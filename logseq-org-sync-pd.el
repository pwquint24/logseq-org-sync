;;; logseq-org-sync-pd.el --- Logseq Markdown <-> Org-roam import/export via pandoc -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Andrew Patrick

;; Author: Andrew Patrick <andrewpatrick@users.noreply.github.com>
;; URL: https://github.com/andrewpatrick/logseq-org-sync
;; Keywords: outlines, hypermedia, files
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.1.0

;;; Commentary:

;; This library implements the pandoc-based import/export backend for the
;; `logseq-org-sync' package.  It converts Logseq Markdown graphs to and
;; from Org-roam Org documents; it is not the two-way sync engine.
;;
;; Import (Logseq Markdown -> Org-roam): pandoc converts Logseq markdown
;; to Org with the `logseq-to-org.lua' filter; a post-processing step then
;; resolves fuzzy page links (`[[Page Title]]') into org-roam id links
;; (`[[id:UUID]]') using the org-roam database.
;;
;; Export (Org-roam -> Logseq Markdown): pandoc converts Org back to
;; markdown with the `org-to-logseq.lua' filter.

;;; Code:

(require 'cl-lib)
(require 'org-element)

;; org-roam is loaded lazily (it is a heavier dependency and the larger
;; package may control load order).  These declarations keep the byte
;; compiler quiet in the meantime.
(declare-function org-roam-node-from-title-or-alias "org-roam-node"
                  (s &optional nocase))
(declare-function org-roam-node-from-id "org-roam-node" (id))
(declare-function org-roam-node-id "org-roam-node" (x))
(declare-function org-roam-node-title "org-roam-node" (x))
(declare-function org-roam-node-level "org-roam-node" (x))
(declare-function org-roam-db-sync "org-roam-db" (&optional force))

(defgroup logseq-org-sync-pd nil
  "Import/export Logseq Markdown graphs to/from Org-roam using pandoc."
  :group 'org)

(defun logseq-org-sync-pd--dir ()
  "Return the directory containing this library."
  (file-name-directory
   (or load-file-name
       buffer-file-name
       (locate-library "logseq-org-sync-pd")
       default-directory)))

(defcustom logseq-org-sync-pd-pandoc "pandoc"
  "Pandoc executable."
  :type 'string
  :group 'logseq-org-sync-pd)

(defcustom logseq-org-sync-pd-forward-filter
  (expand-file-name "filters/logseq-to-org.lua" (logseq-org-sync-pd--dir))
  "Lua filter used for the Logseq markdown -> Org translation."
  :type 'file
  :group 'logseq-org-sync-pd)

(defcustom logseq-org-sync-pd-reverse-filter
  (expand-file-name "filters/org-to-logseq.lua" (logseq-org-sync-pd--dir))
  "Lua filter used for the Org -> Logseq markdown translation."
  :type 'file
  :group 'logseq-org-sync-pd)

(defcustom logseq-org-sync-pd-ambiguous-warning-format
  "# WARNING: ambiguous page link %s left unresolved"
  "Format string for ambiguous-link warnings; `%s' is the title.
The formatted string is inserted as an Org comment line above the link."
  :type 'string
  :group 'logseq-org-sync-pd)

;;; Pandoc invocation

(defun logseq-org-sync-pd--forward-flags ()
  "Pandoc flags for Logseq markdown -> Org."
  (list "-f" "markdown-simple_tables-multiline_tables+mark-superscript-implicit_header_references"
        "-t" "org"
        "--lua-filter" logseq-org-sync-pd-forward-filter))

(defun logseq-org-sync-pd--reverse-flags ()
  "Pandoc flags for Org -> Logseq markdown."
  (list "-f" "org"
        "-t" "markdown"
        "--lua-filter" logseq-org-sync-pd-reverse-filter))

(defun logseq-org-sync-pd--run-pandoc (input-file output-file reverse)
  "Run pandoc on INPUT-FILE, writing OUTPUT-FILE.
If REVERSE is non-nil use org -> markdown, otherwise markdown -> org."
  (let* ((args (append (if reverse
                           (logseq-org-sync-pd--reverse-flags)
                         (logseq-org-sync-pd--forward-flags))
                       (list (expand-file-name input-file)
                             "-o" (expand-file-name output-file))))
         (errbuf (generate-new-buffer " *logseq-org-sync-pd-pandoc*")))
    (unwind-protect
        (let ((exit (apply #'call-process logseq-org-sync-pd-pandoc nil
                           (list errbuf t) nil args)))
          (unless (zerop exit)
            (error "Pandoc failed (%d): %s" exit
                   (with-current-buffer errbuf (buffer-string)))))
      (kill-buffer errbuf))
    output-file))

;;; Path handling

(defun logseq-org-sync-pd--graph-relative (file)
  "Return FILE's path relative to its `pages/' or `journals/' ancestor.
This preserves the Logseq graph's directory layout.  If neither
component is present, fall back to the file's basename."
  (let* ((abs (expand-file-name file))
         (parts (split-string abs "/" t))
         (idx (cl-position-if (lambda (p) (member p '("pages" "journals")))
                              parts :from-end t)))
    (if idx
        (mapconcat #'identity (nthcdr idx parts) "/")
      (file-name-nondirectory abs))))

(defun logseq-org-sync-pd--graph-files (dir regexp)
  "Return files under DIR's `pages/' and `journals/' matching REGEXP.
The result is a sorted list of absolute file names.  This mirrors the
Logseq/org-roam directory layout (AGENTS.md §2)."
  (let ((files nil))
    (dolist (sub '("pages" "journals"))
      (let ((subdir (expand-file-name sub (expand-file-name dir))))
        (when (file-directory-p subdir)
          (dolist (file (directory-files-recursively subdir regexp))
            (push file files)))))
    (sort (nreverse files) #'string<)))

;;; Org-roam resolution

(defun logseq-org-sync-pd--require-org-roam ()
  "Load org-roam, signaling an error if unavailable."
  (or (require 'org-roam nil t)
      (user-error "Org-roam is required but could not be loaded")))

(defun logseq-org-sync-pd--resolve-title (title)
  "Resolve TITLE to an org-roam node id.
Return (ok . ID), the symbol `ambiguous', or the symbol `dangling'."
  (logseq-org-sync-pd--require-org-roam)
  (condition-case _
      (let ((node (org-roam-node-from-title-or-alias title)))
        (if node
            (cons 'ok (org-roam-node-id node))
          'dangling))
    ;; org-roam signals a user-error when more than one node matches.
    (user-error 'ambiguous)))

(defun logseq-org-sync-pd--fuzzy-page-link-p (link)
  "Return non-nil if LINK is a fuzzy page link worth resolving."
  (let ((path (org-element-property :path link)))
    (and path
         (not (string-empty-p path))
         (not (string-prefix-p "*" path))))) ; [[*heading]] search link

(defun logseq-org-sync-pd--link-text (link prefix)
  "Return `[[PREFIX][desc]]' (or `[[PREFIX]]') text that replaces LINK.
The description, if any, is copied verbatim from LINK."
  (let ((cb (org-element-property :contents-begin link))
        (ce (org-element-property :contents-end link)))
    (if (and cb ce)
        (format "[[%s][%s]]" prefix (buffer-substring-no-properties cb ce))
      (format "[[%s]]" prefix))))

(defun logseq-org-sync-pd--warning-present-above-p (pos text)
  "Return non-nil if TEXT already begins the line above POS."
  (save-excursion
    (goto-char pos)
    (forward-line -1)
    (looking-at (regexp-quote text))))

;;;###autoload
(defun logseq-org-sync-pd-resolve-page-links (&optional beg end)
  "Resolve fuzzy page links between BEG and END to `id:' links.

A fuzzy link like [[Page Title]] or [[Page Title][Label]] is replaced
with [[id:UUID]] or [[id:UUID][Label]], resolving the title against the
org-roam database.  When the title is ambiguous (multiple nodes match),
the link is left untouched and a warning comment is inserted on the line
above.  When no node matches (a dangling link), the link is left
untouched.

Return (RESOLVED . WARNED)."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let ((tree (org-element-parse-buffer))
        (edits nil)
        (resolved 0)
        (warned 0))
    (org-element-map tree 'link
      (lambda (link)
        (when (and (string= (org-element-property :type link) "fuzzy")
                   (logseq-org-sync-pd--fuzzy-page-link-p link)
                   (or (null beg) (<= beg (org-element-property :begin link)))
                   (or (null end) (<= (org-element-property :end link) end)))
          (let* ((title (org-element-property :path link))
                 (res (logseq-org-sync-pd--resolve-title title)))
            (pcase res
              (`(ok . ,id)
               (push (cons (org-element-property :begin link)
                           (list :replace (org-element-property :end link)
                                 (logseq-org-sync-pd--link-text link (concat "id:" id))))
                     edits)
               (cl-incf resolved))
              ('ambiguous
               (let* ((pos (save-excursion
                             (goto-char (org-element-property :begin link))
                             (line-beginning-position)))
                      (text (format logseq-org-sync-pd-ambiguous-warning-format
                                    title)))
                 (unless (logseq-org-sync-pd--warning-present-above-p pos text)
                   (push (cons pos (list :warn text)) edits)
                   (cl-incf warned))))
              (_ nil))))))
    ;; Deduplicate (e.g. two identical ambiguous links on one line), then
    ;; apply bottom-to-top so original positions stay valid.
    (setq edits (cl-remove-duplicates edits :test #'equal))
    (dolist (e (sort edits (lambda (a b) (> (car a) (car b)))))
      (pcase (cdr e)
        (`(:replace ,end ,text)
         (goto-char (car e))
         (delete-region (car e) end)
         (insert text))
        (`(:warn ,text)
         (goto-char (car e))
         (insert text "\n"))))
    (when (called-interactively-p 'any)
      (message "Resolved %d page link(s); %d ambiguous left unresolved."
               resolved warned))
    (cons resolved warned)))

;;;###autoload
(defun logseq-org-sync-pd-resolve-page-links-in-file (file)
  "Resolve fuzzy page links in FILE (an Org file) and save it.
Return (RESOLVED . WARNED)."
  (let ((buf (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buf
          (let ((res (logseq-org-sync-pd-resolve-page-links)))
            (when (buffer-modified-p buf)
              (save-buffer))
            res))
      (kill-buffer buf))))

;;;###autoload
(defun logseq-org-sync-pd-restore-page-links (&optional beg end)
  "Restore file-level `id:' links between BEG and END to fuzzy links.

An `id:' link whose target is a file-level org-roam node (heading level
0) originally came from a Logseq page link, so it is rewritten to
[[Title]] or [[Title][desc]].  `id:' links that target heading nodes are
left untouched so the pandoc reverse filter can map them back to block
references ((uuid)).

Return (RESTORED . MISSING), where MISSING counts ids that could not be
found in the org-roam database (left untouched)."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (logseq-org-sync-pd--require-org-roam)
  (let ((tree (org-element-parse-buffer))
        (edits nil)
        (restored 0)
        (missing 0))
    (org-element-map tree 'link
      (lambda (link)
        (when (and (string= (org-element-property :type link) "id")
                   (or (null beg) (<= beg (org-element-property :begin link)))
                   (or (null end) (<= (org-element-property :end link) end)))
          (let ((node (org-roam-node-from-id (org-element-property :path link))))
            (cond
             ((null node)
              (cl-incf missing))
             ((= 0 (org-roam-node-level node))
              (push (cons (org-element-property :begin link)
                          (list :replace (org-element-property :end link)
                                (logseq-org-sync-pd--link-text
                                 link (org-roam-node-title node))))
                    edits)
              (cl-incf restored))
             ;; Heading node: leave as a block reference.
             (t nil))))))
    (dolist (e (sort edits (lambda (a b) (> (car a) (car b)))))
      (pcase (cdr e)
        (`(:replace ,end ,text)
         (goto-char (car e))
         (delete-region (car e) end)
         (insert text))))
    (when (called-interactively-p 'any)
      (message "Restored %d page link(s); %d unresolved id(s)." restored missing))
    (cons restored missing)))

;;;###autoload
(defun logseq-org-sync-pd-restore-page-links-in-file (file)
  "Restore file-level id links in FILE (an Org file) and save it.
Return (RESTORED . MISSING)."
  (let ((buf (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buf
          (let ((res (logseq-org-sync-pd-restore-page-links)))
            (when (buffer-modified-p buf)
              (save-buffer))
            res))
      (kill-buffer buf))))

;;; Import / export

(defun logseq-org-sync-pd--db-sync (&optional force)
  "Synchronize the org-roam database (forcing a rebuild if FORCE)."
  (logseq-org-sync-pd--require-org-roam)
  (org-roam-db-sync force))

;;;###autoload
(defun logseq-org-sync-pd-import-files (files target-dir)
  "Import Logseq markdown FILES into TARGET-DIR as Org-roam files.

Each file's layout relative to its `pages/' or `journals/' ancestor is
preserved under TARGET-DIR.  After conversion the org-roam database is
synchronized and fuzzy page links are resolved to `id:' links.

Return the list of created .org file paths."
  (let ((out-files nil))
    (dolist (file files)
      (let* ((rel (logseq-org-sync-pd--graph-relative file))
             (rel-org (concat (file-name-sans-extension rel) ".org"))
             (out (expand-file-name rel-org (expand-file-name target-dir))))
        (make-directory (file-name-directory out) t)
        (logseq-org-sync-pd--run-pandoc file out nil)
        (push out out-files)))
    (logseq-org-sync-pd--db-sync)
    (dolist (out out-files)
      (logseq-org-sync-pd-resolve-page-links-in-file out))
    (nreverse out-files)))

;;;###autoload
(defun logseq-org-sync-pd-import-directory (source-dir target-dir)
  "Import the Logseq markdown graph at SOURCE-DIR into TARGET-DIR.

SOURCE-DIR is a Logseq graph directory containing `pages/' and
`journals/'.  Each `.md' note is converted to an Org-roam `.org' file
under TARGET-DIR, preserving the `pages/'/`journals/' layout.  The
org-roam database is synchronized and fuzzy page links are resolved to
`id:' links.

Return the list of created .org file paths."
  (interactive
   (list (read-directory-name "Logseq markdown graph: ")
         (read-directory-name "Org-roam target directory: ")))
  (logseq-org-sync-pd-import-files
   (logseq-org-sync-pd--graph-files source-dir "\\.\\(md\\|markdown\\)\\'")
   target-dir))

(defun logseq-org-sync-pd--restore-copy (file)
  "Return a temp .org copy of FILE with page links restored to fuzzy.
The caller is responsible for deleting the returned temp file."
  (let ((temp (make-temp-file "logseq-org-sync-pd-" nil ".org")))
    (copy-file file temp t)
    (logseq-org-sync-pd-restore-page-links-in-file temp)
    temp))

(defun logseq-org-sync-pd--export-file (file base target-dir)
  "Convert FILE (an Org-roam note) to Logseq markdown in TARGET-DIR.
BASE is the directory FILE's output layout is relative to.  Returns the
created .md file path."
  (let* ((rel (file-relative-name (expand-file-name file)
                                  (expand-file-name base)))
         (rel-md (concat (file-name-sans-extension rel) ".md"))
         (out (expand-file-name rel-md (expand-file-name target-dir)))
         (temp (logseq-org-sync-pd--restore-copy file)))
    (make-directory (file-name-directory out) t)
    (unwind-protect
        (logseq-org-sync-pd--run-pandoc temp out t)
      (ignore-errors (delete-file temp)))
    out))

;;;###autoload
(defun logseq-org-sync-pd-export-files (files target-dir)
  "Export Org-roam FILES to Logseq markdown in TARGET-DIR.

Each file's layout relative to `org-roam-directory' is preserved under
TARGET-DIR (falling back to the file's basename when
`org-roam-directory' is unset).  File-level id links are restored to
page links before conversion; heading id links are kept as block
references.

The org-roam database must be current (see `org-roam-db-sync').

Return the list of created .md file paths."
  (let ((out-files nil)
        (root (and (bound-and-true-p org-roam-directory)
                   (expand-file-name org-roam-directory))))
    (logseq-org-sync-pd--require-org-roam)
    (dolist (file files)
      (let ((base (or root (file-name-directory (expand-file-name file)))))
        (push (logseq-org-sync-pd--export-file file base target-dir)
              out-files)))
    (nreverse out-files)))

;;;###autoload
(defun logseq-org-sync-pd-export-directory (source-dir target-dir)
  "Export the Org-roam subdirectory SOURCE-DIR to TARGET-DIR.

SOURCE-DIR is an org-roam mirror directory containing `pages/' and
`journals/'.  Each `.org' note is converted back to a Logseq `.md' file
under TARGET-DIR, preserving the `pages/'/`journals/' layout.

File-level `id:' links are restored to page links before conversion;
heading `id:' links are kept as block references.

The org-roam database must be current (see `org-roam-db-sync').

Return the list of created .md file paths."
  (interactive
   (list (read-directory-name "Org-roam source directory: ")
         (read-directory-name "Logseq markdown target directory: ")))
  (let ((out-files nil))
    (dolist (file (logseq-org-sync-pd--graph-files source-dir "\\.org\\'"))
      (push (logseq-org-sync-pd--export-file file source-dir target-dir)
            out-files))
    (nreverse out-files)))

(provide 'logseq-org-sync-pd)
;;; logseq-org-sync-pd.el ends here
