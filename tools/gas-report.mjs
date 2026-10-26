// SPDX-License-Identifier: MIT
// gas/report.json: the §14 rows the Files recipe suite measures, on both schedules. It runs
// test/integration/FilesRecipes.t.sol twice with `--json -vv` — the default (prague, release bytes, out/) profile
// and the `amsterdam` profile (EIP-8037/8038, its own out/amsterdam + cache/amsterdam so the identity build in out/
// is never touched) — and reads the suite's `log_named_uint` lines: "<label> gas" (gasleft delta around
// `execute`, no intrinsic cost), "<label> frame gas" (the callee frame) and, under amsterdam, "<label> frame state
// gas". It adds the fixture's transaction receipts (prague, intrinsic included) from release/.fixture.json.
//
//   node tools/gas-report.mjs [--skip-amsterdam 1]
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs, root, toJSON } from "./deploy-plan.mjs";

const o = parseArgs(process.argv.slice(2), ["skip-amsterdam"]);
const SUITE = "test/integration/FilesRecipes.t.sol";
const git = (...args) => { try { return execFileSync("git", args, { cwd: root }).toString().trim(); } catch { return null; } };

function run(profile, suite = SUITE) {
  const env = { ...process.env, FOUNDRY_PROFILE: profile };
  if (profile !== "default") Object.assign(env, { FOUNDRY_OUT: `out/${profile}`, FOUNDRY_CACHE_PATH: `cache/${profile}` });
  const r = spawnSync("perl", ["-e", "alarm 900; exec @ARGV", "forge", "test", "--match-path", suite, "--json", "-vv"], { cwd: root, env, encoding: "utf8", timeout: 900_000, maxBuffer: 256 << 20 });
  const start = r.stdout.indexOf("{");
  assert.ok(start >= 0, `forge test (${profile}) printed no JSON (exit ${r.status}): ${r.stderr.slice(-3000)}`);
  const json = JSON.parse(r.stdout.slice(start));
  const out = {};
  Object.defineProperty(out, "raw", { value: {}, enumerable: false });
  for (const result of Object.values(json)) {
    for (const [test, res] of Object.entries(result.test_results)) {
      assert.equal(res.status, "Success", `${profile}: ${test} ${res.status} ${res.reason ?? ""}`);
      out.raw[test] = res.decoded_logs ?? [];
      for (const line of res.decoded_logs ?? []) {
        const m = line.match(/^(.*?) (frame state gas|frame gas|gas): (-?\d+)$/);
        if (!m) continue;
        const key = `${test}\u0000${m[1]}`;
        out[key] ??= {};
        const field = { gas: "gas", "frame gas": "frameGas", "frame state gas": "frameStateGas" }[m[2]];
        out[key][field] ??= Number(m[3]); // a label logged twice in one test keeps its first measurement
      }
    }
  }
  return out;
}

// §14 rows with the suite's step that measures each (conditions are the suite's, recorded per row)
const ROWS = [
  { row: "Root seed (CREATE + PUBLISH files-directory/1), first write of the principal", test: "test_root_seed()", label: "recipe root seed (CREATE + PUBLISH directory)", design: null },
  { row: "Native 1-leaf PUBLISH, steady", test: "test_child_parents_through_the_kernel()", label: "recipe publish directory", design: { prague: "≈ 0.50M", amsterdam: "≈ 1.66M" }, conditions: "files-directory/1, 32-byte body (the design row is 41 B / 2 words); the author has published before" },
  { row: "M1 create folder (CREATE, PUBLISH dir, PUBLISH name, BIND FOLDER), native", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe create folder", design: { prague: "≈ 1.2M", amsterdam: "≈ 4.0M" }, conditions: "first placement in the root folder (a fresh scope, not steady)" },
  { row: "M1 create file (5 leaves), native, no guard", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe create file", design: { prague: "≈ 1.5M", amsterdam: "≈ 5.4M" }, conditions: "first placement in a fresh folder; 18-byte inline document" },
  { row: "Edit (PUBLISH child + BIND HEAD rebind)", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe edit", design: { prague: "≈ 0.76M", amsterdam: "≈ 2.45M" } },
  { row: "Rename / move (PUBLISH name + UNBIND + BIND), native", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe rename + move", design: { prague: "≈ 1.0M", amsterdam: "≈ 3.2M" } },
  { row: "Remove (UNBIND; target word kept, no clear)", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe remove", design: { prague: "≈ 0.38M", amsterdam: "≈ 1.07M" } },
  { row: "Restore (BIND to a masked key, same target)", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe restore", design: { prague: "≈ 0.40M", amsterdam: "≈ 1.18M" } },
  { row: "RELEASE from mask, native", test: "test_mask_then_release_then_restore_a_placement()", label: "recipe release a removed placement", design: { prague: "≈ 0.38M", amsterdam: "≈ 1.07M" } },
  { row: "RELEASE from BOUND, native (not a §14 row)", test: "test_recipes_folder_file_edit_move_remove_restore_release()", label: "recipe release", design: null },
  { row: "Restore a released placement (BIND from RELEASED; §14 'Move-back' analog)", test: "test_mask_then_release_then_restore_a_placement()", label: "recipe restore a released placement", design: { prague: "≈ 0.41M", amsterdam: "≈ 1.2M" }, conditions: "same target, not a different old target" },
  { row: "WITHDRAW, native", test: "test_bind_before_its_parent_and_name_then_a_withdrawn_parent_stays_valid()", label: "recipe withdraw the directory occurrence", design: { prague: "≈ 0.40M", amsterdam: "≈ 1.1M" } },
];

const prague = run("default");
const amsterdam = o["skip-amsterdam"] ? null : run("amsterdam");
const pick = (m, r) => (m ? m[`${r.test}\u0000${r.label}`] ?? null : null);
const rows = ROWS.map((r) => ({ row: r.row, source: { suite: SUITE, test: r.test, label: r.label }, conditions: r.conditions ?? "as the suite runs it", prague: pick(prague, r), amsterdam: pick(amsterdam, r), designEstimate: r.design }));
for (const r of rows) assert.ok(r.prague, `${r.row}: no prague measurement for "${r.source.label}" in ${r.source.test}`);
const covered = new Set(ROWS.map((r) => `${r.test}\u0000${r.label}`));
const supplementary = Object.keys(prague).filter((k) => !covered.has(k)).sort().map((k) => {
  const [test, label] = k.split("\u0000");
  return { source: { suite: SUITE, test, label }, prague: prague[k], amsterdam: amsterdam?.[k] ?? null };
});

// the fixture's receipts (real transactions on anvil --hardfork prague; intrinsic + calldata included)
let fixture = null;
const statePath = join(root, "release/.fixture.json");
if (existsSync(statePath)) {
  const st = JSON.parse(readFileSync(statePath, "utf8"));
  const by = (p) => st.journal.filter((j) => p(j.id));
  const sum = (xs) => xs.reduce((s, j) => s + j.gasUsed, 0);
  fixture = {
    hardfork: "prague", chainId: st.chainId, startedAt: st.startedAt,
    rows: [
      { row: "Genesis code deposit (every CREATE2 of G1–G19 + RealmGenesis.run)", gasUsed: sum(by((id) => /^G(1[0-9]?|2c?|[3-9])(\.|$)/.test(id) && !id.startsWith("G11"))), transactions: by((id) => /^G(1[0-9]?|2c?|[3-9])(\.|$)/.test(id) && !id.startsWith("G11")).length },
      { row: "Descriptor blobs (G11, nine DescriptorStore.put)", gasUsed: sum(by((id) => id.startsWith("G11."))), transactions: 9 },
      { row: "Readers (R1 LensReader, R2 FilesPageReader, R3–R4 ReaderDirectory.list)", gasUsed: sum(by((id) => /^R[1-4]$/.test(id))), transactions: by((id) => /^R[1-4]$/.test(id)).length },
      { row: "Activation (genesis, G20)", gasUsed: sum(by((id) => id === "G20")), design: { prague: "≈ 1.1–1.9M", amsterdam: "≈ 3.5–4.3M" } },
      ...by((id) => id.startsWith("G21.")).map((j) => ({ row: `Described registration, NATIVE (${j.id})`, gasUsed: j.gasUsed, design: { prague: "≈ 0.30M", amsterdam: "≈ 1.55M" } })),
      ...by((id) => id.startsWith("G22.")).map((j) => ({ row: `Seed ${j.label}`, gasUsed: j.gasUsed })),
    ],
    journal: st.journal,
  };
}

// reads: the fixture's eth_estimateGas rows (prague) and the 1,000-entry traversal of test/readers/LargeDirectory.t.sol
const LARGE = "test/readers/LargeDirectory.t.sol";
const large = run("default", LARGE).raw;
const largeRows = Object.entries(large).sort().map(([test, logs]) => {
  const nums = (re) => logs.map((l) => l.match(re)).find(Boolean)?.slice(1).map(Number) ?? null;
  const head = logs.map((l) => l.match(/^(.*) pages \(calls\), rows (\d+) (\d+)$/)).find(Boolean);
  assert.ok(head, `${LARGE}:${test}: no summary line`);
  const [maxGas, totalGas] = nums(/^ {2}max gas per page, total gas (\d+) (\d+)$/);
  const [maxBytes, totalBytes] = nums(/^ {2}max returndata bytes per page, total (\d+) (\d+)$/);
  const pages = [];
  for (let i = 0; i < logs.length; i++) {
    const m = logs[i].match(/ page, rows, scanStatus (\d+) (\d+) (\d+)$/);
    const g = logs[i + 1]?.match(/^ {2}gas, returndata bytes (\d+) (\d+)$/);
    if (m && g) pages.push({ page: Number(m[1]), rows: Number(m[2]), scanStatus: Number(m[3]), gas: Number(g[1]), returndataBytes: Number(g[2]) });
  }
  return { row: `Read: 1,000-entry filtered folder through FilesPageReader.listDirectory (${head[1]})`, source: { suite: LARGE, test }, prague: { calls: Number(head[2]), rows: Number(head[3]), maxGasPerPage: maxGas, totalGas, maxReturndataBytesPerPage: maxBytes, totalReturndataBytes: totalBytes, pages } };
});
const fixtureReads = fixture ? JSON.parse(readFileSync(statePath, "utf8")).reads ?? [] : [];
const readRows = [
  ...fixtureReads.map((r) => ({ row: r.row, source: { fixture: "release/.fixture.json reads", to: r.to, function: r.function }, prague: { estimateGas: r.estimateGas, calldataBytes: r.calldataBytes, returndataBytes: r.returndataBytes, rpcCalls: r.rpcCalls }, note: r.note })),
  ...largeRows,
];

const report = {
  schema: "efs-gas-report/1",
  measurement: { commit: git("rev-parse", "HEAD"), dirtyFiles: (git("status", "--porcelain") || "").split("\n").filter(Boolean).length, date: new Date().toISOString(), foundry: execFileSync("forge", ["--version"]).toString().split("\n")[0].trim() },
  method: {
    suite: SUITE,
    prague: "FOUNDRY_PROFILE=default (evm prague, the release bytes)",
    amsterdam: amsterdam ? "FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam (solc experimental amsterdam target; never release bytes)" : "skipped",
    gas: "gasleft() delta around ILedger.execute inside the test (excludes the 21,000 intrinsic and calldata cost)",
    frameGas: "vm.lastFrameGas().gasTotalUsed of the execute call frame",
    frameStateGas: "vm.lastFrameGas().gasStateUsed (EIP-8037 state gas; absent when 0, i.e. always under prague)",
  },
  rows,
  supplementary,
  reads: readRows,
  fixtureReceipts: fixture,
  notCovered: [
    "fresh / rewritten / cleared slot counts, code bytes and accounts per row (needs a state-diff pass; §14 columns)",
    "tx.gas below and above 2^24 on amsterdam (the suite does not vary tx.gas)",
    "read rows on amsterdam (reads are unrepriced; prague only), confirm and recovery reads, LensReader.headsAt at 64 principals; the cold pin's call count is printed by `efs-fixture.mjs verify`",
    "20-edit staged save, signed lane, guards, CUSTOM registration, policy activation, freeze, kernel upgrade",
  ],
};
mkdirSync(join(root, "gas"), { recursive: true });
writeFileSync(join(root, "gas/report.json"), toJSON(report));
console.log(`gas-report: gas/report.json (${rows.length} §14 rows, ${readRows.length} read rows, ${supplementary.length} supplementary steps, prague${amsterdam ? " + amsterdam" : ""}${fixture ? `, ${fixture.journal.length} fixture receipts` : ""})`);
for (const r of readRows) console.log(`  ${r.row.slice(0, 110)}: ${JSON.stringify({ ...r.prague, pages: undefined })}`);
for (const r of rows) console.log(`  ${r.row.padEnd(78)} prague ${String(r.prague.gas).padStart(9)}${r.amsterdam ? `  amsterdam ${String(r.amsterdam.gas).padStart(9)} (state ${r.amsterdam.frameStateGas ?? 0})` : ""}`);
