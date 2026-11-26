// SPDX-License-Identifier: MIT
// A read-only probe of how a chain charges for fresh storage slots, and from where (docs/GAS-SCHEDULES.md, "What
// counts against the 2^24 cap, and where state gas comes from"). It answers two questions about an RPC endpoint:
//
//   1. Does the node price by EIP-8037 (Glamsterdam)? A fresh slot then draws about 110,020 gas (12,100 of execution
//      plus 97,920 of state gas) where Prague draws 22,100.
//   2. Where does state gas come from? Under EIP-8037 a transaction whose gas limit is at or below 2^24 has no
//      reservoir and pays state gas out of ordinary gas; one above 2^24 starts with at most 2^24 less its intrinsic
//      cost as ordinary gas, and pays state gas from the reservoir (the rest of its gas limit).
//
// How: it never deploys or sends anything. It asks the node to RUN a few bytes of code placed at an unused address by
// a state override. The code writes n fresh slots and returns two words: the gas the call started with (what the GAS
// opcode sees, which excludes the reservoir) and the gas the writes drew from it. It asks twice per case:
//
//   - `eth_simulateV1` with `validation: true`, which applies the node's real transaction rules;
//   - plain `eth_call`, for comparison. A client may relax the rules there (Geth 1.17.9 does not cap ordinary gas at
//     2^24 in `eth_call`, so it shows no reservoir), which is why a planner must not read the cap from `eth_call`.
//
// `node tools/state-gas-probe.mjs <rpc url> [--json]`. It prints one table per reply and writes nothing. No gate runs
// it (it needs a network); the result it found on Sepolia is recorded in docs/GAS-SCHEDULES.md.

const CAP = 1 << 24; // EIP-7825's 16,777,216
const PROBE = "0x00000000000000000000000000000000000ef501"; // an address with no code, given code by the override
const SENDER = "0x00000000000000000000000000000000000ef502"; // given a balance by the override, for validation

/** Runtime code that writes slots n..1 (value 1) and returns (gas at entry, gas the loop drew from the call's gas). */
export function probeCode(n) {
  if (!Number.isInteger(n) || n < 1 || n > 0xffff) throw new Error("n must be 1..65535");
  const b = [
    0x5a, // GAS                      [g0]
    0x61, n >> 8, n & 0xff, // PUSH2 n [n, g0]
  ];
  const loop = b.length;
  b.push(0x5b, 0x80, 0x15, 0x60, 0x00, 0x57); // JUMPDEST DUP1 ISZERO PUSH1 <end> JUMPI
  const patch = b.length - 2;
  b.push(0x60, 0x01, 0x81, 0x55); // PUSH1 1 DUP2 SSTORE      sstore(counter, 1): a fresh slot
  b.push(0x60, 0x01, 0x90, 0x03); // PUSH1 1 SWAP1 SUB        counter - 1
  b.push(0x60, loop, 0x56); // PUSH1 loop JUMP
  b[patch] = b.length;
  b.push(0x5b, 0x50); // JUMPDEST POP                         [g0]
  b.push(0x80, 0x60, 0x00, 0x52); // DUP1 PUSH1 0 MSTORE      mem[0] = g0
  b.push(0x5a, 0x90, 0x03); // GAS SWAP1 SUB                  g0 - g1
  b.push(0x60, 0x20, 0x52); // PUSH1 32 MSTORE                mem[32] = drawn
  b.push(0x60, 0x40, 0x60, 0x00, 0xf3); // RETURN(0, 64)
  return "0x" + b.map((x) => x.toString(16).padStart(2, "0")).join("");
}

const hex = (n) => "0x" + BigInt(n).toString(16);
const words = (data) => {
  const r = (data ?? "0x").slice(2);
  return r.length >= 128 ? { entry: Number(BigInt("0x" + r.slice(0, 64))), drawn: Number(BigInt("0x" + r.slice(64, 128))) } : null;
};

/** The cases: n fresh slots under the cap, at it, and above it. */
export const CASES = [
  { n: 20, gas: 10_000_000 },
  { n: 20, gas: 30_000_000 },
  { n: 100, gas: CAP },
  { n: 100, gas: 30_000_000 },
  { n: 100, gas: 60_000_000 },
];

/** One JSON-RPC batch, so one backend of a load-balanced endpoint answers the client version and every case. */
export function batch(cases = CASES) {
  const out = [{ jsonrpc: "2.0", id: "client", method: "web3_clientVersion", params: [] }];
  cases.forEach(({ n, gas }, i) => {
    const code = probeCode(n);
    out.push({
      jsonrpc: "2.0",
      id: `simulate-${i}`,
      method: "eth_simulateV1",
      params: [
        {
          blockStateCalls: [
            {
              stateOverrides: { [PROBE]: { code }, [SENDER]: { balance: hex(10n ** 20n) } },
              calls: [{ from: SENDER, to: PROBE, gas: hex(gas), maxFeePerGas: hex(10n ** 11n), maxPriorityFeePerGas: "0x1" }],
            },
          ],
          validation: true,
          traceTransfers: false,
        },
        "latest",
      ],
    });
    out.push({ jsonrpc: "2.0", id: `call-${i}`, method: "eth_call", params: [{ to: PROBE, gas: hex(gas) }, "latest", { [PROBE]: { code } }] });
  });
  return out;
}

/** Reads one batch reply into rows `{ n, gas, how, entry, drawn, perSlot, gasUsed, error }`. */
export function rows(reply, cases = CASES) {
  const by = new Map((Array.isArray(reply) ? reply : []).map((o) => [o.id, o]));
  const out = [];
  cases.forEach(({ n, gas }, i) => {
    const s = by.get(`simulate-${i}`);
    const sc = s?.result?.[0]?.calls?.[0];
    const sw = words(sc?.returnData);
    out.push({
      n,
      gas,
      how: "simulate (validated)",
      ...(sw ? { entry: sw.entry, drawn: sw.drawn, perSlot: sw.drawn / n, gasUsed: Number(BigInt(sc.gasUsed ?? "0x0")) } : { error: JSON.stringify(s?.error ?? sc?.error ?? s ?? null) }),
    });
    const c = by.get(`call-${i}`);
    const cw = words(c?.result);
    out.push({ n, gas, how: "eth_call", ...(cw ? { entry: cw.entry, drawn: cw.drawn, perSlot: cw.drawn / n } : { error: JSON.stringify(c?.error ?? c ?? null) }) });
  });
  return { client: by.get("client")?.result ?? null, rows: out };
}

/** What the validated rows say: `pricing` "eip-8037" | "prague" | "unknown"; `reservoir` true | false | null. */
export function verdict(result) {
  const v = result.rows.filter((r) => r.how.startsWith("simulate") && r.perSlot !== undefined);
  const under = v.filter((r) => r.gas <= CAP);
  const above = v.filter((r) => r.gas > CAP);
  const near = (x, y) => Math.abs(x - y) <= 300; // the loop's own ~50 gas per slot
  const pricing = under.length === 0 ? "unknown" : under.every((r) => near(r.perSlot, 110_020)) ? "eip-8037" : under.every((r) => near(r.perSlot, 22_100)) ? "prague" : "unknown";
  const reservoir = pricing !== "eip-8037" || above.length === 0 ? null : above.every((r) => near(r.perSlot, 12_100) && r.entry < CAP);
  return { pricing, reservoir };
}

async function main() {
  const args = process.argv.slice(2);
  const url = args.find((a) => !a.startsWith("--"));
  if (!url) {
    console.error("usage: node tools/state-gas-probe.mjs <rpc url> [--json]");
    process.exit(2);
  }
  const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(batch()) });
  const result = rows(await res.json());
  const v = verdict(result);
  if (args.includes("--json")) {
    console.log(JSON.stringify({ ...result, verdict: v }, null, 2));
    return;
  }
  console.log(`client: ${result.client}`);
  for (const r of result.rows) {
    const head = `  n=${String(r.n).padStart(3)} gas=${r.gas.toLocaleString("en-US").padStart(11)} ${r.how.padEnd(20)}`;
    console.log(r.error ? `${head} ${r.error.slice(0, 120)}` : `${head} gas at entry ${r.entry.toLocaleString("en-US").padStart(11)}  drawn per slot ${r.perSlot.toFixed(1).padStart(10)}${r.gasUsed ? `  gasUsed ${r.gasUsed.toLocaleString("en-US")}` : ""}`);
  }
  console.log(`pricing: ${v.pricing}; state gas from a reservoir above 2^24: ${v.reservoir === null ? "not shown" : v.reservoir ? "yes" : "NO"}`);
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
