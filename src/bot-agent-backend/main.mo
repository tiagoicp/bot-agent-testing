import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import Order "mo:core/Order";
import AdminService "./services/admin-service";
import AgentService "./services/agent-service";
import ConversationService "./services/conversation-service";
// import LLMWrapper "./wrappers/llm-wrapper";

persistent actor {
  public type LLMProvider = {
    #groq;
  };

  public type ApiKeyKey = {
    agentId : Nat;
    provider : LLMProvider;
  };

  // Comparator for (Nat, Text) tuples
  func compareNatTextTuple(a : (Nat, Text), b : (Nat, Text)) : Order.Order {
    switch (Nat.compare(a.0, b.0)) {
      case (#equal) { Text.compare(a.1, b.1) };
      case (other) { other };
    };
  };

  // Get API key for a specific caller, agent, and provider
  private func getApiKeyForCaller(principal : Principal, agentId : Nat, provider : LLMProvider) : ?Text {
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

  var agents = Map.empty<Nat, AgentService.Agent>();
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];
  var conversations = Map.empty<ConversationService.ConversationKey, List.List<ConversationService.Message>>();
  var apiKeys = Map.empty<Principal, Map.Map<(Nat, Text), Text>>(); // Principal -> (agentId, provider_name) -> api_key

  // Get conversation history
  public shared ({ caller }) func getConversation(agentId : Nat) : async {
    #ok : [ConversationService.Message];
    #err : Text;
  } {
    ConversationService.getConversation(conversations, caller, agentId);
  };

  public shared ({ caller }) func talkTo(agentId : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else {

      ConversationService.addMessageToConversation(
        conversations,
        caller,
        agentId,
        {
          author = #user;
          content = message;
          timestamp = Time.now();
        },
      );

      // decide which tool?
      // for now, just mo:llm

      // call the tool
      // call chat mo:llm with the conversation history
      // Initialize LLM wrapper with default model
      // commenting, since there isn't a local / test version of llm canister
      // let llmWrapper = LLMWrapper.LLMWrapper(null);
      // var response = await llmWrapper.chat(message);

      // get api key
      let apiKey = getApiKeyForCaller(caller, agentId, #groq);

      var response = "Hello! This is a placeholder response from the AI agent.";

      // evaluate response and decide to terminate loop or continue
      // for now, just terminate

      // Store and Deliver response
      ConversationService.addMessageToConversation(
        conversations,
        caller,
        agentId,
        {
          author = #agent;
          content = response;
          timestamp = Time.now();
        },
      );

      #ok("Response from AI Agent " # debug_show (agentId) # ": " # response);
    };
  };

  // Create a new agent
  public shared ({ caller }) func createAgent(name : Text, provider : AgentService.Provider, model : Text) : async {
    #ok : Nat;
    #err : Text;
  } {
    let (result, newId) = AgentService.createAgent(name, provider, model, caller, admins, agents, nextAgentId);
    nextAgentId := newId;
    result;
  };

  // Read/Get an agent
  public query func getAgent(id : Nat) : async ?AgentService.Agent {
    AgentService.getAgent(id, agents);
  };

  // Update an agent
  public shared ({ caller }) func updateAgent(id : Nat, newName : ?Text, newProvider : ?AgentService.Provider, newModel : ?Text) : async {
    #ok : Bool;
    #err : Text;
  } {
    AgentService.updateAgent(id, newName, newProvider, newModel, caller, admins, agents);
  };

  // Delete an agent
  public shared ({ caller }) func deleteAgent(id : Nat) : async {
    #ok : Bool;
    #err : Text;
  } {
    AgentService.deleteAgent(id, caller, admins, agents);
  };

  // List all agents
  public query func listAgents() : async [AgentService.Agent] {
    AgentService.listAgents(agents);
  };

  // Add a new admin
  public shared ({ caller }) func addAdmin(newAdmin : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    admins := AdminService.initializeFirstAdmin(caller, admins);

    let validation = AdminService.validateNewAdmin(newAdmin, caller, admins);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        admins := AdminService.addAdminToList(newAdmin, admins);
        #ok(());
      };
    };
  };

  // Get list of admins
  public query func getAdmins() : async [Principal] {
    admins;
  };

  // Check if caller is admin
  public shared ({ caller }) func isCallerAdmin() : async Bool {
    AdminService.isAdmin(caller, admins);
  };

  // Store an API key for an agent
  public shared ({ caller }) func storeApiKey(agentId : Nat, provider : LLMProvider, apiKey : Text) : async {
    #ok : ();
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else {
      let providerName = switch (provider) {
        case (#groq) { "groq" };
      };
      let key = (agentId, providerName);

      // Get or create the caller's API key map
      let callerKeyMap = switch (Map.get(apiKeys, Principal.compare, caller)) {
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
      Map.add(apiKeys, Principal.compare, caller, callerKeyMap);

      #ok(());
    };
  };

  // Get caller's own API keys
  public shared ({ caller }) func getMyApiKeys() : async {
    #ok : [(Nat, Text)];
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else {
      switch (Map.get(apiKeys, Principal.compare, caller)) {
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
};
