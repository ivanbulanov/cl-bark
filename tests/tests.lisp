;;; tests/tests.lisp — Test definitions (auto-generated)

(funhouse.test:deftest test-async-output-basic ()
  "Create an async-output to a string stream, send messages, stop, verify stream contents."
  (let* ((stream (make-string-output-stream))
         (ao (make-async-output stream)))
    (sb-concurrency:send-message (async-output-mailbox ao) "hello async")
    (sb-concurrency:send-message (async-output-mailbox ao) "second line")
    ;; Give writer thread time to drain before stopping
    (sleep 0.2)
    (stop-async-output ao)
    (let ((result (get-output-stream-string stream)))
      (funhouse.test:assert-true (search "hello async" result))
      (funhouse.test:assert-true (search "second line" result)))))

(funhouse.test:deftest test-child-logger ()
  "Create parent with chindings, create child with more bindings, verify concatenation."
  (let* ((parent (make-logger :name "parent" :level :trace))
         ;; Give parent some chindings
         (parent-with-bindings (child parent :service "web"))
         ;; Create child with additional bindings
         (ch (child parent-with-bindings :request-id "abc")))
    ;; Child chindings should contain both
    (funhouse.test:assert-true (search "service" (logger-chindings ch)))
    (funhouse.test:assert-true (search "web" (logger-chindings ch)))
    (funhouse.test:assert-true (search "request-id" (logger-chindings ch)))
    (funhouse.test:assert-true (search "abc" (logger-chindings ch)))
    ;; Child inherits formatter and output
    (funhouse.test:assert-equal (logger-formatter parent-with-bindings) (logger-formatter ch))
    (funhouse.test:assert-equal (logger-output parent-with-bindings) (logger-output ch))))

(funhouse.test:deftest test-child-raw-bindings ()
  "Create parent with raw-bindings, create child, verify raw-bindings are appended."
  (let* ((parent (make-logger :name "parent" :level :trace))
         (p1 (child parent :a 1 :b 2))
         (ch (child p1 :c 3)))
    ;; raw-bindings should have all keys
    (let ((rb (logger-raw-bindings ch)))
      (funhouse.test:assert-true (not (null rb)))
      (funhouse.test:assert-equal 1 (getf rb :a))
      (funhouse.test:assert-equal 2 (getf rb :b))
      (funhouse.test:assert-equal 3 (getf rb :c)))))

(funhouse.test:deftest test-emit-fields-plist ()
  "Test emit-fields with a plist."
  (let ((r (with-output-to-string (s)
             (emit-fields s (list :name "foo" :count 42)))))
    (funhouse.test:assert-true (search "name" r))
    (funhouse.test:assert-true (search "foo" r))
    (funhouse.test:assert-true (search "count" r))
    (funhouse.test:assert-true (search "42" r))))

(funhouse.test:deftest test-emit-value-types ()
  "Test emit-value for string, integer, float, boolean, null, symbol, vector."
  ;; String
  (let ((r (with-output-to-string (s) (emit-value s "hello"))))
    (funhouse.test:assert-equal "\"hello\"" r))
  ;; Integer
  (let ((r (with-output-to-string (s) (emit-value s 42))))
    (funhouse.test:assert-equal "42" r))
  ;; Float
  (let ((r (with-output-to-string (s) (emit-value s 3.14))))
    (funhouse.test:assert-true (search "3.14" r)))
  ;; Boolean true (T)
  (let ((r (with-output-to-string (s) (emit-value s t))))
    (funhouse.test:assert-equal "true" r))
  ;; Null (nil)
  (let ((r (with-output-to-string (s) (emit-value s nil))))
    (funhouse.test:assert-equal "null" r))
  ;; Symbol
  (let ((r (with-output-to-string (s) (emit-value s :foo))))
    (funhouse.test:assert-true (search "foo" (string-downcase r))))
  ;; Vector
  (let ((r (with-output-to-string (s) (emit-value s #(1 2 3)))))
    (funhouse.test:assert-true (search "1" r))
    (funhouse.test:assert-true (search "2" r))
    (funhouse.test:assert-true (search "3" r))))

(funhouse.test:deftest test-end-to-end ()
  "Full flow: create logger, set level, log with context + child + fields."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let* ((lgr (make-logger :name "e2e" :level :trace :output collector))
           (ch (child lgr :service "api")))
      (let ((*log-context* (list (cons :trace-id "t-999"))))
        (funcall (logger-info-fn ch) ch "request handled" :status 200 :duration 42))
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (funhouse.test:assert-equal 1 (length logs))
        ;; chindings from child
        (funhouse.test:assert-true (search "service" line))
        (funhouse.test:assert-true (search "api" line))
        ;; context
        (funhouse.test:assert-true (search "trace-id" line))
        (funhouse.test:assert-true (search "t-999" line))
        ;; per-call fields
        (funhouse.test:assert-true (search "status" line))
        (funhouse.test:assert-true (search "200" line))
        ;; message
        (funhouse.test:assert-true (search "request handled" line))))))

(funhouse.test:deftest test-flush-async-output ()
  "Verify flush-async-output blocks until queue is drained."
  (let* ((stream (make-string-output-stream))
         (ao (make-async-output stream)))
    (sb-concurrency:send-message (async-output-mailbox ao) "line1")
    (flush-async-output ao)
    ;; After flush, data should be in the stream
    (let ((output (get-output-stream-string stream)))
      (funhouse.test:assert-true (search "line1" output)))
    (stop-async-output ao)))

(funhouse.test:deftest test-json-escape-basic ()
  "Test write-json-escaped-string with a normal string."
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "hello world" s))))
    (funhouse.test:assert-equal "hello world" result)))

(funhouse.test:deftest test-json-escape-special-chars ()
  "Test escaping of quotes, backslashes, newlines, returns, tabs, control chars."
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "he said \"hi\"" s))))
    (funhouse.test:assert-true (search "\\\"" result)))
  ;; Backslash
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "back\\slash" s))))
    (funhouse.test:assert-true (search "\\\\" result)))
  ;; Newline
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string (format nil "line1~%line2") s))))
    (funhouse.test:assert-true (search "\\n" result)))
  ;; Tab
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string (format nil "col1~ccol2" #\Tab) s))))
    (funhouse.test:assert-true (search "\\t" result))))

(funhouse.test:deftest test-json-formatter-basic ()
  "Use json-formatter directly, verify output has level, ts, msg keys."
  (let ((output (json-formatter +info+ "" nil nil "hello world" nil)))
    (funhouse.test:assert-true (stringp output))
    (funhouse.test:assert-true (search "\"level\"" output))
    (funhouse.test:assert-true (search "\"ts\"" output))
    (funhouse.test:assert-true (search "\"msg\"" output))
    (funhouse.test:assert-true (search "hello world" output))
    (funhouse.test:assert-true (search "30" output))))

(funhouse.test:deftest test-json-formatter-with-chindings ()
  "Test json-formatter with pre-serialized chindings."
  (let* ((chd (serialize-bindings (list :service "api" :version 3)))
         (output (json-formatter +debug+ chd nil nil "chinding test" nil)))
    (funhouse.test:assert-true (search "service" output))
    (funhouse.test:assert-true (search "api" output))
    (funhouse.test:assert-true (search "version" output))
    (funhouse.test:assert-true (search "3" output))))

(funhouse.test:deftest test-json-formatter-with-context ()
  "Test json-formatter with context alist."
  (let ((output (json-formatter +info+ "" nil '((:request-id . "xyz")) "ctx test" nil)))
    (funhouse.test:assert-true (search "request-id" output))
    (funhouse.test:assert-true (search "xyz" output))))

(funhouse.test:deftest test-json-formatter-with-fields ()
  "Test json-formatter with per-call fields."
  (let ((output (json-formatter +warn+ "" nil nil "oops" (list :code 404 :path "/api"))))
    (funhouse.test:assert-true (search "code" output))
    (funhouse.test:assert-true (search "404" output))
    (funhouse.test:assert-true (search "path" output))
    (funhouse.test:assert-true (search "/api" output))))

(funhouse.test:deftest test-level-constants ()
  "Verify all level constant values."
  (funhouse.test:assert-equal 10 +trace+)
  (funhouse.test:assert-equal 20 +debug+)
  (funhouse.test:assert-equal 30 +info+)
  (funhouse.test:assert-equal 40 +warn+)
  (funhouse.test:assert-equal 50 +error+)
  (funhouse.test:assert-equal 60 +fatal+))

(funhouse.test:deftest test-level-filtering ()
  "Use with-captured-logs, set level to :info, log at trace/debug/info/warn, verify only info and warn captured."
  (with-captured-logs (get-logs)
    (set-level *logger* :info)
    (funcall (logger-trace-fn *logger*) *logger* "t-msg")
    (funcall (logger-debug-fn *logger*) *logger* "d-msg")
    (funcall (logger-info-fn *logger*) *logger* "i-msg")
    (funcall (logger-warn-fn *logger*) *logger* "w-msg")
    (let ((logs (funcall get-logs)))
      (funhouse.test:assert-equal 2 (length logs))
      (funhouse.test:assert-true (search "i-msg" (first logs)))
      (funhouse.test:assert-true (search "w-msg" (second logs))))))

(funhouse.test:deftest test-level-from-keyword ()
  "Test level-from-keyword for all keywords and invalid input."
  (funhouse.test:assert-equal 10 (level-from-keyword :trace))
  (funhouse.test:assert-equal 20 (level-from-keyword :debug))
  (funhouse.test:assert-equal 30 (level-from-keyword :info))
  (funhouse.test:assert-equal 40 (level-from-keyword :warn))
  (funhouse.test:assert-equal 50 (level-from-keyword :error))
  (funhouse.test:assert-equal 60 (level-from-keyword :fatal))
  (let ((signaled nil))
    (handler-case (level-from-keyword :bogus)
      (cl:error () (setf signaled t)))
    (funhouse.test:assert-true signaled)))

(funhouse.test:deftest test-level-name ()
  "Test level-name returns correct strings for all levels."
  (funhouse.test:assert-equal "trace" (level-name +trace+))
  (funhouse.test:assert-equal "debug" (level-name +debug+))
  (funhouse.test:assert-equal "info" (level-name +info+))
  (funhouse.test:assert-equal "warn" (level-name +warn+))
  (funhouse.test:assert-equal "error" (level-name +error+))
  (funhouse.test:assert-equal "fatal" (level-name +fatal+))
  (funhouse.test:assert-equal "unknown" (level-name 99)))

(funhouse.test:deftest test-list-collector ()
  "Test make-list-collector, push items, get-results."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (funcall collector "first")
    (funcall collector "second")
    (funcall collector "third")
    (let ((results (funcall results-fn)))
      (funhouse.test:assert-equal 3 (length results))
      (funhouse.test:assert-equal "first" (first results))
      (funhouse.test:assert-equal "second" (second results))
      (funhouse.test:assert-equal "third" (third results)))))

(funhouse.test:deftest test-logfmt-formatter-basic ()
  "Test logfmt-formatter, verify output format."
  (let ((output (logfmt-formatter +info+ "" nil nil "hello" nil)))
    (funhouse.test:assert-true (stringp output))
    (funhouse.test:assert-true (search "level=info" output))
    (funhouse.test:assert-true (search "ts=" output))
    (funhouse.test:assert-true (search "msg=" output))
    (funhouse.test:assert-true (search "hello" output))))

(funhouse.test:deftest test-logfmt-formatter-with-fields ()
  "Test logfmt with fields, verify key=value pairs."
  (let ((output (logfmt-formatter +warn+ "" nil nil "warning" (list :code 500 :path "/err"))))
    (funhouse.test:assert-true (search "code=500" output))
    (funhouse.test:assert-true (search "path=" output))
    (funhouse.test:assert-true (search "/err" output))))

(funhouse.test:deftest test-make-logger ()
  "Create a logger with make-logger, verify name, level, formatter."
  (let ((lgr (make-logger :name "myapp" :level :debug :formatter #'json-formatter)))
    (funhouse.test:assert-true (logger-p lgr))
    (funhouse.test:assert-equal "myapp" (logger-name lgr))
    (funhouse.test:assert-equal +debug+ (logger-level lgr))
    (funhouse.test:assert-equal #'json-formatter (logger-formatter lgr))))

(funhouse.test:deftest test-named-logger-json ()
  "Verify logger name appears in JSON output."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((*logger* (make-logger :name "myapp" :level :info
                                  :formatter #'json-formatter
                                  :output collector)))
      (info "hello")
      (let ((line (first (funcall results-fn))))
        (funhouse.test:assert-true (search "\"name\":\"myapp\"" line))))))

(funhouse.test:deftest test-nested-context ()
  "Nest two with-context blocks, verify both sets of fields appear."
  (with-captured-logs (get-logs)
    (with-context (:outer "a")
      (with-context (:inner "b")
        (funcall (logger-info-fn *logger*) *logger* "nested")))
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (funhouse.test:assert-true (not (null line)))
      (funhouse.test:assert-true (search "outer" line))
      (funhouse.test:assert-true (search "a" line))
      (funhouse.test:assert-true (search "inner" line))
      (funhouse.test:assert-true (search "b" line)))))

(funhouse.test:deftest test-pretty-formatter-basic ()
  "Test pretty-formatter produces output with ANSI escape codes."
  (let ((output (pretty-formatter +info+ "" nil nil "pretty test" nil)))
    (funhouse.test:assert-true (stringp output))
    ;; ANSI escape starts with ESC [
    (funhouse.test:assert-true (search (string #\Esc) output))
    (funhouse.test:assert-true (search "pretty test" output))))

(funhouse.test:deftest test-sampling-filters ()
  "Set sampling rate=2 on debug, log 10 debug messages, verify every other one passes."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :name "samp" :level :debug :output collector)))
      (set-sampling lgr :debug 2)
      (dotimes (i 10)
        (funcall (logger-debug-fn lgr) lgr (format nil "msg-~d" i)))
      (let ((logs (funcall results-fn)))
        ;; With rate=2, mod counter: count starts at 0, increments before check.
        ;; So every other call passes (when mod=0). Expect 5 out of 10.
        (funhouse.test:assert-equal 5 (length logs))))))

(funhouse.test:deftest test-serialize-bindings ()
  "Test serialize-bindings produces a correct JSON fragment."
  (let ((r (serialize-bindings (list :service "web" :version 2))))
    (funhouse.test:assert-true (stringp r))
    (funhouse.test:assert-true (search "service" r))
    (funhouse.test:assert-true (search "web" r))
    (funhouse.test:assert-true (search "version" r))
    (funhouse.test:assert-true (search "2" r))))

(funhouse.test:deftest test-set-level-all-disabled ()
  "Set level very high, verify all function slots are noop."
  (let ((lgr (make-logger :level 70)))
    (funhouse.test:assert-equal #'noop (logger-trace-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-debug-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-info-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-warn-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-error-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-fatal-fn lgr))))

(funhouse.test:deftest test-set-level-all-enabled ()
  "Set level to :trace, verify no function slots are noop."
  (let ((lgr (make-logger :level :trace)))
    (funhouse.test:assert-true (not (eq #'noop (logger-trace-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-debug-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-info-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-warn-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-error-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-fatal-fn lgr))))))

(funhouse.test:deftest test-set-level-noop ()
  "Create a logger at :info, verify trace-fn and debug-fn are noop but info-fn is not."
  (let ((lgr (make-logger :level :info)))
    (funhouse.test:assert-equal #'noop (logger-trace-fn lgr))
    (funhouse.test:assert-equal #'noop (logger-debug-fn lgr))
    (funhouse.test:assert-true (not (eq #'noop (logger-info-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-warn-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-error-fn lgr))))
    (funhouse.test:assert-true (not (eq #'noop (logger-fatal-fn lgr))))))

(funhouse.test:deftest test-set-sampling ()
  "Set sampling, verify sampler array is populated."
  (let ((lgr (make-logger :level :trace)))
    (funhouse.test:assert-true (null (logger-sampler lgr)))
    (set-sampling lgr :debug 5)
    (funhouse.test:assert-true (not (null (logger-sampler lgr))))
    (let ((entry (aref (logger-sampler lgr) 2)))
      (funhouse.test:assert-true (consp entry))
      (funhouse.test:assert-equal 5 (car entry)))))

(funhouse.test:deftest test-with-captured-logs ()
  "Verify with-captured-logs captures log lines as a list."
  (with-captured-logs (get-logs)
    (funcall (logger-info-fn *logger*) *logger* "line1")
    (funcall (logger-warn-fn *logger*) *logger* "line2")
    (let ((logs (funcall get-logs)))
      (funhouse.test:assert-equal 2 (length logs))
      (funhouse.test:assert-true (search "line1" (first logs)))
      (funhouse.test:assert-true (search "line2" (second logs))))))

(funhouse.test:deftest test-with-context ()
  "Use with-captured-logs and with-context, verify context fields appear in JSON."
  (with-captured-logs (get-logs)
    (with-context (:request-id "req-123")
      (funcall (logger-info-fn *logger*) *logger* "ctx message"))
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (funhouse.test:assert-true (not (null line)))
      (funhouse.test:assert-true (search "request-id" line))
      (funhouse.test:assert-true (search "req-123" line)))))

;;; --- Test suites ---

(funhouse.test:deftest-suite bark-tests
  "Comprehensive test suite for the cl-bark logging library."
  (:tests
   ;; Group 1: Levels
   test-level-constants
   test-level-from-keyword
   test-level-name
   ;; Group 2: JSON Utilities
   test-json-escape-basic
   test-json-escape-special-chars
   test-emit-value-types
   test-emit-fields-plist
   test-serialize-bindings
   ;; Group 3: Logger
   test-make-logger
   test-set-level-noop
   test-set-level-all-enabled
   test-set-level-all-disabled
   test-child-logger
   test-child-raw-bindings
   test-named-logger-json
   ;; Group 4: Formatters
   test-json-formatter-basic
   test-json-formatter-with-fields
   test-json-formatter-with-context
   test-json-formatter-with-chindings
   test-logfmt-formatter-basic
   test-logfmt-formatter-with-fields
   test-pretty-formatter-basic
   ;; Group 5: Context & Integration
   test-with-context
   test-nested-context
   test-with-captured-logs
   test-level-filtering
   test-end-to-end
   ;; Group 6: Sampling
   test-set-sampling
   test-sampling-filters
   ;; Group 7: Async Output
   test-async-output-basic
   test-list-collector
   test-flush-async-output))
