;;; logseq-org-sync-roam-test.el --- Tests for logseq-org-sync-roam -*- lexical-binding: t; -*-

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

;; ERT tests for the org-roam side of the two-way sync engine
;; (`logseq-org-sync-roam.el').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'logseq-org-sync-roam)

(defconst logseq-org-sync-roam-test-dir
  (file-name-directory (expand-file-name (or load-file-name buffer-file-name)))
  "Directory containing this test file.")

(defconst logseq-org-sync-roam-test-fixtures
  (expand-file-name "../fixtures/Work/org-roam" logseq-org-sync-roam-test-dir)
  "Root of the Phase 0 org-roam fixture graph.")

(defconst logseq-org-sync-roam-test-journal
  (expand-file-name "journals/2026-09-30.org" logseq-org-sync-roam-test-fixtures))

(defconst logseq-org-sync-roam-test-meeting
  (expand-file-name "pages/Meeting Notes.org" logseq-org-sync-roam-test-fixtures))

(defconst logseq-org-sync-roam-test-project
  (expand-file-name "pages/Project Alpha.org" logseq-org-sync-roam-test-fixtures))

(ert-deftest logseq-org-sync-roam--scan ()
  (should (equal (logseq-org-sync-roam-scan logseq-org-sync-roam-test-fixtures)
                 (list logseq-org-sync-roam-test-journal
                       logseq-org-sync-roam-test-meeting
                       logseq-org-sync-roam-test-project))))

(ert-deftest logseq-org-sync-roam--parse-project-alpha ()
  (should (equal
           (logseq-org-sync-roam-parse-file logseq-org-sync-roam-test-project)
           '(:title "Project Alpha"
             :id "10000000-0000-0000-0000-000000000001"
             :aliases ("Alpha" "ProjA")
             :content ((:level 1 :todo "TODO" :text "Draft the proposal"
                        :children ((:level 2
                                    :text "Share with [[id:10000000-0000-0000-0000-000000000002][Meeting Notes]]")))
                       (:level 1 :todo "DONE" :text "Ship the first milestone"))
             :links ((id "10000000-0000-0000-0000-000000000002" "Meeting Notes"))))))

(ert-deftest logseq-org-sync-roam--parse-meeting-notes ()
  (should (equal
           (logseq-org-sync-roam-parse-file logseq-org-sync-roam-test-meeting)
           '(:title "Meeting Notes"
             :id "10000000-0000-0000-0000-000000000002"
             :aliases ("Notes")
             :content ((:level 1
                        :text "Summarize decisions from [[id:10000000-0000-0000-0000-000000000001][Project Alpha]]"
                        :children ((:level 2 :text "Follow up on action items"))))
             :links ((id "10000000-0000-0000-0000-000000000001" "Project Alpha"))))))

(ert-deftest logseq-org-sync-roam--parse-journal ()
  (should (equal
           (logseq-org-sync-roam-parse-file logseq-org-sync-roam-test-journal)
           '(:title "2026-09-30"
             :id "10000000-0000-0000-0000-000000000003"
             :content ((:level 1
                        :text "Review [[id:10000000-0000-0000-0000-000000000001][Project Alpha]] proposal"
                        :children ((:level 2 :todo "TODO" :text "Send feedback"))))
             :links ((id "10000000-0000-0000-0000-000000000001" "Project Alpha"))))))

(ert-deftest logseq-org-sync-roam--block-properties-round-trip ()
  (let ((text "#+title: X

* TODO Draft :proj:work:
SCHEDULED: <2026-10-01 Thu> DEADLINE: <2026-10-05 Mon>
:PROPERTIES:
:ID: abc
:foo: bar
:END:
** Child
"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (should (equal text
                     (logseq-org-sync-roam-format
                      (logseq-org-sync-roam-parse-buffer "X")))))))

(ert-deftest logseq-org-sync-roam--planning-round-trip ()
  (let ((text "#+title: X

* TODO Do the thing
SCHEDULED: <2026-10-01 Thu>
** Child
"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (should (equal text
                     (logseq-org-sync-roam-format
                      (logseq-org-sync-roam-parse-buffer "X")))))))

(ert-deftest logseq-org-sync-roam--parse-block-body ()
  (let ((text "* TODO Draft
SCHEDULED: <2026-10-01 Thu>
:PROPERTIES:
:ID: abc
:END:
A body paragraph.
"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (let ((block (car (plist-get (logseq-org-sync-roam-parse-buffer "X")
                                   :content))))
        (should (equal "A body paragraph." (plist-get block :body)))
        (should (equal "<2026-10-01 Thu>" (plist-get block :scheduled)))
        (should (equal '(("ID" . "abc")) (plist-get block :properties)))))))

(ert-deftest logseq-org-sync-roam--round-trip ()
  (dolist (file (logseq-org-sync-roam-scan logseq-org-sync-roam-test-fixtures))
    (let ((expected (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
      (should (equal expected
                     (logseq-org-sync-roam-format
                      (logseq-org-sync-roam-parse-file file)))))))

(ert-deftest logseq-org-sync-roam--page-tags ()
  (let ((text ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000001\n:END:\n#+title: X\n#+filetags: :a:b:\n\n* One\n"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (let ((node (logseq-org-sync-roam-parse-buffer "Fallback")))
        (should (equal '("a" "b") (plist-get node :tags)))))))

(ert-deftest logseq-org-sync-roam--page-tags-round-trip ()
  (let ((node '(:title "X" :id "10000000-0000-0000-0000-000000000001"
                :tags ("a" "b"))))
    (should (equal
             ":PROPERTIES:\n:ID: 10000000-0000-0000-0000-000000000001\n:END:\n#+title: X\n#+filetags: :a:b:\n"
             (logseq-org-sync-roam-format node)))))

(provide 'logseq-org-sync-roam-test)
;;; logseq-org-sync-roam-test.el ends here
