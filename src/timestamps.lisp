;;; src/timestamps.lisp — Timestamp infrastructure for formatters

(in-package #:bark)

;;; --- Timestamps ---
(defvar *override-timestamp* nil
  "When non-nil, formatters use this value instead of the wall clock.
   Internal — used by with-log-buffer for replay.")

(declaim (ftype (function nil (values integer &optional)) get-unix-timestamp-ms))

(defun get-unix-timestamp-ms ()
  "Return current Unix timestamp in milliseconds, or *override-timestamp* if bound."
  (or *override-timestamp*
      #+sbcl
      (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
        (+ (* sec 1000) (floor usec 1000)))
      #-sbcl
      (let ((now (local-time:now)))
        (+ (* (local-time:timestamp-to-unix now) 1000)
           (floor (local-time:nsec-of now) 1000000)))))

(declaim (ftype (function nil (values integer &optional)) current-log-timestamp-ms))

(defun current-log-timestamp-ms ()
  "Return the effective log timestamp in milliseconds since Unix epoch.
Custom formatters MUST call this instead of computing their own timestamp.
During with-log-buffer replay, this returns the original log-call timestamp;
a raw clock read would incorrectly return the flush time instead."
  (get-unix-timestamp-ms))

(defun emit-timestamp (format stream)
  "Emit a timestamp to STREAM in the given FORMAT.
   :unix-ms emits milliseconds since epoch as an integer.
   :iso8601 emits a \"YYYY-MM-DDTHH:MM:SS.mmmZ\" string."
  (ecase format
    (:unix-ms (princ (get-unix-timestamp-ms) stream))
    (:iso8601
     (let ((ms (get-unix-timestamp-ms)))
       (multiple-value-bind (sec remainder) (floor ms 1000)
         (multiple-value-bind (s min h day month year)
             (decode-universal-time (+ sec 2208988800) 0)
           (format stream "\"~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.~3,'0dZ\""
                   year month day h min s remainder)))))))
