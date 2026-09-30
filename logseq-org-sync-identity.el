;;; logseq-org-sync-identity.el --- Node identity (UUID) assignment -*- lexical-binding: t; -*-

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

;; Node identity for the two-way sync engine (Phase 4).  Every note shares a
;; stable UUID across the Logseq and org-roam sides (AGENTS.md §3–§4): the
;; Logseq side stores it as `#+id: <uuid>' and the org-roam side as
;; `:ID: <uuid>'.
;;
;; New IDs are generated with `org-id-new' — the same built-in Org facility
;; org-roam uses when creating a node (see `org-roam-capture-', which assigns
;; `(org-id-new)' to a node that has no ID).  Using it here keeps generated IDs
;; consistent with org-roam's own ID namespace rather than inventing a second
;; one.

;;; Code:

(require 'org-id)

(defun logseq-org-sync-identity-new ()
  "Return a new UUID for a node.
Uses `org-id-new' (the same generator org-roam uses for new nodes)."
  (org-id-new))

(defun logseq-org-sync-identity-ensure-node (node)
  "Return NODE with a guaranteed `:id'.
An existing `:id' is preserved; otherwise a new UUID is assigned via
`org-id-new'."
  (if (plist-get node :id)
      node
    (plist-put node :id (org-id-new))))

(provide 'logseq-org-sync-identity)
;;; logseq-org-sync-identity.el ends here
