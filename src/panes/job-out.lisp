;;;; job-out.lisp — the job-output overlay: a running job's newest bytes, over the jobs list
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------- the job-output overlay ;;;

(defvar *job-out-total* 0
  "How many LINES the job-output overlay has in total, header and footer
included — what `*pane-lines*` must be set to for this pane, so `pane-scroll-max`
clamps against the whole window and not against the slice drawn from it. Set by
`job-out-lines`, which is the only place the total is known. The same arrangement
`*peek-total*` has, for the same reason.")

(defun open-job-out (job)
  "Open the job-output overlay on JOB, empty and waiting.

Opened at the KEYPRESS, before any answer: the pane says `reading…` rather than
showing nothing, and — the part that matters — `apply-event` takes a `JobOutput`
window only when an overlay is open for that job, so the overlay has to exist
before the frame goes out or this head would drop its own answer.

**`:answered` starts NIL and `:loading` starts T, and the two are not the same
fact** (R41): one means *a read is in flight*, the other *one has come back*. The
pane says `reading…` on the first and only the first, so an answer of ZERO BYTES
stops being indistinguishable from an answer that never came."
  (setf *job-out* (list :job job :state "" :never-ran nil :from 0 :to 0 :produced 0
                        :dropped 0 :lines nil :next nil :back nil :loading t
                        :answered nil :error nil))
  (reset-pane-scroll)
  *job-out*)

(defun close-job-out ()
  (setf *job-out* nil)
  (reset-pane-scroll))

(defun job-out-body (&optional (view *job-out*))
  "The overlay's BODY lines — the window the daemon sent, control characters
neutralised (`%without-control`) and PROGRESS LINES COLLAPSED (`%collapse-progress`).

 A job's output is whatever the command wrote, escape sequences included, and a
pane that repaints one hands the operator's terminal to a build log. And a
CAPTURED STREAM is a terminal RECORDING: `cargo`, `docker` and `npm` redraw ONE
row with `\r` and never a newline, so splitting on `\n` alone puts every update
on one row — `2%23%47%100%` — which is exactly what was being read before. The
terminal's own rule: `\r` returns to column 0 and what is written after it
overwrites, so a SHORTER final segment leaves the tail of a longer earlier one
standing (daemon `c37947d`)."
  (mapcar #'%without-control (%collapse-progress (getf view :lines))))

(defun %collapse-progress (lines)
  "LINES with `\r`-separated progress collapsed to what the terminal would show.

 A line like `\"  2%\r 23%\r 47%\r100%\"` is four redraws of ONE row; the
 terminal shows `100%` (the last write wins per column, and `100%` is long
 enough to cover ` 47%`). The rule is the terminal's: after the LAST `\r`, what
 remains overwrites from column 0, and the tail of a longer earlier segment
 stands. This is NOT \"take after the last \r\" — `\"longer\rshort\"` shows
 `shorter` on the terminal, and so it does here."
  (loop for l in lines
        for cr = (position #\return l)
        collect (if cr
                    (let* ((after (subseq l (1+ cr)))
                           (before (subseq l 0 cr)))
                      (if (>= (length after) (length before))
                          after
                          (concatenate 'string after (subseq before (length after)))))
                    l)))

(defun job-out-row-count (head)
  "How many lines the overlay has for its arrows to walk — what `pane-row-count`
answers for `:job-out`. The BODY's, not the rendered pane's: the header and the
footer are not rows a cursor may land on. Same as `peek-row-count`, and for the
same measured reason — a pane that answers 0 here has its arrows clamped to
`(1- 0)` while its own last line advertises that they scroll."
  (declare (ignorable head))
  (length (job-out-body)))

(defun job-out-lines (head cols &optional room)
  "One background job's retained output — the reference's `job_out_lines`
(app.rs:6828-6938), which is the pane the operator asked for: *\"on the job pane
when i press enter im not shown the tailed job output but brought back to the
conversation with /job <id> sent\"*.

    job output — j3
        exited 0 — bytes 0..16384 of 40000 (512 earlier bytes gone off the front)

        line one
        …
        arrows scroll · → next page · ← back · Esc to jobs

**The header is built from the OFFSETS, not from a parsed sentence.** That is the
whole of why the read is a `JobOutput` event and not the `Warning` `/job` replies
with: `/job`'s footer says `[exited 0 — bytes 0..16384 of 40000 produced]` in
prose a pane would have to take apart, and this arrives as numbers beside the
text (event.rs on `SessionEvent::JobOutput`).

`dropped` is disclosed in the HEADER rather than the footer: a window that begins
mid-log is otherwise read as the job's beginning, and that is a lie about what the
job did, not a detail about paging.

A TERMINAL, NOT A DOCUMENT, like `peek-lines`: the TAIL shows by default and the
scroll is clamped HERE, where the visible height is actually known. ROOM is the
rows the frame gave the pane; without it (a test) the whole thing comes back
unwindowed, which is the shape every other pane has."
  (declare (ignorable head))
  (let* ((view *job-out*)
         (job (or (getf view :job) "?"))
         (w (pane-width cols))
         (head-rows (list (list (cons (format nil "job output — ~a" job) '(:bold t))))))
    (cond
      ;; **A refusal is not a window.** The daemon could not answer — a job that
      ;; fell out of the exec host's table between the listing and Enter — so the
      ;; pane says what it said, rather than drawing an empty log the operator
      ;; would read as "the job wrote nothing".
      ((getf view :error)
       (let ((rows (append head-rows
                           (list (list (cons "    the daemon refused this read:" '(:dim t)))
                                 nil)
                           ;; WRAPPED, not truncated: a refusal is prose the
                           ;; operator has to read to the end — the window above
                           ;; is a log and a cut line there costs a byte, while a
                           ;; cut sentence here costs the reason
                           (mappend (lambda (l)
                                      (or (wrap-segments (list (cons l nil)) w)
                                          (list nil)))
                                    (uiop:split-string (getf view :error)
                                                       :separator '(#\newline)))
                           (list nil
                                 (list (cons "    Esc back to jobs" '(:dim t)))))))
         (setf *job-out-total* (length rows))
         rows))
      (t
       (let* ((dropped (or (getf view :dropped) 0))
              ;; **which page keys ACT, from the one function that answers it** — the
              ;; bottom row was promising `→ next page · ← back` for a job with neither
              ;; (R41); see `job-out-pages`.
              (pages (job-out-pages view))
              (meta
                ;; NIL defaults throughout, and a NIL view reads as `reading…`:
                ;; this pane draws from a plist the daemon fills a field at a
                ;; time, and a header that says `NIL — bytes NIL..NIL` is a
                ;; render fault dressed as a measurement.
                ;;
                ;; **`reading…` is `(not :answered)`, and that is R41's whole
                ;; finding: ZERO BYTES IS AN ANSWER.** The rule used to be
                ;; `:loading` AND an empty state word, which is a guess at arrival
                ;; made out of two things that are not arrival — a re-read sets
                ;; `:loading` again on a pane that has ALREADY been told what it
                ;; needs to know, and the state word is non-empty from the moment
                ;; the first answer lands, so it can only answer *have I ever been
                ;; answered*, never *is this window the one I am waiting for*. Keyed
                ;; on the arrival, a pane that has heard `running, 0 bytes` keeps
                ;; saying so — including while it waits for the next page.
                (if (not (getf view :answered))
                    "    reading…"
                    ;; the state and the measurement on ONE line, because they are
                    ;; one fact: what the job is, and what window of how much is on
                    ;; the screen
                    (format nil "    ~a — bytes ~d..~d of ~d~@[~a~]"
                            (getf view :state) (or (getf view :from) 0)
                            (or (getf view :to) 0) (or (getf view :produced) 0)
                            (when (plusp dropped)
                              (format nil " (~d earlier byte~:p gone off the front)"
                                      dropped)))))
              (body (job-out-body view))
              (shown
                (or body
                    ;; **THE EMPTINESS SENTENCE IS THE DAEMON'S OWN CONDITION: `produced == 0`.**
                    ;; Not *the window holds no lines* — that is the window's SHAPE, and the two
                    ;; come apart the moment a window holds nothing while the job HAS produced
                    ;; bytes (a read at an offset past the end, a window the ring dropped
                    ;; entirely). Called `produced > 0` with nothing in hand, `it wrote nothing at
                    ;; all.` is a lie about the job, and it is §11.6's own R17 inversion one case
                    ;; over: *a row with no output must not look like a row whose output is
                    ;; empty*. The daemon draws the line in exactly this place —
                    ;; `harness.rs:3746`, `if slice.produced == 0` — and a head that keyed it on
                    ;; the window would disagree with the daemon about the same job.
                    (when (and (getf view :answered)
                               (zerop (or (getf view :produced) 0)))
                      ;; **AND IT IS DRAWN FROM WHAT WE HAVE BEEN TOLD, not from whether a
                      ;; read is in flight** (R41): the window's emptiness is a fact the
                      ;; last answer settled, so a page re-read must not take the sentence
                      ;; away. Measured, it drew a header with NOTHING under it — which is
                      ;; the blank the operator read as *waiting for the output*, and the
                      ;; same shape as a log whose every line is whitespace.
                      ;;
                      ;; **A job that never ran is not a job that wrote nothing**
                      ;; (§11.6, letibot `e1cd2b0` — *A rules the words; both heads
                      ;; render the same string*).
                      ;;
                      ;; An empty window is TWO facts and this head had ONE sentence
                      ;; for them: `it wrote nothing at all.` under a header reading
                      ;; `not run (could not join its scope)`, which is the operator's
                      ;; own R17 rule inverted — *a row with no output must not look
                      ;; like a row whose output is empty*. The case is chosen by the
                      ;; daemon's `never-ran` FIRST, because the window's emptiness
                      ;; cannot carry the difference; `running` is still read off the
                      ;; state word, which is the daemon's own spelling of the state
                      ;; it holds (`JobState::word`), tested literally for the same
                      ;; reason the jobs pane tests `exited 0` literally: the head
                      ;; renders the daemon's vocabulary and keeps no second copy of
                      ;; the enum. An unfamiliar state word falls to `wrote nothing`,
                      ;; which is letibot's own choice and is pinned there by a test
                      ;; that names every variant.
                      (list (cond ((getf view :never-ran)
                                   ;; **The one sentence of this fix that is not the
                                   ;; daemon's**, and it is written in full so the two
                                   ;; heads cannot hold two sentences about one state.
                                   "    it never ran, so there is nothing it could have written.")
                                  ((equal (getf view :state) "running")
                                   "    it is running and has written nothing yet.")
                                  (t
                                   "    it wrote nothing at all."))))))
              (top (append head-rows
                           (list (list (cons meta '(:dim t))) nil)))
              (wrapped (mappend (lambda (l)
                                  (or (wrap-segments (list (cons l nil)) w) (list nil)))
                                shown))
              ;; The footer names only the keys that DO something here. `→` with
              ;; no `next` would promise a page that does not exist and `←` at the
              ;; front of the log a page before the first byte.
              (footer
                (list nil
                      (list (cons (format nil "    ~a"
                                          (cond ((and (getf pages :next) (getf pages :back))
                                                 "arrows scroll · → next page · ← back · Esc to jobs")
                                                ((getf pages :next)
                                                 "arrows scroll · → next page · Esc to jobs")
                                                ((getf pages :back)
                                                 "arrows scroll · ← back · Esc to jobs")
                                                (t "arrows scroll · Esc to jobs")))
                                  '(:dim t))))))
         (if (null room)
             (append top wrapped footer)
             (let* ((visible (max 1 (- room (length top) (length footer))))
                    (total (length wrapped))
                    (max-scroll (max 0 (- total visible)))
                    (scroll (min (max 0 *pane-scroll*) max-scroll))
                    (end (- total scroll))
                    (start (max 0 (- end visible))))
               (setf *pane-scroll* scroll
                     *job-out-total* (+ (length top) total (length footer)))
               (append top
                       (subseq wrapped start end)
                       ;; pad, so the footer sits on the pane's last row rather
                       ;; than floating under a short window
                       (make-list (max 0 (- visible (- end start))))
                       footer))))))))

