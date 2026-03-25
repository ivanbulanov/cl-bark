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

(defmacro with-format-stream ((var) &body body)
  "Execute BODY with VAR bound to a reusable string-output-stream.
   Returns the accumulated string, resetting the stream for next use.
   Thread-safe: each thread has its own binding via dynamic variables."
  `(let ((,var (or *format-stream*
                   (setf *format-stream* (make-string-output-stream)))))
     ,@body
     (get-output-stream-string ,var)))

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
                (let ((s (string-downcase (symbol-name key))))
                  (when (< (hash-table-count *key-string-cache*) *key-string-cache-limit*)
                    (setf (gethash key *key-string-cache*) s))
                  s)))
    (t (princ-to-string key))))

(defun write-angle-type (stream value)
  "Write <type> for VALUE to STREAM (no quotes)."
  (write-char #\< stream)
  (write-string (type-name-string value) stream)
  (write-char #\> stream))

(defun write-condition-summary (stream condition)
  "Write type: message for CONDITION to STREAM."
  (write-string (type-name-string condition) stream)
  (write-string ": " stream)
  (princ condition stream))
