;;; tests/blocking-tests.lisp — Blocking mode tests for cl-bark

(defpackage #:bark-blocking-tests
  (:use #:cl)
  (:import-from #:bark
   #:+trace+ #:+debug+ #:+info+ #:+warn+ #:+error+ #:+fatal+
   #:make-async-output #:stop-async-output #:flush-async-output
   #:async-output-stream #:async-output-running #:async-output-ring
   #:async-output-notify #:ring-buffer-push
   #:make-tee #:tee
   #:tee-output-p #:tee-output-groups
   #:destination-async-output #:formatter-group-destinations
   #:json-formatter #:make-json-formatter
   #:make-logger #:stop
   #:*logger*))

(in-package #:bark-blocking-tests)

(5am:def-suite blocking-tests
  :description "Tests for blocking mode backpressure in cl-bark.")

(5am:in-suite blocking-tests)

;;; --- ring-buffer-offer ---

(5am:test test-ring-buffer-offer-success
  "ring-buffer-offer returns T when space is available."
  (let ((rb (bark::make-ring-buffer 16)))
    (5am:is-true (bark::ring-buffer-offer rb "hello"))
    (5am:is (string= "hello" (bark::ring-buffer-pop rb)))))

(5am:test test-ring-buffer-offer-full-returns-nil
  "ring-buffer-offer returns NIL when buffer is full, without incrementing dropped."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 16) (bark::ring-buffer-offer rb (format nil "msg-~d" i)))
    (5am:is-false (bark::ring-buffer-offer rb "overflow"))
    (5am:is (= 0 (bark::ring-buffer-dropped rb)))))

(5am:test test-ring-buffer-offer-does-not-increment-dropped
  "ring-buffer-offer never touches the dropped counter, even after multiple failures."
  (let ((rb (bark::make-ring-buffer 16)))
    (dotimes (i 16) (bark::ring-buffer-offer rb "fill"))
    (dotimes (i 10) (bark::ring-buffer-offer rb "overflow"))
    (5am:is (= 0 (bark::ring-buffer-dropped rb)))))

;;; --- monotonic-seconds ---

(5am:test test-monotonic-seconds-returns-positive-double
  "monotonic-seconds returns a positive double-float."
  (let ((t0 (bark::monotonic-seconds)))
    (5am:is (typep t0 'double-float))
    (5am:is (plusp t0))))

(5am:test test-monotonic-seconds-monotonic
  "Two calls to monotonic-seconds are non-decreasing."
  (let ((t0 (bark::monotonic-seconds))
        (t1 (bark::monotonic-seconds)))
    (5am:is (<= t0 t1))))

;;; --- async-output blocking slots ---

(5am:test test-async-output-blocking-slots-default-nil
  "Non-blocking async-output has nil blocking slots — no OS resources allocated."
  (let ((ao (make-async-output (make-string-output-stream) :capacity 16)))
    (unwind-protect
         (progn
           (5am:is-false (bark::async-output-blocking-p ao))
           (5am:is (null (bark::async-output-space-lock ao)))
           (5am:is (null (bark::async-output-space-available ao)))
           (5am:is (= 0 (bark::async-output-block-dropped ao))))
      (stop-async-output ao))))

(5am:test test-async-output-blocking-slots-created
  "Blocking async-output eagerly creates lock and condvar."
  (let ((ao (make-async-output (make-string-output-stream)
                               :capacity 16 :blocking t)))
    (unwind-protect
         (progn
           (5am:is-true (bark::async-output-blocking-p ao))
           (5am:is-true (bark::async-output-space-lock ao))
           (5am:is-true (bark::async-output-space-available ao))
           (5am:is (= 5.0d0 (bark::async-output-block-timeout ao)))
           (5am:is (null (bark::async-output-on-block-timeout ao))))
      (stop-async-output ao))))

(5am:test test-async-output-custom-timeout
  "Custom block-timeout is stored correctly."
  (let ((ao (make-async-output (make-string-output-stream)
                               :capacity 16 :blocking t :block-timeout 10.0)))
    (unwind-protect
         (5am:is (= 10.0d0 (bark::async-output-block-timeout ao)))
      (stop-async-output ao))))

(5am:test test-async-output-nil-timeout
  "nil block-timeout means wait forever."
  (let ((ao (make-async-output (make-string-output-stream)
                               :capacity 16 :blocking t :block-timeout nil)))
    (unwind-protect
         (5am:is (null (bark::async-output-block-timeout ao)))
      (stop-async-output ao))))

(5am:test test-async-output-on-block-timeout-stored
  "on-block-timeout callback is stored in the struct."
  (let* ((cb (lambda (msg stream) (declare (ignore msg stream))))
         (ao (make-async-output (make-string-output-stream)
                                :capacity 16 :blocking t :on-block-timeout cb)))
    (unwind-protect
         (5am:is (eq cb (bark::async-output-on-block-timeout ao)))
      (stop-async-output ao))))

;;; --- blocking push behavior ---

(5am:test test-blocking-push-succeeds-when-space-available
  "Blocking push to a non-full buffer succeeds immediately."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 64 :blocking t)))
    (unwind-protect
         (progn
           (bark::deliver-line ao "hello-blocking")
           (flush-async-output ao)
           (let ((result (get-output-stream-string out)))
             (5am:is (search "hello-blocking" result))))
      (stop-async-output ao))))

(5am:test test-blocking-push-waits-for-space
  "Blocking push blocks when buffer is full, then succeeds after writer drains."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 5.0)))
    (unwind-protect
         (progn
           ;; Fill the buffer
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao)
                                      (format nil "fill-~d" i)))
           ;; Signal writer so it starts draining
           (bt:signal-semaphore (async-output-notify ao))
           ;; This should block briefly, then succeed after writer drains
           (bark::deliver-line ao "waited-msg")
           (flush-async-output ao)
           (let ((result (get-output-stream-string out)))
             (5am:is (search "waited-msg" result))))
      (stop-async-output ao))))

(5am:test test-blocking-push-timeout-fires
  "Blocking push times out and increments block-dropped."
  ;; Use 0.01s timeout — well under the writer's 100ms poll cycle,
  ;; so timeout fires before the writer can drain any entries.
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 0.01)))
    (unwind-protect
         (progn
           ;; Fill the buffer
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao)
                                      (format nil "fill-~d" i)))
           ;; Push should timeout since buffer is full
           (bark::deliver-line ao "timeout-msg")
           (5am:is (plusp (bark::async-output-block-dropped ao))))
      (stop-async-output ao))))

(5am:test test-blocking-push-timeout-callback
  "on-block-timeout is called with message and stream on timeout."
  (let* ((captured-msg nil)
         (captured-stream nil)
         (out (make-string-output-stream))
         (ao (make-async-output out :capacity 16
                                :blocking t
                                :block-timeout 0.01
                                :on-block-timeout
                                (lambda (msg stream)
                                  (setf captured-msg msg
                                        captured-stream stream)))))
    (unwind-protect
         (progn
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao)
                                      (format nil "fill-~d" i)))
           (bark::deliver-line ao "cb-test-msg")
           ;; Timeout fired, callback should have been called
           (5am:is (string= "cb-test-msg" captured-msg))
           (5am:is (eq out captured-stream)))
      (stop-async-output ao))))

(5am:test test-blocking-push-callback-error-caught
  "Errors in on-block-timeout are caught; message is still dropped."
  (let* ((out (make-string-output-stream))
         (err-out (make-string-output-stream))
         (ao (make-async-output out :capacity 16
                                :blocking t
                                :block-timeout 0.01
                                :on-block-timeout
                                (lambda (msg stream)
                                  (declare (ignore msg stream))
                                  (cl:error "callback boom")))))
    (unwind-protect
         (let ((*error-output* err-out))
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao)
                                      (format nil "fill-~d" i)))
           ;; Should not signal — error is caught
           (5am:finishes (bark::deliver-line ao "err-test"))
           (5am:is (plusp (bark::async-output-block-dropped ao)))
           (5am:is (search "callback boom"
                           (get-output-stream-string err-out))))
      (stop-async-output ao))))

(5am:test test-nonblocking-path-unchanged
  "Non-blocking async-output still uses ring-buffer-push with drop counting."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16)))
    (unwind-protect
         (progn
           (dotimes (i 16)
             (ring-buffer-push (async-output-ring ao) (format nil "fill-~d" i)))
           ;; Non-blocking: push drops and increments ring-buffer-dropped
           (bark::deliver-line ao "drop-me")
           (5am:is (plusp (bark::ring-buffer-dropped (async-output-ring ao))))
           ;; block-dropped stays 0
           (5am:is (= 0 (bark::async-output-block-dropped ao))))
      (stop-async-output ao))))

(5am:test test-ring-buffer-dropped-not-inflated-by-blocking
  "Blocking retries never touch ring-buffer-dropped."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 0.01)))
    (unwind-protect
         (progn
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao) (format nil "fill-~d" i)))
           (bark::deliver-line ao "block-or-timeout")
           ;; ring-buffer-dropped must be 0 regardless of outcome
           (5am:is (= 0 (bark::ring-buffer-dropped (async-output-ring ao)))))
      (stop-async-output ao))))

;;; --- tee blocking ---

(defun stop-tee (tee-output)
  "Stop all async outputs in a tee-output. For test cleanup."
  (loop for group across (tee-output-groups tee-output)
        do (loop for dest across (formatter-group-destinations group)
                 do (stop-async-output (destination-async-output dest)))))

(5am:test test-tee-blocking-destination-delivers
  "A blocking destination in a tee delivers messages."
  (let* ((out1 (make-string-output-stream))
         (out2 (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (tee-out (make-tee (list (list :stream out1 :formatter fmt :blocking t)
                                  (list :stream out2 :formatter fmt)))))
    (unwind-protect
         (let ((lgr (make-logger :level :info :formatter fmt :output tee-out)))
           (funcall (bark::logger-info-fn lgr) lgr "tee-blocking-test")
           ;; Flush both destinations
           (loop for group across (tee-output-groups tee-out)
                 do (loop for dest across (formatter-group-destinations group)
                          do (flush-async-output (destination-async-output dest))))
           (let ((r1 (get-output-stream-string out1))
                 (r2 (get-output-stream-string out2)))
             (5am:is (search "tee-blocking-test" r1))
             (5am:is (search "tee-blocking-test" r2))))
      (stop-tee tee-out))))

;;; --- writer broadcast ---

(5am:test test-writer-broadcasts-after-drain
  "Writer broadcasts space-available, unblocking a waiting producer."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 5.0))
         (delivered (bt:make-semaphore :name "delivered")))
    (unwind-protect
         (progn
           ;; Fill the buffer
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao)
                                      (format nil "fill-~d" i)))
           ;; Spawn a producer that will block
           (bt:make-thread
            (lambda ()
              (bark::deliver-line ao "blocked-msg")
              (bt:signal-semaphore delivered))
            :name "blocked-producer")
           ;; Signal writer to drain
           (bt:signal-semaphore (async-output-notify ao))
           ;; Producer should unblock within 2 seconds
           (5am:is-true (bt:wait-on-semaphore delivered :timeout 2.0)
                        "Producer did not unblock after writer drain")
           (flush-async-output ao)
           (5am:is (search "blocked-msg" (get-output-stream-string out))))
      (stop-async-output ao))))

;;; --- stop unblocks producers ---

(5am:test test-stop-unblocks-waiting-producers
  "bark:stop broadcasts on space-available, unblocking all waiting producers."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout nil))
         (threads nil)
         (all-done (bt:make-semaphore :name "all-done")))
    ;; Fill the buffer
    (dotimes (i 16)
      (bark::ring-buffer-offer (async-output-ring ao) (format nil "fill-~d" i)))
    ;; Spawn 4 producers that will block forever (timeout=nil)
    (dotimes (i 4)
      (push (bt:make-thread
             (lambda ()
               (bark::deliver-line ao (format nil "blocked-~d" i))
               (bt:signal-semaphore all-done))
             :name (format nil "blocked-~d" i))
            threads))
    ;; Give producers time to enter wait
    (sleep 0.1)
    ;; Stop should unblock all producers
    (stop-async-output ao)
    ;; All 4 producers must complete within 2 seconds
    (dotimes (i 4)
      (5am:is-true (bt:wait-on-semaphore all-done :timeout 2.0)
                   "Producer ~d not unblocked after stop" i))
    (dolist (th threads) (bt:join-thread th))))

;;; --- bark:start integration ---

(5am:test test-start-with-blocking
  "bark:make-logger with :blocking t creates a blocking async-output."
  (let ((out (make-string-output-stream)))
    (setf *logger* (make-logger :output out :blocking t :block-timeout 10.0))
    (unwind-protect
         (let ((ao (bark::logger-output *logger*)))
           (5am:is (bark::async-output-blocking-p ao))
           (5am:is (= 10.0d0 (bark::async-output-block-timeout ao))))
      (stop *logger*))))

(5am:test test-start-blocking-with-tee-signals-error
  "bark:make-logger with :blocking and a tee-output signals an error."
  (let* ((out1 (make-string-output-stream))
         (out2 (make-string-output-stream))
         (tee-out (make-tee (list (list :stream out1) (list :stream out2)))))
    (unwind-protect
         (5am:signals cl:error
           (make-logger :output tee-out :blocking t))
      (stop-tee tee-out))))

(5am:test test-start-block-timeout-with-tee-signals-error
  "bark:make-logger with :block-timeout and a tee-output signals an error."
  (let* ((out1 (make-string-output-stream))
         (out2 (make-string-output-stream))
         (tee-out (make-tee (list (list :stream out1) (list :stream out2)))))
    (unwind-protect
         (5am:signals cl:error
           (make-logger :output tee-out :block-timeout 1.0))
      (stop-tee tee-out))))

(5am:test test-start-on-block-timeout-with-tee-signals-error
  "bark:make-logger with :on-block-timeout and a tee-output signals an error."
  (let* ((out1 (make-string-output-stream))
         (out2 (make-string-output-stream))
         (tee-out (make-tee (list (list :stream out1) (list :stream out2)))))
    (unwind-protect
         (5am:signals cl:error
           (make-logger :output tee-out :on-block-timeout (lambda (m s) (declare (ignore m s)))))
      (stop-tee tee-out))))

(5am:test test-start-blocking-end-to-end
  "End-to-end: bark:make-logger with :blocking t, log a message, verify delivery."
  (let ((out (make-string-output-stream)))
    (setf *logger* (make-logger :output out :blocking t :formatter (make-json-formatter :timestamp nil)))
    (unwind-protect
         (progn
           (bark:info "blocking-e2e")
           (bark:flush *logger*)
           (5am:is (search "blocking-e2e" (get-output-stream-string out))))
      (stop *logger*))))

;;; --- concurrency tests ---

(5am:test test-concurrent-producers-no-drops
  "N producer threads saturate buffer; all messages eventually delivered, none dropped."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 32 :blocking t :block-timeout 10.0))
         (n-producers 8)
         (msgs-per-producer 50)
         (all-done (bt:make-semaphore :name "all-done"))
         (threads nil))
    (unwind-protect
         (progn
           (dotimes (tid n-producers)
             (let ((id tid))
               (push (bt:make-thread
                      (lambda ()
                        (dotimes (i msgs-per-producer)
                          (bark::deliver-line ao (format nil "t~d-~d" id i)))
                        (bt:signal-semaphore all-done))
                      :name (format nil "producer-~d" id))
                     threads)))
           ;; Wait for all producers (generous timeout)
           (dotimes (i n-producers)
             (5am:is-true (bt:wait-on-semaphore all-done :timeout 30.0)
                          "Producer ~d timed out" i))
           (flush-async-output ao)
           (let* ((result (get-output-stream-string out))
                  (lines (count #\Newline result)))
             ;; All messages delivered
             (5am:is (= (* n-producers msgs-per-producer) lines))
             ;; No drops of either kind
             (5am:is (= 0 (bark::ring-buffer-dropped (async-output-ring ao))))
             (5am:is (= 0 (bark::async-output-block-dropped ao)))))
      (stop-async-output ao)
      (dolist (th threads) (ignore-errors (bt:join-thread th))))))

(5am:test test-concurrent-producers-wake-within-one-drain
  "All N blocked producers wake within one writer drain cycle (no convoy)."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 10.0))
         (n-producers 8)
         (start-barrier (bt:make-semaphore :name "start"))
         (done-times (make-array n-producers :initial-element 0.0d0))
         (threads nil))
    (unwind-protect
         (progn
           ;; Fill the buffer completely
           (dotimes (i 16)
             (bark::ring-buffer-offer (async-output-ring ao) (format nil "fill-~d" i)))
           ;; Spawn producers that will all block
           (dotimes (tid n-producers)
             (let ((id tid))
               (push (bt:make-thread
                      (lambda ()
                        (bt:wait-on-semaphore start-barrier)
                        (bark::deliver-line ao (format nil "wake-~d" id))
                        (setf (aref done-times id) (bark::monotonic-seconds)))
                      :name (format nil "waker-~d" id))
                     threads)))
           ;; Release all producers simultaneously
           (dotimes (i n-producers)
             (bt:signal-semaphore start-barrier))
           ;; Give producers time to enter wait
           (sleep 0.2)
           ;; Signal writer to drain (makes 16 slots available)
           (bt:signal-semaphore (async-output-notify ao))
           ;; Wait for all to complete
           (dolist (th threads) (bt:join-thread th))
           ;; All should have completed within ~1s of each other (one drain cycle)
           (let* ((min-t (reduce #'min done-times))
                  (max-t (reduce #'max done-times))
                  (spread (- max-t min-t)))
             (5am:is (< spread 1.0)
                     "Wakeup spread was ~Fs (expected < 1s)" spread)))
      (stop-async-output ao))))

(5am:test test-concurrent-stop-with-blocked-producers
  "bark:stop with N blocked producers unblocks all promptly."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout nil))
         (n-producers 4)
         (all-done (bt:make-semaphore :name "all-done"))
         (threads nil))
    ;; Fill the buffer
    (dotimes (i 16)
      (bark::ring-buffer-offer (async-output-ring ao) (format nil "fill-~d" i)))
    ;; Spawn producers that block forever
    (dotimes (tid n-producers)
      (push (bt:make-thread
             (lambda ()
               (bark::deliver-line ao "blocked")
               (bt:signal-semaphore all-done))
             :name (format nil "stuck-~d" tid))
            threads))
    ;; Give them time to enter wait
    (sleep 0.2)
    ;; Stop should unblock them all
    (let ((t0 (bark::monotonic-seconds)))
      (stop-async-output ao)
      (dotimes (i n-producers)
        (5am:is-true (bt:wait-on-semaphore all-done :timeout 2.0)
                     "Producer ~d not unblocked after stop" i))
      (let ((elapsed (- (bark::monotonic-seconds) t0)))
        (5am:is (< elapsed 2.0)
                "Stop took ~Fs (expected < 2s)" elapsed)))
    (dolist (th threads) (bt:join-thread th))))

(5am:test test-tee-mixed-blocking-nonblocking
  "Mixed tee: non-blocking destination unaffected when blocking destination is saturated."
  (let* ((out-blocking (make-string-output-stream))
         (out-nonblocking (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         (tee-out (make-tee (list (list :stream out-blocking :formatter fmt
                                        :blocking t :block-timeout 5.0)
                                  (list :stream out-nonblocking :formatter fmt)))))
    (unwind-protect
         (let ((lgr (make-logger :level :info :formatter fmt :output tee-out)))
           ;; Log several messages
           (dotimes (i 5)
             (funcall (bark::logger-info-fn lgr) lgr (format nil "mixed-~d" i)))
           ;; Flush all destinations
           (loop for group across (tee-output-groups tee-out)
                 do (loop for dest across (formatter-group-destinations group)
                          do (flush-async-output (destination-async-output dest))))
           ;; Both destinations should have received all messages
           (let ((nb-result (get-output-stream-string out-nonblocking))
                 (b-result (get-output-stream-string out-blocking)))
             (dotimes (i 5)
               (5am:is (search (format nil "mixed-~d" i) nb-result))
               (5am:is (search (format nil "mixed-~d" i) b-result)))))
      (stop-tee tee-out))))

(5am:test test-tee-partial-delivery-on-timeout
  "Partial delivery: non-blocking destination receives, blocking destination times out and drops."
  (let* ((out-nonblocking (make-string-output-stream))
         (out-blocking (make-string-output-stream))
         (fmt (make-json-formatter :timestamp nil))
         ;; Use different formatters so destinations are in separate groups
         ;; (avoids shared-formatter grouping complications with index order)
         (fmt2 (make-json-formatter :timestamp nil))
         (tee-out (make-tee (list (list :stream out-nonblocking :formatter fmt)
                                  (list :stream out-blocking :formatter fmt2
                                        :blocking t :block-timeout 0.01
                                        :capacity 16)))))
    (unwind-protect
         (progn
           ;; Fill the blocking destination's buffer (capacity=16)
           (let ((blocking-ao
                   (destination-async-output
                    (aref (formatter-group-destinations
                           (aref (tee-output-groups tee-out) 1))
                          0))))
             (dotimes (i 16)
               (bark::ring-buffer-offer (async-output-ring blocking-ao)
                                         (format nil "fill-~d" i))))
           ;; Log through the tee — non-blocking gets it, blocking times out
           (let ((lgr (make-logger :level :info :formatter fmt :output tee-out)))
             (funcall (bark::logger-info-fn lgr) lgr "partial-test"))
           ;; Flush non-blocking destination
           (let ((nb-ao (destination-async-output
                         (aref (formatter-group-destinations
                                (aref (tee-output-groups tee-out) 0))
                               0))))
             (flush-async-output nb-ao))
           ;; Non-blocking destination received the message
           (5am:is (search "partial-test" (get-output-stream-string out-nonblocking)))
           ;; Blocking destination dropped it (block-dropped > 0)
           (let ((blocking-ao
                   (destination-async-output
                    (aref (formatter-group-destinations
                           (aref (tee-output-groups tee-out) 1))
                          0))))
             (5am:is (plusp (bark::async-output-block-dropped blocking-ao)))))
      (stop-tee tee-out))))

;;; --- broadcast-under-lock tests ---

(5am:test test-broadcast-under-lock-no-lost-wakeup
  "Stress test: N producers rapidly blocking and unblocking.
   Without broadcast-under-lock, some producers could miss wakeups and stall.
   All messages must be delivered within the timeout."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout 5.0))
         (n-producers 4)
         (msgs-per-producer 100)
         (all-done (bt:make-semaphore :name "all-done"))
         (threads nil))
    (unwind-protect
         (progn
           (dotimes (tid n-producers)
             (let ((id tid))
               (push (bt:make-thread
                      (lambda ()
                        (dotimes (i msgs-per-producer)
                          (bark::deliver-line ao (format nil "p~d-~d" id i)))
                        (bt:signal-semaphore all-done))
                      :name (format nil "stress-~d" id))
                     threads)))
           (dotimes (i n-producers)
             (5am:is-true (bt:wait-on-semaphore all-done :timeout 10.0)
                          "Producer ~d timed out — possible lost wakeup" i))
           (flush-async-output ao)
           (let* ((result (get-output-stream-string out))
                  (lines (count #\Newline result)))
             (5am:is (= (* n-producers msgs-per-producer) lines)
                     "Expected ~d lines, got ~d" (* n-producers msgs-per-producer) lines)))
      (stop-async-output ao)
      (dolist (th threads) (ignore-errors (bt:join-thread th))))))

(5am:test test-stop-wakes-producers-before-join
  "Stop wakes blocked producers promptly (before joining the writer thread).
   Producers must complete within 1 second of stop being called."
  (let* ((out (make-string-output-stream))
         (ao (make-async-output out :capacity 16 :blocking t :block-timeout nil))
         (n-producers 4)
         (all-done (bt:make-semaphore :name "all-done"))
         (threads nil))
    ;; Fill the buffer
    (dotimes (i 16)
      (bark::ring-buffer-offer (async-output-ring ao) (format nil "fill-~d" i)))
    ;; Spawn producers that will block indefinitely (timeout=nil)
    (dotimes (tid n-producers)
      (push (bt:make-thread
             (lambda ()
               (bark::deliver-line ao "blocked")
               (bt:signal-semaphore all-done))
             :name (format nil "stop-wake-~d" tid))
            threads))
    ;; Give producers time to enter condition-wait
    (sleep 0.1)
    ;; Stop should wake all producers within ~1 second (not waiting for writer timeout)
    (let ((t0 (bark::monotonic-seconds)))
      (stop-async-output ao)
      (dotimes (i n-producers)
        (5am:is-true (bt:wait-on-semaphore all-done :timeout 2.0)
                     "Producer ~d not unblocked by stop" i))
      (let ((elapsed (- (bark::monotonic-seconds) t0)))
        (5am:is (< elapsed 1.0)
                "Stop took ~Fs — expected < 1s (broadcast before join)" elapsed)))
    (dolist (th threads) (bt:join-thread th))))
