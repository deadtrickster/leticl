# Wire and session state — leticl against letibot


**The `src/…` citations below name the PRE-SPLIT paths** — `src/session.lisp`,
`src/editor.lisp`, `src/panes.lisp` — because that is what was read when the row was
measured. The tree has since been cut into directories (`PLAN.md` §6 maps every one), and
re-measuring these citations is a pass of its own, on the same terms as the repin: a
citation is a record of what was read, never a claim about where it is now.
**Reference** `/home/dead/Projects/letibot/letibot` at `8af671e3467ce0a139ba25d99a18378ba39c910b`
(verified with `git -C … rev-parse HEAD`). **The pin is now `149edf91b9740ac7775a0a875abfcd562c8fd3e6`
(2026-10-04), and of the 201 `file.rs:NNN` citations below 3 are still exact against it —
192 have moved and one points past the end of a file that changed shape**; re-read the
function, not the line, and see TODO.md's pin section (`scripts/repin-check` measures it).
**Subject** `/home/dead/Projects/leticl` at `dc62ddf` (2026-09-20 22:19; the pass
finished at `7c2c6fc`, 23:37).

**A SNAPSHOT, NOT THE TREE — and on 2026-09-22 that cost a day's work.** Twenty-three
minutes after this pass closed, `b7a2620` landed (**Enter on a jobs row opens the
output in a pane**) — and nothing re-measured the rows that said otherwise: **W2** and
**W15** here, `panes.md` **G4**, `keys.md` **G20**, and `TODO.md`'s T1(3). They went on
saying MISSING and OPEN, and on 2026-09-22 a driver read them and handed that line to
the head as work: *"Take T1(3) — it is the one B-side defect left"*, on a defect that
had been closed for a day and a half. **The §2.6 incident, mirrored**: that one was a
commit message claiming work that was not there, this one is four files claiming work
was MISSING that was there. Neither is catchable by a test, and both are catchable by
one rule — *a criterion names a test, and the test is run from the tree as committed*.

Those rows now carry the measurement and its date. **Every other row here is true of
`dc62ddf` and says nothing about today; re-measure before acting on one.** Re-measured
2026-09-22 against the tree at `047f9ad` (the behaviour landed in `b7a2620`): this
file's **W2**, **W15**, the **`ReadJobOutput`** row, the **`JobOutput`** row, §4f's retire
half (part of **W16**), and §4i's jobs bullet; `panes.md` **G4** names the evidence.

Surface: the frames, the events, the session fold, the exchange. Not keys, not
commands, not rendering, not panes — those are measured elsewhere.

Every claim below is `file:line` on both sides. Where a fact was *executed*
rather than read it is quoted as `probe:` / `probe2:` — two throwaway ASDF
loads of `:leticl` that fold synthetic envelopes through `apply-event` and
`ingest-hello`, encode frames with `encode-frame`, and print what the plists and
the wire actually hold. Nothing in `src/` was modified to measure any of it.

---

## Summary

| measure | count |
|---|---|
| `ClientFrame` variants in the reference (`protocol.rs:319-712`) | **29** |
| …constructed by leticl | **26** |
| …of the 3 missing, also not sent by the reference TUI | 2 (`Askpass`, `FetchRow`) |
| …genuinely missing | **1** (`ReadJobOutput`) |
| `ServerFrame` variants (`protocol.rs:735-879`) | **13** |
| …handled by `%handle-frame` with a named arm | **11** |
| …reaching the `(t :control)` wildcard, which is what the reference also does | 2 (`secret`, `row_fetched`) |
| `SessionEvent` variants (`event.rs:945-973`) | **29** |
| …folded by `apply-event` (`session.lisp:170-400`) | **24** |
| …answered by `%handle-frame` instead (`head.lisp:184-192`) | 2 (`screen_requested`, `secret_requested`) |
| …deliberately nothing on both sides | 1 (`explain`) |
| …**reaching nothing at all** | **2** (`secret_settled`, `job_output`) |
| `Snapshot` fields (`view.rs:278-297`) ingested by `ingest-snapshot` | **10 of 10** |
| dead constructors (`make-*` with no caller) | **0** — but `ack-frame` (`session.lisp:411`) is a dead wrapper |
| session slots written by the fold and **read by nothing** | **5** |

The headline: the *frame* vocabulary is close to complete and the *fold* is
close to complete, and four classes of defect sit underneath that —

- **(a) two frames that do not survive contact with the daemon.** A `Hello`
  answering a resume (`snapshot: null`) raises a `TYPE-ERROR` in `ingest-hello`,
  so no reconnect and no resume has ever actually worked (**W25**); and
  `/mode NAME` puts `"consented":null` on the wire, which the daemon cannot
  deserialise and answers by closing the connection (**W1**). Both measured.
- **(b) folds that write into a place that is not there.** `ToolProgress`'s note
  goes to a `getf` place that does not exist (**W11**); `ToolStarted` never moves
  a proposed call to running (**W9**); `turn.appended` is initialised and never
  written (**W20**); `turn.progress` outlives its turn (**W18**).
- **(c) four session slots that the fold fills and nothing reads** — notices,
  settled decisions, denials, job settlements (**W13**, **W12**, **V15 — closed**).
  Every daemon-side `Slash` reply lands in one of them. `warnings` was the
  fifth and left this list with R10: it is drawn as a row where it arrived,
  retired by `/notes`, and counted as `notes  N of M retired`.
- **(d) the job-output round trip**, missing at both ends (**W2**).

---

## 1. Every frame in the protocol

`PROTOCOL_VERSION` is `21` (`protocol.rs:210`); leticl sends `21`
(`protocol.lisp:14`, measured on the wire — `probe:` `{"frame":"attach","protocol_version":21,…}`).
See §5 for what a mismatch does.

### 1a. `ClientFrame` — constructed, and sent?

| reference | citation | leticl | citation | verdict |
|---|---|---|---|---|
| `Attach{protocol_version,session_id,since_seq,kind,identity,caps}` | `protocol.rs:325` | `make-attach`, sent at first attach and on every reconnect | `protocol.lisp:72`, `head.lisp:440`, `head.lisp:300` | SAME |
| `Ack{seq,rendered,filtered}` | `protocol.rs:337`,`722` | `make-ack`, sent after the paint | `protocol.lisp:83`, `head.lisp:385` | SAME |
| `Resync` | `protocol.rs:340` | `make-resync`, `/resync` | `protocol.lisp:88`, `commands.lisp:133` | SAME |
| `Prompt{client_request_id,expected_seq,text}` | `protocol.rs:343` | `make-prompt` | `protocol.lisp:91`, `commands.lisp:48` | SAME |
| `WithdrawPrompts{client_request_id,expected_seq}` | `protocol.rs:354` | `make-withdraw-prompts`, ctrl-u | `protocol.lisp:103`, `editor.lisp:440` | DIFFERS — frame identical, local bookkeeping is not; see §4f |
| `Stop{client_request_id,expected_seq,who}` | `protocol.rs:379` | `make-stop`, quit card | `protocol.lisp:110`, `editor.lisp:178` | DIFFERS — `who` is the literal `"leticl"`; the reference sends `client.identity()` (`driver.rs:208`), which is the name it attached under. leticl's attach identity is also `"leticl"` (`head.lisp:441`), so the strings agree today by coincidence, not by construction |
| `Interrupt{client_request_id,expected_seq,reason}` | `protocol.rs:387` | `make-interrupt` | `protocol.lisp:97`, `commands.lisp:203` | SAME |
| `Promote{client_request_id,expected_seq}` | `protocol.rs:395` | inline plist | `commands.lisp:159` | SAME |
| `CompactSession{client_request_id,expected_seq}` | `protocol.rs:407` | inline plist | `commands.lisp:142` | SAME |
| `ReseatSession{…,summarise}` | `protocol.rs:418` | inline plist, `summarise` omitted | `commands.lisp:146` | SAME — omission is the lossless fork, which is what `protocol.rs:927` asserts an old head gets. `/reseat summarise` is unreachable, which is a commands-surface gap |
| `Mode{client_request_id,expected_seq,name,consented}` | `protocol.rs:438` | inline plist | `panes.lisp:517`, `panes.lisp:1218` | **DIFFERS — broken.** `%send-mode` with `consented = nil` puts `"consented":null` on the wire. `probe:` `{"frame":"mode",…,"consented":null}`. `consented: bool` with `#[serde(default)]` accepts a *missing* key, not a present `null`; the frame fails to deserialise and `server.rs:898` breaks the connection loop with `Err`. See gap **W1** |
| `Slash{client_request_id,expected_seq,line}` | `protocol.rs:460` | `%send-slash`, and the unknown-verb fallthrough | `commands.lisp:197`, `commands.lisp:173` | SAME |
| `Askpass{prompt,command}` | `protocol.rs:473` | — | — | MISSING, correctly: it is `letibot-askpass`'s frame, not a TUI's. The reference TUI does not send it either (`client.rs:351` is the helper's) |
| `Secret{req_id,secret}` | `protocol.rs:478` | inline plist; `secret` is the buffer, or **the key is absent** when the password is refused | `editor.lisp:159`, `editor.lisp:164` | SAME — `secret` is `Option<String>`, which reads a missing key and a null alike, so the refusal now goes out with no `secret` key at all (§4.5's elision). `probe:` used to show `"secret":null` |
| `Screen{req_id,cols,rows_n,rows}` | `protocol.rs:492`, sent as the terminal size at `driver.rs:287` | `make-screen-answer`, which requires COLS and ROWS-N and no longer derives either | `protocol.lisp:362-386`, `head.lisp:681-704` | **DIFFERS only in WHEN (gap W6, now closed for the drain path)**; the *numbers* are SAME as of §4.4 — this used to send `(length (first rows))`, the character length of row zero **with its ANSI bytes counted**, so a 100-column frame reported 100 + every SGR byte in its top row and the daemon believed it. `head-last-cols`/`head-last-rows-n` are set beside `head-last-rows` by one paint, so all three describe one frame |
| `Answer{client_request_id,req_id,option_id,pattern,note}` | `protocol.rs:505` | `make-answer`, `pattern`/`note` omitted when nil | `protocol.lisp:195`, `editor.lisp:71`,`106` | SAME |
| `AnswerQuestion{client_request_id,req_id,answer}` | `protocol.rs:644-648` | `make-answer-question`, which now REFUSES an empty answer; `note` and `free` are both buildable | `protocol.lisp:225-263`, `editor.lisp:68` | W7's `note`/`free` half is SAME; **§4.5 is closed** — `answer` is a bare required `QuestionAnswer` and not an `Option`, so `"answer": null` fails the whole `ClientFrame` deserialiser and ends the daemon's read loop. It was unreachable only because the sole caller passes `(list :option idx)` |
| `ListSessions` | `protocol.rs:569` | `make-list-sessions` | `protocol.lisp:145`, `commands.lisp:61` | SAME |
| `ListTodos` | `protocol.rs:577` | `make-list-todos` | `protocol.lisp:148`, `commands.lisp:119` | SAME |
| `ListJobs` | `protocol.rs:585` | `make-list-jobs` | `protocol.lisp:151`, `commands.lisp:111` | SAME |
| `NewSession{client_request_id,title,workspace}` | `protocol.rs:592` | `make-new-session`, **`workspace` always `""`** | `protocol.lisp:160`, `commands.lisp:59`, `head.lisp:446` | DIFFERS — the reference sends its own cwd (`driver.rs:147-150`), and `protocol.rs:599-607` records what an empty one costs: the new session's read-only tools are seated at the daemon's directory, "and every path in it resolved, so the only symptom was answers about the wrong tree". See gap **W3** |
| `ResumeSession{client_request_id,session_id}` | `protocol.rs:624` | `make-resume-session` | `protocol.lisp:166`, `commands.lisp:139` | SAME |
| `RenameSession{client_request_id,session_id,title}` | `protocol.rs:633` | `make-rename-session` | `protocol.lisp:171`, `commands.lisp:67` | SAME |
| `Switch{session_id,since_seq}` | `protocol.rs:645` | `make-switch`, always `since_seq 0` | `protocol.lisp:177`, `commands.lisp:64`, `editor.lisp:320` | SAME — the reference also sends `0` (`driver.rs:156`) |
| `Peek{session_id}` | `protocol.rs:660` | `make-peek` | `protocol.lisp:182`, `commands.lisp:126`, `editor.lisp:289` | SAME |
| `FetchRow{session_id,row,at,len}` | `protocol.rs:680` | — | — | MISSING on both sides. The reference documents its own absence at `app.rs:1794-1807` and files it as `TODO.md` R19.2 |
| `Settings` | `protocol.rs:697` | `make-settings` | `protocol.lisp:185`, `head.lisp:178` | SAME — asked once, from the `hello` arm, which covers attach, switch and reconnect |
| `ReadJobOutput{client_request_id,job,offset}` | `protocol.rs:704` | `make-read-job-output` | `protocol.lisp:293`, `editor.lisp:854` (Enter on a jobs row), `editor.lisp:797` (paging) | **SAME — re-measured 2026-09-22.** Field for field; the answer comes back as `SessionEvent::JobOutput` and the head's `:job-output` arm folds it into the overlay that asked (`session.lisp:1419-1446`). This row said MISSING from 2026-09-20 23:37 until 2026-09-22 — the fix landed in `b7a2620`, 23 minutes after this table was measured. See gap **W2** |
| `Detach` | `protocol.rs:711` | `make-detach` | `protocol.lisp:188`, `head.lisp:455` | SAME |

**Dead code check.** Every `make-*` in `protocol.lisp` has at least one `%send`
caller (grep over `src/`, cross-checked against `package.lisp:37-42`). The one
dead item is `ack-frame` (`session.lisp:411`) — exported at `package.lisp:48`,
documented as *the* read mark, and called by nothing: `run-loop` builds
`(make-ack last-seq …)` directly (`head.lisp:385`). Harmless today, and a trap
tomorrow, because the two spellings disagree about where the seq comes from —
`ack-frame` reads `session-seq` (the last seq *folded*) and the loop reads
`last-seq` (the last seq *read*). `cursor.rs` / `protocol.rs:717-720` say the
second is the only correct one. Verdict: **DEAD-CODE, and the dead copy is the
wrong one.**

### 1b. `ServerFrame` — handled?

| reference | citation | leticl | citation | verdict |
|---|---|---|---|---|
| `Hello{protocol_version,session_id,head_id,dropped,snapshot,resumed_from,scrubbed,wiring,sessions}` | `protocol.rs:744-781` | `ingest-hello` | `head.lisp:162-179`, `session.lisp:87-109` | DIFFERS — `protocol_version` is never read; `dropped` is assigned, not accumulated; the session list is not filtered. See §3 and §5 |
| `Secret{secret}` | `protocol.rs:791` | wildcard `(t :control)` | `head.lisp:267` | SAME — the reference also does nothing (`app.rs:1836`); it is only ever written to an `askpass` head |
| `Sessions{sessions,current,created}` | `protocol.rs:792` | named arm | `head.lisp:230-234` | DIFFERS — `current` and `created` are both dropped. The reference sets `session_id = current` and, when `created` is this head's `/new`, queues a `Switch` to it (`app.rs:1736-1744`). leticl's `/new` and `--new TITLE` therefore create a session and leave you where you were. See gap **W4** |
| `Todos{session_id,todos}` | `protocol.rs:803` | named arm | `head.lisp:239-242` | DIFFERS — `session_id` is not checked. The reference ignores a reply for a session it has since left (`app.rs:1775`) |
| `Settings{rows}` | `protocol.rs:813` | named arm, stamps `*model-from-settings-at*` | `head.lisp:243-253` | SAME (`app.rs:1786-1792`) |
| `Jobs{session_id,jobs}` | `protocol.rs:816` | named arm | `head.lisp:235-238` | DIFFERS — `session_id` not checked (`app.rs:1767`) |
| `Peeked{session_id,dropped,events}` | `protocol.rs:820` | named arm, opens `:peek` | `head.lisp:254-261` | SAME — all three fields kept |
| `RowFetched{…}` | `protocol.rs:839` | wildcard | `head.lisp:267` | SAME by effect; the reference keeps an explicit arm *so an unhandled frame is visible* (`app.rs:1804-1807`), and leticl's wildcard is the swallowing that comment warns about |
| `Event(Envelope)` | `protocol.rs:852` | named arm → `apply-event` | `head.lisp:180-203` | SAME |
| `Resync{reason,dropped,snapshot,scrubbed}` | `protocol.rs:856` | named arm | `head.lisp:204-212` | DIFFERS — `dropped` and `scrubbed` are both dropped on this path. The reference adds both (`app.rs:1843-1845`). See gap **W8** |
| `Accepted{client_request_id,seq,note}` | `protocol.rs:863` | named arm, suppresses `NOTE_PROMPT_QUEUED` | `head.lisp:213-222` | SAME (`app.rs:1862-1870`) |
| `Rejected{client_request_id,reason,expected_seq,actual_seq}` | `protocol.rs:871` | named arm, both numbers said | `head.lisp:223-229` | SAME (`app.rs:1872-1884`) |
| `Bye{reason}` | `protocol.rs:878` | named arm: note + `connected = nil` | `head.lisp:262-266` | **DIFFERS.** The reference sets `quit = true` and the head leaves (`app.rs:1886-1889`); the pump also stops on a `Bye` (`client.rs:548`). leticl stays running and `%try-reconnect` re-attaches every 2 s (`head.lisp:283-316`), so a refusal the daemon meant as final becomes a loop. See gap **W5** and §5 |

---

## 2. Every event

`apply-event` returns `:dirty`/`:quiet`; `%handle-frame` maps those to
`:rendered`/`:filtered` (`head.lisp:201-203`), which is the reference's
`Disposition` (`driver.rs:57-61`). The classification is compared below only
where it changes what the ack reports.

| reference | citation | leticl | citation | verdict |
|---|---|---|---|---|
| `Filling{what,unit,done,total}` | `event.rs:964-974`, published at `harness.rs:2768` | `note-filling` — the four fields folded and the line drawn from them, the daemon's words verbatim | `src/session.lisp:546-566`, `src/chrome.lisp:1195-1215` | **SAME**, and this is R9's second half: the head draws the daemon's `what` and `unit` rather than naming an operation it inferred, and the count is the daemon's rather than a rendering of it. Added at protocol 23 (letibot `4d01aca`), which **replaced** `ImportProgress` — the same event under a narrower name, so the head's fold carried a compatibility arm for one commit and deleted it when the rename landed |
| `TurnStarted{turn_id,model,ledger_head}` | `event.rs:396` | new turn plist; `*turn-started-ms*` set | `session.lisp:178-194` | DIFFERS — `(getf env :snapshot)` at `session.lisp:183` tests a key an `Envelope` never carries (`event.rs:983-990`), so the guard is always true and the clock is always set. And `ingest-snapshot` never *clears* `*turn-started-ms*`, so a switch or resync leaves the previous session's start time running. The reference stores `started_ms` per `TurnPane` (`app.rs:2251`) and drops the pane on a session change (`app.rs:1914`) |
| `PromptProgress{turn_id,…}` | `event.rs:403` | sets `turn.progress` | `session.lisp:218-224` | DIFFERS — no `turn_id` check. The reference and the view both require the id to match (`app.rs:2265`, `view.rs:404-410`) |
| `TokensGenerated{turn_id,tokens}` | `event.rs:415` | `setf turn.tokens` | `session.lisp:195-202` | DIFFERS — no `turn_id` check and no `max`. `probe:` two frames `50` then `10` leave `tokens = 10`; the reference and the view both use `max` so a reordered or duplicated frame cannot move it backwards (`app.rs:2281`, `view.rs:419`) |
| `Delta{turn_id,target,text}` | `event.rs:419` | three targets, terse filters reasoning | `session.lisp:203-217` | DIFFERS — no `turn_id` check. `probe:` a delta carrying `turn_id "OTHER"` appends to the current turn's text and returns `:dirty`. The reference returns `Filtered` (`app.rs:2295-2297`). Targets and the terse rule are otherwise identical |
| `ToolCallProposed{turn_id,call_id,name,args_digest,target}` | `event.rs:424` | pushes a `CallView`-shaped plist, `target` kept, `note-call-target` | `session.lisp:225-235` | SAME |
| `DecisionRequested{req_id,kind,call_id,summary,target,detail,options,choices,because,advice,deadline,on_timeout}` | `event.rs:442-524` | all twelve kept, plus `asked-ts` from the envelope | `session.lisp:313-329` | SAME, and better than the live reference arm, which hard-codes `asked_ts: 0` (`app.rs:2492`). `endp-open` (`session.lisp:405`) is a no-op with a docstring — harmless, but it does not do what the name says; the reference's `self.open.retain(…)` dedup by `req_id` (`app.rs:2471`) has no counterpart here |
| `DecisionAnswered{req_id,outcome,by,basis,late}` | `event.rs:525` | settles, pushes to `settled-decisions`, attaches to the call | `session.lisp:330-349` | DIFFERS — the settled record drops `call_id` and **`advice`**. `view.rs:494-505` and `app.rs:2503-2514` both read three things off the open decision before removing it *because the answer event carries only the `req_id`*, and advice is the one "which nothing downstream can recover". See gap **W10** |
| `ToolStarted{turn_id,call_id,name,access}` | `event.rs:540` | `ensure-call` | `session.lisp:236-243` | **DIFFERS — broken.** `ensure-call` (`session.lisp:139-146`) is `(or (call-view …) (push …))`: a call that already exists as `proposed` is *returned unchanged*. `probe:` after `tool_call_proposed` then `tool_started`, the state is still `"proposed"`. The card therefore draws `○ … · proposed` for the whole run instead of `◐ … · 1.4s` (`cards.lisp:938-952`). The reference sets `Running`, restarts the clock and clears the note (`app.rs:2356-2400`); the view does the same (`view.rs:523-536`). `access` is dropped on both sides. See gap **W9** |
| `ToolProgress{turn_id,call_id,note}` | `event.rs:553` | `(setf (getf call :progress-note) …)` | `session.lisp:244-247` | **DIFFERS — broken.** `call` is a local variable holding the plist and `:progress-note` is not one of its keys, so `setf getf` conses a new head onto the *local* and the list inside `turn.calls` is untouched. `probe:` the note is `NIL` immediately after. Every tool-progress note leticl has ever folded has gone nowhere. See gap **W11** |
| `ToolFinished{turn_id,call_id,outcome,payload_digest,inline_bytes,full_bytes,spill,repairs,edit}` | `event.rs:561` | sets `Finished` state with outcome/inline/full/spill/edit | `session.lisp:248-261` | DIFFERS — `payload_digest` and `repairs` dropped, and **the progress note is not cleared**. `app.rs:2445` clears it and `app.rs:2365-2386` is a 20-line record of what a stale note cost ("the operator read the screen exactly as it was written and reported the session hung requesting the oracle … the diagnosis cost an hour"). leticl cannot suffer it today only because **W11** means the note never arrives; fix W11 without W12 and the injury lands here |
| `TurnFinished{turn_id,finish_reason,usage,timings}` | `event.rs:590` | state + `note-turn-cost` | `session.lisp:262-274` | DIFFERS — `turn.progress` is **not** cleared. `probe:` after a `prompt_progress` then a `turn_finished`, `:progress` still holds `(:TOTAL 10 :CACHE 2 …)`. The reference clears it in all three terminal arms (`app.rs:2565`, `2596`, `2619`) and so does the view (`view.rs:572`, `588`, `608`), with the reason on the field itself: "a progress frame is true only while it is happening" (`view.rs:254-256`). No `turn_id` check either |
| `TurnInterrupted{turn_id,reason,partial_kept}` | `event.rs:596` | state | `session.lisp:275-281` | DIFFERS — progress not cleared (as above) |
| `TurnFailed{turn_id,error,partial_kept}` | `event.rs:617` | state | `session.lisp:282-288` | DIFFERS — progress not cleared. The empty-`turn_id` rule (`view.rs:595-606`: a turn can fail before it published a `TurnStarted`) is satisfied by accident, since leticl checks no id at all |
| `TranscriptAppended{item_id,kind,ledger_head}` | `event.rs:628` | pushes a row with `:item nil` | `session.lisp:289-295` | DIFFERS — the id is **not** appended to `turn.appended`. `probe:` `:appended` is `NIL` before and after. The turn plist initialises `:appended nil` at `session.lisp:192` and nothing ever writes it, so the field is dead. `view.rs:246-253` says what it is for: *"a head shows a running turn from `text`/`reasoning` and a finished one from the transcript, and it needs to know which rows are the finished form or it renders the answer twice"*. leticl also does the tool-result hand-over by `call_id` at `transcript_content` (`session.lisp:302-306`) rather than positionally at `transcript_appended` (`app.rs:2647-2678`) — a different mechanism with the same intent, and `%round-boundary` (`cards.lisp:221`) is what keeps the reused ids apart |
| `TranscriptContent{item_id,item}` | `event.rs:665` | `fill-item`, then hand-over + round boundary | `session.lisp:296-312` | SAME in effect. Unlike the reference (`app.rs:4744-4751`) it does **not** retire a queued prompt here; see §4f |
| `HeadAttached{head_id,kind,identity}` | `event.rs:669` | adds to `session-heads`, loud-only | `session.lisp:365-373` | SAME — leticl keeps the whole presence row, the reference keeps only a count (`app.rs:2700`) |
| `HeadDetached{…}` | `event.rs:674` | removes, loud-only | `session.lisp:374-378` | SAME |
| `Warning{code,detail}` | `event.rs:680` | pushes to `session-warnings` and files a row | `session.lisp:490-660`, `1061-1111` | **DONE (R10) — it was *"the fold writes into a slot nothing reads"*, and now it is read, drawn and retired.** Every code except the three with a better home is filed as a transcript row where the envelope arrived (`note-warning`, the `note-unreadable` shape), folded to `+note-lines+` plus a `… +N lines · /notes` seam, retired by `/notes`/`/dismiss` and still counted by `/status` as `notes  N of M retired`. The reference's four homes are kept: `turn_failed` → the turn's own footer, FILTERED and filtered from a snapshot too (`app.rs:3320-3330`, `2527-2534`); `job_output_refused` → the jobs pane's error **and** the row; `slash`/`slash_refused` → the listing pane when the reply is over three lines (app.rs:3266-3275), the row otherwise; `secret_late` → the row, the only place left to say a password went unused once the card is gone. A long listing and `turn_failed` do not enter `session-warnings`, which is what `/status` counts — the reference's `self.notes` excludes them for the same reason |
| `ScreenRequested{req_id}` | `event.rs:685` | QUEUED in `%handle-frame`, answered by `%answer-screen-requests` after the paint | `head.lisp:307-322`, `head.lisp:681-704` | SAME — **W6 is closed**: the id is queued and the answer carries the rows just drawn, with the size that paint used (`driver.rs:93-99`, `app.rs:2723-2732`) |
| `SecretRequested{req_id,prompt,command,deadline}` | `event.rs:690` | raises the secret card | `head.lisp:189-192` | SAME |
| `SecretSettled{req_id,given,by}` | `event.rs:699` | — | falls to `(t :quiet)` `session.lisp:400` | **MISSING.** `probe:` disposition `:QUIET`, nothing else. The reference dismisses its own card when somebody else answered first and posts who (`app.rs:2750-2765`). Without it leticl's masked password field stays up over a `sudo` that has already been answered — and the daemon's own `secret_late` warning, which would explain it, reaches the screen as a row since R10 (it is the row this head has instead of a card to dismiss). See gap **W14** |
| `Explain{turn_id,plan}` | `event.rs:705` | `(t :quiet)` | `session.lisp:400` | SAME — the reference is `Disposition::Filtered` and nothing else (`app.rs:2825`) |
| `CommandIssued{head_id,identity,command,client_request_id,note}` | `event.rs:726` | pushes to `session-notices`, always `:dirty` | `session.lisp:385-390` | DIFFERS twice. (i) `session-notices` has no reader — see **W13**. (ii) The reference says it out loud **only when `head_id` is not its own** (`app.rs:2815`), because your own routine acceptances are already covered by `Accepted`; and it is `Filtered` below loud. leticl counts every one as rendered |
| `DenialRaised{request_id,turn_id,call_id,tool,summary,baseline,by,basis,tier,outcome,repeat_count,breaker_open,grant}` | `event.rs:801-832` | pushes ten of thirteen to `session-denials` | `session.lisp:355-364` | **DIFFERS — and this is the one with a requirement behind it.** `breaker_open` and `grant` are dropped, and `session-denials` has no reader. `event.rs:772-791` and the reference's own arm (`app.rs:2841-2909`) turn on exactly the two dropped fields: the breaker line, and *"what the operator can do about it right now"*. `docs/boundary-and-adjudication.md` §4b, quoted at `event.rs:773`: *"a denial the operator cannot see manufactures the workaround"*. leticl renders none of them, at any verbosity. See gap **W12** |
| `Subagent{subagent_id,state,prompt,role}` | `event.rs:840` | pushes the whole envelope | `session.lisp:391-393` | SAME by effect — `probe:` two events for one id leave two entries, but `subagent-rows` (`panes.lisp:595-617`) folds by `subagent_id` at draw time and says so. The reference folds at apply (`app.rs:2145-2168`). Both are `Filtered`-equivalent; leticl returns `:dirty`, so it counts as rendered where the reference counts it filtered |
| `JobSettled{job,state,produced,elapsed_ms}` | `event.rs:884` | folded into the row the daemon gave us, by id | `head.lisp:541-557` | **CLOSED** (`e013465`) — and this row said DIFFERS until 2026-09-22, from the same un-re-measured table as **W2**. The envelope is still pushed to `session-jobs` (`session.lisp:1405`, cleared with the session at `session.lisp:103`), and the pane draws the fold: `head-jobs`' own row takes `state`, `running = false`, `produced` and `elapsed_ms` (`app.rs:2187-2192`). A settlement for a job this head was never told about invents no row — it arrives with the next `ListJobs`. Evidence: `a-settled-job-updates-the-row-the-pane-draws` |
| `JobOutput{job,from,to,produced,dropped,state,lines,next}` | `event.rs:916-938` | the `:job-output` arm folds all eight fields into `*job-out*`, and only when an overlay is open for THAT job | `session.lisp:1419-1446` | **SAME — re-measured 2026-09-22** (**W2**, closed in `b7a2620`). Taken only for the job being looked at: the event is published to the session, so a head that never asked sees it too, and a window for a job nobody is looking at is nothing to keep |

---

## 3. The session view

`ingest-snapshot` (`session.lisp:56-75`) against `Snapshot` (`view.rs:278-297`):

| `Snapshot` field | citation | leticl | verdict |
|---|---|---|---|
| `session_id` | `view.rs:279` | `session.lisp:59` | SAME |
| `seq` | `view.rs:282` | `session.lisp:60-61` — sets both `seq` and `expected-seq` | SAME |
| `dropped` | `view.rs:285` | `session.lisp:62` | DIFFERS — assigned. The reference takes `max` in `load` and `+=` in the two frame arms (`app.rs:1937`, `1672`, `1844`) |
| `items_dropped` | `view.rs:287` | `session.lisp:63` | Stored, never read — no `… +N rows above` disclosure anywhere in `src/` |
| `items` | `view.rs:288` | `session.lisp:69`, `%items-vector` | SAME — rows stay raw plists, every `SnapshotItem` field (`view.rs:60-77`) included |
| `turn` | `view.rs:289` | `session.lisp:64` | SAME — the whole `TurnView` plist is kept raw, so `raw_calls`, `appended`, `tokens`, `progress` and each `CallView.edit` survive a snapshot even where the *live* fold drops them |
| `open_decisions` | `view.rs:291` | `session.lisp:65`, folded at `session.lisp:168` | SAME — kept raw, and **the deadline is converted here** (`%decisions-in-head-time`). Nothing else in the list needs a clock, and this one does: the wire's is Unix millis where this head's counter is process-relative. It was converted on the LIVE path only until `3a9b183`, so a head that attached to a session with an ask already open drew `expires in 29833973 min` for a card with 3m49s left (**R18**) |
| `settled_decisions` | `view.rs:294` | `session.lisp:66` | Stored, never read. The reference partitions them: call-bound ones ride the call's card, the rest become notes (`app.rs:2002-2005`) |
| `warnings` | `view.rs:295` | `session.lisp:67` | **DONE (R10).** Each one is filed as a row where it arrived (`note-warning`), folded to `+note-lines+` + a `/notes` seam, retired by `/notes`/`/dismiss` into a set keyed `(code detail ts)` that a snapshot does not carry, and counted by `/status` as `notes  N of M retired`. The reference's `self.notes` is replaced by a snapshot and re-filtered for `turn_failed` (`app.rs:2527-2534`); this head re-files from `session-warnings` on `ingest-snapshot` and filters `turn_failed` the same way |
| `heads` | `view.rs:296` | `session.lisp:68` | SAME (read at `panes.lisp:255`, `cards.lisp:1197`) |

**10 of 10 ingested. 2 of 10 write-only.**

`ingest-hello` (`session.lisp:87-109`) against `Hello` (`protocol.rs:744-781`):

| field | leticl | verdict |
|---|---|---|
| `protocol_version` | never read | DIFFERS — see §5 |
| `session_id` | via the snapshot only | **BROKEN on the resume path** — see **W25** below. `ingest-hello` calls `ingest-snapshot` unconditionally (`session.lisp:88`), and on a resume served from the scrollback the snapshot is `null` (`protocol.rs:752-753`, `hub.rs:636-643`). `ingest-snapshot` then assigns `session-session-id` ← `""` and immediately `session-seq` ← `NIL` into a `:type fixnum` slot, which raises. The reference assigns the id explicitly on that path instead (`app.rs:1680-1685`) |
| `head_id` | `session.lisp:90` | Stored. Nothing uses it. The reference uses it twice: it re-seats the client so later acks are attributed (`driver.rs:71-73`, `client.rs:530`) and it suppresses its own `CommandIssued` (`app.rs:2815`) |
| `dropped` | `session.lisp:91` | DIFFERS — assigned, overwriting the snapshot's; the reference accumulates |
| `snapshot` | `session.lisp:88` | SAME |
| `resumed_from` | `session.lisp:104-108` | SAME |
| `scrubbed` | `session.lisp:89`, `%scrub-total` | SAME — `ScrubReport` is five `u64` counts and nothing else (`scrub.rs:134-150`), so summing every integer in the plist equals `total()` (`scrub.rs:153-159`) |
| `wiring` | `session.lisp:93` | SAME — all four of `SessionWiring` (`registry.rs:255-260`) kept raw |
| `sessions` | `session.lisp:92`, title lookup at 100-103 | DIFFERS — kept unfiltered. The reference drops rows with a `parent_session_id` before storing, twice (`app.rs:1668-1671`, `1732-1735`), because subagents are not sessions a picker lists. **`context_tokens`/`context_cached` are READ now** (`src/chrome.lisp:216-253`, R8): the header's `ctx` comes from the session's own row when the head has no turn of its own — a restart, a reattach, a resume. That closes the second half of this row; the missing `parent_session_id` filter is still open |

**What `ingest-snapshot` does not do that `load` does:** clear the session-scoped
state that is not in the snapshot. `app.rs:1902-1934` clears call tables, usage,
the spend meter, the model, the turn, the head count, the subagent tree, the
jobs table and the queued prompts whenever the id changes, each with a measured
reason attached. `ingest-snapshot` clears none of `session-denials`,
`session-notices`, `session-subagents`, `session-jobs`, and nothing clears
`head-jobs`, `head-queued`, `head-peeked`, `head-settings` or
`*turn-started-ms*`. A `/switch` therefore carries the old session's subagent
tree, job rows and queue onto the new one's screen — `app.rs:1916-1919` records
that exact symptom: *"1 subagent running" on the composer of the very subagent
being looked at*. (`reset-spent` is called from the `hello` arm at
`head.lisp:166`, so the money meter is the one thing that is cleared.)

---

## 4. Correctness of the exchange

### 4a. Acks

`run-loop` (`head.lisp:332-385`) is `driver.rs:35-108` arm for arm: drain and
classify, then draw, then ack. `last-seq` is taken from the frame that was
**read** (`head.lisp:356-358`) and not from what was drawn, and the ack goes out
only when it is positive (`head.lisp:384`), which is `driver.rs:102`. **SAME**,
including the rule that makes it matter — a head at terse still advances.

Two differences, neither in the ordering: the ack carries no head identity and
leticl never learns one (see `head_id`, §3); and `ack-frame` is a second,
wrong-by-construction spelling of the same frame (§1a).

### 4b. Resync

`/resync` sends `ClientFrame::Resync` (`commands.lisp:133`); a `resync` frame is
ingested through the same `ingest-snapshot` the attach uses
(`head.lisp:204-212`), which is the reference's *"they are the same path, which
is why resync is not special"* (`app.rs:1894-1896`). The counter `*resyncs*` is
bumped, matching `app.rs:1843`. **SAME**, except that `dropped` and `scrubbed`
on the frame are discarded (**W8**).

### 4c. Reconnect and backoff

The reference TUI **does not reconnect**: `pump` returns on any read error
(`client.rs:544-555`), the next `client.ack` fails, and `tick` returns `Err`,
which ends `main`. leticl reconnects — `%try-reconnect` (`head.lisp:283-316`),
gated at one attempt per 2 s of `get-universal-time`, re-attaching with
`since_seq = session-seq` so the gap arrives as events or as a `Resync`, and
restarting the reader thread. This is **leticl ahead of the reference**, and the
two comments at `head.lisp:294-298` and `head.lisp:308-311` record the two ways
it was got wrong. The flat 2 s is not a backoff; against a daemon that is gone
it is a 30-attempt-per-minute spin with a status line that keeps changing. That
is a small cost, and it is the mechanism that makes **W5** (a `Bye` becoming a
loop) worse than it would otherwise be.

**And the reconnect does not work.** `%try-reconnect` attaches with
`since_seq = (session-seq …)`, which is nonzero, so the daemon serves the gap
from the ring and answers `Hello { snapshot: null, resumed_from: N }`
(`hub.rs:628-652`, `server.rs:929-942`) — and that Hello raises a `TYPE-ERROR`
inside `ingest-hello` before it reaches any of its own assignments. Measured
(`scratchpad/probe2.lisp`, two hellos differing only in `snapshot`):

```
RESUME-ERROR: TYPE-ERROR              ; "snapshot":null
SNAPSHOT-OK id="s-1" seq=7 dropped=2  ; a snapshot present
```

`ingest-snapshot` is called unconditionally (`session.lisp:88`) and its first
`setf` pair assigns `session-session-id` ← `""`, then the second assigns
`(getf nil :seq)` = `NIL` into a `:type fixnum` slot and signals.
`run-loop`'s `handler-case` (`head.lisp:359-366`) swallows it into
`*last-render-error*`, so the head neither crashes nor recovers: the session id
has already been wiped, and `head-id`, `dropped`, `sessions`, `wiring`, the
title and `resumed_from` are never read, the `hello` arm's
`(%send head (make-settings))` never runs, and `*attach-started-ms*` is never
cleared — so the attach indicator walks forever over a head that is folding the
backlog into a session whose id it has just forgotten. This is **W25**, and it
is the highest-value single fix in this document: it is the whole of §4c.

### 4d. `expected_seq`

Every mutating frame leticl builds carries `(session-expected-seq
(head-session head))`, which `apply-event` sets to the last folded seq
(`session.lisp:175-176`) and `ingest-snapshot` sets to the snapshot's seq
(`session.lisp:61`). The reference carries `app.seq`, set at
`app.rs:1851` from the same place. **SAME.** A `Rejected` with
`REJECT_STALE_SEQ` is surfaced with both numbers (`head.lisp:223-229` vs
`app.rs:1881-1883`) — SAME; neither side branches on the code, and
`protocol.lisp:25-29` has the constants ready for the day one does.

### 4e. Interrupt and stop

`Interrupt` — SAME (`commands.lisp:203`, ctrl-c on a running turn at
`editor.lisp:431`). `Stop` — the frame and the order are SAME (ask, then leave:
`editor.lisp:178-180`, `driver.rs:205-211`), with the `who` literal noted in
§1a. leticl does **not** send `Detach` on the stop path before quitting; it
sends it from the `unwind-protect` in `run` (`head.lisp:455`), which runs either
way, so the effect matches.

### 4f. Queued prompts and withdraw

| | reference | leticl |
|---|---|---|
| queue is pushed | `app.rs:4435` on send | `commands.lisp:47`, newest first |
| an entry is retired | on `TranscriptContent` / `record_item`, **by matching the row's text**, one row per entry, with a prefix rule for the daemon's coalescing (`app.rs:4685-4703`, `4744-4751`) | **by matching the row's text, and the same rule on both paths** — `%resolve-queued` is the one place it lives, `%retire-pending` is the live `transcript_content` caller (`head.lisp:560-568`) and `%re-resolve-queued` the snapshot one (`head.lisp:441`, `607`); the prefix rule comes off as the front piece of a coalesced echo (`head.lisp:214-247`) |
| ctrl-u / Up recall | joins **all** pending, clears **all**, puts them in the composer, then sends `WithdrawPrompts` (`app.rs:3851-3860`) | takes `(first (last …))` — the oldest — into the composer, `butlast`s that one, sends `WithdrawPrompts` (`editor.lisp:436-445`) |

The frame is identical and the daemon drops **every** unconsumed prompt from
this head (`protocol.rs:348-357`). leticl removes one from its own list, so
after a withdraw with two queued the head goes on announcing a prompt the daemon
has already dropped — the withdraw half of **W16**, still open. **The retire half
is closed**: the row's TEXT decides, on the live path and on a snapshot alike
(`%resolve-queued`), so two queued prompts of different lengths retire in the
order their rows land.

### 4g. The decision answer path

Permission: `make-answer` with `option_id`, plus `pattern` for `AllowAlways` and
`note` for `deny_and_tell`, each omitted otherwise (`protocol.lisp:195-212`,
`editor.lisp:44-59`, `106`) — **SAME** as `driver.rs:127-134` /
`protocol.rs:505-549`. Question: `make-answer-question`, which builds
`{option: N}`, `{note: …}`, `{free: …}` or a combination, and **refuses an empty
answer** — see §4.5 below. `can_decide: true` is advertised and honoured, so the
`REJECT_READ_ONLY` path is not reachable; neither side advertises
`FEATURE_QUESTION_ANSWERS` (`protocol.rs:259`), and the reference's
`Caps::default()` (`protocol.rs:277-285`) is `queue 1024, can_decide true,
features []`, which is byte-for-byte what leticl sends. **SAME.**

### 4.5. A key whose value is NIL is omitted, and that is the only spelling the daemon always accepts

**Three field shapes on the Rust side, and they do not agree about a present
`null`:**

| shape | missing key | present `null` |
|---|---|---|
| `Option<T>` | `None` | `None` |
| `T` with `#[serde(default)]` | the default | **ERROR** |
| a bare `T` | **ERROR** | **ERROR** |

So absence is never worse than null and is strictly better for the middle case —
and the middle case is the one that has cost this head two sockets:

- `Mode.consented` (`protocol.rs:452`) — every mode but `allow-all` broke the
  daemon's read loop and dropped the connection until the call site wrote `:false`;
- `ReseatSession.summarise` (`protocol.rs:519`) — the same, fixed the same way;
- **`AnswerQuestion.answer`** (`protocol.rs:644-648`) — latent, and the reason
  this is written down: `QuestionAnswer` is a bare required struct, so
  `"answer": null` fails the WHOLE `ClientFrame` deserialiser. Unreachable only
  because the sole caller passes `(list :option idx)`.

**A hazard fixed three times by hand is a pattern, not an accident.** Both halves
of the general answer are now in the tree:

1. **`%encode-object` elides a NIL-valued key** (`json.lisp`), which closes the
   `Option<T>` and `#[serde(default)]` shapes for every future site, in the one
   place that writes bytes. The two hand-fixed sites keep their explicit `:false`
   — that is a VALUE and reads better on the wire than absence — and are asserted
   to still say `false` rather than nothing.
2. **`make-answer-question` refuses an empty answer**, which no encoder rule can
   reach: for a bare required field, missing and null are both fatal, so the frame
   must not be built. Verified by encoding what the refusal prevents — the elision
   leaves no `answer` KEY at all, and serde rejects that just as hard.

**The root cause is that NIL is overloaded in Lisp** — it is both `false` and
`nothing` — and an encoder cannot tell which one it is looking at, so the
ambiguity is resolved where the knowledge is: `:false` is how a caller says *this
nil is a false*, and every other nil means there is nothing to say.

**An array element is not a key** and keeps its null: `[null]` is a value in a
position, and a list element has no absence to fall back to.

The disclosure rule in `protocol.lisp`'s header — *fields whose presence is the
disclosure are always written, present and zero/null rather than omitted* — is the
DAEMON's rule about the frames it SENDS (`dropped`, `created`, `snapshot`), and
this encoder writes only the client's. Nothing this head sends is a disclosure of
that kind, which is why an earlier test of the opposite rule was asserting a
property of the other side of the wire.

**Asserted as an invariant** rather than site by site:
`no-client-frame-this-head-can-build-carries-a-null` walks every constructor in
`protocol.lisp`, encodes it at the arguments its call sites use, and asserts there
is no `null` and that the frame still decodes.

### 4h. Secrets

`SecretRequested` → masked field → a `Secret` frame with the password, or with **no
`secret` key** when it is refused (§4.5's elision; `secret` is `Option<String>`, so
absence reads as a refusal exactly as `null` did): SAME
(`head.lisp:323-344`, `editor.lisp:383-415` vs `app.rs:2734-2748`,
`driver.rs:195`). `SecretSettled` is handled — the card comes down when somebody
else answers it. `ServerFrame::Secret` is ignored on both sides. `Askpass` belongs
to the helper, not here.

### 4i. `Peeked`, `Settings`, `Slash`, jobs and subagents

- **`Peeked`** — SAME: `Peek` is sent from `/peek` and from the subagent tree's
  Enter (`commands.lisp:126`, `editor.lisp:289`), the reply opens the pane with
  all three fields kept (`head.lisp:254-261`), and the connection does not move.
- **`Settings`** — SAME: asked from the `hello` arm so attach, switch and
  reconnect are covered by one send (`head.lisp:178`), the reply stores rows and
  stamps the seq and does **not** open the pane (`head.lisp:243-253`), which is
  `app.rs:1786-1792` and `app.rs:1661`. `SettingRow.choices`
  (`protocol.rs:242-243`) is read at `panes.lisp:510-515` — the drift this field
  exists to stop is not present here.
- **`Slash`** — SAME on the way out (`commands.lisp:210`, `234`). **SAME on the way
  back since R10**: the reply is a `Warning` on the log, a listing over three body
  lines opens the slash pane (`app.rs:3266-3275`) and anything shorter is filed as a
  row, so `/tools`, `/models`, `/supervise` and `/job` are no longer sent into
  silence. The `ReadJobOutput`/`JobOutput` half is **closed too** (`b7a2620`); what
  this bullet got wrong until 2026-09-22 was reading **W2** as open.
- **Jobs** — SAME throughout: `ListJobs`/`Jobs` fills `head-jobs`, `JobSettled` folds
  into that row by id (`e013465`), and `ReadJobOutput`/`JobOutput` read a window into
  the overlay that asked (`b7a2620`).
- **Subagents** — SAME by effect (fold at draw rather than at apply), with the
  switch-carryover noted in §3.

---

## 5. Protocol version

- The reference speaks `PROTOCOL_VERSION = 21` (`protocol.rs:210`).
- leticl sends `21` (`protocol.lisp:14`; measured on the encoded attach).
- **Daemon side of a mismatch:** `server.rs:332-342` compares the two, writes
  `Bye{reason: "protocol version N, this daemon speaks M"}` and returns — the
  connection closes without a `Hello`. Deliberate: *"a silent version skew looks
  like a bug in the other half, forever"*.
- **Reference head side:** a `Bye` instead of a `Hello` is `ClientError::Refused`
  and the process exits with the daemon's sentence on a restored terminal
  (`client.rs:101`, `letibot-tui.rs:658-661`, and the launcher refuses to route
  around it).
- **leticl side:** nothing checks `Hello.protocol_version`, and the `bye` arm
  only writes a status note and drops `connected` (`head.lisp:262-266`).
  `%try-reconnect` then re-attaches with the same version every two seconds,
  forever. The operator sees `bye: protocol version 21, this daemon speaks 22`
  flashing under a head that never attaches and never exits. The stale header
  in `protocol.lisp:1` and `leticl.asd:7` still says *protocol 18*, which is a
  comment, not a fact — the constant is right.

---

## Gaps worth closing

Sized S (a function), M (a function plus a place to put the result), L (a new
frame, a new pane, or a fold that changes shape).

| id | gap | why it matters | reference | leticl | size |
|---|---|---|---|---|---|
| **W25** | a `Hello` with `snapshot: null` raises `TYPE-ERROR` | this is the **reconnect** answer and the resume answer — every `since_seq > 0` attach whose gap is in the daemon's ring (`hub.rs:636-643`). The head is left half-attached with its session id wiped, no settings asked, and the attach indicator walking forever. Measured: `probe2:` `RESUME-ERROR: TYPE-ERROR` against `SNAPSHOT-OK` for the same Hello with a snapshot | `protocol.rs:752-753`, `app.rs:1680-1685`, `hub.rs:628-652` | `session.lisp:56-75`, `session.lisp:88` | **S** |
| **W1** | `Mode` sends `"consented":null` | `consented: bool` does not accept a present `null`; the daemon's read loop breaks with `Err` and **the connection closes** (`server.rs:897-898`). Every `/mode NAME` that is not `allow-all` — which is every mode an operator normally picks — takes the head down. Measured: `probe:` `{"frame":"mode",…,"consented":null}` | `protocol.rs:438-453` | `panes.lisp:1218-1223`, `json.lisp:84-86` | **S** |
| ~~**W2**~~ | no `ReadJobOutput`, no `job_output` fold, no window | **CLOSED in `b7a2620`, 2026-09-21 00:00 — and this row said OPEN until 2026-09-22, because it was measured at `7c2c6fc` and never re-measured.** All three halves exist: `make-read-job-output` (`protocol.lisp:293`), the `:job-output` fold into `*job-out*` and nowhere else (`session.lisp:1419-1446`), and the window (`panes.lisp:1423-1544`). Measured live: Enter on a finished job drew `job output — j74` / `exited 0 — bytes 0..899 of 899` over the bytes; a running job with nothing written says so in words (`panes.md` G4) | `protocol.rs:704-708`, `event.rs:894-938`, `app.rs:2200-2233`, `driver.rs:167-169` | `tests: enter-on-a-jobs-row-reads-its-output-into-a-pane`, `the-job-output-window-fills-the-overlay-and-it-pages`, `the-job-output-overlay-scrolls-and-discloses-what-fell-off`, `a-refused-job-output-read-lands-in-the-pane`, `the-hint-bar-names-the-job-output-overlays-keys` | **done** |
| **W3** | `NewSession.workspace` always `""` | the new session's read-only tools get seated at the daemon's cwd, *"and every path in it resolved, so the only symptom was answers about the wrong tree"* | `protocol.rs:599-607`, `driver.rs:147-150` | `protocol.lisp:160-164` | **S** |
| **W4** | `Sessions.created` and `.current` dropped | `/new` and `--new TITLE` create a session and leave you in the old one — a command whose effect is invisible | `app.rs:1736-1744` | `head.lisp:230-234` | **S** |
| **W5** | `Bye` is not terminal | a refusal the daemon meant as final becomes a 2 s reconnect loop; a version skew is then unreadable and unescapable | `app.rs:1886-1889`, `client.rs:548` | `head.lisp:262-266`, `head.lisp:283-316` | **S** |
| ~~**W6**~~ | `Screen` answered with the previous frame | **CLOSED**, and §4.4 with it. The id is queued in the frame fold and answered after the paint, from `head-last-rows` **plus** `head-last-cols`/`head-last-rows-n` — one paint, one frame, and the size is a required argument of `make-screen-answer` because deriving it from a row's length reported bytes instead of columns | `driver.rs:93-99`, `app.rs:2723-2732` | `head.lisp:681-704` | **done** |
| **W7** | `AnswerQuestion` can only carry `option` | `note` and `free` are two thirds of the vocabulary and `free` is the half the requirement names: *"opencode style free user reply input"*. Without it a typed answer to a question is unreachable | `question.rs:55-65`, `question.rs:10-20` | `editor.lisp:68-69` | **M** |
| **W8** | `Resync.dropped` / `.scrubbed` discarded | `/status`'s `dropped` and `scrubbed` under-report after any resync, which is exactly when they are worth reading | `app.rs:1843-1845` | `head.lisp:204-212` | **S** |
| **W9** | `ToolStarted` leaves a proposed call `proposed` | the running card never appears: `○ bash ls · proposed` for the whole call instead of `◐ bash ls · 3.2s`. Measured: `probe:` `CALL-STATE-AFTER-STARTED = "proposed"` | `app.rs:2356-2400`, `view.rs:523-536` | `session.lisp:139-146`, `236-243` | **S** |
| **W10** | `DecisionAnswered` drops `advice` and `call_id` | the oracle's verdict is on the *request* and never on the answer; both the view and the head read it off the open decision before removing it because *"nothing downstream can recover"* it | `view.rs:494-516`, `app.rs:2503-2524` | `session.lisp:330-349` | **S** |
| **W11** | `ToolProgress` note goes nowhere | `setf getf` on a local plist with an absent key mutates the local, not the list in the turn. Measured: `probe:` `PROGRESS-NOTE-AFTER-FINISH = NIL`. The card has a slot for it (`cards.lisp:942`) that is always nil | `app.rs:2409-2421` | `session.lisp:244-247` | **S** |
| **W12** | a denial reaches no screen; `breaker_open` and `grant` are not even folded | `docs/boundary-and-adjudication.md` §4b is a requirement: *"a denial the operator cannot see manufactures the workaround"*. The two dropped fields are the two the reference's arm turns on — the breaker sentence and *"what the operator can do about it right now"* | `event.rs:772-832`, `app.rs:2841-2909` | `session.lisp:355-364`, and no reader | **M** (fold) / **L** (with the render) |
| **W13** | `notices`, `settled-decisions`, `items-dropped`, `jobs` are write-only (**`warnings` left this list with R10**) | every post-flight assertion, every `secret_late`, every `job_output_refused` and every settled question with no call is folded and then never drawn. `warnings` was the loudest of them and is now the counter-example: a row where it arrived, a `/notes` verb to retire one, and `notes  N of M retired` on `/status` | `app.rs:2766-2803`, `app.rs:2002-2016` | `session.lisp:33-35`, `385-390`; no reader in `render.lisp`/`cards.lisp`/`chrome.lisp`/`panes.lisp` for the four that remain | **L** |
| **W14** | `SecretSettled` unhandled | the password card stays up after another head has answered, over a `sudo` that is already through. Measured: `probe:` `:QUIET` | `app.rs:2750-2765` | `session.lisp:400` | **S** |
| **W15** | ~~`JobSettled` folded into a list nobody draws~~ | **CLOSED (`e013465`)** — the pane showed `running` for a job that exited, which is *"a panel built from the tool events alone would still show a build as running an hour after it exited"*. The fold is on the row the daemon gave, by id, and invents no row (`head.lisp:541-557`) | `app.rs:2176-2195` | `tests: a-settled-job-updates-the-row-the-pane-draws` | **done** |
| **W16** | ~~withdraw removes one entry~~; ~~retire pops the wrong end~~ | **the retire half is CLOSED (R2, then R16)**: `%retire-pending` matches the row's TEXT, one row per entry, with the coalesced front-piece rule, and both the live and the snapshot path go through `%resolve-queued` (`head.lisp:214-247`, `560-568`) — *evidence `a-landed-row-retires-the-prompt-it-echoes`, `a-snapshot-retires-the-echoes-whose-rows-it-carries`*. **The withdraw half stands**: `WithdrawPrompts` drops every unconsumed prompt at the daemon and leticl takes one out of its own row (`editor.lisp:436-445`) | `app.rs:3851-3860`, `4685-4703`, `4744-4751` | `editor.lisp:436-445` | **M** |
| **W17** | no `turn_id` on `Delta`, `PromptProgress`, `TokensGenerated`, `TurnFinished`, `TurnInterrupted` | a frame from a turn this head is no longer watching is folded into the one it is. Measured: `probe:` a delta for turn `OTHER` appends to the current turn's text and reports `:dirty`. Benign today, load-bearing the moment §8.4's concurrent subagents publish on one hub | `app.rs:2278-2297`, `view.rs:406-419` | `session.lisp:203-224`, `262-288` | **S** |
| **W18** | `turn.progress` survives the turn | *"a progress frame is true only while it is happening"*. Measured: `probe:` `PROGRESS-AFTER-TURN-FINISH = (:TOTAL 10 …)` | `app.rs:2565`,`2596`,`2619`; `view.rs:572`,`588`,`608` | `session.lisp:262-288` | **S** |
| **W19** | `TokensGenerated` is `setf`, not `max` | a reordered or duplicated frame walks the counter backwards. Measured: `probe:` `50` then `10` ⇒ `10` | `app.rs:2281`, `view.rs:419` | `session.lisp:195-202` | **S** |
| **W20** | `turn.appended` never written | the head cannot tell which transcript rows are the finished form of the turn it is drawing live — `view.rs:246-253`'s "renders the answer twice" | `app.rs:2650-2651`, `view.rs:632-634` | `session.lisp:289-295` | **M** |
| **W21** | `ingest-snapshot` clears nothing that is not in the snapshot | a `/switch` carries the old session's subagent tree, job rows, denials, notices and queue onto the new one — *"1 subagent running" on the composer of the very subagent being looked at* | `app.rs:1902-1934` | `session.lisp:56-75` | **M** |
| **W22** | `Hello.sessions` unfiltered; `head_id` unused; `dropped` assigned not accumulated | the picker lists subagents as sessions; `dropped` resets on every reattach; `CommandIssued` cannot suppress this head's own | `app.rs:1662-1673`, `2815`, `driver.rs:71-73` | `session.lisp:87-109` | **S** each |
| **W23** | `ack-frame` is a dead second spelling, and it reads the wrong seq | `protocol.rs:717-720`: *"there is deliberately no other way to obtain one"*. Two ways exist here and the unused one is the bug the rule names | `protocol.rs:714-730` | `session.lisp:411-414` | **S** (delete it) |
| **W24** | no `protocol_version` check on `Hello`; stale "protocol 18" headers | a skew is only ever reported by the daemon's `Bye`, which W5 turns into a loop | `server.rs:332-342`, `letibot-tui.rs:658-661` | `head.lisp:162`, `protocol.lisp:1`, `leticl.asd:7` | **S** |

---

## How each gap should be tested

The repo already has the two shapes this needs.

**A fake daemon** — `tests/tests.lisp:1772-1781` is the pattern: build a head,
`(setf (leticl::head-stream h) (make-string-output-stream) (head-connected h) t)`,
drive the head, then decode every line written and assert on the *frames*. Use
it wherever the assertion is "what went out on the wire".

**A pure fold** — build a `session` with `make-session`, push envelopes through
`apply-event`, assert on the plists. No head, no stream. Use it wherever the
assertion is "what state the fold left".

| gap | assertion that proves it closed | kind |
|---|---|---|
| **W25** | `(ingest-hello (make-session) H)` for a `H` decoded from a real `{"snapshot":null,"resumed_from":42,…}` line returns without signalling, and leaves `session-session-id` = `"s-1"`, `session-seq` = `42`, `session-expected-seq` = `42`, `session-head-id` = `"h1"` and `session-wiring` non-nil. Then, at the head level: after a `hello` with a null snapshot, `(head-connected h)` is `t`, `*attach-started-ms*` is nil, and a `settings` frame is on the wire | pure fold, then fake daemon |
| **W1** | `(search "\"consented\"" (encode-frame …))` is nil for a non-consented mode, **or** the value is `false`. Strongest form: assert the encoder never emits a bare `null` for a field the reference types `bool` — a table of `(frame-builder . boolean-key)` and a check that each either omits the key or writes `true`/`false` | fake daemon (encode only) |
| **W2** | driving Enter on a jobs row writes a `{"frame":"read_job_output","job":"j1","offset":0}` and **not** a `slash`; then folding a `job_output` envelope for `j1` leaves the window's `lines`, `from`, `to`, `next` where the pane reads them | fake daemon + fold |
| **W3** | the `new_session` frame's `workspace` is non-empty and equals the head's cwd | fake daemon |
| **W4** | after a `sessions` frame with `created: "s-2"` following a `/new`, a `{"frame":"switch","session_id":"s-2"}` is on the wire; after a plain `/sessions` list, nothing is | fake daemon |
| **W5** | after a `bye` frame, `(head-running h)` is nil and no further `attach` is written even after `(setf (head-last-reconnect h) 0)` and another loop pass | fake daemon |
| ~~**W6**~~ | done: `the-screen-answer-is-the-frame-that-was-just-drawn` (rows are the painted ones) and `the-screen-answer-reports-columns-and-not-characters` (the size is the frame's column count, while the row's own character length is larger because the escapes are in it) | fake daemon (the `*stdout*` string-stream paint harness) |
| **W7** | done: `a-question-answer-can-carry-a-typed-reply`; and `an-empty-answer-is-not-a-frame` asserts the third clause — an empty answer is REFUSED at the constructor, because `QuestionAnswer` is a required struct and `"answer": null` (or a missing `answer`) fails the daemon's whole `ClientFrame` deserialiser | pure |
| **W8** | `*scrubbed-total*` and `session-dropped` both increase after a `resync` frame carrying `dropped: 3` and a `ScrubReport` summing 4 | fake daemon (the `resync` arm is in `%handle-frame`) |
| **W9** | `proposed` → `tool_started` ⇒ `(getf (getf (call-view turn "c1") :state) :state)` is `"running"`, and the second call to `ToolStarted` for an unseen id still creates a row | pure fold |
| **W10** | a `decision_requested` carrying `advice` and `call_id`, answered, leaves a settled record whose `:advice` and `:call-id` are both non-nil | pure fold |
| **W11** | after `tool_progress`, `(getf (call-view turn "c1") :progress-note)` is the note — read back off the **turn**, never off the return value of the setter | pure fold |
| **W12** | the folded denial has `:breaker-open` and `:grant`; and (with W13) a denial produces a line in the body at every verbosity including `:terse` | pure fold, then a render assertion |
| ~~**W13**~~ | `warnings` was write-only | **CLOSED (R10)** — and it is the counter-example the rest of this section should be read against. A `warning` envelope now produces a row in the body where it arrived, a long `slash`/`slash_refused` reply opens the pane while a short one becomes a row, a `job_output_refused` reaches the jobs pane **and** the row, `turn_failed` is `Filtered` into the turn's own footer, and `secret_late` is a row. The retired set is keyed `(code detail ts)` outside the transcript, so a resync and a reattach replant the wall retired, and `/status` reads `notes  N of M retired`. `notices`, `settled-decisions`, `items-dropped` and `jobs` are still write-only and are the rest of **W13** | `app.rs:3320-3358`, `app.rs:5767-5882` | `tests: a-warning-the-daemon-sends-is-drawn-where-it-arrived`, `a-long-warning-folds-to-three-lines-and-names-the-verb`, `a-retired-warning-leaves-the-screen-and-stays-counted`, `a-retired-warning-stays-retired-across-a-resync-and-a-reattach`, `the-turn-failed-warning-is-not-a-second-copy-of-the-footer`, `the-notes-verb-lists-retires-and-restores` | **done** |
| **W14** | with a secret card up, a `secret_settled` for the same `req_id` clears `head-secret-req`; for a different one it does not | pure fold at the head level (`%handle-frame`), no stream needed |
| **W15** | `/jobs` reply with one running row, then a `job_settled` for its id ⇒ that row in `head-jobs` has `running` false and the new `state`/`produced`/`elapsed_ms`; a settlement for an unknown id invents no row | fake daemon (for the `jobs` frame) + fold |
| **W16** | two queued prompts, then ctrl-u ⇒ the composer holds both joined, `head-queued` is empty, one `withdraw_prompts` on the wire. Separately: two queued prompts of different text, then a `transcript_content` carrying the **first** ⇒ the first is retired, not the last | fake daemon + fold |
| **W17** | a `delta` with a foreign `turn_id` returns `:quiet` and leaves `(getf turn :text)` unchanged; same for `prompt_progress`, `tokens_generated`, `turn_finished` | pure fold |
| **W18** | `prompt_progress` then `turn_finished` ⇒ `(getf turn :progress)` is nil; repeat for `turn_interrupted` and `turn_failed` | pure fold |
| **W19** | `tokens_generated 50` then `10` ⇒ `(getf turn :tokens)` is `50` | pure fold |
| **W20** | `turn_started`, two `transcript_appended` ⇒ `(getf turn :appended)` is those two ids in order | pure fold |
| **W21** | fold a session full of subagents, jobs, denials and notices, then `ingest-snapshot` with a **different** `session_id` ⇒ all four are empty, and `*turn-started-ms*` is nil; with the **same** id, the queue survives (the reference keeps it, `app.rs:1938-1942`) | pure fold |
| **W22** | a `hello` whose `sessions` include a row with `parent_session_id` leaves that row out of `session-sessions`; two `hello`s carrying `dropped: 2` leave `session-dropped` at 4; `session-head-id` is non-empty and a `command_issued` from that head id is not said | fake daemon + fold |
| **W23** | none — delete `ack-frame` and its export. The guard is the existing ack test: the seq acked is the last seq **read**, asserted by feeding an event the head filters and checking the ack still names it | fake daemon (exists in spirit; worth pinning) |
| **W24** | a `hello` whose `protocol_version` is not `+protocol-version+` says which WAY the skew runs and keeps the head attached; and a grep test that `protocol.lisp`'s header comment and `leticl.asd`'s `:long-description` name the same number as `+protocol-version+` — the same shape as `live-state-tables-are-defvar` (`tests.lisp`, per `HACKING.md`), which greps the sources so a rule in a document cannot rot. Done as `a-protocol-skew-says-its-direction-and-the-head-stays` (R5) | fake daemon + a source grep |
| **W-null** | **the invariant, not the instance**: every `make-*` in `protocol.lisp` encodes a frame with no `null` anywhere AND still decodes; plus the two hand-fixed sites still say `consented:false` rather than nothing | pure (`no-client-frame-this-head-can-build-carries-a-null`) |

**Order.** Two of these break the head outright and are each a few lines:
**W25** (no reconnect or resume works at all) and **W1** (`/mode NAME` closes
the connection). Then the three one-line folds with one-line assertions:
**W9**, **W11**, **W19**. Then **W18**, **W14**, **W15**, **W8** and **W3**,
which are the same shape. **W13** has been started from its loudest end —
`warnings`, done by R10 — and the four slots that remain (`notices`,
`settled-decisions`, `items-dropped`, `jobs`) are still the reason W2 and W12
look like separate silences rather than one.
