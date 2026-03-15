;;; cl-bark.asd — System definition
(asdf:defsystem #:cl-bark
  :description "High-performance structured logger for Common Lisp"
  :long-description "Async structured logging with JSON/logfmt/pretty output, multi-output fan-out, child loggers, sampling, and request-scoped buffering."
  :author "Ivan Bulanov"
  :license "MIT"
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
  :depends-on (#:cl-bark #:trivial-benchmark #:trivial-garbage #:bordeaux-threads)
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
