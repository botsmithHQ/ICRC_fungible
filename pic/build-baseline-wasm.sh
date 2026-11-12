#!/usr/bin/env bash
#
# Build the ledger as it was at an earlier commit, for the tests that upgrade
# it in place to the current build:
#   token_baseline  (5fb6104) BEFORE ICRC-85 was switched off: a ledger, and its
#                   archives, that shared cycles (pic/icrc85_off.test.ts)
#   token_one_step  (bb166f8) BEFORE the two-step owner hand-off
#                   (pic/owner_handoff.test.ts)
#   token_pre_lock, token_mixin_pre_lock  (f3d042e) BEFORE the supply lock
#                   (pic/supply_lock.test.ts)
#   token_pre_limit (f3d042e) BEFORE the archive controller limit was
#                   checked at install (pic/archive_upgrade_results.test.ts)
#   token_pre_text106 (d894507) BEFORE the ICRC-106 index principal was stored
#                   as #Text: its setter stored #Blob (pic/icrc106_blob_upgrade.test.ts)
#
# It checks out the ref into a throwaway git worktree, resolves that tree's
# own dependencies (with a 2.x mops CLI, MOPS2), compiles its src/Token.mo (or [main]) with the same flags as
# build-token-wasm.sh, and writes
#   .dfx/local/canisters/<name>/<name>.wasm.gz
# The throwaway worktree is removed on exit.
#
# Usage: bash pic/build-baseline-wasm.sh [ref] [name] [main] [cli]
#        (defaults: BASELINE_REF below, token_baseline, src/Token.mo, mops2)
#        cli = mops2: the ref has a 2.x mops.lock and icrc3-mo 0.4.3 (built with
#        MOPS2, icrc3 patched to 0.4.4, see below). cli = mops: the ref already
#        has a 3.x lock and icrc3-mo 0.4.4 (built with the repo's own mops, no
#        patch).
# pic/build-token-wasm.sh runs it for each of those targets.
set -euo pipefail

# The library's main before the ICRC-85 switches landed.
BASELINE_REF="${1:-5fb6104}"
NAME="${2:-token_baseline}"
MAIN="${3:-src/Token.mo}"
CLI_KIND="${4:-mops2}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
cleanup() {
  git -C "$ROOT" worktree remove --force "$TMP/src" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if ! git cat-file -e "$BASELINE_REF^{commit}" 2>/dev/null; then
  echo "baseline $BASELINE_REF is not in this clone's history (shallow clone?): git fetch --unshallow, or pass a ref" >&2
  exit 1
fi
# Every baseline ref has a mops.lock written by a 2.x mops CLI. The repo's CLI
# (3.x, MOPS_CLI_VERSION in .github/workflows/ci.yml) re-resolves such a lock
# and rewrites it, with a different dependency set (its `base`, for one), so
# the baseline would no longer be the ledger as it was built at that ref. The
# throwaway worktree is installed and built with MOPS2, a 2.x CLI: CI points it
# at ic-mops@$MOPS2_CLI_VERSION; otherwise `mops` on PATH must be one.
case "$CLI_KIND" in
  mops2)
    MOPS2="${MOPS2:-mops}"
    case "$("$MOPS2" --version 2>/dev/null)" in
      "CLI 2."*) ;;
      *) echo "MOPS2 ($MOPS2) is not a 2.x mops CLI; the baseline refs have 2.x mops.lock files" >&2; exit 1 ;;
    esac
    ;;
  mops)
    # A ref from after the 3.x adoption: its lock was written by the repo's CLI.
    MOPS2=mops
    case "$("$MOPS2" --version 2>/dev/null)" in
      "CLI 3."*) ;;
      *) echo "mops on PATH is not a 3.x mops CLI (cli = mops)" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unknown cli '$CLI_KIND' (mops2 | mops)" >&2; exit 1 ;;
esac
# --- icrc3-mo 0.4.3 -> 0.4.4 in the baseline (TEMPORARY, see vendor/README.md) ---
# icrc3-mo 0.4.4 changed the stored type of its v0_1_0 migration state. A ledger
# built with 0.4.0-0.4.3 cannot be upgraded in place to a 0.4.4 build: the
# runtime refuses it ("RTS error: Memory-incompatible program upgrade", M0170).
# Every baseline ref predates the adoption, so each baseline gets exactly the
# upstream 0.4.3 -> 0.4.4 delta: the four files below, copied from HEAD's
# vendor/icrc3-mo (which carries no LOCAL PATCH in them), plus the two packages
# the delta imports (map, vector). The rest of the baseline's icrc3-mo (archive,
# ICRC-85 switches, ...) stays as it was at the ref. A ref whose icrc3-mo is not
# exactly 0.4.3 in these files stops the build.
# Remove this block once every baseline ref is a commit that already has 0.4.4.
ICRC3_DELTA_FILES=(
  "438cba095f02059d47b9e50f80e03c25b0295f4950f93ada621b6c905ed1a194 mops.toml"
  "0ee190c0c346ef9dc81c85c6878cda3753e25562425a623ac166f36b34b685a8 src/migrations/v000_001_000/lib.mo"
  "b7f9c9feb180102895f39fdbb47b0c6561728ed73627b6950b120f656d0ca19b src/migrations/v000_001_000/types.mo"
  "aafada16c2ae3347b410e524988b120fe7b90f460d3690b471e87fbb6f29d091 src/migrations/v000_002_000/lib.mo"
)
ICRC3_HEAD="$ROOT/vendor/icrc3-mo"
# map and vector as HEAD resolves them (HEAD's mops install must have run).
ICRC3_EXTRA_SOURCES=""
for pkg in $([ "$CLI_KIND" = mops2 ] && echo map vector); do
  src="$(cd "$ROOT" && mops sources | awk -v p="$pkg" '$1 == "--package" && $2 == p { print $3 }')"
  if [ -z "$src" ] || [ ! -d "$ROOT/$src" ]; then
    echo "icrc3 delta: HEAD does not resolve '$pkg' (run mops install at the repo root)" >&2
    exit 1
  fi
  # Copied under $TMP: $SOURCES is word-split, and $ROOT may contain spaces.
  cp -R "$ROOT/$src" "$TMP/pkg-$pkg"
  ICRC3_EXTRA_SOURCES+="--package $pkg $TMP/pkg-$pkg "
done

patch_icrc3_to_044() {
  local dir="$1" entry sum f
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    echo "icrc3 delta: $dir is not a plain directory in the baseline; refusing to write to it" >&2
    return 1
  fi
  # Refuse anything but exactly 0.4.3 in the files the delta touches.
  for entry in "${ICRC3_DELTA_FILES[@]}"; do
    sum="${entry%% *}"; f="${entry#* }"
    if [ -L "$dir/$f" ] || [ ! -f "$dir/$f" ]; then
      echo "icrc3 delta: baseline $BASELINE_REF has no plain $f in $dir" >&2
      return 1
    fi
    if [ "$(shasum -a 256 "$dir/$f" | cut -c1-64)" != "$sum" ]; then
      echo "icrc3 delta: baseline $BASELINE_REF: $dir/$f is not icrc3-mo 0.4.3; not patching" >&2
      return 1
    fi
  done
  local before="$TMP/icrc3-before"
  cp -R "$dir" "$before"
  for entry in "${ICRC3_DELTA_FILES[@]}"; do
    f="${entry#* }"
    cp "$ICRC3_HEAD/$f" "$dir/$f"
  done
  # (a) the delta files now match HEAD byte for byte;
  for entry in "${ICRC3_DELTA_FILES[@]}"; do
    f="${entry#* }"
    cmp -s "$ICRC3_HEAD/$f" "$dir/$f" || { echo "icrc3 delta: $f differs from HEAD after patching" >&2; return 1; }
  done
  # (b) nothing else in the baseline's icrc3-mo changed...
  local changed expected
  changed="$( { diff -rq "$before" "$dir" || true; } | sed "s#^Files $before/\([^ ]*\) and .*#\1#" | sort)"
  expected="$(for entry in "${ICRC3_DELTA_FILES[@]}"; do echo "${entry#* }"; done | sort)"
  if [ "$changed" != "$expected" ]; then
    echo "icrc3 delta: unexpected changes in $dir:" >&2
    diff -rq "$before" "$dir" >&2 || true
    return 1
  fi
  # ...and nothing tracked outside it.
  local outside
  outside="$(git status --porcelain --untracked-files=all | grep -v -F " ${dir#./}/" || true)"
  if [ -n "$outside" ]; then
    echo "icrc3 delta: files outside $dir changed:" >&2
    echo "$outside" >&2
    return 1
  fi
  echo "icrc3 delta: $dir patched 0.4.3 -> 0.4.4 (4 files, now identical to HEAD's vendor/icrc3-mo)"
}

git worktree add --detach "$TMP/src" "$BASELINE_REF" >/dev/null
(
  cd "$TMP/src"
  "$MOPS2" install >/dev/null
  MOC="$("$MOPS2" toolchain bin moc)"
  ICRC3_SRC="$("$MOPS2" sources | awk '$1 == "--package" && $2 == "icrc3-mo" { print $3 }')"
  if [ -z "$ICRC3_SRC" ]; then
    echo "icrc3 delta: baseline $BASELINE_REF does not resolve icrc3-mo" >&2
    exit 1
  fi
  if [ "$CLI_KIND" = mops2 ]; then
    patch_icrc3_to_044 "$(dirname "$ICRC3_SRC")"
  fi
  SOURCES="$("$MOPS2" sources | tr '\n' ' ') $ICRC3_EXTRA_SOURCES"
  echo "baseline $BASELINE_REF ($(git rev-parse --short HEAD)), moc $("$MOC" --version)"
  # shellcheck disable=SC2086
  "$MOC" $SOURCES -v --incremental-gc -o "$TMP/$NAME.wasm" "$MAIN" >/dev/null
)

out_dir=".dfx/local/canisters/$NAME"
mkdir -p "$out_dir"
gzip -9 -c "$TMP/$NAME.wasm" > "$out_dir/$NAME.wasm.gz"
ls -la "$out_dir/$NAME.wasm.gz"
