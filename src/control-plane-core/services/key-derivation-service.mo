/// Key Derivation Service
/// Derives encryption keys via Threshold Schnorr signatures with caching
///
/// Each Workspace gets a unique, deterministic encryption key derived from:
/// 1. Calling sign_with_schnorr with workspace ID as derivation path + message
/// 2. Hashing the signature with SHA256 to get a 32-byte key

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";
import IC "mo:ic/Types";
import ICCall "mo:ic/Call";
import HKDF "../utilities/hkdf";

module {
  // ============================================
  // Constants
  // ============================================

  /// Schnorr key name — "key_1" is used across all environments
  public let KEY_NAME : Text = "key_1";

  /// Static message used for key derivation
  /// The workspace ID in derivation_path makes each key unique
  private let KEY_DERIVATION_MESSAGE : Blob = "workspace_api_key_encryption_v1";

  // ============================================
  // Key Cache Type
  // ============================================

  /// Cache of derived encryption keys per Workspace
  /// This avoids repeated expensive Schnorr calls
  public type KeyCache = Map.Map<Nat, [Nat8]>;

  // ============================================
  // Helper Functions
  // ============================================

  /// Convert a Nat to a big-endian byte array (8 bytes)
  private func natToBytes(n : Nat) : [Nat8] {
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        // Shift right by (7-i)*8 bits and mask with 0xFF
        Nat8.fromNat((n / (256 ** (7 - i))) % 256);
      },
    );
  };

  // ============================================
  // Key Derivation Functions
  // ============================================

  /// Derive an encryption key for a Workspace using Schnorr signatures
  /// The key is deterministic: same workspace ID always produces same key
  ///
  /// Algorithm:
  /// 1. Call sign_with_schnorr with workspace ID as derivation path
  /// 2. Hash the signature with SHA256 to get a 32-byte key
  ///
  /// @param workspaceId - The workspace ID to derive a key for
  /// @returns A 32-byte encryption key as [Nat8]
  public func deriveKeyFromSchnorr(workspaceId : Nat) : async [Nat8] {
    // Convert workspace ID to bytes for derivation path
    let workspaceIdBytes = natToBytes(workspaceId);

    // Prepare the signing request
    let signArgs : IC.SignWithSchnorrArgs = {
      message = KEY_DERIVATION_MESSAGE;
      derivation_path = [Blob.fromArray(workspaceIdBytes)];
      key_id = {
        algorithm = #ed25519; // Ed25519 is simpler and sufficient for our purpose
        name = KEY_NAME;
      };
      aux = null; // No BIP341 tweak needed
    };

    // Call the management canister with automatically calculated cycles
    let { signature } = await ICCall.signWithSchnorr(signArgs);

    // Hash the signature to get a 32-byte key
    // This ensures uniform distribution and fixed length
    let signatureBytes = Blob.toArray(signature);
    Blob.toArray(Sha256.fromArray(#sha256, signatureBytes));
  };

  /// Look up a cached key or derive a new one
  /// Mutates the cache if key needs to be derived
  ///
  /// @param cache - Current key cache (will be mutated)
  /// @param workspaceId - The workspace ID to get/derive key for
  /// @returns The encryption key
  public func getOrDeriveKey(
    cache : KeyCache,
    workspaceId : Nat,
  ) : async [Nat8] {
    // Check if key exists in cache
    switch (Map.get(cache, Nat.compare, workspaceId)) {
      case (?key) {
        key;
      };
      case (null) {
        // Key not in cache, derive it
        let key = await deriveKeyFromSchnorr(workspaceId);

        // Add to cache
        Map.add(cache, Nat.compare, workspaceId, key);

        key;
      };
    };
  };

  /// Clear all entries from the cache
  /// Should be called monthly via Timer
  public func clearCache() : KeyCache {
    Map.empty<Nat, [Nat8]>();
  };

  /// Get cache size (for monitoring)
  public func getCacheSize(cache : KeyCache) : Nat {
    Map.size(cache);
  };

  // ============================================
  // Relay Key Cache
  // ============================================

  /// Cache for the HKDF-derived AES-256 key used to encrypt the OpenRouter
  /// API key before forwarding it to the Cloudflare Worker relay.
  ///
  /// A single tagged optional pair is sufficient — there is exactly one
  /// `#relaySharedSecret` per deployment.  `entry.0` is the shared-secret
  /// text that was last used to derive the key; `entry.1` is the derived
  /// 32-byte AES key.  Comparing by secret text lets callers invalidate
  /// the cache simply by storing a new secret.
  public type RelayKeyCache = { var entry : ?(Text, [Nat8]) };

  /// Create an empty relay key cache.
  public func emptyRelayKeyCache() : RelayKeyCache {
    { var entry = null };
  };

  /// Look up a cached relay AES key, or derive one if the cache is stale.
  ///
  /// Worker HKDF contract (must stay in sync with the Cloudflare Worker):
  ///   salt = [] (empty → 32 zero bytes per RFC 5869 §2.2)
  ///   ikm  = UTF-8(sharedSecret)
  ///   info = UTF-8("openrouter-key-v1")
  ///   len  = 32
  ///
  /// This function is **synchronous** — HKDF is pure CPU, no async calls.
  ///
  /// @param cache         - Cache entry to read / update (mutated in place)
  /// @param sharedSecret  - Current relay shared secret text
  /// @returns 32-byte AES-256 key
  public func getOrDeriveRelayKey(cache : RelayKeyCache, sharedSecret : Text) : [Nat8] {
    // Return cached key when the secret hasn't changed.
    switch (cache.entry) {
      case (?(cachedSecret, key)) {
        if (cachedSecret == sharedSecret) { return key };
      };
      case (null) {};
    };

    // Derive: HKDF-SHA256(ikm=UTF8(sharedSecret), info=UTF8("openrouter-key-v1"), len=32)
    let ikm = Blob.toArray(Text.encodeUtf8(sharedSecret));
    let info = Blob.toArray(Text.encodeUtf8("openrouter-key-v1"));
    let key = HKDF.deriveKey(ikm, info, 32);

    cache.entry := ?(sharedSecret, key);
    key;
  };

  /// Invalidate the relay key cache.
  /// Call this whenever `#relaySharedSecret` is updated in main.mo.
  public func invalidateRelayKeyCache(cache : RelayKeyCache) {
    cache.entry := null;
  };
};
