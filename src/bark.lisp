;;; src/bark.lisp — BARK package definitions (auto-generated)
(in-package "BARK")

;;; --- Levels ---

(defparameter *level-colors*
  #(nil
    "36"    ; trace = cyan
    "34"    ; debug = blue
    "32"    ; info  = green
    "33"    ; warn  = yellow
    "31"    ; error = red
    "35")   ; fatal = magenta
  "ANSI color codes indexed by (/ level 10).")

(defparameter *level-names* #(nil "trace" "debug" "info" "warn" "error" "fatal") "Vector of level name strings indexed by (/ level 10).")

(defparameter *level-prefixes* #("{\"level\":10" "{\"level\":20" "{\"level\":30" "{\"level\":40" "{\"level\":50" "{\"level\":60") "Pre-computed JSON level prefixes indexed by (1- (/ level 10)).")

(defconstant +debug+ 20 "Debug log level.")

(defconstant +error+ 50 "Error log level.")

(defconstant +fatal+ 60 "Fatal log level.")

(defconstant +info+ 30 "Info log level.")

(defconstant +trace+ 10 "Trace log level.")

(defconstant +warn+ 40 "Warning log level.")

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

(declaim (ftype (function (fixnum) (values simple-string &optional)) level-name))

(defun level-name (level)
  "Convert a numeric level to its name string."
  (declare (type fixnum level))
  (let ((idx (truncate level 10)))
    (if (and (>= idx 1) (<= idx 6))
        (svref *level-names* idx)
        "unknown")))

;;; --- Serialization Limits ---

(defvar *max-emit-depth* 4
  "Maximum nesting depth for collections in emit-json-value.
   At depth 0, collections become <type> placeholders.")

(defvar *max-emit-length* 20
  "Maximum number of elements emitted per collection.
   Excess elements are replaced by a single \"...\" sentinel.")

;;; --- JSON Output ---

(declaim (ftype (function (simple-string stream) (values null &optional)) write-json-escaped-string))

(defun write-json-escaped-string (string stream)
  "Write STRING to STREAM with JSON escaping."
  (declare (optimize (speed 3) (safety 1))
           (type simple-string string))
  (loop for c of-type character across string do
    (case c
      (#\" (write-string "\\\"" stream))
      (#\\ (write-string "\\\\" stream))
      (#\Newline (write-string "\\n" stream))
      (#\Return (write-string "\\r" stream))
      (#\Tab (write-string "\\t" stream))
      (t (if (< (char-code c) 32)
             (format stream "\\u~4,'0X" (char-code c))
             (write-char c stream))))))

(defun emit-type-placeholder (stream value)
  "Write a \"<type>\" placeholder for VALUE to STREAM as a JSON string."
  (let ((type-name (string-downcase (princ-to-string (type-of value)))))
    (write-char #\" stream)
    (write-char #\< stream)
    (write-string type-name stream)
    (write-char #\> stream)
    (write-char #\" stream)))

(defun emit-json-key (stream key)
  "Write KEY as a JSON object key to STREAM."
  (write-string ",\"" stream)
  (typecase key
    (string (write-json-escaped-string key stream))
    (symbol (write-string (string-downcase (symbol-name key)) stream)))
  (write-string "\":" stream))

(defun coerce-hash-key (k)
  "Coerce hash-table key K to a string for JSON output."
  (typecase k
    (string k)
    (symbol (string-downcase (symbol-name k)))
    (pathname (namestring k))
    (t (string-downcase (princ-to-string (type-of k))))))

(defun emit-json-value (stream value &optional (depth *max-emit-depth*))
  "Write VALUE as JSON to STREAM.  Collections recurse up to DEPTH levels."
  (typecase value
    (string
     (write-char #\" stream)
     (write-json-escaped-string value stream)
     (write-char #\" stream))
    (character
     (write-char #\" stream)
     (write-json-escaped-string (string value) stream)
     (write-char #\" stream))
    (integer (princ value stream))
    (float (princ value stream))
    (ratio (format stream "~F" (coerce value 'double-float)))
    ((eql t) (write-string "true" stream))
    (null (write-string "null" stream))
    (symbol
     (write-char #\" stream)
     (write-string (string-downcase (symbol-name value)) stream)
     (write-char #\" stream))
    (pathname
     (write-char #\" stream)
     (write-json-escaped-string (namestring value) stream)
     (write-char #\" stream))
    (cons
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (progn
           (write-char #\[ stream)
           (loop for cell on value
                 for i from 0
                 for first = t then nil
                 when (>= i *max-emit-length*)
                   do (write-string ",\"...\"" stream)
                      (loop-finish)
                 unless first do (write-char #\, stream)
                 do (emit-json-value stream (car cell) (1- depth))
                 when (and (cdr cell) (atom (cdr cell)))
                   do (write-char #\, stream)
                      (emit-json-value stream (cdr cell) (1- depth))
                      (loop-finish))
           (write-char #\] stream))))
    (vector
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (let ((len (length value)))
           (write-char #\[ stream)
           (loop for i from 0 below len
                 when (>= i *max-emit-length*)
                   do (write-string ",\"...\"" stream)
                      (loop-finish)
                 when (plusp i) do (write-char #\, stream)
                 do (emit-json-value stream (aref value i) (1- depth)))
           (write-char #\] stream))))
    (hash-table
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (let ((first t)
               (count 0))
           (write-char #\{ stream)
           (maphash (lambda (k v)
                      (when (>= count *max-emit-length*)
                        (write-string ",\"...\":\"...\"" stream)
                        (return-from emit-json-value))
                      (if first (setf first nil) (write-char #\, stream))
                      (write-char #\" stream)
                      (write-json-escaped-string (coerce-hash-key k) stream)
                      (write-string "\":" stream)
                      (emit-json-value stream v (1- depth))
                      (incf count))
                    value)
           (write-char #\} stream))))
    (t (emit-type-placeholder stream value))))

(defun emit-json-fields (stream fields)
  "Write a plist of FIELDS as JSON key-value pairs to STREAM."
  (loop for (k v) on fields by #'cddr do
    (emit-json-key stream k)
    (emit-json-value stream v)))

(defun emit-context-fields (stream context)
  "Write dynamic context fields (alist) as JSON key-value pairs to STREAM."
  (dolist (pair context)
    (emit-json-key stream (car pair))
    (emit-json-value stream (cdr pair))))

(declaim (ftype (function (list) (values simple-string &optional)) serialize-bindings))

(defun serialize-bindings (bindings)
  "Pre-serialize BINDINGS plist to a JSON fragment string."
  (with-output-to-string (s)
    (emit-json-fields s bindings)))

;;; --- Logfmt Output ---

(defun emit-logfmt-key (stream key)
  "Write a logfmt key to STREAM."
  (typecase key
    (string (write-string key stream))
    (symbol (write-string (string-downcase (symbol-name key)) stream))))

(defun logfmt-write-bare-or-quoted (stream string)
  "Write STRING to STREAM, quoting if it contains space, quote, or equals."
  (if (find-if (lambda (c) (or (char= c #\Space) (char= c #\") (char= c #\=))) string)
      (progn (write-char #\" stream) (write-string string stream) (write-char #\" stream))
      (write-string string stream)))

(defun emit-logfmt-value (stream value)
  "Write VALUE as a logfmt value to STREAM.  Scalars only."
  (typecase value
    (string (logfmt-write-bare-or-quoted stream value))
    (character (write-string (string value) stream))
    (integer (princ value stream))
    (float (princ value stream))
    (ratio (format stream "~F" (coerce value 'double-float)))
    (null (write-string "null" stream))
    (symbol (write-string (string-downcase (symbol-name value)) stream))
    (pathname (logfmt-write-bare-or-quoted stream (namestring value)))
    (t (let ((type-name (string-downcase (princ-to-string (type-of value)))))
         (write-char #\< stream)
         (write-string type-name stream)
         (write-char #\> stream)))))

;;; --- Timestamps ---

(declaim (ftype (function nil (values integer &optional)) get-unix-timestamp-ms))

(defun get-unix-timestamp-ms ()
  "Return current Unix timestamp in milliseconds."
  #+sbcl
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000) (floor usec 1000)))
  #-sbcl
  (let ((now (local-time:now)))
    (+ (* (local-time:timestamp-to-unix now) 1000)
       (floor (local-time:nsec-of now) 1000000))))

;;; --- Formatters ---

(declaim (ftype (function (fixnum simple-string list list string list) (values simple-string &optional)) json-formatter))

(defun json-formatter (level chindings raw-bindings context message fields)
  "Format a log entry as a JSON line."
  (declare (optimize (speed 3) (safety 1)))
  (declare (ignore raw-bindings))
  (with-output-to-string (s)
    (write-string (svref *level-prefixes* (1- (floor level 10))) s)
    (write-string ",\"ts\":" s)
    (princ (get-unix-timestamp-ms) s)
    (write-string chindings s)
    (emit-context-fields s context)
    (emit-json-fields s fields)
    (write-string ",\"msg\":\"" s)
    (write-json-escaped-string message s)
    (write-string "\"}" s)))

(declaim (ftype (function (fixnum simple-string list list string list) (values simple-string &optional)) logfmt-formatter))

(defun logfmt-formatter (level chindings raw-bindings context message fields)
  "Format a log entry as logfmt (key=value pairs)."
  (declare (ignore chindings))
  (with-output-to-string (s)
    (write-string "level=" s)
    (write-string (level-name level) s)
    (write-string " ts=" s)
    (princ (get-unix-timestamp-ms) s)
    ;; Child logger bindings from raw-bindings plist
    (loop for (k v) on raw-bindings by #'cddr do
      (write-char #\Space s)
      (emit-logfmt-key s k)
      (if (eq v t)
          nil ; bare key = true in logfmt
          (progn (write-char #\= s)
                 (emit-logfmt-value s v))))
    ;; Dynamic context
    (dolist (pair context)
      (write-char #\Space s)
      (emit-logfmt-key s (car pair))
      (if (eq (cdr pair) t)
          nil
          (progn (write-char #\= s)
                 (emit-logfmt-value s (cdr pair)))))
    ;; Per-call fields
    (loop for (k v) on fields by #'cddr do
      (write-char #\Space s)
      (emit-logfmt-key s k)
      (if (eq v t)
          nil
          (progn (write-char #\= s)
                 (emit-logfmt-value s v))))
    (write-string " msg=" s)
    (emit-logfmt-value s message)))

(declaim (ftype (function (fixnum simple-string list list string list) (values simple-string &optional)) pretty-formatter))

(defun pretty-formatter (level chindings raw-bindings context message fields)
  "Format a log entry with ANSI colors for REPL/development use."
  (declare (ignore chindings))
  (with-output-to-string (s)
    (let* ((level-idx (floor level 10))
           (color (svref *level-colors* level-idx))
           (name (level-name level)))
      (format s "~c[~am~5a~c[0m " #\Esc color (string-upcase name) #\Esc)
      (write-string message s)
      ;; Child logger bindings
      (loop for (k v) on raw-bindings by #'cddr do
        (format s " ~c[2m~a~c[0m=" #\Esc
                (typecase k (string k) (symbol (string-downcase (symbol-name k))))
                #\Esc)
        (princ v s))
      ;; Context fields
      (dolist (pair context)
        (format s " ~c[2m~a~c[0m=" #\Esc
                (typecase (car pair) (string (car pair)) (symbol (string-downcase (symbol-name (car pair)))))
                #\Esc)
        (princ (cdr pair) s))
      ;; Per-call fields
      (loop for (k v) on fields by #'cddr do
        (format s " ~c[2m~a~c[0m=" #\Esc
                (typecase k (string k) (symbol (string-downcase (symbol-name k))))
                #\Esc)
        (princ v s)))))

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
  (let* ((actual (max 16 (expt 2 (ceiling (log capacity 2)))))
         (slots (make-array actual :initial-element nil)))
    (%make-ring-buffer :slots slots :mask (1- actual))))

(defun ring-buffer-pop (rb)
  "Pop the next value from the ring buffer. Returns NIL if empty. Single-consumer only."
  (declare (optimize (speed 3) (safety 1)))
  (let ((tail (ring-buffer-tail rb))
        (head (ring-buffer-head rb)))
    (when (< tail head)
      (let* ((idx (logand tail (ring-buffer-mask rb)))
             (val (svref (ring-buffer-slots rb) idx)))
        (loop while (null val) do
          #+sbcl (sb-ext:spin-loop-hint)
          (setf val (svref (ring-buffer-slots rb) idx)))
        (setf (svref (ring-buffer-slots rb) idx) nil)
        (atomics:atomic-incf (ring-buffer-tail rb))
        val))))

(defun ring-buffer-push (rb value)
  "Push VALUE into the ring buffer. Returns T on success, NIL if full (increments drop counter)."
  (declare (optimize (speed 3) (safety 1)))
  (loop
    (let* ((head (ring-buffer-head rb))
           (tail (ring-buffer-tail rb))
           (size (the fixnum (- head tail))))
      (when (>= size (1+ (ring-buffer-mask rb)))
        (atomics:atomic-incf (ring-buffer-dropped rb))
        (return nil))
      (when (atomics:cas (ring-buffer-head rb) head (1+ head))
        (setf (svref (ring-buffer-slots rb) (logand head (ring-buffer-mask rb))) value)
        (return t)))))

(defun ring-buffer-drain (rb)
  "Drain all available values from the ring buffer into a list. Single-consumer only."
  (loop for val = (ring-buffer-pop rb) while val collect val))

;;; --- Async Output ---

(defun default-on-drop (count)
  "Default drop handler. Returns a JSON warning line."
  (format nil "{\"level\":40,\"msg\":\"bark: dropped ~d log messages (output too slow)\"}" count))

(defstruct (async-output (:constructor %make-async-output))
  "Writer thread + ring buffer for async log delivery."
  (ring      nil :type (or null ring-buffer))
  (thread    nil :type (or null bt:thread))
  (stream    nil :type (or null stream))
  (running   nil :type boolean)
  (on-drop   nil :type (or null function))
  (on-error  nil :type (or null function))
  (notify    nil :type t)
  (flush-ack nil :type t))

(declaim (ftype (function (t &key (:capacity fixnum) (:on-drop (or null function)) (:on-error (or null function)))
                          (values async-output &optional)) make-async-output))

(defun make-async-output (stream &key (capacity 8192) (on-drop #'default-on-drop) on-error)
  "Create an async output that writes to STREAM via a background thread."
  (let* ((notify (bt:make-semaphore :name "bark-notify"))
         (ao (%make-async-output
              :ring (make-ring-buffer capacity)
              :stream stream
              :running t
              :on-drop on-drop
              :on-error on-error
              :notify notify)))
    (setf (async-output-thread ao)
          (bt:make-thread (lambda () (writer-loop ao))
                          :name "bark-writer"))
    ao))

(declaim (ftype (function ((or async-output null)) (values null &optional)) flush-async-output))

(defun flush-async-output (async-output)
  "Flush the async writer. Blocks until current queue is drained."
  (when (and async-output (async-output-running async-output))
    (let ((ack (bt:make-semaphore :name "bark-flush-ack")))
      (setf (async-output-flush-ack async-output) ack)
      (bt:signal-semaphore (async-output-notify async-output))
      (bt:wait-on-semaphore ack :timeout 5.0)))
  nil)

(declaim (ftype (function (t) (values null &optional)) stop-async-output))

(defun stop-async-output (async-output)
  "Stop the async writer thread, draining all pending messages first."
  (when (and async-output (async-output-running async-output))
    (flush-async-output async-output)
    (setf (async-output-running async-output) nil)
    (bt:signal-semaphore (async-output-notify async-output))
    (when (async-output-thread async-output)
      (bt:join-thread (async-output-thread async-output)))
    (let ((ring (async-output-ring async-output))
          (stream (async-output-stream async-output)))
      (loop for line = (ring-buffer-pop ring) while line do
        (write-string line stream)
        (terpri stream))
      (force-output stream))))

(declaim (ftype (function (async-output) (values null &optional)) writer-loop))

(defun writer-loop (async-output)
  "Main loop for the async writer thread. Batch-drains the ring buffer."
  (let ((ring   (async-output-ring async-output))
        (stream (async-output-stream async-output))
        (notify (async-output-notify async-output)))
    (handler-case
        (loop while (async-output-running async-output) do
          (bt:wait-on-semaphore notify :timeout 0.1)
          (loop for line = (ring-buffer-pop ring) while line do
            (write-string line stream)
            (terpri stream))
          (force-output stream)
          (let ((dropped (ring-buffer-dropped ring)))
            (when (plusp dropped)
              (loop for old = (ring-buffer-dropped ring)
                    until (atomics:cas (ring-buffer-dropped ring) old 0))
              (let ((on-drop (async-output-on-drop async-output)))
                (when on-drop
                  (let ((warning (funcall on-drop dropped)))
                    (when warning
                      (write-string warning stream)
                      (terpri stream)
                      (force-output stream)))))))
          (let ((ack (async-output-flush-ack async-output)))
            (when ack
              (setf (async-output-flush-ack async-output) nil)
              (bt:signal-semaphore ack))))
      (cl:error (e)
        (format *error-output* "bark writer-loop error: ~a~%" e)
        (force-output *error-output*)))))

;;; --- Logger ---

(defun noop (logger message &rest fields)
  "No-op log function for disabled levels."
  (declare (ignore logger message fields))
  (values))

(defstruct (logger (:constructor %make-logger))
  "A bark logger instance."
  (name         ""    :type string :read-only t)
  (level        30    :type fixnum)
  (chindings    ""    :type string :read-only t)
  (raw-bindings nil   :type list :read-only t)
  (formatter    nil   :type (or null function))
  (output       nil   :type t)
  (sampler      nil   :type (or null simple-vector))
  (trace-fn     #'noop :type function)
  (debug-fn     #'noop :type function)
  (info-fn      #'noop :type function)
  (warn-fn      #'noop :type function)
  (error-fn     #'noop :type function)
  (fatal-fn     #'noop :type function))

(defvar *logger* nil "The current bark logger.")

(defvar *log-context* nil "Dynamic context bindings for the current log scope.")

(declaim (ftype (function (fixnum) (values function &optional)) make-log-fn))

(defun make-log-fn (level-value)
  "Create a log function for LEVEL-VALUE."
  (declare (optimize (speed 3) (safety 1))
           (type fixnum level-value))
  (let ((level-index (floor level-value 10)))
    (lambda (lgr message &rest fields)
      (declare (ignorable lgr) (dynamic-extent fields))
      (block log-fn
        (let ((sampler (logger-sampler lgr)))
          (when (and sampler (aref sampler level-index))
            (let ((sample-state (aref sampler level-index)))
              (when (consp sample-state)
                (let ((count (the fixnum (incf (the fixnum (cdr sample-state)))))
                      (rate (the fixnum (car sample-state))))
                  (unless (zerop (the fixnum (mod count rate)))
                    (return-from log-fn (values))))))))
        (let* ((formatter (the function (logger-formatter lgr)))
               (line (funcall formatter
                              level-value
                              (logger-chindings lgr)
                              (logger-raw-bindings lgr)
                              *log-context*
                              message
                              fields))
               (output (logger-output lgr)))
          (when output
            (if (async-output-p output)
                (progn
                  (ring-buffer-push (async-output-ring output) line)
                  (bt:signal-semaphore (async-output-notify output)))
                (etypecase output
                  (stream (write-string line output) (terpri output) (force-output output))
                  (function (funcall output line))))))
        (values)))))

(declaim (ftype (function (&key (:name string) (:level (or fixnum keyword)) (:formatter function) (:output t))
 (values logger &optional)) make-logger))

(defun make-logger (&key (name "") (level :info) (formatter #'json-formatter) output)
  "Create a new logger."
  (let* ((chindings (if (string= name "")
                        ""
                        (with-output-to-string (s)
                          (emit-json-key s "name")
                          (emit-json-value s name))))
         (raw-bindings (if (string= name "")
                           nil
                           (list :name name)))
         (lgr (%make-logger
               :name name
               :chindings chindings
               :raw-bindings raw-bindings
               :formatter formatter
               :output output)))
    (set-level lgr level)
    lgr))

(declaim (ftype (function (logger (or fixnum keyword)) *) set-level))

(defun set-level (logger level)
  "Set the minimum log level for LOGGER. Swaps function slots."
  (let ((level-val (etypecase level
                     (fixnum level)
                     (keyword (level-from-keyword level)))))
    (setf (logger-level logger) level-val)
    (setf (logger-trace-fn logger) (if (< +trace+ level-val) #'noop (make-log-fn +trace+)))
    (setf (logger-debug-fn logger) (if (< +debug+ level-val) #'noop (make-log-fn +debug+)))
    (setf (logger-info-fn logger)  (if (< +info+  level-val) #'noop (make-log-fn +info+)))
    (setf (logger-warn-fn logger)  (if (< +warn+  level-val) #'noop (make-log-fn +warn+)))
    (setf (logger-error-fn logger) (if (< +error+ level-val) #'noop (make-log-fn +error+)))
    (setf (logger-fatal-fn logger) (if (< +fatal+ level-val) #'noop (make-log-fn +fatal+)))
    (values)))

(declaim (ftype (function (logger (or fixnum keyword) fixnum) (values t &optional)) set-sampling))

(defun set-sampling (logger level rate)
  "Set sampling for LEVEL to 1-in-RATE on LOGGER."
  (let ((level-val (etypecase level
                     (fixnum level)
                     (keyword (level-from-keyword level))))
        (sampler (or (logger-sampler logger)
                     (make-array 7 :initial-element nil))))
    (setf (aref sampler (floor level-val 10)) (cons rate (1- rate)))
    (setf (logger-sampler logger) sampler)))

(declaim (ftype (function (logger &rest t) (values logger &rest t)) child))

(defun child (parent &rest bindings)
  "Create a child logger from PARENT with additional BINDINGS pre-serialized."
  (let* ((new-chindings (concatenate 'string
                                      (logger-chindings parent)
                                      (serialize-bindings bindings)))
         (new-raw-bindings (append (logger-raw-bindings parent) bindings))
         (child (%make-logger
                 :name (logger-name parent)
                 :level (logger-level parent)
                 :chindings new-chindings
                 :raw-bindings new-raw-bindings
                 :formatter (logger-formatter parent)
                 :output (logger-output parent)
                 :sampler (logger-sampler parent))))
    (set-level child (logger-level parent))
    child))

(defmethod print-object ((ao async-output) stream)
  "Print async-output without descending into stream/thread slots."
  (print-unreadable-object (ao stream :type t :identity t)
    (let ((ring (async-output-ring ao)))
      (format stream "~:[stopped~;running~] ~D pending ~D dropped"
              (async-output-running ao)
              (if ring (- (ring-buffer-head ring) (ring-buffer-tail ring)) 0)
              (if ring (ring-buffer-dropped ring) 0)))))

(defmethod print-object ((lgr logger) stream)
  "Print logger showing name and level."
  (print-unreadable-object (lgr stream :type t :identity t)
    (format stream "~A level=~A" (logger-name lgr) (level-name (logger-level lgr)))))

;;; --- Lifecycle ---

(declaim (ftype (function (&key (:stream stream) (:level (or fixnum keyword)) (:formatter function)
                                (:name string) (:capacity fixnum) (:on-drop function) (:context list))
                          (values logger &optional)) start))

(defun start (&key (stream *error-output*) (level :info) (formatter #'json-formatter)
                   (name "") (capacity 8192) (on-drop #'default-on-drop) context)
  "Start the global logger with an async writer thread.
CONTEXT, when provided, is a plist of static context fields (e.g. :role \"broker\" :pid 123).
The root logger is automatically wrapped in a child with these fields."
  (when (and *logger* (logger-output *logger*) (async-output-p (logger-output *logger*)))
    (stop))
  (let* ((ao (make-async-output stream :capacity capacity :on-drop on-drop))
         (chindings (if (string= name "")
                        ""
                        (with-output-to-string (s)
                          (emit-json-key s "name")
                          (emit-json-value s name))))
         (raw-bindings (if (string= name "")
                           nil
                           (list :name name)))
         (lgr (%make-logger
               :name name
               :chindings chindings
               :raw-bindings raw-bindings
               :formatter formatter
               :output ao)))
    (set-level lgr level)
    (setf *logger* (if context (apply #'child lgr context) lgr))))

(declaim (ftype (function nil (values null &optional)) stop))

(defun stop ()
  "Flush and stop the global logger's writer thread."
  (when *logger*
    (let ((output (logger-output *logger*)))
      (when (and output (async-output-p output))
        (stop-async-output output)))
    (setf *logger* nil)))

;;; --- Context ---

(defmacro with-context ((&rest pairs) &body body)
  "Bind dynamic log context fields for the duration of BODY."
  `(let ((*log-context* (list* ,@(loop for (k v) on pairs by #'cddr
                                       collect `(cons ,k ,v))
                               *log-context*)))
     ,@body))

;;; --- Utilities ---

(defmacro with-captured-logs ((&optional (var 'logs) (formatter '#'json-formatter)) &body body)
  "Execute BODY with a test logger that captures log output.
   Binds VAR to a function that returns the list of logged strings.
   FORMATTER defaults to #'json-formatter but can be any formatter function."
  `(multiple-value-bind (collector results-fn) (make-list-collector)
     (let* ((*logger* (%make-logger
                       :name "test"
                       :formatter ,formatter
                       :output collector)))
       (set-level *logger* :trace)
       (let ((,var results-fn))
         ,@body))))

(defvar *compile-time-max-level* 0
  "When positive, log calls for levels below this are eliminated at compile time.")

(declaim (ftype (function nil (values function function &optional)) make-list-collector))

(defun make-list-collector ()
  "Create a list-collecting output function and its result accessor.
   Returns (values collector-fn get-results-fn)."
  (let ((results nil))
    (values
     (lambda (line) (push line results))
     (lambda () (nreverse results)))))

;;; --- Convenience API ---

(defmacro debug (message &rest fields)
  "Log MESSAGE at debug level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-debug-fn *logger*) *logger* ,message ,@fields)))

(defmacro error (message &rest fields)
  "Log MESSAGE at error level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-error-fn *logger*) *logger* ,message ,@fields)))

(defmacro fatal (message &rest fields)
  "Log MESSAGE at fatal level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-fatal-fn *logger*) *logger* ,message ,@fields)))

(defmacro info (message &rest fields)
  "Log MESSAGE at info level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-info-fn *logger*) *logger* ,message ,@fields)))

(defmacro trace (message &rest fields)
  "Log MESSAGE at trace level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-trace-fn *logger*) *logger* ,message ,@fields)))

(defmacro warn (message &rest fields)
  "Log MESSAGE at warn level to *LOGGER*. No-op when *LOGGER* is nil."
  `(when *logger*
     (funcall (logger-warn-fn *logger*) *logger* ,message ,@fields)))
