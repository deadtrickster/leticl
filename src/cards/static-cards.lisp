;;;; static-cards.lisp — the rows that say exactly one thing: a system prompt's origin
;;;; (bootstrap or update), a `/compact` boundary, and a row fetched back from the
;;;; session. Three kinds in one file because each is a few lines of text and none of
;;;; them has state, helpers or a second shape.

(in-package #:leticl)

(defclass system-card (card) ())
(defclass segment-mark-card (card) ())
(defclass fetched-card (card) ())

(defmethod card-lines ((card system-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    (let ((origin (or (getf body :origin) "")))
      (cons (list (cons (format nil "system (~a)"
                                (if (plusp (length origin))
                                    (format nil "~a~a" (char-upcase (char origin 0))
                                            (subseq origin 1))
                                    origin))
                        +md-faint+))
            (mapcar (lambda (l)
                      (mapcar (lambda (seg) (cons (car seg) +md-faint+)) l))
                    (wrap-segments (list (cons (or (getf body :text) "") nil))
                                   cols)))))
  ;; **A `/compact` boundary is a row** (app.rs:10042-10044). The `case`
  ;; had no arm for it, so it fell to `(t nil)` and a segment boundary —
  ;; the one place in a transcript where the model's memory of everything
  ;; above it changed — drew nothing at all.
  )

(defmethod card-lines ((card segment-mark-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    (list (list (cons (format nil "─── ~a ───" (or (getf body :label) ""))
                      +md-faint+))))
  ;; **A ROW FETCHED BACK FROM THE SESSION** (`FetchRow`) — a row older than
  ;; this head's window, pulled in one at a time as the reader scrolls to the
  ;; top. It is its own type because the head knows only what the frame says:
  ;; a body and an ordinal. `RowFetched` carries no kind, no name and no
  ;; timestamp, so drawing it as a tool card or as prose would be inventing
  ;; facts about a row the head has never seen — what it CAN say is where the
  ;; row sits in the session and what the body is.
  ;;
  ;; Folded like every other long thing here: the head of it, and a seam saying
  ;; how much more there is. `:total` is the WHOLE body's length from the
  ;; daemon, so the seam counts what the window did not carry rather than
  ;; guessing from the lines that arrived.
  )

(defmethod card-lines ((card fetched-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    (let* ((row (getf body :row))
           (text (or (getf body :text) ""))
           (total (or (getf body :total) 0))
           (rows (wrap-segments (list (cons text nil)) cols))
           (cap +body-lines-budget+)
           (hidden (max 0 (- (length rows) cap)))
           (shown (if (plusp hidden) (subseq rows 0 cap) rows)))
      (append
       (list (list (cons (format nil "  ▸ row ~d of the session" row) '(:dim t)))
             (list (cons (format nil "    ~a line~:p" (length rows)) '(:dim t))))
       (mapcar (lambda (l) (mapcar (lambda (seg) (cons (car seg) nil)) l)) shown)
       ;; the seam names the BYTES the window left behind when the daemon said
       ;; the body is longer than one fetch, and the rows when it did not — two
       ;; different truncations and only one of them may be claimed
       (when (plusp hidden)
         (list (list (cons (format nil "    … +~d line~:p~@[ · +~d bytes~]"
                                   hidden
                                   (let ((sent (length text)))
                                     (and (> total sent) (- total sent))))
                           '(:dim t))))))))
  ;; **A ROW THIS HEAD WROTE ABOUT ITSELF.** No daemon item has this type — the
  ;; wire's are `user`, `assistant`, `reasoning`, `tool_result`, `system` and
  ;; `segment_mark` — so this is the head filing a sentence of its own into the
  ;; conversation at the point it happened. `note-unreadable` and `note-warning`
  ;; are the writers, and the contract is the one the reference's `warn_line`
  ;; keeps: an `!`, the words, and the failure role (app.rs:8425-8427).
  ;;
  ;; **`:cap` and `:seam` fold a long one** (R10). A warning's detail can be a
  ;; whole rule, and the operator-facing complaint was a WALL of them — 27 red
  ;; lines from two gate timeouts. A note with a `:cap` shows that many rows and
  ;; a `:seam` naming the verb that has the rest, and the seam is DIM rather than
  ;; failure-role because it is not part of the warning: it is the instrument.
  ;; The whole text is still what `/notes` prints, so this folds a disclosure
  ;; and never the record.
  )

