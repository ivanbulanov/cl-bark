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
- `:on-error` — `(lambda (condition) ...)` called in the writer thread when a stream error occurs. Returns a stream to replace the failed one and continue, or nil to let the writer exit (default behavior). When omitted, the writer logs the error to `*error-output*` and exits.

The filter receives the log level (integer) and the per-call fields (the `&rest` plist passed to `bark:info` etc.). It does not see static context (child bindings) or dynamic context (`with-context` bindings) — those are part of formatting, not routing.

Wraps each destination in an async-output (ring buffer + writer thread) and returns a value the logger's `output` slot accepts. `bark:stop` tears down all writer threads but does not close streams — the caller who opened them is responsible for closing them (standard CL convention).

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

Syntax sugar over `make-tee`. Each destination spec has the form `(stream-expr &key formatter filter level capacity on-drop on-error)`. Expressions are evaluated naturally — no quoting needed:

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

Dispatch via `logger-p` on the first argument at runtime (struct type tag check, negligible cost). The explicit logger must be a `logger` struct — passing nil falls through to the `*logger*` path with the nil value as the message, which is a caller error.

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

**Thread-per-destination model:** each destination gets its own writer thread and ring buffer. N destinations = N writer threads. This is a deliberate choice:

- **Isolation** — a slow destination (e.g., network sink with high latency) cannot block fast ones (local file, stderr). Each writer drains its ring buffer independently.
- **Simplicity** — no thread pool scheduling, no multiplexing, no shared-writer coordination. Each writer is a self-contained loop identical to today's single-output writer.
- **Low cost** — idle writer threads are blocked on a semaphore (OS futex). They consume one kernel thread descriptor and minimal RSS (stack pages are virtual until touched). For the typical 2–4 destinations, the overhead is negligible.

The alternative — sharing a writer thread across destinations — would serialize I/O: one slow `write-string` + `force-output` blocks all other destinations on that thread. This is strictly worse for the common case where destinations have different latencies.

For filtered-out destinations, the caller skips formatting entirely — less work than today's single-output path for those destinations.

**Shared formatter optimization:** at tee construction time, destinations are grouped by formatter identity (`eq`). When multiple destinations share the same formatter function, the log call formats the message once and emits the resulting string to all their ring buffers. Users can rely on this when choosing to share formatters across destinations. The optimization applies to function objects that are `eq` — typically `#'bark:json-formatter` used in multiple destination specs. Separately-created closures or lambda forms are not `eq` even if textually identical.

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

### Internal Representation

Two new structs, not exported:

```lisp
(defstruct destination
  "A single output destination within a tee."
  (async-output nil :type async-output)
  (formatter    nil :type function)
  (filter       nil :type (or null function))
  (on-error     nil :type (or null function)))

(defstruct tee-output
  "Fan-out output: multiple destinations, each with its own formatter, filter, and async-output."
  (destinations #() :type simple-vector))  ; vector of destination structs
```

`make-tee` builds a `tee-output`. Each element in the destinations vector holds the per-destination formatter, filter, and async-output (ring buffer + writer thread). The `tee-output` struct goes in the logger's `output` slot — the same slot that today holds a plain `async-output`, stream, or function.

### How `make-log-fn` Changes

Today, `make-log-fn` creates a closure that:
1. Checks the sampler
2. Calls `(logger-formatter lgr)` to format the message
3. Dispatches on `(logger-output lgr)`: async-output → push to ring buffer; stream → write directly; function → funcall

With tee, step 2–3 change based on output type:

```lisp
(let ((output (logger-output lgr)))
  (cond
    ((tee-output-p output)
     (emit-to-tee output level-value
                   (logger-chindings lgr) (logger-raw-bindings lgr)
                   *log-context* message fields))
    ((async-output-p output)
     (let ((line (funcall (logger-formatter lgr) ...)))
       (ring-buffer-push (async-output-ring output) line)
       (bt:signal-semaphore (async-output-notify output))))
    ...))
```

`emit-to-tee` iterates the destinations vector. For each destination:
1. If filter is non-nil, call it with `(level fields)`. Skip this destination if it returns nil.
2. Format with the destination's formatter (not the logger's).
3. Push the formatted string to the destination's ring buffer and signal its writer thread.

The shared-formatter optimization groups destinations by `eq` formatter before iterating. When a group has multiple destinations that all pass their filters, the formatter is called once and the resulting string is pushed to all their ring buffers.

**Hot-path cost:** one `tee-output-p` type check (struct tag comparison) on every log call. For the common non-tee case, this check fails fast and falls through to the existing `async-output-p` branch. The tee path is inherently more expensive (N filter checks + up to N format calls), but that is the cost of multi-output.

### Formatter Slot Interaction

The logger's `formatter` slot and the tee's per-destination formatters are independent:

- **Plain output** (async-output, stream, function): `make-log-fn` uses the logger's `formatter` slot, exactly as today.
- **Tee output**: `make-log-fn` uses each destination's formatter. The logger's `formatter` slot is ignored.

`start` with `:formatter` sets the logger's `formatter` slot regardless of output type. When `:output` is a tee, the slot is inert — each destination already has its own formatter (defaulting to `#'bark:json-formatter` if omitted in the destination spec).

`child` copies the parent's `formatter` slot. When the parent's output is a tee, the child inherits the (inert) formatter slot along with the tee output. This is harmless — the formatter slot is only consulted for non-tee outputs.

### How `stop` Changes

Today, `stop` checks `(async-output-p output)` and calls `stop-async-output`. With tee, it adds a `tee-output-p` branch:

```lisp
(defun stop ()
  (when *logger*
    (let ((output (logger-output *logger*)))
      (cond
        ((and output (tee-output-p output))
         (map nil (lambda (dest)
                    (stop-async-output (destination-async-output dest)))
              (tee-output-destinations output)))
        ((and output (async-output-p output))
         (stop-async-output output))))
    (setf *logger* nil)))
```

Each destination's async-output is stopped independently: flush, set running to nil, join thread, final drain.

### Error Isolation and Recovery

Destinations are independent. If one destination's stream errors (disk full, broken pipe), other destinations continue unaffected. This is intentional — logging is best-effort and must never crash or block the application.

When a writer thread encounters a stream error, it checks the destination's `:on-error` hook:

```lisp
(handler-case
    (progn (write-string line stream) (terpri stream) (force-output stream))
  (cl:error (e)
    (let ((on-error (destination-on-error dest)))
      (if on-error
          (let ((new-stream (funcall on-error e)))
            (if new-stream
                (setf (async-output-stream ao) new-stream)  ; swap and continue
                (setf (async-output-running ao) nil)))      ; give up
          (progn
            (format *error-output* "bark writer-loop error: ~a~%" e)
            (force-output *error-output*)
            (setf (async-output-running ao) nil))))))       ; default: log and exit
```

- **`:on-error` returns a stream** → writer swaps to the new stream and continues draining. The failed message is lost (already attempted), but subsequent messages go to the new stream.
- **`:on-error` returns nil** → writer exits gracefully.
- **No `:on-error`** → writer logs the error to `*error-output*` and exits (current behavior).

Example — reopen a log file on error:

```lisp
(bark:tee
  (*error-output* :formatter #'bark:pretty-formatter)
  ((open "/var/log/app.jsonl" :direction :output :if-exists :append)
   :formatter #'bark:json-formatter
   :on-error (lambda (condition)
               (declare (ignore condition))
               (open "/var/log/app.jsonl"
                     :direction :output :if-exists :append
                     :if-does-not-exist :create))))
```

When a writer exits (no `:on-error` or `:on-error` returns nil), its ring buffer fills and drops subsequent messages via the existing `on-drop` mechanism.

### How `child` Interacts

No change needed. `child` copies the parent's `output` slot, which may be a `tee-output`. The tee-output struct is shared between parent and child — this is correct because child loggers add static context (chindings), they don't reroute. All loggers sharing a tee write to the same set of destinations.

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
