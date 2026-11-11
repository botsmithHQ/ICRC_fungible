#!/usr/bin/env bash
#
# Build the ICRC-85 counterproof wasms: the CURRENT src/Token.mo and
# src/token-mixin.mo with every ICRC-85 kill switch flipped from `?true` to
# `?false` (sharing ON). Nothing else differs from the shipped build, so a test
# that goes red against them is red because ICRC-85 is on.
#
# The flip happens in a throwaway copy of src/ under mktemp; no file of the
# repository is written except the output wasms:
#   .dfx/local/canisters/token_icrc85_on/token_icrc85_on.wasm.gz
#   .dfx/local/canisters/token_mixin_icrc85_on/token_mixin_icrc85_on.wasm.gz
#
# The number of switches is pinned per file. If a source change adds, removes
# or renames a switch, the build stops here instead of producing a wasm that
# is half on (whose counterproof would prove less than it says).
#
# Used by pic/icrc85-counterproof.sh (and the `icrc85-counterproof` CI job).
# Usage: bash pic/build-icrc85-on-wasm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# name:main:switches — switches = `kill_switch = ?true` + `icrc85KillSwitch = ?true`
TARGETS=(
  "token_icrc85_on:Token.mo:5"
  "token_mixin_icrc85_on:token-mixin.mo:4"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MOC="$(mops toolchain bin moc)"
echo "moc: $MOC ($("$MOC" --version))"
SOURCES="$(mops sources | tr '\n' ' ')"

PATTERN='(kill_switch|icrc85KillSwitch) = \?true'

for entry in "${TARGETS[@]}"; do
  IFS=: read -r name main expected <<<"$entry"
  work="$TMP/$name"
  cp -R src "$work"

  found="$(grep -c -E "$PATTERN" "$work/$main" || true)"
  if [ "$found" != "$expected" ]; then
    echo "src/$main has $found ICRC-85 kill switches set to ?true, expected $expected:" >&2
    grep -n -E "$PATTERN" "src/$main" >&2 || true
    echo "Update TARGETS in pic/build-icrc85-on-wasm.sh after checking every switch." >&2
    exit 1
  fi
  sed -E -i.bak "s/$PATTERN/\1 = ?false/g" "$work/$main"
  rm -f "$work/$main.bak"
  if grep -q -E "$PATTERN" "$work/$main"; then
    echo "$main: a kill switch is still ?true after the flip" >&2
    exit 1
  fi
  echo "$name: src/$main with $expected kill switches ?true -> ?false:"
  diff "src/$main" "$work/$main" | grep '^>' || true

  out_dir=".dfx/local/canisters/$name"
  mkdir -p "$out_dir"
  # Same flags as pic/build-token-wasm.sh (and dfx.json).
  # shellcheck disable=SC2086
  "$MOC" $SOURCES -v --incremental-gc -o "$out_dir/$name.wasm" "$work/$main" >/dev/null
  gzip -9 -f "$out_dir/$name.wasm"
  ls -la "$out_dir/$name.wasm.gz"
done
