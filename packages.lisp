;;; packages.lisp — Package definitions

(defpackage #:bark
  (:use #:cl)
  (:documentation "High-performance structured logger for Common Lisp. Async I/O via lock-free ring buffers, JSON/logfmt/pretty formatters, multi-output fan-out, child loggers with pre-serialized context, sampling, and request-scoped buffering.")
  (:shadow #:debug #:error #:trace #:warn)
  (:export
   ;; levels
   #:+trace+ #:+debug+ #:+info+ #:+warn+ #:+error+ #:+fatal+
   ;; conditions
   #:capture
   #:captured-error #:captured-error-p
   #:captured-error-condition #:captured-error-stack
   ;; timestamps
   #:current-log-timestamp-ms
   ;; json
   #:*max-json-depth* #:*max-json-length* #:*max-json-stack-frames*
   ;; pretty
   #:*max-pretty-depth* #:*max-pretty-length* #:*max-pretty-stack-frames*
   ;; formatters
   #:json-formatter #:logfmt-formatter #:pretty-formatter
   #:make-json-formatter #:make-logfmt-formatter #:make-pretty-formatter
   ;; ring-buffer
   #:+min-ring-capacity+ #:+default-buffer-capacity+
   ;; output
   #:make-tee #:tee
   ;; logger
   #:*logger* #:*log-context* #:*compile-time-max-level*
   #:logger #:logger-p
   #:make-logger #:make-child #:set-level #:level-enabled-p
   #:compose-field-transforms
   #:make-windowed-counter #:make-level-sampler #:set-level-sampling
   #:windowed-counter-initial #:windowed-counter-thereafter
   #:windowed-counter-window-ticks
   #:make-consistent-sampler #:set-consistent
   #:consistent-sampler-key-fn #:consistent-sampler-rate
   #:flush #:stop #:register-exit-hook
   #:trace #:debug #:info #:warn #:error #:fatal
   #:with-context #:with-captured-logs
   ;; buffer
   #:with-log-buffer
   #:buffer-entry #:buffer-entry-level #:buffer-entry-message
   #:buffer-entry-fields #:buffer-entry-context #:buffer-entry-timestamp))
