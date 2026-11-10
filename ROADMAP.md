# cl-bark roadmap

Revised 2026-11-10. The last release is 0.1.0 (`67e1b91`, 2026-10-03).

This roadmap lists what cl-bark's two users found missing, plus documentation work. The users:

- **An MCP server application.** It logs through cl-bark, with one async logger for events and one for diagnostics,
  and is pinned by qlot to `67e1b91`. It is private, so it is cited here by what it does, not by path.
- **sql-zealot** (`sql-zealot/lisp`), a PostgreSQL client library. It recorded the cl-bark defects it found as FLAWS
  F37 to F41 and F109.

Rules for this list:

- Every item names the user that needs it. An item without one goes under "Parked".
- Progress is tracked with the checkboxes. A finished item keeps its text and names its commit.

## Release plan

- **0.2.0**: `[Unreleased]` as it stands, plus the items marked *0.2.0* below. Items of phases 2 and 3 that are done
  before the next push go into 0.2.0 too; the rest go into 0.3.0. 0.x allows a breaking change in each minor release,
  and both users are in-house, so two breaking releases cost nothing.
- Tag a release only on a commit that is already pushed. `git offhours apply` rewrites the unpushed commits and would
  leave a tag on the old commit. If the tag must come first, date it at its commit (`GIT_COMMITTER_DATE`).
- Ultralisp, then Quicklisp: after 0.2.0 is tagged (1.3).

## How libraries use cl-bark

Decided 2026-11-10, corrected the same day after review. A library such as sql-zealot must not require cl-bark,
because its users may log with something else. Requiring it costs them an install (cl-bark is in no dist), and the
global effects of loading it (the save and init hooks, the `bt:*default-special-bindings*` push).

- **The library owns a sink**: a function `(lambda (level event fields) ...)`, the shape of the `:on-event` functions
  that pg-wire and the pool already call. The application passes any function.
- **One threshold.** The library's threshold is a level keyword or a predicate on a level. With cl-bark the adapter
  passes `(lambda (level) (bark:level-enabled-p bark:*logger* level))`, so the operator has one knob, and a disabled
  event still costs one call.
- **cl-bark is an optional adapter system** (for sql-zealot, `sql-zealot-postgres/cl-bark`). It is a few lines: its
  sink reads `bark:*logger*` at each event and calls `bark:emit` (2.1). Reading the special per event lets the lines
  join a `with-log-buffer` scope; a child made once at `make-client` would bypass it. Pick the adapter by loading the
  system, never by a feature conditional or `find-package`, which depend on load order.
- **The fallback is the library's own**: synchronous writes to `sb-sys:*stderr*` under a mutex, no thread, no save
  step.

Which concerns stay in the library:

| Concern | Where | Why |
|---------|-------|-----|
| Keeping secrets out of events | Library | It chooses what to emit, and it must hold for every sink. In sql-zealot it is structural: `zl:secret` values, no server error detail, parameter values only on request. |
| Scrubbing the user part of connection URLs | Library, where the text is made | The library produces that text. |
| Turning library values into plain values | Library | No sink can print a `zl:secret` or a `zealot-error`. |
| String length caps | Library, as part of value conversion | A bound that depends on the backend is not a bound: with the fallback sink there would be none. The values are printed with `*print-length*` bound anyway, so the cap costs nothing extra. |
| Rate limits | Library, as a sink wrapper the operator can remove | With the fallback sink a backend limit would not apply. The limiter also runs before the fields are computed. |
| Floods during an outage | Library, by event design | Only the library knows its state. |
| No logging while a lock is held | Library | Concurrency hygiene. |

For cl-bark this means: sql-zealot needs only 2.1. The other items in phases 2 and 3 are justified by the
application.

## Phase 1. Release and distribution

### 1.1 Tag 0.1.0, release 0.2.0

- [x] Tag `v0.1.0` at `67e1b91` (local, annotated, dated at the commit). The two CI commits after it change only
  `ci.yml`.
- [x] *Owner*: push the tag and `main` (after `git offhours plan`). Pushed with `main` at e59a6bc.
- [ ] *0.2.0*: a Migration subsection in the 0.2.0 changelog entry: `*compile-time-max-level*` is now
  `*compile-time-min-level*`, `register-exit-hook` is removed, `flush` and `stop` return a value, and every other
  rename in the release.
- [ ] *0.2.0*: the release commit: changelog heading and date, `:version "0.2.0"` in `cl-bark.asd`.

### 1.2 Bump the `.asd` version on every release (sql-zealot)

`67e1b91` and `f3294fc` both say `:version "0.1.0"` but differ in exports, so a dependent cannot tell which one it
loaded. sql-zealot wrote a `bark-logger` deftype over `bark::logger` to load under both.

- [ ] *0.2.0*: bump the version with each release; document `:depends-on ((:version "cl-bark" "0.2.0"))` in the
  README, so ASDF fails at load time against an old copy.

### 1.3 Ultralisp, then Quicklisp (sql-zealot F109). Postponed until 0.2.0 is tagged

Seven sql-zealot scripts register a cl-bark checkout by hand through `ZL_CL_BARK_DIR`. Ultralisp builds from the branch
head, so submitting before the tag would ship unreleased `main`. All four dependencies are in Quicklisp.

- [ ] Submit to Ultralisp, then Quicklisp.
- [ ] Check first whether a Quicklisp dist build accepts a secondary system (`sql-zealot-postgres/cl-bark`) whose
  dependency is not in the dist. The library model assumes it does.

### 1.4 Follow-ups in sql-zealot (not cl-bark work)

- sql-zealot, short term: require cl-bark 0.2.0 in the `.asd` and delete the `bark-logger` deftype.
- sql-zealot, the library model, written up in sql-zealot's own roadmap: the sink and the predicate threshold, the
  fallback sink, `zl:rate-limited-sink` around the default sink, caps as options (`:log-sql-limit`),
  `zl.pool.connect-failed` as a state event, the adapter system, and the deletion of `call-with-log-context`. The
  review also found that the key-name pass of `mask-log-field` cannot fire, because no catalogue field name contains
  a secret word; confirm and delete it.
  - State event for `zl.pool.connect-failed`: log when failures start, again every 60 s with the count while they
    last, again when the error class changes, and on recovery at the same level as the failure (at `:debug` the
    recovery would be invisible at the default threshold). `zl.pool.timeout` has no state edge under load and stays
    rate limited; `zl.housekeeper.failed` fires at most once per pass and stays per occurrence.

## Phase 2. Public API for what users reach into internals for

Exit criterion: every internal the users call has a public replacement, and sql-zealot uses no `bark::`. The
application switches over in phase 6.

### 2.1 `bark:emit`: a function entry point that takes a field list (application, sql-zealot)

The level macros take fields as literal arguments. A field set built at run time today needs duplicated branches (the
application has four near-identical branches for one event), `(apply (bark::logger-info-fn logger) ...)`, or, in
sql-zealot, `with-context` branches and a closure per line (`call-with-log-context`). The library adapter needs it to
pass a sink's plist on.

- [x] Export `(bark:emit logger level message fields)`, `fields` a plist. (ecde731) The list form keeps it visibly different
  from the macros, so nobody uses it by habit and loses lazy evaluation of the fields. Specify:
  1. It dispatches through the logger's level functions, so samplers, the field transform and a buffer logger apply.
     Inside `with-log-buffer` samplers are bypassed, as for the macros. To join a buffer, pass `bark:*logger*` at
     call time.
  2. `logger` NIL does nothing. `level` is a keyword or a level number; an unknown one signals
     `bark-configuration-error`.
  3. `message` may be NIL or any object; a non-string is printed with `princ`.
  4. `*compile-time-min-level*` does not apply. Fields are evaluated by the caller; guard expensive ones with
     `level-enabled-p`.
- Do not name it `log`, which would shadow `cl:log`.

### 2.2 `capture` returns plain data (application)

`capture` keeps dissect's frame objects (`src/conditions.lisp`). Formatting usually runs on the caller's thread while
the frames are live, but a captured error replayed from `with-log-buffer`, or stored and logged later, is formatted
after its frames have ended. The application hit two consequences: a frame with a stale `&more` area faulted and
wedged the image, and a printing error hid the original condition. It now forces every frame inside `handler-case` and
rebuilds the struct with `bark::%make-captured-error`.

dissect reads the arguments and locals of every frame at `(dissect:stack)`; file and line are read lazily. cl-bark
prints only call, file and line, yet a captured error retains every frame's arguments, which can be secrets, for as
long as it lives.

- [x] `(capture condition &key (max-frames *capture-max-frames*))`, default 50. Each frame becomes plain data: a call
  string, a file namestring or NIL, a line or NIL. No dissect object is kept. A frame that fails to print becomes
  `"#<unprintable frame>"`. Formatter limits cut further. Breaking: `captured-error-stack` changes element type.
  Each frame is a plist `(:call :file :line)`. (98b91bb)
- [x] Fix `internal-frame-p`: it drops leading frames whose printed call contains "BARK", so a user function named
  `EMBARK` at the top of the stack is dropped. Compare the frame function's package instead. (98b91bb)
- Later, only on evidence: walk with `sb-debug:map-backtrace` and stop at `max-frames`, which bounds the walk and reads
  no arguments.

### 2.3 Health of a logger's writers (sql-zealot deploy checks)

sql-zealot's deploy scripts read `bark::async-output-state` and `bark::logger-output` to prove that writers restart
after `save-lisp-and-die`, and its deployment doc names `bark::save-live-outputs`. What a health check needs is
whether a writer has died; the state type has four values, and a list of them per tee destination says nothing about
which destination failed.

- [x] Export `(bark:healthy-p logger)`: true when no async writer of the logger is `:failed`. With `dropped-count`,
  that is a health check. (e43083b)
- [x] Document the save and init hooks by behaviour, so that nobody names internal functions. `docs/lifecycle.md`
  already did; it now points at `healthy-p` for the check after a restore. (e43083b)

### 2.4 Export a level reader (sql-zealot, October review)

`set-level` has no reader. The internal `bark::logger-level` is the struct accessor: it returns a number, is
`setf`-able, and the macro expansions in compiled user code call it, so it cannot become the public reader.

- [x] Export `(bark:current-level logger)`, returning the keyword. (df5d72c)

### 2.5 Rename `set-level-sampling` to `set-level-sampler` (October review). *0.2.0*

No user calls it, so the rename is free now. The pair becomes `make-level-sampler` and `set-level-sampler`.

- [x] Rename, with a Changed line; the Migration subsection (1.1) lists it.

## Phase 3. Output size control (application)

### 3.1 Serialization limits per formatter

The application needs `*max-json-length*` 100 for tool arguments, and unlimited stack frames on its diagnostics log
but not on its events log. The limits are process-wide specials, so it `setf`s them, which changes them for both of
its loggers and for any other cl-bark user in the image.

- [x] Add `:max-depth`, `:max-length` and `:max-stack-frames` to the three formatter constructors. A slot left NIL
  means "read the special when the line is formatted", today's behaviour, so existing `setf` and `let` of the
  specials keep working, also for formatters made before them.
  Done in c8f4453, on `make-json-formatter` and `make-pretty-formatter` only: logfmt writes collections as `<type>`
  placeholders and conditions without a stack, so the three limits would do nothing there. `:unlimited` is accepted
  where the special accepts NIL (stack frames, pretty depth and length).

### 3.2 A string length cap

Nothing bounds a string. The application logged a 10 MB model result whole: 500 MB of log per hour per image, and
pruning then deleted the service's own log. It now cuts results itself, keeping the head and the tail around a marker.

- [x] Add `:max-string-length` to the three formatters, with the same NIL rule as 3.1 and a special
  `*max-string-length*`, default NIL. The cut keeps the head and the tail with a marker that says how many characters
  were cut, and is made while the string is written, without a copy. It applies to string values, condition messages
  and the message.
  Done in 260c00e. Marker `...[N chars cut]...`; the kept characters number the limit. JSON also cuts strings inside
  collections; logfmt quotes a cut string.
- No total line cap: a valid JSON line cut in the middle is hard, and a library bounds its own lines.

### 3.3 Synchronous stream output (application)

The application's diagnostics logger is at `:error`, rare, and must survive a crash. A logger after `stop` already
writes on the caller's thread under the stream lock; there is no way to ask for that from the start.

- [x] `make-logger :async nil` for a stream output: no writer thread, each line written under the stream lock and
  flushed. This also covers SIGKILL and a segfault, which no exit hook can. Tee destinations take `:async` too. (ed9a89d)
- [x] Document that `(sb-ext:exit :abort t)` skips the exit drain: call `bark:flush` first. The application already
  does so on every abort path. (ed9a89d)

## Phase 4. Documentation and spring cleaning

The audit of 2026-11-10 found docs that contradict the code, duplicated topics and a 1151-line README.

### 4.1 Docs that contradict the code. *0.2.0*

- [x] README: the conditions table says `level-from-keyword` and `set-level` signal `type-error`; they signal
  `bark-configuration-error`. The `make-logger` signature in Lifecycle is out of date. The async-only keywords list
  omits `:on-error`. Static context is also set by `make-logger :context`. The Backpressure section is out of order.
  "The API is not expected to change" is wrong for 0.x. (a0ac761)
- [x] State "SBCL only". The README claims every implementation that `atomics` supports, but `src/writer.lisp` uses
  `sb-ext` unguarded, and the ring buffer relies on x86-64 ordering. (a0ac761)
- [x] `docs/value-serialization.md` lists internal functions as exported and says the pretty formatter prints
  symbols in lower case (it binds `:upcase`). (a0ac761)
- [x] `docs/design/decisions.md` "Known quirks" says "as of 0.2.0-dev". (a0ac761)
- [x] CONTRIBUTING and `cl-bark.asd` name `verbose` for the comparative bench, which has no verbose adapter.
  Removed from the `.asd`, the feature check and the bench header; the design doc's verbose section is gone. A
  stray "verbose adapter" comment block stays in `bench/comparative.lisp`. (8f81a7d)
- [x] `docs/blocking-mode.md`: with `:block-timeout nil` a producer waits forever when the writer dies. (a0ac761)
- [x] Docstrings: `stop`'s `continue` restart returns NIL; `make-logger` rounds `:capacity` up to a power of two;
  `make-buffer-logger` says samplers apply at flush time (they do not). Fixed in fe6dca5. The exported struct
  accessors and predicates already had docstrings, set with `(setf documentation)` since 94c282f.

### 4.2 Generated and stale files. *0.2.0*

- [x] Stop committing `docs/api/`: build it in `pages.yml` and ignore it. The committed copy lacks every export added
  since October. (583d626)
- [x] `BENCHMARKS.md` predates the writer rewrite. Delete it; the method stays in the benchmarks doc. Re-run the
  comparative bench and date the numbers the README quotes, or remove them. Deleted in 583d626; the README numbers now carry their date (4956ce7).
- [x] A test that every exported symbol has a docstring, in `make test`: `test-every-export-has-a-docstring`. (293896b)
- [x] `.gitignore`: `.serena/`. Untrack the local tool configuration directory. (f541965)

### 4.3 Duplication and padding

- [x] One canonical page per topic: blocking mode and sampling each have a user guide and a design doc that repeat
  each other; benchmarks, architecture and value serialization are each in three places. (4956ce7, 92a806a)
- [x] Design docs: delete the template sections that are history ("Alternatives Considered", "Non-Goals"), the
  "contrast with cl-llog", and the narrative about the first version. `decisions.md` keeps its ADR format. (92a806a)
- [x] Cut padding in README and `docs/sampling.md`: bold label plus dash on every line, "Why sampling", the
  "Recourses" FAQ, repeated claims. (4956ce7)

### 4.4 Split the README

- [x] README of about 250 lines: what it is, status, install, quick start, levels, a one-screen API tour, symbol
  shadowing, dependencies, a documentation table. The rest moves to `docs/` (lifecycle and conditions, context and
  redaction, formatters, multi-output, buffering, benchmarks, reference of globals and exports, architecture into the
  design overview). Retarget the anchors the design docs link to. (4956ce7, 92a806a)

### 4.5 New reference text (sql-zealot, October review)

- [ ] Which calls can block or take a lock (sql-zealot F38): async with drop takes no lock; `:blocking t` waits up to
  `:block-timeout`; after `stop`, or with `:async nil`, lines are written under a lock per stream; a function output
  runs user code on the calling thread. Say whether logging from a GC finalizer or with interrupts disabled is
  allowed.
- [ ] One table of how children, levels and samplers combine: what a child copies (the level, at creation), what it
  shares (the sampler vector), what later `set-level` and `set-level-sampler` on the parent do.
- [ ] Rotation: name logrotate `copytruncate` and journald.

## Phase 5. Small fixes

- [x] *0.2.0*: `src/writer.lisp` pushes the save and init hooks twice, once bare and once inside a `progn`. Delete one. (5a426a1)

## Phase 6. Changes in the application (last)

The application is under active development, so changes to it wait until the cl-bark work above is done and its
owner is ready. Nothing in phases 1 to 5 depends on them.

- [ ] Pin the 0.2.0 tag in its `qlfile` and run `qlot update cl-bark`.
- [ ] Replace its uses of `bark::` with the public API from phase 2 (`emit`, plain-data `capture`), and its `setf` of
  the serialization specials with per-formatter limits (3.1) and `:max-string-length` (3.2). Consider `:async nil`
  for its diagnostics logger (3.3).
- [ ] Test, in its own suite, loading a renamed vendored copy next to the normal one and saving an image with a live
  async logger in each. Each copy has its own `*stream-locks*`, so two copies writing to stderr do not serialize
  against each other.

## Parked (no user yet)

- **Rate limit per event key, with a suppressed count** (sql-zealot F39 asked for it; sql-zealot keeps its own
  limiter as a sink wrapper). Open problems: a bounded key table with eviction, appending `suppressed` without consing
  a new plist per line, and whether `make-child :sampler` alone is enough.
- **`make-logger :file`**, worth it only with lazy creation on the first line, which would remove the application's
  code that deletes an empty file at teardown.
- **`bark:flush-all`**: saves the application a loop over two loggers.

## Not planned

- **A `:before-emit` hook.** No user; `emit`, `:field-transform`, function outputs and tee filters reach the same
  uses, and a hook that returns a changed tuple conses on the hot path.
- **A key-name redaction helper.** Neither user's case is a top-level field key: sql-zealot's pass cannot fire, and
  the application redacts a key inside a hash table argument.
- **`:sync-levels`.** In an error storm it makes every error line wait for a drain. `:async nil` (3.3) covers the
  need.
- **In-process file rotation.** Several processes write one directory, and logrotate or journald do the job.
- **A field transform per tee destination.** Two loggers work, and it would break the tee's format-once grouping.
- **A child level that follows the parent's.** A cascade needs a registry of children with weak references and a lock;
  `with-context` on a shared logger covers the case.
- **A default logger for libraries.** A library writes its own fallback.
- **Removing the `bt:*default-special-bindings*` push (F41).** Without it the format-stream cache becomes one global
  slot.
- **An event catalogue, typed events, trace id injection, a token-bucket sampler, syslog output, a log browser.**

## Status of the reported items

| Source | Item | Status |
|--------|------|--------|
| sql-zealot F37 | No `save-lisp-and-die` hooks | Fixed in `f3294fc`, unreleased |
| sql-zealot F38 | `:blocking t` stalls a producer up to 5 s | Documented; `:block-timeout` configurable; 4.5 |
| sql-zealot F39 | `make-child` has no sampler of its own | Documented; keyed limit parked |
| sql-zealot F40 | No dropped-line count | Fixed in `f3294fc` (`dropped-count`), unreleased |
| sql-zealot F41 | Load-time push onto `bt:*default-special-bindings*` | Kept by decision |
| sql-zealot | Cannot tell which cl-bark is loaded | Export fixed; version 1.2 |
| sql-zealot F109 | Not in Quicklisp | Postponed; 1.3 |
| sql-zealot | Deploy scripts read writer internals | 2.3 |
| sql-zealot | Optional fields through `with-context` branches | 2.1 |
| application | Calls `bark::logger-info-fn` | 2.1 |
| application | Lazy stack frames, `bark::%make-captured-error` | 2.2 |
| application | Process-wide serialization limits | 3.1 |
| application | No string cap (10 MB result) | 3.2 |
| application | Diagnostics must survive a crash; `:abort t` skips the drain | 3.3 |
| application | No `flush` timeout or result in the pinned version | Fixed in `dc44995`; pin 6 |
