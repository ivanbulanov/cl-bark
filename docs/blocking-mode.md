# Blocking Mode

By default, cl-bark drops log messages when the async ring buffer is full. This is correct for most use cases (console output, metrics) but unacceptable for audit logging, compliance streams, and other sinks where message loss cannot be tolerated.

Blocking mode adds optional backpressure: when the ring buffer is full, the caller thread waits for the writer thread to drain space instead of dropping the message.

## Quick Start

### Single destination

```lisp
(bark:start :output *error-output*
            :blocking t)
```

### With timeout and callback

```lisp
(bark:start :output audit-stream
            :blocking t
            :block-timeout 5.0           ; seconds (default), nil = wait forever
            :on-block-timeout
            (lambda (message stream)
              (format *error-output* "AUDIT DROP: ~a~%" message)))
```

### Per-destination in tee

```lisp
(bark:start :output (bark:tee
                      (audit-stream :blocking t
                                    :block-timeout 5.0
                                    :on-block-timeout #'handle-audit-drop)
                      (*standard-output* :formatter #'bark:pretty-formatter)))
```

## API

### `bark:start` — new keyword arguments

| Keyword | Type | Default | Description |
|---------|------|---------|-------------|
| `:blocking` | `boolean` | `nil` | Enable backpressure |
| `:block-timeout` | `(or real null)` | `5.0` | Seconds to wait before dropping. `nil` = wait forever |
| `:on-block-timeout` | `(or function null)` | `nil` | `(lambda (message stream))` called on timeout |

**Constraint:** These keywords cannot be used when `:output` is a `tee-output`. Configure blocking per-destination in `bark:tee` instead.

### `bark:tee` — same keywords per destination

Each destination spec accepts `:blocking`, `:block-timeout`, and `:on-block-timeout` alongside the existing `:formatter`, `:filter`, `:level`, `:capacity`, `:on-drop`, and `:on-error`.

### Callback signature

```lisp
(lambda (message stream))
```

- `message`: the formatted string that could not be pushed
- `stream`: the destination stream that timed out
- Called in the **caller** thread
- Errors signaled by the callback are caught and reported to `*error-output*`
- The message is dropped regardless of callback outcome

## Design Properties

- **Zero overhead when disabled.** Non-blocking mode adds one `nil` check on the drop path and one `nil` check per writer iteration. No OS resources allocated.
- **Per-destination.** Each tee destination independently chooses blocking or dropping.
- **Deadline-based timeout.** Total blocking for a single log call never exceeds `:block-timeout`, even under contention.
- **No message loss in blocking mode** (unless timeout fires). All messages are delivered if the writer keeps up.

## Sizing Guidance

For blocking mode with N concurrent producer threads, set `:capacity >= 2N` to minimize CAS contention. Smaller buffers force more blocking events and increase producer wakeup churn.

## Edge Cases

- **Writer thread dies:** Blocked producers hang until timeout fires.
- **`bark:stop` with blocked producers:** All producers are woken via broadcast. Messages from producers blocked during stop go through the timeout/callback path.
- **Tee with mixed blocking/non-blocking:** If a non-blocking destination succeeds and a blocking destination times out, the message is delivered to the first but dropped for the second. The `on-block-timeout` callback fires for the failing destination.
- **`with-log-buffer` + blocking:** Buffer flush replays through the root logger. If the root output is blocking, flush can block. This is correct behavior.
