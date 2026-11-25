// SPDX-License-Identifier: MIT
// The ABI-id rule of tools/abi-id.mjs on small fixture ABIs: adding a function, removing one or changing a return type
// changes the id; renaming a parameter or a return value, reordering the ABI and adding an event or error do not.
import assert from "node:assert/strict";
import { test } from "node:test";
import { abiId, outputTuple } from "../abi-id.mjs";
import { keccak256 } from "../keccak.mjs";

const fn = (name, inputs, outputs) => ({
  type: "function",
  name,
  stateMutability: "view",
  inputs: inputs.map((type, i) => ({ name: `a${i}`, type, internalType: type })),
  outputs: outputs.map((o, i) => (typeof o === "string" ? { name: `r${i}`, type: o, internalType: o } : { name: `r${i}`, ...o })),
});
const base = () => [
  fn("counts", [], ["uint64", "uint64", "uint64", "uint64"]),
  fn("head", ["bytes32"], ["uint8", "uint64", "bytes32"]),
  fn("index", [], ["address"]),
];

test("the id is keccak(name ‖ selector ‖ keccak(output tuple), by selector)", () => {
  const abi = [fn("b", [], ["uint8"]), fn("a", ["uint256"], [])];
  const rows = abi
    .map((i) => ({ sel: keccak256(`${i.name}(${i.inputs.map((p) => p.type).join(",")})`).slice(2, 10), out: keccak256(outputTuple(i)).slice(2) }))
    .sort((x, y) => (x.sel < y.sel ? -1 : 1));
  const expected = keccak256(Buffer.concat([Buffer.from("n"), ...rows.map((r) => Buffer.from(r.sel + r.out, "hex"))]));
  assert.equal(abiId("n", abi), expected);
  assert.equal(outputTuple(abi[0]), "(uint8)");
  assert.equal(outputTuple(abi[1]), "()");
});

test("tuples are expanded in the output tuple", () => {
  const f = fn("t", [], [{ type: "tuple[]", components: [{ name: "x", type: "bytes32" }, { name: "y", type: "uint8" }] }]);
  assert.equal(outputTuple(f), "((bytes32,uint8)[])");
});

test("adding, removing or retyping a function changes the id", () => {
  const id = abiId("efs/x/1", base());
  assert.notEqual(abiId("efs/x/1", [...base(), fn("extra", [], ["bool"])]), id, "added");
  assert.notEqual(abiId("efs/x/1", base().slice(1)), id, "removed");
  const retyped = base();
  retyped[1] = fn("head", ["bytes32"], ["uint8", "uint64", "bytes32", "uint16"]);
  assert.notEqual(abiId("efs/x/1", retyped), id, "return type changed");
  const reinput = base();
  reinput[1] = fn("head", ["bytes32", "uint256"], ["uint8", "uint64", "bytes32"]);
  assert.notEqual(abiId("efs/x/1", reinput), id, "inputs changed (a new selector)");
  assert.notEqual(abiId("efs/x/2", base()), id, "name changed");
});

test("names, order, events and errors do not change the id", () => {
  const id = abiId("efs/x/1", base());
  const renamed = base().map((i) => ({ ...i, outputs: i.outputs.map((o) => ({ ...o, name: `z${o.name}` })) }));
  assert.equal(abiId("efs/x/1", renamed), id);
  assert.equal(abiId("efs/x/1", [...base()].reverse()), id);
  const extra = [...base(), { type: "event", name: "E", inputs: [], anonymous: false }, { type: "error", name: "X", inputs: [] }];
  assert.equal(abiId("efs/x/1", extra), id);
});

test("the committed pins match, and the gate names a pin that differs", async () => {
  const { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { dirname, join } = await import("node:path");
  const { ABI_IDS, checkPins } = await import("../abi-id.mjs");
  const repo = join(dirname(new URL(import.meta.url).pathname), "..", "..");
  assert.deepEqual(checkPins(repo), [], "the committed tree's pins match its snapshots");
  const tmp = mkdtempSync(join(tmpdir(), "abi-id-"));
  try {
    const files = new Set(ABI_IDS.flatMap((e) => [e.snapshot, ...e.pins.map((p) => p.file)]));
    for (const f of files) {
      mkdirSync(join(tmp, dirname(f)), { recursive: true });
      copyFileSync(join(repo, f), join(tmp, f));
    }
    const snap = JSON.parse(readFileSync(join(tmp, "test/snapshots/abi/IPostingStore.json"), "utf8"));
    snap.abi = snap.abi.filter((i) => i.name !== "appendBatch"); // a store without appendBatch
    writeFileSync(join(tmp, "test/snapshots/abi/IPostingStore.json"), JSON.stringify(snap));
    const lines = checkPins(tmp);
    assert.equal(lines.length, 2, "both posting-store pins are named");
    assert.ok(lines.every((l) => l.startsWith("efs/posting-store/1:")));
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
