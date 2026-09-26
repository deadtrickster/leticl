use std::time::Instant;

fn us<F: FnMut()>(k: u64, mut f: F) -> f64 {
    // warm
    for _ in 0..(k / 10 + 1) { f(); }
    let t = Instant::now();
    for _ in 0..k { f(); }
    t.elapsed().as_nanos() as f64 / 1000.0 / k as f64
}

fn main() {
    // ---------- width ----------
    let ascii = "the quick brown fox jumps over the lazy dog and keeps going for a while";
    let cjk = "这是一个中文标识符和一个更长的句子，用来测量显示宽度";
    let emoji = "a 🎉 with 🇵🇱 flags 👨‍👩‍👧‍👦 and combining é";
    let code = "fn main() { let x: Vec<String> = v.iter().map(|s| s.to_string()).collect(); }";

    let k = 200_000u64;
    println!("== width (letibot-ui::width::width) ==");
    for (name, s) in [("ascii", ascii), ("cjk", cjk), ("emoji", emoji), ("code", code)] {
        let w = letibot_ui::width::width(s);
        println!("  {name:6} chars={:3} cols={:3}  {:8.4} us/call", s.chars().count(), w,
                 us(k, || { std::hint::black_box(letibot_ui::width::width(std::hint::black_box(s))); }));
    }
    // **IS THE GAP THE ALGORITHM OR THE ALLOCATION?** `width()` is
    // `cells(s).iter().map(|c| c.cols).sum()` — it builds a `Vec<Cell>` for the
    // whole string in order to count it. This is the same arithmetic with no
    // vector, to separate the two.
    println!("  -- the same arithmetic WITHOUT the Vec<Cell> --");
    for (name, s2) in [("ascii", ascii), ("cjk", cjk), ("emoji", emoji), ("code", code)] {
        let sum = us(k, || {
            std::hint::black_box(std::hint::black_box(s2).chars().map(letibot_ui::width::char_width).sum::<usize>());
        });
        println!("  {name:6} chars().map(char_width).sum()  {sum:8.4} us/call   (width() was {:8.4})",
                 us(k / 2, || { std::hint::black_box(letibot_ui::width::width(std::hint::black_box(s2))); }));
    }

    println!("  wrap(ascii, 40)      {:8.4} us/call",
             us(k / 4, || { std::hint::black_box(letibot_ui::width::wrap(std::hint::black_box(ascii), 40)); }));
    println!("  truncate(code, 40)   {:8.4} us/call",
             us(k, || { std::hint::black_box(letibot_ui::width::truncate(std::hint::black_box(code), 40)); }));
    // **pair with the Lisp `wrap-ranges`**, which returns RANGES — the same
    // shape, so neither side is paying for a Vec<String> the other does not build.
    println!("  wrap_ranges(ascii,40) {:8.4} us/call",
             us(k / 4, || { std::hint::black_box(letibot_ui::width::wrap_ranges(std::hint::black_box(ascii), 40)); }));

    // ---------- progress ----------
    use letibot_ui::progress::{bar, duration, prefill_line, thousands, Prefill};
    use letibot_ui::style::Palette;
    let p = Prefill { total: 41200, cache: 38100, processed: 25300, time_ms: 1240 };
    println!("== progress ==");
    println!("  thousands(41200)     {:8.4} us/call", us(k, || { std::hint::black_box(thousands(41200)); }));
    println!("  duration(1240)       {:8.4} us/call", us(k, || { std::hint::black_box(duration(1240)); }));
    println!("  bar(p, 40)           {:8.4} us/call", us(k, || { std::hint::black_box(bar(&p, 40, Palette::Colour)); }));
    println!("  prefill_line(p, 120) {:8.4} us/call", us(k, || { std::hint::black_box(prefill_line(&p, 120, Palette::Colour)); }));

    // ---------- frame decode ----------
    //
    // **THE REAL MIX, from letibot's own `testing::one_of_each`.** A restore is
    // every event kind, so benchmarking one hand-written frame would measure the
    // frame I chose rather than the traffic. Each event is wrapped in the
    // `Envelope` the daemon actually sends, then read back through `FrameReader`
    // — the same path `HeadClient::attach` uses.
    use letibot_sessionlog::event::{Envelope, SessionEvent};
    use letibot_sessionlog::protocol::ServerFrame;
    use letibot_sessionlog::wire::FrameReader;
    use std::io::Cursor;

    let events = letibot_sessionlog::testing::one_of_each();
    let lines: Vec<String> = events
        .iter()
        .map(|e| {
            let env = Envelope { session_id: "s-1".into(), seq: 42, ts: 1, event: e.clone() };
            serde_json::to_string(&ServerFrame::Event(env)).unwrap()
        })
        .collect();
    let total_bytes: usize = lines.iter().map(|l| l.len()).sum();
    println!("== frame decode: {} event kinds, {} bytes total ==", lines.len(), total_bytes);

    // **THE INPUT IS WRITTEN OUT, so the Lisp side measures BYTE-IDENTICAL
    // lines.** Two benchmarks that each build their own fixture measure the two
    // fixtures; this is the only way the comparison means anything.
    {
        use std::io::Write;
        let mut f = std::fs::File::create("/tmp/leticl-probe/perf/frames.jsonl").unwrap();
        for l in &lines { writeln!(f, "{l}").unwrap(); }
        println!("  (wrote {} lines to /tmp/leticl-probe/perf/frames.jsonl)", lines.len());
    }

    // ENCODE (what the daemon does per event; measured here because a head that
    // re-sends anything pays it too)
    let enc = us(2_000, || {
        for e in &events {
            let env = Envelope { session_id: "s-1".into(), seq: 42, ts: 1, event: e.clone() };
            std::hint::black_box(serde_json::to_string(&ServerFrame::Event(env)).unwrap());
        }
    });
    println!("  encode, all {:2} kinds          {:10.4} us/all   {:8.4} us/kind",
             lines.len(), enc, enc / lines.len() as f64);

    // DECODE through the reader, one pass over the whole mix
    let per_pass = us(2_000, || {
        for line in &lines {
            let mut r = FrameReader::new(Cursor::new(std::hint::black_box(line).as_bytes()));
            let _: ServerFrame = r.read().unwrap();
        }
    });
    println!("  decode, all {:2} kinds          {:10.4} us/all   {:8.4} us/kind",
             lines.len(), per_pass, per_pass / lines.len() as f64);
    println!("                                  => an 8000-event restore ~ {:8.2} ms of decode",
             8000.0 * per_pass / lines.len() as f64 / 1000.0);

    // the same without the reader's buffering, for the parse alone
    let parse_only = us(2_000, || {
        for line in &lines {
            let _: ServerFrame = serde_json::from_str(std::hint::black_box(line)).unwrap();
        }
    });
    println!("  serde_json alone, all kinds     {:10.4} us/all   {:8.4} us/kind",
             parse_only, parse_only / lines.len() as f64);

    // per-kind, so a slow kind is visible rather than averaged away
    println!("  -- per kind (decode through the reader) --");
    let mut rows: Vec<(String, f64, usize)> = Vec::new();
    for (i, e) in events.iter().enumerate() {
        let s = serde_json::to_string(e).unwrap();
        let name = s.split('"').nth(3).unwrap_or("?").to_string();
        let per = us(20_000, || {
            let mut r = FrameReader::new(Cursor::new(std::hint::black_box(lines[i].as_str()).as_bytes()));
            let _: ServerFrame = r.read().unwrap();
        });
        rows.push((name, per, lines[i].len()));
    }
    rows.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    for (name, per, len) in rows.iter().take(6) {
        println!("     {name:26} len={len:5}  {per:9.4} us/frame");
    }
    println!("     ... {} kinds, slowest 6 of {}", rows.len(), rows.len());

    // ---------- folding a frame into state ----------
    //
    // The other half of "reading a frame": not parsing it but deciding what it
    // MEANS for a conversation. This is the number that decides how much of a
    // head's event-apply follows the wire out, and it had no counterpart until
    // now — the seam I flagged as unmeasured in R60.
    {
        use letibot_sessionlog::view::{SessionView, ViewBounds};
        let bounds = ViewBounds::default();
        println!("== view apply (folding a decoded frame into state) ==");
        // one pass over the whole mix, from an empty view each time
        let per_pass = us(2_000, || {
            let mut v = SessionView::new("s-1", bounds);
            for e in &events {
                let env = Envelope { session_id: "s-1".into(), seq: 42, ts: 1, event: e.clone() };
                v.apply(&env);
            }
            std::hint::black_box(&v);
        });
        println!("  apply, all {:2} kinds           {:10.4} us/all   {:8.4} us/kind",
                 events.len(), per_pass, per_pass / events.len() as f64);
        println!("                                 => an 8000-event restore ~ {:8.2} ms of apply",
                 8000.0 * per_pass / events.len() as f64 / 1000.0);
    }
}
