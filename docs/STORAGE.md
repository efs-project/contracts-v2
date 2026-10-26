# Storage

How the contracts lay out state, what is fixed forever, and how to change it. The design is
[DESIGN.md](DESIGN.md) §4; this note records what the implementation does with it.

## Namespaces

Every table is an ERC-7201 namespaced struct declared in an abstract storage contract that the
implementation inherits, so `@openzeppelin/upgrades-core` validates it across upgrades:

| Contract | Namespaces (`efs.<unit>.v2.<table>`) |
| --- | --- |
| `src/core/storage/LedgerStorage.sol` | `ledger.realm`, `ledger.counters`, `ledger.records`, `ledger.subjects`, `ledger.admissions`, `ledger.publications`, `ledger.bindings`, `ledger.principals`, `ledger.revisions`; reserved `ledger.source` (S4) and `ledger.staging` (stage-then-commit); the transient `ledger.lock` |
| `src/types/storage/RegistryStorage.sol` | `registry.types`, `registry.declarations`, `registry.policy`, `registry.roles`, `registry.bindings`, `registry.wrappers`, `registry.catalog`, `registry.control` |
| `src/index/storage/StoreStorage.sol` | `index.store.posting` (`PostingStore`), `index.store.bitmap` (`BitmapStore`) |
| `src/index/storage/GenerationStorage.sol` | `index.gen` (one per generation, in its own context) |

Root = `keccak256(abi.encode(uint256(keccak256(id)) − 1)) & ~0xff`; `test/unit/StorageRoots.t.sol` asserts
every constant against the formula and that no two roots collide.

## Packing

Fields are typed with **byte-aligned widths** and the compiler packs each word; nothing in the
contracts shifts or masks a storage word by hand. Where the design's §4.3 drew a sub-byte field
(`kind u4`, `withdrawn u1`, `frozen u1`, `proofKind u4`, `principalKind u4`) the implementation uses
`uint8`, and the reserved bits shrink accordingly; the design's byte offsets are otherwise the
compiler's. Widths: 48-bit admission, record, binding and publication ordinals and counters in storage
(`uint64` in every ABI; saturation threshold 2^48 − 64), 32-bit revisions, 48-bit block numbers in the
transition word, 64-bit chain ids and deadlines, 40-bit timestamps.

The realm namespace lands on the design's eighteen slots (identity +0..+2, control +3, authority +4,
registry +5, index +6, executionSet +7, layoutId +8, domainSeparator +9, indexObligations +10, steward
+11, limitsProfileId +12, limits +13..+14, transition +15, readerDirectory +16, noticePrincipal +17); a
revision row is twenty-five words; an admission row is two; a head row two (meta, target); an
evidence cell thirteen, written sparsely (five words for a native publication).

The transient lock is one word at the `ledger.lock` root: `phase u8@0 | stagedPublication u48@8 |
admissionFrontier u48@56 | mutationsSnapshot u48@104`, packed by `LedgerStorage._packLock`.

## The generated `Layout`

`src/core/layout/Layout.sol`, `vectors/layout.json` and `test/snapshots/layout/*.json` are
**generated** by `pnpm layout` from the compiler's storage layout of the probes in
`test/harness/LayoutProbe.sol`; `pnpm layout:check` runs in CI. The library carries every root,
member slot, mapping and array derivation and one unpacker per packed word. Readers that have only
raw slots (the two facets, the replay decoder, `StateDigest`, the SDK twin) go through it; the
kernel, the delegates, the registry and the stores read their typed structs directly. Only `core/`,
`control/`, `index/` and the two facets may import it (`tools/checks.mjs`).

`Layout.LAYOUT_ID = keccak256("efs2/ledger-layout/1" ‖ canonical JSON of the ledger section of
vectors/layout.json)` is the implementation's `LAYOUT_ID` immutable, a realm word and a revision-row
field (design §4.1). `test/unit/Layout.t.sol` pins the current value; a change means a one-way door
moved and must be deliberate: a layout change before genesis re-versions the id, a layout change
after genesis is an additive upgrade with `PREDECESSOR_LAYOUT_ID` and a second replay decoder.

## Initializer versions

OpenZeppelin's `initializer` sets `_initialized = 1` and `reinitializer(v)` requires `_initialized < v`,
so revision `n` of either proxied contract runs under initializer version `n + 1`; the genesis test
asserts `_getInitializedVersion() == revision + 1`.

## Changing storage

1. Edit the storage contract; keep fields byte-aligned and append within a struct, never reorder.
2. Run `pnpm layout`, read the diff of `vectors/layout.json`, commit the three generated outputs
   together with the change.
3. Update the `LAYOUT_ID` pin in `test/unit/Layout.t.sol` and this note's slot counts if they moved.
4. Before genesis that is all; after genesis the change is an activation with a layout id and a
   decoder of its own (design §8.3 step 5d, §19 E12).
