;;; packages.lisp — Package definitions

(defpackage #:bark
  (:use #:cl)
  (:documentation "High-performance structured logger for Common Lisp. Async I/O via lock-free ring buffers, JSON/logfmt/pretty formatters, multi-output fan-out, child loggers with pre-serialized context, sampling, and request-scoped buffering.")
  (:shadow #:debug #:error #:trace #:warn #:formatter)
  (:export
   ;; levels
   #:+trace+ #:+debug+ #:+info+ #:+warn+ #:+error+ #:+fatal+
   ;; conditions
   #:capture
   #:captured-error-p #:captured-error-condition #:captured-error-stack
   ;; timestamps
   #:current-log-timestamp-ms
   ;; json
   #:*max-json-depth* #:*max-json-length* #:*max-json-stack-frames*
   ;; pretty
   #:*max-pretty-depth* #:*max-pretty-length* #:*max-pretty-stack-frames*
   ;; formatters
   #:formatter #:make-formatter #:formatter-p #:formatter-prepare-fn #:formatter-format-fn
   #:json-formatter #:logfmt-formatter #:pretty-formatter
   #:make-json-formatter #:make-logfmt-formatter #:make-pretty-formatter
   ;; output
   #:make-tee #:tee
   ;; logger
   #:*logger* #:*log-context* #:*compile-time-max-level*
   #:logger-p
   #:make-logger #:make-child #:set-level #:level-enabled-p
   #:make-windowed-counter #:make-level-sampler #:set-level-sampling
   #:make-consistent-sampler #:set-consistent
   #:flush #:stop #:register-exit-hook
   #:trace #:debug #:info #:warn #:error #:fatal
   #:with-context #:with-captured-logs
   ;; buffer
   #:with-log-buffer
   #:buffer-entry-level #:buffer-entry-message
   #:buffer-entry-fields #:buffer-entry-context #:buffer-entry-timestamp
   #:bark-async-stopped
   #:bark-child-operation-error
   #:bark-child-operation-error-operation
   #:bark-configuration-error
   #:bark-configuration-error-detail
   #:bark-error
   #:bark-lifecycle-error
   #:level-name))
