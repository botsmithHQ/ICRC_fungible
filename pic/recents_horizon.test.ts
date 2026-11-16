/**
 * The dedup horizon of `recent_transactions` (docs/design/icrc1-recents-cleanup.md, D1).
 *
 * A re-send carries the same created_at_time C, so it has the same hash. At
 * insertion (time T) `is_in_future` allowed C ≤ T + drift, and a re-send passes
 * `is_too_old` while now ≤ C + window + drift. So an entry must answer
 * #Duplicate up to T + window + 2·drift. Upstream 0.2.1:
 *   - the cleanup deleted it once T + window < now (T1, cleanup side);
 *   - `find_dupe` stopped seeing it at T + window + drift (T2, T3b, read side).
 *
 * Every case runs on the real Token wasm, on a fresh PocketIC instance whose
 * clock starts at T0_NS, and lands its messages on exact nanoseconds
 * (`Ledger.calibrate` / `Ledger.at`). H0 checks the hash helper the T-cases
 * pin their hash order with against the ledger's own blocks.
 *
 * Build the wasm first: bash pic/build-token-wasm.sh token
 * TOKEN_WASM=<path> points it at another build (an unpatched one goes red).
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PocketIcServer } from '@dfinity/pic';
import {
  Ledger, startServer, wasmPath, createIdentity, txHash, repIndyHash, hex,
  amountHashing, compareBytes, outcome, okIndex, field,
  T0_NS, NS_PER_S, WINDOW_NS, DRIFT_NS,
} from './recents_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');

const bob = createIdentity(92).getPrincipal();
const carol = createIdentity(93).getPrincipal();

describe('recents horizon (Token wasm)', () => {
  let server: PocketIcServer;
  beforeAll(async () => { server = await startServer(); }, 60_000);
  afterAll(async () => { if (server) await server.stop(); });

  async function withLedger(fn: (l: Ledger) => Promise<void>): Promise<void> {
    const l = await Ledger.create(server, 'token', TOKEN_WASM);
    try {
      await l.calibrate();
      await fn(l);
    } finally {
      await l.tearDown();
    }
  }

  it('H0: the hash helper matches the ledger (tx value, phash chain) and `at` lands on the nanosecond', async () => {
    await withLedger(async (l) => {
      const T = T0_NS + 100n * NS_PER_S;
      const x = { to: bob, amount: 5_000n, ts: T };
      await l.at(T);
      const i = okIndex(await l.send(x), 'transfer');
      const [prev, blk] = await l.blocks(i - 1n, 2n);
      expect(blk.id).toBe(i);
      const tx = field(blk.block, 'tx')!;
      expect(hex(repIndyHash(tx)), 'tx value hash').toBe(hex(txHash({ ...x, from: l.alice.getPrincipal() })));
      const phash = field(blk.block, 'phash') as { Blob: Uint8Array };
      expect(hex(Uint8Array.from(phash.Blob)), 'phash chain').toBe(hex(repIndyHash(prev.block)));
      expect(field(blk.block, 'ts'), 'executed at the exact nanosecond').toEqual({ Nat: T });
    });
  }, 120_000);

  it('T1: a re-send after insertion + window, before #TooOld, is #Duplicate when the cleanup ran first', async () => {
    await withLedger(async (l) => {
      const T = T0_NS + 100n * NS_PER_S;
      const req = { to: bob, amount: 100_000n, ts: T };
      const hReq = txHash({ ...req, from: l.alice.getPrincipal() });
      // Pinned: the nudge sorts AFTER req, so upstream's walk reaches req.
      const nudgeAmount = amountHashing({ from: l.alice.getPrincipal(), to: carol }, 200_000n, hReq, 1);
      expect(compareBytes(hReq, txHash({ from: l.alice.getPrincipal(), to: carol, amount: nudgeAmount }))).toBe(-1);

      await l.at(T);
      const first = okIndex(await l.send(req), 'pay');
      await l.at(T + WINDOW_NS + 10n * NS_PER_S);
      okIndex(await l.send({ to: carol, amount: nudgeAmount }), 'nudge');
      await l.at(T + WINDOW_NS + 30n * NS_PER_S);
      const resend = await l.send(req);

      expect(outcome(resend, first)).toEqual('Duplicate(+0)');
      expect(await l.balance(bob), 'bob paid once').toBe(100_000n);
    });
  }, 120_000);

  it('T2: a key dated +drift is #Duplicate up to insertion + window + 2·drift', async () => {
    await withLedger(async (l) => {
      const T = T0_NS + 100n * NS_PER_S;
      const req = { to: bob, amount: 100_000n, ts: T + DRIFT_NS };
      await l.at(T);
      const first = okIndex(await l.send(req), 'pay, created_at_time = now + drift');
      // No nudge: no cleanup runs, the entry is still in the map.
      await l.at(T + WINDOW_NS + (3n * DRIFT_NS) / 2n);
      const resend = await l.send(req);

      expect(outcome(resend, first)).toEqual('Duplicate(+0)');
      expect(await l.balance(bob), 'bob paid once').toBe(100_000n);
    });
  }, 120_000);

  it('T3a: a re-send 1 ns past created_at_time + window + drift is #TooOld', async () => {
    await withLedger(async (l) => {
      const T = T0_NS + 100n * NS_PER_S;
      const C = T + DRIFT_NS;
      const req = { to: bob, amount: 100_000n, ts: C };
      await l.at(T);
      const first = okIndex(await l.send(req), 'pay');
      await l.at(C + WINDOW_NS + DRIFT_NS + 1n);
      expect(outcome(await l.send(req), first)).toEqual('TooOld');
      expect(await l.balance(bob), 'bob paid once').toBe(100_000n);
    });
  }, 120_000);

  it('T3b: a re-send exactly at insertion + window + 2·drift is #Duplicate', async () => {
    await withLedger(async (l) => {
      const T = T0_NS + 100n * NS_PER_S;
      const C = T + DRIFT_NS;
      const req = { to: bob, amount: 100_000n, ts: C };
      await l.at(T);
      const first = okIndex(await l.send(req), 'pay');
      // = C + window + drift: the last nanosecond `is_too_old` lets it through.
      await l.at(T + WINDOW_NS + 2n * DRIFT_NS);
      expect(outcome(await l.send(req), first)).toEqual('Duplicate(+0)');
      expect(await l.balance(bob), 'bob paid once').toBe(100_000n);
    });
  }, 120_000);
});
