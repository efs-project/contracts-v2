# Tags: design and measured costs

**Status: this document now describes the release (2026-11-25).** It was written before the build as a recommendation
from the spike (`spike/2026-11-25-tags`, commit `a47f2e9`) and answered the work order in the planning vault's
`Reviews/2026-11-25-tag-model-spec.md` (section 9), which applies James's rulings of 2026-11-25. The proper version
was then built in the order of section 12, each step reviewed on a branch, and integrated as one release on
`fable/2026-11-25-tags-release` (the gateway split, the viewed-place check's cut and work-model formula 2 merged on
top of step 4). Everything below says what is built; what is still a choice for James is section 13 and
[QUESTIONS-FOR-JAMES.md](QUESTIONS-FOR-JAMES.md) Q49–Q54. The SDK re-vendors once, from
[tools/RELEASE.md](../tools/RELEASE.md) "What changes for a consumer in this release".

Every figure is measured on the integrated release tree; the full tables, with the commands that produced them, are
in [TAG-NUMBERS.md](TAG-NUMBERS.md). Figures marked *(estimate)* are not measured. "Today" is the Prague fee
schedule; "Glamsterdam" is EIP-8037/8038, where creating storage is priced separately (see "Depth"), and its figures
are all gas unless they say "execution". [TAG-OPTIONS.md](TAG-OPTIONS.md) is the earlier options paper; its identity
recommendation was overruled and this document replaces it. The spike's own record is
[spike/TAG-SPIKE-NUMBERS.md](spike/TAG-SPIKE-NUMBERS.md).

## In plain words

- **A topic is a path of words**, such as `/cars/tesla`. Anyone can work out its id from the words alone. Nobody owns
  it. The word `tesla` has its own page, `/tesla`, which lists every place the word is used.
- **A tag says "this thing is in this topic, with this number".** The number runs from −65,536 to 65,535 and costs
  nothing extra to store. Zero or above means the tag applies; below zero means it doesn't. "Not this" can be said
  about something you never tagged.
- **A tag on a topic that was never registered is refused.** Registering is publishing one small record per new word
  and per new path, and it rides in the same transaction as the first tag, ahead of it.
- **Anyone can attach files to any address, and tag any address,** including one that has never transacted.
- **Every tag is listed** under its topic and every parent topic, per author and across all authors. The lists are
  written at an author's first statement about a thing in a topic and never rewritten.
- **A 64-word path works.** There is no depth limit.

What it costs, one transaction with nothing else in it:

| | Today | Glamsterdam |
|---|---:|---:|
| Tag a thing in an existing 2-word topic | 0.82M | 2.89M |
| The same, plus registering one new word and its path | 1.39M | 4.68M |
| Each further tag in the same transaction (4-word topic, everything new) | 0.48M | 1.78M |
| Change a tag's number | 0.45M | 1.28M |
| "Not this" about something never tagged | 0.69M | 2.31M |
| Tag an address that never transacted | 0.75M | 2.50M |
| Register a brand-new 8-word path, every word new | 4.07M | 14.09M |
| A first tag on a 64-word path, nothing existing (worst case; the path already registered) | 4.72M | 17.68M |

For scale, creating a file today costs about 1.68M (6.04M on Glamsterdam).

## 1. Topics

Two record Types, both with rules that run when the record is published (`topic-word/1`, `topic/1`), and a third for
labels (`text/1`, section 8).

- **Word page, `topic-word/1`.** Its body is the word's bytes and nothing else. It is also the root-level topic: the
  page for the word `tesla` is the topic `/tesla`.
- **Path, `topic/1`.** A topic of two or more words. Its body is exactly two references: its parent topic, and the
  page of its last word. `/cars/tesla` is the record (page of `cars`, page of `tesla`); `/cars/tesla/model_y` is the
  record (`/cars/tesla`, page of `model_y`).

What this gives, with no new kernel code:

- **The id is the record id,** a hash of the Type and the body. It does not depend on who published it, on the Realm
  or on the chain. Two people publishing `/cars/tesla` get the same id, and the second publication stores nothing
  again. Anyone computes the id from the words with no chain read (`EfsTopics.pathId`; the SDK's twin is checked
  against `test/vectors/topics.json`).
- **Parent before child, word page before use.** The kernel refuses a record whose declared reference does not
  exist. A parent published earlier in the same publication counts, so a short new path registers in one
  transaction and a deep one splits in order.
- **Permanent.** The reference check asks "was this ever admitted". A withdrawal by the first registrant lowers a
  count and changes nothing the check or the index reads.
- **One sequence of words has exactly one record.** A one-word topic is only ever a word page, because a path record
  cannot be built without a parent and the kernel refuses a zero reference. An n-word topic is exactly one path
  record. A path whose parent is a file, a folder, a name or any other Type is refused.
- **Both directories exist already.** The index keeps a list per (Type, reference slot, referenced record). Slot 0 of
  path records gives a topic's children; slot 1 gives the topics whose own word is a given word, which is what a
  word's page shows (`TopicLookupReader.children`, `wordPage`).

**Word rules, checked once per word, on the word page:** 1 to 255 bytes of well-formed UTF-8; no `/` or `\`, no
ASCII control byte, no ASCII `A`–`Z`, no Unicode white space at all (every fold rule turns white space into `_`, so
`tesla` followed by a no-break space could only be a look-alike); none of the refused code points (C1 controls,
format and bidirectional controls, invisible separators, joiners and variation selectors, noncharacters); not `.`
or `..`; not starting with `~`; not `0x` followed by 40 hex digits. The last two apply to every word, not only the
first in a path, because every word has a root-level page. An address belongs in a tag as its target: tag the USDC
contract's address under `/tokens/usdc`, never `/tokens/0xa0b8…`. The check costs about 121 gas per byte of ASCII
and 478 per byte of multi-byte text. Everything else about folding (Unicode case, look-alike letters,
normalisation) stays in the SDK; the chain cannot check it. The refused table is one constant
(`TopicProfile.REFUSED`, from Unicode 15.1) shared with the SDK's vectors; it is hand-written until one generator
produces it from a pinned Unicode version (Q53), so the three Topics Type ids are provisional until then.

**Cost.** A word page is 0.54M alone and 0.21M as an extra action in a batch (1.65M / 0.70M on Glamsterdam). A path
record is 0.65M alone and 0.28M in a batch (2.11M / 0.95M).

## 2. The tag and its number

A tag is a bind at position (TAG, topic, thing), targeting the thing.

- **The number rides in a field the action already has.** The action's field is now `saltOrStrength`: on BIND and
  UNBIND it carries an unsigned strength from 0 to 65,535. BIND means number = strength. UNBIND means number =
  −1 − strength. So every action written before keeps its meaning (a bind is 0, a mask is −1) and no (kind, value)
  pair is meaningless. A strength above 65,535 is refused, never truncated. RELEASE means "I say nothing" and
  carries no number.
- **No new storage.** The head row's 40-bit expiry field narrowed to 32 bits (seconds until 2106) and the number took
  16; bind rows in the admission log carry it in a 16-bit field that was always zero for binds.
- **A first statement may be negative.** UNBIND is admitted from every state: never said, asserted, denied and
  released. This applies to every purpose, with no gate in the kernel, which knows no purposes.
- **Changing only the number keeps history.** A positive to another positive is a BIND to the same target; a negative
  to another negative is another UNBIND. Each is one action under the usual revision check, and each adds a history
  entry.
- **What can be tagged.** Any record or subject that exists, of any Type, including one this repository has never
  seen: a file, a folder, a topic, a specific revision of a file. And an address.

| Operation on an existing tag | Today | Glamsterdam |
|---|---:|---:|
| Change a positive (0 → 75) | 448,570 | 1,281,550 |
| Change a negative (−1 → −5) | 426,776 | 1,171,736 |
| Positive to negative | 458,649 | 1,217,975 |
| Negative to positive | 521,153 | 1,537,339 |
| To silent | 425,843 | 1,170,803 |

A nonzero number costs 12 gas more than zero.

**The validator's laws, in plain words** (`FilesFinalValidator`, refusal codes 1 to 16). It judges only HEAD, FOLDER,
TAG, SAME and BROADER, and only a statement that asserts something or creates a new position for its author: an
author can always mask or release a binding of theirs that already exists, and no law refuses that.

- **Folders.** 1: a folder entry needs a name record. 2: its parent is a folder or a home (an address). 3: an entry
  cannot point at its own folder. 4: a file it names must already exist. 5: a record it names must be a folder.
  6: nothing else may be named, an address included (it would confirm and never be readable). Codes 1 and 2 apply
  to a first "not this" too, so it can only be said about an entry that could exist.
- **A file's HEAD.** 7: never an address. 8: it names a revision record of that same file. 16: a first "not this"
  names a file, a subject created strictly before it (as 15 does for tags). Anything that can have a version is such
  a file, so this never stops anyone saying "not this" about something others can publish a version of.
- **Tags.** 9: a first statement (either sign) sits under a home or under a topic registered strictly before it, in
  an earlier action (a topic registered later in the same publication would silently miss its list entries). A build
  or replay does not lean on this law: it reads as of each admission ([INDEX-BUILD.md](INDEX-BUILD.md) §4.3), so it files what the
  live fold filed even over history that no validator judged.
  14: a tag's target is the thing it names (its role). 15: a first "not this" names something that exists: a record
  or a subject admitted before it, or an address.
- **`same` and `broader`.** 10 and 11: both ends are topics registered strictly before; 12: the two ends differ;
  13: the target is the other end.

## 3. Addresses: homes, targets and links

- **A home's id is the address itself,** as a left-padded word. That is the same value as a key account's principal
  id. A record id or a minted subject id is a hash, so one that looks like an address would take about 2^96 tries;
  the two forms cannot be confused. The zero address is not a home (the kernel refuses a zero subject).
- **Attaching.** A named entry whose parent is address-shaped is accepted with no check on the address: it needs no
  code, no balance and no history. Creating a file at a home that already holds files costs 1.61M against 1.70M
  in a folder with files today (5.61M / 6.10M on Glamsterdam). The folder page reader and lens reader work on a
  home unchanged.
- **An address as a tag's target.** A third target kind, ADDRESS, admits an address-shaped target that is neither a
  record nor a subject. The validator allows it for TAG only.
- **A contract's home** is its raw address, but a contract's principal id is not (it is qualified by the Realm). The
  gateway and the SDK compute "the owner's entries" for a contract home from the contract principal.
- **Folders have a fixed identity.** A folder is a record of (creator, salt) that only its creator can publish, so
  the kind of an object follows from its id. Remove and move release an entry; hide masks it (a mask stops the lens
  walk, so it hides everyone's entry at that name; a release never does).

**What `web3://` serves** (one link grammar; `EfsWeb3Gateway` parses, `EfsWeb3Content` serves the bytes). The first
path segment decides the kind of path:

- `/0x<address>/name/…`: that address's home, read by default through the address's own entries.
- `/~efs/o/<id>/…`: an object link. A folder id is that folder (read through its creator by default); a file id is
  that file's current version.
- `/~efs/v/<revision id>`: exactly that version's bytes, whoever's version it is and whether or not it is current.
- Any other `~` path is the system's and refused (400); any other first word is a topic path, which this gateway does
  not serve yet (501). No folder is ever served at a topic path, so a topic link can never mean a folder.
- An existing object the gateway does not serve is 501, never 404; 404 means the id names nothing. `?lens=` replaces
  the default authors.

## 4. The lists

Every list is append-only. An entry is written at an author's first statement on (topic, thing), whatever its sign;
later changes, removals and re-adds write no list. A reader takes the current state and number from the statement
itself.

| List | Key | Written when | Purposes |
|---|---|---|---|
| Per author, exact | (author, purpose, place) | the author's first statement at a position | all |
| Per author, this topic and below | (author, TAG, ancestor) | the author's first statement, once per proper ancestor | TAG |
| All authors, a place's filings | (purpose, place) | the first statement by anyone at a (place, item), and every later author's first yes there | TAG, FOLDER |
| All authors, who said it | the (place, item) position | every author's first statement there | TAG, FOLDER |
| All authors, this topic and below | (TAG, ancestor) | as the place's filings, once per proper ancestor | TAG |
| All authors, where a thing is filed | (TAG, thing) | the first statement by anyone at that (place, thing) | TAG |

- **Two levels for all authors, with two figures each.** One list of a place's filings, and one list per item of who
  said it. A place's list files an item at its first statement and again at every later author's first yes, so a
  real tag after someone's early "not this", or a second person's `hello.txt` at a home, shows as new, and whoever
  speaks first does not fix where an item sits. Its head gives two figures in one read: **filings**, and an **"about"
  count** of distinct items ever stated (including items nobody says yes to now). An item's head gives how many
  people ever made a statement about it and, **exactly, how many say yes now** (a counter moved by first yeses, masks,
  releases and restores; one read, no scan). A later author's first no, and a yes after an author's own first no,
  file nothing. Buckets by name hash were considered and rejected: a spammer picks names that fall in the victim's
  bucket, so a targeted attack is not bounded.
- **Every statement is reachable from its target, whatever its sign.** A lone "not nsfw" carries no target, so "what
  points at this" never shows it; the last list in the table fixes that for every kind of target.
- **Not kept:** all-authors lists on HEAD (a storage slot per file, and nothing reads it), per-word lists of items,
  and "where a name is used" for FOLDER.
- **Can the HEAD list be added later? Yes, at a price, and with one condition.** Every list is derived from the
  kernel's permanent record of statements, so a later index generation can add a list and build it from history
  into a fresh store before it is switched on. That build step is written and tested: a test harness generation
  carries the genesis stores, adds exactly this list (everyone's versions of a file) in a third store, builds it from
  history and is switched on, and its lists equal those of a Realm that kept the list from genesis, key by key
  ([INDEX-BUILD.md](INDEX-BUILD.md) §2.2, §8; the list and its generation are an example, not product). The build's cost
  is measured (step 4, [INDEX-BUILD.md](INDEX-BUILD.md) §6): a build walks the Realm's whole history, about 478k gas
  per file today (576k on Glamsterdam, state gas included) against about 51k (150k) to keep the list from the start,
  9.3 times (3.8 times) as much; 10,000 files cost about 4.8 billion gas in some 286 transactions, a million files
  about 478 billion in some 28,500. So adding it later is realistic for a small or young Realm and an indexer is the
  route for a large one. The condition: adding a
  generation is an act of the Realm's controller, possible until the Realm is frozen, so the option exists only while
  the Realm is not frozen (Q52).
- **Rebuild equals live.** A test drives a mixed history through the live index, replays it into a fresh index, and
  compares every list.
- **The topic lists exist only with their validator.** The index keeps them only when its own fixed list of units
  contains the profile validator built for the same two topic Types; its constructor refuses any other
  combination, so no Realm can keep topic lists without the "registered before" law that makes them complete. The
  law is what makes the LIVE lists complete; a build from history is exact without it, because the ancestor walk
  then compares the subject's first admission with the tag's (the as-of rule, [INDEX-BUILD.md](INDEX-BUILD.md) §4.3).
- **A Realm that admitted tags before it had the validator.** There the roll-ups hold what a live fold filed, which
  is less than the law would have given: (a) a roll-up's distinct-things count is a floor, not exact; (b) a tag made
  before its topic was registered is never rolled up later by its author, because a first statement files once and
  the author's later changes file nothing; (c) live and built agree on this (a build reads as of the admission), so it
  is a property of that history, not a defect of a build. Example, from `test/index/BuildAsOf.t.sol` (Realm U, no
  validator): Alice tags a thing under `late-0/late-1` before that topic exists, then the topic is registered, then
  Bob says yes at Alice's position and Carol tags a new thing there. The `place-below` list at the word page
  `late-0` ends with count 2 and live 1 although it lists two distinct positions: Bob's yes is a later author's first
  yes at a position that already existed, so it is filed uncounted, and Alice's fresh filing of that position never
  rolled up; only Carol's fresh position counts.

**A first tag, by depth** (one statement alone in its publication; Glamsterdam all gas):

| Case | 1 word | 4 words | 8 words | 64 words |
|---|---:|---:|---:|---:|
| Everything new, today | 0.73M | 0.92M | 1.17M | 4.72M |
| Everything exists, today | 0.61M | 0.73M | 0.89M | 3.10M |
| Everything new, Glamsterdam | 2.60M | 3.31M | 4.27M | 17.68M |
| Everything exists, Glamsterdam | 1.92M | 2.12M | 2.39M | 6.21M |

Per extra path level: the per-author roll-up is 34.6k gas on a new list and 22.9k on an existing one (122.7k and
37.3k on Glamsterdam); the all-authors roll-up 27.1k and 15.4k (115.2k and 29.8k), paid at every filing.

**Ordinary file work:** creating a file pays a "who said it" list and, at a fresh position, a place filing: about
56k–62k more (3.6–4.0%) than before the lists, measured at step 3b; an edit writes no list.

## 5. Depth and the planning rule

- **Today, a single first tag fits one transaction to about 254 words** in the worst case and 401 when everything
  exists (a lone negative where everything exists: 627).
- **On Glamsterdam the answer depends on a rule I had checked.** EIP-8037 says the 16.78M per-transaction cap applies
  to execution gas only; gas for creating storage is paid from a separate reservoir. On that reading the worst-case
  64-word tag is 3.28M of execution gas and fits, and the deepest path is about 366 words. If all gas counted against
  the cap, the worst case (17.68M) would not fit and the limit would be about 60 words. Both readings are in the
  tables.
- **A block must still have room.** A block's usage is the larger of its execution gas and its storage gas; the
  worst-case tag carries about 14.4M of storage gas, which fits any plausible block.

**If the Glamsterdam rule changes before it activates** so that all gas counts against the cap, the worst case is
60 words, under the 64 the ruling requires. Nothing is built for this; two options, neither of which ever skips a
level: open a topic's shared roll-up list when it is registered *(preferred; computed: the 64-word worst case falls
to about 12.30M all gas, for one more list head per registered topic, 27k today and 115k on Glamsterdam)*, or a
roll-up continuation, a new action kind that finishes a tag's remaining levels later *(the fallback: a real
addition to the kernel)*.

**Registering a brand-new path, every word new:**

| Words | Today | Transactions | Glamsterdam, all gas | Execution only | Transactions |
|---:|---:|---:|---:|---:|---:|
| 8 | 4.07M | 1 | 14.09M | 3.01M | 1 |
| 16 | 8.08M | 1 | 27.96M | 5.91M | 1 |
| 32 | 16.32M | 1 | 56.25M | 11.85M | 1 |
| 64 | 33.49M | 3 | 113.80M | 24.19M | 2 |

The Glamsterdam counts assume the execution-only reading. The 64-word registration carries about 89.5M of storage gas
over two transactions; under a 60M block gas limit *(my assumption)* each half fits one block. **Wallet prompts for a
first tag on a brand-new path** *(estimate, registration and tag combined)*: up to 16 words one transaction, so one
prompt; at 32 words two today and one on Glamsterdam; at 64 words three today and two on Glamsterdam; a wallet batch makes each of these one prompt, and the bounded session grant makes them
none. Registration parts are safe to send first and harmless if the save is abandoned.

**The planning rule and the floor.** Before each index call the kernel requires a floor of visible gas, priced from
the index's work model in slot counts (DESIGN §10.4, formula 2). The release fixes the spike's finding: the final
reserve per bind is 7,400 (it was 120,000), and three terms
keep the quote above what the index spends (later statements, publishes of existing records, the final phase per
publish). The floor does not know a tag's depth; the gas model does. So the SDK plans every publication from the
published gas model (`planning`, `floor`, the per-level terms; `tools/gas-plan.mjs` is the reference planner): a
publication is planned when it is inside the Realm's limits and its estimate and the floor's requirement both fit
under the cap less 15%, and anything larger is split before it is signed. The largest planned publication of each
of seventeen shapes is tested on both schedules (TAG-NUMBERS "The largest publication"): for example 38 lone
negatives today and 50 on Glamsterdam, 18 and 19 first tags at depth 8, 3 at depth 64, 10 and 12 create-file
recipes, 64 masks or releases today and 44 on Glamsterdam, and 64 registration pages on both. On Glamsterdam the floor
prices a rewrite of an existing slot at 12,100 (its real execution price there; it was 5,000), which makes the quote
cover what the index spends in every state and lowers the largest batch of later statements (masks, releases,
restores, number changes) and folder re-binds; 64 lone negatives no longer fit one Glamsterdam publication. `indexFloor` is an upper bound only; the fixture checks that
the deployed index prices exactly like the published model.

## 6. Reading

Three readers, all through the read facets (no raw storage): `TopicMineReader` (my lens), `TopicEveryoneReader`
(the public views) and `TopicLookupReader` (one position's authors, a thing's places, counts, word pages,
children).

- **Raw** shows every row of a place's lists. **Everyone** shows a row only when its item's yes-count is above zero
  (somebody says yes now; one exact read, never a scan), unless a lens author denies it. **Mine** reads only the lens
  authors' own lists.
- **The lens order, with one combined walk.** An earlier lens author always beats a later one. For an entry filed
  under topic T and viewed at place P (P = T in an exact view, an ancestor below), each lens author in order is asked
  two things: is it "not this" about the thing at the viewed place, and what does it say where the entry was filed.
  The first answer found decides; the row carries the **decider** (which lens author decided it) and that author's
  number. A stranger's negative never hides a row somebody affirms.
- **The viewed-place check is cheap where it cannot matter.** It reads only head states, and leaves out a lens author
  whose list at the place has nothing masked and, with at least four authors to ask, a position nobody ever stated
  anything at.
- **De-duplication by thing.** A thing filed at two child topics, or filed again by a later author's first yes,
  appears more than once in a list. A page shows each thing once, through its newest filing that shows; the
  yes-count and the lens are checked before a thing counts as seen, so a newer filing nobody affirms never hides an
  older affirmed one. Across pages the SDK removes repeats.
- **Two bounds.** A paged read takes `limit` (list entries read) and `maxRows` (rows returned) and stops at whichever
  comes first, or at its gas reserve. A short or empty page is not the end: every page says whether the list is
  finished and where to resume. One number cannot bound both, because skipping a padded stretch is cheap and a shown
  row under a large lens is not.
- **Only complete lists are read.** A view answers from a list only when the index reports the list's coverage
  COMPLETE. A list the index reports PARTIAL (a later index generation still building it from history) is treated
  exactly like one it reports UNKNOWN: the view, count views included, answers UNKNOWN with no rows and no counts,
  and one such list refuses the view whatever the others report, including a listing resumed after the list stopped
  being complete. Two reasons. A list's PARTIAL would not survive paging, because every page that does not start at
  the origin and finish already says PARTIAL for its own paging, so a listing missing rows would end looking like an
  ordinary long one. And the rows could not be promised, because Everyone decides from the yes-counts of
  `position-authors`, and nothing says what a partly built list's counters hold. Reading a partly built list (newest
  pages while old history is built) would be a new reader contract, designed with that feature, with a list-coverage
  field of its own that survives paging. A live index is always complete, so no page of a real Realm changes. A
  page's own coverage is unchanged: COMPLETE only when it started at the origin and finished, PARTIAL otherwise.
- **The frontier.** Every page also says how far down the listing it got: `frontier` is the entry the next page
  reads first, the newest entry not yet processed, in the number space of the view's row entry (binding ordinals in
  Mine, Everyone and the thing's places; admission ordinals in an item's authors, a word's page and children). A
  view over two or more lists merged gives the largest of each list's next unread entry. On every page that is
  served:
  1. `frontier` is 0 exactly when the listing is finished (scan status EXHAUSTED); entries are never 0, since both
     ordinals start at 1. Every refusal (UNKNOWN, BASIS_STALE, UNSUPPORTED, LIMIT_EXCEEDED, INVALID) carries 0,
     no continuation and no counts.
  2. Every row of the page has an entry strictly greater than `frontier`, and every row any later page of the
     listing returns has an entry less than or equal to it. The lists one view merges never hold the same entry
     twice: in Everyone the place list holds filings at the place itself and the roll-up filings under a proper
     descendant, and a binding has one place; in Mine each list holds only its own author's bindings, the exact list
     at the place and the roll-up below it.
  3. It is the first entry the next page reads, so an entry already fetched into a window but not processed when the
     page stopped (after a ROWS stop, say) is still ahead of it.
  4. It falls strictly from page to page within one listing, rows or not: every page reads at least one entry. So a
     consumer merging several listings newest first can lower its floor for a list on every page, including a page
     of a padded stretch that returns no rows.

  Two exceptions, both stated in the page laws: the word page's root row on its first page is not a list entry (its
  admission is the word page's own, older than every entry), and in Mine a lens that names one principal twice
  reads that author's lists twice, so a row's entry can equal `frontier` and `frontier` can repeat (a consumer
  passes each principal once). Frontiers of different views, or of listings started at different origins, are not
  promised to be comparable. It costs nothing in Mine and Everyone (the page holds it already) and one more entry of
  the page's slice in the lookups.

| Read (cold call) | Gas |
|---|---:|
| Mine: my lens, this topic and below, page of 10, lens of 1 / 8 / 32 / 64 | 563k / 1.10M / 2.31M / 4.80M |
| The same, page of 50 | 2.43M / 3.67M / 7.58M / 11.88M |
| The same, worst case of the viewed-place check, page of 10 | 687k / 1.57M / 3.83M / 8.82M |
| Everyone, lens of 8, page of 10 / 50 (below; worst case) | 1.32M / 6.18M (1.81M / 8.69M) |
| Raw, page of 10 / 50 | 538k / 2.45M |
| A skipped entry in Everyone, any lens | 36k |
| "Anyone's `pet.jpg` at this address", 300 authors, page of 10 | 363k |
| A place's count; an item's author count | 85k; 85k |
| A word's page for 1 / 5 / 20 places | 152k / 355k / 1.07M |

- **Depth makes no difference to a read.** Depth 8 and 64 cost the same to the gas.
- **Call size.** Providers cap the gas of one read call. The release publishes the read terms and, at a 10M cap less
  10%, the bounds: keep page × lens at or below 768 (`mine` exact), 416 (`mine` below), 688 (`everyone` exact) and
  408 (`everyone` below), at most 150 rows and 245 entries per call. The SDK splits larger
  reads, so a big lens never fails as one call too big.

## 7. Spam and what stays true

- Adding one entry to a place's public list costs the spammer about 0.68M gas alone today, 0.35M each when 64 are
  batched (2.21M / 1.27M on Glamsterdam). Adding one to "who said this" at a name needs a fresh account each time
  and costs about 0.61M (1.86M).
- **Sybil bumping.** Because every author's first yes is filed, a thing can be moved to the front of a public "newest
  first" view by saying yes to it from a fresh account: about 0.68M alone, 0.34M each for one fresh account over 64
  existing things (2.22M / 1.19M on Glamsterdam). One account bumps a given thing once; the yes-count rises by that
  one author and the "about" count not at all (Q54).
- A reader pays about 36k gas to skip a junk entry in Everyone, at any lens size, and about 48k per row in Raw.
  Mine is not affected: it reads only lens authors' lists.
- **Bounded whatever the spam:** a count; a lookup of one name or item; a page at one position.
- **Not bounded:** paging through a spammed place in Everyone or Raw. The lens is the defence, and the client should
  label the public tier. Counts can be inflated at about one tag's gas per entry; show the lens count beside the
  global one.

## 8. Meaning: the three purposes for statements about topics

Built, with the label Type:

| Purpose | Position | Target | Holds |
|---|---|---|---|
| `property` | (any subject, key) | a value record, a file or an address | one value per author per key: a label per language, the definition, "moved to" |
| `same` | (topic, other topic) | the other topic | "same as", at word level between word pages and at path level between paths |
| `broader` | (topic, parent topic) | the parent | the optional booru-style parent |

- Single-valued facts share one purpose and differ by key (`label:en`, `definition`, `moved-to`;
  `EfsTopics.propertyKey`), so a new kind of fact needs no new purpose. `property`'s subject may be a topic, a home,
  a file or a folder; no validator judges it.
- **A new relation later (`related`, `part of`) needs no release.** A purpose is only a constant: the kernel accepts
  any purpose, the per-author lists and "what points at this" exist for every purpose, and the validator judges only
  the purposes it names.
- A label's text is a `text/1` record (1 to 255 bytes, one line; `/`, spaces and capitals allowed, so it can hold
  "AC/DC").
- A label's language is a BCP 47 tag, lowercased before its key is derived: `pt-BR` and `pt-br` are one key
  (`label:pt-br`), and so are `EN` and `en`. The chain cannot check this (the key is a hash), so `EfsTopics.labelKey`
  and its JS twin fold ASCII `A`–`Z` themselves; a writer that derives the key some other way must do the same.
- Each statement is one bind: `same` or `broader` costs 0.65M today (2.26M on Glamsterdam); a label with a new text
  record 0.94M (3.29M), naming an existing text 0.65M (2.27M).
- Curating a topic's children uses TAG itself: tag the child into the parent with a number.

## 9. Events for indexers

- **`Bound`**, one event per bind, unbind or release, with purpose, place, thing, target, kind, number, transition
  and target kind; a log filter on (TAG, thing) finds everything anyone said about the thing, lone negatives
  included.
- **`Body`** carries the bytes of a fresh small record of a Type that asks for it (names, words, paths, labels), so
  an indexer follows topics, labels and names from events alone. A repeat publish logs nothing.

## 10. What cannot be done in contracts

Assigned to an indexer (The Graph) or the client on purpose:

- Sorting or ranking by the number, by activity or by popularity. Lists are in first-stated order.
- Combining numbers across authors (an average, "how nsfw on the whole").
- Type-ahead, partial-word and fuzzy search. The chain answers "the page for exactly this word".
- AND, OR and NOT across large lists. Small ones work by reading one list and checking the other per item.
- Following large synonym webs. The spec's limits (4 hops, 16 lists per view) are reader limits.
- Roll-up through anything other than the path. "A Model Y is also electric" needs a second tag.
- "Recently active". An entry never moves after it is written.
- An exact count, per place, of the items that currently apply. The chain keeps it exactly per item (how many
  people say yes now) but not summed over a place.
- Removing duplicates across pages, and hiding junk children by default.
- Unicode folding, look-alike detection, and ENS names. The chain sees only bytes and addresses.
- Listing every author's versions of one file (no all-authors list is kept on HEAD).

## 11. Findings that affected the rest of the system, and what became of them

1. **The index was over its size budget** (21,955 bytes against 19,660). Built: the read-only functions moved to a
   separate reads contract; the generation is now 16,582 bytes.
2. **The kernel's floor would have refused large payable publications on Glamsterdam**, because of a 120k reserve
   per bind in the work model. Built: work-model formula 2 (section 5).
3. **The quote does not price the lists.** Built as planned: the release publishes the per-level terms and the
   planning rule, and the SDK plans from the words; the depth is not stored in the path record.
4. **A design document error** (reserved bits in the admission row). Corrected, and the layout re-versioned.
5. **No reader returned the number.** Built: heads, the admission views and every topic reader row carry it.
6. **Removing a file should release, not mask.** Built: remove and move release, hide masks.
7. **"Trust that topics are registered" must not be a setting.** Built: no flag; the index refuses to keep topic lists
   without its validator (section 4).
8. **The gateway ran out of room** (32 bytes of headroom after the link forms). Built: it is two contracts behind one
   address, the entry point (4,269 bytes of headroom) and a pinned content server (10,699).

## 12. From "proper version" to built

The release built, in the order this section planned, each step reviewed before it merged:

1. Kernel: the number (shape law, head and row fields, the read ABIs), a lone negative from every state, the ADDRESS
   target kind, `Bound` and `Body`, the hot read of a record's body word, the work model and floor fix.
2. Profiles: the two topic Types with the word rule and shared vectors, the validator's laws (topic before tag,
   address targets for TAG only, homes as parents), the text Type and the three purposes.
3. Index: the five first-statement lists with batched writes, the reads contract split, the quote terms, the
   step-3b amendments (every later author's first yes is filed; the exact yes-count).
4. Readers: the three views through the read facets, with the combined lens walk, the two bounds and de-duplication
   by thing; lookup by name, counts, the word page, children.
5. Release: the gateway split with object, revision and home links; the viewed-place check's cut; formula 2; every
   snapshot regenerated once, the release measured on both schedules, and one re-vendor for the SDK.

Still not built: `web3://` topic paths and `directory-alias/1` pointing at a home; the build-from-history step of a
later index generation; the generator for the refused code point table.

Everything moved in the release: the layout id, the hot ABI id, the execution set, the index manifest, the plan
hash, the Type id of `files-name/2` and the three new Types, and nearly every address (tools/RELEASE.md, the identity
table).

## 13. For James

Nothing here blocks the work; these are the points where a different answer from you would change the build. Each
is a numbered question with its alternatives in QUESTIONS-FOR-JAMES.md.

1. **The number's range is −65,536 to 65,535.** It costs nothing. A wider range would cost a storage slot per tag
   with a nonzero number. *Recommend keeping it.* (Q49)
2. **A tag can only be filed under a registered topic or an address.** A chess app that wants tag-like links on its
   own ids uses its own kind of link, at the same cost. *Recommend keeping it.* (Q50)
3. **No word may start with `~`, look like an address or contain white space,** anywhere in a path. *Recommend
   keeping it.* (Q51)
4. **Everyone's versions of one file are not listed on chain today: keep that list from the start, or leave it
   out?** Keeping it costs a storage slot for every file ever created: about 30k gas per file today in the store a
   HEAD statement already writes (about 2% of creating a file; 51k as measured in a separate third store; 118k to
   150k on Glamsterdam). Adding it later is possible and measured at about 485k per file today (582k on
   Glamsterdam), 9.5 to about 16 times as much, paid at once: 4.8 billion gas for 10,000 files, 485 billion for a
   million, so "later" suits only a small or young Realm. Keeping it can be undone (a later generation may drop a
   list); leaving it out cannot, for a large Realm. Your 2026-07-15 ruling (everything written through EFS is
   indexed automatically) bears on it. *The tag design session and the contracts dev both now recommend keeping it
   from the start, as its own list.* (Q52)
5. **The refused code point table** waits on your fold rule; until one generator produces it, the Topics Type ids
   are provisional. (Q53) **Sybil bumping** in public "newest first" views costs about 0.34M–0.68M per bump today.
   (Q54)
6. **Cost.** A tag is about half the price of creating a file today, and a deep new path can take two or three
   transactions for its first use. You ruled that cost is not the constraint; these are the numbers you asked to see.
