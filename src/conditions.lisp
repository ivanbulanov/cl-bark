;;; Copyright 2026 Ivan Bulanov
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; src/conditions.lisp — Condition capture for structured logging

(in-package #:bark)

;;; --- Error capture ---

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

;;; --- Conditions ---

(define-condition bark-error (cl:error)
  ()
  (:documentation "Base condition for all cl-bark errors."))

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

(setf (documentation 'bark-configuration-error-detail 'function)
      "Return the human-readable string describing why the BARK-CONFIGURATION-ERROR was signaled."
      (documentation 'bark-child-operation-error-operation 'function)
      "Return the keyword naming the root-only operation (currently :STOP) that was attempted on a child logger.")
