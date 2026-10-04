;;;; the-api-key-card — the API-key card
;;;;
;;;; Split out of `commands.lisp`, which was one 1784-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------- the API-key card ;;;
;;;
;;; In `commands.lisp` rather than a file of its own because it is a CARD, and every
;;; other card that takes typed input lives here beside the composer it borrows.
(defvar *key-draft* nil
  "The API-key card: `(:provider NAME :verb NAME)`, or NIL when it is closed.

**A CARD AND NOT A COMPOSER ARGUMENT, and the reason is the transcript.** A key typed
into the composer would be appended to the turn and SENT TO THE MODEL — the operator's
credential in a third party's logs, and in this head's own store for ever. The card is
the one surface whose text never travels: `%key-draft-key` eats the keys, `%key-draft-commit`
writes them to a file, and the composer is never involved.

**THE MASKED FIELD IS THE SECRET CARD'S**, deliberately: there is already a mechanism in
this head for `a field you type secrets into and nobody redraws` (`secret-card-lines`,
built for the sudo prompt), and a second one would be a second place to get the redaction
wrong. The key card renders through it — see `secret-card-lines`.")

(defun provider-key-path ()
  "Where the provider keys live: `$XDG_CONFIG_HOME/letibot/providers.toml`, else under `~/.config`.

**LETIBOT'S FILE, NOT THIS HEAD'S** — the daemon reads it, and it is the daemon the key is
for. This head writes it the same way it writes nothing else of the daemon's: one line,
surgically, leaving every other line where it was (see `%provider-key-write`)."
  (let ((xdg (uiop:getenv "XDG_CONFIG_HOME"))
        (home (uiop:getenv "HOME")))
    (cond (xdg (merge-pathnames "letibot/providers.toml"
                               (uiop:ensure-directory-pathname xdg)))
          (home (merge-pathnames "letibot/providers.toml"
                                 (merge-pathnames ".config/"
                                                  (uiop:ensure-directory-pathname home))))
          (t nil))))

(defun %toml-quote (s)
  "S as a TOML basic string. A key is opaque bytes, so both characters that could end the
string early are escaped rather than trusted not to be there."
  (with-output-to-string (o)
    (loop for c across s
          do (case c
               (#\\ (write-string "\\\\" o))
               (#\" (write-string "\\\"" o))
               (t (write-char c o))))))

(defun %provider-key-write (path provider key)
  "Put KEY under `[PROVIDER]` in PATH, leaving every other line exactly where it was.
Answers `(values T NIL)` when it wrote, `(values NIL REASON)` when it did not.

**LINE-SURGICAL, like `save-prefs`, and for the same reason**: this file holds prices,
model profiles and possibly other providers' keys, and a parse-and-re-render would rewrite
all of it — dropping comments, reordering keys, and turning a one-line edit into a diff the
operator did not ask for in a file they own.

**The three cases, because a fresh box has none of them:**
  · the section exists and already has `key = …` — that line is replaced;
  · the section exists and has no key — the line is inserted under the header;
  · the section does not exist — the whole `[PROVIDER]` block is appended."
  (let* ((text (if (probe-file path) (uiop:read-file-string path) ""))
         (lines (uiop:split-string text :separator '(#\newline)))
         (header (format nil "[~a]" provider))
         (fresh (format nil "key = \"~a\"" (%toml-quote key)))
         (state :no-section)
         (out nil))
    (loop for line in lines
          for trimmed = (string-trim " " line)
          for is-header = (and (plusp (length trimmed)) (char= (char trimmed 0) #\[))
          do (cond
               ;; a new section starts: if ours never got its key, put it in before this
               ((and is-header (eq state :section-no-key))
                (setf state :done)
                (push fresh out) (push line out))
               (is-header
                (when (string= trimmed header) (setf state :section-no-key))
                (push line out))
               ;; inside our section, before any other section began
               ((eq state :section-no-key)
                (if (and (>= (length trimmed) 3) (string= "key" (subseq trimmed 0 3)))
                    (progn (setf state :done) (push fresh out))
                    (push line out)))
               (t (push line out))))
    (when (eq state :section-no-key) (push fresh out))
    (let ((body (format nil "~{~a~^~%~}" (nreverse out))))
      (when (eq state :no-section)
        (setf body (format nil "~a~%~a~%~a~%" body (format nil "[~a]" provider) fresh)))
      (handler-case
          (progn
            (ensure-directories-exist path)
            ;; **TEMP FILE AND RENAME, which the preferences writer also does.** A partial
            ;; providers.toml is a file with no key in it and possibly no prices either, and the
            ;; daemon reads it at startup — so the window matters.
            (let ((tmp (format nil "~a.tmp" (namestring path))))
              (with-open-file (s tmp :direction :output :if-exists :supersede
                                     :if-does-not-exist :create :external-format :utf-8)
                (write-string body s))
              ;; 600: a provider key in a world-readable file is a key somebody else can spend.
              (sb-posix:chmod tmp #o600)
              (rename-file tmp path))
            (values t nil))
        (error (e) (values nil (format nil "~a" e)))))))

(defun %key-draft-open (head verb)
  "Open the API-key card for the provider VERB names, or say which providers exist."
  (let* ((known (list "deepseek" "glm" "grok"))
         (which (string-downcase (or verb "")))
         (provider (find which known :test #'string=)))
    (cond
      ((null provider)
       (say head (format nil "/key needs a provider: ~{~a~^, ~}" known))
       t)
      (t
       (setf *key-draft* (list :provider provider :verb which)
             (composer-buffer (head-composer head)) ""
             (composer-cursor (head-composer head)) 0)
       (say head (format nil "paste the ~a key, then enter — esc loses it" provider))
       t))))

(defun %key-draft-commit (head)
  "Write the typed key and close the card. T when it was taken.

**THE COMPOSER IS EMPTIED WHETHER OR NOT THE WRITE WORKED.** A key left in the buffer is a
key one careless `enter` away from being sent to the model, and the failure is already said
in words — so the discard is unconditional and the message carries the reason."
  (let* ((c (head-composer head))
         (key (string-trim '(#\space #\tab #\newline) (composer-buffer c)))
         (provider (getf *key-draft* :provider))
         (path (provider-key-path)))
    (setf (composer-buffer c) "" (composer-cursor c) 0
          *key-draft* nil
          (head-dirty head) t)
    (cond
      ((zerop (length key)) (say head "no key typed — nothing written"))
      ((null path) (say head "no config directory to write providers.toml into"))
      (t (multiple-value-bind (ok why) (%provider-key-write path provider key)
           (if ok
               ;; **AND IT SAYS WHAT TAKES EFFECT, because the answer is not obvious and the
               ;; operator has already been bitten by a setting that looked saved.** The daemon
               ;; resolves the key when it builds its provider, from the config it read at
               ;; startup — so a running daemon keeps the key it started with.
               (say head (format nil "~a key saved to ~a — restart the daemon to use it"
                                 provider (file-namestring path)))
               (say head (format nil "could not write ~a: ~a" (file-namestring path) why))))))
    t))

(defun %key-draft-key (head key type)
  "The API-key card's own keys. T when the key was claimed.

**EVERY PRINTABLE KEY IS THE FIELD'S**, so the ladder gives this card everything but the
few it owns — the same rule the todo card keeps, and the reason is the same: the text being
typed is the valu. Enter submits, esc loses it, backspace and the arrows edit."
  (declare (ignore type))
  (let ((c (head-composer head))
        (kind (getf key :type)))
    (case kind
      (:enter (progn (%key-draft-commit head) t))
      (:esc (setf *key-draft* nil
                  (composer-buffer c) "" (composer-cursor c) 0
                  (head-dirty head) t)
            (say head "key discarded") t)
      (:backspace (when (plusp (length (composer-buffer c)))
                    (setf (composer-buffer c)
                          (subseq (composer-buffer c) 0 (1- (length (composer-buffer c))))
                          (composer-cursor c) (length (composer-buffer c))
                          (head-dirty head) t))
                  t)
      (:paste (let ((text (or (getf key :text) "")))
                (setf (composer-buffer c) (concatenate 'string (composer-buffer c) text)
                      (composer-cursor c) (length (composer-buffer c))
                      (head-dirty head) t)
                t))
      (:char (let ((ch (getf key :ch)))
               (when (and ch (char/= ch #\newline) (char/= ch #\return))
                 (setf (composer-buffer c) (concatenate 'string (composer-buffer c) (string ch))
                       (composer-cursor c) (length (composer-buffer c))
                       (head-dirty head) t))
               t))
      (t nil))))

(defun key-card-lines (head cols)
  "The API-key card, or NIL when it is closed. Masked, and it says where the key goes."
  (declare (ignore cols))
  (when *key-draft*
    (let ((typed (length (composer-buffer (head-composer head)))))
      (list (list (cons " api key " '(:bold t :fg :yellow))
                  (cons (format nil " ~a" (getf *key-draft* :provider)) '(:bold t)))
            (list (cons " key: " '(:fg :bright-cyan :bold t))
                  (cons (make-string typed :initial-element #\*) nil))
            (list (cons (format nil " ~d character~:p — it is written to providers.toml and never sent to the model"
                                typed)
                        '(:dim t)))
            (list (cons " enter saves · esc discards" '(:dim t)))))))

