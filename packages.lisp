;;; packages.lisp — Package definitions (auto-generated)

(defpackage "BARK"
  (:use "COMMON-LISP")
  (:shadow "DEBUG" "ERROR" "TRACE" "WARN")
  (:export "*COMPILE-TIME-MAX-LEVEL*"
           "*LOG-CONTEXT*"
           "*LOGGER*"
           "*MAX-EMIT-DEPTH*"
           "*MAX-EMIT-LENGTH*"
           ;; Serialization API
           "EMIT-JSON-VALUE" "EMIT-JSON-KEY" "EMIT-JSON-FIELDS"
           "EMIT-LOGFMT-VALUE" "EMIT-LOGFMT-KEY"
           "WRITE-JSON-ESCAPED-STRING" "SERIALIZE-BINDINGS"
           "ASYNC-OUTPUT"
           "CHILD"
           "DEBUG"
           "ERROR"
           "FATAL"
           "INFO"
           "JSON-FORMATTER"
           "LOGGER"
           "LOGGER-P"
           "LOGFMT-FORMATTER"
           ;; Multi-output
           "MAKE-TEE"
           "TEE"
           "MAKE-LOGGER"
           "PRETTY-FORMATTER"
           "SET-LEVEL"
           "SET-SAMPLING"
           "START"
           "STOP"
           "TRACE"
           "WARN"
           "WITH-CAPTURED-LOGS"
           "WITH-CONTEXT"))
