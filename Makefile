.POSIX:
.PHONY: all compile test clean purge
.SUFFIXES: .el .elc
.INTERMEDIATE: make-readme-markdown.el

RM = rm -f
EMACS = emacs

# Layout: the legacy one-way converter lives under legacy/, tests under tests/.
LEGACY_DIR = legacy
TESTS_DIR = tests

LISP = logseq-org-roam
SRC = $(LEGACY_DIR)/$(LISP).el
TESTS = $(LEGACY_DIR)/$(LISP)-test.el
BYTEC = $(SRC)c

SYNC_LISP = logseq-org-sync-logseq
SYNC_SRC = $(SYNC_LISP).el
SYNC_TESTS = $(TESTS_DIR)/$(SYNC_LISP)-test.el
SYNC_BYTEC = $(SYNC_SRC)c

SYNC_ROAM_LISP = logseq-org-sync-roam
SYNC_ROAM_SRC = $(SYNC_ROAM_LISP).el
SYNC_ROAM_TESTS = $(TESTS_DIR)/$(SYNC_ROAM_LISP)-test.el
SYNC_ROAM_BYTEC = $(SYNC_ROAM_SRC)c

SYNC_ID_LISP = logseq-org-sync-identity
SYNC_ID_SRC = $(SYNC_ID_LISP).el
SYNC_ID_TESTS = $(TESTS_DIR)/$(SYNC_ID_LISP)-test.el
SYNC_ID_BYTEC = $(SYNC_ID_SRC)c

SYNC_STATE_LISP = logseq-org-sync-state
SYNC_STATE_SRC = $(SYNC_STATE_LISP).el
SYNC_STATE_TESTS = $(TESTS_DIR)/$(SYNC_STATE_LISP)-test.el
SYNC_STATE_BYTEC = $(SYNC_STATE_SRC)c

SYNC_REC_LISP = logseq-org-sync-reconcile
SYNC_REC_SRC = $(SYNC_REC_LISP).el
SYNC_REC_TESTS = $(TESTS_DIR)/$(SYNC_REC_LISP)-test.el
SYNC_REC_BYTEC = $(SYNC_REC_SRC)c

SYNC_SAFETY_LISP = logseq-org-sync-safety
SYNC_SAFETY_SRC = $(SYNC_SAFETY_LISP).el
SYNC_SAFETY_TESTS = $(TESTS_DIR)/$(SYNC_SAFETY_LISP)-test.el
SYNC_SAFETY_BYTEC = $(SYNC_SAFETY_SRC)c

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

# Load path must resolve the sync modules at the root and the legacy modules
# under legacy/.
LOAD_PATH = -L . -L $(LEGACY_DIR)

all: compile

compile: $(BYTEC) $(SYNC_BYTEC) $(SYNC_ROAM_BYTEC) $(SYNC_ID_BYTEC) $(SYNC_STATE_BYTEC) $(SYNC_REC_BYTEC) $(SYNC_SAFETY_BYTEC)

test: $(BYTEC) $(SYNC_BYTEC) $(SYNC_ROAM_BYTEC) $(SYNC_ID_BYTEC) $(SYNC_STATE_BYTEC) $(SYNC_REC_BYTEC) $(SYNC_SAFETY_BYTEC)
	$(BATCH) \
		$(LOAD_PATH) \
		-l $(TESTS) \
		-l $(SYNC_TESTS) \
		-l $(SYNC_ROAM_TESTS) \
		-l $(SYNC_ID_TESTS) \
		-l $(SYNC_STATE_TESTS) \
		-l $(SYNC_REC_TESTS) \
		-l $(SYNC_SAFETY_TESTS) \
		-f ert-run-tests-batch-and-exit

purge: clean
	$(RM) -r $(PKGCACHE)

clean:
	$(RM) $(BYTEC) $(SYNC_BYTEC) $(SYNC_ROAM_BYTEC) $(SYNC_ID_BYTEC) $(SYNC_STATE_BYTEC) $(SYNC_REC_BYTEC) $(SYNC_SAFETY_BYTEC)

legacy/README.md: make-readme-markdown.el $(SRC)
	$(EMACS) -Q --script $< <$(SRC) >$@

make-readme-markdown.el:
	curl -L -o $@ https://raw.github.com/mgalgs/make-readme-markdown/master/make-readme-markdown.el

.el.elc:
	@echo "Compiling $<"
	@$(BATCH) \
		$(LOAD_PATH) \
		-f batch-byte-compile $<
