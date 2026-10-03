# Changelog

All notable changes to cl-bark are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Until 1.0 the API may change between
minor versions, and such changes are listed under **Changed**.

## [Unreleased]

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
