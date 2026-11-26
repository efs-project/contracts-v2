# One-way doors

Values that enter permanent identities. Each is a string, a preimage or a width that a running Realm
can never change without re-identifying data. Every entry has a golden vector produced by an
implementation independent of Solidity (`tools/vectors.mjs`, viem) and a test that pins it.

## Identity domains (`src/lib/Keys.sol`; vectors `test/vectors/ids.json`; test `test/unit/Keys.t.sol`)

"Prototype-verbatim" means the preimage shape; every domain string lost its generation tag on 2026-11-24 (DESIGN.md
adoption note 25), so no id equals the prototype's.

| Domain | Derivation | Note |
| --- | --- | --- |
| `efs/record/1` | `keccak(DOM, typeId, keccak(body))` | prototype-verbatim |
| `efs/subject/1` | `keccak(DOM, creatorPrincipal, salt)` | prototype-verbatim |
| `efs/position/1` | `keccak(DOM, purpose, subject, role)` | prototype-verbatim |
| `efs/binding/1` | `keccak(DOM, principalId, position)` | prototype-verbatim |
| `efs/vk/binding-scope/1` | `keccak(DOM, principalId, purpose, subject)` | prototype-verbatim; the `ScopeKey` |
| `efs/pk/1` | `keccak(DOM, typeId, uint256(kind), uint256(ordinal), value)` | prototype-verbatim; posting keys |
| `efs/principal/1` | key principal = left-padded address; contract principal = `keccak(DOM, 2, realmOrigin, address)` | prototype-verbatim; `principalFor` recognizes only the exact 23-byte `ef0100` designator as a key |
| `efs/type/1` | `keccak(DOM, shape, keccak(abi.encode(refTypes)), ruleId)` | prototype-verbatim; `ruleId` = the codehash named in the descriptor header (Q1) |
| `efs/vk/role-scope/1` | `keccak(DOM, principalId, purpose, role)` | **new**: index family 16 key |
| `efs/realm-origin/1` | `keccak(DOM, genesisChainId, coreAddress, realmSalt)` | **changed from the prototype** (adds `realmSalt`); Q13 |
| `efs/realm/1` | `keccak(DOM, realmOrigin, genesisExecutionProfileId)` | new |
| `efs/publication/1` | `keccak(DOM, principalId, intentDigest)` | the prototype's format-2 shape under a new domain; emitted, never stored |
| `efs/native-intent/1` | `keccak(DOM, realmId, principalId, nonce, deadline, expectedExecutionSet, expectedAcceptanceProfile, guardHash, actionsHash)` | the native retry key; pure over caller inputs |
| `efs/signed-intent/1` | `keccak(DOM, hashStruct(intent), actionsHash)` | the signed retry key, chain-free |
| `efs/acceptance-profile/1` | fold seed `keccak(DOM, executionSet)` per design §6.2 | |
| `efs/described-shape/1` | `keccak(DOM, descriptorBytes)` | |
| `efs/role-key/1` | `keccak(DOM, purpose, role)` | registry role rows |
| `efs/execution-set/1` | design §8.1 | includes the revision ordinal |
| `efs/family/<name>/1` | thirteen names of design §10.2 | vectored under `families` |

Pending vectors (added with the unit that defines them): the EIP-712 `Intent` typehash and domain
(`name = "EFS", version = "1"`, S2), the declaration domain (`"EFS Type Declaration"`, `"1"`), the
callback profile id (`efs/index-callback/4:…`), the hot-ABI id (`efs/ledger-hot/2`), the store ABI
ids, the status vocabulary id (`efs/status-vocabulary/1`, `src/interfaces/Results.sol`).

## Layout

`Layout.LAYOUT_ID` (see [STORAGE.md](STORAGE.md)); the byte-aligned widths; the twenty-five-word
revision row; the transient lock word.

## Codec and limits that enter validity

- Codec-1 descriptors: 134 ≤ length ≤ 4,096 bytes (`ClosureConstants.DESCRIPTOR_MAX`); header
  offsets of design §9.2.
- `ACCEPTOR_GAS_DEFAULT = 300,000` (the declared minimum when a descriptor says 0) and
  `WALLET_GAS_FLOOR = 300,000` are closure constants, never Realm fields: a Realm limit may not enter
  validity (design §9.5 ii).
- `Retention` is numbered `1 LOG_ONLY, 2 STATE` (design §4.2).
- Action kinds 1–7; 8/9 reserved for stage-then-commit.

## Identity-bearing ids and ABI ids fixed by the first persistent registration or activation

| Id | Value | Where |
| --- | --- | --- |
| Type declaration domain | EIP-712 `(name = "EFS Type Declaration", version = "1")`, no chain id, no verifying contract; struct `TypeDeclaration(bytes32 typeId)` | `TypeRegistry.declarationDigest`; inside every relayed declaration |
| Custom binding | struct `TypeBinding(bytes32 bindingId)` under the same domain; `bindingId = keccak(abi.encode("efs/described-binding/1", wrapperCodehash, chainid, registry, typeId, custom, customHash, customAbi = 1, key))` | `TypeRegistry.bindingDigest` |
| NATIVE instance | `CREATE2(0x4e59b44847b379578588920cA78FbF26c0B4956C, salt 0, header.ruleInitcodeHash)` | `TypeRegistry.predictInstance` |
| Descriptor blob | runtime `0x00 ‖ descriptor ‖ declarationSig`, SSTORE2 prologue, salt 0 | `DescriptorStore.predict` |
| Codec | `efs/described/1`: 134-byte header, 164-byte field rows, refTypes sentinels 0 ANY / 1 SELF / ≥ 2^16 exact | `DescribedCodec` |
| Hot ABI id | `HOT_ABI_ID` of the ledger implementation: the ABI id (design §5.3: `keccak(name ‖ per function by selector: selector ‖ keccak(output tuple))`, `tools/abi-id.mjs`) of `ILedgerHot` under `efs/ledger-hot/2` (release) or `efs/ledger-hot/2:test` (suites) | readiness tuple, units, the deploy plan; `pnpm abi:check` |
| Store ABI ids | the same rule over `IPostingStore` under `efs/posting-store/2` (step 3b amended: `retain` and the UNCOUNTED append tag) and `IBitmapStore` under `efs/bitmap-store/2` (`openCoverage` also accepts the live generation while idle) | `storeAbiId()`; `pnpm abi:check` |
| Index profiles | physical `keccak("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head")`, callback `keccak("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs")`, manifest header `keccak("efs/index-manifest/2")` (the manifest hash also folds the reads contract's address and codehash) | `RealmIndex` constants; inside `MANIFEST_HASH` |
| Family ids | `keccak("efs/family/<name>/1")`, thirteen names | `Keys.familyId` |
| Purposes | `keccak("efs/purpose/{head,folder,tag}/1")` | `Purpose` (Actions.sol) |
| Notice kinds | `keccak("efs/notice/{frozen,successor,migration}/1")`; body `abi.encode(kind, uint256 revision, bytes note)` | `ClosureConstants`; the freeze canary |
| Files revision form | word after the fixed words of `files-root/1`/`files-child/1`: 0 inline bytes, 1 a content descriptor id | `docs/LARGE-FILES.md` |
| Span tree | `files-span/1` body `[left, right, length]`; canonical chunking `efs/chunking/1` (8,160-byte payloads; left subtree = largest power of two below n) is an SDK convention, not enforced | `FilesSpanRule`, `EfsFiles.chunk` |
| External locator | any RFC 3986 URI, 1..2,048 printable ASCII bytes; no scheme allowlist | `FilesExternalContentRule` |
| Error catalog | selectors and argument shapes in `test/snapshots/abi/Errors.json`; reason codes in the catalog comments | `abi:check` |

## Deadlines

- **Q1 (structural `ruleId`)** closes at the first grade-1/2 Type registered on a persistent Realm
  (S3 tag tokens are grade 1).
- The `Intent` typehash freezes at S2; the second half of Q5 (per-intent retention opt-in) must be
  decided before it.
- `IAcceptor/2` and `ILedgerHot` freeze before the first Files Type is registered (S1b).
