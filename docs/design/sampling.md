# cl-bark Sampling Design

cl-bark has two sampling strategies that run inside the log call, before any formatting or
buffering: a per-level windowed counter that passes a burst and then a trickle, and a per-logger
consistent hash sampler that keeps or drops every event sharing a key. Both are lock-free, both
are configured on the logger (samplers are passed to `make-logger`; there is no `bark:start`),
and dropped events are silent. The user guide ([../sampling.md](../sampling.md)) covers usage,
window sizing and [caveats](../sampling.md#caveats); this document explains the shape behind them.

## Motivation

A service logging at `:debug` can emit far more lines than an output absorbs. The async ring
buffer absorbs short bursts, but once full it drops by position in time, not by value. Three
needs follow: volume per level (trace and debug are noisy, errors must not be lost); burst shape
(the first N messages of an incident show its trigger, the thousandth identical one adds little);
and completeness per request (a random subset of one request's lines is hard to use).

These are different problems, so there are two mechanisms. The windowed counter addresses the
first two, per level. The consistent sampler addresses the third, per logger, keyed on a value
from the logger's static context. A dropped event costs no serialization and no buffer slot.

## Design Summary

A `windowed-counter` is held per level in the logger's `level-sampler` vector and passes the
first `initial` events per window, then every `thereafter`-th. A `consistent-sampler` is held in
the logger's `consistent` slot and keeps or drops all events sharing a key. The constructors
`make-windowed-counter`, `make-level-sampler` and `make-consistent-sampler` validate arguments;
`set-level-sampling` and `set-consistent` replace samplers at runtime; `make-logger` takes
`:level-sampler` and `:consistent`. Both slots default to nil (two nil checks per call). All
code is in `src/logger.lisp`.

Sampling lives in the closure `make-log-fn` builds per level, in this order: the level gate
(disabled levels are `#'noop`, so sampling is never entered); the consistent sampler (a keep
skips the windowed counter, a drop returns `(values)`, no key or no sampler falls through); the
windowed counter for this level (a false `windowed-allow-p` returns `(values)`); then field
transform, formatter and `dispatch-to-output` (tee, ring buffer). The decision code sits before
the check for an output, so sampling still runs when the logger has no output.

## Data Structures

`windowed-counter` has read-only `initial`, `thereafter` (after the burst, pass 1-in-N by
absolute position; 0 passes nothing) and `window-ticks` (fixnums, window length in
`internal-time-units-per-second` units), plus mutable `count` (`(unsigned-byte 64)`, atomic
increment, plain reset, counts passed and dropped events) and `window-start` (fixnum,
`get-internal-real-time` reading, changed by CAS).

`make-windowed-counter` takes `:initial` (default 5), `:thereafter` (default 100) and
`:window-seconds` (default 1). It rounds seconds to ticks, signals `bark-configuration-error`
with a `use-value` restart if the ticks exceed `most-positive-fixnum`, and starts `window-start`
at the current clock reading. Starting at 0 would make the first clock check find the window long
expired and reset at once, passing up to twice `initial` in a startup burst.

`consistent-sampler` has `key-fn` (static context plist in, key or nil out) and `rate`
(`(integer 1)`, keep 1-in-N keys). `make-consistent-sampler` defaults `:rate` to 1 (keep every
keyed event) and signals `bark-configuration-error` below 1.

Configuration slots are `:read-only t`: to change a parameter, build and install a new struct.

`level-sampler` is nil or a simple-vector of `+level-slot-count+` (7) entries, each nil or a
`windowed-counter`. Index 0 is unused; indices 1 to 6 are trace to fatal, so the level value
(1 to 6) is the vector index directly. A nil entry means that level is not sampled; keep errors
by configuring nothing for `:error`.

## The Hot Path

Per call, the closure takes `count` from `(atomics:atomic-incf (windowed-counter-count wc))`,
checks the clock when `count` is a multiple of the interval, then asks `windowed-allow-p`.
`atomics:atomic-incf` returns the post-increment value, so counts start at 1 and exactly
`initial` messages pass. Every thread gets a distinct count, which makes the arithmetic exact
between resets. The `(unsigned-byte 64)` slot type is what SBCL's atomic increment requires.

`windowed-allow-p` is `(or (<= count initial) (and (plusp thereafter) (zerop (mod count
thereafter))))`:

- Counts 1 through `initial` pass.
- After the burst an event passes when `count` is a multiple of `thereafter`, an absolute
  position in the window, not relative to the burst end (the same rule as Go zap). With `initial`
  5 and `thereafter` 100, messages 6 to 99 are dropped (94 messages) before 100 passes.
- `initial` 0 means no burst. `thereafter` 0 (or negative) passes nothing after the burst until
  reset; `(plusp thereafter)` also guards `mod` against a zero divisor.
- `count` advances for dropped events too: it is a window position, not a tally of kept events.

The clock is read only when `count` is a multiple of `+window-check-interval+`, a `defconstant`
of 64. It must be a power of two because the code masks with `logand` of the interval minus one;
changing it needs a recompile. Consequences:

- **Expiry is detected late, in events, not in time.** A counter seeing fewer than 64 events per
  window renews its burst only when its 64th event arrives. The effective window is the larger of
  `window-seconds` and the time to the next multiple of 64.
- **The checking event is judged on the old window.** The reset runs before `windowed-allow-p`,
  but the closure still holds the pre-reset count; the next event sees count 1.

`maybe-reset-window` resets an expired window with a CAS on `window-start` (one resetter wins, a
loser does nothing) and then a plain `setf` of `count` to 0. The reset is not atomic with
surrounding increments: threads may judge against the stale count in between, and an increment
concurrent with the `setf` can be erased. The error per boundary is roughly the check interval
plus the thread count.

## The Consistent Hash

`consistent-hash-keep-p` is `(zerop (mod (mix-hash (sxhash key)) rate))`: a pure function of key
and rate, with no per-key state, cache or table, so nothing to synchronize or evict. Every logger
sharing the sampler gives the same answer for equal keys.

`sxhash` promises nothing about low-bit distribution, which `mod rate` uses, so `mix-hash`
(a multiply-xorshift finalizer) mixes it: `h ^= h >> 16`; multiply by 2654435769, truncated with
`ldb` to `(integer-length most-positive-fixnum)` bits; `h ^= h >> 13`. The `ldb` keeps the
product in fixnum range so SBCL avoids bignum arithmetic. It is inline, not cryptographic, and
`test-mix-hash-distribution` in `tests/tests.lisp` runs a chi-squared check on it.

Only strings, symbols and numbers give a stable decision; `sxhash` determinism across restarts is
an SBCL property, not a Common Lisp guarantee. The "no key" signal is exactly `nil`: `0` and `""`
are valid keys with one fixed hash, so a `key-fn` that returns them for "missing" silently
disables the windowed counter for those events and applies one constant decision.

`key-fn` receives `(logger-context lgr)`, the logger's static context plist after the field
transform (applied when `make-logger` or `make-child` stores the context). For a child it is the
parent's context followed by its own. It never receives per-call fields or `with-context` values
(`*log-context*`), so a request-scoped child logger carrying the key is the intended carrier.
`getf` scans linearly, so put the key early.

## Inheritance and Runtime Replacement

`make-child` passes the parent's `level-sampler` and `consistent` straight to the child; nothing
is copied.

- The `level-sampler` vector and the counters in it are shared, so parent and children draw from
  one count per level. `set-level-sampling` on either writes into the shared vector
  (`test-child-inherits-level-sampler`).
- `set-consistent` replaces only that logger's slot; existing children keep the old sampler
  (`test-child-snapshots-consistent`).
- If the parent's vector was nil at child creation, a later `set-level-sampling` on the parent
  allocates a fresh vector in the parent only; the child is never sampled by it.
- A vector passed to `:level-sampler` is the caller's object, shared by every logger given it.

Configure samplers on the root before creating children. `set-level-sampling` takes a fixnum or
keyword level (`level-from-keyword`), the fixnum being the index. If a vector exists it writes in
place with one `setf aref`. If none exists it
allocates one and installs it with `atomics:cas` from nil; a CAS loser loops and writes into the
winner's vector, so no update is lost (`test-set-level-sampling-cas-race`). The vector is never
replaced once it exists, which is what lets children share it. Concurrent writers to the same
index are last-writer-wins. A replacement counter restarts that level's window. `set-consistent`
is a single slot write; nil removes the sampler.

## Thread Safety

The count is exact between resets and the window reset is approximate (see above). The consistent
decision is a pure function. Slot reads and the setters' writes are plain word-sized operations
(last writer wins), and vector creation is a CAS from nil. This assumes word-sized loads and
stores are atomic, which holds on SBCL's supported targets. Nothing in the sampling path takes a
lock or allocates.

## Alternatives Considered

- **Sampling before the level gate.** Rejected: every disabled-level call would pay a counter
  increment, and disabled counters would change state.
- **Both strategies must agree.** Rejected: a windowed counter after a keep decision thins a
  request the hash selected. A found key makes the hash final; `rate` controls keyed volume.
- **Token bucket.** Rejected: the ring buffer already absorbs I/O bursts, and a bucket gives no
  guaranteed first N after a quiet period.
- **Per-key decision state (LRU, bloom filter).** Rejected: a stateless hash gives the same
  consistency without memory, eviction or synchronization.
- **Mutex instead of CAS.** Rejected: every logging thread would serialize on it.
- **Per-destination sampling.** Rejected: decisions precede formatting and the tee fan-out. Use
  tee `:level` and `:filter` ([multi-output.md](multi-output.md)) or separate loggers.
- **Probabilistic sampling as a level-sampler type.** Not integrated: the constructors accept
  only windowed counters and the hot path increments `count` directly, so a second type needs a
  `typecase` there. It adds neither a guaranteed burst nor per-request completeness.

## Invariants and Trade-offs

Invariants:

- With both slots nil, a log call does no sampling work beyond two nil checks.
- Evaluation order is level gate, consistent sampler, windowed counter. A non-nil `key-fn` result
  makes the consistent decision final; the windowed counter is neither read nor incremented.
- Equal keys under the same rate get the same decision from every logger sharing the sampler.
- Absent a reset race, exactly `initial` events pass per window, plus multiples of `thereafter`.
- A level whose entry is nil, or a logger whose vector is nil, is never sampled.

Trade-offs:

- Absolute-position `thereafter` matches zap and needs no extra state, at the cost of a run of
  `thereafter - initial - 1` consecutive drops after the burst.
- Checking the clock every 64 events amortizes its cost, but expiry detection depends on traffic
  and the constant needs a recompile to change. The plain count reset costs boundary precision.
- The shared level-sampler vector makes inheritance free, but parent and child share counters and
  a late parent vector is invisible to existing children.
- Bypassing the counter for keyed events gives all-or-nothing requests, but `rate` is then the
  only volume control. With `rate` 10, 100K requests per second and 20 lines each, 200K lines per
  second pass regardless of windowed settings.

Nothing is emitted about dropped events: no summary, drop counter, annotation or callback. A drop
costs one increment and a comparison; a summary would need new shared state or a timer thread,
and running the formatter from the path that exists to avoid it. The per-destination `on-drop`
reporting belongs to ring-buffer overflow, a different mechanism: sampling loss is silent and
configured, ring-buffer loss is reported and not configured.

## Interactions

- **Request-scoped buffering.** `make-buffer-logger` builds loggers with no samplers and wires
  capture functions that bypass `make-log-fn`; flush replays through `emit-entry` unsampled
  (`test-buffer-bypasses-sampling`). See [request-scoped-buffering.md](request-scoped-buffering.md).
- **Tee and field transforms.** Sampling runs before both: a sampled-out event reaches no
  destination, tee filters cannot recover it, and transforms never affect decisions. The context
  given to `key-fn` has already been transformed.
- **Blocking mode.** Blocking avoids loss, sampling causes it; audit loggers should carry no
  sampler. See [../blocking-mode.md](../blocking-mode.md).

## Non-Goals

Per-destination or probabilistic sampling, runtime tuning of the clock-check interval, exact
window boundaries, sampling on dynamic context or per-call fields, persisting counters.

## See also

- [User guide: Sampling](../sampling.md)
- [request-scoped-buffering.md](./request-scoped-buffering.md)
- [overview.md](./overview.md)
- [decisions.md](./decisions.md)
