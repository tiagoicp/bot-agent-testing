import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import AgentHelpers "../helpers";
import StoreSecretHandler "./handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "./handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "./handlers/secrets/delete-secret-handler";
import WorkflowEngineHandler "./handlers/workflow-engine-handler";
import WorkflowCatalogService "../../services/workflow-catalog-service";
import WorkflowCatalogTypes "../../types/workflow-catalog";
import SecretModel "../../models/secret-model";
import SessionModel "../../models/session-model";

module {
  // ============================================
  // Function Tool Registry
  // ============================================
  //
  // Resource-based registry of function tools.
  // Tools are generated dynamically based on provided resources,
  // creating a natural allowlist mechanism.
  //
  // Each tool has its definition (what LLM sees) and handler (implementation).
  // Handlers are closures over provided resources.
  //
  // To add a new tool:
  // 1. Create a private function that returns FunctionTool
  // 2. Capture required resources in the closure
  // 3. Add it to getAll() with appropriate resource checks
  //
  // ============================================

  /// A function tool with definition and implementation
  public type FunctionTool = {
    definition : OpenRouterWrapper.Tool;
    handler : (Text) -> async ToolTypes.ToolCallOutcome;
  };

  /// Get all registered function tools available for the given resources
  public func getAll(resources : ToolTypes.ToolResources) : [FunctionTool] {
    let tools = List.empty<FunctionTool>();

    // ==========================================
    // SECRETS MANAGEMENT TOOLS - require secrets resource + userAuthContext + workspaceId
    // ==========================================
    switch (resources.secrets, resources.userAuthContext, resources.workspaceId) {
      case (?sec, ?uac, ?wsId) {
        // Read tools — always available when resource, user identity, and workspace are present
        List.add(tools, getWorkspaceSecretsTool(sec.state, uac, wsId));
        // Write tools — require write=true
        if (sec.write) {
          List.add(tools, storeSecretTool(sec.state, sec.workspaceKey, uac, wsId));
          List.add(tools, deleteSecretTool(sec.state, uac, wsId));
        };
      };
      case _ {};
    };

    // ==========================================
    // WORKFLOW ENGINE TOOLS - requires engineDispatch + envelopeContext
    // One tool per permitted workflow descriptor, built dynamically from the catalog.
    // ==========================================
    switch (resources.engineDispatch, resources.envelopeContext) {
      case (?ed, ?ec) {
        switch (ed.catalogState.cached) {
          case (?{ descriptors; catalogHash = _ }) {
            let grants = AgentHelpers.buildScopeGrants(ec.agent);
            let uid = switch (resources.userAuthContext) {
              case (?uac) { uac.slackUserId };
              case (null) { "" };
            };
            for (descriptor in WorkflowCatalogService.filterByScopes(descriptors, grants).vals()) {
              List.add(tools, workflowTool(descriptor, ed, ec, resources.resolveSlackBotToken, uid, resources.sourceRef));
            };
          };
          case (null) {}; // catalog not yet loaded — pre-loaded by admin-agent-loop before getAll
        };
      };
      case _ {};
    };

    List.toArray(tools);
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions(resources : ToolTypes.ToolResources) : [OpenRouterWrapper.Tool] {
    Array.map<FunctionTool, OpenRouterWrapper.Tool>(
      getAll(resources),
      func(t : FunctionTool) : OpenRouterWrapper.Tool { t.definition },
    );
  };

  /// Lookup a function tool by name (with resources for closures)
  public func get(resources : ToolTypes.ToolResources, name : Text) : ?FunctionTool {
    Array.find<FunctionTool>(
      getAll(resources),
      func(t : FunctionTool) : Bool {
        t.definition.function.name == name;
      },
    );
  };

  // ============================================
  // SECRETS MANAGEMENT TOOL IMPLEMENTATIONS
  // ============================================

  /// Get workspace secrets tool — always available when secrets resource + user identity + workspaceId are present
  private func getWorkspaceSecretsTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_workspace_secrets";
          description = ?"Lists the secret identifiers stored for the current workspace. Secret values are never returned — only the names of which secrets have been stored.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async ToolTypes.ToolCallOutcome {
        await GetWorkspaceSecretsHandler.handle(map, uac, workspaceId, args);
      };
    };
  };

  /// Store secret tool — requires secrets resource with write + user identity + workspaceId
  private func storeSecretTool(
    map : SecretModel.SecretsState,
    workspaceKey : [Nat8],
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "store_secret";
          description = ?"Encrypts and stores a secret for the current workspace. The Slack bot token (slackBotToken) requires org-admin access. LLM API keys (openRouterApiKey) can be stored by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"secretId\":{\"type\":\"string\",\"description\":\"Standard secret type: openRouterApiKey | slackBotToken | slackSigningSecret. For custom keys use \'custom:<name>\' format.\"},\"secretValue\":{\"type\":\"string\",\"description\":\"The secret value to encrypt and store.\"}},\"required\":[\"secretId\",\"secretValue\"]}";
        };
      };
      handler = func(args : Text) : async ToolTypes.ToolCallOutcome {
        StoreSecretHandler.handle(map, workspaceKey, uac, workspaceId, args);
      };
    };
  };

  /// Delete secret tool — requires secrets resource with write + user identity + workspaceId
  private func deleteSecretTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_secret";
          description = ?"Removes a stored secret from the current workspace. Slack secrets require org-admin access. LLM API keys can be deleted by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"secretId\":{\"type\":\"string\",\"description\":\"Standard secret type: openRouterApiKey | slackBotToken | slackSigningSecret. For custom keys use \'custom:<name>\' format.\"}},\"required\":[\"secretId\"]}";
        };
      };
      handler = func(args : Text) : async ToolTypes.ToolCallOutcome {
        await DeleteSecretHandler.handle(map, uac, workspaceId, args);
      };
    };
  };

  // ============================================
  // WORKFLOW ENGINE TOOL IMPLEMENTATION
  // ============================================

  /// One tool per workflow descriptor — name, description, and JSON schema come
  /// directly from the descriptor; dispatch is handled by WorkflowEngineHandler.
  private func workflowTool(
    descriptor : WorkflowCatalogTypes.WorkflowDescriptor,
    engineDispatch : ToolTypes.EngineDispatch,
    envelopeContext : ToolTypes.EnvelopeContext,
    resolveSlackBotToken : ?(Text -> ?Text),
    requestedByUserId : Text,
    sourceRef : ?SessionModel.SourceRef,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = descriptor.workflowName;
          description = ?descriptor.description;
          parameters = ?descriptor.parametersJsonSchema;
        };
      };
      handler = func(args : Text) : async ToolTypes.ToolCallOutcome {
        await WorkflowEngineHandler.handle(descriptor, engineDispatch, envelopeContext, resolveSlackBotToken, requestedByUserId, sourceRef, args);
      };
    };
  };
};
