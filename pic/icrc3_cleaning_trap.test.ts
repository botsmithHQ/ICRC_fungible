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
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { readFileSync } from 'fs';
import { IDL } from '@icp-sdk/core/candid';
import { Principal } from '@icp-sdk/core/principal';
import {
  archiveIdl, archives, createIdentity, encodeTokenArgs, ledgerIdl, smallArchiveArgs, transferUntil, wasmPath, DAY_MS,
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
