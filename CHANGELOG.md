# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **A mint through `icrc2_transfer_from` respects `max_supply`** (`vendor/icrc2-mo`, a local fork
  of icrc2-mo 0.2.1). A transfer_from whose `from` is the minting account is a mint, and upstream
  credited it without checking `max_supply`: the minting account (no approval needed for its own
  transfer_from) or a spender it approved could mint past the cap. An approval by the minting
  account only goes through with a zero fee (`icrc2_approve` charges the approver, and the minting
  account never holds a balance). None of this is reachable when the minting account is the ledger
  itself, since nobody signs for it. It is now refused with the error
  `icrc1_transfer` gives, `GenericError { error_code = 6; message = "Cannot mint more than <n>
  tokens" }`, and nothing changes. Ledgers without a `max_supply` are unaffected.
  `icrc4_transfer_batch` already capped each item. This does not remove tokens minted past the cap
  before the fix, and `admin_lock_supply` still does not block the ICRC paths: it freezes
  `max_supply`, which now caps all three. Known limit, not fixed: once the minted supply is past
  `max_supply`, `icrc1_transfer` and `icrc4_transfer_batch` mints trap on a subtraction instead of
  replying (transfer_from replies `Cannot mint more than 0 tokens`); nothing is minted either way.
- **The ledger refuses to be installed by the anonymous principal** (`src/Token.mo`,
  `src/token-mixin.mo`). The installer is the first owner and the owner of the default minting
  account, and it is a controller. An install or a reinstall sent by the anonymous principal now
  traps (`"The anonymous principal cannot install the ledger"`) and installs nothing.
  **Breaking** for a deployment that installs without an identity, a local one included: install
  with an authenticated identity.
- **The minting account cannot be owned by the anonymous principal.** A transfer from the minting
  account is a mint, so with such an account anyone mints. An install whose init args carry one
  traps (`"The anonymous principal cannot be the owner of the minting account"`), with or without
  a subaccount. So does `admin_update_icrc1` when its batch carries such a `MintingAccount`: the
  whole batch is refused and nothing of it is applied, locked or not. `inspect` in `Token.mo`
  refuses the same batch at ingress.
- **An upgrade of a working ledger is never refused by these checks**, whoever sends it and
  whatever init args it carries: they run where the installer and the init args are applied, at
  install and reinstall. One upgrade does apply its init args, and is checked for the minting
  account: `src/token-mixin.mo` builds its ICRC-1 state on the first use after the install, so an
  upgrade that comes before that (of a ledger installed while stopped, for example) sets the
  minting account from its own args. No stable field is added, so upgrading is a plain upgrade.
- **Every owner method refuses the anonymous caller** (`src/Token.mo`, `src/token-mixin.mo`),
  in its body and, in `Token.mo`, in the ingress filter, whatever `owner` holds. `owner` starts as
  whoever installed the ledger, so a ledger installed by the anonymous principal had an anonymous
  owner, and then any anonymous caller could call `mint`, rewrite the ledger info, set the index
  and the fee collector, and administer the archives. One predicate, `isOwner`, now guards `mint`,
  `admin_update_icrc1/2/4`, `admin_set_index_canister`, `set_icrc106_index_principal`,
  `icrc107_set_fee_collector` (still `#Err(#AccessDenied)`), `upgradeArchive`,
  `update_archive_controllers` and `getUpgradeError`. Nothing changes for a caller that is not
  anonymous.
- A new archive never gets an anonymous owner as a controller (`src/Token.mo`): the archive hook
  contributes nothing when `owner` is the anonymous principal. Before, every archive such a ledger
  created could be administered by anyone through the management canister.
- **None of this repairs a ledger that the anonymous principal installed from an earlier
  release.** Upgrading it keeps the anonymous principal as its owner, as a controller (anyone can
  reinstall or delete it) and as its default minting account (anyone can mint with
  `icrc1_transfer` or `icrc4_transfer_batch` from it). No method gets it out of that state: its
  owner methods refuse the anonymous caller. The way out is for an authenticated controller to
  remove the anonymous principal from the controllers and reinstall, which loses the state. Read
  `get_owner` and `icrc1_minting_account` before relying on a ledger.
- The install check covers `src/Token.mo` and `src/token-mixin.mo`. The test fixture
  `pic/TokenWithICRC85.mo` keeps its own constructor and does not have it.
- **The decimals never change after install** (`src/Token.mo`, `src/token-mixin.mo`). A change of
  decimals redenominates every balance, fee and amount already recorded, in every wallet, index
  and explorer that reads them. `admin_update_icrc1` now traps (`"Decimals cannot change after
  install"`), and applies nothing, when its batch carries a `Decimals` request, whatever its value
  (the current one included) and whether the supply is locked or not. `inspect` in `Token.mo`
  refuses the same batch at ingress. The init args still set the decimals at install and
  reinstall and, in `src/token-mixin.mo`, at an upgrade that comes before the ICRC-1 state is
  built (the same rule as the minting account above): no balance or block exists yet to be read
  with other decimals. A `Metadata` request for `icrc1:decimals` does not change them either: the
  ledger rewrites that entry from its state after every update. **Breaking** for a script that
  re-sends `Decimals` with the rest of the ledger info. The test fixture `pic/TokenWithICRC85.mo`
  does not have this check.
- **Known limit, not changed: the fee collector and the initial balances accept an account owned
  by the anonymous principal.** The `fee_collector` init arg, an `admin_update_icrc1`
  `FeeCollector` request, `icrc107_set_fee_collector` and the `existing_balances` advanced setting
  do not check the account's owner. Anybody signs for the anonymous principal, so anybody can
  spend what such an account holds: every fee collected, or the balance given to it at install.
  The library leaves this to the deployer, who must not set such an account. Read
  `icrc107_get_fee_collector` and the initial balances before relying on a ledger. See the
  deployer checklist in `readme.md`.
- `admin_init` admits the owner or a controller that is not the anonymous principal. In
  `src/token-mixin.mo` it admitted every caller; it now has the same guard as `Token.mo`, which is
  a change for an authenticated stranger calling it (it only marks the ledger initialised).

### Added

- **New query `icrc3_get_stats()`** (`src/Token.mo`), open to anyone, no arguments: the ICRC-3
  archiving state from the icrc3 library's `get_stats()`. `localLedgerSize` (blocks still on the
  ledger), `firstIndex`, `lastIndex`, `bCleaning` (an archiving pass in flight), the archives
  with the range each holds, and the bounds (`maxActiveRecords`, `settleToRecords`,
  `archiveCycles` and the rest). Same method and type as the icrc3 mixin, so `token-mixin.mo`
  already had it. Archiving needs a balance above `2 * archiveCycles`; below it no archive is
  created and `localLedgerSize` stays over `maxActiveRecords`, which a monitor can read here. It
  is a query, answered by one replica: for monitoring, not for a decision that needs certified
  data.
- **A one-way supply lock** (`src/Token.mo`, `src/token-mixin.mo`). `admin_lock_supply()`, by the
  owner and never by the anonymous principal, sets a flag that no method clears. A second call
  changes nothing. From then on:
  - `mint` traps for every caller, the owner included (`"Supply is locked: mint is disabled"`).
  - `admin_update_icrc1` traps, and applies **nothing**, when its batch carries any
    `MintingAccount` or `MaxSupply` request, whatever its value (lowering the cap and re-setting
    the current minting account included). The whole batch is refused because a partial apply
    would answer a vector of `Bool`s that reads like success. Every other setting (name, symbol,
    logo, fee, metadata, memo bound, fee collector and the rest) stays editable.
- New query `is_supply_locked()`, open to anyone.
- `inspect` in `Token.mo` mirrors the lock, as a cycles optimisation: a mint, or a batch that
  touches either setting, is refused at ingress once locked; `admin_lock_supply` is admitted for
  the owner only. The mixin has no ingress filter; its method bodies refuse.
- New stable field `supplyLocked : Bool`, initialised to `false`. Upgrading is a plain upgrade and
  the ledger starts unlocked. Going BACK to a release without the field is refused by the Motoko
  runtime (enhanced orthogonal persistence traps in `post_upgrade` when a stable field disappears):
  measured on a local replica, the ledger stays on the new wasm and stays locked.

### What the supply lock does not do

- **It is irreversible in this code only.** A controller can upgrade the canister to a wasm that
  keeps the field and ignores it (or clears it), or reinstall it, and the lock is gone. It is as
  strong as the keys of the canister's controllers.
- **It freezes what can be minted, not how it is displayed.** `Metadata` stays editable, and a
  metadata key can claim any figure; it moves no balance. (`Decimals` cannot change after
  install, lock or no lock: see Security above.)
- **It does not close the ICRC transfer paths.** If the minting account is an account somebody can
  sign for, an `icrc1_transfer`, an `icrc2_transfer_from` (after that account's approval) or an
  `icrc4_transfer_batch` from it is still recorded as a mint after the lock. Set the minting
  account to the ledger's own principal before locking, so that nobody can sign for it; the lock
  then keeps it there. The library does not check this: a deployer must.
- The `pic/TokenWithICRC85.mo` fixture has no lock.

### Fixed

- **The ICRC-106 index principal is stored as text** (`vendor/icrc1-mo`). ICRC-106 defines
  `icrc106:index_principal` in `icrc1_metadata` as the principal's textual form; it was a
  `#Blob` of the principal's bytes. `set_icrc106_index_principal` now stores `#Text`.
  `icrc106_get_index_principal` reads it, and still reads a `#Blob` written by an earlier build:
  call `set_icrc106_index_principal` once after upgrading to rewrite the metadata. ICRC-106 was
  already listed in `icrc1_supported_standards` and `icrc10_supported_standards`.
- **`upgradeArchive` no longer fails in silence** (`src/Token.mo`). It dropped the per-archive
  results, marked the upgrade complete even when every archive failed, and `getUpgradeError`
  answered `""`. A ledger that ran it on an earlier build keeps that completion across the
  upgrade: run `upgradeArchive(true)` once after upgrading and read every entry.

### Changed

- **`upgradeArchive` reports each archive** (`src/Token.mo`). It returns
  `vec record { canister_id; result : variant { Ok; Err : text } }`, one entry per archive, where
  it returned `()`; a caller that ignores the reply still decodes it. The upgrade completes only
  when every entry is `Ok`, so after a failure `upgradeArchive(false)` runs again.
  `getUpgradeError` answers the failures of the last run, joined with `"; "`, or `""`. A second
  call while one is running traps `"Upgrade already in progress"`.
- **An install with more than 8 principals in `archiveControllers` traps** (`src/Token.mo`),
  besides the ledger itself. The IC allows 10 controllers per canister and the ledger adds itself
  and the owner. An upgrade is never refused for a list stored before. On such a ledger
  `update_archive_controllers` reports `#Err("… exceeds the IC limit of 10 controllers")` for every
  archive and sends nothing.
- **The owner of the ledger changes in two steps** (`src/Token.mo`, `src/token-mixin.mo`).
  `admin_propose_owner(?Principal)`, by the owner, names a successor; `accept_ownership()`, by
  that principal, completes the hand-off. Nothing moves until the proposed principal accepts, so
  a mistyped principal, or one nobody holds the key of, cannot take the administration with it.
  `null` cancels a proposal and a new proposal replaces the pending one. The anonymous principal
  and the current owner are refused as proposals, and the anonymous caller is refused by both
  methods.
- New queries `get_owner` and `get_pending_owner`.
- New stable field `pending_owner : ?Principal`. Upgrading is a plain upgrade. Going BACK to a
  build without the field is not: the compiler refuses to drop it (M0169).
- In `src/Token.mo` the ingress filter admits `accept_ownership` for the pending principal
  alone, and for nobody while nothing is pending.

### What the hand-off does not do

- A proposal does not expire. A principal proposed long ago can accept at any later time,
  until the owner cancels or replaces the proposal.
- It does not move the archives that exist: the former owner stays among their controllers
  until the new owner runs `update_archive_controllers`.
- It does not move the minting account, which is set at install and changed with
  `admin_update_icrc1`.
- It does not repair a ledger whose owner is ALREADY the anonymous principal, which the
  one-step method allowed, and which an install by the anonymous principal still produces. Every
  owner method refuses the anonymous caller (see Security), and `admin_propose_owner` refuses it,
  so the ownership cannot be moved by a call: a controller has to fix it with a reinstall. Read
  `get_owner` before relying on this release.

### Removed

- **`admin_update_owner`** from `src/Token.mo` and `src/token-mixin.mo`. It handed the ledger
  over in one call and accepted any principal, the anonymous one included. **Breaking** for a
  caller of that method: use the two steps above.
- **The example canisters and the SNS variant**: `src/examples/` (`Lotto.mo`, `Allowlist.mo`,
  `LottoInterface.mo`, `AllowlistInterface.mo`, `utils/ICPService.mo`), `src/snstest.mo` and
  `src/sns_types.mo`, with their `dfx.json` entries and their targets in
  `pic/build-token-wasm.sh`. The issue of the allowlist examples, which added every upgrader to
  the allowlist, goes with them. The test fixture `pic/TokenWithICRC85.mo` stays; its
  owner hand-off is now tested by `pic/icrc85_fixture_handoff.test.ts`.

### Known follow-up

- The committed declarations (`src/declarations/token/*`, `test/devefi_patches/motoko_ledger.idl.*`)
  were edited for the methods of this change only. They already differed from what the compiler
  emits for `src/Token.mo` (`get_health` is missing, `icrc21_canister_call_consent_message` is
  not marked as a query, the `icrc3` init section is not optional).

## [0.2.1] - 2026-03-14

### Updates

- Updated to core 2.1.0
- Update to moc 1.3.0

## [0.2.0] - 2026-02-24

### Added

#### Token Architecture
- **Mixin-based token** (`token-mixin.mo`): Ultra-compact ~150-line token using `include` directives for ICRC-1, ICRC-2, ICRC-3, ICRC-4, and TimerTool mixins — all ICRC endpoints auto-generated
- **Shared Inspect module** (`Inspect.mo`): Reusable argument validation for cycle drain protection with configurable limits (`Config` type), guard functions for inter-canister calls, and compound validators (account, memo, subaccount, Nat, Int, Blob, Text, array length, raw arg size)

#### Cycle Drain Protection
- Complete `system func inspect()` implementation in Token.mo covering all 40+ endpoints
- Raw arg size check first (cheapest operation) before expensive Candid decoding
- Per-standard validation: ICRC-1 (`inspectTransfer`, `inspectBalanceOf`), ICRC-2 (`inspectApprove`, `inspectTransferFrom`, `inspectAllowance`, `inspectGetAllowances`), ICRC-3 (`inspectGetBlocks`, `inspectGetArchives`, `inspectLegacyBlocks`), ICRC-4 (`inspectTransferBatch`, `inspectBalanceOfBatch`)
- Mint/burn argument validation using `isValidAccount`, `isValidNat`, `isValidMemo`

#### New Standard Support
- **ICRC-106** (Index Principal): `icrc106_get_index_principal()`, `set_icrc106_index_principal()` with owner authorization
- **ICRC-107** (Fee Collector Management): `icrc107_set_fee_collector()`, `icrc107_get_fee_collector()` with owner authorization and block type `107feecol`
- **ICRC-21** (Consent Messages): `icrc21_canister_call_consent_message()` with pluggable consent builders for `icrc1_transfer`, `icrc107_set_fee_collector`, `icrc2_approve`, `icrc2_transfer_from`, `icrc4_transfer_batch`
- **ICRC-10**: `icrc10_supported_standards()` aliasing ICRC-1 standards list
- **ICRC-85** (Open Value Sharing): Timer auto-initialization via ClassPlus pattern — no manual `init_icrc85_timer` call needed
- **ICRC-103**: Allowance query endpoint `icrc103_get_allowances()` with configurable `icrc103_max_take_value` and `icrc103_public_allowances`
- **ICRC-130**: Alias for allowance discovery (via ICRC-2 library)

#### Index Push Notifications
- Timer-based push notification system: token proactively notifies index canister when new blocks are added with out spamming it
- `admin_set_index_canister()` / `get_index_canister()` for configuring the index target
- Batched notification with 2-second delay to coalesce multiple blocks
- Best-effort messaging with 60-second timeout and error recovery

#### Rosetta & SNS Compatibility
- `get_data_certificate()` — legacy alias for `icrc3_get_tip_certificate` matching SNS ledger interface
- `is_ledger_ready()` — SNS parity readiness check
- `get_blocks()` — Rosetta-compatible block retrieval with archive callbacks
- `get_transactions()` — Legacy transaction retrieval format
- `archives()` — Legacy archive info endpoint with `block_range_start`/`block_range_end`
- `get_tip()` — Legacy ICRC-3 tip endpoint
- SNS token actor (`snstest.mo`) matching SNS ledger argument format for devefi integration

#### Testing
- **8 new PocketIC test suites** for ICRC_fungible:
  - `icrc106.test.ts` — Index principal management
  - `icrc107.test.ts` — Fee collector get/set
  - `icrc107_lifecycle.test.ts` — End-to-end fee collector changes with real transfers
  - `icrc21.test.ts` — Consent message generation for all supported methods
  - `icrc85.test.ts` — ICRC-85 cycle sharing functionality
  - `index_push.test.ts` — Push notification system with mock index canister
  - `inspect.test.ts` — `system func inspect()` validation for oversized arguments
  - `verify_token_timer.test.ts` — ICRC-85 timer auto-initialization via ClassPlus
- **Comprehensive test runner** (`runners/run_all_tests.sh`, 860 lines):
  - Runs ICRC-1, ICRC-2, ICRC-3, ICRC-4 library mops + PocketIC tests
  - ICRC_fungible mops + PocketIC tests
  - DFINITY official ICRC-1/2 test suite against both `token` and `token-mixin`
  - Devefi integration tests against both `token` and `token-mixin`
  - Rosetta integration tests (including fee collector and archive scenarios)
  - Index-NG and index.mo integration tests against both token variants
  - `--skip-*` and `--only-*` flags for selective test execution
- Integration test scripts for Index-NG (`test_index_ng.sh`), index.mo (`test_index_mo.sh`), Rosetta (`test_rosetta.sh`, `test_rosetta_archive.sh`, `test_rosetta_feecol.sh`)

### Changed

#### Core Migration
- Migrated from `mo:base` to `mo:core` throughout all source files (Token.mo, token-mixin.mo, snstest.mo, Inspect.mo, examples)
- Uses `mo:core/List` instead of `mo:vector` / `mo:base/List`
- Uses `mo:core/Map` and `mo:core/Set` via library re-exports (`ICRC2.CoreMap`, `ICRC2.CoreSet`)
- `persistent actor class` syntax (Motoko 1.1.0+ Enhanced Orthogonal Persistence)
- `transient` annotations on init-time-only bindings
- `Runtime.trap` replaces `D.trap`

#### Dependency Updates
- `icrc1-mo` 0.2.0 — mixin, inspect, ICRC-106/107/21/10/85, mo:core migration
- `icrc2-mo` 0.2.0 — mixin, inspect, ICRC-103/130, cleanup options, mo:core migration
- `icrc3-mo` 0.4.0 — mixin, inspect, query archives, LEB128 certificates, mo:core migration
- `icrc4-mo` 0.2.0 — mixin, inspect, ICRC-21 consent, mo:core migration
- `class-plus` 0.2.0 — ClassPlus initialization manager
- `timer-tool` 0.2.0 — TimerTool with mixin support
- `ic-certification` 1.1.0
- `star` 0.1.1
- `core` 2.0.0
- Toolchain: `moc = "1.1.0"`, `pocket-ic = "12.0.0"`

#### Code Quality
- Removed redundant `stable` keywords on persistent actor fields
- Removed unguarded debug statements from production code
- Fixed unused identifier warnings across Token.mo, snstest.mo, examples
- Fixed ClassPlus system capability (added `<system>` type parameter)

### Fixed

- ICRC-2 `InitArgs` updated with required fields: `cleanup_interval`, `cleanup_on_zero_balance`, `icrc103_max_take_value`, `icrc103_public_allowances`

### Library Changes (upstream)

These changes are in the underlying libraries consumed by this project:

- **icrc1-mo 0.2.0**: Added mixin, inspect module, ICRC-107/106/21/10/85 support, mo:core migration
- **icrc2-mo 0.2.0**: Added mixin, inspect module, ICRC-103/130, cleanup timers, fixed double fee collection bug, fixed ICRC-103 access control, fixed index iterator, mo:core migration
- **icrc3-mo 0.4.0**: Added mixin, inspect module, query archives, fixed certificate LEB128 encoding, mo:core migration
- **icrc4-mo 0.2.0**: Added mixin, inspect module, ICRC-21 consent, batch size guards, mo:core migration

## [0.0.7] - 2025-03-01

### Changed

- Updated dependencies, compiler, and dfx

## [0.0.6] - 2025-01-15

### Added

- Implemented ICRC-3 with legacy `get_transactions` backfill
- ICRC-103 endpoint for retrieving allowances
- ICRC-106 endpoint for retrieving index canister
- SNS token actor (`snstest.mo`) matching SNS initialization interface for devefi integration

### Technical Details

- Uses ClassPlus initialization pattern for ICRC-3
- Supports Rosetta-compatible transaction queries via legacy endpoints