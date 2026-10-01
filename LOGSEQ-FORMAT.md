# Logseq graph files — `.org` and `.md` formats

This document describes the subset of Emacs Org syntax and Markdown that
Logseq reads and writes on the Logseq side of the sync.

- `.org` graphs are selected with `:preferred-format "Org"`.
- Markdown graphs are the default (no active `:preferred-format "Org"`
  setting) and use `.md` files.

The behavior below is inferred from Logseq's own source, checked in at
`og/deps/graph-parser/src/logseq/graph_parser/` and
`og/src/main/frontend/`:

- The actual grammar/tokenizer is the external npm package `mldoc`
  (`og/deps/graph-parser/package.json` depends on `mldoc@^1.5.1`).
- `logseq.graph-parser.mldoc` wraps `mldoc`'s JSON API and returns an EDN AST
  (`->edn`), then `logseq.graph-parser.extract` and
  `logseq.graph-parser.block` turn that AST into Logseq's database entities.
- This document therefore describes the *result* of that pipeline — the
  canonical file form — rather than `mldoc`'s internals.

## 1. File / format selection

- Format is chosen from the file extension: `.org` → `:org` (`.md` →
  `:markdown`). See `logseq.graph-parser.util/get-format`.
- The block pattern for org is `*` (`logseq.graph-parser.config/get-block-pattern`).

## 2. Page properties (first section)

Page properties are org **in-buffer settings** written before the first
headline:

```org
#+id: <uuid>          ;; page identity
#+alias: a, b         ;; page aliases (comma-separated)
#+title: Display name ;; optional page display title
#+<other-key>: value  ;; arbitrary page property
```

Notes:

- Logseq's own writers produce `#+key:` lines (`frontend.util.page-property`
  lowercases the key; `frontend.util.property/add-page-properties` uppercases
  it). Org in-buffer settings are case-insensitive, and `org-element` reports
  the key uppercased (e.g. `#+id:` → key `"ID"`).
- `#+alias:` is the canonical key (singular). Aliases are comma-separated.
- `#+title:` is a page property that overrides the page name. Logseq's page
  name resolution order is `title` property → filename → first heading
  (`logseq.graph-parser.extract/get-page-name`).

## 3. Page name from filename

`logseq.graph-parser.util/title-parsing`:

- `:triple-lowbar` filename format: `___` → `/` (namespaces), then URL-decode
  `%XX` sequences.
- legacy format: `.` → `/`, then URL-decode.

## 4. Blocks as headlines

Every block is an Org headline; the `*` count is the **outline nesting depth**:

```org
* block text
** child text
```

Because `*` encodes indentation rather than "large text", Logseq records the
visual heading style separately as a `:heading:` block property (see §5).

## 5. Block properties

Block properties live in the block's own `:PROPERTIES:` drawer:

```org
* TODO block text
:PROPERTIES:
:id: <uuid>          ;; block identity
:heading: 2          ;; visual heading level (true or 1–6), org-only
:custom-key: value
:END:
```

Notes:

- Drawer delimiters are uppercase (`:PROPERTIES:` / `:END:`); property keys
  inside are written lowercase (`:key: value`).
- On read, Logseq normalizes property keys: lowercase, spaces → `-`,
  underscores → `-`. It also aliases `custom_id` / `custom-id` → `id`, and
  `last-modified-at` → `updated-at`
  (`logseq.graph-parser.block/extract-properties`,
  `logseq.graph-parser.property/->new-properties`).
- **Block identity** is the `:id:` property (`custom-id` / `custom_id` are also
  accepted). `get-custom-id-or-new-id` reads `custom-id`, `custom_id`, then
  `id`.

## 6. TODO keywords, planning, tags

- **TODO keyword** on the headline: `TODO`, `DOING`, `NOW`, `LATER`, `DONE`
  (and other Org TODO keywords).
- **Planning lines** immediately under the headline:

  ```org
  * TODO Write report
  SCHEDULED: <2026-10-01 Thu>
  DEADLINE: <2026-10-05 Mon>
  ```

  Logseq keeps `SCHEDULED:` and `DEADLINE:` as separate lines.
- **Headline tags**: `:tag1:tag2:` at end of the headline.
- **Page-level tags**: `#+filetags:` / `#+tags:` are Logseq built-in page
  properties (`filetags` is marked "org-mode only" in
  `logseq.graph-parser.property`).

## 7. Links and references

- **Page link**: `[[Page Name]]` (mldoc `Page_ref`; org-element link type
  `fuzzy`).
- **URL**: `[[https://example.com][Label]]`.
- **Org file link**: `[[file:...][Label]]` (Logseq recognizes
  `\[\[(file:.*)\]\[.+?\]\]`; `logseq.graph-parser.text/org-page-ref-re`).
- **Block reference**: `((block-uuid))` — references the target block's
  `:id:` property.
- **Block embed**: `{{embed ((block-uuid))}}`.
- **Asset / draw links** are special-cased by Logseq:
  - local assets under `assets/` (`local-asset?`)
  - drawings under `draws/` (`draw?`).

## 8. Blocks and environments

Standard Org structure blocks, e.g.:

```org
#+BEGIN_SRC clojure
...
#+END_SRC

#+BEGIN_QUOTE
...
#+END_QUOTE
```

Also used by Logseq: `#+BEGIN_QUERY`, `#+BEGIN_EXPORT`, and other `#+BEGIN_*` /
`#+END_*` pairs.

## 9. Built-in properties

From `logseq.graph-parser.property`:

- **Org-only editable**: `:macro`, `:filetags`.
- **Identity/hidden**: `:id`, `:custom-id`, `:heading`, `:collapsed`,
  `:created-at` (and `:created_at`), `:updated-at` (and `:last-modified-at` /
  `:last_modified_at`), `:background-color` / `:background_color`.
- **Task markers**: `:todo`, `:doing`, `:now`, `:later`, `:done`.
- **Editable/linkable**: `:alias`, `:aliases`, `:tags`, `:title`, `:icon`,
  `:template`, `:template-including-parent`, `:public`, `:filters`,
  `:exclude-from-graph-view`, `:logseq.query/nlp-date`, and others.

## 10. Parsing pipeline (reference)

1. `logseq.graph-parser.mldoc/->edn` — `mldoc` JSON AST → EDN, with
   `directive` nodes (`#+key:`) collected into a synthetic `Properties` node
   (`collect-page-properties`).
2. `logseq.graph-parser.extract/extract` — determines format, parses the AST,
   extracts page properties.
3. `logseq.graph-parser.block/extract-blocks` — headings → block maps:
   id, refs, properties, timestamps, `:block/format`, parent/left.

## 11. Caveats / limitations

- **Priority cookies** (`[#A]`): `org-element` drops text preceding a priority
  cookie from a headline's `:raw-value`; the sync modules do not support them.
- **Block refs/embeds**: the parse/write module preserves `((uuid))` and
  `{{embed ((uuid))}}` verbatim; the reconciler translates them cross-side
  (see `AGENTS.md` §6).
- **Block body**: only a headline's first line round-trips; free text, tables,
  and `#+BEGIN_*` blocks under a heading are dropped (the IR is headline-only).
- **mldoc org support is a subset of Org**, so constructs outside the
  `og/deps/graph-parser/src/logseq/graph_parser/schema/mldoc.cljc` AST are not
  guaranteed to round-trip through Logseq even if Emacs can parse them.
- **Property key case**: Logseq normalizes keys to lowercase on read; the sync
  modules preserve `org-element`'s reported casing (uppercase for in-buffer
  settings), so non-`id`/`alias` page-property keys may change case on
  round-trip.

---

## Markdown format

The Markdown side of the sync (`.md` files) is parsed and written by
`logseq-org-sync-logseq-markdown-*`.  It shares the same IR as the org side and
differs only in on-disk syntax.

### 1. Format selection

- `.md` → Markdown; `.org` → org (`logseq.graph-parser.util/get-format`).
- The sync engine detects the graph format from `config.edn` rather than
  trusting a single extension
  (`logseq-org-sync-logseq-graph-format`).

### 2. Page properties

Page properties are leading `key:: value` lines before the first block:

```md
id:: <uuid>          ;; page identity
alias:: a, b         ;; page aliases (comma-separated)
title:: Display name ;; optional page display title
tags:: a, b          ;; page tags (comma-separated)
<other-key>:: value  ;; arbitrary page property
```

`id`, `alias`/`aliases`, `tags`, and `title` are recognized specially; other
keys are preserved as `:properties`.

### 3. Blocks as indented list items

Every block is an unordered list item; indentation is the outline depth:

```md
- block text
	- child text
```

Logseq's Markdown writer uses tabs for block indentation by default
(`:export/bullet-indentation :tab`); the sync parser also accepts space
indentation.

### 4. Block properties, planning, TODO

Block properties and planning lines are continuation lines indented under
their block:

```md
- TODO Write report
  SCHEDULED: <2026-10-01 Thu>
  DEADLINE: <2026-10-05 Mon>
  id:: <block-uuid>
  custom-key:: value
```

- **TODO markers** are plain text prefixes: `TODO`, `DOING`, `DONE`, `NOW`,
  `LATER`, `CANCELLED`, `WAIT`, etc.
- **Visual headings** are `#`-prefixed text (`- # Heading` or a bare
  `# Heading`).  The sync normalizes these to a `heading` block property, the
  same way the org side stores visual heading levels.

### 5. Links and references

- **Page link**: `[[Page Name]]`.
- **Described page link**: `[Label]([[Page Name]])`.
- **URL**: `[Label](https://example.com)`.
- **Block reference**: `((block-uuid))`.
- **Block embed**: `{{embed ((block-uuid))}}`.
- **Asset / draw links** are special-cased by Logseq (local assets under
  `assets/`, drawings under `draws/`).

The sync extracts page links with the `markdown-inline` tree-sitter grammar
when available (regexp fallback otherwise); block refs and embeds are
preserved verbatim by the parse/write module and translated cross-side by the
reconciler (see `AGENTS.md` §6).

### 6. Sync scope / limitations

- Only the first line of a block, its TODO marker, its `key:: value` block
  properties, and `SCHEDULED:`/`DEADLINE:` lines round-trip through the IR.
  Tables, code fences, and other multi-line block bodies are dropped (matching
  the org parser's headline-only scope).
- Markdown block tags (`#tag`) are preserved verbatim in block text; they are
  not translated into the IR `:tags` field.
