# Makefile for pandoc-translate

PANDOC = pandoc
FILTER_TO_ORG = filters/logseq-to-org.lua
FILTER_TO_MD = filters/org-to-logseq.lua

# Flags for forward translation (Logseq MD -> Org-roam ORG)
FLAGS_TO_ORG = -f markdown-simple_tables-multiline_tables+mark-superscript-implicit_header_references -t org --lua-filter $(FILTER_TO_ORG)

# Flags for reverse translation (Org-roam ORG -> Logseq MD)
FLAGS_TO_MD = -f org -t markdown --lua-filter $(FILTER_TO_MD)

INPUT_DIR = tests-pandoc/inputs
EXPECTED_DIR = tests-pandoc/expected

# Test files
MD_TESTS = $(wildcard $(INPUT_DIR)/*.md)
ORG_TESTS = $(wildcard $(INPUT_DIR)/*.org)

.PHONY: all test test-forward test-reverse clean

all: test

test: test-forward test-reverse

test-forward:
	@echo "Running Forward Translation Tests (MD -> ORG)..."
	@for f in $(MD_TESTS); do \
		base=$$(basename $$f .md); \
		expected=$(EXPECTED_DIR)/$$base.org; \
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
		expected=$(EXPECTED_DIR)/$$base.md; \
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

clean:
	rm -f tests-pandoc/inputs/*.md.tmp tests-pandoc/inputs/*.org.tmp
