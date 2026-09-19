//! leticl-hl — a C ABI over rano's tree-sitter highlighter, for the leticl head.
//!
//! The head is SBCL and reaches this crate through sb-alien (see RANO.md). The
//! design deliberately does not inherit the Rust letibot integration's
//! weaknesses:
//!
//! - One `Highlighter` per language, kept for the life of the process, so each
//!   language's tree-sitter `Query` compiles exactly once (letibot allocates a
//!   fresh `Highlighter` per call and recompiles the query on every render).
//! - The caller provides the output buffer; nothing here is handed back for the
//!   caller to free.
//! - Every entry point is wrapped in `catch_unwind`: a panic unwinding across an
//!   `extern "C"` boundary aborts the process, and tree-sitter parsing arbitrary
//!   model output is exactly the input that can hit an edge case.
//!
//! The grid unit is one u8 role index per Unicode scalar value, row-major over
//! the source split on `\n` (matching rano's `Highlighter::classes`). That
//! aligns 1:1 with leticl's character strings, which the socket stream decodes
//! as `:element-type 'character :external-format :utf-8`.

use std::cell::RefCell;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;

use rano::syntax::{detect, Highlighter, Lang};

/// 0 = none/unknown, 1..=27 = the rano `Lang` variants in declaration order.
const LANG_SLOTS: usize = 28;

// One `Highlighter` per language id, so a language's query is compiled once and
// its parser reused. Per-thread: the head is a single event loop, and this keeps
// the `Parser` (not `Sync`) out of any shared state. Mapped, not `vec![None; N]`,
// because the latter needs `Option<Highlighter>: Clone` and the `Parser` is not.
thread_local! {
    static HLS: RefCell<Vec<Option<Highlighter>>> =
        RefCell::new((0..LANG_SLOTS).map(|_| None).collect());
}

fn lang_from_id(id: u32) -> Option<Lang> {
    Some(match id {
        1 => Lang::Rust,
        2 => Lang::Go,
        3 => Lang::Bash,
        4 => Lang::Python,
        5 => Lang::C,
        6 => Lang::Json,
        7 => Lang::CommonLisp,
        8 => Lang::JavaScript,
        9 => Lang::TypeScript,
        10 => Lang::Tsx,
        11 => Lang::Markdown,
        12 => Lang::Toml,
        13 => Lang::Yaml,
        14 => Lang::Html,
        15 => Lang::Css,
        16 => Lang::Lua,
        17 => Lang::Ruby,
        18 => Lang::Php,
        19 => Lang::Java,
        20 => Lang::Make,
        21 => Lang::Dockerfile,
        22 => Lang::Ini,
        23 => Lang::Diff,
        24 => Lang::Elisp,
        25 => Lang::Scheme,
        26 => Lang::Sql,
        27 => Lang::Clojure,
        _ => return None,
    })
}

fn id_from_lang(lang: Lang) -> u32 {
    match lang {
        Lang::Rust => 1,
        Lang::Go => 2,
        Lang::Bash => 3,
        Lang::Python => 4,
        Lang::C => 5,
        Lang::Json => 6,
        Lang::CommonLisp => 7,
        Lang::JavaScript => 8,
        Lang::TypeScript => 9,
        Lang::Tsx => 10,
        Lang::Markdown => 11,
        Lang::Toml => 12,
        Lang::Yaml => 13,
        Lang::Html => 14,
        Lang::Css => 15,
        Lang::Lua => 16,
        Lang::Ruby => 17,
        Lang::Php => 18,
        Lang::Java => 19,
        Lang::Make => 20,
        Lang::Dockerfile => 21,
        Lang::Ini => 22,
        Lang::Diff => 23,
        Lang::Elisp => 24,
        Lang::Scheme => 25,
        Lang::Sql => 26,
        Lang::Clojure => 27,
    }
}

/// rano's capture names onto the six syntax role indices, 0 = plain. The table
/// and the dotted-prefix fallback are letibot's `role_for_capture` verbatim; the
/// index → colour decision stays in Lisp, because a palette is a decision about
/// a terminal, not about a parser.
fn role_for_capture(name: &str) -> u8 {
    match name {
        "comment" => 1,
        "string" | "escape" => 2,
        "number" | "constant" | "property" => 3,
        "type" | "constructor" | "label" => 4,
        "keyword" | "include" | "preproc" | "variable.builtin" => 5,
        "function" => 6,
        _ => match name.split_once('.') {
            Some((prefix, _)) => role_for_capture(prefix),
            None => 0,
        },
    }
}

/// The language id for a file path, by rano's extension table. 0 = none.
#[no_mangle]
pub extern "C" fn hl_detect(path: *const c_char) -> u32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if path.is_null() {
            return 0;
        }
        let Ok(s) = unsafe { CStr::from_ptr(path) }.to_str() else {
            return 0;
        };
        let Some(lang) = detect(Some(Path::new(s)), None) else {
            return 0;
        };
        id_from_lang(lang)
    }))
    .unwrap_or(0)
}

/// Highlight the UTF-8 source in `src` (length `src_len`) as language `lang_id`
/// (from `hl_detect`; 0 = none). Fill `out` (capacity `out_cap`) with one role
/// index per scalar value, row-major over the `\n`-split lines. Returns the
/// number of u8s written — the full total on success, 0 on no-language or
/// failure. The caller allocates `out_cap` = total scalar values, so a short
/// return is always a failure, read as uncoloured.
#[no_mangle]
pub extern "C" fn hl_grid(
    src: *const u8,
    src_len: usize,
    lang_id: u32,
    out: *mut u8,
    out_cap: usize,
) -> usize {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let Some(lang) = lang_from_id(lang_id) else {
            return 0;
        };
        if src.is_null() || out.is_null() || src_len == 0 || out_cap == 0 {
            return 0;
        }
        let bytes = unsafe { std::slice::from_raw_parts(src, src_len) };
        let Ok(s) = std::str::from_utf8(bytes) else {
            return 0;
        };
        // The parse holds the per-language `Highlighter` borrow; the owned grid
        // outlives it, so the flatten below runs after the borrow is released.
        let grid = HLS.with(|c| {
            let mut c = c.borrow_mut();
            let slot = &mut c[lang_id as usize];
            let hl = slot.get_or_insert_with(Highlighter::new);
            hl.classes(s, lang)
        });
        if grid.is_empty() {
            return 0;
        }
        // rano's grid is per non-newline char (it splits on `\n` and drops the
        // delimiter). Reconstruct a grid aligned 1:1 with `s`'s characters —
        // one entry per scalar value, newline = role 0 — so the caller indexes
        // it directly against its own character string.
        let mut cells = grid.iter().flatten().peekable();
        let mut written = 0usize;
        for ch in s.chars() {
            if written >= out_cap {
                break;
            }
            let role = if ch == '\n' {
                0
            } else {
                cells
                    .next()
                    .and_then(|c| c.as_deref().map(role_for_capture))
                    .unwrap_or(0)
            };
            unsafe { *out.add(written) = role };
            written += 1;
        }
        written
    }))
    .unwrap_or(0)
}
