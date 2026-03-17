;;; src/json.lisp — JSON serialization and formatter

(in-package #:bark)

;;; --- Serialization Limits ---

(defvar *max-json-depth* 4
  "Maximum nesting depth for collections in emit-json-value.
   At depth 0, collections become <type> placeholders.")

(defvar *max-json-length* 20
  "Maximum number of elements emitted per collection.
   Excess elements are replaced by a single \"...\" sentinel.")

(defvar *max-json-stack-frames* 10
  "Maximum stack frames in JSON condition output. NIL means unlimited.")

;;; --- JSON Output ---

(declaim (ftype (function (string stream) (values null &optional)) write-json-escaped-string))

(defun write-json-escaped-string (string stream)
  "Write STRING to STREAM with JSON escaping."
  (declare (optimize (speed 3) (safety 1))
           (type simple-string string))
  (loop for c of-type character across string do
    (case c
      (#\" (write-string "\\\"" stream))
      (#\\ (write-string "\\\\" stream))
      (#\Newline (write-string "\\n" stream))
      (#\Return (write-string "\\r" stream))
      (#\Tab (write-string "\\t" stream))
      (t (if (< (char-code c) 32)
             (format stream "\\u~4,'0X" (char-code c))
             (write-char c stream))))))

(declaim (inline write-json-string))
(defun write-json-string (stream string)
  "Write STRING as a JSON quoted string to STREAM."
  (write-char #\" stream)
  (write-json-escaped-string string stream)
  (write-char #\" stream))

(defun emit-type-placeholder (stream value)
  "Write a \"<type>\" placeholder for VALUE to STREAM as a JSON string."
  (write-char #\" stream)
  (write-angle-type stream value)
  (write-char #\" stream))

(defun emit-json-condition-fields (stream condition)
  "Write \"type\":\"...\",\"msg\":\"...\" for CONDITION to STREAM.
   No enclosing braces — callers provide { and }."
  (write-string "\"type\":\"" stream)
  (write-json-escaped-string (type-name-string condition) stream)
  (write-string "\",\"msg\":\"" stream)
  (write-json-escaped-string (princ-to-string condition) stream)
  (write-char #\" stream))

(defun emit-json-stack-frame (stream frame)
  "Write one stack frame as a JSON object {\"call\":...,\"file\":...,\"line\":...}."
  (write-string "{\"call\":\"" stream)
  (let ((call (dissect:call frame)))
    (write-json-escaped-string (key-string call) stream))
  (write-char #\" stream)
  (let ((file (dissect:file frame)))
    (when file
      (write-string ",\"file\":\"" stream)
      (write-json-escaped-string (namestring file) stream)
      (write-char #\" stream)))
  (let ((line (dissect:line frame)))
    (when line
      (write-string ",\"line\":" stream)
      (princ line stream)))
  (write-char #\} stream))

(defun emit-json-stack (stream stack)
  "Write ,\"stack\":[...] bounded by *max-json-stack-frames*."
  (write-string ",\"stack\":[" stream)
  (let ((limit *max-json-stack-frames*)
        (i 0))
    (cond
      ((null stack))
      (t
       (dolist (frame stack)
         (when (and limit (>= i limit))
           (when (plusp i) (write-char #\, stream))
           (write-string "{\"call\":\"...\"}" stream)
           (return))
         (when (plusp i) (write-char #\, stream))
         (emit-json-stack-frame stream frame)
         (incf i)))))
  (write-char #\] stream))

(defun emit-json-key (stream key &optional (separator #\,))
  "Write KEY as a JSON object key to STREAM, preceded by SEPARATOR.
   Pass NIL as separator to omit the leading comma (first field in object)."
  (declare (optimize (speed 3) (safety 1)))
  (when separator (write-char separator stream))
  (write-char #\" stream)
  (typecase key
    (string (write-json-escaped-string key stream))
    (symbol (write-json-escaped-string (key-string key) stream))
    (t (write-json-escaped-string (princ-to-string key) stream)))
  (write-string "\":" stream))

(defun coerce-hash-key (k)
  "Coerce hash-table key K to a string for JSON output."
  (typecase k
    (string k)
    (symbol (key-string k))
    (pathname (namestring k))
    (t (princ-to-string k))))

(defun emit-json-value (stream value &optional (depth *max-json-depth*))
  "Write VALUE as JSON to STREAM.  Collections recurse up to DEPTH levels."
  (declare (optimize (speed 3) (safety 1))
           (type fixnum depth))
  (typecase value
    (string    (write-json-string stream value))
    (character (write-json-string stream (string value)))
    (integer (princ value stream))
    (float (cond
             ((or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value))
              (write-string "null" stream))
             (t (format stream "~F" value))))
    (ratio (format stream "~F" (coerce value 'double-float)))
    ((eql t) (write-string "true" stream))
    (null (write-string "null" stream))
    (symbol    (write-json-string stream (key-string value)))
    (pathname  (write-json-string stream (namestring value)))
    (cons
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (progn
           (write-char #\[ stream)
           (loop for cell on value
                 for i fixnum from 0
                 for first = t then nil
                 when (>= i *max-json-length*)
                   do (unless first (write-char #\, stream))
                      (write-string "\"...\"" stream)
                      (loop-finish)
                 unless first do (write-char #\, stream)
                 do (emit-json-value stream (car cell) (1- depth))
                 when (and (cdr cell) (atom (cdr cell)))
                   do (write-char #\, stream)
                      (emit-json-value stream (cdr cell) (1- depth))
                      (loop-finish))
           (write-char #\] stream))))
    (vector
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (let ((len (length value)))
           (write-char #\[ stream)
           (loop for i fixnum from 0 below len
                 when (>= i *max-json-length*)
                   do (when (plusp i) (write-char #\, stream))
                      (write-string "\"...\"" stream)
                      (loop-finish)
                 when (plusp i) do (write-char #\, stream)
                 do (emit-json-value stream (aref value i) (1- depth)))
           (write-char #\] stream))))
    (hash-table
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (let ((first t)
               (count 0))
           (declare (type fixnum count))
           (write-char #\{ stream)
           (block hash-done
             (maphash (lambda (k v)
                        (when (>= count *max-json-length*)
                          (unless first (write-char #\, stream))
                          (write-string "\"...\":\"...\"" stream)
                          (return-from hash-done))
                        (if first (setf first nil) (write-char #\, stream))
                        (write-char #\" stream)
                        (write-json-escaped-string (coerce-hash-key k) stream)
                        (write-string "\":" stream)
                        (emit-json-value stream v (1- depth))
                        (incf count))
                      value))
           (write-char #\} stream))))
    (captured-error
     (write-char #\{ stream)
     (emit-json-condition-fields stream (captured-error-condition value))
     (emit-json-stack stream (captured-error-stack value))
     (write-char #\} stream))
    (condition
     (write-char #\{ stream)
     (emit-json-condition-fields stream value)
     (write-char #\} stream))
    (t (emit-type-placeholder stream value))))

(defun emit-json-fields (stream fields &optional (first-separator #\,))
  "Write a plist of FIELDS as JSON key-value pairs to STREAM.
   FIRST-SEPARATOR is the separator before the first key (NIL to omit)."
  (declare (optimize (speed 3) (safety 1)))
  (loop for (k v) on fields by #'cddr
        for sep = first-separator then #\,
        do (emit-json-key stream k sep)
           (emit-json-value stream v)))

(defun emit-context-fields (stream context &optional (first-separator #\,))
  "Write dynamic context fields (alist) as JSON key-value pairs to STREAM.
   FIRST-SEPARATOR is the separator before the first key (NIL to omit)."
  (declare (optimize (speed 3) (safety 1)))
  (loop for pair in context
        for sep = first-separator then #\,
        do (emit-json-key stream (car pair) sep)
           (emit-json-value stream (cdr pair))))

(declaim (ftype (function (list) (values string &optional)) serialize-bindings))

(defun serialize-bindings (bindings)
  "Pre-serialize BINDINGS plist to a JSON fragment string."
  (with-output-to-string (s)
    (emit-json-fields s bindings)))

(defun build-json-level-prefixes (level-key level-format)
  "Build a vector of pre-computed JSON level field strings (without opening brace).
   LEVEL-KEY is the JSON key name (e.g. \"level\" or \"severity\").
   LEVEL-FORMAT is :numeric or :string."
  (let ((prefixes (make-array +level-slot-count+ :initial-element nil)))
    (loop for i from +trace+ to +fatal+
          do (setf (aref prefixes i)
                   (ecase level-format
                     (:numeric (format nil "\"~a\":~d" level-key i))
                     (:string (format nil "\"~a\":\"~a\"" level-key (level-name i))))))
    prefixes))

(defun make-json-formatter (&key (timestamp :unix-ms) (level-format :string)
                                  (level-key "level") (timestamp-key "ts")
                                  (message-key "msg"))
  "Return a JSON formatter closure with custom keys and formats.
   Pre-computes level prefix vector, timestamp key fragment, and message key fragment.
   Pass :level-key NIL to omit the level field entirely."
  (let ((prefixes (when level-key
                    (build-json-level-prefixes level-key level-format)))
        (ts-key (when timestamp (format nil "\"~a\":" timestamp-key)))
        (msg-key (format nil "\"~a\":\"" message-key)))
    (lambda (level chindings raw-bindings context message fields)
      (declare (optimize (speed 3) (safety 1)))
      (declare (ignore raw-bindings))
      (with-format-stream (s)
        (write-char #\{ s)
        (let ((wrote nil))
          ;; Level
          (when prefixes
            (write-string (svref prefixes level) s)
            (setf wrote t))
          ;; Timestamp
          (when ts-key
            (when wrote (write-char #\, s))
            (write-string ts-key s)
            (emit-timestamp timestamp s)
            (setf wrote t))
          ;; Chindings (pre-serialized with leading commas)
          (let ((clen (length chindings)))
            (when (plusp clen)
              (if wrote
                  (write-string chindings s)
                  (progn (write-string chindings s :start 1)
                         (setf wrote t)))))
          ;; Context and fields
          (let ((sep (if wrote #\, nil)))
            (emit-context-fields s context sep)
            (when context (setf sep #\,))
            (emit-json-fields s fields sep)
            (when fields (setf sep #\,))
            ;; Message
            (when message
              (when sep (write-char sep s))
              (write-string msg-key s)
              (write-json-escaped-string message s)
              (write-string "\"" s))))
        (write-string "}" s)))))

;;; --- Standard Formatters ---
;;; Thin delegates to the factories with default settings.
;;; The factory closures are created once at load time.

(declaim (ftype (function (fixnum string list list (or null string) list) (values string &optional))
                json-formatter))

(let ((fmt (make-json-formatter)))
  (defun json-formatter (level chindings raw-bindings context message fields)
    "Format a log entry as a single JSON line with default settings.
Equivalent to (funcall (make-json-formatter) ...) with no customization.
Field values: strings, numbers, booleans, symbols, pathnames, lists, vectors,
hash-tables, conditions, and captured-errors serialize to JSON natively.
Unsupported types produce a \"<type>\" placeholder. See docs/value-serialization.md."
    (funcall fmt level chindings raw-bindings context message fields)))
