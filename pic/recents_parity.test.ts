/**
 * T7 — the dedup gap seen end to end, on both sides of the hash order
 * (docs/design/icrc1-recents-cleanup.md §5).
 *
 * Timings, relative to the payment at t0 (created_at_time = t0):
 *   t0              pay
 *   t0 + 23 h       re-send
 *   t0 + 24 h 10 s  nudge (another transfer: its cleanup is what upstream's
 *                   walk runs, and it stops at the first live entry in HASH order)
 *   t0 + 24 h 30 s  re-send
 *   t0 + 24 h 61 s  re-send
 *
 * Side −1 pins hash(req) < hash(nudge): upstream's walk reaches req and drops it,
 * the re-send at 24 h 30 s executes and the recipient is paid twice
 * (["Ok","Duplicate(+0)","Ok","TooOld"]). Side +1 pins hash(req) > hash(nudge):
 * upstream keeps req. With the fix both sides answer
 * ["Ok","Duplicate(+0)","Duplicate(+0)","TooOld"] and pay once.
 *
 * Build the wasm first: bash pic/build-token-wasm.sh token
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PocketIcServer } from '@dfinity/pic';
import {
  Ledger, startServer, wasmPath, createIdentity, txHash, amountHashing, compareBytes, outcome, okIndex,
  T0_NS, NS_PER_S,
} from './recents_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');

const H = 3_600n * NS_PER_S;
const S = NS_PER_S;

const bob = createIdentity(92).getPrincipal();
const carol = createIdentity(93).getPrincipal();

describe('T7 recents parity (Token wasm)', () => {
  let server: PocketIcServer;
  beforeAll(async () => { server = await startServer(); }, 60_000);
  afterAll(async () => { if (server) await server.stop(); });

  for (const side of [-1, 1] as const) {
    it(`side ${side}: hash(req) ${side === -1 ? '<' : '>'} hash(nudge) → paid once`, async () => {
      const l = await Ledger.create(server, 'token', TOKEN_WASM);
      try {
        await l.calibrate();
        const t0 = T0_NS + 100n * S;
        const req = { to: bob, amount: 100_000n, ts: t0 };
        const hReq = txHash({ ...req, from: l.alice.getPrincipal() });
        const nudgeBase = { from: l.alice.getPrincipal(), to: carol };
        // hash(req) on `side` of hash(nudge) ⇔ hash(nudge) on −side of hash(req).
        const nudgeAmount = amountHashing(nudgeBase, 200_000n, hReq, side === -1 ? 1 : -1);
        expect(compareBytes(hReq, txHash({ ...nudgeBase, amount: nudgeAmount })), 'pinned hash order').toBe(side);

        const seen: string[] = [];
        await l.at(t0);
        const pay = await l.send(req);
        const first = okIndex(pay, 'pay');
        seen.push(outcome(pay, first));
        await l.at(t0 + 23n * H);
        seen.push(outcome(await l.send(req), first));
        await l.at(t0 + 24n * H + 10n * S);
        okIndex(await l.send({ to: carol, amount: nudgeAmount }), 'nudge');
        await l.at(t0 + 24n * H + 30n * S);
        seen.push(outcome(await l.send(req), first));
        await l.at(t0 + 24n * H + 61n * S);
        seen.push(outcome(await l.send(req), first));

        expect(seen).toEqual(['Ok', 'Duplicate(+0)', 'Duplicate(+0)', 'TooOld']);
        expect(await l.balance(bob), 'bob paid once').toBe(100_000n);
      } finally {
        await l.tearDown();
      }
    }, 120_000);
  }
});
