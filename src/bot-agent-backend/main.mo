import Array "mo:core/Array";
import Result "mo:core/Result";
import Principal "mo:core/Principal";
import AdminManagement "./admin-management";

persistent actor {
  var agents : [(Nat, Text)] = [];
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];

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
    agents := Array.concat(agents, [(id, name)]);
    nextAgentId += 1;
    return #ok(id);
  };

  // Read/Get an agent
  public query func get_agent(id : Nat) : async ?(Nat, Text) {
    return findAgent(id);
  };

  // Update an agent
  public shared ({ caller }) func update_agent(id : Nat, new_name : Text) : async Result.Result<Bool, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can update agents");
    };

    let index = findAgentIndex(id);
    switch (index) {
      case (null) {
        return #err("Agent not found");
      };
      case (?idx) {
        agents := Array.tabulate<(Nat, Text)>(
          agents.size(),
          func(i : Nat) : (Nat, Text) {
            if (i == idx) { (id, new_name) } else { agents[i] };
          },
        );
        return #ok(true);
      };
    };
  };

  // Delete an agent
  public shared ({ caller }) func delete_agent(id : Nat) : async Result.Result<Bool, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can delete agents");
    };

    let index = findAgentIndex(id);
    switch (index) {
      case (null) {
        return #err("Agent not found");
      };
      case (?idx) {
        agents := Array.tabulate<(Nat, Text)>(
          agents.size() - 1,
          func(i : Nat) : (Nat, Text) {
            if (i < idx) { agents[i] } else { agents[i + 1] };
          },
        );
        return #ok(true);
      };
    };
  };

  // List all agents
  public query func list_agents() : async [(Nat, Text)] {
    return agents;
  };

  // Helper function to find agent by ID
  private func findAgent(id : Nat) : ?(Nat, Text) {
    for (agent in agents.vals()) {
      if (agent.0 == id) {
        return ?agent;
      };
    };
    return null;
  };

  // Helper function to find agent index by ID
  private func findAgentIndex(id : Nat) : ?Nat {
    var i = 0;
    while (i < agents.size()) {
      if (agents[i].0 == id) {
        return ?i;
      };
      i += 1;
    };
    return null;
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
