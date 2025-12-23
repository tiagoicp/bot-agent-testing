import Array "mo:core/Array";

persistent actor {
  var agents : [(Nat, Text)] = [];

  public query func greet(name : Text) : async Text {
    return "Hello, " # name # "!";
  };

  public query func talk_to(ai_agent_id : Nat, message : Text) : async Text {
    return "Response from AI Agent " # debug_show (ai_agent_id) # ": " # message;
  };

  // Create a new agent
  public func create_agent(id : Nat, name : Text) : async Bool {
    let existing = findAgent(id);
    if (existing != null) {
      return false; // Agent already exists
    };
    agents := Array.concat(agents, [(id, name)]);
    return true;
  };

  // Read/Get an agent
  public query func get_agent(id : Nat) : async ?(Nat, Text) {
    return findAgent(id);
  };

  // Update an agent
  public func update_agent(id : Nat, new_name : Text) : async Bool {
    let index = findAgentIndex(id);
    switch (index) {
      case (null) {
        return false; // Agent not found
      };
      case (?idx) {
        agents := Array.tabulate<(Nat, Text)>(
          agents.size(),
          func(i : Nat) : (Nat, Text) {
            if (i == idx) { (id, new_name) } else { agents[i] };
          },
        );
        return true;
      };
    };
  };

  // Delete an agent
  public func delete_agent(id : Nat) : async Bool {
    let index = findAgentIndex(id);
    switch (index) {
      case (null) {
        return false; // Agent not found
      };
      case (?idx) {
        agents := Array.tabulate<(Nat, Text)>(
          agents.size() - 1,
          func(i : Nat) : (Nat, Text) {
            if (i < idx) { agents[i] } else { agents[i + 1] };
          },
        );
        return true;
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
};
