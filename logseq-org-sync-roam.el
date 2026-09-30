;;; logseq-org-sync-roam.el --- org-roam scanner, parser, writer -*- lexical-binding: t; -*-

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

;; The org-roam side of the two-way sync engine (Phase 3): a scanner, a parser
;; (`org-roam .org → IR') and a writer (`IR → org-roam .org').  It is the
;; mirror image of `logseq-org-sync-logseq' (Phase 2): the two sides share the
;; same IR (blocks ↔ headlines) and differ only in how they store identity,
;; aliases and links in the first section.
;;
;; ## Canonical org-roam .org format
;;
;; An org-roam note is a `.org' file whose identity and aliases live in a
;; top-level `:PROPERTIES:' drawer and whose title is a `#+title:' keyword:
;;
;;     :PROPERTIES:
;;     :ID: <uuid>             ;; identity
;;     :ROAM_ALIASES: "a" "b"  ;; aliases, quoted
;;     :<other>: value         ;; arbitrary node properties, optional
;;     :END:
;;     #+title: Page title
;;
;;     * TODO block text [[id:<uuid>][Page]]
;;     ** child text
;;
;; Blocks are org headlines, identical in structure to the Logseq side (see
;; `logseq-org-sync-logseq.el' §Blocks).
;;
;; ## Intermediate representation (IR)
;;
;; The node and block plists are exactly those documented in
;; `logseq-org-sync-logseq.el' §Intermediate representation, with two
;; org-roam-side differences:
;;
;; - `:title' is read from the `#+title:' keyword (falling back to the file
;;   name base) rather than derived from the file name base alone.
;; - `:links' contains `(id UUID DESCRIPTION)' tuples for
;;   `[[id:UUID][DESCRIPTION]]' links as well as `(fuzzy TARGET DESCRIPTION)'
;;   tuples for unresolved `[[TARGET]]' links.
;;
;; ## Known limitations
;;
;; - Priority cookies (`[#A]') are not supported (`org-element' drops the text
;;   preceding a priority cookie from a headline's `:raw-value').
;; - Links are preserved verbatim in `:text'; the `:links' field is a semantic
;;   extraction for the reconciler (Phase 5), not the source of link output.
;; - Block references `((uuid))' and embeds `{{embed ((uuid))}}' are preserved
;;   verbatim in `:text' (deferred; see AGENTS.md §6).
;; - Fuzzy-link collection skips org-internal links (`[[#custom-id]]',
;;   `[[*heading]]'); image/asset links are not specially handled (deferred).

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

;;;###autoload
(defun logseq-org-sync-roam-scan (root &optional pages-directory journals-directory)
  "Return sorted absolute paths to `.org' files under ROOT.
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

(defun logseq-org-sync-roam--first-section (data)
  "Return DATA's top-level `section' element, or nil.
DATA is an `org-data' parse tree."
  (cl-find-if (lambda (element) (eq (org-element-type element) 'section))
              (org-element-contents data)))

(defun logseq-org-sync-roam--first-section-drawer (section)
  "Return SECTION's `property-drawer' element, or nil."
  (cl-find-if (lambda (element)
                (eq (org-element-type element) 'property-drawer))
              (org-element-contents section)))

(defun logseq-org-sync-roam--first-section-title (section)
  "Return SECTION's `#+title:' keyword value, or nil."
  (let ((kw (cl-find-if (lambda (element)
                          (and (eq (org-element-type element) 'keyword)
                               (string= (org-element-property :key element)
                                        "TITLE")))
                        (org-element-contents section))))
    (when kw (org-element-property :value kw))))

(defun logseq-org-sync-roam--block-properties (headline)
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

(defun logseq-org-sync-roam--parse-block (headline)
  "Parse HEADLINE (an org-element) into a block plist."
  (let* ((level (org-element-property :level headline))
         (todo (org-element-property :todo-keyword headline))
         (text (org-element-property :raw-value headline))
         (tags (org-element-property :tags headline))
         (props (logseq-org-sync-roam--block-properties headline))
         (scheduled (let ((s (org-element-property :scheduled headline)))
                      (when s (org-element-property :raw-value s))))
         (deadline (let ((d (org-element-property :deadline headline)))
                     (when d (org-element-property :raw-value d))))
         (children (mapcar #'logseq-org-sync-roam--parse-block
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
    (when children (setq block (plist-put block :children children)))
    block))

(defun logseq-org-sync-roam--parse-links (data)
  "Return DATA's page links as (KIND TARGET DESCRIPTION) tuples.
`[[id:UUID][DESCRIPTION]]' links become `(id UUID DESCRIPTION)' and
fuzzy `[[TARGET]]' links become `(fuzzy TARGET DESCRIPTION)'.
DESCRIPTION is nil for a link without a description.  Internal links
\(`[[#custom-id]]', `[[*heading]]') are skipped."
  (let ((links nil))
    (org-element-map data 'link
      (lambda (link)
        (let ((type (org-element-property :type link))
              (path (org-element-property :path link))
              (contents-begin (org-element-property :contents-begin link)))
          (let ((descr (when contents-begin
                         (buffer-substring-no-properties
                          contents-begin
                          (org-element-property :contents-end link)))))
            (cond
             ((string= type "id")
              (push (list 'id path descr) links))
             ((string= type "fuzzy")
              (unless (string-match-p "\\`[#*]" path)
                (push (list 'fuzzy path descr) links))))))))
    (nreverse links)))

;;;###autoload
(defun logseq-org-sync-roam-parse-buffer (&optional title)
  "Parse the current buffer as an org-roam .org file into a node plist.
TITLE is the fallback title used when the buffer has no `#+title:'."
  (let* ((data (org-element-parse-buffer))
         (section (logseq-org-sync-roam--first-section data))
         (node (list :title (or title
                                (file-name-base (or buffer-file-name ""))))))
    (when section
      (let ((title-value (logseq-org-sync-roam--first-section-title section)))
        (when title-value
          (setq node (plist-put node :title title-value))))
      (let ((drawer (logseq-org-sync-roam--first-section-drawer section)))
        (when drawer
          (let ((id nil) (aliases nil) (props nil))
            (dolist (np (org-element-map drawer 'node-property #'identity))
              (let ((key (org-element-property :key np))
                    (value (org-element-property :value np)))
                (cond
                 ((string= key "ID") (setq id value))
                 ((string= key "ROAM_ALIASES")
                  (setq aliases (split-string-and-unquote value)))
                 (t (push (cons key value) props)))))
            (when id (setq node (plist-put node :id id)))
            (when aliases (setq node (plist-put node :aliases aliases)))
            (when props (setq node (plist-put node :properties (nreverse props))))))))
    (let ((blocks (mapcar #'logseq-org-sync-roam--parse-block
                          (cl-remove-if-not
                           (lambda (element)
                             (eq (org-element-type element) 'headline))
                           (org-element-contents data)))))
      (when blocks (setq node (plist-put node :content blocks))))
    (let ((links (logseq-org-sync-roam--parse-links data)))
      (when links (setq node (plist-put node :links links))))
    node))

;;;###autoload
(defun logseq-org-sync-roam-parse-file (file)
  "Parse org-roam .org FILE into a node plist.
The fallback node `:title' is derived from FILE's name base."
  (with-temp-buffer
    (let ((default-directory (or (file-name-directory file) default-directory)))
      (delay-mode-hooks
        (let ((org-inhibit-startup t))
          (org-mode)))
      (insert-file-contents file)
      (logseq-org-sync-roam-parse-buffer (file-name-base file)))))

(defun logseq-org-sync-roam--format-headline (level todo text tags)
  "Format a headline line from LEVEL, TODO, TEXT and TAGS."
  (let ((line (make-string level ?*)))
    (when todo (setq line (concat line " " todo)))
    (when (and text (not (string-empty-p text)))
      (setq line (concat line " " text)))
    (when tags (setq line (concat line " :" (mapconcat #'identity tags ":") ":")))
    line))

(defun logseq-org-sync-roam--format-block (block)
  "Return BLOCK (a block plist) formatted as a list of lines."
  (let* ((level (plist-get block :level))
         (todo (plist-get block :todo))
         (text (plist-get block :text))
         (tags (plist-get block :tags))
         (props (plist-get block :properties))
         (scheduled (plist-get block :scheduled))
         (deadline (plist-get block :deadline))
         (children (plist-get block :children))
         (lines (list (logseq-org-sync-roam--format-headline
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
    (dolist (child children)
      (setq lines (append lines (logseq-org-sync-roam--format-block child))))
    lines))

(defun logseq-org-sync-roam--format-aliases (aliases)
  "Format ALIASES (a list of strings) as a `:ROAM_ALIASES:' value."
  (mapconcat (lambda (alias) (format "\"%s\"" alias)) aliases " "))

;;;###autoload
(defun logseq-org-sync-roam-format (node)
  "Format NODE (an IR node plist) into a canonical org-roam .org string."
  (let ((lines nil))
    ;; Identity/aliases/properties drawer.
    (let ((id (plist-get node :id))
          (aliases (plist-get node :aliases))
          (props (plist-get node :properties)))
      (when (or id aliases props)
        (push ":PROPERTIES:" lines)
        (when id (push (concat ":ID: " id) lines))
        (when aliases
          (push (concat ":ROAM_ALIASES: "
                        (logseq-org-sync-roam--format-aliases aliases)) lines))
        (dolist (prop props)
          (push (concat ":" (car prop) ": " (cdr prop)) lines))
        (push ":END:" lines)))
    ;; Title keyword.
    (let ((title (plist-get node :title)))
      (when title (push (concat "#+title: " title) lines)))
    (setq lines (nreverse lines))
    ;; Blocks, separated from the first section by a blank line when both exist.
    (let ((content nil))
      (dolist (block (plist-get node :content))
        (setq content (append content (logseq-org-sync-roam--format-block block))))
      (when (and lines content)
        (setq lines (append lines (list ""))))
      (setq lines (append lines content)))
    (if lines
        (concat (mapconcat #'identity lines "\n") "\n")
      "")))

;;;###autoload
(defun logseq-org-sync-roam-write (node file)
  "Write NODE to FILE in canonical org-roam .org form."
  (let ((text (logseq-org-sync-roam-format node)))
    (with-temp-buffer
      (insert text)
      (write-region (point-min) (point-max) file))))

(provide 'logseq-org-sync-roam)
;;; logseq-org-sync-roam.el ends here
