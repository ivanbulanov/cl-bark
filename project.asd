;;; funhouse-project.asd — System definition (auto-generated)
(asdf:defsystem "funhouse-project"
  :depends-on ("bordeaux-threads" "sb-concurrency")
  :serial t
  :components
  ((:file "packages")
   (:module "src"
    :components
    ((:file "bark")))
   ))
