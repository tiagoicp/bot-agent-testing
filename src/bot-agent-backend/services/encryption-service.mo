import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Text "mo:base/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Sha256 "mo:sha2/Sha256";

/// SHA256-based Stream Cipher
///
/// This module provides encryption using:
/// - SHA256-based keystream generation (similar to CTR mode)
///
/// Encrypted format: [nonce (8 bytes)] [ciphertext (variable)]
module {

  // Constants
  let NONCE_SIZE : Nat = 8;

  /// Generate unique 8-byte nonce from caller principal hash + timestamp
  public func generateNonce(caller : Principal) : [Nat8] {
    let time = Int.abs(Time.now());
    let principalHash = Principal.hash(caller);
    let combined = Nat32.toNat(principalHash) + time;
    // Convert to 8 bytes (big-endian)
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        let shift = Nat.sub(7, i) * 8;
        Nat8.fromNat((combined / Nat.pow(256, shift)) % 256);
      },
    );
  };
  let _BLOCK_SIZE : Nat = 32; // SHA256 output size (kept for documentation)

  /// Convert Nat64 to big-endian byte array (8 bytes)
  public func nat64ToBytes(n : Nat64) : [Nat8] {
    [
      Nat8.fromNat(Nat64.toNat((n >> 56) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 48) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 40) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 32) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 24) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 16) & 0xFF)),
      Nat8.fromNat(Nat64.toNat((n >> 8) & 0xFF)),
      Nat8.fromNat(Nat64.toNat(n & 0xFF)),
    ];
  };

  /// XOR two byte arrays of equal length
  public func xorBytes(a : [Nat8], b : [Nat8]) : [Nat8] {
    Array.tabulate<Nat8>(
      a.size(),
      func(i : Nat) : Nat8 {
        a[i] ^ b[i];
      },
    );
  };

  /// Compare two byte arrays for equality (constant-time for security)
  public func arrayEqual(a : [Nat8], b : [Nat8]) : Bool {
    if (a.size() != b.size()) {
      return false;
    };

    var result : Nat8 = 0;
    for (i in Iter.range(0, a.size() - 1)) {
      result := result | (a[i] ^ b[i]);
    };

    result == 0;
  };

  /// Generate a single keystream block using SHA256
  /// keystream_block = SHA256(key ++ nonce ++ counter)
  public func generateKeystreamBlock(key : [Nat8], nonce : [Nat8], counter : Nat64) : [Nat8] {
    let counterBytes = nat64ToBytes(counter);

    // Concatenate: key ++ nonce ++ counter
    let inputSize = key.size() + nonce.size() + counterBytes.size();
    let input = Buffer.Buffer<Nat8>(inputSize);

    for (byte in key.vals()) { input.add(byte) };
    for (byte in nonce.vals()) { input.add(byte) };
    for (byte in counterBytes.vals()) { input.add(byte) };

    // Hash and return as [Nat8]
    let hashBlob = Sha256.fromArray(#sha256, Buffer.toArray(input));
    Blob.toArray(hashBlob);
  };

  /// Generate keystream of required length
  public func generateKeystream(key : [Nat8], nonce : [Nat8], length : Nat) : [Nat8] {
    if (length == 0) {
      return [];
    };

    let keystream = Buffer.Buffer<Nat8>(length);
    var counter : Nat64 = 0;

    while (keystream.size() < length) {
      let block = generateKeystreamBlock(key, nonce, counter);
      for (byte in block.vals()) {
        if (keystream.size() < length) {
          keystream.add(byte);
        };
      };
      counter += 1;
    };

    Buffer.toArray(keystream);
  };

  /// Encrypt plaintext
  ///
  /// Parameters:
  /// - key: 32-byte encryption key (from Schnorr signature hash)
  /// - plaintext: data to encrypt
  /// - caller: Principal used to generate unique nonce
  ///
  /// Returns: [nonce (8 bytes)] [ciphertext]
  public func encrypt(key : [Nat8], plaintext : [Nat8], caller : Principal) : [Nat8] {
    // Generate unique nonce from caller + timestamp
    let nonce = generateNonce(caller);

    // Generate keystream and encrypt
    let keystream = generateKeystream(key, nonce, plaintext.size());
    let ciphertext = if (plaintext.size() == 0) {
      [];
    } else {
      xorBytes(plaintext, keystream);
    };

    // Concatenate: nonce ++ ciphertext
    let outputSize = NONCE_SIZE + ciphertext.size();
    let output = Buffer.Buffer<Nat8>(outputSize);

    for (byte in nonce.vals()) { output.add(byte) };
    for (byte in ciphertext.vals()) { output.add(byte) };

    Buffer.toArray(output);
  };

  /// Decrypt ciphertext
  ///
  /// Parameters:
  /// - key: 32-byte encryption key (same key used for encryption)
  /// - encrypted: [nonce (8 bytes)] [ciphertext]
  ///
  /// Returns: ?plaintext (null if data is too short)
  public func decrypt(key : [Nat8], encrypted : [Nat8]) : ?[Nat8] {
    let minSize = NONCE_SIZE;

    // Validate minimum size
    if (encrypted.size() < minSize) {
      return null;
    };

    // Extract components
    let nonce = Array.tabulate<Nat8>(NONCE_SIZE, func(i : Nat) : Nat8 { encrypted[i] });
    let ciphertextSize : Nat = Nat.sub(encrypted.size(), minSize);
    let ciphertext = Array.tabulate<Nat8>(ciphertextSize, func(i : Nat) : Nat8 { encrypted[minSize + i] });

    // Decrypt
    if (ciphertextSize == 0) {
      return ?[];
    };

    let keystream = generateKeystream(key, nonce, ciphertextSize);
    ?xorBytes(ciphertext, keystream);
  };

  /// Convert Text to [Nat8] (UTF-8 encoding)
  public func textToBytes(text : Text) : [Nat8] {
    Blob.toArray(Text.encodeUtf8(text));
  };

  /// Convert [Nat8] to Text (UTF-8 decoding)
  public func bytesToText(bytes : [Nat8]) : ?Text {
    Text.decodeUtf8(Blob.fromArray(bytes));
  };

};
