;;; logseq-org-sync-logseq-test.el --- Tests for logseq-org-sync-logseq -*- lexical-binding: t; -*-

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

;; ERT tests for the Logseq side of the two-way sync engine
;; (`logseq-org-sync-logseq.el').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'logseq-org-sync-logseq)

(defconst logseq-org-sync-logseq-test-dir
  (file-name-directory (expand-file-name (or load-file-name buffer-file-name)))
  "Directory containing this test file.")

(defconst logseq-org-sync-logseq-test-fixtures
  (expand-file-name "../fixtures/Work/logseq" logseq-org-sync-logseq-test-dir)
  "Root of the Phase 0 Logseq fixture graph.")

(defconst logseq-org-sync-logseq-test-journal
  (expand-file-name "journals/2026-09-30.org" logseq-org-sync-logseq-test-fixtures))

(defconst logseq-org-sync-logseq-test-meeting
  (expand-file-name "pages/Meeting Notes.org" logseq-org-sync-logseq-test-fixtures))

(defconst logseq-org-sync-logseq-test-project
  (expand-file-name "pages/Project Alpha.org" logseq-org-sync-logseq-test-fixtures))

(ert-deftest logseq-org-sync-logseq--scan ()
  (should (equal (logseq-org-sync-logseq-scan logseq-org-sync-logseq-test-fixtures)
                 (list logseq-org-sync-logseq-test-journal
                       logseq-org-sync-logseq-test-meeting
                       logseq-org-sync-logseq-test-project))))

(ert-deftest logseq-org-sync-logseq--parse-project-alpha ()
  (should (equal
           (logseq-org-sync-logseq-parse-file logseq-org-sync-logseq-test-project)
           '(:title "Project Alpha"
             :id "10000000-0000-0000-0000-000000000001"
             :aliases ("Alpha" "ProjA")
             :content ((:level 1 :todo "TODO" :text "Draft the proposal"
                        :children ((:level 2 :text "Share with [[Meeting Notes]]")))
                       (:level 1 :todo "DONE" :text "Ship the first milestone"))
             :links ((fuzzy "Meeting Notes" nil))))))

(ert-deftest logseq-org-sync-logseq--parse-meeting-notes ()
  (should (equal
           (logseq-org-sync-logseq-parse-file logseq-org-sync-logseq-test-meeting)
           '(:title "Meeting Notes"
             :id "10000000-0000-0000-0000-000000000002"
             :aliases ("Notes")
             :content ((:level 1 :text "Summarize decisions from [[Project Alpha]]"
                        :children ((:level 2 :text "Follow up on action items"))))
             :links ((fuzzy "Project Alpha" nil))))))

(ert-deftest logseq-org-sync-logseq--parse-journal ()
  (should (equal
           (logseq-org-sync-logseq-parse-file logseq-org-sync-logseq-test-journal)
           '(:title "2026-09-30"
             :id "10000000-0000-0000-0000-000000000003"
             :content ((:level 1 :text "Review [[Project Alpha]] proposal"
                        :children ((:level 2 :todo "TODO" :text "Send feedback"))))
             :links ((fuzzy "Project Alpha" nil))))))

(ert-deftest logseq-org-sync-logseq--block-properties-round-trip ()
  (let ((text "* TODO Draft :proj:work:
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
                     (logseq-org-sync-logseq-format
                      (logseq-org-sync-logseq-parse-buffer "X")))))))

(ert-deftest logseq-org-sync-logseq--planning-round-trip ()
  (let ((text "* TODO Do the thing
SCHEDULED: <2026-10-01 Thu>
** Child
"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (should (equal text
                     (logseq-org-sync-logseq-format
                      (logseq-org-sync-logseq-parse-buffer "X")))))))

(ert-deftest logseq-org-sync-logseq--round-trip ()
  (dolist (file (logseq-org-sync-logseq-scan logseq-org-sync-logseq-test-fixtures))
    (let ((expected (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
      (should (equal expected
                     (logseq-org-sync-logseq-format
                      (logseq-org-sync-logseq-parse-file file)))))))

(ert-deftest logseq-org-sync-logseq--page-tags ()
  (let ((text "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n#+tags: a, b\n#+filetags: :b:c:\n\n* One\n"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (let ((node (logseq-org-sync-logseq-parse-buffer "X")))
        (should (equal '("a" "b" "c") (plist-get node :tags)))
        (should-not (plist-member node :properties))))))

(ert-deftest logseq-org-sync-logseq--page-tags-round-trip ()
  (let ((node '(:title "X" :id "10000000-0000-0000-0000-000000000001"
                :aliases ("Alpha") :tags ("a" "b"))))
    (should (equal
             "#+id: 10000000-0000-0000-0000-000000000001\n#+alias: Alpha\n#+tags: a, b\n"
             (logseq-org-sync-logseq-format node)))))

(defconst logseq-org-sync-logseq-test-markdown-fixtures
  (expand-file-name "../fixtures/Work-markdown/logseq" logseq-org-sync-logseq-test-dir)
  "Root of the Phase 0 Markdown Logseq fixture graph.")

(defconst logseq-org-sync-logseq-test-markdown-journal
  (expand-file-name "journals/2026-09-30.md"
                    logseq-org-sync-logseq-test-markdown-fixtures))

(defconst logseq-org-sync-logseq-test-markdown-meeting
  (expand-file-name "pages/Meeting Notes.md"
                    logseq-org-sync-logseq-test-markdown-fixtures))

(defconst logseq-org-sync-logseq-test-markdown-project
  (expand-file-name "pages/Project Alpha.md"
                    logseq-org-sync-logseq-test-markdown-fixtures))

(ert-deftest logseq-org-sync-logseq--graph-format ()
  (should (eq 'org
              (logseq-org-sync-logseq-graph-format
               logseq-org-sync-logseq-test-fixtures)))
  (should (eq 'markdown
              (logseq-org-sync-logseq-graph-format
               logseq-org-sync-logseq-test-markdown-fixtures))))

(ert-deftest logseq-org-sync-logseq--scan-markdown ()
  (should (equal (logseq-org-sync-logseq-scan
                  logseq-org-sync-logseq-test-markdown-fixtures)
                 (list logseq-org-sync-logseq-test-markdown-journal
                       logseq-org-sync-logseq-test-markdown-meeting
                       logseq-org-sync-logseq-test-markdown-project))))

(ert-deftest logseq-org-sync-logseq--parse-markdown-project-alpha ()
  (should (equal
           (logseq-org-sync-logseq-parse-file
            logseq-org-sync-logseq-test-markdown-project)
           '(:title "Project Alpha"
             :id "10000000-0000-0000-0000-000000000001"
             :aliases ("Alpha" "ProjA")
             :content ((:level 1 :todo "TODO" :text "Draft the proposal"
                        :children ((:level 2 :text "Share with [[Meeting Notes]]")))
                       (:level 1 :todo "DONE" :text "Ship the first milestone"))
             :links ((fuzzy "Meeting Notes" nil))))))

(ert-deftest logseq-org-sync-logseq--parse-markdown-meeting-notes ()
  (should (equal
           (logseq-org-sync-logseq-parse-file
            logseq-org-sync-logseq-test-markdown-meeting)
           '(:title "Meeting Notes"
             :id "10000000-0000-0000-0000-000000000002"
             :aliases ("Notes")
             :content ((:level 1 :text "Summarize decisions from [[Project Alpha]]"
                        :children ((:level 2 :text "Follow up on action items"))))
             :links ((fuzzy "Project Alpha" nil))))))

(ert-deftest logseq-org-sync-logseq--parse-markdown-journal ()
  (should (equal
           (logseq-org-sync-logseq-parse-file
            logseq-org-sync-logseq-test-markdown-journal)
           '(:title "2026-09-30"
             :id "10000000-0000-0000-0000-000000000003"
             :content ((:level 1 :text "Review [[Project Alpha]] proposal"
                        :children ((:level 2 :todo "TODO" :text "Send feedback"))))
             :links ((fuzzy "Project Alpha" nil))))))

(ert-deftest logseq-org-sync-logseq--markdown-round-trip ()
  (dolist (file (logseq-org-sync-logseq-scan
                 logseq-org-sync-logseq-test-markdown-fixtures))
    (let ((expected (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
      (should (equal expected
                     (logseq-org-sync-logseq-markdown-format
                      (logseq-org-sync-logseq-parse-file file)))))))

(ert-deftest logseq-org-sync-logseq--markdown-heading-round-trip ()
  (let ((text "# Heading 1\ncollapsed:: true\n\t- ## Heading 2\n\t\t- ### Heading 3\n"))
    (with-temp-buffer
      (insert text)
      (let ((node (logseq-org-sync-logseq-markdown-parse-buffer "Page")))
        (should (equal
                 '(:level 1 :text "Heading 1"
                   :properties (("heading" . "1") ("collapsed" . "true"))
                   :children ((:level 2 :text "Heading 2"
                               :properties (("heading" . "2"))
                               :children ((:level 3 :text "Heading 3"
                                           :properties (("heading" . "3")))))))
                 (car (plist-get node :content))))))))

(ert-deftest logseq-org-sync-logseq--markdown-multiple-children ()
  (let ((text "- Parent\n\t- Child A\n\t- Child B\n- Sibling\n"))
    (with-temp-buffer
      (insert text)
      (let ((node (logseq-org-sync-logseq-markdown-parse-buffer "Page")))
        (should (equal
                 '(:title "Page"
                   :content ((:level 1 :text "Parent"
                              :children ((:level 2 :text "Child A")
                                         (:level 2 :text "Child B")))
                             (:level 1 :text "Sibling")))
                 node))))))

(provide 'logseq-org-sync-logseq-test)
;;; logseq-org-sync-logseq-test.el ends here
