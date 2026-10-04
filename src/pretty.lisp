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

;;; src/pretty.lisp — Pretty (ANSI) formatter

(in-package #:bark)

;;; --- Pretty formatting ---

(defvar *max-pretty-depth* 4
  "Bound as CL:*PRINT-LEVEL* inside pretty-formatter.
   Controls nesting depth for value output. NIL means unlimited.")

(defvar *max-pretty-length* 20
  "Bound as CL:*PRINT-LENGTH* inside pretty-formatter.
   Controls max elements per collection. NIL means unlimited.")

(defvar *max-pretty-stack-frames* 20
  "Maximum stack frames in pretty-formatter condition output. NIL means unlimited.")

;;; --- Pretty Formatter Helpers ---

(defun format-frame-call (frame)
  "Format a stack frame's call as an uppercase string."
  (let ((call (dissect:call frame)))
    (if (symbolp call)
        (symbol-name call)
        (string-upcase (princ-to-string call)))))

(defun emit-pretty-stack (stream stacks)
  "Write accumulated stack traces. STACKS is a list of (key . captured-error) pairs."
  (let ((single-p (= 1 (length stacks))))
    (dolist (entry stacks)
      (let* ((key (car entry))
             (ce (cdr entry))
             (frames (captured-error-stack ce))
             (limit *max-pretty-stack-frames*)
             (total (length frames)))
        ;; Label when multiple stacks
        (unless single-p
          (format stream "~%  ~c[2m~a~c[0m:" #\Esc (key-string key) #\Esc))
        (let ((indent (if single-p "  " "    "))
              (i 0))
          (dolist (frame frames)
            (when (and limit (>= i limit))
              (format stream "~%~a~c[2m... (~d more frames)~c[0m"
                      indent #\Esc (- total i) #\Esc)
              (return))
            (let ((file (dissect:file frame))
                  (line (dissect:line frame)))
              (format stream "~%~a~c[1mat ~a~c[0m" indent #\Esc (format-frame-call frame) #\Esc)
              (when (or file line)
                (format stream " ~c[2m(~@[~a~]~@[:~d~])~c[0m"
                        #\Esc
                        (when file (namestring file))
                        line
                        #\Esc)))
            (incf i)))))))

(declaim (ftype (function (list) (values string &optional)) serialize-bindings-pretty))

(defun serialize-bindings-pretty (bindings)
  "Pre-serialize BINDINGS plist to a pretty fragment string."
  (with-output-to-string (s)
    (let ((*print-level* *max-pretty-depth*)
          (*print-length* *max-pretty-length*)
          (*print-circle* t))
      (loop for (k v) on bindings by #'cddr
            do (format s " ~c[2m~a~c[0m=" #\Esc (key-string k) #\Esc)
               (cond
                 ((captured-error-p v)
                  (write-condition-summary s (captured-error-condition v)))
                 ((typep v 'condition)
                  (write-condition-summary s v))
                 (t (princ v s)))))))

(defun make-pretty-formatter (&key timestamp (timestamp-key "ts") (show-level t))
  "Return a pretty formatter struct with optional timestamp display.
   TIMESTAMP is nil (no timestamp), :iso8601, or :unix-ms.
   Level is always colored string. Pass :show-level NIL to omit it.
   Signals BARK-CONFIGURATION-ERROR for an unknown TIMESTAMP."
  (check-timestamp-format timestamp)
  (let ((ts-prefix (when timestamp (format nil " ~c[2m~a~c[0m=" #\Esc timestamp-key #\Esc)))
        (ts-prefix-first (when timestamp (format nil "~c[2m~a~c[0m=" #\Esc timestamp-key #\Esc))))
    (make-formatter
     :prepare-fn (make-concat-prepare-fn #'serialize-bindings-pretty)
     :format-fn
     (lambda (level prepared context message fields)
       (with-format-stream (s)
         (let* ((*print-level* *max-pretty-depth*)
                (*print-length* *max-pretty-length*)
                (*print-circle* t)
                (stacks nil)
                (wrote nil))
           ;; WROTE tracks whether anything precedes the next item, so the
           ;; line never starts with a separator space.
           (flet ((write-key (k)
                    (when wrote (write-char #\Space s))
                    (format s "~c[2m~a~c[0m=" #\Esc (key-string k) #\Esc)
                    (setf wrote t))
                  (write-val (k v)
                    (cond
                      ((captured-error-p v)
                       (write-condition-summary s (captured-error-condition v))
                       (push (cons k v) stacks))
                      ((typep v 'condition)
                       (write-condition-summary s v))
                      (t (princ v s)))))
             (when show-level
               (let ((color (svref *level-colors* level)))
                 (format s "~c[~am~a~c[0m" #\Esc color (svref *level-names-upper* level) #\Esc))
               (setf wrote t))
             (when ts-prefix
               (write-string (if wrote ts-prefix ts-prefix-first) s)
               (emit-timestamp timestamp s)
               (setf wrote t))
             (when message
               (when wrote (write-char #\Space s))
               (write-string message s)
               (setf wrote t))
             ;; Splice pre-serialized static context (leading space per field)
             (when (plusp (length (the string prepared)))
               (write-string prepared s :start (if wrote 0 1))
               (setf wrote t))
             ;; Dynamic context
             (dolist (pair context)
               (write-key (car pair)) (write-val (car pair) (cdr pair)))
             ;; Per-call fields
             (loop for (k v) on fields by #'cddr do
               (write-key k) (write-val k v))
             (when stacks
               (emit-pretty-stack s (nreverse stacks))))))))))

(defparameter *default-pretty-formatter* (make-pretty-formatter)
  "Default pretty formatter instance.")

(declaim (ftype (function (fixnum string list (or null string) list) (values string &optional))
                pretty-formatter))

(defun pretty-formatter (level prepared context message fields)
  "Format a log entry as colored human-readable text with default settings."
  (funcall (formatter-format-fn *default-pretty-formatter*)
           level prepared context message fields))
