;;; logseq-org-sync.el --- Interactive two-way sync command -*- lexical-binding: t; -*-

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

;; The triggering/command layer for the two-way sync engine (Phase 7,
;; AGENTS.md §10).  It ties the Phase 5 reconciler and Phase 6 safety layer
;; together into the pieces a user actually invokes:
;;
;; - `logseq-org-sync'       — interactive command, one graph at a time.
;; - `logseq-org-sync-here'  — sync the graph containing the current buffer.
;; - `logseq-org-sync-dry-run' — interactive preview, no writes.
;; - `logseq-org-sync-run'   — non-interactive sync (used by the hooks below).
;; - `logseq-org-sync-all'   — non-interactive sync of every configured graph.
;; - `logseq-org-sync-rebuild-state' — delete and rebuild a graph's cache.
;; - `logseq-org-sync-add-graph' / `logseq-org-sync-remove-graph' — manage
;;   the `logseq-org-sync-graphs' list.
;; - `logseq-org-sync-after-save' — an `after-save-hook' function.
;; - `logseq-org-sync-watch' / `logseq-org-sync-unwatch' — file-notify
;;   watchers for changes made outside Emacs (e.g. by the Logseq app).
;;
;; ## Graph configuration
;;
;; Graphs are declared in `logseq-org-sync-graphs' (AGENTS.md §2).  Each entry
;; is a plist:
;;
;;     (:name "Work"
;;      :logseq-root "~/graphs/Work")
;;
;; `:roam-root' defaults to `<logseq-org-sync-roam-directory>/<name>'
;; (`logseq-org-sync-roam-directory' defaults to `org-roam-directory' when
;; org-roam is loaded), so adding a graph only requires picking its Logseq
;; folder — the mirror subdirectory is derived automatically.
;;
;; Optional keys are `:roam-root', `:pages-directory' (default "pages"),
;; `:journals-directory' (default "journals"), and `:state-file' (default
;; `<logseq-org-sync-state-directory>/<name>.plist').
;;
;; ## Automatic sync
;;
;; Add the save hook to a mode hook (or globally):
;;
;;     (add-hook 'after-save-hook #'logseq-org-sync-after-save)
;;
;; For changes that arrive from outside Emacs (the Logseq app writing `.org'
;; files, for example), start a watcher:
;;
;;     (logseq-org-sync-watch)   ; choose a graph, or pass a graph plist
;;
;; Both automatic paths use `logseq-org-sync-run', which forces the
;; newest-wins conflict policy so they never prompt.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'logseq-org-sync-reconcile)
(require 'logseq-org-sync-safety)
(require 'logseq-org-sync-state)

(defgroup logseq-org-sync-command nil
  "Interactive and automatic triggering for the logseq/org-roam sync."
  :group 'logseq-org-sync
  :prefix "logseq-org-sync-")

(defcustom logseq-org-sync-graphs nil
  "Configured Logseq/org-roam graphs for `logseq-org-sync'.
Each entry is a plist with these keys:

  :name               string; unique identifier for the graph.
  :logseq-root        directory of the native Logseq graph.
  :roam-root          optional; org-roam mirror directory.
  :pages-directory    optional; subtree name (default \"pages\").
  :journals-directory optional; subtree name (default \"journals\").
  :state-file         optional; path to this graph's metadata store.

`:roam-root' defaults to `<logseq-org-sync-roam-directory>/<name>', so a
graph added with `logseq-org-sync-add-graph' only needs `:name' and
`:logseq-root'.  When `:state-file' is omitted, it defaults to a file
named after the graph under `logseq-org-sync-state-directory'."
  :type '(repeat
          (plist :key-type symbol
                 :value-type string
                 :options ((:name)
                           (:logseq-root)
                           (:roam-root)
                           (:pages-directory)
                           (:journals-directory)
                           (:state-file))))
  :group 'logseq-org-sync-command)

(defcustom logseq-org-sync-roam-directory
  (or (and (boundp 'org-roam-directory) org-roam-directory)
      (expand-file-name "org-roam" user-emacs-directory))
  "Parent directory holding one mirror subdirectory per Logseq graph.
A graph's `:roam-root' defaults to
`<logseq-org-sync-roam-directory>/<graph name>'.  This defaults to
`org-roam-directory' when org-roam is loaded, so the mirrors live inside
the org-roam directory."
  :type 'directory
  :group 'logseq-org-sync-command)

(defcustom logseq-org-sync-state-directory
  (expand-file-name "logseq-org-sync" user-emacs-directory)
  "Directory for per-graph state files without an explicit `:state-file'."
  :type 'directory
  :group 'logseq-org-sync-command)

(defcustom logseq-org-sync-watch-delay 2.0
  "Seconds to debounce file-notify events before re-syncing a graph."
  :type 'number
  :group 'logseq-org-sync-command)

(defvar logseq-org-sync--watch-descriptors nil
  "Alist of (GRAPH-NAME . DESCRIPTORS) for active file-notify watchers.")

(defvar logseq-org-sync--watch-timers nil
  "Alist of (GRAPH-NAME . TIMER) for debounced file-notify syncs.")

;;; Graph lookup & normalization

(defun logseq-org-sync--find-graph (name)
  "Return the configured graph named NAME, or nil."
  (cl-find name logseq-org-sync-graphs
           :test (lambda (n graph) (equal n (plist-get graph :name)))))

(defun logseq-org-sync--roam-root-for (graph)
  "Return GRAPH's org-roam mirror directory, deriving it when absent.
The default is `<logseq-org-sync-roam-directory>/<graph name>'."
  (or (plist-get graph :roam-root)
      (expand-file-name (plist-get graph :name)
                        logseq-org-sync-roam-directory)))

(defun logseq-org-sync--graph-entry (logseq-root &optional name)
  "Return a graph plist for LOGSEQ-ROOT.
NAME defaults to LOGSEQ-ROOT's basename; `:roam-root' is left unset so
it stays derived from `logseq-org-sync-roam-directory'."
  (let ((root (expand-file-name logseq-root)))
    (list :name (or name
                    (file-name-nondirectory (directory-file-name root)))
          :logseq-root root)))

(defun logseq-org-sync--graph-add (graphs graph)
  "Return GRAPHS with GRAPH appended.
Errors when a graph with the same `:name' is already present."
  (let ((name (plist-get graph :name)))
    (when (cl-find name graphs
                   :test (lambda (n g) (equal n (plist-get g :name))))
      (error "A graph named %S is already configured" name))
    (append graphs (list graph))))

(defun logseq-org-sync--graph-remove (graphs name)
  "Return GRAPHS without the graph named NAME."
  (cl-remove-if (lambda (graph) (equal name (plist-get graph :name)))
                graphs))

(defun logseq-org-sync--normalize-graph (graph)
  "Return GRAPH with optional directory keys defaulted.
`:roam-root' is derived from `logseq-org-sync-roam-directory' when
absent, so a configured graph only needs `:name' and `:logseq-root'."
  (let ((graph (copy-sequence graph)))
    (unless (plist-get graph :pages-directory)
      (setq graph (plist-put graph :pages-directory "pages")))
    (unless (plist-get graph :journals-directory)
      (setq graph (plist-put graph :journals-directory "journals")))
    (unless (plist-get graph :roam-root)
      (setq graph (plist-put graph :roam-root
                             (logseq-org-sync--roam-root-for graph))))
    graph))

(defun logseq-org-sync--resolve (graph)
  "Resolve GRAPH to a normalized graph plist.
GRAPH may be a graph plist, or a string/symbol naming a configured graph."
  (cond
   ((and (listp graph) (plist-get graph :name))
    (logseq-org-sync--normalize-graph graph))
   ((or (stringp graph) (symbolp graph))
    (let* ((name (if (symbolp graph) (symbol-name graph) graph))
           (found (logseq-org-sync--find-graph name)))
      (or (and found (logseq-org-sync--normalize-graph found))
          (error "No configured graph named %S" name))))
   (t (error "Invalid graph specification: %S" graph))))

(defun logseq-org-sync--read-graph ()
  "Read a graph name from `logseq-org-sync-graphs'."
  (if logseq-org-sync-graphs
      (completing-read "Graph: "
                       (mapcar (lambda (graph) (plist-get graph :name))
                               logseq-org-sync-graphs)
                       nil t)
    (read-string "Graph name: ")))

;;; State persistence

(defun logseq-org-sync--state-file (graph)
  "Return GRAPH's state-store file path."
  (or (plist-get graph :state-file)
      (expand-file-name
       (format "%s.plist"
               (string-replace "/" "_"
                               (format "%s" (plist-get graph :name))))
       logseq-org-sync-state-directory)))

(defun logseq-org-sync--load-state (graph)
  "Return GRAPH's persisted sync state, or an empty state."
  (logseq-org-sync-state-load (logseq-org-sync--state-file graph)))

(defun logseq-org-sync--save-state (graph state)
  "Save STATE for GRAPH and return it."
  (let ((file (logseq-org-sync--state-file graph)))
    (make-directory (file-name-directory file) t)
    (logseq-org-sync-state-save state file)
    state))

(defun logseq-org-sync--apply-and-save (graph state)
  "Plan, safely apply, and persist STATE for GRAPH.
Returns the updated state."
  (logseq-org-sync--save-state
   graph
   (logseq-org-sync-safety-plan-and-apply graph state)))

;;; Command entry points

;;;###autoload
(defun logseq-org-sync-run (graph)
  "Run a non-interactive sync of GRAPH.
GRAPH is a graph plist or the name of a configured graph.  Conflict
resolution is forced to `newest-wins' so this never prompts; the state
store is updated and returned."
  (setq graph (logseq-org-sync--resolve graph))
  (let ((logseq-org-sync-reconcile-conflict-policy 'newest-wins))
    (logseq-org-sync--apply-and-save
     graph (logseq-org-sync--load-state graph))))

;;;###autoload
(defun logseq-org-sync-dry-run (graph)
  "Preview the sync of GRAPH without changing anything.
Interactively, GRAPH is chosen from `logseq-org-sync-graphs'."
  (interactive (list (logseq-org-sync--read-graph)))
  (setq graph (logseq-org-sync--resolve graph))
  (let ((state (logseq-org-sync--load-state graph)))
    (message "%s" (logseq-org-sync-safety-dry-run-text graph state))))

(defun logseq-org-sync--sync-interactive (graph)
  "Run an interactive preview/confirm sync of resolved GRAPH."
  (let* ((state (logseq-org-sync--load-state graph))
         (plan (logseq-org-sync-reconcile-plan graph state)))
    (if (null plan)
        (message "Logseq/org-roam sync: nothing to do for %S."
                 (plist-get graph :name))
      (message "%s" (logseq-org-sync-safety-dry-run-text graph state))
      (when (y-or-n-p "Apply this sync? ")
        (logseq-org-sync--apply-and-save graph state)
        (message "Logseq/org-roam sync of %S complete."
                 (plist-get graph :name))))))

;;;###autoload
(defun logseq-org-sync (graph)
  "Synchronize GRAPH between its Logseq and org-roam sides.
Shows a dry-run preview and asks for confirmation before applying.
Interactively, GRAPH is chosen from `logseq-org-sync-graphs'."
  (interactive (list (logseq-org-sync--read-graph)))
  (logseq-org-sync--sync-interactive (logseq-org-sync--resolve graph)))

;;;###autoload
(defun logseq-org-sync-here ()
  "Synchronize the graph containing the current buffer's file.
The buffer may visit a note under either the Logseq side or the
org-roam side of a configured graph.  Shows a dry-run preview and asks
for confirmation before applying."
  (interactive)
  (if-let* ((file buffer-file-name)
            (graph (logseq-org-sync--graph-for-file file)))
      (logseq-org-sync--sync-interactive graph)
    (message "Current buffer is not under a configured Logseq/org-roam graph")))

;;;###autoload
(defun logseq-org-sync-add-graph (&optional logseq-root name)
  "Add a Logseq graph to `logseq-org-sync-graphs'.
Interactively, LOGSEQ-ROOT is read with `read-directory-name'.  NAME
defaults to LOGSEQ-ROOT's basename and the org-roam mirror to
`<logseq-org-sync-roam-directory>/<name>'; both are created/derived
automatically.  The value is saved via Customize."
  (interactive (list (read-directory-name "Logseq graph folder: " nil nil t)))
  (let* ((root (expand-file-name logseq-root))
         (default-name (file-name-nondirectory (directory-file-name root)))
         (name (or name
                   (if (logseq-org-sync--find-graph default-name)
                       (read-string
                        (format "Graph name (default %S): " default-name)
                        nil nil default-name)
                     default-name)))
         (graph (logseq-org-sync--graph-entry root name))
         (roam-root (logseq-org-sync--roam-root-for graph))
         (format (logseq-org-sync-logseq-graph-format root)))
    (when (y-or-n-p
           (format "Add graph %S (%s) with org-roam mirror %S? "
                   name (or format 'unknown) roam-root))
      (make-directory roam-root t)
      (customize-save-variable
       'logseq-org-sync-graphs
       (logseq-org-sync--graph-add logseq-org-sync-graphs graph))
      (message "Added Logseq graph %S" name))))

;;;###autoload
(defun logseq-org-sync-remove-graph (&optional name)
  "Remove the graph named NAME from `logseq-org-sync-graphs'.
Files on both sides are left in place; the graph simply stops being
synced.  Active watchers for the graph are stopped."
  (interactive
   (list (when logseq-org-sync-graphs
           (completing-read
            "Remove graph: "
            (mapcar (lambda (graph) (plist-get graph :name))
                    logseq-org-sync-graphs)
            nil t))))
  (when name
    (when (y-or-n-p
           (format "Stop syncing graph %S (files are left in place)? " name))
      (logseq-org-sync-unwatch name)
      (customize-save-variable
       'logseq-org-sync-graphs
       (logseq-org-sync--graph-remove logseq-org-sync-graphs name))
      (message "Removed graph %S" name))))

;;;###autoload
(defun logseq-org-sync-all ()
  "Synchronize every graph in `logseq-org-sync-graphs'.
Each graph is synced with the newest-wins policy, so this never prompts."
  (interactive)
  (if (null logseq-org-sync-graphs)
      (message "No graphs configured; use `logseq-org-sync-add-graph'")
    (let ((count 0))
      (dolist (graph logseq-org-sync-graphs)
        (logseq-org-sync-run graph)
        (setq count (1+ count)))
      (message "Synced %d graph(s)" count))))

;;;###autoload
(defun logseq-org-sync-rebuild-state (graph)
  "Rebuild GRAPH's sync cache (the metadata state store) from disk.
Deletes the existing state file and re-seeds it with the current paths,
hashes, and mtimes of every node on both sides, treating the current
contents as the new baseline.  No note files are written.  Use this to
recover from a corrupted cache.  Interactively, GRAPH is chosen from
`logseq-org-sync-graphs'."
  (interactive (list (logseq-org-sync--read-graph)))
  (setq graph (logseq-org-sync--resolve graph))
  (let ((file (logseq-org-sync--state-file graph)))
    (when (file-exists-p file)
      (delete-file file)))
  (logseq-org-sync--save-state graph (logseq-org-sync-reconcile-seed graph))
  (message "Rebuilt sync cache for %S" (plist-get graph :name)))

;;; Automatic triggering

(defun logseq-org-sync--under-p (file root)
  "Return non-nil when FILE is under ROOT."
  (and file root
       (string-prefix-p
        (file-name-as-directory (expand-file-name root))
        (expand-file-name file))))

(defun logseq-org-sync--note-file-p (file graph)
  "Return non-nil when FILE is a note inside GRAPH's pages or journals."
  (let ((pages (or (plist-get graph :pages-directory) "pages"))
        (journals (or (plist-get graph :journals-directory) "journals"))
        (roots (list (plist-get graph :logseq-root)
                     (plist-get graph :roam-root))))
    (cl-some (lambda (root)
               (or (logseq-org-sync--under-p file (expand-file-name pages root))
                   (logseq-org-sync--under-p file (expand-file-name journals root))))
             roots)))

(defun logseq-org-sync--graph-for-file (file)
  "Return the configured graph containing note FILE, or nil."
  (cl-find-if (lambda (graph) (logseq-org-sync--note-file-p file graph))
              (mapcar #'logseq-org-sync--resolve logseq-org-sync-graphs)))

(defun logseq-org-sync-after-save ()
  "Sync the configured graph containing `buffer-file-name', if any.
This is intended for `after-save-hook' and is a no-op for files outside
a configured graph (e.g. `config.edn') or for buffers with no file."
  (when buffer-file-name
    (when-let* ((graph (logseq-org-sync--graph-for-file buffer-file-name)))
      (logseq-org-sync-run graph))))

;;; File-notify watchers

(defun logseq-org-sync--watch-handler (graph _event)
  "Debounced file-notify callback for GRAPH."
  (let ((name (plist-get graph :name)))
    (when-let* ((timer (cdr (assoc name logseq-org-sync--watch-timers))))
      (cancel-timer timer))
    (setf (alist-get name logseq-org-sync--watch-timers nil nil #'equal)
          (run-with-timer logseq-org-sync-watch-delay nil
                          (lambda () (logseq-org-sync-run graph))))))

;;;###autoload
(defun logseq-org-sync-watch (&optional graph)
  "Watch GRAPH's roots and re-sync after external changes.
Interactively, GRAPH is chosen from `logseq-org-sync-graphs'.  Events
are debounced by `logseq-org-sync-watch-delay'."
  (interactive (list (logseq-org-sync--read-graph)))
  (setq graph (logseq-org-sync--resolve graph))
  (let ((name (plist-get graph :name)))
    (unless (assoc name logseq-org-sync--watch-descriptors)
      (let ((descriptors nil))
        (dolist (root (list (plist-get graph :logseq-root)
                            (plist-get graph :roam-root)))
          (when (and root (file-directory-p root))
            (push (file-notify-add-watch
                   root '(change attribute-change)
                   (lambda (event)
                     (logseq-org-sync--watch-handler graph event)))
                  descriptors)))
        (push (cons name (nreverse descriptors))
              logseq-org-sync--watch-descriptors)))
    (message "Watching graph %S" name)))

;;;###autoload
(defun logseq-org-sync-unwatch (&optional graph)
  "Stop watching GRAPH, or all graphs when GRAPH is nil."
  (interactive (list (when logseq-org-sync--watch-descriptors
                       (logseq-org-sync--read-graph))))
  (let ((names (if graph
                   (list (plist-get (logseq-org-sync--resolve graph) :name))
                 (mapcar #'car logseq-org-sync--watch-descriptors))))
    (dolist (name names)
      (dolist (descriptor (cdr (assoc name logseq-org-sync--watch-descriptors)))
        (file-notify-rm-watch descriptor))
      (setq logseq-org-sync--watch-descriptors
            (assoc-delete-all name logseq-org-sync--watch-descriptors))
      (when-let* ((timer (cdr (assoc name logseq-org-sync--watch-timers))))
        (cancel-timer timer))
      (setq logseq-org-sync--watch-timers
            (assoc-delete-all name logseq-org-sync--watch-timers))))
  (message "Stopped watching"))

(provide 'logseq-org-sync)
;;; logseq-org-sync.el ends here
