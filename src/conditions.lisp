;;; src/conditions.lisp — Condition capture for structured logging

(in-package #:bark)

;;; --- Condition Capture ---

(defstruct (captured-error (:constructor %make-captured-error))
  "A condition snapshot with stack trace for structured logging."
  (condition nil :type condition :read-only t)
  (stack     nil :type list     :read-only t))

(setf (documentation 'captured-error-p 'function) "Return T if OBJECT is a captured-error."
      (documentation 'captured-error-condition 'function) "The original condition object."
      (documentation 'captured-error-stack 'function) "List of stack frames captured at snapshot time.")

(defun internal-frame-p (frame)
  "Return T if FRAME belongs to BARK or DISSECT internals."
  (let ((call (dissect:call frame)))
    (typecase call
      (symbol
       (let ((pkg (symbol-package call)))
         (and pkg (member (package-name pkg) '("BARK" "DISSECT") :test #'string=))))
      (t
       (let ((s (string-upcase (princ-to-string call))))
         (or (search "BARK" s) (search "DISSECT" s)))))))

(defun strip-internal-frames (frames)
  "Drop leading BARK/DISSECT internal frames from FRAMES list."
  (loop for rest on frames
        while (internal-frame-p (car rest))
        finally (return rest)))

(defun capture (condition)
  "Snapshot CONDITION with the current stack trace for structured logging.
Returns an opaque captured-error (testable with captured-error-p, readable
with captured-error-condition and captured-error-stack). Pass the result as
a log field value — formatters serialize it with type, message, and stack.
Call inside HANDLER-BIND for a meaningful trace (stack still live).
In HANDLER-CASE the trace reflects the handler's stack, not the error origin."
  (%make-captured-error :condition condition
                        :stack (strip-internal-frames (dissect:stack))))
