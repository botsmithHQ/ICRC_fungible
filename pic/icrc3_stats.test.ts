/**
 * `icrc3_get_stats`: the ledger's ICRC-3 archiving state, read by anyone.
 *
 * With small bounds (50 records on the ledger, settle to 30) a few dozen
 * transfers spawn an archive. The query must show it: `localLedgerSize` drops
 * back under `maxActiveRecords`, the archive is listed with the blocks it took,
 * and the bounds are the ones the ledger was installed with.
 *
 * Counter-proof: archiving only runs while the ledger's balance is above
 * `2 * archiveCycles` (`vendor/icrc3-mo/src/lib.mo`, `check_clean_up`). A
 * ledger installed with less never creates an archive, and the query shows
 * `localLedgerSize` staying above `maxActiveRecords`, which is what a monitor
 * reads as "archiving stalled".
 *
 * TOKEN_WASM=<path> points it at any ledger build.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { IDL } from '@icp-sdk/core/candid';
import { Principal } from '@icp-sdk/core/principal';
import { archives, createIdentity, installLedger, smallArchiveArgs, transferUntil, wasmPath } from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');

/** `installLedger` creates the ledger with this many cycles. */
const LEDGER_CYCLES = 500_000_000_000_000n;
/** Twice this is above `LEDGER_CYCLES`: the ledger can never pay for an archive. */
const UNAFFORDABLE_ARCHIVE_CYCLES = 300_000_000_000_000n;

const TransactionRange = IDL.Record({ start: IDL.Nat, length: IDL.Nat });
const Stats = IDL.Record({
  localLedgerSize: IDL.Nat,
  lastIndex: IDL.Nat,
  firstIndex: IDL.Nat,
  archives: IDL.Vec(IDL.Tuple(IDL.Principal, TransactionRange)),
  supportedBlocks: IDL.Vec(IDL.Record({ block_type: IDL.Text, url: IDL.Text })),
  ledgerCanister: IDL.Principal,
  bCleaning: IDL.Bool,
  constants: IDL.Record({
    archiveProperties: IDL.Record({
      maxActiveRecords: IDL.Nat,
      settleToRecords: IDL.Nat,
      maxRecordsInArchiveInstance: IDL.Nat,
      maxRecordsToArchive: IDL.Nat,
      archiveCycles: IDL.Nat,
      archiveControllers: IDL.Opt(IDL.Opt(IDL.Vec(IDL.Principal))),
    }),
  }),
});

const statsIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  icrc3_get_stats: IDL.Func([], [Stats], ['query']),
  get_health: IDL.Func([], [IDL.Record({ cycles: IDL.Nat })], ['query']),
});

type StatsT = {
  localLedgerSize: bigint;
  lastIndex: bigint;
  firstIndex: bigint;
  archives: [Principal, { start: bigint; length: bigint }][];
  ledgerCanister: Principal;
  bCleaning: boolean;
  constants: { archiveProperties: { maxActiveRecords: bigint; settleToRecords: bigint; archiveCycles: bigint } };
};

describe('icrc3_get_stats', () => {
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

  /** The query, sent by the anonymous principal: it is open to anyone. */
  function reader(ledgerId: Principal) {
    const actor = pic.createActor<any>(statsIdl, ledgerId);
    return {
      stats: () => actor.icrc3_get_stats() as Promise<StatsT>,
      cycles: async () => ((await actor.get_health()) as { cycles: bigint }).cycles,
    };
  }

  it('shows an archive taking blocks off the ledger, read by the anonymous principal', async () => {
    const owner = createIdentity(1).getPrincipal();
    const holder = createIdentity(2);
    const { id: ledgerId, actor: ledger } = await installLedger(pic, TOKEN_WASM, owner, smallArchiveArgs());
    const read = reader(ledgerId);

    const initial = await read.stats();
    expect(initial.archives).toEqual([]);
    expect(initial.bCleaning).toBe(false);
    expect(initial.ledgerCanister.toText()).toBe(ledgerId.toText());
    expect(initial.constants.archiveProperties.maxActiveRecords).toBe(50n);
    expect(initial.constants.archiveProperties.settleToRecords).toBe(30n);
    expect(initial.constants.archiveProperties.archiveCycles).toBe(20_000_000_000_000n);
    const max = initial.constants.archiveProperties.maxActiveRecords;

    let peak = initial.localLedgerSize;
    await transferUntil(pic, ledger, owner, holder, async () => {
      const s = await read.stats();
      if (s.localLedgerSize > peak) peak = s.localLedgerSize;
      return s.archives.length > 0 && !s.bCleaning;
    });

    const after = await read.stats();
    // The ledger passed its bound, and archiving brought it back under it.
    expect(peak).toBeGreaterThan(max);
    expect(after.localLedgerSize).toBeLessThan(peak);
    expect(after.localLedgerSize).toBeLessThanOrEqual(max);
    expect(after.archives.length).toBe(1);
    const [archiveId, range] = after.archives[0];
    expect(range.start).toBe(0n);
    expect(range.length).toBeGreaterThan(0n);
    // Every block is either on the ledger or in the archive.
    expect(range.length + after.localLedgerSize).toBe(after.lastIndex + 1n);
    // The same archive `icrc3_get_archives` lists.
    expect((await archives(ledger, ledgerId)).map((a) => a.canister_id.toText())).toEqual([archiveId.toText()]);
  }, 300_000);

  it('counter-proof: with a balance under 2 × archiveCycles no archive is created and localLedgerSize stays above maxActiveRecords', async () => {
    const owner = createIdentity(3).getPrincipal();
    const holder = createIdentity(4);
    const { id: ledgerId, actor: ledger } = await installLedger(
      pic, TOKEN_WASM, owner, smallArchiveArgs({ archiveCycles: UNAFFORDABLE_ARCHIVE_CYCLES }),
    );
    const read = reader(ledgerId);

    const initial = await read.stats();
    expect(initial.constants.archiveProperties.archiveCycles).toBe(UNAFFORDABLE_ARCHIVE_CYCLES);
    // The precondition, measured rather than assumed.
    expect(await read.cycles()).toBeLessThan(2n * UNAFFORDABLE_ARCHIVE_CYCLES);
    expect(await read.cycles()).toBeLessThanOrEqual(LEDGER_CYCLES);
    const max = initial.constants.archiveProperties.maxActiveRecords;

    // Well past the bound, with every archiving pass given its ticks. An
    // archive showing up also stops it, so that a ledger that can pay for one
    // fails on the assertions below rather than on the transfer count.
    await transferUntil(pic, ledger, owner, holder, async () => {
      const s = await read.stats();
      return s.localLedgerSize > max + 20n || s.archives.length > 0;
    });
    for (let i = 0; i < 10; i++) await pic.tick();

    const after = await read.stats();
    expect(after.archives).toEqual([]);
    expect(after.bCleaning).toBe(false);
    expect(after.localLedgerSize).toBeGreaterThan(max);
    expect(after.localLedgerSize).toBe(after.lastIndex + 1n);
    expect(await archives(ledger, ledgerId)).toEqual([]);
  }, 300_000);
});
