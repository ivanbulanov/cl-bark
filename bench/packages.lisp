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
