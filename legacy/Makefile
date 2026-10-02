.POSIX:
.PHONY: all compile test clean purge readme
.SUFFIXES: .el .elc
.INTERMEDIATE: make-readme-markdown.el

RM = rm -f
EMACS = emacs

# The legacy one-way Logseq -> org-roam converter is self-contained in this
# directory.  Run these targets from within legacy/ (or `make -C legacy ...`).
LISP = logseq-org-roam
SRC = $(LISP).el
TESTS = $(LISP)-test.el
BYTEC = $(SRC)c

# Modules that make up the package; `logseq-org-roam.el' aggregates them.
MODULES = $(LISP)-core.el \
	  $(LISP)-parser.el \
	  $(LISP)-inventory.el \
	  $(LISP)-dict.el \
	  $(LISP)-updater.el \
	  $(LISP)-create.el

# Should pull the following dependencies:
REQS := org-roam mocker

PKGCACHE := $(abspath $(PWD)/package-cache)

# INIT_PACKAGE_EL from package-lint (https://github.com/purcell/package-lint)
# by Steve Purcell (https://github.com/purcell)
INIT_PACKAGE_EL := "(progn \
  (require 'package) \
  (setq package-user-dir \"$(PKGCACHE)\") \
  (setq package-archives \
	'((\"gnu\" . \"https://elpa.gnu.org/packages/\") \
	  (\"nongnu\" . \"https://elpa.nongnu.org/nongnu/\") \
      (\"melpa-stable\" . \"https://stable.melpa.org/packages/\"))) \
  (package-initialize) \
  (unless package-archive-contents \
     (package-refresh-contents)) \
  (dolist (pkg '($(REQS))) \
    (unless (package-installed-p pkg) \
      (package-install pkg))))"

BATCH = $(EMACS) -Q --batch --eval $(INIT_PACKAGE_EL)

# Everything is resolved relative to this directory.
LOAD_PATH = -L .

all: compile

compile: $(BYTEC)

test: $(BYTEC)
	$(BATCH) \
		$(LOAD_PATH) \
		-l $(TESTS) \
		-f ert-run-tests-batch-and-exit

readme: README.md

README.md: make-readme-markdown.el $(SRC)
	$(EMACS) -Q --script $< <$(SRC) >$@

make-readme-markdown.el:
	curl -L -o $@ https://raw.github.com/mgalgs/make-readme-markdown/master/make-readme-markdown.el

purge: clean
	$(RM) -r $(PKGCACHE)

clean:
	$(RM) $(BYTEC) $(MODULES:.el=.elc)

.el.elc:
	@echo "Compiling $<"
	@$(BATCH) \
		$(LOAD_PATH) \
		-f batch-byte-compile $<
