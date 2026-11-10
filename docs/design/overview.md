# cl-bark Architecture Overview

The map of cl-bark: the problem it solves, the one rule that shapes the design, how a single log call travels from macro to bytes on a stream, what each source file is responsible for, and the thread, ring-buffer and formatting model. For usage, see the [README](../../README.md) and the [index](../README.md).

## Motivation

A logger sits inside the code it observes, so its cost is paid by application threads. Three costs matter:

- Disabled calls. Most `trace` and `debug` calls are off in production. They should cost close to nothing.
- Enabled calls. Formatting and I/O must not make the application wait on a slow disk, pipe or socket.
- Structure. Operators want key-value fields, not format strings, so output can be parsed by machines.

The design (Pino-inspired, extended with ideas from zerolog and slog) has four goals: high performance, structured output, flexibility (runtime level changes, swappable formatters, child loggers, dynamic context) portability, which is limited to SBCL; see "Invariants and Trade-offs".

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

- The macro does one thing. `define-log-macro` generates `trace`, `debug`, `info`, `warn`, `error` and `fatal`. It inspects the first argument at expansion time when it is a literal keyword (fields only), otherwise at run time: a `logger-p` value is the logger, a keyword starts a fields-only call, anything else is the message. It then calls the level slot with the logger, the message (`nil` for fields-only calls) and the fields. When `*logger*` is `nil` the call is a no-op and never signals.
- Arguments are evaluated before the slot is called. A disabled level skips formatting, not argument evaluation. `level-enabled-p` exists for guarding expensive argument construction; it checks the level threshold only, not sampling, filters or compile-time settings.
- `make-log-fn` builds one closure per level. The closure declares the `&rest` fields `dynamic-extent`. This is why formatting must complete before the closure returns: the fields list does not outlive the call.
- Sampling precedes formatting. A sampled-out call returns before any string is built. See [sampling.md](sampling.md).
- Function outputs are synchronous. They share `dispatch-to-output` and `deliver-line` with the async path but have no ring buffer or thread. `deliver-line` also has a bare-stream branch, which `make-logger` never reaches because it wraps streams in an async output. `with-captured-logs` relies on a function output.

## Threads and the ring buffer

### Thread per destination

Each destination has its own writer thread and ring buffer, so N destinations run N writer threads. A slow destination such as a network sink cannot hold up a fast one such as stderr. There is no thread pool or shared-writer coordination, and an idle writer is blocked on a semaphore, which costs one kernel thread and little memory.

### Ring buffer

The ring buffer is a lock-free MPSC queue (many producers, one consumer):

```
Producer threads              Writer thread
     |                              |
     +- format message              |
     +- CAS claim slot in ring ->   |
     +- write string to slot        +- pop slots in batch
     +- signal semaphore            +- write-string to stream
                                    +- force-output
                                    +- check drop counter
                                    +- wait on semaphore
```

The payload slots are written and read with plain `svref` and `setf`, fenced by a pair of barriers: the producer issues a write barrier after claiming the slot and before storing the string into it, and the writer issues a read barrier after it loads the string, so the string's contents are visible once its pointer is. On x86-64 (total store order) both are no-ops. A memory barrier on each side of the sleeping flag (`notify-writer`, `writer-wait`) makes sure a writer about to sleep either sees the new line or gets the semaphore signal. cl-bark is tested on x86-64 only; ARM64, which is weakly ordered, is untested.

### Caller-thread formatting

Every log call formats the line to a string in the caller's thread and pushes the string into the ring buffer. The writer thread only calls `write-string` and `force-output`. The reasons:

1. N application threads logging format N lines in parallel without coordination. Formatting in the writer would serialize all of it on one thread per destination, and a formatter thread pool would add a second queue and a second handoff per message.
2. Per-call fields are declared `dynamic-extent`, so the `&rest` plist lives on the stack. Formatting in another thread would require copying the fields to the heap.
3. Dynamic context is a special variable that the caller can rebind at any time. The formatter must read it in the caller's thread. Formatting later would need a snapshot of the alist in each ring slot.
4. With a tee, destinations are grouped by formatter identity (`eq`) and the line is formatted once per group. If writers formatted, destinations sharing a formatter would repeat the work.

The cost is per-call latency in the caller. It is bounded by `*max-json-depth*`, `*max-json-length*` and `*max-json-stack-frames*`. Pre-serialized `prepared` context on child loggers removes the per-call cost of static context, and sampling skips formatting for sampled-out messages.

### Cost of a log call

| Operation | Cost |
|-----------|------|
| Log call, level disabled | One indirect call to `noop` |
| Log call, level enabled, async | Formatting, CAS, semaphore signal |
| Log call, buffer full | Formatting, a failed push and one `atomic-incf`; the formatted line is discarded |
| Writer drain, per message | `write-string` and `force-output` |
| Field transform, per field | One `funcall` when set |

To measure on your hardware, see [../benchmarks.md](../benchmarks.md).

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
| `atomics` | CAS and atomic increment in the ring buffer, drop counters, windowed counters, `set-level-sampler` |
| `bordeaux-threads` | Writer threads, semaphores (notify and flush acknowledgement), locks and condition variables for blocking mode, `*default-special-bindings*` for the per-thread format stream |
| `dissect` | Stack capture for `capture`; frame names in the pretty formatter |
| `local-time` | Millisecond timestamp on non-SBCL implementations |

The benchmark and test systems (`cl-bark/bench-comparative`, `cl-bark/tests` and others) declare their own dependencies, including `fiveam`, `yason`, and weakly `log4cl` and `vom`. They are not runtime dependencies.

### Package and shadowing

All code lives in one package, `bark`. The log macros are named after the levels, so `trace`, `debug`, `warn` and `error` are shadowed, as is `formatter` (the struct). Inside the package, internal code reaches the standard `error` and `warn` through `cl:error` and `cl:warn`. Consumers are expected to call everything with the `bark:` prefix; see [Note on Symbol Shadowing](../../README.md#symbol-shadowing).

## Comparison with other loggers

The comparative benchmark against log4cl and vom, and how to read it, is in [../benchmarks.md](../benchmarks.md#reading-the-comparative-results).

## Invariants and Trade-offs

- The ring buffer holds strings. Nothing downstream of `deliver-line` interprets events. Filters, sampling and transforms therefore run before the push.
- The payload is fenced by a write barrier in the producer and a read barrier in the writer, which cost nothing on x86-64; see [Ring buffer](#ring-buffer). Only x86-64 is tested.
- Single consumer. `ring-buffer-pop` and the drain loop assume one reader per ring. `stop-async-output` drains the remainder after joining the thread for the same reason.
- A logger needs `stop` for a clean shutdown. Writers wake every 0.1 s without a signal, but only `stop` (or the automatic exit drain, see `*exit-flush-timeout*`) joins the thread and drains. Child loggers cannot be stopped; `stop` on a child signals `bark-child-operation-error`.
- Child loggers snapshot at creation. A child copies the parent's formatter, output and `prepared` string and receives the parent's sampler objects at creation; later parent changes are not reflected.
- Bounded memory per formatter. Depth, length and stack-frame limits (`*max-json-depth*`, `*max-json-length*`, `*max-json-stack-frames*`, and pretty equivalents) bound line size and thus caller latency. The key-string cache stops growing at 1024 entries.
- Portability is narrower than the dependency list suggests. `src/writer.lisp` calls `sb-thread:condition-broadcast`, and `src/json.lisp` and `src/logfmt.lisp` call `sb-ext:float-nan-p` without reader conditionals. In the current tree the library loads on SBCL only. The timestamp fallback and the exit-hook branches for other implementations are present but unreachable in practice.
- Throughput figures are sink-bound. Benchmarks use a discard stream; real throughput is limited by the destination and by the single writer per destination.

## Interactions

| Feature | Interaction |
|---------|-------------|
| Sampling and levels | A disabled level never reaches sampling. Sampling runs inside the enabled closure, before field transform and formatting. |
| Sampling and tee filters | Sampling is per logger and runs first; tee filters run per destination afterwards. A sampled-out event reaches no destination. |
| Drop-on-full and formatting | `deliver-line` receives an already formatted string, so a full buffer drops after the formatting cost has been paid. The drop counter and the drop warning are written by the writer thread. |
| Tee and `prepared` | For a tee, `prepared` is a vector with one entry per formatter group, produced by each group's own `prepare-fn`. `make-child` extends each entry. |
| Buffering and sampling | `with-log-buffer` swaps in a buffer-logger with sampler and field transform cleared; replay goes through the original logger's `dispatch-to-output` with the original timestamp bound, so sampling does not apply to buffered entries. See [request-scoped-buffering.md](request-scoped-buffering.md). |
| Buffering and explicit loggers | Only calls through `*logger*` are buffered; calls with an explicit logger argument bypass the buffer. |
| Field transform and context | The transform applies to per-call fields and dynamic context at call time, and to static context once at logger or child creation. |
| Blocking mode and shutdown | `stop-async-output` clears `running`, broadcasts on the space condition variable and joins the writer so blocked producers return. See [blocking-mode.md](blocking-mode.md). |
