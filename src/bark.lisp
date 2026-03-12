;;; src/bark.lisp — BARK package definitions

(in-package #:bark)

;;; --- Levels ---

(defconstant +trace+ 10 "Trace log level.")

(defconstant +debug+ 20 "Debug log level.")

(defconstant +info+ 30 "Info log level.")

(defconstant +warn+ 40 "Warning log level.")

(defconstant +error+ 50 "Error log level.")

(defconstant +fatal+ 60 "Fatal log level.")

(defconstant +level-step+ 10 "Spacing between consecutive log levels.")

(defconstant +level-slot-count+ (1+ (/ +fatal+ +level-step+))
  "Number of level index slots (0 through fatal).")

(defparameter *level-colors*
  #(nil
    "36"    ; trace = cyan
    "34"    ; debug = blue
    "32"    ; info  = green
    "33"    ; warn  = yellow
    "31"    ; error = red
    "35")   ; fatal = magenta
  "ANSI color codes indexed by (/ level +level-step+).")

(defparameter *level-names* #(nil "trace" "debug" "info" "warn" "error" "fatal") "Vector of level name strings indexed by (/ level +level-step+).")

(defparameter *level-names-upper* #(nil "TRACE" "DEBUG" "INFO " "WARN " "ERROR" "FATAL")
  "Pre-computed uppercase padded level names for pretty-formatter.")

(defparameter *level-prefixes*
  (let ((prefixes (make-array +level-slot-count+ :initial-element nil)))
    (loop for i from +trace+ to +fatal+ by +level-step+
          do (setf (aref prefixes (floor i +level-step+))
                   (format nil "{\"level\":~d" i)))
    prefixes)
  "Pre-computed JSON level prefixes indexed by (/ level +level-step+).")

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
  (let ((idx (truncate level +level-step+)))
    (if (and (>= idx (/ +trace+ +level-step+)) (<= idx (/ +fatal+ +level-step+)))
        (svref *level-names* idx)
        "unknown")))

;;; --- Serialization Limits ---

(defvar *max-json-depth* 4
  "Maximum nesting depth for collections in emit-json-value.
   At depth 0, collections become <type> placeholders.")

(defvar *max-json-length* 20
  "Maximum number of elements emitted per collection.
   Excess elements are replaced by a single \"...\" sentinel.")

(defvar *max-pretty-depth* 4
  "Bound as CL:*PRINT-LEVEL* inside pretty-formatter.
   Controls nesting depth for value output. NIL means unlimited.")

(defvar *max-pretty-length* 20
  "Bound as CL:*PRINT-LENGTH* inside pretty-formatter.
   Controls max elements per collection. NIL means unlimited.")

(defvar *max-json-stack-frames* 10
  "Maximum stack frames in JSON condition output. NIL means unlimited.")

(defvar *max-pretty-stack-frames* 20
  "Maximum stack frames in pretty-formatter condition output. NIL means unlimited.")

;;; --- Condition Capture ---

(defstruct (captured-error (:constructor %make-captured-error))
  "A condition snapshot with stack trace for structured logging."
  (condition nil :type condition :read-only t)
  (stack     nil :type list     :read-only t))

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
   Call inside HANDLER-BIND for a meaningful trace (stack still live).
   In HANDLER-CASE the trace reflects the handler's stack, not the error origin."
  (%make-captured-error :condition condition
                        :stack (strip-internal-frames (dissect:stack))))

;;; --- JSON Output ---

(declaim (ftype (function (string stream) (values null &optional)) write-json-escaped-string))

(defun write-json-escaped-string (string stream)
  "Write STRING to STREAM with JSON escaping."
  (declare (optimize (speed 3) (safety 1))
           (type string string))
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

(declaim (inline write-json-string))
(defun write-json-string (stream string)
  "Write STRING as a JSON quoted string to STREAM."
  (write-char #\" stream)
  (write-json-escaped-string string stream)
  (write-char #\" stream))

(declaim (inline type-name-string))
(defun type-name-string (value)
  "Return the type of VALUE as a lowercase string."
  (string-downcase (princ-to-string (type-of value))))

(defvar *key-string-cache* (make-hash-table :test 'eq)
  "Cache for symbol → downcased string. Bounded by *key-string-cache-limit*.")

(defvar *key-string-cache-limit* 1024
  "Maximum entries in the key-string cache. New symbols still work but aren't cached past this.")

(defun key-string (key)
  "Convert a field key to its lowercase string representation.
   Symbol results are memoized in *key-string-cache*."
  (typecase key
    (string key)
    (symbol (or (gethash key *key-string-cache*)
                (let ((s (string-downcase (symbol-name key))))
                  (when (< (hash-table-count *key-string-cache*) *key-string-cache-limit*)
                    (setf (gethash key *key-string-cache*) s))
                  s)))
    (t (princ-to-string key))))

(defun write-angle-type (stream value)
  "Write <type> for VALUE to STREAM (no quotes)."
  (write-char #\< stream)
  (write-string (type-name-string value) stream)
  (write-char #\> stream))

(defun emit-type-placeholder (stream value)
  "Write a \"<type>\" placeholder for VALUE to STREAM as a JSON string."
  (write-char #\" stream)
  (write-angle-type stream value)
  (write-char #\" stream))

(defun write-condition-summary (stream condition)
  "Write type: message for CONDITION to STREAM."
  (write-string (type-name-string condition) stream)
  (write-string ": " stream)
  (princ condition stream))

(defun emit-json-condition-fields (stream condition)
  "Write \"type\":\"...\",\"msg\":\"...\" for CONDITION to STREAM.
   No enclosing braces — callers provide { and }."
  (write-string "\"type\":\"" stream)
  (write-json-escaped-string (type-name-string condition) stream)
  (write-string "\",\"msg\":\"" stream)
  (write-json-escaped-string (princ-to-string condition) stream)
  (write-char #\" stream))

(defun emit-json-stack-frame (stream frame)
  "Write one stack frame as a JSON object {\"call\":...,\"file\":...,\"line\":...}."
  (write-string "{\"call\":\"" stream)
  (let ((call (dissect:call frame)))
    (write-json-escaped-string (key-string call) stream))
  (write-char #\" stream)
  (let ((file (dissect:file frame)))
    (when file
      (write-string ",\"file\":\"" stream)
      (write-json-escaped-string (namestring file) stream)
      (write-char #\" stream)))
  (let ((line (dissect:line frame)))
    (when line
      (write-string ",\"line\":" stream)
      (princ line stream)))
  (write-char #\} stream))

(defun emit-json-stack (stream stack)
  "Write ,\"stack\":[...] bounded by *max-json-stack-frames*."
  (write-string ",\"stack\":[" stream)
  (let ((limit *max-json-stack-frames*)
        (i 0))
    (cond
      ((null stack))
      (t
       (dolist (frame stack)
         (when (and limit (>= i limit))
           (when (plusp i) (write-char #\, stream))
           (write-string "{\"call\":\"...\"}" stream)
           (return))
         (when (plusp i) (write-char #\, stream))
         (emit-json-stack-frame stream frame)
         (incf i)))))
  (write-char #\] stream))

(defun emit-json-key (stream key)
  "Write KEY as a JSON object key to STREAM."
  (declare (optimize (speed 3) (safety 1)))
  (write-string ",\"" stream)
  (typecase key
    (string (write-json-escaped-string key stream))
    (symbol (write-string (key-string key) stream))
    (t (write-json-escaped-string (princ-to-string key) stream)))
  (write-string "\":" stream))

(defun coerce-hash-key (k)
  "Coerce hash-table key K to a string for JSON output."
  (typecase k
    (string k)
    (symbol (key-string k))
    (pathname (namestring k))
    (t (type-name-string k))))

(defun emit-json-value (stream value &optional (depth *max-json-depth*))
  "Write VALUE as JSON to STREAM.  Collections recurse up to DEPTH levels."
  (declare (optimize (speed 3) (safety 1)))
  (typecase value
    (string    (write-json-string stream value))
    (character (write-json-string stream (string value)))
    (integer (princ value stream))
    (float (princ value stream))
    (ratio (format stream "~F" (coerce value 'double-float)))
    ((eql t) (write-string "true" stream))
    (null (write-string "null" stream))
    (symbol    (write-json-string stream (key-string value)))
    (pathname  (write-json-string stream (namestring value)))
    (cons
     (if (<= depth 0)
         (emit-type-placeholder stream value)
         (progn
           (write-char #\[ stream)
           (loop for cell on value
                 for i from 0
                 for first = t then nil
                 when (>= i *max-json-length*)
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
                 when (>= i *max-json-length*)
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
           (block hash-done
             (maphash (lambda (k v)
                        (when (>= count *max-json-length*)
                          (write-string ",\"...\":\"...\"" stream)
                          (return-from hash-done))
                        (if first (setf first nil) (write-char #\, stream))
                        (write-char #\" stream)
                        (write-json-escaped-string (coerce-hash-key k) stream)
                        (write-string "\":" stream)
                        (emit-json-value stream v (1- depth))
                        (incf count))
                      value))
           (write-char #\} stream))))
    (captured-error
     (write-char #\{ stream)
     (emit-json-condition-fields stream (captured-error-condition value))
     (emit-json-stack stream (captured-error-stack value))
     (write-char #\} stream))
    (condition
     (write-char #\{ stream)
     (emit-json-condition-fields stream value)
     (write-char #\} stream))
    (t (emit-type-placeholder stream value))))

(defun emit-json-fields (stream fields)
  "Write a plist of FIELDS as JSON key-value pairs to STREAM."
  (declare (optimize (speed 3) (safety 1)))
  (loop for (k v) on fields by #'cddr do
    (emit-json-key stream k)
    (emit-json-value stream v)))

(defun emit-context-fields (stream context)
  "Write dynamic context fields (alist) as JSON key-value pairs to STREAM."
  (declare (optimize (speed 3) (safety 1)))
  (dolist (pair context)
    (emit-json-key stream (car pair))
    (emit-json-value stream (cdr pair))))

(declaim (ftype (function (list) (values string &optional)) serialize-bindings))

(defun serialize-bindings (bindings)
  "Pre-serialize BINDINGS plist to a JSON fragment string."
  (with-output-to-string (s)
    (emit-json-fields s bindings)))

;;; --- Logfmt Output ---

(defun emit-logfmt-key (stream key)
  "Write a logfmt key to STREAM."
  (declare (optimize (speed 3) (safety 1)))
  (write-string (key-string key) stream))

(defun logfmt-write-bare-or-quoted (stream string)
  "Write STRING to STREAM, quoting if it contains space, quote, equals, backslash,
   or control characters. Escapes quotes, backslashes, newlines, returns, and tabs."
  (declare (optimize (speed 3) (safety 1))
           (type string string))
  (let ((needs-quoting nil))
    (loop for c of-type character across string
          when (or (char= c #\Space) (char= c #\") (char= c #\=)
                   (char= c #\\) (< (char-code c) 32))
            do (setf needs-quoting t) (loop-finish))
    (if needs-quoting
        (progn
          (write-char #\" stream)
          (loop for c of-type character across string do
            (case c
              (#\" (write-string "\\\"" stream))
              (#\\ (write-string "\\\\" stream))
              (#\Newline (write-string "\\n" stream))
              (#\Return (write-string "\\r" stream))
              (#\Tab (write-string "\\t" stream))
              (t (write-char c stream))))
          (write-char #\" stream))
        (write-string string stream))))

(defun emit-logfmt-condition (stream condition)
  "Write CONDITION as a quoted logfmt value: \"type: message\".
   Escapes quotes, backslashes, newlines, returns, and tabs in the message."
  (logfmt-write-bare-or-quoted
   stream
   (with-output-to-string (s) (write-condition-summary s condition))))

(defun emit-logfmt-value (stream value)
  "Write VALUE as a logfmt value to STREAM.  Scalars only."
  (typecase value
    (string (logfmt-write-bare-or-quoted stream value))
    (character (write-string (string value) stream))
    (integer (princ value stream))
    (float (princ value stream))
    (ratio (format stream "~F" (coerce value 'double-float)))
    (null (write-string "null" stream))
    (symbol (write-string (key-string value) stream))
    (pathname (logfmt-write-bare-or-quoted stream (namestring value)))
    (captured-error (emit-logfmt-condition stream (captured-error-condition value)))
    (condition (emit-logfmt-condition stream value))
    (t (write-angle-type stream value))))

(defun emit-logfmt-field (stream key value)
  "Write a logfmt key=value pair to STREAM, preceded by a space.
   Boolean T emits bare key (logfmt convention for flags)."
  (write-char #\Space stream)
  (emit-logfmt-key stream key)
  (unless (eq value t)
    (write-char #\= stream)
    (emit-logfmt-value stream value)))

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
  "Return the effective log timestamp in milliseconds.
   During buffer replay, returns the captured timestamp from the original log call.
   Otherwise, returns the current wall-clock time.
   User-defined formatters should call this for correct timestamps during buffer replay."
  (get-unix-timestamp-ms))

;;; --- Pretty Formatter Helpers ---

(defun format-frame-call (frame)
  "Format a stack frame's call as an uppercase string."
  (let ((call (dissect:call frame)))
    (if (symbolp call)
        (symbol-name call)
        (string-upcase (princ-to-string call)))))

(defun emit-pretty-stack (stream stacks)
  "Write accumulated stack traces. STACKS is a list of (key . captured-error) pairs."
  (let ((single-p (= 1 (length stacks))))
    (dolist (entry stacks)
      (let* ((key (car entry))
             (ce (cdr entry))
             (frames (captured-error-stack ce))
             (limit *max-pretty-stack-frames*)
             (total (length frames)))
        ;; Label when multiple stacks
        (unless single-p
          (format stream "~%  ~c[2m~a~c[0m:" #\Esc (key-string key) #\Esc))
        (let ((indent (if single-p "  " "    "))
              (i 0))
          (dolist (frame frames)
            (when (and limit (>= i limit))
              (format stream "~%~a~c[2m... (~d more frames)~c[0m"
                      indent #\Esc (- total i) #\Esc)
              (return))
            (let ((file (dissect:file frame))
                  (line (dissect:line frame)))
              (format stream "~%~a~c[1mat ~a~c[0m" indent #\Esc (format-frame-call frame) #\Esc)
              (when (or file line)
                (format stream " ~c[2m(~@[~a~]~@[:~d~])~c[0m"
                        #\Esc
                        (when file (namestring file))
                        line
                        #\Esc)))
            (incf i)))))))

;;; --- Formatter Factories ---

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

(defun build-json-level-prefixes (level-key level-format)
  "Build a vector of pre-computed JSON level prefix strings.
   LEVEL-KEY is the JSON key name (e.g. \"level\" or \"severity\").
   LEVEL-FORMAT is :numeric or :string."
  (let ((prefixes (make-array +level-slot-count+ :initial-element nil)))
    (loop for i from +trace+ to +fatal+ by +level-step+
          for idx = (floor i +level-step+)
          do (setf (aref prefixes idx)
                   (ecase level-format
                     (:numeric (format nil "{\"~a\":~d" level-key i))
                     (:string (format nil "{\"~a\":\"~a\"" level-key (level-name i))))))
    prefixes))

(defun make-json-formatter (&key (timestamp :unix-ms) (level-format :numeric)
                                  (level-key "level") (timestamp-key "ts")
                                  (message-key "msg"))
  "Return a JSON formatter closure with custom keys and formats.
   Pre-computes level prefix vector, timestamp key fragment, and message key fragment."
  (let ((prefixes (build-json-level-prefixes level-key level-format))
        (ts-fragment (when timestamp (format nil ",\"~a\":" timestamp-key)))
        (msg-prefix (format nil ",\"~a\":\"" message-key)))
    (lambda (level chindings raw-bindings context message fields)
      (declare (optimize (speed 3) (safety 1)))
      (declare (ignore raw-bindings))
      (with-output-to-string (s)
        (write-string (svref prefixes (floor level +level-step+)) s)
        (when ts-fragment
          (write-string ts-fragment s)
          (emit-timestamp timestamp s))
        (write-string chindings s)
        (emit-context-fields s context)
        (emit-json-fields s fields)
        (when message
          (write-string msg-prefix s)
          (write-json-escaped-string message s)
          (write-string "\"" s))
        (write-string "}" s)))))

(defun make-logfmt-formatter (&key (timestamp :unix-ms) (level-key "level")
                                    (timestamp-key "ts") (message-key "msg"))
  "Return a logfmt formatter closure with custom keys.
   Level is always string for logfmt. Pre-computes key name strings."
  (let ((level-prefix (format nil "~a=" level-key))
        (ts-prefix (when timestamp (format nil " ~a=" timestamp-key)))
        (msg-prefix (format nil " ~a=" message-key)))
    (lambda (level chindings raw-bindings context message fields)
      (declare (ignore chindings))
      (with-output-to-string (s)
        (write-string level-prefix s)
        (write-string (level-name level) s)
        (when ts-prefix
          (write-string ts-prefix s)
          (emit-timestamp timestamp s))
        (loop for (k v) on raw-bindings by #'cddr do (emit-logfmt-field s k v))
        (dolist (pair context) (emit-logfmt-field s (car pair) (cdr pair)))
        (loop for (k v) on fields by #'cddr do (emit-logfmt-field s k v))
        (when message
          (write-string msg-prefix s)
          (emit-logfmt-value s message))))))

(defun make-pretty-formatter (&key timestamp (timestamp-key "ts"))
  "Return a pretty formatter closure with optional timestamp display.
   TIMESTAMP is nil (no timestamp), :iso8601, or :unix-ms.
   Level is always colored string."
  (let ((ts-prefix (when timestamp (format nil " ~c[2m~a~c[0m=" #\Esc timestamp-key #\Esc))))
    (lambda (level chindings raw-bindings context message fields)
      (declare (ignore chindings))
      (with-output-to-string (s)
        (let* ((*print-level* *max-pretty-depth*)
               (*print-length* *max-pretty-length*)
               (*print-circle* t)
               (level-idx (floor level +level-step+))
               (color (svref *level-colors* level-idx))
               (stacks nil))
          (flet ((write-key (k)
                   (format s " ~c[2m~a~c[0m=" #\Esc (key-string k) #\Esc))
                 (write-val (k v)
                   (cond
                     ((captured-error-p v)
                      (write-condition-summary s (captured-error-condition v))
                      (push (cons k v) stacks))
                     ((typep v 'condition)
                      (write-condition-summary s v))
                     (t (princ v s)))))
            (format s "~c[~am~a~c[0m" #\Esc color (svref *level-names-upper* level-idx) #\Esc)
            (when ts-prefix
              (write-string ts-prefix s)
              (emit-timestamp timestamp s))
            (when message
              (write-char #\Space s)
              (write-string message s))
            (loop for (k v) on raw-bindings by #'cddr do
              (write-key k) (write-val k v))
            (dolist (pair context)
              (write-key (car pair)) (write-val (car pair) (cdr pair)))
            (loop for (k v) on fields by #'cddr do
              (write-key k) (write-val k v))
            (when stacks
              (emit-pretty-stack s (nreverse stacks)))))))))

;;; --- Standard Formatters ---
;;; Thin delegates to the factories with default settings.
;;; The factory closures are created once at load time.

(declaim (ftype (function (fixnum string list list (or null string) list) (values string &optional))
                json-formatter logfmt-formatter pretty-formatter))

(let ((fmt (make-json-formatter)))
  (defun json-formatter (level chindings raw-bindings context message fields)
    "Format a log entry as a JSON line. Default keys: level/ts/msg, numeric level, unix-ms."
    (funcall fmt level chindings raw-bindings context message fields)))

(let ((fmt (make-logfmt-formatter)))
  (defun logfmt-formatter (level chindings raw-bindings context message fields)
    "Format a log entry as logfmt (key=value pairs). Default keys: level/ts/msg."
    (funcall fmt level chindings raw-bindings context message fields)))

(let ((fmt (make-pretty-formatter)))
  (defun pretty-formatter (level chindings raw-bindings context message fields)
    "Format a log entry with ANSI colors for REPL/development use."
    (funcall fmt level chindings raw-bindings context message fields)))

(defconstant +min-ring-capacity+ 16 "Minimum ring buffer capacity in log lines. Power of two.")

(defconstant +default-buffer-capacity+ 8192 "Default ring buffer capacity in log lines for async output. Power of two.")

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
  (let ((mask (ring-buffer-mask rb))
        (slots (ring-buffer-slots rb)))
    (loop
      (let* ((head (ring-buffer-head rb))
             (tail (ring-buffer-tail rb))
             (size (the fixnum (- head tail))))
        (when (>= size (1+ mask))
          (atomics:atomic-incf (ring-buffer-dropped rb))
          (return nil))
        (when (atomics:cas (ring-buffer-head rb) head (1+ head))
          (setf (svref slots (logand head mask)) value)
          (return t))))))

(defun ring-buffer-drain (rb)
  "Drain all available values from the ring buffer into a list. Single-consumer only."
  (loop for val = (ring-buffer-pop rb) while val collect val))

;;; --- Async Output ---

(defun default-on-drop (count)
  "Default drop handler. Returns a JSON warning line."
  (format nil "{\"level\":~d,\"msg\":\"bark: dropped ~d log messages (output too slow)\"}" +warn+ count))

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

(defun make-async-output (stream &key (capacity +default-buffer-capacity+) (on-drop #'default-on-drop) on-error)
  "Create an async output that writes to STREAM via a background thread."
  (let* ((notify (bt:make-semaphore :name "bark-notify"))
         (ao (%make-async-output
              :ring (make-ring-buffer capacity)
              :stream stream
              :running t
              :on-drop on-drop
              :on-error on-error
              :notify notify)))
    (let ((err-output *error-output*))
      (setf (async-output-thread ao)
            (bt:make-thread (lambda ()
                              (let ((*error-output* err-output))
                                (writer-loop ao)))
                            :name "bark-writer")))
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
            (loop for old = (ring-buffer-dropped ring)
                  until (atomics:cas (ring-buffer-dropped ring) old 0))
            (let ((on-drop (async-output-on-drop async-output)))
              (when on-drop
                (let ((warning (funcall on-drop dropped)))
                  (when warning
                    (handler-case
                        (progn (write-string warning stream) (terpri stream) (force-output stream))
                      (cl:error () nil))))))))
        (let ((ack (async-output-flush-ack async-output)))
          (when ack
            (setf (async-output-flush-ack async-output) nil)
            (bt:signal-semaphore ack)))))))

;;; --- Multi-Output ---

(defstruct destination
  "A single output destination within a tee."
  (async-output nil :type async-output)
  (formatter    nil :type function)
  (filter       nil :type (or null function)))

(defstruct formatter-group
  "Destinations sharing an eq formatter, for shared-formatter optimization."
  (formatter    nil :type function)
  (destinations #() :type simple-vector))

(defstruct tee-output
  "Fan-out output: destinations grouped by formatter for shared-format optimization."
  (groups #() :type simple-vector))

(declaim (ftype (function (list) (values tee-output &optional)) make-tee))

(defun make-tee (destinations)
  "Create a fan-out output from a list of destination plists.
Each plist accepts :stream (required), :formatter, :filter, :level, :capacity, :on-drop, :on-error.
Specifying both :level and :filter is an error."
  (let ((dests
          (mapcar
           (lambda (spec)
             (let ((stream    (getf spec :stream))
                   (formatter (or (getf spec :formatter) #'json-formatter))
                   (filter-fn (getf spec :filter))
                   (level-kw  (getf spec :level))
                   (capacity  (or (getf spec :capacity) +default-buffer-capacity+))
                   (on-drop   (or (getf spec :on-drop) #'default-on-drop))
                   (on-error  (getf spec :on-error)))
               (when (and filter-fn level-kw)
                 (cl:error "Cannot specify both :filter and :level for a tee destination"))
               (let ((actual-filter
                       (cond
                         (filter-fn filter-fn)
                         (level-kw
                          (let ((threshold (level-from-keyword level-kw)))
                            (lambda (level fields)
                              (declare (ignore fields))
                              (>= level threshold))))
                         (t nil))))
                 (make-destination
                  :async-output (make-async-output stream
                                                   :capacity capacity
                                                   :on-drop on-drop
                                                   :on-error on-error)
                  :formatter formatter
                  :filter actual-filter))))
           destinations)))
    ;; Group by eq formatter for shared-formatter optimization
    (let ((groups (make-hash-table :test 'eq))
          (order nil))
      (dolist (dest dests)
        (let ((fmt (destination-formatter dest)))
          (unless (gethash fmt groups)
            (push fmt order))
          (push dest (gethash fmt groups))))
      (make-tee-output
       :groups (coerce
                (loop for fmt in (nreverse order)
                      collect (make-formatter-group
                               :formatter fmt
                               :destinations (coerce (nreverse (gethash fmt groups))
                                                     'simple-vector)))
                'simple-vector)))))

(defmacro tee (&rest destination-specs)
  "Syntax sugar over make-tee. Each spec is (stream-expr &key formatter filter level capacity on-drop on-error)."
  `(make-tee
    (list ,@(loop for spec in destination-specs
                  for (stream-expr . keys) = spec
                  do (when (and (member :level keys) (member :filter keys))
                       (cl:error "Cannot specify both :level and :filter in tee destination spec"))
                  collect `(list :stream ,stream-expr ,@keys)))))

(declaim (ftype (function (tee-output fixnum string list list (or null string) list) (values &optional)) emit-to-tee))

(defun emit-to-tee (tee-output level-value chindings raw-bindings context message fields)
  "Emit a log event to all destinations in TEE-OUTPUT, grouped by formatter."
  (declare (optimize (speed 3) (safety 1)))
  (loop for group across (tee-output-groups tee-output) do
    (let ((passing nil))
      ;; Collect destinations that pass their filter
      (loop for dest across (formatter-group-destinations group)
            for filter = (destination-filter dest)
            when (or (null filter) (funcall filter level-value fields))
              do (push dest passing))
      ;; Format once for the group, push to all passing destinations
      (when passing
        (let ((line (funcall (formatter-group-formatter group)
                             level-value chindings raw-bindings context message fields)))
          (dolist (dest passing)
            (let ((ao (destination-async-output dest)))
              (ring-buffer-push (async-output-ring ao) line)
              (bt:signal-semaphore (async-output-notify ao))))))))
  (values))

;;; --- Output Delivery ---

(defun deliver-line (output line)
  "Deliver a formatted log LINE to OUTPUT (async-output, stream, or function)."
  (if (async-output-p output)
      (progn
        (ring-buffer-push (async-output-ring output) line)
        (bt:signal-semaphore (async-output-notify output)))
      (etypecase output
        (stream (write-string line output) (terpri output) (force-output output))
        (function (funcall output line)))))

(defun dispatch-to-output (output formatter level chindings raw-bindings ctx message flds)
  "Format and deliver a log event. Routes to tee or single output."
  (if (tee-output-p output)
      (emit-to-tee output level chindings raw-bindings ctx message flds)
      (deliver-line output
                    (funcall (the function formatter)
                             level chindings raw-bindings ctx message flds))))

;;; --- Logger ---

(defun noop (logger message &rest fields)
  "No-op log function for disabled levels."
  (declare (ignore logger message fields))
  (values))

(defstruct (logger (:constructor %make-logger))
  "A bark logger instance."
  (name            ""    :type string :read-only t)
  (level           +info+ :type fixnum)
  (chindings       ""    :type string :read-only t)
  (raw-bindings    nil   :type list :read-only t)
  (formatter       nil   :type (or null function))
  (output          nil   :type t)
  (sampler         nil   :type (or null simple-vector))
  (field-transform nil   :type (or null function))
  (trace-fn        #'noop :type function)
  (debug-fn        #'noop :type function)
  (info-fn         #'noop :type function)
  (warn-fn         #'noop :type function)
  (error-fn        #'noop :type function)
  (fatal-fn        #'noop :type function))

(defvar *logger* nil "The current bark logger.")

(defvar *log-context* nil "Dynamic context bindings for the current log scope.")

(defun apply-field-transform-plist (transform plist)
  "Apply TRANSFORM to each key-value pair in PLIST. Returns a new plist with
   transformed values. Pairs where TRANSFORM returns NIL as second value are dropped."
  (declare (type function transform))
  (loop for (k v) on plist by #'cddr
        for keep = (multiple-value-list (funcall transform k v))
        when (or (null (cdr keep)) (second keep))
          collect k and collect (first keep)))

(defun apply-field-transform-alist (transform alist)
  "Apply TRANSFORM to each pair in ALIST (dynamic context). Returns a new alist.
   Pairs where TRANSFORM returns NIL as second value are dropped."
  (declare (type function transform))
  (loop for (k . v) in alist
        for keep = (multiple-value-list (funcall transform k v))
        when (or (null (cdr keep)) (second keep))
          collect (cons k (first keep))))

(defun compose-field-transforms (outer inner)
  "Compose two field transforms. INNER runs first, then OUTER on the result.
   If either is NIL, returns the other."
  (cond
    ((null outer) inner)
    ((null inner) outer)
    (t (lambda (key value)
         (let ((results (multiple-value-list (funcall inner key value))))
           (if (and (cdr results) (null (second results)))
               (values nil nil)
               (funcall outer key (first results))))))))

(declaim (ftype (function (fixnum) (values function &optional)) make-log-fn))

(defun make-log-fn (level-value)
  "Create a log function for LEVEL-VALUE."
  (declare (optimize (speed 3) (safety 1))
           (type fixnum level-value))
  (let ((level-index (floor level-value +level-step+)))
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
        (let ((output (logger-output lgr))
              (transform (logger-field-transform lgr)))
          (when output
            (let ((ctx (if transform
                           (apply-field-transform-alist transform *log-context*)
                           *log-context*))
                  (flds (if transform
                            (apply-field-transform-plist transform fields)
                            fields)))
              (dispatch-to-output output (logger-formatter lgr)
                                  level-value
                                  (logger-chindings lgr) (logger-raw-bindings lgr)
                                  ctx message flds))))
        (values)))))

(declaim (ftype (function (&key (:name string) (:level (or fixnum keyword)) (:formatter function)
                                (:output t) (:field-transform (or null function)))
                          (values logger &optional)) make-logger))

(defun make-logger (&key (name "") (level :info) (formatter #'json-formatter) output field-transform)
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
               :output output
               :field-transform field-transform)))
    (set-level lgr level)
    lgr))

(declaim (ftype (function (logger (or fixnum keyword)) *) set-level))

(defun wire-level-fns (logger threshold make-fn)
  "Set all six level function slots on LOGGER. Levels at or above THRESHOLD
   get functions from (funcall MAKE-FN level); levels below get #'noop."
  (flet ((slot-fn (level) (if (< level threshold) #'noop (funcall make-fn level))))
    (setf (logger-trace-fn logger) (slot-fn +trace+))
    (setf (logger-debug-fn logger) (slot-fn +debug+))
    (setf (logger-info-fn logger)  (slot-fn +info+))
    (setf (logger-warn-fn logger)  (slot-fn +warn+))
    (setf (logger-error-fn logger) (slot-fn +error+))
    (setf (logger-fatal-fn logger) (slot-fn +fatal+)))
  (values))

(defun set-level (logger level)
  "Set the minimum log level for LOGGER. Swaps function slots."
  (let ((level-val (etypecase level
                     (fixnum level)
                     (keyword (level-from-keyword level)))))
    (setf (logger-level logger) level-val)
    (wire-level-fns logger level-val #'make-log-fn)))

(declaim (ftype (function (logger (or fixnum keyword) fixnum) (values t &optional)) set-sampling))

(defun set-sampling (logger level rate)
  "Set sampling for LEVEL to 1-in-RATE on LOGGER."
  (let ((level-val (etypecase level
                     (fixnum level)
                     (keyword (level-from-keyword level))))
        (sampler (or (logger-sampler logger)
                     (make-array +level-slot-count+ :initial-element nil))))
    (setf (aref sampler (floor level-val +level-step+)) (cons rate (1- rate)))
    (setf (logger-sampler logger) sampler)))

(declaim (ftype (function (logger &rest t) (values logger &rest t)) child))

(defun child (parent &rest bindings)
  "Create a child logger from PARENT with additional BINDINGS pre-serialized.
   Inherits the parent's field-transform. When BINDINGS include :field-transform,
   the value is composed with the parent's transform (child runs after parent)."
  (let* ((child-transform (getf bindings :field-transform))
         (clean-bindings (if child-transform
                             (loop for (k v) on bindings by #'cddr
                                   unless (eq k :field-transform)
                                     collect k and collect v)
                             bindings))
         (parent-transform (logger-field-transform parent))
         (composed-transform (compose-field-transforms child-transform parent-transform))
         (effective-bindings (if composed-transform
                                 (apply-field-transform-plist composed-transform clean-bindings)
                                 clean-bindings))
         (new-chindings (concatenate 'string
                                      (logger-chindings parent)
                                      (serialize-bindings effective-bindings)))
         (new-raw-bindings (append (logger-raw-bindings parent) effective-bindings))
         (child (%make-logger
                 :name (logger-name parent)
                 :level (logger-level parent)
                 :chindings new-chindings
                 :raw-bindings new-raw-bindings
                 :formatter (logger-formatter parent)
                 :output (logger-output parent)
                 :sampler (logger-sampler parent)
                 :field-transform composed-transform)))
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

(declaim (ftype (function (&key (:output t) (:level (or fixnum keyword)) (:formatter function)
                                (:name string) (:capacity fixnum) (:on-drop (or null function))
                                (:context list) (:field-transform (or null function)))
                          (values logger &optional)) start))

(defun start (&key output (level :info) (formatter #'json-formatter)
                   (name "") (capacity +default-buffer-capacity+) (on-drop #'default-on-drop)
                   context field-transform)
  "Start the global logger. OUTPUT can be a stream, a tee-output, or NIL (defaults to *error-output*).
When OUTPUT is a plain stream, it is wrapped in an async-output with CAPACITY and ON-DROP.
When OUTPUT is a tee-output, the async-outputs are already created.
CONTEXT, when provided, is a plist of static context fields.
FIELD-TRANSFORM, when provided, is a function (lambda (key value) -> (values new-value keep-p))
that is called on each field before serialization. Return (values nil nil) to drop a field."
  (when (and *logger* (logger-output *logger*))
    (stop))
  (let* ((actual-output (cond
                          ((tee-output-p output) output)
                          ((streamp output) (make-async-output output :capacity capacity :on-drop on-drop))
                          ((null output) (make-async-output *error-output* :capacity capacity :on-drop on-drop))
                          (t (cl:error "Invalid :output for start: ~a (expected stream, tee-output, or NIL)" output))))
         (lgr (make-logger :name name :level level :formatter formatter
                           :output actual-output :field-transform field-transform)))
    (setf *logger* (if context (apply #'child lgr context) lgr))))

(defun stop ()
  "Flush and stop the global logger's writer thread(s)."
  (when *logger*
    (let ((output (logger-output *logger*)))
      (cond
        ((and output (tee-output-p output))
         (loop for group across (tee-output-groups output)
               do (loop for dest across (formatter-group-destinations group)
                        do (stop-async-output (destination-async-output dest)))))
        ((and output (async-output-p output))
         (stop-async-output output))))
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
     (let* ((*logger* (make-logger :name "test" :level :trace
                                   :formatter ,formatter :output collector)))
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

(macrolet ((define-log-macro (name accessor)
             `(defmacro ,name (&rest args)
                "Log at the appropriate level. First arg can be a logger, a message string,
                 or a keyword (starting a fields-only plist with no message)."
                (when args
                  (if (keywordp (car args))
                      ;; Compile-time: literal keyword first → fields-only, use *logger*
                      `(when *logger*
                         (funcall (,',accessor *logger*) *logger* nil ,@args))
                      ;; First arg needs runtime dispatch
                      (let ((g (gensym "FIRST"))
                            (rest-forms (cdr args)))
                        ;; Pre-compute the logger branch outside the template
                        (let ((logger-branch
                                (cond
                                  ((null rest-forms)
                                   `(funcall (,',accessor ,g) ,g nil))
                                  ((keywordp (car rest-forms))
                                   `(funcall (,',accessor ,g) ,g nil ,@rest-forms))
                                  (t
                                   (let ((g2 (gensym "ARG")))
                                     `(let ((,g2 ,(car rest-forms)))
                                        (if (keywordp ,g2)
                                            (funcall (,',accessor ,g) ,g nil ,g2 ,@(cdr rest-forms))
                                            (funcall (,',accessor ,g) ,g ,g2 ,@(cdr rest-forms)))))))))
                          `(let ((,g ,(car args)))
                             (cond
                               ((logger-p ,g) ,logger-branch)
                               ((keywordp ,g)
                                (when *logger*
                                  (funcall (,',accessor *logger*) *logger* nil ,g ,@rest-forms)))
                               (t
                                (when *logger*
                                  (funcall (,',accessor *logger*) *logger* ,g ,@rest-forms))))))))))))
  (define-log-macro trace logger-trace-fn)
  (define-log-macro debug logger-debug-fn)
  (define-log-macro info  logger-info-fn)
  (define-log-macro warn  logger-warn-fn)
  (define-log-macro error logger-error-fn)
  (define-log-macro fatal logger-fatal-fn))
