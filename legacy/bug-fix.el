;;; bug-fix.el --- Description -*- lexical-binding: t; -*-
;; ---------------
;; LOGSEQ-ORG-ROAM
;; ---------------

(after! logseq-org-roam
  (setq logseq-org-roam-link-types 'fuzzy) ;; or 'files, depending on the
  ;; setting ":org-mode/insert-file-link?"
  ;; See `logseq-org-roam-link-types`
  (setq logseq-org-roam-pages-directory "pages")
  (setq logseq-org-roam-journals-directory "journals")
  (setq logseq-org-roam-journals-file-name-format "%Y_%m_%d")
  (setq logseq-org-roam-journals-title-format "%Y_%m_%d")

  ;; Fix bug where :links offsets accumulate on inventory update when inserting properties/title
  (defun logseq-org-roam--parse-buffer (plist parts)
    "Return updated PLIST based on current buffer's content.
This function updates PLIST based on selected PARTS."
    (org-with-wide-buffer
     (let* ((data (org-element-parse-buffer)))
       (if (memq 'first-section parts)
           (setq plist (logseq-org-roam--parse-first-section data plist)))
       ;; links are never updated for external files
       (unless (plist-get plist :external-p)
         ;; Reset :links before re-collecting to avoid accumulating stale offsets:
         (when (or (memq 'file-links parts) (memq 'fuzzy-links parts))
           (setq plist (plist-put plist :links nil)))
         (if (memq 'file-links parts)
             (setq plist (logseq-org-roam--parse-file-links data plist)))
         (if (memq 'fuzzy-links parts)
             (setq plist (logseq-org-roam--parse-fuzzy-links data plist))))))
    plist))

(defun my/gptel-roam-chat ()
  "Create a permanent Org-roam node for a GPT chat with robust tag handling."
  (interactive)
  (let* ((title (read-string "Chat Title: "))
         ;; 1. Pre-populate with :gpt: as the initial input
         (user-input (read-string "Tags: " "gpt"))
         ;; 2. Split by any sequence of whitespace, then join with colons
         (tag-list (split-string user-input "[[:space:]]+" t))
         (formatted-tags (concat ":" (mapconcat 'identity tag-list ":") ":"))

         (slug  (org-roam-node-slug (org-roam-node-create :title title)))
         (file  (expand-file-name
                 (format "computing/pages/%s-%s.org" (format-time-string "%Y%m%d%H%M%S") slug)
                 org-roam-directory)))
    (find-file file)
    (insert "#+title: " title "\n"
            "#+filetags: " formatted-tags "\n\n")
    (org-id-get-create)
    (gptel-mode 1)
    (save-buffer)
    (message "New GPT chat: %s with tags %s" title formatted-tags))
  )

;; Map it to your leader key
(map! :leader
      :prefix ("o" . "open")
      :desc "New GPT Roam chat" "c" #'my/gptel-roam-chat)

;;
;; Copyright (C) 2026 Andrew Patrick
;;
;; Author: Andrew Patrick <andrewpatrick@192.168.1.18>
;; Maintainer: Andrew Patrick <andrewpatrick@192.168.1.18>
;; Created: September 30, 2026
;; Modified: September 30, 2026
;; Version: 0.0.1
;; Keywords: abbrev bib c calendar comm convenience data docs emulations extensions faces files frames games hardware help hypermedia i18n internal languages lisp local maint mail matching mouse multimedia news outlines processes terminals tex text tools unix vc
;; Homepage: https://github.com/andrewpatrick/bug-fix
;; Package-Requires: ((emacs "24.3"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:



(provide 'bug-fix)
;;; bug-fix.el ends here
