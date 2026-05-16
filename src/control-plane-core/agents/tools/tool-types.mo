import AgentModel "../../models/agent-model";
import SessionModel "../../models/session-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import SecretModel "../../models/secret-model";
import WorkflowEnvelopeModel "../../models/workflow-envelope-model";
import WorkflowCatalogModel "../../models/workflow-catalog-model";
import ApprovalModel "../../models/approval-model";
import WorkflowTypes "../../types/workflow";
import InternalEngine "../../../internal-engine/main";

module {
  // ============================================
  // Shared Tool Types
  // ============================================

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
    durationMs : Nat;
  };

  /// Outcome of a tool call execution
  public type ToolCallOutcome = {
    #ok : Text; // JSON string result
    #err : Text; // Structured JSON error: {"type":"camelCase","message":"..."}
  };

  // ============================================
  // Engine Dispatch Types
  // ============================================

  /// Engine dispatch resources — envelope state, pre-resolved engine actor, catalog state, and approval state.
  /// Passed to workflow tools so they can issue envelopes and dispatch to the engine.
  public type EngineDispatch = {
    envelopeState : WorkflowEnvelopeModel.EnvelopeState;
    internalEngine : InternalEngine.InternalEngine;
    catalogState : WorkflowCatalogModel.CatalogState;
    approvalState : ApprovalModel.ApprovalState;
  };

  /// Per-turn envelope context needed to build a WorkflowEnvelope.
  /// All fields map directly onto EnvelopePayload fields — nothing else.
  public type EnvelopeContext = {
    agent : AgentModel.AgentRecord;
    turnId : Text;
    instructions : Text;
    messages : [WorkflowTypes.ChatMessage];
    apiKey : Text;
  };

  // ============================================
  // Function Tool Resources
  // ============================================

  /// Resources that can be provided to function tools.
  /// Each resource is optional - tools requiring unavailable resources are excluded.
  /// This creates a natural allowlist mechanism controlled by the caller.
  public type ToolResources = {
    // Current workspace context
    workspaceId : ?Nat;

    // Slack bot token resolver — returns the decrypted Slack bot token for the org.
    // Takes an operation name for audit logging.
    // Only admin-category agents receive a resolver closure; all others get null.
    // Tools call this on-demand rather than receiving pre-fetched tokens.
    resolveSlackBotToken : ?(Text -> ?Text);

    // Slack user identity of the user who triggered this agent turn.
    // Required for authorization checks in workspace-management write tools.
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;

    // Source reference for the turn (Slack channel + ts + threadTs).
    // Used by workflow tools that need to post back to the originating thread
    // (e.g. approval prompt). Separate from EnvelopeContext because it is not
    // part of the engine payload.
    sourceRef : ?SessionModel.SourceRef;

    // Secrets store - if provided, secrets-management tools are available.
    // write=true enables store_secret and delete_secret.
    // All secrets tools also require workspaceId and userAuthContext.
    secrets : ?{
      state : SecretModel.SecretsState;
      workspaceKey : [Nat8];
      write : Bool;
    };

    // Engine dispatch resources — if provided, workflow engine tools are available.
    // Carries the envelope state (token store + counter + salt) and the pre-resolved engine actor.
    engineDispatch : ?EngineDispatch;

    // Per-turn envelope context needed by workflow tools to build the WorkflowEnvelope.
    // Requires engineDispatch to also be set.
    envelopeContext : ?EnvelopeContext;
  };
};
