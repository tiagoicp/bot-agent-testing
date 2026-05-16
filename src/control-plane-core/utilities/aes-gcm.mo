/// AES-256-GCM authenticated encryption.
///
/// Implements AES-256 block cipher + GCM mode. Supports encrypt-only
/// (no decryption needed — the core canister only ever encrypts the
/// OpenRouter API key before sending it to the relay Cloudflare Worker).
///
/// Public API:
///   encrypt(key, iv, plaintext, aad) : [Nat8]
///   → returns ciphertext || tag  (tag = last 16 bytes)
///
/// Key: 32 bytes (256-bit)
/// IV:  12 bytes (96-bit) — standard GCM recommended length
/// Tag: 16 bytes (128-bit)
///
/// Follows NIST SP 800-38D.
///
/// ⚠️ SECURITY REQUIREMENTS — caller MUST guarantee:
///   1. **Unique IV per `(key, plaintext)`**: Reusing a `(key, IV)` pair
///      with different plaintexts is catastrophic — it leaks
///      `P1 ⊕ P2` and allows the attacker to recover the GHASH
///      authentication key `H`, enabling arbitrary tag forgery.
///      Use a fresh CSPRNG-derived 12-byte IV per encryption.
///   2. **Key secrecy**: The 32-byte key must come from a secure source
///      (HKDF-derived from an established shared secret, vetKD, etc.).
///   3. **Tag is mandatory**: The caller must transmit the full 16-byte
///      tag with the ciphertext; truncation weakens authentication.
///
/// Side-channel posture: this is a software AES implementation using
/// table lookups (SBOX) and data-dependent branches (`gmul2`, `gfMul`),
/// i.e. not constant-time. On the Internet Computer this is not a
/// practical concern:
///   - The IC scheduler runs canister messages serially per round, so
///     a co-resident adversary canister cannot trigger its own code
///     with the sub-microsecond precision that FLUSH+RELOAD-style
///     cache attacks require.
///   - End-to-end response latency is dominated by network + consensus
///     (~seconds), drowning any microsecond-scale timing signal an
///     external observer could measure.
/// If this module is ever reused outside ICP (e.g. on a shared host
/// where untrusted code can co-reside on the same core), revisit this
/// assumption.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";

module {

  // ============================================
  // AES S-box (FIPS 197 Table 4)
  // ============================================

  let SBOX : [Nat8] = [
    0x63,
    0x7c,
    0x77,
    0x7b,
    0xf2,
    0x6b,
    0x6f,
    0xc5,
    0x30,
    0x01,
    0x67,
    0x2b,
    0xfe,
    0xd7,
    0xab,
    0x76,
    0xca,
    0x82,
    0xc9,
    0x7d,
    0xfa,
    0x59,
    0x47,
    0xf0,
    0xad,
    0xd4,
    0xa2,
    0xaf,
    0x9c,
    0xa4,
    0x72,
    0xc0,
    0xb7,
    0xfd,
    0x93,
    0x26,
    0x36,
    0x3f,
    0xf7,
    0xcc,
    0x34,
    0xa5,
    0xe5,
    0xf1,
    0x71,
    0xd8,
    0x31,
    0x15,
    0x04,
    0xc7,
    0x23,
    0xc3,
    0x18,
    0x96,
    0x05,
    0x9a,
    0x07,
    0x12,
    0x80,
    0xe2,
    0xeb,
    0x27,
    0xb2,
    0x75,
    0x09,
    0x83,
    0x2c,
    0x1a,
    0x1b,
    0x6e,
    0x5a,
    0xa0,
    0x52,
    0x3b,
    0xd6,
    0xb3,
    0x29,
    0xe3,
    0x2f,
    0x84,
    0x53,
    0xd1,
    0x00,
    0xed,
    0x20,
    0xfc,
    0xb1,
    0x5b,
    0x6a,
    0xcb,
    0xbe,
    0x39,
    0x4a,
    0x4c,
    0x58,
    0xcf,
    0xd0,
    0xef,
    0xaa,
    0xfb,
    0x43,
    0x4d,
    0x33,
    0x85,
    0x45,
    0xf9,
    0x02,
    0x7f,
    0x50,
    0x3c,
    0x9f,
    0xa8,
    0x51,
    0xa3,
    0x40,
    0x8f,
    0x92,
    0x9d,
    0x38,
    0xf5,
    0xbc,
    0xb6,
    0xda,
    0x21,
    0x10,
    0xff,
    0xf3,
    0xd2,
    0xcd,
    0x0c,
    0x13,
    0xec,
    0x5f,
    0x97,
    0x44,
    0x17,
    0xc4,
    0xa7,
    0x7e,
    0x3d,
    0x64,
    0x5d,
    0x19,
    0x73,
    0x60,
    0x81,
    0x4f,
    0xdc,
    0x22,
    0x2a,
    0x90,
    0x88,
    0x46,
    0xee,
    0xb8,
    0x14,
    0xde,
    0x5e,
    0x0b,
    0xdb,
    0xe0,
    0x32,
    0x3a,
    0x0a,
    0x49,
    0x06,
    0x24,
    0x5c,
    0xc2,
    0xd3,
    0xac,
    0x62,
    0x91,
    0x95,
    0xe4,
    0x79,
    0xe7,
    0xc8,
    0x37,
    0x6d,
    0x8d,
    0xd5,
    0x4e,
    0xa9,
    0x6c,
    0x56,
    0xf4,
    0xea,
    0x65,
    0x7a,
    0xae,
    0x08,
    0xba,
    0x78,
    0x25,
    0x2e,
    0x1c,
    0xa6,
    0xb4,
    0xc6,
    0xe8,
    0xdd,
    0x74,
    0x1f,
    0x4b,
    0xbd,
    0x8b,
    0x8a,
    0x70,
    0x3e,
    0xb5,
    0x66,
    0x48,
    0x03,
    0xf6,
    0x0e,
    0x61,
    0x35,
    0x57,
    0xb9,
    0x86,
    0xc1,
    0x1d,
    0x9e,
    0xe1,
    0xf8,
    0x98,
    0x11,
    0x69,
    0xd9,
    0x8e,
    0x94,
    0x9b,
    0x1e,
    0x87,
    0xe9,
    0xce,
    0x55,
    0x28,
    0xdf,
    0x8c,
    0xa1,
    0x89,
    0x0d,
    0xbf,
    0xe6,
    0x42,
    0x68,
    0x41,
    0x99,
    0x2d,
    0x0f,
    0xb0,
    0x54,
    0xbb,
    0x16,
  ];

  // RCON values for AES-256 key schedule (index 1..7 used)
  let RCON : [Nat32] = [
    0x00000000, // [0] unused
    0x01000000, // [1] x^0
    0x02000000, // [2] x^1
    0x04000000, // [3] x^2
    0x08000000, // [4] x^3
    0x10000000, // [5] x^4
    0x20000000, // [6] x^5
    0x40000000, // [7] x^6
  ];

  // Powers of 2 for bit extraction
  let POW2 : [Nat] = [1, 2, 4, 8, 16, 32, 64, 128];

  // Powers of 256 for 64-bit big-endian length encoding
  let POW256 : [Nat] = [
    1,
    256,
    65536,
    16777216,
    4294967296,
    1099511627776,
    281474976710656,
    72057594037927936,
  ];

  // GCM reduction polynomial constant: 0xe1 || 0^15
  let GCM_R : [Nat8] = [
    0xe1,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ];

  // ============================================
  // AES key schedule
  // ============================================

  private func subWord(w : Nat32) : Nat32 {
    let b0 = Nat32.toNat(w >> 24);
    let b1 = Nat32.toNat((w >> 16) & 0xff);
    let b2 = Nat32.toNat((w >> 8) & 0xff);
    let b3 = Nat32.toNat(w & 0xff);
    (Nat32.fromNat(Nat8.toNat(SBOX[b0])) << 24) | (Nat32.fromNat(Nat8.toNat(SBOX[b1])) << 16) | (Nat32.fromNat(Nat8.toNat(SBOX[b2])) << 8) | Nat32.fromNat(Nat8.toNat(SBOX[b3]));
  };

  private func rotWord(w : Nat32) : Nat32 {
    (w << 8) | (w >> 24);
  };

  /// Expand a 32-byte (256-bit) key into 60 round-key words.
  private func expandKey(key : [Nat8]) : [Nat32] {
    let w = Array.toVarArray<Nat32>(Array.repeat<Nat32>(0, 60));

    // W[0..7] = key bytes packed as big-endian 32-bit words
    for (i in Nat.range(0, 8)) {
      w[i] := (Nat32.fromNat(Nat8.toNat(key[i * 4])) << 24) | (Nat32.fromNat(Nat8.toNat(key[i * 4 + 1])) << 16) | (Nat32.fromNat(Nat8.toNat(key[i * 4 + 2])) << 8) | Nat32.fromNat(Nat8.toNat(key[i * 4 + 3]));
    };

    // W[8..59] derived via AES-256 key schedule
    for (i in Nat.range(8, 60)) {
      var temp = w[i - 1];
      if (i % 8 == 0) {
        temp := subWord(rotWord(temp)) ^ RCON[i / 8];
      } else if (i % 8 == 4) {
        temp := subWord(temp);
      };
      w[i] := w[i - 8] ^ temp;
    };

    Array.fromVarArray(w);
  };

  // ============================================
  // AES block cipher operations
  // ============================================

  private func subBytes(state : [var Nat8]) {
    for (i in Nat.range(0, 16)) {
      state[i] := SBOX[Nat8.toNat(state[i])];
    };
  };

  private func shiftRows(state : [var Nat8]) {
    // Row 1: positions [1,5,9,13] → rotate left by 1
    let r1 = state[1];
    state[1] := state[5];
    state[5] := state[9];
    state[9] := state[13];
    state[13] := r1;
    // Row 2: positions [2,6,10,14] → rotate left by 2
    let r2a = state[2];
    let r2b = state[6];
    state[2] := state[10];
    state[6] := state[14];
    state[10] := r2a;
    state[14] := r2b;
    // Row 3: positions [3,7,11,15] → rotate left by 3 (= right by 1)
    let r3 = state[15];
    state[15] := state[11];
    state[11] := state[7];
    state[7] := state[3];
    state[3] := r3;
  };

  // Multiply by 0x02 in GF(2^8) with AES polynomial 0x11b
  private func gmul2(b : Nat8) : Nat8 {
    let shifted = Nat8.fromNat((Nat8.toNat(b) * 2) % 256);
    if (b >= 0x80) { shifted ^ 0x1b } else { shifted };
  };

  // Multiply by 0x03 = 0x02 XOR 0x01
  private func gmul3(b : Nat8) : Nat8 { gmul2(b) ^ b };

  private func mixColumns(state : [var Nat8]) {
    for (c in Nat.range(0, 4)) {
      let i = c * 4;
      let a0 = state[i];
      let a1 = state[i + 1];
      let a2 = state[i + 2];
      let a3 = state[i + 3];
      state[i] := gmul2(a0) ^ gmul3(a1) ^ a2 ^ a3;
      state[i + 1] := a0 ^ gmul2(a1) ^ gmul3(a2) ^ a3;
      state[i + 2] := a0 ^ a1 ^ gmul2(a2) ^ gmul3(a3);
      state[i + 3] := gmul3(a0) ^ a1 ^ a2 ^ gmul2(a3);
    };
  };

  private func addRoundKey(state : [var Nat8], roundKeys : [Nat32], round : Nat) {
    for (c in Nat.range(0, 4)) {
      let w = roundKeys[round * 4 + c];
      let base = c * 4;
      state[base] := state[base] ^ Nat8.fromNat(Nat32.toNat(w >> 24) % 256);
      state[base + 1] := state[base + 1] ^ Nat8.fromNat(Nat32.toNat((w >> 16) & 0xff));
      state[base + 2] := state[base + 2] ^ Nat8.fromNat(Nat32.toNat((w >> 8) & 0xff));
      state[base + 3] := state[base + 3] ^ Nat8.fromNat(Nat32.toNat(w & 0xff));
    };
  };

  /// Encrypt a single 16-byte block with the expanded round keys.
  private func aesEncryptBlock(block : [Nat8], roundKeys : [Nat32]) : [Nat8] {
    let state = Array.toVarArray<Nat8>(block);

    addRoundKey(state, roundKeys, 0);

    for (round in Nat.range(1, 14)) {
      subBytes(state);
      shiftRows(state);
      mixColumns(state);
      addRoundKey(state, roundKeys, round);
    };

    // Final round: no MixColumns
    subBytes(state);
    shiftRows(state);
    addRoundKey(state, roundKeys, 14);

    Array.fromVarArray(state);
  };

  // ============================================
  // GCM helpers
  // ============================================

  private func xorBlock(a : [Nat8], b : [Nat8]) : [Nat8] {
    Array.tabulate<Nat8>(16, func(i : Nat) : Nat8 { a[i] ^ b[i] });
  };

  /// Right-shift a 128-bit block by 1 bit (MSB of byte[0] is the leftmost bit).
  private func shrBlock(v : [Nat8]) : [Nat8] {
    let r = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, 16));
    r[0] := Nat8.fromNat(Nat8.toNat(v[0]) / 2);
    for (i in Nat.range(1, 16)) {
      let carry = if (Nat8.toNat(v[i - 1]) % 2 == 1) 128 else 0;
      r[i] := Nat8.fromNat(Nat8.toNat(v[i]) / 2 + carry);
    };
    Array.fromVarArray(r);
  };

  /// Multiply two 128-bit blocks in GF(2^128) using the GCM field
  /// (reduction polynomial x^128 + x^7 + x^2 + x + 1, R = 0xe1||0^15).
  private func gfMul(x : [Nat8], y : [Nat8]) : [Nat8] {
    var z : [Nat8] = Array.repeat<Nat8>(0, 16);
    var v : [Nat8] = y;

    for (byteIdx in Nat.range(0, 16)) {
      for (bitPos in Nat.range(0, 8)) {
        // Scan MSB-first: bitShift = 7 (MSB) down to 0 (LSB).
        // Safe by construction (bitPos in [0,7]); use Int to avoid
        // the Nat-subtraction trap warning.
        let bitShift = Int.abs((7 : Int) - bitPos);
        let bit = Nat8.toNat(x[byteIdx]) / POW2[bitShift] % 2;

        if (bit != 0) { z := xorBlock(z, v) };

        let lsb = Nat8.toNat(v[15]) % 2;
        v := shrBlock(v);
        if (lsb != 0) { v := xorBlock(v, GCM_R) };
      };
    };

    z;
  };

  /// Encode `nBytes` × 8 as an 8-byte big-endian integer (used for GHASH length block).
  private func toBE64Bits(nBytes : Nat) : [Nat8] {
    let bits = nBytes * 8;
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        Nat8.fromNat((bits / POW256[7 - i]) % 256);
      },
    );
  };

  /// Pad a byte array to a multiple of 16 bytes (zero-padding).
  private func padTo16(data : [Nat8]) : [Nat8] {
    let len = data.size();
    let padded = (len + 15) / 16 * 16;
    if (padded == len) data else Array.tabulate<Nat8>(
      padded,
      func(i : Nat) : Nat8 {
        if (i < len) data[i] else 0x00;
      },
    );
  };

  /// Compute GHASH_H(AAD, ciphertext) per NIST SP 800-38D §6.4.
  private func ghash(h : [Nat8], aad : [Nat8], ciphertext : [Nat8]) : [Nat8] {
    var x : [Nat8] = Array.repeat<Nat8>(0, 16);

    // Process AAD blocks
    if (aad.size() > 0) {
      let aadPadded = padTo16(aad);
      var i = 0;
      while (i < aadPadded.size()) {
        let block = Array.tabulate<Nat8>(16, func(j : Nat) : Nat8 { aadPadded[i + j] });
        x := gfMul(xorBlock(x, block), h);
        i += 16;
      };
    };

    // Process ciphertext blocks
    if (ciphertext.size() > 0) {
      let ctPadded = padTo16(ciphertext);
      var i = 0;
      while (i < ctPadded.size()) {
        let block = Array.tabulate<Nat8>(16, func(j : Nat) : Nat8 { ctPadded[i + j] });
        x := gfMul(xorBlock(x, block), h);
        i += 16;
      };
    };

    // Length block: len(AAD) || len(CT) each as 64-bit big-endian bit-counts
    let lenBlock = Array.tabulate<Nat8>(
      16,
      func(i : Nat) : Nat8 {
        if (i < 8) toBE64Bits(aad.size())[i] else toBE64Bits(ciphertext.size())[i - 8];
      },
    );

    gfMul(xorBlock(x, lenBlock), h);
  };

  /// Increment the 32-bit big-endian counter in bytes 12–15 of a block.
  private func inc32(block : [Nat8]) : [Nat8] {
    let r = Array.toVarArray<Nat8>(block);
    var carry = 1;
    var i = 15;
    label incLoop while (carry > 0) {
      let sum = Nat8.toNat(r[i]) + carry;
      r[i] := Nat8.fromNat(sum % 256);
      carry := sum / 256;
      if (i == 12) { carry := 0 } else { i -= 1 };
    };
    Array.fromVarArray(r);
  };

  /// GCTR: AES counter-mode encryption (NIST SP 800-38D §6.5).
  private func gctr(roundKeys : [Nat32], icb : [Nat8], plaintext : [Nat8]) : [Nat8] {
    let n = plaintext.size();
    if (n == 0) return [];

    let output = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, n));
    var cb = icb;
    var offset = 0;

    while (offset < n) {
      let keyStream = aesEncryptBlock(cb, roundKeys);
      let blockEnd = if (offset + 16 > n) n else offset + 16;

      for (j in Nat.range(offset, blockEnd)) {
        output[j] := plaintext[j] ^ keyStream[j - offset];
      };

      cb := inc32(cb);
      offset += 16;
    };

    Array.fromVarArray(output);
  };

  // ============================================
  // Public API
  // ============================================

  /// Encrypt `plaintext` with AES-256-GCM.
  ///
  /// - `key` must be exactly 32 bytes (256-bit).
  /// - `iv`  must be exactly 12 bytes (96-bit GCM standard nonce).
  /// - `aad` is additional authenticated data (may be empty).
  ///
  /// Traps on invalid key/iv length to fail-closed rather than silently
  /// produce non-interoperable output (e.g. an oversized IV would
  /// require GHASH-based J0 derivation per NIST SP 800-38D §7.1).
  ///
  /// Returns `ciphertext || tag` where `tag` is the last 16 bytes.
  public func encrypt(
    key : [Nat8],
    iv : [Nat8],
    plaintext : [Nat8],
    aad : [Nat8],
  ) : [Nat8] {
    assert (key.size() == 32);
    assert (iv.size() == 12);

    let roundKeys = expandKey(key);

    // H = AES_K(0^128)
    let h = aesEncryptBlock(Array.repeat<Nat8>(0, 16), roundKeys);

    // J0 = IV || 0x00000001  (standard for 96-bit IV)
    let j0 = Array.tabulate<Nat8>(
      16,
      func(i : Nat) : Nat8 {
        if (i < 12) iv[i] else if (i < 15) 0x00 else 0x01;
      },
    );

    // Encrypt: C = GCTR(K, inc32(J0), P)
    let ciphertext = gctr(roundKeys, inc32(j0), plaintext);

    // Tag: T = GHASH_H(A, C) XOR AES_K(J0)
    let s = aesEncryptBlock(j0, roundKeys);
    let tag = xorBlock(ghash(h, aad, ciphertext), s);

    // Return ciphertext || tag
    Array.tabulate<Nat8>(
      ciphertext.size() + 16,
      func(i : Nat) : Nat8 {
        if (i < ciphertext.size()) ciphertext[i] else tag[i - ciphertext.size()];
      },
    );
  };
};
