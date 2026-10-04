# cl-bark Architecture Overview

The map of cl-bark: the problem it solves, the one rule that shapes the design, how a single log call travels from macro to bytes on a stream, what each source file is responsible for, and which design document to read next. The user-facing reference is [README](../../README.md); the thread and ring-buffer model is described in [README § Architecture](../../README.md#architecture) and is summarized here, not repeated.

## Motivation

A logger sits inside the code it observes, so its cost is paid by application threads. Three costs matter:

- **Disabled calls.** Most `trace` and `debug` calls are off in production. They should cost close to nothing.
- **Enabled calls.** Formatting and I/O must not make the application wait on a slow disk, pipe or socket.
- **Structure.** Operators want key-value fields, not format strings, so output can be parsed by machines.

The design (Pino-inspired, extended with ideas from zerolog and slog) has four goals: high performance, structured output, flexibility (runtime level changes, swappable formatters, child loggers, dynamic context) and portability. The code delivers the first three. Portability is partial; see "Invariants and Trade-offs".

## Design Summary

The rule is "do nothing in the hot path". Work is split by when and where it can happen:

| Phase | Where | Work |
|-------|-------|------|
| Logger creation (`make-logger`, `make-child`, `set-level`) | Caller of the constructor | Serialize static context into a `prepared` fragment through the formatter's `prepare-fn`; wire six level function slots to either a log closure or `noop`; start one writer thread and ring buffer per destination |
| Formatter creation (`make-json-formatter` and siblings) | Caller of the constructor | Precompute per-level prefix vector and the timestamp and message key fragments |
| Log call | Caller thread | Level-slot dispatch, sampling, field transform, formatting into one string, filter checks, ring-buffer push, semaphore signal |
| Draining | Writer thread (one per destination) | Pop strings, `write-string`, `terpri`, `force-output` once per batch, drop warnings, flush acknowledgements |

Consequences that recur through the other documents:

- The ring buffer carries finished strings, not structured events. Formatting always happens before the push, so a message that is dropped on a full buffer has already been formatted (see "Interactions").
- A disabled level is a slot holding `#'noop`. There is no level comparison on the call path. The cost is that `set-level` rewrites six slots instead of one integer.
- Static context is concatenated once into `prepared`; child loggers extend the parent's string. Dynamic context (`*log-context*`) is read per call, in the caller thread, because it is a special variable.
- The library uses `defstruct`s and function slots. There is no CLOS dispatch on the log path.

## Data Flow of One Log Call

```
(bark:info "msg" :k v)                              caller thread
  |
  v
macro INFO in src/logger.lisp (define-log-macro)
  |  first-arg dispatch; (funcall (logger-info-fn lgr) lgr "msg" :k v)
  v
slot holds #'noop ............ level disabled: return, nothing else runs
slot holds closure from make-log-fn
  |
  |  1. consistent sampler   (logger-consistent): key-fn on static context
  |  2. windowed counter     (logger-level-sampler): atomic-incf, CAS window reset
  |  3. field-transform      (logger-field-transform), if any, on context and fields
  v
dispatch-to-output (src/output.lisp)
  |
  +-- tee-output --> emit-to-tee: per formatter group, run filters,
  |                  format once, deliver-line to each passing destination
  |
  +-- single output --> (formatter-format-fn fmt) level prepared ctx msg fields
  v
deliver-line (src/output.lisp)
  |
  +-- async-output, drop mode ......... ring-buffer-push (src/ring-buffer.lisp)
  |                                     then bt:signal-semaphore
  +-- async-output, blocking mode ..... blocking-deliver (src/writer.lisp)
  +-- bare stream (not via make-logger) write-string, terpri, force-output
  +-- function ........................ funcall with the line
  .
  . ring buffer (MPSC, simple-vector, power-of-two capacity)
  .
writer-loop (src/writer.lisp)                       writer thread "bark-writer"
  wait-on-semaphore (timeout 0.1 s)
  loop: ring-buffer-pop, write-string, terpri
  force-output once per batch
  emit-drop-warning, signal-flush-acks, broadcast-space-available
```

Points worth knowing when reading the code:

- **The macro does one thing.** `define-log-macro` generates `trace`, `debug`, `info`, `warn`, `error` and `fatal`. It inspects the first argument at expansion time when it is a literal keyword (fields only), otherwise at run time: a `logger-p` value is the logger, a keyword starts a fields-only call, anything else is the message. It then calls the level slot with the logger, the message (`nil` for fields-only calls) and the fields. When `*logger*` is `nil` the call is a no-op and never signals.
- **Arguments are evaluated before the slot is called.** A disabled level skips formatting, not argument evaluation. `level-enabled-p` exists for guarding expensive argument construction; it checks the level threshold only, not sampling, filters or compile-time settings.
- **`make-log-fn` builds one closure per level.** The closure declares the `&rest` fields `dynamic-extent`. This is why formatting must complete before the closure returns: the fields list does not outlive the call.
- **Sampling precedes formatting.** A sampled-out call returns before any string is built. See [sampling.md](sampling.md).
- **Function outputs are synchronous.** They share `dispatch-to-output` and `deliver-line` with the async path but have no ring buffer or thread. `deliver-line` also has a bare-stream branch, which `make-logger` never reaches because it wraps streams in an async output. `with-captured-logs` relies on a function output.

The README explains why formatting stays in the caller thread ([Caller-Thread Formatting](../../README.md#caller-thread-formatting)) and why the ring buffer is correct only under x86 store ordering ([Ring Buffer](../../README.md#ring-buffer)). The thread-per-destination rationale is in [Thread-Per-Destination Model](../../README.md#thread-per-destination-model).

## Module Map

`cl-bark.asd` loads `packages` and then twelve files from `src/` serially, in this order. Each file may use anything above it.

| File | Responsibility | Depends on |
|------|----------------|------------|
| `packages.lisp` | Defines the single package `bark` and its export list. Shadows `debug`, `error`, `trace`, `warn` and `formatter`. | `cl` |
| `src/levels.lisp` | Integer levels `+trace+` (1) through `+fatal+` (6), `+level-slot-count+`, name and color tables, `level-from-keyword`, `level-name`. Level 0 is an unused slot so levels index vectors directly. | Nothing |
| `src/conditions.lisp` | `capture` and the `captured-error` struct (condition plus stack snapshot, with bark and dissect frames stripped); the `bark-error` condition hierarchy used for configuration and lifecycle errors. See [condition-serialization.md](condition-serialization.md). | `dissect` |
| `src/timestamps.lisp` | Unix millisecond timestamps. `get-unix-timestamp-ms` has an SBCL fast path; `current-log-timestamp-ms` is the function custom formatters must call because it honors the replay override used by buffering. | `local-time` (non-SBCL path) |
| `src/format-util.lisp` | Per-thread reusable `string-output-stream` (`with-format-stream`), `key-string` with a bounded symbol cache, helpers shared by formatters. | `bordeaux-threads` |
| `src/json.lisp` | JSON escaping and value serialization, depth and length limits, and, despite the file name, the `formatter` struct (`prepare-fn`, `format-fn`), `make-formatter`, `make-concat-prepare-fn`, and the default JSON formatter. | levels, conditions, timestamps, format-util |
| `src/logfmt.lisp` | `key=value` serialization and `make-logfmt-formatter`. | json (formatter protocol), format-util |
| `src/pretty.lisp` | ANSI-colored console formatter and `make-pretty-formatter`; condition output with stack frames. | json (formatter protocol), `dissect` |
| `src/ring-buffer.lisp` | Lock-free MPSC ring buffer of strings: CAS claim on `head`, single-consumer `ring-buffer-pop`, atomic drop counter, `ring-buffer-push` (counts drops) and `ring-buffer-offer` (does not). | `atomics`, `bordeaux-threads` |
| `src/writer.lisp` | `async-output` struct, `make-async-output`, `writer-loop`, `flush-async-output`, `stop-async-output`, `blocking-deliver`, drop warnings. See [blocking-mode.md](blocking-mode.md). | ring-buffer, json (formatter), `bordeaux-threads`, `atomics` |
| `src/output.lisp` | `make-tee` and `tee`, destination and formatter-group structs, `emit-to-tee`, `deliver-line`, `dispatch-to-output`. See [multi-output.md](multi-output.md). | writer, json |
| `src/logger.lisp` | `logger` struct, `noop`, `make-log-fn`, `make-logger`, `make-child`, `set-level` and `wire-level-fns`, sampling structs and constructors, `flush`, `stop`, `with-context`, `with-captured-logs`, the six log macros. | everything above |
| `src/buffer.lisp` | `with-log-buffer`: a buffer-logger whose level slots capture entries, replayed through the original logger's pipeline on exit. See [request-scoped-buffering.md](request-scoped-buffering.md). | logger (`wire-level-fns`, `dispatch-to-output`), timestamps |

The formatter protocol is documented in [formatter-protocol.md](formatter-protocol.md). The struct living in `json.lisp` is a load-order convenience, not a statement that formatters are JSON-specific.

### External dependencies

| System | Used for |
|--------|----------|
| `atomics` | CAS and atomic increment in the ring buffer, drop counters, windowed counters, `set-level-sampling` |
| `bordeaux-threads` | Writer threads, semaphores (notify and flush acknowledgement), locks and condition variables for blocking mode, `*default-special-bindings*` for the per-thread format stream |
| `dissect` | Stack capture for `capture`; frame names in the pretty formatter |
| `local-time` | Millisecond timestamp on non-SBCL implementations |

The benchmark and test systems (`cl-bark/bench-comparative`, `cl-bark/tests` and others) declare their own dependencies, including `fiveam`, `yason`, and weakly `log4cl`, `vom` and `verbose`. They are not runtime dependencies.

### Package and shadowing

All code lives in one package, `bark`. The log macros are named after the levels, so `trace`, `debug`, `warn` and `error` are shadowed, as is `formatter` (the struct). Inside the package, internal code reaches the standard `error` and `warn` through `cl:error` and `cl:warn`. Consumers are expected to call everything with the `bark:` prefix; see [README § Note on Symbol Shadowing](../../README.md#note-on-symbol-shadowing).

## Where to Read Next

| Document | Read it for |
|----------|-------------|
| [decisions.md](decisions.md) | Cross-cutting decision log and the reasons behind choices not covered by a topic document |
| [multi-output.md](multi-output.md) | Tee fan-out, per-destination filters and formatters, explicit logger argument |
| [formatter-protocol.md](formatter-protocol.md) | The `prepare-fn` and `format-fn` contract, writing a formatter |
| [condition-serialization.md](condition-serialization.md) | `capture`, stack snapshots, how formatters render conditions |
| [request-scoped-buffering.md](request-scoped-buffering.md) | `with-log-buffer`, replay, timestamp override |
| [blocking-mode.md](blocking-mode.md) | Back-pressure instead of drop-on-full, timeouts, stop-while-blocked |
| [sampling.md](sampling.md) | Windowed counters, consistent hash sampling, ordering relative to other features |
| [benchmarks.md](benchmarks.md) | Methodology, what the numbers do and do not show |

User guides: [docs/sampling.md](../sampling.md), [docs/blocking-mode.md](../blocking-mode.md), [docs/value-serialization.md](../value-serialization.md).

## Comparison with Other Common Lisp Loggers

Two sources are used, and they answer different questions. Neither makes claims about the current internals of the other libraries beyond what is stated.

### Measured against log4cl, vom, verbose

`bench/comparative.lisp` drives the other libraries through small adapters. What those adapters show about each library's API as used by the benchmark:

| Library | API shape in the benchmark | Structured fields | Async |
|---------|----------------------------|-------------------|-------|
| cl-bark | `bark:info logger "msg" :key value ...` | Yes: keyword-value pairs, serialized to JSON or logfmt | Yes by default; the benchmark runs it with `:blocking t` for a like-for-like comparison |
| log4cl | `log:info` with a format string and format arguments, a `fixed-stream-appender` and `simple-layout` | No: the adapter encodes fields as `key=~a` text | Treated as synchronous |
| vom | `vom:info` with a format string and arguments, `vom:*log-stream*` redirected | No: same text encoding, no context mechanism | Treated as synchronous |
| verbose | No adapter code; a comment in the file says it "has its own async pipeline" | Not exercised | Per that comment, yes |

The harness prints "all loggers synchronous except verbose". Because verbose has no adapter, there are no verbose results. The log4cl and vom adapters inline context into the message text because neither has a structured-context mechanism that the benchmark uses.

What the published numbers say (README § Benchmarks, [bench/results/sample.txt](../../bench/results/sample.txt); sink is a discard stream, so these measure framework overhead, not I/O):

- Disabled-level calls: all three are in single-digit to low-double-digit nanoseconds.
- Single-thread enabled calls with fields: log4cl is faster than cl-bark (it formats less and writes straight to the stream); the README attributes this to text versus structured output. cl-bark allocates a result string per call; log4cl reports none for simple messages.
- Eight threads: cl-bark in blocking mode exceeds log4cl and is close to vom in the sample run. The README attributes this to the lock-free ring buffer; this document does not independently verify that explanation.

`BENCHMARKS.md` reports only cl-bark's own throughput, concurrency scaling and saturation behavior, not the comparative runs. See [benchmarks.md](benchmarks.md) for caveats; the figures come from single runs on one machine.

### Design-time contrast with cl-llog

The design was contrasted with cl-llog. That comparison is a record of architectural intent. cl-llog was not in Quicklisp then and has presumably changed; nothing below describes its current internals.

| Aspect | cl-bark | cl-llog as assessed at design time |
|--------|--------------|-------------------------------------|
| Hot-path dispatch | Function-slot swap; disabled level calls `noop` | Runtime `should-log-p` check |
| Object model | `defstruct`, plain function formatters | `defclass`, generic functions for encoding and output |
| Queue payload | Finished string | Entry object plus field objects |
| Where serialization runs | Caller thread | Writer thread |
| Queue | Lock-free MPSC ring buffer | Circular buffer under a mutex |
| Static context | Pre-serialized at child creation | Serialized per call |

The difference in outlook is that cl-bark asks what can be left out of the hot path; for the queue, see [Unbounded queue](#unbounded-queue).

## Alternatives Considered

### CLOS dispatch for formatters and outputs

A class hierarchy of encoders and outputs gives users `defmethod` extension points. Rejected because CLOS dispatch would run on every call and the goal was no CLOS in the hot path. Formatters are structs holding two functions; extension means writing a function. The cost is that extension is by composition, not by subclassing.

### Runtime level check on every call

Comparing the call's level against the logger's threshold in the enabled path is simpler. It is rejected to avoid a branch and a slot read per call; the slot swap makes the disabled case a single call to `noop`. The cost is the argument-evaluation caveat above and that `set-level` must rewrite all six slots (`wire-level-fns`).

### Formatting in the writer thread

Pushing structured entries and formatting on the consumer would shorten the caller's path. The README gives four reasons against it: callers are the natural parallelism, `dynamic-extent` fields cannot cross threads without copying, `*log-context*` must be read in the calling thread, and tee needs the line before fan-out to share it. A separate formatter thread pool is rejected for adding a second queue handoff. Full text in [README § Caller-Thread Formatting](../../README.md#caller-thread-formatting).

### One writer thread for all destinations

A shared writer simplifies thread management. The README rejects it because a slow destination would stall fast ones; each destination owns a thread and ring buffer. The cost is one OS thread per destination.

### Unbounded queue

The ring is bounded (default capacity 8192, minimum 16, power of two) and drops by default, so a stuck sink cannot grow memory without limit and producers never wait on the writer. Blocking mode is the opt-in alternative for callers that prefer back-pressure over loss ([blocking-mode.md](blocking-mode.md)).

### Hierarchical logger registry, hooks, rate-limit tokens

The README lists a named logger registry as a non-goal (global mutable state; use `defvar`). Hooks and token-bucket limiting are not implemented; windowed counters cover rate limiting.

## Invariants and Trade-offs

- **The ring buffer holds strings.** Nothing downstream of `deliver-line` interprets events. Filters, sampling and transforms therefore run before the push.
- **The payload is not fenced.** Ring-buffer slot reads and writes are plain `svref`. Correctness depends on x86 store ordering; see README. A port to a weakly ordered CPU needs barriers.
- **Single consumer.** `ring-buffer-pop` and the drain loop assume one reader per ring. `stop-async-output` drains the remainder after joining the thread for the same reason.
- **A logger needs `stop` for a clean shutdown.** Writers wake every 0.1 s without a signal, but only `stop` (or the automatic exit drain, see `*exit-flush-timeout*`) joins the thread and drains. Child loggers cannot be stopped; `stop` on a child signals `bark-child-operation-error`.
- **Child loggers snapshot at creation.** A child copies the parent's formatter, output and `prepared` string and receives the parent's sampler objects at creation; later parent changes are not reflected.
- **Bounded memory per formatter.** Depth, length and stack-frame limits (`*max-json-depth*`, `*max-json-length*`, `*max-json-stack-frames*`, and pretty equivalents) bound line size and thus caller latency. The key-string cache stops growing at 1024 entries.
- **Portability is narrower than the dependency list suggests.** `src/writer.lisp` calls `sb-thread:condition-broadcast`, and `src/json.lisp` and `src/logfmt.lisp` call `sb-ext:float-nan-p` without reader conditionals. In the current tree the library loads on SBCL only. The timestamp fallback and the exit-hook branches for other implementations are present but unreachable in practice.
- **Throughput figures are sink-bound.** Benchmarks use a discard stream; real throughput is limited by the destination and by the single writer per destination.

## Interactions

| Feature | Interaction |
|---------|-------------|
| Sampling and levels | A disabled level never reaches sampling. Sampling runs inside the enabled closure, before field transform and formatting. |
| Sampling and tee filters | Sampling is per logger and runs first; tee filters run per destination afterwards. A sampled-out event reaches no destination. |
| Drop-on-full and formatting | `deliver-line` receives an already formatted string, so a full buffer drops after the formatting cost has been paid. The drop counter and the drop warning are written by the writer thread. The README performance table says formatting is skipped on drop; the code does not do that. |
| Tee and `prepared` | For a tee, `prepared` is a vector with one entry per formatter group, produced by each group's own `prepare-fn`. `make-child` extends each entry. |
| Buffering and sampling | `with-log-buffer` swaps in a buffer-logger with sampler and field transform cleared; replay goes through the original logger's `dispatch-to-output` with the original timestamp bound, so sampling does not apply to buffered entries. See [request-scoped-buffering.md](request-scoped-buffering.md). |
| Buffering and explicit loggers | Only calls through `*logger*` are buffered; calls with an explicit logger argument bypass the buffer. |
| Field transform and context | The transform applies to per-call fields and dynamic context at call time, and to static context once at logger or child creation. |
| Blocking mode and shutdown | `stop-async-output` clears `running`, broadcasts on the space condition variable and joins the writer so blocked producers return. See [blocking-mode.md](blocking-mode.md). |

## Non-Goals

Consistent with the README and the code:

- Log rotation, aggregation and shipping. Use external tools.
- Binary wire formats. A formatter can emit any string, so one can be added without core changes.
- Editor or SLIME integration.
- A named logger registry or hierarchy.
- Filters on static or dynamic context, and output override on `make-child`; see [README § Non-Goals](../../README.md#non-goals).
- Exposing the tee's internal structs as a public API.
- Hooks, token-bucket rate limiting and an in-memory log browser, which are not implemented.
