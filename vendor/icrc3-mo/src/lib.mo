///////////////////////////////////////////////////////////////////////////////////////////
/// Base Library for ICRC-3 Standards
///
/// This library includes the necessary functions, types, and classes to build an ICRC-3 standard transactionlog. It provides an implementation of the
/// ICRC3 class which manages the transaction ledger, archives, and certificate store.
///
///
///////////////////////////////////////////////////////////////////////////////////////////

import MigrationTypes "./migrations/types";
import Migration "./migrations";
import Archive "/archive/";

import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import CertifiedData "mo:core/CertifiedData";
import Error "mo:core/Error";
import ExperimentalCycles "mo:core/Cycles";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Timer "mo:core/Timer";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Runtime "mo:core/Runtime";
import List "mo:core/List";
import Map "mo:core/Map";
import Set "mo:core/Set";
import RepIndy "mo:rep-indy-hash";
import HelperLib "helper";
import OVSFixed "mo:ovs-fixed";
import TT "mo:timer-tool";

import MTree "mo:ic-certification/MerkleTree";
import Service "service";
import ClassPlusLib "mo:class-plus";
import LegacyLib "legacy";
import LEB128 "mo:leb128";

module {

  public let ONE_DAY = 86_400_000_000_000; // 1 day in nanoseconds
  public let ONE_XDR_OF_CYCLES = 1_000_000_000_000;  // 1 XDR worth of cycles (~1T)
  public let ICRC85_NAMESPACE = "org.icdevs.icrc85.icrc3";
  public let ICRC85_TIMER_NAMESPACE = "icrc85:ovs:shareaction:icrc3";

  /// Debug channel configuration
  ///
  /// The debug_channel object is used to enable/disable different debugging
  /// messages during runtime.
  let debug_channel = {
    add_record = false;
    certificate = false;
    clean_up = false;
    get_transactions = false;
    icrc85 = false;
  };

  /// Represents the current state of the migration
  public type CurrentState = MigrationTypes.Current.State;
  public type InitArgs = MigrationTypes.Args;

  // Export core library modules for external use
  public let CoreMap = Map;
  public let CoreSet = Set;
  public let CoreList = List;

  /// Compare function for Principal keys in maps
  public let principal_compare = MigrationTypes.Current.principal_compare;

  /// Re-export ICRC-85 types for consumers
  public type ICRC85State = MigrationTypes.Current.ICRC85State;
  public type ICRC85Environment = MigrationTypes.Current.ICRC85Environment;
  public type TimerTool = MigrationTypes.Current.TimerTool;

  /// Represents a transaction
  public type Transaction = MigrationTypes.Current.Transaction;
  public type BlockType = MigrationTypes.Current.BlockType;
  public type Value = MigrationTypes.Current.Value;
  public type State = MigrationTypes.State;
  public type Stats = MigrationTypes.Current.Stats;
  public type Environment = MigrationTypes.Current.Environment;
  public type TransactionRange = MigrationTypes.Current.TransactionRange;
  public type GetTransactionsResult = MigrationTypes.Current.GetTransactionsResult;
  
  /// Listener type for record added events
  public type RecordAddedListener = MigrationTypes.Current.RecordAddedListener;
  public type DataCertificate = MigrationTypes.Current.DataCertificate;
  public type Tip = MigrationTypes.Current.Tip;
  public type GetArchivesArgs = MigrationTypes.Current.GetArchivesArgs;
  public type GetArchivesResult = MigrationTypes.Current.GetArchivesResult;
  public type GetArchivesResultItem = MigrationTypes.Current.GetArchivesResultItem;

  public type GetBlocksArgs = MigrationTypes.Current.GetBlocksArgs;
  public type GetBlocksResult = MigrationTypes.Current.GetBlocksResult;

  public type UpdateSetting = MigrationTypes.Current.UpdateSetting;

  /// Represents the IC actor
  public type IC = MigrationTypes.Current.IC;

  public let CertTree = MigrationTypes.Current.CertTree;




  /// Initializes the initial state
  ///
  /// Returns the initial state of the migration.
  public func initialState() : State {#v0_0_0(#data)};

  /// Returns the current state version
  public let currentStateVersion = #v0_2_0(#id);

  /// Initializes the migration
  ///
  /// This function is used to initialize the migration with the provided stored state.
  ///
  /// Arguments:
  /// - `stored`: The stored state of the migration (nullable)
  /// - `canister`: The canister ID of the migration
  /// - `environment`: The environment object containing optional callbacks and functions
  ///
  /// Returns:
  /// - The current state of the migration
  public let init = Migration.migrate;

  /// Helper library for common functions
  public let helper = HelperLib;
  public let Legacy = LegacyLib;
  public type Service = Service.Service;

  /// Type for Init function arguments
  public type InitFunctionArgs = {
    org_icdevs_class_plus_manager: ClassPlusLib.ClassPlusInitializationManager;
    initialState: State;
    args : ?InitArgs;
    pullEnvironment : ?(() -> Environment);
    onInitialize: ?(ICRC3 -> async*());
    onStorageChange : ((State) ->());
  };

  /// Type for Mixin function arguments (subset of InitFunctionArgs without initialState/onStorageChange)
  public type MixinFunctionArgs = {
    org_icdevs_class_plus_manager: ClassPlusLib.ClassPlusInitializationManager;
    args : ?InitArgs;
    pullEnvironment : ?(() -> Environment);
    onInitialize: ?(ICRC3 -> async*());
  };

  /// Creates default mixin args with all optional fields set to null.
  /// Use with Motoko's `with` syntax to override specific fields.
  ///
  /// Example:
  /// ```motoko
  /// include ICRC3Mixin.mixin({
  ///   ICRC3.defaultMixinArgs(org_icdevs_class_plus_manager) with
  ///   pullEnvironment = ?get_icrc3_environment;
  ///   args = ?icrc3_args;
  /// });
  /// ```
  public func defaultMixinArgs(manager: ClassPlusLib.ClassPlusInitializationManager) : MixinFunctionArgs {
    {
      org_icdevs_class_plus_manager = manager;
      args = null;
      pullEnvironment = null;
      onInitialize = null;
    };
  };

  public func Init(config : InitFunctionArgs) : ()-> ICRC3{
    
    switch(config.pullEnvironment){
      case(?_val) {
        
      };
      case(null) {
        debug if(debug_channel.icrc85) Debug.print("pull environment is null");
      };
    };  

    let wrappedOnInitialize = func (instance: ICRC3) : async* () {
      ///////////
      // ICRC-85 Open Value Sharing
      ///////////

      // Configuration
      let ovsConfig : OVSFixed.InitArgs = {
          namespace = ICRC85_NAMESPACE;
          publicNamespace = ICRC85_TIMER_NAMESPACE;
          baseCycles = ONE_XDR_OF_CYCLES;
          actionDivisor = 1;
          actionMultiplier = 100_000_000;
          maxCycles = ONE_XDR_OF_CYCLES * 100;
          initialWait = ?(ONE_DAY * 7); 
          period = null; // default 30 days
          asset = null; //default Cycles
          platform = null;  //default ICP
          resetAtEndOfPeriod = true;
      };

      //icrc3 needs its own classmanager
      var org_icdevs_class_plus_manager = ClassPlusLib.ClassPlusInitializationManager<system>(instance.caller, instance.canister, true);

      instance.org_icdevs_class_plus_manager := ?org_icdevs_class_plus_manager;


      func getOVSEnv() : OVSFixed.Environment {
        {
            var org_icdevs_timer_tool = instance.environment.org_icdevs_timer_tool;

            var collector = do?{instance.environment.advanced!.icrc85!.collector!};
            advanced = do?{instance.environment.advanced!.icrc85!.advanced!};
        }
      };

      instance.org_icdevs_ovs_fixed := ?OVSFixed.Init({
          org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
          args = ?ovsConfig;
          pullEnvironment = ?getOVSEnv;
          onInitialize = null;
          initialState = instance.state.org_icdevs_ovs_fixed_state;
          onStorageChange = func(_state : OVSFixed.State){
            instance.state.org_icdevs_ovs_fixed_state := _state;
          };
      });

      //make sure metadata is good to go.
      ignore instance.get_stats();

      switch(config.onInitialize){
          case(?cb) await* cb(instance);
          case(null) {};
      };
    };

    ClassPlusLib.ClassPlus<
      ICRC3, 
      State,
      InitArgs,
      Environment>({config with 
        constructor = ICRC3;
        onInitialize = ?wrappedOnInitialize
      }).get;
  };

  


  /// The ICRC3 class manages the transaction ledger, archives, and certificate store.
  ///
  /// The ICRC3 class provides functions for adding a record to the ledger, getting
  /// archives, getting the certificate, and more.
  public class ICRC3(stored: ?State, _caller: Principal, _canister: Principal, args: ?InitArgs, environment_passed: ?Environment, storageChanged: (State) -> ()){

    public let caller = _caller;
    public let canister = _canister;
    public let environment = switch(environment_passed){
      case(null) Runtime.trap("No Environment Provided");
      case(?val) val;
    };

    /// Listener for record added events
    private let record_added_listeners = List.empty<(Text, RecordAddedListener)>();

    /// The current state of the migration
    public var state : CurrentState = do {
      let #v0_2_0(#data(foundState)) = init(
        switch(stored){
          case(null) initialState();
          case(?val) val;
        }, currentStateVersion, args, caller, canister) else Runtime.trap("ICRC3 Not in final state after migration - " # debug_show(currentStateVersion));
      foundState;
    };

    storageChanged(#v0_2_0(#data(state)));

    /// The migrate function
    public let migrate = Migration.migrate;

    /// The IC actor used for updating archive controllers
    private let ic : IC = actor "aaaaa-aa";

    /// Encodes a number as unsigned LEB128 bytes (ICRC-3 compliant)
    ///
    /// LEB128 (Little Endian Base 128) encoding is used to represent 
    /// arbitrarily large unsigned integers in a variable number of bytes.
    /// Required by ICRC-3 specification for `last_block_index` in certificate tree.
    ///
    /// Uses the mo:leb128 library for encoding.
    ///
    /// Arguments:
    /// - `nat`: The number to encode
    ///
    /// Returns:
    /// - The LEB128 encoded bytes
    func encodeLEB128(nat: Nat): Blob {
      Blob.fromArray(LEB128.toUnsignedBytes(nat));
    };

    

    /// Adds a record to the transaction ledger
    ///
    /// This function adds a new record to the transaction ledger.
    ///
    /// Arguments:
    /// - `new_record`: The new record to add
    /// - `top_level`: The top level value (nullable)
    ///
    /// Returns:
    /// - The index of the new record
    ///
    /// Throws:
    /// - An error if the `op` field is missing from the transaction
    public func add_record<system>(new_record: Transaction, top_level: ?Value) : Nat {

      //validate that the trx has an op field according to ICRC3

      debug if(debug_channel.add_record) Debug.print("adding a record" # debug_show(new_record));

      let current_size = List.size(state.ledger);

      debug if(debug_channel.add_record) Debug.print("current_size" # debug_show(current_size));
      

      let last_rec : ?Transaction = if(current_size == 0){
        null;
      } else {
        List.get<Transaction>(state.ledger, current_size - 1);
      };

      debug if(debug_channel.add_record) Debug.print("last_rec" # debug_show(last_rec));

      let trx = List.empty<(Text, Transaction)>();

      //add a phash in accordance with ICRC3 for records > idx 0
      switch(state.latest_hash){
        case(null) {};
        case(?val){
          List.add(trx, ("phash", #Blob(val)));
        };
      };

      List.add(trx,("tx", new_record));

      switch(top_level){
        case(?top_level){
          switch(top_level){
            case(#Map(items)){
              for(thisItem in items.vals()){
                List.add(trx,(thisItem.0, thisItem.1));
              };
            };
            case(_){};
          }
        };
        case(null){};
      };

      debug if(debug_channel.add_record) Debug.print("full tx" # debug_show(List.toArray(trx)));

      let thisTrx = #Map(List.toArray(trx));

      //calculate and set the certifiable hash of the tip of the ledger
      state.latest_hash := ?Blob.fromArray(RepIndy.hash_val(thisTrx));

      List.add(state.ledger, thisTrx);

      if(state.lastIndex == 0) {
        state.lastIndex :=  List.size(state.ledger) - 1;
      } else state.lastIndex += 1;

      //set a timer to clean up
      if(List.size(state.ledger) > state.constants.archiveProperties.maxActiveRecords){
        switch(state.cleaningTimer){
          case(null){ //only need one active timer
            debug if(debug_channel.add_record) Debug.print("setting clean up timer");
            state.cleaningTimer := ?Timer.setTimer<system>(#seconds(0), check_clean_up);
          };
          case(_){}
        };
      };

      debug if(debug_channel.add_record) Debug.print("about to certify " # debug_show(state.latest_hash));

      //certify the new record if the cert store is provided


            switch(environment.get_certificate_store, state.latest_hash){
        
        case(?gcs, ?latest_hash){
          debug if(debug_channel.add_record) Debug.print("have store" # debug_show(gcs()));
          let ct = CertTree.Ops(gcs());
          ct.put([Text.encodeUtf8("last_block_index")], encodeLEB128(state.lastIndex));
          ct.put([Text.encodeUtf8("last_block_hash")], latest_hash);
          ct.setCertifiedData();
        };
        case(_){};
      };
      
      switch(do?{environment.advanced!.updated_certification!}, state.latest_hash){
        
        case(?uc, ?latest_hash){
          debug if(debug_channel.add_record) Debug.print("have cert update");
          ignore uc(latest_hash, state.lastIndex);
        };
        case(_){};
      };

      // Notify all registered listeners about the new record
      for(listener in List.values(record_added_listeners)){
        listener.1<system>(thisTrx, state.lastIndex);
      };

      // ICRC-85: Track successful record addition for cycle sharing
      state.org_icdevs_ovs_fixed_state.activeActions += 1;

      return state.lastIndex;
    };

    /// Returns the archive index for the ledger
    ///
    /// This function returns the archive index for the ledger.
    ///
    /// Arguments:
    /// - `request`: The archive request
    ///
    /// Returns:
    /// - The archive index
    public func get_archives(request: Service.GetArchivesArgs) : Service.GetArchivesResult {
      let results = List.empty<GetArchivesResultItem>();
       
      var bFound = switch(request.from){
        case(null) true;
        case(?_val) false;
      };
      if(bFound == true){
          List.add(results,{
            canister_id = canister;
            start = state.firstIndex;
            end = state.lastIndex;
          });
        } else {
          switch(request.from){
            case(null) {}; //unreachable
            case(?val) {
              if(canister == val){
                bFound := true;
              };
            };
          };
        };

      for(thisItem in Map.entries<Principal, TransactionRange>(state.archives)){
        if(bFound == true){
          if(thisItem.1.start + thisItem.1.length >= 1){
            List.add(results,{
              canister_id = thisItem.0;
              start = thisItem.1.start;
              end = Nat.sub(thisItem.1.start + thisItem.1.length, 1);
            });
          } else{
            Runtime.trap("found archive with length of 0");
          };
        } else {
          switch(request.from){
            case(null) {}; //unreachable
            case(?val) {
              if(thisItem.0 == val){
                bFound := true;
              };
            };
          };
        };
      };

      return List.toArray(results);
    };

    /// Returns the certificate for the ledger
    ///
    /// This function returns the certificate for the ledger.
    ///
    /// Returns:
    /// - The data certificate (nullable)
    public func get_tip_certificate() : ?Service.DataCertificate{
      debug if(debug_channel.certificate) Debug.print("in get tip certificate");
     
      debug if(debug_channel.certificate) Debug.print("have env");
      switch(environment.get_certificate_store){
        case(null){};
        case(?gcs){
          debug if(debug_channel.certificate) Debug.print("have gcs");
          let ct = CertTree.Ops(gcs());
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - treeHash: " # debug_show(ct.treeHash()));
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - tree structure: " # debug_show(MTree.structure(gcs().tree)));
          let blockWitness = ct.reveal([Text.encodeUtf8("last_block_index")]);
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - blockWitness: " # debug_show(blockWitness));
          let hashWitness = ct.reveal([Text.encodeUtf8("last_block_hash")]);
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - hashWitness: " # debug_show(hashWitness));
          let merge = MTree.merge(blockWitness,hashWitness);
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - merge: " # debug_show(merge));
          debug if(debug_channel.certificate) Debug.print("get_tip_certificate - reconstruct(merge): " # debug_show(MTree.reconstruct(merge)));
          
          let witness = ct.encodeWitness(merge);
          return ?{
            certificate = switch(CertifiedData.getCertificate()){
              case(null){
                debug if(debug_channel.certificate) Debug.print("certified returned null");
                return null;
              };

              case(?val) val;
            };
            hash_tree = witness;
          };
        };
      };

      return null;
    };

    /// Returns the latest hash and lastest index along with a witness
    ///
    /// This function returns the latest hash, latest index, and the witness for the ledger.
    ///
    /// Returns:
    /// - The tip information
    public func get_tip() : Tip {
      debug if(debug_channel.certificate) Debug.print("in get tip certificate");
            debug if(debug_channel.certificate) Debug.print("have env");
      switch(environment.get_certificate_store){
        case(null){Runtime.trap("No certificate store provided")};
        case(?gcs){
          debug if(debug_channel.certificate) Debug.print("have gcs");
          let ct = CertTree.Ops(gcs());
          let blockWitness = ct.reveal([Text.encodeUtf8("last_block_index")]);
          let hashWitness = ct.reveal([Text.encodeUtf8("last_block_hash")]);
          let merge = MTree.merge(blockWitness,hashWitness);
          let witness = ct.encodeWitness(merge);
          return {
            last_block_hash = switch(state.latest_hash){
              case(null) Runtime.trap("No root");
              case(?val) val;
            };
            last_block_index = encodeLEB128(state.lastIndex);
            hash_tree = witness;

          };
        };
      };
    };


    /// Updates the controllers for the given canister
    ///
    /// This function updates the controllers for the given canister.
    ///
    /// Arguments:
    /// - `canisterId`: The canister ID
    private func update_controllers(canisterId : Principal) : async (){
      switch(state.constants.archiveProperties.archiveControllers){
        case(?val){
          // LOCAL PATCH (controllers at archive creation): add the environment's
          // `get_archive_controllers`, read now, to the set. Without the hook the
          // set is the upstream one.
          let extra : [Principal] = switch(do?{environment.advanced!.get_archive_controllers!}){
            case(?get) get();
            case(null) [];
          };
          let final_list = switch(val){
            case(?list){
              let a_set = Set.fromIter<Principal>(list.vals(), Principal.compare);
              Set.add(a_set, Principal.compare, canister);
              for(p in extra.vals()) Set.add(a_set, Principal.compare, p);
              ?Set.toArray(a_set);
            };
            case(null){
              let a_set = Set.fromIter<Principal>(extra.vals(), Principal.compare);
              Set.add(a_set, Principal.compare, canister);
              ?Set.toArray(a_set);
            };
          };
          ignore ic.update_settings(({canister_id = canisterId; settings = {
                    controllers = final_list;
                    freezing_threshold = null;
                    memory_allocation = null;
                    compute_allocation = null;
          }}));
        };
        case(_){};    
      };

      return;
    };

    /// Updates the controllers for the given canister
    ///
    /// This function updates the controllers for the given canister.
    ///
    /// Arguments:
    /// - `canisterId`: The canister ID
    public func update_supported_blocks(supported_blocks : [BlockType]) : () {
      List.clear(state.supportedBlocks);
      List.addAll(state.supportedBlocks, supported_blocks.vals());
      return;
    };

 
    public func update_settings(settings : [UpdateSetting]) : [Bool]{

    let results = List.empty<Bool>();
     for(setting in settings.vals()){
          List.add(results, switch(setting) {
            case(#maxActiveRecords(maxActiveRecords)){
              state.constants.archiveProperties.maxActiveRecords := maxActiveRecords;
              true;
            };
            case(#settleToRecords(settleToRecords)){
              state.constants.archiveProperties.settleToRecords := settleToRecords;
              true;
            };
            case(#maxRecordsInArchiveInstance(maxRecordsInArchiveInstance)){
              state.constants.archiveProperties.maxRecordsInArchiveInstance := maxRecordsInArchiveInstance;
              true;
            };
            case(#maxRecordsToArchive(maxRecordsToArchive)){
              state.constants.archiveProperties.maxRecordsToArchive := maxRecordsToArchive;
              true;
            };
            case(#maxArchivePages(maxArchivePages)){
              state.constants.archiveProperties.maxArchivePages := maxArchivePages;
              true;
            };
            case(#archiveIndexType(archiveIndexType)){
              state.constants.archiveProperties.archiveIndexType := archiveIndexType;
              true;
            };
            case(#archiveCycles(archiveCycles)){
              state.constants.archiveProperties.archiveCycles := archiveCycles;
              true;
            };
            case(#archiveControllers(archiveControllers)){
              state.constants.archiveProperties.archiveControllers := archiveControllers;
              true;
            };
          });
        };
      return List.toArray(results);
    };



    /// Runs the clean up process to move records to archive canisters
    ///
    /// This function runs the clean up process to move records to archive canisters.
    public func check_clean_up<system>() : async (){

      //clear the timer
      state.cleaningTimer := null;

      // LOCAL PATCH (cleaningTimer committed before archiving): a trap before
      // the first await below (sending the archive's cycles when the ledger
      // is close to its freezing threshold) rolled back the line above, so
      // `add_record` never armed the timer again. This await commits the
      // null on its own; the guard and `bCleaning := true` stay after it, in
      // one message.
      await async {};

      debug if(debug_channel.clean_up) Debug.print("Checking clean up" # debug_show(stats()));

      //ensure only one cleaning job is running
      if(state.bCleaning) return; //only one cleaning at a time;
      debug if(debug_channel.clean_up) Debug.print("Not currently Cleaning");

      //don't clean if not necessary
      if(List.size(state.ledger) < state.constants.archiveProperties.maxActiveRecords) return;

      state.bCleaning := true;

      debug if(debug_channel.clean_up) Debug.print("Now we are cleaning");

      let (archive_detail, available_capacity) = if(Map.size(state.archives) == 0){
        //no archive exists - create a new canister
        //add cycles;
        debug if(debug_channel.clean_up) Debug.print("Creating a canister");

        let cyclesToUse = if(ExperimentalCycles.balance() > state.constants.archiveProperties.archiveCycles * 2){
          state.constants.archiveProperties.archiveCycles;
        } else{
          //warning ledger will eventually overload
          debug if(debug_channel.clean_up) Debug.print("Not enough cycles" # debug_show(ExperimentalCycles.balance() ));
            state.bCleaning :=false;
          return;
        };

        //commits state and creates archive
        let newArchive =  await (with cycles = cyclesToUse) Archive.Archive({
          maxRecords = state.constants.archiveProperties.maxRecordsInArchiveInstance;
          indexType = #Stable;
          maxPages = state.constants.archiveProperties.maxArchivePages;
          firstIndex = 0;
          icrc85Collector = do?{environment.advanced!.icrc85!.collector!};
          icrc85KillSwitch = do?{environment.advanced!.icrc85!.advanced!.kill_switch!}; // LOCAL PATCH (archive kill switch)
        });
        //set archive controllers calls async
        ignore update_controllers(Principal.fromActor(newArchive));

        let newItem = {
          start = 0;
          length = 0;
        };

        debug if(debug_channel.clean_up) Debug.print("Have an archive");

        Map.add<Principal, TransactionRange>(state.archives, principal_compare, Principal.fromActor(newArchive),newItem);

        ((Principal.fromActor(newArchive), newItem), state.constants.archiveProperties.maxRecordsInArchiveInstance);
      } else{
        //check that the last one isn't full;
        debug if(debug_channel.clean_up) Debug.print("Checking old archive");
        let lastArchive = switch(Map.maxEntry(state.archives)){
          case(null) {Runtime.trap("unreachable")}; //unreachable;
          case(?val) val;
        };
        
        if(lastArchive.1.length >= state.constants.archiveProperties.maxRecordsInArchiveInstance){
          //this one is full, create a new archive
          debug if(debug_channel.clean_up) Debug.print("Need a new canister");
          let cyclesToUse = if(ExperimentalCycles.balance() > state.constants.archiveProperties.archiveCycles * 2){
            state.constants.archiveProperties.archiveCycles;
          } else{
            //warning ledger will eventually overload
            state.bCleaning :=false;
            return;
          };

          let newArchive = await(with cycles = cyclesToUse) Archive.Archive({
            maxRecords = state.constants.archiveProperties.maxRecordsInArchiveInstance;
            indexType = #Stable;
            maxPages = state.constants.archiveProperties.maxArchivePages;
            firstIndex = lastArchive.1.start + lastArchive.1.length;
            icrc85Collector = do?{environment.advanced!.icrc85!.collector!};
            icrc85KillSwitch = do?{environment.advanced!.icrc85!.advanced!.kill_switch!}; // LOCAL PATCH (archive kill switch)
          });

          // LOCAL PATCH (controllers at archive creation): upstream sets the
          // controllers of the first archive only.
          ignore update_controllers(Principal.fromActor(newArchive));

          debug if(debug_channel.clean_up) Debug.print("Have a multi archive");
          let newItem = {
            start = state.firstIndex;
            length = 0;
          };
          Map.add(state.archives, principal_compare, Principal.fromActor(newArchive), newItem);
          ((Principal.fromActor(newArchive), newItem), state.constants.archiveProperties.maxRecordsInArchiveInstance);
        } else {
          debug if(debug_channel.clean_up) Debug.print("just giving stats");
          
          let capacity = if(state.constants.archiveProperties.maxRecordsInArchiveInstance >= lastArchive.1.length){
            Nat.sub(state.constants.archiveProperties.maxRecordsInArchiveInstance,  lastArchive.1.length);
          } else {
            Runtime.trap("max archive length must be larger than the last archive length");
          };

          (lastArchive, capacity);
        };
      };

      let archive = actor(Principal.toText(archive_detail.0)) : MigrationTypes.Current.ArchiveInterface;

      var archive_amount = if(List.size(state.ledger) > state.constants.archiveProperties.settleToRecords){
        Nat.sub(List.size(state.ledger), state.constants.archiveProperties.settleToRecords)
      } else {
        Runtime.trap("Settle to records must be equal or smaller than the size of the ledger upon cleanup");
      };

      debug if(debug_channel.clean_up) Debug.print("amount to archive is " # debug_show(archive_amount));

      var bRecallAtEnd = false;

      if(archive_amount > available_capacity){
        bRecallAtEnd := true;
        archive_amount := available_capacity;
      };

      if(archive_amount > state.constants.archiveProperties.maxRecordsToArchive){
        bRecallAtEnd := true;
        archive_amount := state.constants.archiveProperties.maxRecordsToArchive;
      };

      debug if(debug_channel.clean_up) Debug.print("amount to archive updated to " # debug_show(archive_amount));

      let toArchive = List.empty<Transaction>();
      label find for(thisItem in List.values(state.ledger)){
        List.add(toArchive, thisItem);
        if(List.size(toArchive) == archive_amount) break find;
      };

      debug if(debug_channel.clean_up) Debug.print("tArchive size " # debug_show(List.size(toArchive)));

      try{
        let result = await archive.append_transactions(List.toArray(toArchive));
        let stats = switch(result){
          case(#ok(stats)) stats;
          case(#Full(stats)) stats;
          case(#err(_)){
            //do nothing...it failed;
            state.bCleaning :=false;
            return;
          };
        };

        let new_ledger = List.empty<Transaction>();
        var tracker = 0;
        let archivedAmount = List.size(toArchive);
        for(thisItem in List.values(state.ledger)){
          if(tracker >= archivedAmount){
            List.add(new_ledger, thisItem)
          };
          tracker += 1;
        };
        state.firstIndex := state.firstIndex + archivedAmount;
        state.ledger := new_ledger;
        debug if(debug_channel.clean_up) Debug.print("new ledger size " # debug_show(List.size(state.ledger)));
        Map.add(state.archives, principal_compare, Principal.fromActor(archive),{
          start = archive_detail.1.start;
          length = archive_detail.1.length + archivedAmount;
        })
      } catch (e){
        //archiving failed — log the error but keep records in memory
        debug if(debug_channel.clean_up) Debug.print("check_clean_up: archiving failed: " # Error.message(e));
        state.bCleaning :=false;
        return;
      };

      state.bCleaning :=false;

      if(bRecallAtEnd){
        state.cleaningTimer := ?Timer.setTimer<system>(#seconds(0), check_clean_up);
      };

      debug if(debug_channel.clean_up) Debug.print("Checking clean up" # debug_show(stats()));
      return;
    };

    /// Returns the statistics of the migration
    ///
    /// This function returns the statistics of the migration.
    ///
    /// Returns:
    /// - The migration statistics
    public func get_stats() : Stats {
      return {
        localLedgerSize = List.size(state.ledger);
        lastIndex = state.lastIndex;
        firstIndex = state.firstIndex;
        archives = Iter.toArray(Map.entries<Principal, TransactionRange>(state.archives));
        ledgerCanister = canister;
        supportedBlocks = Iter.toArray<BlockType>(List.values(state.supportedBlocks));
        bCleaning = state.bCleaning;
        constants = {
          archiveProperties = {
            maxActiveRecords = state.constants.archiveProperties.maxActiveRecords;
            settleToRecords = state.constants.archiveProperties.settleToRecords;
            maxRecordsInArchiveInstance = state.constants.archiveProperties.maxRecordsInArchiveInstance;
            maxRecordsToArchive = state.constants.archiveProperties.maxRecordsToArchive;
            archiveCycles = state.constants.archiveProperties.archiveCycles;
            archiveControllers = state.constants.archiveProperties.archiveControllers;
          };
        };
      };
    };

    /// Alias for backward compatibility
    /// @deprecated Use get_stats() instead
    public func stats() : Stats = get_stats();

    /// Returns the statistics of the migration
    ///
    /// This function returns the statistics of the migration.
    ///
    /// Returns:
    /// - The migration statistics
    public func get_state() : CurrentState {
      return state;
    };

    ///Returns an array of supported block types.
    ///
    /// @returns {Array<BlockType>} The array of supported block types.
    public func supported_block_types() : [BlockType] {
      return List.toArray(state.supportedBlocks);
    };

    /// Returns a set of transactions and pointers to archives if necessary
    /// Core function that extracts the shared logic for both get_blocks and get_blocks_legacy
    ///
    /// Returns raw blocks and archive information that can be formatted differently
    private func get_blocks_core(args: [{start: Nat; length: Nat}]) : {
      ledger_length: Nat;
      blocks: List.List<{id: Nat; block: Value}>;
      archives: Map.Map<Principal, List.List<TransactionRange>>;
      first_index: ?Nat;
    } {

      debug if(debug_channel.get_transactions) Debug.print("List.size(state.ledger)" # debug_show((List.size(state.ledger), List.toArray(state.ledger))));
      let local_ledger_length = List.size(state.ledger);

      var first_index : ?Nat = null;


      let ledger_length = if(state.lastIndex == 0 and local_ledger_length == 0) {
        0;
      } else {
        state.lastIndex + 1;
      };

      debug if(debug_channel.get_transactions) Debug.print("have ledger length" # debug_show(ledger_length));

      //get the transactions on this canister
      let transactions = List.empty<{id: Nat; block: Value}>();
      label proc for(thisArg in args.vals()){
        debug if(debug_channel.get_transactions) Debug.print("setting start " # debug_show(thisArg.start + thisArg.length, state.firstIndex));
        
        // Skip if length is 0 - no blocks to retrieve
        if(thisArg.length == 0) {
          continue proc;
        };
        
        if(thisArg.start + thisArg.length > state.firstIndex){
          debug if(debug_channel.get_transactions) Debug.print("setting start " # debug_show(thisArg.start + thisArg.length, state.firstIndex));
          let start = if(thisArg.start <= state.firstIndex){
            debug if(debug_channel.get_transactions) Debug.print("setting start " # debug_show(0));
            0;
          } else{
            debug if(debug_channel.get_transactions) Debug.print("getting trx" # debug_show(state.lastIndex, state.firstIndex, thisArg));
            if(thisArg.start >= (state.firstIndex)){
              Nat.sub(thisArg.start, (state.firstIndex));
            } else {
              Runtime.trap("last index must be larger than requested start plus one");
            };
          };

          let end = if(List.size(state.ledger)==0){
            0;
          } else if(thisArg.start + thisArg.length > state.lastIndex + 1){
            Nat.sub(List.size(state.ledger), 1);
          } else {
            // Calculate the actual end index (exclusive), then make it inclusive for Iter.range
            let localEndIndex = Nat.sub(thisArg.start + thisArg.length, state.firstIndex);
            if(localEndIndex > 0 and localEndIndex <= List.size(state.ledger)) {
              Nat.sub(localEndIndex, 1);
            } else {
              0;
            };
          };


          debug if(debug_channel.get_transactions) Debug.print("getting local transactions" # debug_show(start,end));
          //some of the items are on this server
          if(List.size(state.ledger) > 0 and start <= end){
            label search for(thisItem in HelperLib.range(start, end)){
              debug if(debug_channel.get_transactions) Debug.print("testing" # debug_show(thisItem));
              if(thisItem >= List.size(state.ledger)){
                break search;
              };
              if(first_index == null){
                debug if(debug_channel.get_transactions) Debug.print("setting first index" # debug_show(state.firstIndex + thisItem));
                first_index := ?(state.firstIndex + thisItem);
              };
              List.add(transactions, {
                  id = state.firstIndex + thisItem;
                  block = List.at(state.ledger, thisItem)
              });
            };
          };
        };
      };

      //get any relevant archives
      let archives = Map.empty<Principal, List.List<TransactionRange>>();

      for(thisArgs in args.vals()){
        if(thisArgs.start < state.firstIndex){
          
          debug if(debug_channel.get_transactions) Debug.print("archive settings are " # debug_show(Iter.toArray(Map.entries(state.archives))));
          var seeking = thisArgs.start;
          label archive for(thisItem in Map.entries(state.archives)){
            if (seeking > Nat.sub(thisItem.1.start + thisItem.1.length, 1) or thisArgs.start + thisArgs.length <= thisItem.1.start) {
                continue archive;
            };

            // Calculate the start and end indices of the intersection between the requested range and the current archive.
            let overlapStart = Nat.max(seeking, thisItem.1.start);
            let overlapEnd = Nat.min(thisArgs.start + thisArgs.length - 1, thisItem.1.start + thisItem.1.length - 1);
            let overlapLength = Nat.sub(overlapEnd, overlapStart) + 1;

            // Create an archive request for the overlapping range.
            switch(Map.get(archives, principal_compare, thisItem.0)){
              case(null){
                let newList = List.empty<TransactionRange>();
                List.add(newList, {
                    start = overlapStart;
                    length = overlapLength;
                  });
                Map.add<Principal, List.List<TransactionRange>>(archives, principal_compare, thisItem.0, newList);
              };
              case(?existing){
                List.add(existing, {
                  start = overlapStart;
                  length = overlapLength;
                });
              };
            };

            // If the overlap ends exactly where the requested range ends, break out of the loop.
            if (overlapEnd == Nat.sub(thisArgs.start + thisArgs.length, 1)) {
                break archive;
            };

            // Update seeking to the next desired transaction.
            seeking := overlapEnd + 1;
          };
        };
      };

      debug if(debug_channel.get_transactions) Debug.print("returning transactions result" # debug_show(ledger_length, List.size(transactions), Map.size(archives)));
      
      return {
        ledger_length = ledger_length;
        blocks = transactions;
        archives = archives;
        first_index = first_index;
      };
    };

    ///
    /// This function returns a set of transactions and pointers to archives if necessary.
    ///
    /// Arguments:
    /// - `args`: The transaction range
    ///
    /// Returns:
    /// - The result of getting transactions
    public func get_blocks(args: GetBlocksArgs) : GetBlocksResult {
      let coreResult = get_blocks_core(args);
      
      //build the result
      return {
        log_length = coreResult.ledger_length;
        blocks = List.toArray(coreResult.blocks);
        archived_blocks = Iter.toArray<MigrationTypes.Current.ArchivedTransactionResponse>(Iter.map<(Principal, List.List<TransactionRange>), MigrationTypes.Current.ArchivedTransactionResponse>(Map.entries(coreResult.archives), func(x :(Principal, List.List<TransactionRange>)):  MigrationTypes.Current.ArchivedTransactionResponse{
          {
            args = List.toArray(x.1);
            callback = (actor(Principal.toText(x.0)) : MigrationTypes.Current.ICRC3Interface).icrc3_get_blocks;
          }
        }));
      };
    };

    /// Rosetta-compatible version of get_blocks 
    /// Returns blocks in the format expected by dfinity/ic-icrc-rosetta-api
    /// Uses the archive's get_blocks method callback instead of icrc3_get_blocks
    ///
    /// Arguments:
    /// - `args`: The GetBlocksRequest range
    ///
    /// Returns:
    /// - Rosetta-compatible block response with proper archive callbacks
    public func get_blocks_rosetta(args: Legacy.GetBlocksRequest) : Legacy.RosettaGetBlocksResponse {
      // Convert single request to array format expected by core function
      let coreArgs = [{start = args.start; length = args.length}];
      let coreResult = get_blocks_core(coreArgs);
      
      // Extract just the block values (not the {id, block} wrapper)
      let blockValues = Array.map<{id: Nat; block: Value}, Value>(List.toArray(coreResult.blocks), func(item) = item.block);
      
      // Convert archives to Rosetta format with get_blocks callback
      let rosettaArchives = Array.map<(Principal, List.List<TransactionRange>), Legacy.RosettaArchivedRange>(
        Iter.toArray(Map.entries(coreResult.archives)), 
        func(archiveEntry: (Principal, List.List<TransactionRange>)): Legacy.RosettaArchivedRange {
          let ranges = List.toArray(archiveEntry.1);
          // For Rosetta, we need to flatten multiple ranges into single start/length
          // Taking the first range as the format expects single range per archive
          let firstRange = if (ranges.size() > 0){ ranges[0] } else {{start = 0; length = 0}};
          
          {
            callback = (actor(Principal.toText(archiveEntry.0)) : actor {
              get_blocks: shared query (Legacy.GetBlocksRequest) -> async Legacy.RosettaBlockRange;
            }).get_blocks;
            start = firstRange.start;
            length = firstRange.length;
          };
        } 
      );

      return {
        first_index = switch(coreResult.first_index){
          case(null) state.firstIndex;
          case(?val) val;
        };
        chain_length = Nat64.fromNat(coreResult.ledger_length);
        certificate = null; // Only available in replicated query context
        blocks = blockValues;
        archived_blocks = rosettaArchives;
      };
    };

    /// Legacy version of get_blocks that returns transactions in the legacy format
    ///
    /// This function uses the same core logic as get_blocks but converts the results
    /// to legacy transaction format and uses legacy archive callbacks.
    ///
    /// Arguments:
    /// - `args`: The GetBlocksRequest range
    ///
    /// Returns:
    /// - Legacy transaction response with converted transactions
    public func get_blocks_legacy(args: Legacy.GetBlocksRequest) : Legacy.GetTransactionsResponse {
      // Convert single request to array format expected by core function
      let coreArgs = [{start = args.start; length = args.length}];
      let coreResult = get_blocks_core(coreArgs);
      
      // Convert ICRC-3 blocks to legacy transactions
      let blockValues = Array.map<{id: Nat; block: Value}, Value>(List.toArray(coreResult.blocks), func(item) = item.block);
      let legacyTransactions = Legacy.convertICRC3ToLegacyTransaction(blockValues);
      
      // Convert archives to legacy format
      let legacyArchives = Array.map<(Principal, List.List<TransactionRange>), Legacy.LegacyArchivedRange>(
        Iter.toArray(Map.entries(coreResult.archives)), 
        func(archiveEntry: (Principal, List.List<TransactionRange>)): Legacy.LegacyArchivedRange {
          let ranges = List.toArray(archiveEntry.1);
          // For legacy, we need to flatten multiple ranges into single start/length
          // Taking the first range as legacy format expects single range
          let firstRange = if (ranges.size() > 0){ ranges[0] } else {{start = 0; length = 0}};
          
          {
            callback = (actor(Principal.toText(archiveEntry.0)) : actor {
              get_transactions: shared query (Legacy.GetBlocksRequest) -> async Legacy.GetArchiveTransactionsResponse;
            }).get_transactions;
            start = firstRange.start;
            length = firstRange.length;
          };
        } 
      );
      
      debug if(debug_channel.get_transactions) Debug.print("Returning legacy transactions result" # debug_show(coreResult.ledger_length, coreResult.first_index, state.firstIndex, Map.size(coreResult.archives)));

      return {
        first_index = switch(coreResult.first_index){
          case(null) state.firstIndex;
          case(?val) val;
        };
        log_length = coreResult.ledger_length;
        transactions = legacyTransactions;
        archived_transactions = legacyArchives;
      };
    };

    /// Registers a listener that will be notified when a record is added to the ledger
    ///
    /// The listener will receive the transaction value and its index in the ledger.
    /// If a listener with the same namespace already exists, it will be replaced.
    ///
    /// Arguments:
    /// - `namespace`: A unique identifier for the listener (used to prevent duplicates)
    /// - `remote_func`: The callback function to invoke when a record is added
    ///
    /// Example:
    /// ```motoko
    /// icrc3.register_record_added_listener("my_namespace", func<system>(trx: Value, index: Nat) {
    ///   // Handle the new record
    /// });
    /// ```
    public func register_record_added_listener(namespace: Text, remote_func: RecordAddedListener) {
      let listener = (namespace, remote_func);
      switch(List.indexOf<(Text, RecordAddedListener)>(record_added_listeners, func(a: (Text, RecordAddedListener), b: (Text, RecordAddedListener)) : Bool {
        Text.equal(a.0, b.0);
      }, listener)){
        case(?index){
          List.put<(Text, RecordAddedListener)>(record_added_listeners, index, listener);
        };
        case(null){
          List.add<(Text, RecordAddedListener)>(record_added_listeners, listener);
        };
      };
    };

    public var org_icdevs_ovs_fixed : ?(() -> OVSFixed.OVS) = null; //initialized later
    public var org_icdevs_class_plus_manager : ?ClassPlusLib.ClassPlusInitializationManager = null; //initialized later

    /// `get_icrc85_stats`
    ///
    /// Returns the current ICRC-85 Open Value Sharing statistics.
    public func get_icrc85_stats() : {
      activeActions: Nat;
      lastActionReported: ?Nat;
      nextCycleActionId: ?Nat;
    } {
      {
        activeActions = state.org_icdevs_ovs_fixed_state.activeActions;
        lastActionReported = state.org_icdevs_ovs_fixed_state.lastActionReported;
        nextCycleActionId = state.org_icdevs_ovs_fixed_state.nextCycleActionId;
      };
    };
  };
}