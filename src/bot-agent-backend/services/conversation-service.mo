import Map "mo:core/Map";
import List "mo:core/List";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Result "mo:base/Result";

module {
  public type Message = {
    author : {
      #user;
      #agent;
    };
    content : Text;
    timestamp : Int;
  };

  public type ConversationKey = (Principal, Nat);

  // Comparison function for ConversationKey
  public func conversationKeyCompare(a : ConversationKey, b : ConversationKey) : {
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
  public func addMessageToConversation(
    conversations : Map.Map<ConversationKey, List.List<Message>>,
    principal : Principal,
    agentId : Nat,
    message : Message,
  ) {
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
  public func getConversation(
    conversations : Map.Map<ConversationKey, List.List<Message>>,
    principal : Principal,
    agentId : Nat,
  ) : Result.Result<[Message], Text> {
    let key = (principal, agentId);
    switch (Map.get(conversations, conversationKeyCompare, key)) {
      case (null) {
        #err("No conversation found with agent " # debug_show (agentId));
      };
      case (?messages) {
        #ok(List.toArray(messages));
      };
    };
  };
};
