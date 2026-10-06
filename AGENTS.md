# Logseq Markdown to Org-Roam Translation with Pandoc

## 1. Project Overview

This project provides a translation pipeline between **Logseq Markdown** graphs and **Org-roam v2 Org mode** documents using **Pandoc** and **Pandoc Lua filters**.

The goal is to leverage Pandoc's AST manipulation capabilities via Lua scripting to bridge the differences in data model and syntax between the two systems:
- **Source**: Logseq outliner Markdown files (`.md`) containing block indentation, page and block properties, embeds, block references (`((uuid))`), aliased links (`[Alias]([[Page]])`), planning lines (`SCHEDULED:`, `DEADLINE:`), and metadata.
- **Target**: Org-roam v2 documents (`.org`) containing top-level `:PROPERTIES:` drawers with `:ID:`, `:ROAM_ALIASES:`, `#+title:`, `#+filetags:`, standard document prose and headlines (`*`, `**`), headline property drawers, internal target anchors (`<<uuid>>`), and ID links (`[[id:uuid][Label]]`).
- **Scope**: Focus specifically on the non-standard features of Logseq Markdown (outlining, properties, embeds, block links, task planning) without attempting to re-implement Markdown/Org features already handled natively by Pandoc.
- **Future Goal**: Bidirectional conversion (Org-roam `.org` $\to$ Logseq `.md`).

---

## 2. Logseq Markdown Format Specification

Derived directly from the example graph files (`Logseq-Demo-Graph-main/pages/` and `journals/`):

### 2.1 Outliner Hierarchy & Indentation
- Logseq Markdown is **outliner-first**: every block is an indented bullet item starting with `- `.
- Outlining depth is indicated by **tabs** (or space indentations):
  - Top-level block: `- Block text`
  - Child block: `\t- Child text`
  - Grandchild block: `\t\t- Grandchild text`
- Empty bullet items (`- ` or `\t- `) are frequently inserted by users and the Logseq editor as vertical spacing between blocks.
- Blocks containing visual headings:
  - `- # Heading 1` or `# Heading 1`
  - `\t- ## Heading 2` or `\t## Heading 2`
  - `\t\t- ### Heading 3`

### 2.2 Page Properties
- Written at the very top of the `.md` file before the first block, or within the first block if it contains only properties:
  ```markdown
  property-example:: property-value
  icon:: 👠
  alias:: alias 1, alias 2
  tags:: tag1, tag2
  title:: Explicit Page Title
  id:: 6499faf4-36c5-44d2-ba2a-9e489b209292
  file:: [file.pdf](url)
  file-path:: url
  ```
- **Page Title**: If `title::` is absent, the page title is derived from the filename:
  - URL-encoded entities are decoded (e.g. `%3A` $\to$ `:`, `%20` $\to$ space).
  - Namespace separator `___` is converted to `/`.
  - Extension `.md` is stripped.
- **Page ID**: Stored in `id:: <uuid>`. If omitted, Org-roam requires a UUIDv4 to index the file as a node.
- **Page Aliases**: Stored as comma-separated values in `alias::` or `aliases::`.
- **Page Tags**: Stored as comma-separated values in `tags::` or `filetags::`.

### 2.3 Block Properties & Planning
- Continuation lines directly indented under a bullet block:
  ```markdown
  - Task item or block content
    id:: 6494c06d-09e2-430c-bd73-e8a336c3c06f
    collapsed:: true
    logseq.order-list-type:: number
    SCHEDULED: <2023-06-22 Thu 19:30>
    DEADLINE: <2023-06-25 Sun>
    custom-prop:: custom value
  ```
- **Block Identity**: `id:: <uuid>` provides identity for block references and embeds.
- **Collapse State**: `collapsed:: true`.
- **Ordered List Marker**: `logseq.order-list-type:: number` marks a list as ordered (numbered).
- **Planning**: `SCHEDULED: <timestamp>` and `DEADLINE: <timestamp>`.

### 2.4 Links, References, and Embeds
- **Page References**: `[[Page Title]]`.
- **Aliased Page References**: `[Display Label]([[Target Page]])`.
- **Bare Block References**: `((uuid))` referencing target block's `id:: <uuid>`.
- **Aliased Block References**: `[Display Label](((uuid)))`.
- **Block Embeds**: `{{embed ((uuid))}}`.
- **Page Embeds**: `{{embed [[Target Page]]}}`.
- **Asset Links**: Links to local files stored under `assets/` or drawings under `draws/`.
- **Media Macros**: `{{video https://youtu.be/...}}`, `{{youtube-timestamp 12}}`.

### 2.5 Tags
- Inline page tags: `#tag` or multi-word `#[[multi word tag]]`.
- Heading tags: Placed within or at the end of the heading line.

### 2.6 Inline Formatting & Special Blocks
- Highlights: `==highlight==` and `^^highlight^^`.
- Cloze deletions: `{{cloze text}}`.
- Inline break: `[:br]`.
- Native Org alerts in Markdown: `#+BEGIN_TIP ... #+END_TIP`, `#+BEGIN_NOTE`, `#+BEGIN_WARNING`, `#+BEGIN_IMPORTANT`, `#+BEGIN_CAUTION`, `#+BEGIN_PINNED`, `#+BEGIN_EXAMPLE`, `#+BEGIN_CENTER`, `#+BEGIN_QUOTE`.

---

## 3. Org-Roam v2 Format Specification

Derived from `ORG-ROAM-FORMAT.org`:

### 3.1 Node Model
- Org-roam (v2) operates on a **document-first** model (prose and headings) rather than outliner-first.
- Nodes are identified by an `:ID:` property in an Org `:PROPERTIES:` drawer:
  - **File-level node**: Top-level `:PROPERTIES:` drawer at line 1 of the file.
  - **Heading-level node**: A headline (`*`, `**`, etc.) carrying its own `:PROPERTIES:` drawer containing `:ID:`.

### 3.2 File-Level Structure
```org
:PROPERTIES:
:ID:       6499faf4-36c5-44d2-ba2a-9e489b209292
:ROAM_ALIASES: "alias 1" "alias 2"
:ICON:     👠
:FILE:     this
:END:
#+title: Page Title
#+filetags: :tag1:tag2:

Freeform document text, standard paragraphs, lists, and headings.

* Section Heading
:PROPERTIES:
:ID:       6494c06d-e5c4-4293-82aa-01aa600e2cb5
:END:
Content under section...
```

### 3.3 Elements Mapping
| Concern | Logseq Markdown | Org-roam Target |
| :--- | :--- | :--- |
| **Model** | Outliner-first (indented `- ` bullets) | Document-first (prose + `*` headlines) |
| **File ID** | `id:: <uuid>` page property | Top-level `:PROPERTIES:` drawer `:ID: <uuid>` |
| **Title** | `title::` or filename slug | `#+title: <title>` |
| **Aliases** | `alias:: a, b` or `aliases::` | `:ROAM_ALIASES: "a" "b"` in file drawer |
| **File Tags** | `tags:: a, b` or `filetags::` | `#+filetags: :a:b:` (Org colon tags) |
| **Arbitrary Props** | `key:: val` page property | `:KEY: val` in top `:PROPERTIES:` drawer |
| **Headings** | `- # Heading` or `# Heading` | `* Heading` (level 1-6) |
| **Heading ID** | `id:: <uuid>` under heading | Headline `:PROPERTIES:` drawer `:ID: <uuid>` |
| **Heading Tags** | `#tag` / `#[[multi word]]` on heading | `:tag:multi_word:` at end of headline |
| **List Item ID** | `id:: <uuid>` under list item | Dedicated anchor `<<uuid>> ` at start of item |
| **Page Links** | `[[Page Title]]` | `[[Page Title]]` |
| **Page Aliases** | `[Label]([[Page Title]])` | `[[Page Title][Label]]` |
| **Block Refs (bare)** | `((uuid))` | `[[id:uuid]]` |
| **Block Refs (aliased)**| `[Label](((uuid)))` | `[[id:uuid][Label]]` |
| **Block Embeds** | `{{embed ((uuid))}}` | Preserved `{{embed ((uuid))}}` (or `[[id:uuid][#embed]]`) |
| **Planning** | `SCHEDULED:` / `DEADLINE:` | Headline planning or indented under list item |
| **Ordered Lists** | `logseq.order-list-type:: number` | Org ordered list (`1. `, `2. `) |
| **Special Blocks** | `#+BEGIN_TIP ... #+END_TIP` | Native unescaped `#+BEGIN_TIP ... #+END_TIP` |

---

## 4. Pandoc Lua Filter Insights & Progress Made

### 4.1 Filter Location & Implementation
The filter has been created at:
```
filters/logseq-to-org.lua
```

### 4.2 Key Findings & Discoveries
1. **Pandoc Reader Option Conflicts**:
   - In Pandoc's default Markdown reader, empty bullets followed by sub-bullets (`\t-` on a separate line) can trigger the `simple_tables` extension, incorrectly turning entire nested outlines into simple ASCII tables.
   - **Solution**: Run Pandoc with `-f markdown-simple_tables-multiline_tables+mark-superscript` to ensure bullet outlines are cleanly parsed as nested `BulletList` AST nodes without spurious table conversions.
2. **Top-Level File Header via RawBlock**:
   - [ ] Pandoc's default Org writer does not natively write Org-roam top-level `:PROPERTIES:` drawers.
   - **Solution**: Emit the file `:PROPERTIES:` drawer, `#+title:`, and `#+filetags:` as a `pandoc.RawBlock('org', header_str)` at the beginning of the AST `doc.blocks`.
3. **Suppressing CUSTOM_ID**:
   - Pandoc generates `:CUSTOM_ID: heading-slug` for every header if `header.identifier` is non-empty.
   - **Solution**: Setting `header.identifier = ""` in the filter completely eliminates `:CUSTOM_ID:` and produces clean `:ID: <uuid>` inside `:PROPERTIES:`.
4. **Header Lifting from Bullet Lists**:
   - In Logseq, headings are often nested inside bullet items (`- # Heading 1`, `\t- ## Heading 2`). In Pandoc's AST, this creates a `BulletList` containing `Header` blocks. If left unhandled, Pandoc outputs `- \n * Heading 1` (invalid Org mode).
   - **Solution**: The filter identifies `Header` blocks in list items, strips associated properties (`id::`, `collapsed::`, planning), assigns them to the Header attributes, lifts the Header out to document/sibling level, and extracts headline tags.
5. **Preserving AST Inlines During Property Extraction**:
   - Properties in block continuation lines are separated by `SoftBreak` in the AST `content` array.
   - Earlier naive implementations stringified the content, which lost AST node types (links, code, formatting).
   - **Solution**: The filter splits inlines by `SoftBreak`/`LineBreak` into lines of inlines. Only lines matching `key:: val` or planning patterns are consumed; all other lines are preserved as intact AST inlines.
6. **Link & Embed Transformations**:
   - `[Label]([[Page]])` parses with target `%5B%5BPage%5D%5D`. Decoding and converting to `pandoc.RawInline("org", "[[Page][Label]]")` prevents Pandoc from adding unwanted `file:` prefixes.
   - `[Label](((uuid)))` parses with target `((uuid))` or `%28%28uuid%29%29`. It is converted to `pandoc.RawInline("org", "[[id:uuid][Label]]")`.
   - Bare `((uuid))` in text is transformed to `pandoc.RawInline("org", "[[id:uuid]]")`.
   - Embeds `{{embed ((uuid))}}` are identified and preserved verbatim.
7. **Unpacking Standalone Blocks**:
   - Logseq wraps quotes, code blocks, tables, and alert blocks inside bullets (`- `).
   - The filter unpacks standalone `CodeBlock`, `BlockQuote`, `Table`, `RawBlock`, and `#+BEGIN_*` alert blocks from list items so they render as clean, native Org blocks.
8. **Anchors for List Items**:
   - List items carrying `id:: <uuid>` have an internal Org anchor `<<uuid>> ` prepended to the item text, ensuring ID linkability without breaking the list.

### 4.3 Validation Results
Tested against multiple files in `Logseq-Demo-Graph-main/pages/`:
- `NewPage.md` $\to$ Clean file-level `:PROPERTIES:`, `:FILE: this`, `#+title: NewPage`.
- `Quick Start.md` $\to$ Clean outline headings with `:ID:` drawers, TOC linking to heading IDs, video captions, block anchors.
- `Formatting Style Guide.md` $\to$ Headings 1-5, numbered lists via `order-list-type`, block anchors, task keywords (`TODO`, `DOING`, `DONE`, `SCHEDULED`), embeds, media with `#+attr_html`/`#+attr_org` dimensions, alert blocks.
- `Publishing your Graph Online.md` $\to$ Clean multi-level outline nesting without spurious table conversion, numbered lists.
- `Favourite Plugins.md` $\to$ Anchors on top-level bullet blocks, section headings, media and asset links.
- `Working with Media Files...md` $\to$ Decoded title with colons, numbered sub-lists, tables.
- `journals/2023_06_22.md` $\to$ Journal page title, file ID drawer.

---

## 6. Logseq to Org-Roam Translation Implementation Details

The implementation in `filters/logseq-to-org.lua` handles the following Logseq features:

### 6.1 Hierarchy & Properties
- **Outliner Hierarchy**: Nested bullet lists in Markdown are preserved as nested lists in Org-mode, or lifted to headlines if they contain Logseq-style headings (`- # Heading`).
- **Page Properties**: Extracted from the start of the file and converted into a top-level Org `:PROPERTIES:` drawer.
  - `id::` $\to$ `:ID:` (generates deterministic UUID based on filename if missing).
  - `title::` $\to$ `#+title:`.
  - `alias::`/`aliases::` $\to$ `:ROAM_ALIASES:`.
  - `tags::`/`filetags::` $\to$ `#+filetags:` (standard Org colon-separated format).
- **Block Properties**: Properties like `id::` or `collapsed::` under a bullet are extracted. `id::` becomes an internal anchor `<<uuid>>` for list items or an `:ID:` property for headlines.
- **Ordered Lists**: Detected via `logseq.order-list-type:: number` and converted to Org ordered lists (`1.`, `2.`).

### 6.2 Links & References
- **Fuzzy Page Links**: `[[Page Name]]` is identified via lookahead buffering and converted to `[[Page Name]]`.
- **Aliased Page Links**: `[Alias]([[Page]])` is converted to `[[Page][Alias]]`.
- **Bare Block References**: `((uuid))` is converted to `[[id:uuid]]`.
- **Aliased Block References**: `[Label](((uuid)))` is converted to `[[id:uuid][Label]]`.
- **Block/Page Embeds**: `{{embed ((uuid))}}` and `{{embed [[Page]]}}` are converted to `[[id:uuid][#embed]]` and `[[Page][#embed]]` respectively to maintain semantic intent for Org-roam.
- **Asset/Drawing Links**: Paths starting with `assets/` or `draws/` are prefixed with `file:` and formatted as Org links.

### 6.3 Tasks & Planning
- **Task States**:
  - `LATER` $\to$ `TODO`
  - `NOW` $\to$ `NEXT`
  - `DOING` $\to$ `STARTED`
  - `WAITING` $\to$ `WAIT`
  - `CANCELLED` $\to$ `CANCELLED`
  - `TODO` and `DONE` are preserved.
- **Priority Cookies**: Logseq `[#A]`, `[#B]`, `[#C]` are correctly preserved and handled in headlines and list items.
- **Planning**: `SCHEDULED:` and `DEADLINE:` are extracted from block properties and placed in Org-style planning lines.

### 6.4 Formatting & Special Blocks
- **Highlights**: Both `==text==` and `^^text^^` are converted to Org `==text==`.
- **Cloze Deletions**: `{{cloze text}}` is preserved verbatim.
- **Math**: Both `$..$` and `$$..$$` are converted to standard Org-mode math LaTeX syntax.
- **Alert Blocks**: Logseq/Org-style alert blocks (`#+BEGIN_TIP`, etc.) are unpacked from bullets and preserved as native Org blocks.
- **Line Breaks**: `[:br]` is converted to `\\`.

---

## 8. Bidirectional Translation Status

Both forward and reverse translation filters are now implemented and verified.

### 8.1 Logseq $\to$ Org-Roam (`logseq-to-org.lua`)
- **Hierarchy**: Lifts headings from list items to headlines.
- **Properties**: Converts page and block properties to Org drawers.
- **Tasks**: Maps Logseq states (`LATER`, `NOW`, `DOING`) to Org (`TODO`, `NEXT`, `STARTED`).
- **Links/Embeds**: Converts fuzzy links and translates `{{embed ...}}` to `[[id:uuid][#embed]]`.
- **Assets**: Correctly prefixes `assets/` and `draws/` with `file:`.

### 8.2 Org-Roam $\to$ Logseq (`org-to-logseq.lua`)
- **Hierarchy**: Restores headlines to indented Logseq blocks.
- **Properties**: Restores Org drawers to Logseq `property:: value`.
- **Tasks**: Maps Org states (`TODO`, `NEXT`, `STARTED`) back to Logseq (`LATER`, `NOW`, `DOING`).
- **Embeds**: Restores `[[id:uuid][#embed]]` to Logseq `{{embed ((uuid))}}`.
- **Anchors**: Restores item anchors `<<uuid>>` to indented `id:: uuid` properties.

---

## 9. Testing and Verification

The project uses a `Makefile` to manage a comprehensive test suite in `tests-pandoc/`.

### Running Tests
To run all translation tests:
```bash
make test
```

To run only forward or reverse tests:
```bash
make test-forward
make test-reverse
```

The test suite compares Pandoc's output against manually verified files in `tests-pandoc/expected/`.

---

## 10. Completed Task Plan
- [x] **Phase 1**: Filter Refinement & CLI Runner (Replaced by Emacs integration).
- [x] **Phase 2**: Edge Case Handling (Priority cookies, Cloze, Multi-line, Assets).
- [x] **Phase 3**: Bidirectional Support (Implementation of `org-to-logseq.lua` and test suite).
- [x] **Phase 4**: Portability (Implementation of `Makefile` for testing).

### Phase 1: Filter Refinement & CLI Runner
- [ ] **Task 1.1: Standalone Runner Script**:
  - Create an executable runner script (`logseq-to-org.sh` or python CLI) that bundles the appropriate pandoc flags:
    ```bash
    pandoc -f markdown-simple_tables-multiline_tables+mark-superscript \
           -t org \
           --lua-filter filters/logseq-to-org.lua \
           "$input_file" -o "$output_file"
    ```
- [ ] **Task 1.2: Batch Graph Converter**:
  - Add support for converting an entire Logseq graph (`pages/` and `journals/`) into an Org-roam directory, mirroring directory layout and asset paths.
- [ ] **Task 1.3: Asset Path Rewriting**:
  - Ensure links to `../assets/...` and `draws/...` are correctly resolved relative to the target Org-roam folder.

### Phase 2: Edge Case Handling
- [ ] **Task 2.1: Multi-line Block Bodies**:
  - Review nested multi-line paragraphs under bullets to ensure indentations and line breaks preserve author formatting.
- [ ] **Task 2.2: Cloze & Math Syntax**:
  - Verify math formulas (`$$...$$` and `$..$`) and cloze deletions (`{{cloze ...}}`) in diverse contexts.
- [ ] **Task 2.3: Priority Cookies**:
  - Check Logseq priority markers (e.g. `[#A]`, `[#B]`) and map them to Org headline priorities `[#A]`.

### Phase 3: Reverse Translation (Org-Roam to Logseq Markdown)
- [ ] **Task 3.1: Specification for Org $\to$ Markdown**:
  - Map Org-roam file-level `:PROPERTIES:` and `#+title:` to Logseq front matter `id::`, `title::`, `tags::`, `alias::`.
  - Map Org headlines (`*`, `**`) to Logseq `- # Heading` or `# Heading`.
  - Map Org list items to indented Logseq bullets.
  - Map `[[id:uuid][Label]]` and `[[id:uuid]]` back to `[Label](((uuid)))` and `((uuid))`.
  - Map `[[Page Name][Alias]]` back to `[Alias]([[Page Name]])`.
- [ ] **Task 3.2: Implement `filters/org-to-logseq.lua`**:
  - Lua filter applied with `pandoc -f org -t markdown --lua-filter filters/org-to-logseq.lua`.
- [ ] **Task 3.3: Round-trip Testing**:
  - Convert Logseq `.md` $\to$ Org-roam `.org` $\to$ Logseq `.md` and verify semantic preservation and round-trip fidelity.
