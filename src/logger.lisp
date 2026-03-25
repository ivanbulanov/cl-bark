;;; src/logger.lisp — Logger, sampling, lifecycle, and logging macros

(in-package #:bark)

(defconstant +window-check-interval+ 64
  "How often the windowed counter reads the clock (in messages).
   Must be power of 2 for bit-and optimization.")

;;; --- Sampling ---
(defstruct (windowed-counter (:constructor %make-windowed-counter))
  "Per-level sampling: first INITIAL per window always pass, then 1-in-THEREAFTER."
  (initial      5   :type fixnum :read-only t)
  (thereafter   100 :type fixnum :read-only t)
  (window-ticks 0   :type fixnum :read-only t)
  (count        0   :type (unsigned-byte 64))
  (window-start 0   :type fixnum))

(defstruct (consistent-sampler (:constructor %make-consistent-sampler))
  "Deterministic hash-based sampling. Same key always produces same decision."
  (key-fn nil :type function    :read-only t)
  (rate     1 :type (integer 1) :read-only t))

(setf (documentation 'windowed-counter-initial 'function) "Number of messages always passed at the start of each window."
      (documentation 'windowed-counter-thereafter 'function) "After INITIAL, pass 1-in-THEREAFTER messages. 0 means drop all after initial."
      (documentation 'windowed-counter-window-ticks 'function) "Window duration in internal-time-units.")

(setf (documentation 'consistent-sampler-key-fn 'function)
      "Function (lambda (raw-bindings) ...) that extracts a sampling key from the
logger's static bindings plist. Return a string, symbol, or number for
deterministic sampling (passed to SXHASH; these types are stable across SBCL
sessions). Return NIL to skip consistent sampling and fall through to the
windowed counter. Do not return 0 or the empty string as a \"no key\" sentinel —
they are valid keys that will produce a deterministic (and likely always-keep)
hash decision."
      (documentation 'consistent-sampler-rate 'function) "Keep 1-in-RATE messages with matching key hash.")

(declaim (inline mix-hash consistent-hash-keep-p windowed-allow-p))

(defun mix-hash (h)
  "Multiply-xorshift finalizer for improved low-bit distribution."
  (declare (type fixnum h))
  (let* ((h (logxor h (ash h -16)))
         (h (ldb (byte #.(integer-length most-positive-fixnum) 0)
                 (* h 2654435769))))
    (logxor h (ash h -13))))

(defun consistent-hash-keep-p (key rate)
  "Deterministic keep/drop decision based on key hash."
  (zerop (mod (mix-hash (sxhash key)) rate)))

(defun windowed-allow-p (count wc)
  "Check if COUNT (post-increment value from atomic-incf) passes the windowed counter thresholds."
  (declare (type (unsigned-byte 64) count))
  (let ((initial (windowed-counter-initial wc))
        (thereafter (windowed-counter-thereafter wc)))
    (or (<= count initial)
        (and (plusp thereafter)
             (zerop (mod count thereafter))))))

(defun maybe-reset-window (wc now)
  "Reset window if expired. CAS ensures only one thread resets."
  (let ((ws (windowed-counter-window-start wc)))
    (when (>= (- now ws) (windowed-counter-window-ticks wc))
      (when (atomics:cas (windowed-counter-window-start wc) ws now)
        (setf (windowed-counter-count wc) 0)))))

(defun noop (logger message &rest fields)
  "No-op log function for disabled levels."
  (declare (ignore logger message fields))
  (values))

;;; --- Construction ---
(defstruct (logger (:constructor %make-logger))
  "A bark logger instance."
  (root-p          nil   :type boolean :read-only t)
  (level           +info+ :type fixnum)
  (chindings       ""    :type string :read-only t)
  (raw-bindings    nil   :type list :read-only t)
  (formatter       nil   :type (or null function))
  (output          nil   :type t)
  (level-sampler   nil   :type (or null simple-vector))
  (consistent      nil   :type (or null consistent-sampler))
  (field-transform nil   :type (or null function))
  (trace-fn        #'noop :type function)
  (debug-fn        #'noop :type function)
  (info-fn         #'noop :type function)
  (warn-fn         #'noop :type function)
  (error-fn        #'noop :type function)
  (fatal-fn        #'noop :type function))

(setf (documentation 'logger-p 'function) "Return T if OBJECT is a logger.")

;;; --- Context and fields ---
(defvar *logger* nil "The current bark logger.")

(defvar *log-context* nil "Dynamic context bindings for the current log scope.")

(defun apply-field-transform-plist (transform plist)
  "Apply TRANSFORM to each key-value pair in PLIST. Returns a new plist with
   transformed values. Pairs where TRANSFORM returns NIL as second value are dropped."
  (declare (type function transform))
  (let (new-val drop-p)
    (flet ((receive (val &optional (keep-p nil keep-supplied-p))
             (setf new-val val
                   drop-p (and keep-supplied-p (not keep-p)))))
      (declare (dynamic-extent #'receive))
      (loop for (k v) on plist by #'cddr
            do (multiple-value-call #'receive (funcall transform k v))
            unless drop-p collect k and collect new-val))))

(defun apply-field-transform-alist (transform alist)
  "Apply TRANSFORM to each pair in ALIST (dynamic context). Returns a new alist.
   Pairs where TRANSFORM returns NIL as second value are dropped."
  (declare (type function transform))
  (let (new-val drop-p)
    (flet ((receive (val &optional (keep-p nil keep-supplied-p))
             (setf new-val val
                   drop-p (and keep-supplied-p (not keep-p)))))
      (declare (dynamic-extent #'receive))
      (loop for (k . v) in alist
            do (multiple-value-call #'receive (funcall transform k v))
            unless drop-p collect (cons k new-val)))))

(defun compose-field-transforms (outer inner)
  "Compose two field transforms. INNER runs first, then OUTER on the result.
   If either is NIL, returns the other."
  (cond
    ((null outer) inner)
    ((null inner) outer)
    (t (lambda (key value)
         (let (inner-val drop-p)
           (flet ((receive (val &optional (keep-p nil keep-supplied-p))
                    (setf inner-val val
                          drop-p (and keep-supplied-p (not keep-p)))))
             (declare (dynamic-extent #'receive))
             (multiple-value-call #'receive (funcall inner key value)))
           (if drop-p
               (values nil nil)
               (funcall outer key inner-val)))))))

(declaim (ftype (function (fixnum) (values function &optional)) make-log-fn))

(defun make-log-fn (level-value)
  "Create a log function for LEVEL-VALUE."
  (declare (optimize (speed 3) (safety 1))
           (type fixnum level-value))
  (let ((level-index level-value))
    (lambda (lgr message &rest fields)
      (declare (ignorable lgr) (dynamic-extent fields))
      (block log-fn
        (block sampling
          ;; 1. Consistent sampler
          (let ((cs (logger-consistent lgr)))
            (when cs
              (let ((key (funcall (consistent-sampler-key-fn cs)
                                  (logger-raw-bindings lgr))))
                (when key
                  (if (consistent-hash-keep-p key (consistent-sampler-rate cs))
                      (return-from sampling)
                      (return-from log-fn (values)))))))
          ;; 2. Windowed counter
          (let ((ls (logger-level-sampler lgr)))
            (when ls
              (let ((wc (aref ls level-index)))
                (when wc
                  (let ((count (atomics:atomic-incf (windowed-counter-count wc))))
                    (when (zerop (logand count (1- +window-check-interval+)))
                      (maybe-reset-window wc (get-internal-real-time)))
                    (unless (windowed-allow-p count wc)
                      (return-from log-fn (values)))))))))
        (let ((output (logger-output lgr))
              (transform (logger-field-transform lgr)))
          (when output
            (let ((ctx (if transform
                           (apply-field-transform-alist transform *log-context*)
                           *log-context*))
                  (flds (if transform
                            (apply-field-transform-plist transform fields)
                            fields)))
              (dispatch-to-output output (logger-formatter lgr)
                                  level-value
                                  (logger-chindings lgr) (logger-raw-bindings lgr)
                                  ctx message flds))))
        (values)))))

(declaim (ftype (function (&key (:output t) (:level (or fixnum keyword)) (:formatter function)
                                (:context list) (:field-transform (or null function))
                                (:capacity fixnum) (:on-drop (or null function))
                                (:blocking boolean) (:block-timeout t)
                                (:on-block-timeout (or null function))
                                (:level-sampler (or null simple-vector))
                                (:consistent (or null consistent-sampler)))
                          (values logger &optional)) make-logger))

(defun make-logger (&key output (level :info) (formatter #'json-formatter)
                        context field-transform
                        (capacity +default-buffer-capacity+) (on-drop #'default-on-drop)
                        blocking (block-timeout 5.0 block-timeout-supplied-p) on-block-timeout
                        level-sampler consistent)
  "Create a root logger. Multiple root loggers can coexist — each owns its own
output and writer thread(s). Assign to *logger* for implicit use by logging
macros, or pass explicitly as the first argument to bark:info etc.

OUTPUT (stream, function, tee-output, or NIL):
  Stream/NIL — wrapped in async-output (background writer thread + ring buffer).
  NIL defaults to *error-output*. Function — called synchronously, no thread.
  tee-output — from bark:tee or bark:make-tee, used as-is.

LEVEL (keyword or fixnum, default :info):
  Minimum log level. One of :trace :debug :info :warn :error :fatal.

FORMATTER (function, default #'json-formatter):
  Formatting function with signature (level chindings raw-bindings context
  message fields) -> string. Use make-json-formatter, make-logfmt-formatter,
  or make-pretty-formatter for customization.

CONTEXT (plist or NIL):
  Static context fields attached to every log entry, e.g. '(:name \"myapp\").
  Pre-serialized at creation time — zero per-call cost.

FIELD-TRANSFORM (function or NIL):
  Function (lambda (key value) ...) applied to every field before serialization.
  Return the (possibly modified) value, or (values nil nil) to drop the field.

CAPACITY (fixnum, default 8192): Ring buffer size in messages. Stream output only.
ON-DROP (function or NIL): Called as (funcall on-drop count) when messages are
  dropped due to a full buffer. Returns (values message fields) or NIL to suppress.
BLOCKING (boolean): When T, callers block on a full buffer instead of dropping.
BLOCK-TIMEOUT (real, default 5.0): Seconds to wait when blocking before giving up.
ON-BLOCK-TIMEOUT (function or NIL): Called when block-timeout expires.

LEVEL-SAMPLER (simple-vector or NIL): From make-level-sampler — per-level
  windowed counters for rate limiting.
CONSISTENT (consistent-sampler or NIL): From make-consistent-sampler —
  deterministic hash-based sampling.

Async parameters (CAPACITY through ON-BLOCK-TIMEOUT) are only valid with stream
output. Passing them with a function or tee-output signals BARK-CONFIGURATION-ERROR."
  (when (and (or (functionp output) (tee-output-p output))
             (or blocking on-block-timeout block-timeout-supplied-p
                 (/= capacity +default-buffer-capacity+)
                 (not (eq on-drop #'default-on-drop))))
    (restart-case
        (cl:error 'bark-configuration-error
                  :detail (format nil "Cannot specify async parameters (:capacity, :on-drop, :blocking, ~
               :block-timeout, :on-block-timeout) with a ~:[function~;tee-output~]. ~
               ~:*~:[Function outputs are synchronous — async parameters do not apply.~;~
               Configure these per-destination in bark:tee.~]"
                                  (tee-output-p output)))
      (use-value (value)
        :report "Supply a replacement logger."
        :interactive (lambda () (list (make-logger)))
        (return-from make-logger value))))
  (let* ((actual-output (cond
                          ((functionp output) output)
                          ((tee-output-p output) output)
                          ((or (streamp output) (null output))
                           (make-async-output (or output *error-output*)
                                              :capacity capacity
                                              :formatter formatter
                                              :on-drop on-drop
                                              :on-error nil
                                              :blocking blocking
                                              :block-timeout block-timeout
                                              :on-block-timeout on-block-timeout))
                          (t (restart-case
                                 (cl:error 'bark-configuration-error
                                           :detail (format nil "Invalid :output for make-logger: ~A ~
                                        (expected stream, function, tee-output, or NIL)" output))
                               (use-value (value)
                                 :report "Supply a replacement logger."
                                 :interactive (lambda () (list (make-logger)))
                                 (return-from make-logger value))))))
         (effective-context (if (and context field-transform)
                                (apply-field-transform-plist field-transform context)
                                context))
         (chindings (if effective-context (serialize-bindings effective-context) ""))
         (raw-bindings effective-context)
         (lgr (%make-logger
               :root-p t
               :chindings chindings
               :raw-bindings raw-bindings
               :formatter formatter
               :output actual-output
               :field-transform field-transform
               :level-sampler level-sampler
               :consistent consistent)))
    (set-level lgr level)
    lgr))

(declaim (ftype (function (logger (or fixnum keyword)) *) set-level))

(defun wire-level-fns (logger threshold make-fn)
  "Set all six level function slots on LOGGER. Levels at or above THRESHOLD
   get functions from (funcall MAKE-FN level); levels below get #'noop."
  (flet ((slot-fn (level) (if (< level threshold) #'noop (funcall make-fn level))))
    (setf (logger-trace-fn logger) (slot-fn +trace+))
    (setf (logger-debug-fn logger) (slot-fn +debug+))
    (setf (logger-info-fn logger)  (slot-fn +info+))
    (setf (logger-warn-fn logger)  (slot-fn +warn+))
    (setf (logger-error-fn logger) (slot-fn +error+))
    (setf (logger-fatal-fn logger) (slot-fn +fatal+)))
  (values))

;;; --- Level management ---
(defun set-level (logger level)
  "Set the minimum log level for LOGGER. Accepts a keyword (:trace through :fatal)
or a fixnum level constant. Takes effect immediately."
  (let ((level-val (etypecase level
                     (fixnum level)
                     (keyword (level-from-keyword level)))))
    (setf (logger-level logger) level-val)
    (wire-level-fns logger level-val #'make-log-fn)))

(defun level-enabled-p (logger level)
  "Return T if LEVEL is enabled on LOGGER. NIL when LOGGER is nil.
Checks the level threshold only — does not account for sampling,
per-destination filters, or compile-time elimination."
  (and logger
       (>= (level-from-keyword level)
           (logger-level logger))))

;;; --- Sampling API ---

(defun make-windowed-counter (&key (initial 5) (thereafter 100) (window-seconds 1))
  "Create a windowed counter for rate-limiting log messages.
INITIAL (fixnum, default 5): messages always passed at the start of each window.
THEREAFTER (fixnum, default 100): after INITIAL, pass 1-in-THEREAFTER. 0 means
  hard cap (drop all after initial burst).
WINDOW-SECONDS (real, default 1): window duration in seconds. Counter resets when
  the window expires.
Signals BARK-CONFIGURATION-ERROR if window-seconds produces a tick count exceeding
fixnum range."
  (let ((ticks (round (* window-seconds internal-time-units-per-second))))
    (when (> ticks most-positive-fixnum)
      (restart-case
          (cl:error 'bark-configuration-error
                    :detail (format nil "window-seconds ~A produces ~A ticks, exceeding fixnum range"
                                    window-seconds ticks))
        (use-value (value)
          :report "Supply a replacement windowed-counter."
          :interactive (lambda () (list (make-windowed-counter)))
          (return-from make-windowed-counter value))))
    (%make-windowed-counter :initial initial
                            :thereafter thereafter
                            :window-ticks ticks
                            :window-start (get-internal-real-time))))

(defun make-level-sampler (&key trace debug info warn error fatal)
  "Create a level-sampler vector for per-level windowed sampling.
Each keyword argument corresponds to a log level and accepts a windowed-counter
(from make-windowed-counter) or NIL (no sampling at that level). Levels without
a counter pass all messages. Pass to :level-sampler on make-logger.
Signals BARK-CONFIGURATION-ERROR if any value is not a windowed-counter or NIL."
  (flet ((check (name val)
           (when (and val (not (windowed-counter-p val)))
             (restart-case
                 (cl:error 'bark-configuration-error
                           :detail (format nil "~A must be a windowed-counter or nil, got ~A" name (type-of val)))
               (use-value (value)
                 :report "Supply a replacement level-sampler."
                 :interactive (lambda () (list (make-level-sampler)))
                 (return-from make-level-sampler value))))))
    (check :trace trace) (check :debug debug) (check :info info)
    (check :warn warn) (check :error error) (check :fatal fatal))
  (vector nil trace debug info warn error fatal))

(defun make-consistent-sampler (&key key-fn (rate 1))
  "Create a consistent sampler. RATE is 1-in-N (keep one, drop N-1).
KEY-FN is (lambda (raw-bindings) ...) where RAW-BINDINGS is the logger's
static context plist (set via :context on make-logger/make-child). It should
return a string, symbol, or number for deterministic hashing, or NIL to skip
consistent sampling and fall through to the windowed counter.
Signals BARK-CONFIGURATION-ERROR if RATE < 1."
  (check-type key-fn function)
  (when (< rate 1)
    (restart-case
        (cl:error 'bark-configuration-error
                  :detail (format nil "consistent-sampler rate must be >= 1, got ~A" rate))
      (use-value (value)
        :report "Supply a replacement consistent-sampler."
        :interactive (lambda () (list (make-consistent-sampler :key-fn key-fn :rate 1)))
        (return-from make-consistent-sampler value))))
  (%make-consistent-sampler :key-fn key-fn :rate rate))

(defun set-level-sampling (logger level windowed-counter)
  "Set sampling for LEVEL to WINDOWED-COUNTER on LOGGER (nil to remove).
   Thread-safe via CAS on nil->vector transition."
  (let ((level-index (etypecase level
                      (fixnum level)
                      (keyword (level-from-keyword level)))))
    (loop
      (let ((ls (logger-level-sampler logger)))
        (cond
          (ls
           (setf (aref ls level-index) windowed-counter)
           (return))
          (t
           (let ((new-ls (make-array +level-slot-count+ :initial-element nil)))
             (setf (aref new-ls level-index) windowed-counter)
             (when (atomics:cas (logger-level-sampler logger) nil new-ls)
               (return)))))))))

(defun set-consistent (logger consistent-sampler)
  "Set or replace the consistent sampler on LOGGER.
CONSISTENT-SAMPLER is a sampler from make-consistent-sampler, or NIL to disable."
  (setf (logger-consistent logger) consistent-sampler))

(declaim (ftype (function (logger &key (:context list)
                                            (:level (or null fixnum keyword))
                                            (:field-transform (or null function)))
                          (values logger &optional)) make-child))

(defun make-child (parent &key context level field-transform)
  "Create a child logger that shares PARENT's output and formatter.

PARENT (logger): the root or child logger to derive from.
CONTEXT (plist or NIL): static fields pre-serialized at creation time, appended
  to the parent's context. Zero per-call cost.
LEVEL (keyword, fixnum, or NIL): minimum log level. NIL inherits from parent.
FIELD-TRANSFORM (function or NIL): composes with parent's transform (parent runs
  first, then child). Applied to CONTEXT fields at creation time.

Inherits the parent's formatter, output, level-sampler, and consistent sampler
(snapshots at creation time — later changes to the parent are not reflected)."
  (let* ((parent-transform (logger-field-transform parent))
         (composed-transform (compose-field-transforms field-transform parent-transform))
         (effective-bindings (if (and context composed-transform)
                                 (apply-field-transform-plist composed-transform context)
                                 context))
         (new-chindings (concatenate 'string
                                      (logger-chindings parent)
                                      (serialize-bindings effective-bindings)))
         (new-raw-bindings (append (logger-raw-bindings parent) effective-bindings))
         (child-level (cond
                        ((null level) (logger-level parent))
                        ((keywordp level) (level-from-keyword level))
                        (t level)))
         (child (%make-logger
                 :level child-level
                 :chindings new-chindings
                 :raw-bindings new-raw-bindings
                 :formatter (logger-formatter parent)
                 :output (logger-output parent)
                 :level-sampler (logger-level-sampler parent)
                 :consistent (logger-consistent parent)
                 :field-transform composed-transform)))
    (set-level child child-level)
    child))

(defmethod print-object ((ao async-output) stream)
  "Print async-output without descending into stream/thread slots."
  (print-unreadable-object (ao stream :type t :identity t)
    (let ((ring (async-output-ring ao)))
      (format stream "~:[stopped~;running~] ~D pending ~D dropped"
              (async-output-running ao)
              (if ring (- (ring-buffer-head ring) (ring-buffer-tail ring)) 0)
              (if ring (ring-buffer-dropped ring) 0)))))

(defmethod print-object ((lgr logger) stream)
  "Print logger showing level and kind."
  (print-unreadable-object (lgr stream :type t)
    (format stream "~A~@[ ~A~]" (level-name (logger-level lgr))
            (unless (logger-root-p lgr) "child"))))

(defun do-async-outputs (output fn)
  "Apply FN to each async-output reachable from OUTPUT (tee-output or async-output).
   No-op when OUTPUT is nil or not an async-based output."
  (cond
    ((and output (tee-output-p output))
     (loop for group across (tee-output-groups output)
           do (loop for dest across (formatter-group-destinations group)
                    do (funcall fn (destination-async-output dest)))))
    ((and output (async-output-p output))
     (funcall fn output))))

;;; --- Lifecycle ---
(defun flush (logger)
  "Flush LOGGER, blocking until all pending messages are written.
Signals BARK-ASYNC-STOPPED if any async output has been stopped.
A CONTINUE restart is available to skip stopped outputs."
  (let ((has-stopped nil))
    (flet ((flush-one (ao)
             (if (async-output-running ao)
                 (flush-async-output ao)
                 (setf has-stopped t))))
      (do-async-outputs (logger-output logger) #'flush-one))
    (when has-stopped
      (restart-case
          (cl:error 'bark-async-stopped)
        (continue ()
          :report "Skip stopped outputs."
          nil)))))

(defun stop (logger)
  "Stop writer threads for LOGGER. Blocks until pending messages are drained and
threads have exited. Idempotent — calling stop on an already-stopped or sync
logger is a no-op. Passing NIL is a no-op.
Signals BARK-CHILD-OPERATION-ERROR if LOGGER is a child.
A CONTINUE restart is available to silently ignore the operation."
  (when logger
    (unless (logger-root-p logger)
      (restart-case
          (cl:error 'bark-child-operation-error :operation :stop)
        (continue ()
          :report "Ignore stop on child logger."
          (return-from stop nil))))
    (do-async-outputs (logger-output logger) #'stop-async-output))
  nil)

(defun register-exit-hook (logger)
  "Register LOGGER for automatic cleanup on Lisp image exit.
   Calls bark:stop on the logger when the implementation's exit hook fires.
   Safe to combine with an explicit bark:stop call (stop is idempotent)."
  (let ((fn (lambda () (stop logger))))
    #+sbcl      (push fn sb-ext:*exit-hooks*)
    #+ccl       (push fn ccl:*lisp-cleanup-functions*)
    #+ecl       (push fn ext:*exit-hooks*)
    #+abcl      (push fn ext:*exit-hooks*)
    #+clisp     (push fn custom:*fini-hooks*)
    #-(or sbcl ccl ecl abcl clisp)
    (cl:warn "cl-bark: no exit-hook support on this implementation"))
  (values))

;;; --- Context ---

(defmacro with-context ((&rest pairs) &body body)
  "Bind dynamic log context fields for the duration of BODY."
  `(let ((*log-context* (list* ,@(loop for (k v) on pairs by #'cddr
                                       collect `(cons ,k ,v))
                               *log-context*)))
     ,@body))

;;; --- Utilities ---

(defmacro with-captured-logs ((&optional (var 'logs) (formatter '#'json-formatter)) &body body)
  "Execute BODY with a test logger that captures log output.
   Binds VAR to a function that returns the list of logged strings.
   FORMATTER defaults to #'json-formatter but can be any formatter function."
  `(multiple-value-bind (collector results-fn) (make-list-collector)
     (let* ((*logger* (make-logger :level :trace
                                   :formatter ,formatter :output collector
                                   :context '(:name "test"))))
       (let ((,var results-fn))
         ,@body))))

(defvar *compile-time-max-level* 0
  "When positive, log calls for levels below this are eliminated at compile time.")

(declaim (ftype (function nil (values function function &optional)) make-list-collector))

(defun make-list-collector ()
  "Create a list-collecting output function and its result accessor.
   Returns (values collector-fn get-results-fn)."
  (let ((results nil))
    (values
     (lambda (line) (push line results))
     (lambda () (nreverse results)))))

;;; --- Convenience API ---

(macrolet ((define-log-macro (name accessor)
             `(defmacro ,name (&rest args)
                ,(format nil "Log at ~A level. See bark:info for call forms and semantics."
                         (string-upcase name))
                (when args
                  (if (keywordp (car args))
                      ;; Compile-time: literal keyword first → fields-only, use *logger*
                      `(when *logger*
                         (funcall (,',accessor *logger*) *logger* nil ,@args))
                      ;; First arg needs runtime dispatch
                      (let ((g (gensym "FIRST"))
                            (rest-forms (cdr args)))
                        ;; Pre-compute the logger branch outside the template
                        (let ((logger-branch
                                (cond
                                  ((null rest-forms)
                                   `(funcall (,',accessor ,g) ,g nil))
                                  ((keywordp (car rest-forms))
                                   `(funcall (,',accessor ,g) ,g nil ,@rest-forms))
                                  (t
                                   (let ((g2 (gensym "ARG")))
                                     `(let ((,g2 ,(car rest-forms)))
                                        (if (keywordp ,g2)
                                            (funcall (,',accessor ,g) ,g nil ,g2 ,@(cdr rest-forms))
                                            (funcall (,',accessor ,g) ,g ,g2 ,@(cdr rest-forms)))))))))
                          `(let ((,g ,(car args)))
                             (cond
                               ((logger-p ,g) ,logger-branch)
                               ((keywordp ,g)
                                (when *logger*
                                  (funcall (,',accessor *logger*) *logger* nil ,g ,@rest-forms)))
                               (t
                                (when *logger*
                                  (funcall (,',accessor *logger*) *logger* ,g ,@rest-forms))))))))))))
  (define-log-macro trace logger-trace-fn)
  (define-log-macro debug logger-debug-fn)
  (define-log-macro info  logger-info-fn)
  (define-log-macro warn  logger-warn-fn)
  (define-log-macro error logger-error-fn)
  (define-log-macro fatal logger-fatal-fn))

(setf (documentation 'info 'function)
      "Log at INFO level. All six logging macros (trace, debug, info, warn, error,
fatal) share the same calling convention:

  (bark:info \"msg\" :key value ...)       — log through *logger*
  (bark:info logger \"msg\" :key value ...) — log through an explicit logger
  (bark:info :key value ...)               — fields only, no message, via *logger*

The first argument is dispatched at runtime: if it satisfies logger-p, it is
used as the logger; if it is a keyword, it starts a fields-only plist with no
message; otherwise it is the message string.

When *logger* is NIL (or the explicit logger is NIL), the call is a no-op —
logging macros never signal. Calls below *compile-time-max-level* are
eliminated entirely at compile time.")
