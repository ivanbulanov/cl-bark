# Funhouse Deficiencies Found During cl-bark Refactoring

**Date:** 2026-03-24
**Context:** Refactoring cl-bark using Funhouse MCP tools exclusively

---

- [x] ## 1. FiveAM Test Detection Intermittent

**Symptom:** On first load, `codebase-map` reported `testCount: 0` and `framework: native` despite 314 FiveAM tests across 3 test files. On a subsequent load in the same session, it correctly detected `framework: fiveam` and `testCount: 314`.

**Impact:** Blocks coverage analysis on first load. The refactoring analysis was produced without coverage data because of this.

**Possible root cause:** FiveAM test registration happens at load time via side effects. If the detection check runs before all test files are fully evaluated, it may miss them. Alternatively, the detection may depend on package state that isn't yet established on first load.

**Resolution:** Fixed in commit `9e116c2` — FiveAM test detection reliability improved.

---

- [x] ## 2. `run-tests` Cannot Find Tests Defined via `define` with `test-file`

**Symptom:** After defining a FiveAM test via `define(code: "(5am:test ...)", test-file: "tests.lisp")`, calling `run-tests(name: "test-name")` fails with "No FiveAM test or suite found". However, the test IS registered in FiveAM (verified via `eval` calling `5am:get-test`) and runs correctly when invoked through `5am:run` directly.

**Impact:** Cannot run individual newly-defined tests by name through the MCP tool. Must use `eval` or run the full suite.

**Likely cause:** The `run-tests` name lookup may search the registry or test file index rather than FiveAM's own test registry. Tests defined via `define` with `test-file` are registered in FiveAM but the MCP tool's name resolution doesn't find them until after a save/reload cycle.

**Resolution:** Fixed in commit `9e116c2` — run-tests name lookup improved.

---

- [ ] ## 3. `define-batch` Without `file` Assigns Conditions to Wrong File

**Symptom:** When using `define-batch` to define condition types without specifying `file`, the conditions were assigned to `src/levels.lisp` instead of the expected `src/conditions.lisp`. Required a second `define-batch` call with explicit `file` parameter to fix.

**Impact:** Minor — requires awareness that `define-batch` without `file` uses some default (possibly last-used file or alphabetical first), not the package's "natural" file for the definition kind.

**Workaround:** Always pass `file` when defining new definitions outside of the project's main file.

---

- [x] ## 4. `define-condition` Parent Type Conflicts with Package Shadows

**Symptom:** `define-condition bark-error (error) ...` failed with "Class not yet defined: ERROR" because BARK shadows `cl:error` with a logging macro. Required `(define-condition bark-error (cl:error) ...)` with explicit CL package prefix.

**Impact:** Minor inconvenience. The error message is unhelpful — it says "Class not yet defined" rather than indicating a symbol resolution issue.

**Suggestion:** When `define-condition` fails to resolve a parent type, check if the symbol exists but names a non-class (macro/function), and provide a more helpful error message suggesting the fully-qualified name.

**Resolution:** Fixed in commit `93b88b8` — error message now detects shadowed parent types and suggests the fully-qualified CL name.

---

- [ ] ## 5. `query` Predicate Error on Struct-Generated Functions

**Symptom:** The query `(-> (symbols :kind :function) (filter (lambda (s) (let ((sig (signature-parts s))) (> (+ (length (getf sig :required)) (length (getf sig :key))) 6)))))` failed with:

```
Predicate error during filter on element %RING-BUFFER-TRY-PUSH:
The value 3 is not of type SEQUENCE
```

**Impact:** Cannot filter functions by parameter count without excluding struct-generated functions. The `signature-parts` combinator returns an integer (arity) instead of a plist for some compiler-generated functions.

**Suggestion:** `signature-parts` should return a consistent plist shape for all function kinds, or `filter` should handle predicate errors gracefully (skip the element with a warning instead of aborting the entire query).

---

- [x] ## 6. `unused-export-p` Doesn't Consider Macro Expansions

**Observation:** `unused-export-p` reported 34 of 37 exports as unused. However, many of these (the logging macros `DEBUG`, `ERROR`, `INFO`, etc.) are heavily used — they're invoked as macros, not as direct function calls. The `unused-export-p` predicate appears to check `callers` (who-calls) but not `macro-users` (who-macroexpands).

**Impact:** Misleading results for macro-heavy libraries. The refactoring analysis incorrectly described 35 exports as "unused externally."

**Suggestion:** `unused-export-p` should also check `macro-users` and `references` (who-references-as-value) in addition to `callers`.

**Resolution:** Fixed in commit `f2f8242` — `effective-callers` now checks `macro-users` for macros and `references` for functions/GFs.

---

- [ ] ## 7. `workspace(action: save)` Emits Method to Wrong File, Breaking Load Order

**Symptom:** After redefining `adapter-find-test-by-name` (a method on `fiveam-adapter`) in the live workspace, `workspace(action: save)` moved the method body from `src/adapters/fiveam.lisp` to `src/test-adapter.lisp` and replaced the `defgeneric` with the method definition. On reload, SBCL fails with `CLASS-NOT-FOUND-ERROR: There is no class named FIVEAM-ADAPTER` because `test-adapter.lisp` is loaded before `adapters/fiveam.lisp` (where the class is defined).

**Impact:** High — a save/reload cycle produces an unloadable project. Required manual `git checkout` to restore the two affected files.

**Root cause:** When a method's GF is defined in file A but the method specializes on a class from file B (loaded later), the save emitter places the method body in file A (with the GF). This breaks when the specializer class doesn't exist yet at file A's load time.

**Suggestion:** Method emission should respect the file where the method was originally defined (or where its specializer class is defined), not the file where the GF lives. The `source-file` slot on `method-entry` should be authoritative for emission target.

---

- [ ] ## 8. `workspace(action: save)` Silently Overwrites Unrelated Files

**Symptom:** Saving after modifying only `effective-callers` in `concept.lisp` also rewrote `test-adapter.lisp` and `adapters/fiveam.lisp` with semantically different content (method moved between files, docstring truncated). The diff showed only `concept.lisp` as a dirty file, but save touched 3 files.

**Impact:** Medium — changes to unrelated files are silently introduced. The user must review `git diff` after every save to catch unexpected mutations. In this case the unrelated changes broke the project's load order.

**Suggestion:** Save should only write files that are actually dirty (i.e., have modified definitions). Files whose definitions haven't changed semantically should not be rewritten.

---

## Summary

| # | Status | Severity | Category |
|---|--------|----------|----------|
| 1 | Fixed | Medium | Test detection reliability |
| 2 | Fixed | Medium | Test execution for dynamically defined tests |
| 3 | Open | Low | Default file assignment in define-batch |
| 4 | Fixed | Low | Error message quality for define-condition |
| 5 | Open | Medium | Query robustness with compiler-generated functions |
| 6 | Fixed | Medium | Export analysis accuracy for macros |
| 7 | Open | High | Save emits method to wrong file, breaking load |
| 8 | Open | Medium | Save silently overwrites unrelated files |
