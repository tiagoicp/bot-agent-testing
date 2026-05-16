import Json "mo:json";
import { obj; arr } "mo:json";
import Array "mo:core/Array";
import SecretModel "../../../../models/secret-model";
import SlackAuthMiddleware "../../../../middleware/slack-auth-middleware";
import Types "../../../../types";
import ToolTypes "../../tool-types";
import HandlerHelpers "../handler-helpers";

module {
  /// List the secret identifiers stored for a workspace (values are never returned).
  ///
  /// `workspaceId` is caller-provided (not from JSON args) to enforce workspace
  /// scoping — the LLM cannot target a different workspace.
  ///
  /// Authorization: requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
    _args : Text,
  ) : async ToolTypes.ToolCallOutcome {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(workspaceId)])) {
      case (#err(msg)) {
        HandlerHelpers.makeError("unauthorized", "Unauthorized: " # msg);
      };
      case (#ok(())) {
        switch (SecretModel.getWorkspaceSecrets(secrets, workspaceId)) {
          case (#err(msg)) { HandlerHelpers.makeError("operationFailed", msg) };
          case (#ok(secretIds)) {
            let idStrings = secretIdArrayToJson(secretIds);
            #ok(
              Json.stringify(
                obj([
                  ("secretIds", arr(idStrings)),
                ]),
                null,
              )
            );
          };
        };
      };
    };
  };

  /// Convert a SecretId variant to its string name.
  private func secretIdToString(id : Types.SecretId) : Text {
    switch (id) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
      case (#relaySharedSecret) { "relaySharedSecret" };
      case (#custom(name)) { "custom:" # name };
    };
  };

  private func secretIdArrayToJson(ids : [Types.SecretId]) : [Json.Json] {
    Array.map<Types.SecretId, Json.Json>(
      ids,
      func(id : Types.SecretId) : Json.Json {
        #string(secretIdToString(id));
      },
    );
  };
};
