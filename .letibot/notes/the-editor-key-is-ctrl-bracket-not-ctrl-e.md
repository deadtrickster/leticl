<!-- abstract: The ledger says `ctrl-e` opens the editor. It does not: ctrl-e is this head's composer end-of-line (emacs), the reference's key is `ctrl-]`, and a Lisp head cannot embed rano — it can run it. Everything measured, nothing landed. -->

# Opening the editor: the ledger's key is wrong, and the shape it implies is not this head's

Measured 2026-10-11 against `TODO.md`'s `!term` box (which says *"`ctrl-e` (an `EditorPane` holding a
rano instance behind the composer, toggled, reached by rano's `open-file` key)"*) and against letibot.

## 1. The key is `ctrl-]`, and `ctrl-e` is TAKEN here

`letibot/letibot/crates/tui/src/app/editor.rs`, this head's own header for the feature:

> *"A click on an edit or write row of the conversation, or **`ctrl-]`** for the newest one, opens rano
> on that file — on the change, with the change drawn over the text as rano's own review view."*

And in leticl `ctrl-e` is **the composer's end of line** — the emacs set
(`src/editor/dispatch.lisp:501`, `src/panes/help.lisp:26`: *"ctrl-a ctrl-e — start and end of the line"*).
So the ledger's row, taken literally, would have had a session **take a key that is already doing
something** and call it a port.

**`ctrl-]` is free** in this head: nothing binds it.

## 2. How `ctrl-]` even arrives

The decoder spells a control byte as `(:ctrl CH)` with `CH` at `(+ 96 code)`
(`keys.lisp:262`), so 0x1d is `#\}` (125) — exactly the trap `%ctrl-backslash-p` documents one byte
over (`0x1c` arrives as `#\|`, 124). A binding is therefore

    (and (eq (getf key :type) :ctrl) (eql (getf key :ch) #\}))

## 3. The file is IN the row, and this was measured on the live head

A `tool_result` row's body carries **`:edit`** (asked the running head for a real row's keys:
`:TYPE :CALL-ID :NAME :OUTCOME :PAYLOAD :EDIT :ORIGIN :MEDIA`), and `edit-card.lisp` reads
`(getf edit :path)`. So *the newest changed file* needs no new state:

    (loop for item across (reverse (coerce (session-items …) 'list))
          for body = (item-body item)
          for path = (and (consp body) (getf (getf body :edit) :path))
          when (and (stringp path) (plusp (length path))) return path)

## 4. What this head can and cannot do — and it must not pretend otherwise

The reference **embeds** rano: `rano::editor::Editor` is a library, `open_review` draws the change
over the text, and the pane is `ctrl-]`'s. This head is Lisp and rano is a Rust crate.

**What it CAN do is run rano as a PROGRAM, in the `!term` pane that now exists and works** —
`TermOpen { line: "!term rano <path>" }` — and **`rano` is installed on this box**
(`/home/dead/bin/rano`). That gets the file, rano's syntax, its keys, its mouse and its scrollback.

**What it does NOT get is the review overlay** (`open_review` with the before/after pair — which this
head *does* hold, in `:edit`). So the honest landing says which of the two it is, rather than opening
a plain file and calling it a review.

## 5. Why nothing was landed today

The two helpers and the walk are small and measured above; what is not is the **placement**, and this
file's own history says why that matters — a key must be taken before the paths that assume something
else is the reader. That is a change to the global ladder which wants its own test and its own
attention, and it is one session's worth of care rather than the tail of a long one.
