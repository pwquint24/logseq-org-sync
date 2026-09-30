;;; logseq-org-sync-state.el --- Two-way sync metadata store -*- lexical-binding: t; -*-

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

;; The metadata store for the two-way sync engine (Phase 4).  It persists, per
;; node, the last-synced paths, hashes, mtimes, title, and timestamp — never
;; content (AGENTS.md §4).  It is keyed by the shared UUID that the identity
;; module (`logseq-org-sync-identity') assigns.
;;
;; ## State shape
;;
;;     (:version 1
;;      :nodes ((:id "uuid"
;;               :title "Foo"
;;               :roam-path "pages/Foo.org"
;;               :logseq-path "pages/Foo.org"
;;               :roam-hash "sha256hex"
;;               :logseq-hash "sha256hex"
;;               :roam-mtime (…)      ;; file-attribute-modification-time
;;               :logseq-mtime (…)
;;               :last-sync (…))
;;              ...))
;;
;; Records live in a flat list; `:id' is the key.  A record plist may omit any
;; field that is not yet known (nil values are simply absent).
;;
;; The file is written as a readable Lisp plist (`prin1'/`read'), which is the
;; same convention org uses for `org-id-locations-file'.

;;; Code:

(require 'cl-lib)

(defconst logseq-org-sync-state-version 1
  "Current state-store schema version.")

(defun logseq-org-sync-state-empty ()
  "Return an empty state."
  (list :version logseq-org-sync-state-version :nodes nil))

(defun logseq-org-sync-state-get (state id)
  "Return STATE's record for ID, or nil."
  (cl-find id (plist-get state :nodes)
           :key (lambda (record) (plist-get record :id))
           :test #'equal))

(defun logseq-org-sync-state-put (state record)
  "Return STATE with RECORD inserted.
Any existing record with the same `:id' is replaced."
  (let ((id (plist-get record :id)))
    (plist-put state :nodes
               (cons record
                     (cl-remove id (plist-get state :nodes)
                                :key (lambda (r) (plist-get r :id))
                                :test #'equal)))))

(defun logseq-org-sync-state-remove (state id)
  "Return STATE without any record for ID."
  (plist-put state :nodes
             (cl-remove id (plist-get state :nodes)
                        :key (lambda (record) (plist-get record :id))
                        :test #'equal)))

(defun logseq-org-sync-state-load (file)
  "Load the state in FILE, or return an empty state when absent or invalid."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((state (read (current-buffer))))
          (if (and (consp state) (eq (car state) :version))
              state
            (logseq-org-sync-state-empty))))
    (error (logseq-org-sync-state-empty))))

(defun logseq-org-sync-state-save (state file)
  "Write STATE to FILE as a readable Lisp plist."
  (let ((print-level nil)
        (print-length nil))
    (with-temp-buffer
      (prin1 state (current-buffer))
      (insert "\n")
      (write-region (point-min) (point-max) file))))

(provide 'logseq-org-sync-state)
;;; logseq-org-sync-state.el ends here
