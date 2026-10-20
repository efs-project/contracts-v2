# One-way doors

Values that enter permanent identities. Each is a string, a preimage or a width that a running Realm
can never change without re-identifying data. Every entry has a golden vector produced by an
implementation independent of Solidity (`tools/vectors.mjs`, viem) and a test that pins it.

## Identity domains (`src/lib/Keys.sol`; vectors `test/vectors/ids.json`; test `test/unit/Keys.t.sol`)

| Domain | Derivation | Note |
| --- | --- | --- |
| `efs2/record/1` | `keccak(DOM, typeId, keccak(body))` | prototype-verbatim |
| `efs2/subject/1` | `keccak(DOM, creatorPrincipal, salt)` | prototype-verbatim |
| `efs2/position/1` | `keccak(DOM, purpose, subject, role)` | prototype-verbatim |
| `efs2/binding/1` | `keccak(DOM, principalId, position)` | prototype-verbatim |
| `efs2/vk/binding-scope/1` | `keccak(DOM, principalId, purpose, subject)` | prototype-verbatim; the `ScopeKey` |
| `efs2/pk/1` | `keccak(DOM, typeId, uint256(kind), uint256(ordinal), value)` | prototype-verbatim; posting keys |
| `efs2/principal/1` | key principal = left-padded address; contract principal = `keccak(DOM, 2, realmOrigin, address)` | prototype-verbatim; `principalFor` recognizes only the exact 23-byte `ef0100` designator as a key |
| `efs2/type/1` | `keccak(DOM, shape, keccak(abi.encode(refTypes)), ruleId)` | prototype-verbatim; `ruleId` = the codehash named in the descriptor header (Q1) |
| `efs2/vk/role-scope/1` | `keccak(DOM, principalId, purpose, role)` | **new**: index family 16 key |
| `efs2/realm-origin/1` | `keccak(DOM, genesisChainId, coreAddress, realmSalt)` | **changed from the prototype** (adds `realmSalt`); Q13 |
| `efs2/realm/1` | `keccak(DOM, realmOrigin, genesisExecutionProfileId)` | new |
| `efs2/publication/1` | `keccak(DOM, principalId, intentDigest)` | the prototype's format-2 shape under a new domain; emitted, never stored |
| `efs2/native-intent/1` | `keccak(DOM, realmId, principalId, nonce, deadline, expectedExecutionSet, expectedAcceptanceProfile, guardHash, actionsHash)` | the native retry key; pure over caller inputs |
| `efs2/signed-intent/1` | `keccak(DOM, hashStruct(intent), actionsHash)` | the signed retry key, chain-free |
| `efs2/acceptance-profile/1` | fold seed `keccak(DOM, executionSet)` per design §6.2 | |
| `efs2/described-shape/1` | `keccak(DOM, descriptorBytes)` | |
| `efs2/role-key/1` | `keccak(DOM, purpose, role)` | registry role rows |
| `efs2/execution-set/1` | design §8.1 | includes the revision ordinal |
| `efs2/family/<name>/1` | thirteen names of design §10.2 | vectored under `families` |

Pending vectors (added with the unit that defines them): the EIP-712 `Intent` typehash and domain
(`name = "EFS", version = "2"`, S2), the declaration domain (`"EFS Type Declaration"`, `"1"`), the
callback profile id (`efs2/index-callback/3:…`), the hot-ABI id (`efs2/ledger-hot/1`), the store ABI
ids, the status vocabulary id (`efs2/status-vocabulary/1`, `src/interfaces/Results.sol`).

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
| Custom binding | struct `TypeBinding(bytes32 bindingId)` under the same domain; `bindingId = keccak(abi.encode("efs2/described-binding/1", wrapperCodehash, chainid, registry, typeId, custom, customHash, customAbi = 1, key))` | `TypeRegistry.bindingDigest` |
| NATIVE instance | `CREATE2(0x4e59b44847b379578588920cA78FbF26c0B4956C, salt 0, header.ruleInitcodeHash)` | `TypeRegistry.predictInstance` |
| Descriptor blob | runtime `0x00 ‖ descriptor ‖ declarationSig`, SSTORE2 prologue, salt 0 | `DescriptorStore.predict` |
| Codec | `efs2/described/1`: 134-byte header, 164-byte field rows, refTypes sentinels 0 ANY / 1 SELF / ≥ 2^16 exact | `DescribedCodec` |
| Hot ABI id | `HOT_ABI_ID` of the ledger implementation: release builds `keccak("efs2/ledger-hot/1")`, test builds `keccak("efs2/ledger-hot/1:test")` | readiness tuple, units, the deploy plan |
| Store ABI ids | `keccak("efs2/posting-store/1")`, `keccak("efs2/bitmap-store/1")` | `storeAbiId()` |
| Index profiles | physical `keccak("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head")`, callback `keccak("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs")`, manifest header `keccak("efs2/index-manifest/1")` | `RealmIndex` constants; inside `MANIFEST_HASH` |
| Family ids | `keccak("efs2/family/<name>/1")`, thirteen names | `Keys.familyId` |
| Purposes | `keccak("efs2/purpose/{head,folder,tag}/1")` | `Purpose` (Actions.sol) |
| Notice kinds | `keccak("efs2/notice/{frozen,successor,migration}/1")`; body `abi.encode(kind, uint256 revision, bytes note)` | `ClosureConstants`; the freeze canary |
| Error catalog | selectors and argument shapes in `test/snapshots/abi/Errors.json`; reason codes in the catalog comments | `abi:check` |

## Deadlines

- **Q1 (structural `ruleId`)** closes at the first grade-1/2 Type registered on a persistent Realm
  (S3 tag tokens are grade 1).
- The `Intent` typehash freezes at S2; the second half of Q5 (per-intent retention opt-in) must be
  decided before it.
- `IAcceptor/2` and `ILedgerHot` freeze before the first Files Type is registered (S1b).
