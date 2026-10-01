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
  (`logseq .org ↔ IR`; see §9.8).
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
- `tests/` — ERT test suites for the sync engine:
  - `tests/logseq-org-sync-logseq-test.el` (scanner, parser, round-trip).
  - `tests/logseq-org-sync-roam-test.el` (scanner, parser, round-trip).
  - `tests/logseq-org-sync-identity-test.el`.
  - `tests/logseq-org-sync-state-test.el`.
  - `tests/logseq-org-sync-reconcile-test.el` (seed, create/update,
    newest-wins, rename, delete/trash, dry-run, convergence).
  - `tests/logseq-org-sync-safety-test.el` (dry-run, backup, conflict prompt,
    updated hook).
- `Logseq-Demo-Graph-main/` — the upstream Logseq demo graph (`.md`; **not a
  usable fixture** — the supported Logseq format is `.org`).
- `Logseq-demo-graph-org/` — a `.org` demo graph (`pages/`, `journals/`,
  `logseq/`); a usable seed for Phase 0 fixtures. Its `config.edn` uses
  `:preferred-format "Org"`, `:preferred-workflow :now`, `:file/name-format
  :triple-lowbar`, and default journal filenames `yyyy_MM_dd`.  Its page
  properties were corrected to the canonical org form (`#+KEY:` in-buffer
  settings; see §3), not the markdown `key::` form.
- `LOGSEQ-FORMAT.md`, `ORG-ROAM-FORMAT` — AI-generated format notes (drafts with
  some inaccuracies; verify against the actual fixtures before relying on them).
- `fixtures/` — the Phase 0 fixtures: a minimal paired `Work` graph
  (`Work/logseq/` native Logseq `.org` graph and `Work/org-roam/` mirror) plus
  `fixtures/README.md` documenting the mapping, UUID legend, and round-trip
  contract.
- `Makefile`, `LICENSE`.

---

## 1. Locked architecture decisions

1. **Topology — two separate directories.** Each tree stays native to its own
   tool. A sync engine reads both and translates at the boundary. This replaces
   the current single-shared-directory model.

2. **Logseq side is `.org`.** Logseq must be configured with
   `:preferred-format :org`.

3. **Link strategy — each side native, sync translates.**
   - org-roam tree uses `[[id:uuid][Title]]` links (backlinks/graph work).
   - Logseq tree uses `[[Title]]` double-bracket links (Logseq graph works).
   - The sync converts between them, driven by the shared UUID identity.

4. **Shared identity — the org-roam `:ID:` UUID.**
   - org-roam side: `:ID: <uuid>` property.
   - Logseq side: `#+id: <uuid>` page property (an org in-buffer setting; the
     markdown form is `id:: <uuid>`, but the org graph uses `#+id:`).

5. **Content scope — basics first.** Identity → title/aliases → structure
   (blocks ↔ headings) → links. Deferred: block refs/embeds (see §6), asset
   relocation, full timestamp/tag translation.

6. **Conflicts — newest file wins** by default (no prompt). Prompt-on-conflict is
   a selectable option.

7. **Deletions — moved to a subdirectory** (trash), never hard-deleted.

---

## 2. Directory layout & responsibilities

The org-roam side **mirrors** the Logseq structure: one subdirectory per Logseq
graph, each containing `pages/` and `journals/`. This matches the existing
org-roam configuration (subdirectories per graph, each with `pages/` and
`journals/`).

```
;; Logseq side (native graph)
~/graphs/Work/
  pages/        Foo.org, Bar.org
  journals/     2024-01-01.org
  assets/                     ;; Logseq-only
  logseq/                     ;; Logseq-only (private state)
  config.edn                  ;; Logseq-only

;; org-roam side (mirror)
org-roam-directory/
  Work/
    pages/        Foo.org, Bar.org      ;; mirror of Logseq pages/
    journals/     2024-01-01.org        ;; mirror of Logseq journals/

<state-store>                 ;; one small metadata file (see §4)
```

The mapping is **1:1 on the relative path within a graph**:

- `<logseq-root>/Work/pages/Foo.org` ↔ `<org-roam-directory>/Work/pages/Foo.org`
- `<logseq-root>/Work/journals/2024-01-01.org` ↔ `<org-roam-directory>/Work/journals/2024-01-01.org`

This makes path discovery deterministic; the state store is for change
detection and rename handling, not for locating files.

**Logseq-only**: `assets/`, `logseq/`, `config.edn`. Consequence: local asset
links (e.g. `../assets/foo.png`) would be broken on the org-roam side; asset
relocation is deferred (see §11).

**Multi-graph**: each graph is an independent sync unit with its own config
(logseq dir, org-roam subdir, pages/journal dirs, date formats). The sync
operates **one graph at a time** (at least initially). Sketch (not final
code):

```elisp
(setq logseq-org-sync-graphs
      '(("work"
         :logseq-dir "~/graphs/Work"
         :roam-subdir "Work"     ;; relative to org-roam-directory
         :pages "pages" :journals "journals"
         :journal-file-format "%Y-%m-%d"
         :journal-title-format "%Y-%m-%d")
        ("personal" ...)))
```

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
| Logseq | `#+id: <uuid>` | `[[Title]]` |

The sync translates links in both directions using the UUID map:

- **`roam → logseq`**: `[[id:uuid][Title]]` → `[[Title]]` (UUID → title lookup).
- **`logseq → roam`**: `[[Title]]` → `[[id:uuid][Title]]` (title → UUID lookup).

Edge cases (reusing the existing package's logic):

- **Dead `[[Title]]` link** (no matching UUID): leave as a fuzzy link on the
  org-roam side by default; optional `create` mode creates the node, assigns a
  UUID, and converts the link.
- **Ambiguous title/alias** (two nodes share one): leave that link un-converted
  on both sides (the existing fuzzy-dict conflict handling).
- **Non-page links** (`[[file:...]]`, URLs, block refs, embeds): passed through
  untouched (the existing link-classification rules).

---

## 4. State store

A single small metadata file (human-readable plist/JSON), keyed by UUID. It
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
                       :properties (...) :refs (...) :children (...)))
      :links (list of (kind target description)))
```

Converters come in pure-ish pairs, each unit-testable:

- `logseq → IR` and `IR → logseq`
- `roam → IR` and `IR → roam`

Translation table:

| Concern | Logseq | IR | org-roam |
|---|---|---|---|
| Identity | `#+id: <uuid>` | `:id` | `:ID: <uuid>` |
| Title | filename (slug) | `:title` | `#+title:` |
| Aliases | `#+alias: a, b` | `:aliases` | `:ROAM_ALIASES:` |
| Tags | `#tag` / `tags::` | `:tags` | `#+filetags:` |
| Links | `[[Title]]` | `:links` | `[[id:uuid][Title]]` |
| Structure | bullets (outliner) | `:content` blocks | headings/document |
| TODO | `TODO`/`DOING`/`DONE` markers | `:todo` | org TODO keywords |
| Dates | `SCHEDULED:`/`DEADLINE:` | `:scheduled`/`:deadline` | org timestamps |

---

## 6. Block-level links

Logseq has two block-level reference types:

1. **Block reference** `((uuid))` — shows the referenced block inline, without
   its children, not editable.
2. **Block embed** `{{embed ((uuid))}}` — shows the block with its children,
   editable, changes propagate.

Both key off a block's `:id:` property in its `:PROPERTIES:` drawer.

Handling, phased:

| Construct | v1 | Later |
|---|---|---|
| `((uuid))` block reference | preserved verbatim | `((uuid))` ↔ `[[id:uuid][...]]` (see below) |
| `{{embed ((uuid))}}` block embed | preserved verbatim | preserved by default; optional lossy degrade to a reference |

Later-phase block-reference mapping: **adopt the Logseq block `:id:` as the
org-roam heading `:ID:`** (same UUID). Then:

- `((uuid))` (Logseq) ↔ `[[id:uuid][block text]]` (org-roam) — clean, lossless,
  and gives org-roam real block backlinks.
- Add `:ID:` only to headings whose source Logseq block had an `:id:` (i.e.,
  actually-referenced blocks), not to every bullet.

Embeds have no native org-roam equivalent. Default is verbatim preservation
(perfect round-trip, org-roam ignores them); opt-in mode degrades an embed to a
block reference (lossy: loses "editable + includes children" semantics).

---

## 7. Sync algorithm (each run)

1. **Scan** the Logseq `pages/` + `journals/` (`.org`) and the org-roam tree
   (`org-roam-list-files`).
2. **Hash** every file (SHA-256) and compare against the state store.
3. **Classify** each node by UUID (fall back to title/path matching for nodes
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
`[[id:uuid][Title]]` → `[[Title]]` is lossless. This is the testable contract
that distinguishes a real two-way sync from two one-way converters bolted
together.

---

## 9. Reuse of existing code

The legacy `logseq-org-roam` converter (§9.1–§9.7) now lives in the
`legacy/` subdirectory; the two-way sync engine (§9.8–§9.12) lives at the
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

The full suite (`make test`) passes: 23/23 legacy plus the Phase 2 (§9.8),
Phase 3 (§9.9), and Phase 4 (§9.10) suites. The only intentional behavior
change is the §9.5 fix (verified by `--parse-buffer--idempotent`).

### 9.8 Phase 2 module — `logseq-org-sync-logseq.el`

The Logseq side of the two-way sync engine.  It is a new, self-contained
package (namespace `logseq-org-sync-*`) that requires only `org`, `org-element`,
`cl-lib`, and `subr-x` — it does not reuse the legacy `logseq-org-roam` code.

**Canonical Logseq `.org` format.**  Page properties are org in-buffer settings
and blocks are org headlines:

```
#+id: <uuid>            ;; optional identity
#+alias: a, b           ;; optional aliases
#+<other>: value        ;; arbitrary page props, optional

* [TODO] block text [[Page]]
** child text
```

Block properties live in a `:PROPERTIES:` drawer on the block's own headline.
This is the org-mode form of Logseq properties (the markdown form is
`id::`/`alias::`/`key::`; the `.org` graph uses `#+id:`/`#+alias:`/`#+key:`).

**IR schema.**  A node is a plist with deterministic key order (nil keys are
omitted):

- `:title` — string, from the file name base.
- `:id` — string, or omitted.
- `:aliases` — list of strings, or omitted.
- `:properties` — alist `(("KEY" . "value") ...)` of arbitrary `#+KEY:`
  settings, in document order, or omitted.
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
- `:children` — list of nested block plists, or omitted.

**Public functions:** `logseq-org-sync-logseq-scan` (sorted absolute `.org`
paths under `pages/` + `journals/`), `logseq-org-sync-logseq-parse-buffer`,
`logseq-org-sync-logseq-parse-file`, `logseq-org-sync-logseq-format` (IR →
canonical string), and `logseq-org-sync-logseq-write`.

**Known limitations** (documented in the module commentary):

- Priority cookies (`[#A]`) are not supported (`org-element` drops the text
  preceding a priority cookie from `:raw-value`).
- Arbitrary page-property keys are normalized to uppercase on round-trip
  (`org-element` reports in-buffer keyword keys uppercased).
- Block references `((uuid))` and embeds `{{embed ((uuid))}}` are preserved
  verbatim in `:text` (see §6).
- Fuzzy-link collection skips org-internal links (`[[#custom-id]]`,
  `[[*heading]]`); image/asset links are not specially handled (deferred, §11).

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

* TODO block text [[id:<uuid>][Page]]
** child text
```

**IR.**  The node and block plists are exactly those of §9.8, with two
org-roam-side differences:

- `:title` is read from the `#+title:` keyword (falling back to the file name
  base) rather than derived from the file name base alone.
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
  verbatim in `:text` (see §6).
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
node's path relative to its root is the same on both sides (1:1 mapping).

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

**Known simplification.**  The reconciler hand-writes org-roam files with the
Phase 3 writer (`logseq-org-sync-roam-write`) rather than org-roam's capture
path (§9.10).  This keeps the engine and its tests independent of a live
org-roam database; routing new-node creation through `org-roam-capture-` is
deferred to the Phase 7 command/UX layer.

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

---

## 10. Implementation phases

1. **Phase 0 — Scope & fixtures.** Add a minimal Logseq `.org` fixture graph and
   a matching org-roam fixture for round-trip tests.
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

---

## 11. Deferred (documented limitations)

- Block refs/embeds (see §6) — verbatim in v1.
- Asset relocation and full timestamp/tag translation. Because `assets/` is
  Logseq-only, local asset links (e.g. `../assets/foo.png`) are broken on the
  org-roam side; v1 assumes no local assets or out-of-band asset sync.
- Live/continuous sync is a Phase 7 concern; v1 can be a manual command.
