;;; bench/internal.lisp — Internal cl-bark microbenchmark scenarios

(in-package #:bark-bench)

(declaim (optimize (speed 3) (safety 1)))

(defun make-bench-logger (&key (blocking nil) (capacity 8192)
                               (formatter #'bark:json-formatter))
  "Create a cl-bark logger writing to the discard stream.
   Returns the logger. Caller must call bark:stop when done."
  (bark:make-logger :level :trace
                    :output *discard-stream*
                    :formatter formatter
                    :capacity capacity
                    :blocking blocking))

;;; --- Scenario 1: disabled-level (batch-measured) ---

(register-internal-scenario "disabled-level"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (bark:set-level logger :warn)
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "disabled-level"
                (lambda ()
                  (bark:debug logger *bench-message*)))
            (print-batch-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 2: simple-message (async, default buffer) ---

(register-internal-scenario "simple-message"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "simple-message"
                (lambda ()
                  (bark:info logger *bench-message*))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 3: message-5-fields ---

(register-internal-scenario "message-5-fields"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "message-5-fields"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 4: message-10-fields ---

(register-internal-scenario "message-10-fields"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "message-10-fields"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t
                    :request-id "req-7f3a-4b2c-9d1e" :user-id 10042
                    :remote-addr "192.168.1.100" :bytes-sent 1247 :cached nil))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 5: child-no-context ---

(register-internal-scenario "child-no-context"
  (lambda ()
    (let* ((root (make-bench-logger))
           (child (bark:make-child root '())))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "child-no-context"
                (lambda ()
                  (bark:info child *bench-message*))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop root)))))

;;; --- Scenario 6: child-with-context (chindings) ---

(register-internal-scenario "child-with-context"
  (lambda ()
    (let* ((root (make-bench-logger))
           (child (bark:make-child root *bench-context*)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "child-with-context"
                (lambda ()
                  (bark:info child *bench-message*))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop root)))))

;;; --- Scenario 7: dynamic-context ---

(register-internal-scenario "dynamic-context"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "dynamic-context"
                (lambda ()
                  (bark:with-context (:service "user-api" :version "2.1.0"
                                     :instance-id 7 :production t)
                    (bark:info logger *bench-message*)))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 8: field-transform ---

(register-internal-scenario "field-transform"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (let ((xform-logger
              (bark:make-child logger '()
                :field-transform (lambda (key value)
                                   (declare (ignore key))
                                   value))))
        (unwind-protect
            (multiple-value-bind (time-samples bytes-timer name batch-size)
                (run-batch-scenario "field-transform"
                  (lambda ()
                    (bark:info xform-logger *bench-message*
                      :method "POST" :path "/api/v2/users" :status 201
                      :duration-ms 42.0d0 :authenticated t))
                  :batch-size *default-sample-batch-size*)
              (print-sampled-result time-samples bytes-timer name batch-size))
          (bark:stop logger))))))

;;; --- Scenario 9: formatter-comparison ---

(register-internal-scenario "formatter-comparison"
  (lambda ()
    ;; Use blocking mode to isolate formatter cost from async enqueue variance.
    ;; The write-to-discard cost is constant across formatters, so deltas
    ;; reflect pure formatting differences.
    (dolist (fmt-pair (list (cons "json" #'bark:json-formatter)
                           (cons "logfmt" #'bark:logfmt-formatter)
                           (cons "pretty" #'bark:pretty-formatter)))
      (let ((logger (make-bench-logger :blocking t
                                       :formatter (cdr fmt-pair))))
        (unwind-protect
            (multiple-value-bind (time-samples bytes-timer name batch-size)
                (run-batch-scenario (format nil "formatter-~a" (car fmt-pair))
                  (lambda ()
                    (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                  :batch-size *default-sample-batch-size*)
              (print-sampled-result time-samples bytes-timer name batch-size))
          (bark:stop logger))))))

;;; --- Scenario 10: tee-2-destinations ---

(register-internal-scenario "tee-2-destinations"
  (lambda ()
    (let* ((stream2 (make-broadcast-stream))
           (logger (bark:make-logger
                    :level :trace
                    :output (bark:make-tee
                             (list (list :stream *discard-stream*
                                         :formatter #'bark:json-formatter)
                                   (list :stream stream2
                                         :formatter #'bark:logfmt-formatter))))))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "tee-2-destinations"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 11: tee-shared-formatter ---

(register-internal-scenario "tee-shared-formatter"
  (lambda ()
    (let* ((stream2 (make-broadcast-stream))
           (logger (bark:make-logger
                    :level :trace
                    :output (bark:make-tee
                             (list (list :stream *discard-stream*
                                         :formatter #'bark:json-formatter)
                                   (list :stream stream2
                                         :formatter #'bark:json-formatter))))))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "tee-shared-formatter"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 12: buffer-full-drop (batch-measured) ---

(register-internal-scenario "buffer-full-drop"
  (lambda ()
    (let ((logger (make-bench-logger :capacity 16)))
      ;; Tiny buffer (16 slots) flooded with batch-size calls per sample.
      ;; The writer thread drains a few messages per batch (~us drain rate),
      ;; so the vast majority of calls hit the drop path.  This measures
      ;; drop-heavy workload, not the pure drop path in isolation.
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "buffer-full-drop"
                (lambda ()
                  (bark:info logger *bench-message*)))
            (print-batch-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 13: async-large-buffer ---

(register-internal-scenario "async-large-buffer"
  (lambda ()
    (let ((logger (make-bench-logger :capacity 131072)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "async-large-buffer"
                (lambda ()
                  (bark:info logger *bench-message*))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))

;;; --- Scenario 14: concurrent-1-thread ---

(register-internal-scenario "concurrent-1-thread"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (throughput name threads total elapsed)
              (run-concurrent-scenario "concurrent-1-thread"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                :threads 1)
            (print-throughput-result throughput name threads total elapsed))
        (bark:stop logger)))))

;;; --- Scenario 15: concurrent-8-threads ---

(register-internal-scenario "concurrent-8-threads"
  (lambda ()
    (let ((logger (make-bench-logger)))
      (unwind-protect
          (multiple-value-bind (throughput name threads total elapsed)
              (run-concurrent-scenario "concurrent-8-threads"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t)))
            (print-throughput-result throughput name threads total elapsed))
        (bark:stop logger)))))

;;; --- Scenario 16: blocking-mode ---

(register-internal-scenario "blocking-mode"
  (lambda ()
    (let ((logger (make-bench-logger :blocking t)))
      (unwind-protect
          (multiple-value-bind (time-samples bytes-timer name batch-size)
              (run-batch-scenario "blocking-mode"
                (lambda ()
                  (bark:info logger *bench-message*
                    :method "POST" :path "/api/v2/users" :status 201
                    :duration-ms 42.0d0 :authenticated t))
                :batch-size *default-sample-batch-size*)
            (print-sampled-result time-samples bytes-timer name batch-size))
        (bark:stop logger)))))
