;;; src/ring-buffer.lisp — Lock-free MPSC ring buffer

(in-package #:bark)

(defconstant +min-ring-capacity+ 16 "Minimum ring buffer capacity in log lines. Power of two.")

(defconstant +default-buffer-capacity+ 8192 "Default ring buffer capacity in log lines for async output. Power of two.")

(defconstant +pop-spin-yield-threshold+ 1000
  "Spin iterations in ring-buffer-pop before yielding to the OS scheduler.
   Prevents unbounded CPU spin when a producer is preempted between CAS and slot write.")

;;; --- Ring Buffer ---

(defstruct (ring-buffer (:constructor %make-ring-buffer))
  "Lock-free MPSC ring buffer with drop-on-full semantics."
  (slots    #()  :type simple-vector)
  (mask     0    :type fixnum)
  (head     0    :type (unsigned-byte 64))
  (tail     0    :type (unsigned-byte 64))
  (dropped  0    :type (unsigned-byte 64)))

(defun make-ring-buffer (capacity)
  "Create a ring buffer with CAPACITY rounded up to the next power of two."
  (let* ((actual (max +min-ring-capacity+ (expt 2 (integer-length (1- capacity)))))
         (slots (make-array actual :initial-element nil)))
    (%make-ring-buffer :slots slots :mask (1- actual))))

(defun ring-buffer-pop (rb)
  "Pop the next value from the ring buffer. Returns NIL if empty. Single-consumer only.
   Spins briefly if a producer has claimed a slot but not yet written the value,
   yielding to the OS scheduler after +pop-spin-yield-threshold+ iterations."
  (declare (optimize (speed 3) (safety 1)))
  (let ((tail (ring-buffer-tail rb))
        (head (ring-buffer-head rb)))
    (when (< tail head)
      (let* ((idx (logand tail (ring-buffer-mask rb)))
             (val (svref (ring-buffer-slots rb) idx)))
        (loop while (null val)
              for spin fixnum from 0
              do (if (< spin +pop-spin-yield-threshold+)
                     (progn #+sbcl (sb-ext:spin-loop-hint))
                     (bt:thread-yield))
                 (setf val (svref (ring-buffer-slots rb) idx)))
        (setf (svref (ring-buffer-slots rb) idx) nil)
        (atomics:atomic-incf (ring-buffer-tail rb))
        val))))

(declaim (inline %ring-buffer-try-push))

(defun %ring-buffer-try-push (rb value track-drops)
  "Try to CAS VALUE into RB. When TRACK-DROPS is true, increment dropped counter
   on failure. Returns T on success, NIL if full."
  (declare (optimize (speed 3) (safety 1)))
  (let ((mask (ring-buffer-mask rb))
        (slots (ring-buffer-slots rb)))
    (loop
      (let* ((head (ring-buffer-head rb))
             (tail (ring-buffer-tail rb))
             (size (the fixnum (- head tail))))
        (when (>= size (1+ mask))
          (when track-drops
            (atomics:atomic-incf (ring-buffer-dropped rb)))
          (return nil))
        (when (atomics:cas (ring-buffer-head rb) head (1+ head))
          (setf (svref slots (logand head mask)) value)
          (return t))))))

(declaim (ftype (function (ring-buffer t) (values boolean &optional)) ring-buffer-push ring-buffer-offer))

(defun ring-buffer-push (rb value)
  "Push VALUE into the ring buffer. Returns T on success, NIL if full (increments drop counter)."
  (%ring-buffer-try-push rb value t))

(defun ring-buffer-offer (rb value)
  "Try to push VALUE onto RB. Returns T on success, NIL if full.
   Does NOT increment the dropped counter."
  (%ring-buffer-try-push rb value nil))

(defun ring-buffer-drain (rb)
  "Drain all available values from the ring buffer into a list. Single-consumer only."
  (loop for val = (ring-buffer-pop rb) while val collect val))
