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

(defconst logseq-org-sync-reconcile-test-markdown-fixtures
  (expand-file-name "../fixtures/Work-markdown" logseq-org-sync-reconcile-test-dir)
  "Root of the Phase 0 paired Markdown `Work' fixtures.")

(defun logseq-org-sync-reconcile-test--markdown-setup ()
  "Copy the paired Markdown fixtures into a temp directory.
Return a plist with `:tmp', `:logseq-root', `:roam-root', and `:graph'."
  (let* ((tmp (make-temp-file "logseq-org-sync-reconcile-md-" t))
         (logseq-root (expand-file-name "logseq" tmp))
         (roam-root (expand-file-name "org-roam" tmp)))
    (copy-directory (expand-file-name "logseq"
                                      logseq-org-sync-reconcile-test-markdown-fixtures)
                    logseq-root t t t)
    (copy-directory (expand-file-name "org-roam"
                                      logseq-org-sync-reconcile-test-markdown-fixtures)
                    roam-root t t t)
    (list :tmp tmp
          :logseq-root logseq-root
          :roam-root roam-root
          :graph (list :name "work-md"
                       :logseq-root logseq-root
                       :roam-root roam-root
                       :pages-directory "pages"
                       :journals-directory "journals"))))

(defmacro logseq-org-sync-reconcile-test--with-markdown-setup (bindings &rest body)
  "Evaluate BODY with a fresh Markdown fixture copy bound to BINDINGS.
BINDINGS is a list of `(VAR ACCESSOR)' pairs, e.g. `((graph :graph))'.
The temp directory is deleted afterwards."
  (declare (indent 1))
  (let ((setup (cl-gensym "setup")))
    `(let* ((,setup (logseq-org-sync-reconcile-test--markdown-setup))
            ,@(mapcar (lambda (b) (list (car b) (list 'plist-get setup (cadr b))))
                      bindings))
       (unwind-protect
           (progn ,@body)
         (delete-directory (plist-get ,setup :tmp) t)))))

(ert-deftest logseq-org-sync-reconcile--markdown-fresh-state-seeds ()
  (logseq-org-sync-reconcile-test--with-markdown-setup ((graph :graph))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (should (= 3 (length (plist-get state :nodes))))
      ;; The Markdown logseq paths are recorded with their native `.md'
      ;; extension; the org-roam paths keep `.org'.
      (should (equal "pages/Project Alpha.md"
                     (plist-get (logseq-org-sync-state-get
                                 state "10000000-0000-0000-0000-000000000001")
                                :logseq-path)))
      (should (equal "pages/Project Alpha.org"
                     (plist-get (logseq-org-sync-state-get
                                 state "10000000-0000-0000-0000-000000000001")
                                :roam-path)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--markdown-new-on-logseq-creates-roam ()
  (logseq-org-sync-reconcile-test--with-markdown-setup ((graph :graph)
                                                        (lroot :logseq-root)
                                                        (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (write-region "id:: 10000000-0000-0000-0000-000000000004\n\n- New note [[Project Alpha]]\n"
                    nil (expand-file-name "pages/New Note.md" lroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (should (equal "pages/New Note.org" (plist-get (car plan) :path)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p (expand-file-name "pages/New Note.org" rroot)))
      (should-not (file-exists-p (expand-file-name "pages/New Note.md" rroot)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--markdown-new-on-roam-creates-logseq ()
  (logseq-org-sync-reconcile-test--with-markdown-setup ((graph :graph)
                                                        (lroot :logseq-root)
                                                        (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph)))
      (write-region ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000005\n:END:\n#+title: Fresh\n\n* From roam [[id:10000000-0000-0000-0000-000000000001][Project Alpha]]\n"
                    nil (expand-file-name "pages/Fresh.org" rroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (should (equal "pages/Fresh.md" (plist-get (car plan) :path)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      (should (file-exists-p (expand-file-name "pages/Fresh.md" lroot)))
      (should-not (file-exists-p (expand-file-name "pages/Fresh.org" lroot)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(defconst logseq-org-sync-reconcile-test--block-uuid
  "11111111-1111-1111-1111-111111111111"
  "UUID used to exercise block reference translation.")

(defun logseq-org-sync-reconcile-test--block-registry ()
  "Return a block registry mapping the shared block UUID to \"Hello block\"."
  (let ((reg (make-hash-table :test #'equal)))
    (puthash logseq-org-sync-reconcile-test--block-uuid "Hello block" reg)
    reg))

(ert-deftest logseq-org-sync-reconcile--translate-block-reference ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "See [[id:11111111-1111-1111-1111-111111111111][Hello block]] now"
             (logseq-org-sync-reconcile--translate-logseq-text
              "See ((11111111-1111-1111-1111-111111111111)) now" reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-block-embed ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "[[id:11111111-1111-1111-1111-111111111111][#embed Hello block]]"
             (logseq-org-sync-reconcile--translate-logseq-text
              "{{embed ((11111111-1111-1111-1111-111111111111))}}" reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-block-ref-dangling ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "((00000000-0000-0000-0000-000000000000))"
             (logseq-org-sync-reconcile--translate-logseq-text
              "((00000000-0000-0000-0000-000000000000))" reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-block-ref-sanitizes-description ()
  (let ((reg (make-hash-table :test #'equal)))
    (puthash logseq-org-sync-reconcile-test--block-uuid
             "See [[Project Alpha]]" reg)
    (should (equal
             "[[id:11111111-1111-1111-1111-111111111111][See Project Alpha]]"
             (logseq-org-sync-reconcile--translate-logseq-text
              (concat "((" logseq-org-sync-reconcile-test--block-uuid "))")
              reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-roam-block-link ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "See ((11111111-1111-1111-1111-111111111111)) now"
             (logseq-org-sync-reconcile--translate-roam-text
              "See [[id:11111111-1111-1111-1111-111111111111][Hello block]] now"
              reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-roam-block-embed ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "{{embed ((11111111-1111-1111-1111-111111111111))}}"
             (logseq-org-sync-reconcile--translate-roam-text
              "[[id:11111111-1111-1111-1111-111111111111][#embed Hello block]]"
              reg)))))

(ert-deftest logseq-org-sync-reconcile--translate-roam-page-link-untouched ()
  (let ((reg (logseq-org-sync-reconcile-test--block-registry)))
    (should (equal
             "[[id:99999999-9999-9999-9999-999999999999][Project Alpha]]"
             (logseq-org-sync-reconcile--translate-roam-text
              "[[id:99999999-9999-9999-9999-999999999999][Project Alpha]]"
              reg)))))

(ert-deftest logseq-org-sync-reconcile--block-reference-propagates-to-roam ()
  (logseq-org-sync-reconcile-test--with-markdown-setup ((graph :graph)
                                                        (lroot :logseq-root)
                                                        (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph))
          (block-uuid "11111111-1111-1111-1111-111111111111"))
      ;; A referenced block, and a page referencing/embedding it.
      (write-region (concat "- Important block\n  id:: " block-uuid "\n")
                    nil (expand-file-name "pages/Blocks.md" lroot))
      (write-region (concat "- Reference ((" block-uuid "))\n"
                            "- Embed {{embed ((" block-uuid "))}}\n")
                    nil (expand-file-name "pages/Refs.md" lroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-roam create-roam)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      ;; The org-roam copy of the referencing page carries id links.
      (let ((text (with-temp-buffer
                    (insert-file-contents (expand-file-name "pages/Refs.org" rroot))
                    (buffer-string))))
        (should (string-match-p
                 (regexp-quote (format "[[id:%s][Important block]]" block-uuid))
                 text))
        (should (string-match-p
                 (regexp-quote (format "[[id:%s][#embed Important block]]" block-uuid))
                 text)))
      ;; The referenced block's Logseq id became an org-roam heading :ID:.
      (let ((text (with-temp-buffer
                    (insert-file-contents (expand-file-name "pages/Blocks.org" rroot))
                    (buffer-string))))
        (should (string-match-p (concat ":ID: " block-uuid) text)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(ert-deftest logseq-org-sync-reconcile--block-reference-propagates-to-logseq ()
  (logseq-org-sync-reconcile-test--with-markdown-setup ((graph :graph)
                                                        (lroot :logseq-root)
                                                        (rroot :roam-root))
    (let ((state (logseq-org-sync-reconcile-test--baseline graph))
          (block-uuid "11111111-1111-1111-1111-111111111111"))
      ;; A referenced org-roam block, and a page linking/embedding it.
      (write-region (concat ":PROPERTIES:\n"
                            ":ID: 22222222-2222-2222-2222-222222222222\n"
                            ":END:\n"
                            "#+title: Blocks\n\n"
                            "* Important block\n"
                            ":PROPERTIES:\n"
                            ":ID: " block-uuid "\n"
                            ":END:\n")
                    nil (expand-file-name "pages/Blocks.org" rroot))
      (write-region (concat ":PROPERTIES:\n"
                            ":ID: 33333333-3333-3333-3333-333333333333\n"
                            ":END:\n"
                            "#+title: Refs\n\n"
                            "* Ref [[id:" block-uuid "][Important block]]\n"
                            "* Embed [[id:" block-uuid "][#embed Important block]]\n")
                    nil (expand-file-name "pages/Refs.org" rroot))
      (let ((plan (logseq-org-sync-reconcile-plan graph state)))
        (should (equal '(create-logseq create-logseq)
                       (logseq-org-sync-reconcile-test--types plan)))
        (setq state (logseq-org-sync-reconcile-apply graph state plan)))
      ;; The Logseq copy uses ((uuid)) / {{embed ((uuid))}}.
      (let ((text (with-temp-buffer
                    (insert-file-contents (expand-file-name "pages/Refs.md" lroot))
                    (buffer-string))))
        (should (string-match-p
                 (regexp-quote (format "((%s))" block-uuid)) text))
        (should (string-match-p
                 (regexp-quote (format "{{embed ((%s))}}" block-uuid)) text)))
      ;; The org-roam heading :ID: became a Markdown block id::.
      (let ((text (with-temp-buffer
                    (insert-file-contents (expand-file-name "pages/Blocks.md" lroot))
                    (buffer-string))))
        (should (string-match-p (concat "id:: " block-uuid) text)))
      (should (null (logseq-org-sync-reconcile-plan graph state))))))

(provide 'logseq-org-sync-reconcile-test)
;;; logseq-org-sync-reconcile-test.el ends here
