// SPDX-License-Identifier: MIT
// The local fixture of design §13 / §12.3 row "deploy locally": named anvil instances, any number at once, each with
// its own lease in the machine-wide registry (tools/fixture-registry.mjs), its own port and its own state directory.
// `up` executes the genesis plan of §8.2 step by step (tools/deploy-plan.mjs computes every address and hash
// offline first), registers the ten Files Types and writes the seed (the root, docs/, and three files: inline,
// chunked into a span tree, and at an external locator) as the fixture
// principal, every transaction signed locally (eth_sendRawTransaction). `verify` recomputes everything from the
// artifacts and compares it with the chain; `down` stops only the anvil its lease records, after checking that the
// process is still that anvil. Nothing an instance writes is a tracked file.
//
//   node tools/efs-fixture.mjs up      [--name N] [--port P | --port-range LO-HI] [--chain-id 31337]
//                                      [--realm-salt 0x… | --fresh] [--ttl 900 | --ttl 0 | --keep] [--no-unlocked]
//                                      [--hardfork osaka|prague]   (default osaka: the EIP-7825 gas cap is enforced)
//                                      [--state-dir DIR] [--artifacts DIR] [--plan FILE] [--no-verify]
//                                      [--keep-on-fail] [--write-release] [--json]
//   node tools/efs-fixture.mjs verify  [--name N] [--documents DIR | --release] [--json]
//   node tools/efs-fixture.mjs status  [--name N] [--json]        (no name: the same as list)
//   node tools/efs-fixture.mjs list    [--kind chain|gateway|ui] [--json]
//   node tools/efs-fixture.mjs down    [--name N] [--purge] [--json]
//   node tools/efs-fixture.mjs reset   [--name N] [--fresh] [--chain-id N] [--json]
//   node tools/efs-fixture.mjs gc      [--purge] [--json]
//
// Without --name, verify/status/down/reset use $EFS_FIXTURE_NAME, else the one chain instance this checkout owns.
// Exit codes: 0 ok, 1 verification mismatch, 2 usage, 3 port or lease conflict, 4 instance not found or dead,
// 5 any other failure (stale artifacts, anvil did not start, a deploy step failed). tools/RELEASE.md has the rest.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { concat as concatHex, createPublicClient, createWalletClient, custom, decodeAbiParameters, decodeFunctionResult, defineChain, encodeErrorResult, encodeFunctionData, getAddress, hexToString, keccak256, pad, sha256, size, toHex, zeroAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  ADMIN_SLOT, DEFAULTS, FACTORY, FACTORY_RUNTIME, FIXTURE_KEY, IMPLEMENTATION_SLOT,
  FLOOR_LIMIT_FIELDS, buildPlan, domainSeparator, executionSet, jsonable, keys, limitsProfileId, planDocument, priceMismatches, root, toJSON, validate,
} from "./deploy-plan.mjs";
import {
  DEFAULT_RANGES, EXIT, FixtureError, allocate, assertName, defaultName, gc as registryGc, instanceDir, leasePath, list as registryList,
  lookup, procInfo, procMatches, registryHome, release, update,
} from "./fixture-registry.mjs";

export { DEFAULT_RANGES, EXIT, FixtureError, KINDS, allocate, gc as registryGc, lookup, registryHome, release, update } from "./fixture-registry.mjs";

/** release/ of the repository the plan's artifacts belong to (this checkout, or a release directory). */
const relDir = (plan) => join(plan.local.repoRoot, "release");
export const DEFAULT_TTL = 900;
/** The local chain's rules. "osaka" is what mainnet and Sepolia run (Fusaka): anvil then enforces EIP-7825's
 *  per-transaction gas limit cap, but only with --enable-tx-gas-limit (measured on anvil 1.8.3: without the flag, or
 *  under prague with it, a 20M-gas transaction is accepted). The contracts are still compiled for prague. */
export const HARDFORKS = { osaka: { args: ["--hardfork", "osaka", "--enable-tx-gas-limit"], txGasCap: 16_777_216, feeSchedule: "prague" }, prague: { args: ["--hardfork", "prague"], txGasCap: null, feeSchedule: "prague" } };
export const DEFAULT_HARDFORK = "osaka";
/** anvil's ten default accounts (mnemonic "test test … junk"); index 0 is the fixture key. Public throwaways. */
export const DEFAULT_ACCOUNTS = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906", "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
  "0x976EA74026E726554dB657fA54763abd0C3a0aa9", "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955", "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
  "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
];
const DEFAULT_BALANCE_ETH = 10000;
/** Methods the fixture never sends: it signs every transaction itself. */
const UNSIGNED = new Set(["eth_sendTransaction", "eth_sign", "eth_signTransaction", "eth_signTypedData", "eth_signTypedData_v4", "personal_sign"]);
const STATE_FILES = ["anvil.pid", "anvil.log", "fixture.json", "efs-deployment.json", "expected.json", "up.json"];

// ---- JSON-RPC with call counting -----------------------------------------------------------------------------------

function rpcClient(url, { forbid = new Set(), timeoutMs = 60_000 } = {}) {
  let id = 0;
  const counts = {};
  let envelopes = 0;
  const post = async (body) => {
    envelopes++;
    const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
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
  const guard = (method) => { if (forbid.has(method)) throw new Error(`${method} refused: the fixture signs every transaction locally (eth_sendRawTransaction)`); };
  const call = async (method, params = []) => {
    guard(method);
    counts[method] = (counts[method] ?? 0) + 1;
    return unwrap(method, await post({ jsonrpc: "2.0", id: ++id, method, params }));
  };
  /** One HTTP envelope carrying several logical calls. */
  const batch = async (reqs) => {
    for (const [m] of reqs) { guard(m); counts[m] = (counts[m] ?? 0) + 1; }
    const body = reqs.map(([method, params]) => ({ jsonrpc: "2.0", id: ++id, method, params }));
    const out = await post(body);
    const byId = new Map(out.map((r) => [r.id, r]));
    return body.map((b) => unwrap(b.method, byId.get(b.id)));
  };
  const reset = () => { for (const k of Object.keys(counts)) delete counts[k]; envelopes = 0; };
  return { call, batch, counts, reset, get envelopes() { return envelopes; } };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function clients(url, chainId, opts = {}) {
  const rpc = rpcClient(url, opts);
  const chain = defineChain({ id: chainId, name: `efs-fixture-${chainId}`, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [url] } } });
  const transport = custom({ request: ({ method, params }) => rpc.call(method, params) });
  const account = privateKeyToAccount(FIXTURE_KEY);
  const pub = createPublicClient({ chain, transport, pollingInterval: 50 });
  const wallet = createWalletClient({ chain, transport, account });
  return { rpc, pub, wallet, account, chain };
}

/** Readers bound to one plan's ABIs (several plans, from several artifact sources, may be live in one process). */
function bind(plan) {
  const abiOf = (name) => { const abi = plan.local.abis[name]; assert.ok(abi, `no ABI for ${name}`); return abi; };
  const read = (pub, address, name, functionName, args = []) => pub.readContract({ address, abi: abiOf(name), functionName, args });
  return { abiOf, read };
}

// ---- options -------------------------------------------------------------------------------------------------------

const quiet = () => {};
const pretty = (p) => { const r = relative(process.cwd(), p); return r === "" ? "." : r.startsWith("..") ? p : r; };
const fail = (code, message, exitCode, details) => { throw new FixtureError(code, message, exitCode, details); };
const toInt = (v, what) => {
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) fail("BAD_OPTION", `${what} must be a non-negative integer (got ${JSON.stringify(v)})`, EXIT.USAGE);
  return n;
};
const isSalt = (s) => typeof s === "string" && /^0x[0-9a-fA-F]{64}$/.test(s);
const anvilLike = (lease) => !!lease.command && /^(\S*\/)?anvil\s/.test(lease.command) && lease.command.includes(` --port ${lease.port} `);

/** The instance an omitted --name means: $EFS_FIXTURE_NAME, else the single chain lease this checkout owns. */
function resolveName(name, home) {
  if (name) return assertName(name);
  if (process.env.EFS_FIXTURE_NAME) return assertName(process.env.EFS_FIXTURE_NAME);
  const own = registryList({ kind: "chain", home }).filter((l) => l.checkout === root);
  if (own.length === 1) return own[0].name;
  if (own.length === 0) fail("NO_INSTANCE", `no chain instance is leased from ${root}; pass --name (see \`efs-fixture list\`)`, EXIT.NOT_FOUND);
  return fail("AMBIGUOUS", `${own.length} chain instances are leased from this checkout (${own.map((l) => l.name).join(", ")}); pass --name`, EXIT.USAGE);
}
function requireLease(name, home, { live = true } = {}) {
  const lease = lookup(name, home);
  if (!lease) fail("NO_INSTANCE", `no instance named ${JSON.stringify(name)} in ${home}`, EXIT.NOT_FOUND);
  if (lease.kind !== "chain") fail("NOT_A_CHAIN", `instance ${name} is a ${lease.kind} lease; only chain instances are managed here`, EXIT.USAGE);
  if (live && lease.liveness !== "live") fail("INSTANCE_DEAD", `instance ${name} is ${lease.liveness} (pid ${lease.pid}${lease.expired ? ", past its TTL" : ""}); run \`efs-fixture gc\` or \`up --name ${name}\``, EXIT.NOT_FOUND, { lease });
  return lease;
}

// ---- up ------------------------------------------------------------------------------------------------------------

/**
 * Start a named chain instance and deploy + seed it. Options (CLI flags in camelCase): name, port, portRange, host,
 * chainId, realmSalt, fresh, ttl (seconds; 0 = none), keep, unlocked (default true), stateDir, artifacts (an artifact
 * directory: a forge build, a snapshot or a committed artifacts/ directory; default $EFS_ARTIFACTS_DIR, else out/),
 * plan (a deploy/plan.json the computed plan must equal), verify (default true: run every verify check before the
 * instance is marked ready), keepOnFail (keep a failed instance for inspection), writeRelease, home, log (a console.log-like function;
 * default: none), generation.
 * @returns {Promise<object>} the `up` result (tools/RELEASE.md "JSON contract")
 */
export async function up(o = {}) {
  const log = o.log ?? quiet;
  const home = o.home ?? registryHome();
  const name = assertName(o.name ?? process.env.EFS_FIXTURE_NAME ?? defaultName(root));
  const planFile = o.plan ? resolve(o.plan) : null;
  let planOnDisk = null;
  if (planFile) {
    try { planOnDisk = JSON.parse(readFileSync(planFile, "utf8")); } catch (e) { fail("BAD_PLAN", `--plan ${planFile}: ${e.message}`, EXIT.USAGE); }
    if (planOnDisk.schema !== "efs-deploy-plan/1") fail("BAD_PLAN", `--plan ${planFile} is not an efs-deploy-plan/1 document`, EXIT.USAGE);
    if (o.fresh) fail("BAD_OPTION", "--plan fixes the realm salt; it cannot be combined with --fresh", EXIT.USAGE);
  }
  const chainId = o.chainId === undefined ? planOnDisk?.chainId ?? DEFAULTS.chainId : toInt(o.chainId, "--chain-id");
  if (chainId === 0) fail("BAD_OPTION", "--chain-id must be positive", EXIT.USAGE);
  if (o.fresh && o.realmSalt) fail("BAD_OPTION", "--fresh and --realm-salt are exclusive", EXIT.USAGE);
  const realmSalt = o.fresh ? toHex(randomBytes(32)) : o.realmSalt ?? planOnDisk?.realmSalt ?? DEFAULTS.realmSalt;
  if (!isSalt(realmSalt)) fail("BAD_OPTION", `--realm-salt must be 0x + 64 hex digits (got ${realmSalt})`, EXIT.USAGE);
  const ttl = o.keep ? 0 : o.ttl === undefined ? DEFAULT_TTL : toInt(o.ttl, "--ttl");
  const unlocked = o.unlocked !== false;
  const hardfork = o.hardfork ?? DEFAULT_HARDFORK;
  if (!HARDFORKS[hardfork]) fail("BAD_OPTION", `--hardfork ${hardfork}: one of ${Object.keys(HARDFORKS).join(", ")}`, EXIT.USAGE);
  const host = o.host ?? "127.0.0.1";
  if (!["127.0.0.1", "::1", "localhost"].includes(host)) fail("BAD_OPTION", `--host ${host}: the fixture binds loopback only (127.0.0.1, ::1)`, EXIT.USAGE);
  const port = o.port === undefined || o.port === null ? undefined : toInt(o.port, "--port");
  if (o.writeRelease && (chainId !== DEFAULTS.chainId || realmSalt !== DEFAULTS.realmSalt)) fail("NOT_DEFAULT", "--write-release writes the committed sample, which is defined only on the default configuration (chain 31337, the default realm salt)", EXIT.USAGE);
  const stateDir = resolve(o.stateDir ?? instanceDir(name, home));

  // the plan first: every address and hash is known before anything is deployed (and stale artifacts fail here)
  let plan;
  try { plan = await buildPlan({ chainId, realmSalt, artifacts: o.artifacts }); } catch (e) { fail("ARTIFACTS", `the plan cannot be built: ${e.message}`, EXIT.FAILURE); }
  const planHash = planDocument(plan).planHash;
  if (planOnDisk && (planOnDisk.planHash !== planHash || planOnDisk.chainId !== chainId || planOnDisk.realmSalt !== realmSalt)) {
    fail("PLAN_MISMATCH", `the plan computed from ${plan.local.artifacts.dir} for chain ${chainId} / salt ${realmSalt} has planHash ${planHash}; ${planFile} says ${planOnDisk.planHash} (chain ${planOnDisk.chainId})`, EXIT.MISMATCH);
  }
  if (o.writeRelease && plan.local.repoRoot !== root) fail("NOT_DEFAULT", "--write-release writes this checkout's committed sample; it needs this checkout's artifacts", EXIT.USAGE);

  const meta = {
    chainId, realmSalt, realmId: plan.realm.realmId, ledger: plan.addresses.ledgerProxy, registry: plan.addresses.registryProxy,
    layoutId: plan.layoutId, checkout: root, artifacts: plan.local.artifacts.dir, artifactsMode: plan.local.artifacts.mode, plan: planFile, stateDir, unlocked, signerCapable: unlocked, hardfork, txGasCap: HARDFORKS[hardfork].txGasCap, generation: o.generation ?? 1,
    deployment: join(stateDir, "efs-deployment.json"), expected: join(stateDir, "expected.json"), journal: join(stateDir, "fixture.json"), log: join(stateDir, "anvil.log"),
  };
  let lease;
  let child = null;
  const skipPorts = [];
  try {
    for (let attempt = 0; ; attempt++) {
      lease = await allocate({ kind: "chain", name, port, range: o.portRange, skipPorts, host: host === "localhost" ? "127.0.0.1" : host, ttl, meta, home });
      mkdirSync(stateDir, { recursive: true });
      for (const f of STATE_FILES) rmSync(join(stateDir, f), { force: true });
      log(`efs-fixture: instance ${name} leased port ${lease.port} (${leasePath(name, home)})`);
      const started = await startAnvil({ lease, chainId, ttl, unlocked, stateDir, hardfork });
      if (started.ok) { child = started.child; break; }
      // the child's bind is authoritative: someone outside the registry took the port between probe and bind
      release(name, home);
      if (port !== undefined) fail("PORT_BUSY", `anvil could not bind port ${port}: ${started.reason}`, EXIT.CONFLICT, { port });
      if (!started.bind || attempt >= 4) fail("ANVIL_START", `anvil did not start: ${started.reason}`, EXIT.FAILURE, { log: meta.log });
      skipPorts.push(lease.port);
      log(`efs-fixture: port ${lease.port} was taken before anvil bound it; trying another`);
    }
    const info = child.info;
    lease = update(name, { pid: info.pid, startTime: info.startTime, command: info.command, state: "deploying" }, home);
    writeFileSync(join(stateDir, "anvil.pid"), `${info.pid}\n`);
    const url = lease.url;
    log(`efs-fixture: anvil pid ${info.pid} on ${url} (chain ${chainId}, hardfork ${hardfork}${HARDFORKS[hardfork].txGasCap ? `, tx gas cap ${HARDFORKS[hardfork].txGasCap}` : ""}, ${ttl ? `ttl ${ttl}s` : "no ttl"}, ${unlocked ? "default accounts unlocked" : "no unlocked accounts"})`);

    const { rpc, pub, wallet, account } = clients(url, chainId, { forbid: UNSIGNED });
    const signer = await signerProbe(url, unlocked);
    if (signer.signerCapable !== unlocked) fail("SIGNER", `anvil reports ${signer.accounts} unlocked account(s), expected ${unlocked ? DEFAULT_ACCOUNTS.length : 0}`, EXIT.FAILURE);
    const { journal, factoryMethod } = await deploy({ plan, rpc, pub, wallet, log, instance: { pid: info.pid, log: meta.log } });
    const reads = await readEstimates(rpc, plan, account.address);
    log(`efs-fixture: genesis + registration + seed done (${journal.length} transactions, all eth_sendRawTransaction; factory via ${factoryMethod})`);

    const chain = await chainFacts(pub, hardfork);
    const deployment = await deploymentDocument({ plan, planHash, pub, url, factoryMethod, journal, account, signer, chain });
    const expected = expectedDocument(plan, deployment);
    writeFileSync(meta.deployment, toJSON(deployment));
    writeFileSync(meta.expected, toJSON(expected));
    writeFileSync(meta.journal, toJSON({ schema: "efs-fixture-state/1", name, url, port: lease.port, chainId, realmSalt, pid: info.pid, ttl, startedAt: lease.startedAt, factoryMethod, signer, hardfork, rpcCalls: { ...rpc.counts }, journal, reads }));

    // the instance is ready only once every verify check has passed against it
    let verified = { skipped: true };
    if (o.verify !== false) {
      lease = update(name, { state: "verifying" }, home);
      const t0 = Date.now();
      const v = await verify({ name, home, log });
      verified = { skipped: false, ok: v.ok, checks: v.checks, failures: v.failures.length, ms: Date.now() - t0, coldPin: v.coldPin };
      if (!v.ok) {
        if (o.keepOnFail) {
          lease = update(name, { state: "failed", verified }, home);
          throw new FixtureError("VERIFY_FAILED", `instance ${name} failed ${v.failures.length} of ${v.checks} checks; kept for inspection (--keep-on-fail): stop it with down --name ${name}`, EXIT.MISMATCH, { name, failures: v.failures, kept: true, rpcUrl: url, port: lease.port });
        }
        throw new FixtureError("VERIFY_FAILED", `instance ${name} failed ${v.failures.length} of ${v.checks} checks; torn down`, EXIT.MISMATCH, { name, failures: v.failures, kept: false });
      }
    }
    let releaseWritten = null;
    if (o.writeRelease) {
      writeFileSync(join(relDir(plan), "efs-deployment.json"), toJSON(deployment));
      writeFileSync(join(relDir(plan), "expected.json"), toJSON(expected));
      releaseWritten = ["release/efs-deployment.json", "release/expected.json"];
      log("efs-fixture: wrote the committed sample release/efs-deployment.json and release/expected.json");
    }
    const capabilities = capabilitiesOf(plan, signer, chain);
    lease = update(name, { state: "ready", readyAt: new Date().toISOString(), verified, signerCapable: signer.signerCapable, capabilities, planHash, seedVersion: plan.seed.version, root: plan.seed.root, seed: seedIds(plan) }, home);
    const result = { ...upResult(lease, plan, { home, releaseWritten }), verified };
    writeFileSync(join(stateDir, "up.json"), toJSON(result));
    log(`efs-fixture: ${name} ready — rpc ${url}, ledger ${plan.addresses.ledgerProxy}, root ${plan.seed.root.directoryRecordId}`);
    log(`efs-fixture: documents in ${pretty(stateDir)}; ${lease.expiresAt ? `expires ${lease.expiresAt}` : "no expiry (stop it with down)"}; export EFS_FIXTURE_NAME=${name}`);
    return result;
  } catch (e) {
    if (e instanceof FixtureError && e.details?.kept) throw e; // --keep-on-fail: the instance stays, leased, state "failed"
    // never leave our own anvil behind: kill the child this call spawned (it is ours by construction) and free the lease
    if (child?.info && procMatches(child.info)) await stopPid(child.info.pid);
    if (lease && lookup(name, home)?.owner?.pid === process.pid) release(name, home);
    if (e instanceof FixtureError) throw e;
    throw new FixtureError("UP_FAILED", e.message, EXIT.FAILURE, { log: meta.log });
  }
}

/** Spawn the owned anvil under the watchdog and wait until it answers. Returns {ok, child:{info}} or {ok:false, bind, reason}. */
async function startAnvil({ lease, chainId, ttl, unlocked, stateDir, hardfork }) {
  const args = ["--port", String(lease.port), "--host", lease.host, "--chain-id", String(chainId), ...HARDFORKS[hardfork].args, "--disable-default-create2-deployer"];
  if (!unlocked) args.push("--accounts", "0", "--fund-accounts", ...DEFAULT_ACCOUNTS.map((a) => `${a}:${DEFAULT_BALANCE_ETH}`));
  const logPath = join(stateDir, "anvil.log");
  const fd = openSync(logPath, "w");
  // perl execs anvil, so the pid is anvil's own and SIGALRM ends it after ttl seconds even if `down` never runs
  const child = ttl > 0
    ? spawn("perl", ["-e", `alarm ${ttl}; exec @ARGV`, "anvil", ...args], { detached: true, stdio: ["ignore", fd, fd] })
    : spawn("anvil", args, { detached: true, stdio: ["ignore", fd, fd] });
  closeSync(fd);
  child.unref();
  let spawnError = null;
  child.once("error", (e) => { spawnError = e; });
  const exited = () => spawnError || child.exitCode !== null || child.signalCode !== null;
  const logText = () => { try { return readFileSync(logPath, "utf8"); } catch { return ""; } };
  const rpc = rpcClient(lease.url, { timeoutMs: 2000 });
  for (let i = 0; i < 600; i++) {
    await sleep(50);
    if (exited()) {
      const text = logText();
      return { ok: false, bind: /address already in use|addrinuse|os error 48|os error 98/i.test(text), reason: spawnError?.message ?? (text.trim().split("\n").slice(-3).join(" | ") || `exit ${child.exitCode ?? child.signalCode}`) };
    }
    const info = procInfo(child.pid);
    if (!info || !/^(\S*\/)?anvil\s/.test(info.command) || !logText().includes("Listening on")) continue;
    try {
      if (Number(await rpc.call("eth_chainId")) !== chainId) continue;
    } catch { continue; }
    return { ok: true, child: { info } };
  }
  try { process.kill(child.pid, "SIGKILL"); } catch { /* gone */ }
  return { ok: false, bind: false, reason: "anvil did not answer within 30 s" };
}

/** What anvil itself says about signing: unlocked accounts, and whether an unsigned send is refused. */
async function signerProbe(url, unlocked) {
  const rpc = rpcClient(url);
  const accounts = await rpc.call("eth_accounts");
  if (unlocked) {
    assert.deepEqual(accounts.map((a) => a.toLowerCase()), DEFAULT_ACCOUNTS.map((a) => a.toLowerCase()), "anvil's unlocked accounts are not the ten default accounts");
    return { signerCapable: true, accounts: accounts.length, unsignedSend: "accepted (anvil holds the ten default keys)", signing: "local (eth_sendRawTransaction)" };
  }
  let refused = null;
  try { await rpc.call("eth_sendTransaction", [{ from: DEFAULT_ACCOUNTS[0], to: DEFAULT_ACCOUNTS[1], value: "0x0" }]); } catch (e) { refused = e.rpc?.message ?? e.message; }
  if (refused === null) fail("SIGNER", "anvil accepted an unsigned eth_sendTransaction although it was started with --accounts 0", EXIT.FAILURE);
  const balance = BigInt(await rpc.call("eth_getBalance", [DEFAULT_ACCOUNTS[9], "latest"]));
  assert.equal(balance, BigInt(DEFAULT_BALANCE_ETH) * 10n ** 18n, "the default accounts are not funded");
  return { signerCapable: accounts.length > 0, accounts: accounts.length, unsignedSend: `refused (${refused})`, signing: "local (eth_sendRawTransaction)" };
}

/** The seed's ids a guest-read test asserts against without re-deriving them. */
function seedIds(plan) {
  const s = plan.seed;
  return {
    version: s.version,
    root: s.root,
    folder: { name: s.folder.name, directoryRecordId: s.folder.directoryRecordId },
    file: { name: s.file.name, subjectId: s.file.subjectId, headRecordId: s.file.rootRecordId, headRevision: 1 },
    files: s.files.map((f) => {
      const base = { name: f.name, subjectId: f.subjectId, headRecordId: f.headRecordId, headRevision: f.headRevision, form: f.form, length: f.length, sha256: f.sha256 };
      if (f.contentRecordId) return { ...base, contentRecordId: f.contentRecordId, media: f.media, spanRootId: f.spanRootId, chunkCount: f.chunkCount, spanCount: f.spanCount, chunkPayload: f.chunkPayload, publications: f.publications };
      if (f.externalRecordId) return { ...base, externalRecordId: f.externalRecordId, sentinelRecordId: f.sentinelRecordId, locator: f.locator, media: f.media };
      return base;
    }),
  };
}

/** What the chain enforced when the instance was deployed: a snapshot, not live truth. A block gas limit moves and a
 *  later fork changes what the per-transaction cap counts, so a client reads the live values and treats these as
 *  defaults. `txGasCap` is null where nothing enforces one. */
async function chainFacts(pub, hardfork) {
  const block = await pub.getBlock({ blockTag: "latest" });
  const cap = HARDFORKS[hardfork].txGasCap;
  // feeSchedule names the key of release.json gasModel.schedules that prices this chain (osaka did not reprice storage)
  return { hardfork, feeSchedule: HARDFORKS[hardfork].feeSchedule, txGasCap: cap, txGasCapEnforced: cap !== null, txGasCapRule: cap === null ? null : "EIP-7825: a transaction whose gas limit exceeds the cap is rejected", blockGasLimit: Number(block.gasLimit), atBlock: Number(block.number), snapshot: "taken when the instance was deployed; read live values from the chain" };
}

function capabilitiesOf(plan, signer, chain) {
  return {
    filesSeed: plan.seed.version,
    filesTypes: plan.profile.length,
    seedFiles: plan.seed.files.map((f) => f.name),
    largeFiles: plan.seed.files.some((f) => f.contentRecordId),
    externalLocations: plan.seed.files.some((f) => f.externalRecordId),
    keysView: !!plan.addresses.keysView,
    web3Gateway: !!plan.addresses.web3Gateway,
    readers: [plan.readers.lens.kindLabel, plan.readers.filesPage.kindLabel, plan.readers.topicMine.kindLabel, plan.readers.topicEveryone.kindLabel, plan.readers.topicLookup.kindLabel],
    signerCapable: signer.signerCapable,
    unlockedAccounts: signer.accounts,
    hardfork: chain.hardfork,
    txGasCap: chain.txGasCap,
  };
}

function upResult(lease, plan, { home, releaseWritten }) {
  const a = plan.addresses;
  return {
    ok: true, command: "up", name: lease.name, kind: lease.kind, generation: lease.generation,
    rpcUrl: lease.url, host: lease.host, port: lease.port, chainId: lease.chainId, realmSalt: lease.realmSalt, realmId: plan.realm.realmId,
    pid: lease.pid, stateDir: lease.stateDir, deployment: lease.deployment, expected: lease.expected, journal: lease.journal, log: lease.log,
    ledger: a.ledgerProxy, registry: a.registryProxy, controller: a.controller,
    readers: { ledgerReads: a.ledgerReads, ledgerViews: a.ledgerViews, readerDirectory: a.readerDirectory, lensReader: a.lensReader, filesPageReader: a.filesPageReader, topicMineReader: a.topicMineReader, topicEveryoneReader: a.topicEveryoneReader, topicLookupReader: a.topicLookupReader, keysView: a.keysView, web3Gateway: a.web3Gateway, web3Content: a.web3Content },
    keysView: a.keysView,
    web3Gateway: a.web3Gateway,
    web3Url: `${plan.gateway.urlBase}~efs/o/${plan.gateway.rootDirectory}/`,
    layoutId: plan.layoutId, root: plan.seed.root, seed: seedIds(plan), typeIds: Object.fromEntries(plan.profile.map((p) => [p.type, p.typeId])),
    signerCapable: lease.signerCapable, capabilities: lease.capabilities,
    ttl: lease.ttl, startedAt: lease.startedAt, expiresAt: lease.expiresAt,
    planHash: lease.planHash, plan: lease.plan, checkout: lease.checkout, artifacts: lease.artifacts, artifactsMode: lease.artifactsMode,
    registryHome: home, lease: leasePath(lease.name, home), releaseWritten,
  };
}

/**
 * The receipt of `hash`, or a failure that says what the chain knew. viem's receipt wait swallows RPC errors while it
 * polls, so by itself a timeout cannot tell a dead node from an unmined transaction (seen once in CI: run 45902367913,
 * attempt 1). On a timeout this reads, straight from the node: the transaction by hash, its receipt, the head, the
 * sender's latest and pending nonces and the pool's content; and, when the caller knows them, whether the instance's
 * anvil process is alive and the tail of its log. The wait is 30 s by default, far above the 50 to 100 ms a local send
 * takes, so a stuck send fails fast.
 */
export async function receiptOrReport(pub, hash, { step = "?", sender = null, pid = null, logPath = null, timeoutMs = 30_000 } = {}) {
  try {
    return await pub.waitForTransactionReceipt({ hash, timeout: timeoutMs });
  } catch (e) {
    const ask = async (method, params = []) => { try { return await pub.request({ method, params }); } catch (x) { return `ERROR ${x.shortMessage ?? x.message}`.slice(0, 200); } };
    const tx = await ask("eth_getTransactionByHash", [hash]);
    const rc = await ask("eth_getTransactionReceipt", [hash]);
    let alive = null;
    if (pid !== null) { try { process.kill(pid, 0); alive = true; } catch { alive = false; } }
    let logTail = null;
    if (logPath) { try { logTail = readFileSync(logPath, "utf8").trim().split("\n").slice(-25); } catch (x) { logTail = `unreadable: ${x.message}`; } }
    const found = {
      step, hash, error: e.name, anvilPid: pid, anvilAlive: alive,
      transaction: tx && typeof tx === "object" ? { blockNumber: tx.blockNumber, nonce: tx.nonce, gas: tx.gas, from: tx.from } : tx,
      receipt: rc && typeof rc === "object" ? { blockNumber: rc.blockNumber, status: rc.status, gasUsed: rc.gasUsed } : rc,
      head: await ask("eth_blockNumber"),
      nonceLatest: sender ? await ask("eth_getTransactionCount", [sender, "latest"]) : null,
      noncePending: sender ? await ask("eth_getTransactionCount", [sender, "pending"]) : null,
      txpool: await ask("txpool_content"),
      logTail,
    };
    throw new Error(`no receipt for ${hash} within ${timeoutMs / 1000} s at step "${step}"; what the chain knew:\n${JSON.stringify(found, null, 2)}`, { cause: e });
  }
}

async function deploy({ plan, rpc, pub, wallet, log, instance = {} }) {
  const { read } = bind(plan);
  const journal = [];
  const record = async (step, hash) => {
    const r = await receiptOrReport(pub, hash, { step: step.id, sender: wallet.account.address, pid: instance.pid ?? null, logPath: instance.log ?? null });
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
      log(`efs-fixture: presigned factory tx refused (${e.message}); etching the runtime with anvil_setCode`);
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
      // on a resumed deployment the Realm may already be past genesis (G20b); the genesis set is checked only while it is live
      if ((await read(pub, ledger, "LedgerCore", "revision")) === 1) assert.equal(await read(pub, ledger, "LedgerCore", "executionSet"), plan.genesisActivation.expectedExecutionSet, "G20 executionSet");
    } else if (step.id === "G20b") {
      if ((await read(pub, ledger, "LedgerCore", "revision")) === 1) await send(step, step.to, step.data);
      assert.equal(await read(pub, ledger, "LedgerCore", "revision"), plan.activation.revision, "G20b revision");
      assert.equal(await read(pub, ledger, "LedgerCore", "executionSet"), plan.activation.expectedExecutionSet, "G20b executionSet");
    } else if (["R3", "R4", "R9", "R10", "R11"].includes(step.id)) {
      const [l, kind, reader] = step.args;
      const listed = await read(pub, step.to, "ReaderDirectory", "readers", [l, kind, 0, 16]);
      if (!listed[0].some((x) => x.toLowerCase() === reader.toLowerCase())) await send(step, step.to, step.data);
    } else if (step.id.startsWith("G21.")) {
      await send(step, step.to, step.data);
    } else if (step.kind === "EXECUTE") {
      // already done: its subject exists, or (a chunk-only publication) its last record does
      if (step.marker?.subject && (await read(pub, ledger, "LedgerCore", "subjectCreatedAt", [step.marker.subject])) !== 0n) continue;
      if (step.marker?.record && (await read(pub, ledger, "LedgerCore", "recordHeader", [step.marker.record]))[0] !== pad("0x", { size: 32 })) continue;
      await execute(pub, wallet, plan, step, instance);
      const r = await pub.getTransactionReceipt({ hash: step.txHash });
      journal.push({ id: step.id, label: step.label, txHash: step.txHash, blockNumber: Number(r.blockNumber), blockHash: r.blockHash, gasUsed: Number(r.gasUsed), publication: step.publication });
    }
  }
  return { journal, factoryMethod };
}

/** One native publication with both expectations bound (design Q22; `EfsNative.currentBind`). */
async function execute(pub, wallet, plan, step, instance = {}) {
  const { read, abiOf } = bind(plan);
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
  const r = await receiptOrReport(pub, hash, { step: step.id, sender: wallet.account.address, pid: instance.pid ?? null, logPath: instance.log ?? null });
  assert.equal(r.status, "success", `${step.id} reverted`);
  step.txHash = hash;
  step.publication = Number(publication);
  step.nonce = Number(nonce);
  step.ctx = jsonable(ctx);
}

/** The seeded folder's first page through FilesPageReader.listDirectory and the seeded file's record through
 *  LedgerReads.record: calldata, eth_estimateGas and returndata bytes on the fixture (prague). */
function readCalls(plan) {
  const a = plan.addresses;
  const page = { fields: 7, tagConcept: pad("0x", { size: 32 }), kinds: 0 }; // F_NAME | F_HEADER | F_KIND, every kind
  const unbound = { executionSet: pad("0x", { size: 32 }), revision: 0, indexGeneration: 0, registryMutations: 0n, admissionHighWater: 0n, phase: 0 };
  return [
    { row: "Read: FilesPageReader.listDirectory, the seeded folder docs/ (one page, limit 32, one principal, unbound basis)", contract: "FilesPageReader", to: a.filesPageReader, functionName: "listDirectory", args: [plan.seed.folder.directoryRecordId, [plan.seed.principalId], page, unbound, "0x", 32, 0n] },
    { row: "Read: LedgerReads.record of the seeded file's files-root/1 record", contract: "LedgerReads", to: a.ledgerReads, functionName: "record", args: [a.ledgerProxy, plan.seed.file.rootRecordId] },
  ];
}

async function readEstimates(rpc, plan, from) {
  const { abiOf } = bind(plan);
  const out = [];
  for (const c of readCalls(plan)) {
    const data = encodeFunctionData({ abi: abiOf(c.contract), functionName: c.functionName, args: c.args });
    const ret = await rpc.call("eth_call", [{ to: c.to, data }, "latest"]);
    const gas = Number(await rpc.call("eth_estimateGas", [{ from, to: c.to, data }, "latest"]));
    out.push({ row: c.row, to: c.to, function: c.functionName, calldataBytes: (data.length - 2) / 2, returndataBytes: (ret.length - 2) / 2, estimateGas: gas, rpcCalls: 1, note: "eth_estimateGas of a transaction to the view (includes the 21,000 intrinsic and calldata cost); one eth_call serves the read" });
  }
  return out;
}

async function deploymentDocument({ plan, planHash, pub, url, factoryMethod, journal, account, signer, chain }) {
  const { read } = bind(plan);
  const a = plan.addresses;
  const relPath = join(relDir(plan), "release.json");
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
    immutableReferences: { _admin: plan.local.proxyAdminImmutableOffsets },
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
    factory: { address: FACTORY.address, method: factoryMethod, deployer: FACTORY.deployer, presignedTx: FACTORY.presignedTx, runtimeCodehash: keccak256(FACTORY_RUNTIME()), harnessRuntimeMatches: plan.local.harnessFactoryRuntime === null ? null : plan.local.harnessFactoryRuntime === FACTORY_RUNTIME() },
    genesis: { address: a.genesis, nonces: plan.genesis.nonces, txHash: tx.G18?.txHash ?? null, blockNumber: tx.G18?.blockNumber ?? null, blockHash: tx.G18?.blockHash ?? null },
    // `activation` is the LIVE set (revision 2: the guard capability, step G20b); `genesisActivation` is revision 1 (G20)
    activation: { revision: plan.activation.revision, executionSet: d.executionSet, txHash: tx.G20b?.txHash ?? null, blockNumber: tx.G20b?.blockNumber ?? null, capabilities: plan.activation.capabilities, acceptedChainId: plan.chainId, dependencyRoot: plan.activation.dependencyRoot, set: jsonable(plan.activation) },
    genesisActivation: { revision: plan.genesisActivation.revision, executionSet: plan.genesisActivation.expectedExecutionSet, txHash: tx.G20?.txHash ?? null, blockNumber: tx.G20?.blockNumber ?? null, capabilities: plan.genesisActivation.capabilities },
    layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId,
    hotAbiIdString: plan.hotAbiIdString,
    executionProfileId: plan.executionProfileId,
    limits: plan.limits,
    limitsProfileId: plan.realm.limitsProfileId,
    domainSeparator: plan.realm.domainSeparator,
    noticePrincipal: plan.activation.noticePrincipal,
    ledger: a.ledgerProxy,
    registry: a.registryProxy,
    keysView: a.keysView,
    controller: { address: a.controller, owner: await read(pub, a.controller, "RealmController", "owner"), pendingOwner: await read(pub, a.controller, "RealmController", "pendingOwner"), frozen: await read(pub, a.controller, "RealmController", "frozen") },
    proxies: {
      ledger: await proxy(a.ledgerProxy, a.ledgerAdmin, a.ledgerImpl, g18.creates[2].initializer),
      registry: await proxy(a.registryProxy, a.registryAdmin, a.registryImpl, g18.creates[1].initializer),
    },
    contracts,
    index: { address: a.index, runtimeCodehash: plan.index.runtimeCodehash, reads: { address: a.indexReads, runtimeCodehash: plan.index.reads.runtimeCodehash }, generation: Number(d.indexGeneration), manifestHash: plan.index.manifestHash, indexObligations: plan.realm.indexObligations, stores: { posting: a.postingStore, bitmap: a.bitmapStore }, families: plan.index.families, units: plan.index.units, digestSpecs: plan.index.specs, workModel: plan.workModel },
    typeIds,
    profile: plan.profile.map(({ descriptor, declarationSig, ...p }) => p),
    privilegedRoles: { controllerOwner: account.address, ledgerProxyAdminOwner: a.controller, registryProxyAdminOwner: a.controller, steward: zeroAddress, noticePrincipal: plan.activation.noticePrincipal },
    readers: {
      ledgerReads: a.ledgerReads, ledgerViews: a.ledgerViews, readerDirectory: a.readerDirectory, keysView: a.keysView,
      lensReader: { address: a.lensReader, runtimeCodehash: plan.readers.lens.runtimeCodehash, kind: plan.readers.lens.kind, kindLabel: plan.readers.lens.kindLabel, ledger: a.ledgerProxy, views: a.ledgerViews, reads: a.ledgerReads, layoutId: plan.layoutId, txHash: tx.R1?.txHash ?? null },
      filesPageReader: { address: a.filesPageReader, runtimeCodehash: plan.readers.filesPage.runtimeCodehash, kind: plan.readers.filesPage.kind, kindLabel: plan.readers.filesPage.kindLabel, ledger: a.ledgerProxy, views: a.ledgerViews, reads: a.ledgerReads, layoutId: plan.layoutId, nameType: typeIds["files-name/3"], rootType: typeIds["files-root/1"], childType: typeIds["files-child/1"], txHash: tx.R2?.txHash ?? null },
      topicMineReader: { address: a.topicMineReader, runtimeCodehash: plan.readers.topicMine.runtimeCodehash, kind: plan.readers.topicMine.kind, kindLabel: plan.readers.topicMine.kindLabel, ledger: a.ledgerProxy, views: a.ledgerViews, reads: a.ledgerReads, layoutId: plan.layoutId, txHash: tx.R6?.txHash ?? null },
      topicEveryoneReader: { address: a.topicEveryoneReader, runtimeCodehash: plan.readers.topicEveryone.runtimeCodehash, kind: plan.readers.topicEveryone.kind, kindLabel: plan.readers.topicEveryone.kindLabel, ledger: a.ledgerProxy, views: a.ledgerViews, reads: a.ledgerReads, layoutId: plan.layoutId, txHash: tx.R7?.txHash ?? null },
      topicLookupReader: { address: a.topicLookupReader, runtimeCodehash: plan.readers.topicLookup.runtimeCodehash, kind: plan.readers.topicLookup.kind, kindLabel: plan.readers.topicLookup.kindLabel, ledger: a.ledgerProxy, views: a.ledgerViews, reads: a.ledgerReads, layoutId: plan.layoutId, topicType: typeIds["topic/1"], wordType: typeIds["topic-word/1"], txHash: tx.R8?.txHash ?? null },
      listed: await listedReaders(pub, plan),
      // ERC-5219 over web3:// (docs/LARGE-FILES.md): `${urlBase}0x<address>/<name>/…` (a home) or
      // `${urlBase}~efs/o/<folder id>/<name>/…` (a folder by id; the seed's root: its creator is the default lens)
      web3Gateway: { ...plan.gateway, ledger: a.ledgerProxy, reads: a.ledgerReads, views: a.ledgerViews, layoutId: plan.layoutId, seedUrl: `${plan.gateway.urlBase}~efs/o/${plan.gateway.rootDirectory}/`, txHash: tx.R5?.txHash ?? null },
    },
    seed: { ...seedIds(plan), transactions: plan.steps.filter((s) => s.kind === "EXECUTE").map((s) => ({ id: s.id, label: s.label, txHash: s.txHash ?? tx[s.id]?.txHash ?? null, publication: s.publication ?? tx[s.id]?.publication ?? null, actions: s.actions, bodies: s.bodies })) },
    root: plan.seed.root,
    defaultLensPrincipals: [plan.seed.principalId],
    actors: { owner: account.address, fixturePrincipal: account.address, fixturePrincipalId: plan.seed.principalId, declarationKey: account.address, fixtureKey: "anvil default account 0 (public test key; never use with value)", fundedAccounts: DEFAULT_ACCOUNTS },
    signerCapable: signer.signerCapable,
    signing: { transactions: signer.signing, unlockedAccounts: signer.accounts, unsignedSend: signer.unsignedSend },
    capabilities: capabilitiesOf(plan, signer, chain),
    chain,
    rpc: { url, chainId: plan.chainId, hardfork: chain.hardfork },
    evidenceGrade: "local-fixture",
  };
}

async function listedReaders(pub, plan) {
  const { read } = bind(plan);
  const out = [];
  for (const r of [plan.readers.lens, plan.readers.filesPage, plan.readers.topicMine, plan.readers.topicEveryone, plan.readers.topicLookup]) {
    const [readers, codehashes, layoutIds, physical] = await read(pub, plan.addresses.readerDirectory, "ReaderDirectory", "readers", [plan.addresses.ledgerProxy, r.kind, 0, 16]);
    readers.forEach((x, i) => out.push({ kind: r.kind, kindLabel: r.kindLabel, ordinal: i, reader: x, codehash: codehashes[i], layoutId: layoutIds[i], physicalProfile: physical[i] }));
  }
  return out;
}

function expectedDocument(plan, deployment) {
  const s = plan.seed;
  const t = deployment.typeIds;
  const records = [
    { id: s.root.directoryRecordId, typeId: t["files-directory/1"] },
    { id: s.folder.directoryRecordId, typeId: t["files-directory/1"] },
    { id: s.folder.nameRecordId, typeId: t["files-name/3"] },
  ];
  const heads = [{ key: s.folder.bindingKey, state: 1, revision: 1, target: s.folder.directoryRecordId, what: "FOLDER root/docs → docs directory" }];
  for (const f of s.files) {
    records.push({ id: f.headRecordId, typeId: t["files-root/1"] }, { id: f.nameRecordId, typeId: t["files-name/3"] });
    if (f.contentRecordId) records.push({ id: f.contentRecordId, typeId: t["files-content/1"] }, { id: f.spanRootId, typeId: f.spanCount ? t["files-span/1"] : t["files-bytes/1"] });
    if (f.externalRecordId) records.push({ id: f.externalRecordId, typeId: t["files-external/1"] }, { id: f.sentinelRecordId, typeId: t["files-bytes/1"] });
    heads.push(
      { key: f.headKey, state: 1, revision: f.headRevision, target: f.headRecordId, what: `HEAD ${f.name} → files-root/1 record (form ${f.form})` },
      { key: f.bindingKey, state: 1, revision: 1, target: f.subjectId, what: `FOLDER docs/${f.name} → file subject` },
    );
  }
  return {
    schema: "efs-fixture-expected/1",
    seedVersion: s.version,
    chainId: plan.chainId,
    ledger: plan.addresses.ledgerProxy,
    executionSet: plan.activation.expectedExecutionSet,
    revision: plan.activation.revision,
    root: s.root,
    folder: s.folder,
    file: { ...s.file, body: s.file.body },
    files: s.files,
    counts: s.counts,
    typeIds: deployment.typeIds,
    catalogCount: plan.profile.length,
    heads,
    records,
  };
}

/** A file's bytes from a chunk or span id, by LedgerReads.record point reads, every node checked on the way. */
async function readTree(read, pub, plan, id, out = { chunks: 0, spans: 0 }) {
  const a = plan.addresses;
  const tBytes = plan.profile.find((p) => p.type === "files-bytes/1").typeId;
  const tSpan = plan.profile.find((p) => p.type === "files-span/1").typeId;
  const [st, h, body] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, id]);
  if (st !== 2) throw new Error(`node ${id}: status ${st}, not PRESENT`);
  if (h.typeId.toLowerCase() === tBytes.toLowerCase()) {
    const payload = `0x${body.slice(66)}`;
    if (sha256(payload) !== h.word0.toLowerCase()) throw new Error(`chunk ${id}: payload does not hash to its word 0`);
    out.chunks++;
    return { bytes: payload, ...out };
  }
  if (h.typeId.toLowerCase() !== tSpan.toLowerCase()) throw new Error(`node ${id}: Type ${h.typeId} is neither files-bytes/1 nor files-span/1`);
  const [left, right, length] = decodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }], body);
  out.spans++;
  const lo = await readTree(read, pub, plan, left, out);
  const hi = await readTree(read, pub, plan, right, out);
  const bytes = concatHex([lo.bytes, hi.bytes]);
  if (BigInt(size(bytes)) !== length) throw new Error(`span ${id}: length ${length} != its bytes ${size(bytes)}`);
  return { bytes, ...out };
}

// ---- verify --------------------------------------------------------------------------------------------------------

/**
 * Every check of tools/RELEASE.md "What verify reproduces", against instance `name`'s chain. Options: name,
 * documents (a directory holding efs-deployment.json + expected.json; default the instance's state directory;
 * "release" = the committed sample), home, log. Returns {ok, failures, …}; ok false = exit 1.
 */
export async function verify(o = {}) {
  const log = o.log ?? quiet;
  const home = o.home ?? registryHome();
  const lease = requireLease(resolveName(o.name, home), home);
  const docDir = o.documents ? resolve(root, o.documents) : lease.stateDir;
  const depPath = join(docDir, "efs-deployment.json");
  const expPath = join(docDir, "expected.json");
  for (const p of [depPath, expPath]) if (!existsSync(p)) fail("NO_DOCUMENTS", `${p} is missing${o.documents ? "" : ` (instance ${lease.name} has not finished up: state ${lease.state})`}`, EXIT.NOT_FOUND);
  const dep = JSON.parse(readFileSync(depPath, "utf8"));
  const exp = JSON.parse(readFileSync(expPath, "utf8"));
  if (dep.chainId !== lease.chainId || dep.realmSalt !== lease.realmSalt) {
    fail("DOCUMENTS_MISMATCH", `${depPath} describes chain ${dep.chainId} / salt ${dep.realmSalt}, instance ${lease.name} runs chain ${lease.chainId} / salt ${lease.realmSalt}`, EXIT.MISMATCH);
  }
  const { rpc, pub } = clients(lease.url, lease.chainId, { forbid: UNSIGNED });
  let plan;
  try { plan = await buildPlan({ chainId: lease.chainId, realmSalt: lease.realmSalt, artifacts: lease.artifacts }); } catch (e) { fail("ARTIFACTS", `the plan cannot be built: ${e.message}`, EXIT.FAILURE); }
  const a = plan.addresses;
  const { read, abiOf } = bind(plan);
  const REL = relDir(plan);
  const failures = [];
  const checked = {};
  const eq = (what, got, want) => {
    checked[what.split(" ")[0]] = (checked[what.split(" ")[0]] ?? 0) + 1;
    const norm = (x) => (typeof x === "string" && /^0x[0-9a-fA-F]*$/.test(x) ? x.toLowerCase() : typeof x === "bigint" ? x.toString() : JSON.stringify(jsonable(x)));
    if (norm(got) !== norm(want)) failures.push(`${what}: chain ${norm(got)} != expected ${norm(want)}`);
  };
  const code = async (addr) => (await pub.getCode({ address: addr })) ?? "0x";

  // 0. the instance: its lease, its chain id and what anvil says about signing
  eq("instance chainId", Number(await rpc.call("eth_chainId")), lease.chainId);
  const unlocked = (await rpc.call("eth_accounts")).length;
  eq("instance signerCapable", unlocked > 0, lease.signerCapable);
  // the chain's rules: the recorded snapshot, and the per-transaction gas cap actually enforced (a refused
  // transaction changes no state, so this probe is safe to repeat)
  const hardfork = lease.hardfork ?? "prague";
  const cap = HARDFORKS[hardfork]?.txGasCap ?? null;
  const latest = await pub.getBlock({ blockTag: "latest" });
  eq("instance feeSchedule", dep.chain?.feeSchedule, HARDFORKS[hardfork]?.feeSchedule);
  eq("instance chain", [dep.chain?.hardfork, dep.chain?.txGasCap, dep.chain?.txGasCapEnforced, dep.chain?.blockGasLimit], [hardfork, cap, cap !== null, Number(latest.gasLimit)]);
  if (cap !== null) {
    const key = privateKeyToAccount(FIXTURE_KEY);
    const probe = await key.signTransaction({ chainId: lease.chainId, type: "eip1559", to: key.address, value: 0n, gas: BigInt(cap) + 1n, nonce: await pub.getTransactionCount({ address: key.address }), maxFeePerGas: (latest.baseFeePerGas ?? 0n) * 2n + 1_000_000_000n, maxPriorityFeePerGas: 0n });
    let refusal = null;
    try { await rpc.call("eth_sendRawTransaction", [probe]); } catch (e) { refusal = e.rpc?.message ?? e.message; }
    eq("instance txGasCap-enforced", refusal !== null, true);
  }
  if (dep.signerCapable !== undefined) eq("instance deployment.signerCapable", dep.signerCapable, unlocked > 0);

  // 1. the plan reproduces from the artifacts, and the published documents agree with it
  const planHash = planDocument(plan).planHash;
  eq("documents planHash", dep.planHash, planHash);
  const planFile = lease.plan ?? join(plan.local.repoRoot, "deploy/plan.json");
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
  const docs = [
    [planFile, "efs-deploy-plan-1.schema.json"], [join(REL, "release.json"), "efs-contracts-release-1.schema.json"], [join(REL, "errors.json"), "efs-errors-1.schema.json"],
    [join(plan.local.repoRoot, "gas/report.json"), "efs-gas-report-1.schema.json"], [depPath, "efs-deployment-1.schema.json"], [expPath, "efs-fixture-expected-1.schema.json"],
    [leasePath(lease.name, home), "efs-fixture-lease-1.schema.json"],
  ];
  for (const [file, schema] of docs) {
    if (!existsSync(file)) continue;
    const errs = validate(JSON.parse(readFileSync(file, "utf8")), schema);
    checked.schema = (checked.schema ?? 0) + 1;
    for (const e of errs) failures.push(`schema ${relative(root, file)}: ${e}`);
  }

  // 2. every address and runtime: byte-exact against the artifact with the planned immutables
  eq("code factory", await code(FACTORY.address), FACTORY_RUNTIME());
  eq("code factory-codehash", keccak256(FACTORY_RUNTIME()), "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989");
  const harness = plan.local.harnessFactoryRuntime;
  const harnessNote = harness === null ? "not present (a release directory without the test harness)" : harness === FACTORY_RUNTIME() ? "matches" : `differs (${(harness.length - 2) / 2} bytes vs ${(FACTORY_RUNTIME().length - 2) / 2}; see HARNESS-BUG in tools/RELEASE.md)`;
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
  eq("controller NOTICE_TYPE", await read(pub, a.controller, "RealmController", "NOTICE_TYPE"), plan.profile.find((p) => p.type === "realm-notice/1").typeId);
  eq("registry ledger", await read(pub, a.registryProxy, "TypeRegistry", "ledger"), a.ledgerProxy);
  eq("registry implementation", await read(pub, a.registryProxy, "TypeRegistry", "implementation"), a.registryImpl);
  eq("registry activeRevision", await read(pub, a.registryProxy, "TypeRegistry", "activeRevision"), plan.activation.revision);

  // 5. describe(): every field against the plan
  const d = await read(pub, a.ledgerReads, "LedgerReads", "describe", [a.ledgerProxy]);
  const set = plan.activation;
  const want = {
    realmId: plan.realm.realmId, realmOrigin: plan.realm.realmOrigin, realmSalt: plan.realmSalt, genesisChainId: BigInt(plan.chainId), acceptedChainId: BigInt(plan.chainId),
    chainNamespace: toHex("eip155", { size: 8 }), chainReference: pad(toHex(plan.chainId), { size: 32 }), executionSet: set.expectedExecutionSet, revision: set.revision, layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId, executionProfileId: plan.executionProfileId, capabilities: set.capabilities, ledgerImpl: a.ledgerImpl, ledgerImplCodehash: set.components.ledgerImplCodehash,
    ingress: a.ingress, ingressCodehash: set.components.ingressCodehash, applyDelegate: a.apply, applyCodehash: set.components.applyCodehash, registry: a.registryProxy,
    registryImpl: a.registryImpl, registryImplCodehash: set.components.registryImplCodehash, catalogCount: BigInt(plan.profile.length), index: a.index, indexCodehash: set.components.indexCodehash,
    indexGeneration: 1, indexManifestHash: plan.index.manifestHash, indexObligations: plan.realm.indexObligations, controller: a.controller, controllerCodehash: set.components.controllerCodehash,
    controllerOwner: plan.owner, steward: zeroAddress, frozen: false, phase: 0, readerDirectory: a.readerDirectory, thisFacet: a.ledgerReads, thisFacetCodehash: plan.units.LedgerReads.runtimeCodehash,
    facetVersion: 1, admissions: BigInt(exp.counts.admissions), records: BigInt(exp.counts.records), bindings: BigInt(exp.counts.bindings), publications: BigInt(exp.counts.publications),
    domainSeparator: plan.realm.domainSeparator, limitsProfileId: plan.realm.limitsProfileId, statusVocabularyId: keccak256(toHex("efs/status-vocabulary/1")),
    revisionBlock: BigInt(dep.activation.blockNumber), revisionAdmissionHigh: 0n, registryMutations: 1n,
    verifierProfilesRoot: pad("0x", { size: 32 }), dependencyRoot: pad("0x", { size: 32 }), noticePrincipal: pad("0x", { size: 32 }),
  };
  for (const [k, v] of Object.entries(want)) eq(`describe ${k}`, d[k], v);
  for (const [k, v] of Object.entries(plan.limits)) eq(`describe limits.${k}`, d.limits[k], v);
  const descriptionFields = abiOf("LedgerReads").find((i) => i.name === "describe").outputs[0].components.map((c) => c.name);
  const uncheckedDescribe = descriptionFields.filter((f) => !(f in want) && f !== "limits");

  // 6. the execution set, recomputed offline from the live revision row's components (design §8.1)
  const live = await read(pub, a.ledgerProxy, "LedgerCore", "executionSet");
  eq("executionSet live", live, set.expectedExecutionSet);
  const fromChain = { ...set, components: await revisionComponents(pub, plan, a.ledgerProxy, a.ledgerReads) };
  eq("executionSet recomputed-from-revision-row", executionSet(fromChain, a.ledgerProxy), live);
  eq("executionSet domainSeparator", domainSeparator(plan.chainId, a.ledgerProxy), d.domainSeparator);
  eq("executionSet limitsProfileId", limitsProfileId(plan.limits), d.limitsProfileId);

  // 7. the index: manifest, readiness
  eq("index manifestHash", await read(pub, a.index, "RealmIndex", "manifestHash"), plan.index.manifestHash);
  eq("index codehash", keccak256(await code(a.index)), plan.index.runtimeCodehash);
  eq("index readsContract", await read(pub, a.index, "RealmIndex", "readsContract"), [a.indexReads, plan.index.reads.runtimeCodehash]);
  eq("index reads codehash", keccak256(await code(a.indexReads)), plan.index.reads.runtimeCodehash);
  const rd = await read(pub, a.index, "RealmIndex", "replayReadiness");
  eq("index ready", rd.ready, true);
  eq("index families", rd.families, plan.index.families);
  eq("index units", rd.units, plan.index.units);
  eq("index progress", (await read(pub, a.index, "RealmIndex", "progress"))[0], BigInt(exp.counts.admissions));

  // 8. Types: ids, catalog, rows, descriptor bytes, declarations
  const catalog = [];
  for (let i = 1n; i <= BigInt(plan.profile.length); i++) catalog.push(await read(pub, a.registryProxy, "TypeRegistry", "catalog", [i]));
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
  for (const s of exp.files.map((f) => f.subjectId)) {
    const createdAt = await read(pub, a.ledgerProxy, "LedgerCore", "subjectCreatedAt", [s]);
    eq(`seed subject ${s.slice(0, 10)} created`, createdAt !== 0n, true);
  }
  // a folder is a files-directory/1 record abi.encode(creator, salt) published by its creator, never a subject
  for (const [what, id] of [["root", exp.root.directoryRecordId], ["docs", exp.folder.directoryRecordId]]) {
    eq(`seed folder ${what} is not a subject`, await read(pub, a.ledgerProxy, "LedgerCore", "subjectCreatedAt", [id]), 0n);
    const [st, hd, body] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, id]);
    eq(`seed folder ${what} creator`, [st, hd.typeId, size(body), hd.word0], [2, dep.typeIds["files-directory/1"], 64, exp.root.principalId]);
  }
  eq("seed nonce", (await read(pub, a.ledgerProxy, "LedgerCore", "nonceOf", [exp.root.principalId]))[0], BigInt(exp.counts.publications));
  const scope = await read(pub, a.bitmapStore, "BitmapStore", "scopeHead", [exp.folder.scopeKey]);
  eq("seed scope root", [scope[0], scope[1]], [1n, 1n]);
  const scope2 = await read(pub, a.bitmapStore, "BitmapStore", "scopeHead", [exp.file.scopeKey]);
  eq("seed scope docs", [scope2[0], scope2[1]], [BigInt(exp.files.length), BigInt(exp.files.length)]);

  // 9a. each file's bytes from its HEAD revision: inline; the span tree re-assembled; the external locator
  for (const f of exp.files) {
    const [st, hh, body] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, f.headRecordId]);
    eq(`files ${f.name}.head`, [st, hh.typeId], [2, dep.typeIds["files-root/1"]]);
    const [subject, form] = decodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], body);
    eq(`files ${f.name}.form`, [subject, form], [f.subjectId, BigInt(f.form)]);
    if (f.form === 0) {
      const bytes = `0x${body.slice(2 + 128)}`;
      eq(`files ${f.name}.bytes`, [size(bytes), sha256(bytes)], [f.length, f.sha256]);
      continue;
    }
    const [, , named] = decodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }, { type: "bytes32" }], body);
    if (f.contentRecordId) {
      eq(`files ${f.name}.descriptor`, named, f.contentRecordId);
      const [cst, ch, cb] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, f.contentRecordId]);
      const w = decodeAbiParameters(Array(10).fill({ type: "uint256" }), cb);
      eq(`files ${f.name}.content`, [cst, ch.typeId, toHex(w[0], { size: 32 }), w[2], w[4], toHex(w[5], { size: 32 })], [2, dep.typeIds["files-content/1"], f.spanRootId, f.spanCount ? 2n : 0n, BigInt(f.length), f.sha256]);
      eq(`files ${f.name}.media`, [size(cb), hexToString(`0x${cb.slice(2 + 640)}`)], [320 + size(toHex(f.media ?? "")), f.media ?? ""]);
      try {
        const t = await readTree(read, pub, plan, f.spanRootId);
        eq(`files ${f.name}.reassembled`, [size(t.bytes), sha256(t.bytes), t.chunks, t.spans], [f.length, f.sha256, f.chunkCount, f.spanCount]);
      } catch (e) { failures.push(`files ${f.name}.reassembled: ${e.message}`); }
    }
    if (f.externalRecordId) {
      eq(`files ${f.name}.descriptor`, named, f.externalRecordId);
      const [xst, xh, xb] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, f.externalRecordId]);
      const w = decodeAbiParameters(Array(7).fill({ type: "uint256" }), xb);
      const locatorEnd = 2 + 448 + 2 * Number(w[6]);
      eq(`files ${f.name}.external media`, [size(xb) - 224 - Number(w[6]), hexToString(`0x${xb.slice(locatorEnd)}`)], [size(toHex(f.media ?? "")), f.media ?? ""]);
      eq(`files ${f.name}.external`, [xst, xh.typeId, toHex(w[0], { size: 32 }), w[1], w[2], w[3], w[4], toHex(w[5], { size: 32 }), hexToString(`0x${xb.slice(2 + 448, locatorEnd)}`)], [2, dep.typeIds["files-external/1"], f.sentinelRecordId, 2n, 2n, 1n, BigInt(f.length), f.sha256, f.locator]);
      const [sst, sh, sb] = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, f.sentinelRecordId]);
      eq(`files ${f.name}.sentinel`, [sst, sh.typeId, sb], [2, dep.typeIds["files-bytes/1"], sha256("0x")]);
    }
  }

  // 9c. KeysView reproduces the seed's ids; the index declares the two Files digest specs
  const kv = a.keysView;
  const readme = exp.files[0];
  eq("keysView subjectId", await read(pub, kv, "KeysView", "subjectId", [exp.root.principalId, keccak256(toHex("readme"))]), readme.subjectId);
  eq("keysView recordId", await read(pub, kv, "KeysView", "recordId", [dep.typeIds["files-root/1"], keccak256(exp.file.body)]), readme.headRecordId);
  const headPos = await read(pub, kv, "KeysView", "positionKey", [keccak256(toHex("efs/purpose/head/1")), readme.subjectId, pad("0x", { size: 32 })]);
  eq("keysView bindingKey", await read(pub, kv, "KeysView", "bindingKey", [exp.root.principalId, headPos]), readme.headKey);
  eq("keysView scopeKey", await read(pub, kv, "KeysView", "scopeKey", [exp.root.principalId, keccak256(toHex("efs/purpose/folder/1")), exp.folder.directoryRecordId]), exp.file.scopeKey);
  for (const spec of plan.index.specs) eq(`index digestSpecCount ${spec.typeId.slice(0, 10)}`, await read(pub, a.index, "RealmIndex", "digestSpecCount", [spec.typeId]), 1n);

  // 9d. the index prices like the release: the work model the deployed index answers (workModel(), every field of the
  // ABI's WorkModel, formulaVersion included) equals the deploy plan's and every gas-model floor's (release.json
  // gasModel, and gas/model.json in a checkout; one index serves every schedule), and the Realm's floor prices
  // (describe().limits) equal the floor.limits of the schedule that prices this chain. A planner sizes publications
  // from those documents, so any difference would let it plan what the kernel refuses.
  {
    const wmChain = await read(pub, a.index, "RealmIndex", "workModel");
    const wmFields = abiOf("RealmIndex").find((i) => i.name === "workModel").outputs[0].components.map((c) => c.name);
    const relModel = JSON.parse(readFileSync(join(REL, "release.json"), "utf8")).gasModel;
    const modelFile = join(plan.local.repoRoot, "gas/model.json");
    const model = existsSync(modelFile) ? JSON.parse(readFileSync(modelFile, "utf8")) : null;
    const wmSources = { "deploy plan workModel": plan.workModel, "efs-deployment.json index.workModel": dep.index?.workModel };
    const floorSources = {};
    for (const [s, sched] of Object.entries(relModel?.schedules ?? {})) wmSources[`release.json gasModel.schedules.${s}.floor.workModel`] = sched.floor?.workModel;
    for (const [s, prof] of Object.entries(model?.profiles ?? {})) wmSources[`gas/model.json profiles.${s}.floor.workModel`] = prof.floor?.workModel;
    const sched = HARDFORKS[hardfork]?.feeSchedule;
    floorSources[`release.json gasModel.schedules.${sched}.floor.limits`] = relModel?.schedules?.[sched]?.floor?.limits;
    if (model) floorSources[`gas/model.json profiles.${sched}.floor.limits`] = model.profiles?.[sched]?.floor?.limits;
    const misses = [
      ...priceMismatches("workModel", wmFields, wmChain, wmSources),
      ...priceMismatches("floor.limits", FLOOR_LIMIT_FIELDS, d.limits, floorSources),
    ];
    checked.pricing = (checked.pricing ?? 0) + wmFields.length * Object.keys(wmSources).length + FLOOR_LIMIT_FIELDS.length * Object.keys(floorSources).length;
    for (const m of misses) failures.push(`pricing ${m}`);
  }
  eq("seed root-is-directory", (await read(pub, a.ledgerProxy, "LedgerCore", "recordHeader", [dep.root.directoryRecordId]))[0], dep.typeIds["files-directory/1"]);

  // 9b. the readers: immutables, the directory listing, and one page of the seeded folder
  const lensR = a.lensReader;
  const pageR = a.filesPageReader;
  eq("readers lens.ledger", await read(pub, lensR, "LensReader", "ledger"), a.ledgerProxy);
  eq("readers lens.VIEWS", await read(pub, lensR, "LensReader", "VIEWS"), a.ledgerViews);
  eq("readers lens.READS", await read(pub, lensR, "LensReader", "READS"), a.ledgerReads);
  eq("readers lens.layoutId", await read(pub, lensR, "LensReader", "layoutId"), plan.layoutId);
  for (const [fn, value] of [["LEDGER", a.ledgerProxy], ["VIEWS", a.ledgerViews], ["READS", a.ledgerReads], ["LAYOUT", plan.layoutId], ["NAME_TYPE", dep.typeIds["files-name/3"]], ["ROOT_TYPE", dep.typeIds["files-root/1"]], ["CHILD_TYPE", dep.typeIds["files-child/1"]]]) {
    eq(`readers page.${fn}`, await read(pub, pageR, "FilesPageReader", fn), value);
  }
  for (const [r, name, extra] of [[a.topicMineReader, "TopicMineReader", []], [a.topicEveryoneReader, "TopicEveryoneReader", []], [a.topicLookupReader, "TopicLookupReader", [["TOPIC_TYPE", dep.typeIds["topic/1"]], ["WORD_TYPE", dep.typeIds["topic-word/1"]]]]]) {
    for (const [fn, value] of [["LEDGER", a.ledgerProxy], ["VIEWS", a.ledgerViews], ["READS", a.ledgerReads], ["LAYOUT", plan.layoutId], ...extra]) {
      eq(`readers ${name}.${fn}`, await read(pub, r, name, fn), value);
    }
  }
  const physical = keccak256(toHex("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head"));
  for (const r of [plan.readers.lens, plan.readers.filesPage, plan.readers.topicMine, plan.readers.topicEveryone, plan.readers.topicLookup]) {
    const [readers, codehashes, layoutIds, profiles] = await read(pub, a.readerDirectory, "ReaderDirectory", "readers", [a.ledgerProxy, r.kind, 0, 16]);
    eq(`readers directory ${r.kindLabel}`, [readers, codehashes, layoutIds, profiles], [[r.address], [r.runtimeCodehash], [plan.layoutId], [physical]]);
    eq(`readers deployment ${r.kindLabel}`, dep.readers.listed.find((x) => x.kind === r.kind)?.reader, r.address);
  }
  const [pageCall] = readCalls(plan);
  const pg = await read(pub, pageR, "FilesPageReader", "listDirectory", pageCall.args);
  eq("readers page.status", pg.q.status, 2); // PRESENT
  eq("readers page.rows", pg.rows.map((r) => [r.name, r.target, r.headRecord, r.rowKind]), exp.files.map((f) => [toHex(f.name), f.subjectId, f.headRecordId, 1]));
  eq("readers page.listingCoverage", pg.listingCoverage, 3); // COMPLETE
  const rec = await read(pub, a.ledgerReads, "LedgerReads", "record", [a.ledgerProxy, exp.file.rootRecordId]);
  eq("readers record", [rec[0], rec[1].typeId, rec[1].word0, rec[2]], [2, dep.typeIds["files-root/1"], exp.file.subjectId, exp.file.body]);

  // 9d. the web3:// gateway (ERC-5219 + ERC-7617): its immutables, then the seed read back through `request`
  const gw = a.web3Gateway;
  eq("gateway deployment", [dep.readers.web3Gateway?.address, dep.readers.web3Gateway?.rootDirectory], [gw, exp.root.directoryRecordId]);
  eq("gateway resolveMode", await read(pub, gw, "EfsWeb3Gateway", "resolveMode"), pad(toHex("5219"), { dir: "right", size: 32 }));
  // the entry point names its content server by address and codehash; both are the plan's and the deployment's
  const gwc = a.web3Content;
  eq("gateway content deployment", [dep.readers.web3Gateway?.content?.address, dep.readers.web3Gateway?.content?.runtimeCodehash], [gwc, plan.gateway.content.runtimeCodehash]);
  eq("gateway content codehash", keccak256(await pub.getCode({ address: gwc })), plan.gateway.content.runtimeCodehash);
  for (const [fn, value] of [["ledger", a.ledgerProxy], ["READS", a.ledgerReads], ["VIEWS", a.ledgerViews], ["PAGER", pageR], ["CONTENT", gwc], ["CONTENT_CODEHASH", plan.gateway.content.runtimeCodehash],
    ["layoutId", plan.layoutId], ["ROOT_DIRECTORY", exp.root.directoryRecordId], ["DIRECTORY_TYPE", dep.typeIds["files-directory/1"]]]) {
    eq(`gateway ${fn}`, await read(pub, gw, "EfsWeb3Gateway", fn), value);
  }
  for (const [fn, value] of [["ledger", a.ledgerProxy], ["READS", a.ledgerReads], ["layoutId", plan.layoutId], ["ROOT_TYPE", dep.typeIds["files-root/1"]], ["CHILD_TYPE", dep.typeIds["files-child/1"]],
    ["CONTENT_TYPE", dep.typeIds["files-content/1"]], ["EXTERNAL_TYPE", dep.typeIds["files-external/1"]], ["BYTES_TYPE", dep.typeIds["files-bytes/1"]], ["SPAN_TYPE", dep.typeIds["files-span/1"]]]) {
    eq(`gateway content ${fn}`, await read(pub, gwc, "EfsWeb3Content", fn), value);
  }
  // what a web3:// client does with a URL path: split, percent-decode, call request(); the body is bytes, not UTF-8
  const web3Get = async (path) => {
    const u = new URL(path, "http://gateway.invalid");
    const resource = u.pathname.split("/").slice(1).map(decodeURIComponent);
    const params = [...u.searchParams].map(([key, value]) => ({ key, value }));
    const { data } = await pub.call({ to: gw, data: encodeFunctionData({ abi: abiOf("EfsWeb3Gateway"), functionName: "request", args: [resource, params] }) });
    const [status, body, headers] = decodeAbiParameters([{ type: "uint16" }, { type: "bytes" }, { type: "tuple[]", components: [{ name: "key", type: "string" }, { name: "value", type: "string" }] }], data);
    return { status, body, headers: Object.fromEntries(headers.map((h) => [h.key.toLowerCase(), h.value])) };
  };
  const [gwReadme, gwBig, gwRemote] = exp.files;
  // the seed's root by its folder id; its default lens is its creator, the fixture principal
  const base = `/~efs/o/${exp.root.directoryRecordId}/docs`;
  const one = await web3Get(`${base}/${gwReadme.name}`);
  // readme.txt is inline (no descriptor, no media type): Content-Type from the extension, no nosniff
  eq("gateway readme", [one.status, sha256(one.body), size(one.body), one.headers["content-type"], one.headers["x-efs-record"], one.headers["x-content-type-options"] ?? null], [200, gwReadme.sha256, gwReadme.length, "text/plain; charset=utf-8", gwReadme.headRecordId, null]);
  eq("gateway readme by lens", (await web3Get(`${base}/${gwReadme.name}?lens=${dep.actors.fixturePrincipal}`)).body, one.body);
  const parts = [];
  for (let url = `${base}/${gwBig.name}`; url; ) {
    const r = await web3Get(url);
    // big.bin declares its media type: served as Content-Type with nosniff on every chunk
    eq(`gateway big chunk ${parts.length}`, [r.status, r.headers["content-length"], r.headers["x-efs-sha256"], r.headers["content-type"], r.headers["x-content-type-options"] ?? null], [200, String(gwBig.length), gwBig.sha256, gwBig.media, "nosniff"]);
    parts.push(r.body);
    url = r.status === 200 && parts.length <= gwBig.chunkCount ? r.headers["web3-next-chunk"] : undefined;
  }
  const whole = concatHex(parts);
  eq("gateway big", [parts.length, size(whole), sha256(whole)], [gwBig.chunkCount, gwBig.length, gwBig.sha256]);
  const moved = await web3Get(`${base}/${gwRemote.name}`);
  eq("gateway remote", [moved.status, moved.headers.location, moved.headers["x-efs-sha256"], moved.headers["x-efs-media-type"] ?? null], [307, gwRemote.locator, gwRemote.sha256, gwRemote.media]);
  const listed = await web3Get(base);
  eq("gateway listing", [listed.status, listed.headers["x-efs-listing"], JSON.parse(hexToString(listed.body))], [200, "complete", { entries: exp.files.map((f) => ({ name: f.name, kind: "file" })), complete: true }]);
  eq("gateway statuses", [(await web3Get(`${base}/missing.txt`)).status, (await web3Get(`${base}/${gwReadme.name}?offset=${gwReadme.length}`)).status], [404, 416]);
  // the first segment decides the kind: a plain word is a topic (not served, so `docs` is never a folder there),
  // `~` the system, `0x<40 hex>` a home (the fixture account's own, which holds nothing), any other `0x` segment a word
  // (the root principal id, 64 hex digits, is a topic path, as on the chain's rule 6); the id of an existing
  // object that is neither a folder nor a file (the sample file's revision record) is 501, never 404, and so is a
  // revision link to a record that is not a revision (the root folder); only an id that names nothing is 404
  const nothing = keccak256(toHex("efs/fixture/no such object"));
  eq("gateway forms", [(await web3Get(`/docs/${gwReadme.name}`)).status, (await web3Get(`/~home/${dep.actors.fixturePrincipal}/docs`)).status, (await web3Get(`/${exp.root.principalId}/docs`)).status, (await web3Get(`/~efs/o/${exp.file.rootRecordId}/`)).status, (await web3Get(`/~efs/v/${exp.root.directoryRecordId}`)).status, (await web3Get(`/~efs/o/${nothing}/`)).status, (await web3Get(`/~efs/v/${nothing}`)).status, (await web3Get("/~efs/v")).status],
    [501, 400, 501, 501, 501, 404, 404, 400]);
  // the sample file by its object link (its creator's HEAD) and by its revision link serve the sample bytes
  const byId = await web3Get(`/~efs/o/${exp.file.subjectId}`);
  eq("gateway file by id", [byId.status, sha256(byId.body), byId.headers["x-efs-record"], byId.headers["content-type"]], [200, gwReadme.sha256, exp.file.rootRecordId, "application/octet-stream"]);
  const byRevision = await web3Get(`/~efs/v/${exp.file.rootRecordId}`);
  eq("gateway revision link", [byRevision.status, sha256(byRevision.body), byRevision.headers["x-efs-record"]], [200, gwReadme.sha256, exp.file.rootRecordId]);
  // big.bin through both forms, chunk by chunk
  for (const [label, first] of [["by id", `/~efs/o/${gwBig.subjectId}`], ["by revision", `/~efs/v/${gwBig.headRecordId}`]]) {
    const got = [];
    for (let url = first; url; ) {
      const r = await web3Get(url);
      eq(`gateway big ${label} chunk ${got.length}`, [r.status, r.headers["x-efs-record"], r.headers["content-type"]], [200, gwBig.headRecordId, gwBig.media]);
      got.push(r.body);
      url = r.status === 200 && got.length <= gwBig.chunkCount ? r.headers["web3-next-chunk"] : undefined;
    }
    const all = concatHex(got);
    eq(`gateway big ${label}`, [got.length, size(all), sha256(all)], [gwBig.chunkCount, gwBig.length, gwBig.sha256]);
  }
  const homeDir = await web3Get(`/${dep.actors.fixturePrincipal}/`);
  eq("gateway home", [homeDir.status, homeDir.headers["x-efs-home"], homeDir.headers["x-efs-listing"]], [200, dep.actors.fixturePrincipal.toLowerCase(), "complete"]);

  // 10. cold pin (design §12.3): what an SDK with only release.json + efs-deployment.json does on first contact
  rpc.reset();
  const describeData = encodeFunctionData({ abi: abiOf("LedgerReads"), functionName: "describe", args: [a.ledgerProxy] });
  const [chainHex, block, describeRaw, implWord] = await rpc.batch([
    ["eth_chainId", []], ["eth_getBlockByNumber", ["latest", false]], ["eth_call", [{ to: a.ledgerReads, data: describeData }, "latest"]], ["eth_getStorageAt", [a.ledgerProxy, IMPLEMENTATION_SLOT, "latest"]],
  ]);
  const pinned = decodeFunctionResult({ abi: abiOf("LedgerReads"), functionName: "describe", data: describeRaw });
  const impl = getAddress(`0x${implWord.slice(26)}`);
  const getCodes = [impl, a.ledgerReads, a.ledgerViews, a.lensReader, a.filesPageReader];
  const codes = await rpc.batch(getCodes.map((x) => ["eth_getCode", [x, block.number]]));
  eq("coldpin chainId", Number(chainHex), pinned.acceptedChainId);
  eq("coldpin impl", impl, pinned.ledgerImpl);
  eq("coldpin impl-codehash", keccak256(codes[0]), pinned.ledgerImplCodehash);
  eq("coldpin impl-release", keccak256(codes[0]), plan.units.LedgerCore.runtimeCodehash);
  eq("coldpin reads-codehash", keccak256(codes[1]), pinned.thisFacetCodehash);
  eq("coldpin views-codehash", keccak256(codes[2]), plan.units.LedgerViews.runtimeCodehash);
  eq("coldpin lens-codehash", keccak256(codes[3]), plan.readers.lens.runtimeCodehash);
  eq("coldpin page-codehash", keccak256(codes[4]), plan.readers.filesPage.runtimeCodehash);
  const coldCalls = Object.values(rpc.counts).reduce((x, y) => x + y, 0);
  const coldEnvelopes = rpc.envelopes;
  const coldCounts = { ...rpc.counts };
  if (coldCalls > 9 || coldEnvelopes > 2) failures.push(`coldpin bound: ${coldCalls} calls / ${coldEnvelopes} envelopes`);

  const total = Object.values(checked).reduce((x, y) => x + y, 0);
  log(`efs-fixture verify ${lease.name}: ${total} checks (${Object.entries(checked).map(([k, v]) => `${k} ${v}`).join(", ")})`);
  log(`efs-fixture verify: documents ${pretty(docDir)}; test/harness/doubles/Factory.sol RUNTIME ${harnessNote}`);
  log(`efs-fixture verify: describe() fields not compared: ${uncheckedDescribe.length ? uncheckedDescribe.join(", ") : "none"}`);
  log(`efs-fixture verify: cold pin = ${coldCalls} logical calls in ${coldEnvelopes} HTTP envelopes (${Object.entries(coldCounts).map(([k, v]) => `${k}×${v}`).join(", ")}); design bound ≤ 9 calls, ≤ 2 envelopes`);
  if (failures.length) {
    log(`efs-fixture verify: ${failures.length} mismatch(es):`);
    for (const f of failures) log(`  ${f}`);
  } else log("efs-fixture verify: OK — every address, runtime, describe() field, executionSet(), manifestHash(), Type id and seed row matches");
  return {
    ok: failures.length === 0, command: "verify", name: lease.name, rpcUrl: lease.url, chainId: lease.chainId, documents: docDir,
    checks: total, byGroup: checked, failures, uncheckedDescribe, harnessFactory: harnessNote,
    coldPin: { calls: coldCalls, envelopes: coldEnvelopes, counts: coldCounts, bound: { calls: 9, envelopes: 2 } },
  };
}

/** The current revision's ComponentSet, read through LedgerReads.revisionAt (what the activation pinned). */
async function revisionComponents(pub, plan, ledger, reads) {
  const { read } = bind(plan);
  const rev = await read(pub, ledger, "LedgerCore", "revision");
  const [, r] = await read(pub, reads, "LedgerReads", "revisionAt", [ledger, rev]);
  return r.components;
}

// ---- status / list / gc ----------------------------------------------------------------------------------------------

export async function status(o = {}) {
  const home = o.home ?? registryHome();
  const lease = requireLease(resolveName(o.name, home), home, { live: false });
  let rpc = null;
  if (lease.liveness === "live" && lease.url) {
    try {
      const c = rpcClient(lease.url, { timeoutMs: 2000 });
      const [chainId, block] = await c.batch([["eth_chainId", []], ["eth_blockNumber", []]]);
      rpc = { chainId: Number(chainId), blockNumber: Number(block) };
    } catch (e) { rpc = { error: e.message }; }
  }
  const result = { ok: lease.liveness === "live", command: "status", lease, rpc };
  if (!result.ok) throw new FixtureError("INSTANCE_DEAD", `instance ${lease.name} is ${lease.liveness}`, EXIT.NOT_FOUND, result);
  return result;
}

export function list(o = {}) {
  const home = o.home ?? registryHome();
  return { ok: true, command: "list", registryHome: home, leases: registryList({ kind: o.kind, home }) };
}

export function gc(o = {}) {
  const home = o.home ?? registryHome();
  return { ok: true, command: "gc", registryHome: home, removed: registryGc({ purge: !!o.purge, home }) };
}

// ---- down / reset ----------------------------------------------------------------------------------------------------

async function stopPid(pid) {
  try { process.kill(pid, "SIGTERM"); } catch { return; }
  for (let i = 0; i < 50; i++) {
    await sleep(100);
    try { process.kill(pid, 0); } catch { return; }
  }
  try { process.kill(pid, "SIGKILL"); } catch { /* gone */ }
}

/**
 * Stop chain instance `name`: SIGTERM (then SIGKILL after 5 s) to the pid its lease records, only after `ps` shows
 * that pid still has the recorded start time and the recorded anvil command line for the lease's port; then remove
 * the lease and its port claim. A dead or reused pid is never signalled. Options: name, purge, home, log.
 */
export async function down(o = {}) {
  const log = o.log ?? quiet;
  const home = o.home ?? registryHome();
  const lease = requireLease(resolveName(o.name, home), home, { live: false });
  let stopped = null;
  if (lease.liveness === "live") {
    if (!anvilLike(lease)) fail("NOT_ANVIL_YET", `instance ${lease.name} is ${lease.state}: its lease holder (pid ${lease.pid}) is not yet the anvil it starts; retry when up returns`, EXIT.CONFLICT, { lease });
    if (!procMatches(lease)) fail("IDENTITY", `pid ${lease.pid} no longer matches the lease's start time and command; refusing to signal it`, EXIT.CONFLICT, { lease });
    await stopPid(lease.pid);
    stopped = lease.pid;
    log(`efs-fixture: stopped anvil pid ${lease.pid} (${lease.name}, port ${lease.port})`);
  } else if (lease.liveness === "foreign-host") {
    fail("FOREIGN_HOST", `instance ${lease.name} runs on ${lease.hostname}; stop it there`, EXIT.CONFLICT, { lease });
  } else log(`efs-fixture: ${lease.name}'s anvil (pid ${lease.pid}) is already gone; removing its lease`);
  release(lease.name, home);
  let purged = false;
  if (o.purge && lease.stateDir) {
    if (resolve(lease.stateDir) === resolve(instanceDir(lease.name, home))) rmSync(lease.stateDir, { recursive: true, force: true });
    else for (const f of STATE_FILES) rmSync(join(lease.stateDir, f), { force: true });
    purged = true;
  }
  return { ok: true, command: "down", name: lease.name, port: lease.port, stopped, wasLive: lease.liveness === "live", purged, stateDir: lease.stateDir };
}

/** A fresh deployment under the same name and port: down, then up with generation + 1 (a new salt with fresh). */
export async function reset(o = {}) {
  const home = o.home ?? registryHome();
  const prev = requireLease(resolveName(o.name, home), home, { live: false });
  await down({ name: prev.name, home, log: o.log });
  return up({
    name: prev.name, home, log: o.log, port: prev.port, host: prev.host, chainId: o.chainId ?? prev.chainId,
    realmSalt: o.fresh ? undefined : o.realmSalt ?? prev.realmSalt, fresh: !!o.fresh, ttl: o.keep ? 0 : o.ttl ?? prev.ttl ?? DEFAULT_TTL,
    unlocked: o.unlocked ?? prev.unlocked, hardfork: o.hardfork ?? prev.hardfork, stateDir: prev.stateDir, artifacts: prev.artifacts, plan: o.fresh || o.chainId !== undefined ? undefined : prev.plan ?? undefined,
    generation: (prev.generation ?? 1) + 1,
  });
}

// ---- CLI -----------------------------------------------------------------------------------------------------------

const COMMANDS = {
  up: { values: ["name", "port", "port-range", "host", "chain-id", "realm-salt", "ttl", "state-dir", "artifacts", "plan", "home", "hardfork"], flags: ["fresh", "keep", "no-unlocked", "no-unlocked-accounts", "no-verify", "keep-on-fail", "write-release", "json"] },
  verify: { values: ["name", "documents", "home"], flags: ["release", "json"] },
  status: { values: ["name", "home", "kind"], flags: ["json"] },
  list: { values: ["home", "kind"], flags: ["json"] },
  down: { values: ["name", "home"], flags: ["purge", "json"] },
  reset: { values: ["name", "chain-id", "realm-salt", "ttl", "home"], flags: ["fresh", "keep", "json"] },
  gc: { values: ["home"], flags: ["purge", "json"] },
};
const USAGE = `usage: node tools/efs-fixture.mjs <command> [options]   (tools/RELEASE.md)
  up      [--name N] [--port P | --port-range LO-HI] [--chain-id 31337] [--realm-salt 0x… | --fresh]
          [--ttl 900 | --ttl 0 | --keep] [--no-unlocked] [--hardfork osaka|prague] [--state-dir DIR] [--artifacts DIR] [--plan FILE]
          [--no-verify] [--keep-on-fail] [--write-release] [--json]
  verify  [--name N] [--documents DIR | --release] [--json]
  status  [--name N] [--json]          list [--kind chain|gateway|ui] [--json]
  down    [--name N] [--purge] [--json]
  reset   [--name N] [--fresh] [--chain-id N] [--json]
  gc      [--purge] [--json]
  every command: --home DIR (default $EFS_FIXTURE_HOME, else \${XDG_STATE_HOME:-~/.local/state}/efs/fixtures)
  exit: 0 ok, 1 verify mismatch, 2 usage, 3 port/lease conflict, 4 not found/dead, 5 other failure`;

function parseCli(argv) {
  const [cmd, ...rest] = argv;
  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") throw new FixtureError("USAGE", USAGE, EXIT.USAGE);
  const spec = COMMANDS[cmd];
  if (!spec) throw new FixtureError("USAGE", `unknown command ${JSON.stringify(cmd)}\n${USAGE}`, EXIT.USAGE);
  const o = {};
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--") continue; // pnpm run passes it through
    if (!a.startsWith("--")) throw new FixtureError("USAGE", `unexpected argument ${JSON.stringify(a)}\n${USAGE}`, EXIT.USAGE);
    const k = a.slice(2);
    if (spec.flags.includes(k)) { o[k] = true; continue; }
    if (!spec.values.includes(k)) throw new FixtureError("USAGE", `${cmd}: unknown option ${a} (allowed: ${[...spec.values, ...spec.flags].map((x) => `--${x}`).join(" ")})`, EXIT.USAGE);
    if (rest[i + 1] === undefined || rest[i + 1].startsWith("--")) throw new FixtureError("USAGE", `${a} needs a value`, EXIT.USAGE);
    o[k] = rest[++i];
  }
  return { cmd, o };
}

async function main() {
  const json = process.argv.includes("--json");
  const log = json ? (...a) => console.error(...a) : (...a) => console.log(...a);
  const print = (obj) => process.stdout.write(`${JSON.stringify(obj, (_, v) => (typeof v === "bigint" ? v.toString() : v), json ? undefined : 2)}\n`);
  let cmd = process.argv[2];
  try {
    const parsed = parseCli(process.argv.slice(2));
    cmd = parsed.cmd;
    const o = parsed.o;
    const home = o.home ? resolve(o.home) : undefined;
    let result;
    if (cmd === "up") {
      result = await up({
        name: o.name, port: o.port, portRange: o["port-range"], host: o.host, chainId: o["chain-id"], realmSalt: o["realm-salt"], fresh: o.fresh,
        ttl: o.ttl, keep: o.keep, unlocked: !(o["no-unlocked"] || o["no-unlocked-accounts"]), hardfork: o.hardfork, stateDir: o["state-dir"], artifacts: o.artifacts, plan: o.plan, verify: !o["no-verify"], keepOnFail: o["keep-on-fail"], writeRelease: o["write-release"], home, log,
      });
      if (!json) log(`efs-fixture: name=${result.name} rpc=${result.rpcUrl} chainId=${result.chainId} pid=${result.pid} state=${result.stateDir}`);
    } else if (cmd === "verify") {
      result = await verify({ name: o.name, documents: o.release ? "release" : o.documents, home, log });
    } else if (cmd === "status" && (o.name || process.env.EFS_FIXTURE_NAME)) {
      result = await status({ name: o.name, home });
      if (!json) log(`${result.lease.name}: ${result.lease.liveness}, ${result.lease.state}, ${result.lease.url}, chain ${result.lease.chainId}, block ${result.rpc?.blockNumber ?? "?"}, pid ${result.lease.pid}, expires ${result.lease.expiresAt ?? "never"}`);
    } else if (cmd === "status" || cmd === "list") {
      result = list({ home, kind: o.kind });
      if (!json) {
        if (!result.leases.length) log(`efs-fixture: no leases in ${result.registryHome}`);
        for (const l of result.leases) log(`${l.name.padEnd(28)} ${String(l.kind).padEnd(7)} ${l.liveness.padEnd(5)} ${String(l.state).padEnd(9)} ${String(l.url ?? "-").padEnd(24)} chain ${String(l.chainId ?? "-").padEnd(8)} pid ${String(l.pid).padEnd(7)} ${l.expired ? "EXPIRED " : ""}${l.checkout ?? ""}`);
      }
    } else if (cmd === "down") {
      result = await down({ name: o.name, purge: o.purge, home, log });
    } else if (cmd === "reset") {
      result = await reset({ name: o.name, fresh: o.fresh, chainId: o["chain-id"], realmSalt: o["realm-salt"], ttl: o.ttl, keep: o.keep, home, log });
      result.command = "reset";
    } else if (cmd === "gc") {
      result = gc({ purge: o.purge, home });
      if (!json) log(`efs-fixture gc: removed ${result.removed.leases.length} lease(s) [${result.removed.leases.join(", ")}], ${result.removed.ports.length} port claim(s), ${result.removed.stateDirs.length} state dir(s)`);
    }
    if (json) print(result);
    process.exitCode = result.ok === false ? EXIT.MISMATCH : EXIT.OK;
  } catch (e) {
    const fe = e instanceof FixtureError ? e : new FixtureError("FAILURE", e.stack ?? e.message, EXIT.FAILURE);
    if (json) print({ ok: false, command: cmd ?? null, error: { code: fe.code, message: fe.message, exitCode: fe.exitCode, details: fe.details } });
    else console.error(fe.exitCode === EXIT.USAGE && fe.code === "USAGE" ? fe.message : `efs-fixture: ${fe.code}: ${fe.message}`);
    process.exitCode = fe.exitCode;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();

export { rpcClient, clients };
