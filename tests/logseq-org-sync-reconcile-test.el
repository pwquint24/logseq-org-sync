;;; logseq-org-sync-reconcile-test.el --- Tests for logseq-org-sync-reconcile -*- lexical-binding: t; -*-

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

;; ERT tests for the two-way reconciler (`logseq-org-sync-reconcile.el',
;; Phase 5).  Each test copies the Phase 0 `Work' fixtures into a temporary
;; directory so the real fixtures are never mutated.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'logseq-org-sync-reconcile)
(require 'logseq-org-sync-state)

(defconst logseq-org-sync-reconcile-test-dir
  (file-name-directory (expand-file-name (or load-file-name buffer-file-name)))
  "Directory containing this test file.")

(defconst logseq-org-sync-reconcile-test-fixtures
  (expand-file-name "../fixtures/Work" logseq-org-sync-reconcile-test-dir)
  "Root of the Phase 0 paired `Work' fixtures.")

(defun logseq-org-sync-reconcile-test--setup ()
  "Copy the paired fixtures into a temp directory.
Return a plist with `:tmp', `:logseq-root', `:roam-root', and `:graph'."
  (let* ((tmp (make-temp-file "logseq-org-sync-reconcile-" t))
         (logseq-root (expand-file-name "logseq" tmp))
         (roam-root (expand-file-name "org-roam" tmp)))
    (copy-directory (expand-file-name "logseq"
                                      logseq-org-sync-reconcile-test-fixtures)
                    logseq-root t t t)
    (copy-directory (expand-file-name "org-roam"
                                      logseq-org-sync-reconcile-test-fixtures)
                    roam-root t t t)
    (list :tmp tmp
          :logseq-root logseq-root
          :roam-root roam-root
          :graph (list :name "work"
                       :logseq-root logseq-root
                       :roam-root roam-root
                       :pages-directory "pages"
                       :journals-directory "journals"))))

(defmacro logseq-org-sync-reconcile-test--with-setup (bindings &rest body)
  "Evaluate BODY with a fresh fixture copy bound to BINDINGS.
BINDINGS is a list of `(VAR ACCESSOR)' pairs, e.g. `((graph :graph))'.
The temp directory is deleted afterwards."
  (declare (indent 1))
  (let ((setup (cl-gensym "setup")))
    `(let* ((,setup (logseq-org-sync-reconcile-test--setup))
            ,@(mapcar (lambda (b) (list (car b) (list 'plist-get setup (cadr b))))
                      bindings))
       (unwind-protect
           (progn ,@body)
         (delete-directory (plist-get ,setup :tmp) t)))))

(defun logseq-org-sync-reconcile-test--baseline (graph)
  "Seed GRAPH's state and return it.
Both fixture sides are populated, so the first plan only seeds state."
  (logseq-org-sync-reconcile-apply
   graph
   (logseq-org-sync-state-empty)
   (logseq-org-sync-reconcile-plan graph (logseq-org-sync-state-empty))))

(defun logseq-org-sync-reconcile-test--types (plan)
  "Return the `:type' of each action in PLAN."
  (mapcar (lambda (action) (plist-get action :type)) plan))

(ert-deftest logseq-org-sync-reconcile--fresh-state-seeds ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph))
    (let ((plan (logseq-org-sync-reconcile-plan
                 graph (logseq-org-sync-state-empty))))
      (should (equal '(seed seed seed)
                     (logseq-org-sync-reconcile-test--types plan)))
      ;; Planning must not write anything: the org-roam tree is unchanged.
      (should (file-exists-p
               (expand-file-name "pages/Project Alpha.org"
                                 (plist-get graph :roam-root)))))))

(ert-deftest logseq-org-sync-reconcile--apply-converges ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      ;; After seeding, a second run plans nothing.
      (should (null (logseq-org-sync-reconcile-plan graph state)))
      (should (= 3 (length (plist-get state :nodes)))))))

(ert-deftest logseq-org-sync-reconcile--new-on-logseq-creates-roam ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000004\n\n* New note [[Project Alpha]]\n"
                    nil (expand-file-name "pages/New Note.org" lroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p (expand-file-name "pages/New Note.org" rroot)))
      ;; Converges after the propagation.
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--new-on-roam-creates-logseq ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (write-region ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000005\n:END:\n#+title: Fresh\n\n* From roam [[id:10000000-0000-0000-0000-000000000001][Project Alpha]]\n"
                    nil (expand-file-name "pages/Fresh.org" rroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p (expand-file-name "pages/Fresh.org" lroot)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--modified-logseq-updates-roam ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph))
          (lf (expand-file-name "pages/Project Alpha.org" lroot))
          (rf (expand-file-name "pages/Project Alpha.org" rroot)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n\n* TODO Revised proposal\n"
                    nil lf)
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(update-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      ;; The org-roam copy now carries the revised block.
      (should (string-match-p
               "Revised proposal"
               (with-temp-buffer (insert-file-contents rf) (buffer-string))))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--modified-roam-updates-logseq ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph))
          (lf (expand-file-name "pages/Project Alpha.org" lroot))
          (rf (expand-file-name "pages/Project Alpha.org" rroot)))
      (write-region ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000001\n:END:\n#+title: Project Alpha\n\n* TODO Revised from roam\n"
                    nil rf)
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(update-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (string-match-p
               "Revised from roam"
               (with-temp-buffer (insert-file-contents lf) (buffer-string))))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--both-modified-newest-wins ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph))
          (lf (expand-file-name "pages/Project Alpha.org" lroot))
          (rf (expand-file-name "pages/Project Alpha.org" rroot)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000001\n\n* Logseq edit\n"
                    nil lf)
      (write-region ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000001\n:END:\n#+title: Project Alpha\n\n* Roam edit\n"
                    nil rf)
      ;; Make the org-roam file the newer one.
      (set-file-times lf '(0 0))
      (set-file-times rf (current-time))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        ;; Newest wins: the roam copy propagates to Logseq.
        (should (equal '(update-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (should (eq 'newest-wins (plist-get (car plan) :reason)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (string-match-p
               "Roam edit"
               (with-temp-buffer (insert-file-contents lf) (buffer-string)))))))

(ert-deftest logseq-org-sync-reconcile--rename-mirrors-to-roam ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (rename-file (expand-file-name "pages/Project Alpha.org" lroot)
                   (expand-file-name "pages/Project Renamed.org" lroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(rename-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (should (equal "pages/Project Renamed.org"
                       (plist-get (car plan) :to)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p (expand-file-name "pages/Project Renamed.org" rroot)))
      (should (not (file-exists-p (expand-file-name "pages/Project Alpha.org" rroot))))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--delete-logseq-trashes-roam ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (delete-file (expand-file-name "pages/Meeting Notes.org" lroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(trash-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      ;; The org-roam copy moved to trash, not hard-deleted.
      (should (file-exists-p
               (expand-file-name ".trash/pages/Meeting Notes.org" rroot)))
      (should (not (file-exists-p
                    (expand-file-name "pages/Meeting Notes.org" rroot))))
      ;; The node was dropped from the state.
      (should (null (logseq-org-sync-state-get
                     state "10000000-0000-0000-0000-000000000002"))))))

(ert-deftest logseq-org-sync-reconcile--delete-roam-trashes-logseq ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (delete-file (expand-file-name "pages/Meeting Notes.org" rroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(trash-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p
               (expand-file-name ".trash/pages/Meeting Notes.org" lroot)))
      (should (not (file-exists-p
                    (expand-file-name "pages/Meeting Notes.org" lroot)))))))

(ert-deftest logseq-org-sync-reconcile--dry-run-writes-nothing ()
  (logseq-org-sync-reconcile-test--with-setup ((graph :graph) (lroot :logseq-root)
                                               (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (write-region "#+id: 10000000-0000-0000-0000-000000000004\n\n* Dry [[Project Alpha]]\n"
                    nil (expand-file-name "pages/Dry.org" lroot))
      (let ((plan (logseq-org-sync-reconcile-dry-run graph state)))
        (should (equal '(create-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        ;; Dry-run must not create the org-roam file.
        (should (not (file-exists-p (expand-file-name "pages/Dry.org" rroot))))))))

(provide 'logseq-org-sync-reconcile-test)
;;; logseq-org-sync-reconcile-test.el ends here
