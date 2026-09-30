# Logseq graph files format

 Please write a summary here of the format used for logseq graph files when they are saved as .org files. Search the internet for details. 
 





``` reasoning
**Defining the Focus**

I'm currently focused on defining the exact parameters of the request. The user needs a summary of how Logseq graph files are formatted when saved as Org-mode files. I'm taking care to respond succinctly, while also adhering to the user's needs. I'm making sure my answer is as clear as possible.


**Analyzing Logseq Org Files**

I'm now diving into how Logseq handles Org files, specifically focusing on its block and outlining structure. I've observed that each block within Logseq is stored as an Org headline, mirroring the outline's nesting depth. This means the number of asterisks correlates directly to the level of the outline.


**Examining Org Properties**

I'm now focusing on how Logseq handles properties in Org files. I see a distinction between Markdown and Org mode: properties reside within Org property drawers like `:PROPERTIES:`, unlike Markdown's `key:: value`. Page properties use Org metadata like `#+TITLE` or a top-level `:PROPERTIES:` section.



```

When a Logseq graph is configured to use Org-mode (`.org`), files adhere to standard Emacs Org syntax with a few specific structural conventions:

### 1. Blocks as Headlines
* **Hierarchy:** Unlike Markdown mode (where blocks are list bullets `- `), every Logseq block in an `.org` file is stored as an **Org headline** (`*`, `**`, `***`, etc.). The number of asterisks corresponds to the block nesting depth.
* **Multi-line Blocks:** The first line forms the headline title; any subsequent lines within the same block are plain text immediately beneath the headline.

### 2. Properties and Metadata
* **Block Properties:** Stored inside standard Org `:PROPERTIES:` drawers:
  ```org
  * My Block
  :PROPERTIES:
  :id: 64df19b0-1234-5678-9abc-def012345678
  :custom-key: value
  :heading: 2
  :END:
  ```
  *(Note: Because asterisks define block indentation rather than heading visual size, visual heading styling is recorded as a `:heading: <level>` property.)*
* **Page Metadata:** Defined at the top of the file via Org in-buffer settings (e.g., `#+TITLE:`, `#+ALIAS:`, `#+TAGS:`) or a file-level `:PROPERTIES:` drawer.

### 3. Tasks, Dates, and Time Tracking
* **Keywords:** Tasks use Org task keywords directly on the headline (e.g., `* TODO`, `* DOING`, `* LATER`, `* NOW`, `* DONE`).
* **Planning:** Native Org timestamps are used:
  ```org
  * TODO Write report
  SCHEDULED: <2026-10-01 Thu> DEADLINE: <2026-10-05 Mon>
  ```
* **Logbook:** Clocking and time tracking use native `:LOGBOOK:` drawers with `CLOCK: [start]--[end]` entries.

### 4. Links and References
* **Page Links:** Retain Org link syntax `[[Page Name]]` or standard descriptive links `[[https://example.com][Label]]`.
* **Block References / Embeds:** Represented as `((block-uuid))` or `{{embed ((block-uuid))}}`, corresponding to the target block's `:id:` property.

### 5. Blocks and Environments
* Code and quotes use standard Org structure blocks:
  * `#+BEGIN_SRC <language> ... #+END_SRC`
  * `#+BEGIN_QUOTE ... #+END_QUOTE`

### 

<!-- Local Variables: -->
<!-- gptel-model: gemini-flash-latest -->
<!-- gptel--backend-name: "GeminiSearch" -->
<!-- gptel--system-message: "You are a large language model living in Emacs and a helpful assistant. Respond concisely." -->
<!-- gptel--tool-names: nil -->
<!-- gptel--bounds: ((ignore (177 191) (1189 1193)) (response (191 1189) (1195 3201))) -->
<!-- End: -->
