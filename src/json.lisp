;;;; json.lisp — the wire's JSON convention, in one place (PLAN.md §7).
;;;;
;;;; Wire objects decode to plists with keyword keys: "session_id" becomes
;;;; :session-id. Encoding is the inverse. The encoder never elides: every key
;;;; present in the plist is emitted, nil becomes null, t becomes true, a
;;;; keyword VALUE becomes its snake_case string (enum vocabulary like
;;;; :in_progress), a plist becomes an object, any other list becomes an array.
;;;; Empty arrays are not representable (NIL is null), so frame constructors
;;;; omit serde-default fields at their default instead of writing [].

(in-package #:leticl)

(defun %key-from-wire (string)
  (intern (substitute #\- #\_ (string-upcase string)) :keyword))

(defun %key-to-wire (key)
  (substitute #\_ #\- (string-downcase (symbol-name key))))

(defun json-decode (line)
  "One JSON line to a plist. Arrays stay lists. yason decodes true→t and
both false and null→nil; we never re-encode a decoded frame (we construct our
own), so the false/null ambiguity costs nothing today — noted here because it
becomes a bug the day something round-trips."
  (yason:parse line
               :object-as :plist
               :object-key-fn #'%key-from-wire))

(defun json-encode-to-string (object)
  (with-output-to-string (s) (%encode object s)))

(defun %plist-p (x)
  "A proper list whose car is a keyword, of even length, all keys keywords.
We never send arrays of keywords, so this closes the object/array ambiguity
by convention (PLAN.md §7)."
  (and (consp x)
       (keywordp (car x))
       (alexandria:proper-list-p x)
       (evenp (length x))
       (loop for (k v) on x by #'cddr
             always (keywordp k))))

(defun %encode (v s)
  (typecase v
    (integer (yason:encode v s))
    (float (yason:encode v s))
    (string (yason:encode v s))          ; yason escapes quotes, backslash, control
    (keyword
     (cond ((eq v :true) (write-string "true" s))
           ((eq v :false) (write-string "false" s))
           (t (yason:encode (%key-to-wire v) s))))
    (symbol (if (eq v t)
                (write-string "true" s)
                (write-string "null" s))) ; nil and any other symbol: null
    (cons (if (%plist-p v) (%encode-object v s) (%encode-array v s)))
    (hash-table (yason:encode v s))
    (t (error "cannot encode ~s as json" v))))

(defun %encode-object (plist s)
  "Write PLIST as a JSON object, **OMITTING every key whose value is NIL**.

**Absent is the only spelling that is always accepted, so it is the one this
encoder writes.** Serde on the daemon side has three field shapes and they do not
agree about a present `null`:

  · `Option<T>` accepts a missing key AND a present null — both deserialise to
    `None`, so dropping it costs nothing;
  · `T` with `#[serde(default)]` accepts a MISSING key and **rejects** a present
    null — serde's default fills in for absence, not for null;
  · a bare required `T` accepts neither.

So eliding is never worse than nulling and strictly better for the middle case —
which is the case that has bitten this head twice: `Mode.consented` (protocol.rs:452,
fixed in `%send-mode`) and `ReseatSession.summarise` (protocol.rs:519, fixed in
commands.lisp) both had to be written `:false` by hand, because a present `null` on a
`bool` broke the daemon's read loop and took the socket with it. A hazard fixed three
times by hand is a pattern, not an accident.

**The root cause is that NIL is overloaded in Lisp** — it is both `false` and
`nothing` — and an encoder cannot tell which one it is looking at. So the ambiguity is
resolved where the knowledge is: a key is written when its value is a VALUE, and
`:false` is how a caller says *this nil is a false*. Both hand-fixed sites keep their
explicit `:false`, because for a field like that the presence of `false` reads better
than its absence; what changes is that a THIRD site cannot reach the daemon by
accident. Measured over every constructor in protocol.lisp: no client frame this head
can build carries a null anywhere.

**The one shape this cannot help is the third**: a bare required field is fatal both
missing and null, so an empty payload has to be refused where the frame is BUILT —
see `make-answer-question`.

**An ARRAY element is not a key** and keeps its null: `[null]` is a value in a
position, and there is no \"absent\" for a list element to fall back to.

The disclosure rule in protocol.lisp's header (*fields whose presence is the
disclosure are always written, present and zero/null rather than omitted*) is the
DAEMON's rule about the frames it SENDS — `dropped`, `created`, `snapshot` — and this
encoder writes only the client's. Nothing this head sends is a disclosure of that
kind, which is why an earlier test of the opposite rule (`json-encode-nil-is-null-
never-elided`) was asserting a property of the other side of the wire."
  (write-char #\{ s)
  ;; **The separator flips only when something is actually WRITTEN.** A `for firstp = t
  ;; then nil` in the loop advances on every pair, elided ones included, so the first
  ;; surviving key after an elided one was prefixed with a comma and the frame was
  ;; `{,"b":1}` — invalid JSON, and it would have taken the socket down the way the null
  ;; did. Measured by encoding every constructor: the first version of this elision
  ;; broke `make-prompt` and `make-new-session` at once.
  (let ((firstp t))
    (loop for (k v) on plist by #'cddr
          ;; the elision, in one place: the key goes out only when there is a value
          unless (null v)
            do (progn
                 (unless firstp (write-char #\, s))
                 (setf firstp nil)
                 (yason:encode (%key-to-wire k) s)
                 (write-char #\: s)
                 (%encode v s))))
  (write-char #\} s))

(defun %encode-array (list s)
  (write-char #\[ s)
  (loop for el in list
        for firstp = t then nil
        unless firstp do (write-char #\, s)
        do (%encode el s))
  (write-char #\] s))
