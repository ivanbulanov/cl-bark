# Changelog

All notable changes to cl-bark are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Until 1.0 the API may change between
minor versions, and such changes are listed under **Changed**.

## [Unreleased]

## [0.2.0] - 2026-11-10

### Migration from 0.1.0

- Rename `*compile-time-max-level*` to `*compile-time-min-level*` where you bind it before compiling. It now strips the
  calls below that level.
- Rename `set-level-sampling` to `set-level-sampler`; the arguments are the same.
- Delete calls to `register-exit-hook`. Async outputs are drained at image exit without one, waiting at most
  `*exit-flush-timeout*` (2.0 seconds) per output.
- `flush` and `stop` now give up after `:timeout` seconds (default 5.0) per output and return T or NIL. Pass a larger
  `:timeout` where a drain may take longer, and check the result where a lost line matters.
- `captured-error-stack` returns plists `(:call :file :line)` instead of `dissect` frames: replace `dissect:call`,
  `dissect:file` and `dissect:line` on its elements with `getf`. `:call` is a string. `capture` keeps at most
  `*capture-max-frames*` (50) frames; pass `:max-frames nil` to keep all.
- The message and field forms of a logging call are evaluated only when its level is enabled. Move side effects out of
  log arguments.
- A NIL first argument of a logging macro now means no logger, and the call logs nothing; it was taken as the message.
- An `:on-flush` function of `with-log-buffer` receives the entries as a simple-vector in log order and must return a
  sequence of the entries to emit. Replace list operations such as `dolist` or `car` on them with sequence functions.
- `with-captured-logs` binds `LOGS` in your package by default, not `bark::logs`.
- A bad argument to a constructor or a level function (an unknown level, a bad `:timestamp` or `:level-format`, a
  non-function `:key-fn`) signals `bark-configuration-error` where it used to signal a type error, an `ecase` error,
  or nothing. `make-logger` refuses `:formatter`, and an explicit `:on-drop`, with a tee output, and `:on-drop` with a
  function output: give them to each tee destination.
- Log lines changed in ways a parser or an alert rule can see: stack calls carry their package (`MYAPP::RUN`); logfmt
  quotes string, character and symbol values, escapes control characters and replaces space, `=` and `"` in keys; a
  symbol key with lower-case letters keeps its case; floats print with the shortest round-trip digits; a stream error
  without `:on-error` reports `bark: output stopped on stream error` (was `bark: writer stopped ...`).

### Changed

- Rename `*compile-time-max-level*` to `*compile-time-min-level*` (breaking); it now works: bound at macroexpansion time
  to a level, the logging macros expand to NIL below it and never evaluate arguments.
- Rename `set-level-sampling` to `set-level-sampler` (breaking), to match the `:level-sampler` argument.
- Report a stream error without `:on-error` as `bark: output stopped on stream error` (was `bark: writer stopped ...`),
  since an `:async nil` output has no writer. The printed form of an async output names its state (`running`,
  `stopping`, `stopped`, `failed`, `sync`).
- Make `capture` return plain data (breaking): `captured-error-stack` is a list of plists `(:call string :file
  namestring-or-NIL :line integer-or-NIL)` instead of `dissect` frames, made while the frames are live, so a captured
  error formatted later (stored, or replayed from `with-log-buffer`) no longer touches dead frames, and no frame
  arguments are kept. A frame that fails to print becomes `"#<unprintable frame>"`. The call string now carries its
  package prefix in JSON and pretty output (`MYAPP::RUN`, was `run` in JSON and `RUN` in pretty).
- Add `:max-frames` to `capture`, default the new exported `*capture-max-frames*` (50; NIL keeps all).
- Evaluate message and field forms of `trace`, `debug`, `info`, `warn`, `error` and `fatal` only when the level is
  enabled on the target logger.
- Treat an explicit NIL first argument of the logging macros as a no-op (an absent logger) instead of as a message.
- Signal `bark-configuration-error` (instead of a Lisp `ecase`/type error) for an unknown level keyword or an
  out-of-range level number in `make-logger`, `set-level`, `level-enabled-p`, `set-level-sampler` and `make-tee`.
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

- Add `make-logger :async nil` and an `:async` key for tee destinations: a stream output with no writer thread and
  no queue, each line written on the caller's thread under the stream lock and forced out before the call returns, so
  it survives SIGKILL or a crash. `:on-error` runs on the caller's thread; the queue keywords are refused with it.
  A line logged by an interrupt while its thread is writing to the same stream is counted as dropped.
- Document which logging calls block or take a lock (also from finalizers and with interrupts disabled), what a child
  logger copies and shares, and log rotation with logrotate `copytruncate` or journald.
- Document that `(sb-ext:exit :abort t)` skips the exit drain; call `bark:flush` first.
- Add and export `*max-string-length*` (default NIL) and a `:max-string-length` argument to all three formatter
  constructors: a longer string value, condition message or message is written as its head, a
  `...[N chars cut]...` marker and its tail, without a copy.
- Add `:max-depth`, `:max-length` and `:max-stack-frames` to `make-json-formatter` and `make-pretty-formatter`, so one
  logger can have its own limits without a `setf` of the process-wide specials. A limit left NIL reads the special when
  a line is formatted, as before; `:max-stack-frames` (and the pretty depth and length) also take `:unlimited`.
- Add and export `current-level`, which returns a logger's level as a keyword.
- Add and export `healthy-p`, which returns NIL when an async writer of a logger has failed.
- Add and export `emit`, a function form of the logging macros that takes the fields as a plist built at run time.
- Add `sb-ext:*save-hooks*` and `sb-ext:*init-hooks*` functions: `save-lisp-and-die` no longer fails while an async
  logger runs; the save hook drains and joins every running writer thread, and the init hook restarts them in the
  restored image (standard streams rebound to SBCL's new `*stdout*`/`*stderr*`, file streams reopened for appending;
  outputs stopped before the save stay stopped).
- Add and export `dropped-count`, the cumulative number of lines a logger's async outputs have dropped; reading it
  resets nothing.
- Document that `:blocking t` can stall a producer up to `:block-timeout` per call, that `make-child` shares the
  parent's level-sampler vector, and why `bt:*default-special-bindings*` is still extended at load time.
- Add `*exit-flush-timeout*` (default 2.0 seconds), the per-output wait of the automatic exit drain.
- Export `default-on-drop`, `logger`, and `*default-json-formatter*`, `*default-logfmt-formatter*` and
  `*default-pretty-formatter*`.
- Add `make-logger :on-error`, called on the writer thread with the stream error; return a replacement stream to
  continue or NIL to stop.

### Fixed

- Find cl-bark's own frames in `capture` by package, not by the substring `BARK` in the printed call, which dropped a
  user frame such as `(LAMBDA () :IN EMBARK)` from the top of the stack.
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
- Make child loggers share the parent's level-sampler vector, so `set-level-sampler` after `make-child` applies to the
  whole family (previously a lazily created sampler was not shared).
- Fix `with-context` to evaluate key and value forms exactly once, in order, so keys may be variables; reject an odd
  number of elements at macroexpansion.
- Fix `with-captured-logs` default variable to be `LOGS` in the caller's package (it was `bark::logs`) and use gensyms
  for internals.
- Make `make-list-collector` thread-safe and callable repeatedly (accessor returns a fresh list in log order).
- Fix field transforms returning no values: the field is dropped instead of signalling.
- Fix the windowed sampler detecting window expiry only every 64th message; `set-level-sampler` windows now reset on
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

[Unreleased]: https://github.com/ivanbulanov/cl-bark/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ivanbulanov/cl-bark/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ivanbulanov/cl-bark/releases/tag/v0.1.0
