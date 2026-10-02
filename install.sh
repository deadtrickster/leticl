#!/bin/sh
# Installs leticl: the Common Lisp head, and the daemon it draws.
#
#   curl -fsSL https://raw.githubusercontent.com/deadtrickster/leticl/main/install.sh | sh
#
# **ONE ASSET, FIVE FILES.** The release workflow builds both binaries and packages
# the launcher scripts with them, so this downloads `leticl-<triple>.tar.gz` and
# unpacks it. That is the whole install — no toolchain, no second repository, no
# second version to name.
#
#   leticl-head          the head image — a self-contained ELF, no Lisp needed
#   harnessd             the daemon, which owns the session, the ledger and the store
#   letibot              the launcher that finds or starts this folder's daemon
#   leticl               the seat, and the hook that points the launcher at our head
#   leticl-head-launch   the wrapper that speaks the launcher's arguments to the image
#
# The head is saved with `:executable t`, so it carries SBCL's runtime — measured
# with `ldd`: libzstd, libm, libc and nothing else. It does need
# `libsqlite3.so.0` at run time for the todo store; without it the head still runs
# and says so, it just cannot remember todos. This script checks and names it.
#
# Environment:
#   LETICL_INSTALL_DIR   where everything goes       (default: ~/.local/bin)
#   LETICL_VERSION       tag to install              (default: latest release)
#   LETICL_NO_DAEMON     install the head only — no harnessd, no letibot
#   LETICL_FORCE_DAEMON  install the daemon even though one is already there
#
# **THE DAEMON SWITCH, and why the default is careful.** `harnessd` is NOT
# leticl's: it is letibot's, every leticl in every folder on a box talks to the
# same one, and a second copy in a second directory is a second daemon nobody
# asked for. So a `harnessd` that is already here or already on PATH is LEFT
# ALONE and said out loud — and the way to insist is `LETICL_FORCE_DAEMON=1`, not
# the absence of a switch.

set -eu

REPO="deadtrickster/leticl"
INSTALL_DIR="${LETICL_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${LETICL_VERSION:-}"

# `--no-daemon` for the `sh -s -- --no-daemon` spelling, the environment for the
# piped one. Both, because a one-liner that pipes into `sh` cannot take arguments
# any other way — and an env var is what a script wrapping this will reach for.
NO_DAEMON="${LETICL_NO_DAEMON:-}"
FORCE_DAEMON="${LETICL_FORCE_DAEMON:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-daemon | --head-only) NO_DAEMON=1 ;;
        --force-daemon)            FORCE_DAEMON=1 ;;
        --install-dir)             shift; INSTALL_DIR="${1:-$INSTALL_DIR}" ;;
        *) printf 'leticl: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
# Everything that is not an answer goes to stderr, so the functions below can be
# used in a command substitution without their chatter becoming the value.
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'leticl: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

# The platform, as the release assets name it. `scripts/make-dist.sh` builds the
# names from the same case arm and the workflow asserts the archive's contents, so
# a mismatch fails in CI rather than silently degrading to a build from source.
# **THE FILES THIS ARCHIVE MUST CONTAIN, DECLARED ONCE.**
#
# **AND IT IS A DECLARATION RATHER THAN A LOOP HEADER BECAUSE THE WORKFLOW READS IT.** The names
# used to live in three places — this file's `for want in`, the packaging step's own list, and the
# publish step's assertion — and when `letibot-askpass` was added, all three needed editing.
# MEASURED: the installer learned it, the packaging step did not, and `v0.1.3` was published with
# ten files while this file required eleven. The oneliner refused on a real install with *"has no
# letibot-askpass in it — the asset is broken, not your machine"* — the refusal working perfectly,
# on my own asset.
#
# That is the same drift `HOST_LIBS` was made un-driftable for one layer out: a list in the
# workflow and a list here will separate, and **the one the user runs is not the one CI checks.**
# So the workflow reads THIS line out of the TAGGED install.sh (see `.github/workflows/release.yml`)
# and refuses if it is absent, rather than keeping its own copy.
#
# A line of space-separated names on one line, because the reader is `sed`.
ARCHIVE_FILES="leticl-head harnessd letibot letibot-askpass libleticl_hl.so libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0 leticl leticl-head-launch"

triple() {
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64)                printf 'x86_64-unknown-linux-gnu' ;;
        Linux/aarch64 | Linux/arm64) printf 'aarch64-unknown-linux-gnu' ;;
        *)                           return 1 ;;
    esac
}

main() {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    t=$(triple) || die "no prebuilt release for $(uname -s)/$(uname -m)
       the assets are Linux x86_64 and aarch64 today; macOS is not covered yet.
       To build from a checkout: sbcl --script freeze.lisp, then cargo build
       --release -p letibot-harnessd in a letibot checkout."
    say "leticl: $t -> $INSTALL_DIR"

    name="leticl-$t.tar.gz"
    if [ -n "$VERSION" ]; then
        url="https://github.com/$REPO/releases/download/$VERSION/$name"
    else
        url="https://github.com/$REPO/releases/latest/download/$name"
    fi

    need curl || die "no curl: needed to download the release"
    # `-q` FIRST, and it is not cosmetic: curl reads ~/.curlrc, so a single
    # `insecure` line there turns certificate verification off for every curl the
    # user runs. Downloading a binary that is then executed is not a place to
    # inherit somebody's debugging shortcuts. `--proto`/`--proto-redir` keep both
    # hops on HTTPS.
    warn "Fetching $name ${VERSION:+($VERSION)}..."
    curl -q -fsSL --proto '=https' --proto-redir '=https' -o "$tmp/$name" "$url" \
        || die "no asset at $url
       check the release exists: https://github.com/$REPO/releases"

    tar -xzf "$tmp/$name" -C "$tmp" 2>/dev/null || die "$name is not a readable archive"
    # **SIX FILES, AND THE SHIM IS THE ONE THAT WAS MISSING FOR MONTHS.** `libleticl_hl.so` is
    # rano's tree-sitter highlighter behind a C ABI; without it the head runs and simply has no
    # colour, silently — see `hl-so-path`. It is in the archive now because `native/hl/Cargo.toml`
    # pins rano's published tag instead of a path on one machine.
    # **TEN FILES, AND THE EIGHT THAT ARE NOT SCRIPTS ARE THE INTERESTING ONES.** `harnessd` links
    # four llama libraries and carries an `$ORIGIN` rpath, so it finds them as siblings; an archive
    # that shipped the binary without them would install cleanly and die at first run. The shim is
    # rano's highlighter. Named here rather than discovered at first use.
    # **ELEVEN, AND `letibot-askpass` IS THE ONE THAT WAS MISSING FROM THE ARCHIVE.** Measured on
    # a clean box, in the launcher's own words: *"sudo will have no way to ask for a password:
    # letibot-askpass is not beside harnessd"*. `harnessd` execs it as its `SUDO_ASKPASS`, so
    # without it a session that reaches a `sudo` command cannot ask the operator for anything —
    # a failure at first USE rather than at install, which is the shape this whole exercise exists
    # to find.
    # **FROM THE DECLARATION ABOVE, so there is one list.** `$ARCHIVE_FILES` is unquoted on
    # purpose: it is a space-separated list and the word splitting is the iteration.
    for want in $ARCHIVE_FILES; do
        [ -f "$tmp/$want" ] || die "$name has no $want in it — the asset is broken, not your machine"
    done

    mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
    # cp+chmod rather than install(1): `install` is in GNU and BSD but not in
    # POSIX, and the difference is not worth a portability question here.

    # **THE HEAD, ALWAYS.** It is leticl's own, it is what makes this leticl, and
    # there is no other copy of it to find.
    for f in leticl-head leticl leticl-head-launch; do
        cp "$tmp/$f" "$INSTALL_DIR/$f" || die "cannot write $INSTALL_DIR/$f"
        chmod 755 "$INSTALL_DIR/$f"
    done

    # **THE SHIM, beside the image, and 0644 rather than 0755.** It is dlopen'd, not exec'd, and
    # the copy loop below chmods everything it touches to 0755 — which for a shared library is
    # merely untidy rather than wrong, but this says what the file IS.
    cp "$tmp/libleticl_hl.so" "$INSTALL_DIR/libleticl_hl.so" || die "cannot write $INSTALL_DIR/libleticl_hl.so"
    chmod 644 "$INSTALL_DIR/libleticl_hl.so"
    # **AND THE FOUR LIBRARIES HARNESSD LINKS**, beside it, for the `$ORIGIN` rpath. Without these
    # the daemon installs and cannot start, which is the worst shape a failure can take — the
    # operator's own rule, and letibot measured the same class on arm64 the same day.
    for lib in libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0; do
        cp "$tmp/$lib" "$INSTALL_DIR/$lib" || die "cannot write $INSTALL_DIR/$lib"
        chmod 644 "$INSTALL_DIR/$lib"
    done
    # **AND THE ASKPASS HELPER, BESIDE `harnessd` — that adjacency is the contract.** `harnessd`
    # looks for it next to itself, so this is not a convenience copy: a different directory is the
    # same as absent.
    cp "$tmp/letibot-askpass" "$INSTALL_DIR/letibot-askpass" || die "cannot write $INSTALL_DIR/letibot-askpass"
    chmod 755 "$INSTALL_DIR/letibot-askpass"

    # **THE DAEMON, AND THE SWITCH.** Three answers, and the middle one is the
    # default because it is the case that actually happens: a box that already has
    # harnessd gets its head installed and its daemon left alone.
    #
    #   · `LETICL_NO_DAEMON` — do not install it, whatever is there;
    #   · a `harnessd` already here or on PATH — KEPT, and said out loud with the
    #     path it was found at;
    #   · otherwise — installed, which is the first time.
    existing=""
    if [ -n "$FORCE_DAEMON" ]; then
        existing=""
    elif command -v harnessd >/dev/null 2>&1; then
        existing=$(command -v harnessd)
    elif [ -x "$INSTALL_DIR/harnessd" ]; then
        existing="$INSTALL_DIR/harnessd"
    fi

    if [ -n "$NO_DAEMON" ]; then
        say "harnessd      not installed (--no-daemon)${existing:+ — you have $existing}"
        say "letibot       not installed (--no-daemon)"
    elif [ -n "$existing" ]; then
        say "harnessd      KEPT: $existing"
        say "              (LETICL_FORCE_DAEMON=1 to replace it, LETICL_NO_DAEMON=1 to silence this)"
    else
        for f in harnessd letibot; do
            cp "$tmp/$f" "$INSTALL_DIR/$f" || die "cannot write $INSTALL_DIR/$f"
            chmod 755 "$INSTALL_DIR/$f"
        done
        say "harnessd      $INSTALL_DIR/harnessd"
        say "letibot       $INSTALL_DIR/letibot"
    fi

    # **THREE LINES REWRITTEN, because both scripts ship pointed at a CHECKOUT.**
    # Upstream `LETICL_HOME` is the author's project directory and the wrapper is
    # found under `scripts/`; in an install everything is beside this script. These
    # are the only edits made to a shipped file, and each is one line — a script
    # that guessed its own location at run time would be the alternative and would
    # break the moment somebody symlinked it.
    sed "s|^LETICL_HOME=.*|LETICL_HOME=\"$INSTALL_DIR\"|" \
        "$INSTALL_DIR/leticl" > "$INSTALL_DIR/.leticl.new" \
        && mv "$INSTALL_DIR/.leticl.new" "$INSTALL_DIR/leticl"
    sed "s|^export LETIBOT_HEAD=.*|export LETIBOT_HEAD=\"$INSTALL_DIR/leticl-head-launch\"|" \
        "$INSTALL_DIR/leticl" > "$INSTALL_DIR/.leticl.new" \
        && mv "$INSTALL_DIR/.leticl.new" "$INSTALL_DIR/leticl"
    sed -e "s|^LETICL_HOME=.*|LETICL_HOME=\"$INSTALL_DIR\"|" \
        -e "s|^IMAGE=.*|IMAGE=\"$INSTALL_DIR/leticl-head\"|" \
        "$INSTALL_DIR/leticl-head-launch" > "$INSTALL_DIR/.launch.new" \
        && mv "$INSTALL_DIR/.launch.new" "$INSTALL_DIR/leticl-head-launch"
    # **THE FOURTH REWRITE, AND IT IS THE ONE THAT MADE THE ONELINER FAIL AT FIRST USE.**
    # `scripts/letibot:39` defaults its binary directory to
    #
    #     BIN="${LETIBOT_BIN:-/home/dead/Projects/letibot/letibot/target/release}"
    #
    # — the author's build tree. MEASURED on a clean debian:stable-slim with all six files
    # installed and on PATH: `leticl` printed *"no harnessd at
    # /home/dead/Projects/letibot/letibot/target/release — run: cargo build --release"* with the
    # binary sitting one directory away, and did not start. Setting LETIBOT_BIN to the install
    # directory fixed it entirely, and the next thing it said was the correct *"nothing serving on
    # 127.0.0.1:8080. Start the model first"*.
    #
    # So the install is COMPLETE only with this line, and the first cut of this script swept only
    # the files this repository owns — the third script's assumption went unexamined because it
    # was somebody else's file.
    sed "s|^BIN=.*|BIN=\"${LETIBOT_BIN:-$INSTALL_DIR}\"|" \
        "$INSTALL_DIR/letibot" > "$INSTALL_DIR/.letibot.new" \
        && mv "$INSTALL_DIR/.letibot.new" "$INSTALL_DIR/letibot"
    chmod 755 "$INSTALL_DIR/leticl" "$INSTALL_DIR/leticl-head-launch" "$INSTALL_DIR/letibot"

    # ---------- say what was installed, by running it ----------
    # **`-h`, NOT `--help` AND NOT `--version`, AND THAT IS MEASURED.** The head is a frozen
    # SBCL image, and SBCL's RUNTIME parses `--help` and `--version` before any Lisp runs — so
    # `leticl-head --version` prints `SBCL 2.6.0.debian` and never reaches the head's own
    # argument list. `-h` does reach it: the head prints its own usage and exits 0. So this asks
    # with the flag that gets an answer from the thing being tested. (A user typing `--help` gets
    # the runtime's page; the head's own usage names the right flag, see `usage`.)
    got=$("$INSTALL_DIR/leticl-head" -h 2>/dev/null | head -1 || true)
    if [ -n "$got" ]; then
        say "leticl-head   runs ($got ...)"
    else
        warn "warning: $INSTALL_DIR/leticl-head answered nothing to -h"
        warn "         it is installed; run it to see what it says"
    fi
    [ -n "$NO_DAEMON" ] || [ -z "$existing" ] || say "harnessd      $existing  (kept)"

    # ---------- where a cloud key goes ----------
    # **A FRESH BOX HAS NO providers.toml, and that is the file the daemon's own
    # refusal names.** MEASURED on an empty config directory:
    #
    #   harnessd: provider deepseek: no key for `deepseek`: set $DEEPSEEK_API_KEY,
    #     pass --api-key, or put `key = "…"` under `[deepseek]` in
    #     /tmp/fresh/config/letibot/providers.toml
    #
    # That message is good enough that nothing else is needed to ENTER a key —
    # there is no interactive prompt in this tree (`/login` is `/flowy login`, a
    # seat, not a provider). What was missing is the FILE: the refusal names a path
    # that does not exist yet on a fresh box. So it is written once and never
    # touched again — it holds a key, and a second copy of somebody's credential is
    # worse than none.
    #
    # Mode 600, because a provider key in a world-readable file is a key somebody
    # else can spend.
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/letibot"
    if [ -f "$cfg/providers.toml" ]; then
        say "providers     $cfg/providers.toml  (left alone)"
    else
        mkdir -p "$cfg" 2>/dev/null || true
        if ( umask 077; cat > "$cfg/providers.toml" <<'PROVIDERS'
# letibot: the provider keys, and the prices they are metered against.
#
# WHERE A KEY COMES FROM, in this order (crates/provider/src/keys.rs):
#   1. --api-key FLAG                        a one-off
#   2. $DEEPSEEK_API_KEY / $ZHIPUAI_API_KEY / $XAI_API_KEY
#   3. this file, under [deepseek] / [glm] / [grok]
#   4. ~/.local/share/opencode/auth.json     `type: api` entries only
#
# A missing key is a refusal that names all four, rather than "unauthorized" from
# the provider three seconds later — which names none of them.
#
# To use deepseek, uncomment and paste:
#
# [deepseek]
# key = "sk-..."
#
# **NOTHING HERE IS NEEDED FOR A LOCAL MODEL.** The daemon's default is
# 127.0.0.1:8080, which takes no key at all; this file matters only when the turns
# go to a cloud provider.
PROVIDERS
        ) 2>/dev/null; then
            chmod 600 "$cfg/providers.toml" 2>/dev/null || true
            say "providers     $cfg/providers.toml  (written, no key in it yet)"
        fi
    fi

    # ---------- the libraries that come from the HOST, named ----------
    # **THREE, AND THEY ARE THE ONES `harnessd` CANNOT START WITHOUT.** The archive ships the four
    # llama/ggml libraries, but those in turn need the system's C++ and OpenMP runtimes, and
    # `harnessd` needs sqlite. MEASURED on a clean debian:stable-slim, which is why this exists:
    #
    #   harnessd: error while loading shared libraries: libgomp.so.1: cannot open shared object file
    #   -- and the daemon exits 1, after a launcher that had checked everything it knew how to check.
    #
    # The rule is *name them, not ship them*: they belong to the system, and a copy in the archive
    # would be a libc-compatibility claim nobody measured.
    #
    # **THE THIRD ONE IS NOT MINE.** I found `libgomp.so.1` and `libstdc++.so.6` by hand; letibot's
    # installer read the tree and found `libsqlite3.so.0` too, and its commit says naming two *"would
    # have left the same defect in place for anyone whose box"* lacked the third. Both installers
    # name the same three now, and the workflow asserts the two lists agree.
    #
    # Which needs which, so a reader can tell a real failure from a stale list:
    #   libgomp.so.1      libggml-cpu.so.0     (OpenMP)
    #   libstdc++.so.6    libllama.so.0        (C++)
    #   libsqlite3.so.0   harnessd             (the session store)
    if [ "$(uname -s)" = Linux ]; then
        missing=""
        for lib in libstdc++.so.6 libgomp.so.1 libsqlite3.so.0; do
            # `ldconfig -p` is the loader's own answer; absent means not installed, whichever distro.
            ldconfig -p 2>/dev/null | grep -q "$lib" || missing="$missing $lib"
        done
        if [ -n "$missing" ]; then
            warn ""
            warn "**THE DAEMON CANNOT START WITHOUT THESE, and they are not installed:**$missing"
            warn ""
            warn "They belong to the system rather than to this archive, so they are named and not"
            warn "shipped. Install them and run leticl again:"
            warn "  Debian/Ubuntu:  sudo apt-get install libstdc++6 libgomp1 libsqlite3-0"
            warn "  Fedora/RHEL:    sudo dnf install libstdc++ libgomp sqlite-libs"
            warn "  Arch:           sudo pacman -S gcc-libs gcc-libs sqlite"
            warn ""
            warn "The HEAD runs without them; it is the daemon that needs them, so you would see a"
            warn "working screen with nothing behind it. That distinction is why this is a warning"
            warn "rather than a refusal — but the install is not finished without them."
        fi
    fi

    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *)
            say ""
            say "That directory is not on your PATH. Add it with:"
            say "  export PATH=\"$INSTALL_DIR:\$PATH\""
            ;;
    esac
    say ""
    say "Run 'leticl' in a project folder: it starts this folder's daemon and draws it."
    # ---------- AND WHAT A FRESH BOX STILL NEEDS, WHICH IS TWO MODELS ----------
    # **MEASURED on a clean debian:stable-slim with eleven files installed, the launcher reading
    # LETIBOT_HEAD and the daemon linking: it gets all the way to seating a session and then
    # REFUSES, by name, for a prerequisite that is not a package.** That is the honest end of this
    # installer, and leaving it unsaid would make the refusal look like a packaging bug:
    #
    #   harnessd: no vocabulary GGUF at /home/dead/models/… .gguf
    #   harnessd: the `automode-edits` mode needs 3 prerequisites … missing: an
    #             authorisation oracle → [gatekeeper] endpoint = "HOST:PORT" in providers.toml
    #
    # Both are FILES THIS INSTALLER CANNOT SHIP. The vocab is a real model — ~25 GB for a small
    # single-file quantisation; measured that a SPLIT model's first shard is 10.4 MB with zero
    # tensors and libllama refuses it, so it is not a metadata download. The guard is a second
    # model, and `automode-edits` — the mode `leticl` seats — will not open without one, by its own
    # choice: *"This refuses rather than opening at a weaker mode."*
    say ""
    say "**TWO THINGS A FRESH BOX STILL NEEDS, and neither is a package:**"
    say "  · a MODEL to tokenise with — harnessd needs a vocabulary GGUF on every start, cloud"
    say "    provider included. Point it with LETIBOT_VOCAB=/path/to/model.gguf (a single file;"
    say "    a split model's first shard is metadata only and is refused)."
    say "  · an AUTHORISATION ORACLE — the mode leticl seats refuses to open without one. Put its"
    say "    address in ~/.config/letibot/providers.toml under [gatekeeper] endpoint, or pass"
    say "    --oracle HOST:PORT. Without it the daemon says so by name and exits."
    say ""
    say "Both are named rather than silently absent: the head will not draw a working session until"
    say "they exist, and it will tell you which one is missing."
    # A key already in the file means no advice is needed; the absence of one is
    # the only case where the three ways are worth printing.
    if ! grep -qE '^key[[:space:]]*=' "$cfg/providers.toml" 2>/dev/null; then
        say ""
        say "It draws a LOCAL model by default (127.0.0.1:8080), which needs no key."
        say "For a CLOUD provider the key goes in one of three places:"
        say "  export DEEPSEEK_API_KEY=sk-...     then:  leticl --provider deepseek"
        say "  $cfg/providers.toml — uncomment [deepseek] and paste it"
        say "  a one-off:  harnessd --provider deepseek --api-key sk-..."
    fi
}

main "$@"
