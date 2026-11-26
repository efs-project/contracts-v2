# Release, deploy plan and local fixture (design slice S1b.3)

This is the release and deployment surface the SDK consumes (design §13, §8.2, §12.3 "deploy locally", "cold pin",
"root and home"). It is a **local fixture release**: it has not been reviewed or published, and the fixture key is
public. Run everything from the repository root under Node 24.21.0 (`eval "$(fnm env)" && fnm use 24.21.0`).

## Commands

```sh
# 1. the identity build (default profile: prague, via-IR, bytecode_hash = "none") and the double build with ASTs
perl -e 'alarm 600; exec @ARGV' forge build
FOUNDRY_OUT=out/release-ast FOUNDRY_CACHE_PATH=cache/release-ast perl -e 'alarm 900; exec @ARGV' forge build --ast

# 2. the release manifest, error catalog and artifacts/ (runs `forge script script/Genesis.s.sol` as a cross-check)
node tools/release.mjs

# 3. the offline genesis plan
node tools/deploy-plan.mjs            # [--chain-id 31337] [--realm-salt 0x…] [--out deploy/plan.json] [--artifacts DIR]

# 4. a fixture instance: an owned anvil, genesis, registration, seed, every verify check; then stop it
node tools/efs-fixture.mjs up --json          # prints its name, port and rpcUrl; see "The fixture" below
node tools/efs-fixture.mjs verify --name <n>  # exit 1 on any mismatch
node tools/gas-report.mjs --fixture <n>       # [--skip-amsterdam 1]; reads that instance's receipts
node tools/efs-fixture.mjs down --name <n>

# the committed sample release/efs-deployment.json + release/expected.json (default configuration only)
node tools/efs-fixture.mjs up --name sample --write-release && node tools/efs-fixture.mjs down --name sample
```

**The snapshot rule.** `release/`, `artifacts/` and `deploy/plan.json` are regenerated in the same push as any source
change (steps 1–3). `node tools/release.mjs --check 1` (`pnpm release:check`) writes nothing and fails when a committed
document is not the one the current build produces: `release/errors.json`, `artifacts/*.json` and `deploy/plan.json`
byte for byte, and `release/release.json` without the facts of the machine and the moment (`source`, `buildPlatform`,
`reproducibility`, `toolchain.foundry`, `toolchain.node`, `profiles.crossCheck`). CI runs it after the suites. With
an AST build (`out/release-ast`, locally) immutable names are read from that build; without one (CI) the names are
the committed manifest's, their offsets are checked against the build, and the fixture tests that follow read every
named immutable from a deployed instance.

`gas/report.json` is not covered by `release:check` or any digest (only `verify` validates it against its schema), so
regenerate it by hand with `pnpm gas:report -- --fixture <n>` (or `--fixture-state <journal>`) after the last step,
from a committed tree so its `measurement.dirtyFiles` is 0, whenever the kernel, the index, a Files rule, a body
layout or the fixture seed changes.

`up` copies `sha256(release/release.json)` into the deployment document and `verify` re-hashes the file, so
regenerating `release.json` after `up` makes `verify` fail until the next `up`.

pnpm scripts: `release`, `release:check`, `plan`, `fixture:up`, `fixture:verify`, `fixture:status`, `fixture:list`, `fixture:down`,
`fixture:reset`, `fixture:gc`, `fixture:snapshot`, `gas:report`, `gas:model`, `gas:model:check` and `test:tools` (the
tooling tests; pass options after `--`, e.g. `pnpm fixture:up -- --name mine --json`).

## What changes for a consumer in this release

**This release IS a re-vendor point: the list release** (items 49 to 59, against `6d11858`, the SDK's current pin).
Re-vendor `release/`, `artifacts/`, `deploy/plan.json`, `gas/model.json`, `schemas/`, `test/snapshots/abi/` (no
snapshot changed), `vectors/layout.json` (unchanged) and `test/vectors/` together, and re-pin every value of "The
identity table" below, which compares against `6d11858`. What a consumer must change, as one list:

- **Remove the interim rules when you vendor this model; keeping them double-counts.** Three end here:
  - the **"yes after a lone no" rule** (two fresh slots added by hand: the kernel's to E and K, the index's history
    word to E when the revision before is 1 or a multiple of 5). Replaced by the `bind<Purpose>AfterNo` rows and their
    tier constants (item 57), selected from the head the planner reads: a BIND on a MASKED or RELEASED head with
    `targetKind == 0` (it never bound) is `bind<Purpose>AfterNo`; both slots are in the row (its kernel slot in
    `floor.kernel`), measured at revision 1, and another position is corrected by `historyWordOpen`;
  - the SDK's **"+1 kernel rewrite in K for a FOLDER BIND on a MASKED or RELEASED head"** (`targetKind != 0`).
    Replaced by the re-measured `restoreFolder` and its tiers (and the new `restoreProperty`, `restoreHead`), measured
    restoring to a NEW target already placed elsewhere, so the kernel's rewrite is in the row and in `floor.kernel`;
  - the SDK's **"never subtract"** rule for the history word. Replaced by the symmetric correction (`laterRows.rule`,
    `tools/gas-plan.mjs` `historyWordAdds`): add `historyWordOpen` when the position opens a word and the row's
    `opensHistoryWord` is false, subtract it when the row's is true and the position opens none; without
    `revisionBefore` use the row as it is. Safe because the kernel refuses a stale `expectedRevision` for BIND, UNBIND
    and RELEASE alike (`E_CAS`, item 57).
- **New gas-model fields and constants** (item 57; `efs-gas-model/1`, all required): top-level `laterRows` (`rule`,
  `note`, `historyWordConstant`, `rows`: every later row's `revisionBefore`, `opensHistoryWord`, `target`, and a `note`
  on the new-target restore rows); per profile `maxOverErrorPercent`, `maxOverErrorComposite`, on amsterdam also
  `maxOverExecutionErrorPercent`, `maxOverExecutionErrorComposite`; per composite `laterStatements` and, on amsterdam,
  `allGasOverBoundPercent`; validation state `withinClaim`; 26 new constants (the 18 `bind<Purpose>AfterNo` rows and
  tiers, `restoreProperty` and its two tiers, `unbindHead`, `releaseHead`, `restoreHead`, `restoreTagAtHistoryWord`,
  `historyWordOpen`), each its own pair, none an anchor. **`restoreFolder` and its three tier constants changed meaning
  and value** (a restore to a new target; prague +3,081 to +3,093, amsterdam +10,293 to +10,305 of all gas, all of it
  execution and kernel share).
- **The stated maxima and their bounds** (item 57): prague `maxUnderErrorPercent` 9.68% and `maxOverErrorPercent`
  11.15%, both bounded at 15%; amsterdam `maxUnderErrorPercent` 6.63%, `maxUnderExecutionErrorPercent` **10.52%**,
  `maxOverExecutionErrorPercent` 13.89%, all bounded at 15%, and `maxOverErrorPercent` (all gas) **18.42%**, stated with
  a per-composite bound (15% + later statements × 97,920 state gas over measured). `maxAbsErrorPercent` is the larger of
  the two all-gas figures (18.42 on amsterdam). **The SDK tripwire on amsterdam's execution under-prediction fires at
  10.74%: 0.22 points to spare.** A headroom check reads the under-prediction fields as before.
- **K is low for large publications by a term in n² of the action count** (item 57; modelled at the next
  regeneration): model K against the measured kernel gas, prague / amsterdam: 16 creates with no name PUBLISH
  (64 actions) −257,968 (−2.70%) / −258,724 (−3.76%) at removed names, −255,992 (−2.22%) / −256,784 (−3.34%) at fresh
  names; 25 moves with no name PUBLISH −184,567 (−4.20%) / −184,467 (−4.46%) into removed names, −182,831 (−2.44%) /
  −182,431 (−3.40%) to fresh names; 12 creates with the name PUBLISH (60 actions) −278,042 (−3.28%) / −278,874 (−4.43%)
  at removed names. V is low by the same term. The exposure: a batch planned at the edge of the cap may be refused at
  send-time as over the cap and re-split; it is never sent short. E carries the same term inside its stated
  under-prediction figures. `FloorPlan.t.sol` executes every planned shape's largest batch for real on both schedules,
  which is the guard (item 51).
- **Worst-case rows** (item 57): every restore and yes-after-no row prices its target's backlink word opening, which a
  planner cannot see; elsewhere it over-prices by one slot (prague 17,073; amsterdam 97,920 of state gas). The worst
  over-statement of a total for these shapes is about 1.18× of amsterdam all gas.
- **Everyone's versions of a file** (item 49): read `head-authors` (family kind 22) with the generic posting reads and
  `LedgerViews.authorHeads`; a client answers UNKNOWN unless coverage is COMPLETE, counts versions with `live`, reads
  the order as first statements, and labels non-lens authors public.
- **Work-model values** (item 50): the later row `30, 50, 78,000`; the HEAD surcharge (`surchargePurpose` HEAD) first
  `10, 10, 4,500` and later `0, 10, 10,000`. A planner that reads `floor.workModel` needs no code change; one that
  compares the surcharge purpose must use plain equality (item 52).
- **Words and names** (items 53, 54): `topic-word/1` keeps its label and changes its rule and Type id (39 ASCII
  characters; codes 3, 4, 9; 5 unused); file names are `files-name/3` (the label changed): the SDK's `checkWord` and
  name check change as items 53 and 54 say, with `test/vectors/topics.json` and the new `names.json`.
- **The gateway** (item 55): a first segment starting `0x` that is not `0x`/`0X` + 40 hex is a topic path, answered
  `501 topic paths are not served` (the gateway serves no topic pages in this release).
- **Batch sizes** (item 51): prague masks, releases and masks of masks 58 → 54, restores 51 → 48, create files 10 → 9;
  amsterdam masks, releases and masks of masks 55 → 54, restores 51 → 50; five new planned shapes; every other shape
  unchanged.
- **New and changed codes** (`release/errors.json`): `E_TOPIC_REFUSED`'s codes 3, 4 and 9 (5 unused). No ABI changed.

What did not change: the layout id, the hot and store ABI ids, every ABI, the kernel, the ledger's and every genesis
address, the realm id, the limits, every read bound, the seed (item 59).

**The previous re-vendor point, `6d11858`** (items 42 to 48; the SDK's current pin): what changed for a consumer at
that release, against `3ca53ba`, kept as it was stated then. Its interim rule for a yes after a lone no ENDS with the
list release above.

At `6d11858`: the SDK was pinned to `3ca53ba` ("Merge the final step: liveness gate, fold-hook
refusal, reader rule, Glamsterdam floor price"); that release (items 42 to 48) moved it to that bundle's head: work-model
formula 3, the Type registry rule, the kept-index fix and the gas model's list tiers, built and regenerated together.
Re-vendor `release/`, `artifacts/`, `deploy/plan.json`, `gas/model.json`, `schemas/`, `test/snapshots/abi/`,
`vectors/layout.json` and `test/vectors/` together, and re-pin every value of "The identity table" below, which compares
against `3ca53ba`. What a consumer must change, as one list:

- **The reservation formula** (item 42), for a planner that reproduces the kernel's quote (`tools/gas-plan.mjs`
  `quote()` is the reference): the work model is **32 words** (`WORK_MODEL_WORDS`, was 17; `formulaVersion` 3); each
  BIND, UNBIND or RELEASE adds **one of three rows** by class (a first statement: the author's head UNSET; a re-bind: a
  BIND on a BOUND head; any other later statement: a mask, a release, a restore, a RELEASE always), plus **the
  per-purpose surcharge's** row of the same class when the action's purpose word equals `surchargePurpose` (zero for
  generation 1, so never today); **every WITHDRAW after the first** of a publication adds the later row; with no
  principal (`indexFloor`, an **unknown author**) every bind-kind action adds the **largest of the three rows** field by
  field, surcharge included. Generation 1's rows: first `55, 20, 44,000`, re-bind `20, 40, 42,000`, later `20, 50,
  85,000` (fresh ×10, rewrites ×10, compute).
- **The gas model's list tiers** (item 47; "The list tiers" under "The planning model" below), for the execution
  estimate E of later statements. The three-line rule: an author's entry count at the place known and at most 48 (the
  short tier) prices the first later statement at its place with `<row>NewPlace` (when the model carries it, else
  `<row>`) and any further one at that place with `<row>`; more than 48, or unknown (the long tier), prices them with
  `<row>LongNewPlace` and `<row>LongSamePlace`; a re-bind has no tier (`<row>NewPlace` first at its place, else
  `<row>`). A planner passes `firstAtPlace` (no earlier later statement of the same publication at the same (purpose,
  subject); default true) and `entries` (the author's entry count at the place; **default: unknown, the long tier**). **A
  stale count is treated as unknown** (a count lower than the truth under-prices by up to 21.2%).
- **Interim rule for a yes after a lone no** (item 42; **ENDED by the list release: remove it**, item 57). A planner
  tells the shape from the head it already reads: **`state != UNSET && targetKind == 0`** is a head that never bound
  (`Head.targetKind` is served as stored, `src/interfaces/Views.sol`; `target` is canonical and is 0 for every masked
  or released head, so it cannot tell a lone no from a masked yes). A BIND on such a head adds fresh slots at the
  schedule's price (`test/vectors/gas-schedules.json` `freshSlot`: prague 22,100; amsterdam 12,100 of execution and
  97,920 of state gas):
  - **the kernel's slot, always** (the head's stored target is written fresh): one slot to E and to the kernel's own
    share K, for a lone no, for no → release → yes and for no → no → yes alike;
  - **the index's slot, when a RESTORE opens a word of the binding's history list**: one slot to E when the head's
    revision before the BIND is 1 or a positive multiple of 5 (the binding's 2nd, 6th, 11th, 16th statement and every
    fifth after, without end: `PostingStore._append` opens a word when the list's count is 1 or a multiple of 5, and
    the history takes one append per statement of any kind). It applies to the restore rows only (`restoreTag`,
    `restoreFolder`, `restoreSame`, `restoreBroader` and their tier constants), which are measured as a binding's 3rd
    statement, where no word opens. The mask, release and re-bind rows are measured as the 2nd statement and already
    contain the fresh word (at other positions they over-price by one slot, the safe side). For a never-bound head at
    revision 1 this is the yes directly after a lone no: two slots in all.
  A planner that adds both slots for every never-bound head over-prices the later variants by one slot (the safe
  side). With the rule, the SDK's planner plans the largest batch of this shape at 46 on prague and 48 on amsterdam
  (51 without it; bounded by V once K carries the head's slot), at the formula-3 release; with the list release's
  later row `tools/gas-plan.mjs` plans it at 45 and 48 with the rule (48 and 50 without it; item 51). The rule ends
  when the vendored `gas/model.json` carries the proper rows (the list release's second piece).
- **New error and reason codes** (`release/errors.json`): `E_WORK_MODEL(uint8 code, uint256 value)` (new error: 1 the
  read failed, 2 the reply is not 32 words, 3 `formulaVersion` is not 3); `E_INDEX_NOT_READY` 15 (the index's work model
  is not 32 words of the ingress's formula) and 16 (a word does not fit its field), checked for a kept index and a new
  one; **`E_INDEX_NOT_READY(2)` now means "the ledger's own publication lock is not IDLE"** (was "the kept index's
  readiness phase is not IDLE"); `E_PIN` 13 (the index's work model could not be held as a data contract); `E_REPLAY` 10
  (a PUBLISH or REUSE record's Type: the registry's `descriptorBytes` do not hash to its Type id).
- **New and renamed gas-model fields** (`efs-gas-model/1`, all required): top-level `laterLists` (`shortTierMaxEntries`
  48, `claimEntries` 1,024, `rule`, `note`); per profile `maxUnderErrorPercent`, `maxUnderErrorComposite` and
  `maximaExcludeStates` (`["beyondClaim"]`), and on amsterdam `maxUnderExecutionErrorPercent` and
  `maxUnderExecutionErrorComposite`; `method.laterLists` and `method.maxima`; 37 new constants (item 47); new validation
  states `acrossPlaces`, `acrossPlacesBitsWord`, `longLists`, `beyondClaim`. No field was renamed; the only fields
  removed are formula 2's under `floor.workModel` (`freshPerBindFresh`, `rwPerBind`, `computePerHookEffect`), which now
  holds formula 3's 32 (the three rows, `surchargePurpose` and the surcharge rows). **A headroom check of the 2^24 cap condition reads `maxUnderErrorPercent` on prague
  and `maxUnderExecutionErrorPercent` on amsterdam** (`planning.headroomCovers` says so).
- **Batch sizes** (item 43; `test/vectors/floor-plan.json`): prague tag masks, releases and masks of masks 64 → 58, tag
  restores 60 → 51, number changes 60 → 62, folder re-binds 60 → 62; amsterdam masks, releases and masks of masks
  44 → 55, restores 41 → 51, number changes 41 → 64, folder re-binds 40 → 61, lone negatives 50 → 53; edits (not a
  FloorPlan shape) 24 → 24 and 23 → 28. Every other shape is unchanged on both schedules. A planner that reads the model
  needs no other change; one that hard-codes batch sizes does.
- **ABI snapshots that changed** (against `3ca53ba`, exactly three): `IIndexReads.json` (the `WorkModel` struct that
  `workModel()` and `manifest()` return has formula 3's 32 fields), `ILedgerIngress.json` (new `formulaVersion()`,
  selector `0x70a3985b`, which activation reads), `Errors.json` (new `E_WORK_MODEL`, selector `0xc8be0e1a`).

What did not change: the layout id, the hot ABI ids (release and test), both store ABI ids, the status vocabulary id,
the limits profile id, every Type id, every reader's ABI (and every action, write and read ABI other than the three
snapshots above), the apply delegate, the registry implementation, `ledgerReads`, `ledgerViews`, `readerDirectory`,
`keysView`, every Files and Topics rule and the validator, the seed (`efs-fixture-seed/4`, root `0xf7547aa6…c037`), and
every read bound and recommended read limit on both schedules. Every genesis address on the fixture Realm moved again
(the ingress, the control delegate and the decoder changed; the control delegate embeds the ingress's address, the ledger implementation both, and genesis the implementation's); recompute them for any
other `(chainId, realmSalt)` with `tools/deploy-plan.mjs`.

### The final step (an earlier SDK pin, `3ca53ba`, against `cbf5b78`)

What `3ca53ba` changed against `cbf5b78` (items 32 to 41), kept for a consumer still on `cbf5b78`; every value it names
is superseded by this release's identity table.

**That release was a re-vendor point.** It moved the SDK from `cbf5b78` ("Merge the reader release: frontier in
TopicPageInfo") to the final-step head, `3ca53ba` (items 32 to 41). Re-vendor `release/`, `artifacts/`,
`deploy/plan.json`, `gas/model.json`, `schemas/`, `test/snapshots/abi/`, `vectors/layout.json` and `test/vectors/`
together, and re-pin every value of its identity item (41), which compares against `cbf5b78`. What a consumer must
change:

- **ABI.** `IIndexReads` gained `liveManifestCopy()` (selector `0x1c317828`; `test/snapshots/abi/IIndexReads.json` is
  the only ABI snapshot that differs from `cbf5b78`). The hot and store ABI ids did not move (item 37).
- **Errors** (`release/errors.json`). New `E_INDEX_NOT_READY` reason 14 (the candidate's copy of the live index's
  manifest is not the recorded one) and `E_PIN` code 12 (a copy over 24,575 B); reason 12 no longer covers "the live
  index has no code"; `E_BUILD(7)` also covers a stale or wrong copy and a refused new fold-hook unit (item 37).
- **Topic readers** (item 38). A list the index reports PARTIAL is treated as UNKNOWN; every refused topic page
  carries no counts (`rawTotal`, `positionsEver` and a count view's two counts are 0). No reader ABI changed; the three
  readers' addresses did.
- **Glamsterdam floor and batch sizes** (item 39). A Glamsterdam Realm prices a rewrite at 12,100 in the floor
  (`profiles.amsterdam.floor.limits.floorRewriteGas`, was 5,000); amsterdam's largest planned batches fall for the
  rewrite-heavy shapes (lone negatives 54 → 50; masks, releases and masks of masks of tags 64 → 44; restores and number
  changes 64 → 41; folder re-binds 61 → 40; a name record and a first tag 30 → 27; edits 30 → 23). Prague's plan,
  quotes and `k` did not move. A planner that reads the model needs no code change; one that hard-codes batch sizes does.
- **Gas model** (item 40). `validation` rows gained `state` (`listsNew` | `listsExist`) and four composites; amsterdam
  rows gained `executionErrorPercent`. The stated maximum errors: prague 5.80% (`maxAbsErrorPercent`); amsterdam
  12.03% on all gas (`maxAbsErrorPercent`) and 10.62% on execution gas (`maxAbsExecutionErrorPercent`, new and
  required); each names its composite (`maxAbsErrorComposite`, `maxAbsExecutionErrorComposite`). **On amsterdam test the
  2^24 cap condition against `maxAbsExecutionErrorPercent`**, never against the all-gas figure.
- **Read bounds.** `reads.schedules.*.bounds.*.everyoneExact.maxSkippedEntries` is 247 at every lens on both schedules
  (was 248). The recommended limits (`limitEntries` 245, `maxRows` 150, `pageTimesLens` 768 / 416 / 688 / 408) did not
  move on either schedule.
- **Addresses.** Every genesis address on the fixture Realm moved (the control delegate changed, and genesis embeds
  it), with the index, its reads contract and every reader that embeds the ledger's address; recompute them for any
  other `(chainId, realmSalt)` with `tools/deploy-plan.mjs`.

What did not change: the layout id, the hot ABI ids (release and test) and both store ABI ids, the status vocabulary
id, the limits profile id, every Type id, every action, write and read ABI other than `IIndexReads`, the ingress and
apply delegates, the registry implementation, the decoder, `ledgerReads`, `ledgerViews`, `readerDirectory`,
`keysView`, every Files rule and the validator, the seed (`efs-fixture-seed/4`, root `0xf7547aa6…c037`), and
prague's floor prices and largest batches. The gas-model constants moved only with this release's code: +20 to +134
gas each on both schedules (`fixed` 315,834 → 315,854 on prague, 899,154 → 899,174 on amsterdam); no row was re-fitted
and no term was added.

### The tag release (the SDK's earlier re-vendor, against `cc59d0c`)

The SDK's single re-vendor moves it from the release it vendors now (`cc59d0c`, "Merge the folder identity fix and
the remove/move/hide recipes") to this one: the tag work of docs/TAG-DESIGN.md, built in the order of its §12 and
integrated on `fable/2026-11-25-tags-release`. Everything below is a change a consumer must make or a fact it must
re-pin; nothing else in the consumer surface moved. Re-vendor `release/`, `artifacts/`, `deploy/plan.json`,
`gas/model.json`, `schemas/`, `test/snapshots/abi/`, `vectors/layout.json` and `test/vectors/` together: the release
digest covers them.

**1. Actions and the number.** `Action.salt` is renamed `saltOrStrength` (same position, same `bytes32`; the SDK takes
field names from the vendored ABI). For CREATE it is the creator salt (nonzero), as before; for BIND and UNBIND it is
the binding's unsigned strength 0..65,535 (`BindingNumber.MAX_STRENGTH`; a larger value is refused with
`E_SHAPE(leaf, 2)`, never truncated); for every other kind, RELEASE included, it must be zero. The signed number is
derived, never stored (`BindingNumber.numberOf`): BOUND → strength (0..65,535), MASKED → −1 − strength
(−1..−65,536), UNSET and RELEASED → none. A BIND states `strength`, an UNBIND `−1 − strength`, a RELEASE nothing, so
every action written before (strength 0) keeps its meaning: a bind is 0, a mask is −1. A number change is one BIND to
the same target (positive to positive) or one more UNBIND (negative to negative), under the usual revision check.
The head row's 40-bit expiry field narrowed to 32 bits to make room; `notAfter` stays reserved and always 0.

**2. Lone negatives.** UNBIND is admitted from every state, for every purpose. From UNSET it is transition 6
FIRST_MASK: the binding ordinal, `bindingPosition` and the position cell are allocated as a first BIND allocates
them, with no target (target kind 0, target word 0, revision 1, no previous admission); from MASKED it changes a
negative number and from RELEASED it re-states one (transition 3 MASK). What it does to history reads: a binding's
history (`LedgerViews.historyAt`, family 8) can now START with a mask that has no target, so a consumer must not
assume the first entry of a history is a BIND with a target; a mask's entry keeps the previous target word only
when there was one. A first mask is a first statement: it files the first-statement lists (below) and is in no
backlink list (it has no target).

**3. Target kind ADDRESS.** A nonzero target whose top 96 bits are zero (`bytes32(uint256(uint160(addr)))`) and that
is neither a record nor a created subject is target kind 3 ADDRESS (1 RECORD, 2 SUBJECT, 0 none). `FilesFinalValidator`
admits it for TAG and refuses it for HEAD (code 7) and FOLDER (code 6). Heads (`ILedgerHot.head`, `Head`) report
`targetKind` and `strength`.

**4. Two events.** `Bound(uint64 admission, bytes32 indexed purpose, bytes32 indexed subject, bytes32 indexed role,
bytes32 target, uint8 kind, uint16 strength, uint8 transitionKind, uint8 targetKind)`: one per BIND, UNBIND or
RELEASE admission, right after its `Admitted` (join on `admission`; the author is `Admitted.principalId`); a filter on
(purpose = TAG, role = thing) finds everything said about a thing, lone negatives included. `Body(bytes32 indexed
recordId, bytes32 indexed typeId, bytes body)`: the body of a fresh record of a Type whose descriptor sets
`TYPE_FLAG_EMITS_BODY` (header byte 133 bit 0; `TypeInfo.flags`) and whose body is at most `BODY_EVENT_MAX` (256)
bytes, after the `Admitted` of the PUBLISH that first admitted it; never for a repeat publish or a REUSE. `files-name/2`
and the three Topics Types set the flag.

**5. The hot ABI and the ABI ids.** `ILedgerHot.head` returns `strength` (and the documented `targetKind`), and the
hot interface gained `bodyWord(recordId, index)` (word `index` of a stored body, zero beyond it and for a missing
record; one SLOAD; the only body read profile rules and validators may use). Every ABI id now follows one rule
(design §5.3, `tools/abi-id.mjs`): `keccak256(bytes(name) ‖ for each function sorted by selector: selector ‖
keccak256(canonical output tuple))`; events and errors are outside it. The ids, all four new against `cc59d0c`, are in
the identity table below; the hot interface's name is now `efs/ledger-hot/2` and the posting store's
`efs/posting-store/2` (it gained `retain` and the UNCOUNTED append tag).

**6. The Topics Types and `EfsTopics`.** Three new NATIVE Types, registered at genesis after the ten Files Types
(thirteen in all): `topic-word/1` (a word's page and the root-level topic `/<word>`: the word's bytes, no refs;
refusal codes 1–8, `TopicProfile.wordRefusal`), `topic/1` (a path of two or more words: exactly `[parent, wordPage]`,
64 bytes, both declared refs; the parent a `topic/1` or `topic-word/1` record) and `text/1` (a short display string,
1–255 bytes, for labels; codes 20–24). A topic's id is its record id, computable from the words alone
(`EfsTopics.wordPageId`, `childId`, `pathId`); `test/vectors/topics.json` carries the grammars' verdicts, the refused
code point table and path ids for the SDK's twin. `src/lib/EfsTopics.sol` is the consumer library: `registerWord`,
`registerPath`, `registerChild`, `tag`, `deny` (a lone negative at revision 0), `property`, `label`, `same`,
`broader`, and `propertyKey`/`labelKey`. **The three Topics Type ids are PROVISIONAL** (see the pre-freeze gates).
The named purposes are now HEAD, FOLDER, TAG, PROPERTY (`efs/purpose/property/1`), SAME (`efs/purpose/same/1`) and
BROADER (`efs/purpose/broader/1`); the kernel accepts any purpose.

**7. The validator's codes.** `FilesFinalValidator` refuses with `E_FILES_FINAL(code, leaf)`, wrapped in
`E_INDEX_CALL`; codes 1–15 are listed in `src/profiles/FilesFinalValidator.sol` and, in plain words, in
docs/TAG-DESIGN.md §2. New in this release: a folder parent may be a home (an address-shaped word, code 2), codes 6
and 7 (ADDRESS on FOLDER/HEAD), 9 (a TAG first statement's subject is neither a home nor a topic registered STRICTLY
before it, in an earlier action), 10–13 (SAME/BROADER ends), 14 (a TAG BIND's target must equal its role) and 15 (a
TAG first mask must name something that exists). A mask or release of an existing binding is never judged.

**8. Folder identity and the recipes.** A folder is a `files-directory/1` record with body `abi.encode(creator,
salt)`, admitted only by that creator (`FilesDirectoryRule`: `ctx.principalId == creator`, `salt != 0`); its id is
the record id, never a subject, so the kind of an object follows from its id. The recipes (`EfsFiles`): **remove**
and **move** RELEASE the old entry (a release never stops another author's entry from showing through the lens),
**hide** UNBINDs it (a mask stops the lens walk, so it hides everyone's entry at that name).

**9. The index lists and their keys** (design §10.2; generation 1). New first-statement families, appended only at an
author's FIRST statement on a position, either sign: 6 `place` `Keys.placeList(purpose, place)` (TAG and FOLDER;
each filing: a fresh position and every later author's first yes, so a position may repeat; `count` = filings,
`live` = distinct positions ever stated), 7 `place-below` `Keys.placeBelowList(TAG, ancestor)` (the same per proper
ancestor), 19 `scope-below` `Keys.scopeBelowList(author, TAG, ancestor)`, 20 `position-authors`
`Keys.positionAuthorsList(position)` (`count` = authors who ever stated, `live` = the yes-count, exactly the authors
whose head there is BOUND now) and 21 `role-places` `Keys.rolePlacesList(TAG, role)` (every statement reachable from
its thing). The backlink list (family 5) is now keyed by purpose, `Keys.backlinkList(purpose, target)`, and a
number-only re-bind does not touch it. The topic families are kept only when the generation's units contain the
profile validator for the same two topic Types (`IRealmIndex.topicTypes()`); the index is two contracts
(`readsContract()`; every read is answered at the generation's address).

**10. The readers and `LedgerViews`.** Three new readers, listed in the `ReaderDirectory`:
`TopicMineReader.mine` (kind `efs/reader/topic-mine/1`: a lens of authors over their own exact and roll-up lists,
newest first, the combined walk with the viewed-place check), `TopicEveryoneReader.everyone` (`efs/reader/topic-everyone/1`:
`PlaceQuery.raw` every row, otherwise a row shown when its yes-count is above zero unless a lens author denies it)
and `TopicLookupReader` (`efs/reader/topic-lookup/1`: `byName`, `about`, `placeCount`, `authorCount`, `entryCount`,
`wordPage`, `children`). Rows are de-duplicated by thing within a page and carry the `decider` (the lens index whose
statement decided the row, 255 none) and its number; a page can be short or empty and still `LIMIT`, `ROWS` or `GAS`
with a continuation. `LedgerViews` gained `headStates` (the state word alone of up to `maxReadIds` heads),
`bindingCells`, `lensRule` and `authorHeads`; `LedgerViews`, `LensReader` and `FilesPageReader` moved address with
the layout.

**11. The gateway's link grammar and answers.** The `web3://` entry point is now two contracts: `EfsWeb3Gateway` (the
address a URL names: parsing, names, lens, listings) and `EfsWeb3Content` (deploy step R5a; serves the revision the
gateway selects, by STATICCALL at the immutable `CONTENT`, codehash `CONTENT_CODEHASH` checked on every call; the
deployment document records both under `readers.web3Gateway`). The first path segment decides the kind of path:
`/0x<40 hex>/…` an address's HOME (lens default: that address's own principal; named by `x-efs-home`); `/~efs/o/<id>/…`
an object link (a `files-directory/1` record is that folder, lens default its creator; a created subject is that
file's HEAD, lens default its creator; a record of another Type 501, an id naming nothing 404); `/~efs/v/<revision id>`
a revision link (exactly that `files-root/1` or `files-child/1` record's bytes, no lens; another existing object 501);
every other `~` segment 400; anything else a topic path, 501 (no folder is ever served there). Statuses: 200, 307
external location, 400 malformed, 404 not found (an existing object is never 404), 416 offset past the end, 500 the
HEAD law's named bodies ("HEAD law: target is not a record", "target not a revision", "short revision", "revision of
other file"), 501 not served, 503 listing unsupported. The full grammar is `src/periphery/EfsWeb3Gateway.sol`'s
NatSpec and docs/LARGE-FILES.md "`web3://`".

**12. The gas model.** `gas/model.json` (and `release.json` `gasModel`) gained per schedule `floor` (the kernel's
quote inputs: `workModel`, the floor prices and `kernelTail`, per-Type `refs` and `specs`, `callGasRetained`,
`dispatchOverhead`, the kernel's own fitted share `kernel`, and the formula in prose), a top-level `planning` (the
rule: inside `planning.limits` and `max(E, V) ≤ ⌊2^24 × (100 − headroomPercent) / 100⌋`), `tagLists` (the per-level
terms `tagLevel.{mineNew,mineExisting,sharedNew,sharedExisting}`, `bindTagFresh`, `bindTagSecondAuthor`, and the
price-as-new rule `priceAsNew`) and `reads` (the topic readers' fitted terms, bounds per lens size and `recommended`
limits). `tools/gas-plan.mjs` is the reference planner (it reads only the model; `test/vectors/floor-plan.json` its
verdicts for twenty-two shapes since the list release); the SDK's planner must reproduce it.

**13. The work model in plain terms** (formula 2, `formulaVersion = 2`). The kernel reserves gas for the index's final
phase per bind-kind action (`finalComputePerBind`): it was **120,000 in the release the SDK vendors now and is
7,400**, which is what a bind's final check actually uses; the 120,000 made the floor refuse large publications that
could pay (64 lone negatives on Glamsterdam). To keep the quote above what the index spends, three terms are new:
`rwPerBindLater` (120 tenths of a slot rewrite more for every later statement: a re-bind, number change, mask,
release, restore), `freshPerPublishExisting` (29 tenths of a fresh slot for a PUBLISH of an existing record or a
REUSE) and `finalComputePerPublish` (2,800 of final-phase compute per PUBLISH or REUSE). For the largest batch per
publication this means: binds are no longer capped by the reserve (64 masks, releases or masks of masks fit in one
publication on both schedules), publish-heavy and later-statement batches are priced closer to what they spend, and
first tags on deep topics are still limited by their per-level list cost, which the gas model carries and the floor
does not (the per-shape table is docs/TAG-NUMBERS.md "The largest publication"). The deployed index's work model is
checked against the gas model field by field by the fixture (`verify`, group `pricing`).

**14. `ILedgerCommitments.indexFloor` is an upper bound only.** It quotes without a principal; since formula 3 (item
42) it prices every bind-kind action with the largest of the three rows field by field (under formula 2: as a first
statement). Plan from the gas model's rule, never from `indexFloor`.

**15. Pre-freeze gates** (none blocks a disposable testnet; each blocks freezing a Realm). One current list, as of
this release.

**Done:**

- **The build from history, steps 1 to 4** (docs/INDEX-BUILD.md, reviewed 2026-11-25). A later index generation that
  carries the stores it names can be built and activated on a Realm with history, and the kernel checks carried and
  fresh stores (`E_INDEX_NOT_READY` 12 and 13; step 1, item 23); the budgeted walk of history rebuilds generation 1's
  families, all three counters among them, into fresh stores (step 2, item 26); a new list in a further fresh store is
  built from history and equals a Realm that kept it from genesis, key by key, with the dropped-list, fold-hook and
  partial-coverage tests (step 3b, item 34; the list is a test harness, not product).
- **The as-of rule** (step 3a, item 32): a fold from history reads every fact as of the admission it folds and takes
  no fact from a validator's law (docs/INDEX-BUILD.md §4.3).
- **The liveness gate** (item 37): replacing the live index never depends on it answering; the candidate carries a copy
  of the live index's manifest, which the kernel (reason 14) and the generation check against the recorded hash.
- **The fold-hook refusal** (Option A, item 37): a generation that carries a store is refused a fold-hook unit the live
  index does not declare, unless it walks history and names the unit as built.
- **The Glamsterdam rewrite price** (item 39): a Glamsterdam Realm's floor prices a rewrite at 12,100, so the quote
  covers the callbacks' spend in every measured state on both schedules (docs/INDEX-BUILD.md §10 item 29, fixed).
- **Measured build gas** (step 4, item 36; re-measured with this release's code, docs/INDEX-BUILD.md §6): adding
  `head-authors` later to a Realm of 1,000,000 files costs 479.3B gas in 28,608 transactions on prague (479,325 a file)
  and 577.8B on amsterdam (470.1B of execution in 28,058 transactions and 107.7B of state gas), against 51,351 /
  149,890 a file to keep it from genesis (9.3× / 3.9×); a cold build call's fixed share is 0.25M to 0.28M; every
  admitted publication builds in one 2^24 call.
- **The above-cap state-gas path, confirmed on a real chain** (2026-11-26, `tools/state-gas-probe.mjs`,
  docs/GAS-SCHEDULES.md): on Sepolia, under both Geth and reth, a transaction whose gas limit is above 2^24 starts
  with the cap less intrinsic gas as ordinary gas and pays state gas from the reservoir; at or below the cap it pays
  state gas out of ordinary gas. So the floor quote staying in execution gas is right for a transaction that funds
  its state gas above the cap. A planner must not read this from plain `eth_call` (Geth relaxes the cap there).

Newly done in this release (items 42 to 47):

- **Later statements over-reserved on Glamsterdam** (item 42, work-model formula 3): a later statement's reservation
  was twelve "rewrites" that were really a compute margin, so at the Glamsterdam rewrite price (12,100) later statements
  were reserved 2.0 to 4.3 times their spend and their batches shrank. Formula 3 gives them honest slot counts and
  compute in rows of their own (a re-bind has a row that never searches the list), fitted to lists of up to 1,024
  entries per author per place; the per-purpose surcharge exists (zero for generation 1). Amsterdam's later batches
  grow (masks 44 → 55, number changes 41 → 64, item 43).
- **The released floor's shortfall on today's schedule for later statements at distinct places and in long lists**
  (item 42; a finding against the previous release, `3ca53ba`, fixed here). In that release a later statement's quote
  (formula 2: 122.0k on prague) was below its callbacks' spend when the statements were at distinct places or in long
  lists: 0.91 for a restore of entry 48 across places, 0.75 at 4,096 entries (prague,
  `test/integration/FloorSplit.t.sol`). What it meant: a later-statement publication sent near the floor could be
  refused (`E_INDEX_GAS`, nothing admitted); it could never be admitted unindexed. Prague's later batches were planned on
  that under-quote, so they are smaller now (masks 64 → 58, restores 60 → 51). Formula 3 quotes every later statement
  the floor claims at 1.05× its spend or more (lowest 1.062 on prague, 1.052 on amsterdam), except a yes after a
  lone no, found after the release: prague covers it only in lists of up to 256 entries (item 42).
- **The Type registry rule** (item 46; closed by code): a build no longer reads a Type's stored reference count; it
  proves it from the Type's descriptor, and refuses `E_REPLAY(10)` when the registry's bytes do not hash to the Type id,
  so a replacement Type registry need not keep the row. A registry that withholds a descriptor (reverts) makes a build
  refuse with its own error (docs/INDEX-BUILD.md §4.3).
- **Keeping an index that no longer answers** (item 45; closed): an activation that keeps the live index never asks its
  readiness; it reads only its work model, the read every publication makes. Reason 2 is the ledger's own lock, so a
  live index whose readiness no longer answers can still be kept while another component or the limits change; an
  index that cannot answer its work model is refused 15, because it could not serve a publication either
  (docs/INDEX-BUILD.md §5.3).
- **The gas model's later rows** (item 47, the list tiers): the model's E for masks, releases and restores was 14–24%
  low at an author's entry 48 and beyond and in lists of up to 1,024 entries, because the later rows were measured at
  one place with short lists; the list tiers bring every composite within the claim inside 15% (largest under-prediction
  9.69% on prague, 10.65% of execution gas on amsterdam), and the headroom check reads the under-prediction fields. A
  yes after a lone no has no composite and is outside those figures (item 42).

Newly done in the list release (items 49 to 59):

- **The per-purpose surcharge's use: the all-authors HEAD list** (item 49; QUESTIONS Q52, ruled by James on
  2026-11-26). Generation 1 keeps `head-authors` (family kind 22, everyone's versions of a file) from genesis, as its
  own family in the genesis posting store, with the work model still served from a data contract; the HEAD
  surcharge reserves for it with rows measured on the real code (item 50).
- **The later row made true** (item 50; ruled by the integration owner): 3.0 fresh slots, 5.0 rewrites and 78,000 of
  compute fitted by measurement, so a yes after a lone no is covered within the claim on both schedules at the floor's
  per-action margin and is no longer an exception; `src/interfaces/Index.sol`'s comment on the rows says what is now
  measured (the slot counts are the largest a statement of the class writes).
- **The planner's surcharge comparison** (item 52): `tools/gas-plan.mjs` applies the surcharge on plain equality with
  `surchargePurpose`, as the ingress does.
- **The gas model's rows for a yes after a lone no** (item 57): `bind<Purpose>AfterNo` for every purpose, with their
  tiers; the no → release → yes and no → no → yes variants, the folders (measured, not assumed) and the lone-no batches
  as composites inside the stated maxima; the interim consumer rules end.
- **The planner reads the shape by `targetKind`** (item 57): `state != UNSET && targetKind == 0` is a head that never
  bound, pinned by `test/readers/HeadTargetKind.t.sol` over five sequences; every later row states the position it was
  measured at (`laterRows`), and the symmetric history-word correction makes another position exact.
- **HEAD later rows** (item 57): `unbindHead`, `releaseHead`, `restoreHead` (to a new revision) and `bindHeadAfterNo`.
- **The `Index.sol` comment on the later row** (item 50) and **the gateway's header comment on a first segment starting
  `0x`** (item 55): both now say what the code does.

**Open:**

- **Model the kernel's n² term, together with the long-tier rows, at the next regeneration** (item 57). The model's
  rows are 1 → 2-action marginals, so K, V and E are low for large publications by about 60 to 85 × n² gas (n the
  publication's actions; memory expansion, confirmed from one trace; `test/integration/KernelGrowth.t.sol` measures the
  slope on both schedules, so the term can be fitted from data already in the suite). Re-check every stated maximum
  with it, including the 0.22-point margin between amsterdam's execution under-prediction (10.52%) and the SDK
  tripwire's firing point (10.74%). Until then `FloorPlan.t.sol` executing every planned shape's largest batch on both
  schedules is the guard (item 51).
- **No CI job runs the full `gas-model --check`.** `pnpm gas:model:check` (the `check` workflow) passes
  `--skip-amsterdam`, and the `amsterdam` workflow builds and tests but does not run the model check. So the amsterdam
  constants, the 10.52% figure that sits 0.22 points from the SDK's tripwire, and the `laterRows` notes that quote both
  schedules are re-derived only by hand, at each regeneration. Add the full check (both schedules) to the `amsterdam`
  job when the n² term is modelled.

- **Lists beyond the claim.** The floor claims later statements in lists of up to 1,024 entries per author per place;
  since the list release (item 50) it covers every later statement across places up to 3,586 entries on prague (a yes
  after a lone no stops from 3,587: 1.007, then 0.996) and up to 8,191 on amsterdam (that yes and a restore of a far
  entry stop from 8,192: 1.008 and 1.007, then 0.997 and 0.996); before it, up to 4,096 on both (0.995 / 0.991 at
  4,097). The entry search (`RealmIndex._entryIndex` bisects the author's scope list, one store call per probe, each
  probe reading the word that holds its entry: about 2.1k per probe and 2.0k per distinct word across places, so a list's
  cost goes with its probes and words, not only its length) is what makes a later statement grow with the list; reading a whole word of five entries per probe near the end of the search, or storing a binding's entry
  index, would shorten or remove it. An index change for a later generation (docs/WORK-MODEL-V3.md, "Landed").
- **A planned full batch that meets lists longer than the planner knows.** A planner cannot see list lengths it has not
  read; a batch planned at its largest size whose statements hit lists beyond what the planner knows can need more
  execution gas than the plan assumed. If that passes the 2^24 cap, `eth_estimateGas` fails and the publication is
  refused at send-time as over the cap, nothing sent; the sender then plans it again in smaller parts.
- **The digest-spec case (d)**: a digest spec rebuilt in a fresh store (docs/INDEX-BUILD.md §8 test 9).
- **A manifest copy over 24,575 B** is refused, not split (docs/INDEX-BUILD.md §10 item 34).
- **A real chain's deployment document must describe that chain, read from the chain.** Today only the fixture tool
  writes a deployment document, and it fills the `chain` block from its `--hardfork` option (osaka or prague, both
  priced as `feeSchedule: "prague"`). No tool deploys to a real chain yet. When one is written, its `chain` block must
  come from the chain itself, never from an option or from what the fixture does: the fee schedule from a probe of
  how the chain prices a fresh slot (`tools/state-gas-probe.mjs`; Sepolia prices by EIP-8037 since late 2026, so a
  Sepolia document says `feeSchedule: "amsterdam"`, which is what a consumer's planner keys on), the block gas limit
  from the chain's latest block (Sepolia: about 200,000,000 on 2026-11-26, 60,000,000 until late September 2026),
  and the cap rule that applies there (under EIP-8037 the 2^24 cap counts execution gas only). **`feeSchedule` is
  always written**, with one of the schedule names of `gas/model.json` (`prague`, `amsterdam`): a consumer keys on it
  first and uses `hardfork` only when it is absent, so `hardfork` may be whatever the chain calls its fork. A consumer that finds
  no schedule it knows refuses to plan, so a wrong or missing name fails closed, but a WRONG known name (prague on an
  EIP-8037 chain) would under-fund every large-state publication.
- **A Realm on the `3ca53ba` kernel needs a new index generation to move to this release.** An index of work-model
  formula 2 cannot be kept under this release's ingress: activation refuses it `E_INDEX_NOT_READY(15)` (item 44). No
  Realm exists today, so nothing has to move.
- **One Unicode generator.** `TopicProfile.REFUSED`, its JS copy and the SDK's vectors are hand-written from Unicode
  15.1; one committed generator from one pinned Unicode version must produce all three. The fold rule is ruled
  (QUESTIONS Q53, 2026-11-26). The generator's inputs are committed in the SDK repository (its
  `docs/design/word-characters/generator/`); it waits on the founder's answer on unassigned code points and is not
  built in this release. Until then the `topic-word/1`, `topic/1` and `text/1` Type ids are provisional.
- **The gateway serves no topic pages** (item 55). Every topic path answers `501 topic paths are not served`. A known
  gap, not ordered.
- **The non-ASCII side of the word rule** (item 53). The ASCII side of `topic-word/1` is ruled and built (the 39
  characters, no trailing `.`); the non-ASCII side (a proposal to refuse punctuation, symbols and separators outside
  ASCII, under the SDK's evaluation, with the generator above) changes the word rule's code, and so the `topic-word/1`
  Type id and every topic id, once more in a later release.
- **Names that differ only by capitals or normalization** (QUESTIONS Q7, item 54). Two names that differ only by
  capitals or by Unicode normalization (`Report.txt` and `report.txt`) are still two distinct names on chain, which
  stores and compares names byte for byte. Q7 stays open until before any lasting deployment.
- **The expiry field's width.** The head row's expiry field is 32 bits (seconds until 2106) since the number took
  16; widening it later is a layout change (`layoutId`), so its width is settled before freeze.

**16. A gap in CI, now closed (it predates this release).** `pnpm check` ran only before the build in CI, so its
artifact checks were reported as pending and never ran there: the opcode lint that the ingress writes nothing, the
opcode lint that the apply delegate calls nothing, and the rule that profile rules carry no immutables. They pass on
this release's tree. CI now runs `pnpm check --built` after the build, which fails when any of them did not run. A
consumer that relied on "CI is green" for those three properties in earlier commits should know they were checked
locally, not by CI.

### Since the tag release (this release against `899767e`)

A consumer that vendored the tag release (`899767e`, digest `0xfebf6886…8495`) re-vendors the same directories again.
These are the changes; everything else in the consumer surface is as above.

**17. Thirteen gas rows for statements about topics.** `gas/model.json` prices `PROPERTY`, `SAME` and `BROADER` on
both schedules: `bindPropertyFresh`, `bindPropertyRebind`, `unbindProperty`, `releaseProperty`, `bindSameFreshWord`,
`bindSameFreshPath`, `unbindSame`, `releaseSame`, `restoreSame`, `bindBroaderFresh`, `unbindBroader`,
`releaseBroader`, `restoreBroader` ("The planning model" has the table and the nearest existing rows). A label with a
new text is the `text/1` publish row plus `bindPropertyFresh` (composite `validate label new text`). The planner
prices them by their constants key, with no code change.

**18. The anchor rule for `fixed`.** `fixed` is the median of `2·k1 − k2` over the forty anchor pairs only
(`fit.fixedAnchors`, `tools/gas-fit.mjs`), so adding a row never changes the price of an existing action. `fixed` is
315,778 on prague (315,790 at `899767e`) and 899,110 on amsterdam (899,098): the anchor rows themselves moved by 12 to
36 gas with this release's code, not the new rows. The schema now requires `fit.fixedAnchors`.

**19. The label language rule.** `EfsTopics.labelKey(tag)` lowercases ASCII `A`–`Z` in the BCP 47 tag before deriving
the key, so `pt-BR` and `pt-br` are one key (`label:pt-br`), and so are `EN` and `en`. The chain cannot check it (the
key is a hash): the SDK's twin must fold the same way (`test/vectors/topics.json` `labelKeys`).

**20. The bitmap store: `efs/bitmap-store/2`.** `IBitmapStore.openCoverage` now also accepts the live generation
while the ledger is idle (backfill mode), so a scope that no publication touches after a later BITMAP family is
declared can still get a coverage slot and be backfilled to COMPLETE. Nothing else changed: the writer and family
rule is the same, `E_COVERAGE(1)` still refuses an open slot, and the store does not judge `liveFrom` (for an idle
open the generation passes the frontier plus one). The ABI is unchanged, but the id's tag is now
`efs/bitmap-store/2`, so `STORE_ABI_ID` is `0x2d01560e82c334b2278e6228309ae5d2129bc4d82e60e7111ee8b9276987ba36` (was
`0xb3240a15…5d6f`). This was the one store change that had to land before the first lasting deployment
(docs/INDEX-BUILD.md §0, §7.2): **it is done.**

**21. Refusal code 16.** `FilesFinalValidator` refuses a first "not this" at HEAD (an UNBIND with no earlier statement
by its author) whose subject is not a subject created strictly before it: `E_FILES_FINAL(16, leaf)` inside
`E_INDEX_CALL`. Every subject a HEAD BIND can pass code 8 on is such a file, so nothing that can have a version loses
its "not this"; masks and releases of an existing HEAD are still never judged. The validator's codes are now 1–16. It
adds 5,236 gas to a lone HEAD "not this" on prague and 5,224 of execution gas on amsterdam (no state gas), and on 64
of them the final phase uses 93% of the final reserve on both schedules.

**22. Identities.** Moved: the release digest, the plan hash, the execution set, the index obligations and manifest
hash, the index (generation 1) and its reads contract, `BitmapStore` and `FilesFinalValidator` (address, initcode and
runtime codehash), the bitmap store ABI id, and in `artifacts/` only `BitmapStore.json` and `FilesFinalValidator.json`.
Not moved: the layout id, the hot ABI ids, the posting store ABI id, every Type id, the ledger proxy and
implementation, the registry, every reader and the gateway, the seed (`efs-fixture-seed/4`, the root directory record
`0xf7547aa6…c037`, `docs`, `readme.txt`, `big.bin`, `remote.txt`). The table below has the values.

### Since the statement-rows release (this release against `0fb4804`)

**A consumer does not re-vendor for this step.** Nothing an SDK or a client calls or does changes: no ABI, no
action, no read, no gas row a planner uses. Only the release digest, some addresses and the meaning lists of
`E_INDEX_NOT_READY` and `E_BUILD` move. The same holds for the following build-from-history steps (docs/INDEX-BUILD.md
steps 2 to 4) on their own account: a consumer re-vendors once the build work is finished, or earlier only if it
needs something else from a later commit.

**23. A re-pinned generation can be switched on (build from history, step 1).** A later index generation that carries
the stores it names (a store is *carried* unless it names the generation as `INITIAL_WRITER` and is not attached)
becomes ready on a Realm with admissions: `build(0, maxFacts)`, permissionless and only between publications, moves
its frontier to the ledger's counts once its *carried check* passes (every family it keeps in a carried store is
declared by the live index in the same store from admission 1), and activation then accepts it. A generation whose
carried check fails reports `completedAdmission` and `completedPublication` 0 and is not ready, at the moment it is
read. Activation of a new index checks the same thing itself, from the live index's own readiness, and refuses two
new reasons: **`E_INDEX_NOT_READY(12)`**, a carried family is not the live index's (with admissions; also when the
live index has no code), or, on a Realm with no admissions, a store has already been written (its writers list is
not empty; genesis stores are new and pass), and **`E_INDEX_NOT_READY(13)`**, a store that names the candidate as `INITIAL_WRITER` is
already attached. The catch-up check (8) now runs after the family checks, so such a candidate is named 12 or 13, not
8. Reasons 1 to 13 are listed in `src/interfaces/Errors.sol` (and in `release/errors.json`).

**24. `E_BUILD` codes.** `build` no longer reverts `E_BUILD(0)`. Codes: 1 the generation is live or was activated, 3
the ledger is not idle or a replay or build call is in flight, 4 the generation has a fresh store (the walk of history
is step 2), 7 the carried check fails (on an empty Realm: one of its stores has been written), 8 a nonzero `familyId`. `backfill` still reverts `E_BACKFILL(0)`;
`replayNextPublication` is unchanged.

**25. Identities.** Moved, against `0fb4804`: the release digest (`0xa32e7718374e00ff725fe8a9cc68a1069d16041ca180074d277aada093b569e5`, was
`0x580ede64…d04e`), the plan hash (`0x24e31f1392a12a2f255c272be23064ae0943d6947f607a5e382c872563dc32ac`), the execution set
(`0xbc4ab679e18565670d009eda38285d19326ec5c7a0d9552c22034338fb7b5b83`), the index obligations
(`0x554052222a26ab5ff71f5f604e71b954c2da30cde8fa9d41cc7eb3ad148b4631`) and manifest hash
(`0xbadcd8102461d41530f6069a471662e629e21dc5824a56e530bc70c9c50eac10`); the code of `LedgerControl`, `RealmIndex` and
`IndexReads` (in `artifacts/` only these three files changed). Because the genesis contract embeds the control
delegate's address, every address genesis creates moved with it on the fixture Realm: the ledger implementation and
proxy (`0xD3523C0efE21753f63282a2713186FE9eB7A136b`), both ProxyAdmins, the registry proxy, the controller, both
stores, the index (`0x40275a9f07D1E21300399fD57aBAc345f9662839`) and its reads contract, and every reader that embeds
the ledger's address (`lensReader`, `filesPageReader`, the three topic readers, the gateway and its content contract);
their runtime codehashes move only through those embedded addresses. Not moved: the layout id, the hot ABI ids, both
store ABI ids (no store code changed), every Type id, the ingress and apply delegates, the registry implementation,
`ledgerReads`, `ledgerViews`, `readerDirectory`, `keysView`, every Files rule and the validator, and the seed
(`efs-fixture-seed/4`, root `0xf7547aa6…c037`). Gas: the measured publication rows moved by −12 to +144 gas (almost
all up, by 12 to 144; the index's dispatch changed); `fixed` is 315,790 on prague (315,778 at `0fb4804`) and 899,110 on
amsterdam (unchanged); the validation composites moved by at most 0.01 points (max error 5.80% prague, 7.57%
amsterdam, as at `0fb4804`); the read rows rose by up to 2,652 gas (the reads contract's dispatch), and one read bound
fell by one skipped entry.

### Build from history, step 2 (this release against `99d617a`)

**A consumer does not re-vendor for this step** (the standing note of item 23's section holds): no ABI, action, write
or reader changed, and no selector moved (`test/snapshots/abi/` is unchanged). What moved is below; a consumer
re-vendors once the build work is finished, or earlier only if it needs something else from a later commit.

**26. The walk of history (build from history, step 2).** `build(0, maxFacts)` on a generation with a fresh store
walks history into it: whole publications in order from the generation's frontier, while the leaves folded in the
call plus the next publication's leaf count stay within `maxFacts` (at least one publication per call; with nothing
pending it returns the frontier). It folds only the families of the generation's fresh stores, with the live fold
code, so a generation of generation 1's code can rebuild both stores (the heal path) or either one while carrying the
other (docs/INDEX-BUILD.md §3.2–3.4, §4.3). `replayNextPublication` is unchanged. Fold hooks run only when both stores
are fresh; final hooks never run in a build or replay. Coverage reads of a generation that has never folded live now
apply its carried check to families in carried stores (PARTIAL from 1 through 0 when it fails); a generation that has
folded live (the live index, or a replaced one) answers exactly as before, at the same cost: it is told apart by its
own `liveStarted`, read in the call coverage already made. **`E_INDEX_NOT_READY(12)` gains a case:** on a Realm with no
admissions, a store of a maintained family must also name 0 or the candidate as `INITIAL_WRITER` (a third contract
could otherwise write it in build mode after activation, before the first live write attaches it); the generation's
carried check refuses the same (`build` gives 7). Genesis stores (`INITIAL_WRITER` 0) and a generation's own fresh
stores are unaffected. **`E_BUILD` codes:** 1 live or activated, 2 a store names the generation as `INITIAL_WRITER`
but a live write has attached it, 3 not idle or a call in flight, 5 a fresh store and no decoder, 6 the next
publication's leaf count exceeds `maxFacts`, 7 the carried check fails, 8 a nonzero `familyId`; **4 is removed** (and
stays unused). The meanings are in `src/interfaces/Errors.sol` and `release/errors.json`.

**27. Gas.** The index's fold threads a carried-store mask and runs a bind's two stores' halves one after the other
(docs/INDEX-BUILD.md §10 item 10). Against `99d617a`: the measured publication rows rose by 171 to 2,230 gas (the
per-action constants: +127 to +130 per PUBLISH, REUSE or CREATE, +387 to +486 per bind-kind action, +164 per
WITHDRAW, on both schedules); `fixed` is 315,834 on prague (was 315,790) and 899,154 on amsterdam (was 899,110): the anchor rows
moved with the index's dispatch; the validation composites moved by at most 0.01 points (max error 5.80% prague,
7.56% amsterdam, was 7.57%). **The live index's reads cost what they cost before the build steps**: coverage keys on
the generation's own `liveStarted` in the call it already made, so no read pays for the carried check. The read rows
moved by −3,114 to +16 gas against `99d617a` (−740 to +227 against `0fb4804`; per list read a few tens of gas, from the
reads contract's and the index's function tables), and **the read bounds and recommended limits are unchanged
against `0fb4804`** (against `99d617a` one moved back: `limitEntries` and the `everyoneBelow` `maxSkippedEntries`
bounds on prague are 246 again, as at `0fb4804`; step 1 had made them 245). The floor-plan vectors' `k` did not move
for any shape.

**28. Identities.** Moved, against `99d617a`: the release digest (`0x76c15412fa383c7d3a748287efcee9c284aea3daac9f352487fe2de0cbcfee03`, was
`0xa32e7718…69e5`), the plan hash (`0x32438ed87fd28838b2f1fc5237bef63a007661d003fae887765fbd14fc64e751`, was
`0x24e31f13…32ac`), the execution set (`0x0788d65963e48f73fe655a469cc2110365bc9e498cc37c56030d60ac3a9cb99d`, was
`0xbc4ab679…5b83`), the index obligations (`0x5555dbfb2f06017916926a884b60e8cd72ac362a37661dc09d3e6b3674674f79`, was
`0x55405222…4631`) and manifest hash (`0x3b50d7a2f8ee5104dc0038713dac38a902b16e2045d4904e73635606ef33009f`, was
`0xbadcd810…ac10`); the code of `LedgerControl`, `RealmIndex` and `IndexReads` (in `artifacts/` only these three files
changed), `release/errors.json` (the `E_BUILD` meanings and reason 12's new case), `gas/model.json` and the floor-plan
vectors' measured figures. Because the genesis contract embeds the control delegate's address, every address genesis
creates moved with it on the fixture Realm, as in item 25: the ledger implementation (`LedgerCore`) and proxy
(`0x83ce0B9E2DDd9c5CEBBfe6b2b9Bc275fda9A20fB`, was `0xD3523C0e…136b`), both ProxyAdmins, the registry proxy, the
controller, both stores, the index (`0x6ebfdf09F489bBdBeeF929bcb0C8B7eae02217f7`) and its reads contract
(`0x7345300136217575d8eC1cFd1beA91d25c9A329d`), and every reader that embeds the ledger's address (`lensReader`,
`filesPageReader`, the three topic readers, the gateway and its content contract); the stores' and readers' runtime
codehashes move only through those embedded addresses. Not moved: the layout id, the hot ABI ids, both store ABI
ids (no store code changed), every Type id, the ingress and apply delegates, the registry implementation, the
decoder, `ledgerReads`, `ledgerViews`, `readerDirectory`, `keysView`, every Files rule and the validator, and the
seed (`efs-fixture-seed/4`, root `0xf7547aa6…c037`). No ABI changed (`test/snapshots/abi/` is unchanged; the index's
new `generationProgress()` is in no consumer interface).

### The topic page frontier (this release against `24fa269`; the SDK re-vendors from `0fb4804`)

**A consumer re-vendored for this release** (it became `cbf5b78`, the commit the SDK is pinned to now): it was the
next re-vendor point after `0fb4804`. Between `0fb4804` and that release (the identity table below now compares this
release against `cbf5b78`; the values at `cbf5b78` are its "was" column):

- **Build from history, steps 1 and 2** (items 23 to 28) change nothing a client can call: no ABI, action, write or
  read; they move the release digest, the plan hash, the execution set, the index's identities and, through the
  control delegate embedded in genesis, every genesis address on the fixture Realm (items 25 and 28).
- **The topic page frontier** (items 29 to 31) is the one change a consumer calls: the three topic readers' ABIs
  (`TopicPageInfo` gains `frontier`) and addresses. It is the only ABI change against `0fb4804` (`test/snapshots/abi/`
  differs in `ITopicMineReader`, `ITopicEveryoneReader` and `ITopicLookupReader` only).
- **Read bounds that differ from `0fb4804`:** prague `limitEntries` 246 → 245, and prague `everyoneBelow`
  `maxSkippedEntries` 246 → 245 at every lens (1, 8, 16, 32, 64). Nothing else in `reads.schedules.*.bounds` or
  `recommended` differs on either schedule: `pageTimesLens` 768 / 416 / 688 / 408, `maxRows` 150 and every per-lens
  `maxRows` are as at `0fb4804`, and amsterdam's `limitEntries` is 245 as it was.

**29. `TopicPageInfo.frontier`** (`uint64`, after `scanned`; every later field of the struct moves one word, so
decoding needs the new ABI). It is the entry the continuation's next page reads first: the newest entry of the listing
not yet processed, an entry fetched into a window but not processed when the page stopped included, in the number space
of the view's row entry: binding ordinals (`bindingOrdinal`) in `mine`, `everyone` and `about`, admission ordinals in
`byName` (`firstAdmission`), `wordPage` and `children` (`admission`). Over merged lists (`mine`: every lens author's
exact list and roll-up; `everyone` below: the place list and the roll-up) it is the largest of each list's next unread
entry. On a PRESENT page it is 0 exactly when `scanStatus` is 1 EXHAUSTED (both ordinals start at 1, so no entry is
0); every refusal carries 0. Guarantee: every row of the page has an entry strictly greater than `frontier`, every row
of any later page of the listing an entry at most `frontier`, and `frontier` falls strictly from page to page, a page
with no rows included (each page reads at least one entry). Exceptions: `wordPage`'s first-page root row is no list
entry (its admission is the word page's own, older than every entry); in `mine` a lens that names one principal twice
reads that author's lists twice, so a row's entry can equal `frontier` and `frontier` can repeat (pass each principal
once). Frontiers of different views, or of listings started at different origins, are not promised to be comparable.
Stated in the page laws (`src/interfaces/Readers.sol`) and docs/TAG-DESIGN.md §6; `test/readers/TopicFrontier.t.sol`
checks every view's chains against the index's own lists. `placeCount`, `authorCount` and `entryCount` return no page
and are unchanged.

**30. Gas and bounds.** `mine` and `everyone` take `frontier` from what the page holds (the merge front, the window's
first unconsumed entry): +92 to +303 gas per call on the measured rows, and +16 per skipped entry of `everyone`
(36,145 below at a lens of 1, was 36,129). The lookups read one entry more in the page's slice when one is left:
`byName` page 10 +4,222, `about` page 10 +4,399, `children` page 1 +4,192 (the entry in a word of its own; +273 to
+1,276 where it shares a word), the same on both schedules. The look-ahead rides in the page's own slice, so a full
page of 64 rows with entries left asks `postingSliceOf` for 65 entries: within its documented maximum, the Realm's
`limits.maxReadCount` (256 in the release profile; limits never shrink at freeze). What each reader path asks the index
and the bitmap store for at most, per read: the `mine` and `everyone` windows 16 entries (an exact scope list's window
also one live word), a row's sample 64, a lookup page its rows plus one (`test/readers/TopicFrontier.t.sol`,
`TopicSliceCapTest`, through a double that reverts any read above its cap). **Bounds that moved:** prague `limitEntries` 246 → 245
and prague `everyoneBelow` `maxSkippedEntries` 246 → 245 at every lens (now equal to amsterdam's). `pageTimesLens`
(768 / 416 / 688 / 408), `maxRows` (150) and every `maxRows` bound are unchanged on both schedules. Sizes:
`TopicMineReader` 15,528 B (+47), `TopicEveryoneReader` 16,696 B (+91), `TopicLookupReader` 16,950 B (+392).

**31. Identities.** Moved, against `24fa269`: the release digest
(`0x56bd2f9524e3de85cada737526b1e237c6f69c1b8822f2d36b2a9805100c2565`, was `0x76c15412…ee03`), the plan hash
(`0xe40993daed758041730c5e7b728b86c1171da768c570522bcba2e07b9a432a2c`, was `0x32438ed8…e751`), the three topic readers
(`topicMineReader` `0xFB2f372bebEa5204292ebf4Aefd19EB4e4E09f21`, was `0xE3aD0274…E170`; `topicEveryoneReader`
`0x1ee0AB9D6f342cE440BA1a16f53c6FF3C8f986D2`, was `0x9CD44A56…3A28`; `topicLookupReader`
`0xC74BacA330C94774f332F918FbDca568AB5E119C`, was `0x037dA52b…B484`; runtime, initcode and codehash), their three
`artifacts/` files and their three ABI snapshots, and `gas/model.json` (its `reads`). Not moved: the execution set
(`0x0788d659…b99d`), the index obligations and manifest hash, the layout id, the hot and store ABI ids, every Type
id, the ledger proxy (`0x83ce0B9E…20fB`) and every other address, every other unit's code and ABI, the publication
rows of the gas model, `release/errors.json` and the seed (`efs-fixture-seed/4`).

### Build from history, step 3a: the as-of rule (this release against `26fce43`)

**A consumer does not re-vendor for this step on its own account** (the standing note of item 23's section holds):
nothing a client can call changes. No ABI, action, write, read, reader or error moved (`test/snapshots/abi/` and
`release/errors.json` are unchanged), and no gas row a planner prices from moved by more than 61 gas. A consumer
re-vendors once the build work is finished, or earlier only if it needs something else from a later commit.

**32. The as-of rule (build from history, step 3a).** A fold from history (a replay or any `build`) reads every
fact as of the admission it folds, and takes no fact from a validator's law: a build never re-runs final hooks, so a
law holds only for the history judged under it (docs/INDEX-BUILD.md §4.3, which audits every read of the fold and
the replay decoder). The one read that needed it was the topic roll-up walk's subject: on a Realm whose earlier
history was not judged under `FilesFinalValidator` code 9 (a generation with no topic lists and no Files validator,
for example), a tag could be admitted before its topic was registered, and a topic-list generation built later filed
a roll-up for it or not depending on when the build ran. Now the history path treats the subject as a topic only when
its first admission is strictly below the statement's, which is exactly what the live fold sees (the kernel calls the
index after each leaf), so a build files what a live fold files on any history. The live fold is unchanged in what it
reads and writes: the index tells a fold from history by the selector of the call it runs in (`replayFold`), and the
live path pays one comparison where the walk needs it. Gas: `bindTagFresh`, `bindTagSecondAuthor` and
`unbindTagLone` +61 on both schedules (the TAG first statements, the actions that reach the walk; `bindTagSecondAuthor`
+73 on prague); every other constant that moved, moved by ±12 (code placement); `fixed`, `tagLevel`, every read row,
bound and recommended limit, and every floor-plan `k` are unchanged; max error 5.80% prague, 7.56% amsterdam, as
before. A build pays about 1,500 to 2,300 gas more per first tag on prague (one more word in the walk's first batch).
`RealmIndex` is 18,705 B (was 18,244; budget 19,660).

**33. Identities.** Moved, against `26fce43`: the release digest (it also records the source commit; the value is in
`release/release.json` and in the regeneration commit, was `0x56bd2f95…2565`), the plan hash
(`0x71a26e4abb0d11ec9ef2ecf24b7c62cb16d8ed85b3551ab752a1d178efe3051e`, was `0xe40993da…2a2c`), the execution set
(`0xb381c6768f0e1d3fd24e86bc040eb7fcaf89de5cd637ae33c31e9348dd26d063`, was `0x0788d659…b99d`), the index obligations
(`0x3d0f3ec440f93749596a6849bc1614b8b8791689bb1a9601db1d6a8839fbd479`, was `0x5555dbfb…4f79`), and `RealmIndex`
(generation 1): its address on the fixture Realm (`0xf63888F81EA42E48C1569570d6482F715593c0dE`, was
`0x6ebfdf09…17f7`), runtime codehash (`0xf9c77ea96b7990c2e7a3990e0deedac57bc8ef43c6177bdbd16979b4d29cfa5e`, was
`0x3ce5e150…b452`) and initcode; in `artifacts/` only `RealmIndex.json` changed; `gas/model.json` (sha256
`0x433a8a63e26eaf000889d813d2374bf908924d11a0a72e72e0b78a9f9b4e5fdc`) and the floor-plan vectors' measured figures.
Not moved: the index manifest hash (`0x3b50d7a2…009f`: it folds the reads contract, not the index), the reads contract
(`0x73453001…329d`) and every other address and codehash (the ledger proxy `0x83ce0B9E…20fB`, the implementation, the
control delegate, both stores, the registry, every reader and the gateway: none embeds the index's address), the layout
id, the hot and store ABI ids, every Type id, `release/errors.json`, the ABI snapshots and the seed
(`efs-fixture-seed/4`, root `0xf7547aa6…c037`).

### Build from history, step 3b: a new list in a third store, as a test harness (this release against `5dfb146`)

**A consumer does not re-vendor for this step on its own account** (the standing note of item 23's section holds):
nothing a client can call changes. No ABI, action, write, read, reader or error moved (`test/snapshots/abi/` and
`release/errors.json` are unchanged); the new list, its generation and its deployer are a test harness, not product,
and nothing of them is deployed or in the release. A consumer re-vendors once the build work is finished, or earlier
only if it needs something else from a later commit.

**34. A new list built from history (build from history, step 3b).** `RealmIndex` and `IndexReads` gained internal
extension points that cost nothing unused, so a later generation that carries the genesis stores and keeps a new list
in a further fresh store can be written as those contracts with their extension points overridden: `RealmIndex`'s
fold hooks now run when `_hookRuns(unit, carried)` says so (default: only with nothing carried, as before), and
`IndexReads`' family table and `_declare` are internal, `_carriedCheck` is virtual and the posting reads take the
family's store from `_postingOf` (default: the one posting store). `IndexReads`' runtime is byte-identical;
`RealmIndex` is 18,692 B (was 18,705; budget 19,660). The example (`head-authors`, everyone's versions of a file,
provisional kind 22, in `test/harness/HeadAuthors.sol`) is built, switched on and compared with a Realm that ran it
from genesis, and the dropped-list, fold-hook and partial-coverage tests of the pre-freeze gate pass (docs/INDEX-BUILD.md
§10 items 24–28). Gas (`gas/model.json` against `5dfb146`): every constant moved by −24 to +51 on both schedules (prague: `fixed` −24, the per-action constants +27 to +51, most +39; amsterdam +15 to +51), multi-leaf measured rows by up to +429 (about 39 a leaf); the live fold's only new work is the carried mask passed to the fold-hook loop (generation 1 pins no fold hook, so `_hookRuns` is never reached live), the rest is via-IR code placement; `reads`, `tagLists`, `planning`, every read bound and recommended limit and every floor-plan `k` are unchanged; max error 5.80% prague, 7.56% amsterdam, as before.

**35. Identities.** Moved, against `5dfb146`: the release digest (it also records the source commit; the value is in
`release/release.json` and in the regeneration commit), the plan hash
(`0xdc11743c2e9373ef340cc750c0c2feffadcc0ebcf33e66c00ab883b2e59db803`, was `0x71a26e4a…051e`), the execution set
(`0x2f9812f21076aace773031cfaa207c8a528a8cdf6a7c5c891ce0071b5c4a861c`, was `0xb381c676…d063`), the index obligations
(`0xcaa71c0209688789a7b860d7374ffdaca8b20ff3ee250db7a57b98cca6e44c0d`, was `0x3d0f3ec4…d479`), and `RealmIndex`
(generation 1): its address on the fixture Realm (`0xef782FF1Bb38eDA3A07469DB397f68a75f5034cE`, was
`0xf63888F8…c0dE`), runtime codehash (`0xe7ca5368dda61eb94b908a0d2402246493d070326b621e0ad4f35d7199d0c094`, was
`0xf9c77ea9…fa5e`) and initcode (24,976 B, was 24,989); in `artifacts/` only `RealmIndex.json` changed; `gas/model.json`
and the floor-plan vectors' measured figures. Not moved: the index manifest hash (it folds the reads contract, not the
index), the reads contract (`IndexReads`' runtime is byte-identical) and every other address and codehash, the layout
id, the hot and store ABI ids, every Type id, `release/errors.json`, the ABI snapshots and the seed.

**36. The measured gas of a build (build from history, step 4).** Measurement and docs only: no `src/` file, no
release file, no ABI, identity, gas-model row or floor-plan vector moved, so a consumer does not re-vendor for it. The
figures (docs/INDEX-BUILD.md §6, `test/index/BuildGas.t.sol`, both schedules): adding a list later is priced by the walk
of the whole history, about 26k a publication plus 11k to 24k a leaf (a create-file recipe 148,259, an edit 91,462),
plus the list's own writes, plus a fixed share of about 0.49M–0.52M a cold call; for 1,000,000 files of a create, three
edits and a few second versions and masks each, 484.6B gas on prague and 582.4B on amsterdam (state gas included),
9.5× and 3.9× the price of keeping the list from genesis. Every admitted publication builds in one 2^24 call (the
least headroom: a full replay of 64 lone negatives on prague, 4.34M). **One finding for consumers** (docs/INDEX-BUILD.md
§10 item 29, `test/integration/FloorReconcile.t.sol`): on amsterdam the plan's max(E, V) is execution gas; a
transaction needs the state gas on top, and a single create-file sent with exactly max(E, V) plus its state gas was
refused (14k to 56k short; with the 15% headroom it is admitted, and every planned batch is admitted with exactly the
plan). Take the gas limit from `eth_estimateGas`, as the planning rule says, never from V; on prague the plan covers
every measured shape with no headroom (41,534 to spare for the tightest). A callback that runs out never lets a
publication land unindexed: it is refused `E_INDEX_GAS` and nothing is admitted. *(Since items 37 and 39, at
regeneration: the fixed share of a cold call is 0.25M–0.29M and the 1,000,000-file build 477.7B / 575.7B, because the
carried check reads the manifest copy from code; and with the Glamsterdam rewrite price one create-file recipe sent
with exactly max(E, V) plus its state gas is admitted on amsterdam in both states, 114,791 and 78,791 to spare.
docs/INDEX-BUILD.md §6, §10 items 29 and 39.)*

**37. The liveness gate and Option A (build from history; docs/INDEX-BUILD.md §3.5, §3.6, §5.3, §10 items 34–38).**
A consumer **re-vendors for the release this lands in**: an ABI, an error, the index's constructor and three units'
code changed.
- **Reason 14.** `E_INDEX_NOT_READY(14)`: the candidate carries a store and its copy of the live index's manifest is not
  the manifest the kernel recorded for the current revision (empty, altered, another index's, or stale). Reason 12 no
  longer includes "the live index has no code", and the kernel never calls the live index to activate a successor.
  `E_PIN(reads, 12)`: a reads contract's copy exceeds 24,575 B. `E_BUILD(7)` also covers a stale or wrong copy and a new
  fold-hook unit (below). `release/errors.json` changes with these meanings.
- **The manifest copy.** `IIndexReads.liveManifestCopy()` (new selector `0x1c317828`; `test/snapshots/abi/IIndexReads.json`
  changed) returns the copy a generation was deployed with: `abi.encode(header, families, units, specs, work,
  physicalProfile, callbackProfile, reads, readsCodehash)` of the live index, whose keccak is its `manifestHash()`. An
  operator deploying a later generation takes it from the live index's reads contract (its `manifest()` with that
  contract's address and codehash; it does not need the live index to answer) and passes it as `IndexReads`' new last
  constructor argument (`IndexDeployer.Plan.liveManifest`); genesis passes empty bytes. The copy is held as the code of
  a data contract the reads contract creates (`LIVE_COPY`, `LIVE_COPY_CODEHASH`). **What an operator pays** (measured,
  `test/index/LivenessCost.t.sol`, re-run on this release's build: the real `IndexReads` with generation 1's copy
  against an empty one): for generation 1's shape (7,168 B) 1,537,383 gas on prague and 271,177 execution + 11,152,170
  state gas on amsterdam on top of the reads contract's deployment (`liveManifestCopy()` cold: 7,374 / 7,974); genesis
  passes an empty copy, so `gas/report.json` has no row for it; a copy grows 320 B per family and 320 B per
  unit (+32 B per unit family id, +96 B per digest spec). A copy is valid only while the index it copies is live: if
  the live index is replaced before the candidate is activated, redeploy the candidate with a fresh copy.
- **Option A.** A generation that carries a store refuses (`build` 7, readiness not ready, activation 8) any fold-hook
  unit the live index does not declare with the same fold hook, fold codehash and `purposeFilter`, unless the
  generation walks history and its reads contract names the unit as built (`IndexReads.builtHooks()`, read by the
  generation at construction into `RealmIndex.BUILT_HOOKS`). Final-hook-only units and the empty Realm are unaffected.
  Generation 1 builds none (`builtHooks() == 0`). The claim "this generation builds that hook" counts only when the
  generation actually walks history, that is when it has a fresh store; a generation that carries every store is
  refused a new fold-hook unit whatever it claims.
- **A replaced generation that carries any store can no longer build at all**, because its manifest copy went stale
  when the index it copied was replaced; only a generation whose every store is fresh can still walk history late
  (docs/INDEX-BUILD.md §5.3).
- **Addresses move.** `IndexReads` (constructor, code), `RealmIndex` (code: `BUILT_HOOKS`, `_hookRuns`) and
  `LedgerControl` (the controller delegate: reason 14) changed, so their runtime codehashes and every address and
  identity derived from them move: the index and its reads contract, the index manifest hash and obligations, the
  ledger implementation, the plan hash, the execution set and the release digest.

**The topic readers answer only from complete lists.** **A consumer re-vendors for the release this lands in** (`release/`, `artifacts/`, `deploy/plan.json`,
`gas/model.json` and the rest of the set above, together): the three topic readers' bytecode, and so their addresses,
change. Their ABIs do not (`test/snapshots/abi/` is unchanged), and nothing observable changes on a Realm whose live
index is complete, which every live index is: the rule only decides what a reader does with an index that reports a
list PARTIAL, and a live index never does.

**38. The list-coverage rule.** A topic reader (`TopicMineReader`, `TopicEveryoneReader`, every view of
`TopicLookupReader`, the count views `placeCount`, `authorCount` and `entryCount` included) answers from a list only
when the index reports that list's coverage COMPLETE. A list reported PARTIAL is treated exactly as one reported
UNKNOWN: status UNKNOWN, no rows, coverage UNKNOWN, no counts (`rawTotal`, `positionsEver` and a count view's two
counts 0), `frontier` 0 and no continuation; one needed list that is not COMPLETE refuses the view whatever the others
report, and a listing resumed after a needed list stopped being COMPLETE is refused from that page on. Before, PARTIAL
gave a PRESENT page with its coverage PARTIAL. Why: that PARTIAL did not survive paging (every page that is not
origin-started and finished already says PARTIAL, so a listing over a partly built list ended looking like an
ordinary long one), and its rows could not be promised (`everyone` decides from the `position-authors` counters, and
no design says what a partly built list's counters hold). A page's own `listingCoverage` is unchanged: COMPLETE only
when the listing started at the origin and finished on that page, PARTIAL on every other served page; it is now about
paging alone. Every refusal of a topic view (UNKNOWN, BASIS_STALE, UNSUPPORTED, LIMIT_EXCEEDED, INVALID) also carries
no counts now: `rawTotal` and `positionsEver` used to keep the counts of lists read before the refusal (for example
the exact lists of a `mine` below on an index without topic roll-ups). Reading a partly built list (newest pages while
old history is built) would be a new reader contract, designed with that feature, with a list-coverage field of its
own that survives paging.

**The `about` order, fixed at the final integration.** `about` read each row's `position-authors` head and refused a
zero count (`E_TOPIC_INCONSISTENT(3)`) before it looked at that list's coverage, so on an index that does not declare
the family (whose head reply is `(UNKNOWN, 0, 0, 0, false)`), or one that stopped keeping it over a carried store,
`about` reverted for every position first stated after the drop; it now checks coverage first and refuses UNKNOWN as
data, and a zero count is a fault only on a COMPLETE list. The two below-count refusals at a purpose other than TAG
(`placeCount` and `entryCount` with `below`) now carry coverage UNKNOWN, as every refusal does (they carried the
COMPLETE coverage of the list read). Every other check that can run on a list before its coverage is required
(`_listHead`'s range checks, the scope heads' and the coverage replies' own ranges) holds for any honest reply,
COMPLETE or not, so none of them can turn a not-COMPLETE list into a revert; the tests now also run every view
against every list it needs in the reply shape of an undeclared family (`FaultyReads.UNDECLARED`). One order is left
as it is and written in the page laws: on a resumed page the continuation's cursor is checked against a list's count
before its coverage, so only a forged continuation gets INVALID there instead of UNKNOWN.

For consumers, in one line: a served topic page can be trusted to come from complete lists, and UNKNOWN on a topic view
now also covers "the index is still building this list".

**The Glamsterdam floor price and the ordinary-state composites.** A consumer re-vendors `gas/model.json`,
`schemas/`, `test/vectors/` and the release digest once this lands; nothing a client calls changes (no ABI, action,
read, error, Type id or `src/` file moved). The figures below are the regenerated files' (`gas/model.json` and
`test/vectors/floor-plan.json` against the same files at `726993e`).

**39. The Glamsterdam floor prices a rewrite at 12,100, not 5,000.** On Glamsterdam (EIP-8038) a cold rewrite of an
existing slot costs 12,100 of execution gas, the same as the execution part of a fresh slot (prague 5,000 and 22,100);
the floor's `floorRewriteGas` for a Glamsterdam Realm (`tools/deploy-plan.mjs` `GLAMSTERDAM_FLOOR`, the harness's
`s1Limits()` under `FOUNDRY_PROFILE=amsterdam`, `profiles.amsterdam.floor.limits` in `gas/model.json`) was 5,000. Both
prices of both schedules are now read from one table, `tools/deploy-plan.mjs` `GAS_SCHEDULES` (mirrored for the
Solidity suites in `test/vectors/gas-schedules.json`; `tools/test/gas-schedules.test.mjs` checks the mirror, the
docs/GAS-SCHEDULES.md table and the floor constants against it, `test/integration/FloorPrices.t.sol` checks the
harness against the mirror and measures both prices on each profile, and `tools/release.mjs` refuses a model whose
amsterdam `floor.limits` differ). What it changes for a consumer: **on amsterdam only** (prague's quotes P and every
prague `k` are unchanged; prague's V moved by +22 to +1,364 gas with this release's re-fitted constants), the floor quote P of a publication grows by 7,100 per quoted rewrite, so its
requirement V grows and the planning rule's largest batch falls for the rewrite-heavy shapes: lone negatives 54 → 50,
masks, releases and masks of masks of tags 64 → 44, restores and number changes 64 → 41, folder re-binds 61 → 40,
a name record and a first tag 30 → 27 units, edits (PUBLISH child + HEAD re-bind) 30 → 23; first tags, name records,
repeat publishes, registration chunks and create-file recipes keep their k (docs/TAG-NUMBERS.md has the full table).
64 lone negatives no longer fit one amsterdam publication by V (18.34M against 16.60M; they did at 16.45M). Why it
matters: with 5,000 a create-file recipe in a folder that already holds the author's files was quoted at 0.969× its
callbacks' prefix spend on amsterdam (it can refuse a transaction sent near the floor, never admit an unindexed one);
after the fix the lowest P / spend of any shape the floor claims, in both states and on both schedules, is 1.02
(prague, unchanged) and on amsterdam 1.26 (`test/integration/FloorStates.t.sol`). The cost: later statements on
amsterdam are over-quoted 2.0–4.3× (the work model's `rwPerBindLater` is a compute margin expressed as twelve
rewrites), which only lowers their batch sizes above.

**40. Validation composites in the ordinary state; the model's stated maximum error.** `gas/model.json` validation
rows carry `state` (`listsNew` | `listsExist`; schema `efs-gas-model/1`, a required field), and four composites are
measured in the state where the author's lists exist: a create file in a folder that already holds one of the author's
files, a second edit of a file, a rename + move into a folder holding the author's entries, and a first tag on an
existing 6-word path whose roll-ups hold entries (`GasModel.t.sol` `test_model_validate_recipes_lists_exist`,
`test_model_validate_deep_tag_lists_exist`). No constant is refitted (`fixed` stays on its forty anchor pairs). Errors
of the four, from the regenerated model: prague create file −4.44%, edit +4.98%, rename move −2.41%, deep tag +2.58%;
amsterdam all gas −3.89%, +12.03%, −1.83%, +4.29%, and execution gas (what the rule plans by there) −10.62%, −3.11%,
−8.37%, +0.24%.

**The stated maximum errors, and which field bounds the cap.** Each profile states its largest composite error on all
gas, `maxAbsErrorPercent` (its meaning is unchanged: |`errorPercent`|, predicted against measured all gas), with the
composite that sets it, `maxAbsErrorComposite` (new). Amsterdam also states its largest error on execution gas as a
field of its own, `maxAbsExecutionErrorPercent`, with `maxAbsExecutionErrorComposite` (both new and required on
amsterdam by the schema; each amsterdam row carries `executionErrorPercent`). Regenerated: prague 5.80% (`validate
create file`); amsterdam 12.03% on all gas (`validate edit lists exist`; was 7.56%: the second edit's state gas is
predicted 17.65% high) and 10.62% on execution gas (`validate create file lists exist`, predicted low). **A consumer's
headroom check of the 2^24 cap condition uses `profiles.prague.maxAbsErrorPercent` on prague, where the cap counts
all gas, and `profiles.amsterdam.maxAbsExecutionErrorPercent` on amsterdam, where it counts execution gas only;**
`profiles.amsterdam.maxAbsErrorPercent` bounds the publication's total against the block, never the cap. All three
are under the rule's 15% headroom, which also covers intrinsic gas and calldata; `planning.headroomCovers` names both
figures and which one bounds the cap; `tools/gas-model.mjs` fails a model in which any composite's all-gas or
execution-gas error exceeds 15%, and `tools/test/gas-plan.test.mjs` checks every field against the rows. The model
stays as it is: no re-fit and no new term (a per-kind term was considered and not taken: docs/INDEX-BUILD.md §10
item 42). Why the model is low there (both
states, both schedules): the kernel's share is predicted within 0.6%, and the gap is in the index callbacks and the
final phase, which spend 20–40k more per extra distinct action kind in a publication than the sum of per-action
marginals (each kind's first touch of its index state is cold; a k2 − k1 marginal sees it once, inside `fixed`).

**41. Identities of the final-step release** (`3ca53ba`: items 32 to 40 together, against `cbf5b78`, the commit the SDK
was pinned to then; its full identity table is this file at `3ca53ba`, and "The identity table" below now compares
against `3ca53ba`). **Moved:** the release digest (`0x9f360a55…f321`, was `0x56bd2f95…2565`), the
plan hash (`0x3b88f634…0a3e`), the execution set (`0x768d8353…dde7`), the index obligations (`0xbc6d4b7d…3a3a`) and
manifest hash (`0x073676c0…2e3c`); the code of `LedgerControl` (reason 14), `RealmIndex` (`BUILT_HOOKS`), `IndexReads`
(the copy, Option A) and the three topic readers (the list-coverage rule): in `artifacts/` exactly these six files
changed; `release/errors.json` (reason 14, `E_PIN` 12, the reworded 12 and `E_BUILD(7)`); `gas/model.json` (the
amsterdam floor price, the composites, the error fields, the re-fit with this release's code, one read bound);
`schemas/efs-gas-model-1.schema.json`; `test/vectors/floor-plan.json` (amsterdam) and the new
`test/vectors/gas-schedules.json`; one ABI snapshot, `IIndexReads.json`. Because the genesis contract embeds the
control delegate's address, every address genesis creates moved with it on the fixture Realm (the ledger proxy
`0xFEd9404A…43Ef`, its implementation `LedgerCore` and ProxyAdmin, the registry proxy and its ProxyAdmin, the
controller, the genesis contract), and so did the realm id and domain separator, both stores (their runtime codehashes
through the embedded ledger address only), the index (`0xC2eD8A21…9bfd`) and its reads contract (`0x519cE2e7…9FC9`),
and every reader that embeds the ledger's address (`lensReader`, `filesPageReader`, the three topic readers, the
gateway and its content contract). **Not moved:** the layout id, the hot ABI ids (release `0xf37d24d0…9856`, test
`0x79a1dd51…cce0`), both store ABI ids, the status vocabulary id, the limits profile id, every Type id, the ingress and
apply delegates, the registry implementation (`TypeRegistry`), the decoder, `ledgerReads`, `ledgerViews`,
`readerDirectory`, `keysView`, every Files and Topics rule, `RefuseAllPolicy`, the Files validator, every ABI snapshot
but `IIndexReads.json`, `vectors/layout.json`, every test vector but the two floor files, the recommended read limits,
and the seed (`efs-fixture-seed/4`, root `0xf7547aa6…c037`). Sizes of the `src/` contracts that changed against
`726993e` (budget 19,660 B): `LedgerControl` 18,042 B (1,618 left), `RealmIndex` 18,834 B (826 left), `IndexReads`
12,431 B, `TopicMineReader` 15,461 B, `TopicEveryoneReader` 16,688 B, `TopicLookupReader` 17,081 B, and
`IndexDeployer` 6,624 B (not a release unit); `LedgerIngress` is unchanged at 19,264 B (396 left). With the `about`
order fix (item 38) `TopicLookupReader` is 17,081 B (2,579 left) and its address `0xE32505C0…d5De`; the read rows of
`about` fell by 273 to 813 gas and `placeCount`'s rose by 3, and no read bound or recommended limit moved.

### The previous release, `6d11858`: formula 3, the registry rule, the kept-index fix and the list tiers (against `3ca53ba`)

Three pieces (formula 3; the registry rule with the kept-index fix; the list tiers), each reviewed alone, built and
tested together on both schedules and regenerated once
(docs/INDEX-BUILD.md §10 item 44 says what had to change where they met). Items 42 to 48.

**42. The index floor's formula is formula 3** (docs/WORK-MODEL-V3.md, design §10.4, §5.11). What a consumer's planner
must change, exactly (`tools/gas-plan.mjs` `quote()` is the reference and the SDK's `kernelQuote` must reproduce it):
- **The work model is 32 words** (`WORK_MODEL_WORDS` 17 → 32), in this order: `formulaVersion` (3); the publish and
  per-publication terms as before; three rows of (fresh ×10, rewrites ×10, compute) — first statement
  (`freshPerBindFirst`, `rwPerBindFirst`, `computePerBindFirst`), re-bind (`freshPerRebind`, `rwPerRebind`,
  `computePerRebind`), other later statement (`freshPerBindLater`, `rwPerBindLater`, `computePerBindLater`);
  `surchargePurpose` (bytes32); the surcharge's three rows (`surcharge{Fresh,Rw,Compute}{First,Rebind,Later}`).
  `freshPerBindFresh`, `rwPerBind` and `computePerHookEffect` are gone; `rwPerBindLater` is now the whole rewrite count of
  a later statement. A reader that finds the manifest's profiles from the raw reply finds them at words 36 and 37.
- **Each BIND, UNBIND or RELEASE adds one row by class:** first statement (the author's head UNSET), re-bind (a BIND on a
  BOUND head: a new target, or the same target with a new number), or another later statement (a mask, a release, a
  restore; a RELEASE always). When the action's purpose word equals `surchargePurpose` (plain equality, as the kernel
  compares them: a statement's purpose is never zero, it is refused `E_SHAPE(leaf, 1)`, so a zero `surchargePurpose`
  surcharges nothing that can be admitted; `test/unit/kernel/Shape.t.sol`
  `test_missing_required_field_is_E_SHAPE_1_for_every_kind` refuses a BIND, an UNBIND and a RELEASE with a zero
  purpose), the surcharge's row of the same class is added too. With no principal (`indexFloor`), every bind adds the largest of the
  three rows field by field, surcharge included.
- **WITHDRAW:** every WITHDRAW after the first of a publication adds the later row (formula 2 charged a withdraw
  `computePerAction` only, 0.12× its callbacks' spend).
- Generation 1's values: first `55, 20, 44,000` (formula 2's quote to the gas on prague), re-bind `20, 40, 42,000`,
  later `20, 50, 85,000`, no surcharge; the publish, per-publication and final terms are unchanged.
- **What the floor claims for masks, releases and restores:** an author's list of up to 1,024 entries at one place (one
  author's entries at one exact topic, address or folder), any number of places in one publication. It covered up to
  4,096 entries and stopped covering from 4,097 (as stated at `6d11858`; since the list release 3,586 on prague and 8,191
  on amsterdam, item 50). Beyond that, nothing a person does fails: before each callback the kernel
  requires the gas left to cover what remains of the quote, so a publication sent with a gas limit from
  `eth_estimateGas` (the least limit at which the whole publication succeeds, callbacks included) and a margin is
  admitted even when a statement's real spend is above the quote; what can fail is a publication sent at or near the
  bare floor, which is refused with `E_INDEX_GAS` and admits nothing. A planner cannot see list lengths, so a batch
  planned at its largest size whose statements meet long lists can need more execution gas than the plan assumed; if
  that passes the 2^24 cap, `eth_estimateGas` fails and the publication is refused at send-time as over the cap,
  nothing sent; the sender splits it and tries again.
- **The exception found after the release: a yes after a lone no** (the tag design review; measured and pinned,
  docs/WORK-MODEL-V3.md §3.5). It is a restore that is the binding's second statement, which the later row's
  third-statement restores do not cover in two ways:
  - **The floor.** `PostingStore._append` at count 1 materializes the binding's history word 0, so in a list of lone
    noes (every live-bits word empty) with the thing linked once the yes writes 3 fresh index slots and rewrites 4,
    against the row's 2.0 and 5.0. Across places, prague covers it in lists of up to 256 entries (1.004), stops at 257
    (0.992) and is at 0.955 at the claim length (1,025); amsterdam, where a fresh slot and a rewrite cost the same
    12,100 of execution, covers every measured cell (1.052 at the claim). At one topic it is covered on both (1,025:
    1.106 / 1.238). What can happen: a publication sent at or near the bare floor is refused `E_INDEX_GAS` with
    nothing admitted, never admitted unindexed. Masks and releases are unaffected (their most is 1 fresh and 5
    rewritten). Pinned by `test_split_lone_no_yes_*` (`test/integration/FloorSplit.t.sol`: the short list, 256 and
    257, the claim length, the unlinked and after-first-yeses variants, one place; per-schedule bands and exact slot
    counts).
  - **The gas model: two fresh slots short.** Besides the index's slot, the kernel writes the binding head's target
    fresh (`src/core/LedgerApply.sol`, `if (head.target != target) head.target = target;`, and a lone no leaves it
    zero); that is kernel gas, outside the floor. Measured whole publications (`test/integration/LoneNoGas.t.sol`)
    against the model with the list tiers: prague all gas −21.57% for 32 yeses across 48-entry lists with the count
    known (short tier), +0.81% with it omitted, −11.94% for 16 across 1,025-entry lists, −13.77% for 51 across
    1,025; amsterdam all gas −10.33% to −29.74%, execution gas −11.47% to +12.54% (the table is in
    docs/WORK-MODEL-V3.md §3.5). The full batch of 51 across 1,025-entry lists costs 15,274,989 gas in all on prague
    and 14,035,893 on amsterdam, both under 2^24; the planner's restore batches are bounded by V, not E, so the shortfall
    moves no planned batch size, and `eth_estimateGas` stays the authority for a gas limit. With the interim rule a
    consumer's E for this shape is about the real cost, which at 51 statements is inside the 15% headroom of the cap,
    so its planner splits the largest batch of this shape a little smaller (46 on prague and 48 on amsterdam in the
    SDK's planner, with the head's slot counted in K; 47 and 50 computed from E alone). **The model's stated
    `maxUnderErrorPercent` (and `maxUnderExecutionErrorPercent`) does not include this shape**: no composite measures
    it. The consumer's interim rule is in "What changes for a consumer" above.
  - **Ruled:** this release keeps its values and names the exception; the next regeneration (the list release) makes
    the later row true (§15, "Open").

**43. Batch sizes** (the planning rule, `tools/gas-plan.mjs`, on the regenerated `gas/model.json`, against the same files
at `3ca53ba`; `test/vectors/floor-plan.json`, whose later-statement shapes pass the measured entry count of their one
place, so the list tiers are applied as a consumer would apply them). Run as a consumer would run it, the tiers do not
move any later shape: every later shape gives the same largest batch with a known short count (48), with the count
unknown (the long tier) and with each statement at a place of its own, because these batches are bounded by the floor's
requirement V, not by the estimate E. The edits shape is the planner's only (`tools/gas-plan-later.mjs`).

| shape | prague `3ca53ba` → now | amsterdam `3ca53ba` → now |
|---|---|---|
| tag masks, releases, masks of masks | 64 → **58** | 44 → **55** |
| tag restores | 60 → **51** | 41 → **51** |
| tag number changes (re-binds) | 60 → **62** | 41 → **64** |
| folder re-binds | 60 → **62** | 40 → **61** |
| edits (PUBLISH child + HEAD re-bind) | 24 → 24 | 23 → **28** |
| lone negatives | 38 → 38 | 50 → **53** |
| create-file recipes | 10 → 10 | 12 → 12 |
| first tags at every depth and state, repeat publishes, name records, a name record and a first tag, the registration chunk | unchanged | unchanged |

**Prague's masks, releases and restores get SMALLER than `3ca53ba`'s:** those were planned on a quote below the real
spend for those statements at distinct places and in long lists (0.91 for a restore of entry 48 across places, 0.75 at
4,096 entries; §15). Re-binds have a row of their own and keep or gain. A planner that reads the model needs only the
formula change of item 42.

**44. Errors and activation.** New `E_WORK_MODEL(uint8 code, uint256 value)`: the ingress reads the work model as raw
words and refuses 1 a failed read, 2 a reply that is not 32 words (a formula-2 index answers 17), 3 a `formulaVersion`
other than 3. New `E_INDEX_NOT_READY` reasons, for a kept index and a new one: 15 the index's work model is not 32
words of the activation's ingress's formula (`ILedgerIngress.formulaVersion()`, new), 16 a word does not fit its field.
New `E_PIN` code 13 (the index's work model could not be held as a data contract). `RealmIndex.workModel()` answers from
a data contract (one STOP byte, then the 32 words), bound by address and codehash; the manifest hash still folds the same
`work` struct, so it commits to the exact words.

**45. Keeping an index never asks its readiness; only its work model is read.** An activation that keeps the live
index (`set.components.index == index()`) used to call `IRealmIndex(index).replayReadiness().phase` for reason 2,
uncaught, so a live index whose readiness no longer answered made every activation that kept it revert with that
index's own error. Now the kept index is pinned by the revision row (its address's code against the set's codehash,
`E_PIN(index, 3)`; the codehash and manifest hash against the current revision row, `E_INDEX_NOT_READY(1)`,
unchanged), **`E_INDEX_NOT_READY(2)` means "the ledger's own publication lock is not IDLE"** (was "its readiness phase
is not IDLE"; the phase the readiness echoed was the ledger's own, and `LedgerCore.activate` and `freeze` are already
idle-gated), and the one thing read from the kept index is its work model (`_checkWorkModel`, reasons 15 and 16 of item
44), the read every publication's quote makes. So a kept index whose readiness reverts still activates and folds like
its twin; a kept index whose every call reverts is refused `E_INDEX_NOT_READY(15)` (it cannot answer its work model, so
it could not serve a publication either); and a kept index that answers a work model of another formula (17 words, or 32
words of version 2) is refused 15, so an implementation never runs its ingress over an index whose work model that
ingress would refuse at the first publication (`test/index/Liveness.t.sol` section 6,
`test/control/WorkModelChecks.t.sol`). `release/errors.json` changes with reason 2's wording. No ABI, no new error.

**46. A build proves a Type's reference count.**
`IndexReplayDecoder` (pinned by every index generation as `DECODER`) no longer reads `typeInfo(id).refCount`. For a
PUBLISH or REUSE leaf it asks the registry for `descriptorBytes(id)`, recomputes the Type id from those bytes (the
registry's derivation: `Keys.typeId(Keys.shape(d), refs, ruleId)` over the leading REF32 fields and header bytes
66..98) and compares it with the record's Type id; on a mismatch it refuses **`E_REPLAY(10)`** (new code; `Errors.sol`
and `release/errors.json`), and the count is the descriptor's number of references. Trusted: the registry answers with
some bytes. Proved: they are the registered descriptor and the count, because the Type id commits to both. A registry
whose `descriptorBytes` reverts makes the decode (`decode`, `payload`) and any `build` or `replayNextPublication` that
reaches such a record revert with the registry's own error. Decoded effects are unchanged for every Type a real
registry registers. No ABI change. Measured (the count read alone, cold / warm; today is `typeInfo`):

| descriptor | prague today | prague proved | amsterdam today | amsterdam proved |
|---|---|---|---|---|
| `realm-notice/1` (239 B, the smallest) | 25,050 / 5,541 | 19,461 / 5,452 | 26,250 / 5,541 | 21,161 / 5,552 |
| `files-content/1` (698 B, the largest in the release) | 25,050 / 5,541 | 20,392 / 6,383 | 26,250 / 5,541 | 22,092 / 6,483 |
| the codec's largest (4,096 B, 8 references) | 25,050 / 5,541 | 27,634 / 13,625 | 26,250 / 5,541 | 29,334 / 13,725 |

In a build (`test/index/BuildGas.t.sol`, measured on this release against the figures of `3ca53ba` in
docs/INDEX-BUILD.md §6): per marginal publication −137 to +609 (prague) and −37 to +709 (amsterdam); the fixed share of a
cold call −5,500 / −5,100 per distinct Type it meets (create file 281,227 → 270,480 on prague, 286,627 → 276,680 on
amsterdam, with 253 gas of formula 3's example-generation code on top: a cold call with nothing pending is 240,681, was
240,428); a later list over §6.2's 1,000,000 files 477,732 → 479,325 a file (+0.33%, prague) and 467,971 → 470,112 of
execution (+0.46%; 575,683 → 577,824 in all, +0.37%, amsterdam), docs/INDEX-BUILD.md §6.2. The decoder's code changed
(5,404 → 5,578 B), so its runtime codehash and its address (CREATE2 of its initcode) move; generation 1's index pins it
as an immutable (`DECODER`, a constructor argument), so the index's runtime codehash and address move with it (item 48).

**47. The gas model prices later statements across places and in long lists.** Consumer change:
`gas/model.json` gains the list tiers (tools/RELEASE.md "The list tiers"; design §10.4), so a planner's E for masks,
releases and restores no longer comes out 14–24% low for later statements at an author's entry 48 or beyond, or in
lists of up to 1,024 entries. One shape is outside this: a yes after a lone no, for which the restore rows are two
fresh slots short (item 42); the maxima below do not include it.

- **New fields** (exact names, `efs-gas-model/1`, all required): top-level `laterLists` (`shortTierMaxEntries` 48,
  `claimEntries` 1,024, `rule`, `note`); per profile `maxUnderErrorPercent`, `maxUnderErrorComposite`,
  `maximaExcludeStates` (`["beyondClaim"]`), and on amsterdam `maxUnderExecutionErrorPercent`,
  `maxUnderExecutionErrorComposite`; `method.laterLists` and `method.maxima` (text). New constants (in `constants`,
  `split.executionGas`, `split.stateGas` and `floor.kernel`): `unbindTagNewPlace`, `releaseTagNewPlace`,
  `restoreTagNewPlace`, `bindTagNumberChangeNewPlace`, `unbindFolderNewPlace`, `releaseFolderNewPlace`,
  `restoreFolderNewPlace`, `bindFolderRebindNewPlace`, and `<row>LongNewPlace` and `<row>LongSamePlace` for
  `unbindTag`, `releaseTag`, `restoreTag`, `unbindFolder`, `releaseFolder`, `restoreFolder`, `unbindProperty`,
  `releaseProperty`, `unbindSame`, `releaseSame`, `restoreSame`, `unbindBroader`, `releaseBroader`, `restoreBroader`
  (36 rows), and `restoreFolder` itself (a folder restore had no row); 37 new constants, each its own pair, none an
  anchor: the tiers change neither `fixed` nor any existing row (both moved with this release's code only, below). New validation `state` values: `acrossPlaces`,
  `acrossPlacesBitsWord`, `longLists`, `beyondClaim`; 39 new composites.
- **What a planner passes** for each later statement: `firstAtPlace` (no earlier later statement of the same
  publication at the same (purpose, subject); omitted: true) and `entries` (the author's entry count at the place,
  `TopicLookupReader.entryCount(author, purpose, place, false, …).count`, when it holds one it trusts; omitted:
  unknown, priced at the 1,024 tier, which is safe). A stale, low count under-prices (up to about 21%), so a count
  older than what the planner trusts is treated as unknown. Re-binds have no tier.
- **The headroom check reads the under-prediction fields**: `maxUnderErrorPercent` on prague and
  `maxUnderExecutionErrorPercent` on amsterdam. The maxima (`maxAbs*` and `maxUnder*`) leave out `beyondClaim`
  composites, which stay listed with their errors; `tools/gas-model.mjs` refuses a model in which any of the four
  exceeds 15%.
- **Regenerated figures** (`gas/model.json`; error = predicted − measured, so an under-prediction is negative). Prague:
  `maxAbsErrorPercent` 11.16% (`validate property masks of 8 entries of 1025 at one topic`, an over-prediction),
  `maxUnderErrorPercent` 9.69% (`validate tag releases at entry 47 across topics`). Amsterdam: `maxAbsErrorPercent`
  12.05% (`validate edit lists exist`), `maxAbsExecutionErrorPercent` 13.9% (`validate tag releases of 32 entries of
  1025 at one topic`, an over-prediction), `maxUnderErrorPercent` 6.73% (`validate create file`),
  `maxUnderExecutionErrorPercent` 10.65% (`validate create file lists exist`); none of these covers a yes after a lone
no (item 42), which has no composite. `maximaExcludeStates` is `["beyondClaim"]`
  on both: the three composites at entry 4,096 of 4,097-entry lists (prague −2.39% to −2.85%, amsterdam −0.33% to
  −0.47% of all gas and −1.64% to −1.82% of execution gas) are listed and not counted. Every maximum is under 15%. The
  tiers move no largest batch (item 43). The constants moved with this release's code, not by a re-fit: `fixed`
  315,854 → 311,787 on prague and 899,174 → 895,683 on amsterdam (the index serves the work model the kernel reads from a
  data contract, item 44), every other existing row −111 to +373 gas; the `tagLevel` terms did not move; 37 constants are new.

**48. Identities of that release** (items 42 to 47 together, against `3ca53ba`, the commit the SDK was pinned to then; its
identity table is in this file's history at `6d11858`, and the table below now compares against `6d11858`). **Moved:** the release digest (`0xc4935467…71e4`, was `0x9f360a55…f321`), the plan hash
(`0x4fc3364f…c575`), the execution set (`0x9c22c034…c9e5`), the index obligations (`0x38ac8541…d78f`) and manifest
hash (`0x755a082e…3537`: the work model is in the manifest); the code of `LedgerIngress` (formula 3), `LedgerControl`
(the work-model checks, the kept-index path), `IndexReplayDecoder` (the proved count), `RealmIndex` (the work model
from a data contract), `IndexReads` (the 32-word `WorkModel`) and `LensReader` (it carries `WORK_MODEL_WORDS`); in
`artifacts/` exactly these six files changed, and `LedgerCore.json` in its ABI only (it lists `E_WORK_MODEL`; its
bytecode is unchanged); `release/errors.json` (`E_WORK_MODEL`, `E_INDEX_NOT_READY` 2 reworded and 15, 16, `E_PIN` 13,
`E_REPLAY` 10); `gas/model.json` (formula 3's floor, the list tiers, the new fields, the kernel's lower `fixed`);
`schemas/efs-gas-model-1.schema.json`, `schemas/efs-deploy-plan-1.schema.json`, `schemas/efs-deployment-1.schema.json`;
`test/vectors/floor-plan.json`; three ABI snapshots (`IIndexReads.json`, `ILedgerIngress.json`, `Errors.json`). The
control delegate embeds the ingress's address and the ledger implementation both, and the genesis contract embeds the
implementation's, so every address genesis creates moved on the fixture Realm: the ledger proxy (`0xe942147e…3429`), its
implementation and ProxyAdmin, the registry proxy and its ProxyAdmin, the controller, the genesis contract; so did the
realm id and the domain separator, both stores (through the embedded ledger address only), the index
(`0x9ca434fC…9f26`) and its reads contract (`0x98de1725…07DF`), the decoder, and every reader that embeds the ledger's
address (`lensReader`, `filesPageReader`, the three topic readers, the gateway and its content contract). **Not
moved:** the layout id, the hot ABI ids (release `0xf37d24d0…9856`, test `0x79a1dd51…cce0`), both store ABI ids, the
status vocabulary id, the limits profile id, every Type id, the apply delegate, the registry implementation
(`TypeRegistry`), `ledgerReads`, `ledgerViews`, `readerDirectory`, `keysView`, the descriptor store, every Files and
Topics rule, `RefuseAllPolicy`, the Files validator, every other ABI snapshot, `vectors/layout.json`, every test vector
but `floor-plan.json`, every read row, bound and recommended read limit on both schedules, and the seed
(`efs-fixture-seed/4`, root `0xf7547aa6…c037`). Sizes of the `src/` contracts that changed against `3ca53ba` (runtime
bytes; budget 19,660 B; tightest first): `LedgerIngress` 19,264 → 18,955 B (705 left), `RealmIndex` 18,834 → 18,408 B
(1,252 left), `LedgerControl` 18,042 → 18,363 B (1,297 left), `LensReader` 17,399 → 17,399 B (2,261 left; six bytes of
code differ), `IndexReads` 12,431 → 12,960 B (6,700 left), `IndexReplayDecoder` 5,404 → 5,578 B (14,082 left).

### The list release (against `6d11858`)

Three pieces, each reviewed alone, built and tested together on both schedules and regenerated once (`f102d1b`): the
list piece (the `head-authors` list, the later row and the HEAD surcharge), the names piece (`files-name/3`, the
word rule's ASCII side, the gateway's `0x` words) and the gas model's rows for later statements (the yes after a lone
no, the measured positions, restores to a new target, HEAD's later rows). Nothing broke where they met: both suites
passed on the joined tree before regeneration (1,495 tests on prague, 1,543 on amsterdam); only three tool tests failed,
each on a generated file the regeneration rewrote. Items 49 to 59. Every figure was measured on this release's code on
both schedules unless it says computed.

**49. Everyone's versions of a file: the `head-authors` list** (QUESTIONS Q52, ruled by James 2026-11-26; design §10.2
family 22, §12.2; docs/WORK-MODEL-V3.md "Landed: the list release"). Consumer change: a new family to read, nothing to
call.

- **The family.** Name `head-authors`, family id `keccak("efs/family/head-authors/1")` =
  `0xd09cf038b483bc20ecd786809b77a653a8554e6c938108cba163338955d06bf8` (`test/vectors/ids.json` `families.head-authors`), kind 22, universe 3 (SCOPE), shape APPEND,
  liveSemantics 3 (HEADS), mandatory, `fromAdmission` 1, in the genesis posting store (the store generation 1's other
  posting families use). Its own family, never HEAD positions in family 20, so that a later generation can stop
  keeping it (declare and fold it no more) and every reader then answers UNKNOWN for it rather than stale counts.
- **Key and entry.** Key `(0, 22, 0, position)` = `Keys.headAuthorsList(position)` with `position =
  Keys.position(HEAD, file, 0)`. Entry: the admission ordinal of each author's first HEAD statement on the file, of
  either sign (creating it, saving one's own version of another's file, or a first "not this"). `count` = the authors
  who ever made a HEAD statement on the file; `live` = the authors whose HEAD there is BOUND now. Each transition: a
  first yes appends counted; a lone negative appends UNCOUNTED (`live` unchanged); a mask or release of a BOUND head
  lowers `live` by 1; a restore (a yes after a lone no included) raises it by 1; a re-bind (every edit) and a mask or
  release of a head that is not BOUND write nothing; no later statement appends an entry. In order of first statement.
- **How to read it, with no new reader or ABI** (`test/index/EveryonesVersions.t.sol`
  `test_show_everyones_versions_of_a_file`, three authors' versions of one file, one masked): `postingHeadOf(head-authors,
  0, 0, position)` at the index (coverage, `count`, `live`), `postingSliceOf(head-authors, 0, 0, position, from, n)` for
  the entries, then `LedgerViews.authorHeads(ledger, position, entries)` for each entry's author, status (PRESENT,
  MASKED, RELEASED) and head (its `target` is the version that author names; 0 when masked or released). No reader
  contract enforces the list's rules here as the topic readers do for theirs, so a client applies four (each checked
  against the code and `EveryonesVersions.t.sol`):
  1. **Coverage is the caller's job.** `postingHeadOf` returns the list's coverage first; an "everyone's versions" read
     answers UNKNOWN unless it is COMPLETE, and never "no other versions". Under a later generation that stops keeping
     the list, a client that skips the check would show an empty list as fact. (The end-to-end test asserts COMPLETE.)
  2. **"N versions" is `live`, not `count`.** `count` includes authors who only ever said no and authors whose version
     is masked or released (`test_every_transition`).
  3. **The order is each author's FIRST HEAD statement, not their latest edit.** An edit writes nothing to the list, so
     "most recently edited first" cannot be read from it; a client reads from the end for "newest author first" and
     sorts a page by the heads it fetched.
  4. **It is a public-tier list.** Anyone can add an entry to any file's list with one HEAD statement from a fresh
     account: for a yes, a revision record naming that file (`FilesFinalValidator` code 8: a `files-root/1` or
     `files-child/1` record whose file word is the subject); for a lone no, only that the subject is a file (code 16: a
     subject created strictly before the statement). Measured for a fresh account (its first publication;
     `GasModel.t.sol` `test_public_head_entry_cost`, log-only): a lone no 550,965 gas on prague, 1,802,923 in all on
     amsterdam (432,043 of execution); a yes with its revision record (a child of the file's root) 965,468 / 3,309,466
     (763,546 of execution). As for the tag bump (QUESTIONS Q54), a client shows its lens authors' versions first and
     labels the rest public.
- **What it costs per file** (measured cold, `test/index/HeadAuthorsFloor.t.sol`, generation 1 with the list against
  the same code before it, the same shapes from the same state): a new file 26,054 gas on prague, 16,154 of execution
  plus 97,920 of state gas on amsterdam (114,074 in all); a second author's version 31,188 / 28,388 + 97,920; a lone
  negative on a file whose list exists 13,683 / 28,083; a mask, release or restore 14,502 to 14,568 / 21,690 to 21,768;
  an edit nothing (223 gas of code placement on both). Reserved for by the HEAD surcharge (item 50).
- **Sizes** (runtime bytes, budget 19,660 B): `RealmIndex` 18,408 → 18,733 (+325; 927 left); `IndexReads` 12,960
  (unchanged: the declaration is constructor code); `PostingStore` 6,651 → 6,699 (its family capacity is 17 ids, was
  16, so one stays spare beside generation 1's sixteen posting families; `FAMILY_CAPACITY()` answers 17, its ABI and
  `STORE_ABI_ID` are unchanged). So generation 1's genesis posting store now holds 16 families with one spare slot:
  another list kept from genesis is a design decision, not a free slot. The posting store's family set and the index's family table each gain `head-authors`
  as their last entry (`tools/deploy-plan.mjs` `POSTING_FAMILIES`, `FAMILY_TABLE`), so the manifest, the posting store's
  constructor data and its codehash move.
- **Coverage and the carried check** need nothing new: the family is declared from admission 1 in a store generation
  1 names, so the carried check, the coverage frontier and the readers' COMPLETE rule hold for it as for family 20
  (`EveryonesVersions.t.sol` `test_the_family_is_declared_in_the_genesis_posting_store`; every suite that counts
  generation 1's families counts nineteen).

**50. The work model's values** (formula 3 unchanged: the same 32 words, `formulaVersion` 3). Consumer change: the
values a planner reads from `gas/model.json` `floor.workModel` (the SDK's `kernelQuote` needs no code change; it
already applies the surcharge by purpose).

| word | field | was | now |
|---:|---|---:|---:|
| 19 | `freshPerBindLater` | 20 | **30** |
| 20 | `rwPerBindLater` | 50 | 50 |
| 21 | `computePerBindLater` | 85,000 | **78,000** |
| 22 | `surchargePurpose` | 0 | **`Purpose.HEAD`** (`keccak("efs/purpose/head/1")`) |
| 23-25 | `surchargeFreshFirst`, `surchargeRwFirst`, `surchargeComputeFirst` | 0, 0, 0 | **10, 10, 4,500** |
| 26-28 | `surchargeFreshRebind`, `surchargeRwRebind`, `surchargeComputeRebind` | 0, 0, 0 | 0, 0, 0 |
| 29-31 | `surchargeFreshLater`, `surchargeRwLater`, `surchargeComputeLater` | 0, 0, 0 | **0, 10, 10,000** |

- **The later row** quotes 177,300 a statement on prague and 182,800 on amsterdam (was 162,200 / 177,700). Its fresh
  count 3.0 is the most fresh index slots a later statement writes (a yes after a lone no: the binding's history word
  0, its live-bits word and its thing's backlink word 0). Its compute is the least that quotes the dearest later
  statement within the claim at the floor's per-action margin as the tests assert it (1.03 prague, 1.05 amsterdam): that is a yes after a lone
  no across places in a list of 1,023 entries, spend 171,832 on prague, which needs 77,687; 78,000 gives 1.031. The
  dearest list within the claim is 1,023 entries, not the longest: each probe of the entry search reads the word that
  holds its entry, so the spend goes with the probes (2,119 / 2,114 gas each across places) and the distinct words they
  read (2,000 each), and 1,023 entries (10 probes, 9 words) costs 2,000 more than 1,025 (10 and 8); the released row was
  below its own claim there (0.944 prague for that yes, 1.039 amsterdam for a restore). The evidence the ruling was made
  on, (30, 50, 72,500) and (30, 50, 79,000), was computed at 1,025 entries.
- **The surcharge** is the list's measured cost (the trial's values, confirmed): a first HEAD statement writes one
  fresh slot and rewrites one (the list's head or word 0, and its head for a later author), +3.6k to +4.0k of other
  work; a mask, release or restore of a BOUND head rewrites the counter, +9.4k to +9.6k; a re-bind nothing. It reserves
  31,600 / 28,700 a first HEAD statement (spend +30,688 to +31,040 / +27,886 to +28,239) and 15,000 / 22,100 a later one
  (+14,422 to +14,500 / +21,623 to +21,701).
- **What the floor claims and covers now** (`test/integration/FloorSplit.t.sol`): every later statement in lists of up
  to 1,024 entries per author per place, at any number of places, at the per-action margin, the yes after a lone no
  included (`test_split_lone_no_yes_*` are ordinary claim tests now; at 1,025 entries 1.043 / 1.082, at 1,023 1.031 /
  1.069). Beyond the claim it covers every later statement across places up to 3,586 entries on prague (the yes after a
  lone no stops from 3,587: 1.007, then 0.996) and up to 8,191 on amsterdam (that yes and a restore of a far entry stop
  from 8,192: 1.008 and 1.007, then 0.997 and 0.996); on prague the restore is covered at 8,192 (1.060) and to 57,346
  entries computed. The 4,096 / 4,097 pair of the formula-3 release is replaced by these.
- **The floor's margin, as the tests assert it and nowhere more** (`FloorSplit.t.sol` `_row`, per action): at least
  **1.03 on prague** for every bind-kind statement and every WITHDRAW after the first inside the claim (PUBLISH, REUSE
  and CREATE, whose terms formula 3 did not change, at least 1.005; lowest measured 1.025, a new name record), and at
  least **1.05 on amsterdam** for every per-action cell inside the claim (each further action of a publication). A publication of ONE action alone is a separate assertion, at least 1.03 on both schedules: the lowest on amsterdam is a single WITHDRAW, priced by the per-publication terms, at 1.034. The binding cell is a yes after a lone no
  across places in lists of 1,023 entries on prague, **1.031**; the lowest on amsterdam is a folder re-bind across
  folders, **1.057**. Why 1,023 is dearer than 1,025: each probe of the entry search also reads the word its entry sits
  in, so the cost follows probes plus distinct words read, not length (10 probes and 9 words at 1,023 entries, 10 and 8
  at 1,025). The claim tests assert the bound on the dearest list lengths: restores, masks and yeses after a lone no at
  1,023 entries as well as at 1,025 (`test_split_claim_masks_at_the_dearest_list_within_the_claim` is new). Why about 3%
  is enough: a callback that runs short refuses the whole publication and admits nothing, and a sender's gas limit
  comes from `eth_estimateGas` with a margin, so the floor's margin guards only a publication sent at or near the bare
  floor. Measured per shape, per action (quote / spend):

  | shape (per action) | prague | amsterdam |
  |---|---:|---:|
  | a yes after a lone no across places, lists of 1,023 (the binding cell) | **1.031** | 1.069 |
  | the same, lists of 1,025 | 1.043 | 1.082 |
  | the same, a lone no after 1,024 first yeses | 1.043 | 1.082 |
  | the same, things unlinked | 1.077 | 1.167 |
  | the same, lists of 48 | 1.374 | 1.324 |
  | the same, at one topic of 1,025 | 1.208 | 1.273 |
  | restores of the last of 1,023 entries across places | 1.145 | 1.068 |
  | restores of a far entry across places, lists of 1,025 | 1.160 | 1.081 |
  | masks of the last of 1,023 entries across places | 1.281 | 1.110 |
  | masks of a far entry across places, lists of 1,025 | 1.299 | 1.124 |
  | folder re-binds across folders | 1.068 | **1.057** |
  | tag first yes | 1.034 | 1.154 |
  | tag first lone negative | 1.133 | 1.207 |
  | tag second author first yes | 1.132 | 1.078 |
  | HEAD first, a second author | 1.467 | 1.438 |
  | HEAD later: a re-bind, a mask, a restore | 1.123, 2.000, 2.016 | 1.184, 1.780, 1.685 |
  | tag later: a number change, a mask, a restore | 1.985, 1.803, 1.817 | 2.233, 1.660, 1.568 |
  | restores of entry 48 across topics | 1.321 | 1.215 |
  | WITHDRAW after the first | 2.615 | 3.157 |
  | a new name record (PUBLISH, formula 2's terms, bound 1.005) | 1.025 | 1.918 |
  | CREATE (bound 1.005) | 1.167 | 1.167 |

  Every `FloorSplit.t.sol` row before → after is in docs/WORK-MODEL-V3.md "Landed: the list release", item 6.

**51. Batch sizes** (the planning rule, `tools/gas-plan.mjs`, on the regenerated `gas/model.json`, against the same files
at `6d11858`; `test/vectors/floor-plan.json`, every shape executed by `FloorPlan.t.sol` on both schedules at its
planned size; edits from `tools/gas-plan-later.mjs`):

| shape | prague `6d11858` → now | amsterdam `6d11858` → now |
|---|---|---|
| tag masks, releases, masks of masks | 58 → **54** | 55 → **54** |
| tag restores | 51 → **48** | 51 → **50** |
| tag number changes (re-binds) | 62 → 62 | 64 → 64 |
| folder re-binds | 62 → 62 | 61 → 61 |
| lone negatives | 38 → 38 | 53 → 53 |
| create-file recipes (5 actions each) | 10 → **9** | 12 → 12 |
| first tags, depth 8 / 64, everything new | 18 / 3 → 18 / 3 | 19 / 3 → 19 / 3 |
| first tags, depth 8 / 64, everything existing | 22 / 4 → 22 / 4 | 20 / 3 → 20 / 3 |
| a second author's first tags, depth 8 | 22 → 22 | 20 → 20 |
| repeat publishes, name records, the registration chunk | 64, 61, 64 → unchanged | 64, 64, 64 → unchanged |
| a name record and a first tag (2 actions each) | 21 → 21 | 27 → 27 |
| edits (PUBLISH child + HEAD re-bind; planner only) | 24 → 24 | 28 → 28 |
| **new:** yeses after lone noes on one topic (`bindTagAfterNo`) | **45** | **48** |
| **new:** create-file recipes at removed names, the name PUBLISH a repeat (5 actions) | **11** | **12** |
| **new:** the same with no name PUBLISH (4 actions) | **13** | **16** |
| **new:** moves into removed names, the name PUBLISH a repeat (3 actions) | **18** | **19** |
| **new:** the same with no name PUBLISH (2 actions) | **25** | **25** |

The later batches are bounded by the floor's requirement V, so the later row's higher quote (+15,100 a statement on
prague, +5,100 on amsterdam, item 50) is what moves masks, releases and restores; number changes and folder re-binds are
re-binds, whose row did not change. Create files on prague lose the tenth recipe to the HEAD surcharge's first row and
the list's own gas (V at 9: 13,027,249); amsterdam stays at 12, where a 13th recipe would pass the 64-action limit. Edits
and lone negatives do not move (the surcharge's re-bind share is zero; TAG statements pay nothing for the HEAD list).
The shapes the SDK's two interim rules priced, as `tools/gas-plan.mjs` plans them: a yes after a lone no at one topic
**45 on prague and 48 on amsterdam** (with the interim rule on the `6d11858` model: 47 and 48); folder restores at one
folder, now priced by the re-measured `restoreFolder` with its kernel rewrite, **48 and 48** (with the SDK's +1 kernel
rewrite on the `6d11858` model: 50 and 48).

**`FloorPlan.t.sol` is the guard that makes stating the kernel's n² term (item 57) safe rather than modelling it.**
For every shape in `test/vectors/floor-plan.json` (22 shapes, the five new ones included) it builds the largest planned
publication from the state the planner assumed and executes it for real on both schedules: the kernel's quote equals
the planner's, the measured execution gas E and the floor's sufficient bound V fit the visible gas of a 2^24
transaction, and on prague the publication also runs with exactly that gas; one unit more is refused by the rule. On
amsterdam Foundry has no 2^24 cap, so there admission under the cap is the arithmetic on the measured E and the
kernel's quote. What it does not cover: shapes that are only gas-model composites and not planned shapes (the
yes-after-no variants, revision-5 restores, HEAD later statements across files, folder after-no shapes, long lists).

**52. The planner's surcharge comparison** (`tools/gas-plan.mjs` `quote()`): the surcharge applies when the action's
purpose word equals `surchargePurpose`, exactly as `LedgerIngress._foldOne` compares them (`a.purpose ==
bytes32(_w(wm, W_SURCHARGE_PURPOSE))`); the planner no longer skips a zero `surchargePurpose`. A statement's purpose is
never zero: the kernel refuses a BIND, an UNBIND or a RELEASE with a zero purpose word `E_SHAPE(leaf, 1)`
(`test/unit/kernel/Shape.t.sol` `test_missing_required_field_is_E_SHAPE_1_for_every_kind`, which existed already), so a
zero `surchargePurpose` surcharges nothing that can be admitted. New planner test: `tools/test/gas-plan.test.mjs`, "the
surcharge applies on plain equality with surchargePurpose, zero included". A consumer whose planner keeps a zero guard
quotes the same for every admissible publication; it should still compare as the kernel does.

**53. The word rule changed and the word Type's id moved, although the label `topic-word/1` did not.** Read the
unchanged label as an unchanged name only, never as an unchanged rule: the acceptance set is smaller, so the rule's
codehash, the `topic-word/1` Type id and every word page and topic id moved (item 59). What `TopicProfile.wordRefusal`
does now:
- **Code 3 is any ASCII byte outside 39 characters.** After the fold a word's ASCII is exactly `a`–`z`, `0`–`9`, `-`,
  `_` and `.` (`WORD_ASCII_OK = 0x7fffffe8000000003ff600000000000`). Every other ASCII byte is refused: capitals,
  space, controls, `/`, `\`, `~` and every other punctuation character. So a word never needs escaping in a link and
  leaves every delimiter free: `c++`, `c#`, `r&b`, `don't`, `q&a` and `~tesla` are no longer words; `cpp`, `.net`,
  `sci-fi`, `model_3`, `0xsplits` and `con` are.
- **Code 4 now means "the word ends with `.`".** It covers `.` and `..` (which it refused before) and also `...`, `a.`
  and `inc.`; `.a`, `a.b` and `a..b` are admitted. The reason is link trimming (an auto-linker drops a full stop after
  a pasted link, so `/inc.` would open `/inc`): the tag design session's proposal, not a consequence of the ruling.
- **Code 9 is new: the word starts with `-`.** `-x`, `-` and `--x` are refused; a `-` elsewhere stays admitted
  (`a-b`, `a-`, `a--b`). It keeps `-word` free to mean "not" in EFS link syntax (the founder's test that words leave
  delimiters free); it is the tag design session's default applied by the integration owner, not the founder's words.
  It is 9, not 8: `E_TOPIC_REFUSED(8)` is already `TopicWordRule`'s "refs present".
- **Code 5 can no longer happen.** It meant "starts with `~`"; a `~` is now code 3 wherever it stands, so the branch is
  gone. The number is left unused, not reused: no code changes meaning.
- Unchanged: 1 (length), 2 (malformed UTF-8), 7 (a scalar of `REFUSED`; the table and its classes are untouched), 6
  (`0x` and exactly 40 of `0-9a-f`) and 8 (refs). The order: 1, then 2, 3 and 7 by position, then 4, then 9, then 6
  (so `-a.` is 4). Windows device names are words.
- **What the SDK's `checkWord` must change:** admit exactly the 39 ASCII characters (code 3 for every other ASCII
  byte, `~` included); return 4 for a trailing `.` instead of 4 for `.`/`..` only; add 9 for a leading `-`, checked
  after 4 and before 6; never return 5; keep everything else. `test/vectors/topics.json` (`grammar.wordAscii`,
  `grammar.wordCodes`, `grammar.wordCodeUnused`) carries every ASCII byte alone and inside a word, the trailing `.` and leading `-` cases (`-x`, `-`, `--x`, `-a.`, `a-`, `a-b`,
  `x-`) and `~` first, inside and last.
- **The order of refusals, so `checkWord` returns the chain's FIRST refusal, not only its verdict:** 1 (length);
  then, scanning the word from its first byte, the first of 2 (malformed UTF-8), 3 (an ASCII byte outside the 39) or
  7 (a refused scalar); then 4 (ends with `.`), then 9 (starts with `-`), then 6 (`0x` and 40 hex). So `-a.` is 4,
  `-A` is 3, `A.` is 3, and `0x` + 40 hex digits + `.` is 4. 4 and 6, and 9 and 6, can never both apply.
  `topics.json` holds a vector for every pair of rules that can both apply (labels `pair …`), with the chain's code.

**54. File names are `files-name/3`, which replaces `files-name/2`.** The label changed everywhere it names the live
grammar (`FilesTypes`, `EfsFiles`, the readers, the validator, the tools, the gas model's row keys, the vectors); a
planner that keys on the string `files-name/2` must key on `files-name/3`. On top of everything `files-name/2` refused
(1 to 255 bytes, strict UTF-8, controls, `/` and `\`, the bidi, invisible and noncharacter sets, whitespace first or
last, the `~efs` prefix), a name now refuses:
- **URI meaning:** `#`, `?`, `%` (each changes what a pasted link means).
- **A delimiter kept free for EFS URL syntax:** `<`, `>`, `"`, `|`, `:`, `*`, `;`. The syntax is not designed; only
  the reservations are made. `;` is reserved so a parser can split parameters at `;` first, which is why `=` and `!`
  stay.
- **Link trimming:** a name ending in `.` (also `.` and `..`, refused before). The integration owner's application,
  not James's ruling, and a check of its own so it can be dropped alone.

Admitted as before: inner spaces, `& ( ) ' , + = ! @ $ [ ] { } ^ ~`, backtick, `-`, `_`, leading dots, a leading `-`,
everything outside ASCII that `/2` admitted, and Windows device names (`con`, `nul.txt`, `COM1`, `NUL .txt`). So
`Q&A #3.pdf`, `50%.txt`, `what?.md`, `a;b`, `a:b`, `a*b`, `a<b`, `a>b`, `a|b`, `a"b` and `inc.` are no longer file
names; `Q&A 3.pdf`, `logo@2x.png`, `~$Budget.xlsx`, `Sale!.png` and `-notes.txt` are (a tag word refuses a leading `-`;
a file name does not). The descriptor descriptions of `files-name/3` and `topic-word/1` (part of their Type ids) now state these rules.
The ASCII bitmap is
`ASCII_OK = 0x6fffffffefffffff23ff7bd300000000` (83 bytes of 0x20..0x7e). The refusal code is unchanged
(`E_FILES_REFUSED(2)`; 1 refs). Of the naming experiment's 50 vectors, six change verdict (5, 6, 12, 45, 46, 47).
**What the SDK must change:** refuse the ten new ASCII characters and a trailing `.` before planning, and use the label
`files-name/3`. Names stay byte-exact and case-sensitive.

Measured (`FilesNameRule.accept`, the rule's own warm frame including the context decode, `6d11858` → this release;
the new checks sit after the loop, so the ASCII path is still one bitmap test per byte): 10-byte ASCII `readme.txt`
3,400 → 3,373; 255 ASCII bytes 43,580 → 43,553; 10 bytes of CJK 5,060 → 4,983; 255 bytes of CJK 113,077 → 110,925.
`FilesNameRule` runtime 1,683 → 1,627 B (the trailing `.` test replaced the `.`/`..` test, and `excluded` now reads
the same bitmap for ASCII); `TopicWordRule` 1,897 → 1,934 B (the leading `-` test). Both are far inside the 19,660 B budget.

**55. The gateway follows the chain's rule 6.** A first path segment that starts `0x` and is not an address is a
topic word, as on the chain and in the SDK's links. Only `0x` (or `0X`) followed by exactly 40 hex digits, of either
case, is an address (a home), and that handling is unchanged byte for byte: `0X` + 40 hex is an address, never a word
(the chain refuses it as a word anyway, code 3). Every other `0x` segment, `/0xsplits`, `0x` and 39, 41 or 64 hex
digits, or 40 characters with one that is not hex, is a word, so the path is a topic path and answers what every topic
path answers today, `501 topic paths are not served`, where it was `400 malformed id`. The gateway does not run the word
rule: `/0Xabc` (not a valid word on chain) is 501 too, as is an unregistered word. `400 malformed id` remains for
object and revision ids (`/~efs/o/…`, `/~efs/v/…`). `EfsWeb3Gateway` 15,391 → 15,565 B (4,095 B left); `EfsWeb3Content` unchanged
(8,961 B; the path grammar is the gateway's alone).

**56. Vectors.** New `test/vectors/names.json` (`efs/vectors/names/1`, `tools/name-vectors.mjs`): 653 names, 398 admitted: every
ASCII byte 0x00 to 0x7f alone and at the start, middle and end of a name (512 rows), the examples of the rulings, the
trailing `.` cases, Windows device names as admitted names, the `~efs` prefix, malformed UTF-8 and the non-ASCII
refusals and boundaries of `files-name/2`'s tests, lengths 0, 1, 255 and 256, and the 50 naming-experiment vectors of
`test/profiles/FilesNameVectors.sol` (the tool reads that file and refuses to generate if its grammar disagrees with a
verdict there). Every row
has the verdict, the rule code (0 or 2), an informative first-failed check, the role (`keccak256(name)`) and, when
admitted, the record id for this release's `files-name/3` Type id. `test/vectors/topics.json` grows to 489 words and 45 texts (every ASCII byte alone and inside a word, `~` first, inside and last, the trailing `.` and leading `-` cases, and a vector for every pair of rules that can both apply) and adds `grammar.wordAscii`, `wordAsciiRulings`, `wordAsciiNote`, `wordTrailingDot`, `wordLeadingDash` and `wordCodeUnused`; `wordCodes` lists 9 and no longer lists 5.
`pnpm release` writes both, `pnpm release:check` compares both byte for byte (`names.json` is listed in
`release.json` `vectors` beside the others), `node tools/name-vectors.mjs --check 1` compares the name file alone, and
`test/profiles/NameVectors.t.sol` and `TopicVectors.t.sol` assert every row against the rules.
`test/vectors/floor-plan.json` gains five shapes (item 51). Against `6d11858` the vectors that moved are `names.json`
(new), `topics.json`, `floor-plan.json` and `ids.json` (the `head-authors` family, item 49); every other vector and
`vectors/layout.json` are unchanged.

**57. The gas model's new rows** (`gas/model.json`, `efs-gas-model/1`; `test/integration/GasModel.t.sol` sections 4, 9
and 10). Consumer change: new constants and fields, a selection rule, a symmetric correction, a restated bound, and
the end of the interim rules ("What changes for a consumer" above).

- **A BIND on a head that never bound: `bind<Purpose>AfterNo`.** A planner tells the shape from the head it reads:
  `state != UNSET && targetKind == 0` (`Head.targetKind` is served as stored and is 0 exactly for a head that never
  bound; `Head.target` is canonical, 0 for every head that is not BOUND; pinned by `test/readers/HeadTargetKind.t.sol`
  over five sequences through `LedgerViews.headsAt` and `historyAt`: a lone no; no, release; no, no give 0; yes, mask;
  yes, release give the bound kind; `target` is 0 in all five). Each row is measured as the yes directly after a lone
  no (revision 1 before it: the binding's history word 0 opens, and the kernel writes the head's stored target
  fresh), with the target already linked once elsewhere (its backlink word 0 opens: the dearest state). Rows (all gas
  and kernel share K on prague; all gas, execution gas and K on amsterdam):

  | row | prague | K | amsterdam | execution | K |
  |---|---:|---:|---:|---:|---:|
  | `bindTagAfterNo` | 230,603 | 113,847 | 699,403 | 209,803 | 91,247 |
  | `bindTagAfterNoNewPlace` | 228,961 | 113,823 | 704,961 | 215,361 | 91,223 |
  | `bindTagAfterNoLongNewPlace` | 286,421 | 113,823 | 850,407 | 262,887 | 91,223 |
  | `bindTagAfterNoLongSamePlace` | 264,473 | 113,823 | 740,473 | 250,873 | 91,223 |
  | `bindFolderAfterNo` | 245,320 | 113,847 | 714,120 | 224,520 | 91,247 |
  | `bindFolderAfterNoNewPlace` | 237,572 | 111,835 | 713,584 | 223,984 | 89,247 |
  | `bindFolderAfterNoLongNewPlace` | 295,008 | 111,811 | 859,042 | 271,522 | 89,259 |
  | `bindFolderAfterNoLongSamePlace` | 275,084 | 113,835 | 751,084 | 261,484 | 91,235 |
  | `bindPropertyAfterNo` | 210,215 | 109,639 | 679,027 | 189,427 | 87,051 |
  | `bindPropertyAfterNoLongNewPlace` | 269,764 | 111,729 | 826,550 | 239,030 | 89,129 |
  | `bindPropertyAfterNoLongSamePlace` | 249,815 | 113,729 | 718,615 | 229,015 | 91,129 |
  | `bindSameAfterNo` | 212,448 | 111,627 | 681,272 | 191,672 | 89,051 |
  | `bindSameAfterNoLongNewPlace` | 269,907 | 111,627 | 826,681 | 239,161 | 89,015 |
  | `bindSameAfterNoLongSamePlace` | 247,958 | 111,627 | 716,770 | 227,170 | 89,039 |
  | `bindBroaderAfterNo` | 212,483 | 111,639 | 681,247 | 191,647 | 89,003 |
  | `bindBroaderAfterNoLongNewPlace` | 269,942 | 111,639 | 826,728 | 239,208 | 89,039 |
  | `bindBroaderAfterNoLongSamePlace` | 248,017 | 111,663 | 716,793 | 227,193 | 89,039 |
  | `bindHeadAfterNo` | 232,677 | 109,317 | 708,665 | 219,065 | 86,705 |

  The tiers follow the restore rows' pattern and rule (`laterLists`); HEAD has none (below). FOLDER was measured, not
  assumed equal to TAG: its after-no row is 14,717 gas dearer on prague (the Files validator's folder laws on a BIND)
  with the same kernel share. A lone no on HEAD is admissible (the validator's code 16 asks only that the subject is
  a file created before it), so HEAD has its row, measured as a second author's "not this" and then its yes naming the
  root the first author's HEAD names. Against the restore rows the yes after a lone no costs the kernel's fresh target
  slot and the history word (prague `bindTagAfterNo` 230,603 against `restoreTag` 187,453).
- **Restores to a new target. `restoreFolder*` IS RE-MEASURED.** A FOLDER, PROPERTY or HEAD restore can name a target
  other than the stored one, which the kernel rewrites (`LedgerApply`: `if (head.target != target) head.target =
  target;`); a planner cannot tell (the head view does not show the stored target), so these restore rows are measured
  restoring to a NEW target already placed elsewhere (the kernel's rewrite plus the target's backlink word opening: the
  dearest restore). Old (`6d11858`) → new:

  | row | prague | K | amsterdam | execution | K |
  |---|---|---|---|---|---|
  | `restoreFolder` | 208,066 → **211,159** | 93,818 → **96,759** | 508,092 → **518,385** | 214,332 → **224,625** | 81,118 → **91,259** |
  | `restoreFolderNewPlace` | 200,330 → **203,411** | 91,818 → **94,747** | 507,544 → **517,849** | 213,784 → **224,089** | 79,106 → **89,259** |
  | `restoreFolderLongNewPlace` | 257,778 → **260,859** | 91,806 → **94,735** | 653,058 → **663,351** | 261,378 → **271,671** | 79,106 → **89,247** |
  | `restoreFolderLongSamePlace` | 237,830 → **240,923** | 93,806 → **96,747** | 545,056 → **555,349** | 251,296 → **261,589** | 81,106 → **91,247** |

  New, the same way: `restoreProperty` (a label masked, then set to a different text that is used as a label
  elsewhere) 176,042 / K 92,539 on prague, 483,290 / 189,530 / 87,027 on amsterdam, with `restorePropertyLongNewPlace`
  235,603 / 94,641 and 630,871 / 239,191 / 89,129 and `restorePropertyLongSamePlace` 215,642 / 96,629 and 522,868 /
  229,108 / 91,129 (PROPERTY has tiers; its rows are already at distinct subjects, so no `NewPlace`); HEAD's later rows,
  which HEAD did not have beyond `bindHeadRebind`: `unbindHead` 160,801 / 62,028 and 372,841 / 177,001 / 59,228,
  `releaseHead` 159,615 / 60,819 and 371,655 / 175,815 / 58,019, `restoreHead` (to a new revision a second author's
  HEAD names) 198,533 / 92,199 and 512,993 / 219,233 / 86,699. HEAD has no tiers: a file's HEAD scope list holds one
  entry per author, the HEAD itself, so every HEAD statement is at a list of one entry and at a place of its own, and
  the HEAD rows are measured at distinct files. The measured over-price of a restore to the STORED target, in each
  row's `laterRows` note: `restoreFolder` 2,941 gas on prague and 10,141 on amsterdam (all of it execution and kernel),
  `restoreProperty` 2,929 / 10,117, `restoreHead` 2,952 / 10,164. No same-target row is added (a planner could not
  select it). TAG, SAME and BROADER restores cannot name a new target (the target is the role).
- **The measured position of every later row: `laterRows`** (new, top-level, required; `schemas/efs-gas-model-1.schema.json`).
  `laterRows.rows` maps each of 79 later-row constants to `{ revisionBefore, opensHistoryWord, target }` (`target`:
  `"same"`, `"new"`, `"neverBound"`, or null for an UNBIND or RELEASE), with a `note` on the new-target restore rows.
  Examples: `bindTagAfterNo` `{ revisionBefore: 1, opensHistoryWord: true, target: "neverBound" }`;
  `restoreFolderLongNewPlace` `{ revisionBefore: 2, opensHistoryWord: false, target: "new", note: … }`. Masks, releases
  and re-binds are measured at revision 1 (the word opens), restores at revision 2 (none opens). `laterRows.rule` is
  the selection rule (UNBIND/RELEASE → `unbind<P>`/`release<P>`; BIND on BOUND → the re-bind row; BIND on MASKED or
  RELEASED → `bind<P>AfterNo` when `targetKind == 0`, else `restore<P>`; then the list tiers) and the correction:
- **The history-word correction is symmetric** (ruled). The binding's history list takes one entry per statement of
  every kind (`RealmIndex._foldBind`, first statements included), so its length before a statement is the head's
  revision, and `PostingStore._append` opens a word when that count is 1 or a positive multiple of 5. When an action
  carries `revisionBefore` (`tools/gas-plan.mjs` `historyWordAdds`): add the profile's new constant `historyWordOpen`
  if the row's `opensHistoryWord` is false and the position opens a word; subtract it if the row's is true and the
  position opens none; without `revisionBefore` the row is used as it is. `historyWordOpen` =
  `restoreTagAtHistoryWord` − `restoreTag` (the same restore as the binding's sixth statement against its third, the
  backlink list at one entry before both): **17,100 on prague; 97,920 of state gas and 0 of execution on amsterdam**;
  its kernel share is 0. A stale revision cannot turn the subtraction into an under-priced success: the kernel
  refuses a BIND, an UNBIND and a RELEASE alike whose `expectedRevision` is not the head's (`E_CAS`, nothing written;
  `LedgerApply._applyBind` and `_applyMaskOrRelease`; new test `test/unit/kernel/Strength.t.sol`
  `test_stale_expected_revision_refused_for_bind_unbind_and_release`, a revision too low and too high, from BOUND and
  from MASKED, for all three kinds).
- **The property of the worst-case rows** (measured, both schedules). Every restore and yes-after-no row is measured
  with its target's backlink list at a word-opening count (one entry before it). A planner cannot see that list, so the
  rows are the dearest state, and a statement whose target's backlink list is at another count is over-priced by one
  fresh slot less a rewrite: measured, a third-statement restore whose thing's backlink list holds two entries costs
  **17,073 less on prague and 97,920 less state gas (115 more execution) on amsterdam** than `restoreTag` (one entry).
  On prague that is 9.7% of the cheapest such row (`restoreSame`, 175,382) and 5.8% of the dearest
  (`bindFolderAfterNoLongNewPlace`, 295,008), 11.7% of the cheapest later row of any kind (`releaseProperty`); on
  amsterdam 20.6%, 11.4% and 28.0% of all gas. This is where amsterdam's 18.42% comes from (a restore deep in a toggled
  binding, below). A consumer that sets a gas limit as a multiple of the model's total should know the worst
  over-statement of the total for these shapes: about **1.18×** on amsterdam all gas (execution gas is within ±1% for
  them).
- **The composites** (39 new, 89 in all per profile; error = predicted − measured over measured; prague all gas;
  amsterdam all / execution): yeses after lone noes across 32 topics of 48 entries −7.11% / −2.29%, −7.32%; across 32
  of 256 +2.27% / +0.88%, +2.69%; across 16 of 1,025 +0.22% / +0.32%, +0.63%; 32 of 1,025 at one topic +7.05% /
  +2.01%, +11.52%; no → release → yes and no → no → yes across 32 topics −0.75% / −0.10%, −0.54%; restores at revision
  5 across 32 topics +7.58% / **+18.42%**, −0.58%; the folder equivalents (yeses after hides across 32 folders −0.17%
  / +1.13%, −0.61%; hide → release → yes and hide → hide → yes −0.19% / +1.29%, −0.67%; at entry 1,024 across 16
  folders −0.02% / +0.24%, +0.38%; 8 of 1,025 in one folder +7.24% / +3.37%, +9.64%; restores to new targets across
  32 folders −0.93% / −0.16%, −0.62%); HEAD masks, releases, restores to new revisions and yeses after lone noes across
  32 files −0.75% to −0.91% / −0.10% to −0.14%, −0.54% to −0.57%; creates at removed names and moves into removed
  names, each with the name PUBLISH a repeat (`publishExisting`) and with no name PUBLISH (an SDK omits it when the name
  record exists), at 2 and at the planner's largest batch on each schedule (create 11 and 12, 13 and 16; move 18 and
  19, 25), with the same batches at fresh names beside them: E between −3.59% and +3.16% on prague, −6.63% and +7.65%
  of all gas and −4.07% and +6.30% of execution on amsterdam. The 51-statement yes-after-lone-no batches stay log-only
  in `test/integration/LoneNoGas.t.sol` (each 51 × 1,025 state is 52,275 lone noes, about a minute a profile).
- **The stated maxima and what the 15% refusal bounds** (ruled; `tools/gas-fit.mjs` `overBound`, `method.maxima`,
  `planning.headroomCovers`). Under-predictions above 15% are refused everywhere (prague all gas, amsterdam all gas,
  amsterdam execution); over-predictions above 15% are refused on the gas the 2^24 cap counts (prague all gas,
  amsterdam execution); amsterdam's all-gas over-prediction is refused per composite above `allGasOverBoundPercent` =
  15 + laterStatements × 97,920 × 100 / measured (the schedule's `freshSlot.stateGas` from `GAS_SCHEDULES`, not a
  typed number; both new per-composite fields are in the model). Tool tests: a synthetic composite over its bound for
  another reason is refused, one at the edge passes (`tools/test/gas-fit.test.mjs`). New fields on both profiles
  `maxOverErrorPercent` and `maxOverErrorComposite`, on amsterdam also `maxOverExecutionErrorPercent` and its
  composite (added on prague as well for a regular schema: there the over-prediction of all gas is a bound).
  `maxAbsErrorPercent` keeps its field and is the larger of the under- and over-prediction on all gas, so a consumer
  that reads it sees 18.42 on amsterdam with the composite named; on amsterdam it is stated, not bounded at 15%.
  `maximaExcludeStates` stays `["beyondClaim"]`; no composite is excluded to pass a bound. The figures (against
  `6d11858`):

  | figure | prague | amsterdam |
  |---|---|---|
  | `maxUnderErrorPercent` (all gas) | 9.69 → **9.68** (tag releases at entry 47 across topics) | 6.73 → **6.63** (move 2 files to fresh names, name published) |
  | `maxOverErrorPercent` (all gas) | **11.15** (property masks, 8 of 1,025 at one topic) | **18.42** (tag restores at revision 5 across 32 topics; its bound 33.55) |
  | `maxAbsErrorPercent` (all gas) | 11.16 → **11.15** | 12.05 → **18.42** |
  | `maxUnderExecutionErrorPercent` | | 10.65 → **10.52** (create file, lists exist) |
  | `maxOverExecutionErrorPercent` | | **13.89** (tag releases of 32 of 1,025 at one topic) |
  | `maxAbsExecutionErrorPercent` | | 13.9 → **13.89** |

  The five composites past 15% of amsterdam all gas under the add-only rule, against the bound as implemented
  (symmetric rule): no → release → yes and no → no → yes across 32 topics −0.10% (bound 30.40%); hide → release → yes
  and hide → hide → yes across 32 folders +1.29% (30.41%); restores at revision 5 across 32 topics +18.42% (33.55%).
  **Amsterdam's execution under-prediction is 10.52%, against the SDK tripwire's firing point of 10.74%: 0.22 points to
  spare.** The SDK dev should know that margin before re-vendoring.
- **The kernel's share K is low for large publications, by a term in n²** (stated in this release, modelled at the next
  regeneration). The rows are 1 → 2-action marginals; the kernel's cost of one more action grows with the actions
  already in the publication (`test/integration/KernelGrowth.t.sol`, both schedules: one more CREATE costs the kernel
  89,259 gas in a publication of 1 and 96,353 at 32 → 60; a fresh name PUBLISH 161,207 → 170,990; a repeat name PUBLISH
  97,205 → 106,987; a TAG mask 62,212 → 69,723). The cause is memory expansion, **confirmed from one trace**
  (`test_growth_memory_trace`, run with Foundry's debug tracer: the ledger frames' peak memory grows by 200 words an
  action, 16,160 B at 2 CREATEs and 54,560 B at 8; 3·W + W²/512 then rises by about 2 × 200² / 512 ≈ 156 gas per action
  already present, the measured slope). Model K against the measured kernel gas:

  | publication | prague: removed names | prague: fresh names | amsterdam: removed names | amsterdam: fresh names |
  |---|---|---|---|---|
  | 16 creates, no name PUBLISH (64 actions) | −257,968 (−2.70%) | −255,992 (−2.22%) | −258,724 (−3.76%) | −256,784 (−3.34%) |
  | 25 moves, no name PUBLISH (50 actions) | −184,567 (−4.20%) | −182,831 (−2.44%) | −184,467 (−4.46%) | −182,431 (−3.40%) |
  | 12 creates, name PUBLISH (60 actions) | −278,042 (−3.28%) | −62,042 (−0.58%) | −278,874 (−4.43%) | −63,162 (−0.88%) |
  | 19 moves, name PUBLISH (57 actions) | −303,810 (−5.64%) | +31,286 (+0.35%) | −303,558 (−6.15%) | +31,286 (+0.49%) |
  | 2 creates, no name PUBLISH (8 actions) | +3,123 (+0.22%) | +5,123 (+0.31%) | +3,027 (+0.30%) | +5,039 (+0.45%) |

  In gas the shapes the interim rules priced are short by the same amount as an ordinary batch of the same size
  without a name PUBLISH; with one, the fresh-name batch looks better only because the fresh name PUBLISH row
  over-prices its own kernel share by about 18k in a large batch, which hides the same term. **V is low by the same
  term** (V carries K). The exposure, exactly: a batch planned at the edge of the cap may be refused at send-time as
  over the cap (`eth_estimateGas` fails) and re-split; it is never sent short. E carries the same term, inside its
  stated under-prediction figures above. A repeat name PUBLISH is priced by `publishExisting` (measured on a bytes
  record): measured alone it costs the kernel 1.8k more than the bytes repeat, and the rest of what looked like its
  gap is this term, so no constant of its own is added.
- **Unchanged:** every other row's name and meaning, `fixed` (311,787 on prague; 895,683 → 895,695 on amsterdam, +12,
  code placement) and the anchors' method; against `6d11858` every other constant moved by at most 321 gas except
  `bindHeadFresh` (+25,794 prague, +113,826 amsterdam: the `head-authors` list, item 49). Against the list piece alone
  (before these rows) no existing row moved by more than 0.04%.

**58. Tests and the harness** (no consumer change). The step-3b harness (`test/harness/HeadAuthors.sol`) can no
longer add `head-authors` later, since generation 1 keeps it; its example list is now `file-versions` (provisional
kind 24, the same key shape, entry and fold, in the third store), a second copy of `head-authors` under another id,
and the build-from-history suites also check that it equals generation 1's own list file by file (docs/INDEX-BUILD.md
§2.2). `test/index/EveryonesVersions.t.sol` is new. The build's measured unit costs (`test/index/BuildGas.t.sol`)
moved by +20 gas a HEAD publication and +9,526 on the fixed share of a cold build call, on both schedules (the copy of
the live manifest the carried check reads holds one more family). The §6.2 figures for a million files, the record the
Q52 ruling was made on, stay as they are; computed with this release's units the same build would cost about 0.3B gas
more on each schedule (+0.06%: 479.6B on prague, 470.4B of execution on amsterdam). A cold segment of 20 files
(`test_mixed_segment`) measured 9,684,204 on prague and 9,483,004 of execution on amsterdam (was 9,674,178 and
9,472,978).
The second piece adds (no consumer change): `test/readers/HeadTargetKind.t.sol` (item 57); `test/unit/kernel/Strength.t.sol`
`test_stale_expected_revision_refused_for_bind_unbind_and_release` (item 57); `test/integration/KernelGrowth.t.sol`
(the kernel's marginal cost per action at n = 1, 2, 8, 16, 32 and 60 for CREATE, a fresh and a repeat name PUBLISH and a
TAG mask, logged on both schedules with a band on the slope, and the one memory trace, which runs only under Foundry's
debug tracer and a raised gas limit: `forge test --match-test test_growth_memory_trace -vvv --gas-limit 100000000000`,
skipped otherwise; the suite runs in under a second); five `FloorPlan.t.sol` shapes (item 51);
`FloorSplit.t.sol` `test_split_claim_masks_at_the_dearest_list_within_the_claim` (masks of the last of 1,023 entries:
1.281 / 1.110); GasModel.t.sol section 10 and the rows of item 57; `tools/test/gas-fit.test.mjs` (the bound) and
`tools/test/gas-plan.test.mjs` (the symmetric correction, the measured positions, the over-prediction fields).
`LoneNoGas.t.sol` keeps only what the model does not measure (the 51-statement batches and 32 at one topic of 48 and of
256), logged.

**59. Identities of this release** (items 49 to 58 together, against `6d11858`, the commit the SDK is pinned to; every
value is in the table below). **Moved:** the release digest (`0xe6972acb…8612`, was `0xc4935467…71e4`), the plan hash
(`0x2206022b…e509`), the execution set (`0x478c92b5…7d24`), the index obligations (`0xd1ec8dd9…eb20b`) and manifest
hash (`0x14f48551…e148`: the manifest has `head-authors` and names the validator unit, whose address moved); the Type
ids of `files-name/3` (`0x20665824…8c8d`, was `files-name/2` `0x2b4d22da…c27a`), `topic-word/1` (`0xe7429381…3859`,
was `0xadf365a3…886b`) and `topic/1` (`0x275a99cc…bfde`, was `0x4ea9b8b2…d4cf`; its rule names the word Type), so every
name record id, word page id and topic id; the rule codehashes of `FilesNameRule` (`0xd73a9ee2…fd17` →
`0x80c8f4aa…9308`) and `TopicWordRule` (`0x29442a0e…dfd5` → `0xee656292…edac`) and their instances; the addresses
of `TopicRule` (same code, the new word Type id in its initcode) and `FilesFinalValidator` (constructor Type ids); the
code and address of `PostingStore` (its family set and capacity), `RealmIndex`, `IndexReads`, `FilesPageReader`,
`TopicLookupReader` and `EfsWeb3Gateway` (each embeds a moved Type id or address; `RealmIndex` and the gateway's code also
changed, items 49 and 55); `release/errors.json` (`E_TOPIC_REFUSED`'s list of codes); `gas/model.json` (item 57);
`schemas/efs-gas-model-1.schema.json`; in `artifacts/` exactly `EfsWeb3Gateway.json`, `FilesNameRule.json`,
`IndexReads.json`, `PostingStore.json`, `RealmIndex.json` and `TopicWordRule.json`; `test/vectors/floor-plan.json`,
`ids.json`, `topics.json` and the new `names.json`. **Not moved:** the layout id, the hot ABI ids (release
`0xf37d24d0…9856`, test `0x79a1dd51…cce0`), both store ABI ids, the status vocabulary id, the limits profile id, every
ABI snapshot (`pnpm abi:snapshot` wrote none), `vectors/layout.json`, the kernel (`LedgerCore`, `LedgerIngress`,
`LedgerApply`, `LedgerControl`), the ledger proxy (`0xe942147e…3429`) and every genesis address, the realm id and
domain separator, the registry, `ledgerReads`, `ledgerViews`, `IndexReplayDecoder`, the bitmap store, `LensReader`,
`TopicMineReader`, `TopicEveryoneReader`, `EfsWeb3Content`, `KeysView`, `ReaderDirectory`, every other rule and Type
id, the limits, the work model's shape (its values moved, item 50, and are in the manifest), every read bound, and the
seed (`efs-fixture-seed/4`, root `0xf7547aa6…c037`; its names `docs`, `readme.txt`, `big.bin` and `remote.txt` are
all `files-name/3` names). Sizes of the `src/` contracts whose code changed against `6d11858` (runtime bytes; budget
19,660 B; tightest first): `RealmIndex` 18,408 → 18,733 B (927 left), `TopicLookupReader` 17,081 → 17,081 B (2,579 left;
an embedded id), `EfsWeb3Gateway` 15,391 → 15,565 B (4,095 left), `FilesPageReader` 12,676 → 12,676 B (6,984 left; an
embedded id), `IndexReads` 12,960 → 12,960 B (6,700 left; an embedded address), `PostingStore` 6,651 → 6,699 B (12,961
left), `TopicWordRule` 1,897 → 1,934 B (17,726 left), `FilesNameRule` 1,683 → 1,627 B (18,033 left).

### The identity table (this release against `6d11858`)

Read from `release/release.json`, `deploy/plan.json` and the sample `release/efs-deployment.json` (default fixture
configuration: chain 31337, salt `keccak256("efs/fixture/realm/1")`) of this release, against the same files at
`6d11858` (`git show 6d11858:<file>`), the commit the SDK is pinned to; the ABI ids are computed from
`test/snapshots/abi/` with `tools/abi-id.mjs` (no snapshot changed, so none moved; the test id `efs/ledger-hot/2:test`
is `0x79a1dd51f600e8d16b964d895a4b415cde8c0a3ba9abe66846842a2f12cbcce0`, unchanged). Addresses are the fixture
Realm's; on any other `(chainId, realmSalt)` recompute them with `tools/deploy-plan.mjs`. Beyond the table, `artifacts/`
differs from `6d11858` in `EfsWeb3Gateway`, `FilesNameRule`, `IndexReads`, `PostingStore`, `RealmIndex` and
`TopicWordRule`. No read bound moved: prague and amsterdam limitEntries, maxRows and pageTimesLens are `245, 150, 768 /
416 / 688 / 408`.

| pin | this release | moved against `6d11858` |
|---|---|---|
| release digest (`sha256(release/release.json)`) | `0xe6972acbabe14140768b912ec1677cbe0d590689690ddef8625d67f20eec8612` | yes (was `0xc4935467…71e4`) |
| plan hash | `0x2206022bd93b199fd96e13f23b912d325560337dc7a7caa778c1caf377e6e509` | yes (was `0x4fc3364f…c575`) |
| execution set | `0x478c92b579a4bbf733a6eaa3bfcfbe6760a1c9009d5811315fe95cc53d827d24` | yes (was `0x9c22c034…c9e5`) |
| index obligations | `0xd1ec8dd90fa4b1fbdfa5d62d10023214b421b3e56793439d37be91c4a84eb20b` | yes (was `0x38ac8541…d78f`) |
| index manifest hash | `0x14f48551d0771b6935522ed5e930b9705c173c545a24b7fe036881a1f32ee148` | yes (was `0x755a082e…3537`) |
| layout id | `0xc59a1669be13ef347b3e85757f16896d2f324b1bdbc062719a24496e7173b212` | no |
| ABI id `efs/ledger-hot/2` | `0xf37d24d0ced96ce84fa2a8dd011fc0594eec8f33e3212c27762b76fc9e469856` | no |
| ABI id `efs/posting-store/2` | `0x420c69c26d04ae5ba1cacc694d440d5257b35567851f953775e889406066128a` | no |
| ABI id `efs/bitmap-store/2` | `0x2d01560e82c334b2278e6228309ae5d2129bc4d82e60e7111ee8b9276987ba36` | no |
| status vocabulary id | `0xd873af00e96f1b685c8cf256f1c6cdd79cc546a37704b0b913b514bfdb690f87` | no |
| limits profile id | `0x0ee9b6c0be6c7a4c600b9d48f05847efeb7d01d7e910061522af092c7b5a5055` | no |
| realm id | `0xdfef48c90e48dafc642f4380c8f39c14c1af7d84d5047e5acb7d508d5316460e` | no |
| domain separator | `0xef73e6345147076e5cab816f3a50e5695626648b1771dcc6f52a0327322b77d7` | no |
| `gas/model.json` sha256 | `0x2862faf955dc7510afa3adca4d732515c308dcbb652c23291c32e2e63401699f` | yes (was `0x77848e72…c438`) |
| `release/errors.json` sha256 | `0xa5fd5d86356d8b759651fb5e4b4ef4daca438a4d190b0e620f421c5199e68b63` | yes (was `0xc1030128…606c`) |
| Type id `files-root/1` | `0xc0cd1cb0ae8a822b60380bdc63e7359005c642c9c5b758f436e1bc8ef7bad41c` | no |
| Type id `files-child/1` | `0xac734de0aa9841fab3eb4903db9ac72ff7fcdb722838b85978106322acf04120` | no |
| Type id `files-directory/1` | `0xc1416234ef270e67d4ea6797f53f8f4e221bf6da1adb57f192220ae108dabcba` | no |
| Type id `files-name/3` | `0x20665824055a0b9a5221ba5bdb118fdb3b827a6399d1cc4afed4ac2398298c8d` | yes (was `0x2b4d22da…c27a`) |
| Type id `files-bytes/1` | `0x9e6efb2374eb521d6f32e828be5cfc1b801c3d139bd0d65fe20c03123bb938f0` | no |
| Type id `files-content/1` | `0xca1cd7e79576ec700b74d301e12f0ada3c15fe92727cfd1ca6853dda1bbb5dfe` | no |
| Type id `files-external/1` | `0xb7c77ee54932f287dbd1d65f78662e9e63a8d80d9364c12616f4b76783350386` | no |
| Type id `directory-alias/1` | `0x0c48b987487897968c6b3688da60e3c6db8e645aac2b481b3a1cc36789aecb61` | no |
| Type id `realm-notice/1` | `0xc9efe343865f6f02915f75a1793e2a303b257cbe4bbd4a128ab936cc18cf5c24` | no |
| Type id `files-span/1` | `0xda1abbbbdcaac315756b708a21cb7bcab21bdca7ddcf994eca8597d20fa2debd` | no |
| Type id `topic-word/1` | `0xe742938125784d985d5eab20872be5045976e9fc0807804f173ece59a3fb3859` | yes (was `0xadf365a3…886b`) |
| Type id `topic/1` | `0x275a99cc5a7334c2ffd88257784015ec18f18ec8ffcd6b3e12233e5e3f67bfde` | yes (was `0x4ea9b8b2…d4cf`) |
| Type id `text/1` | `0x0b71fa4391f889f8a5c5b80499ad7b3921ec96111ed99aa0d60410a3bdb26a06` | no |
| ledger proxy | `0xe942147e5E9112c64ced569e8f5FA18B20073429` | no |
| ledger implementation (`LedgerCore`) | `0x13b04891ce92Bec464CA5fDF8e412E4FFB64342E` | no |
| ledger ProxyAdmin | `0x6894E327133006F2Fe5383006d14b290a1692035` | no |
| registry proxy | `0x6cD3F5A2a7c8fDC22259BFFc9a81c699AFBBB415` | no |
| controller | `0xb89a7b732325bc25194AD9B1b51b72fad00EF770` | no |
| genesis contract | `0xc2EeEe8765C8c99809B99aef72cb748daF3f9F62` | no |
| index (generation 1) | `0x412812D2Bd8aEE07963074D0A813F059B97D5f5D` | yes (was `0x9ca434fC…9f26`) |
| index runtime codehash | `0xc901315f0c27ab1d2771d8eb177ec82bc88c809cd16c2b23b27b755ecea26849` | yes (was `0x086f70d3…67a8`) |
| index reads contract | `0x1421c4C9884F0Be77029c83ae884CD84C927123F` | yes (was `0x98de1725…07DF`) |
| `readers.ledgerReads` | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366` | no |
| `readers.ledgerViews` | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648` | no |
| `readers.readerDirectory` | `0x77865D8B084589021D9695865475cBED4fc16c31` | no |
| `readers.keysView` | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F` | no |
| `readers.lensReader` | `0xbb20026c277926D7eDD3d9bCa070FEcA85b4E374` | no |
| `readers.lensReader` runtime codehash | `0x862b457115bf94c5220aeef72df6de52c184159349cafb10a570e4e4e4e132d1` | no |
| `readers.filesPageReader` | `0xbd90fE59D14D6488e506Baac9340391dF5d934d9` | yes (was `0x3dba5FD3…f8a2`) |
| `readers.filesPageReader` runtime codehash | `0x10d41bb049106fbbd746eeeecd1e6e7ca3fbaf2e442947c0db234e456c5da2ce` | yes (was `0x52f038b5…2f6c`) |
| `readers.topicMineReader` | `0x45772331A92Bf67Ce3A16c2A15E733777499CE33` | no |
| `readers.topicMineReader` runtime codehash | `0xdac80a0c60d729f134153d0ed02901cafb902f5ee0091b0766882bb930efe0fd` | no |
| `readers.topicEveryoneReader` | `0x6082241a955e214432b069beC81A5a57c2EC39A0` | no |
| `readers.topicEveryoneReader` runtime codehash | `0xbae87c8a30fec9efcd372dba070dc0a0b9dfc649b0ff22b51df8a25d41751d41` | no |
| `readers.topicLookupReader` | `0x3c57C6dfaEdF8B57077A721b9297921CcbDBA0Aa` | yes (was `0xF9176797…d1a9`) |
| `readers.topicLookupReader` runtime codehash | `0xcd36e8e69853a45574df8dda96c641ab4c6f629fb485587453643be80ffca091` | yes (was `0x48c379a6…4487`) |
| `readers.web3Gateway` | `0x386F52cCB19217AFf97337869Cf02a8bFd385f10` | yes (was `0x78267F06…479e`) |
| `readers.web3Gateway` runtime codehash | `0x5d9ab2e932c429bceda3de17ed1cf60899c280a9fc6537575169eb8d3dec587d` | yes (was `0xa73f9fff…5c41`) |
| `readers.web3Gateway.content` | `0x8d06AbED192b097dbBc2efA37E7F3aaCAB6D5E47` | no |
| `LedgerIngress` (address, runtime codehash) | `0x064cB3432FCEa1965b2531eDe7B6f03461788319 / 0xd3e3e0cfcaba81a37807209c9c138387db51ad1a9ca38aeee6b3b1aee8b4728e` | no |
| `LedgerApply` (address, runtime codehash) | `0x4Eb1ab68E26a13a5aFB7dc4866eEAd6d6eA88343 / 0x7d788fac98935e8c48d36d9e4886246093bef0a0eb20d445a7d28db275637669` | no |
| `LedgerControl` (address, runtime codehash) | `0x992482530deb668f7B98D23edb19432796007722 / 0xa0386f81586303a1a8f7d11b79dca2cbd0439ea7938764bdabd182e21d58a6da` | no |
| `LedgerReads` (address, runtime codehash) | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366 / 0x7aafb133b4b1b130b239da67027f7de118918861850b94584b68c101e0b71657` | no |
| `LedgerViews` (address, runtime codehash) | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648 / 0xf15400a4921e6b3282e9e1b486a14a4268c0f01b1b18e88234659394abc9eb03` | no |
| `DescriptorStore` (address, runtime codehash) | `0xdD13148b5d7cbFdE29C52a1D3C9D22e969BDE71c / 0x96d412de94866a8ce21410434df2a38eb4e3573169f024ddf9669887df72f5dc` | no |
| `IndexReplayDecoder` (address, runtime codehash) | `0x5fdA1ac334D046E3666FceBe45dBd3F5DaFdd3f4 / 0xf183f5c83d76686f23bc41f8f4e6f6f06447adc54da83f5f2751128ebf00dd03` | no |
| `ReaderDirectory` (address, runtime codehash) | `0x77865D8B084589021D9695865475cBED4fc16c31 / 0xb929f9e1714d97a570f12cf66daeeff6f06cfb10b373c1a1b22cc51238c31b5f` | no |
| `FilesBytesRule` (address, runtime codehash) | `0xdD9AE013bf2CCaf784626D70bcab5Be307b07e40 / 0x26b7e1529674fd83c36fbe5ccc9dab915a2f1821d853c707a2cd187e68066d2c` | no |
| `FilesSpanRule` (address, runtime codehash) | `0x248C3f75c03d525c1813e6dCeDFAd10E2193a8b7 / 0x15a6e10285c6953d9157a023a600f567b5cd2dfb807070c85517f6774fb8e5f6` | no |
| `FilesContentRule` (address, runtime codehash) | `0x24a5E41C539FB0e1FF5924239fE23D3bF86De11E / 0x9989c5027fc25da8bceb23b0b5dab216bb1f33c2f8b8fd5d04bc8485bcc712a9` | no |
| `FilesExternalContentRule` (address, runtime codehash) | `0x9A0B471E27F1CDC8478E214c301aA6Aa4F189FaF / 0x637f6861202f82a7432588841d9a5544375dac5d0e77710db9b7b986f7f06f55` | no |
| `FilesRootRule` (address, runtime codehash) | `0xd65df37B79581dEdC752ECDf3325bD91e54c561E / 0xcb7ba484cea9625fa2a8cbc35f81b312a1c936f2c69339e325fa5c4a7b5a9f39` | no |
| `FilesChildRule` (address, runtime codehash) | `0x4d670A2Ef8915ccb1347b6BcC01C1efd073fB6A8 / 0x38d96ac3bc562bdc7adf3708808ab74c2420b46a2df59af8107e4e952f90f9d4` | no |
| `FilesDirectoryRule` (address, runtime codehash) | `0x5A266C0a5428e3caDe9F4c5a8B830DCBDf478615 / 0xaea9d912818cd9f49a7b8426807494ca91551040ec499ec6dfaec6e40ad6bfd2` | no |
| `FilesNameRule` (address, runtime codehash) | `0x0558440B6fb7A98665c3Ff1b2eDC4830C135aE7F / 0x80c8f4aa1066d240d09f1c110c60a94cdbf16e157d5f5721116e00077d169308` | yes (was `0x245098a6…884f / 0xd73a9ee2…fd17`) |
| `RealmNoticeRule` (address, runtime codehash) | `0xB0be8d1E04D0B5D5268C05a6330c3254d6e5df34 / 0x52b5a16a788796687ec4607ff1ef59c4d99140c5eea9f583e8239b9d79b0ddcc` | no |
| `DirectoryAliasRule` (address, runtime codehash) | `0x60B6B7611961E258dC8FF63b37830281Ce0F4bDa / 0xc10493df425c8ccfa89ee4f6948a0a85bacc0426127510fa337562fe68ddb667` | no |
| `TopicWordRule` (address, runtime codehash) | `0x131C5d9fEf6aa4477bFBDD3EdDf4B4D3F9F21450 / 0xee656292391d6fd99176abf04a8875989c323535087836c801e6a24d15c7edac` | yes (was `0x44186F79…32a5 / 0x29442a0e…dfd5`) |
| `TopicRule` (address, runtime codehash) | `0x7fb25Cdd0840Fcd5dB5b6eFE32cC80A99336aeda / 0x6c3de3abe7422d0f0150b084e5a14ea4918c75f7f681ba9da0424f2460b6d69a` | yes (was `0xD07aaA9b…4CdC / 0x6c3de3ab…d69a`) |
| `TextRule` (address, runtime codehash) | `0xD10088139D60Be3faB03FD3012F3706C3Ac69485 / 0xb839d97202882243312d2792eebda9be94bb272490e3d652c73f2a1a9a0661a5` | no |
| `RefuseAllPolicy` (address, runtime codehash) | `0xeba0FBaa0F4bE2a8444C994783120094fFe2BBB1 / 0xefcebe5a8ee27ed2e419e3753d17a6ad67a87fe257797ad10652bd3bc44b2a44` | no |
| `FilesFinalValidator` (address, runtime codehash) | `0x5232Bb9c585F8d992d80dA5f477371bFEe49182B / 0xeb744b64ca0d1d994bc0a1b260382c55b768b53fbbc55ba7bbac9fa7e1cb1619` | yes (was `0xc672EfB3…35C0 / 0xeb744b64…1619`) |
| `LedgerCore` (address, runtime codehash) | `0x13b04891ce92Bec464CA5fDF8e412E4FFB64342E / 0x2fdc95dda795c657c7500ee5ee2644fe0ceb6ee5a5bf4cd7e25f21366d56f23f` | no |
| `TypeRegistry` (address, runtime codehash) | `0x0A5eFCc70026787b94bf6872A8148CA1A29C08C9 / 0xa7e9307a6ef01411f232895f1ae4a5f40b095b5c8da8788a259ffc06846178d3` | no |
| `RealmGenesis` (address, runtime codehash) | `0xc2EeEe8765C8c99809B99aef72cb748daF3f9F62 / 0x631085c94713962726cd0e64ab985602dcf9c6e6542aa88b2fd079b27bf0272c` | no |
| `PostingStore` (address, runtime codehash) | `0xf948095e56785166c51eE0Bb90C92d24b9D4718C / 0x5d1f9c2fb7775b944960f64fa8d20667a40af7616495f52b7337938383735807` | yes (was `0x1546aCdE…6D33 / 0xc2b395ce…4465`) |
| `BitmapStore` (address, runtime codehash) | `0xCEe929eC6398c54265EFCE369F76dAdD47477088 / 0xd8b36e1b30ec57c36304f9d0a86785bc7e8e00ec8028abb0097c060399442fdd` | no |
| `RealmController` (address, runtime codehash) | `0xb89a7b732325bc25194AD9B1b51b72fad00EF770 / 0x93341dc000015afd1a3c22e833d1ebb06e4239d253430a6ab6973f1a1de53930` | no |
| `TypeRegistryProxy` (address, runtime codehash) | `0x6cD3F5A2a7c8fDC22259BFFc9a81c699AFBBB415 / 0xd044c103027b2c4ac7472651a7bc92cb82606b2a878b423a1146850a70015264` | no |
| `LedgerProxy` (address, runtime codehash) | `0xe942147e5E9112c64ced569e8f5FA18B20073429 / 0x9e0eb139edf90b2bac14563b114e92c6ba2f5a330686a4e9ec1003e57179ded1` | no |
| `RegistryProxyAdmin` (address, runtime codehash) | `0x890795926ff55dc3bAC27103c51BF42d5ED7ba44 / 0xf32a01cd7613147ce1fce81b16c52ddeb9377c8a9ec26c61cbfca5f1251752b2` | no |
| `LedgerProxyAdmin` (address, runtime codehash) | `0x6894E327133006F2Fe5383006d14b290a1692035 / 0xf32a01cd7613147ce1fce81b16c52ddeb9377c8a9ec26c61cbfca5f1251752b2` | no |
| `IndexReads` (address, runtime codehash) | `0x1421c4C9884F0Be77029c83ae884CD84C927123F / 0xaaa2423303e6d9351ebfd60ff1a5aeed26fd1a081d7e85332357079dcd9c4378` | yes (was `0x98de1725…07DF / 0x9abcfb62…2f43`) |
| `RealmIndex` (address, runtime codehash) | `0x412812D2Bd8aEE07963074D0A813F059B97D5f5D / 0xc901315f0c27ab1d2771d8eb177ec82bc88c809cd16c2b23b27b755ecea26849` | yes (was `0x9ca434fC…9f26 / 0x086f70d3…67a8`) |
| `KeysView` (address, runtime codehash) | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F / 0xaede6581bd6c30cad13acfdab4ccf0792e45c4e1686c453545d4559831201ab3` | no |
| `LensReader` (address, runtime codehash) | `0xbb20026c277926D7eDD3d9bCa070FEcA85b4E374 / 0x862b457115bf94c5220aeef72df6de52c184159349cafb10a570e4e4e4e132d1` | no |
| `FilesPageReader` (address, runtime codehash) | `0xbd90fE59D14D6488e506Baac9340391dF5d934d9 / 0x10d41bb049106fbbd746eeeecd1e6e7ca3fbaf2e442947c0db234e456c5da2ce` | yes (was `0x3dba5FD3…f8a2 / 0x52f038b5…2f6c`) |
| `EfsWeb3Content` (address, runtime codehash) | `0x8d06AbED192b097dbBc2efA37E7F3aaCAB6D5E47 / 0x91096216c4ec9ccfa94a7f40fcd4ed54562091a76d794413da539375bffb5a66` | no |
| `EfsWeb3Gateway` (address, runtime codehash) | `0x386F52cCB19217AFf97337869Cf02a8bFd385f10 / 0x5d9ab2e932c429bceda3de17ed1cf60899c280a9fc6537575169eb8d3dec587d` | yes (was `0x78267F06…479e / 0xa73f9fff…5c41`) |
| `TopicMineReader` (address, runtime codehash) | `0x45772331A92Bf67Ce3A16c2A15E733777499CE33 / 0xdac80a0c60d729f134153d0ed02901cafb902f5ee0091b0766882bb930efe0fd` | no |
| `TopicEveryoneReader` (address, runtime codehash) | `0x6082241a955e214432b069beC81A5a57c2EC39A0 / 0xbae87c8a30fec9efcd372dba070dc0a0b9dfc649b0ff22b51df8a25d41751d41` | no |
| `TopicLookupReader` (address, runtime codehash) | `0x3c57C6dfaEdF8B57077A721b9297921CcbDBA0Aa / 0xcd36e8e69853a45574df8dda96c641ab4c6f629fb485587453643be80ffca091` | yes (was `0xF9176797…d1a9 / 0x48c379a6…4487`) |
| seed version | `efs-fixture-seed/4` | no |
| seed root directory record | `0xf7547aa65ac7374a944085cc67bd05c48c17a2fef819390b06350f8d4a76c037` | no |

## The fixture: many instances at once

Any number of agents, in any number of checkouts and worktrees of this repository, the SDK and the client, can run
fixture instances at the same time. Each instance has a **name**, its own **lease** in one machine-wide **registry**,
its own **port** and its own **state directory**. Nothing an instance writes is a tracked file. Only blank local
chains are supported: no fork mode, no RPC keys.

### CLI

```text
node tools/efs-fixture.mjs up      [--name N] [--port P | --port-range LO-HI] [--chain-id 31337]
                                   [--realm-salt 0x… | --fresh] [--ttl 900 | --ttl 0 | --keep] [--no-unlocked]
                                   [--hardfork osaka|prague]
                                   [--state-dir DIR] [--artifacts DIR] [--plan FILE] [--no-verify] [--keep-on-fail]
                                   [--write-release] [--json]
node tools/efs-fixture.mjs verify  [--name N] [--documents DIR | --release] [--json]
node tools/efs-fixture.mjs status  [--name N] [--json]          # without a name: the same as list
node tools/efs-fixture.mjs list    [--kind chain|gateway|ui] [--json]
node tools/efs-fixture.mjs down    [--name N] [--purge] [--json]
node tools/efs-fixture.mjs reset   [--name N] [--fresh] [--chain-id N] [--realm-salt 0x…] [--ttl S | --keep] [--json]
node tools/efs-fixture.mjs gc      [--purge] [--json]
every command: --home DIR (the registry; default below)
```

| Flag | Meaning |
|---|---|
| `--name N` | `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, unique machine-wide. Default for `up`: `$EFS_FIXTURE_NAME`, else `<checkout basename>-<4 random hex>`, printed. Default for the other commands: `$EFS_FIXTURE_NAME`, else the one chain instance this checkout has leased (exit 2 if several, 4 if none). |
| `--port P` | Use exactly P; exit 3 when it is leased by a live process, bound by anything, or 60742. |
| `--port-range LO-HI` | Search range when no port is given; default 8600–8999 (the client's proposed gateway range 8546–8599 stays free). |
| `--chain-id N` | Default 31337. |
| `--realm-salt 0x…` / `--fresh` | The Realm salt (default `keccak256("efs/fixture/realm/1")`) or a random one, so the Realm id is fresh. The plan stays computable offline per `(chainId, realmSalt)`: both are in the lease, the documents and the `up` JSON. |
| `--ttl S` / `--ttl 0` / `--keep` | The watchdog: anvil runs as `perl -e 'alarm S; exec @ARGV' anvil …` and dies after S seconds (default 900) even if nobody calls `down`. `0` or `--keep` runs anvil without a watchdog, for a dev session; the lease then has `expiresAt: null`. |
| `--no-unlocked` | Start anvil with `--accounts 0 --fund-accounts <the ten default addresses>:10000`: no unlocked accounts, the same funded addresses (alias `--no-unlocked-accounts`). See "Signing". |
| `--state-dir DIR` | Where the instance's pid, log, journal and documents go (default `<home>/instances/<name>/`). Only the files listed below are written or removed there. |
| `--artifacts DIR` | The artifact source (default `$EFS_ARTIFACTS_DIR`, else `out/`): a Foundry build, a snapshot (`tools/artifacts-snapshot.mjs`) or a committed `artifacts/` directory. See "Artifact sources". |
| `--plan FILE` | A `deploy/plan.json` the computed plan must equal (its chain id and salt become the defaults); exit 1 when the `planHash` differs. |
| `--no-verify` | Skip the in-`up` verify (see "Readiness"). |
| `--keep-on-fail` | When the in-`up` verify fails, keep the instance (lease state `failed`) for inspection instead of tearing it down. |
| `--write-release` | Also write the committed sample `release/efs-deployment.json` and `release/expected.json`. Only on the default configuration (chain 31337, the default salt) and this checkout's artifacts, else exit 2. This is the only way anything under `release/` is written by the fixture. |
| `--documents DIR` / `--release` | `verify` compares the chain with the documents in DIR (default: the instance's own); `--release` = this checkout's committed sample, which verifies against any default-configuration instance. |
| `--purge` | `down`: also delete the instance's state files. `gc`: also delete state directories no lease names. |
| `--json` | Exactly one JSON object on stdout (logs go to stderr), success or failure. |

`reset` is `down` then `up` under the same name, port, chain id, salt, TTL, signing mode, state directory and
artifacts, with `generation + 1`; `--fresh` picks a new salt and `--chain-id` a new chain (the client's reset policy
of a new chain id per reset is the caller's choice).

### Exit codes

| Code | Meaning | `error.code` values |
|---:|---|---|
| 0 | ok | |
| 1 | verification mismatch (`verify`, the in-`up` verify, `--plan`) | `VERIFY_FAILED`, `PLAN_MISMATCH`, `DOCUMENTS_MISMATCH` (verify alone returns `ok: false` with `failures`) |
| 2 | usage | `USAGE`, `BAD_OPTION`, `BAD_NAME`, `BAD_RANGE`, `BAD_PORT`, `BAD_PLAN`, `NOT_DEFAULT`, `AMBIGUOUS`, `NOT_A_CHAIN` |
| 3 | port or lease conflict | `PORT_LEASED`, `PORT_BUSY`, `PORT_FOREIGN`, `NO_FREE_PORT`, `NAME_LEASED`, `NOT_ANVIL_YET`, `IDENTITY`, `FOREIGN_HOST` |
| 4 | instance not found or dead | `NO_INSTANCE`, `INSTANCE_DEAD`, `NO_DOCUMENTS` |
| 5 | any other failure | `ARTIFACTS` (the plan cannot be built, e.g. stale `out/`), `ANVIL_START`, `SIGNER`, `UP_FAILED`, `REGISTRY_UNWRITABLE`, `FAILURE` |

With `--json`, a failure prints `{"ok": false, "command": "...", "error": {"code", "message", "exitCode", "details"}}`.

### Readiness

`up` deploys and seeds, writes the instance's documents, then runs **every `verify` check** against the new chain
(lease state `verifying`). Only when all pass is the lease marked `ready` and the one JSON object printed, carrying the
actual `port` and `rpcUrl` (also when the port was allocated from the range) and `verified: {skipped: false, ok, checks,
failures, ms, coldPin}`. If a check fails, `up` tears the instance down (its own anvil, its lease) and exits 1 with an
error object listing the failures; with `--keep-on-fail` the instance stays leased in state `failed`. Measured cost of
the in-`up` verify: about 0.9 s for 567 checks (the big file is re-assembled node by node); a whole `up` takes about
4–5 s. `--no-verify` skips it (`verified: {skipped: true}`). Both failure paths were exercised by hand against a stale
`deploy/plan.json` (one mismatch): the default tore the instance down and removed its lease; `--keep-on-fail` left it
leased in state `failed`.

### The `up --json` object

```json
{
  "ok": true, "command": "up", "name": "contracts-v2-e4d3", "kind": "chain", "generation": 1,
  "rpcUrl": "http://127.0.0.1:8600", "host": "127.0.0.1", "port": 8600, "chainId": 31337,
  "realmSalt": "0x1419…260f", "realmId": "0x10fb…bc9e", "layoutId": "0x9d4c…9deb", "pid": 6683,
  "stateDir": "<home>/instances/<name>", "deployment": "<stateDir>/efs-deployment.json",
  "expected": "<stateDir>/expected.json", "journal": "<stateDir>/fixture.json", "log": "<stateDir>/anvil.log",
  "ledger": "0x870a…0c1c", "registry": "0x…", "controller": "0x…", "keysView": "0x50dE…757F",
  "web3Gateway": "0x38Bd…bC4a", "web3Url": "web3://0x38Bd…bC4a:31337/~efs/o/0xf754…c037/",
  "readers": { "ledgerReads": "0x…", "ledgerViews": "0x…", "readerDirectory": "0x…", "lensReader": "0x…", "filesPageReader": "0x…", "keysView": "0x50dE…757F", "web3Gateway": "0x38Bd…bC4a", "web3Content": "0x…" },
  "root": { "directoryRecordId": "0xf754…c037", "principalId": "0x…f39f…2266" },
  "seed": {
    "version": "efs-fixture-seed/4", "root": { "…": "as above" },
    "folder": { "name": "docs", "directoryRecordId": "0xbc58…0443" },
    "file": { "name": "readme.txt", "subjectId": "0xb77c…4065", "headRecordId": "0xbd3d…9e8d", "headRevision": 1 },
    "files": [
      { "name": "readme.txt", "subjectId": "0xb77c…4065", "headRecordId": "0xbd3d…9e8d", "headRevision": 1, "form": 0, "length": 18, "sha256": "0x0e7b…6df6" },
      { "name": "big.bin", "subjectId": "0xe160…c12e", "headRecordId": "0x006b…0105", "headRevision": 1, "form": 1, "length": 20000, "sha256": "0xda46…efc9",
        "contentRecordId": "0x9109…5ad4", "spanRootId": "0x26e1…bc67", "chunkCount": 3, "spanCount": 2, "chunkPayload": 8160, "publications": 2 },
      { "name": "remote.txt", "subjectId": "0xf9ad…8385", "headRecordId": "0x2938…fa77", "headRevision": 1, "form": 1, "length": 51, "sha256": "0xf380…a9cc",
        "externalRecordId": "0x7854…3c9b", "sentinelRecordId": "0xbf5a…cb52", "locator": "web3://0x0000000000000000000000000000000000000000:31337/remote.txt" }
    ]
  },
  "typeIds": { "files-root/1": "0x…", "…": "one per Files Type" },
  "signerCapable": true,
  "capabilities": { "filesSeed": "efs-fixture-seed/4", "filesTypes": 13, "seedFiles": ["readme.txt", "big.bin", "remote.txt"], "largeFiles": true, "externalLocations": true, "keysView": true, "web3Gateway": true, "readers": ["efs/reader/lens/1", "efs/reader/files-page/1", "efs/reader/topic-mine/1", "efs/reader/topic-everyone/1", "efs/reader/topic-lookup/1"], "signerCapable": true, "unlockedAccounts": 10, "hardfork": "prague" },
  "ttl": 900, "startedAt": "…", "expiresAt": "…",
  "planHash": "0xf5cb…9904", "plan": null, "checkout": "/path/to/checkout", "artifacts": "/path/to/out", "artifactsMode": "forge",
  "registryHome": "<home>", "lease": "<home>/leases/<name>.json", "releaseWritten": null,
  "verified": { "skipped": false, "ok": true, "checks": 567, "failures": 0, "ms": 694, "coldPin": { "calls": 9, "envelopes": 2 } }
}
```

`verify --json` prints `{ok, command, name, rpcUrl, chainId, documents, checks, byGroup, failures, uncheckedDescribe,
harnessFactory, coldPin}`; `list --json` prints `{ok, command, registryHome, leases: [lease + liveness + expired]}`;
`status --json` `{ok, command, lease, rpc: {chainId, blockNumber}}`; `down --json` `{ok, command, name, port, stopped,
wasLive, purged, stateDir}`; `gc --json` `{ok, command, registryHome, removed: {leases, ports, files, stateDirs}}`.

### The registry

`<home>` = `$EFS_FIXTURE_HOME`, else `${XDG_STATE_HOME:-~/.local/state}/efs/fixtures`. Agents that should see each
other share it; a sandbox that cannot write `~` sets `EFS_FIXTURE_HOME` to a shared writable path (a registry that
cannot be created is exit 5 `REGISTRY_UNWRITABLE`).

```text
<home>/leases/<name>.json     efs-fixture-lease/1 (schemas/efs-fixture-lease-1.schema.json), one per instance
<home>/ports/<port>.json      efs-fixture-port/1: the claim {port, name, kind, pid, startTime, command, hostname}
<home>/instances/<name>/      a chain's default state directory:
    anvil.pid  anvil.log  fixture.json (journal of every transaction, read estimates, rpc call counts)
    efs-deployment.json  expected.json  up.json (the up result)
```

- **Atomic creation.** A lease and a port claim are each created with `open(path, "wx")` (O_CREAT|O_EXCL), so two
  processes can never both hold one name or one port. Updates by the holder are write-then-rename.
- **Holders and liveness.** A record names its holder as `(pid, startTime, command)`, as `ps -o lstart= -o command=`
  prints them under `LC_ALL=C`. It is `live` while that pid still has that start time (and command, once recorded),
  `dead` otherwise (a reused pid does not count), and `foreign-host` when another host wrote it (never judged, never
  broken). A chain lease's holder is the `up` process until anvil is spawned, then anvil itself.
- **Breaking stale records.** A dead record may be removed by anyone, serialized by `<record>.break` (also `wx`); the
  breaker re-reads the record under that lock and removes it only if it is unchanged and still dead, so a fresh
  record is never removed by a breaker that saw an older stale one. A breaker that dies leaves a `.break` that ages out
  after 10 s.
- **Port allocation.** `--port`, or the first port of the range that (1) has no claim held by a live process and (2)
  passes sequential bind probes on `::`, `0.0.0.0` and `127.0.0.1`. The claim comes first, then the probe, so two
  agents starting at the same instant get different ports (tested with 12 processes). anvil's own bind is
  authoritative: if anvil reports the address in use, an allocated port is released and the next one tried (up to 5
  times); an explicit `--port` exits 3. Port 60742 is never allocated or touched.
- **Kill rule.** `down` signals only the pid its lease records, only when `ps` shows that pid with the recorded start
  time and the recorded command line, and only when that command is `anvil … --port <the lease's port> …`. SIGTERM,
  5 s grace, SIGKILL. A dead or reused pid is never signalled; its lease is simply removed. Nothing is ever killed by
  port, by process name or by a bare pid. `gc` never signals anything.
- **TTL.** `expiresAt = startedAt + ttl`; the watchdog ends anvil then, the lease becomes `dead` and `gc` (or the next
  allocation of that name or port) removes it.

**Lease schema (`efs-fixture-lease/1`, a stable contract).** Required: `schema`, `kind` (`chain` | `gateway` | `ui`),
`name`, `state`, `generation`, `pid`, `startTime`, `owner {pid, startTime, user}`, `hostname`, `host`, `port`, `url`,
`ttl`, `startedAt`, `expiresAt`. A chain lease adds `command`, `chainId`, `realmSalt`, `realmId`, `layoutId`, `ledger`,
`registry`, `checkout`, `artifacts`, `artifactsMode`, `plan`, `stateDir`, `unlocked`, `signerCapable`, `deployment`,
`expected`, `journal`, `log`, `planHash`, `seedVersion`, `root`, `seed`, `capabilities`, `verified`, `readyAt`. Chain
states: `allocating` → `allocated` → `deploying` → `verifying` → `ready` (or `failed` with `--keep-on-fail`). Readers
check `schema` and ignore fields they do not know; a breaking change gets a new schema id.

### Library API (`tools/fixture-registry.mjs`, Node built-ins only)

```js
import { allocate, update, lookup, list, release, gc, up, down, verify, registryHome, EXIT, FixtureError } from "<contracts checkout>/tools/fixture-registry.mjs";

const lease = await allocate({ kind: "gateway", name: "wt1-gateway", range: [8546, 8599], pid: process.pid, ttl: 0, meta: { chain: "wt1-chain" } });
update("wt1-gateway", { state: "ready" });          // the holder only; a changed pid/startTime moves the port claim too
lookup("wt1-chain");                                 // lease + {liveness: "live"|"dead"|"foreign-host", expired} | null
list({ kind: "chain" });                             // every lease, oldest first, with liveness
release("wt1-gateway");                              // remove lease + port claim (kills nothing)
gc({ purge: false });                                // {leases, ports, files, stateDirs} removed; signals nothing

const r = await up({ name: "wt1-chain", portRange: "8600-8999", chainId: 3133701, fresh: true, ttl: 0, unlocked: false, artifacts: "<checkout>/artifacts", stateDir: "/tmp/x" });
await verify("wt1-chain");                           // {ok, failures, …}
await down("wt1-chain", { purge: true });
```

Every function takes `home` (default `registryHome()`). Errors are `FixtureError {code, message, exitCode, details}`
with the exit codes above. `up`, `down` and `verify` load viem and the artifacts lazily (they are
`tools/efs-fixture.mjs`'s functions, which also exports `status`, `list`, `gc`, `reset` and re-exports the registry);
`allocate`, `update`, `lookup`, `list`, `release` and `gc` do not.

**For the SDK and the client.** Import `tools/fixture-registry.mjs` from a contracts checkout or release directory and
use one registry (`EFS_FIXTURE_HOME`). Start chains with `up` (or the CLI with `--json`) and read everything from its
result or `lookup(name)`; the deployment document is at `deployment`. The client supervisor takes `gateway` and `ui`
leases with `allocate` in the same registry (their own ranges), updates them as its processes change and `release`s
them on shutdown; it adopts a chain whose `lookup` is `live` and passes `verify`. Never parse `anvil.log`; never kill by
port.

### The chain's rules

The fixture's anvil runs `--hardfork osaka --enable-tx-gas-limit` by default, so the local chain enforces what
mainnet and Sepolia enforce since Fusaka: **a transaction whose gas limit exceeds 16,777,216 (2^24, EIP-7825) is
refused.** Measured on anvil 1.8.3: `--hardfork osaka` alone does not enforce it, and neither does
`--enable-tx-gas-limit` under prague; both are needed. The contracts are still compiled for prague and the addresses
do not change. `--hardfork prague` gives the old behaviour (no cap) for a measurement that needs it.

`efs-deployment/1` records the rules as `chain: { hardfork, feeSchedule, txGasCap, txGasCapEnforced, blockGasLimit,
atBlock }`. `feeSchedule` is the key of `release.json` `gasModel.schedules` that prices the chain (`prague` for both
prague and osaka, which did not reprice storage; each schedule also lists its `hardforks`), so a planner never maps a
hardfork name to a price list by itself.
It is a **snapshot taken at deployment, not live truth**: a block gas limit moves and a later fork changes what the
cap counts (after Glamsterdam it counts execution gas only), so a client reads the live block gas limit from the
chain and treats the document's values as defaults. `verify` compares the snapshot with the chain and proves the
cap by sending a signed transaction with gas limit cap + 1, which must be refused (a refusal changes no state).
`tools/test/fixture-gas-cap.test.mjs` shows the consequence: a publication inside every Realm limit (64 records,
16,384 body bytes, about 28M gas) is refused above the cap, runs out of gas at the cap and is admitted when split
into four; under `--hardfork prague` the same publication is admitted whole.

### Artifact sources

`--artifacts DIR` (or `EFS_ARTIFACTS_DIR`) selects where the plan reads its unit artifacts; the layout is detected:

| Layout | Detected by | Immutable names | Integrity |
|---|---|---|---|
| `forge` | anything else (`out/`) | `$EFS_AST_DIR` (default `DIR/release-ast`), else `release/release.json` | each artifact's metadata keccak256 of its compilation target against the source on disk |
| `snapshot` | `DIR/efs-artifacts-snapshot.json` | frozen in the manifest | the same, against the snapshot's own copy of the sources |
| `release` | `DIR/LedgerCore.json` with `schema: "efs-artifact/1"` | each unit's `immutables` | each unit's runtime and creation code against `DIR/../release/release.json` when present |

So a release directory or another checkout deploys with no forge build and no `out/`:
`up --artifacts <repo>/artifacts --plan <repo>/deploy/plan.json`. In the release layout, `vectors/layout.json` (or
`artifacts/index.json`'s `layoutId`), `release/` and `deploy/` are read from `DIR/..`. Verified: the committed
`artifacts/`, a copy of `artifacts/ release/ vectors/ deploy/` in an empty directory, and a snapshot of
`out/release-ast` each reproduce the committed `deploy/plan.json` hash (`0xf5cb…9904`) and deploy and verify OK.
`release.mjs` now also writes `artifacts/index.json` (`efs-artifacts-index/1`: `layoutId`, `hotAbiId`,
`hotAbiIdString`, the unit list, the manifest path) so `artifacts/` alone carries the layout id; until the next
`pnpm release` it falls back to `vectors/layout.json`. The plan's ABIs travel with the plan (`plan.local`, not part of
`planHash`), so one process can run instances from several sources.

`tools/artifacts-snapshot.mjs --to DIR [--from out] [--ast out/release-ast] [--rev HEAD]` copies the release units'
artifacts, recovers every source they were compiled from by keccak256 (the working tree first, then `git show
<rev>:path`), freezes the immutable layouts and writes the manifest. It refuses unit artifacts that disagree about a
shared source (a half-finished incremental build) and any source it cannot recover byte for byte. Use it when `out/`
is being rebuilt under you: `EFS_ARTIFACTS_DIR=out-fixture-<x> node tools/efs-fixture.mjs up`. `out-fixture-*/` is
gitignored.

### Signing

Every transaction the fixture sends (genesis, registration, seed) is signed locally with the fixture key through a
viem local account and submitted with `eth_sendRawTransaction`; the fixture's RPC client refuses `eth_sendTransaction`,
`eth_sign*` and `personal_sign` outright, and `fixture.json` records the RPC methods used.

- **Default:** anvil's ten default accounts are unlocked and funded (10,000 ETH). `up` checks that `eth_accounts` is
  exactly those ten and records `signerCapable: true`.
- **`--no-unlocked`:** anvil 1.8.3 has no "no unlocked accounts" switch as such, but `--accounts 0` generates no dev
  accounts, and `--fund-accounts` funds the same ten addresses. `up` checks that `eth_accounts` is empty, that an
  unsigned `eth_sendTransaction` is refused (`No Signer available`) and that the tenth default address holds 10,000 ETH,
  and records `signerCapable: false`. Remaining exposure, stated plainly: anvil's admin methods
  (`anvil_impersonateAccount`, `anvil_autoImpersonateAccount`, `anvil_setBalance`, …) are still served to any local
  process; auto-impersonation is off unless someone turns it on.

`signerCapable` is in the lease, the `up` result, the deployment document (`signerCapable`, `signing`,
`capabilities`) and `verify` re-checks it against `eth_accounts`.

### Process rules

- `release.mjs` and `gas-report.mjs` run forge through `perl -e 'alarm 900; exec @ARGV'` with a Node timeout as well.
  The amsterdam run writes `out/amsterdam` and `cache/amsterdam` and never touches the identity `out/`, because
  `[profile.amsterdam]` does not set its own `out`.
- `node --test "tools/test/*.test.mjs"` (`pnpm test:tools`): `fixture-registry.test.mjs` (no anvil: 12 simultaneous
  allocations from 12 processes get 12 different ports; 8 contenders for 3 ports give exactly 3 winners and 5 exit-3
  refusals; a bound port is skipped and refused when explicit; stale leases are broken; gc removes only the dead; down
  refuses to signal a live non-anvil holder and never signals a reused pid) and `fixture-concurrency.test.mjs` (three
  `up --json` at once, one of them `--no-unlocked --fresh --chain-id 3133702`; three names, ports and anvils; each
  verified in `up` and again; `list`; `down`; no lease, claim, state directory or process left). The concurrency test
  skips, with the reason, when the plan cannot be built from the current artifacts. `vendored-tree.test.mjs` (no anvil)
  copies the three fixture tools with `schemas/`, `artifacts/`, `release/` and `deploy/` into an empty directory with
  no `out/` and reproduces the committed plan hash there: the tree a consumer's CI vendors. `fixture-gas-cap.test.mjs`
  is described under "The chain's rules".

### The ABI ids (hot interface and stores)

Every ABI id follows one rule (design §5.3, `tools/abi-id.mjs`):
`id = keccak256(bytes(name) ‖ for each function sorted by selector ascending: selector (4 bytes) ‖
keccak256(bytes(canonical output tuple type string)))`, the output tuple with tuples expanded (`(uint8,uint64,bytes32)`);
inputs are covered by the selector, events and errors are not part of the id. Computed from the committed snapshots:

| id | name | snapshot | value (step 3a) | before step 3a (`keccak(name)` alone) |
| --- | --- | --- | --- | --- |
| hot (release) | `efs/ledger-hot/2` | `ILedgerHot.json` | `0xf37d24d0ced96ce84fa2a8dd011fc0594eec8f33e3212c27762b76fc9e469856` | `0xfd9aff95b7af2d5718baa9825d35c983d09264fa99fd1c1fe50ef7c4de1b8dc0` |
| hot (suites) | `efs/ledger-hot/2:test` | `ILedgerHot.json` | `0x79a1dd51f600e8d16b964d895a4b415cde8c0a3ba9abe66846842a2f12cbcce0` | `0xb9163fed951b51bb8d2d13b3bd410b5de236799b79c7b1f86b9699d1d90dc603` |
| posting store | `efs/posting-store/2` | `IPostingStore.json` | `0x420c69c26d04ae5ba1cacc694d440d5257b35567851f953775e889406066128a` (step 3b amended: `retain` added; `efs/posting-store/1` was `0xef300c267b843366fadb9548283d8ed29eb662770572621fab8f4429d9433554`) | `0xe6e24a4f8c7ff837e49cb1ce542fa5f6091a3ff5fa0bc27c9c8d1f42a79e4229` (under `/1`) |
| bitmap store | `efs/bitmap-store/2` | `IBitmapStore.json` | `0x2d01560e82c334b2278e6228309ae5d2129bc4d82e60e7111ee8b9276987ba36` (same ABI as `/1`, `0xb3240a15cf3c59f820603f4f856a802b9935547ac7d6fa01e892fcfbbfbe5d6f`; the tag moved with the idle `openCoverage`) | `0x92e2ac66b9cd53934d7ffa76ad5c6e89ebc4ceb1da733342e6d2371947fee425` |

The release hot-ABI id is `HOT_ABI_ID` in `tools/deploy-plan.mjs` (name `HOT_ABI_ID_STRING`): `LedgerCore`'s
`HOT_ABI_ID` constructor argument (so `supportedHotAbiIds() == [it]`), `IndexReads`' `hotAbiId` constructor argument
and the `FilesFinalValidator` unit's `hotAbiId`. The suites' id is `KernelDeploy.HOT_ABI_ID` (and
`test/index/IndexDeployer.t.sol`); the store ids are the `STORE_ABI_ID` constants (and `test/index/Stores.t.sol`).
`pnpm abi:check` recomputes every id from the committed snapshot and fails when any of these pins differs.
`release.json` records `profiles.hotAbiId` with `hotAbiIdName`, `profiles.storeAbiIds` and `profiles.abiIdRule`;
`efs-deployment.json` records `hotAbiId` and `hotAbiIdString`.

### The readers

`LensReader(ledger, views, reads)` and `FilesPageReader(ledger, views, reads, files-name/2, files-root/1,
files-child/1)` are CREATE2 steps **R1** and **R2**. Their constructors read `layoutId()` from the ledger proxy, so
they follow G18; they run after the genesis activation (G20). **R3** and **R4** list them permissionlessly in the
`ReaderDirectory` under the kind labels `keccak256("efs/reader/lens/1")` and
`keccak256("efs/reader/files-page/1")` (the strings `test/periphery/ReaderDirectory.t.sol` uses; the directory does
not interpret them). **R6** `TopicMineReader(ledger, views, reads)` (the lens view), **R7**
`TopicEveryoneReader(ledger, views, reads)` (the public views) and **R8** `TopicLookupReader(ledger, views, reads,
topic/1, topic-word/1)` follow the gateway (R5a, R5); **R9**, **R10** and **R11** list them under
`keccak256("efs/reader/topic-mine/1")`, `keccak256("efs/reader/topic-everyone/1")` and
`keccak256("efs/reader/topic-lookup/1")`. **R5a** `EfsWeb3Content(ledger, reads, {files-root/1, files-child/1,
files-content/1, files-external/1, files-bytes/1, files-span/1})` is the `web3://` gateway's content server and **R5**
`EfsWeb3Gateway(ledger, reads, views, filesPageReader, web3Content, rootDirectory, files-directory/1)` the entry point
a `web3://` URL names; the gateway's constructor reads the content server's `ledger()` and records its codehash
(`CONTENT_CODEHASH`), so R5a precedes R5. Neither is an `IReader` or listed. Every reader is realm-specific, because
its immutables name the ledger proxy.

**Reader features are size-bound.** Every reader and facet is held to the 19,660 B runtime budget (`forge build
--sizes`; budgets are never edited to fit), so a reader feature costs bytes another feature cannot have: the step-4
amendment split the old `TopicPageReader` (465 B of headroom) into the lens and the public view. Headroom at this
release: `TopicMineReader` 4,132 B (15,528 B), `TopicEveryoneReader` 2,964 B (16,696 B), `TopicLookupReader` 2,710 B (16,950 B),
`LedgerViews` 1,085 B (18,575 B; `headStates`, the viewed-place check's one-word read, took 252 B), `EfsWeb3Gateway` 4,269 B (15,391 B)
and `EfsWeb3Content` 10,699 B (8,961 B) (the gateway was one 19,628 B contract with 32 B of headroom; it was split so the `web3://`
entry point keeps parsing, names, lens and listings and a pinned content server serves revisions, docs/LARGE-FILES.md "Two
contracts, one address").

### The fixture key

The fixture key is anvil's default account 0 (`0xf39F…2266`; its private key is printed by every `anvil`). It is the
controller owner, the declaration key of the thirteen Types (ten Files, three Topics) and the seed principal. Never use it with value.
`~/.env` is never read.

### The factory

`up` starts anvil with `--disable-default-create2-deployer`. It then funds `0x3fab…5362` and submits the public
presigned pre-EIP-155 transaction of Arachnid's deterministic-deployment proxy. That transaction creates
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with codehash
`0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`, and the deployment document records
`factory.method = "presigned-tx"`. If a node refuses an unprotected transaction, `up` falls back to `anvil_setCode`
with the same runtime and records `"anvil_setCode"`. The runtime is read from the presigned transaction itself
(14-byte prologue, then 69 bytes). `verify` compares it with `test/harness/doubles/Factory.sol`'s `RUNTIME` (now
equal; see HARNESS-BUG below).

## Files

| Path | What it is |
|---|---|
| `tools/deploy-plan.mjs` | Library and CLI. Computes the whole §8.2 plan offline from `out/`: every CREATE2 address from its initcode, `RealmGenesis` and its nonce-1/2/3 creations, the ProxyAdmins (`CREATE(proxy, 1)`) and every runtime codehash, with immutables filled at their offsets. It also holds a JS twin of `src/profiles/FilesTypes.sol` (descriptors, Type ids, EIP-712 declaration signatures), the index manifest hash, `limitsProfileId`, `domainSeparator`, the execution set, the seed actions and a small schema validator. |
| `tools/efs-fixture.mjs` | `up` / `verify` / `status` / `list` / `down` / `reset` / `gc` (above); also a library (`up`, `verify`, `down`, `reset`, `status`, `list`, `gc`). |
| `tools/fixture-registry.mjs` | The machine-wide registry and lease library (above); Node built-ins only. |
| `tools/artifacts-snapshot.mjs` | A self-contained snapshot of the release units' artifacts and sources (above). |
| `tools/test/*.test.mjs` | The tooling tests (`pnpm test:tools`). |
| `tools/release.mjs` | Writes `release/release.json`, `release/errors.json` and `artifacts/`. |
| `tools/gas-report.mjs` | Writes `gas/report.json`. |
| `script/Genesis.s.sol` | Simulation only, never broadcast. `profile(address key)` deploys the thirteen rules, `RefuseAllPolicy` and `FilesFinalValidator` (six Type ids: name, directory, root, child, topic, topic-word) through the factory in forge's EVM and returns `FilesTypes`' and `TopicTypes`' descriptors and ids. `release.mjs` requires the JS twin to match it byte for byte. |
| `deploy/plan.json` | `efs-deploy-plan/1`: 78 steps (F0, G1–G20 with thirteen G10 rules and G11 blobs, R0–R4, thirteen G21 registrations, R5a and R5 the `web3://` gateway's content server and entry point, R6–R11 the three topic readers and their listings, and the six seed publications G22.root, G22.folder, G22.file, G22.big.0–1, G22.remote), each with kind, contract, address, initcode hash, constructor arguments, runtime codehash, calldata hash and post-check, plus the predicted addresses, realm ids, the genesis activation set with `expectedExecutionSet`, the index manifest, the thirteen Type ids and descriptors, the seed and `planHash`. |
| `release/release.json` | `efs-contracts-release/1` (design §13). It records the source commit, tree and dirty count; toolchain pins (`bytecode_hash = "none"`, CBOR trailer kept); the build platform; double-build reproducibility (36/36 units with identical runtime and creation code across `out/` and `out/release-ast`); sha256 of all 90 source files the units compile from; and, per unit, `runtimeHash` (immutables zero), `deployedBytecodeHash` (planned immutables), `initcodeHash`, `initcodeWithArgsHash`, address, named immutable offsets (empty for every `profiles/` contract, which is asserted), sizes and budgets. It also covers the profile (thirteen Types with shape, descriptor, ruleId, instance, blob and declaration signature; `RefuseAllPolicy`; the index manifest, families, units, digest specs, work model and stores), `limits`, `layoutId`, `hotAbiId` and its preimage, the readers (addresses, codehashes, kind labels, facets), `statusVocabularyId`, store ABI ids, index profile ids, `constants` (action kinds, capability bits, the three purpose ids with their preimages, the Status and Coverage codes, and the Files form, carrier, hash, alias and target-kind codes with the chunk payload: all parsed from the Solidity sources, so a consumer never types a protocol string), the consumer pragma floor, privileged roles, the error-catalog pointer and hash, the ABI pointers and the vector hashes. Digest = `sha256(file)`. |
| `test/vectors/media.json` | `efs/vectors/media/1`, written by `tools/release.mjs` (or alone by `node tools/media-vectors.mjs`) and compared byte for byte by `release:check`: `files-content/1` and `files-external/1` bodies with their inputs, release Type ids and record ids, and about forty media strings with the grammar's code and each rule's refusal code (`docs/LARGE-FILES.md` "Media types"). `test/profiles/FilesMediaType.t.sol` asserts it against the rules, `EfsFiles`, `Keys` and `script/Genesis.s.sol`'s Type ids. |
| `test/vectors/topics.json` | `efs/vectors/topics/1`, written by `tools/release.mjs` (or alone by `node tools/topic-vectors.mjs`) and compared byte for byte by `release:check`: the `topic-word/1` and `text/1` verdicts with their codes, the refused code point table (`TopicProfile.REFUSED`), path ids for 1, 2, 3 and 64 words, `PROPERTY` keys, the purposes and the `EfsTopics` builder encodings, for the release Type ids. `test/profiles/TopicVectors.t.sol` asserts every vector. |
| `release/errors.json` | `efs-errors/1`: 107 file-level errors from `src/`, each with selector, signature, args, source, retry class (the first word of the trailing comment; required, the generator refuses an error without one) and meaning (the rest of that comment, else the `///` lines above the error). Every selector in `test/snapshots/abi/Errors.json` is reproduced. |
| `artifacts/<Unit>.json` | `efs-artifact/1` per deployable unit: ABI, method identifiers, creation and runtime bytecode, named immutable offsets. `LedgerCore.json`'s ABI is the union of the kernel ABI with the events and errors of `LedgerApply`, `LedgerIngress` and `LedgerControl`. Interface ABIs are not copied: `abi.interfaces` points at `test/snapshots/abi/` (tools/abi-snapshot.mjs), and storage layouts at `test/snapshots/layout/`. |
| `release/efs-deployment.json` | `efs-deployment/1` (design §13). It records the release digest, plan hash, chain id, `realmId`/`realmOrigin`/`realmSalt`, the factory and how it was deployed, the genesis address, nonces and tx/block, the activation (revision 1, execution set, tx, full set), the layout and hot-ABI ids, the profile id, limits and `limitsProfileId`, the domain separator and `noticePrincipal`. It covers the controller (owner, pending owner, frozen); both proxies (live implementation slot, ERC-1967 admin, `ProxyAdmin.owner()`, the `_admin` immutable offsets, the initializer calldata); every contract with address, runtime hash, step and tx; the index (generation, manifest, obligations, stores, families, units, digest specs, work model); the Type ids and profile rows; privileged roles; the readers (`LedgerReads`, `LedgerViews`, `ReaderDirectory`, and `LensReader`/`FilesPageReader`/`TopicPageReader`/`TopicLookupReader` with address, runtime codehash, kind, bound ledger, facets, layout and, for the page reader, the three Type ids (for the topic lookup reader, the two topic Type ids), plus the directory's listing rows as read back from chain); the seed (version and the three transactions with their actions and bodies); `root {directoryRecordId, principalId}` (a folder is a record, never a subject); `defaultLensPrincipals`; the actors; an RPC hint; and the evidence grade `local-fixture`. |
| `release/expected.json` | `efs-fixture-expected/1`: the seed's post-checks (root, folder, the three files with their ids, lengths, sha256 and, for big.bin and remote.txt, the descriptor, span-root and sentinel ids; counts 27 admissions / 17 records / 7 bindings / 6 publications; seven heads; thirteen records; catalog count 13). |
| `<home>/instances/<name>/` | One instance's runtime state (never tracked): `anvil.pid`, `anvil.log`, `fixture.json` (rpc, pid, ttl, factory method, signing, RPC method counts, the journal of all 79 transactions with hash, block and gasUsed, and the two read estimates), its own `efs-deployment.json` and `expected.json`, and `up.json`. `release/efs-deployment.json` and `release/expected.json` are the committed sample, written only by `up --write-release`. |
| `artifacts/index.json` | `efs-artifacts-index/1`: `layoutId`, `hotAbiId`, the unit list; lets `artifacts/` deploy alone. |
| `gas/report.json` | `efs-gas-report/1` (below). |
| `schemas/*.schema.json` | JSON Schemas (draft 2020-12) for the six documents above and the lease (`efs-fixture-lease-1`). `verify` validates every document present against them, using the subset in `deploy-plan.mjs validate`. They are drafts: `schemas/README.md` says release schemas land after review. |

**Provisional Topics Type ids.** The Type ids of `topic-word/1`, `topic/1` and `text/1` are PROVISIONAL until a committed generator produces the refused code point table (and its JS copy and the SDK's vectors) from one pinned Unicode version, because that table is part of the word and text rules' code and so of those Type ids; this must be closed before any lasting deployment.

## What `verify` reproduces

567 checks against the chain, recomputed from `out/` (and `release/release.json`'s immutable names when the AST
build is absent). Exit 1 on any mismatch; a tampered `expected.json` was tested and fails.

1. **Documents.** `planHash` (recomputed, and equal to `deploy/plan.json`), the ledger address, the execution set, the
   root, and `releaseDigest` against `sha256(release/release.json)`. All six documents are validated against
   `schemas/`.
2. **Code, byte for byte.** The factory runtime and its codehash. For the 31 units the plan deploys (the four readers
   and `KeysView` included), the runtime is compared byte for byte with the artifact plus the planned immutables.
   Codehashes are checked for those 31, the 5 `RealmGenesis` creations (controller, both proxies, both ProxyAdmins)
   and the 13 descriptor blobs.
3. **Genesis.** `controller()`, `registryProxy()` and `ledgerProxy()` equal the plan, `predict()` equals the plan,
   and a second `run()` reverts with exactly `E_GENESIS(0)` (checked by `eth_call`).
4. **Proxies and ownership.** Both ERC-1967 implementation and admin slots; both `ProxyAdmin.owner() == controller`;
   `controller.owner()`, `admins()` and `NOTICE_TYPE`; the registry's `ledger()`, `implementation()` and
   `activeRevision() == 1`.
5. **`describe()`.** Every field of `Description`, 68 comparisons including all 17 limits.
6. **`executionSet()`.** It equals the offline `expectedExecutionSet`, and a JS recomputation from the live revision
   row's `ComponentSet` (`LedgerReads.revisionAt`) equals it too. `domainSeparator` and `limitsProfileId` equal
   `describe()`.
7. **The index.** `manifestHash()` equals the offline manifest hash; `replayReadiness()` is ready, with families and
   units equal to the plan; `progress().lastProcessed` equals 27; `digestSpecCount` is 1 for `files-content/1` and for
   `files-external/1`. **The index prices like the release** (group `pricing`): `workModel()` read at the index address
   is compared field by field (every field of the ABI's `WorkModel`, formula 3's 32: `formulaVersion`, the three rows,
   `surchargePurpose` and the surcharge rows included) with the deploy plan's work model,
   the deployment document's `index.workModel`, every schedule's `gasModel.schedules.<s>.floor.workModel` in
   `release.json` and, in a checkout, every `profiles.<s>.floor.workModel` in `gas/model.json`; and `describe().limits`'
   floor prices (`floorFreshGas`, `floorRewriteGas`, `kernelTail`) with the `floor.limits` of the schedule that prices
   the chain. A mismatch fails verify naming the field and the document (`pricing workModel.<field>: chain … != …`);
   a document missing a field, or carrying one the chain does not have, fails the same way. `tools/test/release-pricing.test.mjs`
   checks the committed documents against the Solidity struct and the compiled ABI without a chain.
8. **The thirteen Types.** The catalog equals the offline id set. For each Type, `typeInfo` mandatory, ruleId, shape and
   blob; `descriptorBytes` equals the JS descriptor; `refTypes`; `declaration` (key and installed); and the published
   id.
9. **The seed.** Thirteen record headers, seven heads (state, revision, target), the three file subjects created,
   each folder (the root and `docs/`) a 64-byte `files-directory/1` record whose word 0 is the fixture principal and
   which is not a subject, the fixture principal's nonce of 6 (one per publication), the root scope (1 entry, 1 live) and the `docs/` scope (3, 3).
   For each file, from its HEAD revision through `LedgerReads.record`: `readme.txt` (form 0) has the expected length
   and sha256; `big.bin` (form 1) names its `files-content/1` record (carrier 2, the span root, length, sha256, the
   media length word and the media bytes), and
   its span tree is re-assembled node by node (each chunk against its own word-0 sha256, each span against its
   length) into 20,000 bytes with the descriptor's sha256, 3 chunks and 2 spans; `remote.txt` (form 1) names its
   `files-external/1` record (the empty sentinel, version 2, carrier 2, sha256, length, the locator and the media
   type byte for byte),
   and the sentinel is the empty `files-bytes/1` record. `KeysView` reproduces the readme's subject, root record,
   HEAD binding key and the `docs/` scope key.
10. **The readers.** `LensReader`'s `ledger()`, `VIEWS`, `READS` and `layoutId()`; `FilesPageReader`'s `LEDGER`,
    `VIEWS`, `READS`, `LAYOUT`, `NAME_TYPE`, `ROOT_TYPE` and `CHILD_TYPE`. For each kind label, the directory's
    `readers(ledger, kind)` must be exactly that reader with its codehash, `layoutId` and the generation-1 physical
    profile, and the deployment document must list it. `TopicMineReader`'s, `TopicEveryoneReader`'s and
    `TopicLookupReader`'s `LEDGER`, `VIEWS`, `READS` and `LAYOUT` (and the lookup reader's `TOPIC_TYPE` and
    `WORD_TYPE`) equal the plan's, and all three are listed under their kinds. One page of `docs/` through `listDirectory` must be PRESENT
    and `COMPLETE` with exactly three rows in bind order (`readme.txt`, `big.bin`, `remote.txt`, each → its file
    subject, HEAD → its root record). `LedgerReads.record`
    of that root record must return PRESENT with the right Type, word 0 and body.
11. **The `web3://` gateway.** `resolveMode()` is `"5219"`, the gateway's nine immutables (`ledger`, `READS`,
    `VIEWS`, `PAGER`, `CONTENT`, `CONTENT_CODEHASH`, `layoutId`, `ROOT_DIRECTORY`, `DIRECTORY_TYPE`) and the content
    server's nine (`ledger`, `READS`, `layoutId` and the six Files Type ids it interprets) are the planned ones, and
    the content server's code hashes to `readers.web3Gateway.content.runtimeCodehash`. Then
    the seed is read through `request` the way a `web3://` client does it, from the seed root by its folder id
    (`/~efs/o/<root directoryRecordId>/docs/…`, the root's creator as the default lens): `docs/readme.txt` with the
    default lens and with `?lens=<fixture account>` (same bytes, sha256, `text/plain` from the extension, no
    `X-Content-Type-Options`);
    `docs/big.bin` chunk by chunk following `web3-next-chunk` until the header is absent (three chunks, 20,000 bytes,
    the seed's sha256, each with the declared `Content-Type: application/octet-stream` and `nosniff`);
    `docs/remote.txt` as `307` with the seed's locator and `x-efs-media-type`; `docs` as a complete JSON listing of the three files; `404` and `416` for a missing
    name and an offset at the end; the sample file by its object link `/~efs/o/<subject id>` (its creator's HEAD)
    and by its revision link `/~efs/v/<root record id>`, both `200` with the sample bytes and `x-efs-record` the root
    record; `docs/big.bin` by its object link and by its revision link, chunk by chunk (three chunks, the seed's
    sha256); and the link forms: `/docs/readme.txt` (a plain word: a topic path) `501`, `/~home/…` and a principal id
    as the first segment `400`, the sample file's root revision record's id by `/~efs/o/…` `501` and the root folder's
    id by `/~efs/v/…` `501` (existing objects of another kind: never `404`), an id that names nothing `404` by both
    links, `/~efs/v` without an id `400`, and the fixture account's own home `/0x<address>/` a complete listing named
    by `x-efs-home`.
12. **Cold pin.** What an SDK holding only `release.json` and `efs-deployment.json` does on first contact.

### Cold-pin call count (observed)

**9 logical calls in 2 HTTP envelopes**: `eth_chainId`, `eth_getBlockByNumber`, `eth_call LedgerReads.describe`,
`eth_getStorageAt(ledgerProxy, ERC-1967 implementation slot)`, then `eth_getCode` ×5 (implementation,
`LedgerReads`, `LedgerViews`, `LensReader`, `FilesPageReader`). That is exactly the design bound of ≤ 9 calls and
≤ 2 envelopes, and `verify` fails if it is exceeded. `verify` checks the chain id, the implementation, and each of the
five codehashes against `describe()` and the release.

## The `executionSet()` offline equality proof

- **How it is computed.** `tools/deploy-plan.mjs executionSet(set, ledger)` hashes
  `keccak256(abi.encode(DOM_EXECUTION_SET, layoutId, domainSeparator(acceptedChainId, ledger), ComponentSet, uint256
  revision, executionProfileId, capabilities, acceptedChainId, keccak256(abi.encode(Limits))))` with viem's
  `encodeAbiParameters`. The `ComponentSet` and `Limits` tuple types come from the compiled ABI
  (`RealmController.activate`, `RealmGenesis.run`), not from hand-written types. This is the formula of
  `LedgerControl._activate` and `test/harness/ExecutionSets.sol`.
- **Inputs.** Every component codehash is computed offline from the artifact runtime with immutables filled. That
  covers the ledger implementation, the registry implementation, the index (whose manifest hash is also computed
  offline), ingress, apply and the controller (whose immutables are the nonce-derived proxy and admin addresses).
- **Where it is asserted.** First, on chain: G20 passes `expectedExecutionSet` into `RealmController.activate`, and
  both `LedgerControl` and the controller revert with `E_EXPECTED_SET` on any difference, so the genesis activation
  landing is itself the proof. Second, in `up`: `ledger.executionSet()` must equal the plan. Third, in `verify`: the
  live value must equal the plan, and a recomputation from the on-chain revision row's components must equal the
  live value. On the default fixture (chain 31337, salt `keccak256("efs/fixture/realm/1")`) the value is
  `0xf5514949f83a07bdd6811d62d6d2afb6d4b3499e1553b8cd18ad0b260e38f00d`.

## The planning model (`gas/model.json`)

`release/release.json` carries the model as `gasModel`: the constants **keyed by fee schedule** (`schedules.prague`,
`schedules.amsterdam`; one schedule's constants must never be applied on a chain running the other), the file's
sha256, and a **joint envelope**. The Realm limits allow a publication of 64 actions and 16,384 body bytes, which can
need about 28M gas, more than the 16,777,216 one transaction may carry (EIP-7825). `gasModel.envelope` therefore
states what one atomic publication realistically holds, as the smallest of the gas budget (the cap less
`planning.headroomPercent` (15%) for intrinsic gas, calldata and the model's error, less the fixed cost) and the two Realm limits, for six named
shapes: a small and a 1 KB edit, a small and a 1 KB create, an 8 KB chunk and a span node. It is for user-facing
messages ("this save is too large to be atomic"); a planner uses the constants and confirms with `eth_estimateGas`.
Regenerate the model after any change to the kernel, the index or a Files rule, then `pnpm run release`. Media
types: a descriptor's media type is the tail of its body (no length word), so a planner prices a content or external
body by its byte length with the ordinary `perWord`/`perByte` terms and no special case (measured on `test/integration/MediaTypeMeasure.t.sol`: for 9-, 24- and 71-byte types on a small on-chain file and an
external file, the model's predicted change is low by 0.9k-6.4k gas, at most 0.28% of the file on prague and 0.08% on
amsterdam; the residual is the grammar's own validation, about 87 gas a byte against `perByte` 11.8).

`pnpm gas:model` (`node tools/gas-model.mjs [--skip-amsterdam 1]`, forge under the same watchdog and `out/amsterdam`
rule) runs `test/integration/GasModel.t.sol` on both profiles and fits `gas = fixed + Σ cost(action)`, with `PUBLISH` new `= publishNew[shape] + perWord·ceil(n/32)
+ perByte·n` and one constant per other action kind and purpose, plus a once-per-principal first-write surcharge
(amsterdam constants are also split into execution and state gas, since the EIP-7825 cap counts execution only).
`fixed` is the median of `2·k1 − k2` over the **anchor pairs** only (`fit.fixedAnchors`: the forty pairs the model had
at `899767e`, frozen in `tools/gas-fit.mjs`). A row added later is fitted as its own constant and keeps its implied
fixed cost in `fit.impliedFixedByPair`, but it never changes `fixed`, so adding a row never re-prices an existing
action (`tools/test/gas-fit.test.mjs`). It is for planning: the SDK splits a large write into publications from it without one `eth_estimateGas` round trip per
guess, and `eth_estimateGas` stays the authority before sending. It excludes intrinsic, calldata and refunds. The
script predicts seven composites it never fits (create file, edit, rename + move, two chunks, the last publication of
a 40 KB file, a first tag on a fresh 6-word path, a label with a new text) and exits 1 if a prague prediction is off by more than 15%.

**The later rows and the list tiers.** The single-place later rows (`unbindTag`, `releaseTag`, `restoreTag`,
`bindTagNumberChange`, `unbindFolder`, `releaseFolder`, `bindFolderRebind`, and the PROPERTY, SAME and BROADER later
rows) are measured at one topic or folder with short lists; later statements at distinct places and in long lists are
priced by the list tiers below (item 47), which bring every composite within the claim inside the headroom. Since the
list release every later row states the position it was measured at (`laterRows`), a BIND on a head that never bound
has rows of its own (`bind<Purpose>AfterNo`), FOLDER, PROPERTY and HEAD restores are measured to a new target, and a
statement at another position of its binding is corrected by `historyWordOpen`, symmetrically (item 57).

**First tags are priced per level (step 3b, design §10.4).** The index's walk of a tagged topic's ancestors is not in
the kernel's floor, so the model carries it: a first statement at TAG (either sign) costs `bindTagFresh` when no author
has stated anything at its position, `bindTagSecondAuthor` when the position exists (measured as a later author's first yes, an upper bound for a
first no there), plus, for each of the topic's `n − 1` proper ancestors, `tagLevel.mineNew` or
`tagLevel.mineExisting` (the author's `scope-below` list at that ancestor is empty or not) and, at every filing (a
fresh position of either sign, or a later author's first yes; a later author's first no files nothing),
`tagLevel.sharedNew` or `tagLevel.sharedExisting` (the `place-below` list at that ancestor). The SDK reads those list heads (`postingHeadOf`) when it plans; a list holding
exactly 1 entry or a multiple of 5 takes a fresh word on its next append, so price it as new (`tagLists.priceAsNew`; it costs one slot rewrite more than a new list, inside the model's headroom; not separately measured). The terms are measured
by four `tag level` rows (`(k2 − k1) / 4` of a first statement on a 2-word and on a 6-word topic from the same state,
so each is one level: "all" rows a first tag at a fresh position, "mine" rows a first no at an existing position), on both schedules, with the amsterdam execution split as for every constant. A batch of tags is split by
these terms; a publication sent with too little gas fails with `E_INDEX_GAS` and admits nothing. Regenerate and commit it whenever the
kernel, the index or a Files rule changes.

**Statements about topics (`PROPERTY`, `SAME`, `BROADER`, design §12.5).** One constant per statement shape, measured
like every bind row (k2 − k1 of one and two statements at distinct positions, by an author who has written before, the
topics and texts registered by an unmeasured publication in the row's own test). A label is `PROPERTY` at
(topic, `labelKey("en")`) → an existing `text/1`; `SAME` is measured word page to word page and 2-word path to 2-word
path (the two differ by about 100 gas, so a planner may use either), `BROADER` word page to word page; the later
statements are on word pages. None of them has a per-level term: a path costs what a word page does. **A label with a
new text** in the same publication (`EfsTopics.label`) is the `text/1` publish row plus the first statement:
`publishNew["text/1"] + perWord·ceil(n/32) + perByte·n + bindPropertyFresh` for an n-byte text. The composite
`validate label new text` (24 bytes) checks it: predicted 850,458 against 890,871 measured on prague (−4.54%), 2,862,918
against 3,058,505 on amsterdam (−6.39%; this release's model), inside the headroom. The rows (gas; amsterdam execution gas in brackets) and the
nearest existing row:

| constant | statement | prague | amsterdam (execution) | nearest existing row (prague; amsterdam execution) |
|---|---|---:|---:|---|
| `bindPropertyFresh` | a label as a first statement, naming an existing text | 328,774 | 1,303,760 (226,640) | `bindHeadFresh` −0.7%; +2.1% |
| `bindPropertyRebind` | a label changed to another existing text (a re-bind) | 196,281 | 584,361 (192,681) | `bindHeadRebind` −3.9%; −4.0% |
| `unbindProperty` | a mask of a label | 145,913 | 350,753 (154,913) | `unbindTag` −6.4%; −6.1% |
| `releaseProperty` | a release of a label | 144,725 | 349,565 (153,725) | `releaseTag` −6.5%; −6.1% |
| `bindSameFreshWord` | `same`, word page to word page, first statement | 357,488 | 1,413,358 (238,318) | `bindTagFresh` −13.7%; −13.4% |
| `bindSameFreshPath` | `same`, path to path, first statement | 357,384 | 1,413,290 (238,250) | `bindSameFreshWord` −104 gas; −68 gas |
| `unbindSame` | a mask of a `same` | 146,024 | 350,840 (155,000) | `unbindProperty` +111 gas; +87 gas |
| `releaseSame` | a release of a `same` | 144,824 | 349,664 (153,824) | `releaseProperty` +99 gas; +99 gas |
| `restoreSame` | a restore of a masked `same` | 174,603 | 474,639 (180,879) | `restoreTag` −6.5%; −6.3% |
| `bindBroaderFresh` | `broader`, word page to word page, first statement | 357,463 | 1,413,381 (238,341) | `bindSameFreshWord` −25 gas; +23 gas |
| `unbindBroader` | a mask of a `broader` | 146,035 | 350,875 (155,035) | `unbindSame` +11 gas; +35 gas |
| `releaseBroader` | a release of a `broader` | 144,847 | 349,675 (153,835) | `releaseSame` +23 gas; +11 gas |
| `restoreBroader` | a restore of a masked `broader` | 174,614 | 474,662 (180,902) | `restoreSame` +11 gas; +23 gas |

`SAME` and `BROADER` cost the same to within 40 gas, and their masks and releases cost what a label's do; a first
`SAME` or `BROADER` is about 29k above a label's (the validator reads both topics' headers) and well below a first TAG,
which also writes the topic lists. `tools/gas-plan.mjs` prices every one of them from its constants key (`{ kind:
"bind", cost: "bindSameFreshWord", first: true }`) with no purpose-specific code; `first` is true for the three first
statements and false for every later one.

**The list tiers: later statements across places and in long lists (design §10.4).** A later statement (a mask, a
release, a restore, a re-bind) costs more than its single-place row in two ordinary states. The index rewrites the
place's scope head on every later statement, so statements at distinct places rewrite one head each (+4.4k a
statement on prague, +11.6k on amsterdam); and `RealmIndex._foldScope` finds the changed entry with `_entryIndex`, a
bisection of the author's scope list at the place (one bitmap-store call per probe), then flips the entry's live bit,
which from entry 48 up lives in a bits word of its own rather than the head word (a mask, release or restore of entry
48 of 49 at a new place costs +21.8k to +38.9k on prague over the new-place row; at entry 1,024 of 1,025, +44.8k to
+61.9k over the single-place row). A re-bind (a BIND on a
BOUND head: a HEAD re-bind, a folder re-bind, a tag number change, a label re-bind) only stamps the scope head
(`BitmapStore.stamp`) and never searches the list. `gas/model.json` prices this with `laterLists` and the tier rows,
and `tools/gas-plan.mjs` `laterKey` is the reference implementation. One later statement the tier rows do not price
right: a yes after a lone no, for which the restore rows are two fresh slots short; this release's interim consumer
rule adds the two slots (item 42).

*The place and the count.* A later statement's **place** is its (purpose, subject): the author's scope list keyed by
`Keys.scope(author, purpose, subject)`, which `RealmIndex._foldScope` both searches and flips. The **author's entry
count at that place** is that list's length: one entry per position the author has ever stated at that subject, of
either sign, masked and released entries included (entries are appended at a first statement and never removed). It
is not a count of positions, of live entries or of everyone's entries. On chain it is
`IBitmapStore.scopeHead(Keys.scope(author, purpose, subject)).count`; the read that returns it today is
`TopicLookupReader.entryCount(author, purpose, place, false, expected)` (`count`; `live` beside it is the live
entries), for every purpose (the `below = false` path does not restrict the purpose). The cost depends on two things,
the list's length (the search) and the changed entry's index in it (its bits word); tiering by the LENGTH is safe
because an entry's index is always below the length, so a count of at most 48 implies both an entry index below 48
(its live bit in the head word) and a search of at most six probes. **First later statement at its place** is defined
per publication: no earlier later statement of the same publication (of any kind: mask, release, restore or re-bind)
is at the same (purpose, subject). An earlier FIRST statement at that place in the same publication does not change
it (that is the dearer reading). A tag and a label on the same topic are at different places (different purposes).
Omitted, `firstAtPlace` is true.

*The rule* (`laterLists.shortTierMaxEntries` = 48, `laterLists.claimEntries` = 1,024):

| the author's entry count at the place | first later statement at its place in the publication | any further one at that place |
|---|---|---|
| known and ≤ 48 (short tier) | `<row>NewPlace` if the constants carry it, else `<row>` | `<row>` |
| > 48, or not known (long tier) | `<row>LongNewPlace` | `<row>LongSamePlace` |
| a row with no `<row>LongNewPlace` (a re-bind: no tier) | `<row>NewPlace` if the constants carry it, else `<row>` | `<row>` |

1,024 is the cap of the claim, not a third tier: a known count above 1,024 is still priced with the long-tier rows,
and is outside what the stated maxima cover (the composites at 4,097 entries are in state `beyondClaim`, reported with
their errors and excluded from the maxima and the 15% bound, as the floor's documented exception is). The 1,024-entry
rows predict publications at entry 4,096 2.9% low on prague and 1.8% low on amsterdam execution gas (0.5% all gas).

*Per purpose.* The tiers apply to every later statement that searches the author's list:

| purpose | tiered rows (short; long first at a place / further) | no tier |
|---|---|---|
| TAG | `unbindTag`, `releaseTag`, `restoreTag` (each with `NewPlace`, `LongNewPlace`, `LongSamePlace`) | `bindTagNumberChange` (`bindTagNumberChangeNewPlace` for the first at a place) |
| FOLDER (hides, removes, restores) | `unbindFolder`, `releaseFolder`, `restoreFolder` (each with `NewPlace`, `LongNewPlace`, `LongSamePlace`) | `bindFolderRebind` (`bindFolderRebindNewPlace`) |
| PROPERTY | `unbindProperty`, `releaseProperty` (`LongNewPlace`, `LongSamePlace`; the row itself is already a new-place row) | `bindPropertyRebind` |
| SAME | `unbindSame`, `releaseSame`, `restoreSame` (`LongNewPlace`, `LongSamePlace`) | — |
| BROADER | `unbindBroader`, `releaseBroader`, `restoreBroader` (`LongNewPlace`, `LongSamePlace`) | — |
| HEAD | none: a HEAD scope list (subject = the file, role 0) holds at most one entry per author, so it is always the short tier and every HEAD later statement is at its own place; the model has no HEAD mask, release or restore row | `bindHeadRebind` (already measured at distinct files) |

FOLDER is priced on its own rows, measured like TAG's (their long rows come out within 0.1k of TAG's: the same bitmap path), and
checked by its own composites at entry 48 and 1,024 across folders and in a 1,025-entry folder. The PROPERTY, SAME and
BROADER rows are measured at distinct subjects already (their existing pairs state at subjects 0, 1, 2), so they have
no `NewPlace` row; their long rows are their own pairs, and a composite each (masks of 8 spread entries of a
1,025-entry list) checks them.

*What a planner passes* for each later statement: `firstAtPlace` (as defined above, per publication: a part of a split
write is a publication) and `entries`, the author's entry count at that place if it has one it trusts. **No count:**
the long tier, which is safe. **A stale count:** a count lower than the truth puts a long list in the short tier and
UNDER-prices it, by up to 21.2% on prague and 19.1% on amsterdam execution gas (20.4% all gas) for a publication at
entry 1,024 (tag restores at 16 topics; folder releases at 16 folders 18.1% / 19.1%), and by up to 16.8% / 13.9% at
entry 48. So a consumer treats a count from a read older than what it trusts (a basis it no longer holds, or any
publication of the author's since) as unknown. A count above the truth only moves a short list into the long tier,
which over-prices it.

*How it was measured.* Every tier row is its own k1/k2 pair (`GasModel.t.sol` section 9): `<row> new place` at three
places whose lists hold one entry; `<row> long new place` at three places whose lists hold 1,025 entries, each statement
at entry 1,024 (eleven probes, alone in its bits word); `<row> long same place` at one place of 1,025 entries, k1 the
entry at 512 and k2 those at 256 and 768 (spread, so the searches share few probes). The folder re-bind's new-place
pair uses the existing row's target pattern (old targets s[29..32), new s[32..35)). A restore re-appends its target to
the target's backlink list, which takes a fresh word when the list holds one entry (a file named in one folder, a
thing the author tagged once); every restore row (`restoreFolder` and the tier rows) is measured in that state, the
dearer and ordinary one (a first measurement with targets named three times came out 17.9% low on amsterdam all gas
for folder restores across folders). None is an anchor, so `fixed` and
every existing row are unchanged (`tools/test/gas-fit.test.mjs`).

**The floor and the planning rule (design §10.4).** Before each index callback the kernel requires a floor of
execution gas to be visible (`gasleft()`), and on Glamsterdam only execution gas is visible and capped. So that a
planner never sizes a publication the floor refuses, `gas/model.json` carries, per schedule, `profiles.<schedule>.floor`:
the kernel's quote inputs exactly (`workModel`, the Realm's floor prices and kernel tail in `limits`, per-Type `refs`
and digest `specs` in `types`, `callGasRetained` = 63/64, `dispatchOverhead`), `kernel` (the kernel's own execution
gas: every `GasModel.t.sol` publication is also run from the same state with the index's two callbacks answered by
`vm.mockCall`, logged as `kernel frame gas`, and fitted like the constants) and `formula`, the plain statement:

- quote (work-model formula 3, item 42): `fresh10 = freshPerPublication + Σ_publish/reuse(freshPerRef·refs + (new
  record ? freshPerPublishFresh + freshPerDigestSpec·specs : freshPerPublishExisting)) + Σ_rows fresh`, `rw10 =
  rwPerPublication + Σ_publish/reuse rwPerPublish + Σ_rows rw`, `compute = computeBase + n·computePerAction + Σ_rows
  compute`, where each BIND, UNBIND or RELEASE adds one row by class, first statement (head UNSET: `freshPerBindFirst`,
  `rwPerBindFirst`, `computePerBindFirst`), re-bind (a BIND on a BOUND head: `freshPerRebind`, `rwPerRebind`,
  `computePerRebind`) or other later statement (`freshPerBindLater`, `rwPerBindLater`, `computePerBindLater`; a RELEASE
  always), plus the surcharge's row of the same class when its purpose word equals `surchargePurpose` (plain
  equality: a statement's purpose is never zero, `E_SHAPE`, so a zero `surchargePurpose` surcharges nothing that can
  be admitted), and every WITHDRAW after the first adds the later row (a REUSE always names an existing record); with no
  principal every bind-kind action adds the largest of the three rows field by field; `P = compute +
  ⌈fresh10/10⌉·floorFreshGas + ⌈rw10/10⌉·floorRewriteGas`; `F = finalComputeBase + binds·finalComputePerBind +
  publishes·finalComputePerPublish`;
- requirement: `V = max(K + ⌈(⌈P·64/63⌉ + dispatchOverhead)·64/63⌉, E) + ⌈F·64/63⌉ + kernelTail`, E the execution
  estimate (prague `constants`, amsterdam `split.executionGas`) and K from `floor.kernel` with the same composition.

The rule (`planning`): a publication is planned when it is inside `planning.limits` (64 actions, 64 bind-kind actions,
16,384 body bytes) and `max(E, V) ≤ ⌊txGasCap × (100 − headroomPercent) / 100⌋` (2^24 and 15%: intrinsic gas, calldata
and the model's error); anything larger is split before it is signed. **A consumer's headroom check of the cap
condition reads the UNDER-prediction field**: `profiles.prague.maxUnderErrorPercent` on prague (the cap counts all gas)
and `profiles.amsterdam.maxUnderExecutionErrorPercent` on amsterdam (it counts execution gas only), each with its
composite (`maxUnderErrorComposite`, `maxUnderExecutionErrorComposite`). Headroom exists to stop a plan coming out too
small; an over-prediction only costs batch size. Since the list release (item 57) the tool refuses a model with an
UNDER-prediction above 15% anywhere (prague all gas, amsterdam all gas, amsterdam execution gas) or an OVER-prediction
above 15% of the gas the cap counts (prague all gas, amsterdam execution gas); amsterdam's all-gas over-prediction is
refused per composite above 15% plus its later statements × 97,920 state gas over its measured gas (the rows' worst
case, which a planner cannot see), so `profiles.amsterdam.maxOverErrorPercent` and `maxAbsErrorPercent` (the larger
of the under- and over-prediction of all gas) are stated, not bounded at 15%. A roll-up list's next append is priced as new
when it holds a number of entries in `tagLists.priceAsNew.entries` (`[1]`) or a multiple of
`tagLists.priceAsNew.entriesMultipleOf` (5, zero included); the prose rule above is that field. `tools/gas-plan.mjs` is
the reference implementation (it imports nothing and reads only the model it is given; `tools/test/gas-plan.test.mjs`);
`pnpm run release` writes its verdict for twenty-two shapes to `test/vectors/floor-plan.json` (the largest planned count per
schedule with E, K, V, P and F, and the refusal of one unit more), and `test/integration/FloorPlan.t.sol` builds each
shape at that count, checks the kernel's own `prepare` quote equals the rule's P and F (read from the `E_INDEX_GAS` the
first callback reverts with on just enough gas, or `indexFloor` for a publication with no BIND or UNBIND, whose quote
does not depend on heads), and proves it admitted: on prague by running it with exactly 2^24 − 21,000 − calldata,
and on both schedules by `E ≤` and `V ≤` that, with E and K measured from the same cooled state (Foundry's amsterdam
profile has no reservoir and no cap, so there this is arithmetic on the measurement). The shapes: lone negatives on a
one-word topic; first tags at depth 8 and 64, everything new and everything existing; a second author's first tags at
depth 8; masks, releases and restores of tags; number changes of asserted tags; masks of masks; re-binds of
root-folder entries to another file; repeat PUBLISHes of existing name records; fresh name records; a mix of fresh
name records and first tags (one of each per unit); a registration chunk of word pages; create-file recipes; and since
the list release yeses after lone noes on a one-word topic, create-file recipes at removed names and moves into removed
names, each with the name PUBLISH a repeat and with none. For each
the suite also logs the callbacks' prefix spend (E − K − the final phase) and the final phase against P and F, and
for every shape but the first tags (whose depth the floor does not know) and the folder re-binds' final phase it
asserts the quote covers them.

**`ILedgerCommitments.indexFloor` is an upper bound only.** It quotes without a principal, so it prices every
bind-kind action with the largest of formula 3's three rows field by field, surcharge included (with the later row of
formula 3 the first row is no longer the largest on amsterdam). A consumer plans from the gas model's rule
(`planning`, `floor`), never from `indexFloor`.

**Read terms (`reads`, step 4).** Every run also measures the topic readers (`tools/gas-reads.mjs` over
`test/integration/TopicReadMeasure.t.sol`, one cold view call per row, on both schedules) and writes `reads`, a
top-level section of its own: per schedule the measured `rows`, the fitted `terms` (`mine` exact and below: an opening,
a per-lens-author opening term, a per-row base and a per-row term per lens index up to the decider; `everyone` exact
and below: an opening, a per-row base, a per-lens-author term and the cost of a skipped entry at lenses of 1, 8 and
64; the below views are fitted on their worst cases, where the viewed-place check reads a head state for every lens
author asked, and `mineBelowQuiet` / `everyoneBelowQuiet` give the same terms where nothing is stated at the viewed
place; `raw`, `byName`, `about`, `wordPage`, `children`: an opening and a per-row cost), the `bounds` per lens size (the
most worst-case rows, and skipped entries, one call reads under `callGasCap` less `marginPercent`) and
`recommended` (`pageTimesLens` per view, `maxRows`, `limitEntries`). The SDK sizes `limit` and `maxRows` from them;
`--check 1` compares the measured rows exactly, like the publication rows.

`pnpm gas:model:check` (`node tools/gas-model.mjs --check 1 --skip-amsterdam 1`) writes nothing: it re-measures the
prague profile, refits, and exits 1 when a validation composite is off by more than 15% (on amsterdam, on all gas or
on execution gas) or when any fitted constant
or measured row differs from the committed `gas/model.json`, printing the first differences and the regeneration
commands (`pnpm run gas:model`, then `pnpm run release`). Gas is deterministic for identical bytecode, so the
comparison is exact; CI runs it after `pnpm release:check` on the prague build the suites left warm, and without
`--skip-amsterdam 1` it checks the amsterdam profile the same way (locally only: CI never builds amsterdam). The 15%
bound covers every composite the stated maxima count (all but `maximaExcludeStates`), over- and under-prediction
alike. An existing row can move by about 12 gas whenever `test/integration/GasModel.t.sol` itself changes, with no
contract change, because the measured frame depends slightly on the test contract's own compiled code (the Realm's
execution-set hash read in the test differs between the two compiles); so the gas-model check's exact match depends on
that file as well as on `src/`.

## Gas rows written (`gas/report.json`)

`test/integration/FilesRecipes.t.sol` logs `<label> gas` (the `gasleft()` delta around `execute`, so no intrinsic
cost), `<label> frame gas` and, under amsterdam, `<label> frame state gas`. These are machine-readable through
`forge test --json -vv` (`decoded_logs`). The runner executes the suite under the default (prague) profile and under
`--profile amsterdam` (`out/amsterdam`). The rows below are prague and amsterdam gas, then amsterdam state gas:

| §14 row | prague | amsterdam (state) |
|---|---:|---:|
| Root seed (PUBLISH directory, no CREATE) | 669,204 | 2,434,070 (1,958,400) |
| Native 1-leaf PUBLISH (64 B directory body, steady author) | 573,728 | 1,853,575 (1,370,880) |
| M1 create folder (no CREATE; first placement in root, fresh scope) | 1,321,648 | 4,794,960 (3,818,880) |
| M1 create file (5 leaves, fresh folder) | 1,683,620 | 6,044,097 (4,798,080) |
| Edit | 864,746 | 2,775,486 (2,056,320) |
| Rename / move (RELEASE + BIND) | 1,119,266 | 3,608,373 (2,643,840) |
| Remove (RELEASE from BOUND) | 451,399 | 1,210,725 (783,360) |
| Restore (released → same target) | 485,944 | 1,259,805 (783,360) |
| RELEASE from mask | 400,505 | 1,064,745 (685,440) |
| Hide (UNBIND from BOUND) | 435,493 | 1,114,135 (685,440) |
| Restore a released placement (Move-back analog) | 500,851 | 1,355,398 (881,280) |
| WITHDRAW | 444,344 | 1,283,991 (881,280) |

**Read rows** (`reads` in the report; prague). `eth_estimateGas` on the fixture includes the 21,000 intrinsic and
calldata cost, and each read is one `eth_call`:

- `FilesPageReader.listDirectory`, one page of `docs/` (now three rows; limit 32, one principal, unbound basis,
  F_NAME | F_HEADER | F_KIND): 560,160 gas, 548 B calldata, 1,856 B returndata.
- `LedgerReads.record` of `readme.txt`'s root record: 91,620 gas, 68 B calldata, 576 B returndata.

The 1,000-entry filtered folder comes from `test/readers/LargeDirectory.t.sol`, whose `console2.log` lines `forge test
--json -vv` exposes in `decoded_logs`. Each run lists all 1,000 live rows; per-page detail is in the report:

| Run | Calls | Max gas per page | Total gas | Max / total returndata |
|---|---:|---:|---:|---:|
| warm, 30M per call | 6 | 29.8M | 160.3M | 72,800 / 389,664 B |
| cold, 30M per call | 6 | 29.9M | 160.3M | 72,800 / 389,664 B |
| warm, 50M per call | 4 | 50.9M | 165.2M | 119,264 / 387,680 B |
| pages of 100 rows | 11 | 15.6M | 154.8M | 39,392 / 394,624 B |

The prototype needed 199 calls.

The report also carries 26 supplementary recipe steps and the fixture's 79 transaction receipts, which are prague
only and include intrinsic cost:

- Genesis code deposit: 45.44M over 30 transactions (the thirteen rules included).
- Readers and views (R0–R11, 13 transactions): 24.02M (`KeysView`, `LensReader`, `FilesPageReader`, the content
  server and the gateway, the three topic readers and the five listings).
- The thirteen descriptor blobs: 2.10M.
- **Genesis activation: 4.10M**, against the design estimate of ≈ 1.1–1.9M (a finding, not a failure). Most of it is
  `CodeScan` walking every unit of the set; when the fast walk meets a byte that reads as a forbidden opcode before
  the trailer (such as a byte of the 32-byte constants via-IR places after the final `INVALID`), it walks the unit
  again from pc 0, so a unit's constants decide whether it pays a second walk (3.02M before the tag release, which
  added units and code to the set).
- `registerDescribed`: 0.24–0.28M each (design ≈ 0.30M).
- Seed: root 0.66M, folder 1.32M, `readme.txt` 1.68M; `big.bin` 12.57M (two 8 KB chunks, 16,384 body bytes) +
  5.81M (the last chunk, two spans, the descriptor, the revision, the name and both binds); `remote.txt` 2.37M.

## KERNEL-BUG

None found in `src/`. Genesis, activation, registration and seed all ran as specified, and every predicted address
and runtime hash matched the chain.

**HARNESS-BUG (fixed upstream in `be20323`).** `test/harness/doubles/Factory.sol` `RUNTIME` had one stray `ff`
(70 bytes; the canonical runtime is 69). `verify` now prints `Factory.sol RUNTIME matches`, and the deployment
document records `factory.harnessRuntimeMatches: true`.

## DESIGN-DIVERGENCE

Where §8.2/§13 and the code disagree. The code is followed in every case.

1. **G1–G2: there are four kernel units, not three.** `LedgerCore(ingress, apply, control, hotAbiId)` needs a
   `LedgerControl(ingress, apply, predecessorLayoutId = 0)` delegate, which §8.2 does not list. The plan adds step
   **G2c**.
2. **G6: `DescribedTypeRule/1` is not deployed.** The file is untracked and still being written by another agent.
   Genesis passes `wrapperV1 = 0`, as `test/control/RealmController.t.sol` does, and the thirteen Types are all
   NATIVE, so no wrapper is needed. A later `controller.activateWrapper(1, wrapper)` adds it.
3. **G9: `IndexBuild/1` does not exist.** `RealmIndex` takes no build, `Readiness.build` is 0, and the plan has no G9.
4. **G13.** `LAYOUT_ID` is a compiled constant, not an immutable. `PREDECESSOR_LAYOUT_ID` is on `LedgerControl`.
   `SUPPORTED_HOT_ABI_IDS` is computed as `[HOT_ABI_ID]`. `LedgerCore` has no `SELF` immutable.
5. **HOT_ABI_ID.** Resolved at step 3a: the hot and store ids are the selector-and-return-layout fold of §5.3
   (above), gated by `pnpm abi:check`. No `vectors/hot-abi.json` table exists; `SUPPORTED_HOT_ABI_IDS` is `[HOT_ABI_ID]`.
6. **G15: `RealmGenesis`' constructor differs from the design.** It is `(owner, ledgerImpl, registryImpl, realmSalt,
   executionProfileId, limitsHash, readerDirectory, wrapperV1, noticeType, controllerInitcodeHash, proxyInitcodeHash)`.
   It reads the implementation codehashes itself, takes the limits only as a hash, and receives the controller and
   proxy creation codes in `run(limits, controllerInitcode, proxyInitcode)`, pinned by hash. The plan follows this.
7. **G17: `BitmapStore` gets three families, not two.** The design lists `[scope, live-scope]`; the code and
   `test/harness/IndexDeploy.sol` use `[scope, roster, live-scope]` (roster is `NOT_MAINTAINED`). The plan follows
   the code.
8. **G19a/G19: the index is two contracts (step 3a).** **G19a** deploys `IndexReads(ledger, hotAbiId, posting, bitmap,
   units, specs, work)`, which holds the manifest and answers the forwarded reads; **G19** deploys
   `RealmIndex(ledger, decoder, reads)`, which copies units, specs and work model from it and folds its address and
   codehash into the manifest hash (header `efs/index-manifest/2`). Neither takes a `layoutId` (a constant) or build
   arguments, and neither reads the ledger at construction (§8.2 says it reads `counts()` and `layoutId()`). The plan
   passes the real G7 decoder; the suites pass `address(0)`. `efs-deployment.json` records `index.runtimeCodehash` and
   `index.reads {address, runtimeCodehash}`; `verify` checks both codehashes on chain and `readsContract()`.
9. **Work model.** `src/` has no release work model, so the index uses
   `test/harness/doubles/IndexDoubles.sol IndexDoubleDefaults.workModel()` (design §10.4, formula 3; the
   rows are measured per action by `test/integration/FloorSplit.t.sol`, the existing-record and per-publish final
   terms by `test/integration/IndexFloor.t.sol`'s `publish`/`reuse` rows; `gas/model.json` `floor.workModel`
   must equal it, which `pnpm release` asserts). `WorkModel` is returned inline by `IIndexReads.manifest()`, so a
   field added to it moves the two profile words after it; `LensReader` finds them from the struct's encoded size
   (the other readers ask `PHYSICAL_PROFILE()`/`CALLBACK_PROFILE()`), and `test/index/IndexReadsSplit.t.sol` asserts
   the reply's head keeps that shape.
   Limits come from `KernelDeploy.s1Limits()` (the §4.2 values; under `FOUNDRY_PROFILE=amsterdam` the fresh-slot floor
   price is the Glamsterdam execution-gas 12,100, `GLAMSTERDAM_FLOOR` in `tools/deploy-plan.mjs`).
10. **G3/G4/G7 take no arguments.** `LedgerReads`, `LedgerViews` and `IndexReplayDecoder` have the layout compiled in;
    they are not "generated for layoutId" by argument.
11. **Readers.** §8.2 has no reader step, so the plan adds R1–R4 after G20, R5a–R5 (the `web3://` gateway's two
    contracts) after them and R6–R11 (the topic readers, step 4) after R5. The facets `LedgerReads` and `LedgerViews` are not `IReader`s and are not listed; only the five readers
    are. **R0** deploys `KeysView` (the
    pure `Keys` derivations as a view, outside the execution set; the eight key helpers left `ILedgerCommitments`); its
    address is `keysView` in the deployment document and the `up` result.
12. **§13 `fixture/`.** There is no `fixture/` directory, no forge-script-encoded seed transactions, no
    `EfsFixture.sol` and no Multicall3 etch. `--state-dir` exists (above). `--hardfork osaka|prague` chooses the local chain's rules only (default osaka); every planned codehash is a prague build either way, and both give the same addresses. The seed is
    encoded in JS (`EfsNative`-equivalent: both expectations bound through `executionSet()` and the ingress's
    `acceptanceProfileOf`) and recorded in `efs-deployment.json` `seed.transactions` and `expected.json`.
13. **Placement of `release.json`.** `schemas/` named no path, so the manifest is `release/release.json`. The six
    schemas are new, unreviewed drafts.
14. **Seed (`efs-fixture-seed/3`).** The root, `docs/`, and three files in `docs/`: `readme.txt` (form 0, the bytes
    inline after `abi.encode(file, 0)`), `big.bin` (20,000 deterministic bytes, word i = keccak256(abi.encode(
    keccak256("efs-fixture/big.bin"), i)), chunked by `efs/chunking/1` into 8,160-byte chunks, chunks in order then
    spans in post-order, a `files-content/1` carrier-2 descriptor declaring `application/octet-stream`, a form-1
    revision; split by `EfsFiles.split`'s
    greedy rule under 64 actions / 16,384 body bytes into two publications) and `remote.txt` (the empty
    `files-bytes/1` sentinel, a `files-external/1` record with locator
    `web3://0x0000000000000000000000000000000000000000:31337/remote.txt`, media type `text/plain; charset=utf-8` and
    the length and sha256 of a 51-byte text, a form-1 revision). `readme.txt` is inline and has no descriptor, so no
    media type: the gateway's extension fallback. Version 3 (was 2) because the seed's descriptor bodies now carry
    media types a consumer can observe (`Content-Type`, `X-Content-Type-Options`, `x-efs-media-type`). It produces 29 admissions, **17 records**, 7 bindings and 6 publications (CREATE leaves
    are subjects, not records). The JS seed encoder mirrors `EfsFiles` (`chunk`, `split`, `storeContent`,
    `createFileRef`, `externalBody`).

## Not covered, and why

- **The §16.6 reproducible-build attestation ("two clean-rebuild hash sets").** The double build covers runtime and
  creation-code identity across two independent full compiles. `standardJsonInputHash` is `null` because the default
  profile emits no `build_info`.
- **`dependencyRoot`.** It is null: the freeze checklist that defines it does not exist yet.
- **§14 slot columns and `tx.gas` cases.** Fresh, rewritten and cleared slot counts, code bytes and accounts per row
  need a state-diff pass. `tx.gas` below and above 2^24 is not varied, and there are no amsterdam fixture receipts:
  release bytes under `anvil --hardfork amsterdam` would need the reservoir and `tx.gas` above 2^24 for the genesis
  code deposit.
- **Remaining read rows.** Confirm/recovery reads and `LensReader.headsAt` at 64 principals in the report, and
  report read rows on amsterdam (reads are not repriced, so they are prague only there; the topic readers' read terms
  are measured on both schedules in `gas/model.json` `reads`).
- **`vectors/execution-set.json`, `manifest.json`, `hot-abi.json`, `names.json` and the other §13 vectors.** These are
  generator work for `tools/vectors.mjs`'s owner. `release.json` hashes the two vector files that exist.
- **The wrapper, the signed lane, guards, freeze and upgrades.** Out of S1b.3.
