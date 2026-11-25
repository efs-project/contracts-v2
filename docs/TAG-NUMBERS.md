# Tags: the measured costs of the first-statement lists (step 3b)

The numbers of the five lists of docs/TAG-DESIGN.md §4 as built (design §10.2 families 6, 7, 19, 20 and 21), on the
real Files Realm: the real `topic-word/1` and `topic/1` Types, `FilesFinalValidator` and the generation-1 index with
its topic lists. `docs/spike/TAG-SPIKE-NUMBERS.md` stays as the spike's record; nothing here replaces it.

**Every figure is marked.** *(measured)*: logged by a test run on the tree of commit `d644bba` (tables A, B, C, the
batch table and D; the step 3b amendments: `place`/`place-below` file every later author's first yes, `position-authors`
keeps a yes-count, the validator's code 15 — source of `3df33e8`, `d644bba` adds only measurement rows), table E and its
"before" column at `17326e0` (its "before" on an export of `5d1cc7d` with the same measurement suite), the per-level
terms at `17326e0` (`gas/model.json`), Foundry 1.8.3, solc 0.8.37 via-IR. Every table of this file was re-measured for
the amendments; the pre-amendment figures are in the history of this file at `5d1cc7d`. *(computed)*: arithmetic on measured figures, with its inputs stated.

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
| `bindTagFresh`: a first tag on a fresh position of a 1-word topic | 414,271 | 1,646,217 | 275,337 |
| `bindTagSecondAuthor`: a later author's first tag on an existing position of a 1-word topic (files one `place` entry) | 312,871 | 1,119,117 | 237,837 |
| `tagLevel.mineNew`: one per-author roll-up entry on a new list | 34,627 | 122,659 | 24,739 |
| `tagLevel.mineExisting`: one per-author roll-up entry on an existing list | 22,871 | 37,268 | 37,268 |
| `tagLevel.sharedNew`: one shared roll-up entry on a new list (every filing: a fresh position or a later first yes) | 27,139 | 115,156 | 17,236 |
| `tagLevel.sharedExisting`: one shared roll-up entry on an existing list | 15,354 | 29,765 | 29,765 |

For an n-word topic: the fresh-position or later-author term, plus, per proper ancestor, mine new or existing and (at
every filing: a fresh position of either sign, or a later author's first yes) shared new or existing; a later author's
first no pays no shared term, and `bindTagSecondAuthor` (measured as a yes) is an upper bound for it. The model's
composite "a first tag on a fresh 6-word path" predicts 1,045,503 against 1,038,300 measured on prague (+0.69%) and
3,748,212 against 3,785,808 on amsterdam (-0.99%). The "mine" rows are now measured with a later author's first no
(which files nothing below), since a later first yes also files a shared entry. Before the amendments (`5d1cc7d`):
`bindTagSecondAuthor` 290,991 prague, 1,016,405 / 233,045 amsterdam; the per-level terms moved by under 2k (the
statement measured changed, not the walk). On amsterdam an
existing list costs more execution gas than a new one: a rewrite is 12,100 of execution gas under EIP-8038, while a new
slot's 110,020 is mostly state gas. That is why case (ii) reaches only 239 words on the execution-only reading in
table C, fewer than case (i)'s 366.

**A number change no longer touches the backlink list** (design §10.2: a BIND that keeps its asserted target skips
family 5) *(measured, `bindTagNumberChange`, step 3a → 3b)*: prague 192,466 → 153,453 (−39,013); amsterdam all
566,012 → 431,867 (−134,145), execution 174,332 → 138,107 (−36,225).

## A (a first tag): one statement on an n-word topic *(measured)*

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 731,634 | 402,785 | 2,598,932 | 542,612 | 1,585,835 | 269,355 |
| (i) everything new | 2 | 791,768 | 425,900 | 2,835,106 | 582,946 | 1,648,052 | 288,052 |
| (i) everything new | 4 | 918,606 | 478,739 | 3,314,058 | 670,218 | 1,779,086 | 332,046 |
| (i) everything new | 8 | 1,171,189 | 583,256 | 4,270,789 | 843,589 | 2,039,990 | 418,870 |
| (i) everything new | 16 | 1,675,757 | 791,703 | 6,183,689 | 1,189,769 | 2,561,235 | 591,955 |
| (i) everything new | 32 | 2,686,541 | 1,210,248 | 10,011,101 | 1,883,741 | 3,605,336 | 939,736 |
| (i) everything new | 64 | 4,718,715 | 2,057,953 | 17,676,555 | 3,282,315 | 5,704,170 | 1,645,930 |
| (ii) lists exist, position new | 1 | 727,460 | 400,368 | 2,528,338 | 569,938 | 1,573,649 | 268,049 |
| (ii) lists exist, position new | 2 | 764,052 | 423,489 | 2,593,730 | 635,330 | 1,635,894 | 286,774 |
| (ii) lists exist, position new | 4 | 843,806 | 476,344 | 2,731,118 | 772,718 | 1,766,989 | 330,829 |
| (ii) lists exist, position new | 8 | 1,002,221 | 580,888 | 3,004,721 | 1,046,321 | 2,028,001 | 417,761 |
| (ii) lists exist, position new | 16 | 1,318,453 | 789,379 | 3,551,365 | 1,592,965 | 2,549,472 | 591,072 |
| (ii) lists exist, position new | 32 | 1,952,565 | 1,208,017 | 4,646,265 | 2,687,865 | 3,594,025 | 939,305 |
| (ii) lists exist, position new | 64 | 3,231,395 | 2,055,914 | 6,846,695 | 4,888,295 | 5,693,762 | 1,646,402 |
| (iii) position exists, my roll-ups new | 1 | 656,779 | 320,715 | 2,193,597 | 528,957 | 1,156,312 | 242,392 |
| (iii) position exists, my roll-ups new | 2 | 721,885 | 341,043 | 2,441,943 | 581,463 | 1,205,973 | 259,413 |
| (iii) position exists, my roll-ups new | 4 | 858,664 | 388,304 | 2,945,236 | 693,076 | 1,311,892 | 300,052 |
| (iii) position exists, my roll-ups new | 8 | 1,131,130 | 481,667 | 3,950,650 | 915,130 | 1,522,565 | 380,165 |
| (iii) position exists, my roll-ups new | 16 | 1,675,464 | 667,801 | 5,960,916 | 1,358,676 | 1,943,351 | 539,831 |
| (iii) position exists, my roll-ups new | 32 | 2,765,780 | 1,041,729 | 9,983,060 | 2,247,380 | 2,786,533 | 860,773 |
| (iii) position exists, my roll-ups new | 64 | 4,957,020 | 1,800,201 | 18,037,980 | 4,035,420 | 4,483,529 | 1,513,289 |
| (iv) everything exists | 1 | 613,130 | 286,589 | 1,914,888 | 544,008 | 960,743 | 242,663 |
| (iv) everything exists | 2 | 649,365 | 309,354 | 1,979,923 | 609,043 | 1,022,631 | 261,031 |
| (iv) everything exists | 4 | 728,436 | 361,480 | 2,116,594 | 745,714 | 1,153,009 | 304,369 |
| (iv) everything exists | 8 | 885,384 | 464,592 | 2,388,764 | 1,017,884 | 1,412,589 | 389,869 |
| (iv) everything exists | 16 | 1,198,750 | 670,217 | 2,932,542 | 1,561,662 | 1,931,189 | 560,309 |
| (iv) everything exists | 32 | 1,827,130 | 1,083,127 | 4,021,710 | 2,650,830 | 2,970,011 | 902,811 |
| (iv) everything exists | 64 | 3,094,498 | 1,919,557 | 6,210,678 | 4,839,798 | 5,058,285 | 1,598,445 |

## A (a lone negative): one statement on an n-word topic *(measured)*

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 672,617 | 343,725 | 2,275,955 | 513,395 | 1,262,811 | 240,091 |
| (i) everything new | 2 | 732,738 | 366,823 | 2,512,128 | 553,728 | 1,325,027 | 258,787 |
| (i) everything new | 4 | 859,583 | 419,673 | 2,991,075 | 640,995 | 1,456,056 | 302,776 |
| (i) everything new | 8 | 1,112,157 | 524,177 | 3,947,809 | 814,369 | 1,716,963 | 389,603 |
| (i) everything new | 16 | 1,616,695 | 732,594 | 5,860,679 | 1,160,519 | 2,238,178 | 562,658 |
| (i) everything new | 32 | 2,627,455 | 1,151,116 | 9,688,067 | 1,854,467 | 3,282,256 | 910,416 |
| (i) everything new | 64 | 4,659,559 | 1,998,750 | 17,353,451 | 3,252,971 | 5,381,019 | 1,616,539 |
| (ii) lists exist, position new | 1 | 668,443 | 341,309 | 2,205,361 | 540,721 | 1,250,626 | 238,786 |
| (ii) lists exist, position new | 2 | 705,022 | 364,417 | 2,270,752 | 606,112 | 1,312,871 | 257,511 |
| (ii) lists exist, position new | 4 | 784,783 | 417,275 | 2,408,135 | 743,495 | 1,443,960 | 301,560 |
| (ii) lists exist, position new | 8 | 943,189 | 521,811 | 2,681,741 | 1,017,101 | 1,704,976 | 388,496 |
| (ii) lists exist, position new | 16 | 1,259,391 | 730,272 | 3,228,355 | 1,563,715 | 2,226,416 | 561,776 |
| (ii) lists exist, position new | 32 | 1,893,479 | 1,148,886 | 4,323,231 | 2,658,591 | 3,270,946 | 909,986 |
| (ii) lists exist, position new | 64 | 3,172,239 | 1,996,712 | 6,523,591 | 4,858,951 | 5,370,612 | 1,617,012 |
| (iii) position exists, my roll-ups new | 1 | 562,083 | 250,246 | 1,732,621 | 459,661 | 805,000 | 195,720 |
| (iii) position exists, my roll-ups new | 2 | 596,750 | 264,402 | 1,855,320 | 484,440 | 838,717 | 207,677 |
| (iii) position exists, my roll-ups new | 4 | 666,032 | 292,662 | 2,100,630 | 533,910 | 906,070 | 231,510 |
| (iii) position exists, my roll-ups new | 8 | 811,282 | 355,913 | 2,597,994 | 639,594 | 1,047,516 | 285,916 |
| (iii) position exists, my roll-ups new | 16 | 1,100,821 | 481,382 | 3,591,705 | 849,945 | 1,329,400 | 393,720 |
| (iii) position exists, my roll-ups new | 32 | 1,679,923 | 732,363 | 5,579,115 | 1,270,635 | 1,893,154 | 609,314 |
| (iii) position exists, my roll-ups new | 64 | 2,842,075 | 1,238,276 | 9,557,907 | 2,115,987 | 3,024,636 | 1,044,476 |
| (iv) everything exists | 1 | 552,607 | 230,754 | 1,649,625 | 474,585 | 695,012 | 194,532 |
| (iv) everything exists | 2 | 575,503 | 244,917 | 1,686,933 | 511,893 | 728,746 | 206,506 |
| (iv) everything exists | 4 | 621,243 | 273,187 | 1,761,461 | 586,421 | 796,124 | 230,364 |
| (iv) everything exists | 8 | 719,409 | 336,446 | 1,917,261 | 742,221 | 937,631 | 284,831 |
| (iv) everything exists | 16 | 914,780 | 461,943 | 2,227,844 | 1,052,804 | 1,219,623 | 392,743 |
| (iv) everything exists | 32 | 1,305,546 | 712,968 | 2,848,998 | 1,673,958 | 1,783,600 | 608,560 |
| (iv) everything exists | 64 | 2,091,026 | 1,218,973 | 4,095,278 | 2,920,238 | 2,915,533 | 1,044,173 |

## B: ordinary file work, step 3a against step 3b as amended *(measured)*

| operation | prague 3a | prague 3b | Δ | amsterdam all 3a | amsterdam all 3b | Δ | amsterdam exec 3a | amsterdam exec 3b | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| create file in a folder with files | 1,642,414 | 1,704,184 | 61,770 (3.8%) | 5,855,340 | 6,100,262 | 244,922 (4.2%) | 1,253,100 | 1,302,182 | 49,082 (3.9%) |
| create file in an empty home | 1,545,370 | 1,601,719 | 56,349 (3.6%) | 5,347,542 | 5,579,931 | 232,389 (4.3%) | 1,234,902 | 1,271,451 | 36,549 (3.0%) |
| create file in a home with files | 1,550,836 | 1,612,475 | 61,639 (4.0%) | 5,360,196 | 5,604,987 | 244,791 (4.6%) | 1,247,556 | 1,296,507 | 48,951 (3.9%) |
| edit | 858,092 | 859,873 | 1,781 (0.2%) | 2,768,808 | 2,770,601 | 1,793 (0.1%) | 712,488 | 714,281 | 1,793 (0.3%) |

## C: the deepest topic whose single first statement fits one transaction (2^24) *(measured)*

| statement, case | prague: deepest | tx gas at it | per level | amsterdam all gas: deepest | tx gas at it | per level | amsterdam execution only: deepest | tx execution gas at it | per level |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tag, (i) everything new | 254 | 16,626,910 | 63,183 | 60 | 16,659,330 | 239,223 | 366 | 16,764,965 | 43,383 |
| tag, (ii) lists exist, position new | 395 | 16,740,256 | 39,641 | 208 | 16,734,587 | 68,441 | 239 | 16,759,237 | 68,441 |
| tag, (iii) position exists, my roll-ups new | 238 | 16,731,737 | 68,127 | 59 | 16,715,872 | 251,267 | 286 | 16,731,836 | 55,427 |
| tag, (iv) everything exists | 401 | 16,744,140 | 39,283 | 217 | 16,757,597 | 68,084 | 240 | 16,727,286 | 68,083 |
| lone negative, (i) everything new | 254 | 16,567,055 | 63,181 | 61 | 16,572,474 | 239,221 | 366 | 16,734,648 | 43,381 |
| lone negative, (iv) everything exists | 627 | 16,774,369 | 24,428 | 386 | 16,763,448 | 38,828 | 416 | 16,759,085 | 38,827 |

## How many first tags fit one publication (2^24, at most 64 actions) *(measured)*

| depth | shape | prague | amsterdam, all gas | amsterdam, execution only |
|---:|---|---:|---:|---:|
| 64 | best: everything exists (case iv) | 8 | 2 | 8 |
| 64 | worst on one topic: a new path, every tag on its deepest topic | 5 | 0 | 8 |
| 64 | worst: every tag on its own new path | 3 | 0 | 5 |
| 8 | best: everything exists (case iv) | 35 | 11 | 41 |
| 8 | worst on one topic: a new path, every tag on its deepest topic | 27 | 6 | 38 |
| 8 | worst: every tag on its own new path | 18 | 4 | 27 |

## D: what one list entry costs a spammer *(measured)*

| entry | prague alone (tx) | prague per entry, 64 in one publication (tx) | amsterdam alone, all (tx) | amsterdam per entry of 64, all (tx) | amsterdam per entry of 64, execution (tx) |
|---|---:|---:|---:|---:|---:|
| a `place` entry: a lone negative at a fresh position of a 1-word topic (an address-shaped role) | 675,818 | 350,410 | 2,205,548 | 1,273,824 | 244,134 |
| a `place-below` entry of an ancestor: a lone negative at a fresh position of its child topic | 724,180 | 373,239 | 2,356,330 | 1,334,013 | 263,013 |
| one more `place` entry for an EXISTING position: a fresh account's first publication, a first yes there (per entry of 64: one fresh account, 64 existing positions of the place) | 682,919 | 336,123 | 2,219,749 | 1,190,931 | 256,101 |
| the same on a 2-word topic: one `place` entry and one `place-below` entry of the ancestor | 713,852 | 341,527 | 2,272,382 | 1,152,973 | 274,753 |
| a `position-authors` entry: a fresh account's first publication, one lone negative at an existing position | 604,939 | — | 1,856,309 | — | — |
| the same by an account that has written before (one per position, for comparison) | 587,863 | — | 1,758,413 | — | — |

## E: a mask, a release and a restore, before and after the yes-count *(measured)*

One cooled publication of one statement by an author who has written before, on a position with another author (TAG:
a 2-word topic; FOLDER: the author's home, a real name). Transaction gas (frame + 21,000 + calldata). "before" =
`5d1cc7d`, "after" = `17326e0`. A transition away from or back to BOUND pays one more posting-store call (family 20's
`release` or `retain`: a warm call and one slot rewrite of the position's list head); a mask or release of a masked head
writes nothing new (the +269/+303 is the larger index's code paths).

| purpose | transition | prague before | prague after | Δ | amsterdam all before | after | Δ | amsterdam execution before | after | Δ |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TAG | mask asserted | 456,613 | 471,307 | 14,694 | 1,208,749 | 1,230,609 | 21,860 | 425,389 | 447,249 | 21,860 |
| TAG | release asserted | 438,392 | 453,062 | 14,670 | 1,109,808 | 1,131,678 | 21,870 | 424,368 | 446,238 | 21,870 |
| TAG | restore from masked | 470,749 | 485,371 | 14,622 | 1,237,385 | 1,259,207 | 21,822 | 454,025 | 475,847 | 21,822 |
| TAG | restore from released | 470,749 | 485,371 | 14,622 | 1,237,385 | 1,259,207 | 21,822 | 454,025 | 475,847 | 21,822 |
| TAG | mask of masked | 422,079 | 422,348 | 269 | 1,086,295 | 1,086,564 | 269 | 400,855 | 401,124 | 269 |
| TAG | release of masked | 421,148 | 421,417 | 269 | 1,085,364 | 1,085,633 | 269 | 399,924 | 400,193 | 269 |
| FOLDER | mask asserted | 455,762 | 470,500 | 14,738 | 1,207,922 | 1,229,826 | 21,904 | 424,562 | 446,466 | 21,904 |
| FOLDER | release asserted | 437,541 | 452,255 | 14,714 | 1,108,981 | 1,130,895 | 21,914 | 423,541 | 445,455 | 21,914 |
| FOLDER | restore from masked | 500,718 | 515,364 | 14,646 | 1,348,088 | 1,369,910 | 21,822 | 466,808 | 488,630 | 21,822 |
| FOLDER | restore from released | 483,669 | 498,291 | 14,622 | 1,250,353 | 1,272,151 | 21,798 | 466,993 | 488,791 | 21,798 |
| FOLDER | mask of masked | 421,228 | 421,531 | 303 | 1,085,468 | 1,085,771 | 303 | 400,028 | 400,331 | 303 |
| FOLDER | release of masked | 420,297 | 420,600 | 303 | 1,084,537 | 1,084,840 | 303 | 399,097 | 399,400 | 303 |

## Opening a topic's shared list at registration *(computed, not built)*

| n | prague today | prague opened | amsterdam all today | amsterdam all opened | amsterdam exec today | amsterdam exec opened |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 918,606 | 883,251 | 3,314,058 | 3,057,885 | 670,218 | 707,805 |
| 8 | 1,171,189 | 1,088,694 | 4,270,789 | 3,673,052 | 843,589 | 931,292 |
| 64 | 4,718,715 | 3,976,260 | 17,676,555 | 12,296,922 | 3,282,315 | 4,071,642 |

Per registered topic, added at registration (≈ one new list head, priced as tagLevel.sharedNew): prague 27,139, amsterdam all 115,156 (execution 17,236).

- **Reading the open-at-registration table (computed).** "opened" = the measured case (i) alone minus (n − 1) ×
  (`tagLevel.sharedNew` − `tagLevel.sharedExisting`) of the same schedule and quantity: if registering a topic also
  wrote that topic's `place-below` list head, every shared roll-up a first tag appends to would already exist and
  only the author's own lists could be new. It takes a 64-word first tag from 17.68M to about 12.30M of all gas on
  amsterdam, under 2^24 (17.68M is not), and from 4.72M to about 3.98M on prague. It does the opposite to amsterdam
  execution gas (3.28M → about 4.07M), because an append to an existing list is more execution gas than a new head.
  The price is one more list head per registered topic, paid at registration and priced as one `sharedNew` entry:
  27,139 on prague, 115,156 all (17,236 execution) on amsterdam. Not built.
- **The batch table** finds the largest k in 1..64 whose publication fits by bisection, every k measured from the
  same prepared state; "worst: every tag on its own new path" was measured over 8 paths at depth 64 and 64 paths at
  depth 8, more than any row fits. A 64-word first tag on an all-new path does not fit alone under the all-gas reading
  on amsterdam (17.68M), so that row's capacity is 0.
- **The floor** *(measured, `test/integration/IndexFloor.t.sol`)*. On amsterdam 64 lone negatives on a one-word topic
  execute in 15.46M (15.41M before the amendments, 12.55M at step 3a) and need 18.93M of visible execution gas by the
  floor's sufficient bound (18.88M before), which therefore still certifies 56 per transaction (16.56M); on prague their execution gas alone is over the cap at 64, as at
  step 3a.
- **Ordinary file work** (table B): a created file pays a `position-authors` entry (a new list) and, at a fresh
  position, a `place` entry (a new list for an empty home, an existing one in a folder with files): +56k to +62k on
  prague (3.6–4.0%), +232k to +245k all gas on amsterdam (4.2–4.6%); the amendments add about 2k to each (the
  validator's and the index's larger code paths). An edit is a HEAD re-bind and writes no list (+1.8k).
- **What the amendments cost** *(measured, against `5d1cc7d`)*. A later author's first yes now files: a `place` entry
  and, per proper ancestor, a `place-below` entry, so cases (iii) and (iv) of a first tag pay the shared per-level
  terms (table A: case (iii) at n = 64 2,894,877 → 4,957,020 on prague; case (iv) at n = 1 598,812 → 613,130), table C
  falls for them (prague (iii) 443 → 238 words, (iv) 628 → 401; amsterdam execution (iii) 589 → 286, (iv) 416 → 240),
  and the batch table's best case falls (depth 64: 13 → 8 on prague, 4 → 2 and 14 → 8 on amsterdam; depth 8: 42 → 35,
  13 → 11, 49 → 41). A first no at an existing position files nothing new and moves by the validator's code-15 read
  (case (iii) lone negative at n = 1: 551,276 → 562,083 on prague, a subject role: no record at the id, then the
  subject's creation). A mask, a release and a restore of an asserted head pay one posting-store call more (table E:
  about +14.7k on prague, +21.9k on amsterdam, all of it execution gas: a warm call and one slot rewrite).
- **The new spam row** (table D): one more `place` entry for a position that already exists needs an author who never
  stated anything there, so a fresh account each time; a fresh account can file at most once per existing position,
  so 64 entries take 64 existing positions at the place. Per entry of 64 it costs about the same as a fresh-position
  lone negative (336,123 against 350,410 on prague; on amsterdam 1,190,931 against 1,273,824 all, 256,101 against
  244,134 execution); the `place` list's `live` (distinct positions) does not move, so a reader that counts positions
  is not misled, and readers remove the duplicate rows by position.
