# cl-bark documentation

The [README](../README.md) is the primary reference: quick start, the full API, feature
interactions and usage examples. The generated [API reference](https://ivanbulanov.github.io/cl-bark/)
(`docs/api/`, built with `make docs`) mirrors the docstrings.

## User guides

| Guide | Covers |
|-------|--------|
| [sampling.md](sampling.md) | Windowed counters, consistent sampling, configuration and caveats |
| [blocking-mode.md](blocking-mode.md) | Backpressure when the ring buffer is full, timeouts, the timeout callback |
| [value-serialization.md](value-serialization.md) | How field values of each type are rendered by the JSON, logfmt and pretty formatters |

## Design documents

Rationale and architecture, kept current with the code. Start with the overview.

| Document | Topic |
|----------|-------|
| [design/overview.md](design/overview.md) | Architecture, module map, data flow, how cl-bark compares to other loggers |
| [design/decisions.md](design/decisions.md) | Decision log for API choices |
| [design/multi-output.md](design/multi-output.md) | Tee design: thread per destination, per-destination formatters and filters |
| [design/formatter-protocol.md](design/formatter-protocol.md) | The prepare/format split and caller-thread serialization |
| [design/condition-serialization.md](design/condition-serialization.md) | Logging conditions: type, message, backtrace capture |
| [design/request-scoped-buffering.md](design/request-scoped-buffering.md) | Retroactive flush decisions with `with-log-buffer` |
| [design/blocking-mode.md](design/blocking-mode.md) | Why bounded blocking instead of drop-only or unbounded queues |
| [design/sampling.md](design/sampling.md) | Burst-then-sample model and consistent sampling |
| [design/benchmarks.md](design/benchmarks.md) | What the `bench/` harness measures and why |

Benchmark results for a reference machine are in [BENCHMARKS.md](../BENCHMARKS.md).
