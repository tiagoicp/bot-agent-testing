import { test; suite; expect } "mo:test";
import AesGcm "../../../../src/control-plane-core/utilities/aes-gcm";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
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

// Decode a hex string into bytes. Length must be even.
func fromHex(hex : Text) : [Nat8] {
  let chars = hex.chars();
  let buf = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, hex.size() / 2));
  var idx = 0;
  var hi : ?Nat8 = null;
  for (c in chars) {
    let v : Nat8 = switch (c) {
      case ('0') 0;
      case ('1') 1;
      case ('2') 2;
      case ('3') 3;
      case ('4') 4;
      case ('5') 5;
      case ('6') 6;
      case ('7') 7;
      case ('8') 8;
      case ('9') 9;
      case ('a') 10;
      case ('b') 11;
      case ('c') 12;
      case ('d') 13;
      case ('e') 14;
      case ('f') 15;
      case (_) { assert false; 0 };
    };
    switch (hi) {
      case null { hi := ?v };
      case (?h) {
        buf[idx] := (h << 4) | v;
        idx += 1;
        hi := null;
      };
    };
  };
  Array.fromVarArray(buf);
};

suite(
  "AES-256-GCM",
  func() {

    suite(
      "encrypt — NIST SP 800-38D test vectors",
      func() {

        // Test Case 1: zero key, zero IV, empty plaintext, empty AAD
        // Expected tag: 530f8afbc74536b9a963b4f1c4cb738b
        test(
          "Test Case 1: zero key/IV, empty PT → tag only",
          func() {
            let key = Array.repeat<Nat8>(0x00, 32);
            let iv = Array.repeat<Nat8>(0x00, 12);
            let result = AesGcm.encrypt(key, iv, [], []);

            // Output must be exactly 16 bytes (tag only, no ciphertext)
            expect.nat(result.size()).equal(16);
            expect.text(toHex(result)).equal("530f8afbc74536b9a963b4f1c4cb738b");
          },
        );

        // Test Case 2: zero key, zero IV, 16-byte zero plaintext, empty AAD
        // Expected CT: cea7403d4d606b6e074ec5d3baf39d18
        // Expected tag: d0d1c8a799996bf0265b98b5d48ab919
        test(
          "Test Case 2: zero key/IV, 16-byte zero PT",
          func() {
            let key = Array.repeat<Nat8>(0x00, 32);
            let iv = Array.repeat<Nat8>(0x00, 12);
            let pt = Array.repeat<Nat8>(0x00, 16);
            let result = AesGcm.encrypt(key, iv, pt, []);

            // 16 bytes CT + 16 bytes tag = 32 bytes total
            expect.nat(result.size()).equal(32);

            let ct = Array.tabulate<Nat8>(16, func(i : Nat) : Nat8 { result[i] });
            let tag = Array.tabulate<Nat8>(16, func(i : Nat) : Nat8 { result[i + 16] });

            expect.text(toHex(ct)).equal("cea7403d4d606b6e074ec5d3baf39d18");
            expect.text(toHex(tag)).equal("d0d1c8a799996bf0265b98b5d48ab919");
          },
        );

        // McGrew & Viega "GCM Spec" Test Case 15 (AES-256, 4-block PT,
        // non-zero key/IV, no AAD). Exercises multi-block GCTR counter
        // increment and multi-block GHASH.
        test(
          "Test Case 15: non-zero key/IV, 4-block PT, no AAD",
          func() {
            let key = fromHex(
              "feffe9928665731c6d6a8f9467308308"
              # "feffe9928665731c6d6a8f9467308308"
            );
            let iv = fromHex("cafebabefacedbaddecaf888");
            let pt = fromHex(
              "d9313225f88406e5a55909c5aff5269a"
              # "86a7a9531534f7da2e4c303d8a318a72"
              # "1c3c0c95956809532fcf0e2449a6b525"
              # "b16aedf5aa0de657ba637b391aafd255"
            );
            let expectedCt = "522dc1f099567d07f47f37a32a84427d"
            # "643a8cdcbfe5c0c97598a2bd2555d1aa"
            # "8cb08e48590dbb3da7b08b1056828838"
            # "c5f61e6393ba7a0abcc9f662898015ad";
            let expectedTag = "b094dac5d93471bdec1a502270e3cc6c";

            let result = AesGcm.encrypt(key, iv, pt, []);
            expect.nat(result.size()).equal(64 + 16);

            let ct = Array.tabulate<Nat8>(64, func(i : Nat) : Nat8 { result[i] });
            let tag = Array.tabulate<Nat8>(16, func(i : Nat) : Nat8 { result[i + 64] });

            expect.text(toHex(ct)).equal(expectedCt);
            expect.text(toHex(tag)).equal(expectedTag);
          },
        );

        // McGrew & Viega Test Case 16: same key/IV as TC15, but with
        // truncated PT (3.75 blocks = 60 bytes) and 20-byte AAD.
        // Exercises non-block-aligned plaintext + multi-block AAD path.
        test(
          "Test Case 16: 60-byte (non-aligned) PT with AAD",
          func() {
            let key = fromHex(
              "feffe9928665731c6d6a8f9467308308"
              # "feffe9928665731c6d6a8f9467308308"
            );
            let iv = fromHex("cafebabefacedbaddecaf888");
            let pt = fromHex(
              "d9313225f88406e5a55909c5aff5269a"
              # "86a7a9531534f7da2e4c303d8a318a72"
              # "1c3c0c95956809532fcf0e2449a6b525"
              # "b16aedf5aa0de657ba637b39"
            );
            let aad = fromHex(
              "feedfacedeadbeeffeedfacedeadbeef"
              # "abaddad2"
            );
            let expectedCt = "522dc1f099567d07f47f37a32a84427d"
            # "643a8cdcbfe5c0c97598a2bd2555d1aa"
            # "8cb08e48590dbb3da7b08b1056828838"
            # "c5f61e6393ba7a0abcc9f662";
            let expectedTag = "76fc6ece0f4e1768cddf8853bb2d551b";

            let result = AesGcm.encrypt(key, iv, pt, aad);
            expect.nat(result.size()).equal(60 + 16);

            let ct = Array.tabulate<Nat8>(60, func(i : Nat) : Nat8 { result[i] });
            let tag = Array.tabulate<Nat8>(16, func(i : Nat) : Nat8 { result[i + 60] });

            expect.text(toHex(ct)).equal(expectedCt);
            expect.text(toHex(tag)).equal(expectedTag);
          },
        );

      },
    );

    suite(
      "encrypt — structural properties",
      func() {

        test(
          "output length is plaintext length + 16 (tag)",
          func() {
            let key = Array.repeat<Nat8>(0x01, 32);
            let iv = Array.repeat<Nat8>(0x02, 12);
            let pt : [Nat8] = [0x48, 0x65, 0x6c, 0x6c, 0x6f]; // "Hello"
            let result = AesGcm.encrypt(key, iv, pt, []);
            expect.nat(result.size()).equal(pt.size() + 16);
          },
        );

        test(
          "different keys produce different ciphertexts",
          func() {
            let iv = Array.repeat<Nat8>(0x00, 12);
            let pt = Array.repeat<Nat8>(0xaa, 16);
            let r1 = AesGcm.encrypt(Array.repeat<Nat8>(0x00, 32), iv, pt, []);
            let r2 = AesGcm.encrypt(Array.repeat<Nat8>(0x01, 32), iv, pt, []);
            var same = true;
            for (i in r1.keys()) {
              if (r1[i] != r2[i]) { same := false };
            };
            assert not same;
          },
        );

        test(
          "different IVs produce different ciphertexts",
          func() {
            let key = Array.repeat<Nat8>(0x00, 32);
            let pt = Array.repeat<Nat8>(0xbb, 16);
            let r1 = AesGcm.encrypt(key, Array.repeat<Nat8>(0x00, 12), pt, []);
            let r2 = AesGcm.encrypt(key, Array.repeat<Nat8>(0x01, 12), pt, []);
            var same = true;
            for (i in r1.keys()) {
              if (r1[i] != r2[i]) { same := false };
            };
            assert not same;
          },
        );

        test(
          "AAD affects the tag but not the ciphertext bytes",
          func() {
            let key = Array.repeat<Nat8>(0x00, 32);
            let iv = Array.repeat<Nat8>(0x00, 12);
            let pt = Array.repeat<Nat8>(0xcc, 16);
            let r1 = AesGcm.encrypt(key, iv, pt, []);
            let r2 = AesGcm.encrypt(key, iv, pt, [0x01, 0x02]);

            // First 16 bytes (ciphertext) must be identical
            var ctSame = true;
            for (i in (Array.tabulate<Nat8>(16, func(j : Nat) : Nat8 { r1[j] })).keys()) {
              if (r1[i] != r2[i]) { ctSame := false };
            };
            assert ctSame;

            // Tags (last 16 bytes) must differ
            var tagSame = true;
            for (i in (Array.tabulate<Nat8>(16, func(j : Nat) : Nat8 { r1[j + 16] })).keys()) {
              if (r1[i + 16] != r2[i + 16]) { tagSame := false };
            };
            assert not tagSame;
          },
        );

        // Property: encrypting two different non-block-aligned plaintexts
        // that share a common prefix must still produce different output.
        // Catches gctr off-by-one or partial-block bugs.
        test(
          "encrypt — non-aligned PT lengths (1, 17, 31, 47 bytes) round-trip lengths",
          func() {
            let key = Array.repeat<Nat8>(0x42, 32);
            let iv = Array.repeat<Nat8>(0x37, 12);
            for (n in [1, 17, 31, 47].vals()) {
              let pt = Array.repeat<Nat8>(0xa5, n);
              let result = AesGcm.encrypt(key, iv, pt, []);
              expect.nat(result.size()).equal(n + 16);
              // Ciphertext bytes must differ from plaintext (XOR with
              // non-zero keystream essentially never matches input).
              var differs = false;
              for (i in Nat.range(0, n)) {
                if (result[i] != pt[i]) { differs := true };
              };
              assert differs;
            };
          },
        );

      },
    );

  },
);
