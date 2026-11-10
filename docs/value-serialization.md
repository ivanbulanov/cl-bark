# Value Serialization

cl-bark serializes field values to JSON and logfmt without signaling errors on any input type. A curated subset of Common Lisp types maps cleanly to each output format. Unsupported types produce a bounded `<type-name>` placeholder rather than crashing, hanging, or producing unbounded output.

## Design Rationale

A logging library must never crash, hang, or produce unbounded output, even when handed unexpected types. Rather than attempting to serialize every CL type (risking circular structures, huge output, and implementation-dependent representations), cl-bark:

- Supports types that map cleanly to JSON and logfmt
- Produces bounded placeholders for everything else, derived from `type-of`
- Never traverses opaque objects, no circularity risk
- Provides a clear contract, unsupported types are the caller's job to convert

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
| `condition` | object | `(make-condition 'simple-error ...)` | `{"type":"simple-error","msg":"boom"}` |
| `captured-error` | object | `(bark:capture condition)` | `{"type":"simple-error","msg":"boom","stack":[...]}` |

Ratio handling: Coerced to `double-float` and printed via `~F` format directive. This avoids the CL `d0` suffix in the output. Precision loss is inherent to IEEE 754 doubles (e.g. `1/3` becomes `0.3333333333333333`, not exactly one-third).

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
| `symbol` | `string-downcase` of symbol-name | `:name` becomes `"name"` |
| `pathname` | `namestring` | `#P"/tmp"` becomes `"/tmp"` |
| anything else | Lowercased type name | `42` becomes `"(integer 0 ...)"` |

Non-string/symbol/pathname keys signal "you're using unsupported key types" without crashing.

### Unsupported Types (Placeholder)

Any type not listed above produces a JSON string `"<type-name>"`:

| Value | JSON output |
|-------|-------------|
| `#'car` | `"<function>"` |
| `#C(1 2)` | `"<complex>"` |
| CLOS instance | `"<class-name>"` |
| `*standard-output*` | `"<synonym-stream>"` |

The placeholder is always a bounded string. To control the representation, convert values before logging.

## logfmt Value Types (`emit-logfmt-value`)

logfmt is a flat key=value format. cl-bark emits scalars only, no collections, no recursive descent.

| CL Type | logfmt | Notes |
|---------|--------|-------|
| `string` | bare or `"quoted"` | Quoted if contains space, `"`, or `=` |
| `character` | bare char | `#\x` becomes `x` |
| `integer` | number | `42` |
| `float` | number | `3.14` |
| `ratio` | number | `1/3` becomes `0.3333333333333333` |
| `nil` | `null` | |
| `symbol` | lowercase | `:foo` becomes `foo` |
| `pathname` | bare or quoted | `#P"/tmp/my log"` becomes `"/tmp/my log"` |
| `condition` | quoted string | `(make-condition 'simple-error ...)` becomes `"simple-error: boom"` |
| `captured-error` | quoted string | `(bark:capture condition)` becomes `"simple-error: boom"` |
| anything else | `<type>` | `<cons>`, `<hash-table>`, `<function>` |

Boolean `t` handling: In logfmt, a bare key with no `=value` means true. The logfmt formatter handles this at the field-writing level: when a field value is `t`, it emits just the key and skips `=value` entirely. `emit-logfmt-value` is never called for `t`.

## Pretty Value Types (`pretty-formatter`)

The pretty formatter uses `princ` (CL's human-readable printer) for most values, with special handling for conditions and captured errors.

| CL Type | Output | Notes |
|---------|--------|-------|
| `string` | bare, unquoted | `princ` omits quotes |
| `integer` | number | `42` |
| `float` | number | `3.14` |
| `symbol` | uppercase | `*print-case*` is bound to `:upcase` |
| `cons` | `(1 2 3)` | `princ` output, bounded by `*print-level*` and `*print-length*` (see Limits below) |
| `hash-table` | `#<HASH-TABLE ...>` | Implementation-dependent |
| `condition` | type: message | `simple-error: boom` |
| `captured-error` | type: message + stack | `simple-error: boom` + indented stack frames |
| anything else | `princ` output | Whatever `print-object` produces |

Keys are lowercased (same as JSON/logfmt), dimmed with ANSI escape codes, and separated by `=`.

Limits: The pretty formatter binds CL's printer variables internally:

| bark variable | CL variable bound | Default | Effect |
|---------------|-------------------|---------|--------|
| `*max-pretty-depth*` | `*print-level*` | `4` | Nesting depth; deeper structures print as `#` |
| `*max-pretty-length*` | `*print-length*` | `20` | Elements per collection; excess prints as `...` |

`*print-circle*` is always bound to `t`, so circular structures are safe.

Set either variable to `nil` to remove the corresponding limit. `make-pretty-formatter :max-depth` and `:max-length` set them for one formatter (see [formatters.md](formatters.md#limits-per-formatter)).

## Conditions

A condition passed as a field value is rendered with its type and message, by all three formatters. `bark:capture` adds a stack trace. The output shapes, the stack frame limits and `capture` usage are in [formatters.md](formatters.md#condition-logging).

## Serialization Limits

Two special variables bound output size for JSON collections:

```lisp
(defvar *max-json-depth* 4)    ; nesting depth before placeholder
(defvar *max-json-length* 20)  ; elements per collection before truncation
```

### Depth Limit

`emit-json-value` accepts an optional `depth` parameter (default `*max-json-depth*`). Each recursive descent into a collection decrements depth by 1. At depth 0, collections become `<type>` placeholders instead of being traversed.

```lisp
;; Default depth (4): deeply nested structures eventually hit placeholders
(emit-json-value stream '((((deeply nested)))))
;; At depth 1: top-level list serialized, nested list becomes placeholder
(emit-json-value stream '(1 (2 3)) 1)  ; => [1,"<cons>"]
```

In practice, depth 0 is only reached through deep nesting (4 levels with the default) or explicit opt-in. Top-level collections always serialize at the default depth.

### Length Limit

Each collection (list, vector, hash-table) emits at most `*max-json-length*` elements. If truncated, a `"..."` sentinel is appended.

```lisp
(let ((*max-json-length* 3))
  (emit-json-value stream '(1 2 3 4 5)))
;; => [1,2,3,"..."]

(let ((*max-json-length* 2))
  (emit-json-value stream #(10 20 30 40)))
;; => [10,20,"..."]
```

For hash-tables, the sentinel is `"...":"..."` to maintain valid JSON object syntax.

Both limits can be overridden per-call with `let` bindings.

### Limits per formatter

`make-json-formatter` takes `:max-depth`, `:max-length` and `:max-stack-frames`, and `make-pretty-formatter` takes the
same three for its own variables. A formatter made with a limit binds the variable to it around each line it formats
and around the context a child logger adds, so the limit belongs to that formatter alone. A limit left NIL reads the
variable at format time, as above. Details and examples are in
[formatters.md](formatters.md#limits-per-formatter).

## API

`capture` and the variables below are exported. The functions named in this page's headings, such as `emit-json-value`, `emit-json-key`, `emit-logfmt-value` and `write-json-escaped-string`, are internal to the `bark` package: reach them with `bark::` at your own risk.

### Exported Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `*max-json-depth*` | `4` | Max nesting depth for JSON collections |
| `*max-json-length*` | `20` | Max elements per JSON collection before truncation |
| `*max-pretty-depth*` | `4` | Nesting depth for pretty-formatter (binds `*print-level*`) |
| `*max-pretty-length*` | `20` | Elements per collection for pretty-formatter (binds `*print-length*`) |
| `*max-json-stack-frames*` | `10` | Max stack frames in JSON condition output |
| `*max-pretty-stack-frames*` | `20` | Max stack frames in pretty-formatter condition output |
