;;; logseq-org-roam-core.el --- Core definitions for logseq-org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2024, Sylvain Bougerel

;; Author: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; Maintainer: Sylvain Bougerel <sylvain.bougerel.devel@gmail.com>
;; URL: https://github.com/sbougerel/logseq-org-roam/
;; Keywords: tools outlines
;; Package-Requires: ((org-roam "2.2.2") (emacs "27.2") (org "9.3"))

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

;; Shared customization options, constants, macros, and small helpers for the
;; `logseq-org-roam' package.  This module is extracted from the original
;; monolithic `logseq-org-roam.el' (Phase 1 of the two-way sync project) and
;; preserves every public and internal symbol unchanged.

;;; Code:
(require 'org)
(require 'org-roam)
(require 'image) ;; for `image-type-file-name-regexps' & `image-type-available-p'

(defgroup logseq-org-roam nil
  "Convert Logseq files to `org-roam' files."
  :group 'org-roam)

;;;###autoload (put 'logseq-org-roam-link-types 'safe-local-variable #'symbolp)
(defcustom logseq-org-roam-link-types nil
  "The kind of links `logseq-org-roam' should convert.
Value is a symbol, only the following are recognized:
- \\='files
- \\='fuzzy
- nil (default, if unrecognized)

You should customize this value based on your
\":org-mode/insert-file-link?\" setting in Logseq.  Values other
than nil save some processing time.

Links considered as candidates to be converted to `org-roam'
ID links are of 2 types:

- File links such as:
  [[file:path/to/pages/page.org][DESCRIPTION]].
- Fuzzy links such as [[TITLE-OR-ALIAS][DESCRIPTION]].


Matching rules for each kind of links are as follows.

When dealing with file links, `logseq-org-roam' ignores links
that do not contain a description since Logseq always populates
it when referencing another page.  It also ignores links that
contain search options since Logseq does not create those.  And
finally it discards any links that is not a link to an `org-roam'
file (since these are not convertible to ID links).

When dealing with fuzzy links, it first ignores dedicated internal
link formats that have specific meaning in `org-mode' (even if
they are broken):

- [[#custom-id]] links,
- [[*heading]] links,
- [[(coderef)]] links,
- [[image.jpg]] inline links to images,

Of the remaining fuzzy links, it discards links that match
internally (as per `org-mode' rules) with:

- <<targets>> or,
- #+name: named elements or,
- a headline by text search,

The leftover links are the candidates to be converted to
`org-roam' external ID links.


Notes on using file links in Logseq.

It is usually recommended to set \":org-mode/insert-file-link?\"
to true in Logseq, presumably to ensure the correct target is
being pointed to.

Unfortunately, Logseq does not always provide a correct path (as
of version 0.10.3) on platforms tested (Android, Linux). As of
version 0.10.3, when a note does not exist yet (or when it is
aliased, see `https://github.com/logseq/logseq/issues/9342'), the
path provided by Logseq is incorrect.  (TODO: test in newer
versions.)

On the other hand `logseq-org-roam' cares to implement the
complex matching rules set by `org-roam' to convert the right
fuzzy links, making Logseq and `org-roam' mostly interoperable
even when using fuzzy links in Logseq."
  :type 'symbol
  :options '(fuzzy file both)
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-pages-directory 'safe-local-variable #'string)
(defcustom logseq-org-roam-pages-directory "pages"
  "Set this variable to mirror Logseq :pages-directory setting."
  :type 'string
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-journals-directory 'safe-local-variable #'string)
(defcustom logseq-org-roam-journals-directory "journals"
  "Set this variable to mirror Logseq :journals-directory setting."
  :type 'string
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-journals-file-name-format 'safe-local-variable #'string)
(defcustom logseq-org-roam-journals-file-name-format "%Y-%m-%d"
  "Set this variable to mirror Logseq :journal/file-name-format setting.
You should pick a format that `logseq-org-roam-maybe-date-func'
can use.  Otherwise, titles for journal entries will not be
formated correctly: `logseq-org-roam' first parses the file name
into a time before feeding it back to `format-time-string' to
create the title (See: `logseq-org-roam-jounals-title-format')."
  :type 'string
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-journals-title-format 'safe-local-variable #'string)
(defcustom logseq-org-roam-journals-title-format "%Y-%m-%d"
  "Set this variable to mirror Logseq :journal/file-name-format setting.
This is used to create a title for journal entires and to find
out which fuzzy links point to journal entries (See
`logseq-org-roam-maybe-date-func').

You can set this to any format that `format-time-string' accepts.
However, you should only use it to create date strings, and not
time strings.  Having hours and seconds in the format will
make it impossible to find out journal entries from fuzzy links."
  :type 'string
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-maybe-date-func 'safe-local-variable #'symbolp)
(defcustom logseq-org-roam-maybe-date-func
  #'logseq-org-roam-maybe-date-default
  "Try parsing a string into a date and return time when successful.
When non-nil, this variable is called with `funcall'.  It is
given 2 arguments: the first is a time format for
`format-time-string', the second is the string to evaluate.  It
is expected to return a time, like `date-to-time' or
`encode-time'.  If the time returned is 0, it assumes that the
string is not a date.  See `logseq-org-roam-maybe-date-default'
for a description of the default behaviour.

If nil, date parsing is disabled."
  :type 'string
  :group 'logseq-org-roam)

(defcustom logseq-org-roam-create-replace '(("[\\/]" . "_"))
  "Alist specifying replacements for fuzzy links.
Car and cdr of each cons will be given as arguments to
`replace-regexp-in-string' when converting fuzzy links to paths
in `logseq-org-roam-create-translate-default'."
  :type 'alist
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-create-translate-func 'safe-local-variable #'symbolp)
(defcustom logseq-org-roam-create-translate-func
  #'logseq-org-roam-create-translate-default
  "Function translating a fuzzy link to a file path.
When non-nil, it is called with `funcall' and a single argument,
the fuzzy link.  It is expected to return an absolute file path.
This variable provide complete control over how fuzzy links are
translated to file paths.

Default to `logseq-org-roam-create-translate-default'.  Setting
this value to nil disables creation of pages for fuzzy links."
  :type 'symbol
  :group 'logseq-org-roam)

;;;###autoload (put 'logseq-org-roam-create-accept-func 'safe-local-variable #'symbol)
(defcustom logseq-org-roam-create-accept-func #'logseq-org-roam-pages-p
  "Tells aparts paths that should be created from paths that should not.
When non-nil, it is called as a function with a single argument:
the path.  When the return value is non-nil, the path is accepted
and the file is created.

The default value (`logseq-org-roam-pages-p') will not create
journal entires.  If you want journal entries to be created too,
you can set this to `logseq-org-roam-logseq-p'.  If you want to
allow files to be created anywhere, you can set this to `always'.

When set to nil, file creation is disabled."
  :type 'symbol
  :group 'logseq-org-roam)

;;;###autoload
(defcustom logseq-org-roam-updated-hook nil
  "Hook called  by `logseq-org-roam' if any files was updated."
  :type 'hook
  :group 'logseq-org-roam)

(defconst logseq-org-roam--named
  '(babel-call
    center-block
    dynamic-block
    example-block
    export-block
    fixed-width
    footnote-definition
    horizontal-rule
    latex-environment
    paragraph
    plain-list
    quote-block
    special-block
    src-block
    table
    verse-block)
  "List of org-elements that can be affiliated with a :name attribute.")

(defconst logseq-org-roam--log-buffer-name "*Logseq Org-roam %s*"
  "Name for the log buffer.
'%s' will be replaced by `org-roam-directory' if present")

(defmacro logseq-org-roam--with-log-buffer (&rest body)
  "Bind standard output to a dedicated buffer for the duration of BODY."
  (declare (debug t))
  `(let* ((standard-output
           (with-current-buffer
               (get-buffer-create
                ;; One buffer per org-roam-directory
                (format logseq-org-roam--log-buffer-name
                        org-roam-directory))
             (kill-all-local-variables) ;; return to fundamental for logging
             (setq default-directory org-roam-directory)
             (setq buffer-read-only nil)
             (setq buffer-file-name nil)
             (setq buffer-undo-list t)
             (goto-char (point-max))
             (if (/= (point-min) (point-max))
                 (insert "\n\n"))
             (current-buffer))))
     (prog1 (progn ,@body)
       (with-current-buffer standard-output
         (goto-char (point-max))
         (insert "You can set this buffer to `org-mode' to navigate links\n")
         (setq buffer-read-only t)))))

(defmacro logseq-org-roam--with-edit-buffer (file &rest body)
  "Find an existing buffer for FILE, set `org-mode' and execute BODY.
If the buffer is new, `org-mode' startup is inhibited.  This
macro does not save the file, but will *always* kill the buffer
if it was previously created."
  (declare (indent 1) (debug t))
  (let ((exist-buf (make-symbol "exist-buf"))
        (buf (make-symbol "buf"))
        (bimf (make-symbol "bimf"))
        (biro (make-symbol "biro")))
    `(let* ((,bimf inhibit-modification-hooks)
            (,biro inhibit-read-only)
            (,exist-buf (find-buffer-visiting ,file))
            (,buf
             (or ,exist-buf
                 (let ((auto-mode-alist nil)
                       (find-file-hook nil))
                   (find-file-noselect ,file)))))
       (unwind-protect
           (with-current-buffer ,buf
             (setq inhibit-read-only t)
             (setq inhibit-modification-hooks (if ,exist-buf t ,bimf))
             (unless (derived-mode-p 'org-mode)
               (let ((org-inhibit-startup t)) (org-mode)))
             ,@body)
         (setq inhibit-modification-hooks ,bimf)
         (setq inhibit-read-only ,biro)
         (unless ,exist-buf (kill-buffer ,buf))))))

(defmacro logseq-org-roam--with-temp-buffer (file &rest body)
  "Visit FILE into an `org-mode' temp buffer and execute BODY.
If the buffer is new, `org-mode' startup is inhibited.  This
macro does not save the file, but will kill the buffer if it was
previously created."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     ;; relative path expansion needs this
     (setq default-directory (file-name-directory ,file))
     (delay-mode-hooks
       (let ((org-inhibit-startup t)) (org-mode)))
     (insert-file-contents ,file)
     ,@body))

(defmacro logseq-org-roam--catch-fun (sym errs fun &rest body)
  "Catch ERRS for SYM during BODY's execution and pass it to FUN."
  (declare (indent 3) (debug t))
  (let ((result (make-symbol "result")))
    `(let ((,result (catch ,sym ,@body)))
       (if (and ,result
                (symbolp ,result)
                (memq ,result ,errs))
           (apply ,fun (list ,result))))))

(defun logseq-org-roam--fl (file)
  "Make an org link to FILE relative to `org-roam-directory'."
  (format "[[file:%s][%s]]"
          file
          (file-relative-name file org-roam-directory)))

(defun logseq-org-roam-pages-p (file)
  "Return non-nil if FILE path is under the Logseq pages directory."
  (string= (directory-file-name (file-name-directory file))
           (expand-file-name logseq-org-roam-pages-directory
                             org-roam-directory)))

(defun logseq-org-roam-journals-p (file)
  "Return non-nil if FILE path is under the Logseq journal directory."
  (string= (directory-file-name (file-name-directory file))
           (expand-file-name logseq-org-roam-journals-directory
                             org-roam-directory)))

(defun logseq-org-roam-logseq-p (file)
  "Return non-nil if FILE path is under the Logseq journal or pages directory."
  (or (logseq-org-roam-pages-p file)
      (logseq-org-roam-journals-p file)))

(defun logseq-org-roam--image-file-p (file)
  "Non-nil if FILE is a supported image type."
  ;; This function exists purely because `image-supported-file-p' has made
  ;; `image-type-from-file-name' obsolete since Emacs 29.1; while it is not
  ;; supported by `compat'.  So `image-type-available-p' is just copied here
  ;;
  ;; The function below is a copy from `image.el' distributed with Emacs version
  ;; 29.1.  Copyright (C) 1998-2023 Free Software Foundation, Inc.
  (let ((case-fold-search t)
        type)
    (catch 'found
      (dolist (elem image-type-file-name-regexps)
        (if (and (string-match-p (car elem) file)
                 (image-type-available-p (setq type (cdr elem))))
            (throw 'found type))))))

(defun logseq-org-roam--value-string-p (element)
  "Return non-nil if ELEMENT has a string value that is not empty."
  (and (org-element-property :value element)
       (not (string-empty-p (org-element-property :value element)))))

(defun logseq-org-roam-maybe-date-default (date-format maybe-date)
  "When MAYBE-DATE match DATE-FORMAT, turn it into a time value.
Attempts to parse MAYBE-DATE with `parse-time-string' first and
convert it back to a string with `format-time-string' using
DATE-FORMAT.  If both string match, it is taken as a journal
date, and the corresponding time is returned."
  ;; TODO: Compile a reverse regex to format-time-string?
  ;; NOTE: hack because '_' are not ISO date chars
  (let* ((hacked-date (replace-regexp-in-string "_" "-" maybe-date))
         (parsed (parse-time-string hacked-date))
         (year (nth 5 parsed))
         (month (nth 4 parsed))
         (day (nth 3 parsed))
         (time (encode-time `(0 0 0 ,day ,month ,year nil -1 nil))))
    (if (and year month day
             (string= (format-time-string date-format time)
                      maybe-date))
        time
      0)))

(defalias 'logseq-org-roam--normalize-text (symbol-function #'downcase)
  "Return a normalized version of TEXT.")
;; Maintain optimizations
(put 'logseq-org-roam--normalize-text 'side-effect-free t)
(put 'logseq-org-roam--normalize-text 'byte-compile 'byte-compile-one-arg)
(put 'logseq-org-roam--normalize-text 'byte-opcode 'byte-downcase)

(defun logseq-org-roam--normalize-path (path)
  "Return a new PATH that is normalized.
The file base portion of path will be downcased, and lowbar
repetitions will be removed.  This helps with mapping
\"triple-lowbar\" setting in Logseq to file slug created by
`org-roam'."
  (let ((dir (file-name-directory path))
        (ext (file-name-extension path))
        (base (file-name-base path)))
    (concat dir
            (replace-regexp-in-string "_+" "_" (downcase base))
            "." ext)))

(provide 'logseq-org-roam-core)
;;; logseq-org-roam-core.el ends here
