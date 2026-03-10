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
| `bark:make-tee` (function) + `bark:tee` (macro) | Combine multiple destination specs into a single output; fan-out at the emit layer |
| Logger as first arg to macros | Optionally pass an explicit logger instead of using `*logger*` |

These are orthogonal. Tee is for mirroring/routing. Explicit logger arg is for call-site selection. Both can be used together or independently.

Additionally, `bark:start` replaces `:stream` with `:output`, which accepts either a plain stream or a tee value.

## API

### `make-tee` (function)

```lisp
(bark:make-tee destinations) -> output
```

A function. `destinations` is a list of plists, each with the keys:

- `:stream` (required) — an output stream
- `:formatter` — a formatter function (defaults to `#'bark:json-formatter`)
- `:filter` — `(lambda (level fields) ...)` returning non-nil to pass, nil to skip. When omitted, all events pass.
- `:level` — a level keyword; shorthand for a filter that checks `(>= level +<level>+)`. Mutually exclusive with `:filter` — specifying both is an error.
- `:capacity` — ring buffer size for this destination (defaults to 8192, rounded up to next power of two)
- `:on-drop` — drop handler for this destination (defaults to `#'bark::default-on-drop`)

The filter receives the log level (integer) and the per-call fields (the `&rest` plist passed to `bark:info` etc.). It does not see static context (child bindings) or dynamic context (`with-context` bindings) — those are part of formatting, not routing.

Wraps each destination in an async-output (ring buffer + writer thread) and returns a value the logger's `output` slot accepts. `bark:stop` tears down all writer threads.

`:level` is sugar — these are equivalent:

```lisp
(bark:make-tee
  (list (list :stream *error-output* :formatter #'bark:json-formatter :level :error)))

(bark:make-tee
  (list (list :stream *error-output* :formatter #'bark:json-formatter
              :filter (lambda (level fields)
                        (declare (ignore fields))
                        (>= level +error+)))))
```

Programmatic construction — destinations from a config list:

```lisp
(bark:make-tee
  (loop for (path . opts) in *log-destinations*
        collect (list* :stream (open path :direction :output :if-exists :append)
                       opts)))
```

### `tee` (macro)

```lisp
(bark:tee &rest destination-specs) -> output
```

Syntax sugar over `make-tee`. Each destination spec has the form `(stream-expr &key formatter filter level capacity on-drop)`. Expressions are evaluated naturally — no quoting needed:

```lisp
(bark:tee
  ;; Fast local console — small buffer is fine
  (*error-output*                       :formatter #'bark:pretty-formatter
                                        :capacity 1024)
  ;; Slow remote sink — large buffer, custom drop message
  ((open "/var/log/app.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'my-custom-formatter
                                        :capacity 65536
                                        :on-drop (lambda (n) (format nil "LOST ~d" n)))
  ;; Errors only — default buffer settings
  ((open "/var/log/errors.jsonl"
         :direction :output
         :if-exists :append)            :formatter #'bark:json-formatter :level :error))
```

Specifying both `:level` and `:filter` in the same destination spec is a compile-time error.

The macro expands to a `make-tee` call:

```lisp
(bark:make-tee
  (list (list :stream *error-output*
              :formatter #'bark:pretty-formatter :capacity 1024)
        (list :stream (open "/var/log/app.jsonl" ...)
              :formatter #'my-custom-formatter :capacity 65536
              :on-drop (lambda (n) (format nil "LOST ~d" n)))
        (list :stream (open "/var/log/errors.jsonl" ...)
              :formatter #'bark:json-formatter :level :error)))
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

`make-tee` creates the async-outputs when called. `bark:stop` iterates all destinations and tears down each writer thread.

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

## Configuration Diagrams

### Single Output

The current default. One logger, one async writer.

```
 bark:info ──► *logger* ──► json-formatter ──► [ring buffer] ──► writer ──► stderr
```

### Tee: Mirror with Different Formatters

Same events, formatted differently per destination.

```
                                 ┌─► pretty-formatter ──► [ring 1] ──► writer 1 ──► stderr
 bark:info ──► *logger* ──► tee─┤
                                 └─► json-formatter ──► [ring 2] ──► writer 2 ──► app.jsonl
```

### Tee: Level-Based Routing

All events to console, errors only to a separate file.

```
                                 ┌─► pretty-formatter ──► [ring 1] ──► writer 1 ──► stderr
 bark:info ──► *logger* ──► tee─┤
                                 └─► filter(≥error) ─?─► json-formatter ──► [ring 2] ──► writer 2 ──► errors.jsonl
                                         │
                                    skip if below
```

### Tee: Shared Formatter Optimization

Two destinations with the same formatter — formatted once, emitted to both.

```
                                 ┌──────────────────────► [ring 1] ──► writer 1 ──► app.jsonl
 bark:info ──► *logger* ──► tee─┤
                                 │  json-formatter
                                 │  (called once)
                                 └─► filter(≥error) ─?─► [ring 2] ──► writer 2 ──► errors.jsonl
```

### Two Independent Loggers

Explicit logger arg bypasses `*logger*`. Each logger has its own output pipeline.

```
 bark:info "msg"          ──► *logger* ──► pretty-formatter ──► [ring 1] ──► writer 1 ──► stderr

 bark:info *audit* "msg"  ──► *audit* ──► json-formatter ──► [ring 2] ──► writer 2 ──► audit.jsonl
```

### Child Logger Inherits Tee

`child` adds static context but shares the parent's tee output.

```
                               chindings: component:"auth"
                                        │
 bark:info ──► child-logger ────────────┤
                                        │
                                    tee (inherited)
                                 ┌──────┴──────┐
                                 ▼              ▼
                          pretty-formatter  json-formatter
                                 │              │
                            [ring 1]       [ring 2]
                                 │              │
                            writer 1       writer 2
                                 │              │
                              stderr        app.jsonl
```

### Combined: Tee + Explicit Logger + Dynamic Context

All features composing. `with-context` applies to whichever logger handles the call.

```
 bark:with-context (:request-id "req-123")
   │
   ├─► bark:info "request" ──► *logger* ──► tee─┬─► pretty ──► stderr
   │                                             └─► json ──► app.jsonl
   │                           (context: request-id)
   │
   └─► bark:info *audit* "login" ──► *audit* ──► json ──► audit.jsonl
                                      (context: request-id)
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
- **Output as a user-visible object** — the tee's internal representation is an implementation detail. `make-tee` and `tee` return an opaque value for the logger's `output` slot.
- **Filter on static/dynamic context** — filters see only the log level and per-call fields, not chindings (static context from `child`) or dynamic context from `with-context`. We considered and rejected chindings filtering — see rationale below.

## Why Filters Don't See Chindings

Chindings (static context set via `bark:child`) are pre-serialized at child creation time. We considered giving filters access to them via `logger-raw-bindings`, but every scenario we examined was better solved by using separate loggers.

### Scenario 1: Per-Component Routing

Goal: route billing events to an audit stream based on `:component "billing"` set via `child`.

```lisp
;; Hypothetical chindings filter
(let ((bark:*logger* (bark:child bark:*logger* :component "billing")))
  (bark:info "charge processed" :amount 100))
;; want audit stream to match on component=billing
```

But you know it's billing when you create the child. Use the explicit logger arg instead:

```lisp
(bark:info *billing-logger* "charge processed" :amount 100)
```

Or give the billing component its own logger with the right output from the start.

### Scenario 2: Multi-Tenant Routing

Goal: child loggers per tenant, route to tenant-specific log files based on `:tenant` chinding.

Same problem — the tenant is known at child creation time. The routing decision can be made then, not deferred to the filter at emit time.

### Scenario 3: Library Creates Children Internally

Goal: an HTTP client library does `(bark:child *logger* :component "http-client")` internally. The application wants to route library events to a debug file by filtering on `component=http-client`.

This is the strongest case — the app doesn't control child creation. But it couples the filter to the library's internal chindings keys, which is fragile. The library should accept a logger parameter instead.

### Conclusion

Chindings are static — the context is known at creation time, so the routing decision can also be made at creation time. Filtering on them at emit time is always after the fact. Use separate loggers or the explicit logger argument for routing based on static context.
