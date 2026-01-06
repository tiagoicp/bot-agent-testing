// Import Bun testing globals
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { PocketIc, generateRandomIdentity } from "@dfinity/pic";
import { Principal } from "@dfinity/principal";

// Import generated types for your canister
import { type _SERVICE } from "../../.dfx/local/canisters/bot-agent-backend/service.did";
import { idlFactory } from "../../.dfx/local/canisters/bot-agent-backend/service.did.js";
import { type Actor } from "@dfinity/pic";

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
  let actor: Actor<_SERVICE>;

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
        const result = await actor.addAdmin(newAdminPrincipal);
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
        await actor.addAdmin(samePrincipal);

        // Second call should fail due to being duplicate
        const result = await actor.addAdmin(samePrincipal);
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
        await actor.addAdmin(somePrincipal);

        const adminsList = await actor.getAdmins();
        expect(adminsList[1]).toEqual(somePrincipal);
      });
    });

    describe("is_caller_admin", () => {
      it("should return false for non-admin caller", async () => {
        // Without setting up as admin, caller should not be admin
        const isAdmin = await actor.isCallerAdmin();
        expect(isAdmin).toBe(false);
      });

      it("should return true for admin caller", async () => {
        const identity = generateRandomIdentity();
        const principalOfIdentity = identity.getPrincipal();

        // Set the caller identity
        actor.setIdentity(identity);

        // Add the caller as admin
        await actor.addAdmin(principalOfIdentity);

        // Now check if caller is admin
        const isAdmin = await actor.isCallerAdmin();
        expect(isAdmin).toBe(true);
      });
    });
  });

  // ============ AGENT MANAGEMENT TESTS ============

  describe("Agent Management", () => {
    let adminIdentity: ReturnType<typeof generateRandomIdentity>;
    let adminPrincipal: Principal;

    beforeEach(async () => {
      // Set up an admin for testing agent operations
      adminIdentity = generateRandomIdentity();
      adminPrincipal = adminIdentity.getPrincipal();
      actor.setIdentity(adminIdentity);
      await actor.addAdmin(adminPrincipal);
    });

    describe("create_agent", () => {
      it("should reject agent creation from non-admin user", async () => {
        const nonAdminIdentity = generateRandomIdentity();
        actor.setIdentity(nonAdminIdentity);

        const result = await actor.createAgent(
          "Test Agent",
          { openai: null },
          "gpt-4",
        );
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Only admins can create agents",
        );
      });

      it("should reject agent creation with empty name", async () => {
        const result = await actor.createAgent("", { openai: null }, "gpt-4");
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Agent name cannot be empty",
        );
      });

      it("should successfully create an agent with admin user and all params", async () => {
        const result = await actor.createAgent(
          "OpenAI Agent",
          { openai: null },
          "gpt-4",
        );
        expect("ok" in result).toBe(true);
        expect("ok" in result ? result.ok : null).toEqual(0n);
      });

      it("should create multiple agents with incrementing IDs", async () => {
        const result1 = await actor.createAgent(
          "Agent 1",
          { openai: null },
          "gpt-4",
        );
        if ("err" in result1) {
          throw new Error(`Failed to create agent 1: ${result1.err}`);
        }
        const id1 = result1.ok;

        const result2 = await actor.createAgent(
          "Agent 2",
          { llmcanister: null },
          "llama",
        );
        if ("err" in result2) {
          throw new Error(`Failed to create agent 2: ${result2.err}`);
        }
        const id2 = result2.ok;

        expect(id1).toEqual(0n);
        expect(id2).toEqual(1n);
      });
    });

    describe("get_agent", () => {
      it("should return null for non-existent agent", async () => {
        const agent = await actor.getAgent(999n);
        // Candid handles an optional custom type as an array with 0 or 1 elements
        // an empty array means null in Motoko
        expect(agent).toEqual([]);
      });

      it("should return an agent that exists", async () => {
        const createResult = await actor.createAgent(
          "Test Agent",
          { openai: null },
          "gpt-4",
        );
        if ("err" in createResult) {
          throw new Error(`Failed to create agent: ${createResult.err}`);
        }
        const agentId = createResult.ok;

        const agent = await actor.getAgent(agentId);
        if (agent.length === 0) {
          throw new Error("Agent should exist but was not found");
        }
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

        const updateResult = await actor.updateAgent(
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
        const result = await actor.updateAgent(999n, [], [], []);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual("Agent not found");
      });

      it("should update agent name only", async () => {
        const createResult = await actor.createAgent(
          "Original",
          { openai: null },
          "gpt-4",
        );
        if ("err" in createResult) {
          throw new Error(`Failed to create agent: ${createResult.err}`);
        }
        const agentId = createResult.ok;

        const updateResult = await actor.updateAgent(
          agentId,
          ["Updated Name"],
          [],
          [],
        );
        expect("ok" in updateResult).toBe(true);

        const agent = await actor.getAgent(agentId);
        if (agent.length === 0) {
          throw new Error("Agent should exist but was not found");
        }
        const agentData = agent[0];
        expect(agentData.name).toEqual("Updated Name");
        expect(agentData.model).toEqual("gpt-4");
      });

      it("should update all agent fields", async () => {
        const createResult = await actor.createAgent(
          "Original",
          { openai: null },
          "gpt-3.5",
        );
        if ("err" in createResult) {
          throw new Error(`Failed to create agent: ${createResult.err}`);
        }
        const agentId = createResult.ok;

        const updateResult = await actor.updateAgent(
          agentId,
          ["New Agent Name"],
          [{ llmcanister: null }],
          ["llama2"],
        );
        expect("ok" in updateResult).toBe(true);

        const agent = await actor.getAgent(agentId);
        if (agent.length === 0) {
          throw new Error("Agent should exist but was not found");
        }
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

        const deleteResult = await actor.deleteAgent(0n);
        expect("err" in deleteResult).toBe(true);
        expect("err" in deleteResult ? deleteResult.err : "").toEqual(
          "Only admins can delete agents",
        );
      });

      it("should reject deletion of non-existent agent", async () => {
        const result = await actor.deleteAgent(999n);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual("Agent not found");
      });

      it("should successfully delete an agent", async () => {
        const createResult = await actor.createAgent(
          "Agent to Delete",
          { openai: null },
          "gpt-4",
        );
        if ("err" in createResult) {
          throw new Error(`Failed to create agent: ${createResult.err}`);
        }
        const agentId = createResult.ok;

        const deleteResult = await actor.deleteAgent(agentId);
        expect("ok" in deleteResult).toBe(true);

        const agent = await actor.getAgent(agentId);
        expect(agent).toEqual([]);
      });
    });

    describe("list_agents", () => {
      it("should return all created agents", async () => {
        await actor.createAgent("Agent 1", { openai: null }, "gpt-4");
        await actor.createAgent("Agent 2", { groq: null }, "mixtral");
        await actor.createAgent("Agent 3", { llmcanister: null }, "llama2");

        const agents = await actor.listAgents();
        expect(agents.length).toEqual(3);
        expect(agents[1].id).toEqual(1n);
        expect(agents[1].name).toEqual("Agent 2");
        expect(agents[1].provider).toEqual({ groq: null });
        expect(agents[1].model).toEqual("mixtral");
      });
    });
  });

  // ============ CONVERSATION TESTS ============

  describe("Conversation Management", () => {
    let adminIdentity: ReturnType<typeof generateRandomIdentity>;
    let adminPrincipal: Principal;
    let userIdentity: ReturnType<typeof generateRandomIdentity>;
    let agentId: bigint;

    beforeEach(async () => {
      // Set up an admin
      adminIdentity = generateRandomIdentity();
      adminPrincipal = adminIdentity.getPrincipal();
      actor.setIdentity(adminIdentity);
      await actor.addAdmin(adminPrincipal);

      // Create a test agent
      const createResult = await actor.createAgent(
        "Test Conversation Agent",
        { openai: null },
        "gpt-4",
      );
      if ("err" in createResult) {
        throw new Error(`Failed to create agent: ${createResult.err}`);
      }
      agentId = createResult.ok;

      // Set up a regular user
      userIdentity = generateRandomIdentity();
      actor.setIdentity(userIdentity);
    });

    describe("talk_to", () => {
      it("should reject anonymous users from sending messages", async () => {
        actor.setPrincipal(Principal.anonymous());

        const result = await actor.talkTo(agentId, "Hello Agent");
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Please login before calling this function",
        );
      });

      it("should accept message from authenticated user", async () => {
        const result = await actor.talkTo(agentId, "Hello Agent");
        expect("ok" in result).toBe(true);
      });
    });

    describe("get_conversation", () => {
      it("should return err message when no conversation exists with agent", async () => {
        const result = await actor.getConversation(agentId);
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "No conversation found with agent " + agentId,
        );
      });

      it("should contain correct message content in conversation history", async () => {
        const testMessage = "This is a test message";
        await actor.talkTo(agentId, testMessage);

        const result = await actor.getConversation(agentId);
        expect("ok" in result).toBe(true);
        const messages = "ok" in result ? result.ok : [];

        const userMessage = messages.find(
          (msg: { author?: Record<string, unknown>; content?: string }) =>
            msg.author && "user" in msg.author,
        );
        expect(userMessage).toBeDefined();
        expect(userMessage?.content).toEqual(testMessage);
      });

      it("should maintain conversation history across multiple messages", async () => {
        const message1 = "First message";
        const message2 = "Second message";
        const message3 = "Third message";

        await actor.talkTo(agentId, message1);
        await actor.talkTo(agentId, message2);
        await actor.talkTo(agentId, message3);

        const result = await actor.getConversation(agentId);
        expect("ok" in result).toBe(true);
        const messages = "ok" in result ? result.ok : [];
        expect(messages.length).toBeGreaterThanOrEqual(3);
      });

      it("should isolate conversations between different agents", async () => {
        // Create another agent
        actor.setIdentity(adminIdentity);
        const createResult2 = await actor.createAgent(
          "Another Agent",
          { groq: null },
          "mixtral",
        );
        if ("err" in createResult2) {
          throw new Error(`Failed to create agent: ${createResult2.err}`);
        }
        const agentId2 = createResult2.ok;

        // Switch back to user and send messages to different agents
        actor.setIdentity(userIdentity);
        const message1 = "Message for first agent";
        const message2 = "Message for second agent";

        await actor.talkTo(agentId, message1);
        await actor.talkTo(agentId2, message2);

        // Check conversation history for first agent
        const result1 = await actor.getConversation(agentId);
        const messages1 = "ok" in result1 ? result1.ok : [];
        const foundMsg1 = messages1.some(
          (msg: { content?: string }) => msg.content === message1,
        );
        expect(foundMsg1).toBe(true);

        // Check conversation history for second agent
        const result2 = await actor.getConversation(agentId2);
        const messages2 = "ok" in result2 ? result2.ok : [];
        const foundMsg2 = messages2.some(
          (msg: { content?: string }) => msg.content === message2,
        );
        expect(foundMsg2).toBe(true);
      });
    });
  });

  // ============ API KEY MANAGEMENT TESTS ============

  describe("API Key Management", () => {
    let adminIdentity: ReturnType<typeof generateRandomIdentity>;
    let adminPrincipal: Principal;
    let userIdentity: ReturnType<typeof generateRandomIdentity>;
    let agentId: bigint;

    beforeEach(async () => {
      // Set up an admin
      adminIdentity = generateRandomIdentity();
      adminPrincipal = adminIdentity.getPrincipal();
      actor.setIdentity(adminIdentity);
      await actor.addAdmin(adminPrincipal);

      // Create a test agent
      const createResult = await actor.createAgent(
        "Test API Key Agent",
        { openai: null },
        "gpt-4",
      );
      if ("err" in createResult) {
        throw new Error(`Failed to create agent: ${createResult.err}`);
      }
      agentId = createResult.ok;

      // Set up a regular user
      userIdentity = generateRandomIdentity();
      actor.setIdentity(userIdentity);
    });

    describe("store_api_key", () => {
      it("should reject anonymous users from storing API keys", async () => {
        actor.setPrincipal(Principal.anonymous());

        const result = await actor.storeApiKey(
          agentId,
          { groq: null },
          "test-key-123",
        );
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Please login before calling this function",
        );
      });

      it("should reject storing API key for non-existent agent", async () => {
        const result = await actor.storeApiKey(
          999n,
          { groq: null },
          "test-key-123",
        );
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual("Agent not found");
      });
    });

    describe("get_my_api_keys", () => {
      it("should reject anonymous users from retrieving API keys", async () => {
        actor.setPrincipal(Principal.anonymous());

        const result = await actor.getMyApiKeys();
        expect("err" in result).toBe(true);
        expect("err" in result ? result.err : "").toEqual(
          "Please login before calling this function",
        );
      });

      it("should return empty array when user has no API keys", async () => {
        const result = await actor.getMyApiKeys();
        expect("ok" in result).toBe(true);
        const keys = "ok" in result ? result.ok : [];
        expect(keys).toEqual([]);
      });

      it("should return only caller's API keys, not other users' keys", async () => {
        // Store key as first user
        await actor.storeApiKey(agentId, { groq: null }, "user-one-key");

        // Switch to second user
        const secondUserIdentity = generateRandomIdentity();
        actor.setIdentity(secondUserIdentity);

        // Second user should have no keys
        const resultBefore = await actor.getMyApiKeys();
        expect("ok" in resultBefore).toBe(true);
        const keysBefore = "ok" in resultBefore ? resultBefore.ok : [];
        expect(keysBefore.length).toEqual(0);

        // Store a key as second user
        await actor.storeApiKey(agentId, { groq: null }, "user-two-key");

        // Now second user should have exactly 1 key
        const resultAfter = await actor.getMyApiKeys();
        expect("ok" in resultAfter).toBe(true);
        const keysAfter = "ok" in resultAfter ? resultAfter.ok : [];
        expect(keysAfter.length).toEqual(1);

        // Switch back to first user
        actor.setIdentity(userIdentity);
        const firstUserResult = await actor.getMyApiKeys();
        expect("ok" in firstUserResult).toBe(true);
        const firstUserKeys = "ok" in firstUserResult ? firstUserResult.ok : [];
        expect(firstUserKeys.length).toEqual(1);
      });

      it("should maintain API key list after storing multiple keys", async () => {
        // Create multiple agents
        actor.setIdentity(adminIdentity);
        const agent1 = agentId;
        const createResult2 = await actor.createAgent(
          "Agent 2",
          { groq: null },
          "mixtral",
        );
        if ("err" in createResult2) {
          throw new Error(`Failed to create agent 2: ${createResult2.err}`);
        }
        const agent2 = createResult2.ok;
        const createResult3 = await actor.createAgent(
          "Agent 3",
          { groq: null },
          "llama",
        );
        if ("err" in createResult3) {
          throw new Error(`Failed to create agent 3: ${createResult3.err}`);
        }
        const agent3 = createResult3.ok;

        // Switch to user and store keys
        actor.setIdentity(userIdentity);
        await actor.storeApiKey(agent1, { groq: null }, "key-1");
        await actor.storeApiKey(agent2, { groq: null }, "key-2");
        await actor.storeApiKey(agent3, { groq: null }, "key-3");

        // Retrieve and verify all keys are present
        const result = await actor.getMyApiKeys();
        expect("ok" in result).toBe(true);
        const keys = "ok" in result ? result.ok : [];
        expect(keys.length).toEqual(3);

        // Verify specific keys
        expect(
          keys.some(
            (k: [bigint, string]) => k[0] === agent1 && k[1] === "groq",
          ),
        ).toBe(true);
        expect(
          keys.some(
            (k: [bigint, string]) => k[0] === agent2 && k[1] === "groq",
          ),
        ).toBe(true);
        expect(
          keys.some(
            (k: [bigint, string]) => k[0] === agent3 && k[1] === "groq",
          ),
        ).toBe(true);
      });
    });
  });
});
