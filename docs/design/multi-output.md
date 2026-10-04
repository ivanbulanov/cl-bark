# Multi-Output

A cl-bark logger can send one stream of events to several destinations, each with its own
formatter, filter, buffer and writer thread. The mechanism is a tee output, built with `make-tee`
or the `tee` macro and passed as `:output` to `make-logger`. A separate mechanism, passing a
logger as the first argument of a log macro, selects between whole loggers at the call site. This
document explains why the two are shaped the way they are. The user-facing reference is
[README § Multi-Output](../../README.md#multi-output).

## Problem

A single output per logger does not cover three common needs:

- **Mirroring.** The same events go to several sinks in different formats, for example pretty
  text on the console and JSON in a file.
- **Routing.** Different events go to different sinks depending on level or on per-call content,
  for example errors to a dedicated file or audit events to an audit stream.
- **Explicit selection.** The call site, not configuration, decides which logger receives an event.

The sinks differ in speed and in how much loss they tolerate. A network sink may stall for
seconds while the console never does, and an audit stream may need backpressure where the console
prefers to drop. One shared queue and one writer would couple all of them.

## Design

### Two orthogonal pieces

A tee mirrors and routes events inside one logger. The explicit logger argument selects between
loggers. Either works alone or together. `make-logger` accepts four kinds of `:output`:

| `:output` | Behaviour |
|-----------|-----------|
| stream | Wrapped in one `async-output` (ring buffer and writer thread) |
| `NIL` | Same as a stream, using `*error-output*` |
| function | Called synchronously with the formatted line, no thread |
| tee output | Used as is; every destination already owns an `async-output` |

There is no global start function and no logger name. Callers bind or set `*logger*`, and a name
is an ordinary `:context` field.

### Destinations and groups

`make-tee` takes a list of destination plists. Each becomes a `destination` struct with its own
`async-output`, `formatter` and optional `filter`, and one writer thread started at that point.
Destinations are then grouped by `eq` identity of their `formatter` struct into
`formatter-group`s, and the `tee-output` holds the vector of `groups`. The three structs are not
exported; a tee is an opaque value for `:output`. Per-destination keys, defaults and the `tee`
macro syntax are in the README. In short, `:formatter` defaults to the shared
`*default-json-formatter*`, and `:capacity`, `:on-drop`, `:blocking`, `:block-timeout` and
`:on-block-timeout` configure that destination's own `async-output`. Passing `nil` for `:on-drop`
selects the default handler, so a drop warning is suppressed by returning `nil` from the handler.

`:level` is shorthand for a filter comparing the event level with a threshold. Giving both
`:level` and `:filter` is a configuration conflict. `make-tee` signals
`bark-configuration-error` with a `use-value` restart that accepts a replacement tee; the `tee`
macro rejects the same combination at macroexpansion time with a plain `cl:error`.

### Pipeline

```
 log macro
   level gate        (logger level; below it the slot holds noop)
   sampling          (consistent sampler, then windowed counter)
   field transform   (per-call fields and dynamic context)
   dispatch-to-output
      tee: emit-to-tee, per formatter group:
             run each destination's filter on (level fields)
             if any passes: call the group's format-fn once
             deliver-line the same string to each passing destination
      other: format with the logger's own formatter, deliver-line once
```

`make-log-fn` builds the per-level closures that run the first three steps. The filter receives
the integer level and the per-call fields after the field transform. `deliver-line` pushes to the
destination's ring buffer, or waits for space when that destination is in blocking mode; a
function output is called directly and a bare stream is written synchronously. Formatting and
filtering run on the calling thread, and the ring buffer holds finished strings, so a writer
thread only drains and writes. A destination whose filter rejects an event costs one filter call,
and a group with no passing destination skips formatting.

```
 caller thread                         writer threads
   group A: format once ------------+--> ring 1 --> writer 1 --> stderr
                                    +--> ring 2 --> writer 2 --> app.jsonl
   group B: format once ---------------> ring 3 --> writer 3 --> errors.jsonl
```

### Prepared context per group

The logger stores static context as `context` (a plist) and `prepared`. For a stream or function
output `prepared` is one string made by the logger's formatter. For a tee it is a simple-vector
with one string per group, made by each group formatter's `prepare-fn`; `make-child` extends each
element with the same group's `prepare-fn`, and `emit-to-tee` indexes the vector in step with the
groups. The logger's own `formatter` slot plays no part in formatting tee events. See
[formatter-protocol.md](formatter-protocol.md) for the protocol.

### Lifecycle

`flush` and `stop` walk the logger's async outputs with `do-async-outputs`, which visits every
destination of a tee, the single async output of a stream logger, and nothing for a function
logger. `stop` drains each output and joins its writer; it is a no-op for `nil`, for an already
stopped logger and for a synchronous one, and signals `bark-child-operation-error` for a child
(a `continue` restart ignores it). `flush` signals `bark-async-stopped` if any output is no longer
running, with a `continue` restart, and waits at most five seconds per output. cl-bark never
closes a caller's streams. Every async output is also drained automatically at image exit.

### Error isolation

A writer thread that hits a stream error calls its destination's `on-error` function, if any.
`on-error` still exists as a `make-tee` key and a `tee` spec key; `make-tee` passes it to
`make-async-output`, which stores it in the `async-output` struct, and `writer-loop` consults it.
`destination` has no `on-error` slot of its own, and `make-logger` passes `nil` for a plain stream
output, so only tee destinations can recover.

- If `on-error` returns a stream, the writer swaps to it and continues; the failed line is lost.
- If it returns `nil`, the writer stops.
- If it signals, or no hook exists, the error is reported on `*error-output*` and the writer
  stops.

The hook receives the original stream condition. After a writer stops, its ring fills and later
lines for that destination are dropped, or producers wait out the block timeout in blocking mode.
Other destinations are unaffected.

## Rationale

**Why a thread per destination rather than one writer.** Each destination gets its own ring
buffer and writer, so a slow sink (a high-latency network stream) cannot delay a fast one (stderr,
a local file). A shared writer would serialise all I/O: one slow `write-string` or `force-output`
would stall every destination. A per-destination thread also reuses the same self-contained loop
as a single async output, with no pool, multiplexing or coordination. Idle writers wait on a
semaphore, so for the usual two to four destinations the cost is a few kernel threads.

**Why group by `eq` formatter.** Formatting is the expensive step and is done on the caller
thread. Destinations sharing one formatter object need the same line, so it is formatted once and
the string is pushed to each passing destination. Identity, not equal settings, is the grouping
key because a formatter holds closures that cannot be compared; two separate
`(make-json-formatter)` calls form two groups even when their settings match. Sharing is
opt-in by binding one formatter to a variable and passing it to several destinations, and
destinations that omit `:formatter` all share the default instance. Grouping also fixes the shape
of `prepared`, one entry per group.

**Why filters see level and per-call fields but not static context.** Static context is
serialised when the logger is created, once per group, so a filter reading the raw plist would
need it kept in parallel. Every scenario examined was better solved by separate loggers.

- *Per-component routing.* To send billing events to an audit stream by `:component "billing"`,
  note that the component is known when the child is made. Create the logger with the right output
  or pass it explicitly: `(bark:info *billing-logger* "charge processed" :amount 100)`.
- *Multi-tenant routing.* With one child per tenant and a log file per tenant, the tenant is known
  at child creation, so the decision belongs there rather than at emit time.
- *Library-created children.* If an HTTP client creates its own child with
  `:context '(:component "http-client")` and the application wants those events in a debug file,
  a filter on that key couples the application to the library's internals. The library should
  accept a logger parameter instead.

Static context is known at creation time, so the routing decision can be made then; a filter
decides after the fact. Dynamic context from `with-context` is scoped rather than routed and is
likewise invisible to filters. Content that varies per call goes in the per-call fields:

```lisp
(bark:tee
  (*error-output* :formatter (bark:make-json-formatter))
  (*audit-file*   :formatter (bark:make-json-formatter)
                  :filter (lambda (level fields)
                            (declare (ignore level))
                            (getf fields :audit))))
```

**Why an explicit logger argument as well as a tee.** A tee decides where an event goes after it
has been logged, from level and per-call fields only. Routing on identity or static context is
decided by the call site, and the first argument of the log macros gives it that choice without a
logger registry or an output override on `make-child`. The macro treats a literal keyword first
argument as a fields-only call, and classifies any other first argument at runtime: a logger,
a keyword starting fields, or the message for `*logger*`. The type-tag check is negligible next
to formatting.

**Why per-destination error isolation.** Logging is best-effort and must not crash or stall the
application. Because each destination owns its stream, buffer and writer, a failing disk or a
broken pipe stops one writer and leaves the rest running. Recovery policy (reopen, swap to another
stream, give up) is the caller's, expressed through `on-error`, so cl-bark does not wrap the
condition or guess a fallback.

**Why child loggers share the tee.** `make-child` copies the parent's `output`, so a child of a
tee logger writes to the same destinations and the same writer threads. A child adds static
context and does not reroute, which keeps the mental model to one rule: routing is chosen by the
logger passed in, context by the child. Each group's formatter receives the child's own prepared
string, so the added context appears in every destination.

## Invariants and Trade-offs

- Each destination owns exactly one `async-output`; writer threads start inside `make-tee`, so
  building a tee has side effects. If a later destination spec fails validation, the writers of
  earlier destinations are already running and are not stopped.
- Tee grouping is by `eq` on the formatter struct. The `groups` vector and the `prepared`
  vector of a tee logger are in the same order and are never reordered after construction.
- Filters run on the calling thread and are not wrapped in a handler. A filter that signals
  propagates out of the log call, so filters should be cheap and total.
- Passing `:formatter` to `make-logger` together with a tee output signals
  `bark-configuration-error` (with a `use-value` restart): each tee destination carries its own
  formatter, so a logger-level one would be dead configuration.
- Async keys on `make-logger` (`:capacity`, `:on-drop`, `:blocking`, `:block-timeout`,
  `:on-block-timeout`) with a tee or function output signal `bark-configuration-error` with a
  `use-value` restart. Per-destination settings belong in the destination spec.
- The drop warning written by a writer thread goes through the destination's own formatter with
  an empty prepared string and no context, straight to the stream. It bypasses the filter, so a
  destination with `:level :error` can still receive a warn-level drop notice.
- A tee output shared by two loggers shares its writers: `stop` on either root logger stops them
  for both.
- Formatting cost stays on the caller, once per group with a passing destination. The ring buffer
  holds strings, never structured data.
- Out of scope: output override on `make-child`, a named logger registry, filtering on static or
  dynamic context, and a public output object. See the README's Non-Goals table.

## Interactions

- **Child loggers.** A child shares the parent's tee and writers. Its `prepared` vector is built
  per group by extending the parent's element with the group's `prepare-fn`. `make-child` copies
  the sampler references at creation time, and the level is its own. A child cannot be stopped;
  stop the root.
- **`with-log-buffer`.** Buffered entries are replayed through `emit-entry` and
  `dispatch-to-output` using the root logger's output, so tee filters run at flush time on the
  replayed level and fields, and entries rejected by a filter are discarded as usual. The buffer
  decides whether an entry is emitted; the tee decides where. The field transform runs at replay,
  not at capture. The buffer-logger drops the samplers, so buffered entries are not sampled. See
  [request-scoped-buffering.md](request-scoped-buffering.md).
- **Blocking mode.** Blocking is per destination. A tee can mix a lossy console with a blocking
  audit file, and a full ring blocks the caller only when the event passes that destination's
  filter. `:block-timeout` defaults to 5.0 seconds in `make-tee`. See
  [blocking-mode.md](blocking-mode.md) and the [user guide](../blocking-mode.md).
- **Sampling.** Sampling runs before field transforms and before dispatch, so a sampled-out event
  reaches no filter and no destination. Tee filters cannot recover it. See
  [sampling.md](sampling.md).
- **`flush` and `stop`.** Both act on every destination of the tee. `flush` waits for each ring
  in turn, so its worst case grows with the destination count. A stopped writer makes `flush`
  signal `bark-async-stopped`; the `continue` restart skips it.
- **Formatter protocol.** Each group's formatter supplies `prepare-fn` at logger and child
  creation and `format-fn` at emit time. Filters never see the prepared string. See
  [formatter-protocol.md](formatter-protocol.md).

## See also

- [README § Multi-Output](../../README.md#multi-output),
  [Configuration Diagrams](../../README.md#configuration-diagrams) and
  [Usage Examples](../../README.md#usage-examples)
- [Formatter protocol](formatter-protocol.md)
- [Blocking mode](blocking-mode.md)
- `src/output.lisp`, `src/writer.lisp`, `src/logger.lisp`, `src/buffer.lisp`
