/// token-mixin.mo - ICRC token using library mixin includes
/// Uses includes for ALL ICRC standards (1, 2, 3, 4)
/// All ICRC endpoints come from the included mixins - ultra compact ~150 lines!

import Blob "mo:core/Blob";
import Cycles "mo:core/Cycles";
import D "mo:core/Debug";
import Error "mo:core/Error";
import Runtime "mo:core/Runtime";
import Int "mo:core/Int";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import CertTree "mo:ic-certification/CertTree";
import Star "mo:star/star";

import ICRC1 "mo:icrc1-mo/ICRC1";
import ICRC1Mixin "mo:icrc1-mo/ICRC1/mixin";
import ICRC2 "mo:icrc2-mo/ICRC2";
import ICRC2Mixin "mo:icrc2-mo/ICRC2/mixin";
import ICRC3 "mo:icrc3-mo/";
import ICRC3Mixin "mo:icrc3-mo/mixin";
import ICRC4 "mo:icrc4-mo/ICRC4";
import ICRC4Mixin "mo:icrc4-mo/ICRC4/mixin";
import ClassPlus "mo:class-plus";
import TT "mo:timer-tool";
import TimerToolMixin "mo:timer-tool/TimerToolMixin";

shared ({ caller = _owner }) persistent actor class Token(args: ?{
  icrc1 : ?ICRC1.InitArgs;
  icrc2 : ?ICRC2.InitArgs;
  icrc3 : ICRC3.InitArgs;
  icrc4 : ?ICRC4.InitArgs;
}) = this {

  // ==========================================================================
  // Configuration defaults and argument merging
  // ==========================================================================

  transient let canisterId = Principal.fromActor(this);
  transient let org_icdevs_class_plus_manager = ClassPlus.ClassPlusInitializationManager<system>(_owner, canisterId, true);

  let icrc1_defaults : ICRC1.InitArgs = {
    name = ?"Test Token"; symbol = ?"TTT"; decimals = 8;
    logo = ?"data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMSIgaGVpZ2h0PSIxIj48cmVjdCB3aWR0aD0iMTAwJSIgaGVpZ2h0PSIxMDAlIiBmaWxsPSJyZWQiLz48L3N2Zz4=";
    fee = ?#Fixed(10000); max_supply = null; min_burn_amount = ?10000; max_memo = ?64;
    minting_account = ?{ owner = _owner; subaccount = null };
    advanced_settings = null; metadata = null; fee_collector = null;
    transaction_window = null; permitted_drift = null;
    max_accounts = ?100000000; settle_to_accounts = ?99999000;
  };
  
  let icrc2_defaults : ICRC2.InitArgs = {
    max_approvals_per_account = ?10000; max_allowance = ?#TotalSupply;
    fee = ?#ICRC1; advanced_settings = null;
    max_approvals = ?10000000; settle_to_approvals = ?9990000;
    cleanup_interval = null; cleanup_on_zero_balance = null;
    icrc103_max_take_value = ?1000; icrc103_public_allowances = ?true;
  };
  
  let icrc3_defaults : ICRC3.InitArgs = {
    maxActiveRecords = 3000; settleToRecords = 2000; maxRecordsInArchiveInstance = 500_000;
    maxArchivePages = 62500; archiveIndexType = #Stable; maxRecordsToArchive = 8000;
    archiveCycles = 20_000_000_000_000; archiveControllers = null;
    supportedBlocks = [
      { block_type = "1xfer"; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "2xfer"; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "2approve"; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1mint"; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1burn"; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "107feecol"; url="https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-107" },
    ];
  };
  
  let icrc4_defaults : ICRC4.InitArgs = { max_balances = ?200; max_transfers = ?200; fee = ?#ICRC1 };

  // Merge user args with defaults
  transient let icrc1_args = switch(args) {
    case(?a) switch(a.icrc1) {
      case(?v) { { v with minting_account = switch(v.minting_account) { case(?m) ?m; case(null) icrc1_defaults.minting_account } } };
      case(null) icrc1_defaults;
    };
    case(null) icrc1_defaults;
  };
  transient let icrc2_args = switch(args) { case(?a) switch(a.icrc2) { case(?v) v; case(null) icrc2_defaults }; case(null) icrc2_defaults };
  transient let icrc3_args = switch(args) { case(?a) a.icrc3; case(null) icrc3_defaults };
  transient let icrc4_args = switch(args) { case(?a) switch(a.icrc4) { case(?v) v; case(null) icrc4_defaults }; case(null) icrc4_defaults };

  // ==========================================================================
  // Stable state (only owner needed - ICRC state managed by mixins)
  // ==========================================================================
  
  let cert_store : CertTree.Store = CertTree.newStore();

  // Whether the anonymous principal signs for `account`, whatever its subaccount.
  func isAnonymousAccount(account : ICRC1.Account) : Bool { Principal.isAnonymous(account.owner) };

  // Traps when the ledger would start with the anonymous principal as its
  // installer: it would be its owner, and it is a controller. See `src/Token.mo`.
  func refuseAnonymousInstaller(installer : Principal) {
    if(Principal.isAnonymous(installer)) Runtime.trap("The anonymous principal cannot install the ledger: it would be its owner, and it is a controller");
  };

  // Traps when the minting account would be one the anonymous principal signs
  // for: a transfer from it is a mint, so anyone could mint.
  func refuseAnonymousMinter(minting : ?ICRC1.Account) {
    let ?account = minting else return;
    if(isAnonymousAccount(account)) Runtime.trap("The anonymous principal cannot be the owner of the minting account: anyone could mint");
  };

  // The initializer of a persisted variable runs at install only. `_owner` is
  // whoever sends the install OR the upgrade, so an upgrade must never run
  // this check. The minting account is checked below, where it is applied.
  var owner = do {
    refuseAnonymousInstaller(_owner);
    _owner;
  };
  // Proposed by the owner as its successor; holds no power until it accepts.
  var pending_owner : ?Principal = null;

  // The one owner predicate. `owner` starts as whoever installed the ledger. A
  // ledger installed by the anonymous principal before that install was refused
  // keeps its anonymous `owner`; the anonymous caller is refused whatever
  // `owner` holds.
  func isOwner(caller : Principal) : Bool { not Principal.isAnonymous(caller) and caller == owner };

  var _init = false;
  // Set for good by `admin_lock_supply`; see `src/Token.mo` for what it does
  // not close (an upgrade to a wasm that ignores it, a reinstall; transfers from
  // a minting account somebody holds still mint).
  var supplyLocked : Bool = false;

  // Index notification state
  var index_canister : ?Principal = null;
  var pending_notify_action_id : ?Nat = null;
  let INDEX_NOTIFY_DELAY_NS : Nat = 2_000_000_000; // 2 seconds

  // ==========================================================================
  // TimerTool via mixin - shared timer queue for all components
  // ==========================================================================

  // ICRC-85 is OFF in this token: it shares no cycles, through any stream
  // (TimerTool, ICRC-1, ICRC-3 and its archives). In every library a `null`
  // switch means ON; only `?true` turns a stream off, as in `src/Token.mo`.
  // `pic/TokenWithICRC85.mo` shows how to turn sharing on.
  func get_timertool_environment() : TT.Environment {{
    advanced = ?{
      icrc85 = ?{
        // TimerTool schedules its own share unless this switch is `?true`,
        // and a share queued by an earlier build returns before sending.
        kill_switch = ?true;
        handler = null;
        period = null;
        asset = null;
        platform = null;
        tree = null;
        collector = null;
        initialWait = null;
      };
    };
    syncUnsafe = null;
    reportExecution = null;
    reportError = null;
    reportBatch = null;
  }};

  include TimerToolMixin({
    config = {
      org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
      args = null;
      pullEnvironment = ?get_timertool_environment;
      onInitialize = null;
    };
    caller = canisterId;
    canisterId = canisterId;
  });

  // ==========================================================================
  // Environment providers for mixins
  // ==========================================================================

  func updated_certification(_cert: Blob, _lastIndex: Nat) : Bool { true };
  func get_certificate_store() : CertTree.Store { cert_store };

  func get_icrc3_environment() : ICRC3.Environment {{
    advanced = ?{
      get_archive_controllers = null;
      updated_certification = ?updated_certification;
      // ICRC-85 OFF for the icrc3 stream, and for every archive, which
      // takes this switch at creation. A `null` environment here does NOT
      // switch it off: it means "default collector, no kill switch".
      icrc85 = ?{
        var org_icdevs_timer_tool = ?org_icdevs_timer_tool;
        var collector = null;
        advanced = ?{ kill_switch = ?true; handler = null; tree = null };
      };
    };
    get_certificate_store = ?get_certificate_store;
    var org_icdevs_timer_tool = ?org_icdevs_timer_tool;
  }};

  func get_icrc1_environment() : ICRC1.Environment {{
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
    var org_icdevs_timer_tool = ?org_icdevs_timer_tool;
    var org_icdevs_class_plus_manager = null;
  }};

  func get_icrc2_environment() : ICRC2.Environment {{ icrc1 = icrc1(); get_fee = null }};
  func get_icrc4_environment() : ICRC4.Environment {{ icrc1 = icrc1(); get_fee = null }};

  func ensureBlockTypes(c: ICRC3.ICRC3) {
    let types = List.fromIter<ICRC3.BlockType>(c.supported_block_types().vals());
    let has = func(t: Text) : Bool = List.any(types, func(bt: ICRC3.BlockType) : Bool = bt.block_type == t);
    for(bt in ["1xfer","2xfer","2approve","1mint","1burn"].vals()) {
      if(not has(bt)) List.add(types, {block_type=bt; url="https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3"});
    };
    c.update_supported_blocks(List.toArray(types));
  };

  // ==========================================================================
  // Mixin Includes - ALL ICRC standards via mixins!
  // ==========================================================================

  // ICRC3 - Transaction log (must be first so icrc3() is available for ICRC1 environment)
  include ICRC3Mixin({
    ICRC3.defaultMixinArgs(org_icdevs_class_plus_manager) with
    args = ?icrc3_args;
    pullEnvironment = ?get_icrc3_environment;
    onInitialize = ?(func(c: ICRC3.ICRC3) : async* () { ensureBlockTypes(c) });
  });

  // ICRC1 - Basic fungible token
  include ICRC1Mixin({
    ICRC1.defaultMixinArgs(org_icdevs_class_plus_manager) with
    args = ?icrc1_args;
    pullEnvironment = ?get_icrc1_environment;
    onInitialize = ?(func(c: ICRC1.ICRC1) : async* () {
      ignore c.register_supported_standards({ name = "ICRC-3"; url = "https://github.com/dfinity/ICRC/ICRCs/icrc-3/" });
      ignore c.register_supported_standards({ name = "ICRC-10"; url = "https://github.com/dfinity/ICRC/ICRCs/icrc-10/" });
    });
    canSetFeeCollector = ?(func(caller : Principal) : Bool { isOwner(caller) });
    canSetIndexPrincipal = ?(func(caller : Principal) : Bool { isOwner(caller) });
  });

  // The mixin applies `icrc1_args` when it first builds the ICRC-1 state: after
  // the install or, if an upgrade comes before that, from that upgrade's args.
  // So the minting account is checked on every start that finds the state not
  // built yet, and never once it is built: an upgrade of a working ledger does
  // not apply its init args, and is not refused for them. The decimals come
  // from the same args: such an early upgrade still sets them, as the install
  // would have, since no balance or block exists yet to be read with others.
  switch(icrc1_migration_state) {
    case(#v0_0_0 _) refuseAnonymousMinter(icrc1_args.minting_account);
    case(_) {};
  };

  // ICRC2 - Approve/transfer_from
  include ICRC2Mixin({
    ICRC2.defaultMixinArgs(org_icdevs_class_plus_manager) with
    args = ?icrc2_args;
    pullEnvironment = ?get_icrc2_environment;
    onInitialize = ?(func(_c: ICRC2.ICRC2) : async* () {
      ignore icrc1().register_supported_standards({ name = "ICRC-103"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-103" });
    });
  });

  // ICRC4 - Batch transfers
  include ICRC4Mixin({
    ICRC4.defaultMixinArgs(org_icdevs_class_plus_manager) with
    args = ?icrc4_args;
    pullEnvironment = ?get_icrc4_environment;
    onInitialize = ?(func(_c: ICRC4.ICRC4) : async* () {
      ignore icrc1().register_supported_standards({ name = "ICRC-4"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-4" });
    });
  });

  // ==========================================================================
  // Token-specific endpoints (mint, burn, admin)
  // ==========================================================================

  // Any `#MintingAccount` or `#MaxSupply` in a ledger-info batch.
  func touchesSupply(r: [ICRC1.UpdateLedgerInfoRequest]) : Bool {
    for(x in r.vals()) { switch(x) { case(#MintingAccount _ or #MaxSupply _) return true; case(_) {} } };
    false
  };

  // Any `#Decimals`: the init args set them at install and nothing changes them
  // after, since every amount already recorded is read with them.
  func touchesDecimals(r: [ICRC1.UpdateLedgerInfoRequest]) : Bool {
    for(x in r.vals()) { switch(x) { case(#Decimals _) return true; case(_) {} } };
    false
  };

  // Any `#MintingAccount` that the anonymous principal signs for.
  func setsAnonymousMinter(r: [ICRC1.UpdateLedgerInfoRequest]) : Bool {
    for(x in r.vals()) { switch(x) { case(#MintingAccount a) if(isAnonymousAccount(a)) return true; case(_) {} } };
    false
  };

  public shared({caller}) func mint(a: ICRC1.Mint) : async ICRC1.TransferResult {
    if(not isOwner(caller)) Runtime.trap("Unauthorized");
    if(supplyLocked) Runtime.trap("Supply is locked: mint is disabled");
    switch(await* icrc1().mint_tokens(caller, a)) { case(#trappable(v) or #awaited(v)) v; case(#err(#trappable(e) or #awaited(e))) Runtime.trap(e) };
  };

  public shared({caller}) func burn(a: ICRC1.BurnArgs) : async ICRC1.TransferResult {
    switch(await* icrc1().burn_tokens(caller, a, false)) { case(#trappable(v) or #awaited(v)) v; case(#err(#trappable(e) or #awaited(e))) Runtime.trap(e) };
  };

  // The owner changes in two steps: nothing moves until the proposed principal
  // accepts, so a mistyped principal cannot take the administration with it.
  // `null` cancels a proposal; a new proposal replaces the pending one.
  public shared({caller}) func admin_propose_owner(proposed: ?Principal) : async () {
    if(Principal.isAnonymous(caller)) Runtime.trap("Unauthorized");
    if(caller != owner) Runtime.trap("Unauthorized");
    switch(proposed){
      case(?p){
        if(Principal.isAnonymous(p)) Runtime.trap("The anonymous principal cannot be the owner");
        if(p == owner) Runtime.trap("That principal is already the owner");
      };
      case(null){};
    };
    pending_owner := proposed;
  };
  public shared({caller}) func accept_ownership() : async () {
    if(Principal.isAnonymous(caller)) Runtime.trap("Unauthorized");
    if(?caller != pending_owner) Runtime.trap("Unauthorized");
    owner := caller;
    pending_owner := null;
  };
  public query func get_owner() : async Principal { owner };
  public query func get_pending_owner() : async ?Principal { pending_owner };
  // A batch that gives the minting account to the anonymous principal, that
  // changes the decimals, or that touches the supply once locked, is refused
  // whole, before any of it applies.
  public shared({caller}) func admin_update_icrc1(r: [ICRC1.UpdateLedgerInfoRequest]) : async [Bool] {
    if(not isOwner(caller)) Runtime.trap("Unauthorized");
    if(setsAnonymousMinter(r)) Runtime.trap("The anonymous principal cannot be the owner of the minting account: anyone could mint");
    if(touchesDecimals(r)) Runtime.trap("Decimals cannot change after install");
    if(supplyLocked and touchesSupply(r)) Runtime.trap("Supply is locked: MintingAccount and MaxSupply cannot change");
    icrc1().update_ledger_info(r)
  };
  // Owner only, never anonymous; irreversible; a second call changes nothing.
  public shared({caller}) func admin_lock_supply() : async () {
    if(not isOwner(caller)) Runtime.trap("Unauthorized");
    supplyLocked := true;
  };
  public query func is_supply_locked() : async Bool { supplyLocked };
  public shared({caller}) func admin_update_icrc2(r: [ICRC2.UpdateLedgerInfoRequest]) : async [Bool] { if(not isOwner(caller)) Runtime.trap("Unauthorized"); icrc2().update_ledger_info(r) };
  public shared({caller}) func admin_update_icrc4(r: [ICRC4.UpdateLedgerInfoRequest]) : async [Bool] { if(not isOwner(caller)) Runtime.trap("Unauthorized"); icrc4().update_ledger_info(r) };

  // ==========================================================================
  // Index Push Notification
  // ==========================================================================

  /// Index notification listener - schedules notify call when blocks are added
  private func index_notify_listener<system>(_transaction: ICRC3.Transaction, _index: Nat) : () {
    let ?_idx_principal = index_canister else return;
    switch (pending_notify_action_id) {
      case (?_) { return }; // Already have a pending notify
      case (null) {

        let now = Int.abs(Time.now());
        let action_id = org_icdevs_timer_tool.setActionASync<system>(
          now + INDEX_NOTIFY_DELAY_NS,
          { actionType = "index:notify"; params = Blob.fromArray([]) },
          15_000_000_000
        );
        pending_notify_action_id := ?action_id.id;
      };
    };
  };

  /// Execute the index notify call
  private func execute_index_notify(actionId: TT.ActionId, _action: TT.Action) : async* Star.Star<TT.ActionId, TT.Error> {
    let ?idx_principal = index_canister else {
      pending_notify_action_id := null;
      return #trappable(actionId);
    };
    let stats = icrc3().get_stats();
    let max_block = stats.lastIndex;
    let index_actor = actor(Principal.toText(idx_principal)) : actor { notify : (Nat) -> async () };
    try {
      await (with timeout = 60) index_actor.notify(max_block);
      pending_notify_action_id := null;
      return #awaited(actionId);
    } catch (e) {
      debug D.print("Index notify failed: " # Error.message(e));
      pending_notify_action_id := null;
      return #err(#awaited({ error_code = 1; message = Error.message(e) }));
    };
  };

  /// Register index notify handlers with TimerTool and ICRC-3
  private func register_index_notify_handlers() {
    org_icdevs_timer_tool.registerExecutionListenerAsync(?"index:notify", execute_index_notify);
    icrc3().register_record_added_listener("index_notify", index_notify_listener);
  };

  /// Configure the index canister for push notifications (null to disable)
  public shared({caller}) func admin_set_index_canister(principal: ?Principal) : async Bool {
    if(not isOwner(caller)) Runtime.trap("Unauthorized");
    index_canister := principal;
    true;
  };

  /// Get the currently configured index canister
  public query func get_index_canister() : async ?Principal { index_canister };

  // The owner, or a controller that is not the anonymous principal, as in
  // Token.mo. It only sets `_init` today, but an admin method is not left open.
  public shared({caller}) func admin_init() : async () {
    if(not (isOwner(caller) or (not Principal.isAnonymous(caller) and Principal.isController(caller)))) Runtime.trap("Unauthorized");
    _init := true;
  };

  // Register index notify handlers via ClassPlus initialization
  List.add<() -> async* ()>(org_icdevs_class_plus_manager.calls, func() : async* () {
    register_index_notify_handlers();
  });

  public shared func deposit_cycles() : async () { ignore Cycles.accept<system>(Cycles.available()) };

  system func postupgrade() {
    // An upgrade clears every IC timer and Motoko numbers new ones from 1
    // again, but TimerTool keeps the id of its last timer in stable state and
    // cancels it the next time it schedules. That id may now belong to a new,
    // unrelated timer (e.g. ICRC-3 archiving), so forget it first.
    //
    // This must run before any TimerTool call in this function. If it ran
    // after a TimerTool `initialize`, it would forget the timer that call just
    // set, and that timer would still fire as an orphan.
    // Unlike `src/Token.mo`, there is no explicit re-arm here: the ClassPlus
    // manager (`org_icdevs_class_plus_manager`, auto-timer on) already
    // initializes TimerTool again on every upgrade, from a timer that runs
    // after this function. That re-arm reads the id cleared here.
    // With that re-arm in place this line is defensive: the manager's timer
    // is always the first of field initialization (id 1) and TimerTool's
    // re-arm takes the next one, so the kept id never names a live timer when
    // the re-arm cancels it. Without the auto-timer this line is required:
    // the first schedule would then come from a later block and could cancel
    // the ICRC-3 archive timer (pic/timertool_upgrade.test.ts, on Token.mo).
    switch (org_icdevs_timer_tool_state) {
      case (#v0_1_0(#data(s))) { s.nextTimer := null };
      case (_) {};
    };

    // ICRC-3 arms its archive timer only while `cleaningTimer` is null, and
    // only the timer itself sets it back to null. An upgrade between the block
    // that armed it and its run leaves the field set and the ledger never
    // archives again; with it null, the next block arms a new timer.
    switch (icrc3_migration_state) {
      case (#v0_2_0(#data(s))) { s.cleaningTimer := null };
      case (#v0_1_0(#data(s))) { s.cleaningTimer := null };
      case (_) {};
    };
  };

  // ==========================================================================
  // Legacy / Candid Parity
  // ==========================================================================

  /// Legacy Rosetta-compatible alias for icrc3_get_tip_certificate.
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
};
