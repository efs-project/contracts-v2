# Tags: the measured costs of the first-statement lists (step 3b)

The numbers of the five lists of docs/TAG-DESIGN.md §4 as built (design §10.2 families 6, 7, 19, 20 and 21), on the
real Files Realm: the real `topic-word/1` and `topic/1` Types, `FilesFinalValidator` and the generation-1 index with
its topic lists. `docs/spike/TAG-SPIKE-NUMBERS.md` stays as the spike's record; nothing here replaces it.

**Every figure is marked.** *(measured)*: logged by a test run on the tree of commit `a6a5228`, table C at `5d1f22a` (whose index and kernel
source is that of `bb2e8d1`; `2e187a8` and `a6a5228` add only the gas-model rows and the measurement suites), Foundry
1.8.3, solc 0.8.37 via-IR. *(computed)*: arithmetic on measured figures, with its inputs stated.

**Quantities.** Every measured publication is cooled first (each pays the cold costs of a transaction of its own),
native lane, by an author that has written before (no first-write surcharge, except the row that says "fresh
account"). "prague" is the release schedule. On amsterdam (EIP-8037/8038) "all" = execution (regular) gas + state gas
and "exec" = execution gas only. Table A and table B are the `execute` frame's gas (no intrinsic 21,000, no calldata);
"per extra" = (k10 − k1) / 9 of a batch of 10 on one topic. Table C, the batch table and table D are transaction gas:
frame + 21,000 + the calldata's standard cost; on amsterdam "execution only" is frame execution gas + 21,000 +
calldata, the quantity the EIP-7825 cap (2^24 = 16,777,216) counts under EIP-8037's execution-only reading.

**Commands** (repository root, under the watchdog; the JSON's `decoded_logs` carry `tl <row> exec|state|all|tx|txexec`
and `tlb <row> exec|state|all`):

```sh
# prague: the release bytes in out/
FOUNDRY_GAS_LIMIT=100000000000 perl -e 'alarm 5400; exec @ARGV' \
  forge test --match-path 'test/integration/TagLists*Measure.t.sol' --json -vv > prague.json
# amsterdam: its own out/ and cache/, never the default out/; Foundry draws state gas from the call, so the test gas
# limit is raised (as for the spike)
FOUNDRY_GAS_LIMIT=100000000000 FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam \
  perl -e 'alarm 9000; exec @ARGV' forge test --match-path 'test/integration/TagLists*Measure.t.sol' --json -vv > amsterdam.json
# table B at step 3a: the same TagListsFileMeasure.t.sol in a `git archive 5827106` export, both profiles
# the per-level terms: pnpm run gas:model (gas/model.json)
```

## The cases

(i) everything new: the author's roll-up lists, the shared lists and the position are all new; (ii) the author's
lists and the shared lists exist (6 entries), the position is new; (iii) the position exists (another author stated
it first) and this author's roll-up lists are new; (iv) everything exists: the position has two authors and the
author's lists hold 6 entries. n is the topic's number of words; a first statement on an n-word topic writes n − 1
entries in each roll-up it touches.

## The per-level terms (`gas/model.json`, design §10.4) *(measured)*

| term | prague | amsterdam, all | amsterdam, execution |
|---|---:|---:|---:|
| `bindTagFresh`: a first tag on a fresh position of a 1-word topic | 413,130 | 1,645,088 | 274,208 |
| `bindTagSecondAuthor`: a first tag on an existing position of a 1-word topic | 290,991 | 1,016,405 | 233,045 |
| `tagLevel.mineNew`: one per-author roll-up entry on a new list | 36,134 | 124,165 | 26,245 |
| `tagLevel.mineExisting`: one per-author roll-up entry on an existing list | 24,408 | 38,805 | 38,805 |
| `tagLevel.sharedNew`: one shared roll-up entry on a new list (fresh positions only) | 25,414 | 113,431 | 15,511 |
| `tagLevel.sharedExisting`: one shared roll-up entry on an existing list | 13,659 | 28,071 | 28,071 |

For an n-word topic: the fresh-position or second-author term, plus, per proper ancestor, mine new or existing and (on
a fresh position) shared new or existing. The model's composite "a first tag on a fresh 6-word path" predicts 1,043,269
against 1,036,035 measured on prague (+0.70%) and 3,745,990 against 3,783,543 on amsterdam (−0.99%). On amsterdam an
existing list costs more execution gas than a new one: a rewrite is 12,100 of execution gas under EIP-8038, while a new
slot's 110,020 is mostly state gas. That is why case (ii) reaches only 239 words on the execution-only reading in
table C, fewer than case (i)'s 368.

**A number change no longer touches the backlink list** (design §10.2: a BIND that keeps its asserted target skips
family 5) *(measured, `bindTagNumberChange`, step 3a → 3b)*: prague 192,466 → 153,453 (−39,013); amsterdam all
566,012 → 431,867 (−134,145), execution 174,332 → 138,107 (−36,225).

## A (a first tag): one statement on an n-word topic *(measured)*

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 730,476 | 401,641 | 2,597,750 | 541,430 | 1,584,691 | 268,211 |
| (i) everything new | 2 | 790,391 | 424,594 | 2,833,705 | 581,545 | 1,646,746 | 286,746 |
| (i) everything new | 4 | 916,791 | 477,108 | 3,312,219 | 668,379 | 1,777,456 | 330,416 |
| (i) everything new | 8 | 1,168,498 | 580,976 | 4,268,074 | 840,874 | 2,037,710 | 416,590 |
| (i) everything new | 16 | 1,671,314 | 788,124 | 6,179,222 | 1,185,302 | 2,557,656 | 588,376 |
| (i) everything new | 32 | 2,678,594 | 1,204,072 | 10,003,130 | 1,875,770 | 3,599,160 | 933,560 |
| (i) everything new | 64 | 4,703,760 | 2,046,582 | 17,661,576 | 3,267,336 | 5,692,799 | 1,634,559 |
| (ii) lists exist, position new | 1 | 726,333 | 399,227 | 2,527,187 | 568,787 | 1,572,508 | 266,908 |
| (ii) lists exist, position new | 2 | 762,768 | 422,191 | 2,592,422 | 634,022 | 1,634,596 | 285,476 |
| (ii) lists exist, position new | 4 | 842,208 | 474,732 | 2,729,496 | 771,096 | 1,765,377 | 329,217 |
| (ii) lists exist, position new | 8 | 999,995 | 578,648 | 3,002,471 | 1,044,071 | 2,025,761 | 415,521 |
| (ii) lists exist, position new | 16 | 1,314,971 | 785,883 | 3,547,859 | 1,589,459 | 2,545,976 | 587,576 |
| (ii) lists exist, position new | 32 | 1,946,571 | 1,202,009 | 4,640,247 | 2,681,847 | 3,588,017 | 933,297 |
| (ii) lists exist, position new | 64 | 3,220,377 | 2,044,882 | 6,835,653 | 4,877,253 | 5,682,730 | 1,635,370 |
| (iii) position exists, my roll-ups new | 1 | 625,313 | 313,505 | 2,066,887 | 500,167 | 1,139,319 | 236,279 |
| (iii) position exists, my roll-ups new | 2 | 659,826 | 327,535 | 2,189,420 | 524,780 | 1,172,902 | 248,102 |
| (iii) position exists, my roll-ups new | 4 | 728,765 | 355,509 | 2,434,399 | 573,919 | 1,239,980 | 271,660 |
| (iii) position exists, my roll-ups new | 8 | 873,352 | 418,210 | 2,931,088 | 678,928 | 1,380,865 | 325,505 |
| (iii) position exists, my roll-ups new | 16 | 1,161,580 | 542,598 | 3,923,488 | 887,968 | 1,661,664 | 432,224 |
| (iii) position exists, my roll-ups new | 32 | 1,738,021 | 791,372 | 5,908,237 | 1,305,997 | 2,223,211 | 645,611 |
| (iii) position exists, my roll-ups new | 64 | 2,894,877 | 1,292,896 | 9,881,733 | 2,146,053 | 3,350,304 | 1,076,384 |
| (iv) everything exists | 1 | 598,812 | 276,991 | 1,886,146 | 515,266 | 931,588 | 235,268 |
| (iv) everything exists | 2 | 621,585 | 291,030 | 1,923,319 | 552,439 | 965,184 | 247,104 |
| (iv) everything exists | 4 | 667,044 | 319,015 | 1,997,578 | 626,698 | 1,032,296 | 270,696 |
| (iv) everything exists | 8 | 764,671 | 381,739 | 2,152,827 | 781,947 | 1,173,248 | 324,608 |
| (iv) everything exists | 16 | 958,979 | 506,173 | 2,462,347 | 1,091,467 | 1,454,182 | 431,462 |
| (iv) everything exists | 32 | 1,347,580 | 755,033 | 3,081,336 | 1,710,456 | 2,015,993 | 645,113 |
| (iv) everything exists | 64 | 2,128,756 | 1,256,735 | 4,323,312 | 2,952,432 | 3,143,623 | 1,076,423 |

## A (a lone negative): one statement on an n-word topic *(measured)*

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 661,747 | 332,868 | 2,265,061 | 502,501 | 1,251,954 | 229,234 |
| (i) everything new | 2 | 721,649 | 355,804 | 2,501,015 | 542,615 | 1,314,008 | 247,768 |
| (i) everything new | 4 | 848,056 | 408,329 | 2,979,524 | 629,444 | 1,444,712 | 291,432 |
| (i) everything new | 8 | 1,099,754 | 512,184 | 3,935,382 | 801,942 | 1,704,970 | 377,610 |
| (i) everything new | 16 | 1,602,540 | 719,302 | 5,846,500 | 1,146,340 | 2,224,886 | 549,366 |
| (i) everything new | 32 | 2,609,796 | 1,135,226 | 9,670,384 | 1,836,784 | 3,266,366 | 894,526 |
| (i) everything new | 64 | 4,634,892 | 1,977,666 | 17,328,760 | 3,228,280 | 5,359,935 | 1,595,455 |
| (ii) lists exist, position new | 1 | 657,604 | 330,455 | 2,194,498 | 529,858 | 1,239,772 | 227,932 |
| (ii) lists exist, position new | 2 | 694,026 | 353,406 | 2,259,732 | 595,092 | 1,301,859 | 246,499 |
| (ii) lists exist, position new | 4 | 773,473 | 405,950 | 2,396,801 | 732,161 | 1,432,635 | 290,235 |
| (ii) lists exist, position new | 8 | 931,251 | 509,858 | 2,669,779 | 1,005,139 | 1,693,022 | 376,542 |
| (ii) lists exist, position new | 16 | 1,246,197 | 717,063 | 3,215,137 | 1,550,497 | 2,213,207 | 548,567 |
| (ii) lists exist, position new | 32 | 1,877,773 | 1,133,164 | 4,307,501 | 2,642,861 | 3,255,224 | 894,264 |
| (ii) lists exist, position new | 64 | 3,151,509 | 1,975,967 | 6,502,837 | 4,838,197 | 5,349,867 | 1,596,267 |
| (iii) position exists, my roll-ups new | 1 | 551,276 | 239,424 | 1,721,790 | 448,830 | 794,177 | 184,897 |
| (iii) position exists, my roll-ups new | 2 | 585,776 | 253,441 | 1,844,322 | 473,442 | 827,756 | 196,716 |
| (iii) position exists, my roll-ups new | 4 | 654,724 | 281,424 | 2,089,298 | 522,578 | 894,831 | 220,271 |
| (iii) position exists, my roll-ups new | 8 | 799,306 | 344,120 | 2,585,994 | 627,594 | 1,035,723 | 274,123 |
| (iii) position exists, my roll-ups new | 16 | 1,087,509 | 468,479 | 3,578,369 | 836,609 | 1,316,497 | 380,817 |
| (iii) position exists, my roll-ups new | 32 | 1,663,939 | 717,242 | 5,563,107 | 1,254,627 | 1,878,033 | 594,193 |
| (iii) position exists, my roll-ups new | 64 | 2,820,747 | 1,218,718 | 9,536,555 | 2,094,635 | 3,005,078 | 1,024,918 |
| (iv) everything exists | 1 | 541,824 | 219,956 | 1,638,818 | 463,778 | 684,213 | 183,733 |
| (iv) everything exists | 2 | 564,584 | 233,983 | 1,675,990 | 500,950 | 717,812 | 195,572 |
| (iv) everything exists | 4 | 610,052 | 261,980 | 1,750,246 | 575,206 | 784,918 | 219,158 |
| (iv) everything exists | 8 | 707,674 | 324,695 | 1,905,502 | 730,462 | 925,880 | 273,080 |
| (iv) everything exists | 16 | 901,957 | 449,104 | 2,214,997 | 1,039,957 | 1,206,785 | 379,905 |
| (iv) everything exists | 32 | 1,290,547 | 697,953 | 2,833,975 | 1,658,935 | 1,768,586 | 593,546 |
| (iv) everything exists | 64 | 2,071,675 | 1,199,607 | 4,075,903 | 2,900,863 | 2,896,167 | 1,024,807 |

## B: ordinary file work, step 3a against step 3b *(measured)*

| operation | prague 3a | prague 3b | Δ | amsterdam all 3a | amsterdam all 3b | Δ | amsterdam exec 3a | amsterdam exec 3b | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| create file in a folder with files | 1,642,414 | 1,701,987 | 59,573 (3.6%) | 5,855,340 | 6,098,077 | 242,737 (4.1%) | 1,253,100 | 1,299,997 | 46,897 (3.7%) |
| create file in an empty home | 1,545,370 | 1,599,658 | 54,288 (3.5%) | 5,347,542 | 5,577,870 | 230,328 (4.3%) | 1,234,902 | 1,269,390 | 34,488 (2.8%) |
| create file in a home with files | 1,550,836 | 1,610,421 | 59,585 (3.8%) | 5,360,196 | 5,602,933 | 242,737 (4.5%) | 1,247,556 | 1,294,453 | 46,897 (3.8%) |
| edit | 858,092 | 859,038 | 946 (0.1%) | 2,768,808 | 2,769,766 | 958 (0.0%) | 712,488 | 713,446 | 958 (0.1%) |

## C: the deepest topic whose single first statement fits one transaction (2^24) *(measured)*

| statement, case | prague: deepest | tx gas at it | per level | amsterdam all gas: deepest | tx gas at it | per level | amsterdam execution only: deepest | tx execution gas at it | per level |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tag, (i) everything new | 254 | 16,570,357 | 62,964 | 60 | 16,645,239 | 239,004 | 368 | 16,770,206 | 43,164 |
| tag, (ii) lists exist, position new | 397 | 16,756,606 | 39,484 | 209 | 16,767,800 | 68,284 | 239 | 16,720,701 | 68,284 |
| tag, (iii) position exists, my roll-ups new | 443 | 16,746,016 | 36,032 | 119 | 16,666,767 | 124,052 | 589 | 16,755,734 | 26,132 |
| tag, (iv) everything exists | 628 | 16,762,355 | 24,292 | 381 | 16,754,389 | 38,694 | 416 | 16,744,267 | 38,692 |
| lone negative, (i) everything new | 254 | 16,500,790 | 62,962 | 61 | 16,548,452 | 239,002 | 369 | 16,773,354 | 43,162 |
| lone negative, (iv) everything exists | 630 | 16,755,403 | 24,292 | 387 | 16,739,129 | 38,692 | 418 | 16,769,735 | 38,691 |

## How many first tags fit one publication (2^24, at most 64 actions) *(measured)*

| depth | shape | prague | amsterdam, all gas | amsterdam, execution only |
|---:|---|---:|---:|---:|
| 64 | best: everything exists (case iv) | 13 | 4 | 14 |
| 64 | worst on one topic: a new path, every tag on its deepest topic | 5 | 0 | 8 |
| 64 | worst: every tag on its own new path | 3 | 0 | 5 |
| 8 | best: everything exists (case iv) | 42 | 13 | 49 |
| 8 | worst on one topic: a new path, every tag on its deepest topic | 27 | 6 | 38 |
| 8 | worst: every tag on its own new path | 18 | 4 | 27 |

## D: what one list entry costs a spammer *(measured)*

| entry | prague alone (tx) | prague per entry, 64 in one publication (tx) | amsterdam alone, all (tx) | amsterdam per entry of 64, all (tx) | amsterdam per entry of 64, execution (tx) |
|---|---:|---:|---:|---:|---:|
| a `place` entry: a lone negative at a fresh position of a 1-word topic | 675,254 | 349,818 | 2,204,936 | 1,273,232 | 243,542 |
| a `place-below` entry of an ancestor: a lone negative at a fresh position of its child topic | 723,428 | 372,490 | 2,355,530 | 1,333,263 | 262,263 |
| a `position-authors` entry: a fresh account's first publication, one lone negative at an existing position | 594,144 | — | 1,845,466 | — | — |
| the same by an account that has written before (one per position, for comparison) | 577,068 | — | 1,747,570 | — | — |

## Opening a topic's shared list at registration *(computed, not built)*

| n | prague today | prague opened | amsterdam all today | amsterdam all opened | amsterdam exec today | amsterdam exec opened |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 916,791 | 881,526 | 3,312,219 | 3,056,139 | 668,379 | 706,059 |
| 8 | 1,168,498 | 1,086,213 | 4,268,074 | 3,670,554 | 840,874 | 928,794 |
| 64 | 4,703,760 | 3,963,195 | 17,661,576 | 12,283,896 | 3,267,336 | 4,058,616 |

Per registered topic, added at registration (≈ one new list head, priced as tagLevel.sharedNew): prague 25,414, amsterdam all 113,431 (execution 15,511).

- **Reading the open-at-registration table (computed).** "opened" = the measured case (i) alone minus (n − 1) ×
  (`tagLevel.sharedNew` − `tagLevel.sharedExisting`) of the same schedule and quantity: if registering a topic also
  wrote that topic's `place-below` list head, every shared roll-up a first tag appends to would already exist and
  only the author's own lists could be new. It takes a 64-word first tag from 17.66M to about 12.28M of all gas on
  amsterdam, under 2^24 (17.66M is not), and from 4.70M to about 3.96M on prague. It does the opposite to amsterdam
  execution gas (3.27M → about 4.06M), because an append to an existing list is more execution gas than a new head.
  The price is one more list head per registered topic, paid at registration and priced as one `sharedNew` entry:
  25,414 on prague, 113,431 all (15,511 execution) on amsterdam. Not built.
- **The batch table** finds the largest k in 1..64 whose publication fits by bisection, every k measured from the
  same prepared state; "worst: every tag on its own new path" was measured over 8 paths at depth 64 and 64 paths at
  depth 8, more than any row fits. A 64-word first tag on an all-new path does not fit alone under the all-gas reading
  on amsterdam (17.66M), so that row's capacity is 0.
- **The floor** *(measured, `test/integration/IndexFloor.t.sol`)*. On amsterdam 64 lone negatives on a one-word topic
  execute in 15.41M (12.55M at step 3a) and need 18.88M of visible execution gas by the floor's sufficient bound, which
  therefore certifies 56 per transaction (16.51M); on prague their execution gas alone is over the cap at 64, as at
  step 3a.
- **Ordinary file work** (table B): a created file pays a `position-authors` entry (a new list) and, at a fresh
  position, a `place` entry (a new list for an empty home, an existing one in a folder with files): +54k to +60k on
  prague (3.5–3.8%), +230k to +243k all gas on amsterdam (4.1–4.5%). An edit is a HEAD re-bind and writes no list
  (+1k, the larger index).
