/// Test-only harness for the ICRC-1 dedup index (`recent_transactions`).
///
/// It wires the vendored `ICRC1` class the way `src/Token.mo` does (same
/// ICRC-3 log, same TimerTool, every ICRC-85 kill switch on, default
/// `transaction_window` and `permitted_drift`) and adds a few queries and
/// owner-only updates that read or feed the index directly. `src/Token.mo`'s
/// public interface does not change: the index size is not observable through
/// it, and the tests of the bounded sweep need it (pic/recents_sweep.test.ts,
/// pic/recents_upgrade.test.ts).
///
/// Not deployed anywhere. Built by pic/build-token-wasm.sh as `recents_probe`
/// (current sources) and `recents_probe_base` (the same file compiled against
/// the libraries of an earlier commit, by pic/build-baseline-wasm.sh).

import List "mo:core/List";
import Map "mo:core/Map";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import InternetComputer "mo:core/InternetComputer";
import CertTree "mo:ic-certification/CertTree";
import Sha256 "mo:sha2/Sha256";
import ICRC1 "mo:icrc1-mo/ICRC1";
import ICRC3 "mo:icrc3-mo/";
import ClassPlus "mo:class-plus";
import TT "mo:timer-tool";

shared ({ caller = _owner }) persistent actor class RecentsProbe() = this {

  transient let org_icdevs_class_plus_manager = ClassPlus.ClassPlusInitializationManager<system>(_owner, Principal.fromActor(this), true);

  // Same values as Token.mo's defaults. transaction_window and permitted_drift
  // stay null: the library defaults (24 h, 60 s) are what the tests assume.
  transient let icrc1_args : ICRC1.InitArgs = {
    name = ?"Probe Token";
    symbol = ?"PRB";
    logo = null;
    decimals = 8;
    fee = ?#Fixed(10000);
    minting_account = ?{ owner = _owner; subaccount = null };
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

  transient let icrc3_args : ICRC3.InitArgs = {
    maxActiveRecords = 10_000;
    settleToRecords = 6_000;
    maxRecordsInArchiveInstance = 100_000_000;
    maxArchivePages = 62500;
    archiveIndexType = #Stable;
    maxRecordsToArchive = 10_000;
    archiveCycles = 20_000_000_000_000;
    archiveControllers = null;
    supportedBlocks = [
      { block_type = "1xfer"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1mint"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1burn"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
    ];
  };

  var icrc1_migration_state = ICRC1.init(ICRC1.initialState(), #v0_1_0(#id), ?icrc1_args, _owner);
  var icrc3_migration_state = ICRC3.initialState();
  let cert_store : CertTree.Store = CertTree.newStore();
  var tt_state : ?TT.State = null;
  transient var _timerTool : ?TT.TimerTool = null;

  // ICRC-85 is OFF, exactly as in Token.mo: TimerTool, ICRC-3 and ICRC-1 all
  // get their kill switch.
  func getTimerTool() : TT.TimerTool {
    switch (_timerTool) {
      case (?tt) tt;
      case (null) {
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
          tt_state,
          Principal.fromActor(this),
          Principal.fromActor(this),
          null,
          ?ttEnv,
          func(newState : TT.State) { tt_state := ?newState },
        );
        _timerTool := ?newTT;
        newTT;
      };
    };
  };

  func get_icrc3_environment() : ICRC3.Environment {
    {
      advanced = ?{
        get_archive_controllers = null;
        updated_certification = null;
        icrc85 = ?{
          var org_icdevs_timer_tool = ?getTimerTool();
          var collector = null;
          advanced = ?{ kill_switch = ?true; handler = null; tree = null };
        };
      };
      get_certificate_store = ?(func() : CertTree.Store { cert_store });
      var org_icdevs_timer_tool = ?getTimerTool();
    };
  };

  transient let icrc3 = ICRC3.Init({
    org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
    initialState = icrc3_migration_state;
    args = ?icrc3_args;
    pullEnvironment = ?get_icrc3_environment;
    onInitialize = null;
    onStorageChange = func(state : ICRC3.State) { icrc3_migration_state := state };
  });

  func get_icrc1_environment() : ICRC1.Environment {
    {
      advanced = ?{
        icrc85 = {
          kill_switch = ?true;
          handler = null;
          tree = null;
          collector = null;
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

  transient let getIcrc1 = ICRC1.Init({
    org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
    initialState = icrc1_migration_state;
    args = ?icrc1_args;
    pullEnvironment = ?get_icrc1_environment;
    onInitialize = null;
    onStorageChange = func(state : ICRC1.State) { icrc1_migration_state := state };
  });

  func icrc1() : ICRC1.ICRC1 { getIcrc1() };

  func onlyOwner(caller : Principal) {
    if (caller != _owner) Runtime.trap("RecentsProbe: owner only");
  };

  // ======== The ledger surface the tests use ========

  public shared ({ caller }) func icrc1_transfer(args : ICRC1.TransferArgs) : async ICRC1.TransferResult {
    switch (await* icrc1().transfer_tokens(caller, args, false, null)) {
      case (#trappable(val)) val;
      case (#awaited(val)) val;
      case (#err(#trappable(err))) Runtime.trap(err);
      case (#err(#awaited(err))) Runtime.trap(err);
    };
  };

  public query func icrc1_balance_of(account : ICRC1.Account) : async Nat {
    icrc1().balance_of(account);
  };

  // ======== The dedup index ========

  /// Number of entries in `recent_transactions`, live or not.
  public query func recents_size() : async Nat {
    Map.size(icrc1().get_state().recent_transactions);
  };

  /// The entry for one transaction hash: (inserted_at, block index).
  public query func recents_get(key : Blob) : async ?(Nat64, Nat) {
    Map.get(icrc1().get_state().recent_transactions, Blob.compare, key);
  };

  /// Adds `n` synthetic entries inserted at `inserted_at`. Their keys are
  /// sha256(be64(salt) ++ be64(i)), i = 0 .. n-1, so a test can recompute
  /// them. No block is written: only the index is fed. Used by the
  /// instruction measurement, where 10^5 entries cannot come from transfers.
  public shared ({ caller }) func recents_seed(n : Nat, salt : Nat64, inserted_at : Nat64) : async () {
    onlyOwner(caller);
    let recents = icrc1().get_state().recent_transactions;
    var i = 0;
    while (i < n) {
      Map.add(recents, Blob.compare, syntheticKey(salt, Nat64.fromNat(i)), (inserted_at, 0));
      i += 1;
    };
  };

  /// Runs `cleanUpRecents` once and returns the instructions it took.
  public shared ({ caller }) func recents_measure_cleanup() : async Nat64 {
    onlyOwner(caller);
    let lib = icrc1();
    InternetComputer.countInstructions(func() { lib.cleanUpRecents() });
  };

  func syntheticKey(salt : Nat64, i : Nat64) : Blob {
    let bytes = List.empty<Nat8>();
    for (word in [salt, i].values()) {
      var shift : Nat64 = 56;
      label bytesOfWord loop {
        List.add(bytes, Nat8.fromNat(Nat64.toNat((word >> shift) & 0xff)));
        if (shift == 0) break bytesOfWord;
        shift -= 8;
      };
    };
    Sha256.fromArray(#sha256, List.toArray(bytes));
  };

};
