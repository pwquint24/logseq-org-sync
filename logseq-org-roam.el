;;; logseq-org-roam.el --- Logseq Org-roam converter -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (C) 2024, Sylvain Bougerel

;; Author: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; Maintainer: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; URL: https://github.com/sbougerel/logseq-org-roam/
;; Keywords: tools outlines
;; Version: 1.0.0
;; Package-Requires: ((org-roam "2.2.2") (emacs "27.2") (org "9.3"))
;; URL: https://github.com/sbougerel/logseq-org-roam

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
;;
;; Logseq Org-roam converter.
;;
;; This file is the aggregator and command entry point of the package.  Phase 1
;; of the two-way sync project split the original monolithic
;; `logseq-org-roam.el' into focused modules; every public and internal symbol
;; is unchanged:
;;
;;     logseq-org-roam-core.el      ;; customization, macros, helpers
;;     logseq-org-roam-parser.el    ;; org-element -> inventory plist
;;     logseq-org-roam-inventory.el ;; per-file metadata inventory
;;     logseq-org-roam-dict.el      ;; fuzzy/file resolution dictionaries
;;     logseq-org-roam-updater.el   ;; first-section and link updaters
;;     logseq-org-roam-create.el    ;; dead-link authoring
;;
;; See the docstring of `logseq-org-roam' for usage, and the project README for
;; the original interoperability notes.

;;; Code:
(require 'logseq-org-roam-core)
(require 'logseq-org-roam-parser)
(require 'logseq-org-roam-inventory)
(require 'logseq-org-roam-dict)
(require 'logseq-org-roam-updater)
(require 'logseq-org-roam-create)

(defun logseq-org-roam--log-start (force create)
  "Log start of execution and state of FORCE and CREATE flags."
  (princ
   (concat
    (format "* Ran on %s\n" (format-time-string "%x at %X"))
    (format "Using Org-roam directory: %s\n" org-roam-directory)
    (format "Logseq pages directory is: %s\n" logseq-org-roam-pages-directory)
    (format "Logseq journal directory is: %s\n" logseq-org-roam-journals-directory)
    "With flags:\n"
    (format "- ~force~ was: %s\n" force)
    (format "- ~create~ was: %s\n" create)
    "With settings:\n"
    (format "- ~logseq-org-roam-link-types~: %S\n" logseq-org-roam-link-types)
    (format "- ~logseq-org-roam-journals-file-name-format~: %s\n" logseq-org-roam-journals-file-name-format)
    (format "- ~logseq-org-roam-journals-title-format~: %s\n" logseq-org-roam-journals-title-format))))

;; TODO: test
(defun logseq-org-roam--check-errors (files inventory)
  "Log parsing issues with FILES in INVENTORY.
Return non-nil if issues where found."
  (princ "** Verifing files:\n")
  (let (error-p)
    (dolist (file files)
      (let ((plist (gethash file inventory)))
        (if (not plist)
            (progn
              (setq error-p t)
              (princ (concat "- File " (logseq-org-roam--fl file)
                             "blank or not parsed\n")))
          (when (plist-get plist :modified-p)
            (setq error-p t)
            (princ (concat "- Save the buffer visiting " (logseq-org-roam--fl file) "\n")))
          (when-let ((err (plist-get plist :parse-error)))
            (setq error-p t)
            (princ (concat "- Error " (format "%s" err)
                           " parsing " (logseq-org-roam--fl file) ", skipped\n")))
          (when-let ((err (plist-get plist :update-error)))
            (setq error-p t)
            (princ (concat "- Error " (format "%s" err)
                           " updating " (logseq-org-roam--fl file)
                           ", left as-is\n")))
          (when (not (plist-get plist :id))
            (setq error-p t)
            (princ (concat "- No id found for " (logseq-org-roam--fl file) "\n")))
          (when (not (plist-get plist :title))
            (setq error-p t)
            (princ (concat "- No title found for " (logseq-org-roam--fl file) "\n"))))))
    (if (not error-p)
        (princ "No errors.\n")
      (princ "Errors found:\nPlease save any work in progress or fix syntax issues in the files mentionned above before re-running the function again. Errors can impact the accuracy of file creation or link conversion.\n")
      (throw 'stop 'error-encountered))))

(defun logseq-org-roam--sanity-check ()
  "Check that `org-roam' is installed and configured."
  (cond
   ((not (featurep 'org-roam))
    (user-error "Feature `org-roam' is not found"))
   ((not org-roam-directory)
    (user-error "Variable `org-roam-directory' is nil"))
   ((not (file-directory-p org-roam-directory))
    (user-error "Directory `org-roam-directory' does not exists"))
   ((not (file-exists-p (expand-file-name
                         logseq-org-roam-pages-directory
                         org-roam-directory)))
    (user-error "Logseq pages must be found directly under `org-roam-directory'"))
   ((not (file-exists-p (expand-file-name
                         logseq-org-roam-journals-directory
                         org-roam-directory)))
    (user-error "Logseq journals must be found directly under `org-roam-directory'"))
   (t)))

;;;###autoload
(defun logseq-org-roam (&optional mode)
  "Migrate files edited with Logseq to `org-roam'.
Parse files returned by `org-roam-list-files' that are not part
of the `org-roam' cache, and if it finds files that were created
by Logseq, it updates these files to set ID, title, aliases, or
convert links to other files by using ID-links.

Please note that while care was taken to ensure its reliability,
you should have a mean to revert the changes it makes on your
files (e.g. backup or version control) before running this
function.

While using this facility regularly makes `org-roam' and Logseq
mostly interoperable; ID-links in Logseq show up as \"Unlinked
Reference\" and thus break the connection in your Logseq graph.
If you primarily rely on Logseq, this could be a deal-breaker.

When called with \\[universal-argument] or MODE is not nil, it
parses any files returned by `org-roam-list-files' (even if they
are already indexed by `org-roam').  This is useful if you've had
a lot of edits with Logseq (or other), and some of the files that
are in `org-roam' may still contain links to other files that are
not converted to ID-links yet.

When `logseq-org-roam' encounters a link created with Logseq to a
page that does not exists yet, it can create that page for you,
leveraging your `org-roam-capture-templates', as you would if you
were using the normal `org-roam' workflow.  This mode of
operation is enabled when `logseg-to-roam-create' is t or when
calling this function with (double) \\[universal-argument]
\\[universal-argument].

To active both creation and forcing to parse all files returned
by `org-roam-list-files' call this function with (triple)
\\[universal-argument] \\[universal-argument]
\\[universal-argument].

When calling `logseq-org-roam' programmatically it accepts the
following arguments:

- nil: parse only files that are not yet indexed (by `org-roam')
  and does not create any new files (when it encounters a link
  created by Logseq without an existing target).

- \\='(4) or 4 or \\='force: parse all files (even those already
  indexed) and does not create any new files.  Equivalent to
  \\[universal-argument] \\[logseq-org-roam].

- \\='(16) or 16 or \\='create: parse only files that are not yet
  indexed and create new files using your capture templates (when
  it encounters a Logseq link without target).  Equivalent to
  \\[universal-argument] \\[universal-argument]
  \\[logseq-org-roam].

- \\='(64) or 64 or \\='force-create: parse all files and create new
  files using your capture templates.  Equivalent to
  \\[universal-argument] \\[universal-argument]
  \\[universal-argument] \\[logseq-org-roam].

To find out how `logseq-org-roam' detects Logseq links, read the
documentation string of `logseq-org-roam-link-types'.  To find
out how `logseq-org-roam' uses your own capture templates, read
the documentation string of `logseq-org-roam-capture'."
  (interactive "P")
  (when (logseq-org-roam--sanity-check)
    (let ((start (current-time))
          elapsed
          force_flag
          create_flag)
      (cond
       ((or (equal mode '(4))
            (eq mode 4)
            (eq mode 'force))
        (setq force_flag t))
       ((or (equal mode '(16))
            (eq mode 16)
            (eq mode 'create))
        (setq create_flag t))
       ((or (equal mode '(64))
            (eq mode 64)
            (eq mode 'force-create))
        (setq force_flag t)
        (setq create_flag t)))
      (logseq-org-roam--with-log-buffer
       (logseq-org-roam--log-start force_flag create_flag)
       ;; Main flow
       ;;
       ;; - inventory files fully
       ;; - update first-sections and re-parse where needed
       ;; - (optionally) author new files where needed and re-parse
       ;; - update links
       ;;
       ;; 2 factors make the implementation rather complex:
       ;;
       ;; - On save, hooks may reformat the buffer in unexpected ways, thus
       ;; it's safer to reparse every time the files are modified.
       ;;
       ;; - Creation adds complexity since we must parse the entire
       ;; content for all files to discover dead links first.
       (let* ((files (org-roam-list-files))
              (link-parts (cond ((eq logseq-org-roam-link-types 'files)
                                 '(file-links))
                                ((eq logseq-org-roam-link-types 'fuzzy)
                                 '(fuzzy-links))
                                (t '(file-links fuzzy-links))))
              (fuzzy-dict (make-hash-table :test #'equal))
              (file-dict (make-hash-table :test #'equal))
              inventory
              modified-files
              created-files
              not-created-files)
         (logseq-org-roam--catch-fun
             'stop '(error-encountered)
             (lambda (_)
               (display-warning 'logseq-org-roam
                                (concat "Stopped with errors, see "
                                        (format logseq-org-roam--log-buffer-name
                                                org-roam-directory)
                                        " buffer")
                                :error))
           (setq inventory (logseq-org-roam--inventory-init files))
           (if (= 0 (logseq-org-roam--inventory-all
                     files inventory force_flag (append '(first-section) link-parts)))
               ;; TODO: calcuate left-over files only
               (progn
                 (princ "No updates to perform\n")
                 ;; Check errors in inventory none-the-less
                 ;; TODO: write dedicated interactive function for this
                 (logseq-org-roam--check-errors files inventory))
             ;; Compute the subset of logseq files instead of using files
             (setq modified-files
                   (logseq-org-roam--update-all files inventory))
             (if modified-files
                 (logseq-org-roam--inventory-update modified-files inventory
                                                    (append '(first-section)
                                                            link-parts)))
             (if (memq 'fuzzy-links link-parts)
                 (logseq-org-roam--fill-fuzzy-dict fuzzy-dict files inventory))
             (if (memq 'file-links link-parts)
                 (logseq-org-roam--fill-file-dict file-dict files))
             ;; Do as much work as possible, but beyond this point, the errors
             ;; (modified files, parse or update errors) could affect accuracy
             ;; of the changes
             (logseq-org-roam--check-errors files inventory)
             (setq not-created-files files)
             (when create_flag
               (setq created-files
                     (logseq-org-roam--create-from files inventory
                                                   file-dict fuzzy-dict))
               (logseq-org-roam--inventory-update created-files inventory
                                                  ;; No links added to new files
                                                  '(first-section))
               (if (memq 'fuzzy-links link-parts)
                   (logseq-org-roam--fill-fuzzy-dict fuzzy-dict created-files inventory))
               (if (memq 'file-links link-parts)
                   (logseq-org-roam--fill-file-dict file-dict created-files))
               (logseq-org-roam--check-errors created-files inventory))
             (if (and (logseq-org-roam--update-all not-created-files
                                                   inventory 'links file-dict fuzzy-dict)
                      modified-files)
                 (run-hooks 'logseq-org-roam-updated-hook)))
           ;; TODO: Refactor presentation of results, use an object instead
           ;; TODO: timing should be `unwind-protect'
           (setq elapsed (float-time (time-subtract (current-time) start)))
           (princ (format "Completed in %.3f seconds\n" elapsed))))))))

(provide 'logseq-org-roam)
;;; logseq-org-roam.el ends here
