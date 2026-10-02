;;; logseq-org-sync-logseq.el --- Logseq .org scanner, parser, writer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 logseq-org-sync authors

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.
;;
;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The Logseq side of the two-way sync engine (Phase 2): a scanner, a parser
;; (`logseq .org → IR' and `logseq Markdown → IR') and a writer (`IR →
;; logseq .org' and `IR → logseq Markdown').  It is independent of the legacy
;; one-way `logseq-org-roam' converter and lives in its own
;; `logseq-org-sync-*' namespace.
;;
;; The graph format is detected from the Logseq `config.edn' by
;; `logseq-org-sync-logseq-graph-format': an active `:preferred-format "Org"'
;; setting means org, anything else means Markdown.
;;
;; ## Canonical Logseq .org format
;;
;; A Logseq page is a `.org' file whose *page properties* are org in-buffer
;; settings and whose *blocks* are org headlines:
;;
;;     #+id: <uuid>            ;; optional page identity
;;     #+alias: a, b           ;; optional page aliases
;;     #+title: Display name   ;; optional page display title (overrides file name)
;;     #+tags: a, b            ;; optional page tags (comma-separated)
;;     #+filetags: :a:b:       ;; optional page tags (org colon form)
;;     #+<other>: value        ;; arbitrary page properties, optional
;;
;;     * [TODO] block text [[Page]]
;;     ** child text
;;
;; Block properties live in a `:PROPERTIES:' drawer on the block's own
;; headline.  This matches the conventions the legacy
;; `logseq-org-roam' parser already reads (`#+alias:' in-buffer settings, and
;; `:PROPERTIES:' drawers), and is *not* the markdown `key:: value' form.
;;
;; ## Intermediate representation (IR)
;;
;; A parsed node is a plist with this deterministic key order (nil keys are
;; omitted):
;;
;;     (:title "Foo" :id "uuid" :aliases ("a" "b") :tags ("a" "b")
;;      :properties (...) :content (block...) :links ((fuzzy "Target" nil)))
;;
;; - `:title'      string.  A `#+title:' keyword overrides the file name base,
;;                 mirroring Logseq's own page-name precedence (title property
;;                 → filename → first heading).
;; - `:id'         string, or omitted.
;; - `:aliases'    list of strings, or omitted.
;; - `:tags'       list of strings, or omitted.  Read from `#+tags:'
;;                 (comma-separated) and `#+filetags:' (org colon form
;;                 `:a:b:'), merged in document order.
;; - `:properties' alist `(("KEY" . "value") ...)' of arbitrary `#+KEY:'
;;                 settings (excluding id/alias/title/tags/filetags) in
;;                 document order, or omitted.  Keys are uppercased as
;;                 `org-element' reports them.
;; - `:content'    ordered list of block plists, or omitted when empty.
;; - `:links'      list of `(fuzzy TARGET DESCRIPTION)' tuples (DESCRIPTION is
;;                 nil for a plain `[[TARGET]]'), or omitted when empty.
;;
;; A block is a plist with this deterministic key order (nil keys omitted):
;;
;;     (:level N :todo "TODO" :text "..." :tags (...) :properties (...)
;;      :scheduled "<...>" :deadline "<...>" :children (...))
;;
;; - `:level'      positive integer.
;; - `:text'       string (the headline `:raw-value', markup preserved).
;; - `:todo'       TODO keyword string, or omitted.
;; - `:tags'       list of strings, or omitted.
;; - `:properties' alist from the block's own `:PROPERTIES:' drawer, or omitted.
;; - `:scheduled' / `:deadline' raw timestamp strings, or omitted.
;; - `:children'   list of nested block plists, or omitted.
;;
;; ## Known limitations
;;
;; - Priority cookies (`[#A]') are not supported: `org-element' drops the text
;;   preceding a priority cookie from a headline's `:raw-value'.
;; - Arbitrary page property keys are normalized to uppercase on round-trip,
;;   because `org-element' reports in-buffer keyword keys uppercased.
;; - Block references `((uuid))' and embeds `{{embed ((uuid))}}' are preserved
;;   verbatim in `:text' by this parse/write module; the reconciler translates
;;   them cross-side (see AGENTS.md §6).
;; - Fuzzy-link collection skips org-internal links (`[[#custom-id]]',
;;   `[[*heading]]'); image/asset links are not specially handled (deferred).
;; - Headline body content (paragraphs, `#+BEGIN_*' blocks, tables) is parsed
;;   into the block's `:body' field and round-trips same-format; cross-format
;;   body translation is still deferred (AGENTS.md §11.1/§11.2).
;;
;; ## Canonical Logseq Markdown format
;;
;; A Markdown Logseq page stores page properties as leading `key:: value'
;; lines and blocks as indented unordered list items:
;;
;;     id:: <uuid>            ;; optional page identity
;;     alias:: a, b           ;; optional page aliases
;;     tags:: a, b            ;; optional page tags
;;     <other>:: value        ;; arbitrary page properties
;;
;;     - TODO block text [[Page]]
;;     	- child text
;;
;; Block properties and planning lines are continuation lines indented under
;; their block (`  key:: value', `  SCHEDULED: <...>').  Visual heading blocks
;; are recognized from `#'-prefixed text and stored as a `heading' block
;; property, mirroring Logseq's org representation.  The Markdown parser uses
;; the `markdown-inline' tree-sitter grammar for link extraction when it is
;; available and falls back to a regexp otherwise.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'treesit)

(defun logseq-org-sync-logseq--config-file (root)
  "Return the readable Logseq config file under ROOT, or nil.
Checks ROOT/logseq/config.edn first (the real Logseq layout), then
ROOT/config.edn (the layout used by the Phase 0 fixtures)."
  (let ((candidates (list (expand-file-name "logseq/config.edn" root)
                          (expand-file-name "config.edn" root))))
    (cl-find-if #'file-readable-p candidates)))

(defun logseq-org-sync-logseq-graph-format (root)
  "Return `org' or `markdown' for the Logseq graph rooted at ROOT.
Read the graph's config.edn, drop `;;' comment lines, and look for
`:preferred-format' followed by whitespace and \"Org\".  When that
setting is present the graph is org; otherwise it is markdown."
  (let ((config (logseq-org-sync-logseq--config-file root)))
    (if (and config
             (with-temp-buffer
               (insert-file-contents config)
               (goto-char (point-min))
               (let ((found nil))
                 (while (and (not found) (not (eobp)))
                   (let ((line (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position))))
                     (unless (string-match-p "\\`[ \t]*;;" line)
                       (when (string-match-p ":preferred-format[ \t]+\"Org\"" line)
                         (setq found t))))
                   (forward-line 1))
                 found)))
        'org
      'markdown)))

;;;###autoload
(defun logseq-org-sync-logseq-scan (root &optional pages-directory journals-directory format)
  "Return sorted absolute paths to Logseq note files under ROOT.
Scan ROOT/PAGES-DIRECTORY and ROOT/JOURNALS-DIRECTORY recursively.
PAGES-DIRECTORY defaults to \"pages\" and JOURNALS-DIRECTORY to
\"journals\".  FORMAT is `org' or `markdown' and defaults to the
graph's configured format (see `logseq-org-sync-logseq-graph-format')."
  (let* ((format (or format (logseq-org-sync-logseq-graph-format root)))
         (regexp (if (eq format 'markdown) "\\.md\\'" "\\.org\\'"))
         (pages (or pages-directory "pages"))
         (journals (or journals-directory "journals"))
         (files nil))
    (dolist (dir (list (expand-file-name pages root)
                       (expand-file-name journals root)))
      (when (file-directory-p dir)
        (setq files (nconc files (directory-files-recursively dir regexp)))))
    (sort files #'string<)))

(defun logseq-org-sync-logseq--first-section (data)
  "Return DATA's top-level `section' element, or nil.
DATA is an `org-data' parse tree."
  (cl-find-if (lambda (element) (eq (org-element-type element) 'section))
              (org-element-contents data)))

(defun logseq-org-sync-logseq--block-properties (headline)
  "Return HEADLINE's own block properties as an alist of (KEY . VALUE).
Only the `:PROPERTIES:' drawer belonging directly to HEADLINE is read;
child headlines' drawers are ignored."
  (let ((section (cl-find-if (lambda (element)
                               (eq (org-element-type element) 'section))
                             (org-element-contents headline))))
    (when section
      (let ((props nil))
        (dolist (np (org-element-map section 'node-property #'identity))
          (push (cons (org-element-property :key np)
                      (org-element-property :value np))
                props))
        (nreverse props)))))

(defun logseq-org-sync-logseq--block-body (headline)
  "Return HEADLINE's own body text, or nil when empty.
The body is the headline's section contents minus its planning line and
`:PROPERTIES:' drawer, trimmed of surrounding whitespace."
  (let ((section (cl-find-if (lambda (element)
                               (eq (org-element-type element) 'section))
                             (org-element-contents headline))))
    (when section
      (let* ((begin (or (org-element-property :contents-begin section)
                        (org-element-property :begin section)))
             (end (or (org-element-property :contents-end section)
                      (org-element-property :end section)))
             (boundaries
              (cl-remove-if-not
               (lambda (element)
                 (memq (org-element-type element) '(planning property-drawer)))
               (org-element-contents section)))
             (body-begin
              (or (and boundaries
                       (apply #'max
                              (mapcar (lambda (element)
                                        (org-element-property :end element))
                                      boundaries)))
                  begin)))
        (let ((body (buffer-substring-no-properties body-begin end)))
          (setq body (string-trim body))
          (and (not (string-empty-p body)) body))))))

(defun logseq-org-sync-logseq--parse-block (headline)
  "Parse HEADLINE (an org-element) into a block plist."
  (let* ((level (org-element-property :level headline))
         (todo (org-element-property :todo-keyword headline))
         (text (org-element-property :raw-value headline))
         (tags (org-element-property :tags headline))
         (props (logseq-org-sync-logseq--block-properties headline))
         (body (logseq-org-sync-logseq--block-body headline))
         (scheduled (let ((s (org-element-property :scheduled headline)))
                      (when s (org-element-property :raw-value s))))
         (deadline (let ((d (org-element-property :deadline headline)))
                     (when d (org-element-property :raw-value d))))
         (children (mapcar #'logseq-org-sync-logseq--parse-block
                           (cl-remove-if-not
                            (lambda (element)
                              (eq (org-element-type element) 'headline))
                            (org-element-contents headline))))
         (block (list :level level)))
    (when todo (setq block (plist-put block :todo todo)))
    (setq block (plist-put block :text text))
    (when tags (setq block (plist-put block :tags tags)))
    (when props (setq block (plist-put block :properties props)))
    (when scheduled (setq block (plist-put block :scheduled scheduled)))
    (when deadline (setq block (plist-put block :deadline deadline)))
    (when body (setq block (plist-put block :body body)))
    (when children (setq block (plist-put block :children children)))
    block))

(defun logseq-org-sync-logseq--parse-links (data)
  "Return DATA's fuzzy page links as (fuzzy TARGET DESCRIPTION) tuples.
DESCRIPTION is nil for a plain `[[TARGET]]' link.  Internal links
\(`[[#custom-id]]', `[[*heading]]') are skipped."
  (let ((links nil))
    (org-element-map data 'link
      (lambda (link)
        (when (string= (org-element-property :type link) "fuzzy")
          (let* ((path (org-element-property :path link))
                 (contents-begin (org-element-property :contents-begin link))
                 (descr (when contents-begin
                          (buffer-substring-no-properties
                           contents-begin
                           (org-element-property :contents-end link)))))
            (unless (string-match-p "\\`[#*]" path)
              (push (list 'fuzzy path descr) links))))))
    (nreverse links)))

;;;###autoload
(defun logseq-org-sync-logseq-parse-buffer (&optional title)
  "Parse the current buffer as a Logseq .org file into a node plist.
TITLE is the fallback title, defaulting to the buffer file name base.
A `#+title:' keyword overrides TITLE, matching Logseq's own page-name
precedence (title property → filename → first heading)."
  (let* ((data (org-element-parse-buffer))
         (section (logseq-org-sync-logseq--first-section data))
         (node (list :title (or title
                                (file-name-base (or buffer-file-name ""))))))
    (when section
      (let ((id nil) (aliases nil) (tags nil) (title-value nil) (props nil))
        (dolist (kw (org-element-map section 'keyword #'identity))
          (let ((key (org-element-property :key kw))
                (value (org-element-property :value kw)))
            (cond
             ((string= key "ID") (setq id value))
             ((string= key "ALIAS")
              (setq aliases (split-string value "\\s-*,\\s-*" t)))
             ((string= key "TITLE") (setq title-value value))
             ((string= key "TAGS")
              (setq tags (append tags (split-string value "\\s-*,\\s-*" t))))
             ((string= key "FILETAGS")
              (setq tags (append tags (split-string value ":" t "\\s-*"))))
             (t (push (cons key value) props)))))
        (when title-value (setq node (plist-put node :title title-value)))
        (when id (setq node (plist-put node :id id)))
        (when aliases (setq node (plist-put node :aliases aliases)))
        (when tags (setq node (plist-put node :tags (delete-dups tags))))
        (when props (setq node (plist-put node :properties (nreverse props))))))
    (let ((blocks (mapcar #'logseq-org-sync-logseq--parse-block
                          (cl-remove-if-not
                           (lambda (element)
                             (eq (org-element-type element) 'headline))
                           (org-element-contents data)))))
      (when blocks (setq node (plist-put node :content blocks))))
    (let ((links (logseq-org-sync-logseq--parse-links data)))
      (when links (setq node (plist-put node :links links))))
    node))

;;;###autoload
(defun logseq-org-sync-logseq-org-parse-file (file)
  "Parse Logseq .org FILE into a node plist.
The node `:title' is derived from FILE's name base."
  (with-temp-buffer
    (let ((default-directory (or (file-name-directory file) default-directory)))
      (delay-mode-hooks
        (let ((org-inhibit-startup t))
          (org-mode)))
      (insert-file-contents file)
      (logseq-org-sync-logseq-parse-buffer (file-name-base file)))))

(defun logseq-org-sync-logseq--markdown-file-p (file)
  "Return non-nil when FILE has a Markdown extension."
  (string-match-p "\\.\\(md\\|markdown\\)\\'" (downcase file)))

;;;###autoload
(defun logseq-org-sync-logseq-parse-file (file)
  "Parse Logseq FILE into a node plist.
The parser is chosen from FILE's extension: `.md'/`.markdown' files use
the Markdown parser; everything else uses the .org parser."
  (if (logseq-org-sync-logseq--markdown-file-p file)
      (logseq-org-sync-logseq-markdown-parse-file file)
    (logseq-org-sync-logseq-org-parse-file file)))

(defun logseq-org-sync-logseq--format-headline (level todo text tags)
  "Format a headline line from LEVEL, TODO, TEXT and TAGS."
  (let ((line (make-string level ?*)))
    (when todo (setq line (concat line " " todo)))
    (when (and text (not (string-empty-p text)))
      (setq line (concat line " " text)))
    (when tags (setq line (concat line " :" (mapconcat #'identity tags ":") ":")))
    line))

(defun logseq-org-sync-logseq--format-block (block)
  "Return BLOCK (a block plist) formatted as a list of lines."
  (let* ((level (plist-get block :level))
         (todo (plist-get block :todo))
         (text (plist-get block :text))
         (tags (plist-get block :tags))
         (props (plist-get block :properties))
         (scheduled (plist-get block :scheduled))
         (deadline (plist-get block :deadline))
         (children (plist-get block :children))
         (body (plist-get block :body))
         (lines (list (logseq-org-sync-logseq--format-headline
                       level todo text tags))))
    (cond
     ((and scheduled deadline)
      (setq lines (append lines
                          (list (concat "SCHEDULED: " scheduled
                                        " DEADLINE: " deadline)))))
     (scheduled (setq lines (append lines (list (concat "SCHEDULED: " scheduled)))))
     (deadline (setq lines (append lines (list (concat "DEADLINE: " deadline))))))
    (when props
      (setq lines (append lines (list ":PROPERTIES:")))
      (dolist (prop props)
        (setq lines (append lines (list (concat ":" (car prop) ": " (cdr prop))))))
      (setq lines (append lines (list ":END:"))))
    (when body
      (setq lines (append lines (split-string body "\n"))))
    (dolist (child children)
      (setq lines (append lines (logseq-org-sync-logseq--format-block child))))
    lines))

;;;###autoload
(defun logseq-org-sync-logseq-format (node)
  "Format NODE (an IR node plist) into a canonical Logseq .org string."
  (let ((lines nil))
    ;; Page properties (in-buffer settings), in document order.
    (let ((id (plist-get node :id)))
      (when id (push (concat "#+id: " id) lines)))
    (let ((aliases (plist-get node :aliases)))
      (when aliases
        (push (concat "#+alias: " (mapconcat #'identity aliases ", ")) lines)))
    (let ((tags (plist-get node :tags)))
      (when tags
        (push (concat "#+tags: " (mapconcat #'identity tags ", ")) lines)))
    (let ((props (plist-get node :properties)))
      (dolist (prop props)
        (push (concat "#+" (car prop) ": " (cdr prop)) lines)))
    (setq lines (nreverse lines))
    ;; Blocks, separated from properties by a blank line when both exist.
    (let ((content nil))
      (dolist (block (plist-get node :content))
        (setq content (append content (logseq-org-sync-logseq--format-block block))))
      (when (and lines content)
        (setq lines (append lines (list ""))))
      (setq lines (append lines content)))
    (if lines
        (concat (mapconcat #'identity lines "\n") "\n")
      "")))

;;;###autoload
(defun logseq-org-sync-logseq-org-write (node file)
  "Write NODE to FILE in canonical Logseq .org form."
  (let ((text (logseq-org-sync-logseq-format node)))
    (with-temp-buffer
      (insert text)
      (write-region (point-min) (point-max) file))))

;;;###autoload
(defun logseq-org-sync-logseq-write (node file)
  "Write NODE to FILE in the Logseq format matching FILE's extension.
`.md'/`.markdown' files use the Markdown writer; everything else uses the
.org writer."
  (if (logseq-org-sync-logseq--markdown-file-p file)
      (logseq-org-sync-logseq-markdown-write node file)
    (logseq-org-sync-logseq-org-write node file)))

;;; ---------------------------------------------------------------------------
;;; Markdown side (Logseq `:preferred-format "Markdown"')
;;; ---------------------------------------------------------------------------

(defconst logseq-org-sync-logseq-markdown-todo-keywords
  '("TODO" "DOING" "DONE" "NOW" "LATER" "CANCELLED" "CANCELED" "WAIT" "WAITING")
  "Logseq task markers recognized at the start of a Markdown block.")

(defun logseq-org-sync-logseq-markdown--leading-whitespace (line)
  "Return LINE's leading tabs and spaces."
  (if (string-match "\\`[ \t]*" line) (match-string 0 line) ""))

(defun logseq-org-sync-logseq-markdown--property-line-p (line)
  "Return non-nil when LINE is a `key:: value' property line.
LINE should already have leading whitespace removed."
  (string-match-p "\\`\\([^[:space:]:]+\\)::[ \t]*\\(.*\\)\\'" line))

(defun logseq-org-sync-logseq-markdown--parse-property (line)
  "Parse property LINE into a (KEY . VALUE) cons."
  (string-match "\\`\\([^[:space:]:]+\\)::[ \t]*\\(.*\\)\\'" line)
  (cons (match-string 1 line) (string-trim-right (match-string 2 line))))

(defun logseq-org-sync-logseq-markdown--block-line-p (line)
  "Return non-nil when raw LINE begins a Logseq Markdown block.
Recognizes unordered bullet blocks (`- ', `* ', `+ ', or a bare `-') and
top-level ATX heading blocks (`# Heading')."
  (let* ((ws (logseq-org-sync-logseq-markdown--leading-whitespace line))
         (rest (substring line (length ws))))
    (or (string-match-p "\\`[-+*]\\(?:[ \t]+\\(.*\\)\\|\\'\\)" rest)
        (and (string-empty-p ws)
             (string-match-p "\\`#\\{1,6\\}[ \t]+" rest)))))

(defun logseq-org-sync-logseq-markdown--indent-unit (lines)
  "Return the indentation unit used by block LINES.
Returns `tab' when any block line is tab-indented; otherwise the
smallest positive space indentation (or 1 when there is none)."
  (let ((tabs nil) (spaces nil))
    (dolist (line lines)
      (when (logseq-org-sync-logseq-markdown--block-line-p line)
        (let ((ws (logseq-org-sync-logseq-markdown--leading-whitespace line)))
          (cond
           ((string-match-p "\t" ws) (setq tabs t))
           ((> (length ws) 0) (push (length ws) spaces))))))
    (cond (tabs 'tab)
          (spaces (apply #'min spaces))
          (t 1))))

(defun logseq-org-sync-logseq-markdown--block-level (line unit)
  "Return LINE's outline level given indentation UNIT."
  (let ((ws (logseq-org-sync-logseq-markdown--leading-whitespace line)))
    (cond
     ((string-empty-p ws) 1)
     ((eq unit 'tab) (+ 1 (cl-count ?\t ws)))
     (t (+ 1 (/ (length ws) unit))))))

(defun logseq-org-sync-logseq-markdown--parse-block-line (line)
  "Parse raw block LINE into (HEADING TODO TEXT).
HEADING is a heading level (integer) or nil, TODO is a task marker or
nil, and TEXT is the block text with markers removed."
  (let* ((ws (logseq-org-sync-logseq-markdown--leading-whitespace line))
         (rest (substring line (length ws))))
    (cond
     ;; Bare top-level ATX heading block.
     ((and (string-empty-p ws)
           (string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)\\'" rest))
      (list (length (match-string 1 rest)) nil
            (string-trim (match-string 2 rest))))
     ;; Bullet block (`- text', `- # Heading', or empty `-').
     ((string-match "\\`[-+*]\\(?:[ \t]+\\(.*\\)\\|\\'\\)" rest)
      (let* ((content (or (match-string 1 rest) ""))
             (content (string-trim content))
             (heading nil)
             (todo nil))
        (when (string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)\\'" content)
          (setq heading (length (match-string 1 content))
                content (string-trim (match-string 2 content))))
        (unless heading
          (let ((re (concat "\\`\\("
                            (regexp-opt logseq-org-sync-logseq-markdown-todo-keywords)
                            "\\)[ \t]+\\(.*\\)\\'")))
            (when (string-match re content)
              (setq todo (match-string 1 content)
                    content (string-trim (match-string 2 content))))))
        (list heading todo content)))
     (t (error "Not a Logseq Markdown block line: %S" line)))))

(defun logseq-org-sync-logseq-markdown--make-block (level heading todo text)
  "Return a block plist for LEVEL, HEADING, TODO and TEXT."
  (let ((block (list :level level)))
    (when todo (setq block (plist-put block :todo todo)))
    (when (and text (not (string-empty-p text)))
      (setq block (plist-put block :text text)))
    (when heading
      (setq block (plist-put block :properties
                             (list (cons "heading" (number-to-string heading))))))
    block))

(defun logseq-org-sync-logseq-markdown--parse-continuation (block line)
  "Merge continuation LINE into BLOCK and return the updated block.
Recognizes `SCHEDULED:', `DEADLINE:', and `key:: value' block properties.
Body lines are handled separately by `--collect-blocks'."
  (let ((trimmed (string-trim-left line)))
    (cond
     ((string-match "\\`SCHEDULED:[ \t]*\\(.*\\)\\'" trimmed)
      (plist-put block :scheduled (string-trim (match-string 1 trimmed))))
     ((string-match "\\`DEADLINE:[ \t]*\\(.*\\)\\'" trimmed)
      (plist-put block :deadline (string-trim (match-string 1 trimmed))))
     ((logseq-org-sync-logseq-markdown--property-line-p trimmed)
      (let* ((prop (logseq-org-sync-logseq-markdown--parse-property trimmed))
             (key (car prop)))
        (unless (string= (downcase key) "heading")
          (let ((props (append (plist-get block :properties)
                               (list (cons key (cdr prop))))))
            (setq block (plist-put block :properties props))))))
     (t nil))
    block))

(defun logseq-org-sync-logseq-markdown--continuation-line-p (line)
  "Return non-nil when LINE is a recognized block continuation.
Recognized continuations are `SCHEDULED:', `DEADLINE:', and `key:: value'
block-property lines; everything else is body content."
  (let ((trimmed (string-trim-left line)))
    (or (string-match-p "\\`SCHEDULED:[ \t]*\\(.*\\)\\'" trimmed)
        (string-match-p "\\`DEADLINE:[ \t]*\\(.*\\)\\'" trimmed)
        (logseq-org-sync-logseq-markdown--property-line-p trimmed))))

(defun logseq-org-sync-logseq-markdown--separator-line-p (line cindent)
  "Return non-nil when LINE separates blocks instead of continuing one.
A blank line is a separator unless it carries the continuation indent
CINDENT, in which case it is a blank line inside a block's body."
  (and (string-blank-p (string-trim line))
       (not (string-prefix-p cindent line))))

(defun logseq-org-sync-logseq-markdown--deindent (line cindent)
  "Remove the continuation indent CINDENT from LINE.
Falls back to stripping leading whitespace when LINE does not begin with
CINDENT."
  (if (string-prefix-p cindent line)
      (substring line (length cindent))
    (string-trim-left line)))

(defun logseq-org-sync-logseq-markdown--collect-blocks (lines unit)
  "Return a flat list of block plists (no `:children') from LINES.
UNIT is the indentation unit returned by
`logseq-org-sync-logseq-markdown--indent-unit'.  Unrecognized indented
continuation lines are collected as the block's `:body'."
  (let ((blocks nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-blank-p (string-trim line))
          (setq lines (cdr lines)))
         ((logseq-org-sync-logseq-markdown--block-line-p line)
          (let* ((parsed (logseq-org-sync-logseq-markdown--parse-block-line line))
                 (level (logseq-org-sync-logseq-markdown--block-level line unit))
                 (block (logseq-org-sync-logseq-markdown--make-block
                         level (nth 0 parsed) (nth 1 parsed) (nth 2 parsed)))
                 (rest (cdr lines))
                 (cindent
                  (concat (logseq-org-sync-logseq-markdown--leading-whitespace line)
                          "  "))
                 (body-lines nil))
            (while (and rest
                        (not (logseq-org-sync-logseq-markdown--block-line-p
                              (car rest)))
                        (not (logseq-org-sync-logseq-markdown--separator-line-p
                              (car rest) cindent)))
              (let ((raw (car rest)))
                (if (logseq-org-sync-logseq-markdown--continuation-line-p raw)
                    (setq block (logseq-org-sync-logseq-markdown--parse-continuation
                                 block raw))
                  (push (logseq-org-sync-logseq-markdown--deindent raw cindent)
                        body-lines)))
              (setq rest (cdr rest)))
            (setq body-lines (nreverse body-lines))
            (while (and body-lines (string-empty-p (car (last body-lines))))
              (setq body-lines (butlast body-lines)))
            (when body-lines
              (setq block (plist-put block :body
                                     (mapconcat #'identity body-lines "\n"))))
            (push block blocks)
            (setq lines rest)))
         (t (setq lines (cdr lines))))))
    (nreverse blocks)))

(defun logseq-org-sync-logseq-markdown--assemble (blocks level)
  "Assemble flat BLOCKS into a tree, consuming blocks at LEVEL.
Return (TREE . REST), where TREE is a list of block plists with
`:children' populated and REST is the first unconsumed block list."
  (let ((children nil))
    (catch 'return
      (while blocks
        (let* ((block (car blocks))
               (lvl (plist-get block :level)))
          (cond
           ((< lvl level)
            (throw 'return (cons (nreverse children) blocks)))
           ((= lvl level)
            (let ((result (logseq-org-sync-logseq-markdown--assemble
                           (cdr blocks) (1+ level))))
              (when (car result)
                (setq block (plist-put block :children (car result))))
              (setq blocks (cdr result))
              (push block children)))
           (t (setq blocks (cdr blocks))))))
      (cons (nreverse children) blocks))))

(defun logseq-org-sync-logseq-markdown--split-page-properties (lines)
  "Split LINES into (PAGE-PROPERTIES . REST).
Leading `key:: value' lines are page properties."
  (let ((props nil) (rest lines))
    (while (and rest
                (let ((line (car rest)))
                  (and (not (string-blank-p line))
                       (logseq-org-sync-logseq-markdown--property-line-p line))))
      (push (pop rest) props))
    (cons (nreverse props) rest)))

(defun logseq-org-sync-logseq-markdown--inline-child-text (node type)
  "Return the trimmed text of NODE's TYPE child, or nil."
  (let ((child (treesit-search-subtree node (concat "\\`" type "\\'"))))
    (when child (string-trim (treesit-node-text child t)))))

(defun logseq-org-sync-logseq-markdown--collect-links (node links)
  "Append fuzzy page links found under NODE to LINKS and return them.
Uses the `markdown-inline' tree-sitter grammar, then recognizes Logseq's
`[[Target]]' and `[Description]([[Target]])' link spellings."
  (dolist (child (treesit-node-children node nil))
    (let ((type (treesit-node-type child)))
      (cond
       ((equal type "inline_link")
        (let ((dest (logseq-org-sync-logseq-markdown--inline-child-text
                     child "link_destination"))
              (descr (logseq-org-sync-logseq-markdown--inline-child-text
                      child "link_text")))
          (when (and dest (string-match "\\`\\[\\[\\(.*?\\)\\]\\]\\'" dest))
            (push (list 'fuzzy (match-string 1 dest)
                        (and descr (not (string-empty-p descr)) descr))
                  links))))
       ((equal type "shortcut_link")
        (let* ((start (treesit-node-start child))
               (end (treesit-node-end child))
               (before (and (> start 1) (char-before start)))
               (after (char-after end)))
          ;; `[[Page]]' parses as `[` + shortcut_link + `]'.
          (when (and (eq before ?\[) (eq after ?\]))
            (let ((target (logseq-org-sync-logseq-markdown--inline-child-text
                           child "link_text")))
              (when target (push (list 'fuzzy target nil) links)))))))))
  (dolist (child (treesit-node-children node t))
    (setq links (logseq-org-sync-logseq-markdown--collect-links child links)))
  links)

(defun logseq-org-sync-logseq-markdown--extract-links-regexp (text)
  "Return Logseq page links in TEXT using a regexp fallback.
Handles `[[Target]]' and `[Description]([[Target]])' spellings."
  (let ((links nil)
        (start 0)
        (re "\\[\\[\\([^][]*\\)\\]\\]\\|\\[\\([^][]*\\)\\](\\(\\[\\[[^][]*\\]\\]\\))"))
    (save-match-data
      (while (string-match re text start)
        (cond
         ((match-beginning 1)
          (let ((target (match-string 1 text)))
            (unless (string-empty-p target)
              (push (list 'fuzzy target nil) links))))
         ((match-beginning 3)
          (let ((descr (match-string 2 text))
                (dest (match-string 3 text)))
            (save-match-data
              (when (string-match "\\`\\[\\[\\([^][]*\\)\\]\\]\\'" dest)
                (let ((target (match-string 1 dest)))
                  (unless (or (string-empty-p target)
                              (string-empty-p descr))
                    (push (list 'fuzzy target descr) links))))))))
        (setq start (match-end 0))))
    (nreverse links)))

(defun logseq-org-sync-logseq-markdown--extract-links (text)
  "Return fuzzy page links in TEXT as (fuzzy TARGET DESCRIPTION) tuples.
Uses the `markdown-inline' tree-sitter grammar when available, and a
regexp fallback otherwise."
  (when (and text (not (string-empty-p text)))
    (require 'markdown-ts-mode nil t)
    (if (treesit-language-available-p 'markdown-inline)
        (with-temp-buffer
          (insert text)
          (let* ((parser (treesit-parser-create 'markdown-inline))
                 (root (treesit-parser-root-node parser))
                 (links nil))
            (nreverse (logseq-org-sync-logseq-markdown--collect-links root links))))
      (logseq-org-sync-logseq-markdown--extract-links-regexp text))))

(defun logseq-org-sync-logseq-markdown--collect-block-links (blocks links)
  "Append page links found in BLOCKS to LINKS and return them."
  (dolist (block blocks)
    (setq links (append links
                        (logseq-org-sync-logseq-markdown--extract-links
                         (plist-get block :text))))
    (when (plist-get block :children)
      (setq links (logseq-org-sync-logseq-markdown--collect-block-links
                   (plist-get block :children) links))))
  links)

;;;###autoload
(defun logseq-org-sync-logseq-markdown-parse-buffer (&optional title)
  "Parse the current buffer as a Logseq Markdown file into a node plist.
TITLE is the fallback title, defaulting to the buffer file name base.  A
`title::' page property overrides it."
  (let* ((lines (split-string (buffer-string) "\n" t))
         (split (logseq-org-sync-logseq-markdown--split-page-properties lines))
         (prop-lines (car split))
         (body-lines (cdr split))
         (node (list :title (or title
                                (file-name-base (or buffer-file-name "")))))
         (id nil) (aliases nil) (tags nil) (title-value nil) (props nil))
    (dolist (line prop-lines)
      (let* ((prop (logseq-org-sync-logseq-markdown--parse-property line))
             (key (downcase (car prop)))
             (value (cdr prop)))
        (cond
         ((string= key "id") (setq id value))
         ((member key '("alias" "aliases"))
          (setq aliases (split-string value "\\s-*,\\s-*" t)))
         ((string= key "tags")
          (setq tags (append tags (split-string value "\\s-*,\\s-*" t))))
         ((string= key "filetags")
          (setq tags (append tags (split-string value ":" t "\\s-*"))))
         ((string= key "title") (setq title-value value))
         (t (push (cons (car prop) value) props)))))
    (when title-value (setq node (plist-put node :title title-value)))
    (when id (setq node (plist-put node :id id)))
    (when aliases (setq node (plist-put node :aliases aliases)))
    (when tags (setq node (plist-put node :tags (delete-dups tags))))
    (when props (setq node (plist-put node :properties (nreverse props))))
    (let* ((unit (logseq-org-sync-logseq-markdown--indent-unit body-lines))
           (flat (logseq-org-sync-logseq-markdown--collect-blocks body-lines unit))
           (tree (car (logseq-org-sync-logseq-markdown--assemble flat 1))))
      (when tree (setq node (plist-put node :content tree))))
    (let ((links (logseq-org-sync-logseq-markdown--collect-block-links
                  (plist-get node :content) nil)))
      (when links (setq node (plist-put node :links links))))
    node))

;;;###autoload
(defun logseq-org-sync-logseq-markdown-parse-file (file)
  "Parse Logseq Markdown FILE into a node plist.
The fallback node `:title' is derived from FILE's name base."
  (with-temp-buffer
    (insert-file-contents file)
    (logseq-org-sync-logseq-markdown-parse-buffer (file-name-base file))))

(defun logseq-org-sync-logseq-markdown--heading-level (props)
  "Return the `heading' level stored in PROPS, or nil."
  (let ((prop (cl-find-if (lambda (p) (string= (downcase (car p)) "heading"))
                          props)))
    (when prop
      (let ((n (string-to-number (cdr prop))))
        (and (> n 0) n)))))

(defun logseq-org-sync-logseq-markdown--block-line (level todo text heading)
  "Format a Markdown block first line from LEVEL, TODO, TEXT and HEADING."
  (let* ((indent (make-string (1- level) ?\t))
         (parts nil))
    (when todo (push todo parts))
    (when heading (push (make-string heading ?#) parts))
    (when (and text (not (string-empty-p text))) (push text parts))
    (setq parts (nreverse parts))
    (if parts
        (concat indent "- " (mapconcat #'identity parts " "))
      (concat indent "-"))))

(defun logseq-org-sync-logseq-markdown--continuation-indent (level)
  "Return the indentation for a block's continuation lines at LEVEL."
  (concat (make-string (1- level) ?\t) "  "))

(defun logseq-org-sync-logseq-markdown--format-block (block)
  "Return BLOCK (a block plist) formatted as a list of Markdown lines."
  (let* ((level (or (plist-get block :level) 1))
         (todo (plist-get block :todo))
         (text (plist-get block :text))
         (props (plist-get block :properties))
         (heading (logseq-org-sync-logseq-markdown--heading-level props))
         (props (cl-remove-if (lambda (p) (string= (downcase (car p)) "heading"))
                              props))
         (scheduled (plist-get block :scheduled))
         (deadline (plist-get block :deadline))
         (children (plist-get block :children))
         (body (plist-get block :body))
         (cindent (logseq-org-sync-logseq-markdown--continuation-indent level))
         (lines (list (logseq-org-sync-logseq-markdown--block-line
                       level todo text heading))))
    (when scheduled
      (setq lines (append lines (list (concat cindent "SCHEDULED: " scheduled)))))
    (when deadline
      (setq lines (append lines (list (concat cindent "DEADLINE: " deadline)))))
    (dolist (prop props)
      (let ((key (if (member (car prop) '("id" "ID")) "id" (car prop))))
        (setq lines (append lines (list (concat cindent key ":: " (cdr prop)))))))
    (when body
      (setq lines (append lines
                          (mapcar (lambda (line) (concat cindent line))
                                  (split-string body "\n")))))
    (dolist (child children)
      (setq lines (append lines (logseq-org-sync-logseq-markdown--format-block child))))
    lines))

(defun logseq-org-sync-logseq-markdown--format-properties (node)
  "Return NODE's page properties as Markdown `key:: value' lines."
  (let ((lines nil))
    (let ((id (plist-get node :id)))
      (when id (push (concat "id:: " id) lines)))
    (let ((aliases (plist-get node :aliases)))
      (when aliases
        (push (concat "alias:: " (mapconcat #'identity aliases ", ")) lines)))
    (let ((tags (plist-get node :tags)))
      (when tags
        (push (concat "tags:: " (mapconcat #'identity tags ", ")) lines)))
    (let ((props (plist-get node :properties)))
      (dolist (prop props)
        (push (concat (car prop) ":: " (cdr prop)) lines)))
    (nreverse lines)))

;;;###autoload
(defun logseq-org-sync-logseq-markdown-format (node)
  "Format NODE (an IR node plist) into a canonical Logseq Markdown string."
  (let ((lines (logseq-org-sync-logseq-markdown--format-properties node))
        (content nil))
    (dolist (block (plist-get node :content))
      (setq content (append content
                            (logseq-org-sync-logseq-markdown--format-block block))))
    (when (and lines content)
      (setq lines (append lines (list ""))))
    (setq lines (append lines content))
    (if lines
        (concat (mapconcat #'identity lines "\n") "\n")
      "")))

;;;###autoload
(defun logseq-org-sync-logseq-markdown-write (node file)
  "Write NODE to FILE in canonical Logseq Markdown form."
  (let ((text (logseq-org-sync-logseq-markdown-format node)))
    (with-temp-buffer
      (insert text)
      (write-region (point-min) (point-max) file))))

(provide 'logseq-org-sync-logseq)
;;; logseq-org-sync-logseq.el ends here
