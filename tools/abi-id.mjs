// SPDX-License-Identifier: MIT
// The ABI ids that commit to their functions (design §5.3, §5.11): one rule for the hot interface and both stores.
//
//   id = keccak256( bytes(name) ‖ for each function, sorted by selector ascending:
//                     selector (4 bytes) ‖ keccak256(bytes(canonical output tuple type string)) )
//
// The canonical output tuple is the ABI type string of the outputs with tuples expanded, for example
// `(uint8,uint64,bytes32)`, `()` for none and `((bytes32,uint8)[])` for an array of structs. Inputs are covered by the
// selector; events and errors are not part of the id. An id therefore changes when a function is added or removed or
// a return type changes, and does not change for a parameter or return name.
//
// `ABI_IDS` names each pinned id: its name string, the committed interface snapshot it is computed from, and every
// place it is pinned (a file and the regular expression whose first group is the pinned value). `pnpm abi:check`
// recomputes each id from the committed snapshot and fails when any pin differs (tools/abi-snapshot.mjs).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { keccak256 } from "./keccak.mjs";

const canonicalType = (p) =>
  p.type.startsWith("tuple") ? `(${p.components.map(canonicalType).join(",")})${p.type.slice(5)}` : p.type;
const signature = (item) => `${item.name}(${(item.inputs ?? []).map(canonicalType).join(",")})`;

/** The canonical output tuple type string of an ABI function item. */
export const outputTuple = (item) => `(${(item.outputs ?? []).map(canonicalType).join(",")})`;

/** The ABI id of `abi` (an array of ABI items) under `name`. */
export function abiId(name, abi) {
  const rows = abi
    .filter((i) => i.type === "function")
    .map((i) => ({ selector: keccak256(signature(i)).slice(2, 10), out: keccak256(outputTuple(i)).slice(2) }))
    .sort((a, b) => (a.selector < b.selector ? -1 : a.selector > b.selector ? 1 : 0));
  for (let i = 1; i < rows.length; i++) {
    if (rows[i].selector === rows[i - 1].selector) throw new Error(`abiId(${name}): duplicate selector 0x${rows[i].selector}`);
  }
  const bytes = Buffer.concat([Buffer.from(name, "utf8"), ...rows.map((r) => Buffer.from(r.selector + r.out, "hex"))]);
  return keccak256(bytes);
}

const HOT_PINS_TEST = [
  { file: "test/harness/KernelDeploy.sol", pattern: /HOT_ABI_ID\s*=\s*(0x[0-9a-fA-F]{64})/ },
  { file: "test/index/IndexDeployer.t.sol", pattern: /\bHOT\s*=\s*(0x[0-9a-fA-F]{64})/ },
];

/** Every ABI id this repository pins, with where it is pinned. */
export const ABI_IDS = [
  {
    name: "efs/ledger-hot/2",
    snapshot: "test/snapshots/abi/ILedgerHot.json",
    pins: [{ file: "tools/deploy-plan.mjs", pattern: /export const HOT_ABI_ID = "(0x[0-9a-fA-F]{64})"/ }],
  },
  { name: "efs/ledger-hot/2:test", snapshot: "test/snapshots/abi/ILedgerHot.json", pins: HOT_PINS_TEST },
  {
    name: "efs/posting-store/2",
    snapshot: "test/snapshots/abi/IPostingStore.json",
    pins: [
      { file: "src/index/PostingStore.sol", pattern: /STORE_ABI_ID\s*=\s*(0x[0-9a-fA-F]{64})/ },
      { file: "test/index/Stores.t.sol", pattern: /POSTING_STORE_ABI_ID\s*=\s*(0x[0-9a-fA-F]{64})/ },
    ],
  },
  {
    name: "efs/bitmap-store/1",
    snapshot: "test/snapshots/abi/IBitmapStore.json",
    pins: [
      { file: "src/index/BitmapStore.sol", pattern: /STORE_ABI_ID\s*=\s*(0x[0-9a-fA-F]{64})/ },
      { file: "test/index/Stores.t.sol", pattern: /BITMAP_STORE_ABI_ID\s*=\s*(0x[0-9a-fA-F]{64})/ },
    ],
  },
];

/** The id of an `ABI_IDS` entry computed from its committed snapshot under `root`. */
export const idFromSnapshot = (root, entry) =>
  abiId(entry.name, JSON.parse(readFileSync(join(root, entry.snapshot), "utf8")).abi);

/** The value pinned at `pin` under `root`, or null when the pattern does not match. */
export function pinnedValue(root, pin) {
  const m = readFileSync(join(root, pin.file), "utf8").match(pin.pattern);
  return m ? m[1].toLowerCase() : null;
}

/** Lines describing every pin that differs from its recomputed id (empty when all agree). */
export function checkPins(root) {
  const lines = [];
  for (const entry of ABI_IDS) {
    const id = idFromSnapshot(root, entry);
    for (const pin of entry.pins) {
      const have = pinnedValue(root, pin);
      if (have !== id) lines.push(`${entry.name}: ${pin.file} pins ${have ?? "(no match)"}, the committed ${entry.snapshot} gives ${id}`);
    }
  }
  return lines;
}

// `node tools/abi-id.mjs` prints every id from the committed snapshots.
if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(new URL(".", import.meta.url).pathname, "..");
  for (const entry of ABI_IDS) console.log(`${entry.name}  ${idFromSnapshot(root, entry)}`);
}
