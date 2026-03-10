;;; cl-bark.asd — System definition
(asdf:defsystem "cl-bark"
  :description "High-performance structured logger for Common Lisp"
  :author "Ivan Bulanov <https://github.com/ivanbulanov>"
  :license "MIT"
  :homepage "https://github.com/ivanbulanov/cl-bark"
  :depends-on ("atomics" "bordeaux-threads" "local-time")
  :version "1.1.0"
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "bark")))))

(asdf:defsystem "cl-bark/tests"
  :depends-on ("cl-bark" "fiveam" "uiop" "yason")
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "tests")))))
