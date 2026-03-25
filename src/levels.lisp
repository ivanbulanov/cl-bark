;;; src/levels.lisp — Log level constants and conversions

(in-package #:bark)

(defconstant +trace+ 1 "Trace log level.")

(defconstant +debug+ 2 "Debug log level.")

(defconstant +info+ 3 "Info log level.")

(defconstant +warn+ 4 "Warning log level.")

(defconstant +error+ 5 "Error log level.")

(defconstant +fatal+ 6 "Fatal log level.")

(defconstant +level-slot-count+ (1+ +fatal+)
  "Number of level index slots (0 through fatal).")

;;; --- Level management ---

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

