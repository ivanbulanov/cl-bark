# Reference

The generated [API reference](https://ivanbulanov.github.io/cl-bark/) lists every export with its docstring. This page
lists the special variables and gives one line for each exported symbol, with the page that explains it.

## Special variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `bark:*logger*` | `nil` | The logger the logging macros use when none is passed. Bind it per thread or set it globally. |
| `bark:*log-context*` | `nil` | Dynamic context, managed by `with-context`. |
| `bark:*compile-time-min-level*` | `nil` | Compile-time level floor; calls below it expand to NIL. |
| `bark:*exit-flush-timeout*` | `2.0` | Seconds to wait per async output when the image exits. |
| `bark:*max-json-depth*` | `4` | Maximum nesting depth of collections in JSON output. |
| `bark:*max-json-length*` | `20` | Maximum elements per collection in JSON output. |
| `bark:*max-pretty-depth*` | `4` | Bound to `*print-level*` in the pretty formatter (NIL is unlimited). |
| `bark:*max-pretty-length*` | `20` | Bound to `*print-length*` in the pretty formatter (NIL is unlimited). |
| `bark:*max-json-stack-frames*` | `10` | Maximum stack frames in JSON condition output (NIL is unlimited). |
| `bark:*max-pretty-stack-frames*` | `20` | Maximum stack frames in pretty condition output (NIL is unlimited). |
| `bark:*default-json-formatter*`, `bark:*default-logfmt-formatter*`, `bark:*default-pretty-formatter*` | | The formatter instances `make-logger` and `make-tee` use by default. |

## Exports by topic

| Symbols | Page |
|---------|------|
| `trace` `debug` `info` `warn` `error` `fatal`, `emit`, `logger`, `logger-p`, `*logger*` | [README](../README.md), [lifecycle.md](lifecycle.md#logging-with-fields-built-at-run-time) |
| `+trace+` `+debug+` `+info+` `+warn+` `+error+` `+fatal+` (level constants), `level-name` (level number to name string) | [README](../README.md) |
| `make-logger`, `make-child`, `set-level`, `current-level`, `level-enabled-p`, `flush`, `stop`, `dropped-count`, `default-on-drop` | [lifecycle.md](lifecycle.md) |
| `bark-error`, `bark-configuration-error`, `bark-lifecycle-error`, `bark-async-stopped`, `bark-child-operation-error` | [lifecycle.md](lifecycle.md) |
| `with-context`, `*log-context*` | [context.md](context.md) |
| `make-tee`, `tee` | [multi-output.md](multi-output.md) |
| `formatter`, `formatter-p`, `formatter-prepare-fn`, `formatter-format-fn`, `make-formatter`, `json-formatter`, `logfmt-formatter`, `pretty-formatter`, `make-json-formatter`, `make-logfmt-formatter`, `make-pretty-formatter`, `current-log-timestamp-ms` | [formatters.md](formatters.md) |
| `capture`, `captured-error-p`, `captured-error-condition`, `captured-error-stack` | [formatters.md](formatters.md) |
| `make-windowed-counter`, `make-level-sampler`, `set-level-sampler`, `make-consistent-sampler`, `set-consistent` | [sampling.md](sampling.md) |
| `with-log-buffer`, `buffer-entry-level`, `buffer-entry-message`, `buffer-entry-fields`, `buffer-entry-context`, `buffer-entry-timestamp` | [request-scoped-buffering.md](request-scoped-buffering.md) |
| `with-captured-logs` | [README](../README.md) |
