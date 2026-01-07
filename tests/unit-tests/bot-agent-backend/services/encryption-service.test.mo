import { test; suite } "mo:test";
import EncryptionService "../../../../src/bot-agent-backend/services/encryption-service";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

// Test key (32 bytes) - simulates a SHA256-hashed Schnorr signature
let testKey : [Nat8] = [
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
  0x0A,
  0x0B,
  0x0C,
  0x0D,
  0x0E,
  0x0F,
  0x10,
  0x11,
  0x12,
  0x13,
  0x14,
  0x15,
  0x16,
  0x17,
  0x18,
  0x19,
  0x1A,
  0x1B,
  0x1C,
  0x1D,
  0x1E,
  0x1F,
];

// Test caller principal
let testCaller = Principal.fromActor(actor "aaaaa-aa");

// Different caller for comparison tests - create a different principal from bytes
let differentCallerBytes : [Nat8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
let differentCaller = Principal.fromBlob(Blob.fromArray(differentCallerBytes));

// Test nonce (8 bytes) - for testing lower-level functions
let testNonce : [Nat8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22];

// Different nonce for comparison tests
let differentNonce : [Nat8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];

suite(
  "EncryptionService",
  func() {

    suite(
      "nat64ToBytes",
      func() {
        test(
          "converts zero correctly",
          func() {
            let bytes = EncryptionService.nat64ToBytes(0);
            assert bytes.size() == 8;
            for (byte in bytes.vals()) {
              assert byte == 0;
            };
          },
        );

        test(
          "converts max value correctly",
          func() {
            let bytes = EncryptionService.nat64ToBytes(0xFFFFFFFFFFFFFFFF);
            assert bytes.size() == 8;
            for (byte in bytes.vals()) {
              assert byte == 0xFF;
            };
          },
        );

        test(
          "converts to big-endian",
          func() {
            let bytes = EncryptionService.nat64ToBytes(0x0102030405060708);
            assert bytes[0] == 0x01;
            assert bytes[1] == 0x02;
            assert bytes[2] == 0x03;
            assert bytes[3] == 0x04;
            assert bytes[4] == 0x05;
            assert bytes[5] == 0x06;
            assert bytes[6] == 0x07;
            assert bytes[7] == 0x08;
          },
        );
      },
    );

    suite(
      "xorBytes",
      func() {
        test(
          "XOR is symmetric - XOR(XOR(a, b), b) == a",
          func() {
            let a : [Nat8] = [0x12, 0x34, 0x56, 0x78];
            let b : [Nat8] = [0xAB, 0xCD, 0xEF, 0x01];

            let xored = EncryptionService.xorBytes(a, b);
            let restored = EncryptionService.xorBytes(xored, b);

            assert EncryptionService.arrayEqual(a, restored);
          },
        );

        test(
          "XOR with zeros returns original",
          func() {
            let a : [Nat8] = [0x12, 0x34, 0x56, 0x78];
            let zeros : [Nat8] = [0x00, 0x00, 0x00, 0x00];

            let result = EncryptionService.xorBytes(a, zeros);
            assert EncryptionService.arrayEqual(a, result);
          },
        );

        test(
          "XOR with self returns zeros",
          func() {
            let a : [Nat8] = [0x12, 0x34, 0x56, 0x78];
            let result = EncryptionService.xorBytes(a, a);

            for (byte in result.vals()) {
              assert byte == 0x00;
            };
          },
        );
      },
    );

    suite(
      "arrayEqual",
      func() {
        test(
          "equal arrays return true",
          func() {
            let a : [Nat8] = [0x01, 0x02, 0x03];
            let b : [Nat8] = [0x01, 0x02, 0x03];
            assert EncryptionService.arrayEqual(a, b);
          },
        );

        test(
          "different arrays return false",
          func() {
            let a : [Nat8] = [0x01, 0x02, 0x03];
            let b : [Nat8] = [0x01, 0x02, 0x04];
            assert not EncryptionService.arrayEqual(a, b);
          },
        );

        test(
          "different length arrays return false",
          func() {
            let a : [Nat8] = [0x01, 0x02, 0x03];
            let b : [Nat8] = [0x01, 0x02];
            assert not EncryptionService.arrayEqual(a, b);
          },
        );

        test(
          "empty arrays are equal",
          func() {
            let a : [Nat8] = [];
            let b : [Nat8] = [];
            assert EncryptionService.arrayEqual(a, b);
          },
        );
      },
    );

    suite(
      "generateKeystreamBlock",
      func() {
        test(
          "generates 32-byte block",
          func() {
            let block = EncryptionService.generateKeystreamBlock(testKey, testNonce, 0);
            assert block.size() == 32;
          },
        );

        test(
          "same inputs produce same output (deterministic)",
          func() {
            let block1 = EncryptionService.generateKeystreamBlock(testKey, testNonce, 0);
            let block2 = EncryptionService.generateKeystreamBlock(testKey, testNonce, 0);
            assert EncryptionService.arrayEqual(block1, block2);
          },
        );

        test(
          "different counters produce different blocks",
          func() {
            let block0 = EncryptionService.generateKeystreamBlock(testKey, testNonce, 0);
            let block1 = EncryptionService.generateKeystreamBlock(testKey, testNonce, 1);
            assert not EncryptionService.arrayEqual(block0, block1);
          },
        );

        test(
          "different nonces produce different blocks",
          func() {
            let block1 = EncryptionService.generateKeystreamBlock(testKey, testNonce, 0);
            let block2 = EncryptionService.generateKeystreamBlock(testKey, differentNonce, 0);
            assert not EncryptionService.arrayEqual(block1, block2);
          },
        );
      },
    );

    suite(
      "generateKeystream",
      func() {
        test(
          "generates exact requested length",
          func() {
            let keystream = EncryptionService.generateKeystream(testKey, testNonce, 50);
            assert keystream.size() == 50;
          },
        );

        test(
          "generates empty array for length 0",
          func() {
            let keystream = EncryptionService.generateKeystream(testKey, testNonce, 0);
            assert keystream.size() == 0;
          },
        );

        test(
          "handles length greater than block size",
          func() {
            // Request 100 bytes (more than 3 blocks of 32 bytes)
            let keystream = EncryptionService.generateKeystream(testKey, testNonce, 100);
            assert keystream.size() == 100;
          },
        );

        test(
          "is deterministic",
          func() {
            let ks1 = EncryptionService.generateKeystream(testKey, testNonce, 64);
            let ks2 = EncryptionService.generateKeystream(testKey, testNonce, 64);
            assert EncryptionService.arrayEqual(ks1, ks2);
          },
        );
      },
    );

    suite(
      "encrypt and decrypt",
      func() {
        test(
          "roundtrip: decrypt(encrypt(plaintext)) == plaintext",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]; // "Hello"

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            switch (decrypted) {
              case (null) { assert false };
              case (?result) {
                assert EncryptionService.arrayEqual(plaintext, result);
              };
            };
          },
        );

        test(
          "encrypted output has correct structure",
          func() {
            let plaintext : [Nat8] = [0x01, 0x02, 0x03, 0x04, 0x05];

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);

            // Expected size: 8 (nonce) + 5 (ciphertext) = 13
            assert encrypted.size() == 13;
          },
        );

        test(
          "different nonces produce different ciphertext",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

            let encrypted1 = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let encrypted2 = EncryptionService.encrypt(testKey, plaintext, differentCaller);

            assert not EncryptionService.arrayEqual(encrypted1, encrypted2);
          },
        );

        test(
          "handles empty plaintext",
          func() {
            let plaintext : [Nat8] = [];

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            switch (decrypted) {
              case (null) { assert false };
              case (?result) {
                assert result.size() == 0;
              };
            };
          },
        );

        test(
          "handles long plaintext (multiple blocks)",
          func() {
            // Create 100-byte plaintext
            let plaintext = Array.tabulate<Nat8>(100, func(i : Nat) : Nat8 { Nat8.fromNat(i % 256) });

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            switch (decrypted) {
              case (null) { assert false };
              case (?result) {
                assert EncryptionService.arrayEqual(plaintext, result);
              };
            };
          },
        );

        test(
          "rejects truncated data",
          func() {
            let tooShort : [Nat8] = [0x01, 0x02, 0x03]; // Less than 8 bytes (nonce)
            let decrypted = EncryptionService.decrypt(testKey, tooShort);
            assert decrypted == null;
          },
        );

        test(
          "wrong key produces different output",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];
            let wrongKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { 0xFF });

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(wrongKey, encrypted);

            switch (decrypted) {
              case (null) { assert false };
              case (?result) {
                // Decryption succeeds but produces different (garbage) output
                assert not EncryptionService.arrayEqual(plaintext, result);
              };
            };
          },
        );
      },
    );

  },
);
