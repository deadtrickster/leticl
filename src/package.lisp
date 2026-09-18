;;;; package.lisp — one package on purpose (PLAN.md §6, D3): a model hacking a
;;;; live instance reaches everything without package imports. The package is
;;;; the public API; HACKING.md will name what is contract vs incidental.

(defpackage #:leticl
  (:documentation "The letibot head, rewritten in Common Lisp.")
  (:use #:cl #:alexandria #:anaphora)
  (:nicknames #:lt)
  (:export
   ;; term
   #:with-raw-mode #:terminal-size #:make-tty-streams
   #:enter-tui #:leave-tui #:with-tui-terminal
   #:sync-begin #:sync-end
   ;; width
   #:char-width #:string-width
   ;; cells
   #:make-screen #:screen-resize #:screen-clear
   #:screen-cols #:screen-rows #:screen-cell #:screen-put #:screen-put-string
   #:cell-ch #:cell-style
   #:style-index #:paint-diff #:paint-full
   ;; json
   #:json-decode #:json-encode-to-string
   ;; wire
   #:read-frame #:write-frame #:wire-error #:wire-error-line #:wire-error-detail
   ;; protocol
   #:+protocol-version+
   #:make-attach #:make-ack #:make-prompt #:make-interrupt #:make-answer
   #:make-answer-question #:make-list-sessions #:make-list-todos
   #:make-new-session #:make-resume-session #:make-rename-session
   #:make-switch #:make-peek #:make-settings #:make-detach #:make-resync
   #:make-screen-answer
   #:encode-frame #:decode-frame #:frame-name #:event-name
   #:next-request-id
   ;; socket
   #:connect-unix #:discover-daemons #:wait-for-input
   ;; session
   #:make-session #:ingest-hello #:ingest-snapshot #:apply-event #:ack-frame
   #:session-seq #:session-expected-seq #:session-session-id #:session-items
   #:item-lines #:turn-lines #:outcome-name
   ;; keys
   #:read-key #:make-composer #:composer-buffer #:composer-cursor
   ;; render
   #:markdown-lines #:wrap-segments #:top-border #:status-line
   #:decision-card-lines #:picker-lines #:help-lines *slash-commands*
   ;; head
   #:run #:*head* #:head-session #:head-prefs #:head-dirty #:head-screen
   #:head-last-rows #:head-cols #:head-rows #:head-mode #:head-composer
   ;; hack
   #:hack-start #:hack-stop #:hack-socket-path #:list-live-heads #:hack-handle))

(defpackage #:leticl/tests
  (:documentation "Zero-dep test harness; see PLAN.md §11.")
  (:use #:cl #:leticl)
  (:export #:run-all))
