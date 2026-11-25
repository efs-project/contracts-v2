# Building a later index family from history: a proposal

**Status: PROPOSAL. Nothing in this document is implemented.** It designs the step that design §10.1 and §10.6
defer ("a later generation builds its later families from history into its fresh stores before attachment") and
that `tools/RELEASE.md` §15 lists as a pre-freeze gate. Where it says "the code", it means `main` at `899767e`.
Where the code and `docs/DESIGN.md` disagree, this document follows the code and says so (§1.4).

Figures are marked **measured** (with the file they come from) or **estimated** (with how). No figure here was
measured for this document.

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

One store defect matters, and it is in `BitmapStore`. `openCoverage` refuses backfill mode (`BitmapStore.sol:142`),
and only the live generation writes the genesis `BitmapStore`. So a BITMAP family added **in place** (the reserved
`roster` family, kind 17) can open a coverage slot only for a scope that some publication touches after the family
is declared. A pre-declaration scope that nobody touches again never gets a slot, `backfillOr`/`backfillSet` refuse
it (`BitmapStore.sol:162, 182`), and its coverage can never become COMPLETE. The genesis `BitmapStore` is a lasting
contract, so **this one-line change must land before the first lasting deployment** if the in-place route for
`roster` is to stay in the design. If it does not land, `roster` (or any later BITMAP family) can still be added,
but only by building a fresh bitmap store from history (§2.3), which is far dearer.

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
  and `Readiness.build` is 0 (`IndexReads.sol:186-188, 227-228`).
- It holds exactly one posting store and one bitmap store (`RealmIndex.sol:44-45, 109-110`), so it cannot fold
  some families into a carried store and others into a fresh one.
- A generation-1-shaped generation that re-pins any store cannot reach readiness on a Realm with admissions (§0).
  `test/index/IndexDeployer.t.sol:74-87` deploys such a generation (re-pinned posting store, fresh bitmap store) but
  never activates it, and could not.
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
   covered by construction". With `openCoverage` refused in backfill mode, "absent" can also mean "predates the
   declaration and was never touched again", which is not covered (§0).
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

### 2.3 (c) Add a BITMAP family

Example: `roster` (kind 17), reserved in generation 1 as `NOT_MAINTAINED` with CURRENT_STATE semantics
(`IndexReads.sol:84`), "which principals are live in a directory".

A BITMAP family's bits are indexed by the entries of the scope list (kind 10) **in the same store**:
`setBit` and `backfillSet` refuse an entry index at or beyond that store's own scope count
(`BitmapStore.sol:118, 184-185`). That leaves three routes:

1. **In place, in the genesis `BitmapStore`** (design §10.6 backfill): possible only for a family the genesis store
   already lists. Its family set is `scope`, `roster`, `live-scope` (`tools/deploy-plan.mjs:171`), so only `roster`.
   It needs the `openCoverage` fix (§0, §7.2).
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
| (c) BITMAP family | **no**, except the `openCoverage` fix | No BITMAP family is planned (`roster` is reserved, Q16's codec-2 families are later). The fix is the only part with a deadline, because the genesis `BitmapStore` is lasting. |

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

Leaf granularity (resuming inside a publication) is not proposed. It would be needed only if one publication's
build cost could exceed one transaction's gas. A build of the HEAD family costs far less per leaf than the
original callbacks did. A full replay of a publication near the cap (64 lone negatives used 15.46M of 16.60M on
amsterdam, **measured**, design §10.4) adds the decode on top of the callbacks but drops the kernel's own share,
so it probably fits; this must be measured (§8, test 11) before the heal path is relied on.

### 3.4 Where progress lives

In the generation's own storage (`efs.index.gen`), which only its code writes (`GenerationStorage.sol:5`):
`progress.lastProcessed` and `progress.lastPublication` are the build frontier: every built family is complete
through it. `replayStage` keeps its meaning (FRESH, BUILDING, CAUGHT_UP, IN_FLIGHT). `buildFrontier[family]` stays
unused while all built families share one walk.

When the generation goes live, the same word becomes the live progress, so `onAdmission`'s contiguity check
(`expected = lastProcessed + 1`, `RealmIndex.sol:165`) is right from the first live call, exactly as after a replay.

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
*current* frontier (`BitmapStore.sol:201-208`), so a built family must never call it (§9, Q10).

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

These are the generation-1 folds that read more than the effect. In a full replay (case (e)) every one of them runs
in the build; in a partial build only those of the built families do, and the rule after the table says which
reads a built family may have.

| read | where | why the build sees what the live fold saw |
|---|---|---|
| family 20's head (fresh-position test) | `RealmIndex.sol:439-441` | Family 20 is rebuilt **in the same walk, in the same store**, so before admission k its head holds exactly the operations of admissions below k. |
| by-record head (materialize the virtual first entry) | `RealmIndex.sol:328-333` | Same: rebuilt in the same walk. |
| scope-list bisection (`_entryIndex`) | `RealmIndex.sol:498-514` | Same, in the fresh bitmap store; or, for a bits-only store (§2.3 route 3), the carried scope list, whose entries never change once written. |
| `recordHeader(recordId).firstAdmission` | `RealmIndex.sol:331` | Written once, when the record is first admitted. |
| a digest body word | `RealmIndex.sol:319-320` | Record bodies are write-once. |
| the ancestor walk: a record's Type word and body word 0 | `RealmIndex.sol:461-483` | Write-once records; the validator admitted the tag only if its topic was registered strictly before (code 9; `IndexProfiles.sol:26-34`), so every record on the chain existed at the original admission and has not changed. Records registered later are not on the chain: a parent link is written when its child is registered. |
| the Type's `refCount` (decoder) | `IndexReplayDecoder.sol:124` | Registration is append-only and never changes an existing Type (design §8.7). |
| position and binding cells (decoder) | `IndexReplayDecoder.sol:144-156` | Write-once. |

**The rule this gives a built family:** its fold may read write-once ledger facts, and heads of families rebuilt in
the same walk. It must **never read a carried family's head or counter**, because those hold the state at the
frontier, not at admission k.

A carried list's *entries* can still be read historically, because they are append-only and ordered. Example: a
new family that needs "was this TAG position fresh at admission k?" (k being a first statement there) may read
carried family 20's entry 0, the admission of the position's first statement: fresh at k exactly when entry 0 is k.
Its `live` cannot be read that way.

`head-authors` reads nothing but the effect, so it needs none of this.

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

---

## 6. Cost

### 6.1 Unit prices

| item | prague | amsterdam (EIP-8037/8038) | source |
|---|---:|---:|---|
| a fresh slot (raw) | 22,100 | ≈ 110,020 | measured: `docs/GAS-SCHEDULES.md:7-8` |
| a slot rewrite (raw) | 5,000 | 12,100 | measured: `docs/GAS-SCHEDULES.md:7-8` |
| one more entry, on a new list (incl. call and key work) | 27,139 | 115,156 | measured: `docs/TAG-NUMBERS.md:237` (`tagLevel.sharedNew`) |
| one more entry, on an existing list | 15,354 | 29,765 | measured: `docs/TAG-NUMBERS.md:238` (`tagLevel.sharedExisting`) |
| a counter write (`release` or `retain`) | ≈ 14,700 | ≈ 21,900 | measured: design §10.4 (`DESIGN.md:1363`), citing `TAG-NUMBERS.md` |
| decode per publication (evidence, revision row, decoder and self-call) | ≈ 20,000 | ≈ 20,000 | **estimated**: about 4 cold slots plus two calls; cold reads assumed unchanged by EIP-8037/8038 |
| decode per non-bind leaf | ≈ 12,000 | ≈ 12,000 | **estimated**: row (2 cold slots), record cell, a registry call |
| decode per bind leaf | ≈ 20,000 | ≈ 20,000 | **estimated**: row, binding position, previous row, three position cells |

Entries are five to a word (`PostingStore.sol:11`), and the first entry lives in the head, so: a list's first entry
costs one fresh slot; its second materializes word 0 (another fresh slot); every fifth after that takes a fresh
word; the rest are rewrites. A counter write is one rewrite of the list head plus the call. Within one build
transaction, a head touched again is warm, so the per-entry prices above are upper bounds there.

### 6.2 Worked estimate: `head-authors` for a Realm of 1 million files (**all estimated**)

Assumed history: 1,000,000 files, each created by a 5-leaf create-file publication (design §14) with one HEAD
FIRST_BIND and one FOLDER bind; 3 edits per file on average, each 2 leaves (PUBLISH child, BIND HEAD rebind); 10%
of files get a second author's own version (2 leaves, one HEAD FIRST_BIND); 6% of files see a HEAD mask, release
or restore of an asserted head. That is about 4.16M publications, 11.3M leaves, 5.2M bind leaves.

| part | count | prague | amsterdam |
|---|---:|---:|---:|
| new lists (one per file) | 1.0M × 27.1k / 115.2k | 27.1B | 115.2B |
| second entries (word 0) | 0.1M × 27.1k / 115.2k (priced as new, `tagLists.priceAsNew`) | 2.7B | 11.5B |
| counter writes | 0.06M × 14.7k / 21.9k | 0.9B | 1.3B |
| decode, publications | 4.16M × 20k | 83B | 83B |
| decode, bind leaves | 5.2M × 20k | 104B | 104B |
| decode, other leaves | 6.1M × 12k | 73B | 73B |
| **total** | | **≈ 290B gas** | **≈ 390B gas** |

That is roughly 17,000 transactions of 2^24 gas on prague and 23,000 on amsterdam, or 290 / 390 ETH at 1 gwei
(2.9 / 3.9 ETH at 0.01 gwei).

Two things stand out. First, the walk, not the storage, dominates on today's schedule: a build pays to decode every
admission, including the 7M that do not touch HEAD. A decoder that reads only a leaf's kind and a bind's purpose
before deciding to skip would cut the walk to roughly 100B (estimated: 2.1k per skipped non-bind, 6.3k per
non-HEAD bind, 12k per HEAD bind, 6k per publication), but it is a second decode path to prove (§9, Q7).
Second, the storage part is what keeping the list from genesis would have cost anyway, spread over the files'
writers (QUESTIONS Q52: about 36k per file today and 124k after Glamsterdam). Deferring is cheaper only if the list
is never wanted.

For comparison, a full replay (case (e)) re-materializes every posting at the fresh-slot price (design §10.6: about
110k per re-materialized posting on amsterdam, an estimate there).

### 6.3 Who pays

Whoever calls `build`. Nothing on chain repays it, and no user's write pays anything extra during a build. In
practice the Realm's operator pays, and should plan the build like a deployment. After activation every new file
pays the new list's live price through the new work model (a new manifest hash, so signed plans bound to the old
set are refused, QUESTIONS Q11).

---

## 7. What it changes

### 7.1 Replaceable until freeze (new code, no change to anything deployed)

- **The building generation** (generation 2). New immutables: one address per store (carried and fresh) and which
  families are built. New functions: `build(0, maxFacts)` with the semantics of §3.2–3.5, and `buildFold`
  (self-call only). `replayNextPublication` stays for case (e). `backfill` keeps reverting until a BITMAP family
  exists. New `E_BUILD` codes (provisional): 1 already live or activated, 2 a fresh store is not fresh, 3 not idle
  or in flight, 5 no decoder, 6 `maxFacts` below the next publication, 7 a carried family is not the live index's,
  8 nonzero `familyId`. `IRealmIndex`'s ABI is not pinned by the kernel (the ledger calls only `onAdmission`,
  `afterPublication`, `replayReadiness` and `readsContract`), so this changes no kernel id. Its size is estimated at
  generation 1's 13,686 B plus 3–5 KB, under 24,576 B.
- **Its reads contract**: per-family store routing; coverage of built families PARTIAL until the frontier; the
  carried check inside `ready`.
- **A deployer** whose plan takes lists of carried and fresh stores (§3.1).
- **`LedgerControl`**: the two checks of §5.3. A new revision of the ledger implementation, not a layout change.

### 7.2 The stores

- **`PostingStore`: no change.** A fresh store for a later family can be today's code. `STORE_ABI_ID` stays
  `efs/posting-store/2`.
- **`BitmapStore`: one change, before the first lasting deployment, if the in-place route for `roster` stays.**
  `openCoverage` should also accept `MODE_BACKFILL` (the live generation while idle), so a pre-declaration scope
  can get its slot without waiting for a publication to touch it. The ABI does not change, so the selector-derived
  `STORE_ABI_ID` would not move by itself; this proposal recommends bumping the tag to `efs/bitmap-store/2` so the
  changed behavior is visible in the id, as was done for the posting store's step-3b amendment. The alternative is
  to drop the in-place route from the design and add every later BITMAP family through a fresh store (§2.3).
- **The genesis `BitmapStore`'s family set** is fixed forever at deployment: `scope`, `roster`, `live-scope`
  (capacity 4). Only those can ever be BITMAP families in place. Decide before the first lasting deployment
  whether to reserve a fourth id; with route 3 of §2.3 available, this proposal reserves nothing more.

---

## 8. Tests that would prove it

Each runs on both fee profiles.

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
    the heaviest admitted publication (64 deep first tags; 64 lone negatives) replayed within 2^24.
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
   in-place BITMAP backfill from the design? *Recommend fix it: one line, and it is the only cheap route for
   `roster`.*
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
    "we can add it later" comes with a price.*
