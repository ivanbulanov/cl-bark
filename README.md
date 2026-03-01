# cl-bark

High-performance structured logger for Common Lisp. Inspired by [Pino](https://github.com/pinojs/pino) (Node.js), [zerolog](https://github.com/rs/zerolog) (Go), and [slog](https://pkg.go.dev/log/slog) (Go).

## Philosophy

Do nothing in the hot path. Pre-compute everything at logger creation time, serialize in the caller thread, do I/O in a background thread. A disabled log call is a function pointer to `noop` — no branch, no allocation.

## Quick Start

```lisp
;; Start the global async logger
(bark:start :name "myapp" :level :info)

;; Log structured messages
(bark:info "user logged in" :user-id 42 :method "oauth")
;; => {"level":30,"ts":1740600000123,"name":"myapp","user-id":42,"method":"oauth","msg":"user logged in"}

(bark:debug "cache miss" :key "session:abc")  ; silenced at :info level — noop call

;; Structured context (scoped to dynamic extent)
(bark:with-context (:request-id "req-123" :tenant "acme")
  (bark:info "processing request")
  (bark:warn "slow query" :duration-ms 1500))

;; Child loggers with pre-serialized bindings
(let ((auth-logger (bark:child bark:*logger* :component "auth")))
  (let ((bark:*logger* auth-logger))
    (bark:info "token verified")))

;; Stop (flushes and joins writer thread)
(bark:stop)
```

## Features

- **Async I/O** — `sb-concurrency:mailbox` with batch drain; caller thread never blocks on I/O
- **Function pointer swap** — `set-level` swaps slots to `#'noop`; disabled levels cost one indirect call
- **Pre-serialized chindings** — child logger bindings serialized once at creation, zero per-call cost
- **Stack-allocated &rest** — `dynamic-extent` on per-call fields avoids heap allocation
- **Compile-time elimination** — set `*compile-time-max-level*` before compiling to strip calls entirely
- **Pluggable formatters** — JSON Lines (production), logfmt (compact), pretty (ANSI-colored REPL)
- **Dynamic context** — `with-context` uses CL special variables for automatic scoping and thread isolation
- **Counter-based sampling** — per-level 1-in-N sampling, checked before serialization
- **Synchronous flush** — `flush-async-output` uses mailbox rendezvous, not sleep

## Log Levels

| Level | Value | Keyword |
|-------|-------|---------|
| Trace | 10 | `:trace` |
| Debug | 20 | `:debug` |
| Info | 30 | `:info` |
| Warn | 40 | `:warn` |
| Error | 50 | `:error` |
| Fatal | 60 | `:fatal` |

Levels are integer-encoded, spaced by 10 for user-defined intermediate levels.

## API Reference

### Logging

```lisp
(bark:trace message &rest fields)
(bark:debug message &rest fields)
(bark:info  message &rest fields)
(bark:warn  message &rest fields)
(bark:error message &rest fields)
(bark:fatal message &rest fields)
```

Each macro expands to `(funcall (logger-<level>-fn *logger*) *logger* message fields...)`. When the level is disabled, the function slot is `#'noop`.

### Logger Management

```lisp
;; Create a logger (sync or with custom output)
(bark:make-logger &key (name "") (level :info) (formatter #'json-formatter) output)

;; Create child logger with pre-serialized bindings
(bark:child parent &rest bindings)

;; Change level at runtime (swaps function slots)
(bark:set-level logger level)
```

### Lifecycle

```lisp
;; Start global async logger
(bark:start &key (stream *error-output*) (level :info) (formatter #'json-formatter) (name ""))

;; Stop and flush
(bark:stop)
```

### Context

```lisp
;; Dynamic context — fields added to all log calls within scope
(bark:with-context (:request-id id :tenant name)
  body...)
```

### Formatters

A formatter is a function with signature:
```
(level chindings raw-bindings context message fields) -> string
```

Built-in formatters:
- `bark:json-formatter` — JSON Lines (default, production)
- `bark:logfmt-formatter` — `key=value` pairs
- `bark:pretty-formatter` — ANSI-colored for REPL

Swap at runtime:
```lisp
(setf (bark::logger-formatter bark:*logger*) #'bark:pretty-formatter)
```

### Sampling

```lisp
;; Log 1 in 100 debug messages
(bark:set-sampling bark:*logger* :debug 100)
```

### Compile-Time Elimination

```lisp
;; Before compiling application code:
(setf bark:*compile-time-max-level* 30)  ; strip trace and debug at compile time
```

### Testing

```lisp
;; Captures log output as a list of strings (default: json-formatter)
(bark:with-captured-logs (get-logs)
  (bark:info "test message" :key "value")
  (let ((lines (funcall get-logs)))
    (assert (= 1 (length lines)))))

;; Use a different formatter for test assertions
(bark:with-captured-logs (get-logs #'bark:logfmt-formatter)
  (bark:info "hello")
  (assert (search "level=info" (first (funcall get-logs)))))
```

## Globals

| Variable | Purpose |
|----------|---------|
| `bark:*logger*` | Current logger (bind per-thread or globally) |
| `bark:*log-context*` | Dynamic context alist (managed by `with-context`) |
| `bark:*compile-time-max-level*` | When positive, compiler macros eliminate calls below this level |

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| `bordeaux-threads` | Thread creation for async writer |
| `sb-concurrency` | Lock-free mailbox (SBCL contrib) |

SBCL 2.4+ required. No portable fallback in v1.0.

## Note on Symbol Shadowing

The convenience macros `bark:trace`, `bark:debug`, `bark:warn`, and `bark:error` shadow `cl:trace`, `cl:debug`, `cl:warn`, and `cl:error`. This only matters if your package `(:use :bark)`. In that case, either shadow-import the ones you need:
```lisp
(:shadowing-import-from :bark #:error #:warn #:trace #:debug)
```
Or — the recommended approach — don't `(:use :bark)` and call everything with the `bark:` prefix.

## Design Document

See [cl-bark-design.md](../funhouse-mcp/docs/plans/2026-02-26-cl-bark-design.md) for the full design rationale, architecture diagrams, and v1.1 roadmap.
