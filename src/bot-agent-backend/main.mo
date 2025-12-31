import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import AdminManagement "./admin-management";

persistent actor {
  var agents = Map.empty<Nat, Text>();
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];

  public type Provider = {
    #openai;
    #llmcanister;
    #groq;
  };

  public type Agent = {
    id : Nat;
    name : Text;
    provider : Provider;
    model : Text;
  };

  public query func greet(name : Text) : async Text {
    return "Hello, " # name # "!";
  };

  public query func talk_to(ai_agent_id : Nat, message : Text) : async Text {
    return "Response from AI Agent " # debug_show (ai_agent_id) # ": " # message;
  };

  // Create a new agent
  public shared ({ caller }) func create_agent(name : Text) : async Result.Result<Nat, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can add new agents");
    };

    if (name == "") {
      return #err("Agent name cannot be empty");
    };
    let id = nextAgentId;
    Map.add(agents, Nat.compare, id, name);
    nextAgentId += 1;
    return #ok(id);
  };

  // Read/Get an agent
  public query func get_agent(id : Nat) : async ?Text {
    return Map.get(agents, Nat.compare, id);
  };

  // Update an agent
  public shared ({ caller }) func update_agent(id : Nat, new_name : Text) : async Result.Result<Bool, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can update agents");
    };

    switch (Map.get(agents, Nat.compare, id)) {
      case (null) {
        return #err("Agent not found");
      };
      case (?_) {
        Map.add(agents, Nat.compare, id, new_name);
        return #ok(true);
      };
    };
  };

  // Delete an agent
  public shared ({ caller }) func delete_agent(id : Nat) : async Result.Result<Bool, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can delete agents");
    };

    switch (Map.get(agents, Nat.compare, id)) {
      case (null) {
        return #err("Agent not found");
      };
      case (?_) {
        Map.remove(agents, Nat.compare, id);
        return #ok(true);
      };
    };
  };

  // List all agents
  public query func list_agents() : async [(Nat, Text)] {
    return Map.toArray(agents);
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
