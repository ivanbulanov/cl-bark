# cl-bark Performance Benchmarks

**Environment:** Linux, SBCL 2.6.1, output to `/dev/null`
**Date:** 2026-03-01

## Single-threaded throughput (1M writes, capacity=65536)

| Formatter | Writes/sec |
|-----------|-----------|
| logfmt    | **1,340,000** |
| pretty    | 1,070,000 |
| JSON      | 944,000   |

logfmt is fastest because it avoids JSON string escaping. JSON is ~30% slower.

## Concurrent writers (logfmt, 1M total writes, capacity=65536)

| Threads | Writes/sec | vs. 1-thread |
|---------|-----------|--------------|
| 1       | 1,280,000  | baseline     |
| 2       | 2,640,000  | 2.1×         |
| 4       | **4,330,000** | **3.4× ← peak** |
| 8       | 4,270,000  | 3.3×         |
| 16      | 4,020,000  | 3.1×         |
| 32      | 3,880,000  | 3.0×         |
| 64      | 3,100,000  | 2.4×         |
| 128     | 2,890,000  | 2.3×         |

Scales linearly to 4 threads, then plateaus. The single consumer thread draining the ring to the
output stream is the bottleneck — it tops out around 4.3M/sec. Beyond 4 threads, additional
producers increase CAS contention on the ring head without improving throughput. At 128 threads,
thread scheduling overhead visibly reduces throughput.

## Saturation / drop behavior (capacity=64, 1ms/msg consumer, 8 threads)

```
400,000 attempted
399,867 dropped  (99.97%)
    133 consumed by writer
Producer rate: 5,000,000/sec
```

Drop behavior is correct and clean: `ring-buffer-push` returns `NIL` and increments the `dropped`
counter atomically. No crashes, no blocking producers, no data corruption. The `on-drop` callback
fires per drop for observability. Under total saturation producers still hit 5M+/sec — the ring is
lock-free so producers never wait on the consumer.

## Summary

| Metric | Value |
|--------|-------|
| Peak throughput (4+ threads, fast sink) | ~4.3M writes/sec |
| Single-thread throughput | ~1.3M writes/sec |
| Bottleneck | single consumer thread |
| Under saturation — producer rate | 5M+/sec |
| Under saturation — drop handling | non-blocking, atomic counter |
| Sweet spot for throughput | 4 concurrent writers |
