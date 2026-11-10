import SW "mo:stable-write-only";
import T "../migrations/types";
import ExperimentalCycles "mo:core/Cycles";
import List "mo:core/List";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import TT "mo:timer-tool";
import Prim "mo:⛔";
import Legacy = "../legacy";
import OVSFixed "mo:ovs-fixed";
import ClassPlusLib "mo:class-plus";
import Principal "mo:core/Principal";
import Inspect "../Inspect";
import HelperLib "../helper";

shared ({ caller = ledger_canister_id }) persistent actor class Archive (_args : T.Current.ArchiveInitArgs) = this {

    //==========================================================================
    // Message Inspection - Cycle Drain Protection
    //==========================================================================

    /// Inspect ingress messages before they are processed.
    /// Rejects calls with oversized unbounded arguments to prevent cycle drain attacks.
    system func inspect(
      {
        caller : Principal = _caller;
        arg : Blob;  // Raw message blob - check size FIRST
        msg : {
          #get_transactions : () -> { start : Nat; length : Nat };
          #get_blocks : () -> { start : Nat; length : Nat };
          #icrc3_get_blocks : () -> [T.Current.TransactionRange];
          #total_transactions : () -> ();
          #get_transaction : () -> T.Current.TxIndex;
          #remaining_capacity : () -> ();
          #get_stats : () -> ();
          #deposit_cycles : () -> ();
          #cycles : () -> ();
          #get_icrc85_stats : () -> ();
          #append_transactions : () -> [T.Current.Transaction];
        };
      }
    ) : Bool {
      // FIRST: Check raw arg size - cheapest check
      // For block queries: 100 ranges * ~20 bytes each = ~2KB max
      if (arg.size() > 10_000) {
        return false;
      };
      
      switch (msg) {
        case (#get_transactions(getArgs)) {
          Inspect.inspectLegacyBlocks(getArgs(), null);
        };
        case (#get_blocks(getArgs)) {
          Inspect.inspectLegacyBlocks(getArgs(), null);
        };
        case (#icrc3_get_blocks(getArgs)) {
          Inspect.inspectGetBlocks(getArgs(), null);
        };
        // No validation needed for these - bounded types
        case (#total_transactions(_)) true;
        case (#get_transaction(_)) true;
        case (#remaining_capacity(_)) true;
        case (#get_stats(_)) true;
        case (#deposit_cycles(_)) true;
        case (#cycles(_)) true;
        case (#get_icrc85_stats(_)) true;
        // Inter-canister call from ledger - caller check in function
        case (#append_transactions(_)) true;
      };
    };

    /// ICRC-85 namespace for Archive Open Value Sharing
    let ICRC85_NAMESPACE = "org.icdevs.icrc85.icrc3archive";
    let ICRC85_TIMER_NAMESPACE = "icrc85:ovs:shareaction:icrc3archive";
    let ONE_DAY = 86_400_000_000_000; // 1 day in nanoseconds
    let ONE_XDR_OF_CYCLES = 1_000_000_000_000;  // 1 XDR worth of cycles (~1T)


    transient let canisterId = Principal.fromActor(this);

    transient let debug_channel = {
      announce = false;
      append = false;
      get = false;
      icrc85 = false;
    };

    debug if(debug_channel.announce) Debug.print("new archive created with the following args" # debug_show(_args));

    type Transaction = T.Current.Transaction;
    type MemoryBlock = {
        offset : Nat64;
        size : Nat;
    };

    public type InitArgs = T.Current.ArchiveInitArgs;

    public type AddTransactionsResponse = T.Current.AddTransactionsResponse;
    public type TransactionRange = T.Current.TransactionRange;
    public type ArchiveStats = T.Current.ArchiveStats;

    // LOCAL PATCH (archive kill switch): `initial_args` is stable, so it keeps
    // the type it had before `icrc85KillSwitch` was added to the arguments
    // (adding the field to it fails `moc --stable-compatible`, M0170). The
    // switch lives in its own stable variable instead. On an upgrade from an
    // archive without it, that variable is initialised from the upgrade's
    // arguments; later upgrades keep it.
    var initial_args : {
      maxRecords : Nat;
      maxPages : Nat;
      indexType : SW.IndexType;
      firstIndex : Nat;
      icrc85Collector : ?Principal;
    } = {
      maxRecords = _args.maxRecords;
      maxPages = _args.maxPages;
      indexType = _args.indexType;
      firstIndex = _args.firstIndex;
      icrc85Collector = _args.icrc85Collector;
    };
    var icrc85_kill_switch : ?Bool = _args.icrc85KillSwitch;
    // LOCAL PATCH (archive kill switch, true wins): the initialiser above runs
    // only once, so an archive created with the switch `null` or `?false` kept
    // sharing after an upgrade that passed `?true`. This statement runs on
    // every install and upgrade: a `?true` in the arguments turns the switch
    // on, and nothing turns it off again.
    if (_args.icrc85KillSwitch == ?true) icrc85_kill_switch := ?true;
    // LOCAL PATCH (upgrade keeps bounds): read the arguments the archive was
    // created with, which `initial_args` keeps across upgrades. Upstream binds
    // `args` to `_args`, and `upgradeArchive` upgrades with placeholders
    // (`maxRecords = 0; firstIndex = 0`), so after an upgrade `get_stats` and
    // `remaining_capacity` trapped, every archive past block 0 served the wrong
    // blocks, and the archive refused all appends as full.
    transient var args = initial_args;

    var memstore = SW.init({
      //maxRecords = args.maxRecords;
      indexType = initial_args.indexType;
      maxPages = 62500;
    });

    transient let sw = SW.StableWriteOnly(?memstore);


    ///////////
    // ICRC-85 Open Value Sharing
    // Should compute to one extra XDR per 1,000,000 records stored
    ///////////

    // Configuration
    let ovsConfig : OVSFixed.InitArgs = {
        namespace = ICRC85_NAMESPACE;
        publicNamespace = ICRC85_TIMER_NAMESPACE;
        baseCycles = ONE_XDR_OF_CYCLES;
        actionDivisor = 1;
        actionMultiplier = 1_000_000;
        maxCycles = ONE_XDR_OF_CYCLES * 100;
        initialWait = ?(ONE_DAY * 7); 
        period = null; // default 30 days
        asset = null; //default Cycles
        platform = null;  //default ICP
        resetAtEndOfPeriod = false; //storage....per record
    };

    //icrc1 needs its own classmanager
    transient var org_icdevs_class_plus_manager = ClassPlusLib.ClassPlusInitializationManager<system>(ledger_canister_id, canisterId, true);

    var org_icdevs_timer_tool_state = TT.initialState();
    
    // Build timerTool environment with collector if provided
    func getTimerToolEnv() : TT.Environment {
      {
        advanced = ?{
          icrc85 = ?{
            kill_switch = icrc85_kill_switch; // LOCAL PATCH (archive kill switch): was `null`
            handler = null;
            period = null;  // default 30 days
            initialWait = ?(ONE_DAY * 7);  // 7 day grace period
            asset = null;   // default cycles
            platform = null; // default ICP
            tree = null;
            collector = args.icrc85Collector;  // Use the collector passed to archive
          };
        };
        syncUnsafe = null;
        reportExecution = null;
        reportError = null;
        reportBatch = null;
      }
    };
          
    transient var org_icdevs_timer_tool = TT.Init({
      org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
      initialState = org_icdevs_timer_tool_state;
      args = null;
      pullEnvironment = ?getTimerToolEnv;
      onInitialize = null;
      onStorageChange = func(state: TT.State) {
        org_icdevs_timer_tool_state := state;
      }
    });


    func getOVSEnv() : OVSFixed.Environment {
      {
          var org_icdevs_timer_tool = ?org_icdevs_timer_tool();
          var collector = args.icrc85Collector;
          // LOCAL PATCH (archive kill switch): was `advanced = null`
          advanced = ?{ kill_switch = icrc85_kill_switch; handler = null; tree = null };
      }
    };

          
    var org_icdevs_ovs_fixed_state = OVSFixed.initialState();

    transient var _ovs = OVSFixed.Init({
        org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
        args = ?ovsConfig;
        pullEnvironment = ?getOVSEnv;
        onInitialize = null;
        initialState = org_icdevs_ovs_fixed_state;
        onStorageChange = func(_state : OVSFixed.State){
          org_icdevs_ovs_fixed_state := _state;
        };
    });

    // =====================================
    // Main Archive Functions
    // =====================================

    public shared ({ caller }) func append_transactions(txs : [Transaction]) : async AddTransactionsResponse {

      debug if(debug_channel.append) Debug.print("adding transactions to archive" # debug_show(txs));

      if (caller != ledger_canister_id) {
          return #err("Unauthorized Access: Only the ledger canister can access this archive canister");
      };

      var recordsAdded = 0;
      label addrecs for(thisItem in txs.vals()){
        let stats = sw.stats();
        if(stats.itemCount >= args.maxRecords){
          debug if(debug_channel.append) Debug.print("braking add recs");
          break addrecs;
        };
        ignore sw.write(to_candid(thisItem));
        recordsAdded += 1;
      };

      // ICRC-85: Track records added for cycle sharing
      org_icdevs_ovs_fixed_state.activeActions +=  recordsAdded;

      let final_stats = sw.stats();
      if(final_stats.itemCount >= args.maxRecords){
        return #Full(final_stats);
      };
      #ok(final_stats);
    };

    func total_txs() : Nat {
        sw.stats().itemCount;
    };

    public shared query func total_transactions() : async Nat {
        total_txs();
    };

    public shared query func get_transaction(tx_index : T.Current.TxIndex) : async ?Transaction {
        return _get_transaction(tx_index);
    };

    public shared query func get_transactions(args: {start : Nat; length: Nat}) : async {
      transactions : [Legacy.Transaction];
    } {
        // Guard for inter-canister calls
        Inspect.guardLegacyBlocks(args, null);
        
        if(args.length > 100000) {
            Runtime.trap("You cannot request more than 100000 transactions at once");
        };
        let results = List.empty<Legacy.Transaction>();
        if(args.length == 0) return { transactions = [] };
        for(thisItem in HelperLib.range(args.start, args.start + args.length - 1)){
            switch(_get_transaction(thisItem)){
                case(null){
                    //should be unreachable...do we return an error?
                };
                case(?val){
                    let items = Legacy.convertICRC3ToLegacyTransaction([val]);
                    if(items.size() == 0){
                        List.add(results,{
                          burn = null;
                          kind = "not_found";
                          mint = null;
                          approve = null;
                          timestamp = 0;
                          transfer = null;
                        } : Legacy.Transaction)
                    } else {
                        for (item in items.vals()) {
                            List.add(results, item);
                        };
                    };
                };
            };
        };
        return {
          transactions = List.toArray(results);
        };
    };

    // Legacy get_blocks for Rosetta compatibility
    // Rosetta's icrc-ledger-agent calls this method on archive canisters
    // Returns blocks in the format expected by BlockRange: { blocks: [Value] }
    public shared query func get_blocks(args: {start : Nat; length: Nat}) : async {
      blocks : [Transaction];
    } {
        // Guard for inter-canister calls
        Inspect.guardLegacyBlocks(args, null);
        
        if(args.length > 100000) {
            Runtime.trap("You cannot request more than 100000 blocks at once");
        };
        let results = List.empty<Transaction>();
        if(args.length == 0) return { blocks = [] };
        for(thisItem in HelperLib.range(args.start, args.start + args.length - 1)){
            switch(_get_transaction(thisItem)){
                case(null){
                    // Block not found - skip
                };
                case(?val){
                    List.add(results, val);
                };
            };
        };
        return {
          blocks = List.toArray(results);
        };
    };

    private func _get_transaction(tx_index : T.Current.TxIndex) : ?Transaction {
        let stats = sw.stats();
        debug if(debug_channel.get) Debug.print("getting transaction" # debug_show(tx_index, args.firstIndex, stats));
       
        let target_index =  if(tx_index >= args.firstIndex) Nat.sub(tx_index, args.firstIndex) else Runtime.trap("Not on this canister requested " # Nat.toText(tx_index) # "first index: " # Nat.toText(args.firstIndex));
        debug if(debug_channel.get) Debug.print("target" # debug_show(target_index));
        if(target_index >= stats.itemCount) Runtime.trap("requested an item outside of this archive canister. first index: " # Nat.toText(args.firstIndex) # " last item" # Nat.toText(args.firstIndex + stats.itemCount - 1));
        debug if(debug_channel.get) Debug.print("target" # debug_show(target_index));
        let ?blob = sw.read(target_index) else return null;
        let t = from_candid(blob) : ?Transaction;
        return t;
    };

    public shared query func icrc3_get_blocks(req : [T.Current.TransactionRange]) : async T.Current.GetTransactionsResult {
      // Guard for inter-canister calls
      Inspect.guardGetBlocks(req, null);

      debug if(debug_channel.get) Debug.print("request for archive blocks " # debug_show(req));

      let transactions = List.empty<{id:Nat; block: Transaction}>();
      for(thisArg in req.vals()){
        // Skip if length is 0 - no blocks to retrieve
        if(thisArg.length != 0) {
          // Calculate the end index (exclusive)
          let endIndex = thisArg.start + thisArg.length;
          if (thisArg.length > 0) {
            for(thisItem in HelperLib.range(thisArg.start, endIndex - 1)){
              debug if(debug_channel.get) Debug.print("getting" # debug_show(thisItem));
              switch(_get_transaction(thisItem)){
                case(null){
                  //should be unreachable...do we return an error?
                };
                case(?val){
                  debug if(debug_channel.get) Debug.print("found" # debug_show(val));
                  List.add(transactions, {id = thisItem; block = val}); // Use thisItem directly as the ID
                };
              };
            };
          };
        };
      };

      return { 
          blocks = List.toArray(transactions);
          archived_blocks = [];
          log_length =  0;
        };
    };

    public shared query func remaining_capacity() : async Nat {
        args.maxRecords - sw.stats().itemCount;
    };

    /// Get comprehensive statistics about this archive canister
    public shared query func get_stats() : async ArchiveStats {
        let stats = sw.stats();
        let totalRecords = stats.itemCount;
        // Calculate stable memory from region stats instead of deprecated Prim.stableMemorySize()
        let indexPages = switch(stats.memory.pages) {
          case(?p) Nat64.toNat(p);
          case(null) 0;
        };
        let dataPages = Nat64.toNat(stats.currentPages);
        {
          total_records = totalRecords;
          first_block_index = args.firstIndex;
          last_block_index = if (totalRecords > 0) { args.firstIndex + totalRecords - 1 } else { args.firstIndex };
          max_records = args.maxRecords;
          remaining_capacity = args.maxRecords - totalRecords;
          cycles_balance = ExperimentalCycles.balance();
          heap_memory = Prim.rts_heap_size();
          stable_memory_pages = dataPages + indexPages;
          ledger_canister = ledger_canister_id;
        };
    };

    /// Deposit cycles into this archive canister.
    public shared func deposit_cycles() : async () {
        let amount = ExperimentalCycles.available();
        let accepted = ExperimentalCycles.accept<system>(amount);
        assert (accepted == amount);
    };

    /// Get the remaining cycles on the server
    public query func cycles() : async Nat {
        ExperimentalCycles.balance();
    };

    ///////////
    // ICRC-85 Public Endpoints
    ///////////

    /// Get ICRC-85 statistics for the archive
    public query func get_icrc85_stats() : async {
      activeActions: Nat;
      lastActionReported: ?Nat;
      nextCycleActionId: ?Nat;
    } {
      {
        activeActions = org_icdevs_ovs_fixed_state.activeActions;
        lastActionReported = org_icdevs_ovs_fixed_state.lastActionReported;
        nextCycleActionId = org_icdevs_ovs_fixed_state.nextCycleActionId;
      };
    };

};