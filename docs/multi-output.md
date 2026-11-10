# Multi-output

A tee output sends each log line to several destinations. Each destination has its own stream, formatter, filter, ring buffer and writer thread.

## `make-tee`

```lisp
(bark:make-tee destinations) -> tee-output
```

`destinations` is a list of plists, each with the keys:

- `:stream` (required): an output stream
- `:formatter`: a formatter struct (defaults to the built-in JSON formatter, equivalent to `(bark:make-json-formatter)`; create one with `bark:make-json-formatter`, `bark:make-logfmt-formatter`, `bark:make-pretty-formatter`, or `bark:make-formatter`)
- `:filter`: `(lambda (level fields) ...)` returning non-nil to pass, nil to skip. Receives the log level (integer) and per-call fields only, not static or dynamic context
- `:level`: a level keyword; shorthand for a filter that checks `(>= level threshold)`. Mutually exclusive with `:filter`
- `:capacity`: ring buffer size in messages for this destination (defaults to 8192; rounded up to next power of two, minimum 16)
- `:on-drop`: `(lambda (count) ...)` called when messages are dropped due to a full buffer. Returns a warning message string, or NIL to suppress. Can optionally return extra fields as a second value: `(values message fields)`. See [drop warnings](blocking-mode.md#drop-mode-and-drop-warnings) for the full return protocol. Defaults to a handler that writes one warning line through the same destination reporting how many messages were dropped
- `:on-error`: `(lambda (condition) ...)` called in the writer thread when a stream write fails. Return a new stream to swap and continue writing, or nil to stop the writer thread (subsequent log calls silently drop messages). The condition is the original `file-error` or `stream-error`; bark does not wrap it. When omitted, the writer logs to `*error-output*` and stops.
- `:blocking`, `:block-timeout`, `:on-block-timeout`: per-destination blocking mode; see [drop warnings](blocking-mode.md#drop-mode-and-drop-warnings)

`bark:stop` tears down all writer threads. Streams are not closed. The caller who opened them closes them.

## `tee` macro

```lisp
(bark:tee &rest destination-specs) -> tee-output
```

Syntax sugar over `make-tee`. Each destination spec has the form `(stream-expr &key formatter filter level capacity on-drop on-error blocking block-timeout on-block-timeout)`:

```lisp
(bark:tee
  ;; Fast local console, small buffer
  (*error-output*                       :formatter (bark:make-pretty-formatter)
                                        :capacity 1024)
  ;; Slow remote sink, large buffer, custom drop message
  ((open "/var/log/app.jsonl"
         :direction :output
         :if-exists :append)            :formatter (bark:make-json-formatter)
                                        :capacity 65536
                                        :on-drop (lambda (n) (format nil "lost ~d" n)))
  ;; Errors only
  ((open "/var/log/errors.jsonl"
         :direction :output
         :if-exists :append)            :formatter (bark:make-json-formatter)
                                        :level :error))
```

Specifying both `:level` and `:filter` in the same destination spec signals `bark-configuration-error`.

## Examples

### Mirror: console and file

Same events, different formats. The most common multi-output scenario.

```lisp
(defvar *log-file* (open "/var/log/app.jsonl"
                         :direction :output :if-exists :append
                         :if-does-not-exist :create))

(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter (bark:make-pretty-formatter))
                                 (*log-file*     :formatter (bark:make-json-formatter)))))

(bark:info "request handled" :status 200)
;; => pretty-printed to stderr
;; => JSON line to log file
```

### Level-based routing

All events to console, errors only to a separate file.

```lisp
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter (bark:make-pretty-formatter))
                                 (*error-file*   :formatter (bark:make-json-formatter)
                                                 :level :error))))

(bark:info "all good")           ; console only
(bark:error "disk full" :vol 3)  ; console + error file
```

### Content-based routing

Audit events to a dedicated stream based on a per-call field.

```lisp
(setf bark:*logger*
      (bark:make-logger :level :info
                        :context '(:name "myapp")
                        :output (bark:tee
                                 (*error-output* :formatter (bark:make-json-formatter))
                                 (*audit-file*   :formatter (bark:make-json-formatter)
                                                 :filter (lambda (level fields)
                                                           (declare (ignore level))
                                                           (getf fields :audit))))))

(bark:info "page loaded" :path "/home")                     ; console only
(bark:info "user login" :audit t :user-id 42 :method "sso") ; console + audit file
```

### Two independent loggers

Explicit logger arg bypasses `*logger*`. Each logger has its own output pipeline.

```lisp
(setf bark:*logger* (bark:make-logger :level :info :context '(:name "app")))

(defvar *audit-logger*
  (bark:make-logger :level :info
                    :context '(:name "audit")
                    :output (open "/var/log/audit.jsonl"
                                  :direction :output :if-exists :append)))

(bark:info "request handled" :status 200)              ; app logger via *logger*
(bark:info *audit-logger* "user login" :user-id 42)    ; audit logger (explicit)
```

## Error recovery

The `:on-error` handler receives the original stream condition (`file-error`, `stream-error`, etc.), bark passes it through without wrapping. The handler runs on the destination's writer thread, not the caller thread, a slow handler stalls the drain, causing the ring buffer to fill and drop messages (in the default non-blocking mode callers are never blocked; with `:blocking t` they wait up to `block-timeout`). Return a new stream to swap and continue, or nil to let the writer exit.

Reopen a log file on any error:

```lisp
(bark:tee
  (*error-output* :formatter (bark:make-pretty-formatter))
  ((open "/var/log/app.jsonl" :direction :output :if-exists :append)
   :formatter (bark:make-json-formatter)
   :on-error (lambda (condition)
               (declare (ignore condition))
               (open "/var/log/app.jsonl"
                     :direction :output :if-exists :append
                     :if-does-not-exist :create))))
```

Dispatch on condition type for different recovery strategies:

```lisp
:on-error (lambda (condition)
            (typecase condition
              (file-error (reopen-log-file))    ; disk full, file deleted
              (stream-error (fallback-stream))  ; broken pipe
              (t nil)))                         ; unknown, give up
```

## Diagrams

### Mirror with different formatters

```
                                 ┌─> pretty-formatter ──> [ring 1] ──> writer 1 ──> stderr
 bark:info ──> *logger* ──> tee─┤
                                 └─> json-formatter ──> [ring 2] ──> writer 2 ──> app.jsonl
```

### Shared formatter

Two destinations with the same formatter, formatted once, emitted to both.

```
                                 ┌──────────────────────> [ring 1] ──> writer 1 ──> app.jsonl
 bark:info ──> *logger* ──> tee─┤
                                 │  json-formatter
                                 │  (called once)
                                 └─> filter(>=error) ─?─> [ring 2] ──> writer 2 ──> errors.jsonl
```
