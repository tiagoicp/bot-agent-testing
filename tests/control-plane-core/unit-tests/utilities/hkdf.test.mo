import { test; suite; expect } "mo:test";
import Hkdf "../../../../src/control-plane-core/utilities/hkdf";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

// Hex comparison helper
func toHex(bytes : [Nat8]) : Text {
  var hex = "";
  for (b in bytes.vals()) {
    let hi = Nat8.toNat(b) / 16;
    let lo = Nat8.toNat(b) % 16;
    let chars = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    hex #= chars[hi] # chars[lo];
  };
  hex;
};

suite(
  "HKDF-SHA256",
  func() {

    suite(
      "extract",
      func() {

        // RFC 5869 Appendix A - Test Case 1
        test(
          "RFC 5869 Test Case 1: extract step",
          func() {
            // Salt = 0x000102030405060708090a0b0c (13 bytes)
            let salt : [Nat8] = [
              0x00,
              0x01,
              0x02,
              0x03,
              0x04,
              0x05,
              0x06,
              0x07,
              0x08,
              0x09,
              0x0a,
              0x0b,
              0x0c,
            ];
            // IKM = 0x0b repeated 22 bytes
            let ikm = Array.repeat<Nat8>(0x0b, 22);

            let prk = Hkdf.extract(salt, ikm);

            // Expected PRK from RFC 5869 §A.1:
            // 077709362c2e32df0ddc3f0dc47bba63 90b6c73bb50f9c3122ec844ad7c2b3e5
            expect.text(toHex(prk)).equal(
              "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
            );
          },
        );

        // RFC 5869 Test Case 2: empty salt → treated as 32 zero bytes
        test(
          "RFC 5869 Test Case 2: empty salt uses 32 zero bytes",
          func() {
            // IKM = 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b (22 bytes)
            let ikm = Array.repeat<Nat8>(0x0b, 22);
            let prk = Hkdf.extract([], ikm);

            // Expected PRK for HMAC-SHA256(0^32, 0x0b*22):
            // 19ef24a32c717b167f33a91d6f648bdf
            // 96596776afdb6377ac434c1c293ccb04
            expect.text(toHex(prk)).equal(
              "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
            );
          },
        );

      },
    );

    suite(
      "expand",
      func() {

        // RFC 5869 Appendix A - Test Case 1, expand step
        test(
          "RFC 5869 Test Case 1: expand 42 bytes",
          func() {
            // PRK from test case 1 extract step
            let prk : [Nat8] = [
              0x07,
              0x77,
              0x09,
              0x36,
              0x2c,
              0x2e,
              0x32,
              0xdf,
              0x0d,
              0xdc,
              0x3f,
              0x0d,
              0xc4,
              0x7b,
              0xba,
              0x63,
              0x90,
              0xb6,
              0xc7,
              0x3b,
              0xb5,
              0x0f,
              0x9c,
              0x31,
              0x22,
              0xec,
              0x84,
              0x4a,
              0xd7,
              0xc2,
              0xb3,
              0xe5,
            ];
            // Info = 0xf0f1f2f3f4f5f6f7f8f9 (10 bytes)
            let info : [Nat8] = [0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9];

            let okm = Hkdf.expand(prk, info, 42);

            expect.nat(okm.size()).equal(42);
            // Expected OKM from RFC 5869 §A.1:
            // 3cb25f25faacd57a90434f64d0362f2a 2d2d0a90cf1a5a4c5db02d56ecc4c5bf
            // 34007208d5b887185865
            expect.text(toHex(okm)).equal(
              "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
            );
          },
        );

        // Exact 32-byte output = one HMAC block, no concatenation
        test(
          "expand exactly 32 bytes (one T block)",
          func() {
            let prk : [Nat8] = [
              0x07,
              0x77,
              0x09,
              0x36,
              0x2c,
              0x2e,
              0x32,
              0xdf,
              0x0d,
              0xdc,
              0x3f,
              0x0d,
              0xc4,
              0x7b,
              0xba,
              0x63,
              0x90,
              0xb6,
              0xc7,
              0x3b,
              0xb5,
              0x0f,
              0x9c,
              0x31,
              0x22,
              0xec,
              0x84,
              0x4a,
              0xd7,
              0xc2,
              0xb3,
              0xe5,
            ];
            let info : [Nat8] = [0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9];

            let okm = Hkdf.expand(prk, info, 32);
            expect.nat(okm.size()).equal(32);
            // First 32 bytes of the 42-byte OKM above
            expect.text(toHex(okm)).equal(
              "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
            );
          },
        );

      },
    );

    suite(
      "deriveKey",
      func() {

        // Verify the openrouter-key-v1 derivation path used by the relay worker
        test(
          "deriveKey with 'openrouter-key-v1' info produces 32 bytes",
          func() {
            // Simulate a 32-byte shared secret (all-zero for a deterministic test)
            let sharedSecret = Array.repeat<Nat8>(0x00, 32);
            let info : [Nat8] = [
              // "openrouter-key-v1" as UTF-8
              0x6f,
              0x70,
              0x65,
              0x6e,
              0x72,
              0x6f,
              0x75,
              0x74,
              0x65,
              0x72,
              0x2d,
              0x6b,
              0x65,
              0x79,
              0x2d,
              0x76,
              0x31,
            ];

            let aesKey = Hkdf.deriveKey(sharedSecret, info, 32);
            expect.nat(aesKey.size()).equal(32);
          },
        );

        // RFC 5869 Test Case 3 (§A.3): empty salt AND empty info.
        // Pins both `deriveKey`'s default-salt path AND `expand`'s
        // empty-info concatenation path against a published vector.
        test(
          "RFC 5869 Test Case 3: empty salt and empty info, 42-byte OKM",
          func() {
            // IKM = 0x0b * 22
            let ikm = Array.repeat<Nat8>(0x0b, 22);
            let okm = Hkdf.deriveKey(ikm, [], 42);

            // Expected OKM from RFC 5869 §A.3:
            // 8da4e775a563c18f715f802a063c5a31 b8a11f5c5ee1879ec3454e5f3c738d2d
            // 9d201395faa4b61a96c8
            expect.nat(okm.size()).equal(42);
            expect.text(toHex(okm)).equal(
              "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
            );
          },
        );

      },
    );

    suite(
      "edge cases",
      func() {

        // length = 0: must return empty output without calling HMAC at all.
        test(
          "expand length = 0 returns empty array",
          func() {
            let prk = Array.repeat<Nat8>(0xaa, 32);
            let okm = Hkdf.expand(prk, [0x01, 0x02], 0);
            expect.nat(okm.size()).equal(0);
          },
        );

        // Lengths spanning block boundaries (1, 32, 33, 64, 65) exercise
        // truncation and the boundary at each multiple of HashLen.
        test(
          "expand produces correct lengths across HashLen boundaries",
          func() {
            let prk = Array.repeat<Nat8>(0x42, 32);
            let info : [Nat8] = [0xab, 0xcd];
            for (n in [1, 32, 33, 64, 65].vals()) {
              let okm = Hkdf.expand(prk, info, n);
              expect.nat(okm.size()).equal(n);
            };
          },
        );

      },
    );

  },
);
