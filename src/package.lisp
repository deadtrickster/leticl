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
   ;; clusters (P7): the unit of measurement is a grapheme cluster, not a char
   #:clusters #:cluster-esc #:cluster-text #:cluster-cols
   #:truncate-to-width #:fit-to-width
   ;; progress — the numbers a turn produces, said in a way a person reads
   #:thousands #:duration #:spinner #:internal-real-time-ms
   #:prefill-fraction #:prefill-cached-fraction #:prefill-computed
   #:prefill-rate #:prefill-eta-ms #:progress-bar #:prefill-line #:decode-line
   ;; cells
   #:make-screen #:screen-resize #:screen-clear
   #:screen-cols #:screen-rows #:screen-cell #:screen-row #:screen-put #:screen-put-string
   #:cell-ch #:cell-style
   #:style-index #:paint-diff #:paint-full
   ;; the two parallel style tables — a restyle may want to read or extend them,
   ;; and the cache is derivable from the specs so it can be repaired in place
   #:*styles* #:*style-sgrs* #:rebuild-style-sgrs
   ;; json
   #:json-decode #:json-encode-to-string
   ;; wire
   #:read-frame #:write-frame #:wire-error #:wire-error-line #:wire-error-detail
   ;; protocol
   #:+protocol-version+
   #:make-attach #:make-ack #:make-prompt #:make-interrupt #:make-answer
   #:match-option
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
   ;; prefs — the head's own choices, on disk
   #:make-prefs #:default-prefs-path #:load-prefs #:save-prefs
   #:prefs-diff #:prefs-thinking #:prefs-tools #:prefs-raw-calls #:prefs-path
   #:load-prefs-into #:save-head-prefs #:head-into-prefs #:prefs-into-head
   ;; chrome (S8) — the alarm, the stall, the money meter, the boxed composer
   #:composer-line #:hint-bar #:alarm-line #:alarm-counts #:alarmed-p
   #:spent-text #:note-turn-cost #:reset-spent
   #:*resyncs* #:*spent-micros* #:*spent-seen* #:*now-ms* #:*last-event-ms*
   #:note-frame-arrived #:stalled-ms #:stall-text #:tick-notice #:say
   #:composer-rows-needed #:composer-inner #:*notice-ttl-frames* #:hint-bar
   #:*notice-ttl* #:*stall-ms* #:*spent-micros* #:*last-event-ms*
   #:session-seq #:session-expected-seq #:session-session-id #:session-items
   #:session-dropped #:session-title #:session-turn #:session-heads
   #:session-warnings #:session-denials #:session-subagents #:session-jobs
   #:session-todos #:session-wiring #:session-open-decisions #:session-sessions
   #:item-lines #:turn-lines #:outcome-name #:edit-lines #:call-lines
   #:turn-footer-lines #:queued-lines
   ;; the item-id maps (S3): what a settled row keeps of the live card
   #:item-facts #:note-call-started #:note-call-finished #:note-call-decision
   #:*item-facts* #:*call-facts* #:*call-started-ms*
   ;; pane scrolling (P41): one offset for every pane, counting from the TOP
   #:pane-scroll-by #:pane-scroll-max #:pane-view #:reset-pane-scroll
   #:scroll-pane-into-view #:*pane-scroll* #:*pane-lines* #:*pane-room*
   ;; the todos pane's unfold state (P42)
   #:*todos-open* #:*repo-todo-cache* #:*repo-todo-stamp*
   ;; clicks (P27)
   #:click-row->sel #:click-header-lines
   ;; the config pane (P21), editable in place
   #:*head-setting-rows*
   ;; engines a model may want to call directly while restyling
   #:highlight-fence #:lang-for-fence
   ;; keys
   #:read-key #:make-composer #:composer-buffer #:composer-cursor
   ;; the editor's windows (S4): the kill ring, undo, the paste ledger
   #:composer-insert #:composer-delete-backward #:composer-delete-forward
   #:composer-move #:composer-kill-to-end #:composer-kill-line #:composer-kill-word
   #:composer-push-history #:composer-history-step
   #:composer-undo #:composer-yank #:composer-kill-region #:composer-insert-paste
   #:expand-pastes #:*kill-ring* #:*kill-ring-max* #:*undo-stack*
   #:*paste-ledger* #:*esc-at* #:*esc-double-ms*
   ;; render
   #:markdown-lines #:wrap-segments #:top-border #:status-line
   #:decision-card-lines #:picker-lines #:help-lines *slash-commands*
   #:quit-card-lines #:secret-card-lines
   #:todos-lines #:repo-todo-lines #:repo-todo-rows #:repo-todo-rows-cached
   #:read-todo-md #:strip-todo-markup
   #:jobs-lines #:subagent-lines #:mode-picker-lines #:models-picker-lines
   #:setting-choices #:setting-value
   #:peek-lines #:config-lines #:status-screen-lines #:help-lines #:picker-lines
   ;; highlight
   #:hl-available-p #:lang-for #:class-grid #:role-style #:highlight-lines
   ;; diff
   #:diff-lines #:diff-lines-with #:hunks #:render-diff #:expand-tabs
   #:word-spans #:apply-diff-to-new #:apply-diff-to-old #:diff-ops #:diff-degraded
   ;; head
   #:%make-head #:run #:*head* #:head-session #:head-prefs #:head-dirty #:head-screen
   #:head-prev-screen
   #:head-last-rows #:head-cols #:head-rows #:head-mode #:head-composer
   #:head-quit-open #:head-secret-req #:head-connected #:head-status-note
   #:head-settings #:head-queued #:head-scroll
   #:head-jobs #:head-subagents #:head-peeked #:head-picker-sel
   ;; hack
   #:hack-start #:hack-stop #:hack-socket-path #:list-live-heads #:hack-handle))

(defpackage #:leticl/tests
  (:documentation "Zero-dep test harness; see PLAN.md §11.")
  (:use #:cl #:leticl)
  (:export #:run-all))
