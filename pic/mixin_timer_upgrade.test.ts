/**
 * Timer ids that `src/token-mixin.mo` keeps in stable state across an upgrade.
 *
 * An upgrade clears every IC timer, but ICRC-3 keeps the id of its armed
 * archive timer (`cleaningTimer`) and only arms a new one while that field is
 * null; the timer clears it when it fires. The mixin's `postupgrade` forgets
 * it, as `src/Token.mo` does (pic/timertool_upgrade.test.ts, same scenario on
 * Token.mo). This file is separate from pic/icrc85_off_mixin.test.ts because
 * it tests ledger timers, not ICRC-85.
 *
 * The production `src/token-mixin.mo` is tested UNCHANGED.
 * Wasm: `bash pic/build-token-wasm.sh token-mixin` (or TOKEN_MIXIN_WASM).
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import type { Actor } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { readFileSync } from 'fs';
import { EOP_UPGRADE, archives, createIdentity, ledgerIdl, wasmPath } from './archive_harness';

const MIXIN_WASM = wasmPath('TOKEN_MIXIN_WASM', 'token-mixin');

const owner = createIdentity(1).getPrincipal();
const holder = createIdentity(2);
const RECIPIENT = createIdentity(99).getPrincipal();

// The mixin's class argument: its `icrc3` section is not optional, unlike
// `Token.mo`'s, so `archive_harness.smallArchiveArgs` does not fit.
const ICRC3InitArgs = IDL.Record({
  maxActiveRecords: IDL.Nat,
  settleToRecords: IDL.Nat,
  maxRecordsInArchiveInstance: IDL.Nat,
  maxArchivePages: IDL.Nat,
  archiveIndexType: IDL.Variant({ Stable: IDL.Null, StableTyped: IDL.Null, Managed: IDL.Null }),
  maxRecordsToArchive: IDL.Nat,
  archiveCycles: IDL.Nat,
  archiveControllers: IDL.Opt(IDL.Opt(IDL.Vec(IDL.Principal))),
  supportedBlocks: IDL.Vec(IDL.Record({ block_type: IDL.Text, url: IDL.Text })),
});
const MixinArgs = IDL.Opt(IDL.Record({
  icrc1: IDL.Opt(IDL.Null),
  icrc2: IDL.Opt(IDL.Null),
  icrc3: ICRC3InitArgs,
  icrc4: IDL.Opt(IDL.Null),
}));

/** ~50 records on the ledger, 60 per archive. */
const SMALL_ARCHIVES = new Uint8Array(IDL.encode([MixinArgs], [[{
  icrc1: [],
  icrc2: [],
  icrc3: {
    maxActiveRecords: 50n,
    settleToRecords: 30n,
    maxRecordsInArchiveInstance: 60n,
    maxArchivePages: 62500n,
    archiveIndexType: { Stable: null },
    maxRecordsToArchive: 25n,
    archiveCycles: 20_000_000_000_000n,
    archiveControllers: [],
    supportedBlocks: [],
  },
  icrc4: [],
}]]));

let picServer: PocketIcServer;
let pic: PocketIc;

beforeAll(async () => {
  picServer = await PocketIcServer.start();
});

afterAll(async () => {
  await picServer?.stop();
});

beforeEach(async () => {
  pic = await PocketIc.create(picServer.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
});

afterEach(async () => {
  await pic?.tearDown();
});

/** Let `seconds` pass, two ticks per second. */
async function settle(seconds = 10): Promise<void> {
  for (let i = 0; i < seconds; i++) {
    await pic.advanceTime(1_000);
    await pic.tick();
    await pic.tick();
  }
}

/** Blocks the ledger has moved to its archives so far. */
async function archived(ledger: Actor<any>, ledgerId: Principal): Promise<bigint> {
  return (await archives(ledger, ledgerId)).reduce((n, a) => n + a.end - a.start + 1n, 0n);
}

/**
 * Fills the ledger to its limit, adds the block that arms the archive timer,
 * stops the ledger before the timer fires, optionally upgrades it, starts it
 * and adds 30 more blocks. Returns the archived blocks right after the start
 * and at the end.
 */
async function archivingAfterStopAtLimit(upgrade: boolean): Promise<{ before: bigint; after: bigint }> {
  const ledgerId = await pic.createCanister({ sender: owner, cycles: 500_000_000_000_000n });
  await pic.installCode({ canisterId: ledgerId, wasm: readFileSync(MIXIN_WASM), arg: SMALL_ARCHIVES, sender: owner });
  for (let i = 0; i < 5; i++) await pic.tick();
  const ledger = pic.createActor<any>(ledgerIdl, ledgerId);

  const send = async (n: bigint) => {
    ledger.setIdentity(holder);
    const r = await ledger.icrc1_transfer({
      from_subaccount: [], to: { owner: RECIPIENT, subaccount: [] },
      amount: 1_000n + n, fee: [], memo: [], created_at_time: [],
    });
    expect('Ok' in r).toBe(true);
  };
  ledger.setPrincipal(owner);
  const minted = await ledger.mint({
    to: { owner: holder.getPrincipal(), subaccount: [] }, amount: 1_000_000_000_000n, memo: [], created_at_time: [],
  });
  expect('Ok' in minted).toBe(true);
  // 50 blocks on the ledger: its limit, not yet crossed.
  for (let n = 1n; n < 50n; n++) { await send(n); await pic.tick(); }
  await settle(3);
  expect(await archived(ledger, ledgerId)).toBe(0n);

  // Block 51 arms the archive timer; stop the ledger before it fires.
  await send(50n);
  await pic.stopCanister({ canisterId: ledgerId, sender: owner });
  if (upgrade) {
    await pic.upgradeCanister({
      canisterId: ledgerId, wasm: readFileSync(MIXIN_WASM), arg: SMALL_ARCHIVES, sender: owner,
      upgradeModeOptions: EOP_UPGRADE,
    });
  }
  await pic.startCanister({ canisterId: ledgerId, sender: owner });
  await settle();
  const before = await archived(ledger, ledgerId);
  for (let n = 51n; n < 81n; n++) { await send(n); await pic.tick(); }
  await settle();
  return { before, after: await archived(ledger, ledgerId) };
}

describe('token-mixin timer ids kept in stable state across an upgrade', () => {
  it('positive control: icrc3 cleaningTimer, a stop and start alone keeps the ledger archiving', async () => {
    const { after } = await archivingAfterStopAtLimit(false);
    expect(after).toBeGreaterThan(0n);
  }, 300_000);

  it('icrc3 cleaningTimer: an upgrade while the archive timer is armed does not stop archiving', async () => {
    const { before, after } = await archivingAfterStopAtLimit(true);
    expect(before).toBe(0n); // the timer had not fired before the upgrade
    expect(after).toBeGreaterThan(0n);
  }, 300_000);
});
