// SPDX-License-Identifier: MIT
// The genesis deploy plan of design §8.2, computed offline from the Foundry artifacts in out/ (the identity build)
// and nothing else: every CREATE2 address from its initcode hash, the three RealmGenesis creations from its nonces,
// every runtime code hash (immutables filled from their recorded offsets), the ten Files descriptors and Type ids
// (an independent JS twin of src/profiles/FilesTypes.sol), the index manifest hash and the genesis execution set.
// Imported by tools/efs-fixture.mjs and tools/release.mjs; as a CLI it writes deploy/plan.json:
//
//   node tools/deploy-plan.mjs [--chain-id 31337] [--realm-salt 0x…] [--out deploy/plan.json] [--artifacts DIR]
//
// Immutable names come from the AST of an auxiliary build (`FOUNDRY_OUT=out/release-ast forge build --ast`), whose
// bytecode must equal the identity build's; without that build they come from release/release.json.
//
// The artifact source is one of three layouts, detected from the directory (`useArtifacts(dir)`; default
// $EFS_ARTIFACTS_DIR, else out/; absolute or relative to the repository root):
//   - "forge":    a Foundry identity build (out/); immutable names from $EFS_AST_DIR (default <dir>/release-ast);
//   - "snapshot": a tools/artifacts-snapshot.mjs copy carrying its sources and immutable layouts, so a fixture can
//                 run while the working tree is edited and rebuilt;
//   - "release":  the committed artifacts/ directory that tools/release.mjs writes (efs-artifact/1 per unit, named
//                 immutable offsets, optional index.json), so a checkout or release directory deploys without a
//                 forge build. Each unit is checked against <dir>/../release/release.json when that file exists.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
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
  sha256,
  size,
  stringToHex,
  toHex,
  zeroAddress,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const SNAPSHOT_FILE = "efs-artifacts-snapshot.json";
export const ARTIFACTS_INDEX = "index.json";
/** The default artifact source: $EFS_ARTIFACTS_DIR, else out/. */
export const DEFAULT_ARTIFACTS = resolve(root, process.env.EFS_ARTIFACTS_DIR || "out");
/** The current source (live bindings, switched by useArtifacts). */
export let OUT;
export let AST_OUT;
export let SNAPSHOT = null;
export let SOURCE_ROOT = root;
export let ARTIFACTS_MODE = "forge";
/** The repository the artifact source belongs to (release/, deploy/, vectors/ are read from it). */
export let REPO_ROOT = root;
let RELEASE_UNITS = null;
let INDEX = null;

/** Point every artifact read at `dir` and detect its layout. Returns a summary of the source. */
export function useArtifacts(dir = DEFAULT_ARTIFACTS) {
  const d = resolve(root, dir);
  assert.ok(existsSync(d), `artifact directory ${d} does not exist`);
  OUT = d;
  SNAPSHOT = existsSync(join(d, SNAPSHOT_FILE)) ? JSON.parse(readFileSync(join(d, SNAPSHOT_FILE), "utf8")) : null;
  const releaseLayout = !SNAPSHOT && existsSync(join(d, "LedgerCore.json")) && JSON.parse(readFileSync(join(d, "LedgerCore.json"), "utf8")).schema === "efs-artifact/1";
  ARTIFACTS_MODE = SNAPSHOT ? "snapshot" : releaseLayout ? "release" : "forge";
  AST_OUT = resolve(root, process.env.EFS_AST_DIR || join(d, "release-ast"));
  SOURCE_ROOT = SNAPSHOT ? join(d, "sources") : root;
  REPO_ROOT = releaseLayout ? dirname(d) : root;
  INDEX = releaseLayout && existsSync(join(d, ARTIFACTS_INDEX)) ? JSON.parse(readFileSync(join(d, ARTIFACTS_INDEX), "utf8")) : null;
  const relPath = join(REPO_ROOT, "release/release.json");
  RELEASE_UNITS = releaseLayout && existsSync(relPath) ? JSON.parse(readFileSync(relPath, "utf8")).contracts : null;
  cache.clear();
  astSeen.clear();
  astIndex = undefined;
  return artifactSource();
}
export const artifactSource = () => ({ dir: OUT, mode: ARTIFACTS_MODE, repoRoot: REPO_ROOT, checkedAgainstRelease: !!RELEASE_UNITS, snapshot: SNAPSHOT ? { createdAt: SNAPSHOT.createdAt, from: SNAPSHOT.from, rev: SNAPSHOT.rev } : null });
/** A repository file the plan reads (vectors/layout.json, the harness factory): the snapshot's copy, or the release
 *  directory's, when it has one; else this checkout's. */
export const repoFile = (rel) => {
  if (SNAPSHOT && existsSync(join(SOURCE_ROOT, rel))) return join(SOURCE_ROOT, rel);
  if (REPO_ROOT !== root && existsSync(join(REPO_ROOT, rel))) return join(REPO_ROOT, rel);
  return join(root, rel);
};
const shown = (p) => (p.startsWith(`${root}/`) ? p.slice(root.length + 1) : p);
const at = (dir) => (isAbsolute(dir) ? dir : resolve(root, dir));
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
export const DEFAULTS = { chainId: 31337, realmSalt: h("efs/fixture/realm/1"), executionProfileId: 1 };
/** The release hot-ABI id: keccak256("efs/ledger-hot/2") (the suites keep "efs/ledger-hot/2:test"). It is
 *  LedgerCore's HOT_ABI_ID immutable, RealmIndex's HOT_ABI_ID and the FilesFinalValidator unit's hotAbiId. */
export const HOT_ABI_ID_STRING = "efs/ledger-hot/2";
export const HOT_ABI_ID = h(HOT_ABI_ID_STRING);
/** ReaderDirectory kind labels (the directory does not interpret them; the strings of test/periphery/ReaderDirectory.t.sol). */
export const READER_KINDS = { lens: h("efs/reader/lens/1"), filesPage: h("efs/reader/files-page/1") };
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
  type: h("efs/type/1"), describedShape: h("efs/described-shape/1"), executionSet: h("efs/execution-set/1"),
  realmOrigin: h("efs/realm-origin/1"), realm: h("efs/realm/1"), record: h("efs/record/1"),
  subject: h("efs/subject/1"), position: h("efs/position/1"), binding: h("efs/binding/1"),
  scope: h("efs/vk/binding-scope/1"),
};
export const PURPOSE = { HEAD: h("efs/purpose/head/1"), FOLDER: h("efs/purpose/folder/1"), TAG: h("efs/purpose/tag/1") };
export const ACTION = { PUBLISH: 1, REUSE: 2, BIND: 3, UNBIND: 4, CREATE: 5, WITHDRAW: 6, RELEASE: 7 };
export const familyId = (name) => h(`efs/family/${name}/1`);
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
const astSeen = new Map();
let astIndex;
// The default source is selected at import only when it exists: a tree without out/ (a vendored release directory)
// must still be importable, and `buildPlan({artifacts})` / `--artifacts` select the source before any read.
if (existsSync(DEFAULT_ARTIFACTS)) useArtifacts();
/** <dir>/<File>.sol/<Name>.json, refused when stale against the source on disk (the abi-snapshot rule); in the
 *  release layout <dir>/<Name>.json, refused when its bytes differ from release/release.json. */
export function artifact(name, { file = name, dir = OUT } = {}) {
  assert.ok(dir, `no artifact directory: ${DEFAULT_ARTIFACTS} does not exist (run \`forge build\`, pass --artifacts DIR or set EFS_ARTIFACTS_DIR)`);
  const base = at(dir);
  const key = `${base}/${file}/${name}`;
  if (cache.has(key)) return cache.get(key);
  if (ARTIFACTS_MODE === "release" && base === OUT) {
    const path = join(base, `${name}.json`);
    assert.ok(existsSync(path), `${shown(path)} is missing (the release artifacts are written by tools/release.mjs)`);
    const r = JSON.parse(readFileSync(path, "utf8"));
    assert.equal(r.schema, "efs-artifact/1", `${shown(path)}: not an efs-artifact/1 document`);
    const u = RELEASE_UNITS?.[name];
    if (RELEASE_UNITS) {
      assert.ok(u, `${shown(path)}: release/release.json has no unit ${name}`);
      assert.equal(keccak256(r.deployedBytecode), u.runtimeHash, `${shown(path)}: runtime differs from release/release.json`);
      assert.equal(keccak256(r.bytecode), u.initcodeHash, `${shown(path)}: creation code differs from release/release.json`);
    }
    const refs = Object.fromEntries((r.immutables ?? []).map((i) => [i.name, i.offsets.map((start) => ({ start, length: 32 }))]));
    const out = { name, source: r.source, abi: r.abi, bytecode: r.bytecode, runtime: r.deployedBytecode, refs, immutables: r.immutables ?? [], settings: null, compiler: null, ast: null };
    cache.set(key, out);
    return out;
  }
  const path = join(base, `${file}.sol`, `${name}.json`);
  assert.ok(existsSync(path), `${shown(path)} is missing: run \`forge build\` first (or point EFS_ARTIFACTS_DIR at a build)`);
  const a = JSON.parse(readFileSync(path, "utf8"));
  const [source, target] = Object.entries(a.metadata.settings.compilationTarget)[0];
  assert.equal(target, name, `${path}: compilation target ${target}`);
  const srcPath = join(SOURCE_ROOT, source);
  assert.ok(existsSync(srcPath), `${shown(path)}: its source ${shown(srcPath)} is missing`);
  const text = readFileSync(srcPath);
  assert.equal(a.metadata.sources[source].keccak256, keccak256(text), `${shown(path)} was built from a different ${source}: run \`forge build\`, or run the fixture from a snapshot (tools/artifacts-snapshot.mjs, EFS_ARTIFACTS_DIR)`);
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
  TransparentUpgradeableProxy: "TransparentUpgradeableProxy", ProxyAdmin: "ProxyAdmin", LensReader: "LensReader", FilesPageReader: "FilesPageReader",
  FilesSpanRule: "FilesSpanRule", KeysView: "KeysView", EfsWeb3Gateway: "EfsWeb3Gateway",
};

// ---- immutables: names → offsets ------------------------------------------------------------------------------------

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
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) { if (!["build-info", "release-ast", "closure"].includes(e.name)) scan(join(dir, e.name)); }
      else if (e.name.endsWith(".json") && e.name !== SNAPSHOT_FILE) walk(JSON.parse(readFileSync(join(dir, e.name), "utf8")).ast);
    }
  };
  scan(AST_OUT);
  return astIndex;
}

/** Whether the AST build has this unit with its AST (a build without `--ast` has the artifact but no tree). */
export function hasAst(name) {
  const path = join(AST_OUT, `${UNITS[name]}.sol`, `${name}.json`);
  if (!astSeen.has(path)) astSeen.set(path, existsSync(path) && !!JSON.parse(readFileSync(path, "utf8")).ast);
  return astSeen.get(path);
}

/** `[{name, offsets}]` for a unit: from a snapshot's manifest, from the AST build (bytecode-checked against the
 *  identity build) or from release/release.json. */
export function immutableLayout(name) {
  const a = artifact(name, { file: UNITS[name] });
  if (Object.keys(a.refs).length === 0) return [];
  if (ARTIFACTS_MODE === "release") return a.immutables;
  if (SNAPSHOT?.immutables?.[name]) return SNAPSHOT.immutables[name];
  if (hasAst(name)) {
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
  // the names are the manifest's; the offsets must still be this build's
  const offsets = (groups) => groups.map((g) => g.join(",")).sort();
  assert.deepEqual(offsets(unit.immutables.map((i) => i.offsets)), offsets(Object.values(a.refs).map((refs) => refs.map((r) => r.start).sort((x, y) => x - y))), `${name}: release/release.json immutable offsets differ from the build's (run \`pnpm run release\` with the AST build)`);
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

export const T = { ROOT: 0, CHILD: 1, DIRECTORY: 2, NAME: 3, BYTES: 4, CONTENT: 5, EXTERNAL: 6, ALIAS: 7, NOTICE: 8, SPAN: 9 };
export const TYPE_NAMES = ["files-root/1", "files-child/1", "files-directory/1", "files-name/2", "files-bytes/1", "files-content/1", "files-external/1", "directory-alias/1", "realm-notice/1", "files-span/1"];
export const RULES = ["FilesRootRule", "FilesChildRule", "FilesDirectoryRule", "FilesNameRule", "FilesBytesRule", "FilesContentRule", "FilesExternalContentRule", "DirectoryAliasRule", "RealmNoticeRule", "FilesSpanRule"];
const NAMESPACE = h("efs/files/1");
const FIELD_PARENT = h("efs/files/field/parent/1");
const FIELD_BYTES = h("efs/files/field/bytes/1");
const FIELD_LEFT = h("efs/files/field/left/1");
const FIELD_RIGHT = h("efs/files/field/right/1");
const SEMANTIC_REVISION = h("efs/files/semantic/parent-revision/1");
const SEMANTIC_CARRIER = h("efs/files/semantic/bytes-carrier/1");
const SEMANTIC_SPAN_CHILD = h("efs/files/semantic/span-child/1");
/** `refTypes` sentinel: any Type. */
const REF_ANY = ZERO;
const refField = (id, semantic, ref) => encodePacked(["bytes32", "bytes32", "uint8", "uint8", "uint16", "uint256", "uint256", "bytes32"], [id, semantic, 1, 0, 32, 0n, 0n, ref]);
/** FilesTypes.*Spec(), byte for byte: description, dependencyClass, refHeaderWords, the REF32 field rows as
 *  [id, semantic, ref(ids)] (fieldCount = rows; refTypes = each row's ref, in order) and flags (header byte 133;
 *  0 when absent). Bit 0 is TYPE_FLAG_EMITS_BODY (the kernel logs a fresh body of at most 256 bytes in `Body`),
 *  meant for names, words and topic records: of these ten only files-name/2 sets it; the topic and text Types the
 *  tag profile adds set it there. */
const SPECS = [
  { description: "abi.encode(fileSubject, form) || rest; the first revision of a created file subject; form 0 rest is the file bytes, form 1 rest is one word naming a files-content/1 or files-external/1 record", dependencyClass: 2, refHeaderWords: 1, fields: [] },
  { description: "abi.encode(parentRecord, fileSubject, form) || rest; parent is files-root/1 or files-child/1 of the same file; form 0 rest is the file bytes, form 1 rest is one word naming a files-content/1 or files-external/1 record", dependencyClass: 2, refHeaderWords: 2, fields: [[FIELD_PARENT, SEMANTIC_REVISION, () => REF_ANY]] },
  { description: "abi.encode(bytes32 creatorPrincipal, bytes32 salt); a folder is this record, admitted only when the publishing principal is the creator word and the salt is nonzero", dependencyClass: 1, refHeaderWords: 1, fields: [] },
  { description: "raw UTF-8 name, 1-255 bytes, well-formed, byte-exact, case-sensitive, not . or .., ~efs reserved", dependencyClass: 1, refHeaderWords: 1, fields: [], flags: 1 },
  { description: "sha256(payload) || payload; one chunk, bounded only by the Realm maxBody; the empty payload is the remote sentinel", dependencyClass: 1, refHeaderWords: 1, fields: [] },
  { description: "[bytesRef, version, carrier, hashAlg, length, sha256, cipher, nonce12, plaintextLength, plaintextSHA256OrZero] || media, the media type being the rest of the body after 320 bytes; carrier 0 one files-bytes/1 record, 1 the remote sentinel, 2 a files-span/1 root; lengths below 2^64; media empty (unknown) or a lowercase RFC 6838 type/subtype with optional ;parameters, at most 255 bytes", dependencyClass: 1, refHeaderWords: 3, fields: [[FIELD_BYTES, SEMANTIC_CARRIER, () => REF_ANY]] },
  { description: "[bytesRef (the empty sentinel), version 2, carrier 2, hashAlg 1, length, sha256, locatorLength] || locator || media; a URI of 1-2048 printable ASCII bytes with an RFC 3986 scheme, no scheme allowlist; media as files-content/1, the rest of the body", dependencyClass: 1, refHeaderWords: 1, fields: [[FIELD_BYTES, SEMANTIC_CARRIER, (ids) => ids[T.BYTES]]] },
  { description: "abi.encode(targetObjectId, kind); kind 1 a files-directory/1 record, 2 a created file subject", dependencyClass: 2, refHeaderWords: 1, fields: [] },
  { description: "abi.encode(bytes32 kind, uint256 revision, bytes note); kind frozen | successor | migration", dependencyClass: 2, refHeaderWords: 1, fields: [] },
  { description: "abi.encode(left, right, length); each child a files-bytes/1 record with a nonempty payload or a files-span/1 record; length is the sum of the children payload lengths, below 2^64", dependencyClass: 1, refHeaderWords: 3, fields: [[FIELD_LEFT, SEMANTIC_SPAN_CHILD, () => REF_ANY], [FIELD_RIGHT, SEMANTIC_SPAN_CHILD, () => REF_ANY]] },
];
/** The rules' constructor arguments (sibling Type ids) and the dependency order they force (FilesTypes). */
const RULE_ARGS = {
  [T.SPAN]: (ids) => [ids[T.BYTES]], [T.CONTENT]: (ids) => [ids[T.BYTES], ids[T.SPAN]], [T.ROOT]: (ids) => [ids[T.CONTENT], ids[T.EXTERNAL]],
  [T.CHILD]: (ids) => [ids[T.ROOT], ids[T.CONTENT], ids[T.EXTERNAL]], [T.ALIAS]: (ids) => [ids[T.DIRECTORY]],
};
export const RULE_ORDER = [T.BYTES, T.SPAN, T.CONTENT, T.EXTERNAL, T.ROOT, T.CHILD, T.DIRECTORY, T.NAME, T.NOTICE, T.ALIAS];

/** FilesTypes.encode: the codec-1 bytes of a NATIVE descriptor (design §9.2 offsets). */
export function descriptor(t, key, ruleCodehash, initcodeHash, ids) {
  const s = SPECS[t];
  const name = stringToHex(TYPE_NAMES[t]);
  const description = stringToHex(s.description);
  const fields = s.fields.length ? concat(s.fields.map(([id, sem, ref]) => refField(id, sem, ref(ids)))) : "0x";
  const header = encodePacked(
    ["uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint8", "uint24", "uint8", "uint8", "uint8", "address", "bytes32", "bytes32", "bytes32", "uint16", "uint8", "uint8"],
    [1, 0, 3, s.fields.length, 1, s.dependencyClass, 1, 1, 0, 0, 0, size(name), key, NAMESPACE, ruleCodehash, initcodeHash, size(description), s.refHeaderWords, s.flags ?? 0],
  );
  assert.equal(size(header), 134);
  return concat([header, name, description, fields]);
}
export const refTypesOf = (t, ids) => SPECS[t].fields.map(([, , ref]) => ref(ids));

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
  return keccak256(enc(["bytes32", "bytes32", "bytes32", "uint256", "address"], [h("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), h("EFS"), h("1"), BigInt(chainId), ledger]));
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
    [h("efs/index-manifest/1"), families, units, specs, work, MANIFEST_PROFILES.physical, MANIFEST_PROFILES.callback],
  ));
}
export const MANIFEST_PROFILES = {
  physical: h("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head"),
  callback: h("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs"),
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
let planQueue = Promise.resolve();
/** `artifacts` selects the artifact source for this plan (default DEFAULT_ARTIFACTS); calls are serialized, because
 *  the source is module state. The result's `local` (excluded from planDocument) carries the ABIs and the other
 *  artifact facts a consumer needs after the plan, so nothing later depends on which source is current. */
export function buildPlan(opts = {}) {
  const run = planQueue.then(() => {
    useArtifacts(opts.artifacts ?? DEFAULT_ARTIFACTS);
    return computePlan(opts);
  });
  planQueue = run.catch(() => {});
  return run;
}

async function computePlan({ chainId = DEFAULTS.chainId, realmSalt = DEFAULTS.realmSalt, key = FIXTURE_KEY } = {}) {
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
  const layoutId = INDEX?.layoutId ?? JSON.parse(readFileSync(repoFile("vectors/layout.json"), "utf8")).layoutId;
  const decoder = add("G7", "IndexReplayDecoder", [], { LAYOUT_ID: layoutId });
  const directory = add("G8", "ReaderDirectory", [], {});

  // G10: the ten NATIVE rule instances in FilesTypes' dependency order (a rule naming a sibling Type id in its
  // initcode follows that Type)
  const ids = new Array(TYPE_NAMES.length);
  const descriptors = new Array(TYPE_NAMES.length);
  const instances = new Array(TYPE_NAMES.length);
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
  for (const t of RULE_ORDER) rule(t, RULE_ARGS[t] ? RULE_ARGS[t](ids) : []);
  const refuseAll = add("G10.policy", "RefuseAllPolicy", [], {});

  // G11: the ten descriptor blobs (CREATE2 by the DescriptorStore at salt 0; runtime 0x00 ‖ descriptor ‖ sig)
  for (let t = 0; t < TYPE_NAMES.length; t++) {
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
  const validatorIdentity = keccak256(enc(["bytes32", "bytes32", "bytes32"], [h("efs/unit/files-final/1"), ids[T.NAME], ids[T.DIRECTORY]]));

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
    familyId: familyId(n), kind, universe, shape, mandatory: from === 1n, liveSemantics: live, recipe: keccak256(encodePacked(["string", "uint8"], ["efs/family-recipe/", kind])),
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

  // R1–R4: the two readers (their constructors read layoutId() from the ledger proxy, so they follow G18) and their
  // permissionless ReaderDirectory listings (advisory discovery hints; design §5.13)
  // R0: KeysView, the pure identity derivations as an on-chain view (design §5.8; outside the execution set)
  const keysView = add("R0", "KeysView", [], {});
  const lens = add("R1", "LensReader", [ledgerProxy, views.address, reads.address], { LEDGER: ledgerProxy, VIEWS: views.address, READS: reads.address, LAYOUT: layoutId, F_SCOPE: familyId("scope") });
  const page = add("R2", "FilesPageReader", [ledgerProxy, views.address, reads.address, ids[T.NAME], ids[T.ROOT], ids[T.CHILD]], { LEDGER: ledgerProxy, VIEWS: views.address, READS: reads.address, LAYOUT: layoutId, NAME_TYPE: ids[T.NAME], ROOT_TYPE: ids[T.ROOT], CHILD_TYPE: ids[T.CHILD] });
  const listing = (id, kind, reader, label) => steps.push({ id, kind: "CALL", contract: "ReaderDirectory", to: directory.address, function: "list(address,bytes32,address)", label, args: [ledgerProxy, kind, reader], postCheck: "readers(ledger, kind) lists the reader with its codehash, layoutId and physical profile", data: encodeFunctionData({ abi: artifact("ReaderDirectory").abi, functionName: "list", args: [ledgerProxy, kind, reader] }) });
  listing("R3", READER_KINDS.lens, lens.address, "list LensReader under efs/reader/lens/1");
  listing("R4", READER_KINDS.filesPage, page.address, "list FilesPageReader under efs/reader/files-page/1");

  // G21: permissionless registration of the ten Types
  for (let t = 0; t < TYPE_NAMES.length; t++) {
    steps.push({ id: `G21.${t}`, kind: "CALL", contract: "TypeRegistry", to: registryProxy, function: "registerDescribed(bytes,bytes,address,bytes)", type: TYPE_NAMES[t], typeId: ids[t], postCheck: "returns typeId; typeInfo(typeId).mandatory == instance", data: encodeFunctionData({ abi: artifact("TypeRegistry").abi, functionName: "registerDescribed", args: [descriptors[t], profile[t].declarationSig, instances[t], "0x"] }) });
  }

  const realmOrigin = keys.realmOrigin(chainId, ledgerProxy, realmSalt);
  const realm = { chainId, realmSalt, realmOrigin, realmId: keys.realmId(realmOrigin, executionProfileId), executionProfileId, domainSeparator: domainSeparator(chainId, ledgerProxy), limitsProfileId: limitsHash, indexObligations: keccak256(enc(["address", "bytes32", "bytes32"], [index.address, index.runtimeCodehash, mHash])) };
  const seed = seedPlan({ ids, principalId: keys.principal(owner) });
  // R5: the web3:// gateway (ERC-5219 with ERC-7617 chunks; docs/LARGE-FILES.md), bound to the seed's root directory
  // record and the page reader. A reader outside the execution set and outside the ReaderDirectory (not an IReader).
  const rootDirectory = seed.expected.root.directoryRecordId;
  const gatewayTypes = { directory: ids[T.DIRECTORY], name: ids[T.NAME], root: ids[T.ROOT], child: ids[T.CHILD], content: ids[T.CONTENT], external_: ids[T.EXTERNAL], bytes_: ids[T.BYTES], span: ids[T.SPAN] };
  const gateway = add("R5", "EfsWeb3Gateway", [ledgerProxy, reads.address, views.address, page.address, rootDirectory, gatewayTypes], {
    LEDGER: ledgerProxy, READS: reads.address, VIEWS: views.address, PAGER: page.address, LAYOUT: layoutId, ROOT_DIRECTORY: rootDirectory,
    DIRECTORY_TYPE: ids[T.DIRECTORY], NAME_TYPE: ids[T.NAME], ROOT_TYPE: ids[T.ROOT], CHILD_TYPE: ids[T.CHILD], CONTENT_TYPE: ids[T.CONTENT], EXTERNAL_TYPE: ids[T.EXTERNAL], BYTES_TYPE: ids[T.BYTES], SPAN_TYPE: ids[T.SPAN],
  });
  steps.push(...seed.steps.map((s) => ({ id: s.id, kind: "EXECUTE", contract: "LedgerCore", to: ledgerProxy, from: owner, label: s.label, actions: jsonable(s.actions), bodies: s.bodies, marker: s.marker, postCheck: s.postCheck })));

  return {
    schema: "efs-deploy-plan/1",
    chainId, realmSalt, owner, fixturePrincipal: owner, declarationKey: owner, factory: FACTORY.address,
    hotAbiId: HOT_ABI_ID, layoutId, executionProfileId, limits: LIMITS, workModel: WORK_MODEL,
    genesis: { address: G, nonces: { controller: 1, registryProxy: 2, ledgerProxy: 3 } },
    addresses: { ingress: ingress.address, apply: apply.address, control: control.address, ledgerReads: reads.address, ledgerViews: views.address, descriptorStore: store.address, indexReplayDecoder: decoder.address, readerDirectory: directory.address, filesFinalValidator: validator.address, refuseAllPolicy: refuseAll.address, ledgerImpl: core.address, registryImpl: registryImpl.address, genesis: G, controller, registryProxy, ledgerProxy, ledgerAdmin, registryAdmin, postingStore: posting.address, bitmapStore: bitmap.address, index: index.address, lensReader: lens.address, filesPageReader: page.address, keysView: keysView.address, web3Gateway: gateway.address },
    readers: { lens: { address: lens.address, kind: READER_KINDS.lens, kindLabel: "efs/reader/lens/1", runtimeCodehash: lens.runtimeCodehash }, filesPage: { address: page.address, kind: READER_KINDS.filesPage, kindLabel: "efs/reader/files-page/1", runtimeCodehash: page.runtimeCodehash } },
    gateway: { address: gateway.address, runtimeCodehash: gateway.runtimeCodehash, resolveMode: "5219", rootDirectory, pager: page.address, urlBase: `web3://${gateway.address}:${chainId}/` },
    hotAbiIdString: HOT_ABI_ID_STRING,
    realm, activation: set, index: { address: index.address, manifestHash: mHash, families, units: unitsList, specs, validatorIdentity },
    profile, seed: seed.expected, units, steps,
    local: {
      artifacts: artifactSource(),
      abis: Object.fromEntries(Object.entries(UNITS).map(([n, f]) => [n, artifact(n, { file: f }).abi])),
      proxyAdminImmutableOffsets: Object.values(artifact("TransparentUpgradeableProxy").refs).flat().map((r) => r.start).sort((x, y) => x - y),
      harnessFactoryRuntime: harnessFactoryRuntime(),
      repoRoot: REPO_ROOT,
    },
  };
}

/** `n` deterministic bytes: word i is keccak256(abi.encode(seed, i)) (test/integration/FilesLargeFiles.t.sol `_payload`). */
export function fixturePayload(n, seed) {
  const words = [];
  for (let i = 0; i < n; i += 32) words.push(keccak256(enc(["bytes32", "uint256"], [seed, BigInt(i)])).slice(2));
  return `0x${words.join("").slice(0, n * 2)}`;
}

/** EfsFiles.chunk (`efs/chunking/1`): chunks in payload order, then the span nodes in post-order. */
export function chunkPayload(ids, payload, chunkSize = CHUNK_PAYLOAD) {
  const total = size(payload);
  const n = total === 0 ? 1 : Math.ceil(total / chunkSize);
  const bodies = [];
  const chunks = [];
  for (let i = 0; i < n; i++) {
    const piece = `0x${payload.slice(2 + i * chunkSize * 2, 2 + Math.min((i + 1) * chunkSize, total) * 2)}`;
    const body = concat([sha256(piece), piece]);
    bodies.push({ typeId: ids[T.BYTES], body });
    chunks.push(keys.record(ids[T.BYTES], body));
  }
  if (n === 1) return { bodies, root: chunks[0], isSpan: false, chunks, spans: [] };
  const spans = [];
  const tree = (lo, hi) => {
    if (hi - lo === 1) return chunks[lo];
    let k = 1;
    while (k * 2 < hi - lo) k *= 2;
    const left = tree(lo, lo + k);
    const right = tree(lo + k, hi);
    const length = Math.min(hi * chunkSize, total) - lo * chunkSize;
    const body = enc(["bytes32", "bytes32", "uint256"], [left, right, BigInt(length)]);
    bodies.push({ typeId: ids[T.SPAN], body });
    const id = keys.record(ids[T.SPAN], body);
    spans.push(id);
    return id;
  };
  const root = tree(0, n);
  return { bodies, root, isSpan: true, chunks, spans };
}

/** EfsFiles.split: greedy publication ends under maxActions and maxBodyBytes. */
export function splitPublications(bodies, maxActions, maxBodyBytes) {
  const ends = [];
  let actions = 0;
  let bytes = 0;
  bodies.forEach((b, i) => {
    const len = size(b);
    if (actions !== 0 && (actions === maxActions || bytes + len > maxBodyBytes)) { ends.push(i); actions = 0; bytes = 0; }
    actions++;
    bytes += len;
  });
  if (actions) ends.push(bodies.length);
  return ends;
}

/** `files-content/1` (EfsFiles.contentBody, plaintext): the ten words, then the media bytes as the rest of the body
 *  (docs/LARGE-FILES.md). `media` is a string, already valid (`mediaTypeRefusal(media) === 0`). */
export function filesContentBody({ bytesRef: ref, carrier, length, sha256: digest, media = "" }) {
  const m = stringToHex(media);
  assert.equal(mediaTypeRefusal(m), 0, `invalid media type ${JSON.stringify(media)}`);
  return concat([enc(["bytes32", "uint256", "uint256", "uint256", "uint256", "bytes32", "uint256", "bytes32", "uint256", "bytes32"], [ref, 1n, BigInt(carrier), 1n, BigInt(length), digest, 0n, ZERO, BigInt(length), digest]), m]);
}
/** `files-external/1` (EfsFiles.externalBody): seven words, then the locator, then the media bytes (the rest). */
export function filesExternalBody({ sentinel, length, sha256: digest, locator, media = "" }) {
  const l = stringToHex(locator);
  const m = stringToHex(media);
  assert.equal(mediaTypeRefusal(m), 0, `invalid media type ${JSON.stringify(media)}`);
  return concat([enc(["bytes32", "uint256", "uint256", "uint256", "uint256", "bytes32", "uint256"], [sentinel, 2n, 2n, 1n, BigInt(length), digest, BigInt(size(l))]), l, m]);
}
/** The media-type grammar of `FilesProfile.mediaTypeRefusal` (hex in): 0 valid (empty is valid: unknown), else the
 *  first refusal: 1 longer than 255 bytes, 2 a bad type name, 3 no "/" after the type, 4 a bad subtype name, 5 the
 *  subtype is followed by a byte other than ";", 6 a parameter byte outside 0x20..0x7e. A name is an RFC 6838
 *  restricted-name in lowercase: 1..127 bytes, first a-z or 0-9, then a-z 0-9 ! # $ & - ^ _ . +. */
export function mediaTypeRefusal(hex) {
  const b = Buffer.from(hex.slice(2), "hex");
  if (b.length === 0) return 0;
  if (b.length > 255) return 1;
  const first = (c) => (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
  const rest = (c) => first(c) || "!#$&-^_.+".includes(String.fromCharCode(c));
  const name = (i) => { if (i >= b.length || !first(b[i])) return -1; let j = i + 1; while (j < b.length && rest(b[j])) j++; return j - i > 127 ? -1 : j; };
  const t = name(0);
  if (t < 0) return 2;
  if (t >= b.length || b[t] !== 0x2f) return 3;
  const s = name(t + 1);
  if (s < 0) return 4;
  if (s === b.length) return 0;
  if (b[s] !== 0x3b) return 5;
  for (let i = s + 1; i < b.length; i++) if (b[i] < 0x20 || b[i] > 0x7e) return 6;
  return 0;
}
/** `files-directory/1` (EfsFiles.directoryBody): abi.encode(creatorPrincipal, salt), 64 bytes; FilesDirectoryRule
 *  admits it only from the creator principal and with a nonzero salt. */
export function filesDirectoryBody(creatorPrincipal, salt) {
  assert.notEqual(BigInt(salt), 0n, "a folder salt is nonzero");
  return enc(["bytes32", "bytes32"], [creatorPrincipal, salt]);
}
/** The canonical chunk payload of efs/chunking/1 (EfsFiles.CHUNK_PAYLOAD). */
export const CHUNK_PAYLOAD = 8160;
export const SEED_VERSION = "efs-fixture-seed/4";
/** The seed's big file: about 20 KB of deterministic bytes (three chunks, two span nodes). */
export const BIG_FILE = { name: "big.bin", length: 20_000, seed: h("efs-fixture/big.bin"), media: "application/octet-stream" };
/** The seed's remote file: a files-external/1 record naming a web3:// locator for a short known text. */
export const REMOTE_FILE = { name: "remote.txt", text: "This file lives at its locator, not on the ledger.\n", locator: "web3://0x0000000000000000000000000000000000000000:31337/remote.txt", media: "text/plain; charset=utf-8" };

/**
 * The seed of design §12.2 (G22) and docs/LARGE-FILES.md, as the fixture principal: the root; the folder docs/;
 * docs/readme.txt (form 0, inline bytes); docs/big.bin (form 1 naming a files-content/1 carrier-2 descriptor over
 * an efs/chunking/1 span tree, split into publications under the Realm limits); docs/remote.txt (form 1 naming a
 * files-external/1 record with a web3:// locator and the empty files-bytes/1 sentinel).
 */
export function seedPlan({ ids, principalId, limits = LIMITS }) {
  const action = (o) => ({ kind: 0, typeId: ZERO, bodyHashOrRecordId: ZERO, purpose: ZERO, subject: ZERO, role: ZERO, target: ZERO, expectedRevision: 0n, saltOrStrength: ZERO, ...o });
  const create = (salt) => ({ a: action({ kind: ACTION.CREATE, saltOrStrength: salt }), b: "0x" });
  const publish = (typeId, body) => ({ a: action({ kind: ACTION.PUBLISH, typeId, bodyHashOrRecordId: keccak256(body) }), b: body });
  const bind = (purpose, subject, role, target, expectedRevision = 0n) => ({ a: action({ kind: ACTION.BIND, purpose, subject, role, target, expectedRevision }), b: "0x" });
  const step = (id, label, list, marker, postCheck) => ({ id, label, actions: list.map((x) => x.a), bodies: list.map((x) => x.b), marker, postCheck });
  const bindingKey = (purpose, subject, role) => keys.binding(principalId, keys.position(purpose, subject, role));

  // a folder is the files-directory/1 record abi.encode(creatorPrincipal, salt), published by its creator; no CREATE
  const rootSalt = h("root");
  const rootBody = filesDirectoryBody(principalId, rootSalt);
  const rootDir = keys.record(ids[T.DIRECTORY], rootBody);
  const docsSalt = h("docs");
  const docsBody = filesDirectoryBody(principalId, docsSalt);
  const docsDir = keys.record(ids[T.DIRECTORY], docsBody);
  const docsName = stringToHex("docs");
  const steps = [
    step("G22.root", "seed root (PUBLISH files-directory/1)", [publish(ids[T.DIRECTORY], rootBody)], { record: rootDir }, "recordHeader(root).typeId == files-directory/1"),
    step("G22.folder", "seed folder docs/ (PUBLISH directory, PUBLISH name, BIND FOLDER)", [publish(ids[T.DIRECTORY], docsBody), publish(ids[T.NAME], docsName), bind(PURPOSE.FOLDER, rootDir, keccak256(docsName), docsDir)], { record: docsDir }, "head(FOLDER root/docs) BOUND → docs directory"),
  ];
  // a file created in docs/ whose first revision is `rest` after abi.encode(file, form)
  const fileIn = (salt, name, form, rest) => {
    const file = keys.subject(principalId, h(salt));
    const body = concat([enc(["bytes32", "uint256"], [file, BigInt(form)]), rest]);
    const head = keys.record(ids[T.ROOT], body);
    const nameHex = stringToHex(name);
    return {
      file, head, body, nameHex,
      actions: [create(h(salt)), publish(ids[T.ROOT], body), publish(ids[T.NAME], nameHex), bind(PURPOSE.HEAD, file, ZERO, head), bind(PURPOSE.FOLDER, docsDir, keccak256(nameHex), file)],
      ids: { name, subjectId: file, headRecordId: head, headRevision: 1, form, nameRecordId: keys.record(ids[T.NAME], nameHex), headKey: bindingKey(PURPOSE.HEAD, file, ZERO), bindingKey: bindingKey(PURPOSE.FOLDER, docsDir, keccak256(nameHex)) },
    };
  };

  // docs/readme.txt: form 0, the bytes inline
  const readmeText = stringToHex("Meeting at 10:00.\n");
  const readme = fileIn("readme", "readme.txt", 0, readmeText);
  steps.push(step("G22.file", "seed file docs/readme.txt (CREATE, PUBLISH root form 0, PUBLISH name, BIND HEAD, BIND FOLDER)", readme.actions, { subject: readme.file }, "head(HEAD file) → root record; head(FOLDER docs/readme.txt) → file"));

  // docs/big.bin: chunks + spans + files-content/1 (carrier 2) + the form-1 revision, split under the limits
  const bigPayload = fixturePayload(BIG_FILE.length, BIG_FILE.seed);
  const tree = chunkPayload(ids, bigPayload);
  const bigSha = sha256(bigPayload);
  const contentBody = filesContentBody({ bytesRef: tree.root, carrier: tree.isSpan ? 2 : 0, length: BIG_FILE.length, sha256: bigSha, media: BIG_FILE.media });
  const contentId = keys.record(ids[T.CONTENT], contentBody);
  const big = fileIn("big.bin", BIG_FILE.name, 1, enc(["bytes32"], [contentId]));
  const bigList = [...tree.bodies.map((x) => publish(x.typeId, x.body)), publish(ids[T.CONTENT], contentBody), ...big.actions];
  const ends = splitPublications(bigList.map((x) => x.b), limits.maxActions, limits.maxBodyBytesPerPublication);
  let from = 0;
  ends.forEach((end, i) => {
    const part = bigList.slice(from, end);
    const last = i === ends.length - 1;
    const lastPublish = [...part].reverse().find((x) => x.a.kind === ACTION.PUBLISH);
    steps.push(step(`G22.big.${i}`, `seed docs/big.bin publication ${i + 1}/${ends.length} (${part.length} actions, ${part.reduce((n, x) => n + size(x.b), 0)} body bytes)`, part,
      last ? { subject: big.file } : { record: keys.record(lastPublish.a.typeId, lastPublish.b) },
      last ? "head(HEAD big.bin) → form-1 root naming the files-content/1 record; head(FOLDER docs/big.bin) → file" : "every chunk and span of this publication admitted"));
    from = end;
  });

  // docs/remote.txt: the empty files-bytes/1 sentinel, a files-external/1 record, the form-1 revision naming it
  const text = stringToHex(REMOTE_FILE.text);
  const sentinelBody = concat([sha256("0x"), "0x"]);
  const sentinelId = keys.record(ids[T.BYTES], sentinelBody);
  const locator = stringToHex(REMOTE_FILE.locator);
  const externalBody = filesExternalBody({ sentinel: sentinelId, length: size(text), sha256: sha256(text), locator: REMOTE_FILE.locator, media: REMOTE_FILE.media });
  const externalId = keys.record(ids[T.EXTERNAL], externalBody);
  const remote = fileIn("remote.txt", REMOTE_FILE.name, 1, enc(["bytes32"], [externalId]));
  steps.push(step("G22.remote", "seed docs/remote.txt (PUBLISH sentinel bytes, PUBLISH files-external/1, CREATE, PUBLISH root form 1, PUBLISH name, BIND HEAD, BIND FOLDER)", [publish(ids[T.BYTES], sentinelBody), publish(ids[T.EXTERNAL], externalBody), ...remote.actions], { subject: remote.file }, "head(HEAD remote.txt) → form-1 root naming the files-external/1 record"));

  // counts the ledger must report: every action is one admission; records and binding cells are distinct ids
  const records = new Set();
  const bindings = new Set();
  let admissions = 0;
  for (const s of steps) {
    s.actions.forEach((a, i) => {
      admissions++;
      if (a.kind === ACTION.PUBLISH) records.add(keys.record(a.typeId, s.bodies[i]));
      if (a.kind === ACTION.BIND) bindings.add(bindingKey(a.purpose, a.subject, a.role));
    });
  }
  const file = { name: "readme.txt", subjectId: readme.file, rootRecordId: readme.head, nameRecordId: readme.ids.nameRecordId, headKey: readme.ids.headKey, bindingKey: readme.ids.bindingKey, scopeKey: keys.scope(principalId, PURPOSE.FOLDER, docsDir), body: readme.body };
  return {
    steps,
    expected: {
      version: SEED_VERSION,
      principalId,
      root: { directoryRecordId: rootDir, principalId },
      folder: { name: "docs", directoryRecordId: docsDir, nameRecordId: keys.record(ids[T.NAME], docsName), bindingKey: bindingKey(PURPOSE.FOLDER, rootDir, keccak256(docsName)), scopeKey: keys.scope(principalId, PURPOSE.FOLDER, rootDir) },
      file,
      files: [
        { ...readme.ids, length: size(readmeText), sha256: sha256(readmeText) },
        { ...big.ids, contentRecordId: contentId, media: BIG_FILE.media, spanRootId: tree.root, length: BIG_FILE.length, sha256: bigSha, chunkCount: tree.chunks.length, spanCount: tree.spans.length, chunkPayload: CHUNK_PAYLOAD, payloadSeed: BIG_FILE.seed, publications: ends.length },
        { ...remote.ids, externalRecordId: externalId, sentinelRecordId: sentinelId, locator: REMOTE_FILE.locator, media: REMOTE_FILE.media, length: size(text), sha256: sha256(text), text: REMOTE_FILE.text },
      ],
      counts: { admissions, records: records.size, bindings: bindings.size, publications: steps.length },
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
  const path = repoFile("test/harness/doubles/Factory.sol");
  if (!existsSync(path)) return null; // a release directory without the test harness
  const src = readFileSync(path, "utf8");
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
  const { units, local, ...rest } = plan;
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
    if (a === "--") continue; // pnpm run passes it through
    if (!a.startsWith("--")) { (out._ ??= []).push(a); continue; }
    const k = a.slice(2);
    assert.ok(allowed.includes(k), `unknown option ${a} (allowed: ${allowed.map((x) => `--${x}`).join(" ")})`);
    out[k] = argv[++i];
    assert.ok(out[k] !== undefined, `${a} needs a value`);
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const o = parseArgs(process.argv.slice(2), ["chain-id", "realm-salt", "out", "artifacts"]);
  const plan = await buildPlan({ chainId: Number(o["chain-id"] ?? DEFAULTS.chainId), realmSalt: o["realm-salt"] ?? DEFAULTS.realmSalt, artifacts: o.artifacts });
  const path = resolve(root, o.out ?? "deploy/plan.json");
  mkdirSync(dirname(path), { recursive: true });
  const doc = planDocument(plan);
  writeFileSync(path, toJSON(doc));
  console.log(`deploy-plan: ${doc.steps.length} steps for chain ${plan.chainId} → ${o.out ?? "deploy/plan.json"} (ledger ${plan.addresses.ledgerProxy}, executionSet ${plan.activation.expectedExecutionSet}, planHash ${doc.planHash})`);
}
