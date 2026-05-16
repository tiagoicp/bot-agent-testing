/// Minimal HTTP response certification module for ICP.
///
/// Provides "skip certification" (no_certification) support for HTTP query responses,
/// so the IC HTTP gateway accepts them without full response verification.
///
/// Uses only `ic-certification` (MerkleTree) + `sha2` — no other external dependencies.
///
/// Usage:
///   1. Store:      `var certStore = HttpCertification.initStore();`
///   2. Certify:    call `HttpCertification.certifySkipFallbackPath(certStore, "/")` from an update context
///   3. Recertify:  call `HttpCertification.certifySkipFallbackPath(certStore, "/")` in `postupgrade`
///   4. Headers:    append `HttpCertification.getSkipCertificationHeaders(certStore, "/")` to query response

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import CertifiedData "mo:core/CertifiedData";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import MerkleTree "mo:ic-certification/MerkleTree";
import SHA256 "mo:sha2/Sha256";
import Base64 "./base64";

module {

  // ============================================
  // Public Types
  // ============================================

  /// Stable store for the certification Merkle tree.
  /// Declare as a `var` in a `persistent actor` — it survives upgrades automatically.
  public type CertStore = {
    var tree : MerkleTree.Tree;
  };

  // ============================================
  // Constants
  // ============================================

  /// The CEL expression that tells the HTTP gateway to skip verification.
  let SKIP_CERT_EXPR : Text = "default_certification ( ValidationArgs { no_certification: Empty { } } )";

  // ============================================
  // Public API
  // ============================================

  /// Create a new, empty certification store.
  public func initStore() : CertStore {
    { var tree = MerkleTree.empty() };
  };

  /// Register a URL fallback path as "skip certification" in the Merkle tree and
  /// commit the root hash via `CertifiedData.set`.
  ///
  /// **Must be called from an update context** (actor init, `postupgrade`, or an update method).
  /// Call once per fallback path you want to serve from `http_request` without full verification.
  public func certifySkipFallbackPath(store : CertStore, url : Text) {
    let textExprPath = buildTextExprPath(url);
    let blobExprPath = Array.map<Text, Blob>(textExprPath, Text.encodeUtf8);
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));

    // For no_certification both request_hash and response_hash are empty blobs
    let fullPath = appendBlobs(blobExprPath, [exprHash, "", ""]);
    store.tree := MerkleTree.put(store.tree, fullPath, "");
    CertifiedData.set(MerkleTree.treeHash(store.tree));
  };

  /// Return the two certification headers required by the IC HTTP gateway
  /// for a "skip certification" response at the given URL.
  ///
  /// Call this from `http_request` (query) and append the result to your response headers.
  /// Returns an empty array if the system certificate is unavailable
  /// (e.g. called from an update context instead of a query),
  /// or if no certified path covers the requested URL.
  ///
  /// When falling back to the root wildcard for an uncertified URL, the witness
  /// must prove **both** that the fallback path exists **and** that no more specific
  /// path exists for the request URL. The HTTP Gateway spec requires:
  ///   "The path must be the most specific path for the current request URL
  ///    in the tree, i.e. a lookup of more specific paths must return Absent."
  /// We achieve this by using `MerkleTree.reveals` to merge witnesses for the
  /// fallback path and the (absent) URL-specific path, which exposes sibling
  /// labels needed by `find_label` to return `Absent` instead of `Unknown`.
  public func getSkipCertificationHeaders(store : CertStore, url : Text) : [(Text, Text)] {
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));

    // Find the appropriate certified expression path.
    // Tries the exact URL path first, then falls back to the root wildcard.
    let (textExprPath, isFallback) = switch (findCertifiedPath(store, url)) {
      case (?(path, fb)) (path, fb);
      case null return [];
    };

    let blobExprPath = Array.map<Text, Blob>(textExprPath, Text.encodeUtf8);
    let fullPath = appendBlobs(blobExprPath, [exprHash, "", ""]);

    // Build the witness.
    // When using a fallback path (root wildcard), we must also prove that the
    // more-specific path for this URL is absent. We use `MerkleTree.reveals`
    // to produce a merged witness covering both paths. The absent-path witness
    // reveals neighbouring labels (e.g. "webhook" next to "<*>") so the HTTP
    // Gateway's `find_label` returns `Absent` rather than `Unknown`.
    let encodedWitness = if (isFallback) {
      let exactTextPath = buildTextExprPath(url);
      let exactBlobPath = Array.map<Text, Blob>(exactTextPath, Text.encodeUtf8);
      let exactFullPath = appendBlobs(exactBlobPath, [exprHash, "", ""]);

      let witness = MerkleTree.reveals(
        store.tree,
        [fullPath, exactFullPath].vals(),
      );
      MerkleTree.encodeWitness(witness);
    } else {
      let witness = MerkleTree.reveal(store.tree, fullPath);
      MerkleTree.encodeWitness(witness);
    };

    // System certificate — only available in query calls
    let certificate = switch (CertifiedData.getCertificate()) {
      case (?cert) cert;
      case null return [];
    };

    // CBOR-encode the text expression path for the header
    let encodedExprPath = cborEncodeTextArray(textExprPath);

    let icCertValue = "certificate=:" # base64(certificate) # ":, " #
    "tree=:" # base64(encodedWitness) # ":, " #
    "version=2, " #
    "expr_path=:" # base64(encodedExprPath) # ":";

    [
      ("ic-certificate", icCertValue),
      ("ic-certificateexpression", SKIP_CERT_EXPR),
    ];
  };

  /// Check if a path exists in the certification store's MerkleTree.
  ///
  /// Returns details about the path including whether it exists, the expression path array,
  /// and the current tree hash. Useful for testing and verification.
  public func checkPath(store : CertStore, url : Text) : {
    exists : Bool;
    path : [Text];
    treeHash : Blob;
  } {
    let textExprPath = buildTextExprPath(url);
    let blobExprPath = Array.map<Text, Blob>(textExprPath, Text.encodeUtf8);
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));
    let fullPath = appendBlobs(blobExprPath, [exprHash, "", ""]);

    // Check if path exists in the tree
    let pathExists = switch (MerkleTree.lookup(store.tree, fullPath)) {
      case (?_) { true };
      case (null) { false };
    };

    {
      exists = pathExists;
      path = textExprPath;
      treeHash = MerkleTree.treeHash(store.tree);
    };
  };

  // ============================================
  // Internal — Fallback Path Resolution
  // ============================================

  /// Find the appropriate certified expression path for a URL.
  ///
  /// Resolution order:
  ///   1. Exact URL path (e.g. ["http_expr", "webhook", "slack", "<*>"])
  ///   2. Root wildcard (["http_expr", "<*>"])  — covers all paths
  ///
  /// Returns `null` if no certified path covers the URL.
  /// The Bool indicates whether a fallback was used (true = fallback).
  func findCertifiedPath(store : CertStore, url : Text) : ?([Text], Bool) {
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));

    // 1. Try the exact path for this URL
    let exactTextPath = buildTextExprPath(url);
    let exactBlobPath = Array.map<Text, Blob>(exactTextPath, Text.encodeUtf8);
    let exactFullPath = appendBlobs(exactBlobPath, [exprHash, "", ""]);

    switch (MerkleTree.lookup(store.tree, exactFullPath)) {
      case (?_) { return ?(exactTextPath, false) };
      case null {};
    };

    // 2. Fall back to root wildcard ["http_expr", "<*>"]
    let rootTextPath : [Text] = ["http_expr", "<*>"];
    let rootBlobPath = Array.map<Text, Blob>(rootTextPath, Text.encodeUtf8);
    let rootFullPath = appendBlobs(rootBlobPath, [exprHash, "", ""]);

    switch (MerkleTree.lookup(store.tree, rootFullPath)) {
      case (?_) { ?(rootTextPath, true) };
      case null { null };
    };
  };

  // ============================================
  // Internal — Expression Path
  // ============================================

  /// Build the V2 text expression path for a URL (fallback variant).
  ///
  /// The root path "/" produces a root-level wildcard that covers ALL paths.
  /// Non-root paths produce a path-specific wildcard.
  ///
  /// Examples:
  ///   "/" → ["http_expr", "<*>"]              (root-level wildcard, covers all paths)
  ///   "/health" → ["http_expr", "health", "<*>"]
  ///   "/api/status" → ["http_expr", "api", "status", "<*>"]
  func buildTextExprPath(url : Text) : [Text] {
    // Strip query parameters (everything after '?')
    let pathOnly = switch (Text.split(url, #char '?').next()) {
      case (?path) { path };
      case (null) { url };
    };

    // Root path → root-level wildcard that covers ALL paths.
    // Using ["http_expr", "<*>"] (without an empty segment) ensures the wildcard
    // sits directly under http_expr, making it a valid fallback for any child path
    // (e.g. "/web", "/api/v1") — not just "/" itself.
    if (pathOnly == "" or pathOnly == "/") {
      return ["http_expr", "<*>"];
    };

    let parts = Text.split(pathOnly, #char '/');
    ignore parts.next(); // skip leading empty segment from "/"
    let segments = Iter.toArray(parts);

    let size : Nat = segments.size() + 2; // "http_expr" + segments + "<*>"
    let lastIdx : Nat = size - 1 : Nat;
    Array.tabulate<Text>(
      size,
      func(i : Nat) : Text {
        if (i == 0) "http_expr" else if (i < lastIdx) segments[i - 1 : Nat] else "<*>";
      },
    );
  };

  // ============================================
  // Internal — Minimal CBOR encoder (text arrays)
  // ============================================

  /// Encode a [Text] as CBOR: self-describing tag + array of text strings.
  func cborEncodeTextArray(arr : [Text]) : Blob {
    let encodedTexts = Array.map<Text, Blob>(arr, Text.encodeUtf8);

    // 1. Calculate total byte count
    var totalSize = 3; // self-describing tag: D9 D9 F7
    totalSize += cborHeaderLen(arr.size()); // array header
    for (encoded in encodedTexts.vals()) {
      totalSize += cborHeaderLen(encoded.size()); // text string header
      totalSize += encoded.size(); // text string body
    };

    // 2. Build flat byte array using a mutable array
    let result = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, totalSize));
    var pos = 0;

    // Self-describing CBOR tag (55799)
    result[pos] := 0xD9;
    pos += 1;
    result[pos] := 0xD9;
    pos += 1;
    result[pos] := 0xF7;
    pos += 1;

    // Array header (major type 4)
    pos := writeCborHeader(result, pos, 4 : Nat8, arr.size());

    // Each text string (major type 3)
    for (encoded in encodedTexts.vals()) {
      pos := writeCborHeader(result, pos, 3 : Nat8, encoded.size());
      for (b in encoded.vals()) {
        result[pos] := b;
        pos += 1;
      };
    };

    Blob.fromArray(Array.fromVarArray(result));
  };

  /// Write a CBOR major-type header into a mutable byte array. Returns updated position.
  func writeCborHeader(buf : [var Nat8], pos : Nat, majorType : Nat8, len : Nat) : Nat {
    let mt : Nat8 = majorType * 32;
    if (len < 24) {
      buf[pos] := mt + Nat8.fromNat(len);
      pos + 1;
    } else if (len < 256) {
      buf[pos] := mt + 24;
      buf[pos + 1] := Nat8.fromNat(len);
      pos + 2;
    } else {
      // len < 65536 — sufficient for any realistic expression path
      buf[pos] := mt + 25;
      buf[pos + 1] := Nat8.fromNat(len / 256);
      buf[pos + 2] := Nat8.fromNat(len % 256);
      pos + 3;
    };
  };

  /// Byte length of a CBOR major-type header for a given payload length.
  func cborHeaderLen(len : Nat) : Nat {
    if (len < 24) 1 else if (len < 256) 2 else 3;
  };

  // ============================================
  // Internal — Base64 encoder (delegates to utilities/base64)
  // ============================================

  func base64(data : Blob) : Text { Base64.encodeBlob(data) };

  // ============================================
  // Internal — Helpers
  // ============================================

  /// Concatenate two Blob arrays.
  func appendBlobs(a : [Blob], b : [Blob]) : [Blob] {
    let aLen = a.size();
    Array.tabulate<Blob>(
      aLen + b.size(),
      func(i : Nat) : Blob {
        if (i < aLen) a[i] else b[i - aLen];
      },
    );
  };
};
