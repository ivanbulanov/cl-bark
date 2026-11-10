# Benchmarks

How to run the benchmarks and how to read the comparative results. The harness is described in [design/benchmarks.md](design/benchmarks.md).

## Running

```bash
make bench              # both suites, default parameters
make bench-quick        # smoke test (1000 iterations)
make bench-full         # publication quality (50000 iterations)
make bench-internal     # internal suite only
make bench-comparative  # comparative suite only
make bench-update-sample  # regenerate bench/results/sample.txt
```

Override parameters on the command line:

```bash
make bench ITERATIONS=50000 THREADS=16 SCENARIO=simple-message
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `ITERATIONS` | 10000 | Measurement samples per scenario |
| `WARMUP` | 10000 | Warmup iterations before measurement |
| `THREADS` | 8 | Thread count for concurrent scenarios |
| `CONCURRENT_ITERATIONS` | 100000 | Messages per thread for throughput scenarios |
| `SUITE` | (both) | `internal` or `comparative` |
| `SCENARIO` | (all) | Run a single named scenario |

Or from the REPL:

```lisp
(asdf:load-system "cl-bark/bench-comparative")
(bark-bench:run :suite :internal :iterations 50000)
```

[bench/results/sample.txt](../bench/results/sample.txt) holds reference numbers from one machine (x86_64, SBCL 2.6.2, 1000 iterations), run on 2026-03-16. They predate the November 2026 writer changes and have not been re-run. The figures quoted on this page come from that file.

## Methodology

All benchmarks write to a discard stream (`(make-broadcast-stream)`) (a portable `/dev/null`). This isolates framework overhead from I/O. Real-world throughput will be lower due to actual disk or network writes.

Timing. Per-call latency uses CFFI `clock_gettime(CLOCK_MONOTONIC)` for nanosecond resolution. Each sample measures a batch of 100 calls; per-call estimates are derived by division. This gives ~10ns effective resolution while amortizing the clock read overhead. Sub-microsecond scenarios (disabled-level) use larger batches of 100,000. Throughput scenarios measure wall-clock elapsed time across 100,000+ messages.

Allocation. Bytes-consed per call is tracked via `trivial-benchmark` (uses SBCL's `sb-ext:get-bytes-consed` where available). The `&rest` field plist is `(declare (dynamic-extent fields))` and stack-allocated, it does not contribute to bytes-consed. The reported bytes are dominated by the formatter's result string, which is the one unavoidable allocation per log call (it goes on the ring buffer). A per-thread reusable string stream eliminates the stream object allocation.

## Reading the comparative results

The comparative suite runs cl-bark against log4cl and vom. They are designed differently, so the numbers need context.

- Structured and text logging. cl-bark serializes typed key-value fields into JSON or logfmt. log4cl and vom pass format strings to `cl:format`. Serialization costs more than `format` with a few directives, which is why log4cl is faster per call on simple messages.
- Blocking and async. The suite runs cl-bark in blocking mode so that it is compared synchronously with log4cl and vom. Normally cl-bark runs async: the caller pushes a formatted string onto the ring buffer and returns, and a writer thread drains it.
- Allocation. log4cl reports 0 bytes for simple messages and about 465 bytes for structured fields. cl-bark reports about 650 to 1200 bytes depending on the formatter, because it builds the whole line as a string for the ring buffer. See [caller-thread formatting](design/overview.md#caller-thread-formatting).
- Threads. At 8 threads cl-bark reached about 1.1M messages per second against about 730K for log4cl in the sample run. The lock-free ring buffer scales with producer threads, while log4cl's appender writes serialize on a lock.
- Formatters. logfmt was about 15 to 20% faster than JSON on structured fields in the sample run, which was a single run of 1000 iterations.
