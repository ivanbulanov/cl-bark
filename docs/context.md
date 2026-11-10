# Context and field redaction

## Context

Log output includes fields from three sources, merged in this order:

1. Static context: fixed fields on the logger, set by `:context` on `bark:make-logger` or `bark:make-child`. Pre-serialized at creation time; zero cost per log call.
2. Dynamic context: scoped fields via `bark:with-context`. Active for all log calls within the dynamic extent. Thread-isolated via CL special variables.
3. Per-call fields: the `&rest` arguments passed directly to `bark:info`, `bark:warn`, etc.

```lisp
;; Static context, lives on the logger
(let ((auth-logger (bark:make-child bark:*logger* :context '(:component "auth"))))

  ;; Dynamic context, scoped to this body
  (bark:with-context (:request-id "req-123")

    ;; Per-call fields
    (bark:info auth-logger "token verified" :user-id 42)))
;; Output merges all three: component, request-id, user-id
```

### Child loggers or dynamic context

Child loggers bind context when they are created, for identity that lasts as long as the logger:

```lisp
(defvar *db-log* (bark:make-child bark:*logger* :context '(:component "database" :pool-size 10)))
(bark:info *db-log* "connection acquired")
```

Dynamic context binds fields to a code path. Every log call in the extent sees them, whichever logger it uses:

```lisp
(bark:with-context (:request-id "req-123")
  (bark:info *auth-log* "checking token")   ; component=auth, request-id=req-123
  (bark:info *db-log* "running query")      ; component=database, request-id=req-123
  (bark:info *cache-log* "cache miss"))     ; component=cache, request-id=req-123
```

With child loggers alone you would have to create a temporary child of each component logger per request. Use child loggers for fixed identity such as a worker id, and dynamic context for per-request values:

```
child logger:     component=database, pool-size=10    (fixed for the logger)
dynamic context:  request-id=req-123, tenant=acme     (per request)
per-call fields:  query="SELECT ...", duration-ms=42   (this event)
```

### What a child copies and what it shares

| Setting | At `bark:make-child` | Later change on the parent | Later change on the child |
|---|---|---|---|
| Level | Copied from the parent, unless `:level` gives one (lower or higher than the parent's) | `bark:set-level` does not reach existing children | `bark:set-level` changes the child only, and the children made from it afterwards |
| Level samplers (the vector of windowed counters) | Shared. A parent that has none gets an empty vector first, so the two always share one | `bark:set-level-sampler` applies to every child, made before or after | `bark:set-level-sampler` applies to the parent and to all its other children as well |
| Windowed counter budget | Shared with the vector: one count per level for the whole family, so a noisy child spends the budget of all | | |
| Consistent sampler | Copied by reference | `bark:set-consistent` does not reach existing children | `bark:set-consistent` changes the child only |
| Static context | The parent's context plus `:context`; a key in both takes the child's value. Serialized once | No call changes it | No call changes it |
| Field transform | The parent's, then the child's `:field-transform`, composed | No call changes it | No call changes it |
| Formatter and output | Shared | Replacing the root logger (a new `bark:make-logger`) leaves existing children on the old output | `bark:stop` on a child signals `bark-child-operation-error`; stop the root |

A child of a child works the same way: it copies the level of its direct parent and shares the one sampler vector of the family. Inside `with-log-buffer`, a child made from `bark:*logger*` derives from the logger being buffered, not from the buffer, so its lines are written at once and not buffered (see [request-scoped buffering](request-scoped-buffering.md)).

### Key shadowing

Nested `with-context` forms shadow outer keys with the same name, like CL `let`:

```lisp
(bark:with-context (:request-id "req-123")
  ;; Retry with new correlation ID
  (bark:with-context (:request-id "req-456")
    (bark:info "retrying")))
;; => {"request-id":"req-456","msg":"retrying"} , inner value wins, no duplicate keys
```

Non-overlapping keys from outer scopes are preserved:

```lisp
(bark:with-context (:tenant "acme" :request-id "req-123")
  (bark:with-context (:request-id "req-456")
    (bark:info "retrying")))
;; => {"tenant":"acme","request-id":"req-456","msg":"retrying"}
```

When the inner `with-context` exits, the outer binding is restored:

```lisp
(bark:with-context (:x "outer")
  (bark:with-context (:x "inner")
    (bark:info "inside"))   ; x = "inner"
  (bark:info "after"))      ; x = "outer"
```

Note: Shadowing applies only within dynamic context (`with-context`). Duplicate keys across static context (child loggers) and per-call fields are not deduplicated, those layers are the caller's responsibility.

## Field redaction

A `:field-transform` on a logger intercepts every field (key-value pair) before serialization. Use it to drop sensitive fields or mask values.

The transform is a function `(lambda (key value) ...)` returning:
- The (possibly modified) value to keep the field
- `(values nil nil)` (two values, second nil) to drop the field entirely

```lisp
;; Drop :password fields, mask :token values
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :field-transform (lambda (key value)
                                           (case key
                                             (:password (values nil nil))
                                             (:token    "****")
                                             (t         value)))))

(bark:info "login" :user "alice" :password "hunter2" :token "abc-xyz")
;; => {"level":"info",...,"user":"alice","token":"****","msg":"login"}
;; :password is gone, :token is masked
```

The transform applies to all three field sources:

| Source | When applied |
|--------|-------------|
| Per-call fields | At log call time, before formatting |
| Dynamic context | At log call time, before formatting |
| Static context (child) | At `make-child` creation time, before pre-serialization |

Inheritance. Children inherit the parent's transform. A child can add its own via `:field-transform`, it composes with the parent's (parent runs first, then child):

```lisp
(let* ((parent (bark:make-logger :level :info :output stream
                                 :field-transform (lambda (key value)
                                                    (if (eq key :secret)
                                                        (values nil nil)
                                                        value))))
       ;; Child adds token masking on top of parent's secret dropping
       (child (bark:make-child parent :context '(:component "auth")
                               :field-transform (lambda (key value)
                                                  (if (eq key :token)
                                                      "****"
                                                      value)))))
  (bark:info child "login" :user "alice" :secret "pw" :token "xyz"))
;; => :secret dropped (parent), :token masked (child)
```

Cost. One `funcall` per field when the slot is non-nil. When nil (the default), zero overhead, the transform check is a null-pointer test in the hot path.
