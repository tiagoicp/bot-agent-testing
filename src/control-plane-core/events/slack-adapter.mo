/// Slack Adapter
/// Parses raw JSON from Slack webhooks into typed SlackEnvelope / Event structures
/// Handles:
///   - url_verification (challenge handshake)
///   - event_callback (real events: app_mention, message)
///   - app_rate_limited
///   - Signature verification using HMAC-SHA256
///
/// Debug logging: when LOG_SLACK_EVENTS is true, raw payloads are logged
/// via Logger so they can be retrieved with `icp canister logs`
/// and copy-pasted into test stubs.

import Text "mo:core/Text";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Json "mo:json";
import SlackEventTypes "./types/slack-event-types";
import NormalizedEventTypes "./types/normalized-event-types";
import Hmac "../utilities/hmac";
import Constants "../constants";
import Encryption "../utilities/encryption";
import Logger "../utilities/logger";
import Types "../types";
import UrlEncoding "../utilities/url-encoding";

module {

  // ============================================
  // Payload Logging
  // ============================================

  /// Log raw payload for development/debugging
  /// Readable via `icp canister logs <canister-id>`
  func logRawPayload(bodyText : Text) {
    if (Constants.LOG_SLACK_EVENTS) {
      Logger.log(#_debug, ?"SlackAdapterEventRaw", bodyText);
    };
  };

  // ============================================
  // Signature Verification
  // ============================================

  /// Validate that a Slack request timestamp is within the acceptable window.
  ///
  /// Rejects requests older than 5 minutes (300 seconds) or with a future timestamp
  /// to prevent replay attacks.
  ///
  /// @param timestamp - Unix timestamp in seconds as text
  /// @returns true if the timestamp is valid and within the acceptable window
  public func verifyTimestamp(timestamp : Text) : Bool {
    let timestampInt = switch (Int.fromText(timestamp)) {
      case (?t) { t };
      case (null) { return false }; // Invalid timestamp format
    };

    let currentTimeNanos = Time.now();
    let currentTimeSeconds = currentTimeNanos / 1_000_000_000;

    let timeDifference = currentTimeSeconds - timestampInt;
    let maxAge = 300; // 5 minutes in seconds

    // Reject if timestamp is in the future or older than 5 minutes
    not (timeDifference < 0 or timeDifference > maxAge);
  };

  /// Verify a Slack HMAC-SHA256 signature against the expected value.
  ///
  /// Builds the base string "v0:{timestamp}:{body}", computes HMAC-SHA256 with the
  /// signing secret, and compares using constant-time equality to prevent timing attacks.
  ///
  /// @param signingSecret - The Slack signing secret (from app settings)
  /// @param signature - The X-Slack-Signature header value
  /// @param timestamp - The X-Slack-Request-Timestamp header value (Unix timestamp in seconds as text)
  /// @param body - The raw request body
  /// @returns true if the signature matches
  func verifyHmac(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : Bool {
    let baseString = "v0:" # timestamp # ":" # body;

    let msgBytes = Encryption.textToBytes(baseString);
    let secretBytes = Encryption.textToBytes(signingSecret);
    let hmacResult = Hmac.compute(secretBytes, msgBytes);
    let expectedSignature = "v0=" # Hmac.bytesToHex(hmacResult);

    // Constant-time comparison to prevent timing attacks
    Text.equal(signature, expectedSignature);
  };

  /// Verify Slack request signature using HMAC-SHA256 and (outside of test) timestamp validation.
  ///
  /// Slack signs requests with: v0=HMAC-SHA256(signing_secret, "v0:{timestamp}:{body}")
  /// See: https://api.slack.com/authentication/verifying-requests-from-slack
  ///
  /// When CANISTER_ENV is set to "test", timestamp validation is skipped to allow
  /// cassette-recorded requests with fixed timestamps to remain verifiable. In all other
  /// environments, the timestamp is validated to prevent replay attacks (requests older
  /// than 5 minutes are rejected).
  ///
  /// @param signingSecret - The Slack signing secret (from app settings)
  /// @param signature - The X-Slack-Signature header value
  /// @param timestamp - The X-Slack-Request-Timestamp header value (Unix timestamp in seconds as text)
  /// @param body - The raw request body
  /// @returns true if the signature (and, outside of test environment, the timestamp) is valid
  public func verifySignature<system>(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : Bool {
    let timestampValid = if (Runtime.envVar<system>("CANISTER_ENV") == ?"test") {
      true; // skip timestamp check in test environment
    } else {
      verifyTimestamp(timestamp);
    };

    if (not timestampValid) { return false };

    verifyHmac(signingSecret, signature, timestamp, body);
  };

  /// Extract a header value by name (case-insensitive)
  public func getHeader(headers : [Types.HeaderField], name : Text) : ?Text {
    let lowerName = Text.toLower(name);
    for ((key, value) in headers.vals()) {
      if (Text.toLower(key) == lowerName) {
        return ?value;
      };
    };
    null;
  };

  // ============================================
  // JSON Parsing
  // ============================================

  /// Parse raw JSON body into a SlackEnvelope
  ///
  /// @param bodyText - Raw JSON string from the webhook
  /// @returns Parsed envelope or error message
  public func parseEnvelope(bodyText : Text) : {
    #ok : SlackEventTypes.SlackEnvelope;
    #err : Text;
  } {
    // Log raw payload for dev environments
    logRawPayload(bodyText);

    // Slack interactive components (Block Kit buttons) send the payload as
    // application/x-www-form-urlencoded: `payload=<percent-encoded-json>`.
    // Detect this prefix and route to the block_actions parser.
    if (Text.startsWith(bodyText, #text "payload=")) {
      let encoded = switch (Text.stripStart(bodyText, #text "payload=")) {
        case (?t) { t };
        case null { Runtime.unreachable() }; // startsWith guard above
      };
      let decoded = switch (UrlEncoding.decodeQueryValue(encoded)) {
        case (#ok(t)) { t };
        case (#err(e)) { return #err("Invalid percent-encoded payload: " # e) };
      };
      return parseBlockActionsPayload(decoded);
    };

    let json = switch (Json.parse(bodyText)) {
      case (#ok(j)) { j };
      case (#err(e)) {
        return #err("Failed to parse JSON: " # debug_show (e));
      };
    };

    // Determine envelope type
    let envelopeType = switch (Json.get(json, "type")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing or invalid 'type' field in envelope") };
    };

    switch (envelopeType) {
      case ("url_verification") {
        switch (parseUrlVerification(json)) {
          case (#ok(v)) { #ok(#url_verification(v)) };
          case (#err(e)) { #err(e) };
        };
      };
      case ("event_callback") {
        switch (parseEventCallback(json)) {
          case (#ok(cb)) { #ok(#event_callback(cb)) };
          case (#err(e)) { #err(e) };
        };
      };
      case ("app_rate_limited") {
        switch (parseAppRateLimited(json)) {
          case (#ok(event)) { #ok(#app_rate_limited(event)) };
          case (#err(e)) { #err(e) };
        };
      };
      case (other) {
        #ok(#unknown(other));
      };
    };
  };

  /// Parse app_rate_limited envelope
  func parseAppRateLimited(json : Json.Json) : {
    #ok : SlackEventTypes.SlackAppRateLimitedEvent;
    #err : Text;
  } {
    let teamId = switch (Json.get(json, "team_id")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'team_id' in app_rate_limited") };
    };
    let minuteRateLimited = switch (Json.get(json, "minute_rate_limited")) {
      case (?#number(#int(n))) { Int.abs(n) };
      case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
      case _ {
        return #err("Missing 'minute_rate_limited' in app_rate_limited");
      };
    };

    #ok({ team_id = teamId; minute_rate_limited = minuteRateLimited });
  };

  /// Parse url_verification envelope
  func parseUrlVerification(json : Json.Json) : {
    #ok : SlackEventTypes.SlackUrlVerification;
    #err : Text;
  } {
    let challenge = switch (Json.get(json, "challenge")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'challenge' in url_verification") };
    };
    let token = switch (Json.get(json, "token")) {
      case (?#string(t)) { t };
      case _ { "" }; // Token is deprecated, not required
    };
    #ok({ challenge; token });
  };

  /// Parse event_callback envelope
  func parseEventCallback(json : Json.Json) : {
    #ok : SlackEventTypes.SlackEventCallback;
    #err : Text;
  } {
    let token = switch (Json.get(json, "token")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let teamId = switch (Json.get(json, "team_id")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'team_id' in event_callback") };
    };
    let apiAppId = switch (Json.get(json, "api_app_id")) {
      case (?#string(a)) { a };
      case _ { return #err("Missing 'api_app_id' in event_callback") };
    };
    let eventId = switch (Json.get(json, "event_id")) {
      case (?#string(e)) { e };
      case _ { return #err("Missing 'event_id' in event_callback") };
    };
    let eventTime = switch (Json.get(json, "event_time")) {
      case (?#number(#int(n))) { Int.abs(n) };
      case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
      case _ { return #err("Missing 'event_time' in event_callback") };
    };

    // Parse inner event
    let eventJson = switch (Json.get(json, "event")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'event' object in event_callback") };
    };

    let innerEvent = switch (parseInnerEvent(eventJson)) {
      case (#ok(e)) { e };
      case (#err(msg)) { return #err(msg) };
    };

    #ok({
      token;
      team_id = teamId;
      api_app_id = apiAppId;
      event = innerEvent;
      event_id = eventId;
      event_time = eventTime;
    });
  };

  /// Parse the inner event object within an event_callback
  func parseInnerEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackInnerEvent;
    #err : Text;
  } {
    let eventType = switch (Json.get(json, "type")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'type' in inner event") };
    };

    switch (eventType) {
      case ("app_mention") {
        switch (parseAppMentionEvent(json)) {
          case (#ok(e)) { #ok(#app_mention(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("message") {
        switch (parseMessageEvent(json)) {
          case (#ok(e)) { #ok(#message(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("assistant_thread_started") {
        switch (parseAssistantThreadStartedEvent(json)) {
          case (#ok(e)) { #ok(#assistant_thread_started(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("assistant_thread_context_changed") {
        switch (parseAssistantThreadContextChangedEvent(json)) {
          case (#ok(e)) { #ok(#assistant_thread_context_changed(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("member_joined_channel") {
        switch (parseMemberJoinedChannelEvent(json)) {
          case (#ok(e)) { #ok(#member_joined_channel(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("member_left_channel") {
        switch (parseMemberLeftChannelEvent(json)) {
          case (#ok(e)) { #ok(#member_left_channel(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("team_join") {
        switch (parseTeamJoinEvent(json)) {
          case (#ok(e)) { #ok(#team_join(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case (other) {
        Logger.log(#warn, ?"SlackAdapter", "Unknown inner event type: " # other);
        #ok(#unknown({ eventType = other }));
      };
    };
  };

  /// Parse app_mention event
  func parseAppMentionEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackAppMentionEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in app_mention event") };
    };
    let text = switch (Json.get(json, "text")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'text' in app_mention event") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in app_mention event") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in app_mention event") };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let threadTs = switch (Json.get(json, "thread_ts")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };

    #ok({ user; text; ts; channel; event_ts = eventTs; thread_ts = threadTs });
  };

  /// Parse message event — dispatches to subtype-specific parsers
  func parseMessageEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let subtype = switch (Json.get(json, "subtype")) {
      case (?#string(s)) { ?s };
      case _ { null };
    };

    switch (subtype) {
      case (null) { parseStandardMessage(json) };
      case (?"bot_message") {
        // Legacy event — new Slack apps do not receive bot_message. Explicitly skip.
        #ok(#skip({ subtype = "bot_message" }));
      };
      case (?"me_message") { parseMeMessage(json) };
      case (?"message_changed") { parseMessageChangedEvent(json) };
      case (?"message_deleted") { parseMessageDeletedEvent(json) };
      case (?"thread_broadcast") {
        // Thread reply broadcast to channel. Intentionally skipped — we focus on dedicated thread conversations.
        #ok(#skip({ subtype = "thread_broadcast" }));
      };
      case (?other) {
        // Catch-all: log and capture minimal fields
        Logger.log(#info, ?"SlackAdapter", "Unhandled message subtype: " # other);
        let channel = switch (Json.get(json, "channel")) {
          case (?#string(c)) { c };
          case _ { "" };
        };
        let ts = switch (Json.get(json, "ts")) {
          case (?#string(t)) { t };
          case _ { "" };
        };
        #ok(#other({ subtype = other; channel; ts }));
      };
    };
  };

  /// Parse standard message (no subtype)
  func parseStandardMessage(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in standard message") };
    };
    let text = switch (Json.get(json, "text")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'text' in standard message") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in standard message") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in standard message") };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let threadTs = switch (Json.get(json, "thread_ts")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };
    let botId = switch (Json.get(json, "bot_id")) {
      case (?#string(b)) { ?b };
      case _ { null };
    };
    let appId = switch (Json.get(json, "app_id")) {
      case (?#string(a)) { ?a };
      case _ { null };
    };
    let agentMetadata : ?Types.AgentMessageMetadata = switch (Json.get(json, "metadata")) {
      case (?metaJson) { parseAgentMetadata(metaJson) };
      case _ { null };
    };

    #ok(#standard({ user; text; ts; channel; eventTs; threadTs; botId; appId; agentMetadata }));
  };

  /// Parse the `metadata` block embedded in an own-bot reply.
  ///
  /// Returns `null` on any mismatch or missing field so callers receive a clean
  /// optional rather than a parse error.
  private func parseAgentMetadata(json : Json.Json) : ?Types.AgentMessageMetadata {
    let eventType = switch (Json.get(json, "event_type")) {
      case (?#string(t)) { t };
      case _ { return null };
    };
    // Validate the event_type sentinel; reject anything else.
    if (eventType != "looping_agent_message") { return null };

    let payloadJson = switch (Json.get(json, "event_payload")) {
      case (?p) { p };
      case _ { return null };
    };
    let parentAgent = switch (Json.get(payloadJson, "parent_agent")) {
      case (?#string(a)) { a };
      case _ { return null };
    };
    let parentTs = switch (Json.get(payloadJson, "parent_ts")) {
      case (?#string(t)) { t };
      case _ { return null };
    };
    let parentChannel = switch (Json.get(payloadJson, "parent_channel")) {
      case (?#string(c)) { c };
      case _ { return null };
    };
    let turnId : Text = switch (Json.get(payloadJson, "turn_id")) {
      case (?#string(t)) { t };
      case _ { return null };
    };
    ?{
      event_type = eventType;
      event_payload = {
        parent_agent = parentAgent;
        parent_ts = parentTs;
        parent_channel = parentChannel;
        turn_id = turnId;
      };
    };
  };

  /// Parse me_message subtype
  func parseMeMessage(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in me_message") };
    };
    let text = switch (Json.get(json, "text")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'text' in me_message") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in me_message") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in me_message") };
    };

    #ok(#meMessage({ user; text; ts; channel }));
  };

  /// Parse message_changed subtype
  /// Also detects assistant_app_thread nested inside message_changed
  func parseMessageChangedEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in message_changed") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in message_changed") };
    };

    // Parse nested message object
    let msgJson = switch (Json.get(json, "message")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'message' object in message_changed") };
    };

    // Check if inner message is an assistant_app_thread
    let innerSubtype = switch (Json.get(msgJson, "subtype")) {
      case (?#string(s)) { ?s };
      case _ { null };
    };

    switch (innerSubtype) {
      case (?"assistant_app_thread") {
        // Parse as assistant_app_thread
        let user = switch (Json.get(msgJson, "user")) {
          case (?#string(u)) { u };
          case _ {
            return #err("Missing 'user' in assistant_app_thread message");
          };
        };
        let text = switch (Json.get(msgJson, "text")) {
          case (?#string(t)) { t };
          case _ { "" };
        };
        let innerTs = switch (Json.get(msgJson, "ts")) {
          case (?#string(t)) { t };
          case _ { return #err("Missing 'ts' in assistant_app_thread message") };
        };
        let threadTs = switch (Json.get(msgJson, "thread_ts")) {
          case (?#string(t)) { t };
          case _ {
            return #err("Missing 'thread_ts' in assistant_app_thread message");
          };
        };
        // Extract title from assistant_app_thread object
        let title = switch (Json.get(msgJson, "assistant_app_thread")) {
          case (?aatJson) {
            switch (Json.get(aatJson, "title")) {
              case (?#string(t)) { ?t };
              case _ { null };
            };
          };
          case _ { null };
        };

        #ok(#assistantAppThread({ user; text; ts = innerTs; channel; threadTs; title }));
      };
      case _ {
        // Regular message_changed
        let msgUser = switch (Json.get(msgJson, "user")) {
          case (?#string(u)) { u };
          case _ { return #err("Missing 'user' in message_changed message") };
        };
        let msgText = switch (Json.get(msgJson, "text")) {
          case (?#string(t)) { t };
          case _ { "" };
        };
        let msgTs = switch (Json.get(msgJson, "ts")) {
          case (?#string(t)) { t };
          case _ { return #err("Missing 'ts' in message_changed message") };
        };
        let msgThreadTs = switch (Json.get(msgJson, "thread_ts")) {
          case (?#string(t)) { ?t };
          case _ { null };
        };
        let edited = switch (Json.get(msgJson, "edited")) {
          case (?editedJson) {
            let editedUser = switch (Json.get(editedJson, "user")) {
              case (?#string(u)) { u };
              case _ { return #err("Missing 'user' in edited") };
            };
            let editedTs = switch (Json.get(editedJson, "ts")) {
              case (?#string(t)) { t };
              case _ { return #err("Missing 'ts' in edited") };
            };
            ?{ user = editedUser; ts = editedTs };
          };
          case _ { null };
        };

        #ok(#messageChanged({ channel; ts; message = { user = msgUser; text = msgText; ts = msgTs; threadTs = msgThreadTs; edited } }));
      };
    };
  };

  /// Parse message_deleted subtype
  func parseMessageDeletedEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in message_deleted") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in message_deleted") };
    };
    let deletedTs = switch (Json.get(json, "deleted_ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'deleted_ts' in message_deleted") };
    };

    #ok(#messageDeleted({ channel; ts; deletedTs }));
  };

  /// Parse assistant_thread_started event
  func parseAssistantThreadStartedEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackAssistantThreadStartedEvent;
    #err : Text;
  } {
    let atJson = switch (Json.get(json, "assistant_thread")) {
      case (?obj) { obj };
      case _ {
        return #err("Missing 'assistant_thread' in assistant_thread_started");
      };
    };
    let userId = switch (Json.get(atJson, "user_id")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user_id' in assistant_thread") };
    };
    let channelId = switch (Json.get(atJson, "channel_id")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel_id' in assistant_thread") };
    };
    let threadTs = switch (Json.get(atJson, "thread_ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'thread_ts' in assistant_thread") };
    };
    let contextJson = switch (Json.get(atJson, "context")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'context' in assistant_thread") };
    };
    let forceSearch = switch (Json.get(contextJson, "force_search")) {
      case (?#bool(b)) { b };
      case _ { false }; // default false when not present
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    #ok({
      assistant_thread = {
        user_id = userId;
        context = { force_search = forceSearch };
        channel_id = channelId;
        thread_ts = threadTs;
      };
      event_ts = eventTs;
    });
  };

  /// Parse assistant_thread_context_changed event
  func parseAssistantThreadContextChangedEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackAssistantThreadContextChangedEvent;
    #err : Text;
  } {
    let atJson = switch (Json.get(json, "assistant_thread")) {
      case (?obj) { obj };
      case _ {
        return #err("Missing 'assistant_thread' in assistant_thread_context_changed");
      };
    };
    let userId = switch (Json.get(atJson, "user_id")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user_id' in assistant_thread") };
    };
    let channelId = switch (Json.get(atJson, "channel_id")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel_id' in assistant_thread") };
    };
    let threadTs = switch (Json.get(atJson, "thread_ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'thread_ts' in assistant_thread") };
    };
    let contextJson = switch (Json.get(atJson, "context")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'context' in assistant_thread") };
    };
    let ctxChannelId = switch (Json.get(contextJson, "channel_id")) {
      case (?#string(c)) { ?c };
      case _ { null };
    };
    let ctxTeamId = switch (Json.get(contextJson, "team_id")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };
    let ctxEnterpriseId = switch (Json.get(contextJson, "enterprise_id")) {
      case (?#string(e)) { ?e };
      case _ { null };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    #ok({
      assistant_thread = {
        user_id = userId;
        context = {
          channel_id = ctxChannelId;
          team_id = ctxTeamId;
          enterprise_id = ctxEnterpriseId;
        };
        channel_id = channelId;
        thread_ts = threadTs;
      };
      event_ts = eventTs;
    });
  };

  // ============================================
  // Normalization: Slack → Internal Event
  // ============================================

  /// Parse member_joined_channel event
  func parseMemberJoinedChannelEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMemberJoinedChannelEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in member_joined_channel") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in member_joined_channel") };
    };
    let channelType = switch (Json.get(json, "channel_type")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let team = switch (Json.get(json, "team")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    #ok({ user; channel; channel_type = channelType; team; event_ts = eventTs });
  };

  /// Parse member_left_channel event
  func parseMemberLeftChannelEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMemberLeftChannelEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in member_left_channel") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in member_left_channel") };
    };
    let channelType = switch (Json.get(json, "channel_type")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let team = switch (Json.get(json, "team")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    #ok({ user; channel; channel_type = channelType; team; event_ts = eventTs });
  };

  /// Parse team_join event (new workspace member)
  func parseTeamJoinEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackTeamJoinEvent;
    #err : Text;
  } {
    let userJson = switch (Json.get(json, "user")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'user' object in team_join") };
    };
    let userId = switch (Json.get(userJson, "id")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user.id' in team_join") };
    };
    let name = switch (Json.get(userJson, "name")) {
      case (?#string(n)) { n };
      case _ { return #err("Missing 'user.name' in team_join") };
    };
    let realName = switch (Json.get(userJson, "real_name")) {
      case (?#string(r)) { ?r };
      case _ { null };
    };
    let isPrimaryOwner = switch (Json.get(userJson, "is_primary_owner")) {
      case (?#bool(b)) { b };
      case _ { false };
    };
    let isAdmin = switch (Json.get(userJson, "is_admin")) {
      case (?#bool(b)) { b };
      case _ { false };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    #ok({
      user = {
        id = userId;
        name;
        real_name = realName;
        is_primary_owner = isPrimaryOwner;
        is_admin = isAdmin;
      };
      event_ts = eventTs;
    });
  };

  /// Convert a parsed SlackEventCallback into a normalized Event
  ///
  /// @param callback - Parsed Slack event callback
  /// @returns Normalized event or error (e.g., unhandled event type, skippable subtype)
  public func normalizeEvent(callback : SlackEventTypes.SlackEventCallback) : {
    #ok : NormalizedEventTypes.Event;
    #err : Text;
  } {
    let payload : NormalizedEventTypes.EventPayload = switch (callback.event) {
      case (#app_mention(mention)) {
        // app_mention normalizes to #message (same shape)
        #message({
          user = mention.user;
          text = mention.text;
          channel = mention.channel;
          ts = mention.ts;
          threadTs = mention.thread_ts;
          isBotMessage = false;
          agentMetadata = null;
        });
      };
      case (#message(msg)) {
        switch (msg) {
          case (#standard(m)) {
            let isOwnBot = m.botId != null and m.appId == ?callback.api_app_id;
            if (isOwnBot) {
              // Allow own-bot messages through ONLY when they carry agent metadata
              // (metadata IS the lineage for round tracking).
              // Messages without metadata (e.g. plain bot notifications) are skipped —
              // there is no recoverable session context without it.
              // This gate works for all channel topologies including DMs, because it
              // depends solely on the metadata field, not on thread structure.
              switch (m.agentMetadata) {
                case (null) {
                  Logger.log(#info, ?"SlackAdapter", "Skipping own-bot message without agent metadata (app_id=" # callback.api_app_id # ")");
                  return #err("Skipping own-bot message without agent metadata");
                };
                case (?_) {
                  Logger.log(#info, ?"SlackAdapter", "Allowing own-bot message with agent metadata for round tracking (app_id=" # callback.api_app_id # ")");
                };
              };
            };
            #message({
              user = m.user;
              text = m.text;
              channel = m.channel;
              ts = m.ts;
              threadTs = m.threadTs;
              isBotMessage = isOwnBot;
              agentMetadata = m.agentMetadata;
            });
          };
          case (#meMessage(m)) {
            #message({
              user = m.user;
              text = m.text;
              channel = m.channel;
              ts = m.ts;
              threadTs = null;
              isBotMessage = false;
              agentMetadata = null;
            });
          };
          case (#messageChanged(m)) {
            #messageEdited({
              channel = m.channel;
              messageTs = m.message.ts;
              threadTs = m.message.threadTs;
              newText = m.message.text;
              editedBy = switch (m.message.edited) {
                case (?e) { ?e.user };
                case (null) { null };
              };
            });
          };
          case (#messageDeleted(m)) {
            #messageDeleted({
              channel = m.channel;
              deletedTs = m.deletedTs;
            });
          };
          case (#assistantAppThread(m)) {
            // assistant_app_thread is a hidden=true system event where Slack updates the
            // thread's title and metadata after the first message is posted.
            // Route as #assistantThreadEvent so the handler can track metadata changes.
            #assistantThreadEvent({
              eventType = #threadMetadataUpdated;
              userId = m.user;
              channelId = m.channel;
              threadTs = m.threadTs;
              eventTs = m.ts;
              context = #metadataUpdated({
                title = m.title;
                text = m.text;
              });
            });
          };
          case (#skip({ subtype })) {
            // Known subtype, explicitly decided to skip — no queuing, no processing.
            Logger.log(#info, ?"SlackAdapter", "Skipping known subtype: " # subtype);
            return #err("Skipping known subtype: " # subtype);
          };
          case (#other({ subtype })) {
            Logger.log(#info, ?"SlackAdapter", "Skipping unhandled message subtype: " # subtype);
            return #err("Skipping unhandled message subtype: " # subtype);
          };
        };
      };
      case (#assistant_thread_started(e)) {
        #assistantThreadEvent({
          eventType = #threadStarted;
          userId = e.assistant_thread.user_id;
          channelId = e.assistant_thread.channel_id;
          threadTs = e.assistant_thread.thread_ts;
          eventTs = e.event_ts;
          context = #started({
            forceSearch = e.assistant_thread.context.force_search;
          });
        });
      };
      case (#assistant_thread_context_changed(e)) {
        #assistantThreadEvent({
          eventType = #threadContextChanged;
          userId = e.assistant_thread.user_id;
          channelId = e.assistant_thread.channel_id;
          threadTs = e.assistant_thread.thread_ts;
          eventTs = e.event_ts;
          context = #contextChanged({
            channelId = e.assistant_thread.context.channel_id;
            teamId = e.assistant_thread.context.team_id;
            enterpriseId = e.assistant_thread.context.enterprise_id;
          });
        });
      };
      case (#unknown({ eventType })) {
        return #err("Unsupported event type: " # eventType);
      };
      case (#member_joined_channel(e)) {
        #memberJoinedChannel({
          userId = e.user;
          channelId = e.channel;
          channelType = e.channel_type;
          teamId = e.team;
          eventTs = e.event_ts;
        });
      };
      case (#member_left_channel(e)) {
        #memberLeftChannel({
          userId = e.user;
          channelId = e.channel;
          channelType = e.channel_type;
          teamId = e.team;
          eventTs = e.event_ts;
        });
      };
      case (#team_join(e)) {
        #teamJoin({
          userId = e.user.id;
          displayName = e.user.name;
          realName = e.user.real_name;
          isPrimaryOwner = e.user.is_primary_owner;
          isOrgAdmin = e.user.is_admin;
          eventTs = e.event_ts;
        });
      };
    };

    #ok({
      source = #slack;
      idempotencyKey = callback.event_id;
      eventId = NormalizedEventTypes.buildEventId(#slack, callback.event_id);
      timestamp = callback.event_time;
      payload;
      enqueuedAt = 0; // Set by EventStoreModel.enqueue
      claimedAt = null;
      processedAt = null;
      failedAt = null;
      failedError = "";
      processingLog = [];
    });
  };

  // ============================================
  // Block Kit interactive payload parsing
  // ============================================

  /// Parse a percent-decoded Slack Block Kit interactive payload JSON string.
  ///
  /// Slack sends interactive component payloads (button clicks, etc.) as:
  ///   payload=<url-encoded-json>
  ///
  /// The JSON structure for a button action contains:
  ///   { "type": "block_actions", "user": { "id": ... }, "team": { "id": ... },
  ///     "message": { "ts": ... }, "channel": { "id": ... },
  ///     "actions": [{ "action_id": ..., "value": ... }] }
  ///
  /// We extract the first action only (Slack sends one action per interactive payload).
  private func parseBlockActionsPayload(decodedJson : Text) : {
    #ok : SlackEventTypes.SlackEnvelope;
    #err : Text;
  } {
    let json = switch (Json.parse(decodedJson)) {
      case (#err(e)) {
        return #err("Failed to parse block_actions JSON: " # debug_show e);
      };
      case (#ok(j)) { j };
    };

    let payloadType = switch (Json.get(json, "type")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'type' in interactive payload") };
    };

    if (payloadType != "block_actions") {
      return #ok(#unknown(payloadType));
    };

    let userId = switch (Json.get(json, "user.id")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user.id' in block_actions payload") };
    };

    let messageTs = switch (Json.get(json, "message.ts")) {
      case (?#string(ts)) { ts };
      case _ { "" }; // message may be absent in some surfaces
    };

    let channelId = switch (Json.get(json, "channel.id")) {
      case (?#string(c)) { c };
      case _ { "" }; // channel may be absent in some surfaces
    };

    // Extract first action from the actions array
    let (actionId, actionValue) = switch (Json.get(json, "actions")) {
      case (?#array(actions)) {
        if (actions.size() == 0) {
          return #err("Empty 'actions' array in block_actions payload");
        };
        let firstAction = actions[0];
        let aid = switch (Json.get(firstAction, "action_id")) {
          case (?#string(a)) { a };
          case _ { return #err("Missing 'action_id' in first action") };
        };
        let aval = switch (Json.get(firstAction, "value")) {
          case (?#string(v)) { v };
          case _ { "" }; // value is optional for some action types
        };
        (aid, aval);
      };
      case _ {
        return #err("Missing or invalid 'actions' in block_actions payload");
      };
    };

    // response_url is provided by Slack for interactive payloads — it's a
    // pre-authenticated POST target for async message updates (valid for 30 min).
    let responseUrl = switch (Json.get(json, "response_url")) {
      case (?#string(u)) { u };
      case _ { "" }; // absent on some surfaces; handler should guard on empty
    };

    #ok(
      #block_actions({
        userId;
        actionId;
        actionValue;
        messageTs;
        channelId;
        responseUrl;
      })
    );
  };
};
