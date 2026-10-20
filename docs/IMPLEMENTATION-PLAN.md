# Implementation plan

How `docs/DESIGN.md` gets built, in what order, and what each checkpoint must show. The design's §17 names the stages (S0–S5) and checkpoints (C0–C5); this plan slices S0, S1 and S1b into the order the contracts engineer builds them, because the first measurements decide the rest. Nothing here changes the design; where the two disagree, the design wins and this plan is wrong.

## Rules that apply to every slice

- **Test first, then the contract, then the measurement.** Every slice starts from a failing Foundry test (a ported prototype canary where one exists, named in design §16) and ends with `forge test`, `pnpm check`, `forge fmt --check` and `forge build --sizes` green on the branch, in one commit per slice.
- **Nothing lands in the kernel that can live elsewhere.** Every PR that touches `src/core/` prints its attribution delta (`node tools/attrib.mjs ... --diff`) in the commit message.
- **Measure before deciding.** Every "C1 decides" item in the design has a pre-stated rule; the measurement is taken as soon as the unit compiles with its full ABI, not at the end of the stage.
- **Bounded tool runs.** `forge`, `solc` and `anvil` run under a watchdog (`perl -e 'alarm N; exec @ARGV' ...`) and the run ends with `pgrep -x forge`, `pgrep -x solc`, `pgrep -x anvil` printing nothing that this session started.
- **No pushes, deployments, settings changes or vault commits** without saying so; the planning vault is published by Codex.

## S0 — foundation (target: two to three days)

| Slice | Builds | Done when |
|---|---|---|
| S0.1 closure | `src/interfaces/*.sol` (every interface of design §5 as declared there, including the kernel-internal ones of §5.15 outside the closure), `src/lib/{Actions,Results,Errors,Limits}.sol`; `tools/abi-snapshot.mjs` writing `test/snapshots/abi/*.json` (selectors, errors, events, struct layouts) and failing on an unreviewed change | the closure compiles at `0.8.27` and `0.8.37`, with and without via-IR; the snapshot is committed; `pnpm check` enforces the closure's import ban |
| S0.2 code pins | `src/lib/{CodePins,CodeScan}.sol` + `test/unit/CodeScan.t.sol`: real-code and designator checks; the plain-runtime scan that skips push data and the CBOR trailer named by the last two bytes; refusals for `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE`, `CREATE2`, ERC-1967 and EIP-1167 shapes; fuzz: forbidden bytes inside push data pass, a real forbidden opcode fails | tests green; the scan's gas on a 20 KB runtime is recorded in the test log |
| S0.3 storage and layout | `src/core/storage/*.sol` (abstract ERC-7201 storage contracts for the realm, counters, records, subjects, admissions, publications, bindings, principals, revisions, transient lock; the registry namespaces; the store and generation namespaces), `forge inspect storageLayout` and `transientStorageLayout` snapshots under `test/snapshots/layout/`, `tools/layout.mjs` generating `src/core/layout/Layout.sol` (roots, slot derivations, packers and unpackers for every packed word of design §4.3–§4.6) and `vectors/layout.json`; `test/unit/Layout.t.sol` parity (every accessor against `vm.load`/`vm.store` on a populated fixture; every packed field at its max width) | parity green; `layoutId` computed and vectored; the `checks.mjs` path allowlist lets only `core/`, `control/`, `index/` and the two facets import `Layout` |
| S0.4 gates | `tools/checks.mjs` additions: the `Layout` allowlist, the `extsload` ban in `profiles/` and consumer readers, the ingress opcode lint over the built artifact, the empty-`immutableReferences` gate for `profiles/`, the write-once-facts lint for final hooks; `test/size/Budgets.t.sol` reading `test/snapshots/sizes.json` (runtime and initcode-with-arguments per deployable with its budget) | all gates runnable on an empty `src/core/`; budgets file committed with the design's §15 numbers as placeholders marked `estimate` |
| S0.5 harness | `test/harness/{EfsTest,StateDigest,ZeroWrite}.sol`, the deployer library the tests and tools share (`src/control/deploy/` or `test/harness/Deploy.sol`, decided by whether the fixture CLI needs it on chain), the prototype doubles ported to `test/harness/` as the slices that use them arrive | `EfsTest` deploys a stub kernel through the deployer; `StateDigest` hashes every `Layout` row kind; `ZeroWrite` catches an `SSTORE`/`TSTORE`/`CREATE` in a delegate under `vm.startStateDiffRecording` |
| S0.6 documents | `docs/ONE-WAY-DOORS.md` (every domain string, preimage, family name, layout id, hot-ABI id, codec cap and the Q1 deadline, each with a golden vector), `docs/STORAGE.md` (incl. the reinitializer offset), `docs/EVOLUTION.md` (design §19), `docs/RECOVERY.md` (design §6.6), `SECURITY.md` (the disclosed residuals) | committed; vectors referenced exist |

**C0:** foundation CI green with every gate; `vectors/` committed; the stub-kernel error and event byte measurement recorded; Q15 answered (who implements, who owns the M1 integration).

## S1 — kernel vertical on the native lane (target: two weeks; the kernel number by day four)

| Slice | Builds | Done when |
|---|---|---|
| S1.1 kernel, apply, ingress | `src/core/{LedgerCore,LedgerApply,LedgerIngress}.sol` with the **full ABI** of design §5.2–§5.4 (both lanes decoded, the import stub, five control selectors, the Etched hot reads, every error and event), the write pipeline of §6 on the native lane, activation/freeze/transition of §8 against a stub registry and a stub index double; ported canaries first: `RecordOccurrenceBounds`, `PublicationPreparation` (retry compare first), `CoreOrderedAcceptance` with the ten index doubles, `MatchedRollback`, `CoreAcceptanceAudit`, `FoundationGuard`/`FoundationIdentity` (native parts) | canaries green; **the C1 kernel measurement taken here**: runtime and initcode of all three units under `prague`, the §3.2 ladder rule applied if over the warning line, the attribution snapshot committed |
| S1.2 registry | `src/types/{TypeRegistry,DescriptorStore,DescribedTypeRule,DescribedCodec}.sol`, grade 3 with deterministic instances first, then grades 1–2; `Falsify` F3/F4/F5, the twenty `DescribedTypeProfile` cases, the wrapper hostile-calldata suite (S14), `activatePolicy` code gates (S6) | green; registry size measured; `typeInfo`/`roleExpectation` gas per call recorded |
| S1.3 index | `src/index/{PostingStore,BitmapStore,RealmIndex,IndexBuild,IndexReplayDecoder}.sol`; the store writer gate (S18) and the order law first, then the gen-1 families of §10.2 folded from `Effect/3`, the digest specs, the floor quote of §10.4, coverage, readiness; then replay, build and backfill with both interleavings; `CoreIndexReplay`, `CoreIndexMaterialization`, `IndexConfigExpectation` ports | green; per-effect store-call cost measured (risk 3 rule: batch if > 2k per effect); live-bits bisection vs dense list measured (C1 rule) |
| S1.4 control and genesis | `src/control/{RealmController,RealmGenesis,IndexDeployer}.sol`, the deployer library finished, `deploy/plan.json` generation; the c0 tests rebuilt on `LedgerCore`; the C2 subset of the upgrade matrix; *migrate → activate → activatePolicy → freeze* through a successor; the freeze ceremony with the native canary (`realm-notice/1`) | green; activation and freeze gas recorded on both schedules |
| S1.5 facets and the consumer | `src/readers/{LedgerReads,LedgerViews}.sol`, `src/periphery/ReaderDirectory.sol`, `src/lib/EfsNative.sol`, `examples/NativeApp.sol`; `Attribution` and `NativeApp` consumer tests; `publication()` with `Effect/3` reconstruction; the recovery classifier vectors | green; cold-pin call count and `publication()` gas recorded |

**C1 (end of S1):** every unit's runtime and initcode on `prague` against the full ABI; gas and `gasStateUsed` for every §14 row on both schedules with slot counts, with `tx.gas` below and above 2^24 on `anvil --hardfork amsterdam`; the §3.2 kernel rule applied; 48-bit versus 64-bit storage decided (2,000-gas rule); the live-scope recipe decided; the floor constants and the joint envelope published in `limits`; the scan cost measured; the memory-expansion row at 64 leaves. Every outcome is a decision with its rule and number recorded in `test/snapshots/` and a one-line entry in `docs/DESIGN.md`'s next revision.

## S1b — Files on the native lane (target: one week)

| Slice | Builds | Done when |
|---|---|---|
| S1b.1 rules | the nine `profiles/` rules of design §12.1 (ported from the prototype where one exists; `files-name/2` from the naming experiment) in the isolated `runs = 1` closure, `RefuseAllPolicy`, `FilesFinalValidator`, `profiles/FilesTypes.sol` generated from the descriptors; the `immutableReferences` gate and the reproducible-build job | each rule's size and gas recorded; Type ids identical across two fixtures with different `--chain-id` and `--realm-salt` |
| S1b.2 readers | `src/readers/{LensReader,FilesPageReader}.sol`, `lib/EfsFiles.sol`, `lib/QueryAccumulator.sol`; `LensReview`, `FaultyReads` over every reader, the honesty tests of §16.2 #3 | green; directory page and 1,000-entry traversal measured |
| S1b.3 release surface | the seed (root, folder, file), `efs-fixture.mjs up/verify/down`, `release.json`, `artifacts/`, `vectors/`, `deploy/plan.json`, `efs-deployment/1`, `gas/report.json`, `schemas/` | `verify` reproduces every address, hash and `describe()` field from a clean checkout |

**C2 (= M1 acceptance):** the PM's workflow end to end through the packaged SDK in the static client (the SDK and client repositories consume the release); reload-and-recover with the retry-after-activation case; the populated-upgrade row; every §16.2 S1 cell green.

## Who builds what

The contracts engineer (Fable) designs and writes the kernel, the apply and ingress delegates, the registry, the index dispatcher and stores, the controller and genesis, and reviews every other piece before it is committed. Bounded, well-specified pieces are delegated to Opus agents against the design text and the prototype sources, one agent per disjoint file set, each returning tests green: S0.1 (closure interfaces and types), S0.2 (`CodeScan`), the storage-layout generator, the prototype doubles and canary ports, the Files rules and the readers, the fixture CLI and the release tooling. Adversarial review passes (Opus) run on every kernel-touching slice before C1 and C2.

## Order of the first days

1. S0.1 and S0.2 in parallel (delegated), S0.3 by the engineer: the storage contracts and `Layout` are the one-way doors everything else packs through.
2. S0.4–S0.6, then C0.
3. S1.1 immediately after, measured by day four of S1; the kernel number decides whether the ladder's first rung is applied before S1.2 starts.
