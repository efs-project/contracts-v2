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

## Deadlines

- **Q1 (structural `ruleId`)** closes at the first grade-1/2 Type registered on a persistent Realm
  (S3 tag tokens are grade 1).
- The `Intent` typehash freezes at S2; the second half of Q5 (per-intent retention opt-in) must be
  decided before it.
- `IAcceptor/2` and `ILedgerHot` freeze before the first Files Type is registered (S1b).
