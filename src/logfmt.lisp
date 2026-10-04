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

;;; src/logfmt.lisp — Logfmt serialization and formatter

(in-package #:bark)

(defun emit-logfmt-key (stream key)
  "Write a logfmt key to STREAM. logfmt has no quoting for keys, so characters a
   key cannot carry (space, =, double quote, control characters) are written as _."
  (declare (optimize (speed 3) (safety 1)))
  (loop for c of-type character across (the string (key-string key))
        do (write-char (if (or (char= c #\Space) (char= c #\=) (char= c #\")
                               (< (char-code c) 32))
                           #\_
                           c)
                       stream)))

(defun logfmt-write-bare-or-quoted (stream string)
  "Write STRING to STREAM, quoting if it contains space, quote, equals, backslash,
   or control characters. Escapes quotes, backslashes, newlines, returns, and tabs."
  (declare (optimize (speed 3) (safety 1)))
  (let ((string (coerce string 'simple-string)))
    (declare (type simple-string string))
    (let ((needs-quoting nil))
      (loop for c of-type character across string
            when (or (char= c #\Space) (char= c #\") (char= c #\=)
                     (char= c #\\) (< (char-code c) 32))
              do (setf needs-quoting t) (loop-finish))
      (if needs-quoting
          (progn
            (write-char #\" stream)
            (loop for c of-type character across string do
              (case c
                (#\" (write-string "\\\"" stream))
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (t (if (< (char-code c) 32)
                       (format stream "\\u~4,'0X" (char-code c))
                       (write-char c stream)))))
            (write-char #\" stream))
          (write-string string stream)))))

;;; --- Logfmt formatting ---

(defun emit-logfmt-condition (stream condition)
  "Write CONDITION as a quoted logfmt value: \"type: message\".
   Escapes quotes, backslashes, newlines, returns, and tabs in the message."
  (logfmt-write-bare-or-quoted
   stream
   (with-output-to-string (s) (write-condition-summary s condition))))

(defun emit-logfmt-value (stream value)
  "Write VALUE as a logfmt value to STREAM.  Scalars only.
   Strings, characters and symbols are quoted when they contain characters that
   would break the key=value grammar; numbers use JSON number syntax."
  (typecase value
    (string (logfmt-write-bare-or-quoted stream value))
    (character (logfmt-write-bare-or-quoted stream (string value)))
    (real (write-json-number stream value))
    (null (write-string "null" stream))
    (symbol (logfmt-write-bare-or-quoted stream (key-string value)))
    (pathname (logfmt-write-bare-or-quoted stream (namestring value)))
    (captured-error (emit-logfmt-condition stream (captured-error-condition value)))
    (condition (emit-logfmt-condition stream value))
    (t (write-angle-type stream value))))

(defun emit-logfmt-field (stream key value)
  "Write a logfmt key=value pair to STREAM, preceded by a space.
   Boolean T emits bare key (logfmt convention for flags)."
  (write-char #\Space stream)
  (emit-logfmt-key stream key)
  (unless (eq value t)
    (write-char #\= stream)
    (emit-logfmt-value stream value)))

(declaim (ftype (function (list) (values string &optional)) serialize-bindings-logfmt))

(defun serialize-bindings-logfmt (bindings)
  "Pre-serialize BINDINGS plist to a logfmt fragment string."
  (with-output-to-string (s)
    (loop for (k v) on bindings by #'cddr
          do (emit-logfmt-field s k v))))

(defun make-logfmt-formatter (&key (timestamp :unix-ms) (level-key "level")
                                    (timestamp-key "ts") (message-key "msg"))
  "Return a logfmt formatter struct with custom keys.
   Level is always string for logfmt. Pre-computes key name strings.
   Pass :level-key NIL to omit the level field entirely.
   Signals BARK-CONFIGURATION-ERROR for an unknown TIMESTAMP."
  (check-timestamp-format timestamp)
  (let ((level-prefix (when level-key (format nil "~a=" level-key)))
        (ts-prefix (when timestamp (format nil " ~a=" timestamp-key)))
        (ts-prefix-first (when timestamp (format nil "~a=" timestamp-key)))
        (msg-prefix (format nil " ~a=" message-key))
        (msg-prefix-first (format nil "~a=" message-key)))
    (make-formatter
     :prepare-fn (make-concat-prepare-fn #'serialize-bindings-logfmt)
     :format-fn
     (lambda (level prepared context message fields)
       (with-format-stream (s)
         ;; WROTE tracks whether anything precedes the next item, so every
         ;; separator is a single space and the line never starts with one.
         (let ((wrote nil))
           (flet ((field (k v)
                    (when wrote (write-char #\Space s))
                    (emit-logfmt-key s k)
                    (unless (eq v t)
                      (write-char #\= s)
                      (emit-logfmt-value s v))
                    (setf wrote t)))
             (when level-prefix
               (write-string level-prefix s)
               (write-string (level-name level) s)
               (setf wrote t))
             (when ts-prefix
               (write-string (if wrote ts-prefix ts-prefix-first) s)
               (emit-timestamp timestamp s)
               (setf wrote t))
             ;; PREPARED is pre-serialized with a leading space per field.
             (when (plusp (length (the string prepared)))
               (write-string prepared s :start (if wrote 0 1))
               (setf wrote t))
             (dolist (pair context) (field (car pair) (cdr pair)))
             (loop for (k v) on fields by #'cddr do (field k v))
             (when message
               (write-string (if wrote msg-prefix msg-prefix-first) s)
               (emit-logfmt-value s message)))))))))

(defparameter *default-logfmt-formatter* (make-logfmt-formatter)
  "Default logfmt formatter instance.")

(declaim (ftype (function (fixnum string list (or null string) list) (values string &optional))
                logfmt-formatter))

(defun logfmt-formatter (level prepared context message fields)
  "Format a log entry as a logfmt line with default settings."
  (funcall (formatter-format-fn *default-logfmt-formatter*)
           level prepared context message fields))
