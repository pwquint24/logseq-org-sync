#!/usr/bin/env bash
#
# Convert every file in the Logseq graph's `pages/` and `journals/`
# subdirectories to Org-roam `.org` files, writing the results into a
# freshly created temporary directory and printing that directory's path.
#
# Usage:
#   ./convert-graph.sh [SOURCE_GRAPH_DIR]
#
# If SOURCE_GRAPH_DIR is omitted it defaults to
#   ./Logseq-Demo-Graph-main

set -euo pipefail

# --- Configuration -----------------------------------------------------------

# Resolve the directory containing this script so the filter paths work
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GRAPH_DIR="${1:-$SCRIPT_DIR/Logseq-Demo-Graph-main}"

PANDOC="${PANDOC:-pandoc}"
FILTER_TO_ORG="$SCRIPT_DIR/filters/logseq-to-org.lua"

# Forward translation flags (Logseq MD -> Org-roam ORG); mirrors the Makefile.
FLAGS_TO_ORG=(-f markdown-simple_tables-multiline_tables+mark-superscript
              -t org
              --lua-filter "$FILTER_TO_ORG")

# --- Validation --------------------------------------------------------------

if [[ ! -d "$GRAPH_DIR" ]]; then
  echo "error: source graph directory not found: $GRAPH_DIR" >&2
  exit 1
fi

if [[ ! -f "$FILTER_TO_ORG" ]]; then
  echo "error: Lua filter not found: $FILTER_TO_ORG" >&2
  exit 1
fi

if ! command -v "$PANDOC" >/dev/null 2>&1; then
  echo "error: pandoc not found on PATH" >&2
  exit 1
fi

# --- Fresh temporary output directory ---------------------------------------

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/logseq-org.XXXXXX")"
trap 'echo "error: conversion failed; partial output left in $OUT_DIR" >&2' ERR

mkdir -p "$OUT_DIR/pages" "$OUT_DIR/journals"

# --- Conversion --------------------------------------------------------------

convert_dir() {
  local subdir="$1"
  local src="$GRAPH_DIR/$subdir"

  [[ -d "$src" ]] || return 0

  shopt -s nullglob
  local files=("$src"/*.md)
  shopt -u nullglob

  local f base out
  for f in "${files[@]}"; do
    base="$(basename "$f" .md)"
    out="$OUT_DIR/$subdir/$base.org"
    echo "  $subdir/$(basename "$f") -> $subdir/$base.org"
    "$PANDOC" "${FLAGS_TO_ORG[@]}" "$f" -o "$out"
  done
}

echo "Converting Logseq graph: $GRAPH_DIR"
convert_dir pages
convert_dir journals

trap - ERR

# --- Done --------------------------------------------------------------------

count="$(find "$OUT_DIR" -name '*.org' | wc -l | tr -d ' ')"
echo "Converted $count file(s) into:"
echo "$OUT_DIR"
