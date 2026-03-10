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
- **Function pointer swap** — `set-level` swaps slots to `#'noop`; disabled levels cost one indirect call
- **Static context** — child logger fields serialized once at creation, zero per-call cost
- **Dynamic context** — `with-context` uses CL special variables for automatic scoping and thread isolation
- **Stack-allocated &rest** — `dynamic-extent` on per-call fields avoids heap allocation
- **Compile-time elimination** — set `*compile-time-max-level*` before compiling to strip calls entirely
- **Pluggable formatters** — JSON Lines (production), logfmt (compact), pretty (ANSI-colored REPL)
- **Counter-based sampling** — per-level 1-in-N sampling, checked before serialization
- **Bounded async buffer** — configurable ring buffer capacity with drop-on-full; dropped messages are reported inline
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

### Logging

```lisp
(bark:trace message &rest fields)
(bark:debug message &rest fields)
(bark:info  message &rest fields)
(bark:warn  message &rest fields)
(bark:error message &rest fields)
(bark:fatal message &rest fields)
```

Each macro expands to a nil-guarded funcall: when `*logger*` is nil the call is a no-op, otherwise it dispatches to `(logger-<level>-fn *logger*)`. When the level is disabled, the function slot is `#'noop`.

### Logger Management

```lisp
;; Create a logger (sync or with custom output)
(bark:make-logger &key (name "") (level :info) (formatter #'json-formatter) output)

;; Create child logger with static context (pre-serialized fields)
(bark:child parent &rest context)

;; Change level at runtime (swaps function slots)
(bark:set-level logger level)
```

### Lifecycle

```lisp
;; Start global async logger
(bark:start &key (stream *error-output*) (level :info) (formatter #'json-formatter)
                 (name "") (capacity 8192) (on-drop #'bark::default-on-drop))

;; Stop and flush
(bark:stop)
```

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

### Formatters

A formatter is a function with signature:
```
(level static-context-str static-context-plist dynamic-context message fields) -> string
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

### Backpressure

The async writer uses a bounded ring buffer. When the buffer is full (output stream too slow), messages are dropped and a warning is emitted inline:

```json
{"level":40,"msg":"bark: dropped 153 log messages (output too slow)"}
```

Control the buffer size and drop behavior:

```lisp
;; Larger buffer (default 8192, rounded up to next power of two)
(bark:start :capacity 65536)

;; Custom drop handler (receives count, returns a string or NIL to suppress)
(bark:start :on-drop (lambda (n) (format nil "DROPPED ~d" n)))

;; Suppress drop warnings entirely
(bark:start :on-drop (lambda (n) (declare (ignore n)) nil))
```

### Compile-Time Elimination

```lisp
;; Before compiling application code:
(setf bark:*compile-time-max-level* 30)  ; strip trace and debug at compile time
```

### Testing

All logging macros are safe to call when `bark:*logger*` is nil — they silently no-op. This means test code that exercises logging call sites can run without initializing a logger:

```lisp
;; No logger setup needed — log calls are silently ignored
(defun my-function ()
  (bark:info "processing" :step 1)
  (do-work)
  (bark:debug "done"))

(test my-function-works
  ;; bark:*logger* is nil here — log calls are harmless no-ops
  (is (expected-result-p (my-function))))
```

To capture and assert on log output, use `with-captured-logs` which binds a temporary logger:

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
| `bark:*log-context*` | Dynamic context plist (managed by `with-context`) |
| `bark:*compile-time-max-level*` | When positive, compiler macros eliminate calls below this level |

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| `bordeaux-threads` | Portable thread creation and semaphores |
| `atomics` | Portable CAS and atomic increment for the lock-free ring buffer |
| `local-time` | Portable Unix millisecond timestamps |

Compatible with any implementation supported by [atomics](https://github.com/Shinmera/atomics): SBCL, CCL, ECL, Allegro, LispWorks, CMUCL.

## Note on Symbol Shadowing

The convenience macros `bark:trace`, `bark:debug`, `bark:warn`, and `bark:error` shadow `cl:trace`, `cl:debug`, `cl:warn`, and `cl:error`. This only matters if your package `(:use :bark)`. In that case, either shadow-import the ones you need:
```lisp
(:shadowing-import-from :bark #:error #:warn #:trace #:debug)
```
Or — the recommended approach — don't `(:use :bark)` and call everything with the `bark:` prefix.

## Async Architecture

### Ring Buffer

The async output path uses a lock-free MPSC (multi-producer, single-consumer) ring buffer:

```
Producer threads              Writer thread
     │                              │
     ├─ format message              │
     ├─ CAS claim slot in ring ──►  │
     ├─ write string to slot        ├─ pop slots in batch
     └─ signal semaphore            ├─ write-string to stream
                                    ├─ force-output
                                    ├─ check drop counter
                                    └─ sleep/wait on semaphore
```

**Ring buffer internals:**
- Pre-allocated `simple-vector` of size 2^N (minimum 16)
- `head` (write cursor) and `tail` (read cursor) are `(unsigned-byte 64)` slots; producers use `atomics:cas` to claim a slot and `atomics:atomic-incf` to record drops
- Producers CAS-loop on `head` to claim a slot, then write the formatted string. If `head - tail >= capacity`, the message is dropped and `dropped` is atomically incremented
- The consumer (single writer thread) reads sequentially from `tail`, spinning briefly if a producer has claimed a slot but hasn't written yet (uses `sb-ext:spin-loop-hint` on SBCL)
- `mask` = capacity - 1 enables `logand` instead of `mod` for index calculation

**Flush protocol:** `flush-async-output` creates a fresh `bt:semaphore`, stores it in the `flush-ack` slot, signals the writer's `notify` semaphore, then blocks on the ack. The writer checks `flush-ack` at the end of each drain cycle and signals it after processing.

**Drop reporting:** After each drain cycle, the writer atomically reads and resets the `dropped` counter. If non-zero, it calls the `on-drop` function (default: `default-on-drop`) which returns a warning string written inline to the output stream. This ensures drop notifications appear in the same log pipeline the user is consuming.

**Shutdown:** `stop-async-output` flushes first (guaranteeing all queued messages and any drop warning are written), sets `running` to nil, signals the writer, joins the thread, then does a final drain of any messages that arrived between flush and shutdown.

### Performance Characteristics

| Operation | Cost |
|-----------|------|
| Log call (level disabled) | ~2ns (indirect call to `noop`) |
| Log call (level enabled, async) | ~500ns–2μs (formatting) + ~30ns (CAS + semaphore signal) |
| Log call (buffer full, drop) | ~500ns–2μs (formatting) + ~20ns (atomic-incf dropped) |
| Writer drain (per message) | ~50ns (pop + write-string) |

Formatting dominates the hot path. The ring buffer overhead (CAS + semaphore) is <5% of total log call time.

## Design Document

See [cl-bark-design.md](../funhouse-mcp/docs/plans/2026-02-26-cl-bark-design.md) for the full design rationale, architecture diagrams, and v1.1 roadmap.
