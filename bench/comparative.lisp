;;; bench/comparative.lisp — Comparative benchmarks across CL loggers

(in-package #:bark-bench)

(declaim (optimize (speed 3) (safety 1)))

;;; ============================================================
;;; Soft-load competitor loggers
;;; ============================================================

(defvar *available-loggers* '()
  "List of (name setup-fn log-message-fn log-fields-5-fn log-fields-10-fn
            log-with-context-fn teardown-fn) for successfully loaded loggers.")

;;; Competitor packages are loaded via :weakly-depends-on in cl-bark.asd.
;;; Push feature flags so #+/- conditionals select the right code paths.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :log4cl)
    (pushnew :bark-bench/log4cl *features*))
  (when (find-package :vom)
    (pushnew :bark-bench/vom *features*))
  (when (find-package :verbose)
    (pushnew :bark-bench/verbose *features*)))

;;; ============================================================
;;; cl-bark adapter (blocking mode)
;;; ============================================================

(defvar *bark-blocking-logger* nil)
(defvar *bark-blocking-child* nil)

(defun bark-blocking-setup ()
  (setf *bark-blocking-logger*
        (bark:make-logger :level :trace :output *discard-stream* :blocking t))
  (setf *bark-blocking-child*
        (bark:make-child *bark-blocking-logger* :context *bench-context*)))

(defun bark-blocking-log-message ()
  (bark:info *bark-blocking-logger* *bench-message*))

(defun bark-blocking-log-fields-5 ()
  (bark:info *bark-blocking-logger* *bench-message*
    :method "POST" :path "/api/v2/users" :status 201
    :duration-ms 42.0d0 :authenticated t))

(defun bark-blocking-log-fields-10 ()
  (bark:info *bark-blocking-logger* *bench-message*
    :method "POST" :path "/api/v2/users" :status 201
    :duration-ms 42.0d0 :authenticated t
    :request-id "req-7f3a-4b2c-9d1e" :user-id 10042
    :remote-addr "192.168.1.100" :bytes-sent 1247 :cached nil))

(defun bark-blocking-log-with-context ()
  (bark:info *bark-blocking-child* *bench-message*))

(defun bark-blocking-teardown ()
  (when *bark-blocking-logger*
    (bark:stop *bark-blocking-logger*)
    (setf *bark-blocking-logger* nil
          *bark-blocking-child* nil)))

(push (list "cl-bark (blocking, json)"
            #'bark-blocking-setup
            #'bark-blocking-log-message
            #'bark-blocking-log-fields-5
            #'bark-blocking-log-fields-10
            #'bark-blocking-log-with-context
            #'bark-blocking-teardown)
      *available-loggers*)

;;; ============================================================
;;; cl-bark adapter (blocking, logfmt formatter)
;;; ============================================================
;;; Same as above but with logfmt output instead of JSON.
;;; logfmt produces key=value pairs — less escaping overhead than JSON.

(defvar *bark-logfmt-logger* nil)
(defvar *bark-logfmt-child* nil)

(defun bark-logfmt-setup ()
  (setf *bark-logfmt-logger*
        (bark:make-logger :level :trace :output *discard-stream*
                          :blocking t :formatter #'bark:logfmt-formatter))
  (setf *bark-logfmt-child*
        (bark:make-child *bark-logfmt-logger* :context *bench-context*)))

(defun bark-logfmt-log-message ()
  (bark:info *bark-logfmt-logger* *bench-message*))

(defun bark-logfmt-log-fields-5 ()
  (bark:info *bark-logfmt-logger* *bench-message*
    :method "POST" :path "/api/v2/users" :status 201
    :duration-ms 42.0d0 :authenticated t))

(defun bark-logfmt-log-fields-10 ()
  (bark:info *bark-logfmt-logger* *bench-message*
    :method "POST" :path "/api/v2/users" :status 201
    :duration-ms 42.0d0 :authenticated t
    :request-id "req-7f3a-4b2c-9d1e" :user-id 10042
    :remote-addr "192.168.1.100" :bytes-sent 1247 :cached nil))

(defun bark-logfmt-log-with-context ()
  (bark:info *bark-logfmt-child* *bench-message*))

(defun bark-logfmt-teardown ()
  (when *bark-logfmt-logger*
    (bark:stop *bark-logfmt-logger*)
    (setf *bark-logfmt-logger* nil
          *bark-logfmt-child* nil)))

(push (list "cl-bark (blocking, logfmt)"
            #'bark-logfmt-setup
            #'bark-logfmt-log-message
            #'bark-logfmt-log-fields-5
            #'bark-logfmt-log-fields-10
            #'bark-logfmt-log-with-context
            #'bark-logfmt-teardown)
      *available-loggers*)

;;; ============================================================
;;; log4cl adapter
;;; ============================================================
;;; Configuration: fixed-stream-appender to discard stream with simple-layout.
;;; simple-layout is the lightest built-in layout (no pattern parsing).
;;; This represents idiomatic log4cl usage for simple stream output.
;;; log4cl macros (log:info etc.) auto-select logger from package context.
;;; We configure the root logger so all log:info calls route through it.

#+bark-bench/log4cl
(progn
  (defvar *log4cl-appender* nil)
  (defvar *log4cl-saved-level* nil)

  (defun log4cl-setup ()
    ;; Remove default console appender, add our discard-stream appender
    (log4cl:remove-all-appenders log4cl:*root-logger*)
    (setf *log4cl-appender*
          (make-instance 'log4cl:fixed-stream-appender
                         :stream *discard-stream*
                         :layout (make-instance 'log4cl:simple-layout)))
    (log4cl:add-appender log4cl:*root-logger* *log4cl-appender*)
    (setf *log4cl-saved-level*
          (log4cl:logger-log-level log4cl:*root-logger*))
    (log4cl:set-log-level log4cl:*root-logger* log4cl:+log-level-info+))

  (defun log4cl-log-message ()
    (log:info "user authentication completed"))

  (defun log4cl-log-fields-5 ()
    ;; log4cl is not a structured logger — use format directives idiomatically
    (log:info "method=~a path=~a status=~d duration-ms=~f authenticated=~a"
              "POST" "/api/v2/users" 201 42.0d0 t))

  (defun log4cl-log-fields-10 ()
    (log:info "method=~a path=~a status=~d duration-ms=~f authenticated=~a ~
               request-id=~a user-id=~d remote-addr=~a bytes-sent=~d cached=~a"
              "POST" "/api/v2/users" 201 42.0d0 t
              "req-7f3a-4b2c-9d1e" 10042 "192.168.1.100" 1247 nil))

  (defun log4cl-log-with-context ()
    ;; log4cl has no structured context mechanism.
    ;; Closest equivalent: include context in the format string.
    (log:info "[service=user-api version=2.1.0 instance-id=7 production=T] ~
               user authentication completed"))

  (defun log4cl-teardown ()
    (when *log4cl-appender*
      (log4cl:remove-all-appenders log4cl:*root-logger*)
      (when *log4cl-saved-level*
        (log4cl:set-log-level log4cl:*root-logger* *log4cl-saved-level*))
      (setf *log4cl-appender* nil)))

  (push (list "log4cl"
              #'log4cl-setup
              #'log4cl-log-message
              #'log4cl-log-fields-5
              #'log4cl-log-fields-10
              #'log4cl-log-with-context
              #'log4cl-teardown)
        *available-loggers*)) ; end #+bark-bench/log4cl

;;; ============================================================
;;; vom adapter
;;; ============================================================
;;; Configuration: redirect vom:*log-stream* to discard stream.
;;; vom is a minimalist logger using format strings for output.
;;; No structured fields or context mechanism — everything is in the format string.

#+bark-bench/vom
(progn
  (defvar *vom-saved-stream* nil)

  (defun vom-setup ()
    (setf *vom-saved-stream* vom:*log-stream*)
    (setf vom:*log-stream* *discard-stream*)
    (vom:config t :info))

  (defun vom-log-message ()
    (vom:info "user authentication completed"))

  (defun vom-log-fields-5 ()
    (vom:info "method=~a path=~a status=~d duration-ms=~f authenticated=~a"
              "POST" "/api/v2/users" 201 42.0d0 t))

  (defun vom-log-fields-10 ()
    (vom:info "method=~a path=~a status=~d duration-ms=~f authenticated=~a ~
               request-id=~a user-id=~d remote-addr=~a bytes-sent=~d cached=~a"
              "POST" "/api/v2/users" 201 42.0d0 t
              "req-7f3a-4b2c-9d1e" 10042 "192.168.1.100" 1247 nil))

  (defun vom-log-with-context ()
    ;; vom has no context mechanism — inline context in the message
    (vom:info "[service=user-api version=2.1.0 instance-id=7 production=T] ~
               user authentication completed"))

  (defun vom-teardown ()
    (when *vom-saved-stream*
      (setf vom:*log-stream* *vom-saved-stream*)
      (setf *vom-saved-stream* nil))
    (vom:config t :info))

  (push (list "vom"
              #'vom-setup
              #'vom-log-message
              #'vom-log-fields-5
              #'vom-log-fields-10
              #'vom-log-with-context
              #'vom-teardown)
        *available-loggers*)) ; end #+bark-bench/vom

;;; ============================================================
;;; verbose adapter
;;; ============================================================
;;; verbose has its own async pipeline — skipped if not installed.

;;; verbose has its own async pipeline — skipped if not installed.
;;; Will show as "Skipping verbose: ..." in output during compile.

;;; ============================================================
;;; Raw baseline (standalone, not a logger adapter)
;;; ============================================================

(defun raw-baseline-fields-5 ()
  "Simulate structured logging using the same primitives cl-bark uses."
  (let ((line (with-output-to-string (s)
                (write-string "{\"level\":\"info\",\"ts\":1740600000123," s)
                (write-string "\"method\":\"POST\"," s)
                (write-string "\"path\":\"/api/v2/users\"," s)
                (write-string "\"status\":201," s)
                (write-string "\"duration-ms\":42.0," s)
                (write-string "\"authenticated\":true," s)
                (write-string "\"msg\":\"user authentication completed\"}" s))))
    (write-string line *discard-stream*)
    (terpri *discard-stream*)
    (force-output *discard-stream*)))

;;; ============================================================
;;; Comparative scenario runner
;;; ============================================================

(defun adapter-getter (adapter getter)
  "Return the log function for GETTER from ADAPTER.
   GETTER: :message, :fields-5, :fields-10, :with-context"
  (destructuring-bind (name setup-fn log-msg log-5 log-10 log-ctx teardown-fn) adapter
    (declare (ignore name setup-fn teardown-fn))
    (ecase getter
      (:message log-msg)
      (:fields-5 log-5)
      (:fields-10 log-10)
      (:with-context log-ctx))))

(defun run-comparative-scenario (scenario-name getter
                                 &key batch-p)
  "Run a single comparative scenario across all available loggers.
   GETTER: :message, :fields-5, :fields-10, :with-context
   All scenarios use batch measurement.  BATCH-P selects large batches
   (sub-microsecond ops) vs sampled batches (normal ops)."
  (format t "~&comparative: ~a (discard sink)~%" scenario-name)
  (format t "Note: all loggers synchronous except verbose (has async pipeline)~%~%")
  (print-comparative-header)
  (dolist (adapter (reverse *available-loggers*))
    (destructuring-bind (name setup-fn log-msg log-5 log-10 log-ctx teardown-fn) adapter
      (declare (ignore log-msg log-5 log-10 log-ctx))
      (let ((fn (adapter-getter adapter getter))
            (bs (if batch-p *batch-size* *default-sample-batch-size*)))
        (funcall setup-fn)
        (unwind-protect
            (multiple-value-bind (time-samples bytes-timer _name batch-size)
                (run-batch-scenario name fn :batch-size bs)
              (declare (ignore _name))
              (let* ((n (length time-samples))
                     (per-call (map '(simple-array double-float (*))
                                    (lambda (s) (/ s batch-size))
                                    time-samples)))
                (multiple-value-bind (p50 mean-val p99)
                    (compute-sample-stats per-call)
                  (let ((bytes
                          (unless batch-p
                            (bytes-per-call bytes-timer n batch-size))))
                    (print-comparative-row name p50 mean-val p99 bytes)))))
          (funcall teardown-fn))))))

;;; ============================================================
;;; Register comparative scenarios
;;; ============================================================

(defun disabled-level-row (label thunk)
  "Run a disabled-level batch scenario and print one comparative row."
  (multiple-value-bind (time-samples _bytes-timer _name batch-size)
      (run-batch-scenario label thunk)
    (declare (ignore _bytes-timer _name))
    (let ((per-call (map '(simple-array double-float (*))
                         (lambda (s) (/ s batch-size))
                         time-samples)))
      (multiple-value-bind (p50 mean-val p99)
          (compute-sample-stats per-call)
        (print-comparative-row label p50 mean-val p99 nil)))))

(register-comparative-scenario "disabled-level"
  (lambda ()
    ;; Special case: each logger must be set to a level that disables the call
    (format t "~&comparative: disabled-level (discard sink, batch-measured)~%~%")
    (print-comparative-header)
    ;; cl-bark blocking — set level to :warn, call :debug (disabled)
    (let ((logger (bark:make-logger :level :warn :output *discard-stream* :blocking t)))
      (unwind-protect
          (disabled-level-row "cl-bark (blocking, json)"
            (lambda () (bark:debug logger *bench-message*)))
        (bark:stop logger)))
    #+bark-bench/log4cl
    (progn
      ;; log4cl — set level to :warn, call log:debug (disabled)
      (log4cl:remove-all-appenders log4cl:*root-logger*)
      (log4cl:add-appender log4cl:*root-logger*
        (make-instance 'log4cl:fixed-stream-appender
                       :stream *discard-stream*
                       :layout (make-instance 'log4cl:simple-layout)))
      (log4cl:set-log-level log4cl:*root-logger* log4cl:+log-level-warn+)
      (unwind-protect
          (disabled-level-row "log4cl"
            (lambda () (log:debug "user authentication completed")))
        (log4cl:remove-all-appenders log4cl:*root-logger*)))
    #+bark-bench/vom
    (progn
      ;; vom — set level to :warn, call vom:debug (disabled)
      (vom:config t :warn)
      (unwind-protect
          (disabled-level-row "vom"
            (lambda () (vom:debug "user authentication completed")))
        (vom:config t :info)))
    (terpri)))

(register-comparative-scenario "simple-message"
  (lambda () (run-comparative-scenario "simple-message" :message)))

(register-comparative-scenario "message-5-fields"
  (lambda () (run-comparative-scenario "message-5-fields" :fields-5)))

(register-comparative-scenario "message-10-fields"
  (lambda () (run-comparative-scenario "message-10-fields" :fields-10)))

(register-comparative-scenario "with-child-context"
  (lambda () (run-comparative-scenario "with-child-context" :with-context)))

(register-comparative-scenario "concurrent-1-thread"
  (lambda ()
    (format t "~&comparative: concurrent-1-thread (discard sink)~%~%")
    (dolist (adapter (reverse *available-loggers*))
      (destructuring-bind (name setup-fn _msg _5 _10 _ctx teardown-fn) adapter
        (declare (ignore _msg _5 _10 _ctx))
        (funcall setup-fn)
        (unwind-protect
            (multiple-value-bind (throughput _name threads total elapsed)
                (run-concurrent-scenario name (adapter-getter adapter :fields-5)
                  :threads 1)
              (declare (ignore _name))
              (print-throughput-result throughput name threads total elapsed))
          (funcall teardown-fn))))))

(register-comparative-scenario "concurrent-8-threads"
  (lambda ()
    (format t "~&comparative: concurrent-8-threads (discard sink)~%~%")
    (dolist (adapter (reverse *available-loggers*))
      (destructuring-bind (name setup-fn _msg _5 _10 _ctx teardown-fn) adapter
        (declare (ignore _msg _5 _10 _ctx))
        (funcall setup-fn)
        (unwind-protect
            (multiple-value-bind (throughput _name threads total elapsed)
                (run-concurrent-scenario name (adapter-getter adapter :fields-5))
              (declare (ignore _name))
              (print-throughput-result throughput name threads total elapsed))
          (funcall teardown-fn))))))

(register-comparative-scenario "raw-baseline"
  (lambda ()
    (format t "~&comparative: raw-baseline (discard sink)~%")
    (format t "String-building floor (including string allocation), not a logger~%~%")
    (multiple-value-bind (time-samples bytes-timer name batch-size)
        (run-batch-scenario "raw-baseline" #'raw-baseline-fields-5
          :batch-size *default-sample-batch-size*)
      (print-sampled-result time-samples bytes-timer name batch-size))))
