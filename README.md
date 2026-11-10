# cl-bark

Structured logger for Common Lisp (SBCL). Log calls take a message and keyword fields and write JSON lines, logfmt or colored text. Formatting happens in the calling thread and a background thread writes to the stream. Inspired by [Pino](https://github.com/pinojs/pino) (Node.js), [zerolog](https://github.com/rs/zerolog) (Go), and [slog](https://pkg.go.dev/log/slog) (Go).

## Status

**Beta (0.1.0).** Tested with automated tests and used only by its author. The API may change before 1.0. See [CHANGELOG.md](CHANGELOG.md).

## Installation

cl-bark is not in Quicklisp yet. Clone it where ASDF can find it, then load it with Quicklisp so the dependencies are fetched:

```sh
git clone https://github.com/ivanbulanov/cl-bark.git ~/quicklisp/local-projects/cl-bark
```

```lisp
(ql:quickload :cl-bark)
```

With [qlot](https://github.com/fukamachi/qlot), add `github cl-bark ivanbulanov/cl-bark` to your `qlfile`.

SBCL only. Tested on x86-64; the ring buffer relies on x86-64 store ordering and ARM64 is untested. See [dependencies](#dependencies).

## Quick Start

```lisp
;; Create the global async logger
(setf bark:*logger* (bark:make-logger :level :info :context '(:name "myapp")))

;; Log structured messages
(bark:info "user logged in" :user-id 42 :method "oauth")
;; => {"level":"info","ts":1740600000123,"name":"myapp","user-id":42,"method":"oauth","msg":"user logged in"}

(bark:debug "cache miss" :key "session:abc")  ; below :info, so this call does nothing

;; Dynamic context, scoped to the dynamic extent
(bark:with-context (:request-id "req-123" :tenant "acme")
  (bark:info "processing request")
  (bark:warn "slow query" :duration-ms 1500))

;; Static context (pre-serialized, fixed for the logger's lifetime)
(let ((auth-logger (bark:make-child bark:*logger* :context '(:component "auth"))))
  (bark:info auth-logger "token verified"))

;; Stop: flushes and joins the writer thread
(bark:stop bark:*logger*)
```

## Features

- Asynchronous output through a lock-free ring buffer with one writer thread per destination. A full buffer drops lines and reports the count, or the caller waits if you choose [blocking mode](docs/blocking-mode.md).
- Multiple destinations with their own formatter, level or filter ([multi-output](docs/multi-output.md)).
- JSON Lines, logfmt and a colored REPL formatter, or your own ([formatters](docs/formatters.md)).
- Static context on child loggers and dynamic context with `with-context` ([context](docs/context.md)).
- Field redaction with a per-logger `:field-transform`.
- Conditions as field values, with optional stack traces through `bark:capture`.
- Per-level windowed sampling and key-consistent sampling ([sampling](docs/sampling.md)).
- Request-scoped buffering that decides after the fact which lines to emit ([buffering](docs/request-scoped-buffering.md)).
- A disabled level costs one call to `noop`, and `*compile-time-min-level*` removes calls at compile time.

## Log Levels

| Level | Value | Keyword |
|-------|-------|---------|
| Trace | 1 | `:trace` |
| Debug | 2 | `:debug` |
| Info | 3 | `:info` |
| Warn | 4 | `:warn` |
| Error | 5 | `:error` |
| Fatal | 6 | `:fatal` |

## Tour of the API

### Logging macros

```lisp
(bark:info message &rest fields)             ; uses *logger*
(bark:info logger message &rest fields)      ; explicit logger
(bark:info :key value &rest fields)          ; fields only, no message
(bark:info logger :key value &rest fields)
```

`trace`, `debug`, `info`, `warn`, `error` and `fatal` all accept an optional logger as the first argument. If the first argument is a `logger`, it is used. Otherwise `*logger*` is used. If the first remaining argument is a keyword, the arguments are a fields-only plist and the output has no `msg` field.

```lisp
(bark:info "user registered" :user-id 42)
;; => {"level":"info","ts":...,"user-id":42,"msg":"user registered"}

(bark:info :event "registration" :user-id 42)
;; => {"level":"info","ts":...,"event":"registration","user-id":42}
```

When `*logger*` is nil, or the first argument is an explicit `nil`, the call does nothing. Message and field forms are evaluated only when the level is enabled.

To guard expensive argument computation, use `level-enabled-p`. It checks the level threshold only, not sampling or tee filters, and returns nil for a nil logger:

```lisp
(when (bark:level-enabled-p bark:*logger* :debug)
  (bark:debug "state dump" :snapshot (expensive-serialize state)))
```

When the fields are only known at run time, `emit` takes them as a list. It goes through the same level check, samplers and field transform as the macros, but the caller has already evaluated the fields, and `*compile-time-min-level*` does not apply:

```lisp
(bark:emit bark:*logger* :info "request done" (list* :status status extra-fields))
```

### Creating and stopping loggers

```lisp
(setf bark:*logger* (bark:make-logger :level :info :context '(:name "myapp")))

(bark:make-child parent :context '(:component "auth"))   ; static context, shared output
(bark:set-level logger :debug)                           ; change the level at runtime
(bark:current-level logger)                              ; the level as a keyword, :debug
(bark:flush logger)                                      ; block until pending lines are written
(bark:stop logger)                                       ; drain and join the writer threads
```

The `:output` argument decides how a logger writes:

| `:output` | Behavior |
|-----------|----------|
| A stream | Background writer thread and ring buffer |
| A function | Called synchronously with each line; no thread |
| A tee from `bark:tee` or `bark:make-tee` | One writer per destination ([multi-output](docs/multi-output.md)) |
| `nil` | `*error-output*`, as a stream |

Async outputs are drained at image exit, and writer threads are restarted after `save-lisp-and-die`. A child shares its parent's output and must not be stopped; stop the root logger. The signatures, `bark:dropped-count`, timeouts and conditions are in [lifecycle.md](docs/lifecycle.md).

### Context

Output fields come from static context (`:context` on a logger or child, serialized once), dynamic context (`with-context`, scoped to the dynamic extent and the thread) and the per-call fields:

```lisp
(let ((auth (bark:make-child bark:*logger* :context '(:component "auth"))))
  (bark:with-context (:request-id "req-123")
    (bark:info auth "token verified" :user-id 42)))
;; component, request-id and user-id all appear
```

See [context.md](docs/context.md) for shadowing rules and for field redaction.

### Conditions as fields

```lisp
(handler-case (process-request)
  (cl:error (c)
    (bark:error "request failed" :err c :path "/api/users")))
;; JSON: ...,"err":{"type":"simple-error","msg":"connection refused"},"path":"/api/users","msg":"request failed"
```

Wrap the condition in `(bark:capture c)` inside `handler-bind` to include a stack trace. See [formatters.md](docs/formatters.md#condition-logging).

### Compile-time elimination

When `bark:*compile-time-min-level*` is bound to a level while a logging macro is expanded, calls below that level expand to `nil`, and their arguments are never evaluated. The variable is read at macroexpansion time, so recompile after changing it.

```lisp
(let ((bark:*compile-time-min-level* :info))
  (compile-file "app.lisp"))
```

### Testing

The logging macros do nothing when `bark:*logger*` is nil. To assert on output:

```lisp
(bark:with-captured-logs (get-logs)
  (bark:info "test message" :key "value")
  (assert (= 1 (length (funcall get-logs)))))

;; with another formatter
(bark:with-captured-logs (get-logs (bark:make-logfmt-formatter))
  (bark:info "hello")
  (assert (search "level=info" (first (funcall get-logs)))))
```

## Symbol shadowing

The macros `bark:trace`, `bark:debug`, `bark:warn` and `bark:error` shadow `cl:trace`, `cl:debug`, `cl:warn` and `cl:error`. This matters only if your package uses `:bark`. Call everything with the `bark:` prefix instead.

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| `bordeaux-threads` | Thread creation and semaphores |
| `atomics` | CAS and atomic increment for the ring buffer |
| `dissect` | Stack trace capture for condition logging |
| `local-time` | Unix millisecond timestamps |

cl-bark runs on SBCL only: it uses `sb-ext` hooks unconditionally.

## Documentation

The [index](docs/README.md) lists everything. The guides:

| Page | Covers |
|------|--------|
| [docs/lifecycle.md](docs/lifecycle.md) | `make-logger`, `flush`, `stop`, `save-lisp-and-die`, conditions and restarts |
| [docs/context.md](docs/context.md) | Static and dynamic context, field redaction |
| [docs/formatters.md](docs/formatters.md) | Built-in and custom formatters, logging conditions |
| [docs/multi-output.md](docs/multi-output.md) | Tee outputs, routing, error recovery |
| [docs/blocking-mode.md](docs/blocking-mode.md) | Dropping and blocking when the buffer is full |
| [docs/sampling.md](docs/sampling.md) | Windowed and consistent sampling |
| [docs/request-scoped-buffering.md](docs/request-scoped-buffering.md) | `with-log-buffer` |
| [docs/interactions.md](docs/interactions.md) | How the features combine |
| [docs/value-serialization.md](docs/value-serialization.md) | How field values are rendered |
| [docs/benchmarks.md](docs/benchmarks.md) | Running and reading the benchmarks |
| [docs/reference.md](docs/reference.md) | Special variables and exports |
| [docs/design/](docs/design/overview.md) | Architecture and design rationale |

The [API reference](https://ivanbulanov.github.io/cl-bark/) is generated from docstrings. See also [CHANGELOG.md](CHANGELOG.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Author

[Ivan Bulanov](https://github.com/ivanbulanov)
