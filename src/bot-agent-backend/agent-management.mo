import Result "mo:core/Result";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import AdminManagement "./admin-management";

module {
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

  // Create a new agent
  public func create_agent(name : Text, provider : Provider, model : Text, caller : Principal, admins : [Principal], agents : Map.Map<Nat, Agent>, nextAgentId : Nat) : (Result.Result<Nat, Text>, Nat) {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return (#err("Only admins can add new agents"), nextAgentId);
    };

    if (name == "") {
      return (#err("Agent name cannot be empty"), nextAgentId);
    };

    let id = nextAgentId;
    let agent : Agent = {
      id = id;
      name = name;
      provider = provider;
      model = model;
    };
    Map.add(agents, Nat.compare, id, agent);
    return (#ok(id), nextAgentId + 1);
  };

  // Read/Get an agent
  public func get_agent(id : Nat, agents : Map.Map<Nat, Agent>) : ?Agent {
    return Map.get(agents, Nat.compare, id);
  };

  // Update an agent
  public func update_agent(id : Nat, new_name : ?Text, new_provider : ?Provider, new_model : ?Text, caller : Principal, admins : [Principal], agents : Map.Map<Nat, Agent>) : Result.Result<Bool, Text> {
    if (not AdminManagement.isAdmin(caller, admins)) {
      return #err("Only admins can update agents");
    };

    switch (Map.get(agents, Nat.compare, id)) {
      case (null) {
        return #err("Agent not found");
      };
      case (?existingAgent) {
        let updatedAgent : Agent = {
          id = id;
          name = switch (new_name) {
            case (null) { existingAgent.name };
            case (?name) { name };
          };
          provider = switch (new_provider) {
            case (null) { existingAgent.provider };
            case (?provider) { provider };
          };
          model = switch (new_model) {
            case (null) { existingAgent.model };
            case (?model) { model };
          };
        };
        Map.add(agents, Nat.compare, id, updatedAgent);
        return #ok(true);
      };
    };
  };

  // Delete an agent
  public func delete_agent(id : Nat, caller : Principal, admins : [Principal], agents : Map.Map<Nat, Agent>) : Result.Result<Bool, Text> {
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
  public func list_agents(agents : Map.Map<Nat, Agent>) : [(Nat, Agent)] {
    return Map.toArray(agents);
  };
};
