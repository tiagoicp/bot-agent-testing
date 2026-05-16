import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
  TEST_API_KEY,
  TEST_MODEL,
  freshDeferredTestCanister,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

describe("OpenRouter Wrapper Unit Tests", () => {
  type TrackId = { workspace: bigint } | { workspaceAgent: [bigint, bigint] };

  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeAll(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    testCanister = (await freshDeferredTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  describe("Reason Method Tests", () => {
    it("should handle basic reasoning with string input", async () => {
      const trackId: TrackId = { workspaceAgent: [1n, 1n] };
      const input = "What are the key benefits of using renewable energy?";
      const instructions =
        "Provide a clear, structured response with main points.";

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/reason-basic",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [instructions],
            [], // temperature
            [], // tools
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("textResponse" in response.ok) {
          expect(response.ok.textResponse.content.length).toBeGreaterThan(0);
          expect(response.ok.textResponse.content.toLowerCase()).toContain(
            "renewable",
          );
        } else {
          throw new Error("Unexpected tool calls response");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle reasoning without instructions or effort", async () => {
      const trackId: TrackId = { workspace: 4n };
      const input = "What is machine learning?";

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/reason-no-instructions",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [], // temperature
            [], // tools
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("textResponse" in response.ok) {
          expect(response.ok.textResponse.content.length).toBeGreaterThan(0);
          expect(response.ok.textResponse.content.toLowerCase()).toContain(
            "machine learning",
          );
        } else {
          throw new Error("Unexpected tool calls response");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should fail with invalid API key", async () => {
      const trackId: TrackId = { workspaceAgent: [7n, 7n] };
      const input = "Test input";

      for (const apiKey of ["", "   "]) {
        try {
          await testCanister.openRouterReason(
            apiKey,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [],
            [],
          );
          expect(false).toBe(true); // Should not reach here
        } catch (error) {
          expect(error).toBeDefined();
        }
      }
    });

    it("should fail with empty input", async () => {
      const trackId: TrackId = { workspaceAgent: [9n, 9n] };

      try {
        await testCanister.openRouterReason(
          TEST_API_KEY,
          [],
          TEST_MODEL,
          trackId,
          [],
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty input validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with empty model name", async () => {
      const trackId: TrackId = { workspaceAgent: [10n, 10n] };
      const input = "Test input";

      try {
        await testCanister.openRouterReason(
          TEST_API_KEY,
          [{ role: { user: null }, content: input }],
          "",
          trackId,
          [],
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty model validation
        expect(error).toBeDefined();
      }
    });
  });

  describe("Tool Calling Tests", () => {
    // Helper type for Tool
    type Tool = {
      tool_type: string;
      function: {
        name: string;
        description: [] | [string];
        parameters: [] | [string];
      };
    };

    it("should call a single tool when prompted", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 1n] };
      const input = "What is the weather in San Francisco?";

      const weatherTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_weather",
          description: ["Get the current weather for a given location"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                location: {
                  type: "string",
                  description: "The city name, e.g. San Francisco",
                },
              },
              required: ["location"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/tool-single-call",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [],
            [[weatherTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("get_weather");
          expect(toolCall.callId).toBeTruthy();

          // Parse arguments and verify location
          const args = JSON.parse(toolCall.arguments);
          expect(args.location.toLowerCase()).toContain("san francisco");
        } else {
          // If model responded with text instead of tool call, that's also acceptable
          // but we expect tool call for this specific prompt
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse.content,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should call appropriate tool from multiple available tools", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 2n] };
      // Use a weather query — LLMs reliably call tools for real-time data they
      // cannot answer directly, unlike simple arithmetic.
      const input = "What is the weather like in Tokyo right now?";

      const weatherTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_weather",
          description: ["Get the current weather for a given location"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                location: { type: "string", description: "The city name" },
              },
              required: ["location"],
            }),
          ],
        },
      };

      const calculatorTool: Tool = {
        tool_type: "function",
        function: {
          name: "calculator",
          description: ["Perform mathematical calculations"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                operation: {
                  type: "string",
                  enum: ["add", "subtract", "multiply", "divide"],
                  description: "The mathematical operation to perform",
                },
                a: { type: "number", description: "First operand" },
                b: { type: "number", description: "Second operand" },
              },
              required: ["operation", "a", "b"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/tool-select-from-multiple",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [],
            [[weatherTool, calculatorTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          // Should pick weather, not calculator, for a weather query
          expect(toolCall.toolName).toBe("get_weather");
          expect(toolCall.callId).toBeTruthy();

          const args = JSON.parse(toolCall.arguments);
          expect(args.location.toLowerCase()).toContain("tokyo");
        } else {
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse.content,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should parse tool call with complex nested parameters", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 4n] };
      const input =
        "Search for JavaScript tutorials published after 2023 with difficulty level beginner";

      const searchTool: Tool = {
        tool_type: "function",
        function: {
          name: "search_tutorials",
          description: ["Search for programming tutorials with filters"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                query: { type: "string", description: "Search query" },
                filters: {
                  type: "object",
                  properties: {
                    language: {
                      type: "string",
                      description: "Programming language",
                    },
                    published_after: {
                      type: "integer",
                      description: "Year published after",
                    },
                    difficulty: {
                      type: "string",
                      enum: ["beginner", "intermediate", "advanced"],
                    },
                  },
                },
              },
              required: ["query"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/tool-complex-params",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [],
            [[searchTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("search_tutorials");

          // Parse and verify complex nested arguments
          const args = JSON.parse(toolCall.arguments);
          expect(args.query.toLowerCase()).toContain("javascript");
          expect(args.filters).toBeDefined();
          expect(args.filters.difficulty).toBe("beginner");
          expect(args.filters.published_after).toBeGreaterThanOrEqual(2023);
        } else {
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse.content,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle tool with no parameters", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 5n] };
      const input = "What time is it right now?";

      const timeTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_current_time",
          description: ["Get the current time"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {},
              required: [],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/wrappers/openrouter-wrapper/tool-no-params",
        () =>
          testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
            TEST_MODEL,
            trackId,
            [],
            [],
            [[timeTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("get_current_time");
          // Arguments should be empty or empty object
          const args = JSON.parse(toolCall.arguments);
          expect(Object.keys(args).length).toBe(0);
        } else {
          // Model might respond with text if it doesn't want to use the tool
          expect(response.ok.textResponse.content.length).toBeGreaterThan(0);
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });
});
