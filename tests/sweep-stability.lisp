;;;; tests/sweep-stability.lisp — the 2026-10-11 sweep's tests for the stability area (TODO.md, "Sweep 2026-10-11").
(in-package #:leticl/tests)

;;; Every test here is one line of `TODO.md` B.11, the stability list: a thing that could
;;; block, kill or silently lose on a head the operator keeps open for days. None of them
;;; needs a daemon — a pipe stands in for a stalled socket, a second sqlite connection for
;;; a second head, a thread holding the paint lock for an eval — because the property under
;;; test is what THIS head does when the other side misbehaves, and the other side is
;;; easiest to make misbehave when it is a fixture.

(defun %sweep-source (relative)
  "One file of THIS checkout's source, located through ASDF rather than `*load-truename*`
— a worktree's test must read the worktree's file, and the fallback `%repo-file` takes
(the main checkout) is the one file that does not carry the change under test."
  (uiop:read-file-string
   (merge-pathnames relative (asdf:system-source-directory :leticl))))

(defun %full-pipe-stream ()
  "A character fd-stream on the write end of a pipe whose buffer is FULL, and the read fd
to close afterwards. Nothing reads the pipe, so the next `write(2)` would block for ever —
which is exactly what a daemon that has stopped reading its socket looks like to a head."
  (multiple-value-bind (rfd wfd) (sb-posix:pipe)
    (sb-posix:fcntl wfd sb-posix:f-setfl
                    (logior (sb-posix:fcntl wfd sb-posix:f-getfl) sb-posix:o-nonblock))
    (let ((chunk (make-array 65536 :element-type '(unsigned-byte 8) :initial-element 10)))
      (loop (multiple-value-bind (n errno) (sb-unix:unix-write wfd chunk 0 (length chunk))
              (declare (ignore errno))
              (when (or (null n) (zerop n)) (return)))))
    (values (sb-sys:make-fd-stream wfd :output t :element-type 'character
                                       :external-format :utf-8 :buffering :none)
            rfd)))

;;; ------------------------------------------------- B.11: writes to a stalled daemon ;;;

(def-test a-write-to-a-stalled-socket-times-out-instead-of-blocking (:suite leticl)
  "**A daemon that stopped reading used to stop the head.** `write-frame` was `write-string`
+ `force-output` on a blocking fd, and every ack, screen answer and `tick-peek` runs on the
main loop — so a full socket buffer meant no paint, no keys, and `/quit` hanging on its own
detach. Now the fd is asked first, with a deadline: a pipe nobody reads, filled to the brim,
signals `write-timeout` within the deadline and the frame is not written."
  (multiple-value-bind (stream rfd) (%full-pipe-stream)
    (unwind-protect
         (let ((t0 (get-internal-real-time)))
           (signals leticl::write-timeout
             (leticl::write-frame "{\"frame\":\"ack\"}" stream :timeout 0.1))
           (is (< (/ (- (get-internal-real-time) t0) internal-time-units-per-second) 2)
               "and it came back within the deadline, not after the daemon woke up")
           ;; the condition is an ERROR, so `%send`'s existing guard sees it
           (is (subtypep 'leticl::write-timeout 'error)))
      (ignore-errors (close stream :abort t))
      (ignore-errors (sb-posix:close rfd)))))

(def-test a-timed-out-send-marks-the-head-disconnected-and-says-so (:suite leticl)
  "`%send` on a stalled socket: the frame is dropped, `head-connected` goes NIL — which is
what hands the socket to the reconnect path on the next pass — and the status note names
the cause. A string-stream wire (every other test's fixture) has no fd and is written at
once, which is the second half of the same claim."
  (multiple-value-bind (stream rfd) (%full-pipe-stream)
    (unwind-protect
         (let ((head (%make-head))
               (leticl::*write-timeout-secs* 0.1))
           (setf leticl::*daemon-seat* nil leticl::*skew-override-seat* nil)
           (setf (leticl::head-stream head) stream (head-connected head) t)
           (leticl::%send head (leticl::make-ack 1 0 0))
           (is (not (head-connected head)) "the head is DISCONNECTED, not blocked")
           (is (search "stopped reading" (or (head-status-note head) ""))
               "and the note says why: ~s" (head-status-note head)))
      (ignore-errors (close stream :abort t))
      (ignore-errors (sb-posix:close rfd))))
  ;; the fixture wire is not an fd-stream: written at once, no deadline consulted
  (let* ((head (%make-head))
         (wire (%wire head))
         (leticl::*write-timeout-secs* 0.1))
    (leticl::%send head (leticl::make-ack 2 0 0))
    (is (equal "ack" (getf (first (%sent wire)) :frame))
        "a stream without an fd is written straight away")))

(def-test the-detach-at-exit-has-a-deadline-of-its-own (:suite leticl)
  "`run`'s cleanup binds the write deadline to ONE second around the detach: a head that is
leaving owes the operator their terminal more than it owes a dead daemon a goodbye, and
`leave-tui` runs after the `ignore-errors` whatever the detach did. Pinned in the source,
because `run` needs a tty and a daemon to execute."
  (let ((src (%sweep-source "src/head/lifecycle.lisp")))
    (is (search "(let ((*write-timeout-secs* 1))" src)
        "the detach's deadline is bound beside the `%send`")
    (is (< (search "(let ((*write-timeout-secs* 1))" src)
           (search "(hack-stop head)" src))
        "and it is in the `unwind-protect` cleanup, before `hack-stop`")))

;;; ------------------------------------------------------- B.11: one slow eval ;;;

(def-test the-painter-skips-a-frame-while-an-eval-holds-the-lock (:suite leticl)
  "`%render-and-paint` took the paint lock with no timeout while the eval socket holds it
for an eval's whole duration: one `(loop)` pushed by mistake and the head never painted
again. Now the lock is TRIED — held, the frame is skipped, `head-dirty` is left set so the
next pass asks again, and the call answers `:busy` at once."
  (let ((head (%make-head))
        (held (sb-thread:make-semaphore))
        (release (sb-thread:make-semaphore)))
    (setf (head-dirty head) t)
    (let ((holder (sb-thread:make-thread
                   (lambda ()
                     (sb-thread:with-mutex ((leticl::paint-lock))
                       (sb-thread:signal-semaphore held)
                       (sb-thread:wait-on-semaphore release)))
                   :name "test eval holding the paint lock")))
      (sb-thread:wait-on-semaphore held)
      (unwind-protect
           (let ((t0 (get-internal-real-time)))
             (is (eq :busy (leticl::%render-and-paint head))
                 "the painter does not wait on an eval")
             (is (< (/ (- (get-internal-real-time) t0) internal-time-units-per-second) 1)
                 "and it came back at once")
             (is (head-dirty head) "the frame it owed is still owed"))
        (sb-thread:signal-semaphore release)
        (sb-thread:join-thread holder :default nil :timeout 5)))))

(def-test a-runaway-eval-is-interrupted-and-reported (:suite leticl)
  "**`with-deadline` does not interrupt a tight loop — measured — and `with-timeout`
does.** An eval of `(loop)` comes back as a reply carrying `sb-ext:timeout` within the
deadline, and the head is left dirty as after every failed eval. The timeout is a
`serious-condition` and not an `error`, like the stack exhaustion the review found; the
eval's guard says `serious-condition` for both.

**The exhaustion itself is NOT exercised here, and that is a measurement too**: `sbcl
--script` implies `--lose-on-corruption`, under which a control-stack guard-page hit is a
FATAL lossage (*\"Control stack exhausted, fault: …\"*, the whole suite gone) and never a
condition — tried, 2026-10-11. The frozen head is saved without that flag, which is where
the review verified the condition is catchable. So the suite pins the type facts and the
guard's spelling, and leaves the live exhaustion to the head."
  (let ((head (%make-head))
        (leticl::+hack-eval-timeout+ 0.2))
    (setf (head-dirty head) nil)
    (multiple-value-bind (value condition ms) (leticl::hack-eval-form head '(loop))
      (is (null value))
      (is (typep condition 'sb-ext:timeout)
          "a `(loop)` is interrupted and reported, not left holding the lock: ~s" condition)
      (is (not (typep condition 'error)) "and it is not an ERROR — the old guard missed it")
      (is (< ms 2000) "within the deadline (~d ms)" ms)
      (is (head-dirty head) "and the head is dirty, so the failure is drawn")))
  (is (not (subtypep 'storage-condition 'error))
      "a stack exhaustion is a STORAGE-CONDITION, which is not an ERROR — the review's finding")
  (is (subtypep 'storage-condition 'serious-condition) "but it is a SERIOUS-CONDITION")
  (let ((hack (%sweep-source "src/hack.lisp")))
    (is (search "(serious-condition (e) (setf (head-dirty head) t) (values nil e (ms)))" hack)
        "and the eval's own guard catches that class")))

;;; ------------------------------------------------------- B.11: the ticks ;;;

(def-test a-tick-that-signals-is-said-once-and-counted-every-time (:suite leticl)
  "One `handler-case` per tick: the first failure is a status note naming the tick, the
second is a count and no note (a note re-set 500 times a second is a status line nobody
else can use), and a `storage-condition` is caught as readily as an `error`."
  (let ((head (%make-head))
        (leticl::*tick-failures* nil)
        (calls 0))
    (flet ((bad (h) (declare (ignore h)) (incf calls) (error "git exploded")))
      (is (null (leticl::%run-tick head 'tick-git #'bad)) "the failure is contained")
      (is (search "tick-git failed: git exploded" (or (head-status-note head) ""))
          "and SAID, naming the tick: ~s" (head-status-note head))
      (leticl::clear-note head)
      (leticl::%run-tick head 'tick-git #'bad)
      (leticl::%run-tick head 'tick-git #'bad)
      (is (null (head-status-note head)) "the second and third failures are not said again")
      (is (equal '((tick-git . 3)) leticl::*tick-failures*) "but every one is counted")
      (is (= 3 calls)))
    (is (null (leticl::%run-tick head 'tick-peek
                                 (lambda (h) (declare (ignore h)) (error 'storage-condition))))
        "a STORAGE-CONDITION in a tick is caught too")
    (is (= 1 (cdr (assoc 'tick-peek leticl::*tick-failures*))))
    ;; a tick that works is run and its value returned — `attach-overdue-p`'s answer is used
    (is (eq :fine (leticl::%run-tick head 'tick-notice (lambda (h) (declare (ignore h)) :fine))))))

(def-test every-tick-in-the-run-loop-is-guarded (:suite leticl)
  "The loop's body names its ticks through `%run-tick` and nowhere bare — pinned in the
source, because `run-loop` runs until the head stops."
  (let* ((src (%sweep-source "src/head/op-call.lisp"))
         (loop-start (search "(defun run-loop (head)" src))
         (body (subseq src loop-start)))
    (dolist (tick '("tick-notice" "tick-stop-request" "tick-op-calls" "tick-dash-feeds"
                    "tick-git" "tick-peek" "tick-dash-watchers" "attach-overdue-p"
                    "%answer-screen-requests"))
      (is (search (format nil "'~a" tick) body) "~a is run through %run-tick" tick)
      (is (not (search (format nil "~%             (~a head)" tick) body))
          "~a is not also called bare" tick))))

;;; -------------------------------------------- B.11: a helper thread's death ;;;

(defclass %exploding-stream (trivial-gray-streams:fundamental-character-input-stream)
  ((condition :initarg :condition :reader %exploding-condition))
  (:documentation "A stream whose first read signals the condition it was given — a
`storage-condition` by default, the class of thing an `error` guard lets through."))

(defmethod trivial-gray-streams:stream-read-char ((s %exploding-stream))
  (error (%exploding-condition s)))

(def-test the-reader-posts-disconnected-on-a-serious-condition (:suite leticl)
  "`%reader-loop` caught `error` only. A `storage-condition` out of its read — not an
`error` — escaped the thread, and in a `--disable-debugger` image that is the process,
with the terminal raw. Now it posts `(:disconnected STREAM)` with the stream it was on
(so a stale reader's goodbye is still told apart from the live one's) and a `read-error`
warning, and RETURNS."
  (let* ((head (%make-head))
         (stream (make-instance '%exploding-stream :condition 'storage-condition)))
    (setf (leticl::head-stream head) stream)
    (finishes (leticl::%reader-loop head))
    (let ((posted (sb-concurrency:receive-pending-messages (leticl::head-frames head))))
      (is (equal (list :disconnected stream) (first posted))
          "the marker, naming the stream: ~s" (first posted))
      (is (equal "read-error" (getf (second posted) :code))
          "and the warning that says what happened: ~s" (second posted)))))

(def-test the-input-loop-and-the-eval-guards-catch-serious-conditions (:suite leticl)
  "The same spelling at every helper-thread guard: `%input-loop`, the three guards in
`hack.lisp`, and `main`'s debugger hook `setf` as a GLOBAL so a helper thread's unhandled
condition restores the terminal — a `let` binding is seen by the main thread only."
  (let ((io (%sweep-source "src/head/io.lisp"))
        (hack (%sweep-source "src/hack.lisp"))
        (freeze (%sweep-source "freeze.lisp")))
    (is (search "(serious-condition (e)
            ;; said, not swallowed" io) "the input loop's guard")
    (is (search "(serious-condition () nil)" hack)
        "the connection's guard says serious-condition")
    (is (search "(serious-condition () (return))" hack)
        "and so does the reply's")
    (is (<= 4 (count-substring "(serious-condition (" hack))
        "the accept loop, the connection, the reply and the handler all say serious-condition")
    (is (search "(setf sb-ext:*invoke-debugger-hook*" freeze)
        "the restoring hook is the global value, not a binding")))

(defun count-substring (needle haystack)
  (loop with start = 0 and n = 0
        for pos = (search needle haystack :start2 start)
        while pos do (incf n) (setf start (1+ pos))
        finally (return n)))

;;; ----------------------------------------------- B.11: two heads on one store ;;;

(def-test store-replace-todos-is-one-transaction-and-busy-is-not-silent (:suite leticl)
  "A second connection holds the write lock (as a second head would, for the length of its
own commit — here, for the length of the test). The wholesale rewrite then neither deletes
nor half-inserts: it waits `*store-busy-timeout-ms*`, fails as a whole, rolls back, and the
OLD list is still on disk. And a single save under the same lock answers NIL with the
reason in `*store-unavailable*` — the caller's `todo not saved: …` note — rather than NIL
with nothing anywhere."
  (let ((leticl::*store-path-override* (format nil "/tmp/leticl-store-busy-~a.db" (random 1000000)))
        (leticl::*store-busy-timeout-ms* 100))
    (unwind-protect
         (progn
           (leticl::store-close)
           (is (not (null leticl::*sqlite-library*)) "libsqlite3 loaded, which everything below needs")
           (is (leticl::store-save-todo (list :id "t1" :content "one" :detail "" :status "open") 1 "p"))
           (is (leticl::store-save-todo (list :id "t2" :content "two" :detail "" :status "open") 2 "p"))
           ;; the second head: its own connection, holding the write lock
           (let ((cell (sb-alien:make-alien leticl::%sq-db)))
             (is (= leticl::+sqlite-ok+
                    (leticl::%sq-open (namestring leticl::*store-path-override*) cell)))
             (let ((other (sb-alien:deref cell)))
               (unwind-protect
                    (progn
                      (is (= leticl::+sqlite-ok+
                             (leticl::%sq-exec other "begin immediate" (sb-sys:int-sap 0)
                                                (sb-sys:int-sap 0) (sb-sys:int-sap 0)))
                          "the other connection holds the write lock")
                      (let ((t0 (get-internal-real-time)))
                        (is (null (leticl::store-replace-todos
                                   (list (list :id "n1" :content "new" :detail "" :status "open"))
                                   "p"))
                            "the rewrite reports failure rather than running half")
                        (is (< 0.05 (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
                            "after waiting the busy timeout for the lock"))
                      (is (search "locked" (or leticl::*store-unavailable* ""))
                          "and the reason names the lock: ~s" leticl::*store-unavailable*)
                      (is (null (leticl::store-save-todo
                                 (list :id "t3" :content "three" :detail "" :status "open") 3 "p"))
                          "a single save under the lock fails too")
                      (is (search "locked" (or leticl::*store-unavailable* ""))
                          "and NOT silently: ~s" leticl::*store-unavailable*))
                 (leticl::%sq-exec other "rollback" (sb-sys:int-sap 0) (sb-sys:int-sap 0) (sb-sys:int-sap 0))
                 (leticl::%sq-close other)
                 (sb-alien:free-alien cell))))
           ;; the lock is gone: the old list is whole, and the store heals on the next call
           (is (equal '("t1" "t2") (mapcar (lambda (i) (getf i :id)) (leticl::store-load-todos "p")))
               "the OLD list is on disk, whole — nothing was deleted without its replacement")
           (is (leticl::store-replace-todos
                (list (list :id "n1" :content "new" :detail "" :status "open")) "p")
               "and the same rewrite runs once the lock is released")
           (is (equal '("n1") (mapcar (lambda (i) (getf i :id)) (leticl::store-load-todos "p")))))
      (leticl::store-close)
      (dolist (suffix '("" "-wal" "-shm"))
        (let ((f (concatenate 'string leticl::*store-path-override* suffix)))
          (when (probe-file f) (ignore-errors (delete-file f))))))))

;;; ------------------------------------------------- B.11: head.toml in place ;;;

(def-test head-toml-is-written-beside-and-renamed-over (:suite leticl)
  "`save-prefs` wrote the file with `:if-exists :supersede` — emptied first, then filled —
so a head that died mid-write, or two heads writing at once, left a truncated file the next
start read as *no preferences*. Now the bytes go to `.head.toml.tmp` beside it and
`rename(2)` swaps them in: a reader sees the old file whole or the new one whole. Measured
the hard way: a directory that refuses the temp file leaves the old file byte for byte."
  (let* ((dir (format nil "/tmp/leticl-prefs-~a/" (random 1000000)))
         (path (concatenate 'string dir "head.toml"))
         (p (leticl::make-prefs)))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (is (leticl::save-prefs p path) "the first save writes")
           (is (probe-file path))
           (is (null (probe-file (concatenate 'string dir ".head.toml.tmp")))
               "and leaves no temp file behind")
           (let ((before (uiop:read-file-string path)))
             (is (search "diff = " before))
             ;; the directory now refuses a new file: the temp file cannot be made
             (sb-posix:chmod dir #o500)
             (setf (getf p :diff) "unified")
             (signals error (leticl::save-prefs p path))
             (sb-posix:chmod dir #o700)
             (is (equal before (uiop:read-file-string path))
                 "a save that could not complete left the old file BYTE FOR BYTE")
             (is (null (probe-file (concatenate 'string dir ".head.toml.tmp"))))))
      (ignore-errors (sb-posix:chmod dir #o700))
      (ignore-errors (uiop:delete-directory-tree (pathname dir) :validate t)))))

;;; --------------------------------------------------- B.11: reconnect ;;;

(def-test reconnect-retires-the-old-reader-before-closing-its-stream (:suite leticl)
  "Closing an fd-stream another thread is mid-`read-line` on is not safe in SBCL.
`%retire-reader` shuts the socket down first — the blocked read returns EOF, the reader
posts its goodbye with ITS stream and returns — joins it, and only then closes. A real
unix socket pair, so the read is a real blocked `read(2)`."
  (let* ((path (format nil "/tmp/leticl-retire-~a.sock" (random 1000000)))
         (listener (make-instance 'sb-bsd-sockets:local-socket :type :stream))
         (head (%make-head)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind listener path)
           (sb-bsd-sockets:socket-listen listener 1)
           (let* ((client (leticl::connect-unix path))
                  (server (sb-bsd-sockets:socket-accept listener))
                  (server-stream (sb-bsd-sockets:socket-make-stream
                                  server :input t :output t :element-type 'character
                                  :external-format :utf-8 :buffering :none)))
             (setf (leticl::head-stream head) server-stream
                   (leticl::head-reader head)
                   (sb-thread:make-thread (lambda () (leticl::%reader-loop head))
                                          :name "test reader"))
             (sleep 0.05)
             (is (sb-thread:thread-alive-p (leticl::head-reader head))
                 "the reader is blocked in its read")
             (let ((t0 (get-internal-real-time)))
               (finishes (leticl::%retire-reader head))
               (is (< (/ (- (get-internal-real-time) t0) internal-time-units-per-second) 1)
                   "and retiring it took the EOF route, not the terminate-after-timeout one"))
             (is (not (sb-thread:thread-alive-p (leticl::head-reader head)))
                 "the old reader is gone before the stream is closed")
             (is (not (open-stream-p server-stream)) "and the stream is closed after")
             (let ((posted (sb-concurrency:receive-pending-messages (leticl::head-frames head))))
               (is (equal (list :disconnected server-stream) (first posted))
                   "its goodbye names the stream it was on: ~s" (first posted)))
             (ignore-errors (close client))))
      (ignore-errors (sb-bsd-sockets:socket-close listener))
      (ignore-errors (delete-file path)))))

(def-test an-ack-passes-the-skew-lock (:suite leticl)
  "While an attach is read-only (an older daemon), `%send` drops every frame but the attach.
It dropped the ACK too — the one frame the daemon waits on to move its cursor — so a locked
head read frames and signed for none. The ack is protocol 1, as the attach is, and spends
nothing of the operator's."
  (let* ((head (%make-head))
         (wire (%wire head)))
    (setf leticl::*daemon-seat* (cons 4242 1) leticl::*skew-override-seat* nil)
    (unwind-protect
         (progn
           (is (leticl::skew-locked-p) "the fixture: a daemon speaking protocol 1 locks the head")
           (leticl::%send head (leticl::make-settings))
           (is (null (%sent wire)) "a settings ask is still dropped while locked")
           (leticl::%send head (leticl::make-ack 9 1 0))
           (let ((sent (%sent wire)))
             (is (equal "ack" (getf (first sent) :frame)) "the ack goes out: ~s" sent)))
      (setf leticl::*daemon-seat* nil))))

;;; ---------------------------------------- B.11: a frame that fails to fold ;;;

(def-test a-frame-that-fails-to-fold-is-not-acked-and-files-a-row (:suite leticl)
  "`last-seq` moved BEFORE `%handle-frame`, so a frame whose fold signalled was acked as
read — a silence, where the rule is *a duplicate, never a silence*. Now the seq is taken
only from a fold that succeeded, and the failure files a row in the conversation with the
wire line and counts it with the frames the decoder could not read."
  (let* ((head (%make-head))
         (before leticl::*unreadable-total*)
         (bad '(:frame "event" :seq 7 :event 42 :wire-line "{\"frame\":\"event\",\"seq\":7,\"event\":42}")))
    (multiple-value-bind (outcome seq) (leticl::%fold-frame head bad)
      (is (null outcome))
      (is (null seq) "no seq from a fold that failed — the mark does not move over it"))
    (is (= (1+ before) leticl::*unreadable-total*) "counted once")
    (let ((rows (map 'list (lambda (i) (ignore-errors (getf (getf i :item) :text)))
                     (leticl::session-items (head-session head)))))
      (is (some (lambda (r) (and r (search "the fold signalled" r) (search "\"seq\":7" r))) rows)
          "and a VISIBLE row names the failure and carries the line: ~s" rows))
    (is (typep leticl::*last-render-error* 'error) "the render gate still sees it")
    ;; a good frame after it in the same pass: the mark passes over, and the row remains
    (sb-concurrency:send-message (leticl::head-frames head) bad)
    (sb-concurrency:send-message (leticl::head-frames head) '(:frame "event" :seq 8))
    (multiple-value-bind (rendered filtered last-seq) (leticl::%fold-pass head)
      (declare (ignore rendered filtered))
      (is (= 8 last-seq) "a later good frame moves the mark — the loss is the row, not a silence"))
    ;; the bad frame alone: nothing is acked, so the daemon resends — a duplicate
    (sb-concurrency:send-message (leticl::head-frames head) bad)
    (multiple-value-bind (rendered filtered last-seq) (leticl::%fold-pass head)
      (declare (ignore rendered filtered))
      (is (= 0 last-seq) "alone, it leaves the mark where it was"))))

;;; ------------------------------------- B.11: evals concurrent with the fold ;;;

(def-test the-fold-pass-skips-while-an-eval-holds-the-lock-and-loses-nothing (:suite leticl)
  "The paint lock covered painting only; an eval ran concurrently with the fold. Now the
drain and the key handling take the lock with the painter's zero wait: held, the pass
skips and the mailboxes keep what arrived; released, the next pass folds it all."
  (let ((head (%make-head))
        (held (sb-thread:make-semaphore))
        (release (sb-thread:make-semaphore)))
    (sb-concurrency:send-message (leticl::head-frames head) '(:frame "event" :seq 3))
    (let ((holder (sb-thread:make-thread
                   (lambda ()
                     (sb-thread:with-mutex ((leticl::paint-lock))
                       (sb-thread:signal-semaphore held)
                       (sb-thread:wait-on-semaphore release)))
                   :name "test eval holding the paint lock")))
      (sb-thread:wait-on-semaphore held)
      (unwind-protect
           (multiple-value-bind (rendered filtered last-seq busy) (leticl::%fold-pass head)
             (is (eq :busy busy) "the pass is skipped, not waited")
             (is (and (= 0 rendered) (= 0 filtered) (= 0 last-seq)))
             (is (= 1 (sb-concurrency:mailbox-count (leticl::head-frames head)))
                 "and the frame is still in the mailbox"))
        (sb-thread:signal-semaphore release)
        (sb-thread:join-thread holder :default nil :timeout 5)))
    (multiple-value-bind (rendered filtered last-seq busy) (leticl::%fold-pass head)
      (declare (ignore rendered filtered))
      (is (null busy))
      (is (= 3 last-seq) "the next pass folds what waited")
      (is (= 0 (sb-concurrency:mailbox-count (leticl::head-frames head)))))))

(def-test the-fold-pass-costs-less-than-the-idle-wait (:suite leticl)
  "The loop's idle wait is 2 ms (`*idle-poll-ms*`, R57) and a key must not wait on the lock
instead. An uncontended grab/release with two empty drains measured 0.05 us a pass on this
box, 2026-10-11 — the bound here is a hundred times that, so a regression of two orders of
magnitude is caught without the test flaking on a loaded machine."
  (let* ((head (%make-head))
         (n 5000)
         (t0 (get-internal-real-time)))
    (dotimes (i n) (leticl::%fold-pass head))
    (let ((us (/ (* 1e6 (- (get-internal-real-time) t0)) internal-time-units-per-second n)))
      (is (< us 50) "~,3f us per idle fold pass (idle wait is ~a ms)" us (* 1000 leticl::*idle-poll-ms*)))))

;;; ------------------------------------------------------ B.11: leave-raw ;;;

(def-test leave-raw-applies-now-rather-than-draining-a-stalled-pty (:suite leticl)
  "`TCSADRAIN` waits for every byte queued on the pty, and a pty whose terminal has stopped
reading never finishes — so `leave-raw`, which runs on the way out, blocked the exit with
the terminal half-restored. `TCSANOW` applies the saved attributes at once. Pinned in the
source, because a stalled pty is not something a test can make without one."
  (let ((src (%sweep-source "src/term.lisp")))
    (is (= 0 leticl::+tcsanow+) "glibc's TCSANOW")
    (is (search "(%tcsetattr *raw-fd* +tcsanow+ *saved-termios*)" src)
        "leave-raw applies now")
    (is (search "(%tcsetattr fd +tcsadrain+ *raw-termios*)" src)
        "and enter-raw, at startup with an empty queue, still drains")))
