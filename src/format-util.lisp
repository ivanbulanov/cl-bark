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

;;; src/format-util.lisp — Shared formatting utilities

(in-package #:bark)

;;; --- Reusable format stream (thread-safe, lock-free) ---

;;; Each thread gets its own string-output-stream via dynamic binding.
;;; New threads auto-bind via bt:*default-special-bindings*.
;;; The internal buffer grows to the largest log line seen, then stays there —
;;; no per-call allocation for the stream itself, only for the result string.

;;; --- Formatting ---

(defvar *format-stream* nil
  "Per-thread reusable string-output-stream for formatters.
   Bound per-thread via bt:*default-special-bindings*; lazily created on first use.")

(pushnew '(*format-stream* . nil) bt:*default-special-bindings*
         :key #'car)

(declaim (inline acquire-format-stream))

(defun acquire-format-stream ()
  "Take the current thread's reusable string-output-stream, or allocate a fresh one.
   The slot is cleared with a CAS while the stream is in use, so a re-entrant
   call (a PRINT-OBJECT or condition :REPORT that logs) and threads that share
   the global binding (threads not created through bordeaux-threads) each get
   their own stream instead of writing into the same one."
  (let ((s *format-stream*))
    (if (and s (atomics:cas (symbol-value '*format-stream*) s nil))
        s
        (make-string-output-stream))))

(defmacro with-format-stream ((var) &body body)
  "Execute BODY with VAR bound to a reusable string-output-stream and return the
   accumulated string. Printer control variables that would change the syntax of
   numbers and symbols (*PRINT-BASE*, *PRINT-RADIX*, *PRINT-PRETTY*,
   *PRINT-READABLY*, *PRINT-CASE*) are bound to their standard values so ambient
   settings cannot corrupt a log line. If BODY exits non-locally the partial
   output is discarded, so the next line on this thread starts clean.
   Thread-safe and re-entrant: see ACQUIRE-FORMAT-STREAM."
  (let ((result (gensym "RESULT")))
    `(let ((,var (acquire-format-stream))
           (*print-base* 10)
           (*print-radix* nil)
           (*print-pretty* nil)
           (*print-readably* nil)
           (*print-case* :upcase)
           (,result nil))
       (unwind-protect
            (progn ,@body
                   (setf ,result (get-output-stream-string ,var)))
         ;; A non-local exit leaves a partial line behind; drop it before
         ;; handing the stream back.
         (unless ,result (get-output-stream-string ,var))
         (setf *format-stream* ,var))
       ,result)))

(declaim (inline message-string))

(defun message-string (message)
  "Normalize a log MESSAGE to a string or NIL. Non-string messages (numbers,
   symbols, objects) are printed with PRINC so a log call never signals."
  (if (or (null message) (stringp message))
      message
      (princ-to-string message)))

;;; --- Helpers ---

(declaim (inline type-name-string))
(defun type-name-string (value)
  "Return the type of VALUE as a lowercase string."
  (string-downcase (princ-to-string (type-of value))))

(defvar *key-string-cache* (make-hash-table :test 'eq #+sbcl :synchronized #+sbcl t)
  "Cache for symbol → downcased string. Bounded by *key-string-cache-limit*.")

(defvar *key-string-cache-limit* 1024
  "Maximum entries in the key-string cache. New symbols still work but aren't cached past this.")

(defun key-string (key)
  "Convert a field key to its lowercase string representation.
   Symbol results are memoized in *key-string-cache*."
  (typecase key
    (string key)
    (symbol (or (gethash key *key-string-cache*)
                ;; Ordinary symbols read as upper case and are emitted lower case.
                ;; A name that already contains lower-case characters was written
                ;; with escapes (:|userId|) and is kept verbatim.
                (let* ((name (symbol-name key))
                       (s (if (some #'lower-case-p name) name (string-downcase name))))
                  (when (< (hash-table-count *key-string-cache*) *key-string-cache-limit*)
                    (setf (gethash key *key-string-cache*) s))
                  s)))
    (t (princ-to-string key))))

(defun write-angle-type (stream value)
  "Write <type> for VALUE to STREAM (no quotes)."
  (write-char #\< stream)
  (write-string (type-name-string value) stream)
  (write-char #\> stream))

(defun condition-message-string (condition)
  "Return CONDITION's report text. A report function that itself signals
   yields a placeholder instead of propagating out of the log call."
  (handler-case (princ-to-string condition)
    (cl:error (e)
      (format nil "<report failed: ~a>" (type-name-string e)))))

(defun write-condition-summary (stream condition)
  "Write type: message for CONDITION to STREAM."
  (write-string (type-name-string condition) stream)
  (write-string ": " stream)
  (write-string (condition-message-string condition) stream))
