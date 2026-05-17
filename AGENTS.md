# AGENTS Instructions

## Project Overview

This is an **ICP (Internet Computer Protocol)** decentralized application built with:

- **Motoko** for smart contract backend (`src/control-plane-core/`)
- **TypeScript** for tests (`tests/`) using PocketIC for local testing
- **Bun** as the package manager and runtime

## Important: CLI Tooling — Use `icp`, Never `dfx`

**NEVER use `dfx`** — this project uses the **`icp` CLI** exclusively for all
Internet Computer operations (build, deploy, canister management, identity, etc.).

Any command you would associate with `dfx` (e.g. `dfx build`, `dfx deploy`,
`dfx canister call`) probably has a direct `icp` equivalent. Consult the `icp-cli` skill
or run `icp --help` when in doubt. Using `dfx` will break the project's toolchain.

## Important: Package Manager

Use **`bun` for local project dependencies and scripts**.

Use **`npm` for global CLI tool installs** (tools typically installed with `-g`).
This exception is especially relevant in **CI workflows** and **Codespaces/devcontainer setup**.

Examples:

- `bun install` - Install dependencies
- `bun run <script>` - Run scripts from package.json
- `bun run test` - Run full tests flow
- `bun run test:build` - Rebuild canisters when src code modified
- `bun run test:control-plane-core` - Run all control-plane-core tests
- `bun run test:internal-engine` - Run all internal-engine tests
- `bun run test:ts-parallel` - Run both TypeScript suites in parallel
- `bun run format` - Run code formatter
- `bun run lint` - Run linter

Global CLI install examples (allowed/preferred):

- `npm install -g ic-mops`
- `npm install -g @dfinity/pic`

### Running Specific Tests

**IMPORTANT:** To run specific test files or individual tests, use `bun test` directly (NOT `bun run test`).

The `bun run test` script runs a complete build and test suite and does NOT accept additional parameters.

Examples:

```bash
# Run a specific test file
bun test tests/control-plane-core/integration-tests/workspace-admin-talk.spec.ts

# Run a specific test case by name (using -t flag)
bun test tests/control-plane-core/integration-tests/workspace-admin-talk.spec.ts -t "should accept message from workspace admin"

# Record cassettes for a specific test file
RECORD_CASSETTES=true bun test tests/control-plane-core/integration-tests/workspace-admin-talk.spec.ts
```

## Library Dependencies

### mo:base is Deprecated - Use mo:core

**NEVER use `mo:base`** - it is deprecated and unmaintained. Use **`mo:core`** instead.

- `mo:core` is the modern successor to `mo:base`.
- All standard modules are available in `mo:core` (Array, Blob, Principal, Timer, Text, etc.)
- If you encounter compatibility issues, check the module definitions in `.mops/core@{version}/src/` for the correct API

## When to Request Feedback (CRITICAL)

**IMPORTANT:** **STOP and REQUEST USER FEEDBACK** before proceeding in these situations:

### Design Decision Blockers

- **Feature removal or significant reduction in scope** (e.g., removing web search capability, disabling a planned feature)
- **Architecture changes** that affect multiple files or core patterns
- **API contract changes** that impact external integrations or user-facing behavior
- **Performance trade-offs** where there are multiple valid approaches with different costs
- **Security or privacy implications** (encryption, authentication, data access)

### Technical Blockers

- **Multiple solution paths exist** with unclear "best" choice
- **External dependency limitations** (API doesn't support intended feature, library missing capability)
- **Breaking changes required** to existing tests or production code
- **Workarounds needed** that compromise original requirements

### Challenge Requests That Break Existing Invariants

**Even when the user's intent is clear, push back if the requested change would:**

- Corrupt data semantics (e.g. storing the wrong agent name in a metadata field that downstream logic depends on)
- Break a chain/lineage invariant established in a prior task
- Produce a worse user-facing outcome than the current design (e.g. a Slack message labelling a reply from `::admin` as `::research`)

**Do not implement first and revert later.** Stop, explain the specific invariant that would be violated, and confirm before touching anything.

Example of the right response:

> "If I use the incoming `parent_agent` as the outgoing `parent_agent`, a reply from `::admin` would be labelled as `::research` in the metadata — which would route follow-up messages to the wrong agent. Is that intentional, or should `parent_agent` remain the name of the agent that authored this reply?"

### How to Request Feedback

When you encounter a blocking decision, **use the `ask_questions` tool** to surface the decision to the user before proceeding. Do not ask in free text — the tool formats the question clearly and lets the user respond quickly.

Steps:

1. **Stop immediately** - do not implement a solution
2. **Use `ask_questions`**: frame the situation, present 2-3 options (with pros/cons), and mark your recommended option
3. **Wait for user decision** before coding

**Example**:

> "I discovered that Groq's Responses API doesn't support the built-in web search tool. I have three options:
>
> 1. **Remove web search** from planning (simplest, but loses key feature)
> 2. **Integrate Compound API** (enables web search, but adds complexity)
> 3. **Implement custom HTTP outcall** for search (full control, most work)
>
> I recommend option 2 (Compound API) since web search was a core requirement. Should I proceed with that approach?"

## Architectural Patterns

## Motoko Conventions

- **Model function parameter order**: all model functions must place the state/collection parameter **first**. This aligns with `mo:core` idioms (e.g. `Map.get(map, compare, key)`) and makes partial application natural.
- **`Nat` is a subtype of `Int`** (`Nat <: Int`): a `Nat` value can be passed wherever an `Int` is expected. Do not add explicit casts or conversions when a function parameter is typed `Int` and the caller has a `Nat` — it is already valid.

### Tool and ExecutionApi Response Contract

All tool handlers (`ToolCallOutcome`) and the `executionApi` endpoint must produce structured JSON responses:

- **`#ok : Text`** — a meaningful JSON result. Never include a `"success": true` wrapper key.
- **`#err : Text`** — always `{"type":"camelCaseIdentifier","message":"Human readable sentence."}`. **Never a plain string.**
  - `type`: stable programmatic camelCase identifier (e.g. `"parseError"`, `"unauthorized"`, `"missingField"`).
  - `message`: human-readable sentence.
- Variant names are `#ok`/`#err` (not `#success`/`#error`) to align with the ICP `Result` pattern.

### Guard Rails vs Service Logic

**Guard rails (authentication, authorization, validation)** must be implemented at the **controller level (main.mo)**, not buried inside service functions.

## Testing Practices

### Cassettes Are NEVER Written Manually

**NEVER create or edit cassette files (`.json` files under `tests/cassettes/`) by hand.**

Cassettes must always be generated by running the real test with `RECORD_CASSETTES=true`, which makes live HTTP calls and saves the real responses. Manually authored cassettes will contain fake channel IDs / fake API responses that do not reflect the real Slack workspace and will cause assertion failures.

Rules:

- **Do NOT create cassette `.json` files.** You should run `RECORD_CASSETTES=true bun test <file>` to record them.
- **Do NOT edit existing cassette `.json` files.** If a cassette is wrong, re-record yourself.
- **Cassettes that require real Slack channels must use resolver helpers** (`resolveOrgAdminChannel`, `resolveSpecsChannelForInfo`, `resolveSpecsChannel`) so the channel ID stays consistent between record and playback sessions.

### Prefer `expect` Over `assert`

In Motoko tests, **use `expect` syntax instead of `assert`**. The `expect` API provides better error messages with actual vs expected values.

Refer to `.mops/test@{version}/README.md` for complete `expect` documentation and examples.

## How to Verify Your Work

**Always start by checking for errors using the get_errors tool.** This catches compilation errors, type issues, and lint warnings. Once confirmed, use the language-specific checks below.

### For Motoko Code

Use icp build to verify Motoko src code without creating canisters:

```bash
# Check Motoko files for compilation errors
icp build control-plane-core
```

If it's tests written in Motoko you modified, run the mops test instead:

```bash
# Run Motoko tests
mops test
```

### For TypeScript Code

Use the TypeScript compiler to verify integration tests code:

```bash
# Type-check TypeScript without emitting
bun run tsc --noEmit
```

## Architecture

Please be aware of an [ARCHITECTURE.md](../ARCHITECTURE.md) file in the repository that provides detailed information about the system architecture, design decisions, and component interactions. Reviewing this document will help you understand the overall structure and design principles of the project.
