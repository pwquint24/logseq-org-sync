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
;; (`logseq .org → IR') and a writer (`IR → logseq .org').  It is independent
;; of the legacy one-way `logseq-org-roam' converter and lives in its own
;; `logseq-org-sync-*' namespace.
;;
;; This module handles Logseq **org** graphs only.  Logseq Markdown graphs are
;; no longer synced; they are imported/exported through the pandoc backend
;; (`logseq-org-sync-pd', see `PANDOC-TRANSLATE.md').
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
;;   into the block's `:body' field and round-trips byte-for-byte.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

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
(defun logseq-org-sync-logseq-scan (root &optional pages-directory journals-directory)
  "Return sorted absolute paths to Logseq .org files under ROOT.
Scan ROOT/PAGES-DIRECTORY and ROOT/JOURNALS-DIRECTORY recursively.
PAGES-DIRECTORY defaults to \"pages\" and JOURNALS-DIRECTORY to
\"journals\"."
  (let* ((pages (or pages-directory "pages"))
         (journals (or journals-directory "journals"))
         (files nil))
    (dolist (dir (list (expand-file-name pages root)
                       (expand-file-name journals root)))
      (when (file-directory-p dir)
        (setq files (nconc files (directory-files-recursively dir "\\.org\\'")))))
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

;;;###autoload
(defun logseq-org-sync-logseq-parse-file (file)
  "Parse Logseq .org FILE into a node plist.
The node `:title' is derived from FILE's name base."
  (logseq-org-sync-logseq-org-parse-file file))

(defun logseq-org-sync-logseq--format-headline (level todo text tags)
  "Format a headline line from LEVEL, TODO, TEXT and TAGS."
  (let* ((stars (make-string level ?*))
         (line stars))
    (when todo (setq line (concat line " " todo)))
    (when (and text (not (string-empty-p text)))
      (setq line (concat line " " text)))
    (when tags (setq line (concat line " :" (mapconcat #'identity tags ":") ":")))
    (if (string= line stars)
        (concat stars " ")
      line)))

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
  "Write NODE to FILE in canonical Logseq .org form."
  (logseq-org-sync-logseq-org-write node file))
(provide 'logseq-org-sync-logseq)
;;; logseq-org-sync-logseq.el ends here
