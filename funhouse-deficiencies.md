# Funhouse Deficiencies Found During cl-bark Refactoring

**Date:** 2026-03-24
**Context:** Refactoring cl-bark using Funhouse MCP tools exclusively
**Updated:** 2026-03-24 — workspace lifecycle simplified, better suggestions for file mapping issues

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

- [x] ## 3. New Definitions Without `file` Get Assigned to Wrong File

**Symptom:** When using `define-batch` to define condition types without specifying `file`, the conditions were assigned to `src/levels.lisp` instead of the expected `src/conditions.lisp`. Required a second `define-batch` call with explicit `file` parameter to fix.

**Impact:** Minor — requires awareness that `define`/`define-batch` without `file` uses a default (first file in the package with room for the definition kind), not the "natural" file for the definition.

**Root cause:** `resolve-target-file` in file-model.lisp picks the first file that has the definition's package in scope. In a multi-file package, this is the first file in load order — which may not be the right file for the definition's kind.

**Resolution:** `sync-define` no longer auto-assigns files for new definitions without an explicit `file` parameter. New definitions are left unassigned (no file-model-node). Pre-save validation in `dump-source-handler` catches unassigned definitions and returns `unassignedDefinitions` with candidate files, nudging the agent to assign files explicitly before saving. Redefinitions of existing definitions still inherit their file association.

---

- [x] ## 4. `define-condition` Parent Type Conflicts with Package Shadows

**Symptom:** `define-condition bark-error (error) ...` failed with "Class not yet defined: ERROR" because BARK shadows `cl:error` with a logging macro. Required `(define-condition bark-error (cl:error) ...)` with explicit CL package prefix.

**Impact:** Minor inconvenience. The error message is unhelpful — it says "Class not yet defined" rather than indicating a symbol resolution issue.

**Suggestion:** When `define-condition` fails to resolve a parent type, check if the symbol exists but names a non-class (macro/function), and provide a more helpful error message suggesting the fully-qualified name.

**Resolution:** Fixed in commit `93b88b8` — error message now detects shadowed parent types and suggests the fully-qualified CL name.

---

- [x] ## 5. `query` Predicate Error on Struct-Generated Functions

**Symptom:** The query `(-> (symbols :kind :function) (filter (lambda (s) (let ((sig (signature-parts s))) (> (+ (length (getf sig :required)) (length (getf sig :key))) 6)))))` failed with:

```
Predicate error during filter on element %RING-BUFFER-TRY-PUSH:
The value 3 is not of type SEQUENCE
```

**Impact:** Cannot filter functions by parameter count without excluding struct-generated functions. The `signature-parts` combinator returns an integer (arity) instead of a plist for some compiler-generated functions.

**Suggestion:** `signature-parts` should return a consistent plist shape for all function kinds, or `filter` should handle predicate errors gracefully (skip the element with a warning instead of aborting the entire query).

**Resolution:** Fixed — `signature-parts` now returns lists of parameter names instead of integer counts for `:required`, `:optional`, and `:key` slots (e.g. `(:required (A B) :key (X Y) ...)` instead of `(:required 2 :key 2 ...)`). The `(length (getf sig :required))` pattern now works correctly. Also added a `(listp ll)` guard to handle non-list lambda-list values gracefully.

---

- [x] ## 6. `unused-export-p` Doesn't Consider Macro Expansions

**Observation:** `unused-export-p` reported 34 of 37 exports as unused. However, many of these (the logging macros `DEBUG`, `ERROR`, `INFO`, etc.) are heavily used — they're invoked as macros, not as direct function calls. The `unused-export-p` predicate appears to check `callers` (who-calls) but not `macro-users` (who-macroexpands).

**Impact:** Misleading results for macro-heavy libraries. The refactoring analysis incorrectly described 35 exports as "unused externally."

**Suggestion:** `unused-export-p` should also check `macro-users` and `references` (who-references-as-value) in addition to `callers`.

**Resolution:** Fixed in commit `f2f8242` — `effective-callers` now checks `macro-users` for macros and `references` for functions/GFs.

---

- [x] ## 7. `workspace(action: save)` Emits Method to Wrong File, Breaking Load Order

**Symptom:** After redefining `adapter-find-test-by-name` (a method on `fiveam-adapter`) in the live workspace, `workspace(action: save)` moved the method body from `src/adapters/fiveam.lisp` to `src/test-adapter.lisp` and replaced the `defgeneric` with the method definition. On reload, SBCL fails with `CLASS-NOT-FOUND-ERROR: There is no class named FIVEAM-ADAPTER` because `test-adapter.lisp` is loaded before `adapters/fiveam.lisp` (where the class is defined).

**Impact:** High — a save/reload cycle produces an unloadable project. Required manual `git checkout` to restore the two affected files.

**Root cause:** When a method's GF is defined in file A but the method specializes on a class from file B (loaded later), the save emitter places the method body in file A (with the GF). This breaks when the specializer class doesn't exist yet at file A's load time.

**Resolution:** Two complementary fixes applied:

1. **Method-entry carries file-model-node.** `register-method-definition` now carries over the old method-entry's `file-model-node` when a method is redefined. `update-file-model-for-define` handles methods separately via `update-file-model-for-method`, which marks the method's own node dirty instead of the GF's. This prevents method redefinition from corrupting the GF's source text or moving the method to the wrong file.

2. **Pre-save validation (shared with #3).** `dump-source-handler` validates that all definitions and methods have file assignments before saving. Methods without file-model-nodes (new methods without explicit `file`) are caught and reported as unassigned.

---

- [x] ## 8. `workspace(action: save)` Silently Overwrites Unrelated Files

**Symptom:** Saving after modifying only `effective-callers` in `concept.lisp` also rewrote `test-adapter.lisp` and `adapters/fiveam.lisp` with semantically different content (method moved between files, docstring truncated). The diff showed only `concept.lisp` as a dirty file, but save touched 3 files.

**Impact:** Medium — changes to unrelated files are silently introduced. The user must review `git diff` after every save to catch unexpected mutations. In this case the unrelated changes broke the project's load order.

**Resolution:** Two fixes combined:
1. Commit `5adf320` fixed the "stale dirty nodes" issue — file model nodes are reset after save, preventing re-emission of previously modified files.
2. The #7 fix (method-aware file model sync) prevents method redefinition from corrupting GF nodes in unrelated files. Methods now operate on their own file-model-nodes.

---

- [x] ## 9. Save Appends Duplicate Test Definitions When Framework Changes

**Symptom:** Defining tests with `5am:def-test`, then redefining the same-named tests with native `deftest`, then saving — the file contains both the old `5am:def-test` and new `deftest` versions. The old versions are not removed, causing `Package 5AM does not exist` errors on reload.

**Impact:** Medium — test files become corrupted with duplicate definitions. Requires manual file editing to clean up. The file model tracks definitions by name but doesn't recognize that `5am:def-test` and `deftest` create the same logical test.

**Suggestion:** The file model should track test definitions by their logical name across framework-specific macros, or `define` should explicitly untrack the old form when redefining a test with a different macro.

**Resolution:** Fixed — `update-test-file-content` now falls back to name-only matching when the operator-specific search fails. When replacing a test with a different framework macro (e.g. `deftest` → `5am:def-test`), `find-form-span` first tries exact operator match, then retries with name-only if no match. This preserves operator disambiguation for non-switching cases while handling framework switching gracefully.

---

## Summary

| # | Status | Severity | Category |
|---|--------|----------|----------|
| 1 | Fixed | Medium | Test detection reliability |
| 2 | Fixed | Medium | Test execution for dynamically defined tests |
| 3 | Fixed | Low | File mapping: default file assignment |
| 4 | Fixed | Low | Error message quality for define-condition |
| 5 | Fixed | Medium | Query robustness with compiler-generated functions |
| 6 | Fixed | Medium | Export analysis accuracy for macros |
| 7 | Fixed | High | File mapping: method emitted to wrong file |
| 8 | Fixed | Medium | File mapping: save overwrites unrelated files |
| 9 | Fixed | Medium | Save appends duplicate tests on framework change |

## Cross-cutting theme: File Mapping (resolved)

Deficiencies #3, #7, and #8 shared a root cause: **file association for definitions was implicit and fragile.** The system guessed which file a definition belonged to, and these guesses were wrong — especially for methods in multi-file packages.

Fixed with three changes:
1. **`sync-define` no longer guesses** — new definitions without explicit `file` are left unassigned
2. **Method-aware file model sync** — method redefinition operates on the method's own file-model-node, not the GF's
3. **Pre-save validation** — `dump-source-handler` refuses to save if any definitions lack file assignments, returning `unassignedDefinitions` with candidate files

This shifts file organization from "guess at define time" to "validate before persist," which aligns with Funhouse's philosophy of letting the agent experiment freely and only enforcing structure when persisting.

### Workspace lifecycle note

The `clean` workspace action was removed (commit `0552855`) as redundant with `load`. The workspace API is now 7 actions: `save | load | diff | create | delete | list | reload-file`. The `load-from` parameter was renamed to `dir` on `create` for consistency. All workspace load mechanisms now detect Funhouse projects and spawn from source automatically.
