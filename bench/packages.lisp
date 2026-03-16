;;; bench/packages.lisp — Benchmark package definition

(defpackage #:bark-bench
  (:use #:cl)
  (:export
   ;; Entry point
   #:run
   ;; Harness utilities (for comparative.lisp)
   #:*discard-stream*
   #:*default-iterations*
   #:*default-warmup*
   #:*default-threads*
   #:*default-sample-batch-size*
   #:*default-concurrent-iterations*
   #:*batch-size*
   #:run-batch-scenario
   #:run-concurrent-scenario
   #:print-header
   #:print-sampled-result
   #:print-batch-result
   #:print-throughput-result
   #:print-comparative-row
   #:print-comparative-header
   #:make-gate
   #:gate-wait
   #:gate-open
   ;; Payloads (shared between internal and comparative)
   #:*bench-message*
   #:*bench-fields-5*
   #:*bench-fields-10*
   #:*bench-context*))
