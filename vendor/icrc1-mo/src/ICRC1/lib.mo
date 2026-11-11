import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import List "mo:core/List";
import Map "mo:core/Map";
import RepIndy "mo:rep-indy-hash";
import Star "mo:star/star";
import OVSFixed "mo:ovs-fixed";
import ClassPlusLib "mo:class-plus";


import Account "Account";
import Migration "./migrations";
import MigrationTypes "./migrations/types";
import Utils "Utils";


/// The ICRC1 class defines the structure and functions necessary for creating and managing ICRC-1 compliant tokens on the Internet Computer. 
/// It encapsulates the state and behavior of a token ledger which includes transfer, mint, and burn functionalities, as well 
/// as metadata handling and tracking of transactions via ICRC-3 transaction logs.
module {

    /// Used to control debug printing for various actions.
    let debug_channel = {
      announce = false;
      transfer = false;
      accounts = false;
      standards = false;
      validation = false;
      icrc85 = false;
    };

    // ICRC-85 Constants
    let ONE_DAY = 86_400_000_000_000; // 1 day in nanoseconds
    let ONE_XDR_OF_CYCLES = 1_000_000_000_000;  // 1 XDR worth of cycles (~1T)
    let ICRC85_NAMESPACE = "org.icdevs.icrc85.icrc1";
    let ICRC85_TIMER_NAMESPACE = "icrc85:ovs:shareaction:icrc1";

    /// Default fee returned when no fee is configured or when the fee is environment-determined.
    let DEFAULT_FEE : Nat = 10_000;

    /// Exposes types from the migrations library to users of this module, allowing them to utilize these types in interacting 
    /// with instances of ICRC1 tokens and their respective attributes and actions.
    public type State =               MigrationTypes.State;


    // Imports from types to make code more readable
    public type CurrentState =        MigrationTypes.Current.State;
    public type Environment =         MigrationTypes.Current.Environment;
    public type FeeValidationMode =   MigrationTypes.Current.FeeValidationMode;

    public type Account =             MigrationTypes.Current.Account;
    public type Balance =             MigrationTypes.Current.Balance;
    public type Value =               MigrationTypes.Current.Value;
    public type Subaccount =          MigrationTypes.Current.Subaccount;
    public type AccountBalances =     MigrationTypes.Current.AccountBalances;

    public type Transaction =         MigrationTypes.Current.Transaction;
    public type Fee =                 MigrationTypes.Current.Fee;
    public type MetaData =            MigrationTypes.Current.MetaData;
    public type TransferArgs =        MigrationTypes.Current.TransferArgs;
    public type Mint =                MigrationTypes.Current.Mint;
    public type BurnArgs =            MigrationTypes.Current.BurnArgs;
    public type TransactionRequest =  MigrationTypes.Current.TransactionRequest;
    public type TransactionRequestNotification = MigrationTypes.Current.TransactionRequestNotification;
    public type TransferError =       MigrationTypes.Current.TransferError;

    public type SupportedStandard =   MigrationTypes.Current.SupportedStandard;

    public type InitArgs =            MigrationTypes.Current.InitArgs;
    public type AdvancedSettings =    MigrationTypes.Current.AdvancedSettings;
    public type MetaDatum =           MigrationTypes.Current.MetaDatum;
    public type TxLog =               MigrationTypes.Current.TxLog;
    public type TxIndex =             MigrationTypes.Current.TxIndex;
    public type CanTransfer =             MigrationTypes.Current.CanTransfer;

    public type UpdateLedgerInfoRequest = MigrationTypes.Current.UpdateLedgerInfoRequest;


    public type TransferResult = MigrationTypes.Current.TransferResult;
    public type TokenTransferredListener = MigrationTypes.Current.TokenTransferredListener;
    public type TransferRequest = MigrationTypes.Current.TransactionRequest;

    // ICRC-85 Open Value Sharing types
    public type ICRC85State = MigrationTypes.Current.ICRC85State;
    public type ICRC85Environment = MigrationTypes.Current.ICRC85Environment;
    public type TimerTool = MigrationTypes.Current.TimerTool;

    // ICRC-107 Fee Management types
    public type SetFeeCollectorArgs = {
      fee_collector : ?Account;
      created_at_time : Nat64;
    };

    public type SetFeeCollectorError = {
      #AccessDenied : Text;
      #InvalidAccount : Text;
      #Duplicate : { duplicate_of : Nat };
      #TooOld;
      #CreatedInFuture : { ledger_time : Nat64 };
      #GenericError : { error_code : Nat; message : Text };
    };

    public type SetFeeCollectorResult = {
      #Ok : Nat;
      #Err : SetFeeCollectorError;
    };

    public type GetFeeCollectorError = {
      #GenericError : { error_code : Nat; message : Text };
    };

    public type GetFeeCollectorResult = {
      #Ok : ?Account;
      #Err : GetFeeCollectorError;
    };

    // ICRC-106 Index Principal types
    public type Icrc106Error = {
      #GenericError : { description : Text; error_code : Nat };
      #IndexPrincipalNotSet;
    };

    public type Icrc106GetResult = {
      #Ok : Principal;
      #Err : Icrc106Error;
    };

    // ICRC-21 Consent Message types
    public type ConsentMessageMetadata = {
      language : Text;
      utc_offset_minutes : ?Int16;
    };

    public type ConsentMessageSpec = {
      metadata : ConsentMessageMetadata;
      device_spec : ?{
        #GenericDisplay;
        #FieldsDisplay;
      };
    };

    public type ConsentMessageRequest = {
      method : Text;
      arg : Blob;
      user_preferences : ConsentMessageSpec;
    };

    public type DisplayValue = {
      #TokenAmount : { decimals : Nat8; amount : Nat64; symbol : Text };
      #TimestampSeconds : { amount : Nat64 };
      #DurationSeconds : { amount : Nat64 };
      #Text : { content : Text };
    };

    public type ConsentMessage = {
      #GenericDisplayMessage : Text;
      #FieldsDisplayMessage : { intent : Text; fields : [(Text, DisplayValue)] };
    };

    public type ConsentInfo = {
      consent_message : ConsentMessage;
      metadata : ConsentMessageMetadata;
    };

    public type ErrorInfo = {
      description : Text;
    };

    public type Icrc21Error = {
      #UnsupportedCanisterCall : ErrorInfo;
      #ConsentMessageUnavailable : ErrorInfo;
      #InsufficientPayment : ErrorInfo;
      #GenericError : { error_code : Nat; description : Text };
    };

    public type ConsentMessageResponse = {
      #Ok : ConsentInfo;
      #Err : Icrc21Error;
    };

    public type TokenInfo = {
      symbol : Text;
      decimals : Nat8;
      fee : Nat;
    };

    /// Type for consent message handlers registered by each standard.
    /// Takes the request, token info, and resolved display spec.
    /// Returns the consent message response.
    public type ConsentMessageHandler = (ConsentMessageRequest, TokenInfo, { #GenericDisplay; #FieldsDisplay }) -> ConsentMessageResponse;

    // =========================================================================
    // ICRC-21 Helper Functions (public for use by ICRC-2, ICRC-4 handlers)
    // =========================================================================

    /// Check that a blob has valid candid magic bytes ("DIDL")
    public func hasValidCandidHeader(blob : Blob) : Bool {
      if (blob.size() < 4) return false;
      let bytes = Blob.toArray(blob);
      bytes[0] == 0x44 and bytes[1] == 0x49 and bytes[2] == 0x44 and bytes[3] == 0x4C;
    };

    /// Format a token amount with proper decimal placement.
    /// e.g. formatAmount(123456789, 8) => "1.23456789"
    public func formatAmount(amount : Nat, decimals : Nat8) : Text {
      let dec = Nat8.toNat(decimals);
      if (dec == 0) return Nat.toText(amount);

      var divisor : Nat = 1;
      var i : Nat = 0;
      while (i < dec) {
        divisor := divisor * 10;
        i += 1;
      };

      let whole = amount / divisor;
      let frac = amount % divisor;

      if (frac == 0) return Nat.toText(whole) # ".0";

      // Pad fractional part with leading zeros
      var fracText = Nat.toText(frac);
      while (fracText.size() < dec) {
        fracText := "0" # fracText;
      };

      // Trim trailing zeros
      let chars = Text.toArray(fracText);
      var end = chars.size();
      while (end > 1 and chars[end - 1] == '0') {
        end -= 1;
      };
      var trimmed = "";
      var j : Nat = 0;
      while (j < end) {
        trimmed := trimmed # Text.fromChar(chars[j]);
        j += 1;
      };

      Nat.toText(whole) # "." # trimmed;
    };

    func hexChar(n : Nat8) : Text {
      let chars = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"];
      chars[Nat8.toNat(n)];
    };

    /// Format an Account as text: "principal" or ICRC-1 textual encoding
    public func formatAccount(account : Account) : Text {
      let ownerText = Principal.toText(account.owner);
      switch (account.subaccount) {
        case (null) ownerText;
        case (?sub) {
          var allZero = true;
          for (b in sub.vals()) {
            if (b != 0) allZero := false;
          };
          if (allZero) {
            ownerText;
          } else {
            Account.encodeAccount(account);
          };
        };
      };
    };

    /// Format an optional memo as hex string
    public func formatMemo(memo : ?Blob) : Text {
      switch (memo) {
        case (null) "None";
        case (?m) {
          if (m.size() == 0) return "Empty";
          var hex = "0x";
          for (b in m.vals()) {
            let hi = b / 16;
            let lo = b % 16;
            hex := hex # hexChar(hi) # hexChar(lo);
          };
          hex;
        };
      };
    };

    // =========================================================================
    // Built-in ICRC-21 Consent Builders
    // =========================================================================

    /// Build a consent message for icrc1_transfer
    public func buildTransferConsent(
      request : ConsentMessageRequest,
      info : TokenInfo,
      spec : { #GenericDisplay; #FieldsDisplay },
    ) : ConsentMessageResponse {
      let decoded : ?TransferArgs = from_candid(request.arg);
      switch (decoded) {
        case (null) {
          #Err(#UnsupportedCanisterCall({ description = "Failed to decode icrc1_transfer arguments" }));
        };
        case (?args) {
          let amountText = formatAmount(args.amount, info.decimals);
          let feeText = formatAmount(info.fee, info.decimals);
          let toText = formatAccount(args.to);

          switch (spec) {
            case (#GenericDisplay) {
              var md = "## Transfer " # info.symbol # "\n\n";
              md := md # "**Amount:** " # amountText # " " # info.symbol # "\n\n";
              md := md # "**To:** " # toText # "\n\n";
              md := md # "**Fee:** " # feeText # " " # info.symbol;
              switch (args.memo) {
                case (?_m) { md := md # "\n\n**Memo:** " # formatMemo(args.memo) };
                case (null) {};
              };
              #Ok({
                consent_message = #GenericDisplayMessage(md);
                metadata = request.user_preferences.metadata;
              });
            };
            case (#FieldsDisplay) {
              let fields = Array.tabulate<(Text, DisplayValue)>(
                switch (args.memo) { case (null) 3; case (?_) 4 },
                func(i : Nat) : (Text, DisplayValue) {
                  switch (i) {
                    case (0) ("Amount", #TokenAmount({ decimals = info.decimals; amount = Nat64.fromNat(args.amount); symbol = info.symbol }));
                    case (1) ("To", #Text({ content = toText }));
                    case (2) ("Fee", #TokenAmount({ decimals = info.decimals; amount = Nat64.fromNat(info.fee); symbol = info.symbol }));
                    case (_) ("Memo", #Text({ content = formatMemo(args.memo) }));
                  };
                },
              );
              #Ok({
                consent_message = #FieldsDisplayMessage({
                  intent = "Transfer " # amountText # " " # info.symbol;
                  fields = fields;
                });
                metadata = request.user_preferences.metadata;
              });
            };
          };
        };
      };
    };

    /// Build a consent message for icrc107_set_fee_collector
    public func buildSetFeeCollectorConsent(
      request : ConsentMessageRequest,
      _info : TokenInfo,
      spec : { #GenericDisplay; #FieldsDisplay },
    ) : ConsentMessageResponse {
      let decoded : ?SetFeeCollectorArgs = from_candid(request.arg);
      switch (decoded) {
        case (null) {
          #Err(#UnsupportedCanisterCall({ description = "Failed to decode icrc107_set_fee_collector arguments" }));
        };
        case (?args) {
          let collectorText = switch (args.fee_collector) {
            case (null) "None (clear fee collector)";
            case (?acct) formatAccount(acct);
          };

          switch (spec) {
            case (#GenericDisplay) {
              var md = "## Set Fee Collector\n\n";
              md := md # "**Fee collector:** " # collectorText;
              #Ok({
                consent_message = #GenericDisplayMessage(md);
                metadata = request.user_preferences.metadata;
              });
            };
            case (#FieldsDisplay) {
              let fields : [(Text, DisplayValue)] = [
                ("Fee collector", #Text({ content = collectorText })),
              ];
              #Ok({
                consent_message = #FieldsDisplayMessage({
                  intent = "Set fee collector";
                  fields = fields;
                });
                metadata = request.user_preferences.metadata;
              });
            };
          };
        };
      };
    };

    /// Defines functions to create an initial state, versioning, and utilities for the token ledger. 
    /// These are direct mappings from the Migration types library to provide an easy-to-use API surface for users of the ICRC1 class.
    public func initialState() : State {#v0_0_0(#data)};
    public let currentStateVersion = #v0_2_0(#id);

    // Initializes the state with default or migrated data and sets up other utilities such as maps and list data structures.
    /// Also initializes helper functions and constants like hashing, account equality checks, and comparisons.
    public let init = Migration.migrate;

    //convienence variables to make code more readable
    public let CoreMap = Map;
    public let CoreList = List;
    public let AccountHelper = Account;
    public let UtilsHelper = Utils;
    public let account_eq = MigrationTypes.Current.account_eq;
    public let account_compare = MigrationTypes.Current.account_compare;
    public let blob_compare = MigrationTypes.Current.blob_compare;

    // Legacy backward-compatible exports for migration support
    // These are used by older migration files in dependent libraries (like ICRC2 v0_1_0)
    public let account_hash32 = MigrationTypes.v0_1_0.account_hash32;
    public let ahash = MigrationTypes.v0_1_0.ahash;

    /// ClassPlus-compatible initialization function
    ///
    /// This function wraps the ICRC1 class with ClassPlus for proper async
    /// initialization, enabling automatic ICRC-85 timer setup.
    ///
    /// Example:
    /// ```motoko
    /// transient let icrc1 = ICRC1.Init({
    ///   org_icdevs_class_plus_manager = manager;
    ///   initialState = icrc1_migration_state;
    ///   args = ?icrc1Args;
    ///   pullEnvironment = ?getEnvironment;
    ///   onInitialize = null;
    ///   onStorageChange = func(state: ICRC1.State) {
    ///     icrc1_migration_state := state;
    ///   };
    /// });
    /// ```

    /// Type for Init function arguments
    public type InitFunctionArgs = {
      org_icdevs_class_plus_manager: ClassPlusLib.ClassPlusInitializationManager;
      initialState: State;
      args : ?InitArgs;
      pullEnvironment : ?(() -> Environment);
      onInitialize: ?(ICRC1 -> async*());
      onStorageChange : ((State) ->());
    };

    /// Type for Mixin function arguments (subset of InitFunctionArgs without initialState/onStorageChange)
    public type MixinFunctionArgs = {
      org_icdevs_class_plus_manager: ClassPlusLib.ClassPlusInitializationManager;
      args : ?InitArgs;
      pullEnvironment : ?(() -> Environment);
      onInitialize: ?(ICRC1 -> async*());
      /// Optional interceptor for validating/modifying transfers before execution
      canTransfer: CanTransfer;
      /// Authorization check for icrc107_set_fee_collector.
      /// Return true to allow, false to deny.  If null, endpoint returns NotImplemented.
      canSetFeeCollector: ?((Principal) -> Bool);
      /// Authorization check for set_icrc106_index_principal.
      /// Return true to allow, false to deny.  If null, endpoint returns error.
      canSetIndexPrincipal: ?((Principal) -> Bool);
    };

    /// Creates default mixin args with all optional fields set to null.
    /// Use with Motoko's `with` syntax to override specific fields.
    ///
    /// Example:
    /// ```motoko
    /// include ICRC1Mixin.mixin({
    ///   ICRC1.defaultMixinArgs(org_icdevs_class_plus_manager) with
    ///   pullEnvironment = ?get_icrc1_environment;
    ///   canTransfer = ?#Sync(myValidator);
    /// });
    /// ```
    public func defaultMixinArgs(manager: ClassPlusLib.ClassPlusInitializationManager) : MixinFunctionArgs {
      {
        org_icdevs_class_plus_manager = manager;
        args = null;
        pullEnvironment = null;
        onInitialize = null;
        canTransfer = null;
        canSetFeeCollector = null;
        canSetIndexPrincipal = null;
      };
    };

    public func Init(config : InitFunctionArgs) : () -> ICRC1 {
      
      debug if(debug_channel.announce) Debug.print("ICRC1 Init");
      
      
      let wrappedOnInitialize = func(instance: ICRC1) : async* () {

        //make sure metadata is good to go.
        ignore instance.metadata();

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

        //icrc1 needs its own classmanager
        var org_icdevs_class_plus_manager = ClassPlusLib.ClassPlusInitializationManager<system>(instance.caller, instance.canister, true);

        instance.org_icdevs_class_plus_manager := ?org_icdevs_class_plus_manager;

        func getOVSEnv() : OVSFixed.Environment {
          {
              var org_icdevs_timer_tool = instance.environment.org_icdevs_timer_tool;
              var collector = do?{instance.environment.advanced!.icrc85.collector!};
              advanced = do?{instance.environment.advanced!.icrc85.advanced!};
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
        
        switch(config.onInitialize){
          case(?cb) await* cb(instance);
          case(null) {};
        };
      };

      ClassPlusLib.ClassPlus<
        ICRC1, 
        State,
        InitArgs,
        Environment>({config with 
          //org_icdevs_class_plus_manager = org_icdevs_class_plus_manager;
          constructor = ICRC1;
          onInitialize = ?wrappedOnInitialize
        }).get;
    };


    //// The `ICRC1` class encapsulates the logic required for managing a token ledger, providing capabilities 
    //// such as transferring tokens, getting account balances, and maintaining a log of transactions.
    //// It also supports minting and burning tokens while following compliance with the ICRC-1 standard.
    ////
    //// Parameters:
    //// - `stored`: An optional parameter that can be the previously stored state of the ledger for migration purposes.
    //// - `caller`: The `Principal` that initiated the creation (used for permission checks).
    //// - `canister`: The `Principal` of the canister where this token ledger is deployed.
    //// - `args`: Optional initialization arguments to configure the token.
    //// - `environment_passed`: Optional contextual information for the ledger such as fees and timestamp functions.
    //// - `storageChanged`: Callback invoked when state changes (for persistence notification).
    public class ICRC1(stored: ?State, _caller: Principal, _canister: Principal, args: ?InitArgs, environment_passed: ?Environment, storageChanged: (State) -> ()){

      public let caller = _caller;
      public let canister = _canister;


      /// The environment configuration, unwrapped from optional
      public let environment = switch(environment_passed){
        case(null) Runtime.trap("No Environment Provided");
        case(?val) val;
      };

      /// Initializes the ledger state with either a new state or a given state for migration. 
      /// This setup process involves internal data migration routines.
      public var state : CurrentState = do {
        let #v0_2_0(#data(foundState)) = init(
          switch(stored){
            case(null) initialState();
            case(?val) val;
          }, currentStateVersion, args, caller) else Runtime.trap("ICRC1 Not in final state after migration - "  # debug_show(currentStateVersion));
        foundState;
      };
   
      // Notify storage changed after initialization
      storageChanged(#v0_2_0(#data(state)));

      /// Holds the list of listeners that are notified when a token transfer takes place. 
      /// This allows the ledger to communicate token transfer events to other canisters or entities that have registered an interest.
      private let token_transferred_listeners = List.empty<(Text, TokenTransferredListener)>();

      public var org_icdevs_ovs_fixed : ?(() -> OVSFixed.OVS) = null; //initialized later
      public var org_icdevs_class_plus_manager : ?ClassPlusLib.ClassPlusInitializationManager = null; //initialized later
      
      
      //// Retrieves the full internal state of the token ledger.
      //// This state includes all balances, metadata, transaction logs, and other relevant financial and operational data.
      ////
      //// Returns:
      //// - `CurrentState`: The complete state data of the ledger.
      public func get_state() : CurrentState {
        return state;
      };

      /// Returns the array of local transactions. Does not scale use icrc3-mo for scalable archives
      ///
      /// Returns:
      /// - `List<Transaction>`: A list containing the local transactions recorded in the ledger.
      public func get_local_transactions() : List.List<Transaction> {
        return state.local_transactions;
      };

      /// Returns the current environment settings for the ledger.
      ///
      /// Returns:
      /// - `Environment`: The environment context in which the ledger operates, encapsulating properties 
      ///   like transfer fee calculation and timing functions.
      public func get_environment() : Environment {
        return environment;
      };

      /// Returns the canister Principal where this ledger is deployed.
      ///
      /// Returns:
      /// - `Principal`: The Principal of the canister hosting this ledger.
      public func get_canister() : Principal {
        return canister;
      };

      /// Returns the name of the token for display.
      ///
      /// Returns:
      /// - `Text`: The token's name; or if not set, the default is the canister's principal in text form.
      public func name() : Text {
          switch(state.name){
            case(?val) val;
            case(_) Principal.toText(canister);
          };
      };

      /// Returns the symbol of the token for display, e.g. "BTC" or "ETH".
      ///
      /// Returns:
      /// - `Text`: The token's symbol; or if not set, the default is the canister's principal in text form.
      public func symbol() : Text {
          switch(state.symbol){
            case(?val) val;
            case(_) Principal.toText(canister);
          };
      };

      /// Returns the number of decimals the token uses for precision.
      ///
      /// Best Practice: 8
      ///
      /// Returns:
      /// - `Nat8`: The number of decimals used in token quantity representation.
      public func decimals() : Nat8 {
          state.decimals;
      };

      /// Returns the default or environment-specified transfer fee.
      ///
      /// Returns:
      /// - `Balance`: The fixed or computed fee for each token transfer.
      public func fee() : MigrationTypes.Current.Balance {
          switch(state._fee){
            case(?val) switch(val){
              case(#Fixed(val))val;
              case(#Environment){
                //placeholder: actual fee is determined at runtime via environment callback
                DEFAULT_FEE;
              };
            };
            case(_) DEFAULT_FEE;
          };
      };


      /// `metadata`
      ///
      /// Retrieves all metadata associated with the token ledger, such as the symbol, name, and other relevant data.
      /// If no metadata is found, the method initializes default metadata based on the state and the canister Principal.
      ///
      /// Returns:
      /// `MetaData`: A record containing all metadata entries for this ledger.
      public func metadata() : [MetaDatum] {
         let md = switch(state.metadata){
          case(null) {
            let newdata = init_metadata();
            state.metadata := ?newdata;
            newdata;
          };
          case(?val) val;
         };

         switch(md){
          case(#Map(val)) val;
          case(_) Runtime.trap("malformed metadata");
         };
      };

      /// `register_metadata`
      ///
      /// Adds metadata to the metadata list from outside the class
      /// Used by ICRC2 and 3 to add metadata dataum.
      ///
      /// Returns:
      /// `MetaData`: A record containing all metadata entries for this ledger.
      /// Warning: This function does not perform security checks. You will need to do this at the implementation level.
      public func register_metadata(request: [MetaDatum]) : [MetaDatum]{
        let md = switch(state.metadata){
          case(?#Map(val)) val;
          case(_) [];
         };

        let results = Map.empty<Text, MetaDatum>();
        for(thisItem in md.vals()){
          Map.add(results, Text.compare, thisItem.0, thisItem);
        };

        for(thisItem in request.vals()){
          Map.add(results, Text.compare, thisItem.0, thisItem);
        };

        let finalresult = Iter.toArray<MetaDatum>(Map.values(results));
        state.metadata := ?#Map(finalresult);
        return finalresult;
      };

      /// Creates a List with the default metadata and returns it.
      public func init_metadata() : MigrationTypes.Current.Value {
          let metadata = List.empty<MigrationTypes.Current.MetaDatum>();
          List.add(metadata, ("icrc1:fee", #Nat(switch(state._fee){
            case(null) DEFAULT_FEE;
            case(?val){
              switch(val){
                case(#Fixed(val))val;
                case(#Environment) DEFAULT_FEE; //placeholder: actual fee is determined at runtime via environment callback.
              };
            }
          })));
          List.add(metadata, ("icrc1:name", #Text(switch(state.name){
            case(null) Principal.toText(canister);
            case(?val) val;
          })));

          List.add(metadata, ("icrc1:symbol", #Text(switch(state.symbol){
            case(null) Principal.toText(canister);
            case(?val) val;
          })));
          List.add(metadata, ("icrc1:decimals", #Nat(Nat8.toNat(state.decimals))));

          switch(state.logo){
            case(null){};
            case(?val){
              List.add(metadata, ("icrc1:logo", #Text(val)));
            };
          };

          let finalmetadata = register_metadata(List.toArray(metadata));

          #Map(finalmetadata);
      };

    /// Updates ledger information such as approval limitations with the provided request.
    /// - Parameters:
    ///     - request: `[UpdateLedgerInfoRequest]` - A list of requests containing the updates to be applied to the ledger.
    /// - Returns: `[Bool]` - An array of booleans indicating the success of each update request.
    /// Warning: This function does not perform security checks. You will need to do this at the implementation level.
    public func update_ledger_info(request: [UpdateLedgerInfoRequest]) : [Bool]{
    

      let results = List.empty<Bool>();
      for(thisItem in request.vals()){
        switch(thisItem){
          
          case(#PermittedDrift(val)){state.permitted_drift := val};
          case(#TransactionWindow(val)){state.transaction_window := val};
          case(#Name(val)){state.name := ?val};
          case(#Symbol(val)){state.symbol := ?val};
          case(#Logo(val)){state.logo := ?val};
          case(#Decimals(val)){state.decimals := val};
          case(#MaxSupply(val)){state.max_supply := val};
          case(#MaxMemo(val)){state.max_memo := val};
          case(#MinBurnAmount(val)){state.min_burn_amount := val};
          case(#MintingAccount(val)){state.minting_account := val};
          case(#MaxAccounts(val)){state.max_accounts := val};
          case(#SettleToAccounts(val)){state.settle_to_accounts := val};
          case(#FeeCollector(val)){
            state.fee_collector := val;
            state.fee_collector_emitted := false;
          };
          case(#Metadata(val)){
            let md = metadata();
            let metaResults = Map.empty<Text, MetaDatum>();
            for(thisMetaItem in md.vals()){
              Map.add(metaResults, Text.compare, thisMetaItem.0, thisMetaItem);
            };
            switch(val.1){
              case(?item){
                Map.add(metaResults, Text.compare, val.0, (val.0,item));
              };
              case(null){
                ignore Map.take(metaResults, Text.compare, val.0);
              };
            };

            let finalresult = Iter.toArray<MetaDatum>(Map.values(metaResults));
            state.metadata := ?#Map(finalresult);
          };
          case(#Fee(fee)){
            state._fee := ?fee;
          }
        };
        List.add(results, true);
      };

      ignore init_metadata();
      return List.toArray(results);
    };

      /// `total_supply`
      ///
      /// Returns the current total supply of the circulating tokens by subtracting the number of burned tokens from the minted tokens.
      ///
      /// Returns:
      /// `Balance`: The total number of tokens currently in circulation.
      public func total_supply() : MigrationTypes.Current.Balance {
          state._minted_tokens - state._burned_tokens;
      };

      /// `minted_supply`
      ///
      /// Returns the total number of tokens that have been minted since the inception of the ledger.
      ///
      /// Returns:
      /// `Balance`: The total number of tokens minted.
      public func minted_supply() : MigrationTypes.Current.Balance {
          state._minted_tokens;
      };

      /// `burned_supply`
      ///
      /// Returns the total number of tokens that have been burned since the inception of the ledger.
      ///
      /// Returns:
      /// `Balance`: The total number of tokens burned.
      public func burned_supply() : MigrationTypes.Current.Balance {
          state._burned_tokens;
      };

      /// `max_supply`
      ///
      /// Returns the maximum supply of tokens that the ledger can support.
      /// If no maximum supply is set, the function returns `null`.
      ///
      /// Returns:
      /// `?Balance`: The maximum number of tokens that can exist, or `null` if there is no limit.
      public func max_supply() : ?MigrationTypes.Current.Balance {
          state.max_supply;
      };

      /// `minting_account`
      ///
      /// Retrieves the account designated for minting operations. If tokens are sent to this account, they are considered burned.
      ///
      /// Returns:
      /// `Account`: The account with the permission to mint and burn tokens.
      public func minting_account() : MigrationTypes.Current.Account {
          state.minting_account;
      };

      /// `balance_of`
      ///
      /// Retrieves the balance of the specified account.
      ///
      /// Parameters:
      /// - `account`: The account whose balance is being requested.
      ///
      /// Returns:
      /// `Balance`: The number of tokens currently held in the account.
      public func balance_of(account : MigrationTypes.Current.Account) : MigrationTypes.Current.Balance {
          Utils.get_balance(state.accounts, account);
      };

      /// `supported_standards`
      ///
      /// Provides a list of standards supported by the ledger, indicating compliance with various ICRC standards.
      ///
      /// Returns:
      /// `[SupportedStandard]`: An array of supported standards including their names and URLs.
      public func supported_standards() : [MigrationTypes.Current.SupportedStandard] {
          switch(state.supported_standards){
            case(?val){
              List.toArray(val);
            };
            case(null){
              let base = Utils.init_standards();
              state.supported_standards := ?base;
              List.toArray(base);
            };
          };

      };

      /// `register_supported_standards`
      ///
      /// Adds a supported standard.
      ///
      /// Returns:
      /// `[SupportedStandard]`: An array of supported standards including their names and URLs.
      /// Warning: This function does not perform security checks. You will need to do this at the implementation level.
      public func register_supported_standards(req: MigrationTypes.Current.SupportedStandard) : Bool {
          let current_standards = switch(state.supported_standards){
            case(?val)val;
            case(null){
              let base = Utils.init_standards();
              state.supported_standards := ?base;
              base
            };
          };

          debug if(debug_channel.standards) Debug.print("registering a standard " # debug_show(req, List.toArray(current_standards)));


          let new_list = List.empty<MigrationTypes.Current.SupportedStandard>();
          var bFound = false;

          for(thisItem in List.values(current_standards)){
            if(thisItem.name == req.name){
              debug if(debug_channel.standards) Debug.print("replacing standard");
              bFound := true;
              List.add(new_list, req);
            } else{
              List.add(new_list, thisItem);
            }
          };

          if(bFound == false){
            List.add(new_list, req);
          };

          state.supported_standards := ?new_list;

          return true;
      };



      /// `add_local_ledger`
      ///
      /// Adds a transaction to the local transaction log and returns its index.
      ///
      /// Parameters:
      /// - `tx`: The transaction to add to the log.
      ///
      /// Returns:
      /// `Nat`: The index at which the transaction was added in the local log.
      public func add_local_ledger(tx : Transaction) : Nat{
        List.add(state.local_transactions, tx);
        List.size(state.local_transactions) - 1;
      };

      /// `transfer`
      ///
      /// Processes a token transfer request according to the provided arguments, handling both regular transfers and special cases like minting and burning.
      ///
      /// Parameters:
      /// - `args`: Details about the transfer including source, destination, amount, and other relevant data.
      /// - `caller`: The principal of the caller initiating the transfer.
      /// - `system_override`: A boolean that, if true, allows bypassing certain checks (reserved for system operations like cleaning up small balances).
      ///
      /// Returns:
      /// `TransferResult`: The result of the attempt to transfer tokens, either indicating success or providing error information.
      ///
      /// Warning: This function traps. we highly suggest using transfer_tokens to manage the returns and awaitstate change
      public func transfer(caller : Principal, args : MigrationTypes.Current.TransferArgs) : async* MigrationTypes.Current.TransferResult{
          return switch(await* transfer_tokens(caller, args, false, null)){
            case(#trappable(val)) val;
            case(#awaited(val)) val;
            case(#err(#trappable(err))) Runtime.trap(err);
            case(#err(#awaited(err))) Runtime.trap(err);
          };  
        };


      /// `transfer_tokens`
      ///
      /// Processes a token transfer request according to the provided arguments, handling both regular transfers and special cases like minting and burning.
      ///
      /// Parameters:
      /// - `args`: Details about the transfer including source, destination, amount, and other relevant data.
      /// - `caller`: The principal of the caller initiating the transfer.
      /// - `system_override`: A boolean that, if true, allows bypassing certain checks (reserved for system operations like cleaning up small balances).
      ///
      /// Returns:
      /// `TransferResult`: The result of the attempt to transfer tokens, either indicating success or providing error information.
      public func transfer_tokens<system>(
          caller : Principal,
          args : MigrationTypes.Current.TransferArgs,
          system_override : Bool,
          can_transfer : CanTransfer
      ) : async* Star.Star<MigrationTypes.Current.TransferResult, Text> {

          debug if (debug_channel.announce) Debug.print("in transfer");

          let from = {
              owner = caller;
              subaccount = args.from_subaccount;
          };

          // Per ICRC-3 refinement: If both the sender and the recipient resolve to the 
          // minting account in the same call, the ledger MUST reject the call
          let from_is_minting = account_eq(from, state.minting_account);
          let to_is_minting = account_eq(args.to, state.minting_account);

          if (from_is_minting and to_is_minting) {
            return #trappable(#Err(#GenericError({
              error_code = 7;
              message = "Invalid transfer: both sender and recipient are the minting account";
            })));
          };

          let tx_kind = if (from_is_minting) {
            #mint;
          } else if (to_is_minting) {
            #burn;
          } else {
            #transfer;
          };

          let tx_req = Utils.create_transfer_req(args, caller, tx_kind);

          //when we create the transfer we should calculate the required fee. This should only be done once and used throughout the rest of the calcualtion

          let calculated_fee = switch(tx_req.kind){
            case(#transfer){
              get_fee(args);
            };
            case(_){
              0;
            };
          };

          debug if (debug_channel.transfer) Debug.print("validating");
          switch (validate_request(tx_req, calculated_fee, system_override)) {
              case (#err(errorType)) {
                  return #trappable(#Err(errorType));
              };
              case (#ok(_)) {};
          };

          let txMap = transfer_req_to_value(tx_req);
          let txTopMap = transfer_req_to_value_top(calculated_fee, tx_req);

          let pre_notification = {
            tx_req with
            calculated_fee = calculated_fee;
          };

          var bAwaited = false;

          let (finaltx, finaltxtop, notification) : (Value, ?Value, TransactionRequestNotification) = switch(await* handleCanTransfer(txMap, ?txTopMap, pre_notification, can_transfer)){
            case(#trappable(val)) val;
            case(#awaited(val)){
              bAwaited := true;
              debug if (debug_channel.transfer) Debug.print("handleCanTransfer awaited something " # debug_show(val));
              let override_fee = val.2.calculated_fee;
              //revalidate 
              switch (validate_request(val.2, override_fee, system_override)) {
                case (#err(errorType)) {
                    return #awaited(#Err(errorType));
                };
                case (#ok(_)) {};
              };
              val;
            };
            case(#err(val)){
              debug if (debug_channel.transfer) Debug.print("handleCanTransfer gave us an error of " # debug_show(val));
              return val;
            };
          };

          let { amount; to; } = notification;

          debug if (debug_channel.transfer)Debug.print("Moving tokens");

          var finaltxtop_var = finaltxtop;
          let final_fee = notification.calculated_fee;



          // process transaction
          switch(notification.kind){
              case(#mint){
                  Utils.mint_balance(state, to, amount);
              };
              case(#burn){
                  Utils.burn_balance(state, from, amount);
              };
              case(#transfer){
                  Utils.transfer_balance(state, notification);

                  // burn fee
                  if(final_fee > 0){
                    switch(state.fee_collector){
                      case(null){
                        Utils.burn_balance(state, from, final_fee);
                      };
                      case(?val){
                        finaltxtop_var := switch(handleFeeCollector(final_fee, val, notification, finaltxtop)){
                          case(#ok(val)) val;
                          case(#err(err)){
                            if(bAwaited){
                              return #awaited(#Err(#GenericError({error_code= 6453; message=err})));
                            } else {
                              return #trappable(#Err(#GenericError({error_code= 6453; message=err})));
                            };
                          };
                        };
                      };
                    };
                  };
              };
          };

          

          // store transaction
          let index = handleAddRecordToLedger<system>(finaltx, finaltxtop_var, notification);

          let tx_final = Utils.req_to_tx(notification, index);

          if(calculated_fee > 0) setFeeCollectorBlock(index);
          

          //add trx for dedupe
          let trxhash = Blob.fromArray(RepIndy.hash_val(finaltx));

          debug if (debug_channel.transfer)Debug.print("attempting to add recent" # debug_show(trxhash, finaltx));

          Map.add<Blob, (Nat64, Nat)>(state.recent_transactions, Blob.compare, trxhash, (get_time64(), index));

          handleBroadcastToListeners<system>(tx_final, index);

          // ICRC-85: Track successful transaction for cycle sharing
          state.org_icdevs_ovs_fixed_state.activeActions := state.org_icdevs_ovs_fixed_state.activeActions + 1;

          handleCleanUp<system>();

          debug if (debug_channel.transfer)Debug.print("done transfer");
          if(bAwaited){
            #awaited(#Ok(index));
          } else {
            #trappable(#Ok(index));
          };
      };

      /// Notifies all registered listeners about a token transfer event.
      ///
      /// Parameters:
      /// - `tx_final`: The final transaction that occurred on the ledger.
      /// - `index`: The index of the final transaction in the ledger.
      ///
      /// Returns:
      /// - Nothing (unit type).
      ///
      /// Remarks:
      /// - The function goes through the list of registered token-transferred listeners and invokes their callback functions with the transaction details.
      public func handleBroadcastToListeners<system>(tx_final : Transaction, index: Nat) : (){
        debug if (debug_channel.transfer)Debug.print("attempting to call listeners" # debug_show(List.size(token_transferred_listeners)));
        for(thisItem in List.values(token_transferred_listeners)){
          thisItem.1<system>(tx_final, index);
        };
      };


      /// Manages the transfer of the transaction fee to the designated fee collector account.
      ///
      /// Parameters:
      /// - `final_fee`: The fee to be transferred.
      /// - `fee_collector`: The account information of the fee collector.
      /// - `notification`: Notification containing the information about the transfer request and calculated fee.
      /// - `txtop`: Optional top layer information for transaction logging.
      ///
      /// Returns:
      /// - `Result<?Value, Text>`: The result of the fee transfer operation containing updated top layer information or an error message.
      ///
      /// Remarks:
      /// - If fee collection is enabled, this function is responsible for transferring the fee and updating the transaction information with fee collector details.
      public func handleFeeCollector(final_fee: Nat, fee_collector : Account, notification: TransactionRequestNotification, txtop : ?Value) : Result.Result<?Value, Text> {
        var finaltxtop_var = txtop;
        if(final_fee > 0){
          if(state.fee_collector_emitted){
            finaltxtop_var := switch(Utils.insert_map(finaltxtop_var, "fee_col_block", #Nat(state.fee_collector_block))){
              case(#ok(val)) ?val;
              case(#err(err)) return #err("unreachable map addition" # debug_show(err));
            };
          } else {
            finaltxtop_var := switch(Utils.insert_map(finaltxtop_var, "fee_col", Utils.accountToValue(fee_collector))){
              case(#ok(val)) ?val;
              case(#err(err)) return #err("unreachable map addition" # debug_show(err));
            };
          };

          Utils.transfer_balance(state,{
            notification with
            kind = #transfer;
            to = fee_collector;
            amount = final_fee;
          });
        };

        #ok(finaltxtop_var);
      };

      /// Adds a transfer record to the ledger.
      ///
      /// Parameters:
      /// - `finaltx`: The transaction value to be added.
      /// - `finaltxtop`: Optional top layer data for the transaction log.
      /// - `notification`: The notification containing final transfer details.
      ///
      /// Returns:
      /// - `Nat`: The index of the added transaction record.
      ///
      /// Remarks:
      /// - Based on the environment settings, the transfer may be added to a local transaction log or processed through an external function for ledger recording.
      public func handleAddRecordToLedger<system>(finaltx : Value, finaltxtop: ?Value, notification: TransactionRequestNotification) : Nat{
        switch(environment.add_ledger_transaction){
            case(?add_ledger_transaction){
              add_ledger_transaction<system>(finaltx, finaltxtop);
            };
            case(null){
              let tx = Utils.req_to_tx(notification, List.size(state.local_transactions));
              add_local_ledger(tx);
            }
          };
      };

      /// Sets the block index for the fee collector, ensuring it is set only once.
      ///
      /// Parameters:
      /// - `index`: The index of the transaction block related to fee collection.
      ///
      /// Returns:
      /// - Nothing (unit type).
      ///
      /// Remarks:
      /// - This function is used when fee collection pertains to a specific block transaction, recording its occurrence.
      public func setFeeCollectorBlock(index : Nat){
        switch(state.fee_collector){
            case(?_val){
              
              if(state.fee_collector_emitted){} else {
                state.fee_collector_block := index;
                state.fee_collector_emitted := true;
              };
              
            };
            case(null){
            };
          };
      };

      // =====================================================================
      // ICRC-107: Fee Collector Management
      // =====================================================================

      /// Returns the current fee collector account.
      public func get_fee_collector() : GetFeeCollectorResult {
        #Ok(state.fee_collector);
      };

      /// Sets the fee collector via ICRC-107, creating a `107feecol` block in the ICRC-3 log.
      ///
      /// Authorization must be checked at the actor level before calling this.
      ///
      /// Parameters:
      /// - `caller`: The principal who initiated the call (recorded in the block).
      /// - `args`: SetFeeCollectorArgs with the fee_collector and created_at_time.
      ///
      /// Returns:
      /// - `SetFeeCollectorResult`: Ok(block_index) or Err(error).
      public func set_fee_collector<system>(caller : Principal, args : SetFeeCollectorArgs) : SetFeeCollectorResult {

        // Validate created_at_time (dedup window)
        let now = get_time64();
        let permitted_drift = state.permitted_drift;
        let transaction_window = state.transaction_window;

        if (args.created_at_time > now + permitted_drift) {
          return #Err(#CreatedInFuture({ ledger_time = now }));
        };

        if (now > args.created_at_time + transaction_window + permitted_drift) {
          return #Err(#TooOld);
        };

        // Build the tx Value for deduplication and block
        let txItems = List.empty<(Text, Value)>();
        List.add(txItems, ("mthd", #Text("107set_fee_collector")));
        List.add(txItems, ("ts", #Nat(Nat64.toNat(args.created_at_time))));
        List.add(txItems, ("caller", #Blob(Principal.toBlob(caller))));

        switch(args.fee_collector) {
          case(?fc) {
            List.add(txItems, ("fee_collector", Utils.accountToValue(fc)));
          };
          case(null) {};
        };

        let finaltx = #Map(List.toArray(txItems));

        // Check for duplicate
        let trxhash = Blob.fromArray(RepIndy.hash_val(finaltx));
        switch(Map.get<Blob, (Nat64, Nat)>(state.recent_transactions, Blob.compare, trxhash)){
          case(?existing) {
            return #Err(#Duplicate({ duplicate_of = existing.1 }));
          };
          case(null) {};
        };

        // Build the top-level block with btype
        let topItems = List.empty<(Text, Value)>();
        List.add(topItems, ("btype", #Text("107feecol")));
        List.add(topItems, ("ts", #Nat(Nat64.toNat(now))));
        let finaltxtop = #Map(List.toArray(topItems));

        // Update state
        state.fee_collector := args.fee_collector;
        state.fee_collector_emitted := false; // Reset so next block emits fee_col or fee_col_block appropriately

        // Record the block
        let index = switch(environment.add_ledger_transaction) {
          case(?add_ledger_transaction) {
            add_ledger_transaction<system>(finaltx, ?finaltxtop);
          };
          case(null) {
            // No ledger transaction handler - store locally
            0; // Should not happen in production
          };
        };

        // Mark the 107feecol block as the fee collector reference block
        state.fee_collector_block := index;
        state.fee_collector_emitted := true;

        // Record for dedup
        Map.add<Blob, (Nat64, Nat)>(state.recent_transactions, Blob.compare, trxhash, (now, index));

        #Ok(index);
      };

      // =====================================================================
      // ICRC-106: Index Principal
      // =====================================================================

      // LOCAL PATCH (ICRC-106 as text): ICRC-106 defines
      // `icrc106:index_principal` as "(text): The textual representation of
      // the principal of the associated index canister", and it "MUST
      // represent the textual form of the principal returned by
      // `icrc106_get_index_principal`" (ICRC-106.md lines 28 and 58).
      // Upstream stored `#Blob(Principal.toBlob p)`, so a client reading the
      // metadata as the standard says found no text. The setter now stores
      // `#Text(Principal.toText p)` and the getter reads it back. A ledger set
      // by an earlier build still holds the `#Blob` until the setter runs
      // again; the getter keeps answering it meanwhile.

      /// Returns the index principal from metadata, if set.
      public func get_icrc106_index_principal() : Icrc106GetResult {
        for (item in metadata().vals()) {
          if (item.0 == "icrc106:index_principal") {
            switch (item.1) {
              case (#Text(t)) return #Ok(Principal.fromText(t));
              // Stored by a build before the LOCAL PATCH above.
              case (#Blob(b)) return #Ok(Principal.fromBlob(b));
              case (_) {};
            };
          };
        };
        #Err(#IndexPrincipalNotSet);
      };

      /// Sets or clears the index principal, updating metadata.
      /// Authorization must be checked at the actor/mixin level.
      public func set_icrc106_index_principal(principal : ?Principal) {
        switch(principal) {
          case(?p) {
            // LOCAL PATCH (ICRC-106 as text): see `get_icrc106_index_principal`.
            ignore update_ledger_info([#Metadata("icrc106:index_principal", ?#Blob(Principal.toBlob(p)))]);
          };
          case(null) {
            ignore update_ledger_info([#Metadata("icrc106:index_principal", null)]);
          };
        };
      };

      // =====================================================================
      // ICRC-21: Consent Message Handler Registry
      // =====================================================================

      let _consent_handlers = List.empty<(Text, ConsentMessageHandler)>();

      /// Register a consent message handler for a given method name.
      /// Multiple standards (ICRC-2, ICRC-4, etc.) can register handlers for their own methods.
      public func register_consent_handler(method : Text, handler : ConsentMessageHandler) {
        // Replace existing handler for this method or add new one
        var found = false;
        let replacement = List.empty<(Text, ConsentMessageHandler)>();
        for ((m, h) in List.values(_consent_handlers)) {
          if (m == method) {
            List.add(replacement, (method, handler));
            found := true;
          } else {
            List.add(replacement, (m, h));
          };
        };
        if (not found) {
          List.add(_consent_handlers, (method, handler));
        } else {
          // Clear and repopulate from replacement
          List.clear(_consent_handlers);
          for (item in List.values(replacement)) {
            List.add(_consent_handlers, item);
          };
        };
      };

      /// Returns token info for consent message building.
      public func get_token_info() : TokenInfo {
        { symbol = symbol(); decimals = decimals(); fee = fee() };
      };

      /// Build a consent message by routing to the registered handler for the request's method.
      /// Handles validation (language, candid header) before dispatching.
      public func build_consent_message(request : ConsentMessageRequest) : ConsentMessageResponse {
        // Determine display spec: default to GenericDisplay if not specified
        let spec : { #GenericDisplay; #FieldsDisplay } = switch (request.user_preferences.device_spec) {
          case (null) #GenericDisplay;
          case (?s) s;
        };

        // Only support English for now
        let lang = request.user_preferences.metadata.language;
        if (lang != "en" and not Text.startsWith(lang, #text("en-"))) {
          return #Err(#GenericError({
            error_code = 1;
            description = "Unsupported language: " # lang # ". Only English (en) is supported.";
          }));
        };

        // Validate candid header before attempting from_candid (which traps on invalid headers)
        if (not hasValidCandidHeader(request.arg)) {
          return #Err(#UnsupportedCanisterCall({
            description = "Failed to decode arguments: invalid candid encoding";
          }));
        };

        // Find registered handler for this method
        let info = get_token_info();
        for ((method, handler) in List.values(_consent_handlers)) {
          if (method == request.method) {
            return handler(request, info, spec);
          };
        };

        #Err(#UnsupportedCanisterCall({
          description = "No consent message available for method: " # request.method;
        }));
      };

      /// Checks if the ledger has too many accounts and triggers an account cleanup if necessary.
      ///
      /// Returns:
      /// - Nothing (unit type).
      ///
      /// Remarks:
      /// - If the ledger grows beyond 'max_accounts', older small balances are transferred to the minting account to tidy up the ledger.
      public func handleCleanUp<system>(){
        debug if (debug_channel.transfer)Debug.print("cleaning");
        cleanUpRecents();
        switch(state.cleaning_timer){
          case(null){ //only need one active timer
            debug if(debug_channel.transfer) Debug.print("setting clean up timer");
            state.cleaning_timer := ?Timer.setTimer<system>(#seconds(0), checkAccounts);
          };
          case(_){}
        };
      };

      /// Evaluates additional transfer validation rules if provided.
      ///
      /// Parameters:
      /// - `txMap`: Value representing the transfer.
      /// - `txTopMap`: Optional additional data for the transfer log.
      /// - `pre_notification`: The pre-transfer notification containing initial transfer information.
      /// - `canTransfer`: Optional rules to validate the transfer further.
      ///
      /// Returns:
      /// - A star-patterned response that may either contain the updated data or errors.
      ///
      /// Possible Responses:
      /// - Returns the original data if no additional rules are provided.
      /// - On calling a synchronous validation function, returns the result or any encountered error.
      /// - On calling an asynchronous validation function, either returns the result or goes into a waiting state for further handling.
      public func handleCanTransfer(txMap : Value, txTopMap: ?Value, pre_notification: TransactionRequestNotification, canTransfer : CanTransfer) : async* Star.Star<(Value, ?Value,  TransactionRequestNotification), MigrationTypes.Current.TransferResult> {
        debug if (debug_channel.transfer) Debug.print("in handleCanTransfer awaited something " );
        switch(canTransfer){
            case(null){
              #trappable((txMap, txTopMap, pre_notification));
            };
            case(?#Sync(remote_func)){
              switch(remote_func<system>(txMap, txTopMap, pre_notification)){
                case(#ok(val)) return #trappable((val.0,val.1,val.2));
                case(#err(tx)) return #err(#trappable(#Err(#GenericError({error_code= 6453; message=tx}))));
              };
            };
            case(?#Async(remote_func)){
              debug if (debug_channel.transfer) Debug.print("in handleCanTransfer awaiting something ");
              switch(await* remote_func(txMap, txTopMap, pre_notification)){
                case(#trappable(val)) #trappable((val.0,val.1,val.2));
                case(#awaited(val)){
                  #awaited((val.0,val.1,val.2));
                };
                case(#err(#awaited(tx))){
                  debug if (debug_channel.transfer) Debug.print("awaited error " # debug_show(tx));
                  return #err(#awaited(#Err(#GenericError({error_code= 6453; message=tx}))));
                };
                case(#err(#trappable(tx))){
                  debug if (debug_channel.transfer) Debug.print("trappable error " # debug_show(tx));
                  return #err(#trappable(#Err(#GenericError({error_code= 6453; message=tx}))));
                };
              };
            };
          };
      };

      /// `mint`
      ///
      /// Allows the minting account to create new tokens and add them to a specified beneficiary account.
      ///
      /// Parameters:
      /// - `args`: Minting arguments including the destination account and the amount to mint.
      /// - `caller`: The principal of the caller requesting the mint operation.
      ///
      /// Returns:
      /// `TransferResult`: The result of the mint operation, either indicating success or providing error information.
      ///
      /// Warning: This function traps. we highly suggest using transfer_tokens to manage the returns and awaitstate change
      public func mint(caller : Principal, args : MigrationTypes.Current.Mint) : async* MigrationTypes.Current.TransferResult {
        switch( await* mint_tokens(caller, args)){
          case(#trappable(val)) val;
          case(#awaited(val)) val;
          case(#err(#trappable(err))) Runtime.trap(err);
          case(#err(#awaited(err))) Runtime.trap(err);
        };
      };

      /// `mint`
      ///
      /// Allows the minting account to create new tokens and add them to a specified beneficiary account.
      ///
      /// Parameters:
      /// - `args`: Minting arguments including the destination account and the amount to mint.
      /// - `caller`: The principal of the caller requesting the mint operation.
      ///
      /// Returns:
      /// `TransferResult`: The result of the mint operation, either indicating success or providing error information.
      public func mint_tokens(caller : Principal, args : MigrationTypes.Current.Mint) : async* Star.Star<MigrationTypes.Current.TransferResult, Text> {

         
          if (caller != state.minting_account.owner) {
              return #trappable(#Err(
                  #GenericError {
                      error_code = 401;
                      message = "Unauthorized: Only the minting_account can mint tokens.";
                  },
              ));
          };

          let transfer_args : MigrationTypes.Current.TransferArgs = {
              args with from_subaccount = state.minting_account.subaccount;
              fee = null;
          };
          //Note: canTransfer hook is skipped for minting — authorization is at the actor level.
          await* transfer_tokens(caller, transfer_args, false, null);
      };

      /// `burn`
      ///
      /// Allows an account to burn tokens by transferring them to the minting account and removing them from the total token supply.
      ///
      /// Parameters:
      /// - `args`: Burning arguments including the amount to burn.
      /// - `caller`: The principal of the caller requesting the burn operation.
      ///
      /// Returns:
      /// `TransferResult`: The result of the burn operation, either indicating success or providing error information.
      /// Warning: This function traps. we highly suggest using transfer_tokens to manage the returns and awaitstate change
      public func burn(caller : Principal, args : MigrationTypes.Current.BurnArgs,) : async* MigrationTypes.Current.TransferResult {
        switch( await*  burn_tokens(caller, args, false)){
          case(#trappable(val)) val;
          case(#awaited(val)) val;
          case(#err(#trappable(err))) Runtime.trap(err);
          case(#err(#awaited(err))) Runtime.trap(err);
        };
      };

      /// `burn`
      ///
      /// Allows an account to burn tokens by transferring them to the minting account and removing them from the total token supply.
      ///
      /// Parameters:
      /// - `args`: Burning arguments including the amount to burn.
      /// - `caller`: The principal of the caller requesting the burn operation.
      /// - `system_override`: A boolean that allows bypassing the minimum burn amount check if true. Reserved for system operations.
      ///
      /// Returns:
      /// `TransferResult`: The result of the burn operation, either indicating success or providing error information.
      public func burn_tokens( caller : Principal, args : MigrationTypes.Current.BurnArgs, system_override: Bool) : async* Star.Star<MigrationTypes.Current.TransferResult, Text> {
          let transfer_args : MigrationTypes.Current.TransferArgs = {
              args with 
              to = state.minting_account;
              fee : ?Balance = null;
          };

          await* transfer_tokens(caller, transfer_args, system_override, null);
      };

      /// # testMemo
    ///
    /// Validates the size of the memo field to ensure it doesn't exceed the allowed number of bytes.
    ///
    /// ## Parameters
    ///
    /// - `val`: `?Blob` - The memo blob to be tested. This parameter can be `null` if no memo is provided.
    ///
    /// ## Returns
    ///
    /// `??Blob` - An optional optional blob which will return `null` if the blob size exceeds the
    /// allowed maximum, or the blob itself if it's of a valid size.
    ///
    /// ## Remarks
    ///
    /// This function compares the size of the memo blob against the `max_memo` limit defined in the ledger's environment state.
    ///
    public func testMemo(val : ?Blob) : ??Blob{
      switch(val){
        case(null) return ?null;
        case(?val){
          let max_memo = state.max_memo;
          if(val.size() > max_memo){
            return null;
          };
          return ??val;
        };
      };
    };

      /// `is_too_old`
      ///
      /// Checks whether the `created_at_time` of a transfer request is too old according to the ledger's permitted time range.
      ///
      /// Parameters:
      /// - `created_at_time`: The timestamp denoting when the transfer was initiated.
      ///
      /// Returns:
      /// `Bool`: True if the transaction is considered too old, false otherwise.
      public func is_too_old(created_at_time : Nat64) : Bool {
          debug if (debug_channel.validation) Debug.print("testing is_too_old");
          let current_time : Nat64  = get_time64();
          debug if (debug_channel.validation) Debug.print("current time is" # debug_show(current_time,state.transaction_window ,state.permitted_drift ));
          // Safe subtraction to avoid overflow when current_time is very small (e.g., in tests)
          let time_threshold = state.transaction_window + state.permitted_drift;
          if (current_time < time_threshold) {
            // If current_time is less than the threshold, everything is considered valid (not too old)
            return false;
          };
          let lower_bound = current_time - time_threshold;
          created_at_time < lower_bound;
      };

      /// `is_in_future`
      ///
      /// Determines if the `created_at_time` of a transfer request is set in the future relative to the ledger's clock.
      ///
      /// Parameters:
      /// - `created_at_time`: The timestamp to validate against the current ledger time.
      ///
      /// Returns:
      /// `Bool`: True if the timestamp is in the future, false otherwise.
      public func is_in_future(created_at_time : Nat64) : Bool {
          debug if (debug_channel.validation) Debug.print("testing is_in_future" # debug_show(created_at_time, state.permitted_drift, get_time64()));
          let current_time : Nat64  = get_time64();
          let upper_bound = current_time + state.permitted_drift;
          created_at_time > upper_bound;
      };

    /// `find_dupe`
    ///
    /// Searches for a duplicate transaction using the provided hash.
    ///
    /// Parameters:
    /// - `trxhash`: The hash of the transaction to find.
    ///
    /// Returns:
    /// - `?Nat`: An optional index of the duplicated transaction or null if no duplicate is found.
    public func find_dupe(trxhash: Blob) : ?Nat {
      switch(Map.get<Blob, (Nat64,Nat)>(state.recent_transactions, Blob.compare, trxhash)){
          case(?found){
            if(found.0 + state.permitted_drift + state.transaction_window > get_time64()){
              return ?found.1;
            };
          };
          case(null){};
        };
        return null;
    };

    /// `deduplicate`
    ///
    /// Checks if a transaction request is a duplicate of an existing transaction based on the hashing of its contents.
    /// If a duplicate is found, it returns an error with the transaction index.
    ///
    /// Parameters:
    /// - `tx_req`: The transaction request to check for duplication.
    ///
    /// Returns:
    /// - `Result<(), Nat>`: Returns `#ok` if no duplicate is found, or `#err` with the index of the duplicate.
    public func deduplicate(tx_req : MigrationTypes.Current.TransactionRequest) : Result.Result<(), Nat> {

      let trxhash = Blob.fromArray(RepIndy.hash_val(transfer_req_to_value(tx_req)));
      debug if (debug_channel.validation) Debug.print("attempting to deduplicate" # debug_show(trxhash, tx_req));

      switch(find_dupe(trxhash)){
        case(?found){
          return #err(found);
        };
        case(null){};
      };
        #ok();
    };

    /// `cleanUpRecents`
    ///
    /// Iterates through and removes transactions from the 'recent transactions' index that are no longer within the permitted drift.
    public func cleanUpRecents() : (){
      //LOCAL PATCH (see vendor/README.md): collect keys to delete first to avoid modifying the
      //map while iterating it. Deleting during `Map.entries` corrupts mo:core's
      //B-tree iterator and traps with a Natural subtraction underflow in
      //core/src/Map.mo, which rolls back the whole transfer that triggered the
      //cleanup. Same shape icrc2-mo already uses in `cleanUpApprovals`.
      let now = get_time64();
      let expired = List.empty<Blob>();
      label clean for(thisItem in Map.entries(state.recent_transactions)){
        if(thisItem.1.0 + state.transaction_window < now){
          //we can remove this item;
          List.add(expired, thisItem.0);
        } else {
          //items are inserted in order in this map so as soon as we hit a still valid item, the rest of the list should still be valid as well
          break clean;
        };
      };
      for(k in List.values(expired)){
        ignore Map.take(state.recent_transactions, Blob.compare, k);
      };
    };

     /// `checkAccounts`
    ///
    /// Iterates over the ledger accounts and transfers balances below a set threshold to the minting account.
    /// It's meant to clean up small balances and is called periodically according to a set timer.
    public func checkAccounts() : async (){
      debug if(debug_channel.accounts) Debug.print("in check accounts");
      if(Map.size(state.accounts) > state.max_accounts){
        debug if(debug_channel.accounts) Debug.print("cleaning accounts");
        let comp = func(a : (Account, Nat), b: (Account,Nat)) : Order.Order{
          return Nat.compare(a.1, b.1);
        };
        label clean for(thisItem in Iter.sort(Map.entries(state.accounts), comp)){
          debug if(debug_channel.accounts) Debug.print("inspecting item" # debug_show(thisItem));
          let result = await* transfer_tokens(thisItem.0.owner, {
            from_subaccount = thisItem.0.subaccount;
            to = state.minting_account;
            amount = thisItem.1;
            fee = null;
            memo = ?Text.encodeUtf8("clean");
            created_at_time = null;
          }, true, null);

          debug if(debug_channel.accounts) Debug.print("inspecting result " # debug_show(result));

          switch(result){
            case(#err(_)){
              //don't waste cycles. something is wrong
              //Note: consider adding an error notification callback in a future version
              return;
            };
            case(_){};
          };

          if(Map.size(state.accounts) <= state.settle_to_accounts ){break clean};
        };
      };
    };

    /// `validate_fee`
    ///
    /// Validates the fee specified in a transaction request against the calculated fee based on the ledger's fee policy.
    /// Behavior depends on the fee_validation_mode in Environment:
    /// - #Strict (default): Per ICRC-1 spec, fee must exactly match (returns BadFee otherwise)
    /// - #Tolerant: Fee can be greater than or equal to the calculated fee
    ///
    /// Parameters:
    /// - `calculated_fee`: The fee calculated by the ledger for a transaction.
    /// - `opt_fee`: The optional fee specified in the transaction request by the user.
    ///
    /// Returns:
    /// - `Bool`: True if the fee is valid according to the validation mode, false otherwise.
    public func validate_fee(
        calculated_fee : MigrationTypes.Current.Balance,
        opt_fee : ?MigrationTypes.Current.Balance,
    ) : Bool {
        let mode = switch(do?{environment.advanced!.fee_validation_mode!}) {
            case (?m) m;
            case (null) #Strict; // Default to ICRC-1 compliant strict matching
        };
        
        debug if (debug_channel.validation) Debug.print("validate_fee: calculated=" # debug_show(calculated_fee) # " opt_fee=" # debug_show(opt_fee) # " mode=" # debug_show(mode));
        
        switch (opt_fee) {
            case (?tx_fee) {
                switch (mode) {
                    case (#Strict) {
                        // Per ICRC-1 spec, fee must exactly match when specified
                        if (tx_fee != calculated_fee) {
                            debug if (debug_channel.validation) Debug.print("validate_fee: STRICT FAIL - tx_fee=" # debug_show(tx_fee) # " != calculated_fee=" # debug_show(calculated_fee));
                            return false;
                        };
                    };
                    case (#Tolerant) {
                        // Allow fees >= calculated fee for backwards compatibility
                        if (tx_fee < calculated_fee) {
                            return false;
                        };
                    };
                };
            };
            case (null) {};
        };

        true;
    };

    /// `get_fee`
    ///
    /// Retrieves the appropriate transfer fee for a given transaction request.
    ///
    /// Parameters:
    /// - `request`: The transfer request which includes the amount and potential fee parameters.
    ///
    /// Returns:
    /// - `Nat`: The required transfer fee for the specified transaction request.
    public func get_fee(request: TransferArgs) : Nat {
      let base_fee = get_expected_fee(request);
      // In tolerant mode or when no user fee is specified, use base_fee
      // When user fee is specified, take the max for the actual charge
      switch(request.fee){
        case(null) base_fee;
        case(?user_fee) Nat.max(base_fee, user_fee);
      };
    };

    /// # get_expected_fee
    ///
    /// Gets the ledger's expected/base fee for a transaction, without considering user-provided fees.
    /// This is used for ICRC-1 spec compliance validation where the fee must exactly match.
    ///
    /// Parameters:
    /// - `request`: The transfer arguments containing transaction details.
    ///
    /// Returns:
    /// - `Nat`: The base ledger fee (not influenced by user-provided fee).
    public func get_expected_fee(request: TransferArgs) : Nat {
      switch(state._fee){
        case(?fee){
          switch(fee){
            case(#Fixed(val)) val;
            case(#Environment){
              switch(do?{environment.advanced!.get_fee!}){
                case(?get_fee_env) get_fee_env(state, environment, request);
                case(_) DEFAULT_FEE;
              };
            };
          };
        };
        case(null) DEFAULT_FEE;
      };
    };

    /// # testCreatedAt
    ///
    /// Validates a provided creation timestamp to ensure it's neither too old nor too far into the future,
    /// relative to the ledger's time and a permissible drift amount.
    ///
    /// ## Parameters
    ///
    /// - `val`: `?Nat64` - The creation timestamp to be tested. Can be `null` for cases when the timestamp is not provided.
    /// - `environment`: `Environment` - The environment settings that provide context such as permitted drift and the current ledger time.
    ///
    /// ## Returns
    ///
    /// A variant indicating success or specific error conditions:
    /// - `#ok`: `?Nat64` - An optional containing the provided timestamp if valid.
    /// - `#Err`: `{#TooOld; #InTheFuture: Nat64}` - Error variant indicating if the timestamp is too old or too far in the future.
    ///
    /// ## Remarks
    ///
    /// This function uses the ledger's permissible drift value from the environment to assess timestamp validity.
    ///
    public func testCreatedAt(val : ?Nat64) : {
      #ok: ?Nat64;
      #Err: {#TooOld; #InTheFuture: Nat64};
      
    }{
      switch(val){
        case(null) return #ok(null);
        case(?val){
          if(is_in_future(val)){
            return #Err(#InTheFuture(get_time64()));
          };
          if(is_too_old(val)){
            return #Err(#TooOld);
          };
          return #ok(?val);
        };
      };
    };

    /// `validate_request`
    ///
    /// Perform checks against a transfer request to ensure it meets all the criteria for a valid and secure transfer.
    /// Checks include account validation, memo size, balance sufficiency, mint constraints, burn constraints, and deduplication.
    ///
    /// Parameters:
    /// - `tx_req`: The transaction request to validate.
    /// - `calculated_fee`: The calculated fee for the transaction.
    /// - `system_override`: If true, allows bypassing certain checks for system-level operations.
    ///
    /// Returns:
    /// - `Result<(), TransferError>`: Returns `#ok` if the request is valid, or `#err` with the appropriate error if any check fails.
    public func validate_request(
        tx_req : MigrationTypes.Current.TransactionRequest,
        calculated_fee : MigrationTypes.Current.Balance,
        system_override : Bool
    ) : Result.Result<(), MigrationTypes.Current.TransferError> {

        debug if (debug_channel.validation) Debug.print("in validate_request");

        // Note: Self-transfers (from == to) are allowed per DFINITY reference implementation
        // They result in a fee being paid with no net balance change

        if (not Account.validate(tx_req.from)) {
            return #err(
                #GenericError({
                    error_code = 2;
                    message = "Invalid account entered for sender. "  # debug_show(tx_req.from);
                }),
            );
        };

        if (not Account.validate(tx_req.to)) {
            return #err(
                #GenericError({
                    error_code = 3;
                    message = "Invalid account entered for recipient " # debug_show(tx_req.to);
                }),
            );
        };

        debug if (debug_channel.validation) Debug.print("Checking memo");

        if (testMemo(tx_req.memo) == null) {
            return #err(
                #GenericError({
                    error_code = 4;
                    message = "Memo must not be more than " # debug_show(state.max_memo) # " bytes";
                }),
            );
        };

        if (tx_req.amount == 0) {
            return #err(
                #GenericError({
                    error_code = 5;
                    message = "Amount must be greater than 0";
                }),
            );
        };

        debug if (debug_channel.validation) Debug.print("starting filter");
        label filter switch (tx_req.kind) {
            case (#transfer) {
                debug if (debug_channel.validation) Debug.print("validating fee");
                // Get the expected ledger fee (without user fee influence) for validation
                let expected_fee = get_expected_fee({
                    to = tx_req.to;
                    from_subaccount = tx_req.from.subaccount;
                    amount = tx_req.amount;
                    fee = null; // Get base fee without user influence
                    memo = tx_req.memo;
                    created_at_time = tx_req.created_at_time;
                });
                debug if (debug_channel.validation) Debug.print("expected_fee=" # debug_show(expected_fee) # " user_fee=" # debug_show(tx_req.fee));
                if (not validate_fee(expected_fee, tx_req.fee)) {
                    return #err(
                        #BadFee {
                            expected_fee = expected_fee;
                        },
                    );
                };

                let final_fee = switch(tx_req.fee){
                  case(null) calculated_fee;
                  case(?val) val;
                };

                debug if (debug_channel.validation) Debug.print("getting balance");
                let balance : MigrationTypes.Current.Balance = Utils.get_balance(
                    state.accounts,
                    tx_req.from,
                );

                debug if (debug_channel.validation) Debug.print("found balance" # debug_show(balance));

                if (tx_req.amount + final_fee > balance) {
                    return #err(#InsufficientFunds { balance });
                };
            };

            case (#mint) {

                // Per ICRC-1 spec: mint transactions have no fee
                // If fee is specified, it must be 0 (calculated_fee is 0 for mints)
                if (not validate_fee(calculated_fee, tx_req.fee)) {
                    return #err(
                        #BadFee {
                            expected_fee = calculated_fee;
                        },
                    );
                };

                let ?max_supply = state.max_supply else break filter;
                
                if (max_supply < state._minted_tokens + tx_req.amount) {
                    let remaining_tokens = (max_supply - state._minted_tokens) : Nat;

                    return #err(
                        #GenericError({
                            error_code = 6;
                            message = "Cannot mint more than " # Nat.toText(remaining_tokens) # " tokens";
                        }),
                    );
                };
                
            };
            case (#burn) {

                // Per ICRC-1 spec: burn transactions have no fee
                // If fee is specified, it must be 0 (calculated_fee is 0 for burns)
                if (not validate_fee(calculated_fee, tx_req.fee)) {
                    return #err(
                        #BadFee {
                            expected_fee = calculated_fee;
                        },
                    );
                };

                let balance : MigrationTypes.Current.Balance = Utils.get_balance(
                    state.accounts,
                    tx_req.from,
                );

                if (balance < tx_req.amount) {
                    return #err(#InsufficientFunds { balance });
                };


                
                let ?min_burn_amount = state.min_burn_amount else break filter;
              
                if (system_override == false and tx_req.to == state.minting_account and tx_req.amount < min_burn_amount) {
                    return #err(
                        #BadBurn { min_burn_amount = min_burn_amount },
                    );
                };
            };
        };

        debug if (debug_channel.validation) Debug.print("testing Time");
        switch (testCreatedAt(tx_req.created_at_time)) {
            case (#ok(val)) {
              switch(val){
                case(null){};
                case(?val){
                  //according to icrc-1, if created at time is null, don't deduplicate.
                  switch (deduplicate(tx_req)) {
                      case (#err(tx_index)) {
                          return #err(
                              #Duplicate {
                                  duplicate_of = tx_index;
                              },
                          );
                      };
                      case (_) {};
                  };
                };
              };
            };
            case (#Err(#TooOld)) {
              return #err(#TooOld);
            };
            case(#Err(#InTheFuture(_val))){
              return #err(
                  #CreatedInFuture {
                      ledger_time = get_time64();
                  },
              );
            };
        };

        debug if (debug_channel.validation) Debug.print("done validate");
        #ok();
    };


    /// `transfer_req_to_value`
    ///
    /// Converts a transaction request into a `Value` type that can be processed by an ICRC-3 transaction log.
    ///
    /// Parameters:
    /// - `request`: The transaction request to convert.
    ///
    /// Returns:
    /// - `Value`: The transaction request converted to a `Value` type suitable for logs.
    public func transfer_req_to_value(request: TransactionRequest) : Value {
      let trx = List.empty<(Text, Value)>();

      List.add(trx, ("amt",#Nat(request.amount)));

      switch(request.kind){
        case(#mint) {
          List.add(trx, ("op",#Text("mint")));
          List.add(trx, ("to", Utils.accountToValue(request.to)));
        };
        case(#burn){
          List.add(trx, ("op",#Text("burn")));
          List.add(trx, ("from", Utils.accountToValue(request.from)));
        };
        case(#transfer){
          List.add(trx, ("op",#Text("xfer")));
          List.add(trx, ("to", Utils.accountToValue(request.to)));
          List.add(trx, ("from", Utils.accountToValue(request.from)));
        };
      };

      switch(request.fee){
        case(null){
        };
        case(?val){
          List.add(trx, ("fee", #Nat(val)));
        };
      };

      switch(request.created_at_time){
        case(null){
        };
        case(?val){
          List.add(trx, ("ts", #Nat(Nat64.toNat(val))));
        };
      };

      switch(request.memo){
        case(null){
        };
        case(?val){
          List.add(trx, ("memo", #Blob(val)));
        };
      };

      let vTrx = #Map(List.toArray(trx));

      return vTrx
    };

    /// `get_time64`
    ///
    /// Retrieves the current time in nanoseconds in a 64-bit unsigned integer format.
    ///
    /// Returns:
    /// - `Nat64`: The current ledger time.
    public func get_time64() : Nat64{
      return Utils.get_time64();
    };

    /// `transfer_req_to_value_top`
    ///
    /// Converts a transaction request with an additional layer that includes calculated fee information, meant for ICRC-3 transaction log top layer.
    ///
    /// Parameters:
    /// - `calculated_fee`: The calculated fee for the transaction to include.
    /// - `request`: The transaction request to convert.
    ///
    /// Returns:
    /// - `Value`: The transaction request converted to a top layer `Value` type suitable for logs.
    public func transfer_req_to_value_top(calculated_fee : MigrationTypes.Current.Balance, request: TransactionRequest) : Value {
      let trx = List.empty<(Text, Value)>();

      // NOTE: We do NOT include `btype` for standard operations (mint, burn, xfer).
      // DFINITY's index-ng and Rosetta use `tx.op` for standard operations.
      // The `btype` field is only used for ICRC-107 fee collector blocks.
      // See: https://github.com/dfinity/ic/blob/main/rs/rosetta-api/icrc1/src/common/storage/types.rs

      switch(request.fee){
        case(null){
          if(calculated_fee > 0){
            List.add(trx, ("fee", #Nat(calculated_fee)));
          };
        };
        case(_){};
      };

      List.add(trx, ("ts", #Nat(Nat64.toNat(get_time64()))));

      let vTrx = #Map(List.toArray(trx));

      return vTrx
    };

    //events

    type Listener<T> = (Text, T);

      /// Generic function to register a listener.
      ///
      /// Parameters:
      ///     namespace: Text - The namespace identifying the listener.
      ///     remote_func: T - A callback function to be invoked.
      ///     listeners: List<Listener<T>> - The list of listeners.
      public func register_listener<T>(namespace: Text, remote_func: T, listeners: List.List<Listener<T>>) {
        let listener: Listener<T> = (namespace, remote_func);
        switch(List.indexOf<Listener<T>>(listeners, func(a: Listener<T>, b: Listener<T>) : Bool {
          Text.equal(a.0, b.0);
        }, listener)){
          case(?index){
            List.put<Listener<T>>(listeners, index, listener);
          };
          case(null){
            List.add<Listener<T>>(listeners, listener);
          };
        };
      };

    /// `register_listener`
    ///
    /// Registers a new listener or updates an existing one in the provided `listeners` vector.
    ///
    /// Parameters:
    /// - `namespace`: A unique namespace used to identify the listener.
    /// - `remote_func`: The listener's callback function.
    /// - `listeners`: The vector of existing listeners that the new listener will be added to or updated in.
    public func register_token_transferred_listener(namespace: Text, remote_func : TokenTransferredListener){
      register_listener<TokenTransferredListener>(namespace, remote_func, token_transferred_listeners);
    };

    

    

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
};
