/**
 * Block reads are capped in the body (`src/Token.mo`, MAX_BLOCKS_PER_CALL).
 *
 * `icrc3_get_blocks`, `get_blocks` and `get_transactions` are queries, but a
 * call from another canister, or one sent as an update, runs replicated and
 * the ledger pays for it. `inspect` never sees a call from a canister, so the
 * size of a read is bounded where every caller goes through: the body. A
 * request for more than 2 000 blocks, over all its ranges, gets the first
 * 2 000 of what it asked for, in order (ICRC-3 lets a ledger return fewer
 * blocks than requested), and the client asks again from where it stopped.
 *
 *  (a) a canister asks for 10 000 blocks, or 50 ranges of 200: it gets 2 000,
 *      and the ledger pays for 2 000;
 *  (b) a request under the cap gets what it asked for;
 *  (c) a start + length past 2^64 does not trap;
 *  (d) a client that pages by what it was given, and the Motoko index, both
 *      reach the end of a ledger with archives.
 *
 * Counterproof: `TOKEN_WASM=<a build without capBlockRanges / capBlockRange>
 * npx vitest run get_blocks_cap.test.ts` turns (a) red.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { resolve } from 'path';
import { readFileSync, existsSync } from 'fs';
import { createIdentity, installLedger, wasmPath } from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');
const RAW_CALLER_WASM = wasmPath('RAW_CALLER_WASM', 'raw_caller');
const INDEX_WASM = resolve(__dirname, '../../index.mo/.dfx/local/canisters/icrc_index/icrc_index.wasm.gz');

const CAP = 2_000;
const BATCH = 200; // the ledger's default `max_transfers`
const U64_MAX = 2n ** 64n - 1n;

// =============== IDL ===============

const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });
const TransactionRange = IDL.Record({ start: IDL.Nat, length: IDL.Nat });
const GetBlocksArgs = IDL.Vec(TransactionRange);
const LegacyArgs = IDL.Record({ start: IDL.Nat, length: IDL.Nat });

// Decoding skips the fields not listed, and `Reserved` takes any block.
const BlocksOnly = IDL.Record({ log_length: IDL.Nat, blocks: IDL.Vec(IDL.Record({ id: IDL.Nat, block: IDL.Reserved })) });
const GetBlocksResult = IDL.Record({
  log_length: IDL.Nat,
  blocks: IDL.Vec(IDL.Record({ id: IDL.Nat, block: IDL.Reserved })),
  archived_blocks: IDL.Vec(IDL.Record({
    args: GetBlocksArgs,
    callback: IDL.Func([GetBlocksArgs], [BlocksOnly], ['query']),
  })),
});
const RosettaBlocks = IDL.Record({
  chain_length: IDL.Nat64, first_index: IDL.Nat, blocks: IDL.Vec(IDL.Reserved), archived_blocks: IDL.Vec(IDL.Reserved),
});
const LegacyTransactions = IDL.Record({
  log_length: IDL.Nat, first_index: IDL.Nat, transactions: IDL.Vec(IDL.Reserved), archived_transactions: IDL.Vec(IDL.Reserved),
});

const TransferArg = IDL.Record({
  from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  to: Account,
  amount: IDL.Nat,
  fee: IDL.Opt(IDL.Nat),
  memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
  created_at_time: IDL.Opt(IDL.Nat64),
});
const BatchResult = IDL.Vec(IDL.Opt(IDL.Variant({ Ok: IDL.Nat, Err: IDL.Reserved })));

const IndexInit = IDL.Opt(IDL.Variant({
  Init: IDL.Record({
    ledger_id: IDL.Principal,
    retrieve_blocks_from_ledger_interval_seconds: IDL.Opt(IDL.Nat64),
  }),
  Upgrade: IDL.Record({
    ledger_id: IDL.Opt(IDL.Principal),
    retrieve_blocks_from_ledger_interval_seconds: IDL.Opt(IDL.Nat64),
  }),
}));
const IndexStatus = IDL.Record({ num_blocks_synced: IDL.Nat64 });

type Range = { start: bigint; length: bigint };
type Blocks = { log_length: bigint; blocks: { id: bigint }[]; archived_blocks: { args: Range[]; callback: [Principal, string] }[] };

const enc = (types: IDL.Type[], values: unknown[]) => new Uint8Array(IDL.encode(types, values));
const ids = (from: number, count: number) => Array.from({ length: count }, (_, i) => BigInt(from + i));
const idsOf = (r: { blocks: { id: bigint }[] }) => r.blocks.map((b) => b.id);

// =============== Fixture ===============

const owner = createIdentity(1).getPrincipal(); // installs: the owner and the minting account
const holder = createIdentity(5).getPrincipal();
const stranger = createIdentity(3).getPrincipal();
const RECIPIENT = createIdentity(9).getPrincipal();

function icrc3Args(maxActiveRecords: bigint, settleToRecords: bigint, maxRecordsToArchive: bigint) {
  return [{
    icrc1: [],
    icrc2: [],
    icrc3: [{
      maxActiveRecords,
      settleToRecords,
      maxRecordsInArchiveInstance: 100_000n,
      maxArchivePages: 62_500n,
      archiveIndexType: { Stable: null },
      maxRecordsToArchive,
      archiveCycles: 20_000_000_000_000n,
      archiveControllers: [],
      supportedBlocks: [],
    }],
    icrc4: [],
  }];
}

class Chain {
  private constructor(readonly pic: PocketIc, readonly id: Principal, readonly raw: Principal) {}

  static async create(pic: PocketIc, args: unknown[]): Promise<Chain> {
    const { id, actor } = await installLedger(pic, TOKEN_WASM, owner, args);
    const raw = await pic.createCanister({ sender: owner, cycles: 10_000_000_000_000n });
    await pic.installCode({ canisterId: raw, wasm: readFileSync(RAW_CALLER_WASM), arg: enc([], []), sender: owner });
    const minted = await actor.mint({ to: { owner: holder, subaccount: [] }, amount: 1_000_000_000_000n, memo: [], created_at_time: [] });
    expect('Ok' in minted).toBe(true);
    return new Chain(pic, id, raw);
  }

  /** `batches` × 200 transfers, one block each. */
  async addBlocks(batches: number) {
    for (let b = 0; b < batches; b++) {
      const transfers = Array.from({ length: BATCH }, (_, i) => ({
        from_subaccount: [], to: { owner: RECIPIENT, subaccount: [] }, amount: BigInt(1 + i), fee: [], memo: [], created_at_time: [],
      }));
      const reply = await this.pic.updateCall({ canisterId: this.id, method: 'icrc4_transfer_batch', arg: enc([IDL.Vec(TransferArg)], [transfers]), sender: holder });
      const results = IDL.decode([BatchResult], reply)[0] as any[];
      expect(results.length).toBe(BATCH);
      for (const r of results) expect(r[0] && 'Ok' in r[0]).toBe(true);
    }
  }

  /** `method` called by another canister: the reply bytes, or a throw if the ledger trapped. */
  async via(method: string, arg: Uint8Array): Promise<Uint8Array> {
    const reply = await this.pic.updateCall({
      canisterId: this.raw, method: 'call', sender: stranger,
      arg: enc([IDL.Principal, IDL.Text, IDL.Vec(IDL.Nat8)], [this.id, method, arg]),
    });
    return new Uint8Array(IDL.decode([IDL.Vec(IDL.Nat8)], reply)[0] as any);
  }

  getBlocks = async (ranges: Range[]): Promise<Blocks> =>
    IDL.decode([GetBlocksResult], await this.via('icrc3_get_blocks', enc([GetBlocksArgs], [ranges])))[0] as any;
  legacyBlocks = async (start: bigint, length: bigint): Promise<any> =>
    IDL.decode([RosettaBlocks], await this.via('get_blocks', enc([LegacyArgs], [{ start, length }])))[0];
  legacyTransactions = async (start: bigint, length: bigint): Promise<any> =>
    IDL.decode([LegacyTransactions], await this.via('get_transactions', enc([LegacyArgs], [{ start, length }])))[0];

  balance = async () => BigInt(await this.pic.getCyclesBalance(this.id));

  /** What the LEDGER spent (not the caller) while `work` ran. */
  async spent<T>(work: () => Promise<T>): Promise<[bigint, T]> {
    const before = await this.balance();
    const result = await work();
    return [before - (await this.balance()), result];
  }
}

let server: PocketIcServer;

beforeAll(async () => { server = await PocketIcServer.start(); });
afterAll(async () => { await server?.stop(); });

async function newPic(): Promise<PocketIc> {
  return PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
}

// =============== (a) (b) (c): 10 001 blocks, all on the ledger ===============

describe('block reads: at most 2 000 blocks per call, from any caller', () => {
  let pic: PocketIc;
  let c: Chain;
  const LOG = 1 + 50 * BATCH; // the mint and 10 000 transfers

  beforeAll(async () => {
    pic = await newPic();
    // No archive: every block stays on the ledger, so the reads cost what they serve.
    c = await Chain.create(pic, icrc3Args(20_000n, 10_000n, 10_000n));
    await c.addBlocks(50);
    for (let i = 0; i < 3; i++) await pic.tick();
    const tip = await c.getBlocks([{ start: 0n, length: 0n }]);
    expect(tip.log_length).toBe(BigInt(LOG));
  }, 600_000);

  afterAll(async () => { await pic?.tearDown(); });

  it('(a) a canister asking for 10 000 blocks gets the first 2 000, and the ledger pays for 2 000', async () => {
    const [atCap, capped] = await c.spent(() => c.getBlocks([{ start: 0n, length: BigInt(CAP) }]));
    // A ledger without the cap may trap once the reply passes 2 MiB, after the
    // work: what it spent is measured either way.
    const [asked10k, reply] = await c.spent(() => c.getBlocks([{ start: 0n, length: 10_000n }]).catch((e: Error) => e));
    console.log(`ledger cycles: icrc3_get_blocks 2 000 → ${atCap}, 10 000 → ${asked10k}${reply instanceof Error ? ' (trapped)' : ''}`);
    expect(reply).not.toBeInstanceOf(Error);
    const r = reply as Blocks;
    expect(r.log_length).toBe(BigInt(LOG));
    expect(idsOf(r)).toEqual(ids(0, CAP));
    expect(r.archived_blocks).toEqual([]);
    expect(idsOf(capped)).toEqual(ids(0, CAP));
    // Asking for five times more costs no more than asking for the cap.
    expect(asked10k).toBeLessThan((atCap * 12n) / 10n);
  });

  it('(a) 50 ranges of 200: the first ranges, in the order asked, up to 2 000 blocks', async () => {
    // Descending starts, so "the first" means the order of the request, not of the chain.
    const ranges = Array.from({ length: 50 }, (_, i) => ({ start: BigInt(9_800 - i * 200), length: 200n }));
    const [spent, r] = await c.spent(() => c.getBlocks(ranges));
    console.log(`ledger cycles: icrc3_get_blocks 50 × 200 → ${spent}`);
    expect(idsOf(r)).toEqual(Array.from({ length: 10 }, (_, i) => ids(9_800 - i * 200, 200)).flat());
    // One over the cap: only the tail of the last range goes.
    expect(idsOf(await c.getBlocks([{ start: 0n, length: 1_000n }, { start: 3_000n, length: 1_001n }])))
      .toEqual([...ids(0, 1_000), ...ids(3_000, 1_000)]);
  });

  it('(a) get_blocks and get_transactions: 10 000 asked, 2 000 served', async () => {
    const [spentBlocks, blocks] = await c.spent(() => c.legacyBlocks(0n, 10_000n));
    const [spentTxs, txs] = await c.spent(() => c.legacyTransactions(0n, 10_000n));
    console.log(`ledger cycles: get_blocks 10 000 → ${spentBlocks}, get_transactions 10 000 → ${spentTxs}`);
    expect(blocks.blocks.length).toBe(CAP);
    expect(blocks.first_index).toBe(0n);
    expect(blocks.chain_length).toBe(BigInt(LOG));
    expect(txs.transactions.length).toBe(CAP);
    expect(txs.first_index).toBe(0n);
    expect(txs.log_length).toBe(BigInt(LOG));
  });

  it('(a) the same cap for an ingress update and for a query', async () => {
    const arg = enc([GetBlocksArgs], [[{ start: 0n, length: 10_001n }]]);
    // `inspect` checks the shape of a block read, not its size: admitted, then capped.
    const update = IDL.decode([BlocksOnly], await pic.updateCall({ canisterId: c.id, method: 'icrc3_get_blocks', arg, sender: stranger }))[0] as any;
    const query = IDL.decode([BlocksOnly], await pic.queryCall({ canisterId: c.id, method: 'icrc3_get_blocks', arg, sender: stranger }))[0] as any;
    expect(idsOf(update)).toEqual(ids(0, CAP));
    expect(idsOf(query)).toEqual(ids(0, CAP));
  });

  // Green against a ledger without the cap too: under the cap, nothing changes.
  it('(b) a request under the cap gets exactly what it asked for', async () => {
    expect(idsOf(await c.getBlocks([{ start: 5n, length: 100n }]))).toEqual(ids(5, 100));
    expect(idsOf(await c.getBlocks([{ start: 0n, length: 10n }, { start: 50n, length: 20n }, { start: 10_000n, length: 5n }])))
      .toEqual([...ids(0, 10), ...ids(50, 20), 10_000n]);
    // Exactly the cap, over two ranges.
    expect(idsOf(await c.getBlocks([{ start: 0n, length: 1_000n }, { start: 3_000n, length: 1_000n }])))
      .toEqual([...ids(0, 1_000), ...ids(3_000, 1_000)]);
    // An empty range takes nothing from the others.
    expect(idsOf(await c.getBlocks([{ start: 0n, length: 0n }, { start: 7n, length: 3n }]))).toEqual(ids(7, 3));
    // The blocks themselves do not change: one read of 100 is two reads of 50.
    const whole = await c.via('icrc3_get_blocks', enc([GetBlocksArgs], [[{ start: 5n, length: 100n }]]));
    const halves = await c.via('icrc3_get_blocks', enc([GetBlocksArgs], [[{ start: 5n, length: 50n }, { start: 55n, length: 50n }]]));
    expect(Buffer.from(halves).equals(Buffer.from(whole))).toBe(true);

    const blocks = await c.legacyBlocks(5n, 100n);
    expect([blocks.first_index, blocks.blocks.length]).toEqual([5n, 100]);
    const txs = await c.legacyTransactions(5n, 100n);
    expect([txs.first_index, txs.transactions.length]).toEqual([5n, 100]);
  });

  it('(c) a start + length past 2^64 does not trap', async () => {
    const past = await c.getBlocks([{ start: U64_MAX, length: U64_MAX }]);
    expect([past.log_length, past.blocks.length]).toEqual([BigInt(LOG), 0]);
    expect(idsOf(await c.getBlocks([{ start: 0n, length: U64_MAX }, { start: 0n, length: U64_MAX }]))).toEqual(ids(0, CAP));
    expect(idsOf(await c.getBlocks([{ start: 10_000n, length: 2n ** 128n }]))).toEqual([10_000n]);
    // The largest numbers `inspect` admits from ingress, and bigger ones from a canister.
    const huge = 10n ** 40n - 1n;
    expect((await c.getBlocks([{ start: huge, length: huge }])).blocks).toEqual([]);
    expect((await c.getBlocks([{ start: 10n ** 60n, length: 10n ** 60n }])).blocks).toEqual([]);

    expect((await c.legacyBlocks(U64_MAX, U64_MAX)).blocks.length).toBe(0);
    expect((await c.legacyBlocks(0n, U64_MAX)).blocks.length).toBe(CAP);
    expect((await c.legacyTransactions(U64_MAX, U64_MAX)).transactions.length).toBe(0);
    expect((await c.legacyTransactions(0n, 2n ** 128n)).transactions.length).toBe(CAP);
  });
});

// =============== (d) a ledger with archives: clients reach the end ===============

describe('block reads with archives: a client and the index reach the end', () => {
  let pic: PocketIc;
  let c: Chain;
  const LOG = 1 + 13 * BATCH; // 2 601 blocks, more than one capped read

  beforeAll(async () => {
    pic = await newPic();
    // At most 1 000 blocks on the ledger: the rest goes to an archive.
    c = await Chain.create(pic, icrc3Args(1_000n, 500n, 100n));
    await c.addBlocks(13);
    let archived = false;
    for (let i = 0; i < 120 && !archived; i++) {
      await pic.advanceTime(1_000);
      await pic.tick();
      archived = (await c.getBlocks([{ start: 0n, length: 1n }])).archived_blocks.length > 0;
    }
    expect(archived, 'block 0 never reached an archive').toBe(true);
  }, 600_000);

  afterAll(async () => { await pic?.tearDown(); });

  /** One read as an index makes it: archived ranges first, from their archive, then the ledger's. */
  async function read(start: bigint, length: bigint): Promise<{ log: bigint; got: bigint[] }> {
    const r = await c.getBlocks([{ start, length }]);
    const got: bigint[] = [];
    for (const a of r.archived_blocks) {
      const [archive, method] = a.callback;
      const reply = await pic.queryCall({ canisterId: archive, method, arg: enc([GetBlocksArgs], [a.args]), sender: stranger });
      got.push(...idsOf(IDL.decode([BlocksOnly], reply)[0] as any));
    }
    got.push(...idsOf(r));
    return { log: r.log_length, got };
  }

  it('a client asking for 10 000 at a time, and moving on by what it got, reaches the end', async () => {
    let start = 0n;
    let calls = 0;
    const seen: bigint[] = [];
    for (;;) {
      const { log, got } = await read(start, 10_000n);
      calls++;
      expect(got.length).toBeGreaterThan(0);
      expect(got.length).toBeLessThanOrEqual(CAP);
      seen.push(...got);
      start += BigInt(got.length);
      if (start >= log) break;
      expect(calls).toBeLessThan(10);
    }
    expect(calls).toBe(Math.ceil(LOG / CAP));
    expect(seen).toEqual(ids(0, LOG));
  });

  it('an empty range that starts inside an archive takes nothing and traps nothing', async () => {
    // The library traps on such a range; the cap drops it before the library sees it.
    const r = await c.getBlocks([{ start: 5n, length: 0n }, { start: 0n, length: 3n }]);
    expect(r.archived_blocks.flatMap((a) => a.args)).toEqual([{ start: 0n, length: 3n }]);
    // The legacy reads: no block, no archive, and the first index of an empty
    // read, the ledger's first local block (archiving goes on meanwhile, so
    // it is only known to be past block 5).
    const blocks = await c.legacyBlocks(5n, 0n);
    expect([blocks.blocks.length, blocks.archived_blocks.length, blocks.chain_length]).toEqual([0, 0, BigInt(LOG)]);
    expect(blocks.first_index).toBeGreaterThan(5n);
    const txs = await c.legacyTransactions(5n, 0n);
    expect([txs.transactions.length, txs.archived_transactions.length, txs.log_length]).toEqual([0, 0, BigInt(LOG)]);
    expect(txs.first_index).toBeGreaterThan(5n);
  });

  it('the Motoko index syncs every block, past the cap', async () => {
    expect(existsSync(INDEX_WASM), `index wasm not found at ${INDEX_WASM}: bash pic/build-index-wasm.sh`).toBe(true);
    const index = await pic.createCanister({ sender: owner, cycles: 100_000_000_000_000n });
    await pic.installCode({
      canisterId: index,
      wasm: readFileSync(INDEX_WASM),
      arg: enc([IndexInit], [[{ Init: { ledger_id: c.id, retrieve_blocks_from_ledger_interval_seconds: [1n] } }]]),
      sender: owner,
    });
    let synced = 0n;
    for (let i = 0; i < 200 && synced < BigInt(LOG); i++) {
      await pic.advanceTime(1_000);
      await pic.tick();
      const reply = await pic.queryCall({ canisterId: index, method: 'status', arg: enc([], []), sender: stranger });
      synced = (IDL.decode([IndexStatus], reply)[0] as any).num_blocks_synced;
    }
    expect(synced).toBe(BigInt(LOG));
  }, 300_000);
});
