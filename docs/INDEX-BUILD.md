# Building a later index family from history: a proposal

**Status: PROPOSAL, steps 1 to 4 implemented (step 1: 2026-11-26, branch `fable/2026-11-26-index-build-1`;
step 2: 2026-11-26, branch `fable/2026-11-26-index-build-2`; step 3a, the as-of rule of §4.3: 2026-11-26, branch
`fable/2026-11-26-index-build-3a`; step 3b, a new list in a third store, as a test harness: 2026-11-26, branch
`fable/2026-11-26-index-build-3b`; step 4, the measured gas of a build: 2026-11-26, branch
`fable/2026-11-26-index-build-4`).** It designs the step that design §10.1 and §10.6 defer
("a later generation builds its later families from history into its fresh stores before attachment") and that
`tools/RELEASE.md` §15 lists as a pre-freeze gate. Where it says "the code", it means `main` at `899767e`, except in
the paragraphs marked **Landed**, which describe the code after step 1, step 2, step 3a or step 3b (each says which). Where the
code and `docs/DESIGN.md` disagree, this document follows the code and says so (§1.4).

The work is built in four steps. **Step 1 (landed):** a generation that carries stores becomes ready and can be
activated on a Realm with admissions, and one that carries an abandoned store cannot: the carried check (§3.5), the
no-fresh-store half of `build` (§3.2, §3.4) and the two kernel checks of §5.3. **Step 2 (landed):** `build(0,
maxFacts)` is the budgeted walk of history into the generation's fresh stores (§3.2–3.4), folding only the families
of its fresh stores, so a generation-1-shaped generation can rebuild both stores (case (e)) or heal either one while
carrying the other (§4.3); coverage reads apply the carried check (§3.5). **Step 3:** a generation with an extra fresh
`PostingStore` and a new APPEND family (the `head-authors` example, §2.2), with the deployer plan it needs (§3.1) and
the built-equals-live tests (§8); **landed as step 3b**, as a test harness (the list is an example, not product). **Step 3a (landed):** the as-of rule of §4.3: a fold from history reads every
fact as of the admission it folds and takes no fact from a validator's law. **Step 4 (landed):** the measured gas of a build (§6, §8 test 11), measurement and docs only. §10 lists where steps 1
and 2 differ from this proposal, and the entries of steps 3a, 3b and 4 (step 4 has an open finding against the
release's amsterdam floor prices: §10 item 29).

Figures are marked **measured** (with the file they come from) or **estimated** (with how). The cost figures of §6
were measured for this document in step 4 (`test/index/BuildGas.t.sol`); the rest were measured by the suites each
paragraph names.

Reviewed on 2026-11-25 by the integration owner and by the tag design session; both accepted the shape and the
recommendations of §9 (question 9 waits on QUESTIONS Q3). Their follow-ups are in §2.2 (what a built list
inherits), §2.6 (the planning rule), §4.3 (an example) and §6.2 (the price of adding a list later).

---

## 0. The answer first

**Can a later generation build into the stores as they are written today?** Yes, into *fresh* stores, and that is
the only kind of store anything can ever be built into:

- A generation-1 store at genesis has `INITIAL_WRITER = 0` (`tools/deploy-plan.mjs:567`;
  `test/harness/IndexDeploy.sol:92-93`). Its family set is fixed in immutables at construction
  (`PostingStore.sol:45-69`, `BitmapStore.sol:34-47`). So nobody can ever build into it, and no family can ever be
  added to it. It can only be **carried**: re-pinned by a later generation, which then writes it live.
- A fresh store whose `INITIAL_WRITER` is the new generation accepts that generation's writes while it is not
  attached and the ledger is idle, in `MODE_BUILD` (`StoreBase.sol:59-66`). `MODE_BUILD` is not backfill mode.
  `append`, `appendBatch`, `release` and `retain` refuse only `MODE_BACKFILL` (`PostingStore.sol:117, 137, 148,
  158`), and the UNCOUNTED bit is honored on every append path (`PostingStore.sol:168-187`). So every counter
  operation the live fold uses is open to a builder. This is not a promise: generation 1's full replay already
  uses exactly these operations in `MODE_BUILD`, and `test/integration/TopicListsReplay.t.sol:185-252` shows the
  replayed heads (`count`, `live`, `last`, `flags`) equal the live ones for families 5, 6, 7, 8, 10, 11, 16, 19, 20
  and 21, with all three counters moved by the history.

So **neither `PostingStore` nor `BitmapStore` has to change for a later generation to add an APPEND family,
change a digest spec or replay everything.** The design §10.6 note that "`retain`, `release` and the uncounted
append all refuse in backfill mode" is true, but a build never runs in backfill mode.

One store defect mattered, and it was in `BitmapStore`. `openCoverage` refused backfill mode, and only the live
generation writes the genesis `BitmapStore`. So a BITMAP family added **in place** (the reserved `roster` family,
kind 17) could open a coverage slot only for a scope that some publication touches after the family is declared. A
pre-declaration scope that nobody touches again never got a slot, `backfillOr`/`backfillSet` refuse a scope without
one, and its coverage could never become COMPLETE. The genesis `BitmapStore` is a lasting contract, so the fix had to
land before the first lasting deployment for the in-place route for `roster` to stay in the design. **It landed in
this release:** `openCoverage` now accepts the live generation while idle (the writer and family rule is unchanged,
`E_COVERAGE(1)` still refuses an open slot, and the store still does not judge `liveFrom`), and the store's ABI tag
is `efs/bitmap-store/2` (`test/index/Stores.t.sol` opens, backfills and completes an untouched scope). Without it,
`roster` (or any later BITMAP family) could have been added only by building a fresh bitmap store from history
(§2.3), which is far dearer.

Everything else this proposal needs is in code that is replaceable until the Realm is frozen: the new generation
itself, a deployer that can carry some stores and create others, its reads contract, and one more readiness check
in `LedgerControl`. These must land **before freeze**, not before the first lasting deployment.

There is also a gap that blocks every partial build today, independent of the stores: **a generation that carries
any store cannot become ready on a Realm with admissions.** Its progress starts at 0 (`RealmIndex.sol:145`),
replay refuses because its stores are not all fresh (`RealmIndex.sol:537, 580-585`), and activation requires
`completedAdmission == counts().admissions` (`LedgerControl.sol:304-306`). §3.5 fixes it in the new generation.

---

## 1. What exists today

### 1.1 What generation 1 can do

- **Fold live.** `onAdmission` is called once per leaf with `Effect[1]` (`LedgerIngress.sol:640-680`) and folds
  every family of §10.2 (`RealmIndex.sol:157-180, 227-495`).
- **Replay into fresh stores.** `replayNextPublication(maxFacts)` is implemented, not a revert
  (`RealmIndex.sol:533-554`). It is permissionless, needs the ledger idle, and needs *both* stores to name this
  generation as `INITIAL_WRITER` and be unattached (`_fresh`, `RealmIndex.sol:580-585`). It decodes one
  publication through the pinned `IndexReplayDecoder` by `STATICCALL`, then calls itself (`replayFold`,
  `RealmIndex.sol:558-578`), which runs the same `_fold` as the live path. So the live fold code is the replay fold
  code. `maxFacts` is a guard, not a budget: a publication with more leaves than `maxFacts` reverts `E_REPLAY(6)`
  (`RealmIndex.sol:552`; `test/index/Replay.t.sol:378`).
- **Activate after a replay.** `test/index/Replay.t.sol:280-364` replays a quiet history into a generation created
  by `IndexDeployer`, activates it, folds a new publication live into the same stores (one writer range from build
  into live), and shows replay is refused once live.

### 1.2 What generation 1 cannot do

- `build` and `backfill` revert `E_BUILD(0)` / `E_BACKFILL(0)` (`RealmIndex.sol:597-605`). `buildDelegate()` is 0
  and `Readiness.build` is 0 (`IndexReads.sol:186-188, 227-228`). **Landed (step 1):** `build(0, maxFacts)` now moves
  the frontier of a generation that carries both of its stores (§3.5) and refuses one with a fresh store,
  `E_BUILD(4)`, until step 2; `backfill` still reverts `E_BACKFILL(0)`; `buildDelegate()` and `Readiness.build` are
  still 0. **Landed (step 2):** `build(0, maxFacts)` also walks history into the fresh stores of a generation that has
  any (§3.2–3.4); `E_BUILD(4)` is gone.
- It holds exactly one posting store and one bitmap store (`RealmIndex.sol:44-45, 109-110`), so it cannot fold
  some families into a carried store and others into a fresh one.
- A generation-1-shaped generation that re-pins any store cannot reach readiness on a Realm with admissions (§0).
  `test/index/IndexDeployer.t.sol:74-87` deploys such a generation (re-pinned posting store, fresh bitmap store) but
  never activates it, and could not. **Landed (step 1):** one that re-pins *both* stores can (`build`, §3.5;
  `test/index/Carried.t.sol`); one that re-pins one store and creates the other still cannot until step 2 builds the
  fresh one. **Landed (step 2):** it can: `build` rebuilds the fresh store from history while the carried one stays
  the live index's (`test/index/BuildWalk.t.sol`, `test/index/BuildWalkRefusals.t.sol`).
- `GenerationStorage.buildFrontier` is declared (`src/index/storage/GenerationStorage.sol:16-25`) and never used.

### 1.3 What the tests prove and what they do not

Proved: replay equals live for every generation-1 list and counter over a mixed history
(`TopicListsReplay.t.sol:86-252`; `Replay.t.sol:562`, which also checks every decoded publication hashes to the
live `effectsHash`); replayed stamps are the mutating admission (`Replay.t.sol:644`);
a fold hook cannot re-enter a replay; a builder may write only before attachment and only while idle, and stamps
the admission it folds (`test/index/Stores.t.sol:118-160, 545-562`).

Not proved: a replay or build that runs while publications keep landing; activation racing a publication; a
generation that carries some stores and builds others; any later family; any BITMAP backfill. Nothing measures the
gas of a replay step.

### 1.4 Where the code and DESIGN disagree (this document follows the code)

1. §10.6's engineer's note says the counter operations "all refuse in backfill mode" and must be addressed. A build
   runs in `MODE_BUILD` (store rule 3), which accepts them (§0).
2. §10.1 gives the generation a constructor `(ledger, layoutId, decoder, postingStores[], bitmapStore, build,
   buildCodehash, …)`. The code takes `(ledger, decoder, reads)` and one store of each kind (`RealmIndex.sol:90`).
3. §10.6 says the decoder checks the publication's revision row for `ledgerImplCodehash`, `layoutId` and
   `indexManifestHash`. The code checks only `layoutId` (`IndexReplayDecoder.sol:63-68`).
4. §5.11's `IBitmapStore` writes take no admission. The code's `appendScopeEntry`, `setBit` and `stamp` take one
   and check it against the frontier (`BitmapStore.sol:75-137`, `StoreBase.sol:83-92`).
5. §10.3 says the core fold "never reads heads, positions or admission rows". It reads no *ledger* heads, but it
   does read its own store's list heads (by-record, `RealmIndex.sol:329`; family 20, `RealmIndex.sol:440`) and the
   scope list (`_entryIndex`, `RealmIndex.sol:498-514`), and ledger record cells and body words (§4.3).
6. §10.5 and §8.3 step 5h require "every store's writers ranges contiguous". The code checks contiguity only
   (`LedgerControl.sol:359-364`); it does not check that the last range belongs to the live index, nor that a
   fresh store names the candidate as `INITIAL_WRITER`. §5.3 explains why that matters.
7. §4.6 says a coverage slot "exists only for scopes that predate the family's declaration ordinal; absent =
   covered by construction". While `openCoverage` refused backfill mode, "absent" could also mean "predates
   the declaration and was never touched again", which is not covered (§0); since `efs/bitmap-store/2` the live
   generation opens such a slot while idle, so the gap is the generation's to close, not the store's.
8. §8.7 lists `replayNextPublication`, `build` and `backfill` as `DELEGATECALL`s into `IndexBuild`. Withdrawn
   (§10.1 note); generation 1 replays in its own code.

---

## 2. The cases

Every example below uses the HEAD purpose of a file: `BIND(HEAD, file, 0 → record)` (`EfsFiles.sol:18`), position
`Keys.position(HEAD, file, 0)` (`EfsFiles.sol:134-137`).

### 2.1 (a) Re-pin only: a new generation, no new family

Example: generation 2 fixes a fold bug in a final hook, or changes the work model. It keeps every family where it
is. It is deployed with plain CREATE2 and names the genesis stores. Nothing is built. It must still become ready:
it has to prove that the stores it carries are complete through the frontier at activation. §3.5 is that proof.

### 2.2 (b) Add an APPEND family (worked example: everyone's versions of a file)

Generation 1 deliberately keeps no all-authors list on HEAD (design §10.2, "HEAD is deliberately in none of
them"; `docs/TAG-DESIGN.md` §4; QUESTIONS Q52). Generation 2 adds one. Provisional definition:

| | |
|---|---|
| name, kind | `head-authors`, kind 22 (both provisional; kinds 2, 3, 9 stay reserved) |
| key | `(0, 22, 0, position)` with `position = Keys.position(HEAD, file, 0)` |
| entry | the admission of each author's first HEAD statement on the file (FIRST_BIND or FIRST_MASK) |
| `count` | authors who ever made a HEAD statement on the file |
| `live` | authors whose HEAD on the file is BOUND now (HEADS semantics, the same transitions as family 20) |
| store | a fresh `PostingStore` with `FAMILY_IDS = [head-authors]`, `INITIAL_WRITER` = generation 2 |

Why a new family and not "family 20 for HEAD too": family 20 lives in the carried genesis store, which nobody can
build into. Widening family 20's purposes would make its history for HEAD positions empty, so its coverage could
never be honest.

The fold, inside the bind fold, when `purpose == HEAD`:

| transition | store operation |
|---|---|
| FIRST_BIND | `append(key, admission)` (counted) |
| FIRST_MASK | `append(key, admission | UNCOUNTED)` |
| RESTORE | `retain(key, 1)` |
| MASK or RELEASE with `oldTarget != 0` | `release(key, 1)` |
| REBIND, or MASK/RELEASE of a head that is not BOUND | nothing |

It reads nothing but the effect. A trace, live and built alike: Alice creates `notes.md` at admission 100
(append 100: count 1, live 1, one slot); Alice edits at 140 (REBIND: nothing); Bob saves his own version at 200
(his FIRST_BIND at the same position: append 200, count 2, live 2, word 0 materialized); Alice releases her head at
300 (release: live 1); Alice restores at 400 (retain: live 2). End state, both ways: count 2, live 2, last 200,
entries [100, 200].

**A built list inherits history as it was admitted.** A build folds every admitted statement, and a later
validator cannot refuse a statement after the fact. So a rule that keeps junk out of a list has to be in the
validator before the statements are made, not in the generation that later lists them. One case existed until
this release: a first "not this" at HEAD (an UNBIND with no earlier statement) was not judged, so anyone could make
one about an id that names no file. Nothing lists it. A `head-authors` build would have given that id a list with
one uncounted entry. The fix is the rule code 15 already applies to TAG and FOLDER (`FilesFinalValidator`): a first mask at HEAD
must name a created subject. It costs one read on a rare action, and it has the same deadline as any validator
change: before the first lasting deployment. It landed in this release as code 16: a first "not this" at HEAD must
name a subject created strictly before it (`test/integration/HeadLaw.t.sol`).

**Landed (step 3b), as an EXAMPLE, not product.** `head-authors`, kind 22 and the generation that keeps it are a test
harness (`test/harness/HeadAuthors.sol`: `HeadAuthorsIndex`, `HeadAuthorsReads`, `ListIndexDeployer`); the product
keeps no all-authors HEAD list (Q52: whether the first index should keep it is James's decision, and both recommendations are now to keep it), and kind 22 is not reserved by anything in `src/`. The fold is the
table above, in `HeadAuthorsIndex._foldMore`, on BIND, UNBIND and RELEASE effects at HEAD only, with the third store's
carried bit (`CARRIED_THIRD = 4`) honored; it reads nothing but the effect, so it needs no as-of comparison, live or
from history. The store is a fresh `PostingStore` with family set `[head-authors]` and `INITIAL_WRITER` = the
generation, and the manifest declares the family there with `fromAdmission == 1`, universe 3 (SCOPE, as family 20),
HEADS semantics. The trace is `test/index/HeadAuthorsBuild.t.sol::test_head_authors_trace`, live and built: end state
count 2, live 2, last = Bob's first statement, entries [Alice's, Bob's], and the list reads the same through the
generation's `postingHeadOf`/`postingSliceOf`, which route it to the third store.

### 2.3 (c) Add a BITMAP family

Example: `roster` (kind 17), reserved in generation 1 as `NOT_MAINTAINED` with CURRENT_STATE semantics
(`IndexReads.sol:84`), "which principals are live in a directory".

A BITMAP family's bits are indexed by the entries of the scope list (kind 10) **in the same store**:
`setBit` and `backfillSet` refuse an entry index at or beyond that store's own scope count
(`BitmapStore.sol:118, 186-187`). That leaves three routes:

1. **In place, in the genesis `BitmapStore`** (design §10.6 backfill): possible only for a family the genesis store
   already lists. Its family set is `scope`, `roster`, `live-scope` (`tools/deploy-plan.mjs:171`), so only `roster`.
   It needed the `openCoverage` fix (§0, §7.2), which landed in this release (`efs/bitmap-store/2`).
2. **A fresh `BitmapStore` built from history.** It must rebuild kind 10 and `live-scope` too, because the bits
   need the scope lists beside them. Correct with today's code (`MODE_BUILD` accepts `appendScopeEntry`, `setBit`,
   `stamp`), but it costs about one fresh slot per scope ever bound plus the entries (estimated from §10.2's slot
   shapes).
3. **A fresh bits-only store of new code**, which takes entry indices from the generation and keeps no scope list.
   Built by walking history, reading the carried kind-10 lists only for entry indices, which never change once
   written (append-only, `BitmapStore.sol:75-102`). Needs a new store contract and its own ABI id.

### 2.4 (d) Change a digest spec

Example: generation 2 adds a third `DigestSpec` (another Type's body word 5, sha256). Family 15 is GLOBAL: a
digest key may already hold earlier admissions, so the new spec's older entries cannot be appended to the carried
store without breaking the order law (design §10.6). Generation 2 rebuilds family 15 with all three specs, in one
ascending walk, into a fresh store, and its manifest points family 15 at the fresh store. The carried store keeps
its old family-15 keys, which nothing writes or reads any more. This is case (b) applied to an existing family id.

### 2.5 (e) Full replay into fresh stores (the heal path)

Example: a store is found corrupted, or a freeze rehearsal. Every family is rebuilt into fresh stores. This
exists today for a generation-1-shaped generation (§1.1). What it lacks is a tested procedure for a busy Realm
(§5.3) and a measured cost.

### 2.6 What the first build covers

| case | first build? | why |
|---|---|---|
| (a) re-pin only | **yes** | Every later generation needs the carried-store proof (§3.5); without it no generation can replace generation 1 on a live Realm except by full replay. |
| (b) new APPEND family | **yes** | It is the promise the release gate is about (Q52). |
| (d) digest spec | yes, same machinery | Once (b) can put any manifest family in a fresh store, (d) is (b) for family 15. Its test can follow. |
| (e) full replay | exists; add the busy-Realm test | The code is there; the race and transition procedure are not tested. |
| (c) BITMAP family | **no**; the `openCoverage` fix landed in this release | No BITMAP family is planned (`roster` is reserved, Q16's codec-2 families are later). The fix was the only part with a deadline, because the genesis `BitmapStore` is lasting; it is in `efs/bitmap-store/2`. |

**Planning rule: batch later lists into one generation.** One walk builds every built family, and the walk is
most of the cost (§6.2). Two lists added in two generations pay for two walks of the whole history; added together
they pay for one. So a Realm should collect the lists it wants and add them in a single generation, and a request
for one more list is a request to schedule it with the next batch.

---

## 3. The shape

### 3.1 Who deploys what

The building generation is its own contract, with the build in its own runtime (QUESTIONS Q34 option (a); the
plain-runtime scan stays whole, `LedgerControl.sol:288`). For case (b) it holds:

- the carried genesis `PostingStore` and `BitmapStore` (re-pinned: their address and codehash in its manifest);
- one fresh `PostingStore` per new family set, `INITIAL_WRITER` = the generation;
- its reads contract, which now routes each posting read to the family's own store, not to one `POSTING`.

`IndexDeployer` (`src/control/IndexDeployer.sol:16-119`) already creates fresh stores with `INITIAL_WRITER` = the
nonce-predicted generation, then the reads contract, then the generation, and asserts every prediction. But its
`Plan` has one posting slot and one bitmap slot, each either fresh or carried, so it cannot express "carry the
genesis posting store and also create a fresh one". The proposal is an `IndexDeployer` whose plan carries a list
of carried stores and a list of fresh stores (initcode, family set). A deployer is not lasting Realm state: it can
be written when generation 2 is.

**Landed (step 3b), in the test harness.** `ListIndexDeployer` (`test/harness/HeadAuthors.sol`) takes a LIST of
stores, each carried (an address) or fresh (initcode and family set, created with `INITIAL_WRITER` = the
nonce-predicted generation): slot 0 the posting store, slot 1 the bitmap store, every further slot an extra store,
passed to the reads contract as `extra`. It creates the fresh stores in order, then the reads contract, then the
generation, and asserts every prediction, as `IndexDeployer` does. The production `IndexDeployer` is unchanged: its
one-slot-per-kind plan still expresses every generation-1-shaped generation, and the dropped-list test's generations
(§5.3) use it. The generation is `RealmIndex` with its extension points overridden (§10 item 24); its reads contract is
`IndexReads` with its extension points overridden (`_declare` for the extra family, `_postingOf` for per-family
routing, `_carriedCheck` over every store).

### 3.2 The build entry point

Keep the selector `build(bytes32 familyId, uint16 maxFacts) returns (uint64 through)` (`IRealmIndex.sol:32`):

- **`familyId` must be 0**: one walk builds every built family of the generation together, so history is decoded
  once. A nonzero id reverts (reserved for a later per-family build, which no case here needs).
- **Permissionless.** The build writes only the generation's own fresh stores, which nobody treats as canonical
  until activation. It takes no input that can change what it writes: the history decides. A stranger who calls it
  pays gas to move the Realm forward.
- **Idle-gated.** `ledger.phase() == IDLE`, as the stores themselves require for rule 3 (`StoreBase.sol:59-61`).
  A publication is one transaction, so every other transaction starts idle; the gate refuses only a call made from
  inside a publication (a fold or final hook), as `replayStage == 4` does for replay (`RealmIndex.sol:540-544`).
- **Refused once switched on**: if `ledger.index() == this` or `liveStarted != 0`. After activation the stores
  would refuse anyway (the generation is `ledger.index()`, so an idle write is `MODE_BACKFILL`), but the explicit
  check names the reason.
- **Refused unless every fresh store is fresh**: `INITIAL_WRITER == this` and not attached, as `_fresh` checks
  today, but over the fresh stores only.

**Landed (step 2),** in `RealmIndex.build`, in this order: a nonzero `familyId` (`E_BUILD(8)`); live, or ever folded
live (1); not idle, or a replay or build call of this generation in flight (3); a store that names this generation as
`INITIAL_WRITER` but is attached (2: neither fresh nor carried; only a live write attaches, so some live index wrote
a store this generation never vouched for, which kernel reason 13 also refuses); the carried check (7). Then the
carried mask: bit `CARRIED_POSTING` or `CARRIED_BITMAP` for each store that is not fresh (`_carried`). With both
bits set nothing is walked and the frontier moves to `counts()` (step 1). Otherwise: no decoder (5), and the walk of
§3.3 folds only the families of the fresh stores. Fresh and carried are judged at every call, so a store that a live
write attached between calls stops the next call with 2. Under the kernel's checks that can happen only before any
build write: an index that names another generation's fresh store passes check 12 only on a Realm with no admissions,
where the store must be unwritten (`test/index/BuildWalkRefusals.t.sol::testAFreshStoreAttachedByALiveWriteRefusesTheBuild`).
`replayNextPublication` keeps its selector and behavior (both stores fresh, `maxFacts` a guard of one publication,
`E_REPLAY` codes unchanged) and shares the decode-and-fold internals with `build` (`_replayOne`, `replayFold`).

### 3.3 Bounded steps

The step is **one publication**, as in replay: a publication has at most 64 leaves (`LedgerControl.sol:152-157`),
its leaves fold in order, and every earlier effect is flushed before the next folds (`RealmIndex.sol:433-434`),
which the family-20 head read depends on.

`maxFacts` becomes a **budget**, not replay's guard: the call folds whole publications, in order, while the leaves
folded so far plus the next publication's leaf count stay within `maxFacts`. It folds at least one, and reverts if
the first does not fit (so `maxFacts >= 64` always makes progress). It returns the new frontier.

Each publication goes the way replay goes today: `STATICCALL` the pinned decoder for the payload, then `CALL` this
contract (`buildFold`, `msg.sender == this` only), which folds the built families with the live fold code.
Folding inside a self-call keeps the effects in calldata, as the live fold expects.

**Landed (step 2).** As proposed, with one change of name: the self-call is `replayFold`, shared with replay, not a
new `buildFold`. The carried mask rides as one word after the ABI payload (`_replayOne` appends it; the ABI decoder
ignores trailing calldata; `replayFold` reads `msg.data`'s last word), so it is chosen by this code and never by a
caller (`replayFold` refuses any caller but the generation itself, `E_WRITER`). The fold is the live fold: `onAdmission`
and `replayFold` both run `_foldPublication`, which runs `_fold` with mask 0 live and in an all-fresh build or replay,
and with the carried store's bit in a build that heals one store; `_fold` then skips `_foldRecord` and
`_foldWithdraw` (posting only) and the half of `_foldBind` that writes the carried store. The bind fold was split
into its two halves for this (`_foldScope` writes the bitmap store, the rest the posting store); the halves touch
different stores and read nothing of each other's (§4.3), so the order between them changes neither store, and the
live path runs the split code too. The next publication's leaf count is read from its evidence cell
(`extsload(publicationsEvidenceSlot(n))`, `leafCount` in word 0) before it is decoded: one extra `extsload` call to the
ledger per publication (a cold slot the decoder then reads warm, so it adds about a call's overhead, not a cold read).
`maxFacts = 0` with a pending publication reverts 6; with nothing pending any budget returns the frontier. Measured
(test 7, `test/index/BuildWalk.t.sol::test_heaviest_publications_build_in_one_call`): every admitted shape's
largest publication builds in one call well under 2^24 on both schedules (§8 test 11 has the figures). The walk
needs one admitted publication's build to fit one transaction; for the heaviest admitted publication today that is
9.76M of the 16.7M a 2^24 transaction leaves the call (depth-64 first tags, prague). A generation whose folds are
heavier than those of the generation that admitted the history (more lists, or a full replay with extra families)
must measure this again, and leaf-granular resume is the remedy, which can ship in that generation's own code.

Leaf granularity (resuming inside a publication) is not proposed. It would be needed only if one publication's
build cost could exceed one transaction's gas. **Done (step 4, measured, §8 test 11):** for the example generation
(a list added later) and for a full replay, the heaviest publication of every shape the planning rule admits builds in
one cold call under 2^24 on both schedules; the least headroom is a full replay of 64 lone negatives on prague
(12,416,008 of the 16,755,216 the call has: 4.34M to spare). So **a build need not resume inside a publication** for
any history the kernel admits today. A generation whose fold is heavier than generation 1's must measure this again
(`test/index/BuildGas.t.sol::test_heaviest_admitted_publications` is the test to copy).

### 3.4 Where progress lives

In the generation's own storage (`efs.index.gen`), which only its code writes (`GenerationStorage.sol:5`):
`progress.lastProcessed` and `progress.lastPublication` are the build frontier: every built family is complete
through it. `replayStage` keeps its meaning (FRESH, BUILDING, CAUGHT_UP, IN_FLIGHT). `buildFrontier[family]` stays
unused while all built families share one walk.

When the generation goes live, the same word becomes the live progress, so `onAdmission`'s contiguity check
(`expected = lastProcessed + 1`, `RealmIndex.sol:165`) is right from the first live call, exactly as after a replay.

**Landed (step 2).** As proposed. `build` sets `replayStage` to 4 (IN_FLIGHT) for the walk and to 3 (CAUGHT_UP) or 2
(BUILDING, the value replay calls REPLAYING) after it; `lastProcessed` and `lastPublication` move in `_foldPublication`
after each folded publication, so an interrupted series of calls resumes exactly where the last call stopped, and a
reverted call (budget too small, a decoder or store error) moves nothing. `buildFrontier` is still unused.

### 3.5 Carried families: the proof that replaces "we never folded them"

A generation that carries a store did not fold that store's history; the live index did. Its claim is: "every
family I carry is complete through the frontier, because the live index keeps it, in this very store". The
generation can check that claim itself:

> for every family the manifest marks carried, the live index (`ledger.index()`) declares the same family id, in
> the same store, maintained from admission 1 (`fromAdmission == 1`, read from the live index's
> `replayReadiness().families`).

The live index folds every admission synchronously (a publication without its callbacks is not admitted), so while
that holds and the ledger is idle, the carried families are complete through `counts().admissions`.

So the build step does two things: it walks history for the built families, and, for a generation with no built
family (case (a)), `build(0, maxFacts)` folds nothing and moves the frontier straight to `counts()` once the
carried check passes. Readiness reports `completedAdmission = lastProcessed` and is ready only if the carried check
passes at the moment it is read.

**Landed (step 1).** How the code does it:

- **Where.** The check is `IndexReads.carriedCheck()`, in the generation's reads contract, which holds the family
  table; like every other read it judges `msg.sender` as the generation, so it is answered at the generation's
  address through its fallback. `RealmIndex.build` calls it directly; `IndexReads.replayReadiness` applies it.
- **Fresh and carried.** A store is fresh when it names the generation as `INITIAL_WRITER` and is not attached
  (`RealmIndex._isFresh`, `IndexReads._isFresh`); every other store the generation names is carried, including the
  genesis stores (`INITIAL_WRITER = 0`), so generation 1 itself "carries" its stores.
- **The edge cases.** With no admissions there is no history to miss, so the check asks something else: both of the
  generation's stores have an empty writers list (never written in build mode or live), whoever their
  `INITIAL_WRITER` is. An honest build or replay on an empty Realm makes no store call (`replayNextPublication`
  returns before decoding when there is no publication; `build` folds nothing), and every build-mode or live write
  records a writer range on its first call (`StoreBase._authorizeWriter`), so this holds for every honest store.
  Genesis needs no special case: generation 1's stores are new, and the kernel's check 12 has the same rule.
  **Since step 2** each store must also name 0 or the generation itself as `INITIAL_WRITER` (below, §5.3). When the generation is the live index the check passes (it folds its
  stores itself; this also stops the check from asking itself). A generation with no carried store passes. A live
  index without code, or whose readiness read reverts, fails the check (with admissions).
- **Readiness when the check fails.** `completedAdmission` and `completedPublication` are 0 and `ready` is false,
  whatever the progress word says. The tuple has one frontier for the whole generation, and the kernel trusts
  `completedAdmission` (§5.2); a generation whose carried families are not proven claims nothing. The progress word
  itself (`progress()`) is unchanged, so a re-pin that was built and then lost its proof keeps its frontier and is
  ready again if the proof returns. The check is made at the moment readiness is read.
- **`build` with no fresh store** (`RealmIndex.build`): `familyId` must be 0 (`E_BUILD(8)`); refused once this
  generation is `ledger.index()` or has folded live (`E_BUILD(1)`), inside a publication or while a replay call of this
  generation is in flight (`E_BUILD(3)`), when the generation has any fresh store (`E_BUILD(4)`, step 2), and when the
  carried check fails (`E_BUILD(7)`). Otherwise it sets `lastProcessed` and `lastPublication` to `counts()`, sets
  `replayStage` to CAUGHT_UP and returns the admission frontier. `maxFacts` bounds nothing here, because nothing is
  folded. After more publications land, calling it again moves the frontier again.

Coverage reads (`coverage`, `coverageOfType`, …) do **not** apply the check in step 1: they report the progress
frontier as before. For a live generation that is exact (the check passes); a generation that is not live and
whose carried check fails would still report its stale frontier there. Readers read the live index, and the kernel
reads only readiness, so step 1 leaves coverage unchanged; step 3, which gives coverage a per-family frontier, should
apply the check to carried families there.

**Landed (step 2): coverage applies the check, per family.** `IndexReads._coverage` (behind `coverage`,
`coverageOfType`, `coverageOfSpec`, `coverageOfDigest`, `postingHeadOf`, `postingSliceOf` and `occurrencesOf`)
answers, for a maintained family of the calling generation:

The caller's state is read from its own progress word, in the one call coverage already made to it
(`generationProgress()`, which returns the frontier and `liveStarted`): a generation that has folded live answers
exactly as before step 2, with no ledger read and no check, so the live index's reads cost what they cost at
`99d617a` up to the shift of the function tables (−3,114 to +16 gas per measured read row; every read bound is as at
`0fb4804`, tools/RELEASE.md item 27). Only a generation that has never folded live takes the check.

| state of the caller | family in a fresh store | family in a carried store |
|---|---|---|
| the live index, has folded live (`liveStarted`) | as before step 2: COMPLETE (1, admissions) while idle; unchanged inside a publication | same (no check, no extra read) |
| the live index, activated but no live admission yet (`liveStarted == 0`) | takes the check, which passes for the live index: COMPLETE (1, admissions) | same |
| folded live, then replaced | as before step 2, from its stale frontier: COMPLETE while nothing has been admitted since, PARTIAL (1, frontier) after | same (stale, as before; the check is not asked) |
| never live, building or behind (frontier < admissions), check passes | PARTIAL (1, frontier) | PARTIAL (1, frontier) |
| never live, caught up, check passes | COMPLETE (1, admissions) | COMPLETE (1, admissions) |
| never live, check fails | PARTIAL (1, frontier) (or COMPLETE when caught up): it folded these itself | **PARTIAL (1, 0)**: it claims nothing, as readiness does |
| any | gapped: PARTIAL (1, frontier) | same |

A family that is not maintained, or not declared, is UNKNOWN (0, 0) as before. "Carried" here includes a store that
names the caller as `INITIAL_WRITER` but is attached, and such a store also fails the check (below). Readiness is
unchanged in shape: `ready` is false while the frontier is behind `counts()`, and `completedAdmission` is the frontier,
or 0 when the check fails. In step 1 a not-live generation whose check failed reported its stale frontier, COMPLETE
when no admission had landed since. Tests: `test/index/BuildWalk.t.sol::_heal`,
`::test_activation_refuses_an_unfinished_build`,
`test/index/BuildWalkRefusals.t.sol::testCoverageOfCarriedFamiliesFollowsTheCarriedCheck`.

**Landed (step 2): a store attached under the generation's own name fails the check.** With admissions, a store that
names the generation as `INITIAL_WRITER` and is attached makes the carried check false (unless the generation is the
live index). Only a live write attaches, so some live index wrote a store this generation never vouched for; the
kernel refuses the same candidate with reason 13, and `build` with `E_BUILD(2)`.

**No reader can see a building generation.** The topic readers resolve the index per call from
`ILedgerHot(ledger).index()` (`TopicReaderBase._open`, `src/readers/TopicReaderBase.sol:198`) and never cache it;
`LensReader` and `FilesPageReader` do the same. So a reader asks only the live index, whose coverage is COMPLETE
(or prefix-COMPLETE inside a publication), and a generation that is still building is never asked: a tag reader cannot
show a building generation's empty page as if it were an answer. The readers were not changed.

**Landed (step 3b): per family across three stores.** `IndexReads._coverage` already judged each family by its own
store (`_storeOf(family.store)`); with `_carriedCheck` overridden to cover every store (the same rule, store by store:
on an empty Realm every store unwritten and `INITIAL_WRITER` 0 or the generation; with admissions, every family in a
carried store declared by the live index in the same store from 1), the three-store generation answers per family:
`head-authors` (fresh third store) PARTIAL (1, frontier) while behind and COMPLETE when caught up; generation 1's
families (carried genesis stores) the same while the check passes, and PARTIAL (1, 0) when it fails
(`test/index/HeadAuthorsBuild.t.sol::test_build_races_and_switches_on`,
`::test_admissions_refuse_another_writers_third_store`). What the readers do with PARTIAL and UNKNOWN is pinned per
view and per family by `test/readers/TopicPartialCoverage.t.sol` (§8): since 2026-11-26 both are a refusal with no
rows and no counts (PARTIAL is treated exactly as UNKNOWN, docs/TAG-DESIGN.md §6), as `src/interfaces/Readers.sol`
specifies; an empty list at PARTIAL is UNKNOWN, never an empty page.

**Landed (the liveness gate, 2026-11-26, branch `fable/2026-11-26-liveness`): the check no longer calls the live
index.** The live index's families are static: they are its manifest, whose hash the kernel recorded in the revision
row (`indexManifestHash`) when it activated that index. So a generation is deployed with a **copy** of the live index's
manifest preimage, the bytes `abi.encode(header, families, units, specs, work, physicalProfile, callbackProfile, reads,
readsCodehash)` that hash to that record (`IIndexReads.liveManifestCopy()`; `IndexDeployer.Plan.liveManifest`; empty at
genesis). `IndexReads._liveManifest()` reads the recorded hash of the current revision (`ILedgerHot.revision()` and one
`extsload` of word 8 of the row, `Layout.revisionsRowsSlot`), compares it with the copy's keccak and decodes the
families and units from the copy; `_carriedCheck` (and the three-store harness override) use it and never call the live
index. The copy is the canonical encoding (it hashes to what the index computed with `abi.encode`), so decoding its
leading values is exact; a copy with any byte changed, truncated, extended, empty on a Realm with admissions, or of
another generation fails (`test/index/Liveness.t.sol::test_a_wrong_copy_is_refused`). **A stale copy is the intended
failure:** a generation deployed against L1 whose L1 has since been replaced holds a copy that no longer hashes to the
record, so its check fails (`build` 7, readiness claims nothing, kernel 14) and it must be redeployed with the new live
index's copy (`::test_a_stale_copy_is_refused_and_a_fresh_one_activates`). One consequence, tested: a REPLACED
generation that carries any store can no longer build at all (its copy went stale when it was replaced), which closes
the late-walk route of §5.3 for every such generation (`DroppedList.t.sol`, `HeadAuthorsBuild.t.sol`); an all-fresh
generation never asks for the copy. The copy is held as code (§10 item 34 has the measurement): `IndexReads`' constructor
creates a data contract whose runtime is one STOP byte and the copy, as descriptor blobs are held, and records it by
address and codehash (`LIVE_COPY`, `LIVE_COPY_CODEHASH`; both covered by the reads codehash, so by the manifest hash).
The copy can be at most 24,575 B (EIP-170's 24,576 B runtime less the STOP byte); a larger one is refused at
construction, `E_PIN(reads, 12)`. Its size is `896 + 320·families + 320·units + 32·(family ids over all units) +
96·specs` bytes (measured: 7,168 B for the release's generation 1, 18 families, 1 unit, 2 specs; 16,000 B for 40
families and 6 units), so at most 72 families with one unit and two specs, or 67 with six one-id units.

Why not trust the writers history instead? Because it cannot tell "complete" from "abandoned". Example: generation
1 writes store S; generation 2 replays into fresh stores and goes live; S stops receiving writes; generation 3
re-pins S. S's writers list is `[(gen1, 1, open)]`: contiguous, and missing everything since generation 2's
activation. Worse, a store that was never written has an empty list and passes every writers test. Only "the live
index uses this very store for this family" is a proof.

### 3.6 Rebuilding each `Effect`

Through the pinned per-layout decoder, as replay does (`IndexReplayDecoder.sol:51-173`): the evidence cell gives
the principal, first admission and leaf count; each admission row gives kind, leaf, binding ordinal, revision and
`prevAdmission`; `oldTarget`/`oldTargetKind` come from the previous bind row's `a` word and target kind
(`IndexReplayDecoder.sol:168-171`); the FIRST_MASK transition is "UNBIND whose previous row is row 0"
(`IndexReplayDecoder.sol:164-166`); `freshRecord` is `cell.firstAdmission == admission`; refs are the leading
body words of the Type's `refCount`.

The decoder refuses a publication whose revision row names another layout (`E_REPLAY(2)`). Today there is one
layout. A Realm that ever changes layout needs a generation that pins one decoder per layout and picks by the
publication's revision row; that is outside this proposal but must be remembered before the first layout change.

Fold hooks: during a build, the generation calls no fold hook of a carried unit (it already folded live, and its
companion store is not fresh). A unit new in this generation with a fold hook would be built like a family, into
its own fresh companion store. Generation 1 has no fold hook (design §10.7). Final hooks are never called during a
build: the history was validated when it was admitted, and is never re-judged (design §10.6 tolerance rule; Q37).

**Landed (step 2).** Replay today calls every unit's fold hook after each publication's fold, as the live path does
(`_foldHooks`), and never calls a final hook (`afterPublication` is the ledger's call only). So: a build with both
stores fresh calls the fold hooks exactly as replay does (once per matching effect; a hook that re-enters `build`
or `replayNextPublication` is refused, `E_BUILD(3)` / `E_REPLAY(3)`); a build that heals one store calls **no** fold
hook; no build or replay calls a final hook. The generation cannot tell a carried unit from a new one: a `Unit` names
its hooks and codehashes but no store, and nothing records which generation first pinned it, so in a mixed build it
calls none. Step 3 owns "a new unit's fold hook is built" (it needs the unit to name its companion store, or the
generation to list its new units). `test/index/BuildWalkRefusals.t.sol::testFoldHooksRunInAnAllFreshBuildOnlyAndCannotReenterIt`.
Design §10.6's tolerance rule says final hooks "re-validate a publication" during replay when the revision row names
the same final codehash; the code never does (it follows this document, not the design).

**Landed (step 3b): a new unit's fold hook is built.** `_foldPublication` now calls `_foldHooks` with the carried mask,
and each unit's hook runs when `RealmIndex._hookRuns(unit, carried)` says so (default: mask 0, exactly as before).
The example generation overrides it: a unit at or above `NEW_UNITS_FROM` (a number its reads contract records, so the
manifest hash covers it) runs in every fold, live and from history; every unit below it only live or in an all-fresh
fold. `test/index/HeadAuthorsHooks.t.sol`: generation 1 pins a recording fold hook A from genesis, the example
generation keeps A and adds a recording hook B; the build calls A never and B once per effect of history, B's record
then equals A's (same effects, same order, same refs), and after activation both advance together. No change to the
`Unit` struct: "new" is the generation's own list, not a field. Cost: `RealmIndex` 13 B smaller (18,705 → 18,692);
live, the loop now always runs and checks `_hookRuns` only for a unit that has a fold hook (none in generation 1).
**A gap that remained at step 3b** (closed by Option A below): a generation that carries every store walks nothing
(`build` moves the frontier straight to `counts()`), so a unit it adds never saw the history
(`::test_a_re_pin_cannot_build_a_new_units_hook`: the kernel activated it). The hook's companion store is the hook's own
business (the recording hooks keep their own storage); a store the generation names is fresh or carried as above.

**Landed (Option A, 2026-11-26, branch `fable/2026-11-26-liveness`): a new fold-hook unit is refused by default.**
Whenever a generation carries a store (a re-pin, or a build that heals a store), its carried check also asks that every
unit with a fold hook be **carried**: the live index's manifest, read from the same verified copy as the families (§3.5),
declares a unit with the **same fold hook address, the same fold codehash and the same `purposeFilter`**
(`IndexReads._unitsCarried`). Those three are exactly what decides which effects a hook is given: `RealmIndex._foldHooks`
calls `u.foldHook` (skipped when it is zero) on every effect whose purpose matches `u.purposeFilter` (0 = every effect);
`_hookRuns` decides only whether the unit runs in this fold at all; nothing else in a `Unit` gates a call. So with the
three equal, the live index has called that very code with exactly these effects for every admission. A wider filter
leaves effects the hook never saw; a narrower one leaves folds in the hook's state that the new unit would never give
it; either way the hook does not hold what it would hold had it run from genesis under the new unit, so both count as
NEW. Not compared, because they decide no fold call: `familyIds`, the final hook and its codehash, `hotAbiId` and
`identity`. A NEW unit fails the check (`build` `E_BUILD(7)`, readiness claims nothing, so activation refuses
`E_INDEX_NOT_READY(8)`; coverage of carried families follows the check as before), with two exceptions: an empty Realm
(no history to miss; the check has its own rule there) and a unit the generation builds itself. A unit with only a final
hook is never judged (final hooks never run from history). No kernel change and no hook-interface change.

**The opt-out is an explicit claim by the generation's pinned code.** `IndexReads._builtHooks()` (internal virtual,
default 0; `builtHooks()` answers it) names, by bit, the units whose fold hooks this generation builds from history. The
generation reads it once at construction into `RealmIndex.BUILT_HOOKS`, and `_hookRuns` (now private, not virtual)
runs a hook in a fold that carries a store only when its bit is set; the carried check accepts a NEW unit only when its
bit is set. So the hooks a build calls and the hooks the check accepts as built are one value and cannot get out of
step (`HeadAuthorsHooks.t.sol::test_a_new_units_fold_hook_is_built_and_a_carried_units_is_not` asserts both read the
same mask). The claim is accepted only when the generation **walks** (it has a fresh store, so `build` folds every
publication from 1 and calls the named hooks on each): a generation that carries every store walks nothing, so no claim
to build a hook can be true for it and none is accepted (`::test_a_re_pin_cannot_build_a_new_units_hook`, now refused
7 / 8 even though its reads contract names the hook). Beyond that, claiming the bit for a hook the code does not really
build from history is the author's lie in pinned code (the manifest hash covers the reads contract's code), not a gap
in the kernel. Tests (`test/index/HeadAuthorsHooks.t.sol`): refused by default (`build` 7, nothing complete, activation
8); the same hook address with another codehash is new; a wider and a narrower `purposeFilter` are new; identical units
(another `identity` only) are carried and build and activate; final-hook-only units, new or changed, are unaffected;
the step-3b generation that builds its new hook passes through the opt-out; the empty Realm accepts a new fold-hook unit
(`Liveness.t.sol::test_the_empty_realm_accepts_a_new_fold_hook_unit`). `BuildWalkRefusals.t.sol`'s heal build with a
new hook unit is now refused 7 (it built with the hook called for nothing).

**Why the kernel does not check a hook frontier instead (rejected; do not propose it again).** The alternative was a
kernel check that each unit's fold hook reports a frontier equal to the ledger's admission count. (1) The kernel would
have to pin a hook interface it does not pin today: it calls no hook and pins hooks only by codehash and `hotAbiId`
(above). (2) The hook would have to keep that frontier: a storage write of about 5,000 gas on every live publication,
forever, on every Realm. (3) The answer would still be a claim by pinned code, so a generation that forgot to build the
hook, paired with a hook that reports the ledger's count, would pass. Option A costs nothing live and puts the claim
where the code that makes it is.

**The rule for a unit's fold hook and history (step 3b; a pre-freeze rule).** A fold hook runs in its own call, so it
cannot use the generation's `_fromHistory()`, and `IIndexHook.fold(effect, refs, publication)` carries no flag. The
code says who owns that interface: the kernel never calls a hook; it pins each unit's hook addresses by codehash, scans
them as plain runtime and requires their `hotAbiId` to be supported (`LedgerControl._checkIndex`, `_pinUnit`), and it
does NOT check `callbackProfile` (nor `physicalProfile`) at activation: the readiness tuple reports it and only the
readers compare it (`TopicReaderBase`, `FilesPageReader` and `LensReader` answer UNSUPPORTED for any other value).
`callbackProfile` (`efs/index-callback/4:ordered-prefix:static-final:effect-24:refs`) describes the ledger's calls to
the index, not the index's calls to its hooks; the only caller of `IIndexHook.fold` is the generation's own code
(`RealmIndex._foldHooks`). Today `IIndexHook.fold` is implemented by `FilesFinalValidator` (an acknowledgement, never
called: its unit has no fold hook) and by test doubles only (`RealIndex.t.sol`, `Replay.t.sol`, `Carried.t.sol`,
`BuildWalkRefusals.t.sol`, `BuildAsOf.t.sol`'s `PassiveTopicHook`, and this step's `RecordingFoldHook`). So:

- **Rule (i), the rule now:** a fold hook must be exact on its own. It may use the effect, the refs, the publication
  and ledger facts read as of the effect's admission, and it makes the first-admission comparison of §4.3 on every
  call, live included, for any fact whose existence can begin after the admission (it pays that read live). A hook
  that uses only the effect, as both recording hooks do, needs no comparison.
- **Rule (ii) stays available without a kernel change:** a later generation may call its OWN new units through a
  different hook interface (for example one with a "from history" argument), because the generation, not the kernel,
  owns that call; such units are pinned by codehash like any other. It should not do that by changing
  `CALLBACK_PROFILE`, which the readers compare and which names the ledger's callback shape, but by its own convention
  for the units it lists as new. So nothing needs to go into `IIndexHook` before freeze.
- **A hook can already tell live from history**, with no interface change: the generation calls fold hooks live inside
  `onAdmission`, where `ILedgerHot.phase()` is APPLYING, and from history only inside `build` or `replayNextPublication`,
  which both require IDLE. A hook that wants to skip the comparison live may read `phase()` (one call to the ledger) and
  compare only when it is IDLE. This relies on the kernel's phase semantics and on the generation's gates; rule (i) is
  the simple form and is what this document asks.

---

## 4. Exactness: built equals live

The argument has three parts, and each family kind is an instance of them.

**Same inputs.** The build folds the same `Effect` stream: the decoder rebuilds it from write-once admission rows,
and `Replay.t.sol:562` checks every decoded publication hashes to the `effectsHash` the live publication emitted.

**Same operations, same order.** The build runs the live fold code for each built family, so for each key it issues
the same sequence of store operations (counted append, UNCOUNTED append, `release`, `retain`, `appendScopeEntry`,
`setBit`, `stamp`) in the same order, because it walks admissions ascending and folds each publication's leaves in
order. A head's `count`, `live`, `last` and entries are functions of that sequence alone.

**Same store behavior in both modes.** In `PostingStore`, the mode decides only whether a write is allowed; no
write's effect depends on it (`PostingStore.sol:112-187`). In `BitmapStore`, the only mode-dependent value is the
admission check: a live write must stamp the frontier, a build write may stamp any admission up to it
(`StoreBase.sol:83-92`). The build passes the admission it folds, which is the frontier the live write had, so the
stamp is the same (`Stores.t.sol:545-562`). One exception, not used by any fold today: `retireCoverage` stamps the
*current* frontier (`BitmapStore.sol:203-210`), so a built family must never call it (§9, Q10).

Two properties make a wrong build fail loudly instead of diverging: the order law (`E_ORDER` on an entry not above
`last`, `PostingStore.sol:173`) and the counter bounds (`release` below zero, `retain` above `count`:
`PostingStore.sol:150, 161`). A build that skipped an append would revert at the next release of that key.

### 4.1 APPEND entries

Entries are admission or binding ordinals taken from the effect, appended in admission order. Binding ordinals are
allocated in admission order, so they rise too. The order law holds because the walk is ascending.

### 4.2 The counters

The task names three. The code has more, and all follow the same argument.

- **Family 5 `live` (backlink, HEADS).** Release `oldTarget`'s key when `oldTarget != 0` and the action is not a
  same-target BIND; append `target`'s key (counted) on every BIND that is not same-target
  (`RealmIndex.sol:347-352, 402-404`). Inputs: `kind`, `target`, `oldTarget`, all in the effect. A same-target
  re-bind touches nothing, live and built.
- **Family 20 `live` (the yes-count, HEADS).** FIRST_BIND appends counted; FIRST_MASK appends UNCOUNTED
  (`RealmIndex.sol:443`); RESTORE retains (`:383-385`); MASK or RELEASE with `oldTarget != 0` releases
  (`:398-400`). Inputs: the transition kind and `oldTarget`, from the effect.
- **Families 6 and 7 `live` (DISTINCT).** A filing is counted only when the position is fresh, otherwise appended
  UNCOUNTED (`RealmIndex.sol:445-446, 450, 478`). "Fresh" is a read of family 20's head (next part).
- **Families 1, 4, 12 `live` (OCCURRENCE)**: lowered by WITHDRAW (`RealmIndex.sol:485-495`), from the effect.
- **The scope head's `live` and `lastMutation`** (`BitmapStore.sol:97-101, 119-128`): `setBit` on `live-scope`
  moves `live` only when the bit changes, so it is a function of the bit sequence; `lastMutation` is the stamped
  admission (above).

Each is moved only by store operations the fold issues from effect fields, so each is reproduced by the same
operation sequence. `MODE_BUILD` accepts every one of these operations (§0). That is why no store change is needed,
and why "it is safe" needs no more than "the builder is the store's only writer before attachment, and it writes
in ascending order".

### 4.3 Folds that read state besides the effect

**The as-of rule (step 3a).** A fold from history reads every fact as of the admission it folds. A validator's law
is never a source of facts for a build. Live, the fold reads state at the moment of admission (the kernel applies a
publication's leaves one at a time and calls the index after each, `LedgerCore._applyOne`: apply the leaf, raise
the admissions counter, `_notifyIndex`, then the next leaf), so "as of the admission" is free and always true,
whatever validator is installed: the fold of leaf k sees what leaves below k wrote, in earlier publications and in
earlier leaves of its own, and nothing a later leaf writes. From history the same read sees today's state. So for any
fact whose EXISTENCE can begin after the admission being folded, the history path compares the fact's first
admission with the folded admission, and treats the fact as absent unless it is strictly below. A fact that is
write-once and necessarily present at that admission by a KERNEL law needs no comparison. A validator's law (a final
hook's refusal) is not such a law: a build never re-runs final hooks, so a law holds only for history judged under it,
and a Realm's earlier history may have been admitted under no validator, or under one without that law. The live
path runs the same reads as before: a fold knows it is from history by the selector of the call it runs in
(`RealmIndex._fromHistory`: `msg.sig == replayFold`, the one entry point of every replay and build, callable only by
the generation itself; the live fold enters through `onAdmission`), and tests it only where a read needs the
comparison.

These are the generation-1 folds that read more than the effect. In a full replay (case (e)) every one of them runs
in the build; in a partial build only those of the built families do, and the rule after the table says which
reads a built family may have.

**Landed (step 2): the table, checked against the code read by read.** The proposal's table (kept below the rule
for its argument) missed the withdrawal's by-record read, every read the stores make inside a write, the writer
rule's reads and most of the decoder's. This is the full list. "Posting part" and "bitmap part" are the two halves of
the fold: `_foldRecord`, `_foldWithdraw` and the posting half of `_foldBind` write only the posting store;
`_foldScope` (the bitmap half of `_foldBind`) writes only the bitmap store. A build that heals one store runs only
that store's half (the carried mask, §3.2). The verdicts: **R** reads only what it rebuilds (a fresh store's own
state, rebuilt in the same walk, or write-once ledger facts); **E** reads carried *entries* (allowed: append-only);
**F** reads a carried head, counter or bit (forbidden); **—** does not run in that configuration.

| # | read | where (code) | posting carried, bitmap fresh | posting fresh, bitmap carried | as of the admission: why |
|---|---|---|---|---|---|
| 1 | by-record head `count` (is the first occurrence still virtual?) | `_foldRecord` | — (posting part skipped) | R: fresh posting store, same walk | cannot change behind the fold: the fresh store holds exactly the admissions below this one (same walk, ascending) |
| 2 | `recordHeader(recordId).firstAdmission` | `_foldRecord` | — | R: write-once ledger record cell | write-once, present: a REUSE or repeat PUBLISH names a record first admitted at an earlier admission (`LedgerIngress.validateLeaf`: `E_MISSING_RECORD`; `LedgerApply._applyRecord` writes the cell only when its Type word is 0) |
| 3 | a digest body word | `_foldRecord` | — | R: write-once record body | write-once, present: the fold of a fresh record reads its own body, written by this very leaf before the index is called (`LedgerCore._applyOne`: apply, then `_notifyIndex`); `_storeBody` runs once per record |
| 4 | the digest de-duplication (`_buffered`) | `_foldRecord` | — | R: this effect's own memory buffer | memory of this effect |
| 5 | by-record head `count` (materialize a withdrawn virtual first occurrence) | `_foldWithdraw` | — | R: fresh posting store | as row 1 |
| 6 | family 20's head `count` (is the position fresh?) | `_firstStatementLists` | — | R: fresh posting store, same walk; every earlier effect of the publication is flushed before this one folds | as row 1 |
| 7a | the ancestor walk, the subject's level: its Type word and body word 0 | `_walk` | — | R: write-once records, compared with the statement's admission on the history path (7b) | **could begin to exist later.** Nothing in the kernel stops a tag under a subject that is registered after it (only validator code 9 does); write-once once it exists (`_applyRecord`). So on the history path it counts only through 7b |
| 7b | the ancestor walk, the subject's cell word 1 (its first admission): **new, history path only**, in the same batch as 7a | `_walk` | — | R | the comparison: the subject is a topic for this statement only if its first admission is nonzero and strictly below the statement's admission; the live fold of the same leaf sees exactly the records of lower admissions (the per-leaf loop), so the two stop at the same place. Write-once (`firstAdmission` is set with the cell) |
| 7c | the ancestor walk, each proper ancestor's Type word and body word 0 | `_walk` | — | R: write-once records | write-once, present: reached only from a subject first admitted below the statement; the kernel's reference law (`LedgerIngress._resolveRefs`: a declared reference that is no record is refused, `E_REF(leaf, i, 1)`, checked before the leaf applies) admits a `topic/1` record only after its parent (body word 0), so each ancestor's first admission is below its child's |
| 8 | the scope list's `count` and entries (`_entryIndex` bisection, on RESTORE, MASK, RELEASE) | `_foldScope` | R: fresh bitmap store, same walk | — (bitmap part skipped) | as row 1 (the fresh bitmap store) |
| 9 | the entry index `appendScopeEntry` returns (used by the first mask's `setBit`) | `_foldScope` | R: fresh bitmap store | — | as row 1 |
| 10 | inside `append`/`appendBatch`: the head's `count` and `last` (order law, word position) | `PostingStore._append` | — (no posting write) | R: fresh posting store | as row 1 |
| 11 | inside `release`/`retain`: the head's `live` and `count` (counter bounds) | `PostingStore` | — | R: fresh posting store | as row 1 |
| 12 | inside `appendScopeEntry`: the scope head's `count` and last entry (order law) | `BitmapStore` | R: fresh bitmap store | — | as row 1 |
| 13 | inside `setBit`: the scope head's `count`, the live bit and `live` | `BitmapStore` | R: fresh bitmap store | — | as row 1 |
| 14 | the writer rule: `ledger.index()`, `phase()`, `counts().admissions` | `StoreBase._authorizeWriter` | R: the frontier bounds the stamp only (a build write may stamp any admission up to it, `_stampAdmission`) | same | not a fact folded: bounds the stamp a build write may carry, never what it writes |
| 15a | the decoder: evidence cell word 0 (leaf count, first admission) | `IndexReplayDecoder._decode` | R: write-once | same | write-once, present: written once in `LedgerCore._begin` under a fresh publication ordinal, before any leaf of the publication; a build or replay runs only while idle, so every publication it decodes is complete |
| 15b | the decoder: evidence cell word 1 (the revision in force) | `_decode` | R: write-once | same | write-once, present: as 15a (`e.revision = $.revision` in `_begin`) |
| 15c | the decoder: evidence cell word 2 (the principal) | `_decode` | R: write-once | same | write-once, present: as 15a |
| 16 | the decoder: the revision row's layout word | `_decode` | R: written once at activation | same | write-once, present: a revision row is written once, by the activation of that revision (`reinitializer(revision + 1)` makes revisions strictly increase), before any publication under it; a mismatch reverts (`E_REPLAY(2)`), it folds nothing |
| 17a | the decoder: each admission row's word 0 (kind, leaf, binding ordinal, expected revision, previous admission, target kind) | `_decode`, `_effect` | R: write-once | same | write-once, present: written once by its own leaf (`LedgerApply.applyLeaf`); the one field that changes later, `withdrawn` (set on a PUBLISH/REUSE row by a WITHDRAW), is not read |
| 17b | the decoder: each admission row's word 1 (`a`: record id, salt, target, or withdrawn admission) | `_decode`, `_effect` | R: write-once | same | write-once, present: as 17a |
| 17c | the decoder: `bindingPosition[bindingOrdinal]` | `_effect` | R: write-once | same | write-once, present: written once by `LedgerApply._allocate` at the binding's first statement, at or before this admission (an ordinal is allocated once) |
| 17d | the decoder: the previous bind row's word 0 (its kind and target kind: the transition, `oldTargetKind`) | `_effect` | R: write-once | same | write-once, present: an earlier admission's row (`prevAdmission` < this one; row 0, never written, means UNSET); `withdrawn` not read |
| 17e | the decoder: the previous bind row's word 1 (`oldTarget`) | `_effect` | R: write-once | same | write-once, present: as 17d |
| 17f | the decoder: the position cell (purpose, subject, role) | `_effect` | R: write-once | same | write-once, present: written by `_allocate` only while empty (`p.purpose == 0`), at the position's first statement by anyone, at or before this admission |
| 18a | the decoder: a withdrawal's target row (word 0: its publication; word 1: the record id) | `_effect` | R: write-once | same | write-once, present: the target is an earlier admission (`_applyWithdraw`: `target < admission`); `withdrawn` not read |
| 18b | the decoder: the withdrawn record's Type word | `_effect` | R: write-once | same | write-once, present: the record was first admitted at the target admission or before (`_applyRecord` writes a cell only when its Type word is 0) |
| 18c | the decoder: the target publication's principal (evidence word 2) | `_effect` | R: write-once | same | write-once, present: as 15a, for an earlier publication |
| 19a | the decoder: a PUBLISH/REUSE record's Type word and cell word 1 (`freshRecord` = first admission equals this one) | `_effect` | R: write-once | same | write-once, present: the leaf itself wrote the cell or found it written (`_applyRecord`); `firstAdmission` never changes (`occurrences`, which does, is not used) |
| 19b | the decoder: the Type's `refCount` (`TypeRegistry.typeInfo`) and the registry address (`registry()`) | `_effect`, `_decode` | R: registration is append-only and never changes a Type (design §8.7) | same | write-once, present: the Type was registered before any record of it was admitted (`validateLeaf`: `E_UNKNOWN_TYPE`); `registerDescribed` returns early on an existing row; `refCount` is the length of the reference Types the id commits to; the registry address is set once, at genesis (`LedgerControl` initialize) |
| 19c | the decoder: a record's leading body words (the refs) | `_decode` | R: write-once | same | write-once, present: written once with the record's first admission (`_storeBody`), at or before this one |
| 20 | the build's own leaf count of the next publication (before decoding) | `RealmIndex.build` | R: the write-once evidence cell | same | write-once, present: as row 15 |
| 21 | the fold's own progress word (`lastProcessed`, `lastPublication`), the generation's digest specs and topic Type ids | `_foldPublication`, `_foldRecord`, `_firstStatementLists` | R | same | the generation's own state and immutables: the order check and its configuration, the same for every fold; not ledger facts |
| 22 | the build's and replay's gates: `counts()`, `phase()`, `index()`, `IndexReads.carriedCheck()`, the stores' `initialWriter()` / `attached()` | `build`, `replayNextPublication`, `_carried`, `_spoiled` | R | same | not folded: they bound the walk or refuse the call, and choose the store bits of the mask; no list entry or counter is taken from them |
| 23 | fold hooks (called only with no store carried) and final hooks (never called from history) | `_foldHooks` | — | R (hooks: none in generation 1) | not the fold's reads: a later unit's fold hook gets the same effects as live and must keep the as-of rule itself (§3.6) |

No posting write depends on a bitmap read and no bitmap write depends on a posting read: the only value one half
takes from a store is the scope entry index (rows 8, 9), and it feeds only the bitmap half's own `setBit`. **Neither
mixed configuration needs a forbidden read, so both are built** (`build` heals either store); no configuration is
refused, and no `E_BUILD` code is spent on one. Nothing in either half reads the *carried* store at all, not even its
entries, so the "E" verdict has no row in generation 1. Tests: `test/index/BuildWalk.t.sol::test_heal_the_bitmap_store`,
`::test_heal_the_posting_store` and `test/index/BuildWalkRefusals.t.sol::testHealEachStoreAgainstATwinRealm`.

**Landed (step 3a): the last column, the audit of every read against the as-of rule.** One read could begin to exist
after the admission it serves: row 7a, the subject of a tag (now compared through 7b). Before step 3a the walk read the subject's Type word as
it is when the fold runs and relied on `FilesFinalValidator` code 9 for the rest, so on a Realm whose history was not
judged under code 9 (a first generation with no topic lists and no Files validator, or a validator without the law)
a tag could be admitted before its topic, and a topic-list generation built later filed a roll-up for it when the
build ran after the topic's registration and none when it ran before: the built lists depended on when the build
ran. Fixed: on the history path `_walk` reads the subject's cell word 1 (its first admission) in the batch it already
makes and stops when that is 0 or not strictly below the statement's admission; a live fold of the same leaf sees no
such record and stops at the same place, so built equals live on every history. Every other read is of a fact that
cannot begin or change after the folded admission, by a kernel law named in the column, or of the generation's own
fresh store, rebuilt in the same walk. No other defect was found. One reach beyond the ledger: row 19b's Type row is
write-once in the current `TypeRegistry` code, and the registry implementation can be replaced by an activation until
freeze; a replacement must keep existing rows (a Type's `refCount` is also fixed by its id, which commits to its
reference Types). Also outside the fold: the store writer rule (row
14) and the build's own gates (`counts()`, `phase()`, `index()`, `IndexReads.carriedCheck`) bound or refuse a call and
are not folded; a fold hook is called from history with the same effects as live and must keep the rule itself (a
later unit's obligation, docs §3.6; generation 1 has none); final hooks are never called from history.

**The Files laws.** No fold of generation 1 takes a fact from any of `FilesFinalValidator`'s codes 1 to 16 now. Code 9
was the walk's (above). The others constrain what an effect may say (a FOLDER entry's name, parent and target, a
HEAD's revision, a TAG target equal to its role, a SAME/BROADER pair of topics, a first "not this" naming something
that exists); every list that those effects touch (backlink by target, place by subject, role-places by role,
position-authors and history by position, role-scope, the scope list) is keyed and filled from the effect itself, so
a list built over history that broke a law holds exactly what the live fold filed for it. Readers that rely on a law
(the HEAD law, for example) re-check it themselves (`FilesFinalValidator` NatSpec, "defence in depth").

Tests: `test/index/BuildAsOf.t.sol` (default and amsterdam profiles). Realm U admits its history with no unit and no
topic lists; a topic-list generation with the real validator as its unit builds it. Built before the topic's
registration and continued after it, built after it, and replayed: the same lists, with no roll-up for the early tag
(`test_build_does_not_depend_on_when_it_runs`). Realm V takes the same history with the topic lists live beside a
final hook that answers the topic getters and judges nothing; U's built lists equal V's live lists key by key
(`test_built_equals_a_live_fold_without_the_law`; heads and every entry of families 5, 6, 7, 8, 11, 16, 19, 20, 21 and
the scope lists). In one publication, a topic registered in the leaf before the tag rolls the tag up and one
registered in the leaf after it does not, live and built (`test_same_publication_topic_first`,
`test_same_publication_tag_first`: the topic's first admission is the tag's admission − 1 and + 1, the two sides of
"strictly below"). The live fold never reads the first-admission word, and a build of the same tag reads it once
(`test_the_live_fold_never_reads_the_first_admission`, a ledger read recorder on V, where nothing else reads the
subject). The built-equals-live suites over history judged under code 9 (`BuildWalk.t.sol`, `BuildWalkRefusals.t.sol`,
`TopicListsReplay.t.sol`, `Replay.t.sol`) pass unchanged: there the comparison is always true.

The proposal's table, for its argument (its walk row relied on the validator; superseded by the as-of rule above):

| read | where | why the build sees what the live fold saw |
|---|---|---|
| family 20's head (fresh-position test) | `RealmIndex._firstStatementLists` | Family 20 is rebuilt **in the same walk, in the same store**, so before admission k its head holds exactly the operations of admissions below k. |
| by-record head (materialize the virtual first entry) | `RealmIndex._foldRecord`, `_foldWithdraw` | Same: rebuilt in the same walk. |
| scope-list bisection (`_entryIndex`) | `RealmIndex._foldScope` | Same, in the fresh bitmap store; or, for a bits-only store (§2.3 route 3), the carried scope list, whose entries never change once written. |
| `recordHeader(recordId).firstAdmission` | `RealmIndex._foldRecord` | Written once, when the record is first admitted. |
| a digest body word | `RealmIndex._foldRecord` | Record bodies are write-once. |
| the ancestor walk: a record's Type word and body word 0 | `RealmIndex._walk` | Write-once records; the validator admitted the tag only if its topic was registered strictly before (code 9; `IndexProfiles.sol:26-34`), so every record on the chain existed at the original admission and has not changed. Records registered later are not on the chain: a parent link is written when its child is registered. |
| the Type's `refCount` (decoder) | `IndexReplayDecoder._effect` | Registration is append-only and never changes an existing Type (design §8.7). |
| position and binding cells (decoder) | `IndexReplayDecoder._effect` | Write-once. |

**The rule this gives a built family:** its fold may read write-once ledger facts that a kernel law makes present at
the folded admission (any other fact it compares with that admission on the history path, the as-of rule), and heads
of families rebuilt in the same walk. It must **never read a carried family's head or counter**, because those hold the state at the
frontier, not at admission k.

A carried list's *entries* can still be read historically, because they are append-only and ordered. Example: a
new family that needs "was this TAG position fresh at admission k?" (k being a first statement there) may read
carried family 20's entry 0, the admission of the position's first statement: fresh at k exactly when entry 0 is k.
Its `live` cannot be read that way.

The other direction, as an example of what the rule forbids: a later family that needs "how many things apply at
this place now, as of admission k" cannot read family 20's yes-count, which holds the count at the frontier. It
has to keep its own per-position count and rebuild it in the same walk.

`head-authors` reads nothing but the effect, so it needs none of this (step 3b: `HeadAuthorsIndex._foldMore` reads no
store and no ledger fact).

**Fold hooks keep the as-of rule themselves (rule (i) of §3.6).** A hook is called from history with the same effects
as live and cannot see the generation's `_fromHistory()`; it must therefore make the first-admission comparison on
every call, live included, for any fact that can begin to exist after the effect's admission, or read only the effect.

### 4.4 The only other writer

Store rule 1 accepts `ledger.index()` during a publication as a writer of *any* store that lists the family
(`StoreBase.sol:52-56`), fresh or not. Generation 1 cannot address a fresh store: its store addresses are
immutables. If a live index ever did write a fresh store, the store would attach and the build would then fail with
`E_WRITER`, not diverge silently. A builder that is not the store's `INITIAL_WRITER` is refused
(`StoreBase.sol:59-67`).

---

## 5. Switching on

### 5.1 What "ready" means for a built family

- the family's manifest entry has `fromAdmission == 1` (`LedgerControl.sol:323`);
- its coverage is COMPLETE: `from == 1`, `through == lastProcessed == counts().admissions`, not gapped
  (`IndexReads.sol:231-241`); before that it reports PARTIAL with `through` = the build frontier (design §10.7);
- its store is pinned by codehash, scanned plain, lists the family, and has contiguous writer ranges
  (`LedgerControl.sol:324-330`); a fresh store's list is `[(generation, 1, open)]`, or empty if history held no
  entry for it.

**Landed (step 3b),** for a family in a third store: `head-authors` is declared with `fromAdmission == 1` in a store
that lists it; it reads PARTIAL (1, frontier) while the build is behind and COMPLETE when caught up; activation of an
unfinished build refuses with reason 8 while it reads PARTIAL; after activation it reads COMPLETE, and the first live
HEAD statement appends to the third store and attaches it, keeping the one writer range `[(generation, 1, open)]` the
build opened (`test/index/HeadAuthorsBuild.t.sol::test_build_races_and_switches_on`). The kernel's checks 9 to 13 run
per family and per store, so the third store needed no kernel change: it is pinned, scanned, checked to list the
family and for contiguous ranges, refused when another contract's (12: on an empty Realm because its `INITIAL_WRITER`
is neither 0 nor the candidate, with admissions because the live index does not declare the family in it) or when
attached under the candidate's name (13), and accepted when the live index is a three-store generation that declares
the family in that very store (a re-pin of all three stores).

### 5.2 What `checkActivation` re-derives today

For a new index: plain runtime of the index and its reads contract, the readiness tuple's ledger, layout, hot ABI
and manifest hash, `phase == IDLE`, exact catch-up (`completedAdmission == admissions`, `completedPublication ==
publications`), unit and store pins, APPEND `from == 1`, families in their stores, contiguous writers
(`LedgerControl.sol:269-332`). It trusts the generation's own `completedAdmission`, which is acceptable: the
generation's code is pinned by codehash.

### 5.3 What it should also check (before freeze)

Two checks belong in `LedgerControl._checkIndex`, as defense beside the generation's own (§3.5):

- **Carried families are the live index's** (new `E_INDEX_NOT_READY(12)`): for each family whose store does not
  name the candidate as `INITIAL_WRITER`, the current `$.index` declares the same family in the same store from 1.
- **Fresh stores are the candidate's** (new `E_INDEX_NOT_READY(13)`): a store that names the candidate as
  `INITIAL_WRITER` is not attached.

**Landed (step 1),** in `LedgerControl._checkIndex`, inside the loop over the candidate's maintained families, after
the store's pins, family list and writer ranges: a store whose `initialWriter()` is the candidate must not be
`attached()` (13); otherwise, when the ledger has admissions, the live index's own `replayReadiness().families`
(read from `$.index`, once, only when a carried family needs it) must hold an entry with the same family id, the
same store address and `fromAdmission == 1` (12); a live index without code is 12. With no admissions, 12 instead
requires every store of a maintained family to have an empty writers list, whoever its `INITIAL_WRITER` is
(genesis: new stores, empty lists). Together the checks keep one invariant by induction: **every store of the live
index holds only what pinned generation code wrote.** The base case is the empty Realm (no store written); a carried
store is the live index's (12); a fresh store is the candidate's own, unattached, and written only by the
candidate's codehash-pinned code (13).

**Landed (step 2): the base case, closed, and the induction argued again.** A store accepts exactly three writers
(`StoreBase._authorizeWriter`): the live index while a publication is open (live), the live index while idle
(backfill: `openCoverage`, `backfillOr`, `backfillSet`, `retireCoverage` only), and the store's `INITIAL_WRITER`
while the store is unattached and the ledger idle (build). The first two are the live index, whose code the kernel
pinned at activation. So the invariant rests on the third: who is a store's `INITIAL_WRITER`, for as long as it is
unattached. Step 1's empty-Realm rule asked only that a store be unwritten at activation; a store whose
`INITIAL_WRITER` was a third contract could then be written by it in build mode after activation, before the first
live write attached it. **The rule is now: on a Realm with no admissions every maintained family's store is
unwritten AND names 0 or the candidate as `INITIAL_WRITER`** (reason 12, and the generation's carried check, so
`build` gives 7). With it, by induction over activations: the first activated index that names a store S was either
activated on an empty Realm (so `INITIAL_WRITER(S)` is 0 or that index), or with admissions, where S is either fresh
for it (`INITIAL_WRITER(S)` is that index, unattached: 13) or carried, which 12 allows only if the live index already
names S, contradicting "first". **So every store any live index has named has `INITIAL_WRITER` 0 or a generation
that was itself activated over it** (codehash-pinned, its activation having passed every check).

The lazily attached store: with admissions, a store of the live index L can still be unattached, because stores
attach at their first live write and no admission has touched it yet. Who can write it in build mode?

- **A genesis store** (`INITIAL_WRITER = 0`): nobody (`StoreBase` refuses a zero `INITIAL_WRITER`).
- **A store whose `INITIAL_WRITER` is a generation G that was activated over it and later replaced before the store
  attached.** G is pinned code that was activated. It can write S in build mode only through its own `build` or
  `replayNextPublication`, which refuse once G has folded live (1); so G was replaced before any admission reached it
  (`liveStarted == 0`), and its frontier is the count at its activation (check 8). Its walk folds only admissions
  after that, and every admission since then that touches S's families was folded live by G's successors into S,
  which attached S on the first one; while S is unattached there is none, so G's walk writes nothing to S (it may
  fold CREATEs, which touch no store), and once S is attached G is refused (2). "Writes nothing" holds when G and
  the generation folding live keep the same lists in S, which is true for every generation of generation 1's code.
  **If the successor dropped a list F from S**, the precise statement is: a publication that touches only F does not
  attach S (the successor writes nothing for it), so G's walk can still fold F's entries for it into S. That does
  not break the invariant: G is pinned code that was activated, and what it writes is the honest fold of F. The
  entries are dead weight: nobody reads them through the live index, which does not declare F, and no later
  generation can declare F in S again, because check 12 needs the live index to declare F in S from admission 1. A
  list the successor still keeps can never be written by G after the switch: any publication touching it was folded
  live first, which attached S. So dropping a list from a carried store is allowed and is not refused; forbidding it
  would force a whole-history rebuild of the kept lists (§6.2) for an ordinary cost cut. **Since the liveness gate
  this case no longer arises for G:** G carries the genesis bitmap store, and a replaced generation that carries any
  store can no longer build at all, because its manifest copy is stale (it copies the index G replaced, and the
  revision row now records G' instead), so `build` refuses 7 before folding anything. Only a generation whose every
  store is fresh asks for no copy, and so only such a generation can still walk late; the argument above, that what it
  writes is the honest fold of pinned, activated code, still covers it. **Tested (step 3b, then the liveness gate),
  `test/index/DroppedList.t.sol`, and every step behaved as claimed, so no kernel refusal is added:** G (example code:
  generation 1's posting lists plus X, `subjects-created`, folded on CREATE only, in a fresh posting store T; the genesis
  bitmap store carried) builds and is activated; before any admission reaches it, G' (generation 1's code) carrying T
  and the bitmap store is built (check 12 passes: G declares each of G' s lists in T from 1) and activated; a
  CREATE-only publication leaves T unattached and every generation-1 list in T unchanged (equal to a twin Realm that
  ran generation 1 throughout); G's late `build` is refused 7 (stale copy; at step 3b, before the liveness gate, it was
  allowed and folded that CREATE into X), so T keeps no entry of the CREATE; a bind is folded live by G' and attaches
  T, after which G's `build` is refused 2 and the kernel refuses G 13; H (G's code
  declaring X in T again) is refused, `build` 7 and activation 12; after more traffic every list G' keeps equals the
  twin's, key by key; X's entries are dead weight, UNKNOWN through G' and readable only from the store. Shown before
  step 3b:
  `test/index/BuildWalkRefusals.t.sol::testAFreshStoreAttachedByALiveWriteRefusesTheBuild` (C builds, is activated,
  is replaced by D before any admission; C's `build` then folds nothing; D's first write attaches C's stores; C gets
  2 and the kernel 13).
- **A candidate's own fresh store** (`INITIAL_WRITER` = the candidate, unattached: 13): only the candidate, pinned by
  the codehash the activation names. Once it is the live index, its writes are live or backfill (rule 1 is checked
  first), and its `build` refuses (1).

No case lets unpinned code write a store of the live index. Tests: `testAnEmptyRealmRefusesAStoreAThirdContractCouldWrite`
(the candidate is refused 12 and `build` 7; the squatter's write then lands in a store no index names, and it cannot
write the genesis stores the live index uses) and `testAnEmptyRealmStillActivatesARePinAndAFreshGeneration`. The exact catch-up check (8) now runs **after** the
family loop, so a candidate that can never be ready is named 12 or 13 instead of "behind". Reasons 1 to 13 are listed
in `src/interfaces/Errors.sol`.

**Landed (the liveness gate): check 12 reads the candidate's verified copy, and reason 14.** With admissions, for the
first carried family the kernel asks the CANDIDATE for its copy of the live index's manifest
(`IIndexReads.liveManifestCopy()`, answered through the candidate's fallback by its reads contract), requires
`keccak256(copy)` to equal `indexManifestHash` of the current revision row (`_revisions().rows[$.revision]`, the row
that activated or kept the live index), and decodes only the copy's leading `(bytes32, FamilyEntry[])`
(`LedgerControl._liveFamilies`). A copy that does not hash to the record is **`E_INDEX_NOT_READY(14)`**; it never calls
the live index. Because the copy is canonical once it hashes to the record, decoding only its prefix is sound; a copy
with a trailing byte changed is refused 14 (`test/index/Liveness.t.sol::test_a_wrong_copy_is_refused`). The kernel's
defense does not rest on the candidate's honesty: a lying candidate that reports itself caught up and declares a store
the live index does not declare is refused 12 with a true copy and 14 with a forged one
(`::test_a_lying_candidate_is_refused_12_with_a_true_copy_and_14_with_a_forged_one`). The empty-Realm rule is unchanged
and asks for no copy (genesis passes an empty one). No kernel ABI change, no change to the activation set, no CREATE in
the Core context. `LedgerControl` 17,830 → 18,042 B. Order: the copy is checked at the first carried family, so a
replaced candidate that carries any store now reports 14 before a later family's 13 (`HeadAuthorsBuild.t.sol`).

**The unchanged-index path (found, not changed).** An activation that KEEPS the live index (`index == $.index`) still
calls `IRealmIndex(index).replayReadiness().phase` for reason 2, uncaught: while the live index does not answer, every
activation that keeps it reverts with the live index's own error (for example a limits or controller change).
Replacing the index in that same activation is the recovery, and it now works with a correct copy
(`test/index/Liveness.t.sol::test_keeping_an_index_that_stops_answering_reverts_with_its_error`). The path was left as it
is: an index that cannot report its phase should not be kept, and the read is the design's §8.3 5h.

`LedgerControl` is part of the ledger implementation, replaceable by activation until freeze. After freeze the
kernel never changes, and a steward activation under posture B (design §8.10) would run the frozen checks; so if
posture B is chosen, these must be in the terminal implementation.

### 5.4 Admitting while building, and closing the gap

A build step is a transaction between publications. Each publication is one transaction too, so the Realm keeps
admitting while the build runs, the live index keeps folding, and the builder walks only finished publications
(`n <= counts().publications`). The builder falls behind by whatever lands between its calls, and catches up with
more calls.

Activation needs exact catch-up at the moment it runs (`LedgerControl.sol:304-306`). The gap between "built
through admission N" and the frontier must be closed so that no publication can land in between. Two ways, both
possible today, neither needing a new kernel entry point:

1. **One transaction.** The owner (a Safe) sends one batch: `index.build(0, maxFacts)` as many times as the gap
   needs, then `controller.activate(set)`. Nothing can publish inside a transaction. The activation set does not
   depend on the frontier (it names the index, codehash and manifest hash), so it can be prepared in advance. Good
   for a quiet Realm, or a small gap.
2. **A transition.** `controller.beginTransition(revision + 1, deadline)` makes every write revert `E_TRANSITION`
   until the deadline (`LedgerCore.sol:227-229`; design §8.8); anyone calls `build` until caught up; the controller
   activates, which ends the transition. The pause is at most `limits.maxTransitionBlocks`, so the bulk of the
   build runs before the transition and only the tail inside it. Good for a busy Realm.

If a publication slips in anyway (no batch, no transition), activation reverts `E_INDEX_NOT_READY(8)` and nothing
changes; build again and retry.

After activation the first live write to a fresh store attaches it and keeps one writer range from 1
(`StoreBase.sol:70-79`; `Replay.t.sol:336-340`). The first live write to a carried store closes the old index's
range at (that admission − 1) and opens the new one. That attribution is late if the new generation does not touch
a carried store for a while (the old range appears to run past the activation); it is harmless for correctness,
because writer ranges are not coverage, but readers must not treat them as coverage.

A replaced generation can never be activated again at its old address: its progress is stale, `build` refuses a
generation that has been live (`E_BUILD(1)`), and its fresh stores are attached (reason 13). Going back means
deploying the same code again as a new generation over the live stores (case (a)).

**Landed (step 2), tested as described** (`test/index/BuildWalk.t.sol`): publications land between build calls and
the builder catches up with more calls (`test_build_races_live_admissions_then_one_transaction`); a publication that
slips in before activation is refused `E_INDEX_NOT_READY(8)` with nothing changed, and coverage then reads PARTIAL
through the old frontier; build-until-caught-up and activation in one external call from the controller succeed (the
same test); and the transition route (`test_transition_route`): after `beginTransition`, an ordinary write reverts
`E_TRANSITION`, `build` still runs (it needs only `phase() == IDLE`, which a transition does not change; the stores'
writer rule reads `index()`, `phase()` and `counts()` only), and the activation ends the transition, after which writes
are admitted again. For a heal build both routes behave the same as for a re-pin: the carried store keeps the live
index's writes up to the activation, and the new generation's first live write to it closes the old range.

---

## 6. Cost

### 6.1 Unit prices (**measured**, step 4)

All figures of §6.1 and §6.2 are **measured** by `test/index/BuildGas.t.sol` (run on the default profile, prague, and
with `FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam FOUNDRY_GAS_LIMIT=100000000000`)
unless a row names another file. The Realm is the Files Realm of `TopicListsHistory` with generation 1 live; two building
generations are caught up before each measurement: **EX**, the example generation of step 3b (carries both genesis
stores, builds `head-authors` into a fresh third store: "add one list later"), and **FR**, generation 1's code over two
fresh stores (a full replay, the heal path, §6.4).

**How a call is made cold.** The publications to build are admitted live (generation 1), the state is snapshotted, and
every account a build touches is cooled with `vm.cool` (account and storage): the kernel's five contracts, the registry
and its implementation, the descriptor store, generation 1's index, reads and stores, the Files validator, the rule
instances, and both building generations with their reads contracts, decoders and stores. Then one `build(0, 65535)`
call is made with ample gas and read with `vm.lastFrameGas()`: `gasTotalUsed` is its gas (on amsterdam, execution gas
only: Foundry reports EIP-8037 state gas apart, as `gasStateUsed`, and the `gasleft()` delta around the call is their
sum plus the caller's CALL), and the state is reverted, so every kind is measured from the same state. **Derived by
difference:** the marginal publication of a kind is (C9 − C1)/8, C1 the cold call over one publication and C9 over nine
of the same kind, each on its own file; the call's fixed share is C1 − marginal. The marginal leaf of the kinds whose
leaves are all alike is the same over one publication of 1 and of 9 leaves. **The list's storage** is the same EX call
with the third store's `append`, `retain` and `release` answered by `vm.mockCall` (the CALL is still made; the store's
code and storage are not run), subtracted: so "list" below is the third store's write, code and storage, and "walk" is
the decode, the self-call, the fold and the CALL.

**EX, adding `head-authors` later, per marginal publication** (gas; amsterdam: execution gas, and the state gas apart):

| publication kind (leaves) | prague walk | prague list | prague total | amsterdam walk | amsterdam list | amsterdam total | amsterdam state gas |
|---|---:|---:|---:|---:|---:|---:|---:|
| create file, design §14 recipe (5) | 148,281 | 30,225 | 178,506 | 148,281 | 20,325 | 168,606 | 97,920 |
| edit: PUBLISH child + HEAD re-bind (2) | 91,484 | 0 | 91,484 | 91,484 | 0 | 91,484 | 0 |
| second author's own version (2) | 87,911 | 35,527 | 123,438 | 87,911 | 32,727 | 120,638 | 97,920 |
| HEAD mask of a BOUND head (1) | 61,389 | 12,238 | 73,627 | 61,389 | 19,438 | 80,827 | 0 |
| HEAD release of a BOUND head (1) | 61,405 | 12,238 | 73,643 | 61,405 | 19,438 | 80,843 | 0 |
| HEAD restore of a masked head (1) | 61,157 | 12,174 | 73,331 | 61,157 | 19,374 | 80,531 | 0 |
| first tag on a one-word topic (1) | 55,870 | 0 | 55,870 | 55,870 | 0 | 55,870 | 0 |
| folder move with a new name: PUBLISH name, RELEASE, BIND FOLDER (3) | 114,431 | 0 | 114,431 | 114,431 | 0 | 114,431 | 0 |
| plain publish of a name record (1) | 50,104 | 0 | 50,104 | 50,104 | 0 | 50,104 | 0 |

Re-measured at the final integration (the liveness gate's code, §10 item 39): every marginal publication, EX and FR,
is 22 gas dearer than step 4 measured (148,259 → 148,281 for a create file's walk), on both schedules; the per-leaf
figures below did not move.

The walk is the same on both schedules to the gas: it reads, and EIP-8037/8038 did not reprice what it reads here. The
list's first entry is one fresh slot (prague 30,225 with its code; amsterdam 20,325 of execution and 97,920 of state
gas); its counter is one rewrite of the list's head (prague 12,238; amsterdam 19,438: a cold rewrite costs 7,200 more
execution gas there). **The fixed share of a cold call** (C1 − marginal) is 252,738 to 281,227 on prague and 257,338 to
286,627 on amsterdam; a cold EX call with nothing pending costs 240,428 / 244,628 (its gates, the carried check, which
reads the generation's copy of the live index's manifest from code, checks it against the revision row's manifest hash
and decodes it, and the progress word). Step 4 measured 488,026 to 516,515 and 492,926 to 522,215, and 475,716 /
480,216 with nothing pending, when the carried check called the live index's `replayReadiness()`; reading the copy
saves about 235k a cold call. FR's fixed share is 91,690 to 181,914 (prague) and 95,290 to 297,079 (amsterdam); FR with
nothing pending 77,380 / 80,580 (it carries nothing, so it reads no copy; step 4: 91,588 to 181,812, 95,188 to 296,977,
77,278 / 80,478).

**Per leaf that touches nothing the list keeps** (the term of "a list on one purpose is dear to add to a long history";
marginal leaf inside one publication, EX, the same on both schedules): a first tag 29,860, a plain publish 24,155, a
CREATE 10,983. The same leaf as a publication of its own costs 55,870 (tag) and 50,104 (publish): about 26k of every
publication is its own decode (evidence cell, revision row, decoder and self-call). A HEAD mask leaf, which does touch
the list, is 47,612 (prague) / 54,812 (amsterdam), of which the walk is 35,374.

**What the estimate said (§6.1 before step 4):** decode ≈ 20,000 per publication, ≈ 12,000 per non-bind leaf, ≈ 20,000
per bind leaf; a new list's entry 27,139 / 115,156; a counter write ≈ 14,700 / ≈ 21,900. Measured, a publication's own
decode is about 26k, a non-bind leaf 11k to 24k, the walk of a whole create-file recipe 148,281 and of an edit 91,484 (148,259 and 91,462 at step 4);
the list's first entry 30,225 (prague) and 20,325 + 97,920 of state gas (amsterdam), its counter 12,238 / 19,438.

### 6.2 `head-authors` for a Realm of 1 million files (**measured** unit costs, the same assumed history)

Assumed history, unchanged from the estimate: 1,000,000 files, each created by a 5-leaf create-file publication (design
§14); 3 edits per file, each 2 leaves; 10% of files get a second author's own version (2 leaves); 6% of files see a
HEAD mask, release or restore of an asserted head (1 leaf; priced at the mean of the three). That is 4.16M publications
and 11.26M leaves. Priced from §6.1's marginal figures; the transactions are cold `build` calls of up to the 16,755,216
gas a 2^24 transaction leaves the call (21,000 base, 1,000 of calldata; on amsterdam the cap counts execution gas only,
state gas comes from the reservoir), each paying the fixed share of the create-file row once.

| part | count × measured unit | prague | amsterdam execution | amsterdam state gas | the estimate said (prague / amsterdam) |
|---|---|---:|---:|---:|---:|
| new lists (one per file) | 1.0M × 30,225 / 20,325 + 97,920 | 30.23B | 20.33B | 97.92B | 27.1B / 115.2B |
| second entries (word 0) | 0.1M × 35,527 / 32,727 + 97,920 | 3.55B | 3.27B | 9.79B | 2.7B / 11.5B |
| counter writes | 0.06M × 12,217 / 19,417 | 0.73B | 1.17B | 0 | 0.9B / 1.3B |
| walk of the create-file publications | 1.0M × 148,281 | 148.28B | 148.28B | 0 | (decode, three rows: |
| walk of the edits | 3.0M × 91,484 | 274.45B | 274.45B | 0 | 83B publications, |
| walk of the second authors' versions | 0.1M × 87,911 | 8.79B | 8.79B | 0 | 104B bind leaves, |
| walk of the HEAD transitions | 0.06M × 61,317 | 3.68B | 3.68B | 0 | 73B other leaves) |
| fixed share of each call | 28,513 × 281,227 / 27,930 × 286,627 | 8.02B | 8.01B | 0 | — |
| **total** | | **477.73B** | **467.97B** | **107.71B** | **≈ 290B / ≈ 390B** |
| transactions of 2^24 | | **28,513** | **27,930** | | ≈ 17,000 / ≈ 23,000 |
| per file | | **477,732** | **467,971** | **107,712** | ≈ 290k / ≈ 390k |

So on amsterdam the build costs 575.68B gas in all (575,683 per file), 467.97B of it execution. At 1 gwei that is 477.7
ETH on prague and 575.7 ETH on amsterdam. **What the manifest copy moved** (the final integration, §10 item 39): the
fixed share of a call fell from 516,515 / 522,215 to 281,227 / 286,627 (the carried check reads the copy from code
instead of calling the live index), and every walk rose by 22 gas; together the 1,000,000-file totals fell by 6.83B
on prague (484.56B in 28,920 transactions → 477.73B in 28,513) and 6.70B of execution on amsterdam (474.67B in 28,330
→ 467.97B in 27,930; 582.38B → 575.68B in all): 1.4% on prague, and on amsterdam 1.4% of the execution
and 1.2% of all gas. **Cross-check** (`::test_mixed_segment`): one cold EX
call over a segment of the mix (20 files: 20 recipes, 60 edits, 2 second authors' versions, a mask, a release and a
restore; 85 publications, 227 leaves) costs 9,652,927 on prague (9,440,327 + 2,154,240 of state gas on amsterdam; step
4: 9,886,345 and 9,674,045) and fits one call; the per-kind figures above add up to 9,807,864 for it (prague), 1.6%
more: the marginal figures do not grow over a call of 85 publications.

**The price of "add it later"** (per file, this history):

| | prague | amsterdam |
|---|---:|---:|
| kept from genesis (the list's live cost, measured cold) | 51,167 | 41,896 execution + 107,712 state = 149,608 |
| built later (EX) | 477,732 | 467,971 execution + 107,712 state = 575,683 |
| later against genesis | **9.3×** | **3.8×** in all gas (11.2× in execution gas) |
| what the estimate said | ≈ 31k kept, ≈ 290k later, 8× to 9× | ≈ 128k kept, ≈ 390k later, ≈ 3× |

Kept from genesis is the list's live price, measured cold by `test/index/HeadAuthorsFloor.t.sol` (`FloorBase._need`:
every account of the Realm cooled; E of the example generation minus E of generation 1 for the same shape from the same
state): a first HEAD statement (create file) 41,683 (prague) / 32,195 + 97,920 state (amsterdam), a second author's
first statement 46,554 / 44,154 + 97,920, a later statement (mask, release, restore) 22,925 to 23,100 / 30,525 to 30,712,
an edit's re-bind 1,149 / 1,149; weighted by the history above. The estimate's "kept" counted only the list's storage;
the measured live price also pays the CALL to the third store and its writer rule.

**What the measurement changes.** The walk, not the storage, is the price, and it is dearer than estimated: 435.20B of
the 477.73B on prague (91%), the same 435.20B on amsterdam. It is paid per publication and per leaf of the whole
history, whatever the list keeps: here the edits alone, which the list ignores (a re-bind changes nothing in it), cost
274.45B, more than half. The storage part is what keeping the list from genesis would have cost anyway, so "later" adds
the walk, paid by one operator at once.

**The rule this gives** (unchanged, with measured figures). Adding an on-chain list later is affordable for a small or
young Realm and not for a large one. For 10,000 files of this history: 4.78B gas in 286 transactions on prague (4.78 ETH
at 1 gwei); on amsterdam 4.68B of execution in 280 transactions plus 1.08B of state gas, 5.76B in all. For 1,000,000
files: 477.7B gas, 28,513 transactions (prague); 575.7B, 27,930 transactions (amsterdam). For a large Realm the realistic
route to a list nobody kept is an indexer, or a new Realm that keeps it from genesis.

**The third part of the price: the reservation a later list adds to every other statement** (step 3b, §10 item 27;
measured with the planning rule, `tools/gas-plan-later.mjs`, which runs `tools/gas-plan.mjs` unchanged on a copy of
`gas/model.json` whose `floor.workModel` is the example generation's, `HeadAuthorsGenesis.workModel`). The work model has
no per-purpose term, so the list's reservation (+10 fresh tenths on a first statement, +10 rewrite tenths on every bind
and on every later statement, +27,000 compute per bind-kind action) is charged on every TAG and FOLDER statement too.
The largest publication the planning rule plans, generation 1 → the example generation:

| shape | prague | amsterdam |
|---|---|---|
| lone negatives on a one-word topic | 38 → **32** | 50 → **42** |
| first tags, depth 8, everything new | 18 → 18 | 19 → 19 |
| first tags, depth 64, everything new | 3 → 3 | 3 → 3 |
| create-file recipes (5 actions each) | 10 → **9** | 12 → **11** (V at 11: 13.40M) |
| plain edits (PUBLISH files-child/1, HEAD re-bind; 2 actions each) | 24 → **23** | 23 → **21** |

The amsterdam column is the regenerated model's, with the Glamsterdam rewrite price (§10 item 29: 12,100, was 5,000);
at step 4, before that fix, it read 54 → 47, 19 → 19, 3 → 3, 12 → 12 (V 11.79M → 12.88M) and 30 → 28. The prague
column did not move. The first tags are limited by their own execution estimate (E, the per-level list cost), not by
the floor, so the reservation does not move them; the lone negatives lose 16% (prague) and 16% (amsterdam) of their
batch. The table is
the same with the list's own live execution added to E on HEAD statements (`LIST_LIVE` in the tool, the figures above),
because those shapes are bounded by V. The edits shape is planner arithmetic only (no FloorPlan test builds it); the
other four are FloorPlan's shapes. A per-purpose term in the ingress's quote (a formula change, replaceable until
freeze) would leave every non-HEAD shape at generation 1's batch.

**Cured by work-model formula 3 (2026-11-26, docs/WORK-MODEL-V3.md).** The example generation's model now puts the
list's reservation in the HEAD purpose surcharge (first +10 fresh, +10 rewrites, +27,000; re-bind nothing, since the list
does nothing on an edit; other later +10 rewrites, +27,000), so TAG and FOLDER statements are quoted exactly as
generation 1 quotes them (`test/index/HeadAuthorsFloor.t.sol`, `test_other_purposes_are_not_reserved_for_the_list`).
The same table under formula 3 (generation 1 → the example generation; the same with the list's E):

| shape | prague | amsterdam |
|---|---|---|
| lone negatives on a one-word topic | 38 → 38 | 53 → 53 |
| first tags, depth 8, everything new | 18 → 18 | 19 → 19 |
| first tags, depth 64, everything new | 3 → 3 | 3 → 3 |
| create-file recipes (5 actions each) | 10 → **9** | 12 → 12 |
| plain edits (PUBLISH files-child/1, HEAD re-bind; 2 actions each) | 24 → 24 | 28 → 28 |

Only the HEAD statements' own shape (create file, on prague) pays the list's reservation; the lone negatives keep their
batch.

### 6.3 Who pays

Whoever calls `build`. Nothing on chain repays it, and no user's write pays anything extra during a build. In
practice the Realm's operator pays, and should plan the build like a deployment: every list wanted goes into the
same generation, because one walk builds them all (§2.6). After activation every new file
pays the new list's live price through the new work model (a new manifest hash, so signed plans bound to the old
set are refused, QUESTIONS Q11).

### 6.4 A full replay, the heal path (**measured**, FR)

Per marginal publication (prague; amsterdam execution + state gas; re-measured at the final integration, each 22 gas
above step 4): create file 461,709; 371,771 + 893,520. Edit
243,346; 229,234 + 354,960. Second author's version 252,199; 202,849 + 489,600. HEAD mask 132,048; 143,848 + 97,920.
HEAD release 132,036; 143,836 + 97,920. HEAD restore 132,114; 151,114 + 97,920. First tag on a one-word topic 227,089;
172,726 + 538,560. Folder move with a new name 374,269; 335,432 + 599,760. Plain publish 85,364; 79,276 + 61,200. Per
leaf inside one publication: first tag 201,266; 146,903 + 538,560. Plain publish 59,446; 53,359 + 61,200. CREATE
10,877; 10,877. HEAD mask 106,118; 117,918 + 97,920. For the history of §6.2: 1,237.7B gas, 73,871 transactions, 1.24M
per file on prague; 1,108.2B of execution in 66,140 transactions plus 2,013.2B of state gas, 3.12M per file in all, on
amsterdam (step 4: 1,237.6B in 73,865, and 1,108.1B in 66,134). (The estimate said "about 110k per re-materialized posting on amsterdam".) A full replay re-materializes
every list at the fresh-slot price, so it costs 2.6× (prague) and 5.4× (amsterdam, all gas) a later list's build of the
same history.

---

## 7. What it changes

### 7.1 Replaceable until freeze (new code, no change to anything deployed)

- **The building generation** (generation 2). New immutables: one address per store (carried and fresh) and which
  families are built. New functions: `build(0, maxFacts)` with the semantics of §3.2–3.5, and `buildFold`
  (self-call only). `replayNextPublication` stays for case (e). `backfill` keeps reverting until a BITMAP family
  exists. New `E_BUILD` codes (provisional): 1 already live or activated, 2 a fresh store is not fresh, 3 not idle
  or in flight, 5 no decoder, 6 `maxFacts` below the next publication, 7 a carried family is not the live index's,
  8 nonzero `familyId`. **Landed (step 1):** 1, 3, 7 and 8 as listed, and a new 4, "the generation has a fresh store:
  the walk is not built yet", which step 2 removes; 2, 5 and 6 belong to the walk (step 2). `E_BUILD(0)` is gone.
  **Landed (step 2):** the codes are 1 live or activated; 2 a store names the generation as `INITIAL_WRITER` but a live
  write has attached it (the proposal's "a fresh store is not fresh", made exact: a store whose `INITIAL_WRITER` is
  another generation is carried, not refused, and fails the carried check instead); 3 not idle or a replay or build
  call of this generation in flight; 5 a fresh store and no decoder; 6 the next publication's leaf count exceeds
  `maxFacts` (nothing was folded in this call); 7 the carried check fails; 8 a nonzero `familyId`. **4 is removed and
  stays unused** (no code changes its meaning); no configuration is refused (§4.3), so no code was needed for one.
  `buildFold` was not added: `replayFold` is the self-call of both paths (§3.3). `IRealmIndex`'s ABI is not pinned by the kernel (the ledger calls only `onAdmission`,
  `afterPublication`, `replayReadiness` and `readsContract`), so this changes no kernel id. Its size is estimated at
  generation 1's 13,686 B plus 3–5 KB, under 24,576 B.
- **Its reads contract**: per-family store routing; coverage of built families PARTIAL until the frontier; the
  carried check inside `ready`.
- **A deployer** whose plan takes lists of carried and fresh stores (§3.1).
- **`LedgerControl`**: the two checks of §5.3. A new revision of the ledger implementation, not a layout change.
  **Landed (step 1):** 17,091 B → 17,674 B (budget 19,660); `RealmIndex` 16,582 B → 17,144 B; `IndexReads` 8,894 B →
  10,671 B. The deployer was not changed: its plan already expresses "carry both" and "carry one, create the other".

### 7.2 The stores

- **`PostingStore`: no change.** A fresh store for a later family can be today's code. `STORE_ABI_ID` stays
  `efs/posting-store/2`.
- **`BitmapStore`: one change, landed in this release.** `openCoverage` also accepts `MODE_BACKFILL` (the live
  generation while idle), so a pre-declaration scope gets its slot without waiting for a publication to touch it;
  this keeps the in-place route for `roster`, which the genesis store's lasting deployment would otherwise have
  closed. The ABI did not change, so the selector-derived `STORE_ABI_ID` would not have moved by itself; the tag is
  now `efs/bitmap-store/2` so the changed behavior is visible in the id, as was done for the posting store's step-3b
  amendment. The alternative, dropping the in-place route and adding every later BITMAP family through a fresh store
  (§2.3), is no longer needed.
- **The genesis `BitmapStore`'s family set** is fixed forever at deployment: `scope`, `roster`, `live-scope`
  (capacity 4). Only those can ever be BITMAP families in place. Decide before the first lasting deployment
  whether to reserve a fourth id; with route 3 of §2.3 available, this proposal reserves nothing more.

---

## 8. Tests that would prove it

Each runs on both fee profiles. **Landed (step 1),** in `test/index/Carried.t.sol` (default profile; the amsterdam
profile runs the same suite with the rest): test 5 in full; test 6 in full, plus a lying test double refused by the
kernel alone; of test 4, a publication between `build` and activation (`E_INDEX_NOT_READY(8)`, then built again) and
build-then-activate in one transaction (through a batching controller); of test 7, `build` after activation, from
inside a publication (a fold hook of the live generation), with a nonzero `familyId`, and on a generation with a
fresh store (`E_BUILD(4)`, step 1 only); of test 8, a fresh store already attached (`E_INDEX_NOT_READY(13)`) and an
unbuilt frontier (8). Also: a Realm with no admissions activates a carried generation over unwritten stores, with
or without `build`, and refuses one over a store its own `INITIAL_WRITER` wrote in build mode (`E_BUILD(7)`,
`E_INDEX_NOT_READY(12)`); genesis stores are unwritten.

**Landed (step 2),** in `test/index/BuildWalk.t.sol` (the Files Realm, the mixed history of
`test/integration/TopicListsHistory.sol`, which moves every counter of §4.2) and `test/index/BuildWalkRefusals.t.sol`
(the `Carried.t.sol` history, which has a WITHDRAW, with a twin Realm), both run on the default and the amsterdam
profiles: test 1 for generation 1's families with both stores fresh (`test_build_equals_replay_equals_live`: live,
replayed and built stores equal list by list, entry by entry, scope heads, entries and live words), and for each
store healed alone, compared with the live store before activation and with a twin that never switched after more
traffic, with the writer ranges (`test_heal_the_bitmap_store`, `test_heal_the_posting_store`,
`testHealEachStoreAgainstATwinRealm`); test 3 (`testFuzz_interrupted_build_equals_one_build`: per-call budgets of 64,
exactly the next publication, one below it, and random, over all three configurations; `test_budget_edges`); test 4
in full (`test_build_races_live_admissions_then_one_transaction`, `test_transition_route`); test 7 except the
stranger's generation naming a fresh store, which the generation itself refuses before any write (its carried check
fails, 7), so the store's own `E_WRITER` is shown by a write from that generation's address
(`testStoresRefuseEveryBuildWriteButTheirInitialWriters`, which also shows a candidate cannot write the store it
carries), plus `testBuildRefusals` (8, 3 from inside a publication, 6, 5, `E_REPLAY(1)` for a mixed generation, 1)
and `testAFreshStoreAttachedByALiveWriteRefusesTheBuild` (2, and the kernel's 13); test 8's frontier half
(`test_activation_refuses_an_unfinished_build`, coverage PARTIAL at that moment); test 12 for the configurations step 2
has (`testFoldHooksRunInAnAllFreshBuildOnlyAndCannotReenterIt`: fold hooks run in an all-fresh build exactly as in
replay and in no build that heals one store); and a preview of test 11 (`test_heaviest_publications_build_in_one_call`,
below). Tests 2, 9 and 10 need step 3 or a BITMAP family.

**Landed (step 3b),** with the example generation of §2.2 (a test harness), on the default and the amsterdam
profiles: test 1 for a new list (`test/index/HeadAuthorsBuild.t.sol::test_built_equals_live_every_family`: Realm B runs
generation 1, then builds the example generation carrying both genesis stores and activates it; Realm L runs the
example generation from genesis; every recorded key of every family in the three stores, heads and entries, scope
heads, entries and live words, `head-authors` included, is equal, before and after more traffic; the HEAD history has
a first bind, a re-bind, a second author's first bind, a third author's first mask (code 16 holds: the file exists), a
mask and a release of BOUND heads, two restores (one over a first mask), a mask of a masked head and a release of a
masked head, and the counters it moved are asserted); test 2 (`::test_head_authors_trace`, live and built); test 3 for
three stores (`::testFuzz_interrupted_build_equals_one_build`, three configurations, and
`::test_one_publication_per_call`); test 4 and test 8's frontier half for three stores
(`::test_build_races_and_switches_on`); test 7/8's store half for the third store (`::test_empty_realm_refuses_another_writers_third_store`,
`::test_admissions_refuse_another_writers_third_store`, `::test_a_third_store_the_live_index_never_named_is_refused`,
`::test_an_attached_third_store_refuses_the_build`); test 12 (`test/index/HeadAuthorsHooks.t.sol`); the dropped-list
test of §5.3 (`test/index/DroppedList.t.sol`); the example's work model against what its callbacks spend
(`test/index/HeadAuthorsFloor.t.sol`, §10 item 27); and the readers under partial coverage
(`test/readers/TopicPartialCoverage.t.sol`: every view of the three topic readers with each family it reads reported
UNKNOWN and then PARTIAL by a wrapped index). **Not in step 3b:** test 9 (case (d), a digest spec), test 10 (BITMAP
families) and test 11 (the measured gas of a build, step 4, done below).

**The readers under partial coverage (step 3b; the rule since 2026-11-26), per view.** A family is listed for a view
when reporting it UNKNOWN or PARTIAL changes the view's answer. Since the list-coverage rule of 2026-11-26
(docs/TAG-DESIGN.md §6, the page laws of `src/interfaces/Readers.sol`) PARTIAL is treated exactly as UNKNOWN: for
every listed pair the answer under either is UNKNOWN, no rows, coverage UNKNOWN, no counts, `frontier` 0 and no
continuation, and the two answers are identical; a listing resumed after a needed list turned PARTIAL is refused the
same way; no pair reverts. (Step 3b recorded the earlier behavior, a PRESENT page with the faithful rows and coverage
PARTIAL; the table of families is unchanged.)

| view | families it needs |
|---|---|
| `mine` exact | live-scope (the scope list's bits; `position-authors` is read only as a shortcut that falls back to the heads) |
| `mine` below | scope-below, live-scope |
| `everyone` exact | place, position-authors |
| `everyone` below | place, place-below, position-authors |
| `byName` | position-authors |
| `about` | role-places, position-authors |
| `placeCount` exact / below | place / place-below |
| `authorCount` | position-authors |
| `entryCount` exact / below | live-scope / scope-below |
| `wordPage`, `children` | place, place-below, reference-position |

An empty list at PARTIAL is UNKNOWN, never an empty PRESENT page (`::test_an_empty_list_at_partial_is_unknown_never_an_empty_page`).

**Test 11 (done, step 4: `test/index/BuildGas.t.sol`, both profiles).** The per-publication and per-leaf costs of a
build for every publication kind, for a list added later (EX) and a full replay (FR), are §6.1, §6.2 and §6.4. The
heaviest admitted publications (`floor-plan.json` k, generation 1's planning rule; the example generation's rule admits
fewer, §6.2), each admitted live and then built alone in one cold call (gas; amsterdam execution gas, + its state gas;
headroom under the 16,755,216 a 2^24 transaction leaves the call):

| publication | leaves (prague / amsterdam) | EX prague | EX amsterdam | FR prague | FR amsterdam |
|---|---:|---:|---:|---:|---:|
| lone negatives, largest admitted | 38 / 54 | 1,691,892 (15.06M left) | 2,223,641 (14.53M) | 7,199,069 (9.56M) | 7,897,298 + 23,500,800 (8.86M) |
| first tags, depth 8, largest admitted | 18 / 19 | 1,059,142 (15.70M) | 1,094,899 (15.66M) | 7,496,685 (9.26M) | 6,089,158 + 17,136,000 (10.67M) |
| first tags, depth 64, largest admitted | 3 / 3 | 605,152 (16.15M) | 610,052 (16.15M) | 9,770,262 (6.98M) | 7,078,562 + 26,536,320 (9.68M) |
| create-file recipes, largest admitted | 50 / 60 | 2,124,228 (14.63M) | 2,348,883 + 1,175,040 (14.41M) | 4,580,625 (12.17M) | 4,594,622 + 10,673,280 (12.16M) |
| 64 lone negatives | 64 / 64 | 2,557,616 (14.20M) | 2,562,516 (14.19M) | 12,416,008 (4.34M) | 9,462,308 + 27,809,280 (7.29M) |

On prague each call was also run with exactly 16,755,216 gas, and succeeded. Every row fits; leaf-granular resume is not
needed (§3.3, §9 q1). The step-2 preview (`BuildWalk.t.sol::test_heaviest_publications_build_in_one_call`, generation
1's code over fresh stores) measured the FR rows' shapes with the same method; it stays as it is.

1. **Built equals live, every family and counter.** Two Realms take the same mixed history: Realm L runs
   generation 2 from genesis (live); Realm B runs generation 1, then builds generation 2 and activates it. Compare
   every key of every family: head (`count`, `live`, `last`, `flags`) and every entry; scope heads (`count`,
   `live`, `lastMutation`, `liveBits0`) and entries. The history must move every counter of §4.2 (assert that it
   did, as `TopicListsReplay.t.sol:226-249` does), including same-target re-binds, first masks, restores over
   first masks, releases of masked heads and withdrawals. Then send more traffic to both and compare again.
2. **`head-authors` trace.** The §2.2 trace as a named test, live and built.
3. **Interrupted and resumed.** Build in many calls with small budgets, cut at every publication boundary
   (fuzzed); the result equals a single build.
4. **Racing live admissions.** Publications land between build calls; the builder catches up; activation in the
   same transaction as the last build call succeeds; activation after a publication slipped in reverts
   `E_INDEX_NOT_READY(8)`; the transition route succeeds while ordinary writes revert `E_TRANSITION`.
5. **Re-pin only (case a).** Generation 2 carries every store, `build(0, …)` moves its frontier to `counts()`,
   activation succeeds; its first live write folds into the carried stores and closes the old writer ranges.
6. **Abandoned carried store.** Generation 3 re-pins a store the live index no longer uses: the generation's
   readiness is not ready, and activation reverts `E_INDEX_NOT_READY(12)`.
7. **Refusals.** A builder that is not the fresh store's `INITIAL_WRITER` (a stranger's generation naming it) is
   refused `E_WRITER`; a build write into a carried store is refused `E_WRITER`; a build after activation, from
   inside a publication (fold-hook re-entry), with a nonzero `familyId`, or with a too-small budget is refused
   with its code; a fresh store attached by any live write ends the build.
8. **Activation refuses an unfinished build**: frontier below `counts()` (`E_INDEX_NOT_READY(8)`); a fresh store
   naming another `INITIAL_WRITER` or attached (`E_INDEX_NOT_READY(13)`).
9. **Digest spec (case d).** Family 15 rebuilt with old and new specs equals a Realm where both specs were live from
   genesis; `coverageOfSpec` reports PARTIAL during the build and COMPLETE after.
10. **CURRENT_STATE bitmap, mask before and after (case c, when built).** For `roster` in place after the
    `openCoverage` fix: an entry masked after declaration but before its backfill stays clear; an entry masked after
    its backfill is cleared by the live hook; a pre-declaration scope that no publication touches is backfilled to
    COMPLETE. For a fresh store built from history: the same two orders give the bits a genesis-live family gives.
11. **Gas.** Measure the build per publication and per leaf on both schedules (this replaces §6's estimates), and
    the heaviest admitted publication (64 deep first tags; 64 lone negatives) replayed within 2^24. **Done (step 4).**
12. **Fold hooks** of carried units are not called during a build; a new unit's fold hook is.

---

## 9. Open questions for the reviewers

1. **Step size.** Publication-granular steps with `maxFacts` as a leaf budget, or leaf-granular resume?
   *Recommend publication-granular; add leaf resume only if test 11 shows one publication's build over 2^24.*
2. **One walk or one per family.** *Recommend one walk for all built families (`familyId == 0`): decoding
   dominates the cost (§6.2), so walking twice doubles it.*
3. **Closing the gap.** Batch transaction, transition, or a new controller entry point that builds and activates?
   *Recommend no new entry point: batch for quiet Realms, transition for busy ones (§5.4).*
4. **Kernel checks of §5.3.** In `LedgerControl`, or only in the generation? *Recommend both, landed before freeze
   (and in the terminal implementation if posture B is chosen).*
5. **`openCoverage` in backfill mode.** Fix the genesis `BitmapStore` before the first lasting deployment, or drop
   in-place BITMAP backfill from the design? *Fixed: landed in this release (`efs/bitmap-store/2`). One line, and it
   is the only cheap route for `roster`.*
6. **Reserved BITMAP ids.** Reserve a fourth family id in the genesis `BitmapStore`? *Recommend no; route 3 of
   §2.3 covers later families.*
7. **A filtered decoder** that skips leaves a build does not need. *Recommend not in the first build; later, only
   with a differential test against the generic decoder over a large mixed history.*
8. **Family id for a changed recipe** (case d). Keep `digest` with a new recipe hash, or a new id? *Recommend keep
   the id; the manifest hash and `coverageOfSpec` already say which specs are covered.*
9. **After freeze.** A build needs an activation, which freeze ends (design §8.10). Under posture B the steward may
   activate only "a replayed index generation". Should that include a built one? *Recommend yes if posture B is
   chosen; it is the same readiness.* Decide with QUESTIONS Q3.
10. **`retireCoverage` stamps the frontier**, not the folded admission, in build mode. *Recommend that no build
    path call it; if one ever must, give it an admission argument (an ABI change).*
11. **Building HEADS counters from current state** (the binding table and current heads) instead of walking every
    admission. Cheaper for some families, but it is a second derivation with its own proof. *Recommend not for the
    first build.*
12. **Who funds a large build.** *Recommend the operator; record the measured cost (test 11) in the release notes so
    "we can add it later" comes with a price. **Recorded (step 4):** §6 and tools/RELEASE.md item 36.

---

## 10. Where steps 1 and 2 differ from this proposal, and what the proposal had wrong

1. **Readiness of a failed carried check.** §3.5 says readiness reports `completedAdmission = lastProcessed` and is
   ready only if the check passes. The code reports 0 for both `completedAdmission` and `completedPublication` when
   the check fails. The kernel trusts `completedAdmission` and ignores `ready` (§5.2), so a tuple that kept the
   frontier would claim, to the one reader that acts on it, that the carried families are complete.
2. **The order of the kernel's checks.** The exact catch-up check (`E_INDEX_NOT_READY(8)`) moved after the loop
   over families, so an abandoned carried store is reported as 12 (it can never be fixed by building) rather than as
   8 (behind). §8 test 6 expects 12 for an honest generation 3, whose frontier can never move; with the old order it
   would have been 8.
3. **Where the generation's check lives.** In the reads contract (`IndexReads.carriedCheck`), which holds the family
   table, not in `RealmIndex`, which holds only its two store addresses. Both are the generation's own code and are
   redeployed together, so a re-pin of generation 1's code (case (a)) carries the check.
4. **A genesis store's first writer range starts at its first write, not at 1.** A live write opens a range at the
   admission that makes it (`StoreBase._attach`), so generation 1's posting range starts at the first admission that
   writes the store (2 in the test history, whose admission 1 is a CREATE) and its bitmap range at the first bind.
   §5.4's "closes the old index's range at (that admission − 1)" is exact.
5. **`E_BUILD(4)`** is new: "a fresh store, the walk is not built yet". It exists only until step 2.
6. **The proposal's size figure was stale.** §7.1 estimates generation 2 from "generation 1's 13,686 B"; generation
   1's `RealmIndex` was 16,582 B at `0fb4804` and is 17,144 B after step 1.
7. **Not done in step 1, though §1.4 item 6 names it:** the kernel still does not check that a store's last writer
   range belongs to the live index. Check 12 makes that unnecessary for carried families (it asks the live index's
   manifest, which is stronger), and check 13 covers fresh stores.
8. **The zero-admission residual is closed.** The first version of step 1 let both checks pass anything on an empty
   Realm, so a store that its own `INITIAL_WRITER` (code nobody pinned) had written in `MODE_BUILD` could be carried
   into the first live generation. Now, with no admissions, every store must have an empty writers list, in the
   generation's check and in the kernel's reason 12. That is the base case of the invariant of §5.3; checks 12 and
   13 are its step. The simple form ("every store", not only "every carried store") held: no honest path writes a
   store on an empty Realm.

### Where step 2 differs from the proposal, and what the proposal had wrong

9. **No `buildFold`.** §3.3 and §7.1 name a new self-call `buildFold`. The code reuses `replayFold`: both paths
   decode with the pinned decoder and call it through `_replayOne`, with the carried mask as one trailing calldata word
   (the ABI decoder ignores it; only the generation can call `replayFold`). One fold entry point, no new selector.
10. **The bind fold is split into its two stores' halves** (`_foldScope` for the bitmap store, the rest of
    `_foldBind` for the posting store), and the live path runs the split code too. Before, the two stores' calls
    were interleaved within one effect. The reorder is exact (different stores; neither half reads the other's
    store, §4.3), and every existing suite passes unchanged (the index suites on both profiles); the measured
    publication gas rows moved (tools/RELEASE.md item 27).
11. **`E_BUILD(2)` means "attached under this generation's name", not "a fresh store is not fresh".** A store naming
    another `INITIAL_WRITER` is simply carried and answers to the carried check (7). Only a store naming this
    generation and attached is neither; the generation refuses it as the kernel does (13), in `build` (2), in the
    carried check (so readiness claims nothing) and in coverage.
12. **§4.3's table was incomplete** (the withdrawal's by-record read, every store-internal read, the writer rule,
    most decoder reads); the full table is there, and it shows both mixed configurations are exact.
13. **"A fresh store attached by any live write ends the build" (§8 test 7).** Under the kernel's checks a
    generation's fresh store is attached by a live write only after the generation itself was activated over it:
    the empty-Realm route (another index carrying it) is closed by the `INITIAL_WRITER` rule (§5.3). What remains is
    a generation activated and replaced before any admission reached it; the test takes that route and shows the
    generation (2) and the kernel (13) refusing it once its successor's first live write attached the stores.
14. **The stranger's builder** (§8 test 7: "a builder that is not the fresh store's `INITIAL_WRITER` … is refused
    `E_WRITER`"): a stranger generation that names a fresh store of another generation treats it as carried, and its
    carried check fails (7) before it writes anything, so the store's `E_WRITER` is never reached through `build`. The
    store's refusal is shown by a write from that generation's address.
15. **Coverage applies the carried check** (§3.5 said step 3 should): a carried family of a generation that has
    never folded live reports PARTIAL (1, 0) when the check fails. The first version asked the ledger `index()` on
    every coverage read, which made the live index's reads dearer and moved the readers' bounds; the check now keys
    on the generation's own `liveStarted`, read in the call coverage already made (`generationProgress()`, a new
    getter on `RealmIndex`, not in a consumer interface), so a generation that has folded live answers exactly as
    before step 2. A replaced generation answers from its stale frontier, as it did before.
18. **The empty-Realm rule gained `INITIAL_WRITER`** (§5.3): reason 12 and the carried check also refuse, on a Realm
    with no admissions, a store whose `INITIAL_WRITER` is neither 0 nor the candidate.
16. **Fold hooks.** As §3.6 proposes, with the gap it leaves made explicit: a generation-1-shaped generation cannot
    tell a carried unit from a new one, so a build that heals one store calls no fold hook at all; an all-fresh build
    calls them as replay does.
17. **Sizes.** `RealmIndex` 17,144 B → 18,244 B (budget 19,660; the proposal's estimate of 3–5 KB more was for a
    generation with per-family store routing, which is step 3); `IndexReads` 11,127 B → 11,556 B; `LedgerControl`
    17,687 B → 17,830 B. **`RealmIndex` has 1,416 B left under the budget.** One more list in a third store costs a
    fold and a store address, and the budget is the project's, below the protocol's 24,576 B. But a real later
    generation that keeps every generation-1 list and adds several more in the same contract needs room made first
    (for example by moving fold code it no longer needs out, or by raising the budget on purpose): plan that
    before promising the lists.

**Pre-freeze gate: activation must not depend on the live index answering. DONE (2026-11-26, branch
`fable/2026-11-26-liveness`, items 34–38 below).** Check 12 and the generation's carried check read the live index's
`replayReadiness().families` at run time; if that read reverted, the kernel's activation reverted with the live index's
own error and the generation's check failed, so only a full replay could replace a broken index. Shown on the tree
before the change (`git archive 4003069`, the scenario of `test/index/Liveness.t.sol` test 1 with no copy): `build`
reverted `E_BUILD(7)` and the activation reverted `BreakableReads.E_BROKEN()`, the live index's error. Now the candidate
carries a copy of the live index's manifest preimage, the kernel and the generation check it against the
`indexManifestHash` the kernel recorded and read the families (and, for Option A, the units) from it, and neither calls
the live index (§3.5, §5.3). The same scenario builds, is ready, activates and folds the next publications live, every
list equal to a twin Realm's, both when the live index's readiness reverts and when every call to its address reverts.
A stale copy (the live index replaced after the candidate was deployed) is refused, and the candidate is redeployed with
a fresh copy. The storage form chosen is code (item 34).

### Step 3a: the as-of rule (2026-11-26, branch `fable/2026-11-26-index-build-3a`)

19. **What changed.** The rule of §4.3 ("a fold from history reads every fact as of the admission it folds; a
    validator's law is never a source of facts for a build") and its one fix. `RealmIndex._fromHistory()` is true
    exactly when the fold runs inside `replayFold` (`msg.sig`), which is the only path of every replay and every
    build (both stores fresh, either store healed: `_replayOne` calls it on this contract, and nothing else can,
    `E_WRITER`); the live fold runs inside `onAdmission`. On the history path `_walk` first reads the subject's
    level in one batch of three words (`_parentAsOf`: the Type word, body word 0 and cell word 1, the first
    admission) and continues from the subject's parent only when the subject is a `topic/1` record first admitted at
    a nonzero admission strictly below the statement's; otherwise it files no roll-up. The ancestors' levels then
    read as before. Nothing else in the fold changed. The comments on `_walk`, the constructor, `_foldMore` and
    `IndexProfiles.requireTopicUnit` no longer say the validator makes a build exact: `requireTopicUnit` stays,
    because the law still decides what the LIVE lists mean (a live tag under an unregistered topic would be filed
    with no roll-up), not whether a build is exact.
    *Why the selector and not a bit in the mask word.* The first version carried a `HISTORY` bit in the carried
    mask from `_replayOne` through `replayFold`, `_fold`, `_foldBind` and `_firstStatementLists` to `_walk`.
    Measured on the live path (prague, one publication each, against `26fce43`): +29 to +44 gas on every bind-kind
    action (the extra argument through `_foldBind`) and +255 to +287 per first tag (a run-time length for the walk's
    slot array). The selector test costs the live path one comparison in `_walk` and nothing anywhere else, so it
    replaced the bit before any regeneration. A later generation's `_foldMore` uses the same `_fromHistory()`.
20. **Why history only.** Live, the kernel's per-leaf loop (`LedgerCore._applyOne`: validate, apply the leaf, raise
    `counters.admissions`, `_notifyIndex`, `_recheck`, then the next leaf) means the fold of a leaf reads exactly the
    state of all lower admissions: a record registered by an earlier leaf of the same publication is there, one
    registered by a later leaf is not. A BIND-kind leaf registers no record, so "first admission strictly below the
    statement's" is precisely the set of records the live fold can see. The comparison is therefore always true live
    and costs nothing to skip; from history it is what makes the read as-of.
21. **Why ancestors need no comparison.** The kernel's reference law: `LedgerIngress.validateLeaf` →
    `_validateRecord` → `_resolveRefs` refuses a record whose declared reference i (body word i) is not a record
    (`E_REF(leaf, i, 1)`), and runs before the leaf is applied, so a `topic/1` record's parent (body word 0, a
    declared reference of `topic/1`) was first admitted strictly before it. This is the kernel's law for every
    Type with declared references, not a validator's. Record cells and bodies are written once (`LedgerApply._applyRecord`
    writes the cell only while its Type word is 0, `_storeBody` once), so from a subject first admitted below the
    statement every level of the walk reads what the live fold read.
22. **Costs (measured, prague).** *History path:* the subject's level reads one more word (its cell word 1) in the
    batch it already made: a cold `SLOAD` (2,100) for the first statement on a subject in the call, warm (100) after,
    plus the three-word batch's memory. Measured by `BuildWalk.t.sol::test_heaviest_publications_build_in_one_call`
    (one cold `build` call each) against `26fce43`: per first tag +1,547 (38 lone negatives on one word, 7,183,117 →
    7,241,906), +1,588 (64 lone negatives), +1,704 (18 first tags on a depth-8 topic, 7,466,008 → 7,496,688), +2,319
    (3 on a depth-64 topic, 9,763,308 → 9,770,265); every admitted shape still builds in one call far under 2^24. The
    two shapes that cannot be admitted rose by +2,160 and +6,988 per tag (64 first tags at depth 8 and 64: memory
    expansion in a call that already holds tens of thousands of words). *Live path:* `gas/model.json` against
    `26fce43`, every constant on both schedules: `bindTagFresh` +61, `bindTagSecondAuthor` +73 (prague) / +61
    (amsterdam), `unbindTagLone` +61 (the three rows whose action reaches the walk: a TAG first statement); every
    other constant that moved, moved by exactly ±12 (prague: `files-name/2` publish −12, `bindHeadFresh`,
    `bindHeadRebind`, `bindFolderRebind`, `bindTagNumberChange`, `restoreTag` +12, `bindPropertyFresh`,
    `bindPropertyRebind` −12; amsterdam: `bindFolderFreshFile`, `bindFolderFreshDirectory` +12, `restoreBroader` −12),
    and none of these reach `_walk`, so the ±12 is via-IR code placement (the same ±12 the anchor rows show between
    any two builds), not the rule; `fixed` (315,834 / 899,154), `tagLevel`, every read row, bound and recommended limit,
    and every floor-plan `k` are unchanged; max error 5.80% / 7.56%, as before. The +61 per first tag is the flag
    test (`msg.sig` loaded, compared, a jump) and the code around it in `_walk`. *Size:* `RealmIndex` 18,244 B → 18,705 B
    (+461; budget 19,660 B, 955 B left); no other contract's code changed (`IndexProfiles` changed comments only).
23. **How the live path is shown unchanged.** (i) Every existing live suite and snapshot passes untouched: no test,
    ABI snapshot or vector other than the new suite changed (`FilesFixture._units` became `virtual`, a test harness
    change with no effect on any other suite). (ii) `test/index/BuildAsOf.t.sol::test_the_live_fold_never_reads_the_first_admission`
    records the ledger's storage reads during a live first tag on Realm V and fails if the subject's cell word 1 is
    read; the same test shows a build of the same tag reads it exactly once. (iii) The gas model's live rows (item 22): only the three rows whose action reaches the walk moved by more than the ±12 of code placement, by +61.

### Step 3b: a new list in a third store, as a test harness (2026-11-26, branch `fable/2026-11-26-index-build-3b`)

24. **What changed in `src/`: extension points only.** `RealmIndex`: `_foldPublication` passes the carried mask to
    `_foldHooks`, which runs a unit's fold hook when the new `_hookRuns(unit, carried)` (internal virtual, default
    `carried == 0`, the old rule) says so; `RealmIndex` 18,705 B → 18,692 B (−13; budget 19,660 B). `IndexReads`: the
    family table (`_families`, `_familyAt`) and `_declare` are internal, `_carriedCheck` is internal virtual, its helpers
    `_unwritten`, `_storeOf` and `_declaresFromOne` are internal, and the two posting reads that took `POSTING` take
    `_postingOf(pos)` (internal virtual, default `POSTING`); its runtime is byte-identical to `5dfb146` (11,556 B). No
    other contract changed, the kernel included: checks 9 to 13 already run per family and per store. Live gas
    (`gas/model.json` against `5dfb146`): every constant moved by −24 to +51 on both schedules (most per-action
    constants +39 on prague), multi-leaf rows by up to +429; the only new live work is the carried mask passed to the
    hook loop (generation 1 pins no fold hook, so `_hookRuns` is never reached live), the rest is code placement;
    reads, tag terms, bounds and every floor-plan `k` are unchanged (tools/RELEASE.md item 34).
25. **The harness** (`test/harness/HeadAuthors.sol`, all EXAMPLES): `HeadAuthorsReads` (`IndexReads` plus
    `head-authors` in `extra[0]`, per-family routing, a three-store carried check, `NEW_UNITS_FROM`),
    `HeadAuthorsIndex` (`RealmIndex` plus the §2.2 fold in `_foldMore`, a third carried bit `CARRIED_THIRD = 4` in
    `_carried`/`_allCarried`, the third store in `_spoiled`, and `_hookRuns` for new units), `ListIndexDeployer` (a
    plan that is a list of carried and fresh stores), `HeadAuthorsGenesis` (the example at a Realm's genesis, three
    stores with `INITIAL_WRITER` 0), `CreatorsReads`/`CreatorsIndex` (§5.3's G and H: list X on CREATE in the posting
    store, deployed by the production `IndexDeployer`) and `RecordingFoldHook`. `FilesFixture._gen1` and
    `FloorBase._coolRealm` became `virtual` (test harness changes with no effect on any other suite).
26. **Differences from the proposal.** (a) No new `E_BUILD` code and no change to `build`: the third store is one more
    carried bit, fresh and carried are judged as for the two genesis stores. (b) The deployer is a harness, not product
    (§3.1). (c) The new list's universe is 3 (SCOPE, as family 20), its semantics HEADS. (d) Fold hooks: built for new
    units through `_hookRuns`, with the generation's own list of new units (`NEW_UNITS_FROM`) instead of a `Unit` field;
    a generation that carries every store still builds no hook (§3.6, a gap). (e) The rule for a unit's fold hook and
    history is now written (§3.6, rule (i)). (f) The kernel was not changed and needed no change for three stores.
    (g) §8's reader test: the readers answer PARTIAL as a PRESENT page that states its coverage, as
    `src/interfaces/Readers.sol` specifies, not as UNKNOWN; "UNKNOWN with no rows" holds for UNKNOWN only. No reader was
    changed. (Superseded 2026-11-26: the list-coverage rule treats PARTIAL exactly as UNKNOWN, docs/TAG-DESIGN.md §6;
    the three topic readers changed for it.) (h) Not in this step: case (d), BITMAP families, the measured gas of a build (step 4).
27. **The work model (§6.3).** The model has no per-purpose term, so the new list's price is charged on every
    bind-kind action: `freshPerBindFresh` +10 (one fresh slot on a first statement: the list's head, or its word 0),
    `rwPerBind` +10 (the head rewritten by a later author's first statement), `rwPerBindLater` +10 (the counter on a
    restore, mask or release) and `computePerHookEffect` +27,000 (the CALL to the third store, cold on a publication's
    first HEAD statement, and its writer rule), set from `test/index/HeadAuthorsFloor.t.sol`. How the floor uses it:
    the ingress quotes `prefixFloor = compute + ⌈fresh10/10⌉·floorFreshGas + ⌈rw10/10⌉·floorRewriteGas` from the live
    index's `workModel()` and the author's heads, and before each callback the kernel requires that much (less what the
    callbacks have spent) to be available (design §10.4); a floor that is too low lets a callback run out of gas, so
    honest means the quote covers the callbacks' prefix spend (E − K − the final phase). Measured, the list costs a
    first HEAD statement 41.6k (a new list) to 46.5k (a second author's word 0) on prague, 37.8k warm in a batch, and
    32.1k to 44.1k on amsterdam (execution gas; the fresh slot's state gas is outside the cap); a later statement 22.9k
    to 23.1k (prague) and 30.5k to 30.6k (amsterdam); a re-bind 1.1k. Each increment of the model covers that on both
    schedules (a first statement is quoted 54.1k / 44.1k more, a later one 37k more), and the example's prefix quote
    covers its spend for every HEAD shape measured (create file, a second author's version, a third author's first
    mask, a mask, a release and a restore of a head, an edit, 32 second-author first masks), with every V within a 2^24
    transaction and, on prague, each publication admitted with exactly V. With generation 1's model the same example
    under-quotes a create-file recipe on amsterdam (0.91×), so the list needs its own terms. The price of the
    over-quote: every TAG and FOLDER statement is quoted 37k to 54k more than it spends for the list, which shrinks
    the planning rule's largest batches of those shapes for such a generation (not measured here: `FloorPlan.t.sol`
    plans generation 1). A real generation that adds a HEAD list would want a per-purpose term (a formula change in the
    ingress, replaceable until freeze) or accept that. Observed in passing, reconciled in step 4 (item 29, item 32): in this
    suite's state generation 1's own model quotes a create-file recipe at 0.97× its prefix spend on amsterdam (and
    1.43× on prague, not 1.10× as first written); design §10.4's about 1.1× is the state of a first file in a folder.
28. **Preview figures (warm, within one test transaction; step 4 measures cold).** The build of the example
    generation over the history of test 1 (53 publications, 92 admissions; the walk folds only `head-authors`, the two
    genesis stores are carried): prague 4,874,870 gas in 2 calls (budget 64), 91,978 per publication, 52,987 per leaf; amsterdam 5,415,290 gas in 2 calls, 102,175 per publication,
    58,861 per leaf (Foundry's amsterdam profile draws state gas from the call, so these include it).

### Step 4: the measured gas of a build (2026-11-26, branch `fable/2026-11-26-index-build-4`)

29. **FIXED IN THIS RELEASE (the Glamsterdam floor price, tools/RELEASE.md item 39): on amsterdam, generation 1's
    prefix quote was below a create-file recipe's callback spend in a folder where the author already has files
    (0.969×); with `floorRewriteGas` 12,100 it is 1.259×.** The finding as step 4 measured it, then the after figures.
    Measured by
    `test/integration/FloorReconcile.t.sol` (FloorBase's method on both profiles: cold, every Realm account cooled;
    spend = E − K − the final phase, split per leaf by mocking the callbacks of leaves ≥ i):

    | state | prague P / spend | amsterdam P / spend | index slots written |
    |---|---:|---:|---|
    | A: FloorPlan's state, the author's first file in the folder (1 recipe) | 610,600 / 552,842 = 1.104 | 450,600 / 407,140 = 1.106 | 17 fresh, 3 rewritten |
    | A: the planned batch (10 / 12 recipes) | 4,761,500 / 3,718,143 = 1.280 | 4,205,000 / 3,346,113 = 1.256 | 98 / 120 fresh, 3 rewritten |
    | B: HeadAuthorsFloor's state, the author has two files in the folder (1 recipe) | 610,600 / 410,534 = 1.487 | **450,600 / 464,766 = 0.969** | 7 fresh, 17 rewritten |

    Both figures are right: design §10.4's "about 1.1×" is state A (IndexFloor's and FloorPlan's), step 3b's 0.97× is
    state B (`HeadAuthorsFloorGen1Test`, the same E, 1,304,106). Not warm against cold (both cold), not a different
    definition (both E − K − final phase, the same kernel check), not a different fixture code: a different STATE. The
    quote is the same for every create-file recipe (it prices each bind as a first statement on new lists: 16 fresh
    slots at `floorFreshGas`, 19 rewrites at `floorRewriteGas`), while what the callbacks write depends on whether the
    lists exist. On prague a fresh slot (22,100) costs 4.4 rewrites, so a folder with entries is cheaper and the ratio
    rises (1.49×). On amsterdam a cold rewrite costs about 12,100 execution gas (EIP-8038; measured here as the list
    counter's rewrite, 12,238 on prague and 19,438 on amsterdam, §6.1) and the Realm's `floorRewriteGas` is 5,000 on both
    schedules (`tools/deploy-plan.mjs` `GLAMSTERDAM_FLOOR`; `test/harness/KernelDeploy.sol`, whose comment "a rewrite
    stays 5,000: measured" was measured on first-statement shapes, which rewrite little). So writing into existing lists
    is not cheaper in execution there, and B's 17 rewrites are each quoted ~7k short: per leaf, B's PUBLISH of the root
    spends 110,238 against A's 85,180 and the name record 77,338 against 52,178 (appending to existing by-type,
    by-author and reference lists). **The term that is short: `limits.floorRewriteGas` on a Glamsterdam Realm (5,000
    against about 12,100).** Shortfall in B: 14,166 gas (3.1%).

    **What it can and cannot do.** The kernel checks, before each prefix callback, that (gasleft − F − T)·63/64 at the
    kernel and 63/64 of that at the ingress is at least the remaining quote (P less what the earlier callbacks spent,
    never below 0), then calls the index with all of it; the final phase checks F the same way. Every callback failure
    reverts the whole publication: empty returndata (out of gas) is `E_INDEX_GAS(quoted, available)` from `_ack`
    (`LedgerIngress.sol`), any other failure `E_INDEX_CALL` / `E_INDEX_ACK` / `E_INDEX_RETURNDATA`; the final call is a
    `STATICCALL` acknowledged the same way; a unit's fold hook runs inside `onAdmission` and a final hook inside
    `afterPublication`, both plain Solidity calls whose failure bubbles (`RealmIndex._foldHooks`, `afterPublication`);
    nothing on the live path catches a failure. So **a quote below the spend can never let a publication land
    unindexed**; it only weakens the early check (the last callback of B is checked against a remaining quote of 0, so
    it can run out after every check passed, and is then refused `E_INDEX_GAS`, consuming nothing). Tests:
    `FloorReconcile.t.sol::test_a_callback_that_runs_out_admits_nothing` (every gas from 2,000 below the least that
    admits a recipe: refused, nothing admitted; on prague 40 of 40 refusals are the early check, on amsterdam 40 of 40
    come after every check passed, in both states), `BurningFoldHookTest` and `BurningFinalHookTest` (a unit's fold hook
    or final hook that runs out: `E_INDEX_GAS`, nothing admitted, at 3M to 200M gas), and the kernel doubles of
    `test/integration/atomicity/Ordered.t.sol` (§7: burning, writing and malformed callbacks).

    **With the planned gas** (`FloorReconcile.t.sol::test_planned_gas_admits_create_files`; plan = max(E, V), the
    model's for the planned batch, from the measured E and K and the kernel's quote for one recipe; "least" = the least
    execution gas that admits it, to 1 gas):

    | shape | prague: plan − least | amsterdam: plan + state gas − least | amsterdam with the headroom (plan / 0.85 + state) |
    |---|---:|---:|---|
    | A, 10 / 12 recipes (the planned batch) | +236,188 | +177,803 | admitted |
    | A, 1 recipe | +45,404 (model plan: +50,593) | **−24,277** (model plan: −19,488) | admitted |
    | B, 10 / 12 recipes | +230,859 | +188,693 | admitted |
    | B, 1 recipe | +41,534 (model plan: +46,723) | **−14,144** (model plan: −55,522) | admitted |

    On prague the plan covers every shape with no headroom (the tightest: one recipe in B, 41,534 to spare). On
    amsterdam the plan is execution gas only and the transaction also carries the state gas; Foundry draws it from the
    same gas, which is the chain's rule for a transaction of at most 2^24 (no reservoir), and harsher than the chain for
    the 12-recipe batch (58M with its state gas; on chain the reservoir pays state gas first). One recipe sent with
    exactly the plan and its state gas is refused in BOTH states, so the cause is not the quote (A's quote covers the
    spend): it is the callbacks' state gas (17 and 7 fresh index slots, 97,920 each) drawn from regular gas through the
    two 63/64 steps and past the F + T the kernel holds back, which V (an execution-gas figure) does not count; in B the
    model's E also under-estimates the shape (model 1,165,959, measured 1,304,766, +11.9%, beyond the model's stated
    7.56% maximum error, which is over its fitted rows). With the 15% headroom every shape is admitted, and no largest
    planned batch has to shrink. The planning rule already says the gas limit comes from `eth_estimateGas`, never from
    V; a consumer that sends max(E, V) as the gas limit on amsterdam fails every write by the whole state gas.
    **Fixed in this release.** A Glamsterdam Realm's `floorRewriteGas` is 12,100 (`tools/deploy-plan.mjs`
    `GAS_SCHEDULES`, the one table; `KernelDeploy.s1Limits()` under the amsterdam profile; `profiles.amsterdam.floor
    .limits` in `gas/model.json`); the work model's rewrite tenths are unchanged. After the fix (the same suite, the
    regenerated floor-plan vectors; prague did not move):

    | state | prague P / spend | amsterdam P / spend (was) |
    |---|---:|---:|
    | A, 1 recipe | 610,600 / 552,952 = 1.104 | 585,500 / 407,284 = 1.437 (1.106) |
    | A, the planned batch (10 / 12 recipes) | 4,761,500 / 3,719,243 = 1.280 | 5,681,800 / 3,347,637 = 1.697 (1.256) |
    | B, 1 recipe | 610,600 / 410,644 = 1.486 | 585,500 / 464,876 = **1.259** (0.969) |

    | shape | prague: plan − least | amsterdam: plan + state gas − least (was) | exactly plan (+ state) |
    |---|---:|---:|---|
    | A, 10 / 12 recipes | +236,215 | +1,700,376 (+177,803) | admitted |
    | A, 1 recipe | +45,393 | **+114,791** (−24,277) | admitted (was refused on amsterdam) |
    | B, 10 / 12 recipes | +230,887 | +1,711,299 (+188,693) | admitted |
    | B, 1 recipe | +41,524 | **+78,791** (−14,144) | admitted (was refused on amsterdam) |

    So one recipe sent with exactly the plan and its state gas is now admitted on amsterdam in both states, and the
    suite asserts P / spend ≥ 1 in all three states and admission at exactly the plan in state A on both schedules
    (`FloorStates.t.sol` asserts P / spend ≥ 1 over every shape the floor claims). The sweep below the least is
    unchanged in kind: every gas from 2,000 below the least is refused and nothing is admitted; on prague 40 of 40
    refusals are the early check, on amsterdam 40 of 40 come after every check passed, in both states. The planning
    rule still takes the gas limit from `eth_estimateGas`, never from V; the cost of the fix is in the batch sizes
    (tools/RELEASE.md item 39, docs/TAG-NUMBERS.md) and in the over-reservation of later statements (item 41).
30. **What changed.** No `src/` file and no release file. New: `test/index/BuildGas.t.sol` (the measurement suite of
    §6 and §8 test 11, with upper bands on every per-publication and per-leaf figure, about 25% over the measured
    values), `test/integration/FloorReconcile.t.sol` (item 29) and `tools/gas-plan-later.mjs` (the planning rule on the
    example generation's work model, §6.2; no gate runs it, and it changes nothing the gates compute).
31. **What the estimate had wrong** (§6.1, §6.2). The decode is dearer: about 26k of every publication and 11k to 24k
    per leaf (estimated 20k and 12k to 20k), so the walk is 435.11B of a 1M-file build (estimated 260B) and a later
    list costs 484,560 per file on prague (estimated 290k) and 582,381 on amsterdam in all gas (estimated 390k); kept
    from genesis, measured cold, is 51,167 / 149,608 (estimated 31k / 128k), so later against genesis is 9.5× / 3.9×
    (estimated 8× to 9× / 3×). A cold EX call pays a fixed share of about 0.49M to 0.52M (the carried check asks the live
    index's `replayReadiness()`), which the estimate did not have; it is 3% of the price at 2^24 a call. (Superseded by
    the manifest copy: 0.25M to 0.29M, and the 1,000,000-file figures 477,732 / 575,683 a file, 9.3× / 3.8×; §6, item
    39.)
32. **Correction to item 27.** Step 3b observed "generation 1's own model quotes a create-file recipe at 0.97× its
    prefix spend on amsterdam and 1.10× on prague" in its floor suite. The amsterdam figure reproduces (0.969×, item
    29); on prague that suite measures 1.427× (`HeadAuthorsFloorGen1Test`: 610,600 / 427,634). The example generation's
    own model quotes it at 1.531× (prague) and 1.084× (amsterdam), and the example under generation 1's model at 1.301×
    and 0.906×.
33. **What remains of the pre-freeze gate** (tools/RELEASE.md §15; brought up to date at the final integration). Done
    since step 4: the liveness gate and the fold-hook gap (Option A, items 34–38) and item 29's amsterdam rewrite price
    (fixed in this release). Open: case (d), a digest spec rebuilt in a fresh store (§8 test 9); the above-cap
    state-gas path on a client that implements EIP-8037 (anvil 1.8.3 accepts `--hardfork amsterdam` but applies prague
    pricing); the work model's missing compute and per-purpose terms for later statements (item 41); until freeze any
    replacement Type registry must keep existing Type rows (§4.3); an activation that keeps a live index which no
    longer answers still reverts (§5.3; replacing the index is the recovery).

### The liveness gate and Option A (2026-11-26, branch `fable/2026-11-26-liveness`)

34. **Where the copy lives: measured, code chosen.** Both forms were measured with holders that do only what each adds
    (`test/index/LivenessCost.t.sol`; `vm.lastFrameGas`, execution gas and, on amsterdam, state gas separately; the
    holder with the copy minus the holder with an empty copy; cold reads with the holder and the data contract
    cooled):

    | copy | form | prague deploy | amsterdam deploy (execution + state) | cold read |
    |---|---|---|---|---|
    | 7,168 B (the release's generation 1: 18 families, 1 unit, 2 specs) | (a) storage | 4,934,297 | 2,706,893 + 21,444,480 | 492,700 |
    | | (b) code | 1,534,724 | 458,752 + 11,152,170 | 7,278 (amsterdam 7,878) |
    | 16,000 B (40 families, 6 units) | (a) storage | 10,893,586 | 6,054,682 + 47,001,600 | 1,097,614 |
    | | (b) code | 3,442,663 | 1,024,000 + 24,665,130 | 12,996 (13,596) |
    | 19,968 B (58 families, 1 unit) | (a) storage | 14,023,691 | 7,796,287 + 60,612,480 | 1,369,775 |
    | | (b) code | 4,320,568 | 1,277,952 + 30,736,170 | 15,953 (16,553) |

    The real `IndexReads` with the generation-1 copy against an empty one: +1,537,383 deployment gas on prague,
    +271,177 execution + 11,152,170 state on amsterdam; `liveManifestCopy()` cold 7,374 (7,974). Code is 3.2× cheaper to
    deploy on prague, 2.1× on amsterdam, and about 68× cheaper to read; every carried check of a generation that has
    not folded live (readiness, `build`, a carried family's coverage) and the kernel's activation read the copy, so
    storage would add about 0.5 M gas to each of them for generation 1's shape. Bytecode: the code holder's runtime is
    179 B larger than the storage holder's (537 vs 358 B), which is the code form's extra in `IndexReads`; the kernel's
    and `RealmIndex`'s code is the same for both forms. The code form's cost the storage form does not have is the size
    limit: 24,575 B, so at most 72 families with one unit and two specs, or 67 with six units (§3.5's formula); a
    plausible later generation of 40 lists and 6 units (16,000 B) fits with 8.5 KB to spare, so the limit does not
    decide against it; a larger copy is refused at construction with its own code, `E_PIN(reads, 12)`, and would need
    the copy split over several data contracts (not built). The data contract is not one of the contracts activation
    scans (it scans the index, its reads contract, the build contract, the units' hooks and the stores), so its data
    bytes never meet `CodeScan`; it starts with STOP, so it cannot execute, and it would fail a scan (its last two bytes
    are not a solc trailer), which matters only if a later revision scans it. It is bound twice: the reads contract
    records its address and codehash as immutables (covered by the reads codehash and so by the manifest hash), and the
    kernel and the generation hash its content against the record. Nothing in the Core context creates it.
35. **What changed in `src/`.** `IIndexReads.liveManifestCopy()` (new; the ABI snapshot changed); `IndexReads`: one
    more constructor argument (the copy), `LIVE_COPY`, `LIVE_COPY_CODEHASH`, `_liveCopy`, `_liveManifest`,
    `_unitsCarried`, `_builtHooks`, `builtHooks()`; `RealmIndex`: `BUILT_HOOKS`, `_hookRuns` private and reading it;
    `LedgerControl._liveFamilies` reads the candidate's copy, reason 14; `IndexDeployer.Plan.liveManifest` (and the
    reads arguments encoded as one struct: the ten arguments were too deep for via-IR in `run`); `Errors.sol`: reason 14,
    `E_PIN` 12, reworded 12 and `E_BUILD(7)`. `tools/deploy-plan.mjs` passes an empty copy at genesis. Sizes: `LedgerControl`
    17,830 → 18,042 B (`_checkIndex` +807, `_liveFamilies` −722, the inlined `_revisions` −215, `_activate` +68),
    `RealmIndex` 18,692 → 18,834 B, `IndexReads` 11,556 → 12,431 B (12,012 after the liveness gate alone), all under
    the 19,660 B budget.
36. **Differences from the decided shape.** (a) The oversize copy has its own refusal, `E_PIN(reads, 12)`, at the
    reads contract's construction. (b) Option A's match is fold hook, fold codehash AND `purposeFilter` (§3.6; widened
    from address and codehash on review). (c) The opt-out is accepted only when the generation walks: a generation
    that carries every store cannot build a hook, so its claim is refused. (d) `_hookRuns` is no longer an extension
    point: the opt-out is the reads contract's `_builtHooks`, which the generation reads at construction.
37. **Tests changed, and why.** `Carried.t.sol::testAnAbandonedCarriedStoreIsRefusedByTheGenerationAndTheKernel`: the
    early re-pin's copy is stale, so the kernel says 14 (was 12), and the liar double is given a true copy so it still
    meets 12. `HeadAuthorsBuild.t.sol::test_an_attached_third_store_refuses_the_build`: the replaced C's `build` is
    refused 7 (stale copy; was a no-op build) and the kernel says 14 (was 13). `DroppedList.t.sol`: G's late build,
    after G' went live, is refused 7 (stale copy; before, it folded the CREATE into X), so X keeps its entries.
    `BuildWalkRefusals.t.sol::testFoldHooksRunInAnAllFreshBuildOnlyAndCannotReenterIt`: the heal build with a new hook
    unit is refused 7 (Option A). `HeadAuthorsHooks.t.sol::test_a_re_pin_cannot_build_a_new_units_hook`: refused 7 / 8
    (was activated). Every plan builder fills the copy (`test/harness/ManifestCopy.sol`); `HeadAuthorsReads` names its
    new units through `_builtHooks`.
38. **Still open.** Case (d), a digest spec rebuilt in a fresh store (§8 test 9); the Type-registry rule; the unchanged
    index path's reason-2 read (§5.3, left as it is); a copy over 24,575 B (refused, not split).

### The final integration (2026-11-26, branch `fable/2026-11-26-final`)

The liveness gate and Option A (items 34–38), the reader list-coverage rule (tools/RELEASE.md item 38) and the
Glamsterdam floor price with the ordinary-state composites (item 29, tools/RELEASE.md items 39–40) were each tested
alone; merged on `main` at `726993e` (step 4), they were built, tested together on both schedules and regenerated once.

39. **What had to change where the pieces met.** No `src/` file and no behavior: the three pieces did not conflict.
    (a) Step 4's suites (`BuildGas.t.sol`, `FloorReconcile.t.sol`) already deployed their generations through the
    harness the liveness branch had fixed (`HeadAuthorsBase`, `ManifestCopy.ofLive`), so they built and passed
    unchanged. (b) `FloorReconcile.t.sol` measured the defect item 29 describes and asserted nothing about it; it now
    asserts the fixed behavior (P / spend ≥ 1 in all three states, admission at exactly the plan in state A on both
    schedules) and says how it relates to the floor branch's `FloorStates.t.sol`. (c) The floor-plan vectors, which
    every amsterdam floor suite and `BuildGas`' heaviest-publication test read, were stale until the regeneration
    (the floor branch had changed the prices, not the committed vectors). (d) `TopicSliceCapTest.setUp` failed on the
    amsterdam profile with `E_GAS(0, 300000, 77774)` at `726993e` too: its 70 authors' tags drew state gas from the
    test call's own gas (Foundry has no EIP-8037 reservoir) and ran out of the default 2^30. The amsterdam profile's
    test gas limit is now 10^11 (`foundry.toml`, the `FOUNDRY_GAS_LIMIT` the measuring tools already passed; the gas
    model suite's logs are identical under both limits). Two amsterdam-profile tests fail at `726993e` and here alike
    and are not this release's: `CodeScan.t.sol::test_compiledTrailerIsTheSolcVersionMap` (solc's experimental
    amsterdam target writes another trailer) and `Doubles.t.sol::test_writing_final_fails_only_under_STATICCALL`.
    (e) Measured with the manifest copy: every marginal publication of a build is 22 gas dearer (EX and FR, both
    schedules), and the fixed share of a cold EX call fell from 488,026–516,515 to 252,738–281,227 on prague and from
    492,926–522,215 to 257,338–286,627 on amsterdam, because the carried check reads the copy from code instead of
    calling the live index's `replayReadiness()` (§6.1; the 1,000,000-file build is 1.4% cheaper on prague and 1.2% in all gas on amsterdam, §6.2).
    `BuildGas`' bands are on marginal figures, which moved by 22 gas, so none was changed. (f) The gas model states
    amsterdam's execution-gas maximum error as its own field (tools/RELEASE.md item 40).
40. **Two things the liveness gate settles, each in one sentence.** (a) A replaced generation that carries any store
    can no longer build at all, because its manifest copy is stale, so only a generation whose every store is fresh can
    still walk history late (§3.5, §5.3). (b) The claim "this generation builds that hook" (`IndexReads._builtHooks`,
    `RealmIndex.BUILT_HOOKS`) counts only when the generation actually walks history, that is when it has a fresh
    store; a generation that carries every store is refused for a new fold-hook unit whatever it claims (§3.6).
41. **Accepted: the amsterdam batch sizes as they come out, and the over-reservation of later statements.** The work
    model charges a later statement (a mask, release, restore or number change, `rwPerBindLater`) twelve "rewrites"
    that are really a compute margin. At the Glamsterdam rewrite price of 12,100 (it was 5,000) that charge reserves
    later statements 2.0 to 4.3 times their spend on Glamsterdam and shrinks their batches (tag masks, releases and
    masks of masks 64 → 44, restores and number changes 64 → 41, folder re-binds 61 → 40; tools/RELEASE.md item 39).
    The integration owner accepted these sizes for this release. The remedy is a compute term for later statements in
    the reservation formula, to be decided together with QUESTIONS Q52 (a per-purpose term) as ONE change to the
    formula. The formula lives in `LedgerIngress`, which has 396 B left under the 19,660 B budget (19,264 B in this
    build), so that change needs a size plan before code.
42. **An option not taken: a "per extra distinct kind" term in the gas model.** In both states the index callbacks
    and the final phase spend about 20k to 40k more per extra distinct kind of action in a publication than the sum
    of the per-action figures (each kind's first touch of its index state is cold; a k2 − k1 marginal sees it once,
    inside `fixed`). A measured per-kind execution term, sized from the composites at about 24k to 28k on amsterdam,
    would bring amsterdam's maximum execution-gas error from about 10.6% to about 3.7%; on prague, at about 20k to
    24k, it helps the create file but makes the edits worse (about +7.5% to +8%). It is inferred from the composites'
    residuals, not measured as a row of its own, and what it gives depends on what counts as a kind: recomputed from
    this release's validation rows, 24k to 28k gives 4.2% to 7.4% on amsterdam depending on whether CREATE and the
    tag-level terms count, and prague's edits +7.5% to +8.0% at 20k to 24k. A real term would need a row measured
    independently of the composites it is judged against. Not pursued in this release; the model stays as it is,
    with no re-fit and no new term (tools/RELEASE.md item 40).
43. **FIXED BY WORK-MODEL FORMULA 3 (2026-11-26): the released floor is below the spend of later statements at distinct
    places and in long lists, on today's schedule too.** In the current release a later statement's quote (formula 2:
    122.0k on prague, 235.6k on amsterdam) is below its callbacks' spend when the statements are at distinct places or
    in long lists: 0.91 on prague for a restore of entry 48 across places (134.0k), 0.75 at 4,096 entries (162.8k),
    measured by `test/integration/FloorSplit.t.sol`. Every later measurement before it was in one place with short
    lists, where one scope head is rewritten once per publication and the author's scope list is searched in six
    probes. So today a later-statement publication sent near the floor can be refused (`E_INDEX_GAS`), but it can never
    be admitted unindexed; and prague's later batches were planned on that under-quote. Formula 3 fits the later row to
    the dearest later statement in lists of up to 1,024 entries per author per place (docs/WORK-MODEL-V3.md §3.5), which
    makes prague's masks, releases and restores smaller (64 → 58, 60 → 51) and keeps every re-bind batch at or above
    today's with a row of its own. Item 41's over-reservation on amsterdam is cured by the same change.
