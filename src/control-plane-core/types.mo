import InternalEngine "../internal-engine/main";
import WorkflowCatalogModel "./models/workflow-catalog-model";
import OpenRouterWrapper "./wrappers/openrouter-wrapper";

module {
  /// Log level for filtering and categorizing messages
  public type LogLevel = {
    #_debug; // "_" prefix needed, `debug` is reserved in Motoko
    #info;
    #warn;
    #error;
  };

  /// Secret identifier for encrypted-at-rest secrets
  /// Each variant represents a distinct secret that can be stored per workspace
  public type SecretId = {
    #openRouterApiKey;
    #slackBotToken;
    #slackSigningSecret;
    #relaySharedSecret; // HMAC shared secret for Cloudflare Worker relay webhook verification
    #custom : Text; // admin-defined key name; stored as "custom:<name>" in the map
  };

  // ============================================
  // HTTP Types (for webhooks and incoming requests)
  // ============================================

  public type HeaderField = (Text, Text);

  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
    certificate_version : ?Nat16;
  };

  public type HttpUpdateRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };

  public type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    upgrade : ?Bool;
  };

  // ============================================
  // Processing Step — handler observability
  // ============================================

  /// A single step taken by a handler during event processing.
  /// Provides observability into what actions were attempted and their outcomes.
  /// Defined here (rather than in events/types/) so orchestrators and other
  /// non-event modules can also emit and return steps without a cross-layer import.
  public type ProcessingStep = {
    action : Text; // e.g. "llm_call", "post_to_slack", "update_channel_history"
    result : { #ok; #err : Text };
    timestamp : Int; // Time.now() when this step completed
  };

  // ============================================
  // Agent Orchestration Types
  // ============================================

  /// Engine dispatch dependencies threaded into agent loops.
  public type AgentEngineDeps<EnvelopeState> = {
    envelopeState : EnvelopeState;
    internalEngine : InternalEngine.InternalEngine;
    catalogState : WorkflowCatalogModel.CatalogState;
  };

  /// Suspension data captured when an agent turn is suspended waiting for an async workflow result.
  /// Stored inside TurnStatus so the checkpoint is co-located with the turn state.
  public type SuspensionData = {
    /// Full LLM conversation history at the point of suspension.
    /// Cannot be reconstructed from traces (traces are observability data, not LLM replay logs).
    messages : [OpenRouterWrapper.ResponseInputMessage];
    /// Call ID of the specific tool call that dispatched the workflow.
    /// Required because a single LLM round may emit multiple tool calls; we need the exact one.
    pendingToolCallId : Text;
    /// Loop round counter at suspension — used to enforce MAX_AGENT_ROUNDS across the resume boundary.
    roundCount : Nat;
  };

  /// Shared result returned by agent orchestration and category loops.
  public type AgentOrchestrateResult = {
    #dispatched : {
      steps : [ProcessingStep];
      suspension : SuspensionData;
    };
    #awaitingApproval : {
      steps : [ProcessingStep];
      suspension : SuspensionData;
      approvalCode : Text;
    };
    #ok : {
      response : Text;
      steps : [ProcessingStep];
    };
    #err : {
      message : Text;
      steps : [ProcessingStep];
    };
  };

  // ============================================
  // Agent Message Metadata
  // ============================================

  /// Metadata embedded in every agent reply.
  ///
  /// Metadata is embedded in every bot reply posted via chat.postMessage.
  /// When the reply is received back as a Slack event, the adapter parses this
  /// metadata to reconstruct the lineage and round count — no separate
  /// server-side round-context index required.

  /// The payload carried inside every agent message metadata block.
  /// Extracted as a standalone type so callers that only need lineage data
  /// (e.g. ChannelMessage) don't have to carry the outer Slack envelope.
  /// `event_payload.parent_agent`   — bare agent name that produced this reply (e.g. `"admin"`, no `::` prefix).
  /// `event_payload.parent_ts`      — ts of the message this is a reply to.
  /// `event_payload.parent_channel` — channel of that message (ts is channel-scoped;
  ///                                   both fields are needed for an unambiguous lookup).
  public type AgentMetadataPayload = {
    parent_agent : Text; // bare name of the agent that produced this reply (no "::" prefix)
    parent_ts : Text; // ts of the message that triggered this reply
    parent_channel : Text; // channel of that message (ts is channel-scoped)
    turn_id : Text; // turnId that produced this reply
  };

  /// `event_type` is always `"looping_agent_message"` — validated on receipt;
  /// any other value causes the parser to return `null` (treated as absent).
  public type AgentMessageMetadata = {
    event_type : Text;
    event_payload : AgentMetadataPayload;
  };
};
