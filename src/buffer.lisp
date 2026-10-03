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
              :context (logger-context original)
              :prepared (logger-prepared original)
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
                          (logger-prepared root-logger)
                          ctx
                          (buffer-entry-message entry)
                          flds))))

;;; --- Root logger tracking ---

(defvar *root-logger* nil
  "The non-buffer logger that the buffer scope flushes through.
   Bound by with-log-buffer. When non-nil, signals that we are inside a buffer
   scope and nested with-log-buffer calls become no-ops.")

;;; --- with-log-buffer ---

(defmacro with-log-buffer ((logger &key (level :trace) on-flush) &body body)
  "Execute BODY with log calls to LOGGER buffered via *logger*.
   LOGGER is evaluated once and bound to *logger* as a buffer-logger for the body's
   dynamic extent. Only implicit log calls (through *logger*) are buffered; explicit
   logger arguments bypass the buffer.
   Nesting is a no-op: if already inside a buffer scope, BODY runs directly with no
   additional buffering. The outermost scope controls capture level and flush policy.
   LEVEL is the capture threshold (default :trace). ON-FLUSH, if provided, is called
   as (funcall on-flush entries condition normal-exit-p) to select entries to emit."
  (let ((source-lgr (gensym "SOURCE-LGR"))
        (buffer (gensym "BUFFER"))
        (condition (gensym "CONDITION"))
        (normal-exit-p (gensym "NORMAL-EXIT-P"))
        (original-level (gensym "ORIG-LEVEL"))
        (buf-lgr (gensym "BUF-LGR"))
        (on-flush-fn (gensym "ON-FLUSH"))
        (buffer-level (gensym "BUF-LEVEL")))
    `(let ((,source-lgr ,logger))
       (cond
         ;; No logger — just run body
         ((null ,source-lgr)
          (progn ,@body))
         ;; Already inside a buffer scope — no-op, run body directly
         (*root-logger*
          (progn ,@body))
         ;; Outermost buffer scope — set up buffering
         (t
          (let* ((,buffer-level (level-from-keyword ,level))
                 (,original-level (logger-level ,source-lgr))
                 (,buffer (make-array 32 :adjustable t :fill-pointer 0))
                 (,on-flush-fn ,on-flush)
                 (,buf-lgr (make-buffer-logger ,source-lgr ,buffer-level ,buffer))
                 (,condition nil)
                 (,normal-exit-p nil))
            (let ((*root-logger* ,source-lgr))
              (unwind-protect
                  (handler-bind ((serious-condition
                                   (lambda (c)
                                     (unless ,condition (setf ,condition c)))))
                    (multiple-value-prog1
                        (let ((*logger* ,buf-lgr))
                          ,@body)
                      (setf ,normal-exit-p t)))
                (flush-buffer ,buffer *root-logger* ,normal-exit-p ,condition
                              ,on-flush-fn ,original-level)))))))))

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
