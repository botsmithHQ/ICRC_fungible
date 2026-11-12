#!/usr/bin/env bash
#
# Build the wasms the pic/*.test.ts suite loads from .dfx/local/canisters/,
# WITHOUT a replica.
#
# `dfx build <canister>` refuses to run until the canister has an id, which
# means a running replica. This script goes straight to the pinned moc with the
# sources mops resolves — so whatever `mops sources` points at (including the
# local fork in vendor/) is what actually gets compiled — and gzips the result
# into the paths the tests expect.
#
# Usage: bash pic/build-token-wasm.sh [canister ...]     (default: all of them)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# name:main — must match dfx.json
ALL=(
  "token:src/Token.mo"
  "token-mixin:src/token-mixin.mo"
  "token_icrc85:pic/TokenWithICRC85.mo"
  "dummy_collector:pic/DummyCollector.mo"
  "raw_caller:pic/RawCaller.mo"
  "interleave_caller:pic/InterleaveCaller.mo"
  # Not in dfx.json: fixtures of pic/archive_upgrade_results.test.ts, the
  # release-in-`finally` pattern of `upgradeArchive` with a callback that
  # traps, and a caller that sends `upgradeArchive` twice at once.
  "finally_probe:pic/FinallyProbe.mo"
  "twice_caller:pic/TwiceCaller.mo"
  # Not in dfx.json: the ledger BEFORE ICRC-85 was switched off, built from git
  # history by pic/build-baseline-wasm.sh (the positive controls and upgrade
  # tests of pic/icrc85_off.test.ts need it).
  "token_baseline:@baseline"
  # The ledger BEFORE the two-step owner hand-off, for the upgrade test of
  # pic/owner_handoff.test.ts. Built the same way, from its own commit.
  "token_one_step:@baseline bb166f8 token_one_step"
  "token_pre_lock:@baseline f3d042e token_pre_lock"
  "token_mixin_pre_lock:@baseline f3d042e token_mixin_pre_lock src/token-mixin.mo"
  # The ledger BEFORE it checked the archive controller limit at install, so a
  # test can hold a ledger past the limit (pic/archive_upgrade_results.test.ts).
  "token_pre_limit:@baseline f3d042e token_pre_limit"
  # The ledger BEFORE it refused the anonymous principal at install: the only
  # way left to a ledger whose owner is anonymous, which the tests of the owner
  # guards need (pic/owner_anon_guard.test.ts, pic/supply_lock.test.ts,
  # pic/install_refusal.test.ts).
  "token_pre_refusal:@baseline 5ff1d78 token_pre_refusal"
  "token_mixin_pre_refusal:@baseline 5ff1d78 token_mixin_pre_refusal src/token-mixin.mo"
  # The ledger BEFORE the ICRC-106 index principal was stored as #Text: its
  # setter stored #Blob, so the metadata of a ledger set by it holds a #Blob
  # that only get_icrc106_index_principal's #Blob case still reads
  # (pic/icrc106_blob_upgrade.test.ts). d894507 already has the 3.x lock and
  # icrc3-mo 0.4.4: built with the repo's mops (4th word), no icrc3 patch.
  "token_pre_text106:@baseline d894507 token_pre_text106 src/Token.mo mops"
)

MOC="$(mops toolchain bin moc)"
echo "moc: $MOC ($("$MOC" --version))"
echo "icrc1-mo source: $(mops sources | grep '^--package icrc1-mo ' || echo 'NOT RESOLVED')"
SOURCES="$(mops sources | tr '\n' ' ')"

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  for entry in "${ALL[@]}"; do targets+=("${entry%%:*}"); done
fi

for name in "${targets[@]}"; do
  main=""
  for entry in "${ALL[@]}"; do
    [ "${entry%%:*}" = "$name" ] && main="${entry#*:}"
  done
  if [ -z "$main" ]; then
    echo "unknown canister: $name" >&2
    exit 1
  fi

  if [ "${main%% *}" = "@baseline" ]; then
    # shellcheck disable=SC2086
    bash "$ROOT/pic/build-baseline-wasm.sh" ${main#@baseline}
    continue
  fi

  out_dir=".dfx/local/canisters/$name"
  mkdir -p "$out_dir"
  echo "building $name from $main"
  # Same flags as dfx.json.
  # shellcheck disable=SC2086
  "$MOC" $SOURCES -v --incremental-gc -o "$out_dir/$name.wasm" "$main" >/dev/null
  gzip -9 -f "$out_dir/$name.wasm"
  ls -la "$out_dir/$name.wasm.gz"
done
