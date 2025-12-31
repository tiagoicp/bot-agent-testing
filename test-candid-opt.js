// Test to understand how Candid encodes/decodes Option types
import { IDL } from "@dfinity/candid";

// Create an Option type
const AgentOpt = IDL.Opt(IDL.Record({
  'id': IDL.Nat,
  'name': IDL.Text,
  'provider': IDL.Variant({'openai': IDL.Null}),
  'model': IDL.Text,
}));

// Test encoding/decoding
console.log("OptClass definition:");
console.log("- ConstructType<[T] | []>");
console.log("- This means: either an array with one element [T], or an empty array []");
console.log("");

// When Motoko returns null (None in Option):
console.log("When Motoko returns null for ?Agent:");
console.log("- Gets encoded as empty array: []");
console.log("- Gets decoded back as: []");
console.log("");

// When Motoko returns ?Agent (Some):
console.log("When Motoko returns Some(Agent):");
console.log("- Gets encoded as: [agentObject]");
console.log("- Gets decoded back as: [agentObject]");
