import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { Actor, PocketIc } from "@dfinity/pic";
import {
  createTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../../setup";

describe("ToolExecutor", () => {
  describe("deterministic branches", () => {
    let pic: PocketIc;
    let testCanister: Actor<TestCanisterService>;

    beforeAll(async () => {
      const testEnv = await createTestCanister();
      pic = testEnv.pic;
    });

    beforeEach(async () => {
      testCanister = (await freshTestCanister(pic)).actor;
    });

    afterAll(async () => {
      await pic.tearDown();
    });

    it("returns an error for an unknown tool name", async () => {
      const results = await testCanister.testToolExecutorExecute(
        "does_not_exist",
        "{}",
      );

      expect(results).toHaveLength(1);
      if (results[0] && "err" in results[0].result) {
        expect(results[0].result.err).toContain("Unknown tool");
      } else {
        throw new Error("Expected unknown tool execution to fail");
      }
    });

    it("formats tool results for the next LLM round", async () => {
      const formatted = await testCanister.testToolExecutorFormatFixture();

      expect(formatted).toContain("Tool call call-1 result:");
      expect(formatted).toContain('{"ok":true}');
      expect(formatted).toContain("Tool call call-2 result:");
      expect(formatted).toContain("boom");
    });
  });
});
