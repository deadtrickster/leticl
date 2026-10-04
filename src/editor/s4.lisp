;;;; editor.lisp — the input surface: the composer and the key ladder.
;;;;
;;;; The composer (cursor, history, kills) and the precedence ladder that decides
;;;; who a key belongs to. The ladder has the Rust head's fixed precedence: the
;;;; cards that own the keyboard, then the head's own chords, then a click, then
;;;; whatever list is on the screen, then the composer.
;;;;
;;;; **What is gated on an empty composer is ENTER and the digits, not the arrows
;;;; and not the letters.** The whole ladder used to be gated, which reads as a
;;;; rule — a half-typed line always means the line — and cost the operator the
;;;; line it was protecting: an ask arriving mid-sentence could only be answered
;;;; by emptying the composer first, and a pane on the screen swallowed every
;;;; character typed under it. Arrows belong to whatever list is up; Enter and a
;;;; row number belong to the line being typed, and a line that names no option
;;;; answers the marked row and is HELD.
;;;;
;;;; The terminal DECODER is not here — that is `keys.lisp`, the port of
;;;; term.rs's tables. This file receives decoded key plists.

(in-package #:leticl)

;;; ------------------------------------------------------------------ S4 ;;;
;;;
;;; The editor's windows, and every one of them is a GLOBAL rather than a
;;; `composer` slot. A defstruct layout change is a hard error in this SBCL, so a
;;; slot would mean a restart — the one thing a live head must not need. There is
;;; one composer per process, so a defvar each costs nothing and pushes.
;;;
;;; They sit at the TOP of the file rather than beside the functions that use
;;; them, because the key ladder below reaches for several of them and a special
;;; referenced before its defvar is a full compile-time warning (chrome.lisp says
;;; the same about `*esc-at*`).

(defvar *kill-ring* nil
  "Killed text, newest first. `ctrl-y` yanks the head of it.

A ring rather than a single slot: `ctrl-k` then some editing then `ctrl-y` is
the common shape, and a single slot loses the first kill the moment you make a
second one.")
(defparameter *kill-ring-max* 16
  "How many kills to keep. A ring nobody can exhaust is a leak.")

(defvar *undo-stack* nil
  "Snapshots of the composer buffer, newest first, for `ctrl-z`.

Snapshots rather than an operation log: a buffer is a string and a string is
cheap, while replaying operations has to get every one of them right. Batched at
WORD granularity by the caller, so `ctrl-z` undoes a word rather than a
character — a per-character undo makes you hold the key and hope.")
(defparameter *undo-max* 400
  "How many snapshots to keep before dropping the oldest.")

(defvar *dash-nav* nil
  "The dashboard pane's cursor state: a plist `:sel :scroll :open`.

**A `defvar` and NOT a head slot**, and that is this tree's own rule rather than a preference: a
new slot is a struct LAYOUT change, which SBCL refuses to redefine in a running image, so it needs
a restart — and a pane's cursor is not worth one. `*pane-scroll*` is a global for the same reason.
Reset when the pane opens, so it never shows a cursor from a dashboard that has since been
re-registered.")
(defvar *paste-ledger* nil
  "Alist of MARKER → the text that marker stands for.

A paste of five lines or more collapses to a marker in the composer and the full
text is remembered here, then SUBSTITUTED BACK on submit. The point is that a
three-thousand-line paste is one visible token while you are typing and still
arrives whole — the operator sees a marker, the model receives the paste.")

(defparameter *history-max* 50
  "How many submitted prompts are remembered — the reference's `HISTORY_CAP`.
An uncapped history is a leak with a friendly name.")

(defvar *history-recalled* nil
  "The text a history walk last put in the composer, or NIL.

The rule worth having, and the one this head did not have: **once a recalled
entry has been edited, the walk stops**, because the next press would silently
destroy the edit (editor.rs:519-527).")

(defvar *redo-stack* nil
  "Buffers an undo took back, newest first, for `alt+z`.

Cleared by the next EDIT and not by the next key, which is the rule that makes a
redo stack usable: undo, undo, redo, redo walks back and forth, and the moment
you type something the branch you abandoned is gone (editor.rs:441-454, 629).")

(defvar *preferred-col* nil
  "The column a run of ↑/↓ is trying to keep.

Sticky, so walking down through a short line and on to a long one comes back to
the column you started in rather than the end of the short one. Cleared by any
key that is not ↑ or ↓, which is where a vertical walk ends.")

