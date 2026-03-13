;;; cl-bark.asd — System definition
(asdf:defsystem "cl-bark"
  :description "High-performance structured logger for Common Lisp"
  :author "Ivan Bulanov <https://github.com/ivanbulanov>"
  :license "MIT"
  :homepage "https://github.com/ivanbulanov/cl-bark"
  :depends-on ("atomics" "bordeaux-threads" "dissect" "local-time")
  :version "2.0.0"
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "bark")
     (:file "buffer")))))

(asdf:defsystem "cl-bark/tests"
  :depends-on ("cl-bark" "fiveam" "uiop" "yason")
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "tests")))))

(asdf:defsystem "cl-bark/concurrency-tests"
  :depends-on ("cl-bark" "fiveam" "bordeaux-threads")
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "sampling-concurrency-tests")))))
