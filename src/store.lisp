;;;; store.lisp — the head's OWN data, in sqlite.
;;;;
;;;; **The operator's ruling, and it is a convention rather than a preference:** *"regarding local
;;;; todo storage - use sqlite as always, not files."* Their other head keeps its data in
;;;; `sessions.db`, so a head that wrote a bespoke `.sexp` beside its preferences was inventing a
;;;; second kind of local storage in a tree that already has one.
;;;;
;;;; **A STORE OF ITS OWN, and not the daemon's `sessions.db`.** That file belongs to `harnessd` —
;;;; it is opened, migrated and written by another process, and a head that reached into it would
;;;; be the second writer on a database whose owner assumes it is the only one. What a head owns
;;;; locally is its own state, so this is `$XDG_DATA_HOME/leticl/head.db`: same engine, same
;;;; conventions (WAL, a table per kind of thing), a different owner.
;;;;
;;;; **`sb-alien` DIRECTLY, not a Rust shim or a CFFI dependency.** The tree already calls C this
;;;; way (`native/hl`, via `src/highlight.lisp`) and `libsqlite3.so` ships with the box, so the
;;;; alternative was a vendored binding for six functions. `sb-alien` is SBCL's own and needs no
;;;; build step, which matters because the head is frozen into an image and a new C dependency
;;;; would be a new thing to build.
;;;;
;;;; **`prepare` + `bind` + `step`, never string interpolation.** A todo's title is arbitrary
;;;; prose that may contain any byte, and building SQL by concatenation is the one way to get that
;;;; wrong that no amount of testing catches — the value and the syntax live in the same string.
;;;; The one statement that IS assembled by hand is a `create table`, whose text this file owns.

(in-package #:leticl)

;;; ------------------------------------------------------------- the C ABI ;;;

(defparameter *sqlite-library*
  (handler-case (progn (sb-alien:load-shared-object "libsqlite3.so.0") t)
    (error () nil))
  "Did `libsqlite3` load? NIL means the head runs without a store.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a constant could never
be moved on a running head — and this one is the switch a test uses to exercise the no-library path.

**The head must still work without it.** A head whose screen will not come up because a database
library is missing is worse than one that cannot remember its todos: the conversation is the
product, and this is a convenience beside it. `store-available-p` is what every caller asks.")

;; **`defparameter` AND NOT `defconstant`, and the live head is why.** The file pusher skips
;; constants — *"re-evaluating a defstruct leaves existing instances on the old layout"*, and a
;; constant is the same class — so on the first push of this file the three of them were SKIPPED and
;; the head answered `UNBOUND-VARIABLE +SQLITE-OK+` to a call that had nothing wrong with it. Every
;; other tunable in this tree is a `defparameter` for exactly this reason.
(defparameter +sqlite-ok+ 0)
(defparameter +sqlite-row+ 100)
(defparameter +sqlite-done+ 101)

(sb-alien:define-alien-type %sq-db sb-sys:system-area-pointer)
(sb-alien:define-alien-type %sq-stmt sb-sys:system-area-pointer)

(sb-alien:define-alien-routine ("sqlite3_open" %sq-open) sb-alien:int
  (filename sb-alien:c-string) (ppdb (* %sq-db)))
(sb-alien:define-alien-routine ("sqlite3_close" %sq-close) sb-alien:int
  (db %sq-db))
(sb-alien:define-alien-routine ("sqlite3_errmsg" %sq-errmsg) sb-alien:c-string
  (db %sq-db))
(sb-alien:define-alien-routine ("sqlite3_exec" %sq-exec) sb-alien:int
  (db %sq-db) (sql sb-alien:c-string) (callback sb-sys:system-area-pointer)
  (arg sb-sys:system-area-pointer) (errmsg (* sb-alien:c-string)))
(sb-alien:define-alien-routine ("sqlite3_prepare_v2" %sq-prepare) sb-alien:int
  (db %sq-db) (sql sb-alien:c-string) (nbytes sb-alien:int)
  (stmt (* %sq-stmt)) (tail (* sb-alien:c-string)))
(sb-alien:define-alien-routine ("sqlite3_bind_text" %sq-bind-text) sb-alien:int
  (stmt %sq-stmt) (index sb-alien:int) (text sb-alien:c-string)
  (nbytes sb-alien:int) (destructor sb-sys:system-area-pointer))
(sb-alien:define-alien-routine ("sqlite3_bind_int64" %sq-bind-int64) sb-alien:int
  (stmt %sq-stmt) (index sb-alien:int) (value sb-alien:long-long))
(sb-alien:define-alien-routine ("sqlite3_step" %sq-step) sb-alien:int
  (stmt %sq-stmt))
;; **THE POINTER, not a `c-string`, and a NULL column is why.** Declaring the return type as
;; `c-string` makes sb-alien convert it with `strlen`, and `strlen(NULL)` is a MEMORY FAULT —
;; *"Unhandled memory fault at #x0"*, MEASURED on the live head, where a column came back NULL and
;; took the whole eval with it. NULL is legitimate SQL (a row written before a column existed, a
;; hand-edited row, a table created by an older build), so the conversion has to be OURS.
(sb-alien:define-alien-routine ("sqlite3_column_text" %sq-column-text-ptr) sb-sys:system-area-pointer
  (stmt %sq-stmt) (column sb-alien:int))

;; **TWO BINDINGS FOR ONE C FUNCTION, and that is the NULL guard.** The `c-string` declaration is
;; what converts to a Lisp string, and it does so by `strlen` — so it may only be called once the
;; pointer is known to be non-NULL. So the pointer binding asks the question and this one answers it.
(sb-alien:define-alien-routine ("sqlite3_column_text" %sq-column-text-str) sb-alien:c-string
  (stmt %sq-stmt) (column sb-alien:int))

(defun %sq-column-text (stmt column)
  "COLUMN as a Lisp string, or NIL for SQL NULL.

NIL rather than an empty string, because the two are different facts about a row and the caller is
the only layer that knows which is honest for its column — `store-load-todos` reads a NULL detail as
no detail, and a NULL title as a row it will not draw."
  (let ((sap (%sq-column-text-ptr stmt column)))
    (when (and sap (not (sb-sys:sap= sap (sb-sys:int-sap 0))))
      (%sq-column-text-str stmt column))))
(sb-alien:define-alien-routine ("sqlite3_finalize" %sq-finalize) sb-alien:int
  (stmt %sq-stmt))

(defparameter +sqlite-transient+
  ;; `SQLITE_TRANSIENT` is `(sqlite3_destructor_type)-1`: it tells sqlite to take its OWN COPY of
  ;; a bound string, because ours is a Lisp string that the GC may move. Passing 0 (SQLITE_STATIC)
  ;; would hand sqlite a pointer into a Lisp object, which is the kind of bug that works until a
  ;; collection happens to run between the bind and the step.
  ;; **`(1- (ash 1 64))` and not `-1`**: `int-sap` is typed `unsigned-byte 64`, and `-1` reads as a
  ;; constant that "conflicts with its asserted type" — a WARNING, which this tree's build treats as
  ;; fatal (`caught 1 fatal ERROR condition` on the first attempt). The all-ones word IS -1 as a
  ;; pointer; spelling it unsigned is what lets the compiler accept it.
  (sb-sys:int-sap (1- (ash 1 64))))

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
  (and *sqlite-library*
       (not *store-unavailable*)
       (not (null (%store-db)))))

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
                                          status text not null default 'open')"
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
                           db))))
            (sb-alien:free-alien cell)
            (sb-alien:free-alien err)))))))

(defun store-close ()
  "Close the handle, if open. For a test between cases, and for a switch between stores."
  (when *store-handle*
    (%sq-close *store-handle*)
    (setf *store-handle* nil *store-file* nil)))

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
each site is how a reader checks it."
  (%sq-bind-text stmt index (or value "") -1 +sqlite-transient+))

;;; ------------------------------------------------------- the operator's rows ;;;

(defun store-load-todos ()
  "Every stored item, oldest first, as the plists `*operator-todos*` holds.

**NIL for a store that is not there**, which the caller cannot distinguish from an empty list — and
that is the honest answer rather than a guess: a head with no database and a head whose list is
empty both have nothing to draw, and inventing a difference would be inventing a claim."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "select id, title, detail, status from operator_todo order by seq")
            (let ((out nil))
              (loop while (= +sqlite-row+ (%sq-step stmt))
                    do (push (list :id (%sq-column-text stmt 0)
                                   :content (%sq-column-text stmt 1)
                                   :detail (or (%sq-column-text stmt 2) "")
                                   :status (or (%sq-column-text stmt 3) "open"))
                             out))
              (nreverse out)))
        (error (e) (setf *store-unavailable* (format nil "~a" e)) nil)))))

(defun store-save-todo (item &optional seq)
  "Insert or replace ITEM. SEQ is its place in the list; defaults to the item's own id order.

**`insert or replace` rather than a delete and an insert**: the id is the key, so a later save of the
same item is an edit, and doing it as two statements would leave a window with no row in it."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "insert or replace into operator_todo
                                     (id, seq, title, detail, status) values (?,?,?,?,?)")
            (%bind-text stmt 1 (getf item :id))
            (%sq-bind-int64 stmt 2 (or seq
                                       (ignore-errors (parse-integer (or (getf item :id) "")
                                                                     :junk-allowed t))
                                       0))
            (%bind-text stmt 3 (getf item :content))
            (%bind-text stmt 4 (getf item :detail))
            (%bind-text stmt 5 (or (getf item :status) "open"))
            (= +sqlite-done+ (%sq-step stmt)))
        (error (e) (setf *store-unavailable* (format nil "~a" e)) nil)))))

(defun store-delete-todo (id)
  "Remove the row ID. T when the statement ran."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (with-statement (stmt db "delete from operator_todo where id = ?")
            (%bind-text stmt 1 id)
            (= +sqlite-done+ (%sq-step stmt)))
        (error (e) (setf *store-unavailable* (format nil "~a" e)) nil)))))

(defun store-replace-todos (items)
  "Rewrite the whole list: every row deleted, ITEMS inserted in order. T when it ran.

**For the migration and for a test**, not for the interactive path: an add saves one row and a
removal deletes one, because a wholesale rewrite on every keystroke is a transaction per key and a
window in which the list is not on disk at all."
  (let ((db (%store-db)))
    (when db
      (handler-case
          (progn
            (with-statement (stmt db "delete from operator_todo")
              (%sq-step stmt))
            (loop for item in items for i from 1
                  do (store-save-todo item i))
            t)
        (error (e) (setf *store-unavailable* (format nil "~a" e)) nil)))))
