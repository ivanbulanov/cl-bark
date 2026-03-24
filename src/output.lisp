;;; src/output.lisp — Output routing and multi-output (tee)

(in-package #:bark)

;;; --- Multi-Output ---

(defstruct destination
  "A single output destination within a tee."
  (async-output nil :type async-output)
  (formatter    nil :type function)
  (filter       nil :type (or null function)))

(defstruct formatter-group
  "Destinations sharing an eq formatter, for shared-formatter optimization."
  (formatter    nil :type function)
  (destinations #() :type simple-vector))

;;; Tee output
(defstruct tee-output
  "Fan-out output: destinations grouped by formatter for shared-format optimization."
  (groups #() :type simple-vector))

(declaim (ftype (function (list) (values tee-output &optional)) make-tee))

(defun make-tee (destinations)
  "Create a fan-out output from a list of destination plists.
Each plist accepts :stream (required), :formatter, :filter, :level, :capacity,
:on-drop, :on-error, :blocking, :block-timeout, :on-block-timeout.
Specifying both :level and :filter signals BARK-CONFIGURATION-ERROR."
  (let ((dests
          (mapcar
           (lambda (spec)
             (let ((stream           (getf spec :stream))
                   (formatter        (or (getf spec :formatter) #'json-formatter))
                   (filter-fn        (getf spec :filter))
                   (level-kw         (getf spec :level))
                   (capacity         (or (getf spec :capacity) +default-buffer-capacity+))
                   (on-drop          (or (getf spec :on-drop) #'default-on-drop))
                   (on-error         (getf spec :on-error))
                   (blocking         (getf spec :blocking))
                   (block-timeout    (getf spec :block-timeout 5.0))
                   (on-block-timeout (getf spec :on-block-timeout)))
               (when (and filter-fn level-kw)
                 (cl:error 'bark-configuration-error
                           :detail "Cannot specify both :filter and :level for a tee destination"))
               (let ((actual-filter
                       (cond
                         (filter-fn filter-fn)
                         (level-kw
                          (let ((threshold (level-from-keyword level-kw)))
                            (lambda (level fields)
                              (declare (ignore fields))
                              (>= level threshold))))
                         (t nil))))
                 (make-destination
                  :async-output (make-async-output stream
                                                   :capacity capacity
                                                   :formatter formatter
                                                   :on-drop on-drop
                                                   :on-error on-error
                                                   :blocking blocking
                                                   :block-timeout block-timeout
                                                   :on-block-timeout on-block-timeout)
                  :formatter formatter
                  :filter actual-filter))))
           destinations)))
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
                       (cl:error "Cannot specify both :level and :filter in tee destination spec"))
                  collect `(list :stream ,stream-expr ,@keys)))))

(declaim (ftype (function (tee-output fixnum string list list (or null string) list) (values &optional)) emit-to-tee))

(defun emit-to-tee (tee-output level-value chindings raw-bindings context message fields)
  "Emit a log event to all destinations in TEE-OUTPUT, grouped by formatter."
  (declare (optimize (speed 3) (safety 1)))
  (loop for group across (tee-output-groups tee-output) do
    (let ((passing nil))
      ;; Collect destinations that pass their filter
      (loop for dest across (formatter-group-destinations group)
            for filter = (destination-filter dest)
            when (or (null filter) (funcall filter level-value fields))
              do (push dest passing))
      ;; Format once for the group, push to all passing destinations
      (when passing
        (let ((line (funcall (formatter-group-formatter group)
                             level-value chindings raw-bindings context message fields)))
          (dolist (dest passing)
            (deliver-line (destination-async-output dest) line))))))
  (values))

(declaim (ftype (function (t string) (values &optional)) deliver-line))

;;; Dispatch
(defun deliver-line (output line)
  "Deliver a formatted log LINE to OUTPUT (async-output, stream, or function)."
  (if (async-output-p output)
      (if (async-output-blocking-p output)
          (blocking-deliver output line)
          (progn
            (ring-buffer-push (async-output-ring output) line)
            (bt:signal-semaphore (async-output-notify output))))
      (etypecase output
        (stream (write-string line output) (terpri output) (force-output output))
        (function (funcall output line)))))

(declaim (ftype (function (t function fixnum string list list (or null string) list) (values &optional))
                dispatch-to-output))

(defun dispatch-to-output (output formatter level chindings raw-bindings ctx message flds)
  "Format and deliver a log event. Routes to tee or single output."
  (if (tee-output-p output)
      (emit-to-tee output level chindings raw-bindings ctx message flds)
      (deliver-line output
                    (funcall (the function formatter)
                             level chindings raw-bindings ctx message flds))))
