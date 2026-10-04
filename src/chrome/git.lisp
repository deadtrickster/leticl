;;;; git — the git field: the project's branch, and what the checkout is doing
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------------- git ;;;
;;;
;;; **WHAT THE WORKSPACE'S OWN REPOSITORY SAYS, ON THE ROW THE OPERATOR CROSSES.** The ask is
;;; theirs, 2026-10-04: *"I want to see git status in the head."* It goes beside the workspace
;;; path, because that is the thing it is a fact about, and it is ONE field: the branch, a `*`
;;; when there is anything uncommitted, and a count when the branch is ahead or behind.
;;;
;;; **IT IS REFRESHED FROM THE LOOP AND NEVER FROM A PAINT.** `git status` is a process, and this
;;; head paints a frame out of a loop that has one to spare; the rule is the dash collectors' own
;;; (`dashwatch.lisp`: a measurement never runs where the frame is drawn). MEASURED on this
;;; checkout: `git status --porcelain=v1 --branch` takes 0.00 s and prints one line, so two
;;; seconds between readings is chosen to keep the PROCESS rate low rather than because a frame
;;; could not afford it. It is wrapped in coreutils' `timeout` for the checkout where it is not
;;; free, because `uiop:run-program`'s own `:timeout` was MEASURED accepting 1 against a `sleep 30`
;;; and taking 30 seconds.
;;;
;;; **A repository this cannot read is ABSENT, not empty.** The field is NIL and the reservation
;;; draws its blank slot — the same honesty the numbers beside it keep. A header that said `main`
;;; over a directory that is not a repository would be a lie in the one row nobody checks.

(defparameter +git-refresh-ms+ 2000
  "How long a reading is trusted before the loop takes another.")

(defvar *git-cache* nil
  "`(:dir D :text T :at MS)` — the last reading, and which directory it was OF.

A `defvar` so a push can introduce it on a running head, which is how this head is fixed.")

(defun %git-oid (lines)
  "The branch oid out of a v2 branch line, or NIL.

LINES and not the raw output: `find-if` over a STRING walks its CHARACTERS, so the first lambda
call gets `#\#` and every test after it is nonsense — measured here, as a type error naming the
character. Every line-level reader in this section takes lines."
  (let ((line (find-if (lambda (l) (and (>= (length l) 13)
                                        (string= "# branch.oid " l :end2 13)))
                       lines)))
    (when line (subseq line 13))))

(defun %git-action (dir)
  "The action in progress, from the marker files GIT ITSELF leaves — gitstatus reads the same ones.

`git status --porcelain` does not report this at all: the long format says *rebase in progress*
and the porcelain does not, so the markers are the only source. A `.git` that is a FILE (a linked
worktree) has these elsewhere and this returns NIL for it, which is an absence rather than a guess."
  (when dir
    (let ((git (merge-pathnames ".git/" (uiop:ensure-directory-pathname dir))))
      (when (uiop:directory-exists-p git)
        (cond ((or (uiop:directory-exists-p (merge-pathnames "rebase-merge/" git))
                   (uiop:directory-exists-p (merge-pathnames "rebase-apply/" git))) "rebase")
              ((probe-file (merge-pathnames "MERGE_HEAD" git)) "merge")
              ((probe-file (merge-pathnames "CHERRY_PICK_HEAD" git)) "cherry-pick")
              ((probe-file (merge-pathnames "REVERT_HEAD" git)) "revert")
              ((probe-file (merge-pathnames "BISECT_LOG" git)) "bisect")
              (t nil))))))

(defun %git-count (body what)
  "The number after WHAT in BODY, or NIL when BODY is absent or does not carry it.

NIL for a missing body rather than an error: every caller here asks about a line that may not be
in the output at all — no upstream, no stashes, a one-line reading."
  (let ((at (and body (search what body))))
    (when at
      (let* ((rest (subseq body (+ at (length what))))
             (end (or (position-if-not #'digit-char-p rest) (length rest))))
        (when (plusp end) (parse-integer rest :end end))))))

(defun %git-count-branch-ab (lines what)
  "The number after WHAT in the v2 `# branch.ab +A -B` line, or NIL."
  ;; `# branch.ab` is ELEVEN characters — the hash, the space, and nine more — and a prefix
  ;; comparison with the wrong length silently finds no line at all, which is how this went from
  ;; a wrong number to no number.
  (let ((line (find-if (lambda (l) (and (>= (length l) 11) (string= "# branch.ab" l :end2 11))) lines)))
    (when line (%git-count line what))))

(defparameter +git-format-default+ "%b%d%a%s%m%~%+%!%?"
  "The default format: gitstatus's segments, in gitstatus's order, concatenated.

**The placeholders ARE the glyphs**, which is the whole mnemonic: `%b` branch (or `@oid` when
detached), `%d` behind, `%a` ahead, `%s` stashes, `%m` the action in progress, `%~` conflicts,
`%+` staged, `%!` unstaged, `%?` untracked. `%%` is a literal per cent and anything else is
literal text. `git_format` in this head's preferences file overrides it — one line, and the
segments it does not mention are simply not drawn.")

(defparameter +git-slots+
  '(("%b" . :branch) ("%d" . :behind) ("%a" . :ahead) ("%s" . :stash) ("%m" . :action)
    ("%~" . :conflict) ("%+" . :staged) ("%!" . :unstaged) ("%?" . :untracked))
  "The format's placeholders, in the order the default spells them.")

(defparameter +git-styles+
  '((:branch-clean . (:fg :green))
    (:branch-dirty . (:fg :yellow))
    (:behind . (:fg :cyan))
    (:ahead . (:fg :cyan))
    (:stash . (:fg :magenta))
    (:action . (:fg :magenta :bold t))
    (:conflict . (:fg :red :bold t))
    (:staged . (:fg :green))
    (:unstaged . (:fg :yellow))
    (:untracked . (:dim t)))
  "One role per segment, chosen to say what the segment SAYS.

**A branch is green when the tree is clean and yellow when it is not** — the one fact a person
reads at a glance — staged work is green, unstaged is yellow, conflicts are red and bold because
nothing else on that row is a demand, and untracked files are dim because they are usually noise.")

(defun %git-style (key)
  "KEY's role, or NIL for a segment this head has no opinion about."
  (cdr (assoc key +git-styles+)))

(defun %git-parts (porcelain dir)
  "PORCELAIN v2 output as gitstatus's prompt segments — the FACTS, not the text:

    (:branch \"main\" :detached nil :behind nil :ahead 2 :stash 5 :action \"merge\"
     :conflict 6 :staged 7 :unstaged 8 :untracked 9)

branch or `@oid` when detached (gitstatus shows the commit and not the branch), behind and ahead
of the upstream, the stash count, the action in progress, conflicts, staged, unstaged and
untracked — the table in gitstatus's README, in the order it prints them. NIL when the input does
not even name a branch.

**The facts and not the text**, because the format decides the text and a preference may change
the format: a cache of strings would be a cache of somebody's old choice.

**`⇠`/`⇢` are absent on purpose**: those are the PUSH remote, which `git status` does not know, and
printing the upstream's numbers with the push remote's glyphs is the kind of lie a field on every
screen must not tell."
  (let ((lines (remove-if (lambda (l) (zerop (length l)))
                          (mapcar (lambda (l) (string-right-trim '(#\Return #\Newline) l))
                                  (uiop:split-string (or porcelain "") :separator '(#\Newline)))))
        (staged 0) (unstaged 0) (untracked 0) (conflict 0))
    (let* ((head (find-if (lambda (l) (and (>= (length l) 14)
                                          ;; `# branch.head ` is FOURTEEN characters: the hash,
                                          ;; the space, the word, the space
                                          (string= "# branch.head " l :end2 14)))
                          lines))
           (name (if head (subseq head 14) nil))
           (oid (%git-oid lines)))
      (when head
        (dolist (l lines)
          (cond ;; **THE GUARD IS THE PREFIX'S OWN LENGTH, EVERY TIME.** A `string=` bounded at N on a
                ;; line shorter than N is a BOUNDS ERROR, not a false — measured here on a three-character
                ;; `? h` line, which is the shape an untracked entry takes — and every prefix test in this
                ;; function carries the length it compares.
                ((and (>= (length l) 4) (member (char l 0) '(#\1 #\2) :test #'char=))
                 ;; `1 XY …` and `2 XY …` — X is index-vs-HEAD, Y is workdir-vs-index
                 (when (char/= (char l 2) #\.) (incf staged))
                 (when (char/= (char l 3) #\.) (incf unstaged)))
                ((and (plusp (length l)) (char= (char l 0) #\u)) (incf conflict))
                ((and (plusp (length l)) (char= (char l 0) #\?)) (incf untracked))))
        (list :branch (if (and name (string= name "(detached)"))
                          (if oid (format nil "@~a" (subseq oid 0 (min 8 (length oid)))) "@")
                          name)
              :detached (and name (string= name "(detached)"))
              :behind (let ((n (%git-count-branch-ab lines "-"))) (and n (plusp n) n))
              :ahead (let ((n (%git-count-branch-ab lines "+"))) (and n (plusp n) n))
              :stash (let ((n (%git-count (find-if (lambda (l) (and (>= (length l) 8)
                                                                    (string= "# stash " l :end2 8)))
                                                   lines)
                                          "# stash ")))
                       (and n (plusp n) n))
              :action (%git-action dir)
              :conflict (and (plusp conflict) conflict)
              :staged (and (plusp staged) staged)
              :unstaged (and (plusp unstaged) unstaged)
              :untracked (and (plusp untracked) untracked))))))

(defun %git-segment (key state)
  "The `(TEXT . STYLE)` for KEY in STATE, or NIL when it has nothing to say.

The glyphs are gitstatus's own — `⇣` `⇡` `*` `~` `+` `!` `?` — so a reader who knows that prompt
knows this row."
  (let ((n (getf state key)))
    (cond ((null n) nil)
          ((eq key :branch)
           (let ((dirty (or (getf state :staged) (getf state :unstaged) (getf state :untracked)
                            (getf state :conflict))))
             (cons n (if dirty (%git-style :branch-dirty) (%git-style :branch-clean)))))
          ((eq key :action) (cons n (%git-style :action)))
          ((integerp n) (cons (format nil "~a~d"
                                      (ecase key (:behind "⇣") (:ahead "⇡") (:stash "*")
                                                  (:conflict "~") (:staged "+") (:unstaged "!")
                                                  (:untracked "?"))
                                      n)
                              (%git-style key))))))

(defun %git-format ()
  "The format in force: the preference when there is one, the default otherwise.

**READ ON THE READER THREAD, NOT IN A PAINT.** `*prefs*` may have been loaded by a build that
predates the key, so the preference is read under `ignore-errors`: a mistyped template or a
missing accessor is then a bad line rather than a header that fails to draw."
  (let ((f (and *head* (ignore-errors (getf (head-prefs *head*) :git-format)))))
    (if (and f (stringp f) (plusp (length f))) f +git-format-default+)))

(defun %git-pieces (state format)
  "STATE as the list of `(TEXT . STYLE)` the format asks for.

Literals are attached to the piece they PRECEDE — a space before a mark travels with the mark — so
that fitting drops whole pieces and never half of one."
  (let ((out nil) (pending "") (i 0) (n (length format)))
    (loop while (< i n) do
      (if (char/= (char format i) #\%)
          (progn (setf pending (concatenate 'string pending (string (char format i))))
                 (incf i))
          (let* ((two (subseq format i (min (+ i 2) n)))
                 (pair (and (= (length two) 2) (assoc two +git-slots+ :test #'string=))))
            (if pair
                (progn
                  (let ((seg (%git-segment (cdr pair) state)))
                    (when seg (push (cons (concatenate 'string pending (car seg)) (cdr seg)) out))
                    (setf pending ""))
                  (incf i 2))
                (progn ;; `%%` is a literal per cent, and a trailing `%` is literal too
                  (setf pending (concatenate 'string pending "%"))
                  (incf i (if (= (length two) 2) 2 1)))))))
    (when (and (plusp (length pending)) out)
      (setf (car out) (cons (concatenate 'string (caar out) pending) (cdar out))))
    (nreverse out)))

(defun %git-text (porcelain &optional dir)
  "PORCELAIN as one string through the DEFAULT format — what the tests assert."
  (let ((state (%git-parts porcelain dir)))
    (when state (format nil "~{~a~}" (mapcar #'car (%git-pieces state +git-format-default+))))))

(defun %git-fit (pieces room)
  "The longest PREFIX of PIECES that fits in ROOM columns, or NIL.

**The field degrades by DELETION, like every other thing on this row** — the branch is the floor
and the marks fall off its right in gitstatus's own order, so a narrow screen loses `?4` and not
the branch. A field dropped whole is the behaviour this replaces."
  (loop with out = nil and used = 3
        for p in pieces
        while (<= (+ used (string-width (car p)) 1) room)
        do (push p out) (incf used (string-width (car p)))
        finally (return (nreverse out))))

(defun %project-dir (ws)
  "The directory whose repository the header reports: the workspace, or the one repository below it.

**The operator's layout is NESTED** — *Projects/letibot/letibot with the session living in
Projects/letibot* — so the workspace is the PARENT of the repository and not the repository, and every
consumer that assumed otherwise drew nothing rather than being wrong: no branch beside the header's
path. Parity with letibot's `fde7f6e`, and one resolver rather than two for their reason — a branch from
one repository and a TODO.md from another would each be true alone.

The workspace itself wins when it IS a repository; otherwise a SINGLE repository one level below, and
nothing when there is none or several, because guessing between two checkouts is how a header comes to
name the wrong tree."
  (when (and ws (plusp (length ws)))
    (let ((w (uiop:ensure-directory-pathname ws)))
      (cond ((uiop:directory-exists-p (merge-pathnames ".git/" w)) ws)
            (t (let ((repos (ignore-errors
                              (remove-if-not (lambda (d)
                                               (uiop:directory-exists-p (merge-pathnames ".git/" d)))
                                             (directory (merge-pathnames "*/" w))))))
                 (and (= (length repos) 1) (namestring (first repos)))))))))

(defun %git-command (dir)
  "The argv for one reading.

**`--no-optional-locks` IS THE ONE FLAG THAT IS NOT ABOUT WHAT IS READ.** A plain `git status` may
take the index lock and write the refreshed index back — a READER writing to the repository it is
reporting on, which is exactly what an indicator must not do. With it, git touches nothing.

`--porcelain=v2 --show-stash` because that is where gitstatus's segments come from: `branch.head`,
`branch.oid`, `branch.ab`, the XY pair per entry, `u` for unmerged, `?` for untracked, and the
stash count. The `timeout` cap is the dash collectors' rule: `uiop:run-program`'s own `:timeout`
was MEASURED accepting 1 against a `sleep 30` and taking 30 seconds."
  (list "timeout" "1" "git" "-C" dir "--no-optional-locks"
        "status" "--porcelain=v2" "--branch" "--show-stash"))

(defun %git-refresh (dir)
  "Read DIR's repository, render it through the format in force, and store BOTH.

**THE FORMAT IS APPLIED HERE, ON THE READER THREAD, AND NOWHERE ELSE.** A paint draws cached
pieces: it never parses, never formats, and cannot meet a template somebody mistyped or a
preference function this build does not carry. That is what keeps a bad format a bad line rather
than a header that fails to draw."
  (let ((text (ignore-errors
                (uiop:run-program (%git-command dir)
                                  :output :string :error-output nil
                                  :ignore-error-status t))))
    (let ((state (%git-parts text dir)))
      (setf *git-cache* (list :dir dir
                              :state state
                              :pieces (and state (%git-pieces state (%git-format)))
                              :at (internal-real-time-ms)))
      (getf *git-cache* :pieces))))

(defvar *git-dir* nil
  "The workspace the reader is pointed at, set by the loop's `tick-git`.")

(defvar *git-thread* nil
  "The reader thread, or NIL. `dash-start`'s pattern, and for its reason.")

(defvar *git-running* nil
  "Does the reader keep reading? Cleared by `git-stop`, felt within a step.")

(defun %git-collect-once ()
  "One reading, if the interval has passed or the workspace has moved.

**A repo nobody in this session touches still has to be read**, which is why this is a clock and
not an event: the operator edits and commits in another terminal, the other agent commits in this
one, an editor writes a file — none of those reach this head as anything it can subscribe to. The
clock is what sees them. What must not happen is the clock running IN THE LOOP."
  (let ((dir *git-dir*)
        (cache *git-cache*))
    (when (and dir (plusp (length dir))
               (or (null cache)
                   (not (equal dir (getf cache :dir)))
                   (>= (- (internal-real-time-ms) (or (getf cache :at) 0)) +git-refresh-ms+)))
      (%git-refresh dir))))

(defun git-start ()
  "Start the reader thread. Idempotent: calling it twice does not make two threads.

`dash-start`'s shape, including the small-step sleep and its reason: a stop felt only after a
whole interval reads as a hang."
  (setf *git-running* t)
  (unless (and *git-thread* (sb-thread:thread-alive-p *git-thread*))
    (setf *git-thread*
          (sb-thread:make-thread
           (lambda ()
             (loop while *git-running*
                   do (ignore-errors (%git-collect-once))
                      (loop repeat 10 while *git-running* do (sleep 0.1))))
           :name "leticl-git-reader")))
  +git-refresh-ms+)

(defun git-stop ()
  "Stop the reader. Idempotent."
  (setf *git-running* nil)
  (when (and *git-thread* (sb-thread:thread-alive-p *git-thread*))
    (ignore-errors (sb-thread:join-thread *git-thread* :timeout 2)))
  (setf *git-thread* nil)
  (values))

(defun tick-git (head)
  "Point the reader at this session's workspace and make sure it is running.

**CALLED FROM THE LOOP, AND IT MUST NEVER RUN A PROCESS.** The first version did, every two
seconds, wrapped in `timeout 1`: on this checkout that is nothing, and on a checkout where git is
slow it is up to a second with no keys and no repaint — the loop is the one thing in this head
that may not wait, which is why the dash collectors were moved onto a thread after being wedged by
exactly this. So the loop sets a directory and starts a thread; the reading happens over there and
the paint reads whatever the last one left."
  (let ((dir (getf (session-wiring (head-session head)) :workspace)))
    (when (and dir (plusp (length dir)))
      (let ((dir (%project-dir dir)))
        (unless (equal dir *git-dir*) (setf *git-dir* dir)))
      (git-start))))

(defun top-border (head cols)
  "The header: what this session IS on the left, what it is COSTING on the right.

    ▌ the cache question  ~/Projects/letibot   2/4 · glm-5.3-flash · 41.2k ctx · 92% cached · 45 tok/s · 12.3s · 1.2k out

The shape is letibot's `header_line`, and so are the three registers, read off its
raw escapes rather than its plain text: the bar is `Role::UserAccent` (blue), the
title `Strong`, the workspace `Faint`, and the whole tail `Faint`. Ours painted the
left half bold from the bar to the path, which is one register where the reference
has three — and it is the row the eye crosses on every return to the field.

**It degrades by deletion, one field at a time**, from the tail's END: the path is
shortened from its left before anything is dropped — a path is recognisable from
its end, and a token count is not recoverable from anywhere else on the screen."
  (let* ((s (head-session head))
         (name (if (plusp (length (session-title s)))
                   (session-title s) (session-session-id s)))
         (model (%model-name s))
         ;; **EACH FIELD AS `(KEY . TEXT-OR-NIL)`, AND THE KEY IS WHAT RESERVES ITS COLUMNS** —
         ;; see `%header-tail` and `+header-tail-slots+` for the axiom this serves. NIL is
         ;; *nothing measured this*, and it holds its place rather than taking none.
         (fields (append (list (cons :position (%session-position s)))
                         (list (cons :model (and (plusp (length model)) model)))
                         (list (cons :spent (spent-text)))
                         (%usage-fields s)))
         ;; **the name's own columns — the `+ 2` was the bar and the space beside it**, and it is
         ;; gone with the bar. Leaving it would have made every row two columns short of the body:
         ;; measured, the test that asserts the width caught it immediately, which is what it is for.
         (name-cols (string-width name))
         ;; **THE RESERVATION IS AFFORDED OR IT IS NOT, AND THAT IS DECIDED FROM COLS ALONE.**
         ;;
         ;; Every slot costs columns, and columns are what the fields LEFT of it have to move for.
         ;; At a wide frame reserving them is free — the row is padded to COLS in any case, so a
         ;; blank slot is indistinguishable from padding — and the fields then cannot move. At a
         ;; narrow frame the slots would cost more than they are worth: a canonical tail is about
         ;; twenty-six columns wider than a natural one, and at 100 columns reserving everything
         ;; would leave the tail room for exactly one field where letibot shows seven.
         ;;
         ;; So the choice is made on the CANONICAL tail — every field present, every slot at its
         ;; width — and not on the tail that happens to be drawn. That is the whole point: a
         ;; decision taken from the measurements would itself move when a measurement arrived.
         ;; Below the threshold the tail is drawn NATURALLY, exactly as the reference draws it,
         ;; and the fields move when a value grows — the fidelity is worth more than the
         ;; stillness on a frame too narrow to have both.
         (canon (%header-tail-cols fields))
         (reserved (<= (+ name-cols canon 2) cols)))
    (unless reserved
      ;; drop from the end until it leaves room for the name, as the reference does
      (loop while (and (> (length fields) 1)
                       (> (+ name-cols (string-width (%header-tail-natural fields)) 2) cols))
            do (setf fields (butlast fields))))
    (let* ((tail (%header-tail fields))
           ;; the pad charges the RESERVED width, so the tail's left edge is where the reservation
           ;; puts it whether or not every slot was drawn
           (tail-reserved (if reserved canon (string-width tail)))
           (tail-cols (if (plusp (length tail)) (+ 2 tail-reserved) 0))
           ;; **NO BLUE BAR AND NO BOLD TITLE** — the header is FACTS, and the bar is the claim
           ;; that the PERSON spoke.
           ;;
           ;; The operator: *"the project directory and session name are pinned in the first row
           ;; with the same blue bar we use for my messages. very confusing. just make both gray
           ;; and remove the bar.\"*
           ;;
           ;; They are right, and it is R42's own argument arriving at the header. `▌` in
           ;; `UserAccent` is how this head says *a person said this* — the operator's rows wear it
           ;; (`%operator-block-lines`), and the settled echo of the terminal's own input keeps it
           ;; too. A bar on the header made the session's NAME look like somebody's sentence, on
           ;; the one row the reader crosses on every return to the field.
           ;;
           ;; **Both halves go faint, which is the register the workspace already had.** The bar
           ;; is deleted rather than recoloured: a grey bar would still be a bar, and this is the
           ;; same rule the workspace has followed since the reference's `Role::Faint` — position
           ;; and name are facts about the session, not a speaker.
           ;;
           ;; **This DEPARTS from letibot** (its `header_line` paints the bar `UserAccent` and the
           ;; title `Strong`), so it is recorded as ours and not as parity.
           (left (list (cons name '(:dim t))))
           (left-cols name-cols)
           (ws (%workspace s)))
      ;; the workspace fills whatever is left, shortened from its LEFT
      (when ws
        (let ((room (- cols left-cols tail-cols 2)))
          (when (>= room 8)
            (let ((shown (%ellipsise-left ws room)))
              (setf left (append left (list (cons (format nil "  ~a" shown) '(:dim t)))))
              (incf left-cols (+ 2 (string-width shown)))))))
      ;; **AND THE WORKSPACE'S REPOSITORY**, beside the path it is a fact about, in gitstatus's
      ;; own segments AND its own colours. READ here, never RUN and never FORMATTED here: the
      ;; reader thread parses and renders, and this only chooses how much fits. **The segments
      ;; carry their own styles** — a green branch, a yellow `!`, a red `~` — and the parens are
      ;; the row's own faint, so the field still reads as one thing.
      (let* ((pieces (getf *git-cache* :pieces))
             (room (- cols left-cols tail-cols 2))
             (fit (and (equal (getf *git-cache* :dir)
                               (%project-dir (getf (session-wiring s) :workspace)))
                       (%git-fit pieces room))))
        (when fit
          (setf left (append left (list (cons " (" '(:dim t))))
                left (append left fit)
                left (append left (list (cons ")" '(:dim t)))))
          (incf left-cols (+ 3 (loop for piece in fit sum (string-width (car piece)))))))
      (let* ((pad (max 0 (- cols left-cols tail-reserved)))
             ;; **AND THE RESERVED BUT UNUSED COLUMNS AFTER THE TAIL.** The block the fields sit in
             ;; is `tail-reserved` wide whatever happens to be in it, so `2/2` stands where `2/2`
             ;; will stand when the rate lands beside it — that stillness is the whole point, and
             ;; this is what it costs: the row ends in blank cells on a frame where nothing has been
             ;; measured yet. They are the frame's own padding in a different place, not a field with
             ;; something to say, so they are a segment of their own rather than part of the faint
             ;; tail.
             (slack (max 0 (- tail-reserved (string-width tail)))))
        (append left
                (list (cons (make-string pad :initial-element #\space) nil)
                      (cons tail '(:dim t)))
                (when (plusp slack)
                  (list (cons (make-string slack :initial-element #\space) nil))))))))

