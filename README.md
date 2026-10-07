# LOGSEQ-ORG-SYNC

`logseq-org-sync` is an Emacs Lisp package with two related features:

- **Two-way sync** between a **Logseq `.org` graph** and an
  **org-roam directory**. Changes made on either side propagate to the
  other without clobbering concurrent work, and every note keeps one
  stable identity on both sides.
- **Pandoc import/export** between a **Logseq Markdown graph** and an
  org-roam directory. This is a one-shot, batch conversion (not a live
  sync), backed by Pandoc and two Lua filters.

The sync engine only handles Logseq org graphs. Logseq Markdown graphs
are no longer synced; they are imported and exported through the pandoc
backend instead.

The full architecture is in `AGENTS.md`; the on-disk formats are in
`LOGSEQ-FORMAT.org` and `ORG-ROAM-FORMAT.org`; the pandoc import/export
design is in `PANDOC-TRANSLATE.md`.

The whole thing is vibe coded using deepseek and ECA.

## Installation

The package is pure Emacs Lisp, so you only need the `.el` files on your
`load-path`. There is no build step and no non-Elisp runtime dependency.
Pandoc is required only for Markdown import/export. The examples below
install straight from GitHub with
[straight.el](https://github.com/radian-software/straight.el);
`(require 'logseq-org-sync)` pulls in the rest of the `.el` files in the
package.

### Vanilla Emacs (straight.el)

``` emacs-lisp
(straight-use-package
 '(logseq-org-sync :type git
                   :host github
                   :repo "pwquint24/logseq-org-sync"
                   :files ("*.el" "filters/*")))

(require 'logseq-org-sync)
```

The `:files` selector installs the compiled sources and the pandoc Lua
filters, and skips the demo graphs, fixtures, tests, and legacy
converter. If you also want the test suite and fixtures locally, use the
default file set instead:

``` emacs-lisp
(straight-use-package
 '(logseq-org-sync :type git
                   :host github
                   :repo "pwquint24/logseq-org-sync"))
```

### Doom Emacs

Doom already ships straight, so declare the package in `packages.el`:

``` emacs-lisp
(package! logseq-org-sync
  :recipe (:host github
           :repo "pwquint24/logseq-org-sync"
           :files ("*.el" "filters/*")))
```

Then run `doom sync` and add the `(require 'logseq-org-sync)` (or the
`use-package!` form below) to your `config.el`:

``` emacs-lisp
(use-package! logseq-org-sync
  :commands (logseq-org-sync
             logseq-org-sync-here
             logseq-org-sync-all
             logseq-org-sync-watch))
```

To keep the full checkout (tests and fixtures included), drop the
`:files` key from the recipe:

``` emacs-lisp
(package! logseq-org-sync
  :recipe (:host github :repo "pwquint24/logseq-org-sync"))
```

### Manual (load-path)

If you would rather not use a package manager, clone the repository and
put it on your `load-path`:

``` emacs-lisp
(add-to-list 'load-path "/path/to/logseq-org-sync")
(require 'logseq-org-sync)
```

## TL;DR — sync a Logseq org graph

1.  Install the package (see [Installation](#installation)) and
    `(require 'logseq-org-sync)`.

2.  Add a graph by picking its Logseq folder:

    ``` emacs-lisp
    M-x logseq-org-sync-add-graph
    ```

    This derives the graph name from the folder basename and mirrors it
    into `<logseq-org-sync-roam-directory>/<name>`.
    `logseq-org-sync-roam-directory` defaults to `org-roam-directory`
    when org-roam is loaded. Only Logseq org graphs can be added for
    sync; Markdown graphs are rejected with a pointer to import/export.

3.  Sync it:

    ``` emacs-lisp
    M-x logseq-org-sync            ;; pick a graph, preview, apply
    M-x logseq-org-sync-here       ;; sync the graph of the current buffer
    M-x logseq-org-sync-all        ;; sync every configured graph
    ```

4.  (Optional) sync automatically on save:

    ``` emacs-lisp
    (add-hook 'after-save-hook #'logseq-org-sync-after-save)
    ```

    and watch for changes made by the Logseq app:

    ``` emacs-lisp
    M-x logseq-org-sync-watch      ;; choose a graph
    M-x logseq-org-sync-unwatch    ;; stop
    ```

## TL;DR — import/export a Logseq Markdown graph

These use Pandoc and require org-roam (for identity/link resolution).
They live in `logseq-org-sync-pd.el`, which is not loaded by
`(require 'logseq-org-sync)`; load it explicitly first:

``` emacs-lisp
(require 'logseq-org-sync-pd)
```

``` emacs-lisp
M-x logseq-org-sync-pd-import-directory
;;   source: a Logseq Markdown graph (contains pages/ and journals/)
;;   target: an org-roam subdirectory to write .org files into

M-x logseq-org-sync-pd-export-directory
;;   source: an org-roam subdirectory (contains pages/ and journals/)
;;   target: a directory to write Logseq Markdown .md files into
```

Both preserve the `pages/` and `journals/` layout. Import resolves
fuzzy page links to `id:` links after `org-roam-db-sync`; export
restores file-level `id:` links to page links before conversion.

## Requirements

- Emacs with Org. The sync engine uses `org-element`, `org-id`, and
  `file-notify`.
- org-roam is **not** required to run the sync engine or its tests. The
  org-roam side is read and written directly; org-roam is only relevant
  as the place where the mirror lives and as the tool that indexes the
  result.
- Markdown import/export requires `pandoc` on `PATH` and the two Lua
  filters in `filters/`. Link resolution/restoration also requires
  org-roam.

## Graph configuration

Graphs live in the `logseq-org-sync-graphs` user option. Each entry only
needs a name and a Logseq org folder; the org-roam mirror directory is
derived.

``` emacs-lisp
(setq logseq-org-sync-roam-directory "~/org-roam")

(setq logseq-org-sync-graphs
      '((:name "Work"     :logseq-root "~/graphs/Work")
        (:name "Personal" :logseq-root "~/graphs/Personal")))
```

With the configuration above:

- `~/graphs/Work` mirrors into `~/org-roam/Work`
- `~/graphs/Personal` mirrors into `~/org-roam/Personal`

Each mirror contains the same `pages/` and `journals/` subtrees as its
Logseq graph. The mapping is 1:1 on the relative path within a graph;
both sides use `.org`.

**Per-graph keys** (all optional except `:name` and `:logseq-root`):

- `:roam-root` defaults to `<logseq-org-sync-roam-directory>/<name>`.
- `:pages-directory` defaults to `pages`.
- `:journals-directory` defaults to `journals`.
- `:state-file` defaults to
  `<logseq-org-sync-state-directory>/<name>.plist`.

**Format**

The sync only supports Logseq graphs whose `config.edn` selects the org
format (`:preferred-format "Org"`). `logseq-org-sync-add-graph` checks
this and refuses Markdown graphs; use import/export for those.

## Commands

### Sync

- `logseq-org-sync` chooses a graph, shows a dry-run preview, and
  applies it (asking only before moves or deletes).
- `logseq-org-sync-here` syncs the graph containing the current
  buffer's file (on either side).
- `logseq-org-sync-dry-run` previews a graph's plan without writing
  anything.
- `logseq-org-sync-run` is a non-interactive sync; it forces newest-wins
  so it never prompts.
- `logseq-org-sync-all` non-interactively syncs every configured graph.
- `logseq-org-sync-rebuild-state` deletes and rebuilds a graph's state
  cache from the files currently on disk (no note files are written).
- `logseq-org-sync-add-graph` picks a Logseq org folder, derives the
  name and mirror, and saves the config.
- `logseq-org-sync-remove-graph` chooses a graph and stops syncing it
  (files are left in place).
- `logseq-org-sync-watch` watches a graph for external changes and
  re-syncs (debounced).
- `logseq-org-sync-unwatch` stops watching a graph (or all graphs).
- `logseq-org-sync-after-save` is an `after-save-hook` function that
  syncs the graph of the saved file.

### Pandoc import/export

- `logseq-org-sync-pd-import-directory` imports a Logseq Markdown graph
  directory into an org-roam subdirectory.
- `logseq-org-sync-pd-export-directory` exports an org-roam subdirectory
  to a Logseq Markdown directory.
- `logseq-org-sync-pd-import-files` / `logseq-org-sync-pd-export-files`
  are the underlying file-list primitives.

## How the two graphs are translated

Both sync sides read into a common **intermediate representation** (IR)
and write from it. This makes translation symmetric and testable:

``` emacs-lisp
(node :id "uuid"
      :title "Foo"
      :aliases ("a" "b")
      :tags ("a" "b")
      :properties (("KEY" . "value"))
      :content ((:level 1 :text "block text" :todo "TODO"
                 :properties (("ID" . "uuid"))
                 :body "body text"
                 :children (...)))
      :links ((fuzzy "Title" nil)))
```

A **node** is one note (page/journal). A **block** is one Logseq block /
one org-roam heading. The parsers turn files into IR; the writers turn
IR back into files; the reconciler decides which side's IR is
authoritative and translates links and block references for the target
side.

## Element translation

- Identity is `#+id: <uuid>` in Logseq `.org` and `:ID: <uuid>` in
  org-roam `.org`.
- Title comes from the filename (overridden by `#+title:`) on both
  sides.
- Aliases are `#+alias: a, b` in Logseq `.org` and
  `:ROAM_ALIASES:` `"a" "b"` in org-roam `.org`.
- Page tags are `#+tags:` / `#+filetags:` in Logseq `.org` and
  `#+filetags: :a:b:` in org-roam `.org`.
- Block tags are a heading `:tag:` on both sides.
- Page links are `[[Title]]` in Logseq `.org` and
  `[[id:uuid][Title]]` in org-roam `.org`.
- Block references are `((uuid))` in Logseq `.org` and
  `[[id:uuid][block text]]` in org-roam `.org`.
- Block embeds are `{{embed ((uuid))}}` in Logseq `.org` and
  `[[id:uuid][#embed block text]]` in org-roam `.org`.
- Structure is headlines on both sides.
- TODO states are Org TODO keywords on both sides.
- Dates are `SCHEDULED:` / `DEADLINE:` on both sides.
- Block body is the section body on both sides.

**Identity**

The shared UUID is the one thing that ties a note together across the
two sides. New IDs come from `org-id-new`, the same generator org-roam
uses for new nodes, so generated IDs stay in org-roam's namespace.

**Links**

The sync translates links in both directions through the UUID map:

- `roam → logseq`: `[[id:uuid][Title]]` becomes `[[Title]]` (UUID →
  title).
- `logseq → roam`: `[[Title]]` becomes `[[id:uuid][Title]]` (title →
  UUID).

Dead `[[Title]]` links stay fuzzy on the org-roam side; ambiguous titles
are left un-converted on both sides. `file:` links are remapped to the
real Logseq asset location and back (assets are referenced, never
moved).

**Block references and embeds**

Logseq block references `((uuid))` and embeds `{{embed ((uuid))}}` are
matched to org-roam `[[id:uuid][...]]` links. An embed is distinguished
on the org-roam side by the `#embed` description prefix
(`logseq-org-sync-block-embed-prefix`). A block's `:id:` is adopted as
the org-roam heading `:ID:`, and the reverse mapping restores the
`((uuid))` / `{{embed ((uuid))}}` spelling.

**Empty blocks**

By default (`logseq-org-sync-drop-empty-blocks` is non-nil), truly empty
blocks are dropped before a note is written. An empty block has no text,
todo, tags, properties, planning lines, body, or children. This keeps
the org-roam mirror free of empty headlines. Set the option to nil to
keep those blocks as empty org headlines instead (lossless, but noisier).

## The state cache

Each graph has one small metadata file. It stores **metadata only — never
content**:

- `:id`, cached `:title`
- `:logseq-path` and `:roam-path`
- `:logseq-hash` / `:roam-hash` (SHA-256)
- `:logseq-mtime` / `:roam-mtime`
- `:last-sync`

File bodies, blocks, links, tags, and timestamps live only in the actual
`.org` files.

The cache is used for exactly three decisions:

1.  **Change detection** — compare the current file hash with the
    last-synced hash.
2.  **Rename detection** — same content but a new path means a rename to
    mirror.
3.  **Deletion detection** — a side is missing but the state says it
    existed, so the surviving copy is moved to trash.

Path discovery is deterministic from the two roots, so the engine can
find every file even with an empty or missing state.

**Regenerating a corrupt or deleted state cache**

The state file is safe to delete. `logseq-org-sync-state-load` treats a
missing or invalid file as an **empty** state, and the next sync
re-baselines and saves a fresh file. No note content is deleted or
overwritten by deleting the cache itself.

To regenerate it, run:

    M-x logseq-org-sync-rebuild-state

This deletes the state file and re-seeds the cache from every node that
is present on both sides, without writing any note files. Nodes present
on only one side are left out and are handled by the next normal sync.

Or do it by hand:

1.  Delete the graph's state file:

    ``` elisp
    ~/.emacs.d/logseq-org-sync/<name>.plist   ;; default
    ;; or the explicit :state-file for that graph
    ```

2.  Run a sync:

    ``` elisp
    M-x logseq-org-sync
    ```

On the first run after deletion:

- If a file exists on **both** sides, it is `seed`ed: a baseline is
  recorded and nothing is written.
- If a file exists on **only one** side, it is treated as `new` and the
  missing side is created.
- If a file was deleted on one side, it is not seen as a deletion; the
  survivor is recreated instead.
- If a file was renamed on one side, it is not seen as a rename; both
  sides seed under the current paths.

In short: **safe to delete, self-healing, but it forgets what changed
since the last sync** until a fresh baseline is written. A more detailed
breakdown is in [STATE-CACHE.org](STATE-CACHE.org).

## Safety

- **Dry-run** — every interactive sync shows a plan first. Creates and
  updates apply immediately; you are asked only before moves or deletes.
- **Backup** — before an overwrite, the existing file is copied under
  `<graph root>/.backup/` (`logseq-org-sync-safety-backup-directory`).
- **Trash** — deletions are moved to `<graph root>/.trash/`, never
  hard-deleted (`logseq-org-sync-reconcile-trash-directory`).
- **Conflicts** — when both sides changed, **newest file wins** by
  default. Set `logseq-org-sync-reconcile-conflict-policy` to `prompt`
  to choose per conflict.
- **Updated hook** — `logseq-org-sync-updated-hook` runs after any
  non-empty sync.

## Setup gotchas

**org-roam**

- The sync **hand-writes** org-roam files rather than using
  `org-roam-capture-`. Files created this way are not in org-roam's
  database until it re-indexes. Run `M-x org-roam-db-sync` after the
  first sync if org-roam's graph/backlinks look stale.
- `logseq-org-sync-roam-directory` defaults to `org-roam-directory` when
  it is bound, so the per-graph mirrors land inside the org-roam
  directory. Set `org-roam-directory` (or
  `logseq-org-sync-roam-directory`) **before** adding graphs.

**org-roam-dailies**

- org-roam has one global `org-roam-dailies-directory`; it has no notion
  of a per-graph `journals/` subtree. This sync does **not** use
  org-roam's dailies machinery. Each graph keeps its own `journals/`
  directory and the sync treats journals as ordinary files.

**Logseq**

- Only the org format is synced. Format is decided by
  `:preferred-format "Org"` in `config.edn`; a Markdown graph is
  rejected by `logseq-org-sync-add-graph` and handled with the pandoc
  import/export commands.
- The sync is self-contained: it never shells out to the Logseq app, its
  HTTP API, or its Node parser. The Logseq app can be closed, or you can
  use `logseq-org-sync-watch` to pick up its writes.
- `assets/`, `logseq/`, `draws/`, and `config.edn` are Logseq-only and
  are not synced. Local asset links (`../assets/…`) are therefore
  remapped to the real Logseq asset location on the org-roam side.

**Pandoc import/export**

- Import/export is a one-way batch conversion, not a live sync. It does
  not maintain the state cache.
- The org-roam database must be current for link resolution/restoration;
  import runs `org-roam-db-sync` automatically.

**General limitations**

- Priority cookies (`[#A]`) are not supported (org-element drops the
  text before a priority cookie).

## Testing

``` {.bash org-language="sh"}
make test
```

`make test` runs both suites:

- `make test-elisp` — the sync engine ERT suite (scanner/parser
  round-trips, identity, state, reconciliation, safety, and the command
  layer).
- `make test-pandoc` — the pandoc filter forward/reverse tests in
  `tests-pandoc/`.

## Related documentation

- `AGENTS.md` — architecture, IR, sync algorithm, phases, deferred work.
- `PANDOC-TRANSLATE.md` — the pandoc import/export design and filters.
- `LOGSEQ-FORMAT.org` — the Logseq `.org` format reference.
- `ORG-ROAM-FORMAT.org` — the org-roam `.org` format reference.
- `STATE-CACHE.org` — the state cache in detail.
- `fixtures/README.md` — the paired fixture contract.

## Acknowledgments

This project builds upon and references prior work in the Emacs and
Logseq communities:

- **Legacy converter** — Sylvain Bougerel's
  [logseq-org-roam](https://github.com/sbougerel/logseq-org-roam)
  provided the initial one-way (Logseq → org-roam) converter, inventory
  design, and link detection logic. The original package and its test
  suite are preserved under `legacy/` for reference and historical
  lineage.
- **Pandoc filters** — the Markdown ↔ org-roam translation filters were
  developed in a separate `pandoc-translate` project and merged into
  this repository (see `PANDOC-TRANSLATE.md`).
- **Logseq demo graphs** — The reference Markdown demo graph under
  `Logseq-Demo-Graph-main/` is from candideu's
  [Logseq-Demo-Graph](https://github.com/candideu/Logseq-Demo-Graph),
  and the paired Org graph under `Logseq-demo-graph-org/` serves as
  reference material for Logseq's native Org mode representation.
