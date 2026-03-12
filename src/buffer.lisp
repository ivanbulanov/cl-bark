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

;;; --- Flush ---

(defun emit-entry (root-logger entry)
  "Replay a single buffer ENTRY through ROOT-LOGGER's output pipeline."
  (let* ((*override-timestamp* (buffer-entry-timestamp entry))
         (transform (logger-field-transform root-logger))
         (ctx (if transform
                  (apply-field-transform-alist transform (buffer-entry-context entry))
                  (buffer-entry-context entry)))
         (flds (if transform
                   (apply-field-transform-plist transform (buffer-entry-fields entry))
                   (buffer-entry-fields entry)))
         (output (logger-output root-logger)))
    (when output
      (if (tee-output-p output)
          (emit-to-tee output
                       (buffer-entry-level entry)
                       (logger-chindings root-logger)
                       (logger-raw-bindings root-logger)
                       ctx
                       (buffer-entry-message entry)
                       flds)
          (let ((line (funcall (the function (logger-formatter root-logger))
                               (buffer-entry-level entry)
                               (logger-chindings root-logger)
                               (logger-raw-bindings root-logger)
                               ctx
                               (buffer-entry-message entry)
                               flds)))
            (if (async-output-p output)
                (progn
                  (ring-buffer-push (async-output-ring output) line)
                  (bt:signal-semaphore (async-output-notify output)))
                (etypecase output
                  (stream (write-string line output) (terpri output) (force-output output))
                  (function (funcall output line)))))))))

(defun flush-buffer (buffer root-logger normal-exit-p condition on-flush original-level)
  "Flush BUFFER entries through ROOT-LOGGER. Selection logic:
   - on-flush provided: delegate to callback (entries, condition, normal-exit-p).
   - Abnormal exit with condition: emit all entries.
   - Otherwise: emit entries >= original-level."
  (when (zerop (length buffer))
    (return-from flush-buffer (values)))
  (let ((entries (if on-flush
                     (funcall on-flush buffer condition normal-exit-p)
                     (if (and (not normal-exit-p) condition)
                         buffer
                         nil))))
    (if entries
        ;; Emit the selected entries
        (loop for entry across entries
              do (emit-entry root-logger entry))
        ;; No on-flush and normal exit (or non-condition NLX): filter by level
        (unless on-flush
          (loop for entry across buffer
                when (>= (buffer-entry-level entry) original-level)
                  do (emit-entry root-logger entry)))))
  (values))
