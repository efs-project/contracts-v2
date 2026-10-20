# Evolution ledger → proving tests (design §19, `docs/EVOLUTION.md`)

One row per change class. `proven` cites the test that exercises the mechanism end to end on the real
contracts; `partial` says what is still missing; `later` names the slice that will prove it.

| Row | Change class | Proving test(s) | Status |
| --- | --- | --- | --- |
| E1 | New lane or verifier suite | — (the signed lane and the import stub are S2) | later (S2) |
| E2 | New descriptor codec or wrapper build | `test/unit/registry/TypeRegistry.t.sol::testStructuralGradeNeedsAnActivatedWrapper` (two wrapper versions; the old Type keeps its pinned wrapper), `::testActivateWrapperReadsTheWrappersOwnConstants` | proven |
| E3 | New developer predicate semantics | `test/integration/RealRegistry.t.sol::testPolicyActivationRefusesThenSunsets`, `test/integration/FilesRecipes.t.sol::test_refuse_all_sunsets_a_type_with_the_nonce_intact` (`RefuseAllPolicy` on the old Type, nonce intact) | proven |
| E4 | New index family or physical layout | `test/index/Replay.t.sol::testReplayRebuildsEveryFamilyAndTheGenerationActivates` (a new generation with fresh stores created by `IndexDeployer`, caught up by replay, activated, live), `test/index/IndexDeployer.t.sol::testRePinnedStoresAreReusedAndThePlanIsPinned` (re-pinned stores) | partial: `build()` of a later APPEND family and per-scope `backfill()` of a later BITMAP family are not built (generation 1 declares none; Q34) |
| E5 | New action kind | — (kinds 8/9 reserved behind capability b9) | later |
| E6 | New reader or Lens algorithm | `test/periphery/ReaderDirectory.t.sol` (listing, never in the execution set); `test/readers/Facets.t.sol` (facets outside the execution set); readers resolve the live index per call: `LensReader`/`FilesPageReader` suites | partial until S1b.2 lands |
| E7 | New profile | `test/integration/FilesRecipes.t.sol` (Types + the `FilesFinalValidator` unit pinned in the manifest + the recipes) | proven for Files |
| E8 | Larger bodies and carriers | — (`carrierKind` reserved; b6) | later |
| E9 | Multichain portability of ids | `test/profiles/FilesTypes.t.sol` (identical Type ids on two Realms with different chain ids), `test/unit/registry/TypeRegistry.t.sol::testDeclarationSignatureLaw` (the declaration verifies under another chain id), `test/unit/registry/DescribedTypeRuleCustom.t.sol` (two Realms) | proven |
| E10 | Privacy profiles | — | later |
| E11 | Chain fork or renumbering | `test/control/Activation.t.sol` (an `acceptedChainId` change is an activation with flag b2 and a recomputed domain separator) | proven |
| E12 | Counter widths beyond 48 bits | — (`PREDECESSOR_LAYOUT_ID = 0`; a layout revision is a future kernel build) | later |
| E13 | Controller, controller code or owner change | `test/control/RealmController.t.sol::testOwnerChangeIsAnActivation`, `::testMigrateThenActivateThenPolicyThenFreezeThroughTheSuccessor` | proven |
| E14 | Freeze | `test/control/RealmController.t.sol::testMigrateThenActivateThenPolicyThenFreezeThroughTheSuccessor`, `::testFreezePrechecksAndCanary`, `test/control/Freeze.t.sol` | proven |
| E15 | Gas repricing | `test/control/Activation.t.sol` (a limits change is an activation with flag b7); `forge test --profile amsterdam` runs every recipe under EIP-8037/8038 pricing (`docs/GAS-SCHEDULES.md`) | partial: "after the freeze, satisfied by `tx.gas`" is not a named test |
| E16 | Hot read additions | `test/control/Activation.t.sol` (unit `hotAbiId` membership, `E_HOT_ABI`) | partial: a second implementation with a grown `SUPPORTED_HOT_ABI_IDS` is not built |

Kernel-level upgrade behaviour (the PM's fifth difficult behaviour) is `test/upgrade/PopulatedUpgrade.t.sol`
and `test/control/Activation.t.sol`; the security register is mapped in `test/security/README.md`.
