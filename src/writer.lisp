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

;;; src/writer.lisp — Async output and writer thread

(in-package #:bark)

(declaim (ftype (function () (values double-float &optional)) monotonic-seconds))

(defun monotonic-seconds ()
  "Current time in seconds (monotonic, double-float precision)."
  (/ (get-internal-real-time)
     #.(coerce internal-time-units-per-second 'double-float)))

(declaim (ftype (function (string &rest t) (values &optional)) %report))

(defun %report (control &rest args)
  "Best-effort internal diagnostic on *error-output*. Never signals: the stream
   it writes to may be the very one that just failed."
  (ignore-errors
   (apply #'format *error-output* control args)
   (force-output *error-output*))
  (values))

(defun default-on-drop (count)
  "Default drop handler. Returns (values message fields) for the formatter.
   Message is a string, fields is nil. Either value can be nil to suppress."
  (format nil "bark: dropped ~d log messages (output too slow)" count))

;;; --- Stream locks ---
;;;
;;; SBCL fd-streams are not thread-safe, and nothing stops two writers from
;;; targeting the same stream: two root loggers on *error-output*, or one tee
;;; listing a stream twice with different filters. Every write to a stream,
;;; whether from a writer thread or from the synchronous fallback after stop,
;;; holds the lock for that stream's underlying object.

(defvar *stream-locks* (make-hash-table :test 'eq :weakness :key :synchronized t)
  "Lock per underlying output stream, shared by every writer that targets it.")

(declaim (ftype (function (stream) (values stream &optional)) resolve-stream))

(defun resolve-stream (stream)
  "Follow synonym streams to the stream they currently denote, so that two
   synonyms for the same fd share one lock."
  (loop while (typep stream 'synonym-stream)
        do (setf stream (symbol-value (synonym-stream-symbol stream))))
  stream)

(declaim (ftype (function (stream) (values t &optional)) stream-lock))

(defun stream-lock (stream)
  "Return the lock guarding writes to STREAM, creating it on first use."
  (let ((key (resolve-stream stream)))
    (or (gethash key *stream-locks*)
        (sb-ext:with-locked-hash-table (*stream-locks*)
          (or (gethash key *stream-locks*)
              (setf (gethash key *stream-locks*) (bt:make-lock "bark-stream")))))))

;;; --- Async output ---

(defstruct (async-output (:constructor %make-async-output))
  "Writer thread + ring buffer for async log delivery. An output made with
   :async nil has neither thread nor writer: its ring only counts dropped lines."
  (ring              nil   :type (or null ring-buffer))
  (thread            nil   :type (or null bt:thread))
  (stream            nil   :type (or null stream))
  ;; :running  — writer thread alive, lines go through the ring.
  ;; :stopping — stop claimed; the writer is draining and will exit.
  ;; :stopped  — clean stop; later lines are written synchronously by the caller.
  ;; :failed   — the writer died (unrecoverable stream error or thread death);
  ;;             later lines are counted as dropped.
  ;; :sync     — made with :async nil: no writer; each line is written and
  ;;             forced by the caller under the stream lock.
  (state             :running :type (member :running :stopping :stopped :failed :sync))
  ;; Set by stop; the writer loop exits when it sees it.
  (quit              nil   :type boolean)
  ;; True while the writer is (about to be) waiting on NOTIFY. Producers only
  ;; signal the semaphore when this is set, see notify-writer.
  (sleeping          nil   :type boolean)
  (formatter         nil   :type (or null formatter))
  (on-drop           nil   :type (or null function))
  (on-error          nil   :type (or null function))
  (notify            nil   :type t)
  (flush-lock        nil   :type t)
  ;; List of (semaphore . head-index): acknowledged once every line pushed
  ;; before head-index has been written.
  (flush-acks        nil   :type list)
  ;; Blocking mode slots
  (blocking-p        nil   :type boolean)
  (block-timeout     5.0d0 :type (or double-float null))
  (on-block-timeout  nil   :type (or null function))
  (block-dropped     0     :type (unsigned-byte 64))
  (space-lock        nil   :type t)
  (space-available   nil   :type t)
  ;; Set by the save hook: how to find the stream again after the image is
  ;; restored. NIL, :STDOUT, :STDERR or (:FILE . PATHNAME).
  (restart-key       nil   :type t)
  ;; Lines already announced by a drop warning. The ring counter restarts from
  ;; zero after each warning; this one only grows, for DROPPED-COUNT.
  (dropped-reported  0     :type (unsigned-byte 64)))

(declaim (inline async-output-running))

(defun async-output-running (async-output)
  "Return T while the writer thread of ASYNC-OUTPUT accepts lines through the ring."
  (eq (async-output-state async-output) :running))

(defun broadcast-space-available (async-output)
  "Wake all blocked producers waiting for buffer space.
   No-op when non-blocking (space-available is nil)."
  (let ((cv (async-output-space-available async-output)))
    (when cv
      (bt:with-lock-held ((async-output-space-lock async-output))
        (sb-thread:condition-broadcast cv)))))

;;; --- Exit registry ---
;;;
;;; Every async output is tracked through a weak pointer so that one exit hook
;;; can drain all live writers before the image exits. SBCL runs exit hooks
;;; before it terminates other threads, so the writers are still alive here.

(defvar *live-outputs* nil
  "Weak pointers to async outputs whose writer threads may still be running.")

(defvar *live-outputs-lock* (bt:make-lock "bark-live-outputs")
  "Guards *live-outputs*.")

(defvar *exit-hook-installed* nil
  "True once stop-live-outputs has been pushed onto the implementation's exit hooks.")

(defvar *exit-flush-timeout* 2.0
  "Seconds the exit hook waits per async output for its writer to drain and exit.")

(defun live-output-p (weak-pointer)
  "True when WEAK-POINTER still points at an async output that is not stopped:
   one whose writer runs, or one made with :async nil."
  (let ((ao (sb-ext:weak-pointer-value weak-pointer)))
    (and ao (member (async-output-state ao) '(:running :stopping :sync)) t)))

(defun register-live-output (async-output)
  "Track ASYNC-OUTPUT for the exit hook, pruning entries that are gone or stopped."
  (bt:with-lock-held (*live-outputs-lock*)
    (setf *live-outputs*
          (cons (sb-ext:make-weak-pointer async-output)
                (delete-if-not #'live-output-p *live-outputs*)))
    (unless *exit-hook-installed*
      (setf *exit-hook-installed* t)
      (push #'stop-live-outputs sb-ext:*exit-hooks*)))
  (values))

(defun unregister-live-output (async-output)
  "Stop tracking ASYNC-OUTPUT."
  (bt:with-lock-held (*live-outputs-lock*)
    (setf *live-outputs*
          (delete-if (lambda (wp)
                       (let ((ao (sb-ext:weak-pointer-value wp)))
                         (or (null ao) (eq ao async-output))))
                     *live-outputs*)))
  (values))

(defun stop-live-outputs ()
  "Exit hook: stop every live async output so buffered lines reach their
   streams before the image exits. Waits at most *exit-flush-timeout* per output."
  (dolist (wp (bt:with-lock-held (*live-outputs-lock*) (copy-list *live-outputs*)))
    (let ((ao (sb-ext:weak-pointer-value wp)))
      (when ao
        (ignore-errors (stop-async-output ao :timeout *exit-flush-timeout*)))))
  (values))

;;; --- Construction ---

(defun start-writer-thread (async-output)
  "Start the writer thread of ASYNC-OUTPUT and record it in the output. The
   thread reports through the *ERROR-OUTPUT* of the calling thread."
  (let ((err-output *error-output*))
    (setf (async-output-thread async-output)
          (bt:make-thread (lambda ()
                            (let ((*error-output* err-output))
                              (writer-loop async-output)))
                          :name "bark-writer")))
  async-output)

(declaim (ftype (function (t &key (:capacity fixnum) (:formatter (or null formatter))
                                  (:on-drop (or null function)) (:on-error (or null function))
                                  (:blocking boolean) (:block-timeout t)
                                  (:on-block-timeout (or null function)))
                          (values async-output &optional)) make-async-output))

(defun make-async-output (stream &key (capacity +default-buffer-capacity+)
                                      formatter (on-drop #'default-on-drop) on-error
                                      blocking (block-timeout 5.0) on-block-timeout)
  "Create an async output that writes to STREAM via a background thread.
FORMATTER, when provided, is used to format on-drop warning bindings.
ON-DROP is called on the writer thread with the number of lines dropped since
the last report; NIL suppresses the report. ON-ERROR is called on the writer
thread with the stream error; return a replacement stream to continue or NIL to
stop. When BLOCKING is true, callers wait for space instead of dropping messages.
The output is drained automatically when the image exits."
  (let* ((notify (bt:make-semaphore :name "bark-notify"))
         (ao (%make-async-output
              :ring (make-ring-buffer capacity)
              :stream stream
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
    (register-live-output ao)
    (start-writer-thread ao)
    ao))

;;; --- Producer side ---

(declaim (inline notify-writer))

(defun notify-writer (async-output)
  "Wake the writer if it is sleeping. Called after a line has been pushed.
   The barrier pairs with the one in writer-wait: either the writer sees the
   line before it decides to sleep, or this producer sees SLEEPING and signals."
  (sb-thread:barrier (:memory))
  (when (async-output-sleeping async-output)
    (bt:signal-semaphore (async-output-notify async-output)))
  (values))

(declaim (ftype (function ((or async-output null) &optional real) (values boolean &optional))
                flush-async-output))

(defun flush-async-output (async-output &optional (timeout 5.0))
  "Flush the async writer. Blocks until every line pushed before this call has
   been written and the stream forced, or TIMEOUT seconds pass. Returns T when
   the writer acknowledged the flush, NIL on timeout or when ASYNC-OUTPUT is
   NIL, stopped, or failed."
  (when (and async-output
             (member (async-output-state async-output) '(:running :stopping)))
    (let ((ack (cons (bt:make-semaphore :name "bark-flush-ack")
                     (ring-buffer-head (async-output-ring async-output)))))
      (bt:with-lock-held ((async-output-flush-lock async-output))
        (push ack (async-output-flush-acks async-output)))
      (bt:signal-semaphore (async-output-notify async-output))
      (and (bt:wait-on-semaphore (car ack) :timeout timeout)
           (not (eq (async-output-state async-output) :failed))
           t))))

(declaim (ftype (function (t &key (:timeout real)) (values boolean &optional)) stop-async-output))

(defun stop-async-output (async-output &key (timeout 5.0))
  "Stop the writer thread of ASYNC-OUTPUT, draining pending lines first.
   Waits up to TIMEOUT seconds for the drain and again for the thread to exit.
   Returns T when the writer exited cleanly, NIL when ASYNC-OUTPUT was already
   stopped or the writer did not exit in time. Only the first concurrent caller
   performs the stop; others return NIL at once. After a clean stop, lines
   delivered to the output are written synchronously on the caller's thread."
  (when (and async-output
             (atomics:cas (async-output-state async-output) :running :stopping))
    (flush-async-output async-output timeout)
    (setf (async-output-quit async-output) t)
    ;; Wake blocked producers so they see the output is no longer running.
    (broadcast-space-available async-output)
    (bt:signal-semaphore (async-output-notify async-output))
    (let* ((thread (async-output-thread async-output))
           ;; join-thread returns :timeout (the default) when the thread did
           ;; not exit in time or was aborted; otherwise the loop's NIL.
           (exited (or (null thread)
                       (not (eq :timeout
                                (sb-thread:join-thread thread :timeout timeout :default :timeout)))))
           (clean (and exited (eq (async-output-state async-output) :stopping))))
      ;; Catch producers that entered the wait after the first broadcast.
      (broadcast-space-available async-output)
      (cond
        (clean
         (setf (async-output-state async-output) :stopped)
         ;; The writer is gone, so this thread is the single consumer now.
         (let ((ring (async-output-ring async-output))
               (stream (async-output-stream async-output)))
           (handler-case
               (bt:with-lock-held ((stream-lock stream))
                 (loop for line = (ring-buffer-pop ring) while line do
                   (write-string line stream)
                   (terpri stream))
                 (force-output stream))
             (cl:error () nil))))
        (t
         (setf (async-output-state async-output) :failed)))
      (signal-ready-acks async-output nil)
      (unregister-live-output async-output)
      clean)))

(declaim (ftype (function (list) (values (or null string) &optional)) sync-option-conflicts))
(defun sync-option-conflicts (options)
  "OPTIONS is a plist of the queue keywords (:capacity, :on-drop, :blocking,
   :block-timeout, :on-block-timeout) and whether each was given. Return the
   message for BARK-CONFIGURATION-ERROR when any was given together with
   :async nil, or NIL when none was."
  (let ((given (loop for (key value) on options by #'cddr
                     when value collect key)))
    (when given
      (format nil "Cannot specify ~{~S~^, ~} with :async nil: a synchronous output ~
                   has no queue and no writer thread." given))))

(declaim (ftype (function (t &key (:on-error (or null function))) (values async-output &optional)) make-sync-output))
(defun make-sync-output (stream &key on-error)
  "Create an output for make-logger :async nil: no writer thread and no queue.
Each line is written on the caller's thread under the stream lock and forced
out at once, so it reaches the stream even if the process is killed right
after. ON-ERROR is called on the caller's thread with the stream error; return
a replacement stream to write the line there and continue, or NIL to mark the
output failed. The output is tracked so that a saved core reopens its stream."
  (let ((ao (%make-async-output
             :ring (make-ring-buffer 16)
             :stream stream
             :on-error on-error
             :state :sync)))
    (register-live-output ao)
    ao))

(declaim (ftype (function (t string) (values (or null condition) &optional)) write-line-locked))
(defun write-line-locked (stream line)
  "Write LINE and a newline to STREAM under its stream lock and force it out.
   Return NIL, or the error that writing signaled."
  (handler-case
      (progn
        (bt:with-lock-held ((stream-lock stream))
          (write-string line stream)
          (terpri stream)
          (force-output stream))
        nil)
    (cl:error (condition) condition)))

(declaim (ftype (function (async-output string condition) (values &optional)) handle-sync-stream-error))
(defun handle-sync-stream-error (async-output line condition)
  "Handle a stream error of an output made with :async nil. The first thread to
   see the error marks the output failed and calls the on-error hook (as the
   writer thread does); when the hook returns a replacement stream, LINE is
   written there once more and the output goes back to :sync. Lines that arrive
   meanwhile, also from the hook itself, are counted as dropped, and so is LINE
   when it cannot be written."
  (let ((ring (async-output-ring async-output)))
    (if (and (atomics:cas (async-output-state async-output) :sync :failed)
             (handle-stream-error async-output condition))
        (let ((retry-error (write-line-locked (async-output-stream async-output) line)))
          (cond
            (retry-error
             (%report "bark: replacement stream failed too: ~a~%" retry-error)
             (atomics:atomic-incf (ring-buffer-dropped ring)))
            (t
             (setf (async-output-state async-output) :sync))))
        (atomics:atomic-incf (ring-buffer-dropped ring))))
  (values))

(declaim (ftype (function (async-output string) (values &optional)) write-sync-line))
(defun write-sync-line (async-output line)
  "Write LINE for an output made with :async nil, on the caller's thread.
   A stream error goes to HANDLE-SYNC-STREAM-ERROR."
  (let ((condition (write-line-locked (async-output-stream async-output) line)))
    (when condition
      (handle-sync-stream-error async-output line condition)))
  (values))

(declaim (ftype (function (async-output string) (values &optional)) write-line-synchronously))

(defun write-line-synchronously (async-output line)
  "After a clean stop the writer is gone: write LINE on the caller's thread,
   under the stream lock. Never signals; a failing stream counts the line as dropped."
  (when (write-line-locked (async-output-stream async-output) line)
    (atomics:atomic-incf (ring-buffer-dropped (async-output-ring async-output))))
  (values))

;;; --- Writer thread ---

(declaim (ftype (function (async-output) (values null &optional)) writer-loop))

(defun writer-loop (async-output)
  "Main loop for the async writer thread. The loop is total: an error in one
   iteration (a failing on-drop callback, a formatter bug) is reported and the
   next iteration proceeds. Whatever ends the thread, the cleanup marks the
   output and releases every waiter."
  (let* ((ring (async-output-ring async-output))
         (budget (ring-buffer-capacity ring)))
    (unwind-protect
         (loop until (async-output-quit async-output) do
           (handler-case (writer-iteration async-output ring budget)
             (serious-condition (c)
               (%report "bark: writer error (continuing): ~a~%" c)))
           (unless (async-output-quit async-output)
             (writer-wait async-output ring)))
      ;; Clean stop sets :stopping before QUIT; anything else is a death.
      (when (eq (async-output-state async-output) :running)
        (setf (async-output-state async-output) :failed))
      (setf (async-output-sleeping async-output) nil)
      (broadcast-space-available async-output)
      (signal-ready-acks async-output nil)
      (unless (eq (async-output-state async-output) :stopping)
        (unregister-live-output async-output))))
  nil)

(defun writer-wait (async-output ring)
  "Wait for work: a pushed line, a flush request, a stop, or the 100 ms poll
   that backs all of them. See notify-writer for the barrier protocol."
  (let ((notify (async-output-notify async-output)))
    (setf (async-output-sleeping async-output) t)
    (sb-thread:barrier (:memory))
    (unwind-protect
         (when (and (ring-buffer-empty-p ring)
                    (not (async-output-quit async-output)))
           (bt:wait-on-semaphore notify :timeout 0.1))
      (setf (async-output-sleeping async-output) nil))
    ;; Collapse signals that accumulated while the writer was awake.
    (loop while (sb-thread:try-semaphore notify)))
  (values))

(defun writer-iteration (async-output ring budget)
  "One writer cycle: drain up to BUDGET lines, force the stream, report drops,
   acknowledge satisfied flush requests, wake blocked producers. Bounding the
   batch keeps the housekeeping running under sustained overload, where the ring
   never empties."
  (let ((stream (async-output-stream async-output)))
    (multiple-value-bind (written stream-error) (write-batch ring stream budget)
      (declare (ignore written))
      (when (and stream-error (not (handle-stream-error async-output stream-error)))
        (setf (async-output-state async-output) :failed
              (async-output-quit async-output) t)))
    (emit-drop-warning async-output)
    (signal-ready-acks async-output (ring-buffer-tail ring))
    (broadcast-space-available async-output))
  (values))

(declaim (ftype (function (ring-buffer stream fixnum) (values fixnum (or null condition) &optional))
                write-batch))

(defun write-batch (ring stream budget)
  "Write up to BUDGET lines from RING to STREAM under the stream lock and force
   the stream. Returns (values lines-written error) where ERROR is the stream
   error that interrupted the batch, or NIL. The line being written when the
   error occurred is lost."
  (let ((written 0))
    (declare (type fixnum written))
    (bt:with-lock-held ((stream-lock stream))
      (handler-case
          (progn
            (loop repeat budget
                  for line = (ring-buffer-pop ring) while line
                  do (write-string line stream)
                     (terpri stream)
                     (incf written))
            (when (plusp written)
              (force-output stream))
            (values written nil))
        (cl:error (e)
          (values written e))))))

(defun handle-stream-error (async-output error)
  "Handle a stream write ERROR on the writer thread, or on the caller's thread
   for an output made with :async nil. Calls the on-error hook,
   which may return a replacement stream. Returns T when writing can continue,
   NIL when the writer must stop."
  (let ((on-error (async-output-on-error async-output)))
    (if on-error
        (handler-case
            (let ((new-stream (funcall on-error error)))
              (cond
                (new-stream
                 (setf (async-output-stream async-output) new-stream)
                 t)
                (t nil)))
          (cl:error (handler-error)
            (%report "bark: on-error handler failed: ~a (original: ~a)~%" handler-error error)
            nil))
        (progn
          (%report "bark: output stopped on stream error: ~a~%" error)
          nil))))

(defun signal-ready-acks (async-output written-through)
  "Acknowledge flush requests whose lines have all been written: those whose
   head index is at most WRITTEN-THROUGH. NIL acknowledges every request, used
   when the writer exits."
  (let ((ready nil))
    (bt:with-lock-held ((async-output-flush-lock async-output))
      (setf (async-output-flush-acks async-output)
            (loop for ack in (async-output-flush-acks async-output)
                  if (or (null written-through) (<= (cdr ack) written-through))
                    do (push ack ready)
                  else collect ack)))
    (dolist (ack ready)
      (bt:signal-semaphore (car ack))))
  (values))

(defun emit-drop-warning (async-output)
  "Check the drop counter and emit a formatted warning if messages were dropped.
   Atomically resets the counter via CAS. Errors in the on-drop callback, the
   formatter, or the stream are reported and never propagate."
  (let* ((ring (async-output-ring async-output))
         (dropped (ring-buffer-dropped ring)))
    (unless (plusp dropped)
      (return-from emit-drop-warning (values)))
    (let ((actual-dropped
            (loop for old = (ring-buffer-dropped ring)
                  when (atomics:cas (ring-buffer-dropped ring) old 0)
                    return old))
          (on-drop (async-output-on-drop async-output)))
      (atomics:atomic-incf (async-output-dropped-reported async-output)
                           actual-dropped)
      (unless on-drop
        (return-from emit-drop-warning (values)))
      (multiple-value-bind (message fields)
          (handler-case (funcall on-drop actual-dropped)
            (cl:error (e)
              (%report "bark: on-drop handler failed: ~a~%" e)
              (values nil nil)))
        (when (or message fields)
          (let ((line (handler-case (format-drop-warning async-output message fields)
                        (cl:error (e)
                          (%report "bark: could not format drop warning: ~a~%" e)
                          nil)))
                (stream (async-output-stream async-output)))
            (when line
              (handler-case
                  (bt:with-lock-held ((stream-lock stream))
                    (write-string line stream)
                    (terpri stream)
                    (force-output stream))
                (cl:error () nil))))))))
  (values))

(defun format-drop-warning (async-output message fields)
  "Format the drop warning MESSAGE and FIELDS with the output's formatter, or as
   a minimal JSON object when the output has none."
  (let ((fmt (async-output-formatter async-output)))
    (if (formatter-p fmt)
        (funcall (formatter-format-fn fmt) +warn+ "" nil message fields)
        (with-output-to-string (s)
          (write-string "{\"level\":\"warn\",\"msg\":" s)
          (write-json-string s (or message ""))
          (write-char #\} s)))))

;;; --- Blocking delivery ---

(defun blocking-deliver (ao line)
  "Deliver LINE to blocking async-output AO, waiting for space if full."
  (let ((ring (async-output-ring ao)))
    ;; Fast path: try offer without locking
    (when (ring-buffer-offer ring line)
      (notify-writer ao)
      (return-from blocking-deliver))
    ;; Slow path: wait for space
    (let* ((timeout (async-output-block-timeout ao))
           (deadline (when timeout
                       (+ (monotonic-seconds) timeout))))
      (bt:with-lock-held ((async-output-space-lock ao))
        (loop
          (when (ring-buffer-offer ring line)
            (notify-writer ao)
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
            (%report "bark: on-block-timeout handler failed: ~a~%" e)))))
    (atomics:atomic-incf (async-output-block-dropped ao))))

;;; --- Save and restore ---

(defvar *saved-outputs* nil
  "Weak pointers to the async outputs the save hook stopped, to be restarted by
   the init hook. Guarded by *LIFECYCLE-LOCK*.")

(defvar *lifecycle-lock* (bt:make-lock "bark-lifecycle")
  "Serializes the save and init hooks.")

(defun restart-key (stream)
  "Describe how to find STREAM again in a restored image. Synonym streams and
   streams of unknown kind are kept as they are (NIL); the standard streams are
   found again by name; file streams by their pathname."
  (cond
    ((typep stream 'synonym-stream) nil)
    ((eq stream sb-sys:*stdout*) :stdout)
    ((eq stream sb-sys:*stderr*) :stderr)
    ((and (typep stream 'file-stream) (output-stream-p stream))
     (let ((path (ignore-errors (pathname stream))))
       (and path (list :file path (stream-external-format stream)))))
    (t nil)))

(defun restored-stream (async-output)
  "Return the stream ASYNC-OUTPUT must write to in the restored image, or NIL
   when a file stream cannot be reopened. The standard streams are recreated by
   SBCL at startup, so the old objects are stale. A file stream is reopened for
   appending, because its descriptor does not survive the save."
  (let ((key (async-output-restart-key async-output)))
    (case key
      (:stdout sb-sys:*stdout*)
      (:stderr sb-sys:*stderr*)
      (t
       (if (consp key)
           (handler-case
               (open (second key) :direction :output :if-exists :append
                                  :if-does-not-exist :create
                                  :external-format (third key))
             (cl:error (e)
               (%report "bark: cannot reopen ~a after restore: ~a~%" (second key) e)
               nil))
           (async-output-stream async-output))))))

(defun save-live-outputs ()
  "Save hook (sb-ext:*save-hooks*): stop the writer thread of every running
   async output, draining its pending lines, so that save-lisp-and-die is not
   refused for lack of a single thread. Each output stopped here is remembered
   and restarted by RESTART-SAVED-OUTPUTS in the restored image. An output made
   with :async nil has no thread; it is remembered too, so that its stream is
   looked up again. Outputs that are already stopped or failed are left alone.
   Idempotent."
  (bt:with-lock-held (*lifecycle-lock*)
    (dolist (wp (bt:with-lock-held (*live-outputs-lock*) (copy-list *live-outputs*)))
      (let ((ao (sb-ext:weak-pointer-value wp)))
        (when (and ao (member (async-output-state ao) '(:running :sync)))
          (setf (async-output-restart-key ao)
                (restart-key (async-output-stream ao)))
          (cond
            ((eq (async-output-state ao) :sync)
             (pushnew wp *saved-outputs*))
            ((ignore-errors (stop-async-output ao :timeout *exit-flush-timeout*))
             (push (sb-ext:make-weak-pointer ao) *saved-outputs*))
            (t
             (%report "bark: writer did not stop cleanly before save; not restarting it~%")))))))
  (values))

(defun restart-saved-outputs ()
  "Init hook (sb-ext:*init-hooks*): restart the writer thread of every async
   output that SAVE-LIVE-OUTPUTS stopped. The standard streams are looked up
   again, because SBCL recreates them at startup; a file stream is reopened for
   appending. An output made with :async nil gets its stream back the same way,
   without a thread. An output whose file cannot be reopened is marked failed
   and counts later lines as dropped. Idempotent: each output restarts once."
  (bt:with-lock-held (*lifecycle-lock*)
    (let ((saved *saved-outputs*))
      (setf *saved-outputs* nil)
      (dolist (wp saved)
        (let ((ao (sb-ext:weak-pointer-value wp)))
          (when (and ao (member (async-output-state ao) '(:stopped :sync)))
            (let ((stream (restored-stream ao)))
              (cond
                ((and stream (eq (async-output-state ao) :sync))
                 (setf (async-output-stream ao) stream))
                (stream
                 (setf (async-output-stream ao) stream
                       (async-output-quit ao) nil
                       (async-output-sleeping ao) nil
                       (async-output-flush-acks ao) nil
                       (async-output-notify ao) (bt:make-semaphore :name "bark-notify"))
                 (register-live-output ao)
                 (start-writer-thread ao)
                 (setf (async-output-state ao) :running))
                (t
                 (setf (async-output-state ao) :failed)))))))))
  (values))

(pushnew 'save-live-outputs sb-ext:*save-hooks*)

(pushnew 'restart-saved-outputs sb-ext:*init-hooks*)
