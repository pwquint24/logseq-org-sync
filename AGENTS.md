# Two-Way Sync: Logseq Graph ↔ Org-roam

## Project goal

Build a **two-way sync** in Emacs Lisp between:

- a **Logseq graph** directory (the source of truth for Logseq), and
- an **org-roam** directory (the source of truth for Emacs).

Changes made in either directory propagate to the other, without clobbering work
done on the other side.

The directory currently contains:

- `legacy/` — the pre-existing one-way (Logseq → org-roam) converter by
  Sylvain Bougerel, moved into a subdirectory during tidying. §9 documents
  its architecture. Its files are:
  - `legacy/logseq-org-roam.el` — the aggregator + command entry point
    (see §9.7).
  - `legacy/logseq-org-roam-core.el`, `legacy/logseq-org-roam-parser.el`,
    `legacy/logseq-org-roam-inventory.el`, `legacy/logseq-org-roam-dict.el`,
    `legacy/logseq-org-roam-updater.el`, `legacy/logseq-org-roam-create.el` —
    the Phase 1 module split of `logseq-org-roam.el` (see §9.7).
  - `legacy/bug-fix.el` — a bugfix for that package (fixes stale link offsets
    on the re-parse pass). The fix is now folded into `logseq-org-roam-parser.el`
    (§9.5). It also carries unrelated personal config (gptel + Doom leader-key
    bindings) that is out of scope for this project.
  - `legacy/logseq-org-roam-test.el` — the legacy ERT test suite (uses the
    `mocker` library; the top-level `logseq-org-roam` command is untested).
  - `legacy/README.md` — the legacy package README.
- `logseq-org-sync-logseq.el` — the Phase 2 Logseq-side scanner/parser/writer
  (`logseq .org ↔ IR` and `logseq Markdown ↔ IR`; see §9.8).
- `logseq-org-sync-roam.el` — the Phase 3 org-roam-side scanner/parser/writer
  (`org-roam .org ↔ IR`; see §9.9).
- `logseq-org-sync-identity.el` — the Phase 4 node identity (UUID) assignment
  (see §9.10); uses `org-id-new`.
- `logseq-org-sync-state.el` — the Phase 4 metadata state store (load/save of
  last-synced paths/hashes/mtimes; see §9.10).
- `logseq-org-sync-reconcile.el` — the Phase 5 reconciler (scan both sides,
  classify by UUID, produce/apply an action plan; see §9.11).
- `logseq-org-sync-safety.el` — the Phase 6 safety & UX layer (dry-run
  preview, pre-overwrite backup, updated hook; see §9.12).
- `logseq-org-sync.el` — the Phase 7 command/triggering layer (interactive
  command, `after-save-hook`, file-notify watchers; see §9.13).
- `tests/` — ERT test suites for the sync engine:
  - `tests/logseq-org-sync-logseq-test.el` (scanner, parser, round-trip).
  - `tests/logseq-org-sync-roam-test.el` (scanner, parser, round-trip).
  - `tests/logseq-org-sync-identity-test.el`.
  - `tests/logseq-org-sync-state-test.el`.
  - `tests/logseq-org-sync-reconcile-test.el` (seed, create/update,
    newest-wins, rename, delete/trash, dry-run, convergence).
  - `tests/logseq-org-sync-safety-test.el` (dry-run, backup, conflict prompt,
    updated hook).
  - `tests/logseq-org-sync-test.el` (Phase 7 command layer: graph resolution,
    state-file defaults, save-hook file matching, propagation).
- `Logseq-Demo-Graph-main/` — the upstream Logseq demo graph (`.md`); used as
  a reference for the Markdown format, not as a test fixture.
- `Logseq-demo-graph-org/` — a `.org` demo graph (`pages/`, `journals/`,
  `logseq/`); a usable seed for Phase 0 fixtures. Its `config.edn` uses
  `:preferred-format "Org"`, `:preferred-workflow :now`, `:file/name-format
  :triple-lowbar`, and default journal filenames `yyyy_MM_dd`.  Its page
  properties were corrected to the canonical org form (`#+KEY:` in-buffer
  settings; see §3), not the markdown `key::` form.
- `LOGSEQ-FORMAT.md`, `ORG-ROAM-FORMAT` — format references for the Logseq
  `.org`/`.md` and org-roam `.org` sides, respectively (grounded in the `og/`
  Logseq source).
- `fixtures/` — the Phase 0 fixtures: paired `Work` graphs — `Work/logseq/` a
  native Logseq `.org` graph, `Work-markdown/logseq/` a native Logseq Markdown
  graph, and matching `org-roam/` mirrors — plus `fixtures/README.md`
  documenting the mapping, UUID legend, and round-trip contract.
- `Makefile`, `LICENSE`.

---

## 1. Locked architecture decisions

1. **Topology — two separate directories.** Each tree stays native to its own
   tool. A sync engine reads both and translates at the boundary. This replaces
   the current single-shared-directory model.

2. **Logseq side is `.org` or `.md`.** The sync detects the graph format from
   its `config.edn`: an active `:preferred-format "Org"` setting means `.org`;
   otherwise `.md` (see §9.8).

3. **Link strategy — each side native, sync translates.**
   - org-roam tree uses `[[id:uuid][Title]]` links (backlinks/graph work).
   - Logseq tree uses `[[Title]]` double-bracket links (Logseq graph works).
   - The sync converts between them, driven by the shared UUID identity.

4. **Shared identity — the org-roam `:ID:` UUID.**
   - org-roam side: `:ID: <uuid>` property.
   - Logseq org side: `#+id: <uuid>` page property (an org in-buffer setting).
   - Logseq Markdown side: `id:: <uuid>` page property.

5. **Content scope — basics first.** Identity → title/aliases → structure
   (blocks ↔ headings) → links → block refs/embeds (see §6). Deferred: asset
   relocation, full timestamp/tag translation.

6. **Conflicts — newest file wins** by default (no prompt). Prompt-on-conflict is
   a selectable option.

7. **Deletions — moved to a subdirectory** (trash), never hard-deleted.

8. **Self-contained parser — no dependency on a local Logseq install.** The
   engine reimplements Logseq's parsing/writing in pure Elisp (`og/` is
   vendored as the reference spec) and never shells out to Logseq Desktop or
   its parsers.  Explored and rejected as the core path:

   - Desktop's local HTTP API (`127.0.0.1:12315`;
     `og/src/electron/electron/server.cljs`) is only a proxy for the plugin
     SDK against the *open, indexed* graph — it has no "parse a file/string"
     primitive and requires the app to be running.
   - The real parser (`logseq.graph-parser.cli/parse-graph`) is Node.js +
     nbb-logseq + `mldoc` dependencies, is **not** bundled with Desktop, is
     read-only, and returns Logseq's datascript/AST model rather than our IR.

   Optional, non-core uses (not a dependency): `parse-graph` as a test oracle
   to diff our IR against Logseq's ground truth, and the Desktop HTTP API only
   for change notification/triggering.

---

## 2. Directory layout & responsibilities

The org-roam side **mirrors** the Logseq structure: one subdirectory per Logseq
graph, each containing `pages/` and `journals/`. This matches the existing
org-roam configuration (subdirectories per graph, each with `pages/` and
`journals/`).

```
;; Logseq side (native graph; `.org' or `.md' depending on config.edn)
~/graphs/Work/
  pages/        Foo.org, Bar.org     ;; or Foo.md, Bar.md
  journals/     2024-01-01.org       ;; or 2024-01-01.md
  assets/                     ;; Logseq-only
  logseq/                     ;; Logseq-only (private state)
  config.edn                  ;; Logseq-only

;; org-roam side (mirror; always `.org')
org-roam-directory/
  Work/
    pages/        Foo.org, Bar.org      ;; mirror of Logseq pages/
    journals/     2024-01-01.org        ;; mirror of Logseq journals/

<state-store>                 ;; one small metadata file (see §4)
```

The mapping is **1:1 on the relative path within a graph**, with only the
extension changing for Markdown graphs:

- `<logseq-root>/Work/pages/Foo.org` ↔ `<org-roam-directory>/Work/pages/Foo.org`
- `<logseq-root>/Work/pages/Foo.md`  ↔ `<org-roam-directory>/Work/pages/Foo.org`
- `<logseq-root>/Work/journals/2024-01-01.org` ↔ `<org-roam-directory>/Work/journals/2024-01-01.org`

This makes path discovery deterministic; the state store is for change
detection and rename handling, not for locating files.

**Logseq-only**: `assets/`, `logseq/`, `config.edn`. Consequence: local asset
links (e.g. `../assets/foo.png`) would be broken on the org-roam side; asset
relocation is deferred (see §11).

**Multi-graph**: each graph is an independent sync unit with its own config
(logseq root, org-roam root, pages/journal dirs, state file). The sync
operates **one graph at a time** (or all configured graphs via
`logseq-org-sync-all`). This is implemented by the Phase 7
`logseq-org-sync-graphs` defcustom (§9.13):

```elisp
(setq logseq-org-sync-roam-directory "~/org-roam")
(setq logseq-org-sync-graphs
      '((:name "Work"
         :logseq-root "~/graphs/Work")
        (:name "Personal"
         :logseq-root "~/graphs/Personal")))
```

Each graph's `:roam-root` defaults to
`<logseq-org-sync-roam-directory>/<name>` (so the examples above mirror into
`~/org-roam/Work` and `~/org-roam/Personal`), which makes
`logseq-org-sync-add-graph` a matter of picking a Logseq folder.  Optional
per-graph keys remain `:roam-root`, `:pages-directory`, `:journals-directory`,
and `:state-file`.

**org-roam dailies nuance**: org-roam uses a single global
`org-roam-dailies-directory`, which does not express "one `journals/` per
graph". This does not affect the sync — the sync engine handles journal dates
itself (reusing `maybe-date-func` + name/title formats), and journals are
ordinary files under each graph's `journals/`. org-roam's built-in per-graph
dailies is a separate concern.

---

## 3. Identity & link model

Every note has a stable UUID present on **both** sides:

| Side | Identity storage | Link format |
|---|---|---|
| org-roam | `:ID: <uuid>` | `[[id:uuid][Title]]` |
| Logseq `.org` | `#+id: <uuid>` | `[[Title]]` |
| Logseq Markdown | `id:: <uuid>` | `[[Title]]` |

The sync translates links in both directions using the UUID map:

- **`roam → logseq`**: `[[id:uuid][Title]]` → `[[Title]]` (UUID → title lookup).
- **`logseq → roam`**: `[[Title]]` → `[[id:uuid][Title]]` (title → UUID lookup).

Edge cases (reusing the existing package's logic):

- **Dead `[[Title]]` link** (no matching UUID): leave as a fuzzy link on the
  org-roam side by default; optional `create` mode creates the node, assigns a
  UUID, and converts the link.
- **Ambiguous title/alias** (two nodes share one): leave that link un-converted
  on both sides (the existing fuzzy-dict conflict handling).
- **Non-page links** (`[[file:...]]`, URLs): passed through untouched (the
  existing link-classification rules).  Block refs/embeds are handled
  separately (§6).

---

## 4. State store

A single small metadata file (human-readable Lisp plist), keyed by UUID. It
stores **metadata only — never content**.

Per node:

| Field | Purpose |
|---|---|
| `:id` | shared UUID |
| `:roam-path` | relative path in the org-roam dir |
| `:logseq-path` | relative path in the Logseq dir |
| `:roam-hash` | SHA-256 of the org-roam file at last sync |
| `:logseq-hash` | SHA-256 of the Logseq file at last sync |
| `:roam-mtime` / `:logseq-mtime` | last-sync mtimes (drives "newest wins" + fast dirty check) |
| `:title` | cached title (rename detection / matching) |
| `:last-sync` | timestamp |

**Not stored:** file bodies, blocks, links, tags, or timestamps — content lives
only in the actual `.org` files.

Size: ~300–500 bytes per node. ~50 KB at 100 notes, ~5 MB at 10,000 notes.
Negligible; can live under `user-emacs-directory` or be version-controlled.

---

## 5. Intermediate representation (IR)

To make translation testable and symmetric, both sides read/write a common IR:

```
(node :id "uuid"
      :title "Foo"
      :aliases (...)
      :tags (...)
      :properties (...)
      :content (ordered list of blocks
                (block :level N :text "..." :todo ... :scheduled ... :deadline ...
                       :properties (...) :body "..." :children (...)))
      :links (list of (kind target description)))
```

Converters come in pure-ish pairs, each unit-testable:

- `logseq → IR` and `IR → logseq`
- `roam → IR` and `IR → roam`

Translation table:

| Concern | Logseq `.org` | Logseq Markdown | IR | org-roam |
|---|---|---|---|---|
| Identity | `#+id: <uuid>` | `id:: <uuid>` | `:id` | `:ID: <uuid>` |
| Title | filename slug; `#+title:` overrides | filename slug; `title::` overrides | `:title` | `#+title:` |
| Aliases | `#+alias: a, b` | `alias:: a, b` | `:aliases` | `:ROAM_ALIASES:` |
| Tags | `#+tags: a, b` and/or `#+filetags: :a:b:` | `tags:: a, b` | `:tags` | `#+filetags: :a:b:` |
| Links | `[[Title]]` | `[[Title]]` / `[desc]([[Title]])` | `:links` | `[[id:uuid][Title]]` |
| Block refs | `((uuid))` / `{{embed ((uuid))}}` | `((uuid))` / `{{embed ((uuid))}}` | block `:text` (translated at sync) | `[[id:uuid][block text]]` / `[[id:uuid][#embed block text]]` |
| Structure | headlines (outliner) | indented list items (outliner) | `:content` blocks | headings/document |
| Block body | section body | indented continuation lines | `:body` (string; planned §11.1) | section body; Markdown tables wrap in `#+BEGIN_SRC markdown` (§11.2) |
| TODO | org TODO keywords (`TODO`/`DOING`/`DONE`) | `TODO`/`DOING`/`DONE`/… prefix | `:todo` | org TODO keywords |
| Dates | `SCHEDULED:`/`DEADLINE:` | `SCHEDULED:`/`DEADLINE:` | `:scheduled`/`:deadline` | org timestamps |

---

## 6. Block-level links

Logseq has two block-level reference types:

1. **Block reference** `((uuid))` — shows the referenced block inline, without
   its children, not editable.
2. **Block embed** `{{embed ((uuid))}}` — shows the block with its children,
   editable, changes propagate.

Both key off a block's identity property: Markdown `id:: uuid`, or org
`:PROPERTIES:` `:ID: uuid`.

The reconciler **adopts the Logseq block `:id:` as the org-roam heading `:ID:`**
(same UUID), and translates references in both directions using a block
registry (block UUID → block text) built from the source side:

| Logseq | org-roam |
|---|---|
| `((uuid))` | `[[id:uuid][block text]]` |
| `{{embed ((uuid))}}` | `[[id:uuid][#embed block text]]` |

- `#embed` is `logseq-org-sync-block-embed-prefix` (a defcustom).
- The link description is a display label derived from the block's text; it is
  sanitized (page links reduced to their visible label, square brackets
  removed) so it cannot terminate the link early.  Identity is the UUID, and
  the Logseq side regenerates `((uuid))` / `{{embed ((uuid))}}` from the UUID
  alone, so the description is never authoritative.
- A `[[id:uuid][...]]` link is a block reference only when its UUID is in the
  block registry; links to page UUIDs remain ordinary page links.
- Unresolved (dangling) block UUIDs are preserved verbatim.
- `:ID:` is written only for headings whose source Logseq block already carried
  an `:id:` (the sync never synthesizes block ids).

Only the live rendering differs on the org-roam side: org-roam does not
transclude block children, so an embed renders as a plain `id:` link there, but
the embed/reference distinction survives a round-trip.

---

## 7. Sync algorithm (each run)

1. **Scan** the Logseq `pages/` + `journals/` (`.org` or `.md`, per the graph
   format) and the org-roam mirror's `pages/` + `journals/` (`.org`).
2. **Hash** every file (SHA-256) and compare against the state store.
3. **Classify** each node by UUID (fall back to `path:` matching for nodes
   lacking an ID):
   - new on Logseq only → convert `logseq → roam`, write org-roam side;
   - new on org-roam only → convert `roam → logseq`, write Logseq side;
   - modified on Logseq only → reconvert, overwrite org-roam side;
   - modified on org-roam only → reconvert, overwrite Logseq side;
   - modified on both → **newest file wins** (default), or prompt (opt-in);
   - renamed → update the path mapping on that side (no content change);
   - deleted on one side → mirror to the trash subdirectory on the other.
4. **Update** the state store with new hashes/paths/mtimes.

---

## 8. Correctness invariant

For any note with no concurrent edits, a full round-trip must converge to a
no-op:

- `logseq → roam → logseq` == original
- `roam → logseq → roam` == original

Because both conversions resolve through the same UUID map, `[[Title]]` →
`[[id:uuid][Title]]` → `[[Title]]` is lossless. Block references obey the same
invariant: `((uuid))` → `[[id:uuid][block text]]` → `((uuid))`, and an embed's
`#embed` marker restores `{{embed ((uuid))}}` (the description text is
regenerated from the block registry, never trusted). This is the testable
contract that distinguishes a real two-way sync from two one-way converters
bolted together.

---

## 9. Reuse of existing code

The legacy `logseq-org-roam` converter (§9.1–§9.7) now lives in the
`legacy/` subdirectory; the two-way sync engine (§9.8–§9.13) lives at the
repository root and in `tests/`.

The following existing `logseq-org-roam.el` logic is reused for the
`logseq → roam` half and the "read org-roam" half:

- link detection (`file` + `fuzzy` link parsing, internal-link exclusion),
- fuzzy-dict and file-dict construction (title/alias/path conflict detection),
- normalization (`--normalize-text` downcase; `--normalize-path` downcase +
  underscore collapse),
- date detection (`maybe-date-func`),
- SHA-256 hash guard against concurrent edits,
- inventory model (cache-p / modified-p / external-p / parse-error).

The `bug-fix.el` offset bug is fixed **structurally** by the IR design: parse →
IR → write, never patch byte offsets in place.

### 9.1 Entry point & modes

`logseq-org-roam (&optional MODE)` is the single interactive entry point.
`MODE` selects behavior via universal arguments:

| `MODE` | effect |
|---|---|
| nil | parse only files not yet in the `org-roam` cache; do not create files |
| `'(4)` / `4` / `'force` (C-u) | force-parse all files; no creation |
| `'(16)` / `16` / `'create` (C-u C-u) | no force; author new files for dead links |
| `'(64)` / `64` / `'force-create` (C-u C-u C-u) | force + create |

### 9.2 What it actually converts (scope)

Only the **first section** and **links**:

- first section — add `:ID:` (via `org-id-get-create`), `#+title:` (via
  `--buffer-title`), and `:ROAM_ALIASES:` from `#+alias:`.
- links — `[[file:...][desc]]` and `[[Title]]`/`[[Alias]]` → `[[id:uuid][desc]]`.
- optional creation — author a missing node for a dead link (inserts an ID and
  `#+title:`; no capture-template support).

It does **not** convert structure, block refs/embeds, timestamps, tags, or
assets — those remain the deferred scope in §11.

### 9.3 Data flow (in-place, offset-based)

1. `org-roam-list-files` → absolute paths.
2. Build an **inventory**: hash table keyed by absolute path → plist
   (`:cache-p`, `:id`, `:title`, `:roam-aliases`, `:aliases`, `:external-p`,
   `:modified-p`, `:hash`, `:first-section-p`, `:title-point`, `:links`,
   `:parse-error`, `:update-error`).
3. Parse each file with `org-element-parse-buffer`; extract first-section
   metadata and link tuples `(type begin end path descr raw)`.
4. **Two passes** — first sections are updated first, modified files re-parsed,
   dictionaries filled, then links updated. IDs must exist before links can be
   rewritten.
5. Optionally create files for dead links, re-parse them, refill dictionaries,
   then convert links.
6. A SHA-256 hash is re-verified before every edit; on `hash-mismatch` the
   file's edit is aborted (concurrent-edit guard).

### 9.4 Dictionaries

- `fuzzy-dict` — normalized title/alias (`downcase`) → path; a `cons` marks a
  conflict (ambiguous target → leave those links unconverted).
- `file-dict` — normalized path (downcase base + collapse `_+` → `_`) → path; a
  `cons` marks a conflict.

### 9.5 The `bug-fix.el` bug

`--parse-buffer` pushes into the existing `:links` plist without resetting it.
On `--inventory-update` (the re-parse after first-section edits), this appends
a second copy of every link with now-stale byte offsets. The fix resets
`:links` to nil before re-collecting. The IR design (§5) removes the whole
class of problem: converters emit fresh IR rather than patching offsets in a
live buffer.

### 9.6 Tests

ERT + `mocker` (`mocker-let`), mocking `org-roam-db-query`, `secure-hash`,
`insert-file-contents`, `find-file-noselect`, `save-buffer`, etc. Covers
inventory construction, `--parse-buffer`, dictionary conflict detection,
`--update-first-section`, `--update-links`, `--create-translate-default`, and
`--create-from`. The top-level `logseq-org-roam` command is **not** tested.

### 9.7 Phase 1 module split

The monolith was split into focused modules while keeping **every public and
internal symbol unchanged** (so the ERT/mocker suite still passes by symbol
name). `logseq-org-roam.el` is now the aggregator and command entry point; it
`require`s the modules below and still `provide`s `logseq-org-roam`.

| File | Contents |
|---|---|
| `logseq-org-roam-core.el` | `defgroup`, all `defcustom`s, `defconst`s, macros (`--with-log-buffer`, `--with-edit-buffer`, `--with-temp-buffer`, `--catch-fun`), predicates (`pages-p`/`journals-p`/`logseq-p`), helpers (`--fl`, `--image-file-p`, `--value-string-p`, `maybe-date-default`, `--normalize-text`, `--normalize-path`) |
| `logseq-org-roam-parser.el` | `--parse-first-section-*`, `--parse-file-links`, `--parse-fuzzy-links`, `--parse-buffer` (with the §9.5 fix), `--parse-files` |
| `logseq-org-roam-inventory.el` | `--inventory-init`, `--inventory-from-cache`, `--inventory-mark-external`, `--inventory-mark-modified`, `--inventory-all`, `--inventory-update` |
| `logseq-org-roam-dict.el` | `--fill-fuzzy-dict`, `--fill-file-dict` |
| `logseq-org-roam-updater.el` | `--buffer-title`, `--update-first-section`, `--update-links`, `--update-all` |
| `logseq-org-roam-create.el` | `create-translate-default`, `--create-path-fuzzy`, `--create-path-file`, `--create-from` |
| `logseq-org-roam.el` | `--log-start`, `--check-errors`, `--sanity-check`, `logseq-org-roam` (command) |

Load order (by `require`) is core → parser → inventory → dict → updater →
create → `logseq-org-roam`. The §9.5 offset bug is fixed in the parser module:
`--parse-buffer` resets a *stale* `:links` key (guarded by `plist-member` so a
link-less file still has no `:links` key) before re-collecting.

The full suite (`make test`) passes: the legacy suite plus Phases 2–7
(§9.8–§9.13). The only intentional behavior change is the §9.5 fix (verified
by `--parse-buffer--idempotent`).

### 9.8 Phase 2 module — `logseq-org-sync-logseq.el`

The Logseq side of the two-way sync engine.  It is a new, self-contained
package (namespace `logseq-org-sync-*`) that requires only `org`, `org-element`,
`cl-lib`, `subr-x`, and `treesit` — it does not reuse the legacy
`logseq-org-roam` code.  It handles both Logseq `.org` graphs and Logseq
Markdown graphs.

**Graph format detection.**  `logseq-org-sync-logseq-graph-format` reads
`<root>/logseq/config.edn` (falling back to `<root>/config.edn`), drops `;;`
comment lines, and looks for `:preferred-format` followed by whitespace and
`"Org"`.  If present the graph is org; otherwise it is Markdown.  `-scan`,
`-parse-file`, and `-write` use that format (or the file extension) to choose
the `.org` or `.md` implementation.

**Canonical Logseq `.org` format.**  Page properties are org in-buffer settings
and blocks are org headlines:

```
#+id: <uuid>            ;; optional identity
#+alias: a, b           ;; optional aliases
#+title: Display name   ;; optional page display title (overrides file name)
#+tags: a, b            ;; optional page tags (comma-separated)
#+filetags: :a:b:       ;; optional page tags (org colon form, merged with #+tags:)
#+<other>: value        ;; arbitrary page props, optional

* [TODO] block text [[Page]]
** child text
```

Block properties live in a `:PROPERTIES:` drawer on the block's own headline.
This is the org-mode form of Logseq properties (the markdown form is
`id::`/`alias::`/`key::`; the `.org` graph uses `#+id:`/`#+alias:`/`#+key:`).

**Canonical Logseq Markdown format.**  Page properties are leading `key:: value`
lines and blocks are indented unordered list items:

```
id:: <uuid>            ;; optional identity
alias:: a, b           ;; optional aliases
tags:: a, b            ;; optional page tags
<other>:: value        ;; arbitrary page props

- TODO block text [[Page]]
	- child text
```

Block properties and planning lines are continuation lines indented under
their block (`  key:: value`, `  SCHEDULED: <...>`).  Visual heading blocks
(`# Heading` or `- # Heading`) are normalized to a `heading` block property,
mirroring the `.org` side.  The Markdown parser uses the `markdown-inline`
tree-sitter grammar for link extraction when it is available, with a regexp
fallback otherwise.

**IR schema.**  A node is a plist with deterministic key order (nil keys are
omitted):

- `:title` — string.  A `#+title:` keyword overrides the file name base,
  matching Logseq's page-name precedence (title property → filename → first
  heading).
- `:id` — string, or omitted.
- `:aliases` — list of strings, or omitted.
- `:tags` — list of strings, or omitted.  Read from `#+tags:` (comma-separated)
  and/or `#+filetags:` (org colon form `:a:b:`), merged in document order.
- `:properties` — alist `(("KEY" . "value") ...)` of arbitrary `#+KEY:`
  settings (excluding `id`/`alias`/`title`/`tags`/`filetags`), in document
  order, or omitted.
- `:content` — ordered list of block plists, or omitted.
- `:links` — list of `(fuzzy TARGET DESCRIPTION)` tuples (DESCRIPTION nil for a
  plain `[[TARGET]]`), or omitted.

A block is a plist with deterministic key order (nil keys omitted):

- `:level` — positive integer.
- `:text` — string (headline `:raw-value`; inline markup preserved verbatim).
- `:todo` — TODO keyword string, or omitted.
- `:tags` — list of strings, or omitted.
- `:properties` — alist from the block's own `:PROPERTIES:` drawer, or omitted.
- `:scheduled` / `:deadline` — raw timestamp strings, or omitted.
- `:body` — string (block body text between the first line and child blocks,
  with planning/properties excluded), or omitted.
- `:children` — list of nested block plists, or omitted.

**Public functions:** `logseq-org-sync-logseq-scan` (sorted absolute `.org` or
`.md` paths under `pages/` + `journals/`), `logseq-org-sync-logseq-parse-file`,
`logseq-org-sync-logseq-format`, `logseq-org-sync-logseq-write`,
`logseq-org-sync-logseq-graph-format`, and the Markdown-specific
`logseq-org-sync-logseq-markdown-parse-buffer/-parse-file/-format/-write`.

**Known limitations** (documented in the module commentary):

- Priority cookies (`[#A]`) are not supported (`org-element` drops the text
  preceding a priority cookie from `:raw-value`).
- Arbitrary page-property keys are normalized to uppercase on round-trip
  (`org-element` reports in-buffer keyword keys uppercased).
- Block references `((uuid))` and embeds `{{embed ((uuid))}}` are preserved
  verbatim in `:text` by the parse/write module; the reconciler translates them
  cross-side (see §6).
- Fuzzy-link collection skips org-internal links (`[[#custom-id]]`,
  `[[*heading]]`); image/asset links are not specially handled (deferred, §11).
- Block bodies beyond the first line (tables, code fences, multi-line text)
  round-trip through the block's `:body` field: byte-for-byte same-format
  (`.org ↔ .org` and Markdown ↔ Markdown), and cross-format for fenced code
  blocks and Markdown tables (§11.1/§11.2).  Other body constructs cross
  formats verbatim.  A block keeps its first line (`:text`), TODO marker,
  `:tags`, block `:properties`, `SCHEDULED:`/`DEADLINE:` lines, `:body`, and
  `:children`.
- Markdown block tags (`#tag` / `#[[multi-word tag]]`) are stripped from the
  block's first line into the IR `:tags` field (multi-word tags use the
  underscore spelling org requires); the Markdown writer emits `:tags` back as
  `#tag`.  org headline tags (`:tag:`) already map to `:tags` on both org
  sides.  See §11.3.

### 9.9 Phase 3 module — `logseq-org-sync-roam.el`

The org-roam side of the two-way sync engine.  It is the mirror image of the
Phase 2 `logseq-org-sync-logseq` module: the two sides share the same IR
(blocks ↔ headlines) and differ only in how they store identity/aliases in the
first section and in their link representation.  Self-contained package
(namespace `logseq-org-sync-*`) requiring only `org`, `org-element`, `cl-lib`,
and `subr-x`.

**Canonical org-roam `.org` format.**  Identity and aliases live in a
top-level `:PROPERTIES:` drawer and the title is a `#+title:` keyword:

```
:PROPERTIES:
:ID: <uuid>
:ROAM_ALIASES: "a" "b"
:END:
#+title: Page title
#+filetags: :a:b:

* TODO block text [[id:<uuid>][Page]]
** child text
```

**IR.**  The node and block plists are exactly those of §9.8, with these
org-roam-side differences:

- `:title` is read from the `#+title:` keyword (falling back to the file name
  base) rather than derived from the file name base alone.
- `:tags` is read from and written as the `#+filetags:` keyword (org colon form
  `:a:b:`), rather than Logseq's `#+tags:`/`#+filetags:` mix.
- `:links` contains `(id UUID DESCRIPTION)` tuples for
  `[[id:UUID][DESCRIPTION]]` links in addition to `(fuzzy TARGET DESCRIPTION)`
  tuples for unresolved `[[TARGET]]` links.

`ROAM_ALIASES` values are split with `split-string-and-unquote` (each alias is
double-quoted and space-separated).  Arbitrary drawer node properties (other
than `ID`/`ROAM_ALIASES`) are preserved as `:properties`.

**Public functions:** `logseq-org-sync-roam-scan` (sorted absolute `.org`
paths under `pages/` + `journals/`), `logseq-org-sync-roam-parse-buffer`,
`logseq-org-sync-roam-parse-file`, `logseq-org-sync-roam-format` (IR →
canonical string), and `logseq-org-sync-roam-write`.

**Known limitations** (documented in the module commentary):

- Priority cookies (`[#A]`) are not supported (`org-element` drops the text
  preceding a priority cookie from `:raw-value`).
- Links are preserved verbatim in `:text`; `:links` is a semantic extraction
  for the reconciler (Phase 5), not the source of link output.
- Block references `((uuid))` and embeds `{{embed ((uuid))}}` are preserved
  verbatim in `:text` by the parse/write module; the reconciler translates them
  cross-side (see §6).
- Fuzzy-link collection skips org-internal links (`[[#custom-id]]`,
  `[[*heading]]`); image/asset links are not specially handled (deferred, §11).

### 9.10 Phase 4 modules — identity & state store

Two small, self-contained modules make up the identity and metadata half of
the engine.

**`logseq-org-sync-identity.el`** assigns the shared UUID (§3).  New IDs come
from `org-id-new` — the same built-in Org generator org-roam itself uses when
creating a node (`org-roam-capture-` assigns `(org-id-new)` to a node that has
no ID), so generated IDs stay in org-roam's ID namespace rather than inventing
a second one.

- `logseq-org-sync-identity-new` → a new UUID (`org-id-new`).
- `logseq-org-sync-identity-ensure-node` → an IR node with a guaranteed `:id`
  (existing `:id` preserved; otherwise a new UUID is assigned).

**`logseq-org-sync-state.el`** persists the sync metadata (§4) — never content
— keyed by UUID:

```
(:version 1
 :nodes ((:id "uuid" :title "Foo"
          :roam-path "pages/Foo.org" :logseq-path "pages/Foo.org"
          :roam-hash "sha256hex" :logseq-hash "sha256hex"
          :roam-mtime (…) :logseq-mtime (…) :last-sync (…))
         ...))
```

Public functions: `logseq-org-sync-state-empty`, `-get` (by `:id`), `-put`
(replaces a same-`:id` record), `-remove`, `-load` (returns an empty state when
the file is absent/invalid), and `-save` (writes a readable Lisp plist via
`prin1`, the same convention as `org-id-locations-file`).  `:roam-mtime` /
`:logseq-mtime` store `file-attribute-modification-time` values and drive the
§7 "newest wins" + fast dirty check.

**org-roam file creation (Phase 5).**  When the reconciler authors a new
org-roam note, it should prefer org-roam's built-in node-creation path —
`org-roam-capture-` with `:immediate-finish t` (or `org-roam-node-create` +
`org-id-get-create` for the `:ID:` property) — over hand-writing the file, so
org-roam's database and hooks stay consistent.  The identity module above is
the ID half of that path.

### 9.11 Phase 5 module — `logseq-org-sync-reconcile.el`

The reconciler (AGENTS.md §7).  It reads both a Logseq graph and its org-roam
mirror, classifies every node by its shared UUID, and produces an ordered
**plan** of actions; a separate apply step executes it.  Planning is pure
(reads files, never writes), so the same plan powers the Phase 6 dry-run.

**Graph configuration.**  A graph is a plist describing one Logseq/org-roam
pair (AGENTS.md §2):

```
(:name "work"
 :logseq-root "~/graphs/Work"
 :roam-root   "/org-roam/Work"
 :pages-directory "pages"
 :journals-directory "journals")
```

The two roots hold identically-named `pages/` and `journals/` subtrees, so a
node's path relative to its root is the same on both sides (1:1 mapping).  For
Markdown graphs the Logseq side uses `.md` while the org-roam side stays
`.org`; the reconciler maps extensions back and forth when building actions
and state records (`logseq-org-sync-reconcile--roam-path` /
`--logseq-path`).

**Node tables (internal).**  Each side is read into a hash table keyed by UUID
(files without a `:id` fall back to a `path:` key).  A table value is
`(:id UUID :path REL :abs ABS :node IR :hash SHA256 :mtime TIME :title TITLE)`,
where `:hash` is the file's SHA-256 and `:mtime` its
`file-attribute-modification-time`.

**Actions.**  The plan is an ordered list of action plists, each carrying
`:type`, `:id`, and `:reason` plus the fields the executor needs:

| `:type` | meaning | extra fields |
|---|---|---|
| `create-roam` / `create-logseq` | new on one side; propagate | `:path`, `:node` |
| `update-roam` / `update-logseq` | modified on one side; reconvert | `:path`, `:node` |
| `seed` | present on both, never synced; record baseline | `:path`, `:node` |
| `rename-roam` / `rename-logseq` | path changed on one side; mirror rename | `:from`, `:to` |
| `trash-roam` / `trash-logseq` | deleted on one side; move the other copy to trash | `:path`, `:abs` |

`:reason` is one of `new`, `modified`, `newest-wins`, `renamed`, `deleted`,
`conflict`, or `seed`.

**Classification** (AGENTS.md §7 step 3): new-on-one-side → create; modified
on one side (hash differs from state) → update the other; modified on both →
newest file wins (default) or prompt; path changed on one side with identical
content → rename; deleted on one side with a state record → trash the other.
A node present on both sides but absent from state is **seeded** (recorded,
not written) so a first run over an already-paired graph is a no-op.

**Public functions:**

- `logseq-org-sync-reconcile-plan` (graph state) → the plan (pure).
- `logseq-org-sync-reconcile-dry-run` — alias of `-plan` (Phase 6 uses it).
- `logseq-org-sync-reconcile-apply` (graph state plan) → updated state
  (writes files, moves deletions to trash, updates the state store).

**Conflict policy** (AGENTS.md §6):

- `logseq-org-sync-reconcile-conflict-policy` — `newest-wins` (default) or
  `prompt`.
- `logseq-org-sync-reconcile-prompt-function` — called for `prompt`; returns
  `logseq` or `roam`.

**Trash** (AGENTS.md §1.7): `logseq-org-sync-reconcile-trash-directory`
(default `.trash`); deleted files are moved there (relative path preserved),
never hard-deleted.

**Block references (AGENTS.md §6).**  After classification, `-plan` translates
block references in the `:node` of each create/update action for its target
side.  A block registry (block UUID → block text) is built from the source
side's node table; Logseq `((uuid))` / `{{embed ((uuid))}}` become
`[[id:uuid][block text]]` / `[[id:uuid][#embed block text]]`, and the reverse
direction maps a `[[id:uuid][...]]` link whose UUID is in the registry back to
`((uuid))` (or `{{embed ((uuid))}}` when the description starts with
`logseq-org-sync-block-embed-prefix`).  Page links and dangling references are
left untouched.  Because the description is regenerated from the registry, the
embed/reference distinction round-trips losslessly.

**Cross-format block bodies (AGENTS.md §11.1 step 6, §11.2).**  For Markdown
graphs only, `-plan` also translates each block's `:body` for its target side:
Logseq Markdown fenced code blocks become `#+BEGIN_SRC` blocks and Markdown
pipe tables are wrapped verbatim in `#+BEGIN_SRC markdown` blocks on the
org-roam side, with the reverse unwrapping in the other direction
(`logseq-org-sync-reconcile--md-block-to-roam` /
`--roam-block-to-logseq`, applied by `--translate-plan`).  Other body
constructs cross formats verbatim (AGENTS.md §11.1).  Org-format Logseq graphs
need no body translation because both sides already use org syntax.

**Known simplification.**  The reconciler hand-writes org-roam files with the
Phase 3 writer (`logseq-org-sync-roam-write`) rather than org-roam's capture
path (§9.10).  This keeps the engine and its tests independent of a live
org-roam database; routing new-node creation through `org-roam-capture-`
remains deferred.

### 9.12 Phase 6 module — `logseq-org-sync-safety.el`

The safety & UX layer (AGENTS.md §10 phase 6).  It is a thin wrapper over the
reconciler: planning, classification, and execution stay in
`logseq-org-sync-reconcile` so they remain independently testable.

**Public functions:**

- `logseq-org-sync-safety-dry-run-text` (graph state) → a human-readable
  preview of the plan as a string; computes the plan but never applies it.
- `logseq-org-sync-safety-apply` (graph state plan) → state; backs up files
  about to be overwritten, applies the plan, then runs the updated hook.
- `logseq-org-sync-safety-plan-and-apply` (graph state) → state; the
  convenience entry point combining plan + safe apply.

**Defcustoms:**

- `logseq-org-sync-updated-hook` — run after an apply with a non-empty plan.
- `logseq-org-sync-safety-backup-directory` — `.backup` by default.
- `logseq-org-sync-safety-backup-enabled` — non-nil by default.

**Backup** (AGENTS.md §10 phase 6): before an overwrite, the existing file is
copied under the graph root's `.backup/` subdirectory (relative path
preserved).  Deletions are already moved to `.trash/` by the reconciler.  The
newest-wins/prompt conflict policy lives on the reconciler (§9.11).

### 9.13 Phase 7 module — `logseq-org-sync.el`

The triggering/command layer (AGENTS.md §10 phase 7).  It wires the Phase 5
reconciler and Phase 6 safety layer into the pieces a user invokes.  It does
not add new sync logic; planning and execution stay in
`logseq-org-sync-reconcile` / `logseq-org-sync-safety`.

**Graph configuration** (AGENTS.md §2) lives in the `logseq-org-sync-graphs`
defcustom: a list of plists, each with `:name`, `:logseq-root`, and an
optional `:roam-root` (defaulting to
`<logseq-org-sync-roam-directory>/<name>`).  Optional
`:pages-directory`/`:journals-directory` default to `pages` / `journals`, and
an optional `:state-file` defaults to
`<logseq-org-sync-state-directory>/<name>.plist`.  `logseq-org-sync-roam-directory`
defaults to `org-roam-directory` when org-roam is loaded, so mirrors live
inside the org-roam directory.

**Public functions:**

- `logseq-org-sync` (graph) — interactive command: resolve a graph, load its
  state, show the dry-run preview, ask for confirmation, then apply and save
  state.  Operates one graph at a time.
- `logseq-org-sync-here` — sync the graph containing the current buffer's
  file, whether that file is on the Logseq side or the org-roam side; same
  preview/confirm flow as `logseq-org-sync`.
- `logseq-org-sync-dry-run` (graph) — interactive preview only.
- `logseq-org-sync-run` (graph) — non-interactive sync; forces the conflict
  policy to `newest-wins` so it never prompts, applies, saves state, and
  returns the new state.  Used by the automatic triggers below.
- `logseq-org-sync-all` — non-interactive sync of every configured graph via
  `logseq-org-sync-run`.
- `logseq-org-sync-add-graph` — pick a Logseq folder; the graph name defaults
  to the folder's basename and the `:roam-root` to
  `<logseq-org-sync-roam-directory>/<name>`; creates the mirror subdirectory
  and saves `logseq-org-sync-graphs` via Customize.
- `logseq-org-sync-remove-graph` — choose a configured graph, stop its
  watchers, and remove it from `logseq-org-sync-graphs` (files are left in
  place).
- `logseq-org-sync-after-save` — an `after-save-hook` function; syncs the
  configured graph containing `buffer-file-name` when it is a note under a
  graph's `pages/` or `journals/` subtree.
- `logseq-org-sync-watch` / `logseq-org-sync-unwatch` — start/stop
  `file-notify` watchers on a graph's two roots; events are debounced by
  `logseq-org-sync-watch-delay` and re-sync via `logseq-org-sync-run`.

**Defcustoms:**

- `logseq-org-sync-graphs` — the configured graphs (nil by default).
- `logseq-org-sync-roam-directory` — the parent of per-graph mirror
  subdirectories (defaults to `org-roam-directory` when bound).
- `logseq-org-sync-state-directory` — under `user-emacs-directory` by default.
- `logseq-org-sync-watch-delay` — 2.0 seconds by default.

---

## 10. Implementation phases

1. **Phase 0 — Scope & fixtures.** Add minimal Logseq `.org` and Markdown
   fixture graphs, each with a matching org-roam fixture for round-trip tests.
2. **Phase 1 — Extract & stabilize.** Split the monolith into modules (parser,
   dictionaries, inventory, updaters). Port the existing ERT suite. No behavior
   change.
3. **Phase 2 — Logseq side.** Scanner + parser + writer (`logseq ↔ IR`).
4. **Phase 3 — org-roam side.** Parser (reuse) + writer (`roam ↔ IR`).
5. **Phase 4 — Identity & state store.** UUID assignment + metadata persistence.
6. **Phase 5 — Reconciler.** Change detection, classification, propagation,
   rename/delete handling.
7. **Phase 6 — Safety & UX.** Dry-run preview, backup/trash, newest-wins +
   optional conflict prompt, updated hook.
8. **Phase 7 — Triggering.** `logseq-org-sync` command (operates one graph at a
   time) + `after-save-hook` / `file-notify` watchers.
9. **Phase 8 — Tests & docs.** Round-trip invariants, fixture tests, README.

Phases 0–8 are implemented (§9.8–§9.13 plus `README.org`,
`LOGSEQ-FORMAT.md`, `ORG-ROAM-FORMAT`); the remaining work is the deferred
scope below.

---

## 11. Deferred (documented limitations)

- Block refs/embeds are translated cross-side (§6), but org-roam has no live
  transclusion for embeds (they render as plain `id:` links there), and
  dangling block references are preserved verbatim.
- Asset relocation and full timestamp/tag translation. Because `assets/` is
  Logseq-only, local asset links (e.g. `../assets/foo.png`) are broken on the
  org-roam side; v1 assumes no local assets or out-of-band asset sync.
- Block bodies beyond the first line (tables, code fences, multi-line text)
  round-trip through `:body` (same-format byte-for-byte, plus cross-format
  for fenced code blocks and Markdown tables).  See §9.8, §11.1, and §11.2.
- Live/continuous sync: Phase 7 provides an `after-save-hook` and
  `file-notify` watchers; richer or more robust continuous operation (e.g.
  finer-grained watch filtering, queueing) remains a future concern.

### 11.1 Block-body support in the IR

Logseq itself keeps a block's full body (`:block/body` AST + `:block/content`
raw text; see `og/deps/graph-parser/src/logseq/graph_parser/block.cljs`
`extract-blocks` / `get-block-content`), so the headline-only IR was the sync
engine's own simplification, not Logseq's.  An optional `:body` string has
been added to the block plist, and the parsers and writers round-trip it.

Steps 1–7 are implemented: the IR schema, both parser sides, the writers,
same-format round-trip tests, cross-format body translation, and the doc
sweep.

Steps:

1. **Extend the IR block schema** with `:body` (string, omitted when empty) —
   the block's own body content between its first line and its child blocks
   (paragraphs, tables, code fences, quotes, `#+BEGIN_*` blocks).  It excludes
   `:properties`, `:scheduled`, `:deadline`, and `:children`, which remain
   separately modeled.
2. **Org parsers** (`logseq-org-sync-logseq--parse-block`,
   `logseq-org-sync-roam--parse-block`): read the headline's `section` body —
   the section's contents minus its `property-drawer` — canonicalize it, and
   store it as `:body`.
3. **Markdown parser** (`logseq-org-sync-logseq-markdown--collect-blocks` /
   `--parse-continuation`): instead of discarding unrecognized indented
   continuation lines, accumulate them as `:body` (de-indented to the block's
   content level), preserving blank lines, fenced code, and table rows.
4. **Writers** emit `:body` after the first line / planning / properties and
   before children:
   - org writers (`logseq-org-sync-logseq--format-block`,
     `logseq-org-sync-roam--format-block`) insert the body text directly;
   - Markdown writer (`logseq-org-sync-logseq-markdown--format-block`)
     re-indents each body line with the block's continuation indent.
5. **Same-format round-trips first.** Verify byte-for-byte round-trips for
   `org ↔ org` and `markdown ↔ markdown` (extend the existing round-trip
   tests), since these reuse each side's native body syntax.
6. **Cross-format.** Fenced code blocks translate natively
   (` ```lang ` … ` ``` ` ↔ `#+BEGIN_SRC lang` … `#+END_SRC`).  Markdown pipe
   tables are **not** translated to org tables; instead they are wrapped
   verbatim in a `#+BEGIN_SRC markdown` … `#+END_SRC` block on the org-roam
   side (§11.2).  Other `markdown ↔ org` body constructs (blockquotes,
   `#+BEGIN_*` blocks) remain deferred: such a body crossing formats is
   carried verbatim and documented as un-translated, or dropped on the
   foreign side.  This translation lives in
   `logseq-org-sync-reconcile--md-block-to-roam` /
   `--roam-block-to-logseq`, applied by `--translate-plan` for Markdown
   graphs (§9.11).
7. **Update docs** (`AGENTS.md` §5 IR table, §9.8/§9.9/§9.11,
   `LOGSEQ-FORMAT.md`, `ORG-ROAM-FORMAT`) — done.

Open decisions to resolve during implementation:

- `:body` canonicalization: both sides store raw body text with surrounding
  whitespace trimmed — the org parsers take the section body minus its
  planning line and `:PROPERTIES:` drawer, `string-trim`med; the Markdown
  parser de-indents continuation lines to the block's content level and drops
  trailing blank lines.  Writer idempotence (step 4) must reproduce this.
- whether `:body` stores raw text only, or a future structured AST (mirroring
  Logseq's `:block/body` vs `:block/content` split) is added later.

### 11.2 Markdown tables wrap in a `#+BEGIN_SRC markdown` block

Cross-format block bodies do **not** translate Markdown pipe tables into
native org tables.  A Markdown pipe table crossing from a Markdown-format
Logseq graph into its org-roam mirror is carried **verbatim** inside a
`#+BEGIN_SRC markdown` … `#+END_SRC` block (implemented in
`logseq-org-sync-reconcile--md-block-to-roam` /
`--roam-block-to-logseq`, §9.11).  Rationale: GFM and org tables
disagree on alignment storage (delimiter-row colons vs. org's auto-detected
`<l>`/`<c>`/`<r>` cookies), escaped pipes (`\|`) have no clean org-table
equivalent, and cell text would otherwise require per-cell inline translation.
The wrapper keeps the table byte-for-byte lossless and the round-trip
self-describing.

**Scope.** Markdown-graph ↔ org-roam only.  Logseq `.org` graphs and org-roam
both already use native org tables, so no wrapping happens there.

**Round-trip contract.**

- `logseq markdown → roam`: a block whose content is a pipe table (its first
  line and/or `:body` lines are `| … |` rows) is written with the full table
  text — header, any delimiter row, and data rows — verbatim inside
  `#+BEGIN_SRC markdown` … `#+END_SRC`, de-indented to the source block's
  content level.
- `roam → logseq markdown`: a `#+BEGIN_SRC markdown` block whose entire
  contents are a pipe table is unwrapped back to raw pipe-table lines,
  re-indented under the block with the block's continuation indent.

**Recognition (no extra metadata).** A `#+BEGIN_SRC markdown` block is a
wrapped table iff its contents are a Markdown pipe table: a header row
(`| … |`), an optional delimiter row (`|---|`, with optional `:` alignment
colons), and zero or more data rows — every non-blank line beginning and
ending with `|`.  A genuine Markdown source block whose sample text is itself
a valid pipe table is indistinguishable and round-trips back as a native
table on the Logseq side; this is an accepted, documented edge case.

**IR.** No structured table node is added.  A table travels inside the
block's `:body` string (§11.1): the Markdown parser/writer handles table rows
as body lines, and the org-roam parser/writer wraps/unwraps the
`#+BEGIN_SRC markdown` block.

**Assumptions / open details.**

- First cut assumes a table occupies its block's body (the common Logseq
  case); mixed paragraph+table content in one block is out of scope until
  `:body` can represent structured regions.
- Logseq frequently stores a table's header row as the block's first line
  (`:text`) with the remaining rows as continuation lines; the Markdown parser
  must recognize a `| … |` first line as a table row and join it with the
  `:body` rows before wrapping.
- The canonical wrapped form preserves the delimiter row and alignment colons
  exactly; neither side normalizes the table text.

### 11.3 Markdown block tags (`#tag`)

**Status.**  Implemented in the Markdown parser and writer
(`logseq-org-sync-logseq-markdown--make-block` / `--format-block`).  The org
sides (Logseq `.org` and org-roam) already read and write block `:tags` as
headline tags, so no org-side change was needed.

**Behavior.**

- Markdown parser: `#tag` and `#[[multi-word tag]]` in a block's first line
  are *stripped* from `:text` and collected into the block's `:tags`.  A plain
  `#tag` drops trailing sentence punctuation; a `#[[...]]` tag is normalized
  to underscore spelling (`#[[next week]]` → `next_week`) because org headline
  tags cannot contain whitespace.
- Markdown writer: the block's `:tags` are emitted at the end of the first
  line as `#tag` (in document order).
- org-roam / Logseq `.org`: unchanged — `:tags` already round-trips as `:tag:`.

**Decisions made.**

- *Strip* (not preserve): the tag leaves `:text` and lives only in `:tags`, so
  the round-trip is lossless with no duplication.
- *Position*: tags move to the end of the line (org's only headline-tag
  position); the first sync canonicalizes this and later runs are no-ops.
- *Multi-word spelling*: spaces normalize to `_`; the reverse maps an
  underscore tag back to a single `#tag` word (spaces are not recovered).
- *Case*: preserved verbatim on both sides (no lowercase normalization).
- *Deduplication*: `:tags` is the single source of truth; nothing is re-added
  to `:text`.

**Known limitations.**

- org headline tags are more restrictive than Logseq tag text
  (`[[:alnum:]_@#%]` only), so tags containing other characters (e.g. `+`,
  `:`, apostrophes) may produce an invalid org tag.
- A `#` inside a `[[...]]` page link is not protected from tag extraction.
- Trailing sentence punctuation on a plain `#tag` (`#tag.`) is dropped rather
  than kept as part of the tag.
