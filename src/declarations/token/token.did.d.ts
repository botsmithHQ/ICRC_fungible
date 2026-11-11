import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export interface ArchiveControllersResult {
  'result' : { 'Ok' : Array<Principal> } |
    { 'Err' : string },
  'canister_id' : Principal,
}
export interface ArchiveUpgradeResult {
  'result' : { 'Ok' : null } |
    { 'Err' : string },
  'canister_id' : Principal,
}
export interface Account {
  'owner' : Principal,
  'subaccount' : [] | [Subaccount],
}
export interface Account__5 {
  'owner' : Principal,
  'subaccount' : [] | [Uint8Array | number[]],
}
export interface AdvancedSettings {
  'existing_balances' : Array<[Account, Balance]>,
  'burned_tokens' : Balance,
  'fee_collector_emitted' : boolean,
  'minted_tokens' : Balance,
  'local_transactions' : Array<Transaction>,
  'fee_collector_block' : bigint,
}
export interface AdvancedSettings__1 {
  'existing_approvals' : Array<[[Account, Account], ApprovalInfo]>,
}
export interface Allowance {
  'allowance' : bigint,
  'expires_at' : [] | [bigint],
}
export interface AllowanceArgs { 'account' : Account, 'spender' : Account }
export interface AllowanceDetail {
  'from_account' : Account,
  'to_spender' : Account,
  'allowance' : bigint,
  'expires_at' : [] | [bigint],
}
export type AllowanceResult = { 'Ok' : Array<AllowanceDetail> } |
  { 'Err' : GetAllowancesError };
export interface ApprovalInfo {
  'from_subaccount' : [] | [Uint8Array | number[]],
  'amount' : bigint,
  'expires_at' : [] | [bigint],
  'spender' : Account,
}
export interface Approve {
  'fee' : [] | [bigint],
  'from' : Account__5,
  'memo' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
  'expected_allowance' : [] | [bigint],
  'expires_at' : [] | [bigint],
  'spender' : Account__5,
}
export interface ApproveArgs {
  'fee' : [] | [bigint],
  'memo' : [] | [Uint8Array | number[]],
  'from_subaccount' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
  'expected_allowance' : [] | [bigint],
  'expires_at' : [] | [bigint],
  'spender' : Account,
}
export type ApproveError = {
    'GenericError' : { 'message' : string, 'error_code' : bigint }
  } |
  { 'TemporarilyUnavailable' : null } |
  { 'Duplicate' : { 'duplicate_of' : bigint } } |
  { 'BadFee' : { 'expected_fee' : bigint } } |
  { 'AllowanceChanged' : { 'current_allowance' : bigint } } |
  { 'CreatedInFuture' : { 'ledger_time' : bigint } } |
  { 'TooOld' : null } |
  { 'Expired' : { 'ledger_time' : bigint } } |
  { 'InsufficientFunds' : { 'balance' : bigint } };
export type ApproveResponse = { 'Ok' : bigint } |
  { 'Err' : ApproveError };
export interface ArchivedTransactionResponse {
  'args' : Array<TransactionRange>,
  'callback' : [Principal, string],
}
export type Balance = bigint;
export interface BalanceQueryArgs { 'accounts' : Array<Account> }
export type BalanceQueryResult = Array<bigint>;
export interface BlockType { 'url' : string, 'block_type' : string }
export interface Burn {
  'from' : Account,
  'memo' : [] | [Memo],
  'created_at_time' : [] | [Timestamp],
  'amount' : Balance,
}
export interface BurnArgs {
  'memo' : [] | [Memo],
  'from_subaccount' : [] | [Subaccount],
  'created_at_time' : [] | [Timestamp],
  'amount' : Balance,
}
export interface Burn__1 {
  'from' : Account__5,
  'memo' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
  'spender' : [] | [Account__5],
}
export interface ConsentInfo {
  'metadata' : ConsentMessageMetadata,
  'consent_message' : ConsentMessage,
}
export type ConsentMessage = {
    'FieldsDisplayMessage' : {
      'fields' : Array<[string, DisplayValue]>,
      'intent' : string,
    }
  } |
  { 'GenericDisplayMessage' : string };
export interface ConsentMessageMetadata {
  'utc_offset_minutes' : [] | [number],
  'language' : string,
}
export interface ConsentMessageRequest {
  'arg' : Uint8Array | number[],
  'method' : string,
  'user_preferences' : ConsentMessageSpec,
}
export type ConsentMessageResponse = { 'Ok' : ConsentInfo } |
  { 'Err' : Icrc21Error };
export interface ConsentMessageSpec {
  'metadata' : ConsentMessageMetadata,
  'device_spec' : [] | [
    { 'GenericDisplay' : null } |
      { 'FieldsDisplay' : null }
  ],
}
export interface DataCertificate {
  'certificate' : Uint8Array | number[],
  'hash_tree' : Uint8Array | number[],
}
export type DisplayValue = { 'Text' : { 'content' : string } } |
  {
    'TokenAmount' : {
      'decimals' : number,
      'amount' : bigint,
      'symbol' : string,
    }
  } |
  { 'TimestampSeconds' : { 'amount' : bigint } } |
  { 'DurationSeconds' : { 'amount' : bigint } };
export interface ErrorInfo { 'description' : string }
export type Fee = { 'Environment' : null } |
  { 'Fixed' : bigint };
export type Fee__1 = { 'ICRC1' : null } |
  { 'Environment' : null } |
  { 'Fixed' : bigint };
export interface GetAllowancesArgs {
  'take' : [] | [bigint],
  'prev_spender' : [] | [Account],
  'from_account' : [] | [Account],
}
export type GetAllowancesError = {
    'GenericError' : { 'message' : string, 'error_code' : bigint }
  } |
  { 'AccessDenied' : { 'reason' : string } };
export interface GetArchiveTransactionsResponse {
  'transactions' : Array<Transaction__1>,
}
export interface GetArchivesArgs { 'from' : [] | [Principal] }
export type GetArchivesResult = Array<GetArchivesResultItem>;
export interface GetArchivesResultItem {
  'end' : bigint,
  'canister_id' : Principal,
  'start' : bigint,
}
export type GetBlocksArgs = Array<TransactionRange>;
export interface GetBlocksRequest { 'start' : bigint, 'length' : bigint }
export interface GetBlocksResult {
  'log_length' : bigint,
  'blocks' : Array<{ 'id' : bigint, 'block' : Value__1 }>,
  'archived_blocks' : Array<ArchivedTransactionResponse>,
}
export type GetFeeCollectorError = {
    'GenericError' : { 'message' : string, 'error_code' : bigint }
  };
export type GetFeeCollectorResult = { 'Ok' : [] | [Account] } |
  { 'Err' : GetFeeCollectorError };
export type GetLegacyArchiveTransactionFunction = ActorMethod<
  [GetBlocksRequest],
  GetArchiveTransactionsResponse
>;
export type GetTransactionsFn = ActorMethod<
  [Array<TransactionRange>],
  GetTransactionsResult
>;
export interface GetTransactionsResponse {
  'first_index' : bigint,
  'log_length' : bigint,
  'transactions' : Array<Transaction__1>,
  'archived_transactions' : Array<LegacyArchivedRange>,
}
export interface GetTransactionsResult {
  'log_length' : bigint,
  'blocks' : Array<{ 'id' : bigint, 'block' : Value__1 }>,
  'archived_blocks' : Array<ArchivedTransactionResponse>,
}
export type Icrc106Error = {
    'GenericError' : { 'description' : string, 'error_code' : bigint }
  } |
  { 'IndexPrincipalNotSet' : null };
export type Icrc106GetResult = { 'Ok' : Principal } |
  { 'Err' : Icrc106Error };
export type Icrc21Error = {
    'GenericError' : { 'description' : string, 'error_code' : bigint }
  } |
  { 'InsufficientPayment' : ErrorInfo } |
  { 'UnsupportedCanisterCall' : ErrorInfo } |
  { 'ConsentMessageUnavailable' : ErrorInfo };
export type IndexType = { 'Stable' : null } |
  { 'StableTyped' : null } |
  { 'Managed' : null };
export interface InitArgs {
  'fee' : [] | [Fee],
  'advanced_settings' : [] | [AdvancedSettings],
  'max_memo' : [] | [bigint],
  'decimals' : number,
  'metadata' : [] | [Value],
  'minting_account' : [] | [Account],
  'logo' : [] | [string],
  'permitted_drift' : [] | [Timestamp],
  'name' : [] | [string],
  'settle_to_accounts' : [] | [bigint],
  'fee_collector' : [] | [Account],
  'transaction_window' : [] | [Timestamp],
  'min_burn_amount' : [] | [Balance],
  'max_supply' : [] | [Balance],
  'max_accounts' : [] | [bigint],
  'symbol' : [] | [string],
}
export interface InitArgs__1 {
  'fee' : [] | [Fee__1],
  'advanced_settings' : [] | [AdvancedSettings__1],
  'max_allowance' : [] | [MaxAllowance],
  'max_approvals' : [] | [bigint],
  'icrc103_max_take_value' : [] | [bigint],
  'cleanup_on_zero_balance' : [] | [boolean],
  'icrc103_public_allowances' : [] | [boolean],
  'max_approvals_per_account' : [] | [bigint],
  'settle_to_approvals' : [] | [bigint],
  'cleanup_interval' : [] | [bigint],
}
export interface InitArgs__2 {
  'maxRecordsToArchive' : bigint,
  'archiveIndexType' : IndexType,
  'maxArchivePages' : bigint,
  'settleToRecords' : bigint,
  'archiveCycles' : bigint,
  'maxActiveRecords' : bigint,
  'maxRecordsInArchiveInstance' : bigint,
  'archiveControllers' : [] | [[] | [Array<Principal>]],
  'supportedBlocks' : Array<BlockType>,
}
export interface InitArgs__3 {
  'fee' : [] | [Fee__1],
  'max_balances' : [] | [bigint],
  'max_transfers' : [] | [bigint],
}
export interface LegacyArchiveInfo {
  'block_range_end' : bigint,
  'canister_id' : Principal,
  'block_range_start' : bigint,
}
export interface LegacyArchivedRange {
  'callback' : [Principal, string],
  'start' : bigint,
  'length' : bigint,
}
export type Map = Array<[string, Value__2]>;
export type MaxAllowance = { 'TotalSupply' : null } |
  { 'Fixed' : bigint };
export type Memo = Uint8Array | number[];
export type MetaDatum = [string, Value];
export interface Mint {
  'to' : Account,
  'memo' : [] | [Memo],
  'created_at_time' : [] | [Timestamp],
  'amount' : Balance,
}
export interface Mint__2 {
  'to' : Account__5,
  'memo' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
}
export interface RosettaArchivedRange {
  'callback' : [Principal, string],
  'start' : bigint,
  'length' : bigint,
}
export interface RosettaBlockRange { 'blocks' : Array<Value__2> }
export interface RosettaGetBlocksResponse {
  'certificate' : [] | [Uint8Array | number[]],
  'first_index' : bigint,
  'blocks' : Array<Value__2>,
  'chain_length' : bigint,
  'archived_blocks' : Array<RosettaArchivedRange>,
}
export interface SetFeeCollectorArgs {
  'fee_collector' : [] | [Account],
  'created_at_time' : bigint,
}
export type SetFeeCollectorError = { 'InvalidAccount' : string } |
  { 'GenericError' : { 'message' : string, 'error_code' : bigint } } |
  { 'AccessDenied' : string } |
  { 'Duplicate' : { 'duplicate_of' : bigint } } |
  { 'CreatedInFuture' : { 'ledger_time' : bigint } } |
  { 'TooOld' : null };
export type SetFeeCollectorResult = { 'Ok' : bigint } |
  { 'Err' : SetFeeCollectorError };
export type Subaccount = Uint8Array | number[];
export interface Stats {
  'archives' : Array<[Principal, TransactionRange]>,
  'bCleaning' : boolean,
  'constants' : {
    'archiveProperties' : {
      'archiveControllers' : [] | [[] | [Array<Principal>]],
      'archiveCycles' : bigint,
      'maxActiveRecords' : bigint,
      'maxRecordsInArchiveInstance' : bigint,
      'maxRecordsToArchive' : bigint,
      'settleToRecords' : bigint,
    },
  },
  'firstIndex' : bigint,
  'lastIndex' : bigint,
  'ledgerCanister' : Principal,
  'localLedgerSize' : bigint,
  'supportedBlocks' : Array<BlockType>,
}
export interface SupportedStandard { 'url' : string, 'name' : string }
export type Timestamp = bigint;
export interface Tip {
  'last_block_index' : Uint8Array | number[],
  'hash_tree' : Uint8Array | number[],
  'last_block_hash' : Uint8Array | number[],
}
export interface Token {
  'accept_ownership' : ActorMethod<[], undefined>,
  'admin_init' : ActorMethod<[], undefined>,
  'admin_lock_supply' : ActorMethod<[], undefined>,
  'admin_propose_owner' : ActorMethod<[[] | [Principal]], undefined>,
  /**
   * / Configure the index canister for push notifications
   * / Set to null to disable notifications
   */
  'admin_set_index_canister' : ActorMethod<[[] | [Principal]], boolean>,
  'admin_update_icrc1' : ActorMethod<
    [Array<UpdateLedgerInfoRequest__2>],
    Array<boolean>
  >,
  'admin_update_icrc2' : ActorMethod<
    [Array<UpdateLedgerInfoRequest__1>],
    Array<boolean>
  >,
  'admin_update_icrc4' : ActorMethod<
    [Array<UpdateLedgerInfoRequest>],
    Array<boolean>
  >,
  'archives' : ActorMethod<[], Array<LegacyArchiveInfo>>,
  'burn' : ActorMethod<[BurnArgs], TransferResult>,
  'deposit_cycles' : ActorMethod<[], undefined>,
  'getUpgradeError' : ActorMethod<[], string>,
  'get_blocks' : ActorMethod<
    [{ 'start' : bigint, 'length' : bigint }],
    RosettaGetBlocksResponse
  >,
  /**
   * / Legacy Rosetta-compatible alias for icrc3_get_tip_certificate.
   * / Returns { certificate: opt blob; hash_tree: blob } to match SNS ledger interface.
   */
  'get_data_certificate' : ActorMethod<
    [],
    {
      'certificate' : [] | [Uint8Array | number[]],
      'hash_tree' : Uint8Array | number[],
    }
  >,
  'get_icrc85_stats' : ActorMethod<
    [],
    {
      'activeActions' : bigint,
      'nextCycleActionId' : [] | [bigint],
      'lastActionReported' : [] | [bigint],
    }
  >,
  /**
   * / Get the currently configured index canister
   */
  'get_index_canister' : ActorMethod<[], [] | [Principal]>,
  'get_owner' : ActorMethod<[], Principal>,
  'get_pending_owner' : ActorMethod<[], [] | [Principal]>,
  'get_tip' : ActorMethod<[], Tip>,
  'get_transactions' : ActorMethod<
    [{ 'start' : bigint, 'length' : bigint }],
    GetTransactionsResponse
  >,
  'icrc103_get_allowances' : ActorMethod<[GetAllowancesArgs], AllowanceResult>,
  'icrc106_get_index_principal' : ActorMethod<[], Icrc106GetResult>,
  'icrc107_get_fee_collector' : ActorMethod<[], GetFeeCollectorResult>,
  'icrc107_set_fee_collector' : ActorMethod<
    [SetFeeCollectorArgs],
    SetFeeCollectorResult
  >,
  'icrc10_supported_standards' : ActorMethod<[], Array<SupportedStandard>>,
  'icrc1_balance_of' : ActorMethod<[Account], Balance>,
  'icrc1_decimals' : ActorMethod<[], number>,
  'icrc1_fee' : ActorMethod<[], Balance>,
  'icrc1_metadata' : ActorMethod<[], Array<MetaDatum>>,
  'icrc1_minting_account' : ActorMethod<[], [] | [Account]>,
  /**
   * / Functions for the ICRC1 token standard
   */
  'icrc1_name' : ActorMethod<[], string>,
  'icrc1_supported_standards' : ActorMethod<[], Array<SupportedStandard>>,
  'icrc1_symbol' : ActorMethod<[], string>,
  'icrc1_total_supply' : ActorMethod<[], Balance>,
  'icrc1_transfer' : ActorMethod<[TransferArgs], TransferResult>,
  'icrc21_canister_call_consent_message' : ActorMethod<
    [ConsentMessageRequest],
    ConsentMessageResponse
  >,
  'icrc2_allowance' : ActorMethod<[AllowanceArgs], Allowance>,
  'icrc2_approve' : ActorMethod<[ApproveArgs], ApproveResponse>,
  'icrc2_transfer_from' : ActorMethod<[TransferFromArgs], TransferFromResponse>,
  'icrc3_get_archives' : ActorMethod<[GetArchivesArgs], GetArchivesResult>,
  'icrc3_get_blocks' : ActorMethod<[GetBlocksArgs], GetBlocksResult>,
  /**
   * / The ICRC-3 archiving state, open to anyone. Archiving needs a balance
   * / above 2 * archiveCycles; below it localLedgerSize stays over
   * / maxActiveRecords and no archive is created.
   */
  'icrc3_get_stats' : ActorMethod<[], Stats>,
  'icrc3_get_tip_certificate' : ActorMethod<[], [] | [DataCertificate]>,
  'icrc3_supported_block_types' : ActorMethod<[], Array<BlockType>>,
  'icrc4_balance_of_batch' : ActorMethod<
    [BalanceQueryArgs],
    BalanceQueryResult
  >,
  'icrc4_maximum_query_batch_size' : ActorMethod<[], [] | [bigint]>,
  'icrc4_maximum_update_batch_size' : ActorMethod<[], [] | [bigint]>,
  'icrc4_transfer_batch' : ActorMethod<
    [TransferBatchArgs],
    TransferBatchResults
  >,
  /**
   * / SNS parity: returns true once the ledger is initialized and ready.
   */
  'is_ledger_ready' : ActorMethod<[], boolean>,
  'is_supply_locked' : ActorMethod<[], boolean>,
  'mint' : ActorMethod<[Mint], TransferResult>,
  'set_icrc106_index_principal' : ActorMethod<[[] | [Principal]], undefined>,
  'update_archive_controllers' : ActorMethod<
    [],
    Array<ArchiveControllersResult>
  >,
  'upgradeArchive' : ActorMethod<[boolean], Array<ArchiveUpgradeResult>>,
}
export interface Transaction {
  'burn' : [] | [Burn],
  'kind' : string,
  'mint' : [] | [Mint],
  'timestamp' : Timestamp,
  'index' : TxIndex,
  'transfer' : [] | [Transfer],
}
export interface TransactionRange { 'start' : bigint, 'length' : bigint }
export interface Transaction__1 {
  'burn' : [] | [Burn__1],
  'kind' : string,
  'mint' : [] | [Mint__2],
  'approve' : [] | [Approve],
  'timestamp' : bigint,
  'transfer' : [] | [Transfer__1],
}
export interface Transfer {
  'to' : Account,
  'fee' : [] | [Balance],
  'from' : Account,
  'memo' : [] | [Memo],
  'created_at_time' : [] | [Timestamp],
  'amount' : Balance,
}
export interface TransferArgs {
  'to' : Account,
  'fee' : [] | [Balance],
  'memo' : [] | [Memo],
  'from_subaccount' : [] | [Subaccount],
  'created_at_time' : [] | [Timestamp],
  'amount' : Balance,
}
export type TransferBatchArgs = Array<TransferArgs>;
export type TransferBatchError = { 'TooManyRequests' : { 'limit' : bigint } } |
  { 'GenericError' : { 'message' : string, 'error_code' : bigint } } |
  { 'TemporarilyUnavailable' : null } |
  { 'BadBurn' : { 'min_burn_amount' : bigint } } |
  { 'Duplicate' : { 'duplicate_of' : bigint } } |
  { 'BadFee' : { 'expected_fee' : bigint } } |
  { 'CreatedInFuture' : { 'ledger_time' : bigint } } |
  { 'GenericBatchError' : { 'message' : string, 'error_code' : bigint } } |
  { 'TooOld' : null } |
  { 'InsufficientFunds' : { 'balance' : bigint } };
export type TransferBatchResult = { 'Ok' : bigint } |
  { 'Err' : TransferBatchError };
export type TransferBatchResults = Array<[] | [TransferBatchResult]>;
export type TransferError = {
    'GenericError' : { 'message' : string, 'error_code' : bigint }
  } |
  { 'TemporarilyUnavailable' : null } |
  { 'BadBurn' : { 'min_burn_amount' : Balance } } |
  { 'Duplicate' : { 'duplicate_of' : TxIndex } } |
  { 'BadFee' : { 'expected_fee' : Balance } } |
  { 'CreatedInFuture' : { 'ledger_time' : Timestamp } } |
  { 'TooOld' : null } |
  { 'InsufficientFunds' : { 'balance' : Balance } };
export interface TransferFromArgs {
  'to' : Account,
  'fee' : [] | [bigint],
  'spender_subaccount' : [] | [Uint8Array | number[]],
  'from' : Account,
  'memo' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
}
export type TransferFromError = {
    'GenericError' : { 'message' : string, 'error_code' : bigint }
  } |
  { 'TemporarilyUnavailable' : null } |
  { 'InsufficientAllowance' : { 'allowance' : bigint } } |
  { 'BadBurn' : { 'min_burn_amount' : bigint } } |
  { 'Duplicate' : { 'duplicate_of' : bigint } } |
  { 'BadFee' : { 'expected_fee' : bigint } } |
  { 'CreatedInFuture' : { 'ledger_time' : bigint } } |
  { 'TooOld' : null } |
  { 'InsufficientFunds' : { 'balance' : bigint } };
export type TransferFromResponse = { 'Ok' : bigint } |
  { 'Err' : TransferFromError };
export type TransferResult = { 'Ok' : TxIndex } |
  { 'Err' : TransferError };
export interface Transfer__1 {
  'to' : Account__5,
  'fee' : [] | [bigint],
  'from' : Account__5,
  'memo' : [] | [Uint8Array | number[]],
  'created_at_time' : [] | [bigint],
  'amount' : bigint,
  'spender' : [] | [Account__5],
}
export type TxIndex = bigint;
export type UpdateLedgerInfoRequest = { 'Fee' : Fee__1 } |
  { 'MaxBalances' : bigint } |
  { 'MaxTransfers' : bigint };
export type UpdateLedgerInfoRequest__1 = { 'Fee' : Fee__1 } |
  { 'MaxAllowance' : [] | [MaxAllowance] } |
  { 'MaxApprovalsPerAccount' : bigint } |
  { 'MaxApprovals' : bigint } |
  { 'SettleToApprovals' : bigint };
export type UpdateLedgerInfoRequest__2 = { 'Fee' : Fee } |
  { 'Metadata' : [string, [] | [Value]] } |
  { 'Symbol' : string } |
  { 'Logo' : string } |
  { 'Name' : string } |
  { 'MaxSupply' : [] | [bigint] } |
  { 'MaxMemo' : bigint } |
  { 'MinBurnAmount' : [] | [bigint] } |
  { 'TransactionWindow' : bigint } |
  { 'PermittedDrift' : bigint } |
  { 'SettleToAccounts' : bigint } |
  { 'MintingAccount' : Account } |
  { 'FeeCollector' : [] | [Account] } |
  { 'MaxAccounts' : bigint } |
  { 'Decimals' : number };
export type Value = { 'Int' : bigint } |
  { 'Map' : Array<[string, Value]> } |
  { 'Nat' : bigint } |
  { 'Blob' : Uint8Array | number[] } |
  { 'Text' : string } |
  { 'Array' : Array<Value> };
export type Value__1 = { 'Int' : bigint } |
  { 'Map' : Array<[string, Value__1]> } |
  { 'Nat' : bigint } |
  { 'Blob' : Uint8Array | number[] } |
  { 'Text' : string } |
  { 'Array' : Array<Value__1> };
export type Value__2 = { 'Int' : bigint } |
  { 'Map' : Map } |
  { 'Nat' : bigint } |
  { 'Nat64' : bigint } |
  { 'Blob' : Uint8Array | number[] } |
  { 'Text' : string } |
  { 'Array' : Array<Value__2> };
export interface _SERVICE extends Token {}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: (args: { IDL: typeof IDL }) => IDL.Type[];
