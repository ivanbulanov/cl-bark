;;; src/writer.lisp — Async output and writer thread

(in-package #:bark)

;;; --- Async Output ---

(declaim (ftype (function () (values double-float &optional)) monotonic-seconds))

(defun monotonic-seconds ()
  "Current time in seconds (monotonic, double-float precision)."
  (/ (get-internal-real-time)
     #.(coerce internal-time-units-per-second 'double-float)))

(defun default-on-drop (count)
  "Default drop handler. Returns (values message fields) for the formatter.
   Message is a string, fields is nil. Either value can be nil to suppress."
  (format nil "bark: dropped ~d log messages (output too slow)" count))

;;; Async output
(defstruct (async-output (:constructor %make-async-output))
  "Writer thread + ring buffer for async log delivery."
  (ring              nil   :type (or null ring-buffer))
  (thread            nil   :type (or null bt:thread))
  (stream            nil   :type (or null stream))
  (running           nil   :type boolean)
  (formatter         nil   :type (or null function))
  (on-drop           nil   :type (or null function))
  (on-error          nil   :type (or null function))
  (notify            nil   :type t)
  (flush-lock        nil   :type t)
  (flush-acks        nil   :type list)
  ;; Blocking mode slots
  (blocking-p        nil   :type boolean)
  (block-timeout     5.0d0 :type (or double-float null))
  (on-block-timeout  nil   :type (or null function))
  (block-dropped     0     :type (unsigned-byte 64))
  (space-lock        nil   :type t)
  (space-available   nil   :type t))

(defun broadcast-space-available (async-output)
  "Wake all blocked producers waiting for buffer space.
   No-op when non-blocking (space-available is nil)."
  (let ((cv (async-output-space-available async-output)))
    (when cv
      (bt:with-lock-held ((async-output-space-lock async-output))
        (sb-thread:condition-broadcast cv)))))

(declaim (ftype (function (t &key (:capacity fixnum) (:formatter (or null function))
                                  (:on-drop (or null function)) (:on-error (or null function))
                                  (:blocking boolean) (:block-timeout t)
                                  (:on-block-timeout (or null function)))
                          (values async-output &optional)) make-async-output))

(defun make-async-output (stream &key (capacity +default-buffer-capacity+)
                                      formatter (on-drop #'default-on-drop) on-error
                                      blocking (block-timeout 5.0) on-block-timeout)
  "Create an async output that writes to STREAM via a background thread.
FORMATTER, when provided, is used to format on-drop warning bindings.
When BLOCKING is true, callers wait for space instead of dropping messages."
  (let* ((notify (bt:make-semaphore :name "bark-notify"))
         (ao (%make-async-output
              :ring (make-ring-buffer capacity)
              :stream stream
              :running t
              :formatter formatter
              :on-drop on-drop
              :on-error on-error
              :notify notify
              :flush-lock (bt:make-lock "bark-flush")
              :blocking-p blocking
              :block-timeout (when block-timeout
                               (coerce block-timeout 'double-float))
              :on-block-timeout on-block-timeout
              :space-lock (when blocking
                            (bt:make-lock "bark-space"))
              :space-available (when blocking
                                 (bt:make-condition-variable
                                  :name "bark-space-available")))))
    (let ((err-output *error-output*))
      (setf (async-output-thread ao)
            (bt:make-thread (lambda ()
                              (let ((*error-output* err-output))
                                (writer-loop ao)))
                            :name "bark-writer")))
    ao))

(declaim (ftype (function ((or async-output null)) (values null &optional)) flush-async-output))

(defun flush-async-output (async-output)
  "Flush the async writer. Blocks until current queue is drained (5s timeout)."
  (when (and async-output (async-output-running async-output))
    (let ((ack (bt:make-semaphore :name "bark-flush-ack")))
      (bt:with-lock-held ((async-output-flush-lock async-output))
        (push ack (async-output-flush-acks async-output)))
      (bt:signal-semaphore (async-output-notify async-output))
      (bt:wait-on-semaphore ack :timeout 5.0)))
  nil)

(declaim (ftype (function (t) (values null &optional)) stop-async-output))

(defun stop-async-output (async-output)
  "Stop the async writer thread, draining all pending messages first."
  (when (and async-output (async-output-running async-output))
    (flush-async-output async-output)
    (setf (async-output-running async-output) nil)
    ;; Wake blocked producers immediately so they see running=nil and exit
    (broadcast-space-available async-output)
    (bt:signal-semaphore (async-output-notify async-output))
    (when (async-output-thread async-output)
      (bt:join-thread (async-output-thread async-output)))
    ;; Final broadcast to catch any producers that entered wait after the first
    (broadcast-space-available async-output)
    (let ((ring (async-output-ring async-output))
          (stream (async-output-stream async-output)))
      (handler-case
          (progn
            (loop for line = (ring-buffer-pop ring) while line do
              (write-string line stream)
              (terpri stream))
            (force-output stream))
        (cl:error () nil)))))

(declaim (ftype (function (async-output) (values null &optional)) writer-loop))

;;; Writer thread
(defun writer-loop (async-output)
  "Main loop for the async writer thread. Batch-drains the ring buffer."
  (let ((ring      (async-output-ring async-output))
        (stream    (async-output-stream async-output))
        (notify    (async-output-notify async-output))
        (drop-fmt  (async-output-formatter async-output)))
    (flet ((handle-stream-error (e)
             "Handle a stream write error. Returns T if recovered, NIL to exit."
             (let ((on-error (async-output-on-error async-output)))
               (if on-error
                   (handler-case
                       (let ((new-stream (funcall on-error e)))
                         (if new-stream
                             (progn (setf stream new-stream
                                          (async-output-stream async-output) new-stream)
                                    t)
                             (progn (setf (async-output-running async-output) nil)
                                    nil)))
                     (cl:error (handler-error)
                       (format *error-output* "bark on-error handler failed: ~a (original: ~a)~%" handler-error e)
                       (force-output *error-output*)
                       (setf (async-output-running async-output) nil)
                       nil))
                   (progn
                     (format *error-output* "bark writer-loop error: ~a~%" e)
                     (force-output *error-output*)
                     (setf (async-output-running async-output) nil)
                     nil)))))
      (loop while (async-output-running async-output) do
        (bt:wait-on-semaphore notify :timeout 0.1)
        (let ((wrote-p nil))
          (loop for line = (ring-buffer-pop ring) while line do
            (setf wrote-p t)
            (handler-case
                (progn (write-string line stream) (terpri stream))
              (cl:error (e) (unless (handle-stream-error e) (return)))))
          (when (and wrote-p (async-output-running async-output))
            (handler-case (force-output stream)
              (cl:error (e) (handle-stream-error e)))))
        (let ((dropped (ring-buffer-dropped ring)))
          (when (plusp dropped)
            (let ((actual-dropped
                    (loop for old = (ring-buffer-dropped ring)
                          when (atomics:cas (ring-buffer-dropped ring) old 0)
                            return old)))
              (let ((on-drop (async-output-on-drop async-output)))
                (when on-drop
                  (multiple-value-bind (message fields) (funcall on-drop actual-dropped)
                    (when (or message fields)
                      (handler-case
                          (let ((line (if drop-fmt
                                         (funcall drop-fmt +warn+ "" nil nil message fields)
                                         (format nil "{\"level\":~d,\"msg\":~s}" +warn+ (or message "")))))
                            (write-string line stream)
                            (terpri stream)
                            (force-output stream))
                        (cl:error () nil)))))))))
        (let ((acks (bt:with-lock-held ((async-output-flush-lock async-output))
                      (prog1 (async-output-flush-acks async-output)
                        (setf (async-output-flush-acks async-output) nil)))))
          (dolist (ack acks)
            (bt:signal-semaphore ack)))
        ;; Wake blocked producers under the lock to prevent lost wakeups.
        ;; Without the lock, a producer between offer-fail and condition-wait
        ;; could miss the broadcast and sleep until the next writer iteration.
        (broadcast-space-available async-output)))
    ;; Drain any orphaned flush-acks so callers don't stall for the 5s timeout
    (let ((acks (bt:with-lock-held ((async-output-flush-lock async-output))
                  (prog1 (async-output-flush-acks async-output)
                    (setf (async-output-flush-acks async-output) nil)))))
      (dolist (ack acks)
        (bt:signal-semaphore ack)))))

;;; --- Output Delivery ---

(defun blocking-deliver (ao line)
  "Deliver LINE to blocking async-output AO, waiting for space if full."
  (let ((ring (async-output-ring ao))
        (notify (async-output-notify ao)))
    ;; Fast path: try offer without locking
    (when (ring-buffer-offer ring line)
      (bt:signal-semaphore notify)
      (return-from blocking-deliver))
    ;; Slow path: wait for space
    (let* ((timeout (async-output-block-timeout ao))
           (deadline (when timeout
                       (+ (monotonic-seconds) timeout))))
      (bt:with-lock-held ((async-output-space-lock ao))
        (loop
          (when (ring-buffer-offer ring line)
            (bt:signal-semaphore notify)
            (return-from blocking-deliver))
          (unless (async-output-running ao)
            (return))
          (let ((remaining (when deadline
                             (- deadline (monotonic-seconds)))))
            (when (and remaining (<= remaining 0.0d0))
              (return))
            (bt:condition-wait (async-output-space-available ao)
                               (async-output-space-lock ao)
                               :timeout (or remaining nil))))))
    ;; Timed out or stopped — handle callback and count
    (let ((cb (async-output-on-block-timeout ao)))
      (when cb
        (handler-case (funcall cb line (async-output-stream ao))
          (cl:error (e)
            (format *error-output* "bark on-block-timeout error: ~a~%" e)
            (force-output *error-output*)))))
    (atomics:atomic-incf (async-output-block-dropped ao))))
