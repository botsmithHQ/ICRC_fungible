import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Cycles "mo:core/Cycles";
import D "mo:core/Debug";
import Error "mo:core/Error";
import Runtime "mo:core/Runtime";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";

import CertTree "mo:ic-certification/CertTree";

import ICRC1 "mo:icrc1-mo/ICRC1";
import ICRC1Inspect "mo:icrc1-mo/ICRC1/Inspect";
import ICRC2 "mo:icrc2-mo/ICRC2";
import ICRC2Inspect "mo:icrc2-mo/ICRC2/Inspect";
import ICRC2Service "mo:icrc2-mo/ICRC2/service";
import ICRC3Legacy "mo:icrc3-mo/legacy";
import ICRC3 "mo:icrc3-mo/";
import ICRC3Inspect "mo:icrc3-mo/Inspect";
import ICRC4 "mo:icrc4-mo/ICRC4";
import ICRC4Inspect "mo:icrc4-mo/ICRC4/Inspect";

import UpgradeArchive = "mo:icrc3-mo/upgradeArchive";

import ClassPlus "mo:class-plus";
import TT "mo:timer-tool";
import Star "mo:star/star";

shared ({ caller = _owner }) persistent actor class Token  (args: ?{
    icrc1 : ?ICRC1.InitArgs;
    icrc2 : ?ICRC2.InitArgs;
    icrc3 : ?ICRC3.InitArgs;
    icrc4 : ?ICRC4.InitArgs;
  }
) = this{


    transient let Map = ICRC2.CoreMap;
    transient let Set = ICRC2.CoreSet;

    transient let org_icdevs_class_plus_manager = ClassPlus.ClassPlusInitializationManager<system>(_owner, Principal.fromActor(this), true);

    transient let default_icrc1_args : ICRC1.InitArgs = {
      name = ?"Test Token";
      symbol = ?"TTT";
      logo = ?"data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMSIgaGVpZ2h0PSIxIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxyZWN0IHdpZHRoPSIxMDAlIiBoZWlnaHQ9IjEwMCUiIGZpbGw9InJlZCIvPjwvc3ZnPg==";
      decimals = 8;
      fee = ?#Fixed(10000);
      minting_account = ?{
        owner = _owner;
        subaccount = null;
      };
      max_supply = null;
      min_burn_amount = ?10000;
      max_memo = ?80;
      advanced_settings = null;
      metadata = null;
      fee_collector = null;
      transaction_window = null;
      permitted_drift = null;
      max_accounts = ?100000000;
      settle_to_accounts = ?99999000;
    };

    transient let default_icrc2_args : ICRC2.InitArgs = {
      max_approvals_per_account = ?10000;
      max_allowance = ?#TotalSupply;
      fee = ?#ICRC1;
      advanced_settings = null;
      max_approvals = ?10000000;
      settle_to_approvals = ?9990000;
      cleanup_interval = null; // No automatic cleanup by default
      cleanup_on_zero_balance = null; // Don't auto-cleanup on zero balance
      icrc103_max_take_value = ?1000; // Max 1000 allowances per query
      icrc103_public_allowances = ?true; // Allowances are publicly queryable
    };

    transient let default_icrc3_args : ICRC3.InitArgs = {
      maxActiveRecords = 10_000;
      settleToRecords = 6_000;
      maxRecordsInArchiveInstance = 100_000_000;
      maxArchivePages = 62500;
      archiveIndexType = #Stable;
      maxRecordsToArchive = 10_000;
      archiveCycles = 20_000_000_000_000;
      archiveControllers = null;
      supportedBlocks = [
        {
          block_type = "1xfer"; 
          url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
        },
        {
          block_type = "2xfer"; 
          url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
        },
        {
          block_type = "2approve"; 
          url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
        },
        {
          block_type = "1mint"; 
          url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
        },
        {
          block_type = "1burn"; 
          url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
        },
        {
          block_type = "107feecol"; 
          url="https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-107";
        }
      ];
    };

    transient let default_icrc4_args : ICRC4.InitArgs = {
      max_balances = ?200;
      max_transfers = ?200;
      fee = ?#ICRC1;
    };

    transient let icrc1_args : ICRC1.InitArgs = switch(args){
      case(null) default_icrc1_args;
      case(?args){
        switch(args.icrc1){
          case(null) default_icrc1_args;
          case(?val){
            {
              val with minting_account = switch(
                val.minting_account){
                  case(?val) ?val;
                  case(null) {?{
                    owner = _owner;
                    subaccount = null;
                  }};
                };
            };
          };
        };
      };
    };

    transient let icrc2_args : ICRC2.InitArgs = switch(args){
      case(null) default_icrc2_args;
      case(?args){
        switch(args.icrc2){
          case(null) default_icrc2_args;
          case(?val) val;
        };
      };
    };


    transient let icrc3_args : ICRC3.InitArgs = switch(args){
      case(null) default_icrc3_args;
      case(?args){
        switch(args.icrc3){
          case(null) default_icrc3_args;
          case(?val) val;
        };
      };
    };

    transient let icrc4_args : ICRC4.InitArgs = switch(args){
      case(null) default_icrc4_args;
      case(?args){
        switch(args.icrc4){
          case(null) default_icrc4_args;
          case(?val) val;
        };
      };
    };

    /// The IC refuses a canister with more controllers than this.
    transient let IC_MAX_CONTROLLERS : Nat = 10;

    /// Traps when `archiveControllers` leaves no room, within
    /// `IC_MAX_CONTROLLERS`, for the two principals the ledger adds to every
    /// archive: itself and the owner. The owner counts even when it is in the
    /// list, because it can change and the list cannot.
    func checkArchiveControllers(configured : ??[Principal]) {
      let ?(?list) = configured else return;
      let self = Principal.fromActor(this);
      let distinct = Set.fromIter<Principal>(list.vals(), Principal.compare);
      Set.remove(distinct, Principal.compare, self);
      let n = Set.size(distinct);
      if (n + 2 > IC_MAX_CONTROLLERS) {
        Runtime.trap("archiveControllers has " # Nat.toText(n) # " principals besides the ledger; at most " # Nat.toText(IC_MAX_CONTROLLERS - 2) # " fit the IC limit of " # Nat.toText(IC_MAX_CONTROLLERS) # " controllers with the ledger and the owner");
      };
    };

    /// Whether the anonymous principal signs for `account`. It signs for every
    /// subaccount of its own, so the subaccount is not read. A transfer from
    /// the minting account is a mint: with such an account anyone mints.
    func isAnonymousAccount(account : ICRC1.Account) : Bool {
      Principal.isAnonymous(account.owner)
    };

    /// Traps when the ledger would start with the anonymous principal as its
    /// installer, which makes it the owner and proves it is a controller, or
    /// as the owner of its minting account.
    func refuseAnonymousInstall(installer : Principal, minting : ?ICRC1.Account) {
      if (Principal.isAnonymous(installer)) {
        Runtime.trap("The anonymous principal cannot install the ledger: it would be its owner, and it is a controller");
      };
      let ?account = minting else return;
      if (isAnonymousAccount(account)) {
        Runtime.trap("The anonymous principal cannot be the owner of the minting account: anyone could mint");
      };
    };

    // The initializer of a persisted variable runs at install only. `_owner`
    // is whoever sends the install OR the upgrade, and an upgrade does not
    // apply its init args, so an upgrade must never run this check.
    var icrc1_migration_state = do {
      refuseAnonymousInstall(_owner, icrc1_args.minting_account);
      ICRC1.init(ICRC1.initialState(), #v0_1_0(#id),?icrc1_args, _owner);
    };
    var icrc2_migration_state = ICRC2.init(ICRC2.initialState(), #v0_1_0(#id),?icrc2_args, _owner);
    var icrc4_migration_state = ICRC4.init(ICRC4.initialState(), #v0_1_0(#id),?icrc4_args, _owner);
    // The initializer of a persisted variable runs at install only, so the
    // configured archive controllers are checked when they are applied and an
    // upgrade, which does not apply its init args, is never refused for them.
    var icrc3_migration_state = do {
      checkArchiveControllers(icrc3_args.archiveControllers);
      ICRC3.initialState();
    };
    let cert_store : CertTree.Store = CertTree.newStore();
    transient let _ct = CertTree.Ops(cert_store);


    var owner = _owner;

    /// The one owner predicate, for every body guard, every owner arm of
    /// `inspect` and `argCap`. `owner` starts as whoever installed the ledger.
    /// An install by the anonymous principal is refused, but a ledger installed
    /// by it before that refusal keeps its anonymous `owner` through every
    /// upgrade; the anonymous caller is refused whatever `owner` holds. That
    /// closes the owner methods only: such a ledger still has the anonymous
    /// principal as a controller and, by default, as its minting account.
    func isOwner(caller : Principal) : Bool {
      not Principal.isAnonymous(caller) and caller == owner
    };

    /// Set for good by `admin_lock_supply`. Once `true`, `mint` is refused and
    /// `admin_update_icrc1` refuses any batch that touches the minting account
    /// or the maximum supply. No method sets it back to `false`.
    ///
    /// What it does NOT do:
    ///  - It is irreversible in this code only. A controller can upgrade the
    ///    canister to a wasm that keeps this field and ignores it, or reinstall
    ///    it, and the lock is gone. (A wasm that drops the field is refused by
    ///    the runtime: a stable field cannot disappear in an upgrade.)
    ///  - It does not close the ICRC paths. When the minting account is an
    ///    account somebody can sign for, an `icrc1_transfer`, an
    ///    `icrc2_transfer_from` (after an approval by that account) or an
    ///    `icrc4_transfer_batch` from it is still recorded as a mint. All three
    ///    are capped by `max_supply`, which the lock freezes, and none of them by
    ///    the lock itself. With the minting account set to this canister's own
    ///    principal nobody can sign for it; this library does not check that,
    ///    the deployer must.
    var supplyLocked : Bool = false;

    /// Whether a ledger-info batch changes what can be minted. Pure: `inspect`
    /// and the body of `admin_update_icrc1` share it, so they cannot drift.
    func touchesSupply(requests : [ICRC1.UpdateLedgerInfoRequest]) : Bool {
      for (request in requests.vals()) {
        switch (request) {
          case (#MintingAccount _ or #MaxSupply _) return true;
          case (_) {};
        };
      };
      false
    };

    /// Whether a ledger-info batch changes the decimals. The init args set them
    /// at install and nothing changes them after: every balance, fee and amount
    /// already recorded, and every wallet and index that cached them, is read
    /// with them. Pure: `inspect` and the body of `admin_update_icrc1` share it,
    /// so they cannot drift.
    func touchesDecimals(requests : [ICRC1.UpdateLedgerInfoRequest]) : Bool {
      for (request in requests.vals()) {
        switch (request) {
          case (#Decimals _) return true;
          case (_) {};
        };
      };
      false
    };

    /// Whether a ledger-info batch sets a minting account that the anonymous
    /// principal signs for. Pure: `inspect` and the body of
    /// `admin_update_icrc1` share it, so they cannot drift.
    func setsAnonymousMinter(requests : [ICRC1.UpdateLedgerInfoRequest]) : Bool {
      for (request in requests.vals()) {
        switch (request) {
          case (#MintingAccount account) if (isAnonymousAccount(account)) return true;
          case (_) {};
        };
      };
      false
    };

    // The principal the owner proposed as its successor. It holds no power:
    // `owner` changes only when this principal calls `accept_ownership`.
    var pending_owner : ?Principal = null;

    var icrc3_migration_state_new = icrc3_migration_state;

    // TimerTool state - stored in stable memory to survive upgrades
    var tt_state : ?TT.State = null;

    // ONE TimerTool instance shared across all components
    // This is created lazily and passed to ICRC-1, ICRC-3, etc.
    transient var _timerTool : ?TT.TimerTool = null;

    //============================================================================
    // Index Push Notification State
    //============================================================================

    // Index canister principal for push notifications (null = disabled)
    var index_canister : ?Principal = null;
    
    // Pending notify action ID (prevents duplicate scheduling)
    var pending_notify_action_id : ?Nat = null;
    
    // Configuration: delay before sending notify (allows batching multiple blocks)
    let INDEX_NOTIFY_DELAY_NS : Nat = 2_000_000_000; // 2 seconds

    //============================================================================
    
    func getTimerTool() : TT.TimerTool {
      switch(_timerTool) {
        case(?tt) tt;
        case(null) {
          // ICRC-1 and ICRC-3 use this tool for their own purposes too.
          // ICRC-85 is OFF: this token shares no cycles, through any stream.
          // TimerTool schedules its own share unless this switch is `?true`,
          // and a share queued by an earlier build returns before sending.
          // `pic/TokenWithICRC85.mo` shows how to turn sharing on.
          let ttEnv : TT.Environment = {
            advanced = ?{ icrc85 = ?{
              kill_switch = ?true;
              handler = null;
              period = null;
              initialWait = null;
              asset = null;
              platform = null;
              tree = null;
              collector = null;
            } };
            syncUnsafe = null;
            reportExecution = null;
            reportError = null;
            reportBatch = null;
          };
          
          let newTT = TT.TimerTool(
            tt_state,                       // stored state
            Principal.fromActor(this),      // caller
            Principal.fromActor(this),      // canister
            null,                           // args
            ?ttEnv,                         // environment
            func(newState: TT.State) {
              tt_state := ?newState;
            }
          );
          _timerTool := ?newTT;
          newTT;
        };
      };
    };

    // ======== ICRC-3 Definition (must come before ICRC-1 since ICRC-1 depends on icrc3().add_record) ========

  private func updated_certification(_cert: Blob, _lastIndex: Nat) : Bool{
    // Note: setCertifiedData is already called by icrc3.add_record
    // We only need this callback if we want to add additional data to the cert tree
    // before the final setCertifiedData call in icrc3
    return true;
  };

  private func get_certificate_store() : CertTree.Store {
    return cert_store;
  };

  private func get_icrc3_environment() : ICRC3.Environment{
      {
        advanced = ?{
          // Each new archive gets the current owner as a controller (when
          // `archiveControllers` is managed). The library reads it in a
          // self-message sent after the archive exists, so an `accept_ownership`
          // landing in between gives the archive the new owner. While a hand-off is
          // pending that is still the owner that proposed it: the proposed
          // principal has proven nothing yet. Once it accepts, it runs
          // `update_archive_controllers` to take the archives that exist.
          // An anonymous owner is never added: anyone could then administer
          // the archive through the management canister.
          get_archive_controllers = ?(func () : [Principal] {
            if (Principal.isAnonymous(owner)) [] else [owner]
          });
          updated_certification = ?updated_certification;
          // ICRC-85 OFF for the icrc3 stream, and for every archive, which
          // takes this switch at creation. A `null` environment here does NOT
          // switch it off: it means "default collector, no kill switch".
          icrc85 = ?{
            var org_icdevs_timer_tool = ?getTimerTool();
            var collector = null;
            advanced = ?{ kill_switch = ?true; handler = null; tree = null };
          };
        };
        get_certificate_store = ?get_certificate_store;
        var org_icdevs_timer_tool = ?getTimerTool();
      };
  };

  func ensure_block_types(icrc3Class: ICRC3.ICRC3) : () {
    let supportedBlocks = List.fromIter<ICRC3.BlockType>(icrc3Class.supported_block_types().vals());

    let has = func(blockType: Text) : Bool {
      List.any(supportedBlocks, func(bt: ICRC3.BlockType) : Bool { bt.block_type == blockType });
    };

    if(not has("1xfer")){
      List.add(supportedBlocks, {
            block_type = "1xfer"; 
            url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
          });
    };

    if(not has("2xfer")){
      List.add(supportedBlocks, {
            block_type = "2xfer"; 
            url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
          });
    };

    if(not has("2approve")){
      List.add(supportedBlocks, {
            block_type = "2approve"; 
            url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
          });
    };

    if(not has("1mint")){
      List.add(supportedBlocks, {
            block_type = "1mint"; 
            url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
          });
    };

    if(not has("1burn")){
      List.add(supportedBlocks, {
            block_type = "1burn"; 
            url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3";
          });
    };

    if(not has("107feecol")){
      List.add(supportedBlocks, {
            block_type = "107feecol"; 
            url="https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-107";
          });
    };

    icrc3Class.update_supported_blocks(List.toArray(supportedBlocks));
  };

  transient let icrc3 = ICRC3.Init({
    org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
    initialState = icrc3_migration_state_new;
    args = ?icrc3_args;
    pullEnvironment = ?get_icrc3_environment;
    onInitialize = ?(func(newClass: ICRC3.ICRC3) : async*(){
       ensure_block_types(newClass);
    });
    onStorageChange = func(state: ICRC3.State){
      icrc3_migration_state_new := state;
    };
  });

    // ======== ICRC-1 Definition ========

    private func get_icrc1_environment() : ICRC1.Environment {
    {
      advanced = ?{
        icrc85 = {
          // No library reads this top-level field: set alone, the icrc1 stream
          // keeps sharing. Set for readers; the switch is `advanced` below.
          kill_switch = ?true;
          handler = null;
          tree = null;
          collector = null;
          // ICRC-85 OFF for the icrc1 stream.
          advanced = ?{ kill_switch = ?true; handler = null; tree = null };
        };
        get_fee = null;
        fee_validation_mode = ?#Strict;
      };
      add_ledger_transaction = ?icrc3().add_record;
      var org_icdevs_timer_tool = ?getTimerTool();
      var org_icdevs_class_plus_manager = ?org_icdevs_class_plus_manager;
    };
  };

    private func icrc1_onInitialize(instance: ICRC1.ICRC1) : async* () {
      ignore instance.register_supported_standards({
        name = "ICRC-3";
        url = "https://github.com/dfinity/ICRC/ICRCs/icrc-3/"
      });
      ignore instance.register_supported_standards({
        name = "ICRC-10";
        url = "https://github.com/dfinity/ICRC/ICRCs/icrc-10/"
      });
      ignore instance.register_supported_standards({
        name = "ICRC-106";
        url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-106"
      });
      ignore instance.register_supported_standards({
        name = "ICRC-107";
        url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-107"
      });
      ignore instance.register_supported_standards({
        name = "ICRC-21";
        url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-21"
      });
      // Register ICRC-21 consent handlers for ICRC-1 methods
      instance.register_consent_handler("icrc1_transfer", ICRC1.buildTransferConsent);
      instance.register_consent_handler("icrc107_set_fee_collector", ICRC1.buildSetFeeCollectorConsent);
    };

    transient let getIcrc1 = ICRC1.Init({
      org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
      initialState = icrc1_migration_state;
      args = ?icrc1_args;
      pullEnvironment = ?get_icrc1_environment;
      onInitialize = ?icrc1_onInitialize;
      onStorageChange = func(state: ICRC1.State) {
        icrc1_migration_state := state;
      };
    });

    func icrc1() : ICRC1.ICRC1 {
      getIcrc1();
    };

  private func get_icrc2_environment() : ICRC2.Environment {
    {
      icrc1 = icrc1();
      get_fee = null;
    };
  };

  private func icrc2_onInitialize(_instance: ICRC2.ICRC2) : async* () {
    ignore icrc1().register_supported_standards({
      name = "ICRC-103";
      url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-103"
    });
    // Register ICRC-21 consent handlers for ICRC-2 methods
    icrc1().register_consent_handler("icrc2_approve", ICRC2.buildApproveConsent);
    icrc1().register_consent_handler("icrc2_transfer_from", ICRC2.buildTransferFromConsent);
  };

  transient let getIcrc2 = ICRC2.Init({
    org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
    initialState = icrc2_migration_state;
    args = ?icrc2_args;
    pullEnvironment = ?get_icrc2_environment;
    onInitialize = ?icrc2_onInitialize;
    onStorageChange = func(state: ICRC2.State) {
      icrc2_migration_state := state;
    };
  });

  func icrc2() : ICRC2.ICRC2 {
    getIcrc2();
  };

  private func get_icrc4_environment() : ICRC4.Environment {
    {
      icrc1 = icrc1();
      get_fee = null;
    };
  };

  private func icrc4_onInitialize(_instance: ICRC4.ICRC4) : async* () {
    ignore icrc1().register_supported_standards({
      name = "ICRC-4";
      url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-4"
    });
    // Register ICRC-21 consent handler for ICRC-4 methods
    icrc1().register_consent_handler("icrc4_transfer_batch", ICRC4.buildBatchTransferConsent);
  };

  transient let getIcrc4 = ICRC4.Init({
    org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
    initialState = icrc4_migration_state;
    args = ?icrc4_args;
    pullEnvironment = ?get_icrc4_environment;
    onInitialize = ?icrc4_onInitialize;
    onStorageChange = func(state: ICRC4.State) {
      icrc4_migration_state := state;
    };
  });

  func icrc4() : ICRC4.ICRC4 {
    getIcrc4();
  };

  //============================================================================
  // Message Inspection - Cycle Drain Protection
  //============================================================================

  type InspectMsg = {
    // ICRC-1 endpoints
    #icrc1_name : () -> ();
    #icrc1_symbol : () -> ();
    #icrc1_decimals : () -> ();
    #icrc1_fee : () -> ();
    #icrc1_metadata : () -> ();
    #icrc1_total_supply : () -> ();
    #icrc1_minting_account : () -> ();
    #icrc1_balance_of : () -> ICRC1.Account;
    #icrc1_supported_standards : () -> ();
    #icrc1_transfer : () -> ICRC1.TransferArgs;
    #icrc10_supported_standards : () -> ();

    // ICRC-2 endpoints
    #icrc2_allowance : () -> ICRC2.AllowanceArgs;
    #icrc2_approve : () -> ICRC2.ApproveArgs;
    #icrc2_transfer_from : () -> ICRC2.TransferFromArgs;
    #icrc103_get_allowances : () -> ICRC2.GetAllowancesArgs;

    // ICRC-3 endpoints
    #icrc3_get_blocks : () -> ICRC3.GetBlocksArgs;
    #icrc3_get_archives : () -> ICRC3.GetArchivesArgs;
    #icrc3_get_tip_certificate : () -> ();
    #icrc3_supported_block_types : () -> ();
    #get_blocks : () -> { start : Nat; length : Nat };
    #get_transactions : () -> { start : Nat; length : Nat };
    #get_tip : () -> ();
    #archives : () -> ();

    // ICRC-4 endpoints
    #icrc4_transfer_batch : () -> ICRC4.TransferBatchArgs;
    #icrc4_balance_of_batch : () -> ICRC4.BalanceQueryArgs;
    #icrc4_maximum_update_batch_size : () -> ();
    #icrc4_maximum_query_batch_size : () -> ();

    // ICRC-106 endpoints
    #icrc106_get_index_principal : () -> ();
    #set_icrc106_index_principal : () -> ?Principal;

    // ICRC-107 endpoints
    #icrc107_set_fee_collector : () -> ICRC1.SetFeeCollectorArgs;
    #icrc107_get_fee_collector : () -> ();

    // ICRC-21 endpoints
    #icrc21_canister_call_consent_message : () -> ICRC1.ConsentMessageRequest;

    // Legacy / Candid parity endpoints
    #get_data_certificate : () -> ();
    #is_ledger_ready : () -> ();

    // Admin endpoints
    #admin_propose_owner : () -> ?Principal;
    #accept_ownership : () -> ();
    #get_owner : () -> ();
    #get_pending_owner : () -> ();
    #admin_update_icrc1 : () -> [ICRC1.UpdateLedgerInfoRequest];
    #admin_update_icrc2 : () -> [ICRC2.UpdateLedgerInfoRequest];
    #admin_update_icrc4 : () -> [ICRC4.UpdateLedgerInfoRequest];
    #admin_set_index_canister : () -> ?Principal;
    #admin_init : () -> ();
    #admin_lock_supply : () -> ();
    #is_supply_locked : () -> ();

    // Other endpoints
    #mint : () -> ICRC1.Mint;
    #burn : () -> ICRC1.BurnArgs;
    #get_icrc85_stats : () -> ();
    #getUpgradeError : () -> ();
    #upgradeArchive : () -> Bool;
    #update_archive_controllers : () -> ();
    #get_index_canister : () -> ();
    #deposit_cycles : () -> ();
    #get_health : () -> ();
  };

  /// Ingress size limit of every method that is not named in `argCap`.
  /// Measured with Candid encoding of maximal arguments (29-byte principals,
  /// 32-byte subaccounts, 40-digit Nats, every optional field set, 80-byte
  /// memo): icrc1_transfer 293 B, icrc2_approve 336 B, icrc2_transfer_from
  /// 364 B, icrc3_get_blocks with 100 ranges 3 824 B. Everything else is smaller.
  transient let DEFAULT_ARG_CAP : Nat = 5_120;

  /// One maximal batch entry measures 149 B plus its memo (229 B with an
  /// 80-byte memo): a 29-byte principal, both subaccounts of 32 bytes, amount
  /// and fee of 40 digits, `created_at_time` set. A 200-entry batch is
  /// 45 868 B, of which 68 B are the type table and the vector.
  transient let TRANSFER_ENTRY_BYTES : Nat = 149;
  /// One maximal account measures 65 B: a 29-byte principal and a 32-byte
  /// subaccount. A 200-account query is 13 037 B, of which 37 B are framing.
  transient let BALANCE_ENTRY_BYTES : Nat = 65;
  /// Margin over the measured framing of a batch (68 B and 37 B).
  transient let BATCH_FRAMING_BYTES : Nat = 256;
  /// What a consent request adds around the call it wraps: the method name
  /// (the library refuses more than 256 B), the language tag and the device
  /// spec. Measured around a full batch: 103 B with a 20-byte method name,
  /// 375 B with a 256-byte one and a 35-byte language tag.
  transient let CONSENT_FRAMING_BYTES : Nat = 512;
  /// A ledger-info update that carries a logo. Measured by Candid-encoding a
  /// 110 214-byte data URI plus a rename in the same call: about 110.3 KB (the
  /// exact figure moves with the type table the client sends).
  /// Only the owner gets it.
  transient let OWNER_INFO_ARG_CAP : Nat = 160_000;
  /// No batch limit, however configured, opens more than this. Without it
  /// `max_transfers = 10 000` would admit 2.29 MB from any caller.
  transient let BATCH_ARG_CEILING : Nat = 1_048_576;

  // The three readers below look at the persisted state directly. They must
  // stay pure: `inspect` runs on one replica, outside consensus, and whatever
  // it writes is discarded — so they never go through the lazily initialised
  // classes (`icrc1()`, `icrc4()`).
  func configuredMaxMemo() : Nat {
    switch (icrc1_migration_state) {
      case (#v0_2_0(#data(state))) state.max_memo;
      case (#v0_1_0(#data(state))) state.max_memo;
      // Not initialised yet. Every version is listed: a new one must not
      // compile until somebody says where its limit lives.
      case (#v0_0_0 _ or #v0_1_0(#id) or #v0_2_0(#id)) ICRC1Inspect.defaultConfig.maxMemoSize;
    };
  };

  func configuredMaxTransfers() : Nat {
    switch (icrc4_migration_state) {
      case (#v0_2_0(#data(state))) state.ledger_info.max_transfers;
      case (#v0_1_0(#data(state))) state.ledger_info.max_transfers;
      case (#v0_0_0 _ or #v0_1_0(#id) or #v0_2_0(#id)) 0;
    };
  };

  func configuredMaxBalances() : Nat {
    switch (icrc4_migration_state) {
      case (#v0_2_0(#data(state))) state.ledger_info.max_balances;
      case (#v0_1_0(#data(state))) state.ledger_info.max_balances;
      case (#v0_0_0 _ or #v0_1_0(#id) or #v0_2_0(#id)) 0;
    };
  };

  /// The largest amount or fee a call may carry: the 40 digits the library's
  /// validators allow, as a comparison. The validators count digits, which
  /// formats the number: on a number of a few kilobytes that alone exceeds
  /// what `inspect` may execute, and the message is then refused by the
  /// instruction limit instead of by this filter. So every amount is compared
  /// here before a validator sees it.
  transient let NAT_BOUND : Nat = 10 ** 40;

  func bounded(n : Nat) : Bool { n < NAT_BOUND };

  func boundedOpt(n : ?Nat) : Bool {
    switch (n) { case (?value) value < NAT_BOUND; case (null) true };
  };

  func validTransfer(args : ICRC1.TransferArgs, config : ICRC1Inspect.Config) : Bool {
    bounded(args.amount) and boundedOpt(args.fee) and ICRC1Inspect.inspectTransfer(args, ?config);
  };

  func validApprove(args : ICRC2.ApproveArgs, config : ICRC2Inspect.Config) : Bool {
    bounded(args.amount) and boundedOpt(args.expected_allowance) and boundedOpt(args.fee)
    and ICRC2Inspect.inspectApprove(args, ?config);
  };

  func validTransferFrom(args : ICRC2.TransferFromArgs, config : ICRC2Inspect.Config) : Bool {
    bounded(args.amount) and boundedOpt(args.fee) and ICRC2Inspect.inspectTransferFrom(args, ?config);
  };

  /// The checks of the library's `inspectTransferBatch`, with the Nat bound as
  /// a comparison instead of a digit count. Counting digits formats the number,
  /// and on a full batch of large amounts that alone exceeds what `inspect` may
  /// execute: measured, 150 entries with 40-digit amount and fee hit the
  /// 200 M instruction limit, so the largest legitimate batch was refused.
  func validTransferBatch(batch : ICRC4.TransferBatchArgs, maxMemo : Nat) : Bool {
    if (batch.size() == 0 or batch.size() > configuredMaxTransfers()) return false;
    let validBlob = func(blob : ?Blob, limit : Nat) : Bool {
      switch (blob) { case (null) true; case (?b) b.size() <= limit };
    };
    for (transfer in batch.vals()) {
      if (not validBlob(transfer.from_subaccount, 32)) return false;
      if (not validBlob(transfer.to.subaccount, 32)) return false;
      if (not validBlob(transfer.memo, maxMemo)) return false;
      if (not bounded(transfer.amount)) return false;
      if (not boundedOpt(transfer.fee)) return false;
    };
    true;
  };

  /// What `entries` maximal transfers measure, with the margin.
  func transferBatchBytes(entries : Nat) : Nat {
    entries * (TRANSFER_ENTRY_BYTES + configuredMaxMemo()) + BATCH_FRAMING_BYTES;
  };

  /// What `entries` maximal accounts measure, with the margin.
  func balanceBatchBytes(entries : Nat) : Nat {
    entries * BALANCE_ENTRY_BYTES + BATCH_FRAMING_BYTES;
  };

  func transferBatchCap() : Nat {
    Nat.min(BATCH_ARG_CEILING, Nat.max(DEFAULT_ARG_CAP, transferBatchBytes(configuredMaxTransfers())));
  };

  func balanceBatchCap() : Nat {
    Nat.min(BATCH_ARG_CEILING, Nat.max(DEFAULT_ARG_CAP, balanceBatchBytes(configuredMaxBalances())));
  };

  /// Whether a blob starts with the Candid magic bytes, "DIDL". Decoding one
  /// that does not traps, and a trap in `inspect` refuses the message.
  func isCandid(blob : Blob) : Bool {
    if (blob.size() < 4) return false;
    blob[0] == 0x44 and blob[1] == 0x49 and blob[2] == 0x44 and blob[3] == 0x4C;
  };

  /// A consent request is a read, open to every caller, and its body FORMATS
  /// the amounts of the call it wraps. So the wrapped call is held here to
  /// the rules of the method it names — measured without them: a request
  /// wrapping one transfer whose amount is a 1 KB number cost the canister
  /// 6.0 B cycles, and from 10 KB on it ran into the instruction limit of the
  /// message at 10.0 B cycles, from the anonymous principal.
  ///
  /// Only a request that wraps a batch may be larger than the default, and
  /// only by what its entries account for. A method this ledger has no rule
  /// for passes when it is small: its body answers without decoding anything.
  func validConsentRequest(
    request : ICRC1.ConsentMessageRequest,
    requestBytes : Nat,
    maxMemo : Nat,
    icrc1Config : ICRC1Inspect.Config,
    icrc2Config : ICRC2Inspect.Config,
  ) : Bool {
    if (requestBytes > request.arg.size() + CONSENT_FRAMING_BYTES) return false;
    // Not Candid at all: nothing to validate and nothing the body can format.
    // It answers with its typed error, which a small request may have.
    if (not isCandid(request.arg)) return request.arg.size() <= DEFAULT_ARG_CAP;
    if (request.method == "icrc4_transfer_batch") {
      let ?batch : ?ICRC4.TransferBatchArgs = from_candid (request.arg) else return false;
      return request.arg.size() <= transferBatchBytes(batch.size()) and validTransferBatch(batch, maxMemo);
    };
    if (request.arg.size() > DEFAULT_ARG_CAP) return false;
    if (request.method == "icrc1_transfer") {
      let ?args : ?ICRC1.TransferArgs = from_candid (request.arg) else return false;
      return validTransfer(args, icrc1Config);
    };
    if (request.method == "icrc2_approve") {
      let ?args : ?ICRC2.ApproveArgs = from_candid (request.arg) else return false;
      return validApprove(args, icrc2Config);
    };
    if (request.method == "icrc2_transfer_from") {
      let ?args : ?ICRC2.TransferFromArgs = from_candid (request.arg) else return false;
      return validTransferFrom(args, icrc2Config);
    };
    true;
  };

  /// The ingress size limit of each method. Every method is listed, so a new
  /// one does not compile until it is classified here, and it gets more than
  /// the default only on purpose. The batch limits follow the ledger's own
  /// configuration, so raising `max_transfers` raises the cap with it, up to
  /// `BATCH_ARG_CEILING`.
  ///
  /// Every other method stays at the default whatever `max_memo` is: a ledger
  /// configured with a memo bound above ~4 800 bytes would have its larger
  /// memos refused here although the body accepts them.
  func argCap(msg : InspectMsg, caller : Principal) : Nat {
    switch (msg) {
      case (#icrc4_transfer_batch _) transferBatchCap();
      case (#icrc4_balance_of_batch _) balanceBatchCap();
      // A wallet asks for the consent text of the call it is about to sign,
      // and the largest such call is a full batch.
      case (#icrc21_canister_call_consent_message _) transferBatchCap() + CONSENT_FRAMING_BYTES;
      case (#admin_update_icrc1 _) {
        if (isOwner(caller)) OWNER_INFO_ARG_CAP else DEFAULT_ARG_CAP;
      };
      case (
        #icrc1_name _ or #icrc1_symbol _ or #icrc1_decimals _ or #icrc1_fee _
        or #icrc1_metadata _ or #icrc1_total_supply _ or #icrc1_minting_account _
        or #icrc1_balance_of _ or #icrc1_supported_standards _ or #icrc1_transfer _
        or #icrc10_supported_standards _ or #icrc2_allowance _ or #icrc2_approve _
        or #icrc2_transfer_from _ or #icrc103_get_allowances _ or #icrc3_get_blocks _
        or #icrc3_get_archives _ or #icrc3_get_tip_certificate _
        or #icrc3_supported_block_types _ or #get_blocks _ or #get_transactions _
        or #get_tip _ or #archives _ or #icrc4_maximum_update_batch_size _
        or #icrc4_maximum_query_batch_size _ or #icrc106_get_index_principal _
        or #set_icrc106_index_principal _ or #icrc107_set_fee_collector _
        or #icrc107_get_fee_collector _ or #get_data_certificate _ or #is_ledger_ready _
        or #admin_propose_owner _ or #accept_ownership _ or #get_owner _
        or #get_pending_owner _ or #admin_update_icrc2 _ or #admin_update_icrc4 _
        or #admin_set_index_canister _ or #admin_init _ or #mint _ or #burn _
        or #get_icrc85_stats _ or #getUpgradeError _ or #upgradeArchive _
        or #update_archive_controllers _ or #get_index_canister _ or #deposit_cycles _
        or #get_health _ or #admin_lock_supply _ or #is_supply_locked _
      ) DEFAULT_ARG_CAP;
    };
  };

  /// Filters ingress messages before the canister pays for them.
  ///
  /// This is a cycles optimisation ONLY, never the access control: it runs on
  /// a single replica, outside consensus, and never for inter-canister calls.
  /// Every guard in the method bodies stays and is what actually decides.
  ///
  /// Three rules:
  ///  1. Size first, per method (`argCap`). Nobody gets a larger limit for
  ///     having installed or for controlling the canister.
  ///  2. A method whose body admits one principal is refused here for anyone
  ///     else, with the same predicate the body applies. For the owner that is
  ///     the CURRENT `owner`, which `accept_ownership` changes. It is not
  ///     `_owner`, the class parameter, which is whoever performed the last
  ///     install or upgrade of the canister. The owner predicate is `isOwner`,
  ///     which refuses the anonymous principal even when it is the owner.
  ///  3. Reads stay open to every caller, the anonymous principal included,
  ///     when they arrive as update calls. Wallets and indexers read balances,
  ///     allowances and blocks through certified update calls; refusing them
  ///     would break those clients. They are held to the default size limit.
  system func inspect(
    {
      caller : Principal;
      arg : Blob;
      msg : InspectMsg;
    }
  ) : Bool {
    // FIRST, outside any arm: the cheapest check, before anything is decoded.
    if (arg.size() > argCap(msg, caller)) return false;

    // The memo bound is the ledger's configured one, not the library default.
    let maxMemo = configuredMaxMemo();
    let icrc1Config = { ICRC1Inspect.defaultConfig with maxMemoSize = maxMemo };
    let icrc2Config = { ICRC2Inspect.defaultConfig with maxMemoSize = maxMemo };

    switch (msg) {
      // ---- Open to every caller: field validation only ----
      case (#icrc1_balance_of(getArgs)) {
        ICRC1Inspect.inspectBalanceOf(getArgs(), ?icrc1Config);
      };
      case (#icrc1_transfer(getArgs)) {
        validTransfer(getArgs(), icrc1Config);
      };
      case (#icrc2_allowance(getArgs)) {
        ICRC2Inspect.inspectAllowance(getArgs(), ?icrc2Config);
      };
      case (#icrc2_approve(getArgs)) {
        validApprove(getArgs(), icrc2Config);
      };
      case (#icrc2_transfer_from(getArgs)) {
        validTransferFrom(getArgs(), icrc2Config);
      };
      case (#icrc103_get_allowances(getArgs)) {
        ICRC2Inspect.inspectGetAllowances(getArgs(), ?icrc2Config);
      };
      case (#icrc3_get_blocks(getArgs)) {
        ICRC3Inspect.inspectGetBlocks(getArgs(), null);
      };
      case (#icrc3_get_archives(getArgs)) {
        ICRC3Inspect.inspectGetArchives(getArgs(), null);
      };
      case (#get_blocks(getArgs)) {
        ICRC3Inspect.inspectLegacyBlocks(getArgs(), null);
      };
      case (#get_transactions(getArgs)) {
        ICRC3Inspect.inspectLegacyBlocks(getArgs(), null);
      };
      // A batch may weigh what its entries account for, not what the largest
      // batch would: one entry padded to the cap is refused.
      case (#icrc4_transfer_batch(getArgs)) {
        let batch = getArgs();
        arg.size() <= transferBatchBytes(batch.size()) and validTransferBatch(batch, maxMemo);
      };
      case (#icrc4_balance_of_batch(getArgs)) {
        let query_ = getArgs();
        arg.size() <= balanceBatchBytes(query_.accounts.size()) and
        ICRC4Inspect.inspectBalanceOfBatch(query_, ?{
          ICRC4Inspect.configWithLedgerLimits(configuredMaxTransfers(), configuredMaxBalances())
          with maxMemoSize = maxMemo
        });
      };
      case (#icrc21_canister_call_consent_message(getArgs)) {
        let request = getArgs();
        ICRC1Inspect.inspectConsentMessage(request, ?icrc1Config) and
        validConsentRequest(request, arg.size(), maxMemo, icrc1Config, icrc2Config);
      };
      case (#burn(getArgs)) {
        let args = getArgs();
        bounded(args.amount) and ICRC1Inspect.inspectBurn(args, ?icrc1Config);
      };

      // ---- The current owner only, never anonymous, as the bodies have it ----
      case (#mint(getArgs)) {
        // Once the supply is locked nobody mints; the argument is not decoded.
        if (supplyLocked) return false;
        if (not isOwner(caller)) return false;
        let args = getArgs();
        ICRC1Inspect.isValidAccount(args.to, icrc1Config) and
        bounded(args.amount) and
        ICRC1Inspect.isValidMemo(args.memo, icrc1Config);
      };
      // A batch that would give the minting account to the anonymous principal,
      // or that changes the decimals, is refused whole, as the body refuses it.
      // So is, once the supply is locked, a batch that touches the minting
      // account or the maximum supply.
      // The batch is decoded only for the owner, and `argCap` has already
      // bounded it.
      case (#admin_update_icrc1(getArgs)) {
        if (not isOwner(caller)) return false;
        let requests = getArgs();
        not setsAnonymousMinter(requests) and not touchesDecimals(requests)
        and (not supplyLocked or not touchesSupply(requests));
      };
      case (
        #admin_update_icrc2 _ or #admin_update_icrc4 _
        or #admin_set_index_canister _
        or #set_icrc106_index_principal _ or #icrc107_set_fee_collector _
        // The archive methods follow the owner too, so their power goes with
        // the hand-off and upgrading the canister grants nothing.
        // `getUpgradeError` is a read, but its body answers the owner alone
        // and no wallet asks for it, so it is not part of the open reads.
        or #upgradeArchive _ or #update_archive_controllers _ or #getUpgradeError _
      ) isOwner(caller);

      // Admitted for the owner locked or not: a second lock is the body's
      // no-op, not an ingress refusal.
      case (#admin_lock_supply _) isOwner(caller);

      // ---- The two steps of a hand-off, as the bodies have them. The
      // anonymous principal is refused whatever `owner` and `pending_owner`
      // hold, and with nothing pending nobody can accept. ----
      case (#admin_propose_owner _) not Principal.isAnonymous(caller) and caller == owner;
      case (#accept_ownership _) not Principal.isAnonymous(caller) and ?caller == pending_owner;

      // ---- The owner or a controller, never anonymous, as the body has it ----
      case (#admin_init _) isOwner(caller) or (not Principal.isAnonymous(caller) and Principal.isController(caller));

      // ---- Open to every caller: reads without an argument worth checking,
      // and `deposit_cycles`, which anybody may use to fund the canister ----
      case (
        #icrc1_name _ or #icrc1_symbol _ or #icrc1_decimals _ or #icrc1_fee _
        or #icrc1_metadata _ or #icrc1_total_supply _ or #icrc1_minting_account _
        or #icrc1_supported_standards _ or #icrc10_supported_standards _
        or #icrc3_get_tip_certificate _ or #icrc3_supported_block_types _
        or #get_tip _ or #archives _ or #icrc4_maximum_update_batch_size _
        or #icrc4_maximum_query_batch_size _ or #icrc106_get_index_principal _
        or #icrc107_get_fee_collector _ or #get_icrc85_stats _ or #get_index_canister _
        or #deposit_cycles _ or #get_data_certificate _ or #is_ledger_ready _
        or #get_health _ or #get_owner _ or #get_pending_owner _
        or #is_supply_locked _
      ) true;
    };
  };

  

  // ICRC-85 timer initialization is now handled automatically through the OVSFixed.Init
  // ClassPlus pattern in ICRC1 and ICRC3 libraries - no manual timer setup needed.

  /// Functions for the ICRC1 token standard
  public shared query func icrc1_name() : async Text {
      icrc1().name();
  };

  public shared query func icrc1_symbol() : async Text {
      icrc1().symbol();
  };

  public shared query func icrc1_decimals() : async Nat8 {
      icrc1().decimals();
  };

  public shared query func icrc1_fee() : async ICRC1.Balance {
      icrc1().fee();
  };

  public shared query func icrc1_metadata() : async [ICRC1.MetaDatum] {
      icrc1().metadata()
  };
  public shared query func get_icrc85_stats() : async { activeActions: Nat; lastActionReported: ?Nat; nextCycleActionId: ?Nat } {
    icrc1().get_icrc85_stats()
  };


  public shared query func icrc1_total_supply() : async ICRC1.Balance {
      icrc1().total_supply();
  };

  public shared query func icrc1_minting_account() : async ?ICRC1.Account {
      ?icrc1().minting_account();
  };

  public shared query func icrc1_balance_of(args : ICRC1.Account) : async ICRC1.Balance {
      icrc1().balance_of(args);
  };

  public shared query func icrc1_supported_standards() : async [ICRC1.SupportedStandard] {
      icrc1().supported_standards();
  };

  public shared query func icrc10_supported_standards() : async [ICRC1.SupportedStandard] {
      let standards = icrc1().supported_standards();
      let icrc21 : ICRC1.SupportedStandard = { name = "ICRC-21"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-21" };
      let b = List.fromArray<ICRC1.SupportedStandard>(standards);
      List.add(b, icrc21);
      return List.toArray(b);
  };

  public shared ({ caller }) func icrc1_transfer(args : ICRC1.TransferArgs) : async ICRC1.TransferResult {
      switch(await* icrc1().transfer_tokens(caller, args, false, null)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) Runtime.trap(err);
        case(#err(#awaited(err))) Runtime.trap(err);
      };
  };




  var upgradeError = "";
  var upgradeComplete = false;

  // Set while an `upgradeArchive` run awaits, so a second call cannot
  // interleave its writes to `upgradeError` and `upgradeComplete`. Transient:
  // no call survives an upgrade, and a persisted flag left set would lock the
  // method for good.
  transient var upgradeInFlight = false;

  public type ArchiveUpgradeResult = {
    canister_id : Principal;
    result : { #Ok; #Err : Text };
  };

  // The archive methods are gated on the mutable `owner`, never on `_owner`:
  // `_owner` is whoever performed the last install or upgrade, so gating on it
  // would hand the archives to anyone who upgrades the canister.
  public query ({caller}) func getUpgradeError() : async Text {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    return upgradeError;
  };

  /// Upgrades every ICRC-3 archive and reports each one, in the order of the
  /// snapshot taken before the first `await`. The run completes only when
  /// every archive upgraded; after a failure `upgradeArchive(false)` runs
  /// again. `getUpgradeError` answers the failures of the last run, joined
  /// with "; ", or "" when it had none.
  public shared ({ caller }) func upgradeArchive(bOverride : Bool) : async [ArchiveUpgradeResult] {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    if(bOverride == true or upgradeComplete == false){} else {
      Runtime.trap("Upgrade already complete");
    };
    if(upgradeInFlight){ Runtime.trap("Upgrade already in progress")};
    upgradeInFlight := true;
    upgradeError := "";

    let archives = Iter.toArray<Principal>(Map.keys(icrc3().get_state().archives));
    try {
      // An archive created before the archive kill switch existed takes it here.
      let outcomes = try {
        await UpgradeArchive.upgradeArchiveWith(archives, { icrc85KillSwitch = ?true });
      } catch(e){
        // Nothing is known to have upgraded.
        Array.tabulate<Result.Result<(), Text>>(archives.size(), func(_ : Nat) : Result.Result<(), Text> { #err(Error.message(e)) });
      };

      let results = Array.tabulate<ArchiveUpgradeResult>(archives.size(), func(i : Nat) : ArchiveUpgradeResult {
        let result = if (i < outcomes.size()) outcomes[i] else #err("no result for archive " # Principal.toText(archives[i]));
        { canister_id = archives[i]; result = switch(result){ case(#ok) #Ok; case(#err(e)) #Err(e) } };
      });
      let errors = List.empty<Text>();
      for (r in results.vals()){
        switch(r.result){ case(#Err(e)) List.add(errors, e); case(#Ok) {} };
      };
      if (List.isEmpty(errors)) {
        upgradeComplete := true;
      } else {
        upgradeError := Text.join(List.values(errors), "; ");
      };
      results;
    } finally {
      upgradeInFlight := false;
    };
  };

  

  public type ArchiveControllersResult = {
    canister_id : Principal;
    result : { #Ok : [Principal]; #Err : Text };
  };

  /// Sets the controllers of every ICRC-3 archive to the configured
  /// `archiveControllers` plus this ledger and the current `owner`. The list
  /// REPLACES the archive's controllers, so a former owner is dropped. With
  /// `archiveControllers = null` the archives are unmanaged: nothing is sent
  /// and every archive reports it. One result per archive, in the order of the
  /// snapshot taken before the first `await`. A set of more than
  /// `IC_MAX_CONTROLLERS` is reported for every archive and not sent.
  public shared({caller}) func update_archive_controllers() : async [ArchiveControllersResult] {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};

    // Read once, before any `await`: every archive of this call gets the same
    // set even if `accept_ownership` interleaves, and an archive created
    // mid-loop is left to the next call.
    let current_owner = owner;
    let archives = Iter.toArray<Principal>(Map.keys(icrc3().get_state().archives));

    let final_list : ?[Principal] = switch(icrc3().get_state().constants.archiveProperties.archiveControllers){
      case(null) null;
      case(?val){
        let a_set = switch(val){
          case(?list) Set.fromIter<Principal>(list.vals(), Principal.compare);
          case(null) Set.empty<Principal>();
        };
        Set.add(a_set, Principal.compare, Principal.fromActor(this));
        Set.add(a_set, Principal.compare, current_owner);
        ?Iter.toArray(Set.values(a_set));
      };
    };

    // A set past the IC's limit is refused by the management canister; say
    // why instead, and send nothing. Only a ledger installed before the
    // install check (`checkArchiveControllers`) can get here.
    let over_limit : ?Text = switch(final_list){
      case(?controllers) if (controllers.size() > IC_MAX_CONTROLLERS) {
        ?(Nat.toText(controllers.size()) # " controllers exceeds the IC limit of " # Nat.toText(IC_MAX_CONTROLLERS) # " controllers");
      } else null;
      case(null) null;
    };

    let results = List.empty<ArchiveControllersResult>();
    let ic : ICRC3.IC = actor("aaaaa-aa");
    for (archive in archives.vals()){
      switch(final_list, over_limit){
        case(null, _){
          List.add(results, { canister_id = archive; result = #Err("archive controllers are not configured") });
        };
        case(?_, ?reason){
          List.add(results, { canister_id = archive; result = #Err(reason) });
        };
        case(?controllers, null){
          try {
            await ic.update_settings(({canister_id = archive; settings = {
                      controllers = ?controllers;
                      freezing_threshold = null;
                      memory_allocation = null;
                      compute_allocation = null;
            }}));
            List.add(results, { canister_id = archive; result = #Ok(controllers) });
          } catch(e){
            List.add(results, { canister_id = archive; result = #Err(Error.message(e)) });
          };
        };
      };
    };
    List.toArray(results);
  };
  

  // ======== ICRC-106: Index Principal ========

  public query func icrc106_get_index_principal() : async ICRC1.Icrc106GetResult {
    icrc1().get_icrc106_index_principal();
  };

  public shared({caller}) func set_icrc106_index_principal(principal : ?Principal) : async () {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    icrc1().set_icrc106_index_principal(principal);
  };

  // ======== ICRC-107: Fee Collector Management ========

  public shared ({ caller }) func icrc107_set_fee_collector(args : ICRC1.SetFeeCollectorArgs) : async ICRC1.SetFeeCollectorResult {
    if(not isOwner(caller)){ return #Err(#AccessDenied("Only the owner can set the fee collector")) };
    icrc1().set_fee_collector<system>(caller, args);
  };

  public query func icrc107_get_fee_collector() : async ICRC1.GetFeeCollectorResult {
    icrc1().get_fee_collector();
  };

  // ======== ICRC-21: Consent Messages ========

  public shared query func icrc21_canister_call_consent_message(request : ICRC1.ConsentMessageRequest) : async ICRC1.ConsentMessageResponse {
    icrc1().build_consent_message(request);
  };

  public shared ({ caller }) func mint(args : ICRC1.Mint) : async ICRC1.TransferResult {
      if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
      // Before the first `await`: a mint that starts after the lock is refused.
      if(supplyLocked){ Runtime.trap("Supply is locked: mint is disabled")};

      switch( await* icrc1().mint_tokens(caller, args)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) Runtime.trap(err);
        case(#err(#awaited(err))) Runtime.trap(err);
      };
  };

  public shared ({ caller }) func burn(args : ICRC1.BurnArgs) : async ICRC1.TransferResult {
      switch( await*  icrc1().burn_tokens(caller, args, false)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) Runtime.trap(err);
        case(#err(#awaited(err))) Runtime.trap(err);
      };
  };

   public query ({ caller = _ }) func icrc2_allowance(args: ICRC2.AllowanceArgs) : async ICRC2.Allowance {
      return icrc2().allowance(args.spender, args.account, false);
    };

  public shared ({ caller }) func icrc2_approve(args : ICRC2.ApproveArgs) : async ICRC2.ApproveResponse {
      switch(await*  icrc2().approve_transfers(caller, args, false, null)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) Runtime.trap(err);
        case(#err(#awaited(err))) Runtime.trap(err);
      };
  };

  public shared ({ caller }) func icrc2_transfer_from(args : ICRC2.TransferFromArgs) : async ICRC2.TransferFromResponse {
      switch(await* icrc2().transfer_tokens_from(caller, args, null)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) Runtime.trap(err);
        case(#err(#awaited(err))) Runtime.trap(err);
      };
  };

  public query({caller}) func icrc103_get_allowances(args: ICRC2.GetAllowancesArgs) : async ICRC2Service.AllowanceResult {
    return icrc2().getAllowances(caller, args);
  };

  public query func icrc3_get_blocks(args: ICRC3.GetBlocksArgs) : async ICRC3.GetBlocksResult{
    return icrc3().get_blocks(args);
  };

  // Legacy get_blocks for Rosetta compatibility
  // Returns blocks in the format expected by icrc-ledger-agent (dfinity/ic-icrc-rosetta-api)
  // This includes proper archive callbacks that point to the get_blocks method on archive canisters
  public query func get_blocks(args: { start : Nat; length : Nat }) : async ICRC3Legacy.RosettaGetBlocksResponse {
    return icrc3().get_blocks_rosetta(args);
  };

  public query func get_transactions(args: { start : Nat; length : Nat }) : async ICRC3Legacy.GetTransactionsResponse {

    let results = icrc3().get_blocks_legacy(args);
    return {
      first_index = results.first_index;
      log_length = results.log_length;
      transactions = results.transactions;
      archived_transactions = results.archived_transactions;
    };
  };

  public query func icrc3_get_archives(args: ICRC3.GetArchivesArgs) : async ICRC3.GetArchivesResult{
    return icrc3().get_archives(args);
  };

  // Legacy archives endpoint for Rosetta compatibility
  // Rosetta calls this method via update (not ICRC-3's icrc3_get_archives)
  // Returns the archive info in the format Rosetta expects
  public type LegacyArchiveInfo = {
    canister_id : Principal;
    block_range_start : Nat;
    block_range_end : Nat;
  };

  public shared func archives() : async [LegacyArchiveInfo] {
    let icrc3Archives = icrc3().get_archives({ from = null });
    let buffer = List.empty<LegacyArchiveInfo>();
    for (archive in icrc3Archives.vals()) {
      List.add(buffer, {
        canister_id = archive.canister_id;
        block_range_start = archive.start;
        block_range_end = archive.end;
      });
    };
    List.toArray(buffer);
  };

  public query func icrc3_get_tip_certificate() : async ?ICRC3.DataCertificate {
    return icrc3().get_tip_certificate();
  };

  /// Legacy Rosetta-compatible alias for icrc3_get_tip_certificate.
  /// Returns { certificate: opt blob; hash_tree: blob } to match SNS ledger interface.
  public query func get_data_certificate() : async { certificate: ?Blob; hash_tree: Blob } {
    switch(icrc3().get_tip_certificate()) {
      case(?cert) { { certificate = ?cert.certificate; hash_tree = cert.hash_tree } };
      case(null) { { certificate = null; hash_tree = "" } };
    };
  };

  /// SNS parity: returns true once the ledger is initialized and ready.
  public query func is_ledger_ready() : async Bool {
    true;
  };

  public query func icrc3_supported_block_types() : async [ICRC3.BlockType] {
    return icrc3().supported_block_types();
  };

  public query func get_tip() : async ICRC3.Tip {
    return icrc3().get_tip();
  };

  public shared ({ caller }) func icrc4_transfer_batch(args: ICRC4.TransferBatchArgs) : async ICRC4.TransferBatchResults {
      switch(await* icrc4().transfer_batch_tokens(caller, args, null, null)){
        case(#trappable(val)) val;
        case(#awaited(val)) val;
        case(#err(#trappable(err))) err;
        case(#err(#awaited(err))) err;
      };
  };

  public shared query func icrc4_balance_of_batch(request : ICRC4.BalanceQueryArgs) : async ICRC4.BalanceQueryResult {
      icrc4().balance_of_batch(request);
  };

  public shared query func icrc4_maximum_update_batch_size() : async ?Nat {
      ?icrc4().get_state().ledger_info.max_transfers;
  };

  public shared query func icrc4_maximum_query_batch_size() : async ?Nat {
      ?icrc4().get_state().ledger_info.max_balances;
  };

  /// The owner changes in two steps, so that a mistyped principal, or one
  /// nobody holds the key of, can never take the ledger's administration
  /// with it: nothing moves until the proposed principal proves it can act.
  ///
  /// Step 1, by the owner. `?p` proposes `p` and replaces any earlier
  /// proposal; `null` cancels. The proposal grants `p` nothing.
  public shared ({ caller }) func admin_propose_owner(proposed : ?Principal) : async () {
    if(Principal.isAnonymous(caller)){ Runtime.trap("Unauthorized")};
    if(caller != owner){ Runtime.trap("Unauthorized")};
    switch(proposed){
      case(?p){
        if(Principal.isAnonymous(p)){ Runtime.trap("The anonymous principal cannot be the owner")};
        if(p == owner){ Runtime.trap("That principal is already the owner")};
      };
      case(null){};
    };
    pending_owner := proposed;
  };

  /// Step 2, by the proposed principal, and by nobody else.
  public shared ({ caller }) func accept_ownership() : async () {
    if(Principal.isAnonymous(caller)){ Runtime.trap("Unauthorized")};
    if(?caller != pending_owner){ Runtime.trap("Unauthorized")};
    owner := caller;
    pending_owner := null;
  };

  public query func get_owner() : async Principal { owner };

  public query func get_pending_owner() : async ?Principal { pending_owner };

  public shared ({ caller }) func admin_update_icrc1(requests : [ICRC1.UpdateLedgerInfoRequest]) : async [Bool] {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    // The whole batch, before any of it is applied: a partial apply would
    // answer a vector that reads like success.
    if(setsAnonymousMinter(requests)){
      Runtime.trap("The anonymous principal cannot be the owner of the minting account: anyone could mint");
    };
    if(touchesDecimals(requests)){
      Runtime.trap("Decimals cannot change after install");
    };
    if(supplyLocked and touchesSupply(requests)){
      Runtime.trap("Supply is locked: MintingAccount and MaxSupply cannot change");
    };
    return icrc1().update_ledger_info(requests);
  };

  /// Locks the supply for good: `mint` and any `admin_update_icrc1` batch that
  /// touches the minting account or the maximum supply are refused from now
  /// on. The owner only, never the anonymous principal. No method unlocks it,
  /// and a second call changes nothing. See `supplyLocked` for what the lock
  /// does not close.
  public shared ({ caller }) func admin_lock_supply() : async () {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    supplyLocked := true;
  };

  public query func is_supply_locked() : async Bool { supplyLocked };

  public shared ({ caller }) func admin_update_icrc2(requests : [ICRC2.UpdateLedgerInfoRequest]) : async [Bool] {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    return icrc2().update_ledger_info(requests);
  };

  public shared ({ caller }) func admin_update_icrc4(requests : [ICRC4.UpdateLedgerInfoRequest]) : async [Bool] {
    if(not isOwner(caller)){ Runtime.trap("Unauthorized")};
    return icrc4().update_ledger_info(requests);
  };

  //============================================================================
  // Index Push Notification
  //============================================================================

  /// Configure the index canister for push notifications
  /// Set to null to disable notifications
  public shared ({ caller }) func admin_set_index_canister(principal : ?Principal) : async Bool {
    if (not isOwner(caller)) { Runtime.trap("Unauthorized") };
    index_canister := principal;
    return true;
  };

  /// Get the currently configured index canister
  public query func get_index_canister() : async ?Principal {
    index_canister;
  };

  /// Index notification listener - schedules notify call when blocks are added
  /// This is registered with ICRC-3's record_added_listener mechanism
  private func index_notify_listener<system>(_transaction: ICRC3.Transaction, _index: Nat) : () {
    // Skip if no index canister configured
    let ?_idx_principal = index_canister else return;
    
    // Skip if already have a pending notification (batching)
    switch (pending_notify_action_id) {
      case (?_) {
        // Already have a pending notify - it will send the latest index at execution time
        return;
      };
      case (null) {
        // Schedule new notify action
        let tt = getTimerTool();
        let now = Int.abs(Time.now());
        
        let action_id = tt.setActionASync<system>(
          now + INDEX_NOTIFY_DELAY_NS,
          {
            actionType = "index:notify";
            params = Blob.fromArray([]); // Current block index retrieved at execution time
          },
          15_000_000_000 // 15 second timeout
        );
        
        pending_notify_action_id := ?action_id.id;
      };
    };
  };

  /// Execute the index notify call - called by TimerTool when the scheduled time arrives
  private func execute_index_notify(actionId: TT.ActionId, _action: TT.Action) : async* Star.Star<TT.ActionId, TT.Error> {
    let ?idx_principal = index_canister else {
      pending_notify_action_id := null;
      return #trappable(actionId);
    };
    
    // Get current max block index from ICRC-3
    let stats = icrc3().get_stats();
    let max_block = stats.lastIndex;
    
    // Create actor reference to index canister
    let index_actor = actor(Principal.toText(idx_principal)) : actor {
      notify : (Nat) -> async ();
    };
    
    try {
      // Call index canister with the latest block number using best effort messaging
      await (with timeout = 60) index_actor.notify(max_block);
      pending_notify_action_id := null;
      return #awaited(actionId);
    } catch (e) {
      // Log error but clear pending to allow retry on next block
      debug D.print("Index notify failed: " # Error.message(e));
      pending_notify_action_id := null;
      return #err(#awaited({ error_code = 1; message = Error.message(e) }));
    };
  };

  /// Register index notification handlers
  /// Called during initialization and after upgrades
  private func register_index_notify_handlers<system>() {
    // Register execution handler with TimerTool
    getTimerTool().registerExecutionListenerAsync(?"index:notify", execute_index_notify);
    
    // Register record added listener with ICRC-3
    icrc3().register_record_added_listener("index_notify", index_notify_listener);
  };

  //============================================================================

  /* /// Uncomment this code to establish have icrc1 notify you when a transaction has occurred.
  private func transfer_listener(trx: ICRC1.Transaction, trxid: Nat) : () {

  };

  /// Uncomment this code to establish have icrc1 notify you when a transaction has occurred.
  private func approval_listener(trx: ICRC2.TokenApprovalNotification, trxid: Nat) : () {

  };

  /// Uncomment this code to establish have icrc1 notify you when a transaction has occurred.
  private func transfer_from_listener(trx: ICRC2.TransferFromNotification, trxid: Nat) : () {

  }; */

  private var _init = false;
  public shared(msg) func admin_init() : async () {
    //can only be called once
    // The owner, or a controller that is not the anonymous principal: a ledger
    // installed by the anonymous principal has it among its controllers.
    if(not (isOwner(msg.caller) or (not Principal.isAnonymous(msg.caller) and Principal.isController(msg.caller)))){
      Runtime.trap("unauthorized");
    };

    if(_init == false){
      //ensure metadata has been registered


      // Register index push notification handlers
      register_index_notify_handlers<system>();

      //uncomment the following line to register the transfer_listener
      //icrc1().register_token_transferred_listener<system>("my_namespace", transfer_listener);

      //uncomment the following line to register the transfer_listener
      //icrc2().register_token_approved_listener<system>("my_namespace", approval_listener);

      //uncomment the following line to register the transfer_listener
      //icrc2().register_transfer_from_listener<system>("my_namespace", transfer_from_listener);
    };
    _init := true;
  };


  // Deposit cycles into this canister.
  public shared func deposit_cycles() : async () {
      let amount = Cycles.available();
      let accepted = Cycles.accept<system>(amount);
      assert (accepted == amount);
  };

  public query func get_health() : async { cycles : Nat } {
    { cycles = Cycles.balance() }
  };

  system func postupgrade() {
    // An upgrade clears every IC timer and Motoko numbers new ones from 1
    // again, but TimerTool keeps the id of its last timer in stable state and
    // cancels it the next time it schedules. That id may now belong to a new,
    // unrelated timer (e.g. ICRC-3 archiving), so forget it first.
    switch (tt_state) {
      case (?#v0_1_0(#data(s))) { s.nextTimer := null };
      case (_) {};
    };

    // ICRC-3 arms its archive timer only while `cleaningTimer` is null, and
    // only the timer itself sets it back to null. An upgrade between the block
    // that armed it and its run leaves the field set and the ledger never
    // archives again; with it null, the next block arms a new timer.
    switch (icrc3_migration_state_new) {
      case (#v0_2_0(#data(s))) { s.cleaningTimer := null };
      case (#v0_1_0(#data(s))) { s.cleaningTimer := null };
      case (_) {};
    };

    //re wire up the listener after upgrade
    
    // Re-register index push notification handlers (transient state lost on upgrade)
    register_index_notify_handlers<system>();

    // Arm TimerTool's timer again for the actions queued before the upgrade
    // (an index notify). Queued ICRC-85 share actions only reschedule
    // themselves and return while the kill switch is on.
    getTimerTool().initialize<system>();

    //uncomment the following line to register the transfer_listener
      //icrc1().register_token_transferred_listener("my_namespace", transfer_listener);

      //uncomment the following line to register the transfer_listener
      //icrc2().register_token_approved_listener("my_namespace", approval_listener);

      //uncomment the following line to register the transfer_listener
      //icrc2().register_transfer_from_listener("my_namespace", transfer_from_listener);
  };

};
