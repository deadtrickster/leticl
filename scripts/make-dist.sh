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

# The daemon is letibot's, built from a checkout the workflow puts under
# `daemon/`. Located by the same two-layout rule.
daemon_bin=""
for candidate in "$repo/daemon/target/release/harnessd" \
                 "$repo/daemon/target/$triple/release/harnessd"; do
    if [ -x "$candidate" ]; then
        daemon_bin="$candidate"
        break
    fi
done
[ -n "$daemon_bin" ] || {
    echo "make-dist: no harnessd: check out deadtrickster/letibot at ./daemon and build it" >&2
    echo "  looked under daemon/target/release/ and daemon/target/$triple/release/" >&2
    exit 1
}

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
launcher="$repo/daemon/scripts/letibot"
[ -f "$launcher" ] || {
    echo "make-dist: no launcher at daemon/scripts/letibot" >&2
    exit 1
}

mkdir -p "$outdir"
name="leticl-$triple.tar.gz"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM

cp "$head_bin"   "$stage/leticl-head"
cp "$daemon_bin" "$stage/harnessd"
cp "$launcher"   "$stage/letibot"
cp "$shim"       "$stage/libleticl_hl.so"
cp "$repo/scripts/leticl"      "$stage/leticl"
cp "$repo/scripts/leticl-head" "$stage/leticl-head-launch"
chmod 755 "$stage/leticl-head" "$stage/harnessd" "$stage/letibot" \
          "$stage/leticl" "$stage/leticl-head-launch"

# COPYFILE_DISABLE stops macOS tar writing AppleDouble `._` entries, which would
# otherwise land in the archive and be extracted by the installer.
COPYFILE_DISABLE=1 tar -czf "$outdir/$name" -C "$stage" \
    leticl-head harnessd letibot libleticl_hl.so leticl leticl-head-launch

# **PROVE THE ARCHIVE IS WHAT THE INSTALLER EXPECTS BEFORE PUBLISHING IT.** Every
# name here is one install.sh looks for by name; a release that is missing one is
# an install that half-works, which looks like the operator's mistake rather than
# a broken asset.
listing=$(tar -tzf "$outdir/$name")
for want in leticl-head harnessd letibot libleticl_hl.so leticl leticl-head-launch; do
    if [ "$(printf '%s\n' "$listing" | grep -c "^$want\$")" -ne 1 ]; then
        echo "make-dist: $name must hold exactly one top-level $want: $listing" >&2
        exit 1
    fi
done

printf '%s\n' "$outdir/$name"
