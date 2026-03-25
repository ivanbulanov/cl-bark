
;;; src/logfmt.lisp — Logfmt serialization and formatter

(in-package #:bark)

(defun emit-logfmt-key (stream key)
  "Write a logfmt key to STREAM."
  (declare (optimize (speed 3) (safety 1)))
  (write-string (key-string key) stream))

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
                (t (write-char c stream))))
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
  "Write VALUE as a logfmt value to STREAM.  Scalars only."
  (typecase value
    (string (logfmt-write-bare-or-quoted stream value))
    (character (write-string (string value) stream))
    (integer (princ value stream))
    (float (cond
             ((or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value))
              (write-string "null" stream))
             (t (format stream "~F" value))))
    (ratio (format stream "~F" (coerce value 'double-float)))
    (null (write-string "null" stream))
    (symbol (write-string (key-string value) stream))
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
   Pass :level-key NIL to omit the level field entirely."
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
         (let ((wrote nil))
           (when level-prefix
             (write-string level-prefix s)
             (write-string (level-name level) s)
             (setf wrote t))
           (when ts-prefix
             (write-string (if wrote ts-prefix ts-prefix-first) s)
             (emit-timestamp timestamp s)
             (setf wrote t))
           (when (plusp (length (the string prepared)))
             (write-string prepared s)
             (setf wrote t))
           (dolist (pair context) (emit-logfmt-field s (car pair) (cdr pair)))
           (loop for (k v) on fields by #'cddr do (emit-logfmt-field s k v))
           (when message
             (write-string (if wrote msg-prefix msg-prefix-first) s)
             (emit-logfmt-value s message))))))))

(defparameter *default-logfmt-formatter* (make-logfmt-formatter)
  "Default logfmt formatter instance.")

(declaim (ftype (function (fixnum string list (or null string) list) (values string &optional))
                logfmt-formatter))

(defun logfmt-formatter (level prepared context message fields)
  "Format a log entry as a logfmt line with default settings."
  (funcall (formatter-format-fn *default-logfmt-formatter*)
           level prepared context message fields))
