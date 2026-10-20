// SPDX-License-Identifier: MIT
// The genesis deploy plan of design §8.2, computed offline from the Foundry artifacts in out/ (the identity build)
// and nothing else: every CREATE2 address from its initcode hash, the three RealmGenesis creations from its nonces,
// every runtime code hash (immutables filled from their recorded offsets), the nine Files descriptors and Type ids
// (an independent JS twin of src/profiles/FilesTypes.sol), the index manifest hash and the genesis execution set.
// Imported by tools/efs-fixture.mjs and tools/release.mjs; as a CLI it writes deploy/plan.json:
//
//   node tools/deploy-plan.mjs [--chain-id 31337] [--realm-salt 0x…] [--out deploy/plan.json]
//
// Immutable names come from the AST of an auxiliary build (`FOUNDRY_OUT=out/release-ast forge build --ast`), whose
// bytecode must equal the identity build's; without that build they come from release/release.json.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  concat,
  encodeAbiParameters,
  encodeDeployData,
  encodeFunctionData,
  encodePacked,
  getAddress,
  getContractAddress,
  keccak256,
  pad,
  size,
  stringToHex,
  toHex,
  zeroAddress,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const OUT = "out";
export const AST_OUT = "out/release-ast";
const ZERO = pad("0x", { size: 32 });
const h = (s) => keccak256(stringToHex(s));
const enc = (types, values) => encodeAbiParameters(types.map((type) => ({ type })), values);

// ---- fixed facts of this release line ------------------------------------------------------------------------------

/** EIP-7997 / Arachnid deterministic-deployment proxy (design §8.2), its presigned pre-EIP-155 deployment. */
export const FACTORY = {
  address: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
  deployer: "0x3fab184622dc19b6109349b94811493bf2a45362",
  presignedTx:
    "0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222",
  fundWei: 10n ** 17n,
};
/** anvil's first default key: a public throwaway, the fixture's owner, declaration key and seed principal. */
export const FIXTURE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
export const DEFAULTS = { chainId: 31337, realmSalt: h("efs2/fixture/realm/1"), executionProfileId: 1 };
/** No canonical HOT_ABI_ID derivation is committed (design §5.3 names a formula; src/ and vectors/ carry none):
 *  the release uses the suites' id, test/harness/KernelDeploy.sol HOT_ABI_ID. DESIGN-DIVERGENCE in tools/RELEASE.md. */
export const HOT_ABI_ID = h("efs2/ledger-hot/1:test");
/** test/harness/KernelDeploy.sol s1Limits() — the design's §4.2 values. */
export const LIMITS = {
  maxActions: 64, maxBody: 8192, maxRefs: 8, maxReadSetPrincipals: 64, maxReadSetPositions: 4, maxWitness: 4096,
  maxTransitionBlocks: 7200, inlineWordMax: 256, witnessRetention: 1, maxBindsPerPublication: 64,
  maxBodyBytesPerPublication: 16384, maxFreshSlotsPerPublication: 600, maxReadIds: 64, maxReadCount: 256,
  floorFreshGas: 22100, floorRewriteGas: 5000, kernelTail: 20000,
};
/** test/harness/doubles/IndexDoubles.sol IndexDoubleDefaults.workModel() — no release work model exists in src/. */
export const WORK_MODEL = {
  formulaVersion: 1, freshPerPublication: 2, rwPerPublication: 10, freshPerPublishFresh: 10, rwPerPublish: 50,
  freshPerBindFresh: 30, rwPerBind: 40, freshPerRef: 10, freshPerDigestSpec: 10, computeBase: 60000,
  computePerAction: 25000, computePerHookEffect: 60000, finalComputeBase: 60000, finalComputePerBind: 120000,
};
export const DOM = {
  type: h("efs2/type/1"), describedShape: h("efs2/described-shape/1"), executionSet: h("efs2/execution-set/1"),
  realmOrigin: h("efs2/realm-origin/1"), realm: h("efs2/realm/1"), record: h("efs2/record/1"),
  subject: h("efs2/subject/1"), position: h("efs2/position/1"), binding: h("efs2/binding/1"),
  scope: h("efs2/vk/binding-scope/1"),
};
export const PURPOSE = { HEAD: h("efs2/purpose/head/1"), FOLDER: h("efs2/purpose/folder/1"), TAG: h("efs2/purpose/tag/1") };
export const ACTION = { PUBLISH: 1, REUSE: 2, BIND: 3, UNBIND: 4, CREATE: 5, WITHDRAW: 6, RELEASE: 7 };
export const familyId = (name) => h(`efs2/family/${name}/1`);
export const POSTING_FAMILIES = ["by-type", "by-author", "backlink", "history", "reference-position", "by-record", "unique-by-type", "scalar", "digest", "role-scope"];
export const BITMAP_FAMILIES = ["scope", "roster", "live-scope"];
export const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
export const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

export const keys = {
  principal: (address) => pad(address.toLowerCase(), { size: 32 }),
  typeId: (shape, refs, ruleId) => keccak256(enc(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.type, shape, keccak256(enc(["bytes32[]"], [refs])), ruleId])),
  shape: (d) => keccak256(enc(["bytes32", "bytes"], [DOM.describedShape, d])),
  record: (typeId, body) => keccak256(enc(["bytes32", "bytes32", "bytes32"], [DOM.record, typeId, keccak256(body)])),
  subject: (p, salt) => keccak256(enc(["bytes32", "bytes32", "bytes32"], [DOM.subject, p, salt])),
  position: (purpose, subject, role) => keccak256(enc(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.position, purpose, subject, role])),
  binding: (p, position) => keccak256(enc(["bytes32", "bytes32", "bytes32"], [DOM.binding, p, position])),
  scope: (p, purpose, subject) => keccak256(enc(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.scope, p, purpose, subject])),
  realmOrigin: (chainId, core, salt) => keccak256(enc(["bytes32", "uint64", "address", "bytes32"], [DOM.realmOrigin, BigInt(chainId), core, salt])),
  realmId: (origin, profile) => keccak256(enc(["bytes32", "bytes32", "uint16"], [DOM.realm, origin, profile])),
};

// ---- artifacts -----------------------------------------------------------------------------------------------------

const cache = new Map();
/** out/<File>.sol/<Name>.json, refused when stale against the source on disk (the abi-snapshot rule). */
export function artifact(name, { file = name, dir = OUT } = {}) {
  const key = `${dir}/${file}/${name}`;
  if (cache.has(key)) return cache.get(key);
  const path = join(root, dir, `${file}.sol`, `${name}.json`);
  assert.ok(existsSync(path), `${dir}/${file}.sol/${name}.json is missing: run \`forge build\` first`);
  const a = JSON.parse(readFileSync(path, "utf8"));
  const [source, target] = Object.entries(a.metadata.settings.compilationTarget)[0];
  assert.equal(target, name, `${path}: compilation target ${target}`);
  const text = readFileSync(join(root, source));
  assert.equal(a.metadata.sources[source].keccak256, keccak256(text), `${path} was built from a different ${source}: run \`forge build\``);
  const out = { name, source, abi: a.abi, bytecode: a.bytecode.object, runtime: a.deployedBytecode.object, refs: a.deployedBytecode.immutableReferences ?? {}, settings: a.metadata.settings, compiler: a.metadata.compiler, ast: a.ast };
  cache.set(key, out);
  return out;
}

/** The release units (design §3.1) with their artifact file names. */
export const UNITS = {
  LedgerIngress: "LedgerIngress", LedgerApply: "LedgerApply", LedgerControl: "LedgerControl", LedgerCore: "LedgerCore",
  LedgerReads: "LedgerReads", LedgerViews: "LedgerViews", DescriptorStore: "DescriptorStore", IndexReplayDecoder: "IndexReplayDecoder",
  ReaderDirectory: "ReaderDirectory", TypeRegistry: "TypeRegistry", RealmGenesis: "RealmGenesis", RealmController: "RealmController",
  PostingStore: "PostingStore", BitmapStore: "BitmapStore", RealmIndex: "RealmIndex", FilesFinalValidator: "FilesFinalValidator",
  FilesRootRule: "FilesRootRule", FilesChildRule: "FilesChildRule", FilesDirectoryRule: "FilesDirectoryRule", FilesNameRule: "FilesNameRule",
  FilesBytesRule: "FilesBytesRule", FilesContentRule: "FilesContentRule", FilesExternalContentRule: "FilesExternalContentRule",
  DirectoryAliasRule: "DirectoryAliasRule", RealmNoticeRule: "RealmNoticeRule", RefuseAllPolicy: "RefuseAllPolicy",
  TransparentUpgradeableProxy: "TransparentUpgradeableProxy", ProxyAdmin: "ProxyAdmin",
};

// ---- immutables: names → offsets ------------------------------------------------------------------------------------

let astIndex;
function astNames() {
  if (astIndex) return astIndex;
  astIndex = new Map();
  const walk = (n) => {
    if (Array.isArray(n)) return n.forEach(walk);
    if (!n || typeof n !== "object") return;
    if (n.nodeType === "VariableDeclaration" && n.mutability === "immutable") astIndex.set(String(n.id), n.name);
    for (const v of Object.values(n)) walk(v);
  };
  const scan = (dir) => {
    for (const e of readdirSync(join(root, dir), { withFileTypes: true })) {
      if (e.isDirectory()) { if (e.name !== "build-info") scan(`${dir}/${e.name}`); }
      else if (e.name.endsWith(".json")) walk(JSON.parse(readFileSync(join(root, dir, e.name), "utf8")).ast);
    }
  };
  scan(AST_OUT);
  return astIndex;
}

/** `[{name, offsets}]` for a unit, from the AST build (bytecode-checked against out/) or from release/release.json. */
export function immutableLayout(name) {
  const a = artifact(name, { file: UNITS[name] });
  if (Object.keys(a.refs).length === 0) return [];
  if (existsSync(join(root, AST_OUT, `${UNITS[name]}.sol`, `${name}.json`))) {
    const b = artifact(name, { file: UNITS[name], dir: AST_OUT });
    assert.equal(b.runtime, a.runtime, `${name}: the AST build's runtime differs from the identity build's (not reproducible)`);
    assert.equal(b.bytecode, a.bytecode, `${name}: the AST build's creation code differs from the identity build's`);
    const names = astNames();
    const layout = Object.entries(b.refs).map(([id, refs]) => {
      assert.ok(names.has(id), `${name}: immutable AST id ${id} not found in ${AST_OUT}`);
      return { name: names.get(id), offsets: refs.map((r) => (assert.equal(r.length, 32), r.start)).sort((x, y) => x - y) };
    }).sort((x, y) => (x.name < y.name ? -1 : 1));
    const fromIdentity = Object.values(a.refs).map((refs) => refs.map((r) => r.start).sort((x, y) => x - y).join(",")).sort();
    assert.deepEqual(layout.map((l) => l.offsets.join(",")).sort(), fromIdentity, `${name}: immutable offsets differ between the builds`);
    return layout;
  }
  const rel = join(root, "release/release.json");
  assert.ok(existsSync(rel), `${name} has immutables: build ${AST_OUT} (see tools/RELEASE.md) or provide release/release.json`);
  const unit = JSON.parse(readFileSync(rel, "utf8")).contracts[name];
  assert.ok(unit?.immutables, `release/release.json has no immutable layout for ${name}`);
  return unit.immutables;
}

/** The runtime the constructor will leave: the artifact's deployed bytecode with every immutable filled. */
export function runtimeOf(name, values = {}) {
  const a = artifact(name, { file: UNITS[name] });
  const layout = immutableLayout(name);
  const bytes = Buffer.from(a.runtime.slice(2), "hex");
  const seen = new Set();
  for (const { name: imm, offsets } of layout) {
    assert.ok(imm in values, `${name}: no value for immutable ${imm}`);
    const v = values[imm];
    const word = Buffer.from(pad(typeof v === "string" ? v.toLowerCase() : toHex(v), { size: 32 }).slice(2), "hex");
    for (const o of offsets) word.copy(bytes, o);
    seen.add(imm);
  }
  for (const k of Object.keys(values)) assert.ok(seen.has(k), `${name}: immutable ${k} has no runtime reference`);
  return `0x${bytes.toString("hex")}`;
}

// ---- the Files profile: a JS twin of src/profiles/FilesTypes.sol ----------------------------------------------------

export const T = { ROOT: 0, CHILD: 1, DIRECTORY: 2, NAME: 3, BYTES: 4, CONTENT: 5, EXTERNAL: 6, ALIAS: 7, NOTICE: 8 };
export const TYPE_NAMES = ["files-root/1", "files-child/1", "files-directory/1", "files-name/2", "files-bytes/1", "files-content/1", "files-external/1", "directory-alias/1", "realm-notice/1"];
export const RULES = ["FilesRootRule", "FilesChildRule", "FilesDirectoryRule", "FilesNameRule", "FilesBytesRule", "FilesContentRule", "FilesExternalContentRule", "DirectoryAliasRule", "RealmNoticeRule"];
const NAMESPACE = h("efs2/files/1");
const FIELD_PARENT = h("efs2/files/field/parent/1");
const FIELD_BYTES = h("efs2/files/field/bytes/1");
const SEMANTIC_REVISION = h("efs2/files/semantic/parent-revision/1");
const SEMANTIC_CARRIER = h("efs2/files/semantic/bytes-carrier/1");
const refField = (id, semantic, ref) => encodePacked(["bytes32", "bytes32", "uint8", "uint8", "uint16", "uint256", "uint256", "bytes32"], [id, semantic, 1, 0, 32, 0n, 0n, ref]);
const SPECS = [
  { description: "abi.encode(fileSubject) || document; the first revision of a created file subject", dependencyClass: 2, refHeaderWords: 1 },
  { description: "abi.encode(parentRecord, fileSubject) || document; parent is files-root/1 or files-child/1 of the same file", dependencyClass: 1, refHeaderWords: 2, field: () => refField(FIELD_PARENT, SEMANTIC_REVISION, ZERO), refs: () => [ZERO] },
  { description: "abi.encode(seedSubject); a directory is this record, seeded by a created subject", dependencyClass: 2, refHeaderWords: 1 },
  { description: "raw UTF-8 name, 1-255 bytes, well-formed, byte-exact, case-sensitive, not . or .., ~efs reserved", dependencyClass: 1, refHeaderWords: 1 },
  { description: "sha256(payload) || payload; payload at most 8160 bytes", dependencyClass: 1, refHeaderWords: 1 },
  { description: "11 words [bytesRef, version, carrier, hashAlg, length, sha256, media, cipher, nonce12, plaintextLength, plaintextSHA256OrZero]", dependencyClass: 1, refHeaderWords: 3, field: (ids) => refField(FIELD_BYTES, SEMANTIC_CARRIER, ids[T.BYTES]), refs: (ids) => [ids[T.BYTES]] },
  { description: "7 words [bytesRef, version 2, carrier 2 ar | 3 ipfs, hashAlg 1, length, sha256, locatorLength] || ASCII locator", dependencyClass: 1, refHeaderWords: 1, field: (ids) => refField(FIELD_BYTES, SEMANTIC_CARRIER, ids[T.BYTES]), refs: (ids) => [ids[T.BYTES]] },
  { description: "abi.encode(targetObjectId, kind); kind 1 a files-directory/1 record, 2 a created file subject", dependencyClass: 2, refHeaderWords: 1 },
  { description: "abi.encode(bytes32 kind, uint256 revision, bytes note); kind frozen | successor | migration", dependencyClass: 2, refHeaderWords: 1 },
];

/** FilesTypes.encode: the codec-1 bytes of a NATIVE descriptor (design §9.2 offsets). */
export function descriptor(t, key, ruleCodehash, initcodeHash, ids) {
  const s = SPECS[t];
  const name = stringToHex(TYPE_NAMES[t]);
  const description = stringToHex(s.description);
  const fields = s.field ? s.field(ids) : "0x";
  const header = encodePacked(
    ["uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint24", "uint8", "uint8", "uint8", "address", "bytes32", "bytes32", "bytes32", "uint16", "uint8", "uint8"],
    [1, 0, 3, s.field ? 1 : 0, 1, s.dependencyClass, 1, 1, 0, 0, 0, size(name), key, NAMESPACE, ruleCodehash, initcodeHash, size(description), s.refHeaderWords, 0],
  );
  assert.equal(size(header), 134);
  return concat([header, name, description, fields]);
}
export const refTypesOf = (t, ids) => (SPECS[t].refs ? SPECS[t].refs(ids) : []);

/** The EIP-712 declaration digest (TypeRegistry.declarationDigest; chain-free). */
export function declarationDigest(typeId) {
  const domain = keccak256(enc(["bytes32", "bytes32", "bytes32"], [h("EIP712Domain(string name,string version)"), h("EFS Type Declaration"), h("1")]));
  return keccak256(concat(["0x1901", domain, keccak256(enc(["bytes32", "bytes32"], [h("TypeDeclaration(bytes32 typeId)"), typeId]))]));
}
export async function declare(typeId, privateKey) {
  const s = await sign({ hash: declarationDigest(typeId), privateKey });
  return concat([s.r, s.s, toHex(Number(s.v), { size: 1 })]);
}

// ---- ABI-typed hashing ---------------------------------------------------------------------------------------------

const fnInputs = (abi, name) => abi.find((i) => i.type === "function" && i.name === name).inputs;
const ctorInputs = (abi) => abi.find((i) => i.type === "constructor").inputs;
const component = (params, name) => params.find((p) => p.name === name);

export function limitsProfileId(limits) {
  const limitsParam = component(fnInputs(artifact("RealmGenesis").abi, "run"), "limits");
  return keccak256(encodeAbiParameters([limitsParam], [limits]));
}
export function domainSeparator(chainId, ledger) {
  return keccak256(enc(["bytes32", "bytes32", "bytes32", "uint256", "address"], [h("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), h("EFS"), h("2"), BigInt(chainId), ledger]));
}
/** Design §8.1, exactly as LedgerControl._activate (and test/harness/ExecutionSets.sol) computes it. */
export function executionSet(set, ledger) {
  const setParam = fnInputs(artifact("RealmController").abi, "activate")[0];
  const componentsParam = component(setParam.components, "components");
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, componentsParam, { type: "uint256" }, { type: "uint16" }, { type: "uint16" }, { type: "uint64" }, { type: "bytes32" }],
    [DOM.executionSet, set.layoutId, domainSeparator(set.acceptedChainId, ledger), set.components, BigInt(set.revision), set.executionProfileId, set.capabilities, BigInt(set.acceptedChainId), limitsProfileId(set.limits)],
  ));
}
/** RealmIndex's MANIFEST_HASH: keccak(abi.encode(MANIFEST_HEADER, families, units, specs, work, PHYSICAL, CALLBACK)). */
export function manifestHash(families, units, specs, work) {
  const ri = artifact("RealmIndex").abi;
  const readiness = ri.find((i) => i.name === "replayReadiness").outputs[0];
  const ctor = ctorInputs(ri);
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, component(readiness.components, "families"), component(ctor, "units"), component(ctor, "specs"), component(ctor, "work"), { type: "bytes32" }, { type: "bytes32" }],
    [h("efs2/index-manifest/1"), families, units, specs, work, MANIFEST_PROFILES.physical, MANIFEST_PROFILES.callback],
  ));
}
export const MANIFEST_PROFILES = {
  physical: h("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head"),
  callback: h("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs"),
};
/** RealmIndex's constructor `_declare` table: (name, kind, universe, shape, liveSemantics, store, fromAdmission). */
const FAMILY_TABLE = [
  ["by-type", 1, 1, 1, 2, "posting", 1n], ["by-author", 4, 2, 1, 2, "posting", 1n], ["backlink", 5, 4, 1, 3, "posting", 1n],
  ["history", 8, 3, 1, 1, "posting", 1n], ["scope", 10, 3, 1, 1, "bitmap", 1n], ["reference-position", 11, 1, 1, 1, "posting", 1n],
  ["by-record", 12, 5, 1, 2, "posting", 1n], ["unique-by-type", 13, 1, 1, 1, "posting", 1n], ["scalar", 14, 1, 1, 1, "posting", 1n],
  ["digest", 15, 5, 1, 1, "posting", 1n], ["role-scope", 16, 3, 1, 1, "posting", 1n], ["roster", 17, 3, 2, 2, "bitmap", 2n ** 64n - 1n],
  ["live-scope", 18, 3, 2, 2, "bitmap", 1n],
];

// ---- the plan ------------------------------------------------------------------------------------------------------

const SALT0 = ZERO;
const create2 = (initcode) => getContractAddress({ opcode: "CREATE2", from: FACTORY.address, salt: SALT0, bytecode: initcode });
const createAt = (from, nonce) => getContractAddress({ opcode: "CREATE", from, nonce: BigInt(nonce) });
const deployData = (name, args = []) => {
  const a = artifact(name, { file: UNITS[name] });
  return args.length ? encodeDeployData({ abi: a.abi, bytecode: a.bytecode, args }) : a.bytecode;
};

/**
 * Builds the whole plan offline. Every step names its kind, the address it produces, the initcode hash it is
 * created from, its arguments and the post-check `verify` runs. Nothing here reads a chain.
 */
export async function buildPlan({ chainId = DEFAULTS.chainId, realmSalt = DEFAULTS.realmSalt, key = FIXTURE_KEY } = {}) {
  const fixture = privateKeyToAccount(key);
  const owner = fixture.address;
  const steps = [];
  const units = {};
  const add = (id, name, args, immutables, extra = {}) => {
    const initcode = deployData(name, args);
    const address = create2(initcode);
    const runtime = runtimeOf(name, typeof immutables === "function" ? immutables(address) : immutables);
    const entry = { id, kind: "CREATE2", contract: name, source: artifact(name, { file: UNITS[name] }).source, address, salt: SALT0, initcodeHash: keccak256(initcode), initcodeBytes: size(initcode), args: jsonable(args), runtimeCodehash: keccak256(runtime), runtimeBytes: size(runtime), postCheck: "extcodehash(address) == runtimeCodehash", ...extra };
    steps.push({ ...entry, data: concat([SALT0, initcode]) });
    units[extra.label ?? name] = { address, runtimeCodehash: entry.runtimeCodehash, runtime };
    return entry;
  };

  steps.push({ id: "F0", kind: "FACTORY", contract: "DeterministicDeploymentProxy", address: FACTORY.address, deployer: FACTORY.deployer, presignedTx: FACTORY.presignedTx, runtimeCodehash: keccak256(FACTORY_RUNTIME()), postCheck: "extcode(address) == the presigned tx runtime (codehash 0x2fa86add…4989)" });

  const ingress = add("G1", "LedgerIngress", [zeroAddress], (self) => ({ SELF: self, SIGNATURE_STORE: zeroAddress }));
  const apply = add("G2", "LedgerApply", [], (self) => ({ SELF: self }));
  const control = add("G2c", "LedgerControl", [ingress.address, apply.address, ZERO], (self) => ({ SELF: self, INGRESS: ingress.address, INGRESS_CODEHASH: ingress.runtimeCodehash, APPLY: apply.address, APPLY_CODEHASH: apply.runtimeCodehash, PREDECESSOR_LAYOUT_ID: ZERO }));
  const reads = add("G3", "LedgerReads", [], {});
  const views = add("G4", "LedgerViews", [], {});
  const store = add("G5", "DescriptorStore", [], {});
  const layoutId = JSON.parse(readFileSync(join(root, "vectors/layout.json"), "utf8")).layoutId;
  const decoder = add("G7", "IndexReplayDecoder", [], { LAYOUT_ID: layoutId });
  const directory = add("G8", "ReaderDirectory", [], {});

  // G10: the nine NATIVE rule instances (the leaves first; child and alias name a sibling Type in their initcode)
  const ids = new Array(9);
  const descriptors = new Array(9);
  const instances = new Array(9);
  const profile = [];
  const rule = (t, args) => {
    const e = add(`G10.${t}`, RULES[t], args, {}, { label: `${RULES[t]}`, type: TYPE_NAMES[t] });
    const d = descriptor(t, owner, e.runtimeCodehash, e.initcodeHash, ids);
    const refs = refTypesOf(t, ids);
    ids[t] = keys.typeId(keys.shape(d), refs, e.runtimeCodehash);
    descriptors[t] = d;
    instances[t] = e.address;
    profile[t] = { type: TYPE_NAMES[t], typeId: ids[t], rule: RULES[t], instance: e.address, ruleCodehash: e.runtimeCodehash, ruleInitcodeHash: e.initcodeHash, refTypes: refs, shape: keys.shape(d), descriptor: d, descriptorBytes: size(d) };
  };
  for (const t of [T.BYTES, T.ROOT, T.DIRECTORY, T.NAME, T.NOTICE, T.CONTENT, T.EXTERNAL]) rule(t, []);
  rule(T.CHILD, [ids[T.ROOT]]);
  rule(T.ALIAS, [ids[T.DIRECTORY]]);
  const refuseAll = add("G10.policy", "RefuseAllPolicy", [], {});

  // G11: the nine descriptor blobs (CREATE2 by the DescriptorStore at salt 0; runtime 0x00 ‖ descriptor ‖ sig)
  for (const t of [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
    const sig = await declare(ids[t], key);
    const blobRuntime = concat(["0x00", descriptors[t], sig]);
    const blobInit = concat(["0x600B5981380380925939F3", blobRuntime]);
    const blob = getContractAddress({ opcode: "CREATE2", from: store.address, salt: SALT0, bytecode: blobInit });
    profile[t].declarationSig = sig;
    profile[t].blob = blob;
    profile[t].blobCodehash = keccak256(blobRuntime);
    steps.push({ id: `G11.${t}`, kind: "CALL", contract: "DescriptorStore", to: store.address, function: "put(bytes,bytes)", type: TYPE_NAMES[t], address: blob, args: [descriptors[t], sig], runtimeCodehash: profile[t].blobCodehash, postCheck: "extcodehash(blob) == keccak256(0x00 ‖ descriptor ‖ sig)", data: encodeFunctionData({ abi: artifact("DescriptorStore").abi, functionName: "put", args: [descriptors[t], sig] }) });
  }

  // G12: FilesFinalValidator, no caller pin
  const validator = add("G12", "FilesFinalValidator", [ids[T.NAME], ids[T.DIRECTORY]], {});
  const validatorIdentity = keccak256(enc(["bytes32", "bytes32", "bytes32"], [h("efs2/unit/files-final/1"), ids[T.NAME], ids[T.DIRECTORY]]));

  // G13–G14: the two implementations
  const core = add("G13", "LedgerCore", [ingress.address, apply.address, control.address, HOT_ABI_ID], { INGRESS: ingress.address, INGRESS_CODEHASH: ingress.runtimeCodehash, APPLY: apply.address, APPLY_CODEHASH: apply.runtimeCodehash, CONTROL: control.address, CONTROL_CODEHASH: control.runtimeCodehash, HOT_ABI_ID });
  const registryImpl = add("G14", "TypeRegistry", [store.address], { DESCRIPTOR_STORE: store.address });

  // G15: RealmGenesis by CREATE2; its three creations are f(G, nonce)
  const controllerInit = artifact("RealmController").bytecode;
  const proxyInit = artifact("TransparentUpgradeableProxy").bytecode;
  const executionProfileId = DEFAULTS.executionProfileId;
  const limitsHash = limitsProfileId(LIMITS);
  const genesisArgs = [owner, core.address, registryImpl.address, realmSalt, executionProfileId, limitsHash, directory.address, zeroAddress, ids[T.NOTICE], keccak256(controllerInit), keccak256(proxyInit)];
  const genesisInit = deployData("RealmGenesis", genesisArgs);
  const G = create2(genesisInit);
  const controller = createAt(G, 1);
  const registryProxy = createAt(G, 2);
  const ledgerProxy = createAt(G, 3);
  const ledgerAdmin = createAt(ledgerProxy, 1);
  const registryAdmin = createAt(registryProxy, 1);
  add("G15", "RealmGenesis", genesisArgs, {
    OWNER: owner, LEDGER_IMPL: core.address, LEDGER_IMPL_CODEHASH: core.runtimeCodehash, REGISTRY_IMPL: registryImpl.address, REGISTRY_IMPL_CODEHASH: registryImpl.runtimeCodehash,
    REALM_SALT: realmSalt, EXECUTION_PROFILE_ID: executionProfileId, LIMITS_HASH: limitsHash, READER_DIRECTORY: directory.address, WRAPPER_V1: zeroAddress,
    NOTICE_TYPE: ids[T.NOTICE], CONTROLLER_INITCODE_HASH: keccak256(controllerInit), PROXY_INITCODE_HASH: keccak256(proxyInit),
  }, { nonces: { controller: 1, registryProxy: 2, ledgerProxy: 3 } });

  // G16–G17: the stores name the predicted ledger proxy, INITIAL_WRITER = 0
  const posting = add("G16", "PostingStore", [ledgerProxy, zeroAddress, POSTING_FAMILIES.map(familyId)], { LEDGER: ledgerProxy, INITIAL_WRITER: zeroAddress });
  const bitmap = add("G17", "BitmapStore", [ledgerProxy, zeroAddress, BITMAP_FAMILIES.map(familyId)], { LEDGER: ledgerProxy, INITIAL_WRITER: zeroAddress, FAMILY_LIVE_SCOPE: familyId("live-scope") });

  // G18: RealmGenesis.run — the controller, the registry proxy, the ledger proxy (each initialized in its creation)
  const controllerRuntime = runtimeOf("RealmController", { LEDGER: ledgerProxy, REGISTRY: registryProxy, LEDGER_ADMIN: ledgerAdmin, REGISTRY_ADMIN: registryAdmin, NOTICE_TYPE: ids[T.NOTICE] });
  const proxyRuntime = (admin) => runtimeOf("TransparentUpgradeableProxy", { _admin: admin });
  const adminRuntime = runtimeOf("ProxyAdmin", {});
  const runData = encodeFunctionData({ abi: artifact("RealmGenesis").abi, functionName: "run", args: [LIMITS, controllerInit, proxyInit] });
  const created = [
    { label: "RealmController", address: controller, nonce: 1, runtimeCodehash: keccak256(controllerRuntime), runtimeBytes: size(controllerRuntime) },
    { label: "TypeRegistryProxy", address: registryProxy, nonce: 2, runtimeCodehash: keccak256(proxyRuntime(registryAdmin)), implementation: registryImpl.address, admin: registryAdmin, initializer: encodeFunctionData({ abi: artifact("TypeRegistry").abi, functionName: "initialize", args: [ledgerProxy, zeroAddress] }) },
    { label: "LedgerProxy", address: ledgerProxy, nonce: 3, runtimeCodehash: keccak256(proxyRuntime(ledgerAdmin)), implementation: core.address, admin: ledgerAdmin },
    { label: "RegistryProxyAdmin", address: registryAdmin, creator: registryProxy, nonce: 1, runtimeCodehash: keccak256(adminRuntime), owner: controller },
    { label: "LedgerProxyAdmin", address: ledgerAdmin, creator: ledgerProxy, nonce: 1, runtimeCodehash: keccak256(adminRuntime), owner: controller },
  ];
  for (const c of created) units[c.label] = { address: c.address, runtimeCodehash: c.runtimeCodehash };
  const realmInit = { realmSalt, controller, registry: registryProxy, readerDirectory: directory.address, executionProfileId, limits: LIMITS };
  created[2].initializer = encodeFunctionData({ abi: artifact("LedgerCore").abi, functionName: "initialize", args: [realmInit] });
  steps.push({ id: "G18", kind: "CALL", contract: "RealmGenesis", to: G, function: "run(Limits,bytes,bytes)", args: [LIMITS, keccak256(controllerInit), keccak256(proxyInit)], creates: created, postCheck: "genesis.controller/registryProxy/ledgerProxy == predicted; codehashes; ProxyAdmin.owner() == controller; a second run() reverts E_GENESIS(0)", data: runData });

  // G19: RealmIndex/1 with FilesFinalValidator pinned (purposeFilter FOLDER) and the two Files digest specs
  const unitsList = [{ foldHook: zeroAddress, foldCodehash: ZERO, finalHook: validator.address, finalCodehash: validator.runtimeCodehash, familyIds: [], purposeFilter: PURPOSE.FOLDER, hotAbiId: HOT_ABI_ID, identity: validatorIdentity }];
  const specs = [{ typeId: ids[T.CONTENT], wordIndex: 5, algorithm: 1 }, { typeId: ids[T.EXTERNAL], wordIndex: 5, algorithm: 1 }];
  const families = FAMILY_TABLE.map(([n, kind, universe, shape, live, s, from]) => ({
    familyId: familyId(n), kind, universe, shape, mandatory: from === 1n, liveSemantics: live, recipe: keccak256(encodePacked(["string", "uint8"], ["efs2/family-recipe/", kind])),
    fromAdmission: from, store: s === "posting" ? posting.address : bitmap.address, storeCodehash: s === "posting" ? posting.runtimeCodehash : bitmap.runtimeCodehash,
  }));
  const mHash = manifestHash(families, unitsList, specs, WORK_MODEL);
  const F = Object.fromEntries(FAMILY_TABLE.map(([n]) => [`F_${n.toUpperCase().replace(/-/g, "_")}`, familyId(n)]));
  const indexImm = { LEDGER: ledgerProxy, LAYOUT_ID: layoutId, HOT_ABI_ID, DECODER: decoder.address, POSTING: posting.address, BITMAP: bitmap.address, MANIFEST_HASH: mHash, ...F };
  const referenced = new Set(immutableLayout("RealmIndex").map((l) => l.name));
  const index = add("G19", "RealmIndex", [ledgerProxy, HOT_ABI_ID, decoder.address, posting.address, bitmap.address, unitsList, specs, WORK_MODEL], Object.fromEntries(Object.entries(indexImm).filter(([k]) => referenced.has(k))), { manifestHash: mHash });

  // G20: the genesis activation through the controller
  const components = {
    ledgerImpl: core.address, ledgerImplCodehash: core.runtimeCodehash, registryImpl: registryImpl.address, registryImplCodehash: registryImpl.runtimeCodehash,
    index: index.address, indexCodehash: index.runtimeCodehash, indexManifestHash: mHash, ingress: ingress.address, ingressCodehash: ingress.runtimeCodehash,
    applyDelegate: apply.address, applyCodehash: apply.runtimeCodehash, controller, controllerCodehash: keccak256(controllerRuntime), controllerOwner: owner,
    steward: zeroAddress, verifierProfilesRoot: ZERO,
  };
  const set = { revision: 1, components, layoutId, executionProfileId, capabilities: 0, acceptedChainId: BigInt(chainId), limits: LIMITS, expectedExecutionSet: ZERO, dependencyRoot: ZERO, noticePrincipal: ZERO, migrationScope: [], migration: "0x" };
  set.expectedExecutionSet = executionSet(set, ledgerProxy);
  steps.push({ id: "G20", kind: "CALL", contract: "RealmController", to: controller, from: owner, function: "activate(ActivationSet)", args: jsonable([set]), postCheck: "ledger.executionSet() == expectedExecutionSet; revision 1; index installed", data: encodeFunctionData({ abi: artifact("RealmController").abi, functionName: "activate", args: [set] }) });

  // G21: permissionless registration of the nine Types
  for (const t of [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
    steps.push({ id: `G21.${t}`, kind: "CALL", contract: "TypeRegistry", to: registryProxy, function: "registerDescribed(bytes,bytes,address,bytes)", type: TYPE_NAMES[t], typeId: ids[t], postCheck: "returns typeId; typeInfo(typeId).mandatory == instance", data: encodeFunctionData({ abi: artifact("TypeRegistry").abi, functionName: "registerDescribed", args: [descriptors[t], profile[t].declarationSig, instances[t], "0x"] }) });
  }

  const realmOrigin = keys.realmOrigin(chainId, ledgerProxy, realmSalt);
  const realm = { chainId, realmSalt, realmOrigin, realmId: keys.realmId(realmOrigin, executionProfileId), executionProfileId, domainSeparator: domainSeparator(chainId, ledgerProxy), limitsProfileId: limitsHash, indexObligations: keccak256(enc(["address", "bytes32", "bytes32"], [index.address, index.runtimeCodehash, mHash])) };
  const seed = seedPlan({ ids, principalId: keys.principal(owner) });
  steps.push(...seed.steps.map((s) => ({ id: s.id, kind: "EXECUTE", contract: "LedgerCore", to: ledgerProxy, from: owner, label: s.label, actions: jsonable(s.actions), bodies: s.bodies, postCheck: s.postCheck })));

  return {
    schema: "efs-deploy-plan/1",
    chainId, realmSalt, owner, fixturePrincipal: owner, declarationKey: owner, factory: FACTORY.address,
    hotAbiId: HOT_ABI_ID, layoutId, executionProfileId, limits: LIMITS, workModel: WORK_MODEL,
    genesis: { address: G, nonces: { controller: 1, registryProxy: 2, ledgerProxy: 3 } },
    addresses: { ingress: ingress.address, apply: apply.address, control: control.address, ledgerReads: reads.address, ledgerViews: views.address, descriptorStore: store.address, indexReplayDecoder: decoder.address, readerDirectory: directory.address, filesFinalValidator: validator.address, refuseAllPolicy: refuseAll.address, ledgerImpl: core.address, registryImpl: registryImpl.address, genesis: G, controller, registryProxy, ledgerProxy, ledgerAdmin, registryAdmin, postingStore: posting.address, bitmapStore: bitmap.address, index: index.address },
    realm, activation: set, index: { address: index.address, manifestHash: mHash, families, units: unitsList, specs, validatorIdentity },
    profile, seed: seed.expected, units, steps,
  };
}

/** The seed of design §12.2 (G22): root, then one folder and one file, as the fixture principal. */
export function seedPlan({ ids, principalId }) {
  const action = (o) => ({ kind: 0, typeId: ZERO, bodyHashOrRecordId: ZERO, purpose: ZERO, subject: ZERO, role: ZERO, target: ZERO, expectedRevision: 0n, salt: ZERO, ...o });
  const create = (salt) => action({ kind: ACTION.CREATE, salt });
  const publish = (t, body) => action({ kind: ACTION.PUBLISH, typeId: ids[t], bodyHashOrRecordId: keccak256(body) });
  const bind = (purpose, subject, role, target, expectedRevision = 0n) => action({ kind: ACTION.BIND, purpose, subject, role, target, expectedRevision });
  const rootSalt = h("root");
  const rootSubject = keys.subject(principalId, rootSalt);
  const rootBody = enc(["bytes32"], [rootSubject]);
  const rootDir = keys.record(ids[T.DIRECTORY], rootBody);
  const docsSubject = keys.subject(principalId, h("docs"));
  const docsBody = enc(["bytes32"], [docsSubject]);
  const docsDir = keys.record(ids[T.DIRECTORY], docsBody);
  const docsName = stringToHex("docs");
  const file = keys.subject(principalId, h("readme"));
  const fileBody = concat([enc(["bytes32"], [file]), stringToHex("Meeting at 10:00.\n")]);
  const fileRoot = keys.record(ids[T.ROOT], fileBody);
  const fileName = stringToHex("readme.txt");
  const steps = [
    { id: "G22.root", label: "seed root (CREATE + PUBLISH files-directory/1)", actions: [create(rootSalt), publish(T.DIRECTORY, rootBody)], bodies: ["0x", rootBody], postCheck: "recordHeader(root).typeId == files-directory/1; subjectCreatedAt(rootSubject) != 0" },
    { id: "G22.folder", label: "seed folder docs/ (CREATE, PUBLISH directory, PUBLISH name, BIND FOLDER)", actions: [create(h("docs")), publish(T.DIRECTORY, docsBody), publish(T.NAME, docsName), bind(PURPOSE.FOLDER, rootDir, keccak256(docsName), docsDir)], bodies: ["0x", docsBody, docsName, "0x"], postCheck: "head(FOLDER root/docs) BOUND → docs directory" },
    { id: "G22.file", label: "seed file docs/readme.txt (CREATE, PUBLISH root, PUBLISH name, BIND HEAD, BIND FOLDER)", actions: [create(h("readme")), publish(T.ROOT, fileBody), publish(T.NAME, fileName), bind(PURPOSE.HEAD, file, ZERO, fileRoot), bind(PURPOSE.FOLDER, docsDir, keccak256(fileName), file)], bodies: ["0x", fileBody, fileName, "0x", "0x"], postCheck: "head(HEAD file) → root record; head(FOLDER docs/readme.txt) → file" },
  ];
  const bindingKey = (purpose, subject, role) => keys.binding(principalId, keys.position(purpose, subject, role));
  return {
    steps,
    expected: {
      version: "efs-fixture-seed/1",
      principalId,
      root: { directoryRecordId: rootDir, subjectId: rootSubject, principalId },
      folder: { name: "docs", directoryRecordId: docsDir, subjectId: docsSubject, nameRecordId: keys.record(ids[T.NAME], docsName), bindingKey: bindingKey(PURPOSE.FOLDER, rootDir, keccak256(docsName)), scopeKey: keys.scope(principalId, PURPOSE.FOLDER, rootDir) },
      file: { name: "readme.txt", subjectId: file, rootRecordId: fileRoot, nameRecordId: keys.record(ids[T.NAME], fileName), headKey: bindingKey(PURPOSE.HEAD, file, ZERO), bindingKey: bindingKey(PURPOSE.FOLDER, docsDir, keccak256(fileName)), scopeKey: keys.scope(principalId, PURPOSE.FOLDER, docsDir), body: fileBody },
      counts: { admissions: 11, records: 5, bindings: 3, publications: 3 },
    },
  };
}

/** The factory runtime: the code the presigned transaction's init code returns (bytes 14.. of its data field;
 *  codehash 0x2fa86add…4989, the canonical Arachnid proxy). */
export function FACTORY_RUNTIME() {
  const tx = FACTORY.presignedTx;
  const at = tx.indexOf("b853"); // the 83-byte data field: a 14-byte prologue, then the 69-byte runtime
  const data = tx.slice(at + 4, at + 4 + 83 * 2);
  assert.equal(data.slice(0, 28), "604580600e600039806000f350fe", "presigned factory prologue");
  return `0x${data.slice(28)}`;
}

/** test/harness/doubles/Factory.sol RUNTIME, which the suites etch only when no factory exists (Foundry's test EVM
 *  pre-deploys the canonical one, so the constant is normally unused). Compared, not trusted. */
export function harnessFactoryRuntime() {
  const src = readFileSync(join(root, "test/harness/doubles/Factory.sol"), "utf8");
  const m = src.match(/RUNTIME\s*=\s*hex"([0-9a-f]+)"/);
  assert.ok(m, "Factory.sol RUNTIME not found");
  return `0x${m[1]}`;
}

/** JSON-safe copy (bigint → decimal string). */
export function jsonable(x) {
  return JSON.parse(JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

export const toJSON = (x) => `${JSON.stringify(jsonable(x), null, 2)}\n`;

/** The plan file: the steps without their raw calldata (the fixture recomputes it) plus a digest of all of it. */
export function planDocument(plan) {
  const { units, ...rest } = plan;
  const doc = jsonable({ ...rest, steps: plan.steps.map(({ data, ...s }) => ({ ...s, calldataHash: data ? keccak256(data) : undefined })) });
  doc.planHash = keccak256(stringToHex(JSON.stringify(doc)));
  return doc;
}

// ---- the schemas/ subset this tooling enforces (type, const, enum, required, properties, additionalProperties, items, minItems)

export function validate(doc, schemaFile) {
  const schema = JSON.parse(readFileSync(join(root, "schemas", schemaFile), "utf8"));
  const errs = [];
  const typeOf = (v) => (v === null ? "null" : Array.isArray(v) ? "array" : Number.isInteger(v) ? "integer" : typeof v);
  const check = (v, s, at) => {
    if (s.const !== undefined && JSON.stringify(v) !== JSON.stringify(s.const)) errs.push(`${at}: != const ${JSON.stringify(s.const)}`);
    if (s.enum && !s.enum.some((e) => JSON.stringify(e) === JSON.stringify(v))) errs.push(`${at}: not in ${JSON.stringify(s.enum)}`);
    if (s.type) {
      const types = [].concat(s.type);
      const t = typeOf(v);
      if (!types.includes(t) && !(t === "integer" && types.includes("number"))) errs.push(`${at}: type ${t}, want ${types.join("|")}`);
    }
    if (v && typeof v === "object" && !Array.isArray(v)) {
      for (const k of s.required ?? []) if (!(k in v)) errs.push(`${at}: missing ${k}`);
      for (const [k, sub] of Object.entries(s.properties ?? {})) if (k in v) check(v[k], sub, `${at}.${k}`);
      if (s.additionalProperties && typeof s.additionalProperties === "object") {
        for (const [k, x] of Object.entries(v)) if (!(k in (s.properties ?? {}))) check(x, s.additionalProperties, `${at}.${k}`);
      }
    }
    if (Array.isArray(v)) {
      if (s.minItems !== undefined && v.length < s.minItems) errs.push(`${at}: fewer than ${s.minItems} items`);
      if (s.items) v.forEach((x, i) => check(x, s.items, `${at}[${i}]`));
    }
  };
  check(doc, schema, schema.$id);
  return errs;
}

// ---- CLI -----------------------------------------------------------------------------------------------------------

export function parseArgs(argv, allowed) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { (out._ ??= []).push(a); continue; }
    const k = a.slice(2);
    assert.ok(allowed.includes(k), `unknown option ${a} (allowed: ${allowed.map((x) => `--${x}`).join(" ")})`);
    out[k] = argv[++i];
    assert.ok(out[k] !== undefined, `${a} needs a value`);
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const o = parseArgs(process.argv.slice(2), ["chain-id", "realm-salt", "out"]);
  const plan = await buildPlan({ chainId: Number(o["chain-id"] ?? DEFAULTS.chainId), realmSalt: o["realm-salt"] ?? DEFAULTS.realmSalt });
  const path = join(root, o.out ?? "deploy/plan.json");
  mkdirSync(dirname(path), { recursive: true });
  const doc = planDocument(plan);
  writeFileSync(path, toJSON(doc));
  console.log(`deploy-plan: ${doc.steps.length} steps for chain ${plan.chainId} → ${o.out ?? "deploy/plan.json"} (ledger ${plan.addresses.ledgerProxy}, executionSet ${plan.activation.expectedExecutionSet}, planHash ${doc.planHash})`);
}
