;;;; rows — the file and the operator's rows
;;;;
;;;; Split out of `store.lisp`, which was one 650-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; --------------------------------------------------------------- the file ;;;

(defvar *store-path-override* nil
  "A test's own database path. Bound, never set: the default is `store-path`.")

(defun store-path ()
  "Where the head's own database lives: `$XDG_DATA_HOME/leticl/head.db`, else under `~/.local/share`.

**The XDG DATA directory and not the config one.** `head.toml` and the retired notes are things a
person may read and edit; this is a database, and a database in a config directory invites exactly
the hand-editing that a `create table` cannot survive. `~/.local/share` is where letibot's own
`sessions.db` sits, so the two heads' local data are in the same place for the same reason."
  (or *store-path-override*
      (let ((xdg (uiop:getenv "XDG_DATA_HOME"))
            (home (uiop:getenv "HOME")))
        (cond (xdg (merge-pathnames "leticl/head.db"
                                    (uiop:ensure-directory-pathname xdg)))
              (home (merge-pathnames "leticl/head.db"
                                     (merge-pathnames ".local/share/"
                                                      (uiop:ensure-directory-pathname home))))
              (t nil)))))

(defvar *store-lock* (sb-thread:make-mutex :name "leticl store")
  "The ONE lock every store operation holds, and it is not optional.

**MEASURED, as SBCL CORRUPTION WARNINGS flooding the operator's own window:**

    CORRUPTION WARNING in SBCL pid 1672364 tid 1836575:
      Memory fault at (nil) (pc=(nil), fp=0x7f035c8562c0, sp=0x7f035c856268)
      The integrity of this image is possibly compromised.

`pc=(nil)` is a call through a NULL FUNCTION POINTER, and sqlite reaches its methods through function
pointers stored in the object it is working on — so this is a USE-AFTER-FREE: one thread was inside a
statement while another had already closed the database out from under it.

**Because this file had no lock at all, and the handle is one per PROCESS while the callers are not:**
the loop thread saves on every add and delete, the reader thread folds a `todos_updated` on an
incoming frame, and every `tui-eval` runs on its OWN thread. Three threads, one `sqlite3*`, and the
reopen-on-failure path I added is a close — the exact thing that must never overlap a use.

**A recursive lock, because the calls genuinely nest**: `store-load-todos` adopts orphans and
`store-replace-todos` saves row by row, so a plain mutex would deadlock the head on the first such
call. `with-recursive-lock` is the same thread re-entering, which is what nesting here is.

**And the order is always paint-then-store, never the reverse.** An eval holds the paint lock and may
take this one; the loop never takes this lock and then waits for paint. So there is no cycle. That is
worth stating because a lock added here without that argument is how a head hangs instead of
corrupting.")

(defvar *store-handle* nil "The open database handle, or NIL. One per process.")
(defvar *store-file* nil "The path `*store-handle*` was opened from, so a path change reopens.")
(defvar *store-unavailable* nil
  "Set when the database could not be opened or a statement failed, with the reason.

**It refuses rather than retries.** A store that failed once — a permissions error, a full disk, a
locked file — will very likely fail again, and a head that retried on every keystroke would spend a
syscall per key to fail the same way. Saying so once and keeping the list in memory is what a person
can act on.")

(defun store-available-p ()
  "Can the store be used? **It ASKS, rather than reporting a remembered verdict.**

The first cut returned `(and *sqlite-library* (not *store-unavailable*))`, which answers *nothing has
gone wrong yet* — so it said YES for a path that could never be opened, and only told the truth after
somebody had tried. MEASURED by the test that binds a store under `/proc`: `store-available-p` was T
and the very next call signalled. A predicate a caller uses to decide whether to try must try.

The attempt is cached: `%store-db` opens once and reuses the handle, and a failure sets
`*store-unavailable*` for the session, so this is at most one `open` and then one comparison."
  (sb-thread:with-recursive-lock (*store-lock*)
    (and *sqlite-library*
       (not *store-unavailable*)
       (not (null (%store-db))))))

(defun %store-failed (e)
  "Record E as this session's store failure, DROP THE HANDLE, and answer NIL.

**THE HANDLE IS DROPPED AND THAT IS THE WHOLE POINT.** MEASURED on the live head: a statement that
signalled left the connection in a state where every later prepare faulted with `Unhandled memory
fault at #x0`, so ONE bad call disabled the store for the rest of the session — and because every
caller swallows the failure, the head went on running with a store that silently refused every write.
Reopening the handle fixed it immediately (also measured: a fresh connection wrote on the first
attempt). So a failure costs one call: `%store-db` reopens on the next one, and a successful reopen
clears `*store-unavailable*`, which is what keeps `store-available-p` honest.

An `ignore-errors` around the close: this runs INSIDE a handler, and a close that signals must not
replace the error being reported with its own."
  (setf *store-unavailable* (format nil "~a" e))
  (when *store-handle*
    (ignore-errors (%sq-close *store-handle*))
    (setf *store-handle* nil))
  nil)

(defun %store-db ()
  "The open handle, opening and creating the schema on first use. NIL when there is no store."
  (when *sqlite-library*
    (let ((path (store-path)))
      (when path
        (when (and *store-handle* (equal *store-file* path))
          (return-from %store-db *store-handle*))
        (when *store-handle* (%sq-close *store-handle*) (setf *store-handle* nil))
        ;; **EVERYTHING THAT CAN REFUSE IS INSIDE THE HANDLER, and the first cut had
        ;; `ensure-directories-exist` outside it.** MEASURED: a path whose directory cannot be
        ;; created — a read-only mount, `/proc`, a full disk — SIGNALS `SIMPLE-FILE-ERROR` rather
        ;; than returning, so a head pointed at a bad store died at startup instead of running
        ;; without one. The claim this file makes is that a missing convenience never takes the
        ;; screen down; that claim has to hold for a filesystem that says no.
        (handler-case (ensure-directories-exist path)
          (error (e) (setf *store-unavailable* (format nil "~a" e)) (return-from %store-db nil)))
        (let ((cell (sb-alien:make-alien %sq-db))
              (err (sb-alien:make-alien sb-alien:c-string)))
          (unwind-protect
               (if (/= +sqlite-ok+ (%sq-open (namestring path) cell))
                   (setf *store-unavailable* "the database could not be opened")
                   (let ((db (sb-alien:deref cell)))
                     ;; WAL, because a head and a test may both touch this file and the default
                     ;; rollback journal takes a write lock for the whole transaction.
                     (%sq-exec db "pragma journal_mode=wal" (sb-sys:int-sap 0) (sb-sys:int-sap 0) err)
                     (if (/= +sqlite-ok+
                             (%sq-exec db
                                       "create table if not exists operator_todo (
                                          id     text primary key,
                                          seq    integer not null,
                                          title  text not null,
                                          detail text not null default '',
                                          status text not null default 'open',
                                          workspace text not null default '')"
                                       (sb-sys:int-sap 0) (sb-sys:int-sap 0) err))
                         (progn (setf *store-unavailable* (or (sb-alien:deref err) "schema failed"))
                                (%sq-close db))
                         ;; **`db` IS THE ANSWER, and the `setf` was not.**
                         ;;
                         ;; `unwind-protect` returns its PROTECTED FORM's value, and that branch
                         ;; ended in `(setf … *store-unavailable* nil)` — which evaluates to NIL. So
                         ;; opening the database SUCCESSFULLY returned NIL, and every caller read
                         ;; that as *there is no store*: `store-save-todo` did nothing, silently, and
                         ;; a probe showed `db=NIL`, `save=NIL`, `unavail=NIL` with nothing wrong
                         ;; anywhere. MEASURED, and the shape is worth naming — a function whose
                         ;; last form is an assignment returns the assignment's value, which is
                         ;; almost never the thing the caller wants.
                         (progn
                           (setf *store-handle* db *store-file* path *store-unavailable* nil)
                           ;; **AND THE TABLE THAT RECORDS A SEEDING**, beside the one it seeds. A
                           ;; row here says *this project has had its starter todos put in it*, and
                           ;; it is a table rather than a column because the fact is about the
                           ;; PROJECT and not about any row — deleting every starter todo afterwards
                           ;; must not bring them back, which is exactly what an "is the list empty"
                           ;; test would do.
                           (%sq-exec db
                                     "create table if not exists todo_seed (
                                        workspace text primary key)"
                                     (sb-sys:int-sap 0) (sb-sys:int-sap 0) err)
                           ;; **AND THE COLUMN FOR A DATABASE THAT PREDATES IT.**
                           ;;
                           ;; `create table if not exists` is a no-op on a database that already has
                           ;; the table, so a head upgrading from before todos were per-project would
                           ;; keep a table with no `workspace` column and every statement naming it
                           ;; would fail — the whole feature silently dead on exactly the head that
                           ;; had rows to migrate.
                           ;;
                           ;; The `alter` is run and its failure IGNORED, which is the small honest
                           ;; move: SQLite has no `add column if not exists`, and the only failure
                           ;; here is `duplicate column name`, which means the schema is already
                           ;; right. Anything else would have failed the `create` above too.
                           (ignore-errors
                            (%sq-exec db
                                      "alter table operator_todo add column workspace text not null default ''"
                                      (sb-sys:int-sap 0) (sb-sys:int-sap 0) err))
                           db))))
            (sb-alien:free-alien cell)
            (sb-alien:free-alien err)))))))

(defun store-close ()
  "Close the handle, if open. For a test between cases, and for a switch between stores."
  (sb-thread:with-recursive-lock (*store-lock*)
    (when *store-handle*
    (%sq-close *store-handle*)
    (setf *store-handle* nil *store-file* nil))))

(defmacro with-statement ((var db sql) &body body)
  "VAR bound to a prepared SQL statement, finalized however BODY ends.

**`unwind-protect` and not a straight `finalize` after BODY**: a statement holds a lock until it is
finalized, so one that is left behind by an error keeps the database busy for the rest of the
process — the failure mode being invisible until the NEXT write."
  (let ((stmt (gensym "STMT")) (cell (gensym "CELL")))
    `(let ((,cell (sb-alien:make-alien %sq-stmt))
           (,var nil))
       (unwind-protect
            (progn
              ;; **`(sb-sys:int-sap 0)` AND NOT `nil` FOR THE TAIL.** `sqlite3_prepare_v2`'s last
              ;; argument is an OUT-parameter this file never reads, and passing a Lisp `nil` where
              ;; a pointer is expected is exactly the kind of thing sb-alien may accept, reject or
              ;; dereference depending on the version — MEASURED as `Unhandled memory fault at
              ;; #x0` on the live head while a fresh image was fine. An explicit null pointer says
              ;; what is meant.
              (if (/= +sqlite-ok+ (%sq-prepare ,db ,sql -1 ,cell (sb-sys:int-sap 0)))
                  (error "could not prepare: ~a" ,sql)
                  (setf ,var (sb-alien:deref ,cell)))
              ,@body)
         (when ,var (%sq-finalize ,var))
         (sb-alien:free-alien ,cell)))))

(defun %bind-text (stmt index value)
  "Bind VALUE at INDEX as TEXT, taking sqlite's own copy of it.

**One index at a time, and spelled out at each call site.** The first cut bound a LIST over
parameters 1..n and then bound the integer over parameter 2 by hand, which reads as though the two
were independent when the second overwrote part of the first. A binding is positional; saying so at
each site is how a reader checks it.

**AND A STRING FROM THE WIRE IS NOT ALWAYS `simple-string`, WHICH COST THE OPERATOR THEIR TODO.** The
alien declaration takes a `c-string`, and sb-alien refuses anything else:

    The value \"completed\" is not of type SIMPLE-STRING when binding STRING

MEASURED, on the live head: a status that arrived from the daemon is `(VECTOR CHARACTER 20)`,
**adjustable, with a fill pointer** — the JSON reader's own output shape — and every save carrying one
THREW. That is the boundary, so this is where it is fixed, once: rows the head builds itself
(`format nil`) are simple and always saved, while a status the MODEL moved arrives from the wire and
therefore never did — silently, which is what made it look like a restart losing the operator's row
rather than a write that never happened.

`coerce` only when it is needed, so the common path copies nothing."
  (%sq-bind-text stmt index
                 (let ((s (or value "")))
                   (if (typep s 'simple-string) s (coerce s 'simple-string)))
                 -1 +sqlite-transient+))

;;; ------------------------------------------------------- the operator's rows ;;;

(defun store-load-todos (workspace)
  "Every stored item for WORKSPACE, oldest first, as the plists `*operator-todos*` holds.

**PER PROJECT, and that is the operator's ruling** — *\"todos must be perproject\"* — after they
found the leak: a row created in a leticl window (`push leticl to github`) appeared on the RANO
daemon's board, because this used to be one table with no key and `push-operator-todos` sent the
whole list to every session on HELLO. The daemon's board is per-session and project-scoped and the
MODEL reads it as its plan, so a head-wide list became one project's work items — and
`unfinished_plan` would have handed the rano model a check naming leticl work.

The key is the daemon's own workspace, the same string `modes.tsv` keys a project root by, so the two
notions of *which project is this* cannot disagree.

**ROWS WITH NO WORKSPACE ARE ADOPTED, ONCE, AND THE ADOPTION IS SAID.** Every row written before this
column existed has `workspace = ''`, and there are only two honest things to do with them: leave them
visible everywhere (which is the bug), or assign them to the workspace that first asks. Guessing is
avoidable because the head doing the asking is the only head that ever wrote them in practice — but it
is still a guess, so it is REPORTED rather than silent, and it happens once because the update leaves
nothing behind for the next caller.

**NIL for a store that is not there**, which the caller cannot distinguish from an empty list — and
that is the honest answer rather than a guess: a head with no database and a head whose list is
empty both have nothing to draw, and inventing a difference would be inventing a claim."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
    (when db
      (handler-case
          (progn
            (let ((adopted (store-adopt-orphan-todos workspace)))
              (when (plusp adopted)
                ;; SAID, because it is the one step here that claims to know which project a row
                ;; belongs to without being told.
                (setf *store-note*
                      (format nil "~d todo~:p written before todos were per-project now belong~@[ to ~a~]"
                              adopted workspace))))
            (with-statement (stmt db "select id, title, detail, status from operator_todo
                                        where workspace = ? order by seq")
              (%bind-text stmt 1 (or workspace ""))
              (let ((out nil))
                (loop while (= +sqlite-row+ (%sq-step stmt))
                      do (push (list :id (%sq-column-text stmt 0)
                                     :content (%sq-column-text stmt 1)
                                     :detail (or (%sq-column-text stmt 2) "")
                                     :status (or (%sq-column-text stmt 3) "open"))
                               out))
                (nreverse out))))
        (error (e) (%store-failed e)))))))

(defvar *store-note* nil
  "A one-off sentence the store wants said — currently the orphan-row adoption.

A `defvar` read and cleared by `load-operator-todos`, which is the caller that can actually put it on
the screen: this file has no opinion about the status line, and threading a head through a store
function to say one sentence would be the tail wagging the dog.")

(defun %store-user-version ()
  "This database's migration version, or 0. **SQLite's own application number**, `pragma user_version`:
no table of ours to create, it travels with the file, and it is exactly what a migration marker is."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "pragma user_version")
            (if (= +sqlite-row+ (%sq-step stmt))
                (let ((sap (%sq-column-text-ptr stmt 0)))
                  (if (and sap (not (sb-sys:sap= sap (sb-sys:int-sap 0))))
                      (or (ignore-errors (parse-integer (%sq-column-text-str stmt 0)
                                                        :junk-allowed t))
                          0)
                      0))
                0))
        (error (e) (progn (%store-failed e) 0))))))

(defun %store-set-user-version (n)
  "Record migration version N. T when it was recorded.

The number is interpolated because a `pragma` takes no bound parameters — and it is an integer this
file chooses, never anything a caller passes, so there is nothing to inject."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db (format nil "pragma user_version = ~d" n))
            (= +sqlite-done+ (%sq-step stmt)))
        (error (e) (progn (%store-failed e) nil))))))

(defparameter +todos-orphan-migration+ 1
  "The version at which the pre-workspace rows were adopted. See `store-adopt-orphan-todos`.")

(defparameter +todos-legacy-import-migration+ 2
  "The version at which the old `todos.sexp` was imported. See `store-legacy-import-pending-p`.

**A SECOND VERSION, and the reason is the same defect twice.** MEASURED on the operator's own head:
`t5 \"plain quoting\"` and `t6 \"push leticl to github\"` were deleted from the table, the head was
restarted, and BOTH CAME BACK under a different workspace. The source was `~/.config/leticl/todos.sexp`,
still holding them, and the import branch of `load-operator-todos` re-created them because the table was
empty. Its docstring says *\"AND IT IMPORTS THE OLD FILE ONCE\"* — and it ran whenever the table was
empty for the project asking, which is not once. Exactly the shape `store-adopt-orphan-todos` had, found
by exactly the same act: deleting the rows and watching them return.")

(defun store-legacy-import-pending-p ()
  "T when the one-time import of the old `todos.sexp` has NOT happened yet."
  (< (%store-user-version) +todos-legacy-import-migration+))

(defun store-mark-legacy-imported ()
  "Record that the old `todos.sexp` has had its one chance. T when it recorded the version."
  (when (< (%store-user-version) +todos-legacy-import-migration+)
    (%store-set-user-version +todos-legacy-import-migration+)))

(defun store-adopt-orphan-todos (workspace)
  "Give every row with no workspace to WORKSPACE. Returns how many moved.

**The rows that predate the column, and the only place a project is inferred rather than known.** See
`store-load-todos` for why this is a one-time report rather than a silent assignment. NIL or an empty
WORKSPACE adopts nothing: a head that does not yet know its project must not be the one to claim every
unowned row — that would hand them to whichever head started first."
  (sb-thread:with-recursive-lock (*store-lock*)
    (if (or (null workspace) (zerop (length workspace)))
      0
      (let ((db (%store-db)))
        (when db
          ;; **ONCE, AND THIS IS A CORRECTION TO A BLANKET UPDATE THAT RAN ON EVERY LOAD.**
          ;;
          ;; MEASURED, and it is the operator's report: *"wtf why all new session get plain quoting and
          ;; push leticl to github todos???"* — two rows they had finished with turned up in every new
          ;; session. The cause is this statement's shape, not anybody's mistake with the data: it was
          ;; `update operator_todo set workspace = ? where workspace = ''`, run from `store-load-todos`
          ;; on EVERY load, so every row with an empty workspace was claimed **permanently** by the
          ;; first workspace that happened to load. The docstring above says *"it happens once"* — the
          ;; docstring was right and the code did the opposite.
          ;;
          ;; The intent was a MIGRATION: rows written before the column existed have `''`, and they
          ;; need a home. A migration is identified by a version, and this is the first one — so
          ;; `pragma user_version` is the guard, and a row left ownerless afterwards stays ownerless,
          ;; which is the honest reading: it belongs to no project, so it shows in a head that does not
          ;; know its project rather than in all of them.
          (if (>= (%store-user-version) +todos-orphan-migration+)
              0
              (handler-case
                  (let ((moved (with-statement (stmt db "update operator_todo set workspace = ? where workspace = ''")
                                 (%bind-text stmt 1 workspace)
                                 (if (= +sqlite-done+ (%sq-step stmt))
                                     (%sq-changes db)
                                     0))))
                    ;; **THE VERSION IS SET WHETHER OR NOT ANYTHING MOVED**, or a database whose
                    ;; first loader found no orphans would look unmigrated for ever and the next
                    ;; workspace to ask would be handed the job — which is the same "whoever asks
                    ;; first" rule in a slower costume.
                    (%store-set-user-version +todos-orphan-migration+)
                    moved)
                (error (e) (progn (%store-failed e) 0)))))))))

(defun store-todo-seeded-p (workspace)
  "Has WORKSPACE already had its starter todos put in it? NIL when it has not, or when there is no store.

**NIL for *no store* as well as for *not seeded*, and that is the safe direction here**: a head with no
database has nowhere to record a seeding, so it must not seed — otherwise every start would add the
starter rows again, which is the duplicate-every-session defect this feature was extracted from."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
      (when (and db (plusp (length (or workspace ""))))
        (handler-case
            (with-statement (stmt db "select 1 from todo_seed where workspace = ?")
              (%bind-text stmt 1 workspace)
              (= +sqlite-row+ (%sq-step stmt)))
          (error (e) (progn (%store-failed e) nil)))))))

(defun store-mark-todo-seeded (workspace)
  "Record that WORKSPACE has had its starter todos. T when it was recorded."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
      (when (and db (plusp (length (or workspace ""))))
        (handler-case
            (with-statement (stmt db "insert or replace into todo_seed (workspace) values (?)")
              (%bind-text stmt 1 workspace)
              (= +sqlite-done+ (%sq-step stmt)))
          (error (e) (progn (%store-failed e) nil)))))))

(defun store-save-todo (item &optional seq workspace)
  "Insert or replace ITEM for WORKSPACE. SEQ is its place in the list; defaults to the item's own id order.

**`insert or replace` rather than a delete and an insert**: the id is the key, so a later save of the
same item is an edit, and doing it as two statements would leave a window with no row in it.

**WORKSPACE IS WRITTEN ON EVERY SAVE, including an edit.** A row edited by a head that knows its
project keeps that project; the alternative — leaving the column alone on update — would let a row
keep a stale owner after a rename. NIL is stored as the empty string, which is the orphan marker
`store-adopt-orphan-todos` looks for."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "insert or replace into operator_todo
                                     (id, seq, title, detail, status, workspace) values (?,?,?,?,?,?)")
            (%bind-text stmt 1 (getf item :id))
            (%sq-bind-int64 stmt 2 (or seq
                                       (ignore-errors (parse-integer (or (getf item :id) "")
                                                                     :junk-allowed t))
                                       0))
            (%bind-text stmt 3 (getf item :content))
            (%bind-text stmt 4 (getf item :detail))
            (%bind-text stmt 5 (or (getf item :status) "open"))
            (%bind-text stmt 6 (or workspace ""))
            (= +sqlite-done+ (%sq-step stmt)))
        (error (e) (%store-failed e)))))))

(defun store-todo-id-ceiling ()
  "The highest `tN` id anywhere in the table, whatever project it belongs to — or 0.

**Across EVERY workspace, deliberately.** Ids are the store's PRIMARY KEY over the whole file, so a
counter raised past only the current project's ids can still mint one that another project holds — and
`insert or replace` then OVERWRITES a real row instead of adding one. That is `note-todo-ids`' own
measured defect, one project along; with todos now per-project it would have been introduced by the
very change that scoped them.

The parse is in SQL because the ids are `tN` and the alternative is loading every row of every project
to look at them. `substr(id, 2)` drops the namespace letter and `cast(... as integer)` turns the rest
into a number — and a row whose id is not that shape casts to 0, which is below every real id and so
cannot raise the ceiling by accident. That is the safe direction: an unreadable id must not make the
counter skip a range it never used."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "select max(cast(substr(id, 2) as integer)) from operator_todo
                              where id like 't%'")
            (if (= +sqlite-row+ (%sq-step stmt))
                (let ((sap (%sq-column-text-ptr stmt 0)))
                  (if (and sap (not (sb-sys:sap= sap (sb-sys:int-sap 0))))
                      (or (ignore-errors (parse-integer (%sq-column-text-str stmt 0) :junk-allowed t)) 0)
                      0))
                0))
        (error (e) (progn (%store-failed e) 0)))))))

(defun store-delete-todo (id)
  "Remove the row ID. T when the statement ran."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "delete from operator_todo where id = ?")
            (%bind-text stmt 1 id)
            (= +sqlite-done+ (%sq-step stmt)))
        (error (e) (%store-failed e)))))))

(defun store-replace-todos (items workspace)
  "Rewrite this WORKSPACE's list: its rows deleted, ITEMS inserted in order. T when it ran.

**For the migration and for a test**, not for the interactive path: an add saves one row and a
removal deletes one, because a wholesale rewrite on every keystroke is a transaction per key and a
window in which the list is not on disk at all.

**It deletes only ITS OWN project's rows.** A `delete from operator_todo` with no key was the shape
that made this file's list one list; keeping it here would mean a migration in one workspace silently
emptying every other project's todos."
  (sb-thread:with-recursive-lock (*store-lock*)
    (let ((db (%store-db)))
    (when db
      (handler-case
          (progn
            (with-statement (stmt db "delete from operator_todo where workspace = ?")
              (%bind-text stmt 1 (or workspace ""))
              (%sq-step stmt))
            ;; **AND EVERY INSERT IS CHECKED, BECAUSE THIS FUNCTION IS A DELETE FIRST.** It ran as
            ;; written even when the inserts failed: the rows came out, nothing went back, and it
            ;; answered T. MEASURED — that is how a probe emptied this table and reported success.
            ;; A wholesale rewrite that cannot report a failed rewrite is worse than no rewrite,
            ;; because the caller has already lost the old rows by the time it asks.
            (let ((lost nil))
              (loop for item in items for i from 1
                    unless (store-save-todo item i workspace)
                      do (setf lost t))
              (if lost
                  (progn (setf *store-unavailable* "the list could not be written back")
                         nil)
                  t)))
        (error (e) (%store-failed e)))))))
