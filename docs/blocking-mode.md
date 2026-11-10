# Blocking Mode

By default, cl-bark drops log messages when the async ring buffer is full. That suits console output and metrics, but not audit logging, compliance streams, or other sinks where message loss is not acceptable.

Blocking mode adds backpressure: when the ring buffer is full, the caller thread waits for the writer thread to drain space instead of dropping the message. A blocked call can stall its thread for up to `:block-timeout` seconds. Do not log in blocking mode from code that holds a lock others need, or from a library that must never wait on its log destination; keep the default drop mode there.

## Drop mode and drop warnings

The default. Each destination has a bounded ring buffer. When the buffer is full, messages are dropped and a warning is emitted inline. Drop warnings are formatted through the same formatter as normal log entries, so they respect configured field names, timestamp format, and level representation:

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

When a line is dropped for any reason, `bark:dropped-count` counts it; see [lifecycle.md](lifecycle.md).

## Quick Start

### Single destination

```lisp
(setf bark:*logger* (bark:make-logger :output *error-output*
                                      :blocking t))
```

### With timeout and callback

```lisp
(setf bark:*logger* (bark:make-logger :output audit-stream
                                      :blocking t
                                      :block-timeout 5.0           ; seconds (default), nil = wait forever
                                      :on-block-timeout
                                      (lambda (message stream)
                                        (format *error-output* "AUDIT DROP: ~a~%" message))))
```

### Per-destination in tee

```lisp
(setf bark:*logger* (bark:make-logger :output (bark:tee
                                                (audit-stream :blocking t
                                                              :block-timeout 5.0
                                                              :on-block-timeout #'handle-audit-drop)
                                                (*standard-output* :formatter (bark:make-pretty-formatter)))))
```

## API

### `bark:make-logger`: keyword arguments

| Keyword | Type | Default | Description |
|---------|------|---------|-------------|
| `:blocking` | `boolean` | `nil` | Enable backpressure |
| `:block-timeout` | `(or real null)` | `5.0` | Seconds to wait before dropping (coerced to `double-float`). `nil` = wait forever |
| `:on-block-timeout` | `(or function null)` | `nil` | `(lambda (message stream))` called on timeout |

Constraint: These keywords are only valid with a stream output (or the default `*error-output*`). Passing them with a `tee-output` or a function output signals `bark-configuration-error`. Configure blocking per-destination in `bark:tee` instead; function outputs are synchronous and never block. With `:async nil` there is no buffer to wait on, so these keywords signal `bark-configuration-error` there too.

### `bark:tee`: same keywords per destination

Each destination spec accepts `:blocking`, `:block-timeout`, and `:on-block-timeout` alongside the existing `:formatter`, `:filter`, `:level`, `:capacity`, `:on-drop`, and `:on-error`.

### Callback signature

```lisp
(lambda (message stream))
```

- `message`: the formatted string that could not be pushed
- `stream`: the destination stream that timed out
- Called in the caller thread
- Errors signaled by the callback are caught and reported to `*error-output*`
- The message is dropped regardless of callback outcome

## Design Properties

- Near-zero overhead when disabled. Non-blocking mode adds one boolean slot check per push and one `nil` check per writer iteration. No lock or condition variable is created.
- Per-destination. Each tee destination independently chooses blocking or dropping.
- Deadline-based timeout. Total blocking for a single log call never exceeds `:block-timeout`, even under contention.
- No message loss in blocking mode (unless timeout fires). All messages are delivered if the writer keeps up.

## Sizing Guidance

For blocking mode with N concurrent producer threads, set `:capacity >= 2N` to minimize CAS contention. Smaller buffers force more blocking events and increase producer wakeup churn.

## Edge Cases

- Writer thread dies: However the writer ends (a stream error the `:on-error` hook does not replace, or a terminated thread), its cleanup marks the output failed and wakes every blocked producer. Each one gives up at once: `:on-block-timeout` runs and the line counts as block-dropped, even with `:block-timeout nil`. Lines delivered after that are counted as dropped.
- `bark:stop` with blocked producers: All producers are woken via broadcast. Messages from producers blocked during stop go through the timeout/callback path. Call as `(bark:stop bark:*logger*)` or pass the logger returned by `bark:make-logger`.
- Tee with mixed blocking/non-blocking: If a non-blocking destination succeeds and a blocking destination times out, the message is delivered to the first but dropped for the second. The `on-block-timeout` callback fires for the failing destination.
- Synchronous outputs and the stream lock: an output made with `:async nil` (and a logger after `bark:stop`) writes on the caller's thread while holding the per-stream lock that the writer threads take for each batch. A caller can therefore wait for that lock while a writer thread or another caller writes to the same stream, and a slow stream (a full pipe, a stalled disk) blocks it for as long as the write takes. `:block-timeout` does not apply to that wait. [Which calls block or take a lock](lifecycle.md#which-calls-block-or-take-a-lock) lists every case, with finalizers and code that runs with interrupts disabled.
- `with-log-buffer` + blocking: Buffer flush replays through the root logger. If the root output is blocking, flush can block. This is correct behavior.
