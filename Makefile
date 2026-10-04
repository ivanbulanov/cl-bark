.PHONY: test test-blocking test-concurrent load clean docs \
        bench bench-quick bench-full bench-internal bench-comparative \
        bench-update-sample

SBCL := sbcl --noinform --non-interactive
LOAD := --eval '(push (truename ".") asdf:*central-registry*)'

# Benchmark parameters (override on command line: make bench ITERATIONS=50000)
ITERATIONS            ?= 10000
WARMUP                ?= 10000
THREADS               ?= 8
CONCURRENT_ITERATIONS ?= 100000
SUITE                 ?=
SCENARIO              ?=

test:
	$(SBCL) $(LOAD) \
	  --eval '(asdf:load-system :cl-bark/tests)' \
	  --eval '(let ((r (5am:run (intern "BARK-TESTS" :bark-tests)))) (5am:explain! r) (unless (5am:results-status r) (uiop:quit 1)))'

test-blocking:
	$(SBCL) $(LOAD) \
	  --eval '(asdf:load-system :cl-bark/tests)' \
	  --eval '(let ((r (5am:run (intern "BLOCKING-TESTS" :bark-blocking-tests)))) (5am:explain! r) (unless (5am:results-status r) (uiop:quit 1)))'

test-concurrent:
	$(SBCL) $(LOAD) \
	  --eval '(asdf:load-system :cl-bark/concurrency-tests)' \
	  --eval '(let ((r (5am:run (intern "SAMPLING-CONCURRENCY-TESTS" :bark-concurrency-tests)))) (5am:explain! r) (unless (5am:results-status r) (uiop:quit 1)))'

load:
	$(SBCL) $(LOAD) --eval '(asdf:load-system :cl-bark)'

docs:
	@rm -rf docs/api/
	$(SBCL) $(LOAD) \
	  --eval '(ql:quickload "staple" :silent t)' \
	  --eval '(asdf:load-system :cl-bark)' \
	  --eval '(staple:generate :cl-bark :output-directory #p"docs/api/" :if-exists :supersede :subsystems nil)'
	@python3 docs/fix-staple.py docs/api/index.html
	@echo "Generated docs/api/index.html"

# ASDF caches FASLs under $XDG_CACHE_HOME/common-lisp (default ~/.cache).
# Honour the override so `XDG_CACHE_HOME=... make clean` clears the same
# cache that `XDG_CACHE_HOME=... make test` populated.
CL_CACHE ?= $(or $(XDG_CACHE_HOME),$(HOME)/.cache)/common-lisp

clean:
	find . -name '*.fasl' -delete
	rm -rf $(CL_CACHE)/sbcl-*/$(CURDIR)/

# --- Benchmarks ---

BENCH_LOAD := --eval '(asdf:load-system :cl-bark/bench-comparative)'
BENCH_ARGS = :iterations $(ITERATIONS) :warmup $(WARMUP) \
             :threads $(THREADS) :concurrent-iterations $(CONCURRENT_ITERATIONS)

# Conditional args: only passed when set
ifneq ($(SUITE),)
  BENCH_SUITE = :suite :$(SUITE)
endif
ifneq ($(SCENARIO),)
  BENCH_SCENARIO = :scenario "$(SCENARIO)"
endif

bench:
	$(SBCL) $(LOAD) $(BENCH_LOAD) \
	  --eval '(bark-bench:run $(BENCH_SUITE) $(BENCH_SCENARIO) $(BENCH_ARGS))'

bench-quick:
	$(MAKE) bench ITERATIONS=1000 WARMUP=1000 CONCURRENT_ITERATIONS=10000

bench-full:
	$(MAKE) bench ITERATIONS=50000 WARMUP=10000 CONCURRENT_ITERATIONS=100000

bench-internal:
	$(MAKE) bench SUITE=internal

bench-comparative:
	$(MAKE) bench SUITE=comparative

bench-update-sample:
	@echo "Sample results — run on your hardware for your numbers" > bench/results/sample.txt
	@echo "Machine: $$(uname -m)" >> bench/results/sample.txt
	@echo "CL: $$($(SBCL) --eval '(format t "~a ~a" (lisp-implementation-type) (lisp-implementation-version))' --eval '(uiop:quit)')" >> bench/results/sample.txt
	@echo "Date: $$(date +%Y-%m-%d)" >> bench/results/sample.txt
	@echo "Iterations: 1000 (reduced for sample; default is 10000)" >> bench/results/sample.txt
	@echo "Sample batch size: 100 (per-call estimates derived from 100-call batches)" >> bench/results/sample.txt
	@echo "Timer: CFFI clock_gettime(CLOCK_MONOTONIC), nanosecond resolution" >> bench/results/sample.txt
	@echo "" >> bench/results/sample.txt
	@$(MAKE) --no-print-directory bench-quick 2>&1 \
	  | grep -v '^;' | grep -v 'note:' | grep -v 'unable' | grep -v 'due to' \
	  | grep -v 'because' | grep -v 'Upgraded' | grep -v 'optimize' \
	  | grep -v 'wrote ' | grep -v 'compil' | grep -v 'printed' \
	  | grep -v 'WARNING:' | grep -v 'undefined function' \
	  | grep -v 'Undefined function' | grep -v 'caught ' | grep -v 'BABEL' \
	  | grep -v '^make' | grep -v '^sbcl ' | grep -v '^  --eval' \
	  | sed '/^$$/N;/^\n$$/d' \
	  >> bench/results/sample.txt
	@echo "Updated bench/results/sample.txt"
