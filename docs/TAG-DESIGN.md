# Tags: design and measured costs

**Status: a recommendation with measured evidence (2026-11-25). Nothing here is on `main`.** It answers the work
order in the planning vault's `Reviews/2026-11-25-tag-model-spec.md` (section 9), which applies James's rulings of
2026-11-25. The code that produced the numbers is the spike on this branch (`spike/2026-11-25-tags`); it is evidence
and is never merged as it stands. The proper version goes to a branch, is reviewed, and lands as one release.

Every figure is measured on the integrated spike build (commit `a47f2e9`) unless marked *(estimate)*. The full tables,
with the commands that produced them, are in [spike/TAG-SPIKE-NUMBERS.md](spike/TAG-SPIKE-NUMBERS.md). "Today" is the
Prague fee schedule; "Glamsterdam" is EIP-8037/8038, where creating storage is priced separately (see "Depth").
[TAG-OPTIONS.md](TAG-OPTIONS.md) is the earlier options paper; its identity recommendation was overruled and this
document replaces it.

## In plain words

- **A topic is a path of words**, such as `/cars/tesla`. Anyone can work out its id from the words alone. Nobody owns
  it. The word `tesla` has its own page, `/tesla`, which lists every place the word is used.
- **A tag says "this thing is in this topic, with this number".** The number runs from −65,536 to 65,535 and costs
  nothing extra to store. Zero or above means the tag applies; below zero means it doesn't. "Not this" can be said
  about something you never tagged.
- **A tag on a topic that was never registered is refused.** Registering is publishing one small record per new word
  and per new path, and it rides in the same transaction as the first tag.
- **Anyone can attach files to any address, and tag any address,** including one that has never transacted.
- **Every tag is listed** under its topic and every parent topic, per author and across all authors. The lists are
  written once, at an author's first statement about a thing in a topic, and never rewritten.
- **A 64-word path works.** No depth limit is proposed.

What it costs, one transaction with nothing else in it:

| | Today | Glamsterdam (all gas) |
|---|---:|---:|
| Tag a thing in an existing 2-word topic | 0.81M | 2.88M |
| The same, plus registering one new word and its path | 1.36M | 4.65M |
| Each further tag in the same transaction (4-word topic, everything new) | 0.47M | 1.77M |
| Change a tag's number | 0.49M | 1.41M |
| "Not this" about something never tagged | 0.68M | 2.29M |
| Tag an address that never transacted | 0.74M | 2.49M |
| Register a brand-new 8-word path, every word new | 3.98M | 14.0M |
| Tag on a brand-new 64-word path, nothing existing (worst case) | 4.76M | 17.98M |

For scale, creating a file today costs about 1.7M.

## 1. Topics

Two record Types, both with rules that run when the record is published.

- **Word page, `topic-word/1`.** Its body is the word's bytes and nothing else. It is also the root-level topic: the
  page for the word `tesla` is the topic `/tesla`.
- **Path, `topic/1`.** A topic of two or more words. Its body is exactly two references: its parent topic, and the
  page of its last word. `/cars/tesla` is the record (page of `cars`, page of `tesla`); `/cars/tesla/model_y` is the
  record (`/cars/tesla`, page of `model_y`).

What this gives, with no new kernel code:

- **The id is the record id,** a hash of the Type and the body. It does not depend on who published it, on the Realm
  or on the chain. Two people publishing `/cars/tesla` get the same id, and the second publication stores nothing
  again. Anyone computes the id from the words with no chain read.
- **Parent before child, word page before use.** The kernel already refuses a record whose declared reference does
  not exist. A parent published earlier in the same publication counts, so a short new path registers in one
  transaction and a deep one splits in order.
- **Permanent.** The reference check asks "was this ever admitted". A withdrawal by the first registrant lowers a
  count and changes nothing the check or the index reads (tested).
- **One sequence of words has exactly one record.** A one-word topic is only ever a word page, because a path record
  cannot be built without a parent and the kernel refuses a zero reference. An n-word topic is exactly one path
  record. A path whose parent is a file, a folder, a name or any other Type is refused (tested per case). A reader
  should still treat a chain that does not end at a word page as invalid.
- **Both directories exist already.** The index keeps a list per (Type, reference slot, referenced record). Slot 0 of
  path records gives a topic's children. Slot 1 gives the topics whose own word is a given word, which is what a
  word's page shows. No new index code, and no per-word list of items (measured in round one: it cost as much again
  as the roll-up lists).

**Word rules, checked once per word, on the word page:** 1 to 255 bytes of well-formed UTF-8; no `/`, no ASCII
control byte, no ASCII space, no ASCII `A`–`Z`; not `.` or `..`; not starting with `~`; not `0x` followed by 40 hex
digits. The last two apply to every word, not only the first in a path, because every word has a root-level page.
An address belongs in a tag as its target: tag the USDC contract's address under `/tokens/usdc`, never
`/tokens/0xa0b8…`. The check costs 121 to 208 gas per byte. Everything else about folding (Unicode case, look-alike
letters, normalisation) stays in the SDK; the chain cannot check it. The rule does not yet refuse C1 controls, bidi
controls or invisible characters, which `files-name/2` does refuse; the proper version should.

**Cost.** A word page is 0.53M alone and 0.20M as an extra action in a batch (1.64M / 0.69M on Glamsterdam). A path
record is 0.64M alone and 0.27M in a batch (2.10M / 0.95M).

## 2. The tag and its number

A tag is a bind at position (TAG, topic, thing), targeting the thing. The model is unchanged from the measured path
in TAG-OPTIONS.

- **The number rides in a field the action already has.** On BIND and UNBIND the `salt` word carries an unsigned
  strength from 0 to 65,535. BIND means number = strength. UNBIND means number = −1 − strength. So every action
  written today keeps its meaning (a bind is 0, a mask is −1) and no (kind, value) pair is meaningless. A strength
  above 65,535 is refused, never truncated, so a later widening cannot change the meaning of an action already on
  chain. RELEASE means "I say nothing" and carries no number. The proper version should rename the field
  `saltOrStrength`; the SDK takes field names from the vendored ABI.
- **No new storage.** The head row had 8 reserved bits and a 40-bit expiry field that is always zero; the expiry
  field narrows to 32 bits (seconds until 2106) and the number takes 16. Bind rows in the admission log had a 16-bit
  field that is always zero for binds. Eight bits would give up nothing; 24 bits would shrink the expiry field to 194
  days, which makes it useless. Sixteen is the widest clean width.
- **A first statement may be negative.** UNBIND is admitted from every state: never said, asserted, denied and
  released. This applies to every purpose, with no gate. A gate would have to live in the kernel, which knows no
  purposes, or in a validator, which may never refuse a mask.
- **Changing only the number keeps history.** A positive to another positive is a BIND to the same target; a negative
  to another negative is another UNBIND. Each is one action under the usual revision check, and each adds a history
  entry.
- **What a tag's subject may be.** A registered topic, or a home (section 3). The profile validator refuses a first
  statement (positive or negative) on anything else, with a named error. The topic must be registered strictly
  before the tag, in an earlier action; the spike first accepted "anywhere in the same publication", and that tag
  would have silently missed its roll-up lists. Other apps that want tag-like links on their own ids use their own
  purpose.
- **What can be tagged.** A file (a subject), a folder (a directory record), a topic, a specific revision of a file
  (a record), and an address.

| Operation on an existing tag | Today | Glamsterdam |
|---|---:|---:|
| Change a positive (0 → 75) | 485,253 | 1,413,319 |
| Change a negative (−1 → −5) | 423,408 | 1,168,334 |
| Positive to negative | 441,018 | 1,193,144 |
| Negative to positive | 503,330 | 1,512,316 |
| To silent | 422,465 | 1,167,391 |

A nonzero number costs 12 gas more than zero.

## 3. Addresses: homes and targets

- **A home's id is the address itself,** as a left-padded word. That is the same value as a key account's principal
  id. A record id or a minted subject id is a hash, so one that looks like an address would take about 2^96 tries;
  the two forms cannot be confused. The zero address is not a home (the kernel refuses a zero subject).
- **Attaching.** A named entry whose parent is address-shaped is accepted with no check on the address: it needs no
  code, no balance and no history. Tag links under a home need nothing new. Attaching a file to a home costs the
  same as into a folder (1,731,223 against 1,737,328 today). The existing folder page reader and lens reader work on
  a home unchanged (tested).
- **An address as a tag's target.** A third target kind, ADDRESS, admits an address-shaped target that is neither a
  record nor a subject. The validator allows it for TAG only. On a file's HEAD or a folder entry it is refused with
  a named error, because it would confirm and never be readable. A named folder entry pointing at an address can
  come later, with its reader.
- **A contract's home** is its raw address, but a contract's principal id is not (it is qualified by the Realm). The
  SDK computes "the owner's entries" for a contract home from the contract principal.
- **Not built:** `web3://` paths that start at a home. The gateway's first path segment already means "this
  author's entries under the Realm root", so a home start needs its own marker. About 200 to 400 bytes
  *(estimate)*, within the gateway's 1,650 bytes of headroom. `directory-alias/1` cannot point at a home yet.

## 4. The lists

Every list is append-only. An entry is written once, at an author's first statement on (topic, thing), whatever its
sign. Later changes, removals and re-adds write no list. A reader takes the current state and number from the
statement itself. "Newest first" therefore means most recently first-stated; no later action by an author can move
or duplicate their entry (tested, including remove-and-add-back).

| List | Key | Written when | Purposes |
|---|---|---|---|
| Per author, exact | (author, purpose, place) | exists today | all |
| **Per author, this topic and below** | (author, TAG, ancestor) | the author's first statement, once per proper ancestor | TAG |
| All authors, a place's distinct items | (purpose, place) | the first statement by anyone at that (place, item) | TAG, FOLDER |
| All authors, who said it | the (place, item) position | every author's first statement there | TAG, FOLDER |
| All authors, this topic and below | (TAG, ancestor) | the first statement by anyone, once per proper ancestor | TAG |
| All authors, where a thing is filed | (TAG, thing) | the first statement by anyone at that (place, thing) | TAG |

- **Two levels for all authors.** One list of a place's distinct items, and one list per item of who said it. A
  lookup of one name or item reads one short list whatever the size of the place. One photo tagged by a hundred
  people appears once. A place's count is "distinct items" and an item's count is "how many people said this", each
  one read. Buckets by name hash were considered and rejected: a spammer picks names that fall in the victim's
  bucket, so a targeted attack is not bounded.
- **Every statement is reachable from its target, whatever its sign.** A lone "not nsfw" carries no target, so the
  existing "what points at this" list never shows it. The last list in the table fixes that for every kind of
  target. Hiding still uses only lens authors' denials, read directly.
- **Not kept:** all-authors lists on HEAD (a storage slot per file, and nothing reads it), per-word lists of items,
  and "where a name is used" for FOLDER (pure cost: +25,575 gas per created file).
- **Rebuild equals live.** A test drives a mixed history through the live index, replays it into a fresh index, and
  compares every list. The index reads only records that can never change, and the validator guarantees they predate
  the tag.

**What the lists add to one first tag** (on top of about 0.70M today and 2.57M on Glamsterdam with no lists):

| Case | 1 word | 4 words | 8 words | 64 words |
|---|---:|---:|---:|---:|
| Today: everything new | 85k | 265k | 517k | 4.06M |
| Today: my lists exist, the item is new here | 74k | 183k | 341k | 2.57M |
| Today: someone already tagged this item here | 39k | 141k | 275k | 2.25M |
| Today: everything exists | 22k | 89k | 176k | 1.49M |
| Glamsterdam: everything new | 350k | 1.06M | 2.01M | 15.4M |
| Glamsterdam: everything exists | 37k | 146k | 291k | 2.41M |

Per extra path level: the per-author roll-up is 35k gas on a list the author has never used and 23.5k on an existing
one (123k and 38k on Glamsterdam). The all-authors roll-up costs the same again, but only when the item is new to
that topic. Round two also made every list write cheaper: one store call per action with one authorization, which
took 16k off every publication and 39k off a first tag before any list is added.

**Ordinary file work:** creating a file costs about 53k more (3%) with the all-authors folder lists on; an edit costs
nothing more.

## 5. Depth

- **Today, a tag fits one transaction to about 254 words** in the worst case and 651 when everything exists.
- **On Glamsterdam the answer depends on a rule I had checked.** EIP-8037 (status: Last Call; its deadline has
  passed) says the 16.78M per-transaction cap applies to execution gas only. Gas for creating storage is paid from a
  separate reservoir, and a transaction's total limit may be far higher. On that reading the worst-case 64-word tag
  is 3.30M of execution gas and fits; the deepest path is about 364 words *(estimate: Foundry has no reservoir, so
  this is computed from the execution share)*. If all gas counted against the cap, the worst case (17.98M) would not
  fit and the limit would be about 59 words. Both readings are in the tables.
- **A block must still have room.** A block's usage is the larger of its execution gas and its storage gas. The
  worst-case tag carries 14.7M of storage gas, which fits any plausible block.

**If the Glamsterdam rule changes before it activates** so that all gas counts against the cap, the worst case is
59 words, under the 64 the ruling requires. Nothing is built for this; two options, neither of which ever skips a
level:

- **Open the roll-up list when the topic is registered** *(preferred)*. The worst case is dear because every
  all-authors list on a new path is brand new, and a new list is a new storage slot. If registering a topic also
  writes that topic's all-authors roll-up list head, those lists always exist by the time anything is tagged. Only
  the author's own lists can then be new. A first tag on a 64-word path becomes about 12.7M all gas *(estimate:
  2.6M base, 63 levels at 123k for the author's new lists and 38k for the existing shared ones)*, which fits, and
  the limit moves to about 88 words. Price: one more storage slot per registered topic (22k gas today, 110k on
  Glamsterdam), paid at registration, which already splits across transactions. The tag stays one atomic write.
- **A roll-up continuation** *(for paths deeper than that)*. The tag is admitted with its exact lists and as many
  ancestor levels as fit; a later action, which anyone may send, finishes the remaining levels. A tag whose lists
  are unfinished must be visible as such to readers, and the continuation must be an ordinary recorded action so a
  rebuilt index matches the live one. Price *(estimate)*: one storage slot per unfinished tag for its progress, the
  fixed cost of a publication (about 0.3M today) per continuation, and the same per-level cost as now. It is a new
  action kind and a real addition to the kernel, so it is the fallback, not the plan.

**Registering a brand-new path, every word new:**

| Words | Today | Transactions | Glamsterdam, all gas | Execution only | Transactions |
|---:|---:|---:|---:|---:|---:|
| 8 | 3.98M | 1 | 14.0M | 2.93M | 1 |
| 16 | 7.89M | 1 | 27.8M | 5.74M | 1 |
| 32 | 15.9M | 1 | 55.9M | 11.5M | 1 |
| 64 | 32.7M | 3 | 113.0M | 23.5M | 2 |

- The Glamsterdam counts assume the execution-only reading, where the limit is 64 actions per publication. If all gas
  counted, 64 words would take 8 transactions.
- The 64-word registration carries about 89M of storage gas over two transactions. Assuming a 60M block gas limit
  *(my assumption; state yours if it differs)*, each half fits one block and takes most of it. Under a 36M limit it
  would need three.
- **Wallet prompts for a first tag on a brand-new path** *(estimate, registration and tag combined)*: up to 16 words,
  one transaction, so one prompt. At 32 words, two today and one on Glamsterdam. At 64 words, three today and two on
  Glamsterdam. A wallet batch (EIP-5792) makes each of these one prompt, and the bounded session grant James already
  allowed makes them none. Registration parts are safe to send first and are harmless if the save is abandoned.

## 6. Reading

The spike has one reader with the three views. It reads raw storage, which the repository's rules do not allow a
shipped reader to do; the proper version goes through the read facets.

| Read (cold call) | Gas |
|---|---:|
| Mine: my lens, this topic and below, page of 10, lens of 1 / 8 / 32 / 64 | 283k / 633k / 2.08M / 4.10M |
| The same, page of 50 | 1.35M / 1.93M / 6.49M / 15.1M |
| Everyone, lens of 8, page of 10 / 50 | 656k / 3.49M |
| Raw, page of 10 / 50 | 322k / 1.44M |
| "Anyone's `pet.jpg` at this address", 3 authors / 300 authors | 88,440 / 88,446 |
| One name in a place of 3 / 2,001 entries | 71k / 73k |
| A place's count; an item's author count | 29k; 32k |
| A word's page for 1 / 5 / 20 places (directory plus one count each) | 61k / 177k / 610k |

- **Depth makes no difference to a read** (under 0.5% between 1 and 64 words).
- **Call size.** Providers cap the gas of one read call. Assuming a conservative 10M cap, keep a page to 50 rows at
  most and page × lens to 1,600 at most *(estimate from the measured points)*: 25 rows at a lens of 64, 50 rows at a
  lens of 32. The SDK should split larger reads, so a big lens never fails as "unknown" because one call was too big.
  The cost grows with lens size because each candidate from the j-th lens author checks the authors ahead of it; the
  proper reader should batch those checks through the existing heads facet.
- **Duplicates** are removed within a page. The same item reached through two authors' lists can appear again on the
  next page; the client removes it across pages.
- **Denials.** The spike hides a row when a lens author is negative at the position the entry was filed under. The
  spec also hides it when a lens author is negative at the place being viewed; the proper reader adds that check.
- **Counts** are list lengths. They count every statement ever made, including removed and negative ones.

## 7. Spam and what stays true

- Adding one entry to a place's public list costs the spammer about 0.30M gas today (1.13M on Glamsterdam). Adding
  one to "who said this" at a name needs a fresh account each time and costs about 0.54M (1.71M). These were measured
  in round two, before the final integration.
- A reader pays about 28k gas to skip a junk row in Raw and 71k with a lens of 8 *(estimate, from the page slopes)*.
  Mine is not affected: it reads only lens authors' lists.
- **Bounded whatever the spam:** a count; a lookup of one name or item; a page at one position.
- **Not bounded:** paging through a spammed place in Everyone or Raw. With public lists newest first, whoever
  appended last at `pet.jpg` is what a public first page shows. The lens is the defence, and the client should label
  the public tier.
- Counts can be inflated at about one tag's gas per entry. Show the lens count beside the global one.

## 8. Meaning: the purposes for statements about topics

Proposed smallest set, to be fixed before anything lasting is deployed. None is built or measured; each statement
is one bind and costs what a tag does.

| Purpose | Position | Target | Holds |
|---|---|---|---|
| `property` | (topic, key) | a value record or a file | one value per author per key: a label per language, the definition, "moved to" |
| `same` | (topic, other topic) | the other topic | "same as", at word level between word pages and at path level between paths |
| `broader` | (topic, parent topic) | the parent | the optional booru-style parent |

- Single-valued facts share one purpose and differ by key (`label:en`, `definition`, `moved-to`), so a new kind of
  fact needs no new purpose. Many-valued relations get their own purpose so each has its own list.
- "What points at this" already exists across authors, so synonyms are found from either side.
- A label needs a small text Type (`files-name/2` refuses `/`, so it cannot hold "AC/DC").
- Curating a topic's children uses TAG itself, as the spec says: tag the child into the parent with a number.

## 9. Events for indexers

- Today the kernel's events carry neither a bind's target nor its number, and no byte of a record's body. An
  off-chain indexer would need storage reads or transaction traces.
- The spike adds `Bound`, one event per bind, with purpose, subject, role, target, kind, strength, transition and
  target kind. It costs 3,633 gas per bind and 124 bytes of kernel code.
- **Still missing: the words.** A topic's word reaches no log. The proper version should emit a record's body when a
  fresh record of a small Type is admitted (a word costs about 1 to 2k gas to log *(estimate)*), so an indexer can
  follow topics, labels and names from events alone.

## 10. What cannot be done in contracts

Assigned to an indexer (The Graph) or the client on purpose:

- Sorting or ranking by the number, by activity or by popularity. Lists are in first-stated order.
- Combining numbers across authors (an average, "how nsfw on the whole").
- Type-ahead, partial-word and fuzzy search. The chain answers "the page for exactly this word".
- AND, OR and NOT across large lists. Small ones work by reading one list and checking the other per item.
- Following large synonym webs. The spec's limits (4 hops, 16 lists per view) are reader limits.
- Roll-up through anything other than the path. "A Model Y is also electric" needs a second tag.
- "Recently active". An entry never moves after it is written.
- An exact count of tags that currently apply. Counts include removed and negative statements.
- Removing duplicates across pages, and hiding junk children by default.
- Unicode folding, look-alike detection, and ENS names. The chain sees only bytes and addresses.
- Listing every author's versions of one file (no all-authors list is kept on HEAD).

## 11. Findings that affect the rest of the system

1. **The index contract is over its size budget.** It is 21,955 bytes against 19,660. The proper version moves its
   read-only functions into a separate reads contract (about 2.3 KB *(estimate)*, no cost to writes). The ingress
   has 626 bytes left and the gateway 1,654.
2. **The kernel's gas floor would wrongly refuse some large publications on Glamsterdam.** Before each index call the
   kernel requires a floor of visible gas. EIP-8037 says the GAS opcode does not see the storage reservoir. A
   publication of 64 lone negatives on a one-word topic needs 19.0M visible by the floor's arithmetic but only 15.4M
   of execution gas to run, so it is refused though it can pay (asserted in a test). The cause is a reserve of 120k
   per bind in the index's work model, far above what a bind's final check uses. The fix is in the work model, not a
   limits value, and belongs in the same release. On today's schedule that publication cannot pay anyway.
3. **The quote does not price the lists.** A deep tag sent with too little gas fails with a clear out-of-gas error
   and is never accepted without its lists, but the person pays for the failed transaction. The primary fix is in
   the SDK: it always plans from the words, so it knows the depth, the number of new words, and (from two reads)
   whether the author's and the shared lists exist. The release publishes the per-level terms in the gas model (a
   new list, an existing list, per author and shared, on both schedules) so the SDK's gas limit and the kernel's
   floor are computed from the same figures. Storing the depth in the path record, so the kernel can quote it too,
   is optional. The floor fix of finding 2 ships with it.
4. **A design document error.** DESIGN §4.3 lists 11 reserved bits in the admission row; the real layout has none.
   The proper version corrects the text and re-versions the layout identities.
5. **No reader returns the number yet.** It must be added to the head and admission views, which changes those ABIs
   and the layout id.
6. **Removing a file should release, not mask.** A mask stops the lens search, so removing my `pet.jpg` at a shared
   place would hide other people's. The reference recipes change in the same release (remove and move release; hide
   masks).
7. **"Trust that topics are registered" must not be a setting.** The spike's index has a flag that skips two reads
   per level because the validator guarantees a topic is registered before it is tagged. A Realm built with the flag
   and without the validator would quietly drop roll-up entries. In the proper version there is no flag: the index
   keeps the topic lists only when its own fixed list of units contains the profile validator built for the same two
   topic Types, and its constructor refuses any other combination. A test proves the misconfigured index cannot be
   deployed.

## 12. The proper version, as one release

Already under way on `fable/2026-11-25-single-release`: a folder becomes a record of (creator, salt) that only its
creator can publish, which fixes the kind of an object by its id, and the remove/move/hide recipes.

Then, in this order, each reviewed before it merges:

1. Kernel: the number (shape law, head and row fields, the read ABIs), a lone negative from every state, the ADDRESS
   target kind, the `Bound` event and the record-body event, the work-model and floor fix.
2. Profiles: the two topic Types with the word rule and shared vectors, the validator checks (topic before tag,
   address targets for TAG only, homes as parents), the text Type and the three purposes of section 8.
3. Index: the five new lists with batched writes, the reads contract split to get under the size budget, the quote
   terms.
4. Readers: the three views, lookup by name, counts, the word page, through the read facets; a home start for
   `web3://` paths.
5. Release: regenerate every snapshot once, measure the real build on both schedules, and hand the SDK one re-vendor.

Everything moves in that release: the layout id, the hot ABI id if the head read gains the number, the execution
set, the index manifest, the plan hash, the Type ids of the directory and the new Types, and nearly every address.

## 13. For James

Nothing here blocks the work; these are the points where a different answer from you would change the build.

1. **The number's range is −65,536 to 65,535.** It costs nothing. A wider range would cost a storage slot per tag
   with a nonzero number. *Recommend keeping it.*
2. **A tag can only be filed under a registered topic or an address.** A chess app that wants tag-like links on its
   own ids uses its own kind of link, at the same cost. *Recommend keeping it.*
3. **No word may start with `~` or look like an address,** anywhere in a path. *Recommend keeping it.*
4. **Everyone's versions of one file are not listed on chain.** Keeping that list costs a storage slot for every
   file ever created (about 36k gas today, 124k on Glamsterdam). *Recommend leaving it to the indexer.*
5. **Cost.** A tag is about half the price of creating a file today, and a deep new path can take two or three
   transactions for its first use. You ruled that cost is not the constraint; these are the numbers you asked to see.
