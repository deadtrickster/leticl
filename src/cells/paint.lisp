;;;; paint — the diff painter
;;;;
;;;; Split out of `cells.lisp`, which was one 556-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------------------- paint ;;;

(declaim (inline %cell=))
(defun %cell= (a b)
  (declare (type cell a b))
  (and (char= (cell-ch a) (cell-ch b))
       (= (cell-style a) (cell-style b))))

(defun %write-decimal (n out)
  "N, a non-negative fixnum, in decimal on OUT — what `(format out \"~D\" n)`
does, without going through the format interpreter. The painter emits one
cursor move per changed run: measured, up to a few hundred a frame, and `format`
was 2.6% of the paint for two numbers per move."
  (declare (type fixnum n) (type stream out))
  (if (< n 10)
      (write-char (code-char (+ 48 n)) out)
      (progn (%write-decimal (floor n 10) out)
             (write-char (code-char (+ 48 (mod n 10))) out))))

(defun %move-to (out row col)
  "`ESC[row;colH`, 1-based, from 0-based ROW and COL."
  (declare (type fixnum row col) (type stream out))
  (write-char +esc+ out)
  (write-char #\[ out)
  (%write-decimal (1+ row) out)
  (write-char #\; out)
  (%write-decimal (1+ col) out)
  (write-char #\H out))

(defvar *caret* nil
  "Where the terminal's own caret belongs, as (ROW . COL), or NIL for hidden.

Set by `%render` from the composer; read by the painter, which ends every frame
with the move and `ESC[?25h` — or with `ESC[?25l` when nothing wants it. A defvar
and not a head slot, because a slot is a struct layout change and that is a
restart, which is the one thing a live push must not need."
  )

(defun paint-diff (prev cur out &key (sync t))
  "Emit the escape sequence that turns the terminal showing PREV into the
terminal showing CUR. PREV nil paints everything. Both screens must have the
same shape. Runs of changed cells are written behind one absolute cursor move;
styles are tracked across the whole frame so SGR is emitted only on change.

Typed, and at DEFAULT safety, on purpose. The loop reads a `cell` out of each
screen's `simple-vector` and the declaration makes every accessor a direct load —
that is where the time was (measured: 18.7% of the frame, of which the two
`format`s and the untyped struct reads were most). What (safety 0) would remove
is one struct-tag test per cell, and the vector holds whatever a hack put there:
`(fill (screen-cells s) nil)` off the eval socket is one line, and with the check
gone that is a memory fault in the main thread — the exact failure this head has
already died of once. The check stays, and it was measured to cost nothing: 200
paints of a 210×63 frame with every row changed took 15 ms at default safety and
14–16 ms with (safety 0) — the same number, inside the run-to-run noise."
  (declare (type screen cur) (type (or null screen) prev) (type stream out))
  (when prev
    (assert (and (= (screen-cols prev) (screen-cols cur))
                 (= (screen-rows prev) (screen-rows cur)))
            (prev cur) "paint-diff screens must have the same shape"))
  (let* ((cols (screen-cols cur))
         (rows (screen-rows cur))
         (cells (screen-cells cur))
         ;; paint-full has just cleared: a default cell needs no writing, so
         ;; that is the sentinel — ONE of them, not one per cell
         (blank (%cell #\space 0))
         (pcells (if prev (screen-cells prev) nil))
         ;; Every paint ends with a reset, so every paint begins at default
         ;; style — SGR for style 0 is never needed mid-frame.
         (last-style 0)
         ;; **THE SAME TRACKING FOR A HYPERLINK**, which is the whole of the grid's part in this:
         ;; `last-link` is the span currently open, or NIL. It is a SPAN and not a URL — `eq`
         ;; answers whether it is still the one — and the URL never comes near a cell.
         (last-link nil))
    (declare (type fixnum cols rows last-style)
             (type simple-vector cells)
             (type (or null simple-vector) pcells))
    (when sync (sync-begin out))
    ;; **THE SYNC MUST CLOSE, WHATEVER HAPPENS.**
    ;;
    ;; `ESC[?2026h` ENABLES synchronized output, which SUSPENDS every update until
    ;; `ESC[?2026l` arrives. Between them there is no protection, so anything that
    ;; signals inside the paint loop — a bad cell, a plist that changed shape, an
    ;; error from the alien highlight shim — skips the close and leaves the
    ;; terminal with sync still ENABLED. The head keeps painting, `%render-and-paint`
    ;; catches the error into `*last-render-error*`, sets `head-dirty` and loops,
    ;; and every frame after that goes into a terminal that has stopped showing
    ;; anything. Measured by the operator: expanding a tool card or a thinking
    ;; block froze the screen, scroll looked dead, and switching tmux windows
    ;; restored it because tmux re-asserts the terminal's state on focus.
    ;;
    ;; The fix is the `unwind-protect` and nothing cleverer: on the way out — the
    ;; happy path and a signal alike — the sync is closed and the output flushed.
    ;; A reset goes with it, because this module's invariant is that every paint
    ;; BEGINS at default style and an aborted paint never wrote the body's own.
    (let ((painted nil))
      (unwind-protect
           (progn
             (dotimes (r rows)
               (declare (type fixnum r))
               (let ((c 0)
                     (base (* r cols))
                     ;; **ASKED ONCE PER ROW.** Most rows carry no link, and this is a hash lookup
                     ;; per cell otherwise — 13,000 a frame to learn nothing.
                     (row-links (link-row r)))
                 (declare (type fixnum c base))
                 (loop while (< c cols)
                       do (let* ((i (+ base c))
                                 (cell (svref cells i))
                                 (pcell (if pcells (svref pcells i) blank)))
                            (declare (type fixnum i) (type cell cell pcell))
                            (if (%cell= pcell cell)
                                (incf c)
                                (progn
                                  ;; start of a changed run: move there, write until it ends
                                  (%move-to out r c)
                                  (loop while (< c cols)
                                        do (let* ((j (+ base c))
                                                  (cc (svref cells j))
                                                  (pp (if pcells (svref pcells j) blank)))
                                             (declare (type fixnum j) (type cell cc pp))
                                             (when (%cell= pp cc) (return))
                                             (let ((ch (cell-ch cc)))
                                               (cond
                                                 ((char= ch +wide-cont+)
                                                  ;; covered by the wide char before it
                                                  (incf c))
                                                 (t
                                                  ;; **A LINK OPENS AND CLOSES WHERE THE STYLE IS,
                                                  ;; AND ONLY WHEN THIS HEAD DRAWS LINKS.** A span
                                                  ;; that ends mid-run closes and the next run
                                                  ;; reopens it: two sequences where one would do,
                                                  ;; and correct either way.
                                                  (when row-links
                                                    (let ((want (and *link-enabled*
                                                                     (link-at row-links c))))
                                                      (unless (eq want last-link)
                                                        (when last-link (%osc8-close out))
                                                        (setf last-link nil)
                                                        (when (and want (link-url (third want)))
                                                          (%osc8-open (link-url (third want)) out)
                                                          (setf last-link want)))))
                                                  (when (/= (cell-style cc) last-style)
                                                    (write-string (%sgr (cell-style cc)) out)
                                                    (setf last-style (cell-style cc)))
                                                  (let ((w (char-width ch)))
                                                    (if (and (= 2 w) (= c (1- cols)))
                                                        ;; a wide char on the last column would
                                                        ;; wrap; the buffer never holds one there
                                                        ;; (screen-put-string degrades it), but a
                                                        ;; direct screen-put could — guard anyway
                                                        (progn (write-char #\space out) (incf c))
                                                        (progn (write-char ch out)
                                                               (incf c (max 1 w))))))))))
                                  ;; **THE RUN ENDS AND SO DOES THE LINK.** The inner loop stops at
                                  ;; the first unchanged cell, which can be the middle of a span —
                                  ;; so a link left open here would cover everything after it on
                                  ;; the row, including text the reader never linked. Two
                                  ;; sequences where one would do, and correct either way.
                                  (when last-link (%osc8-close out) (setf last-link nil))))))))
             (write-char +esc+ out)
             (write-string "[0m" out)
             ;; THE CARET, last: a frame is a run of absolute moves, so wherever the
             ;; last changed run left the cursor is arbitrary — the caret has to be
             ;; placed after the painting and only then shown.
             (if *caret*
                 (progn (%move-to out (car *caret*) (cdr *caret*))
                        (write-char +esc+ out)
                        (write-string "[?25h" out))
                 (progn (write-char +esc+ out)
                        (write-string "[?25l" out)))
             (setf painted t))
        ;; the cleanup: reached on the happy path AND on a signal, and it is the
        ;; only thing that stands between a render error and a frozen terminal
        (unless painted
          (write-char +esc+ out)
          (write-string "[0m" out))
        ;; **AND THE SAME FOR AN OPEN LINK**, for the same reason the reset is here: a paint that
        ;; signalled mid-run left a hyperlink open, and everything the terminal draws after it —
        ;; including the next frame — is inside it. Unconditional and unpaired: a close emitted
        ;; when nothing is open is six bytes the terminal ignores.
        (when last-link (%osc8-close out) (setf last-link nil))
        (when sync (sync-end out))
        (ignore-errors (force-output out))))))

(defun paint-full (cur out)
  "Clear and paint everything — after a resize, on attach, on resync."
  (write-string (format nil "~C[2J" +esc+) out)
  (paint-diff nil cur out))

(defun move-to (out row col)
  (format out "~C[~D;~DH" +esc+ (1+ row) (1+ col)))

(defun screen-row (screen row)
  "ROW of SCREEN as a list of cells. NIL for a row off the screen, rather than an
error: a caller rendering a frame that just shrank is asking a reasonable
question."
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen)))
    (when (and (>= row 0) (< row rows))
      (loop for c from 0 below cols collect (screen-cell screen row c)))))

(defun %esc-sequences (string)
  "Every `ESC` in STRING followed by the run of characters up to and including its
final byte — an approximate CSI/OSC shape, which is all a test needs to ask *which
sequences are on this frame*.

Used by §3.1's guarantee test, and it is deliberately here rather than in the test
file: it reads the same bytes `screen-rows-ansi` writes, so the two cannot disagree
about what a sequence looks like on this head's wire."
  ;; **The CSI grammar and nothing looser**: `ESC[`, then parameters (digits, `;`,
  ;; `?`), then exactly ONE final byte. A set of "plausible" letters is a set that
  ;; swallows the text after the sequence — measured, `ESC[0mhello` came back as
  ;; `ESC[0mh`, because `h` is also the final byte of `?25h`.
  (loop for i from 0 below (length string)
        when (char= (char string i) #\Esc)
          collect (let ((j (1+ i)))
                    (when (and (< j (length string)) (char= (char string j) #\[))
                      (incf j)
                      (loop while (and (< j (length string))
                                       (let ((c (char string j)))
                                         (or (digit-char-p c) (char= c #\;) (char= c #\?))))
                            do (incf j))
                      ;; one final byte, 0x40-0x7e, and no more
                      (when (and (< j (length string))
                                 (<= #x40 (char-code (char string j)) #x7e))
                        (incf j)))
                    (subseq string i j))))

(defun screen-rows-ansi (screen)
  "One string per row, escape codes included — the answer to ScreenRequested
and the body of /cells: what this head actually drew, at its real size, not a
description of it (protocol.rs on ClientFrame::Screen).

Built every frame (`%render-and-paint` keeps the last drawn rows), so it is
typed like the painter and reads the cell vector directly. Default safety, for
the painter's reason: the vector is a `simple-vector` of whatever was put there."
  (declare (type screen screen))
  (let* ((out nil)
         (cols (screen-cols screen))
         (cells (screen-cells screen)))
    (declare (type fixnum cols) (type simple-vector cells))
    (dotimes (r (screen-rows screen))
      (declare (type fixnum r))
      (with-output-to-string (s)
        (let ((last-style -1)
              (base (* r cols)))
          (declare (type fixnum last-style base))
          (dotimes (c cols)
            (declare (type fixnum c))
            (let ((cell (svref cells (+ base c))))
              (declare (type cell cell))
              (unless (char= (cell-ch cell) +wide-cont+)
                (when (/= (cell-style cell) last-style)
                  (write-string (%sgr (cell-style cell)) s)
                  (setf last-style (cell-style cell)))
                (write-char (cell-ch cell) s))))
          (write-char +esc+ s)
          (write-string "[0m" s))
        (push (get-output-stream-string s) out)))
    (nreverse out)))
