;;; cl-bark.asd — System definition (auto-generated)
(asdf:defsystem "cl-bark"
  :version "1.1.0"
  :depends-on ("bordeaux-threads")
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
