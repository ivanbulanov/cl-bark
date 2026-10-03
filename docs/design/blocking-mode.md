# cl-bark Blocking Mode Design

How cl-bark lets a destination wait for buffer space instead of dropping messages: the extra state on `async-output`, the producer and writer handshake, the timeout and shutdown rules, and the alternatives that were rejected. The user-facing reference is [Blocking Mode](../blocking-mode.md) (keywords, callback signature, sizing); the README sections [Backpressure](../../README.md#backpressure) and [Ring Buffer](../../README.md#ring-buffer) describe the surrounding mechanism. This document explains the shape behind them.

## Motivation

The default async path is lossy by design. Callers format a line, push it onto a bounded lock-free ring buffer (`src/ring-buffer.lisp`) and return; one writer thread per destination (`src/writer.lisp`) drains the buffer. When the buffer is full, `ring-buffer-push` counts a drop and the writer later reports the count through `on-drop`. That is the right behaviour for consoles, metrics and debug streams: a slow sink must not stall the application.

Two problems follow for other sinks:

- **Drop-only loses audit messages.** Audit, compliance and billing streams cannot tolerate a missing line. Their producers can tolerate latency but not loss.
- **An unbounded queue hides saturation.** Removing the loss by removing the bound turns a slow sink into unbounded memory growth. The overload stays invisible until the process runs out of memory, which is a less local failure than a bounded wait.

A single global policy fails one group or the other, so both policies exist and the choice is made where the sink is configured.

## Design Summary

| Option | Configuration | Full buffer means | Loss | Caller latency |
|--------|---------------|-------------------|------|----------------|
| Drop (default) | `:blocking nil` | Message dropped, counted in `ring-buffer-dropped`, reported by `on-drop` | Yes, reported by the `on-drop` warning | Never waits |
| Bounded block | `:blocking t` (`:block-timeout` defaults to 5.0) | Caller waits up to the timeout, then the line is given up: `on-block-timeout` runs and `block-dropped` is incremented | Only on timeout or stop, signalled to the callback | Up to `block-timeout` per call |
| Block forever | `:blocking t :block-timeout nil` | Caller waits until space appears or the output stops | None while the writer lives | Unbounded |

Both blocking variants are offered because they answer different failure preferences. A bounded wait caps the damage of a stuck sink or a dead writer and gives the application a hook (`on-block-timeout`) to divert the line. The unbounded wait is for users who prefer hanging to losing a message. The default is bounded so that a dead writer or unresponsive stream cannot hang the application; waiting forever is always an explicit choice.

| Piece | Where | Role |
|-------|-------|------|
| `ring-buffer-offer` | `src/ring-buffer.lisp` | Push that reports fullness without counting a drop |
| Blocking slots on `async-output` | `src/writer.lisp` | Flag, timeout, callback, timeout-drop counter, lock, condition variable |
| `blocking-deliver` | `src/writer.lisp` | Producer side: fast path, then a deadline-bounded wait |
| `broadcast-space-available` | `src/writer.lisp` | Writer side: wake all waiters after every drain cycle |
| `stop-async-output` | `src/writer.lisp` | Wakes waiters so they do not outlive the output |
| `deliver-line` | `src/output.lisp` | Chooses `blocking-deliver` or `ring-buffer-push` per destination |

Blocking is a property of one `async-output`, that is, of one destination. There is no new exported symbol: `:blocking`, `:block-timeout` and `:on-block-timeout` are keywords on `make-logger` (single stream output) and on each destination spec of `make-tee` and `tee`.

## Ring Buffer Support

`ring-buffer-push` and `ring-buffer-offer` are thin wrappers over one inlined routine, `%ring-buffer-try-push`, whose only difference is a `track-drops` argument. The CAS loop reads `head` and `tail`, returns NIL when the occupied size is at least capacity, and otherwise claims the slot by CAS on `head` and stores the value. `ring-buffer-offer` passes `track-drops` as false, so it never touches `ring-buffer-dropped`. `ring-buffer-push` is unchanged in behaviour.

The blocking path retries, and a failed attempt must not look like a loss. With `ring-buffer-push`, every retry would increment `ring-buffer-dropped`, the writer's `emit-drop-warning` would report messages that were never dropped, and monitoring data would be inflated. See Alternatives Considered for the variant that undoes the count. With `offer`, `ring-buffer-dropped` stays zero on a blocking destination; the loss counter that moves is `block-dropped`.

The choice between the two functions is made in `deliver-line` before any ring buffer call. The non-blocking path pays one `blocking-p` test and nothing else.

## State on `async-output`

`async-output` (`src/writer.lisp`) has six slots for blocking mode:

| Slot | Type | Default | Purpose |
|------|------|---------|---------|
| `blocking-p` | `boolean` | `nil` | Selects `blocking-deliver` in `deliver-line` |
| `block-timeout` | `(or double-float null)` | `5.0d0` | Seconds to wait; `nil` means no limit |
| `on-block-timeout` | `(or null function)` | `nil` | Caller-thread callback when a line is given up |
| `block-dropped` | `(unsigned-byte 64)` | `0` | Lines given up by the blocking path (timeout or stop) |
| `space-lock` | `t` | `nil` | Mutex named "bark-space", protecting the wait |
| `space-available` | `t` | `nil` | Condition variable named "bark-space-available" |

`make-async-output` coerces a non-nil `block-timeout` to `double-float`, so integers, single floats and double floats are all accepted and the deadline arithmetic stays in one type.

**Eager creation.** The lock and the condition variable are created in `make-async-output` when `blocking` is true and are `nil` otherwise. A non-blocking output allocates no extra OS resources, and the writer's broadcast is a no-op when the condition variable is `nil`. Lazy creation was rejected; see Alternatives Considered.

`block-dropped` has no exported reader; `async-output-block-dropped` is internal. The signals available to an application are the `on-block-timeout` callback and, for tests and diagnostics, that slot. There is no analogue of the `on-drop` warning for blocking drops.

## Producer Path

`deliver-line` (`src/output.lisp`) delivers a formatted line to an async output. For a blocking output it calls `blocking-deliver`; otherwise it calls `ring-buffer-push` and signals the `notify` semaphore. `emit-to-tee` also goes through `deliver-line`, once per passing destination, so tee destinations get the same treatment as a single output. The branch on `blocking-p` lives in `deliver-line`, not inside the ring buffer, so the ring buffer's CAS path carries no conditional for it.

`blocking-deliver` runs in the calling thread:

1. **Fast path, no lock.** `ring-buffer-offer`. On success it signals `notify` (so the writer wakes without waiting for its 100 ms poll) and returns.
2. **Slow path.** The deadline is computed once, as `monotonic-seconds` plus `block-timeout`, or `nil` when there is no timeout. The caller takes `space-lock` and loops:
   - try `ring-buffer-offer`; on success signal `notify` and return;
   - if `running` is false, leave the loop;
   - compute the remaining time from the fixed deadline; if it is not positive, leave the loop;
   - otherwise `bt:condition-wait` on `space-available` with `:timeout` set to the remaining time (or no timeout).
3. **Give-up path**, after the lock is released: run `on-block-timeout` if present, then `atomics:atomic-incf` on `block-dropped`.

Every wake-up, whether a broadcast, a timeout or a spurious wake-up, goes back to the top of the loop and re-attempts `offer`. Wake-ups are hints; the predicate is the ring buffer itself.

### The `on-block-timeout` contract

- Signature `(lambda (message stream))`: `message` is the formatted line that could not be queued, `stream` is the destination's current stream (`async-output-stream`, which `on-error` may have swapped).
- It runs in the caller thread, after `space-lock` is released, so a slow callback delays only its own caller and no user code runs under cl-bark's lock.
- The return value is ignored. The line is dropped regardless, and `block-dropped` is incremented after the callback returns. The callback cannot accept the message back; it exists for a side effect such as writing to a fallback sink or raising an alert.
- Errors are caught with `handler-case` on `cl:error` and reported on `*error-output*` as `bark on-block-timeout error: ...`; processing continues to the counter. Non-error conditions and non-local exits are not intercepted, and a non-local exit out of the callback skips the `block-dropped` increment.
- The callback also runs when the wait ended because `running` became false (stop or writer exit), not only on a genuine timeout. The name is narrower than the behaviour.
- A callback that logs to the same blocking destination re-enters `blocking-deliver` and can wait a further `block-timeout`.

### Deadline and clock

The deadline is fixed once, before the first wait. Total time inside one log call is therefore bounded by `block-timeout` plus scheduling jitter, even when the producer repeatedly wakes, loses the freed slot to another thread and waits again. A relative timeout on each wait would restart on every retry and would not give that bound.

`monotonic-seconds` is `get-internal-real-time` divided by `internal-time-units-per-second`, returned as a double float. On the SBCL used to check this document (2.6.9) the unit is one microsecond. The Common Lisp standard does not promise that `get-internal-real-time` is monotonic, and the code does not enforce it; the function is monotonic in practice on SBCL.

### Timeout edge values

`block-timeout` is tested for NIL, not for positivity. A value of `0` (coerced to `0.0d0`) makes the deadline equal to the start time: the producer makes one locked offer attempt, finds no remaining time and gives up without waiting. A negative value behaves the same way. `nil` waits indefinitely.

## Writer Path

`writer-loop` waits on the `notify` semaphore for up to 100 ms, drains the ring buffer, forces output, emits any drop warning, signals flush acknowledgments, and then calls `broadcast-space-available`. That last call is unconditional: it runs at the end of every iteration, including iterations that drained nothing.

```lisp
(defun broadcast-space-available (async-output)
  (let ((cv (async-output-space-available async-output)))
    (when cv
      (bt:with-lock-held ((async-output-space-lock async-output))
        (sb-thread:condition-broadcast cv)))))
```

For a non-blocking output the cost is one slot read and one test per iteration. For a blocking output it is one lock round trip and a broadcast, once per writer iteration; the broadcast itself costs tens of nanoseconds, against a cycle of up to 100 ms.

### Handshake

```
Producer (ring full)             space-lock / condvar        Writer thread
------------------------         --------------------        ----------------------
offer -> full
lock space-lock
offer -> full
condition-wait ----------------> waiting (lock released)
                                                             wait on notify (<= 100 ms)
                                                             pop all lines, write, flush
                                                             emit-drop-warning
                                                             signal-flush-acks
                                 <---- lock, broadcast ----- broadcast-space-available
wake, relock
offer -> success
signal notify, unlock
                                                             (next cycle writes the line)
```

### Why the broadcast takes the lock

A producer holds `space-lock` from its failed `offer` until `condition-wait` atomically releases it. A broadcast that must acquire the same lock cannot fall between the failed attempt and the wait, so a wake-up cannot be lost in that gap. `test-broadcast-under-lock-no-lost-wakeup` is the stress test for this property. The offers themselves are lock-free; the lock is a rendezvous for the wait, not a guard on the ring buffer.

### Why broadcast and not notify

A drain usually frees many slots at once. With `condition-notify`, one waiter wakes per drain batch, so the remaining waiters would wait for later cycles: a convoy whose latency grows with the number of blocked producers times the drain cycle. With `condition-broadcast`, all waiters wake, serialize on the mutex and each tries its offer; with as many free slots as waiters, all succeed in one round. The contention among them costs nanoseconds per attempt against a drain cycle measured in tens of milliseconds. Broadcast is also what stop needs, since every waiter must be released.

### Why every iteration

Broadcasting only after iterations that drained entries was rejected. The writer could drain and broadcast before a producer has entered `condition-wait`, and that producer would then sleep until the next drain cycle or its timeout. Broadcasting every iteration bounds the time a waiting producer sleeps through a state change to one writer cycle, at the cost described above.

## Lock Ordering

Two mutexes exist on an `async-output`:

| Lock | Protects | Held by |
|------|----------|---------|
| `flush-lock` | The `flush-acks` list | Flushing threads while pushing an ack; the writer while collecting acks |
| `space-lock` | The condition-variable wait | Blocked producers during the wait; the writer and the stopping thread during a broadcast |

They guard unrelated state and are never held together. A producer holds `space-lock` only inside `blocking-deliver`, which never calls flush. The writer takes `flush-lock` inside `signal-flush-acks` and releases it before calling `broadcast-space-available`. `stop-async-output` calls `flush-async-output` (taking `flush-lock`) and later `broadcast-space-available` (taking `space-lock`); the two are sequential. The `on-block-timeout` callback runs after `space-lock` is released. Because no path nests the two locks, no ordering between them is needed.

## Stop and Shutdown

`stop-async-output` proceeds in this order:

1. `flush-async-output`, which drains what is queued.
2. Set `running` to nil.
3. `broadcast-space-available`, so blocked producers wake before the writer is joined.
4. Signal `notify` and join the writer thread.
5. A second broadcast, to catch producers that entered the wait after the first one.
6. A final drain of the ring buffer on the stopping thread; stream errors are ignored.

A woken producer first retries `offer`, and only when the buffer is still full does it see `running` false and take the give-up path. A producer blocked at stop time therefore ends in one of two ways: its line is queued and written by the writer's last cycle or the final drain, or it is dropped through the callback and `block-dropped`. It is not left waiting. `test-stop-unblocks-waiting-producers`, `test-stop-wakes-producers-before-join` and `test-concurrent-stop-with-blocked-producers` check that producers with `block-timeout` nil return promptly.

The first broadcast comes before the join so that blocked producers are released immediately rather than after the writer has exited; `test-stop-wakes-producers-before-join` asserts this with a one second bound.

`stop-async-output` does nothing when `running` is already false, so stop is idempotent.

### Known limits

- **Fast path ignores `running`.** A producer arriving after the final drain, with room in the buffer, succeeds at the fast-path `offer`; its line is never written and not counted. The same holds for non-blocking outputs. Callers are expected not to log to a logger they have stopped.
- **Writer death.** When the writer exits because of a stream error (no `on-error` hook, a hook that fails, or a hook that returns nil), `handle-stream-error` sets `running` to nil. The iteration still reaches `broadcast-space-available`, so producers already waiting wake, see `running` false and give up at once instead of waiting out the timeout. Producers that arrive later with a full buffer also give up on their first locked attempt. Producers that arrive while there is room still queue lines nobody drains, and a later `bark:stop` is a no-op because `running` is already false. Only a writer that disappears without clearing `running` (for example a killed thread) leaves producers to rely on the timeout, and with `block-timeout` nil they wait forever.
- **`flush` guarantee.** `flush-async-output` waits up to five seconds for an acknowledgment the writer signals during an iteration. It uses its own semaphore and does not depend on `space-available`, so producers that keep refilling the buffer cannot postpone it. It promises that the writer completed a cycle after the request, not that the buffer is empty on return.

## Edge Cases

| Case | Behaviour |
|------|-----------|
| Capacity 1 | `make-ring-buffer` rounds capacity up to a power of two with a minimum of 16 (`+min-ring-capacity+`), so the smallest ring holds 16 lines |
| `:block-timeout 0` | One locked offer attempt, then give up; no wait |
| `:block-timeout nil` | Waits until space appears or `running` becomes false |
| Many waiters, few slots | All wake on a broadcast and serialize on `space-lock`; the first ones succeed, the rest wait for the next cycle. Throughput is bounded by the writer's drain rate, which is the intended backpressure |
| Spurious wake-up | Harmless; the producer retries `offer` and re-checks `running` and the deadline |
| Slow `on-error` handler | Runs on the writer thread, so it stalls the drain and lengthens producer waits |

Fairness is not guaranteed. The fast-path `offer` takes no lock, so a newly arriving producer can take a freed slot ahead of a waiter, and waiters acquire `space-lock` in no defined order. A waiter can be starved until its deadline.

## Alternatives Considered

### Counting semaphore instead of a condition variable

Rejected for three reasons:

1. *Lost wakeups.* A semaphore signal is consumed by whichever waiter returns, whether or not it then wins the CAS for a slot. A woken producer that loses the race wastes the signal while other waiters see none, although space exists.
2. *No broadcast.* On stop, one signal frees one waiter. With N blocked producers and `block-timeout` nil, N minus one would hang.
3. *Count drift.* Non-blocking producers consume slots without consuming signals, so the semaphore count diverges from real free space.

A mutex and condition variable with the ring buffer as the predicate avoids all three: the wait re-checks the predicate on every wake-up, broadcast wakes every waiter, and spurious wake-ups only cause a retry.

### Reusing `ring-buffer-push` and compensating the drop counter

Rejected. `ring-buffer-push` increments `ring-buffer-dropped` on a full buffer, which would produce spurious drop warnings and inflated monitoring data, since the blocking path retries rather than drops. Undoing the increment with `atomic-decf` races with the writer's read-and-reset of the counter in `emit-drop-warning`: the writer can reset between the increment and the decrement, and the decrement then wraps the unsigned counter. A separate operation that never increments (`ring-buffer-offer`), selected before the call, removes the problem instead of patching it.

### `condition-notify` instead of `condition-broadcast`

Rejected for the convoy reason given in Writer Path. It would also release only one waiter per stop-time wake-up.

### Broadcast only when entries were drained

Rejected; see Writer Path. The saving is one lock round trip per cycle, and the cost is a producer that can sleep through the only broadcast it needed.

### Lazy, CAS-based creation of the lock and condition variable

Rejected in favour of eager creation, to avoid the complexity and portability pitfalls of lazy CAS-based creation (memory ordering on ARM64, spin loops). Eager creation moves the cost to `make-async-output` and leaves both slots `nil` when blocking is off.

### Timeout designs

| Design | Outcome |
|--------|---------|
| Relative timeout on each wait | Rejected. A producer that repeatedly wakes and loses the race restarts the clock, so one log call can exceed the configured limit |
| Single deadline, computed once | Adopted. Total time in one call is bounded by `block-timeout` plus jitter |
| Default `nil` (wait forever) | Rejected. Pathological hangs (dead writer, unresponsive stream) would stall the application by default |
| Default 5.0 seconds, `nil` as the explicit opt-in | Adopted. `nil` is for users who prefer hanging to losing a message |

### Configuration level

| Level | Outcome |
|-------|---------|
| Per logger | Rejected. One logger can fan out to a console that must never stall and an audit file that must not lose lines |
| Per tee, applied to all destinations | Rejected and made an error: `make-logger` signals `bark-configuration-error` (with a `use-value` restart) when `:blocking`, `:block-timeout` or `:on-block-timeout` accompanies a tee output, because each destination should block or drop independently |
| Per destination | Adopted. Each destination owns its ring buffer, writer, counters and callback |

The `make-logger` check uses a supplied-p variable for `:block-timeout`. A check written against the value cannot detect an explicit `:block-timeout`, because the default is 5.0.

### Where the blocking logic lives

| Location | Outcome |
|----------|---------|
| Inside `ring-buffer-push` | Rejected. `ring-buffer-push` stays untouched so the happy CAS path has no added overhead |
| `deliver-line` and `emit-to-tee`, branching on `blocking-p` and using `ring-buffer-offer` as the primitive | Adopted. The blocking path is explicit and `ring-buffer-push` is unchanged |

## Invariants and Trade-offs

Invariants:

- A blocking destination never increments `ring-buffer-dropped`, so it never produces an `on-drop` warning. Its losses are counted in `block-dropped`.
- A line passed to `blocking-deliver` is either queued once or given up once (callback, then counter). The exception is a non-local exit from the callback, which skips the counter.
- One log call waits no longer than `block-timeout` plus scheduling jitter when the timeout is non-nil.
- A producer re-checks the ring buffer, `running` and the deadline after every wake-up; no path relies on a wake-up having a particular cause.
- The two locks are never nested, and no user code runs under `space-lock`.
- With blocking off, the lock and condition variable are `nil` and the added costs are one `blocking-p` test per push and one `nil` test per writer iteration.

Trade-offs:

- Latency is traded for completeness. A saturated blocking destination makes callers wait; sustained throughput equals the writer's drain rate.
- Deadlock risk exists when the writer's own work logs to the same blocking destination (a stream whose write path logs, or an `on-error` handler that logs): the writer becomes a producer waiting for itself and recovers only through the timeout, never with `nil`. The same holds for a lock a producer holds that the sink path also needs.
- Priority inversion: a producer waits on a writer thread and on whatever the sink depends on.
- Wake-up cost is proportional to the number of waiters per cycle. With N concurrent producers a capacity of at least 2N keeps retries rare (see the [user guide](../blocking-mode.md)).
- The ring buffer's payload slots rely on x86 store ordering (README, "Ring Buffer"). The blocking path adds mutex and condition-variable operations and no new reliance on that assumption.

## Interactions

| Feature | Interaction |
|---------|-------------|
| Tee | Blocking is per destination. `emit-to-tee` delivers sequentially, so a blocked destination delays every later destination in the same call, and a mixed tee can deliver a line to one destination and drop it for another. A tee with any blocking destination is effectively blocking for the caller. `block-dropped`, the callback and the timeout are per `async-output`, so a loss is attributable to one destination. Formatter grouping is unaffected: the line is formatted once per group and delivered to each passing destination in turn. See [multi-output.md](multi-output.md) |
| Request-scoped buffering | `with-log-buffer` replays entries on flush through `emit-entry` and `dispatch-to-output` on the root logger's output. A flush of many entries into a blocking destination can exceed capacity at once, so the replay waits for drain cycles, each entry possibly up to `block-timeout`, and the code leaving the buffer scope waits with it. Entries given up during the replay are dropped like any other blocking drop. See [request-scoped-buffering.md](request-scoped-buffering.md) |
| Sampling | Sampling runs in the log function before dispatch. Lines it discards never reach `deliver-line`, so they are neither queued nor counted as blocking drops. Sampling intentionally drops messages and defeats the guarantee blocking mode provides; the README (Feature Interactions) advises against combining them on one logger. Inside `with-log-buffer` sampling is bypassed. See [sampling.md](sampling.md) |
| `flush` | Independent of the condition variable. `bark:flush` calls `flush-async-output` per running async output and signals `bark-async-stopped` for stopped ones. A producer blocked on a full buffer does not stop a flush from completing |
| `stop` | Wakes blocked producers twice, before and after the join; see Stop and Shutdown |
| `on-drop` | Never fires for a blocking destination, since `ring-buffer-dropped` stays zero |
| `on-error` | Runs on the writer thread; a slow handler lengthens producer waits, and a handler that returns nil clears `running`, after which waiting producers give up |
| Function output | Synchronous, no ring buffer; blocking keywords with a function output signal `bark-configuration-error` |

## Tests

`tests/blocking-tests.lisp` (FiveAM suite `blocking-tests`) covers:

- Ring buffer: `test-ring-buffer-offer-success`, `test-ring-buffer-offer-full-returns-nil`, `test-ring-buffer-offer-does-not-increment-dropped`.
- Clock: `test-monotonic-seconds-returns-positive-double`, `test-monotonic-seconds-monotonic`.
- Slots and defaults: `test-async-output-blocking-slots-default-nil`, `test-async-output-blocking-slots-created`, `test-async-output-custom-timeout`, `test-async-output-nil-timeout`, `test-async-output-on-block-timeout-stored`.
- Push behaviour: `test-blocking-push-succeeds-when-space-available`, `test-blocking-push-waits-for-space`, `test-blocking-push-timeout-fires`, `test-blocking-push-timeout-callback`, `test-blocking-push-callback-error-caught`, `test-nonblocking-path-unchanged`, `test-ring-buffer-dropped-not-inflated-by-blocking`.
- Tee: `test-tee-blocking-destination-delivers`, `test-tee-mixed-blocking-nonblocking`, `test-tee-partial-delivery-on-timeout`.
- Writer and stop: `test-writer-broadcasts-after-drain`, `test-stop-unblocks-waiting-producers`, `test-stop-wakes-producers-before-join`, `test-concurrent-stop-with-blocked-producers`.
- `make-logger` integration: `test-start-with-blocking`, `test-start-blocking-with-tee-signals-error`, `test-start-block-timeout-with-tee-signals-error`, `test-start-on-block-timeout-with-tee-signals-error`, `test-start-blocking-end-to-end`.
- Concurrency: `test-concurrent-producers-no-drops`, `test-concurrent-producers-wake-within-one-drain`, `test-broadcast-under-lock-no-lost-wakeup`.

The timeout tests use a 10 ms timeout, below the writer's 100 ms poll, so they depend on the writer not draining within that interval. Not covered: `:block-timeout 0`, the writer-exit-on-error path, a producer arriving after `stop`, and sampling or `with-log-buffer` combined with blocking.

## Non-Goals

- **Blocking for synchronous loggers.** Function outputs have no buffer to wait on.
- **A per-logger or per-call mode.** Policy is per destination.
- **Detecting or restarting a dead writer.** The timeout and the `running` flag are the only safety nets.
- **An `on-drop` equivalent for blocking drops.** The callback and the `block-dropped` slot are the interface; there is no inline warning and no exported counter reader.
- **Fairness or FIFO ordering among waiters.** Producers retry opportunistically.
- **Guaranteeing delivery after `stop`.** Logging to a stopped logger is outside the contract.
- **Combining with sampling.** The two features pull in opposite directions and no interaction is designed.
