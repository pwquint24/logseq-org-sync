;;; logseq-org-sync-safety.el --- Safety & UX for the two-way sync -*- lexical-binding: t; -*-

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

;; The safety & UX layer for the two-way sync engine (Phase 6, AGENTS.md §10).
;; It wraps the Phase 5 reconciler (`logseq-org-sync-reconcile') with the
;; guardrails that make a destructive sync safe to run:
;;
;; - **Dry-run preview** — `logseq-org-sync-safety-dry-run-text' renders the
;;   reconciler's plan as human-readable text without touching the filesystem.
;; - **Backup** — before a file is overwritten, `logseq-org-sync-safety-apply'
;;   copies it under a `.backup' subdirectory of its graph root.  Deletions are
;;   moved to trash by the reconciler (never hard-deleted; AGENTS.md §1.7).
;; - **Conflict policy** — newest-wins (default) or prompt-on-conflict; the
;;   policy and prompt live on the reconciler as
;;   `logseq-org-sync-reconcile-conflict-policy' and
;;   `logseq-org-sync-reconcile-prompt-function' (AGENTS.md §6).
;; - **Updated hook** — `logseq-org-sync-updated-hook' runs after any change.
;;
;; The module is deliberately thin: planning, classification, and execution
;; stay in the reconciler so they remain independently testable.

;;; Code:

(require 'cl-lib)
(require 'logseq-org-sync-reconcile)

(defgroup logseq-org-sync-safety nil
  "Safety and UX options for the logseq/org-roam two-way sync."
  :group 'logseq-org-sync
  :prefix "logseq-org-sync-")

(defcustom logseq-org-sync-updated-hook nil
  "Hook run after a sync applies changes.
It is called once per `logseq-org-sync-safety-apply' when the plan was
non-empty (i.e. at least one file changed)."
  :type 'hook
  :group 'logseq-org-sync-safety)

(defcustom logseq-org-sync-safety-backup-directory ".backup"
  "Subdirectory, under a graph root, that receives pre-overwrite backups."
  :type 'string
  :group 'logseq-org-sync-safety)

(defcustom logseq-org-sync-safety-backup-enabled t
  "When non-nil, back up a file before overwriting it during sync."
  :type 'boolean
  :group 'logseq-org-sync-safety)

(defun logseq-org-sync-safety--action-description (action)
  "Return a one-line human-readable description of ACTION."
  (let ((type (plist-get action :type))
        (path (or (plist-get action :path)
                  (plist-get action :to)
                  (plist-get action :from)))
        (reason (plist-get action :reason)))
    (format "%-14s %-24s (%s)"
            type
            (or path "-")
            reason)))

(defun logseq-org-sync-safety--move-delete-p (action)
  "Return non-nil when ACTION moves or deletes a file.
Rename actions move a file and trash actions move its surviving mirror
to trash (AGENTS.md §7)."
  (memq (plist-get action :type)
        '(rename-roam rename-logseq trash-roam trash-logseq)))

(defun logseq-org-sync-safety--move-delete-description (action)
  "Return a human-readable description of a move/delete ACTION."
  (pcase (plist-get action :type)
    ('rename-roam
     (format "Rename org-roam note %s to %s (renamed on the Logseq side)"
             (plist-get action :from) (plist-get action :to)))
    ('rename-logseq
     (format "Rename Logseq note %s to %s (renamed on the org-roam side)"
             (plist-get action :from) (plist-get action :to)))
    ('trash-roam
     (format "Move org-roam note %s to trash (deleted on the Logseq side)"
             (plist-get action :path)))
    ('trash-logseq
     (format "Move Logseq note %s to trash (deleted on the org-roam side)"
             (plist-get action :path)))))

(defun logseq-org-sync-safety-confirm-text (plan)
  "Return a confirmation question for PLAN, or nil when none is needed.
Only move/delete actions (renames and trashes) ask for confirmation;
they are listed so the user can see exactly what will change.  Plans
with only create/update/seed actions return nil and can be applied
without prompting."
  (let ((actions (cl-remove-if-not #'logseq-org-sync-safety--move-delete-p
                                   plan)))
    (when actions
      (format "This sync will move or delete %d file%s:\n%s\nProceed? "
              (length actions)
              (if (= (length actions) 1) "" "s")
              (mapconcat (lambda (action)
                           (concat "  "
                                   (logseq-org-sync-safety--move-delete-description
                                    action)))
                         actions "\n")))))

(defun logseq-org-sync-safety-dry-run-text (graph state)
  "Return a human-readable preview of the reconciliation of GRAPH and STATE.
The plan is computed but never applied, so the filesystem is untouched."
  (let* ((plan (logseq-org-sync-reconcile-plan graph state))
         (name (or (plist-get graph :name) "unnamed")))
    (if (null plan)
        (format "Sync plan for %S: nothing to do.\n" name)
      (concat
       (format "Sync plan for %S (%d action%s):\n"
               name (length plan) (if (= (length plan) 1) "" "s"))
       (mapconcat (lambda (action)
                    (concat "  "
                            (logseq-org-sync-safety--action-description action)))
                  plan "\n")
       "\n"))))

(defun logseq-org-sync-safety--abs-for-action (graph action)
  "Return (ABS . ROOT) for the file ACTION will overwrite in GRAPH, or nil.
Create/update actions write the target side's copy; renames overwrite
the `:to' path.  Trash and seed actions write nothing."
  (let* ((type (plist-get action :type))
         (path (plist-get action :path)))
    (pcase type
      ((or 'create-roam 'update-roam)
       (and path (cons (expand-file-name path (plist-get graph :roam-root))
                       (plist-get graph :roam-root))))
      ((or 'create-logseq 'update-logseq)
       (and path (cons (expand-file-name path (plist-get graph :logseq-root))
                       (plist-get graph :logseq-root))))
      ('rename-roam
       (let ((to (plist-get action :to)))
         (and to (cons (expand-file-name to (plist-get graph :roam-root))
                       (plist-get graph :roam-root)))))
      ('rename-logseq
       (let ((to (plist-get action :to)))
         (and to (cons (expand-file-name to (plist-get graph :logseq-root))
                       (plist-get graph :logseq-root)))))
      (_ nil))))

(defun logseq-org-sync-safety--backup-targets (graph plan)
  "Return the files PLAN will overwrite in GRAPH as (ABS . ROOT) pairs.
Only paths whose file currently exists are included (a non-existent
target does not need backing up)."
  (let ((targets nil))
    (dolist (action plan)
      (let ((target (logseq-org-sync-safety--abs-for-action graph action)))
        (when (and target (file-exists-p (car target)))
          (push target targets))))
    (nreverse targets)))

(defun logseq-org-sync-safety--backup-file (abs root)
  "Copy ABS under ROOT's backup subdirectory.
The relative path under ROOT is preserved inside the backup directory."
  (let* ((rel (file-relative-name abs (file-name-as-directory
                                       (expand-file-name root))))
         (dest (expand-file-name
                (concat logseq-org-sync-safety-backup-directory "/" rel)
                (expand-file-name root))))
    (make-directory (file-name-directory dest) t)
    (copy-file abs dest 'ok-if-already-exists)
    dest))

(defun logseq-org-sync-safety--backup (graph plan)
  "Back up every file PLAN will overwrite in GRAPH.
Returns the list of backup destination paths.  Each overwrite target is
copied under its graph root's backup subdirectory before `apply' runs."
  (let ((backups nil))
    (dolist (target (logseq-org-sync-safety--backup-targets graph plan))
      (push (logseq-org-sync-safety--backup-file (car target) (cdr target))
            backups))
    (nreverse backups)))

;;;###autoload
(defun logseq-org-sync-safety-apply (graph state plan)
  "Apply PLAN for GRAPH with backups, returning the updated STATE.
When `logseq-org-sync-safety-backup-enabled' is non-nil, files about to
be overwritten are first copied into the backup subdirectory.  If the
plan is non-empty, `logseq-org-sync-updated-hook' runs afterwards."
  (when (and logseq-org-sync-safety-backup-enabled plan)
    (logseq-org-sync-safety--backup graph plan))
  (let ((state (logseq-org-sync-reconcile-apply graph state plan)))
    (when plan
      (run-hooks 'logseq-org-sync-updated-hook))
    state))

;;;###autoload
(defun logseq-org-sync-safety-plan-and-apply (graph state)
  "Plan and safely apply the reconciliation of GRAPH and STATE.
Returns the updated state.  This is the convenience entry point that
combines `logseq-org-sync-reconcile-plan' and
`logseq-org-sync-safety-apply'."
  (let ((plan (logseq-org-sync-reconcile-plan graph state)))
    (logseq-org-sync-safety-apply graph state plan)))

(provide 'logseq-org-sync-safety)
;;; logseq-org-sync-safety.el ends here
