# Phase 0 fixtures

Minimal, paired fixtures for round-trip tests. Each fixture is a **native**
representation of the same three notes — one as a Logseq graph (`.org` or
`.md`), one as an org-roam directory — related by the shared UUID identity
described in `AGENTS.md` §3–§5.

## Layout

```
fixtures/Work/
  logseq/                  ;; native Logseq graph root  (~/graphs/Work)
    config.edn             ;; Logseq config the sync engine assumes
    pages/
      Project Alpha.org
      Meeting Notes.org
    journals/
      2026-09-30.org
  org-roam/                ;; native org-roam mirror (org-roam-directory/Work)
    pages/
      Project Alpha.org
      Meeting Notes.org
    journals/
      2026-09-30.org
```

The mapping is **1:1 on the relative path within the graph** (AGENTS.md §2):

- `logseq/pages/Project Alpha.org` ↔ `org-roam/pages/Project Alpha.org`
- `logseq/journals/2026-09-30.org` ↔ `org-roam/journals/2026-09-30.org`

Logseq-only artifacts (`assets/`, `logseq/`) are omitted; asset files are
never copied or moved — file links are remapped to point at the Logseq
graph's real `assets/` directory (AGENTS.md §3, §11).

## UUID legend

All UUIDs are deterministic so round-trip tests can assert exact output:

| UUID | Note |
|---|---|
| `10000000-0000-0000-0000-000000000001` | `Project Alpha` |
| `10000000-0000-0000-0000-000000000002` | `Meeting Notes` |
| `10000000-0000-0000-0000-000000000003` | journal `2026-09-30` |

## What each file demonstrates

The fixtures exercise the core v1 scope from AGENTS.md §5:

| Concern | Logseq side | org-roam side |
|---|---|---|
| Identity | `#+id: <uuid>` page property | `:ID: <uuid>` |
| Title | filename slug (`Project Alpha`) | `#+title: Project Alpha` |
| Aliases | `#+alias: Alpha, ProjA` | `:ROAM_ALIASES: "Alpha" "ProjA"` |
| Links | `[[Meeting Notes]]` | `[[id:…-002][Meeting Notes]]` |
| Structure | headline blocks (`*`, `**`) | headings (`*`, `**`) |
| TODO | `TODO` / `DONE` keywords | `TODO` / `DONE` keywords |

Notes:

- Page properties (`id`, `alias`) are written as **org in-buffer settings**
  (`#+id:`, `#+alias:`), matching the org-mode property conventions the
  legacy `logseq-org-roam` parser already reads (`#+alias:`; see
  `logseq-org-roam--parse-first-section-keywords`). Block properties use
  `:PROPERTIES:` drawers. This is the canonical form the Phase 2 Logseq
  parser/writer uses.
- The journal filename/title uses `yyyy-MM-dd` on the Logseq side (see
  `config.edn`) and `%Y-%m-%d` in the sync engine's own config.

## Round-trip contract (AGENTS.md §8)

With no concurrent edits, each note must round-trip to a no-op:

- `logseq → roam → logseq` == original Logseq file
- `roam → logseq → roam` == original org-roam file

Because both sides share the UUID, `[[Meeting Notes]]` →
`[[id:…-002][Meeting Notes]]` → `[[Meeting Notes]]` is lossless.

---

## Markdown fixture

`fixtures/Work-markdown/` mirrors the same three notes as a native Logseq
**Markdown** graph (`pages/*.md`, `journals/*.md`) paired with the same
org-roam mirror as `Work/`:

```
fixtures/Work-markdown/
  logseq/                  ;; native Logseq Markdown graph root
    config.edn             ;; no active :preferred-format "Org"
    pages/
      Project Alpha.md
      Meeting Notes.md
    journals/
      2026-09-30.md
  org-roam/                ;; same org-roam mirror as Work/
    pages/
      Project Alpha.org
      Meeting Notes.org
    journals/
      2026-09-30.org
```

The mapping is 1:1 on the relative path, with the extension changed on the
Logseq side:

- `logseq/pages/Project Alpha.md` ↔ `org-roam/pages/Project Alpha.org`
- `logseq/journals/2026-09-30.md` ↔ `org-roam/journals/2026-09-30.org`

| Concern | Logseq Markdown side | org-roam side |
|---|---|---|
| Identity | `id:: <uuid>` | `:ID: <uuid>` |
| Aliases | `alias:: Alpha, ProjA` | `:ROAM_ALIASES: "Alpha" "ProjA"` |
| Links | `[[Meeting Notes]]` | `[[id:…-002][Meeting Notes]]` |
| Structure | indented list items (`-`, `\t-`) | headings (`*`, `**`) |
| TODO | `TODO` / `DONE` prefix | `TODO` / `DONE` keywords |

The config omits an active `:preferred-format "Org"`, so
`logseq-org-sync-logseq-graph-format` treats it as Markdown.
