# Contributing

Bug reports and pull requests are welcome at
<https://github.com/ivanbulanov/cl-bark/issues>.

## Development setup

cl-bark is a plain ASDF system. With [Quicklisp](https://www.quicklisp.org/)
installed, clone the repository into `~/quicklisp/local-projects/` (or add it to
your ASDF source registry) and run:

```sh
make test              # main suite
make test-blocking     # blocking-mode suite
make test-concurrent   # sampling concurrency suite
```

`make` targets assume `sbcl` is on `PATH`; override with `make test SBCL="..."`.
The test suites need `fiveam` and `yason`. The `bench*` targets need `cffi`,
`trivial-benchmark` and `trivial-garbage` and, for the comparative suite, `log4cl`
and `vom`. All are available through Quicklisp.

## Pull requests

- Do not add work or allocation to the log call site beyond the formatted line;
  a change that does needs a benchmark justification (`make bench-internal`).
- Every exported function, macro, variable and condition has a docstring.
- Add or update tests in `tests/` for behavior changes; all three suites must
  pass.
- If a change affects the public API, add an entry under **Unreleased** in
  `CHANGELOG.md` and update the relevant README section. For design-level
  changes, update the matching document under `docs/design/`.
- New source files carry the Apache 2.0 header used by the existing files.
- Regenerate the API reference with `make docs` when docstrings or exports
  change; the result in `docs/api/` is committed and published automatically.

## License

By contributing you agree that your contributions are licensed under the
Apache License 2.0 (see `LICENSE`).
