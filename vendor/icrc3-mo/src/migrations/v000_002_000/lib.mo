import MigrationTypes "../types";
import v0_2_0 "types";

import Map "mo:core/Map";
import List "mo:core/List";
import Vec "mo:vector";
import OldMap "mo:map/Map";
import v0_1_0 "../v000_001_000/types";

import OVSFixed "mo:ovs-fixed";

module {

  type Transaction = v0_2_0.Transaction;
  type BlockType = v0_2_0.BlockType;
  type TransactionRange = v0_2_0.TransactionRange;

  public func upgrade(prevMigrationState: MigrationTypes.State, _args: ?MigrationTypes.Args, _caller: Principal, _canister: Principal): MigrationTypes.State {

    let #v0_1_0(#data(prevState)) = prevMigrationState else {
      return prevMigrationState; // Already at or past this version
    };

    // 0.3.x layout -> mo:core: mo:vector ledger/supportedBlocks -> core List; mo:map archives -> core Map.
    // Transaction/BlockType/TransactionRange are the same shapes in both versions.
    let newLedger = List.fromArray<Transaction>(Vec.toArray<v0_1_0.Transaction>(prevState.ledger));
    let newSupportedBlocks = List.fromArray<BlockType>(Vec.toArray<v0_1_0.BlockType>(prevState.supportedBlocks));
    let newArchives = Map.fromIter<Principal, TransactionRange>(OldMap.entries<Principal, v0_1_0.TransactionRange>(prevState.archives), v0_2_0.principal_compare);

    let state : v0_2_0.State = {
      var ledger = newLedger;
      archives = newArchives;
      supportedBlocks = newSupportedBlocks;
      ledgerCanister = prevState.ledgerCanister;
      var lastIndex = prevState.lastIndex;
      var firstIndex = prevState.firstIndex;
      var bCleaning = prevState.bCleaning;
      var cleaningTimer = prevState.cleaningTimer;
      var latest_hash = prevState.latest_hash;
      constants = {
        archiveProperties = {
          var maxActiveRecords = prevState.constants.archiveProperties.maxActiveRecords;
          var settleToRecords = prevState.constants.archiveProperties.settleToRecords;
          var maxRecordsInArchiveInstance = prevState.constants.archiveProperties.maxRecordsInArchiveInstance;
          var maxRecordsToArchive = prevState.constants.archiveProperties.maxRecordsToArchive;
          var maxArchivePages = prevState.constants.archiveProperties.maxArchivePages;
          var archiveIndexType = prevState.constants.archiveProperties.archiveIndexType;
          var archiveCycles = prevState.constants.archiveProperties.archiveCycles;
          var archiveControllers = prevState.constants.archiveProperties.archiveControllers;
        };
      };
      // Initialize ICRC-85 state for OVS
      
      var org_icdevs_ovs_fixed_state = OVSFixed.initialState();
      var org_icdevs_timer_tool = null;
    };

    return #v0_2_0(#data(state));
  };

};
