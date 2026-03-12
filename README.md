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

;; Dynamic context (scoped to dynamic extent)
(bark:with-context (:request-id "req-123" :tenant "acme")
  (bark:info "processing request")
  (bark:warn "slow query" :duration-ms 1500))

;; Static context (pre-serialized, fixed for the logger's lifetime)
(let ((auth-logger (bark:child bark:*logger* :component "auth")))
  (let ((bark:*logger* auth-logger))
    (bark:info "token verified")))

;; Stop (flushes and joins writer thread)
(bark:stop)
```

## Features

- **Async I/O** — lock-free MPSC ring buffer with batch drain; bounded memory, caller never blocks
- **Multi-output (tee)** — fan-out to multiple destinations, each with its own formatter, filter, and async writer
- **Per-destination filters** — route events by level or custom predicate per destination
- **Per-destination formatters** — different formats per destination (JSON to file, pretty to console)
- **Shared formatter optimization** — when destinations share an `eq` formatter, the message is formatted once
- **Explicit logger selection** — pass a logger as first argument to any logging macro to bypass `*logger*`
- **Error recovery** — per-destination `:on-error` handler can swap streams on failure
- **Function pointer swap** — `set-level` swaps slots to `#'noop`; disabled levels cost one indirect call
- **Static context** — child logger fields serialized once at creation, zero per-call cost
- **Dynamic context** — `with-context` uses CL special variables for automatic scoping and thread isolation
- **Stack-allocated &rest** — `dynamic-extent` on per-call fields avoids heap allocation
- **Compile-time elimination** — set `*compile-time-max-level*` before compiling to strip calls entirely
- **Pluggable formatters** — JSON Lines (production), logfmt (compact), pretty (ANSI-colored REPL)
- **Counter-based sampling** — per-level 1-in-N sampling, checked before serialization
- **Field redaction** — per-logger `field-transform` drops or masks fields before serialization; composable via child loggers
- **Bounded async buffer** — configurable ring buffer capacity with drop-on-full per destination
- **Synchronous flush** — `flush-async-output` uses semaphore rendezvous, not sleep

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

### Logging Macros

```lisp
(bark:info message &rest fields)           ; uses *logger*
(bark:info some-logger message &rest fields) ; uses some-logger explicitly
```

All six macros (`trace`, `debug`, `info`, `warn`, `error`, `fatal`) accept an optional logger as the first argument. When the first argument is a `logger` struct, it is used directly. Otherwise, it is treated as the message and `*logger*` is used.

Dispatch via `logger-p` on the first argument at runtime (struct type tag check, negligible cost). When `*logger*` is nil, the call is a no-op.

### Logger Management

```lisp
;; Create a logger (sync or with custom output)
(bark:make-logger &key (name "") (level :info) (formatter #'json-formatter) output field-transform)

;; Create child logger with static context (pre-serialized fields)
(bark:child parent &rest context)

;; Change level at runtime (swaps function slots)
(bark:set-level logger level)

;; Set sampling rate (1-in-N)
(bark:set-sampling logger level rate)
```

### Lifecycle

```lisp
;; Start global async logger
(bark:start &key output (level :info) (formatter #'json-formatter)
                 (name "") (capacity 8192) (on-drop #'bark::default-on-drop)
                 context field-transform)

;; Stop and flush all writer threads
(bark:stop)
```

`:output` accepts a stream, a tee-output (from `bark:tee` or `bark:make-tee`), or NIL (defaults to `*error-output*`). When `:output` is a plain stream, `start` wraps it in an async-output. When `:output` is a tee-output, the async-outputs are already created.

`:context`, when provided, is a plist of static context fields. The root logger is wrapped in a child with these fields.

`:field-transform`, when provided, is a function `(lambda (key value) ...)` applied to every field before serialization. See [Field Redaction](#field-redaction).

### Multi-Output

#### `make-tee` (function)

```lisp
(bark:make-tee destinations) -> tee-output
```

`destinations` is a list of plists, each with the keys:

- `:stream` (required) — an output stream
- `:formatter` — a formatter function (defaults to `#'bark:json-formatter`)
- `:filter` — `(lambda (level fields) ...)` returning non-nil to pass, nil to skip
- `:level` — a level keyword; shorthand for a filter that checks `(>= level threshold)`. Mutually exclusive with `:filter`
- `:capacity` — ring buffer size in messages for this destination (defaults to 8192; rounded up to next power of two, minimum 16)
- `:on-drop` — drop handler for this destination (defaults to `#'bark::default-on-drop`)
- `:on-error` — `(lambda (condition) ...)` called in the writer thread when a stream write fails. The condition is the original condition signaled by the stream (`file-error`, `stream-error`, etc.) — bark does not wrap or translate it. Return a stream to swap and continue, or nil to exit. When omitted, the writer logs the condition to `*error-output*` and exits.

The filter receives the log level (integer) and the per-call fields (the `&rest` plist passed to `bark:info` etc.). It does **not** see static context or dynamic context — those are part of formatting, not routing.

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
                                        :on-drop (lambda (n) (format nil "LOST ~d" n)))
  ;; Errors only
  ((open "/var/log/errors.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'bark:json-formatter
                                        :level :error))
```

Specifying both `:level` and `:filter` in the same destination spec is a compile-time error.

### Context

Log output includes fields from three sources, merged in this order:

1. **Static context** — fixed fields on the logger, set once via `bark:child`. Pre-serialized at creation time; zero cost per log call.
2. **Dynamic context** — scoped fields via `bark:with-context`. Active for all log calls within the dynamic extent. Thread-isolated via CL special variables.
3. **Per-call fields** — the `&rest` arguments passed directly to `bark:info`, `bark:warn`, etc.

```lisp
;; Static context — lives on the logger
(let ((bark:*logger* (bark:child bark:*logger* :component "auth")))

  ;; Dynamic context — scoped to this body
  (bark:with-context (:request-id "req-123")

    ;; Per-call fields
    (bark:info "token verified" :user-id 42)))
;; Output merges all three: component, request-id, user-id
```

#### When to Use Each

**Child loggers** bind context at creation time — structural identity that lives for the logger's lifetime:

```lisp
;; Fixed for this component — every log carries :component automatically
(defvar *db-log* (bark:child bark:*logger* :component "database" :pool-size 10))
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

With child loggers alone, you'd need to create a new child of each logger per request, thread them through every function, and discard them after.

**Child loggers win for permanent identity.** A worker's ID is fixed for its lifetime:

```lisp
(dotimes (i pool-size)
  (let ((log (bark:child bark:*logger* :worker-id i)))
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
;; JSON: {"level":50,...,"err":{"type":"simple-error","msg":"connection refused"},"path":"/api/users","msg":"request failed"}
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
(bark:start :name "myapp" :level :info
            :field-transform (lambda (key value)
                               (case key
                                 (:password (values nil nil))
                                 (:token    "****")
                                 (t         value))))

(bark:info "login" :user "alice" :password "hunter2" :token "abc-xyz")
;; => {"level":30,...,"user":"alice","token":"****","msg":"login"}
;; :password is gone, :token is masked
```

The transform applies to **all three field sources**:

| Source | When applied |
|--------|-------------|
| Per-call fields | At log call time, before formatting |
| Dynamic context | At log call time, before formatting |
| Static context (child) | At `child` creation time, before pre-serialization |

**Inheritance.** Children inherit the parent's transform. A child can add its own via `:field-transform` in the bindings — it composes with the parent's (parent runs first, then child):

```lisp
(let* ((parent (bark:make-logger :name "app" :level :info :output stream
                                 :field-transform (lambda (key value)
                                                    (if (eq key :secret)
                                                        (values nil nil)
                                                        value))))
       ;; Child adds token masking on top of parent's secret dropping
       (child (bark:child parent :component "auth"
                                 :field-transform (lambda (key value)
                                                    (if (eq key :token)
                                                        "****"
                                                        value)))))
  (let ((bark:*logger* child))
    (bark:info "login" :user "alice" :secret "pw" :token "xyz")))
;; => :secret dropped (parent), :token masked (child)
```

**Cost.** One `funcall` per field when the slot is non-nil. When nil (the default), zero overhead — the transform check is a null-pointer test in the hot path.

### Formatters

A formatter is a function with signature:
```
(level static-context-str static-context-plist dynamic-context message fields) -> string
```

Built-in formatters:
- `bark:json-formatter` — JSON Lines (default, production)
- `bark:logfmt-formatter` — `key=value` pairs
- `bark:pretty-formatter` — ANSI-colored for REPL

**Supported field value types:**

| Type | JSON | logfmt | pretty |
|------|------|--------|--------|
| `string` | `"escaped"` | `bare` or `"quoted"` | as-is |
| `integer` | `123` | `123` | as-is |
| `float` | `3.14` | `3.14` | as-is |
| `ratio` | `0.333` | `0.333` | as-is |
| `t` | `true` | `true` | as-is |
| `nil` | `null` | `null` | as-is |
| `symbol` | `"lowercase"` | `lowercase` | as-is |
| `list` | `["a","b"]` | `"(a b)"` | as-is |
| `vector` | `[1,2,3]` | `"#(1 2 3)"` | as-is |
| `hash-table` | `{"k":"v"}` | `"#<HASH-TABLE ...>"` | as-is |
| `pathname` | `"/var/log/app.jsonl"` | `/var/log/app.jsonl` | as-is |
| `condition` | `{"type":"...","msg":"..."}` | `"type: msg"` | type: msg |
| `captured-error` | `{"type":"...","msg":"...","stack":[...]}` | `"type: msg"` | type: msg + stack |
| everything else | `"princ-to-string"` | `"princ-to-string"` | as-is |

All types are accepted — no log call ever signals `type-error`. Ratios are coerced to `double-float`. For JSON: lists serialize as arrays (including dotted pairs), pathnames as strings, vectors as arrays, hash-tables as objects. For logfmt: collections and complex types are quoted via `princ-to-string`. The fallback for all other types is `princ-to-string` — specialize `print-object` on your classes to control their log representation.

### Sampling

```lisp
;; Log 1 in 100 debug messages
(bark:set-sampling bark:*logger* :debug 100)
```

### Backpressure

The async writer uses a bounded ring buffer per destination. When the buffer is full, messages are dropped and a warning is emitted inline:

```json
{"level":40,"msg":"bark: dropped 153 log messages (output too slow)"}
```

Control per destination:

```lisp
(bark:tee
  (*error-output* :capacity 65536)  ; larger buffer (messages, not bytes)
  (log-file       :on-drop (lambda (n) (format nil "DROPPED ~d" n))))  ; custom handler
```

Or globally when using a single output:

```lisp
(bark:start :capacity 65536 :on-drop (lambda (n) (format nil "DROPPED ~d" n)))
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

## Usage Examples

### Mirror: Console + File

Same events, different formats. The most common multi-output scenario.

```lisp
(defvar *log-file* (open "/var/log/app.jsonl"
                         :direction :output :if-exists :append
                         :if-does-not-exist :create))

(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter)
                     (*log-file*     :formatter #'bark:json-formatter)))

(bark:info "request handled" :status 200)
;; => pretty-printed to stderr
;; => JSON line to log file
```

### Level-Based Routing

All events to console, errors only to a separate file.

```lisp
(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter)
                     (*error-file*   :formatter #'bark:json-formatter
                                     :level :error)))

(bark:info "all good")           ; console only
(bark:error "disk full" :vol 3)  ; console + error file
```

### Content-Based Routing

Audit events to a dedicated stream based on a per-call field.

```lisp
(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:json-formatter)
                     (*audit-file*   :formatter #'bark:json-formatter
                                     :filter (lambda (level fields)
                                               (declare (ignore level))
                                               (getf fields :audit)))))

(bark:info "page loaded" :path "/home")                     ; console only
(bark:info "user login" :audit t :user-id 42 :method "sso") ; console + audit file
```

### Two Independent Loggers

Explicit logger arg bypasses `*logger*`. Each logger has its own output pipeline.

```lisp
(bark:start :name "app" :level :info)

(defvar *audit-logger*
  (bark:make-logger :name "audit" :level :info
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
| **Output override on `child`** | `child` is for adding static context, not rerouting. Mixing these concerns complicates the mental model. | Use a separate logger with its own output for different routing. |
| **Named logger registry** | Global mutable registries add implicit coupling. CL already has `defvar` and `defparameter`. | Manage logger variables yourself: `(defvar *audit-logger* (bark:make-logger ...))`. |
| **Structured data in ring buffer** | Formatting in the caller thread keeps the writer thread trivial (just `write-string` + `force-output`). Deferring formatting to the writer would serialize all format work on a single thread. | This is a deliberate architectural choice for throughput. |
| **Output as a user-visible object** | The tee's internal representation (`tee-output`, `destination`, `formatter-group`) is an implementation detail. | Use `make-tee`/`tee` to create outputs. Inspect via the logger's output slot if needed for debugging. |

## Conditions

All conditions are signaled at configuration time. Logging macros never signal — a disabled level is a `noop` call, and writer errors are handled internally.

| Source | Condition | When |
|--------|-----------|------|
| `level-from-keyword` | `type-error` | Unknown level keyword (from `ecase`) |
| `set-level` | `type-error` | Level is neither `fixnum` nor keyword (from `etypecase`) |
| `make-tee` | `simple-error` | Both `:filter` and `:level` on the same destination |
| `tee` | `simple-error` | Same, at macro expansion time |
| `start` | `simple-error` | `:output` is not a stream, `tee-output`, or `nil` |

Writer thread stream errors (`file-error`, `stream-error`, etc.) are caught internally. When `:on-error` is provided, it receives the original condition — see [Error Recovery](#error-recovery). Otherwise the error is logged to `*error-output*` and the writer exits.

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

### Performance Characteristics

| Operation | Cost |
|-----------|------|
| Log call (level disabled) | ~2ns (indirect call to `noop`) |
| Log call (level enabled, async) | ~500ns-2us (formatting) + ~30ns (CAS + semaphore signal) |
| Log call (level enabled, tee, N dest) | ~500ns-2us per unique formatter + ~30ns x N (push + signal) |
| Log call (buffer full, drop) | ~20ns (atomic-incf dropped) — formatting skipped |
| Writer drain (per message) | ~50ns (pop + write-string) |
| Explicit logger dispatch | ~1ns (struct type tag check on first argument) |
| Field transform (per field) | ~10ns (funcall) — only when transform is non-nil |

Formatting dominates the hot path. The ring buffer overhead (CAS + semaphore) is <5% of total log call time. The shared formatter optimization reduces tee overhead when destinations share a formatter.

## Globals

| Variable | Purpose |
|----------|---------|
| `bark:*logger*` | Current logger (bind per-thread or globally) |
| `bark:*log-context*` | Dynamic context (managed by `with-context`) |
| `bark:*compile-time-max-level*` | When positive, compiler macros eliminate calls below this level |
| `bark:*max-json-stack-frames*` | Max stack frames in JSON condition output (default 10, nil = unlimited) |
| `bark:*max-pretty-stack-frames*` | Max stack frames in pretty condition output (default 20, nil = unlimited) |

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
