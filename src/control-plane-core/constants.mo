import Types "./types";

module {
  // Minimum log level — set this to #info or #warn for production to reduce noise.
  // All levels at or above this threshold will be emitted.
  public let MIN_LOG_LEVEL : Types.LogLevel = #_debug;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  public let THIRTY_DAYS_NS : Nat = 2_592_000_000_000_000;

  // 7 days in nanoseconds (7 * 24 * 60 * 60 * 1_000_000_000)
  // Used for periodic cleanup of processed events map
  public let SEVEN_DAYS_NS : Nat = 604_800_000_000_000;

  // 1 hour in nanoseconds (60 * 60 * 1_000_000_000)
  // Used to detect unprocessed events that were never picked up
  public let ONE_HOUR_NS : Nat = 3_600_000_000_000;

  // Log raw Slack event payloads for development/debugging
  // Set it to true for dev/staging to output raw JSON via `icp canister logs`
  // Useful for creating new test stubs and debugging event parsing
  public let LOG_SLACK_EVENTS : Bool = true;

  // 1 year in nanoseconds (365 * 24 * 60 * 60 * 1_000_000_000)
  // Retention period for the access change log in SlackUserModel
  public let ACCESS_LOG_RETENTION_NS : Nat = 31_536_000_000_000_000;

  // Channel history retention
  // Messages/groups older than this are dropped by the weekly prune timer.
  // 30 days in seconds (30 * 24 * 3600)
  public let CHANNEL_HISTORY_RETENTION_SECS : Nat = 2_592_000;

  // Agent routing round control
  // Absolute ceiling on the number of LLM rounds any session may run.
  public let MAX_AGENT_ROUNDS : Nat = 10;

  // Required name for the org-admin Slack channel.
  // Members of this channel are treated as org-level admins.
  // The channel MUST be named exactly this value (without the `#` prefix) for
  // visibility and security best practices. The reconciliation service verifies
  // this on every weekly run and warns the Primary Owner if the name has changed.
  public let ORG_ADMIN_CHANNEL_NAME : Text = "looping-ai-org-admins";

  // Secrets whose access events are excluded from the audit log when
  // stored on workspace 0. These high-frequency org-level credentials would
  // produce too much noise in the log on every request signature check.
  // Secrets stored on workspace > 0 are always logged regardless of this list.
  public let SECRET_AUDIT_EXCLUSIONS : [Types.SecretId] = [#slackBotToken, #slackSigningSecret, #relaySharedSecret];

  // Platform-level secrets that power the Slack integration itself.
  // These must never be readable by agent code — they are infrastructure
  // credentials managed exclusively by org-level admins on workspace 0.
  // `resolveSecret` hard-blocks any request for these variants, and
  // `parseAgentSecretId` refuses to admit them into agent configuration.
  public let PLATFORM_SECRETS : [Types.SecretId] = [#slackBotToken, #slackSigningSecret, #relaySharedSecret];

  // Turn cleanup retention — 90 days in nanoseconds (90 * 24 * 60 * 60 * 1_000_000_000)
  // Turns with `startedAtNs` older than this are hard-deleted by the turn-cleanup timer.
  public let TURN_CLEANUP_RETENTION_NS : Nat = 7_776_000_000_000_000;

  // Trace cleanup retention — 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  // Traces for turns with `startedAtNs` older than this are deleted independently of the
  // owning turn, keeping heap usage bounded while turns remain queryable for 90 days.
  public let TRACE_CLEANUP_RETENTION_NS : Nat = 2_592_000_000_000_000;

  // Envelope cleanup retention — 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  // Envelope records with `createdAtNs` older than this are purged by the weekly cleanup
  // timer. Kept as a separate constant from TRACE_CLEANUP_RETENTION_NS for independent tuning.
  public let ENVELOPE_CLEANUP_RETENTION_NS : Nat = 2_592_000_000_000_000;

  // Workflow token time-to-live — 60 minutes in nanoseconds (60 * 60 * 1_000_000_000)
  // Tokens are issued by Core when spawning an engine run and auto-expire after this window.
  public let WORKFLOW_TOKEN_TTL_NS : Int = 3_600_000_000_000;

  // Approval TTL — 1 hour in nanoseconds (60 * 60 * 1_000_000_000)
  // Pending approvals auto-expire after this window; the per-turn one-shot timer fires
  // `resumeWithDenial` with reason "approval timed out".
  public let APPROVAL_TTL_NS : Int = 3_600_000_000_000;

  // Default session policy — token budgets for context-window management.
  // The admin agent can override these per-agent via the update_session_policy tool.
  public let DEFAULT_SUMMARY_TOKEN_BUDGET : Nat = 32768; // 32k
  public let DEFAULT_MAX_TRUNCATED_TOKENS : Nat = 4096; // 4k

  // ── Engine lifecycle ───────────────────────────────────────────────

  // Cycles attached when spawning the engine canister (2 trillion)
  public let ENGINE_SPAWN_CYCLES : Nat = 2_000_000_000_000;

  // Minimum cycle balance before triggering a top-up (500 billion)
  public let ENGINE_MIN_CYCLES : Nat = 500_000_000_000;

  // Cycles deposited per top-up (1 trillion)
  public let ENGINE_TOPUP_CYCLES : Nat = 1_000_000_000_000;

  // ── LLM Relay (Cloudflare Worker) ─────────────────────────────────

  // Endpoint of the Cloudflare Worker relay that proxies LLM requests to
  // OpenRouter and delivers responses back via a signed webhook callback.
  public let LLM_RELAY_URL : Text = "https://looping-llm-api-worker.looping-ai-account.workers.dev";

};
