/**
 * Shared harness of the dedup-index tests (pic/recents_*.test.ts).
 *
 * - The ICRC-3 representation-independent hash of a transfer, computed here the
 *   way the ledger keys `recent_transactions` (`transfer_req_to_value` +
 *   `RepIndy.hash_val`), so a test can PIN the hash order it depends on and
 *   assert it. `recents_horizon.test.ts` checks this helper against the
 *   ledger's own blocks (the tx value and the phash chain).
 * - A nanosecond clock. pic's `setTime`/`advanceTime` work in milliseconds;
 *   the boundaries tested here are one nanosecond wide. `calibrate` measures
 *   the offset between the time set and the time a message executes at,
 *   through `CreatedInFuture.ledger_time`, and `at` uses it.
 * - Install/upgrade of the Token and of the RecentsProbe harness, each case on
 *   a fresh PocketIC instance whose clock starts at the same constant, so the
 *   hashes (which contain `created_at_time`) are the same on every run.
 */

import { expect } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { createHash } from 'crypto';
import { readFileSync } from 'fs';
import { createIdentity, encodeTokenArgs, EOP_UPGRADE, wasmPath } from './archive_harness';

export { createIdentity, wasmPath };

// =============== Library constants the tests assume ===============

export const NS_PER_S = 1_000_000_000n;
/** icrc1-mo default `transaction_window` (24 h). */
export const WINDOW_NS = 86_400n * NS_PER_S;
/** icrc1-mo default `permitted_drift` (60 s). */
export const DRIFT_NS = 60n * NS_PER_S;
/** vendor/icrc1-mo `SWEEP_MIN` / `SWEEP_PER_INSERT` (LOCAL PATCH recents sweep). */
export const SWEEP_MIN = 16;
export const SWEEP_PER_INSERT = 2;
/** Every case starts its clock here (2027-01-15T08:00:00Z), so hashes are stable. */
export const T0_NS = 1_800_000_000n * NS_PER_S;
export const FEE = 10_000n;
/** Recipient of the (always refused) calibration messages. */
const CALIBRATION_SINK = createIdentity(99).getPrincipal();

// =============== ICRC-3 values and the rep-indy hash ===============

export type Value =
  | { Nat: bigint }
  | { Int: bigint }
  | { Text: string }
  | { Blob: Uint8Array | number[] }
  | { Array: Value[] }
  | { Map: [string, Value][] };

function sha256(bytes: Uint8Array): Uint8Array {
  return new Uint8Array(createHash('sha256').update(bytes).digest());
}

function leb128(n: bigint): Uint8Array {
  const out: number[] = [];
  do {
    let byte = Number(n & 0x7fn);
    n >>= 7n;
    if (n !== 0n) byte |= 0x80;
    out.push(byte);
  } while (n !== 0n);
  return new Uint8Array(out);
}

function sleb128(n: bigint): Uint8Array {
  const out: number[] = [];
  for (;;) {
    const byte = Number(n & 0x7fn);
    n >>= 7n;
    const done = (n === 0n && (byte & 0x40) === 0) || (n === -1n && (byte & 0x40) !== 0);
    out.push(done ? byte : byte | 0x80);
    if (done) break;
  }
  return new Uint8Array(out);
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/** Same ordering as Motoko's `Blob.compare`: bytewise, then length. */
export function compareBytes(a: Uint8Array, b: Uint8Array): -1 | 0 | 1 {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
}

/** `RepIndy.hash_val` (rep-indy-hash 0.2.1). */
export function repIndyHash(v: Value): Uint8Array {
  if ('Blob' in v) return sha256(Uint8Array.from(v.Blob));
  if ('Text' in v) return sha256(new TextEncoder().encode(v.Text));
  if ('Nat' in v) return sha256(leb128(v.Nat));
  if ('Int' in v) return sha256(sleb128(v.Int));
  if ('Array' in v) return sha256(concat(v.Array.map(repIndyHash)));
  const entries = v.Map.map(([k, val]) => concat([repIndyHash({ Text: k }), repIndyHash(val)]));
  entries.sort(compareBytes);
  return sha256(concat(entries));
}

export function hex(b: Uint8Array): string {
  return Buffer.from(b).toString('hex');
}

export function accountValue(owner: Principal, subaccount?: Uint8Array): Value {
  const parts: Value[] = [{ Blob: owner.toUint8Array() }];
  if (subaccount) parts.push({ Blob: subaccount });
  return { Array: parts };
}

export interface Xfer {
  from: Principal;
  to: Principal;
  amount: bigint;
  /** created_at_time; absent = no dedup on the way in, but still indexed. */
  ts?: bigint;
  memo?: Uint8Array;
}

/** `transfer_req_to_value` for a plain transfer (not a mint or a burn), fee left to the ledger. */
export function transferTxValue(x: Xfer): Value {
  const m: [string, Value][] = [
    ['amt', { Nat: x.amount }],
    ['op', { Text: 'xfer' }],
    ['to', accountValue(x.to)],
    ['from', accountValue(x.from)],
  ];
  if (x.ts !== undefined) m.push(['ts', { Nat: x.ts }]);
  if (x.memo !== undefined) m.push(['memo', { Blob: x.memo }]);
  return { Map: m };
}

/** The key the ledger files this transfer under in `recent_transactions`. */
export function txHash(x: Xfer): Uint8Array {
  return repIndyHash(transferTxValue(x));
}

/**
 * The first amount ≥ `start` whose transfer hash sorts on `side` of `pivot`
 * (-1: before, +1: after). Deterministic: the same inputs give the same amount.
 */
export function amountHashing(
  base: Omit<Xfer, 'amount'>, start: bigint, pivot: Uint8Array, side: -1 | 1,
): bigint {
  for (let a = start; a < start + 10_000n; a++) {
    if (compareBytes(txHash({ ...base, amount: a }), pivot) === side) return a;
  }
  throw new Error('no amount found on that side of the pivot');
}

/** sha256(be64(salt) ++ be64(i)) — RecentsProbe.recents_seed's keys. */
export function syntheticKey(salt: bigint, i: bigint): Uint8Array {
  const b = Buffer.alloc(16);
  b.writeBigUInt64BE(salt, 0);
  b.writeBigUInt64BE(i, 8);
  return sha256(new Uint8Array(b));
}

// =============== Candid ===============

const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });

const TransferError = IDL.Variant({
  GenericError: IDL.Record({ message: IDL.Text, error_code: IDL.Nat }),
  TemporarilyUnavailable: IDL.Null,
  BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
  Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
  BadFee: IDL.Record({ expected_fee: IDL.Nat }),
  CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
  TooOld: IDL.Null,
  InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
});

const TransferResult = IDL.Variant({ Ok: IDL.Nat, Err: TransferError });

const ValueIdl = IDL.Rec();
ValueIdl.fill(IDL.Variant({
  Int: IDL.Int,
  Map: IDL.Vec(IDL.Tuple(IDL.Text, ValueIdl)),
  Nat: IDL.Nat,
  Blob: IDL.Vec(IDL.Nat8),
  Text: IDL.Text,
  Array: IDL.Vec(ValueIdl),
}));

const BlockRange = IDL.Record({ start: IDL.Nat, length: IDL.Nat });

const recentsIdl: IDL.InterfaceFactory = ({ IDL }) => IDL.Service({
  icrc1_transfer: IDL.Func([IDL.Record({
    from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    to: Account,
    amount: IDL.Nat,
    fee: IDL.Opt(IDL.Nat),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  })], [TransferResult], []),
  icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ['query']),
  // Token only.
  icrc3_get_blocks: IDL.Func([IDL.Vec(BlockRange)], [IDL.Record({
    log_length: IDL.Nat,
    blocks: IDL.Vec(IDL.Record({ id: IDL.Nat, block: ValueIdl })),
  })], ['query']),
  // RecentsProbe only.
  recents_size: IDL.Func([], [IDL.Nat], ['query']),
  recents_get: IDL.Func([IDL.Vec(IDL.Nat8)], [IDL.Opt(IDL.Tuple(IDL.Nat64, IDL.Nat))], ['query']),
  recents_seed: IDL.Func([IDL.Nat, IDL.Nat64, IDL.Nat64], [], []),
  recents_measure_cleanup: IDL.Func([], [IDL.Nat64], []),
});

export type TransferRes = { Ok: bigint } | { Err: Record<string, any> };

// =============== A ledger on its own PocketIC instance ===============

export type Kind = 'token' | 'probe';

export class Ledger {
  readonly owner = createIdentity(90); // minting account
  readonly alice = createIdentity(91);
  delta = 0n; // executed-at minus set-to, from `calibrate`
  private constructor(
    readonly server: PocketIcServer,
    readonly pic: PocketIc,
    readonly kind: Kind,
    readonly id: Principal,
    private readonly actor: any,
  ) {}

  /**
   * A fresh PocketIC instance at T0_NS, the wasm installed, alice funded with
   * one mint. Asserts the precondition: an empty log/index before the mint.
   */
  static async create(server: PocketIcServer, kind: Kind, wasm: string): Promise<Ledger> {
    const pic = await PocketIc.create(server.getUrl(), {
      application: [{ state: { type: SubnetStateType.New } }],
    });
    await (pic as any).client.setTime({ nanosSinceEpoch: T0_NS });
    const owner = createIdentity(90).getPrincipal();
    const id = await pic.createCanister({ sender: owner, cycles: 500_000_000_000_000n });
    await pic.installCode({
      canisterId: id,
      wasm: readFileSync(wasm),
      arg: kind === 'token' ? encodeTokenArgs(null) : new Uint8Array(IDL.encode([], [])),
      sender: owner,
    });
    for (let i = 0; i < 5; i++) await pic.tick();
    const actor = pic.createActor<any>(recentsIdl, id);
    const l = new Ledger(server, pic, kind, id, actor);

    if (kind === 'token') expect(await l.logLength(), 'precondition: empty log').toBe(0n);
    else expect(await l.recentsSize(), 'precondition: empty index').toBe(0n);
    const mint = await l.transfer(l.owner.getPrincipal(), {
      from: l.owner.getPrincipal(), to: l.alice.getPrincipal(), amount: 1_000_000_000_000n,
    });
    expect(mint, 'mint to alice').toEqual({ Ok: 0n });
    return l;
  }

  async tearDown(): Promise<void> {
    await this.pic.tearDown();
  }

  async upgrade(wasm: string): Promise<void> {
    await this.pic.upgradeCanister({
      canisterId: this.id,
      wasm: readFileSync(wasm),
      arg: this.kind === 'token' ? encodeTokenArgs(null) : new Uint8Array(IDL.encode([], [])),
      sender: this.owner.getPrincipal(),
      upgradeModeOptions: EOP_UPGRADE,
    });
    for (let i = 0; i < 5; i++) await this.pic.tick();
  }

  async transfer(sender: Principal, x: Xfer): Promise<TransferRes> {
    this.actor.setPrincipal(sender);
    return await this.actor.icrc1_transfer({
      from_subaccount: [],
      to: { owner: x.to, subaccount: [] },
      amount: x.amount,
      fee: [],
      memo: x.memo === undefined ? [] : [x.memo],
      created_at_time: x.ts === undefined ? [] : [x.ts],
    });
  }

  /** A transfer from alice (the funded account). */
  send(x: Omit<Xfer, 'from'>): Promise<TransferRes> {
    return this.transfer(this.alice.getPrincipal(), { ...x, from: this.alice.getPrincipal() });
  }

  async balance(p: Principal): Promise<bigint> {
    return await this.actor.icrc1_balance_of({ owner: p, subaccount: [] });
  }

  async logLength(): Promise<bigint> {
    return (await this.actor.icrc3_get_blocks([])).log_length;
  }

  async blocks(start: bigint, length: bigint): Promise<{ id: bigint; block: Value }[]> {
    return (await this.actor.icrc3_get_blocks([{ start, length }])).blocks;
  }

  async recentsSize(): Promise<bigint> {
    return await this.actor.recents_size();
  }

  async recentsGet(key: Uint8Array): Promise<[bigint, bigint] | undefined> {
    const r = await this.actor.recents_get(key);
    return r.length === 0 ? undefined : r[0];
  }

  async seed(n: bigint, salt: bigint, insertedAt: bigint): Promise<void> {
    this.actor.setPrincipal(this.owner.getPrincipal());
    await this.actor.recents_seed(n, salt, insertedAt);
  }

  async measureCleanup(): Promise<bigint> {
    this.actor.setPrincipal(this.owner.getPrincipal());
    return await this.actor.recents_measure_cleanup();
  }

  // ---- nanosecond clock ----

  async now(): Promise<bigint> {
    return (await (this.pic as any).client.getTime()).nanosSinceEpoch as bigint;
  }

  private async setNs(ns: bigint): Promise<void> {
    const cur = await this.now();
    if (ns < cur) throw new Error(`clock would go back: ${ns} < ${cur}`);
    await (this.pic as any).client.setTime({ nanosSinceEpoch: ns });
  }

  /** The time the next message executes at when the clock is set to `ns`. */
  private async executedAt(ns: bigint): Promise<bigint> {
    await this.setNs(ns);
    // Not to the minting account: that is a burn, refused as BadBurn before the time checks.
    const r = await this.send({ to: CALIBRATION_SINK, amount: 1n, ts: ns + 1_000_000n * NS_PER_S });
    expect(r, 'calibration message is refused as CreatedInFuture').toHaveProperty('Err.CreatedInFuture');
    return (r as any).Err.CreatedInFuture.ledger_time as bigint;
  }

  /**
   * Measures `delta` twice, one second apart, and asserts it is the same both
   * times: the boundary tests rely on landing on an exact nanosecond.
   */
  async calibrate(): Promise<void> {
    const a = (await this.now()) + NS_PER_S;
    const d1 = (await this.executedAt(a)) - a;
    const b = a + NS_PER_S;
    const d2 = (await this.executedAt(b)) - b;
    expect(d1 >= 0n, `delta ${d1} is not negative`).toBe(true);
    expect(d2, 'the clock offset is stable').toBe(d1);
    this.delta = d1;
  }

  /** Sets the clock so that the NEXT message executes at exactly `ns`. */
  async at(ns: bigint): Promise<void> {
    await this.setNs(ns - this.delta);
  }

  async advance(ns: bigint): Promise<void> {
    await this.setNs((await this.now()) + ns);
  }
}

export async function startServer(): Promise<PocketIcServer> {
  return await PocketIcServer.start();
}

/** 'Ok', 'Duplicate(+k)' (k = duplicate_of − `first`), or the Err tag. */
export function outcome(r: TransferRes, first: bigint): string {
  if ('Ok' in r) return 'Ok';
  const tag = Object.keys(r.Err)[0];
  if (tag === 'Duplicate') return `Duplicate(+${r.Err.Duplicate.duplicate_of - first})`;
  return tag;
}

export function okIndex(r: TransferRes, what: string): bigint {
  expect(r, what).toHaveProperty('Ok');
  return (r as { Ok: bigint }).Ok;
}

/** Field `k` of an ICRC-3 #Map value. */
export function field(v: Value, k: string): Value | undefined {
  if (!('Map' in v)) return undefined;
  return v.Map.find(([key]) => key === k)?.[1];
}
