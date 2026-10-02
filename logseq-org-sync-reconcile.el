;;; logseq-org-sync-reconcile.el --- Two-way reconciler -*- lexical-binding: t; -*-

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

;; The reconciler for the two-way sync engine (Phase 5, AGENTS.md §7).  It
;; reads both a Logseq graph and its org-roam mirror, classifies every node by
;; its shared UUID, and produces an ordered *plan* of actions that bring the
;; two sides into agreement.  A separate `apply' step executes the plan.
;;
;; Planning is a pure function of (graph, state): it reads files but never
;; writes them, so it can be reused verbatim for a dry-run preview (Phase 6,
;; `logseq-org-sync-safety').  Only `logseq-org-sync-reconcile-apply' mutates
;; the filesystem and the state store.
;;
;; ## Graph configuration
;;
;; A graph is a plist describing one Logseq/org-roam pair (AGENTS.md §2):
;;
;;     (:name "work"
;;      :logseq-root "~/graphs/Work"
;;      :roam-root   "/org-roam/Work"
;;      :pages-directory "pages"
;;      :journals-directory "journals")
;;
;; The two roots hold identically-named `pages/' and `journals/' subtrees, so a
;; node's path relative to its root is the same on both sides.
;;
;; ## Node tables
;;
;; Each side is read into a table keyed by UUID.  A table value is a plist:
;;
;;     (:id UUID :path RELATIVE :abs ABSOLUTE :node IR :hash SHA256
;;      :mtime MTIME :title TITLE)
;;
;; `:path' is relative to the graph root (so it is comparable across sides);
;; `:node' is the parsed IR (AGENTS.md §5); `:hash' is the SHA-256 of the file
;; contents and `:mtime' its modification time.
;;
;; ## Actions
;;
;; The plan is an ordered list of action plists.  Every action carries `:type'
;; plus a `:reason' (a symbol explaining the classification) and the data the
;; executor needs:
;;
;;     (:type create-roam   :id UUID :path REL :node IR :reason new)
;;     (:type create-logseq :id UUID :path REL :node IR :reason new)
;;     (:type update-roam   :id UUID :path REL :node IR :reason modified)
;;     (:type update-logseq :id UUID :path REL :node IR :reason modified)
;;     (:type seed          :id UUID :path REL :node IR :reason seed)
;;     (:type rename-roam   :id UUID :from REL :to REL :reason renamed)
;;     (:type rename-logseq :id UUID :from REL :to REL :reason renamed)
;;     (:type trash-roam    :id UUID :path REL :abs ABS :reason deleted)
;;     (:type trash-logseq  :id UUID :path REL :abs ABS :reason deleted)
;;
;; `:reason' is one of `new', `modified', `newest-wins', `renamed', `deleted',
;; or `conflict' (only used when the conflict policy is `prompt' and unresolved;
;; see Phase 6).
;;
;; ## Classification (AGENTS.md §7 step 3)
;;
;; For each UUID present on either side:
;;
;; - new on Logseq only  -> `create-roam'  (convert logseq -> roam)
;; - new on org-roam only -> `create-logseq' (convert roam -> logseq)
;; - modified on Logseq only -> `update-roam'
;; - modified on org-roam only -> `update-logseq'
;; - modified on both -> newest file wins (default) or prompt (opt-in)
;; - renamed (path changed, content identical, on both sides) -> `rename-*'
;; - deleted on one side, unchanged on the other -> `trash-*' on the other
;;
;; "Modified" is detected by comparing the file's SHA-256 against the hash the
;; state store recorded at the last sync (AGENTS.md §4).  A side with no state
;; record but a present file is treated as modified (it is new *to the engine*).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'logseq-org-sync-logseq)
(require 'logseq-org-sync-roam)
(require 'logseq-org-sync-identity)
(require 'logseq-org-sync-state)

(defconst logseq-org-sync-reconcile-trash-directory ".trash"
  "Subdirectory, under a graph root, that receives trashed files.
Deletions are moved here rather than hard-deleted (AGENTS.md §1.7).")

(defun logseq-org-sync-reconcile--graph-format (graph)
  "Return `org' or `markdown' for GRAPH's Logseq side."
  (logseq-org-sync-logseq-graph-format (plist-get graph :logseq-root)))

(defun logseq-org-sync-reconcile--markdown-p (graph)
  "Return non-nil when GRAPH's Logseq side uses Markdown files."
  (eq (logseq-org-sync-reconcile--graph-format graph) 'markdown))

(defun logseq-org-sync-reconcile--replace-extension (path from to)
  "Replace PATH's FROM extension with TO, or return PATH unchanged."
  (if (string-suffix-p from path)
      (concat (substring path 0 (- (length path) (length from))) to)
    path))

(defun logseq-org-sync-reconcile--roam-path (graph logseq-path)
  "Return the org-roam relative path corresponding to LOGSEQ-PATH.
GRAPH supplies the Logseq graph's format (see
`logseq-org-sync-reconcile--graph-format')."
  (if (logseq-org-sync-reconcile--markdown-p graph)
      (logseq-org-sync-reconcile--replace-extension logseq-path ".md" ".org")
    logseq-path))

(defun logseq-org-sync-reconcile--logseq-path (graph roam-path)
  "Return the Logseq relative path corresponding to ROAM-PATH.
GRAPH supplies the Logseq graph's format (see
`logseq-org-sync-reconcile--graph-format')."
  (if (logseq-org-sync-reconcile--markdown-p graph)
      (logseq-org-sync-reconcile--replace-extension roam-path ".org" ".md")
    roam-path))

(defgroup logseq-org-sync nil
  "Two-way sync between a Logseq graph and an org-roam directory."
  :group 'files
  :prefix "logseq-org-sync-")

(defcustom logseq-org-sync-reconcile-conflict-policy 'newest-wins
  "How to resolve a node modified on both sides.
- `newest-wins' (default): the file with the more recent modification
  time is propagated to the other side, without prompting (AGENTS.md §6).
- `prompt': ask the user which side to keep."
  :type '(choice (const :tag "Newest file wins" newest-wins)
                 (const :tag "Prompt on conflict" prompt))
  :group 'logseq-org-sync)

(defcustom logseq-org-sync-reconcile-prompt-function
  #'logseq-org-sync-reconcile--prompt-default
  "Function called to resolve a conflict when the policy is `prompt'.
It is called with the node's UUID and the two table entries (Logseq
first); it should return `logseq' or `roam'."
  :type 'function
  :group 'logseq-org-sync)

(defcustom logseq-org-sync-block-embed-prefix "#embed"
  "Description prefix marking an org-roam link as a Logseq block embed.
A `[[id:UUID][DESCRIPTION]]' link whose description begins with this
prefix is translated back to Logseq as `{{embed ((UUID))}}' rather than
a plain `((UUID))' block reference (AGENTS.md §6)."
  :type 'string
  :group 'logseq-org-sync)

(defun logseq-org-sync-reconcile--prompt-default (_id _logseq _roam)
  "Default conflict prompt.
Ask the user which side to keep and return `logseq' or `roam'."
  (if (y-or-n-p "Conflict; keep the Logseq version? ")
      'logseq
    'roam))

(defun logseq-org-sync-reconcile--file-hash (file)
  "Return the SHA-256 of FILE's contents, or nil when unreadable."
  (when (file-readable-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun logseq-org-sync-reconcile--file-mtime (file)
  "Return FILE's modification time as a time value, or nil when unavailable.
The value is suitable for `time-less-p' and matches
`file-attribute-modification-time' (AGENTS.md §4)."
  (file-attribute-modification-time (file-attributes file)))

(defun logseq-org-sync-reconcile--relative (root abs)
  "Return ABS relative to ROOT (with `/' separators)."
  (file-relative-name abs (file-name-as-directory (expand-file-name root))))

(defun logseq-org-sync-reconcile--table-entry (root abs node)
  "Return a node-table plist for ABS (under ROOT) parsed into NODE."
  (list :id (plist-get node :id)
        :path (logseq-org-sync-reconcile--relative root abs)
        :abs abs
        :node node
        :hash (logseq-org-sync-reconcile--file-hash abs)
        :mtime (logseq-org-sync-reconcile--file-mtime abs)
        :title (plist-get node :title)))

(defun logseq-org-sync-reconcile--build-table (root scan-fn parse-fn pages journals
                                                   &optional path-key-fn)
  "Return a UUID-keyed hash table for files under ROOT.
SCAN-FN lists the files (root/pages/journals); PARSE-FN parses a file
into an IR node; PAGES and JOURNALS name the subtrees to scan.  Files
without a `:id' are keyed by their relative path prefixed with
\"path:\" so they still participate in the sync.  PATH-KEY-FN, when
non-nil, maps an entry's relative path to the cross-side key used for
that fallback (e.g. mapping `.md' Logseq paths to their `.org' mirror)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (abs (funcall scan-fn root pages journals))
      (let* ((node (funcall parse-fn abs))
             (entry (logseq-org-sync-reconcile--table-entry root abs node))
             (key (or (plist-get node :id)
                      (concat "path:" (if path-key-fn
                                          (funcall path-key-fn
                                                   (plist-get entry :path))
                                        (plist-get entry :path))))))
        (puthash key entry table)))
    table))

(defun logseq-org-sync-reconcile--scan-logseq (graph)
  "Return a UUID-keyed table of the Logseq side of GRAPH."
  (logseq-org-sync-reconcile--build-table
   (plist-get graph :logseq-root)
   (lambda (root pages journals)
     (logseq-org-sync-logseq-scan
      root pages journals (logseq-org-sync-reconcile--graph-format graph)))
   #'logseq-org-sync-logseq-parse-file
   (plist-get graph :pages-directory)
   (plist-get graph :journals-directory)
   (lambda (path)
     (logseq-org-sync-reconcile--roam-path graph path))))

(defun logseq-org-sync-reconcile--scan-roam (graph)
  "Return a UUID-keyed table of the org-roam side of GRAPH."
  (logseq-org-sync-reconcile--build-table
   (plist-get graph :roam-root)
   #'logseq-org-sync-roam-scan
   #'logseq-org-sync-roam-parse-file
   (plist-get graph :pages-directory)
   (plist-get graph :journals-directory)))

(defun logseq-org-sync-reconcile--side-modified-p (id entry state key)
  "Non-nil when ENTRY's content differs from its last-synced hash.
ID is the node's state key (a UUID, or a `path:' key for files without
one); KEY is the STATE record's hash field (`:logseq-hash' or
`:roam-hash').  A missing STATE record means the side is new to the
engine, i.e. modified."
  (let* ((record (and state (logseq-org-sync-state-get state id)))
         (known (and record (plist-get record key))))
    (not (equal known (plist-get entry :hash)))))

(defun logseq-org-sync-reconcile--newer-side (logseq-entry roam-entry)
  "Return `logseq' or `roam' for whichever side has the newer mtime.
LOGSEQ-ENTRY and ROAM-ENTRY are the two table entries.  Ties (or missing
mtimes) favour `logseq'."
  (let ((lt (plist-get logseq-entry :mtime))
        (rt (plist-get roam-entry :mtime)))
    (if (and lt rt (time-less-p lt rt)) 'roam 'logseq)))

(defun logseq-org-sync-reconcile--action (type id node path reason &rest extra)
  "Build an action plist of TYPE for ID.
NODE and PATH describe the source; REASON records the classification;
EXTRA supplies additional key/value pairs (e.g. `:abs', `:from', `:to')."
  (let ((action (list :type type
                      :id id
                      :path path
                      :node node
                      :reason reason)))
    (while extra
      (setq action (plist-put action (car extra) (cadr extra)))
      (setq extra (cddr extra)))
    action))

(defun logseq-org-sync-reconcile--node-for (entry)
  "Return ENTRY's IR node, or nil."
  (plist-get entry :node))

(defun logseq-org-sync-reconcile--classify-new (id logseq-entry roam-entry graph)
  "Classify the node ID when present on only one side.
LOGSEQ-ENTRY and ROAM-ENTRY are the (possibly nil) table entries; GRAPH
supplies the format used to map paths between the two sides."
  (cond
   ((and logseq-entry (not roam-entry))
    (list (logseq-org-sync-reconcile--action
           'create-roam id
           (logseq-org-sync-reconcile--node-for logseq-entry)
           (logseq-org-sync-reconcile--roam-path
            graph (plist-get logseq-entry :path))
           'new)))
   ((and roam-entry (not logseq-entry))
    (list (logseq-org-sync-reconcile--action
           'create-logseq id
           (logseq-org-sync-reconcile--node-for roam-entry)
           (logseq-org-sync-reconcile--logseq-path
            graph (plist-get roam-entry :path))
           'new)))
   (t nil)))

(defun logseq-org-sync-reconcile--classify-both (id logseq-entry roam-entry state graph)
  "Classify the node ID present on both sides.
Return a list of actions reconciling LOGSEQ-ENTRY and ROAM-ENTRY given
the last-synced STATE (AGENTS.md §7).  GRAPH supplies the format used to
map paths between the two sides."
  (let* ((record (and state (logseq-org-sync-state-get state id)))
         (l-mod (logseq-org-sync-reconcile--side-modified-p
                 id logseq-entry state :logseq-hash))
         (r-mod (logseq-org-sync-reconcile--side-modified-p
                 id roam-entry state :roam-hash))
         (l-path (plist-get logseq-entry :path))
         (r-path (plist-get roam-entry :path)))
    (cond
     ;; Never synced: record both sides as a baseline (no write).
     ((not record)
      (list (logseq-org-sync-reconcile--action
             'seed id
             (logseq-org-sync-reconcile--node-for logseq-entry)
             (or l-path r-path) 'seed)))
     ;; Content identical (both unchanged): maybe just a rename to mirror.
     ((and (not l-mod) (not r-mod))
      (logseq-org-sync-reconcile--classify-rename
       id logseq-entry roam-entry record graph))
     ;; Only Logseq changed.
     ((and l-mod (not r-mod))
      (list (logseq-org-sync-reconcile--action
             'update-roam id
             (logseq-org-sync-reconcile--node-for logseq-entry)
             (logseq-org-sync-reconcile--roam-path graph l-path)
             'modified)))
     ;; Only org-roam changed.
     ((and r-mod (not l-mod))
      (list (logseq-org-sync-reconcile--action
             'update-logseq id
             (logseq-org-sync-reconcile--node-for roam-entry)
             (logseq-org-sync-reconcile--logseq-path graph r-path)
             'modified)))
     ;; Both changed: newest wins, or prompt.
     (t
      (let ((side (if (eq logseq-org-sync-reconcile-conflict-policy 'prompt)
                      (funcall logseq-org-sync-reconcile-prompt-function
                               id logseq-entry roam-entry)
                    (logseq-org-sync-reconcile--newer-side
                     logseq-entry roam-entry))))
        (if (eq side 'logseq)
            (list (logseq-org-sync-reconcile--action
                   'update-roam id
                   (logseq-org-sync-reconcile--node-for logseq-entry)
                   (logseq-org-sync-reconcile--roam-path graph l-path)
                   (if (eq logseq-org-sync-reconcile-conflict-policy 'prompt)
                       'conflict 'newest-wins)))
          (list (logseq-org-sync-reconcile--action
                 'update-logseq id
                 (logseq-org-sync-reconcile--node-for roam-entry)
                 (logseq-org-sync-reconcile--logseq-path graph r-path)
                 (if (eq logseq-org-sync-reconcile-conflict-policy 'prompt)
                     'conflict 'newest-wins)))))))))

(defun logseq-org-sync-reconcile--classify-rename (id logseq-entry roam-entry
                                                      record graph)
  "Return rename actions for ID when a side's relative path changed vs RECORD.
Both LOGSEQ-ENTRY and ROAM-ENTRY are unchanged, so a differing path is a
rename that must be mirrored to the other side (AGENTS.md §7).  Nil RECORD
means the node has never been synced, so path differences are not treated
as renames.  GRAPH supplies the format used to map paths between sides."
  (when record
    (let ((l-path (plist-get logseq-entry :path))
          (r-path (plist-get roam-entry :path))
          (l-known (plist-get record :logseq-path))
          (r-known (plist-get record :roam-path)))
      (cond
       ;; Logseq renamed: mirror the new name onto the org-roam side.
       ((and l-known r-known (not (equal l-path l-known)) (equal r-path r-known))
        (let ((to (logseq-org-sync-reconcile--roam-path graph l-path)))
          (list (logseq-org-sync-reconcile--action
                 'rename-roam id nil nil 'renamed :from r-known :to to))))
       ;; org-roam renamed: mirror the new name onto the Logseq side.
       ((and l-known r-known (equal l-path l-known) (not (equal r-path r-known)))
        (let ((to (logseq-org-sync-reconcile--logseq-path graph r-path)))
          (list (logseq-org-sync-reconcile--action
                 'rename-logseq id nil nil 'renamed :from l-known :to to))))
       (t nil)))))

(defun logseq-org-sync-reconcile--classify-deleted (id logseq-entry roam-entry
                                                       state graph)
  "Classify the node ID present on only one side but known to STATE.
Of LOGSEQ-ENTRY and ROAM-ENTRY exactly one is non-nil; the missing side's
copy was deleted, so mirror the deletion into that side's trash
\(AGENTS.md §7).  GRAPH supplies the roots."
  (let ((record (and state (logseq-org-sync-state-get state id))))
    (when record
      (cond
       ;; Deleted on Logseq, still present on org-roam -> trash the roam copy.
       ((and (not logseq-entry) roam-entry)
        (let ((path (plist-get record :roam-path)))
          (when path
            (list (logseq-org-sync-reconcile--action
                   'trash-roam id nil path 'deleted
                   :abs (logseq-org-sync-reconcile--abs graph 'roam path))))))
       ;; Deleted on org-roam, still present on Logseq -> trash the logseq copy.
       ((and logseq-entry (not roam-entry))
        (let ((path (plist-get record :logseq-path)))
          (when path
            (list (logseq-org-sync-reconcile--action
                   'trash-logseq id nil path 'deleted
                   :abs (logseq-org-sync-reconcile--abs graph 'logseq path))))))))))

(defun logseq-org-sync-reconcile--merge-classify (id logseq-entry roam-entry
                                                     state graph)
  "Classify the node ID given its LOGSEQ-ENTRY, ROAM-ENTRY, STATE and GRAPH."
  (cond
   ;; Present on both sides.
   ((and logseq-entry roam-entry)
    (logseq-org-sync-reconcile--classify-both
     id logseq-entry roam-entry state graph))
   ;; Present on at least one side: a mirrored deletion, else new.
   (t
    (or (logseq-org-sync-reconcile--classify-deleted
         id logseq-entry roam-entry state graph)
        (logseq-org-sync-reconcile--classify-new
         id logseq-entry roam-entry graph)))))

;;; ---------------------------------------------------------------------------
;;; Block references and embeds (AGENTS.md §6)
;;; ---------------------------------------------------------------------------

(defconst logseq-org-sync-reconcile--uuid-regexp
  "[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}"
  "Regexp matching a UUID (the shape of Logseq block and node ids).")

(defun logseq-org-sync-reconcile--block-id (block)
  "Return BLOCK's identity UUID, or nil.
Block ids live in BLOCK's `:properties' under \"ID\" (org) or
\"id\" (Markdown)."
  (let ((props (plist-get block :properties)))
    (or (cdr (assoc "ID" props))
        (cdr (assoc "id" props)))))

(defun logseq-org-sync-reconcile--register-blocks (table blocks)
  "Map every block UUID in BLOCKS to its `:text' in TABLE.
A block with no text registers the empty string so a resolved reference
is still distinguishable from an unknown UUID."
  (dolist (block blocks)
    (let ((id (logseq-org-sync-reconcile--block-id block)))
      (when id
        (puthash id (or (plist-get block :text) "") table)))
    (let ((children (plist-get block :children)))
      (when children
        (logseq-org-sync-reconcile--register-blocks table children)))))

(defun logseq-org-sync-reconcile--block-registry (entries)
  "Return a hash table mapping block UUID -> block text for ENTRIES.
ENTRIES is a list of node-table plists (each carries `:node')."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (logseq-org-sync-reconcile--register-blocks
       table (plist-get (plist-get entry :node) :content)))
    table))

(defun logseq-org-sync-reconcile--sanitize-description (text)
  "Return TEXT safe for use as an org link description.
Logseq page links are reduced to their visible label and any literal
square brackets are removed so they cannot terminate the link early."
  (let ((s (or text "")))
    (setq s (replace-regexp-in-string
             "\\[\\[[^][]*\\]\\[\\([^][]*\\)\\]\\]" "\\1" s))
    (setq s (replace-regexp-in-string "\\[\\[\\([^][]*\\)\\]\\]" "\\1" s))
    (replace-regexp-in-string "[][]" "" s)))

(defun logseq-org-sync-reconcile--embed-description (text)
  "Return the org link description for a block embed of TEXT."
  (concat logseq-org-sync-block-embed-prefix
          (if (and text (not (string-empty-p text))) (concat " " text) "")))

(defun logseq-org-sync-reconcile--embed-description-p (desc)
  "Return non-nil when DESC marks a block embed."
  (and desc
       (or (string= desc logseq-org-sync-block-embed-prefix)
           (string-prefix-p (concat logseq-org-sync-block-embed-prefix " ")
                            desc))))

(defun logseq-org-sync-reconcile--uuid-in (string)
  "Return the first UUID in STRING, or nil."
  (when (string-match logseq-org-sync-reconcile--uuid-regexp string)
    (match-string 0 string)))

(defun logseq-org-sync-reconcile--translate-logseq-text (text registry)
  "Translate Logseq block references/embeds in TEXT to org-roam links.
`((UUID))' becomes `[[id:UUID][TEXT]]' and `{{embed ((UUID))}}' becomes
`[[id:UUID][#embed TEXT]]', where TEXT is the referenced block's text
from REGISTRY.  References whose UUID is not in REGISTRY are left
verbatim."
  (let ((re (concat "{{embed[ \t]*((\\("
                    logseq-org-sync-reconcile--uuid-regexp "\\)))}}"
                    "\\|"
                    "((\\(" logseq-org-sync-reconcile--uuid-regexp "\\)))")))
    (replace-regexp-in-string
     re
     (lambda (whole)
       (save-match-data
         (let* ((uuid (logseq-org-sync-reconcile--uuid-in whole))
                (text (and uuid (gethash uuid registry))))
           (if (null text)
               whole
             (let ((desc (logseq-org-sync-reconcile--sanitize-description text)))
               (if (string-prefix-p "{{embed" whole)
                   (format "[[id:%s][%s]]"
                           uuid (logseq-org-sync-reconcile--embed-description desc))
                 (if (string-empty-p desc)
                     (format "[[id:%s]]" uuid)
                   (format "[[id:%s][%s]]" uuid desc))))))))
     text t t)))

(defconst logseq-org-sync-reconcile--id-link-regexp
  (concat "\\[\\[id:\\([^][]+\\)\\]\\[\\([^][]*\\)\\]\\]"
          "\\|"
          "\\[\\[id:\\([^][]+\\)\\]\\]")
  "Regexp matching an org `[[id:UUID][DESCRIPTION]]' or `[[id:UUID]]' link.")

(defun logseq-org-sync-reconcile--translate-roam-text (text registry)
  "Translate org-roam block links in TEXT to Logseq block references.
`[[id:UUID][DESC]]' where UUID names a block in REGISTRY becomes
`((UUID))', or `{{embed ((UUID))}}' when DESC begins with the embed
prefix.  Page links (UUID not in REGISTRY) are left untouched."
  (replace-regexp-in-string
   logseq-org-sync-reconcile--id-link-regexp
   (lambda (whole)
     (save-match-data
       (if (string-match logseq-org-sync-reconcile--id-link-regexp whole)
           (let* ((uuid (or (match-string 1 whole) (match-string 3 whole)))
                  (desc (match-string 2 whole)))
             (if (null (gethash uuid registry))
                 whole
               (if (logseq-org-sync-reconcile--embed-description-p desc)
                   (format "{{embed ((%s))}}" uuid)
                 (format "((%s))" uuid))))
         whole)))
   text t t))

(defun logseq-org-sync-reconcile--map-block-text (fn block)
  "Return BLOCK with its `:text' translated by FN, recursing into children."
  (let ((text (plist-get block :text)))
    (when text
      (setq block (plist-put block :text (funcall fn text)))))
  (let ((children (plist-get block :children)))
    (when children
      (setq block (plist-put block :children
                             (mapcar (lambda (child)
                                       (logseq-org-sync-reconcile--map-block-text
                                        fn child))
                                     children)))))
  block)

(defun logseq-org-sync-reconcile--translate-node (node fn)
  "Return NODE with every block's `:text' translated by FN."
  (let ((content (plist-get node :content)))
    (if content
        (plist-put node :content
                   (mapcar (lambda (block)
                             (logseq-org-sync-reconcile--map-block-text fn block))
                           content))
      node)))

(defun logseq-org-sync-reconcile--node-to-roam (node registry)
  "Return NODE with Logseq block references translated to org-roam links.
REGISTRY maps block UUIDs to their text."
  (logseq-org-sync-reconcile--translate-node
   node (lambda (text)
          (logseq-org-sync-reconcile--translate-logseq-text text registry))))

(defun logseq-org-sync-reconcile--node-to-logseq (node registry)
  "Return NODE with org-roam block links translated to Logseq references.
REGISTRY maps block UUIDs to their text."
  (logseq-org-sync-reconcile--translate-node
   node (lambda (text)
          (logseq-org-sync-reconcile--translate-roam-text text registry))))

;;; ---------------------------------------------------------------------------
;;; Cross-format block bodies (AGENTS.md §11.1 step 6, §11.2)
;;; ---------------------------------------------------------------------------

(defun logseq-org-sync-reconcile--md-fence-language (text)
  "Return Markdown fence TEXT's info string, or nil when TEXT is not a fence.
An empty string means a fence with no info string."
  (when (and text
             (string-match "\\`\\(`\\{3\\}\\)\\([^`]*\\)\\'" text))
    (string-trim (match-string 2 text))))

(defun logseq-org-sync-reconcile--md-body-content (body)
  "Return BODY with a trailing Markdown closing fence line removed.
Returns nil for a nil BODY."
  (when body
    (let ((lines (split-string body "\n")))
      (if (and lines
               (string-match-p "\\`[ \t]*`\\{3\\}[ \t]*\\'" (car (last lines))))
          (let ((stripped (mapconcat #'identity (butlast lines) "\n")))
            (and (not (string-empty-p stripped)) stripped))
        body))))

(defun logseq-org-sync-reconcile--md-pipe-row-p (line)
  "Return non-nil when LINE is a Markdown pipe-table row."
  (string-match-p "\\`|.*|\\'" (string-trim line)))

(defun logseq-org-sync-reconcile--md-pipe-table-p (text)
  "Return non-nil when TEXT is a Markdown pipe table.
Every non-blank line must begin and end with `|'."
  (and text (not (string-empty-p text))
       (let ((ok t) (lines (split-string text "\n")))
         (dolist (line lines)
           (unless (or (string-blank-p (string-trim line))
                       (logseq-org-sync-reconcile--md-pipe-row-p line))
             (setq ok nil)))
         ok)))

(defun logseq-org-sync-reconcile--src-block (body)
  "Return (LANG . CONTENT) when BODY is a single `#+BEGIN_SRC' block.
Returns nil otherwise."
  (when (and body
             (string-match
              "\\`#\\+BEGIN_SRC\\([ \t]+\\([^ \t\n]+\\)\\)?[^\n]*\n" body))
    (let* ((lang (or (match-string 2 body) ""))
           (content-start (match-end 0))
           (content-end (and (string-match "\n#\\+END_SRC[ \t]*\\'" body)
                             (match-beginning 0))))
      (when content-end
        (cons lang (if (>= content-start content-end)
                       ""
                     (substring body content-start content-end)))))))

(defun logseq-org-sync-reconcile--set-body (block body)
  "Return BLOCK with `:body' BODY, or without `:body' when BODY is empty."
  (if (and body (not (string-empty-p body)))
      (plist-put block :body body)
    (let ((result nil) (rest block))
      (while rest
        (unless (eq (car rest) :body)
          (setq result (plist-put result (car rest) (cadr rest))))
        (setq rest (cddr rest)))
      result)))

(defun logseq-org-sync-reconcile--md-block-to-roam (block)
  "Translate a Logseq Markdown BLOCK into an org-roam block.
A fenced code block (whose `:text' is a ``````` opener) becomes a
`#+BEGIN_SRC' body; a pipe table (whose full content is `| … |' rows) is
wrapped verbatim in `#+BEGIN_SRC markdown' (§11.2).  Other blocks are
returned unchanged."
  (let* ((text (plist-get block :text))
         (body (plist-get block :body))
         (lang (logseq-org-sync-reconcile--md-fence-language text)))
    (cond
     (lang
      (let* ((src-lang (if (string-empty-p lang) "" (concat " " lang)))
             (content (logseq-org-sync-reconcile--md-body-content body))
             (new-body (concat "#+BEGIN_SRC" src-lang "\n"
                               (if content (concat content "\n") "")
                               "#+END_SRC")))
        (setq block (plist-put block :text ""))
        (logseq-org-sync-reconcile--set-body block new-body)))
     ((and text (logseq-org-sync-reconcile--md-pipe-table-p
                 (concat text (if body (concat "\n" body) ""))))
      (let* ((table (concat text (if body (concat "\n" body) "")))
             (new-body (concat "#+BEGIN_SRC markdown\n" table "\n#+END_SRC")))
        (setq block (plist-put block :text ""))
        (logseq-org-sync-reconcile--set-body block new-body)))
     (t block))))

(defun logseq-org-sync-reconcile--roam-block-to-logseq (block)
  "Translate an org-roam BLOCK into a Logseq Markdown block.
A `#+BEGIN_SRC lang' body becomes a Markdown fence; a `#+BEGIN_SRC
markdown' body holding a pipe table is unwrapped to a native table
\(§11.2).  Other blocks are returned unchanged."
  (let* ((body (plist-get block :body))
         (src (logseq-org-sync-reconcile--src-block body)))
    (cond
     ((and src (string= (car src) "markdown")
           (logseq-org-sync-reconcile--md-pipe-table-p (cdr src)))
      (let* ((lines (split-string (cdr src) "\n"))
             (header (car lines))
             (rows (cdr lines)))
        (setq block (plist-put block :text header))
        (logseq-org-sync-reconcile--set-body
         block (and rows (mapconcat #'identity rows "\n")))))
     (src
      (let* ((lang (car src))
             (content (cdr src))
             (new-body (concat content (if (string-empty-p content) "" "\n") "```")))
        (setq block (plist-put block :text (concat "```" lang)))
        (logseq-org-sync-reconcile--set-body block new-body)))
     (t block))))

(defun logseq-org-sync-reconcile--map-block-body (fn block)
  "Return BLOCK transformed by FN (block -> block), recursing into children."
  (let ((result (funcall fn block)))
    (let ((children (plist-get result :children)))
      (when children
        (setq result
              (plist-put result :children
                         (mapcar (lambda (child)
                                   (logseq-org-sync-reconcile--map-block-body
                                    fn child))
                                 children)))))
    result))

(defun logseq-org-sync-reconcile--node-bodies (node fn)
  "Return NODE with each block transformed by FN (block -> block)."
  (let ((content (plist-get node :content)))
    (if content
        (plist-put node :content
                   (mapcar (lambda (block)
                             (logseq-org-sync-reconcile--map-block-body fn block))
                           content))
      node)))

(defun logseq-org-sync-reconcile--node-body-to-roam (node)
  "Return NODE with Markdown block bodies translated to org-roam."
  (logseq-org-sync-reconcile--node-bodies
   node #'logseq-org-sync-reconcile--md-block-to-roam))

(defun logseq-org-sync-reconcile--node-body-to-logseq (node)
  "Return NODE with org-roam block bodies translated to Markdown."
  (logseq-org-sync-reconcile--node-bodies
   node #'logseq-org-sync-reconcile--roam-block-to-logseq))

(defun logseq-org-sync-reconcile--translate-plan (plan logseq roam graph)
  "Translate block references and block bodies in PLAN for the target side.
LOGSEQ and ROAM are the two node tables; they supply the block
registries used to resolve block UUIDs to text.  GRAPH supplies the
Logseq format, so block bodies are only translated for Markdown graphs."
  (let ((logseq-registry (logseq-org-sync-reconcile--block-registry
                          (hash-table-values logseq)))
        (roam-registry (logseq-org-sync-reconcile--block-registry
                        (hash-table-values roam)))
        (markdown-p (logseq-org-sync-reconcile--markdown-p graph)))
    (mapcar
     (lambda (action)
       (let ((type (plist-get action :type))
             (node (plist-get action :node)))
         (cond
          ((and node (memq type '(create-roam update-roam)))
           (let ((translated (logseq-org-sync-reconcile--node-to-roam
                              node logseq-registry)))
             (when markdown-p
               (setq translated
                     (logseq-org-sync-reconcile--node-body-to-roam translated)))
             (plist-put action :node translated)))
          ((and node (memq type '(create-logseq update-logseq)))
           (let ((translated (logseq-org-sync-reconcile--node-to-logseq
                              node roam-registry)))
             (when markdown-p
               (setq translated
                     (logseq-org-sync-reconcile--node-body-to-logseq translated)))
             (plist-put action :node translated))))
         action))
     plan)))

(defun logseq-org-sync-reconcile-plan (graph state)
  "Return an ordered reconciliation plan for GRAPH given the last-synced STATE.
The plan is a list of action plists (see the file Commentary).  Planning
reads files but performs no writes, so it is safe to call for a preview.
Block references and block bodies in create/update nodes are translated
for their target side (AGENTS.md §6, §11.1 step 6)."
  (let ((logseq (logseq-org-sync-reconcile--scan-logseq graph))
        (roam (logseq-org-sync-reconcile--scan-roam graph))
        (ids nil)
        (plan nil))
    ;; Collect every key from both tables, Logseq first for stable ordering.
    (maphash (lambda (id _entry) (unless (member id ids) (push id ids))) logseq)
    (maphash (lambda (id _entry) (unless (member id ids) (push id ids))) roam)
    (setq ids (nreverse ids))
    (dolist (id ids)
      (setq plan
            (append plan
                    (logseq-org-sync-reconcile--merge-classify
                     id (gethash id logseq) (gethash id roam) state graph))))
    (logseq-org-sync-reconcile--translate-plan plan logseq roam graph)))

;;;###autoload
(defun logseq-org-sync-reconcile-dry-run (graph state)
  "Return the plan for GRAPH against STATE without touching the filesystem.
Alias for `logseq-org-sync-reconcile-plan' highlighting its safety."
  (logseq-org-sync-reconcile-plan graph state))

(defun logseq-org-sync-reconcile--write-logseq (node abs)
  "Write NODE to ABS using the Logseq writer."
  (make-directory (file-name-directory abs) t)
  (logseq-org-sync-logseq-write node abs))

(defun logseq-org-sync-reconcile--write-roam (node abs)
  "Write NODE to ABS using the org-roam writer."
  (make-directory (file-name-directory abs) t)
  (logseq-org-sync-roam-write node abs))

(defun logseq-org-sync-reconcile--trash (abs root)
  "Move ABS into ROOT's trash subdirectory (AGENTS.md §1.7).
Returns the destination path, or nil for a nil ABS.  Missing files are
ignored.  The relative path under ROOT is preserved inside the trash."
  (when (and abs (file-exists-p abs))
    (let* ((rel (logseq-org-sync-reconcile--relative root abs))
           (dest (expand-file-name
                  (concat logseq-org-sync-reconcile-trash-directory "/" rel)
                  (expand-file-name root))))
      (make-directory (file-name-directory dest) t)
      (rename-file abs dest 'ok-if-already-exists)
      dest)))

(defun logseq-org-sync-reconcile--abs (graph side path)
  "Return PATH made absolute under GRAPH's SIDE root."
  (expand-file-name path
                    (expand-file-name (plist-get graph
                                                 (if (eq side 'logseq)
                                                     :logseq-root
                                                   :roam-root)))))

(defun logseq-org-sync-reconcile--record (state action graph)
  "Return STATE updated with metadata for ACTION, using GRAPH roots.
Hash/mtime are read back from both sides.  Paths follow the 1:1 mapping
\(AGENTS.md §2): create/update/seed leave both sides at `:path', while a
rename leaves both sides at `:to'."
  (let* ((id (plist-get action :id))
         (type (plist-get action :type))
         (path (plist-get action :path))
         (existing (logseq-org-sync-state-get state id))
         (record (or existing (list :id id)))
         (logseq-path (plist-get existing :logseq-path))
         (roam-path (plist-get existing :roam-path)))
    ;; Determine each side's final relative path.  Action `:path' and `:to'
    ;; values are native to their target side, so the other side's path is
    ;; derived by extension mapping (identity for org graphs).
    (pcase type
      ((or 'create-roam 'update-roam)
       (setq roam-path path
             logseq-path (logseq-org-sync-reconcile--logseq-path graph path)))
      ((or 'create-logseq 'update-logseq)
       (setq logseq-path path
             roam-path (logseq-org-sync-reconcile--roam-path graph path)))
      ('seed
       (setq logseq-path path
             roam-path (logseq-org-sync-reconcile--roam-path graph path)))
      ('rename-roam
       (let ((to (plist-get action :to)))
         (setq roam-path to
               logseq-path (logseq-org-sync-reconcile--logseq-path graph to))))
      ('rename-logseq
       (let ((to (plist-get action :to)))
         (setq logseq-path to
               roam-path (logseq-org-sync-reconcile--roam-path graph to)))))
    (when logseq-path (setq record (plist-put record :logseq-path logseq-path)))
    (when roam-path (setq record (plist-put record :roam-path roam-path)))
    (when (plist-get action :node)
      (setq record (plist-put record :title
                              (plist-get (plist-get action :node) :title))))
    (let ((l-abs (and logseq-path
                      (logseq-org-sync-reconcile--abs graph 'logseq logseq-path)))
          (r-abs (and roam-path
                      (logseq-org-sync-reconcile--abs graph 'roam roam-path))))
      (when l-abs
        (setq record (plist-put record :logseq-hash
                                (logseq-org-sync-reconcile--file-hash l-abs)))
        (setq record (plist-put record :logseq-mtime
                                (logseq-org-sync-reconcile--file-mtime l-abs))))
      (when r-abs
        (setq record (plist-put record :roam-hash
                                (logseq-org-sync-reconcile--file-hash r-abs)))
        (setq record (plist-put record :roam-mtime
                                (logseq-org-sync-reconcile--file-mtime r-abs)))))
    (setq record (plist-put record :last-sync (current-time)))
    (logseq-org-sync-state-put state record)))

;;;###autoload
(defun logseq-org-sync-reconcile-apply (graph state plan)
  "Execute PLAN for GRAPH, returning the updated STATE.
Each action is performed and the state store is updated with the new
paths, hashes, and mtimes (AGENTS.md §4, §7 step 4).  Deletions are
moved to trash, never hard-deleted."
  (dolist (action plan)
    (let ((type (plist-get action :type))
          (id (plist-get action :id))
          (path (plist-get action :path))
          (node (plist-get action :node)))
      (pcase type
        ('create-roam
         (logseq-org-sync-reconcile--write-roam
          node (logseq-org-sync-reconcile--abs graph 'roam path)))
        ('update-roam
         (logseq-org-sync-reconcile--write-roam
          node (logseq-org-sync-reconcile--abs graph 'roam path)))
        ('create-logseq
         (logseq-org-sync-reconcile--write-logseq
          node (logseq-org-sync-reconcile--abs graph 'logseq path)))
        ('update-logseq
         (logseq-org-sync-reconcile--write-logseq
          node (logseq-org-sync-reconcile--abs graph 'logseq path)))
        ('rename-roam
         (let ((from (logseq-org-sync-reconcile--abs graph 'roam
                                                     (plist-get action :from)))
               (to (logseq-org-sync-reconcile--abs graph 'roam
                                                   (plist-get action :to))))
           (make-directory (file-name-directory to) t)
           (when (file-exists-p from)
             (rename-file from to 'ok-if-already-exists))))
        ('rename-logseq
         (let ((from (logseq-org-sync-reconcile--abs graph 'logseq
                                                     (plist-get action :from)))
               (to (logseq-org-sync-reconcile--abs graph 'logseq
                                                   (plist-get action :to))))
           (make-directory (file-name-directory to) t)
           (when (file-exists-p from)
             (rename-file from to 'ok-if-already-exists))))
        ('trash-roam
         (logseq-org-sync-reconcile--trash
          (or (plist-get action :abs)
              (logseq-org-sync-reconcile--abs graph 'roam path))
          (plist-get graph :roam-root))
         (setq state (logseq-org-sync-state-remove state id)))
        ('trash-logseq
         (logseq-org-sync-reconcile--trash
          (or (plist-get action :abs)
              (logseq-org-sync-reconcile--abs graph 'logseq path))
          (plist-get graph :logseq-root))
         (setq state (logseq-org-sync-state-remove state id))))
      (unless (memq type '(trash-roam trash-logseq))
        (setq state (logseq-org-sync-reconcile--record state action graph)))))
  state)

(provide 'logseq-org-sync-reconcile)
;;; logseq-org-sync-reconcile.el ends here
