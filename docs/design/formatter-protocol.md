# cl-bark Formatter Protocol Design

How a cl-bark formatter is structured, why static context is serialized when a logger is created rather than on every call, and what a custom formatter has to respect. The user-facing reference is [README § Formatters](../../README.md#formatters) and [README § Formatter Factories](../../README.md#formatter-factories); value rendering is covered by [value-serialization.md](../value-serialization.md). This document explains the shape behind those references.

## Motivation

A logger carries static context: the `:context` plist given to `make-logger`, plus whatever each `make-child` adds. That context appears on every line the logger emits, so serializing it on every call is wasted work. Serializing it once at creation only works if the logger knows which output format it is serializing for.

The first version of cl-bark solved this for JSON only:

- Every logger kept two representations of its static context: a pre-serialized JSON fragment (named `chindings`, after Pino) and the original plist (`raw-bindings`).
- Every formatter received both and ignored the one it did not need, through a six-argument signature `(level chindings raw-bindings context message fields)`.
- A logfmt or pretty logger still paid for JSON serialization of context it never printed, and the JSON string was meaningless to it.
- The logger itself (`make-logger`, `make-child`) called the JSON serializer directly, so it was not format-neutral.
- Formatters were bare functions, so there was nowhere to attach a per-format preparation step.
- The name `chindings` has no meaning outside Pino.

The formatter protocol replaces the pair with one opaque `prepared` value produced by the formatter itself.

## Design Summary

A formatter is a struct holding two closures. There are no generic functions, no classes to subclass, and no registry of formatter names; `make-formatter` is the whole extension API.

```lisp
(defstruct (formatter (:constructor %make-formatter))
  (prepare-fn ... :type function :read-only t)
  (format-fn  ... :type function :read-only t))

(bark:make-formatter :prepare-fn (lambda (parent-prepared delta-context) ...)
                     :format-fn  (lambda (level prepared context message fields) ...))
```

| Slot | Called | Arguments | Returns |
|------|--------|-----------|---------|
| `prepare-fn` | Once per logger creation (root, child, and once per formatter group for a tee) | `parent-prepared` (`nil` for a root, otherwise the parent's prepared value), `delta-context` (plist of the fields added at this level, possibly `nil`) | The prepared string for this logger |
| `format-fn` | Once per emitted event, in the caller thread, once per formatter group for a tee | `level` (fixnum 1 to 6), `prepared`, `context` (alist from `with-context`), `message` (string or `nil`), `fields` (plist) | A complete line as a string, without a trailing newline |

`delta-context` is a plist (alternating keys and values); the built-in serializers walk it with `#'cddr`. The docstring of `formatter-prepare-fn` in `src/json.lisp` calls it an alist, which is wrong; the code wins. The dynamic `context` handed to `format-fn` is a different shape, an alist of `(key . value)` pairs, and `fields` is a plist.

Both slots are `:read-only` and typed `function`. The struct is defined in `src/json.lisp`, ahead of the three built-in formatters that use it; `src/format-util.lisp`, `src/timestamps.lisp` and `src/levels.lisp` load earlier and provide the helpers.

The logger stores the prepared value in its `prepared` slot and never inspects it. Its type is `(or string simple-vector)`: a string for a single output, a simple-vector with one string per formatter group for a tee.

```
logger creation                              log call
---------------                              --------
:context plist                               *log-context*   per-call fields
     |                                            |               |
     v                                            v               v
prepare-fn(nil, context)  --->  prepared  --->  format-fn(level prepared context message fields)
     |                                                              |
make-child: prepare-fn(parent-prepared, delta)                      v
                                                          line (string)
```

## The Formatter Struct

### Why a struct rather than a function

The original design used a bare function as the formatter. A single function has one entry point, so the per-format work done at logger creation had to live somewhere else, which is how the logger came to serialize JSON itself. The refactor (commit "Refactor formatter from function to struct across cl-bark") gives each format one object that owns both halves: how to prepare static context, and how to format a line. The logger holds the object and calls through it; it knows nothing about JSON, logfmt, or pretty.

Further consequences of the struct:

- Type checks. `logger-formatter` is `(or null formatter)` and a tee destination's formatter slot is `formatter`, so an old-style bare function is rejected by the slot type instead of being called with the wrong arity. There is no compatibility shim.
- Identity. Two uses of the same struct object are recognizably the same formatter. The tee relies on this (see [Tee grouping](#tee-grouping)).
- Configuration. A factory such as `make-json-formatter` precomputes level prefixes and key fragments in a closure and returns a struct, so customization costs nothing per call.

### The constructor

`%make-formatter` is the raw, unexported constructor. The exported `make-formatter` takes `&key prepare-fn format-fn` and substitutes a default `prepare-fn` that returns `""` when none is given. A formatter without a `prepare-fn` therefore works, but its logger's static `:context` does not appear in output, because nothing serializes it.

`format-fn` is required. The `(cl:error "format-fn is required")` initform in the struct definition is not what fires when it is omitted: `make-formatter` always passes `:format-fn`, so a missing function reaches the slot as `nil` and fails the `function` slot type check. The initform is effectively unreachable through the public constructor. The `cl:` prefix is needed because the `bark` package shadows `error` (and `trace`, `debug`, `warn`, `formatter`).

### Exported names

Exported from `packages.lisp`: `formatter`, `make-formatter`, `formatter-p`, `formatter-prepare-fn`, `formatter-format-fn`, the three factories `make-json-formatter`, `make-logfmt-formatter`, `make-pretty-formatter`, and the bare functions `json-formatter`, `logfmt-formatter`, `pretty-formatter`. The default instances `*default-json-formatter*`, `*default-logfmt-formatter*` and `*default-pretty-formatter*` are not exported; outside the package they are reached with `bark::`.

The bare functions are five-argument functions that delegate to the default instances. They exist for direct calls (the test suite calls them; formatter tests live in `tests/tests.lisp`) and are not formatter structs; passing `#'bark:json-formatter` as `:formatter` fails the type check.

## Prepare and Format Split

### Eager preparation

Static context is serialized when the logger is created:

| Event | Call |
|-------|------|
| `make-logger` | `(funcall (formatter-prepare-fn formatter) nil effective-context)` |
| `make-child` | `(funcall (formatter-prepare-fn parent-formatter) (logger-prepared parent) effective-bindings)` |

`effective-context` and `effective-bindings` are the plists after the logger's `:field-transform` has been applied (for a child, the parent's and child's transforms composed, parent first). Transforms therefore run before preparation: a redacted value never reaches the prepared string. Dynamic context and per-call fields are transformed per call, in `make-log-fn` (and again in `emit-entry` for replayed entries).

Child creation is O(delta): the child serializes only the fields it adds and concatenates them onto the parent's already-prepared string. A child of a child never re-serializes the grandparent's fields.

The logger also keeps the raw `context` plist (parent context appended with the child's effective bindings). The formatter protocol does not use it; the consistent sampler passes it to its `key-fn`. See [sampling.md](sampling.md).

### Composability invariant

Because a child's prepared string is `parent-prepared` followed by new text, every prepare-fn output has to be safe to concatenate with its own earlier output. The built-ins meet this by making each fragment self-delimiting at its front:

| Format | Fragment shape | Separator |
|--------|----------------|-----------|
| JSON | `,"name":"myapp","env":"prod"` | leading comma on every key |
| logfmt | ` name=myapp env=prod` | leading space on every field |
| pretty | ` ESC[2mnameESC[0m=myapp` | leading space on every field, dim key escapes embedded |

The consumer undoes the leading separator when the fragment lands first on the line. The JSON `format-fn` writes `prepared` with `:start 1` when nothing precedes it (level and timestamp both omitted). The logfmt `format-fn` tracks a `wrote` flag and chooses between prefixed and unprefixed key strings (`ts-prefix` versus `ts-prefix-first`, `msg-prefix` versus `msg-prefix-first`). A custom formatter may use any scheme that composes; the logger does not look inside.

Prepared strings are format-specific. The pretty fragment contains ANSI escapes, the JSON fragment contains escaped JSON; neither can be handed to a different formatter.

### `make-concat-prepare-fn`

All three built-ins build their prepare-fn with `make-concat-prepare-fn` (internal, in `src/json.lisp`), which takes a serializer from a plist to a string:

```lisp
(make-concat-prepare-fn #'serialize-bindings-json)
```

The returned closure serializes `delta-context` when it is non-nil (a nil or empty delta contributes `""`) and concatenates with `parent-prepared` when that is non-nil. The serializers are `serialize-bindings-json`, `serialize-bindings-logfmt` and `serialize-bindings-pretty`. The helper was extracted after the same lambda had been copied into three factories, so that a fix applies in one place.

`serialize-bindings-pretty` formats a `condition` or `captured-error` value as `type: message` through `write-condition-summary`, the same text the dynamic-context path produces. A captured error's stack is not part of a prepared string; see [condition-serialization.md](condition-serialization.md).

### Mismatched formatters between parent and child

`make-child` takes no `:formatter` argument. A child always inherits its parent's formatter, and a child of a tee logger inherits the tee, so a child cannot carry a formatter different from its parent's. This is what keeps the prepared chain valid: `parent-prepared` is only meaningful to the formatter that produced it, so feeding it to another formatter's prepare-fn would produce a mixed fragment. A different format is obtained by creating a separate root logger with its own `:formatter`, or by sending the same events to several formats through a tee, where each formatter group has its own prepared value.

## Call Path

The path from a log macro to a line in a ring buffer:

```
bark:info "msg" :k v
   |
   v   (logger-info-fn lgr)  -- the closure made by make-log-fn
make-log-fn closure (src/logger.lisp)
   | 1. consistent sampler (key-fn receives (logger-context lgr))
   | 2. windowed counter
   | 3. if output: apply field-transform to *log-context* and fields
   v
dispatch-to-output (src/output.lisp)
   |                                   \
   | non-tee                            \ tee
   v                                     v
format-fn(level prepared ctx msg flds)   emit-to-tee: for each formatter group i
   |                                       prepared = (aref prepared i)
   v                                       collect destinations whose filter passes
deliver-line                               if any: format-fn once for the group
   |                                       deliver-line to each passing destination
   v
async-output ring buffer (or stream, or function)
   |
   v   writer thread: write-string line, newline, force-output
```

Points that matter to a formatter author:

- `make-log-fn` passes `(logger-prepared lgr)` unchanged. For a single output it is a string; for a tee it is the simple-vector, and `emit-to-tee` picks the element for the current group, so a `format-fn` always sees a string.
- `dispatch-to-output` ignores its `formatter` argument for a tee. For a non-tee output it uses `(or formatter *default-json-formatter*)`. The fallback exists because the logger's slot type allows `nil`. `make-logger` defaults `:formatter` to `*default-json-formatter*`, so the case arises only when a caller passes `:formatter nil` explicitly: `prepared` is then `""` (no prepare-fn runs), the logger writes JSON without static context, and the async output has no formatter, so drop warnings use a hand-built JSON string (see [Drop warnings](#drop-warnings)). This is a silent mismatch, not an error; callers should pass a formatter or omit the keyword.
- `deliver-line` accepts three output kinds. An `async-output` receives the string in its ring buffer (or through `blocking-deliver` in blocking mode), and the writer thread writes it plus a newline. A stream receives `write-string`, `terpri` and `force-output`. A function output (synchronous, used by `with-captured-logs`) is called with the bare line.
- The formatter returns a string rather than writing to a stream. A line is produced once and may be pushed to several destinations' ring buffers, and the writer threads never format normal events. See [README § Caller-Thread Formatting](../../README.md#caller-thread-formatting) for the reasons formatting stays in the caller thread.
- `fields` is declared `dynamic-extent` in `make-log-fn`. A `format-fn` must not retain `fields` (or `context`) past its return.
- Filters in a tee see the level and the per-call fields, after field-transform. They never see static context; see the filter rationale in [multi-output.md](multi-output.md).

### Drop warnings

The async writer reports dropped messages itself. `emit-drop-warning` in `src/writer.lisp` formats the `(values message fields)` returned by `on-drop` through the async output's formatter, calling `format-fn` with `+warn+`, `""` as prepared, `nil` context, the message and the fields. A drop warning therefore uses the configured keys, timestamp format and level representation, but carries no static context. A custom `format-fn` must tolerate this call: level `+warn+`, `prepared` of `""` (even for a formatter whose real prepared strings have a required shape), `context` of `nil`, and a `message` that may be `nil` when only fields are returned. If the slot holds no formatter, a hand-built JSON string is used. `make-logger` gives its single async output the logger's formatter; `make-tee` gives each destination's async output that destination's formatter.

## Tee Grouping

`make-tee` in `src/output.lisp` builds one `destination` per spec (async output, formatter, optional filter) and then groups destinations by formatter identity:

```lisp
(defstruct formatter-group formatter destinations)   ; destinations: simple-vector
(defstruct tee-output groups)                        ; groups: simple-vector
```

Grouping uses an `eq` hash table, with groups kept in first-seen order so the group index is stable. A destination that omits `:formatter` gets `*default-json-formatter*`, which is a single shared instance, so all such destinations land in one group.

`emit-to-tee` handles one group at a time: run each destination's filter, and only if at least one passes, call the group's `format-fn` once and push the same line to every passing destination. A group with no passing destination costs only the filter calls. Different groups format independently, each with its own prepared value.

The group index is also the index into the prepared vector. `make-logger` and `make-child` build that vector with the same group order, mapping each group's formatter `prepare-fn` over the parent's per-group values (`make-child` maps over the groups and the parent vector together). A tee logger therefore holds one prepared string per group, not one per destination, and a formatter shared by three destinations is prepared once. See [multi-output.md](multi-output.md#destinations-and-groups) and [multi-output.md](multi-output.md#prepared-context-per-group).

Identity, not equality, decides grouping. Two calls to `(bark:make-json-formatter)` produce two groups even with identical settings. Sharing one variable across specs is the supported way to get a single group.

The logger's own `formatter` slot is ignored when its output is a tee (`dispatch-to-output` does not consult it for tees). A tee logger created without `:formatter` still holds `*default-json-formatter*` in that slot; it is inherited by children and has no effect on tee output.

## Built-in Formatters

All three are produced by factories that return a struct, and each has a default instance created at load time as a `defparameter`.

| | `make-json-formatter` | `make-logfmt-formatter` | `make-pretty-formatter` |
|---|---|---|---|
| Keywords | `:timestamp :level-format :level-key :timestamp-key :message-key` | `:timestamp :level-key :timestamp-key :message-key` | `:timestamp :timestamp-key :show-level` |
| Timestamp default | `:unix-ms` | `:unix-ms` | none (`nil`) |
| Level | string or numeric; omitted by `:level-key nil` | string; omitted by `:level-key nil` | colored padded uppercase label; omitted by `:show-level nil` |
| Field order | level, timestamp, prepared, dynamic context, per-call fields, message | level, timestamp, prepared, dynamic context, per-call fields, message | level, timestamp, message, prepared, dynamic context, per-call fields, then stack blocks |
| Prepared fragment | JSON key/value pairs with leading commas | space-prefixed `key=value` pairs | space-prefixed dim-key `key=value` pairs |
| Value emitter | `emit-json-value` | `emit-logfmt-value` | `princ` under bounded printer variables |

Parameter semantics are documented in [README § Formatter Factories](../../README.md#formatter-factories). Design points that are not in the README:

- The JSON message is written last and is omitted when `message` is `nil` (fields-only calls). The same holds for logfmt and pretty.
- The JSON `format-fn` is compiled with `(optimize (speed 3) (safety 1))`; level prefixes are precomputed into a vector indexed by level, and the timestamp and message keys are precomputed strings.
- In pretty output the message precedes the static fields. Pretty collects the stacks of `captured-error` values encountered while writing fields and appends them after the line through `emit-pretty-stack`, so a pretty "line" can span several physical lines. JSON embeds the stack as an array; logfmt omits stacks and writes `"type: msg"` only.
- Pretty binds `*print-level*`, `*print-length*` and `*print-circle*` around both preparation and formatting.

Value rendering, placeholders for unsupported types, and condition handling are specified in [value-serialization.md](../value-serialization.md); the formatter protocol does not define a value protocol. Each built-in calls its own emitters directly.

## Shared Utilities

`src/format-util.lisp` holds the pieces the built-ins share:

| Symbol | Role |
|--------|------|
| `with-format-stream` | Binds a variable to a reusable per-thread string-output-stream and returns the accumulated string |
| `*format-stream*` | The per-thread stream; created lazily |
| `key-string` | Converts a field key (string, symbol, or other) to a lowercase string; symbol results are memoized in `*key-string-cache*` up to `*key-string-cache-limit*` (1024) entries |
| `type-name-string` | Lowercase type name of a value |
| `write-angle-type` | Writes `<type>` for a value |
| `write-condition-summary` | Writes `type: message` for a condition |

`with-format-stream` avoids allocating a stream per call: the stream's internal buffer grows to the largest line seen and stays, so the only allocation per call is the result string. `*format-stream*` is registered in `bt:*default-special-bindings*`, so threads created through bordeaux-threads get their own binding.

Properties that follow from the code:

- The stream is not re-entrant. A `format-fn` running inside `with-format-stream` that triggers another use of the same macro in the same thread (for example a `print-object` method that formats a log line) shares the stream, and the inner call would take the outer call's partial output.
- A thread created without bordeaux-threads has no binding, so the first use sets the global value and such threads share one stream. Callers that create threads should use bordeaux-threads.
- `key-string` is a plain symbol-to-string cache with a size cap; once the cap is reached new symbols still work and are simply not cached.

These utilities are internal. A custom formatter may use them through `bark::`, or build its own string; the protocol only requires that `format-fn` returns one.

## Timestamps and Level Names

A `format-fn` receives no timestamp argument. Built-ins obtain one when needed through `emit-timestamp`, which takes a format keyword (`:unix-ms`, written as an integer, or `:iso8601`, written as `"YYYY-MM-DDTHH:MM:SS.mmmZ"` with the surrounding double quotes included in all three formatters) and writes to a stream. Any other keyword signals through `ecase`.

`emit-timestamp` reads `get-unix-timestamp-ms`, which returns `*override-timestamp*` when it is non-nil and the wall clock otherwise. The exported `current-log-timestamp-ms` is a thin wrapper over the same function, for custom formatters. A formatter that reads the clock itself gets the flush time, not the log time, whenever events are replayed (see [Replay](#replay-through-with-log-buffer)).

Level names are consumed by formatters from `src/levels.lisp`:

| Symbol | Content | Used by |
|--------|---------|---------|
| `+trace+` to `+fatal+` | fixnums 1 to 6 | `level` argument |
| `+level-slot-count+` | 7 | JSON level prefix vector size |
| `level-name` | lowercase name; `"unknown"` outside 1 to 6 | logfmt, JSON string levels, `print-object` of a logger; exported |
| `*level-names-upper*` | padded uppercase (`"INFO "`, `"WARN "`) | pretty |
| `*level-colors*` | ANSI codes: trace 36, debug 34, info 32, warn 33, error 31, fatal 35 | pretty |

`*level-names*`, `*level-names-upper*` and `*level-colors*` are vectors indexed by level with `nil` at index 0.

## Replay Through `with-log-buffer`

A buffered scope does not format anything while the body runs. The capture closure stores a `buffer-entry` with the level, the message, a `copy-list` of the fields (needed because `fields` is dynamic-extent), the current `*log-context*`, and a timestamp taken from `get-unix-timestamp-ms` at the call. See [request-scoped-buffering.md](request-scoped-buffering.md).

`make-buffer-logger` copies `context`, `prepared`, `formatter` and `output` from the original logger, so the buffer logger has the same prepared value the original would have used. On flush, `emit-entry` rebinds `*override-timestamp*` to the entry's timestamp, applies the root logger's field transform to the entry's context and fields (the buffer logger has none), and calls `dispatch-to-output` with the root logger's output, formatter and prepared value:

```lisp
(let* ((*override-timestamp* (buffer-entry-timestamp entry)) ...)
  (dispatch-to-output output (logger-formatter root-logger) level
                      (logger-prepared root-logger) ctx message flds))
```

Replay uses the same dispatch path as a live call, so tee filters, formatter groups and shared formatting behave identically. The rebinding makes `emit-timestamp` and `current-log-timestamp-ms` return the original time during the format call, so a flushed line carries the time of the log call, not the time of the flush. This works only for formatters that obtain the time through those two functions.

## Writing a Custom Formatter

A custom formatter needs a `format-fn`; a `prepare-fn` is needed only if it wants static `:context` fields to appear.

```lisp
(bark:make-formatter
 :prepare-fn (lambda (parent-prepared delta-context) ...)   ; optional
 :format-fn  (lambda (level prepared context message fields) ...))
```

Obligations on `prepare-fn`:

- Accept two arguments. `parent-prepared` is `nil` for a root logger; `delta-context` is a plist and may be `nil`.
- Return a string that composes by concatenation with the output of earlier calls in the same chain, or otherwise handle `parent-prepared` correctly.
- Respect the logger's field transform for free: the plist it receives has already been transformed.

Obligations on `format-fn`:

- Accept five arguments and return a single string without a trailing newline.
- Treat `message` as possibly `nil`.
- Tolerate the drop-warning call: `prepared` of `""` and `context` of `nil` (see [Drop warnings](#drop-warnings)).
- Treat `context` as an alist of `(key . value)` pairs and `fields` as a plist; do not retain either.
- Take the timestamp from `bark:current-log-timestamp-ms`, not from the clock, so buffered replay is correct.
- Use `bark:level-name` for the level label.
- Never signal on an unfamiliar value type; a logger must not crash the caller.
- Bound the output. The depth, length and stack-frame limits apply to the built-in emitters, not to custom code:

| Variable | Default | Applies to |
|----------|---------|------------|
| `*max-json-depth*` | 4 | JSON collection nesting |
| `*max-json-length*` | 20 | Elements per JSON collection |
| `*max-json-stack-frames*` | 10 | Frames in JSON condition output |
| `*max-pretty-depth*` | 4 | Bound to `*print-level*` in pretty |
| `*max-pretty-length*` | 20 | Bound to `*print-length*` in pretty |
| `*max-pretty-stack-frames*` | 20 | Frames in pretty condition output |

logfmt has no such variables: collections render as `<type>` placeholders. A custom formatter that reuses `emit-json-value` or `princ` inherits these limits; one that traverses values itself must apply its own.

A minimal complete example: plain `timestamp level message key=value` lines, with static context composed by concatenation.

```lisp
(defun plain-pairs (stream plist)
  (loop for (k v) on plist by #'cddr
        do (format stream " ~(~a~)=~a" k v)))

(defvar *plain-formatter*
  (bark:make-formatter
   :prepare-fn (lambda (parent-prepared delta-context)
                 (concatenate 'string (or parent-prepared "")
                              (with-output-to-string (s)
                                (plain-pairs s delta-context))))
   :format-fn (lambda (level prepared context message fields)
                (with-output-to-string (s)
                  (format s "~d ~a ~a" (bark:current-log-timestamp-ms)
                          (bark:level-name level) (or message ""))
                  (write-string prepared s)
                  (loop for (k . v) in context do (format s " ~(~a~)=~a" k v))
                  (plain-pairs s fields)))))

(defvar *lgr* (bark:make-logger :formatter *plain-formatter*
                                :output *standard-output*
                                :context '(:app "demo")))
```

To benefit from tee grouping, reuse one formatter struct across destinations. Select a custom formatter by passing the struct as `:formatter` to `make-logger`, or per destination in `make-tee` or `tee`. There is no registration step and no `:format` keyword.

## Alternatives Considered

### Keep `chindings` and `raw-bindings`, formatters ignore one

Status quo. Rejected: every logger serialized to JSON regardless of formatter, every formatter ignored one of two arguments, and the name was Pino jargon.

### Serialize static context at log time in non-JSON formatters

Keep only the raw plist and let each formatter serialize it per call. Reason: this gives up the zero per-call cost of static context, which is the purpose of preparation. The chosen design keeps the same O(delta) child creation as the JSON-only design it replaces.

### Logger builds a format-agnostic prepared value

The logger would produce the intermediate form itself. Reason: the logger must not know about JSON, logfmt or pretty, and `prepared` is opaque to it. Only the formatter knows what splices cheaply into its own output.

### Generic functions or classes for formatters

A CLOS protocol with methods per formatter class. What the struct provides instead: no class definitions or method dispatch on the per-call path, and a formatter's configuration lives in the closures created by its factory.

### Re-serialize the child's full context

Serialize `parent-context` plus the delta again at each child. Rejected: each child level serializes only its own new fields and concatenates with the parent's prepared string. The cost is the composability requirement on prepared strings.

### One prepared string per tee logger

A single value would be wrong when destinations use different formatters, since each format needs its own prepared text. The chosen design holds a simple-vector indexed by formatter group. Preparation iterates groups, not destinations, so a shared formatter is prepared once.

### Compatibility with bare-function formatters

Accepting the old closure signature alongside structs. Rejected: migration is not a concern and backward compatibility is out of scope. The old six-argument signature is gone, not adapted.

### Formatter writes to a stream

Passing an output stream into `format-fn`. Reason: one formatted line is shared by every passing destination in a group and then queued as a string, and the writer thread never formats; a stream argument would not fit the fan-out.

## Invariants and Trade-offs

| Invariant | Why |
|-----------|-----|
| `prepared` is produced by the formatter that will consume it | Fragments are format-specific; there is no cross-format conversion |
| A child inherits its parent's formatter | `make-child` has no `:formatter`; mixing would break the prepared chain |
| Prepared output composes by concatenation | `make-child` appends the delta to the parent's string |
| Field transforms run before preparation | Static context is transformed once, at logger creation |
| A tee logger's `prepared` is a vector in group order | `emit-to-tee` indexes it by group position |
| `format-fn` returns a string, formats once per group, in the caller thread | Fan-out, `dynamic-extent` fields, and dynamic context read in the caller |
| Timestamps come from `current-log-timestamp-ms` or `emit-timestamp` | Replay rebinds `*override-timestamp*` |

Trade-offs:

- Logger creation does serialization work (O(delta) per child) so that log calls do none for static context. Creating many short-lived children does cost one prepare call each, and the prepared string is held for the life of the child.
- The prepared string is spliced as is on every line, so the cost of a long static context is proportional to its serialized length on every call, but with no re-serialization.
- Preparation happens before any request-scoped decision, so static context is serialized even if buffered entries are later discarded.
- Identity-based grouping is cheap and predictable but surprising: equal settings in two factory calls do not share formatting work.
- The pretty formatter's output is not a single physical line when a captured error carries a stack.
- The nil-formatter fallback in `dispatch-to-output` avoids a type error but hides a misconfiguration.
- The per-thread format stream is fast but not re-entrant and relies on bordeaux-threads to bind it per thread.

## Interactions

| Feature | Interaction |
|---------|-------------|
| Tee (multi-output) | Groups by `eq` formatter; prepared is a per-group vector; the logger's own formatter slot is ignored for tee output. See [multi-output.md](multi-output.md) |
| Child loggers | Inherit the formatter struct (same object, so `eq`); prepared extended from the parent's; the tee vector is extended per group |
| Field transform | Applied to the static plist before `prepare-fn`, and to context and fields per call before `format-fn` |
| Sampling | Sampling runs before dispatch, so sampled-out events skip formatting. The consistent sampler's `key-fn` receives the logger's `context` plist, not the prepared string. See [sampling.md](sampling.md) |
| Request-scoped buffering | Entries are stored unformatted; replay rebinds `*override-timestamp*` and re-enters `dispatch-to-output`. See [request-scoped-buffering.md](request-scoped-buffering.md) |
| Backpressure and drop warnings | Warnings are formatted by the async output's formatter with empty prepared and context. See [blocking-mode.md](blocking-mode.md) |
| Condition serialization | Each built-in renders conditions and captured errors itself; the pretty prepare path summarizes conditions in static context. See [condition-serialization.md](condition-serialization.md) |
| Testing | `(with-captured-logs (var formatter) ...)` creates a function-output logger at `:trace` with static context `(:name "test")` and the formatter you pass, defaulting to `*default-json-formatter*`; collected lines carry no newline |
| Level wiring | Disabled levels are `noop` slots and never reach a formatter; the compile-time level cut removes the call entirely |

## Non-Goals

- A formatter registry, naming scheme or keyword selection (`:format :json`). A formatter is chosen by passing a struct.
- Extension through generic functions, or a pluggable value serialization protocol. Value rendering belongs to each built-in format; see [value-serialization.md](../value-serialization.md).
- Per-child formatter overrides.
- Converting a prepared value between formats.
- Backward compatibility with bare-function formatters.
- Formatting on the writer thread, or a formatter thread pool.
- Passing the timestamp or an output stream into `format-fn`.

## See also

- [README § Formatters](../../README.md#formatters) and
  [Formatter Factories](../../README.md#formatter-factories)
- [Architecture Overview](overview.md)
- [Multi-output](multi-output.md), [Request-scoped buffering](request-scoped-buffering.md),
  [Sampling](sampling.md), [Blocking mode](blocking-mode.md),
  [Condition serialization](condition-serialization.md)
- [Value serialization](../value-serialization.md)
- `src/json.lisp`, `src/logfmt.lisp`, `src/pretty.lisp`, `src/format-util.lisp`, `src/output.lisp`,
  `src/writer.lisp`
