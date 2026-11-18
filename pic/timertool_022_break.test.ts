/**
 * timer-tool 0.2.2 is a declared break (vendor/README.md, "timer-tool"): a
 * ledger built with timer-tool 0.2.0-0.2.1 cannot be upgraded in place to the
 * current build. Motoko checks the whole stored type, and 0.2.2 changed
 * `#v0_1_0`, so the runtime refuses the upgrade (M0170).
 *
 * The other upgrade tests build their baselines with HEAD's timer-tool 0.2.2
 * swapped in (pic/build-baseline-wasm.sh), so none of them sees the break.
 * This one keeps it under test: `token_pre_tt022` is the ledger just before
 * the bump (41fd7aa^ = 09ba06a) with its own timer-tool 0.2.1 (keep-tt).
 * - Upgrading it to TOKEN_WASM must be refused with the M0170 message, and the
 *   ledger must still answer afterwards.
 * - The control upgrades TOKEN_WASM to itself, so the refusal is not a
 *   property of TOKEN_WASM alone.
 * If a later change made the two compatible again, the first test turns red,
 * and the declaration in vendor/README.md has to be updated with it.
 * Counterproof: TOKEN_PRE_TT022_WASM=<a 0.2.2 build> (TOKEN_WASM itself, say)
 * makes the refusal test red.
 *
 * Wasms: `bash pic/build-token-wasm.sh token token_pre_tt022`.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { createIdentity, installLedger, upgradeLedger, wasmPath } from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');
const PRE_WASM = wasmPath('TOKEN_PRE_TT022_WASM', 'token_pre_tt022');
const REFUSAL = 'Memory-incompatible program upgrade';

const owner = createIdentity(1).getPrincipal();

let picServer: PocketIcServer;
let pic: PocketIc;

async function symbol(id: Principal): Promise<string> {
  const res = await pic.queryCall({
    canisterId: id,
    method: 'icrc1_symbol',
    arg: new Uint8Array(IDL.encode([], [])),
    sender: owner,
  });
  return IDL.decode([IDL.Text], res)[0] as string;
}

beforeAll(async () => {
  picServer = await PocketIcServer.start();
  pic = await PocketIc.create(picServer.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
}, 120000);

afterAll(async () => {
  await pic?.tearDown();
  await picServer?.stop();
});

describe('timer-tool 0.2.2: declared break with 0.2.0-0.2.1 ledgers', () => {
  it('control: the current build upgrades in place to itself', async () => {
    const { id } = await installLedger(pic, TOKEN_WASM, owner, null);
    await upgradeLedger(pic, id, TOKEN_WASM, owner, null);
    expect(await symbol(id)).toBeTypeOf('string');
  });

  it('a ledger built with timer-tool 0.2.1 is refused (M0170) and still answers', async () => {
    const { id } = await installLedger(pic, PRE_WASM, owner, null);
    const sym = await symbol(id);
    let error: unknown;
    try {
      await upgradeLedger(pic, id, TOKEN_WASM, owner, null);
    } catch (e) {
      error = e;
    }
    expect(error, 'HEAD accepted an in-place upgrade from timer-tool 0.2.1: the declared break is gone').toBeDefined();
    expect(String((error as Error)?.message ?? error)).toContain(REFUSAL);
    expect(await symbol(id), 'the refused ledger must still answer').toEqual(sym);
  });
});
