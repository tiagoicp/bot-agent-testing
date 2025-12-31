// Import Bun testing globals
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { PocketIc, generateRandomIdentity } from "@dfinity/pic";
import { Principal } from "@dfinity/principal";

// Import generated types for your canister
import { type _SERVICE } from "../../.dfx/local/canisters/bot-agent-backend/service.did";
import { idlFactory } from "../../.dfx/local/canisters/bot-agent-backend/service.did.js";

// Helper to generate valid principals for testing
function generateTestPrincipal(seed: number): Principal {
  // Create a valid principal from seed
  const bytes = new Uint8Array(29);
  bytes[0] = 0; // Type byte for principal
  bytes.set(new TextEncoder().encode(`test${seed}`), 1);
  return Principal.fromUint8Array(bytes);
}

// Define the path to your canister's WASM file
export const WASM_PATH = resolve(
  import.meta.dir,
  "..",
  "..",
  ".dfx",
  "local",
  "canisters",
  "bot-agent-backend",
  "bot-agent-backend.wasm"
);

// The `describe` function is used to group tests together
// and is completely optional.
describe("Bot Agent Backend", () => {
  // Define variables to hold our PocketIC instance, canister ID,
  // and an actor to interact with our canister.
  let pic: PocketIc;
  let canisterId: Principal;
  let actor: any; // It will be defined in beforeEach as a fixture.actor

  // The `beforeEach` hook runs before each test.
  //
  // This can be replaced with a `beforeAll` hook to persist canister
  // state between tests.
  beforeEach(async () => {
    // create a new PocketIC instance
    pic = await PocketIc.create(process.env.PIC_URL || "");

    // Setup the canister and actor
    const fixture = await pic.setupCanister<_SERVICE>({
      idlFactory,
      wasm: WASM_PATH,
    });

    // Save the actor and canister ID for use in tests
    actor = fixture.actor;
    canisterId = fixture.canisterId;
  });

  // The `afterEach` hook runs after each test.
  //
  // This should be replaced with an `afterAll` hook if you use
  // a `beforeAll` hook instead of a `beforeEach` hook.
  afterEach(async () => {
    // tear down the PocketIC instance
    await pic.tearDown();
  });

  // The `it` function is used to define individual tests
  it("should greet a user", async () => {
    const response = await actor.greet("cool");

    expect(response).toEqual("Hello, cool!");
  });

  // ============ ADMIN TESTS ============

  describe("Admin Management", () => {
    describe("add_admin", () => {
      it("should reject anonymous users from adding admins", async () => {
        // caller will be anonymous
        actor.setPrincipal(Principal.anonymous());

        const newAdminPrincipal = generateTestPrincipal(1);
        const result = await actor.add_admin(newAdminPrincipal);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Anonymous users cannot be admins"
        );
      });

      it("should reject duplicate admin addition attempts", async () => {
        const samePrincipal = generateTestPrincipal(2);

        // caller will be a non-anonymous principal
        actor.setIdentity(generateRandomIdentity());

        // add first admin
        await actor.add_admin(samePrincipal);

        // Second call should fail due to being duplicate
        const result = await actor.add_admin(samePrincipal);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Principal is already an admin"
        );
      });
    });

    describe("get_admins", () => {
      it("should return an array of admin principals", async () => {
        const somePrincipal = generateTestPrincipal(1);

        // caller will be a non-anonymous principal
        actor.setIdentity(generateRandomIdentity());

        // add first admin
        await actor.add_admin(somePrincipal);

        const adminsList = await actor.get_admins();
        expect(adminsList[1]).toEqual(somePrincipal);
      });
    });

    describe("is_caller_admin", () => {
      it("should return false for non-admin caller", async () => {
        // Without setting up as admin, caller should not be admin
        const isAdmin = await actor.is_caller_admin();
        expect(isAdmin).toBe(false);
      });

      it("should return true for admin caller", async () => {
        const identity = generateRandomIdentity();
        const principalOfIdentity = identity.getPrincipal();

        // Set the caller identity
        actor.setIdentity(identity);

        // Add the caller as admin
        await actor.add_admin(principalOfIdentity);

        // Now check if caller is admin
        const isAdmin = await actor.is_caller_admin();
        expect(isAdmin).toBe(true);
      });
    });
  });
});
