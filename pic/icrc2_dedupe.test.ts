/**
 * `icrc2_approve` and `icrc2_transfer_from` deduplicate only when the client sets
 * `created_at_time` (vendor/icrc2-mo, LOCAL PATCH "dedupe requires created_at_time").
 *
 * ICRC-1, "Transaction deduplication" (inherited by ICRC-2): "If the client did not
 * set the `created_at_time` field, the ledger SHOULD NOT deduplicate the transaction."
 * icrc1-mo already does so for `icrc1_transfer`. icrc2-mo 0.2.1 looked up the
 * duplicate hash whether or not `created_at_time` was set, so two identical calls
 * without it got `Duplicate` on the second.
 *
 * Each case pins one side:
 *   - without `created_at_time`, two identical calls both land (two blocks);
 *   - with the same `created_at_time`, the second is `Duplicate` of the first and
 *     changes nothing;
 *   - a call without `created_at_time` does not make a later identical call WITH it
 *     a duplicate (the fork keeps recording every call, as icrc1-mo does, but a
 *     record without `ts` never matches a lookup, which always carries `ts`).
 *
 * Red against icrc2-mo 0.2.1 (the "without" cases), green against the fork:
 *   TOKEN_WASM=<path> npx vitest run icrc2_dedupe.test.ts
 */

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { readFileSync } from 'fs';
import { createIdentity, wasmPath } from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');

const enc = (types: IDL.Type[], values: unknown[]) => new Uint8Array(IDL.encode(types, values));
const none = enc([], []);

const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });
type AccountT = { owner: Principal; subaccount: [] | [Uint8Array] };
const acct = (owner: Principal): AccountT => ({ owner, subaccount: [] });

const GenericError = IDL.Record({ error_code: IDL.Nat, message: IDL.Text });
const TransferArgs = IDL.Record({
  from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  to: Account,
  amount: IDL.Nat,
  fee: IDL.Opt(IDL.Nat),
  memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
  created_at_time: IDL.Opt(IDL.Nat64),
});
const TransferFromArgs = IDL.Record({
  spender_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  from: Account,
  to: Account,
  amount: IDL.Nat,
  fee: IDL.Opt(IDL.Nat),
  memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
  created_at_time: IDL.Opt(IDL.Nat64),
});
const ApproveArgs = IDL.Record({
  from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  spender: Account,
  amount: IDL.Nat,
  expected_allowance: IDL.Opt(IDL.Nat),
  expires_at: IDL.Opt(IDL.Nat64),
  fee: IDL.Opt(IDL.Nat),
  memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
  created_at_time: IDL.Opt(IDL.Nat64),
});
// The full error variants of the ledger's .did, so any refusal decodes and shows in the assertion.
const TransferResult = IDL.Variant({
  Ok: IDL.Nat,
  Err: IDL.Variant({
    BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    GenericError,
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    TooOld: IDL.Null,
  }),
});
const TransferFromResult = IDL.Variant({
  Ok: IDL.Nat,
  Err: IDL.Variant({
    BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    GenericError,
    InsufficientAllowance: IDL.Record({ allowance: IDL.Nat }),
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    TooOld: IDL.Null,
  }),
});
const ApproveResult = IDL.Variant({
  Ok: IDL.Nat,
  Err: IDL.Variant({
    AllowanceChanged: IDL.Record({ current_allowance: IDL.Nat }),
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    Expired: IDL.Record({ ledger_time: IDL.Nat64 }),
    GenericError,
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    TooOld: IDL.Null,
  }),
});
const Allowance = IDL.Record({ allowance: IDL.Nat, expires_at: IDL.Opt(IDL.Nat64) });

type Result = { Ok: bigint } | { Err: Record<string, unknown> };

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
const sections = { icrc1: IDL.Opt(IDL.Null), icrc2: IDL.Opt(IDL.Null), icrc4: IDL.Opt(IDL.Null) };
const INSTALL_ARG = enc([IDL.Opt(IDL.Record({ ...sections, icrc3: IDL.Opt(ICRC3InitArgs) }))], [[]]);

let server: PocketIcServer;
beforeAll(async () => { server = await PocketIcServer.start(); }, 120_000);
afterAll(async () => { await server.stop(); });

describe('icrc2 deduplicates only when created_at_time is set', () => {
  const minter = createIdentity(1).getPrincipal(); // installer: owner and minting account
  const alice = createIdentity(5).getPrincipal();
  const spender = createIdentity(6).getPrincipal();
  const bob = createIdentity(7).getPrincipal();
  let pic: PocketIc;
  let id: Principal;
  let fee: bigint;

  const update = (method: string, arg: Uint8Array, sender: Principal) =>
    pic.updateCall({ canisterId: id, method, arg, sender });
  const query = (method: string, arg: Uint8Array = none) =>
    pic.queryCall({ canisterId: id, method, arg, sender: Principal.anonymous() });

  const balanceOf = async (p: Principal) =>
    IDL.decode([IDL.Nat], await query('icrc1_balance_of', enc([Account], [acct(p)])))[0] as bigint;
  const blocks = async () => {
    const reply = await query('icrc3_get_blocks', enc([IDL.Vec(IDL.Record({ start: IDL.Nat, length: IDL.Nat }))], [[]]));
    return (IDL.decode([IDL.Record({ log_length: IDL.Nat })], reply)[0] as { log_length: bigint }).log_length;
  };
  const allowance = async () =>
    (IDL.decode([Allowance], await query('icrc2_allowance', enc([IDL.Record({ account: Account, spender: Account })], [{ account: acct(alice), spender: acct(spender) }])))[0] as { allowance: bigint }).allowance;
  /** What a refused duplicate must leave as it was. */
  const state = async () => ({ alice: await balanceOf(alice), bob: await balanceOf(bob), blocks: await blocks(), allowance: await allowance() });

  /** A `created_at_time` inside the window: the ledger's current time, in nanoseconds. */
  const now = async () => BigInt(Math.floor(await pic.getTime())) * 1_000_000n;
  const opt = (cat: bigint | null): [] | [bigint] => (cat === null ? [] : [cat]);

  const approve = async (amount: bigint, cat: bigint | null): Promise<Result> =>
    IDL.decode([ApproveResult], await update('icrc2_approve', enc([ApproveArgs], [{
      from_subaccount: [], spender: acct(spender), amount, expected_allowance: [], expires_at: [], fee: [], memo: [],
      created_at_time: opt(cat),
    }]), alice))[0] as Result;
  const transferFrom = async (amount: bigint, cat: bigint | null): Promise<Result> =>
    IDL.decode([TransferFromResult], await update('icrc2_transfer_from', enc([TransferFromArgs], [{
      spender_subaccount: [], from: acct(alice), to: acct(bob), amount, fee: [], memo: [], created_at_time: opt(cat),
    }]), spender))[0] as Result;

  beforeEach(async () => {
    pic = await PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
    id = await pic.createCanister({ sender: minter });
    await pic.addCycles(id, 100_000_000_000_000n);
    await pic.installCode({ canisterId: id, wasm: readFileSync(TOKEN_WASM), arg: INSTALL_ARG, sender: minter });
    await pic.tick(3);
    fee = IDL.decode([IDL.Nat], await query('icrc1_fee'))[0] as bigint;
    // Fund alice with a mint (the installer is the minting account). `max_allowance`
    // defaults to the total supply, so the approvals below stay well under it.
    const mint = IDL.decode([TransferResult], await update('icrc1_transfer', enc([TransferArgs], [{
      from_subaccount: [], to: acct(alice), amount: 100_000_000_000n, fee: [], memo: [], created_at_time: [],
    }]), minter))[0] as Result;
    expect(mint, 'alice is funded').toHaveProperty('Ok');
  });
  afterEach(async () => { await pic.tearDown(); });

  describe('icrc2_approve', () => {
    it('without created_at_time, two identical approvals both land', async () => {
      const before = await state();
      const first = await approve(1_000_000n, null);
      expect(first, 'first approval').toHaveProperty('Ok');
      const second = await approve(1_000_000n, null);
      expect(second, 'an identical approval without created_at_time is not a duplicate').toHaveProperty('Ok');
      expect((second as { Ok: bigint }).Ok).toBe((first as { Ok: bigint }).Ok + 1n);
      expect(await state()).toEqual({ ...before, alice: before.alice - 2n * fee, blocks: before.blocks + 2n, allowance: 1_000_000n });
    });

    it('with the same created_at_time, the second approval is a duplicate and changes nothing', async () => {
      const cat = await now();
      const first = await approve(1_000_000n, cat);
      expect(first, 'first approval').toHaveProperty('Ok');
      const after = await state();
      const second = await approve(1_000_000n, cat);
      expect(second).toEqual({ Err: { Duplicate: { duplicate_of: (first as { Ok: bigint }).Ok } } });
      expect(await state(), 'a duplicate moves nothing').toEqual(after);
    });

    it('an approval without created_at_time does not make the same approval with it a duplicate', async () => {
      const first = await approve(1_000_000n, null);
      expect(first, 'approval without created_at_time').toHaveProperty('Ok');
      const second = await approve(1_000_000n, await now());
      expect(second, 'the same approval with created_at_time').toHaveProperty('Ok');
      expect((second as { Ok: bigint }).Ok).toBe((first as { Ok: bigint }).Ok + 1n);
    });
  });

  describe('icrc2_transfer_from', () => {
    beforeEach(async () => {
      expect(await approve(10_000_000n, null), 'alice approves the spender').toHaveProperty('Ok');
    });

    it('without created_at_time, two identical transfers both land', async () => {
      const before = await state();
      const first = await transferFrom(1_000n, null);
      expect(first, 'first transfer').toHaveProperty('Ok');
      const second = await transferFrom(1_000n, null);
      expect(second, 'an identical transfer without created_at_time is not a duplicate').toHaveProperty('Ok');
      expect((second as { Ok: bigint }).Ok).toBe((first as { Ok: bigint }).Ok + 1n);
      expect(await state()).toEqual({
        alice: before.alice - 2n * (1_000n + fee),
        bob: before.bob + 2_000n,
        blocks: before.blocks + 2n,
        allowance: before.allowance - 2n * (1_000n + fee),
      });
    });

    it('with the same created_at_time, the second transfer is a duplicate and changes nothing', async () => {
      const cat = await now();
      const first = await transferFrom(1_000n, cat);
      expect(first, 'first transfer').toHaveProperty('Ok');
      const after = await state();
      const second = await transferFrom(1_000n, cat);
      expect(second).toEqual({ Err: { Duplicate: { duplicate_of: (first as { Ok: bigint }).Ok } } });
      expect(await state(), 'a duplicate moves nothing').toEqual(after);
    });

    it('a transfer without created_at_time does not make the same transfer with it a duplicate', async () => {
      const first = await transferFrom(1_000n, null);
      expect(first, 'transfer without created_at_time').toHaveProperty('Ok');
      const second = await transferFrom(1_000n, await now());
      expect(second, 'the same transfer with created_at_time').toHaveProperty('Ok');
      expect((second as { Ok: bigint }).Ok).toBe((first as { Ok: bigint }).Ok + 1n);
    });
  });
});
