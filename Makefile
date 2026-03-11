.PHONY: test load clean

SBCL := sbcl --noinform --non-interactive
LOAD := --eval '(push (truename ".") asdf:*central-registry*)'

test:
	$(SBCL) $(LOAD) \
	  --eval '(asdf:load-system :cl-bark/tests)' \
	  --eval '(let ((r (5am:run (intern "BARK-TESTS" :bark-tests)))) (5am:explain! r) (unless (5am:results-status r) (uiop:quit 1)))'

load:
	$(SBCL) $(LOAD) --eval '(asdf:load-system :cl-bark)'

clean:
	find . -name '*.fasl' -delete
