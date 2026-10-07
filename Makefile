.POSIX:
.PHONY: all compile test test-elisp test-pandoc test-forward test-reverse clean purge
.SUFFIXES: .el .elc

RM = rm -f
EMACS = emacs
PANDOC = pandoc

# Layout: the sync engine modules live at the root, tests under tests/.
TESTS_DIR = tests

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

SYNC_CMD_LISP = logseq-org-sync
SYNC_CMD_SRC = $(SYNC_CMD_LISP).el
SYNC_CMD_TESTS = $(TESTS_DIR)/$(SYNC_CMD_LISP)-test.el
SYNC_CMD_BYTEC = $(SYNC_CMD_SRC)c

SYNC_PD_LISP = logseq-org-sync-pd
SYNC_PD_SRC = $(SYNC_PD_LISP).el
SYNC_PD_BYTEC = $(SYNC_PD_SRC)c

# All modules that make up the sync engine.
SYNC_BYTECS = $(SYNC_BYTEC) $(SYNC_ROAM_BYTEC) $(SYNC_ID_BYTEC) \
	      $(SYNC_STATE_BYTEC) $(SYNC_REC_BYTEC) \
	      $(SYNC_SAFETY_BYTEC) $(SYNC_CMD_BYTEC) $(SYNC_PD_BYTEC)

SYNC_TEST_FILES = $(SYNC_TESTS) $(SYNC_ROAM_TESTS) $(SYNC_ID_TESTS) \
		  $(SYNC_STATE_TESTS) $(SYNC_REC_TESTS) \
		  $(SYNC_SAFETY_TESTS) $(SYNC_CMD_TESTS)

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

# The sync modules live at the root; tests are resolved from there too.
LOAD_PATH = -L .

# Pandoc translation (Logseq Markdown <-> Org-roam)
FILTER_TO_ORG = filters/logseq-to-org.lua
FILTER_TO_MD = filters/org-to-logseq.lua

# Flags for forward translation (Logseq MD -> Org-roam ORG)
FLAGS_TO_ORG = -f markdown-simple_tables-multiline_tables+mark-superscript-implicit_header_references -t org --lua-filter $(FILTER_TO_ORG)

# Flags for reverse translation (Org-roam ORG -> Logseq MD)
FLAGS_TO_MD = -f org -t markdown --lua-filter $(FILTER_TO_MD)

PANDOC_INPUT_DIR = tests-pandoc/inputs
PANDOC_EXPECTED_DIR = tests-pandoc/expected

MD_TESTS = $(wildcard $(PANDOC_INPUT_DIR)/*.md)
ORG_TESTS = $(wildcard $(PANDOC_INPUT_DIR)/*.org)

all: compile

compile: $(SYNC_BYTECS)

test: test-elisp test-pandoc

test-elisp: $(SYNC_BYTECS)
	$(BATCH) \
		$(LOAD_PATH) \
		$(SYNC_TEST_FILES:%= -l %) \
		-f ert-run-tests-batch-and-exit

test-pandoc: test-forward test-reverse

test-forward:
	@echo "Running Forward Translation Tests (MD -> ORG)..."
	@for f in $(MD_TESTS); do \
		base=$$(basename $$f .md); \
		expected=$(PANDOC_EXPECTED_DIR)/$$base.org; \
		actual=$$(mktemp); \
		echo -n "  Testing $$base... "; \
		$(PANDOC) $(FLAGS_TO_ORG) $$f -o $$actual; \
		if [ ! -f $$expected ]; then \
			echo "NEW (creating expected)"; \
			cp $$actual $$expected; \
		elif diff -u $$expected $$actual > /dev/null; then \
			echo "PASS"; \
		else \
			echo "FAIL"; \
			diff -u $$expected $$actual; \
			rm $$actual; exit 1; \
		fi; \
		rm $$actual; \
	done

test-reverse:
	@echo "Running Reverse Translation Tests (ORG -> MD)..."
	@for f in $(ORG_TESTS); do \
		base=$$(basename $$f .org); \
		expected=$(PANDOC_EXPECTED_DIR)/$$base.md; \
		actual=$$(mktemp); \
		echo -n "  Testing $$base... "; \
		$(PANDOC) $(FLAGS_TO_MD) $$f -o $$actual; \
		if [ ! -f $$expected ]; then \
			echo "NEW (creating expected)"; \
			cp $$actual $$expected; \
		elif diff -u $$expected $$actual > /dev/null; then \
			echo "PASS"; \
		else \
			echo "FAIL"; \
			diff -u $$expected $$actual; \
			rm $$actual; exit 1; \
		fi; \
		rm $$actual; \
	done

purge: clean
	$(RM) -r $(PKGCACHE)

clean:
	$(RM) $(SYNC_BYTECS)
	$(RM) $(PANDOC_INPUT_DIR)/*.md.tmp $(PANDOC_INPUT_DIR)/*.org.tmp

.el.elc:
	@echo "Compiling $<"
	@$(BATCH) \
		$(LOAD_PATH) \
		-f batch-byte-compile $<
