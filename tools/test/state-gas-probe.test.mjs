// SPDX-License-Identifier: MIT
// tools/state-gas-probe.mjs, offline: the probe's code, the batch it sends, and how it reads replies. The replies
// below are what Sepolia's two clients answered on 2026-11-26 (docs/GAS-SCHEDULES.md); no network is used here.
import assert from "node:assert/strict";
import { test } from "node:test";
import { CASES, ESTIMATES, batch, probeCode, rows, verdict } from "../state-gas-probe.mjs";

const word = (n) => BigInt(n).toString(16).padStart(64, "0");
const two = (entry, drawn) => "0x" + word(entry) + word(drawn);

// eth_estimateGas for 20, 100 and 200 fresh slots: the same on both clients, execution plus state gas
const ESTIMATED = { 20: 2_235_141, 100: 11_110_304, 200: 22_204_258 };

/** A batch reply built from `[entry, drawn]` per case, for the validated simulation and for plain eth_call. */
function reply(client, simulated, called, gasUsed, estimated = ESTIMATED) {
  const out = [{ jsonrpc: "2.0", id: "client", result: client }];
  CASES.forEach((_, i) => {
    out.push({ jsonrpc: "2.0", id: `simulate-${i}`, result: [{ calls: [{ status: "0x1", gasUsed: "0x" + gasUsed[i].toString(16), returnData: two(...simulated[i]) }] }] });
    out.push({ jsonrpc: "2.0", id: `call-${i}`, result: two(...called[i]) });
  });
  for (const n of ESTIMATES) if (estimated[n]) out.push({ jsonrpc: "2.0", id: `estimate-${n}`, result: "0x" + estimated[n].toString(16) });
  return out;
}

// n = 20 at 10M and 30M; n = 100 at 2^24, 30M and 60M
const VALIDATED = [
  [9_984_998, 2_201_360],
  [16_762_214, 242_960],
  [16_762_214, 11_006_640],
  [16_762_214, 1_214_640],
  [16_762_214, 1_214_640],
];
const GAS_USED = [2_216_383, 2_216_383, 11_021_663, 11_021_663, 11_021_663];
// Geth 1.17.9's plain eth_call: ordinary gas is not capped, so state gas is drawn from it at every gas limit
const GETH_CALL = [
  [9_984_998, 2_201_360],
  [29_984_998, 2_201_360],
  [16_762_214, 11_006_640],
  [29_984_998, 11_006_640],
  [59_984_998, 11_006_640],
];

test("the probe's code is the loop it documents", () => {
  // GAS; PUSH2 20; loop: JUMPDEST DUP1 ISZERO PUSH1 end JUMPI; PUSH1 1 DUP2 SSTORE; PUSH1 1 SWAP1 SUB; PUSH1 loop
  // JUMP; end: JUMPDEST POP; DUP1 PUSH1 0 MSTORE; GAS SWAP1 SUB; PUSH1 32 MSTORE; PUSH1 64 PUSH1 0 RETURN
  assert.equal(probeCode(20), "0x5a6100145b801560155760018155600190036004565b50806000525a900360205260406000f3");
  assert.equal(probeCode(0x1234).slice(4, 10), "611234".slice(0, 6));
  assert.throws(() => probeCode(0));
  assert.throws(() => probeCode(65536));
});

test("one batch asks the client and both readings of every case", () => {
  const b = batch();
  assert.equal(b.length, 1 + 2 * CASES.length + ESTIMATES.length);
  assert.equal(b[0].method, "web3_clientVersion");
  const sim = b.filter((q) => q.method === "eth_simulateV1");
  assert.equal(sim.length, CASES.length);
  for (const q of sim) assert.equal(q.params[0].validation, true);
  // nothing is sent: only calls that read
  for (const q of b) assert.ok(["web3_clientVersion", "eth_simulateV1", "eth_call", "eth_estimateGas"].includes(q.method));
});

test("reth: the reservoir shows in both readings", () => {
  const r = rows(reply("reth/v2.11.0", VALIDATED, VALIDATED, GAS_USED));
  assert.equal(r.client, "reth/v2.11.0");
  assert.deepEqual(verdict(r), { pricing: "eip-8037", reservoir: true, estimateCountsStateGas: true });
  const above = r.rows.find((x) => x.how === "eth_call" && x.n === 100 && x.gas === 30_000_000);
  assert.equal(above.entry, 16_762_214);
});

test("Geth: the validated reading shows the reservoir, plain eth_call does not", () => {
  const r = rows(reply("Geth/v1.17.9", VALIDATED, GETH_CALL, GAS_USED));
  // the verdict reads only the validated rows
  assert.deepEqual(verdict(r), { pricing: "eip-8037", reservoir: true, estimateCountsStateGas: true });
  // the estimate for 200 fresh slots is above 2^24: a gas limit taken from it must not be clamped at the cap
  assert.ok(r.estimates.find((e) => e.n === 200).estimate > 1 << 24);
  const call = r.rows.find((x) => x.how === "eth_call" && x.n === 100 && x.gas === 30_000_000);
  assert.equal(call.entry, 29_984_998); // not capped at 2^24
  assert.ok(call.perSlot > 100_000); // state gas drawn from ordinary gas
  const sim = r.rows.find((x) => x.how.startsWith("simulate") && x.n === 100 && x.gas === 30_000_000);
  assert.equal(sim.entry, 16_762_214);
  assert.ok(sim.perSlot < 13_000);
  // gas used is the same above and below the cap: the reservoir changes where gas is drawn from, not what is paid
  const used = r.rows.filter((x) => x.how.startsWith("simulate") && x.n === 100).map((x) => x.gasUsed);
  assert.deepEqual(new Set(used), new Set([11_021_663]));
});

test("a Prague chain is read as Prague, and shows no reservoir", () => {
  const prague = CASES.map(({ n, gas }) => [gas - 21_002, n * 22_148]);
  const r = rows(reply("anvil/1.8.3", prague, prague, CASES.map(({ n }) => 21_000 + n * 22_148), {}));
  assert.deepEqual(verdict(r), { pricing: "prague", reservoir: null, estimateCountsStateGas: null });
});

test("an error reply is reported as a row, not thrown", () => {
  const bad = [
    { jsonrpc: "2.0", id: "client", result: "x" },
    { jsonrpc: "2.0", id: "simulate-0", error: { code: -32601, message: "the method eth_simulateV1 does not exist" } },
  ];
  const r = rows(bad);
  assert.match(r.rows[0].error, /eth_simulateV1/);
  assert.deepEqual(verdict(r), { pricing: "unknown", reservoir: null, estimateCountsStateGas: null });
});

test("an estimate that counted execution only is read as such", () => {
  const r = rows(reply("x", VALIDATED, VALIDATED, GAS_USED, { 20: 260_000, 100: 1_230_000 }));
  assert.equal(verdict(r).estimateCountsStateGas, false);
});
