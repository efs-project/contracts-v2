// SPDX-License-Identifier: MIT
// Golden identity vectors for `src/lib/Keys.sol`, computed by an independent implementation (viem's
// keccak256 + ABI encoder, the SDK's stack) and never by Solidity. `forge test` reads the output from
// test/vectors/ids.json; the SDK's own `Keys` twin must reproduce the same file bit for bit.
// Run with `pnpm vectors` from the repository root; commit the regenerated file with any change.
import { writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters, keccak256, pad, stringToHex, toHex } from "viem";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const h = (s) => keccak256(stringToHex(s));
const enc = (types, values) => encodeAbiParameters(types.map((type) => ({ type })), values);
const k = (types, values) => keccak256(enc(types, values));

export const DOM = {
  record: h("efs2/record/1"),
  position: h("efs2/position/1"),
  binding: h("efs2/binding/1"),
  scope: h("efs2/vk/binding-scope/1"),
  posting: h("efs2/pk/1"),
  subject: h("efs2/subject/1"),
  principal: h("efs2/principal/1"),
  type: h("efs2/type/1"),
  roleScope: h("efs2/vk/role-scope/1"),
  realmOrigin: h("efs2/realm-origin/1"),
  realm: h("efs2/realm/1"),
  publication: h("efs2/publication/1"),
  nativeIntent: h("efs2/native-intent/1"),
  signedIntent: h("efs2/signed-intent/1"),
  profile: h("efs2/acceptance-profile/1"),
  describedShape: h("efs2/described-shape/1"),
  roleKey: h("efs2/role-key/1"),
  executionSet: h("efs2/execution-set/1"),
};
// Index families of design §10.2: keccak("efs2/family/<name>/1").
export const FAMILIES = ["by-type", "by-author", "backlink", "history", "scope", "reference-position", "by-record", "unique-by-type", "scalar", "digest", "role-scope", "roster", "live-scope"];
export const familyId = (name) => keccak256(stringToHex(`efs2/family/${name}/1`));
export const KIND = { byType: 1, byAuthor: 4, backlink: 5, history: 8, scope: 10, referencePosition: 11, byRecord: 12, uniqueByType: 13, scalar: 14, digest: 15 };

export const keys = {
  principal: (address) => pad(address, { size: 32 }),
  contractPrincipal: (realmOrigin, address) => k(["bytes32", "uint256", "bytes32", "address"], [DOM.principal, 2n, realmOrigin, address]),
  typeId: (shape, refTypes, ruleId) => k(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.type, shape, keccak256(enc(["bytes32[]"], [refTypes])), ruleId]),
  record: (typeId, body) => k(["bytes32", "bytes32", "bytes32"], [DOM.record, typeId, keccak256(body)]),
  recordFromHash: (typeId, bodyHash) => k(["bytes32", "bytes32", "bytes32"], [DOM.record, typeId, bodyHash]),
  subject: (creator, salt) => k(["bytes32", "bytes32", "bytes32"], [DOM.subject, creator, salt]),
  position: (purpose, subject, role) => k(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.position, purpose, subject, role]),
  binding: (principal, position) => k(["bytes32", "bytes32", "bytes32"], [DOM.binding, principal, position]),
  scope: (principal, purpose, subject) => k(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.scope, principal, purpose, subject]),
  posting: (typeId, kind, ordinal, valueKey) => k(["bytes32", "bytes32", "uint256", "uint256", "bytes32"], [DOM.posting, typeId, BigInt(kind), BigInt(ordinal), valueKey]),
  roleScope: (principal, purpose, role) => k(["bytes32", "bytes32", "bytes32", "bytes32"], [DOM.roleScope, principal, purpose, role]),
  realmOrigin: (chainId, core, salt) => k(["bytes32", "uint64", "address", "bytes32"], [DOM.realmOrigin, chainId, core, salt]),
  realmId: (origin, profile) => k(["bytes32", "bytes32", "uint16"], [DOM.realm, origin, profile]),
  publicationId: (principal, intentDigest) => k(["bytes32", "bytes32", "bytes32"], [DOM.publication, principal, intentDigest]),
  roleKey: (purpose, role) => k(["bytes32", "bytes32", "bytes32"], [DOM.roleKey, purpose, role]),
  shape: (descriptor) => k(["bytes32", "bytes"], [DOM.describedShape, descriptor]),
};
const zero = pad("0x", { size: 32 });
keys.byTypeList = (t) => keys.posting(t, KIND.byType, 0, zero);
keys.byAuthorList = (p) => keys.posting(zero, KIND.byAuthor, 0, p);
keys.backlinkList = (target) => keys.posting(zero, KIND.backlink, 0, target);
keys.historyList = (bk) => keys.posting(zero, KIND.history, 0, bk);
keys.scopeList = (sk) => keys.posting(zero, KIND.scope, 0, sk);
keys.referenceList = (t, ordinal, target) => keys.posting(t, KIND.referencePosition, ordinal, target);
keys.byRecordList = (id) => keys.posting(zero, KIND.byRecord, 0, id);
keys.uniqueByTypeList = (t) => keys.posting(t, KIND.uniqueByType, 0, zero);
keys.scalarList = (t, spec, kind, value) => keys.posting(t, KIND.scalar, spec, k(["uint8", "bytes32"], [kind, value]));
keys.digestList = (alg, value) => keys.posting(zero, KIND.digest, 0, k(["bytes32", "bytes32"], [alg, value]));

// Fixed inputs: mock addresses and tags that never occur on a real deployment.
const inputs = {
  eoa: "0x1111111111111111111111111111111111111111",
  contractAddress: "0x2222222222222222222222222222222222222222",
  realmOrigin: h("vectors/realm-origin"),
  shape: h("vectors/shape"),
  ruleId: h("vectors/rule"),
  refTypes: [h("vectors/ref-a"), h("vectors/ref-b")],
  body: stringToHex("hello, efs"),
  bodyHash: keccak256(stringToHex("hello, efs")),
  salt: h("vectors/salt"),
  purpose: h("efs2/purpose/head/1"),
  role: h("vectors/role"),
  ordinal: 3,
  spec: 2,
  scalarKind: 7,
  value: h("vectors/value"),
  algorithm: h("sha256"),
};
const eoaPrincipal = keys.principal(inputs.eoa);
const contractPrincipal = keys.contractPrincipal(inputs.realmOrigin, inputs.contractAddress);
const typeId = keys.typeId(inputs.shape, inputs.refTypes, inputs.ruleId);
const typeIdNoRefs = keys.typeId(inputs.shape, [], inputs.ruleId);
const recordId = keys.record(typeId, inputs.body);
const subjectId = keys.subject(eoaPrincipal, inputs.salt);
const positionKey = keys.position(inputs.purpose, subjectId, inputs.role);
const bindingKey = keys.binding(eoaPrincipal, positionKey);
const scopeKey = keys.scope(eoaPrincipal, inputs.purpose, subjectId);

const realmOrigin = keys.realmOrigin(11155111n, inputs.contractAddress, inputs.salt);
const vectors = {
  schema: "efs2/vectors/ids/1",
  families: Object.fromEntries(FAMILIES.map((n) => [n, familyId(n)])),
  generator: "tools/vectors.mjs (viem keccak256 + encodeAbiParameters)",
  domains: DOM,
  inputs,
  outputs: {
    eoaPrincipal,
    contractPrincipal,
    typeId,
    typeIdNoRefs,
    recordId,
    recordFromHash: keys.recordFromHash(typeId, inputs.bodyHash),
    subjectId,
    positionKey,
    bindingKey,
    scopeKey,
    byTypeList: keys.byTypeList(typeId),
    byAuthorList: keys.byAuthorList(eoaPrincipal),
    backlinkList: keys.backlinkList(recordId),
    historyList: keys.historyList(bindingKey),
    scopeList: keys.scopeList(scopeKey),
    referenceList: keys.referenceList(typeId, inputs.ordinal, recordId),
    byRecordList: keys.byRecordList(recordId),
    uniqueByTypeList: keys.uniqueByTypeList(typeId),
    scalarList: keys.scalarList(typeId, inputs.spec, inputs.scalarKind, inputs.value),
    digestList: keys.digestList(inputs.algorithm, inputs.value),
    roleScopeKey: keys.roleScope(eoaPrincipal, inputs.purpose, inputs.role),
    realmOrigin,
    realmId: keys.realmId(realmOrigin, 1),
    contractPrincipalOfOrigin: keys.contractPrincipal(realmOrigin, inputs.contractAddress),
    publicationId: keys.publicationId(eoaPrincipal, inputs.bodyHash),
    roleKey: keys.roleKey(inputs.purpose, inputs.role),
    shape: keys.shape(inputs.body),
  },
};
if (keys.recordFromHash(typeId, inputs.bodyHash) !== recordId) throw new Error("record derivations disagree");
const out = join(root, "test/vectors/ids.json");
writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
console.log(`vectors: wrote ${out} (${Object.keys(vectors.outputs).length} outputs); typeId ${typeId}`);
