/**
 * U1 — upgrade in place from the library as it was before the recents fix
 * (main 091b5e34) to the current build (docs/design/icrc1-recents-cleanup.md §6).
 *
 * The stable type of `recent_transactions` does not change; the sweep cursor
 * and its counter live in the ICRC1 class instance, so they reset on upgrade.
 * Before the upgrade the base build leaves live entries and expired ones
 * (expired entries that sort after a live one linger: D2). After it:
 *   - the upgrade succeeds, balances and the block log are unchanged;
 *   - a live key re-send is #Duplicate, an expired key re-send is #TooOld;
 *   - a key dated +drift before the upgrade is #Duplicate up to its insertion
 *     + window + 2·drift (a strict widening: no gap opens in the transition);
 *   - (probe) the expired backlog drains under the sweep's rule.
 *
 * Build the wasms first:
 *   bash pic/build-token-wasm.sh token recents_probe token_recents_base recents_probe_base
 * The *_base wasms are built from 091b5e34 by pic/build-baseline-wasm.sh.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PocketIcServer } from '@dfinity/pic';
import {
  Ledger, startServer, wasmPath, createIdentity, txHash, amountHashing, compareBytes, okIndex, outcome,
  T0_NS, NS_PER_S, WINDOW_NS, DRIFT_NS, SWEEP_MIN, SWEEP_PER_INSERT, type Kind,
} from './recents_harness';

const WASMS: Record<Kind, { base: string; current: string }> = {
  token: {
    base: wasmPath('TOKEN_RECENTS_BASE_WASM', 'token_recents_base'),
    current: wasmPath('TOKEN_WASM', 'token'),
  },
  probe: {
    base: wasmPath('RECENTS_PROBE_BASE_WASM', 'recents_probe_base'),
    current: wasmPath('RECENTS_PROBE_WASM', 'recents_probe'),
  },
};

const bob = createIdentity(92).getPrincipal();
const carol = createIdentity(93).getPrincipal();
const dave = createIdentity(94).getPrincipal();
const S = NS_PER_S;
const HORIZON = WINDOW_NS + 2n * DRIFT_NS;
const DEAD_SEEDS = 40;
const DRAIN_CALLS = 6;

describe('U1 recents across the upgrade from 091b5e34', () => {
  let server: PocketIcServer;
  beforeAll(async () => { server = await startServer(); }, 60_000);
  afterAll(async () => { if (server) await server.stop(); });

  for (const kind of ['token', 'probe'] as const) {
    it(`${kind}: live keys stay #Duplicate, expired keys are #TooOld and drain`, async () => {
      const l = await Ledger.create(server, kind, WASMS[kind].base);
      try {
        await l.calibrate();
        const alice = l.alice.getPrincipal();

        // ---- before the upgrade, on the base build ----
        const T = T0_NS + 100n * S;
        const dead = Array.from({ length: DEAD_SEEDS }, (_, i) => ({ to: bob, amount: 100_000n + BigInt(i), ts: T + BigInt(i) * S }));
        const deadKeys = dead.map((x) => txHash({ ...x, from: alice }));
        const deadIdx: bigint[] = [];
        for (const [i, x] of dead.entries()) {
          await l.at(x.ts);
          deadIdx.push(okIndex(await l.send(x), `dead seed ${i}`));
        }
        // The nudge sorts before the largest dead seed: on the base build some
        // expired seeds linger behind it (D2).
        const maxDead = deadKeys.reduce((a, b) => (compareBytes(a, b) > 0 ? a : b));
        const nudgeAmount = amountHashing({ from: alice, to: carol }, 200_000n, maxDead, -1);
        const tNudge = T + BigInt(DEAD_SEEDS) * S + HORIZON;
        await l.at(tNudge);
        okIndex(await l.send({ to: carol, amount: nudgeAmount }), 'nudge');

        const t1 = tNudge + 10n * S;
        const live = { to: dave, amount: 300_000n, ts: t1 };
        await l.at(t1);
        const liveIdx = okIndex(await l.send(live), 'live seed');
        const t2 = t1 + 1n * S;
        const future = { to: dave, amount: 300_001n, ts: t2 + DRIFT_NS }; // dated +drift
        await l.at(t2);
        const futureIdx = okIndex(await l.send(future), 'live seed dated +drift');

        const accounts = [alice, bob, carol, dave, l.owner.getPrincipal()];
        const balancesBefore = await Promise.all(accounts.map((p) => l.balance(p)));
        const logBefore = kind === 'token' ? await l.blocks(0n, 1_000n) : [];
        const sizeBefore = kind === 'probe' ? await l.recentsSize() : 0n;
        if (kind === 'probe') {
          // Precondition: the base build left expired seeds in the index.
          expect(sizeBefore, 'expired seeds linger on the base build').toBeGreaterThan(3n); // 3 live: nudge, live, future
        }

        // ---- upgrade ----
        await l.at(t2 + 10n * S);
        await l.upgrade(WASMS[kind].current);

        expect(await Promise.all(accounts.map((p) => l.balance(p))), 'balances').toEqual(balancesBefore);
        if (kind === 'token') expect(await l.blocks(0n, 1_000n), 'block log').toEqual(logBefore);
        if (kind === 'probe') expect(await l.recentsSize(), 'the upgrade itself sweeps nothing').toBe(sizeBefore);

        // ---- after the upgrade ----
        await l.at(t1 + 60n * S);
        expect(outcome(await l.send(live), liveIdx), 'live key').toEqual('Duplicate(+0)');
        expect(outcome(await l.send(dead[0]), deadIdx[0]), 'expired key').toEqual('TooOld');

        if (kind === 'probe') {
          // Drain: the 3 live entries (nudge, live, future) plus one per
          // call stay; every expired one goes. The first call after the
          // upgrade examines SWEEP_MIN entries, the next ones SWEEP_MIN + SWEEP_PER_INSERT.
          let size = await l.recentsSize();
          for (let c = 1; c <= DRAIN_CALLS; c++) {
            okIndex(await l.send({ to: carol, amount: 400_000n + BigInt(c) }), `drain call ${c}`);
            size = await l.recentsSize();
          }
          expect(SWEEP_MIN + (DRAIN_CALLS - 1) * (SWEEP_MIN + SWEEP_PER_INSERT), 'the calls cover a lap')
            .toBeGreaterThan(Number(sizeBefore) + DRAIN_CALLS);
          expect(size, 'drained to the live set').toBe(BigInt(3 + DRAIN_CALLS));
        }

        // The key dated +drift, inserted BEFORE the upgrade, is still a
        // duplicate between its insertion + window + drift and + 2·drift.
        await l.at(t2 + WINDOW_NS + (3n * DRIFT_NS) / 2n);
        expect(outcome(await l.send(future), futureIdx), 'key dated +drift, after the upgrade').toEqual('Duplicate(+0)');
        expect(await l.balance(dave), 'dave paid once per key').toBe(600_001n);
      } finally {
        await l.tearDown();
      }
    }, 300_000);
  }
});
