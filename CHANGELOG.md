# Changelog

All notable changes to cl-bark are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Until 1.0 the API may change between
minor versions, and such changes are listed under **Changed**.

## [Unreleased]

### Changed

- Rename `*compile-time-max-level*` to `*compile-time-min-level*` (breaking); it now works: bound at macroexpansion time
  to a level, the logging macros expand to NIL below it and never evaluate arguments.
- Evaluate message and field forms of `trace`, `debug`, `info`, `warn`, `error` and `fatal` only when the level is
  enabled on the target logger.
- Treat an explicit NIL first argument of the logging macros as a no-op (an absent logger) instead of as a message.
- Signal `bark-configuration-error` (instead of a Lisp `ecase`/type error) for an unknown level keyword or an
  out-of-range level number in `make-logger`, `set-level`, `level-enabled-p`, `set-level-sampling` and `make-tee`.
- Accept a level constant as well as a keyword in `level-enabled-p`.
- Signal `bark-configuration-error` at construction for a bad `:timestamp` (`make-json-formatter`,
  `make-logfmt-formatter`, `make-pretty-formatter`), a bad `:level-format`, a missing `make-formatter :format-fn`, and a
  non-function `make-consistent-sampler :key-fn`.
- Signal `bark-configuration-error` from `make-logger` when `:formatter` is passed with a tee output (each destination
  has its own formatter), and from `make-tee` for a `:stream` that is not a stream.
- Make `make-logger` reject an explicit `:on-drop`, even `#'default-on-drop`, with a function or tee output.
- Make `make-tee` accept `:on-drop NIL` to suppress drop reports.
- Return a boolean from `flush` (T when every running async output acknowledged, NIL on timeout) and accept `:timeout`
  (default 5.0) on `flush` and `stop`.
- Return T from `stop` when every writer exited cleanly, NIL otherwise; `stop` is idempotent, only the first concurrent
  caller performs it, and it waits at most `:timeout` per output.
- Remove `register-exit-hook`; async outputs are drained automatically at image exit.
- Skip the clock read for accepted messages in `make-windowed-counter` sampling; expiry is noticed by the first
  would-be-dropped message (`+window-check-interval+` removed).
- Treat `with-log-buffer` `:on-flush` entries as a simple-vector in log order, and require it to return a sequence of
  entries to emit.

### Added

- Add `*exit-flush-timeout*` (default 2.0 seconds), the per-output wait of the automatic exit drain.
- Export `default-on-drop`, `logger`, and `*default-json-formatter*`, `*default-logfmt-formatter*` and
  `*default-pretty-formatter*`.
- Add `make-logger :on-error`, called on the writer thread with the stream error; return a replacement stream to
  continue or NIL to stop.

### Fixed

- Make the async writer thread survive per-iteration errors (failing `on-drop` callback, formatter bug, stream error); a
  dead writer marks the output failed and releases waiters instead of hanging `flush`/`stop`.
- Serialize writes per underlying stream, so two loggers or tee destinations sharing a stream (including synonym streams
  such as `*error-output*`) no longer interleave or corrupt output.
- Drain every async output automatically at image exit.
- Keep a logger working after `stop`: later lines are written synchronously on the calling thread instead of being lost.
- Fix lost or stuck lines under load in the ring buffer (an interrupt between claim and publish could wedge the writer;
  added memory barriers for weakly ordered CPUs).
- Bound each writer batch so drop warnings, flush acknowledgements and blocked producers are serviced under sustained
  overload.
- Honor `make-logger :on-error` (it was always passed as NIL); a replacement stream returned from the handler keeps the
  writer running.
- Make `make-tee` validate all destinations before starting any writer thread, and stop already-started writers on a
  non-local exit (no leaked threads).
- Make `make-logger` validate `:level` before starting a writer thread.
- Fix `with-log-buffer` on `:on-flush`/error paths: the captured condition is the most recent serious condition (handled
  or not), and a flush error during unwind is reported instead of replacing the unwinding condition.
- Make `with-log-buffer` capture thread-safe (CAS push), so threads sharing the buffer-logger no longer race.
- Fix a buffer-logger that escapes its `with-log-buffer` scope: it now logs through the source logger instead of into a
  dead buffer.
- Fix `make-child` on a buffer-logger: children derive from the source logger and emit immediately.
- Fix nested `with-log-buffer` on a different logger being silently skipped; only a nested scope on the same logger is a
  no-op.
- Make `make-child` honor a context key that overrides the parent's (the parent's duplicate is removed;
  consistent-sampler `key-fn` sees the child value).
- Make child loggers share the parent's level-sampler vector, so `set-level-sampling` after `make-child` applies to the
  whole family (previously a lazily created sampler was not shared).
- Fix `with-context` to evaluate key and value forms exactly once, in order, so keys may be variables; reject an odd
  number of elements at macroexpansion.
- Fix `with-captured-logs` default variable to be `LOGS` in the caller's package (it was `bark::logs`) and use gensyms
  for internals.
- Make `make-list-collector` thread-safe and callable repeatedly (accessor returns a fresh list in log order).
- Fix field transforms returning no values: the field is dropped instead of signalling.
- Fix the windowed sampler detecting window expiry only every 64th message; `set-level-sampling` windows now reset on
  the first message that would be dropped, so low-volume levels regain their burst.
- Fix formatter output bugs: no leading space on a line, and exactly one space separator in logfmt and pretty output
  when level, timestamp, context or message are omitted.
- Fix logfmt output: quote string, character and symbol values and escape control characters (`\uXXXX`); replace space,
  `=`, `"` and control characters in keys with `_`.
- Fix `:|camelCase|` style keys being down-cased; a symbol name containing lower-case characters is emitted verbatim.
- Fix JSON and logfmt float output: shortest round-trip digits with an `E` exponent where needed, ratios as doubles, and
  a string when a ratio does not fit a double.
- Make formatters immune to ambient printer settings (`*print-base*`, `*print-radix*`, `*print-pretty*`,
  `*print-readably*`, `*print-case*`).
- Make formatting re-entrant and safe across threads not created via bordeaux-threads (a `print-object` or condition
  report that logs no longer corrupts the line); partial output is discarded on non-local exit.
- Fix a condition whose report function signals: the log call writes `<report failed: TYPE>` instead of propagating the
  error.
- Make a non-string log message (number, symbol, object) print with `princ` instead of signalling.
- Fix the default drop warning (no formatter) to emit `{"level":"warn","msg":...}` JSON, with a string level and a
  properly escaped message.

## [0.1.0] - 2026-10-03

First public release.

### Added

- Structured logging macros `trace`, `debug`, `info`, `warn`, `error`, `fatal`
  (`*compile-time-max-level*` is defined but reserved; it currently has no effect.)
- Async writer thread with a lock-free ring buffer; optional blocking mode with
  bounded timeout and `on-block-timeout` callback.
- JSON, logfmt and pretty formatters built on a common formatter protocol.
- Static context via child loggers and dynamic context via `with-context`.
- Multi-output fan-out (`make-tee`, `tee`) with per-destination formatters and
  filters.
- Condition logging with type, message and optional backtrace; field redaction.
- Sampling: windowed counters and consistent (key-hashed) samplers.
- Request-scoped buffering (`with-log-buffer`) with retroactive flush decisions.
- Test helper `with-captured-logs`.
- Internal and comparative benchmark harness (`make bench`).

[Unreleased]: https://github.com/ivanbulanov/cl-bark/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ivanbulanov/cl-bark/releases/tag/v0.1.0
