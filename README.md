# cl-bark

High-performance structured logger for Common Lisp. Inspired by [Pino](https://github.com/pinojs/pino) (Node.js), [zerolog](https://github.com/rs/zerolog) (Go), and [slog](https://pkg.go.dev/log/slog) (Go).

## Status

**Beta (0.1.0).** The library has been reviewed and tested with automated tests but has been used only by the author so far. Real-world applicability is not yet proven. The API is not expected to change, but no stability guarantee is made until 1.0.

## Philosophy

Do nothing in the hot path. Pre-compute everything at logger creation time, serialize in the caller thread, do I/O in a background thread. A disabled log call is a function pointer to `noop` — no branch, no allocation.

## Quick Start

```lisp
;; Create the global async logger
(setf bark:*logger* (bark:make-logger :level :info :context '(:name "myapp")))

;; Log structured messages
(bark:info "user logged in" :user-id 42 :method "oauth")
;; => {"level":"info","ts":1740600000123,"name":"myapp","user-id":42,"method":"oauth","msg":"user logged in"}

(bark:debug "cache miss" :key "session:abc")  ; silenced at :info level — noop call

;; Dynamic context (scoped to dynamic extent)
(bark:with-context (:request-id "req-123" :tenant "acme")
  (bark:info "processing request")
  (bark:warn "slow query" :duration-ms 1500))

;; Static context (pre-serialized, fixed for the logger's lifetime)
(let ((auth-logger (bark:make-child bark:*logger* :context '(:component "auth"))))
  (bark:info auth-logger "token verified"))

;; Stop (flushes and joins writer thread)
(bark:stop bark:*logger*)
```

## Features

- **Async I/O** — lock-free MPSC ring buffer with batch drain; semaphore-based flush, no sleep-polling
- **Function output** — pass a function as `:output` for testing or custom integrations; called synchronously, no thread
- **Bounded async buffer** — configurable ring buffer capacity with drop-on-full semantics
- **Blocking back-pressure** — `:blocking t` makes callers wait for buffer space instead of dropping; configurable timeout and callback
- **Multi-output (tee)** — fan-out to multiple destinations, each with its own formatter, filter, and async writer
- **Per-destination filters** — route events by level or custom predicate per destination
- **Per-destination formatters** — for example, JSON to file, pretty to console
- **Shared formatter optimization** — when destinations share an `eq` formatter, the message is formatted once
- **Error recovery** — per-destination `:on-error` handler can swap streams on failure
- **Child loggers** — `make-child` shares parent output; inherits and composes context, field-transform, and samplers
- **Implicit or explicit logger** — single-logger apps use `*logger*` and bare `(bark:info ...)`; multi-logger apps pass a logger as first argument
- **Static context** — logger fields serialized once at creation, zero per-call cost
- **Dynamic context** — `with-context` uses CL special variables for automatic scoping and thread isolation
- **Pluggable formatters** — JSON Lines (production), logfmt (compact), pretty (ANSI-colored REPL)
- **Structured error capture** — `bark:capture` snapshots conditions with stack traces; formatters serialize type, message, and frames
- **Field redaction** — per-logger `field-transform` drops or masks fields before serialization; composable via child loggers
- **Windowed rate limiting** — per-level time-windowed counters with initial burst allowance then 1-in-N, checked before serialization
- **Consistent hash sampling** — deterministic key-based sampling via `make-consistent-sampler`; same key always kept or always dropped
- **Low overhead** — disabled levels cost one indirect call (`#'noop` slot swap), per-call fields are stack-allocated (`dynamic-extent`), `*compile-time-max-level*` strips calls entirely at compile time
- **Request-scoped buffering** — `with-log-buffer` captures all log calls; on success emit only info+, on failure emit everything including debug — zero-config retroactive log level decisions

## Log Levels

| Level | Value | Keyword |
|-------|-------|---------|
| Trace | 1 | `:trace` |
| Debug | 2 | `:debug` |
| Info | 3 | `:info` |
| Warn | 4 | `:warn` |
| Error | 5 | `:error` |
| Fatal | 6 | `:fatal` |

## API Reference

### Logging Macros

```lisp
(bark:info message &rest fields)             ; message + fields, uses *logger*
(bark:info logger message &rest fields)      ; message + fields, explicit logger
(bark:info :key value &rest fields)          ; fields only, no message
(bark:info logger :key value &rest fields)   ; fields only, explicit logger
```

All six macros (`trace`, `debug`, `info`, `warn`, `error`, `fatal`) accept an optional logger as the first argument. When the first argument is a `logger` struct, it is used directly. Otherwise, `*logger*` is used.

**Optional message:** When the first non-logger argument is a keyword, the entire argument list is treated as a fields-only plist and no message is emitted. The `msg` field is omitted from JSON/logfmt output entirely (zerolog `Send()` semantics). When the first non-logger argument is a string, it is used as the message.

```lisp
;; With message
(bark:info "user registered" :user-id 42)
;; => {"level":"info","ts":...,"user-id":42,"msg":"user registered"}

;; Without message — fields only
(bark:info :event "registration" :user-id 42)
;; => {"level":"info","ts":...,"event":"registration","user-id":42}
```

When the first non-logger argument is a literal keyword, the macro emits the fields-only path directly. When it's a variable, a runtime `keywordp` check ensures consistent behavior. When `*logger*` is nil, the call is a no-op.

### Level Predicate

```lisp
(bark:level-enabled-p logger level) -> boolean
```

Returns `t` if a log call at `level` would be dispatched (not noop'd) on `logger`. Use it to guard expensive argument computation:

```lisp
(when (bark:level-enabled-p *logger* :debug)
  (bark:debug "state dump" :snapshot (expensive-serialize state)))
```

When `logger` is `nil`, returns `nil` — consistent with the logging macros.

Checks the level threshold only. Does not account for sampling, per-destination filters, or compile-time elimination.

### Lifecycle

```lisp
;; Create logger and assign to the global
(setf bark:*logger*
      (bark:make-logger &key output (level :info) (formatter #'json-formatter)
                             context field-transform
                             (capacity 8192) (on-drop #'default-on-drop)
                             blocking (block-timeout 5.0) on-block-timeout
                             level-sampler consistent))

;; Create child logger with static context (pre-serialized fields)
;; Children share the parent's output — no threads, no cleanup needed (just let GC collect).
;; Do not call bark:stop on a child; always stop the root logger.
(bark:make-child parent &key context field-transform level)

;; Change level at runtime (swaps function slots)
(bark:set-level logger level)

;; Set sampling rate (1-in-N)
(bark:set-sampling logger level rate)

;; Flush pending messages (blocks until written)
(bark:flush logger)

;; Stop and flush all writer threads (blocks until drained, idempotent)
(bark:stop logger)

;; Register automatic cleanup on image exit (stop is idempotent, safe with explicit stop)
(bark:register-exit-hook logger)
```

`bark:make-logger` is the main entry point. It creates a logger and returns it — assign it to `bark:*logger*` or any other variable. The output type determines whether async I/O is used:

| `:output` value | Behavior |
|---|---|
| Stream | Wrapped in async-output (background thread + ring buffer) |
| Function | Called synchronously — no thread, no buffer |
| `tee-output` | Used as-is (already contains async-outputs internally) |
| NIL | Defaults to `*error-output*`, wrapped in async-output |

`:output` accepts a stream, a function, a tee-output (from `bark:tee` or `bark:make-tee`), or NIL. Async-specific parameters (`:capacity`, `:on-drop`, `:blocking`, `:block-timeout`, `:on-block-timeout`) are only valid for stream outputs. Passing them with a function or tee-output signals `bark-configuration-error`.

`:context`, when provided, is a plist of static context fields pre-serialized into the root logger. Zero per-call cost.

`:field-transform`, when provided, is a function `(lambda (key value) ...)` applied to every field before serialization. See [Field Redaction](#field-redaction).

`bark:stop` flushes and joins all writer threads for the given logger. Blocks until the queue is drained and threads have exited. Idempotent — stopping an already-stopped or sync logger is a no-op. Calling on a child logger signals `bark-child-operation-error` (a `continue` restart is available to silently ignore). Always stop the root logger.

`bark:flush` blocks until all pending messages in the logger's async output are written to their streams. Accepts any logger — global or user-created. Handles both single-output and tee-output loggers. Signals `bark-async-stopped` if any async output has been stopped (a `continue` restart is available to skip stopped outputs).

`bark:register-exit-hook` registers a logger for automatic `bark:stop` on Lisp image exit. Safe to combine with an explicit `bark:stop` call (stop is idempotent). Supports SBCL, CCL, ECL, ABCL, and CLISP.

### Multi-Output

#### `make-tee` (function)

```lisp
(bark:make-tee destinations) -> tee-output
```

`destinations` is a list of plists, each with the keys:

- `:stream` (required) — an output stream
- `:formatter` — a formatter function (defaults to `#'bark:json-formatter`)
- `:filter` — `(lambda (level fields) ...)` returning non-nil to pass, nil to skip. Receives the log level (integer) and per-call fields only — not static or dynamic context
- `:level` — a level keyword; shorthand for a filter that checks `(>= level threshold)`. Mutually exclusive with `:filter`
- `:capacity` — ring buffer size in messages for this destination (defaults to 8192; rounded up to next power of two, minimum 16)
- `:on-drop` — `(lambda (count) ...)` called when messages are dropped due to a full buffer. Returns a warning message string, or NIL to suppress. Can optionally return extra fields as a second value: `(values message fields)`. See [Backpressure](#backpressure) for the full return protocol. Defaults to `#'bark::default-on-drop`
- `:on-error` — `(lambda (condition) ...)` called in the writer thread when a stream write fails. Return a new stream to swap and continue writing, or nil to stop the writer thread (subsequent log calls silently drop messages). The condition is the original `file-error` or `stream-error` — bark does not wrap it. When omitted, the writer logs to `*error-output*` and stops.

`bark:stop` tears down all writer threads. Streams are not closed — the caller who opened them is responsible for closing them.

#### `tee` (macro)

```lisp
(bark:tee &rest destination-specs) -> tee-output
```

Syntax sugar over `make-tee`. Each destination spec has the form `(stream-expr &key formatter filter level capacity on-drop on-error)`:

```lisp
(bark:tee
  ;; Fast local console — small buffer
  (*error-output*                       :formatter #'bark:pretty-formatter
                                        :capacity 1024)
  ;; Slow remote sink — large buffer, custom drop message
  ((open "/var/log/app.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'bark:json-formatter
                                        :capacity 65536
                                        :on-drop (lambda (n) (format nil "lost ~d" n)))
  ;; Errors only
  ((open "/var/log/errors.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'bark:json-formatter
                                        :level :error))
```

Specifying both `:level` and `:filter` in the same destination spec signals `bark-configuration-error`.

### Context

Log output includes fields from three sources, merged in this order:

1. **Static context** — fixed fields on the logger, set once via `bark:make-child`. Pre-serialized at creation time; zero cost per log call.
2. **Dynamic context** — scoped fields via `bark:with-context`. Active for all log calls within the dynamic extent. Thread-isolated via CL special variables.
3. **Per-call fields** — the `&rest` arguments passed directly to `bark:info`, `bark:warn`, etc.

```lisp
;; Static context — lives on the logger
(let ((auth-logger (bark:make-child bark:*logger* :context '(:component "auth"))))

  ;; Dynamic context — scoped to this body
  (bark:with-context (:request-id "req-123")

    ;; Per-call fields
    (bark:info auth-logger "token verified" :user-id 42)))
;; Output merges all three: component, request-id, user-id
```

#### When to Use Each

**Child loggers** bind context at creation time — structural identity that lives for the logger's lifetime:

```lisp
;; Fixed for this component — every log carries :component automatically
(defvar *db-log* (bark:make-child bark:*logger* :context '(:component "database" :pool-size 10)))
(bark:info *db-log* "connection acquired")
```

**Dynamic context** binds context to a code path — scoped to the call stack:

```lisp
;; Scoped to this request — all code within sees these fields
(bark:with-context (:request-id (generate-id) :user-id 42)
  (handle-auth)
  (run-query)
  (send-response))
```

**Dynamic context wins for cross-cutting concerns.** A request ID needs to appear in logs from every component, but each component has its own child logger:

```lisp
(bark:with-context (:request-id "req-123")
  (bark:info *auth-log* "checking token")   ; → component=auth, request-id=req-123
  (bark:info *db-log* "running query")      ; → component=database, request-id=req-123
  (bark:info *cache-log* "cache miss"))     ; → component=cache, request-id=req-123
```

With child loggers alone, you'd need to create a temporary child of *each* component logger per request and ensure every function uses the right one. `with-context` adds the field once and all loggers see it.

**Child loggers win for permanent identity.** A worker's ID is fixed for its lifetime:

```lisp
(dotimes (i pool-size)
  (let ((log (bark:make-child bark:*logger* :context (list :worker-id i))))
    (spawn-worker log)))
```

Dynamic context would require wrapping the entire worker body in `with-context`, and the binding wouldn't survive callbacks into shared code that re-establishes context.

**The combination is the intended usage:** child loggers carry *who* (component identity), dynamic context carries *when/why* (request trace, correlation ID):

```
child logger:     component=database, pool-size=10    (structural, permanent)
dynamic context:  request-id=req-123, tenant=acme     (per-request, transient)
per-call fields:  query="SELECT ...", duration-ms=42   (this specific event)
```

### Condition Logging

Conditions passed as field values are automatically serialized with their type and message — no wrapper needed.

```lisp
(handler-case (process-request)
  (cl:error (c)
    (bark:error "request failed" :err c :path "/api/users")))
;; JSON: {"level":"error",...,"err":{"type":"simple-error","msg":"connection refused"},"path":"/api/users","msg":"request failed"}
;; logfmt: level=error ... err="simple-error: connection refused" path=/api/users msg=request\ failed
;; pretty: ERROR request failed err=simple-error: connection refused path=/api/users
```

For stack traces, use `bark:capture` inside `handler-bind` (stack still live):

```lisp
(handler-bind ((cl:error (lambda (c)
                           (bark:error "request failed"
                                       :err (bark:capture c))
                           (invoke-restart 'abort))))
  (process-request))
;; JSON err field: {"type":"simple-error","msg":"...","stack":[{"call":"process-request","file":"api.lisp","line":42},...]}
;; pretty: ERROR request failed err=simple-error: connection refused
;;           at PROCESS-REQUEST (api.lisp:42)
;;           at HANDLE-CONNECTION (server.lisp:88)
```

`bark:capture` works in `handler-case` too, but the stack trace reflects the handler's location (the stack has already unwound), not the error origin.

Stack frame limits:

```lisp
(setf bark:*max-json-stack-frames* 20)    ; default 10, NIL = unlimited
(setf bark:*max-pretty-stack-frames* 30)  ; default 20, NIL = unlimited
```

### Field Redaction

A `:field-transform` on a logger intercepts every field (key-value pair) before serialization. Use it to drop sensitive fields or mask values.

The transform is a function `(lambda (key value) ...)` returning:
- The (possibly modified) value to keep the field
- `(values nil nil)` (two values, second nil) to drop the field entirely

```lisp
;; Drop :password fields, mask :token values
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :field-transform (lambda (key value)
                                           (case key
                                             (:password (values nil nil))
                                             (:token    "****")
                                             (t         value)))))

(bark:info "login" :user "alice" :password "hunter2" :token "abc-xyz")
;; => {"level":"info",...,"user":"alice","token":"****","msg":"login"}
;; :password is gone, :token is masked
```

The transform applies to **all three field sources**:

| Source | When applied |
|--------|-------------|
| Per-call fields | At log call time, before formatting |
| Dynamic context | At log call time, before formatting |
| Static context (child) | At `make-child` creation time, before pre-serialization |

**Inheritance.** Children inherit the parent's transform. A child can add its own via `:field-transform` — it composes with the parent's (parent runs first, then child):

```lisp
(let* ((parent (bark:make-logger :level :info :output stream
                                 :field-transform (lambda (key value)
                                                    (if (eq key :secret)
                                                        (values nil nil)
                                                        value))))
       ;; Child adds token masking on top of parent's secret dropping
       (child (bark:make-child parent :context '(:component "auth")
                               :field-transform (lambda (key value)
                                                  (if (eq key :token)
                                                      "****"
                                                      value)))))
  (bark:info child "login" :user "alice" :secret "pw" :token "xyz"))
;; => :secret dropped (parent), :token masked (child)
```

**Cost.** One `funcall` per field when the slot is non-nil. When nil (the default), zero overhead — the transform check is a null-pointer test in the hot path.

### Formatters

A formatter is a function with signature:
```
(level chindings raw-bindings context message fields) -> string
```

| Parameter | Type | Purpose |
|-----------|------|---------|
| `level` | fixnum | Numeric log level (1-6) |
| `chindings` | string | Static context pre-serialized as a JSON fragment (e.g. `,"name":"myapp"`). Splice directly into JSON output for zero per-call serialization cost |
| `raw-bindings` | plist | Static context as a key-value plist (e.g. `(:name "myapp")`). Same data as `chindings` but not pre-serialized — use this in non-JSON formatters |
| `context` | alist | Dynamic context from `with-context` |
| `message` | string | The log message |
| `fields` | plist | Per-call fields from the `&rest` args |

JSON-oriented formatters use `chindings` (pre-serialized, zero per-call cost) and `(declare (ignore raw-bindings))`. Text-oriented formatters use `raw-bindings` and `(declare (ignore chindings))`. Both representations carry the same data.

Built-in formatters:
- `bark:json-formatter` — JSON Lines (default, production)
- `bark:logfmt-formatter` — `key=value` pairs
- `bark:pretty-formatter` — colored terminal output for REPL/development

**Supported field value types:**

| Type | JSON | logfmt | pretty |
|------|------|--------|--------|
| `string` | `"escaped"` | `bare` or `"quoted"` | unquoted |
| `integer` | `123` | `123` | `123` |
| `float` | `3.14` | `3.14` | `3.14` |
| `ratio` | `0.333` | `0.333` | `1/3` |
| `t` | `true` | bare key (no `=value`) | `T` |
| `nil` | `null` | `null` | `NIL` |
| `symbol` | `"lowercase"` | `lowercase` | `UPPERCASE` |
| `list` | `["a","b"]` | `<cons>` | `princ` (bounded) |
| `vector` | `[1,2,3]` | `<simple-vector>` | `princ` (bounded) |
| `hash-table` | `{"k":"v"}` | `<hash-table>` | `princ` (bounded) |
| `pathname` | `"/var/log/app.jsonl"` | `/var/log/app.jsonl` | namestring |
| `condition` | `{"type":"...","msg":"..."}` | `"type: msg"` | type: msg |
| `captured-error` | `{"type":"...","msg":"...","stack":[...]}` | `"type: msg"` | type: msg + stack |
| everything else | `"<type>"` | `<type>` | `princ` |

All types are accepted — no log call ever signals `type-error`. Ratios are coerced to `double-float`.

**JSON:**
- Lists serialize as arrays (including dotted pairs)
- Vectors as arrays, hash-tables as objects, pathnames as strings
- Unsupported types fall back to a `"<type>"` placeholder string

**logfmt:**
- Collections and unsupported types emit an unquoted `<type>` placeholder (e.g., `<cons>`, `<hash-table>`)
- Boolean `t` emits a bare key with no `=value` (logfmt convention for flags)

**pretty:** Values are printed via `princ`, bounded by `*print-level*` and `*print-length*`.

**Customization:** Specialize `print-object` on your classes to control the type name shown in placeholders. Collection depth and length are bounded by formatter-specific limits — see [Tuning](#tuning).

#### Formatter Factories

The built-in formatters (`json-formatter`, `logfmt-formatter`, `pretty-formatter`) are zero-config convenience functions with fixed defaults. When you need to match an external system's expected format — different field names, timestamp format, or level encoding — use the corresponding factory function to create a customized formatter. Factories return closures with the same signature as the built-ins, with all configuration pre-computed at creation time (no per-call overhead). You can also write an entirely custom formatter — any function with the signature `(level chindings raw-bindings context message fields)` that returns a string works as a `:formatter`. Custom formatters must call `bark:current-log-timestamp-ms` for timestamps instead of reading the clock directly — during `with-log-buffer` replay, this function returns the original log-call timestamp rather than the flush time.

**`make-json-formatter`**

```lisp
(bark:make-json-formatter &key (timestamp :unix-ms) (level-format :string)
                               (level-key "level") (timestamp-key "ts")
                               (message-key "msg"))
```

| Parameter | Values | Default |
|-----------|--------|---------|
| `timestamp` | `:unix-ms`, `:iso8601`, `nil` (omit) | `:unix-ms` |
| `level-format` | `:string`, `:numeric` | `:string` |
| `level-key` | any string, or `nil` (omit) | `"level"` |
| `timestamp-key` | any string | `"ts"` |
| `message-key` | any string | `"msg"` |

```lisp
;; GCP Cloud Logging format
(setf bark:*logger*
      (bark:make-logger :formatter (bark:make-json-formatter
                                     :level-key "severity" :level-format :string
                                     :timestamp-key "timestamp" :timestamp :iso8601
                                     :message-key "message")))

(bark:info "deployed" :version "1.2.3")
;; => {"severity":"info","timestamp":"2025-01-15T12:00:00.000Z","version":"1.2.3","message":"deployed"}

;; Omit timestamp (external system adds it)
(setf bark:*logger* (bark:make-logger :formatter (bark:make-json-formatter :timestamp nil)))
;; => {"level":"info","version":"1.2.3","msg":"deployed"}

;; Omit level (external system adds it)
(setf bark:*logger* (bark:make-logger :formatter (bark:make-json-formatter :level-key nil)))
;; => {"ts":1740600000123,"msg":"deployed"}
```

**`make-logfmt-formatter`**

```lisp
(bark:make-logfmt-formatter &key (timestamp :unix-ms) (level-key "level")
                                  (timestamp-key "ts") (message-key "msg"))
```

Level is always a string in logfmt. Pass `:level-key nil` to omit it. Timestamp accepts `:unix-ms`, `:iso8601`, or `nil`.

```lisp
(setf bark:*logger*
      (bark:make-logger :formatter (bark:make-logfmt-formatter :level-key "lvl" :message-key "message")))
(bark:info "ready" :port 8080)
;; => lvl=info ts=1736942400000 port=8080 message=ready
```

**`make-pretty-formatter`**

```lisp
(bark:make-pretty-formatter &key timestamp (timestamp-key "ts") (show-level t))
```

The standard `pretty-formatter` omits timestamps (REPL use). The factory adds optional timestamp display. Pass `:show-level nil` to omit the colored level label.

```lisp
;; Pretty with ISO 8601 timestamps
(setf bark:*logger* (bark:make-logger :formatter (bark:make-pretty-formatter :timestamp :iso8601)))
;; => INFO  ts="2025-01-15T12:00:00.000Z" ready port=8080
```

### Sampling

See [docs/sampling.md](docs/sampling.md) for windowed counters, consistent sampling, and configuration.

### Backpressure

**Async mode (default).** Each destination has a bounded ring buffer. When the buffer is full, messages are dropped and a warning is emitted inline. Drop warnings are formatted through the same formatter as normal log entries, so they respect configured field names, timestamp format, and level representation:

**Blocking mode** (`:blocking t` on `make-logger`). When the buffer is full, the caller blocks until space is available (up to `:block-timeout` seconds, default 5). If the timeout expires, `:on-block-timeout` is called if provided; otherwise the message is dropped silently. Use blocking mode when message loss is unacceptable and you can tolerate caller latency spikes.

**Async drop handling:**

```json
{"level":"warn","ts":1740600000123,"msg":"bark: dropped 153 log messages (output too slow)"}
```

The `on-drop` callback receives the drop count and returns `(values message fields)` via multiple values. The writer formats the result at warn level through the destination's formatter:

| Return | Effect |
|--------|--------|
| `"message"` | Message only (second value defaults to nil) |
| `(values "msg" (list :count n))` | Message + extra fields |
| `(values nil (list :dropped n))` | Fields only, no message |
| `nil` | Suppress entirely |

```lisp
;; Default: returns "bark: dropped N log messages (output too slow)"
;; Custom: message + extra fields
(bark:tee
  (*error-output* :capacity 65536)  ; larger buffer (messages, not bytes)
  (log-file       :on-drop (lambda (n) (values (format nil "dropped ~d" n) (list :count n)))))

;; Suppress drop warnings entirely
(setf bark:*logger* (bark:make-logger :on-drop (lambda (n) (declare (ignore n)) nil)))
```

### Compile-Time Elimination

```lisp
;; Before compiling application code:
(setf bark:*compile-time-max-level* 30)  ; strip trace and debug at compile time
```

### Testing

All logging macros are safe to call when `bark:*logger*` is nil — they silently no-op.

To capture and assert on log output:

```lisp
(bark:with-captured-logs (get-logs)
  (bark:info "test message" :key "value")
  (let ((lines (funcall get-logs)))
    (assert (= 1 (length lines)))))

;; Use a different formatter
(bark:with-captured-logs (get-logs #'bark:logfmt-formatter)
  (bark:info "hello")
  (assert (search "level=info" (first (funcall get-logs)))))
```

### Request-Scoped Buffering

Buffer log calls and decide at scope exit which to emit. The default: on success, emit entries at or above the logger's configured level. On failure (unhandled condition), emit everything — including debug and trace.

`with-log-buffer` takes a logger argument, binds it to `*logger*` as a buffer-logger for the body's dynamic extent, and flushes through the original logger on exit. Only implicit log calls (through `*logger*`) are buffered; log calls that pass an explicit logger argument bypass the buffer, because they don't go through `*logger*`.

```lisp
;; Buffer a per-request child logger
(bark:with-log-buffer ((bark:make-child root-logger :context (list :request-id id)))
  (bark:debug "parsing body" :content-type ct)
  (bark:info "processing" :path path)
  (process request))
;; Success: only :info emitted. Error: all entries emitted, then error propagates.
```

**Parameters:**

- **`logger`** (required) — the logger to buffer and flush through.
- **`level`** — capture threshold (default `:trace`). The logger's level is lowered to this inside the scope.
- **`on-flush`** — optional `(lambda (entries condition normal-exit-p) ...)`. Returns a sequence of entries to emit.

```lisp
;; Custom: emit debug logs only for slow requests
(bark:with-log-buffer (request-logger
    :on-flush (lambda (entries condition normal-exit-p)
                (declare (ignore condition normal-exit-p))
                (if (> elapsed-ms 500) entries
                    (remove-if (lambda (e) (< (bark:buffer-entry-level e) bark:+info+))
                               entries))))
  ...)
```

**Semantics:**

- Normal exit: filter to entries >= logger's original level.
- Abnormal exit (unhandled condition): emit all entries.
- Non-condition unwind (`return-from`, `throw`): treated as normal exit.
- Handled errors (caught by `handler-case` inside body): normal exit.
- Explicit logger args (`(bark:info *audit-logger* "msg")`) bypass the buffer.
- **Nesting is a no-op.** If already inside a `with-log-buffer` scope, inner scopes run their body directly with no additional buffering. The outermost scope controls capture level and flush policy. This prevents bugs with wrong flush targets, lost context, and out-of-order output that would arise from independent nested buffers.

**Buffer entries** are structs with accessors for `on-flush` callbacks:

- `bark:buffer-entry-level` — numeric level
- `bark:buffer-entry-message` — log message
- `bark:buffer-entry-fields` — per-call fields plist
- `bark:buffer-entry-context` — snapshot of dynamic context
- `bark:buffer-entry-timestamp` — millisecond timestamp from log time

**Timestamps:** Flushed entries carry their original log-time timestamps. User-defined formatters should call `bark:current-log-timestamp-ms` instead of computing their own to get correct timestamps during replay.

**Compile-time elimination:** `with-log-buffer` can only buffer calls that exist in the compiled code. If `*compile-time-max-level*` eliminates debug calls, they cannot be retroactively surfaced.

### Feature Interactions

#### Disabled by design

**Buffering disables sampling.** Inside `with-log-buffer`, both windowed counters and consistent samplers are bypassed. The buffer captures every log call at or above the capture level. Sampling during capture would lose entries that the `on-flush` callback or error-triggered flush might need. See [docs/sampling.md](docs/sampling.md) for details on the two sampling strategies.

**Nested buffering is a no-op.** If already inside a `with-log-buffer` scope, inner scopes run their body directly. The outermost scope controls capture level and flush policy.

#### Incompatible — signals error

**`:level` + `:filter` on the same tee destination.** `:level` is shorthand for a level-threshold filter. Specify one or the other.

**Async parameters with function or tee output.** `:capacity`, `:on-drop`, `:blocking`, `:block-timeout`, and `:on-block-timeout` on `make-logger` are only valid with stream output. Function outputs are synchronous (no ring buffer or writer thread). Tee outputs configure these per-destination.

#### Contradictory intent

**Sampling + blocking mode.** Blocking mode (`:blocking t`) exists to prevent message loss — audit trails, compliance logs, billing events. Sampling intentionally drops messages. Do not configure both on the same logger: sampling defeats the guarantee blocking mode provides.

#### Behavioral notes

**Compile-time elimination limits buffering.** `with-log-buffer` can only buffer calls that exist in the compiled code. If `*compile-time-max-level*` strips debug/trace calls at compile time, the buffer cannot retroactively surface them at runtime.

**Compile-time elimination is invisible to `level-enabled-p`.** The predicate checks the runtime level threshold only. It can return true for a level whose log calls were eliminated at compile time. If you use both, ensure `*compile-time-max-level*` and your runtime level are consistent.

**Tee filters do not see context.** Per-destination `:filter` functions receive the log level (integer) and per-call fields only — not static context (child logger bindings) or dynamic context (`with-context`). Context is part of formatting, not routing. To route based on identity, use separate loggers.

**Sampling runs before field transforms.** A sampled-out message never reaches the field transform. This means transforms cannot influence sampling decisions — sampling is based solely on the consistent hash and windowed count.

**Sampling runs before tee filters.** A message dropped by sampling never reaches any tee destination's filter. Tee filters cannot recover sampled-out messages.

**Buffer `on-flush` sees untransformed fields.** The buffer captures raw field values. The root logger's field transform is applied after `on-flush` selects which entries to emit, during the actual flush to output. Write `on-flush` callbacks against raw field names and values.

## Benchmarks

### Running

```bash
make bench              # both suites, default parameters
make bench-quick        # smoke test (1000 iterations)
make bench-full         # publication quality (50000 iterations)
make bench-internal     # internal suite only
make bench-comparative  # comparative suite only
make bench-update-sample  # regenerate bench/results/sample.txt
```

Override parameters on the command line:

```bash
make bench ITERATIONS=50000 THREADS=16 SCENARIO=simple-message
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `ITERATIONS` | 10000 | Measurement samples per scenario |
| `WARMUP` | 10000 | Warmup iterations before measurement |
| `THREADS` | 8 | Thread count for concurrent scenarios |
| `CONCURRENT_ITERATIONS` | 100000 | Messages per thread for throughput scenarios |
| `SUITE` | (both) | `internal` or `comparative` |
| `SCENARIO` | (all) | Run a single named scenario |

Or from the REPL:

```lisp
(asdf:load-system "cl-bark/bench-comparative")
(bark-bench:run :suite :internal :iterations 50000)
```

See [sample results](bench/results/sample.txt) for reference numbers on one machine.

### Methodology

All benchmarks write to a discard stream (`(make-broadcast-stream)`) — a portable `/dev/null`. This isolates framework overhead from I/O. Real-world throughput will be lower due to actual disk or network writes.

**Timing.** Per-call latency uses CFFI `clock_gettime(CLOCK_MONOTONIC)` for nanosecond resolution. Each sample measures a batch of 100 calls; per-call estimates are derived by division. This gives ~10ns effective resolution while amortizing the clock read overhead. Sub-microsecond scenarios (disabled-level) use larger batches of 100,000. Throughput scenarios measure wall-clock elapsed time across 100,000+ messages.

**Allocation.** Bytes-consed per call is tracked via `trivial-benchmark` (uses SBCL's `sb-ext:get-bytes-consed` where available). The `&rest` field plist is `(declare (dynamic-extent fields))` and stack-allocated — it does not contribute to bytes-consed. The reported bytes are dominated by the formatter's result string, which is the one unavoidable allocation per log call (it goes on the ring buffer). A per-thread reusable string stream eliminates the stream object allocation.

### Reading the Comparative Results

The comparative suite benchmarks cl-bark against log4cl and vom. These loggers have fundamentally different designs, so the numbers require context.

**Structured vs. text logging.** cl-bark is a structured logger: it serializes typed key-value fields into JSON or logfmt. log4cl and vom are text loggers: they pass format strings to `cl:format`. Structured serialization (escaping strings, printing numbers, building JSON objects) is inherently more expensive than `format` with a few directives. This is the primary reason log4cl is faster per-call on simple messages — it does less work.

**Blocking vs. async.** The comparative suite runs cl-bark in blocking mode to make a fair synchronous comparison against log4cl and vom, which are both synchronous. In production, cl-bark normally runs in async mode: the caller pushes a formatted string onto a lock-free ring buffer and returns immediately, with a background writer thread draining to the stream. Async mode decouples caller latency from I/O latency entirely.

**Allocation gap.** log4cl reports 0 bytes for simple messages and ~465 bytes for structured fields. cl-bark reports ~650-1200 bytes depending on the formatter. The difference is structural: cl-bark builds a complete JSON/logfmt line as a string (the ring buffer payload), while log4cl writes directly to the destination stream with no intermediate string. This is the cost of caller-thread formatting — see [Caller-Thread Formatting](#caller-thread-formatting) for why this trade-off exists.

**Where cl-bark wins.** Multi-threaded throughput: at 8 threads, cl-bark reaches ~1.1M msg/sec vs log4cl's ~730K. cl-bark's lock-free MPSC ring buffer scales with producer threads, while log4cl's appender writes serialize on a lock. This is the scenario that matters in production — multiple application threads logging concurrently.

**Logfmt is faster than JSON.** logfmt output (`key=value` pairs) avoids JSON's escaping and quoting overhead. The difference is ~15-20% on structured fields. If you don't need JSON, logfmt is the better default for performance.

## Usage Examples

### Mirror: Console + File

Same events, different formats. The most common multi-output scenario.

```lisp
(defvar *log-file* (open "/var/log/app.jsonl"
                         :direction :output :if-exists :append
                         :if-does-not-exist :create))

(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter #'bark:pretty-formatter)
                                 (*log-file*     :formatter #'bark:json-formatter))))

(bark:info "request handled" :status 200)
;; => pretty-printed to stderr
;; => JSON line to log file
```

### Level-Based Routing

All events to console, errors only to a separate file.

```lisp
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter #'bark:pretty-formatter)
                                 (*error-file*   :formatter #'bark:json-formatter
                                                 :level :error))))

(bark:info "all good")           ; console only
(bark:error "disk full" :vol 3)  ; console + error file
```

### Content-Based Routing

Audit events to a dedicated stream based on a per-call field.

```lisp
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter #'bark:json-formatter)
                                 (*audit-file*   :formatter #'bark:json-formatter
                                                 :filter (lambda (level fields)
                                                           (declare (ignore level))
                                                           (getf fields :audit))))))

(bark:info "page loaded" :path "/home")                     ; console only
(bark:info "user login" :audit t :user-id 42 :method "sso") ; console + audit file
```

### Two Independent Loggers

Explicit logger arg bypasses `*logger*`. Each logger has its own output pipeline.

```lisp
(setf bark:*logger* (bark:make-logger :level :info :context '(:name "app")))

(defvar *audit-logger*
  (bark:make-logger :level :info
                    :context '(:name "audit")
                    :output (open "/var/log/audit.jsonl"
                                  :direction :output :if-exists :append)))

(bark:info "request handled" :status 200)              ; app logger via *logger*
(bark:info *audit-logger* "user login" :user-id 42)    ; audit logger (explicit)
```

### Error Recovery

The `:on-error` handler receives the original stream condition (`file-error`, `stream-error`, etc.) — bark passes it through without wrapping. The handler runs on the destination's writer thread, not the caller thread — a slow handler stalls the drain, causing the ring buffer to fill and drop messages (callers are never blocked). Return a new stream to swap and continue, or nil to let the writer exit.

Reopen a log file on any error:

```lisp
(bark:tee
  (*error-output* :formatter #'bark:pretty-formatter)
  ((open "/var/log/app.jsonl" :direction :output :if-exists :append)
   :formatter #'bark:json-formatter
   :on-error (lambda (condition)
               (declare (ignore condition))
               (open "/var/log/app.jsonl"
                     :direction :output :if-exists :append
                     :if-does-not-exist :create))))
```

Dispatch on condition type for different recovery strategies:

```lisp
:on-error (lambda (condition)
            (typecase condition
              (file-error (reopen-log-file))    ; disk full, file deleted
              (stream-error (fallback-stream))  ; broken pipe
              (t nil)))                         ; unknown — give up
```

## Configuration Diagrams

### Single Output

```
 bark:info ──> *logger* ──> json-formatter ──> [ring buffer] ──> writer ──> stderr
```

### Tee: Mirror with Different Formatters

```
                                 ┌─> pretty-formatter ──> [ring 1] ──> writer 1 ──> stderr
 bark:info ──> *logger* ──> tee─┤
                                 └─> json-formatter ──> [ring 2] ──> writer 2 ──> app.jsonl
```

### Tee: Level-Based Routing

```
                                 ┌─> pretty-formatter ──> [ring 1] ──> writer 1 ──> stderr
 bark:info ──> *logger* ──> tee─┤
                                 └─> filter(>=error) ─?─> json-formatter ──> [ring 2] ──> writer 2 ──> errors.jsonl
                                         │
                                    skip if below
```

### Tee: Shared Formatter Optimization

Two destinations with the same formatter — formatted once, emitted to both.

```
                                 ┌──────────────────────> [ring 1] ──> writer 1 ──> app.jsonl
 bark:info ──> *logger* ──> tee─┤
                                 │  json-formatter
                                 │  (called once)
                                 └─> filter(>=error) ─?─> [ring 2] ──> writer 2 ──> errors.jsonl
```

### Two Independent Loggers

```
 bark:info "msg"          ──> *logger* ──> pretty-formatter ──> [ring 1] ──> writer 1 ──> stderr

 bark:info *audit* "msg"  ──> *audit* ──> json-formatter ──> [ring 2] ──> writer 2 ──> audit.jsonl
```

### Child Logger Inherits Tee

```
                               static context: component:"auth"
                                        │
 bark:info ──> child-logger ────────────┤
                                        │
                                    tee (inherited)
                                 ┌──────┴──────┐
                                 ▼              ▼
                          pretty-formatter  json-formatter
                                 │              │
                            [ring 1]       [ring 2]
                                 │              │
                            writer 1       writer 2
                                 │              │
                              stderr        app.jsonl
```

### Combined: Tee + Explicit Logger + Dynamic Context

```
 bark:with-context (:request-id "req-123")
   │
   ├─> bark:info "request" ──> *logger* ──> tee─┬─> pretty ──> stderr
   │                                             └─> json ──> app.jsonl
   │                           (context: request-id)
   │
   └─> bark:info *audit* "login" ──> *audit* ──> json ──> audit.jsonl
                                      (context: request-id)
```

## Non-Goals

These are **intentionally** not supported and won't be added:

| Non-goal | Rationale | Recourse |
|----------|-----------|----------|
| **Filters on static/dynamic context** | Static context is known at logger creation time — the routing decision can be made then, not deferred to filter time. Dynamic context is scoped, not routed. | Use separate loggers or the explicit logger argument for routing based on static context. |
| **Output override on `make-child`** | `make-child` is for adding static context, not rerouting. Mixing these concerns complicates the mental model. | Use a separate logger with its own output for different routing. |
| **Named logger registry** | Global mutable registries add implicit coupling. CL already has `defvar` and `defparameter`. | Manage logger variables yourself: `(defvar *audit-logger* (bark:make-logger ...))`. |
| **Structured data in ring buffer** | Formatting in the caller thread is a deliberate throughput and efficiency choice. See [Caller-Thread Formatting](#caller-thread-formatting) for full rationale. | — |
| **Output as a user-visible object** | The tee's internal representation (`tee-output`, `destination`, `formatter-group`) is an implementation detail. | Use `make-tee`/`tee` to create outputs. Inspect via the logger's output slot if needed for debugging. |

## Conditions

All bark-specific conditions inherit from `bark:bark-error` (which inherits from `cl:error`):

```
bark-error                           ; base — all bark errors
├── bark-configuration-error         ; invalid constructor arguments
│     slot: detail (string)          ; human-readable explanation
└── bark-lifecycle-error             ; operation invalid for current state
    ├── bark-async-stopped           ; flush on stopped async output
    └── bark-child-operation-error   ; root-only op attempted on child
          slot: operation (symbol)   ; the attempted operation (e.g. :stop)
```

Conditions are signaled at configuration time or on lifecycle misuse. Logging macros never signal — a disabled level is a `noop` call, and writer errors are handled internally.

| Source | Condition | Restart | When |
|--------|-----------|---------|------|
| `level-from-keyword` | `type-error` | — | Unknown level keyword (from `ecase`) |
| `set-level` | `type-error` | — | Level is neither `fixnum` nor keyword (from `etypecase`) |
| `make-tee` | `bark-configuration-error` | — | Both `:filter` and `:level` on the same destination |
| `tee` | `bark-configuration-error` | — | Same, at macro expansion time |
| `make-logger` | `bark-configuration-error` | — | `:output` is not a stream, function, `tee-output`, or `nil` |
| `make-logger` | `bark-configuration-error` | — | Async parameters with a function or `tee-output` |
| `make-consistent-sampler` | `bark-configuration-error` | — | Rate < 1 |
| `make-level-sampler` | `bark-configuration-error` | — | Non-windowed-counter value |
| `make-windowed-counter` | `bark-configuration-error` | — | Window ticks exceed fixnum range |
| `stop` | `bark-child-operation-error` | `continue` | Called on a child logger |
| `flush` | `bark-async-stopped` | `continue` | Called on a stopped logger |

### Handling Conditions

Selective handling by condition type:

```lisp
;; Catch only configuration errors, let lifecycle errors propagate
(handler-case (bark:make-logger :output 42)
  (bark:bark-configuration-error (c)
    (log:warn "Bad logger config: ~A" (bark:bark-configuration-error-detail c))
    (bark:make-logger)))  ; fall back to defaults
```

### Using Restarts

`flush` and `stop` offer `continue` restarts for graceful degradation:

```lisp
;; Flush what you can, skip stopped outputs
(handler-bind ((bark:bark-async-stopped
                 (lambda (c) (declare (ignore c)) (invoke-restart 'continue))))
  (bark:flush logger))

;; Generic cleanup that works on any logger (root or child)
(handler-bind ((bark:bark-child-operation-error
                 (lambda (c) (declare (ignore c)) (invoke-restart 'continue))))
  (bark:stop logger))
```

### Writer Thread Errors

Writer thread stream errors (`file-error`, `stream-error`, etc.) are caught internally. When `:on-error` is provided, it receives the original condition — see [Error Recovery](#error-recovery). Otherwise the error is logged to `*error-output*` and the writer exits. If the `:on-error` handler itself signals, or an `:on-block-timeout` callback signals, those errors are also caught and written to `*error-output*` — the writer thread never propagates exceptions to the caller.

## Architecture

### Thread-Per-Destination Model

Each destination gets its own writer thread and ring buffer. N destinations = N writer threads.

- **Isolation** — a slow destination (network sink with high latency) cannot block fast ones (local file, stderr)
- **Simplicity** — no thread pool, no multiplexing, no shared-writer coordination
- **Low cost** — idle writer threads are blocked on a semaphore (OS futex). They consume one kernel thread and minimal RSS

### Ring Buffer

Lock-free MPSC (multi-producer, single-consumer):

```
Producer threads              Writer thread
     │                              │
     ├─ format message              │
     ├─ CAS claim slot in ring ──>  │
     ├─ write string to slot        ├─ pop slots in batch
     └─ signal semaphore            ├─ write-string to stream
                                    ├─ force-output
                                    ├─ check drop counter
                                    └─ wait on semaphore
```

**TSO dependency.** The ring buffer's payload slots are written and read with plain `svref`/`setf` — no memory barriers around the string data. Correctness relies on x86 Total Store Order (TSO): stores from the producer become visible to the consumer in program order, so the payload is always committed before the semaphore signal that wakes the writer. This is safe on x86/x86-64 (SBCL's primary target and all implementations supported by `atomics`). A port to a weakly-ordered architecture (ARM, RISC-V) would need acquire/release barriers on the payload slot accesses.

### Caller-Thread Formatting

Every log call formats the message to a finished string in the caller's thread, then pushes that string into the ring buffer. The writer thread does nothing but `write-string` + `force-output`. This is a deliberate choice with four supporting reasons:

**1. Callers are the natural parallelism.** N application threads logging = N-way parallel formatting with zero coordination. Deferring formatting to the writer would serialize all format work on one thread per destination. A dedicated formatter thread pool would add coordination overhead (a second queue, a second CAS + semaphore handoff per message) without improving throughput — the pool's parallelism P is typically ≤ N, and the callers were already doing the work for free.

**2. `dynamic-extent` requires caller-thread formatting.** Per-call fields are declared `dynamic-extent` — the `&rest` plist lives on the stack, zero heap allocation. Deferring formatting to another thread would require heap-copying the fields (they won't survive the caller's stack frame), negating this optimization.

**3. Dynamic context is a special variable.** `*log-context*` is thread-local and can be rebound at any point. The formatter must read it in the caller's thread to capture the correct bindings. Deferring would require snapshotting the alist into the ring buffer slot — an extra allocation per log call, plus the writer would need to know about context semantics.

**4. Shared formatter optimization requires formatting before fan-out.** With tee, destinations are grouped by formatter identity (`eq`). The message is formatted once per group, then the same string is pushed to all passing destinations' ring buffers. If formatting were deferred to writer threads, each writer would format independently — duplicating work when destinations share a formatter.

**Trade-off: per-call latency.** Formatting dominates caller-thread latency. This is bounded by `*max-json-depth*`, `*max-json-length*`, and `*max-json-stack-frames*`. Pre-serialized `chindings` on child loggers eliminate per-call cost for static context. Sampling skips formatting entirely for sampled-out messages.

### Performance Characteristics

| Operation | Cost |
|-----------|------|
| Log call (level disabled) | One indirect call to `noop` |
| Log call (level enabled, async) | Formatting + CAS + semaphore signal |
| Log call (buffer full, drop) | One `atomic-incf` -- formatting skipped |
| Writer drain (per message) | `write-string` + `force-output` |
| Field transform (per field) | One `funcall` when non-nil |

See [Benchmarks](#benchmarks) to measure on your hardware.

## Globals

| Variable | Default | Purpose |
|----------|---------|---------|
| `bark:*logger*` | `nil` | Current logger (bind per-thread or globally) |
| `bark:*log-context*` | `nil` | Dynamic context (managed by `with-context`) |
| `bark:*compile-time-max-level*` | `0` | When positive, compiler macros eliminate calls below this level |
| `bark:*max-json-depth*` | `4` | Max nesting depth for collections in JSON output |
| `bark:*max-json-length*` | `20` | Max elements per collection in JSON output |
| `bark:*max-pretty-depth*` | `4` | Bound as `*print-level*` in pretty-formatter (nil = unlimited) |
| `bark:*max-pretty-length*` | `20` | Bound as `*print-length*` in pretty-formatter (nil = unlimited) |
| `bark:*max-json-stack-frames*` | `10` | Max stack frames in JSON condition output (nil = unlimited) |
| `bark:*max-pretty-stack-frames*` | `20` | Max stack frames in pretty condition output (nil = unlimited) |

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| `bordeaux-threads` | Portable thread creation and semaphores |
| `atomics` | Portable CAS and atomic increment for the lock-free ring buffer |
| `dissect` | Portable stack trace capture for condition logging |
| `local-time` | Portable Unix millisecond timestamps (non-SBCL fallback) |

Compatible with any implementation supported by [atomics](https://github.com/Shinmera/atomics): SBCL, CCL, ECL, Allegro, LispWorks, CMUCL.

## Note on Symbol Shadowing

The macros `bark:trace`, `bark:debug`, `bark:warn`, and `bark:error` shadow `cl:trace`, `cl:debug`, `cl:warn`, and `cl:error`. This only matters if your package `(:use :bark)`. The recommended approach: don't `(:use :bark)` and call everything with the `bark:` prefix.

## Design Document

See [multi-output-design.md](docs/multi-output-design.md) for the full design rationale, architecture decisions, and interaction matrix.

## License

MIT. See [LICENSE](LICENSE).

## Author

[Ivan Bulanov](https://github.com/ivanbulanov)
