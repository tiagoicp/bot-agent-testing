/// HKDF-SHA256 (RFC 5869).
///
/// Implements the two-step HKDF key derivation function using HMAC-SHA256:
///
///   1. `extract(salt, ikm)` → PRK = HMAC-SHA256(salt, ikm)
///   2. `expand(prk, info, length)` → OKM of the requested byte length
///
/// Usage for OpenRouter key derivation:
///   let prk = Hkdf.extract([] (* empty → 32 zero bytes per RFC *), sharedSecretBytes);
///   let aesKey = Hkdf.expand(prk, Text.encodeUtf8("openrouter-key-v1"), 32);
///
/// ⚠️ IKM must be HIGH-ENTROPY keying material (random bytes, ECDH/vetKD
/// output, an established shared secret). HKDF is NOT a password hash —
/// it has no computational cost knob. Never feed it user passwords; use
/// Argon2/scrypt/PBKDF2 for password-derived keys.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Hmac "./hmac";

module {

  /// Extract step: PRK = HMAC-SHA256(salt, IKM).
  ///
  /// Per RFC 5869 §2.2: if `salt` is empty the implementation MUST use
  /// HashLen (32) zero bytes as the salt.
  public func extract(salt : [Nat8], ikm : [Nat8]) : [Nat8] {
    let effectiveSalt : [Nat8] = if (salt.size() == 0) {
      Array.repeat<Nat8>(0x00, 32);
    } else {
      salt;
    };
    Blob.toArray(Hmac.compute(effectiveSalt, ikm));
  };

  /// Expand step: derive `length` bytes of output keying material from PRK.
  ///
  /// Per RFC 5869 §2.3:
  ///   T(0) = ""
  ///   T(i) = HMAC-SHA256(PRK, T(i-1) || info || i)
  ///   OKM  = T(1) || T(2) || … truncated to `length`
  ///
  /// Maximum output length is 255 * 32 = 8160 bytes (RFC 5869 §2.3).
  /// Traps if `length` exceeds this bound to fail-closed rather than
  /// silently wrap the 1-byte counter.
  public func expand(prk : [Nat8], info : [Nat8], length : Nat) : [Nat8] {
    assert (length <= 255 * 32);

    var prevT : [Nat8] = [];
    var okm : [Nat8] = [];
    var counter : Nat = 1;

    while (okm.size() < length) {
      // msg = T(i-1) || info || counter_byte
      let msg = Array.tabulate<Nat8>(
        prevT.size() + info.size() + 1,
        func(j : Nat) : Nat8 {
          if (j < prevT.size()) {
            prevT[j];
          } else if (j < prevT.size() + info.size()) {
            info[j - prevT.size()];
          } else {
            Nat8.fromNat(counter);
          };
        },
      );

      prevT := Blob.toArray(Hmac.compute(prk, msg));
      okm := Array.tabulate<Nat8>(
        okm.size() + prevT.size(),
        func(j : Nat) : Nat8 {
          if (j < okm.size()) okm[j] else prevT[j - okm.size()];
        },
      );
      counter += 1;
    };

    // Truncate to requested length
    if (okm.size() == length) {
      okm;
    } else {
      Array.tabulate<Nat8>(length, func(j : Nat) : Nat8 { okm[j] });
    };
  };

  /// Convenience: one-shot HKDF with empty salt (derives `length` bytes from `ikm`).
  ///
  /// Equivalent to `expand(extract([], ikm), info, length)`.
  public func deriveKey(ikm : [Nat8], info : [Nat8], length : Nat) : [Nat8] {
    expand(extract([], ikm), info, length);
  };
};
