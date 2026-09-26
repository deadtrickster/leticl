# perf-rust — the Rust half of the R60 speed comparison

Two probes, one per side, run against **byte-identical input**. This half calls
letibot's *real* crates (`letibot-ui`, `letibot-sessionlog`) — the shipping
functions, not reimplementations — and writes the 25 event lines it measures to
`frames.jsonl`, which `../perf-lisp.lisp` then reads. The event mix is letibot's
own `testing::one_of_each`, so neither side is measured on a frame somebody
chose.

    CARGO_TARGET_DIR=/tmp/perf-target cargo run --release

**`CARGO_TARGET_DIR` is not optional.** Without it the build lands in letibot's
workspace `target/`, which another agent is using; the path dependency compiles
its crates into whichever target dir is set, so pointing it at `/tmp` keeps the
neighbouring tree untouched.

Then the Lisp half:

    sbcl --script scripts/perf-lisp.lisp

**Results and their reading live in R60 §7** of
`~/Projects/head-parity-2026-09-21.md`, including what could not be measured
(there is no Rust cell grid to compare against) and the one measurement that
shows the result is not an artefact (Rust's `width()` allocates a `Vec<Cell>` per
call; the same arithmetic without it is still 2.6× slower than Lisp's).

The Rust probe's `Cargo.toml` points at letibot by absolute path — it is a
dev-box instrument, not a buildable member of either workspace.
