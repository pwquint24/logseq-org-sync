;;; logseq-org-roam-updater.el --- Updaters for logseq-org-roam -*- lexical-binding: t; -*-

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

;; In-place file updaters extracted from the original monolithic
;; `logseq-org-roam.el'.  These patch the first section (identity/title/aliases)
;; and rewrite links, guarded by a SHA-256 hash re-verification before every
;; edit.

;;; Code:
(require 'logseq-org-roam-core)

(defun logseq-org-roam--buffer-title ()
  "Return a title based on current buffer's file name.
If the file is a journal entry, format the title accroding to
`logseq-org-roam-journals-title-format'."
  (let* ((base-name (file-name-base (buffer-file-name))))
    (if (logseq-org-roam-journals-p (buffer-file-name))
        (let ((time (condition-case ()
                        (funcall logseq-org-roam-maybe-date-func
                                 logseq-org-roam-journals-file-name-format
                                 base-name)
                      (error 0))))
          (if (time-equal-p 0 time) base-name
            (format-time-string logseq-org-roam-journals-title-format time)))
      base-name)))

(defun logseq-org-roam--update-first-section (plist)
  "Update current buffer first section based on PLIST."
  (org-with-wide-buffer
   (let ((start-size (buffer-size))
         (first-section-p (plist-get plist :first-section-p))
         (beg (point-min)))
     (goto-char beg)
     (unless first-section-p
       (insert "\n") ;; Empty line is needed to create first section
       (backward-char))
     (unless (plist-get plist :id)
       (org-id-get-create))
     (unless (plist-get plist :title)
       (let ((title (logseq-org-roam--buffer-title)))
         (goto-char (+ (or (plist-get plist :title-point) beg)
                       (- (buffer-size) start-size)
                       (if first-section-p 0 -1)))
         (unless (bolp) (throw 'update-error 'mismatch-before-title))
         (insert (concat "#+title: " title "\n"))))
     (when-let ((diff (seq-difference (plist-get plist :aliases)
                                      (plist-get plist :roam-aliases))))
       (goto-char beg)
       (dolist (alias diff)
         (org-roam-property-add "ROAM_ALIASES" alias)))
     (unless first-section-p
       (goto-char (+ beg (- (buffer-size) start-size) -1))
       (unless (looking-at "\n") (throw 'update-error 'mismatch-first-section))
       (delete-char 1)))))

(defun logseq-org-roam--update-links (links inventory file-dict fuzzy-dict)
  "Convert LINKS in current buffer to a target in INVENTORY.
This function returns t or an error code if there was an issue
updating the buffer.

The argument FILE-DICT is a hash-table that maps a normalized
file path to a key in inventory (a file path).  When dealing only
with fuzzy links, this hashtable is not used.

The argument FUZZY-DICT is a hash-table that maps a normalized
fuzzy link to a key in inventory (a file path).  When dealing
only with file links, this hashtable is not used."
  ;; `secure-hash' has a small chance of collision
  (pcase-dolist (`(_ ,beg ,end _ _ ,raw) links)
    (unless (string= (buffer-substring-no-properties beg end) raw)
      (throw 'update-error 'mismatch-link)))
  (pcase-dolist (`(,type ,beg ,end ,path ,descr _)
                 ;; Avoid offset calculations with buffer updates
                 (sort links (lambda (a b) (> (nth 1 a) (nth 1 b)))))
    (when-let ((id (plist-get
                    (gethash
                     ;; file-dict and fuzzy-dict key can be `consp' (conflict)
                     (if (eq 'file type)
                         (gethash (logseq-org-roam--normalize-path
                                   (expand-file-name path)) file-dict)
                       (gethash (logseq-org-roam--normalize-text path) fuzzy-dict))
                     inventory) :id)))
      (save-excursion
        (save-restriction
          (narrow-to-region beg end)
          (goto-char beg)
          (delete-region beg end)
          ;; TODO: log link updates
          (if descr
              (insert (concat "[[id:" id "][" descr "]]"))
            (insert (concat "[[id:" id "][" path "]]"))))))))

(defun logseq-org-roam--update-all (files inventory &optional link-p file-dict fuzzy-dict)
  "Update all FILES according to INVENTORY.
By default only the first section is updated, but if LINK-P is
non-nil, links are updated instead taking into account
FILE-DICT and FUZZY-DICT.

First sections and links are never updated in the same pass,
since to update the links, all first sections must be inventoried
first."
  (let (updated-files log-p)
    (princ (concat "** Updating files:\n"))
    (dolist (file files)
      (when-let ((plist (gethash file inventory)))
        (unless (or (plist-get plist :modified-p)
                    (plist-get plist :external-p)
                    (plist-get plist :parse-error)
                    (plist-get plist :cache-p)
                    (plist-get plist :update-error)
                    (if link-p
                        (not (plist-get plist :links))
                      (and (plist-get plist :title)
                           (plist-get plist :id)
                           ;; TODO store diff and union instead?
                           (not (seq-difference (plist-get plist :aliases)
                                                (plist-get plist :roam-aliases))))))
          (logseq-org-roam--catch-fun
              'update-error '(mismatch-before-title
                              mismatch-first-section
                              mismatch-link
                              hash-mismatch)
              (lambda (err)
                (princ (format "- Error updating %s of %s\n"
                               (if link-p "links" "first section")
                               (logseq-org-roam--fl file)))
                (puthash file
                         (plist-put plist :update-error err)
                         inventory))
            (logseq-org-roam--with-edit-buffer file
              (unless (string= (plist-get plist :hash)
                               (secure-hash
                                'sha256 (current-buffer)))
                (throw 'update-error 'hash-mismatch))
              (if link-p
                  (logseq-org-roam--update-links (plist-get plist :links)
                                                 inventory file-dict fuzzy-dict)
                (logseq-org-roam--update-first-section plist))
              (when (buffer-modified-p)
                (save-buffer)  ;; NOTE: runs org-roam hook and formatters
                (push file updated-files)
                (princ (concat "- Updated " (if link-p "links" "first section")
                               " of " (logseq-org-roam--fl file) "\n"))
                (setq log-p t)))))))
    (unless log-p
      (princ "No updates found\n"))
    updated-files))

(provide 'logseq-org-roam-updater)
;;; logseq-org-roam-updater.el ends here
