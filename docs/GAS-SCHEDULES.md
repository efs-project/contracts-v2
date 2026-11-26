# Gas schedules

EFS contracts are priced on **two** schedules, because the chain is changing under the design:

| Schedule | Status (verified 2026-10-13) | Fresh storage slot | Rewrite of an existing slot (cold) | Code deposit | New account |
| --- | --- | ---: | ---: | ---: | ---: |
| Prague/Osaka (Fusaka) | mainnet and Sepolia | 22,100 | 5,000 | 200 / byte | 25,000 |
| Glamsterdam (EIP-8037 + EIP-8038, with EIP-7954 and EIP-7997) | **live on Sepolia since 2026-10-06; no Hoodi or mainnet date; EIPs in Last Call** | ≈ 110,020 (97,920 state gas + 12,100) | 12,100 | 1,530 / byte state gas | 183,600 state gas |

The table is the docs copy of one machine-readable table, `tools/deploy-plan.mjs` `GAS_SCHEDULES` (mirrored for the
Solidity suites in `test/vectors/gas-schedules.json`). The Realm's floor prices are read from it (`floorFreshGas` = the
fresh slot's execution gas, `floorRewriteGas` = the cold rewrite: 22,100 / 5,000 on prague, 12,100 / 12,100 on
Glamsterdam) and checked against it: `tools/test/gas-schedules.test.mjs` checks this table, the mirror and the tool
constants, and `test/integration/FloorPrices.t.sol` checks the Solidity harness against the mirror and measures both
prices on each profile (prague 22,100 and 5,000; amsterdam 12,100 + 97,920 state gas and 12,100). A "rewrite" here is
the first write in a transaction of a slot that already holds a nonzero value, cold or read first (a later write of the
same slot in the same transaction is 100 on both schedules).

Facts from EIP-8037 that matter for the design (read from the EIP text):

- State gas is a second dimension. EIP-7825's 16,777,216 cap applies to **execution gas only**; a transaction's
  total `tx.gas` may exceed it, drawn from a state-gas reservoir, up to `TX_MAX_TOTAL_GAS_LIMIT` (2^32 − 1) and the
  block's per-dimension gas limit. An 8,192-byte inline body (≈ 28M of state gas as 256 fresh slots) is therefore
  still *sendable* after Glamsterdam, but costs about thirteen times more than today.
- **What counts against the 2^24 cap, and where state gas comes from** (re-read from the EIP pages on 2026-11-26,
  EIP-8037 in Last Call; quoted lines are the EIP's):
  - Intrinsic gas counts. It is "charged entirely in execution-gas (base transaction cost, calldata, access lists,
    …)", and the budget is `execution_gas_budget = TX_MAX_GAS_LIMIT - intrinsic_gas`. So the 21,000 and the calldata
    (16 gas per nonzero byte, 4 per zero byte) come out of the 16,777,216.
  - The EIP-7623 calldata floor is a separate condition, not a charge on top. Validity needs
    `max(intrinsic_gas, calldata_floor_gas_cost) <= TX_MAX_GAS_LIMIT`, and at the end the transaction's execution-gas
    part is at least the floor ("compared against the transaction's execution-gas portion alone"). A publication's
    execution gas is far above its floor, so the floor does not bind in practice; a planner checks "floor ≤ cap"
    once and budgets calldata at the ordinary price.
  - The reservoir is only the overflow above the execution budget: `gas_left = min(execution_gas_budget,
    tx.gas - intrinsic_gas)` and `state_gas_reservoir = (tx.gas - intrinsic_gas) - gas_left`. **A transaction whose
    `tx.gas` is at or below 2^24 has an empty reservoir**, and its state gas is drawn from ordinary gas ("When the
    reservoir is exhausted, the remainder deducts from `gas_left`"). `GAS` "returns `gas_left` only".
  - Consequences for EFS. (1) A sender must be free to set `tx.gas` ABOVE 2^24 on Glamsterdam: `tx.gas = 2^24 +
    state gas` gives the whole execution budget and pays state gas from the reservoir. Capping the gas limit at 2^24
    makes every unit of state gas eat the execution budget; a first tag on a depth-64 topic (about 3.3M execution
    and 14.4M state gas) then cannot be sent at all. The bound a planner respects is on execution gas (the cap less
    intrinsic gas), never on `tx.gas`. (2) The kernel's index reservation is quoted in execution gas and checked with
    `GAS`. With state gas funded from the reservoir that quote is exactly what the callbacks draw from `gas_left`.
    Under the cap the callbacks' state gas comes out of the same `gas_left`, which the quote does not count, so a
    transaction sent near the quote can be refused with `E_INDEX_GAS`; it is never admitted unindexed
    (`test/integration/FloorReconcile.t.sol`). (3) Foundry's amsterdam profile has no reservoir, which matches the
    chain for a transaction at or below the cap and is harsher than the chain above it; the fixture tool runs only
    osaka and prague, so the above-cap path is not confirmed by anything in this repository yet.
  - **Decision (integration owner, 2026-11-26):** the floor quote stays in execution gas and is not changed to count
    state gas. A transaction with much state gas funds it through the reservoir (`tx.gas` above 2^24); a small one
    takes its gas limit from `eth_estimateGas`, which already includes the state gas it will draw. A consumer's
    state-gas figure per shape is `gas/model.json` → `profiles.amsterdam.split.stateGas` (the same keys and formula
    as `constants`). Still open: confirming the above-cap path end to end on a chain that runs the new rules.
  - The EIP text is not consistent on one point that does not touch EFS: it says account-creation costs are no
    longer part of intrinsic gas, and elsewhere that a value transfer to a new account adds to it.
- A slot set and reset within one transaction, a reverted frame, or a failed `CREATE` produces a state-gas
  **refill**; the publication lock would be refilled, but the kernel uses transient storage for it anyway.
- Code deposit is state gas at 1,530 gas per byte: a 24 KiB implementation costs ≈ 37.8M to deploy, and every
  "data as code" carrier (descriptor blobs, read-set preimages, signature bytes, per-binding rule instances) is
  repriced 7.65× per byte plus 183,600 per account. Per 32-byte word, code is cheaper than a fresh slot above
  roughly three words (48,960 + amortized account cost versus 110,020).
- EIP-7954 raises the runtime code limit to 65,536 bytes and initcode to 131,072 bytes on chains that adopt it.
  This repository still gates every unit at 24,576 / 49,152 so the same bytes deploy on chains without 7954
  and stay affordable under 8037.

## How we measure

- Release bytes, sizes and identities come from the `prague` build. `FOUNDRY_PROFILE=amsterdam` recompiles with
  solc's experimental `amsterdam` target (`experimental = true`) and runs the same suites under the repriced
  schedule; forge-std 1.17.0 exposes `vm.lastFrameGas()` with `gasStateUsed` there (it is zero under prague).
  Those bytes are never shipped or size-gated.
- End-to-end fixture measurements can also run on **anvil 1.8.3 with `--hardfork amsterdam`** against the
  prague build and record `gasUsed` from receipts.
- The gas report in every release bundle records, per supported operation: fresh slots, rewritten slots,
  cleared slots, code bytes deployed and accounts created, so either schedule can be applied without
  re-measuring. "Within ±10k of the prototype" statements are meaningless as Glamsterdam statements.

## Baselines carried from the prototype (today's schedule, receipts)

| Operation (prototype, lab-b at `4fbea63a`) | Receipt gas | Fresh slots | Estimated under 8037/8038 |
| --- | ---: | ---: | ---: |
| Named inline file create (5 leaves, guarded 2×1, Files index) | 2,169,867 | 56 | ≈ 7.9M |
| Edit (publish child + head rebind) | 1,327,787 | 29 | ≈ 4.6M |
| Rename (publish name + mask + bind) | 1,535,870 | 35 | ≈ 5.5M |
| Mask one placement | 869,189 | 16 | ≈ 2.9M |
| Fresh 64×4 guarded read set (carrier 10,593 B) | 5,539,847 | 17 + carrier | ≈ 21M |

Source: the 2026-10-13 slot accounting (follow-up 6 of the design analysis), derived from the prototype sources
and cross-checked against the retained known-key classification of the create and the 64×4 fresh-versus-dedup
delta (−0.4%).

## Measured on 2026-10-20 (first-time writes; `forge test`, default profile = prague, `--profile amsterdam` = EIP-8037/8038 regular + state gas)

Whole `execute` calls measured from the caller in `test/integration/FilesRecipes.t.sol` against the kernel, the real registry and the real generation-1 index with `FilesFinalValidator` pinned. First-time writes (fresh folder scopes, fresh postings), so 5–17 % over the §14 steady-state estimates.

| Step | prague | amsterdam | §14 estimate (today / Glamsterdam) |
| --- | ---: | ---: | --- |
| Root seed (CREATE + PUBLISH files-directory/1) | 769,256 | 2,710,108 | — |
| Create folder | 1,391,205 | 4,864,205 | ≈ 1.2M / ≈ 4.0M |
| Create file | 1,669,939 | 5,854,065 | ≈ 1.5M / ≈ 5.4M |
| Edit (files-child/1 + HEAD CAS) | 890,351 | 2,801,025 | ≈ 0.76M / ≈ 2.45M |
| Rename + move (UNBIND + BIND) | 1,079,612 | 3,378,054 | ≈ 1.0M / ≈ 3.2M |
| Remove (UNBIND) | 445,671 | 1,197,698 | ≈ 0.38M / ≈ 1.07M |
| Restore (BIND) | 487,069 | 1,253,629 | ≈ 0.40M / ≈ 1.18M |
| Release | 428,836 | 1,100,176 | ≈ 0.38M / ≈ 1.07M |
| Bytes + content + empty sentinel + external | 1,859,163 | 6,636,253 | — |

`files-name/2` validation: 3,400 gas for a 10-byte name, 43,580 for 255 ASCII bytes, 113,077 for 255 bytes of CJK. `FilesFinalValidator`: ≈ 5.3k gas per additional FOLDER bind. `LedgerViews.publication()`: 118k–225k gas per call. The C1 closure rewrites design §14 with these rows and adds `gasStateUsed` and the two sides of 2^24.

## Measured on 2026-11-25 (the single release: a folder is its creator's record; remove releases)

The GasModel fixture (`test/integration/GasModel.t.sol` setUp: every account cooled before the measured `execute`, a
principal that has written before, a steady folder scope), `gasleft()` delta around `execute`; main `49e606c`
against this change. Create folder is `PUBLISH(files-directory/1, (creator, salt))`, `PUBLISH(files-name/2)`,
`BIND(FOLDER)` (main: the same after a `CREATE`); "per extra" is `(x8 − x1) / 7` folders in one publication.

| Step | prague main → now | amsterdam main → now |
| --- | ---: | ---: |
| Create folder, alone | 1,284,071 → 1,207,295 (−6.0 %) | 4,191,743 → 3,938,927 (−6.0 %) |
| Create folder, per extra in one publication | 877,027 → 795,678 (−9.3 %) | 3,101,702 → 2,844,338 (−8.3 %) |
| Remove (main: UNBIND; now: RELEASE) | 449,707 → 449,898 | 1,201,721 → 1,201,924 |
| Hide (UNBIND, new recipe) | — → 449,707 | — → 1,201,733 |
| Rename + move (main: UNBIND + BIND; now: RELEASE + BIND) | 1,080,214 → 1,080,393 | 3,371,522 → 3,371,725 |

RELEASE and UNBIND write the same slots; RELEASE measures about 190 gas more. The recipe rows of `gas/report.json` carry the same operations as `FilesRecipes.t.sol` runs them.
