import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import List "mo:core/List";
import Text "mo:core/Text";
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
  func generateNonce(caller : Principal) : [Nat8] {
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

  /// Convert Nat64 to big-endian byte array (8 bytes)
  func nat64ToBytes(n : Nat64) : [Nat8] {
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
  func xorBytes(a : [Nat8], b : [Nat8]) : [Nat8] {
    Array.tabulate<Nat8>(
      a.size(),
      func(i : Nat) : Nat8 {
        a[i] ^ b[i];
      },
    );
  };

  /// Generate a single keystream block using SHA256
  /// keystream_block = SHA256(key ++ nonce ++ counter)
  func generateKeystreamBlock(key : [Nat8], nonce : [Nat8], counter : Nat64) : [Nat8] {
    let counterBytes = nat64ToBytes(counter);

    // Concatenate: key ++ nonce ++ counter
    let input = List.empty<Nat8>();

    for (byte in key.vals()) { List.add(input, byte) };
    for (byte in nonce.vals()) { List.add(input, byte) };
    for (byte in counterBytes.vals()) { List.add(input, byte) };

    // Hash and return as [Nat8]
    let hashBlob = Sha256.fromArray(#sha256, List.toArray(input));
    Blob.toArray(hashBlob);
  };

  /// Generate keystream of required length
  func generateKeystream(key : [Nat8], nonce : [Nat8], length : Nat) : [Nat8] {
    if (length == 0) {
      return [];
    };

    let keystream = List.empty<Nat8>();
    var counter : Nat64 = 0;

    while (List.size(keystream) < length) {
      let block = generateKeystreamBlock(key, nonce, counter);
      for (byte in block.vals()) {
        if (List.size(keystream) < length) {
          List.add(keystream, byte);
        };
      };
      counter += 1;
    };

    List.toArray(keystream);
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
    assert key.size() == 32;

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
    let output = List.empty<Nat8>();

    for (byte in nonce.vals()) { List.add(output, byte) };
    for (byte in ciphertext.vals()) { List.add(output, byte) };

    List.toArray(output);
  };

  /// Decrypt ciphertext
  ///
  /// Parameters:
  /// - key: 32-byte encryption key (same key used for encryption)
  /// - encrypted: [nonce (8 bytes)] [ciphertext]
  ///
  /// Returns: plaintext
  public func decrypt(key : [Nat8], encrypted : [Nat8]) : [Nat8] {
    // Validate key size
    assert key.size() == 32;

    // Validate minimum size
    let minSize = NONCE_SIZE;
    assert encrypted.size() >= minSize;

    // Extract components
    let nonce = Array.tabulate<Nat8>(NONCE_SIZE, func(i : Nat) : Nat8 { encrypted[i] });
    let ciphertextSize : Nat = Nat.sub(encrypted.size(), minSize);
    let ciphertext = Array.tabulate<Nat8>(ciphertextSize, func(i : Nat) : Nat8 { encrypted[minSize + i] });

    // Decrypt
    if (ciphertextSize == 0) {
      return [];
    };

    let keystream = generateKeystream(key, nonce, ciphertextSize);
    xorBytes(ciphertext, keystream);
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
