;;;; package.lisp — one package on purpose (PLAN.md §6, D3): a model hacking a
;;;; live instance reaches everything without package imports. The package is
;;;; the public API; HACKING.md will name what is contract vs incidental.

(defpackage #:leticl
  (:documentation "The letibot head, rewritten in Common Lisp.")
  (:use #:cl #:alexandria #:anaphora)
  (:nicknames #:lt)
  (:export
   ;; term
   #:with-raw-mode #:terminal-size #:make-tty-streams #:restore-terminal
   #:leave-tui #:leave-raw
   #:enter-tui #:leave-tui #:with-tui-terminal
   #:sync-begin #:sync-end
   ;; width
   #:char-width #:string-width
   ;; clusters (P7): the unit of measurement is a grapheme cluster, not a char
   #:clusters #:cluster-esc #:cluster-text #:cluster-cols
   #:truncate-to-width #:fit-to-width
   ;; progress — the numbers a turn produces, said in a way a person reads
   #:thousands #:duration #:spinner #:internal-real-time-ms
   #:unix-now-ms #:wire-deadline->monotonic #:wire-stamp->started-ms #:deadline-remaining-ms #:deadline-said
   #:on-timeout-said #:+deadline-coarse-ms+ #:+on-timeout-said+ #:*unix-offset-ms*
   #:prefill-fraction #:prefill-cached-fraction #:prefill-computed
   #:prefill-rate #:prefill-eta-ms #:progress-bar #:prefill-line #:decode-line
   ;; cells
   #:make-screen #:screen-resize #:screen-clear
   #:screen-cols #:screen-rows #:screen-cell #:screen-row #:screen-put #:screen-put-string
   #:%esc-sequences
   #:cell-ch #:cell-style
   #:style-index #:paint-diff #:paint-full
   ;; the render failure, and the lock that keeps a push out of a frame. EXPORTED
   ;; because the head's contract now names it in three places outside this file:
   ;; the gate reports it, `/status` explains it, and the alarm raises it.
   #:*last-render-error* #:paint-lock
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
   #:make-answer-question #:question-answer #:make-list-sessions #:make-list-todos #:make-list-jobs
   #:make-set-operator-todos
   #:make-new-session #:make-resume-session #:make-rename-session #:make-fetch-row
   #:make-switch #:make-peek #:make-settings #:make-detach #:make-resync
   #:make-read-job-output
   #:make-screen-answer
   #:encode-frame #:decode-frame #:frame-name #:event-name
   #:next-request-id
   ;; the operator-call door (R24 part two): the daemon's list, and the two frames
   #:+head-run-tools-key+ #:+daemon-verbs-key+ #:head-run-tools #:head-run-descriptors
   #:head-daemon-verbs
   #:next-call-id
   #:make-operator-call #:make-operator-result
   ;; R11's locator: the oracle's own exchange, by the adjudication's id
   #:+diagnostic-kinds+ #:make-fetch-diagnostic
   #:+tool-outcomes+ #:+outcomes-taking-a-reason+
   ;; socket
   #:connect-unix #:discover-daemons #:no-daemon #:no-daemon-socket #:wait-for-input
   ;; session
   #:make-session #:ingest-hello #:ingest-snapshot #:apply-event
   ;; prefs — the head's own choices, on disk
   #:make-prefs #:default-prefs-path #:load-prefs #:save-prefs
   #:prefs-diff #:prefs-thinking #:prefs-tools #:prefs-raw-calls #:prefs-path
   #:load-prefs-into #:save-head-prefs #:head-into-prefs #:prefs-into-head
   #:load-retired-into #:persist-retired #:+retired-cap+
   #:shared-notes-path #:read-retired-keys #:merge-retired-keys #:save-retired-keys #:*notes-path-override* #:notes-path
   #:retired->string #:string->retired #:warning-glyph #:%quote-value
   #:*write-prefs*
   ;; chrome (S8) — the alarm, the stall, the money meter, the boxed composer
   #:composer-line #:hint-bar #:alarm-line #:alarm-counts #:alarmed-p
   ;; R46: the alarm is a pointer, and opening /status is what acknowledges it
   #:*alarms-acked* #:alarm-acked-p #:acknowledge-alarms
   #:spent-text #:note-turn-cost #:reset-spent
   #:*resyncs* #:*spent-micros* #:*spent-seen* #:*now-ms* #:*last-event-ms*
   #:note-frame-arrived #:stalled-ms #:stall-text #:stall-row #:notice-line
   #:tick-notice #:say
   #:turn-status #:composer-title #:composer-wiring #:turn-report-row #:turn-report-text #:composer-boxed-p #:running-jobs
   #:attach-lines #:cat-frame #:attaching-p #:*attach-started-ms* #:+cat-frames+
   #:+attach-wait-ms+ #:attach-overdue-p #:attach-gave-up-said
   ;; the carry line — one row for a fork in flight, in the cat and the bar
   #:carry-line #:*carry-last-done* #:*carry-moved-at*
   #:+body-patience-ms+ #:+carry-min-rows+ #:%carry-counts #:note-carry
   #:reset-carry #:*carry-outstanding*
   ;; a counted operation the daemon reports, and the one renderer both use
   #:*filling* #:note-filling #:reset-filling #:filling-active-p
   #:filling-progress-line
   ;; the history line cache, and the generation that invalidates it
   #:*hist-cache* #:*hist-generation* #:*scroll-anchor* #:*hist-bounds*
   #:%viewport-lines
   ;; ONE place sets a preference, and it is the place that invalidates
   ;; the render cache — see prefs.lisp's header
   #:head-pref
   #:composer-rows-needed #:composer-inner #:+notice-ttl-ms+ #:hint-bar
   #:+live-frame-ms+ #:+live-frame-coarse-ms+ #:live-frame-p #:live-frame-tenths-p
   #:live-frame-interval-ms #:live-frame-due-p #:*last-paint-ms*
   #:notice-remaining-ms #:clear-note #:head-notice-until
   #:*stall-ms* #:*spent-micros* #:*last-event-ms*
   #:session-seq #:session-expected-seq #:session-session-id #:session-items
   #:session-dropped #:session-title #:session-turn #:session-heads #:session-head-id
   #:session-items-dropped
   #:session-warnings #:session-denials #:session-subagents #:session-jobs
   #:session-retired #:warning-identity #:session-retired-p #:note-warning
   #:routine-warning-p #:warning-glyph #:+routine-warnings+
   #:compaction-facts #:compaction-row-p #:note-compaction #:+compaction-row-codes+
   #:session-snapshotted-p #:note-snapshotted #:*snapshotted-sessions*
   #:warning-order #:warning-note-text #:retire-warning #:retire-all-warnings
   #:restore-warnings #:warning-counts #:+note-lines+
   #:warning-listing-lines #:open-notes-listing #:notes-listing-open-p
   #:session-todos #:session-wiring #:session-open-decisions #:session-sessions
   #:turn-running-p #:turn-busy-p
   #:item-lines
   #:+role-faint+ #:+role-failure+
   #:turn-lines #:outcome-name #:edit-lines #:call-lines
   #:turn-footer-lines #:queued-lines #:render-split #:edit-split-lines
   ;; the step: the model's WORKING sits in, under what it SAYS
   #:activity-indent #:step-in-lines #:+activity-indent-cols+
   ;; the item-id maps (S3): what a settled row keeps of the live card
   #:item-facts #:note-call-started #:note-call-finished #:note-call-decision
   #:display-target #:verb-label #:call-target-of #:note-call-target #:*target-max-cols*
   #:%control-char-p #:raw-call-lines
   #:note-assistant-targets #:note-snapshot-targets #:*call-targets*
   #:call-answered-p #:note-answered-call #:*answered-calls* #:%live-elapsed-ms
   #:*item-facts* #:*call-facts* #:*call-started-ms*
   ;; pane scrolling (P41): one offset for every pane, counting from the TOP
   #:pane-scroll-by #:pane-scroll-max #:pane-view #:reset-pane-scroll
   #:scroll-pane-into-view #:*pane-scroll* #:*pane-lines* #:*pane-room*
   ;; the todos pane's unfold state (P42)
   #:*repo-todo-open* #:*repo-todo-cache* #:*repo-todo-stamp* #:repo-todo-stops
   ;; clicks (P27)
   #:click-row->sel #:click-header-lines
   ;; the config pane (P21), editable in place
   #:*head-setting-rows*
   ;; engines a model may want to call directly while restyling
   #:highlight-fence #:lang-for-fence #:fence-token #:fence-grammar-name #:*fence-tokens*
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
   #:wrap-ranges #:locate-in-ranges #:composer-caret #:composer-ranges #:*caret*
   #:markdown-lines #:inline-spans #:reasoning-header #:reasoning-lines
   #:wrap-segments #:top-border #:status-line
   #:decision-card-lines #:picker-lines #:help-lines #:*slash-commands*
   ;; R42: who spoke a user row, and the label the session's own rows carry
   #:%user-speaker #:+session-label+
   ;; the completion surface's own pieces: the head's verbs, the declared shortcuts, and the
   ;; union Tab walks (which is where the daemon's published verbs enter)
   #:+command-aliases+ #:%slash-completions
   ;; R38: the one writer of the rung, and the rungs themselves
   #:set-verbosity #:+verbosity-ladder+ #:+verbosity-said+
   #:verbosity-name #:verbosity-for-word #:+verbosity-other-words+
   ;; R42's sibling: the rung persists, and the interactive writer that keeps it
   #:%choose-verbosity #:prefs-verbosity
   #:permission-card-lines #:card-content-window #:card-scroll-by #:reset-card-scroll
   #:*card-scroll* #:*card-page*
   ;; R40: which row `ctrl-t` acts on, so a seam names the chord only there
   #:newest-payload-row-p #:newest-payload-item-id #:*payload-head*
   #:quit-card-lines #:secret-card-lines
   #:todos-lines #:repo-todo-lines #:repo-todo-rows #:repo-todo-rows-cached
   #:read-todo-md #:strip-todo-markup
   #:peek-row-count #:pane-escape-target #:pane-initial-sel #:picker-initial-sel
   ;; the job-output overlay the jobs pane's enter opens
   #:*job-out* #:*job-out-total* #:open-job-out #:close-job-out
   ;; the slash listing — a verb's reply, when it is a listing and not a sentence
   #:*slash-out* #:note-slash-reply #:close-slash-out #:slash-out-lines
   #:slash-out-row-count #:+slash-listing-lines+
   #:job-out-lines #:job-out-body #:job-out-row-count
   #:subagent-switch
   #:jobs-lines #:subagent-lines #:subagent-rows #:pick-card-lines #:open-pick #:close-pick
   #:take-pick #:pick-by-text #:pick-key-event #:mode-action #:mode-confirm-key
   #:%resolve-session #:%switch-to
   #:mode-confirm-lines #:pick-choices #:pick-current
   #:picker-sessions #:config-rows #:config-change #:pane-width #:wrap-text
   #:tilde-path #:short-id #:bytes-human #:split-row
   #:*rendered-total* #:*scrubbed-total* #:*filtered-total* #:*unreadable-total*
   #:*seq-gaps* #:note-seq-gap #:*hack-accept-errors*
   ;; R16's follow-up: the queued prompt an ANNOUNCED row draws, in its own place
   #:*bound-prompts* #:%bind-echo #:%unbind-echo #:bound-prompt-for
   #:rows-above #:note-row-fetched #:rows-above-line #:prepend-item
   #:fetch-row-above #:*row-fetch* #:*rows-above-gone* #:+row-fetch-len+ #:*scroll-max*
   #:*daemon-protocol*
   ;; the payload window (T1): what makes the rest of a long result reachable
   #:*payload-view* #:*payload-page* #:payload-view-page #:payload-view-close
   #:payload-view-seed #:payload-view-open-p
   ;; R37 amended: the run marker — the two counts a run of hidden rows collapses to, and its opener
   #:reading-hides-p #:hidden-run-lines #:newest-hidden-run-id #:hidden-run-marker
   #:*hidden-run-open* #:%set-hidden-run-open #:*hidden-run-head*
   #:%hidden-run-id #:%marker-onto-last-line #:%hidden-run-counts #:%hidden-run-counts-text #:%hidden-run-counts-segs #:%counts-clause-segs #:%row-invisible-p
   #:marker-rising-p
   ;; dash — the dashboard vocabulary (dash.lisp). A panel is DATA, registered at runtime;
   ;; these are the pieces an operator composes with from a live REPL.
   #:dash-register #:dash-unregister #:dash-panels #:dash-clear-panels #:dash-panel-lines
   #:dash-frame-lines #:dash-line #:dash-bar-text #:dash-style-for
   ;; **THE ASTERISKS ARE PART OF THE NAME, and leaving them off is a silent, baffling bug.**
   ;; `#:dash-samplers` exports a symbol CALLED `dash-samplers`, which nothing ever binds — while
   ;; the variable is `*dash-samplers*`. Every one of these was written without its stars the
   ;; first time, so a test in another package got `UNBOUND-VARIABLE` and read like a missing
   ;; `defvar` rather than a typo in an export list. Eight symbols, one cause.
   #:dash-note #:dash-values #:dash-last #:dash-stale-p #:dash-freshness
   #:dash-age-ms #:dash-oldest-freshness #:dash-reset-series #:dash-direction #:dash-spark
   #:dash-bytes #:dash-bytes-at #:dash-rate #:dash-pct #:dash-counter
   #:dash-bind #:dash-bindings #:dash-nav #:dash-http-get #:dash-parse-metrics
   #:dash-panel-for-job #:dash-job-panels #:dash-panel-at-line #:*dash-line-map*
   ;; R56 — a job-backed panel: the feed, and the five states it always draws
   #:dash-job-matches-p #:dash-job-for-panel #:dash-feed-panels #:dash-feed-due-p
   #:tick-dash-feeds #:dash-note-job #:dash-job-rows #:*dash-fed*
   #:dash-sample-system #:dash-collect-once #:dash-start #:dash-stop #:dash-sampler-add
   #:dash-llama-panels #:dash-llama-dashboard #:dash-register-defaults
   #:*dash-series* #:*dash-interval* #:*dash-panels* #:*dash-views* #:*dash-nav*
   #:*dash-samplers* #:*dash-running* #:*dash-thread* #:*dash-last-error*
   #:hidden-run-marker-room #:+hidden-run-marker-cols+ #:+hidden-run-marker-floor+ #:+hidden-run-count-rungs+ #:+hidden-run-seam-rungs+ #:+hidden-run-marker-ladder+
   #:*marker-seam* #:%set-marker-seam #:+operator-block-style+
   ;; R37's OPEN QUESTION, as a switch: two messages or one prose (the operator rules)
   #:*reading-join-prose* #:%set-reading-join-prose #:%reading-joined-items #:*reading-joined*
   #:reasoning-line-count
   #:protocol-skew-said #:unreadable-said #:file-head-note
   #:%send-slash
   #:setting-choices #:setting-value
   #:peek-lines #:config-lines #:status-screen-lines #:help-lines #:picker-lines
   ;; highlight
   #:hl-available-p #:lang-for #:class-grid #:role-style #:highlight-lines
   #:class-rows #:classed-segments
   #:hl-memo-clear #:*hl-grid-calls* #:+hl-memo-max-chars+ #:+hl-memo-entries+
   ;; diff
   #:diff-lines #:diff-lines-with #:hunks #:render-diff #:expand-tabs
   #:word-spans #:apply-diff-to-new #:apply-diff-to-old #:diff-ops #:diff-degraded
   ;; head
   #:%make-head #:run #:*head* #:head-session #:head-prefs #:head-dirty #:head-screen
   #:head-full-repaint #:%render-and-paint
   #:head-prev-screen
   #:head-last-rows #:head-cols #:head-rows #:head-mode #:head-composer
   #:head-farewell #:head-quit-open #:head-secret-req #:head-connected #:head-status-note
   #:head-settings #:head-queued #:head-scroll #:head-screen-reqs #:head-want-new
   #:*queued-unconfirmed* #:%resolve-queued #:%re-resolve-queued
   #:head-jobs #:head-subagents #:head-peeked #:head-picker-sel
   ;; the operator-call door (R24 part two), the head's half
   #:*head-tool-runners* #:*op-calls* #:+op-call-wait-ms+ #:tick-op-calls #:%op-call-ask
   #:*op-call-draft* #:op-call-draft-open-p #:op-call-card-lines #:%op-call-draft-key
   ;; R44: the operator's own todo items — the list, the add verb, and the modal card
   #:*operator-todos* #:operator-todo-add #:note-todo-ids #:push-operator-todos #:*todo-draft* #:todo-draft-open-p #:todo-card-lines
   #:operator-todos-path #:read-operator-todos #:persist-operator-todos #:operator-todos->text #:text->operator-todos #:+operator-todos-cap+ #:save-operator-todos #:load-operator-todos #:*todo-file-unreadable*
   ;; the head's own sqlite store (src/store.lisp)
   #:store-path #:store-available-p #:store-close #:*store-path-override* #:*store-unavailable*
   #:store-load-todos #:store-save-todo #:store-delete-todo #:store-replace-todos #:*sqlite-library*
   #:%todo-draft-open #:%todo-draft-key #:%todo-draft-field
   ;; R11's locator
   #:*diag* #:diagnostic-listing-lines #:open-diagnostic-listing #:%diagnostic-ask
   ;; hack
   #:hack-start #:hack-stop #:hack-socket-path #:list-live-heads #:hack-handle
   #:head-hack-listener #:head-hack-path #:hack-accept-loop #:hack-serve
   ;; links — OSC 8, kept OUT of the grid (links.lisp). The operator: *"i also dont mind if image
   ;; path will be rendered as a link so a click will open the image for me."*
   #:link-reset #:link-note #:link-row #:link-at #:link-url #:link-intern
   #:link-path-url #:image-path-p #:image-path-link #:link-strip-style
   #:link-fence-holds-p #:links-said #:*link-enabled* #:*link-cwd* #:*link-urls* #:*link-spans*
   #:%url-encode #:%osc8-open #:%osc8-close))

(defpackage #:leticl/tests
  (:documentation "Zero-dep test harness; see PLAN.md §11.")
  (:use #:cl #:leticl)
  (:export #:run-all))
