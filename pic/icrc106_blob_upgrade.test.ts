/**
 * A ledger set by a build BEFORE the ICRC-106 index principal was stored as
 * #Text keeps a `#Blob` in its metadata, and the current build must still
 * answer it.
 *
 * pic/icrc106.test.ts upgrades the current wasm to itself, so its value is
 * already #Text and the `case (#Blob(b))` of `get_icrc106_index_principal`
 * (vendor/icrc1-mo/src/ICRC1/lib.mo) is never reached: delete that case and
 * that suite stays green while a real ledger answers IndexPrincipalNotSet.
 * Here the baseline (`token_pre_text106`, d894507, whose setter stored #Blob) is
 * installed, set, and upgraded in place to TOKEN_WASM.
 *
 * Wasms: `bash pic/build-token-wasm.sh` builds both. TOKEN_WASM /
 * TOKEN_PRE_TEXT106_WASM point at other builds.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { createIdentity, installLedger, upgradeLedger, wasmPath } from './archive_harness';

const TOKEN_WASM = wasmPath('TOKEN_WASM', 'token');
const BASELINE_WASM = wasmPath('TOKEN_PRE_TEXT106_WASM', 'token_pre_text106');

const owner = createIdentity(1).getPrincipal();
const indexA = createIdentity(2).getPrincipal();
const indexB = createIdentity(3).getPrincipal();

const Value = IDL.Rec();
Value.fill(
  IDL.Variant({
    Int: IDL.Int,
    Map: IDL.Vec(IDL.Tuple(IDL.Text, Value)),
    Nat: IDL.Nat,
    Blob: IDL.Vec(IDL.Nat8),
    Text: IDL.Text,
    Array: IDL.Vec(Value),
  }),
);
const MetaDatum = IDL.Tuple(IDL.Text, Value);
const Icrc106Result = IDL.Variant({
  Ok: IDL.Principal,
  Err: IDL.Variant({
    GenericError: IDL.Record({ description: IDL.Text, error_code: IDL.Nat }),
    IndexPrincipalNotSet: IDL.Null,
  }),
});

let picServer: PocketIcServer;
let pic: PocketIc;
let id: Principal;

async function getIndex(): Promise<any> {
  const res = await pic.queryCall({
    canisterId: id,
    method: 'icrc106_get_index_principal',
    arg: new Uint8Array(IDL.encode([], [])),
    sender: owner,
  });
  return IDL.decode([Icrc106Result], res)[0];
}

async function indexMetadata(): Promise<any> {
  const res = await pic.queryCall({
    canisterId: id,
    method: 'icrc1_metadata',
    arg: new Uint8Array(IDL.encode([], [])),
    sender: owner,
  });
  const entry = (IDL.decode([IDL.Vec(MetaDatum)], res)[0] as any[]).find(([k]) => k === 'icrc106:index_principal');
  expect(entry, 'icrc106:index_principal missing from icrc1_metadata').toBeDefined();
  return entry![1];
}

async function setIndex(p: Principal): Promise<void> {
  await pic.updateCall({
    canisterId: id,
    method: 'set_icrc106_index_principal',
    arg: new Uint8Array(IDL.encode([IDL.Opt(IDL.Principal)], [[p]])),
    sender: owner,
  });
}

beforeAll(async () => {
  picServer = await PocketIcServer.start();
  pic = await PocketIc.create(picServer.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
  ({ id } = await installLedger(pic, BASELINE_WASM, owner, null));
}, 120000);

afterAll(async () => {
  await pic?.tearDown();
  await picServer?.stop();
});

describe('ICRC-106 index principal: a #Blob left by the baseline', () => {
  it('positive control: the baseline stores the index principal as #Blob', async () => {
    await setIndex(indexA);
    expect(Object.keys(await indexMetadata()), 'the baseline must hold a #Blob, or this suite proves nothing').toEqual(['Blob']);
    expect((await getIndex()).Ok.toText()).toEqual(indexA.toText());
  });

  it('after the upgrade to the current build the getter still answers the #Blob', async () => {
    await upgradeLedger(pic, id, TOKEN_WASM, owner, null);
    const got = await getIndex();
    expect(got.Err, 'a #Blob left by the baseline must not read as IndexPrincipalNotSet').toBeUndefined();
    expect(got.Ok.toText()).toEqual(indexA.toText());
  });

  it('the upgrade leaves the metadata value as #Blob', async () => {
    const value = await indexMetadata();
    expect(Object.keys(value)).toEqual(['Blob']);
    expect(Principal.fromUint8Array(Uint8Array.from(value.Blob)).toText()).toEqual(indexA.toText());
  });

  it('setting it again with the current build stores #Text', async () => {
    await setIndex(indexB);
    const value = await indexMetadata();
    expect(Object.keys(value)).toEqual(['Text']);
    expect(value.Text).toEqual(indexB.toText());
    expect((await getIndex()).Ok.toText()).toEqual(indexB.toText());
  });
});
