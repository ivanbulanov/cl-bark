# cl-bark documentation

The [README](../README.md) has the quick start and a tour of the API. The generated
[API reference](https://ivanbulanov.github.io/cl-bark/) lists every export with its docstring; build it locally with `make docs`.

## Guides

| Page | Covers |
|------|--------|
| [lifecycle.md](lifecycle.md) | `make-logger`, `flush`, `stop`, `dropped-count`, `save-lisp-and-die`, conditions and restarts |
| [context.md](context.md) | Static and dynamic context, key shadowing, field redaction |
| [formatters.md](formatters.md) | Built-in formatters and their options, custom formatters, logging conditions |
| [value-serialization.md](value-serialization.md) | How each field type is rendered by the JSON, logfmt and pretty formatters |
| [multi-output.md](multi-output.md) | Tee outputs, per-destination formatters and filters, routing examples, error recovery |
| [blocking-mode.md](blocking-mode.md) | Dropping and warnings when the buffer is full, blocking with a timeout |
| [sampling.md](sampling.md) | Windowed counters, consistent sampling, caveats |
| [request-scoped-buffering.md](request-scoped-buffering.md) | `with-log-buffer` |
| [interactions.md](interactions.md) | How sampling, buffering, blocking, tee filters and transforms combine |
| [benchmarks.md](benchmarks.md) | Running the benchmarks, reading the comparative results |
| [reference.md](reference.md) | Special variables and a list of exports by topic |

## Design documents

| Document | Topic |
|----------|-------|
| [design/overview.md](design/overview.md) | Architecture, data flow of a log call, threads and ring buffer, module map |
| [design/decisions.md](design/decisions.md) | Decision log for API choices, known quirks |
| [design/multi-output.md](design/multi-output.md) | Tee design: thread per destination, per-destination formatters and filters |
| [design/formatter-protocol.md](design/formatter-protocol.md) | The prepare and format split |
| [design/condition-serialization.md](design/condition-serialization.md) | Logging conditions: type, message, backtrace capture |
| [design/request-scoped-buffering.md](design/request-scoped-buffering.md) | Retroactive flush decisions with `with-log-buffer` |
| [design/blocking-mode.md](design/blocking-mode.md) | State machine and locking of blocking mode |
| [design/sampling.md](design/sampling.md) | Data structures, hot path and hash of the samplers |
| [design/benchmarks.md](design/benchmarks.md) | What the `bench/` harness measures and why |
