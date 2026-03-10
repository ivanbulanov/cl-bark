# Multi-Output Design Review

Critical review of `multi-output-design.md` against the existing cl-bark codebase.

## 1. `tee` as a Macro — Unjustified

The design's only rationale: "no quoting issues, no list wrappers." This is weak — it trades a minor syntax convenience for real limitations:

- **No programmatic construction.** You can't build a tee from a computed list of destinations (e.g., a config file parsed at startup). Every destination must be a literal in the macro form.
- **No testing in isolation.** You can't unit-test tee construction without going through macro expansion.
- **Confusing "expansion time" language.** The doc says "the tee macro creates the async-outputs at macro-expansion time" — this is misleading. Macro expansion produces *code*; async-outputs are created when that code *executes*. A function does the same thing without the confusion.

**Recommendation:** Make `tee` a function that takes a list of destination plists. Optionally provide a `tee` macro as syntax sugar that expands to the function call. The function is the real API; the macro is convenience.

## 2. Where Does Per-Destination Formatting Live?

This is the biggest gap in the design. Currently, the logger has a single `formatter` slot, and `make-log-fn` does:

```lisp
(let* ((formatter (logger-formatter lgr))
       (line (funcall formatter ...))
       (output (logger-output lgr)))
  ...)
```

With tee, formatting must happen **per destination** because each has its own formatter. But the design never explains how `make-log-fn` changes. Two questions are unanswered:

- **Is the logger's `formatter` slot ignored when output is a tee?** If so, what happens to `start`'s `:formatter` parameter — is it an error to pass it with a tee output? A no-op? Used as a default for destinations without explicit formatters?
- **How does `make-log-fn` detect tee vs. plain output?** It would need a type dispatch: `(if (tee-p output) (emit-to-tee ...) (emit-single ...))`. This is a hot-path branch on every log call. The design should discuss this.

`child` copies the parent's `formatter` slot. A child of a tee-configured logger inherits a stale/unused formatter. Not harmful but worth addressing explicitly.

## 3. What Is the Internal Representation of a Tee?

The design says tee returns "a value the logger's output slot accepts" and calls the internal representation "an implementation detail." But `stop` needs to tear down all writer threads, `child` shares the output, and `make-log-fn` needs to dispatch on it. The internal shape affects all three. At minimum, the design should specify:

- Is it a struct? A list of async-outputs? A closure?
- How does `stop` recognize and iterate it? The current `stop` checks `(async-output-p output)` — that fails for a tee value.

## 4. N Destinations = N Threads

Each destination gets its own ring buffer and writer thread. Five destinations = five threads. The design doesn't discuss this cost or whether it's acceptable. For the common case (2-3 destinations), it's fine. But the API doesn't prevent 10+ destinations, and the design should set expectations.

Consider: could multiple destinations sharing the same formatter *and* same stream share a single writer thread? The "shared formatter optimization" already groups by `eq` formatter for format-once semantics, but each still has a separate writer.

## 5. Shared Formatter Optimization Is Fragile

The design guarantees format-once when formatters are `eq`. But:

- `#'bark:json-formatter` from two different compilation units may or may not be `eq` (implementation-dependent for top-level `defun`).
- `(lambda ...)` forms are never `eq` even when textually identical.
- If a user wraps a formatter (e.g., `(let ((f #'bark:json-formatter)) f)`) the binding is `eq` but this isn't obvious.

The "guarantee" needs a caveat: it only works for formatter references that are literally the same function object. In practice this means `#'bark:json-formatter` used multiple times, which is the common case. But calling it a "guarantee" overpromises.

## 6. Filter Doesn't See `message`

Filter signature: `(lambda (level fields) ...)`. The content-routing example uses `:audit` as a per-call field. But what about routing based on the message string itself? The message is available in the caller thread at filter time — excluding it seems arbitrary. If the goal is to keep filters cheap, the message is just a string comparison, no costlier than `getf` on a plist.

**Recommendation:** `(lambda (level message fields) ...)` — or at minimum, document why message is excluded.

## 7. Breaking Change to `start` Not Acknowledged

`start` currently takes `:stream`. The design replaces it with `:output`. This breaks every existing caller. The design should either:

- Explicitly mark this as a breaking change (new major version)
- Support both `:stream` and `:output` with deprecation warning for `:stream`
- Note that `make-logger` already uses `:output`, so this unifies the API — which is good, but the migration needs to be called out

## 8. Stream Lifecycle

The tee examples show `(open "/var/log/app.jsonl" ...)` inside the tee form. Who closes these streams? `stop-async-output` stops the writer thread and flushes, but doesn't close the stream. If the tee macro opens streams, it should track them. If the user opens them, the doc should say so explicitly.

Currently the design is silent on this, which will lead to file descriptor leaks.

## 9. Explicit Logger Arg — Hot Path Cost

The proposed macro:

```lisp
(defmacro info (first &rest rest)
  (let ((g (gensym)))
    `(let ((,g ,first))
       (if (logger-p ,g)
           (funcall (logger-info-fn ,g) ,g ,@rest)
           (when *logger*
             (funcall (logger-info-fn *logger*) *logger* ,g ,@rest))))))
```

Every log call now pays for:

1. Binding a gensym (`let`)
2. A `logger-p` type check (struct tag comparison)
3. A branch

The current code is a straight `funcall` with no branch. For a library that pre-computes `noop` function slots to avoid even a level comparison on disabled calls, adding a branch on every enabled call is inconsistent with the performance philosophy.

**Alternative:** Two separate macros — `bark:info` always uses `*logger*`, and `bark:info*` (or `bark:log-to`) takes an explicit logger. Zero cost on the common path, explicit at the call site.

## 10. `*logger*` nil Guard Removed for Explicit Logger

In the proposed expansion, `(bark:info some-logger "msg")` calls `(funcall (logger-info-fn some-logger) some-logger ...)` with no nil guard. If `some-logger` is nil but happens to not be a logger struct, it falls to the `*logger*` path. But if someone writes `(bark:info nil "msg")`, `(logger-p nil)` returns nil, so it falls to `(when *logger* ...)` — the nil is silently passed as the message. Not a crash, but confusing behavior that should be documented or guarded against.

## 11. Interaction with `with-captured-logs`

`with-captured-logs` is used extensively in tests. It creates a logger with a string stream and captures output. How does this work when the production logger uses tee? If someone wants to test that both destinations receive the right content, they need to capture from two streams. The design doesn't address testability of multi-output configurations.

## 12. Error Isolation Between Destinations

If one destination's stream errors (disk full, broken pipe), the writer thread for that destination dies (current `handler-case` logs to `*error-output*` and the thread exits). Other destinations continue. This is good, but:

- There's no notification mechanism beyond `*error-output*` — the caller doesn't know a destination died.
- A dead destination's ring buffer fills up and silently drops all subsequent messages.
- No recovery path (restart the writer, reconnect the stream).

This is acceptable for v1 but should be listed as a known limitation.

## Summary

| # | Issue | Severity | Recommendation |
|---|-------|----------|----------------|
| 2 | `make-log-fn` changes unspecified | **High** | Document how per-destination format/filter integrates with existing hot path |
| 3 | Tee internal representation unspecified | **High** | Specify type so `stop`, `child`, `make-log-fn` interactions are clear |
| 1 | ~~Tee as macro only~~ | ~~Medium~~ | ~~Add function API, macro as sugar~~ — **resolved** |
| 7 | Breaking `start` API change | Medium | Acknowledge breaking change or add deprecation path |
| 8 | Stream lifecycle | Medium | Document who closes streams, or add close-on-stop option |
| 9 | Hot-path branch for explicit logger | Medium | Consider separate macros instead of runtime dispatch |
| 4 | Thread count scaling | Low | Document that N destinations = N threads |
| 5 | Shared formatter `eq` fragility | Low | Document the `eq` limitation clearly |
| 6 | Filter excludes `message` | Low | Add message to filter signature |
| 10 | nil logger silent misbehavior | Low | Document or guard |
| 11 | `with-captured-logs` testability | Low | Extend for multi-output testing |
| 12 | Destination error isolation | Low | List as known limitation |

The two high-severity items — unspecified `make-log-fn` changes and unspecified tee internal type — are the core issue. The design describes what the user sees but not how the internals change to support it. Since cl-bark's performance story depends on the hot-path design (`noop` function slots, pre-serialized chindings, lock-free ring buffer), the multi-output design needs to show that the new per-destination dispatch doesn't compromise this.
