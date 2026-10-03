# cl-bark Condition Serialization Design

How cl-bark turns a condition into log output: the automatic type-and-message rendering, the explicit `capture` that adds a backtrace, and the rules that keep both bounded. Usage and output shape are documented in [README: Condition Logging](../../README.md#condition-logging) and [value-serialization.md: Condition Serialization](../value-serialization.md#condition-serialization); this document explains why the code is shaped the way it is.

## Motivation

Conditions are the main payload of `:error` and `:fatal` log calls. The generic value dispatch treats unknown objects as opaque and emits a `<type>` placeholder (see [value-serialization.md](../value-serialization.md)), which for a condition would be `"<simple-error>"`: no message and no trace. A structured logger that cannot report why something failed is of little use at those levels.

Two separate needs follow, with different costs:

- **Type and message.** Cheap, always available from the condition object, and enough for most log lines.
- **Backtrace.** Expensive, and only meaningful at the point where the condition is signaled. A backtrace describes the live control stack. It cannot be reconstructed from the condition object afterwards.

The design keeps the cheap part free of caller effort and makes the expensive part explicit.

## Design Summary

| Piece | Where | Purpose |
|-------|-------|---------|
| Plain condition as a field value | `emit-json-value`, `emit-logfmt-value`, `make-pretty-formatter` | Rendered as type name plus report text, no caller action |
| `bark:capture` | `src/conditions.lisp` | Snapshots a condition together with the current stack |
| `captured-error` struct | `src/conditions.lisp` | Holds the condition and the frame list; the formatters recognize it |
| `*max-json-stack-frames*`, `*max-pretty-stack-frames*` | `src/json.lisp`, `src/pretty.lisp` | Bound the number of frames written at format time |
| `dissect` | `cl-bark.asd` (`:depends-on`) | Portable source of frames and frame accessors |

The formatting code is split across `src/format-util.lisp` (shared helpers such as `type-name-string` and `write-condition-summary`), `src/json.lisp`, `src/logfmt.lisp` and `src/pretty.lisp`.

```
 signal site                 log call                     formatter
 -----------                 --------                     ---------
 handler-bind lambda  -----  (bark:error "..."            typecase on field value
   (bark:capture c)            :err <value>)                captured-error -> type, msg, stack
                                                            condition      -> type, msg
```

## Two-Tier Model

**Tier 1: a bare condition.** Any field value for which `(typep value 'condition)` holds is serialized with its type name and its report text. There is no wrapper and no registration. The type name is `(string-downcase (princ-to-string (type-of c)))` (`type-name-string` in `src/format-util.lisp`). The message is the condition printed with `princ`, so the condition's `:report` function (or `print-object`) decides the text.

**Tier 2: `capture`.** `(bark:capture condition)` returns a `captured-error` that stores the condition and a snapshot of the stack. The result is passed as a field value like any other. Formatters detect it and add the frames.

### Why the backtrace is captured in the handler

The trace has to be taken by the caller, on the calling thread, while the signaling frames are still on the stack:

- `handler-case` unwinds before the clause body runs. Only `handler-bind` runs its handler on top of the signaling frames. `capture` still works inside a `handler-case` clause, but it records the clause's stack, not the origin of the error. The `capture` docstring says so.
- Formatting happens too late. A log call hands its fields to a formatter, and `dispatch-to-output` in `src/output.lisp` invokes the formatter's `format-fn` on the caller thread (an async writer thread only receives finished strings). With `with-log-buffer`, formatting is deferred to flush, which can run after the handler has returned. A stack walk at format time would therefore describe the formatter's frames, not the error's.
- The logging macros cannot capture on the caller's behalf. At `bark:error` time the stack is the application code that logs, not the code that signaled. A trace taken there would look authoritative and point at the wrong place. Capture is an explicit act at the signal site.

### Why capture is opt-in

Walking the stack costs time and allocates one frame object per frame. Most error log lines do not need it, and conditions logged from `handler-case` clauses cannot benefit from it. Tier 1 stays zero-effort and cheap; callers pay for Tier 2 only where they place a `capture` call.

Because the macros evaluate their arguments before the level function is called, a `(bark:capture c)` written inline in a log call runs even when the level is disabled or the event is later sampled out. See Interactions.

## The `captured-error` Struct

```lisp
(defstruct (captured-error (:constructor %make-captured-error))
  (condition nil :type condition :read-only t)
  (stack     nil :type list     :read-only t))
```

| Aspect | Behavior |
|--------|----------|
| Constructor | `%make-captured-error` is internal. `capture` is the only exported way to build one. |
| Exports | `capture`, `captured-error-p`, `captured-error-condition`, `captured-error-stack`. The type name `captured-error` itself is not exported (`packages.lisp`); use `captured-error-p` from outside the package. |
| Slots | Read-only. The wrapped condition is never modified. |
| Not a condition | The struct is not a subtype of `condition`, so it cannot be signaled or handled by accident, and it never matches the `condition` clause of a formatter. |
| Stack contents | A list of `dissect` frame objects, most recent first, with leading cl-bark and `dissect` frames removed. |

### What it costs

- **Time.** `capture` calls `dissect:stack`, which walks the entire control stack. There is no depth limit at capture time. The cost is paid once per `capture`, on the calling thread.
- **Memory.** The full frame list is retained for as long as the struct is referenced. JSON and pretty output print at most 10 or 20 frames by default, but all frames are stored, because the limits are applied when formatting, not when capturing. This allows one captured error to be rendered by several formatters with different limits (for example, a tee with a JSON file destination and a pretty console destination).
- **Not captured.** Local variables, restarts, thread identity, and timestamps. `dissect` can collect locals; cl-bark does not request them (see Alternatives Considered).

### Frame stripping

`dissect:stack` starts with frames belonging to `capture` and to `dissect`. `internal-frame-p` identifies them, and `strip-internal-frames` drops the leading run so the first frame shown is the caller's code. The substring search runs on the upcased printed call for non-symbol frames, so the match is case-insensitive.

| Frame `call` | Internal when |
|--------------|---------------|
| A symbol | The symbol has a package and the package name is `BARK` or `DISSECT` |
| Anything else (lambda, `flet`, `labels` entries are reported as lists) | The upcased printed form contains the substring `BARK` or `DISSECT` |

Only the leading run is stripped. A cl-bark frame deeper in the stack stays, and so does every frame below the first non-internal one. The substring test for non-symbol calls is a heuristic: a leading anonymous frame whose printed form happens to contain `BARK` is also stripped, and an anonymous frame deeper in the stack is never examined.

## The `dissect` Dependency

Common Lisp has no standard way to obtain a backtrace. Each implementation exposes its own, and the frame shape differs. cl-bark uses `dissect` for exactly four things: `dissect:stack`, `dissect:call`, `dissect:file`, and `dissect:line`. No `sb-*` symbol appears in `src/conditions.lisp`, so the capture and the frame rendering are as portable as `dissect` is. (Other parts of the formatters use `sb-ext:float-nan-p`, which is unrelated to this feature.)

The recorded rationale for `dissect` is portability: one library, one frame accessor protocol, across SBCL, CCL, ECL, Allegro, ABCL, Clasp, and CLISP.

| Option | Status | Reason |
|--------|--------|--------|
| `dissect` | Chosen | Portable frames with `call`, `file`, and `line` accessors |
| `sb-debug` (or another implementation API) | Rejected | Implementation-specific; the library would need a backend per implementation |
| `trivial-backtrace` | Not recorded | The design notes do not discuss it, so no rejection reason is on record |
| No dependency | Not chosen | Would leave only type and message, which is Tier 1 without a backtrace |

The cost is a hard dependency in `:depends-on`, loaded even for programs that never call `capture`.

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `*max-json-stack-frames*` | `10` | Frames written in the JSON `stack` array; `NIL` is unlimited |
| `*max-pretty-stack-frames*` | `20` | Frames written in pretty output; `NIL` is unlimited |

Both are special variables, so a caller can rebind them with `let` around a single log call. Usage is in [value-serialization.md: Stack Frame Limits](../value-serialization.md#stack-frame-limits). They follow the naming of `*max-json-depth*` and `*max-pretty-depth*`, and they are exported.

There are two variables because the outputs have different consumers: JSON lines are machine-consumed and size-sensitive, pretty output is read at a terminal. The differing defaults are a choice, and the design notes do not state the reason.

There is no logfmt limit and no variable for "internal frame stripping": stripping is unconditional, and logfmt prints no frames.

A limit of `0` writes only the truncation marker. The limits apply at format time only.

## Output Per Formatter

All three formatters dispatch on the field value with a closed `typecase` or `cond`; the `captured-error` clause comes before the `condition` clause. The order is stylistic, since the types are disjoint.

### JSON

`emit-json-value` writes an object. Key order is `type`, `msg`, then `stack` (captured errors only). Frame key order is `call`, `file`, `line`.

```
{"type":"simple-error","msg":"boom"}
{"type":"simple-error","msg":"boom","stack":[{"call":"open-connection","file":"net.lisp","line":87},{"call":"..."}]}
```

- `msg` is always present; an empty report text gives `""`, not an absent key.
- `emit-json-condition-fields` writes the bare `"type":..,"msg":..` pair without braces, so the captured-error clause can append `emit-json-stack` before closing. It cannot use `emit-json-key`, which always prepends a comma.
- `call` goes through `key-string`: symbols are downcased, strings pass through, and any other object (a list for lambda, `flet`, or `labels` frames) is written with `princ-to-string` and is not downcased. A lambda frame therefore appears as `(LAMBDA () :IN LOAD-AS-SOURCE)` in upper case, while named functions appear in lower case.
- `file` (via `namestring`) and `line` are omitted when `dissect` reports none.
- An empty stack gives `"stack":[]` with no sentinel. When more frames exist than the limit, the sentinel `{"call":"..."}` follows the last written frame. It parallels the `"..."` sentinel of length-limited collections and keeps `stack` an array of objects.
- Because the condition's own `msg` is nested inside the field object, it does not collide with the top-level log `msg` key (`level`, `ts`, the fields, then the log message, in that order).

### logfmt

`emit-logfmt-condition` writes one value, `type: message`, for both a plain condition and a captured error. The text goes through `logfmt-write-bare-or-quoted`, which quotes and escapes it. Because the text always contains `": "`, the value is always quoted in practice (`err="simple-error: boom"`). The stack is dropped: logfmt is intentionally flat, and traces belong in JSON or pretty output.

### Pretty

`write-condition-summary` writes `type: message` inline after the key, in place of `princ` of the object. For a captured error the field is also queued, and after all fields `emit-pretty-stack` appends the frames. It takes the list of queued `(key . captured-error)` pairs and reads the limit from `*max-pretty-stack-frames*`:

```
ERROR request failed err=simple-error: boom
  at OPEN-CONNECTION (net.lisp:87)
  at PROCESS-REQUEST (api.lisp:42)
  ... (3 more frames)
```

(ANSI escapes omitted: the call name is bold, the location and the truncation line are dim.)

- Stacks are appended after all fields rather than inline, so the first line keeps its field order.
- One captured error produces an unlabeled block indented two spaces. Several in one call produce a dim `key:` label line per block, with frames indented four spaces.
- `format-frame-call` upcases the call, symbol or not. File and line are optional independently: `(file:line)`, `(file)`, or `(:line)` forms depend on what `dissect` reports.
- The truncation line reports `total - i` frames, where `total` is the length of the whole stored stack.
- The type name is not colored; only the level, keys, call names, and locations carry ANSI styling.

## Wrapped and Nested Conditions

A condition is rendered flat. cl-bark reads only `type-of` and the printed report text; it does not read slots, follow a cause, or recurse into sub-conditions.

- A condition that wraps another appears only as its own report text. If the report mentions the inner condition, the text shows it; otherwise the inner condition is invisible.
- `captured-error-condition` has slot type `condition`, so a `captured-error` cannot wrap another `captured-error`.
- A condition inside a list, vector, or hash table is serialized as an object in JSON, provided the enclosing collection itself was emitted. Collections at depth 0 become `<type>` placeholders first, and the condition inside is not reached. In logfmt a list is a `<cons>` placeholder, and in pretty it is `princ`ed under the print limits, which does not use the condition clauses.
- `msg` comes from `princ-to-string`, so two conditions of the same type name from different packages are indistinguishable in the `type` field (`princ` prints the symbol without a package prefix, and this holds regardless of `*package*`).

Cause chains are a non-goal (see Alternatives Considered).

## User Customization

There is no generic function and no extension protocol for condition serialization. The dispatch is a closed `typecase`, and `emit-json-value` and its siblings are not exported. The options are all outside the formatters:

| Goal | Mechanism |
|------|-----------|
| Change the message text | Define `:report` (or `print-object`) on the condition class; it feeds `msg`, and the `: message` part of logfmt and pretty |
| Change the type string | Name the condition class accordingly; it comes from `type-of` |
| Emit extra structured data | Convert before logging: pass a plist or hash table instead of the condition, or add fields next to it |
| Redact or replace conditions centrally | A `:field-transform` on `make-logger` or `make-child` (see [README: Field Redaction](../../README.md#field-redaction)) |
| Full control of rendering | Build a custom `formatter` with `make-formatter` and handle values in `format-fn` (see [formatter-protocol.md](formatter-protocol.md)) |

This matches the contract in [value-serialization.md](../value-serialization.md): unsupported types are the caller's job to convert. A protocol would have to be bounded by the same rules (no recursion, no unbounded output) and would make the output shape depend on user code.

## Alternatives Considered

### Automatic stack capture in the logging macros

Rejected. At `bark:error` time the stack is the application's logging code, not the signal site, so the trace would look authoritative while pointing at the wrong place. It would also add a stack walk to every error log call. Capture is explicit at the signal site.

### Cause chains and recursive condition rendering

Rejected. Common Lisp has no standard cause slot, so a chain would require a cl-bark protocol that user condition classes opt into. Not recursing is also what keeps the condition clauses bounded and free of depth bookkeeping.

### Local variable capture

Rejected. `dissect` can collect locals, but the data is expensive and unbounded.

### Stack traces in logfmt

Rejected. logfmt is flat key-value text, and a trace does not fit that shape. Hence no logfmt frame limit.

### A `captured-error` that is a condition subclass, or a condition with extra slots

Rejected in favor of a wrapper struct. The wrapper leaves the original condition untouched and still available to field transforms and custom formatters, and it cannot be signaled or matched by `handler-bind` clauses by accident.

### A preformatted text trace in JSON

Rejected in favor of an array of `call`/`file`/`line` objects, which suits machine consumption. Pretty output gets the human-readable `at FN (file:line)` form from the same frames.

### Per-destination capture limits

Not done. The full stack is stored and the limits are format-time variables, so one captured error serves several formatters. The cost is the memory held by the full stack.

## Invariants and Trade-offs

- **Logging never signals, with one gap.** The condition clauses do not recurse and write bounded output, but `princ-to-string` of a condition runs the user's `:report` function with no error protection around formatting. A report function that signals propagates out of the log call.
- **Bounded output.** The condition object is never traversed, so the object portion is a fixed two keys. Only the stack is variable, and it is bounded by the frame limits, except when a limit is `NIL`.
- **Depth is not consulted.** The condition clauses ignore the `depth` argument of `emit-json-value`. They fire whatever the remaining depth.
- **`*max-json-length*` does not apply to frames.** Frames have their own limit. The message text itself is not length-limited.
- **`captured-error` is never a condition.** Code that dispatches on `condition` does not see it, and the formatters must handle both explicitly.
- **Eager capture, lazy rendering.** The expensive step happens at the signal site; rendering happens later and can happen several times.
- **Printer variables.** The pretty formatter binds `*print-level*`, `*print-length*`, and `*print-circle*` around the line, so they also shape the report text there. JSON and logfmt `princ` under the ambient printer settings.
- **Key-string cache.** JSON `call` text goes through `key-string`, which memoizes symbols in a bounded cache (1024 entries, shared with field keys). Frame symbols can occupy slots that field keys would otherwise use.
- **Hard dependency.** The library depends on `dissect` for everyone, not only for users of `capture`.

## Interactions

### Field redaction and transforms

`:field-transform` runs before any formatter, on every field of the call, and sees the raw value: a bare condition or a `captured-error`. A transform can drop the field, mask it, or replace it with a plist or string. cl-bark never inspects a condition's slots, so nothing inside a condition is redacted automatically; the report text and the frame `file` paths are written as is. Redaction of a condition has to be done by replacing the whole value. For static `:context` the transform runs once at `make-child` or `make-logger` time, before pre-serialization.

### Request-scoped buffering

`with-log-buffer` stores the raw field plist (`make-buffer-capture-fn` copies the list with `copy-list`) and formats at flush through `emit-entry`. A `captured-error` is an ordinary object reference inside that plist, so the stack taken at the signal site is replayed intact. Formatting at flush also means the transform sees the untransformed capture and the frame limits in effect at flush time apply, not those at the log call. The buffer-logger has no transform, so the transform is applied once, at flush. See [request-scoped-buffering.md](request-scoped-buffering.md). The buffer's own `condition` argument to `on-flush` is the first `serious-condition` seen in the body and is unrelated to serialization.

### Static context and child loggers

Static context given to `make-logger` or `make-child` is pre-serialized once through each formatter's `prepare-fn`. Consequences:

- JSON and logfmt freeze the rendered text at creation, including the JSON stack, under the limits in effect then.
- Pretty (`serialize-bindings-pretty`) writes only the `type: message` summary for a `captured-error`. Its stack lines are dropped, since the accumulation of stacks exists only in the per-call formatter.
- Dynamic context (`with-context`) and per-call fields are rendered at log time and keep their stacks.

A captured error is a per-call value. Putting one in static context freezes or drops its trace.

### Depth and length limits

Covered under Invariants: the condition clauses ignore `*max-json-depth*` and `*max-json-length*`, but a condition nested in a collection is reachable only through collection clauses that obey them. See [value-serialization.md: Serialization Limits](../value-serialization.md#serialization-limits).

### Sampling

Sampling runs inside the level function, after the macro has evaluated its arguments. An inline `(bark:capture c)` in the argument list is evaluated even if the event is then dropped by a consistent sampler or a windowed counter, and also even if the level is disabled (the level function is then `noop`, but arguments are still evaluated). Callers who want to avoid the walk for events that may be dropped should test `level-enabled-p` first or capture only on a path that will certainly log. Buffered entries bypass sampling entirely, so a captured error in a buffer is never sampled out; see [sampling.md](sampling.md).

### Async and tee outputs

Formatting happens on the caller thread, so the stack walk and the rendering are both in caller latency (see [README: Caller-Thread Formatting](../../README.md#caller-thread-formatting)). The writer thread sees only strings. With a tee, each destination's formatter renders the same `captured-error` independently, using its own formatter and the shared limit variables.

## Non-Goals

- Automatic capture in the logging macros.
- Cause chains, slot walking, or any recursion into condition objects.
- Local variable capture, restart capture, or thread and timestamp metadata in a captured error.
- Stack traces in logfmt.
- A user-extensible serialization protocol for conditions.
- Protecting log calls against a `:report` function that signals.
