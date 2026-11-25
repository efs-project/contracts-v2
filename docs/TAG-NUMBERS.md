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
- **The floor** *(measured, `test/integration/IndexFloor.t.sol`, both profiles)*. With the work model re-measured on
  the amended lists (design §10.4), 64 lone negatives on a one-word topic execute in 15.46M on amsterdam, the kernel's
  own share K is 7.34M, the prefix floor 8.32M (1.07× the callbacks' 7.77M) and the final reserve 494k (1.39× the final
  phase's 355k); the floor's requirement V = max(K + P·(64/63)² + 2k, E) + F·64/63 + 20k is 16.46M, within the 16.60M a
  2^24 transaction leaves after intrinsic gas and calldata, so all 64 are admitted in one publication. (The step-3b
  figure, 56, came from a bound that took the callbacks' spend as 60k per bind; K is now measured, by the same
  publication with the index's callbacks mocked.) On prague their execution gas alone (22.32M) is over the cap.
  The final phase's worst cases, 64 actions each (prague / amsterdam execution gas, reserve 494k): first masks about
  64 created subjects 994k / 994k, about 64 records 738k / 738k, first tags on 64 distinct topics 471k / 471k, lone
  negatives about addresses 355k / 355k: the per-bind reserve is set from the topics row, and a per-bind term large
  enough for the subjects row would put 64 lone negatives over the cap (design §10.4).
- **The planning rule** *(measured, `test/integration/FloorPlan.t.sol`; `gas/model.json` `planning`)*: the largest
  publication the rule plans of each shape, its measured execution gas E and the floor's requirement V (both against
  the 16.58M-16.75M of visible execution gas the transaction leaves); every one is admitted, on prague also by running
  it with exactly that gas. "next" is one unit more: refused by the rule for gas (on prague, run anyway, it was still
  admitted: the rule is conservative) or past the 64-action limit.

  | shape | prague k | E | V | next | amsterdam k | E (execution) | V | next |
  |---|---:|---:|---:|---|---:|---:|---:|---|
  | lone negatives, one-word topic | 38 | 13,145,643 | 14,334,338 | gas | 54 | 12,970,264 | 13,891,774 | gas |
  | first tags, depth 8, everything new | 18 | 11,232,262 | 11,407,894 | gas | 19 | 8,425,173 | 8,608,323 | gas |
  | first tags, depth 64, everything new | 3 | 10,447,334 | 10,510,204 | gas | 3 | 7,443,234 | 7,506,104 | gas |
  | first tags, depth 8, everything existing | 22 | 11,364,484 | 11,570,186 | gas | 20 | 8,307,367 | 8,498,034 | gas |
  | first tags, depth 64, everything existing | 4 | 8,220,552 | 8,290,940 | gas | 3 | 7,354,489 | 7,417,359 | gas |
  | second author's first tags, depth 8 | 22 | 11,652,528 | 11,858,230 | gas | 20 | 8,311,537 | 8,502,204 | gas |
  | masks of tags | 64 | 11,158,719 | 11,680,154 | limit | 64 | 11,708,217 | 12,229,652 | limit |
  | releases of tags | 64 | 11,079,337 | 11,600,772 | limit | 64 | 11,628,835 | 12,150,270 | limit |
  | restores of tags | 64 | 13,147,742 | 13,669,177 | limit | 64 | 13,507,294 | 14,028,729 | limit |
  | registration chunk (word pages) | 64 | 13,908,308 | 14,092,263 | limit | 64 | 10,334,848 | 10,429,824 | limit |
  | create-file recipes (5 actions each) | 10 | 12,910,510 | 14,047,533 | gas | 12 | 10,863,547 | 11,781,879 | limit |

  The model's estimates for deep tags run 15-45% high (the composition prices every roll-up append from the
  per-level terms with the price-as-new rule), so the rule under-fills those publications rather than over-fills them.
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

## Reads (step 4, amended; the viewed-place check cut) *(measured)*

The topic readers of design §5.13 and §11 (`TopicMineReader`, `TopicEveryoneReader`, `TopicLookupReader`) on the
real Realm of the reader suites (the step-3c lists, `FilesFinalValidator`, the Topics Types), after the step-4
amendment (the combined lens walk with the viewed-place check below, the yes-count read before any lens read in
`everyone`, the decider's number) and the release step's cut of the viewed-place check: it reads head states only
(`LedgerViews.headStates`, one word per head, where `heads` read two) and leaves out what cannot be MASKED (a lens
author whose exact scope list at the place is all live, in `mine`; with at least 4 lens authors to ask, a viewed
position nobody ever stated anything at, in both views; `TopicReaderBase._maskedAt` states why each is exact).
"Before" is `main` 3d68a89 (the committed `gas/model.json`; the two worst-case fixtures, new here, measured on a
`git archive 3d68a89` export with the same suite), "after" the source of 7121927; Foundry 1.8.3, solc 0.8.37 via-IR.
The after rows are `gas/model.json` `reads` (`pnpm run gas:model` writes them, `pnpm run gas:model:check` compares
them exactly). Every figure is one cold `view` call: every account the call can touch is cooled first (`vm.cool`),
and the figure is the call frame's gas (`vm.lastCallGas().gasTotalUsed`; no intrinsic 21,000, no calldata). Setups
run with gas metering paused. Reads are not repriced on amsterdam: every row is within 0.1% of prague (about +4k, the
cold accounts), and the per-row terms are the same. `page` is `limit`, the list entries read; in these setups every
entry read is a row, except the padded stretch.

```sh
FOUNDRY_GAS_LIMIT=100000000000 perl -e 'alarm 5400; exec @ARGV' \
  forge test --match-path test/integration/TopicReadMeasure.t.sol -vv | grep ' tr '
FOUNDRY_GAS_LIMIT=100000000000 FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam \
  perl -e 'alarm 9000; exec @ARGV' forge test --match-path test/integration/TopicReadMeasure.t.sol -vv | grep ' tr '
```

**`mine`, exact plus below.** 50 things filed by the lens round-robin (thing i by lens author i mod L, so the newest
rows come from the highest lens indices that have entries), at depth 1 (the place itself) or under the deepest topic
of an 8- or 64-word path, read from its first word. Depth 8 and 64 cost the same to the gas: a read never walks a path.
At depth 8 and 64 every row is a roll-up row with the viewed-place check (ruling R3); nobody stated anything at the
place, so every lens author's exact list there is empty (all live) and the check now reads no head at all. Before →
after:

| lens | depth | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---:|---:|---|---|---|---|
| 1 | 1 | 583,111 → 576,269 | 587,311 → 580,469 | 2,400,616 → 2,362,014 | 2,405,416 → 2,366,814 |
| 1 | 8 | 706,363 → 563,194 | 710,563 → 567,394 | 3,152,520 → 2,427,134 | 3,157,320 → 2,431,934 |
| 1 | 64 | 706,363 → 563,194 | 710,563 → 567,394 | 3,152,520 → 2,427,134 | 3,157,320 → 2,431,934 |
| 8 | 1 | 1,048,408 → 1,043,236 | 1,052,608 → 1,047,436 | 3,615,223 → 3,574,302 | 3,620,023 → 3,579,102 |
| 8 | 8 | 1,576,465 → 1,099,766 | 1,580,665 → 1,103,966 | 6,603,077 → 3,670,736 | 6,607,877 → 3,675,536 |
| 8 | 64 | 1,576,465 → 1,099,766 | 1,580,665 → 1,103,966 | 6,603,077 → 3,670,736 | 6,607,877 → 3,675,536 |
| 32 | 1 | 2,500,836 → 2,501,122 | 2,505,036 → 2,505,322 | 7,578,985 → 7,527,892 | 7,583,785 → 7,532,692 |
| 32 | 8 | 4,007,395 → 2,307,423 | 4,011,595 → 2,311,623 | 17,713,161 → 7,576,021 | 17,717,961 → 7,580,821 |
| 32 | 64 | 4,007,395 → 2,307,423 | 4,011,595 → 2,311,623 | 17,713,161 → 7,576,021 | 17,717,961 → 7,580,821 |
| 64 | 1 | 5,270,251 → 5,277,237 | 5,274,451 → 5,281,437 | 12,307,334 → 12,238,349 | 12,312,134 → 12,243,149 |
| 64 | 8 | 11,007,154 → 4,797,151 | 11,011,354 → 4,801,351 | 32,658,239 → 11,876,200 | 32,663,039 → 11,881,000 |
| 64 | 64 | 11,007,154 → 4,797,151 | 11,011,354 → 4,801,351 | 32,658,239 → 11,876,200 | 32,663,039 → 11,881,000 |

At lens 64, depth 8 the check had made a page of 10 cost 2.35 times what it cost before the check (4,686,038) and a
page of 50 2.83 times (11,544,029); it now costs 2.4% and 2.9% more than before the check. Depth 1 (exact rows) moves
by −1.6% to +0.1%.

**`mine`, the worst case of the check** (`mine worst`): the depth-8 fixture, but before the filings the last lens
author says yes to every thing at the place itself (so no viewed position's author list is empty) and every lens
author says "not this" about one other thing there (so no lens author's exact list there is all live). Those entries
are older than every filing, so the pages read only roll-up rows, every row shows, and every row reads the head
states of lens[0..j] at the viewed place (and, from j + 1 = 4, the author-list head first). Before → after:

| lens | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---:|---|---|---|---|
| 1 | 740,318 → 686,699 | 744,518 → 690,899 | 3,220,472 → 2,929,274 | 3,225,272 → 2,934,074 |
| 8 | 1,726,743 → 1,569,170 | 1,730,943 → 1,573,370 | 6,934,452 → 5,865,692 | 6,939,252 → 5,870,492 |
| 32 | 4,571,601 → 3,825,206 | 4,575,801 → 3,829,406 | 19,008,351 → 13,799,753 | 19,013,151 → 13,804,553 |
| 64 | 12,201,400 → 8,821,390 | 12,205,600 → 8,825,590 | 35,376,679 → 23,180,254 | 35,381,479 → 23,185,054 |

The one-word read saves about 9k per lens index on a row that needs the heads (24.5k → 15.4k per lens index). The
author-list read costs about 8k cold and saves about 2.4k per lens author it spares, so it is read only with at least 4
lens authors left to ask (`NOBODY_MIN_ASK`); read for every row it made the worst case at lens 1 dearer (740,318 →
831,323 at page 10) instead of cheaper.

**`everyone` and `raw`.** 60 things filed by one author at a one-word place's child; the exact view reads the child,
the below view the parent (the place list and the roll-up merged). The lens is 8 authors none of whom said anything,
so every lens head is read where the entry was filed. In the plain below fixture the things at the parent are other
things than at the child, so nobody stated anything at the viewed positions; in the worst case (`everyone worst
below`) the same 60 things are filed at both, so every viewed position holds a statement and all 8 lens authors are
asked there. Before the cut both cost the same (every viewed-place head was read). Before → after:

| view | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---|---|---|---|---|
| everyone, exact, lens of 8 | 1,096,193 → 1,088,601 | 1,100,193 → 1,092,601 | 5,247,023 → 5,205,963 | 5,252,223 → 5,211,163 |
| everyone, below, lens of 8 | 2,162,189 → 1,315,134 | 2,166,189 → 1,319,134 | 10,961,183 → 6,177,276 | 10,966,383 → 6,182,476 |
| everyone, below, lens of 8, worst | 2,162,189 → 1,808,276 | 2,166,189 → 1,812,276 | 10,961,183 → 8,692,141 | 10,966,383 → 8,697,341 |
| raw, exact | 537,945 → 538,317 | 541,745 → 542,117 | 2,446,182 → 2,447,872 | 2,450,582 → 2,452,272 |
| raw, below | 618,742 → 619,151 | 622,542 → 622,951 | 2,669,814 → 2,671,538 | 2,674,214 → 2,675,938 |

Before the step-4 amendment the same pages were 942,999 / 1,979,494 / 660,150 / 741,316 (page 10, prague) and 4,350,544 /
9,459,056 / 2,931,255 / 3,156,327 (page 50). `raw` and the point reads below move by at most +0.1% (the call state
carries two more words).

**A padded stretch** (ruling R8): 60 lone negatives by one stranger at a place's child (the place list of the child;
below, the roll-up of the place), so no entry is a row; a lens of L silent authors. Gas per SKIPPED entry, the page-60
minus page-20 difference over 40 entries: before the yes-count was read first (the lens read first), and now:

| lens | exact, lens first | exact, now (prague / amsterdam) | below, lens first | below, now (prague / amsterdam) |
|---:|---:|---:|---:|---:|
| 1 | 49,072 / 49,082 | 35,970 / 35,980 | 62,058 / 62,068 | 36,135 / 36,145 |
| 8 | 77,271 / 77,281 | 35,971 / 35,981 | 178,104 / 178,129 | 36,137 / 36,147 |
| 64 | 356,951 / 356,961 | 35,981 / 35,991 | 1,555,563 / 1,555,763 | 36,146 / 36,156 |

A skipped entry costs its cell and one author-list head whatever the lens: about 36k at every lens size, on both
schedules (+34 against 3d68a89). `test/readers/TopicLensOrder.t.sol` asserts it: at a lens of 64 a skipped entry costs
at most 1,000 gas more than at a lens of 1, and at most 45,000 in all. The SDK sizes its entry limit from this number.

**Point reads and directories.**

| read | prague | amsterdam |
|---|---:|---:|
| `byName`, 300 authors at one FOLDER position of a home, page of 10 | 363,480 | 367,280 |
| `byName`, the same, page of 50 | 1,273,480 | 1,277,280 |
| `about`, a thing filed under 20 places, page of 10 | 473,030 | 476,830 |
| `about`, page of 20 | 801,153 | 804,953 |
| `about`, page of 10 with a sample of 4 authors per row | 1,165,473 | 1,171,273 |
| `placeCount`, a place of 2,000 positions | 84,934 | 88,134 |
| `authorCount`, a position of 300 authors | 84,957 | 88,157 |
| `entryCount`, an author's 2,000 exact entries | 82,954 | 86,154 |
| `wordPage`, 1 place (the root place) | 151,549 | 154,849 |
| `wordPage`, 5 places | 355,165 | 358,865 |
| `wordPage`, 20 places (one page) | 1,066,470 | 1,071,670 |
| `children`, 16 child topics | 894,860 | 899,760 |
| `children`, a page of 1 | 185,725 | 189,125 |

**Bounded whatever the spam** (`test/readers/TopicLookup.t.sol`): `byName` page 1 at a position of 300 authors costs
within 0.5% of the same page at 3 authors (the larger ordinals' calldata), and `placeCount` and `byName` in a place of
2,000 positions cost the same to the gas as in a place of 3. A place padded with lone negatives around one real tag is
read in pages of 4 entries, each page `LIMIT` with a continuation, until the tag (`test/readers/TopicEveryone.t.sol`).

**Per row** *(fitted; `gas/model.json` `reads.schedules.<schedule>.terms`)*:

- `mine`, exact rows: an opening of about 192k + 28.4k per lens author, then per row about 36k + 6.6k·(j + 1), j the
  row's deciding lens index (least squares over the four lens sizes and both pages; within 11.5%).
- `mine`, roll-up rows (below), fitted on the worst case (`mineBelow`, the bounds): an opening of about 339k + 20.7k
  per lens author, then per row about 39k + 15.4k·(j + 1) (the filed-position state words and the viewed-place head
  states of lens[0..j]); within 31%, the largest error an overestimate at lens 1, page 10, the largest underestimate
  9.4% at lens 32, page 10. Before: 386k, then 22k + 24.5k·(j + 1). Where nothing is stated at the place
  (`mineBelowQuiet`) a row is about 37k + 6.7k·(j + 1), what an exact row costs.
- `everyone`, exact: about 61k to open, 48k per shown row without a lens (`raw`) and 6.9k more per lens author;
  below: about 106k to open, 51k per shown row and, in the worst case, 15.1k more per lens author (before: 21.1k);
  8.8k when the viewed positions are empty (`everyoneBelowQuiet`); every skipped entry about 36k at any lens.
- `byName` about 23k per row after an opening of about 136k; `about` about 33k per row (69k more with a sample of 4);
  `wordPage` and `children` about 47k per place after about 120k–140k.

**Call size** *(computed; `reads.schedules.<schedule>.bounds` and `recommended`)*. At a 10M cap less a 10% margin, the
most worst-case rows one call holds, by lens size, now (before):

| lens | `mine` exact | `mine` below | `everyone` exact | `everyone` below |
|---:|---:|---:|---:|---:|
| 1 | 208 (204) | 159 (183) | 163 (163) | 133 (122) |
| 8 | 96 (95) | 52 (39) | 86 (86) | 51 (40) |
| 16 | 59 (58) | 29 (20) | 56 (55) | 30 (22) |
| 32 | 31 (31) | 15 (10) | 33 (32) | 16 (12) |
| 64 | 15 (15) | 7 (5) | 18 (18) | 8 (6) |

(amsterdam: the same, except `mine` exact at lens 1, 207). `mine` below at lens 1 falls because its fit is now taken
on the worst case, whose lens-1 rows the fit overestimates; the measured worst case at lens 1 is cheaper than before.
At most 246 skipped entries in one `everyone` call at any lens on prague (245 on amsterdam; 246 on both before).
**Keep page × lens at or below about 768 for `mine` exact, 416 for `mine` below, 688 for `everyone` exact and 408 for
`everyone` below** (the published `pageTimesLens`, the smallest over lenses 8 to 64; before 760, 312, 688 and 320),
`maxRows` at most 150, and `limit` (entries) at most 245; a page that mixes rows and skipped entries stays under the
cap while opening + rows·row(L) + skipped·36k ≤ 9M. A consumer splits a read by these terms (`limit`, `maxRows`, and a
`gasReserve` that covers one batch of 16 rows) so that no lens fails as one call too big; a page cut by a bound is a
`LIMIT`, `ROWS` or `GAS` page with a continuation, never an empty or `UNKNOWN` one.
