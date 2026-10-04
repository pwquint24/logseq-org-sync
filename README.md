# LOGSEQ-ORG-SYNC

logseq-org-sync is a two-way sync between a Logseq graph (`.org` or`.md`) and an org-roam directory,
written in Emacs Lisp. Changes made on either side propagate to the
other without clobbering concurrent work, and every note keeps one
stable identity on both sides.

The full architecture is in AGENTS.md; the on-disk formats are in
LOGSEQ-FORMAT.org and ORG-ROAM-FORMAT.org.

The whole thing is vibe coded using deepseek and ECA

## Installation

The package is pure Emacs Lisp, so you only need the `.el` files on your
`load-path`. There is no build step and no non-Elisp runtime dependency.
The examples below install straight from GitHub with
[straight.el](https://github.com/radian-software/straight.el); `(require
'logseq-org-sync)` pulls in the rest of the `.el` files in the package.

### Vanilla Emacs (straight.el)

``` emacs-lisp
(straight-use-package
 '(logseq-org-sync :type git
                   :host github
                   :repo "pwquint24/logseq-org-sync"
                   :files ("*.el")))

(require 'logseq-org-sync)
```

The `:files ("*.el")` selector installs just the compiled sources and
skips the demo graphs, fixtures, tests, and legacy converter. If you also
want the test suite and fixtures locally, use the default file set
instead:

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
           :files ("*.el")))
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

 ## TL;DR

1.  Install the package (see [Installation](#installation)) and
    `(require 'logseq-org-sync)`.

2.  Add a graph by picking its Logseq folder:

``` emacs-lispM-x logseq-org-sync-add-graph
```

This derives the graph name from the folder basename and mirrors it into
`<logseq-org-sync-roam-directory>/<name>`.
`logseq-org-sync-roam-directory` defaults to `org-roam-directory` when
org-roam is loaded.

3.  Sync it:

``` emacs-lispM-x logseq-org-sync            ;; pick a graph, preview, apply
M-x logseq-org-sync-here       ;; sync the graph of the current buffer
M-x logseq-org-sync-all        ;; sync every configured graph
```

4.  (Optional) sync automatically on save:

``` emacs-lisp(add-hook 'after-save-hook #'logseq-org-sync-after-save)
```

and watch for changes made by the Logseq app:

``` emacs-lispM-x logseq-org-sync-watch      ;; choose a graph
M-x logseq-org-sync-unwatch    ;; stop
```

The rest of this document explains what actually happens, what the state
cache is for, and the setup gotchas to watch out for.

## requirements

- emacs with Org. The engine uses `org-element`, `org-id`, and
  `file-notify`.
- For Markdown graphs, tree-sitter with the `markdown` and
  `markdown-inline` grammars. Link extraction uses `markdown-inline`
  when available and falls back to a regexp otherwise.
- org-roam is **not** required to run the engine or its tests. The
  org-roam side is read and written directly; org-roam is only relevant
  as the place where the mirror lives and as the tool that indexes the
  result.

## Graph configuration

Graphs live in the `logseq-org-sync-graphs` user option. Each entry only
needs a name and a Logseq folder; the org-roam mirror directory is
derived.

``` emacs-lisp(setq logseq-org-sync-roam-directory "~/org-roam")

(setq logseq-org-sync-graphs
      '((:name "Work"     :logseq-root "~/graphs/Work")
        (:name "Personal" :logseq-root "~/graphs/Personal")))
```

With the configuration above:

- `~/graphs/Work` mirrors into `~/org-roam/Work`
- `~/graphs/Personal` mirrors into
  `~/org-roam/Personal`

Each mirror contains the same `pages/` and
`journals/` subtrees as its Logseq graph. The mapping is 1:1
on the relative path within a graph; for a Markdown graph only the
extension changes (`.md` on the Logseq side,
`.org` on the org-roam side).

**Per-graph keys** (all optional except `:name` and `:logseq-root`):

- `:roam-root` defaults to
  `<logseq-org-sync-roam-directory>/<name>`.
- `:pages-directory` defaults to `pages`.
- `:journals-directory` defaults to `journals`.
- `:state-file` defaults to
  `<logseq-org-sync-state-directory>/<name>.plist`.

**Format detection**

The Logseq format is read from
`<logseq-root>/logseq/config.edn` (falling back to
`<logseq-root>/config.edn`). If
`:preferred-format` is set to `"Org"`, the graph
uses `.org` files; otherwise it uses `.md`. The
org-roam side is always `.org`.

## Commands

- `logseq-org-sync` chooses a graph, shows a dry-run preview, and
  applies it (asking only before moves or deletes).
- `logseq-org-sync-here` syncs the graph containing the current
  buffer\'s file (on either side).
- `logseq-org-sync-dry-run` previews a graph\'s plan without writing
  anything.
- `logseq-org-sync-run` is a non-interactive sync; it forces newest-wins
  so it never prompts.
- `logseq-org-sync-all` non-interactively syncs every configured graph.
- `logseq-org-sync-rebuild-state` deletes and rebuilds a graph's state
  cache from the files currently on disk (no note files are written).
- `logseq-org-sync-add-graph` picks a Logseq folder, derives the name
  and mirror, and saves the config.
- `logseq-org-sync-remove-graph` chooses a graph and stops syncing it
  (files are left in place).
- `logseq-org-sync-watch` watches a graph for external changes and
  re-syncs (debounced).
- `logseq-org-sync-unwatch` stops watching a graph (or all graphs).
- `logseq-org-sync-after-save` is an `after-save-hook` function that
  syncs the graph of the saved file.

`logseq-org-sync-here` and `logseq-org-sync-after-save` both match the
current file against every configured graph\'s `pages/` and `journals/`
subtrees, on both the Logseq and org-roam roots, so the same command
works regardless of which side the buffer is on.

## How the two graphs are translated

Both sides read into a common **intermediate representation** (IR) and
write from it. This makes translation symmetric and testable:

``` emacs-lisp(node :id "uuid"
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
IR back into files; the reconciler decides which side\'s IR is
authoritative and translates links and block references for the target
side.

## Element translation

- Identity is `#+id: <uuid>` in Logseq `.org`,
  `id:: <uuid>` in Logseq Markdown, and
  `:ID: <uuid>` in org-roam `.org`.
- Title comes from the filename (overridden by `#+title:`) in
  Logseq `.org`, from the filename (overridden by
  `title::`) in Logseq Markdown, and from
  `#+title:` in org-roam `.org`.
- Aliases are `#+alias: a, b` in Logseq `.org`,
  `alias:: a, b` in Logseq Markdown, and
  `:ROAM_ALIASES:` `"a" "b"` in org-roam `.org`.
- Page tags are `#+tags:` / `#+filetags:` in
  Logseq `.org`, `tags:: a, b` in Logseq Markdown,
  and `#+filetags: :a:b:` in org-roam `.org`.
- Block tags are a heading `:tag:` in Logseq
  `.org`, `#tag` / `#[[multi-word]]` in
  Logseq Markdown, and a heading `:tag:` in org-roam
  `.org`.
- Page links are `[[Title]]` in Logseq `.org`,
  `[[Title]]` / `[t]([[Title]])` in Logseq
  Markdown, and `[[id:uuid][Title]]` in org-roam
  `.org`.
- Block references are `((uuid))` in Logseq `.org`
  and Logseq Markdown, and `[[id:uuid][block text]]` in
  org-roam `.org`.
- Block embeds are `{{embed ((uuid))}}` in Logseq
  `.org` and Logseq Markdown, and
  `[[id:uuid][#embed block text]]` in org-roam
  `.org`.
- Structure is headlines in Logseq `.org`, indented list
  items in Logseq Markdown, and headings / document in org-roam
  `.org`.
- TODO states are Org TODO keywords in Logseq `.org`,
  `TODO=/=DOING=/=DONE=… in Logseq Markdown, and Org TODO keywords in  org-roam =.org`.
- Dates are `SCHEDULED:` / `DEADLINE:` in Logseq
  `.org` and Logseq Markdown, and org timestamps in org-roam
  `.org`.
- Block body is the section body in Logseq `.org`, indented
  continuation in Logseq Markdown, and the section body in org-roam
  `.org`.

**Identity**

The shared UUID is the one thing that ties a note together across the
two sides. New IDs come from `org-id-new`, the same generator org-roam
uses for new nodes, so generated IDs stay in org-roam\'s namespace.

**Links**

The sync translates links in both directions through the UUID map:

- `roam → logseq`: `[[id:uuid][Title]]` becomes
  `[[Title]]` (UUID → title).
- `logseq → roam`: `[[Title]]` becomes
  `[[id:uuid][Title]]` (title → UUID).

Dead `[[Title]]` links stay fuzzy on the org-roam side;
ambiguous titles are left un-converted on both sides. Non-page links
(`file:`, URLs) pass through.

**Block references and embeds**

Logseq block references `((uuid))` and embeds
`{{embed ((uuid))}}` are matched to org-roam
`[[id:uuid][...]]` links. An embed is distinguished on the
org-roam side by the `#embed` description prefix
(`logseq-org-sync-block-embed-prefix`). A block\'s `:id:` is
adopted as the org-roam heading `:ID:`, and the reverse
mapping restores the `((uuid))` /
`{{embed ((uuid))}}` spelling.

**Block tags**

A block\'s tags round-trip between the Markdown spelling
(`#tag` / `#[[multi-word tag]]`) and the org
spelling (`:tag:` at the end of the heading). The Markdown
parser strips `#tag` from the block\'s first line into the
block\'s `:tags` field, and the writer re-emits it as
`#tag`. A multi-word tag uses the underscore spelling on the
org side (`#[[next week]]` → `next_week`) because
org headline tags cannot contain whitespace.

**Block bodies**

Block bodies (paragraphs, tables, code fences, quotes) round-trip
byte-for-byte **within the same format** (`.org ↔ .org` and
Markdown ↔ Markdown). Across formats, two constructs are translated:

- Fenced code blocks ↔ Org source blocks:

- Markdown pipe tables are **not** converted to org tables. They are
  wrapped verbatim in a `#+BEGIN_SRC markdown` block on the
  org-roam side, and unwrapped back on the Logseq side:

Other body constructs (blockquotes, `#+BEGIN_*` blocks) cross
formats verbatim and are not structurally translated.

## The state cache

Each graph has one small metadata file. It stores **metadata only ---
never content**:

- `:id`, cached `:title`
- `:logseq-path` and `:roam-path`
- `:logseq-hash` / `:roam-hash` (SHA-256)
- `:logseq-mtime` / `:roam-mtime`
- `:last-sync`

File bodies, blocks, links, tags, and timestamps live only in the actual
`.org` / `.md` files.

The cache is used for exactly three decisions:

1.  **Change detection** --- compare the current file hash with the
    last-synced hash.
2.  **Rename detection** --- same content but a new path means a rename
    to mirror.
3.  **Deletion detection** --- a side is missing but the state says it
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

1.  Delete the graph\'s state file:

    ``` elisp
    ~/.emacs.d/logseq-org-sync/<name>.plist   ;; default
    ;; or the explicit :state-file for that graph
    ```

2.  Run a sync:

    ``` elisp
    M-x logseq-org-sync
    ```

On the first run after deletion:

- If a file exists on **both** sides, it is =seed=ed: a baseline is
  recorded and nothing is written.
- If a file exists on **only one** side, it is treated as
  `new` and the missing side is created.
- If a file was deleted on one side, it is not seen as a deletion; the
  survivor is recreated instead.
- If a file was renamed on one side, it is not seen as a rename; both
  sides seed under the current paths.

In short: **safe to delete, self-healing, but it forgets what changed
since the last sync** until a fresh baseline is written. A more detailed
breakdown is in [STATE-CACHE.org](STATE-CACHE.org).

## Safety

- **Dry-run** --- every interactive sync shows a plan first. Creates and
  updates apply immediately; you are asked only before moves or deletes.
- **Backup** --- before an overwrite, the existing file is copied under
  `<graph root>/.backup/`
  (`logseq-org-sync-safety-backup-directory`).
- **Trash** --- deletions are moved to
  `<graph root>/.trash/`, never hard-deleted
  (`logseq-org-sync-reconcile-trash-directory`).
- **Conflicts** --- when both sides changed, **newest file wins** by
  default. Set `logseq-org-sync-reconcile-conflict-policy` to `prompt`
  to choose per conflict.
- **Updated hook** --- `logseq-org-sync-updated-hook` runs after any
  non-empty sync.

## Setup gotchas

**org-roam**

- The sync **hand-writes** org-roam files rather than using
  `org-roam-capture-`. Files created this way are not in org-roam\'s
  database until it re-indexes. Run `M-x org-roam-db-sync`
  after the first sync if org-roam\'s graph/backlinks look stale.
- `logseq-org-sync-roam-directory` defaults to `org-roam-directory` when
  it is bound, so the per-graph mirrors land inside the org-roam
  directory. Set `org-roam-directory` (or
  `logseq-org-sync-roam-directory`) **before** adding graphs.

**org-roam-dailies**

- org-roam has one global `org-roam-dailies-directory`; it has no notion
  of a per-graph `journals/` subtree. This sync does **not**
  use org-roam\'s dailies machinery. Each graph keeps its own
  `journals/` directory and the sync treats journals as
  ordinary files. Do not expect org-roam\'s dailies capture to target
  these synced journals automatically.

**Logseq**

- Format is decided by `:preferred-format "Org"` in
  `config.edn`. A commented or absent setting means Markdown.
  Make sure this matches what the graph actually uses.
- The sync is self-contained: it never shells out to the Logseq app, its
  HTTP API, or its Node parser. The Logseq app can be closed, or you can
  use `logseq-org-sync-watch` to pick up its writes.
- `assets/`, `logseq/`, `draws/`, and
  `config.edn` are Logseq-only and are not synced. Local
  asset links (`../assets/…`) are therefore broken on the
  org-roam side.

**General limitations**

- Priority cookies (`[#A]`) are not supported (org-element
  drops the text before a priority cookie).
- Markdown block tags (`#tag` /
  `#[[multi-word tag]]` in block text) are stripped into the
  `:tags` field and round-trip as org headline tags; a
  multi-word tag uses the underscore spelling.
- Cross-format body translation covers code blocks and Markdown tables
  only; other body constructs cross formats verbatim.

## Testing

``` {.bash org-language="sh"}
make test
```

The suite covers the legacy converter and every sync phase:
scanner/parser round-trips, identity, state, reconciliation, safety, and
the Phase 7 command layer.

## Related documentation

- AGENTS.md--- architecture, IR, sync algorithm, phases, deferred work.
- LOGSEQ-FORMAT.org--- the Logseq `.org` / `.md`
  format reference.
- ORG-ROAM-FORMAT.org --- the org-roam `.org` format
  reference.
- STATE-CACHE.org --- the state cache in detail.
- fixtures/README.md --- the paired fixture contract.

## Acknowledgments

This project builds upon and references prior work in the Emacs and
Logseq communities:

- **Legacy converter** --- Sylvain Bougerel\'s
  [logseq-org-roam](https://github.com/sbougerel/logseq-org-roam)
  provided the initial one-way (Logseq → org-roam) converter, inventory
  design, and link detection logic. The original package and its test
  suite are preserved under `legacy/` for reference and
  historical lineage.
- **Logseq demo graphs** --- The reference Markdown demo graph under
  `Logseq-Demo-Graph-main/` is from candideu\'s
  [Logseq-Demo-Graph](https://github.com/candideu/Logseq-Demo-Graph),
  and the paired Org graph under `Logseq-demo-graph-org/`
  serves as reference material for Logseq\'s native Org mode
  representation.
