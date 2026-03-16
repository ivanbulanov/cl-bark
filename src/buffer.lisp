;;; src/buffer.lisp — Request-scoped log buffering

(in-package #:bark)

;;; --- Buffer entry ---

(defstruct (buffer-entry (:constructor make-buffer-entry))
  "A single buffered log entry, captured for deferred emission."
  (level     0   :type fixnum)
  (message   nil :type (or null string))
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
                        :context *log-context*
                        :timestamp (get-unix-timestamp-ms))
     buffer)
    (values)))

(defun make-buffer-logger (original buffer-level buffer)
  "Create a buffer-logger: a copy of ORIGINAL with level lowered to BUFFER-LEVEL,
   field-transform and sampler cleared, and level slots replaced with capture functions."
  (let ((lgr (%make-logger
              :chindings (logger-chindings original)
              :raw-bindings (logger-raw-bindings original)
              :formatter (logger-formatter original)
              :output (logger-output original)
              :field-transform nil)))
    (setf (logger-level lgr) buffer-level)
    (wire-level-fns lgr buffer-level
                    (lambda (level) (make-buffer-capture-fn level buffer)))
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
      (dispatch-to-output output (logger-formatter root-logger)
                          (buffer-entry-level entry)
                          (logger-chindings root-logger)
                          (logger-raw-bindings root-logger)
                          ctx
                          (buffer-entry-message entry)
                          flds))))

;;; --- Root logger tracking ---

(defvar *root-logger* nil
  "The non-buffer logger that all buffer scopes flush through.
   Bound by the outermost with-log-buffer; inner scopes read but don't rebind.")

;;; --- with-log-buffer ---

(defmacro with-log-buffer ((logger &key (level :trace) on-flush) &body body)
  "Execute BODY with log calls to LOGGER buffered via *logger*.
   LOGGER is evaluated once and bound to *logger* as a buffer-logger for the body's
   dynamic extent. Only implicit log calls (through *logger*) are buffered; explicit
   logger arguments bypass the buffer.
   LEVEL is the capture threshold (default :trace). ON-FLUSH, if provided, is called
   as (funcall on-flush entries condition normal-exit-p) to select entries to emit."
  (let ((source-lgr (gensym "SOURCE-LGR"))
        (buffer (gensym "BUFFER"))
        (condition (gensym "CONDITION"))
        (normal-exit-p (gensym "NORMAL-EXIT-P"))
        (root (gensym "ROOT"))
        (original-level (gensym "ORIG-LEVEL"))
        (buf-lgr (gensym "BUF-LGR"))
        (on-flush-fn (gensym "ON-FLUSH"))
        (buffer-level (gensym "BUF-LEVEL")))
    `(let ((,source-lgr ,logger))
       (if (null ,source-lgr)
           ;; No logger — just run body
           (progn ,@body)
           (let* ((,buffer-level (level-from-keyword ,level))
                  (,original-level (logger-level ,source-lgr))
                  (,buffer (make-array 32 :adjustable t :fill-pointer 0))
                  (,on-flush-fn ,on-flush)
                  (,root (or *root-logger* ,source-lgr))
                  (,buf-lgr (make-buffer-logger ,source-lgr ,buffer-level ,buffer))
                  (,condition nil)
                  (,normal-exit-p nil))
             (let ((*root-logger* ,root))
               (unwind-protect
                   (handler-bind ((serious-condition
                                    (lambda (c)
                                      (unless ,condition (setf ,condition c)))))
                     (multiple-value-prog1
                         (let ((*logger* ,buf-lgr))
                           ,@body)
                       (setf ,normal-exit-p t)))
                 (flush-buffer ,buffer ,root ,normal-exit-p ,condition
                               ,on-flush-fn ,original-level))))))))

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
