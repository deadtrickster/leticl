;;;; session-picker.lisp — the session picker: which sessions there are, and the list
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ------------------------------------------------------------- screens ;;;

(defun picker-sessions (session)
  "The sessions the picker lists: the daemon's own, with a SUB-SESSION under its parent.

The reference filters `parent_session_id.is_none()` on both `Hello` and
`Sessions` (app.rs:1391), because a subagent is a child of a session, shown in the
subagent tree and reached by `/switch id`. Ours listed them — measured on the
same daemon, letibot's picker had 28 rows and ours 58 — so the header's count
(`%session-position`) and the picker disagreed about how many sessions there
were. One filter, here, that both read.

**CORRECTED 2026-10-03, after the operator read a plan that made a child something to VIEW:**

  > why readonly? subagent session is more like you driving others via tmux. I already can post to
  > subagent, and agent can talk back and forth too

A child is a SESSION: it has a hub, rows, a store, a snapshot on request, and an id `/switch` already
takes — and this head deliberately hid it from the one list that reaches sessions. Everything built to
work around that hiding (the peek verb's renderer, `subagent-out-lines`, the pane's own Enter) is
vestigial now that Enter attaches and the peek asks for rows.

**WHAT THE FILTER WAS REACHING FOR IS REAL AND IS KEPT**: twenty subagents must not bury the four
conversations the operator cares about. So a child is drawn UNDER its parent and UNNUMBERED, and
`%session-position` counts the numbered rows only — the header says `1/3` for three conversations
however many children they have."
  (let* ((all (session-sessions session))
         (out nil))
    ;; **THE DAEMON'S ORDER, WITH EACH PARENT'S CHILDREN MOVED UP UNDER IT.** A child is a session —
    ;; attachable, promptable, and it answers; see the docstring for the operator's words and for why the
    ;; filter this replaces was the bug rather than the quiet.
    (dolist (p all)
      (unless (getf p :parent-session-id)
        (push p out)
        (dolist (c all)
          (when (equal (getf c :parent-session-id) (getf p :session-id))
            (push c out)))))
    ;; a child whose parent is not in the list — a daemon that trimmed it — is still a session
    (dolist (b all)
      (unless (member b out :test #'equal)
        (push b out)))
    (nreverse out)))

(defun picker-lines (session sel cols)
  "The session picker, row for row the reference's `picker_lines`:

    sessions in this daemon
    <blank>
    ▸  1  title                              2647 rows · 2 heads · qwen-3.8-27b
          s-1789639478142928813  ~/Projects/leticl
       2  other title                     on disk · 1799 rows · glm-5.3-flash
          s-1789462738453908838  ~/Projects/letibot
    <blank>
    ↑↓ moves · enter switches · …
    switching does not stop anything: …

The row under the cursor is reversed and the mark `▸` is what Enter takes; the
session this head is IN keeps its name bold, so \"where am I\" and \"what Enter
takes\" stay two readable facts. The facts on the right are the daemon's:
`generating` while a turn runs, `on disk` for a stored session, the store's row
count (the view's `items` is bounded and would make a long session look short),
the heads attached and the model. Under EVERY row, the full id and the workspace —
the id because it is the thing you would type, the workspace because for a stored
session it is the only thing on the row that says what the conversation was about.

Second value is the cursor's LINE: two lines per session, after a two-line header."
  (let* ((w (pane-width cols))
         (rows (picker-sessions session))
         (n (length rows))
         (sel (if (plusp n) (min sel (1- n)) 0))
         (header (list (list (cons "sessions in this daemon" '(:bold t)))
                       nil))
         (lines nil))
    (when (null rows)
      (push (list (cons "  none listed yet — the daemon has not answered, or this head is replaying a recorded log and has no daemon to ask."
                        '(:dim t)))
            lines))
    (loop for s in rows
          for i from 0
          do (let* ((here (equal (getf s :session-id) (session-session-id session)))
                    (picked (= i sel))
                    (status (getf s :status))
                    (title (or (getf s :title) ""))
                    (name (if (plusp (length title)) title (short-id (getf s :session-id))))
                    (running (getf status :running))
                    (stored (or (getf s :stored-items) 0))
                    (rows-n (if (plusp stored) stored (or (getf status :items) 0)))
                    (heads (or (getf status :heads) 0))
                    ;; **THE MODEL ON THE ROW THE HEAD IS IN COMES FROM THE HEAD, NOT FROM THE
                    ;; DAEMON'S ROW.** `wiring.model` is the daemon's word from its own attach, and
                    ;; it is never revised — `ServerFrame::Settings` has one send site and it is the
                    ;; ANSWER to a request (see `%model-name`), so a session whose provider changed
                    ;; mid-life has a stale model on every daemon row forever. That is the same fact
                    ;; `%model-name` was written for the HEADER, and leaving the picker on the raw
                    ;; `wiring` field made the two surfaces disagree about one session on one
                    ;; screen: the operator's *"in sessions list this session presented as qwen"*
                    ;; while the header of the same head said `deepseek/deepseek-flash`.
                    ;;
                    ;; The head only knows better about the session it is IN; for every other row
                    ;; the daemon's own word is the only thing anyone has.
                    (model (or (and here
                                    (let ((m (%model-name session)))
                                      (and (plusp (length m)) m)))
                               (getf (getf s :wiring) :model)
                               ""))
                    (workspace (or (getf (getf s :wiring) :workspace) ""))
                    (facts (remove nil
                                   (list (and running "generating")
                                         (and (not (getf s :live)) "on disk")
                                         (and (plusp rows-n) (format nil "~d rows" rows-n))
                                         (and (plusp heads)
                                              (format nil "~d head~:p" heads))
                                         (and (plusp (length model)) model))))
                    ;; the reference reverses the WHOLE left half, mark and name
                    ;; alike, and the name's bold rides inside it
                    (child (and (getf s :parent-session-id) t))
                    (number (1+ (count-if-not (lambda (b) (getf b :parent-session-id))
                                              (subseq rows 0 i))))
                    (left (list (cons (if child
                                         ;; **UNNUMBERED, and the number is what makes a row a CONVERSATION.**
                                         ;; The header counts the same rows this numbers, so twenty
                                         ;; subagents cannot turn it into `1/21`: a child sits under its
                                         ;; parent, where it is both visible and quiet.
                                         (format nil "~a   ↳ " (if picked "▸" " "))
                                         (format nil "~a ~2d  " (if picked "▸" " ") number))
                                       (and picked '(:reverse t)))
                                (cons name (cond ((and picked here) '(:reverse t :bold t))
                                                 (picked '(:reverse t))
                                                 (here '(:bold t))
                                                 (t nil)))))
                    (right (list (cons (format nil "~{~a~^ · ~}" facts)
                                       (if running '(:fg :yellow) '(:dim t))))))
               (push (split-row left right w) lines)
               (push (list (cons (if (plusp (length workspace))
                                     (format nil "      ~a  ~a" (getf s :session-id)
                                             (tilde-path workspace))
                                     (format nil "      ~a" (getf s :session-id)))
                                 '(:dim t)))
                     lines)))
    (push nil lines)
    (push (list (cons "  ↑↓ moves · enter switches · or type a number or part of a name and press enter · /new [title] makes one · /rename NAME names this one · esc closes"
                      '(:dim t)))
          lines)
    (push (list (cons "  switching does not stop anything: a turn keeps running in the session you left, and it is still there when you come back."
                      '(:dim t)))
          lines)
    (values (append header (nreverse lines))
            (+ (length header) (* 2 sel)))))

