;;; logseq-org-sync-state-test.el --- Tests for logseq-org-sync-state -*- lexical-binding: t; -*-

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

;; ERT tests for the sync state store (`logseq-org-sync-state.el').

;;; Code:

(require 'ert)
(require 'logseq-org-sync-state)

(defconst logseq-org-sync-state-test-record
  '(:id "10000000-0000-0000-0000-000000000001"
        :title "Project Alpha"
        :roam-path "pages/Project Alpha.org"
        :logseq-path "pages/Project Alpha.org"
        :roam-hash "aaaaaaaa"
        :logseq-hash "bbbbbbbb"
        :roam-mtime (12345 0)
        :logseq-mtime (12346 0)
        :last-sync (12347 0))
  "A sample state record.")

(ert-deftest logseq-org-sync-state--empty ()
  (should (equal (logseq-org-sync-state-empty)
                 '(:version 1 :nodes nil))))

(ert-deftest logseq-org-sync-state--put-get ()
  (let ((state (logseq-org-sync-state-put
                (logseq-org-sync-state-empty)
                logseq-org-sync-state-test-record)))
    (should (equal (logseq-org-sync-state-get state "10000000-0000-0000-0000-000000000001")
                   logseq-org-sync-state-test-record))))

(ert-deftest logseq-org-sync-state--put-replaces ()
  (let* ((other (plist-put logseq-org-sync-state-test-record
                           :title "Renamed"))
         (state (logseq-org-sync-state-put
                 (logseq-org-sync-state-put
                  (logseq-org-sync-state-empty)
                  logseq-org-sync-state-test-record)
                 other)))
    (should (equal (logseq-org-sync-state-get state "10000000-0000-0000-0000-000000000001")
                   other))
    (should (equal (length (plist-get state :nodes)) 1))))

(ert-deftest logseq-org-sync-state--remove ()
  (let ((state (logseq-org-sync-state-remove
                (logseq-org-sync-state-put
                 (logseq-org-sync-state-empty)
                 logseq-org-sync-state-test-record)
                "10000000-0000-0000-0000-000000000001")))
    (should (null (logseq-org-sync-state-get state "10000000-0000-0000-0000-000000000001")))))

(ert-deftest logseq-org-sync-state--save-load-round-trip ()
  (let ((state (logseq-org-sync-state-put
                (logseq-org-sync-state-empty)
                logseq-org-sync-state-test-record))
        (file (make-temp-file "logseq-org-sync-state-" nil ".el")))
    (unwind-protect
        (progn
          (logseq-org-sync-state-save state file)
          (should (equal state (logseq-org-sync-state-load file))))
      (delete-file file))))

(ert-deftest logseq-org-sync-state--load-missing ()
  (should (equal (logseq-org-sync-state-empty)
                 (logseq-org-sync-state-load
                  (make-temp-name "logseq-org-sync-state-missing-")))))

(provide 'logseq-org-sync-state-test)
;;; logseq-org-sync-state-test.el ends here
