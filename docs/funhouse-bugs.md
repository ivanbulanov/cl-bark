# Funhouse Bugs Found During cl-bark Audit

## Bug #1: Section format with trailing text doesn't round-trip

**Severity:** Medium — prevents using decorative section formats like `;;; --- Title ---`

**Steps to reproduce:**
1. Set section convention: `conventions(action: "set", path: "sections.format", value: "\";;; --- ~A ---\"")`
2. Save (persists to `.funhouse/conventions.lisp`)
3. Reload the project

**Expected:** Section headers `;;; --- Sampling ---` parsed as section name `"Sampling"`

**Actual:** `~A` in the format is greedy during parsing — it consumes the trailing ` ---` as part of the section name, producing `"Sampling ---"`. All section names get mangled.

**Root cause:** CL's `format`/`parse` treats `~A` as a greedy match. The trailing ` ---` in the format template `";;; --- ~A ---"` is not used to constrain the match boundary. The parser strips the prefix `;;; --- ` and assigns everything remaining to `~A`, including the trailing ` ---`.

**Workaround:** Use `";;; ~A"` (no trailing delimiter). Decorative headers with `;;; --- Title ---` can coexist as manual sub-grouping comments, but they must not be the section format.

**Impact on cl-bark:** Forced use of `;;; SectionName` (plain format) for Funhouse-managed section headers. Original `;;; --- Title ---` style is used only for manual sub-groupings within sections.

**Fix suggestion:** The convention format parser should handle trailing literal text after `~A` by scanning backward from the end of the line. E.g., for format `";;; --- ~A ---"`:
1. Match prefix `";;; --- "` → strip it
2. Match suffix `" ---"` → strip it from the end
3. What remains is the section name
