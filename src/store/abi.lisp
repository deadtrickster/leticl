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
;;;; **A CHANGE TO THIS FILE NEEDS A RESTART, NOT A PUSH — and that is MEASURED, not a precaution.**
;;;; Pushing it three times into one live head left the image in a state where `store-load-todos`
;;;; faulted with *"Unhandled memory fault at #x0"* while a FRESH image read the same database
;;;; correctly (`READ: ("t5" "t6")`), the `sqlite3` CLI showed the rows intact, and the whole suite
;;;; passed. The head survived it — the handler catches the fault and records it — but the store
;;;; answered nothing for the rest of that session, and it looked exactly like a store that was
;;;; empty.
;;;;
;;;; The class is the pusher's own: a re-evaluated `define-alien-type` in a live image is a
;;;; LAYOUT change, which is why `defstruct` and `defclass` are already skipped by `--file`. These
;;;; routines are called correctly by the frozen image and by every fresh load; what is not safe is
;;;; redefining them underneath callers that were compiled against them.
;;;;
;;;; **`prepare` + `bind` + `step`, never string interpolation.** A todo's title is arbitrary
;;;; prose that may contain any byte, and building SQL by concatenation is the one way to get that
;;;; wrong that no amount of testing catches — the value and the syntax live in the same string.
;;;; The one statement that IS assembled by hand is a `create table`, whose text this file owns.

(in-package #:leticl)

;;; ------------------------------------------------------------- the C ABI ;;;

(defvar *sqlite-library*
  (handler-case (progn (sb-alien:load-shared-object "libsqlite3.so.0") t)
    (error () nil))
  "Did `libsqlite3` load? NIL means the head runs without a store.

**`defvar`, AND THE REASON IS THE INITIALIZER AND NOT THE VARIABLE.** Every other tunable in this file
is a `defparameter`, and for a plain value that is the same thing; here it is not. `defparameter`
ASSIGNS ON EVERY EVALUATION, so pushing this file into a live head ran `load-shared-object` again on
EVERY PUSH — a dynamic-linker call on a process that already holds an open sqlite handle and compiled
alien routines resolved into that library. `defvar` assigns only when unbound, so the library is
loaded once for the life of the process, which is what a foreign library is: process-wide state, not
a setting somebody tunes.

**This is hardening, not a proven cause, and it is worth saying which.** The corruption warnings on
the operator's heads (`Memory fault at (nil)`, `pc=(nil)`) came from a store that had NO LOCK while
three threads used one connection — that is the defect, and `*store-lock*` is the fix. But repeating a
`load-shared-object` on a live process was pointless at best, and the one thing in this file that
touches the dynamic linker is not a thing to do per push while chasing a memory fault.

It stays a VARIABLE and not a `defconstant` for the reason the constants below record — the file
pusher skips constants — and a test can still set it, which is what the no-library path is exercised
with.

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

(sb-alien:define-alien-routine ("sqlite3_changes" %sq-changes) sb-alien:int
  (db %sq-db))
;; 
;; `sqlite3_changes` is how a WRITE reports how much it wrote. It is the only way to tell *the
;; statement ran* from *the statement matched nothing*, which are different facts: a `delete` of a
;; row that is not there succeeds and changes nothing, and the orphan adoption needs the count to know
;; whether it has anything to REPORT.

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

