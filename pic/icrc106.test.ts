/**
 * ICRC-106 PIC Tests
 * 
 * Tests the ICRC-106 (Index Principal) implementation:
 * 1. Controller can set the index principal
 * 2. icrc106_get_index_principal returns the set principal
 * 3. icrc1_metadata includes icrc106:index_principal, as #Text (ICRC-106), after set
 * 4. Index principal persists across upgrade
 * 5. Returns IndexPrincipalNotSet error before setting
 * 6. Non-controller cannot set index principal
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { PocketIc, PocketIcServer, SubnetStateType } from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';
import { resolve } from 'path';
import { readFileSync, existsSync } from 'fs';
import { Ed25519KeyIdentity } from '@dfinity/identity';

const TOKEN_WASM_PATH = resolve(__dirname, '../.dfx/local/canisters/token/token.wasm.gz');

// =============== IDL Types ===============

const Account = IDL.Record({
  owner: IDL.Principal,
  subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
});

const Icrc106Error = IDL.Variant({
  GenericError: IDL.Record({ description: IDL.Text, error_code: IDL.Nat }),
  IndexPrincipalNotSet: IDL.Null,
});

const Icrc106Result = IDL.Variant({
  Ok: IDL.Principal,
  Err: Icrc106Error,
});

const Value = IDL.Rec();
Value.fill(
  IDL.Variant({
    Int: IDL.Int,
    Map: IDL.Vec(IDL.Tuple(IDL.Text, Value)),
    Nat: IDL.Nat,
    Blob: IDL.Vec(IDL.Nat8),
    Text: IDL.Text,
    Array: IDL.Vec(Value),
  })
);

const MetaDatum = IDL.Tuple(IDL.Text, Value);

/**
 * The `icrc106:index_principal` metadata value as ICRC-106 defines it: `#Text`
 * holding the principal's textual form, which must parse back to itself.
 */
function indexPrincipalText(value: any): string {
  expect(Object.keys(value), 'icrc106:index_principal must be #Text (ICRC-106.md:28,58)').toEqual(['Text']);
  expect(Principal.fromText(value.Text).toText()).toEqual(value.Text);
  return value.Text;
}

// =============== Token Init ===============

function buildTokenInitTypes(IDL: typeof import('@icp-sdk/core/candid').IDL) {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });

  const Fee = IDL.Variant({
    Environment: IDL.Null,
    Fixed: IDL.Nat,
    ICRC1: IDL.Null,
  });

  const MaxAllowance = IDL.Variant({
    TotalSupply: IDL.Null,
    Fixed: IDL.Nat,
  });

  const ArchiveIndexType = IDL.Variant({
    Stable: IDL.Null,
    StableTyped: IDL.Null,
    Managed: IDL.Null,
  });

  const BlockType = IDL.Record({
    block_type: IDL.Text,
    url: IDL.Text,
  });

  const Value = IDL.Rec();
  Value.fill(
    IDL.Variant({
      Int: IDL.Int,
      Map: IDL.Vec(IDL.Tuple(IDL.Text, Value)),
      Nat: IDL.Nat,
      Blob: IDL.Vec(IDL.Nat8),
      Text: IDL.Text,
      Array: IDL.Vec(Value),
    })
  );

  const Transaction = IDL.Record({
    burn: IDL.Opt(IDL.Record({
      from: Account,
      memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
      created_at_time: IDL.Opt(IDL.Nat64),
      amount: IDL.Nat,
    })),
    kind: IDL.Text,
    mint: IDL.Opt(IDL.Record({
      to: Account,
      memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
      created_at_time: IDL.Opt(IDL.Nat64),
      amount: IDL.Nat,
    })),
    timestamp: IDL.Nat64,
    index: IDL.Nat,
    transfer: IDL.Opt(IDL.Record({
      to: Account,
      fee: IDL.Opt(IDL.Nat),
      from: Account,
      memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
      created_at_time: IDL.Opt(IDL.Nat64),
      amount: IDL.Nat,
    })),
  });

  const AdvancedSettings = IDL.Record({
    existing_balances: IDL.Vec(IDL.Tuple(Account, IDL.Nat)),
    burned_tokens: IDL.Nat,
    fee_collector_emitted: IDL.Bool,
    minted_tokens: IDL.Nat,
    local_transactions: IDL.Vec(Transaction),
    fee_collector_block: IDL.Nat,
  });

  const ICRC1InitArgs = IDL.Record({
    name: IDL.Opt(IDL.Text),
    symbol: IDL.Opt(IDL.Text),
    logo: IDL.Opt(IDL.Text),
    decimals: IDL.Nat8,
    fee: IDL.Opt(Fee),
    minting_account: IDL.Opt(Account),
    max_supply: IDL.Opt(IDL.Nat),
    min_burn_amount: IDL.Opt(IDL.Nat),
    max_memo: IDL.Opt(IDL.Nat),
    advanced_settings: IDL.Opt(AdvancedSettings),
    metadata: IDL.Opt(Value),
    fee_collector: IDL.Opt(Account),
    transaction_window: IDL.Opt(IDL.Nat64),
    permitted_drift: IDL.Opt(IDL.Nat64),
    max_accounts: IDL.Opt(IDL.Nat),
    settle_to_accounts: IDL.Opt(IDL.Nat),
  });

  const ICRC2InitArgs = IDL.Record({
    max_approvals_per_account: IDL.Opt(IDL.Nat),
    max_allowance: IDL.Opt(MaxAllowance),
    fee: IDL.Opt(Fee),
    advanced_settings: IDL.Opt(IDL.Null),
    max_approvals: IDL.Opt(IDL.Nat),
    settle_to_approvals: IDL.Opt(IDL.Nat),
  });

  const ICRC3InitArgs = IDL.Record({
    maxActiveRecords: IDL.Nat,
    settleToRecords: IDL.Nat,
    maxRecordsInArchiveInstance: IDL.Nat,
    maxArchivePages: IDL.Nat,
    archiveIndexType: ArchiveIndexType,
    maxRecordsToArchive: IDL.Nat,
    archiveCycles: IDL.Nat,
    archiveControllers: IDL.Opt(IDL.Opt(IDL.Vec(IDL.Principal))),
    supportedBlocks: IDL.Vec(BlockType),
  });

  const ICRC4InitArgs = IDL.Record({
    max_balances: IDL.Opt(IDL.Nat),
    max_transfers: IDL.Opt(IDL.Nat),
    fee: IDL.Opt(Fee),
  });

  const FullInitArgs = IDL.Opt(IDL.Record({
    icrc1: IDL.Opt(ICRC1InitArgs),
    icrc2: IDL.Opt(ICRC2InitArgs),
    icrc3: ICRC3InitArgs,
    icrc4: IDL.Opt(ICRC4InitArgs),
    icrc85_collector: IDL.Opt(IDL.Principal),
  }));

  return FullInitArgs;
}

// =============== Helpers ===============

function createIdentity(seed: number): Ed25519KeyIdentity {
  const seedArray = new Uint8Array(32);
  seedArray[0] = seed;
  return Ed25519KeyIdentity.generate(seedArray);
}

function defaultTokenArgs() {
  return [{
    icrc1: [],
    icrc2: [],
    icrc3: {
      maxActiveRecords: BigInt(3000),
      settleToRecords: BigInt(2000),
      maxRecordsInArchiveInstance: BigInt(500000),
      maxArchivePages: BigInt(62500),
      archiveIndexType: { Stable: null },
      maxRecordsToArchive: BigInt(8000),
      archiveCycles: BigInt(20_000_000_000_000),
      archiveControllers: [],
      supportedBlocks: [],
    },
    icrc4: [{
      max_balances: [BigInt(100)],
      max_transfers: [BigInt(100)],
      fee: [],
    }],
    icrc85_collector: [],
  }];
}

// =============== Test Suite ===============

describe('ICRC-106 Index Principal Tests', () => {
  let pic: PocketIc;
  let picServer: PocketIcServer;
  let tokenCanisterId: Principal;
  const admin = createIdentity(10);
  const nonAdmin = createIdentity(11);
  const fakeIndexPrincipal = createIdentity(12).getPrincipal();
  const fakeIndexPrincipal2 = createIdentity(13).getPrincipal();

  beforeAll(async () => {
    if (!existsSync(TOKEN_WASM_PATH)) {
      throw new Error(`Token WASM not found at ${TOKEN_WASM_PATH}. Run 'dfx build token' first.`);
    }

    picServer = await PocketIcServer.start();
    pic = await PocketIc.create(picServer.getUrl(), {
      application: [{ state: { type: SubnetStateType.New } }],
    });

    const tokenWasm = readFileSync(TOKEN_WASM_PATH);
    const TokenInitType = buildTokenInitTypes(IDL);

    tokenCanisterId = await pic.createCanister({
      sender: admin.getPrincipal(),
    });
    await pic.addCycles(tokenCanisterId, 100_000_000_000_000n);

    await pic.installCode({
      canisterId: tokenCanisterId,
      wasm: tokenWasm,
      arg: IDL.encode([TokenInitType], [defaultTokenArgs()]),
      sender: admin.getPrincipal(),
    });

    console.log('Token canister deployed:', tokenCanisterId.toText());
  }, 120000);

  afterAll(async () => {
    if (pic) await pic.tearDown();
    if (picServer) await picServer.stop();
  });

  it('should return IndexPrincipalNotSet before setting', async () => {
    const result = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });

    const decoded = IDL.decode([Icrc106Result], result)[0] as any;
    expect(decoded.Err).toBeDefined();
    expect(decoded.Err.IndexPrincipalNotSet).toBeDefined();
  });

  it('should allow controller to set index principal', async () => {
    const result = await pic.updateCall({
      canisterId: tokenCanisterId,
      method: 'set_icrc106_index_principal',
      arg: IDL.encode([IDL.Opt(IDL.Principal)], [[fakeIndexPrincipal]]),
      sender: admin.getPrincipal(),
    });

    // set_icrc106_index_principal returns ()
    IDL.decode([], result);
  });

  it('should return the set index principal', async () => {
    const result = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });

    const decoded = IDL.decode([Icrc106Result], result)[0] as any;
    expect(decoded.Ok).toBeDefined();
    expect(decoded.Ok.toText()).toEqual(fakeIndexPrincipal.toText());
  });

  it('should include icrc106:index_principal in icrc1_metadata', async () => {
    const result = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc1_metadata',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });

    const decoded = IDL.decode([IDL.Vec(MetaDatum)], result)[0] as any[];
    
    // Find the icrc106:index_principal entry
    const icrc106Entry = decoded.find(([key, _val]: [string, any]) => key === 'icrc106:index_principal');
    
    expect(icrc106Entry).toBeDefined();
    // ICRC-106.md:28,58: "(text): The textual representation of the principal
    // of the associated index canister". A `#Blob` here fails the standard.
    expect(indexPrincipalText(icrc106Entry[1])).toEqual(fakeIndexPrincipal.toText());
  });

  // A non-owner no longer reaches the body by ingress: `inspect` refuses the
  // message first. The body's own "Unauthorized" is proven through a caller
  // canister in inspect.test.ts ("the body guards still decide, past the filter").
  it('should refuse a non-owner setting the index principal at ingress', async () => {
    await expect(pic.updateCall({
      canisterId: tokenCanisterId,
      method: 'set_icrc106_index_principal',
      arg: IDL.encode([IDL.Opt(IDL.Principal)], [[fakeIndexPrincipal2]]),
      sender: nonAdmin.getPrincipal(),
    })).rejects.toThrow(/inspect_message/i);
  });

  it('should update index principal and metadata when changed', async () => {
    // Set to a new principal
    await pic.updateCall({
      canisterId: tokenCanisterId,
      method: 'set_icrc106_index_principal',
      arg: IDL.encode([IDL.Opt(IDL.Principal)], [[fakeIndexPrincipal2]]),
      sender: admin.getPrincipal(),
    });

    // Verify get returns the new value
    const getResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const decoded = IDL.decode([Icrc106Result], getResult)[0] as any;
    expect(decoded.Ok.toText()).toEqual(fakeIndexPrincipal2.toText());

    // Verify metadata is updated
    const metaResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc1_metadata',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const metadata = IDL.decode([IDL.Vec(MetaDatum)], metaResult)[0] as any[];
    const icrc106Entry = metadata.find(([key, _val]: [string, any]) => key === 'icrc106:index_principal');
    expect(icrc106Entry).toBeDefined();
    expect(indexPrincipalText(icrc106Entry[1])).toEqual(fakeIndexPrincipal2.toText());
  });

  it('should remove icrc106:index_principal from metadata when unset', async () => {
    // Unset the index principal
    await pic.updateCall({
      canisterId: tokenCanisterId,
      method: 'set_icrc106_index_principal',
      arg: IDL.encode([IDL.Opt(IDL.Principal)], [[]]),
      sender: admin.getPrincipal(),
    });

    // Verify get returns error
    const getResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const decoded = IDL.decode([Icrc106Result], getResult)[0] as any;
    expect(decoded.Err).toBeDefined();
    expect(decoded.Err.IndexPrincipalNotSet).toBeDefined();

    // Verify metadata no longer has the entry
    const metaResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc1_metadata',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const metadata = IDL.decode([IDL.Vec(MetaDatum)], metaResult)[0] as any[];
    const icrc106Entry = metadata.find(([key, _val]: [string, any]) => key === 'icrc106:index_principal');
    expect(icrc106Entry).toBeUndefined();
  });

  it('should persist index principal across upgrade', async () => {
    // Set index principal
    await pic.updateCall({
      canisterId: tokenCanisterId,
      method: 'set_icrc106_index_principal',
      arg: IDL.encode([IDL.Opt(IDL.Principal)], [[fakeIndexPrincipal]]),
      sender: admin.getPrincipal(),
    });

    // Verify it's set
    const preUpgradeResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const preDecoded = IDL.decode([Icrc106Result], preUpgradeResult)[0] as any;
    expect(preDecoded.Ok.toText()).toEqual(fakeIndexPrincipal.toText());

    // Upgrade the canister (reinstall with mode=upgrade)
    const tokenWasm = readFileSync(TOKEN_WASM_PATH);
    const TokenInitType = buildTokenInitTypes(IDL);

    await pic.upgradeCanister({
      canisterId: tokenCanisterId,
      wasm: tokenWasm,
      arg: IDL.encode([TokenInitType], [defaultTokenArgs()]),
      sender: admin.getPrincipal(),
      upgradeModeOptions: {
        skip_pre_upgrade: [],
        wasm_memory_persistence: [{ keep: null }],
      },
    });

    // Verify index principal persists after upgrade
    const postUpgradeResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc106_get_index_principal',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const postDecoded = IDL.decode([Icrc106Result], postUpgradeResult)[0] as any;
    expect(postDecoded.Ok).toBeDefined();
    expect(postDecoded.Ok.toText()).toEqual(fakeIndexPrincipal.toText());

    // Also verify metadata persists after upgrade
    const metaResult = await pic.queryCall({
      canisterId: tokenCanisterId,
      method: 'icrc1_metadata',
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });
    const metadata = IDL.decode([IDL.Vec(MetaDatum)], metaResult)[0] as any[];
    const icrc106Entry = metadata.find(([key, _val]: [string, any]) => key === 'icrc106:index_principal');
    expect(icrc106Entry).toBeDefined();
    expect(indexPrincipalText(icrc106Entry[1])).toEqual(fakeIndexPrincipal.toText());
  });

  it.each(['icrc1_supported_standards', 'icrc10_supported_standards'])('should include ICRC-106 in %s', async (method) => {
    const result = await pic.queryCall({
      canisterId: tokenCanisterId,
      method,
      arg: IDL.encode([], []),
      sender: admin.getPrincipal(),
    });

    const StandardType = IDL.Record({
      name: IDL.Text,
      url: IDL.Text,
    });
    const decoded = IDL.decode([IDL.Vec(StandardType)], result)[0] as any[];
    
    const icrc106Standard = decoded.find((s: any) => s.name === 'ICRC-106');
    expect(icrc106Standard).toBeDefined();
    expect(icrc106Standard.url).toContain('ICRC-106');
  });
});
