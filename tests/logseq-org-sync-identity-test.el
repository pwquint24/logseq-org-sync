;;; logseq-org-sync-identity-test.el --- Tests for logseq-org-sync-identity -*- lexical-binding: t; -*-

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

;; ERT tests for node identity (`logseq-org-sync-identity.el').

;;; Code:

(require 'ert)
(require 'logseq-org-sync-identity)

(defconst logseq-org-sync-identity-test-uuid-regexp
  "\\`[0-9a-fA-F]\\{8\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{12\\}\\'"
  "Regexp matching a UUID, as produced by `org-id-new'.")

(ert-deftest logseq-org-sync-identity--new-is-uuid ()
  (should (string-match-p logseq-org-sync-identity-test-uuid-regexp
                          (logseq-org-sync-identity-new))))

(ert-deftest logseq-org-sync-identity--ensure-preserves-existing ()
  (let ((node '(:title "Foo" :id "10000000-0000-0000-0000-000000000001")))
    (should (equal node (logseq-org-sync-identity-ensure-node node)))))

(ert-deftest logseq-org-sync-identity--ensure-assigns ()
  (let* ((node (logseq-org-sync-identity-ensure-node '(:title "Foo")))
         (id (plist-get node :id)))
    (should (stringp id))
    (should (string-match-p logseq-org-sync-identity-test-uuid-regexp id))
    (should (equal "Foo" (plist-get node :title)))))

(provide 'logseq-org-sync-identity-test)
;;; logseq-org-sync-identity-test.el ends here
