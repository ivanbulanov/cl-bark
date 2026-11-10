# Lifecycle and conditions

```lisp
;; Create logger and assign to the global
(setf bark:*logger*
      (bark:make-logger &key output (level :info) (formatter bark:*default-json-formatter*)
                             context field-transform
                             (capacity 8192) (on-drop #'bark:default-on-drop) on-error
                             blocking (block-timeout 5.0) on-block-timeout
                             level-sampler consistent))

;; Create child logger with static context (pre-serialized fields)
;; Children share the parent's output, no threads, no cleanup needed (just let GC collect).
;; Do not call bark:stop on a child; always stop the root logger.
;; A child has no sampler or rate limit of its own: it shares the parent's level-sampler vector (windowed counters
;; and their budget), so a noisy child spends the parent's budget.
(bark:make-child parent &key context field-transform level)

;; Change level at runtime (swaps function slots)
(bark:set-level logger level)

;; Read the level back as a keyword (:trace through :fatal; NIL for a nil logger)
(bark:current-level logger)

;; Set per-level sampling (windowed-counter, or nil to remove)
(bark:set-level-sampler logger level windowed-counter)

;; Flush pending messages (blocks until written)
(bark:flush logger)

;; Stop and flush all writer threads (blocks until drained, idempotent; returns T when every writer exited cleanly)
(bark:stop logger)

;; Async outputs are drained automatically at image exit; no registration is needed
```

`bark:make-logger` is the main entry point. It creates a logger and returns it, assign it to `bark:*logger*` or any other variable. The output type determines whether async I/O is used:

| `:output` value | Behavior |
|---|---|
| Stream | Wrapped in async-output (background thread + ring buffer) |
| Function | Called synchronously, no thread, no buffer |
| `tee-output` | Used as-is (already contains async-outputs internally) |
| NIL | Defaults to `*error-output*`, wrapped in async-output |

`:output` accepts a stream, a function, a tee-output (from `bark:tee` or `bark:make-tee`), or NIL. Async-specific parameters (`:capacity`, `:on-drop`, `:on-error`, `:blocking`, `:block-timeout`, `:on-block-timeout`) are only valid for stream outputs. Passing them with a function or tee-output signals `bark-configuration-error`.

`:context`, when provided, is a plist of static context fields pre-serialized into the root logger. Zero per-call cost.

`:field-transform`, when provided, is a function `(lambda (key value) ...)` applied to every field before serialization. See [Field Redaction](context.md#field-redaction).

`bark:stop` flushes and joins all writer threads for the given logger. Blocks until the queue is drained and threads have exited. Idempotent, stopping an already-stopped or sync logger is a no-op. Calling on a child logger signals `bark-child-operation-error`; the `continue` restart makes `stop` return NIL. Always stop the root logger.

`bark:flush` blocks until all pending messages in the logger's async output are written to their streams. Accepts any logger, global or user-created. Handles both single-output and tee-output loggers. Signals `bark-async-stopped` if any async output has been stopped (a `continue` restart is available to skip stopped outputs).

Every async output is drained automatically when the image exits, waiting at most `bark:*exit-flush-timeout*` (default 2.0 seconds) per output.

`bark:dropped-count` returns how many lines the async outputs of a logger have dropped so far (full buffer, failed writer, and blocking-mode timeouts), summed over its outputs. The count only grows: lines already announced by a drop warning stay in it, and reading it resets nothing. It returns 0 for NIL and for a synchronous (function) logger.

```lisp
(bark:dropped-count bark:*logger*)
```

## Saving a core with `save-lisp-and-die`

SBCL refuses to save a core while other threads run, and a writer thread would not survive the save anyway. cl-bark installs a function on `sb-ext:*save-hooks*` that drains and joins the writer thread of every running async output, and a function on `sb-ext:*init-hooks*` that starts the writer threads again in the restored image, so no call is needed from the application and no lines are lost.

- Only outputs that were running at save time are restarted. An output stopped earlier with `bark:stop` stays stopped (synchronous writes), and a failed one stays failed.
- Between the save hook and the end of the save, and until the init hook has run, lines are written synchronously on the caller's thread.
- Standard streams: an output whose stream is `sb-sys:*stdout*` or `sb-sys:*stderr*` is rebound to SBCL's freshly created standard stream, because the old stream object is stale in the restored image. Synonym streams (`*standard-output*`, `*error-output*`) keep working as they are.
- File streams: the descriptor does not survive a save, so an output on a file stream (a `file-stream` with a pathname) is reopened for appending by the init hook, with the same external format. If the file cannot be reopened, the output is marked failed and later lines count as dropped (see `bark:dropped-count`). Any other stream (string streams, sockets, pipes) is kept as it is and is not valid in the restored image unless it survives a save by itself; give such an output an `:on-error` handler, or stop the logger before saving and make a new one after the restore.
- If `save-lisp-and-die` fails after the save hook ran (for example because an unrelated thread is running), the outputs stay stopped and write synchronously until the init hook runs; the process keeps logging.
- A logger created before the save and held by a global variable keeps working after the restore; a logger no longer referenced is not restarted.

`bark:flush` and `bark:stop` accept `:timeout` (seconds per async output, default 5.0). `bark:flush` returns T when every running async output acknowledged and NIL on timeout; `bark:stop` returns T when every writer exited cleanly and NIL otherwise.

## Conditions

All bark-specific conditions inherit from `bark:bark-error` (which inherits from `cl:error`):

```
bark-error                           ; base, all bark errors
├── bark-configuration-error         ; invalid constructor arguments
│     slot: detail (string)          ; human-readable explanation
└── bark-lifecycle-error             ; operation invalid for current state
    ├── bark-async-stopped           ; flush on stopped async output
    └── bark-child-operation-error   ; root-only op attempted on child
          slot: operation (symbol)   ; the attempted operation (e.g. :stop)
```

Conditions are signaled at configuration time or on lifecycle misuse. Logging macros never signal, a disabled level is a `noop` call, and writer errors are handled internally.

| Source | Condition | Restart | When |
|--------|-----------|---------|------|
| `make-logger`, `set-level`, `level-enabled-p`, `set-level-sampler`, `make-tee` | `bark-configuration-error` | none | Unknown level keyword or out-of-range level number |
| `make-json-formatter`, `make-logfmt-formatter`, `make-pretty-formatter` | `bark-configuration-error` | none | Unknown `:timestamp` or `:level-format` value |
| `make-formatter` | `bark-configuration-error` | none | `:format-fn` missing |
| `make-consistent-sampler` | `bark-configuration-error` | none | `:key-fn` is not a function |
| `make-logger` | `bark-configuration-error` | none | `:formatter` given together with a tee output |
| `make-tee` | `bark-configuration-error` | none | `:stream` is not a stream |
| `make-tee` | `bark-configuration-error` | none | Both `:filter` and `:level` on the same destination |
| `tee` | `bark-configuration-error` | none | Same, at macro expansion time |
| `make-logger` | `bark-configuration-error` | none | `:output` is not a stream, function, `tee-output`, or `nil` |
| `make-logger` | `bark-configuration-error` | none | Async parameters with a function or `tee-output` |
| `make-consistent-sampler` | `bark-configuration-error` | none | Rate < 1 |
| `make-level-sampler` | `bark-configuration-error` | none | Non-windowed-counter value |
| `make-windowed-counter` | `bark-configuration-error` | none | Window ticks exceed fixnum range |
| `stop` | `bark-child-operation-error` | `continue` (returns NIL) | Called on a child logger |
| `flush` | `bark-async-stopped` | `continue` | Called on a stopped logger |

### Handling conditions

Selective handling by condition type:

```lisp
;; Catch only configuration errors, let lifecycle errors propagate
(handler-case (bark:make-logger :output 42)
  (bark:bark-configuration-error (c)
    (log:warn "Bad logger config: ~A" (bark:bark-configuration-error-detail c))
    (bark:make-logger)))  ; fall back to defaults
```

### Using restarts

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

### Writer thread errors

Writer thread stream errors (`file-error`, `stream-error`, etc.) are caught internally. When `:on-error` is provided, it receives the original condition, see [Error Recovery](multi-output.md#error-recovery). Otherwise the error is logged to `*error-output*` and the writer exits. If the `:on-error` handler itself signals, or an `:on-block-timeout` callback signals, those errors are also caught and written to `*error-output*`, the writer thread never propagates exceptions to the caller.
