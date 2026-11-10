# Request-scoped buffering

Buffer log calls and decide at scope exit which to emit. The default: on success, emit entries at or above the logger's configured level. On failure (unhandled condition), emit everything, including debug and trace.

`with-log-buffer` takes a logger argument, binds it to `*logger*` as a buffer-logger for the body's dynamic extent, and flushes through the original logger on exit. Only implicit log calls (through `*logger*`) are buffered; log calls that pass an explicit logger argument bypass the buffer, because they don't go through `*logger*`.

```lisp
;; Buffer a per-request child logger
(bark:with-log-buffer ((bark:make-child root-logger :context (list :request-id id)))
  (bark:debug "parsing body" :content-type ct)
  (bark:info "processing" :path path)
  (process request))
;; Success: only :info emitted. Error: all entries emitted, then error propagates.
```

Parameters:

- `logger` (required): the logger to buffer and flush through.
- `level`: capture threshold (default `:trace`). The logger's level is lowered to this inside the scope.
- `on-flush`: optional `(lambda (entries condition normal-exit-p) ...)`. Returns a sequence of entries to emit.

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

Semantics:

- Normal exit: filter to entries >= logger's original level.
- Abnormal exit (unhandled condition): emit all entries.
- Non-condition unwind (`return-from`, `throw`): treated as normal exit.
- Handled errors (caught by `handler-case` inside body): normal exit.
- Explicit logger args (`(bark:info *audit-logger* "msg")`) bypass the buffer.
- Nesting is a no-op. If already inside a `with-log-buffer` scope, inner scopes run their body directly with no additional buffering. The outermost scope controls capture level and flush policy. This prevents bugs with wrong flush targets, lost context, and out-of-order output that would arise from independent nested buffers.

Buffer entries are structs with accessors for `on-flush` callbacks:

- `bark:buffer-entry-level`: numeric level
- `bark:buffer-entry-message`: log message
- `bark:buffer-entry-fields`: per-call fields plist
- `bark:buffer-entry-context`: snapshot of dynamic context
- `bark:buffer-entry-timestamp`: millisecond timestamp from log time

Timestamps: Flushed entries carry their original log-time timestamps. User-defined formatters should call `bark:current-log-timestamp-ms` instead of computing their own to get correct timestamps during replay.

Compile-time elimination: calls stripped by `*compile-time-min-level*` expand to `nil` and never reach the buffer; the runtime level still governs every call that remains.
