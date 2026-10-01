# logseq-org-sync

A two-way sync between a **Logseq graph** (`.org` or `.md`) and an **org-roam**
directory, written in Emacs Lisp. Changes made on either side propagate to the
other without clobbering concurrent work.

The full design is in [`AGENTS.md`](AGENTS.md). The on-disk formats are
documented in [`LOGSEQ-FORMAT.md`](LOGSEQ-FORMAT.md) and
[`ORG-ROAM-FORMAT`](ORG-ROAM-FORMAT).

## Requirements

- Emacs with Org (the sync uses `org-element`, `org-id`, and `file-notify`).
- For Markdown graphs, Emacs 31 with tree-sitter and the `markdown` /
  `markdown-inline` grammars.  Link extraction uses `markdown-inline` when it
  is available and falls back to a regexp otherwise.
- org-roam is **not** required to run the engine or its tests; the org-roam
  side is read/written directly.

## How it works

Every note shares a stable UUID:

| Side | Identity | Links |
|---|---|---|
| Logseq `.org` | `#+id: <uuid>` | `[[Title]]` |
| Logseq Markdown | `id:: <uuid>` | `[[Title]]` |
| org-roam `.org` | `:ID: <uuid>` | `[[id:<uuid>][Title]]` |

The sync scans both sides, classifies each node by UUID, and produces an
ordered plan of `create` / `update` / `rename` / `trash` actions. It then
applies the plan with backups and a dry-run preview. Metadata (paths, hashes,
mtimes) is stored per node — never content.

## Layout

```
logseq-org-sync-logseq.el     Phase 2 — Logseq scanner/parser/writer (.org + .md)
logseq-org-sync-roam.el       Phase 3 — org-roam scanner/parser/writer
logseq-org-sync-identity.el   Phase 4 — UUID assignment
logseq-org-sync-state.el      Phase 4 — metadata store
logseq-org-sync-reconcile.el  Phase 5 — reconciler (plan + apply)
logseq-org-sync-safety.el     Phase 6 — dry-run, backup, updated hook
logseq-org-sync.el            Phase 7 — command + hooks + watchers
tests/                        ERT suites for each phase
legacy/                       the original one-way converter (reference)
fixtures/                     paired Logseq / org-roam fixtures (.org and .md)
```

## Usage

Configure one or more graphs:

```elisp
(require 'logseq-org-sync)

(setq logseq-org-sync-graphs
      '(("work"
         :name "work"
         :logseq-root "~/graphs/Work"
         :roam-root "~/org-roam/Work"
         :pages-directory "pages"
         :journals-directory "journals")))
```

The Logseq format is read from `<logseq-root>/logseq/config.edn` (or
`<logseq-root>/config.edn`).  If `:preferred-format "Org"` is active the graph
uses `.org`; otherwise it uses `.md`.

Sync a graph interactively:

```elisp
M-x logseq-org-sync
```

Preview without writing:

```elisp
M-x logseq-org-sync-dry-run
```

Sync on save (Emacs-side edits):

```elisp
(add-hook 'after-save-hook #'logseq-org-sync-after-save)
```

Watch for external changes (e.g. the Logseq app writing files):

```elisp
M-x logseq-org-sync-watch        ; start
M-x logseq-org-sync-unwatch      ; stop
```

The command, save hook, and watchers operate one graph at a time. Conflicts
resolve to the newest file by default; set
`logseq-org-sync-reconcile-conflict-policy` to `prompt` to choose interactively
during `logseq-org-sync`.

## Tests

```sh
make test
```

The suite covers the legacy converter and every sync phase (scanner/parser
round-trips, identity, state, reconciliation, safety, and the Phase 7 command
layer).

## Documentation

- [`AGENTS.md`](AGENTS.md) — architecture, IR, sync algorithm, phases.
- [`LOGSEQ-FORMAT.md`](LOGSEQ-FORMAT.md) — Logseq `.org` / `.md` format reference.
- [`ORG-ROAM-FORMAT`](ORG-ROAM-FORMAT) — org-roam `.org` format reference.
- [`STATE-CACHE.md`](STATE-CACHE.md) — the per-graph metadata store and what
  happens if it is deleted.
- [`fixtures/README.md`](fixtures/README.md) — the paired fixture contract.

## License

See [`LICENSE`](LICENSE).
