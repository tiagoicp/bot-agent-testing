import Error "mo:core/Error";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Array "mo:core/Array";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Json "mo:json";
import { str; obj; bool; int } "mo:json";

import InternalEngine "../../src/internal-engine/main";
import WorkflowCatalog "../../src/internal-engine/workflows/workflow-catalog";

import HttpWrapper "../../src/control-plane-core/wrappers/http-wrapper";
import OpenRouterWrapper "../../src/control-plane-core/wrappers/openrouter-wrapper";
import SlackWrapper "../../src/control-plane-core/wrappers/slack-wrapper";
import HttpCertification "../../src/control-plane-core/utilities/http-certification";
import MessageHandler "../../src/control-plane-core/events/handlers/message-handler";
import BlockActionsHandler "../../src/control-plane-core/events/handlers/block-actions-handler";
import SlackEventTypes "../../src/control-plane-core/events/types/slack-event-types";
import MessageDeletedHandler "../../src/control-plane-core/events/handlers/message-deleted-handler";
import MessageEditedHandler "../../src/control-plane-core/events/handlers/message-edited-handler";
import AssistantThreadHandler "../../src/control-plane-core/events/handlers/assistant-thread-handler";
import TeamJoinHandler "../../src/control-plane-core/events/handlers/team-join-handler";
import MemberJoinedChannelHandler "../../src/control-plane-core/events/handlers/member-joined-channel-handler";
import MemberLeftChannelHandler "../../src/control-plane-core/events/handlers/member-left-channel-handler";
import NormalizedEventTypes "../../src/control-plane-core/events/types/normalized-event-types";
import SlackAdapter "../../src/control-plane-core/events/slack-adapter";

import StoreSecretHandler "../../src/control-plane-core/agents/tools/handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "../../src/control-plane-core/agents/tools/handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "../../src/control-plane-core/agents/tools/handlers/secrets/delete-secret-handler";
import WorkflowEngineHandler "../../src/control-plane-core/agents/tools/handlers/workflow-engine-handler";
import WorkflowCatalogTypes "../../src/control-plane-core/types/workflow-catalog";
import EngineDispatchService "../../src/control-plane-core/services/engine-dispatch-service";
import WorkflowTypes "../../src/control-plane-core/types/workflow";
import WeeklyReconciliationRunner "../../src/control-plane-core/timers/weekly-reconciliation-runner";
import ClearKeyCacheRunner "../../src/control-plane-core/timers/clear-key-cache-runner";
import ProcessedEventsCleanupRunner "../../src/control-plane-core/timers/processed-events-cleanup-runner";
import ChannelHistoryPruneRunner "../../src/control-plane-core/timers/channel-history-prune-runner";
import TurnCleanupRunner "../../src/control-plane-core/timers/turn-cleanup-runner";
import EngineTopupRunner "../../src/control-plane-core/timers/engine-topup-runner";
import SlackEventIntakeService "../../src/control-plane-core/services/slack-event-intake-service";
import ChannelHistoryModel "../../src/control-plane-core/models/channel-history-model";
import SlackUserModel "../../src/control-plane-core/models/slack-user-model";
import SlackAuthMiddleware "../../src/control-plane-core/middleware/slack-auth-middleware";
import WorkspaceModel "../../src/control-plane-core/models/workspace-model";
import AgentModel "../../src/control-plane-core/models/agent-model";
import KeyDerivationService "../../src/control-plane-core/services/key-derivation-service";
import SecretModel "../../src/control-plane-core/models/secret-model";
import EventStoreModel "../../src/control-plane-core/models/event-store-model";
import SessionModel "../../src/control-plane-core/models/session-model";
import WorkflowEnvelopeModel "../../src/control-plane-core/models/workflow-envelope-model";
import WorkflowCatalogModel "../../src/control-plane-core/models/workflow-catalog-model";
import ApprovalModel "../../src/control-plane-core/models/approval-model";
import WorkflowApiService "../../src/control-plane-core/services/workflow-api-service";
import WorkflowAsyncEffectService "../../src/control-plane-core/services/workflow-async-effect-service";
import EventProcessingContextTypes "../../src/control-plane-core/events/types/event-processing-context";
import AgentRunner "../../src/control-plane-core/agents/agent-runner";
import ToolExecutor "../../src/control-plane-core/agents/tools/tool-executor";
import ToolTypes "../../src/control-plane-core/agents/tools/tool-types";
import Types "../../src/control-plane-core/types";
import TestHelpers "./test-helpers";

// ============================================
// Test Canister
// ============================================

// IMPORTANT:
// Never add this canister to icp.yaml or deploy it

shared ({ caller = parent }) persistent actor class TestCanister() = self {
  // Store for HTTP certification testing
  var certStore = HttpCertification.initStore();

  // Persistent Slack user state for tests (cache + access change log).
  // This allows us to verify state changes and audit log entries across handler calls.
  var slackUsers = SlackUserModel.emptyState();

  // Persistent key cache for testing key derivation mechanics.
  // Starts empty; tests seed it via testSeedKeyForWorkspace or test methods.
  var testKeyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache();

  // Pre-seeded workspace state with channel anchors for handler tests.
  //   Workspace 0: Default (no channel anchors) — from emptyState()
  //   Workspace 1: adminChannelId = C_ADMIN_CHANNEL
  //   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN
  let testWorkspacesState : WorkspaceModel.WorkspacesState = do {
    let s = WorkspaceModel.emptyState();
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 1"); // id = 1
    ignore WorkspaceModel.setAdminChannel(s, 1, "C_ADMIN_CHANNEL");
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 2"); // id = 2
    ignore WorkspaceModel.setAdminChannel(s, 2, "C_ROUND_TRIP_ADMIN");
    s;
  };

  // Agent registry state for agent handler tests. Starts empty; tests
  // register agents through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  let testAgentRegistry = AgentModel.emptyState();

  // Secrets map and key cache for secrets handler tests. Starts empty; tests
  // store/delete secrets through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  // The key cache is pre-seeded with the all-zeros dummy key for workspaces 0, 1, 2
  // to avoid live Schnorr calls during unit tests.
  let testSecretsMap = SecretModel.initState();
  let testSecretsKeyCache : KeyDerivationService.KeyCache = Map.fromArray<Nat, [Nat8]>(
    [(0, TestHelpers.dummyKey), (1, TestHelpers.dummyKey), (2, TestHelpers.dummyKey)],
    Nat.compare,
  );

  // Event store state for event handler tests. Starts empty; tests seed events
  // through the testSeedFailedEvent helper and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  let testEventStore = EventStoreModel.empty();

  // Channel history store for channel-history-prune runner tests.
  let testChannelHistoryStore = ChannelHistoryModel.empty();

  // Session stores dedicated to turn-cleanup-runner tests.
  let testCleanupSessionStores = SessionModel.emptyStores();

  // Envelope state paired with testCleanupSessionStores for turn-cleanup-runner tests.
  let testCleanupEnvelopeState = WorkflowEnvelopeModel.emptyState();

  // Dispatch-path session stores — shared across testMessageHandlerDispatch calls
  // so testGetTurnStatus can observe turn state after the handler returns.
  let testDispatchSessionStores = SessionModel.emptyStores();

  // Approval state paired with testDispatchSessionStores for block-actions-handler tests.
  // Persists within a canister instance so testSeedApprovalRecord / testHandleBlockAction /
  // testGetApprovalStatus can observe state changes across separate calls.
  let testDispatchApprovalState = ApprovalModel.emptyState();

  // Workflow API token store — dedicated store for workflowApi endpoint tests.
  let testWorkflowEnvelopeState = WorkflowEnvelopeModel.emptyState();

  // Internal engine principal for workflowApi authorization guard tests.
  var testInternalEnginePrincipal : ?Principal = null;

  let mockInternalEngine : InternalEngine.InternalEngine = actor (Principal.toText(Principal.fromActor(self))) : InternalEngine.InternalEngine;

  // Workflow API service wired up for unit tests.
  transient let testWorkflowApiService = WorkflowApiService.Service({
    envelopeState = testWorkflowEnvelopeState;
    workspaces = testWorkspacesState;
    agentRegistry = testAgentRegistry;
    approvalState = ApprovalModel.emptyState();
    eventStore = testEventStore;
    sessionStores = testDispatchSessionStores;
  });

  // Workflow async effect end-to-end test state.
  // Uses AgentModel.defaultState() so agent 0 (workspace-admin, ownedBy=0) is pre-seeded.
  let testEffectAgentRegistry = AgentModel.defaultState();
  let testEffectSessionStores = SessionModel.emptyStores();
  let testEffectEnvelopeState = WorkflowEnvelopeModel.emptyState();
  transient let testEffectWorkflowApiService = WorkflowApiService.Service({
    envelopeState = testEffectEnvelopeState;
    workspaces = testWorkspacesState;
    agentRegistry = testEffectAgentRegistry;
    approvalState = ApprovalModel.emptyState();
    eventStore = testEventStore;
    sessionStores = testEffectSessionStores;
  });
  // Secrets store and key cache for the async-effect service (workspace 0 only).
  // The dummy key lets the service resolve secrets without a live Schnorr call.
  let testEffectSecretsState = SecretModel.initState();
  let testEffectKeyCache : KeyDerivationService.KeyCache = Map.fromArray<Nat, [Nat8]>(
    [(0, TestHelpers.dummyKey)],
    Nat.compare,
  );
  transient let testEffectAsyncEffectService = WorkflowAsyncEffectService.Service({
    sessionStores = testEffectSessionStores;
    agentRegistry = testEffectAgentRegistry;
    workspaces = testWorkspacesState;
    secrets = testEffectSecretsState;
    approvalState = ApprovalModel.emptyState();
    resumeAdminTurn = func(_ : Text, _ : SessionModel.SuspensionData, _ : Text) : async Types.AgentOrchestrateResult {
      #err({
        message = "resumeAdminTurn not supported in test canister";
        steps = [];
      });
    };
  });

  func outcomeToText(outcome : ToolTypes.ToolCallOutcome) : Text {
    switch (outcome) {
      case (#ok(t)) { t };
      case (#err(e)) { e };
    };
  };

  func testOrchestratorEngineDeps() : Types.AgentEngineDeps<WorkflowEnvelopeModel.EnvelopeState> {
    // Pre-seed the catalog with the real internal-engine descriptors so that
    // admin-agent-loop sees the full tool list without needing a live self-call
    // to listWorkflows(). This mirrors production behaviour where Core has already
    // fetched the catalog at least once.
    let catalog = WorkflowCatalogModel.empty();
    let catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
    WorkflowCatalogModel.replace(catalog, catalogHash, WorkflowCatalog.allDescriptors);
    {
      envelopeState = WorkflowEnvelopeModel.emptyState();
      internalEngine = mockInternalEngine;
      catalogState = catalog;
    };
  };

  func testAgentWithModel(category : AgentModel.AgentCategory, name : Text, model : Text) : AgentModel.AgentRecord {
    let allowedChannelIds = switch (category) {
      case (#_system(#admin)) { Set.empty<Text>() };
      case (_) { Set.fromArray(["C_TEST_CATEGORY"], Text.compare) };
    };
    {
      id = 999;
      ownedBy = 0;
      category;
      config = {
        name;
        model;
        workflowEngines = [#canister];
        allowedChannelIds;
        secrets = { allowed = [(0, #openRouterApiKey)]; overrides = [] };
      };
      state = {
        toolsState = Map.empty<Text, AgentModel.ToolState>();
      };
    };
  };

  func testAgent(category : AgentModel.AgentCategory, name : Text) : AgentModel.AgentRecord {
    testAgentWithModel(category, name, "openai/gpt-oss-120b");
  };

  func ensureTestInternalEngine() : async InternalEngine.InternalEngine {
    mockInternalEngine;
  };

  /// Implements the InternalEngine.InternalEngine interface so mockInternalEngine
  /// (cast to this canister) can serve the workflow catalog to admin-agent-loop.
  public shared func listWorkflows() : async {
    #ok : Text;
    #err : Text;
  } {
    let catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
    #ok(WorkflowCatalog.listWorkflowsJson(catalogHash));
  };

  public shared ({ caller = _ }) func execute(envelope : WorkflowTypes.EnvelopePayload) : async {
    #ok;
    #err : Text;
  } {
    let requiredVersion = "v1";
    let versionOk = switch (envelope.dispatchedVersion) {
      case (?v) { v == requiredVersion };
      case (null) { false };
    };
    if (not versionOk) {
      return #err(Json.stringify(obj([("type", str("versionMismatch")), ("message", str("Envelope version mismatch. Engine requires: " # requiredVersion # ".")), ("envelopeVersionRequired", str(requiredVersion))]), null));
    };

    let hasApiKey = Array.find<(Text, Text)>(
      envelope.secrets.apiKeys,
      func(kv : (Text, Text)) : Bool { kv.0 == "openrouter" },
    ) != null;
    if (not hasApiKey) {
      return #err("Missing 'openrouter' API key in envelope secrets");
    };

    #ok;
  };

  // ============================================
  // Slack Wrapper Test Methods
  // ============================================

  public shared ({ caller }) func slackGetOrganizationMembers(token : Text) : async {
    #ok : [SlackWrapper.SlackUser];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getOrganizationMembers(token);
  };

  public shared ({ caller }) func slackListChannels(token : Text, types : ?Text) : async {
    #ok : [SlackWrapper.SlackChannel];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.listChannels(token, types);
  };

  public shared ({ caller }) func slackGetChannelMembers(token : Text, channel : Text) : async {
    #ok : [Text];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getChannelMembers(token, channel);
  };

  // ============================================
  // HTTP Wrapper Test Methods
  // ============================================

  public shared ({ caller }) func httpGet(url : Text, headers : [HttpWrapper.HttpHeader]) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.get(url, headers);
  };

  public shared ({ caller }) func httpPost(url : Text, headers : [HttpWrapper.HttpHeader], body : Text) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.post(url, headers, body);
  };

  public shared ({ caller }) func openRouterReason(
    apiKey : Text,
    input : [OpenRouterWrapper.ResponseInputMessage],
    model : Text,
    trackId : OpenRouterWrapper.TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[OpenRouterWrapper.Tool],
  ) : async OpenRouterWrapper.ReasonWithToolsResult {
    assert caller == parent;
    await OpenRouterWrapper.reason(apiKey, input, model, trackId, instructions, temperature, tools);
  };

  // ============================================
  // HTTP Certification Methods
  // ============================================

  public shared ({ caller }) func httpCertInit() : async () {
    assert caller == parent;
    certStore := HttpCertification.initStore();
  };

  public shared ({ caller }) func httpCertCertifyPath(url : Text) : async () {
    assert caller == parent;
    HttpCertification.certifySkipFallbackPath(certStore, url);
  };

  public query func httpCertGetHeaders(url : Text) : async {
    #ok : [(Text, Text)];
    #err : Text;
  } {
    try {
      let headers = HttpCertification.getSkipCertificationHeaders(certStore, url);
      #ok(headers);
    } catch (_) {
      #err("Failed to get headers");
    };
  };

  /// Check if a path exists in the MerkleTree and return its details
  public query func httpCertCheckPath(url : Text) : async {
    #ok : {
      exists : Bool;
      path : [Text];
      treeHash : Blob;
    };
    #err : Text;
  } {
    try {
      let result = HttpCertification.checkPath(certStore, url);
      #ok(result);
    } catch (e) {
      #err("Failed to check path: " # Error.message(e));
    };
  };

  // ============================================
  // Events Handler Test Methods
  // ============================================

  public shared ({ caller }) func testMessageHandler(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(msg, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  /// Like testMessageHandler, but pre-seeds the context with a real Slack bot token
  /// and OpenRouter API key so the full happy-path (LLM call → Slack post) can be exercised
  /// and captured with the cassette recording system.
  public shared ({ caller }) func testMessageHandlerWithSecrets(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    openRouterApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    // Anchor workspace 0's admin channel to the incoming channel so the admin routing
    // guard passes. The setAdminChannel call is silently ignored if the channel is
    // already anchored to another workspace (e.g. C_ADMIN_CHANNEL → workspace 1 in
    // testWorkspacesState), which is fine for tests that fire before the routing guard.
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  /// Like testMessageHandlerWithSecrets, but also pre-seeds the conversation store
  /// with a parent message that carries a UserAuthContext and optionally seeds
  /// a delegation-depth chain in the session stores.
  /// This allows bot-message (isBotMessage: true) tests to exercise delegation
  /// depth checks and MAX_AGENT_ROUNDS termination logic.
  ///
  /// parentChannel     — channel where the parent message lives.
  /// parentTs          — ts of the parent message (also used as rootTs for a top-level post).
  /// delegationDepth   — number of turns to chain in sessionStores (0 = no prior delegation).
  public shared ({ caller }) func testMessageHandlerBotBranch(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    openRouterApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    delegationDepth : Nat,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    let ctx = TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]);
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      ctx.channelHistory,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ChannelHistoryModel.updateMessageContext(
      ctx.channelHistory,
      parentChannel,
      parentTs,
      parentTs,
      ?parentAuthCtx,
    );
    // Seed a delegation chain in the session stores
    var prevTurnId : ?Text = null;
    var i = 0;
    while (i < delegationDepth) {
      let turn = SessionModel.createTurn(ctx.sessionStores, 0, null, prevTurnId, ?parentAuthCtx);
      SessionModel.completeTurn(ctx.sessionStores, turn.turnId, #succeeded, null, null);
      prevTurnId := ?turn.turnId;
      i += 1;
    };
    // Override turn_id only when turns were seeded; otherwise pass msg through unchanged.
    let adjustedMsg = switch (prevTurnId) {
      case (null) { msg };
      case (?tid) {
        switch (msg.agentMetadata) {
          case (null) { msg };
          case (?m) {
            {
              user = msg.user;
              text = msg.text;
              channel = msg.channel;
              ts = msg.ts;
              threadTs = msg.threadTs;
              isBotMessage = msg.isBotMessage;
              agentMetadata = ?{
                event_type = m.event_type;
                event_payload = {
                  parent_agent = m.event_payload.parent_agent;
                  parent_ts = m.event_payload.parent_ts;
                  parent_channel = m.event_payload.parent_channel;
                  turn_id = tid;
                };
              };
            };
          };
        };
      };
    };
    await MessageHandler.handle(adjustedMsg, ctx);
  };

  /// Like `testMessageHandlerBotBranch`, but uses `ctxWithOpenRouterOnlySecrets` (no Slack
  /// bot token) so the `postTerminationIfTokenAvailable` call is a no-op.
  ///
  /// Use this for non-deferred guard tests that verify termination logic (e.g.
  /// MAX_AGENT_ROUNDS delegation depth) without needing a cassette to handle the
  /// outgoing Slack HTTPS chat.postMessage call.
  public shared ({ caller }) func testMessageHandlerBotBranchNoSlackToken(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    openRouterApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    delegationDepth : Nat,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    let ctx = TestHelpers.ctxWithOpenRouterOnlySecrets(slackUsers, testWorkspacesState, openRouterApiKey, [msg.channel]);
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      ctx.channelHistory,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ChannelHistoryModel.updateMessageContext(
      ctx.channelHistory,
      parentChannel,
      parentTs,
      parentTs,
      ?parentAuthCtx,
    );
    // Seed a delegation chain in the session stores
    var prevTurnId : ?Text = null;
    var i = 0;
    while (i < delegationDepth) {
      let turn = SessionModel.createTurn(ctx.sessionStores, 0, null, prevTurnId, ?parentAuthCtx);
      SessionModel.completeTurn(ctx.sessionStores, turn.turnId, #succeeded, null, null);
      prevTurnId := ?turn.turnId;
      i += 1;
    };
    // Override turn_id only when turns were seeded; otherwise pass msg through unchanged.
    let adjustedMsg = switch (prevTurnId) {
      case (null) { msg };
      case (?tid) {
        switch (msg.agentMetadata) {
          case (null) { msg };
          case (?m) {
            {
              user = msg.user;
              text = msg.text;
              channel = msg.channel;
              ts = msg.ts;
              threadTs = msg.threadTs;
              isBotMessage = msg.isBotMessage;
              agentMetadata = ?{
                event_type = m.event_type;
                event_payload = {
                  parent_agent = m.event_payload.parent_agent;
                  parent_ts = m.event_payload.parent_ts;
                  parent_channel = m.event_payload.parent_channel;
                  turn_id = tid;
                };
              };
            };
          };
        };
      };
    };
    await MessageHandler.handle(adjustedMsg, ctx);
  };

  /// Like `testMessageHandlerWithSecrets`, but pre-seeds the context with BOTH a
  /// `unit-test-admin` (#_system(#admin)) and a `unit-test-custom` (#custom) agent.
  ///
  /// Use this variant for primary-agent resolution tests that reference `::unit-test-custom`
  /// explicitly.  Because `route(#custom, …)` returns a stub error without making any HTTP
  /// calls, these tests complete quickly with no cassette required.
  public shared ({ caller }) func testMessageHandlerWithCustomAgent(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    openRouterApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndCustom(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  /// Like `testMessageHandlerWithCustomAgent`, but uses `TestHelpers.ctxWithSecretsAndCustomNoOpenRouter`
  /// so the admin route short-circuits at key resolution (#err) without any HTTP outcall.
  ///
  /// Use for primary-agent fallback tests on a non-deferred actor where you only need
  /// to assert that the agent WAS resolved (i.e. primary_agent_skip is NOT emitted).
  public shared ({ caller }) func testMessageHandlerWithCustomAgentNoOpenRouter(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndCustomNoOpenRouter(slackUsers, testWorkspacesState, botToken, [msg.channel]));
  };

  /// Variant of testMessageHandlerWithSecrets designed for admin routing guard tests.
  ///
  /// @param adminChannelOverride  — `[channelId]` sets workspace 0's admin channel to
  ///                                that specific channel (for wrong-channel blocking tests).
  ///                                `[]` leaves workspace 0 with no admin channel
  ///                                (for null-adminChannelId blocking tests).
  ///
  /// Unlike testMessageHandlerWithSecrets, this function does NOT set workspace 0's
  /// admin channel to msg.channel. Use it when you want the guard to fire.
  public shared ({ caller }) func testMessageHandlerAdminChannelBlocked(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    openRouterApiKey : Text,
    adminChannelOverride : ?Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    switch (adminChannelOverride) {
      case (?chId) {
        ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, chId);
      };
      case (null) {}; // leave workspace 0 with no admin channel
    };
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  /// Like testMessageHandlerWithSecrets but uses real (non-todo) engine dispatch stubs:
  /// - generateEnvelopeId returns "dispatch-test-env-001"
  /// - dispatchToEngine always returns #ok (mock engine accepts the envelope)
  ///
  /// sessionStores is the shared testDispatchSessionStores so that
  /// testGetTurnStatus can observe turn state after the call.
  public shared ({ caller }) func testMessageHandlerDispatch(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    openRouterApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    let baseCtx = TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]);
    let engine = await ensureTestInternalEngine();
    let ctx : EventProcessingContextTypes.EventProcessingContext = {
      secrets = baseCtx.secrets;
      keyCache = baseCtx.keyCache;
      channelHistory = baseCtx.channelHistory;
      agentRegistry = baseCtx.agentRegistry;
      slackUsers = baseCtx.slackUsers;
      workspaces = baseCtx.workspaces;
      eventStore = baseCtx.eventStore;
      sessionStores = testDispatchSessionStores;
      envelopeState = WorkflowEnvelopeModel.emptyState();
      internalEngine = engine;
      catalogState = {
        // Pre-seed the catalog so admin-agent-loop can build workflow tools
        // without making a live listWorkflows() call inside the test tick budget.
        var cached = ?{
          catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
          descriptors = WorkflowCatalog.allDescriptors;
        };
      };
      approvalState = ApprovalModel.emptyState();
      armApprovalTimer = func(_expiresAtNs : Int, _cb : () -> async ()) : async Nat {
        0;
      }; // no-op: timers not exercised in integration tests
    };
    await MessageHandler.handle(msg, ctx);
  };

  /// Query the status of a turn recorded in testDispatchSessionStores.
  /// Returns "running", "awaitingWorkflow", "succeeded", or "failed"; null if not found.
  public query func testGetTurnStatus(turnId : Text) : async ?Text {
    switch (SessionModel.findTurn(testDispatchSessionStores, turnId)) {
      case (null) { null };
      case (?turn) {
        let statusText = switch (turn.status) {
          case (#running) { "running" };
          case (#awaitingWorkflow(_)) { "awaitingWorkflow" };
          case (#awaitingApproval(_)) { "awaitingApproval" };
          case (#succeeded) { "succeeded" };
          case (#failed) { "failed" };
        };
        ?statusText;
      };
    };
  };

  // ============================================
  // Block Actions Handler Test Methods
  // ============================================

  /// Seed a turn in #awaitingApproval state in testDispatchSessionStores and a matching
  /// approval record in testDispatchApprovalState. Returns both the turnId and the
  /// approval code so tests can call testHandleBlockAction / testHandleBlockActionFullPipeline
  /// with the correct values.
  public shared ({ caller }) func testSeedApprovalForTurn(
    workflowName : Text,
    requestedByUserId : Text,
  ) : async { turnId : Text; approvalCode : Text } {
    assert caller == parent;
    let turn = SessionModel.createTurn(
      testDispatchSessionStores,
      0,
      ?#slack({
        channelId = "C_TEST";
        ts = "1700000010.000001";
        threadTs = null;
      }),
      null,
      null,
    );
    let code = ApprovalModel.request(
      testDispatchApprovalState,
      workflowName,
      "{}",
      0,
      0,
      turn.turnId,
      requestedByUserId,
    );
    ignore SessionModel.suspendForApproval(
      testDispatchSessionStores,
      turn.turnId,
      {
        messages = [];
        pendingToolCallId = "test-call-id";
        roundCount = 0;
      },
      code,
      Time.now() + 3_600_000_000_000,
    );
    { turnId = turn.turnId; approvalCode = code };
  };

  /// Seed an approval record in testDispatchApprovalState and return the generated code.
  /// Stores the record with workspaceId=0, agentId=0 and the supplied turnId /
  /// requestedByUserId so that testHandleBlockAction can look it up.
  public shared ({ caller }) func testSeedApprovalRecord(
    workflowName : Text,
    turnId : Text,
    requestedByUserId : Text,
  ) : async Text {
    assert caller == parent;
    ApprovalModel.request(
      testDispatchApprovalState,
      workflowName,
      "{}",
      0,
      0,
      turnId,
      requestedByUserId,
    );
  };

  /// Simulate a Slack Block Kit button click against testDispatchApprovalState.
  /// Constructs a minimal BlockActionsPayload and calls BlockActionsHandler.handle.
  /// Pass responseUrl="" to skip the response_url HTTP call.
  /// Do NOT call pic.tick() after this — the fire-and-forget resume timer must not
  /// run during approval-status validation tests (engine is absent).
  public shared ({ caller }) func testHandleBlockAction(
    actionId : Text,
    code : Text,
    slackUserId : Text,
    responseUrl : Text,
  ) : async () {
    assert caller == parent;
    let payload : SlackEventTypes.BlockActionsPayload = {
      userId = slackUserId;
      actionId;
      actionValue = code;
      messageTs = "1700000000.000001";
      channelId = "C_TEST";
      responseUrl;
    };
    let resumeDeps : AgentRunner.ResumeDeps = {
      sessionStores = testDispatchSessionStores;
      agentRegistry = testAgentRegistry;
      secrets = testSecretsMap;
      internalEngine = null;
      envelopeState = testWorkflowEnvelopeState;
      catalogState = { var cached = null };
      approvalState = testDispatchApprovalState;
    };
    let deps : BlockActionsHandler.BlockActionsDeps = {
      approvalState = testDispatchApprovalState;
      sessionStores = testDispatchSessionStores;
      agentRegistry = testAgentRegistry;
      slackUsers;
      resumeDeps;
      keyCache = testSecretsKeyCache;
    };
    await BlockActionsHandler.handle<system>(payload, deps);
  };

  /// Full-pipeline variant of testHandleBlockAction for testing the
  /// approve → resumeWithApproval → #awaitingWorkflow path.
  ///
  /// Seeds bot token and OR API key into a fresh secrets state using the dummy key,
  /// wires testEffectAgentRegistry (agent 0 pre-seeded) and the mock internal engine,
  /// then calls BlockActionsHandler.handle<system>.
  ///
  /// Call pic.tick() after this to let the zero-delay resume timer fire.
  public shared ({ caller }) func testHandleBlockActionFullPipeline(
    actionId : Text,
    code : Text,
    slackUserId : Text,
    responseUrl : Text,
    botToken : Text,
    orApiKey : Text,
  ) : async () {
    assert caller == parent;
    // Seed bot token and OR API key into a fresh secrets state encrypted with dummyKey.
    let secrets = SecretModel.initState();
    ignore SecretModel.storeSecret(
      secrets,
      TestHelpers.dummyKey,
      0,
      #slackBotToken,
      botToken,
      { slackUserId = null; agentId = null; operation = "test-seed" },
    );
    ignore SecretModel.storeSecret(
      secrets,
      TestHelpers.dummyKey,
      0,
      #openRouterApiKey,
      orApiKey,
      { slackUserId = null; agentId = null; operation = "test-seed" },
    );
    let payload : SlackEventTypes.BlockActionsPayload = {
      userId = slackUserId;
      actionId;
      actionValue = code;
      messageTs = "1700000000.000001";
      channelId = "C_TEST";
      responseUrl;
    };
    let resumeDeps : AgentRunner.ResumeDeps = {
      sessionStores = testDispatchSessionStores;
      agentRegistry = testEffectAgentRegistry;
      secrets;
      internalEngine = ?mockInternalEngine;
      envelopeState = WorkflowEnvelopeModel.emptyState();
      catalogState = {
        var cached = ?{
          catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
          descriptors = WorkflowCatalog.allDescriptors;
        };
      };
      approvalState = testDispatchApprovalState;
    };
    let deps : BlockActionsHandler.BlockActionsDeps = {
      approvalState = testDispatchApprovalState;
      sessionStores = testDispatchSessionStores;
      agentRegistry = testEffectAgentRegistry;
      slackUsers;
      resumeDeps;
      keyCache = testSecretsKeyCache;
    };
    await BlockActionsHandler.handle<system>(payload, deps);
  };

  /// Query the status of an approval record in testDispatchApprovalState.
  /// Returns "pending" / "used" / "expired", or null if the code is not found.
  public query func testGetApprovalStatus(code : Text) : async ?Text {
    switch (ApprovalModel.findByCode(testDispatchApprovalState, code)) {
      case (null) { null };
      case (?record) {
        let statusText = switch (record.status) {
          case (#pending) { "pending" };
          case (#approved) { "approved" };
          case (#denied) { "denied" };
        };
        ?statusText;
      };
    };
  };

  // ============================================
  // Agent Orchestrator Category Test Methods
  // ============================================

  public shared ({ caller }) func testOrchestrateSystemAdminNoApiKey() : async Types.AgentOrchestrateResult {
    assert caller == parent;
    await AgentRunner.start(
      testAgent(#_system(#admin), "unit-test-admin"),
      ChannelHistoryModel.empty(),
      null,
      null,
      "turn-admin-0",
      SessionModel.emptyStores(),
      null,
      null,
      SecretModel.initState(),
      TestHelpers.dummyKey,
      TestHelpers.dummyKey,
      testOrchestratorEngineDeps(),
      ApprovalModel.emptyState(),
    );
  };

  public shared ({ caller }) func testOrchestrateSystemOnboarding() : async Types.AgentOrchestrateResult {
    assert caller == parent;
    let secrets = do {
      let s = SecretModel.initState();
      ignore SecretModel.storeSecret(s, TestHelpers.dummyKey, 0, #openRouterApiKey, "dummy-key", { slackUserId = null; agentId = null; operation = "test" });
      s;
    };
    await AgentRunner.start(
      testAgent(#_system(#onboarding), "unit-test-onboarding"),
      ChannelHistoryModel.empty(),
      null,
      null,
      "turn-onboarding-0",
      SessionModel.emptyStores(),
      null,
      null,
      secrets,
      TestHelpers.dummyKey,
      TestHelpers.dummyKey,
      testOrchestratorEngineDeps(),
      ApprovalModel.emptyState(),
    );
  };

  public shared ({ caller }) func testOrchestrateCustom() : async Types.AgentOrchestrateResult {
    assert caller == parent;
    let secrets = do {
      let s = SecretModel.initState();
      ignore SecretModel.storeSecret(s, TestHelpers.dummyKey, 0, #openRouterApiKey, "dummy-key", { slackUserId = null; agentId = null; operation = "test" });
      s;
    };
    await AgentRunner.start(
      testAgent(#custom, "unit-test-custom"),
      ChannelHistoryModel.empty(),
      null,
      null,
      "turn-custom-0",
      SessionModel.emptyStores(),
      null,
      null,
      secrets,
      TestHelpers.dummyKey,
      TestHelpers.dummyKey,
      testOrchestratorEngineDeps(),
      ApprovalModel.emptyState(),
    );
  };

  /// Run AdminAgentLoop.process with configurable apiKey, model, and prompt.
  /// Pass apiKey="" to simulate no secret seeded (triggers "No OpenRouter API key" error).
  /// Pass model="" to trigger an invalid-model error from the LLM wrapper.
  public shared ({ caller }) func testAdminAgentLoopProcess(
    apiKey : Text,
    model : Text,
    prompt : Text,
  ) : async Types.AgentOrchestrateResult {
    assert caller == parent;
    let secrets = if (apiKey == "") {
      SecretModel.initState();
    } else {
      let s = SecretModel.initState();
      ignore SecretModel.storeSecret(
        s,
        TestHelpers.dummyKey,
        0,
        #openRouterApiKey,
        apiKey,
        { slackUserId = null; agentId = null; operation = "test-seed" },
      );
      s;
    };
    let history = ChannelHistoryModel.empty();
    let authCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_ADMIN_LOOP_TEST";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      history,
      "C_TEST_CATEGORY",
      {
        ts = "1700000000.000001";
        userAuthContext = ?authCtx;
        text = prompt;
        agentMetadata = null;
      },
      null,
    );
    let triggerPrompt : ?Text = if (prompt == "") { null } else { ?prompt };
    await AgentRunner.start(
      testAgentWithModel(#_system(#admin), "unit-test-admin", model),
      history,
      ?#slack({
        channelId = "C_TEST_CATEGORY";
        ts = "1700000000.000001";
        threadTs = null;
      }),
      triggerPrompt,
      "turn-admin-loop-0",
      SessionModel.emptyStores(),
      null,
      null,
      secrets,
      TestHelpers.dummyKey,
      TestHelpers.dummyKey,
      testOrchestratorEngineDeps(),
      ApprovalModel.emptyState(),
    );
  };

  /// Run AdminAgentLoop.process with a seeded userAuthContext (userId = "U_ADMIN_LOOP_TEST").
  /// Identical to testAdminAgentLoopProcess but passes a proper userAuthContext so
  /// requestedByUserId is correctly captured in #awaitingApproval results.
  public shared ({ caller }) func testAdminAgentLoopApproval(
    apiKey : Text,
    model : Text,
    prompt : Text,
  ) : async Types.AgentOrchestrateResult {
    assert caller == parent;
    let secrets = if (apiKey == "") {
      SecretModel.initState();
    } else {
      let s = SecretModel.initState();
      ignore SecretModel.storeSecret(
        s,
        TestHelpers.dummyKey,
        0,
        #openRouterApiKey,
        apiKey,
        { slackUserId = null; agentId = null; operation = "test-seed" },
      );
      s;
    };
    let history = ChannelHistoryModel.empty();
    let authCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_ADMIN_LOOP_TEST";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      history,
      "C_TEST_CATEGORY",
      {
        ts = "1700000000.000001";
        userAuthContext = ?authCtx;
        text = prompt;
        agentMetadata = null;
      },
      null,
    );
    let triggerPrompt : ?Text = if (prompt == "") { null } else { ?prompt };
    await AgentRunner.start(
      testAgentWithModel(#_system(#admin), "unit-test-admin", model),
      history,
      ?#slack({
        channelId = "C_TEST_CATEGORY";
        ts = "1700000000.000001";
        threadTs = null;
      }),
      triggerPrompt,
      "turn-admin-loop-approval-0",
      SessionModel.emptyStores(),
      ?authCtx,
      ?"U_ADMIN_LOOP_TEST",
      secrets,
      TestHelpers.dummyKey,
      TestHelpers.dummyKey,
      testOrchestratorEngineDeps(),
      ApprovalModel.emptyState(),
    );
  };

  // ============================================
  // Tool Executor Test Methods
  // ============================================

  public shared ({ caller }) func testToolExecutorExecute(
    toolName : Text,
    args : Text,
  ) : async [ToolTypes.ToolResult] {
    assert caller == parent;
    let resources : ToolTypes.ToolResources = {
      workspaceId = null;
      resolveSlackBotToken = null;
      userAuthContext = null;
      sourceRef = null;
      secrets = null;
      engineDispatch = null;
      envelopeContext = null;
    };
    await ToolExecutor.execute(
      resources,
      [{ callId = "call-1"; toolName; arguments = args }],
    );
  };

  public shared ({ caller }) func testToolExecutorFormatFixture() : async Text {
    assert caller == parent;
    ToolExecutor.formatResultsForLlm([
      { callId = "call-1"; result = #ok("{\"ok\":true}"); durationMs = 0 },
      { callId = "call-2"; result = #err("boom"); durationMs = 0 },
    ]);
  };

  // ============================================
  // Workflow API Test Methods
  // ============================================

  /// Sets the internal engine principal used by testWorkflowApi's authorization guard.
  public shared ({ caller }) func testSetInternalEnginePrincipal(p : Principal) : async () {
    assert caller == parent;
    testInternalEnginePrincipal := ?p;
  };

  /// Issues a full-scope workflow token directly into testWorkflowEnvelopeState.
  /// Returns the token nonce.
  public shared ({ caller }) func testIssueWorkflowToken(
    turnId : Text,
    workspaceId : Nat,
  ) : async Text {
    assert caller == parent;
    WorkflowEnvelopeModel.issue(
      testWorkflowEnvelopeState,
      turnId,
      workspaceId,
      [
        #workspace({ access = #write }),
        #agents({ access = #write }),
        #slackQueue({ access = #read }),
        #session({ access = #write }),
      ],
    ).nonce;
  };

  /// Mirrors the production workflowApi endpoint for unit tests.
  /// Applies the engine-principal authorization guard then delegates to testWorkflowApiService.
  /// Async effects are discarded — this tests the synchronous response only.
  public shared ({ caller }) func testWorkflowApi(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
  ) : async { #ok : Text; #err : Text } {
    switch (testInternalEnginePrincipal) {
      case (null) {};
      case (?expected) {
        if (caller != expected) {
          return #err("Unauthorized: caller " # Principal.toText(caller) # " is not the internal engine canister");
        };
      };
    };
    let { response } = testWorkflowApiService.handleRequest(method, path, body);
    response;
  };

  // ============================================
  // Workflow Async Effect Test Methods
  // ============================================

  /// Seed a pending turn in testEffectSessionStores with a Slack sourceRef.
  /// The turn is set to #awaitingWorkflow so it is ready for engine completion.
  /// Returns the generated turnId (format: "{agentId}_{turnNumber}").
  public shared ({ caller }) func testSeedPendingTurn(
    agentId : Nat,
    channelId : Text,
    ts : Text,
    threadTs : ?Text,
  ) : async Text {
    assert caller == parent;
    let turn = SessionModel.createTurn(
      testEffectSessionStores,
      agentId,
      ?#slack({ channelId; ts; threadTs }),
      null,
      null,
    );
    ignore SessionModel.suspendForWorkflow(
      testEffectSessionStores,
      turn.turnId,
      {
        messages = [];
        pendingToolCallId = "test-call-id";
        roundCount = 0;
      },
    );
    turn.turnId;
  };

  /// Seed a #running turn in testEffectSessionStores with a Slack sourceRef.
  /// Use this when testing the normal (non-resume) completion path where the
  /// turn is not awaiting a workflow engine result.
  /// Returns the generated turnId (format: "{agentId}_{turnNumber}").
  public shared ({ caller }) func testSeedRunningTurn(
    agentId : Nat,
    channelId : Text,
    ts : Text,
    threadTs : ?Text,
  ) : async Text {
    assert caller == parent;
    let turn = SessionModel.createTurn(
      testEffectSessionStores,
      agentId,
      ?#slack({ channelId; ts; threadTs }),
      null,
      null,
    );
    // Leave status as #running (the default from createTurn)
    turn.turnId;
  };

  /// Issues a full-scope workflow token into testEffectEnvelopeState.
  /// Returns the token nonce.
  public shared ({ caller }) func testIssueEffectToken(
    turnId : Text,
    workspaceId : Nat,
  ) : async Text {
    assert caller == parent;
    WorkflowEnvelopeModel.issue(
      testEffectEnvelopeState,
      turnId,
      workspaceId,
      [
        #workspace({ access = #write }),
        #agents({ access = #write }),
        #slackQueue({ access = #read }),
        #session({ access = #write }),
      ],
    ).nonce;
  };

  /// Call testEffectWorkflowApiService, then synchronously run any async effects
  /// using the provided botToken (bypasses Schnorr key derivation for unit tests).
  /// The botToken is seeded into testEffectSecretsState encrypted with the dummy key
  /// so WorkflowAsyncEffectService can resolve it without a live Schnorr call.
  public shared ({ caller }) func testRunAsyncEffect(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
    botToken : Text,
  ) : async { #ok : Text; #err : Text } {
    assert caller == parent;
    ignore SecretModel.storeSecret(
      testEffectSecretsState,
      TestHelpers.dummyKey,
      0,
      #slackBotToken,
      botToken,
      { slackUserId = null; agentId = null; operation = "test-seed" },
    );
    let { response; asyncEffects } = testEffectWorkflowApiService.handleRequest(method, path, body);
    for (effect in asyncEffects.vals()) {
      await testEffectAsyncEffectService.processEffect(testEffectKeyCache, effect);
    };
    response;
  };

  /// Variant of testRunAsyncEffect that wires a succeeding resumeAdminTurn stub.
  /// Use this to exercise the #awaitingWorkflow → #succeeded path in
  /// WorkflowAsyncEffectService, where the service calls resumeAdminTurn and then
  /// applies the result via TurnCompletionService.
  /// The stub returns #ok immediately, avoiding a live LLM or engine call.
  public shared ({ caller }) func testRunAsyncEffectWithResume(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
    botToken : Text,
  ) : async { #ok : Text; #err : Text } {
    assert caller == parent;
    ignore SecretModel.storeSecret(
      testEffectSecretsState,
      TestHelpers.dummyKey,
      0,
      #slackBotToken,
      botToken,
      { slackUserId = null; agentId = null; operation = "test-seed-resume" },
    );
    // Build a one-shot service with a succeeding resumeAdminTurn stub.
    let serviceWithResume = WorkflowAsyncEffectService.Service({
      sessionStores = testEffectSessionStores;
      agentRegistry = testEffectAgentRegistry;
      workspaces = testWorkspacesState;
      secrets = testEffectSecretsState;
      approvalState = ApprovalModel.emptyState();
      resumeAdminTurn = func(_ : Text, _ : SessionModel.SuspensionData, _ : Text) : async Types.AgentOrchestrateResult {
        #ok({ response = "Workflow complete."; steps = [] });
      };
    });
    let { response; asyncEffects } = testEffectWorkflowApiService.handleRequest(method, path, body);
    for (effect in asyncEffects.vals()) {
      await serviceWithResume.processEffect(testEffectKeyCache, effect);
    };
    response;
  };

  /// Query the status of a turn in testEffectSessionStores.
  public query func testGetEffectTurnStatus(turnId : Text) : async ?Text {
    switch (SessionModel.findTurn(testEffectSessionStores, turnId)) {
      case (null) { null };
      case (?turn) {
        let statusText = switch (turn.status) {
          case (#running) { "running" };
          case (#awaitingWorkflow(_)) { "awaitingWorkflow" };
          case (#awaitingApproval(_)) { "awaitingApproval" };
          case (#succeeded) { "succeeded" };
          case (#failed) { "failed" };
        };
        ?statusText;
      };
    };
  };

  public shared ({ caller }) func testMessageDeletedHandler(
    deleted : {
      channel : Text;
      deletedTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageDeletedHandler.handle(deleted, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  public shared ({ caller }) func testMessageEditedHandler(
    edited : {
      channel : Text;
      messageTs : Text;
      threadTs : ?Text;
      newText : Text;
      editedBy : ?Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageEditedHandler.handle(edited, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  public shared ({ caller }) func testAssistantThreadEventHandler(
    thread : {
      eventType : { #threadStarted; #threadContextChanged };
      userId : Text;
      channelId : Text;
      threadTs : Text;
      eventTs : Text;
      context : NormalizedEventTypes.AssistantThreadContext;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await AssistantThreadHandler.handle(thread, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  public shared ({ caller }) func testTeamJoinHandler(
    event : {
      userId : Text;
      displayName : Text;
      realName : ?Text;
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await TeamJoinHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  public shared ({ caller }) func testMemberJoinedChannelHandler(
    event : {
      userId : Text;
      channelId : Text;
      channelType : Text;
      teamId : Text;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MemberJoinedChannelHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  public shared ({ caller }) func testMemberLeftChannelHandler(
    event : {
      userId : Text;
      channelId : Text;
      channelType : Text;
      teamId : Text;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MemberLeftChannelHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  // ============================================
  // Slack User Cache Query Methods
  // ============================================

  /// Serializable version of SlackUserEntry for Candid response
  public type SlackUserInfo = {
    slackUserId : Text;
    displayName : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    isBot : Bool;
    adminWorkspaces : [Nat];
  };

  /// Serializable version of AccessChangeEntry for Candid response.
  /// `source` is encoded as a plain string: "reconciliation", "manual", or "slackEvent:<eventId>".
  /// `changeType` is encoded as the variant name (e.g. "orgAdminGranted").
  /// `workspaceId` is populated only for workspace-scoped change types.
  public type ChangeLogEntryInfo = {
    slackUserId : Text;
    changeType : Text;
    source : Text;
    workspaceId : ?Nat;
  };

  /// Reset the Slack user state (cache + change log) for test isolation.
  public func resetSlackUserCache() : async () {
    slackUsers := SlackUserModel.emptyState();
  };

  /// Get all Slack users currently in the cache
  public query func getSlackUsers() : async [SlackUserInfo] {
    let entries = SlackUserModel.listUsers(slackUsers.cache);
    Array.map<SlackUserModel.SlackUserEntry, SlackUserInfo>(
      entries,
      func(entry : SlackUserModel.SlackUserEntry) : SlackUserInfo {
        let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
        {
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          adminWorkspaces = adminIds;
        };
      },
    );
  };

  /// Look up a specific Slack user by ID
  public query func getSlackUser(slackUserId : Text) : async ?SlackUserInfo {
    switch (SlackUserModel.lookupUser(slackUsers.cache, slackUserId)) {
      case (null) { null };
      case (?entry) {
        let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
        ?({
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          adminWorkspaces = adminIds;
        });
      };
    };
  };

  /// Return all access change log entries recorded in the current state.
  /// Entries are in chronological order (oldest first).
  public query func getChangeLog() : async [ChangeLogEntryInfo] {
    let entries = SlackUserModel.getLogsSince(slackUsers, 0);
    Array.map<SlackUserModel.AccessChangeEntry, ChangeLogEntryInfo>(
      entries,
      func(e : SlackUserModel.AccessChangeEntry) : ChangeLogEntryInfo {
        let changeTypeText = switch (e.changeType) {
          case (#userAdded) { "userAdded" };
          case (#userRemoved) { "userRemoved" };
          case (#orgAdminGranted) { "orgAdminGranted" };
          case (#orgAdminRevoked) { "orgAdminRevoked" };
          case (#primaryOwnerGranted) { "primaryOwnerGranted" };
          case (#primaryOwnerRevoked) { "primaryOwnerRevoked" };
          case (#workspaceAdminGranted(_)) { "workspaceAdminGranted" };
          case (#workspaceAdminRevoked(_)) { "workspaceAdminRevoked" };
        };
        let wsIdOpt : ?Nat = switch (e.changeType) {
          case (#workspaceAdminGranted(wsId)) { ?wsId };
          case (#workspaceAdminRevoked(wsId)) { ?wsId };
          case (_) { null };
        };
        let sourceText = switch (e.source) {
          case (#reconciliation) { "reconciliation" };
          case (#slackEvent(eventId)) { "slackEvent:" # eventId };
          case (#manual) { "manual" };
        };
        {
          slackUserId = e.slackUserId;
          changeType = changeTypeText;
          source = sourceText;
          workspaceId = wsIdOpt;
        };
      },
    );
  };

  // ============================================
  // Weekly Reconciliation Service Test Methods
  // ============================================

  /// Seed a single Slack user into the persistent state for reconciliation tests.
  public shared ({ caller }) func seedSlackUser(
    slackUserId : Text,
    displayName : Text,
    isPrimaryOwner : Bool,
    isOrgAdmin : Bool,
    isBot : Bool,
  ) : async () {
    assert caller == parent;
    SlackUserModel.upsertUser(
      slackUsers,
      {
        slackUserId;
        displayName;
        isPrimaryOwner;
        isOrgAdmin;
        isBot;
        adminWorkspaces = Set.empty<Nat>();
      },
      #manual,
    );
  };

  /// Seed a workspace admin channel membership for a user in the persistent state.
  /// The user must already exist in the cache (seed via seedSlackUser first).
  public shared ({ caller }) func seedWorkspaceMembership(
    slackUserId : Text,
    workspaceId : Nat,
  ) : async () {
    assert caller == parent;
    ignore SlackUserModel.joinAdminChannel(slackUsers, slackUserId, workspaceId, #manual);
  };

  /// Run the weekly reconciliation runner against the shared test cache and
  /// the pre-seeded test workspace state.
  ///
  /// @param token               Decrypted Slack bot token (or mock value)
  /// @param orgAdminChannelId   Optional org-admin channel ID — when provided, sets workspace 0's
  ///                            adminChannelId before the run so the runner treats it as the org-admin channel
  public shared ({ caller }) func testWeeklyReconciliationRunner(
    token : Text,
    orgAdminChannelId : ?Text,
  ) : async {
    #ok : WeeklyReconciliationRunner.ReconciliationSummary;
    #err : Text;
  } {
    assert caller == parent;
    // Set workspace 0's adminChannelId so the reconciliation runner treats it as the org-admin channel.
    switch (orgAdminChannelId) {
      case (null) {};
      case (?channelId) {
        ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, channelId);
      };
    };
    // Seed the token into testSecretsMap so the runner can resolve it.
    ignore SecretModel.storeSecret(testSecretsMap, TestHelpers.dummyKey, 0, #slackBotToken, token, { slackUserId = null; agentId = null; operation = "test" });
    await WeeklyReconciliationRunner.run(
      testSecretsKeyCache,
      testSecretsMap,
      slackUsers,
      testWorkspacesState,
    );
  };

  // ============================================
  // Timer Runner Test Methods
  // ============================================

  /// Run the clear-key-cache runner and apply the result to testKeyCache.
  /// Returns the cache size after the run.
  public shared ({ caller }) func testClearKeyCacheRunner() : async {
    #ok : Nat;
    #err : Text;
  } {
    assert caller == parent;
    switch (ClearKeyCacheRunner.run()) {
      case (#ok(cache)) {
        testKeyCache := cache;
        #ok(KeyDerivationService.getCacheSize(testKeyCache));
      };
      case (#err(e)) { #err(e) };
    };
  };

  /// Run the processed-events-cleanup runner against testEventStore.
  public shared ({ caller }) func testProcessedEventsCleanupRunner() : async {
    #ok;
    #err : Text;
  } {
    assert caller == parent;
    ProcessedEventsCleanupRunner.run(testEventStore);
  };

  /// Run the channel-history-prune runner against testChannelHistoryStore.
  public shared ({ caller }) func testChannelHistoryPruneRunner() : async {
    #ok;
    #err : Text;
  } {
    assert caller == parent;
    ChannelHistoryPruneRunner.run(testChannelHistoryStore);
  };

  /// Seed a message directly into testChannelHistoryStore for prune runner tests.
  /// The ts string format must be "SECONDS.MICROSECONDS" (e.g. "1700000000.000001").
  /// Pass null for threadTs to store as a top-level post.
  public shared ({ caller }) func testSeedChannelHistoryMessage(
    channelId : Text,
    ts : Text,
    threadTs : ?Text,
  ) : async () {
    assert caller == parent;
    ChannelHistoryModel.addMessage(
      testChannelHistoryStore,
      channelId,
      {
        ts;
        userAuthContext = null;
        text = "test message";
        agentMetadata = null;
      },
      threadTs,
    );
  };

  /// Returns the number of top-level timeline entries for the given channel
  /// in testChannelHistoryStore. Returns 0 if the channel does not exist.
  public shared query ({ caller }) func testGetChannelHistoryEntryCount(channelId : Text) : async Nat {
    assert caller == parent;
    switch (Map.get(testChannelHistoryStore, Text.compare, channelId)) {
      case (null) { 0 };
      case (?ch) { Map.size(ch.timeline) };
    };
  };

  // ============================================
  // Turn Cleanup Runner Test Methods
  // ============================================

  /// Run the turn-cleanup runner against testCleanupSessionStores.
  /// Returns the number of turns deleted.
  public shared ({ caller }) func testTurnCleanupRunner() : async {
    #ok : Nat;
    #err : Text;
  } {
    assert caller == parent;
    TurnCleanupRunner.run(testCleanupSessionStores, testCleanupEnvelopeState);
  };

  /// Seed a turn into testCleanupSessionStores.
  /// The turn's startedAtNs is stamped by Time.now() — control the clock
  /// via pic.setTime() before calling this helper.
  /// Returns the new turnId.
  public shared ({ caller }) func testSeedTurn(agentId : Nat) : async Text {
    assert caller == parent;
    let turn = SessionModel.createTurn(testCleanupSessionStores, agentId, null, null, null);
    turn.turnId;
  };

  /// Returns the number of turns stored for agentId in testCleanupSessionStores.
  /// Returns 0 when no turns have been seeded for that agent.
  public shared query ({ caller }) func testGetTurnCount(agentId : Nat) : async Nat {
    assert caller == parent;
    switch (SessionModel.getTurnsByAgent(testCleanupSessionStores, agentId)) {
      case (null) { 0 };
      case (?turnMap) { Map.size(turnMap) };
    };
  };

  /// Append a trace entry to the given turn in testCleanupSessionStores.
  /// Useful for verifying that the trace GC pass removes entries independently
  /// of their owning turns.
  public shared ({ caller }) func testSeedTrace(turnId : Text) : async () {
    assert caller == parent;
    SessionModel.appendTrace(testCleanupSessionStores, turnId, #roundLimitHit);
  };

  /// Returns true when a trace list exists for the given turnId, false otherwise.
  public shared query ({ caller }) func testHasTrace(turnId : Text) : async Bool {
    assert caller == parent;
    switch (SessionModel.getTraces(testCleanupSessionStores, turnId)) {
      case (null) { false };
      case (?_) { true };
    };
  };

  // ============================================
  // Engine Topup Runner Test Methods
  // ============================================

  /// Run the engine-topup runner with the given optional engine principal.
  /// Pass null to test the "engine not yet spawned" no-op path.
  /// Pass a principal for a non-existent/uncontrolled canister to test the
  /// canister_status failure path — the try/catch should return #err.
  public shared ({ caller }) func testEngineTopupRunner(enginePrincipal : ?Principal) : async {
    #ok;
    #err : Text;
  } {
    assert caller == parent;
    await EngineTopupRunner.run(enginePrincipal);
  };

  // ============================================
  // Slack Adapter Test Methods
  // ============================================

  public shared ({ caller }) func testSlackSignatureVerification(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : async Bool {
    assert caller == parent;
    SlackAdapter.verifySignature<system>(signingSecret, signature, timestamp, body);
  };

  public shared query ({ caller }) func testSlackTimestampVerification(timestamp : Text) : async Bool {
    assert caller == parent;
    SlackAdapter.verifyTimestamp(timestamp);
  };

  // ============================================
  // Key Derivation Service Test Methods
  // ============================================

  /// Returns the current number of entries in the persistent test key cache.
  public shared query ({ caller }) func testGetKeyCacheSize() : async Nat {
    assert caller == parent;
    KeyDerivationService.getCacheSize(testKeyCache);
  };

  /// Clears the persistent test key cache, simulating the periodic cache-clearing timer.
  public shared ({ caller }) func testClearKeyCache() : async () {
    assert caller == parent;
    testKeyCache := KeyDerivationService.clearCache();
  };

  /// Derives and caches the encryption key for a workspace via a live sign_with_schnorr call.
  /// Requires the canister to be deployed on a subnet with fiduciary (threshold Schnorr) support.
  public shared ({ caller }) func testSeedKeyForWorkspace(workspaceId : Nat) : async () {
    assert caller == parent;
    let key = await KeyDerivationService.deriveKeyFromSchnorr(workspaceId);
    Map.add(testKeyCache, Nat.compare, workspaceId, key);
  };

  /// Returns the byte-length of the cached key for the given workspace, or null if not cached.
  /// Use this to confirm the dummy key has been stored (expected length = 32).
  public query func testGetCachedKeyLength(workspaceId : Nat) : async ?Nat {
    switch (Map.get(testKeyCache, Nat.compare, workspaceId)) {
      case (?key) { ?key.size() };
      case (null) { null };
    };
  };

  // ============================================
  // Secrets Handler Test Methods
  //
  // All secrets handlers run against testSecretsMap (starts empty).
  // testSecretsKeyCache is pre-seeded with the all-zeros dummy key for
  // workspaces 0, 1, and 2, avoiding live Schnorr calls.
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Test the StoreSecretHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId, secretId, secretValue }).
  /// @param auth  Simplified auth context.
  ///
  /// Secrets stored here persist for the lifetime of this PocketIC canister
  /// so subsequent calls to testGetWorkspaceSecretsHandler see them.
  public shared ({ caller }) func testStoreSecretHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    // Extract workspaceId from JSON args so the handler receives it as a typed param.
    // The original args string is passed through unchanged — the handler only reads secretId/secretValue.
    let workspaceId : Nat = switch (Json.parse(args)) {
      case (#err(_)) {
        return Json.stringify(obj([("success", bool(false)), ("error", str("Failed to parse arguments"))]), null);
      };
      case (#ok(json)) {
        switch (Json.get(json, "workspaceId")) {
          case (?#number(#int(n))) { Int.abs(n) };
          case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
          case _ {
            return Json.stringify(obj([("success", bool(false)), ("error", str("Missing or invalid 'workspaceId'"))]), null);
          };
        };
      };
    };
    StoreSecretHandler.handle(testSecretsMap, TestHelpers.dummyKey, uac, workspaceId, args) |> outcomeToText(_);
  };

  /// Test the GetWorkspaceSecretsHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId }).
  /// @param auth  Simplified auth context.
  public shared ({ caller }) func testGetWorkspaceSecretsHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    // Extract workspaceId from JSON args so the handler receives it as a typed param.
    let workspaceId : Nat = switch (Json.parse(args)) {
      case (#err(_)) {
        return Json.stringify(obj([("success", bool(false)), ("error", str("Failed to parse arguments"))]), null);
      };
      case (#ok(json)) {
        switch (Json.get(json, "workspaceId")) {
          case (?#number(#int(n))) { Int.abs(n) };
          case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
          case _ {
            return Json.stringify(obj([("success", bool(false)), ("error", str("Missing or invalid 'workspaceId'"))]), null);
          };
        };
      };
    };
    (await GetWorkspaceSecretsHandler.handle(testSecretsMap, uac, workspaceId, args)) |> outcomeToText(_);
  };

  /// Test the DeleteSecretHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId, secretId }).
  /// @param auth  Simplified auth context.
  public shared ({ caller }) func testDeleteSecretHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    // Extract workspaceId from JSON args so the handler receives it as a typed param.
    let workspaceId : Nat = switch (Json.parse(args)) {
      case (#err(_)) {
        return Json.stringify(obj([("success", bool(false)), ("error", str("Failed to parse arguments"))]), null);
      };
      case (#ok(json)) {
        switch (Json.get(json, "workspaceId")) {
          case (?#number(#int(n))) { Int.abs(n) };
          case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
          case _ {
            return Json.stringify(obj([("success", bool(false)), ("error", str("Missing or invalid 'workspaceId'"))]), null);
          };
        };
      };
    };
    (await DeleteSecretHandler.handle(testSecretsMap, uac, workspaceId, args)) |> outcomeToText(_);
  };

  // ============================================
  // Event Store Handler Test Methods
  //
  // All event store handlers run against testEventStore (starts empty).
  // Use testSeedFailedEvent to inject a failed event before calling the handlers.
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Seed a failed event into testEventStore for handler tests.
  /// Enqueues a minimal event then immediately marks it as failed with the given error.
  public shared ({ caller }) func testSeedFailedEvent(
    eventId : Text,
    errorMsg : Text,
  ) : async () {
    assert caller == parent;
    let event : NormalizedEventTypes.Event = {
      source = #slack;
      idempotencyKey = eventId;
      eventId = "slack_" # eventId;
      timestamp = 0;
      payload = #message({
        user = "U_TEST";
        text = "test";
        channel = "C_TEST";
        ts = "1700000000.000001";
        threadTs = null;
        isBotMessage = false;
        agentMetadata = null;
      });
      enqueuedAt = 0;
      claimedAt = null;
      processedAt = null;
      failedAt = null;
      failedError = "";
      processingLog = [];
    };
    ignore EventStoreModel.enqueue(testEventStore, event);
    EventStoreModel.markFailed(testEventStore, "slack_" # eventId, errorMsg);
  };

  /// Seed a processed event into testEventStore for cleanup runner tests.
  /// Enqueues a minimal event then immediately marks it as processed.
  /// The processedAt timestamp is stamped with Time.now() inside EventStoreModel,
  /// so call this while pic.setTime() is set to the desired past/present time.
  public shared ({ caller }) func testSeedProcessedEvent(eventId : Text) : async () {
    assert caller == parent;
    let event : NormalizedEventTypes.Event = {
      source = #slack;
      idempotencyKey = eventId;
      eventId = "slack_" # eventId;
      timestamp = 0;
      payload = #message({
        user = "U_TEST";
        text = "test";
        channel = "C_TEST";
        ts = "1700000000.000001";
        threadTs = null;
        isBotMessage = false;
        agentMetadata = null;
      });
      enqueuedAt = 0;
      claimedAt = null;
      processedAt = null;
      failedAt = null;
      failedError = "";
      processingLog = [];
    };
    ignore EventStoreModel.enqueue(testEventStore, event);
    EventStoreModel.markProcessed(testEventStore, "slack_" # eventId, []);
  };

  // ============================================
  // EngineDispatchService Test Methods
  // ============================================

  /// Test EngineDispatchService.dispatch directly using the pre-spawned testInternalEngine.
  ///
  /// @param seedVersion   Pre-seeds knownEngineVersions["internal-engine"] before the call.
  ///                      null → map starts empty (service defaults to "v1").
  ///                      e.g. ?"v0" → simulates a stale cached version to exercise negotiation.
  /// @param includeApiKey Whether to include the "openrouter" key in envelope secrets.
  ///                      false triggers the engine's API-key error, covering error-propagation
  ///                      and retry-failure paths.
  ///
  /// Returns a flat record so both success and failure expose `knownVersionAfter`,
  /// which is the value stored in knownEngineVersions after the call (null = no update).
  public shared ({ caller }) func testEngineDispatchService(
    seedVersion : ?Text,
    includeApiKey : Bool,
  ) : async { dispatched : Bool; error : ?Text; knownVersionAfter : ?Text } {
    assert caller == parent;
    let engine = mockInternalEngine;
    let store = WorkflowEnvelopeModel.emptyState();
    switch (seedVersion) {
      case (?v) {
        Map.add(store.knownEngineVersions, Text.compare, "internal-engine", v);
      };
      case null {};
    };
    let apiKeys : [(Text, Text)] = if (includeApiKey) {
      [("openrouter", "test-key"), ("model", "gpt-4")];
    } else { [("model", "gpt-4")] };
    let { envelopeId; nonce = envelopeNonce } = WorkflowEnvelopeModel.issue(
      store,
      "test-turn-dispatch-0_0",
      0,
      [#workspace({ access = #read })],
    );
    let envelope : WorkflowTypes.EnvelopePayload = {
      envelopeId;
      dispatchedVersion = null;
      catalogHash = null;
      requestId = "test-turn-dispatch-0_0";
      agentId = 0;
      agentName = "test-agent";
      workspaceId = 0;
      workflowName = "workspace_get";
      workflowArguments = null;
      model = "";
      messages = [];
      instructions = "test instructions";
      constraints = { maxRounds = 1; maxTokenBudget = null };
      secrets = { apiKeys };
      scopeGrants = [#workspace({ access = #read })];
      envelopeNonce;
    };
    let knownVersionAfter = func() : ?Text {
      Map.get(store.knownEngineVersions, Text.compare, "internal-engine");
    };
    switch (await EngineDispatchService.dispatch(store, engine, envelope)) {
      case (#ok) {
        {
          dispatched = true;
          error = null;
          knownVersionAfter = knownVersionAfter();
        };
      };
      case (#err(e)) {
        {
          dispatched = false;
          error = ?e;
          knownVersionAfter = knownVersionAfter();
        };
      };
    };
  };

  // ============================================
  // Dispatch Workflow Handler Test Methods
  // ============================================

  /// Test the WorkflowEngineHandler in isolation.
  ///
  /// Builds a minimal descriptor with no coreDirectives and dispatches using the provided args.
  /// @param args             JSON-encoded tool arguments (workflow-specific).
  /// @param botToken         Optional Slack bot token (unused when no preValidation directives).
  /// @param mockDispatchFail When true, dispatch returns #err; otherwise #ok.
  /// Uses a minimal org-admin AgentRecord stub and a fresh WorkflowEnvelopeModel.EnvelopeState.
  public shared ({ caller }) func testWorkflowEngineHandler(
    args : Text,
    botToken : ?Text,
    mockDispatchFail : Bool,
  ) : async Text {
    assert caller == parent;
    let agent : AgentModel.AgentRecord = {
      id = 0;
      ownedBy = 0;
      category = #_system(#admin);
      config = {
        name = "test-dispatch-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = Set.empty<Text>();
        secrets = { allowed = []; overrides = [] };
      };
      state = {
        toolsState = Map.empty<Text, AgentModel.ToolState>();
      };
    };
    let internalEngine : InternalEngine.InternalEngine = if (mockDispatchFail) {
      // Use a non-existent canister so execute throws, triggering the handler's error path.
      actor "aaaaa-aa" : InternalEngine.InternalEngine;
    } else {
      mockInternalEngine;
    };
    let engineDispatch : ToolTypes.EngineDispatch = {
      envelopeState = WorkflowEnvelopeModel.emptyState();
      internalEngine;
      catalogState = {
        var cached = ?{
          catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
          descriptors = WorkflowCatalog.allDescriptors;
        };
      };
      approvalState = ApprovalModel.emptyState();
    };
    let envelopeContext : ToolTypes.EnvelopeContext = {
      agent;
      turnId = "test-turn-0_0";
      instructions = "Test instructions";
      messages = [];
      apiKey = "test-api-key";
    };
    let resolveSlackBotToken : ?(Text -> ?Text) = switch (botToken) {
      case (null) { null };
      case (?token) { ?(func(_ : Text) : ?Text { ?token }) };
    };
    let descriptor : WorkflowCatalogTypes.WorkflowDescriptor = {
      workflowName = "workspace_get";
      description = "Administrative operations";
      parametersJsonSchema = "{\"type\":\"object\"}";
      requiredScopes = [];
      coreDirectives = [];
    };
    let outcome = await WorkflowEngineHandler.handle(descriptor, engineDispatch, envelopeContext, resolveSlackBotToken, "", null, args);
    switch (outcome) {
      case (#ok(t)) { t };
      case (#err(e)) { e };
    };
  };

  /// Test the WorkflowEngineHandler with a descriptor that has coreDirectives = [#require("approval")].
  ///
  /// @param args             JSON-encoded tool arguments (no approvalCode → triggers approval prompt).
  /// @param botToken         Optional Slack bot token (used to attempt posting the approval Slack message).
  /// @param mockDispatchFail When true, dispatch returns #err; otherwise #ok.
  /// @param preApprove       When true, pre-seeds an approval code as #used so the dispatch proceeds.
  /// @param slackChannelId   When provided, used as the Slack channelId in sourceRef.
  public shared ({ caller }) func testWorkflowEngineHandlerApproval(
    args : Text,
    botToken : ?Text,
    mockDispatchFail : Bool,
    preApprove : Bool,
    slackChannelId : ?Text,
  ) : async Text {
    assert caller == parent;
    let approvalWorkflowName = "admin-approval-v1";
    let testUserId = "U_TEST_USER";
    let testTurnId = "test-turn-0_0";
    let agent : AgentModel.AgentRecord = {
      id = 0;
      ownedBy = 0;
      category = #_system(#admin);
      config = {
        name = "test-approval-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = Set.empty<Text>();
        secrets = { allowed = []; overrides = [] };
      };
      state = {
        toolsState = Map.empty<Text, AgentModel.ToolState>();
      };
    };
    let internalEngine : InternalEngine.InternalEngine = if (mockDispatchFail) {
      actor "aaaaa-aa" : InternalEngine.InternalEngine;
    } else {
      mockInternalEngine;
    };
    let approvalState = ApprovalModel.emptyState();
    // Pre-seed catalog so dispatch can proceed past step 3 (catalog hash check).
    let catalog = WorkflowCatalogModel.empty();
    let catalogHash = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);
    WorkflowCatalogModel.replace(catalog, catalogHash, WorkflowCatalog.allDescriptors);
    let engineDispatch : ToolTypes.EngineDispatch = {
      envelopeState = WorkflowEnvelopeModel.emptyState();
      internalEngine;
      catalogState = catalog;
      approvalState;
    };
    let envelopeContext : ToolTypes.EnvelopeContext = {
      agent;
      turnId = testTurnId;
      instructions = "Test instructions";
      messages = [];
      apiKey = "test-api-key";
    };
    let resolveSlackBotToken : ?(Text -> ?Text) = switch (botToken) {
      case (null) { null };
      case (?token) { ?(func(_ : Text) : ?Text { ?token }) };
    };
    let descriptor : WorkflowCatalogTypes.WorkflowDescriptor = {
      workflowName = approvalWorkflowName;
      description = "Administrative approval workflow";
      parametersJsonSchema = "{\"type\":\"object\"}";
      requiredScopes = [];
      coreDirectives = [#require("approval")];
    };
    let sourceRef : ?SessionModel.SourceRef = switch (slackChannelId) {
      case (?channelId) {
        ?#slack({ channelId; ts = "1700000000.000001"; threadTs = null });
      };
      case (null) { null };
    };
    // When preApprove=true: generate + validate a code so handle() proceeds to dispatch.
    let actualArgs : Text = if (preApprove) {
      let code = ApprovalModel.request(approvalState, approvalWorkflowName, "{}", 0, 0, testTurnId, testUserId);
      ignore ApprovalModel.approve(approvalState, code, testUserId, Set.empty());
      Json.stringify(obj([("approvalCode", str(code))]), null);
    } else {
      args;
    };
    let outcome = await WorkflowEngineHandler.handle(descriptor, engineDispatch, envelopeContext, resolveSlackBotToken, testUserId, sourceRef, actualArgs);
    switch (outcome) {
      case (#ok(t)) { t };
      case (#err(e)) { e };
    };
  };

  /// Test the SlackEventIntakeService in isolation.
  /// Parses the raw JSON body, normalizes and enqueues the event into testEventStore.
  /// Returns a plain-text discriminant:
  ///   "enqueued:<eventId>" — event was normalized and stored
  ///   "duplicate"          — event already present in the store
  ///   "skipped:<reason>"   — event was recognized but intentionally dropped
  ///   "notEventCallback"   — envelope is not an event_callback
  ///   "parseError:<msg>"   — JSON parsing or validation failed
  public shared ({ caller }) func testSlackEventIntakeService(body : Text) : async Text {
    assert caller == parent;
    switch (SlackEventIntakeService.processEventBody(testEventStore, body)) {
      case (#enqueued(eventId)) { "enqueued:" # eventId };
      case (#duplicate) { "duplicate" };
      case (#skipped(reason)) { "skipped:" # reason };
      case (#notEventCallback) { "notEventCallback" };
      case (#parseError(msg)) { "parseError:" # msg };
    };
  };

  /// Return event store statistics for test assertions.
  /// JSON: { "success": true, "unprocessedEvents": N, "processedEvents": N, "failedEvents": N }
  public shared ({ caller }) func testGetEventStoreStats() : async Text {
    assert caller == parent;
    let s = EventStoreModel.sizes(testEventStore);
    Json.stringify(
      obj([
        ("success", bool(true)),
        ("unprocessedEvents", int(s.unprocessed)),
        ("processedEvents", int(s.processed)),
        ("failedEvents", int(s.failed)),
      ]),
      null,
    );
  };
};
