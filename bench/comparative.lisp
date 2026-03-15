;;; bench/comparative.lisp — Comparative benchmarks across CL loggers

(in-package #:bark-bench)

(declaim (optimize (speed 3) (safety 1)))

;;; ============================================================
;;; Soft-load competitor loggers
;;; ============================================================

(defvar *available-loggers* '()
  "List of (name setup-fn log-message-fn log-fields-5-fn log-fields-10-fn
            log-with-context-fn teardown-fn) for successfully loaded loggers.")

(defun try-load-logger (system-name)
  "Attempt to load a logger system. Returns T on success, NIL on failure."
  (handler-case
      (progn (asdf:load-system system-name) t)
    (error (c)
      (format t "~&;; Skipping ~a: ~a~%" system-name c)
      nil)))

;;; ============================================================
;;; cl-bark adapter (blocking mode)
;;; ============================================================

(defvar *bark-blocking-logger* nil)
(defvar *bark-blocking-child* nil)

(defun bark-blocking-setup ()
  (setf *bark-blocking-logger*
        (bark:make-logger :level :trace :output *discard-stream* :blocking t))
  (setf *bark-blocking-child*
        (bark:make-child *bark-blocking-logger* *bench-context*)))

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

(push (list "cl-bark (blocking)"
            #'bark-blocking-setup
            #'bark-blocking-log-message
            #'bark-blocking-log-fields-5
            #'bark-blocking-log-fields-10
            #'bark-blocking-log-with-context
            #'bark-blocking-teardown)
      *available-loggers*)

;;; ============================================================
;;; log4cl adapter
;;; ============================================================

(when (try-load-logger "log4cl")
  ;; Configuration: stream-appender to discard stream, default pattern layout.
  ;; Idiomatic log4cl usage — not tuned for maximum speed.
  ;; [Implementation left to the implementer — requires reading log4cl API]
  ;; After implementing, push adapter to *available-loggers*
  )

;;; ============================================================
;;; vom adapter
;;; ============================================================

(when (try-load-logger "vom")
  ;; Configuration: set vom:*log-hook* to write to *discard-stream*.
  ;; vom uses format strings, not structured fields.
  ;; [Implementation left to the implementer — requires reading vom API]
  ;; After implementing, push adapter to *available-loggers*
  )

;;; ============================================================
;;; verbose adapter
;;; ============================================================

(when (try-load-logger "verbose")
  ;; Configuration: verbose has its own async pipeline with worker threads.
  ;; CRITICAL: teardown must stop verbose's pipeline threads.
  ;; Report notes that verbose is also async (enqueue latency, not full I/O).
  ;; [Implementation left to the implementer — requires reading verbose API]
  ;; After implementing, push adapter to *available-loggers*
  )

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
   GETTER: :message, :fields-5, :fields-10, :with-context"
  (format t "~&comparative: ~a (discard sink)~%" scenario-name)
  (format t "Note: all loggers synchronous except verbose (has async pipeline)~%~%")
  (print-comparative-header)
  (dolist (adapter (reverse *available-loggers*))
    (destructuring-bind (name setup-fn log-msg log-5 log-10 log-ctx teardown-fn) adapter
      (declare (ignore log-msg log-5 log-10 log-ctx))
      (let ((fn (adapter-getter adapter getter)))
        (funcall setup-fn)
        (unwind-protect
            (if batch-p
                (multiple-value-bind (timer _name batch-size)
                    (run-batch-scenario name fn)
                  (declare (ignore _name))
                  (multiple-value-bind (p50 mean p99)
                      (compute-stats timer 'org.shirakumo.trivial-benchmark:real-time)
                    (print-comparative-row name
                      (/ p50 batch-size) (/ mean batch-size) (/ p99 batch-size)
                      nil)))
                (multiple-value-bind (timer _name)
                    (run-scenario name fn)
                  (declare (ignore _name))
                  (multiple-value-bind (p50 mean p99)
                      (compute-stats timer 'org.shirakumo.trivial-benchmark:real-time)
                    (let ((bytes
                            (handler-case
                                (let* ((samples (org.shirakumo.trivial-benchmark:samples
                                                timer 'org.shirakumo.trivial-benchmark:bytes-consed))
                                       (total (org.shirakumo.trivial-benchmark:compute :total samples))
                                       (n (length (org.shirakumo.trivial-benchmark:samples
                                                  timer 'org.shirakumo.trivial-benchmark:real-time))))
                                  (/ total n))
                              (error () nil))))
                      (print-comparative-row name p50 mean p99 bytes)))))
          (funcall teardown-fn))))))

;;; ============================================================
;;; Register comparative scenarios
;;; ============================================================

(register-comparative-scenario "disabled-level"
  (lambda ()
    ;; Special case: each logger must be set to a level that disables the call
    (format t "~&comparative: disabled-level (discard sink, batch-measured)~%~%")
    (print-comparative-header)
    ;; cl-bark blocking
    (let ((logger (bark:make-logger :level :warn :output *discard-stream* :blocking t)))
      (unwind-protect
          (multiple-value-bind (timer _name batch-size)
              (run-batch-scenario "cl-bark (blocking)"
                (lambda () (bark:debug logger *bench-message*)))
            (declare (ignore _name))
            (multiple-value-bind (p50 mean p99)
                (compute-stats timer 'org.shirakumo.trivial-benchmark:real-time)
              (print-comparative-row "cl-bark (blocking)"
                (/ p50 batch-size) (/ mean batch-size) (/ p99 batch-size) nil)))
        (bark:stop logger)))
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
    (multiple-value-bind (timer name)
        (run-scenario "raw-baseline" #'raw-baseline-fields-5)
      (print-scenario-result timer name))))
