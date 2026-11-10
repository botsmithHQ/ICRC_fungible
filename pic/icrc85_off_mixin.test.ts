/**
 * `src/token-mixin.mo` ships with ICRC-85 Open Value Sharing OFF, as
 * `src/Token.mo` does (pic/icrc85_off.test.ts): neither the ledger nor any of
 * its archives sends cycles, through any stream, from install onward and after
 * an upgrade from a build that did share.
 *
 * The production `src/token-mixin.mo` is tested UNCHANGED. The collector is
 * created at the library's default collector id, which is where an
 * unconfigured ledger sends its shares, and every "nothing was sent" is paired
 * with a positive control in the same harness that sees a paying mixin ledger.
 *
 * The paying mixin is `token_mixin_pre_refusal`: `src/token-mixin.mo` at
 * 5ff1d78, built by pic/build-token-wasm.sh for the owner guard tests. Its
 * three ICRC-85 switches are `null`, which every library reads as ON, as were
 * the mixin's switches up to the commit that turned them off.
 *
 * Wasms: `bash pic/build-token-wasm.sh`. TOKEN_MIXIN_WASM and
 * TOKEN_MIXIN_ICRC85_ON_WASM point at other builds.
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { readFileSync } from 'fs';
import {
  EOP_UPGRADE, NAMESPACES, advanceDays, archives, countByNamespace, countByStream, createIdentity,
  installCollector, ledgerIdl, transferUntil, wasmPath,
} from './archive_harness';

const MIXIN_WASM = wasmPath('TOKEN_MIXIN_WASM', 'token-mixin');
const MIXIN_ON_WASM = wasmPath('TOKEN_MIXIN_ICRC85_ON_WASM', 'token_mixin_pre_refusal');

const LEDGER_STREAMS = [NAMESPACES.icrc1, NAMESPACES.icrc3, NAMESPACES.timerTool];

const owner = createIdentity(1).getPrincipal();
const holder = createIdentity(2);

// The mixin's class argument: unlike `Token.mo`, its `icrc3` section is not
// optional, so `archive_harness.installLedger` cannot encode small archives.
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

/** `null`: the mixin's defaults. `smallArchives`: ~50 records on the ledger, 60 per archive. */
type Args = null | 'smallArchives';

function encodeArgs(args: Args): Uint8Array {
  if (args === null) return new Uint8Array(IDL.encode([MixinArgs], [[]]));
  return new Uint8Array(IDL.encode([MixinArgs], [[{
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
}

async function installMixin(pic: PocketIc, wasm: string, args: Args) {
  const id = await pic.createCanister({ sender: owner, cycles: 500_000_000_000_000n });
  await pic.installCode({ canisterId: id, wasm: readFileSync(wasm), arg: encodeArgs(args), sender: owner });
  for (let i = 0; i < 5; i++) await pic.tick();
  const actor = pic.createActor<any>(ledgerIdl, id);
  actor.setPrincipal(owner);
  return { id, actor };
}

const statsIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  get_icrc85_stats: IDL.Func([], [IDL.Record({
    activeActions: IDL.Nat, lastActionReported: IDL.Opt(IDL.Nat), nextCycleActionId: IDL.Opt(IDL.Nat),
  })], ['query']),
  admin_set_index_canister: IDL.Func([IDL.Opt(IDL.Principal)], [IDL.Bool], []),
});

/** Asserts `after` has no more notifications than `before`, per stream, naming it. */
function expectNoGrowth(before: Record<string, number>, after: Record<string, number>, what: string) {
  for (const ns of new Set([...Object.keys(before), ...Object.keys(after)])) {
    expect(after[ns] ?? 0, `${what}: stream ${ns} sent cycles`).toBe(before[ns] ?? 0);
  }
}

// ONE server for the whole file (see pic/icrc85_off.test.ts).
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

describe('ICRC-85 is off in token-mixin', () => {
  it('positive control: a mixin with its switches null pays the default collector on every ledger stream', async () => {
    const collector = await installCollector(pic);
    const { id } = await installMixin(pic, MIXIN_ON_WASM, null);
    await advanceDays(pic, 8);
    const counts = await countByNamespace(collector, id);
    for (const ns of LEDGER_STREAMS) {
      expect(counts[ns] ?? 0, `paying mixin stream ${ns} should pay`).toBeGreaterThanOrEqual(1);
    }
  });

  it('a fresh ledger sends nothing, on any stream', async () => {
    const collector = await installCollector(pic);
    await installMixin(pic, MIXIN_WASM, null);
    for (const days of [8, 31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth({}, await countByStream(collector), `fresh mixin ledger, +${days}d`);
    }
  });

  it('a share queued by the paying mixin sends nothing after the upgrade', async () => {
    const collector = await installCollector(pic);
    const { id, actor: ledger } = await installMixin(pic, MIXIN_ON_WASM, null);
    await advanceDays(pic, 8);
    const before = await countByNamespace(collector, id);
    for (const ns of LEDGER_STREAMS) {
      expect(before[ns] ?? 0, `paying mixin stream ${ns} paid before the upgrade`).toBeGreaterThanOrEqual(1);
    }

    await pic.upgradeCanister({
      canisterId: id, wasm: readFileSync(MIXIN_WASM), arg: encodeArgs(null), sender: owner, upgradeModeOptions: EOP_UPGRADE,
    });
    for (let i = 0; i < 5; i++) await pic.tick();
    const streamsBefore = await countByStream(collector);

    // A live ledger after the upgrade: an index is configured and a block is
    // added, so the index push queues a TimerTool action too. No canister
    // lives at the index id; the failed push is handled.
    const admin = pic.createActor<any>(statsIdl, id);
    admin.setPrincipal(owner);
    expect(await admin.admin_set_index_canister([createIdentity(3).getPrincipal()])).toBe(true);
    let transfers = 0;
    await transferUntil(pic, ledger, owner, holder, async () => transfers++ >= 1);

    // Witness that TimerTool's queue woke again after the upgrade and the
    // queued share ran. The mixin has no re-arm of its own: the ClassPlus
    // manager initializes TimerTool again on every upgrade. ovs-fixed
    // reschedules the share (a new `nextCycleActionId`) before it returns on
    // the kill switch, so the id changes whether the share pays or not.
    const queued = (await admin.get_icrc85_stats()).nextCycleActionId;
    expect(queued, 'the paying mixin queued an icrc1 share').toHaveLength(1);

    for (const days of [31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth(streamsBefore, await countByStream(collector), `after the upgrade, +${days}d`);
      const next = (await admin.get_icrc85_stats()).nextCycleActionId;
      expect(next, `after the upgrade, +${days}d: the queued share was rescheduled`).toHaveLength(1);
      expect(next[0], `after the upgrade, +${days}d: the queued share ran`).not.toBe(queued[0]);
    }
  });

  it('new archives send nothing, the first and the next', async () => {
    const collector = await installCollector(pic);
    const { id, actor: ledger } = await installMixin(pic, MIXIN_WASM, 'smallArchives');
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 2);
    const list = await archives(ledger, id);
    expect(list.length).toBeGreaterThanOrEqual(2);

    for (const days of [8, 31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth({}, await countByStream(collector), `mixin ledger with ${list.length} archives, +${days}d`);
    }
  });
});
