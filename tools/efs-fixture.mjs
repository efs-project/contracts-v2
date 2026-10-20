// SPDX-License-Identifier: MIT
// The local fixture of design §13 / §12.3 row "deploy locally": an owned anvil, the genesis plan of §8.2 executed
// step by step (tools/deploy-plan.mjs computes every address and hash offline first), the nine Files Types
// registered, the seed (root, one folder, one file) written as the fixture principal, and the efs-deployment/1
// document. `verify` recomputes everything from the artifacts and compares it with the chain; `down` stops the
// anvil this tool started (its own pid file only).
//
//   node tools/efs-fixture.mjs up     [--port 8560] [--chain-id 31337] [--realm-salt 0x…] [--ttl 900]
//   node tools/efs-fixture.mjs verify
//   node tools/efs-fixture.mjs down
//
// Files: release/.anvil.pid, release/.anvil.log, release/.fixture.json (rpc + journal), release/efs-deployment.json,
// release/expected.json. The fixture key is anvil's first default key (a public throwaway; see tools/RELEASE.md).
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, custom, decodeFunctionResult, defineChain, encodeErrorResult, encodeFunctionData, getAddress, keccak256, pad, parseEther, toHex, zeroAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  ADMIN_SLOT, DEFAULTS, FACTORY, FACTORY_RUNTIME, FIXTURE_KEY, harnessFactoryRuntime, IMPLEMENTATION_SLOT, PURPOSE, TYPE_NAMES, artifact,
  buildPlan, domainSeparator, executionSet, jsonable, keys, limitsProfileId, parseArgs, planDocument, root, toJSON, validate,
} from "./deploy-plan.mjs";

const REL = join(root, "release");
const PID = join(REL, ".anvil.pid");
const STATE = join(REL, ".fixture.json");
const FOREIGN_PORT = 60742; // someone else's anvil: never ours, never touched

// ---- JSON-RPC with call counting -----------------------------------------------------------------------------------

function rpcClient(url) {
  let id = 0;
  const counts = {};
  let envelopes = 0;
  const post = async (body) => {
    envelopes++;
    const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    return res.json();
  };
  const unwrap = (method, j) => {
    if (j.error) {
      const e = new Error(`${method}: ${j.error.message}`);
      e.rpc = j.error;
      throw e;
    }
    return j.result;
  };
  const call = async (method, params = []) => {
    counts[method] = (counts[method] ?? 0) + 1;
    return unwrap(method, await post({ jsonrpc: "2.0", id: ++id, method, params }));
  };
  /** One HTTP envelope carrying several logical calls. */
  const batch = async (reqs) => {
    for (const [m] of reqs) counts[m] = (counts[m] ?? 0) + 1;
    const body = reqs.map(([method, params]) => ({ jsonrpc: "2.0", id: ++id, method, params }));
    const out = await post(body);
    const byId = new Map(out.map((r) => [r.id, r]));
    return body.map((b) => unwrap(b.method, byId.get(b.id)));
  };
  const reset = () => { for (const k of Object.keys(counts)) delete counts[k]; envelopes = 0; };
  return { call, batch, counts, reset, get envelopes() { return envelopes; } };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const portOpen = (port) => new Promise((resolve) => {
  const s = connect({ port, host: "127.0.0.1" });
  s.once("connect", () => { s.destroy(); resolve(true); });
  s.once("error", () => resolve(false));
});
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const commOf = (pid) => { try { return execFileSync("ps", ["-p", String(pid), "-o", "comm="]).toString().trim(); } catch { return ""; } };

function clients(url, chainId) {
  const rpc = rpcClient(url);
  const chain = defineChain({ id: chainId, name: `efs-fixture-${chainId}`, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [url] } } });
  const transport = custom({ request: ({ method, params }) => rpc.call(method, params) });
  const account = privateKeyToAccount(FIXTURE_KEY);
  const pub = createPublicClient({ chain, transport, pollingInterval: 50 });
  const wallet = createWalletClient({ chain, transport, account });
  return { rpc, pub, wallet, account, chain };
}

const abiOf = (name) => artifact(name).abi;
async function read(pub, address, name, functionName, args = []) {
  return pub.readContract({ address, abi: abiOf(name), functionName, args });
}

// ---- up ------------------------------------------------------------------------------------------------------------

async function up(o) {
  const port = Number(o.port ?? 8560);
  const chainId = Number(o["chain-id"] ?? DEFAULTS.chainId);
  const realmSalt = o["realm-salt"] ?? DEFAULTS.realmSalt;
  const ttl = Number(o.ttl ?? 900);
  assert.notEqual(port, FOREIGN_PORT, `port ${FOREIGN_PORT} belongs to another anvil; pick another`);
  mkdirSync(REL, { recursive: true });
  if (existsSync(PID)) {
    const pid = Number(readFileSync(PID, "utf8"));
    assert.ok(!alive(pid), `a fixture anvil (pid ${pid}) is already up: run \`node tools/efs-fixture.mjs down\` first`);
    rmSync(PID);
  }
  assert.ok(!(await portOpen(port)), `port ${port} is in use; pick a free one with --port`);

  // the plan first: every address and hash is known before anything is deployed
  const plan = await buildPlan({ chainId, realmSalt });
  const planHash = planDocument(plan).planHash;

  // an owned anvil under a watchdog (perl execs anvil, so the pid file holds anvil's own pid)
  const log = openSync(join(REL, ".anvil.log"), "w");
  const child = spawn("perl", ["-e", `alarm ${ttl}; exec @ARGV`, "anvil", "--port", String(port), "--chain-id", String(chainId), "--hardfork", "prague", "--disable-default-create2-deployer"], { detached: true, stdio: ["ignore", log, log] });
  child.unref();
  writeFileSync(PID, String(child.pid));
  const url = `http://127.0.0.1:${port}`;
  const { rpc, pub, wallet, account } = clients(url, chainId);
  for (let i = 0; ; i++) {
    try { assert.equal(Number(await rpc.call("eth_chainId")), chainId); break; } catch (e) {
      if (i > 200) throw new Error(`anvil did not answer on ${url}: ${e.message}`);
      await sleep(100);
    }
  }
  assert.equal(commOf(child.pid).split("/").pop(), "anvil", `pid ${child.pid} is not anvil`);
  console.log(`efs-fixture: anvil pid ${child.pid} on ${url} (chain ${chainId}, hardfork prague, ttl ${ttl}s)`);

  const journal = [];
  const record = async (step, hash) => {
    const r = await pub.waitForTransactionReceipt({ hash });
    assert.equal(r.status, "success", `${step.id} reverted (${hash})`);
    journal.push({ id: step.id, label: step.label ?? step.contract, txHash: hash, blockNumber: Number(r.blockNumber), blockHash: r.blockHash, gasUsed: Number(r.gasUsed) });
    return r;
  };
  const codeAt = async (a) => (await pub.getCode({ address: a })) ?? "0x";

  // F0: the deterministic-deployment factory from its public presigned transaction
  let factoryMethod = "presigned-tx";
  if ((await codeAt(FACTORY.address)) === "0x") {
    const fund = await wallet.sendTransaction({ to: FACTORY.deployer, value: FACTORY.fundWei });
    await record({ id: "F0.fund", label: "fund the factory deployer" }, fund);
    try {
      const hash = await rpc.call("eth_sendRawTransaction", [FACTORY.presignedTx]);
      await record({ id: "F0", label: "factory presigned tx" }, hash);
    } catch (e) {
      factoryMethod = "anvil_setCode";
      console.log(`efs-fixture: presigned factory tx refused (${e.message}); etching the runtime with anvil_setCode`);
      await rpc.call("anvil_setCode", [FACTORY.address, FACTORY_RUNTIME()]);
    }
  } else factoryMethod = "preexisting";
  assert.equal(await codeAt(FACTORY.address), FACTORY_RUNTIME(), "factory runtime != the presigned transaction's runtime");

  const send = async (step, to, data) => record(step, await wallet.sendTransaction({ to, data }));
  const ledger = plan.addresses.ledgerProxy;
  for (const step of plan.steps) {
    if (step.kind === "FACTORY") continue;
    if (step.kind === "CREATE2" || step.id.startsWith("G11.")) {
      if ((await codeAt(step.address)) === "0x") await send(step, step.kind === "CREATE2" ? FACTORY.address : step.to, step.data);
      const code = await codeAt(step.address);
      assert.equal(keccak256(code), step.runtimeCodehash, `${step.id} ${step.contract}: runtime codehash differs from the plan`);
    } else if (step.id === "G18") {
      if ((await read(pub, step.to, "RealmGenesis", "controller")) === zeroAddress) await send(step, step.to, step.data);
      for (const c of step.creates) assert.equal(keccak256(await codeAt(c.address)), c.runtimeCodehash, `G18 ${c.label}: runtime codehash differs from the plan`);
    } else if (step.id === "G20") {
      if ((await read(pub, ledger, "LedgerCore", "revision")) === 0) await send(step, step.to, step.data);
      assert.equal(await read(pub, ledger, "LedgerCore", "executionSet"), plan.activation.expectedExecutionSet, "G20 executionSet");
    } else if (step.id.startsWith("G21.")) {
      await send(step, step.to, step.data);
    } else if (step.kind === "EXECUTE") {
      const subject = step.id === "G22.root" ? plan.seed.root.subjectId : step.id === "G22.folder" ? plan.seed.folder.subjectId : plan.seed.file.subjectId;
      if ((await read(pub, ledger, "LedgerCore", "subjectCreatedAt", [subject])) !== 0n) continue;
      await execute(pub, wallet, plan, step);
      const r = await pub.getTransactionReceipt({ hash: step.txHash });
      journal.push({ id: step.id, label: step.label, txHash: step.txHash, blockNumber: Number(r.blockNumber), blockHash: r.blockHash, gasUsed: Number(r.gasUsed), publication: step.publication });
    }
  }
  console.log(`efs-fixture: genesis + registration + seed done (${journal.length} transactions, factory via ${factoryMethod})`);

  const deployment = await deploymentDocument({ plan, planHash, pub, url, factoryMethod, journal, account });
  writeFileSync(join(REL, "efs-deployment.json"), toJSON(deployment));
  writeFileSync(join(REL, "expected.json"), toJSON(expectedDocument(plan, deployment)));
  writeFileSync(STATE, toJSON({ url, port, chainId, realmSalt, pid: child.pid, ttl, startedAt: new Date().toISOString(), factoryMethod, journal }));
  console.log(`efs-fixture: wrote release/efs-deployment.json and release/expected.json (ledger ${ledger}, root ${plan.seed.root.directoryRecordId})`);
}

/** One native publication with both expectations bound (design Q22; `EfsNative.currentBind`). */
async function execute(pub, wallet, plan, step) {
  const ledger = plan.addresses.ledgerProxy;
  const actions = step.actions.map((a) => ({ ...a, expectedRevision: BigInt(a.expectedRevision) }));
  const principal = keys.principal(wallet.account.address);
  const [nonce] = await read(pub, ledger, "LedgerCore", "nonceOf", [principal]);
  const ctx = {
    nonce,
    deadline: 0n,
    expectedExecutionSet: await read(pub, ledger, "LedgerCore", "executionSet"),
    expectedAcceptanceProfile: await read(pub, plan.addresses.ingress, "LedgerIngress", "acceptanceProfileOf", [ledger, actions]),
  };
  const data = encodeFunctionData({ abi: abiOf("LedgerCore"), functionName: "execute", args: [actions, step.bodies, ctx, "0x"] });
  const sim = await pub.call({ account: wallet.account.address, to: ledger, data });
  const [publication] = decodeFunctionResult({ abi: abiOf("LedgerCore"), functionName: "execute", data: sim.data });
  const hash = await wallet.sendTransaction({ to: ledger, data });
  const r = await pub.waitForTransactionReceipt({ hash });
  assert.equal(r.status, "success", `${step.id} reverted`);
  step.txHash = hash;
  step.publication = Number(publication);
  step.nonce = Number(nonce);
  step.ctx = jsonable(ctx);
}

async function deploymentDocument({ plan, planHash, pub, url, factoryMethod, journal, account }) {
  const a = plan.addresses;
  const relPath = join(REL, "release.json");
  const releaseDigest = existsSync(relPath) ? `0x${createHash("sha256").update(readFileSync(relPath)).digest("hex")}` : null;
  const tx = Object.fromEntries(journal.map((j) => [j.id, j]));
  const contracts = {};
  for (const s of plan.steps) {
    if (s.kind === "CREATE2") contracts[s.label ?? s.contract] = { address: s.address, runtimeCodehash: s.runtimeCodehash, initcodeHash: s.initcodeHash, step: s.id, txHash: tx[s.id]?.txHash ?? null, blockNumber: tx[s.id]?.blockNumber ?? null };
    if (s.id === "G18") for (const c of s.creates) contracts[c.label] = { address: c.address, runtimeCodehash: c.runtimeCodehash, step: "G18", creator: c.creator ?? a.genesis, nonce: c.nonce, txHash: tx.G18?.txHash ?? null, blockNumber: tx.G18?.blockNumber ?? null };
  }
  const proxy = async (p, admin, impl, initializer) => ({
    address: p,
    implementation: getAddress(`0x${(await pub.getStorageAt({ address: p, slot: IMPLEMENTATION_SLOT })).slice(26)}`),
    expectedImplementation: impl,
    proxyAdmin: getAddress(`0x${(await pub.getStorageAt({ address: p, slot: ADMIN_SLOT })).slice(26)}`),
    expectedProxyAdmin: admin,
    proxyAdminOwner: await read(pub, admin, "ProxyAdmin", "owner"),
    immutableReferences: { _admin: plan.units.TypeRegistryProxy ? immutableOffsets("TransparentUpgradeableProxy") : [] },
    initializer,
  });
  const g18 = plan.steps.find((s) => s.id === "G18");
  const d = await read(pub, a.ledgerReads, "LedgerReads", "describe", [a.ledgerProxy]);
  const typeIds = Object.fromEntries(plan.profile.map((p) => [p.type, p.typeId]));
  return {
    schema: "efs-deployment/1",
    releaseDigest,
    planHash,
    chainId: plan.chainId,
    realmId: plan.realm.realmId,
    realmOrigin: plan.realm.realmOrigin,
    realmSalt: plan.realmSalt,
    factory: { address: FACTORY.address, method: factoryMethod, deployer: FACTORY.deployer, presignedTx: FACTORY.presignedTx, runtimeCodehash: keccak256(FACTORY_RUNTIME()), harnessRuntimeMatches: harnessFactoryRuntime() === FACTORY_RUNTIME() },
    genesis: { address: a.genesis, nonces: plan.genesis.nonces, txHash: tx.G18?.txHash ?? null, blockNumber: tx.G18?.blockNumber ?? null, blockHash: tx.G18?.blockHash ?? null },
    activation: { revision: 1, executionSet: d.executionSet, txHash: tx.G20?.txHash ?? null, blockNumber: tx.G20?.blockNumber ?? null, capabilities: 0, acceptedChainId: plan.chainId, dependencyRoot: plan.activation.dependencyRoot, set: jsonable(plan.activation) },
    layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId,
    executionProfileId: plan.executionProfileId,
    limits: plan.limits,
    limitsProfileId: plan.realm.limitsProfileId,
    domainSeparator: plan.realm.domainSeparator,
    noticePrincipal: plan.activation.noticePrincipal,
    ledger: a.ledgerProxy,
    registry: a.registryProxy,
    controller: { address: a.controller, owner: await read(pub, a.controller, "RealmController", "owner"), pendingOwner: await read(pub, a.controller, "RealmController", "pendingOwner"), frozen: await read(pub, a.controller, "RealmController", "frozen") },
    proxies: {
      ledger: await proxy(a.ledgerProxy, a.ledgerAdmin, a.ledgerImpl, g18.creates[2].initializer),
      registry: await proxy(a.registryProxy, a.registryAdmin, a.registryImpl, g18.creates[1].initializer),
    },
    contracts,
    index: { address: a.index, generation: Number(d.indexGeneration), manifestHash: plan.index.manifestHash, indexObligations: plan.realm.indexObligations, stores: { posting: a.postingStore, bitmap: a.bitmapStore }, families: plan.index.families, units: plan.index.units, digestSpecs: plan.index.specs, workModel: plan.workModel },
    typeIds,
    profile: plan.profile.map(({ descriptor, declarationSig, ...p }) => p),
    privilegedRoles: { controllerOwner: account.address, ledgerProxyAdminOwner: a.controller, registryProxyAdminOwner: a.controller, steward: zeroAddress, noticePrincipal: plan.activation.noticePrincipal },
    readers: { ledgerReads: a.ledgerReads, ledgerViews: a.ledgerViews, readerDirectory: a.readerDirectory, listed: [], note: "LensReader and FilesPageReader are not in this release (in progress elsewhere); nothing is listed in the ReaderDirectory" },
    seed: { version: plan.seed.version, transactions: plan.steps.filter((s) => s.kind === "EXECUTE").map((s) => ({ id: s.id, label: s.label, txHash: s.txHash ?? tx[s.id]?.txHash ?? null, publication: s.publication ?? tx[s.id]?.publication ?? null, actions: s.actions, bodies: s.bodies })) },
    root: plan.seed.root,
    defaultLensPrincipals: [plan.seed.principalId],
    actors: { owner: account.address, fixturePrincipal: account.address, fixturePrincipalId: plan.seed.principalId, declarationKey: account.address, fixtureKey: "anvil default account 0 (public test key; never use with value)" },
    rpc: { url, chainId: plan.chainId, hardfork: "prague" },
    evidenceGrade: "local-fixture",
  };
}

function immutableOffsets(name) {
  return Object.values(artifact(name).refs).flat().map((r) => r.start).sort((x, y) => x - y);
}

function expectedDocument(plan, deployment) {
  const s = plan.seed;
  return {
    schema: "efs-fixture-expected/1",
    seedVersion: s.version,
    chainId: plan.chainId,
    ledger: plan.addresses.ledgerProxy,
    executionSet: plan.activation.expectedExecutionSet,
    revision: 1,
    root: s.root,
    folder: s.folder,
    file: { ...s.file, body: s.file.body },
    counts: s.counts,
    typeIds: deployment.typeIds,
    catalogCount: 9,
    heads: [
      { key: s.folder.bindingKey, state: 1, revision: 1, target: s.folder.directoryRecordId, what: "FOLDER root/docs → docs directory" },
      { key: s.file.headKey, state: 1, revision: 1, target: s.file.rootRecordId, what: "HEAD readme → files-root/1 record" },
      { key: s.file.bindingKey, state: 1, revision: 1, target: s.file.subjectId, what: "FOLDER docs/readme.txt → file subject" },
    ],
    records: [
      { id: s.root.directoryRecordId, typeId: deployment.typeIds["files-directory/1"] },
      { id: s.folder.directoryRecordId, typeId: deployment.typeIds["files-directory/1"] },
      { id: s.folder.nameRecordId, typeId: deployment.typeIds["files-name/2"] },
      { id: s.file.rootRecordId, typeId: deployment.typeIds["files-root/1"] },
      { id: s.file.nameRecordId, typeId: deployment.typeIds["files-name/2"] },
    ],
  };
}

// ---- verify --------------------------------------------------------------------------------------------------------

async function verify() {
  assert.ok(existsSync(STATE), "no fixture state: run `node tools/efs-fixture.mjs up` first");
  const st = JSON.parse(readFileSync(STATE, "utf8"));
  const dep = JSON.parse(readFileSync(join(REL, "efs-deployment.json"), "utf8"));
  const exp = JSON.parse(readFileSync(join(REL, "expected.json"), "utf8"));
  const { rpc, pub } = clients(st.url, st.chainId);
  const plan = await buildPlan({ chainId: st.chainId, realmSalt: st.realmSalt });
  const a = plan.addresses;
  const failures = [];
  const checked = {};
  const eq = (what, got, want) => {
    checked[what.split(" ")[0]] = (checked[what.split(" ")[0]] ?? 0) + 1;
    const norm = (x) => (typeof x === "string" && /^0x[0-9a-fA-F]*$/.test(x) ? x.toLowerCase() : typeof x === "bigint" ? x.toString() : JSON.stringify(jsonable(x)));
    if (norm(got) !== norm(want)) failures.push(`${what}: chain ${norm(got)} != expected ${norm(want)}`);
  };
  const code = async (addr) => (await pub.getCode({ address: addr })) ?? "0x";

  // 1. the plan reproduces from the artifacts, and the published documents agree with it
  const planHash = planDocument(plan).planHash;
  eq("documents planHash", dep.planHash, planHash);
  const planFile = join(root, "deploy/plan.json");
  if (existsSync(planFile)) {
    const onDisk = JSON.parse(readFileSync(planFile, "utf8"));
    if (onDisk.chainId === plan.chainId && onDisk.realmSalt === plan.realmSalt) eq("documents deploy/plan.json", onDisk.planHash, planHash);
  }
  eq("documents ledger", dep.ledger, a.ledgerProxy);
  eq("documents executionSet", exp.executionSet, plan.activation.expectedExecutionSet);
  eq("documents root", dep.root, plan.seed.root);
  if (dep.releaseDigest) {
    const rel = readFileSync(join(REL, "release.json"));
    eq("documents releaseDigest", dep.releaseDigest, `0x${createHash("sha256").update(rel).digest("hex")}`);
  }

  // the documents conform to schemas/
  for (const [file, schema] of [["deploy/plan.json", "efs-deploy-plan-1.schema.json"], ["release/release.json", "efs-contracts-release-1.schema.json"], ["release/efs-deployment.json", "efs-deployment-1.schema.json"], ["release/expected.json", "efs-fixture-expected-1.schema.json"], ["release/errors.json", "efs-errors-1.schema.json"], ["gas/report.json", "efs-gas-report-1.schema.json"]]) {
    if (!existsSync(join(root, file))) continue;
    const errs = validate(JSON.parse(readFileSync(join(root, file), "utf8")), schema);
    checked.schema = (checked.schema ?? 0) + 1;
    for (const e of errs) failures.push(`schema ${file}: ${e}`);
  }

  // 2. every address and runtime: byte-exact against the artifact with the planned immutables
  eq("code factory", await code(FACTORY.address), FACTORY_RUNTIME());
  eq("code factory-codehash", keccak256(FACTORY_RUNTIME()), "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989");
  const harnessNote = harnessFactoryRuntime() === FACTORY_RUNTIME() ? "matches" : `differs (${(harnessFactoryRuntime().length - 2) / 2} bytes vs ${(FACTORY_RUNTIME().length - 2) / 2}; see HARNESS-BUG in tools/RELEASE.md)`;
  for (const [label, u] of Object.entries(plan.units)) {
    const c = await code(u.address);
    eq(`codehash ${label}`, keccak256(c), u.runtimeCodehash);
    if (u.runtime) eq(`runtime ${label}`, c, u.runtime);
  }
  for (const p of plan.profile) eq(`codehash blob ${p.type}`, keccak256(await code(p.blob)), p.blobCodehash);

  // 3. genesis: journal, predictions, single use
  eq("genesis controller", await read(pub, a.genesis, "RealmGenesis", "controller"), a.controller);
  eq("genesis registryProxy", await read(pub, a.genesis, "RealmGenesis", "registryProxy"), a.registryProxy);
  eq("genesis ledgerProxy", await read(pub, a.genesis, "RealmGenesis", "ledgerProxy"), a.ledgerProxy);
  const predicted = await read(pub, a.genesis, "RealmGenesis", "predict");
  eq("genesis predict", predicted, [a.controller, a.registryProxy, a.ledgerProxy]);
  const g18 = plan.steps.find((s) => s.id === "G18");
  try {
    await rpc.call("eth_call", [{ to: a.genesis, data: g18.data }, "latest"]);
    failures.push("genesis second-run: a second run() did not revert");
  } catch (e) {
    eq("genesis second-run", e.rpc?.data, encodeErrorResult({ abi: abiOf("RealmGenesis"), errorName: "E_GENESIS", args: [0] }));
  }

  // 4. proxies, admins, ownership
  const slot = async (addr, s) => getAddress(`0x${(await pub.getStorageAt({ address: addr, slot: s })).slice(26)}`);
  eq("proxy ledger-impl", await slot(a.ledgerProxy, IMPLEMENTATION_SLOT), a.ledgerImpl);
  eq("proxy registry-impl", await slot(a.registryProxy, IMPLEMENTATION_SLOT), a.registryImpl);
  eq("proxy ledger-admin", await slot(a.ledgerProxy, ADMIN_SLOT), a.ledgerAdmin);
  eq("proxy registry-admin", await slot(a.registryProxy, ADMIN_SLOT), a.registryAdmin);
  eq("proxy ledger-admin-owner", await read(pub, a.ledgerAdmin, "ProxyAdmin", "owner"), a.controller);
  eq("proxy registry-admin-owner", await read(pub, a.registryAdmin, "ProxyAdmin", "owner"), a.controller);
  eq("controller owner", await read(pub, a.controller, "RealmController", "owner"), plan.owner);
  eq("controller admins", await read(pub, a.controller, "RealmController", "admins"), [a.ledgerAdmin, a.registryAdmin]);
  eq("controller NOTICE_TYPE", await read(pub, a.controller, "RealmController", "NOTICE_TYPE"), plan.profile[8].typeId);
  eq("registry ledger", await read(pub, a.registryProxy, "TypeRegistry", "ledger"), a.ledgerProxy);
  eq("registry implementation", await read(pub, a.registryProxy, "TypeRegistry", "implementation"), a.registryImpl);
  eq("registry activeRevision", await read(pub, a.registryProxy, "TypeRegistry", "activeRevision"), 1);

  // 5. describe(): every field against the plan
  const d = await read(pub, a.ledgerReads, "LedgerReads", "describe", [a.ledgerProxy]);
  const set = plan.activation;
  const want = {
    realmId: plan.realm.realmId, realmOrigin: plan.realm.realmOrigin, realmSalt: plan.realmSalt, genesisChainId: BigInt(plan.chainId), acceptedChainId: BigInt(plan.chainId),
    chainNamespace: toHex("eip155", { size: 8 }), chainReference: pad(toHex(plan.chainId), { size: 32 }), executionSet: set.expectedExecutionSet, revision: 1, layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId, executionProfileId: plan.executionProfileId, capabilities: 0, ledgerImpl: a.ledgerImpl, ledgerImplCodehash: set.components.ledgerImplCodehash,
    ingress: a.ingress, ingressCodehash: set.components.ingressCodehash, applyDelegate: a.apply, applyCodehash: set.components.applyCodehash, registry: a.registryProxy,
    registryImpl: a.registryImpl, registryImplCodehash: set.components.registryImplCodehash, catalogCount: 9n, index: a.index, indexCodehash: set.components.indexCodehash,
    indexGeneration: 1, indexManifestHash: plan.index.manifestHash, indexObligations: plan.realm.indexObligations, controller: a.controller, controllerCodehash: set.components.controllerCodehash,
    controllerOwner: plan.owner, steward: zeroAddress, frozen: false, phase: 0, readerDirectory: a.readerDirectory, thisFacet: a.ledgerReads, thisFacetCodehash: plan.units.LedgerReads.runtimeCodehash,
    facetVersion: 1, admissions: BigInt(exp.counts.admissions), records: BigInt(exp.counts.records), bindings: BigInt(exp.counts.bindings), publications: BigInt(exp.counts.publications),
    domainSeparator: plan.realm.domainSeparator, limitsProfileId: plan.realm.limitsProfileId, statusVocabularyId: keccak256(toHex("efs2/status-vocabulary/1")),
    revisionBlock: BigInt(dep.activation.blockNumber), revisionAdmissionHigh: 0n, registryMutations: 1n,
    verifierProfilesRoot: pad("0x", { size: 32 }), dependencyRoot: pad("0x", { size: 32 }), noticePrincipal: pad("0x", { size: 32 }),
  };
  for (const [k, v] of Object.entries(want)) eq(`describe ${k}`, d[k], v);
  for (const [k, v] of Object.entries(plan.limits)) eq(`describe limits.${k}`, d.limits[k], v);
  const descriptionFields = artifact("LedgerReads").abi.find((i) => i.name === "describe").outputs[0].components.map((c) => c.name);
  const uncheckedDescribe = descriptionFields.filter((f) => !(f in want) && f !== "limits");

  // 6. the execution set, recomputed offline from the live revision row's components (design §8.1)
  const live = await read(pub, a.ledgerProxy, "LedgerCore", "executionSet");
  eq("executionSet live", live, set.expectedExecutionSet);
  const fromChain = { ...set, components: await revisionComponents(pub, a.ledgerProxy, a.ledgerReads) };
  eq("executionSet recomputed-from-revision-row", executionSet(fromChain, a.ledgerProxy), live);
  eq("executionSet domainSeparator", domainSeparator(plan.chainId, a.ledgerProxy), d.domainSeparator);
  eq("executionSet limitsProfileId", limitsProfileId(plan.limits), d.limitsProfileId);

  // 7. the index: manifest, readiness
  eq("index manifestHash", await read(pub, a.index, "RealmIndex", "manifestHash"), plan.index.manifestHash);
  const rd = await read(pub, a.index, "RealmIndex", "replayReadiness");
  eq("index ready", rd.ready, true);
  eq("index families", rd.families, plan.index.families);
  eq("index units", rd.units, plan.index.units);
  eq("index progress", (await read(pub, a.index, "RealmIndex", "progress"))[0], BigInt(exp.counts.admissions));

  // 8. Types: ids, catalog, rows, descriptor bytes, declarations
  const catalog = [];
  for (let i = 1n; i <= 9n; i++) catalog.push(await read(pub, a.registryProxy, "TypeRegistry", "catalog", [i]));
  eq("types catalog", [...catalog].sort(), plan.profile.map((p) => p.typeId).sort());
  for (const p of plan.profile) {
    const info = await read(pub, a.registryProxy, "TypeRegistry", "typeInfo", [p.typeId]);
    eq(`types ${p.type}.mandatory`, info.mandatory, p.instance);
    eq(`types ${p.type}.ruleId`, info.ruleId, p.ruleCodehash);
    eq(`types ${p.type}.shape`, info.shape, p.shape);
    eq(`types ${p.type}.blob`, info.descriptorBlob, p.blob);
    eq(`types ${p.type}.descriptor`, await read(pub, a.registryProxy, "TypeRegistry", "descriptorBytes", [p.typeId]), p.descriptor);
    eq(`types ${p.type}.refTypes`, await read(pub, a.registryProxy, "TypeRegistry", "refTypes", [p.typeId]), p.refTypes);
    const [k, installed] = await read(pub, a.registryProxy, "TypeRegistry", "declaration", [p.typeId]);
    eq(`types ${p.type}.declaration`, [k, installed], [plan.owner, true]);
    eq(`types ${p.type}.published-id`, dep.typeIds[p.type], p.typeId);
  }

  // 9. the seed: expected.json against the hot getters
  for (const r of exp.records) eq(`seed record ${r.id.slice(0, 10)}`, (await read(pub, a.ledgerProxy, "LedgerCore", "recordHeader", [r.id]))[0], r.typeId);
  for (const hd of exp.heads) {
    const got = await read(pub, a.ledgerProxy, "LedgerCore", "head", [hd.key]);
    eq(`seed head ${hd.what}`, [got[0], got[1], got[6]], [hd.state, BigInt(hd.revision), hd.target]);
  }
  for (const s of [exp.root.subjectId, exp.folder.subjectId, exp.file.subjectId]) {
    const at = await read(pub, a.ledgerProxy, "LedgerCore", "subjectCreatedAt", [s]);
    if (at === 0n) failures.push(`seed subject ${s}: not created`);
  }
  eq("seed nonce", (await read(pub, a.ledgerProxy, "LedgerCore", "nonceOf", [exp.root.principalId]))[0], 3n);
  const scope = await read(pub, a.bitmapStore, "BitmapStore", "scopeHead", [exp.folder.scopeKey]);
  eq("seed scope root", [scope[0], scope[1]], [1n, 1n]);
  const scope2 = await read(pub, a.bitmapStore, "BitmapStore", "scopeHead", [exp.file.scopeKey]);
  eq("seed scope docs", [scope2[0], scope2[1]], [1n, 1n]);
  eq("seed root-is-directory", (await read(pub, a.ledgerProxy, "LedgerCore", "recordHeader", [dep.root.directoryRecordId]))[0], dep.typeIds["files-directory/1"]);

  // 10. cold pin (design §12.3): what an SDK with only release.json + efs-deployment.json does on first contact
  rpc.reset();
  const describeData = encodeFunctionData({ abi: abiOf("LedgerReads"), functionName: "describe", args: [a.ledgerProxy] });
  const [chainHex, block, describeRaw, implWord] = await rpc.batch([
    ["eth_chainId", []], ["eth_getBlockByNumber", ["latest", false]], ["eth_call", [{ to: a.ledgerReads, data: describeData }, "latest"]], ["eth_getStorageAt", [a.ledgerProxy, IMPLEMENTATION_SLOT, "latest"]],
  ]);
  const pinned = decodeFunctionResult({ abi: abiOf("LedgerReads"), functionName: "describe", data: describeRaw });
  const impl = getAddress(`0x${implWord.slice(26)}`);
  const getCodes = [impl, a.ledgerReads, a.ledgerViews]; // the two readers of §12.3 are not in this release
  const codes = await rpc.batch(getCodes.map((x) => ["eth_getCode", [x, block.number]]));
  eq("coldpin chainId", Number(chainHex), pinned.acceptedChainId);
  eq("coldpin impl", impl, pinned.ledgerImpl);
  eq("coldpin impl-codehash", keccak256(codes[0]), pinned.ledgerImplCodehash);
  eq("coldpin impl-release", keccak256(codes[0]), plan.units.LedgerCore.runtimeCodehash);
  eq("coldpin reads-codehash", keccak256(codes[1]), pinned.thisFacetCodehash);
  eq("coldpin views-codehash", keccak256(codes[2]), plan.units.LedgerViews.runtimeCodehash);
  const coldCalls = Object.values(rpc.counts).reduce((x, y) => x + y, 0);
  const coldEnvelopes = rpc.envelopes;

  const total = Object.values(checked).reduce((x, y) => x + y, 0);
  console.log(`efs-fixture verify: ${total} checks (${Object.entries(checked).map(([k, v]) => `${k} ${v}`).join(", ")})`);
  console.log(`efs-fixture verify: test/harness/doubles/Factory.sol RUNTIME ${harnessNote}`);
  console.log(`efs-fixture verify: describe() fields not compared: ${uncheckedDescribe.length ? uncheckedDescribe.join(", ") : "none"}`);
  console.log(`efs-fixture verify: cold pin = ${coldCalls} logical calls in ${coldEnvelopes} HTTP envelopes (${Object.entries(rpc.counts).map(([k, v]) => `${k}×${v}`).join(", ")}); design bound ≤ 9 calls, ≤ 2 envelopes`);
  if (coldCalls > 9 || coldEnvelopes > 2) failures.push(`coldpin bound: ${coldCalls} calls / ${coldEnvelopes} envelopes`);
  if (failures.length) {
    console.error(`efs-fixture verify: ${failures.length} mismatch(es):`);
    for (const f of failures) console.error(`  ${f}`);
    process.exit(1);
  }
  console.log("efs-fixture verify: OK — every address, runtime, describe() field, executionSet(), manifestHash(), Type id and seed row matches");
}

/** The current revision's ComponentSet, read through LedgerReads.revisionAt (what the activation pinned). */
async function revisionComponents(pub, ledger, reads) {
  const rev = await read(pub, ledger, "LedgerCore", "revision");
  const [, r] = await read(pub, reads, "LedgerReads", "revisionAt", [ledger, rev]);
  return r.components;
}

// ---- down ----------------------------------------------------------------------------------------------------------

async function down() {
  if (!existsSync(PID)) { console.log("efs-fixture: no pid file; nothing to stop"); return; }
  const pid = Number(readFileSync(PID, "utf8"));
  if (alive(pid)) {
    const comm = commOf(pid).split("/").pop();
    assert.equal(comm, "anvil", `pid ${pid} from ${PID} is '${comm}', not anvil: refusing to kill it`);
    process.kill(pid, "SIGTERM");
    for (let i = 0; i < 50 && alive(pid); i++) await sleep(100);
    if (alive(pid)) process.kill(pid, "SIGKILL");
    console.log(`efs-fixture: stopped anvil pid ${pid}`);
  } else console.log(`efs-fixture: anvil pid ${pid} already gone`);
  rmSync(PID);
}

// ---- CLI -----------------------------------------------------------------------------------------------------------

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, ...rest] = process.argv.slice(2);
  const o = parseArgs(rest, ["port", "chain-id", "realm-salt", "ttl"]);
  if (cmd === "up") await up(o);
  else if (cmd === "verify") await verify();
  else if (cmd === "down") await down();
  else {
    console.error("usage: node tools/efs-fixture.mjs up [--port N] [--chain-id N] [--realm-salt 0x…] [--ttl S] | verify | down");
    process.exit(2);
  }
}

export { rpcClient, clients };
