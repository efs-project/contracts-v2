// SPDX-License-Identifier: MIT
// Binding-number vectors (design §6.4, `efs/vectors/numbers/1`): the shape law of `Action.saltOrStrength` on the
// bind kinds, the signed number a head carries for each state and strength, and the ABI encoding and actionsHash of
// the builders a client uses for a bind with a strength and for a lone negative, so an SDK's encoder, validator and
// number decoder can be checked against the contracts exactly. Computed here in JS (viem's ABI encoder and
// keccak256; the law written from the NatSpec of `src/interfaces/Actions.sol`), never by Solidity.
// `tools/release.mjs` writes test/vectors/numbers.json and `pnpm release:check` compares it byte for byte;
// `test/unit/kernel/NumberVectors.t.sol` asserts every vector against `BindingNumber`, the kernel and `EfsFiles`.
// Nothing here depends on the release build, so the file changes only when the law does.
import { encodeAbiParameters, keccak256, pad, stringToHex, toHex } from "viem";

export const MAX_STRENGTH = 65_535;
const KIND = { BIND: 3, UNBIND: 4, CREATE: 5, RELEASE: 7 };
const ZERO = pad("0x", { size: 32 });
const h = (s) => keccak256(stringToHex(s));
const word = (n) => pad(toHex(n), { size: 32 });
const ACTION_TUPLE = {
  type: "tuple[]",
  components: [
    { name: "kind", type: "uint8" }, { name: "typeId", type: "bytes32" }, { name: "bodyHashOrRecordId", type: "bytes32" },
    { name: "purpose", type: "bytes32" }, { name: "subject", type: "bytes32" }, { name: "role", type: "bytes32" },
    { name: "target", type: "bytes32" }, { name: "expectedRevision", type: "uint64" }, { name: "saltOrStrength", type: "bytes32" },
  ],
};

/** The signed number of a head (`BindingNumber.numberOf`): BOUND → strength, MASKED → -1 - strength, else none. */
export function numberOf(state, strength) {
  if (state === 1) return { has: true, number: strength };
  if (state === 2) return { has: true, number: -1 - strength };
  return { has: false, number: 0 };
}

/** The kernel's verdict on a bind kind's `saltOrStrength` word: 0 admitted, else the `E_SHAPE` code (always 2). */
export function strengthShapeCode(kind, value) {
  const max = kind === KIND.RELEASE ? 0n : BigInt(MAX_STRENGTH);
  return BigInt(value) > max ? 2 : 0;
}

/** The builders: BIND stating `strength`, UNBIND stating `-1 - strength`, a lone negative (UNBIND, revision 0). */
export const bindAction = ({ purpose, subject, role, target, expectedRevision = 0n, strength = 0 }) =>
  ({ kind: KIND.BIND, typeId: ZERO, bodyHashOrRecordId: ZERO, purpose, subject, role, target, expectedRevision: BigInt(expectedRevision), saltOrStrength: word(strength) });
export const unbindAction = ({ purpose, subject, role, expectedRevision = 0n, strength = 0 }) =>
  ({ ...bindAction({ purpose, subject, role, target: ZERO, expectedRevision, strength }), kind: KIND.UNBIND });
export const loneNegativeAction = ({ purpose, subject, role, strength = 0 }) => unbindAction({ purpose, subject, role, expectedRevision: 0n, strength });

export const actionsHash = (actions) => keccak256(encodeAbiParameters([ACTION_TUPLE], [actions]));

export function numberVectors() {
  const values = [
    ["zero", 0n], ["one", 1n], ["255", 255n], ["256", 256n], ["the maximum", 65_535n], ["the maximum + 1", 65_536n],
    ["2^24", 1n << 24n], ["low bits 7 with a high bit", (1n << 200n) | 7n], ["only the top bit", 1n << 255n],
  ];
  const shape = [];
  for (const [kindName, kind] of [["BIND", KIND.BIND], ["UNBIND", KIND.UNBIND], ["RELEASE", KIND.RELEASE]]) {
    for (const [label, v] of values) {
      shape.push({ label: `${kindName}, ${label}`, kind, saltOrStrength: pad(toHex(v), { size: 32 }), code: strengthShapeCode(kind, v) });
    }
  }
  const numbers = [];
  for (const state of [0, 1, 2, 3]) {
    for (const strength of [0, 1, 4, 75, 65_535]) numbers.push({ state, strength, ...numberOf(state, strength) });
  }
  const TAG = h("efs/purpose/tag/1");
  const topic = h("vectors/numbers/topic");
  const thing = h("vectors/numbers/thing");
  const address = pad("0x00000000000000000000000000000000000ba5ed", { size: 32 });
  const builders = [
    { label: "bind with strength 75 (+75), fresh", builder: "EfsFiles.bindWithStrength(TAG, topic, thing, thing, 0, 75)", number: 75, action: bindAction({ purpose: TAG, subject: topic, role: thing, target: thing, strength: 75 }) },
    { label: "number change 75 -> 3 on a bound head at revision 1", builder: "EfsFiles.bindWithStrength(TAG, topic, thing, thing, 1, 3)", number: 3, action: bindAction({ purpose: TAG, subject: topic, role: thing, target: thing, expectedRevision: 1n, strength: 3 }) },
    { label: "a lone negative (-1)", builder: "EfsFiles.loneNegative(TAG, topic, thing, 0)", number: -1, action: loneNegativeAction({ purpose: TAG, subject: topic, role: thing }) },
    { label: "a lone negative on an address (-65,536)", builder: "EfsFiles.loneNegative(TAG, topic, address, 65535)", number: -65_536, action: loneNegativeAction({ purpose: TAG, subject: topic, role: address, strength: 65_535 }) },
    { label: "a negative number change -1 -> -5 at revision 1", builder: "EfsFiles.unbindWithStrength(TAG, topic, thing, 1, 4)", number: -5, action: unbindAction({ purpose: TAG, subject: topic, role: thing, expectedRevision: 1n, strength: 4 }) },
  ].map((b) => ({ ...b, actionsHash: actionsHash([b.action]) }));
  return {
    schema: "efs/vectors/numbers/1",
    generator: "tools/number-vectors.mjs via tools/release.mjs (viem encodeAbiParameters + keccak256; the law from src/interfaces/Actions.sol)",
    spec: "docs/DESIGN.md §6.4; BindingNumber (src/interfaces/Actions.sol)",
    law: {
      field: "Action.saltOrStrength: CREATE = the creator salt; BIND and UNBIND = an unsigned strength 0..65,535; RELEASE = 0; every other kind 0",
      refusal: "a strength above 65,535 (any nonzero word on RELEASE) is E_SHAPE(leaf, 2), never truncated",
      number: "BOUND: strength; MASKED: -1 - strength; UNSET, RELEASED and reserved states: no number. BIND states strength, UNBIND states -1 - strength, RELEASE states nothing",
      unbind: "admitted from every state (UNSET, BOUND, MASKED, RELEASED) under expectedRevision; from UNSET it is a FIRST_MASK (transition 6)",
    },
    maxStrength: MAX_STRENGTH,
    ids: { TAG, topic, thing, address },
    shape,
    numbers,
    builders,
  };
}

// `node tools/number-vectors.mjs` writes test/vectors/numbers.json alone (`pnpm release` writes it too, and
// `pnpm release:check` compares it).
if (import.meta.url === `file://${process.argv[1]}`) {
  const { writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { root, toJSON } = await import("./deploy-plan.mjs");
  const out = join(root, "test/vectors/numbers.json");
  const doc = numberVectors();
  writeFileSync(out, toJSON(doc));
  console.log(`number vectors: wrote ${out} (${doc.shape.length} shape cases, ${doc.numbers.length} numbers, ${doc.builders.length} builders)`);
}
