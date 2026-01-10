import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Types "../types";
import EncryptionService "./encryption-service";

module {
  /// Type alias for encrypted API key storage
  /// The Blob contains: [nonce (8 bytes)] [ciphertext]
  public type EncryptedApiKey = Blob;

  /// Type alias for the API keys map
  /// Principal -> (agentId, provider_name) -> encrypted_api_key
  public type ApiKeysMap = Map.Map<Principal, Map.Map<(Nat, Text), EncryptedApiKey>>;

  // Comparator for (Nat, Text) tuples
  public func compareNatTextTuple(a : (Nat, Text), b : (Nat, Text)) : Order.Order {
    switch (Nat.compare(a.0, b.0)) {
      case (#equal) { Text.compare(a.1, b.1) };
      case (other) { other };
    };
  };

  /// Convert LlmProvider variant to string representation
  private func providerToString(provider : Types.LlmProvider) : Text {
    switch (provider) {
      case (#openai) { "openai" };
      case (#llmcanister) { "llmcanister" };
      case (#groq) { "groq" };
    };
  };

  /// Get and decrypt API key for a specific caller, agent, and provider
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this Principal
  /// @param principal - The Principal whose key to retrieve
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @returns Decrypted API key text, or null if not found or decryption fails
  public func getApiKeyForCallerAndAgent(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    principal : Principal,
    agentId : Nat,
    provider : Types.LlmProvider,
  ) : ?Text {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        null;
      };
      case (?callerKeyMap) {
        switch (Map.get(callerKeyMap, compareNatTextTuple, key)) {
          case (null) { null };
          case (?encryptedBlob) {
            // Decrypt the API key
            let encryptedBytes = Blob.toArray(encryptedBlob);
            let decryptedBytes = EncryptionService.decrypt(encryptionKey, encryptedBytes);
            EncryptionService.bytesToText(decryptedBytes);
          };
        };
      };
    };
  };

  /// Encrypt and store an API key for an agent
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this Principal
  /// @param principal - The Principal storing the key
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @param apiKey - The plaintext API key to encrypt and store
  /// @returns Result
  public func storeApiKey(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    principal : Principal,
    agentId : Nat,
    provider : Types.LlmProvider,
    apiKey : Text,
  ) : Result.Result<(), Text> {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    // Convert API key to bytes and encrypt (nonce generated internally)
    let plaintextBytes = EncryptionService.textToBytes(apiKey);
    let encryptedBytes = EncryptionService.encrypt(encryptionKey, plaintextBytes, principal);
    let encryptedBlob = Blob.fromArray(encryptedBytes);

    // Get or create the caller's API key map
    let callerKeyMap = switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        Map.empty<(Nat, Text), EncryptedApiKey>();
      };
      case (?existingMap) {
        existingMap;
      };
    };

    // Add the encrypted API key to the caller's map
    Map.add(callerKeyMap, compareNatTextTuple, key, encryptedBlob);

    // Store the updated map back
    Map.add(apiKeys, Principal.compare, principal, callerKeyMap);

    #ok(());
  };

  /// Get caller's own API key identifiers (without decrypting the keys)
  /// Returns list of (agentId, providerName) pairs
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param principal - The Principal whose keys to list
  /// @returns List of (agentId, providerName) tuples
  public func getMyApiKeys(
    apiKeys : ApiKeysMap,
    principal : Principal,
  ) : Result.Result<[(Nat, Text)], Text> {
    switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        #ok([]);
      };
      case (?callerKeyMap) {
        #ok(Iter.toArray(Map.keys(callerKeyMap)));
      };
    };
  };

  /// Delete an API key for a specific agent and provider
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param principal - The Principal whose key to delete
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @returns Result
  public func deleteApiKey(
    apiKeys : ApiKeysMap,
    principal : Principal,
    agentId : Nat,
    provider : Types.LlmProvider,
  ) : Result.Result<(), Text> {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    switch (Map.get(apiKeys, Principal.compare, principal)) {
      case (null) {
        #err("No API keys found for this principal");
      };
      case (?callerKeyMap) {
        // Check if the key exists before deleting
        switch (Map.get(callerKeyMap, compareNatTextTuple, key)) {
          case (null) {
            #err("No API key found for agent " # debug_show (agentId) # " with provider " # providerName);
          };
          case (?_) {
            ignore Map.delete(callerKeyMap, compareNatTextTuple, key);
            Map.add(apiKeys, Principal.compare, principal, callerKeyMap);
            #ok(());
          };
        };
      };
    };
  };
};
