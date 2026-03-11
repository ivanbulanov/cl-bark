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
   #:emit-json-value #:emit-json-fields #:emit-json-key
   #:emit-logfmt-value #:emit-logfmt-key
   #:*max-emit-depth* #:*max-emit-length*
   #:write-json-escaped-string #:serialize-bindings
   ;; Async output internals
   #:make-async-output #:stop-async-output #:flush-async-output
   ;; Multi-output internals
   #:destination-p #:destination-async-output #:destination-formatter #:destination-filter
   #:formatter-group-formatter #:formatter-group-destinations
   #:tee-output-p #:tee-output-groups
   #:make-tee
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

(5am:test test-emit-json-value-types
  "Test emit-json-value for string, integer, float, boolean, null, symbol, vector."
  (let ((r (with-output-to-string (s) (emit-json-value s "hello"))))
    (5am:is (string= "\"hello\"" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s 42))))
    (5am:is (string= "42" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s 3.14))))
    (5am:is-true (search "3.14" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s t))))
    (5am:is (string= "true" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s nil))))
    (5am:is (string= "null" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s :foo))))
    (5am:is-true (search "foo" (string-downcase r))))
  (let ((r (with-output-to-string (s) (emit-json-value s #(1 2 3)))))
    (5am:is-true (search "1" r))
    (5am:is-true (search "2" r))
    (5am:is-true (search "3" r))))

(5am:test test-emit-json-fields-plist
  "Test emit-json-fields with a plist."
  (let ((r (with-output-to-string (s)
             (emit-json-fields s (list :name "foo" :count 42)))))
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

;;; --- JSON Value Serialization (new types) ---

(5am:test test-emit-json-value-character
  "Characters serialize as single-char JSON strings."
  (let ((r (with-output-to-string (s) (emit-json-value s #\a))))
    (5am:is (string= "\"a\"" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s #\Space))))
    (5am:is (string= "\" \"" r))))

(5am:test test-emit-json-value-ratio
  "Ratios coerce to double-float without d0 suffix."
  (let ((r (with-output-to-string (s) (emit-json-value s 1/3))))
    (5am:is-true (search "0.333" r))
    (5am:is-false (search "d0" r))
    (5am:is-false (search "D0" r))))

(5am:test test-emit-json-value-pathname
  "Pathnames serialize as quoted namestrings."
  (let ((r (with-output-to-string (s) (emit-json-value s #P"/var/log/app.log"))))
    (5am:is (string= "\"/var/log/app.log\"" r))))

(5am:test test-emit-json-value-cons
  "Proper lists serialize as JSON arrays."
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 3)))))
    (5am:is (string= "[1,2,3]" r)))
  ;; Nested list
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 (2 3))))))
    (5am:is (string= "[1,[2,3]]" r))))

(5am:test test-emit-json-value-dotted-pair
  "Dotted pairs serialize as JSON arrays with cdr appended."
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 . 2)))))
    (5am:is (string= "[1,2]" r)))
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 . 3)))))
    (5am:is (string= "[1,2,3]" r))))

(5am:test test-emit-json-value-hash-table-symbol-keys
  "Hash-tables with symbol keys produce lowercased string keys."
  (let ((h (make-hash-table)))
    (setf (gethash :name h) "alice")
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      (5am:is-true (search "\"name\":\"alice\"" r)))))

(5am:test test-emit-json-value-hash-table-pathname-keys
  "Hash-tables with pathname keys produce namestring keys."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash #P"/tmp/log" h) 42)
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      (5am:is-true (search "\"/tmp/log\":42" r)))))

(5am:test test-emit-json-value-hash-table-unsupported-keys
  "Hash-tables with unsupported key types produce type-name keys."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash 42 h) "the-answer")
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      ;; Integer key becomes type placeholder (type-of 42 is implementation-dependent)
      (5am:is-true (search "\"the-answer\"" r))
      ;; Key should not be "42" (raw number as string)
      (5am:is-false (string= "{\"42\":\"the-answer\"}" r)))))

(5am:test test-emit-json-value-fallback-placeholder
  "Unsupported types produce <type-name> placeholder."
  ;; Function
  (let ((r (with-output-to-string (s) (emit-json-value s #'car))))
    (5am:is-true (search "<" r))
    (5am:is-true (search ">" r))
    (5am:is (char= #\" (char r 0)))))

(5am:test test-emit-json-value-clos-placeholder
  "CLOS objects produce <class-name> placeholder."
  (let ((r (with-output-to-string (s)
             (emit-json-value s (make-condition 'simple-error
                                  :format-control "test"
                                  :format-arguments nil)))))
    (5am:is-true (search "<" r))))

;;; --- JSON Serialization Limits ---

(5am:test test-emit-json-value-depth-limit
  "Nested collections become placeholders at depth 0."
  ;; At depth 1, top-level list serializes but nested list becomes placeholder
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 (2 3)) 1))))
    (5am:is-true (search "1" r))
    (5am:is-true (search "<cons>" r)))
  ;; At depth 0, even top-level becomes placeholder
  (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 3) 0))))
    (5am:is-true (search "<cons>" r))))

(5am:test test-emit-json-value-length-limit-cons
  "Lists longer than *max-emit-length* are truncated with ellipsis."
  (let ((bark:*max-emit-length* 3))
    (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 3 4 5)))))
      (5am:is (string= "[1,2,3,\"...\"]" r)))))

(5am:test test-emit-json-value-length-limit-vector
  "Vectors longer than *max-emit-length* are truncated with ellipsis."
  (let ((bark:*max-emit-length* 2))
    (let ((r (with-output-to-string (s) (emit-json-value s #(10 20 30 40)))))
      (5am:is (string= "[10,20,\"...\"]" r)))))

(5am:test test-emit-json-value-length-limit-hash-table
  "Hash-tables larger than *max-emit-length* are truncated."
  (let ((bark:*max-emit-length* 1)
        (h (make-hash-table :test 'equal)))
    (setf (gethash "a" h) 1 (gethash "b" h) 2 (gethash "c" h) 3)
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      (5am:is-true (search "\"...\":\"...\"" r)))))

(5am:test test-emit-json-value-depth-and-length
  "Depth and length limits compose correctly."
  (let ((bark:*max-emit-length* 2))
    ;; depth=2: top list OK, nested list OK, doubly-nested → placeholder
    (let ((r (with-output-to-string (s) (emit-json-value s '((1 2) (3 4) (5 6)) 2))))
      ;; Length limit truncates to 2 elements + ellipsis
      (5am:is-true (search "\"...\"" r)))))

;;; --- logfmt Value Serialization ---

(5am:test test-emit-logfmt-value-character
  "Characters serialize as bare single char in logfmt."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s #\x))))
    (5am:is (string= "x" r))))

(5am:test test-emit-logfmt-value-ratio
  "Ratios coerce to double-float in logfmt."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s 1/4))))
    (5am:is-true (search "0.25" r))
    (5am:is-false (search "d0" r))))

(5am:test test-emit-logfmt-value-pathname
  "Pathnames serialize via namestring in logfmt."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s #P"/tmp/log"))))
    (5am:is (string= "/tmp/log" r)))
  ;; Pathname with spaces gets quoted
  (let ((r (with-output-to-string (s) (emit-logfmt-value s #P"/tmp/my log"))))
    (5am:is (string= "\"/tmp/my log\"" r))))

(5am:test test-emit-logfmt-value-collection-placeholder
  "Collections produce <type> placeholder in logfmt."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s '(1 2 3)))))
    (5am:is (string= "<cons>" r)))
  (let ((r (with-output-to-string (s) (emit-logfmt-value s #(1 2 3)))))
    (5am:is-true (search "<" r)))
  (let ((r (with-output-to-string (s) (emit-logfmt-value s (make-hash-table)))))
    (5am:is-true (search "<" r))))

(5am:test test-emit-logfmt-value-fallback-placeholder
  "Unsupported types produce <type> placeholder in logfmt."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s #'car))))
    (5am:is-true (search "<" r))
    (5am:is-true (search ">" r))))

;;; --- logfmt Bare Key for Boolean T ---

(5am:test test-logfmt-bare-key-for-true
  "In logfmt, boolean t emits bare key with no =value."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level :info :formatter #'bark:logfmt-formatter :output out)))
      (funcall (bark::logger-info-fn l) l "msg" :verbose t :count 42))
    (let ((s (get-output-stream-string out)))
      ;; Should have bare "verbose" without "=true"
      (5am:is-true (search " verbose " s))
      (5am:is-false (search "verbose=" s))
      ;; Other fields should still have =
      (5am:is-true (search "count=42" s)))))

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

;;; --- Utilities ---

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

;;; --- Async Output ---

(5am:test test-async-output-basic
  "Create an async-output to a string stream, send messages, stop, verify stream contents."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (bark::ring-buffer-push (bark::async-output-ring ao) "hello")
    (bark::ring-buffer-push (bark::async-output-ring ao) "world")
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::flush-async-output ao)
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (5am:is (search "hello" result))
      (5am:is (search "world" result)))))

(5am:test test-flush-async-output
  "Verify flush-async-output blocks until queue is drained."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (dotimes (i 5)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "line-~d" i)))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::flush-async-output ao)
    (let ((result (get-output-stream-string out)))
      (5am:is (= 5 (count #\Newline result))))
    (bark::stop-async-output ao)))

;;; --- Helpers ---

(defun stop-tee (tee-output)
  "Stop all async outputs in a tee-output. For test cleanup."
  (loop for group across (tee-output-groups tee-output)
        do (loop for dest across (formatter-group-destinations group)
                 do (bark::stop-async-output (destination-async-output dest)))))

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

(5am:test test-async-output-integration
  "START creates an async-backed logger; STOP flushes all pending messages."
  (let ((out (make-string-output-stream)))
    (bark:start :stream out :level :info :capacity 64)
    (bark:info "integration-test-msg")
    (bark:stop)
    (let ((result (get-output-stream-string out)))
      (5am:is (search "integration-test-msg" result)))))

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

;;; --- Captured Logs Formatter ---

(5am:test test-with-captured-logs-formatter
  "WITH-CAPTURED-LOGS accepts an optional formatter argument."
  ;; Default still uses json
  (bark:with-captured-logs (logs)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (5am:is (search "\"level\"" line))))
  ;; Explicit logfmt
  (bark:with-captured-logs (logs #'bark:logfmt-formatter)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (5am:is (search "level=info" line))))
  ;; Explicit pretty
  (bark:with-captured-logs (logs #'bark:pretty-formatter)
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (5am:is (search "INFO" line))
      ;; pretty formatter should NOT have JSON structure
      (5am:is (not (search "\"level\"" line))))))

;;; --- Convenience Macros ---

(5am:test test-convenience-macros
  "BARK:TRACE through BARK:FATAL expand to the correct level funcalls."
  (bark:with-captured-logs (logs)
    (bark:trace "t")
    (bark:debug "d")
    (bark:info "i")
    (bark:warn "w")
    (bark:error "e")
    (bark:fatal "f")
    (let ((lines (funcall logs)))
      (5am:is (= 6 (length lines)))
      ;; Verify each level number in order
      (5am:is (search "\"level\":10" (nth 0 lines)))
      (5am:is (search "\"level\":20" (nth 1 lines)))
      (5am:is (search "\"level\":30" (nth 2 lines)))
      (5am:is (search "\"level\":40" (nth 3 lines)))
      (5am:is (search "\"level\":50" (nth 4 lines)))
      (5am:is (search "\"level\":60" (nth 5 lines))))))

(5am:test test-macros-with-fields
  "Convenience macros pass per-call fields through to the formatter."
  (bark:with-captured-logs (logs)
    (bark:info "request" :method "GET" :path "/api")
    (let ((line (first (funcall logs))))
      (5am:is (search "\"method\":\"GET\"" line))
      (5am:is (search "\"path\":\"/api\"" line)))))

;;; --- Ring Buffer ---

(5am:test test-ring-buffer-basic
  "Push and pop values from a ring buffer."
  (let ((rb (bark::make-ring-buffer 16)))
    (5am:is (bark::ring-buffer-push rb "a"))
    (5am:is (bark::ring-buffer-push rb "b"))
    (5am:is (string= "a" (bark::ring-buffer-pop rb)))
    (5am:is (string= "b" (bark::ring-buffer-pop rb)))
    (5am:is (null (bark::ring-buffer-pop rb)))))

(5am:test test-ring-buffer-drop-on-full
  "Ring buffer drops messages and increments counter when full."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 16) (bark::ring-buffer-push rb (format nil "msg-~d" i)))
    (5am:is (= 0 (bark::ring-buffer-dropped rb)))
    (5am:is (null (bark::ring-buffer-push rb "overflow")))
    (5am:is (= 1 (bark::ring-buffer-dropped rb)))
    (bark::ring-buffer-pop rb)
    (5am:is (bark::ring-buffer-push rb "recovered"))))

(5am:test test-ring-buffer-drain
  "Drain returns all available values."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 5) (bark::ring-buffer-push rb (format nil "~d" i)))
    (let ((items (bark::ring-buffer-drain rb)))
      (5am:is (= 5 (length items)))
      (5am:is (string= "0" (first items)))
      (5am:is (string= "4" (fifth items))))))

(5am:test test-ring-buffer-mpsc
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
      (5am:is (= 400 (length items)))
      (5am:is (= 0 (bark::ring-buffer-dropped rb))))))

;;; --- Async Drop Handling ---

(5am:test test-async-drop-warning
  "When the ring buffer overflows, a drop warning appears in the output."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 5)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (5am:is (search "dropped 5 log messages" result)))))

(5am:test test-async-custom-on-drop
  "Custom on-drop callback controls the drop warning message."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16
               :on-drop (lambda (n) (format nil "LOST:~d" n)))))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 3)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (5am:is (search "LOST:3" result)))))

(5am:test test-async-on-drop-nil-suppresses
  "on-drop returning NIL suppresses the warning line."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16
               :on-drop (lambda (n) (declare (ignore n)) nil))))
    (dotimes (i 20)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      (5am:is (not (search "dropped" result))))))

;;; --- Multi-Output: make-tee ---

(5am:test test-make-tee-basic
  "make-tee creates a tee-output with correct number of destinations."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter #'json-formatter)
                     (list :stream s2 :formatter #'pretty-formatter)))))
    (unwind-protect
         (progn
           (5am:is-true (tee-output-p tee))
           ;; Two different formatters -> two groups
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; Each group has one destination
           (5am:is (= 1 (length (formatter-group-destinations (aref (tee-output-groups tee) 0)))))
           (5am:is (= 1 (length (formatter-group-destinations (aref (tee-output-groups tee) 1))))))
      ;; Cleanup: stop all async outputs
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

(5am:test test-make-tee-shared-formatter-grouping
  "Destinations with eq formatters are grouped together."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (s3 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter #'json-formatter)
                     (list :stream s2 :formatter #'pretty-formatter)
                     (list :stream s3 :formatter #'json-formatter)))))
    (unwind-protect
         (progn
           ;; Two formatters (json shared by 2, pretty by 1) -> two groups
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; Find the json group (has 2 destinations)
           (let ((json-group (find #'json-formatter (tee-output-groups tee)
                                   :key #'formatter-group-formatter)))
             (5am:is-true (not (null json-group)))
             (5am:is (= 2 (length (formatter-group-destinations json-group))))))
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

(5am:test test-make-tee-level-filter
  "The :level shorthand creates a filter that checks >= threshold."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter #'json-formatter :level :error)))))
    (unwind-protect
         (let* ((group (aref (tee-output-groups tee) 0))
                (dest (aref (formatter-group-destinations group) 0))
                (filter (destination-filter dest)))
           (5am:is-true (not (null filter)))
           ;; Below error -> filtered out
           (5am:is-false (funcall filter +info+ nil))
           (5am:is-false (funcall filter +warn+ nil))
           ;; At or above error -> passes
           (5am:is-true (funcall filter +error+ nil))
           (5am:is-true (funcall filter +fatal+ nil)))
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

(5am:test test-make-tee-default-formatter
  "Omitting :formatter defaults to #'json-formatter."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:make-tee (list (list :stream s1)))))
    (unwind-protect
         (let ((group (aref (tee-output-groups tee) 0)))
           (5am:is (eq #'json-formatter (formatter-group-formatter group))))
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

(5am:test test-make-tee-level-and-filter-conflict
  "Specifying both :level and :filter signals an error."
  (let ((s1 (make-string-output-stream)))
    (5am:signals cl:error
      (bark:make-tee
       (list (list :stream s1
                   :level :error
                   :filter (lambda (level fields) (declare (ignore level fields)) t)))))))

(5am:test test-make-tee-custom-capacity-and-on-drop
  "Per-destination :capacity and :on-drop are passed to async-output."
  (let* ((s1 (make-string-output-stream))
         (custom-drop (lambda (n) (format nil "CUSTOM:~d" n)))
         (tee (bark:make-tee
               (list (list :stream s1 :capacity 1024 :on-drop custom-drop)))))
    (unwind-protect
         (let* ((group (aref (tee-output-groups tee) 0))
                (dest (aref (formatter-group-destinations group) 0))
                (ao (destination-async-output dest)))
           ;; Ring buffer capacity should be 1024
           (5am:is (= 1023 (bark::ring-buffer-mask (bark::async-output-ring ao))))
           ;; on-drop should be our custom function
           (5am:is (eq custom-drop (bark::async-output-on-drop ao))))
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

(5am:test test-tee-macro-basic
  "tee macro creates same structure as equivalent make-tee call."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter #'json-formatter)
               (s2 :formatter #'pretty-formatter :level :error))))
    (unwind-protect
         (progn
           (5am:is-true (tee-output-p tee))
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; Second destination should have a filter (from :level :error)
           (let* ((pretty-group (find #'pretty-formatter (tee-output-groups tee)
                                      :key #'formatter-group-formatter))
                  (dest (aref (formatter-group-destinations pretty-group) 0)))
             (5am:is-true (not (null (destination-filter dest))))
             (5am:is-false (funcall (destination-filter dest) +info+ nil))
             (5am:is-true (funcall (destination-filter dest) +error+ nil))))
      (loop for group across (tee-output-groups tee)
            do (loop for dest across (formatter-group-destinations group)
                     do (bark::stop-async-output (destination-async-output dest)))))))

;;; --- Multi-Output: Tee Logging ---

(5am:test test-tee-mirror-two-destinations
  "Tee with two destinations: same event goes to both with different formatters."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter #'json-formatter)
               (s2 :formatter #'logfmt-formatter))))
    (unwind-protect
         (let ((*logger* (make-logger :name "tee-test" :level :info :output tee)))
           (bark:info "hello" :key "val")
           (stop-tee tee)
           (let ((json-out (get-output-stream-string s1))
                 (logfmt-out (get-output-stream-string s2)))
             ;; Both streams got the message
             (5am:is-true (search "hello" json-out))
             (5am:is-true (search "hello" logfmt-out))
             ;; JSON output has JSON structure
             (5am:is-true (search "\"msg\"" json-out))
             ;; Logfmt output has logfmt structure
             (5am:is-true (search "msg=" logfmt-out))))
      (stop-tee tee))))

(5am:test test-tee-level-filter-routing
  "Tee with level filter: info goes to console only, error goes to both."
  (let* ((s-all (make-string-output-stream))
         (s-errors (make-string-output-stream))
         (tee (bark:tee
               (s-all    :formatter #'json-formatter)
               (s-errors :formatter #'json-formatter :level :error))))
    (unwind-protect
         (let ((*logger* (make-logger :name "route" :level :info :output tee)))
           (bark:info "all good")
           (bark:error "disk full")
           (stop-tee tee)
           (let ((all-out (get-output-stream-string s-all))
                 (err-out (get-output-stream-string s-errors)))
             ;; All stream gets both messages
             (5am:is-true (search "all good" all-out))
             (5am:is-true (search "disk full" all-out))
             ;; Error stream only gets the error
             (5am:is-false (search "all good" err-out))
             (5am:is-true (search "disk full" err-out))))
      (stop-tee tee))))

(5am:test test-tee-custom-filter
  "Tee with a custom filter that routes based on per-call fields."
  (let* ((s-all (make-string-output-stream))
         (s-audit (make-string-output-stream))
         (tee (bark:tee
               (s-all   :formatter #'json-formatter)
               (s-audit :formatter #'json-formatter
                        :filter (lambda (level fields)
                                  (declare (ignore level))
                                  (getf fields :audit))))))
    (unwind-protect
         (let ((*logger* (make-logger :name "filter" :level :info :output tee)))
           (bark:info "page loaded" :path "/home")
           (bark:info "user login" :audit t :user-id 42)
           (stop-tee tee)
           (let ((all-out (get-output-stream-string s-all))
                 (audit-out (get-output-stream-string s-audit)))
             ;; All stream gets both
             (5am:is-true (search "page loaded" all-out))
             (5am:is-true (search "user login" all-out))
             ;; Audit stream only gets the audit event
             (5am:is-false (search "page loaded" audit-out))
             (5am:is-true (search "user login" audit-out))))
      (stop-tee tee))))

(5am:test test-tee-shared-formatter-optimization
  "When destinations share an eq formatter, it's called once per log event."
  (let* ((call-count 0)
         (counting-fmt
          (lambda (level chindings raw-bindings context message fields)
            (incf call-count)
            (json-formatter level chindings raw-bindings context message fields)))
         (s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         ;; Both destinations use the SAME formatter object
         (tee (bark:make-tee
               (list (list :stream s1 :formatter counting-fmt)
                     (list :stream s2 :formatter counting-fmt)))))
    (unwind-protect
         (let ((*logger* (make-logger :name "opt" :level :info :output tee)))
           (bark:info "shared format test")
           (stop-tee tee)
           ;; Formatter should have been called exactly once (not twice)
           (5am:is (= 1 call-count))
           ;; Both streams should have received the message
           (5am:is-true (search "shared format test" (get-output-stream-string s1)))
           (5am:is-true (search "shared format test" (get-output-stream-string s2))))
      (stop-tee tee))))

(5am:test test-tee-shared-formatter-with-filter
  "Shared formatter optimization respects per-destination filters."
  (let* ((call-count 0)
         (counting-fmt
          (lambda (level chindings raw-bindings context message fields)
            (incf call-count)
            (json-formatter level chindings raw-bindings context message fields)))
         (s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter counting-fmt)
                     (list :stream s2 :formatter counting-fmt :level :error)))))
    (unwind-protect
         (let ((*logger* (make-logger :name "opt-filter" :level :info :output tee)))
           ;; Info message: only s1 passes filter, s2 filtered out
           (bark:info "info only")
           (stop-tee tee)
           ;; Formatter called once (for s1; s2 was filtered but format happens for group)
           (5am:is (= 1 call-count))
           (5am:is-true (search "info only" (get-output-stream-string s1)))
           (5am:is-false (search "info only" (get-output-stream-string s2))))
      (stop-tee tee))))

(5am:test test-tee-child-inherits
  "Child logger inherits parent's tee output."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter #'json-formatter)
               (s2 :formatter #'json-formatter))))
    (unwind-protect
         (let* ((parent (make-logger :name "parent" :level :info :output tee))
                (ch (child parent :component "auth")))
           (let ((*logger* ch))
             (bark:info "token verified" :user-id 42))
           (stop-tee tee)
           (let ((out1 (get-output-stream-string s1))
                 (out2 (get-output-stream-string s2)))
             ;; Both destinations receive the event
             (5am:is-true (search "token verified" out1))
             (5am:is-true (search "token verified" out2))
             ;; Both include static context from child
             (5am:is-true (search "component" out1))
             (5am:is-true (search "auth" out1))
             (5am:is-true (search "component" out2))))
      (stop-tee tee))))

(5am:test test-tee-with-context
  "Dynamic context applies to all tee destinations."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter #'json-formatter)
               (s2 :formatter #'json-formatter))))
    (unwind-protect
         (let ((*logger* (make-logger :name "ctx" :level :info :output tee)))
           (bark:with-context (:request-id "req-123")
             (bark:info "hello"))
           (stop-tee tee)
           (let ((out1 (get-output-stream-string s1)))
             (5am:is-true (search "request-id" out1))
             (5am:is-true (search "req-123" out1))))
      (stop-tee tee))))

(5am:test test-tee-level-filtering-respects-logger-level
  "Logger level threshold still applies before tee dispatch."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:tee (s1 :formatter #'json-formatter))))
    (unwind-protect
         (let ((*logger* (make-logger :name "lvl" :level :warn :output tee)))
           ;; Info is below logger level -> noop function -> never reaches tee
           (bark:info "should not appear")
           (bark:warn "should appear")
           (stop-tee tee)
           (let ((out (get-output-stream-string s1)))
             (5am:is-false (search "should not appear" out))
             (5am:is-true (search "should appear" out))))
      (stop-tee tee))))
