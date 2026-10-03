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

;;; cl-bark.asd — System definition
(asdf:defsystem #:cl-bark
  :description "High-performance structured logger for Common Lisp"
  :long-description "Async structured logging with JSON/logfmt/pretty output, multi-output fan-out, child loggers, sampling, and request-scoped buffering."
  :author "Ivan Bulanov"
  :license "Apache-2.0"
  :homepage "https://github.com/ivanbulanov/cl-bark"
  :source-control (:git "https://github.com/ivanbulanov/cl-bark.git")
  :bug-tracker "https://github.com/ivanbulanov/cl-bark/issues"
  :version "0.1.0"
  :depends-on (#:atomics #:bordeaux-threads #:dissect #:local-time)
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "levels")
     (:file "conditions")
     (:file "timestamps")
     (:file "format-util")
     (:file "json")
     (:file "logfmt")
     (:file "pretty")
     (:file "ring-buffer")
     (:file "writer")
     (:file "output")
     (:file "logger")
     (:file "buffer")))))

(asdf:defsystem #:cl-bark/tests
  :depends-on (#:cl-bark #:fiveam #:uiop #:yason)
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "tests")
     (:file "blocking-tests")))))

(asdf:defsystem #:cl-bark/concurrency-tests
  :depends-on (#:cl-bark #:fiveam #:bordeaux-threads)
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "sampling-concurrency-tests")))))

(asdf:defsystem #:cl-bark/bench
  :description "Internal microbenchmarks for cl-bark"
  :depends-on (#:cl-bark #:trivial-benchmark #:trivial-garbage #:bordeaux-threads #:cffi)
  :serial t
  :components
  ((:module "bench"
    :components
    ((:file "packages")
     (:file "harness")
     (:file "internal")))))

(asdf:defsystem #:cl-bark/bench-comparative
  :description "Comparative benchmarks: cl-bark vs other CL loggers"
  :depends-on (#:cl-bark/bench)
  :weakly-depends-on (#:log4cl #:vom #:verbose)
  :serial t
  :components
  ((:module "bench"
    :components
    ((:file "comparative")))))
