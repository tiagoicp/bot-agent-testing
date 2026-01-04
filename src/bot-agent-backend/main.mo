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
  public shared ({ caller }) func getConversation(ai_agent_id : Nat) : async {
    #ok : [ConversationService.Message];
    #err : Text;
  } {
    ConversationService.getConversation(conversations, caller, ai_agent_id);
  };

  public shared ({ caller }) func talkTo(ai_agent_id : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else {

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
      let llmWrapper = LLMWrapper.LLMWrapper(null);
      var response = await llmWrapper.chat(message);

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

      #ok("Response from AI Agent " # debug_show (ai_agent_id) # ": " # response);
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
};
