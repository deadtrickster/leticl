#!/bin/sh
# Installs leticl: the Common Lisp head, and the daemon it draws.
#
#   curl -fsSL https://raw.githubusercontent.com/deadtrickster/leticl/main/install.sh | sh
#
# **TWO BINARIES FROM TWO REPOSITORIES**, and that is the whole shape of this
# script. `leticl` is only a head: it attaches to a `harnessd` that owns the
# session, the ledger, the tools and the store. So a working install is
#
#   leticl-head   the head image              (deadtrickster/leticl releases)
#   harnessd      the daemon                  (deadtrickster/letibot releases)
#   letibot       the launcher that finds or starts this folder's daemon
#   leticl        the seat, and the hook that points the launcher at our head
#   leticl-head-launch   the wrapper that speaks the launcher's arguments to the image
#
# **THE HEAD IS A SELF-CONTAINED BINARY, which is what makes this possible.**
# `freeze.lisp` saves it with `:executable t`, so it carries SBCL's runtime and
# needs no Lisp installed — measured with `ldd`: libzstd, libm, libc, and nothing
# else. It DOES need `libsqlite3.so.0` at runtime for the todo store; a head
# without it still runs and says so (`store.lisp`), it just cannot remember
# todos.
#
# Environment:
#   LETICL_INSTALL_DIR   where everything goes            (default: ~/.local/bin)
#   LETICL_VERSION       tag of the HEAD   (default: latest release)
#   LETIBOT_VERSION      tag of the DAEMON (default: latest release)
#
# The two versions are separate on purpose: head and daemon are released from
# different repositories and versioned apart, so one variable cannot name both.

set -eu

LETICL_REPO="deadtrickster/leticl"
LETIBOT_REPO="deadtrickster/letibot"

INSTALL_DIR="${LETICL_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${LETICL_VERSION:-}"
DAEMON_VERSION="${LETIBOT_VERSION:-}"

say() { printf '%s\n' "$*"; }
# Everything that is not an answer goes to stderr, so the functions below can be
# used in a command substitution without their chatter becoming the value.
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'leticl: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

# The platform, as the release assets name it. `make-dist.sh` builds the names
# from the same case arm, so a rename on one side fails in CI rather than
# silently degrading every install to a source build.
triple() {
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64)                printf 'x86_64-unknown-linux-gnu' ;;
        Linux/aarch64 | Linux/arm64) printf 'aarch64-unknown-linux-gnu' ;;
        Darwin/arm64)                printf 'aarch64-apple-darwin' ;;
        Darwin/x86_64)               printf 'x86_64-apple-darwin' ;;
        *)                           return 1 ;;
    esac
}

# `-q` FIRST, and it is not cosmetic: curl reads ~/.curlrc, so a single
# `insecure` line there turns certificate verification off for every curl the
# user runs. Downloading a binary that is then executed is not a place to inherit
# somebody's debugging shortcuts. `--proto`/`--proto-redir` keep both hops on
# HTTPS. Rano's installer carries the same two flags and the same measurement.
get() { curl -q -fsSL --proto '=https' --proto-redir '=https' "$1" -o "$2"; }

# One release asset, extracted, with the expected binary in it. Returning
# non-zero is a normal outcome — a platform with no published asset — not an
# error, and the caller names what is missing.
fetch_asset() {
    repo="$1" name="$2" want="$3" version="$4" into="$5"
    if [ -n "$version" ]; then
        url="https://github.com/$repo/releases/download/$version/$name"
    else
        url="https://github.com/$repo/releases/latest/download/$name"
    fi
    get "$url" "$into/$name" 2>/dev/null || return 1
    tar -xzf "$into/$name" -C "$into" 2>/dev/null || return 1
    [ -f "$into/$want" ] || return 1
    printf '%s' "$into/$want"
}

# A script from the head's repository AT THE SAME TAG as the binary, so the
# launcher and the image it launches cannot be a version apart.
fetch_script() {
    repo="$1" path="$2" ref="$3" into="$4"
    get "https://raw.githubusercontent.com/$repo/$ref/$path" "$into/$(basename "$path")" 2>/dev/null || return 1
    printf '%s' "$into/$(basename "$path")"
}

main() {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    t=$(triple) || die "no prebuilt release for $(uname -s)/$(uname -m)
       build from a checkout instead: scripts/freeze-safe && cp bin/leticl-head, or ask for an asset"
    say "leticl: $t -> $INSTALL_DIR"

    # ---------- the two binaries ----------
    warn "Fetching leticl-head ${VERSION:-latest}..."
    head_bin=$(fetch_asset "$LETICL_REPO" "leticl-$t.tar.gz" "leticl-head" "$VERSION" "$tmp") \
        || die "no leticl release asset 'leticl-$t.tar.gz'${VERSION:+ at $VERSION}"

    warn "Fetching harnessd ${DAEMON_VERSION:-latest} from $LETIBOT_REPO..."
    daemon_bin=$(fetch_asset "$LETIBOT_REPO" "harnessd-$t.tar.gz" "harnessd" "$DAEMON_VERSION" "$tmp") \
        || die "no harnessd release asset 'harnessd-$t.tar.gz'${DAEMON_VERSION:+ at $DAEMON_VERSION}
       the daemon lives in $LETIBOT_REPO and is released separately — LETIBOT_VERSION picks its tag"

    # ---------- the scripts, from the tag the head came from ----------
    ref="${VERSION:-main}"
    warn "Fetching the launcher scripts at $ref..."
    launcher=$(fetch_script "$LETICL_REPO" "scripts/leticl" "$ref" "$tmp") || die "could not fetch scripts/leticl"
    wrapper=$(fetch_script "$LETICL_REPO" "scripts/leticl-head" "$ref" "$tmp") || die "could not fetch scripts/leticl-head"

    # ---------- install ----------
    mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
    # cp+chmod rather than install(1): `install` is in GNU and BSD but not in
    # POSIX, and the difference is not worth a portability question here.
    cp "$head_bin"    "$INSTALL_DIR/leticl-head"    || die "cannot write $INSTALL_DIR/leticl-head"
    cp "$daemon_bin"  "$INSTALL_DIR/harnessd"       || die "cannot write $INSTALL_DIR/harnessd"
    cp "$wrapper"     "$INSTALL_DIR/leticl-head-launch"
    cp "$launcher"    "$INSTALL_DIR/leticl"
    chmod 755 "$INSTALL_DIR/leticl-head" "$INSTALL_DIR/harnessd" \
              "$INSTALL_DIR/leticl-head-launch" "$INSTALL_DIR/leticl"

    # **BOTH SCRIPTS DEFAULT `LETICL_HOME` TO THE AUTHOR'S CHECKOUT.** That is
    # right for a checkout and wrong for an install — the image is beside the
    # script, not under a project directory — so it is rewritten here. This is the
    # only edit the installer makes to a shipped file, and it is one line each.
    sed "s|^LETICL_HOME=.*|LETICL_HOME=\"$INSTALL_DIR\"|" "$INSTALL_DIR/leticl-head-launch" > "$INSTALL_DIR/.w" \
        && mv "$INSTALL_DIR/.w" "$INSTALL_DIR/leticl-head-launch"
    sed "s|^LETICL_HOME=.*|LETICL_HOME=\"$INSTALL_DIR\"|" "$INSTALL_DIR/leticl" > "$INSTALL_DIR/.l" \
        && mv "$INSTALL_DIR/.l" "$INSTALL_DIR/leticl"
    chmod 755 "$INSTALL_DIR/leticl-head-launch" "$INSTALL_DIR/leticl"

    # The launcher execs `letibot` with LETIBOT_HEAD pointing at our wrapper, so
    # this is the one line that decides WHICH head the launcher starts.
    sed "s|^export LETIBOT_HEAD=.*|export LETIBOT_HEAD=\"$INSTALL_DIR/leticl-head-launch\"|" \
        "$INSTALL_DIR/leticl" > "$INSTALL_DIR/.l2" && mv "$INSTALL_DIR/.l2" "$INSTALL_DIR/leticl"
    chmod 755 "$INSTALL_DIR/leticl"

    # ---------- say what was installed, by running it ----------
    say "leticl-head   $("$INSTALL_DIR/leticl-head" --version 2>/dev/null || echo '(refused to run)')"

    # ---------- and what is missing ----------
    if need letibot; then
        say "letibot       $(command -v letibot)"
    else
        warn ""
        warn "**The launcher is NOT on your PATH, so nothing can start the daemon yet.**"
        warn "leticl starts its daemon through 'letibot', from $LETIBOT_REPO:"
        warn "  curl -fsSL https://raw.githubusercontent.com/$LETIBOT_REPO/main/scripts/letibot -o \"$INSTALL_DIR/letibot\" && chmod 755 \"$INSTALL_DIR/letibot\""
    fi
    if ! ls /usr/lib/*/libsqlite3.so.0 /usr/lib/libsqlite3.so.0 /lib/*/libsqlite3.so.0 >/dev/null 2>&1; then
        warn ""
        warn "no libsqlite3.so.0 found: the head will run without a todo store."
        warn "  Debian/Ubuntu:  apt-get install libsqlite3-0"
    fi

    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *)
            say ""
            say "That directory is not on your PATH. Add it with:"
            say "  export PATH=\"$INSTALL_DIR:\$PATH\""
            ;;
    esac
}

main "$@"
