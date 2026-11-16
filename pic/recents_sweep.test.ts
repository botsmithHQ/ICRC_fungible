/**
 * The cleanup of `recent_transactions` as memory management
 * (docs/design/icrc1-recents-cleanup.md, D2 and §3 option A).
 *
 * Upstream 0.2.1 walked the map in HASH order and stopped at the first live
 * entry, so an expired entry that sorts after a live one stayed. The fix is a
 * bounded incremental sweep (SWEEP_MIN + SWEEP_PER_INSERT · added entries per
 * call, resuming from a cursor, never stopping at a live entry).
 *
 * The index size is not observable through Token.mo, so these cases run on the
 * pic-only harness pic/RecentsProbe.mo (same ICRC1 wiring, plus recents_size /
 * recents_get). Hash orders the cases depend on are pinned and asserted.
 *
 * Build the wasm first: bash pic/build-token-wasm.sh recents_probe
 * RECENTS_PROBE_WASM=<path> points it at another build.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PocketIcServer } from '@dfinity/pic';
import type { Principal } from '@icp-sdk/core/principal';
import {
  Ledger, startServer, wasmPath, createIdentity, txHash, amountHashing, compareBytes, okIndex,
  repIndyHash, accountValue, hex,
  T0_NS, NS_PER_S, WINDOW_NS, DRIFT_NS, SWEEP_MIN, SWEEP_PER_INSERT,
} from './recents_harness';

const PROBE_WASM = wasmPath('RECENTS_PROBE_WASM', 'recents_probe');

const bob = createIdentity(92).getPrincipal();
const carol = createIdentity(93).getPrincipal();
const S = NS_PER_S;
/** An entry inserted at T is dead once now > T + HORIZON. */
const HORIZON = WINDOW_NS + 2n * DRIFT_NS;

/** The key of the funding mint (block 0) of `Ledger.create`. */
function mintKey(alice: Principal): Uint8Array {
  return repIndyHash({ Map: [['amt', { Nat: 1_000_000_000_000n }], ['op', { Text: 'mint' }], ['to', accountValue(alice)]] });
}

describe('recents sweep (RecentsProbe wasm)', () => {
  let server: PocketIcServer;
  beforeAll(async () => { server = await startServer(); }, 60_000);
  afterAll(async () => { if (server) await server.stop(); });

  async function withProbe(fn: (l: Ledger) => Promise<void>): Promise<void> {
    const l = await Ledger.create(server, 'probe', PROBE_WASM);
    try {
      expect(await l.recentsGet(mintKey(l.alice.getPrincipal())), 'the mint is indexed under the computed key').toBeDefined();
      await fn(l);
    } finally {
      await l.tearDown();
    }
  }

  it('T4: expired entries that hash after a live one are swept', async () => {
    await withProbe(async (l) => {
      const alice = l.alice.getPrincipal();
      const T = T0_NS + 100n * S;
      const seeds = Array.from({ length: 12 }, (_, i) => ({ to: bob, amount: 100_000n + BigInt(i), ts: T + BigInt(i) * S }));
      const seedKeys = seeds.map((x) => txHash({ ...x, from: alice }));
      const maxSeed = seedKeys.reduce((a, b) => (compareBytes(a, b) > 0 ? a : b));
      // Pinned: at least one seed sorts AFTER the nudge, where upstream's walk never goes.
      const nudgeAmount = amountHashing({ from: alice, to: carol }, 200_000n, maxSeed, -1);
      const nudgeKey = txHash({ from: alice, to: carol, amount: nudgeAmount });
      const after = seedKeys.filter((k) => compareBytes(k, nudgeKey) > 0).length;
      expect(after, 'seeds sorting after the nudge').toBeGreaterThan(0);

      for (const [i, x] of seeds.entries()) {
        await l.at(x.ts);
        okIndex(await l.send(x), `seed ${i}`);
      }
      for (const k of seedKeys) expect(await l.recentsGet(k), `seed ${hex(k)} indexed`).toBeDefined();

      await l.at(T + 11n * S + HORIZON + 1n * S);
      okIndex(await l.send({ to: carol, amount: nudgeAmount }), 'nudge');

      expect(await l.recentsSize()).toEqual(1n);
      expect(await l.recentsGet(nudgeKey), 'only the nudge is left').toBeDefined();
    });
  }, 180_000);

  it('T5: the map stays ≤ 2·live + SWEEP_MIN under steady traffic', async () => {
    await withProbe(async (l) => {
      const T = T0_NS + 100n * S;
      const step = WINDOW_NS / 48n; // 30 min
      const times: bigint[] = [];
      for (let i = 0; i < 3 * 48; i++) {
        const t = T + BigInt(i) * step;
        await l.at(t);
        okIndex(await l.send({ to: bob, amount: 100_000n + BigInt(i) }), `transfer ${i}`);
        times.push(t);
        const live = times.filter((ti) => ti + HORIZON >= t).length;
        const size = Number(await l.recentsSize());
        expect(size, `step ${i}: size ${size}, live ${live}`).toBeLessThanOrEqual(2 * live + SWEEP_MIN);
      }
    });
  }, 300_000);

  it('T10: the cursor key is swept when it is the only expired entry', async () => {
    await withProbe(async (l) => {
      // The mint's own cleanup examined its entry, so the mint key is the
      // sweep cursor. Once it expires, it is the only entry, and the cursor.
      await l.advance(HORIZON + 1n * S);
      await l.measureCleanup();
      expect(await l.recentsSize()).toEqual(0n);
    });
  }, 120_000);

  it('T6: a quiet period drains, at least SWEEP_MIN per call, down to the live set', async () => {
    await withProbe(async (l) => {
      const alice = l.alice.getPrincipal();
      const T = T0_NS + 100n * S;
      const seeds = Array.from({ length: 200 }, (_, i) => ({ to: bob, amount: 100_000n + BigInt(i) }));
      const seedKeys = seeds.map((x) => txHash({ ...x, from: alice }));
      const maxSeed = seedKeys.reduce((a, b) => (compareBytes(a, b) > 0 ? a : b));
      // Pinned: nudge 1 sorts before the largest seed; every later nudge sorts
      // after nudge 1. Upstream's walk then stops at nudge 1 on every call
      // after the first, with expired seeds still behind it.
      const n1 = amountHashing({ from: alice, to: carol }, 200_000n, maxSeed, -1);
      const k1 = txHash({ from: alice, to: carol, amount: n1 });
      const nudges = [n1];
      while (nudges.length < 16) {
        nudges.push(amountHashing({ from: alice, to: carol }, nudges[nudges.length - 1] + 1n, k1, 1));
      }

      await l.at(T);
      for (const [i, x] of seeds.entries()) okIndex(await l.send(x), `seed ${i}`);
      await l.advance(2n * WINDOW_NS);

      let size = await l.recentsSize();
      expect(size, '200 seeds + the mint, all expired').toBe(201n);
      for (const [j, amount] of nudges.entries()) {
        const call = j + 1;
        const deadBefore = Number(size) - j; // the j earlier nudges are live
        okIndex(await l.send({ to: carol, amount }), `nudge ${call}`);
        const next = await l.recentsSize();
        const removed = Number(size) + 1 - Number(next);
        // The call examines min(size, SWEEP_MIN + SWEEP_PER_INSERT) entries;
        // at most `call` of them are live.
        const examined = Math.min(Number(size) + 1, SWEEP_MIN + SWEEP_PER_INSERT);
        const floor = Math.min(deadBefore, examined - call);
        expect(removed, `call ${call}: size ${size} → ${next}`).toBeGreaterThanOrEqual(floor);
        size = next;
      }
      expect(size, 'drained to the 16 live nudges').toBe(16n);
    });
  }, 300_000);
});
