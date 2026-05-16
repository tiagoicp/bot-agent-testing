/// Standard Base64 codec (RFC 4648).
///
/// Provides both encoding and strict decoding (no whitespace tolerance).
/// Uses the standard alphabet (A-Z a-z 0-9 + /) with `=` padding.
///
/// Extracted from `http-certification.mo` so that relay and other modules
/// can encode/decode without pulling in the full certification dependency tree.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

module {

  // ============================================
  // Constants
  // ============================================

  let ALPHABET : [Char] = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '+',
    '/',
  ];

  // Reverse lookup table: ASCII code → base64 value (255 = invalid).
  // Indexed by ASCII code 0..127; codes >= 128 are rejected before lookup.
  let DECODE_TABLE : [Nat8] = [
    // 0-47
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    62,
    255,
    255,
    255,
    63,
    // 48-63: '0'-'9' → 52-61, rest invalid
    52,
    53,
    54,
    55,
    56,
    57,
    58,
    59,
    60,
    61,
    255,
    255,
    255,
    255,
    255,
    255,
    // 64-79: '@' invalid, 'A'-'O' → 0-14
    255,
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    // 80-95: 'P'-'Z' → 15-25, rest invalid
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    255,
    255,
    255,
    255,
    255,
    // 96-111: '`' invalid, 'a'-'o' → 26-40
    255,
    26,
    27,
    28,
    29,
    30,
    31,
    32,
    33,
    34,
    35,
    36,
    37,
    38,
    39,
    40,
    // 112-127: 'p'-'z' → 41-51, rest invalid
    41,
    42,
    43,
    44,
    45,
    46,
    47,
    48,
    49,
    50,
    51,
    255,
    255,
    255,
    255,
    255,
  ];

  // ============================================
  // Encoding
  // ============================================

  /// Encode a byte array as standard Base64 with `=` padding.
  public func encode(bytes : [Nat8]) : Text {
    let len = bytes.size();
    if (len == 0) return "";

    let outputLen = ((len + 2) / 3) * 4;

    let chars = Array.tabulate<Char>(
      outputLen,
      func(ci : Nat) : Char {
        let group = ci / 4;
        let pos = ci % 4;
        let bi = group * 3;

        if (pos == 2 and bi + 1 >= len) return '=';
        if (pos == 3 and bi + 2 >= len) return '=';

        let b0 = Nat8.toNat(bytes[bi]);
        let b1 = if (bi + 1 < len) Nat8.toNat(bytes[bi + 1]) else 0;
        let b2 = if (bi + 2 < len) Nat8.toNat(bytes[bi + 2]) else 0;

        let index = switch pos {
          case 0 { b0 / 4 };
          case 1 { (b0 % 4) * 16 + b1 / 16 };
          case 2 { (b1 % 16) * 4 + b2 / 64 };
          case _ { b2 % 64 };
        };

        ALPHABET[index];
      },
    );

    Text.fromIter(chars.vals());
  };

  /// Convenience wrapper: encode a `Blob` as standard Base64.
  public func encodeBlob(data : Blob) : Text {
    encode(Blob.toArray(data));
  };

  // ============================================
  // Decoding
  // ============================================

  /// Decode a standard Base64 string.
  ///
  /// Returns `null` if the input contains characters outside the Base64 alphabet
  /// (other than the trailing `=` pad characters) or if the length is invalid.
  public func decode(text : Text) : ?[Nat8] {
    let chars = Iter.toArray(text.chars());
    let len = chars.size();

    if (len == 0) return ?[];
    if (len % 4 != 0) return null;

    // Count trailing padding characters
    var padCount = 0;
    if (len >= 1 and chars[len - 1] == '=') padCount += 1;
    if (len >= 2 and chars[len - 2] == '=') padCount += 1;
    if (padCount > 2) return null;

    // Safe by construction: len % 4 == 0 and padCount <= 2,
    // so (len/4)*3 >= 3 > padCount when len > 0.
    let outputLen = Int.abs(((len / 4) * 3 : Int) - padCount);
    let output = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, outputLen));
    var outIdx = 0;

    var i = 0;
    while (i < len) {
      // Decode 4 characters → 3 bytes
      let v0 = decodeChar(chars[i]);
      let v1 = decodeChar(chars[i + 1]);
      let v2 = if (i + 2 < len and chars[i + 2] != '=') decodeChar(chars[i + 2]) else ?0;
      let v3 = if (i + 3 < len and chars[i + 3] != '=') decodeChar(chars[i + 3]) else ?0;

      switch (v0, v1, v2, v3) {
        case (?a, ?b, ?c, ?d) {
          // byte 0: top 6 bits of a + top 2 bits of b
          if (outIdx < outputLen) {
            output[outIdx] := Nat8.fromNat((a * 4 + b / 16) % 256);
            outIdx += 1;
          };
          // byte 1: bottom 4 bits of b + top 4 bits of c
          if (outIdx < outputLen) {
            output[outIdx] := Nat8.fromNat(((b % 16) * 16 + c / 4) % 256);
            outIdx += 1;
          };
          // byte 2: bottom 2 bits of c + all 6 bits of d
          if (outIdx < outputLen) {
            output[outIdx] := Nat8.fromNat(((c % 4) * 64 + d) % 256);
            outIdx += 1;
          };
        };
        case _ { return null };
      };

      i += 4;
    };

    ?Array.fromVarArray(output);
  };

  /// Decode a Base64 `Text` and wrap in a `Blob`. Returns `null` on error.
  public func decodeBlob(text : Text) : ?Blob {
    switch (decode(text)) {
      case (?bytes) { ?Blob.fromArray(bytes) };
      case (null) { null };
    };
  };

  // ============================================
  // Internal helpers
  // ============================================

  private func decodeChar(c : Char) : ?Nat {
    let code = Nat32.toNat(Char.toNat32(c));
    if (code >= 128) return null;
    let v = Nat8.toNat(DECODE_TABLE[code]);
    if (v == 255) null else ?v;
  };
};
