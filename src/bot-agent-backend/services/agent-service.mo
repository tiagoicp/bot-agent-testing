import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Iter "mo:core/Iter";

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
  public func createAgent(name : Text, provider : Provider, model : Text, agents : Map.Map<Nat, Agent>, nextAgentId : Nat) : ({ #ok : Nat; #err : Text }, Nat) {
    if (name == "") {
      (#err("Agent name cannot be empty"), nextAgentId);
    } else {
      let id = nextAgentId;
      let agent : Agent = {
        id;
        name;
        provider;
        model;
      };
      Map.add(agents, Nat.compare, id, agent);
      (#ok(id), nextAgentId + 1);
    };
  };

  // Read/Get an agent
  public func getAgent(id : Nat, agents : Map.Map<Nat, Agent>) : ?Agent {
    Map.get(agents, Nat.compare, id);
  };

  // Update an agent
  public func updateAgent(id : Nat, newName : ?Text, newProvider : ?Provider, newModel : ?Text, agents : Map.Map<Nat, Agent>) : {
    #ok : Bool;
    #err : Text;
  } {
    switch (Map.get(agents, Nat.compare, id)) {
      case (null) {
        #err("Agent not found");
      };
      case (?existingAgent) {
        let updatedAgent : Agent = {
          id;
          name = switch (newName) {
            case (null) { existingAgent.name };
            case (?name) { name };
          };
          provider = switch (newProvider) {
            case (null) { existingAgent.provider };
            case (?provider) { provider };
          };
          model = switch (newModel) {
            case (null) { existingAgent.model };
            case (?model) { model };
          };
        };
        Map.add(agents, Nat.compare, id, updatedAgent);
        #ok(true);
      };
    };
  };

  // Delete an agent
  public func deleteAgent(id : Nat, agents : Map.Map<Nat, Agent>) : {
    #ok : Bool;
    #err : Text;
  } {
    switch (Map.get(agents, Nat.compare, id)) {
      case (null) {
        #err("Agent not found");
      };
      case (?_) {
        Map.remove(agents, Nat.compare, id);
        #ok(true);
      };
    };
  };

  // List all agents
  public func listAgents(agents : Map.Map<Nat, Agent>) : [Agent] {
    Iter.toArray(Map.values(agents));
  };
};
