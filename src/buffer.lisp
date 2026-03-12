;;; src/buffer.lisp — Request-scoped log buffering

(in-package #:bark)

;;; --- Buffer entry ---

(defstruct (buffer-entry (:constructor make-buffer-entry))
  "A single buffered log entry, captured for deferred emission."
  (level     0   :type fixnum)
  (message   ""  :type string)
  (fields    nil :type list)
  (context   nil :type list)
  (timestamp 0   :type (integer 0)))
