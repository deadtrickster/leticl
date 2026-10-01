#!/bin/sh
# Package a built leticl as the ONE release asset install.sh asks for.
#
#   scripts/make-dist.sh <target-triple> [outdir]
#
# The contract is install.sh's: it downloads `leticl-<triple>.tar.gz` from the
# release and expects **both binaries and the launcher scripts** at the archive
# root. That naming lives in ONE place — here — and the release workflow calls
# this script, so an asset cannot be built with a name the installer does not ask
# for.
#
# **ONE ASSET AND NOT TWO, which is the whole reason this is not rano's script.**
# `leticl` is only a head: a working install needs `harnessd` too, and the daemon
# is built from a DIFFERENT repository (deadtrickster/letibot) whose releases are
# tagged independently. Making the installer fetch two assets from two repositories
# means two version variables, two arch checks and two ways to half-install. So the
# CI builds both and ships one archive.
#
# Two layouts are accepted, because the workflow may or may not use `--target`:
#   target/release/{leticl-head,harnessd}          a native build
#   target/<triple>/release/{…}                    a cross build
set -eu

triple="${1:-}"
if [ -z "$triple" ]; then
    echo "usage: make-dist.sh <target-triple> [outdir]" >&2
    exit 2
fi
outdir="${2:-dist}"

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The head is this repository's, built by freeze.lisp into bin/leticl-head.
head_bin=""
for candidate in "$repo/bin/leticl-head" "$repo/target/release/leticl-head"; do
    if [ -f "$candidate" ]; then
        head_bin="$candidate"
        break
    fi
done
[ -n "$head_bin" ] || {
    echo "make-dist: no head image: run 'sbcl --script freeze.lisp' first" >&2
    echo "  looked for bin/leticl-head and target/release/leticl-head" >&2
    exit 1
}

# **THE DAEMON AND ITS LIBRARIES COME FROM LETIBOT'S PUBLISHED ASSET, not from a build here.**
# Building it needs a llama.cpp checkout (`tokencore/build.rs` wants `llama.h` and `libllama.so`),
# which letibot's own release workflow goes to the trouble of compiling — and which it then
# PUBLISHES. So `LETIBOT_DIST` names a directory holding the extracted asset:
#
#     harnessd  letibot  libllama.so.0  libggml.so.0  libggml-cpu.so.0  libggml-base.so.0
#
# **THE FOUR LIBRARIES ARE NOT OPTIONAL.** `harnessd` links them and carries an `$ORIGIN` rpath,
# so it finds them as siblings — and an archive that shipped the binary without them would install
# cleanly and die at first run. letibot measured that same shape on arm64 the same day: a binary
# that compiled and could not execute because one `DT_NEEDED` library was missing.
#
# A source build under `daemon/` is still accepted, for working offline.
daemon_bin=""
daemon_libs=""
if [ -n "${LETIBOT_DIST:-}" ]; then
    daemon_bin="$LETIBOT_DIST/harnessd"
    daemon_libs="$LETIBOT_DIST"
else
    for candidate in "$repo/daemon/target/release/harnessd" \
                     "$repo/daemon/target/$triple/release/harnessd"; do
        if [ -x "$candidate" ]; then
            daemon_bin="$candidate"
            daemon_libs="$(dirname "$candidate")"
            break
        fi
    done
fi
[ -n "$daemon_bin" ] && [ -f "$daemon_bin" ] || {
    echo "make-dist: no harnessd. Set LETIBOT_DIST to an extracted letibot release asset" >&2
    echo "  (harnessd letibot libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0)," >&2
    echo "  or build letibot into daemon/ (needs a llama.cpp checkout)." >&2
    exit 1
}
for lib in libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0; do
    [ -f "$daemon_libs/$lib" ] || {
        echo "make-dist: $daemon_libs has no $lib — harnessd links it and would fail at first run" >&2
        exit 1
    }
done

# **THE HIGHLIGHTING SHIM.** Built from `native/hl`, which until 2026-10-01 took rano by
# ABSOLUTE PATH and so could not be built on a runner at all — which is why no archive ever
# carried this file and a fresh install ran uncoloured without saying so. Two layouts: the
# workflow's own `--target-dir hl-target`, and a plain local build.
shim=""
for candidate in "$repo/hl-target/release/libleticl_hl.so" \
                 "$repo/native/hl/target/release/libleticl_hl.so"; do
    if [ -f "$candidate" ]; then
        shim="$candidate"
        break
    fi
done
[ -n "$shim" ] || {
    echo "make-dist: no shim: build it with" >&2
    echo "  cargo build --release --manifest-path native/hl/Cargo.toml --target-dir hl-target" >&2
    exit 1
}

# The launcher, from letibot — the same checkout. Without it nothing can start
# the daemon, so an asset missing it is an install that does not work.
launcher="${LETIBOT_DIST:+$LETIBOT_DIST/letibot}"
[ -n "$launcher" ] || launcher="$repo/daemon/scripts/letibot"
[ -f "$launcher" ] || {
    echo "make-dist: no launcher at daemon/scripts/letibot" >&2
    exit 1
}

mkdir -p "$outdir"
name="leticl-$triple.tar.gz"

# **A FIXED STAGE DIRECTORY AND NO `trap`, deliberately.** `stage=$(mktemp -d)` with a trap that
# deletes it is the obvious spelling and it was the first one: a recursive delete on a path that
# does not exist until the moment it runs. That is legitimate shell and it is UNVERIFIABLE by any
# reader that resolves a command's meaning before running it — including this repository's own
# harness, which refused it, and an unverifiable packaging script is one nobody tests until a
# release goes wrong. A fixed path, emptied at the start of every run, needs no trap and cannot be
# made to pass by a stale directory.
stage="$repo/.make-dist-stage"
rm -rf "$stage"
mkdir -p "$stage"

cp "$head_bin"   "$stage/leticl-head"
cp "$daemon_bin" "$stage/harnessd"
cp "$launcher"   "$stage/letibot"
cp "$shim"       "$stage/libleticl_hl.so"
for lib in libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0; do
    cp "$daemon_libs/$lib" "$stage/$lib"
done
cp "$repo/scripts/leticl"      "$stage/leticl"
cp "$repo/scripts/leticl-head" "$stage/leticl-head-launch"
chmod 755 "$stage/leticl-head" "$stage/harnessd" "$stage/letibot" \
          "$stage/leticl" "$stage/leticl-head-launch"

# COPYFILE_DISABLE stops macOS tar writing AppleDouble `._` entries, which would
# otherwise land in the archive and be extracted by the installer.
COPYFILE_DISABLE=1 tar -czf "$outdir/$name" -C "$stage" \
    leticl-head harnessd letibot \
    libleticl_hl.so libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0 \
    leticl leticl-head-launch

# **PROVE THE ARCHIVE IS WHAT THE INSTALLER EXPECTS BEFORE PUBLISHING IT.** Every
# name here is one install.sh looks for by name; a release that is missing one is
# an install that half-works, which looks like the operator's mistake rather than
# a broken asset.
listing=$(tar -tzf "$outdir/$name")
for want in leticl-head harnessd letibot libleticl_hl.so \
            libllama.so.0 libggml.so.0 libggml-cpu.so.0 libggml-base.so.0 \
            leticl leticl-head-launch; do
    if [ "$(printf '%s\n' "$listing" | grep -c "^$want\$")" -ne 1 ]; then
        echo "make-dist: $name must hold exactly one top-level $want: $listing" >&2
        exit 1
    fi
done

printf '%s\n' "$outdir/$name"
