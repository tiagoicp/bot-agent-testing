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
  "bot-agent-backend.wasm",
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

  // ============ ADMIN MANAGEMENT TESTS ============

  describe("Admin Management", () => {
    describe("add_admin", () => {
      it("should reject anonymous users from adding admins", async () => {
        // caller will be anonymous
        actor.setPrincipal(Principal.anonymous());

        const newAdminPrincipal = generateTestPrincipal(1);
        const result = await actor.add_admin(newAdminPrincipal);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Anonymous users cannot be admins",
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
          "Principal is already an admin",
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

  // ============ AGENT MANAGEMENT TESTS ============

  describe("Agent Management", () => {
    let adminIdentity: any;
    let adminPrincipal: Principal;

    beforeEach(async () => {
      // Set up an admin for testing agent operations
      adminIdentity = generateRandomIdentity();
      adminPrincipal = adminIdentity.getPrincipal();
      actor.setIdentity(adminIdentity);
      await actor.add_admin(adminPrincipal);
    });

    describe("create_agent", () => {
      it("should reject agent creation from non-admin user", async () => {
        const nonAdminIdentity = generateRandomIdentity();
        actor.setIdentity(nonAdminIdentity);

        const result = await actor.create_agent(
          "Test Agent",
          { openai: null },
          "gpt-4",
        );
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Only admins can add new agents",
        );
      });

      it("should reject agent creation with empty name", async () => {
        const result = await actor.create_agent("", { openai: null }, "gpt-4");
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Agent name cannot be empty",
        );
      });

      it("should successfully create an agent with admin user and all params", async () => {
        const result = await actor.create_agent(
          "OpenAI Agent",
          { openai: null },
          "gpt-4",
        );
        expect("ok" in result).toBe(true);
        expect("ok" in result ? result.ok : null).toEqual(0n);
      });

      it("should create multiple agents with incrementing IDs", async () => {
        const result1 = await actor.create_agent(
          "Agent 1",
          { openai: null },
          "gpt-4",
        );
        const id1 = "ok" in result1 ? result1.ok : null;

        const result2 = await actor.create_agent(
          "Agent 2",
          { llmcanister: null },
          "llama",
        );
        const id2 = "ok" in result2 ? result2.ok : null;

        expect(id1).toEqual(0n);
        expect(id2).toEqual(1n);
      });
    });

    describe("get_agent", () => {
      it("should return null for non-existent agent", async () => {
        const agent = await actor.get_agent(999);
        // Candid handles an optional custom type as an array with 0 or 1 elements
        // an empty array means null in Motoko
        expect(agent).toEqual([]);
      });

      it("should return an agent that exists", async () => {
        const createResult = await actor.create_agent(
          "Test Agent",
          { openai: null },
          "gpt-4",
        );
        const agentId = "ok" in createResult ? createResult.ok : null;

        const agent = await actor.get_agent(agentId);
        expect(agent.length).toBeGreaterThan(0);
        const agentData = agent[0];
        expect(agentData.id).toEqual(agentId);
        expect(agentData.name).toEqual("Test Agent");
        expect(agentData.provider).toEqual({ openai: null });
        expect(agentData.model).toEqual("gpt-4");
      });
    });

    describe("update_agent", () => {
      it("should reject update from non-admin user", async () => {
        // Try to update as non-admin
        const nonAdminIdentity = generateRandomIdentity();
        actor.setIdentity(nonAdminIdentity);

        const updateResult = await actor.update_agent(
          0n,
          ["Updated Name"],
          [],
          [],
        );
        expect("err" in updateResult).toBe(true);
        expect("err" in updateResult ? updateResult.err : "").toEqual(
          "Only admins can update agents",
        );
      });

      it("should reject update of non-existent agent", async () => {
        const result = await actor.update_agent(999n, [], [], []);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual("Agent not found");
      });

      it("should update agent name only", async () => {
        const createResult = await actor.create_agent(
          "Original",
          { openai: null },
          "gpt-4",
        );
        const agentId = "ok" in createResult ? createResult.ok : null;

        const updateResult = await actor.update_agent(
          agentId,
          ["Updated Name"],
          [],
          [],
        );
        expect("ok" in updateResult).toBe(true);

        const agent = await actor.get_agent(agentId);
        expect(agent.length).toBeGreaterThan(0);
        const agentData = agent[0];
        expect(agentData.name).toEqual("Updated Name");
        expect(agentData.model).toEqual("gpt-4");
      });

      it("should update all agent fields", async () => {
        const createResult = await actor.create_agent(
          "Original",
          { openai: null },
          "gpt-3.5",
        );
        const agentId = "ok" in createResult ? createResult.ok : null;

        const updateResult = await actor.update_agent(
          agentId,
          ["New Agent Name"],
          [{ llmcanister: null }],
          ["llama2"],
        );
        expect("ok" in updateResult).toBe(true);

        const agent = await actor.get_agent(agentId);
        expect(agent.length).toBeGreaterThan(0);
        const agentData = agent[0];
        expect(agentData.name).toEqual("New Agent Name");
        expect(agentData.provider).toEqual({ llmcanister: null });
        expect(agentData.model).toEqual("llama2");
      });
    });

    describe("delete_agent", () => {
      it("should reject deletion from non-admin user", async () => {
        // Try to delete as non-admin
        const nonAdminIdentity = generateRandomIdentity();
        actor.setIdentity(nonAdminIdentity);

        const deleteResult = await actor.delete_agent(0);
        expect("err" in deleteResult).toBe(true);
        expect("err" in deleteResult ? deleteResult.err : "").toEqual(
          "Only admins can delete agents",
        );
      });

      it("should reject deletion of non-existent agent", async () => {
        const result = await actor.delete_agent(999);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual("Agent not found");
      });

      it("should successfully delete an agent", async () => {
        const createResult = await actor.create_agent(
          "Agent to Delete",
          { openai: null },
          "gpt-4",
        );
        const agentId = "ok" in createResult ? createResult.ok : null;

        const deleteResult = await actor.delete_agent(agentId);
        expect("ok" in deleteResult).toBe(true);

        const agent = await actor.get_agent(agentId);
        expect(agent).toEqual([]);
      });
    });

    describe("list_agents", () => {
      it("should return all created agents", async () => {
        await actor.create_agent("Agent 1", { openai: null }, "gpt-4");
        await actor.create_agent("Agent 2", { groq: null }, "mixtral");
        await actor.create_agent("Agent 3", { llmcanister: null }, "llama2");

        const agents = await actor.list_agents();
        expect(agents.length).toEqual(3);
        expect(agents[1].id).toEqual(1n);
        expect(agents[1].name).toEqual("Agent 2");
        expect(agents[1].provider).toEqual({ groq: null });
        expect(agents[1].model).toEqual("mixtral");
      });
    });
  });
});
