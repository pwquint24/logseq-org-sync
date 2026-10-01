;;; logseq-org-roam-inventory.el --- Inventory for logseq-org-roam -*- lexical-binding: t; -*-

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

;; Inventory construction extracted from the original monolithic
;; `logseq-org-roam.el'.  The inventory is a hash table keyed by absolute file
;; path whose values are plists describing each file's metadata.

;;; Code:
(require 'logseq-org-roam-core)
(require 'logseq-org-roam-parser)

(defun logseq-org-roam--inventory-init (files)
  "Initialise inventory with FILES."
  (let ((inventory (make-hash-table :test #'equal)))
    (mapc (lambda (elem) (puthash elem nil inventory)) files)
    inventory))

(defun logseq-org-roam--inventory-from-cache (inventory)
  "Populate INVENTORY with `org-roam' cache for FILES.
Return the number of files whose metadata was retreived from the
cache."
  (let ((count 0)
        (data-cached (org-roam-db-query [:select [file id title]
                                         :from nodes
                                         :where (= 0 level)])))
    (pcase-dolist (`(,file ,id ,title) data-cached)
      ;; TODO: Consider throwing an error if cache is not updated
      (unless (eq 'not-found (gethash file inventory 'not-found))
        (setq count (1+ count))
        (let ((aliases (mapcar #'car
                               (org-roam-db-query [:select [alias] :from aliases
                                                   :where (= node-id $s1)]
                                                  id))))
          (puthash file
                   (append (list :cache-p t :id id)
                           (if (and title (not (string-empty-p title)))
                               (list :title title))
                           (if aliases
                               (list :roam-aliases aliases)))
                   inventory))))
    count))

(defun logseq-org-roam--inventory-mark-external (files inventory)
  "Mark FILES in INVENTORY that are not Logseq files."
  (let ((count 0))
    (mapc (lambda (file)
            (unless (logseq-org-roam-logseq-p file)
              (setq count (1+ count))
              (let* ((plist (gethash file inventory))
                     (new_plist (plist-put plist :external-p t)))
                (puthash file new_plist inventory))))
          files)
    count))

(defun logseq-org-roam--inventory-mark-modified (files inventory)
  "Update INVENTORY with modified buffer visiting any FILES.
Return the number of files from INVENTORY that are currently
being modified in a buffer."
  (let ((count 0))
    (dolist (file files)
      (when-let* ((existing_buf (find-buffer-visiting file))
                  (mod-p (buffer-modified-p existing_buf)))
        (setq count (1+ count))
        (let* ((plist (gethash file inventory))
               (new_plist (plist-put plist :modified-p t)))
          (puthash file new_plist inventory))))
    count))

(defun logseq-org-roam--inventory-all (files inventory force parts)
  "Build inventory of `org-roam' metadata for FILES.
Update INVENTORY (hashtable) with a plist describing relevant
metadata to convert Logseq files to `org-roam'.  The
keys (absolute paths) point to both existing and new `org-roam'
files (presumably created with Logseq).

The argument FORCE ensure that all files are parsed, instead of
relying on information from the `org-roam' cache (in which case,
files already indexed are ever modififed).

The argument PARTS ensures that the function only parses the
necessary parts of each files.

Returns the number of files parsed without error."
  (princ "** Initial inventory:\n")
  (let* (count_cached
         count_external
         count_modified
         count_parsed)
    (unless force
      (setq count_cached
            (logseq-org-roam--inventory-from-cache inventory)))
    (setq count_modified
          (logseq-org-roam--inventory-mark-modified files inventory))
    (setq count_external
          (logseq-org-roam--inventory-mark-external files inventory))
    (setq count_parsed
          (logseq-org-roam--parse-files files inventory parts))
    (princ
     (concat
      (format "%s files found in org-roam directory\n"
              (hash-table-count inventory))
      (unless force
        (format "%s files' metadata retrieved from cache\n"
                count_cached))
      (format "%s files being visited in a modified buffer will be skipped\n"
              count_modified)
      (format "%s files are external to Logseq and will not be modified\n"
              count_external)
      (format "%s files have been parsed without errors\n"
              count_parsed)))
    count_parsed))

(defun logseq-org-roam--inventory-update (files inventory parts)
  "Update INVENTORY by reparsing FILES."
  (princ "** Inventory update:\n")
  (let* (count_parsed)
    (setq count_parsed
          (logseq-org-roam--parse-files files inventory parts))
    (princ
     (concat
      (format "%s files have been parsed without errors\n"
              count_parsed)))))

(provide 'logseq-org-roam-inventory)
;;; logseq-org-roam-inventory.el ends here
