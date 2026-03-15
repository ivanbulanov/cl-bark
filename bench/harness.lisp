;;; bench/harness.lisp — Benchmark harness wrapping trivial-benchmark

(in-package #:bark-bench)

(declaim (optimize (speed 3) (safety 1)))

;;; ============================================================
;;; Constants and globals
;;; ============================================================

(defvar *discard-stream* (make-broadcast-stream)
  "Portable /dev/null stream. All benchmark loggers write here.")

(defvar *default-iterations* 10000
  "Default number of measurement iterations per scenario.")

(defvar *default-warmup* 10000
  "Default number of warmup iterations before measurement.")

(defvar *default-threads* 8
  "Default thread count for concurrent scenarios.")

(defvar *batch-size* 100000
  "Number of calls per batch for sub-microsecond scenarios.")

;;; ============================================================
;;; Standard payloads
;;; ============================================================

(defvar *bench-message* "user authentication completed")

(defvar *bench-fields-5*
  '(:method "POST"
    :path "/api/v2/users"
    :status 201
    :duration-ms 42.0d0
    :authenticated t))

(defvar *bench-fields-10*
  '(:method "POST"
    :path "/api/v2/users"
    :status 201
    :duration-ms 42.0d0
    :authenticated t
    :request-id "req-7f3a-4b2c-9d1e"
    :user-id 10042
    :remote-addr "192.168.1.100"
    :bytes-sent 1247
    :cached nil))

(defvar *bench-context*
  '(:service "user-api" :version "2.1.0" :instance-id 7 :production t))

;;; ============================================================
;;; Statistics
;;; ============================================================

(defun compute-percentile (sorted-vector percentile)
  "Compute the given percentile (0-100) from a sorted vector."
  (let* ((n (length sorted-vector))
         (rank (* (/ percentile 100.0d0) (1- n)))
         (low (floor rank))
         (high (min (1+ low) (1- n)))
         (frac (- rank low)))
    (if (= low high)
        (aref sorted-vector low)
        (+ (* (- 1.0d0 frac) (aref sorted-vector low))
           (* frac (aref sorted-vector high))))))

(defun extract-sorted-samples (timer metric)
  "Extract raw samples from a trivial-benchmark timer, return as sorted vector."
  (let* ((raw (org.shirakumo.trivial-benchmark:samples timer metric))
         (copy (copy-seq raw)))
    (sort copy #'<)))

(defun compute-stats (timer metric)
  "Compute p50, mean, p99 from a timer's samples for a given metric.
   Returns (values p50 mean p99 sample-count)."
  (let* ((sorted (extract-sorted-samples timer metric))
         (n (length sorted))
         (total (reduce #'+ sorted))
         (mean (if (zerop n) 0.0d0 (/ total n)))
         (p50 (if (zerop n) 0.0d0 (compute-percentile sorted 50)))
         (p99 (if (zerop n) 0.0d0 (compute-percentile sorted 99))))
    (values p50 mean p99 n)))

;;; ============================================================
;;; Unit formatting
;;; ============================================================

(defun format-time (seconds)
  "Format a time value in appropriate units (ns, us, ms, s)."
  (cond
    ((< seconds 1.0d-6) (format nil "~dns" (round (* seconds 1.0d9))))
    ((< seconds 1.0d-3) (format nil "~,1fus" (* seconds 1.0d6)))
    ((< seconds 1.0d0)  (format nil "~,1fms" (* seconds 1.0d3)))
    (t                   (format nil "~,2fs" seconds))))

(defun format-bytes (bytes)
  "Format byte count."
  (if (zerop bytes) "0" (format nil "~d" (round bytes))))

;;; ============================================================
;;; Start gate (portable barrier via semaphores)
;;; ============================================================

(defstruct (gate (:constructor make-gate (thread-count)))
  "A start gate that blocks THREAD-COUNT threads until opened."
  (thread-count 0 :type fixnum :read-only t)
  (semaphore (bordeaux-threads:make-semaphore :name "bench-gate") :read-only t))

(defun gate-wait (gate)
  "Block until the gate is opened."
  (bordeaux-threads:wait-on-semaphore (gate-semaphore gate)))

(defun gate-open (gate)
  "Release all waiting threads by signaling the semaphore once per thread."
  (dotimes (i (gate-thread-count gate))
    (bordeaux-threads:signal-semaphore (gate-semaphore gate))))

;;; ============================================================
;;; Scenario runners
;;; ============================================================

(defun run-scenario (name thunk &key (iterations *default-iterations*)
                                     (warmup *default-warmup*))
  "Run a standard scenario: warmup, GC, then sample ITERATIONS calls.
   THUNK is a zero-arg function called once per iteration.
   Returns (values timer name)."
  ;; Warmup
  (dotimes (i warmup) (funcall thunk))
  ;; GC
  (trivial-garbage:gc :full t)
  ;; Measure
  (let ((timer (make-instance 'org.shirakumo.trivial-benchmark:timer)))
    (dotimes (i iterations)
      (org.shirakumo.trivial-benchmark:with-sampling (timer)
        (funcall thunk)))
    (values timer name)))

(defun run-batch-scenario (name thunk &key (iterations *default-iterations*)
                                           (warmup *default-warmup*)
                                           (batch-size *batch-size*))
  "Run a batch-measured scenario for sub-microsecond operations.
   Each sample measures BATCH-SIZE calls. Reports per-call average.
   Returns (values timer name batch-size)."
  ;; Warmup — run full batches to warm the same tight-loop code path
  ;; that measurement uses (branch predictor, inline caches)
  (let ((warmup-batches (ceiling warmup batch-size)))
    (dotimes (i warmup-batches)
      (dotimes (j batch-size)
        (funcall thunk))))
  ;; GC
  (trivial-garbage:gc :full t)
  ;; Measure — each sample is one batch
  (let ((timer (make-instance 'org.shirakumo.trivial-benchmark:timer)))
    (dotimes (i iterations)
      (org.shirakumo.trivial-benchmark:with-sampling (timer)
        (dotimes (j batch-size)
          (funcall thunk))))
    (values timer name batch-size)))

(defun run-concurrent-scenario (name thunk &key (iterations *default-iterations*)
                                                (warmup *default-warmup*)
                                                (threads *default-threads*))
  "Run a concurrent throughput scenario.
   Spawns THREADS worker threads, each calling THUNK ITERATIONS times.
   Returns (values throughput-msg/sec name threads total-messages elapsed-seconds)."
  ;; Warmup (single-threaded)
  (dotimes (i warmup) (funcall thunk))
  ;; GC
  (trivial-garbage:gc :full t)
  ;; Concurrent measurement
  (let* ((total-messages (* threads iterations))
         (gate (make-gate threads))
         (workers
           (loop repeat threads
                 collect (bordeaux-threads:make-thread
                          (lambda ()
                            (gate-wait gate)
                            (dotimes (i iterations)
                              (funcall thunk)))
                          :name "bench-worker"))))
    ;; Release all workers, then start the clock
    (gate-open gate)
    (let ((start (get-internal-real-time)))
      ;; Wait for all to finish
      (dolist (w workers) (bordeaux-threads:join-thread w))
      (let* ((end (get-internal-real-time))
             (elapsed (/ (- end start)
                         (coerce internal-time-units-per-second 'double-float)))
             (throughput (/ total-messages elapsed)))
        (values throughput name threads total-messages elapsed)))))

;;; ============================================================
;;; Reporting
;;; ============================================================

(defun print-header (&key (stream *standard-output*) (suite ""))
  "Print benchmark header with system information."
  (format stream "~&cl-bark ~a benchmarks~%" suite)
  (format stream "~a ~a, ~a~%"
          (lisp-implementation-type)
          (lisp-implementation-version)
          (machine-type))
  (format stream "Sink: discard (framework overhead only, not real-world throughput)~%")
  (format stream "Note: p99 includes GC pauses and OS scheduling jitter~%")
  (terpri stream))

(defun print-scenario-result (timer name &key (stream *standard-output*))
  "Print results for a standard scenario."
  (multiple-value-bind (p50 mean p99 n)
      (compute-stats timer 'org.shirakumo.trivial-benchmark:real-time)
    (declare (ignore n))
    (let ((bytes (handler-case
                     (org.shirakumo.trivial-benchmark:compute
                      :total
                      (org.shirakumo.trivial-benchmark:samples
                       timer 'org.shirakumo.trivial-benchmark:bytes-consed))
                   (error () :n/a))))
      (format stream "~&~a~%" name)
      (format stream "  p50=~a, mean=~a, p99=~a"
              (format-time p50) (format-time mean) (format-time p99))
      (unless (eq bytes :n/a)
        (let ((per-call (/ bytes (length (org.shirakumo.trivial-benchmark:samples
                                         timer 'org.shirakumo.trivial-benchmark:real-time)))))
          (format stream ", bytes=~a" (format-bytes per-call))))
      (terpri stream))))

(defun print-batch-result (timer name batch-size &key (stream *standard-output*))
  "Print results for a batch-measured scenario."
  (multiple-value-bind (p50 mean p99)
      (compute-stats timer 'org.shirakumo.trivial-benchmark:real-time)
    (let ((per-call-p50 (/ p50 batch-size))
          (per-call-mean (/ mean batch-size)))
      (declare (ignore per-call-p50))
      (format stream "~&~a (batch: ~d calls)~%" name batch-size)
      (if (< per-call-mean 1.0d-8)
          (format stream "  per-call: < 10ns~%")
          (format stream "  per-call: ~a (p50=~a, mean=~a, p99=~a per batch)~%"
                  (format-time per-call-mean)
                  (format-time p50) (format-time mean) (format-time p99)))
      ;; bytes-consed for the batch
      (let ((bytes (handler-case
                       (org.shirakumo.trivial-benchmark:compute
                        :total
                        (org.shirakumo.trivial-benchmark:samples
                         timer 'org.shirakumo.trivial-benchmark:bytes-consed))
                     (error () :n/a))))
        (unless (eq bytes :n/a)
          (let* ((n-samples (length (org.shirakumo.trivial-benchmark:samples
                                    timer 'org.shirakumo.trivial-benchmark:real-time)))
                 (per-call (/ bytes (* n-samples batch-size))))
            (format stream "  bytes: ~a~%" (format-bytes per-call))))))))

(defun print-throughput-result (throughput name threads total elapsed
                                &key (stream *standard-output*))
  "Print results for a concurrent throughput scenario."
  (format stream "~&~a (~d threads, ~d total messages, ~,3fs)~%"
          name threads total elapsed)
  (format stream "  throughput: ~,0f msg/sec~%" throughput))

(defun print-comparative-row (label p50 mean p99 bytes &key (stream *standard-output*))
  "Print one row of a comparative table."
  (format stream "  ~24a ~9a ~9a ~9a ~8a~%"
          label (format-time p50) (format-time mean) (format-time p99)
          (if bytes (format-bytes bytes) "")))

(defun print-comparative-header (&key (stream *standard-output*))
  "Print the header row of a comparative table."
  (format stream "  ~24a ~9a ~9a ~9a ~8a~%"
          "logger" "p50" "mean" "p99" "bytes")
  (format stream "  ~24a ~9a ~9a ~9a ~8a~%"
          (make-string 24 :initial-element #\-) "---" "---" "---" "---"))

;;; ============================================================
;;; Scenario registry
;;; ============================================================

(defvar *internal-scenarios* '()
  "List of (name . thunk) for internal scenarios. Populated by internal.lisp.")

(defvar *comparative-scenarios* '()
  "List of (name . thunk) for comparative scenarios. Populated by comparative.lisp.")

(defun register-internal-scenario (name thunk)
  "Register an internal benchmark scenario."
  (let ((existing (assoc name *internal-scenarios* :test #'string=)))
    (if existing
        (setf (cdr existing) thunk)
        (setf *internal-scenarios*
              (nconc *internal-scenarios* (list (cons name thunk)))))))

(defun register-comparative-scenario (name thunk)
  "Register a comparative benchmark scenario."
  (let ((existing (assoc name *comparative-scenarios* :test #'string=)))
    (if existing
        (setf (cdr existing) thunk)
        (setf *comparative-scenarios*
              (nconc *comparative-scenarios* (list (cons name thunk)))))))

;;; ============================================================
;;; Entry point
;;; ============================================================

(defun run (&key suite scenario (iterations *default-iterations*)
                 (warmup *default-warmup*) (threads *default-threads*))
  "Run benchmark scenarios.
   :suite    — :internal, :comparative, or nil (both)
   :scenario — scenario name string, or nil (all in suite)
   :iterations — measurement iterations per scenario (default 10000)
   :warmup    — warmup iterations (default 10000)
   :threads   — thread count for concurrent scenarios (default 8)"
  (let ((*default-iterations* iterations)
        (*default-warmup* warmup)
        (*default-threads* threads))
    (when (or (null suite) (eq suite :internal))
      (run-suite :internal scenario))
    (when (or (null suite) (eq suite :comparative))
      (run-suite :comparative scenario))))

(defun run-suite (suite scenario)
  "Run all scenarios in a suite, or a single named scenario."
  (let ((scenarios (ecase suite
                     (:internal *internal-scenarios*)
                     (:comparative *comparative-scenarios*))))
    (when (null scenarios)
      (format t "~&No ~a scenarios registered.~%" suite)
      (return-from run-suite))
    (print-header :suite (string-downcase (symbol-name suite)))
    (if scenario
        (let ((entry (assoc scenario scenarios :test #'string-equal)))
          (if entry
              (funcall (cdr entry))
              (format t "~&Unknown scenario: ~a~%" scenario)))
        (dolist (entry scenarios)
          (funcall (cdr entry))
          (terpri)))))
