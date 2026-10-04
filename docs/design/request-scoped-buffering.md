# cl-bark Request-Scoped Buffering Design

How `with-log-buffer` holds log calls until a scope ends and then decides which of them reach the output. The user-facing reference is [README § Request-Scoped Buffering](../../README.md#request-scoped-buffering); the cross-feature rules are in [README § Feature Interactions](../../README.md#feature-interactions). This document explains the shape of the implementation in `src/buffer.lisp` and the reasons behind it.

## Motivation

A service that handles many requests succeeds almost all the time. Logging at `:debug` multiplies the volume for requests nobody will inspect. Logging at `:info` discards the debug trail for the few requests that fail, which is where it was needed. The decision about what to keep depends on how the scope ends, and a log level is decided before the scope runs.

Existing facilities each decide too early:

| Facility | Why it does not solve the problem |
|----------|-----------------------------------|
| Log levels | Filter eagerly, before the outcome is known |
| Dynamic context (`with-context`) | Tags entries, but neither holds nor suppresses them |
| Tee filters | Route each entry at emit time, with no knowledge of later events |
| Sampling | Drops entries probabilistically, so the failing request is as likely to be sampled out as any other |
| `with-captured-logs` | Collects formatted strings, is synchronous and test-oriented, and has no conditional logic |

## Design Summary

`with-log-buffer` takes a logger, replaces `*logger*` for the dynamic extent of its body with a buffer-logger, and records every log call into an adjustable vector instead of formatting it. In an `unwind-protect` cleanup, `flush-buffer` selects entries and replays them through the original logger's output pipeline.

```lisp
(bark:with-log-buffer (logger &key (level :trace) on-flush)
  &body body)
```

| Piece | Purpose |
|-------|---------|
| `with-log-buffer` (macro) | Set up capture, track the exit, trigger the flush |
| `make-buffer-logger` | Copy of the source logger whose level slots hold capture functions |
| `make-buffer-capture-fn` | Per-level closure that builds a `buffer-entry` and pushes it onto the vector |
| `buffer-entry` (struct) | One captured call: level, message, fields, context snapshot, timestamp |
| `flush-buffer` | Choose which entries to emit |
| `emit-entry` | Replay one entry through the root logger |
| `*root-logger*` | Marks that a buffer scope is active and holds the logger to flush through |
| `*override-timestamp*` and `current-log-timestamp-ms` | Make replayed entries carry their original timestamps |

Capture-then-flush flow:

```
 (with-log-buffer (logger) body)
        |
        v
 +------------------------------+
 | *root-logger* = logger       |   body runs unbuffered if
 | buf-lgr = make-buffer-logger |   *root-logger* is already set
 | *logger* = buf-lgr           |
 +--------------+---------------+
                |
                v
   body: (bark:debug ...) (bark:info ...)
        |   each call lands in buf-lgr's capture function
        v
   vector of buffer-entry  (level, message, fields copy,
                            context snapshot, timestamp)
                |
     normal return, or non-local exit, or error unwinds
                |
                v
        unwind-protect cleanup
                |
                v
   flush-buffer: on-flush / abnormal+condition / level filter
                |
                v
   emit-entry per selected entry
     (*override-timestamp* = entry timestamp,
      field-transform, dispatch-to-output on the root logger)
                |
                v
   tee filters, formatter, async ring buffer or stream
```

`src/buffer.lisp` is the last component of `cl-bark.asd`. It depends on `%make-logger`, `wire-level-fns` and the level-slot protocol from `src/logger.lisp`, on `dispatch-to-output` from `src/output.lisp`, and on `*override-timestamp*` from `src/timestamps.lisp`.

## Capture

### The buffer-logger

`make-buffer-logger` builds a fresh logger with `%make-logger`. It copies `context`, `prepared`, `formatter` and `output` from the source logger and leaves every other slot at its default. It then sets the level slot to the capture level and calls `wire-level-fns` with a factory that returns a capture closure for each level at or above the capture level. Levels below the capture level stay `#'noop`.

This reuses the mechanism `set-level` uses. The logging macros funnel through `logger-<level>-fn` of whichever logger they resolve, so nothing in the macros knows about buffering. A call through `*logger*` reaches a capture closure, and a call below the capture level reaches `#'noop` at the same cost as a disabled level.

Three slots are deliberately left at their defaults:

- `field-transform` is `nil`. The transform is applied once, at flush time (see [Flush-time work](#flush-time-work)).
- `level-sampler` and `consistent` are `nil`. Capture is unconditional, because a sampled-out entry would be gone before the flush decision exists. The docstring of `make-buffer-logger` says "sampler cleared"; the code achieves it by not copying the slots.
- `root-p` is `nil`, so the buffer-logger is never taken for a root logger.

The macro evaluates the `level` argument once through `level-from-keyword`, which accepts only the six level keywords. The capture level may be raised as well as lowered: with a source logger at `:info` and `:level :error`, info entries are not captured and cannot be flushed.

### `buffer-entry`

```lisp
(defstruct buffer-entry
  level message fields context timestamp)   ; all read-only, typed
```

| Slot | Type | Content |
|------|------|---------|
| `level` | fixnum | Numeric level of the call |
| `message` | string or nil | Message, nil for fields-only calls |
| `fields` | list | Fresh copy of the per-call plist |
| `context` | list | Value of `*log-context*` at capture time |
| `timestamp` | non-negative integer | Unix milliseconds at capture time |

An entry stores everything that is dynamic at capture time, because none of it is reliable at flush time:

- `*log-context*` is established by `with-context`. By the time the cleanup runs, those bindings are gone. The snapshot is a reference to the alist that was current, and `with-context` builds a new alist instead of mutating the old one, so no copy is needed.
- The `&rest` fields list of the log function is declared `dynamic-extent`. Capture must outlive the call, so the capture closure uses `copy-list`.
- The timestamp is read in the capture closure through `get-unix-timestamp-ms`. A flush reads a later clock value, and the entry should say when the event happened, not when the scope ended.

Static context needs no snapshot. It is the logger's `prepared` string, which belongs to the root logger and does not change during the scope.

The accessors are exported. The struct type name and `make-buffer-entry` are not exported from the `bark` package; `on-flush` callbacks use the accessors, and tests construct entries through the internal constructor.

## Exit Detection

`with-log-buffer` distinguishes exits using two pieces of state, both local to the macro expansion:

- `normal-exit-p` starts as `nil` and is set to `t` after the body returns, inside a `multiple-value-prog1` so that all return values pass through unchanged.
- `condition` is set by a `handler-bind` on `serious-condition` the first time one is signaled in the body.

| Exit | `normal-exit-p` | `condition` | Default flush |
|------|-----------------|-------------|---------------|
| Body returns | `t` | nil | Filter by original level |
| Body returns after a condition was signaled but handled inside | `t` | usually nil (see below) | Filter by original level |
| `return-from`, `throw`, `go` out of the body | nil | nil | Filter by original level |
| Condition unwinds through the scope | nil | non-nil | Emit everything |

The handler records and returns. It never handles, so the condition continues to propagate to whatever handler the application established, and outer `handler-case` forms and the debugger see it unchanged.

A `return-from` or `throw` counts as normal exit because it is deliberate control flow. Failure is recognized as the combination of unwinding and a recorded condition; a bare unwind with no condition falls into the level-filter branch. A retry loop, where `return` leaves the scope on success, is the motivating case.

The placement of the `handler-bind` matters. It sits outside the body, so any `handler-case` or `handler-bind` the body establishes is more recent and runs first. A `handler-case` inside the body that unwinds before the signal reaches the macro's handler leaves `condition` nil and the exit normal; the test `test-with-log-buffer-on-flush-sees-handled-condition` pins this. A body-local `handler-bind` that declines lets the signal reach the macro's handler, so `condition` can be non-nil even when the scope still returns normally. `on-flush` receives all three values (entries, condition, `normal-exit-p`) so a caller can decide for itself. The default rule is `(and (not normal-exit-p) condition)`.

The flush is in an `unwind-protect` cleanup so that it runs on every exit, including non-local ones. The cleanup runs with `*logger*` already restored to its outer value and `*root-logger*` still bound.

## Flush

### Selection rules

`flush-buffer` receives the vector, the root logger, `normal-exit-p`, `condition`, the `on-flush` callback and the original level, and applies these rules in order:

| Order | Condition | Entries emitted |
|-------|-----------|-----------------|
| 1 | Buffer is empty | None. `on-flush` is not called |
| 2 | `on-flush` supplied | Whatever the callback returns |
| 3 | No `on-flush`, abnormal exit with a condition | All entries |
| 4 | Otherwise | Entries whose level is at least the original level |

The original level is read from the source logger when the scope is entered, before the buffer-logger exists. A `set-level` on the source logger during the scope does not change the threshold for that scope.

Emission order is capture order. Nothing is emitted while the scope runs. If an `on-flush` callback reorders its result, the output follows the callback's order.

### The case where `on-flush` returns nil

Without `on-flush`, "no entries selected" and "use the level filter" are the same internal state: the abnormal branch yields the whole buffer, and the normal branch yields `nil`, which falls through to the filter. With `on-flush`, a nil result must mean "emit nothing", for example in a callback that suppresses a request entirely. The code separates the two with `(unless on-flush ...)` around the fallback filter. Without that guard, a callback returning nil would turn into the default level filter. The test `test-with-log-buffer-on-flush-nil-suppresses-all` covers this.

Two related details follow from the same function:

- The result of `on-flush` is traversed with `loop ... across`, so it must be a vector (or nil). The README describes it as a sequence. A callback built on `remove-if` over the entries vector returns a vector and works; a list result signals a type error inside the cleanup form. The callback receives the live buffer vector (with a fill pointer), not a copy.
- `on-flush` runs inside the cleanup form. An error signaled by the callback or by emission during an unwind replaces the original non-local exit.

### Replay through `emit-entry`

`emit-entry` takes the root logger and one entry and runs the final steps of a normal log call: field transform, then `dispatch-to-output` with the root logger's formatter and `prepared` string and the entry's context snapshot, message and fields. It does not go through the root logger's level functions, so the root logger's level and samplers are not consulted at flush. The entry has already been admitted by capture and selected by flush.

Replaying through `dispatch-to-output` has these consequences:

- Tee destinations behave as for any other event. Each destination's filter runs on the entry's level and fields, so a debug entry flushed after a failure is still dropped by an errors-only destination. The buffer decides whether to emit; the tee decides where.
- Async outputs receive the lines through `deliver-line`, the same entry point as live calls, so ring buffers, blocking mode and drop callbacks apply unchanged.
- When the root logger has no output, `emit-entry` does nothing.

### Timestamps

The built-in formatters get their timestamp from `get-unix-timestamp-ms`, which returns `*override-timestamp*` when it is non-nil and the wall clock otherwise. `emit-entry` binds `*override-timestamp*` to the entry's timestamp around the dispatch. The formatter signature stays the same and the built-in formatters need no changes.

A custom formatter that reads the clock itself would stamp flush time on every replayed entry. `current-log-timestamp-ms` is the exported function formatters call instead; it delegates to `get-unix-timestamp-ms`. The `*override-timestamp*` variable stays internal.

### Flush-time work

| Mechanism | Capture time | Flush time |
|-----------|--------------|------------|
| Field transform | Not applied. The buffer-logger has no transform | Applied by `emit-entry` with the root logger's transform, to both the context alist and the fields plist |
| Level sampler and consistent sampler | Not applied. The buffer-logger has neither | Not applied. `emit-entry` calls `dispatch-to-output` directly and never reads sampler slots |
| Tee filters | Not applied | Applied by `emit-to-tee` as for any event |

The field transform runs once on each emitted entry, and only on emitted entries. The buffer-logger does not inherit the transform: it would run at capture and again at replay, applying it twice. Applying it at flush also means discarded entries never pay for the transform.

Samplers are not re-applied at flush. Samplers are cleared at capture because a sampled-out entry would be permanently lost, defeating the purpose of buffering. The code also does not sample at replay; the effect is that a buffered scope bypasses sampling in both directions. See [sampling.md](../sampling.md#request-scoped-buffering-with-log-buffer).

## Nesting

Nested `with-log-buffer` is a no-op. The macro checks `*root-logger*`: when it is non-nil, the body runs directly with no additional buffering, and the outermost scope controls the capture level and the flush policy. The `level` and `on-flush` arguments of an inner scope are ignored, though its `logger` argument is still evaluated once. A nil logger also makes the macro a plain `progn`.

`*root-logger*` has two jobs: it is the signal that a buffer scope is active, and it holds the logger the flush replays through, which is the source logger of the outermost scope.

Nested scopes could instead buffer independently, each flushing directly to the root output and not into its parent. The code uses the no-op rule. The README states the reason as "wrong flush targets, lost context, and out-of-order output"; the table below shows the mechanisms.

| Problem with independent nested buffers | Mechanism |
|------------------------------------------|-----------|
| Wrong flush target and lost context | All scopes flush through the root logger. If `*logger*` is rebound to a different child between nested scopes (`component "auth"` outside, `component "db"` inside), inner entries are emitted with the root's static context, so the output carries the outer component. The inner child's context is lost |
| Out-of-order output | An inner scope flushes at its own exit, directly to the output. Outer entries logged before the inner scope began are still held, so inner entries appear before them |

Merging inner entries into the outer buffer is also rejected, for complexity and unpredictable behavior; see [Alternatives Considered](#alternatives-considered).

The no-op rule has a cost. A failing inner operation that is caught by an outer `handler-case` inside the same outer scope is a handled error from the outer scope's perspective, so the exit is normal and the debug entries of the failed inner operation are not emitted. The test `test-nested-buffer-inner-error-handled-by-outer` pins this. A library cannot get an isolated buffer for a sub-operation while a caller's scope is active.

## Explicit Logger Calls Bypass the Buffer

Only calls that resolve to `*logger*` are captured. The logging macros take an optional first argument: if it satisfies `logger-p`, that logger's level slot is used directly and `*logger*` is not read. `(bark:info *audit-logger* "msg")` therefore goes to `*audit-logger*` immediately.

Passing a logger is a routing decision, and the buffer should not override it. This is the same explicit selection described in [multi-output.md](multi-output.md).

Two corollaries. A child logger created before the scope is entered is not the buffer-logger, so calls through it go straight to the output. A child created from `*logger*` inside the body is derived from the buffer-logger, but `make-child` wires ordinary log functions through `set-level`, so calls through that child are emitted immediately as well. Code that wants a child buffered passes it as the `logger` argument of `with-log-buffer`, as in the README example, so the buffer-logger copies its `context` and `prepared`.

## Memory and Cost

Capture cost per call is one `copy-list` of the fields, one `buffer-entry`, one timestamp read and one `vector-push-extend`. Nothing is formatted, so entries that are discarded never pay for formatting, transform or delivery.

| Aspect | Behavior |
|--------|----------|
| Buffer size | Unbounded. Starts at 32 slots and grows through `vector-push-extend` |
| Fields | Fresh list per entry. Captured values stay reachable until the scope ends and the vector is released, so large objects in fields are retained that long |
| Dynamic extent | The `&rest` list is not stack-allocated on this path, because it must outlive the call. Live logging keeps its `dynamic-extent` declaration |
| Context | Shared reference to the current alist. No copy |
| Flush | Linear in the number of emitted entries. Transform, formatting and delivery happen once per entry at scope exit |
| Thread safety | The vector is created per scope and has no synchronization |

The buffer is unbounded because the typical scope is a request that lasts milliseconds to seconds with tens of entries, and a bound adds API surface and implementation complexity for a problem expected to be rare. The consequence is that a long-running scope that logs heavily at `:trace` grows without limit. The scope boundary and the `level` argument are the only controls.

Special bindings are per thread in SBCL. A thread started inside the scope does not inherit the `*logger*` and `*root-logger*` bindings, so its log calls go to the global values. This follows from dynamic binding and is not specific to this feature. Passing the buffer-logger to another thread explicitly would share the unsynchronized vector.

## Alternatives Considered

### Log levels

Levels filter before the scope runs. Choosing `:debug` for everything pays the volume cost for every request; choosing `:info` loses the trail for failures.

### Sampling

Keeping a fraction of debug entries retains the failing request's trail only by chance. Sampling loses exactly the logs needed when something goes wrong.

### Tee filters

A filter sees one entry at emit time, with no knowledge of how the scope ends. The design keeps filters in the flush path for routing, and uses the buffer for the retroactive decision.

### `with-captured-logs`

It collects formatted output synchronously, is intended for tests, and has no conditional logic.

### Independent nested buffers

Each nested scope buffers and flushes to the root separately. Rejected in favor of the no-op rule, because of the static-context problem that follows from "all scopes flush to root"; see [Nesting](#nesting).

### Merging inner entries into the outer buffer

Not done: merging adds complexity and makes behavior unpredictable. With the no-op rule the outcome is simpler still, since inner calls are captured by the outer buffer directly.

### Bounded buffer

Deferred: bounds add API surface and implementation complexity, and the problem is expected to be rare. Bounds can be added later if real usage demands.

## Invariants and Trade-offs

Invariants maintained by the code:

- Within a scope, emitted entries are in capture order, unless `on-flush` reorders them.
- Each emitted entry carries its capture-time timestamp, level, message, fields and context snapshot, with the root logger's static context.
- The field transform runs at most once on any entry, and only at flush.
- The buffer is flushed exactly once per outermost scope, on every exit path, by the `unwind-protect`.
- The return values of the body pass through unchanged, and the macro never handles a condition.
- A nil logger and a nested scope both run the body with no buffering.
- `*logger*` inside the body is the buffer-logger; `*logger*` during the flush is the outer value.

Trade-offs:

| Choice | Benefit | Cost |
|--------|---------|------|
| Replay through `dispatch-to-output` | Same pipeline as live events, including tee filters and async output | Bypasses root level and samplers at flush, so `on-flush` can emit below the root level |
| No-op nesting | One flush policy, correct static context, ordered output | A sub-operation cannot get an isolated buffer or its own `on-flush` |
| Capture everything above the capture level | No entries lost to samplers | Memory grows with the number of captured calls |
| Unbounded buffer | No bound API, no silent loss | A heavy `:trace` scope grows without limit |
| Only `*logger*` calls are captured | Explicit routing decisions are respected | Calls through explicit loggers, including children made earlier, are not buffered |
| Condition recorded, not handled | The debugger and outer handlers are unaffected | The recorded condition can exist on a normal exit when body-local handlers decline |
| Failure means unwind plus condition | Deliberate non-local exits stay quiet | A declined condition followed by a normal return reaches `on-flush` but is not treated as failure by the default rule |

## Interactions

| Feature | Interaction |
|---------|-------------|
| Compile-time elimination | `*compile-time-min-level*` removes log calls from the compiled code. The buffer operates at runtime and cannot capture calls that no longer exist. Leave it `nil`, or at or below the capture level, in code that uses buffering. This is inherent to compile-time elimination; `set-level` has the same limit |
| `level-enabled-p` | Inside the scope it is evaluated against the buffer-logger, so it reflects the capture level, not the source logger's level |
| Tee | Destination filters and per-group formatters apply at flush, to each emitted entry. Filters receive the entry's level and its transformed fields |
| Child loggers | A child passed as the `logger` argument is copied for its static context. Children created before or inside the scope bypass capture |
| Sampling | Bypassed on capture and not re-applied on replay. See [sampling.md](../sampling.md#request-scoped-buffering-with-log-buffer) |
| Field transform | Applied at flush with the root logger's transform |
| Blocking mode | Flush delivers all selected entries in one burst. With `:blocking t` the caller waits for the writer when the ring is full, which holds the thread at the end of the scope. blocking-mode.md calls this correct behavior; see [blocking-mode.md](../blocking-mode.md) |
| Non-blocking async output | A burst larger than the ring capacity drops entries under the usual drop policy, and the `:on-drop` handler reports the count. A failing request with many captured entries is the case most exposed to this |
| Custom formatters | Must call `current-log-timestamp-ms`, or replayed entries show flush time |
| `with-context` | The context alist at each call is snapshotted in the entry, so bindings that have exited by flush time are still reported |

## Non-Goals

- Bounding the buffer or choosing which entries to drop when it fills.
- Intercepting log calls that pass an explicit logger.
- Bypassing tee filters at flush. Filters run on replayed entries as on live ones.
- Merging nested buffers, or giving nested scopes their own flush policy.
- Applying samplers to replayed entries.
- Emitting partial results before the scope ends. Nothing is emitted until exit.
- Buffering across threads. A scope is one dynamic extent in one thread.

## See also

- [README § Request-Scoped Buffering](../../README.md#request-scoped-buffering): usage and user-facing semantics
- [overview.md](overview.md): architecture map and where each design document fits
- [sampling.md](sampling.md) (design) and [user guide](../sampling.md#request-scoped-buffering-with-log-buffer): how sampling interacts with the buffer
- [multi-output.md](multi-output.md): tee filters and the explicit logger argument
- [blocking-mode.md](blocking-mode.md) (design) and [user guide](../blocking-mode.md): backpressure behavior during a flush burst
- [formatter-protocol.md](formatter-protocol.md): the prepare and format protocol the replay path uses
- [condition-serialization.md](condition-serialization.md): how conditions captured in fields are rendered at flush
- `src/buffer.lisp`, `src/timestamps.lisp`
