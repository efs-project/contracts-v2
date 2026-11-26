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

**This release IS a re-vendor point.** The SDK is pinned to `3ca53ba` ("Merge the final step: liveness gate, fold-hook
refusal, reader rule, Glamsterdam floor price"); this release (items 42 to 48) moves it to this bundle's head: work-model
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
  states `acrossPlaces`, `acrossPlacesBitsWord`, `longLists`, `beyondClaim`. Nothing was renamed or removed in the model
  itself; the floor's `workModel` now has formula 3's 32 fields (`freshPerBindFresh`, `rwPerBind` and
  `computePerHookEffect` are gone). **A headroom check of the 2^24 cap condition reads `maxUnderErrorPercent` on prague
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

### The final step (the SDK's current pin, `3ca53ba`, against `cbf5b78`)

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
verdicts for seventeen shapes); the SDK's planner must reproduce it.

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
  the floor claims at 1.05× its spend or more (lowest 1.062 on prague, 1.052 on amsterdam).
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
  9.69% on prague, 10.65% of execution gas on amsterdam), and the headroom check reads the under-prediction fields.

**Open:**

- **The per-purpose surcharge's use: the all-authors HEAD list** waits on QUESTIONS Q52. The surcharge itself is built
  (formula 3, item 42; zero for generation 1); if Q52 is answered yes the list is its own family, with the work model
  served from a data contract as it is now, as ruled.
- **Lists beyond the claim.** The floor claims later statements in lists of up to 1,024 entries per author per place;
  it covers up to 4,096 and stops covering from 4,097 (measured: 1.008 at 4,096, 0.995 at 4,097 on prague; 1.003 and
  0.991 on amsterdam). The entry search (`RealmIndex._entryIndex` bisects the author's scope list, one store call per
  probe: about 2.2k per doubling within one place, 4.2k to 5.1k across places) is what makes a later statement grow with
  the list; reading a whole word of five entries per probe near the end of the search, or storing a binding's entry
  index, would shorten or remove it. An index change for a later generation (docs/WORK-MODEL-V3.md, "Landed").
- **A planned full batch that meets lists longer than the planner knows.** A planner cannot see list lengths it has not
  read; a batch planned at its largest size whose statements hit lists beyond what the planner knows can need more
  execution gas than the plan assumed. If that passes the 2^24 cap, `eth_estimateGas` fails and the publication is
  refused at send-time as over the cap, nothing sent; the sender then plans it again in smaller parts.
- **HEAD has no mask, release or restore row in the gas model.** A HEAD scope list holds at most one entry per author,
  so a HEAD later statement is always the short tier at its own place, but the model has no row that measures one (only
  `bindHeadRebind`); a planner prices a HEAD mask, release or restore from the nearest row it has.
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
- **One Unicode generator.** `TopicProfile.REFUSED`, its JS copy and the SDK's vectors are hand-written from Unicode
  15.1; one committed generator from one pinned Unicode version must produce all three (it waits on the fold rule,
  QUESTIONS Q53). Until then the `topic-word/1`, `topic/1` and `text/1` Type ids are provisional.
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

### This release: formula 3, the registry rule, the kept-index fix and the list tiers (against `3ca53ba`)

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
  restore; a RELEASE always). When the action's purpose word equals `surchargePurpose` (never when it is zero), the
  surcharge's row of the same class is added too. With no principal (`indexFloor`), every bind adds the largest of the
  three rows field by field, surcharge included.
- **WITHDRAW:** every WITHDRAW after the first of a publication adds the later row (formula 2 charged a withdraw
  `computePerAction` only, 0.12× its callbacks' spend).
- Generation 1's values: first `55, 20, 44,000` (formula 2's quote to the gas on prague), re-bind `20, 40, 42,000`,
  later `20, 50, 85,000`, no surcharge; the publish, per-publication and final terms are unchanged.
- **What the floor claims for masks, releases and restores:** an author's list of up to 1,024 entries at one place (one
  author's entries at one exact topic, address or folder), any number of places in one publication. It covers up to
  4,096 entries and stops covering from 4,097. Beyond that, nothing a person does fails: before each callback the kernel
  requires the gas left to cover what remains of the quote, so a publication sent with a gas limit from
  `eth_estimateGas` (the least limit at which the whole publication succeeds, callbacks included) and a margin is
  admitted even when a statement's real spend is above the quote; what can fail is a publication sent at or near the
  bare floor, which is refused with `E_INDEX_GAS` and admits nothing. A planner cannot see list lengths, so a batch
  planned at its largest size whose statements meet long lists can need more execution gas than the plan assumed; if
  that passes the 2^24 cap, `eth_estimateGas` fails and the publication is refused at send-time as over the cap,
  nothing sent; the sender splits it and tries again.

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
lists of up to 1,024 entries.

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
  anchor: `fixed` and every existing row are unchanged. New validation `state` values: `acrossPlaces`,
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
  `maxUnderExecutionErrorPercent` 10.65% (`validate create file lists exist`). `maximaExcludeStates` is `["beyondClaim"]`
  on both: the three composites at entry 4,096 of 4,097-entry lists (prague −2.39% to −2.85%, amsterdam −0.33% to
  −0.47% of all gas and −1.64% to −1.82% of execution gas) are listed and not counted. Every maximum is under 15%. The
  tiers move no largest batch (item 43). The constants moved with this release's code, not by a re-fit: `fixed`
  315,854 → 311,787 on prague and 899,174 → 895,683 on amsterdam (the index serves the work model the kernel reads from a
  data contract, item 44), every other existing row −111 to +373 gas; the `tagLevel` terms did not move; 37 constants are new.

**48. Identities of this release** (items 42 to 47 together, against `3ca53ba`, the commit the SDK is pinned to; every
value is in the table below). **Moved:** the release digest (`0xc4935467…71e4`, was `0x9f360a55…f321`), the plan hash
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

### The identity table (this release against `3ca53ba`)

Read from `release/release.json`, `deploy/plan.json` and the sample `release/efs-deployment.json` (default fixture
configuration: chain 31337, salt `keccak256("efs/fixture/realm/1")`) of this release, against the same files at
`3ca53ba` (`git show 3ca53ba:<file>`), the commit the SDK is pinned to; the ABI ids are computed from
`test/snapshots/abi/` with `tools/abi-id.mjs` at both commits. Addresses are the fixture Realm's; on any other
`(chainId, realmSalt)` recompute them with `tools/deploy-plan.mjs`. Every value an SDK vendors is here: the documents'
digests, the identities of the execution set and the index, the ABI ids, every Type id, every deployed unit's address
and runtime codehash, the read bounds and the seed. Beyond the table, `artifacts/` differs from `3ca53ba` in
`IndexReads`, `IndexReplayDecoder`, `LedgerControl`, `LedgerIngress`, `LensReader` and `RealmIndex` (and `LedgerCore` in
its ABI only), and `test/snapshots/abi/` in `IIndexReads.json`, `ILedgerIngress.json` and `Errors.json`. No read bound
moved.

| pin | this release | moved against `3ca53ba` |
|---|---|---|
| release digest (`sha256(release/release.json)`) | `0xc4935467e40c164417878cad8717725f4f71b623386a2f1d95e8e9bd4b9471e4` | yes (was `0x9f360a55…f321`) |
| plan hash | `0x4fc3364f1d30e8f13b06f0535d8a65f54f66fc21c79ff150ac021af67b55c575` | yes (was `0x3b88f634…0a3e`) |
| execution set | `0x9c22c034e660c606de155654f43f35a7a24f29513d6e1d5dd5c94a1e1c60c9e5` | yes (was `0x768d8353…dde7`) |
| index obligations | `0x38ac8541875e7088b16c0d089ffb69e684598d49c1945377378a40135e29d78f` | yes (was `0xbc6d4b7d…3a3a`) |
| index manifest hash | `0x755a082e5564c4c599b61131e11b0ff1a86642fcc53ac1be9cd23b67512d3537` | yes (was `0x073676c0…2e3c`) |
| layout id | `0xc59a1669be13ef347b3e85757f16896d2f324b1bdbc062719a24496e7173b212` | no |
| ABI id `efs/ledger-hot/2` | `0xf37d24d0ced96ce84fa2a8dd011fc0594eec8f33e3212c27762b76fc9e469856` | no |
| ABI id `efs/ledger-hot/2:test` | `0x79a1dd51f600e8d16b964d895a4b415cde8c0a3ba9abe66846842a2f12cbcce0` | no |
| ABI id `efs/posting-store/2` | `0x420c69c26d04ae5ba1cacc694d440d5257b35567851f953775e889406066128a` | no |
| ABI id `efs/bitmap-store/2` | `0x2d01560e82c334b2278e6228309ae5d2129bc4d82e60e7111ee8b9276987ba36` | no |
| status vocabulary id | `0xd873af00e96f1b685c8cf256f1c6cdd79cc546a37704b0b913b514bfdb690f87` | no |
| limits profile id | `0x0ee9b6c0be6c7a4c600b9d48f05847efeb7d01d7e910061522af092c7b5a5055` | no |
| realm id | `0xdfef48c90e48dafc642f4380c8f39c14c1af7d84d5047e5acb7d508d5316460e` | yes (was `0x791e5fa5…4193`) |
| domain separator | `0xef73e6345147076e5cab816f3a50e5695626648b1771dcc6f52a0327322b77d7` | yes (was `0xee65704e…c9a7`) |
| `gas/model.json` sha256 | `0x77848e722c7f122463b009b0ccdc864c5ea40ab750007f490f0721d76c39c438` | yes (was `0x6b754403…8dad`) |
| `release/errors.json` sha256 | `0xc1030128f82e0dec4a6901045bb9f12fc5407dd2a4ff17de973815e282e1606c` | yes (was `0xa3278b62…ff7e`) |
| Type id `files-root/1` | `0xc0cd1cb0ae8a822b60380bdc63e7359005c642c9c5b758f436e1bc8ef7bad41c` | no |
| Type id `files-child/1` | `0xac734de0aa9841fab3eb4903db9ac72ff7fcdb722838b85978106322acf04120` | no |
| Type id `files-directory/1` | `0xc1416234ef270e67d4ea6797f53f8f4e221bf6da1adb57f192220ae108dabcba` | no |
| Type id `files-name/2` | `0x2b4d22da420798302dd4daa0b18bcb0e88d0bff06e43d9c58407bbb0a7e3c27a` | no |
| Type id `files-bytes/1` | `0x9e6efb2374eb521d6f32e828be5cfc1b801c3d139bd0d65fe20c03123bb938f0` | no |
| Type id `files-content/1` | `0xca1cd7e79576ec700b74d301e12f0ada3c15fe92727cfd1ca6853dda1bbb5dfe` | no |
| Type id `files-external/1` | `0xb7c77ee54932f287dbd1d65f78662e9e63a8d80d9364c12616f4b76783350386` | no |
| Type id `directory-alias/1` | `0x0c48b987487897968c6b3688da60e3c6db8e645aac2b481b3a1cc36789aecb61` | no |
| Type id `realm-notice/1` | `0xc9efe343865f6f02915f75a1793e2a303b257cbe4bbd4a128ab936cc18cf5c24` | no |
| Type id `files-span/1` | `0xda1abbbbdcaac315756b708a21cb7bcab21bdca7ddcf994eca8597d20fa2debd` | no |
| Type id `topic-word/1` | `0xadf365a36950129688fc6b662ec39a18f0b54b2cfa634b6ec634ebd3ec8c886b` | no |
| Type id `topic/1` | `0x4ea9b8b24cedad9ad6d9b1dea15789d261812620dfc5ab2c28926c06b832d4cf` | no |
| Type id `text/1` | `0x0b71fa4391f889f8a5c5b80499ad7b3921ec96111ed99aa0d60410a3bdb26a06` | no |
| ledger proxy | `0xe942147e5E9112c64ced569e8f5FA18B20073429` | yes (was `0xFEd9404A…43Ef`) |
| ledger implementation (`LedgerCore`) | `0x13b04891ce92Bec464CA5fDF8e412E4FFB64342E` | yes (was `0xF0C32073…9E40`) |
| ledger ProxyAdmin | `0x6894E327133006F2Fe5383006d14b290a1692035` | yes (was `0x154E96bf…7307`) |
| registry proxy | `0x6cD3F5A2a7c8fDC22259BFFc9a81c699AFBBB415` | yes (was `0xF22eF34A…ab85`) |
| registry implementation | `0x0A5eFCc70026787b94bf6872A8148CA1A29C08C9` | no |
| registry ProxyAdmin | `0x890795926ff55dc3bAC27103c51BF42d5ED7ba44` | yes (was `0x885F77f0…A642`) |
| controller | `0xb89a7b732325bc25194AD9B1b51b72fad00EF770` | yes (was `0xdb1415d6…9be0`) |
| genesis contract | `0xc2EeEe8765C8c99809B99aef72cb748daF3f9F62` | yes (was `0x0628338E…539C`) |
| index (generation 1) | `0x9ca434fCb6EdfBa18e6F985EE9697e903f019f26` | yes (was `0xC2eD8A21…9bfd`) |
| index runtime codehash | `0x086f70d323160eb4ee66d82883c656547e08fda0a841ee38f0b45197b01e67a8` | yes (was `0xc0dee80c…a546`) |
| index reads contract | `0x98de17254E0fb67ee3F5F5800f2BaCF4bAb907DF` | yes (was `0x519cE2e7…9FC9`) |
| posting store | `0x1546aCdEe8ae52b8E3f1e6E79404329B96876D33` | yes (was `0x55c2D07C…f4C3`) |
| bitmap store | `0xCEe929eC6398c54265EFCE369F76dAdD47477088` | yes (was `0xb3d6f841…A1f4`) |
| `readers.ledgerReads` | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366` | no |
| `readers.ledgerViews` | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648` | no |
| `readers.readerDirectory` | `0x77865D8B084589021D9695865475cBED4fc16c31` | no |
| `readers.keysView` | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F` | no |
| `readers.lensReader` | `0xbb20026c277926D7eDD3d9bCa070FEcA85b4E374` | yes (was `0x072C087f…5Bc4`) |
| `readers.lensReader` runtime codehash | `0x862b457115bf94c5220aeef72df6de52c184159349cafb10a570e4e4e4e132d1` | yes (was `0x61e15445…7fe0`) |
| `readers.filesPageReader` | `0x3dba5FD3f30b0390f795846d8b0e4df8ac0df8a2` | yes (was `0xa03716f5…7404`) |
| `readers.filesPageReader` runtime codehash | `0x52f038b5ce032260ac4147389646c72b0c5cc763403e37659834a9f062c42f6c` | yes (was `0x302810eb…dcd6`) |
| `readers.topicMineReader` | `0x45772331A92Bf67Ce3A16c2A15E733777499CE33` | yes (was `0x0de61140…cc6e`) |
| `readers.topicMineReader` runtime codehash | `0xdac80a0c60d729f134153d0ed02901cafb902f5ee0091b0766882bb930efe0fd` | yes (was `0x7f435e19…1bc6`) |
| `readers.topicEveryoneReader` | `0x6082241a955e214432b069beC81A5a57c2EC39A0` | yes (was `0x0E082ab7…a76B`) |
| `readers.topicEveryoneReader` runtime codehash | `0xbae87c8a30fec9efcd372dba070dc0a0b9dfc649b0ff22b51df8a25d41751d41` | yes (was `0xc420fe4b…b70f`) |
| `readers.topicLookupReader` | `0xF9176797604bEE9E49E8C7BC1Ac4a9A1a3B6d1a9` | yes (was `0xE32505C0…d5De`) |
| `readers.topicLookupReader` runtime codehash | `0x48c379a6eee2a1f0caacbe966d885fed1b16037c9bcc22494e22307bd3b74487` | yes (was `0x77800e5d…fe63`) |
| `readers.web3Gateway` | `0x78267F061679839Cb5e483d9aba806d5D032479e` | yes (was `0x99780AaA…583a`) |
| `readers.web3Gateway` runtime codehash | `0xa73f9fffe1fc2ff4b788d502d9222d061057fc16294db24d75f1000fc7505c41` | yes (was `0xec9ea7c9…c029`) |
| `readers.web3Gateway.content` | `0x8d06AbED192b097dbBc2efA37E7F3aaCAB6D5E47` | yes (was `0x7D73d400…3D15`) |
| `readers.web3Gateway.content` runtime codehash | `0x91096216c4ec9ccfa94a7f40fcd4ed54562091a76d794413da539375bffb5a66` | yes (was `0x3113647b…3a08`) |
| `LedgerIngress` (address, runtime codehash) | `0x064cB3432FCEa1965b2531eDe7B6f03461788319 / 0xd3e3e0cfcaba81a37807209c9c138387db51ad1a9ca38aeee6b3b1aee8b4728e` | yes (was `0x23eC6bBD…b1a7 / 0x1491217b…079a`) |
| `LedgerApply` (address, runtime codehash) | `0x4Eb1ab68E26a13a5aFB7dc4866eEAd6d6eA88343 / 0x7d788fac98935e8c48d36d9e4886246093bef0a0eb20d445a7d28db275637669` | no |
| `LedgerControl` (address, runtime codehash) | `0x992482530deb668f7B98D23edb19432796007722 / 0xa0386f81586303a1a8f7d11b79dca2cbd0439ea7938764bdabd182e21d58a6da` | yes (was `0x973f33FE…0160 / 0x078461f1…7daa`) |
| `LedgerReads` (address, runtime codehash) | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366 / 0x7aafb133b4b1b130b239da67027f7de118918861850b94584b68c101e0b71657` | no |
| `LedgerViews` (address, runtime codehash) | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648 / 0xf15400a4921e6b3282e9e1b486a14a4268c0f01b1b18e88234659394abc9eb03` | no |
| `DescriptorStore` (address, runtime codehash) | `0xdD13148b5d7cbFdE29C52a1D3C9D22e969BDE71c / 0x96d412de94866a8ce21410434df2a38eb4e3573169f024ddf9669887df72f5dc` | no |
| `IndexReplayDecoder` (address, runtime codehash) | `0x5fdA1ac334D046E3666FceBe45dBd3F5DaFdd3f4 / 0xf183f5c83d76686f23bc41f8f4e6f6f06447adc54da83f5f2751128ebf00dd03` | yes (was `0x49e9bC76…ED1b / 0x0f2574f4…2605`) |
| `ReaderDirectory` (address, runtime codehash) | `0x77865D8B084589021D9695865475cBED4fc16c31 / 0xb929f9e1714d97a570f12cf66daeeff6f06cfb10b373c1a1b22cc51238c31b5f` | no |
| `FilesBytesRule` (address, runtime codehash) | `0xdD9AE013bf2CCaf784626D70bcab5Be307b07e40 / 0x26b7e1529674fd83c36fbe5ccc9dab915a2f1821d853c707a2cd187e68066d2c` | no |
| `FilesSpanRule` (address, runtime codehash) | `0x248C3f75c03d525c1813e6dCeDFAd10E2193a8b7 / 0x15a6e10285c6953d9157a023a600f567b5cd2dfb807070c85517f6774fb8e5f6` | no |
| `FilesContentRule` (address, runtime codehash) | `0x24a5E41C539FB0e1FF5924239fE23D3bF86De11E / 0x9989c5027fc25da8bceb23b0b5dab216bb1f33c2f8b8fd5d04bc8485bcc712a9` | no |
| `FilesExternalContentRule` (address, runtime codehash) | `0x9A0B471E27F1CDC8478E214c301aA6Aa4F189FaF / 0x637f6861202f82a7432588841d9a5544375dac5d0e77710db9b7b986f7f06f55` | no |
| `FilesRootRule` (address, runtime codehash) | `0xd65df37B79581dEdC752ECDf3325bD91e54c561E / 0xcb7ba484cea9625fa2a8cbc35f81b312a1c936f2c69339e325fa5c4a7b5a9f39` | no |
| `FilesChildRule` (address, runtime codehash) | `0x4d670A2Ef8915ccb1347b6BcC01C1efd073fB6A8 / 0x38d96ac3bc562bdc7adf3708808ab74c2420b46a2df59af8107e4e952f90f9d4` | no |
| `FilesDirectoryRule` (address, runtime codehash) | `0x5A266C0a5428e3caDe9F4c5a8B830DCBDf478615 / 0xaea9d912818cd9f49a7b8426807494ca91551040ec499ec6dfaec6e40ad6bfd2` | no |
| `FilesNameRule` (address, runtime codehash) | `0x245098a6b090227e8F542c460f1C3be3F948884f / 0xd73a9ee29819be1f26d1bc18d766fc0118d68555005c9c6acafc6e64bfdbfd17` | no |
| `RealmNoticeRule` (address, runtime codehash) | `0xB0be8d1E04D0B5D5268C05a6330c3254d6e5df34 / 0x52b5a16a788796687ec4607ff1ef59c4d99140c5eea9f583e8239b9d79b0ddcc` | no |
| `DirectoryAliasRule` (address, runtime codehash) | `0x60B6B7611961E258dC8FF63b37830281Ce0F4bDa / 0xc10493df425c8ccfa89ee4f6948a0a85bacc0426127510fa337562fe68ddb667` | no |
| `TopicWordRule` (address, runtime codehash) | `0x44186F79ddA5e09dce338b0649b4c5E6ee4432a5 / 0x29442a0e789e1692d9ffc9e9c5202ee791f06860417b5dbd8ceeaffe81f1dfd5` | no |
| `TopicRule` (address, runtime codehash) | `0xD07aaA9b8b6719B7E8Af64e34B4366700c9a4CdC / 0x6c3de3abe7422d0f0150b084e5a14ea4918c75f7f681ba9da0424f2460b6d69a` | no |
| `TextRule` (address, runtime codehash) | `0xD10088139D60Be3faB03FD3012F3706C3Ac69485 / 0xb839d97202882243312d2792eebda9be94bb272490e3d652c73f2a1a9a0661a5` | no |
| `RefuseAllPolicy` (address, runtime codehash) | `0xeba0FBaa0F4bE2a8444C994783120094fFe2BBB1 / 0xefcebe5a8ee27ed2e419e3753d17a6ad67a87fe257797ad10652bd3bc44b2a44` | no |
| `FilesFinalValidator` (address, runtime codehash) | `0xc672EfB35936f09A05611f5f61057Ef2C4DD35C0 / 0xeb744b64ca0d1d994bc0a1b260382c55b768b53fbbc55ba7bbac9fa7e1cb1619` | no |
| `LedgerCore` (address, runtime codehash) | `0x13b04891ce92Bec464CA5fDF8e412E4FFB64342E / 0x2fdc95dda795c657c7500ee5ee2644fe0ceb6ee5a5bf4cd7e25f21366d56f23f` | yes (was `0xF0C32073…9E40 / 0x69dd1897…bef1`) |
| `TypeRegistry` (address, runtime codehash) | `0x0A5eFCc70026787b94bf6872A8148CA1A29C08C9 / 0xa7e9307a6ef01411f232895f1ae4a5f40b095b5c8da8788a259ffc06846178d3` | no |
| `RealmGenesis` (address, runtime codehash) | `0xc2EeEe8765C8c99809B99aef72cb748daF3f9F62 / 0x631085c94713962726cd0e64ab985602dcf9c6e6542aa88b2fd079b27bf0272c` | yes (was `0x0628338E…539C / 0x5b057dff…3d9a`) |
| `PostingStore` (address, runtime codehash) | `0x1546aCdEe8ae52b8E3f1e6E79404329B96876D33 / 0xc2b395ce1b118831a35bd0e72a6ca07382887fd106281b6cf9e93549fd164465` | yes (was `0x55c2D07C…f4C3 / 0xa4b86e30…4a8d`) |
| `BitmapStore` (address, runtime codehash) | `0xCEe929eC6398c54265EFCE369F76dAdD47477088 / 0xd8b36e1b30ec57c36304f9d0a86785bc7e8e00ec8028abb0097c060399442fdd` | yes (was `0xb3d6f841…A1f4 / 0x3569a27c…95d9`) |
| `RealmController` (address, runtime codehash) | `0xb89a7b732325bc25194AD9B1b51b72fad00EF770 / 0x93341dc000015afd1a3c22e833d1ebb06e4239d253430a6ab6973f1a1de53930` | yes (was `0xdb1415d6…9be0 / 0x646adad3…2e2f`) |
| `TypeRegistryProxy` (address, runtime codehash) | `0x6cD3F5A2a7c8fDC22259BFFc9a81c699AFBBB415 / 0xd044c103027b2c4ac7472651a7bc92cb82606b2a878b423a1146850a70015264` | yes (was `0xF22eF34A…ab85 / 0x2e2060da…e263`) |
| `LedgerProxy` (address, runtime codehash) | `0xe942147e5E9112c64ced569e8f5FA18B20073429 / 0x9e0eb139edf90b2bac14563b114e92c6ba2f5a330686a4e9ec1003e57179ded1` | yes (was `0xFEd9404A…43Ef / 0xd9f1cf09…4134`) |
| `RegistryProxyAdmin` (address, runtime codehash) | `0x890795926ff55dc3bAC27103c51BF42d5ED7ba44 / 0xf32a01cd7613147ce1fce81b16c52ddeb9377c8a9ec26c61cbfca5f1251752b2` | yes (was `0x885F77f0…A642 / 0xf32a01cd…52b2`) |
| `LedgerProxyAdmin` (address, runtime codehash) | `0x6894E327133006F2Fe5383006d14b290a1692035 / 0xf32a01cd7613147ce1fce81b16c52ddeb9377c8a9ec26c61cbfca5f1251752b2` | yes (was `0x154E96bf…7307 / 0xf32a01cd…52b2`) |
| `IndexReads` (address, runtime codehash) | `0x98de17254E0fb67ee3F5F5800f2BaCF4bAb907DF / 0x9abcfb6220404631fcd97e6ac59f6f5cdcd92680cd6afde0e2967fbe79072f43` | yes (was `0x519cE2e7…9FC9 / 0x09258a9a…2007`) |
| `RealmIndex` (address, runtime codehash) | `0x9ca434fCb6EdfBa18e6F985EE9697e903f019f26 / 0x086f70d323160eb4ee66d82883c656547e08fda0a841ee38f0b45197b01e67a8` | yes (was `0xC2eD8A21…9bfd / 0xc0dee80c…a546`) |
| `KeysView` (address, runtime codehash) | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F / 0xaede6581bd6c30cad13acfdab4ccf0792e45c4e1686c453545d4559831201ab3` | no |
| `LensReader` (address, runtime codehash) | `0xbb20026c277926D7eDD3d9bCa070FEcA85b4E374 / 0x862b457115bf94c5220aeef72df6de52c184159349cafb10a570e4e4e4e132d1` | yes (was `0x072C087f…5Bc4 / 0x61e15445…7fe0`) |
| `FilesPageReader` (address, runtime codehash) | `0x3dba5FD3f30b0390f795846d8b0e4df8ac0df8a2 / 0x52f038b5ce032260ac4147389646c72b0c5cc763403e37659834a9f062c42f6c` | yes (was `0xa03716f5…7404 / 0x302810eb…dcd6`) |
| `EfsWeb3Content` (address, runtime codehash) | `0x8d06AbED192b097dbBc2efA37E7F3aaCAB6D5E47 / 0x91096216c4ec9ccfa94a7f40fcd4ed54562091a76d794413da539375bffb5a66` | yes (was `0x7D73d400…3D15 / 0x3113647b…3a08`) |
| `EfsWeb3Gateway` (address, runtime codehash) | `0x78267F061679839Cb5e483d9aba806d5D032479e / 0xa73f9fffe1fc2ff4b788d502d9222d061057fc16294db24d75f1000fc7505c41` | yes (was `0x99780AaA…583a / 0xec9ea7c9…c029`) |
| `TopicMineReader` (address, runtime codehash) | `0x45772331A92Bf67Ce3A16c2A15E733777499CE33 / 0xdac80a0c60d729f134153d0ed02901cafb902f5ee0091b0766882bb930efe0fd` | yes (was `0x0de61140…cc6e / 0x7f435e19…1bc6`) |
| `TopicEveryoneReader` (address, runtime codehash) | `0x6082241a955e214432b069beC81A5a57c2EC39A0 / 0xbae87c8a30fec9efcd372dba070dc0a0b9dfc649b0ff22b51df8a25d41751d41` | yes (was `0x0E082ab7…a76B / 0xc420fe4b…b70f`) |
| `TopicLookupReader` (address, runtime codehash) | `0xF9176797604bEE9E49E8C7BC1Ac4a9A1a3B6d1a9 / 0x48c379a6eee2a1f0caacbe966d885fed1b16037c9bcc22494e22307bd3b74487` | yes (was `0xE32505C0…d5De / 0x77800e5d…fe63`) |
| read bounds (prague): limitEntries, maxRows, pageTimesLens mine exact / mine below / everyone exact / everyone below | `245, 150, 768 / 416 / 688 / 408` | no |
| read bounds (amsterdam): limitEntries, maxRows, pageTimesLens mine exact / mine below / everyone exact / everyone below | `245, 150, 768 / 416 / 688 / 408` | no |
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
priced by the list tiers below (item 47), which bring every composite within the claim inside the headroom.

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
and `tools/gas-plan.mjs` `laterKey` is the reference implementation.

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
  always), plus the surcharge's row of the same class when its purpose word equals `surchargePurpose` (never when that
  is zero), and every WITHDRAW after the first adds the later row (a REUSE always names an existing record); with no
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
small; an over-prediction only costs batch size. The maximum-error fields (`maxAbsErrorPercent`,
`maxAbsExecutionErrorPercent`) keep their meaning, and the tool refuses a model in which any of the four exceeds 15%. A roll-up list's next append is priced as new
when it holds a number of entries in `tagLists.priceAsNew.entries` (`[1]`) or a multiple of
`tagLists.priceAsNew.entriesMultipleOf` (5, zero included); the prose rule above is that field. `tools/gas-plan.mjs` is
the reference implementation (it imports nothing and reads only the model it is given; `tools/test/gas-plan.test.mjs`);
`pnpm run release` writes its verdict for seventeen shapes to `test/vectors/floor-plan.json` (the largest planned count per
schedule with E, K, V, P and F, and the refusal of one unit more), and `test/integration/FloorPlan.t.sol` builds each
shape at that count, checks the kernel's own `prepare` quote equals the rule's P and F (read from the `E_INDEX_GAS` the
first callback reverts with on just enough gas, or `indexFloor` for a publication with no BIND or UNBIND, whose quote
does not depend on heads), and proves it admitted: on prague by running it with exactly 2^24 − 21,000 − calldata,
and on both schedules by `E ≤` and `V ≤` that, with E and K measured from the same cooled state (Foundry's amsterdam
profile has no reservoir and no cap, so there this is arithmetic on the measurement). The shapes: lone negatives on a
one-word topic; first tags at depth 8 and 64, everything new and everything existing; a second author's first tags at
depth 8; masks, releases and restores of tags; number changes of asserted tags; masks of masks; re-binds of
root-folder entries to another file; repeat PUBLISHes of existing name records; fresh name records; a mix of fresh
name records and first tags (one of each per unit); a registration chunk of word pages; create-file recipes. For each
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
