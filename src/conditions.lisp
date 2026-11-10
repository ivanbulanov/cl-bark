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

(defvar *capture-max-frames* 50
  "Default for the :MAX-FRAMES argument of CAPTURE: the most stack frames a
captured error keeps. NIL keeps every frame. The formatter limits
(*MAX-JSON-STACK-FRAMES*, *MAX-PRETTY-STACK-FRAMES*) cut further when a line is
written.")

(defstruct (captured-error (:constructor %make-captured-error))
  "A condition snapshot with stack trace for structured logging."
  (condition nil :type condition :read-only t)
  (stack     nil :type list     :read-only t))

(setf (documentation 'captured-error-p 'function) "Return T if OBJECT is a captured-error."
      (documentation 'captured-error-condition 'function) "The original condition object."
      (documentation 'captured-error-stack 'function) "List of the stack frames captured at snapshot time, innermost first, each a plist
(:CALL string :FILE namestring-or-NIL :LINE integer-or-NIL).")

(defun frame-name-symbol (call)
  "Return the symbol that names the function of a frame whose call is CALL, or NIL.
CALL is a symbol, a string, or a list such as (FLET NAME :IN OUTER),
(LAMBDA ARGS :IN OUTER) or (SB-PCL::FAST-METHOD NAME ...); a form with :IN is
named by what follows :IN, another list by its second element."
  (typecase call
    (symbol call)
    (cons (let ((in (member :in call)))
            (if in
                (frame-name-symbol (second in))
                (frame-name-symbol (second call)))))
    (t nil)))

(defun internal-frame-p (frame)
  "Return T if the function of FRAME, a dissect frame, is named by a symbol of the
BARK or DISSECT package. The packages are compared, not the printed names, so a
user function such as EMBARK is not internal."
  (let ((name (frame-name-symbol (dissect:call frame))))
    (and name
         (member (symbol-package name)
                 (load-time-value (list (symbol-package 'capture)
                                        (symbol-package 'dissect:stack)))
                 :test #'eq)
         t)))

(defun strip-internal-frames (frames)
  "Drop the frames of CAPTURE and of what it called from FRAMES, a list of dissect
frames, innermost first. Called outside a handler, dissect:stack starts at its
own frame: everything up to and including the first CAPTURE frame goes. Called
in a handler, it starts at the frame that signalled, and no CAPTURE frame is
there. Then leading frames of BARK or DISSECT functions are dropped too."
  (let* ((capture-pos (position-if (lambda (frame)
                                     (eq (frame-name-symbol (dissect:call frame)) 'capture))
                                   frames))
         (rest (if capture-pos (nthcdr (1+ capture-pos) frames) frames)))
    (loop while (and rest (internal-frame-p (car rest)))
          do (pop rest))
    rest))

(defun frame-plist (frame)
  "Return FRAME, a live dissect frame, as plain data: a plist (:CALL string
:FILE namestring-or-NIL :LINE integer-or-NIL). The call is printed with
every package prefix but COMMON-LISP's. A frame that cannot be read or printed becomes
(:CALL \"#<unprintable frame>\" :FILE NIL :LINE NIL)."
  (handler-case
      (let ((call (dissect:call frame))
            (file (dissect:file frame))
            (line (dissect:line frame)))
        (list :call (if (stringp call)
                        call
                        (with-standard-io-syntax
                          (let ((*package* (find-package "COMMON-LISP"))
                                (*print-readably* nil)
                                (*print-pretty* nil))
                            (prin1-to-string call))))
              :file (and file (namestring file))
              :line (and (integerp line) line)))
    (serious-condition ()
      (list :call "#<unprintable frame>" :file nil :line nil))))

(defun capture (condition &key (max-frames *capture-max-frames*))
  "Snapshot CONDITION with the current stack trace for structured logging.
Returns a captured-error (testable with captured-error-p, readable with
captured-error-condition and captured-error-stack). Pass the result as a log
field value: formatters serialize it with type, message, and stack.

The stack is plain data, made while the frames are live: a list of at most
MAX-FRAMES (default *CAPTURE-MAX-FRAMES*, 50; NIL for all) plists
(:CALL string :FILE namestring-or-NIL :LINE integer-or-NIL), innermost first.
No frame object, argument or local variable is kept, so a captured error can be
stored, replayed from WITH-LOG-BUFFER or formatted later. A frame that cannot
be printed becomes (:CALL \"#<unprintable frame>\" :FILE NIL :LINE NIL).

Call inside HANDLER-BIND for a meaningful trace (stack still live).
In HANDLER-CASE the trace reflects the handler's stack, not the error origin."
  (%make-captured-error
   :condition condition
   :stack (loop for frame in (strip-internal-frames (dissect:stack))
                for i from 0
                while (or (null max-frames) (< i max-frames))
                collect (frame-plist frame))))

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
