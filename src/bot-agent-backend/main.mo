import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import AdminService "./services/admin-service";
import AgentService "./services/agent-service";
import ConversationService "./services/conversation-service";
import LLMWrapper "./wrappers/llm-wrapper";

persistent actor {
  var agents = Map.empty<Nat, AgentService.Agent>();
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];
  var conversations = Map.empty<ConversationService.ConversationKey, List.List<ConversationService.Message>>();

  // Get conversation history
  public shared ({ caller }) func get_conversation(ai_agent_id : Nat) : async Result.Result<[ConversationService.Message], Text> {
    return ConversationService.getConversation(conversations, caller, ai_agent_id);
  };

  public shared ({ caller }) func talk_to(ai_agent_id : Nat, message : Text) : async Result.Result<Text, Text> {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };

    ConversationService.addMessageToConversation(
      conversations,
      caller,
      ai_agent_id,
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
    let llm_wrapper = LLMWrapper.LLMWrapper(null);
    var response = await llm_wrapper.chat(message);

    // evaluate response and decide to terminate loop or continue
    // for now, just terminate

    // Store and Deliver response
    ConversationService.addMessageToConversation(
      conversations,
      caller,
      ai_agent_id,
      {
        author = #agent;
        content = response;
        timestamp = Time.now();
      },
    );

    return #ok("Response from AI Agent " # debug_show (ai_agent_id) # ": " # response);
  };

  // Create a new agent
  public shared ({ caller }) func create_agent(name : Text, provider : AgentService.Provider, model : Text) : async Result.Result<Nat, Text> {
    let (result, newId) = AgentService.create_agent(name, provider, model, caller, admins, agents, nextAgentId);
    nextAgentId := newId;
    return result;
  };

  // Read/Get an agent
  public query func get_agent(id : Nat) : async ?AgentService.Agent {
    return AgentService.get_agent(id, agents);
  };

  // Update an agent
  public shared ({ caller }) func update_agent(id : Nat, new_name : ?Text, new_provider : ?AgentService.Provider, new_model : ?Text) : async Result.Result<Bool, Text> {
    return AgentService.update_agent(id, new_name, new_provider, new_model, caller, admins, agents);
  };

  // Delete an agent
  public shared ({ caller }) func delete_agent(id : Nat) : async Result.Result<Bool, Text> {
    return AgentService.delete_agent(id, caller, admins, agents);
  };

  // List all agents
  public query func list_agents() : async [AgentService.Agent] {
    return AgentService.list_agents(agents);
  };

  // Add a new admin
  public shared ({ caller }) func add_admin(new_admin : Principal) : async Result.Result<(), Text> {
    admins := AdminService.initializeFirstAdmin(caller, admins);

    let validation = AdminService.validateNewAdmin(new_admin, caller, admins);
    switch (validation) {
      case (#err(msg)) {
        return #err(msg);
      };
      case (#ok(())) {
        admins := AdminService.addAdminToList(new_admin, admins);
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
    return AdminService.isAdmin(caller, admins);
  };
};
