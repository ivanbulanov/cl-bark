# Sampling

cl-bark provides two composable sampling strategies that control log volume without losing visibility into the events that matter. Both operate before formatting — sampled-out messages pay zero serialization cost.

## Why Sampling

A service logging at `:debug` across 100K requests/sec can produce millions of log lines per second. Most of these are routine — the same cache miss, the same SQL timing, the same auth check. Without sampling:

- Writer threads fall behind, ring buffers fill, messages drop uncontrollably
- Log storage costs explode
- Log search tools become unusable

Sampling trades completeness for sustainability. The two strategies address different facets of the problem.

## Windowed Counter

**What it does:** For a given log level, guarantee the first N messages per time window always pass, then sample 1-in-M thereafter.

**Why this shape:** The first few messages in a burst are the most diagnostic — they show what triggered the burst. After that, statistical sampling preserves trends without flooding. This is Go zap's production-proven model.

**Why per-level:** Different levels have different volume characteristics. Debug might need aggressive 1-in-100 sampling while info needs only a mild 1-in-10. Errors should never be sampled. Per-level control avoids the "one cap fits all" problem.

**Why not a token bucket:** Token buckets provide smoother rate control, but cl-bark's async ring buffer already absorbs I/O bursts. The windowed counter's "burst then sample" model serves observability better — you see the start of every incident, then get a statistical view of its duration.

### Basic Usage

```lisp
;; Sample debug messages: first 5 per second always pass, then 1-in-100
(bark:start :level :debug
            :level-sampler (bark:make-level-sampler
                             :debug (bark:make-windowed-counter
                                      :initial 5 :thereafter 100)))
```

### Hard Cap

Set `thereafter` to 0 to drop everything after the initial burst:

```lisp
;; Allow at most 10 trace messages per second
(bark:make-level-sampler
  :trace (bark:make-windowed-counter :initial 10 :thereafter 0))
```

This is useful for trace-level instrumentation that would otherwise overwhelm the system. You see the first 10 per window, then silence until the next window.

### Multiple Levels

Each level gets its own counter with independent parameters:

```lisp
(bark:make-level-sampler
  :trace (bark:make-windowed-counter :initial 2  :thereafter 50)
  :debug (bark:make-windowed-counter :initial 5  :thereafter 100)
  :info  (bark:make-windowed-counter :initial 10 :thereafter 0))
;; :warn, :error, :fatal are nil — no sampling, everything passes
```

### Runtime Adjustment

Change sampling without restarting:

```lisp
;; Tighten debug sampling during a load spike
(bark:set-level-sampling *logger* :debug
  (bark:make-windowed-counter :initial 2 :thereafter 500))

;; Remove debug sampling entirely
(bark:set-level-sampling *logger* :debug nil)
```

`set-level-sampling` is thread-safe. The struct replacement is atomic (single word-sized write). Active log calls see either the old or new counter, never a partial state.

### Window Sizing

The `:window-seconds` parameter controls how long a window lasts:

```lisp
;; Tight window: 1 second (default)
(bark:make-windowed-counter :initial 5 :thereafter 100 :window-seconds 1)

;; Wider window: 10 seconds — smoother averages, less responsive to bursts
(bark:make-windowed-counter :initial 5 :thereafter 100 :window-seconds 10)
```

Shorter windows react faster to traffic changes but may allow more total messages. Longer windows provide more stable rates. For most services, 1 second is the right default.

## Consistent Sampler

**What it does:** Hash a correlation key (e.g., request-id) and deterministically keep or drop all logs sharing that key. Same key always produces the same decision within a process.

**Why this exists:** When debugging a request, you need all of its logs, not a random subset. Windowed counters sample independently per message — you might see the auth log but not the database query from the same request. Consistent sampling gives you all-or-nothing: either you see the complete request trace, or you see none of it.

**Why hash-based:** The decision must be deterministic (same key = same outcome) and stateless (no per-key tracking, no bloom filters, no LRU cache). A hash mod N satisfies both.

### Basic Usage

```lisp
(bark:start :level :debug
            :consistent (bark:make-consistent-sampler
                          :key-fn (lambda (bindings)
                                    (getf bindings :request-id))
                          :rate 10))
```

This keeps 1-in-10 requests (all their logs) and drops the other 9 entirely.

### How `key-fn` Works

The `key-fn` receives the logger's accumulated `raw-bindings` — a plist containing all static context from the logger and its ancestors. It returns a key (any hashable value) or nil.

When `key-fn` returns nil (no correlation key available), the consistent sampler is skipped and the message falls through to the windowed counter. This means messages logged before a request-id is established naturally bypass consistent sampling.

```lisp
;; Key function extracts :request-id from bindings
(lambda (bindings) (getf bindings :request-id))

;; The :request-id comes from a child logger:
(let ((req-log (bark:child *logger* :request-id (generate-id))))
  ;; req-log's raw-bindings include :request-id
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

```
log call → consistent check → windowed check → emit
              |                   |
              key found?          count check
              yes: hash decides   no consistent key:
              (skip windowed)     windowed decides
```

**When a key is found:** the consistent sampler makes the keep/drop decision. The windowed counter is bypassed entirely. This preserves the all-or-nothing guarantee — if a request is kept, all its logs pass without volume gating.

**When no key is found:** the consistent sampler is skipped (~15ns overhead) and the windowed counter decides.

### Typical Production Setup

```lisp
(bark:start
  :name "api-server"
  :level :debug

  ;; Consistent: keep 1-in-50 full request traces
  :consistent (bark:make-consistent-sampler
                :key-fn (lambda (bindings) (getf bindings :request-id))
                :rate 50)

  ;; Windowed: for messages without a request-id (startup, health checks, etc.)
  :level-sampler (bark:make-level-sampler
                   :debug (bark:make-windowed-counter
                            :initial 5 :thereafter 200)
                   :trace (bark:make-windowed-counter
                            :initial 2 :thereafter 0)))

;; Per-request child logger
(defun handle-request (request)
  (let ((bark:*logger* (bark:child bark:*logger*
                                   :request-id (request-id request)
                                   :method (request-method request))))
    ;; All logs here carry :request-id in raw-bindings.
    ;; Consistent sampler decides once per request.
    (bark:info "request started")
    (bark:debug "headers parsed" :count (header-count request))
    (process-request request)
    (bark:info "request completed" :status 200)))
```

Startup logs and health checks lack `:request-id`, so they fall through to the windowed counter. Request-scoped logs are handled by the consistent sampler.

### Microservice with Component Loggers

Child loggers inherit both sampling configurations:

```lisp
;; Root logger with sampling
(bark:start :level :debug
            :consistent (bark:make-consistent-sampler
                          :key-fn (lambda (b) (getf b :request-id))
                          :rate 20)
            :level-sampler (bark:make-level-sampler
                             :debug (bark:make-windowed-counter
                                      :initial 5 :thereafter 100)))

;; Component loggers — each inherits sampling from root
(defvar *db-log* (bark:child bark:*logger* :component "database"))
(defvar *cache-log* (bark:child bark:*logger* :component "cache"))
(defvar *auth-log* (bark:child bark:*logger* :component "auth"))

;; In a request handler:
(let ((bark:*logger* (bark:child bark:*logger* :request-id rid)))
  ;; All component loggers see :request-id via the inherited key-fn,
  ;; because raw-bindings accumulate from all ancestors.
  ;; BUT: only loggers created as children of the request-scoped logger
  ;; will carry :request-id. The component loggers above were created
  ;; from the root — they need a per-request child too:
  (let ((*db-log* (bark:child *db-log* :request-id rid)))
    (bark:debug *db-log* "query executed" :sql "SELECT ...")))
```

## Interaction with Other Features

### Request-Scoped Buffering (`with-log-buffer`)

Sampling is completely bypassed inside `with-log-buffer`. The buffer captures everything regardless of sampling configuration. At flush time, the buffer decides what to emit based on exit status — this is a higher-priority decision than sampling.

```lisp
;; Even with aggressive sampling, the buffer captures all debug logs.
;; On error, everything is emitted. On success, only info+ is emitted.
(bark:with-log-buffer ()
  (bark:debug "step 1" :data payload)   ; captured (sampling bypassed)
  (bark:debug "step 2" :result result)  ; captured
  (process))
```

**Rationale:** `with-log-buffer` exists for retroactive decisions — you don't know whether you need the debug logs until the scope exits. Sampling would defeat this purpose by discarding messages before the buffer sees them.

### Multi-Output (Tee)

Sampling runs before formatting and output dispatch. A sampled-out message never reaches any destination. There is no per-destination sampling — if you need different volumes per destination, use per-destination level filters instead:

```lisp
;; Debug to file (sampled), info+ to console (unsampled)
(bark:start :level :debug
            :level-sampler (bark:make-level-sampler
                             :debug (bark:make-windowed-counter
                                      :initial 5 :thereafter 100))
            :output (bark:tee
                     (*error-output* :formatter #'bark:pretty-formatter
                                     :level :info)   ; info+ only
                     (log-file      :formatter #'bark:json-formatter)))
```

### Compile-Time Elimination

`*compile-time-max-level*` eliminates log calls at compile time. Sampling cannot resurrect eliminated calls. If you compile with `(setf bark:*compile-time-max-level* 30)`, debug and trace calls don't exist in the binary — no sampling configuration can bring them back.

### Level Gate

Sampling runs after the level gate. If a level is disabled (below the logger's threshold), the noop function fires and sampling code is never reached. A windowed counter configured on a disabled level is inert — it doesn't count or reset. If you later enable the level via `set-level`, the counter activates with its current state.

## Caveats

### Consistent sampler bypasses windowed counter

When the consistent sampler decides "keep," the windowed counter is skipped entirely. This means `consistent.rate` is the **sole volume control** for keyed messages. If you set `rate=2` (keep 50%) and have 100K requests/sec each producing 20 log lines, the consistent sampler alone passes 1M log lines/sec — regardless of any windowed counter configuration.

**Recourse:** Set `rate` high enough to keep total keyed throughput within your output capacity. Work backwards from your budget: if you can handle 10K log lines/sec and each request produces 20 lines, you need `rate >= requests_per_sec * 20 / 10000`.

### Post-burst sampling gap

After the initial burst (messages 0 through `initial-1`), the next sampled message passes at `count = thereafter`, not `count = initial + thereafter`. With `initial=5, thereafter=100`: the gap between the last burst message and the first sample is 96 dropped messages, not 100.

This matches Go zap's behavior and is negligible in practice. If you need a precise rate immediately after the burst, set `initial=0`.

### Window boundary fuzziness

The windowed counter amortizes clock reads every 64 messages (configurable via `+window-check-interval+` at compile time). This means window boundaries are detected up to 64 messages late. At 10K messages/sec, the fuzziness is ~6ms — irrelevant for 1-second windows. At 1M messages/sec, it's ~64 microseconds.

**Recourse:** If you need tighter windows, reduce `+window-check-interval+` before compiling cl-bark. Powers of 2 only (for bit-mask optimization). Lower values increase clock overhead (~0.3ns per check per message).

### Thread-count imprecision at window boundaries

At a window boundary, multiple threads may observe the old count before one thread resets it. Up to `thread-count` extra messages may be incorrectly evaluated against the old window's count. The net effect on sampling rates over a full window is negligible (<0.1% for typical volumes).

### `sxhash` consistency

The consistent sampler uses `sxhash` for hashing. On SBCL, `sxhash` is deterministic across sessions for strings, symbols, and numbers. The same request-id always produces the same sampling decision, even across process restarts. This is an SBCL property, not a CL spec guarantee — other implementations may randomize `sxhash` seeds.

### Child logger key-fn timing

The consistent sampler's `key-fn` reads `raw-bindings` from the logger struct. These bindings are set at logger creation time (via `child`). If you set up the consistent sampler on a root logger and create request-scoped children, the `key-fn` sees the child's bindings — including `:request-id`. But logging through the root logger directly (without a child) means `key-fn` won't find `:request-id` and falls through to the windowed counter.

**Recourse:** Always log through a request-scoped child when you want consistent sampling. Root-level logs (startup, health checks) fall through to the windowed counter by design.

### Sampling + field transforms

Sampling runs before field transforms. A sampled-out message never reaches the field transform. This is correct (why transform something you're dropping?) but means you cannot use field transforms to influence sampling decisions. Sampling is based solely on the consistent hash and windowed count.

## Recourses

### "I'm losing too many messages"

1. **Check which sampler is dropping.** The consistent sampler drops entire requests; the windowed counter drops individual messages. If you're missing full request traces, lower `consistent.rate`. If you're missing individual debug lines within kept requests, adjust the windowed counter's `initial` and `thereafter`.

2. **Disable sampling for a level.** Pass nil to `set-level-sampling`:
   ```lisp
   (bark:set-level-sampling *logger* :debug nil)
   ```

3. **Use `with-log-buffer` for critical paths.** Buffering bypasses all sampling. Wrap the code path where you need complete logs:
   ```lisp
   (bark:with-log-buffer ()
     (critical-operation))
   ```

### "I'm still getting too many messages"

1. **Increase `consistent.rate`.** This is the coarsest knob — it drops entire request traces.

2. **Add a hard cap.** Set `thereafter=0` on noisy levels:
   ```lisp
   (bark:set-level-sampling *logger* :trace
     (bark:make-windowed-counter :initial 2 :thereafter 0))
   ```

3. **Raise the logger level.** Sampling is not a substitute for level control. If you don't need `:debug` in production, set `:level :info`.

### "Sampling behavior changed after restart"

Both samplers are stateless — they don't persist counters across restarts. The windowed counter starts fresh (first window begins at construction time). The consistent sampler's hash decisions are deterministic for the same key values (on SBCL), so the same request-id gets the same decision.

If behavior seems different, check whether `rate` or `initial`/`thereafter` values changed in configuration.

### "I need to see all logs for a specific request"

Use `with-log-buffer` around the request handler instead of relying on sampling:

```lisp
(bark:with-log-buffer (:level :trace)
  (handle-request request))
```

Or create a child logger with the consistent sampler disabled:

```lisp
(let ((bark:*logger* (bark:child bark:*logger* :request-id rid)))
  (bark:set-consistent bark:*logger* nil)
  (handle-request request))
```

### "I want different sampling per destination"

Sampling is per-logger, not per-destination. Use tee-level filters for per-destination volume control:

```lisp
(bark:start :level :debug
            :output (bark:tee
                     ;; Console: info+ only (no sampling needed)
                     (*error-output* :formatter #'bark:pretty-formatter
                                     :level :info)
                     ;; File: all levels, sampled
                     (log-file :formatter #'bark:json-formatter)))
```

The console gets a clean info+ stream (filtered by level, not sampling). The file gets all levels but with sampling applied.
