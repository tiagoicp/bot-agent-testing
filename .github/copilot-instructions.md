# Copilot Instructions for bot-agent-testing

## Project Overview

This is an **ICP (Internet Computer Protocol)** decentralized application built with:

- **Motoko** for smart contract backend (`src/bot-agent-backend/`)
- **TypeScript** for tests (`tests/`) using PocketIC for local testing
- **Bun** as the package manager and runtime

## Important: Package Manager

**Use `bun` commands only.** Do NOT use `npm` or `npx` commands.

Examples:

- `bun install` - Install dependencies
- `bun run <script>` - Run scripts from package.json
- `bun test` - Run tests
- `bun run format` - Run code formatter
- `bun run lint` - Run linter

## Architectural Patterns

### Guard Rails vs Service Logic

**Guard rails (authentication, authorization, validation)** must be implemented at the **controller level (main.mo)**, not buried inside service functions.

## How to Verify Your Work

### For Motoko Code

Use dfx build with the `--check` flag to verify Motoko code without creating canisters:

```bash
# Check Motoko files for compilation errors
dfx build bot-agent-backend --check
```

### For TypeScript Tests

Use the TypeScript compiler to verify test code:

```bash
# Type-check TypeScript without emitting
bun run tsc --noEmit
```
