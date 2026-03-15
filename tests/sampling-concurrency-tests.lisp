;;; tests/sampling-concurrency-tests.lisp — Sampling concurrency stress tests
;;; Run separately via: make test-concurrent
;;; Not included in the standard test suite (too slow for CI).

(defpackage #:bark-concurrency-tests
  (:use #:cl)
  (:import-from #:bark
   #:make-logger #:make-windowed-counter #:make-level-sampler
   #:set-level-sampling #:logger-debug-fn
   #:json-formatter #:make-child))

(in-package #:bark-concurrency-tests)

(5am:def-suite sampling-concurrency-tests
  :description "Concurrency stress tests for advanced sampling.")

(5am:in-suite sampling-concurrency-tests)

;;; --- Helpers ---

(defun make-counting-output ()
  "Return (values output-fn count-fn). Thread-safe counter."
  (let ((count 0)
        (lock (bt:make-lock "count")))
    (values (lambda (line)
              (declare (ignore line))
              (bt:with-lock-held (lock)
                (incf count)))
            (lambda () (bt:with-lock-held (lock) count)))))

;;; --- Windowed counter concurrency ---

(5am:test test-windowed-concurrent
  "N threads logging through shared windowed counter produce approximately correct count."
  (let ((threads 8)
        (messages-per-thread 10000)
        (initial 5)
        (thereafter 100))
    (multiple-value-bind (output count-fn) (make-counting-output)
      (let ((lgr (make-logger :context '(:name "conc") :level :debug
                              :formatter #'json-formatter :output output
                              :level-sampler (make-level-sampler
                                              :debug (make-windowed-counter
                                                      :initial initial
                                                      :thereafter thereafter
                                                      :window-seconds 60)))))
        (let ((thread-list nil))
          (dotimes (tid threads)
            (push (bt:make-thread
                   (lambda ()
                     (let ((fn (logger-debug-fn lgr)))
                       (dotimes (i messages-per-thread)
                         (funcall fn lgr "msg"))))
                   :name (format nil "wc-~d" tid))
                  thread-list))
          (dolist (th thread-list) (bt:join-thread th)))
        (let* ((total (* threads messages-per-thread))
               (expected (+ initial (floor (- total initial) thereafter)))
               (actual (funcall count-fn))
               (tolerance (* expected 0.05)))
          ;; Within 5% of expected
          (5am:is-true (<= (- expected tolerance) actual (+ expected tolerance))
                       "Expected ~d ±~,0f, got ~d" expected tolerance actual))))))

;;; --- set-level-sampling CAS race ---

(5am:test test-set-level-sampling-cas-race
  "Concurrent set-level-sampling from nil: exactly one vector allocated, all counters present."
  (let ((lgr (make-logger :context '(:name "cas") :level :debug))
        (counters (make-array 7 :initial-element nil)))
    ;; 6 threads, one per level (trace=1 through fatal=6)
    (let ((thread-list nil))
      (dotimes (tid 6)
        (let ((level-index (1+ tid)))  ; indices 1-6
          (let ((wc (make-windowed-counter :initial tid :thereafter (1+ tid))))
            (setf (aref counters level-index) wc)
            (push (bt:make-thread
                   (lambda ()
                     (set-level-sampling lgr level-index wc))
                   :name (format nil "cas-~d" tid))
                  thread-list))))
      (dolist (th thread-list) (bt:join-thread th)))
    ;; Verify: vector exists
    (5am:is-true (not (null (bark::logger-level-sampler lgr))))
    ;; Verify: all 6 level slots have their windowed-counter (no silent overwrites)
    (let ((ls (bark::logger-level-sampler lgr)))
      (5am:is (= bark::+level-slot-count+ (length ls)))
      (dotimes (idx 6)
        (let ((slot (aref ls (1+ idx))))
          (5am:is-true (eq slot (aref counters (1+ idx)))
                       "Slot ~d should have its assigned windowed-counter" (1+ idx)))))))

;;; --- No crash / no corruption ---

(5am:test test-concurrent-no-crash
  "Concurrent logging with both samplers does not crash or corrupt."
  (multiple-value-bind (output count-fn) (make-counting-output)
    (let ((lgr (make-logger :context '(:name "stress") :level :debug
                            :formatter #'json-formatter :output output
                            :consistent (bark:make-consistent-sampler
                                         :key-fn (lambda (b) (getf b :rid))
                                         :rate 5)
                            :level-sampler (make-level-sampler
                                            :debug (make-windowed-counter
                                                    :initial 10 :thereafter 50
                                                    :window-seconds 60)))))
      (let ((thread-list nil))
        ;; Half threads log with key (consistent path), half without (windowed path)
        (dotimes (tid 8)
          (let ((use-key (evenp tid)))
            (push (bt:make-thread
                   (lambda ()
                     (let* ((lgr2 (if use-key
                                      (make-child lgr (list :rid (format nil "req-~d" tid)))
                                      lgr))
                            (fn (logger-debug-fn lgr2)))
                       (dotimes (i 5000)
                         (funcall fn lgr2 "msg"))))
                   :name (format nil "stress-~d" tid))
                  thread-list)))
        (dolist (th thread-list) (bt:join-thread th)))
      ;; Just verify it completed without error and produced some output
      (5am:is-true (> (funcall count-fn) 0)
                   "Should have produced some output"))))
