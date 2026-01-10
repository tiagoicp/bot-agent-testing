import { test; suite; expect } "mo:test";
import EncryptionService "../../../../src/bot-agent-backend/services/encryption-service";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

/// Compare two byte arrays for equality (constant-time for security)
func arrayEqual(a : [Nat8], b : [Nat8]) : Bool {
  if (a.size() != b.size()) {
    return false;
  };

  var result : Nat8 = 0;
  for (i in Nat.range(0, a.size())) {
    result := result | (a[i] ^ b[i]);
  };

  result == 0;
};

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

suite(
  "EncryptionService",
  func() {

    suite(
      "encrypt and decrypt",
      func() {
        test(
          "roundtrip: decrypt(encrypt(plaintext)) == plaintext",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]; // "Hello"

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            expect.bool(arrayEqual(plaintext, decrypted)).isTrue();
          },
        );

        test(
          "encrypted output has correct structure",
          func() {
            let plaintext : [Nat8] = [0x01, 0x02, 0x03, 0x04, 0x05];

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);

            // Expected size: 8 (nonce) + 5 (ciphertext) = 13
            expect.nat(encrypted.size()).equal(13);
          },
        );

        test(
          "different principals (nonces) produce different ciphertext",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

            let encrypted1 = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let encrypted2 = EncryptionService.encrypt(testKey, plaintext, differentCaller);

            expect.bool(arrayEqual(encrypted1, encrypted2)).isFalse();
          },
        );

        test(
          "handles empty plaintext",
          func() {
            let plaintext : [Nat8] = [];

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            expect.nat(decrypted.size()).equal(0);
          },
        );

        test(
          "handles long plaintext (multiple blocks)",
          func() {
            // Create 100-byte plaintext
            let plaintext = Array.tabulate<Nat8>(100, func(i : Nat) : Nat8 { Nat8.fromNat(i % 256) });

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(testKey, encrypted);

            expect.bool(arrayEqual(plaintext, decrypted)).isTrue();
          },
        );

        test(
          "wrong key produces different output",
          func() {
            let plaintext : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];
            let wrongKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { 0xFF });

            let encrypted = EncryptionService.encrypt(testKey, plaintext, testCaller);
            let decrypted = EncryptionService.decrypt(wrongKey, encrypted);

            // Decryption succeeds but produces different (garbage) output
            expect.bool(arrayEqual(plaintext, decrypted)).isFalse();
          },
        );
      },
    );
  },
);
