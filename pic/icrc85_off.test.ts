/**
 * `src/Token.mo` ships with ICRC-85 Open Value Sharing OFF: neither the ledger
 * nor any of its archives sends cycles, through any stream, from install onward
 * and after an upgrade from a build that did share.
 *
 * The production `src/Token.mo` is tested UNCHANGED. The collector is created
 * at the library's default collector id (`archive_harness.DEFAULT_COLLECTOR`),
 * which is where an unconfigured ledger sends its shares. A balance check with
 * the default collector absent would prove nothing: a send to a missing
 * canister is refunded. So every "nothing was sent" below is paired with a
 * positive control in the same harness that sees a paying ledger.
 *
 * Streams and the namespace each one reports to the collector:
 *   ledger   icrc1 `org.icdevs.icrc85.icrc1`, icrc3 `org.icdevs.icrc85.icrc3`,
 *            TimerTool `org.icdevs.icrc85.supertimer`
 *   archive  TimerTool `org.icdevs.icrc85.supertimer`, ovs-fixed
 *            `org.icdevs.icrc85.icrc3archive` (told apart by the caller)
 *
 * Wasms: `bash pic/build-token-wasm.sh` (current) and
 * `bash pic/build-baseline-wasm.sh` (the library before the switch-off).
 * TOKEN_WASM / BASELINE_TOKEN_WASM point at other builds.
 *
 * Also here: a new archive gets the ledger's current owner as a controller,
 * read in a self-message sent after the archive exists.
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { readFileSync } from 'fs';
import {
  NAMESPACES, advanceDays, countByStream, trace, archiveBlocks, archiveIdl, archives, countByNamespace, createIdentity,
  expectAllUpgraded, installCollector, installLedger, ledgerIdl, smallArchiveArgs, tokenInitType, transferUntil,
  upgradeLedger, wasmPath,
} from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');
const BASELINE_WASM = wasmPath('BASELINE_TOKEN_WASM', 'token_baseline');
const ICRC85_WASM = wasmPath('ICRC85_WASM', 'token_icrc85');

const LEDGER_STREAMS = [NAMESPACES.icrc1, NAMESPACES.icrc3, NAMESPACES.timerTool];
const ARCHIVE_STREAMS = [NAMESPACES.timerTool, NAMESPACES.archive];

const owner = createIdentity(1).getPrincipal();
const holder = createIdentity(2);

const sorted = (ps: Principal[]) => ps.map((p) => p.toText()).sort();

/** Asserts `after` has no more notifications than `before`, per namespace, naming the stream. */
function expectNoGrowth(before: Record<string, number>, after: Record<string, number>, what: string) {
  for (const ns of new Set([...Object.keys(before), ...Object.keys(after)])) {
    expect(after[ns] ?? 0, `${what}: stream ${ns} sent cycles`).toBe(before[ns] ?? 0);
  }
}

// ONE server for the whole file. `PocketIcServer.start` names its port file
// after `process.ppid`, so a second `start` in the same process can read the
// port of a server already stopped and hang.
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

describe('ICRC-85 is off', () => {
  it('positive control: the baseline ledger pays the default collector on every ledger stream', async () => {
    const collector = await installCollector(pic);
    const { id } = await installLedger(pic, BASELINE_WASM, owner, null);
    await advanceDays(pic, 8);
    const counts = await countByNamespace(collector, id);
    for (const ns of LEDGER_STREAMS) {
      expect(counts[ns] ?? 0, `baseline stream ${ns} should pay`).toBeGreaterThanOrEqual(1);
    }
  });

  it('a fresh ledger sends nothing, on any stream', async () => {
    const collector = await installCollector(pic);
    await installLedger(pic, TOKEN_WASM, owner, null);
    for (const days of [8, 31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth({}, await countByStream(collector), `fresh ledger, +${days}d`);
    }
  });

  it('a share queued by the baseline sends nothing after the upgrade', async () => {
    const collector = await installCollector(pic);
    const { id, actor: ledger } = await installLedger(pic, BASELINE_WASM, owner, null);
    await advanceDays(pic, 8);
    const before = await countByNamespace(collector, id);
    for (const ns of LEDGER_STREAMS) {
      expect(before[ns] ?? 0, `baseline stream ${ns} paid before the upgrade`).toBeGreaterThanOrEqual(1);
    }

    await upgradeLedger(pic, id, TOKEN_WASM, owner, null);
    const streamsBefore = await countByStream(collector);

    // The upgrade drops the IC timer behind TimerTool, and `Token.mo`'s
    // postupgrade arms it again for the earliest queued action, the share the
    // baseline queued included. This test still goes through the realistic
    // path of a live ledger: an index is configured and a block is added, so
    // the index push queues a TimerTool action too. That traffic is no longer
    // what wakes the queue. No canister lives at the index id; the failed push
    // is handled.
    const admin = pic.createActor<any>(({ IDL }) => IDL.Service({
      admin_set_index_canister: IDL.Func([IDL.Opt(IDL.Principal)], [IDL.Bool], []),
    }), id);
    admin.setPrincipal(owner);
    expect(await admin.admin_set_index_canister([createIdentity(3).getPrincipal()])).toBe(true);
    let transfers = 0;
    await transferUntil(pic, ledger, owner, holder, async () => transfers++ >= 1);

    // Witness, in this run, that the timer was armed again and the queued share
    // ran. ovs-fixed reschedules the share (a new `nextCycleActionId`) before it
    // returns on the kill switch, so the id changes whether the share pays or
    // not. Without it, a ledger whose timer never fires again after the upgrade
    // would leave this test green.
    const stats = pic.createActor<any>(({ IDL }) => IDL.Service({
      get_icrc85_stats: IDL.Func([], [IDL.Record({
        activeActions: IDL.Nat, lastActionReported: IDL.Opt(IDL.Nat), nextCycleActionId: IDL.Opt(IDL.Nat),
      })], ['query']),
    }), id);
    const queued = (await stats.get_icrc85_stats()).nextCycleActionId;
    expect(queued, 'the baseline queued an icrc1 share').toHaveLength(1);

    for (const days of [31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth(streamsBefore, await countByStream(collector), `after the upgrade, +${days}d`);
      const next = (await stats.get_icrc85_stats()).nextCycleActionId;
      expect(next, `after the upgrade, +${days}d: the queued share was rescheduled`).toHaveLength(1);
      expect(next[0], `after the upgrade, +${days}d: the queued share ran`).not.toBe(queued[0]);
    }
  });

  it('new archives send nothing, the first and the next', async () => {
    const collector = await installCollector(pic);
    const { id, actor: ledger } = await installLedger(pic, TOKEN_WASM, owner, smallArchiveArgs({ perArchive: 60 }));
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 2);
    const list = await archives(ledger, id);

    for (const days of [8, 31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth({}, await countByStream(collector), `ledger with ${list.length} archives, +${days}d`);
    }
  });

  it('an archive created by the baseline pays until upgradeArchive, then stops and keeps its blocks', async () => {
    const collector = await installCollector(pic);
    const { id, actor: ledger } = await installLedger(pic, BASELINE_WASM, owner, smallArchiveArgs({ perArchive: 60 }));
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 2);
    const list = await archives(ledger, id);

    // Positive control for the archive streams.
    await advanceDays(pic, 8);
    for (const a of list) {
      const counts = await countByNamespace(collector, a.canister_id);
      for (const ns of ARCHIVE_STREAMS) {
        expect(counts[ns] ?? 0, `baseline archive ${a.canister_id.toText()} stream ${ns} should pay`).toBeGreaterThanOrEqual(1);
      }
    }

    const blocksBefore: string[] = [];
    for (const a of list) {
      const archive = pic.createActor<any>(archiveIdl, a.canister_id);
      const stats = await archive.get_stats();
      blocksBefore.push(await archiveBlocks(archive, stats.first_block_index, stats.total_records));
    }

    trace('upgrade ledger');
    await upgradeLedger(pic, id, TOKEN_WASM, owner, smallArchiveArgs({ perArchive: 60 }));
    ledger.setPrincipal(owner);
    trace('upgradeArchive');
    expectAllUpgraded(await ledger.upgradeArchive(false), list);
    trace('upgradeArchive returned');
    for (let i = 0; i < 5; i++) await pic.tick();
    expect(await ledger.getUpgradeError()).toBe('');

    const before = await countByStream(collector);
    for (const days of [31, 31]) {
      await advanceDays(pic, days);
      expectNoGrowth(before, await countByStream(collector), `after upgradeArchive, +${days}d`);
    }

    for (const [i, a] of list.entries()) {
      const archive = pic.createActor<any>(archiveIdl, a.canister_id);
      const stats = await archive.get_stats();
      expect(await archiveBlocks(archive, stats.first_block_index, stats.total_records), `blocks of ${a.canister_id.toText()}`)
        .toBe(blocksBefore[i]);
    }
  });

  it('an archive created with the switch null stops after upgradeArchiveWith(?true): true wins', async () => {
    // The archive already has its `icrc85_kill_switch` variable, set to null
    // because its ledger (pic/TokenWithICRC85.mo) leaves the switch unset. Its
    // initialiser does not run again on upgrade; only the "true wins" statement
    // can turn the switch on.
    const collector = await installCollector(pic);
    const [tokenArgs] = smallArchiveArgs({ perArchive: 60 }) as any[];
    const fixtureInit = IDL.Opt(IDL.Record({
      icrc1: IDL.Opt(IDL.Null),
      icrc2: IDL.Opt(IDL.Null),
      icrc3: (tokenInitType() as any)._type._fields.find(([k]: [string]) => k === 'icrc3')[1]._type,
      icrc4: IDL.Opt(IDL.Null),
      icrc85_collector: IDL.Opt(IDL.Principal),
    }));
    const id = await pic.createCanister({ sender: owner, cycles: 500_000_000_000_000n });
    await pic.installCode({
      canisterId: id,
      wasm: readFileSync(ICRC85_WASM),
      arg: new Uint8Array(IDL.encode([fixtureInit], [[{ ...tokenArgs, icrc3: tokenArgs.icrc3[0], icrc85_collector: [] }]])),
      sender: owner,
    });
    for (let i = 0; i < 5; i++) await pic.tick();
    const ledger = pic.createActor<any>(ledgerIdl, id);
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 1);
    const list = await archives(ledger, id);

    // Positive control: the archive pays on both of its streams.
    await advanceDays(pic, 8);
    for (const a of list) {
      const counts = await countByNamespace(collector, a.canister_id);
      for (const ns of ARCHIVE_STREAMS) {
        expect(counts[ns] ?? 0, `null-switch archive ${a.canister_id.toText()} stream ${ns} should pay`).toBeGreaterThanOrEqual(1);
      }
    }

    // `Token.mo` upgrades its archives with `upgradeArchiveWith(…, ?true)`.
    await upgradeLedger(pic, id, TOKEN_WASM, owner, smallArchiveArgs({ perArchive: 60 }));
    ledger.setPrincipal(owner);
    expectAllUpgraded(await ledger.upgradeArchive(false), list);
    for (let i = 0; i < 5; i++) await pic.tick();
    expect(await ledger.getUpgradeError()).toBe('');

    const before: Record<string, Record<string, number>> = {};
    for (const a of list) before[a.canister_id.toText()] = await countByNamespace(collector, a.canister_id);
    for (const days of [31, 31]) {
      await advanceDays(pic, days);
      for (const a of list) {
        expectNoGrowth(before[a.canister_id.toText()], await countByNamespace(collector, a.canister_id),
          `archive ${a.canister_id.toText()} after upgradeArchiveWith(?true), +${days}d`);
      }
    }
  });
});

describe('a new archive is controlled by the owner read after it exists', () => {
  it('configured set ∪ {ledger, owner}, and the next archive follows a hand-off', async () => {
    const configured = createIdentity(7).getPrincipal();
    const next = createIdentity(8).getPrincipal();
    const { id, actor: ledger } = await installLedger(
      pic, TOKEN_WASM, owner, smallArchiveArgs({ perArchive: 60, controllers: [configured] }),
    );

    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 1);
    for (let i = 0; i < 5; i++) await pic.tick();
    const [first] = await archives(ledger, id);
    expect(sorted(await pic.getControllers(first.canister_id)), 'first archive')
      .toEqual(sorted([configured, id, owner]));

    // A proposal alone moves nothing: the archive created while it is pending
    // gets the owner that proposed, and not the proposed principal.
    ledger.setPrincipal(owner);
    await ledger.admin_propose_owner([next]);
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 2);
    for (let i = 0; i < 5; i++) await pic.tick();
    const known = new Set([first.canister_id.toText()]);
    const pending = (await archives(ledger, id)).find((a) => !known.has(a.canister_id.toText()))!;
    known.add(pending.canister_id.toText());
    expect(sorted(await pic.getControllers(pending.canister_id)), 'archive created during a pending hand-off')
      .toEqual(sorted([configured, id, owner]));

    ledger.setPrincipal(next);
    await ledger.accept_ownership();
    expect((await ledger.get_owner()).toText()).toBe(next.toText());

    // No mint after the hand-off: `mint` needs the current owner AND the
    // minting account, which stays the installer. The holder has enough.
    await transferUntil(pic, ledger, next, holder, async () => (await archives(ledger, id)).length >= 3, 600, false);
    for (let i = 0; i < 5; i++) await pic.tick();
    const second = (await archives(ledger, id)).find((a) => !known.has(a.canister_id.toText()))!;
    expect(sorted(await pic.getControllers(second.canister_id)), 'archive created after the hand-off')
      .toEqual(sorted([configured, id, next]));
    expect(sorted(await pic.getControllers(first.canister_id)), 'first archive, unchanged by the hand-off')
      .toEqual(sorted([configured, id, owner]));
  });

  it('`archiveControllers = null` is unmanaged: only the ledger controls a new archive', async () => {
    const { id, actor: ledger } = await installLedger(
      pic, TOKEN_WASM, owner, smallArchiveArgs({ perArchive: 60, controllers: 'unmanaged' }),
    );
    await transferUntil(pic, ledger, owner, holder, async () => (await archives(ledger, id)).length >= 1);
    for (let i = 0; i < 5; i++) await pic.tick();
    const [first] = await archives(ledger, id);
    expect(sorted(await pic.getControllers(first.canister_id))).toEqual(sorted([id]));
  });
});
