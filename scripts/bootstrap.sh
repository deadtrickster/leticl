#!/bin/sh
# Fetch the vendored dependencies at their pinned commits. vendor/ is
# gitignored; reproducibility lives here, not in the tree.
# Approved 2026-09-17 (network egress, once).
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/vendor"

pin () {
  name=$1
  url=$2
  sha=$3
  if [ ! -d "$root/vendor/$name/.git" ]; then
    git clone --quiet "$url" "$root/vendor/$name"
  fi
  git -C "$root/vendor/$name" checkout --quiet "$sha"
}

pin yason                  https://github.com/phmarek/yason.git                          0c84b29
pin trivial-gray-streams   https://github.com/trivial-gray-streams/trivial-gray-streams.git 257d73e
pin alexandria             https://gitlab.common-lisp.net/alexandria/alexandria.git      f283e25

echo "vendor ready"
