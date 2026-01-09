import { test; suite; expect } "mo:test";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import KeyDerivationService "../../../../src/bot-agent-backend/services/key-derivation-service";

// Test principals
let principal1 = Principal.fromActor(actor "aaaaa-aa");
let principal2 = Principal.fromText("2vxsx-fae");

suite(
  "KeyDerivationService",
  func() {
    test(
      "getSchnorrKeyName returns correct key name for local environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#local);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_LOCAL);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for test environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#test);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_LOCAL);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for staging environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#staging);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_TEST);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for production environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#production);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_PROD);
      },
    );

    test(
      "clearCache returns an empty cache",
      func() {
        let cache = KeyDerivationService.clearCache();
        let size = KeyDerivationService.getCacheSize(cache);
        expect.nat(size).equal(0);
      },
    );

    test(
      "getCacheSize returns correct count after adding entries",
      func() {
        let cache = Map.empty<Principal, [Nat8]>();
        let size = KeyDerivationService.getCacheSize(cache);
        expect.nat(size).equal(0);

        let testKey1 : [Nat8] = [0x00, 0x01, 0x02, 0x03];
        let testKey2 : [Nat8] = [0x04, 0x05, 0x06, 0x07];

        Map.add(cache, Principal.compare, principal1, testKey1);
        expect.nat(KeyDerivationService.getCacheSize(cache)).equal(1);

        Map.add(cache, Principal.compare, principal2, testKey2);
        expect.nat(KeyDerivationService.getCacheSize(cache)).equal(2);
      },
    );
  },
);
