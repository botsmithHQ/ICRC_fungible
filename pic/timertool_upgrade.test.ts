/**
 * TimerTool after an upgrade.
 *
 * The ledger keeps ONE TimerTool queue (src/Token.mo, getTimerTool). Its IC
 * timer is armed only when something calls setAction* / cancelAction, and an
 * upgrade clears every IC timer. The index push (src/Token.mo, "Index Push
 * Notification") is an action of that queue that has nothing to do with
 * ICRC-85: a new block schedules one `index:notify`, and while it is pending
 * (`pending_notify_action_id`, stable) no other one is scheduled.
 *
 * These tests use the real index canister (../../index.mo) with a polling
 * interval of one day, so it only learns about blocks through the push.
 */
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import type { Actor } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { existsSync, readFileSync } from 'fs';
import { resolve } from 'path';
import {
  advanceDays, archives, countByStream, createIdentity, installCollector, installLedger, smallArchiveArgs,
  upgradeLedger, wasmPath,
} from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');
const INDEX_WASM = resolve(__dirname, '../../index.mo/.dfx/local/canisters/icrc_index/icrc_index.wasm.gz');

const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });

const ledgerIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  admin_init: IDL.Func([], [], []),
  admin_set_index_canister: IDL.Func([IDL.Opt(IDL.Principal)], [IDL.Bool], []),
  mint: IDL.Func([IDL.Record({
    to: Account,
    amount: IDL.Nat,
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  })], [IDL.Variant({ Ok: IDL.Nat, Err: IDL.Reserved })], []),
  icrc1_transfer: IDL.Func([IDL.Record({
    from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    to: Account,
    amount: IDL.Nat,
    fee: IDL.Opt(IDL.Nat),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  })], [IDL.Variant({ Ok: IDL.Nat, Err: IDL.Reserved })], []),
  // Only the two requests these tests send; Candid accepts a smaller variant.
  admin_update_icrc1: IDL.Func(
    [IDL.Vec(IDL.Variant({ MaxAccounts: IDL.Nat, SettleToAccounts: IDL.Nat }))],
    [IDL.Vec(IDL.Bool)],
    [],
  ),
  icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ['query']),
  icrc3_get_archives: IDL.Func(
    [IDL.Record({ from: IDL.Opt(IDL.Principal) })],
    [IDL.Vec(IDL.Record({ canister_id: IDL.Principal, start: IDL.Nat, end: IDL.Nat }))],
    ['query'],
  ),
});

const indexIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  status: IDL.Func([], [IDL.Record({ num_blocks_synced: IDL.Nat64 })], ['query']),
});

const IndexArg = IDL.Opt(IDL.Variant({
  Init: IDL.Record({
    ledger_id: IDL.Principal,
    retrieve_blocks_from_ledger_interval_seconds: IDL.Opt(IDL.Nat64),
  }),
  Upgrade: IDL.Record({
    ledger_id: IDL.Opt(IDL.Principal),
    retrieve_blocks_from_ledger_interval_seconds: IDL.Opt(IDL.Nat64),
  }),
}));

const owner = createIdentity(1).getPrincipal();
const holderId = createIdentity(2);
const holder = holderId.getPrincipal();
const RECIPIENT = createIdentity(99).getPrincipal();

let server: PocketIcServer;
let pic: PocketIc | undefined;

beforeAll(async () => {
  if (!existsSync(INDEX_WASM)) throw new Error(`Index WASM not found at ${INDEX_WASM}. Build it in index.mo first.`);
  server = await PocketIcServer.start();
}, 120_000);
afterAll(async () => { await server.stop(); });
afterEach(async () => { await pic?.tearDown(); pic = undefined; });

/**
 * A ledger and a real index that never polls on its own during the test. The
 * ledger pushes to it only when `pushToIndex` is set.
 */
async function setup(args: unknown[] | null = null, pushToIndex = true): Promise<{
  ledger: Actor<any>; ledgerId: Principal; index: Actor<any>; indexId: Principal;
}> {
  pic = await PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
  const { id: ledgerId } = await installLedger(pic, TOKEN_WASM, owner, args);
  const ledger = pic.createActor<any>(ledgerIdl, ledgerId);
  ledger.setPrincipal(owner);

  const indexId = await pic.createCanister({ sender: owner, cycles: 100_000_000_000_000n });
  await pic.installCode({
    canisterId: indexId,
    wasm: readFileSync(INDEX_WASM),
    arg: new Uint8Array(IDL.encode([IndexArg], [[{ Init: {
      ledger_id: ledgerId,
      retrieve_blocks_from_ledger_interval_seconds: [86_400n],
    } }]])),
    sender: owner,
  });
  const index = pic.createActor<any>(indexIdl, indexId);

  await ledger.admin_init();
  if (pushToIndex) expect(await ledger.admin_set_index_canister([indexId])).toBe(true);
  await settle();
  return { ledger, ledgerId, index, indexId };
}

/** Let `seconds` pass, ticking enough for a notify + the index's fetch. */
async function settle(seconds = 10): Promise<void> {
  for (let i = 0; i < seconds; i++) {
    await pic!.advanceTime(1_000);
    await pic!.tick();
    await pic!.tick();
  }
}

async function mint(ledger: Actor<any>, amount: bigint): Promise<void> {
  const r = await ledger.mint({ to: { owner: holder, subaccount: [] }, amount, memo: [], created_at_time: [] });
  expect('Ok' in r).toBe(true);
}

async function synced(index: Actor<any>): Promise<bigint> {
  return (await index.status()).num_blocks_synced;
}

/** Blocks the ledger has moved to its archives so far. */
async function archived(ledger: Actor<any>, ledgerId: Principal): Promise<bigint> {
  return (await archives(ledger, ledgerId)).reduce((n, a) => n + a.end - a.start + 1n, 0n);
}

// The index learns about blocks one push late: the ledger sends the index of
// its last block (src/Token.mo, execute_index_notify) and the index only syncs
// when that number is greater than the blocks it already has. So these tests
// mint blocks in pairs: the second push of a pair always brings both.

describe('TimerTool queue after an upgrade', () => {
  it('positive control: without an upgrade, every pair of blocks reaches the index', async () => {
    const { ledger, index } = await setup();
    const before = await synced(index);
    await mint(ledger, 1_000_000n);
    await mint(ledger, 2_000_000n);
    await settle();
    expect(await synced(index)).toBe(before + 2n);
    await mint(ledger, 3_000_000n);
    await mint(ledger, 4_000_000n);
    await settle();
    expect(await synced(index)).toBe(before + 4n);
  });

  it('an index notify queued before an upgrade runs after it, and later blocks keep reaching the index', async () => {
    const { ledger, ledgerId, index } = await setup();
    const before = await synced(index);
    await mint(ledger, 1_000_000n);
    await mint(ledger, 2_000_000n);
    await settle();
    expect(await synced(index)).toBe(before + 2n);

    // Two blocks whose notify (2 s delay) is still queued when the ledger is upgraded.
    await mint(ledger, 3_000_000n);
    await mint(ledger, 4_000_000n);
    await upgradeLedger(pic!, ledgerId, TOKEN_WASM, owner, null);

    await settle(30);
    expect(await synced(index)).toBe(before + 4n);

    // Later blocks must be pushed too.
    await mint(ledger, 5_000_000n);
    await mint(ledger, 6_000_000n);
    await settle(30);
    expect(await synced(index)).toBe(before + 6n);
  });

  // The re-arm also wakes the ICRC-85 share actions queued in the same
  // TimerTool queue. With the kill switches as shipped (?true) they only
  // reschedule themselves: nothing may reach the collector.
  it('ICRC-85 stays off: after the re-arm, the queued share actions pay nothing', async () => {
    const { ledger, ledgerId, index } = await setup();
    const collector = await installCollector(pic!);
    const before = await synced(index);
    await mint(ledger, 1_000_000n);
    await mint(ledger, 2_000_000n);
    await mint(ledger, 3_000_000n);
    await mint(ledger, 4_000_000n);
    await upgradeLedger(pic!, ledgerId, TOKEN_WASM, owner, null);
    await settle(30);
    expect(await synced(index)).toBe(before + 4n); // the queue is awake

    // Several share periods (30 days each), with traffic in each one.
    for (let period = 0; period < 3; period++) {
      await advanceDays(pic!, 31);
      await mint(ledger, 1_000n);
      await mint(ledger, 1_000n);
      await settle(10);
    }
    // The real index pays its own shares (another canister, ICRC-85 on), so
    // the collector does receive; none of it may come from the ledger.
    const streams = Object.keys(await countByStream(collector));
    expect(streams.length).toBeGreaterThan(0);
    expect(streams.filter((s) => s.endsWith(`@ ${ledgerId.toText()}`))).toEqual([]);
  }, 300_000);
});

describe('TimerTool timer id kept across an upgrade', () => {
  // Motoko numbers IC timers from 1 again after an upgrade, but TimerTool keeps
  // the id of its last timer (`nextTimer`) in stable state and cancels it the
  // first time it schedules after the upgrade. That first time is the index
  // push of a new block, in the same message (ICRC-3 add_record) that may have
  // just set the archive timer, whose id ICRC-3 also keeps in stable state and
  // only clears when it fires. If the two ids match, archiving stops for good.
  //
  // The ids are deterministic in PocketIC; this sequence (one push before the
  // upgrade, three archive runs after it) makes them match.
  async function archivingAfterFirstPush(upgrade: boolean): Promise<{ before: bigint; after: bigint }> {
    const { ledger, ledgerId, indexId } = await setup(smallArchiveArgs(), false);
    let blocks = 0n;
    const transfer = async () => {
      ledger.setIdentity(holderId);
      const r = await ledger.icrc1_transfer({
        from_subaccount: [], to: { owner: RECIPIENT, subaccount: [] },
        amount: 1_000n + blocks, fee: [], memo: [], created_at_time: [],
      });
      ledger.setPrincipal(owner);
      expect('Ok' in r).toBe(true);
      blocks++;
      await pic!.tick();
      await pic!.tick();
    };

    await mint(ledger, 1_000_000_000_000n); blocks++; // the holder's balance

    // One push before the upgrade, then the index is switched off again.
    expect(await ledger.admin_set_index_canister([indexId])).toBe(true);
    await mint(ledger, 1n); blocks++;
    await settle(5);
    expect(await ledger.admin_set_index_canister([])).toBe(true);
    await settle(5);

    if (upgrade) await upgradeLedger(pic!, ledgerId, TOKEN_WASM, owner, smallArchiveArgs());

    // Three archive runs with no push configured.
    for (let run = 0; run < 3; run++) {
      const start = await archived(ledger, ledgerId);
      for (let i = 0; i < 200 && (await archived(ledger, ledgerId)) === start; i++) await transfer();
      await settle();
    }

    // Fill the ledger up to its limit (50 blocks) without crossing it.
    for (let local = blocks - (await archived(ledger, ledgerId)); local < 50n; local++) await transfer();
    await settle();
    const before = await archived(ledger, ledgerId);

    // The next block crosses the limit (archive timer) and is the first push.
    expect(await ledger.admin_set_index_canister([indexId])).toBe(true);
    await transfer();
    await settle();
    for (let i = 0; i < 90; i++) await transfer();
    await settle();
    return { before, after: await archived(ledger, ledgerId) };
  }

  it('positive control: without an upgrade, the ledger keeps archiving', async () => {
    const { before, after } = await archivingAfterFirstPush(false);
    expect(after).toBeGreaterThan(before);
  }, 300_000);

  it('after an upgrade, the first push does not cancel the archive timer', async () => {
    const { before, after } = await archivingAfterFirstPush(true);
    expect(after).toBeGreaterThan(before);
  }, 300_000);
});

describe('Other timer ids kept in stable state across an upgrade', () => {
  // ICRC-3 keeps the id of its archive timer (`cleaningTimer`) in stable state
  // and only arms a new one while that field is null; the timer clears it when
  // it fires. If the ledger is stopped and upgraded after the block that armed
  // the timer but before it fires, the timer is gone and the field is not null.
  async function archivingAfterStopAtLimit(upgrade: boolean): Promise<{ before: bigint; after: bigint }> {
    const { ledger, ledgerId } = await setup(smallArchiveArgs(), false);
    const send = async (n: bigint) => {
      ledger.setIdentity(holderId);
      const r = await ledger.icrc1_transfer({
        from_subaccount: [], to: { owner: RECIPIENT, subaccount: [] },
        amount: 1_000n + n, fee: [], memo: [], created_at_time: [],
      });
      ledger.setPrincipal(owner);
      expect('Ok' in r).toBe(true);
    };
    await mint(ledger, 1_000_000_000_000n);
    // 50 blocks on the ledger: its limit, not yet crossed.
    for (let n = 1n; n < 50n; n++) { await send(n); await pic!.tick(); }
    await settle(3);
    expect(await archived(ledger, ledgerId)).toBe(0n);

    // Block 51 arms the archive timer; stop the ledger before it fires.
    await send(50n);
    await pic!.stopCanister({ canisterId: ledgerId, sender: owner });
    if (upgrade) await upgradeLedger(pic!, ledgerId, TOKEN_WASM, owner, smallArchiveArgs());
    await pic!.startCanister({ canisterId: ledgerId, sender: owner });
    await settle();
    const before = await archived(ledger, ledgerId);
    for (let n = 51n; n < 81n; n++) { await send(n); await pic!.tick(); }
    await settle();
    return { before, after: await archived(ledger, ledgerId) };
  }

  it('positive control: icrc3 cleaningTimer, a stop and start alone keeps the ledger archiving', async () => {
    const { after } = await archivingAfterStopAtLimit(false);
    expect(after).toBeGreaterThan(0n);
  }, 300_000);

  it('icrc3 cleaningTimer: an upgrade while the archive timer is armed does not stop archiving', async () => {
    const { before, after } = await archivingAfterStopAtLimit(true);
    expect(before).toBe(0n); // the timer had not fired before the upgrade
    expect(after).toBeGreaterThan(0n);
  }, 300_000);

  // ICRC-1 keeps `cleaning_timer` (shared with ICRC-2, which calls the same
  // check) in stable state, arms it on a transfer only while it is null, and
  // never sets it back to null (vendor/icrc1-mo ICRC1/lib.mo, handleCleanUp and
  // checkAccounts). So the account sweep (burn the smallest balances once there
  // are more than max_accounts) runs at most once in the life of the ledger, at
  // its first transfer, upgrade or not. That is an upstream one-shot timer, not
  // a stale id left by an upgrade, and it is not fixed here: setting the field
  // back to null would start burning balances. This test measures it.
  async function accountsWithBalanceOverTheLimit(upgrade: boolean): Promise<number> {
    const { ledger, ledgerId } = await setup(null, false);
    const others = [100, 101, 102, 103].map((s) => createIdentity(s).getPrincipal());
    const send = async (to: Principal, amount: bigint) => {
      ledger.setIdentity(holderId);
      const r = await ledger.icrc1_transfer({
        from_subaccount: [], to: { owner: to, subaccount: [] },
        amount, fee: [], memo: [], created_at_time: [],
      });
      ledger.setPrincipal(owner);
      expect('Ok' in r).toBe(true);
    };
    await mint(ledger, 1_000_000_000_000n);
    await send(others[0], 1_000_000n); // the timer runs with two accounts: nothing to sweep
    await settle(3);
    expect(await ledger.admin_update_icrc1([{ MaxAccounts: 3n }, { SettleToAccounts: 2n }])).toEqual([true, true]);
    if (upgrade) await upgradeLedger(pic!, ledgerId, TOKEN_WASM, owner, null);
    for (let i = 1; i < others.length; i++) { await send(others[i], 1_000_000n + BigInt(i)); await settle(2); }
    await settle(5);
    let withBalance = 0;
    for (const p of [holder, ...others]) {
      if ((await ledger.icrc1_balance_of({ owner: p, subaccount: [] })) > 0n) withBalance++;
    }
    return withBalance;
  }

  it('measured: icrc1/icrc2 cleaning_timer is one-shot for the life of the ledger, so an upgrade changes nothing', async () => {
    // Five accounts with a balance and max_accounts = 3: the sweep never runs again.
    expect(await accountsWithBalanceOverTheLimit(false)).toBe(5);
    await pic!.tearDown(); pic = undefined;
    expect(await accountsWithBalanceOverTheLimit(true)).toBe(5);
  }, 300_000);
});
