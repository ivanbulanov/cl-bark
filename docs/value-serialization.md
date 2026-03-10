# Value Serialization

cl-bark serializes field values to JSON and logfmt without signaling errors on any input type. A curated subset of Common Lisp types maps cleanly to each output format. Unsupported types produce a bounded `<type-name>` placeholder rather than crashing, hanging, or producing unbounded output.

## Design Rationale

A logging library must never crash, hang, or produce unbounded output -- even when handed unexpected types. Rather than attempting to serialize every CL type (risking circular structures, huge output, and implementation-dependent representations), cl-bark:

- **Supports types that map cleanly** to JSON and logfmt
- **Produces bounded placeholders** for everything else, derived from `type-of`
- **Never traverses opaque objects** -- no circularity risk
- **Provides a clear contract** -- unsupported types are the caller's job to convert

## JSON Value Types (`emit-json-value`)

### Scalars

Emitted at any nesting depth.

| CL Type | JSON | Example input | Example output |
|---------|------|---------------|----------------|
| `string` | quoted, escaped | `"hello"` | `"hello"` |
| `character` | single-char string | `#\a` | `"a"` |
| `integer` | number | `42` | `42` |
| `float` | number | `3.14` | `3.14` |
| `ratio` | number | `1/3` | `0.3333333333333333` |
| `t` | `true` | `t` | `true` |
| `nil` | `null` | `nil` | `null` |
| `symbol` | lowercase string | `:foo` | `"foo"` |
| `pathname` | namestring | `#P"/tmp/log"` | `"/tmp/log"` |

**Ratio handling:** Coerced to `double-float` and printed via `~F` format directive. This avoids the CL `d0` suffix in the output. Precision loss is inherent to IEEE 754 doubles (e.g. `1/3` becomes `0.3333333333333333`, not exactly one-third).

### Collections

Emitted when nesting depth > 0. Become `<type>` placeholders at depth 0.

| CL Type | JSON | Notes |
|---------|------|-------|
| `cons` (proper list) | `[1,2,3]` | Recursive |
| `cons` (dotted pair) | `[1,2]` | Cdr appended as final element |
| `vector` | `[1,0,1]` | Includes bit-vectors |
| `hash-table` | `{"k":"v"}` | See key handling below |

### Hash-Table Key Coercion

JSON object keys must be strings. cl-bark coerces hash-table keys:

| Key type | Coercion | Example |
|----------|----------|---------|
| `string` | Used as-is | `"name"` |
| `symbol` | `string-downcase` of symbol-name | `:name` -> `"name"` |
| `pathname` | `namestring` | `#P"/tmp"` -> `"/tmp"` |
| anything else | Lowercased type name | `42` -> `"(integer 0 ...)"` |

Non-string/symbol/pathname keys signal "you're using unsupported key types" without crashing.

### Unsupported Types (Placeholder)

Any type not listed above produces a JSON string `"<type-name>"`:

| Value | JSON output |
|-------|-------------|
| `#'car` | `"<function>"` |
| `(make-condition 'error ...)` | `"<simple-error>"` |
| `#C(1 2)` | `"<complex>"` |
| CLOS instance | `"<class-name>"` |
| `*standard-output*` | `"<synonym-stream>"` |

The placeholder is always a bounded string. To control the representation, convert values before logging.

## logfmt Value Types (`emit-logfmt-value`)

logfmt is a flat key=value format. cl-bark emits **scalars only** -- no collections, no recursive descent.

| CL Type | logfmt | Notes |
|---------|--------|-------|
| `string` | bare or `"quoted"` | Quoted if contains space, `"`, or `=` |
| `character` | bare char | `#\x` -> `x` |
| `integer` | number | `42` |
| `float` | number | `3.14` |
| `ratio` | number | `1/3` -> `0.3333333333333333` |
| `nil` | `null` | |
| `symbol` | lowercase | `:foo` -> `foo` |
| `pathname` | bare or quoted | `#P"/tmp/my log"` -> `"/tmp/my log"` |
| anything else | `<type>` | `<cons>`, `<hash-table>`, `<function>` |

**Boolean `t` handling:** In logfmt, a bare key with no `=value` means true. The logfmt formatter handles this at the field-writing level: when a field value is `t`, it emits just the key and skips `=value` entirely. `emit-logfmt-value` is never called for `t`.

## Serialization Limits

Two special variables bound output size for JSON collections:

```lisp
(defvar *max-emit-depth* 4)    ; nesting depth before placeholder
(defvar *max-emit-length* 20)  ; elements per collection before truncation
```

### Depth Limit

`emit-json-value` accepts an optional `depth` parameter (default `*max-emit-depth*`). Each recursive descent into a collection decrements depth by 1. At depth 0, collections become `<type>` placeholders instead of being traversed.

```lisp
;; Default depth (4): deeply nested structures eventually hit placeholders
(emit-json-value stream '((((deeply nested)))))
;; At depth 1: top-level list serialized, nested list becomes placeholder
(emit-json-value stream '(1 (2 3)) 1)  ; => [1,"<cons>"]
```

In practice, depth 0 is only reached through deep nesting (4 levels with the default) or explicit opt-in. Top-level collections always serialize at the default depth.

### Length Limit

Each collection (list, vector, hash-table) emits at most `*max-emit-length*` elements. If truncated, a `"..."` sentinel is appended.

```lisp
(let ((*max-emit-length* 3))
  (emit-json-value stream '(1 2 3 4 5)))
;; => [1,2,3,"..."]

(let ((*max-emit-length* 2))
  (emit-json-value stream #(10 20 30 40)))
;; => [10,20,"..."]
```

For hash-tables, the sentinel is `"...":"..."` to maintain valid JSON object syntax.

Both limits can be overridden per-call with `let` bindings.

## API

### Exported Functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `emit-json-value` | `(stream value &optional depth)` | Write VALUE as JSON |
| `emit-json-key` | `(stream key)` | Write KEY as JSON object key |
| `emit-json-fields` | `(stream fields)` | Write plist as JSON key-value pairs |
| `emit-logfmt-value` | `(stream value)` | Write VALUE as logfmt scalar |
| `emit-logfmt-key` | `(stream key)` | Write KEY as logfmt key |
| `write-json-escaped-string` | `(string stream)` | Write STRING with JSON escaping |
| `serialize-bindings` | `(bindings)` | Pre-serialize plist to JSON fragment string |

### Exported Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `*max-emit-depth*` | `4` | Max nesting depth for JSON collections |
| `*max-emit-length*` | `20` | Max elements per collection before truncation |

### Legacy Names

The following names are still exported as aliases for backward compatibility:

| Legacy | Current |
|--------|---------|
| `emit-value` | `emit-json-value` |
| `emit-key` | `emit-json-key` |
| `emit-fields` | `emit-json-fields` |
| `logfmt-write-value` | `emit-logfmt-value` |
| `logfmt-write-key` | `emit-logfmt-key` |
