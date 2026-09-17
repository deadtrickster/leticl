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
  (write-char #\{ s)
  (loop for (k v) on plist by #'cddr
        for firstp = t then nil
        unless firstp do (write-char #\, s)
        do (yason:encode (%key-to-wire k) s)
           (write-char #\: s)
           (%encode v s))
  (write-char #\} s))

(defun %encode-array (list s)
  (write-char #\[ s)
  (loop for el in list
        for firstp = t then nil
        unless firstp do (write-char #\, s)
        do (%encode el s))
  (write-char #\] s))
