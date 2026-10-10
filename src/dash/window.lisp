;;;; window — the window's numbers, and why ABSOLUTES
;;;;
;;;; Split out of `dash.lisp`, which was one 1569-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------- the window's numbers, and why ABSOLUTES ;;;;
;;;
;;; **ABSOLUTES, NEVER INCREMENTS.** `hub.publish` means every attached head sees the `JobOutput`
;;; answering ANOTHER head's read — so a series accumulated from deltas DOUBLE-COUNTS the moment a
;;; second head polls, while one taking the reply's ABSOLUTE is idempotent and simply gains the
;;; extra sample. **And an absolute is DROP-SAFE for the same reason**, which is this design paying
;;; twice: `produced` is a monotonic total, unaffected by what the ring threw away, so the primary
;;; series cannot be corrupted by a gap at all. The increment would have been wrong on both counts,
;;; and the wire was telling us so.

(defun dash-note-job (window &optional head)
  "Record WINDOW's own numbers, and run its panel's `:feed`. Returns how many series were written.

Called by the `JobOutput` event arm — which ALSO folds a window into the pane, and the two are
deliberately separate readers of one fact: the pane wants the LINES, the dashboard wants the
NUMBERS, and neither is derived from the other.

**HEAD IS HOW A PANEL REGISTERED BY COMMAND IS FOUND, and its absence was why they never ran.**
The panel lookup used to be handed a fabricated job — `(list :id job :command job)` — whose COMMAND
was the job's own id, so `dash-job-matches-p` could only ever match a panel registered with that
exact id. A panel registered the way the file format documents (`:job \"llama-server\"`, matching
the command line) never matched an `JobOutput` window, and a `:feed` panel that never fills looks
exactly like a job that produced nothing (the dashboard reviewer, 2026-10-11). The daemon's job LIST
is where the command lives, so it is consulted when a head is in hand; the synthesized list stays as
the fallback for the callers that have none (a test, a resync)."
  (let* ((job (getf window :job))
         (produced (getf window :produced))
         (dropped (getf window :dropped))
         (entry (and head job
                     (find-if (lambda (j) (string= job (or (getf j :id) ""))) (head-jobs head))))
         (n 0))
    (when job
      (setf (gethash job *dash-fed*)
            (list :next (getf window :next)
                  :from (getf window :from)
                  :state (or (getf window :state) "")
                  :never-ran (getf window :never-ran)
                  :at *now-ms*
                  :asked t)))
    ;; the two every job has, so `:job` alone is a working panel with no parsing
    (when produced (dash-note (format nil "job.~a.produced" job) produced) (incf n))
    (when dropped (dash-note (format nil "job.~a.dropped" job) dropped) (incf n))
    ;; and the panel's own reading, which is a function of the window like a sampler is
    (let ((panel (dash-panel-for-job (or entry (list :id job :command job)))))
      (when (and panel (getf panel :feed))
        (dolist (pair (ignore-errors (funcall (getf panel :feed) window)))
          (when (dash-note (car pair) (cdr pair)) (incf n)))))
    ;; **AND THE WATCHERS THAT CLAIM THIS JOB** — a `job_output` source is an EVENT, not a poll, so
    ;; this is its only reader. Same `fboundp` reasoning as `dash-collect-once`'s sink pass.
    (when (fboundp 'dash-watcher-note-job)
      (incf n (or (ignore-errors (dash-watcher-note-job window)) 0)))
    n))

;;; ========================================================= the five states ;;;;

(defun dash-job-rows (head panel &optional cols)
  "The rows a job-backed PANEL always draws: its state, and what it has produced.

**FIVE STATES AND THEY ARE ALL REAL** (R56), the last one because an empty window is two facts:

  · `waiting` — registered, no job in the daemon's list yet. A panel may legitimately be registered
    BEFORE its job exists, which is why the association matches on the command line;
  · `running` — the live register;
  · `exited 0`;
  · `ended` — non-zero, killed; **the job's own word**, never rendered as `error`;
  · `never_ran` — the wrapper could not join its cgroup, so nothing started. In the ATTENTION
    register, because this head already paid for the confusion once: the R41 work's own words,
    *a job that never ran has no duration, and the row claimed one*.

A panel that wants ONLY these passes its own plist:

    (dash-register \"import\" :job \"long-import\"
      :rows (lambda (cols) (dash-job-rows *head* that cols)))

and a panel with its own numbers puts them in a `:feed` and draws them beside these."
  (declare (ignore cols))
  (let* ((entry (dash-job-for-panel head panel))
         (id (getf entry :id))
         (fed (and id (gethash id *dash-fed*)))
         (never (or (and entry (getf entry :never-ran)) (getf fed :never-ran)))
         (running (and entry (getf entry :running)))
         (state (or (and entry (getf entry :state)) (getf fed :state) ""))
         (series (and id (dash-values (format nil "job.~a.produced" id))))
         (produced (and series (plusp (length series)) (aref series (1- (length series)))))
         (dropped (and id (dash-last (format nil "job.~a.dropped" id))))
         (dir (and series (dash-direction series 20))))
    (append
     (list
      (list :label "job"
            :value (or id "—")
            :kind (cond ((null entry) :dim)
                        (never :crit)
                        (running :pending)
                        ((and (plusp (length state)) (uiop:string-prefix-p "exited 0" state)) :good)
                        (t :crit))
            :tail (cond ((null entry)
                         (format nil "waiting for a job whose command names ~a"
                                 (or (getf panel :job) "")))
                        (never "never ran — the wrapper could not join its cgroup")
                        (t state))))
     (when produced
       (list (list :label "written"
                   :value (dash-bytes produced)
                   :kind :plain
                   ;; **A GAP IS A FACT ON THE PANEL, never a smoothed line.** Bytes fell off the
                   ;; ring, so a parser that counts is wrong from that point on and cannot tell
                   ;; from the lines alone — which is the third member of this file's family:
                   ;; stale is not zero, absent is not zero, and a gap is not a fall to zero.
                   :tail (cond ((and dropped (plusp dropped))
                                (format nil "~@[~a · ~]~a dropped" dir (dash-bytes dropped)))
                               (dir dir)
                               (t ""))))))))

;;; ====================================================== 8. the llama panel ;;;
;;;
;;; **THE DASHBOARD THE OPERATOR ASKED FOR**, and the shape is the argument: the collector feeds
;;; series, the panels read them, and every number is drawn beside its denominator. Nothing here
;;; is compiled into the head's core — `dash-llama-dashboard` is a function you call, and every
;;; piece of it can be replaced at a live REPL.

(defparameter +dash-llama-host+ "127.0.0.1")
(defparameter +dash-llama-port+ 8080)

(defun dash-register-defaults ()
  "Register the dashboards this head ships, WITHOUT starting a collector.

**Registration is free and collecting is not**, so they are split: this runs at head startup (it is
a few plists and no I/O), and the collector starts when somebody opens the pane (`/dashboards`).
A head that samples `/proc` and a model server every five seconds for an operator who never looks
is a head doing work nobody asked for.

**Why startup at all, when a panel is supposed to be composed at a REPL**: without it, a fresh head
has the vocabulary and NO panels, which is what the operator got — *\"I restarted, no dashboards\"* —
because the only thing that had ever registered one was a hand-typed eval in a session. The panels
this head ships are therefore DEFAULT STATE, like the folds and the diff shape, and a REPL can
still replace or clear them.

Idempotent: `dash-register` replaces by name, so calling this twice is one set of panels."
  (dash-llama-panels)
  ;; **AND THE SAMPLERS, which is the half I first left out** — registering the panels alone gave
  ;; a head that opened its pane to two boxes of dashes, because `/dashboards` starts a collector
  ;; that had nothing to call. Registering a lambda is free; it is the THREAD and the I/O that
  ;; wait for somebody to look.
  (dash-sampler-add "llama" #'dash-sample-llama)
  (dash-sampler-add "system" #'dash-sample-system)
  (length (dash-panels)))

(defun dash-llama-dashboard (&key (start t))
  "**THE ONE CALL A HEAD MAKES**: register the panels, register the samplers, and start
collecting. Returns the interval.

Two samplers and not one, because they fail independently — llama-server can be down while the
machine is fine, and a single sampler would take the system panel's history with it every time
the server restarts. That is the same reason `dash-collect-once` records a failing sampler instead
of propagating."
  (dash-llama-panels)
  (dash-sampler-add "llama" #'dash-sample-llama)
  (dash-sampler-add "system" #'dash-sample-system)
  (when start (dash-start))
  *dash-interval*)

(defparameter +dash-cores+ 32
  "Cores, for the load row's denominator.

**A constant rather than a probe, and that is the design.** A load average with no scale is a
number nobody can act on — 20.09 is alarming on 4 cores and idle on 64 — so the denominator has
to be sayable, and a `defparameter` lets a panel be TESTED without asking the machine. The
default is this box's; a head on another machine sets it once."
  )

(defun dash-sample-llama ()
  "llama-server's own `/metrics`, plus `/slots` for what is in flight.

The metric names are the server's and the derivations are stated, because two of them are
COUNTERS and a counter drawn as a gauge is a line that only ever climbs:
  · `predicted_tokens_seconds` and `prompt_tokens_seconds` are already rates, so they are read
    directly — note they are per-slot averages, not `Δtokens/Δt`;
  · the spec-decode accept RATE is `accepted / drafts` from the cumulative counters, which is
    the number that says whether the draft model is earning its keep."
  (let* ((text (dash-http-get +dash-llama-host+ +dash-llama-port+ "/metrics"))
         (m (dash-parse-metrics text)))
    (flet ((g (name) (cdr (assoc name m :test #'string=))))
      ;; **THE DENOMINATOR IS DRAFT TOKENS, NOT DRAFT STEPS**, and reading the wrong one gives a
      ;; rate ABOVE 100%: measured on the live server, `num_drafts_total` is 1.98M *"verification
      ;; steps"* while `num_draft_tokens_total` is 3.95M tokens generated, and 3.53M were
      ;; accepted. Against steps that is 178%; against tokens it is 89%, which is the number the
      ;; panel is actually about. One draft yields several tokens, so the two counters are not
      ;; the same kind of thing and the names do not say so.
      (let ((drafts (g "llamacpp:spec_decode_num_draft_tokens_total"))
            (accepted (g "llamacpp:spec_decode_num_accepted_tokens_total"))
            (prompt (g "llamacpp:prompt_tokens_total"))
            (cached (g "llamacpp:prompt_tokens_cached_total"))
            (pred (g "llamacpp:tokens_predicted_total")))
        (list (cons "llama.gen_rate" (g "llamacpp:predicted_tokens_seconds"))
              (cons "llama.prompt_rate" (g "llamacpp:prompt_tokens_seconds"))
              (cons "llama.processing" (g "llamacpp:requests_processing"))
              (cons "llama.deferred" (g "llamacpp:requests_deferred"))
              (cons "llama.slots_busy" (g "llamacpp:n_busy_slots_per_decode"))
              (cons "llama.decode_total" (g "llamacpp:n_decode_total"))
              (cons "llama.ctx_max" (g "llamacpp:n_tokens_max"))
              (cons "llama.accept_ratio"
                    (and drafts accepted (plusp drafts) (min 1.0 (/ accepted drafts))))
              (cons "llama.cache_ratio" (and prompt cached (plusp prompt) (/ cached prompt)))
              (cons "llama.predicted_total" pred)
              ;; **A COUNTER IS NOT A GAUGE.** `/slots` reports what is in flight NOW — the
              ;; prompt a request is working through — which is the only live progress there
              ;; is; the totals above only ever climb and cannot answer "is it moving".
              (cons "llama.slot_prompt_pts"
                    (let ((slots (ignore-errors
                                  (json-decode (or (dash-http-get +dash-llama-host+
                                                                 +dash-llama-port+ "/slots")
                                                   "[]")))))
                      (when (listp slots)
                        (let ((busy (remove-if-not (lambda (s) (getf s :is-processing)) slots)))
                          (when busy
                            (let ((s (first busy)))
                              (getf s :n-prompt-tokens-processed))))))))))))

(defun dash-llama-panels ()
  "Register the llama + system dashboard. Call it, or call it at a REPL to change one panel.

Each panel's `:needs` names the series its freshness chip should reflect — **a panel is only as
live as its stalest input**, which is why the chip is computed from the set rather than from
whichever series happened to be sampled last."
  (dash-register "llama" :title "llama-server" :order 10
                 ;; **`job` IS WHAT LINKS IT TO THE JOBS PANE** — the operator's ask. It is a
                 ;; SUBSTRING of the command rather than an id, because a panel is registered
                 ;; before the job it watches exists (see `dash-panel-for-job`).
                 :job "llama-server"
                 :needs '("llama.gen_rate" "llama.processing")
                 :rows
                 (lambda (cols)
                   (declare (ignore cols))
                   (let* ((gen (dash-last "llama.gen_rate"))
                          (pp (dash-last "llama.prompt_rate"))
                          (peak (let ((v (dash-values "llama.gen_rate")))
                                  (and v (plusp (length v)) (reduce #'max v))))
                          (dec (dash-values "llama.gen_rate"))
                          (proc (dash-last "llama.processing"))
                          (defer (dash-last "llama.deferred"))
                          (acc (dash-last "llama.accept_ratio"))
                          (cache (dash-last "llama.cache_ratio")))
                     (list
                      (list :label "generation"
                            :value (or (dash-rate gen) "—")
                            :bar (and gen peak (plusp peak) (/ gen peak))
                            :tail (format nil "peak ~a  ~a"
                                          (or (dash-rate peak) "?")
                                          (or (dash-direction dec 20) "no trend")))
                      (list :label "prompt"
                            :value (or (dash-rate pp) "—")
                            :kind :dim
                            :tail "tokens/s, per slot")
                      (list :label "requests"
                            :value (if proc (format nil "~d" (round proc)) "—")
                            :kind (if (and proc (plusp proc)) :pending :dim)
                            :tail (format nil "processing~@[ · ~d deferred~]" (and defer (plusp defer) (round defer))))
                      (list :label "spec accept"
                            :value (or (dash-pct acc 0) "—")
                            :bar acc
                            :kind (cond ((null acc) :dim) ((> acc 0.8) :good) ((< acc 0.4) :warn) (t :plain))
                            :tail "accepted of drafted")
                      (list :label "prefix cache"
                            :value (or (dash-pct cache 0) "—")
                            :bar cache
                            :kind :good
                            :tail "prompt tokens reused")))))
  (dash-register "system" :title "this machine" :order 20
                 :needs '("sys.load1" "sys.mem_used")
                 :rows
                 (lambda (cols)
                   (declare (ignore cols))
                   (let* ((l1 (dash-last "sys.load1"))
                          (used (dash-last "sys.mem_used"))
                          (total (dash-last "sys.mem_total"))
                          (swap (dash-last "sys.swap_used"))
                          (stot (dash-last "sys.swap_total"))
                          (mem-frac (and used total (plusp total) (/ used total)))
                          (swap-frac (and swap stot (plusp stot) (/ swap stot))))
                     (list
                      ;; **LOAD IS A NUMBER WITH NO SCALE UNTIL IT HAS ONE.** A bare 20.09 is
                      ;; alarming on four cores and idle on sixty-four, and the reader cannot
                      ;; tell which — so the denominator is in the tail, always.
                      (list :label "load 1m"
                            :value (if l1 (format nil "~,1f" l1) "—")
                            :bar (and l1 (plusp +dash-cores+) (/ l1 +dash-cores+))
                            :kind (cond ((null l1) :dim)
                                        ((> l1 (* 1.2 +dash-cores+)) :crit)
                                        ((> l1 +dash-cores+) :warn)
                                        (t :good))
                            ;; **THE SEPARATOR IS PART OF THE WORD, not of the format.** A
                            ;; row that ends `of 32 cores · ` carries punctuation for a
                            ;; sentence that is not there — and it is there for the first three
                            ;; samples of every session, which is when the pane is first read.
                            :tail (let ((dir (dash-direction (dash-values "sys.load1") 20)))
                                    (if dir
                                        (format nil "of ~d cores · ~a" +dash-cores+ dir)
                                        (format nil "of ~d cores" +dash-cores+))))
                      (list :label "memory"
                            :value (or (dash-bytes used) "—")
                            :bar mem-frac
                            :kind (cond ((null mem-frac) :dim)
                                        ((> mem-frac 0.9) :crit)
                                        ((> mem-frac 0.75) :warn)
                                        (t :plain))
                            :tail (format nil "of ~a · ~a"
                                          (or (dash-bytes total) "?")
                                          (or (dash-pct mem-frac 0) "")))
                      ;; **SWAP IS THE ONE NUMBER HERE THAT IS ALMOST ALWAYS BAD**, so its
                      ;; threshold is a fraction of a gigabyte rather than a percentage:
                      ;; anything swapped at all on a model box is memory pressure, and waiting
                      ;; for 100% to say so is waiting until the machine is already thrashing.
                      (list :label "swap"
                            :value (or (dash-bytes swap) "—")
                            :bar swap-frac
                            :kind (cond ((null swap) :dim)
                                        ((> swap (* 512 1024 1024)) :crit)
                                        ((plusp swap) :warn)
                                        (t :good))
                            :tail (format nil "of ~a" (or (dash-bytes stot) "?")))))))
  (dash-bind "g" "main" "dash")
  (dash-bind "j/k" "move" "move")
  (dash-bind "esc" "leave" "leave")
  (values))

