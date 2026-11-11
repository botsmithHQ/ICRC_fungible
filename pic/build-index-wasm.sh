#!/usr/bin/env bash
#
# Build the ICRC index canister that some pic tests install next to the ledger
# (pic/icrc85.test.ts, pic/index_push.test.ts, pic/timertool_upgrade.test.ts,
# pic/verify_token_timer.test.ts). They read it from a sibling checkout:
#   <this repo>/../index.mo/.dfx/local/canisters/icrc_index/icrc_index.wasm.gz
#
# If that directory does not exist, it is cloned from INDEX_MO_REPO at
# INDEX_MO_SHA (what CI does). If it exists, it is built as it is, at whatever
# commit it is on (a developer's own checkout).
#
# Like pic/build-token-wasm.sh, it skips dfx: index.mo's own `mops install`,
# its pinned moc (`mops toolchain bin moc`) and `mops sources`, then gzip.
#
# index.mo's mops.lock is written by a 2.x mops CLI. The repo's CLI (3.x,
# MOPS_CLI_VERSION in .github/workflows/ci.yml) re-resolves such a lock and
# rewrites it, so index.mo is installed and built with MOPS2, a 2.x CLI: CI
# points it at ic-mops@$MOPS2_CLI_VERSION; otherwise `mops` on PATH must be one.
#
# Usage: bash pic/build-index-wasm.sh
set -euo pipefail

INDEX_MO_REPO="${INDEX_MO_REPO:-https://github.com/botsmithHQ/index.mo.git}"
INDEX_MO_SHA="${INDEX_MO_SHA:-eb4985e06b5b8b328779131c154281e14c88c83f}"

MOPS2="${MOPS2:-mops}"
case "$("$MOPS2" --version 2>/dev/null)" in
  "CLI 2."*) ;;
  *) echo "MOPS2 ($MOPS2) is not a 2.x mops CLI; index.mo's mops.lock is a 2.x lock" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(dirname "$ROOT")/index.mo"

if [ ! -d "$DIR" ]; then
  git init -q "$DIR"
  git -C "$DIR" remote add origin "$INDEX_MO_REPO"
  git -C "$DIR" fetch -q --depth 1 origin "$INDEX_MO_SHA"
  git -C "$DIR" checkout -q --detach FETCH_HEAD
fi
echo "index.mo at $(git -C "$DIR" rev-parse HEAD) ($DIR)"

cd "$DIR"
"$MOPS2" install >/dev/null
if ! git diff --quiet -- mops.lock; then
  echo "mops install rewrote index.mo's mops.lock: wrong mops CLI version ($("$MOPS2" --version | head -1))?" >&2
  git diff --stat -- mops.lock >&2
  exit 1
fi
MOC="$("$MOPS2" toolchain bin moc)"
echo "moc: $MOC ($("$MOC" --version))"

out_dir=".dfx/local/canisters/icrc_index"
mkdir -p "$out_dir"
# shellcheck disable=SC2046
"$MOC" $("$MOPS2" sources) -o "$out_dir/icrc_index.wasm" src/Canisters/Index.mo
gzip -9 -f "$out_dir/icrc_index.wasm"
ls -la "$out_dir/icrc_index.wasm.gz"
