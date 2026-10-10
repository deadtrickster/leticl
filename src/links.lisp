;;;; links.lisp — OSC 8 hyperlinks, kept OUT of the cell grid.
;;;;
;;;; The operator, 2026-09-27: *"i also dont mind if image path will be rendered as a link so a
;;;; click will open the image for me."*
;;;;
;;;; **THE CONSTRAINT, AND IT OUTRANKS THE CONVENIENCE.** This head's cell grid physically cannot
;;;; carry an escape: a cell is one character plus an interned style INTEGER (`cells.lisp`), so
;;;; `a-tool-payload-cannot-reconfigure-the-operators-terminal` is a PROOF here rather than a patch,
;;;; which is the parity document's criterion *content the head did not author must not reconfigure
;;;; the terminal* — its own words: *"a cell grid cannot store a control character at all, so for B
;;;; the same criterion is a proof rather than a fix."* It fails the day a zero-width cluster gains
;;;; a cell, and that test is the citation because a test name survives the document being
;;;; renumbered.
;;;;
;;;; A hyperlink is exactly the thing that would break that proof: it is a non-printing escape
;;;; carrying a URL, which is not a character and does not fit in a cell. So:
;;;;
;;;;   · **NOTHING GOES IN A CELL.** The grid stays chars plus interned styles, and this module
;;;;     lives beside it, not inside it.
;;;;   · **CONTENT NEVER SUPPLIES A TARGET.** A URL here is authored by THIS FILE from a path the
;;;;     HEAD resolved and confirmed exists (`link-path-url`, which answers NIL otherwise). A tool
;;;;     payload, model prose, and a markdown link cannot reach it — they would have to call
;;;;     `link-intern`, and the only caller is the renderer, after `%without-control` has already
;;;;     turned every control character in that text into a space.
;;;;   · **AND THE SPANS ARE A PARALLEL MAP, PER ROW, OF INTEGERS.** A span is `(start end ID)`;
;;;;     the ID indexes a table of URLs built for this frame. Every URL is in one place a reader
;;;;     can audit, and the painter — which already tracks `last-style` across a frame — tracks
;;;;     `last-link` the same way.
;;;;
;;;; **What the painter emits, and what it does NOT promise.** An OSC 8 is a REQUEST to the
;;;; terminal: the terminal decides whether the text under it is clickable and what a click does,
;;;; which is the operator's desktop configuration and not this head's business. No string here
;;;; says "opens the image", and no screen says it either (see `link-said`).

(in-package #:leticl)

;;; ============================================================= the escapes ;;;

(defparameter +st+ (coerce (list #\Esc #\\) 'string)
  "String Terminator. `ESC \\` and not BEL, because it is what the OSC 8 specification names —
and a BEL inside a frame is a bell, which some terminals ring even when it terminates a sequence.")

(defun %osc8-open (url out)
  "Open a hyperlink to URL."
  (write-char +esc+ out)
  (write-string "]8;;" out)
  (write-string url out)
  (write-string +st+ out))

(defun %osc8-close (out)
  "Close it. **Unconditional and unpaired with a URL**: every close is the same six bytes, so a
painter that has lost track of which link is open can still emit a correct close."
  (write-char +esc+ out)
  (write-string "]8;;" out)
  (write-string +st+ out))

;;; =============================================================== the table ;;;
;;;
;;; Per FRAME, both of them: an id is only meaningful within the frame that minted it, and a
;;; table that outlived its frame would grow for ever and could hand a row a URL from a screen
;;; nobody is looking at.

(defvar *link-urls* nil
  "A vector of this frame's URLs — the ONE place a target can be read. Written only by
`link-intern`, which is called only by `link-path-url`'s callers.")

(defvar *link-spans* nil
  "This frame's spans: a hash of ROW → vector of `(START END ID)`.

**Integers and columns only.** No text, no escapes, and nothing derived from content, which is
what makes this safe to keep beside a grid that is safe for the same reason.")

(defun link-reset ()
  "Begin a frame: no URLs, no spans."
  (setf *link-urls* (make-array 0 :adjustable t :fill-pointer 0)
        *link-spans* (make-hash-table :test #'eql)))

(defun link-intern (url)
  "URL's id for this frame. The ONE writer of the table."
  (or (position url *link-urls* :test #'string=)
      (progn (vector-push-extend url *link-urls*)
             (1- (length *link-urls*)))))

(defun link-url (id)
  (and (integerp id) *link-urls* (< -1 id (length *link-urls*)) (aref *link-urls* id)))

(defun link-note (row start end id)
  "Record that ROW, columns START..END-1, are ID.

**THE INNER BINDING IS NOT CALLED `row`, and that is not style.** It was, and the `let` shadowed the
row NUMBER with the row's spans — so `(setf (gethash row …))` wrote every span under the key NIL
and `link-row` answered NIL for every row on the screen. Nothing raised: a link that is recorded
nowhere is a link that is simply never drawn, which is the quietest possible failure for this
feature and exactly why `an-image-path-becomes-a-link-…` asserts the PAINTED bytes rather than the
recording."
  (when (and *link-spans* (< start end))
    (let ((have (gethash row *link-spans*)))
      (setf (gethash row *link-spans*)
            (if have
                (let ((v (make-array (1+ (length have)) :adjustable t :fill-pointer 0)))
                  (dotimes (i (length have)) (vector-push-extend (aref have i) v))
                  (vector-push-extend (list start end id) v)
                  v)
                (let ((v (make-array 1 :adjustable t :fill-pointer 0)))
                  (vector-push-extend (list start end id) v) v))))))

(defun link-row (row)
  "ROW's spans, or NIL. **The painter asks this ONCE per row** — most rows have none, and a hash
lookup per cell would be 13,000 of them a frame to learn nothing."
  (and *link-spans* (gethash row *link-spans*)))

(defun link-at (spans col)
  "The span covering COL, or NIL."
  (when spans
    (loop for s across spans
          when (and (<= (first s) col) (< col (second s))) return s)))

;;; ============================================================ the resolution ;;;

(defparameter +image-extensions+
  '("png" "jpg" "jpeg" "gif" "webp" "bmp" "tif" "tiff" "svg" "avif" "heic" "ico")
  "The extensions this head will link.

**An extension is a weak signal and it is the only one the head has.** letibot's `read` on an
image now carries a `Media { mime, … }`, but `Media` has no path and is not on the wire to a head
(R55), so what a row shows is the path the model asked for — and its extension is what says
*this is a picture*. A stronger signal would need a field, and if one is added this list is the
first thing that should go.

It is a WHITELIST and not a blacklist on purpose: a mis-typed extension costs a link that is not
offered, which is nothing, where a wrongly-linked binary is a click that opens a hex editor.")

(defparameter *link-cwd* nil
  "What a relative path resolves against — the session's workspace, set by the renderer.

**A terminal has no idea what this head's working directory is**, so a relative path in a `file://`
URL is not a broken link but a meaningless one: it names `/home/you/foo.png` on whatever machine
the terminal happens to be. Resolved here or not linked at all.")

(defun %path-extension (path)
  (let* ((dot (position #\. path :from-end t))
         (slash (position #\/ path :from-end t)))
    (when (and dot (or (null slash) (> dot slash)) (< dot (1- (length path))))
      (string-downcase (subseq path (1+ dot))))))

(defun image-path-p (path)
  "Does PATH name a picture, by its extension?"
  (let ((ext (and path (%path-extension path))))
    (and ext (member ext +image-extensions+ :test #'string=))))

(defun %url-encode (path)
  "PATH with everything outside the URL path's unreserved set percent-encoded.

**Spaces alone would justify this** — a path with a space in it is ordinary on this box and a bare
space ends a URL — but the rule is applied to everything outside `unreserved /`, because an
un-encoded `?` or `#` silently truncates the URL at the character and the link then opens a
DIFFERENT existing file, which is worse than no link."
  (with-output-to-string (o)
    (loop for ch across path
          for code = (char-code ch)
          do (if (or (and (>= code 97) (<= code 122))   ; a-z
                     (and (>= code 65) (<= code 90))    ; A-Z
                     (and (>= code 48) (<= code 57))    ; 0-9
                     (find ch "-._~/"))
                 (write-char ch o)
                 (format o "%~2,'0X" code)))))

(defun link-path-url (path)
  "A `file://` URL for PATH, or **NIL when it cannot be resolved honestly**.

Three refusals, and each is the operator's own rule rather than caution:

  · **the path must be absolute** after resolution — a relative one is meaningless to a terminal
    that does not know where this head is;
  · **it must EXIST** — `probe-file`, so a path the model typed that is not there renders as plain
    text rather than as a link that fails when clicked. A link that does nothing is worse than no
    link, because the reader has been told something is clickable;
  · **and `truename`** — so `..`, a symlink and a `/proc/self/cwd` all become the real file, which
    is what the terminal is about to hand to a program.

`~` is expanded, because that is how an operator writes a path and how a model often does."
  (when (and path (stringp path) (plusp (length path)))
    (let* ((expanded (let ((raw (if (and (plusp (length path)) (char= (char path 0) #\~))
                                    (merge-pathnames (subseq path 1)
                                                     (uiop:getenv "HOME"))
                                    path)))
                       (if (uiop:absolute-pathname-p raw)
                           raw
                           (if *link-cwd* (merge-pathnames raw *link-cwd*) raw)))))
      (when (uiop:absolute-pathname-p expanded)
        (let ((true (ignore-errors (truename expanded))))
          (when (and true (ignore-errors (probe-file true)))
            (concatenate 'string "file://" (%url-encode (namestring true)))))))))

(defun image-path-link (path)
  "An image path as a link target, or NIL. The ONE call the renderer makes."
  (when (and (image-path-p path) (link-path-url path))
    (link-intern (link-path-url path))))

;;; ============================================================ the switch ;;;
;;;
;;; **ON BY DEFAULT, WITH A PREF TO TURN IT OFF, AND NO `$TERM` SNIFFING.**
;;;
;;; *Why on*: OSC 8 cannot be detected — there is no query — and the failure on a terminal that
;;; does not know it is the GOOD one: the sequence is ignored and the text renders bare. A feature
;;; whose worst case is *nothing happens* and whose default is off is a feature nobody has.
;;;
;;; *Why not `$TERM`*: `$TERM` does not name the terminal emulator. tmux rewrites it to
;;; `screen-256color` for a terminal that may be kitty; ssh passes whatever the far side set; and a
;;; multiplexer sits between this head and the terminal that decides. **A guess keyed on it would be
;;; wrong in both directions** — suppressing links under tmux, where they work, and offering them to
;;; a `dumb` terminal in a pipe, where nothing is clickable at all.
;;;
;;; *Why a boolean and not a chooser*: R38's rule — a setting with more than two values is CHOSEN,
;;; not cycled — does not apply. There are two values, and the reference's fold idiom already
;;; carries them (`%flip-fold`, `:show-tools`).

(defvar *link-enabled* t
  "Whether the painter emits OSC 8 at all.

A `defvar` for the house reason: a live push must not reset the running head's choice. Read per
call rather than cached — it is a plist lookup, and a cached copy is the thing that goes stale.")

(defun link-strip-style (style)
  "STYLE without its `:link` — the style a segment has once the link has been taken out of it.

**The two travel in one plist and must not travel into one table.** A style is interned by value
and kept for the life of the head, so a `:link` left in one would be a URL held in the style table:
unbounded, compared by `equal` on every intern, and content in a structure whose safety argument is
that it holds a character and an integer. Stripped at the painter, which is the only reader that
wants the link."
  (when style
    (loop for (k v) on style by #'cddr unless (eq k :link) append (list k v))))

;;; =============================================================== the fence ;;;
;;;
;;; **THE ONE THING THAT MUST STAY TRUE**, kept beside the escapes it is about so it cannot be
;;; forgotten when this module changes: a URL here is built from a path the HEAD resolved, and no
;;; text that arrived from a payload, a model or a markdown link can reach `link-intern` except
;;; through `link-path-url`'s three refusals — absolute, existing, `truename`d.

(defun link-fence-holds-p (text)
  "Could TEXT become a link target on its own? The fence, made testable.

It is called with the things that must NOT be able to: a payload carrying an OSC 8, model prose
spelling a markdown link, a bare URL. **Answers T only when the text is a path that RESOLVES** —
which is the whole of the fence, because a URL is never taken from text in the first place."
  (and (stringp text) (link-path-url text) t))
