import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Text "mo:core/Text";
import List "mo:core/List";
import Order "mo:core/Order";
import Nat "mo:core/Nat";

module {
  public type LLMProvider = {
    #groq;
  };

  public type ApiKeyKey = {
    agentId : Nat;
    provider : LLMProvider;
  };

  // Comparator for (Nat, Text) tuples
  public func compareNatTextTuple(a : (Nat, Text), b : (Nat, Text)) : Order.Order {
    switch (Nat.compare(a.0, b.0)) {
      case (#equal) { Text.compare(a.1, b.1) };
      case (other) { other };
    };
  };

  // Get API key for a specific caller, agent, and provider
  public func getApiKeyForCallerAndAgent(
    apiKeys : Map.Map<Principal, Map.Map<(Nat, Text), Text>>,
    principal : Principal,
    agentId : Nat,
    provider : LLMProvider,
  ) : ?Text {
    let providerName = switch (provider) {
      case (#groq) { "groq" };
    };
    let key = (agentId, providerName);

    switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        null;
      };
      case (?callerKeyMap) {
        Map.get(callerKeyMap, compareNatTextTuple, key);
      };
    };
  };

  // Store an API key for an agent
  public func storeApiKey(
    apiKeys : Map.Map<Principal, Map.Map<(Nat, Text), Text>>,
    principal : Principal,
    agentId : Nat,
    provider : LLMProvider,
    apiKey : Text,
  ) : (
    Map.Map<Principal, Map.Map<(Nat, Text), Text>>,
    {
      #ok : ();
      #err : Text;
    },
  ) {
    let providerName = switch (provider) {
      case (#groq) { "groq" };
    };
    let key = (agentId, providerName);

    // Get or create the caller's API key map
    let callerKeyMap = switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        Map.empty<(Nat, Text), Text>();
      };
      case (?existingMap) {
        existingMap;
      };
    };

    // Add the API key to the caller's map
    Map.add(callerKeyMap, compareNatTextTuple, key, apiKey);

    // Store the updated map back
    Map.add(apiKeys, Principal.compare, principal, callerKeyMap);

    (apiKeys, #ok(()));
  };

  // Get caller's own API keys
  public func getMyApiKeys(
    apiKeys : Map.Map<Principal, Map.Map<(Nat, Text), Text>>,
    principal : Principal,
  ) : {
    #ok : [(Nat, Text)];
    #err : Text;
  } {
    switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        #ok([]);
      };
      case (?callerKeyMap) {
        let keysIter = Map.keys(callerKeyMap);
        var keysList = List.empty<(Nat, Text)>();
        for (key in keysIter) {
          List.add(keysList, key);
        };
        #ok(List.toArray(keysList));
      };
    };
  };
};
