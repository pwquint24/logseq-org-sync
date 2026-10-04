;;; logseq-org-sync-safety-test.el --- Tests for logseq-org-sync-safety -*- lexical-binding: t; -*-

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

;; ERT tests for the safety & UX layer (`logseq-org-sync-safety.el',
;; Phase 6): dry-run preview, pre-overwrite backup, conflict policy, and
;; the updated hook.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'logseq-org-sync-safety)
(require 'logseq-org-sync-state)

(defconst logseq-org-sync-safety-test-dir
  (file-name-directory (expand-file-name (or load-file-name buffer-file-name)))
  "Directory containing this test file.")

(defconst logseq-org-sync-safety-test-fixtures
  (expand-file-name "../fixtures/Work" logseq-org-sync-safety-test-dir)
  "Root of the Phase 0 paired `Work' fixtures.")

(defun logseq-org-sync-safety-test--setup ()
  "Copy the paired fixtures into a temp directory.
Return a plist with `:tmp', `:logseq-root', `:roam-root', and `:graph'."
  (let* ((tmp (make-temp-file "logseq-org-sync-safety-" t))
         (logseq-root (expand-file-name "logseq" tmp))
         (roam-root (expand-file-name "org-roam" tmp)))
    (copy-directory (expand-file-name "logseq" logseq-org-sync-safety-test-fixtures)
                    logseq-root t t t)
    (copy-directory (expand-file-name "org-roam" logseq-org-sync-safety-test-fixtures)
                    roam-root t t t)
    (list :tmp tmp
          :logseq-root logseq-root
          :roam-root roam-root
          :graph (list :name "work"
                       :logseq-root logseq-root
                       :roam-root roam-root
                       :pages-directory "pages"
                       :journals-directory "journals"))))

(defmacro logseq-org-sync-safety-test--with-setup (bindings &rest body)
  "Evaluate BODY with a fresh fixture copy bound to BINDINGS.
BINDINGS is a list of `(VAR ACCESSOR)' pairs; the temp directory is
deleted afterwards."
  (declare (indent 1))
  (let ((setup (cl-gensym "setup")))
    `(let* ((,setup (logseq-org-sync-safety-test--setup))
            ,@(mapcar (lambda (b) (list (car b) (list 'plist-get setup (cadr b))))
                      bindings))
       (unwind-protect
           (progn ,@body)
         (delete-directory (plist-get ,setup :tmp) t)))))

(defun logseq-org-sync-safety-test--baseline (graph)
  "Seed GRAPH's state and return it."
  (logseq-org-sync-reconcile-apply
   graph
   (logseq-org-sync-state-empty)
   (logseq-org-sync-reconcile-plan graph (logseq-org-sync-state-empty))))

(ert-deftest logseq-org-sync-safety--dry-run-empty ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph))
    (let ((state (logseq-org-sync-safety-test--baseline graph)))
      (should (string-match-p
               "nothing to do"
               (logseq-org-sync-safety-dry-run-text graph state))))))

(ert-deftest logseq-org-sync-safety--dry-run-reports-and-writes-nothing ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph) (lroot :logseq-root)
                                            (rroot :roam-root))
    (let ((state (logseq-org-sync-safety-test--baseline graph)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000004\n\n* Dry [[Project Alpha]]\n"
                    nil (expand-file-name "pages/Dry.org" lroot))
      (let ((text (logseq-org-sync-safety-dry-run-text graph state)))
        (should (string-match-p "create-roam" text))
        (should (string-match-p "pages/Dry.org" text)))
      ;; Dry-run must not create the org-roam file.
      (should (not (file-exists-p (expand-file-name "pages/Dry.org" rroot)))))))

(ert-deftest logseq-org-sync-safety--confirm-text-nil-without-moves ()
  (should-not
   (logseq-org-sync-safety-confirm-text
    '((:type create-roam :path "pages/New.org")
      (:type update-logseq :path "pages/Old.org")
      (:type seed :path "pages/Seed.org")))))

(ert-deftest logseq-org-sync-safety--confirm-text-lists-moves-and-deletes ()
  (let ((text
         (logseq-org-sync-safety-confirm-text
          '((:type create-roam :path "pages/New.org")
            (:type rename-roam :from "pages/Old.org" :to "pages/Newer.org")
            (:type trash-logseq :path "pages/Gone.org")))))
    (should text)
    (should (string-match-p "move or delete" text))
    (should (string-match-p
             "Rename org-roam note pages/Old.org to pages/Newer.org" text))
    (should (string-match-p
             "Move Logseq note pages/Gone.org to trash" text))
    (should-not (string-match-p "create-roam" text))))

(ert-deftest logseq-org-sync-safety--backup-before-overwrite ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph) (lroot :logseq-root)
                                            (rroot :roam-root))
    (let* ((state (logseq-org-sync-safety-test--baseline graph))
           (rf (expand-file-name "pages/Project Alpha.org" rroot))
           (original (with-temp-buffer (insert-file-contents rf) (buffer-string))))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n\n* TODO Revised\n"
                    nil (expand-file-name "pages/Project Alpha.org" lroot))
      (setq state (logseq-org-sync-safety-plan-and-apply graph state))
      ;; The overwritten org-roam file was backed up with its old content.
      (let ((backup (expand-file-name ".backup/pages/Project Alpha.org" rroot)))
        (should (file-exists-p backup))
        (should (equal original
                       (with-temp-buffer
                         (insert-file-contents backup)
                         (buffer-string))))))))

(ert-deftest logseq-org-sync-safety--backup-disabled ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph) (lroot :logseq-root)
                                            (rroot :roam-root))
    (let ((logseq-org-sync-safety-backup-enabled nil)
          (state (logseq-org-sync-safety-test--baseline graph)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n\n* TODO Revised\n"
                    nil (expand-file-name "pages/Project Alpha.org" lroot))
      (setq state (logseq-org-sync-safety-plan-and-apply graph state))
      (should (not (file-exists-p
                    (expand-file-name ".backup/pages/Project Alpha.org" rroot)))))))

(ert-deftest logseq-org-sync-safety--conflict-prompt-selects-roam ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph) (lroot :logseq-root)
                                            (rroot :roam-root))
    (let* ((logseq-org-sync-reconcile-conflict-policy 'prompt)
           (logseq-org-sync-reconcile-prompt-function
            (lambda (_id _logseq _roam) 'roam))
           (state (logseq-org-sync-safety-test--baseline graph))
           (lf (expand-file-name "pages/Project Alpha.org" lroot))
           (rf (expand-file-name "pages/Project Alpha.org" rroot)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n\n* Logseq edit\n" nil lf)
      (write-region ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000001\n:END:\n#+title: Project Alpha\n\n* Roam edit\n" nil rf)
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(update-logseq)
                       (mapcar (lambda (a) (plist-get a :type)) plan)))
        (should (eq 'conflict (plist-get (car plan) :reason)))))))

(ert-deftest logseq-org-sync-safety--updated-hook-runs-on-change ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph) (lroot :logseq-root))
    (let* ((ran nil)
           (logseq-org-sync-updated-hook
            (list (lambda () (setq ran t))))
           (state (logseq-org-sync-safety-test--baseline graph)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n\n* TODO Revised\n"
                    nil (expand-file-name "pages/Project Alpha.org" lroot))
      (logseq-org-sync-safety-plan-and-apply graph state)
      (should ran))))

(ert-deftest logseq-org-sync-safety--updated-hook-skipped-when-clean ()
  (logseq-org-sync-safety-test--with-setup ((graph :graph))
    (let* ((ran nil)
           (logseq-org-sync-updated-hook
            (list (lambda () (setq ran t))))
           (state (logseq-org-sync-safety-test--baseline graph)))
      (logseq-org-sync-safety-plan-and-apply graph state)
      (should-not ran))))

(provide 'logseq-org-sync-safety-test)
;;; logseq-org-sync-safety-test.el ends here
