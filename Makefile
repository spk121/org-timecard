EMACS ?= emacs

.PHONY: test compile clean

test:
	$(EMACS) --batch -Q -L . -l org-timecard-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --batch -Q -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile org-timecard.el

clean:
	rm -f *.elc
