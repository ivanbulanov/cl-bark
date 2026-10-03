;;; Copyright 2026 Ivan Bulanov
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; src/json.lisp — JSON serialization and formatter

(in-package #:bark)

;;; --- Configuration ---

(defvar *max-json-depth* 4
  "Maximum nesting depth for collections in emit-json-value.
   At depth 0, collections become <type> placeholders.")

(defvar *max-json-length* 20
  "Maximum number of elements emitted per collection.
   Excess elements are replaced by a single \"...\" sentinel.")

(defvar *max-json-stack-frames* 10
  "Maximum stack frames in JSON condition output. NIL means unlimited.")

(declaim (ftype (function (string stream) (values null &optional)) write-json-escaped-string))

;;; --- Serialization ---

(defun write-json-escaped-string (string stream)
  "Write STRING to STREAM with JSON escaping."
  (declare (optimize (speed 3) (safety 1)))
  (let ((string (coerce string 'simple-string)))
    (declare (type simple-string string))
  (loop for c of-type character across string do
    (case c
      (#\" (write-string "\\\"" stream))
      (#\\ (write-string "\\\\" stream))
      (#\Newline (write-string "\\n" stream))
      (#\Return (write-string "\\r" stream))
      (#\Tab (write-string "\\t" stream))
      (t (if (< (char-code c) 32)
             (format stream "\\u~4,'0X" (char-code c))
             (write-char c stream)))))))

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

;;; --- Formatter protocol ---

(defstruct (formatter (:constructor %make-formatter))
  "A formatter protocol: prepare-fn pre-serializes static context at logger creation,
   format-fn formats a log event at call time."
  (prepare-fn (lambda (parent-prepared delta-context)
                (declare (ignore parent-prepared delta-context))
                "")
              :type function :read-only t)
  (format-fn  (cl:error "format-fn is required")
              :type function :read-only t))

(setf (documentation 'formatter-p 'function) "Return T if OBJECT is a formatter."
      (documentation 'formatter-prepare-fn 'function) "Function of two arguments, the parent's prepared string (or NIL) and the delta context plist, returning the pre-serialized static context string for a logger. Called when a logger or child logger is created."
      (documentation 'formatter-format-fn 'function) "Function of five arguments, LEVEL (fixnum), PREPARED (string), CONTEXT (list), MESSAGE (string or NIL) and FIELDS (list), returning the formatted log line as a string. Called for each log event.")

(declaim (ftype (function (&key (:prepare-fn function) (:format-fn function))
                           (values formatter &optional))
                make-formatter))

(defun make-formatter (&key prepare-fn format-fn)
  "Create a formatter with a prepare/format protocol."
  (%make-formatter :prepare-fn (or prepare-fn
                                   (lambda (parent-prepared delta-context)
                                     (declare (ignore parent-prepared delta-context))
                                     ""))
                   :format-fn format-fn))

(declaim (ftype (function (function) (values function &optional)) make-concat-prepare-fn))

(defun make-concat-prepare-fn (serialize-fn)
  "Return a prepare-fn that serializes delta-context with SERIALIZE-FN
   and concatenates with parent-prepared."
  (lambda (parent-prepared delta-context)
    (let ((s (if delta-context (funcall serialize-fn delta-context) "")))
      (if parent-prepared
          (concatenate 'string parent-prepared s)
          s))))

(declaim (ftype (function (list) (values string &optional)) serialize-bindings-json))

(defun serialize-bindings-json (bindings)
  "Pre-serialize BINDINGS plist to a JSON fragment string."
  (with-output-to-string (s)
    (emit-json-fields s bindings)))

;;; --- Formatting ---

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
  "Return a JSON formatter struct with custom keys and formats.
   Pre-computes level prefix vector, timestamp key fragment, and message key fragment.
   Pass :level-key NIL to omit the level field entirely."
  (let ((prefixes (when level-key
                    (build-json-level-prefixes level-key level-format)))
        (ts-key (when timestamp (format nil "\"~a\":" timestamp-key)))
        (msg-key (format nil "\"~a\":\"" message-key)))
    (make-formatter
     :prepare-fn (make-concat-prepare-fn #'serialize-bindings-json)
     :format-fn
     (lambda (level prepared context message fields)
       (declare (optimize (speed 3) (safety 1)))
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
           ;; Prepared context (pre-serialized with leading commas)
           (let ((clen (length (the string prepared))))
             (when (plusp clen)
               (if wrote
                   (write-string prepared s)
                   (progn (write-string prepared s :start 1)
                          (setf wrote t)))))
           ;; Dynamic context and per-call fields
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
         (write-string "}" s))))))

;;; --- Standard Formatters ---

;;; Thin delegates to the factories with default settings.
;;; The factory closures are created once at load time.

(defparameter *default-json-formatter* (make-json-formatter)
  "Default JSON formatter instance.")

(declaim (ftype (function (fixnum string list (or null string) list) (values string &optional))
                json-formatter))

(defun json-formatter (level prepared context message fields)
  "Format a log entry as a single JSON line with default settings."
  (funcall (formatter-format-fn *default-json-formatter*)
           level prepared context message fields))
