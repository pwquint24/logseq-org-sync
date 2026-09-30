;;; logseq-org-roam-create.el --- Dead-link authoring for logseq-org-roam -*- lexical-binding: t; -*-

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

;; Dead-link authoring extracted from the original monolithic
;; `logseq-org-roam.el'.  These functions create missing `org-roam' files for
;; links whose target has no matching node.

;;; Code:
(require 'logseq-org-roam-core)

(defun logseq-org-roam-create-translate-default (fuzzy)
  "Transform FUZZY into an expanded file path.
If the fuzzy link represents a date, it will translate the link
to a path under the journal directory (see
`logseq-org-roam-journals-directory') otherwise translate the
link to a file path under the pages directory (See
`logseq-org-roam-pages-directory').

To tell apart dates from other strings, it uses
`logseq-org-roam-maybe-date-func'.  Special characters in the
link path are also replaced, see:
`logseq-org-roam-create-replace'."
  (let ((time (condition-case ()
                  (funcall logseq-org-roam-maybe-date-func
                           logseq-org-roam-journals-title-format
                           fuzzy)
                (error 0)))
        (normalized fuzzy))
    (if (and time (not (time-equal-p 0 time)))
        (setq normalized
              (format-time-string logseq-org-roam-journals-file-name-format
                                  time))
      (pcase-dolist (`(,regex . ,rep) logseq-org-roam-create-replace)
        (setq normalized (replace-regexp-in-string regex rep normalized))))
    (concat
     (expand-file-name
      normalized (expand-file-name
                  (if (and time (not (time-equal-p 0 time)))
                      logseq-org-roam-journals-directory
                    logseq-org-roam-pages-directory)
                  org-roam-directory))
     ".org")))

(defun logseq-org-roam--create-path-fuzzy (fuzzy fuzzy-dict)
  "Return a path from FUZZY link.
Uses FUZZY-DICT to ensure this is a brand new entry."
  (if (eq 'not-found (gethash (logseq-org-roam--normalize-text fuzzy)
                              fuzzy-dict 'not-found))
      (let ((translated
             (condition-case ()
                 (funcall logseq-org-roam-create-translate-func fuzzy)
               (error nil))))
        (if (file-name-absolute-p translated) translated))))

(defun logseq-org-roam--create-path-file (path file file-dict)
  "Return a path from the PATH in a FILE link.
The path needs to be expanded first before being checked against
FILE-DICT, as it is normally relative to the FILE it is located
in."
  (let ((expanded
         (expand-file-name path
                           (file-name-directory file))))
    (if (eq 'not-found (gethash (logseq-org-roam--normalize-path expanded)
                                file-dict 'not-found))
        expanded)))

(defun logseq-org-roam--create-from (files inventory file-dict fuzzy-dict)
  "Author new files for dead links of each FILES in INVENTORY.
FILE-DICT and FUZZY-DICT are used for dead links detection with
file links and fuzzy links respectively.  Any dead links is
considered a candidate for creation of new files.

Fuzzy links are first transformed to an expended path by calling
`logseq-org-roam-create-translate-func' with the link
path as an argument.

If file links are expanded against the parent directory of the
file containing them.

The path is given as the first argument to
`logseq-org-roam-create-accept-func' when it is
non-nil.

The resulting path must match `org-roam-file-p', it's
parent directory must exist, and the file must not exist.

Finally, for file links only, the description is used as the
title for the new file.

When the file is created, it is inserted an Org ID and a title,
then saved.  There is no support for templates at the moment.

Return the list of new files created."
  (let (created-files)
    (princ "** Creating new files:\n")
    (dolist (file files)
      (when-let ((plist (gethash file inventory)))
        (unless
            (or (plist-get plist :modified-p)
                (plist-get plist :external-p)
                (plist-get plist :parse-error)
                (plist-get plist :cache-p)
                (plist-get plist :update-error))
          (pcase-dolist (`(,type _ _ ,path ,descr _) (plist-get plist :links))
            (let (new-path new-title)
              (cond
               ((eq type 'file)
                (setq new-path (logseq-org-roam--create-path-file
                                path file file-dict))
                (setq new-title descr))
               (t
                (setq new-path (logseq-org-roam--create-path-fuzzy
                                path fuzzy-dict))
                (setq new-title path)))
              (cond ((not new-path) t) ;; link to existing entry
                    ((not (file-exists-p
                           (directory-file-name
                            (file-name-directory new-path))))
                     (princ (format "- For %s link %s in %s: parent directory of %s does not exists\n"
                                    (if (eq type 'file) "file" "fuzzy")
                                    path (logseq-org-roam--fl file) new-path)))
                    ((file-exists-p new-path)
                     (princ (format "- For %s link %s in %s: file %s already exists\n"
                                    (if (eq type 'file) "file" "fuzzy")
                                    path (logseq-org-roam--fl file) new-path)))
                    ((not (org-roam-file-p new-path))
                     (princ (format "- For %s link %s in %s: %s is not an org-roam file\n"
                                    (if (eq type 'file) "file" "fuzzy")
                                    path (logseq-org-roam--fl file) new-path)))
                    ((not (condition-case ()
                              (funcall logseq-org-roam-create-accept-func
                                       new-path)
                            (error nil)))
                     (princ (format "- For %s link %s in %s: creation of %s is rejected\n"
                                    (if (eq type 'file) "file" "fuzzy")
                                    path (logseq-org-roam--fl file) new-path)))
                    (t
                     (logseq-org-roam--with-edit-buffer new-path
                       ;; TODO: Use capture templates instead
                       (org-id-get-create)
                       (goto-char (point-max))
                       (insert (concat "#+title: " new-title "\n"))
                       (save-buffer))
                     (princ (concat "- Created " (logseq-org-roam--fl new-path)
                                    " from the " (if (eq type 'file) "file" "fuzzy")
                                    " link in " (logseq-org-roam--fl file) "\n"))
                     (push new-path created-files))))))))
    (unless created-files
      (princ "No new files created\n"))
    created-files))

(provide 'logseq-org-roam-create)
;;; logseq-org-roam-create.el ends here
