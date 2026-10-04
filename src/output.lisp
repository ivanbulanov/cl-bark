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

;;; src/output.lisp — Output routing and multi-output (tee)

(in-package #:bark)

(defstruct destination
  "A single output destination within a tee."
  (async-output nil :type async-output)
  (formatter    nil :type formatter)
  (filter       nil :type (or null function)))

(defstruct formatter-group
  "Destinations sharing an eq formatter, for shared-formatter optimization."
  (formatter    nil :type formatter)
  (destinations #() :type simple-vector))

;;; --- Tee output ---

(defstruct tee-output
  "Fan-out output: destinations grouped by formatter for shared-format optimization."
  (groups #() :type simple-vector))

(declaim (ftype (function (list) (values tee-output &optional)) make-tee))

(defun parse-tee-spec (spec)
  "Validate one destination plist and return it normalized, with :filter
   resolved and defaults filled in. No writer thread is started here, so a bad
   spec cannot leak threads for the specs before it."
  (let ((stream           (getf spec :stream))
        (formatter        (or (getf spec :formatter) *default-json-formatter*))
        (filter-fn        (getf spec :filter))
        (level            (getf spec :level))
        (capacity         (or (getf spec :capacity) +default-buffer-capacity+))
        (on-drop          (getf spec :on-drop #'default-on-drop))
        (on-error         (getf spec :on-error))
        (blocking         (getf spec :blocking))
        (block-timeout    (getf spec :block-timeout 5.0))
        (on-block-timeout (getf spec :on-block-timeout)))
    (unless (streamp stream)
      (cl:error 'bark-configuration-error
                :detail (format nil "Tee destination :stream must be a stream, got ~S" stream)))
    (unless (formatter-p formatter)
      (cl:error 'bark-configuration-error
                :detail (format nil "Tee destination :formatter must be a formatter, got ~S" formatter)))
    (when (and filter-fn level)
      (cl:error 'bark-configuration-error
                :detail "Cannot specify both :filter and :level for a tee destination"))
    (list :stream stream
          :formatter formatter
          :filter (cond
                    (filter-fn filter-fn)
                    (level
                     (let ((threshold (level-value level)))
                       (lambda (level fields)
                         (declare (ignore fields))
                         (>= level threshold))))
                    (t nil))
          :capacity capacity
          :on-drop on-drop
          :on-error on-error
          :blocking blocking
          :block-timeout block-timeout
          :on-block-timeout on-block-timeout)))

(defun make-tee (destinations)
  "Create a fan-out output from a list of destination plists.
Each plist accepts :stream (required), :formatter, :filter, :level, :capacity,
:on-drop (NIL suppresses drop reports), :on-error, :blocking, :block-timeout,
:on-block-timeout. Every spec is validated before any writer thread starts;
BARK-CONFIGURATION-ERROR is signalled for a :stream that is not a stream, an
unknown :level, or both :level and :filter. A USE-VALUE restart supplies a
replacement tee-output."
  (let ((specs (restart-case (mapcar #'parse-tee-spec destinations)
                 (use-value (value)
                   :report "Supply a replacement tee-output."
                   :interactive (lambda () (list (make-tee (list (list :stream *error-output*)))))
                   (return-from make-tee value))))
        (dests nil)
        (complete nil))
    (unwind-protect
         (progn
           (dolist (spec specs)
             (let ((ao (make-async-output (getf spec :stream)
                                          :capacity (getf spec :capacity)
                                          :formatter (getf spec :formatter)
                                          :on-drop (getf spec :on-drop)
                                          :on-error (getf spec :on-error)
                                          :blocking (getf spec :blocking)
                                          :block-timeout (getf spec :block-timeout)
                                          :on-block-timeout (getf spec :on-block-timeout))))
               (push (make-destination :async-output ao
                                       :formatter (getf spec :formatter)
                                       :filter (getf spec :filter))
                     dests)))
           (setf dests (nreverse dests)
                 complete t))
      ;; A non-local exit while starting writers must not leak the ones started.
      (unless complete
        (dolist (dest dests)
          (ignore-errors (stop-async-output (destination-async-output dest) :timeout 1.0)))))
    ;; Group by eq formatter for shared-formatter optimization
    (let ((groups (make-hash-table :test 'eq))
          (order nil))
      (dolist (dest dests)
        (let ((fmt (destination-formatter dest)))
          (unless (gethash fmt groups)
            (push fmt order))
          (push dest (gethash fmt groups))))
      (make-tee-output
       :groups (coerce
                (loop for fmt in (nreverse order)
                      collect (make-formatter-group
                               :formatter fmt
                               :destinations (coerce (nreverse (gethash fmt groups))
                                                     'simple-vector)))
                'simple-vector)))))

(defmacro tee (&rest destination-specs)
  "Syntax sugar over make-tee. Each spec is
(stream-expr &key formatter filter level capacity on-drop on-error blocking block-timeout on-block-timeout)."
  `(make-tee
    (list ,@(loop for spec in destination-specs
                  for (stream-expr . keys) = spec
                  do (when (and (member :level keys) (member :filter keys))
                       (cl:error 'bark-configuration-error
                                 :detail "Cannot specify both :level and :filter in tee destination spec"))
                  collect `(list :stream ,stream-expr ,@keys)))))

(declaim (ftype (function (tee-output fixnum t list (or null string) list) (values &optional)) emit-to-tee))

(defun emit-to-tee (tee-output level-value prepared context message fields)
  "Emit a log event to all destinations in TEE-OUTPUT, grouped by formatter.
   PREPARED is a simple-vector of per-group prepared strings."
  (declare (optimize (speed 3) (safety 1)))
  (loop for group across (tee-output-groups tee-output)
        for i fixnum from 0 do
    (let ((passing nil)
          (group-prepared (if (simple-vector-p prepared)
                              (aref prepared i)
                              prepared)))
      ;; Collect destinations that pass their filter
      (loop for dest across (formatter-group-destinations group)
            for filter = (destination-filter dest)
            when (or (null filter) (funcall filter level-value fields))
              do (push dest passing))
      ;; Format once for the group, push to all passing destinations
      (when passing
        (let ((line (funcall (formatter-format-fn (formatter-group-formatter group))
                             level-value group-prepared context message fields)))
          (dolist (dest passing)
            (deliver-line (destination-async-output dest) line))))))
  (values))

(declaim (ftype (function (t string) (values &optional)) deliver-line))

;;; --- Dispatch ---

(defun deliver-line (output line)
  "Deliver a formatted log LINE to OUTPUT (async-output, stream, or function).
   An async output that was stopped cleanly takes the line synchronously; one
   whose writer failed counts it as dropped."
  (if (async-output-p output)
      (case (async-output-state output)
        ((:running :stopping)
         (if (async-output-blocking-p output)
             (blocking-deliver output line)
             (progn
               (ring-buffer-push (async-output-ring output) line)
               (notify-writer output))))
        (:stopped
         (write-line-synchronously output line))
        (t
         (atomics:atomic-incf (ring-buffer-dropped (async-output-ring output)))))
      (etypecase output
        (stream (write-string line output) (terpri output) (force-output output))
        (function (funcall output line)))))

(declaim (ftype (function (t (or null formatter) fixnum t list (or null string) list) (values &optional))
                dispatch-to-output))

(defun dispatch-to-output (output formatter level prepared ctx message flds)
  "Format and deliver a log event. Routes to tee or single output.
   For tee outputs, each destination group has its own formatter (FORMATTER is ignored).
   For non-tee outputs, FORMATTER must be non-nil; falls back to *default-json-formatter*."
  (if (tee-output-p output)
      (emit-to-tee output level prepared ctx message flds)
      (let ((fmt (or formatter *default-json-formatter*)))
        (deliver-line output
                      (funcall (formatter-format-fn fmt)
                               level prepared ctx message flds)))))
