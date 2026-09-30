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
}

main "$@"
