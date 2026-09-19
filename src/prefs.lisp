;;;; prefs.lisp — the head's own preferences, on disk (S5 fills this in).
;;;;
;;;; Created by S0 as the file S5 owns; empty of forms on purpose. Today the
;;;; folds and the diff shape live only in the running `head` struct and die
;;;; with the process — the defect `crates/tui/src/prefs.rs`'s header quotes the
;;;; operator about: *"i'd prefer a config option and a pane with runtime-able
;;;; configurations editable"*.
;;;;
;;;; S5 puts here: reading and writing `~/.config/leticl/head.toml` in the flat
;;;; `key = "value"` subset (parsed by hand — four keys do not earn a
;;;; dependency, and a file a person edits with `vi` must survive a comment and
;;;; a key this build does not know), and the read at start / write on change
;;;; that the config pane (S6) needs.
;;;;
;;;; Deliberately empty: S0 is a carve with a byte-identical acceptance test,
;;;; and adding behaviour here would make a failure ambiguous between the move
;;;; and the new code.

(in-package #:leticl)
