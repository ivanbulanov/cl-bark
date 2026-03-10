# cl-bark Multi-Output Design

Design for multi-destination logging in cl-bark: tee (fan-out), per-output filters and formatters, and explicit logger selection at call sites.

## Motivation

cl-bark currently supports one output per logger. In practice, users need:

- **Mirroring** — same events to multiple destinations with different formats (pretty to console, JSON to file)
- **Routing** — different events to different destinations based on level, content, or other criteria
- **Explicit selection** — choosing which logger receives a specific event at the call site

## Design Summary

Two additions to the public API:

| Addition | Purpose |
|----------|---------|
| `bark:tee` (macro) | Combine multiple destination specs into a single output; fan-out at the emit layer |
| Logger as first arg to macros | Optionally pass an explicit logger instead of using `*logger*` |

These are orthogonal. Tee is for mirroring/routing. Explicit logger arg is for call-site selection. Both can be used together or independently.

Additionally, `bark:start` replaces `:stream` with `:output`, which accepts either a plain stream or a tee value.

## API

### `tee` (macro)

```lisp
(bark:tee &rest destination-specs) -> output
```

A macro. Each destination spec has the form `(stream-expr &key formatter filter level)`:

- `stream-expr` — evaluated; any expression that yields an output stream
- `formatter` — evaluated; a formatter function (defaults to `#'bark:json-formatter`)
- `filter` — evaluated; `(lambda (level fields) ...)` returning non-nil to pass, nil to skip. When omitted, all events pass.
- `level` — a level keyword; shorthand for a filter that checks `(>= level +<level>+)`. Mutually exclusive with `:filter` — specifying both is a compile-time error.

The filter receives the log level (integer) and the per-call fields (the `&rest` plist passed to `bark:info` etc.). It does not see static context (child bindings) or dynamic context (`with-context` bindings) — those are part of formatting, not routing.

The macro evaluates each stream and formatter expression, wraps each destination in an async-output (ring buffer + writer thread), and returns a value the logger's `output` slot accepts. `bark:stop` tears down all writer threads.

`:level` is sugar — these are equivalent:

```lisp
(bark:tee
  (*error-output* :formatter #'bark:json-formatter :level :error))

(bark:tee
  (*error-output* :formatter #'bark:json-formatter
                  :filter (lambda (level fields)
                            (declare (ignore fields))
                            (>= level +error+))))
```

Because `tee` is a macro, stream and formatter expressions are evaluated naturally — no quoting issues, no `list` wrappers:

```lisp
(bark:tee
  (*error-output*                       :formatter #'bark:pretty-formatter)
  ((open "/var/log/app.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'my-custom-formatter)
  ((open "/var/log/errors.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'bark:json-formatter :level :error))
```

### `start`

`bark:start` takes `:output` instead of `:stream`:

```lisp
(bark:start :name "myapp" :level :info :output *error-output*)

(bark:start :name "myapp" :level :info
            :output (bark:tee ...))
```

When `:output` is a plain stream, `start` wraps it in an async-output. When `:output` is a tee value, the async-outputs are already created by the `tee` macro.

### Explicit logger argument

All six logging macros (`trace`, `debug`, `info`, `warn`, `error`, `fatal`) accept an optional logger as the first argument:

```lisp
(bark:info "message" &rest fields)           ; uses *logger*
(bark:info some-logger "message" &rest fields) ; uses some-logger
```

Dispatch via `logger-p` on the first argument at runtime (struct type tag check, negligible cost).

Macro expansion:

```lisp
(defmacro info (first &rest rest)
  (let ((g (gensym)))
    `(let ((,g ,first))
       (if (logger-p ,g)
           (funcall (logger-info-fn ,g) ,g ,@rest)
           (when *logger*
             (funcall (logger-info-fn *logger*) *logger* ,g ,@rest))))))
```

## Architecture: Where Work Happens

Today: caller thread formats, string enters ring buffer, writer thread does I/O.

With multi-output: **filter and format in the caller thread, per destination.** Each destination has its own async-output (ring buffer + writer thread). The ring buffer still holds formatted strings.

```
Caller thread                      Writer threads (one per destination)
     |                                  |
     +-- for each destination in tee:   |
     |     if (passes filter)           |
     |       format with destination's  |
     |         formatter                |
     |       emit string to             |
     |         ring buffer  ----------> +-- pop + write-string
     |                                  |
```

The `tee` macro creates the async-outputs at macro-expansion time. `bark:stop` iterates all destinations and tears down each writer thread.

For filtered-out destinations, the caller skips formatting entirely — less work than today's single-output path for those destinations.

**Shared formatter optimization:** at tee construction time, destinations are grouped by formatter identity (`eq`). When multiple destinations share the same formatter function, the log call formats the message once and emits the resulting string to all their ring buffers. This is a guarantee, not just an internal optimization — users can rely on it when choosing to share formatters across destinations:

```lisp
;; Same formatter → formatted once, emitted to both ring buffers
(bark:tee
  (*error-output* :formatter #'bark:json-formatter)
  (*log-file*     :formatter #'bark:json-formatter :level :error))

;; Different formatters → formatted twice
(bark:tee
  (*error-output* :formatter #'bark:pretty-formatter)
  (*log-file*     :formatter #'bark:json-formatter))
```

## Usage Examples

### Mirror: Console + File

Same events, different formats. The most common multi-output scenario.

```lisp
(defvar *log-file* (open "/var/log/app.jsonl"
                         :direction :output :if-exists :append
                         :if-does-not-exist :create))

(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter)
                     (*log-file*     :formatter #'bark:json-formatter)))

(bark:info "request handled" :status 200)
;; => pretty-printed to stderr
;; => JSON line to log file
```

### Level-Based Routing

Errors to a separate stream.

```lisp
(defvar *error-file* (open "/var/log/errors.jsonl"
                           :direction :output :if-exists :append
                           :if-does-not-exist :create))

(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter)
                     (*error-file*   :formatter #'bark:json-formatter
                                     :level :error)))

(bark:info "all good")           ; console only
(bark:error "disk full" :vol 3)  ; console + error file
```

### Content-Based Routing

Audit events to a dedicated stream based on a per-call field.

```lisp
(defvar *audit-file* (open "/var/log/audit.jsonl"
                           :direction :output :if-exists :append
                           :if-does-not-exist :create))

(bark:start :name "myapp" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:json-formatter)
                     (*audit-file*   :formatter #'bark:json-formatter
                                     :filter (lambda (level fields)
                                               (declare (ignore level))
                                               (getf fields :audit)))))

(bark:info "page loaded" :path "/home")                     ; console only
(bark:info "user login" :audit t :user-id 42 :method "sso") ; console + audit file
```

Note: the filter sees only the per-call fields (`:audit`, `:user-id`, etc.), not static context from `child` or dynamic context from `with-context`.

### Explicit Logger Selection

Two independent loggers, caller decides which one to use per call site.

```lisp
;; App logger via start (async)
(bark:start :name "app" :level :info)

;; Audit logger — separate, sync output to a file
(defvar *audit-logger*
  (bark:make-logger :name "audit" :level :info
                    :output (open "/var/log/audit.jsonl"
                                  :direction :output :if-exists :append
                                  :if-does-not-exist :create)))

;; App log — uses *logger*
(bark:info "request handled" :status 200)

;; Audit log — explicit logger
(bark:info *audit-logger* "user login" :user-id 42)
```

### Explicit Logger + Dynamic Context

`with-context` is orthogonal — it sets `*log-context*`, which any logger reads.

```lisp
(bark:with-context (:request-id "req-123" :tenant "acme")
  (bark:info "processing request")                          ; app logger, has context
  (bark:info *audit-logger* "elevated privileges" :role "admin")) ; audit logger, also has context
```

### Child Loggers Inherit Tee

`child` copies the parent's `output` slot. A tee is just a value in that slot — inherited transparently.

```lisp
(defvar *log-file* (open "/var/log/app.jsonl"
                         :direction :output :if-exists :append
                         :if-does-not-exist :create))

(bark:start :name "app" :level :info
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter)
                     (*log-file*     :formatter #'bark:json-formatter)))

(let ((bark:*logger* (bark:child bark:*logger* :component "auth")))
  (bark:info "token verified" :user-id 42))
;; => both destinations receive the event
;; => both include static context component:"auth"
```

### Single Output

`:output` with a plain stream or defaulting to `*error-output*`.

```lisp
(bark:start :name "myapp" :level :info)
(bark:info "business as usual")
```

## Interaction Matrix

| Feature | Tee | Explicit Logger | Child | with-context |
|---------|-----|-----------------|-------|--------------|
| **Tee** | — | Independent | Inherited via output slot | Orthogonal |
| **Explicit Logger** | Can use a logger whose output is a tee | — | N/A (bypasses *logger*) | Context applies to explicit logger too |
| **Child** | Inherits parent's tee | N/A | Chains context | Orthogonal |
| **with-context** | Applied per-destination during format | Read by any logger | Orthogonal | Nests |

## Non-Goals

- **Output override on `child`** — child is for adding static context, not rerouting. Use a separate logger or explicit logger arg for different routing.
- **Structured data in ring buffer** — formatting stays in the caller thread. The ring buffer holds strings. This preserves the current architecture and keeps the writer thread simple.
- **Named logger registry** — users who need multiple loggers manage their own variables. No global registry.
- **Output as a user-visible object** — destination specs are syntax consumed by the `tee` macro. The internal representation is an implementation detail.
- **Filter on static/dynamic context** — filters see only the log level and per-call fields. Routing based on child bindings or `with-context` fields is not supported; those are formatting concerns, not routing concerns.
