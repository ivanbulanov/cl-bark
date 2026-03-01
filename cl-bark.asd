;;; cl-bark.asd — System definition (auto-generated)
(asdf:defsystem "cl-bark"
  :depends-on ("bordeaux-threads" "sb-concurrency")
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "bark")))
   ))

(asdf:defsystem "cl-bark/tests"
  :depends-on ("cl-bark" "fiveam" "uiop" "yason")
  :serial t
  :components
  ((:module "tests"
    :components
    ((:file "tests"))))
  )
