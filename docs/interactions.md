# Feature interactions

## Disabled by design

Buffering disables sampling. Inside `with-log-buffer`, both windowed counters and consistent samplers are bypassed. The buffer captures every log call at or above the capture level. Sampling during capture would lose entries that the `on-flush` callback or error-triggered flush might need. See [sampling.md](sampling.md) for details on the two sampling strategies.

Nested buffering is a no-op. If already inside a `with-log-buffer` scope, inner scopes run their body directly. The outermost scope controls capture level and flush policy.

## Incompatible: signals an error

`:level` + `:filter` on the same tee destination. `:level` is shorthand for a level-threshold filter. Specify one or the other.

Async parameters with function or tee output. `:capacity`, `:on-drop`, `:on-error`, `:blocking`, `:block-timeout`, and `:on-block-timeout` on `make-logger` are only valid with stream output. Function outputs are synchronous (no ring buffer or writer thread). Tee outputs configure these per-destination.

`:async nil` with queue parameters or a tee output. A stream output made with `:async nil` has no ring buffer and no writer thread, so `:capacity`, `:on-drop`, `:blocking`, `:block-timeout` and `:on-block-timeout` signal `bark-configuration-error` with it; `:on-error` is accepted and runs on the caller's thread. A tee output refuses `:async`; set it per destination.

## Contradictory settings

Sampling and blocking mode. Blocking mode (`:blocking t`) exists to prevent message loss in audit trails, compliance logs and billing events. Sampling drops messages. Do not configure both on the same logger.

## Ordering

Compile-time elimination happens before buffering. Calls below `*compile-time-min-level*` are stripped at macroexpansion time and never reach the buffer; the runtime level still governs the rest. `level-enabled-p` checks the runtime level threshold only.

Tee filters do not see context. Per-destination `:filter` functions receive the log level (integer) and per-call fields only, not static context (child logger bindings) or dynamic context (`with-context`). Context is part of formatting, not routing. To route based on identity, use separate loggers.

Sampling runs before field transforms. A sampled-out message never reaches the field transform. This means transforms cannot influence sampling decisions, sampling is based solely on the consistent hash and windowed count.

Sampling runs before tee filters. A message dropped by sampling never reaches any tee destination's filter. Tee filters cannot recover sampled-out messages.

Buffer `on-flush` sees untransformed fields. The buffer captures raw field values. The root logger's field transform is applied after `on-flush` selects which entries to emit, during the actual flush to output. Write `on-flush` callbacks against raw field names and values.
