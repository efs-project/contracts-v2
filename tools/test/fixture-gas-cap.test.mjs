// SPDX-License-Identifier: MIT
// The local chain enforces the per-transaction gas cap that mainnet and Sepolia enforce (EIP-7825, 2^24), so a
// publication that is too large fails here and not first on a real chain.
//
// One instance (default hardfork: osaka with the cap). A publication inside every Realm limit (64 actions, 16,384
// body bytes) that needs about 28M gas:
//   - sent with a gas limit above the cap, the node refuses the transaction;
//   - sent with the gas limit at the cap, it runs out of gas and nothing is admitted;
//   - split into four publications of 16 records, each is admitted under the cap.
// A second instance started with --hardfork prague admits the same publication whole, using more gas than the cap:
// the old behaviour, opt-in, and the proof that gas was the only obstacle.
//
//   node --test tools/test/fixture-gas-cap.test.mjs
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { createPublicClient, createWalletClient, encodeFunctionData, http, keccak256, sha256, concat, toHex, pad } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ACTION, FIXTURE_KEY, T, buildPlan, keys } from "../deploy-plan.mjs";
import { HARDFORKS, down, receiptOrReport, up } from "../efs-fixture.mjs";

const home = mkdtempSync(join(tmpdir(), "efs-fixture-gas-cap-"));
const CAP = HARDFORKS.osaka.txGasCap;
const ZERO = pad("0x", { size: 32 });
const started = [];

after(async () => {
  for (const name of started) { try { await down({ name, home }); } catch { /* already gone */ } }
  rmSync(home, { recursive: true, force: true });
});

/** `count` distinct files-bytes/1 records of 224 payload bytes (a 256-byte body: sha256(payload) ‖ payload). */
function records(typeId, count, seed) {
  const actions = [];
  const bodies = [];
  for (let i = 0; i < count; i++) {
    const payload = toHex(new Uint8Array(224).map((_, j) => (seed * 31 + i * 7 + j) & 0xff));
    const body = concat([sha256(payload), payload]);
    actions.push({ kind: ACTION.PUBLISH, typeId, bodyHashOrRecordId: keccak256(body), purpose: ZERO, subject: ZERO, role: ZERO, target: ZERO, expectedRevision: 0n, saltOrStrength: ZERO });
    bodies.push(body);
  }
  return { actions, bodies };
}

test("a publication over the per-transaction gas cap is refused; split, it is admitted", { timeout: 300_000 }, async (t) => {
  let plan;
  try { plan = await buildPlan(); } catch (e) { t.skip(`the plan cannot be built from the current artifacts: ${e.message.split("\n")[0]}`); return; }
  assert.equal(CAP, 16_777_216);

  const r = await up({ name: "capped", home, ttl: 240 });
  started.push("capped");
  assert.equal(r.capabilities.hardfork, "osaka");
  assert.equal(r.capabilities.txGasCap, CAP);
  const dep = JSON.parse(readFileSync(r.deployment, "utf8"));
  assert.deepEqual([dep.chain.hardfork, dep.chain.txGasCap, dep.chain.txGasCapEnforced], ["osaka", CAP, true]);

  const transport = http(r.rpcUrl);
  const account = privateKeyToAccount(FIXTURE_KEY);
  const chain = { id: r.chainId, name: "efs-fixture", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [r.rpcUrl] } } };
  const pub = createPublicClient({ chain, transport, pollingInterval: 50 });
  const wallet = createWalletClient({ chain, transport, account });
  const abi = plan.local.abis.LedgerCore;
  const ledger = r.ledger;
  const principal = keys.principal(account.address);
  const nonceOn = async (client) => (await client.readContract({ address: ledger, abi, functionName: "nonceOf", args: [principal] }))[0];
  const nonceOf = () => nonceOn(pub);
  const call = async ({ actions, bodies }, client = pub) => {
    const ctx = {
      nonce: await nonceOn(client), deadline: 0n,
      expectedExecutionSet: await client.readContract({ address: ledger, abi, functionName: "executionSet" }),
      expectedAcceptanceProfile: await client.readContract({ address: plan.addresses.ingress, abi: plan.local.abis.LedgerIngress, functionName: "acceptanceProfileOf", args: [ledger, actions] }),
    };
    return encodeFunctionData({ abi, functionName: "execute", args: [actions, bodies, ctx, "0x"] });
  };

  // inside every Realm limit: 64 actions, 64 × 256 = 16,384 body bytes
  const big = records(dep.typeIds["files-bytes/1"], 64, 1);
  assert.equal(big.actions.length, dep.limits.maxActions);
  assert.equal(big.bodies.reduce((n, b) => n + (b.length - 2) / 2, 0), dep.limits.maxBodyBytesPerPublication);
  const before = await nonceOf();

  // 1. above the cap: the node refuses the transaction itself
  await assert.rejects(wallet.sendTransaction({ to: ledger, data: await call(big), gas: BigInt(CAP) + 1n }), /gas limit cap|tx gas limit|intrinsic gas too high/i);
  assert.equal(await nonceOf(), before, "a refused transaction admits nothing");

  // 2. at the cap: it is mined, runs out of gas, and admits nothing
  const hash = await wallet.sendTransaction({ to: ledger, data: await call(big), gas: BigInt(CAP) });
  const receipt = await receiptOrReport(pub, hash, { step: "2: the whole publication at the cap", sender: account.address, pid: r.pid, logPath: r.log });
  assert.equal(receipt.status, "reverted", "the publication needs more gas than one transaction may carry");
  assert.equal(await nonceOf(), before, "an out-of-gas publication admits nothing");

  // 3. split into four publications of sixteen records: each fits, each is admitted
  for (let i = 0; i < 4; i++) {
    const part = { actions: big.actions.slice(i * 16, i * 16 + 16), bodies: big.bodies.slice(i * 16, i * 16 + 16) };
    const h = await wallet.sendTransaction({ to: ledger, data: await call(part) });
    const rc = await receiptOrReport(pub, h, { step: `3: part ${i} of 4`, sender: account.address, pid: r.pid, logPath: r.log });
    assert.equal(rc.status, "success");
    assert.ok(rc.gasUsed < BigInt(CAP), `part ${i} used ${rc.gasUsed}`);
  }
  assert.equal(await nonceOf(), before + 4n);
  const last = big.actions.at(-1);
  const header = await pub.readContract({ address: ledger, abi, functionName: "recordHeader", args: [keys.record(last.typeId, big.bodies.at(-1))] });
  assert.equal(header[0], last.typeId, "the last record is on the ledger");
  await down({ name: "capped", home });

  // the opt-out: under prague nothing enforces the cap, and the same 64-record publication is admitted whole there,
  // which shows that gas was the only thing wrong with it
  const p = await up({ name: "uncapped", home, ttl: 240, hardfork: "prague", verify: false });
  started.push("uncapped");
  assert.equal(p.capabilities.txGasCap, null);
  const wallet2 = createWalletClient({ chain: { ...chain, rpcUrls: { default: { http: [p.rpcUrl] } } }, transport: http(p.rpcUrl), account });
  const pub2 = createPublicClient({ chain, transport: http(p.rpcUrl), pollingInterval: 50 });
  assert.equal(p.ledger, ledger, "the same plan gives the same ledger address");
  const h2 = await wallet2.sendTransaction({ to: ledger, data: await call(big, pub2), gas: 29_000_000n });
  const whole = await receiptOrReport(pub2, h2, { step: "prague: the whole publication", sender: account.address, pid: p.pid, logPath: p.log });
  assert.equal(whole.status, "success");
  assert.ok(whole.gasUsed > BigInt(CAP), `the whole publication used ${whole.gasUsed}, more than the cap`);
  await down({ name: "uncapped", home });
});
