# Evolution ledger

Maintained copy of [DESIGN.md](DESIGN.md) §19: every class of change the contracts are expected to absorb, the mechanism that absorbs it, and whether it touches the kernel ABI, the layout or old rows. One test per row lives in `test/evolution/` (added with the stage that enables the row).

| # | Change class | Mechanism | Kernel ABI? | Layout? | Old rows re-read? | Who, before / after freeze |
|---|---|---|---|---|---|---|
| E1 | New lane or verifier suite | new `LedgerIngress` build + capability bit + activation; evidence rows carry `proofKind`/`verifierProfile` | no (import's selector exists from S1 as a stub) | no | no | controller / frozen (or steward B) |
| E2 | New descriptor codec or wrapper build | `codecVersion` and `ruleCodehash` in the header; `activateWrapper` appends; old Types keep their pinned wrapper | no | no | no | permissionless registration; controller activation |
| E3 | New developer predicate semantics | new Type; `RefuseAllPolicy` on the old; supersession evidence | no | no | no | anyone / controller |
| E4 | New index family or physical layout | new generation re-pinning the stores and adding a fresh store per new family set (created with it by `IndexDeployer`); APPEND families built ascending into it before attachment; BITMAP families hooked at declaration with per-scope backfill by `liveSemantics`; never a re-materialization of untouched families | no | no | no | controller / steward |
| E5 | New action kind (incl. stage-then-commit) | kernel upgrade + new callback profile + new generation; kinds 8/9 and `efs.ledger.v2.staging` reserved | implementation, not selector | no | no | controller / frozen |
| E6 | New reader or Lens algorithm | immutable contracts over the facets; listed in `ReaderDirectory`; never in the execution set; readers resolve the live index per call | no | no | no | anyone, before and after freeze |
| E7 | New profile (tags, lists, homes) | Types + a unit (new generation only if families change) + readers | no | no | no | anyone / controller |
| E8 | Larger bodies and carriers | `carrierKind`; `limits.maxBody`; `BodyStore` behind b6 | no | no | no | controller |
| E9 | Multichain portability of ids | `Keys` chain-free except the origin-qualified contract principal; NATIVE rule instances at the same address on every chain | no | no | no | one-way door |
| E10 | Privacy profiles | opaque roles and bodies | no | no | no | anyone |
| E11 | Chain fork or renumbering | `acceptedChainId` by activation; domain separator recomputed | no | no | no | controller; frozen = read-only on a fork |
| E12 | Counter widths beyond 48 bits | layout revision; `layoutId` re-versioned; `PREDECESSOR_LAYOUT_ID`; decoder per layout; hot ABI unchanged (`uint64`) | no | yes | no | controller / impossible after freeze |
| E13 | Controller, controller code or owner change | activation (`migrate`, `acceptOwnershipAndActivate`) | no | no | no | owner |
| E14 | Freeze | terminal activation + canary + renounce; steward optional | no | no | no | owner, once |
| E15 | Gas repricing | floors re-tuned by a limits activation before freeze; after freeze, satisfied by `tx.gas` | no | no | no | controller / nobody needed |
| E16 | Hot read additions | a new `HOT_ABI_ID`; `SUPPORTED_HOT_ABI_IDS` grows by one and never shrinks; existing selectors and layouts never change | additive | no | no | controller |

---
