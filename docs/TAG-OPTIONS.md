# Tag options, with numbers

**Status: superseded (2026-11-25). James ruled on T-1 to T-5 and on the tag model; its identity recommendation
("not path") was overruled. The design and its measured costs are in [TAG-DESIGN.md](TAG-DESIGN.md). This paper is
kept as the record of the options that were priced.** It answers the PM's ask: price the ways EFS could carry tags, so the decision is
made from real numbers. Measured figures are marked **(m)**; figures computed from measured constants are marked
**(e)**. Recommendations are the contracts engineer's and are labelled as such.

## In plain words

A tag is three things said together: **who** says it, **which tag**, and **about what**. "Alice says photo #7 is
*nsfw*." A folder entry is the same sentence with a name on it: "Alice says the thing called `readme.txt` in *docs*
is file #7."

James's brief: *a folder is a tag; tags are hierarchical, so `/car/tesla` and `/person/tesla` are different tags;
tag-first like Obsidian or Gmail; persistent URIs.*

What the contracts as built already do, with no change:

- They can store "Alice says #7 is in *X*" today, for any *X*. It costs about **0.34M gas per tag** in a batch
  **(m)**, or 0.73M for one tag sent alone **(m)**. After Glamsterdam: 1.3M and 2.6M **(m)**.
- Assert, deny and "said nothing" (the 2026-09-10 direction D-C) already exist as three states of that statement.
- "List everything Alice put in *X*" and "list what Alice put on #7" both work, in pages, in the order she added
  them **(m)**.

What they do not do:

- **Reach the 50k-per-tag budget** (ruling D-E). One stored statement per tag costs about seven times that. Only
  packing many tags into one stored record gets near 50k, and only when a thing gets many tags at once.
- **Treat a folder and a tag as one thing.** Today a folder is its own kind of record and a file can only be filed
  under one of those.
- **Let you attach files to an address that has never written**, or start a `web3://` path at a person's own home.

Three decisions are needed, in this order:

1. **Is a folder a tag?** (one kind of node with two kinds of link, option C below). *Engineer's recommendation:
   yes.* It matches the brief, costs nothing extra, and makes homes and `web3://` roots fall out.
2. **What gives a node its identity:** its text (`tesla` is one tag everywhere), its path (`/car/tesla`), or a minted
   id (a folder that stays itself when renamed). *Recommendation: text for global tags, minted for folders and
   hierarchical tags, address for homes; not path.* The reasons are in "Identity".
3. **When to pay for the cheap dense path** (option B). *Recommendation: not for the MVP.* Ship tags on the path that
   exists; add packing when a real workload needs dozens of tags per item.

## The numbers that exist today (option A, all measured)

Measured in `test/integration/TagPathMeasure.t.sol` on the release build, cold state (each publication pays what a
transaction of its own pays), native lane. One tag = one binding at position `(TAG, concept, role = target)` with
the tagged thing as its target.

| Write | Today (prague) | After Glamsterdam (amsterdam) |
|---|---:|---:|
| One tag, alone in a transaction | 0.73M | 2.60M |
| Each further tag in the same transaction | 0.28–0.34M | 0.99–1.32M |
| Ten tags in one transaction | 3.73M | 14.1M |
| Forty tags in one transaction | 14.1M | 54.1M |
| Deny a tag you asserted | 0.45M | 1.20M |
| Assert it again | 0.49M | 1.33M |
| Back to "said nothing" | 0.41M | 1.08M |
| Deny a tag you never asserted (needs assert + deny; one transaction) | 0.81M | 2.85M |

About 45 tags fit one transaction under the 16.78M cap. A tag stores 8 to 11 fresh storage words **(m, from
state gas)**; roughly six of them are the kernel's own record of the statement and the rest are index entries
**(e)**. That is why this path cannot get near 50k: the kernel's record alone is about 0.15M **(e)**.

| Read (free calls; gas matters only against an RPC's per-call limit) | Gas |
|---|---:|
| Is #7 tagged *X* by Alice? | 13.5k |
| Everything Alice tagged *X*: a page of 10 | 0.94M |
| The same, a page of 50 (47 live, 3 denied skipped) | 3.81M |
| Which tags Alice put on #7: the list of 8 | 85k, plus 14.7k per tag to check it is still asserted |
| For comparison, a folder listing with names and kinds: per entry | about 152k |

So a member list costs about 76–94k gas per entry through the general-purpose lens reader, which is about 400
entries per 30M call. A reader written for member lists alone should do it in 15–25k per entry **(e)**.

## The options

### A. Tags on the binding path as built

Every tag is its own statement in the ledger, exactly like a folder entry without a name.

- **Changes:** none in the kernel, the index or the Types. A small reader for tag pages is new periphery. A label
  Type for tag names may be wanted (a tag's display name, description), and is an ordinary new Type.
- **Stance (D-C):** assert = bind, deny = unbind (a mask), said nothing = never bound or released. In a lens of
  several authors the first author with a stance decides, and a denial stops the search; that is the Lens law the
  folders use. Counting stances across authors is one 13.5k read per author.
- **Children of X:** the scope list of `(author, TAG, X)`: paged, in the order added, denied entries skipped,
  cursor-safe. The same machinery as a folder listing. Numbers above.
- **Good:** works now, one mechanism for folders and tags, every statement individually signed, deniable and
  auditable.
- **Bad:** seven times the D-E budget per tag today and six times after Glamsterdam. Fine for "tag a few things"
  and for folders-as-tags; not for booru-style tagging with dozens of tags on every item.

### B. A dedicated dense tag family

One record per (author, target) holding that author's whole tag list for the thing (asserted and denied), one
pointer to the current list, and index bitmaps per (author, tag) over targets for fast set queries.

| Tagging one thing (all estimates from measured constants) | Today | After Glamsterdam |
|---|---:|---:|
| 1 tag | 0.59M | 2.0M |
| 5 tags at once (per tag) | 0.71M (142k) | 2.6M (517k) |
| 10 tags at once (per tag) | 0.87M (87k) | 3.3M (330k) |
| 35 tags at once (per tag) | 1.65M (47k) | 6.9M (196k) |
| 35 tags, short ids packed four to a word (per tag) | 1.05M (30k) | 4.0M (114k) |
| Later, add one tag to a thing that has 10 | 0.68M | 2.4M |

- **Changes:** a new Type and rule for the tag list; a new index generation with a bitmap family and a way to read
  a variable-length list out of a record body; a builder for it; a tag page reader. Before any persistent
  deployment the index part is just a different genesis; after one it is an index migration by activation.
  Roughly two to three weeks with review **(e)**.
- **Stance (D-C):** two lists in the record (asserted, denied); anything in neither is "said nothing".
- **Children of X:** scan the (author, X) bitmap, 256 candidates per storage read, then confirm each hit against the
  author's current list (the bitmap is an accelerator, never the truth: a bit cannot be reliably cleared when lists
  are rewritten). About 15–30k per confirmed entry **(e)**. The real gain is set logic: "tagged A and B but not C" is
  computed on bitmap words before any entry is touched; in option A it is a list plus one check per candidate.
- **Good:** the only shape that reaches the D-E budget, at about 35 tags per item.
- **Bad:** it is *worse* than A for the everyday case. One tag on one thing costs 0.59M against A's 0.34M, and
  adding a tag later rewrites the list. It is a second mechanism next to bindings, with new index code to review.
  And it reaches 50k only at booru density, which the D-E ruling already put out of scope for one payer.

### C. One node, two kinds of link

A **node** is just an id. Two kinds of link hang off it, both of which exist today:

- a **named child** (`FOLDER`, node, name → thing): a folder entry;
- an **unnamed member** (`TAG`, node, thing → thing): a tag.

So `docs` is a node whose children have names, `nsfw` is a node whose members do not, and nothing stops one node
from having both. "A folder is a tag" becomes literally true: tagging #7 with *docs* and filing it in *docs* as
`readme.txt` are two links to the same node.

- **Costs:** exactly option A for members (0.34M per tag in a batch **(m)**) and exactly today's folder costs for
  named children (create a file in a folder: 1.64M alone **(m)**, about 1.27M each in a batch **(e)**).
- **Changes:** a node Type (replacing or alongside `files-directory/1`); a new final validator that accepts a node
  as a parent; the page reader and the `web3://` gateway learn the node Type. No kernel change. One useful kernel
  fact, verified: **the thing a link hangs off does not have to exist, only the thing it points at does.** So nobody
  has to create `nsfw`, or Bob's home, before filing under it. A node needs a record only to be listed as someone's
  child or to carry a label, and publishing it twice is harmless (the second publisher pays 0.19M **(m)** and the
  record is not stored again).
- **Stance and children:** as in A. Named children list through the folder reader, members through the member
  list. Placement is not inference (ruling D-A): putting `tesla` under `car` does not make things tagged `tesla`
  answer a query for `car`; only an explicit link does.
- **Good:** one model for folders, tags and homes; matches the brief; no extra cost; reuses reviewed code.
- **Bad:** the same per-tag cost as A. Changing the directory Type and validator now means the SDK and client
  re-record once more. And it forces the identity decision below.

B is not an alternative to C: B is a cheaper carrier for *members* that can be added under C later.

## Identity: what makes two nodes the same node

This is the decision with consequences that cannot be undone, because every link is stored under the node's id.

| A node's id comes from | `/car/tesla` vs `/person/tesla` | Rename `car` to `vehicle` | Find the id from a URL | Needs creating first |
|---|---|---|---|---|
| **its text** (`tesla`), folded as D-B rules | the same node | nothing to do; the placement is a link | hash the word; no chain read | no |
| **its path** (`car/tesla`) | different nodes | every node under it gets a new id; old members stay behind at the old ids, forever | hash the path; no chain read | no |
| **minting** (a creator and a salt; today's folders) | different nodes | one link changes; members untouched | walk the path link by link, through a lens | yes, by its creator |
| **an address** (a home) | n/a | n/a | hash the address | no |

The brief asks for distinct `/car/tesla` and `/person/tesla` *and* persistent URIs. Path-derived ids give the first
and break the second the day anything is renamed or moved, and a ledger cannot go back and re-file old members.
Every system that put the name or the parent into a tag's identity paid for it this way.

*Engineer's recommendation:* use three of the four, as three ways to get an id for the same kind of node.

- **Text** for global tags: `#tesla`, `#nsfw`, `#copyright`. Already ruled (D-B). Flat, no creation, anyone can use
  them.
- **Minted** for folders and for hierarchical tags: the `tesla` inside `car` is its own node, distinct from the one
  inside `person`, and stays itself through renames and moves. Its persistent URI is its id; `/car/tesla` is the
  name it currently has under someone's `car`, the way a file path names an inode.
- **Address** for homes.
- **Not path.**

What this costs James's mental model: `/car/tesla` is a *place you look up*, not a string you hash. Two people's
`/car/tesla` can be different nodes unless they share the same `car` (which a shared lens gives them).

## Homes and the `web3://` root (Q46)

- **Under C:** home(address) is a node derived from the address. Anyone can attach files to it without the owner
  having ever transacted; whose attachments you see is the lens, as everywhere. A `web3://` path
  `/<principal>/docs/a.txt` starts at that principal's home, so Q46 is answered by "a home per principal" with no
  shared root, and `web3://…/~tag/nsfw` can list a tag.
- **Under A or B without C:** a home has to be a directory record, which only its owner can create (a creation is
  authored by the creator). Its id is still computable in advance, but an address that never wrote has no home to
  attach to, and the shared root stays the only starting point.

## What each option changes

| | A as built | B dense family | C one node, two links |
|---|---|---|---|
| Kernel | none | none | none |
| Types | optional label Type | tag-list Type and rule | node Type; directory Type retired or kept |
| Index | none | new generation, new bitmap family, body-list extraction, builder | new final validator (a new generation after deployment; free before) |
| Readers | tag page reader | tag page reader with bitmap scan | folder reader and gateway accept nodes; tag page reader |
| SDK and client | new calls only | new calls only | re-record fixtures once; folder calls keep their shape |
| Per tag, today | 0.34M (m) | 47k–0.59M by density (e) | 0.34M (m) |
| Per tag, Glamsterdam | 1.3M (m) | 0.2M–2.0M by density (e) | 1.3M (m) |
| Meets D-E (50k / 220k) | no | at about 35 tags per item | no (yes with B added later) |

## Two small kernel questions worth settling with this

1. **Deny without having asserted.** Today a denial needs an assertion first, so "this is NOT nsfw" about something
   you never tagged is two actions (0.81M alone **(m)**). Letting a denial stand on its own is a small kernel change
   that makes it one action, about the price of one tag (0.73M alone, 0.34M in a batch) **(e)**, and is much cheaper
   to make before a deployment than after.
2. **Which index lists a tag needs.** A tag pays for the same index lists as a folder entry. If some are never read
   for tags, a later index generation can skip them and save perhaps a fifth **(e)**. Not worth doing until reads
   are known.

## Recommendation (the contracts engineer's)

1. Adopt C as the model: a node with named children and unnamed members.
2. Identity: text for global tags (as ruled), minted for folders and hierarchical tags, address for homes; no
   path-derived ids.
3. Ship tags at option A's price for the MVP. Be plain in the product that a tag costs about as much as creating a
   folder entry, so tagging is for a handful of things, not for thirty tags on every photo.
4. Keep B as the planned upgrade for dense tagging, as a carrier under the same nodes, built when a workload needs
   it. State now that D-E's 50k is met only there.
5. Decide "deny without asserting" before the first persistent deployment.

## What James has to rule

- **T-1. Is a folder a tag** (option C)?
- **T-2. Identity:** text, minted and address, with no path-derived ids? In particular: is it acceptable that
  `/car/tesla` is looked up rather than hashed?
- **T-3. Is 0.34M per tag acceptable for the MVP**, with the dense path later?
- **T-4. Denial on its own:** one action (a kernel change now) or two (as built)?
- **T-5. Homes:** a node per address that anyone can attach to (needs C), and `web3://` paths starting there (Q46)?

D-D (which index lists are automatic) stays pending as before and does not block any of these.
