import Nat "mo:core/Nat";
import RunStoreModel "../../src/internal-engine/models/run-store-model";
import RunHelpers "../../src/internal-engine/runner/run-helpers";
import TestHelpers "./test-helpers";

// ============================================
// Internal Engine Test Canister
// ============================================
//
// IMPORTANT: Never add this canister to icp.yaml or deploy it.
//
// Exposes internal engine modules as public actor methods so PocketIC TypeScript
// integration tests can invoke them over Candid. Placeholder only — methods will
// be expanded as coverage is added in future sessions.

shared ({ caller = _parent }) persistent actor class InternalEngineTestCanister() = self {

  // ── Run Store ─────────────────────────────────────────────────────

  let runStore = RunStoreModel.empty();

  /// Enqueue a minimal test envelope and return ok/duplicate.
  public func testEnqueue(envelopeId : Nat) : async Text {
    let envelope = TestHelpers.minimalEnvelope(envelopeId, "test-agent", "Hello");
    let record = RunHelpers.fromEnvelope(envelope, 0);
    switch (RunStoreModel.enqueue(runStore, record)) {
      case (#ok) { "ok" };
      case (#duplicate) { "duplicate" };
    };
  };

  /// Return the number of runs in each store bucket.
  public query func testGetSizes() : async {
    running : Nat;
    completed : Nat;
    failed : Nat;
  } {
    RunStoreModel.sizes(runStore);
  };

  /// Return a JSON summary of a run record by envelopeId, or null if not found.
  /// Fields included: envelopeId, requestId, agentName, enqueuedAt, status.
  public query func testGetRunRecord(envelopeId : Nat) : async ?Text {
    switch (RunStoreModel.get(runStore, envelopeId)) {
      case (null) { null };
      case (?r) {
        let status = switch (r.status) {
          case (null) { "null" };
          case (?#completed) { "completed" };
          case (?#roundLimitReached) { "roundLimitReached" };
          case (?#failed(_)) { "failed" };
        };
        ?(
          "{\"envelopeId\":" # Nat.toText(r.envelopeId) #
          ",\"requestId\":\"" # r.requestId # "\"" #
          ",\"agentName\":\"" # r.agentName # "\"" #
          ",\"enqueuedAt\":" # debug_show (r.enqueuedAt) #
          ",\"status\":\"" # status # "\"}"
        );
      };
    };
  };

};
