;;; logseq-org-sync-test.el --- Tests for the Phase 7 command layer -*- lexical-binding: t; -*-

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

;; ERT tests for the Phase 7 triggering layer (`logseq-org-sync.el').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'logseq-org-sync)

(defun logseq-org-sync-test--graph (tmp)
  "Return an org-format graph plist rooted in TMP."
  (let ((lroot (expand-file-name "logseq" tmp)))
    (make-directory (expand-file-name "logseq" lroot) t)
    (write-region "{:preferred-format \"Org\"}\n"
                  nil (expand-file-name "logseq/config.edn" lroot)))
  (list :name "work"
        :logseq-root (expand-file-name "logseq" tmp)
        :roam-root (expand-file-name "org-roam" tmp)
        :pages-directory "pages"
        :journals-directory "journals"
        :state-file (expand-file-name "state.plist" tmp)))

(ert-deftest logseq-org-sync--state-file-default ()
  (let ((logseq-org-sync-state-directory "/tmp/logseq-org-sync-test"))
    (should (equal (expand-file-name "work.plist" "/tmp/logseq-org-sync-test")
                   (logseq-org-sync--state-file '(:name "work"))))))

(ert-deftest logseq-org-sync--resolve ()
  (let ((logseq-org-sync-graphs
         (list '(:name "work" :logseq-root "/a" :roam-root "/b"))))
    (should (equal "pages"
                   (plist-get (logseq-org-sync--resolve "work")
                              :pages-directory)))
    (should (equal "journals"
                   (plist-get (logseq-org-sync--resolve 'work)
                              :journals-directory)))))

(ert-deftest logseq-org-sync--graph-for-file ()
  (let ((logseq-org-sync-graphs
         (list (list :name "work"
                     :logseq-root "/g/logseq"
                     :roam-root "/g/org-roam"
                     :pages-directory "pages"
                     :journals-directory "journals"))))
    (should (logseq-org-sync--graph-for-file "/g/logseq/pages/Foo.org"))
    (should (logseq-org-sync--graph-for-file
             "/g/org-roam/journals/2024-01-01.org"))
    (should-not (logseq-org-sync--graph-for-file "/g/logseq/config.edn"))
    (should-not (logseq-org-sync--graph-for-file "/elsewhere/Foo.org"))))

(ert-deftest logseq-org-sync--run-propagates ()
  (let* ((tmp (make-temp-file "logseq-org-sync-cmd-" t))
         (graph (logseq-org-sync-test--graph tmp))
         (lroot (plist-get graph :logseq-root))
         (rroot (plist-get graph :roam-root))
         (state-file (plist-get graph :state-file)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" lroot) t)
          (write-region "#+id: 10000000-0000-0000-0000-000000000001\n\n* One [[Two]]\n"
                        nil (expand-file-name "pages/One.org" lroot))
          (let ((state (logseq-org-sync-run graph)))
            (should (file-exists-p (expand-file-name "pages/One.org" rroot)))
            (should (file-exists-p state-file))
            (should (= 1 (length (plist-get state :nodes))))))
      (delete-directory tmp t))))

(provide 'logseq-org-sync-test)
;;; logseq-org-sync-test.el ends here
