;;; src/levels.lisp — Log level constants and conversions

(in-package #:bark)

;;; --- Levels ---

(defconstant +trace+ 1 "Trace log level.")

(defconstant +debug+ 2 "Debug log level.")

(defconstant +info+ 3 "Info log level.")

(defconstant +warn+ 4 "Warning log level.")

(defconstant +error+ 5 "Error log level.")

(defconstant +fatal+ 6 "Fatal log level.")

(defconstant +level-slot-count+ (1+ +fatal+)
  "Number of level index slots (0 through fatal).")

(defparameter *level-colors*
  #(nil
    "36"    ; trace = cyan
    "34"    ; debug = blue
    "32"    ; info  = green
    "33"    ; warn  = yellow
    "31"    ; error = red
    "35")   ; fatal = magenta
  "ANSI color codes indexed by level.")

(defparameter *level-names* #(nil "trace" "debug" "info" "warn" "error" "fatal") "Vector of level name strings indexed by level.")

(defparameter *level-names-upper* #(nil "TRACE" "DEBUG" "INFO " "WARN " "ERROR" "FATAL")
  "Pre-computed uppercase padded level names for pretty-formatter.")

(declaim (ftype (function (keyword) (values fixnum &optional)) level-from-keyword))

(defun level-from-keyword (keyword)
  "Convert a level keyword like :TRACE to its numeric value."
  (ecase keyword
    (:trace +trace+)
    (:debug +debug+)
    (:info  +info+)
    (:warn  +warn+)
    (:error +error+)
    (:fatal +fatal+)))

(declaim (ftype (function (fixnum) (values string &optional)) level-name))

(defun level-name (level)
  "Convert a numeric level to its name string."
  (declare (type fixnum level))
  (if (<= +trace+ level +fatal+)
      (svref *level-names* level)
      "unknown"))

;;; Conditions

(define-condition bark-configuration-error (bark-error)
  ((detail :initarg :detail :reader bark-configuration-error-detail
           :type string))
  (:report (lambda (c s) (write-string (bark-configuration-error-detail c) s)))
  (:documentation "Signaled when constructor arguments are invalid or conflicting.
Raised by MAKE-LOGGER, MAKE-TEE, MAKE-CONSISTENT-SAMPLER, MAKE-LEVEL-SAMPLER,
and MAKE-WINDOWED-COUNTER on validation failure."))

(define-condition bark-lifecycle-error (bark-error)
  ()
  (:documentation "Signaled when an operation is invalid for the logger's current state."))

(define-condition bark-async-stopped (bark-lifecycle-error)
  ()
  (:report "Cannot flush: one or more async outputs have been stopped.")
  (:documentation "Signaled by FLUSH when an async output has been stopped.
A CONTINUE restart is available to skip stopped outputs."))

(define-condition bark-child-operation-error (bark-lifecycle-error)
  ((operation :initarg :operation :reader bark-child-operation-error-operation
              :type symbol))
  (:report (lambda (c s)
             (format s "Cannot ~(~A~) a child logger — it shares the parent's output. ~
                        ~(~:*~A~) the root logger instead."
                     (bark-child-operation-error-operation c))))
  (:documentation "Signaled when a root-only operation is attempted on a child logger.
A CONTINUE restart is available to silently ignore the operation."))
