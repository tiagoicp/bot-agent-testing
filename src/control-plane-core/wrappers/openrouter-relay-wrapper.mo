/// OpenRouter Relay Wrapper
///
/// Submits LLM reasoning requests to the Cloudflare Worker relay instead of
/// calling OpenRouter directly.  The worker proxies the request to OpenRouter
/// and delivers the response back to this canister via a signed webhook.
///
/// Security contract
/// ─────────────────
///   • `aesKey` (32 bytes) — HKDF-derived from the relay shared secret.
///     Must be obtained from `KeyDerivationService.getOrDeriveRelayKey`.
///   • `hmacKeyBytes` — raw UTF-8 bytes of the shared secret, used to sign
///     the outbound request per the worker's HMAC-SHA256 scheme.
///   • IV is derived deterministically as the first 12 bytes of
///     HMAC-SHA256(hmacKeyBytes, UTF-8("iv-v1-" ++ requestId)).  This is a
///     PRF-nonce: unique per requestId, unpredictable without the key, and
///     requires zero extra async calls.
///
/// Worker request contract (must stay in sync with the Cloudflare Worker)
/// ───────────────────────────────────────────────────────────────────────
///   POST <LLM_RELAY_URL>
///   Headers:
///     Content-Type:  application/json
///     X-Timestamp:   <unix seconds as decimal>
///     X-Signature:   sha256=<hex HMAC-SHA256(hmacKeyBytes, "${ts}.${body}")>
///   Body:
///     {
///       "requestId":                   <string>,
///       "openrouter":                  { <full OpenRouter Responses API payload> },
///       "encryptedApiKey":             { "iv": <base64>, "ct": <base64(ct||tag)> },
///       "truncate_thinking_to_max_tokens": <nat>
///     }
///   Expected response: HTTP 202, body { "ok": true, "requestId": <string> }

import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Time "mo:core/Time";
import HttpWrapper "./http-wrapper";
import Hmac "../utilities/hmac";
import AesGcm "../utilities/aes-gcm";
import Base64 "../utilities/base64";
import Constants "../constants";
import Json "mo:json";
import { str; int; float; bool; obj; arr } "mo:json";

module {
  // ============================================
  // Types for OpenRouter API
  // ============================================

  /// Tracking identifier for attribution and usage monitoring
  public type TrackId = {
    #workspace : Nat;
    #workspaceAgent : (Nat, Nat);
  };

  /// Role for Responses API input messages
  public type ResponseInputRole = {
    #user;
    #assistant;
    #system_;
    #developer;
  };

  /// Input message for OpenRouter Responses API
  public type ResponseInputMessage = {
    role : ResponseInputRole;
    content : Text;
  };

  /// Input for OpenRouter Responses API (array of messages)
  public type ResponseInput = [ResponseInputMessage];

  /// Reasoning configuration for Responses API
  public type ReasoningConfig = {
    effort : ?Text;
    summary : ?Text; // "auto" | "concise" | "detailed"
  };

  /// Text format configuration
  public type TextFormat = {
    format_type : Text; // "text" or "json_schema"
  };

  /// Tool choice for Responses API
  public type ToolChoice = {
    #string : Text; // "none", "auto", "required"
    #objectDef : { tool_type : Text; function_name : Text };
  };

  /// Function definition for tools
  public type FunctionDef = {
    name : Text;
    description : ?Text;
    parameters : ?Text; // JSON schema as string
  };

  /// Tool definition
  public type Tool = {
    tool_type : Text; // "function"
    function : FunctionDef;
  };

  /// A tool call request from the LLM
  public type ToolCall = {
    callId : Text;
    toolName : Text;
    arguments : Text; // JSON string of arguments
  };

  /// Result from reason - follows #ok/#err pattern
  public type ReasonWithToolsResult = {
    #ok : {
      #textResponse : { content : Text; thinking : ?Text };
      #toolCalls : [ToolCall];
    };
    #err : Text;
  };

  /// Request payload for OpenRouter Responses API
  public type ResponseRequest = {
    input : ResponseInput;
    model : Text;
    instructions : ?Text;
    max_output_tokens : ?Nat;
    metadata : ?Text; // JSON string for custom key-value pairs
    parallel_tool_calls : ?Bool;
    reasoning : ?ReasoningConfig;
    service_tier : ?Text;
    store : ?Bool;
    stream : ?Bool;
    temperature : ?Float;
    text : ?TextFormat;
    tool_choice : ?ToolChoice;
    tools : ?[Tool];
    top_p : ?Float;
    truncation : ?Text;
    user : ?Text;
  };

  /// Output content from Responses API
  public type ResponseOutputContent = {
    content_type : Text;
    text : Text;
    annotations : [Text];
  };

  /// Message output from Responses API
  public type ResponseMessage = {
    output_type : Text;
    id : Text;
    status : Text;
    role : Text;
    content : [ResponseOutputContent];
  };

  /// Response output array item
  public type ResponseOutput = {
    #message : ResponseMessage;
  };

  /// Usage details for Responses API
  public type ResponseUsage = {
    input_tokens : Nat;
    input_tokens_details : ?{ cached_tokens : Nat };
    output_tokens : Nat;
    output_tokens_details : ?{ reasoning_tokens : Nat };
    total_tokens : Nat;
  };

  /// Response payload from OpenRouter Responses API
  public type ResponseData = {
    id : Text;
    objectType : Text;
    status : Text;
    created_at : Nat;
    output : [ResponseOutput];
    previous_response_id : ?Text;
    model : Text;
    reasoning : ?ReasoningConfig;
    max_output_tokens : ?Nat;
    instructions : ?Text;
    text : ?TextFormat;
    tools : [Tool];
    tool_choice : ?ToolChoice;
    truncation : Text;
    metadata : ?Text;
    temperature : Float;
    top_p : Float;
    user : ?Text;
    service_tier : Text;
    error : ?Text;
    incomplete_details : ?Text;
    usage : ResponseUsage;
    parallel_tool_calls : Bool;
    store : Bool;
  };

  // ============================================
  // Private serialization helpers
  // ============================================

  private func responseInputRoleToString(role : ResponseInputRole) : Text {
    switch (role) {
      case (#user) { "user" };
      case (#assistant) { "assistant" };
      case (#system_) { "system" };
      case (#developer) { "developer" };
    };
  };

  private func responseInputMessageToJson(msg : ResponseInputMessage) : Json.Json {
    obj([
      ("role", str(responseInputRoleToString(msg.role))),
      ("content", str(msg.content)),
    ]);
  };

  private func inputToJson(input : ResponseInput) : Json.Json {
    arr(Array.map<ResponseInputMessage, Json.Json>(input, responseInputMessageToJson));
  };

  private func toolChoiceToJson(toolChoice : ToolChoice) : Json.Json {
    switch (toolChoice) {
      case (#string(choice)) { str(choice) };
      case (#objectDef(toolObj)) {
        obj([
          ("type", str(toolObj.tool_type)),
          ("function", obj([("name", str(toolObj.function_name))])),
        ]);
      };
    };
  };

  private func toolToJson(tool : Tool) : Json.Json {
    let toolFields = List.empty<(Text, Json.Json)>();
    List.add(toolFields, ("type", str(tool.tool_type)));
    List.add(toolFields, ("name", str(tool.function.name)));

    switch (tool.function.description) {
      case (?desc) { List.add(toolFields, ("description", str(desc))) };
      case (null) {};
    };

    switch (tool.function.parameters) {
      case (?params) {
        switch (Json.parse(params)) {
          case (#ok(paramJson)) {
            List.add(toolFields, ("parameters", paramJson));
          };
          case (#err(_)) {};
        };
      };
      case (null) {};
    };

    obj(List.toArray(toolFields));
  };

  private func serializeResponseRequest(request : ResponseRequest) : Text {
    let requestFields = List.empty<(Text, Json.Json)>();
    List.add(requestFields, ("input", inputToJson(request.input)));
    List.add(requestFields, ("model", str(request.model)));

    switch (request.instructions) {
      case (?inst) { List.add(requestFields, ("instructions", str(inst))) };
      case (null) {};
    };

    switch (request.max_output_tokens) {
      case (?tokens) {
        List.add(requestFields, ("max_output_tokens", int(tokens)));
      };
      case (null) {};
    };

    switch (request.metadata) {
      case (?meta) {
        switch (Json.parse(meta)) {
          case (#ok(metaJson)) {
            List.add(requestFields, ("metadata", metaJson));
          };
          case (#err(_)) {};
        };
      };
      case (null) {};
    };

    switch (request.parallel_tool_calls) {
      case (?parallel) {
        List.add(requestFields, ("parallel_tool_calls", bool(parallel)));
      };
      case (null) {};
    };

    switch (request.reasoning) {
      case (?reasoning) {
        let reasoningFields = List.empty<(Text, Json.Json)>();
        switch (reasoning.effort) {
          case (?effort) {
            List.add(reasoningFields, ("effort", str(effort)));
          };
          case (null) {};
        };
        switch (reasoning.summary) {
          case (?summary) {
            List.add(reasoningFields, ("summary", str(summary)));
          };
          case (null) {};
        };
        List.add(requestFields, ("reasoning", obj(List.toArray(reasoningFields))));
      };
      case (null) {};
    };

    switch (request.service_tier) {
      case (?tier) { List.add(requestFields, ("service_tier", str(tier))) };
      case (null) {};
    };

    switch (request.store) {
      case (?store) { List.add(requestFields, ("store", bool(store))) };
      case (null) {};
    };

    switch (request.stream) {
      case (?stream) { List.add(requestFields, ("stream", bool(stream))) };
      case (null) {};
    };

    switch (request.temperature) {
      case (?temp) { List.add(requestFields, ("temperature", float(temp))) };
      case (null) {};
    };

    switch (request.text) {
      case (?textFormat) {
        List.add(requestFields, ("text", obj([("format", obj([("type", str(textFormat.format_type))]))])));
      };
      case (null) {};
    };

    switch (request.tool_choice) {
      case (?choice) {
        List.add(requestFields, ("tool_choice", toolChoiceToJson(choice)));
      };
      case (null) {};
    };

    switch (request.tools) {
      case (?tools) {
        List.add(requestFields, ("tools", arr(Array.map<Tool, Json.Json>(tools, toolToJson))));
      };
      case (null) {};
    };

    switch (request.top_p) {
      case (?p) { List.add(requestFields, ("top_p", float(p))) };
      case (null) {};
    };

    switch (request.truncation) {
      case (?trunc) { List.add(requestFields, ("truncation", str(trunc))) };
      case (null) {};
    };

    switch (request.user) {
      case (?user) { List.add(requestFields, ("user", str(user))) };
      case (null) {};
    };

    Json.stringify(obj(List.toArray(requestFields)), null);
  };

  // ============================================
  // Public Functions
  // ============================================

  /// Parse an OpenRouter Responses API body into a `ReasonWithToolsResult`.
  ///
  /// Made public so the webhook handler can invoke it after reassembling and
  /// decompressing the worker's chunked callback payload.
  public func parseResponsesApiWithToolCalls(responseBody : Text) : ReasonWithToolsResult {
    switch (Json.parse(responseBody)) {
      case (#err(error)) {
        #err("Failed to parse JSON response: " # debug_show error # ".");
      };
      case (#ok(json)) {
        switch (Json.get(json, "output")) {
          case (null) {
            #err("Could not find output array in response.");
          };
          case (?outputArrayJson) {
            switch (outputArrayJson) {
              case (#array(outputs)) {
                // First pass: collect function_call outputs
                let toolCallsList = List.empty<ToolCall>();

                for (outputJson in outputs.vals()) {
                  switch (Json.get(outputJson, "type")) {
                    case (?typeJson) {
                      switch (typeJson) {
                        case (#string("function_call")) {
                          let callIdOpt = switch (Json.get(outputJson, "call_id")) {
                            case (?#string(id)) { ?id };
                            case (_) { null };
                          };
                          let nameOpt = switch (Json.get(outputJson, "name")) {
                            case (?#string(n)) { ?n };
                            case (_) { null };
                          };
                          let argsOpt = switch (Json.get(outputJson, "arguments")) {
                            case (?#string(a)) { ?a };
                            case (_) { null };
                          };

                          switch (callIdOpt, nameOpt, argsOpt) {
                            case (?callId, ?name, ?args) {
                              List.add(
                                toolCallsList,
                                {
                                  callId;
                                  toolName = name;
                                  arguments = args;
                                },
                              );
                            };
                            case (_) {};
                          };
                        };
                        case (_) {};
                      };
                    };
                    case (null) {};
                  };
                };

                let toolCallsArray = List.toArray(toolCallsList);
                if (toolCallsArray.size() > 0) {
                  return #ok(#toolCalls(toolCallsArray));
                };

                // Collect thinking text from reasoning output items
                var thinkingOpt : ?Text = null;
                for (outputJson in outputs.vals()) {
                  switch (Json.get(outputJson, "type")) {
                    case (?#string("reasoning")) {
                      switch (Json.get(outputJson, "summary[0].text")) {
                        case (?#string(t)) { thinkingOpt := ?t };
                        case (_) {};
                      };
                    };
                    case (_) {};
                  };
                };

                // Second pass: extract the message text
                for (outputJson in outputs.vals()) {
                  switch (Json.get(outputJson, "type")) {
                    case (?#string("message")) {
                      switch (Json.get(outputJson, "content[0].text")) {
                        case (?#string(content)) {
                          return #ok(#textResponse({ content; thinking = thinkingOpt }));
                        };
                        case (_) {};
                      };
                    };
                    case (_) {};
                  };
                };

                #err("Could not find message output or tool calls in response.");
              };
              case (_) {
                #err("Output field is not an array.");
              };
            };
          };
        };
      };
    };
  };

  /// Submit a reasoning request to the Cloudflare Worker relay.
  ///
  /// The caller is responsible for:
  ///   • Building `requestId` (e.g. `turnId # "-r" # Nat.toText(round)`)
  ///   • Providing `hmacKeyBytes = Blob.toArray(Text.encodeUtf8(sharedSecret))`
  ///   • Providing `aesKey` from `KeyDerivationService.getOrDeriveRelayKey`
  ///
  /// On success the worker acknowledges with HTTP 202 and echoes `requestId`.
  /// The actual LLM response is delivered asynchronously via webhook.
  ///
  /// @param requestId    - Unique, deterministic identifier for this round
  /// @param hmacKeyBytes - UTF-8 bytes of the relay shared secret (for HMAC signing)
  /// @param aesKey       - 32-byte HKDF-derived AES key (for API key encryption)
  /// @param apiKey       - OpenRouter API key to encrypt and forward
  /// @param input        - Conversation history as Responses API input array
  /// @param model        - OpenRouter model identifier
  /// @param trackId      - Attribution identifier (workspace / workspace+agent)
  /// @param instructions - Optional system instructions
  /// @param temperature              - Optional sampling temperature
  /// @param tools                    - Optional tool definitions for function calling
  /// @param truncateThinkingMaxTokens - Max tokens of reasoning to include in the response;
  ///                                   pass `session.policy.maxTruncatedTokens`
  public func submitReason(
    requestId : Text,
    hmacKeyBytes : [Nat8],
    aesKey : [Nat8],
    apiKey : Text,
    input : ResponseInput,
    model : Text,
    trackId : TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[Tool],
    truncateThinkingMaxTokens : Nat,
  ) : async { #ok : { requestId : Text }; #err : Text } {
    assert aesKey.size() == 32;
    assert hmacKeyBytes.size() > 0;
    assert input.size() > 0;
    assert Text.trim(model, #char ' ') != "";
    assert Text.trim(requestId, #char ' ') != "";

    // ── 1. User key for OpenRouter attribution ──────────────────────
    let userKey = switch (trackId) {
      case (#workspace(id)) { Nat.toText(id) };
      case (#workspaceAgent(wsId, agId)) {
        Nat.toText(wsId) # "_" # Nat.toText(agId);
      };
    };

    // ── 2. Build OpenRouter request payload ─────────────────────────
    let request : ResponseRequest = {
      input;
      model;
      instructions;
      max_output_tokens = null;
      metadata = null;
      parallel_tool_calls = null;
      reasoning = ?{ effort = ?"high"; summary = ?"auto" };
      service_tier = null;
      store = ?false;
      stream = ?false;
      temperature;
      text = null;
      tool_choice = null;
      tools;
      top_p = null;
      truncation = null;
      user = ?userKey;
    };

    let openrouterPayloadText = serializeResponseRequest(request);

    // ── 3. Derive IV deterministically (PRF-nonce pattern) ──────────
    //   IV = first 12 bytes of HMAC-SHA256(hmacKeyBytes, UTF-8("iv-v1-" ++ requestId))
    //   Unique per requestId, unpredictable without the key.
    let ivMessage = Blob.toArray(Text.encodeUtf8("iv-v1-" # requestId));
    let ivFull = Blob.toArray(Hmac.compute(hmacKeyBytes, ivMessage));
    let iv = Array.tabulate<Nat8>(12, func(i : Nat) : Nat8 { ivFull[i] });

    // ── 4. Encrypt the OpenRouter API key with AES-256-GCM ──────────
    //   AAD is empty — matches the worker's crypto.subtle.decrypt call
    //   (no additionalData).  Output is ct || tag (tag = last 16 bytes).
    let apiKeyBytes = Blob.toArray(Text.encodeUtf8(apiKey));
    let encrypted = AesGcm.encrypt(aesKey, iv, apiKeyBytes, []);
    let ivBase64 = Base64.encode(iv);
    let ctBase64 = Base64.encode(encrypted);

    // ── 5. Parse openrouter payload for embedding in relay body ─────
    let openrouterJson = switch (Json.parse(openrouterPayloadText)) {
      case (#ok(j)) { j };
      case (#err(_)) {
        return #err("Internal error: failed to re-parse serialized openrouter payload.");
      };
    };

    // ── 6. Build relay request body ──────────────────────────────────
    let relayBody = Json.stringify(
      obj([
        ("requestId", str(requestId)),
        ("openrouter", openrouterJson),
        ("encryptedApiKey", obj([("iv", str(ivBase64)), ("ct", str(ctBase64))])),
        ("truncate_thinking_to_max_tokens", int(truncateThinkingMaxTokens)),
      ]),
      null,
    );

    // ── 7. Compute HMAC-SHA256 request signature ─────────────────────
    //   Scheme: sha256=<hex HMAC(hmacKeyBytes, "${ts}.${body}")>
    let tsNs : Int = Time.now();
    let tsSecs : Int = tsNs / 1_000_000_000;
    let tsText = Int.toText(tsSecs);
    let sigMessage = Blob.toArray(Text.encodeUtf8(tsText # "." # relayBody));
    let signatureBlob = Hmac.compute(hmacKeyBytes, sigMessage);
    let signatureHeader = "sha256=" # Hmac.bytesToHex(signatureBlob);

    // ── 8. POST to relay ─────────────────────────────────────────────
    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Content-Type"; value = "application/json" },
      { name = "X-Timestamp"; value = tsText },
      { name = "X-Signature"; value = signatureHeader },
    ];

    let httpResult = await HttpWrapper.post(Constants.LLM_RELAY_URL # "/relay", headers, relayBody);

    switch (httpResult) {
      case (#err(error)) {
        #err("Relay HTTP request failed: " # error # ".");
      };
      case (#ok((status, responseBody))) {
        if (status == 202) {
          #ok({ requestId });
        } else {
          #err("Relay returned status " # Nat.toText(status) # ": " # responseBody # ".");
        };
      };
    };
  };
};
