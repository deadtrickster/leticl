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
    for want in leticl-head harnessd letibot leticl leticl-head-launch; do
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
    chmod 755 "$INSTALL_DIR/leticl" "$INSTALL_DIR/leticl-head-launch"

    # ---------- say what was installed, by running it ----------
    # A binary that cannot run is a failure this script would otherwise report as
    # success, so the version is asked for rather than assumed.
    got=$("$INSTALL_DIR/leticl-head" --version 2>/dev/null || true)
    if [ -n "$got" ]; then
        say "leticl-head   $got"
    else
        warn "warning: $INSTALL_DIR/leticl-head answered nothing to --version"
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

    # ---------- and what it will be missing ----------
    if [ "$(uname -s)" = Linux ] && ! ldconfig -p 2>/dev/null | grep -q 'libsqlite3\.so\.0'; then
        warn ""
        warn "no libsqlite3.so.0: the head will run, but it cannot remember your todos"
        warn "  Debian/Ubuntu:  sudo apt-get install libsqlite3-0"
        warn "  Fedora/RHEL:    sudo dnf install sqlite-libs"
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
