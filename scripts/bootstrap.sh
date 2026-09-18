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
pin anaphora               https://github.com/spwhitton/anaphora.git                     bcf0f74
pin fiveam                 https://github.com/lispci/fiveam.git                          e43d6c8
pin asdf-flv               https://github.com/didierverna/asdf-flv.git                   3f1de41
pin trivial-backtrace      https://github.com/gwkkwg/trivial-backtrace.git               7f90b4a

echo "vendor ready"
