# rano integration — review and improvements

rano (`~/Projects/rano/rano`) is the tree-sitter highlighter both heads reuse.
This file records how the Rust **letibot** head integrates it, the improvements
that review found, and the design of the **leticl** shim that carries those
improvements over instead of the reference implementation's weaknesses.

## How letibot integrates rano

- **Dependency** — `crates/ui/Cargo.toml`: `rano = { path = "/home/dead/Projects/rano/rano" }`,
  an absolute path, documented as deliberate (operator-local, not published).
- **All usage is in `crates/ui/src/sidediff.rs`**, a small surface:
  - `lang_for(path)` → `rano::syntax::detect(Some(Path), None)` — extension-only, no first-line sniff.
  - `class_grid(lines, lang)` → **fresh `Highlighter::new()`** + `hl.classes(&src, lang)` + `role_for_capture`.
  - `role_for_capture` → rano capture name → the ui crate's `Role`s, dotted-prefix fallback.
  - `SplitConfig.lang` carries the detected language into the render.
- **Two call sites in `crates/tui/src/app.rs`:**
  - the transcript activity row — cached in `hist_lines`, rendered once, invalidated on
    content/fold/width change. The rano parse is paid **once per edit**.
  - the live call-card body, via `call_card` in the per-frame live-pane loop — **no cache**.

## Improvements (in order of impact)

### 1. Cache the live call-card's diff body — the real one

`call_card` is rebuilt every frame at 10 Hz for every live call, and the edit diff is in the
body. But the diff body is a pure function of
`(path, before, after, before_start, after_start, width, view, palette, fold)` — all static
while a call is live (the excerpt is fixed at issue time). The only per-frame variable is the
header's `now_ms` timer, and a *Finished* card (the state that actually shows the diff) doesn't
even use the timer. So a completed edit's diff is re-parsed by tree-sitter — twice per frame,
10×/second — producing identical bytes until the card settles into `hist_lines`.

This is the "drawing at 10 Hz cost O(everything)" bug the head already fixed for text and
reasoning via `BlockCache` — the call cards just weren't given the same treatment. Memoize the
body per call (keyed on the excerpt + render params), re-render only the header.

### 2. Reuse one `Highlighter` / cache the `Query` per language in `render_split`

`render_split` calls `class_grid` twice with the *same* `lang`, and each `class_grid` does
`Highlighter::new()` — which starts with `query: None`, so `classes` **recompiles the
tree-sitter `Query`** both times. The `Query` is a pure function of `Lang`
(`Query::new(&lang.language(), lang.query())`); it does not depend on the source text.
Minimal fix: thread one `Highlighter` through both calls so the query compiles once per render.
Better: cache the `Query` per-language in a `LazyLock`/`OnceLock` so it compiles once per
process (verify `Query: Send + Sync` first for a global static).

### 3. Defensive class-grid indexing (robustness, not speed)

In `render_pair`, the text is read safely — `old.get(h.line).copied().unwrap_or("")` — but the
class grid is read with panicking direct indexing: `old_classes[h.line]` / `new_classes[h.line]`.
On a successful parse the row counts match exactly (`lines.join("\n")` split on `\n` gives
`lines.len()` rows), so this is latent, not live. But if `classes` ever returns a short or empty
grid — a catastrophic `parse → None`, a query-compile failure — the text degrades to blank while
the classes **panic**. Use `.get(h.line).unwrap_or(&[])` for the grids to match the text's
defensive style; a missing row should read as "uncoloured," which the `None`-lang path already does.

### 4. Portability of the absolute path (minor, already documented)

Hardcodes `/home/dead`. Cargo doesn't support env-var path deps natively, so the realistic
options are a `[patch]` section or a build-script override. Low priority — the comment already
owns this decision.

### 5. `detect` with `first_line: None` (minor limitation)

Extension-only, so extensionless files render uncoloured. The head only holds the bounded
excerpt (which may not start at line 1), so first-line sniffing isn't reliably available; a
daemon-side language hint would fix it, but the plan forbids daemon changes. Low priority.

## The leticl shim

leticl is SBCL and CFFI-free by default (PLAN.md D2, relaxed 2026-09-19 for exactly this). It
reaches rano through a small Rust `cdylib` — `native/hl/` — called with **sb-alien** (already in
the tree for termios; no new Lisp dependency). The shim is the head's only native component and
degrades to uncoloured when the `.so` is absent.

The shim is structured to **not inherit** the reference implementation's weaknesses:

- **Persistent `Highlighter` + per-language `Query` cache** (improvement #2, done right). The
  shim owns its own static state, so the query compiles once per language for the life of the
  process and the `Parser` is reused. The Rust original recompiles the query on every render
  because it allocates a fresh `Highlighter` per call.
- **Caller-provided output buffer.** The Lisp side allocates the grid
  (`sb-alien:make-alien (array unsigned8 n)`), passes pointer + capacity, the shim fills it and
  returns the count. No Rust-allocated string to free, no leak path.
- **`catch_unwind` at every entry point.** A Rust panic unwinding across an `extern "C"`
  boundary aborts the process; tree-sitter parsing arbitrary model output is exactly the input
  that can hit an edge case. The shim catches and returns an error code instead.
- **Defensive on the Lisp side** (improvement #3): a short or empty grid reads as uncoloured,
  never a bounds fault.

### ABI

The grid unit is **one u8 per Unicode scalar value**, row-major (rows are the source split on
`\n`, matching rano's `classes`). This aligns 1:1 with leticl's character strings: the socket
stream is `:element-type 'character :external-format :utf-8`, so a leticl string is a sequence of
scalar values, and rano's `char` is a scalar value too. Multi-byte characters (CJK, emoji) are
one grid entry and one string element each.

```
hl_detect(path: *const c_char) -> u32
    Language id for a file path by rano's extension table. 0 = none/unknown.

hl_grid(src: *const u8, src_len: usize, lang: u32,
        out: *mut u8, out_cap: usize) -> usize
    Highlight the UTF-8 source in `src` as language `lang` (from hl_detect; 0 = none).
    Fill `out` with one role index per scalar value, row-major over the \n-split lines.
    Returns the number of u8s written — the full total on success, 0 on no-language or
    failure. The caller allocates `out_cap` = total scalar values, so a short return is
    always a failure, read as uncoloured.

Role indices (u8): 0 = plain, then the syntax roles, mapped from rano capture names by the
same table letibot's `role_for_capture` uses (comment, string, number/constant, type,
keyword, function, with the dotted-prefix fallback). The index → colour decision stays in
Lisp: a palette is a decision about a terminal, not about a parser.
```

### Build

`cargo build --release` in `native/hl/` → `target/release/libleticl_hl.so`. First build compiles
rano's 26 grammars (minutes); afterwards it is cached. The `.so` is machine-local, the same
status as letibot's absolute-path dependency. rano's `syntax` API changing breaks the shim at
**build** time (a compile error), not at runtime.

### What leticl still ports to Lisp

The diff machinery is pure and has no native dependency:

- `diff.rs` — Myers O(ND) line diff (prefix/suffix preconditioners, `max_d` guard), intra-line
  word diff (positional pairing, similarity floor), hunk model (MAX_CONTEXT=3, stitching).
- `sidediff.rs` — split/unified view, line numbers, sign-column glyph (the carrier that survives
  `Palette::None` and a pipe), the `/diff` toggle. Syntax colour comes from the shim.
- The hand-written `highlight.rs` streaming lexer is **not** ported: rano colours both the diff
  panels and the streaming fences. rano always full-re-parses (a deliberate choice — reusing the
  old tree leaks byte offsets and panics when a line shortens), which is consistent with leticl's
  current render model (the viewport is rebuilt each frame; leticl has no frozen-prefix cache yet).
