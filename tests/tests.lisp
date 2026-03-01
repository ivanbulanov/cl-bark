;;; tests/tests.lisp — cl-bark tests using FiveAM

(defpackage #:bark-tests
  (:use #:cl)
  (:import-from #:bark
   ;; Level constants and helpers
   #:+trace+ #:+debug+ #:+info+ #:+warn+ #:+error+ #:+fatal+
   #:level-from-keyword #:level-name
   ;; Struct accessors
   #:logger-p #:logger-name #:logger-level #:logger-formatter
   #:logger-output #:logger-chindings #:logger-raw-bindings #:logger-sampler
   #:logger-trace-fn #:logger-debug-fn #:logger-info-fn
   #:logger-warn-fn #:logger-error-fn #:logger-fatal-fn
   ;; JSON/serialization internals
   #:emit-value #:emit-fields #:emit-key
   #:write-json-escaped-string #:serialize-bindings
   ;; Async output internals
   #:make-async-output #:stop-async-output #:flush-async-output
   ;; Utilities
   #:noop #:make-list-collector
   ;; Public API (non-conflicting)
   #:make-logger #:child #:set-level #:set-sampling #:start #:stop
   #:json-formatter #:logfmt-formatter #:pretty-formatter
   #:with-captured-logs #:with-context
   #:*logger* #:*log-context*))

(in-package #:bark-tests)

(5am:def-suite bark-tests
  :description "Comprehensive test suite for the cl-bark logging library.")

(5am:in-suite bark-tests)

;;; --- Levels ---

(5am:test test-level-constants
  "Verify all level constant values."
  (5am:is (= 10 +trace+))
  (5am:is (= 20 +debug+))
  (5am:is (= 30 +info+))
  (5am:is (= 40 +warn+))
  (5am:is (= 50 +error+))
  (5am:is (= 60 +fatal+)))

(5am:test test-level-from-keyword
  "Test level-from-keyword for all keywords and invalid input."
  (5am:is (= 10 (level-from-keyword :trace)))
  (5am:is (= 20 (level-from-keyword :debug)))
  (5am:is (= 30 (level-from-keyword :info)))
  (5am:is (= 40 (level-from-keyword :warn)))
  (5am:is (= 50 (level-from-keyword :error)))
  (5am:is (= 60 (level-from-keyword :fatal)))
  (5am:signals cl:error (level-from-keyword :bogus)))

(5am:test test-level-name
  "Test level-name returns correct strings for all levels."
  (5am:is (string= "trace" (level-name +trace+)))
  (5am:is (string= "debug" (level-name +debug+)))
  (5am:is (string= "info" (level-name +info+)))
  (5am:is (string= "warn" (level-name +warn+)))
  (5am:is (string= "error" (level-name +error+)))
  (5am:is (string= "fatal" (level-name +fatal+)))
  (5am:is (string= "unknown" (level-name 99))))

;;; --- JSON Utilities ---

(5am:test test-json-escape-basic
  "Test write-json-escaped-string with a normal string."
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "hello world" s))))
    (5am:is (string= "hello world" result))))

(5am:test test-json-escape-special-chars
  "Test escaping of quotes, backslashes, newlines, returns, tabs, control chars."
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "he said \"hi\"" s))))
    (5am:is-true (search "\\\"" result)))
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string "back\\slash" s))))
    (5am:is-true (search "\\\\" result)))
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string (format nil "line1~%line2") s))))
    (5am:is-true (search "\\n" result)))
  (let ((result (with-output-to-string (s)
                  (write-json-escaped-string (format nil "col1~ccol2" #\Tab) s))))
    (5am:is-true (search "\\t" result))))

(5am:test test-emit-value-types
  "Test emit-value for string, integer, float, boolean, null, symbol, vector."
  (let ((r (with-output-to-string (s) (emit-value s "hello"))))
    (5am:is (string= "\"hello\"" r)))
  (let ((r (with-output-to-string (s) (emit-value s 42))))
    (5am:is (string= "42" r)))
  (let ((r (with-output-to-string (s) (emit-value s 3.14))))
    (5am:is-true (search "3.14" r)))
  (let ((r (with-output-to-string (s) (emit-value s t))))
    (5am:is (string= "true" r)))
  (let ((r (with-output-to-string (s) (emit-value s nil))))
    (5am:is (string= "null" r)))
  (let ((r (with-output-to-string (s) (emit-value s :foo))))
    (5am:is-true (search "foo" (string-downcase r))))
  (let ((r (with-output-to-string (s) (emit-value s #(1 2 3)))))
    (5am:is-true (search "1" r))
    (5am:is-true (search "2" r))
    (5am:is-true (search "3" r))))

(5am:test test-emit-fields-plist
  "Test emit-fields with a plist."
  (let ((r (with-output-to-string (s)
             (emit-fields s (list :name "foo" :count 42)))))
    (5am:is-true (search "name" r))
    (5am:is-true (search "foo" r))
    (5am:is-true (search "count" r))
    (5am:is-true (search "42" r))))

(5am:test test-serialize-bindings
  "Test serialize-bindings produces a correct JSON fragment."
  (let ((r (serialize-bindings (list :service "web" :version 2))))
    (5am:is-true (stringp r))
    (5am:is-true (search "service" r))
    (5am:is-true (search "web" r))
    (5am:is-true (search "version" r))
    (5am:is-true (search "2" r))))

;;; --- Logger ---

(5am:test test-make-logger
  "Create a logger with make-logger, verify name, level, formatter."
  (let ((lgr (make-logger :name "myapp" :level :debug :formatter #'json-formatter)))
    (5am:is-true (logger-p lgr))
    (5am:is (string= "myapp" (logger-name lgr)))
    (5am:is (= +debug+ (logger-level lgr)))
    (5am:is (eq #'json-formatter (logger-formatter lgr)))))

(5am:test test-set-level-noop
  "Create a logger at :info, verify trace-fn and debug-fn are noop but info-fn is not."
  (let ((lgr (make-logger :level :info)))
    (5am:is (eq #'noop (logger-trace-fn lgr)))
    (5am:is (eq #'noop (logger-debug-fn lgr)))
    (5am:is-false (eq #'noop (logger-info-fn lgr)))
    (5am:is-false (eq #'noop (logger-warn-fn lgr)))
    (5am:is-false (eq #'noop (logger-error-fn lgr)))
    (5am:is-false (eq #'noop (logger-fatal-fn lgr)))))

(5am:test test-set-level-all-enabled
  "Set level to :trace, verify no function slots are noop."
  (let ((lgr (make-logger :level :trace)))
    (5am:is-false (eq #'noop (logger-trace-fn lgr)))
    (5am:is-false (eq #'noop (logger-debug-fn lgr)))
    (5am:is-false (eq #'noop (logger-info-fn lgr)))
    (5am:is-false (eq #'noop (logger-warn-fn lgr)))
    (5am:is-false (eq #'noop (logger-error-fn lgr)))
    (5am:is-false (eq #'noop (logger-fatal-fn lgr)))))

(5am:test test-set-level-all-disabled
  "Set level very high, verify all function slots are noop."
  (let ((lgr (make-logger :level 70)))
    (5am:is (eq #'noop (logger-trace-fn lgr)))
    (5am:is (eq #'noop (logger-debug-fn lgr)))
    (5am:is (eq #'noop (logger-info-fn lgr)))
    (5am:is (eq #'noop (logger-warn-fn lgr)))
    (5am:is (eq #'noop (logger-error-fn lgr)))
    (5am:is (eq #'noop (logger-fatal-fn lgr)))))

(5am:test test-child-logger
  "Create parent with chindings, create child with more bindings, verify concatenation."
  (let* ((parent (make-logger :name "parent" :level :trace))
         (parent-with-bindings (child parent :service "web"))
         (ch (child parent-with-bindings :request-id "abc")))
    (5am:is-true (search "service" (logger-chindings ch)))
    (5am:is-true (search "web" (logger-chindings ch)))
    (5am:is-true (search "request-id" (logger-chindings ch)))
    (5am:is-true (search "abc" (logger-chindings ch)))
    (5am:is (eq (logger-formatter parent-with-bindings) (logger-formatter ch)))
    (5am:is (eq (logger-output parent-with-bindings) (logger-output ch)))))

(5am:test test-child-raw-bindings
  "Create parent with raw-bindings, create child, verify raw-bindings are appended."
  (let* ((parent (make-logger :name "parent" :level :trace))
         (p1 (child parent :a 1 :b 2))
         (ch (child p1 :c 3)))
    (let ((rb (logger-raw-bindings ch)))
      (5am:is-true (not (null rb)))
      (5am:is (= 1 (getf rb :a)))
      (5am:is (= 2 (getf rb :b)))
      (5am:is (= 3 (getf rb :c))))))

(5am:test test-named-logger-json
  "Verify logger name appears in JSON output."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((*logger* (make-logger :name "myapp" :level :info
                                  :formatter #'json-formatter
                                  :output collector)))
      (bark:info "hello")
      (let ((line (first (funcall results-fn))))
        (5am:is-true (search "\"name\":\"myapp\"" line))))))

;;; --- Formatters ---

(5am:test test-json-formatter-basic
  "Use json-formatter directly, verify output has level, ts, msg keys."
  (let ((output (json-formatter +info+ "" nil nil "hello world" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search "\"level\"" output))
    (5am:is-true (search "\"ts\"" output))
    (5am:is-true (search "\"msg\"" output))
    (5am:is-true (search "hello world" output))
    (5am:is-true (search "30" output))))

(5am:test test-json-formatter-with-fields
  "Test json-formatter with per-call fields."
  (let ((output (json-formatter +warn+ "" nil nil "oops" (list :code 404 :path "/api"))))
    (5am:is-true (search "code" output))
    (5am:is-true (search "404" output))
    (5am:is-true (search "path" output))
    (5am:is-true (search "/api" output))))

(5am:test test-json-formatter-with-context
  "Test json-formatter with context alist."
  (let ((output (json-formatter +info+ "" nil '((:request-id . "xyz")) "ctx test" nil)))
    (5am:is-true (search "request-id" output))
    (5am:is-true (search "xyz" output))))

(5am:test test-json-formatter-with-chindings
  "Test json-formatter with pre-serialized chindings."
  (let* ((chd (serialize-bindings (list :service "api" :version 3)))
         (output (json-formatter +debug+ chd nil nil "chinding test" nil)))
    (5am:is-true (search "service" output))
    (5am:is-true (search "api" output))
    (5am:is-true (search "version" output))
    (5am:is-true (search "3" output))))

(5am:test test-logfmt-formatter-basic
  "Test logfmt-formatter, verify output format."
  (let ((output (logfmt-formatter +info+ "" nil nil "hello" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search "level=info" output))
    (5am:is-true (search "ts=" output))
    (5am:is-true (search "msg=" output))
    (5am:is-true (search "hello" output))))

(5am:test test-logfmt-formatter-with-fields
  "Test logfmt with fields, verify key=value pairs."
  (let ((output (logfmt-formatter +warn+ "" nil nil "warning" (list :code 500 :path "/err"))))
    (5am:is-true (search "code=500" output))
    (5am:is-true (search "path=" output))
    (5am:is-true (search "/err" output))))

(5am:test test-pretty-formatter-basic
  "Test pretty-formatter produces output with ANSI escape codes."
  (let ((output (pretty-formatter +info+ "" nil nil "pretty test" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search (string #\Esc) output))
    (5am:is-true (search "pretty test" output))))

;;; --- Context & Integration ---

(5am:test test-with-context
  "Use with-captured-logs and with-context, verify context fields appear in JSON."
  (with-captured-logs (get-logs)
    (with-context (:request-id "req-123")
      (bark:info "ctx message"))
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (5am:is-true (not (null line)))
      (5am:is-true (search "request-id" line))
      (5am:is-true (search "req-123" line)))))

(5am:test test-nested-context
  "Nest two with-context blocks, verify both sets of fields appear."
  (with-captured-logs (get-logs)
    (with-context (:outer "a")
      (with-context (:inner "b")
        (bark:info "nested")))
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (5am:is-true (not (null line)))
      (5am:is-true (search "outer" line))
      (5am:is-true (search "a" line))
      (5am:is-true (search "inner" line))
      (5am:is-true (search "b" line)))))

(5am:test test-with-captured-logs
  "Verify with-captured-logs captures log lines as a list."
  (with-captured-logs (get-logs)
    (bark:info "line1")
    (bark:warn "line2")
    (let ((logs (funcall get-logs)))
      (5am:is (= 2 (length logs)))
      (5am:is-true (search "line1" (first logs)))
      (5am:is-true (search "line2" (second logs))))))

(5am:test test-level-filtering
  "Set level to :info, log at trace/debug/info/warn, verify only info and warn captured."
  (with-captured-logs (get-logs)
    (set-level *logger* :info)
    (bark:trace "t-msg")
    (bark:debug "d-msg")
    (bark:info "i-msg")
    (bark:warn "w-msg")
    (let ((logs (funcall get-logs)))
      (5am:is (= 2 (length logs)))
      (5am:is-true (search "i-msg" (first logs)))
      (5am:is-true (search "w-msg" (second logs))))))

(5am:test test-end-to-end
  "Full flow: create logger, set level, log with context + child + fields."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let* ((lgr (make-logger :name "e2e" :level :trace :output collector))
           (ch (child lgr :service "api")))
      (let ((*log-context* (list (cons :trace-id "t-999"))))
        (funcall (logger-info-fn ch) ch "request handled" :status 200 :duration 42))
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (5am:is (= 1 (length logs)))
        (5am:is-true (search "service" line))
        (5am:is-true (search "api" line))
        (5am:is-true (search "trace-id" line))
        (5am:is-true (search "t-999" line))
        (5am:is-true (search "status" line))
        (5am:is-true (search "200" line))
        (5am:is-true (search "request handled" line))))))

;;; --- Sampling ---

(5am:test test-set-sampling
  "Set sampling, verify sampler array is populated."
  (let ((lgr (make-logger :level :trace)))
    (5am:is-true (null (logger-sampler lgr)))
    (set-sampling lgr :debug 5)
    (5am:is-true (not (null (logger-sampler lgr))))
    (let ((entry (aref (logger-sampler lgr) 2)))
      (5am:is-true (consp entry))
      (5am:is (= 5 (car entry))))))

(5am:test test-sampling-filters
  "Set sampling rate=2 on debug, log 10 debug messages, verify every other one passes."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :name "samp" :level :debug :output collector)))
      (set-sampling lgr :debug 2)
      (dotimes (i 10)
        (funcall (logger-debug-fn lgr) lgr (format nil "msg-~d" i)))
      (let ((logs (funcall results-fn)))
        (5am:is (= 5 (length logs)))))))

;;; --- Async Output ---

(fiveam:test test-async-output-basic
  "Create an async-output to a string stream, send messages, stop, verify stream contents."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (bark::ring-buffer-push (bark::async-output-ring ao) "hello")
    (bark::ring-buffer-push (bark::async-output-ring ao) "world")
    (sb-thread:signal-semaphore (bark::async-output-notify ao))
    (bark::flush-async-output ao)
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (search "hello" result))
      (fiveam:is (search "world" result)))))
(5am:test test-list-collector
  "Test make-list-collector, push items, get-results."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (funcall collector "first")
    (funcall collector "second")
    (funcall collector "third")
    (let ((results (funcall results-fn)))
      (5am:is (= 3 (length results)))
      (5am:is (string= "first" (first results)))
      (5am:is (string= "second" (second results)))
      (5am:is (string= "third" (third results))))))

(fiveam:test test-flush-async-output
  "Verify flush-async-output blocks until queue is drained."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (dotimes (i 5)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "line-~d" i)))
    (sb-thread:signal-semaphore (bark::async-output-notify ao))
    (bark::flush-async-output ao)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (= 5 (count #\Newline result))))
    (bark::stop-async-output ao)))
;;; --- Helpers ---

(defun log-at (logger-level msg-level &optional (fmt #'bark:json-formatter))
  "Create a logger at LOGGER-LEVEL, fire one message at MSG-LEVEL, return output string."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level logger-level :formatter fmt :output out)))
      (let ((fn (funcall (ecase msg-level
                           (:trace #'bark::logger-trace-fn)
                           (:debug #'bark::logger-debug-fn)
                           (:info  #'bark::logger-info-fn)
                           (:warn  #'bark::logger-warn-fn)
                           (:error #'bark::logger-error-fn)
                           (:fatal #'bark::logger-fatal-fn))
                         l)))
        (funcall fn l "test")))
    (get-output-stream-string out)))

(defun log-to-string (level &optional (formatter #'bark:json-formatter))
  "Log one message at LEVEL with FORMATTER, return output string."
  (log-at level level formatter))

;;; --- JSON Level Numbers ---

(5am:test test-json-level-numbers
  "All 6 levels emit the correct numeric level code in JSON output."
  (loop for (kw expected) in '((:trace 10) (:debug 20) (:info 30)
                                (:warn 40) (:error 50) (:fatal 60))
        do (let* ((line (log-to-string kw #'bark:json-formatter))
                  (level (gethash "level" (yason:parse line))))
             (5am:is (= expected level)))))

;;; --- Level Filtering (threshold matrix) ---

(5am:test test-level-filtering-thresholds
  "Messages below the logger's threshold are dropped; at/above it are emitted."
  (loop for (threshold silent loud)
        in '((:warn  (:trace :debug :info)       (:warn :error :fatal))
             (:info  (:trace :debug)             (:info :warn :error :fatal))
             (:error (:trace :debug :info :warn) (:error :fatal)))
        do (dolist (kw silent)
             (5am:is (string= "" (log-at threshold kw))))
           (dolist (kw loud)
             (5am:is-true (plusp (length (log-at threshold kw)))))))

;;; --- Formatter Coverage ---

(5am:test test-formatters
  "All three formatters produce non-empty, format-appropriate output."
  ;; JSON: must be valid JSON with level/ts/msg keys
  (let* ((s (log-at :info :info #'bark:json-formatter))
         (p (yason:parse s)))
    (5am:is-true (hash-table-p p))
    (5am:is-true (integerp (gethash "level" p)))
    (5am:is-true (integerp (gethash "ts"    p)))
    (5am:is-true (stringp  (gethash "msg"   p))))
  ;; Logfmt: key=value structure, contains level= and msg=
  (let ((s (log-at :info :info #'bark:logfmt-formatter)))
    (5am:is-true (search "level=info" s))
    (5am:is-true (search "msg="       s))
    (5am:is-true (search "ts="        s)))
  ;; Pretty: contains ANSI escape codes and the message text
  (let ((s (log-at :info :info #'bark:pretty-formatter)))
    (5am:is-true (search (string #\Escape) s))
    (5am:is-true (search "test" s))))

;;; --- Context Scoping ---

(5am:test test-with-context-scoping
  "WITH-CONTEXT injects fields within its dynamic scope and does not leak."
  (bark:with-captured-logs (logs)
    (bark:with-context (:svc "api" :ver "1")
      (bark:info "outer")
      (bark:with-context (:user 42)
        (bark:info "inner")))
    (bark:info "outside")
    (let* ((entries (mapcar #'yason:parse (funcall logs)))
           (outer   (first entries))
           (inner   (second entries))
           (outside (third entries)))
      ;; outer: has svc/ver, no user
      (5am:is (equal "api" (gethash "svc" outer)))
      (5am:is (equal "1"   (gethash "ver" outer)))
      (5am:is-false (gethash "user" outer))
      ;; inner: has all three
      (5am:is (equal "api" (gethash "svc"  inner)))
      (5am:is (= 42        (gethash "user" inner)))
      ;; outside: no context at all
      (5am:is-false (gethash "svc"  outside))
      (5am:is-false (gethash "user" outside)))))

;;; --- Child Logger Fields ---

(5am:test test-child-logger-fields
  "CHILD logger pre-attaches fields to every message it emits."
  (bark:with-captured-logs (logs)
    (let ((child (bark:child bark:*logger* :component "db" :pool 5)))
      (bark:info "parent msg")
      (funcall (bark::logger-info-fn child) child "child msg" :query "SELECT 1"))
    (let* ((entries (mapcar #'yason:parse (funcall logs)))
           (parent  (first entries))
           (child   (second entries)))
      ;; Parent has no child fields
      (5am:is-false (gethash "component" parent))
      ;; Child carries pre-attached bindings
      (5am:is (equal "db" (gethash "component" child)))
      (5am:is (= 5        (gethash "pool"      child)))
      ;; Child also carries call-site fields
      (5am:is (equal "SELECT 1" (gethash "query" child))))))

;;; --- Dynamic Level Changes ---

(5am:test test-set-level-dynamic
  "SET-LEVEL swaps fn slots so level changes take effect immediately."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level :trace :formatter #'bark:json-formatter :output out)))
      ;; At :trace - debug fires
      (funcall (bark::logger-debug-fn l) l "should-emit")
      (bark:set-level l :error)
      ;; After raising to :error - debug is now noop
      (funcall (bark::logger-debug-fn l) l "should-suppress")
      (funcall (bark::logger-error-fn l) l "should-emit-again"))
    (let ((lines (remove "" (uiop:split-string (get-output-stream-string out)
                                               :separator '(#\Newline))
                         :test #'equal)))
      (5am:is (= 2 (length lines)))
      (5am:is-true (search "should-emit"       (first  lines)))
      (5am:is-true (search "should-emit-again" (second lines))))))

;;; --- Async Output Integration ---

(fiveam:test test-async-output-integration
  "START creates an async-backed logger; STOP flushes all pending messages."
  (let ((out (make-string-output-stream)))
    (bark:start :stream out :level :info :capacity 64)
    (bark:info "integration-test-msg")
    (bark:stop)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (search "integration-test-msg" result)))))
;;; --- JSON String Escaping ---

(5am:test test-json-string-escaping-roundtrip
  "JSON formatter properly escapes quotes, backslashes, and control chars in strings."
  (bark:with-captured-logs (logs)
    (bark:info "escaping"
                   :quote  "say \"hello\""
                   :slash  "back\\slash"
                   :tab    (format nil "has~Ctab" #\Tab)
                   :nl     (format nil "line~%two"))
    (let ((raw (first (funcall logs))))
      ;; Raw JSON should contain escaped sequences
      (5am:is-true (search "\\\"hello\\\"" raw))
      (5am:is-true (search "back\\\\slash" raw))
      ;; Must be single-line (newline-delimited transport requirement)
      (5am:is-false (find #\Newline raw)))))

;;; --- Logfmt Quoting ---

(5am:test test-logfmt-quoting-rules
  "Logfmt formatter quotes values containing spaces; bare values are unquoted."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level :info :formatter #'bark:logfmt-formatter :output out)))
      (funcall (bark::logger-info-fn l) l "msg"
               :bare  "simple"
               :space "has spaces"
               :num   42
               :url   "http://x.com/p?q=a b"))
    (let ((s (get-output-stream-string out)))
      (5am:is-true (search "bare=simple"          s))
      (5am:is-true (search "space=\"has spaces\"" s))
      (5am:is-true (search "num=42"               s))
      (5am:is-true (search "url=\"http://"        s)))))

;;; --- JSON Value Types ---

(5am:test test-json-value-types-roundtrip
  "JSON formatter correctly encodes all supported value types."
  (bark:with-captured-logs (logs)
    (bark:info "types"
                   :str   "hello"
                   :int   42
                   :float 3.14
                   :true  t
                   :null  nil
                   :sym   :keyword
                   :vec   (vector 1 2 3)
                   :obj   (let ((h (make-hash-table :test 'equal)))
                            (setf (gethash "k" h) "v") h))
    (let ((p (yason:parse (first (funcall logs)))))
      (5am:is (equal "hello"   (gethash "str"   p)))
      (5am:is (= 42            (gethash "int"   p)))
      (5am:is-true  (floatp    (gethash "float" p)))
      ;; yason:parse returns CL T for JSON true
      (5am:is (eq t (gethash "true" p)))
      (5am:is-false  (gethash "null" p))
      (5am:is (equal "keyword" (gethash "sym"   p)))
      (5am:is-true (listp      (gethash "vec"  p)))
      (5am:is-true (hash-table-p (gethash "obj" p))))))

;;; --- Sampling Rate ---

(5am:test test-sampling-rate
  "SET-SAMPLING passes ~1/N messages at the given level; unsampled levels unaffected."
  (bark:with-captured-logs (logs)
    (let ((l bark:*logger*))
      (bark:set-sampling l :debug 10)
      (let ((dfn (bark::logger-debug-fn l))
            (ifn (bark::logger-info-fn  l)))
        ;; 1000 debug messages at 1-in-10 → expect ~100, tolerance 50-150
        (dotimes (i 1000) (funcall dfn l "throttled-msg" :i i))
        ;; 100 info messages, no sampling → expect exactly 100
        (dotimes (i 100)  (funcall ifn l "full-rate-msg" :i i))))
    (let* ((all       (funcall logs))
           (throttled (count "throttled-msg" all :test (lambda (k s) (search k s))))
           (full-rate (count "full-rate-msg" all :test (lambda (k s) (search k s)))))
      (5am:is (= 100 full-rate))
      (5am:is-true (<= 50 throttled 150)))))

(fiveam:test (test-with-captured-logs-formatter :compile-at :definition-time)
  "WITH-CAPTURED-LOGS accepts an optional formatter argument."
  ;; Default still uses json
  (bark:with-captured-logs (logs)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (fiveam:is (search "\"level\"" line))))
  ;; Explicit logfmt
  (bark:with-captured-logs (logs #'bark:logfmt-formatter)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (fiveam:is (search "level=info" line))))
  ;; Explicit pretty
  (bark:with-captured-logs (logs #'bark:pretty-formatter)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (fiveam:is (search "INFO" line))
      ;; pretty formatter should NOT have JSON structure
      (fiveam:is (not (search "\"level\"" line))))))

(fiveam:test (test-convenience-macros :compile-at :definition-time)
  "BARK:TRACE through BARK:FATAL expand to the correct level funcalls."
  (bark:with-captured-logs (logs)
    (bark:trace "t")
    (bark:debug "d")
    (bark:info "i")
    (bark:warn "w")
    (bark:error "e")
    (bark:fatal "f")
    (let ((lines (funcall logs)))
      (fiveam:is (= 6 (length lines)))
      ;; Verify each level number in order
      (fiveam:is (search "\"level\":10" (nth 0 lines)))
      (fiveam:is (search "\"level\":20" (nth 1 lines)))
      (fiveam:is (search "\"level\":30" (nth 2 lines)))
      (fiveam:is (search "\"level\":40" (nth 3 lines)))
      (fiveam:is (search "\"level\":50" (nth 4 lines)))
      (fiveam:is (search "\"level\":60" (nth 5 lines))))))

(fiveam:test (test-macros-with-fields :compile-at :definition-time)
  "Convenience macros pass per-call fields through to the formatter."
  (bark:with-captured-logs (logs)
    (bark:info "request" :method "GET" :path "/api")
    (let ((line (first (funcall logs))))
      (fiveam:is (search "\"method\":\"GET\"" line))
      (fiveam:is (search "\"path\":\"/api\"" line)))))

(fiveam:test test-ring-buffer-basic
  "Push and pop values from a ring buffer."
  (let ((rb (bark::make-ring-buffer 16)))
    (fiveam:is (bark::ring-buffer-push rb "a"))
    (fiveam:is (bark::ring-buffer-push rb "b"))
    (fiveam:is (string= "a" (bark::ring-buffer-pop rb)))
    (fiveam:is (string= "b" (bark::ring-buffer-pop rb)))
    (fiveam:is (null (bark::ring-buffer-pop rb)))))

(fiveam:test test-ring-buffer-drop-on-full
  "Ring buffer drops messages and increments counter when full."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 16) (bark::ring-buffer-push rb (format nil "msg-~d" i)))
    (fiveam:is (= 0 (bark::ring-buffer-dropped rb)))
    (fiveam:is (null (bark::ring-buffer-push rb "overflow")))
    (fiveam:is (= 1 (bark::ring-buffer-dropped rb)))
    (bark::ring-buffer-pop rb)
    (fiveam:is (bark::ring-buffer-push rb "recovered"))))

(fiveam:test test-ring-buffer-drain
  "Drain returns all available values."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 5) (bark::ring-buffer-push rb (format nil "~d" i)))
    (let ((items (bark::ring-buffer-drain rb)))
      (fiveam:is (= 5 (length items)))
      (fiveam:is (string= "0" (first items)))
      (fiveam:is (string= "4" (fifth items))))))

(fiveam:test test-ring-buffer-mpsc
  "Multiple producer threads can push without data loss."
  (let ((rb (bark::make-ring-buffer 1024))
        (threads nil))
    (dotimes (tid 4)
      (push (bt:make-thread
             (lambda ()
               (dotimes (i 100)
                 (bark::ring-buffer-push rb (format nil "t~d-~d" tid i))))
             :name (format nil "pusher-~d" tid))
            threads))
    (dolist (th threads) (bt:join-thread th))
    (let ((items (bark::ring-buffer-drain rb)))
      (fiveam:is (= 400 (length items)))
      (fiveam:is (= 0 (bark::ring-buffer-dropped rb))))))

(fiveam:test test-async-drop-warning
  "When the ring buffer overflows, a drop warning appears in the output."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 5)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (sb-thread:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (search "dropped 5 log messages" result)))))

(fiveam:test test-async-custom-on-drop
  "Custom on-drop callback controls the drop warning message."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16
               :on-drop (lambda (n) (format nil "LOST:~d" n)))))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 3)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (sb-thread:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (search "LOST:3" result)))))

(fiveam:test test-async-on-drop-nil-suppresses
  "on-drop returning NIL suppresses the warning line."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16
               :on-drop (lambda (n) (declare (ignore n)) nil))))
    (dotimes (i 20)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (sb-thread:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (fiveam:is (not (search "dropped" result))))))
