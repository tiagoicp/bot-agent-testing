import { test; suite; expect } "mo:test";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Result "mo:core/Result";
import ApiKeysService "../../../../src/bot-agent-backend/services/api-keys-service";

func resultToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

suite(
  "ApiKeysService",
  func() {
    test(
      "storeApiKey stores an API key for a principal and agent",
      func() {
        let principal = Principal.fromActor(actor "aaaaa-aa");
        var apiKeys = Map.empty<Principal, Map.Map<(Nat, Text), Text>>();
        let agentId = 1;
        let provider = #groq;
        let apiKey = "test-key-123";

        let (updatedKeys, result) = ApiKeysService.storeApiKey(
          apiKeys,
          principal,
          agentId,
          provider,
          apiKey,
        );

        apiKeys := updatedKeys;

        expect.result<(), Text>(result, resultToText, resultEqual).isOk();

        let retrievedKey = ApiKeysService.getApiKeyForCallerAndAgent(
          apiKeys,
          principal,
          agentId,
          provider,
        );

        expect.option(retrievedKey, Text.toText, Text.equal).equal(?apiKey);
      },
    );

    test(
      "getApiKeyForCallerAndAgent returns latest key after update",
      func() {
        let principal = Principal.fromActor(actor "aaaaa-aa");
        var apiKeys = Map.empty<Principal, Map.Map<(Nat, Text), Text>>();
        let agentId = 1;
        let provider = #groq;

        // Store first API key
        let firstKey = "original-key-123";
        let (keysAfterFirst, result1) = ApiKeysService.storeApiKey(
          apiKeys,
          principal,
          agentId,
          provider,
          firstKey,
        );
        apiKeys := keysAfterFirst;
        expect.result<(), Text>(result1, resultToText, resultEqual).isOk();

        // Verify first key is stored
        let retrievedFirstKey = ApiKeysService.getApiKeyForCallerAndAgent(
          apiKeys,
          principal,
          agentId,
          provider,
        );
        expect.option(retrievedFirstKey, Text.toText, Text.equal).equal(?firstKey);

        // Update with a new API key
        let secondKey = "updated-key-456";
        let (keysAfterSecond, result2) = ApiKeysService.storeApiKey(
          apiKeys,
          principal,
          agentId,
          provider,
          secondKey,
        );
        apiKeys := keysAfterSecond;
        expect.result<(), Text>(result2, resultToText, resultEqual).isOk();

        // Verify latest key is returned
        let retrievedLatestKey = ApiKeysService.getApiKeyForCallerAndAgent(
          apiKeys,
          principal,
          agentId,
          provider,
        );
        expect.option(retrievedLatestKey, Text.toText, Text.equal).equal(?secondKey);
      },
    );
  },
);
