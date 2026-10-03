# Design decisions

This document records why the public API of cl-bark has the shape it has. It covers API-shape decisions, not
internals; for the architecture and the path of one log call see [overview.md](overview.md). Each entry gives the
context, the decision as the code implements it today, and the consequences, plus rejected alternatives where a
record of them exists. Usage is documented in the [README](../../README.md); this file does not repeat it. The code is
the authority; behaviour that is easy to misread is collected under [Known quirks](#known-quirks).

## Logger construction: one entry point, `make-logger`

**Context.** A logging library needs a way to create a logger, bind it globally, and tear it down. Bundling these
into one operation (a `start` function that creates, binds `*logger*`, and stops the previous logger) makes it
impossible to have two independent async loggers, for example an application logger and an audit logger.

**Decision.** `make-logger` is the only way to create a root logger:

```lisp
(make-logger &key output (level :info) (formatter *default-json-formatter*)
                  context field-transform
                  (capacity +default-buffer-capacity+) (on-drop #'default-on-drop)
                  blocking (block-timeout 5.0) on-block-timeout
                  level-sampler consistent)
```

It returns a logger and never touches `*logger*`; the caller binds it explicitly. There is no `start` function. The
type of `:output` selects the behaviour, and there is no `:async` flag:

- a stream is wrapped in an async output (ring buffer plus one background writer thread, started eagerly);
- `NIL` means `*error-output*`, wrapped the same way;
- a function is called synchronously with each formatted line, with no thread and no buffer;
- a `tee-output` (from `tee` or `make-tee`) is used as is, because it already contains async outputs.

The async parameters `:capacity`, `:on-drop`, `:blocking`, `:block-timeout` and `:on-block-timeout` apply to stream
outputs only. Passing any of them with a function or a tee output signals `bark-configuration-error` (with a
`use-value` restart), because they are per-destination settings that belong in `tee`. Any other `:output` type
signals the same condition.

**Consequences.** Several independent loggers can coexist, each owning its output and writer threads. Lifecycle is
explicit: `stop` targets one logger. The cost is that `make-logger` is not a pure constructor, since a stream output
spawns a thread, so a logger that is abandoned without `stop` leaves its writer running (`register-exit-hook` exists
for image exit). Rejecting async parameters for function and tee outputs, rather than ignoring them, gives up a little
convenience in exchange for catching misconfiguration at construction time.

**Rejected.** An `:async` boolean: the output type already determines the behaviour, and a flag would allow
contradictory combinations such as `:async t` with a function output.

## Opaque logger struct, no `name` slot

**Context.** Loggers carry identity in two ways: the variable that holds them, and the data they attach to each
record. A dedicated `name` slot would be a special case of the second.

**Decision.** `logger` is a `defstruct` whose slots are internal. Only `logger-p` is exported, not the type name and
not any slot accessor. There is no `name` slot and no `:name` argument; a name is ordinary static context, for
example `:context '(:name "myapp")`. `print-object` shows the type, the level name, and the word `child` for
non-root loggers, which is enough to tell loggers apart in a REPL. `with-captured-logs` builds its logger with
`:context '(:name "test")`, which shows the convention in use.

**Consequences.** The representation can change without breaking users, and there is one way to attach a field to
every record. Users cannot read a logger's level, context or output back; the only exported query is
`level-enabled-p` (see below). If real demand for read accessors appears they can be added, since adding an export is
not a breaking change.

## `make-child` with keyword context

**Context.** Child loggers carry extra static context that is serialized once at creation. An earlier shape that
took the context as a trailing rest list mixed data with configuration: a magic key such as `:field-transform` had
to be stripped from the plist before the rest was treated as fields. `child` also named a constructor without the
CL `make-` prefix.

**Decision.** `(make-child parent &key context level field-transform)`. `:context` is a keyword argument holding a
plist, so context and configuration cannot collide. The child:

- appends its context to the parent's and pre-serializes only the new part through the formatter's `prepare-fn`;
- takes `:level` if given, otherwise a snapshot of the parent's current level, so a later `set-level` on the parent
  does not propagate;
- copies the parent's formatter and output, and the parent's level sampler and consistent sampler by reference at
  creation time;
- composes `:field-transform` with the parent's through `compose-field-transforms`, the parent's transform running
  first and the child's on its result.

A child is never a root, at any nesting depth. `stop` on a child signals `bark-child-operation-error` (with a
`continue` restart that ignores the call), because the child shares the parent's writer and stopping it would break
the parent and its siblings. `flush` on a child is allowed and flushes the shared output.

**Consequences.** Per-call cost of context is zero, and configuration is unambiguous. A child needs no cleanup and
can be dropped to the garbage collector. The snapshot rule means level changes must be applied to each logger that
should follow them.

## Call convention: explicit logger or implicit `*logger*`

**Context.** Most code logs through one global logger, but some code needs to log through a specific logger,
including loggers created per request or per component. Requiring a logger argument everywhere is noisy;
supporting only the global makes multi-logger use awkward.

**Decision.** The six macros `trace`, `debug`, `info`, `warn`, `error` and `fatal` accept three call forms:

```lisp
(bark:info "msg" :key value)          ; through *logger*
(bark:info logger "msg" :key value)   ; through an explicit logger
(bark:info :key value)                ; fields only, through *logger*
```

A literal keyword first argument is recognised at macroexpansion time. Otherwise the first argument is dispatched at
runtime: if it satisfies `logger-p` it is the logger, if it is a keyword it starts a fields-only plist, and anything
else is the message. When `*logger*` is `NIL` the implicit forms are no-ops and the macros never signal. The macros
dispatch through the logger's per-level function slots (see the next entry) rather than a generic function.

**Consequences.** Both styles work with one set of names, and the shadowed CL symbols (`debug`, `error`, `trace`,
`warn`) are used package-qualified. The costs are that a message cannot be a keyword, and that a first argument that
is not a logger is always read as the message: an explicit `NIL` logger is therefore treated as a `NIL` message sent
through `*logger*`, not as a no-op. Arguments are evaluated before the level function is called, so an expensive
argument is computed even when the level is disabled, which is the reason `level-enabled-p` exists.

## Levels as fixnums 1..6; `set-level` swaps function slots

**Context.** Levels are compared on every log call and used to index per-level vectors (names, colours, sampler
counters). The set is fixed at six, and there is no support for user-defined levels.

**Decision.** `+trace+` through `+fatal+` are the consecutive constants 1 through 6, so a level is directly an index
into a vector; slot 0 of each level-indexed vector is a `NIL` sentinel, and `+level-slot-count+` is 7 (not exported).
`level-name` converts a number to its lowercase name (exported); `level-from-keyword` converts a keyword and
signals on an unknown one with `ecase` (not exported). `make-logger :level`, `set-level` and `make-child :level`
accept a keyword or a fixnum.

Each logger holds six function slots, one per level. `set-level` stores the threshold and rewires the slots through
`wire-level-fns`: levels at or above the threshold get a real log function from `make-log-fn`, levels below get
`#'noop`. The macros call the slot without comparing levels.

**Consequences.** A disabled level costs one indirect call with no comparison, and enabled paths do no arithmetic to
find a vector index. A numeric level such as 30 from another system does not map onto these values, and there is no
way to add an intermediate level. `set-level` takes effect on the next call but rewrites six slots one at a time, so
a concurrent log call may briefly see a mix of old and new slots.

## `level-enabled-p` is the only level query

**Context.** Because the macros evaluate their arguments before the level function runs, a disabled call still pays
for building its arguments. Other logging libraries provide a predicate for guarding such code.

**Decision.** `(level-enabled-p logger level)` takes a logger (or `NIL`) and a level keyword, and returns true when a
call at that level would be dispatched. It returns `NIL` for a `NIL` logger, consistent with the macros. An invalid
keyword signals an error from `level-from-keyword`. It checks the threshold only: it does not account for sampling,
for per-destination tee filters, or for compile-time elimination. There is no `when-level` macro and no per-level
predicates such as `debug-enabled-p`.

**Consequences.** The guard pattern is one `when` around the expensive call. The predicate is exact about the level
and conservative about everything else: it can return true for a call that sampling then drops. Sampling is excluded
because it uses atomic counters, and a predicate could not claim a sample slot on behalf of the following call. The
logger's level slot stays private; this predicate is the whole read interface for levels.

## Formatter as a two-function struct

**Context.** A formatter must turn a log event into a line, and the static part of the context (from `:context` and
child loggers) is the same on every call, so serializing it per call would be wasted work.

**Decision.** A `formatter` is a read-only struct of two functions, exported with `make-formatter`,
`formatter-p`, `formatter-prepare-fn` and `formatter-format-fn`:

- `prepare-fn` takes the parent's prepared value (or `NIL`) and the delta context, and returns the pre-serialized
  static context. It runs once, when a logger or child is created.
- `format-fn` takes `level` (fixnum), the prepared value, the dynamic context list, the message (string or `NIL`)
  and the fields, and returns the finished line as a string. It runs for every enabled call.

`make-json-formatter`, `make-logfmt-formatter` and `make-pretty-formatter` build such structs; `json-formatter`,
`logfmt-formatter` and `pretty-formatter` are exported functions that apply default settings. The symbol `formatter`
is shadowed in package `bark`. A custom formatter is any struct built with `make-formatter`; see
[formatter-protocol.md](formatter-protocol.md).

**Consequences.** Per-call cost is only the dynamic part. The protocol is plain data and closures, so tests and tools
can build formatters without defining classes. The prepared value is opaque to everything but the formatter that
produced it, so a formatter cannot be swapped on an existing logger.

## Default JSON output; `level` is a string

**Context.** Log pipelines and structured-logging libraries in other languages generally emit the level as a string,
and a numeric level is an internal detail that readers cannot interpret without the table.

**Decision.** `make-json-formatter` is declared as:

```lisp
(make-json-formatter &key (timestamp :unix-ms) (level-format :string)
                          (level-key "level") (timestamp-key "ts") (message-key "msg"))
```

so the default output carries `"level":"info"`. `:level-format :numeric` emits the number 1 through 6 instead.
`*default-json-formatter*` (an instance of the factory with default settings, not exported) is what `make-logger`
uses when no formatter is given. For every formatter the level can be dropped: `:level-key nil` for JSON and logfmt,
`:show-level nil` for pretty. Logfmt always writes the level as a string, and pretty always writes a coloured label.

**Consequences.** Output is readable and portable by default. Anyone consuming numeric levels must opt in with
`:level-format :numeric` and use the 1 through 6 scale. Omitting the level lets a log shipper add its own.

## Caller-thread formatting

**Context.** A log call can format on the calling thread and hand a string to the writer, or hand the raw event to
the writer and format there. The second keeps the caller faster but must copy or retain arbitrary Lisp objects.

**Decision.** The calling thread formats. `make-log-fn` applies sampling, applies any field transform, and then
`dispatch-to-output` calls the formatter's `format-fn` and pushes the finished string; the writer thread only writes
strings to the stream. For a tee, the line is formatted once per group of destinations that share an `eq`
formatter.

**Consequences.** Field values are serialized while they still hold the state the caller saw, so a mutable object is
logged as it was at the call, and the ring buffer holds only strings. The price is that formatting cost lands on the
caller, and a slow `print-object` method slows the logging thread, not the writer. See the formatting discussion in
[overview.md](overview.md).

## Tee: per-destination filter, one writer thread each

**Context.** One logger often needs to write to several places with different formats and thresholds, for example
JSON to a file and pretty output to the terminal at a higher level.

**Decision.** `make-tee` takes a list of destination plists, and `tee` is a macro over it. Each plist has `:stream`
(required) and optional `:formatter`, `:filter`, `:level`, plus the per-destination async settings `:capacity`,
`:on-drop`, `:on-error`, `:blocking`, `:block-timeout`, `:on-block-timeout`. Every destination gets its own async
output, so its own ring buffer and writer thread; one slow destination cannot stall another. `:filter` is a function
of `(level fields)`; `:level` is shorthand for a threshold filter, and giving both signals
`bark-configuration-error`. Filters run before formatting, and destinations with an `eq` formatter are formatted
once per event.

**Consequences.** Destinations are isolated in speed and in backpressure policy, and a destination that filters out
an event costs nothing further. The cost is one thread per destination. Tee destinations must be streams, because
the async settings only make sense there; a plain function sink is available only as a whole-logger output. Details
are in [multi-output.md](multi-output.md).

## Drop by default; blocking is opt-in

**Context.** A bounded buffer between producers and a slow stream has two possible policies when it fills: discard
new messages or make the producer wait. Logging should not stall a request thread by default.

**Decision.** The ring buffer is a lock-free multi-producer, single-consumer structure with drop-on-full semantics,
default capacity `+default-buffer-capacity+` (8192 lines). A drop increments a counter, and the writer emits a
warning built by `on-drop`, called as `(funcall on-drop count)` and returning `(values message fields)` or `NIL`
to suppress; the default reports "dropped N log messages". With `:blocking t`, producers instead wait for space for
up to `:block-timeout` seconds (default 5.0); on timeout the line is discarded, `:on-block-timeout` is called if
supplied, and a separate counter is incremented. After `stop`, no writer consumes the buffer, so later lines are
never written, and `flush` on a stopped output signals `bark-async-stopped` with a `continue` restart. See
[blocking-mode.md](blocking-mode.md).

**Consequences.** The default never adds latency to the caller, at the price of lost lines under sustained
overload, which is reported rather than hidden. Blocking trades latency for completeness and still has a bounded
worst case. Neither mode is guaranteed to be lossless, because shutdown without `stop` can leave lines in the
buffer.

## No CLOS

**Context.** Formatters and outputs are open sets, which suggests generic functions. The hot path is a handful of
calls per log event.

**Decision.** The library defines no classes and no generic functions. Types are `defstruct`s, errors are
`define-condition`s (`bark-error` and its subtypes), and behaviour is selected by stored functions: the six level
slots on the logger and the two functions in a formatter. The only methods are two `print-object` methods, for the
logger and the async output.

**Consequences.** There is no dispatch cost on the hot path and no dependency on MOP behaviour across
implementations. Extension means supplying functions (a formatter struct, an output function, a field transform),
not subclassing; a user cannot specialise on the logger or output types.

## Narrow export list

**Context.** Everything exported is a commitment. The package is used by application code, custom formatter
authors, and tests.

**Decision.** The package exports what those users need: the level constants, `level-name`, the logging macros,
`make-logger`, `make-child`, `set-level`, `level-enabled-p`, `flush`, `stop`, `register-exit-hook`, the formatter
protocol and factories, `make-tee` and `tee`, the sampling constructors with `set-level-sampling` and
`set-consistent`, `with-context`, `with-captured-logs`, `with-log-buffer` with the buffer-entry readers, `capture`
and the captured-error readers, the serialization limits, `current-log-timestamp-ms`, and the `bark-*` conditions. It
does not export the logger type or its accessors, `async-output`, `level-from-keyword`, `+level-slot-count+`, the
JSON and logfmt emitters, the format-util helpers, the sampler accessors, `*default-json-formatter*`, or
`default-on-drop`. Internals are reachable with `bark::` but carry no stability promise.

**Consequences.** Internals can change freely, and the documented surface is small enough to review. Users who want
something internal must use `bark::` or ask for it to be promoted, which is the intended way to discover real
needs, for example format-util helpers for custom formatters.

## One file per concern

**Context.** The source began as a single file, which mixed formatting, threading, routing and the public API and
made it hard to see which part depends on which.

**Decision.** The system loads `packages` and then twelve files in `src/`, in this order from `cl-bark.asd`:

1. `levels`: constants, name vectors, level conversion.
2. `conditions`: `bark-*` conditions, `capture`.
3. `timestamps`: timestamp emission.
4. `format-util`: key and type-name helpers shared by formatters.
5. `json`: serialization, the `formatter` struct, JSON factory.
6. `logfmt`: logfmt factory.
7. `pretty`: pretty factory.
8. `ring-buffer`: the generic MPSC buffer.
9. `writer`: async output, writer loop, blocking delivery.
10. `output`: tee, destinations, dispatch.
11. `logger`: logger struct, sampling, `make-logger`, lifecycle, macros.
12. `buffer`: request-scoped buffering.

The order is a dependency order (`:serial t`): formatters depend only on levels and helpers, the ring buffer is
independent of the writer, and the logger comes last because it uses everything else. The formatter struct lives in
`json.lisp`, the first formatter file, and the other two formatters rely on it. Sampling structs sit in `logger.lisp`
because the logger struct has slots of their types.

**Consequences.** A change to one concern touches one file, and each formatter is self-contained apart from the
shared protocol. The load order matters and a new file must be placed in it deliberately.

## Beta status: no backward-compatibility guarantee before 1.0

**Context.** The library is at version 0.1.0 and has been used only by its author. Its API has been reshaped
repeatedly to reach the form above, with no deprecation aliases.

**Decision.** The README states that the library is beta and that no stability guarantee is made until 1.0. The
[changelog](../../CHANGELOG.md) commits to listing breaking changes under **Changed** and to semantic versioning, and
that until 1.0 the API may change between minor versions. Breaking changes are made directly, with no deprecated
aliases or compatibility shims. Symbols reachable only through `bark::` are outside the API at any version.

**Consequences.** The API can still be corrected when real use shows a mistake, instead of carrying a bad shape
forever. Users who need stability should pin a version and read the changelog on upgrade. This list of decisions
describes the current API and is expected to change before 1.0.

## Known quirks

Behaviour that is correct per the code and now documented consistently, but that a reader may not expect.

- `*compile-time-max-level*` is exported and defined, but no logging macro or compiler macro consults it. It is
  reserved for a future compile-time elimination feature and setting it has no effect. The README, the user guide
  and the variable's docstring all say so.
- The logging macros treat any first argument that is neither a logger nor a keyword as the message, so
  `(bark:info nil "x")` logs through `*logger*` with a `NIL` message and `"x"` as an (invalid) field key. Only
  `*logger*` being `NIL` yields a no-op.
- The default JSON formatter and the default drop handler are internal (`bark::*default-json-formatter*`,
  `bark::default-on-drop`). The README describes their behaviour without naming them; pass your own `:formatter`
  or `:on-drop` to replace them.
