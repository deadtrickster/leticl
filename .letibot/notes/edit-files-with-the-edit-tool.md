# A detected change draws its diff — and a live head draws the code it was PUSHED

Written when I misread the operator's report *"edits via python not showin as diffs again"* as
advice about my own tooling. It was not: they were naming a defect in the head, and the
correction that followed was *"it is already detected as edit, but stopped drawing diffs some
time ago"*. What is actually true, measured:

**The diff for a change no tool announced is the HEAD's rendering of the daemon's excerpt.**
`bash.rs` builds a `FileEdit` when a command changed exactly one file and attaches the note
*"this command changed `<path>` — the diff beside it was detected afterwards, not made by
`edit`"*. The head used to choose what to draw from the TOOL'S NAME —
`(member (%verb-kind …) '(:edit :write))` — so `bash` got the note and no diff; the fix is
**`773a356` (2026-10-02)**, and the rule is: *the excerpt's presence is the signal*, because a
write through `edit` and a write by a python heredoc are the same fact (R35).

**So when a diff stops appearing, the head is stale, not the code.** A live image holds the
definitions the last push gave it. `scripts/tui-eval --tree` makes it match disk; a
`defparameter` travels, a `defclass`/`defstruct` does not (those want a restart). Check
`tui-eval --where <symbol>` — a definition with a source path is image-baked, a null one was
pushed — before believing anything about a running head's behaviour.

**The heredoc trap is still real and separate.** In a python heredoc `\"` inside a `'''…'''`
string lands as a bare `"`, which closes a Lisp docstring early: that broke
`no-docstring-is-cut-short-by-an-unescaped-quote` eight times in one session, each as a fatal
read error after the file was already written. Prefer `edit` for that reason, and for a diff
the operator can read in the tool result.
