;;; logseq-org-roam-dict.el --- Dictionaries for logseq-org-roam -*- lexical-binding: t; -*-

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

;; Link-resolution dictionaries extracted from the original monolithic
;; `logseq-org-roam.el'.  These map normalized titles/aliases (fuzzy-dict) and
;; normalized paths (file-dict) to inventory keys, marking conflicts with a
;; `cons'.

;;; Code:
(require 'logseq-org-roam-core)

(defun logseq-org-roam--fill-fuzzy-dict (fuzzy-dict files inventory)
  "Fill titles and aliases of FILES into FUZZY-DICT.
Map each title and alias to a key in INVENTORY or to a `cons'
containing a key to INVENTORY when a conflict is found.

Ensure that titles and aliases found across all files are unique.
If any 2 titles or alias conflicts with each other, there is no
unique target for titled links to these files.

Returns the number of conflicts found"
  (princ "** Filling dictionary of titles and aliases:\n")
  (let ((conflict-count 0))
    (dolist (file files)
      (when-let ((plist (gethash file inventory)))
        (unless (or (plist-get plist :modified-p)
                    (plist-get plist :parse-error)
                    (plist-get plist :update-error))
          ;; NOTE: Similar title and aliases from the same file are not marked as conflict
          ;; TODO: cl-* could be faster
          (let ((merged (seq-uniq
                         (mapcar #'logseq-org-roam--normalize-text
                                 (delq nil (append
                                            (list (plist-get plist :title))
                                            (plist-get plist :aliases)
                                            (plist-get plist :roam-aliases))))
                         #'string=)))
            (dolist (target merged)
              (let ((val (gethash target fuzzy-dict 'not-found))
                    other-file)
                (if (eq 'not-found val)
                    (puthash target file fuzzy-dict)
                  (setq conflict-count (1+ conflict-count))
                  (if (consp val)
                      (setq other-file (car val))
                    (setq other-file val)
                    (puthash target (cons other-file nil) fuzzy-dict))
                  ;; Log the conflict
                  (let* ((this-title-p (string= target (logseq-org-roam--normalize-text
                                                        (plist-get plist :title))))
                         (other-plist (gethash other-file inventory))
                         (other-title-p (string= target (logseq-org-roam--normalize-text
                                                         (plist-get other-plist :title)))))
                    (princ (format "- The %s \"%s\" in %s conflicts with the %s in %s, links will not be converted.\n"
                                   (if this-title-p "title" "alias")
                                   target
                                   (logseq-org-roam--fl file)
                                   (if other-title-p "title" "alias")
                                   (logseq-org-roam--fl other-file)))))))))))
    (princ (format "%s entries in total\n" (hash-table-count fuzzy-dict)))
    (princ (format "%s conflicts\n" conflict-count))
    conflict-count))

(defun logseq-org-roam--fill-file-dict (file-dict files)
  "Fill FILE-DICT with the normalized path of each FILES.
Maps each normalized path to the original path or to a `cons' with
original path.  If the mapping is to a cons, it means a conflict
was found and the `car' contains the first path to this
entry."
  (princ "** Filling dictionary of similar paths:\n")
  (let ((conflict-count 0))
    (dolist (file files)
      (let ((normalized (logseq-org-roam--normalize-path file)))
        (if (eq 'not-found (gethash normalized file-dict 'not-found))
            (puthash normalized file file-dict)
          (setq conflict-count (1+ conflict-count))
          (let ((val (gethash normalized file-dict))
                original)
            (if (consp val)
                (setq original (car val))
              (puthash normalized (cons val nil) file-dict)
              (setq original val))
            (princ (format "- Path to %s and %s are too similar and will not be converted\n"
                           (logseq-org-roam--fl file)
                           (logseq-org-roam--fl original)))))))
    (princ (format "%s entries in total\n" (hash-table-count file-dict)))
    (princ (format "%s conflicts\n" conflict-count))
    conflict-count))

(provide 'logseq-org-roam-dict)
;;; logseq-org-roam-dict.el ends here
