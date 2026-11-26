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

**14. `ILedgerCommitments.indexFloor` is an upper bound only.** It quotes without a principal, so it prices every
BIND and UNBIND as a first statement; it is exact only when every bind-kind action is one. Plan from the gas model's
rule, never from `indexFloor`.

**15. Pre-freeze gates** (none blocks a disposable testnet; each blocks freezing a Realm):

- **The build-from-history step and its three counters.** A later index generation builds its new families from
  history before it is attached (design §10.6). It must rebuild three COUNTERS, not only list entries: family 5's
  `live`, family 20's yes-count and the distinct figure of families 6 and 7. The design is `docs/INDEX-BUILD.md`
  (reviewed 2026-11-25), built in four steps. **Done (step 1, item 23):** a generation that carries every store it
  names (a re-pin, for example generation 1's code with a fixed hook) can be built and activated on a Realm with
  history, and the kernel's two readiness checks of carried and fresh stores (`E_INDEX_NOT_READY` 12 and 13) are in
  `LedgerControl`. **Done (step 2, item 26):** the budgeted walk of history into a generation's fresh stores, for
  generation 1's families: a generation can rebuild both stores (the heal path, case (e)) or rebuild either store
  while carrying the other, and the rebuilt stores, all three counters among them, equal the live ones
  (`test/index/BuildWalk.t.sol`). **Not done:** a generation that carries the genesis stores and builds a NEW family
  into an extra fresh store, with its deployer plan, its reads contract's per-family store routing and the
  built-equals-live tests for that family (step 3), and the measured cost of a build (step 4; step 2's preview: every
  admitted publication shape builds in one call under 2^24 on both schedules, so leaf-granular resume is not needed).
  **Done (step 3a, item 32): the as-of rule.** A fold from history reads every fact as of the admission it folds and
  takes no fact from a validator's law, so a build is exact over any admitted history, including history no validator
  judged (docs/INDEX-BUILD.md §4.3, which audits every read of the fold and the decoder). **Done (step 3b, item 34):**
  the harness generation (it carries the genesis stores, keeps a new list, `head-authors`, in a third fresh store,
  has a deployer plan of carried and fresh stores and a reads contract that routes and covers per family; an example,
  not product) and built-equals-live for that list against a Realm that ran it from genesis, every counter included;
  the dropped-list test (dropping a list from a carried store activates, the replaced generation's late walk writes
  only the dropped list, declaring it in that store again is refused 12, the kept lists equal a twin Realm's: no
  kernel refusal was needed); the reader test for partial coverage (every topic view: UNKNOWN is a refusal with no
  rows, PARTIAL a PRESENT page that states its coverage, never COMPLETE; since item 36 PARTIAL is treated exactly as
  UNKNOWN); a new unit's fold hook built with the walk;
  and the written rule for a fold hook and history (rule (i), docs/INDEX-BUILD.md §3.6). So "a later generation can
  add this list" (for example the all-authors list on a file's versions, QUESTIONS Q52) is now shown. **What remains
  of the gate:** the measured gas of a build on both schedules (step 4); the liveness gate below; a re-pin that adds a
  unit with a fold hook builds no history for it (docs/INDEX-BUILD.md §3.6: a generation adding such a unit needs a
  fresh store, nothing refuses the other shape); case (d), a digest spec rebuilt in a fresh store (its test, §8 test
  9); and, if a real later generation adds a HEAD list, a per-purpose work-model term or an accepted over-quote of TAG
  and FOLDER statements (docs/INDEX-BUILD.md §10 item 27). A build walks the whole history, so a later list has a
  price (its §6.2).
- **Activation must not depend on the live index answering** (docs/INDEX-BUILD.md §10, new with step 2). The kernel's
  check 12 and the generation's carried check read the live index's `replayReadiness().families` whenever the
  candidate carries a store. If that read reverts, the kernel's activation reverts with the live index's own error and
  the generation's check fails, so a broken live index can be replaced only by a full replay into fresh stores. The
  list is static (the live index's manifest, whose hash the revision row records), so the kernel could check a copy
  the candidate carries against the recorded `indexManifestHash` instead of calling the live index; not built. Until
  then, the recovery route is a full replay.
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

**A consumer re-vendors for this release.** It is the next re-vendor point after `0fb4804`, the commit the SDK is
pinned to: re-vendor the same directories as above (`test/snapshots/abi/` included) and re-pin every value of the
identity table below, which compares against `0fb4804`. Between `0fb4804` and this release:

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

### The topic readers answer only from complete lists (this release against `4003069`)

**A consumer re-vendors for the release this lands in** (`release/`, `artifacts/`, `deploy/plan.json`,
`gas/model.json` and the rest of the set above, together): the three topic readers' bytecode, and so their addresses,
change. Their ABIs do not (`test/snapshots/abi/` is unchanged), and nothing observable changes on a Realm whose live
index is complete, which every live index is: the rule only decides what a reader does with an index that reports a
list PARTIAL, and a live index never does.

**36. The list-coverage rule.** A topic reader (`TopicMineReader`, `TopicEveryoneReader`, every view of
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

For consumers, in one line: a served topic page can be trusted to come from complete lists, and UNKNOWN on a topic view
now also covers "the index is still building this list".

**37. Identities.** PLACEHOLDER, filled in at regeneration: the release digest, the plan hash, the three topic
readers' addresses, runtime codehashes and initcode, their `artifacts/` files, the `gas/model.json` `reads` terms if
they move, and the list of what did not move.

### The identity table (this release against `0fb4804`)

Read from `release/release.json`, `deploy/plan.json` and the sample `release/efs-deployment.json` (default fixture
configuration: chain 31337, salt `keccak256("efs/fixture/realm/1")`) of this release, against the same files at
`0fb4804` (`git show 0fb4804:<file>`), the commit the SDK is pinned to. Addresses are the fixture Realm's; on any other
`(chainId, realmSalt)` recompute them with `tools/deploy-plan.mjs`. Every value an SDK vendors is here: the documents'
digests, the identities of the execution set and the index, the ABI ids, every Type id, every deployed unit's address
and runtime codehash, the read bounds and the seed. Beyond the table, `artifacts/` differs from `0fb4804` in
`IndexReads`, `LedgerControl`, `RealmIndex` and the three topic readers, and `test/snapshots/abi/` in the three topic
readers' interfaces.

| pin | this release | moved against `0fb4804` |
|---|---|---|
| release digest (`sha256(release/release.json)`) | `0x56bd2f9524e3de85cada737526b1e237c6f69c1b8822f2d36b2a9805100c2565` | yes (was `0x580ede64…d04e`) |
| plan hash | `0xe40993daed758041730c5e7b728b86c1171da768c570522bcba2e07b9a432a2c` | yes (was `0xff2f4490…6d83`) |
| execution set | `0x0788d65963e48f73fe655a469cc2110365bc9e498cc37c56030d60ac3a9cb99d` | yes (was `0x3a9a6aea…93e4`) |
| index obligations | `0x5555dbfb2f06017916926a884b60e8cd72ac362a37661dc09d3e6b3674674f79` | yes (was `0x9150afe9…6524`) |
| index manifest hash | `0x3b50d7a2f8ee5104dc0038713dac38a902b16e2045d4904e73635606ef33009f` | yes (was `0x608cabe7…006c`) |
| layout id | `0xc59a1669be13ef347b3e85757f16896d2f324b1bdbc062719a24496e7173b212` | no |
| hot ABI id `efs/ledger-hot/2` (release) | `0xf37d24d0ced96ce84fa2a8dd011fc0594eec8f33e3212c27762b76fc9e469856` | no |
| hot ABI id `efs/ledger-hot/2:test` (suites) | `0x79a1dd51f600e8d16b964d895a4b415cde8c0a3ba9abe66846842a2f12cbcce0` | no |
| posting store ABI id | `0x420c69c26d04ae5ba1cacc694d440d5257b35567851f953775e889406066128a` | no |
| bitmap store ABI id | `0x2d01560e82c334b2278e6228309ae5d2129bc4d82e60e7111ee8b9276987ba36` | no |
| status vocabulary id | `0xd873af00e96f1b685c8cf256f1c6cdd79cc546a37704b0b913b514bfdb690f87` | no |
| limits profile id | `0x0ee9b6c0be6c7a4c600b9d48f05847efeb7d01d7e910061522af092c7b5a5055` | no |
| realm id | `0xc1e804018fed84a16135c2c3241382251686115d655e79f6e86e347bcba4700a` | yes (was `0x95909a76…e0e5`) |
| domain separator | `0x50636c43bdf2a174ee18b4b73db46465f0898170b8997fe04af75ff8d03f3c91` | yes (was `0xe7865609…2413`) |
| `gas/model.json` sha256 | `0xa4b9f64bf6fe40e27b6c0db6bbaee3fc39bb43a7bc8e5fc2a4fe74cf90b53e34` | yes (was `0xe4df874a…f09d`) |
| `release/errors.json` sha256 | `0xa97d387cae3fcdcc57ff79787d418603664791d08188388859478d7458e21f17` | yes (was `0xaa8fa61b…640c`) |
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
| ledger proxy | `0x83ce0B9E2DDd9c5CEBBfe6b2b9Bc275fda9A20fB` | yes (was `0x83DbD341…30C6`) |
| ledger implementation (`LedgerCore`) | `0x3C56f31A136aB3F04F1cD1e6eaa6f6AE56c0042C` | yes (was `0x074Dc885…8fF5`) |
| ledger ProxyAdmin | `0x5e292A49455b94545a6818F59c224e1c0B3350AB` | yes (was `0x428D1ac2…24B1`) |
| registry proxy | `0xa1657E67598eeC461e2bf0Ac5CB3903CA7C40BD2` | yes (was `0xdFCd716a…AD7C`) |
| registry implementation | `0x0A5eFCc70026787b94bf6872A8148CA1A29C08C9` | no |
| registry ProxyAdmin | `0x2dEb3CeB5454811F0D1aE8d2619bBa1F3FFc1439` | yes (was `0xb6DD5442…0D81`) |
| controller | `0xA6aFe20eD91162AC8AfE9aE082522fB69cb66E30` | yes (was `0x126c1775…9296`) |
| genesis contract | `0xff73065986D14D2E1D1050d59f7cCd7ACe043533` | yes (was `0x6fCEec8E…36bf`) |
| index (generation 1) | `0x6ebfdf09F489bBdBeeF929bcb0C8B7eae02217f7` | yes (was `0xCa5A752A…d4Dc`) |
| index runtime codehash | `0x3ce5e1501d5edb8090832d0fc9b960f5d99efce7716b18598c64160c1013b452` | yes (was `0xd07b8751…8c7a`) |
| index reads contract | `0x7345300136217575d8eC1cFd1beA91d25c9A329d` | yes (was `0x2Ce5BD78…92e6`) |
| posting store | `0xA5CE13aB7011FcE7357b79e0267251499055DCB9` | yes (was `0xdAB85C02…94DE`) |
| bitmap store | `0x508EB68a5e2a3aF1954e161d590B28B3C6d02D1B` | yes (was `0x164F6F6a…457F`) |
| `readers.ledgerReads` | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366` | no |
| `readers.ledgerViews` | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648` | no |
| `readers.readerDirectory` | `0x77865D8B084589021D9695865475cBED4fc16c31` | no |
| `readers.keysView` | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F` | no |
| `readers.lensReader` | `0x268B3c8BfA3501D22aBAd8D90CD0EB93909C70aB` | yes (was `0x5CaDE2E3…f143`) |
| `readers.lensReader` runtime codehash | `0x1e292b4ddd241b346e6789b20810a3dacbf36709958874a11be3c3ae84177c07` | yes (was `0x860798ab…8ce1`) |
| `readers.filesPageReader` | `0xc00D538AC16c07B678a017E24c7d2d6Ce9648F2A` | yes (was `0x6c9b137B…c882`) |
| `readers.filesPageReader` runtime codehash | `0x149a571c99b2dbf8d972a1ba436f2cc3f9acc8fbaf539b3f689d54e49087f2c4` | yes (was `0xb92d98d3…8dcd`) |
| `readers.topicMineReader` | `0xFB2f372bebEa5204292ebf4Aefd19EB4e4E09f21` | yes (was `0xE53496e1…d247`) |
| `readers.topicMineReader` runtime codehash | `0x2a7d824c8a0dc7a9499cf0d38e0f6104a950268c8ac0eb0876c1e2ef108b15cc` | yes (was `0xb63c773d…4b25`) |
| `readers.topicEveryoneReader` | `0x1ee0AB9D6f342cE440BA1a16f53c6FF3C8f986D2` | yes (was `0x5bfC28aC…eC0D`) |
| `readers.topicEveryoneReader` runtime codehash | `0x50347b7bdc521b6b3531efbf3ee7286a6274bfdc9f3811c31188ff71d23cbe5e` | yes (was `0x4004a077…1fe6`) |
| `readers.topicLookupReader` | `0xC74BacA330C94774f332F918FbDca568AB5E119C` | yes (was `0x99B1C129…7204`) |
| `readers.topicLookupReader` runtime codehash | `0x8068237209320bb83f2b2b1580185d3a1064e8c818841e7fef6d6eaa44e25596` | yes (was `0xb97894ec…8649`) |
| `readers.web3Gateway` | `0xcA9eC410de151d86C3620EbBbc3Aa9DF0E822981` | yes (was `0x18c605A8…6077`) |
| `readers.web3Gateway` runtime codehash | `0xcd627a0eeb1ee4943a407382c30b4d1a75cc6074131761a85cb5fe6cc4242727` | yes (was `0xc1051430…85a8`) |
| `readers.web3Gateway.content` (`EfsWeb3Content`) | `0x502a7CCe35D221884FBfFE4f32687C4e288841FA` | yes (was `0x2c80161a…4929`) |
| `readers.web3Gateway.content` runtime codehash | `0x4e20242c4ab3065cfc558a4423978d15edbb8f7ba2318d90a22d892f74d519aa` | yes (was `0xcc3533b8…a060`) |
| `LedgerIngress` (address, runtime codehash) | `0x23eC6bBDeE632Cd4C0131bD7ED5915B286cEb1a7` / `0x1491217b620dce1fd28b6aaf6d17c0ab4a41c507bb0cf44e8379cd35a4b0079a` | no |
| `LedgerApply` (address, runtime codehash) | `0x4Eb1ab68E26a13a5aFB7dc4866eEAd6d6eA88343` / `0x7d788fac98935e8c48d36d9e4886246093bef0a0eb20d445a7d28db275637669` | no |
| `LedgerControl` (address, runtime codehash) | `0x7f9eA1e98fb218467F6B7632bd64e07b36A6789e` / `0xb56cb5079ee7082629918824d81dde7ca9c265fb13353d58164e57b5d07e00ec` | yes (was `0x5c82f235…5564` / `0x6cf43cd4…34c1`) |
| `LedgerReads` (address, runtime codehash) | `0x76E3Fb2DF9cbce48C4819b2C51c17216668E9366` / `0x7aafb133b4b1b130b239da67027f7de118918861850b94584b68c101e0b71657` | no |
| `LedgerViews` (address, runtime codehash) | `0xdf43CDcc94948Ce810eC640615b21C0BE1fE5648` / `0xf15400a4921e6b3282e9e1b486a14a4268c0f01b1b18e88234659394abc9eb03` | no |
| `DescriptorStore` (address, runtime codehash) | `0xdD13148b5d7cbFdE29C52a1D3C9D22e969BDE71c` / `0x96d412de94866a8ce21410434df2a38eb4e3573169f024ddf9669887df72f5dc` | no |
| `IndexReplayDecoder` (address, runtime codehash) | `0x49e9bC76aaE1a2585885D876311Daa4c974aED1b` / `0x0f2574f466a8c3d6bb667d72dd1fdbfc9222636e26c33b4224ccc766fb8f2605` | no |
| `ReaderDirectory` (address, runtime codehash) | `0x77865D8B084589021D9695865475cBED4fc16c31` / `0xb929f9e1714d97a570f12cf66daeeff6f06cfb10b373c1a1b22cc51238c31b5f` | no |
| `FilesBytesRule` (address, runtime codehash) | `0xdD9AE013bf2CCaf784626D70bcab5Be307b07e40` / `0x26b7e1529674fd83c36fbe5ccc9dab915a2f1821d853c707a2cd187e68066d2c` | no |
| `FilesSpanRule` (address, runtime codehash) | `0x248C3f75c03d525c1813e6dCeDFAd10E2193a8b7` / `0x15a6e10285c6953d9157a023a600f567b5cd2dfb807070c85517f6774fb8e5f6` | no |
| `FilesContentRule` (address, runtime codehash) | `0x24a5E41C539FB0e1FF5924239fE23D3bF86De11E` / `0x9989c5027fc25da8bceb23b0b5dab216bb1f33c2f8b8fd5d04bc8485bcc712a9` | no |
| `FilesExternalContentRule` (address, runtime codehash) | `0x9A0B471E27F1CDC8478E214c301aA6Aa4F189FaF` / `0x637f6861202f82a7432588841d9a5544375dac5d0e77710db9b7b986f7f06f55` | no |
| `FilesRootRule` (address, runtime codehash) | `0xd65df37B79581dEdC752ECDf3325bD91e54c561E` / `0xcb7ba484cea9625fa2a8cbc35f81b312a1c936f2c69339e325fa5c4a7b5a9f39` | no |
| `FilesChildRule` (address, runtime codehash) | `0x4d670A2Ef8915ccb1347b6BcC01C1efd073fB6A8` / `0x38d96ac3bc562bdc7adf3708808ab74c2420b46a2df59af8107e4e952f90f9d4` | no |
| `FilesDirectoryRule` (address, runtime codehash) | `0x5A266C0a5428e3caDe9F4c5a8B830DCBDf478615` / `0xaea9d912818cd9f49a7b8426807494ca91551040ec499ec6dfaec6e40ad6bfd2` | no |
| `FilesNameRule` (address, runtime codehash) | `0x245098a6b090227e8F542c460f1C3be3F948884f` / `0xd73a9ee29819be1f26d1bc18d766fc0118d68555005c9c6acafc6e64bfdbfd17` | no |
| `RealmNoticeRule` (address, runtime codehash) | `0xB0be8d1E04D0B5D5268C05a6330c3254d6e5df34` / `0x52b5a16a788796687ec4607ff1ef59c4d99140c5eea9f583e8239b9d79b0ddcc` | no |
| `DirectoryAliasRule` (address, runtime codehash) | `0x60B6B7611961E258dC8FF63b37830281Ce0F4bDa` / `0xc10493df425c8ccfa89ee4f6948a0a85bacc0426127510fa337562fe68ddb667` | no |
| `TopicWordRule` (address, runtime codehash) | `0x44186F79ddA5e09dce338b0649b4c5E6ee4432a5` / `0x29442a0e789e1692d9ffc9e9c5202ee791f06860417b5dbd8ceeaffe81f1dfd5` | no |
| `TopicRule` (address, runtime codehash) | `0xD07aaA9b8b6719B7E8Af64e34B4366700c9a4CdC` / `0x6c3de3abe7422d0f0150b084e5a14ea4918c75f7f681ba9da0424f2460b6d69a` | no |
| `TextRule` (address, runtime codehash) | `0xD10088139D60Be3faB03FD3012F3706C3Ac69485` / `0xb839d97202882243312d2792eebda9be94bb272490e3d652c73f2a1a9a0661a5` | no |
| `RefuseAllPolicy` (address, runtime codehash) | `0xeba0FBaa0F4bE2a8444C994783120094fFe2BBB1` / `0xefcebe5a8ee27ed2e419e3753d17a6ad67a87fe257797ad10652bd3bc44b2a44` | no |
| `FilesFinalValidator` (address, runtime codehash) | `0xc672EfB35936f09A05611f5f61057Ef2C4DD35C0` / `0xeb744b64ca0d1d994bc0a1b260382c55b768b53fbbc55ba7bbac9fa7e1cb1619` | no |
| `LedgerCore` (address, runtime codehash) | `0x3C56f31A136aB3F04F1cD1e6eaa6f6AE56c0042C` / `0xd6b26d5cdd827850a9e906422ae56ac962c0ecddbfa8dbb8b19dae198b8dee3b` | yes (was `0x074Dc885…8fF5` / `0xef6a0c5d…b8ff`) |
| `TypeRegistry` (address, runtime codehash) | `0x0A5eFCc70026787b94bf6872A8148CA1A29C08C9` / `0xa7e9307a6ef01411f232895f1ae4a5f40b095b5c8da8788a259ffc06846178d3` | no |
| `RealmGenesis` (address, runtime codehash) | `0xff73065986D14D2E1D1050d59f7cCd7ACe043533` / `0x6138027c761937f074a871c95e4505d66e5e11cabbf2f9afe0ca558324bd7660` | yes (was `0x6fCEec8E…36bf` / `0x8b2b401f…6083`) |
| `PostingStore` (address, runtime codehash) | `0xA5CE13aB7011FcE7357b79e0267251499055DCB9` / `0x180ab3612928cce982ad6efcd75db4935bcc2d5696eb0227adb61ce6cd3b858f` | yes (was `0xdAB85C02…94DE` / `0x9a89824d…8040`) |
| `BitmapStore` (address, runtime codehash) | `0x508EB68a5e2a3aF1954e161d590B28B3C6d02D1B` / `0xcc0c33afa91b6070db27d016b14bab50b2916f27fc6aa6c94d01bf6826941b1b` | yes (was `0x164F6F6a…457F` / `0x192588d9…8858`) |
| `RealmController` (address, runtime codehash) | `0xA6aFe20eD91162AC8AfE9aE082522fB69cb66E30` / `0x871f2a71707d659b8ed4f5cc9bc238e76e5939a2602489b5026540e63cb3c5b7` | yes (was `0x126c1775…9296` / `0xf438ffe1…eaec`) |
| `IndexReads` (address, runtime codehash) | `0x7345300136217575d8eC1cFd1beA91d25c9A329d` / `0xf7de800d4339c4f2210bc1fb91b5d12e133d264adb74b33f0e637b7b9ae87108` | yes (was `0x2Ce5BD78…92e6` / `0x084545d7…9d86`) |
| `RealmIndex` (address, runtime codehash) | `0x6ebfdf09F489bBdBeeF929bcb0C8B7eae02217f7` / `0x3ce5e1501d5edb8090832d0fc9b960f5d99efce7716b18598c64160c1013b452` | yes (was `0xCa5A752A…d4Dc` / `0xd07b8751…8c7a`) |
| `KeysView` (address, runtime codehash) | `0x50dE57E374C6a44B18b28Cdc5092EeC45e74757F` / `0xaede6581bd6c30cad13acfdab4ccf0792e45c4e1686c453545d4559831201ab3` | no |
| read bounds (prague): limitEntries, maxRows, pageTimesLens mine exact / mine below / everyone exact / everyone below | `245, 150, 768 / 416 / 688 / 408` | yes (was `246, 150, 768 / 416 / 688 / 408`) |
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
   is compared field by field (every field of the ABI's `WorkModel`, `formulaVersion` and formula 2's
   `rwPerBindLater`, `freshPerPublishExisting` and `finalComputePerPublish` included) with the deploy plan's work model,
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
`validate label new text` (24 bytes) checks it: predicted 828,939 against 890,272 measured on prague (−6.89%), 2,812,603
against 3,057,918 on amsterdam (−8.02%), inside the headroom. The rows (gas; amsterdam execution gas in brackets) and the
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

**The floor and the planning rule (design §10.4).** Before each index callback the kernel requires a floor of
execution gas to be visible (`gasleft()`), and on Glamsterdam only execution gas is visible and capped. So that a
planner never sizes a publication the floor refuses, `gas/model.json` carries, per schedule, `profiles.<schedule>.floor`:
the kernel's quote inputs exactly (`workModel`, the Realm's floor prices and kernel tail in `limits`, per-Type `refs`
and digest `specs` in `types`, `callGasRetained` = 63/64, `dispatchOverhead`), `kernel` (the kernel's own execution
gas: every `GasModel.t.sol` publication is also run from the same state with the index's two callbacks answered by
`vm.mockCall`, logged as `kernel frame gas`, and fitted like the constants) and `formula`, the plain statement:

- quote (work-model formula 2): `fresh10 = freshPerPublication + Σ_publish/reuse(freshPerRef·refs + (new record ?
  freshPerPublishFresh + freshPerDigestSpec·specs : freshPerPublishExisting)) + Σ_bind-kind(head UNSET ?
  freshPerBindFresh : 0)`, `rw10 = rwPerPublication + Σ_publish/reuse rwPerPublish + Σ_bind-kind(rwPerBind + (head
  UNSET ? 0 : rwPerBindLater))` (a RELEASE is always a later statement, a REUSE always an existing record); `P =
  computeBase + n·computePerAction + binds·computePerHookEffect + ⌈fresh10/10⌉·floorFreshGas +
  ⌈rw10/10⌉·floorRewriteGas`; `F = finalComputeBase + binds·finalComputePerBind + publishes·finalComputePerPublish`;
- requirement: `V = max(K + ⌈(⌈P·64/63⌉ + dispatchOverhead)·64/63⌉, E) + ⌈F·64/63⌉ + kernelTail`, E the execution
  estimate (prague `constants`, amsterdam `split.executionGas`) and K from `floor.kernel` with the same composition.

The rule (`planning`): a publication is planned when it is inside `planning.limits` (64 actions, 64 bind-kind actions,
16,384 body bytes) and `max(E, V) ≤ ⌊txGasCap × (100 − headroomPercent) / 100⌋` (2^24 and 15%: intrinsic gas, calldata
and the model's error); anything larger is split before it is signed. A roll-up list's next append is priced as new
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

**`ILedgerCommitments.indexFloor` is an upper bound only.** It quotes without a principal, so every BIND and UNBIND
reads an UNSET head and is priced as a first statement (`freshPerBindFresh`, which is above `rwPerBindLater` on both
schedules); it is exact only when every bind-kind action is one. A consumer plans from the gas model's rule
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
prague profile, refits, and exits 1 when a validation composite is off by more than 15% or when any fitted constant
or measured row differs from the committed `gas/model.json`, printing the first differences and the regeneration
commands (`pnpm run gas:model`, then `pnpm run release`). Gas is deterministic for identical bytecode, so the
comparison is exact; CI runs it after `pnpm release:check` on the prague build the suites left warm, and without
`--skip-amsterdam 1` it checks the amsterdam profile the same way (locally only: CI never builds amsterdam).

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
   `test/harness/doubles/IndexDoubles.sol IndexDoubleDefaults.workModel()` (design §10.4, formula 2; the
   constants are measured with the step-3b lists in place, the later-statement, existing-record and per-publish final
   terms by `test/integration/IndexFloor.t.sol`'s `later`/`publish`/`reuse` rows; `gas/model.json` `floor.workModel`
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
