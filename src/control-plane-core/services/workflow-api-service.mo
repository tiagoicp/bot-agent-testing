import Json "mo:json";
import { str; obj; arr; int } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Text "mo:core/Text";
import List "mo:core/List";
import Set "mo:core/Set";
import Time "mo:core/Time";
import WorkspaceModel "../models/workspace-model";
import AgentModel "../models/agent-model";
import ApprovalModel "../models/approval-model";
import EventStoreModel "../models/event-store-model";
import SessionModel "../models/session-model";
import WorkflowTypes "../types/workflow";
import WorkflowEnvelopeModel "../models/workflow-envelope-model";
import Constants "../constants";

module {

  // ── Dependencies (threaded from main.mo) ───────────────────────────

  public type ServiceDeps = {
    envelopeState : WorkflowEnvelopeModel.EnvelopeState;
    workspaces : WorkspaceModel.WorkspacesState;
    agentRegistry : AgentModel.AgentRegistryState;
    approvalState : ApprovalModel.ApprovalState;
    eventStore : EventStoreModel.EventStoreState;
    sessionStores : SessionModel.SessionStores;
  };

  public class Service(deps : ServiceDeps) {

    // ── Main handler (synchronous — NOT async) ─────────────────────────

    public func handleRequest(
      method : WorkflowTypes.HttpMethod,
      path : Text,
      body : Text,
    ) : WorkflowTypes.HandleResult {
      let asyncEffects = List.empty<WorkflowTypes.AsyncEffect>();

      // 1. Parse JSON body
      let parsed = switch (Json.parse(body)) {
        case (#err(_)) {
          return result(errorResponse("parseError", "Invalid JSON in request body."), asyncEffects);
        };
        case (#ok(json)) { json };
      };

      // 2. Extract envelopeNonce from body
      let envelopeNonce = switch (Json.get(parsed, "envelopeNonce")) {
        case (?#string(n)) { n };
        case (_) {
          return result(errorResponse("missingField", "Missing or invalid 'envelopeNonce'."), asyncEffects);
        };
      };

      // 3. Parse path segments and dispatch
      let segments = parsePath(path);
      let response = switch (segments.size()) {

        // ── Single-segment routes (collection-level) ───────────────
        case 1 {
          switch (method, segments[0]) {
            // #workspace scoped routes
            case (#get, "workspace") {
              handleWorkspaceGet(envelopeNonce);
            };
            case (#post, "workspace") {
              handleWorkspaceCreate(envelopeNonce, parsed);
            };

            // #agents scoped routes
            case (#get, "agent") { handleAgentList(envelopeNonce) };
            case (#post, "agent") { handleAgentCreate(envelopeNonce, parsed) };

            case _ { errorResponse("routeNotFound", "Not found: " # path) };
          };
        };

        // ── Two-segment routes (resource-level or event sub-action) ─
        case 2 {
          let (seg0, seg1) = (segments[0], segments[1]);
          switch (method, seg0) {
            // #workspace scoped routes
            case (#post, "workspace") {
              switch (seg1) {
                case "update" {
                  handleWorkspaceUpdate(envelopeNonce, parsed);
                };
                case "admin-channel" {
                  handleSetAdminChannel(envelopeNonce, parsed);
                };
                case _ {
                  errorResponse("routeNotFound", "Not found: POST /workspace/" # seg1);
                };
              };
            };
            case (#delete, "workspace") {
              handleWorkspaceDelete(envelopeNonce, seg1, parsed);
            };

            // #agents scoped routes
            case (#get, "agent") { handleAgentGet(envelopeNonce, seg1) }; // #agent scope route
            case (#post, "agent") {
              handleAgentUpdate(envelopeNonce, seg1, parsed);
            };
            case (#delete, "agent") {
              handleAgentDelete(envelopeNonce, seg1);
            };

            // Slack Queue routes
            case (#get, "slack-queue") {
              switch (seg1) {
                case "stats" { handleSlackQueueStats(envelopeNonce) };
                case "failed" { handleSlackQueueFailedList(envelopeNonce) };
                case _ {
                  errorResponse("routeNotFound", "Not found: GET /slack-queue/" # seg1);
                };
              };
            };

            // Workflow event webhook
            case (#post, "workflow") {
              switch (seg1) {
                case "milestone" {
                  handleEventMilestone(envelopeNonce, asyncEffects, parsed);
                };
                case "complete" {
                  handleEventComplete(envelopeNonce, asyncEffects, parsed);
                };
                case _ {
                  errorResponse("routeNotFound", "Not found: POST /workflow/" # seg1);
                };
              };
            };

            // Agent Session Policy routes
            case (#post, "session") {
              switch (seg1) {
                case "policy" {
                  handleSessionPolicy(envelopeNonce, parsed);
                };
                case _ {
                  errorResponse("routeNotFound", "Not found: POST /session/" # seg1);
                };
              };
            };
            case _ { errorResponse("routeNotFound", "Not found: " # path) };
          };
        };

        case _ { errorResponse("routeNotFound", "Not found: " # path) };
      };

      result(response, asyncEffects);
    };

    // ── Token helpers ────────────────────────────────────────────────────

    /// Extract the workspace ID bound to a token. Returns null for invalid/expired tokens.
    private func getTokenWorkspaceId(envelopeNonce : Text) : ?Nat {
      switch (WorkflowEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) { null };
        case (?record) { ?record.workspaceId };
      };
    };

    /// Validates a scope grant and extracts the workspace ID from the token in one step.
    /// Returns #err if scope is missing or the token is invalid/expired.
    private func requireScope(
      envelopeNonce : Text,
      grant : WorkflowTypes.ScopeGrant,
    ) : { #ok : Nat; #err : (Text, Text) } {
      switch (checkGrant(envelopeNonce, grant)) {
        case (#err(e)) { #err(e) };
        case (#ok) {
          switch (getTokenWorkspaceId(envelopeNonce)) {
            case (null) { #err("invalidToken", "Invalid or expired token.") };
            case (?ws) { #ok(ws) };
          };
        };
      };
    };

    /// Looks up an agent and verifies it belongs to the token's workspace.
    /// Defense-in-depth: the token workspaceId equals agent.ownedBy at dispatch time,
    /// so a mismatch indicates a programming error or a tampered token.
    private func requireOwnedAgent(
      tokenWs : Nat,
      agentId : Nat,
    ) : { #ok : AgentModel.AgentRecord; #err : (Text, Text) } {
      switch (AgentModel.lookupById(deps.agentRegistry, agentId)) {
        case (null) { #err("agentNotFound", "Agent not found.") };
        case (?a) {
          if (a.ownedBy != tokenWs) {
            #err("forbidden", "Workspace boundary violation: agent not owned by token workspace.");
          } else {
            #ok(a);
          };
        };
      };
    };

    // ── Workspace handlers ─────────────────────────────────────────────

    /// Returns the token's own workspace.
    private func handleWorkspaceGet(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #read }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      switch (WorkspaceModel.getWorkspace(deps.workspaces, tokenWs)) {
        case (null) {
          errorResponse("workspaceNotFound", "Workspace not found.");
        };
        case (?w) { okResponse(?workspaceRecordToJson(w)) };
      };
    };

    private func handleWorkspaceCreate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      // Only org admin (ws 0) can create new workspaces
      if (not WorkspaceModel.isOrgWorkspace(tokenWs)) {
        return errorResponse("forbidden", "Only org admin can create workspaces.");
      };
      let name = switch (requireString(body, "name")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      switch (WorkspaceModel.createWorkspace(deps.workspaces, name)) {
        case (#ok(id)) { okResponse(?int(id)) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    private func handleWorkspaceUpdate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      let newName = switch (requireString(body, "name")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      switch (WorkspaceModel.renameWorkspace(deps.workspaces, tokenWs, newName)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    private func handleWorkspaceDelete(envelopeNonce : Text, idStr : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let workspaceId = switch (Nat.fromText(idStr)) {
        case (null) {
          return errorResponse("invalidId", "Invalid workspace id: " # idStr # ".");
        };
        case (?id) { id };
      };
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      // Only org admin (ws 0) can delete workspaces
      if (not WorkspaceModel.isOrgWorkspace(tokenWs)) {
        return errorResponse("forbidden", "Only org admin can delete workspaces.");
      };
      // Require a valid, approved, unexpired, matching approval code
      let approvalCode = switch (Json.get(body, "approvalCode")) {
        case (?#string(c)) { c };
        case (_) {
          return errorResponse("approvalRequired", "An approval code is required to delete a workspace.");
        };
      };
      let approval = switch (ApprovalModel.findByCode(deps.approvalState, approvalCode)) {
        case (null) {
          return errorResponse("approvalInvalid", "Approval code not found.");
        };
        case (?r) { r };
      };
      switch (approval.status) {
        case (#approved) {};
        case (_) {
          return errorResponse("approvalInvalid", "Approval code has not been approved.");
        };
      };
      if (ApprovalModel.isWorkflowWindowExpired(approval, Time.now())) {
        let ttlHours = 2 * (Nat.fromInt(Constants.APPROVAL_TTL_NS) / 3_600_000_000_000);
        return errorResponse("approvalExpired", "Approval code has expired. Approvals must be executed within " # Nat.toText(ttlHours) # " hour(s) of being requested.");
      };
      if (approval.workspaceId != workspaceId or approval.workflowName != "workspace_delete") {
        return errorResponse("approvalMismatch", "Approval code does not match this workspace delete request.");
      };
      switch (WorkspaceModel.deleteWorkspace(deps.workspaces, workspaceId)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    // ── Agent handlers ─────────────────────────────────────────────────

    private func handleAgentList(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #read }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      let agents = AgentModel.listAgents(deps.agentRegistry);
      let items = List.empty<Json.Json>();
      for (a in agents.vals()) {
        // Workspace boundary: only show agents owned by token's workspace
        if (a.ownedBy == tokenWs) {
          List.add(items, agentRecordToJson(a));
        };
      };
      okResponse(?arr(List.toArray(items)));
    };

    private func handleAgentGet(envelopeNonce : Text, idStr : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) {
          return errorResponse("invalidId", "Invalid agent id: " # idStr # ".");
        };
        case (?id) { id };
      };
      // Admins (agents:read) can get any agent in their workspace.
      // Non-admin agents can only read their own record (#agent scope with matching id).
      if (
        not validateScope(envelopeNonce, #agents({ access = #read })) and
        not validateScope(envelopeNonce, #agent({ id = agentId; access = #read }))
      ) {
        return errorResponse("forbidden", "Token does not grant access to agent " # idStr # ".");
      };
      let tokenWs = switch (getTokenWorkspaceId(envelopeNonce)) {
        case (null) {
          return errorResponse("invalidToken", "Invalid or expired token.");
        };
        case (?ws) { ws };
      };
      let agent = switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(a)) { a };
      };
      okResponse(?agentRecordToJson(agent));
    };

    private func handleAgentCreate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      let name = switch (requireString(body, "name")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      let model = switch (requireString(body, "model")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      // workspaceId is implicit from token — NOT accepted in body
      let channelSet = switch (Json.get(body, "allowedChannelIds")) {
        case (?#array(items)) {
          let set = Set.empty<Text>();
          for (item in items.vals()) {
            switch (item) {
              case (#string(s)) { Set.add(set, Text.compare, s) };
              case _ {
                return errorResponse("invalidValue", "'allowedChannelIds' must be an array of strings.");
              };
            };
          };
          set;
        };
        case (_) {
          return errorResponse("missingField", "Missing or invalid 'allowedChannelIds' field.");
        };
      };
      let engines = switch (parseOptionalWorkflowEngines(body)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(null)) { [] };
        case (#ok(?e)) { e };
      };
      let config : AgentModel.AgentConfig = {
        name;
        model;
        workflowEngines = engines;
        allowedChannelIds = channelSet;
        secrets = { allowed = []; overrides = [] };
      };
      switch (AgentModel.register(deps.agentRegistry, tokenWs, #custom, config)) {
        case (#ok(id)) { okResponse(?int(id)) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    private func handleAgentUpdate(envelopeNonce : Text, idStr : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) {
          return errorResponse("invalidId", "Invalid agent id: " # idStr # ".");
        };
        case (?id) { id };
      };
      // 1. Check scope authorization
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      // 2. Check agent ownership (workspace boundary)
      switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(_)) {};
      };
      let newName = switch (Json.get(body, "name")) {
        case (?#string(n)) { ?n };
        case (_) { null };
      };
      let newModel = switch (Json.get(body, "model")) {
        case (?#string(m)) { ?m };
        case (_) { null };
      };
      let newEngines = switch (parseOptionalWorkflowEngines(body)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      switch (AgentModel.updateById(deps.agentRegistry, agentId, { name = newName; model = newModel; workflowEngines = newEngines; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null })) {
        case (#ok(_)) { okResponse(null) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    // ── Agent delete handler ────────────────────────────────────────────

    private func handleAgentDelete(envelopeNonce : Text, idStr : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) {
          return errorResponse("invalidId", "Invalid agent id: " # idStr # ".");
        };
        case (?id) { id };
      };
      // 1. Check scope authorization
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      // 2. Check agent ownership (workspace boundary)
      switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(_)) {};
      };
      switch (AgentModel.unregisterById(deps.agentRegistry, agentId)) {
        case (#ok(_)) { okResponse(null) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    // ── Admin channel handler ──────────────────────────────────────────

    /// Sets admin channel on the token's own workspace.
    private func handleSetAdminChannel(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      let channelId = switch (requireString(body, "channelId")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(v)) { v };
      };
      switch (WorkspaceModel.setAdminChannel(deps.workspaces, tokenWs, channelId)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse("operationFailed", e) };
      };
    };

    // ── Event handlers ─────────────────────────────────────────────────

    private func handleSlackQueueStats(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      switch (checkGrant(envelopeNonce, #slackQueue({ access = #read }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok) {};
      };
      let stats = EventStoreModel.sizes(deps.eventStore);
      okResponse(?obj([("unprocessed", int(stats.unprocessed)), ("processed", int(stats.processed)), ("failed", int(stats.failed))]));
    };

    private func handleSlackQueueFailedList(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      switch (checkGrant(envelopeNonce, #slackQueue({ access = #read }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok) {};
      };
      let failed = EventStoreModel.listFailed(deps.eventStore);
      let items = List.empty<Json.Json>();
      for (e in failed.vals()) {
        List.add(
          items,
          obj([
            ("eventId", str(e.eventId)),
            ("error", str(e.failedError)),
          ]),
        );
      };
      okResponse(?arr(List.toArray(items)));
    };

    // ── Session handler ────────────────────────────────────────────────

    private func handleSessionPolicy(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #session({ access = #write }))) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(ws)) { ws };
      };
      let agentIdNum = switch (parsePositiveNat(body, "agentId")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(n)) { n };
      };
      // Workspace boundary: can only update session policy for own agents
      switch (requireOwnedAgent(tokenWs, agentIdNum)) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(_)) {};
      };
      let summaryBudget = switch (parsePositiveNat(body, "summaryTokenBudget")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(n)) { n };
      };
      let maxTruncated = switch (parsePositiveNat(body, "maxTruncatedTokens")) {
        case (#err(t, m)) { return errorResponse(t, m) };
        case (#ok(n)) { n };
      };
      let policy : SessionModel.SessionPolicy = {
        summaryTokenBudget = summaryBudget;
        maxTruncatedTokens = maxTruncated;
      };
      if (SessionModel.updateSessionPolicy(deps.sessionStores, agentIdNum, policy)) {
        okResponse(null);
      } else {
        errorResponse("updateFailed", "Failed to update session policy.");
      };
    };

    // ── Event milestone/complete handlers ──────────────────────────────

    private func handleEventMilestone(
      envelopeNonce : Text,
      asyncEffects : List.List<WorkflowTypes.AsyncEffect>,
      body : Json.Json,
    ) : {
      #ok : Text;
      #err : Text;
    } {
      let record = switch (WorkflowEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) {
          return errorResponse("invalidToken", "Invalid or expired token.");
        };
        case (?r) { r };
      };
      let humanSummary = switch (Json.get(body, "humanSummary")) {
        case (?#string(s)) { s };
        case (_) {
          return errorResponse("missingField", "Missing 'humanSummary' field.");
        };
      };
      let stepsDetail = parseStepsDetail(body);
      List.add(
        asyncEffects,
        #milestone({
          envelopeId = record.envelopeId;
          turnId = record.turnId;
          humanSummary;
          stepsDetail;
        }),
      );
      okResponse(null);
    };

    private func handleEventComplete(
      envelopeNonce : Text,
      asyncEffects : List.List<WorkflowTypes.AsyncEffect>,
      body : Json.Json,
    ) : {
      #ok : Text;
      #err : Text;
    } {
      let record = switch (WorkflowEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) {
          return errorResponse("invalidToken", "Invalid or expired token.");
        };
        case (?r) { r };
      };
      let humanSummary = switch (Json.get(body, "humanSummary")) {
        case (?#string(s)) { s };
        case (_) {
          return errorResponse("missingField", "Missing 'humanSummary' field.");
        };
      };
      let stepsDetail = parseStepsDetail(body);
      let status = parseWorkflowStatus(body);
      let stats = parseWorkflowStats(body);

      // Revoke token immediately (defense-in-depth)
      WorkflowEnvelopeModel.revoke(deps.envelopeState, envelopeNonce);

      List.add(
        asyncEffects,
        #complete({
          envelopeId = record.envelopeId;
          turnId = record.turnId;
          humanSummary;
          stepsDetail;
          status;
          stats;
        }),
      );
      okResponse(null);
    };

    // ── Response builders ───────────────────────────────────────────────

    private func result(
      response : { #ok : Text; #err : Text },
      asyncEffects : List.List<WorkflowTypes.AsyncEffect>,
    ) : WorkflowTypes.HandleResult {
      { response; asyncEffects = List.toArray(asyncEffects) };
    };

    private func okResponse(data : ?Json.Json) : { #ok : Text; #err : Text } {
      switch (data) {
        case (?d) { #ok(Json.stringify(d, null)) };
        case (null) { #ok("{}") };
      };
    };

    private func errorResponse(errType : Text, message : Text) : {
      #ok : Text;
      #err : Text;
    } {
      #err(Json.stringify(obj([("type", str(errType)), ("message", str(message))]), null));
    };

    // ── Serialization helpers ──────────────────────────────────────────

    private func workspaceRecordToJson(w : WorkspaceModel.WorkspaceRecord) : Json.Json {
      let fields = List.empty<(Text, Json.Json)>();
      List.add(fields, ("id", int(w.id)));
      List.add(fields, ("name", str(w.name)));
      switch (w.adminChannelId) {
        case (?ch) { List.add(fields, ("adminChannelId", str(ch))) };
        case (null) {};
      };
      obj(List.toArray(fields));
    };

    private func agentRecordToJson(a : AgentModel.AgentRecord) : Json.Json {
      let categoryText = switch (a.category) {
        case (#_system(#admin)) { "system:admin" };
        case (#_system(#onboarding)) { "system:onboarding" };
        case (#custom) { "custom" };
      };
      let engineItems = List.empty<Json.Json>();
      for (e in a.config.workflowEngines.vals()) {
        List.add(engineItems, str(workflowEngineToText(e)));
      };
      let channelItems = List.empty<Json.Json>();
      for (ch in Set.toArray(a.config.allowedChannelIds).vals()) {
        List.add(channelItems, str(ch));
      };
      let secretAllowedItems = List.empty<Json.Json>();
      for ((wsId, sid) in a.config.secrets.allowed.vals()) {
        let sidText = switch (sid) {
          case (#openRouterApiKey) { "openRouterApiKey" };
          case (#slackBotToken) { "slackBotToken" };
          case (#slackSigningSecret) { "slackSigningSecret" };
          case (#relaySharedSecret) { "relaySharedSecret" };
          case (#custom(name)) { "custom:" # name };
        };
        List.add(
          secretAllowedItems,
          obj([("workspaceId", int(wsId)), ("secretId", str(sidText))]),
        );
      };
      let secretOverrideItems = List.empty<Json.Json>();
      for ((sid, customName) in a.config.secrets.overrides.vals()) {
        let sidText = switch (sid) {
          case (#openRouterApiKey) { "openRouterApiKey" };
          case (#slackBotToken) { "slackBotToken" };
          case (#slackSigningSecret) { "slackSigningSecret" };
          case (#relaySharedSecret) { "relaySharedSecret" };
          case (#custom(name)) { "custom:" # name };
        };
        List.add(
          secretOverrideItems,
          obj([("secretId", str(sidText)), ("customKeyName", str(customName))]),
        );
      };
      obj([
        ("id", int(a.id)),
        ("ownedBy", int(a.ownedBy)),
        ("category", str(categoryText)),
        ("name", str(a.config.name)),
        ("model", str(a.config.model)),
        ("workflowEngines", arr(List.toArray(engineItems))),
        ("allowedChannelIds", arr(List.toArray(channelItems))),
        (
          "secrets",
          obj([
            ("allowed", arr(List.toArray(secretAllowedItems))),
            ("overrides", arr(List.toArray(secretOverrideItems))),
          ]),
        ),
      ]);
    };

    // ── WorkflowEngine helpers ───────────────────────────────────────────────────

    private func workflowEngineToText(e : AgentModel.WorkflowEngine) : Text {
      switch (e) {
        case (#canister) { "canister" };
        case (#github) { "github" };
      };
    };

    private func parseOptionalWorkflowEngines(body : Json.Json) : {
      #ok : ?[AgentModel.WorkflowEngine];
      #err : (Text, Text);
    } {
      switch (Json.get(body, "workflowEngines")) {
        case (null) { #ok(null) };
        case (?#array(items)) {
          let engines = List.empty<AgentModel.WorkflowEngine>();
          for (item in items.vals()) {
            switch (item) {
              case (#string("canister")) { List.add(engines, #canister) };
              case (#string("github")) { List.add(engines, #github) };
              case (#string(s)) {
                return #err("invalidValue", "Unknown workflowEngine value: '" # s # "'.");
              };
              case (_) {
                return #err("invalidValue", "'workflowEngines' must be an array of strings.");
              };
            };
          };
          #ok(?List.toArray(engines));
        };
        case (_) {
          #err("invalidValue", "'workflowEngines' must be an array.");
        };
      };
    };

    // ── Path parsing ───────────────────────────────────────────────────

    private func parsePath(path : Text) : [Text] {
      let parts = Text.split(path, #char '/');
      let segments = List.empty<Text>();
      for (p in parts) {
        if (Text.size(p) > 0) {
          List.add(segments, p);
        };
      };
      List.toArray(segments);
    };

    // ── Body field parsing helpers ─────────────────────────────────────

    /// Extracts a required string field from a JSON body object.
    private func requireString(body : Json.Json, key : Text) : {
      #ok : Text;
      #err : (Text, Text);
    } {
      switch (Json.get(body, key)) {
        case (?#string(v)) { #ok(v) };
        case (_) { #err("missingField", "Missing '" # key # "' field.") };
      };
    };

    /// Extracts a required non-negative number field and returns it as Nat.
    private func parsePositiveNat(body : Json.Json, key : Text) : {
      #ok : Nat;
      #err : (Text, Text);
    } {
      switch (Json.get(body, key)) {
        case (?#number(#int(n))) {
          if (n < 0) {
            #err("invalidValue", "Invalid '" # key # "': must be non-negative.");
          } else {
            #ok(Nat.fromInt(n));
          };
        };
        case (_) {
          #err("missingField", "Missing or invalid '" # key # "' field.");
        };
      };
    };

    private func parseStepsDetail(body : Json.Json) : [WorkflowTypes.SummarizedStep] {
      switch (Json.get(body, "stepsDetail")) {
        case (?#array(items)) {
          let steps = List.empty<WorkflowTypes.SummarizedStep>();
          for (item in items.vals()) {
            let tool = switch (Json.get(item, "tool")) {
              case (?#string(t)) { t };
              case (_) { "unknown" };
            };
            let summary = switch (Json.get(item, "summary")) {
              case (?#string(s)) { s };
              case (_) { "" };
            };
            let success = switch (Json.get(item, "success")) {
              case (?#bool(b)) { b };
              case (_) { false };
            };
            List.add(steps, { tool; summary; success });
          };
          List.toArray(steps);
        };
        case (_) { [] };
      };
    };

    private func parseWorkflowStatus(body : Json.Json) : WorkflowTypes.WorkflowStatus {
      switch (Json.get(body, "status")) {
        case (?#string("completed")) { #completed };
        case (?#string("roundLimitReached")) { #roundLimitReached };
        case (?#string("failed")) {
          let reason = switch (Json.get(body, "statusReason")) {
            case (?#string(r)) { r };
            case (_) { "Unknown failure" };
          };
          #failed(reason);
        };
        case (_) { #failed("Unknown status") };
      };
    };

    private func parseWorkflowStats(body : Json.Json) : WorkflowTypes.WorkflowStats {
      let statsObj = switch (Json.get(body, "stats")) {
        case (?obj) { obj };
        case (null) {
          return {
            durationNs = null;
            llmCalls = null;
            toolCalls = null;
            inputTokens = null;
            outputTokens = null;
            model = null;
            rounds = null;
            estimatedDollarCost = null;
          };
        };
      };
      let getOptInt = func(key : Text) : ?Int {
        switch (Json.get(statsObj, key)) {
          case (?#number(#int(n))) { ?n };
          case (?#number(#float(f))) { ?Float.toInt(f) };
          case (_) { null };
        };
      };
      let getOptNat = func(key : Text) : ?Nat {
        switch (getOptInt(key)) {
          case (?n) { if (n < 0) { null } else { ?Nat.fromInt(n) } };
          case (null) { null };
        };
      };
      {
        durationNs = getOptInt("durationNs");
        llmCalls = getOptNat("llmCalls");
        toolCalls = getOptNat("toolCalls");
        inputTokens = getOptNat("inputTokens");
        outputTokens = getOptNat("outputTokens");
        model = switch (Json.get(statsObj, "model")) {
          case (?#string(m)) { ?m };
          case (_) { null };
        };
        rounds = getOptNat("rounds");
        estimatedDollarCost = switch (Json.get(statsObj, "estimatedDollarCost")) {
          case (?#number(#float(f))) { ?f };
          case (?#number(#int(i))) { ?Float.fromInt(i) };
          case (_) { null };
        };
      };
    };

    // ── Scope validation ───────────────────────────────────────────────
    private func accessText(access : WorkflowTypes.ScopeAccess) : Text {
      switch (access) {
        case (#read) { "read" };
        case (#write) { "write" };
      };
    };

    private func grantText(grant : WorkflowTypes.ScopeGrant) : Text {
      switch (grant) {
        case (#workspace(w)) { "workspace:" # accessText(w.access) };
        case (#agents(a)) { "agents:" # accessText(a.access) };
        case (#agent(a)) {
          "agent:" # Nat.toText(a.id) # ":" # accessText(a.access);
        };
        case (#slackQueue(s)) { "slack-queue:" # accessText(s.access) };
        case (#session(s)) { "session:" # accessText(s.access) };
      };
    };

    /// Checks a scope grant, returning #ok or a derived error tuple on failure.
    private func checkGrant(
      envelopeNonce : Text,
      grant : WorkflowTypes.ScopeGrant,
    ) : { #ok; #err : (Text, Text) } {
      if (validateScope(envelopeNonce, grant)) { #ok } else {
        #err("unauthorized", "Token does not grant " # grantText(grant) # ".");
      };
    };
    private func validateScope(
      envelopeNonce : Text,
      requiredGrant : WorkflowTypes.ScopeGrant,
    ) : Bool {
      WorkflowEnvelopeModel.validate(deps.envelopeState, envelopeNonce, requiredGrant);
    };

  }; // end class Service

};
