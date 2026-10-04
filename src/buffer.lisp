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

;;; src/buffer.lisp — Request-scoped log buffering

(in-package #:bark)

;;; --- Log buffer ---

(defstruct (buffer-entry (:constructor make-buffer-entry))
  "A single buffered log entry, captured for deferred emission.
   Slots: LEVEL (fixnum), MESSAGE (string or nil), FIELDS (plist of per-call fields),
   CONTEXT (alist snapshot of dynamic context), TIMESTAMP (millisecond unix timestamp)."
  (level     0   :type fixnum          :read-only t)
  (message   nil :type (or null string) :read-only t)
  (fields    nil :type list            :read-only t)
  (context   nil :type list            :read-only t)
  (timestamp 0   :type (integer 0)     :read-only t))

(setf (documentation 'buffer-entry-level 'function) "Numeric log level of the buffered entry."
      (documentation 'buffer-entry-message 'function) "Log message string, or nil."
      (documentation 'buffer-entry-fields 'function) "Per-call fields plist (the &rest args passed to bark:info etc.)."
      (documentation 'buffer-entry-context 'function) "Alist snapshot of dynamic context at capture time."
      (documentation 'buffer-entry-timestamp 'function) "Millisecond unix timestamp from the original log call.")

(defstruct (log-buffer (:constructor make-log-buffer ()))
  "Entries captured by one with-log-buffer scope, newest first. Capture pushes
   with CAS, so threads that share the buffer-logger need no lock."
  (entries nil :type list))

;;; --- Buffer logger ---

(defun make-buffer-capture-fn (level-value buffer)
  "Create a function that captures log calls into BUFFER instead of formatting."
  (lambda (lgr message &rest fields)
    (declare (ignore lgr) (dynamic-extent fields))
    (atomics:atomic-push
     (make-buffer-entry :level level-value
                        :message (message-string message)
                        :fields (copy-list fields)
                        :context *log-context*
                        :timestamp (get-unix-timestamp-ms))
     (log-buffer-entries buffer))
    (values)))

(defun make-buffer-logger (original buffer-level buffer)
  "Create a buffer-logger: a stand-in for ORIGINAL with level lowered to
   BUFFER-LEVEL and level slots replaced with capture functions. Field
   transforms and samplers are applied at flush time, through ORIGINAL, so the
   stand-in carries none. ORIGINAL is recorded as the source, which is what
   make-child derives children from."
  (let ((lgr (%make-logger
              :context (logger-context original)
              :prepared (logger-prepared original)
              :formatter (logger-formatter original)
              :output (logger-output original)
              :field-transform nil
              :source original)))
    (setf (logger-level lgr) buffer-level)
    (wire-level-fns lgr buffer-level
                    (lambda (level) (make-buffer-capture-fn level buffer)))
    lgr))

(defun forward-to-source (buffer-logger source)
  "Repoint BUFFER-LOGGER's level functions at SOURCE. Called when the scope
   ends, so a buffer-logger that escaped it (captured by a closure, handed to a
   thread) logs through SOURCE instead of into a buffer nobody will flush."
  (setf (logger-level buffer-logger) (logger-level source))
  (macrolet ((forward (&rest accessors)
               `(setf ,@(loop for accessor in accessors
                              append `((,accessor buffer-logger)
                                       (lambda (lgr message &rest fields)
                                         (declare (ignore lgr))
                                         (apply (,accessor source) source message fields)))))))
    (forward logger-trace-fn logger-debug-fn logger-info-fn
             logger-warn-fn logger-error-fn logger-fatal-fn))
  (values))

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
                          (logger-prepared root-logger)
                          ctx
                          (buffer-entry-message entry)
                          flds))))

;;; --- Root logger tracking ---

(defvar *root-logger* nil
  "The non-buffer logger that the buffer scope flushes through.
   Bound by with-log-buffer. When non-nil, signals that we are inside a buffer
   scope; a nested with-log-buffer on the same logger becomes a no-op.")

;;; --- with-log-buffer ---

(defmacro with-log-buffer ((logger &key (level :trace) on-flush) &body body)
  "Execute BODY with log calls to LOGGER buffered via *logger*.
   LOGGER is evaluated once and bound to *logger* as a buffer-logger for the body's
   dynamic extent. Only implicit log calls (through *logger*) are buffered; explicit
   logger arguments bypass the buffer, and children made inside the scope derive
   from LOGGER itself (its level, transform and samplers) and emit immediately.
   Nesting on the same logger is a no-op: BODY runs directly and the outermost
   scope controls capture level and flush policy. A nested scope on a different
   logger is a scope of its own.
   LEVEL is the capture threshold (default :trace). ON-FLUSH, if provided, is called
   as (funcall on-flush entries condition normal-exit-p), where ENTRIES is a
   simple-vector in log order, and must return a sequence of the entries to emit.
   CONDITION is the most recent serious condition signalled in BODY, whether or
   not it was handled; without ON-FLUSH it only matters on a non-local exit.
   After the scope ends, log calls on the buffer-logger go through LOGGER directly."
  (let ((source-lgr (gensym "SOURCE-LGR"))
        (buffer (gensym "BUFFER"))
        (condition (gensym "CONDITION"))
        (normal-exit-p (gensym "NORMAL-EXIT-P"))
        (original-level (gensym "ORIG-LEVEL"))
        (buf-lgr (gensym "BUF-LGR"))
        (on-flush-fn (gensym "ON-FLUSH"))
        (buffer-level (gensym "BUF-LEVEL")))
    `(let ((,source-lgr ,logger))
       ;; A buffer-logger stands in for its source; buffer on the source.
       (when (and ,source-lgr (logger-source ,source-lgr))
         (setf ,source-lgr (logger-source ,source-lgr)))
       (cond
         ;; No logger — just run body
         ((null ,source-lgr)
          (progn ,@body))
         ;; Already inside a buffer scope on this logger — run body directly
         ((eq *root-logger* ,source-lgr)
          (progn ,@body))
         ;; Outermost buffer scope for this logger — set up buffering
         (t
          (let* ((,buffer-level (level-value ,level))
                 (,original-level (logger-level ,source-lgr))
                 (,buffer (make-log-buffer))
                 (,on-flush-fn ,on-flush)
                 (,buf-lgr (make-buffer-logger ,source-lgr ,buffer-level ,buffer))
                 (,condition nil)
                 (,normal-exit-p nil))
            (let ((*root-logger* ,source-lgr))
              (unwind-protect
                  (handler-bind ((serious-condition
                                   (lambda (c) (setf ,condition c))))
                    (multiple-value-prog1
                        (let ((*logger* ,buf-lgr))
                          ,@body)
                      (setf ,normal-exit-p t)))
                (forward-to-source ,buf-lgr ,source-lgr)
                (flush-buffer ,buffer ,source-lgr ,normal-exit-p ,condition
                              ,on-flush-fn ,original-level)))))))))

(defun flush-buffer (buffer root-logger normal-exit-p condition on-flush original-level)
  "Flush BUFFER entries through ROOT-LOGGER. Selection logic:
   - on-flush provided: delegate to callback (entries, condition, normal-exit-p).
   - Abnormal exit with condition: emit all entries.
   - Otherwise: emit entries >= original-level.
   During a non-local exit an error in the flush is reported, not signalled, so
   it cannot replace the condition that is already unwinding."
  (let ((entries (coerce (reverse (log-buffer-entries buffer)) 'simple-vector)))
    (when (zerop (length entries))
      (return-from flush-buffer (values)))
    (flet ((emit-selected ()
             (cond
               (on-flush
                (map nil (lambda (entry) (emit-entry root-logger entry))
                     (funcall on-flush entries condition normal-exit-p)))
               ((and (not normal-exit-p) condition)
                (map nil (lambda (entry) (emit-entry root-logger entry)) entries))
               (t
                (loop for entry across entries
                      when (>= (buffer-entry-level entry) original-level)
                        do (emit-entry root-logger entry))))))
      (if normal-exit-p
          (emit-selected)
          (handler-case (emit-selected)
            (cl:error (e)
              (%report "bark: with-log-buffer flush failed during unwind: ~a~%" e))))))
  (values))
