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
   #:*max-json-depth* #:*max-json-length*
   #:*max-pretty-depth* #:*max-pretty-length*
   #:write-json-escaped-string #:serialize-bindings
   ;; Async output internals
   #:make-async-output #:stop-async-output #:flush-async-output
   #:async-output-stream #:async-output-running #:async-output-ring #:async-output-thread
   #:async-output-notify #:ring-buffer-push
   ;; Multi-output internals
   #:destination-p #:destination-async-output #:destination-formatter #:destination-filter
   #:formatter-group-formatter #:formatter-group-destinations
   #:tee-output-p #:tee-output-groups
   #:make-tee
   ;; Condition serialization
   #:capture #:captured-error-p #:captured-error-condition #:captured-error-stack
   #:*max-json-stack-frames* #:*max-pretty-stack-frames*
   ;; Utilities
   #:noop #:make-list-collector
   #:current-log-timestamp-ms #:*override-timestamp*
   ;; Field transform
   #:logger-field-transform #:compose-field-transforms
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

(5am:test test-emit-json-key-non-string-non-symbol
  "emit-json-key handles non-string/non-symbol keys via princ-to-string."
  ;; Integer key — must produce valid JSON, not empty key
  (let ((r (with-output-to-string (s) (emit-json-key s 42))))
    (5am:is-true (search "\"42\":" r)))
  ;; String key — normal path
  (let ((r (with-output-to-string (s) (emit-json-key s "foo"))))
    (5am:is-true (search "\"foo\":" r)))
  ;; Symbol key — lowercased
  (let ((r (with-output-to-string (s) (emit-json-key s :bar))))
    (5am:is-true (search "\"bar\":" r))))

(5am:test test-emit-logfmt-key-non-string-non-symbol
  "emit-logfmt-key handles non-string/non-symbol keys via princ-to-string."
  (let ((r (with-output-to-string (s) (emit-logfmt-key s 42))))
    (5am:is (string= "42" r)))
  (let ((r (with-output-to-string (s) (emit-logfmt-key s "foo"))))
    (5am:is (string= "foo" r)))
  (let ((r (with-output-to-string (s) (emit-logfmt-key s :bar))))
    (5am:is (string= "bar" r))))

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
             (emit-json-value s *standard-output*))))
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
  "Lists longer than *max-json-length* are truncated with ellipsis."
  (let ((bark:*max-json-length* 3))
    (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 3 4 5)))))
      (5am:is (string= "[1,2,3,\"...\"]" r)))))

(5am:test test-emit-json-value-length-limit-vector
  "Vectors longer than *max-json-length* are truncated with ellipsis."
  (let ((bark:*max-json-length* 2))
    (let ((r (with-output-to-string (s) (emit-json-value s #(10 20 30 40)))))
      (5am:is (string= "[10,20,\"...\"]" r)))))

(5am:test test-emit-json-value-length-limit-hash-table
  "Hash-tables larger than *max-json-length* are truncated."
  (let ((bark:*max-json-length* 1)
        (h (make-hash-table :test 'equal)))
    (setf (gethash "a" h) 1 (gethash "b" h) 2 (gethash "c" h) 3)
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      (5am:is-true (search "\"...\":\"...\"" r)))))

(5am:test test-emit-json-value-hash-table-truncation-valid-json
  "Truncated hash-tables produce valid JSON with closing brace."
  (let ((bark:*max-json-length* 1)
        (h (make-hash-table :test 'equal)))
    (setf (gethash "a" h) 1 (gethash "b" h) 2)
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      ;; Must end with } — previously the return-from skipped the closing brace
      (5am:is (char= #\} (char r (1- (length r)))))
      ;; Must be parseable as JSON
      (5am:is (hash-table-p (yason:parse r))))))

(5am:test test-emit-json-value-depth-and-length
  "Depth and length limits compose correctly."
  (let ((bark:*max-json-length* 2))
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

(5am:test test-pretty-formatter-print-length
  "Pretty-formatter truncates long lists via *max-pretty-length*."
  (let* ((*max-pretty-length* 3)
         (output (pretty-formatter +info+ "" nil nil "msg"
                                   (list :data '(1 2 3 4 5)))))
    (5am:is-true (search "1" output))
    (5am:is-true (search "3" output))
    ;; CL printer uses "..." for truncation
    (5am:is-true (search "..." output))
    ;; Element beyond the limit should not appear
    (5am:is-false (search "5" output))))

(5am:test test-pretty-formatter-print-level
  "Pretty-formatter truncates deep nesting via *max-pretty-depth*."
  (let* ((*max-pretty-depth* 1)
         (output (pretty-formatter +info+ "" nil nil "msg"
                                   (list :data '((nested))))))
    ;; CL printer uses "#" for depth truncation
    (5am:is-true (search "#" output))))

(5am:test test-pretty-formatter-print-circle
  "Pretty-formatter handles circular structures without looping."
  (let* ((circ (list 1 2 3)))
    (setf (cdr (last circ)) circ)
    ;; Should complete without hanging — *print-circle* is bound to T
    (let ((output (pretty-formatter +info+ "" nil nil "msg"
                                    (list :data circ))))
      (5am:is-true (stringp output))
      (5am:is-true (search "#" output)))))

(5am:test test-pretty-formatter-nil-limits
  "Pretty-formatter with NIL limits produces unlimited output."
  (let* ((*max-pretty-length* nil)
         (*max-pretty-depth* nil)
         (output (pretty-formatter +info+ "" nil nil "msg"
                                   (list :data '(1 2 3 4 5 6 7 8 9 10)))))
    ;; All elements should appear
    (5am:is-true (search "10" output))
    (5am:is-false (search "..." output))))

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
    (bark:start :output out :level :info :capacity 64)
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

(5am:test test-logfmt-quoting-escapes-internal-quotes
  "Logfmt formatter escapes double quotes inside quoted values."
  (let ((r (with-output-to-string (s)
             (bark::logfmt-write-bare-or-quoted s "he said \"hello\""))))
    ;; Must not produce malformed "he said "hello"" — internal quotes escaped
    (5am:is (char= #\" (char r 0)))
    (5am:is (char= #\" (char r (1- (length r)))))
    (5am:is-true (search "\\\"" r))
    ;; Round-trip: count quotes — opening + closing + 2 escaped = 4 quote chars
    (5am:is (= 4 (count #\" r)))))

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

(5am:test test-with-captured-logs-includes-name
  "WITH-CAPTURED-LOGS produces JSON output that includes the logger name."
  (bark:with-captured-logs (logs)
    (bark:info "hello")
    (let* ((line (first (funcall logs)))
           (parsed (yason:parse line)))
      ;; The test logger has name "test" — must appear in JSON output
      (5am:is (string= "test" (gethash "name" parsed))))))

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

(5am:test test-ring-buffer-power-of-two-rounding
  "make-ring-buffer rounds capacity to next power of two correctly.
   Exact powers of two must not be rounded up (regression: float rounding)."
  ;; Exact power of two — must stay at that size, not round up
  (let ((rb (bark::make-ring-buffer 256)))
    (5am:is (= 256 (length (bark::ring-buffer-slots rb)))))
  ;; Non-power-of-two — rounds up
  (let ((rb (bark::make-ring-buffer 100)))
    (5am:is (= 128 (length (bark::ring-buffer-slots rb)))))
  ;; Minimum capacity enforced
  (let ((rb (bark::make-ring-buffer 4)))
    (5am:is (= 16 (length (bark::ring-buffer-slots rb))))))

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

;;; --- Multi-Output: Lifecycle ---

(5am:test test-start-with-plain-stream
  "start with :output as a plain stream wraps it in async-output."
  (let ((out (make-string-output-stream)))
    (bark:start :output out :level :info :name "plain")
    (bark:info "stream test")
    (bark:stop)
    (5am:is-true (search "stream test" (get-output-stream-string out)))))

(5am:test test-start-with-tee-output
  "start with :output as a tee-output uses it directly."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream)))
    (bark:start :name "tee" :level :info
                :output (bark:tee
                         (s1 :formatter #'json-formatter)
                         (s2 :formatter #'pretty-formatter)))
    (bark:info "tee start test" :key "val")
    (bark:stop)
    (let ((json-out (get-output-stream-string s1))
          (pretty-out (get-output-stream-string s2)))
      (5am:is-true (search "tee start test" json-out))
      (5am:is-true (search "tee start test" pretty-out))
      (5am:is-true (search "\"msg\"" json-out)))))

(5am:test test-start-default-output
  "start with no :output defaults to *error-output*."
  (let* ((out (make-string-output-stream))
         (*error-output* out))
    (bark:start :name "default" :level :info)
    (bark:info "default test")
    (bark:stop)
    (5am:is-true (search "default test" (get-output-stream-string out)))))

(5am:test test-start-with-context-and-tee
  "start with :context and :output tee wraps in child with context."
  (let* ((s1 (make-string-output-stream)))
    (bark:start :name "ctx" :level :info
                :output (bark:tee (s1 :formatter #'json-formatter))
                :context '(:role "broker" :pid 123))
    (bark:info "context tee test")
    (bark:stop)
    (let ((out (get-output-stream-string s1)))
      (5am:is-true (search "context tee test" out))
      (5am:is-true (search "role" out))
      (5am:is-true (search "broker" out)))))

(5am:test test-stop-tears-down-tee
  "stop with tee output stops all writer threads."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream)))
    (bark:start :name "teardown" :level :info
                :output (bark:tee
                         (s1 :formatter #'json-formatter)
                         (s2 :formatter #'json-formatter)))
    (bark:info "before stop")
    (bark:stop)
    ;; After stop, *logger* should be nil
    (5am:is-true (null *logger*))
    ;; Both streams should have the message
    (5am:is-true (search "before stop" (get-output-stream-string s1)))
    (5am:is-true (search "before stop" (get-output-stream-string s2)))))

;;; --- Multi-Output: Error Recovery ---

(5am:test test-on-error-stream-recovery
  "on-error returning a new stream causes the writer to swap and continue."
  (let* ((bad-write-count 0)
         (recovery-stream (make-string-output-stream))
         (failing-stream (make-broadcast-stream))  ; broadcast to nothing -> won't error, need custom
         (ao (bark::make-async-output
              (make-string-output-stream)  ; initial stream
              :capacity 64
              :on-error (lambda (e)
                          (declare (ignore e))
                          recovery-stream))))
    ;; Close the initial stream to cause write errors
    (close (bark::async-output-stream ao))
    ;; Push a message — writer should hit error, recover to recovery-stream
    (bark::ring-buffer-push (bark::async-output-ring ao) "recovered message")
    (bt:signal-semaphore (bark::async-output-notify ao))
    ;; Give writer time to process
    (sleep 0.2)
    (bark::stop-async-output ao)
    ;; The recovery stream should have subsequent messages
    ;; (the failed message is lost, but the writer continues)
    (5am:is (eq recovery-stream (bark::async-output-stream ao)))))

(5am:test test-on-error-returns-nil-stops-writer
  "on-error returning NIL causes the writer thread to exit."
  (let* ((ao (bark::make-async-output
              (make-string-output-stream)
              :capacity 64
              :on-error (lambda (e) (declare (ignore e)) nil))))
    (close (bark::async-output-stream ao))
    (bark::ring-buffer-push (bark::async-output-ring ao) "will fail")
    (bt:signal-semaphore (bark::async-output-notify ao))
    (sleep 0.2)
    ;; Writer should have exited
    (5am:is-false (bark::async-output-running ao))
    ;; Clean up thread
    (when (bark::async-output-thread ao)
      (bt:join-thread (bark::async-output-thread ao)))))

(5am:test test-no-on-error-default-behavior
  "Without on-error, writer logs to *error-output* and exits."
  (let* ((err-out (make-string-output-stream))
         (*error-output* err-out)
         (ao (bark::make-async-output
              (make-string-output-stream)
              :capacity 64)))
    (close (bark::async-output-stream ao))
    (bark::ring-buffer-push (bark::async-output-ring ao) "will fail")
    (bt:signal-semaphore (bark::async-output-notify ao))
    (sleep 0.2)
    ;; Writer should have exited
    (5am:is-false (bark::async-output-running ao))
    ;; Error should be logged to *error-output*
    (5am:is-true (search "bark writer-loop error" (get-output-stream-string err-out)))
    (when (bark::async-output-thread ao)
      (bt:join-thread (bark::async-output-thread ao)))))

;;; --- Explicit Logger Argument ---

(5am:test test-explicit-logger-basic
  "Passing a logger as first arg routes to that logger, not *logger*."
  (multiple-value-bind (c1 r1) (make-list-collector)
    (multiple-value-bind (c2 r2) (make-list-collector)
      (let ((*logger* (make-logger :name "global" :level :info :output c1))
            (other   (make-logger :name "other"  :level :info :output c2)))
        (bark:info "goes to global")
        (bark:info other "goes to other")
        (let ((global-logs (funcall r1))
              (other-logs (funcall r2)))
          (5am:is (= 1 (length global-logs)))
          (5am:is (= 1 (length other-logs)))
          (5am:is-true (search "goes to global" (first global-logs)))
          (5am:is-true (search "goes to other" (first other-logs))))))))

(5am:test test-explicit-logger-all-levels
  "All six macros accept an explicit logger as first argument."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :name "explicit" :level :trace :output collector)))
      (bark:trace lgr "t")
      (bark:debug lgr "d")
      (bark:info  lgr "i")
      (bark:warn  lgr "w")
      (bark:error lgr "e")
      (bark:fatal lgr "f")
      (let ((logs (funcall results-fn)))
        (5am:is (= 6 (length logs)))
        (5am:is-true (search "\"level\":10" (nth 0 logs)))
        (5am:is-true (search "\"level\":60" (nth 5 logs)))))))

(5am:test test-explicit-logger-with-fields
  "Explicit logger receives per-call fields."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :name "fields" :level :info :output collector)))
      (bark:info lgr "request" :method "GET" :path "/api")
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (5am:is-true (search "method" line))
        (5am:is-true (search "GET" line))
        (5am:is-true (search "path" line))))))

(5am:test test-explicit-logger-with-context
  "Dynamic context applies to explicit logger too."
  (multiple-value-bind (c1 r1) (make-list-collector)
    (multiple-value-bind (c2 r2) (make-list-collector)
      (let ((*logger* (make-logger :name "global" :level :info :output c1))
            (other   (make-logger :name "other"  :level :info :output c2)))
        (bark:with-context (:req "123")
          (bark:info "global msg")
          (bark:info other "other msg"))
        (let ((g-line (first (funcall r1)))
              (o-line (first (funcall r2))))
          ;; Both loggers see the dynamic context
          (5am:is-true (search "req" g-line))
          (5am:is-true (search "123" g-line))
          (5am:is-true (search "req" o-line))
          (5am:is-true (search "123" o-line)))))))

(5am:test test-explicit-logger-nil-logger-is-message
  "When *logger* is nil and first arg is a string, it's a no-op (not crash)."
  (let ((*logger* nil))
    ;; Should not error — nil *logger* means no-op
    (bark:info "this is fine")
    (5am:is-true t)))

(5am:test test-explicit-logger-string-first-arg
  "When first arg is a string (not a logger), it's treated as the message."
  (with-captured-logs (get-logs)
    (bark:info "hello world" :key "val")
    (let ((line (first (funcall get-logs))))
      (5am:is-true (search "hello world" line))
      (5am:is-true (search "key" line)))))

;;; --- Condition Serialization ---

(5am:test test-captured-error-struct
  "Verify captured-error struct and its accessors."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c)))
    (5am:is (captured-error-p ce))
    (5am:is (eq c (captured-error-condition ce)))
    (5am:is (listp (captured-error-stack ce)))))

(5am:test test-capture-strips-internal-frames
  "Verify capture does not include bark/dissect internal frames."
  (let* ((c (make-condition 'simple-error :format-control "test"))
         (ce (bark:capture c)))
    ;; No frame should have BARK or DISSECT in its call
    (dolist (frame (captured-error-stack ce))
      (let ((call (dissect:call frame)))
        (when (symbolp call)
          (let ((pkg (symbol-package call)))
            (when pkg
              (5am:is-false (member (package-name pkg) '("BARK" "DISSECT") :test #'string=)
                            "Frame ~a should not be from BARK or DISSECT" call))))))))

(5am:test test-json-condition-simple-error
  "emit-json-value on a simple-error produces {\"type\":...,\"msg\":...}."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (json-str (with-output-to-string (s) (emit-json-value s c)))
         (parsed (yason:parse json-str)))
    (5am:is (string= "simple-error" (gethash "type" parsed)))
    (5am:is (string= "boom" (gethash "msg" parsed)))))

(5am:test test-json-condition-type-error
  "emit-json-value on a type-error shows correct type name."
  (let* ((c (make-condition 'type-error :datum 42 :expected-type 'string))
         (json-str (with-output-to-string (s) (emit-json-value s c)))
         (parsed (yason:parse json-str)))
    (5am:is (string= "type-error" (gethash "type" parsed)))
    (5am:is (stringp (gethash "msg" parsed)))))

(5am:test test-json-condition-empty-message
  "Condition with empty format-control produces empty msg, not omitted."
  (let* ((c (make-condition 'simple-error :format-control ""))
         (json-str (with-output-to-string (s) (emit-json-value s c)))
         (parsed (yason:parse json-str)))
    (5am:is (string= "" (gethash "msg" parsed)))))

(5am:test test-json-captured-error-structure
  "emit-json-value on captured-error has type, msg, stack keys."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c))
         (json-str (with-output-to-string (s) (emit-json-value s ce)))
         (parsed (yason:parse json-str)))
    (5am:is (string= "simple-error" (gethash "type" parsed)))
    (5am:is (string= "boom" (gethash "msg" parsed)))
    (5am:is (listp (gethash "stack" parsed)))
    ;; Each frame has at least a "call" key
    (dolist (frame (gethash "stack" parsed))
      (5am:is (stringp (gethash "call" frame))))))

(5am:test test-json-stack-frame-limit
  "Stack frames respect *max-json-stack-frames* and append sentinel."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c))
         (json-str (let ((*max-json-stack-frames* 2))
                     (with-output-to-string (s) (emit-json-value s ce))))
         (parsed (yason:parse json-str))
         (stack (gethash "stack" parsed)))
    ;; Should have at most 3 entries: 2 real + 1 sentinel
    (5am:is (<= (length stack) 3))
    ;; Last entry is the sentinel
    (when (> (length stack) 2)
      (5am:is (string= "..." (gethash "call" (car (last stack))))))))

(5am:test test-json-stack-frame-limit-nil
  "*max-json-stack-frames* NIL means unlimited."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c))
         (json-str (let ((*max-json-stack-frames* nil))
                     (with-output-to-string (s) (emit-json-value s ce))))
         (parsed (yason:parse json-str))
         (stack (gethash "stack" parsed)))
    ;; Should have more than 2 frames (no truncation)
    (5am:is (> (length stack) 2))))

(5am:test test-json-stack-frame-limit-zero
  "*max-json-stack-frames* 0 produces sentinel only."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c))
         (json-str (let ((*max-json-stack-frames* 0))
                     (with-output-to-string (s) (emit-json-value s ce))))
         (parsed (yason:parse json-str))
         (stack (gethash "stack" parsed)))
    (5am:is (= 1 (length stack)))
    (5am:is (string= "..." (gethash "call" (first stack))))))

(5am:test test-json-captured-error-empty-stack
  "Captured error with empty stack produces empty array."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark::%make-captured-error :condition c :stack nil))
         (json-str (with-output-to-string (s) (emit-json-value s ce)))
         (parsed (yason:parse json-str)))
    (5am:is (equal '() (gethash "stack" parsed)))))

(5am:test test-logfmt-condition
  "emit-logfmt-value on a condition produces quoted type: message."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (result (with-output-to-string (s) (emit-logfmt-value s c))))
    (5am:is (string= "\"simple-error: boom\"" result))))

(5am:test test-logfmt-captured-error
  "emit-logfmt-value on captured-error produces same as plain condition."
  (let* ((c (make-condition 'simple-error :format-control "boom"))
         (ce (bark:capture c))
         (result (with-output-to-string (s) (emit-logfmt-value s ce))))
    (5am:is (string= "\"simple-error: boom\"" result))))

(5am:test test-pretty-condition-inline
  "Pretty formatter shows type: message for plain conditions."
  (bark:with-captured-logs (get-logs #'pretty-formatter)
    (let ((c (make-condition 'simple-error :format-control "boom")))
      (bark:error "failed" :err c)
      (let ((line (first (funcall get-logs))))
        (5am:is-true (search "simple-error: boom" line))))))

(5am:test test-pretty-captured-error-stack
  "Pretty formatter shows inline condition + indented stack trace."
  (bark:with-captured-logs (get-logs #'pretty-formatter)
    (let ((c (make-condition 'simple-error :format-control "boom")))
      (bark:error "failed" :err (bark:capture c))
      (let ((line (first (funcall get-logs))))
        ;; Inline condition
        (5am:is-true (search "simple-error: boom" line))
        ;; Stack trace lines (ANSI bold "at" with frame call)
        (5am:is-true (search "at " line))))))

(5am:test test-pretty-stack-frame-limit
  "Pretty formatter respects *max-pretty-stack-frames*."
  (bark:with-captured-logs (get-logs #'pretty-formatter)
    (let ((c (make-condition 'simple-error :format-control "boom"))
          (*max-pretty-stack-frames* 1))
      (bark:error "failed" :err (bark:capture c))
      (let ((line (first (funcall get-logs))))
        ;; Should have truncation marker
        (5am:is-true (search "... (" line))
        (5am:is-true (search "more frames)" line))))))

;;; --- Integration Tests: Condition Serialization ---

(5am:test test-integration-json-condition
  "Full pipeline: bark:error with a condition field, JSON formatter."
  (bark:with-captured-logs (get-logs #'json-formatter)
    (let ((c (make-condition 'simple-error :format-control "db down")))
      (bark:error "query failed" :err c)
      (let* ((lines (funcall get-logs))
             (parsed (yason:parse (first lines))))
        (5am:is (= 1 (length lines)))
        ;; err is a JSON object with type and msg
        (let ((err (gethash "err" parsed)))
          (5am:is (hash-table-p err))
          (5am:is (string= "simple-error" (gethash "type" err)))
          (5am:is (string= "db down" (gethash "msg" err))))
        ;; Top-level msg is the log message
        (5am:is (string= "query failed" (gethash "msg" parsed)))))))

(5am:test test-integration-json-captured-error
  "Full pipeline: bark:error with captured-error field, JSON formatter."
  (bark:with-captured-logs (get-logs #'json-formatter)
    (let ((c (make-condition 'simple-error :format-control "db down")))
      (bark:error "query failed" :err (bark:capture c))
      (let* ((lines (funcall get-logs))
             (parsed (yason:parse (first lines)))
             (err (gethash "err" parsed)))
        (5am:is (hash-table-p err))
        (5am:is (string= "simple-error" (gethash "type" err)))
        (5am:is (listp (gethash "stack" err)))))))

(5am:test test-integration-logfmt-condition
  "Full pipeline: bark:error with a condition field, logfmt formatter."
  (bark:with-captured-logs (get-logs #'logfmt-formatter)
    (let ((c (make-condition 'simple-error :format-control "db down")))
      (bark:error "query failed" :err c)
      (let ((line (first (funcall get-logs))))
        (5am:is-true (search "err=\"simple-error: db down\"" line))))))

(5am:test test-integration-custom-condition
  "Custom condition class serializes with correct type name."
  (bark:with-captured-logs (get-logs #'json-formatter)
    (eval '(define-condition bark-tests::test-condition (cl:error)
             ((detail :initarg :detail :reader bark-tests::test-condition-detail))
             (:report (lambda (c s) (format s "detail: ~a" (bark-tests::test-condition-detail c))))))
    (let ((c (make-condition 'bark-tests::test-condition :detail "oops")))
      (bark:error "custom" :err c)
      (let* ((parsed (yason:parse (first (funcall get-logs))))
             (err (gethash "err" parsed)))
        (5am:is (string= "test-condition" (gethash "type" err)))
        (5am:is (string= "detail: oops" (gethash "msg" err)))))))

;;; --- Context Path Tests: Condition in Child/Dynamic Context ---

(5am:test test-condition-in-child-bindings-json
  "Condition in child logger static bindings serializes correctly in JSON.
   Child bindings are pre-serialized into chindings at child creation time."
  (bark:with-captured-logs (get-logs #'json-formatter)
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:child bark:*logger* :boot-err c)))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let* ((parsed (yason:parse (first (funcall get-logs))))
               (err (gethash "boot-err" parsed)))
          (5am:is (hash-table-p err))
          (5am:is (string= "simple-error" (gethash "type" err))))))))

(5am:test test-condition-in-child-bindings-logfmt
  "Condition in child logger raw-bindings serializes correctly in logfmt.
   raw-bindings carry the live condition object, serialized at log time."
  (bark:with-captured-logs (get-logs #'logfmt-formatter)
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:child bark:*logger* :boot-err c)))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let ((line (first (funcall get-logs))))
          (5am:is-true (search "boot-err=\"simple-error: startup err\"" line)))))))

(5am:test test-condition-in-child-bindings-pretty
  "Condition in child logger raw-bindings serializes correctly in pretty.
   raw-bindings carry the live condition object, serialized at log time."
  (bark:with-captured-logs (get-logs #'pretty-formatter)
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:child bark:*logger* :boot-err c)))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let ((line (first (funcall get-logs))))
          (5am:is-true (search "simple-error: startup err" line)))))))

(5am:test test-condition-in-dynamic-context
  "Condition in with-context serializes correctly."
  (bark:with-captured-logs (get-logs #'json-formatter)
    (let ((c (make-condition 'simple-error :format-control "ctx err")))
      (bark:with-context (:last-err c)
        (bark:info "status check")
        (let* ((parsed (yason:parse (first (funcall get-logs))))
               (err (gethash "last-err" parsed)))
          (5am:is (hash-table-p err))
          (5am:is (string= "simple-error" (gethash "type" err))))))))

;;; --- Field Transform: Redaction ---

(5am:test test-field-transform-drop-per-call
  "Field transform drops per-call fields when returning (values nil nil)."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'json-formatter :output out
                          :field-transform (lambda (key value)
                                            (if (eq key :secret)
                                                (values nil nil)
                                                value)))))
      (funcall (logger-info-fn l) l "login" :user "alice" :secret "hunter2"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"user\":\"alice\"" result))
      (5am:is-false (search "secret" result))
      (5am:is-false (search "hunter2" result)))))

(5am:test test-field-transform-mask-value
  "Field transform masks a value by returning a replacement."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'json-formatter :output out
                          :field-transform (lambda (key value)
                                            (if (eq key :token)
                                                "****"
                                                value)))))
      (funcall (logger-info-fn l) l "auth" :token "abc-secret-123" :method "oauth"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"token\":\"****\"" result))
      (5am:is-false (search "abc-secret-123" result))
      (5am:is-true (search "\"method\":\"oauth\"" result)))))

(5am:test test-field-transform-passthrough
  "Field transform returning value unchanged is a no-op."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'json-formatter :output out
                          :field-transform (lambda (key value)
                                            (declare (ignore key))
                                            value))))
      (funcall (logger-info-fn l) l "msg" :a 1 :b "two"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"a\":1" result))
      (5am:is-true (search "\"b\":\"two\"" result)))))

(5am:test test-field-transform-on-dynamic-context
  "Field transform applies to dynamic context fields."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'json-formatter :output out
                          :field-transform (lambda (key value)
                                            (if (eq key :password)
                                                (values nil nil)
                                                value)))))
      (let ((*logger* l)
            (*log-context* (list (cons :request-id "req-1") (cons :password "secret"))))
        (funcall (logger-info-fn l) l "request" :path "/api")))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"request-id\":\"req-1\"" result))
      (5am:is-false (search "password" result))
      (5am:is-false (search "secret" result))
      (5am:is-true (search "\"path\":\"/api\"" result)))))

(5am:test test-field-transform-on-child-static-bindings
  "Field transform applies to child logger static bindings at creation time."
  (let ((out (make-string-output-stream)))
    (let* ((parent (make-logger :level :info :formatter #'json-formatter :output out
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:child parent :component "auth" :secret "key-abc")))
      (funcall (logger-info-fn ch) ch "hello"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"component\":\"auth\"" result))
      (5am:is-false (search "secret" result))
      (5am:is-false (search "key-abc" result)))))

(5am:test test-field-transform-nil-means-no-transform
  "A nil field-transform slot means no transformation (default)."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'json-formatter :output out)))
      (5am:is (null (logger-field-transform l)))
      (funcall (logger-info-fn l) l "msg" :key "val"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"key\":\"val\"" result)))))

(5am:test test-field-transform-inherited-by-child
  "Child inherits parent's field-transform."
  (let ((out (make-string-output-stream)))
    (let* ((parent (make-logger :level :info :formatter #'json-formatter :output out
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:child parent :component "db")))
      (funcall (logger-info-fn ch) ch "query" :sql "SELECT 1" :secret "pw"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"sql\":\"SELECT 1\"" result))
      (5am:is-false (search "secret" result)))))

(5am:test test-field-transform-child-compose
  "Child can add its own field-transform, composed with parent's."
  (let ((out (make-string-output-stream)))
    (let* ((parent (make-logger :level :info :formatter #'json-formatter :output out
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:child parent :component "auth"
                                  :field-transform (lambda (key value)
                                                     (if (eq key :token)
                                                         "****"
                                                         value)))))
      (funcall (logger-info-fn ch) ch "login" :user "alice" :secret "pw" :token "xyz"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"user\":\"alice\"" result))
      (5am:is-false (search "secret" result))
      (5am:is-true (search "\"token\":\"****\"" result))
      (5am:is-false (search "xyz" result)))))

(5am:test test-compose-field-transforms-nil-cases
  "compose-field-transforms handles nil inputs correctly."
  (let ((xform (lambda (k v) (declare (ignore k)) (string-upcase v))))
    (5am:is (null (compose-field-transforms nil nil)))
    (5am:is (eq xform (compose-field-transforms xform nil)))
    (5am:is (eq xform (compose-field-transforms nil xform)))))

(5am:test test-field-transform-with-logfmt
  "Field transform works with logfmt formatter too."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter #'logfmt-formatter :output out
                          :field-transform (lambda (key value)
                                            (if (eq key :password)
                                                (values nil nil)
                                                value)))))
      (funcall (logger-info-fn l) l "login" :user "alice" :password "secret"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "user=alice" result))
      (5am:is-false (search "password" result))
      (5am:is-false (search "secret" result)))))

;;; --- Timestamp override ---

(5am:test test-current-log-timestamp-ms-returns-integer
  "current-log-timestamp-ms returns a positive integer."
  (let ((ts (current-log-timestamp-ms)))
    (5am:is (integerp ts))
    (5am:is (plusp ts))))

(5am:test test-override-timestamp-used-when-bound
  "*override-timestamp* overrides current-log-timestamp-ms."
  (let ((*override-timestamp* 1234567890))
    (5am:is (= 1234567890 (current-log-timestamp-ms)))))

(5am:test test-override-timestamp-nil-uses-wall-clock
  "*override-timestamp* nil falls through to wall clock."
  (let ((*override-timestamp* nil))
    (5am:is (plusp (current-log-timestamp-ms)))))

(5am:test test-override-timestamp-in-json-output
  "JSON formatter uses *override-timestamp* when bound."
  (let* ((out (make-string-output-stream))
         (l (make-logger :level :info :formatter #'json-formatter :output out)))
    (let ((bark::*override-timestamp* 9999999))
      (funcall (logger-info-fn l) l "test"))
    (let* ((line (get-output-stream-string out))
           (json (yason:parse line)))
      (5am:is (= 9999999 (gethash "ts" json))))))
