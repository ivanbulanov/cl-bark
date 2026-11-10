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

Field values of every type are accepted, and no log call signals `type-error`. How each type is rendered by each formatter is described in [value-serialization.md](value-serialization.md). Collection depth and length are bounded by `*max-json-depth*`, `*max-json-length*`, `*max-pretty-depth*` and `*max-pretty-length*` (see [reference.md](reference.md)), or by the limits given to one formatter (see [Limits per formatter](#limits-per-formatter)). To control the type name shown in a placeholder, specialize `print-object` on your classes.

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
                               (message-key "msg")
                               max-depth max-length max-stack-frames
                               max-string-length)
```

| Parameter | Values | Default |
|-----------|--------|---------|
| `timestamp` | `:unix-ms`, `:iso8601`, `nil` (omit) | `:unix-ms` |
| `level-format` | `:string`, `:numeric` | `:string` |
| `level-key` | any string, or `nil` (omit) | `"level"` |
| `timestamp-key` | any string | `"ts"` |
| `message-key` | any string | `"msg"` |
| `max-depth` | non-negative integer, or `nil` (read `*max-json-depth*`) | `nil` |
| `max-length` | non-negative integer, or `nil` (read `*max-json-length*`) | `nil` |
| `max-stack-frames` | non-negative integer, `:unlimited`, or `nil` (read `*max-json-stack-frames*`) | `nil` |
| `max-string-length` | non-negative integer, `:unlimited`, or `nil` (read `*max-string-length*`) | `nil` |

The limits are described in [Limits per formatter](#limits-per-formatter).

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
                                  (timestamp-key "ts") (message-key "msg")
                                  max-string-length)
```

Level is always a string in logfmt. Pass `:level-key nil` to omit it. Timestamp accepts `:unix-ms`, `:iso8601`, or `nil`. `max-string-length` is described in [Limits per formatter](#limits-per-formatter).

```lisp
(setf bark:*logger*
      (bark:make-logger :formatter (bark:make-logfmt-formatter :level-key "lvl" :message-key "message")))
(bark:info "ready" :port 8080)
;; => lvl=info ts=1736942400000 port=8080 message=ready
```

`make-pretty-formatter`

```lisp
(bark:make-pretty-formatter &key timestamp (timestamp-key "ts") (show-level t)
                                 max-depth max-length max-stack-frames
                                 max-string-length)
```

The standard `pretty-formatter` omits timestamps (REPL use). The factory adds optional timestamp display. Pass `:show-level nil` to omit the colored level label. `max-depth`, `max-length`, `max-stack-frames` and `max-string-length` take a non-negative integer, `:unlimited`, or `nil` (the default) to read `*max-pretty-depth*`, `*max-pretty-length*`, `*max-pretty-stack-frames*` and `*max-string-length*`; see [Limits per formatter](#limits-per-formatter).

```lisp
;; Pretty with ISO 8601 timestamps
(setf bark:*logger* (bark:make-logger :formatter (bark:make-pretty-formatter :timestamp :iso8601)))
;; => INFO  ts="2025-01-15T12:00:00.000Z" ready port=8080
```

### Limits per formatter

The size limits are special variables (`*max-json-depth*`, `*max-json-length*`, `*max-json-stack-frames*` and their
`*max-pretty-...*` counterparts), so a `setf` changes them for every logger in the image, also for other libraries that
use cl-bark. To give one logger its own limits, pass them to the formatter's constructor:

```lisp
;; Events: short collections, the default stack limit.
(defvar *events*
  (bark:make-logger :output events-stream
                    :formatter (bark:make-json-formatter :max-length 100)))

;; Diagnostics: every frame of a captured error.
(defvar *diagnostics*
  (bark:make-logger :output diagnostics-stream
                    :formatter (bark:make-json-formatter :max-stack-frames :unlimited)))
```

A limit left NIL reads its special when a line is formatted, so `setf` and `let` of the special still work, also for
a formatter made before them. A limit that is set holds for the context a child logger adds as well as for each line.
`:unlimited` is accepted where the special accepts NIL: the stack frame limits and the pretty formatter's depth and
length. JSON depth and length must stay bounded, because the JSON writer has no circularity check. A bad value signals
`bark-configuration-error` when the formatter is made.

`make-logfmt-formatter` takes only `:max-string-length`: logfmt writes a collection as a `<type>` placeholder and a
condition without its stack.

### String length

Nothing else bounds a string, so one large value (a model result, a request body) can make a line of many megabytes.
`bark:*max-string-length*` (default NIL, unlimited) and the `:max-string-length` argument of all three constructors cap
string field values, condition messages and the log message. A longer string keeps its head and its tail, with a
marker between them that says how many characters were cut:

```lisp
(let ((bark:*max-string-length* 8))
  (bark:info "result" :body (format nil "HEAD~aTAIL" (make-string 1000 :initial-element #\x))))
;; => {"level":"info","ts":...,"body":"HEAD...[1000 chars cut]...TAIL","msg":"result"}
```

The kept characters number the limit, the head getting one more for an odd limit; the marker comes on top. The cut is
made while the string is written, so the string is not copied. In JSON a string inside a collection is cut too; in
logfmt a cut string is always quoted, because the marker holds spaces. Keys, type names and stack frames are not cut,
and no limit applies to a whole line.

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

`make-json-formatter` and `make-pretty-formatter` also take `:max-stack-frames`, for one logger only (see
[Limits per formatter](#limits-per-formatter)).
