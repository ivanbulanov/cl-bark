# Sampling

cl-bark has two sampling strategies that can be used together. Both run before formatting, so a sampled-out message costs no serialization.

## Windowed Counter

For a given log level, the first N messages in each time window always pass, then one in M passes. This is the model of Go's zap: the first messages of a burst show what triggered it, and the sample after that shows its extent. Counting is 1-based, and the clock is read only when a message is about to be dropped (see "Window expiry detection").

Counters are set per level, so debug can be sampled one in 100 while info is sampled one in 10 and errors are not sampled.

### Basic Usage

```lisp
;; Sample debug messages: first 5 per second always pass, then 1-in-100
(setf bark:*logger*
      (bark:make-logger :level :debug
                        :level-sampler (bark:make-level-sampler
                                         :debug (bark:make-windowed-counter
                                                  :initial 5 :thereafter 100))))
```

Counting is 1-based: messages 1 through 5 in a window pass, then every 100th message (100, 200, ...) passes.

### Hard Cap

Set `thereafter` to 0 to drop everything after the initial burst:

```lisp
;; Allow at most 10 trace messages per second
(bark:make-level-sampler
  :trace (bark:make-windowed-counter :initial 10 :thereafter 0))
```

This is useful for trace-level instrumentation that would otherwise overwhelm the system. You see the first 10 per window, then silence until the window is reset (see "Window expiry detection" below for when a reset is noticed).

### Multiple Levels

Each level gets its own counter with independent parameters:

```lisp
(bark:make-level-sampler
  :trace (bark:make-windowed-counter :initial 2  :thereafter 50)
  :debug (bark:make-windowed-counter :initial 5  :thereafter 100)
  :info  (bark:make-windowed-counter :initial 10 :thereafter 0))
;; :warn, :error, :fatal are nil, no sampling, everything passes
```

### Runtime Adjustment

Change sampling without restarting:

```lisp
;; Tighten debug sampling during a load spike
(bark:set-level-sampler bark:*logger* :debug
  (bark:make-windowed-counter :initial 2 :thereafter 500))

;; Remove debug sampling entirely
(bark:set-level-sampler bark:*logger* :debug nil)
```

The level argument is a keyword (`:debug`) or a fixnum level value. `set-level-sampler` is thread-safe. The per-level slot replacement is a single word-sized write, so active log calls see either the old or new counter, never a partial state. If the logger has no level-sampler yet, the first call installs a fresh vector with a CAS.

### Window Sizing

The `:window-seconds` parameter controls how long a window lasts:

```lisp
;; Tight window: 1 second (default)
(bark:make-windowed-counter :initial 5 :thereafter 100 :window-seconds 1)

;; Wider window: 10 seconds, smoother averages, less responsive to bursts
(bark:make-windowed-counter :initial 5 :thereafter 100 :window-seconds 10)
```

Shorter windows react faster to traffic changes but may allow more total messages. Longer windows provide more stable rates. For most services, 1 second is the right default.

## Consistent Sampler

The consistent sampler hashes a correlation key (for example a request id) and keeps or drops all logs that share the key. The same key gives the same decision within a process, and no per-key state is kept.

Windowed counters decide per message, so you might see the auth log of a request but not its database query. With consistent sampling you see the whole request or none of it.

### Basic Usage

```lisp
(setf bark:*logger*
      (bark:make-logger :level :debug
                        :consistent (bark:make-consistent-sampler
                                      :key-fn (lambda (context)
                                                (getf context :request-id))
                                      :rate 10)))
```

This keeps 1-in-10 requests (all their logs) and drops the other 9 entirely.

### How `key-fn` Works

The `key-fn` receives the logger's static context plist (`logger-context`), all context set via `:context` on the logger and its ancestors. It returns a key (a string, symbol, or number, which is passed to `sxhash`) or nil.

When `key-fn` returns nil (no correlation key available), the consistent sampler is skipped and the message falls through to the windowed counter. This means messages logged before a request-id is established naturally bypass consistent sampling.

```lisp
;; Key function extracts :request-id from the logger's context
(lambda (context) (getf context :request-id))

;; The :request-id comes from a child logger:
(let ((req-log (bark:make-child bark:*logger* :context (list :request-id (generate-id)))))
  ;; req-log's context includes :request-id
  ;; All logs through req-log get the same hash decision
  (bark:info req-log "handling request")
  (bark:debug req-log "parsed body" :size 4096))
```

### Choosing a Rate

The rate is 1-in-N: `rate=1` keeps everything, `rate=100` keeps 1%.

| Traffic | Rate | Effect |
|---------|------|--------|
| 1K req/sec | 10 | ~100 full request traces/sec |
| 10K req/sec | 100 | ~100 full request traces/sec |
| 100K req/sec | 1000 | ~100 full request traces/sec |

Work backwards from how many full traces you want to retain per second, then divide by request rate.

## Combining Both

The two strategies compose. The consistent sampler runs first:

1. `key-fn` is called with the logger's static context.
2. If it returns a key, the hash decides. The windowed counter is skipped, so a kept request keeps all its logs.
3. If it returns nil, the windowed counter decides.

### Typical Production Setup

```lisp
(setf bark:*logger*
      (bark:make-logger
        :context '(:name "api-server")
        :level :debug

        ;; Consistent: keep 1-in-50 full request traces
        :consistent (bark:make-consistent-sampler
                      :key-fn (lambda (context) (getf context :request-id))
                      :rate 50)

        ;; Windowed: for messages without a request-id (startup, health checks, etc.)
        :level-sampler (bark:make-level-sampler
                         :debug (bark:make-windowed-counter
                                  :initial 5 :thereafter 200)
                         :trace (bark:make-windowed-counter
                                  :initial 2 :thereafter 0))))

;; Per-request child logger
(defun handle-request (request)
  (let ((bark:*logger* (bark:make-child bark:*logger*
                                        :context (list :request-id (request-id request)
                                                       :method (request-method request)))))
    ;; All logs here carry :request-id in the logger context.
    ;; Consistent sampler decides once per request.
    (bark:info "request started")
    (bark:debug "headers parsed" :count (header-count request))
    (process-request request)
    (bark:info "request completed" :status 200)))
```

Startup logs and health checks lack `:request-id`, so they fall through to the windowed counter. Request-scoped logs are handled by the consistent sampler.

### Microservice with Component Loggers

`make-child` snapshots both sampling configurations at creation time. The child shares the parent's level-sampler vector and consistent sampler object as they were when the child was created:

```lisp
;; Root logger with sampling
(setf bark:*logger*
      (bark:make-logger :level :debug
                        :consistent (bark:make-consistent-sampler
                                      :key-fn (lambda (context) (getf context :request-id))
                                      :rate 20)
                        :level-sampler (bark:make-level-sampler
                                         :debug (bark:make-windowed-counter
                                                  :initial 5 :thereafter 100))))

;; Component loggers, each inherits sampling from root
(defvar *db-log* (bark:make-child bark:*logger* :context '(:component "database")))
(defvar *cache-log* (bark:make-child bark:*logger* :context '(:component "cache")))
(defvar *auth-log* (bark:make-child bark:*logger* :context '(:component "auth")))

;; In a request handler:
;; Context accumulates from all ancestors, but only loggers created as
;; children of the request-scoped context carry :request-id. The component
;; loggers above were created from the root, so they need a per-request
;; child too:
(let ((db-log (bark:make-child *db-log* :context (list :request-id rid))))
  (bark:debug db-log "query executed" :sql "SELECT ..."))
```

Because the snapshot is taken at creation, a later `set-consistent` on the parent does not reach existing children. `set-level-sampler` on the parent reaches existing children only if the parent already had a level-sampler when the child was created (the vector is shared); if the parent had none, the call installs a new vector that existing children do not see. Windowed counters are shared objects, so children created from the same parent draw from the same counter for a given level.

## Caveats

### Consistent sampler bypasses windowed counter

When the consistent sampler decides "keep," the windowed counter is skipped entirely. This means `consistent.rate` is the sole volume control for keyed messages. If you set `rate=2` (keep 50%) and have 100K requests/sec each producing 20 log lines, the consistent sampler alone passes 1M log lines/sec, regardless of any windowed counter configuration.

Recourse: Set `rate` high enough to keep total keyed throughput within your output capacity. Work backwards from your budget: if you can handle 10K log lines/sec and each request produces 20 lines, you need `rate >= requests_per_sec * 20 / 10000`.

### Post-burst sampling gap

Counts are 1-based: each message increments the counter (via `atomics:atomic-incf`, which returns the new value) and passes when `count <= initial`, or when `thereafter` is positive and `count` is a multiple of `thereafter`. The first sampled message passes at `count = thereafter`, not `count = initial + thereafter`. With `initial=5, thereafter=100`: messages 1 through 5 pass, message 100 passes, and the 94 messages in between (6 through 99) are dropped, not 100.

This matches Go zap's behavior and is negligible in practice. If you need a precise rate immediately after the burst, set `initial=0`.

### Window expiry detection

The clock is read only when a message is about to be dropped. Each call `atomic-incf`s the counter and checks `count <= initial` or a multiple of `thereafter`; a message that passes never touches the clock. A message that would be dropped reads `get-internal-real-time` and, if the window has expired, resets the window (count back to 0), re-increments, and re-checks, so that message is counted in the new window. There is no compile-time constant.

Consequences: a level that never exceeds `initial` within a window never reads the clock, and a level whose count stays under its thresholds just keeps counting until a message would be dropped. Expiry is noticed by the first would-be-dropped message after the window ends, so a low-volume level gets its burst back as soon as it would otherwise drop. Under sustained overload every dropped message pays one clock read.

### Thread-count imprecision at window boundaries

At a window boundary, multiple threads may observe the old count before one thread resets it. Up to `thread-count` extra messages may be incorrectly evaluated against the old window's count. The net effect on sampling rates over a full window is negligible (<0.1% for typical volumes).

### `sxhash` consistency

The consistent sampler uses `sxhash` for hashing. On SBCL, `sxhash` is deterministic across sessions for strings, symbols, and numbers. The same request-id always produces the same sampling decision, even across process restarts. This is an SBCL property, not a CL spec guarantee, other implementations may randomize `sxhash` seeds.

### Child logger key-fn timing

The consistent sampler's `key-fn` reads the static context plist (`logger-context`) from the logger struct. This context is set at logger creation time (via `:context` on `make-logger` or `make-child`). If you set up the consistent sampler on a root logger and create request-scoped children, the `key-fn` sees the child's context, including `:request-id`. But logging through the root logger directly (without a child) means `key-fn` won't find `:request-id` and falls through to the windowed counter.

Recourse: Always log through a request-scoped child when you want consistent sampling. Root-level logs (startup, health checks) fall through to the windowed counter by design.

## Other features

- Sampling runs after the level gate. A counter on a disabled level does not count or reset until the level is enabled.
- Sampling runs before field transforms and tee filters. A sampled-out message reaches neither.
- Sampling is per logger. For different volumes per destination, give the tee destinations level filters.
- Calls stripped by `*compile-time-min-level*` never reach the sampler.
- `with-log-buffer` bypasses sampling for implicit log calls. See [interactions.md](interactions.md) and [request-scoped-buffering.md](request-scoped-buffering.md).
- Do not combine sampling with [blocking mode](blocking-mode.md): sampling drops messages that blocking mode is meant to keep.
