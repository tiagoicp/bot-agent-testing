import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import AdminManagement "./admin-management";
import AgentManagement "./agent-management";

persistent actor {
  var agents = Map.empty<Nat, AgentManagement.Agent>();
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];
  var conversations = Map.empty<ConversationKey, List.List<Message>>();

  type Message = {
    author : {
      #user : Principal;
      #agent : Nat;
    };
    content : Text;
    timestamp : Int;
  };

  type ConversationKey = (Principal, Nat);

  // Comparison function for ConversationKey
  private func conversationKeyCompare(a : ConversationKey, b : ConversationKey) : {
    #less;
    #equal;
    #greater;
  } {
    switch (Principal.compare(a.0, b.0)) {
      case (#equal) {
        Nat.compare(a.1, b.1);
      };
      case (other) {
        other;
      };
    };
  };

  // Add a message to a conversation
  private func addMessageToConversation(principal : Principal, agentId : Nat, message : Message) {
    let key = (principal, agentId);
    switch (Map.get(conversations, conversationKeyCompare, key)) {
      case (null) {
        let newList = List.empty<Message>();
        List.add(newList, message);
        Map.add(conversations, conversationKeyCompare, key, newList);
      };
      case (?existingList) {
        List.add(existingList, message);
      };
    };
  };

  // Get conversation history
  public shared ({ caller }) func get_conversation(ai_agent_id : Nat) : async Result.Result<[Message], Text> {
    let key = (caller, ai_agent_id);
    switch (Map.get(conversations, conversationKeyCompare, key)) {
      case (null) {
        return #err("No conversation found with agent " # debug_show (ai_agent_id));
      };
      case (?messages) {
        return #ok(List.toArray(messages));
      };
    };
  };

  public shared ({ caller }) func talk_to(ai_agent_id : Nat, message : Text) : async Result.Result<Text, Text> {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };

    addMessageToConversation(
      caller,
      ai_agent_id,
      {
        author = #user(caller);
        content = message;
        timestamp = Time.now();
      },
    );

    return #ok("Response from AI Agent " # debug_show (ai_agent_id) # ": " # message);
  };

  // Create a new agent
  public shared ({ caller }) func create_agent(name : Text, provider : AgentManagement.Provider, model : Text) : async Result.Result<Nat, Text> {
    let (result, newId) = AgentManagement.create_agent(name, provider, model, caller, admins, agents, nextAgentId);
    nextAgentId := newId;
    return result;
  };

  // Read/Get an agent
  public query func get_agent(id : Nat) : async ?AgentManagement.Agent {
    return AgentManagement.get_agent(id, agents);
  };

  // Update an agent
  public shared ({ caller }) func update_agent(id : Nat, new_name : ?Text, new_provider : ?AgentManagement.Provider, new_model : ?Text) : async Result.Result<Bool, Text> {
    return AgentManagement.update_agent(id, new_name, new_provider, new_model, caller, admins, agents);
  };

  // Delete an agent
  public shared ({ caller }) func delete_agent(id : Nat) : async Result.Result<Bool, Text> {
    return AgentManagement.delete_agent(id, caller, admins, agents);
  };

  // List all agents
  public query func list_agents() : async [AgentManagement.Agent] {
    return AgentManagement.list_agents(agents);
  };

  // Add a new admin
  public shared ({ caller }) func add_admin(new_admin : Principal) : async Result.Result<(), Text> {
    admins := AdminManagement.initializeFirstAdmin(caller, admins);

    let validation = AdminManagement.validateNewAdmin(new_admin, caller, admins);
    switch (validation) {
      case (#err(msg)) {
        return #err(msg);
      };
      case (#ok(())) {
        admins := AdminManagement.addAdminToList(new_admin, admins);
        return #ok(());
      };
    };
  };

  // Get list of admins
  public query func get_admins() : async [Principal] {
    return admins;
  };

  // Check if caller is admin
  public shared ({ caller }) func is_caller_admin() : async Bool {
    return AdminManagement.isAdmin(caller, admins);
  };
};
