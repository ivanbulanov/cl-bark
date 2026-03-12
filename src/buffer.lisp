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

;;; --- Buffer logger ---

(defun make-buffer-capture-fn (level-value buffer)
  "Create a function that captures log calls into BUFFER instead of formatting."
  (lambda (lgr message &rest fields)
    (declare (ignore lgr) (dynamic-extent fields))
    (vector-push-extend
     (make-buffer-entry :level level-value
                        :message message
                        :fields (copy-list fields)
                        :context (copy-list *log-context*)
                        :timestamp (get-unix-timestamp-ms))
     buffer)
    (values)))

(defun make-buffer-logger (original buffer-level buffer)
  "Create a buffer-logger: a copy of ORIGINAL with level lowered to BUFFER-LEVEL,
   field-transform and sampler cleared, and level slots replaced with capture functions."
  (let ((lgr (%make-logger
              :name (logger-name original)
              :chindings (logger-chindings original)
              :raw-bindings (logger-raw-bindings original)
              :formatter (logger-formatter original)
              :output (logger-output original)
              :field-transform nil
              :sampler nil)))
    (setf (logger-level lgr) buffer-level)
    (setf (logger-trace-fn lgr) (if (< +trace+ buffer-level) #'noop (make-buffer-capture-fn +trace+ buffer)))
    (setf (logger-debug-fn lgr) (if (< +debug+ buffer-level) #'noop (make-buffer-capture-fn +debug+ buffer)))
    (setf (logger-info-fn lgr)  (if (< +info+  buffer-level) #'noop (make-buffer-capture-fn +info+  buffer)))
    (setf (logger-warn-fn lgr)  (if (< +warn+  buffer-level) #'noop (make-buffer-capture-fn +warn+  buffer)))
    (setf (logger-error-fn lgr) (if (< +error+ buffer-level) #'noop (make-buffer-capture-fn +error+ buffer)))
    (setf (logger-fatal-fn lgr) (if (< +fatal+ buffer-level) #'noop (make-buffer-capture-fn +fatal+ buffer)))
    lgr))
