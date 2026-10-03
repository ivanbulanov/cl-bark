# cl-bark Benchmark Harness Design

Why the `bench/` harness is shaped the way it is: what it measures, how a sample is taken, and which numbers it can and cannot support. The how-to material lives elsewhere: [README § Benchmarks](../../README.md#benchmarks) covers running, methodology and reading the comparative results, and [BENCHMARKS.md](../../BENCHMARKS.md) holds an earlier set of reference-machine results. This document is for someone extending the harness or deciding whether a number is trustworthy.

## Motivation

The README originally carried nanosecond claims with nothing behind them. The harness exists so that every performance statement can be reproduced on the reader's own machine, and so that the allocation claims (a disabled log call allocates nothing) are checked rather than asserted.

Three questions drive the design:

- **How much time does the logging framework add on the calling thread?** Formatting, field handling, enqueue or blocking write. Disk and terminal behaviour are excluded on purpose.
- **Where does the cost go?** Disabled check, simple message, field count, child context, formatter choice, tee fan-out, buffer saturation, blocking mode, concurrent producers.
- **Roughly how does that compare with other Common Lisp loggers?** An honest, caveated comparison, not a ranking.

Each question has a different failure mode. Sub-microsecond operations are below the resolution of a naive timer. A comparison across loggers with different designs is easy to make unfair. Concurrent throughput needs a start barrier or the thread start-up cost lands in the result. The sections below take these in turn.

## Design Summary

| Piece | File | Purpose |
|-------|------|---------|
| Package, exports | `bench/packages.lisp` | Package `bark-bench`; exports the entry point `run`, the harness utilities and the shared payloads |
| Harness | `bench/harness.lisp` | Clock, statistics, scenario runners, start gate, reporting, scenario registries, entry point |
| Internal suite | `bench/internal.lisp` | 16 scenarios on cl-bark's own modes |
| Comparative suite | `bench/comparative.lisp` | cl-bark, log4cl and vom through adapters, plus a raw string-building baseline |
| Make targets | `Makefile` | Parameter variables and the `bench*` targets |

The shape of a scenario is the same in both suites: a name, a thunk that performs one log call, and a runner that decides how the thunk is timed.

```lisp
;; Batch-measured: each sample times BATCH-SIZE calls.
(run-batch-scenario name thunk &key iterations warmup batch-size)
;; returns (values time-samples bytes-timer name batch-size)

;; Concurrent: THREADS workers, ITERATIONS calls each, one wall-clock interval.
(run-concurrent-scenario name thunk &key iterations warmup threads)
;; returns (values throughput name threads total-messages elapsed-seconds)
```

Runners return raw data and do not print. A separate printer (`print-sampled-result`, `print-batch-result`, `print-throughput-result`, `print-comparative-row`) formats it. Scenarios register a closure with `register-internal-scenario` or `register-comparative-scenario`, and `run-suite` walks the registry.

Scenario names are strings. The registries are alists keyed by name, registration replaces an existing entry of the same name (`string=`), and lookup by `:scenario` uses `string-equal`, so the match is case-insensitive. The Makefile passes `:scenario "$(SCENARIO)"` as a string for the same reason.

## Two ASDF Systems

Both live in `cl-bark.asd`:

| System | Depends on | Contains |
|--------|-----------|----------|
| `cl-bark/bench` | `cl-bark`, `trivial-benchmark`, `trivial-garbage`, `bordeaux-threads`, `cffi` | `bench/packages.lisp`, `bench/harness.lisp`, `bench/internal.lisp` |
| `cl-bark/bench-comparative` | `cl-bark/bench`; weakly: `log4cl`, `vom`, `verbose` | `bench/comparative.lisp` |

The split keeps the internal suite loadable with only the libraries the harness itself needs. A maintainer who wants to profile cl-bark does not need three other loggers installed. The comparative system adds a file to the same package (`bark-bench`) rather than defining its own, so it can call the harness functions and reuse the shared payloads without qualification.

### Why competitors are not hard dependencies

A hard `:depends-on` on log4cl, vom and verbose would make the whole benchmark system unloadable whenever any one of them fails to install or compile on a given platform. The harness has to keep working with whatever subset is present. Competitor code is therefore guarded by reader conditionals on feature keywords that `comparative.lisp` computes from package presence:

```lisp
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :log4cl) (pushnew :bark-bench/log4cl *features*)))
```

An adapter for a logger that is not loaded is not compiled into the system and does not appear in the output. A consequence of using `#+` is that the decision is made when `comparative.lisp` is compiled. A cached FASL built while a competitor was absent stays without that adapter after the competitor is installed, until the FASL is rebuilt (`make clean` removes them).

## The Harness

### Timing source

SBCL's `get-internal-real-time` has microsecond resolution (`internal-time-units-per-second` is 1,000,000). The first implementation timed each log call individually through `trivial-benchmark`'s `with-sampling`. Most async log calls take a few hundred nanoseconds, so single-call samples read as zero. The mean was non-zero only because the accumulated total over thousands of samples averaged to a measurable value, and p50 and p99 were all zero. Concurrent throughput had a second problem: with 1,000 messages in a few milliseconds, the quotient produced round numbers such as 200,000 and 1,000,000.

Two changes fixed this, and both are in the current code:

1. **Nanosecond clock.** `get-monotonic-ns` in `bench/harness.lisp` calls `clock_gettime` through CFFI with `CLOCK_MONOTONIC` (constant selected per OS: Linux 1, Darwin 6, FreeBSD 4, and `CLOCK_REALTIME` as the fallback on any other OS). All durations, per-batch and concurrent wall clock, come from this function. `trivial-benchmark` no longer supplies timing.
2. **Small-batch sampling.** Each sample times a batch of N calls, and the per-call estimate is the batch time divided by N. With N of 100 and a call of about 500ns, a sample spans about 50 microseconds. The estimate then has about 10ns of resolution, and the cost of two clock reads is spread over 100 calls.

The two changes are complementary. The nanosecond clock removes the quantization problem. Batching amortizes the clock read itself, whose cost is not measured in this repository, and smooths single-call noise.

`trivial-benchmark` is still used, but only for allocation. A `timer` object is created per scenario, and `with-sampling` wraps each batch so that the `bytes-consed` metric is recorded. `bytes-per-call` divides the total by samples times batch size, and returns `:n/a` if the metric cannot be read (the printers then omit the bytes figure).

### Batch sizes

There are two batch sizes. `*default-sample-batch-size*` (100) is the batch for ordinary scenarios. `*batch-size*` (100,000) is the default of `run-batch-scenario` and is used by scenarios whose per-call cost is a few nanoseconds or whose behaviour is a flood. The reasoning for each class:

| Scenario class | Per-call scale | Batch size | Why |
|----------------|---------------|-----------|-----|
| Disabled-level check | a few ns | 100,000 | A batch of 100 would last well under a microsecond and read as noise. 100,000 calls make a batch of hundreds of microseconds. |
| Enabled call, simple or with fields, async or blocking | hundreds of ns to several us | 100 | A batch of 100 spans tens to hundreds of microseconds, which is many timer ticks and few enough calls that a GC pause stays visible as a batch outlier. |
| Buffer-full drop | contention dominated | 100,000 | A flood against a 16-slot ring. Large batches keep the writer thread draining at its natural rate. |
| Raw baseline | hundreds of ns | 100 | Same class as an enabled call. |

### What smoothing does to p99

Per-call p50, mean and p99 are statistics over per-batch averages. A single 50-microsecond GC pause inside a 100-call batch appears as 0.5 microseconds added to that batch's per-call estimate, not as a 50-microsecond spike. p99 across 10,000 batches still shows the case where a meaningful share of batches hit GC. It cannot show the worst single call, and it understates the tail of an individual call by up to a factor of N. For disabled-level and buffer-full-drop the effect is larger, because a sample averages 100,000 calls.

Percentiles are linearly interpolated between neighbouring ranks of the sorted sample vector (`compute-percentile`). The reported statistics are exactly p50, mean and p99, from `compute-sample-stats`. p99.9 is not reported; with the default 10,000 samples it rests on ten points.

### Execution protocol

For each scenario, `run-batch-scenario` does the following:

1. **Warm up in full batches.** It runs `ceiling(warmup / batch-size)` complete batches. The warmup uses the same tight loop as the measurement, so the branch predictor and any call-site caches are trained on the code path that is later timed. Warming with individual calls would warm a different loop. At the defaults this is 100 batches (10,000 calls) for a batch of 100, and a single batch (100,000 calls) for a batch of 100,000, because the warmup count is rounded up to whole batches.
2. **Full GC.** `(trivial-garbage:gc :full t)` runs once, after warmup and before measurement, so warmup garbage does not fall into the first samples.
3. **Measure.** `iterations` samples, each one batch inside `with-sampling`. The clock reads are inside the `with-sampling` form, so its bookkeeping is outside the timed region.

There is no GC between samples. Allocation pressure is part of what a logger costs, and forcing collections between samples would hide the real GC share of the tail. Collections therefore occur during measurement, inflate the tail percentiles, and the report header says so ("p99 includes GC pauses and OS scheduling jitter").

Every bench file starts with `(declaim (optimize (speed 3) (safety 1)))`, matching the policy cl-bark itself is compiled with. Without it the harness code and scenario closures would compile under the default policy and the numbers would not reflect cl-bark's compiled behaviour.

Each scenario builds its own logger and stops it with `bark:stop` in an `unwind-protect`, so writer threads from one scenario do not run during the next.

### The start gate

`make-gate`, `gate-wait` and `gate-open` implement a start barrier from a `bordeaux-threads` semaphore. `gate-open` signals the semaphore once per waiting thread. Condition variables were rejected for this: the portable `bordeaux-threads` version 1 interface has no broadcast operation. Semaphores exist in both the version 1 and version 2 interfaces, and signaling once per thread releases all of them.

## The Discard Sink

Every logger writes to `*discard-stream*`, a `(make-broadcast-stream)` with no component streams. It is portable (no `/dev/null` path) and it isolates framework overhead from I/O.

What it does isolate: disk latency, terminal rendering, buffering policy of a real file stream, and OS write behaviour.

What it does not isolate:

- The stream function calls themselves. `write-string`, `terpri` and `force-output` still dispatch on the broadcast stream and cost something. The cost is not zero, but it is the same for every logger.
- Formatting work that happens before the stream. String building, number printing and JSON escaping are all measured, which is the point.
- Memory behaviour. A logger that builds a line string per call allocates it even though it is discarded immediately.

A discard-sink number is therefore a lower bound on what a user sees. Real throughput is lower.

## The Internal Suite

The internal suite runs in default asynchronous mode unless noted. `make-bench-logger` builds the logger: level `:trace`, output `*discard-stream*`, JSON formatter, capacity 8192, optional `:blocking`. All scenarios use the same constant payloads (`*bench-message*`, five- and ten-field plists, a four-field context) so differences between rows come from the logger, not the data. The payloads cover strings, integers, doubles and booleans. Exotic value types are a correctness matter for the tests and not part of the benchmark.

| Scenario | What it exercises | Batch size | Mode |
|----------|------------------|-----------|------|
| `disabled-level` | `bark:debug` on a logger set to `:warn`; checks the allocation claim | 100,000 | batch (`print-batch-result`) |
| `simple-message` | Message only, async | 100 | sampled |
| `message-5-fields` | Message with five keyword fields | 100 | sampled |
| `message-10-fields` | Message with ten keyword fields | 100 | sampled |
| `child-no-context` | `make-child` with no context | 100 | sampled |
| `child-with-context` | `make-child` with a four-field context (pre-serialized) | 100 | sampled |
| `dynamic-context` | `with-context` binding the same four fields around each call | 100 | sampled |
| `field-transform` | Child with an identity `:field-transform`, five fields | 100 | sampled |
| `formatter-comparison` | JSON, logfmt, pretty in blocking mode; prints three rows named `formatter-json`, `formatter-logfmt`, `formatter-pretty` | 100 | sampled |
| `tee-2-destinations` | Tee of two destinations, JSON and logfmt | 100 | sampled |
| `tee-shared-formatter` | Tee of two destinations, both JSON formatters | 100 | sampled |
| `buffer-full-drop` | Capacity-16 buffer flooded; drop-heavy workload | 100,000 | batch |
| `async-large-buffer` | Capacity 131072 so enqueue is measured without drops | 100 | sampled |
| `concurrent-1-thread` | Five-field call from one worker | n/a | throughput |
| `concurrent-8-threads` | Five-field call from `*default-threads*` workers | n/a | throughput |
| `blocking-mode` | `:blocking t`, five fields | 100 | sampled |

Notes on specific rows:

- `child-with-context` against `dynamic-context` shows the value of pre-serializing context into the child versus rebuilding it per call.
- `formatter-comparison` uses blocking mode so that the formatter cost is not mixed with async enqueue variance. The cost of the discard write is the same across the three, so deltas are formatting.
- `async-large-buffer` against `simple-message` separates enqueue cost from drop behaviour: the 131072-slot buffer prevents drops.
- `buffer-full-drop` measures a drop-heavy workload and not the pure drop path. With a 16-slot ring and 100,000 calls per sample the writer thread drains only a few messages per batch, so almost every call takes the drop path, but not all of them.
- `concurrent-8-threads` is named for the default. The thread count comes from `*default-threads*`, set by `THREADS`, so with `THREADS=16` the row keeps the name and runs 16 workers.
- `tee-shared-formatter` builds two separate JSON formatter instances. Despite the name it does not share one formatter object between destinations.

## The Comparative Suite

### Fairness rules

1. **Same sink, same payloads.** All loggers write to `*discard-stream*` with the shared constants.
2. **Idiomatic configuration.** Each competitor is configured the way its documentation describes ordinary stream output, not tuned for speed at the expense of features. The configuration is recorded in the adapter source with comments.
3. **Same logical work through each logger's own API.** log4cl and vom are format-directive loggers and have no field model. For the five- and ten-field scenarios their adapters call the native macro with a format string such as `"method=~a path=~a status=~d ..."` and the values as arguments. They are not wrapped in a shim that accepts keyword fields. The same information is emitted, but the work differs in kind: cl-bark escapes and structures typed values, and the competitors substitute into a format control string. `simple-message` (no fields) is the purest comparison.
4. **Context scenario.** cl-bark logs through a child with pre-serialized context. log4cl and vom have no equivalent, so their adapters embed the context as a literal prefix in the message string. This measures the closest equivalent, not identical work.
5. **cl-bark in blocking mode only.** The two cl-bark rows run with `:blocking t`: `cl-bark (blocking, json)` and `cl-bark (blocking, logfmt)`. Async mode returns after an enqueue and excludes the formatted write from the caller's time on the writer thread, while synchronous loggers include the write. Putting an async enqueue number next to synchronous totals in one table invites a comparison that does not hold. Async is measured in the internal suite only. Both formatters are listed because the formatter differs; the label names both mode and formatter.
6. **Concurrent rows use the five-field adapter.**

### Adapter protocol

An adapter is a plain list of seven elements, not a CLOS protocol and not a struct:

```lisp
(name setup-fn log-message log-fields-5 log-fields-10 log-with-context teardown-fn)
```

Adapters are pushed on `*available-loggers*` and iterated with `reverse`, so the table order is source order. `adapter-getter` selects one of the four log functions by keyword (`:message`, `:fields-5`, `:fields-10`, `:with-context`). The reason for plain functions is size: with four adapters, a protocol and generic functions add an abstraction layer, while a list of closures is more transparent. Setup runs before and teardown after each scenario (inside `unwind-protect`), so a scenario leaves no appender, redirected stream or running writer thread behind.

Adding a logger means writing the six functions, guarding them with a feature keyword, and pushing the list. No scenario code changes.

| Logger | Configuration | Notes |
|--------|---------------|-------|
| `cl-bark (blocking, json)` | `make-logger :level :trace :output *discard-stream* :blocking t`; child with `*bench-context*` | Default JSON formatter |
| `cl-bark (blocking, logfmt)` | Same with `make-logfmt-formatter` | Isolates formatter cost in the synchronous setting |
| `log4cl` | `fixed-stream-appender` on the discard stream with `simple-layout` at the root logger, level info | Simple layout is the lightest built-in layout; all appenders removed and level restored at teardown |
| `vom` | `vom:*log-stream*` rebound to the discard stream, `(vom:config t :info)` | Original stream restored at teardown |

### Scenario catalogue

| Scenario | What it exercises | Batch size | Measurement mode |
|----------|------------------|-----------|------------------|
| `disabled-level` | Disabled call; cl-bark (blocking, json), log4cl and vom each set to a level that disables the call | 100,000 | batch, no bytes column |
| `simple-message` | Message only | 100 | sampled, with bytes |
| `message-5-fields` | Five fields | 100 | sampled, with bytes |
| `message-10-fields` | Ten fields | 100 | sampled, with bytes |
| `with-child-context` | Four-field context | 100 | sampled, with bytes |
| `concurrent-1-thread` | Five-field call, one worker | n/a | throughput |
| `concurrent-8-threads` | Five-field call, `*default-threads*` workers | n/a | throughput |
| `raw-baseline` | Hand-written string building | 100 | sampled |

`disabled-level` is a special case: each logger needs a different setting to disable the call, so the scenario configures each one inline and does not use the adapter list. Only cl-bark (blocking, json) is included for cl-bark in this scenario; the logfmt row would measure the same level check.

### Raw baseline

`raw-baseline` is not a logger and has no adapter. It builds a fixed JSON-like line from constant fragments with `with-output-to-string` and `write-string`, then writes it to the discard stream with `terpri` and `force-output`. It is a floor for "build a string and write it", including the string allocation. It does no value serialization, since the fragments are literal text, so a logger that serializes typed values cannot reach it. It exists only for the five-field case.

### verbose

`verbose` is listed as a weak dependency and is flagged by a feature keyword when its package is present, but `bench/comparative.lisp` currently has no verbose adapter: only a comment where one would go. No verbose row is produced. A verbose row would need an annotation because it runs an asynchronous pipeline and the number would reflect enqueue latency. The header line printed by `run-comparative-scenario` ("all loggers synchronous except verbose") refers to a row that does not exist.

## Concurrency Scenarios

`run-concurrent-scenario` measures aggregate throughput, messages per second, across `threads` workers each running `iterations` calls. Iterations are per thread, so total messages is threads times iterations (default 100,000 per thread, `CONCURRENT_ITERATIONS`). The value is deliberately larger than the latency iteration count: at 1,000 messages the run is over in a few milliseconds and the result quantizes.

Protocol:

1. Warm up single-threaded for `warmup` calls on the main thread.
2. Full GC.
3. Create the workers. Each blocks in `gate-wait`.
4. `gate-open` releases them, then the main thread reads the clock and joins every worker.
5. Elapsed time is the clock difference around the joins; throughput is total messages over elapsed seconds.

Thread creation is outside the timed window, which is the reason for the gate. The clock is read after the gate opens, not before: starting it first would include the wake-up latency of all workers, and reading it inside a worker would require agreement among threads. The cost is a small race. Workers can begin running before the main thread reads its clock, so elapsed can be slightly understated and throughput slightly overstated. The effect shrinks as the run lengthens. The join ordering also means elapsed includes the slowest worker's tail.

### Why per-call percentiles are not reported under concurrency

A per-call latency distribution under contention would need every thread to record timestamps into a preallocated array and aggregate afterwards. That adds implementation complexity and, more importantly, adds clock reads and memory traffic inside the contended region, which perturbs the thing being measured. Aggregate throughput is the primary question for the concurrent scenarios, so the harness reports only that.

The async internal rows count attempted messages. The default buffer holds 8192 entries, so a fast producer set can overrun it and drop messages, and dropped calls are still counted in the total. The harness does not read or print drop counts.

## Report Format

`print-header` writes the suite name, `lisp-implementation-type`, `lisp-implementation-version` and `machine-type`, then two caveat lines (discard sink; p99 includes GC and scheduling jitter).

| Printer | Used for | Output |
|---------|----------|--------|
| `print-sampled-result` | Batch of 100 scenarios | name, then p50, mean, p99 per call and bytes per call |
| `print-batch-result` | Batch of 100,000 scenarios | name with batch size, per-call mean, then per-batch p50, mean and p99, then bytes |
| `print-throughput-result` | Concurrent scenarios | name, threads, total messages, elapsed seconds, msg/sec |
| `print-comparative-header` and `print-comparative-row` | Comparative tables | columns logger, p50, mean, p99, bytes |

`format-time` chooses ns, us, ms or s. In `print-batch-result`, the per-call mean is derived from the per-batch mean divided by the batch size. When it is below 10 nanoseconds the line is the string `per-call: < 10ns` and the percentiles are not printed. The harness does not claim a precision it does not have: loop overhead and clock quantization dominate that range. The percentiles in the other form are per batch and not per call, and the line says so.

The harness does not persist results. `bench/results/sample.txt` is a hand-triggered capture produced by `make bench-update-sample`, with a header recording the machine, SBCL version, date, iteration count, batch size and timer. It is reduced-iteration output meant as an illustration.

## Make Variables and Targets

Variables (override on the command line):

| Variable | Default | Passed as |
|----------|---------|-----------|
| `ITERATIONS` | 10000 | `:iterations` |
| `WARMUP` | 10000 | `:warmup` |
| `THREADS` | 8 | `:threads` |
| `CONCURRENT_ITERATIONS` | 100000 | `:concurrent-iterations` |
| `SUITE` | empty | `:suite :<value>`, only when set |
| `SCENARIO` | empty | `:scenario "<value>"`, only when set |

`SUITE` and `SCENARIO` are conditional, so an unset value leaves the keyword out and `run` applies its default (both suites, all scenarios).

| Target | Effect |
|--------|--------|
| `bench` | Loads `cl-bark/bench-comparative` and calls `bark-bench:run` with the variables above |
| `bench-quick` | `bench` with `ITERATIONS=1000 WARMUP=1000 CONCURRENT_ITERATIONS=10000` |
| `bench-full` | `bench` with `ITERATIONS=50000 WARMUP=10000 CONCURRENT_ITERATIONS=100000` |
| `bench-internal`, `bench-comparative` | `bench` with `SUITE` set |
| `bench-update-sample` | Writes a header plus the output of `bench-quick` to `bench/results/sample.txt`, filtering compiler notes with `grep -v` |

Every target loads the comparative system, which loads the internal one, so the internal suite is not selectable without compiling the comparative file. If a `SCENARIO` is named without a `SUITE`, `run` looks for it in both suites and prints `Unknown scenario` for each suite that lacks it. `disabled-level` exists in both suites, so it runs twice without `SUITE`.

Total call count is iterations times batch size. For batch-100,000 scenarios at the defaults that is 10^9 calls per scenario, and 5 times 10^9 under `bench-full`. That is why the quick target exists.

## Alternatives Considered

### Per-call timing with the standard clock

Time each call with `get-internal-real-time`, as the first implementation did through `with-sampling`. Rejected because the resolution is a microsecond and most calls take less, so samples read as zero. Even a finer clock leaves a per-read cost that is a significant fraction of a short call.

### A single fixed batch size for every scenario

One value for all scenarios. Rejected because the per-call scale spans three orders of magnitude. A batch large enough for a few-nanosecond call would hide GC effects in the several-microsecond scenarios, and one small enough for those would make the disabled-level check read as noise.

### Platform-neutral timing only (no CFFI)

Batching makes a nanosecond timer less necessary, and CFFI is an implementation-specific dependency. The harness uses one anyway: `cl-bark/bench` depends on `cffi` and uses `clock_gettime`. The commit that introduced it states the aim as nanosecond precision for the batch measurement. The cost is portability: the clock ids are chosen for Linux, Darwin and FreeBSD, and any other OS falls back to `CLOCK_REALTIME`, which is wall time and can jump. Windows has no `clock_gettime` and is not supported by the harness.

### Replacing `trivial-benchmark`

Still used, for the `bytes-consed` metric. The harness takes timing from its own clock, but dropping the library would mean calling an SBCL allocation counter directly, and the library gives a portable metric hook.

### Hard ASDF dependency on competitors

Rejected, see above: one failing library would make the whole benchmark system unloadable.

### A CLOS adapter protocol

Rejected for scale: a list of closures is more transparent than generic functions for a handful of adapters.

### Showing cl-bark in async mode in the comparative table

Rejected because async enqueue latency excludes the I/O-side work that synchronous loggers perform on the caller thread, which makes the comparison misleading.

### A real file or disk sink

Rejected because the result would be dominated by filesystem and operating system behaviour, not by the logging framework.

### Forced GC between samples

Rejected because it would hide the allocation cost that is part of the framework overhead and would make the GC share of the tail invisible. The harness collects once per scenario instead.

### Condition variables for the start barrier

Rejected because `bordeaux-threads` version 1 has no broadcast and semaphores work in both versions.

### Tuning competitors for speed, or shimming them to accept structured fields

Rejected. A benchmark of a logger configured against its documentation, or called through a custom adapter layer, measures the shim.

### p99.9

Rejected: with 10,000 samples it is the tenth worst point and mostly GC and scheduler noise. The header already warns that p99 contains both.

### Per-call latency percentiles for concurrent scenarios

Deferred, see "Why per-call percentiles are not reported under concurrency".

## Validity Caveats

- **Loop overhead is included.** The counter increment, comparison and thunk call through `funcall` are part of each batch. For disabled-level this can be a large share of the result, which is why the output reads `< 10ns` and not a figure. The `funcall` of a closure is also part of every scenario, the same for all loggers.
- **p99 includes GC and scheduling.** There is no GC between samples, and the harness does not pin threads or isolate cores. Another process on the machine moves the tail.
- **Smoothing hides single-call spikes.** See the p99 discussion above.
- **Fixed scenario order.** Scenarios run in registration order, and later scenarios may benefit from warmer caches. The order is not randomized. Run a single scenario with `SCENARIO` to check whether position matters.
- **Warmup is single-threaded in the concurrent scenarios.** Worker threads begin cold with respect to per-thread state, caches and any thread-local allocation regions.
- **Start race.** The clock is read after `gate-open`; see Concurrency Scenarios.
- **Bytes include harness consing.** The allocation counter covers the whole `with-sampling` region, including the loop and the clock read. The harness does not subtract its own share.
- **Allocation is per call, averaged.** Bytes come from a total divided by calls, so there is no distribution.
- **Format-directive loggers do different work.** Interpret the field scenarios as cost of emitting the same information, not the same operation. The README explains the practical reading.
- **Async rows are not comparable to synchronous rows.** This is why the comparative table uses blocking mode for cl-bark.
- **Drop counts are not reported.** `buffer-full-drop` and the async concurrent scenarios can drop messages; the harness neither counts nor prints them. A reader of those rows must remember that some of the calls were drops.
- **Competitor setup is not neutral under a shared image.** log4cl and vom keep global state (root logger, stream variable). Teardown restores it, but the harness and the competitors share one image and one heap.
- **Illustrative numbers.** Results depend on machine and SBCL version; numbers from different machines are not comparable.

## Interactions

What the scenarios exercise in the library:

| Library feature | Scenarios |
|-----------------|-----------|
| Level check and the disabled path (`bark:debug` with a higher threshold) | `disabled-level` (both suites) |
| Caller-thread formatting into a string | All enabled scenarios; `formatter-comparison` separates JSON, logfmt and pretty |
| Ring buffer enqueue and the writer thread (async) | `simple-message`, field scenarios, `async-large-buffer`, `concurrent-*` (internal) |
| Ring buffer saturation and the drop path | `buffer-full-drop` |
| Blocking mode ([blocking-mode.md](blocking-mode.md)) | `blocking-mode`, `formatter-comparison`, and the cl-bark rows of the comparative suite |
| Child loggers and pre-serialized context | `child-no-context`, `child-with-context`, `with-child-context` |
| Dynamic context (`with-context`) | `dynamic-context` |
| Field transform | `field-transform` |
| Multi-output tee ([multi-output.md](multi-output.md)) | `tee-2-destinations`, `tee-shared-formatter` |
| Multi-producer scaling | `concurrent-1-thread`, `concurrent-8-threads` |

The benchmark code uses public API only: `make-logger`, `make-child`, `make-tee`, `with-context`, `set-level`, `stop`, the log macros and the formatter constructors. A change to those signatures means touching `bench/internal.lisp` and the cl-bark adapters in `bench/comparative.lisp`.

## Non-Goals

- **Sustained throughput and saturation testing.** Requires rate control, steady-state detection and saturation-point identification. Valuable follow-up, not implemented.
- **End-to-end disk latency.** Dominated by the filesystem and operating system, not by the framework.
- **Request-scoped buffering (`with-log-buffer`).** A workflow feature, not a hot-path one; its benchmark value is low. Not covered.
- **Compile-time elimination.** The result is trivially zero and the macro expansion shows it.
- **Per-call percentiles under concurrency.** See above.
- **Scenario randomization.** Acknowledged as a source of ordering bias; `SCENARIO` is the workaround.
- **Drop-count reporting.** Not implemented for `buffer-full-drop`.
- **Result persistence and diffing.** No machine-readable output (JSON or CSV) and no comparison between runs. `sample.txt` is text.
- **A statistical test across runs.** The harness reports one run's distribution; run-to-run variance is the reader's to estimate.
