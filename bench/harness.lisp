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

;;; bench/harness.lisp — Benchmark harness with nanosecond timing via CFFI

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

(defvar *default-sample-batch-size* 100
  "Default calls per sample for sampled-batch scenarios.
   Each sample measures this many calls; per-call time is derived by division.")

(defvar *default-concurrent-iterations* 100000
  "Default iterations per thread for concurrent throughput scenarios.")

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
;;; Nanosecond monotonic clock via CFFI
;;; ============================================================

(cffi:defcstruct timespec
  (tv-sec :long)
  (tv-nsec :long))

(defvar +clock-monotonic+
  #+linux 1
  #+darwin 6
  #+freebsd 4
  #-(or linux darwin freebsd) 0
  "CLOCK_MONOTONIC constant. Falls back to CLOCK_REALTIME (0) on unknown OS.")

(declaim (inline get-monotonic-ns))
(defun get-monotonic-ns ()
  "Return monotonic time in nanoseconds."
  (cffi:with-foreign-object (ts '(:struct timespec))
    (cffi:foreign-funcall "clock_gettime"
      :int +clock-monotonic+ :pointer ts :int)
    (the integer
      (+ (the integer (* (cffi:foreign-slot-value ts '(:struct timespec) 'tv-sec)
                         1000000000))
         (the integer (cffi:foreign-slot-value ts '(:struct timespec) 'tv-nsec))))))

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

(defun compute-sample-stats (samples)
  "Compute p50, mean, p99 from a double-float sample vector (seconds).
   Returns (values p50 mean p99 n)."
  (let* ((sorted (sort (copy-seq samples) #'<))
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

(defun run-batch-scenario (name thunk &key (iterations *default-iterations*)
                                           (warmup *default-warmup*)
                                           (batch-size *batch-size*))
  "Run a batch-measured scenario.
   Each sample measures BATCH-SIZE calls with nanosecond timing.
   Bytes-consed tracked separately via trivial-benchmark.
   Returns (values time-samples bytes-timer name batch-size)
   where time-samples is a (simple-array double-float) of batch times in seconds."
  ;; Warmup — run full batches to warm the same tight-loop code path
  ;; that measurement uses (branch predictor, inline caches)
  (let ((warmup-batches (ceiling warmup batch-size)))
    (dotimes (i warmup-batches)
      (dotimes (j batch-size)
        (funcall thunk))))
  ;; GC
  (trivial-garbage:gc :full t)
  ;; Measure — each sample is one batch, timed with ns clock
  (let ((time-samples (make-array iterations :element-type 'double-float
                                             :initial-element 0.0d0))
        (bytes-timer (make-instance 'org.shirakumo.trivial-benchmark:timer)))
    (dotimes (i iterations)
      (org.shirakumo.trivial-benchmark:with-sampling (bytes-timer)
        (let ((start (get-monotonic-ns)))
          (dotimes (j batch-size)
            (funcall thunk))
          (setf (aref time-samples i)
                (/ (coerce (- (get-monotonic-ns) start) 'double-float) 1.0d9)))))
    (values time-samples bytes-timer name batch-size)))

(defun run-concurrent-scenario (name thunk &key (iterations *default-concurrent-iterations*)
                                                (warmup *default-warmup*)
                                                (threads *default-threads*))
  "Run a concurrent throughput scenario.
   Spawns THREADS worker threads, each calling THUNK ITERATIONS times.
   Returns (values throughput-msg/sec name threads total-messages elapsed-seconds)."
  ;; Warmup (single-threaded)
  (dotimes (i warmup) (funcall thunk))
  ;; GC
  (trivial-garbage:gc :full t)
  ;; Concurrent measurement — ns clock for wall-clock elapsed
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
    (let ((start (get-monotonic-ns)))
      ;; Wait for all to finish
      (dolist (w workers) (bordeaux-threads:join-thread w))
      (let* ((elapsed-ns (- (get-monotonic-ns) start))
             (elapsed (/ (coerce elapsed-ns 'double-float) 1.0d9))
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

(defun bytes-per-call (bytes-timer n-samples batch-size)
  "Extract per-call bytes from a trivial-benchmark timer, or :n/a on error."
  (handler-case
      (let ((total (org.shirakumo.trivial-benchmark:compute
                     :total
                     (org.shirakumo.trivial-benchmark:samples
                      bytes-timer 'org.shirakumo.trivial-benchmark:bytes-consed))))
        (/ total (* n-samples batch-size)))
    (error () :n/a)))

(defun print-sampled-result (time-samples bytes-timer name batch-size
                             &key (stream *standard-output*))
  "Print results for a sampled-batch scenario.
   TIME-SAMPLES: double-float vector of batch times (seconds).
   Per-call estimates are derived by dividing each by BATCH-SIZE."
  (let* ((n (length time-samples))
         ;; Derive per-call times, then compute stats
         (per-call (map '(simple-array double-float (*))
                        (lambda (s) (/ s batch-size))
                        time-samples)))
    (multiple-value-bind (p50 mean-val p99)
        (compute-sample-stats per-call)
      (let ((bytes (bytes-per-call bytes-timer n batch-size)))
        (format stream "~&~a~%" name)
        (format stream "  p50=~a, mean=~a, p99=~a"
                (format-time p50) (format-time mean-val) (format-time p99))
        (unless (eq bytes :n/a)
          (format stream ", bytes=~a" (format-bytes bytes)))
        (terpri stream)))))

(defun print-batch-result (time-samples bytes-timer name batch-size
                           &key (stream *standard-output*))
  "Print results for a large-batch scenario (sub-microsecond ops)."
  (multiple-value-bind (p50 mean p99 n)
      (compute-sample-stats time-samples)
    (let ((per-call-mean (/ mean batch-size)))
      (format stream "~&~a (batch: ~d calls)~%" name batch-size)
      (if (< per-call-mean 1.0d-8)
          (format stream "  per-call: < 10ns~%")
          (format stream "  per-call: ~a (p50=~a, mean=~a, p99=~a per batch)~%"
                  (format-time per-call-mean)
                  (format-time p50) (format-time mean) (format-time p99)))
      ;; bytes-consed for the batch
      (let ((bytes (bytes-per-call bytes-timer n batch-size)))
        (unless (eq bytes :n/a)
          (format stream "  bytes: ~a~%" (format-bytes bytes)))))))

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
                 (warmup *default-warmup*) (threads *default-threads*)
                 (concurrent-iterations *default-concurrent-iterations*))
  "Run benchmark scenarios.
   :suite    — :internal, :comparative, or nil (both)
   :scenario — scenario name string, or nil (all in suite)
   :iterations — measurement samples per scenario (default 10000)
   :warmup    — warmup iterations (default 10000)
   :threads   — thread count for concurrent scenarios (default 8)
   :concurrent-iterations — messages per thread for throughput scenarios (default 100000)"
  (let ((*default-iterations* iterations)
        (*default-warmup* warmup)
        (*default-threads* threads)
        (*default-concurrent-iterations* concurrent-iterations))
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
