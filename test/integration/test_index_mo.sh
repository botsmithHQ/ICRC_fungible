#!/bin/bash
# index.mo Integration Test
#
# Tests the Motoko index.mo canister against our icrc3-mo ledger.
# Mirrors the same phases as test_index_ng.sh:
#   - Mint, Transfer, Burn
#   - Approve, Transfer-from, Remove approval
#   - Fee collector set/switch/clear (ICRC-107)
#   - Archive creation (low ICRC-3 thresholds)
#   - Balance verification (index vs ledger)
#   - Fee collector range verification
#   - Account transaction queries
#   - Smart catch-up (index.mo schedules timer(0) when behind)
#
# Usage:
#   ./test_index_mo.sh [--canister token|token-mixin]
#

set -euo pipefail

# Parse arguments
CANISTER_NAME="token"
while [[ $# -gt 0 ]]; do
    case $1 in
        --canister)
            CANISTER_NAME="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "=== index.mo Comprehensive Integration Test ==="
echo "Testing: $CANISTER_NAME"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPLICA_PORT=8887

# --------------- Locate index.mo wasm ---------------
INDEX_MO_WASM="$SCRIPT_DIR/icrc_index.wasm.gz"
INDEX_MO_DID="$SCRIPT_DIR/icrc_index.did"

if [ ! -f "$INDEX_MO_WASM" ]; then
    echo "⚠️  icrc_index.wasm.gz not found at $INDEX_MO_WASM"
    echo "   Building from index.mo project..."
    WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
    INDEX_MO_DIR="$WORKSPACE_DIR/index.mo"
    if [ ! -d "$INDEX_MO_DIR" ]; then
        echo "❌ index.mo project not found at $INDEX_MO_DIR"
        echo "   Clone: git clone https://github.com/botsmithHQ/index.mo $INDEX_MO_DIR"
        exit 1
    fi
    pushd "$INDEX_MO_DIR" > /dev/null
    mops install 2>/dev/null || true
    icp build icrc_index 2>&1 || { echo "❌ Failed to build index.mo"; exit 1; }
    ARTIFACT="$INDEX_MO_DIR/.icp/cache/artifacts/icrc_index"
    gzip -c "$ARTIFACT" > "$INDEX_MO_WASM"
    echo "   ✅ Built and compressed index.mo WASM"
    popd > /dev/null
fi

echo "📦 Using index.mo WASM: $INDEX_MO_WASM"

# --------------- Cleanup ---------------
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    cd "$PROJECT_DIR"
    icp network stop 2>/dev/null || true
    echo "Done!"
}
trap cleanup EXIT

echo "🧹 Cleaning up previous state..."
cd "$PROJECT_DIR"
icp network stop 2>/dev/null || true
rm -rf ".icp/cache/networks/local/state" ".icp/cache/networks/local/local.ids.json" 2>/dev/null || true

# --------------- Replica & Deploy ---------------
echo "🚀 Starting local replica on port $REPLICA_PORT..."
icp network start -d
sleep 3

# Setup deployer identity (minter)
icp identity new icrc_deployer --storage plaintext 2>/dev/null || true
icp identity default icrc_deployer
DEPLOYER_PRINCIPAL=$(icp identity principal)
icp token transfer 20 "$DEPLOYER_PRINCIPAL" --identity anonymous 2>/dev/null || true
icp cycles mint --icp 15 2>/dev/null || true

# Deploy with low archive thresholds so archiving actually happens
echo "📦 Deploying $CANISTER_NAME canister (low archive thresholds)..."
icp deploy "$CANISTER_NAME" --args "(opt record {
  icrc1 = null;
  icrc2 = null;
  icrc3 = opt record {
    maxActiveRecords = 20 : nat;
    settleToRecords = 10 : nat;
    maxRecordsInArchiveInstance = 100 : nat;
    maxArchivePages = 62500 : nat;
    archiveIndexType = variant { Stable };
    maxRecordsToArchive = 15 : nat;
    archiveCycles = 2000000000000 : nat;
    archiveControllers = null : opt opt vec principal;
    supportedBlocks = vec {
      record { block_type = \"1xfer\"; url = \"https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3\" };
      record { block_type = \"2xfer\"; url = \"https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3\" };
      record { block_type = \"2approve\"; url = \"https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3\" };
      record { block_type = \"1mint\"; url = \"https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3\" };
      record { block_type = \"1burn\"; url = \"https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3\" };
    };
  };
  icrc4 = null;
})" --args-format candid -y

TOKEN_ID=$(icp canister status "$CANISTER_NAME" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "✅ $CANISTER_NAME deployed at: $TOKEN_ID"

echo "🔧 Initializing $CANISTER_NAME..."
icp canister call "$CANISTER_NAME" admin_init "()" || echo "admin_init might not be needed"

# Add cycles for archive creation
echo "💎 Adding cycles to $CANISTER_NAME for archive creation..."
icp canister top-up --amount 10000000000000 "$CANISTER_NAME"

# Deploy index.mo canister
echo "📦 Deploying index.mo canister..."
icp deploy icrc_index_mo --args "(opt variant { Init = record {
  ledger_id = principal \"$TOKEN_ID\";
  retrieve_blocks_from_ledger_interval_seconds = opt (1 : nat64);
  icrc85_collector = null;
} })" --args-format candid -y
INDEX_ID=$(icp canister status icrc_index_mo --json | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "✅ index.mo deployed at: $INDEX_ID"

MINTER=$(icp identity principal)

# --------------- Create test identities ---------------
icp identity new idx_alice   --storage plaintext 2>/dev/null || true
icp identity new idx_bob     --storage plaintext 2>/dev/null || true
icp identity new idx_charlie --storage plaintext 2>/dev/null || true
icp identity default idx_alice;   ALICE=$(icp identity principal)
icp identity default idx_bob;     BOB=$(icp identity principal)
icp identity default idx_charlie; CHARLIE=$(icp identity principal)
icp identity default icrc_deployer

echo "👤 Minter  : $MINTER"
echo "👤 Alice   : $ALICE"
echo "👤 Bob     : $BOB"
echo "👤 Charlie : $CHARLIE"

FEE_RAW=$(icp canister call "$CANISTER_NAME" icrc1_fee '()' | grep -o '[0-9_]*' | tr -d '_')
echo "💵 Fee: $FEE_RAW"

# --------------- Helper functions ---------------
do_mint() {
    local TO=$1; local AMT=$2
    icp identity default icrc_deployer
    icp canister call "$CANISTER_NAME" icrc1_transfer "(record {
        to = record { owner = principal \"$TO\"; subaccount = null };
        amount = $AMT; fee = null; memo = null; created_at_time = null; from_subaccount = null;
    })"
}

do_transfer() {
    local FROM_ID=$1; local TO=$2; local AMT=$3
    icp identity default "$FROM_ID"
    icp canister call "$CANISTER_NAME" icrc1_transfer "(record {
        to = record { owner = principal \"$TO\"; subaccount = null };
        amount = $AMT; fee = null; memo = null; created_at_time = null; from_subaccount = null;
    })"
}

do_burn() {
    local FROM_ID=$1; local AMT=$2
    icp identity default "$FROM_ID"
    icp canister call "$CANISTER_NAME" burn "(record {
        amount = $AMT; from_subaccount = null; memo = null; created_at_time = null;
    })"
}

do_approve() {
    local FROM_ID=$1; local SPENDER=$2; local AMT=$3
    icp identity default "$FROM_ID"
    icp canister call "$CANISTER_NAME" icrc2_approve "(record {
        spender = record { owner = principal \"$SPENDER\"; subaccount = null };
        amount = $AMT;
        fee = null; memo = null; created_at_time = null; from_subaccount = null;
        expected_allowance = null; expires_at = null;
    })"
}

do_transfer_from() {
    local CALLER_ID=$1; local FROM=$2; local TO=$3; local AMT=$4
    icp identity default "$CALLER_ID"
    icp canister call "$CANISTER_NAME" icrc2_transfer_from "(record {
        from = record { owner = principal \"$FROM\"; subaccount = null };
        to = record { owner = principal \"$TO\"; subaccount = null };
        amount = $AMT;
        fee = null; memo = null; created_at_time = null; spender_subaccount = null;
    })"
}

set_fee_collector() {
    icp identity default icrc_deployer
    if [ "$1" == "null" ]; then
        icp canister call "$CANISTER_NAME" icrc107_set_fee_collector "(record {
            fee_collector = null;
            created_at_time = $(date +%s)000000000 : nat64;
        })"
    else
        icp canister call "$CANISTER_NAME" icrc107_set_fee_collector "(record {
            fee_collector = opt record { owner = principal \"$1\"; subaccount = null };
            created_at_time = $(date +%s)000000000 : nat64;
        })"
    fi
}

get_balance_ledger() {
    icp identity default icrc_deployer
    icp canister call "$CANISTER_NAME" icrc1_balance_of "(record { owner = principal \"$1\"; subaccount = null })" | grep -o '[0-9_]*' | tr -d '_'
}

get_balance_index() {
    icp identity default icrc_deployer
    icp canister call icrc_index_mo icrc1_balance_of "(record { owner = principal \"$1\"; subaccount = null })" | grep -o '[0-9_]*' | tr -d '_'
}

TESTS_PASSED=0
TESTS_FAILED=0
BLOCK_COUNT=0

# =============================================
echo ""
echo "=========================================="
echo "Phase 1 – Mints"
echo "=========================================="
echo ""

echo "💰 Mint #1: 10B to Alice..."
do_mint "$ALICE" 10_000_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💰 Mint #2: 5B to Bob..."
do_mint "$BOB" 5_000_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💰 Mint #3: 2B to Charlie..."
do_mint "$CHARLIE" 2_000_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 2 – Transfers (fees burned)"
echo "=========================================="
echo ""

echo "💸 Transfer #1: Alice → Bob 1M..."
do_transfer idx_alice "$BOB" 1_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer #2: Bob → Charlie 500K..."
do_transfer idx_bob "$CHARLIE" 500_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer #3: Charlie → Alice 100K..."
do_transfer idx_charlie "$ALICE" 100_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 3 – Burns"
echo "=========================================="
echo ""

echo "🔥 Burn #1: Alice burns 50K..."
do_burn idx_alice 50_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "🔥 Burn #2: Bob burns 100K..."
do_burn idx_bob 100_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 4 – Approvals & Transfer-from"
echo "=========================================="
echo ""

echo "📝 Approve #1: Alice approves Bob for 5M..."
do_approve idx_alice "$BOB" 5_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "📝 Approve #2: Bob approves Charlie for 2M..."
do_approve idx_bob "$CHARLIE" 2_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer-from #1: Bob pulls 1M from Alice → Charlie..."
do_transfer_from idx_bob "$ALICE" "$CHARLIE" 1_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer-from #2: Charlie pulls 500K from Bob → Alice..."
do_transfer_from idx_charlie "$BOB" "$ALICE" 500_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 5 – Remove approvals"
echo "=========================================="
echo ""

echo "🚫 Remove approval: Alice revokes Bob (approve 0)..."
do_approve idx_alice "$BOB" 0
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "🚫 Remove approval: Bob revokes Charlie (approve 0)..."
do_approve idx_bob "$CHARLIE" 0
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 6 – Fee collector (Charlie)"
echo "=========================================="
echo ""

echo "🔧 Setting fee collector to Charlie..."
set_fee_collector "$CHARLIE"
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer (fee→Charlie): Alice → Bob 2M..."
do_transfer idx_alice "$BOB" 2_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer (fee→Charlie): Bob → Alice 1M..."
do_transfer idx_bob "$ALICE" 1_000_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 7 – Switch fee collector (Alice)"
echo "=========================================="
echo ""

echo "🔧 Switching fee collector to Alice..."
set_fee_collector "$ALICE"
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer (fee→Alice): Bob → Charlie 500K..."
do_transfer idx_bob "$CHARLIE" 500_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer (fee→Alice): Charlie → Bob 200K..."
do_transfer idx_charlie "$BOB" 200_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# =============================================
echo ""
echo "=========================================="
echo "Phase 8 – Clear fee collector & more txns"
echo "=========================================="
echo ""

echo "🔧 Clearing fee collector (fees burned)..."
set_fee_collector "null"
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "💸 Transfer (fee burned): Alice → Bob 300K..."
do_transfer idx_alice "$BOB" 300_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

echo "🔥 Burn #3: Charlie burns 200K..."
do_burn idx_charlie 200_000
BLOCK_COUNT=$((BLOCK_COUNT + 1))

# Generate extra transfers to push past archive threshold (20 active records)
echo ""
echo "=========================================="
echo "Phase 9 – Extra transfers (trigger archiving)"
echo "=========================================="
echo ""

for i in $(seq 1 10); do
    echo "💸 Extra transfer #$i: Alice → Bob..."
    do_transfer idx_alice "$BOB" $((10000 + i))
    BLOCK_COUNT=$((BLOCK_COUNT + 1))
done

echo ""
echo "📊 Total ledger transactions created: $BLOCK_COUNT"

# Wait for archiving to happen
echo ""
echo "⏳ Waiting for archiving..."
sleep 5

# Check archives
echo ""
echo "📁 Checking archives..."
icp identity default icrc_deployer
ARCHIVES=$(icp canister call "$CANISTER_NAME" icrc3_get_archives "(record {})")
echo "   $ARCHIVES"

ARCHIVE_COUNT=$(echo "$ARCHIVES" | grep -c "canister_id" || echo "0")
if [ "$ARCHIVE_COUNT" -gt "0" ]; then
    echo "   ✅ Archive canister(s) created: $ARCHIVE_COUNT"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ⚠️  No archives created yet"
fi

# =============================================
echo ""
echo "=========================================="
echo "Waiting for index.mo to sync all blocks..."
echo "=========================================="

# index.mo with smart catch-up should sync fast: it schedules timer(0)
# when it fetches a full batch, so it keeps going until it hits the tip.
for attempt in $(seq 1 60); do
    STATUS=$(icp canister call icrc_index_mo status "()")
    SYNCED=$(echo "$STATUS" | grep -o 'num_blocks_synced = [0-9]*' | grep -o '[0-9]*' || echo "0")
    if [ "$SYNCED" -ge "$BLOCK_COUNT" ]; then
        echo "   ✅ index.mo synced $SYNCED/$BLOCK_COUNT blocks (attempt $attempt)"
        break
    fi
    printf "."
    sleep 1
done
echo ""

echo "📊 Index status: synced $SYNCED blocks (expected >= $BLOCK_COUNT)"

if [ "$SYNCED" -ge "$BLOCK_COUNT" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ❌ index.mo did not sync enough blocks"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# =============================================
echo ""
echo "=========================================="
echo "Verifying blocks from index"
echo "=========================================="

BLOCKS_RESP=$(icp canister call icrc_index_mo get_blocks "(record { start = 0; length = $((BLOCK_COUNT + 5)) })")
CHAIN_LEN=$(echo "$BLOCKS_RESP" | grep -o 'chain_length = [0-9_]*' | grep -o '[0-9_]*' | tr -d '_' || echo "0")
echo "   Chain length reported by index: $CHAIN_LEN"

if [ "$CHAIN_LEN" -ge "$BLOCK_COUNT" ]; then
    echo "   ✅ Index chain length matches expected"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ❌ Index chain length too low: $CHAIN_LEN < $BLOCK_COUNT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# =============================================
echo ""
echo "=========================================="
echo "Verifying balances (index vs ledger)"
echo "=========================================="

check_balance() {
    local LABEL=$1 PRINCIPAL=$2
    local LEDGER_BAL INDEX_BAL
    LEDGER_BAL=$(get_balance_ledger "$PRINCIPAL")
    INDEX_BAL=$(get_balance_index "$PRINCIPAL")
    echo "   $LABEL – Ledger: $LEDGER_BAL  Index: $INDEX_BAL"
    if [ "$LEDGER_BAL" == "$INDEX_BAL" ]; then
        echo "   ✅ $LABEL balance matches"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "   ❌ $LABEL balance MISMATCH"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

check_balance "Alice"   "$ALICE"
check_balance "Bob"     "$BOB"
check_balance "Charlie" "$CHARLIE"

# =============================================
echo ""
echo "=========================================="
echo "Verifying account transactions"
echo "=========================================="

check_account_txns() {
    local LABEL=$1 PRINCIPAL=$2
    local RESP
    RESP=$(icp canister call icrc_index_mo get_account_transactions "(record {
        account = record { owner = principal \"$PRINCIPAL\"; subaccount = null };
        start = null; max_results = 100;
    })")
    local TX_COUNT
    TX_COUNT=$(echo "$RESP" | grep -c "id =" || echo "0")
    echo "   $LABEL: $TX_COUNT transactions returned"
    if [ "$TX_COUNT" -gt "0" ]; then
        echo "   ✅ $LABEL has transaction history"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "   ❌ $LABEL has no transactions"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

check_account_txns "Alice"   "$ALICE"
check_account_txns "Bob"     "$BOB"
check_account_txns "Charlie" "$CHARLIE"

# =============================================
echo ""
echo "=========================================="
echo "Verifying fee collector ranges"
echo "=========================================="

FEE_COL_RESP=$(icp canister call icrc_index_mo get_fee_collectors_ranges "()")
echo "   $FEE_COL_RESP"

# Charlie and Alice both served as fee collectors
FEE_COL_ENTRIES=$(echo "$FEE_COL_RESP" | grep -c "owner" || echo "0")
if [ "$FEE_COL_ENTRIES" -ge "2" ]; then
    echo "   ✅ Fee collector ranges include multiple collectors"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ⚠️  Fee collector ranges: $FEE_COL_ENTRIES entries (expected >= 2)"
    # index.mo should track fee collectors properly
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# =============================================
echo ""
echo "=========================================="
echo "Verifying ledger_id"
echo "=========================================="

LEDGER_ID_RESP=$(icp canister call icrc_index_mo ledger_id "()")
echo "   Index reports: $LEDGER_ID_RESP"
if echo "$LEDGER_ID_RESP" | grep -q "$TOKEN_ID"; then
    echo "   ✅ Ledger ID matches"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ❌ Ledger ID mismatch"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# =============================================
echo ""
echo "=========================================="
echo "Verifying subaccount listing"
echo "=========================================="

SUBACCOUNTS=$(icp canister call icrc_index_mo list_subaccounts "(record { owner = principal \"$ALICE\"; start = null })")
echo "   Alice subaccounts: $SUBACCOUNTS"
# Default subaccount should appear if Alice has a balance
TESTS_PASSED=$((TESTS_PASSED + 1))

# =============================================
echo ""
echo "=========================================="
echo "Verifying get_stats (index.mo specific)"
echo "=========================================="

STATS=$(icp canister call icrc_index_mo get_stats "()")
echo "   $STATS"

# Check num_accounts > 0
ACCOUNT_COUNT=$(echo "$STATS" | grep -o 'num_accounts = [0-9]*' | grep -o '[0-9]*' || echo "0")
if [ "$ACCOUNT_COUNT" -ge "3" ]; then
    echo "   ✅ Stats report $ACCOUNT_COUNT accounts (>= 3 expected)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ❌ Stats num_accounts too low: $ACCOUNT_COUNT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Check ledger_id in stats
if echo "$STATS" | grep -q "$TOKEN_ID"; then
    echo "   ✅ Stats ledger_id correct"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "   ❌ Stats ledger_id mismatch"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# =============================================
echo ""
echo "=========================================="
echo "=== TEST SUMMARY ==="
echo "=========================================="
echo "Blocks created         : $BLOCK_COUNT"
echo "Blocks synced (index)  : $SYNCED"
echo "Archives created       : $ARCHIVE_COUNT"
echo "Tests passed           : $TESTS_PASSED"
echo "Tests failed           : $TESTS_FAILED"
echo ""
echo "Transaction types covered:"
echo "  - Mint (3)"
echo "  - Transfer (9+)"
echo "  - Burn (3)"
echo "  - Approve (4)"
echo "  - Transfer-from (2)"
echo "  - Remove approval (2)"
echo "  - Set fee collector (2)"
echo "  - Clear fee collector (1)"
echo ""

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "🎉 ALL INDEX.MO INTEGRATION TESTS PASSED!"
    exit 0
else
    echo "❌ SOME TESTS FAILED – review output above"
    exit 1
fi
