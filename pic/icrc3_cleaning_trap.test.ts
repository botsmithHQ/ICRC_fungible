/**
 * A ledger that cannot pay for its archive archives again once it can.
 *
 * `check_clean_up` (vendor/icrc3-mo/src/lib.mo) runs from a timer and first
 * sets `cleaningTimer := null`; `add_record` arms a new timer only while that
 * field is null. Creating the first archive sends it `archiveCycles`. When the
 * ledger's balance minus its freezing reserve cannot cover that, the send traps
 * inside the timer's own message, before its first `await`, and the trap rolls
 * back the `null`. The field keeps the id of a timer that already ran, no block
 * arms another one, and the ledger never archives again, even after it is
 * topped up. Upstream only recovers through an upgrade (`Token.mo`'s
 * postupgrade clears the field).
 *
 * The test holds the ledger just under the amount it needs: 45T of balance,
 * `archiveCycles` 20T (the `balance > 2 × archiveCycles` check passes) and a
 * freezing reserve of ~30T, so 20T cannot leave. A fixed memory allocation
 * makes the reserve independent of the heap the transfers grow. Then the
 * reserve goes back to 30 days, and the next blocks must archive with no
 * upgrade, every block exactly once across the ledger and the archive.
 *
 * Red without the LOCAL PATCH (cleaningTimer committed before archiving):
 * no archive. TOKEN_WASM=<path> points it at any build.
 *
 * The second describe covers a failure AFTER that first await: the archive
 * canister is created but its install is rejected (`archiveCycles` covers the
 * creation fee and 100M more, too little to install). The run throws at that
 * await and `bCleaning` stays true, so every later run returns at once. The
 * library keeps no `finally` there on purpose (vendor/README.md, "Not
 * patched: bCleaning"): one that cleared the flag would create and pay for a
 * new archive on every block. `Token.mo`'s postupgrade clears the flag
 * instead, so stop + upgrade + start recovers. Red without that line: no
 * cleanup runs after the upgrade.
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { readFileSync } from 'fs';
import { IDL } from '@icp-sdk/core/candid';
import { Principal } from '@icp-sdk/core/principal';
import {
  archiveIdl, archives, createIdentity, encodeTokenArgs, ledgerIdl, smallArchiveArgs, transferUntil, wasmPath, DAY_MS,
  EOP_UPGRADE,
} from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');

const ARCHIVE_CYCLES = 20_000_000_000_000n;
const RESERVE = 30_000_000_000_000n;
const THIRTY_DAYS_S = 2_592_000n;

/** The ledger's own `icrc3_get_blocks`: its local blocks and the log length. */
const logIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  icrc3_get_blocks: IDL.Func(
    [IDL.Vec(IDL.Record({ start: IDL.Nat, length: IDL.Nat }))],
    [IDL.Record({ log_length: IDL.Nat, blocks: IDL.Vec(IDL.Record({ id: IDL.Nat, block: IDL.Reserved })) })],
    ['query'],
  ),
});

/** The canister id PocketIC hands out right after `id`. */
function nextCanisterId(id: Principal): Principal {
  const bytes = new Uint8Array(id.toUint8Array());
  const view = new DataView(bytes.buffer);
  view.setBigUint64(0, view.getBigUint64(0) + 1n);
  return Principal.fromUint8Array(bytes);
}

describe('a failed archive creation does not stop archiving for good', () => {
  let picServer: PocketIcServer;
  let pic: PocketIc;

  beforeAll(async () => {
    picServer = await PocketIcServer.start();
    pic = await PocketIc.create(picServer.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
  });

  afterAll(async () => {
    await pic?.tearDown();
    await picServer?.stop();
  });

  it('archives again, without an upgrade, once the freezing reserve leaves room for the archive', async () => {
    const owner = createIdentity(1).getPrincipal();
    const holder = createIdentity(2);
    const id = await pic.createCanister({ sender: owner, cycles: 45_000_000_000_000n });
    await pic.installCode({
      canisterId: id,
      wasm: readFileSync(TOKEN_WASM),
      arg: encodeTokenArgs(smallArchiveArgs({ archiveCycles: ARCHIVE_CYCLES })),
      sender: owner,
    });
    for (let i = 0; i < 5; i++) await pic.tick();
    const ledger = pic.createActor<any>(ledgerIdl, id);
    ledger.setPrincipal(owner);
    const log = pic.createActor<any>(logIdl, id);
    const logLength = async () => (await log.icrc3_get_blocks([{ start: 0n, length: 0n }])).log_length as bigint;
    const balance = async () => BigInt(await pic.getCyclesBalance(id));

    // Idle burn under a fixed allocation, measured, then a threshold that
    // reserves ~30T of the ~45T balance.
    await pic.updateCanisterSettings({ canisterId: id, memoryAllocation: 1n << 30n, sender: owner });
    const before = await balance();
    await pic.advanceTime(DAY_MS);
    for (let i = 0; i < 5; i++) await pic.tick();
    const burnPerDay = before - (await balance());
    expect(burnPerDay).toBeGreaterThan(0n);
    await pic.updateCanisterSettings({ canisterId: id, freezingThreshold: (RESERVE * 86_400n) / burnPerDay, sender: owner });

    // Ten blocks under maxActiveRecords (50), then ten past it, where every
    // block runs a cleanup that cannot send 20T. The difference per block is
    // what a failing cleanup costs the ledger.
    await transferUntil(pic, ledger, owner, holder, async () => (await logLength()) >= 40n);
    const at40 = await balance();
    await transferUntil(pic, ledger, owner, holder, async () => (await logLength()) >= 50n, 600, false);
    const at50 = await balance();
    await transferUntil(pic, ledger, owner, holder, async () => (await logLength()) >= 60n, 600, false);
    for (let i = 0; i < 10; i++) await pic.tick();
    const at60 = await balance();
    console.log(`ledger cycles per block: ${(at40 - at50) / 10n} below 50 blocks, ` +
      `${(at50 - at60) / 10n} past 50 (a cleanup that traps on every block)`);
    expect(await archives(ledger, id), 'no archive while the reserve is ~30T').toHaveLength(0);
    expect(at60, 'the 20T never left').toBeGreaterThan(2n * ARCHIVE_CYCLES);
    expect(await pic.getCanisterSubnetId(nextCanisterId(id)), 'no canister was created').toBeNull();

    // Room again. No upgrade: only new blocks.
    await pic.updateCanisterSettings({ canisterId: id, freezingThreshold: THIRTY_DAYS_S, sender: owner });
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length > 0, 30, false);
    for (let i = 0; i < 10; i++) await pic.tick();

    // Every block exactly once, across the ledger and its archives.
    const total = await logLength();
    const ids: bigint[] = (await log.icrc3_get_blocks([{ start: 0n, length: total }])).blocks.map((b: any) => b.id);
    const list = await archives(ledger, id);
    expect(list.length).toBeGreaterThan(0);
    for (const a of list) {
      const archive = pic.createActor<any>(archiveIdl, a.canister_id);
      const stats = await archive.get_stats();
      const r = await archive.icrc3_get_blocks([{ start: stats.first_block_index, length: stats.total_records }]);
      ids.push(...r.blocks.map((b: any) => b.id as bigint));
    }
    const sorted = [...ids].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    expect(sorted.length, 'blocks in the ledger + archives').toBe(Number(total));
    sorted.forEach((b, i) => expect(b, `block ${i}`).toBe(BigInt(i)));
  });
});

// =============== bCleaning: an archive install that is rejected ===============

/** The creation fee of an application subnet and 100M more: creating the archive works, installing it does not. */
const SHORT_ARCHIVE_CYCLES = 500_100_000_000n;
const RECIPIENT = createIdentity(99).getPrincipal();

/** The `n`-th canister id PocketIC hands out after `id`. */
function nthCanisterId(id: Principal, n: number): Principal {
  let p = id;
  for (let i = 0; i < n; i++) p = nextCanisterId(p);
  return p;
}

describe('an archive install that is rejected leaves archiving stuck until the ledger is upgraded', () => {
  let picServer: PocketIcServer;
  let pic: PocketIc;

  beforeAll(async () => {
    picServer = await PocketIcServer.start();
  });

  afterAll(async () => {
    await picServer?.stop();
  });

  // One instance per test: the ledger is its first canister, and every
  // canister it creates takes the next id.
  beforeEach(async () => {
    pic = await PocketIc.create(picServer.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
  });

  afterEach(async () => {
    await pic?.tearDown();
  });

  /** A ledger with `SHORT_ARCHIVE_CYCLES` and one archive that would hold every block of the test. */
  async function install() {
    const owner = createIdentity(1).getPrincipal();
    const holder = createIdentity(2);
    const id = await pic.createCanister({ sender: owner, cycles: 45_000_000_000_000n });
    await pic.installCode({
      canisterId: id,
      wasm: readFileSync(TOKEN_WASM),
      arg: encodeTokenArgs(smallArchiveArgs({ archiveCycles: SHORT_ARCHIVE_CYCLES, perArchive: 1000 })),
      sender: owner,
    });
    for (let i = 0; i < 5; i++) await pic.tick();
    const ledger = pic.createActor<any>(ledgerIdl, id);
    ledger.setPrincipal(owner);
    const log = pic.createActor<any>(logIdl, id);
    const logLength = async () => (await log.icrc3_get_blocks([{ start: 0n, length: 0n }])).log_length as bigint;
    /** Canisters the ledger has created so far. */
    const created = async () => {
      let n = 0;
      while ((await pic.getCanisterSubnetId(nthCanisterId(id, n + 1))) !== null) n++;
      return n;
    };
    const blocksUntil = async (target: bigint, mint = false) => {
      await transferUntil(pic, ledger, owner, holder, async () => (await logLength()) >= target, 600, mint);
      for (let i = 0; i < 10; i++) await pic.tick();
    };
    const upgrade = async (stop: boolean) => {
      if (stop) await pic.stopCanister({ canisterId: id, sender: owner });
      await pic.upgradeCanister({
        canisterId: id, wasm: readFileSync(TOKEN_WASM), arg: encodeTokenArgs(null), sender: owner,
        upgradeModeOptions: EOP_UPGRADE,
      });
      if (stop) await pic.startCanister({ canisterId: id, sender: owner });
      for (let i = 0; i < 5; i++) await pic.tick();
    };
    /** One transfer, in its own call, so the test can tick past it one round at a time. */
    const transfer = async (amount: bigint) => {
      ledger.setIdentity(holder);
      const r = await ledger.icrc1_transfer({
        from_subaccount: [], to: { owner: RECIPIENT, subaccount: [] }, amount, fee: [], memo: [], created_at_time: [],
      });
      ledger.setPrincipal(owner);
      expect('Ok' in r).toBe(true);
    };
    return { owner, id, ledger, log, logLength, created, blocksUntil, upgrade, transfer };
  }

  it('stop + upgrade + start archives again; while the install is still rejected, each upgrade costs one archive creation', async () => {
    const l = await install();
    const balance = async () => BigInt(await pic.getCyclesBalance(l.id));
    const start = await balance();

    // 20 blocks past maxActiveRecords (50): one cleanup creates a canister,
    // its install is rejected, and no later block runs another.
    await l.blocksUntil(70n, true);
    const stuck = await balance();
    console.log(`stuck: ${await l.created()} canister(s) created, ${start - stuck} cycles spent`);
    expect(await archives(l.ledger, l.id), 'no archive').toHaveLength(0);
    expect(await l.created(), 'one canister created, no retry per block').toBe(1);

    // Recovery while the install is still rejected: the next block runs one
    // cleanup, which creates one canister and sticks again. Not one per block.
    await l.upgrade(true);
    await l.blocksUntil(100n);
    const afterOne = await balance();
    console.log(`after stop + upgrade, install still rejected: ${await l.created()} canister(s) created, ` +
      `${stuck - afterOne} cycles spent over 30 blocks`);
    expect(await archives(l.ledger, l.id), 'still no archive').toHaveLength(0);
    expect(await l.created(), 'the upgrade let exactly one cleanup run').toBe(2);
    expect(stuck - afterOne, 'one archive creation, not one per block').toBeLessThan(2n * SHORT_ARCHIVE_CYCLES);

    // Recovery once the install is accepted. The ledger's `archiveCycles` is
    // fixed in stable state (an upgrade does not apply init args), so the test
    // lifts the rejection from outside: it tops up the new canister in the
    // round after its creation, before the install reaches it.
    await l.upgrade(true);
    const nextArchive = nthCanisterId(l.id, (await l.created()) + 1);
    await l.transfer(7_000n);
    let toppedUp = false;
    for (let t = 0; t < 30 && !toppedUp; t++) {
      await pic.tick();
      if ((await pic.getCanisterSubnetId(nextArchive)) !== null) {
        await pic.addCycles(nextArchive, 2_000_000_000_000);
        toppedUp = true;
      }
    }
    expect(toppedUp, 'a cleanup ran after the second upgrade').toBe(true);
    await l.blocksUntil(130n);

    const list = await archives(l.ledger, l.id);
    expect(list.map((a) => a.canister_id.toText()), 'the topped-up canister is the archive').toEqual([nextArchive.toText()]);
    expect(await l.created(), 'the archive is the only canister created by this cleanup').toBe(3);

    // Every block exactly once, across the ledger and its archive.
    const total = await l.logLength();
    const ids: bigint[] = (await l.log.icrc3_get_blocks([{ start: 0n, length: total }])).blocks.map((b: any) => b.id);
    const archive = pic.createActor<any>(archiveIdl, list[0].canister_id);
    const stats = await archive.get_stats();
    expect(stats.total_records, 'blocks moved to the archive').toBeGreaterThan(0n);
    const r = await archive.icrc3_get_blocks([{ start: stats.first_block_index, length: stats.total_records }]);
    ids.push(...r.blocks.map((b: any) => b.id as bigint));
    const sorted = [...ids].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    expect(sorted.length, 'blocks in the ledger + archive').toBe(Number(total));
    sorted.forEach((b, i) => expect(b, `block ${i}`).toBe(BigInt(i)));
  });

  it('the premise of the reset: an upgrade without stop is refused while a cleanup awaits the archive install', async () => {
    const l = await install();
    await l.blocksUntil(50n, true);
    // This block crosses maxActiveRecords and arms the archive timer.
    await l.transfer(7_000n);
    let outcome = '';
    for (let t = 0; t < 30 && outcome === ''; t++) {
      await pic.tick();
      // The canister exists: the cleanup now awaits its install.
      if ((await pic.getCanisterSubnetId(nthCanisterId(l.id, 1))) === null) continue;
      try {
        await l.upgrade(false);
        outcome = 'accepted';
      } catch (e: any) {
        outcome = String(e?.message ?? e);
      }
    }
    expect(outcome).toContain('canister_pre_upgrade attempted with outstanding message callbacks');
  });
});
