# Formatters

A formatter is a struct with two slots: `prepare-fn` and `format-fn`. The `format-fn` has signature:
```
(level prepared context message fields) -> string
```


| Parameter | Type | Purpose |
|-----------|------|---------|
| `level` | fixnum | Numeric log level (1-6) |
| `prepared` | string | Pre-serialized static context prepared by the `prepare-fn` (opaque to the logger). Used by formatters to splice static context into output with zero per-call cost |
| `context` | alist | Dynamic context from `with-context` |
| `message` | string | The log message |
| `fields` | plist | Per-call fields from the `&rest` args |

The `prepare-fn` is called once per child logger creation and receives a plist of static context fields. It returns a pre-serialized string (e.g., a JSON fragment for JSON formatters, a logfmt string for logfmt formatters). The `format-fn` receives this prepared string and splices it into the output. This design enables O(delta) child creation: each child level only serializes its own new fields, inheriting the parent's pre-serialized context.

Built-in formatter factories:
- `bark:make-json-formatter`: creates a JSON Lines formatter (production)
- `bark:make-logfmt-formatter`: creates a `key=value` pairs formatter
- `bark:make-pretty-formatter`: creates a colored terminal formatter for REPL/development

Default formatter: the built-in JSON formatter, equivalent to `(bark:make-json-formatter)`

Field values of every type are accepted, and no log call signals `type-error`. How each type is rendered by each formatter is described in [value-serialization.md](value-serialization.md). Collection depth and length are bounded by `*max-json-depth*`, `*max-json-length*`, `*max-pretty-depth*` and `*max-pretty-length*` (see [reference.md](reference.md)). To control the type name shown in a placeholder, specialize `print-object` on your classes.

## Formatter factories

The built-in factories (`make-json-formatter`, `make-logfmt-formatter`, `make-pretty-formatter`) take keyword arguments that change field names, timestamp format and level encoding, to match an external system's expected format. The configuration is computed once, with no per-call cost.

You can also write an entirely custom formatter using `make-formatter`:

```lisp
(bark:make-formatter &key prepare-fn format-fn)
```

Both `:prepare-fn` and `:format-fn` are required. The `prepare-fn` receives a plist of static context and returns a pre-serialized string. The `format-fn` has signature `(level prepared context message fields)` and returns a string. Custom formatters must call `bark:current-log-timestamp-ms` for timestamps instead of reading the clock directly, during `with-log-buffer` replay, this function returns the original log-call timestamp rather than the flush time.

`make-json-formatter`

```lisp
(bark:make-json-formatter &key (timestamp :unix-ms) (level-format :string)
                               (level-key "level") (timestamp-key "ts")
                               (message-key "msg"))
```

| Parameter | Values | Default |
|-----------|--------|---------|
| `timestamp` | `:unix-ms`, `:iso8601`, `nil` (omit) | `:unix-ms` |
| `level-format` | `:string`, `:numeric` | `:string` |
| `level-key` | any string, or `nil` (omit) | `"level"` |
| `timestamp-key` | any string | `"ts"` |
| `message-key` | any string | `"msg"` |

```lisp
;; GCP Cloud Logging format
(setf bark:*logger*
      (bark:make-logger :formatter (bark:make-json-formatter
                                     :level-key "severity" :level-format :string
                                     :timestamp-key "timestamp" :timestamp :iso8601
                                     :message-key "message")))

(bark:info "deployed" :version "1.2.3")
;; => {"severity":"info","timestamp":"2025-01-15T12:00:00.000Z","version":"1.2.3","message":"deployed"}

;; Omit timestamp (external system adds it)
(setf bark:*logger* (bark:make-logger :formatter (bark:make-json-formatter :timestamp nil)))
;; => {"level":"info","version":"1.2.3","msg":"deployed"}

;; Omit level (external system adds it)
(setf bark:*logger* (bark:make-logger :formatter (bark:make-json-formatter :level-key nil)))
;; => {"ts":1740600000123,"msg":"deployed"}
```

`make-logfmt-formatter`

```lisp
(bark:make-logfmt-formatter &key (timestamp :unix-ms) (level-key "level")
                                  (timestamp-key "ts") (message-key "msg"))
```

Level is always a string in logfmt. Pass `:level-key nil` to omit it. Timestamp accepts `:unix-ms`, `:iso8601`, or `nil`.

```lisp
(setf bark:*logger*
      (bark:make-logger :formatter (bark:make-logfmt-formatter :level-key "lvl" :message-key "message")))
(bark:info "ready" :port 8080)
;; => lvl=info ts=1736942400000 port=8080 message=ready
```

`make-pretty-formatter`

```lisp
(bark:make-pretty-formatter &key timestamp (timestamp-key "ts") (show-level t))
```

The standard `pretty-formatter` omits timestamps (REPL use). The factory adds optional timestamp display. Pass `:show-level nil` to omit the colored level label.

```lisp
;; Pretty with ISO 8601 timestamps
(setf bark:*logger* (bark:make-logger :formatter (bark:make-pretty-formatter :timestamp :iso8601)))
;; => INFO  ts="2025-01-15T12:00:00.000Z" ready port=8080
```

## Condition logging

Conditions passed as field values are automatically serialized with their type and message, no wrapper needed.

```lisp
(handler-case (process-request)
  (cl:error (c)
    (bark:error "request failed" :err c :path "/api/users")))
;; JSON: {"level":"error",...,"err":{"type":"simple-error","msg":"connection refused"},"path":"/api/users","msg":"request failed"}
;; logfmt: level=error ... err="simple-error: connection refused" path=/api/users msg=request\ failed
;; pretty: ERROR request failed err=simple-error: connection refused path=/api/users
```

For stack traces, use `bark:capture` inside `handler-bind` (stack still live):

```lisp
(handler-bind ((cl:error (lambda (c)
                           (bark:error "request failed"
                                       :err (bark:capture c))
                           (invoke-restart 'abort))))
  (process-request))
;; JSON err field: {"type":"simple-error","msg":"...","stack":[{"call":"MYAPP::PROCESS-REQUEST","file":"/srv/myapp/api.lisp","line":42},...]}
;; pretty: ERROR request failed err=simple-error: connection refused
;;           at MYAPP::PROCESS-REQUEST (/srv/myapp/api.lisp:42)
;;           at MYAPP::HANDLE-CONNECTION (/srv/myapp/server.lisp:88)
```

`bark:capture` works in `handler-case` too, but the stack trace reflects the handler's location (the stack has already unwound), not the error origin.

`capture` turns the stack into plain data while the frames are live: `captured-error-stack` is a list of plists `(:call string :file namestring-or-NIL :line integer-or-NIL)`, innermost first. The call is printed with its package prefix (COMMON-LISP's omitted), and a frame that fails to print becomes `"#<unprintable frame>"`. No frame object, argument or local variable is kept, so a captured error can be stored, replayed from `with-log-buffer` or formatted later, and it does not hold on to the values of the frames' arguments. `capture` keeps at most `:max-frames` frames, by default `bark:*capture-max-frames*` (50; NIL keeps all):

```lisp
(bark:capture c :max-frames 200)
```

Stack frame limits at format time, applied on top of the `capture` limit:

```lisp
(setf bark:*max-json-stack-frames* 20)    ; default 10, NIL = unlimited
(setf bark:*max-pretty-stack-frames* 30)  ; default 20, NIL = unlimited
```
