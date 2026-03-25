;;; tests/tests.lisp — cl-bark tests using FiveAM

(defpackage #:bark-tests
  (:use #:cl)
  (:shadowing-import-from #:bark #:formatter)
  (:import-from #:bark
   ;; Level constants and helpers
   #:+trace+ #:+debug+ #:+info+ #:+warn+ #:+error+ #:+fatal+
   #:level-from-keyword #:level-name
   ;; Struct accessors
   #:logger-p #:logger-level #:logger-formatter
   #:logger-output #:logger-context #:logger-prepared
   #:logger-trace-fn #:logger-debug-fn #:logger-info-fn
   #:logger-warn-fn #:logger-error-fn #:logger-fatal-fn
   ;; Formatter protocol
   #:make-formatter #:formatter-p #:formatter-prepare-fn #:formatter-format-fn
   #:make-json-formatter #:make-logfmt-formatter #:make-pretty-formatter
   ;; JSON/serialization internals
   #:emit-json-value #:emit-json-fields #:emit-json-key
   #:emit-logfmt-value #:emit-logfmt-key
   #:*max-json-depth* #:*max-json-length*
   #:*max-pretty-depth* #:*max-pretty-length*
   #:write-json-escaped-string #:serialize-bindings-json
   #:make-concat-prepare-fn
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
   ;; Buffer entry
   #:make-buffer-entry
   #:buffer-entry-level #:buffer-entry-message
   #:buffer-entry-fields #:buffer-entry-context #:buffer-entry-timestamp
   #:make-buffer-logger
   #:flush-buffer
   #:with-log-buffer
   ;; Field transform
   #:logger-field-transform #:compose-field-transforms
   ;; Public API (non-conflicting)
   #:make-logger #:make-child #:set-level #:stop
   #:set-level-sampling #:set-consistent
   #:make-windowed-counter #:make-level-sampler #:make-consistent-sampler
   #:windowed-counter-window-ticks
   #:json-formatter #:logfmt-formatter #:pretty-formatter
   #:make-json-formatter #:make-logfmt-formatter #:make-pretty-formatter
   #:with-captured-logs #:with-context
   #:*logger* #:*log-context*))

(in-package #:bark-tests)

(5am:def-suite bark-tests
  :description "Comprehensive test suite for the cl-bark logging library.")

(5am:in-suite bark-tests)

;;; --- Test utilities ---

(defun sync-output (stream)
  "Wrap STREAM in a function for synchronous log delivery in tests.
   Use this with make-logger to avoid async wrapping when testing
   formatting, filtering, and other non-async concerns."
  (lambda (line) (write-string line stream) (terpri stream)))

;;; --- Levels ---

(5am:test test-level-constants
  "Verify all level constant values."
  (5am:is (= 1 +trace+))
  (5am:is (= 2 +debug+))
  (5am:is (= 3 +info+))
  (5am:is (= 4 +warn+))
  (5am:is (= 5 +error+))
  (5am:is (= 6 +fatal+)))

(5am:test test-level-from-keyword
  "Test level-from-keyword for all keywords and invalid input."
  (5am:is (= 1 (level-from-keyword :trace)))
  (5am:is (= 2 (level-from-keyword :debug)))
  (5am:is (= 3 (level-from-keyword :info)))
  (5am:is (= 4 (level-from-keyword :warn)))
  (5am:is (= 5 (level-from-keyword :error)))
  (5am:is (= 6 (level-from-keyword :fatal)))
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

(5am:test test-json-escape-non-simple-string
  "Non-simple strings (adjustable, fill-pointer) must not signal type errors.
Regression: yason returns (VECTOR CHARACTER N) which is not SIMPLE-STRING."
  (let* ((adjustable (make-array 10 :element-type 'character
                                    :adjustable t :fill-pointer 0))
         (_ (loop for c across "hello" do (vector-push-extend c adjustable)))
         (result (with-output-to-string (s)
                   (write-json-escaped-string adjustable s))))
    (declare (ignore _))
    (5am:is (string= "hello" result))))

(5am:test test-emit-json-value-non-simple-string
  "Non-simple strings passed through emit-json-value must work end-to-end."
  (let* ((adjustable (make-array 10 :element-type 'character
                                    :adjustable t :fill-pointer 0))
         (_ (loop for c across "test" do (vector-push-extend c adjustable)))
         (r (with-output-to-string (s) (emit-json-value s adjustable))))
    (declare (ignore _))
    (5am:is (string= "\"test\"" r))))

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
  (let ((r (serialize-bindings-json(list :service "web" :version 2))))
    (5am:is-true (stringp r))
    (5am:is-true (search "service" r))
    (5am:is-true (search "web" r))
    (5am:is-true (search "version" r))
    (5am:is-true (search "2" r))))

(5am:test test-make-concat-prepare-fn
  "Test make-concat-prepare-fn returns a prepare-fn that serializes and concatenates."
  (let ((prepare (make-concat-prepare-fn #'serialize-bindings-json)))
    ;; Root call: parent-prepared is nil
    (let ((result (funcall prepare nil (list :service "web"))))
      (5am:is-true (stringp result))
      (5am:is-true (search "service" result))
      (5am:is-true (search "web" result)))
    ;; Child call: concatenate with parent
    (let* ((parent (funcall prepare nil (list :service "web")))
           (child (funcall prepare parent (list :request-id "abc"))))
      (5am:is-true (search "service" child))
      (5am:is-true (search "request-id" child)))
    ;; No delta context: returns parent or empty string
    (5am:is (string= "" (funcall prepare nil nil)))
    (let ((parent (funcall prepare nil (list :k "v"))))
      (5am:is (string= parent (funcall prepare parent nil))))))

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
  "Hash-tables with non-string/symbol/pathname keys use princ-to-string."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash 42 h) "the-answer")
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      (5am:is (string= "{\"42\":\"the-answer\"}" r)))))

(5am:test test-emit-json-value-hash-table-integer-keys-no-collision
  "Distinct integer hash keys produce distinct JSON keys, not colliding type names."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash 42 h) "a" (gethash 99 h) "b")
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      ;; Both keys must appear with their actual values
      (5am:is-true (search "\"42\"" r))
      (5am:is-true (search "\"99\"" r))
      ;; Both values must be present (no collision/overwrite)
      (5am:is-true (search "\"a\"" r))
      (5am:is-true (search "\"b\"" r))
      ;; Must be valid JSON
      (5am:is (hash-table-p (yason:parse r))))))

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
    (let ((l (bark:make-logger :level :info :formatter (make-logfmt-formatter) :output (sync-output out))))
      (funcall (bark::logger-info-fn l) l "msg" :verbose t :count 42))
    (let ((s (get-output-stream-string out)))
      ;; Should have bare "verbose" without "=true"
      (5am:is-true (search " verbose " s))
      (5am:is-false (search "verbose=" s))
      ;; Other fields should still have =
      (5am:is-true (search "count=42" s)))))

;;; --- Logger ---

(5am:test test-make-logger
  "Create a logger with make-logger, verify level and formatter."
  (let ((lgr (make-logger :context '(:name "myapp") :level :debug :formatter (make-json-formatter))))
    (5am:is-true (logger-p lgr))
    (5am:is (= +debug+ (logger-level lgr)))
    (5am:is (formatter-p (logger-formatter lgr)))))

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
  (let ((lgr (make-logger :level 7)))
    (5am:is (eq #'noop (logger-trace-fn lgr)))
    (5am:is (eq #'noop (logger-debug-fn lgr)))
    (5am:is (eq #'noop (logger-info-fn lgr)))
    (5am:is (eq #'noop (logger-warn-fn lgr)))
    (5am:is (eq #'noop (logger-error-fn lgr)))
    (5am:is (eq #'noop (logger-fatal-fn lgr)))))

;;; --- Level Predicate ---

(5am:test test-level-enabled-p-basic
  "level-enabled-p returns T for enabled levels, NIL for disabled."
  (let ((lgr (make-logger :level :info)))
    (5am:is-true (bark:level-enabled-p lgr :info))
    (5am:is-true (bark:level-enabled-p lgr :warn))
    (5am:is-true (bark:level-enabled-p lgr :error))
    (5am:is-true (bark:level-enabled-p lgr :fatal))
    (5am:is-false (bark:level-enabled-p lgr :debug))
    (5am:is-false (bark:level-enabled-p lgr :trace))))

(5am:test test-level-enabled-p-nil-logger
  "level-enabled-p returns NIL when logger is nil."
  (5am:is-false (bark:level-enabled-p nil :info))
  (5am:is-false (bark:level-enabled-p nil :debug)))

(5am:test test-level-enabled-p-reflects-set-level
  "level-enabled-p reflects runtime level changes via set-level."
  (let ((lgr (make-logger :level :info)))
    (5am:is-false (bark:level-enabled-p lgr :debug))
    (bark:set-level lgr :debug)
    (5am:is-true (bark:level-enabled-p lgr :debug))))

(5am:test test-level-enabled-p-invalid-level
  "level-enabled-p signals type-error for invalid level keyword."
  (let ((lgr (make-logger :level :info)))
    (5am:signals type-error (bark:level-enabled-p lgr :bogus))))

(5am:test test-child-logger
  "Create parent with prepared context, create child with more bindings, verify concatenation."
  (let* ((parent (make-logger :context '(:name "parent") :level :trace))
         (parent-with-bindings (make-child parent :context '(:service "web")))
         (ch (make-child parent-with-bindings :context '(:request-id "abc"))))
    (5am:is-true (search "service" (logger-prepared ch)))
    (5am:is-true (search "web" (logger-prepared ch)))
    (5am:is-true (search "request-id" (logger-prepared ch)))
    (5am:is-true (search "abc" (logger-prepared ch)))
    (5am:is (eq (logger-formatter parent-with-bindings) (logger-formatter ch)))
    (5am:is (eq (logger-output parent-with-bindings) (logger-output ch)))))

(5am:test test-prepared-slot-types
  "Non-tee logger has string prepared; tee logger has simple-vector prepared."
  ;; Non-tee: string
  (let ((lgr (make-logger :context '(:service "web") :level :info)))
    (5am:is (stringp (logger-prepared lgr))))
  ;; Tee: simple-vector
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter (make-json-formatter))
               (s2 :formatter (make-logfmt-formatter)))))
    (unwind-protect
         (let ((lgr (make-logger :context '(:service "web") :level :info :output tee)))
           (5am:is (simple-vector-p (logger-prepared lgr)))
           (5am:is (= 2 (length (logger-prepared lgr))))
           ;; Each element is a string
           (5am:is (stringp (aref (logger-prepared lgr) 0)))
           (5am:is (stringp (aref (logger-prepared lgr) 1))))
      (stop-tee tee))))

(5am:test test-child-context
  "Create parent with context, create child, verify context are appended."
  (let* ((parent (make-logger :context '(:name "parent") :level :trace))
         (p1 (make-child parent :context '(:a 1 :b 2)))
         (ch (make-child p1 :context '(:c 3))))
    (let ((rb (logger-context ch)))
      (5am:is-true (not (null rb)))
      (5am:is (= 1 (getf rb :a)))
      (5am:is (= 2 (getf rb :b)))
      (5am:is (= 3 (getf rb :c))))))

(5am:test test-named-logger-json
  "Verify logger name appears in JSON output."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((*logger* (make-logger :context '(:name "myapp") :level :info
                                  :formatter (make-json-formatter)
                                  :output collector)))
      (bark:info "hello")
      (let ((line (first (funcall results-fn))))
        (5am:is-true (search "\"name\":\"myapp\"" line))))))

;;; --- Formatters ---

(5am:test test-json-formatter-basic
  "Use json-formatter directly, verify output has level, ts, msg keys."
  (let ((output (json-formatter +info+ "" nil "hello world" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search "\"level\"" output))
    (5am:is-true (search "\"ts\"" output))
    (5am:is-true (search "\"msg\"" output))
    (5am:is-true (search "hello world" output))
    (5am:is-true (search "\"level\":\"info\"" output))))

(5am:test test-json-formatter-with-fields
  "Test json-formatter with per-call fields."
  (let ((output (json-formatter +warn+ "" nil "oops" (list :code 404 :path "/api"))))
    (5am:is-true (search "code" output))
    (5am:is-true (search "404" output))
    (5am:is-true (search "path" output))
    (5am:is-true (search "/api" output))))

(5am:test test-json-formatter-with-context
  "Test json-formatter with context alist."
  (let ((output (json-formatter +info+ "" '((:request-id . "xyz")) "ctx test" nil)))
    (5am:is-true (search "request-id" output))
    (5am:is-true (search "xyz" output))))

(5am:test test-json-formatter-with-prepared
  "Test json-formatter with pre-serialized context."
  (let* ((prepared (serialize-bindings-json (list :service "api" :version 3)))
         (output (json-formatter +debug+ prepared nil "context test" nil)))
    (5am:is-true (search "service" output))
    (5am:is-true (search "api" output))
    (5am:is-true (search "version" output))
    (5am:is-true (search "3" output))))

(5am:test test-logfmt-formatter-basic
  "Test logfmt-formatter, verify output format."
  (let ((output (logfmt-formatter +info+ "" nil "hello" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search "level=info" output))
    (5am:is-true (search "ts=" output))
    (5am:is-true (search "msg=" output))
    (5am:is-true (search "hello" output))))

(5am:test test-logfmt-formatter-with-fields
  "Test logfmt with fields, verify key=value pairs."
  (let ((output (logfmt-formatter +warn+ "" nil "warning" (list :code 500 :path "/err"))))
    (5am:is-true (search "code=500" output))
    (5am:is-true (search "path=" output))
    (5am:is-true (search "/err" output))))

(5am:test test-pretty-formatter-basic
  "Test pretty-formatter produces output with ANSI escape codes."
  (let ((output (pretty-formatter +info+ "" nil "pretty test" nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search (string #\Esc) output))
    (5am:is-true (search "pretty test" output))))

(5am:test test-pretty-formatter-print-length
  "Pretty-formatter truncates long lists via *max-pretty-length*."
  (let* ((*max-pretty-length* 3)
         (output (pretty-formatter +info+ "" nil "msg"
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
         (output (pretty-formatter +info+ "" nil "msg"
                                   (list :data '((nested))))))
    ;; CL printer uses "#" for depth truncation
    (5am:is-true (search "#" output))))

(5am:test test-pretty-formatter-print-circle
  "Pretty-formatter handles circular structures without looping."
  (let* ((circ (list 1 2 3)))
    (setf (cdr (last circ)) circ)
    ;; Should complete without hanging — *print-circle* is bound to T
    (let ((output (pretty-formatter +info+ "" nil "msg"
                                    (list :data circ))))
      (5am:is-true (stringp output))
      (5am:is-true (search "#" output)))))

(5am:test test-pretty-formatter-nil-limits
  "Pretty-formatter with NIL limits produces unlimited output."
  (let* ((*max-pretty-length* nil)
         (*max-pretty-depth* nil)
         (output (pretty-formatter +info+ "" nil "msg"
                                   (list :data '(1 2 3 4 5 6 7 8 9 10)))))
    ;; All elements should appear
    (5am:is-true (search "10" output))
    (5am:is-false (search "..." output))))

(5am:test test-dispatch-nil-formatter-falls-back-to-default
  "dispatch-to-output with nil formatter falls back to *default-json-formatter*."
  (let* ((out (make-string-output-stream))
         (lgr (make-logger :level :info
                           :output (sync-output out)
                           :formatter nil)))
    (let ((*logger* lgr))
      (bark:info "fallback test"))
    (let ((result (get-output-stream-string out)))
      ;; Should produce valid JSON via *default-json-formatter*
      (5am:is-true (search "fallback test" result))
      (5am:is-true (search "\"level\"" result)))))

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
    (let* ((lgr (make-logger :context '(:name "e2e") :level :trace :output collector))
           (ch (make-child lgr :context '(:service "api"))))
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

;;; --- Sampling: mix-hash ---

(5am:test test-mix-hash-distribution
  "mix-hash produces roughly uniform distribution across mod buckets.
   Chi-squared test: if p > 0.01, distribution is acceptably uniform."
  (dolist (rate '(2 3 5 10 100))
    (let ((buckets (make-array rate :initial-element 0))
          (n 100000))
      (dotimes (i n)
        (incf (aref buckets (mod (bark::mix-hash (sxhash i)) rate))))
      ;; Chi-squared statistic
      (let* ((expected (/ n rate))
             (chi-sq (loop for count across buckets
                           sum (/ (expt (- count expected) 2) expected))))
        ;; Critical value for p=0.01 with (rate-1) degrees of freedom.
        ;; For small rates use generous threshold; for rate=100, df=99, critical~135.
        (let ((critical (cond ((<= rate 5) 15.0)
                              ((<= rate 10) 25.0)
                              (t 150.0))))
          (5am:is-true (< chi-sq critical)
                       "mix-hash mod ~d: chi-sq=~,2f exceeds ~,2f (n=~d)"
                       rate chi-sq critical n))))))

;;; --- Sampling: windowed counter ---

(5am:test test-windowed-initial-burst
  "First INITIAL messages always pass regardless of THEREAFTER."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "wc") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 5 :thereafter 1000
                                                    :window-seconds 60)))))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 5)
          (funcall fn lgr (format nil "msg-~d" i))))
      (5am:is (= 5 (length (funcall results-fn)))))))

(5am:test test-windowed-thereafter-sampling
  "After initial burst, 1-in-THEREAFTER pass."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "wc") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 0 :thereafter 10
                                                    :window-seconds 60)))))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 1000)
          (funcall fn lgr "msg")))
      ;; initial=0, thereafter=10: count 0 passes (mod 0 10 = 0), then every 10th
      ;; Total: 100 out of 1000
      (5am:is (= 100 (length (funcall results-fn)))))))

(5am:test test-windowed-hard-cap
  "thereafter=0 drops everything after initial burst."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "wc") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 3 :thereafter 0
                                                    :window-seconds 60)))))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 100)
          (funcall fn lgr "msg")))
      (5am:is (= 3 (length (funcall results-fn)))))))

(5am:test test-windowed-initial-zero
  "initial=0 skips burst, goes straight to thereafter check."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "wc") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 0 :thereafter 5
                                                    :window-seconds 60)))))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 100)
          (funcall fn lgr "msg")))
      ;; mod 0 5 = 0 (pass), mod 5 5 = 0 (pass), ... → 20 out of 100
      (5am:is (= 20 (length (funcall results-fn)))))))

(5am:test test-windowed-window-reset
  "After window expires, counter resets and a new burst passes."
  (let ((wc (make-windowed-counter :initial 2 :thereafter 0 :window-seconds 1)))
    ;; Simulate: exhaust initial burst
    (dotimes (i 5) (atomics:atomic-incf (bark::windowed-counter-count wc)))
    ;; Force window expiry by calling with now far enough in the future
    (let ((future-now (+ (bark::windowed-counter-window-start wc)
                         (* 2 (bark::windowed-counter-window-ticks wc)))))
      (bark::maybe-reset-window wc future-now))
    (5am:is (= 0 (bark::windowed-counter-count wc)))))

(5am:test test-windowed-amortized-clock-check
  "Window reset only happens on +window-check-interval+ boundaries."
  (let ((wc (make-windowed-counter :initial 1000 :thereafter 0 :window-seconds 1)))
    ;; Counts 1..63 should NOT trigger reset (interval check uses logand)
    (dotimes (i 63)
      (atomics:atomic-incf (bark::windowed-counter-count wc)))
    ;; Count is now 63, window-start still original
    (let ((old-ws (bark::windowed-counter-window-start wc))
          (future-now (+ (bark::windowed-counter-window-start wc)
                         (* 2 (bark::windowed-counter-window-ticks wc)))))
      ;; Simulate the 64th message (count becomes 64, logand with 63 = 0)
      (let ((count (atomics:atomic-incf (bark::windowed-counter-count wc))))
        (when (zerop (logand count (1- bark::+window-check-interval+)))
          (bark::maybe-reset-window wc future-now)))
      ;; Now window-start should have been updated
      (5am:is-true (/= old-ws (bark::windowed-counter-window-start wc))))))

;;; --- Sampling: consistent sampler ---

(5am:test test-consistent-deterministic
  "Same key always produces same keep/drop decision."
  (let ((rate 10)
        (key "request-abc-123"))
    (let ((decision (bark::consistent-hash-keep-p key rate)))
      (dotimes (i 100)
        (5am:is (eq decision (bark::consistent-hash-keep-p key rate)))))))

(5am:test test-consistent-nil-key-passthrough
  "key-fn returning nil falls through to windowed counter."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "cs") :level :debug :output collector
                            :consistent (make-consistent-sampler
                                         :key-fn (lambda (bindings)
                                                   (declare (ignore bindings))
                                                   nil)
                                         :rate 10)
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 3 :thereafter 0
                                                    :window-seconds 60)))))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 100)
          (funcall fn lgr "msg")))
      ;; nil key → consistent skipped → windowed: initial=3, thereafter=0
      (5am:is (= 3 (length (funcall results-fn)))))))

(5am:test test-consistent-rate-1-keeps-all
  "rate=1 keeps every message (mod hash 1 = 0 always)."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "cs") :level :debug :output collector
                            :consistent (make-consistent-sampler
                                         :key-fn (lambda (bindings)
                                                   (getf bindings :rid))
                                         :rate 1))))
      (let ((child-lgr (make-child lgr :context '(:rid "test-key"))))
        (let ((fn (logger-debug-fn child-lgr)))
          (dotimes (i 50)
            (funcall fn child-lgr "msg"))))
      (5am:is (= 50 (length (funcall results-fn)))))))

;;; --- Sampling: constructors ---

(5am:test test-make-level-sampler-layout
  "make-level-sampler produces correct vector layout."
  (let* ((wc-debug (make-windowed-counter :initial 5 :thereafter 100))
         (wc-trace (make-windowed-counter :initial 2 :thereafter 50))
         (ls (make-level-sampler :debug wc-debug :trace wc-trace)))
    (5am:is (= 7 (length ls)))
    (5am:is (null (aref ls 0)))        ; index 0 unused
    (5am:is (eq wc-trace (aref ls 1))) ; trace = index 1
    (5am:is (eq wc-debug (aref ls 2))) ; debug = index 2
    (5am:is (null (aref ls 3)))        ; info = nil
    (5am:is (null (aref ls 4)))        ; warn = nil
    (5am:is (null (aref ls 5)))        ; error = nil
    (5am:is (null (aref ls 6)))))      ; fatal = nil

(5am:test test-make-level-sampler-type-check
  "make-level-sampler rejects non-windowed-counter arguments."
  (5am:signals cl:error (make-level-sampler :debug 42))
  (5am:signals cl:error (make-level-sampler :trace "not-a-counter")))

(5am:test test-make-windowed-counter-ticks
  "window-ticks computed correctly from window-seconds."
  (let ((wc (make-windowed-counter :window-seconds 2)))
    (5am:is (= (* 2 internal-time-units-per-second)
               (windowed-counter-window-ticks wc)))))

(5am:test test-make-consistent-sampler-rate-zero
  "make-consistent-sampler rejects rate=0."
  (5am:signals cl:error
    (make-consistent-sampler :key-fn (lambda (b) (declare (ignore b)) nil)
                             :rate 0)))

;;; --- Sampling: integration ---

(5am:test test-both-nil-zero-sampling
  "When both sampler slots are nil, all messages pass."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "nil") :level :debug :output collector)))
      (5am:is (null (bark::logger-level-sampler lgr)))
      (5am:is (null (bark::logger-consistent lgr)))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 100)
          (funcall fn lgr "msg")))
      (5am:is (= 100 (length (funcall results-fn)))))))

(5am:test test-consistent-bypasses-windowed
  "Key-bearing messages bypass windowed counter; keyless messages use windowed."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let* ((lgr (make-logger :context '(:name "both") :level :debug :output collector
                             :consistent (make-consistent-sampler
                                          :key-fn (lambda (b) (getf b :rid))
                                          :rate 1)  ; rate=1 keeps all keyed
                             :level-sampler (make-level-sampler
                                             :debug (make-windowed-counter
                                                     :initial 0 :thereafter 0
                                                     :window-seconds 60)))))
      ;; Keyless messages: windowed initial=0 thereafter=0 → drop all
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 50)
          (funcall fn lgr "keyless")))
      ;; Keyed messages: consistent rate=1 → keep all (bypass windowed)
      (let* ((keyed-lgr (make-child lgr :context '(:rid "test-key")))
             (fn (logger-debug-fn keyed-lgr)))
        (dotimes (i 50)
          (funcall fn keyed-lgr "keyed")))
      (let ((logs (funcall results-fn)))
        ;; Only the 50 keyed messages should pass
        (5am:is (= 50 (length logs)))))))

(5am:test test-buffer-bypasses-sampling
  "with-log-buffer captures all messages regardless of sampling."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "buf") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 0 :thereafter 0
                                                    :window-seconds 60)))))
      ;; Without buffer: everything dropped (initial=0 thereafter=0)
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 10)
          (funcall fn lgr "direct")))
      (5am:is (= 0 (length (funcall results-fn))))
      ;; With buffer: everything captured (sampling bypassed)
      (let ((bark:*logger* lgr)
            (bark::*root-logger* nil))
        (bark:with-log-buffer (bark:*logger* :level :debug)
          (dotimes (i 10)
            (bark:debug "buffered"))))
      ;; Buffer flushes at original level (:debug), all 10 should pass
      (5am:is (= 10 (length (funcall results-fn)))))))

(5am:test test-child-inherits-level-sampler
  "Child shares parent's level-sampler vector; in-place mutations visible."
  (let* ((lgr (make-logger :context '(:name "par") :level :debug
                           :level-sampler (make-level-sampler
                                           :debug (make-windowed-counter
                                                   :initial 5 :thereafter 100))))
         (ch (make-child lgr :context '(:component "child"))))
    ;; Same vector object
    (5am:is (eq (bark::logger-level-sampler lgr) (bark::logger-level-sampler ch)))
    ;; In-place mutation via set-level-sampling on parent visible to child
    (let ((new-wc (make-windowed-counter :initial 10 :thereafter 50)))
      (set-level-sampling lgr :debug new-wc)
      (5am:is (eq new-wc (aref (bark::logger-level-sampler ch) 2))))))

(5am:test test-child-snapshots-consistent
  "Child snapshots parent's consistent sampler; parent changes don't propagate."
  (let* ((cs (make-consistent-sampler
              :key-fn (lambda (b) (getf b :rid)) :rate 10))
         (lgr (make-logger :context '(:name "par") :level :debug :consistent cs))
         (ch (make-child lgr :context '(:component "child"))))
    (5am:is (eq cs (bark::logger-consistent ch)))
    ;; Replace on parent
    (set-consistent lgr nil)
    ;; Child still has original
    (5am:is (eq cs (bark::logger-consistent ch)))))

(5am:test test-set-level-sampling-runtime-swap
  "Replacing sampler via set-level-sampling takes effect on next log call."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "swap") :level :debug :output collector
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 0 :thereafter 0
                                                    :window-seconds 60)))))
      ;; All dropped initially
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 10) (funcall fn lgr "dropped")))
      (5am:is (= 0 (length (funcall results-fn))))
      ;; Swap to permissive counter
      (set-level-sampling lgr :debug
                          (make-windowed-counter :initial 1000 :thereafter 0
                                                :window-seconds 60))
      (let ((fn (logger-debug-fn lgr)))
        (dotimes (i 10) (funcall fn lgr "passed")))
      (5am:is (= 10 (length (funcall results-fn)))))))

(5am:test test-start-with-sampling
  "make-logger creates a logger that respects sampling args."
  (let ((out (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :output out :level :debug :context '(:name "samp-start")
                                          :level-sampler (make-level-sampler
                                                          :debug (make-windowed-counter
                                                                  :initial 3 :thereafter 0
                                                                  :window-seconds 60))))
    (unwind-protect
         (let ((fn (logger-debug-fn bark:*logger*)))
           (dotimes (i 10) (funcall fn bark:*logger* "msg"))
           (bark:flush bark:*logger*)
           (let* ((output (get-output-stream-string out))
                  (lines (remove "" (uiop:split-string output :separator '(#\Newline))
                                 :test #'string=)))
             (5am:is (= 3 (length lines)))))
      (bark:stop bark:*logger*))))

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

(5am:test test-flush-async-output-concurrent
  "Concurrent flush-async-output calls must all complete without hanging."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64))
         (threads nil)
         (all-flushed (bt:make-semaphore :name "all-flushed")))
    ;; Launch 4 threads that all flush concurrently
    (dotimes (i 4)
      (push (bt:make-thread
             (lambda ()
               (bark::ring-buffer-push (bark::async-output-ring ao)
                                       (format nil "msg-~d" i))
               (bt:signal-semaphore (bark::async-output-notify ao))
               (bark::flush-async-output ao)
               (bt:signal-semaphore all-flushed))
             :name (format nil "flusher-~d" i))
            threads))
    ;; All 4 must complete within 2 seconds (not 5s timeout each)
    (dotimes (i 4)
      (5am:is-true (bt:wait-on-semaphore all-flushed :timeout 2.0)
                   "Flush ~d timed out — flush-ack race" i))
    (dolist (th threads) (bt:join-thread th))
    (bark::stop-async-output ao)))

;;; --- Helpers ---

(defun stop-tee (tee-output)
  "Stop all async outputs in a tee-output. For test cleanup."
  (loop for group across (tee-output-groups tee-output)
        do (loop for dest across (formatter-group-destinations group)
                 do (bark::stop-async-output (destination-async-output dest)))))

(defun log-at (logger-level msg-level &optional (fmt (make-json-formatter)))
  "Create a logger at LOGGER-LEVEL, fire one message at MSG-LEVEL, return output string."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level logger-level :formatter fmt :output (sync-output out))))
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

(defun log-to-string (level &optional (formatter (make-json-formatter)))
  "Log one message at LEVEL with FORMATTER, return output string."
  (log-at level level formatter))

;;; --- JSON Level Numbers ---

(5am:test test-json-level-numbers
  "All 6 levels emit the correct level name string in JSON output."
  (loop for (kw expected) in '((:trace "trace") (:debug "debug") (:info "info")
                                (:warn "warn") (:error "error") (:fatal "fatal"))
        do (let* ((line (log-to-string kw (make-json-formatter)))
                  (level (gethash "level" (yason:parse line))))
             (5am:is (string= expected level)))))

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
  (let* ((s (log-at :info :info (make-json-formatter)))
         (p (yason:parse s)))
    (5am:is-true (hash-table-p p))
    (5am:is-true (stringp (gethash "level" p)))
    (5am:is-true (integerp (gethash "ts"    p)))
    (5am:is-true (stringp  (gethash "msg"   p))))
  ;; Logfmt: key=value structure, contains level= and msg=
  (let ((s (log-at :info :info (make-logfmt-formatter))))
    (5am:is-true (search "level=info" s))
    (5am:is-true (search "msg="       s))
    (5am:is-true (search "ts="        s)))
  ;; Pretty: contains ANSI escape codes and the message text
  (let ((s (log-at :info :info (make-pretty-formatter))))
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
    (let ((child (bark:make-child bark:*logger* :context '(:component "db" :pool 5))))
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
    (let ((l (bark:make-logger :level :trace :formatter (make-json-formatter) :output (sync-output out))))
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
  "make-logger creates an async-backed logger; stop flushes all pending messages."
  (let ((out (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :output out :level :info :capacity 64))
    (bark:info "integration-test-msg")
    (bark:stop bark:*logger*)
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
    (let ((l (bark:make-logger :level :info :formatter (make-logfmt-formatter) :output (sync-output out))))
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
  (bark:with-captured-logs (logs (make-logfmt-formatter))
    (bark:info "hi")
    (let ((line (first (funcall logs))))
      (5am:is (search "level=info" line))))
  ;; Explicit pretty
  (bark:with-captured-logs (logs (make-pretty-formatter))
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
      ;; Verify each level name in order
      (5am:is (search "\"level\":\"trace\"" (nth 0 lines)))
      (5am:is (search "\"level\":\"debug\"" (nth 1 lines)))
      (5am:is (search "\"level\":\"info\""  (nth 2 lines)))
      (5am:is (search "\"level\":\"warn\""  (nth 3 lines)))
      (5am:is (search "\"level\":\"error\"" (nth 4 lines)))
      (5am:is (search "\"level\":\"fatal\"" (nth 5 lines))))))

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
;;; on-drop returns (values message fields) via multiple values:
;;;   message + nil    → message only, formatted at warn level
;;;   message + fields → message + extra fields
;;;   nil + fields     → fields only, no message
;;;   nil              → suppress entirely

(5am:test test-async-drop-warning
  "Default on-drop produces a formatted JSON line with level, timestamp, and message."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (ao (bark::make-async-output out :capacity 16 :formatter fmt)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 5)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Message content preserved
      (5am:is (search "dropped 5 log messages" result))
      ;; Formatted via the formatter with level and msg
      (5am:is (search "\"level\":" result))
      (5am:is (search "\"msg\":" result)))))

(5am:test test-async-drop-uses-formatter-config
  "Drop warnings use the configured formatter's keys and format."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil :level-key "severity" :message-key "message"))
         (ao (bark::make-async-output out :capacity 16 :formatter fmt)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 3)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Uses custom keys from formatter
      (5am:is (search "\"severity\":" result))
      (5am:is (search "\"message\":" result)))))

(5am:test test-async-drop-with-timestamp
  "Drop warnings include timestamp when formatter is configured with one."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp :unix-ms))
         (ao (bark::make-async-output out :capacity 16 :formatter fmt)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 2)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Timestamp present in drop warning
      (5am:is (search "\"ts\":" result))
      (5am:is (search "\"level\":" result))
      (5am:is (search "\"msg\":" result)))))

(5am:test test-async-drop-with-logfmt-formatter
  "Drop warnings use the logfmt formatter when configured."
  (let* ((out (make-string-output-stream))
         (fmt (make-logfmt-formatter :timestamp nil))
         (ao (bark::make-async-output out :capacity 16 :formatter fmt)))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 4)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Logfmt format
      (5am:is (search "level=warn" result))
      (5am:is (search "msg=" result))
      (5am:is (search "dropped 4 log messages" result)))))

(5am:test test-async-custom-on-drop-message-and-fields
  "Custom on-drop returns message + fields via multiple values."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (ao (bark::make-async-output out :capacity 16
               :formatter fmt
               :on-drop (lambda (n) (values (format nil "LOST ~d" n) (list :count n))))))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 3)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Custom message preserved
      (5am:is (search "LOST 3" result))
      ;; Extra field from on-drop
      (5am:is (search "\"count\":3" result))
      ;; Formatted via formatter
      (5am:is (search "\"level\":" result)))))

(5am:test test-async-on-drop-fields-only
  "on-drop returning (values nil fields) emits fields without message."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (ao (bark::make-async-output out :capacity 16
               :formatter fmt
               :on-drop (lambda (n) (values nil (list :dropped n :severity "backpressure"))))))
    (dotimes (i 16)
      (bark::ring-buffer-push (bark::async-output-ring ao) (format nil "msg-~d" i)))
    (dotimes (i 3)
      (bark::ring-buffer-push (bark::async-output-ring ao) "overflow"))
    (bt:signal-semaphore (bark::async-output-notify ao))
    (bark::stop-async-output ao)
    (let ((result (get-output-stream-string out)))
      ;; Fields appear in output
      (5am:is (search "\"dropped\":3" result))
      (5am:is (search "\"severity\":" result))
      (5am:is (search "backpressure" result)))))

(5am:test test-async-on-drop-nil-suppresses
  "on-drop returning NIL suppresses the warning line entirely."
  (let* ((out (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (ao (bark::make-async-output out :capacity 16
               :formatter fmt
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
               (list (list :stream s1 :formatter (make-json-formatter))
                     (list :stream s2 :formatter (make-pretty-formatter))))))
    (unwind-protect
         (progn
           (5am:is-true (tee-output-p tee))
           ;; Two different formatters -> two groups
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; Each group has one destination
           (5am:is (= 1 (length (formatter-group-destinations (aref (tee-output-groups tee) 0)))))
           (5am:is (= 1 (length (formatter-group-destinations (aref (tee-output-groups tee) 1))))))
      ;; Cleanup: stop all async outputs
      (stop-tee tee))))

(5am:test test-make-tee-shared-formatter-grouping
  "Destinations with eq formatters are grouped together."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (s3 (make-string-output-stream))
         (json-fmt (make-json-formatter))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter json-fmt)
                     (list :stream s2 :formatter (make-pretty-formatter))
                     (list :stream s3 :formatter json-fmt)))))
    (unwind-protect
         (progn
           ;; Two formatters (json shared by 2, pretty by 1) -> two groups
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; Find the json group (has 2 destinations)
           (let ((json-group (find json-fmt (tee-output-groups tee)
                                   :key #'formatter-group-formatter)))
             (5am:is-true (not (null json-group)))
             (5am:is (= 2 (length (formatter-group-destinations json-group))))))
      (stop-tee tee))))

(5am:test test-make-tee-level-filter
  "The :level shorthand creates a filter that checks >= threshold."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter (make-json-formatter) :level :error)))))
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
      (stop-tee tee))))

(5am:test test-make-tee-default-formatter
  "Omitting :formatter defaults to *default-json-formatter*."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:make-tee (list (list :stream s1)))))
    (unwind-protect
         (let ((group (aref (tee-output-groups tee) 0)))
           (5am:is (formatter-p (formatter-group-formatter group))))
      (stop-tee tee))))

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
         (custom-drop (lambda (n) (format nil "CUSTOM ~d" n)))
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
      (stop-tee tee))))

(5am:test test-tee-macro-basic
  "tee macro creates same structure as equivalent make-tee call."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter (make-json-formatter))
               (s2 :formatter (make-pretty-formatter) :level :error))))
    (unwind-protect
         (progn
           (5am:is-true (tee-output-p tee))
           (5am:is (= 2 (length (tee-output-groups tee))))
           ;; The second group should have a filter (from :level :error)
           (let* ((second-group (aref (tee-output-groups tee) 1))
                  (dest (aref (formatter-group-destinations second-group) 0)))
             (5am:is-true (not (null (destination-filter dest))))
             (5am:is-false (funcall (destination-filter dest) +info+ nil))
             (5am:is-true (funcall (destination-filter dest) +error+ nil))))
      (stop-tee tee))))

;;; --- Multi-Output: Tee Logging ---

(5am:test test-tee-mirror-two-destinations
  "Tee with two destinations: same event goes to both with different formatters."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:tee
               (s1 :formatter (make-json-formatter))
               (s2 :formatter (make-logfmt-formatter)))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "tee-test") :level :info :output tee)))
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
               (s-all    :formatter (make-json-formatter))
               (s-errors :formatter (make-json-formatter) :level :error))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "route") :level :info :output tee)))
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
               (s-all   :formatter (make-json-formatter))
               (s-audit :formatter (make-json-formatter)
                        :filter (lambda (level fields)
                                  (declare (ignore level))
                                  (getf fields :audit))))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "filter") :level :info :output tee)))
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
          (make-formatter
           :prepare-fn (formatter-prepare-fn (make-json-formatter))
           :format-fn (lambda (level prepared context message fields)
                        (incf call-count)
                        (json-formatter level prepared context message fields))))
         (s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         ;; Both destinations use the SAME formatter object
         (tee (bark:make-tee
               (list (list :stream s1 :formatter counting-fmt)
                     (list :stream s2 :formatter counting-fmt)))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "opt") :level :info :output tee)))
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
          (make-formatter
           :prepare-fn (formatter-prepare-fn (make-json-formatter))
           :format-fn (lambda (level prepared context message fields)
                        (incf call-count)
                        (json-formatter level prepared context message fields))))
         (s1 (make-string-output-stream))
         (s2 (make-string-output-stream))
         (tee (bark:make-tee
               (list (list :stream s1 :formatter counting-fmt)
                     (list :stream s2 :formatter counting-fmt :level :error)))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "opt-filter") :level :info :output tee)))
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
               (s1 :formatter (make-json-formatter))
               (s2 :formatter (make-json-formatter)))))
    (unwind-protect
         (let* ((parent (make-logger :context '(:name "parent") :level :info :output tee))
                (ch (make-child parent :context '(:component "auth"))))
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
               (s1 :formatter (make-json-formatter))
               (s2 :formatter (make-json-formatter)))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "ctx") :level :info :output tee)))
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
         (tee (bark:tee (s1 :formatter (make-json-formatter)))))
    (unwind-protect
         (let ((*logger* (make-logger :context '(:name "lvl") :level :warn :output tee)))
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
  "make-logger with :output as a plain stream wraps it in async-output."
  (let ((out (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :output out :level :info))
    (bark:info "stream test")
    (bark:stop bark:*logger*)
    (5am:is-true (search "stream test" (get-output-stream-string out)))))

(5am:test test-start-with-tee-output
  "make-logger with :output as a tee-output uses it directly."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :level :info
                                          :output (bark:tee
                                                   (s1 :formatter (make-json-formatter))
                                                   (s2 :formatter (make-pretty-formatter)))))
    (bark:info "tee start test" :key "val")
    (bark:stop bark:*logger*)
    (let ((json-out (get-output-stream-string s1))
          (pretty-out (get-output-stream-string s2)))
      (5am:is-true (search "tee start test" json-out))
      (5am:is-true (search "tee start test" pretty-out))
      (5am:is-true (search "\"msg\"" json-out)))))

(5am:test test-start-default-output
  "make-logger with no :output defaults to *error-output*."
  (let* ((out (make-string-output-stream))
         (*error-output* out))
    (setf bark:*logger* (bark:make-logger :level :info))
    (bark:info "default test")
    (bark:stop bark:*logger*)
    (5am:is-true (search "default test" (get-output-stream-string out)))))

(5am:test test-start-with-context-and-tee
  "make-logger with :context and :output tee passes context fields through."
  (let* ((s1 (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :level :info
                                          :output (bark:tee (s1 :formatter (make-json-formatter)))
                                          :context '(:name "ctx" :role "broker" :pid 123)))
    (bark:info "context tee test")
    (bark:stop bark:*logger*)
    (let ((out (get-output-stream-string s1)))
      (5am:is-true (search "context tee test" out))
      (5am:is-true (search "role" out))
      (5am:is-true (search "broker" out)))))

(5am:test test-stop-tears-down-tee
  "stop with tee output stops all writer threads."
  (let* ((s1 (make-string-output-stream))
         (s2 (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :level :info
                                          :output (bark:tee
                                                   (s1 :formatter (make-json-formatter))
                                                   (s2 :formatter (make-json-formatter)))))
    (bark:info "before stop")
    (bark:stop bark:*logger*)
    (setf bark:*logger* nil)
    ;; After stop, *logger* should be nil
    (5am:is-true (null *logger*))
    ;; Both streams should have the message
    (5am:is-true (search "before stop" (get-output-stream-string s1)))
    (5am:is-true (search "before stop" (get-output-stream-string s2)))))

(5am:test test-flush-drains-pending-messages
  "bark:flush blocks until all pending messages are written to the stream."
  (let ((out (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :level :info :output out))
    (dotimes (i 10)
      (bark:info (format nil "msg-~d" i)))
    (bark:flush bark:*logger*)
    (let ((result (get-output-stream-string out)))
      (5am:is (= 10 (count #\Newline result))
              "Expected 10 lines after flush, got ~d" (count #\Newline result)))
    (bark:stop bark:*logger*)))

(5am:test test-flush-with-tee-output
  "bark:flush drains all destinations in a tee."
  (let ((s1 (make-string-output-stream))
        (s2 (make-string-output-stream)))
    (setf bark:*logger* (bark:make-logger :level :info
                                          :output (bark:tee
                                                   (s1 :formatter (make-json-formatter))
                                                   (s2 :formatter (make-json-formatter)))))
    (bark:info "tee-flush-msg")
    (bark:flush bark:*logger*)
    (5am:is-true (search "tee-flush-msg" (get-output-stream-string s1)))
    (5am:is-true (search "tee-flush-msg" (get-output-stream-string s2)))
    (bark:stop bark:*logger*)))

(5am:test test-flush-explicit-logger
  "bark:flush on a user-created logger drains its output."
  (let* ((out (make-string-output-stream))
         (lgr (bark:make-logger :context '(:name "explicit") :level :info
                                :formatter (make-json-formatter) :output out :capacity 64)))
    (bark:info lgr "explicit-msg")
    (bark:flush lgr)
    (5am:is-true (search "explicit-msg" (get-output-stream-string out)))
    (bark:stop lgr)))

(5am:test test-flush-stopped-logger-signals-error
  "bark:flush signals an error on a stopped logger."
  (let* ((out (make-string-output-stream))
         (lgr (bark:make-logger :level :info :output out)))
    (bark:stop lgr)
    (5am:signals error (bark:flush lgr))))

;;; --- Multi-Output: Error Recovery ---

(5am:test test-on-error-stream-recovery
  "on-error returning a new stream causes the writer to swap and continue."
  (let* ((recovery-stream (make-string-output-stream))
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
      (let ((*logger* (make-logger :context '(:name "global") :level :info :output c1))
            (other   (make-logger :context '(:name "other")  :level :info :output c2)))
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
    (let ((lgr (make-logger :context '(:name "explicit") :level :trace :output collector)))
      (bark:trace lgr "t")
      (bark:debug lgr "d")
      (bark:info  lgr "i")
      (bark:warn  lgr "w")
      (bark:error lgr "e")
      (bark:fatal lgr "f")
      (let ((logs (funcall results-fn)))
        (5am:is (= 6 (length logs)))
        (5am:is-true (search "\"level\":\"trace\"" (nth 0 logs)))
        (5am:is-true (search "\"level\":\"fatal\"" (nth 5 logs)))))))

(5am:test test-explicit-logger-no-message
  "Explicit logger as sole arg emits a log entry with nil message."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "solo") :level :info :output collector)))
      (bark:info lgr)
      (let ((logs (funcall results-fn)))
        (5am:is (= 1 (length logs)))
        ;; Should have level but no msg key (nil message)
        (5am:is-true (search "\"level\":\"info\"" (first logs)))
        (5am:is-false (search "\"msg\":" (first logs)))))))

(5am:test test-explicit-logger-keyword-fields-only
  "Explicit logger with keyword fields only (no message)."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "kw") :level :info :output collector)))
      (bark:info lgr :method "GET" :status 200)
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (5am:is (= 1 (length logs)))
        (5am:is-true (search "\"method\":\"GET\"" line))
        (5am:is-true (search "\"status\":200" line))
        (5am:is-false (search "\"msg\":" line))))))

(5am:test test-explicit-logger-with-fields
  "Explicit logger receives per-call fields."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "fields") :level :info :output collector)))
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
      (let ((*logger* (make-logger :context '(:name "global") :level :info :output c1))
            (other   (make-logger :context '(:name "other")  :level :info :output c2)))
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
  (bark:with-captured-logs (get-logs (make-pretty-formatter))
    (let ((c (make-condition 'simple-error :format-control "boom")))
      (bark:error "failed" :err c)
      (let ((line (first (funcall get-logs))))
        (5am:is-true (search "simple-error: boom" line))))))

(5am:test test-pretty-captured-error-stack
  "Pretty formatter shows inline condition + indented stack trace."
  (bark:with-captured-logs (get-logs (make-pretty-formatter))
    (let ((c (make-condition 'simple-error :format-control "boom")))
      (bark:error "failed" :err (bark:capture c))
      (let ((line (first (funcall get-logs))))
        ;; Inline condition
        (5am:is-true (search "simple-error: boom" line))
        ;; Stack trace lines (ANSI bold "at" with frame call)
        (5am:is-true (search "at " line))))))

(5am:test test-pretty-stack-frame-limit
  "Pretty formatter respects *max-pretty-stack-frames*."
  (bark:with-captured-logs (get-logs (make-pretty-formatter))
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
  (bark:with-captured-logs (get-logs (make-json-formatter))
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
  (bark:with-captured-logs (get-logs (make-json-formatter))
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
  (bark:with-captured-logs (get-logs (make-logfmt-formatter))
    (let ((c (make-condition 'simple-error :format-control "db down")))
      (bark:error "query failed" :err c)
      (let ((line (first (funcall get-logs))))
        (5am:is-true (search "err=\"simple-error: db down\"" line))))))

(5am:test test-integration-custom-condition
  "Custom condition class serializes with correct type name."
  (bark:with-captured-logs (get-logs (make-json-formatter))
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
   Child bindings are pre-serialized into prepared context at child creation time."
  (bark:with-captured-logs (get-logs (make-json-formatter))
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:make-child bark:*logger* :context (list :boot-err c))))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let* ((parsed (yason:parse (first (funcall get-logs))))
               (err (gethash "boot-err" parsed)))
          (5am:is (hash-table-p err))
          (5am:is (string= "simple-error" (gethash "type" err))))))))

(5am:test test-condition-in-child-bindings-logfmt
  "Condition in child logger context serializes correctly in logfmt.
   context carry the live condition object, serialized at log time."
  (bark:with-captured-logs (get-logs (make-logfmt-formatter))
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:make-child bark:*logger* :context (list :boot-err c))))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let ((line (first (funcall get-logs))))
          (5am:is-true (search "boot-err=\"simple-error: startup err\"" line)))))))

(5am:test test-condition-in-child-bindings-pretty
  "Condition in child logger context serializes correctly in pretty.
   context carry the live condition object, serialized at log time."
  (bark:with-captured-logs (get-logs (make-pretty-formatter))
    (let* ((c (make-condition 'simple-error :format-control "startup err"))
           (child-logger (bark:make-child bark:*logger* :context (list :boot-err c))))
      (let ((bark:*logger* child-logger))
        (bark:info "started")
        (let ((line (first (funcall get-logs))))
          (5am:is-true (search "simple-error: startup err" line)))))))

(5am:test test-condition-in-dynamic-context
  "Condition in with-context serializes correctly."
  (bark:with-captured-logs (get-logs (make-json-formatter))
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
    (let ((l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
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
    (let ((l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
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
    (let ((l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
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
    (let ((l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
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
    (let* ((parent (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:make-child parent :context '(:component "auth" :secret "key-abc"))))
      (funcall (logger-info-fn ch) ch "hello"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"component\":\"auth\"" result))
      (5am:is-false (search "secret" result))
      (5am:is-false (search "key-abc" result)))))

(5am:test test-field-transform-nil-means-no-transform
  "A nil field-transform slot means no transformation (default)."
  (let ((out (make-string-output-stream)))
    (let ((l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out))))
      (5am:is (null (logger-field-transform l)))
      (funcall (logger-info-fn l) l "msg" :key "val"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"key\":\"val\"" result)))))

(5am:test test-field-transform-inherited-by-child
  "Child inherits parent's field-transform."
  (let ((out (make-string-output-stream)))
    (let* ((parent (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:make-child parent :context '(:component "db"))))
      (funcall (logger-info-fn ch) ch "query" :sql "SELECT 1" :secret "pw"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"sql\":\"SELECT 1\"" result))
      (5am:is-false (search "secret" result)))))

(5am:test test-field-transform-child-compose
  "Child can add its own field-transform, composed with parent's."
  (let ((out (make-string-output-stream)))
    (let* ((parent (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out)
                                :field-transform (lambda (key value)
                                                   (if (eq key :secret)
                                                       (values nil nil)
                                                       value))))
           (ch (bark:make-child parent :context '(:component "auth")
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
    (let ((l (make-logger :level :info :formatter (make-logfmt-formatter) :output (sync-output out)
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
         (l (make-logger :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (let ((bark::*override-timestamp* 9999999))
      (funcall (logger-info-fn l) l "test"))
    (let* ((line (get-output-stream-string out))
           (json (yason:parse line)))
      (5am:is (= 9999999 (gethash "ts" json))))))

;;; --- Buffer entry ---

(5am:test test-buffer-entry-struct
  "buffer-entry struct holds all captured fields."
  (let ((entry (make-buffer-entry :level +info+
                                  :message "hello"
                                  :fields '(:key "val")
                                  :context '((:req-id . "r1"))
                                  :timestamp 1234567890)))
    (5am:is (= +info+ (buffer-entry-level entry)))
    (5am:is (string= "hello" (buffer-entry-message entry)))
    (5am:is (equal '(:key "val") (buffer-entry-fields entry)))
    (5am:is (equal '((:req-id . "r1")) (buffer-entry-context entry)))
    (5am:is (= 1234567890 (buffer-entry-timestamp entry)))))

;;; --- Buffer logger ---

(5am:test test-make-buffer-logger-level-lowered
  "Buffer logger has level lowered to the requested capture level."
  (let* ((original (make-logger :context '(:name "app") :level :info :output *standard-output*))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (5am:is (= +trace+ (logger-level buf-lgr)))))

(5am:test test-make-buffer-logger-slots-cleared
  "Buffer logger has field-transform and sampler set to nil."
  (let* ((original (make-logger :context '(:name "app") :level :info :output *standard-output*
                                :field-transform (lambda (k v) (declare (ignore k)) v)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (5am:is (null (logger-field-transform buf-lgr)))
    (5am:is (null (bark::logger-level-sampler buf-lgr)))
    (5am:is (null (bark::logger-consistent buf-lgr)))))

(5am:test test-make-buffer-logger-preserves-identity
  "Buffer logger preserves prepared context and context from original."
  (let* ((parent (make-logger :context '(:name "app") :level :info :output *standard-output*))
         (original (make-child parent :context '(:component "auth")))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (5am:is (string= (logger-prepared original) (logger-prepared buf-lgr)))
    (5am:is (equal (logger-context original) (logger-context buf-lgr)))))

(5am:test test-make-buffer-logger-captures-entries
  "Calling log functions on buffer logger pushes entries to buffer vector."
  (let* ((original (make-logger :context '(:name "app") :level :info :output *standard-output*))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (funcall (logger-info-fn buf-lgr) buf-lgr "hello" :key "val")
    (5am:is (= 1 (length buffer)))
    (let ((entry (aref buffer 0)))
      (5am:is (= +info+ (buffer-entry-level entry)))
      (5am:is (string= "hello" (buffer-entry-message entry)))
      (5am:is (equal '(:key "val") (buffer-entry-fields entry))))))

(5am:test test-make-buffer-logger-captures-context
  "Buffer logger snapshots *log-context* at log time."
  (let* ((original (make-logger :context '(:name "app") :level :info :output *standard-output*))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (let ((*log-context* (list (cons :req-id "r1"))))
      (funcall (logger-info-fn buf-lgr) buf-lgr "hello"))
    (5am:is (equal '((:req-id . "r1")) (buffer-entry-context (aref buffer 0))))))

(5am:test test-make-buffer-logger-captures-all-levels
  "Buffer logger captures entries at all enabled levels."
  (let* ((original (make-logger :context '(:name "app") :level :info :output *standard-output*))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (buf-lgr (make-buffer-logger original +trace+ buffer)))
    (funcall (logger-trace-fn buf-lgr) buf-lgr "t")
    (funcall (logger-debug-fn buf-lgr) buf-lgr "d")
    (funcall (logger-info-fn buf-lgr) buf-lgr "i")
    (funcall (logger-warn-fn buf-lgr) buf-lgr "w")
    (funcall (logger-error-fn buf-lgr) buf-lgr "e")
    (funcall (logger-fatal-fn buf-lgr) buf-lgr "f")
    (5am:is (= 6 (length buffer)))
    (5am:is (= +trace+ (buffer-entry-level (aref buffer 0))))
    (5am:is (= +fatal+ (buffer-entry-level (aref buffer 5))))))

;;; --- Flush buffer ---

(5am:test test-flush-buffer-normal-exit-filters-by-level
  "Normal exit: only entries >= original level are emitted."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-buffer-entry :level +debug+ :message "dbg" :timestamp 100) buffer)
    (vector-push-extend (make-buffer-entry :level +info+ :message "inf" :timestamp 200) buffer)
    (vector-push-extend (make-buffer-entry :level +warn+ :message "wrn" :timestamp 300) buffer)
    (flush-buffer buffer root t nil nil +info+)
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "dbg" result))
      (5am:is-true (search "inf" result))
      (5am:is-true (search "wrn" result)))))

(5am:test test-flush-buffer-abnormal-exit-emits-all
  "Abnormal exit with condition: all entries emitted."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (cond (make-condition 'simple-error :format-control "boom")))
    (vector-push-extend (make-buffer-entry :level +debug+ :message "dbg" :timestamp 100) buffer)
    (vector-push-extend (make-buffer-entry :level +info+ :message "inf" :timestamp 200) buffer)
    (flush-buffer buffer root nil cond nil +info+)
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "dbg" result))
      (5am:is-true (search "inf" result)))))

(5am:test test-flush-buffer-non-condition-nlx-filters
  "Non-condition NLX (normal-exit-p=nil, condition=nil): filter like normal exit."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-buffer-entry :level +debug+ :message "dbg" :timestamp 100) buffer)
    (vector-push-extend (make-buffer-entry :level +info+ :message "inf" :timestamp 200) buffer)
    (flush-buffer buffer root nil nil nil +info+)
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "dbg" result))
      (5am:is-true (search "inf" result)))))

(5am:test test-flush-buffer-uses-override-timestamp
  "Flushed entries use their captured timestamp, not wall clock."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-buffer-entry :level +info+ :message "test" :timestamp 42) buffer)
    (flush-buffer buffer root t nil nil +info+)
    (let* ((line (get-output-stream-string out))
           (json (yason:parse line)))
      (5am:is (= 42 (gethash "ts" json))))))

(5am:test test-flush-buffer-applies-field-transform
  "Flush applies root logger's field transform to entry fields."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)
                            :field-transform (lambda (key value)
                                              (if (eq key :secret)
                                                  (values nil nil)
                                                  value))))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-buffer-entry :level +info+ :message "test"
                                           :fields '(:user "alice" :secret "pw")
                                           :timestamp 100) buffer)
    (flush-buffer buffer root t nil nil +info+)
    (let* ((line (get-output-stream-string out))
           (json (yason:parse line)))
      (5am:is (string= "alice" (gethash "user" json)))
      (5am:is (null (gethash "secret" json))))))

(5am:test test-flush-buffer-on-flush-callback
  "on-flush callback controls which entries are emitted."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         ;; Only emit warn and above
         (on-flush (lambda (entries condition normal-exit-p)
                     (declare (ignore condition normal-exit-p))
                     (remove-if (lambda (e) (< (buffer-entry-level e) +warn+)) entries))))
    (vector-push-extend (make-buffer-entry :level +info+ :message "inf" :timestamp 100) buffer)
    (vector-push-extend (make-buffer-entry :level +warn+ :message "wrn" :timestamp 200) buffer)
    (flush-buffer buffer root t nil on-flush +info+)
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "inf" result))
      (5am:is-true (search "wrn" result)))))

(5am:test test-flush-buffer-on-flush-receives-all-args
  "on-flush callback receives entries, condition, and normal-exit-p."
  (let* ((root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter)
                            :output (make-string-output-stream)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0))
         (cond (make-condition 'simple-error :format-control "err"))
         (captured-args nil)
         (on-flush (lambda (entries condition normal-exit-p)
                     (setf captured-args (list entries condition normal-exit-p))
                     nil)))
    (vector-push-extend (make-buffer-entry :level +info+ :message "x" :timestamp 1) buffer)
    (flush-buffer buffer root nil cond on-flush +info+)
    (5am:is (= 1 (length (first captured-args))))
    (5am:is (eq cond (second captured-args)))
    (5am:is (eq nil (third captured-args)))))

(5am:test test-flush-buffer-empty-does-nothing
  "Flushing an empty buffer produces no output."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (flush-buffer buffer root t nil nil +info+)
    (5am:is (string= "" (get-output-stream-string out)))))

(5am:test test-flush-buffer-preserves-entry-order
  "Entries are flushed in the order they were captured."
  (let* ((out (make-string-output-stream))
         (root (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (buffer (make-array 8 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-buffer-entry :level +info+ :message "first" :timestamp 100) buffer)
    (vector-push-extend (make-buffer-entry :level +info+ :message "second" :timestamp 200) buffer)
    (vector-push-extend (make-buffer-entry :level +info+ :message "third" :timestamp 300) buffer)
    (flush-buffer buffer root t nil nil +info+)
    (let ((result (get-output-stream-string out)))
      (5am:is (< (search "first" result)
                 (search "second" result)
                 (search "third" result))))))

;;; --- with-log-buffer ---

(5am:test test-with-log-buffer-normal-exit-filters
  "Normal exit filters to entries >= logger's configured level."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:debug "hidden")
      (bark:info "visible"))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "hidden" result))
      (5am:is-true (search "visible" result)))))

(5am:test test-with-log-buffer-abnormal-exit-emits-all
  "Abnormal exit emits all buffered entries."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (ignore-errors
      (with-log-buffer (*logger*)
        (bark:debug "debug-trail")
        (bark:info "info-msg")
        (cl:error "boom")))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "debug-trail" result))
      (5am:is-true (search "info-msg" result)))))

(5am:test test-with-log-buffer-returns-body-value
  "with-log-buffer returns the value of the body."
  (let ((*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter)
                               :output (make-string-output-stream))))
    (5am:is (= 42 (with-log-buffer (*logger*) 42)))))

(5am:test test-with-log-buffer-returns-multiple-values
  "with-log-buffer preserves multiple return values."
  (let ((*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter)
                               :output (make-string-output-stream))))
    (multiple-value-bind (a b) (with-log-buffer (*logger*) (values 1 2))
      (5am:is (= 1 a))
      (5am:is (= 2 b)))))

(5am:test test-with-log-buffer-handled-error-is-normal
  "Error caught inside body = normal exit, debug discarded."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:debug "pre-error")
      (handler-case (cl:error "handled")
        (cl:error () (bark:info "recovered"))))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "pre-error" result))
      (5am:is-true (search "recovered" result)))))

(5am:test test-with-log-buffer-return-from-is-normal
  "return-from (non-condition NLX) treated as normal exit."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (block outer
      (with-log-buffer (*logger*)
        (bark:debug "hidden-debug")
        (bark:info "shown-info")
        (return-from outer 99)))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "hidden-debug" result))
      (5am:is-true (search "shown-info" result)))))

(5am:test test-with-log-buffer-custom-level
  "Custom capture level limits what gets buffered."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (ignore-errors
      (with-log-buffer (*logger* :level :debug)
        (bark:trace "trace-hidden")
        (bark:debug "debug-visible")
        (cl:error "force flush")))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "trace-hidden" result))
      (5am:is-true (search "debug-visible" result)))))

(5am:test test-with-log-buffer-on-flush-callback
  "on-flush callback controls emission."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger* :on-flush (lambda (entries condition normal-exit-p)
                                  (declare (ignore condition normal-exit-p))
                                  ;; Only emit entries with :audit in fields
                                  (remove-if-not (lambda (e)
                                                   (getf (buffer-entry-fields e) :audit))
                                                 entries)))
      (bark:info "no-audit" :path "/")
      (bark:info "has-audit" :audit t :path "/admin"))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "no-audit" result))
      (5am:is-true (search "has-audit" result)))))

(5am:test test-with-log-buffer-captures-context
  "Dynamic context is captured at log time, not flush time."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (with-context (:req "r1")
        (bark:info "inside-ctx"))
      ;; Context gone here, but entry captured it
      (bark:info "outside-ctx"))
    (let* ((result (get-output-stream-string out))
           (lines (uiop:split-string result :separator '(#\Newline))))
      ;; First line should have req=r1
      (5am:is-true (search "r1" (first lines)))
      ;; Second line should not
      (5am:is-false (search "r1" (second lines))))))

(5am:test test-with-log-buffer-preserves-timestamps
  "Each entry retains its own timestamp from log time."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:info "msg1")
      (bark:info "msg2"))
    (let* ((result (get-output-stream-string out))
           (lines (remove-if (lambda (s) (string= s ""))
                             (uiop:split-string result :separator '(#\Newline)))))
      ;; Both lines should have ts fields (positive integers)
      (5am:is (= 2 (length lines)))
      (let ((ts1 (gethash "ts" (yason:parse (first lines))))
            (ts2 (gethash "ts" (yason:parse (second lines)))))
        (5am:is (plusp ts1))
        (5am:is (plusp ts2))
        (5am:is (<= ts1 ts2))))))

(5am:test test-with-log-buffer-explicit-logger-bypasses
  "Explicit logger arg bypasses the buffer."
  (let* ((buf-out (make-string-output-stream))
         (direct-out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "buf") :level :info :formatter (make-json-formatter) :output (sync-output buf-out)))
         (direct-lgr (make-logger :context '(:name "direct") :level :info :formatter (make-json-formatter)
                                  :output (sync-output direct-out))))
    (with-log-buffer (*logger*)
      (bark:info "buffered")
      (bark:info direct-lgr "direct"))
    ;; "buffered" goes through buffer → buf-out
    ;; "direct" goes directly to direct-out (bypasses buffer)
    (5am:is-true (search "buffered" (get-output-stream-string buf-out)))
    (5am:is-true (search "direct" (get-output-stream-string direct-out)))))

(5am:test test-with-log-buffer-nil-logger-noop
  "with-log-buffer with *logger* nil is a no-op (body still runs)."
  (let ((*logger* nil)
        (ran nil))
    (with-log-buffer (*logger*)
      (setf ran t))
    (5am:is-true ran)))

;;; --- Nested buffering ---

(5am:test test-nested-buffer-is-noop
  "Nested with-log-buffer is a no-op — all entries go to outermost buffer."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:info "outer-1")
      (with-log-buffer (*logger*)
        (bark:info "inner-1"))
      (bark:info "outer-2"))
    ;; All three in outermost buffer, filtered to >= :info on normal exit
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "outer-1" result))
      (5am:is-true (search "inner-1" result))
      (5am:is-true (search "outer-2" result)))))

(5am:test test-nested-buffer-inner-error-handled-by-outer
  "Nested scope is a no-op; handled error inside is normal exit for outer."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:debug "outer-debug")
      (bark:info "outer-info")
      (handler-case
          (with-log-buffer (*logger*)
            (bark:debug "inner-debug")
            (cl:error "inner boom"))
        (cl:error () nil))
      (bark:info "outer-continues"))
    (let ((result (get-output-stream-string out)))
      ;; Error was handled → normal exit → debug entries filtered out
      (5am:is-false (search "outer-debug" result))
      (5am:is-false (search "inner-debug" result))
      ;; Info entries visible
      (5am:is-true (search "outer-info" result))
      (5am:is-true (search "outer-continues" result)))))

(5am:test test-nested-buffer-deeply-nested-noop
  "Deeply nested with-log-buffer scopes are all no-ops except the outermost."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (with-log-buffer (*logger*)
        (with-log-buffer (*logger*)
          (bark:info "deep"))))
    (5am:is-true (search "deep" (get-output-stream-string out)))))

;;; --- Buffer edge cases ---

(5am:test test-with-log-buffer-on-flush-nil-suppresses-all
  "on-flush returning nil suppresses all output."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out))))
    (with-log-buffer (*logger* :on-flush (lambda (entries condition normal-exit-p)
                                  (declare (ignore entries condition normal-exit-p))
                                  nil))
      (bark:info "suppressed"))
    (5am:is (string= "" (get-output-stream-string out)))))

(5am:test test-with-log-buffer-child-logger-prepared
  "Buffer scope with child logger preserves static context in output."
  (let* ((out (make-string-output-stream))
         (parent (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)))
         (*logger* (make-child parent :context '(:component "auth"))))
    (with-log-buffer (*logger*)
      (bark:info "login"))
    (let* ((result (get-output-stream-string out))
           (json (yason:parse (string-trim '(#\Newline) result))))
      (5am:is (string= "auth" (gethash "component" json))))))

(5am:test test-with-log-buffer-field-transform-at-flush
  "Root logger's field transform is applied at flush time, not capture time."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter) :output (sync-output out)
                                :field-transform (lambda (key value)
                                                  (if (eq key :token) "****" value)))))
    (with-log-buffer (*logger*)
      (bark:info "login" :token "secret-abc"))
    (let* ((result (get-output-stream-string out))
           (json (yason:parse (string-trim '(#\Newline) result))))
      (5am:is (string= "****" (gethash "token" json))))))

(5am:test test-with-log-buffer-on-flush-sees-handled-condition
  "handler-case inside body catches first; on-flush sees normal exit."
  (let* ((*logger* (make-logger :context '(:name "app") :level :info :formatter (make-json-formatter)
                                :output (make-string-output-stream)))
         (seen-condition nil)
         (seen-normal-exit-p nil))
    (with-log-buffer (*logger* :on-flush (lambda (entries condition normal-exit-p)
                                  (declare (ignore entries))
                                  (setf seen-condition condition
                                        seen-normal-exit-p normal-exit-p)
                                  nil))
      (bark:info "before-error")
      (handler-case (cl:error "caught-inside")
        (cl:error () nil)))
    ;; handler-case is inner to handler-bind so it catches first; condition not seen
    (5am:is-false seen-condition)
    ;; Body completed normally (handler-case handled the error)
    (5am:is-true seen-normal-exit-p)))

(5am:test test-with-log-buffer-logfmt-formatter
  "Buffer works with logfmt formatter."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "app") :level :info :formatter (make-logfmt-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:info "hello" :key "val"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "msg=hello" result))
      (5am:is-true (search "key=val" result)))))

(5am:test test-with-log-buffer-pretty-formatter
  "Buffer works with pretty formatter."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "test") :level :info :formatter (make-pretty-formatter) :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:info "hello"))
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "hello" result)))))

;;; --- Optional message ---

(5am:test test-json-formatter-nil-message
  "JSON formatter omits msg field when message is nil."
  (let ((output (json-formatter +info+ "" nil nil nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search "\"level\"" output))
    (5am:is-true (search "\"ts\"" output))
    (5am:is-false (search "\"msg\"" output))))

(5am:test test-json-formatter-nil-message-with-fields
  "JSON formatter omits msg but includes fields when message is nil."
  (let ((output (json-formatter +info+ "" nil nil (list :event "login" :user-id 42))))
    (5am:is-false (search "\"msg\"" output))
    (5am:is-true (search "\"event\"" output))
    (5am:is-true (search "login" output))
    (5am:is-true (search "\"user-id\"" output))
    (5am:is-true (search "42" output))))

(5am:test test-logfmt-formatter-nil-message
  "Logfmt formatter omits msg= when message is nil."
  (let ((output (logfmt-formatter +info+ "" nil nil nil)))
    (5am:is-true (search "level=info" output))
    (5am:is-true (search "ts=" output))
    (5am:is-false (search "msg=" output))))

(5am:test test-logfmt-formatter-nil-message-with-fields
  "Logfmt formatter omits msg= but includes fields when message is nil."
  (let ((output (logfmt-formatter +warn+ "" nil nil (list :event "login"))))
    (5am:is-false (search "msg=" output))
    (5am:is-true (search "event=" output))))

(5am:test test-pretty-formatter-nil-message
  "Pretty formatter omits message text when message is nil."
  (let ((output (pretty-formatter +info+ "" nil nil nil)))
    (5am:is-true (stringp output))
    (5am:is-true (search (string #\Esc) output))
    ;; Level label appears but no message text follows
    (5am:is-true (search "INFO" output))))

(5am:test test-pretty-formatter-nil-message-with-fields
  "Pretty formatter shows fields without message text when nil."
  (let ((output (pretty-formatter +info+ "" nil nil (list :event "login"))))
    (5am:is-true (search "event" output))
    (5am:is-true (search "login" output))
    ;; Verify no spurious message text — only level + fields
    (5am:is-false (search "nil" output))))

(5am:test test-macro-keyword-first-fields-only
  "Logging macro with keyword first arg treats all args as fields plist."
  (with-captured-logs (get-logs)
    (bark:info :event "login" :user-id 42)
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (5am:is (= 1 (length logs)))
      (5am:is-false (search "\"msg\"" line))
      (5am:is-true (search "\"event\"" line))
      (5am:is-true (search "login" line))
      (5am:is-true (search "\"user-id\"" line))
      (5am:is-true (search "42" line)))))

(5am:test test-macro-string-first-preserves-message
  "Logging macro with string first arg still works as before."
  (with-captured-logs (get-logs)
    (bark:info "hello world" :key "val")
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (5am:is (= 1 (length logs)))
      (5am:is-true (search "\"msg\"" line))
      (5am:is-true (search "hello world" line))
      (5am:is-true (search "\"key\"" line)))))

(5am:test test-macro-explicit-logger-keyword-fields
  "Logging macro with explicit logger and keyword-first fields."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "test") :level :info :output collector)))
      (bark:info lgr :event "created" :id 7)
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (5am:is (= 1 (length logs)))
        (5am:is-false (search "\"msg\"" line))
        (5am:is-true (search "\"event\"" line))
        (5am:is-true (search "created" line))))))

(5am:test test-macro-explicit-logger-string-message
  "Logging macro with explicit logger and string message."
  (multiple-value-bind (collector results-fn) (make-list-collector)
    (let ((lgr (make-logger :context '(:name "test") :level :info :output collector)))
      (bark:info lgr "hello" :k "v")
      (let* ((logs (funcall results-fn))
             (line (first logs)))
        (5am:is (= 1 (length logs)))
        (5am:is-true (search "\"msg\"" line))
        (5am:is-true (search "hello" line))))))

(5am:test test-macro-runtime-keyword-detection
  "Logging macro detects keyword at runtime for variable first arg."
  (with-captured-logs (get-logs)
    (let ((key :event))
      (bark:info key "login"))
    (let* ((logs (funcall get-logs))
           (line (first logs)))
      (5am:is (= 1 (length logs)))
      ;; key is :event at runtime → treated as fields-only
      (5am:is-false (search "\"msg\"" line))
      (5am:is-true (search "\"event\"" line))
      (5am:is-true (search "login" line)))))

(5am:test test-macro-zero-args-no-output
  "Logging macro with zero args produces no output."
  (with-captured-logs (get-logs)
    (bark:info)
    (5am:is (= 0 (length (funcall get-logs))))))

(5am:test test-buffer-nil-message-roundtrip
  "Buffer captures and flushes entries with nil message."
  (let* ((out (make-string-output-stream))
         (*logger* (make-logger :context '(:name "test") :level :info :output (sync-output out))))
    (with-log-buffer (*logger*)
      (bark:info :event "buffered"))
    (let ((result (get-output-stream-string out)))
      (5am:is-false (search "\"msg\"" result))
      (5am:is-true (search "\"event\"" result))
      (5am:is-true (search "buffered" result)))))

;;; --- Formatter Factories ---

(5am:test test-make-json-formatter-custom-keys
  "make-json-formatter produces output with custom key names."
  (let ((fmt (bark:make-json-formatter :level-key "severity"
                                       :timestamp-key "time"
                                       :message-key "message")))
    (let* ((*override-timestamp* 1234567890000)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "hello" nil)))
      (5am:is-true (search "\"severity\":\"info\"" result))
      (5am:is-true (search "\"time\":1234567890000" result))
      (5am:is-true (search "\"message\":\"hello\"" result))
      ;; Default keys should NOT appear
      (5am:is-false (search "\"level\":" result))
      (5am:is-false (search "\"ts\":" result))
      (5am:is-false (search "\"msg\":" result)))))

(5am:test test-make-json-formatter-string-level
  "make-json-formatter with :string level-format emits level name strings."
  (let ((fmt (bark:make-json-formatter :level-format :string)))
    (let ((result (funcall (formatter-format-fn fmt) +warn+ "" nil "oops" nil)))
      (5am:is-true (search "\"level\":\"warn\"" result)))))

(5am:test test-make-json-formatter-iso8601-timestamp
  "make-json-formatter with :iso8601 timestamp emits ISO 8601 string."
  (let ((fmt (bark:make-json-formatter :timestamp :iso8601)))
    ;; 2025-01-15T12:00:00.000Z = 1736942400000
    (let* ((*override-timestamp* 1736942400000)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "test" nil)))
      (5am:is-true (search "\"ts\":\"2025-01-15T12:00:00.000Z\"" result)))))

(5am:test test-make-json-formatter-no-timestamp
  "make-json-formatter with :timestamp nil omits the timestamp field."
  (let ((fmt (bark:make-json-formatter :timestamp nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" nil "test" nil)))
      (5am:is-false (search "\"ts\":" result))
      (5am:is-true (search "\"level\":\"info\"" result))
      (5am:is-true (search "\"msg\":\"test\"" result)))))

(5am:test test-make-json-formatter-fields
  "make-json-formatter handles per-call fields and context."
  (let ((fmt (bark:make-json-formatter :timestamp nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ ""
                           (list (cons :req "abc")) "hi"
                           (list :user 42))))
      (5am:is-true (search "\"req\":\"abc\"" result))
      (5am:is-true (search "\"user\":42" result)))))

(5am:test test-make-logfmt-formatter-custom-keys
  "make-logfmt-formatter produces output with custom key names."
  (let ((fmt (bark:make-logfmt-formatter :level-key "severity"
                                         :timestamp-key "time"
                                         :message-key "message")))
    (let* ((*override-timestamp* 9999)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "hello" nil)))
      (5am:is-true (search "severity=info" result))
      (5am:is-true (search "time=9999" result))
      (5am:is-true (search "message=hello" result)))))

(5am:test test-make-logfmt-formatter-no-timestamp
  "make-logfmt-formatter with :timestamp nil omits the timestamp."
  (let ((fmt (bark:make-logfmt-formatter :timestamp nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" nil "test" nil)))
      (5am:is-false (search "ts=" result))
      (5am:is-true (search "level=info" result))
      (5am:is-true (search "msg=test" result)))))

(5am:test test-make-pretty-formatter-with-timestamp
  "make-pretty-formatter with :unix-ms timestamp shows timestamp."
  (let ((fmt (bark:make-pretty-formatter :timestamp :unix-ms)))
    (let* ((*override-timestamp* 42000)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "hello" nil)))
      (5am:is-true (search "INFO" result))
      (5am:is-true (search "42000" result))
      (5am:is-true (search "hello" result)))))

(5am:test test-make-pretty-formatter-without-timestamp
  "make-pretty-formatter without timestamp omits it (like standard pretty-formatter)."
  (let ((fmt (bark:make-pretty-formatter)))
    (let* ((*override-timestamp* 42000)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "hello" nil)))
      (5am:is-true (search "INFO" result))
      (5am:is-true (search "hello" result))
      (5am:is-false (search "42000" result)))))

(5am:test test-make-pretty-formatter-iso8601
  "make-pretty-formatter with :iso8601 timestamp emits ISO 8601 string."
  (let ((fmt (bark:make-pretty-formatter :timestamp :iso8601)))
    (let* ((*override-timestamp* 1736942400000)
           (result (funcall (formatter-format-fn fmt) +info+ "" nil "test" nil)))
      (5am:is-true (search "2025-01-15T12:00:00.000Z" result)))))

(5am:test test-factory-formatter-with-make-logger
  "Factory formatter integrates with make-logger."
  (let* ((out (make-string-output-stream))
         (fmt (bark:make-json-formatter :timestamp nil :level-format :string
                                        :message-key "text"))
         (*logger* (make-logger :context '(:name "test") :level :info :output (sync-output out)
                                :formatter fmt)))
    (bark:info "works")
    (let ((result (get-output-stream-string out)))
      (5am:is-true (search "\"level\":\"info\"" result))
      (5am:is-true (search "\"text\":\"works\"" result))
      (5am:is-false (search "\"ts\":" result)))))

(5am:test test-factory-formatter-with-captured-logs
  "Factory formatter integrates with with-captured-logs."
  (let ((fmt (bark:make-json-formatter :timestamp nil :level-format :string)))
    (bark:with-captured-logs (get-logs fmt)
      (bark:info "captured")
      (let* ((lines (funcall get-logs))
             (line (first lines)))
        (5am:is (= 1 (length lines)))
        (5am:is-true (search "\"level\":\"info\"" line))
        (5am:is-true (search "\"msg\":\"captured\"" line))))))

(5am:test test-make-json-formatter-no-level
  "make-json-formatter with :level-key nil omits the level field."
  (let ((fmt (bark:make-json-formatter :level-key nil :timestamp nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" nil "test" (list :code 200))))
      (5am:is-false (search "\"level\"" result))
      (5am:is-true (search "\"code\":200" result))
      (5am:is-true (search "\"msg\":\"test\"" result))
      ;; Must be valid JSON: starts with { ends with }
      (5am:is (char= #\{ (char result 0)))
      (5am:is (char= #\} (char result (1- (length result))))))))

(5am:test test-make-json-formatter-no-level-with-timestamp
  "make-json-formatter with :level-key nil but timestamp still present."
  (let ((fmt (bark:make-json-formatter :level-key nil)))
    (let ((result (funcall (formatter-format-fn fmt) +warn+ "" nil "hello" nil)))
      (5am:is-false (search "\"level\"" result))
      (5am:is-true (search "\"ts\":" result))
      (5am:is-true (search "\"msg\":\"hello\"" result))
      ;; No leading comma after {
      (5am:is-false (string= ",\"" (subseq result 1 3))))))

(5am:test test-make-json-formatter-no-level-with-prepared-context
  "make-json-formatter with :level-key nil, no timestamp, but prepared context present."
  (let ((fmt (bark:make-json-formatter :level-key nil :timestamp nil)))
    (let* ((chd (serialize-bindings-json(list :svc "api")))
           (result (funcall (formatter-format-fn fmt) +info+ chd nil "test" nil)))
      (5am:is-false (search "\"level\"" result))
      (5am:is-true (search "\"svc\":\"api\"" result))
      ;; No leading comma after {
      (5am:is-false (string= ",\"" (subseq result 1 3))))))

(5am:test test-make-json-formatter-no-level-no-ts-context-only
  "make-json-formatter with no level, no timestamp, no prepared context — only context fields."
  (let ((fmt (bark:make-json-formatter :level-key nil :timestamp nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" '((:env . "prod")) nil nil)))
      (5am:is-true (search "\"env\":\"prod\"" result))
      ;; No leading comma after {
      (5am:is-false (string= ",\"" (subseq result 1 3))))))

(5am:test test-make-logfmt-formatter-no-level
  "make-logfmt-formatter with :level-key nil omits the level field."
  (let ((fmt (bark:make-logfmt-formatter :level-key nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" nil "test" (list :code 200))))
      (5am:is-false (search "level=" result))
      (5am:is-false (search "NIL=" result))
      (5am:is-true (search "ts=" result))
      (5am:is-true (search "code=200" result))
      (5am:is-true (search "msg=" result))
      ;; Timestamp is now first — no leading space
      (5am:is (char/= #\Space (char result 0))))))

(5am:test test-make-pretty-formatter-no-level
  "make-pretty-formatter with :show-level nil omits the colored level label."
  (let ((fmt (bark:make-pretty-formatter :show-level nil)))
    (let ((result (funcall (formatter-format-fn fmt) +info+ "" nil "hello" nil)))
      (5am:is-true (search "hello" result))
      ;; Should NOT contain any of the level names
      (5am:is-false (search "INFO" result))
      (5am:is-false (search "info" result)))))

;;; --- Bug regression tests ---

(5am:test test-logfmt-condition-escapes-quotes
  "Logfmt condition with double-quotes in message must escape them."
  (let* ((c (make-condition 'simple-error :format-control "said ~a" :format-arguments '("\"hi\"")))
         (result (with-output-to-string (s) (bark::emit-logfmt-value s c))))
    ;; Must be properly quoted — no unescaped double-quotes within the value
    (5am:is (char= #\" (char result 0)))
    (5am:is (char= #\" (char result (1- (length result)))))
    ;; Count quotes: opening + closing + 2 escaped = 4
    ;; The internal quotes must be escaped with backslash
    (let ((inner (subseq result 1 (1- (length result)))))
      ;; No bare unescaped double-quote inside the quoted value
      (5am:is-false (search "\"hi\"" inner)
                    "Internal quotes must be escaped, not bare"))))

(5am:test test-logfmt-condition-escapes-newlines
  "Logfmt condition with newlines in message must not produce multi-line output."
  (let* ((c (make-condition 'simple-error :format-control "line1~%line2"))
         (result (with-output-to-string (s) (bark::emit-logfmt-value s c))))
    ;; Must not contain a literal newline (breaks newline-delimited transport)
    (5am:is-false (find #\Newline result)
                  "Logfmt value must be single-line")))

(5am:test test-logfmt-bare-or-quoted-escapes-newlines
  "logfmt-write-bare-or-quoted must quote strings containing newlines."
  (let ((result (with-output-to-string (s)
                  (bark::logfmt-write-bare-or-quoted s (format nil "line1~%line2")))))
    ;; Must not contain a literal newline
    (5am:is-false (find #\Newline result)
                  "Logfmt value must be single-line")
    ;; Must be quoted (starts and ends with double-quote)
    (5am:is (char= #\" (char result 0)))
    (5am:is (char= #\" (char result (1- (length result)))))))

(5am:test test-logfmt-bare-or-quoted-escapes-backslashes
  "logfmt-write-bare-or-quoted must handle backslashes."
  (let ((result (with-output-to-string (s)
                  (bark::logfmt-write-bare-or-quoted s "back\\slash"))))
    ;; Backslash should appear in output (exact form depends on whether we escape)
    (5am:is-true (search "\\" result))))

(5am:test test-logfmt-bare-or-quoted-non-simple-string
  "Non-simple strings (adjustable, fill-pointer) must not signal type errors.
Regression: yason returns (VECTOR CHARACTER N) which is not SIMPLE-STRING."
  (let* ((adjustable (make-array 10 :element-type 'character
                                    :adjustable t :fill-pointer 0))
         (_ (loop for c across "hello" do (vector-push-extend c adjustable)))
         (result (with-output-to-string (s)
                   (bark::logfmt-write-bare-or-quoted s adjustable))))
    (declare (ignore _))
    (5am:is (string= "hello" result))))

(5am:test test-logfmt-value-newline-in-string
  "logfmt values containing newlines are quoted and newlines escaped."
  (let ((out (make-string-output-stream)))
    (let ((l (bark:make-logger :level :info :formatter (make-logfmt-formatter) :output (sync-output out))))
      (funcall (bark::logger-info-fn l) l "msg" :data (format nil "line1~%line2")))
    (let ((s (get-output-stream-string out)))
      ;; Must not contain a literal newline in the value portion
      ;; (the trailing newline from terpri is OK, but there must not be a mid-line break)
      (let ((lines (remove "" (uiop:split-string s :separator '(#\Newline)) :test #'string=)))
        (5am:is (= 1 (length lines)) "logfmt output must be a single line")))))

;;; --- Bug fix: JSON truncation with *max-json-length* = 0 ---

(5am:test (test-emit-json-value-length-zero-cons :suite bark-tests)
  "Cons with *max-json-length*=0 produces valid JSON (no leading comma)."
  (let ((bark:*max-json-length* 0))
    (let ((r (with-output-to-string (s) (emit-json-value s '(1 2 3)))))
      (5am:is (string= "[\"...\"]" r)))))

(5am:test (test-emit-json-value-length-zero-vector :suite bark-tests)
  "Vector with *max-json-length*=0 produces valid JSON (no leading comma)."
  (let ((bark:*max-json-length* 0))
    (let ((r (with-output-to-string (s) (emit-json-value s #(10 20 30)))))
      (5am:is (string= "[\"...\"]" r)))))

(5am:test (test-emit-json-value-length-zero-hash-table :suite bark-tests)
  "*max-json-length*=0 hash-table produces valid JSON (no leading comma)."
  (let ((bark:*max-json-length* 0)
        (h (make-hash-table :test 'equal)))
    (setf (gethash "a" h) 1)
    (let ((r (with-output-to-string (s) (emit-json-value s h))))
      ;; Must start with { and end with }, no leading comma after {
      (5am:is (char= #\{ (char r 0)))
      (5am:is (char= #\} (char r (1- (length r)))))
      (5am:is-false (char= #\, (char r 1))
                    "No leading comma after opening brace")
      ;; Must be parseable as JSON
      (5am:is (hash-table-p (yason:parse r))))))

(5am:test (test-emit-json-value-length-zero-roundtrip :suite bark-tests)
  "*max-json-length*=0 output is valid JSON for all collection types."
  (let ((bark:*max-json-length* 0))
    ;; Cons → parseable JSON array
    (let ((r (with-output-to-string (s) (emit-json-value s '(1 2)))))
      (5am:is (listp (yason:parse r))))
    ;; Vector → parseable JSON array
    (let ((r (with-output-to-string (s) (emit-json-value s #(1 2)))))
      (5am:is (listp (yason:parse r))))
    ;; Hash-table → parseable JSON object
    (let* ((h (make-hash-table :test 'equal))
           (_ (setf (gethash "k" h) "v"))
           (r (with-output-to-string (s) (emit-json-value s h))))
      (declare (ignore _))
      (5am:is (hash-table-p (yason:parse r))))))

;;; --- Bug fix: Symbol keys with special characters ---

(5am:test (test-emit-json-key-symbol-with-special-chars :suite bark-tests)
  "emit-json-key escapes special characters in symbol names."
  ;; Symbol with a double-quote in its name
  (let* ((sym (intern "KEY\"QUOTE" :keyword))
         (r (with-output-to-string (s) (emit-json-key s sym))))
    ;; Must contain escaped quote, not raw quote breaking the JSON
    (5am:is-true (search "\\\"" r))
    ;; The key should be properly delimited
    (5am:is-true (search "\":" r))))

;;; --- Bug fix: Double-float JSON serialization ---

(5am:test (test-json-double-float-no-d-marker :suite bark-tests)
  "Double-float values must not contain SBCL's d0 exponent marker in JSON output."
  (let ((r (with-output-to-string (s) (emit-json-value s 0.042d0))))
    (5am:is-false (search "d" r) "Double-float JSON should not contain 'd' marker: ~a" r)
    (5am:is-false (search "D" r))
    ;; Must be parseable as a number
    (5am:is-true (search "0.042" r))))

(5am:test (test-json-double-float-large :suite bark-tests)
  "Large double-floats serialize as valid JSON numbers."
  (let ((r (with-output-to-string (s) (emit-json-value s 1.0d10))))
    (5am:is-false (search "d" r))
    (5am:is-false (search "D" r))))

(5am:test (test-json-double-float-small :suite bark-tests)
  "Small double-floats serialize as valid JSON numbers."
  (let ((r (with-output-to-string (s) (emit-json-value s 1.0d-10))))
    (5am:is-false (search "d" r))
    (5am:is-false (search "D" r))))

(5am:test (test-json-double-float-pi :suite bark-tests)
  "Pi serializes as a valid JSON number."
  (let ((r (with-output-to-string (s) (emit-json-value s pi))))
    (5am:is-false (search "d" r))
    (5am:is-false (search "D" r))
    (5am:is-true (search "3.14159" r))))

(5am:test (test-json-double-float-roundtrip :suite bark-tests)
  "Double-float in full pipeline produces valid parseable JSON."
  (bark:with-captured-logs (logs)
    (bark:info "elapsed" :dur 0.042d0)
    (let* ((line (first (funcall logs)))
           (parsed (yason:parse line)))
      (5am:is (floatp (gethash "dur" parsed))))))

;;; --- Bug fix: IEEE 754 special values ---

(5am:test (test-json-float-nan :suite bark-tests)
  "NaN float serializes as JSON null, not CL printer output."
  (let* ((nan (sb-kernel:make-single-float #x7FC00000))
         (r (with-output-to-string (s) (emit-json-value s nan))))
    (5am:is (string= "null" r))))

(5am:test (test-json-float-positive-infinity :suite bark-tests)
  "Positive infinity serializes as JSON null."
  (let* ((inf sb-ext:single-float-positive-infinity)
         (r (with-output-to-string (s) (emit-json-value s inf))))
    (5am:is (string= "null" r))))

(5am:test (test-json-float-negative-infinity :suite bark-tests)
  "Negative infinity serializes as JSON null."
  (let* ((inf sb-ext:single-float-negative-infinity)
         (r (with-output-to-string (s) (emit-json-value s inf))))
    (5am:is (string= "null" r))))

(5am:test (test-json-double-float-infinity :suite bark-tests)
  "Double-float infinity serializes as JSON null."
  (let* ((inf sb-ext:double-float-positive-infinity)
         (r (with-output-to-string (s) (emit-json-value s inf))))
    (5am:is (string= "null" r))))

;;; --- Bug fix: logfmt float serialization ---

(5am:test (test-logfmt-double-float-no-d-marker :suite bark-tests)
  "Double-float values in logfmt must not contain SBCL's d0 exponent marker."
  (let ((r (with-output-to-string (s) (emit-logfmt-value s 0.042d0))))
    (5am:is-false (search "d" r))
    (5am:is-false (search "D" r))
    (5am:is-true (search "0.042" r))))

(5am:test (test-logfmt-float-nan :suite bark-tests)
  "NaN float in logfmt serializes as null."
  (let* ((nan (sb-kernel:make-single-float #x7FC00000))
         (r (with-output-to-string (s) (emit-logfmt-value s nan))))
    (5am:is (string= "null" r))))

(5am:test (test-logfmt-float-infinity :suite bark-tests)
  "Infinity in logfmt serializes as null."
  (let* ((inf sb-ext:single-float-positive-infinity)
         (r (with-output-to-string (s) (emit-logfmt-value s inf))))
    (5am:is (string= "null" r))))

;;; --- Bug fix: stop-async-output drain error handling ---

(5am:test (test-stop-async-output-closed-stream :suite bark-tests)
  "stop-async-output does not crash when the stream is already closed."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 16)))
    ;; Close the stream to simulate a failed output
    (close (bark::async-output-stream ao))
    ;; Push a message that the writer won't be able to write
    (bark::ring-buffer-push (bark::async-output-ring ao) "msg")
    (bt:signal-semaphore (bark::async-output-notify ao))
    (sleep 0.2)
    ;; stop should not crash despite the closed stream
    (5am:finishes (bark::stop-async-output ao))))

;;; --- Bug fix: Writer-loop orphaned flush-acks ---

(5am:test (test-flush-after-writer-exit-no-stall :suite bark-tests)
  "flush-async-output returns quickly when writer thread has exited."
  (let* ((ao (bark::make-async-output
              (make-string-output-stream)
              :capacity 16
              :on-error (lambda (e) (declare (ignore e)) nil))))
    ;; Force writer to exit by closing the stream
    (close (bark::async-output-stream ao))
    (bark::ring-buffer-push (bark::async-output-ring ao) "trigger-error")
    (bt:signal-semaphore (bark::async-output-notify ao))
    (sleep 0.3)
    ;; Writer should have exited by now
    (5am:is-false (bark::async-output-running ao))
    ;; flush-async-output must return quickly (not stall for 5s)
    (let ((start (get-internal-real-time)))
      (bark::flush-async-output ao)
      (let ((elapsed-ms (* 1000.0
                           (/ (- (get-internal-real-time) start)
                              internal-time-units-per-second))))
        (5am:is-true (< elapsed-ms 1000)
                     "flush-async-output stalled for ~Fms (should be < 1s)" elapsed-ms)))
    ;; Clean up
    (when (bark::async-output-thread ao)
      (bt:join-thread (bark::async-output-thread ao)))))

(5am:test test-flush-stopped-signals-bark-async-stopped
  "bark:flush signals bark-async-stopped (not just error) when output is stopped."
  (let* ((out (make-string-output-stream))
         (lgr (bark:make-logger :level :info :output out)))
    (bark:stop lgr)
    (5am:signals bark:bark-async-stopped (bark:flush lgr))))

(5am:test test-flush-stopped-restart-continue
  "The continue restart in flush skips stopped outputs."
  (let* ((out (make-string-output-stream))
         (lgr (bark:make-logger :level :info :output out)))
    (bark:stop lgr)
    ;; invoke continue — should return normally, no error
    (handler-bind ((bark:bark-async-stopped
                     (lambda (c)
                       (declare (ignore c))
                       (invoke-restart 'continue))))
      (bark:flush lgr))
    (5am:pass "continue restart returned normally")))
(5am:test test-stop-child-signals-bark-child-operation-error
  "bark:stop on a child signals bark-child-operation-error."
  (let* ((out (make-string-output-stream))
         (parent (bark:make-logger :level :info :output out))
         (child (bark:make-child parent)))
    (unwind-protect
         (5am:signals bark:bark-child-operation-error
           (bark:stop child))
      (bark:stop parent))))

(5am:test test-stop-child-operation-slot
  "bark-child-operation-error carries the :stop operation."
  (let* ((out (make-string-output-stream))
         (parent (bark:make-logger :level :info :output out))
         (child (bark:make-child parent)))
    (unwind-protect
         (handler-case (bark:stop child)
           (bark:bark-child-operation-error (c)
             (5am:is (eq :stop (bark:bark-child-operation-error-operation c)))))
      (bark:stop parent))))

(5am:test test-stop-child-restart-continue
  "The continue restart in stop silently ignores stop on child."
  (let* ((out (make-string-output-stream))
         (parent (bark:make-logger :level :info :output out))
         (child (bark:make-child parent)))
    (unwind-protect
         (progn
           (handler-bind ((bark:bark-child-operation-error
                            (lambda (c)
                              (declare (ignore c))
                              (invoke-restart 'continue))))
             (bark:stop child))
           ;; parent should still be running
           (5am:is-true (bark::async-output-running (bark::logger-output parent))))
      (bark:stop parent))))

(5am:test test-make-logger-async-with-tee-signals-configuration-error
  "make-logger signals bark-configuration-error for async params with tee."
  (let* ((s1 (make-string-output-stream))
         (tee (bark:make-tee (list (list :stream s1)))))
    (unwind-protect
         (5am:signals bark:bark-configuration-error
           (bark:make-logger :output tee :blocking t))
      (bark:stop (bark:make-logger :output (make-string-output-stream))))))

(5am:test test-make-logger-invalid-output-signals-configuration-error
  "make-logger signals bark-configuration-error for invalid output type."
  (5am:signals bark:bark-configuration-error
    (bark:make-logger :output 42)))

(5am:test test-make-tee-filter-level-conflict-signals-configuration-error
  "make-tee signals bark-configuration-error for :filter + :level."
  (let ((s1 (make-string-output-stream)))
    (5am:signals bark:bark-configuration-error
      (bark:make-tee
       (list (list :stream s1
                   :level :error
                   :filter (lambda (level fields) (declare (ignore level fields)) t)))))))

(5am:test test-make-consistent-sampler-rate-zero-signals-configuration-error
  "make-consistent-sampler signals bark-configuration-error for rate < 1."
  (5am:signals bark:bark-configuration-error
    (bark:make-consistent-sampler :key-fn (lambda (b) (declare (ignore b)) "k") :rate 0)))

(5am:test test-make-level-sampler-bad-type-signals-configuration-error
  "make-level-sampler signals bark-configuration-error for non-windowed-counter."
  (5am:signals bark:bark-configuration-error
    (bark:make-level-sampler :info 42)))

(5am:test test-configuration-error-detail-slot
  "bark-configuration-error carries a human-readable detail string."
  (handler-case (bark:make-logger :output 42)
    (bark:bark-configuration-error (c)
      (5am:is (stringp (bark:bark-configuration-error-detail c)))
      (5am:is (search "Invalid :output" (bark:bark-configuration-error-detail c))))))

(5am:test test-condition-hierarchy
  "Condition type hierarchy is correct."
  (5am:is (subtypep 'bark:bark-configuration-error 'bark:bark-error))
  (5am:is (subtypep 'bark:bark-lifecycle-error 'bark:bark-error))
  (5am:is (subtypep 'bark:bark-async-stopped 'bark:bark-lifecycle-error))
  (5am:is (subtypep 'bark:bark-child-operation-error 'bark:bark-lifecycle-error))
  (5am:is (subtypep 'bark:bark-error 'cl:error)))

(5am:test test-consistent-hash-keep-p-rate-1-always-keeps
  "Rate 1 means mod hash 1 = 0 always, so every key is kept."
  (dolist (key '("foo" "bar" 42 :baz))
    (5am:is-true (bark::consistent-hash-keep-p key 1))))

(5am:test test-consistent-hash-keep-p-distribution
  "With a large sample, rate=N keeps roughly 1/N of distinct keys."
  (let* ((rate 10)
         (n 10000)
         (kept (loop for i below n
                     count (bark::consistent-hash-keep-p (format nil "key-~d" i) rate))))
    ;; Expect ~1000 (1/10 of 10000). Allow 20% tolerance.
    (5am:is (< 700 kept 1300)
            "Expected ~1000 kept out of 10000 at rate 10, got ~d" kept)))

(5am:test test-windowed-allow-p-initial-burst
  "Counts <= initial are always allowed."
  (let ((wc (make-windowed-counter :initial 5 :thereafter 100)))
    (5am:is-true (bark::windowed-allow-p 1 wc))
    (5am:is-true (bark::windowed-allow-p 5 wc))
    (5am:is-false (bark::windowed-allow-p 6 wc))))

(5am:test test-windowed-allow-p-thereafter-sampling
  "After initial burst, only every Nth message passes."
  (let ((wc (make-windowed-counter :initial 3 :thereafter 10)))
    ;; After initial, counts 4-9 should be blocked, 10 should pass
    (5am:is-false (bark::windowed-allow-p 4 wc))
    (5am:is-false (bark::windowed-allow-p 9 wc))
    (5am:is-true (bark::windowed-allow-p 10 wc))
    (5am:is-false (bark::windowed-allow-p 11 wc))
    (5am:is-true (bark::windowed-allow-p 20 wc))))

(5am:test test-windowed-allow-p-hard-cap
  "Thereafter=0 means hard cap — nothing passes after initial."
  (let ((wc (make-windowed-counter :initial 2 :thereafter 0)))
    (5am:is-true (bark::windowed-allow-p 1 wc))
    (5am:is-true (bark::windowed-allow-p 2 wc))
    (5am:is-false (bark::windowed-allow-p 3 wc))
    (5am:is-false (bark::windowed-allow-p 100 wc))
    (5am:is-false (bark::windowed-allow-p 1000 wc))))

(5am:test test-write-json-string-basic
  "Writes a properly quoted JSON string."
  (5am:is (string= "\"hello\""
                    (with-output-to-string (s) (bark::write-json-string s "hello")))))

(5am:test test-write-json-string-escapes
  "Escapes control characters, quotes, and backslashes."
  (5am:is (string= "\"a\\\"b\""
                    (with-output-to-string (s) (bark::write-json-string s "a\"b"))))
  (5am:is (string= "\"a\\\\b\""
                    (with-output-to-string (s) (bark::write-json-string s "a\\b"))))
  (5am:is (string= "\"a\\nb\""
                    (with-output-to-string (s) (bark::write-json-string s (format nil "a~%b"))))))

(5am:test test-write-json-string-empty
  "Empty string produces two quotes."
  (5am:is (string= "\"\""
                    (with-output-to-string (s) (bark::write-json-string s "")))))
