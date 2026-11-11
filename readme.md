# ICRC-1, ICRC-2, ICRC-3, ICRC-4, ICRC-10, ICRC-21, ICRC-106, ICRC-107 Compatible Fungible Token

## Overview
This project is focused on the development and implementation of a fungible token standard, utilizing blockchain or distributed ledger technology. The core of the project is written in Motoko and is compatibility with the DFINITY Internet Computer platform.

## Contents
- `dfx.json`: Configuration file for project settings and canister definitions.
- `mops.toml`: Dependency management file listing various Motoko libraries and tools.
- `runners/test_deploy.sh`: Script for testing or deploying the token system.
- `runners/prod_deploy.sh`: Script for deploying to production token system.
- `src/Token.mo`: Source code for the token system written in Motoko.

## Setup and Installation
1. **Environment Setup**: Ensure you have an environment that supports Motoko programming. This typically involves setting up the [DFINITY Internet Computer SDK](https://internetcomputer.org/docs/current/references/cli-reference/dfx-parent) and [mops tool chain](https://docs.mops.one/quick-start).
2. **Dependency Installation**: Install the dependencies listed in `mops.toml`. `mops install`.
3. **Configuration**: Adjust `dfx.json` and `mops.toml` according to your project's specific needs, such as changing canister settings or updating dependency versions.

## Usage
- **Development**: Modify and enhance `src/Token.mo` as per your requirements. This file contains the logic and structure of the fungible token system.
- **Testing and Deployment**: Use `runners/test_deploy.sh` for deploying the token system to a test or development environment. This script may need modifications to fit your deployment process.
- **Production Deployment**: Use `runners/prod_deploy.sh` for deploying the token system to a main net environment. This script will need modifications to fit your deployment process.

## Deployer checklist
The ledger refuses some mistakes; others are left to the deployer. Before relying on a ledger:
- **Install with an authenticated identity.** The installer is the first owner and a controller; the anonymous principal is refused.
- **Give the minting account an owner nobody can sign for** (the ledger's own principal) before `admin_lock_supply`. A transfer from the minting account is a mint, locked or not. The anonymous principal is refused as its owner.
- **Never set the fee collector or an initial balance to an account owned by the anonymous principal.** The `fee_collector` init arg, a `FeeCollector` request to `admin_update_icrc1`, `icrc107_set_fee_collector` and `existing_balances` accept one, and anybody can spend what it holds. Check `icrc107_get_fee_collector` after every change.
- **Choose the decimals at install.** They never change afterwards: `admin_update_icrc1` refuses a `Decimals` request.
- **`admin_lock_supply` is irreversible** in this code: `mint` is refused after it, the owner included. The ICRC transfer paths from the minting account still mint unless nobody can sign for it (see above), within `max_supply` when one is set.

See `CHANGELOG.md` for what each of these checks covers and what it does not.

## Dependencies
- DFX and Mops
- Additional dependencies are listed in `mops.toml`. Ensure they are properly installed and configured.

## Contribution and Development Guidelines
- **Coding Standards**: Adhere to established Motoko coding practices. Ensure readability and maintainability of the code.
- **Testing**: Thoroughly test any new features or changes in a controlled environment before integrating them into the main project.
- **Documentation**: Update documentation and comments within the code to reflect changes or additions to the project.

## Testing

### CI

`.github/workflows/ci.yml` runs on every pull request, on pushes to `main` and on demand, with two jobs:

- **`pic`**: the whole PocketIC suite of `pic/` (`npm test`), after building every wasm it loads
  (`bash pic/build-token-wasm.sh`, baselines from git history included, and `bash pic/build-index-wasm.sh`,
  which clones `index.mo` as a sibling checkout at a pinned commit).
- **`icrc85-counterproof`**: ICRC-85 is off in this fork, and the "off" guards of `pic/` say so. This job
  checks that they can tell. `pic/build-icrc85-on-wasm.sh` builds the current `src/Token.mo` and
  `src/token-mixin.mo` with every ICRC-85 kill switch flipped from `?true` to `?false` (in a throwaway copy,
  nothing else changed), and `pic/icrc85-counterproof.sh` runs the guards against those builds. The job is
  **green only when every guard is red on its own ICRC-85 assertion** (a stream that "sent cycles", or a
  collector stream from the ledger). In its log, `RED as expected` lines are the good outcome; a guard that
  passes against the sharing build, fails for another reason (a missing wasm, a trap in setup) or was renamed
  fails the job (`pic/icrc85-counterproof-check.mjs` holds the list).

Locally, the `mops` first on `PATH` has to be the CLI that wrote `mops.lock` (3.6.0, `MOPS_CLI_VERSION` in
`ci.yml`; the build scripts call `mops`, so an alias does not reach them), and `MOPS2` the path of a 2.x CLI
(`MOPS2_CLI_VERSION`): index.mo and the baseline refs keep locks written by 2.13.1, and the build scripts install
those with it (`vendor/README.md`, last section):
`mops install && (cd pic && npm ci) && bash pic/build-token-wasm.sh && bash pic/build-index-wasm.sh`, then
`(cd pic && npm test)` and `bash pic/icrc85-counterproof.sh`.

### Running devefi_ledger_tests (PocketIC Integration Tests)

The [devefi_ledger_tests](https://github.com/Neutrinomic/devefi_ledger_tests) suite provides comprehensive PocketIC-based integration tests for ICRC ledgers. These tests validate real canister behavior including transfers, burns, mints, transaction windows, and more.

**Setup:**

```bash
# Clone the test repository
git clone https://github.com/Neutrinomic/devefi_ledger_tests.git /tmp/devefi_ledger_tests
cd /tmp/devefi_ledger_tests

# Install dependencies
npm install

# Build the Motoko ledger WASM (from ICRC_fungible directory)
cd /path/to/ICRC_fungible
dfx build token --check
cp .dfx/local/canisters/token/token.wasm /tmp/devefi_ledger_tests/icrc_ledger/motoko_ledger.wasm
```

**Running Tests:**

```bash
cd /tmp/devefi_ledger_tests

# Run all applicable tests
LEDGER=motoko LEDGER_TYPE=icrc npx jest --testPathIgnorePatterns="ntc.spec.ts|fastscan.spec.ts"

# Run specific test file
LEDGER=motoko LEDGER_TYPE=icrc npx jest ledger.spec.ts

# Run with verbose output
LEDGER=motoko LEDGER_TYPE=icrc npx jest --verbose
```

**Test Suites:**

| Test File | Description | Status |
|-----------|-------------|--------|
| `ledger.spec.ts` | Core ledger operations, metadata | ✅ |
| `basic.spec.ts` | Basic transfer scenarios | ✅ |
| `mint.spec.ts` | Minting operations | ✅ |
| `burn.spec.ts` | Burn operations | ✅ |
| `tx_window.spec.ts` | Transaction window/deduplication | ✅ |
| `noise.spec.ts` | Stress testing | ✅ |
| `dust.spec.ts` | Small amount handling | ✅ |
| `on_sent.spec.ts` | Send callbacks | ✅ |
| `passback.spec.ts` | Passback scenarios | ✅ |
| `legacy_address.spec.ts` | Legacy address format | ✅ |
| `ledger_down.spec.ts` | Ledger unavailability handling | ✅ |

**Skipped Tests (Not Applicable):**

| Test File | Reason |
|-----------|--------|
| `ntc.spec.ts` | Tests NTC minter canister (not a ledger test) - requires minter-specific methods like `get_queue`, `get_dropped`, `stats` |
| `fastscan.spec.ts` | Tests DFINITY Rust ledger-specific upgrade/reinstall features with fastscan WASM |

**Expected Results:** 205+ tests passing across 11 test files.

### DFINITY Index-ng Integration

See `/test/integration/` for index-ng canister integration tests that verify block sync and transaction indexing.

## ICRC-85 Open Value Sharing (OVS) Roll-Up

> **`src/Token.mo` ships with every stream below switched OFF.** The ledger and
> its archives send no cycles for ICRC-85. Each stream is stopped through the
> field its library reads (see the comments in `src/Token.mo`): the icrc1
> environment's `icrc85.advanced.kill_switch` (its top-level `kill_switch` is
> read by nothing), the icrc3 environment's `icrc85.advanced.kill_switch`
> (which each new archive also takes), and the TimerTool environment's
> `advanced.icrc85.kill_switch`. `pic/icrc85_off.test.ts` pins it, and
> `pic/TokenWithICRC85.mo` shows a token with sharing on.

This token deploys multiple components that each can participate in [ICRC-85 Open Value Sharing](https://github.com/dfinity/ICRC/issues/85) via the [ovs-fixed](https://mops.one/ovs-fixed) library. Each component independently shares a portion of cycles with infrastructure providers based on its usage. Below is the complete roll-up of OVS namespaces a token canister and its archives run when sharing is on.

### Ledger Canister

| Component | Namespace | Actions Tracked | Cycle Formula | Period Reset |
|-----------|-----------|-----------------|---------------|--------------|
| **timer-tool** | `org.icdevs.icrc85.supertimer` | Timer actions scheduled | 1 XDR base + 1 XDR per 100K actions, max 100 XDR | Yes (delta since last report) |
| **ICRC-1** | `org.icdevs.icrc85.icrc1` | Successful transfers, mints, burns | 1 XDR base + 100M cycles per action, max 100 XDR | Yes |
| **ICRC-3** | `org.icdevs.icrc85.icrc3` | Ledger records added | 1 XDR base + 100M cycles per action, max 100 XDR | Yes |

### Archive Canisters (per archive instance)

| Component | Namespace | Actions Tracked | Cycle Formula | Period Reset |
|-----------|-----------|-----------------|---------------|--------------|
| **timer-tool** | `org.icdevs.icrc85.supertimer` | Timer actions scheduled | 1 XDR base + 1 XDR per 100K actions, max 100 XDR | Yes (delta since last report) |
| **ICRC-3 Archive** | `org.icdevs.icrc85.icrc3archive` | Records stored (cumulative) | 1 XDR base + 1M cycles per record, max 100 XDR | **No** — storage-based, accumulates |

### Notes

- **1 XDR ≈ 1 trillion cycles** (1,000,000,000,000).
- All OVS payments are capped at 50% of the canister's current cycle balance for safety.
- Each component has a **7-day grace period** before the first share, then shares every **30 days**.
- The ICRC-3 Archive uses `resetAtEndOfPeriod = false` because its value is proportional to total records stored, not throughput.

## Repository
- [Project Repository](https://github.com/icdevsorg/ICRC_fungible)

## License
- MIT License

## Contact
- **Contributing**: For contributing to this project, please submit a pull request to the repository.
