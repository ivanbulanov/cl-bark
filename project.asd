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
