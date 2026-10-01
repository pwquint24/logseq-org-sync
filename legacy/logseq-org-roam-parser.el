;;; logseq-org-roam-parser.el --- Parser for logseq-org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2024, Sylvain Bougerel

;; Author: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; Maintainer: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; URL: https://github.com/sbougerel/logseq-org-roam/
;; Keywords: tools outlines

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

;; Parser extracted from the original monolithic `logseq-org-roam.el'.  It
;; reads an `org-element' AST and produces the inventory plist metadata
;; (first-section identity/title/aliases and link tuples).

;;; Code:
(require 'logseq-org-roam-core)

(defun logseq-org-roam--parse-first-section-properties (section plist)
  "Return updated PLIST based on first SECTION properties."
  (org-element-map section 'property-drawer
    (lambda (property-drawer)
      ;; Set `:title-point' after the drawer, and reset if there's a title
      (setq plist (plist-put plist :title-point
                             (progn
                               (goto-char
                                (- (org-element-property :end
                                                         property-drawer)
                                   (org-element-property :post-blank
                                                         property-drawer)))
                               (beginning-of-line)
                               (point))))
      (org-element-map property-drawer 'node-property
        (lambda (node-property)
          (let ((key (org-element-property :key node-property)))
            (cond
             ((and (string= "ID" key)
                   (logseq-org-roam--value-string-p node-property))
              (setq plist (plist-put plist :id
                                     (org-element-property :value
                                                           node-property))))
             ((and (string= "ROAM_ALIASES" key)
                   (logseq-org-roam--value-string-p node-property))
              (setq plist (plist-put plist :roam-aliases
                                     (split-string-and-unquote
                                      (org-element-property
                                       :value
                                       node-property)))))))))))
  plist)

(defun logseq-org-roam--parse-first-section-keywords (section plist)
  "Return updated PLIST based on first SECTION keywords."
  (org-element-map section 'keyword
    (lambda (keyword)
      (let ((key (org-element-property :key keyword)))
        (cond
         ((string= "TITLE" key)
          (setq plist (plist-put plist :title-point
                                 (org-element-property :begin keyword)))
          (if (logseq-org-roam--value-string-p keyword)
              (setq plist (plist-put plist :title
                                     (org-element-property :value keyword)))))
         ((and (string= "ALIAS" key)
               (logseq-org-roam--value-string-p keyword))
          (setq plist (plist-put plist :aliases
                                 (split-string
                                  (org-element-property :value keyword)
                                  "\\s-*,\\s-*"))))))))
  plist)

(defun logseq-org-roam--parse-first-section (data plist)
  "Return updated PLIST based on first section of DATA."
  (declare (pure t) (side-effect-free t))
  (cond
   ((or (not (consp data))
        (not (eq 'org-data (car data))))
    (throw 'parse-error 'invalid-ast))
   ((or (not (cddr data))
        (not (consp (caddr data)))
        (not (eq 'section (caaddr data))))
    ;; no content or no first section
    plist)
   (t
    (setq plist (plist-put plist :first-section-p t))
    (let ((section (caddr data)))
      (setq plist (logseq-org-roam--parse-first-section-properties section plist))
      (setq plist (logseq-org-roam--parse-first-section-keywords section plist)))
    plist)))

(defun logseq-org-roam--parse-file-links (data plist)
  "Return updated PLIST based on file links in DATA."
  (let ((links (plist-get plist :links)))
    (org-element-map data 'link
      (lambda (link)
        (if (and (string= (org-element-property :type link) "file")
                 (org-element-property :contents-begin link)
                 (not (org-element-property :search-option link)))
            (let* ((path (org-element-property :path link))
                   (descr (buffer-substring-no-properties
                           (org-element-property :contents-begin link)
                           (org-element-property :contents-end link)))
                   (begin (org-element-property :begin link))
                   (end (- (org-element-property :end link)
                           (org-element-property :post-blank link)))
                   (raw (buffer-substring-no-properties begin end)))
              (push (list 'file begin end path descr raw) links)))))
    (if links (setq plist (plist-put plist :links links))))
  plist)

(defun logseq-org-roam--parse-fuzzy-links (data plist)
  "Return updated PLIST based on fuzzy links in DATA.
This function ensures that we do not convert fuzzy links that
already match internal links; they take precedence over external
ID links."
  (let ((links (plist-get plist :links))
        (text-targets (make-hash-table :test #'equal)))
    (org-element-map data (append '(link target headline)
                                  logseq-org-roam--named)
      (lambda (element)
        (let ((type (org-element-type element)))
          (if-let ((name (org-element-property :name element)))
              ;; Org-mode searches are case incensitive
              (puthash (downcase name) t text-targets))
          (cond
           ;; See `org-link-search' to understand what fuzzy link point to
           ((eq type 'headline)
            (puthash (downcase
                      ;; TODO: remove internal function dependency
                      ;; This function skips tasks, priority, a statistics cookies
                      (org-link--normalize-string
                       (org-element-property :raw-value element))) t text-targets))
           ((and (eq type 'link)
                 (string= (org-element-property :type element) "fuzzy"))
            (let ((path (org-element-property :path element))
                  (content (org-element-property :contents-begin element)))
              (unless (or
                       ;; "[[*Heading]]" links qualify as internal, ignore them
                       (string-match "\\`\\*" path)
                       ;; When the link has no content, ignore image types
                       (and (not content)
                            (logseq-org-roam--image-file-p path)))
                (let* ((descr (if content
                                  (buffer-substring-no-properties
                                   (org-element-property :contents-begin element)
                                   (org-element-property :contents-end element))))
                       (begin (org-element-property :begin element))
                       (end (- (org-element-property :end element)
                               (org-element-property :post-blank element)))
                       (raw (buffer-substring-no-properties begin end)))
                  (push (list 'fuzzy begin end path descr raw) links)))))
           ((eq type 'target)
            (puthash (downcase (org-element-property :value element)) t text-targets))))))
    ;; Filter out link that match targets, headlines or named elements
    (setq links (seq-filter (lambda (link) (not (gethash (nth 3 link) text-targets)))
                            links))
    (if links (setq plist (plist-put plist :links links))))
  plist)

(defun logseq-org-roam--parse-buffer (plist parts)
  "Return updated PLIST based on current buffer's content.
This function updates PLIST with based on selected PARTS, a list
of keywords which defaults to \\='(first-section file-links
fuzzy-links)."
  (org-with-wide-buffer
   (let* ((data (org-element-parse-buffer)))
     (if (memq 'first-section parts)
         (setq plist (logseq-org-roam--parse-first-section data plist)))
     ;; links are never updated for external files
     (unless (plist-get plist :external-p)
       ;; Reset a *stale* `:links' before re-collecting so a re-parse (e.g. the
       ;; inventory update after first-section edits) does not accumulate
       ;; duplicate links with stale byte offsets.  This is the fix originally
       ;; shipped in `bug-fix.el'.  Guarding on `plist-member' preserves the
       ;; original invariant that a file with no links has no `:links' key
       ;; (rather than a `:links nil' entry).
       (when (and (or (memq 'file-links parts) (memq 'fuzzy-links parts))
                  (plist-member plist :links))
         (setq plist (plist-put plist :links nil)))
       (if (memq 'file-links parts)
           (setq plist (logseq-org-roam--parse-file-links data plist)))
       (if (memq 'fuzzy-links parts)
           (setq plist (logseq-org-roam--parse-fuzzy-links data plist))))))
  plist)

(defun logseq-org-roam--parse-files (files inventory parts)
  "Populate INVENTORY by parsing content of FILES.
Restrict parsing to PARTS if provided.  Return the number of files
that were parsed."
  (let ((count 0))
    (dolist (file files)
      ;; It's OK if plist is nil!
      (let ((plist (gethash file inventory)))
        (unless (or (plist-get plist :modified-p)
                    (plist-get plist :cache-p)
                    (plist-get plist :parse-error)
                    (plist-get plist :update-error))
          (logseq-org-roam--catch-fun
              'parse-error '(invalid-ast)
              (lambda (err)
                (princ (concat "- Error parsing " (logseq-org-roam--fl file) "\n"))
                (puthash file
                         (plist-put plist :parse-error err)
                         inventory))
            (logseq-org-roam--with-temp-buffer file
              (let ((new_plist (plist-put plist :hash
                                          (secure-hash
                                           'sha256 (current-buffer)))))
                (setq new_plist
                      (logseq-org-roam--parse-buffer new_plist parts))
                (puthash file new_plist inventory)
                (princ (concat "- Parsed " (logseq-org-roam--fl file) "\n"))
                (setq count (1+ count))))))))
    count))

(provide 'logseq-org-roam-parser)
;;; logseq-org-roam-parser.el ends here
