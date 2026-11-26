# Work model formula 3: a design proposal with a measured size plan

Status: **proposal, not a work order.** It prepares the integration owner's question "fix the floor's over-reservation
of later statements and give it a per-purpose term, as one change, decided together with QUESTIONS Q52". Nothing in
`src/`, `test/` or `tools/` changes with this document. Every figure is marked **measured** (with the run that produced
it) or **estimated** (with how). The measurements were made in scratch copies of `018e290` (section 8 lists them); none
of that code is committed.

## Landed (2026-11-26, branch `fable/2026-11-26-formula-v3`)

Formula 3 is built. The rulings and two reviews changed it from the proposal below in these ways. The rest of the
document is the proposal as reviewed, kept for its evidence; where it differs from this section, this section is what
the code does.

1. **Three rows, not two.** A re-bind (a BIND on a BOUND head, transition `T_REBIND`) has a row of its own. It never
   searches the author's scope list and moves no live bit or yes-count (`RealmIndex._foldScope` only stamps the scope
   head, `_foldBind` moves no count), and the measurements agree: a number change costs 62.3k on prague in one-entry
   lists and in lists of 1,025 entries across nine topics alike. The ingress tells it apart with the head read it already
   makes (`kind == BIND && state == BOUND`). The surcharge has the same three rows. `WORK_MODEL_WORDS` is **32**: rows
   at words 13-15 (first), 16-18 (re-bind), 19-21 (other later), the surcharged purpose at 22, its rows at 23-31.
2. **The later row was measured in one place only, and was wrong** (the tag design review). Across distinct places a
   mask, release or restore rewrites its place's scope head once more; from entry 48 it writes a live-bits word of its
   own (fresh when the word was empty); and it bisects the author's scope list, one store call per probe (about 2.2k per
   doubling within a place, 4.2k to 5.1k across places). The measurements, both schedules, cold, are committed in
   `test/integration/FloorSplit.t.sol` (table below). The later row is now **2.0 fresh, 5.0 rewrites, 85,000 compute**
   (the proposal's 2.0, 4.0, 42,000); the re-bind row **2.0, 4.0, 42,000**; the first row is unchanged.
3. **The floor claims later statements in lists of up to 1,024 entries per author per place** (the claim's number lives
   in one place: `LIST_LENGTH_CLAIM` in `test/harness/doubles/IndexDoubles.sol`, next to the values fitted to it). It
   covers up to 4,096 entries and stops covering from 4,097 (measured and pinned, §3.5). One kind of restore is
   outside that on prague: a yes after a lone no, covered in lists of up to 256 entries (§3.5).
4. **`indexFloor` takes the largest of the three rows** in each field, surcharge included, when it has no principal, so
   it is an upper bound whatever the values (with the new later row the first row is no longer above it on amsterdam:
   142.75k against 177.7k).
5. **Activation range-checks the work model** (`E_INDEX_NOT_READY` 16) besides its version and length (15); the ingress
   refuses a wrong length or version on every quote (`E_WORK_MODEL` 1 to 3). The ingress keeps no formula 2: a formula-2
   index under it is refused loudly (`E_WORK_MODEL` 2, 17 words), and activation refuses to keep one (15).
6. **WITHDRAW:** only the withdraws after a publication's first pay the later row (one alone is covered by the
   per-publication terms, measured 1.41 / 1.03).
7. **If the HEAD list is kept (Q52), it will be its own family** with the data-contract saver, not folded into
   `position-authors` (ruled; reasons under Q4). It is not built here.
8. **The gas model's later rows** (`unbindTag`, `releaseTag`, `restoreTag`, `bindTagNumberChange`, `unbindFolder`,
   `releaseFolder`, `bindFolderRebind`) were measured in one place with short lists, so the planner's E was short for
   later statements at distinct places and in long lists (by about +37k per statement for a restore of entry 48 across
   places and +65k at 4,096 entries, prague). Done in the same release: the gas model's list tiers (tools/RELEASE.md
   items 47 and "The list tiers"); formula 3 itself changes only the floor section of `tools/gas-model.mjs` and the
   planner's quote.
9. **Sizes in the release** (runtime bytes, budget 19,660 B; formula 3 together with the release's other pieces):
   `LedgerIngress` 18,955 B (705 left), `RealmIndex` 18,408 B (1,252 left), `LedgerControl` 18,363 B (1,297 left),
   `IndexReads` 12,960 B; at `3ca53ba` 19,264, 18,834, 18,042 and 12,431 B.

**The measurements behind the later row** (`FloorSplit.t.sol`, per action, spend p / a, the formula-3 quote's ratio):

| later statement | fresh | rewritten | spend p / a | ratio p / a |
|---|---:|---:|---:|---:|
| a restore, one topic, short list | 1 | 4 | 97.4k / 116.4k | 1.664 / 1.526 |
| restores across 33 topics, one-entry lists | 1 | 5 | 95.2k / 121.3k | 1.704 / 1.464 |
| masks of entry 48 across topics (49-entry lists) | 1 | 5 | 117.6k / 143.8k | 1.378 / 1.235 |
| restores of entry 48 across topics (its bits word empty) | 2 | 5 | 134.0k / 150.3k | 1.210 / 1.182 |
| restores at the end of one list of 4,096 | 1 | 4 | 112.4k / 131.3k | 1.443 / 1.352 |
| **the claim:** restores of a far entry across nine topics, lists of 1,025 | 2 | 5 | 152.6k / 168.9k | 1.062 / 1.052 |
| covered up to: the same at 4,096 entries | 2 | 5 | 160.9k / 177.1k | 1.008 / 1.003 |
| **beyond the claim:** the same at 4,097 entries (thirteen probes) | 2 | 5 | 162.8k / 179.1k | 0.995 / 0.991 |
| masks of a far entry across nine topics, lists of 4,097 | 1 | 5 | 146.5k / 172.7k | 1.107 / 1.029 |
| re-binds: folder re-binds across 33 folders | 2 | 4 | 106.8k / 115.8k | 1.068 / 1.058 |
| re-binds: number changes of a far entry across nine topics, lists of 1,025 | 1 | 2 | 62.3k / 66.9k | 1.833 / 1.833 |
| **the exception:** a yes after a lone no across nine topics, lists of 48 lone noes | 2 | 4 | 128.9k / 137.8k | 1.258 / 1.289 |
| the same, lists of 256 | 3 | 4 | 161.5k / 160.5k | 1.004 / 1.106 |
| the same, lists of 257 | 3 | 4 | 163.5k / 162.5k | 0.992 / 1.093 |
| the same, lists of 1,025 | 3 | 4 | 169.7k / 168.8k | 0.955 / 1.052 |

The last four rows were measured after the release (`test_split_lone_no_yes_*`, §3.5); the later row was fitted
without them.

Formula 2's later quote (122.0k on prague) was below several of these on today's schedule too: 0.91 for a restore of
entry 48 across places and 0.75 at 4,096 entries. Its prague batches were planned on that under-quote, so formula 3's
are smaller where it was short (the batch table below).

**The entry search is the part that grows** (an index item for later, not built here). `RealmIndex._entryIndex` finds a
binding's entry in the author's scope list by bisection, one `scopeEntry` call per probe. That costs about 2.2k per
doubling of the list within one place and 4.2k to 5.1k across places (cold words), and it is why the later row depends
on the length the floor claims. Reading a whole word of five entries per probe near the end of the search, or storing a
binding's entry index when it is appended, would shorten or remove it; either is a change to the index, so to a later
generation, and would let the later row shrink.

**Batch sizes as landed** (the planning rule, `tools/gas-plan.mjs`, on the regenerated `gas/model.json` with the list
tiers applied, which move none of these; "today" = `test/vectors/floor-plan.json` at `3ca53ba`; edits from
`tools/gas-plan-later.mjs`'s shape):

| shape | prague today → formula 3 | amsterdam today → formula 3 |
|---|---|---|
| tag masks, releases, masks of masks | 64 → **58** | 44 → **55** |
| tag restores | 60 → **51** | 41 → **51** |
| tag number changes (re-binds) | 60 → **62** | 41 → **64** |
| folder re-binds | 60 → **62** | 40 → **61** |
| edits (PUBLISH child + HEAD re-bind) | 24 → 24 | 23 → **28** |
| lone negatives | 38 → 38 | 50 → **53** |
| create-file recipes | 10 → 10 | 12 → 12 |
| every other planned shape | unchanged | unchanged |

Prague's masks, releases and restores get SMALLER than today's, because today's are planned on a quote that is below
the real spend for those statements at distinct places and in long lists. The re-bind row keeps every re-bind batch at
or above today's on both schedules.

## The answer first

- **The fix.** Formula 3 charges each bind-kind action one of two *rows*, chosen by whether it is a first or a later
  statement. A row is three honest numbers: fresh slots, rewritten slots and compute in gas. A later statement is
  quoted 2 fresh slots, 4 rewrites and 50,000 of compute (with `computePerAction`) instead of 0 fresh slots and 16
  "rewrites". A first statement keeps the formula-2 quote to the gas on prague; on amsterdam it falls by 14,200.
- **The per-purpose term.** One *surcharge*: one purpose id and a row for first and later statements of that purpose,
  added on top of the ordinary row. For Q52's HEAD list it is `HEAD`, +1 fresh, +1 rewrite and +4,500 on a first
  statement, and +1 rewrite and +10,000 on a later one. Every other purpose pays nothing.
- **What it buys** (measured by `FloorPlan.t.sol` against the new quote). On amsterdam, tag masks, releases, masks of
  masks, restores and number changes go back to **64** (from 44 and 41), folder re-binds to **61** (from 40), lone
  negatives to **53** (from 50) and edits to **28** (from 23). On prague, restores and number changes go to 63 (from 60)
  and folder re-binds to 62 (from 60). Nothing falls without the HEAD list. With it, create-file recipes on prague fall
  from 10 to 9 and edits on amsterdam from 28 to 27. Lone negatives stay at 38 on prague and 53 on amsterdam.
- **The upper-bound law holds.** Every shape the floor claims is quoted at or above its callbacks' spend, in both list
  states, on both schedules. The lowest whole-publication ratio is 1.022 on prague (a name record and a first tag,
  unchanged from formula 2) and 1.039 on amsterdam (64 tag restores; formula 2's lowest there was 1.26, because it
  over-reserved).
- **It fits, with room to spare.** The straightforward code does **not** fit: +710 B against the 396 B left. Read
  `workModel()`'s reply as raw words instead of ABI-decoding a struct and `LedgerIngress` *shrinks*: 19,264 → 18,537 B
  for the full formula 3 (1,123 B left). The same trick costs nothing in gas and saves some. Serving the work model
  from a data contract makes `RealmIndex` 511 B smaller as well (18,834 → 18,323 B), with room for the HEAD list.
- **Surprises** (section 9): a later statement writes a fresh index slot (two for a re-bind), which formula 2 never
  quotes; a WITHDRAW is quoted at 0.12× its spend; the ingress never reads `formulaVersion`; and today's amsterdam
  lone-negative batch is 50, not 54.

## If the owner says no to Q52

The two decisions can be read apart. Section 4's table has a column for each.

**Decision 1, "the compute term only" (Q52 is no).** The whole change is the two rows: later statements get their
honest slot counts (2 fresh, 4 rewrites) plus a compute term, and first statements move the 2 rewrites of compute
that formula 2 hid in `rwPerBind` into their compute term. No surcharge is needed, because no purpose keeps a list of
its own. There are two ways to build it.

| decision 1 built as | `LedgerIngress` (budget 19,660 B) | `RealmIndex` | `IndexReads` | measured by |
|---|---:|---:|---:|---|
| the smallest diff: one new field, `freshPerBindLater`, in formula 2's layout, with new values (`rwPerBind` 20, `rwPerBindLater` 20, `computePerHookEffect` 44,000, `freshPerBindLater` 20) | 19,351 (+87; 309 left) | 18,871 (+37) | 12,449 | scratch `v3m` |
| the two rows, read as raw words (formula 3's layout without the surcharge) | 18,379 (−885) | 18,274 (−560) | 12,757 | scratch `v3k` |

What decision 1 buys on amsterdam: masks, releases, masks of masks and restores 44/41 → 64, number changes 41 → 64 (63
in the smallest-diff build), folder re-binds 40 → 61, lone negatives 50 → 53 and edits 23 → 28. Prague: restores and
number changes 60 → 63 (62), folder re-binds 60 → 62 (61). The planner measured these on the scratch model.
`FloorPlan.t.sol` also proved them end to end on both profiles (section 4), with decision 2's code and the
surcharge set to zero, whose quote is decision 1's.

**Decision 2, "compute term plus the per-purpose term" (Q52 is yes).** Decision 2 is decision 1 plus the surcharge
fields and the HEAD list in `RealmIndex`. It costs 158 B more in the ingress than the two-row build of decision 1
(18,537 B), and 20 to 90 gas a publication on the live path (section 3.3).

**Build now or wait?** Build now, in formula 3's final layout, with the surcharge fields present and set to zero
(section 7, step 1). A "no" on Q52 then needs nothing more. A "yes" changes only values and `RealmIndex`, never the
struct, the ingress or the SDK's formula a second time. The smallest-diff build is cheaper today, but a "yes" would
then mean a second formula version, manifest and SDK re-vendor before the first persistent Realm.

## Terms

- **Quote (P).** The prefix floor `prefixFloor` the ingress computes for a publication: the gas the kernel requires to
  be visible before the index's per-leaf callbacks. Before callback *i* it requires `P − S_i` (*S_i* is what the
  callbacks have spent so far), so the publication's whole quote must cover the callbacks' whole spend.
- **Final reserve (F).** The gas the kernel keeps back for the index's final phase. It is a visibility floor, not a
  proof (design §10.4).
- **Spend.** What the index's prefix callbacks really use: E − K − the final phase, where E is the publication's
  execution gas and K is the same publication with the callbacks mocked (`FloorBase._need`, `_finalPhase`).
- **Ratio.** P over spend. The upper-bound law asks ratio ≥ 1 for every shape the floor claims.
- **Schedules.** *prague* (fresh slot 22,100, rewrite 5,000) and *amsterdam* (Glamsterdam: fresh slot 12,100 of
  execution gas, rewrite 12,100; state gas is outside the quote). `docs/GAS-SCHEDULES.md`.
- **First statement.** A BIND or UNBIND on the author's UNSET head at the position. **Later statement:** every other
  bind-kind action (a RELEASE always).
- **Lists new / lists exist.** Whether the author's lists at the place (scope, role-scope, history and the
  first-statement lists) already hold entries. A first statement on a new topic meets new lists. Every later statement
  meets existing ones.
- **Row.** Formula 3's per-bind terms for one class of statement: (fresh ×10, rewrites ×10, compute).
- **Surcharge.** Formula 3's per-purpose term: one purpose id and a first row and a later row added on top for
  statements of that purpose.
- **Genesis HEAD list.** Q52's option (a): "every author of a file's versions", kept in generation 1's own posting
  store.

## 1. Formula 2 today, exactly as the code computes it

Source: `src/core/LedgerIngress.sol` `_foldAndQuote` and `_foldOne` at `018e290`. The work model is read on every
publication by `IIndexReads(index).workModel()`. `RealmIndex` answers it from its own storage copy (two cold storage
slots: 6,631 gas a call, **measured** in a `-vvvv` trace of `MeasureV3Test`).

| phase | term | multiplied by | added to | priced by |
|---|---|---|---|---|
| once per publication | `freshPerPublication` | 1 | fresh10 | `floorFreshGas` |
| | `rwPerPublication` | 1 | rw10 | `floorRewriteGas` |
| | `computeBase` | 1 | compute | 1 (gas) |
| every action | `computePerAction` | n (all actions, CREATE and WITHDRAW included) | compute | 1 |
| PUBLISH / REUSE | `freshPerPublishFresh + freshPerDigestSpec · specs` when the record has no header yet (`_recordExists`; specs from `digestSpecCount`, 0 if the index does not answer) | 1 | fresh10 | `floorFreshGas` |
| | `freshPerPublishExisting` otherwise | 1 | fresh10 | `floorFreshGas` |
| | `rwPerPublish` | 1 | rw10 | `floorRewriteGas` |
| | `freshPerRef` | the Type's `refCount` | fresh10 | `floorFreshGas` |
| BIND / UNBIND / RELEASE | `freshPerBindFresh` when the author's head is UNSET (a RELEASE is never read and counts as BOUND) | 1 | fresh10 | `floorFreshGas` |
| | `rwPerBindLater` otherwise | 1 | rw10 | `floorRewriteGas` |
| | `rwPerBind` | 1, every bind-kind action | rw10 | `floorRewriteGas` |
| | `computePerHookEffect` | 1, every bind-kind action | compute | 1 |
| conversion | `freshSlots = ⌈fresh10/10⌉`, `rewrites = ⌈rw10/10⌉`, `P = uint32(compute + freshSlots·floorFreshGas + rewrites·floorRewriteGas)` | | | `Limits` (realm word 14) |
| final phase | `F = uint32(finalComputeBase + finalComputePerBind·binds + finalComputePerPublish·publishes)` | | | 1 |

How the kernel enforces it (`src/core/LedgerCore.sol` `_notifyIndex`, `_final`). Before each leaf's callback it keeps
`F + kernelTail` back and forwards 63/64 of the rest to `dispatchIndex`. That call reverts with
`E_INDEX_GAS(remaining, available)` when `available < P − S_i`. Before the final phase the kernel requires
`(gasleft − kernelTail)·63/64 ≥ F`. So `floorFreshGas` and `floorRewriteGas` price the quote, and `kernelTail` sits
outside it.

Where the code and `docs/DESIGN.md` §10.4 / §5.11 disagree, or where the design leaves something out:

1. **`formulaVersion` is never read.** The design names "formula 2, `formulaVersion = 2`", but no contract in `src/`
   checks the field. Section 6.4 says why this matters for formula 3.
2. **The design says later statements are "all rewrites and compute".** Measured, each one writes one fresh index slot
   (a re-bind writes two). Formula 2 quotes them none (section 2).
3. **A REUSE of a missing record is quoted as a new record.** The design says "a REUSE always names an existing one".
   The code checks existence for REUSE too and takes the fresh branch when the record is missing. `validateLeaf` then
   refuses it (`E_MISSING_RECORD`), so only the quote of a publication that never lands differs.
4. **The `uint32` casts are silent.** A work model that makes P or F pass 2^32 wraps with no error. The design does not
   say so. Generation 1's values stay far below it (64 actions quote at most about 14M).
5. **CREATE and WITHDRAW get `computePerAction` and nothing else.** The design's formula says the same, but it never
   says that a WITHDRAW's callback writes a slot and spends about 68k (section 2).

## 2. What the callbacks really spend

**Method (measured).** The scratch suite `MeasureV3Test` extends `FloorReconcileTest`. For each kind of action it
builds the state, then measures the same shape at 1 action and at 33 actions from that state (`FloorReconcile._split`:
every Realm account cooled, spend = E − K − the final phase). Index-side slots come from Foundry's state diff (index,
posting store, bitmap store; "fresh" means zero before and nonzero after, "rewritten" means nonzero before and changed).
The per-action figures are the difference over 32. The first of the 33 actions pays the publication's cold costs and,
for a first statement, meets the author's new lists, so the per-action row is the "lists exist" state and the
one-action row the "lists new" state. **Other** is spend − fresh × fresh price − rewritten × rewrite price on that
schedule. It is the compute, calls and cold reads a compute term has to cover. It agrees across the two schedules to
within 0.7k for every row, which is the evidence that the split is schedule-neutral. Runs:
`FOUNDRY_PROFILE=ci forge test --match-contract MeasureV3Test -vv` and the same under
`FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam`, on `018e290` (formula 2)
and on the formula-3 copy `v3t0` (quote columns). "p / a" means prague / amsterdam. Topic: one registered word.

### 2.1 Per action, the author's lists exist (measured)

| action | fresh slots | rewritten slots | other p / a | spend p / a | formula 2 quote p / a | f2 ratio p / a | formula 3 quote p / a | f3 ratio p / a |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| TAG first lone negative (fresh position) | 4.43 | 0.00 | 64.0k / 64.5k | 161.9k / 118.1k | 183.6k / 156.9k | 1.13 / 1.33 | 183.6k / 142.8k | 1.13 / 1.21 |
| TAG first yes (fresh position) | 5.43 | 0.00 | 57.3k / 57.8k | 177.3k / 123.5k | 183.6k / 156.9k | 1.04 / 1.27 | 183.6k / 142.8k | 1.04 / 1.16 |
| TAG second author's first yes | 4.43 | 2.00 | 54.0k / 54.5k | 161.9k / 132.3k | 183.6k / 156.9k | 1.13 / 1.19 | 183.6k / 142.8k | 1.13 / 1.08 |
| TAG second author's first no | 3.21 | 1.00 | 56.8k / 57.2k | 132.7k / 108.2k | 183.6k / 156.9k | 1.38 / 1.45 | 183.6k / 142.8k | 1.38 / 1.32 |
| TAG later: number change | 1.00 | 1.00 | 30.4k / 30.7k | 57.5k / 54.9k | 122.0k / 235.6k | 2.12 / 4.29 | 114.2k / 122.6k | 1.99 / 2.23 |
| TAG later: mask | 1.00 | 3.00 | 61.1k / 61.6k | 98.2k / 110.0k | 122.0k / 235.6k | 1.24 / 2.14 | 114.2k / 122.6k | 1.16 / 1.12 |
| TAG later: mask of a mask | 1.00 | 1.00 | 41.6k / 41.9k | 68.7k / 66.1k | 122.0k / 235.6k | 1.78 / 3.57 | 114.2k / 122.6k | 1.66 / 1.86 |
| TAG later: release | 1.00 | 3.00 | 61.1k / 61.6k | 98.2k / 110.0k | 122.0k / 235.6k | 1.24 / 2.14 | 114.2k / 122.6k | 1.16 / 1.11 |
| TAG later: restore | 1.00 | 4.00 | 55.3k / 55.9k | 97.4k / 116.4k | 122.0k / 235.6k | 1.25 / 2.02 | 114.2k / 122.6k | 1.17 / 1.05 |
| FOLDER later: re-bind | 2.00 | 3.00 | 42.9k / 43.4k | 102.1k / 103.9k | 122.0k / 235.6k | 1.20 / 2.27 | 114.2k / 122.6k | 1.12 / 1.18 |
| FOLDER later: mask | 1.00 | 3.00 | 61.1k / 61.6k | 98.2k / 110.0k | 122.0k / 235.6k | 1.24 / 2.14 | 114.2k / 122.6k | 1.16 / 1.12 |
| FOLDER later: release | 1.00 | 3.00 | 61.1k / 61.6k | 98.2k / 110.0k | 122.0k / 235.6k | 1.24 / 2.14 | 114.2k / 122.6k | 1.16 / 1.11 |
| FOLDER later: restore | 1.00 | 4.00 | 55.4k / 56.0k | 97.5k / 116.5k | 122.0k / 235.6k | 1.25 / 2.02 | 114.2k / 122.6k | 1.17 / 1.05 |
| HEAD first: second author's yes (another's file) | 3.21 | 1.00 | 39.7k / 40.0k | 115.6k / 90.9k | 183.6k / 156.9k | 1.59 / 1.73 | 183.6k / 142.8k | 1.59 / 1.57 |
| HEAD first: lone negative on another's file | 2.21 | 0.00 | 46.4k / 46.7k | 95.2k / 73.4k | 183.6k / 156.9k | 1.93 / 2.14 | 183.6k / 142.8k | 1.93 / 1.94 |
| HEAD later: re-bind (an edit) | 2.00 | 3.00 | 42.4k / 43.0k | 101.6k / 103.5k | 122.0k / 235.6k | 1.20 / 2.28 | 114.2k / 122.6k | 1.12 / 1.19 |
| HEAD later: mask | 1.00 | 3.00 | 44.5k / 45.0k | 81.6k / 93.4k | 122.0k / 235.6k | 1.49 / 2.52 | 114.2k / 122.6k | 1.40 / 1.31 |
| HEAD later: release | 1.00 | 3.00 | 44.5k / 45.0k | 81.6k / 93.4k | 122.0k / 235.6k | 1.49 / 2.52 | 114.2k / 122.6k | 1.40 / 1.31 |
| HEAD later: restore | 1.00 | 4.00 | 38.9k / 39.5k | 81.0k / 100.0k | 122.0k / 235.6k | 1.51 / 2.36 | 114.2k / 122.6k | 1.41 / 1.23 |
| PUBLISH new (10-byte name) | 0.65 | 0.00 | 29.3k / 29.4k | 43.6k / 37.2k | 44.1k / 70.8k | 1.01 / 1.90 | unchanged | 1.01 / 1.90 |
| PUBLISH existing (the same names again) | 2.40 | 0.00 | 34.3k / 34.4k | 87.3k / 63.5k | 95.2k / 98.8k | 1.09 / 1.56 | unchanged | 1.09 / 1.56 |
| REUSE | 2.40 | 0.00 | 34.3k / 34.5k | 87.3k / 63.5k | 95.2k / 98.8k | 1.09 / 1.56 | unchanged | 1.09 / 1.56 |
| CREATE | 0.00 | 0.00 | 6.9k / 6.9k | 6.9k / 6.9k | 8.0k / 8.0k | 1.16 / 1.16 | 8.0k / 8.0k | 1.17 / 1.17 |
| WITHDRAW (of a name record) | 1.00 | 0.00 | 45.6k / 45.7k | 67.7k / 57.8k | 8.0k / 8.0k | **0.12 / 0.14** | 8.0k / 8.0k (see Q6) | 0.12 / 0.14 |

The fresh slot of a later statement is in the posting store (**measured**, `test_v3_which_fresh`: one fresh slot of a
tag mask and of a number change, both in the posting store; it is the binding's history list growing).

### 2.2 One action alone: the publication's cold costs, and the author's lists new for a first statement (measured)

| action | fresh | rewritten | spend p / a | f2 P p / a | f2 ratio | f3 P p / a | f3 ratio |
|---|---:|---:|---:|---:|---:|---:|---:|
| TAG first lone negative | 9 | 1 | 284.7k / 203.7k | 319.9k / 265.4k | 1.12 / 1.30 | 319.9k / 251.2k | 1.12 / 1.23 |
| TAG first yes | 10 | 1 | 300.2k / 209.1k | 319.9k / 265.4k | 1.07 / 1.27 | 319.9k / 251.2k | 1.07 / 1.20 |
| TAG second author's first yes | 5 | 5 | 212.9k / 200.0k | 319.9k / 265.4k | 1.50 / 1.33 | 319.9k / 251.2k | 1.50 / 1.26 |
| TAG later: restore | 1 | 6 | 137.2k / 171.3k | 247.3k / 338.0k | 1.80 / 1.97 | 239.5k / 225.0k | 1.75 / 1.31 |
| TAG later: mask | 1 | 5 | 137.9k / 164.9k | 247.3k / 338.0k | 1.79 / 2.05 | 239.5k / 225.0k | 1.74 / 1.37 |
| FOLDER later: re-bind | 2 | 5 | 132.7k / 149.6k | 247.3k / 338.0k | 1.86 / 2.26 | 239.5k / 225.0k | 1.81 / 1.50 |
| HEAD later: restore | 1 | 5 | 106.8k / 133.8k | 247.3k / 338.0k | 2.32 / 2.53 | 239.5k / 225.0k | 2.24 / 1.68 |
| PUBLISH existing | 2 | 5 | 116.9k / 133.5k | 224.6k / 207.2k | 1.92 / 1.55 | unchanged | |
| WITHDRAW | 1 | 3 | 94.6k / 106.7k | 133.3k / 110.4k | 1.41 / 1.03 | unchanged | |

The rewrites of a publication are mostly per publication, not per action: a list's head is rewritten once and its
later writes in the same transaction cost 100. That is why one action alone rewrites 5 or 6 slots and each further
action 1 to 4.

### 2.3 Create-file recipes, and the whole publications the floor claims (measured)

A create-file recipe is CREATE, PUBLISH root, PUBLISH name, BIND HEAD, BIND FOLDER. `FloorReconcile`'s per-leaf split
(prague / amsterdam):

| state | index slots | prefix spend | P (f2 = f3 on prague) | ratio f2 | ratio f3 |
|---|---|---:|---:|---:|---:|
| A: the author's first file in the folder | 17 fresh, 3 rewritten | 552,952 / 407,284 | 610,600 / 585,500 (f3: 557,100) | 1.104 / 1.437 | 1.104 / 1.368 |
| B: the author already has files there | 7 fresh, 17 rewritten | 410,644 / 464,876 | same | 1.486 / 1.259 | 1.487 / 1.198 |

Per leaf in state A on prague: HEAD 195.6k and FOLDER 179.6k (they include the publication's first cold calls into
the stores). In state B: 123.6k and 156.3k.

The whole-publication shapes of `FloorStates.t.sol` and `FloorPlan.t.sol` (formula 3, both profiles, passing) are in
section 4.

## 3. The proposal: formula 3

### 3.1 The formula

Over a publication of n actions:

```
fresh10 = freshPerPublication + Σ_publish(freshPerRef·refs + (new ? freshPerPublishFresh + freshPerDigestSpec·specs
                                                                 : freshPerPublishExisting))
          + Σ_bind row.fresh
rw10    = rwPerPublication + publishes·rwPerPublish + Σ_bind row.rw
compute = computeBase + n·computePerAction + Σ_bind row.compute
  where, for each BIND / UNBIND / RELEASE,
    row = first statement ? (freshPerBindFirst, rwPerBindFirst, computePerBindFirst)
                          : (freshPerBindLater, rwPerBindLater, computePerBindLater)
    and, when the action's purpose word equals surchargePurpose (never when surchargePurpose is 0),
    row += first statement ? (surchargeFreshFirst, surchargeRwFirst, surchargeComputeFirst)
                           : (surchargeFreshLater, surchargeRwLater, surchargeComputeLater)
P = compute + ⌈fresh10/10⌉·limits.floorFreshGas + ⌈rw10/10⌉·limits.floorRewriteGas        (unchanged)
F = finalComputeBase + binds·finalComputePerBind + publishes·finalComputePerPublish         (unchanged)
```

The publish, per-publication and final-phase terms are formula 2's, unchanged (see Q9 on `rwPerPublish`).

### 3.2 The struct (26 words, `WORK_MODEL_WORDS` 17 → 26)

```solidity
struct WorkModel {
    uint8 formulaVersion;             // 3
    uint16 freshPerPublication;
    uint16 rwPerPublication;
    uint16 freshPerPublishFresh;
    uint16 freshPerPublishExisting;
    uint16 rwPerPublish;
    uint16 freshPerRef;
    uint16 freshPerDigestSpec;
    uint32 computeBase;
    uint32 computePerAction;
    uint32 finalComputeBase;
    uint32 finalComputePerBind;
    uint32 finalComputePerPublish;
    // a bind-kind action's row: words 13-15 for a first statement, 16-18 for a later one
    uint16 freshPerBindFirst;
    uint16 rwPerBindFirst;
    uint32 computePerBindFirst;
    uint16 freshPerBindLater;
    uint16 rwPerBindLater;
    uint32 computePerBindLater;
    // one purpose surcharge (word 19; 0 = none), its first row (20-22) and its later row (23-25)
    bytes32 surchargePurpose;
    uint16 surchargeFreshFirst;
    uint16 surchargeRwFirst;
    uint32 surchargeComputeFirst;
    uint16 surchargeFreshLater;
    uint16 surchargeRwLater;
    uint32 surchargeComputeLater;
}
```

The rows sit in consecutive words on purpose. The ingress reads the reply as raw words, so a row is three loads at a
fixed offset (section 5).

New and changed field names:

| field | status | replaces in formula 2 |
|---|---|---|
| `freshPerBindFirst` | renamed | `freshPerBindFresh` |
| `rwPerBindFirst` | new | the first-statement share of `rwPerBind` |
| `computePerBindFirst` | new | the first-statement share of `computePerHookEffect` |
| `freshPerBindLater` | new | (nothing: formula 2 quotes later statements no fresh slot) |
| `rwPerBindLater` | **meaning changed**: the whole rewrite count of a later statement | `rwPerBind + rwPerBindLater` |
| `computePerBindLater` | new | the later-statement share of `computePerHookEffect` |
| `surchargePurpose`, `surchargeFreshFirst`, `surchargeRwFirst`, `surchargeComputeFirst`, `surchargeFreshLater`, `surchargeRwLater`, `surchargeComputeLater` | new | (nothing) |
| `freshPerBindFresh`, `rwPerBind`, `computePerHookEffect` | removed | |

### 3.3 The per-purpose shape: (a), one surcharge entry

| shape | what the ingress does per bind | measured or estimated cost | verdict |
|---|---|---|---|
| (a) one entry: a purpose id plus a first row and a later row | compares the action's `purpose` word (calldata, already loaded for the position key) with word 19 of the work model in memory, and on a match adds three more words | ingress +158 B over decision 1's two-row build (**measured**: 18,379 → 18,537); live path: a create-file publication's kernel share rose 89 gas (two binds, one matching; **measured**, K 1,123,052 → 1,123,141); IndexReads +245 B | **chosen** |
| (b) a fixed table of two or three entries | a loop over the entries, the same comparison per entry | **estimated** +60 to 100 B more and about 20 gas per entry per bind (the loop and one more comparison); 7 more words per entry | not needed: no second purpose keeps a list of its own today. A later need is a formula 4 |
| (c) the kernel passes nothing and the generation declares a per-purpose function | the ingress calls the index during the quote (per bind, or once with the actions) | **estimated** at least one cold CALL (2,600) plus the calldata of the actions, per publication, and code in the index | rejected: dearer on the hot path, and the quote no longer comes from a static manifest field |

**Landed:** there is ONE surcharge slot. The design already has a second per-purpose cost: a fold-hook unit with a
purpose filter runs inside `onAdmission`, so its gas is prefix spend, and formula 3 retires `computePerHookEffect`. If
HEAD holds the slot, the first purpose-filtered unit either goes on the ordinary rows (every purpose reserves for it) or
needs formula 4, a kernel activation. One entry is accepted for generation 1.

The kernel stays purpose-agnostic in (a). It never interprets a purpose; it compares two words. A surcharge purpose of
0 never matches a bind that lands, because the kernel refuses a bind with purpose 0 (`LedgerCore` `E_SHAPE(leaf, 1)`).
Even if it did match, every surcharge term is then 0.

### 3.4 Values

Every slot count below is the largest the measurements in section 2 found for its class. Compute is set from the
dearest whole shape of the class, so that the slot counts stay true counts and no compute hides in them.

| field | formula 2 (gen 1 today) | formula 3, gen 1, no HEAD list | formula 3, gen 1 with the genesis HEAD list | where it comes from |
|---|---:|---:|---:|---|
| `freshPerBindFirst` | 55 | 55 | 55 | first yes writes 5.43 (2.1) |
| `rwPerBindFirst` | 40 (`rwPerBind`) | 20 | 20 | second author's first yes rewrites 2.00 (2.1) |
| `computePerBindFirst` | 34,000 (`computePerHookEffect`) | 44,000 | 44,000 | the 2 rewrites of compute formula 2 hid, moved: prague's first quote is unchanged to the gas (183,550 a statement); the dearest first shapes are then covered 1.035× (prague first yes) and 1.08× (amsterdam second author's yes) |
| `freshPerBindLater` | 0 | 20 | 20 | re-binds write 2.00, every other later statement 1.00 (2.1) |
| `rwPerBindLater` | 160 (`rwPerBind + rwPerBindLater`) | 40 | 40 | restores rewrite 4.00 (2.1) |
| `computePerBindLater` | 34,000 | 42,000 | 42,000 | with `computePerAction` 50,000 a statement: the least value that quotes every measured later statement ≥ 1.05× on both schedules. The binding case is amsterdam's restore: 1.05 × 116.4k − 6 slots × 12.1k = 49.7k |
| `surchargePurpose` | — | 0 | `Purpose.HEAD` | |
| `surchargeFreshFirst` | — | 0 | 10 | the list's new head, or a second author's word: +1.00 fresh (table below) |
| `surchargeRwFirst` | — | 0 | 10 | a second author rewrites the list's head: +1.00 |
| `surchargeComputeFirst` | — | 0 | 4,500 | +3.5k to +4.0k of other, measured |
| `surchargeFreshLater` | — | 0 | 0 | |
| `surchargeRwLater` | — | 0 | 10 | the counter on a mask, release or restore: +1.00 |
| `surchargeComputeLater` | — | 0 | 10,000 | +9.25k to +9.42k of other (the counter's call into the store), measured |
| every other field | as today | unchanged | unchanged | |

The genesis HEAD list's own cost, measured as the formula-3 copy with the list (`v3t2`) minus the same copy without it
(`v3t0`), the same shapes from the same states (`MeasureV3Test`, both profiles):

| HEAD statement | extra slots | extra spend p / a (execution) | the surcharge reserves p / a |
|---|---|---:|---:|
| create file (a first yes on a new list) | +1 fresh | +25,675 / +15,775 (and +97,920 of state gas) | 31,600 / 28,700 |
| a second author's first yes | +1 fresh, +1 rewritten | +30,958 / +28,155 | 31,600 / 28,700 |
| a lone negative on another's file | +1 fresh, +1 rewritten | +30,626 / +27,822 | 31,600 / 28,700 |
| mask or release of a BOUND head | +1 rewritten | +14,318 / +21,516 | 15,000 / 22,100 |
| restore | +1 rewritten | +14,253 / +21,451 | 15,000 / 22,100 |
| re-bind (an edit) | none | 0 / 0 | 15,000 / 22,100 (over-reserved, Q5) |

**Landed note on these values** (the tag design review): by the class rule, the first-row surcharge for the HEAD list is
not needed (a HEAD first statement plus the list is under the first row), and it is what costs the tenth create-file
recipe on prague. The values stay ("the surcharge is the list's measured cost" is the simpler rule and keeps
create-file's margin at 1.10); they are manifest data that the later HEAD-list step can revisit. With the re-bind row the
surcharge's re-bind share is zero, since the list does nothing on an edit, which removes the edit's over-reservation.

**Without the surcharge** the formula-3 rows still cover these on prague (lowest: create file in state A, 1.055). On
amsterdam a HEAD restore with the list rewrites 5 slots against the row's 4 and is covered only 1.01×. So the
surcharge is what keeps the HEAD quote honest, not just safe.

### 3.5 The upper-bound law

Formula 3 keeps the lowest ratio at or above 1 the way formula 2 does: every slot count is at least the largest
measured for its class, and each class's compute term is set so that its dearest measured shape stays at or above
1.035 (first statements, prague, unchanged from formula 2) and 1.05 (later statements, both schedules). The measured
whole-publication ratios, formula 3 (`FloorPlan.t.sol` at the planned k; `FloorStates.t.sol`; `IndexFloor.t.sol`;
`FloorReconcile.t.sol`; `HeadAuthorsFloor.t.sol`; all passing on both profiles in `v3t0` and `v3t2`):

| | prague, no list | prague, with list | amsterdam, no list | amsterdam, with list | formula 2 today, p / a |
|---|---:|---:|---:|---:|---:|
| lowest of FloorPlan's claimed shapes | 1.022 (name record + first tag, k 21) | 1.022 | 1.039 (tag restores, k 64) | 1.039 | 1.022 / 1.26 (design §10.4) |
| tag masks, releases at k | 1.152 | 1.151 | 1.099 | 1.099 | 1.229 / — |
| folder re-binds at k | 1.133 (k 62) | 1.133 | 1.188 (k 61) | 1.188 | 1.209 (k 60) / — |
| lone negatives at k | 1.132 (k 38) | 1.132 | 1.200 (k 53) | 1.200 | 1.132 / — |
| create-file recipes at k | 1.280 (k 10) | 1.267 (k 9) | 1.595 (k 12) | 1.607 | 1.280 / — |
| state B: one create file | 1.487 | 1.472 | 1.198 | 1.218 | 1.486 / 1.259 |
| state A: one create file | 1.104 | 1.109 | 1.368 | 1.384 | 1.104 / 1.437 |
| state B: 32 first tags | 1.052 | 1.052 | 1.162 | 1.162 | |

This holds for the shapes the floor claims, in both list states, on both schedules. On amsterdam the margin is
thinner than formula 2's (1.04 against 1.26): that is the over-reservation going away, not a defect. A strictly
componentwise rule (compute ≥ the largest "other" of the class, ignoring that the slot counts already over-cover
most shapes) would also be honest. It costs batches: prague lone negatives 38 → 36, restores and number changes
63 → 58, amsterdam lone negatives 53 → 49 (planner, **measured** on the scratch model, Q1).

**Landed: what the floor claims, and what it does not.**

- **Covered:** every first statement on a topic of one word (deep first tags remain the exception of §3.6); every
  re-bind, in a list of any length and at any number of places (it never searches); every mask and release, and every
  restore but one kind, in an author's list of up to 1,024 entries at one place, at any entry, with any number of
  distinct places in one publication, quoted at 1.05× or more of its spend on both schedules; every WITHDRAW. The one
  kind is a yes after a lone no, covered on prague only in lists of up to 256 entries (below). The list is one author's entries at
  one exact place, keyed by author, purpose and subject: for a tag, everything one author filed under one exact topic or
  address; for a folder, one author's entries in that folder; a file's HEAD list has one entry, so edits and version
  masks never search far.
- **Not covered — a limit of the bare floor, not a rare case:** masks, releases and restores in longer lists. They are
  ordinary for three kinds of author: a large folder or dataset import, a curator or bot filing under one topic, a
  moderator's list of negatives on a busy topic. The quote covers a restore of a far entry across distinct places up to
  4,096 entries (twelve probes, measured 1.008 / 1.003) and stops covering from 4,097 (thirteen probes, measured
  0.995 / 0.991); the restore sets that number because it writes the most (2 fresh, 5 rewritten) on top of the search. Both
  are pinned by tests (`test_split_break_even_covered_at_4096`, `test_split_break_even_not_covered_at_4097`), and the
  claim by `test_split_claim_restores_across_lists_at_the_claim`.
- **Not covered either:** two statements at one position in one publication. The quote reads the author's head before
  the publication, so a first yes followed by a mask of the same position is quoted as two first statements; with the
  first row no longer at or above the later row, the second is under-quoted by the difference between the rows when its
  spend is near the later row's. In short lists the first row still covers it (measured per pair 1.420 / 1.467; pinned by
  `test_split_two_statements_at_one_position`).
- **Not covered on prague: a yes after a lone no in a list of more than 256 entries** (found after the release by the
  tag design review; measured and pinned). A yes after a lone no is a restore that is the binding's SECOND statement.
  `PostingStore._append` at count 1 materializes the binding's history word 0, a fresh slot; every restore the later
  row was fitted to is a binding's third statement (yes, mask, yes), whose append rewrites that word. In a list of lone
  noes no live bit is ever set, so the entry's live-bits word is empty and the yes writes it fresh; with the thing's
  backlink list holding one entry, the yes writes that list's word 0 fresh too. The yes then writes 3 fresh index slots
  and rewrites 4, against the row's 2.0 and 5.0. Per statement (`test/integration/FloorSplit.t.sol`, prague /
  amsterdam; quote 162,200 / 177,700):

  | the yes after a lone no | fresh | rewritten | spend p / a | ratio p / a |
  |---|---:|---:|---:|---:|
  | across nine topics, lists of 48 lone noes | 2 | 4 | 128,854 / 137,837 | 1.258 / 1.289 |
  | the same, lists of 256 | 3 | 4 | 161,454 / 160,532 | 1.004 / 1.106 |
  | the same, lists of 257 | 3 | 4 | 163,454 / 162,532 | 0.992 / 1.093 |
  | the same, lists of 512 or 513 (alike) | 3 | 4 | 167,573 / 166,651 | 0.967 / 1.066 |
  | the same, lists of 1,024 or 1,025 (alike) | 3 | 4 | 169,693 / 168,771 | 0.955 / 1.052 |
  | lists of 1,025, the thing unlinked (its backlink list empty) | 3 | 3 | 164,391 / 156,369 | 0.986 / 1.136 |
  | a lone no after 1,024 first yeses (the same bits word state) | 3 | 4 | 169,693 / 168,771 | 0.955 / 1.052 |
  | at one topic of 48, nine spread entries | 2 | 3 | 116,368 / 118,155 | 1.393 / 1.503 |
  | at one topic of 256 | 2.12 | 3 | 131,021 / 131,566 | 1.237 / 1.350 |
  | at one topic of 1,025 | 2.5 | 3 | 146,599 / 143,432 | 1.106 / 1.238 |

  So prague covers this shape in lists of up to 256 entries, stops at 257 (0.992), and is at 0.955 at the claim length;
  amsterdam, where a fresh slot and a rewrite cost the same 12,100 of execution, covers every measured cell (1.052 at
  the claim). What can happen is what "not covered" means below: a publication sent at or near the bare floor is
  refused `E_INDEX_GAS` with nothing admitted; it is never admitted unindexed. Masks and releases are unaffected (their
  most is 1 fresh and 5 rewritten, measured). Pinned by `test_split_lone_no_yes_short_list`,
  `test_split_lone_no_yes_covered_at_256`, `test_split_lone_no_yes_not_covered_at_257`,
  `test_split_lone_no_yes_at_the_claim`, `test_split_lone_no_yes_at_the_claim_unlinked`,
  `test_split_lone_no_yes_after_yeses_at_the_claim` and `test_split_lone_no_yes_one_place_at_the_claim` (per-schedule
  bands and exact slot counts). **Ruled:** the released values stay for this release, with the exception named and
  pinned; at the next regeneration (the list release) the later row's fresh count goes to 3.0 with its compute fitted by
  measurement, clearing the 1.05 assertion of `test_split_claim_restores_across_lists_at_the_claim` on both schedules
  (tools/RELEASE.md §15, "Open").
- **The gas model is two fresh slots short for the same yes** (kernel gas as well as index gas, so this is a gas-model
  matter, not a floor one). Besides the index's slot above, the kernel writes the binding head's target fresh:
  `LedgerApply` writes `head.target` only when it changes, and a lone no leaves it zero. The model's restore rows
  (`restoreTag` and its tiers) measure a third statement, which writes neither. After a lone no and then a release or
  a second no, the yes is the binding's third statement: its history append rewrites, so of the two extra slots only the
  head's target remains (one slot short; not measured as a publication). A folder hide of an entry never bound, then a bind, is the
  same transition and is to be measured, not assumed. Whole publications
  (`test/integration/LoneNoGas.t.sol`; lists of lone noes, things linked once, file subjects as the rows use), against
  `gas/model.json` with the list tiers, error = (predicted − measured) / measured:

  | publication | tier the planner applies | prague, all gas | amsterdam, all gas | amsterdam, execution |
  |---|---|---:|---:|---:|
  | 32 yeses across topics, lists of 48 | short (count 48 known) | −21.57% | −29.74% | −11.47% |
  | the same | long (count omitted) | +0.81% | −10.33% | +8.20% |
  | 32 at one topic of 48 | short | −19.21% | −29.38% | −8.66% |
  | the same | long | −2.64% | −22.51% | +12.54% |
  | 32 across topics, lists of 256 | long | −10.55% | −22.76% | −1.08% |
  | 32 at one topic of 256 | long | −5.70% | −23.62% | +8.81% |
  | 16 across topics, lists of 1,025 | long | −11.94% | −22.46% | −2.94% |
  | 32 at one topic of 1,025 | long | −7.40% | −25.20% | +7.23% |
  | 51 across topics, lists of 1,025 | long | −13.77% | −23.98% | −4.90% |
  | 51 at one topic of 1,025 | long | −9.01% | −25.64% | +5.17% |

  The full batch (51, the largest planned batch of tag restores) across 1,025-entry lists costs 15,274,989 gas in all
  on prague (15,099,369 of execution, 21,000 intrinsic, 154,620 of calldata) and 14,035,893 of execution in all on
  amsterdam (13,860,261 of execution), both under 2^24. The planner's restore batches are bounded by V, not E (51 on
  both schedules with the count known or omitted), so the shortfall moves no planned batch size; `eth_estimateGas`
  stays the authority for a gas limit. The model's stated `maxUnderErrorPercent` (and amsterdam's
  `maxUnderExecutionErrorPercent`) does NOT include this shape: no validation composite measures it. The proper rows
  are for the list release (tools/RELEASE.md §15); until then a consumer adds two fresh slots to E for such a BIND
  (tools/RELEASE.md item 42, the interim rule). Reproduce: `forge test --match-path
  test/integration/LoneNoGas.t.sol -vv` on each profile (frame gas, frame state gas, calldata gas); the prediction for
  prague all gas and amsterdam execution gas is the planner's E, `planner(model, schedule).check(actions).E` in
  `tools/gas-plan.mjs` with `actions` one `{ kind: "bind", cost: "restoreTag", first: false, firstAtPlace, entries }`
  per yes, and amsterdam all gas is the same sum over `profiles.amsterdam.constants` (`fixed` plus each yes's
  `laterKey` constant).
- **What "not covered" means for a person.** Before each callback the kernel requires the gas left to cover what
  remains of the quote (`dispatchIndex`, `E_INDEX_GAS`). A publication whose real spend is above the quote is still
  admitted when it carries the gas: a sender that takes its gas limit from `eth_estimateGas` (the least limit at which
  the whole publication succeeds, callbacks included) with a margin is admitted. What can fail is a publication sent
  with a gas limit at or near the bare floor: a callback that runs out reverts it whole with `E_INDEX_GAS`, so it is
  refused near the floor and never admitted unindexed. A planner cannot see list lengths, so a batch planned at its
  largest size whose statements meet long lists can need more execution gas than the plan assumed; if that passes the
  2^24 cap, `eth_estimateGas` fails, and the publication is refused at send-time as over the cap, nothing sent; the
  sender splits it and tries again. Only a mask, a release or a restore pays the search.
- **Not a lasting commitment.** The search lives in the index and the rows in the manifest, both per generation; a
  later index can change either without touching a store.
- **`indexFloor` is an upper bound** whatever the values: with no principal, every bind adds the largest of the three
  rows in each field, surcharge rows included, so it is at or above the quote of the same publication by any author at
  any prices (`test_index_floor_bounds_every_author_whatever_the_rows` checks it under generation 1's model and under a
  model whose later row out-quotes its first row).

### 3.6 Deep first tags: leave the exception alone

The floor still does not know a topic's depth, and formula 3 should not try. Pricing the walk needs the depth, which
is not stored, and the gas model already carries the per-level terms. The deep shapes are bounded by their own
execution estimate E, not by the floor: their largest batches do not move under formula 3 (section 4: depth 8 and 64,
both states, both schedules, unchanged), and their ratios (0.07 to 0.55, measured) are what the design already
documents. A per-depth term would need the ingress to walk ancestors: a ledger read per level on the hot path.

## 4. What it buys, in numbers

The planning rule (`tools/gas-plan.mjs`, unchanged except the quote) over `gas/model.json` at `018e290` with
`floor.workModel` replaced. For the HEAD-list column, the list's measured execution gas is added to `bindHeadFresh`
(+25,675 prague, +15,775 amsterdam); its re-bind costs 0. **Measured** for v2, D1 and D2 by `FloorPlan.t.sol`, which
built the largest publication of each shape in the formula-3 copies and found the kernel's quote equal to the planner's
and the publication admitted (V within a 2^24 transaction; on prague run with exactly the room). The scratch planner's
formula-2 path reproduces the committed `test/vectors/floor-plan.json` byte for byte.

**D1** = formula 3 with no HEAD list (decision 1, two-row build). **D2** = formula 3 with the genesis HEAD list and its
surcharge (decision 2). Changed numbers are in bold.

| shape | prague: today / D1 / D2 | amsterdam: today / D1 / D2 | for reference: today's formula + the list on general terms (p / a) |
|---|---|---|---|
| lone negatives (first masks), one-word topic | 38 / 38 / 38 | 50 / **53** / **53** | 34 / 44 |
| first tags, 8-word path, all new | 18 / 18 / 18 | 19 / 19 / 19 | 18 / 19 |
| first tags, 64-word path, all new | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 |
| first tags, 8-word topic, positions exist | 22 / 22 / 22 | 20 / 20 / 20 | 22 / 20 |
| first tags, 64-word topic, positions exist | 4 / 4 / 4 | 3 / 3 / 3 | 4 / 3 |
| second author's first tags, 8-word topic | 22 / 22 / 22 | 20 / 20 / 20 | 22 / 20 |
| tag masks | 64 / 64 / 64 | 44 / **64** / **64** | 64 / 41 |
| tag releases | 64 / 64 / 64 | 44 / **64** / **64** | 64 / 41 |
| tag restores | 60 / **63** / **63** | 41 / **64** / **64** | 56 / 39 |
| tag number changes | 60 / **63** / **63** | 41 / **64** / **64** | 56 / 39 |
| masks of masks | 64 / 64 / 64 | 44 / **64** / **64** | 64 / 41 |
| folder re-binds | 60 / **62** / **62** | 40 / **61** / **61** | 56 / 38 |
| repeat publishes | 64 / 64 / 64 | 64 / 64 / 64 | 64 / 64 |
| name records | 61 / 61 / 61 | 64 / 64 / 64 | 61 / 64 |
| a name record and a first tag (units of 2) | 21 / 21 / 21 | 27 / 27 / 27 | 20 / 25 |
| registration chunk (word pages) | 64 / 64 / 64 | 64 / 64 / 64 | 64 / 64 |
| create-file recipes (units of 5) | 10 / 10 / **9** | 12 / 12 / 12 | 9 / 12 |
| edits: PUBLISH child + HEAD re-bind (units of 2; planner only) | 24 / 24 / 24 | 23 / **28** / **27** | 23 / 22 |

The last column is the list's honest increments put on formula 2's general terms (`freshPerBindFresh` +10, `rwPerBind`
+10, `computePerHookEffect` +10,000). It is what Q52's "yes" costs every purpose without a per-purpose term.

**The headline answers.**

- **Amsterdam masks, releases, masks of masks, restores and number changes return to 64; folder re-binds to 61**
  (prague's is 62). At 61 the amsterdam batch is still limited by V: 14.12M, and one more re-bind is over the
  14.26M budget, because a folder re-bind's final phase is reserved and spent on top of the quote. Both decisions do
  this.
- **The lone-negative batch stays at 38 on prague with the HEAD list kept, and rises to 53 on amsterdam.** Today's
  amsterdam figure is 50, not 54: 54 was the figure before the Glamsterdam rewrite price was corrected (RELEASE.md
  item 39). With today's formula and the list it would fall to 34 / 44.
- **What the HEAD list adds to a create-file:** reserved +31,600 on prague (P 610,600 → 642,200) and +28,700 on
  amsterdam (557,100 → 585,800). Real gas is +25,764 of execution on prague (E 1,724,035 → 1,749,799, of which 77 is
  the surcharge comparison) and +15,852 of execution plus 97,920 of state gas on amsterdam (113,772 in all). All
  measured by `FloorReconcile`'s state A.
- **What the HEAD list adds to an edit:** reserved +15,000 / +22,100. Real gas is 0: an edit's HEAD re-bind leaves
  the list alone (measured: the same 101,547 / 103,426 per re-bind with and without the list). It is the one
  over-reservation the surcharge adds (Q5), and it costs one edit on amsterdam (28 → 27).
- **Create-file recipes on prague fall from 10 to 9 with the list.** That is the surcharge's reservation, not the
  list's gas: with the list's gas and no surcharge the batch stays at 10.

## 5. The size plan

All sizes are runtime bytes from `FOUNDRY_PROFILE=ci forge build --sizes`, **measured** in scratch copies of
`018e290` (section 8). The project budget is 19,660 B a unit.

### 5.1 `LedgerIngress` (19,264 B, 396 B left)

| build | size | Δ | fits |
|---|---:|---:|---|
| today | 19,264 | | |
| D2, straightforward: struct decode, the new fields, Solidity branches (`v3b`) | 19,974 | +710 | **no** |
| D2, rows added in assembly, reply copied into a memory struct (`v3e`) | 19,192 | −72 | yes |
| **room idea A alone, on formula 2: read `workModel()`'s reply as raw words (`v2opt`)** | 18,499 | −765 | |
| D1, smallest diff: one new field, struct decode (`v3m`) | 19,351 | +87 | yes (309 left) |
| D1, two rows, raw read (`v3k`) | 18,379 | −885 | yes |
| **D2, two rows plus the surcharge, raw read (`v3g0`), recommended** | **18,537** | **−727** | yes (1,123 left) |
| D2 plus the WITHDRAW row of Q6 (`v3w`) | 18,453 | −811 | yes |

Where the bytes go (`node tools/attrib.mjs out/LedgerIngress.sol/LedgerIngress.json --diff <today's report>`, D2
recommended): `_foldAndQuote` 1,787 → 649 (−1,138: the ABI decoder of the 17-field struct and its memory copy, inlined
at each of the four callers), `_foldOne` 3,180 → 2,622 (−558), selector wrappers −276, `_ack` +19; added `_addRow`
+363, `_workModel` +360 and `_w` +324 (the raw read and the word loads, also inlined). Net −727 (shared blocks +245).

**Room idea A: the raw read.** `IIndexReads.workModel()` returns a static struct, so its ABI reply is the struct's words
in order. The ingress copies `WORK_MODEL_WORDS × 32` bytes of the reply into fresh memory and reads word *i* with one
`mload`. There is no decoder, no per-field range check and no memory struct. It reverts `E_INDEX_RETURNDATA` when the
call fails or the reply is any other size. It drops the decoder's range checks; the index is pinned by codehash and its
work model by the manifest hash, so no unchecked value can reach it that the Realm did not commit to. The scratch copy
needed one fix: in Yul, `and(staticcall(…), eq(returndatasize(), n))` evaluates `returndatasize()` before the call
(arguments run right to left), so the size check must be a separate statement. Every figure above includes the fix
except `v3e` (measured before it; the fix moved the others by 1 B). Gas: the raw read and the row loads make the kernel's own share K *smaller* (**measured**, prague `FloorPlan`:
38 lone negatives −8,895, 64 tag masks −12,696, 10 create-file recipes −8,449, 61 name records −10,433), counting
idea B below.

**The other candidates.**

| idea | measured or estimated | verdict |
|---|---|---|
| Pack the work model into fewer words, read once | not built. The raw read already removes the decoding cost that packing would save, and packing would add a shift and a mask per field (**estimated** +150 to 250 B for 26 fields) | not needed |
| One pass instead of per-term multiplications | partly what the rows do (three loads and adds per bind instead of four field reads) | taken, inside the rows |
| Move the quote out of the ingress (into the index, or a new view contract) | **estimated**: one more CALL per publication (2,600 cold plus the action list as calldata, about 9 words an action), and the quote's code duplicated in the index | not needed; rejected on the hot path |
| Trim something else in the ingress | not needed after idea A | |
| Raise the budget | not needed. The budget keeps every unit deployable on chains without EIP-7954 (24,576 B) with headroom, and keeps code-deposit state gas bounded under EIP-8037 (1,530 a byte) | not proposed |

### 5.2 The other contracts the change touches

| contract | today | D1 (two rows) | D2 | D2 + HEAD list (position-authors) | D2 + HEAD list (own family 22) |
|---|---:|---:|---:|---:|---:|
| `RealmIndex`, work model in storage (today's way) | 18,834 | (not built) | 19,207 (+373) | 19,386 (+552; 274 left) | 19,827 (**over by 167**) |
| `RealmIndex`, work model as a data contract (room idea B) | 18,260 (idea B alone, on formula 2) | 18,274 | 18,323 (−511) | **18,502 (−332)** | 18,943 (+109; 717 left) |
| `IndexReads` | 12,431 | 12,757 | 13,002 | 13,002 | 13,002 (the declaration is constructor code) |
| `IndexDeployer` (not a release unit) | 6,624 | 6,740 | 7,124 | 7,124 | 7,124 |
| `LedgerCore`, `LedgerControl`, `LedgerViews`, `LensReader` | 15,029 / 18,042 / 18,575 / 17,399 | unchanged | unchanged | unchanged | unchanged |

`LedgerCore` embeds the ingress's address and codehash as immutables, so its *code* changes with any ingress change;
its size does not. `LensReader` reads the manifest's profiles at word `4 + WORK_MODEL_WORDS`, so its code changes (one
constant); its size does not. `LedgerViews` does not serve the work model. The kernel's revision row copies `Limits`,
not the work model.

**Room idea B: the work model as a data contract.** `RealmIndex`'s constructor writes `abi.encode(work)` as the code of
a data contract after a STOP byte (the same holder `IndexReads._holdCopy` uses for the manifest copy), and
`workModel()` answers with one `EXTCODECOPY`. It saves 574 B on formula 2 and 511 B with formula 3. On the hot path the
call costs 3,876 gas against 6,631 today, because no storage slot is read (**measured**, one `-vvvv` trace each, the
index warm). It costs one more contract per generation: **estimated** 832 B of code, about 0.2M gas to deploy on
prague and about 1.5M of state gas on amsterdam (832 × 1,530 + 183,600), once.

**The HEAD list itself, measured as a minimal fold in `RealmIndex`.**

- **Into `position-authors` (family 20), +179 B.** The first-statement branch appends the HEAD position's authors entry
  (counted for a yes, UNCOUNTED for a no) and nothing else. `_authorsKept` gains HEAD, so the existing restore and
  mask branches move the yes-count. No new family id, store or reader. The list is then exactly "everyone who made a
  HEAD statement on this file", keyed by the HEAD position, with `live` the authors whose HEAD is BOUND now.
- **As its own family `head-authors` (kind 22) in the genesis posting store, +620 B**, above the 150 to 300 B
  estimate: one more immutable, one more branch in the first-statement path and a second retain/release pair, each
  inlined. It fits only with room idea B (18,943 B). With the work model in storage it is 167 B over (19,827 B).
- The list's gas is the same either way (one more entry in the append batch the statement already sends).

**What is recommended:** idea A in the ingress and idea B in `RealmIndex`, and the HEAD list in `position-authors`
(Q4). That is `LedgerIngress` 18,537 B (1,123 left), `RealmIndex` 18,502 B (1,158 left) and `IndexReads` 13,002 B.

## 6. Everything else the change moves

### 6.1 Identities

- **`WORK_MODEL_WORDS`** 17 → 26 (D1 two-row build: 19; smallest diff: 18). `test/index/IndexReadsSplit.t.sol` fails
  until it matches the struct.
- **The manifest hash** moves (the work model is encoded inline in `manifest()`), so **`indexObligations`** moves, so
  every signed plan's commitment and every unsent signed plan is void (design Q11). The release digest, plan hash,
  execution set, index and reads addresses all move with it.
- **`workModel()` reads**: `IIndexReads.workModel()` keeps its selector but its return tuple changes. The
  `IIndexReads.json` ABI snapshot moves. `RealmIndex.workModel()` answers from the data contract (idea B).
- **The kernel's revision row**: no copy of the work model, no change.
- **The layout id does not move.** No ledger storage changes; the layout tool covers ledger storage only.
- **The hot ABI id does not move.** It is computed from `ILedgerHot` alone, which does not change.
  `ILedgerCommitments.indexFloor` keeps its signature. The store ABI ids do not move. The HEAD list in
  `position-authors` changes no store. As its own family it changes the posting store's `FAMILY_IDS` constructor data,
  not its ABI.
- **Code that changes**: `LedgerIngress`, then `LedgerCore` (immutables), `RealmIndex`, `IndexReads`, `LensReader`
  (the constant), `IndexDeployer`.

### 6.2 Tools, model, release

- `tools/deploy-plan.mjs` `WORK_MODEL` (values and field names, `formulaVersion: 3`). The schemas
  `efs-deploy-plan-1`, `efs-deployment-1` and `efs-gas-model-1` list the fields by name.
- `gas/model.json` `floor.workModel` and the formula prose (`tools/gas-model.mjs` line 246). Then regenerate the model
  on both profiles (`pnpm gas:model`), because K moves (section 5.1).
- `tools/gas-plan.mjs` `quote()`: the two rows and the surcharge. A planner bind action needs its purpose. Today's
  actions carry only a cost key, so add `purpose` (the scratch planner inferred it from the key, which is enough for
  the 18 shapes). `tools/gas-plan-later.mjs`' example generation becomes a HEAD surcharge instead of general
  increments. Regenerate `test/vectors/floor-plan.json` (`tools/release.mjs`), then `pnpm release` and
  `pnpm release:check`.
- `tools/efs-fixture.mjs` `verify` compares the work model field by field from the ABI's own names, so it follows the
  struct. Its sources (deploy plan, deployment, release, model) must all be regenerated.
- The scratch planner's formula-3 quote, which produced section 4:

```js
const row = a.first ? "First" : "Later";
fresh10 += wm[`freshPerBind${row}`]; rw10 += wm[`rwPerBind${row}`]; compute += wm[`computePerBind${row}`];
if (wm.surchargePurpose && purposeOf(a) === wm.surchargePurpose) {
  fresh10 += wm[`surchargeFresh${row}`]; rw10 += wm[`surchargeRw${row}`]; compute += wm[`surchargeCompute${row}`];
}
```

### 6.3 The SDK (read from `sdk-v2` `origin/main` `d0359fc`, not changed)

The SDK vendors the model and the ABI and has its own copy of the quote. A consumer must change:

- `packages/sdk/src/actions/split.ts` `kernelQuote` and the `FloorModel` work-model type: the two rows by first or
  later statement, and the surcharge by comparing `action.purpose` with `surchargePurpose` (the SDK's actions already
  carry the purpose word).
- The generated files `packages/sdk/src/generated/gas.ts` and `abis.ts`, the fixture `fixtures/rpc/deployment.json`,
  the vendored `packages/solidity/src/interfaces/Index.sol`, and `test/split.test.ts` (it restates formula 2's rewrite
  sum).
- A planner that ignores the surcharge under-quotes HEAD statements under D2, and the kernel then refuses them with
  `E_INDEX_GAS`. It never admits them unindexed. So the SDK should ship with the contracts' re-vendor, not after.

### 6.4 Tests that pin a quote or the struct

`FloorPlan.t.sol` (the vectors), `FloorStates.t.sol`, `FloorReconcile.t.sol`, `IndexFloor.t.sol` (its amsterdam
"64 lone negatives do not fit" assertion still holds: V 17.39M against 16.60M, measured), `HeadAuthorsFloor.t.sol` with
`test/harness/HeadAuthors.sol` (the example's increments become a HEAD surcharge; it passes that way in the scratch
copy), `RealIndex.t.sol` (`formulaVersion`, a hand-written fresh-slot sum), `unit/Doubles.t.sol` (every value),
`atomicity/Ordered.t.sol` (sets `computeBase`), `IndexReadsSplit.t.sol`, `readers/LensFaulty.t.sol` (the profile
offset), `test/harness/doubles/IndexDoubles.sol` (the values), and `tools/test/gas-plan.test.mjs` and
`release-pricing.test.mjs`. In the scratch copies, with those patched, every floor suite passes on both profiles.

### 6.5 Formula versioning: one activation, no side-by-side

- **Today nothing checks `formulaVersion`.** A formula-2 ingress given a formula-3 index ABI-decodes the 26-word reply
  as 17 fields (the decoder accepts a longer reply). It then reads the wrong words: word 6, `freshPerRef` = 30, is
  taken as `freshPerBindFresh`, and so on. That is a silent mis-quote, not a refusal.
- **A formula-3 ingress given a formula-2 index refuses every publication** (the raw read wants exactly 26 words). That
  fails closed.
- **Recommendation:** the formula-3 ingress also requires word 0 = 3 (**estimated** under 20 B). The activation check
  in `LedgerControl` (1,618 B left) refuses a candidate index whose `workModel().formulaVersion` is not the one the
  candidate ingress implements (**estimated** 40 to 80 B). The kernel and the index then change in one activation.
- **The ingress need not keep formula 2.** No persistent Realm exists, and Q52 belongs before the first one. A fixture
  Realm moves by an activation that installs the new implementation and replaces the index together. That voids unsent
  signed plans, which Q11 already accepts. It is assumed, not checked here, that one activation can carry both; step 1
  should confirm it. Keeping both formulas would cost a version branch and a second quote in the ingress, against no
  Realm that needs it.

## 7. Open questions and the order of work

### 7.1 Questions for the reviewers (each with a recommendation)

1. **Fitted or strictly componentwise compute?** Fitted (this proposal): slot counts at the largest measured, compute
   from the dearest whole shape at ≥ 1.035 / 1.05. Strict: compute ≥ the largest "other" of the class, which costs
   prague lone negatives 38 → 36 and restores 63 → 58. *Recommend fitted.*
2. **The per-purpose shape.** *Recommend (a), one surcharge entry.* A table can come later as a formula 4.
3. **Ship the surcharge fields even if Q52 is no?** They cost 158 B and about 20 to 40 gas a bind (estimated from the
   89 gas measured for a two-bind publication). A later per-purpose list then needs no formula change. *Recommend yes.*
4. **Where the HEAD list lives under a yes. Ruled: its own family, with the data-contract saver.** The reasons:
   coverage is per family id, so a later generation that stopped keeping HEAD entries inside family 20 could not say so,
   and a HEAD key would answer stale counts as COMPLETE; with its own family, dropping it is leaving one family
   undeclared, and every reader answers UNKNOWN. A size hint for that step (untested): one helper that returns the family
   id and key kind for a purpose (0 for none), used by the three existing branches, in place of a second retain/release
   pair. The recommendation below is the proposal's, superseded: In `position-authors` (+179 B, no new family) or as its own family 22
   (+620 B, needs room idea B). *Recommend `position-authors`*, with the tag design session checking that a
   `position-authors` reader keyed by a HEAD position reads as "everyone's versions of this file".
5. **Exempt HEAD re-binds from the later surcharge?** It would be one more test in the ingress (BIND on a BOUND head,
   **estimated** 20 to 30 B) and would win back one edit on amsterdam (27 → 28). *Recommend not now.*
6. **Quote a WITHDRAW as a later statement?** It is quoted 0.12× / 0.14× per extra withdraw today. It is not one of
   the floor's claimed shapes, so it is refused near the floor, never admitted unindexed. The later row covers it
   (114.2k / 122.6k against 67.7k / 57.8k). Measured −84 B (the second call site changed the inliner's choice).
   *Recommend yes, in the same change.*
7. **Room ideas A and B.** Both save bytes and gas. *Recommend both.*
8. **Version checks.** *Recommend the ingress check (word 0 = 3) and the activation check* (6.5).
9. **`rwPerPublish` hides compute.** It quotes 4.6 rewrites per publish, but a publish's rewrites are per publication
   (measured 0.00 per extra action). No planned shape is limited by it today: publish-heavy batches are already at 61
   to 64. *Recommend leaving it to a later formula,* noted here so it is not forgotten.
10. **The deep first tags exception.** *Recommend leaving it as it is* (3.6).
11. **The thinner amsterdam margin** (lowest 1.039 against 1.26 today). The gas model's 15% headroom and
    `eth_estimateGas` stay the sender's guard; the floor only has to stay above the callbacks' spend. *Recommend
    accepting it,* and committing the split suite (step 1) so a regression is seen.

### 7.2 The order of work (each step on a branch, reviewed by the integration owner, then merged)

1. **Kernel and index: formula 3 with the surcharge fields set to zero.** `Index.sol` (struct, `WORK_MODEL_WORDS`),
   the ingress (raw read, rows, surcharge, version check, WITHDRAW row if Q6 is yes), `RealmIndex` (data contract),
   `IndexReads`, `LedgerControl` (activation check), the harness values and the tests in 6.4. Commit the scratch split
   suite as `test/integration/FloorSplit.t.sol`. Regenerates the `IIndexReads.json` ABI snapshot, the attribution
   report and the sizes.
2. **Tools and release:** `deploy-plan.mjs`, the three schemas, `gas-model.mjs` prose, `gas-plan.mjs` (with a purpose
   on bind actions), `gas-plan-later.mjs`. Regenerates `gas/model.json` (both profiles), `test/vectors/floor-plan.json`,
   `release/*` and the fixture's verify sources.
3. **Docs:** DESIGN §5.11 and §10.4 (the formula, the corrected "later statements write a fresh slot"), INDEX-BUILD
   §6.2 and §10 item 27, TAG-NUMBERS' largest-publication table, a RELEASE item, and QUESTIONS Q52's consequence (the
   38 → 32 sentence no longer holds).
4. **Only after Q52 is answered yes:** the HEAD list in `RealmIndex`, generation 1's HEAD surcharge values, a test of
   the list's contents and its floor in both states. Regenerates the model, the vectors and the release again.
5. **The SDK re-vendor** (6.3), with the contracts' steps 2 and 4. Each regenerated release moves the SDK's pin.

Steps 1 to 3 do not wait for Q52. A "no" ends the work there. A "yes" adds step 4 and leaves the struct, the ingress
and the SDK's formula alone.

## 8. How the figures were made

Scratch copies (none committed), each `git archive 018e290`, with their own `pnpm install --frozen-lockfile` and
`forge soldeer install`. Forge always ran under `perl -e 'alarm shift; exec @ARGV' 3000`, and amsterdam always with
its own `FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam`.

| copy | what it is |
|---|---|
| `base` | `018e290` plus the scratch suite `test/scratch/MeasureV3.t.sol` (section 2's formula-2 rows; FloorPlan's K) |
| `v3a`, `v3b`, `v3c`, `v3d`, `v3e`, `v3f` | size experiments: one new field; D2 straightforward; raw read into a struct; rows in assembly; pointer reads |
| `v2opt` | formula 2 with room ideas A and B only |
| `v3m` | D1, smallest diff (one new field) |
| `v3k` | D1, two rows, ideas A and B |
| `v3g0`, `v3g1`, `v3g2` | D2 with idea B: no list; the list as family 22; the list in `position-authors` |
| `v3h1`, `v3h2` | D2 with the work model in storage, with each form of the list |
| `v3w` | D2 plus the WITHDRAW row |
| `v3t0` | D2 code with generation 1's formula-3 values and no list, the harness patched, vectors regenerated: every floor suite and `MeasureV3Test` on both profiles |
| `v3t2` | the same with the list in `position-authors`, first with no surcharge, then with the HEAD surcharge and its own vectors |

The planner runs were `tools/gas-plan.mjs` with the five-line quote of 6.2 over `gas/model.json` at `018e290`, whose
`floor.workModel` was replaced. Its formula-2 path reproduces the committed `test/vectors/floor-plan.json` exactly.

## 9. Where the measurements disagree with what was assumed

1. **Today's amsterdam lone-negative batch is 50, not 54.** 54 was the figure before RELEASE.md item 39. Formula 3
   gives 53, with or without the HEAD list.
2. **Later statements are not "all rewrites and compute"** (design §10.4). *Precision (landed):* the fresh slot is the
   binding's history list (family 8) and, for a re-bind, the new target's backlink entry; the posting store packs five
   entries per word with the first in the head, so a binding's statements 2, 6, 11, 16 and so on open a slot and the rest
   rewrite (`PostingStore._append`: count 1 materializes word 0 with the inline first entry; counts 5, 10 and 15 open
   words 1, 2 and 3). The mask, release and re-bind rows measure a binding's second statement, the worst case for them.
   The restore rows measure a third (yes, mask, yes), whose history append rewrites word 0, so a restore that is a
   binding's second statement, a yes after a lone no, writes one fresh slot more than its row (§3.5). Each measured
   later statement writes one fresh posting-store slot, and a re-bind writes two. Formula 2 quotes them no fresh slot. On prague its 16 rewrites at 5,000 happened to cover
   that. On amsterdam each of those fresh slots also costs 97,920 of state gas.
3. **A WITHDRAW is under-quoted 0.12× / 0.14×** for each withdraw after the first in a publication (not a claimed
   shape; refused near the floor, never admitted unindexed).
4. **The HEAD list as its own family costs 620 B, not 150 to 300 B.** In `position-authors` it costs 179 B.
5. **The genesis HEAD list does not need the per-purpose term to stay above 1 on prague** (the TAG-sized rows cover a
   HEAD statement plus the list). On amsterdam a restore with the list is covered only 1.01× and rewrites more slots
   than the row quotes, so honesty needs the surcharge.
6. **"The honest reservation adds that fresh slot to every first bind of any purpose"** is right for formula 2 (the
   reference column of section 4: lone negatives 38 → 34 on prague). Under formula 3's surcharge it does not hold:
   lone negatives stay at 38.
7. **The 396 B was not the constraint.** The straightforward formula 3 does not fit (+710 B), but reading the reply as
   raw words takes 765 B *out* of today's ingress.
8. **The ingress never reads `formulaVersion`**, so a mismatched kernel and index mis-quote silently in one direction
   (6.5).
9. **Formula 2 hides compute in `rwPerBind` too, not only in `rwPerBindLater`**: a first statement rewrites at most 2
   slots, and formula 2 quotes 4. Formula 3 moves those 10,000 gas into `computePerBindFirst`, which leaves prague
   exactly where it was.
