import { test; suite; expect } "mo:test";
import Base64 "../../../../src/control-plane-core/utilities/base64";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

suite(
  "Base64",
  func() {

    suite(
      "encode",
      func() {

        test(
          "empty input returns empty string",
          func() {
            expect.text(Base64.encode([])).equal("");
          },
        );

        test(
          "RFC 4648 §10 test vector: 'f' → 'Zg=='",
          func() {
            expect.text(Base64.encode([0x66])).equal("Zg==");
          },
        );

        test(
          "RFC 4648 §10 test vector: 'fo' → 'Zm8='",
          func() {
            expect.text(Base64.encode([0x66, 0x6f])).equal("Zm8=");
          },
        );

        test(
          "RFC 4648 §10 test vector: 'foo' → 'Zm9v'",
          func() {
            expect.text(Base64.encode([0x66, 0x6f, 0x6f])).equal("Zm9v");
          },
        );

        test(
          "RFC 4648 §10 test vector: 'foob' → 'Zm9vYg=='",
          func() {
            expect.text(Base64.encode([0x66, 0x6f, 0x6f, 0x62])).equal("Zm9vYg==");
          },
        );

        test(
          "RFC 4648 §10 test vector: 'foobar' → 'Zm9vYmFy'",
          func() {
            expect.text(Base64.encode([0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72])).equal("Zm9vYmFy");
          },
        );

        test(
          "'Hello' → 'SGVsbG8='",
          func() {
            expect.text(Base64.encode([0x48, 0x65, 0x6c, 0x6c, 0x6f])).equal("SGVsbG8=");
          },
        );

        test(
          "all-zero single byte → 'AA=='",
          func() {
            expect.text(Base64.encode([0x00])).equal("AA==");
          },
        );

        test(
          "all-zero 3 bytes → 'AAAA'",
          func() {
            expect.text(Base64.encode([0x00, 0x00, 0x00])).equal("AAAA");
          },
        );

        test(
          "all-0xFF 3 bytes → '////'",
          func() {
            expect.text(Base64.encode([0xff, 0xff, 0xff])).equal("////");
          },
        );

      },
    );

    suite(
      "decode",
      func() {

        test(
          "empty string returns empty array",
          func() {
            switch (Base64.decode("")) {
              case (?bytes) { expect.nat(bytes.size()).equal(0) };
              case null { assert false };
            };
          },
        );

        test(
          "'Zg==' → [0x66]",
          func() {
            switch (Base64.decode("Zg==")) {
              case (?bytes) {
                expect.nat(bytes.size()).equal(1);
                expect.nat(Nat8.toNat(bytes[0])).equal(0x66);
              };
              case null { assert false };
            };
          },
        );

        test(
          "'SGVsbG8=' → 'Hello'",
          func() {
            switch (Base64.decode("SGVsbG8=")) {
              case (?bytes) {
                expect.nat(bytes.size()).equal(5);
                expect.nat(Nat8.toNat(bytes[0])).equal(0x48); // 'H'
                expect.nat(Nat8.toNat(bytes[4])).equal(0x6f); // 'o'
              };
              case null { assert false };
            };
          },
        );

        test(
          "'Zm9v' → 'foo'",
          func() {
            switch (Base64.decode("Zm9v")) {
              case (?bytes) {
                expect.nat(bytes.size()).equal(3);
                expect.nat(Nat8.toNat(bytes[0])).equal(0x66);
                expect.nat(Nat8.toNat(bytes[1])).equal(0x6f);
                expect.nat(Nat8.toNat(bytes[2])).equal(0x6f);
              };
              case null { assert false };
            };
          },
        );

        test(
          "invalid character returns null",
          func() {
            switch (Base64.decode("Zm9!")) {
              case (?_) { assert false };
              case null { /* expected */ };
            };
          },
        );

        test(
          "length not divisible by 4 returns null",
          func() {
            switch (Base64.decode("Zm8")) {
              case (?_) { assert false };
              case null { /* expected */ };
            };
          },
        );

      },
    );

    suite(
      "round-trip",
      func() {

        test(
          "encode then decode returns original bytes",
          func() {
            let original : [Nat8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef];
            let encoded = Base64.encode(original);
            switch (Base64.decode(encoded)) {
              case (?decoded) {
                expect.nat(decoded.size()).equal(original.size());
                for (i in original.keys()) {
                  expect.nat(Nat8.toNat(decoded[i])).equal(Nat8.toNat(original[i]));
                };
              };
              case null { assert false };
            };
          },
        );

        test(
          "round-trip 32-byte key-like value",
          func() {
            let original = Array.tabulate<Nat8>(
              32,
              func(i : Nat) : Nat8 {
                Nat8.fromNat(i * 8 % 256);
              },
            );
            let encoded = Base64.encode(original);
            switch (Base64.decode(encoded)) {
              case (?decoded) {
                expect.nat(decoded.size()).equal(32);
                for (i in original.keys()) {
                  expect.nat(Nat8.toNat(decoded[i])).equal(Nat8.toNat(original[i]));
                };
              };
              case null { assert false };
            };
          },
        );

      },
    );

  },
);
