#!/usr/bin/env bash
#
# ICRC-85 counterproof. ICRC-85 is off in this fork, and the "off" guards of
# the pic suite say so. This script checks that those guards can tell: it runs
# them against ledgers that are the current sources with every ICRC-85 kill
# switch flipped ON (pic/build-icrc85-on-wasm.sh), and passes only if each
# guard goes red on its own ICRC-85 assertion (pic/icrc85-counterproof-check.mjs).
#
# Exit 0: every guard red as it must be. Exit 1: a guard passed against a
# sharing ledger, failed for another reason, or is missing.
#
# Needs the wasms of `bash pic/build-token-wasm.sh` (positive controls and
# baselines) and `bash pic/build-index-wasm.sh`, and `npm ci` in pic/.
# Usage: bash pic/icrc85-counterproof.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANISTERS="$ROOT/.dfx/local/canisters"

bash "$ROOT/pic/build-icrc85-on-wasm.sh"

REPORT="$(mktemp -d)/icrc85-counterproof.json"
cd "$ROOT/pic"
set +e
TOKEN_WASM="$CANISTERS/token_icrc85_on/token_icrc85_on.wasm.gz" \
TOKEN_MIXIN_WASM="$CANISTERS/token_mixin_icrc85_on/token_mixin_icrc85_on.wasm.gz" \
  npx vitest run icrc85_off.test.ts icrc85_off_mixin.test.ts timertool_upgrade.test.ts \
    --reporter=default --reporter=json --outputFile.json="$REPORT"
vitest_rc=$?
set -e
echo "vitest exit code: $vitest_rc (non-zero is expected: the guards must fail)"

if [ ! -s "$REPORT" ]; then
  echo "::error::vitest wrote no report ($REPORT): the suite did not run" >&2
  exit 1
fi
node "$ROOT/pic/icrc85-counterproof-check.mjs" "$REPORT"
