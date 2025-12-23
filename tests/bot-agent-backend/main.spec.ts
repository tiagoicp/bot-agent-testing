// Import Bun testing globals
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { PocketIc } from "@dfinity/pic";
import { Principal } from "@dfinity/principal";

// Import generated types for your canister
import { type _SERVICE } from "../../.dfx/local/canisters/bot-agent-backend/service.did";
import { idlFactory } from "../../.dfx/local/canisters/bot-agent-backend/service.did.js";

// Define the path to your canister's WASM file
export const WASM_PATH = resolve(
  import.meta.dir,
  "..",
  "..",
  ".dfx",
  "local",
  "canisters",
  "bot-agent-backend",
  "bot-agent-backend.wasm",
);

// The `describe` function is used to group tests together
// and is completely optional.
describe("Bot Agent Backend", () => {
  // Define variables to hold our PocketIC instance, canister ID,
  // and an actor to interact with our canister.
  let pic: PocketIc;
  let canisterId: Principal;
  let actor: _SERVICE;

  // The `beforeEach` hook runs before each test.
  //
  // This can be replaced with a `beforeAll` hook to persist canister
  // state between tests.
  beforeEach(async () => {
    // create a new PocketIC instance
    pic = await PocketIc.create(process.env.PIC_URL || "http://localhost:8000");

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
});
