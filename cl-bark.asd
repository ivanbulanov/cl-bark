;;; cl-bark.asd — System definition
(asdf:defsystem "cl-bark"
  :depends-on ("bordeaux-threads" "sb-concurrency")
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "bark")))))

(asdf:defsystem "cl-bark/tests"
  :depends-on ("cl-bark" "fiveam")
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "tests")))))
