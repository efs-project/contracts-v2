# Tags: the release's measured costs

The final tables for the tag release (docs/TAG-DESIGN.md, design §10.2, §10.4, §11, §12.5): the real Files Realm
with the `topic-word/1`, `topic/1` and `text/1` Types, `FilesFinalValidator`, the generation-1 index with its
first-statement lists (families 6, 7, 19, 20, 21) and work-model formula 2, and the three topic readers. One build,
one measurement: every figure in this file was measured on the integrated release tree (commit `073e653`, the
merge of the gateway split, the viewed-place check's cut and work-model formula 2; Foundry 1.8.3, solc 0.8.37
via-IR) on both fee schedules, by the commands below. Earlier step-by-step tables (step 3a against 3b, before and
after each amendment) are in this file's history; `docs/spike/TAG-SPIKE-NUMBERS.md` stays as the spike's record.

**Quantities.** Every measured publication is cooled first (each pays the cold costs of a transaction of its own),
native lane, by an author that has written before (no first-write surcharge, except the rows that say "fresh
account"). "prague" is the release schedule. On amsterdam (EIP-8037/8038) "all" = execution (regular) gas + state gas
and "exec" = execution gas only, the quantity the EIP-7825 cap (2^24 = 16,777,216) counts under EIP-8037's
execution-only reading. "alone" and "per extra" are the `execute` frame's gas (no intrinsic 21,000, no calldata);
"per extra" = (k10 − k1) / 9 of a batch of 10. Rows marked "(tx)" are transaction gas: frame + 21,000 + the
calldata's standard cost. *(computed)* marks arithmetic on measured figures, with its inputs stated.

**Commands** (repository root, the release bytes in `out/`, amsterdam never in the default `out/`; the deep and
batched suites need `FOUNDRY_GAS_LIMIT` raised, because Foundry draws amsterdam state gas from the call):

```sh
for f in TagListsMeasure TagListsFileMeasure TagNumberMeasure TopicMeasure IndexFloor FloorPlan; do
  FOUNDRY_GAS_LIMIT=100000000000 perl -e 'alarm 5400; exec @ARGV' \
    forge test --match-path test/integration/$f.t.sol --json -vv > prague-$f.json
  FOUNDRY_GAS_LIMIT=100000000000 FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam \
    perl -e 'alarm 9000; exec @ARGV' forge test --match-path test/integration/$f.t.sol --json -vv > amsterdam-$f.json
done
pnpm run gas:model     # the per-level terms and the reads (gas/model.json), both schedules
pnpm run gas:report -- --fixture <instance>   # the file recipes (gas/report.json)
```

The JSON's `decoded_logs` carry the rows: `tl <row> exec|state|all|tx|txexec` and `tlb <row> …` (TagLists*),
`num <row> …` (TagNumberMeasure), `topic <row> gas|frame gas|frame state gas` (TopicMeasure), `floor <shape> …`
(IndexFloor, FloorPlan); `tr <row>` (TopicReadMeasure, through `pnpm run gas:model`).

## The cases

(i) everything new: the author's roll-up lists, the shared lists and the position are all new; (ii) the author's
lists and the shared lists exist (6 entries), the position is new; (iii) the position exists (another author stated
it first) and this author's roll-up lists are new; (iv) everything exists: the position has two authors and the
author's lists hold 6 entries. n is the topic's number of words; a first statement on an n-word topic writes n − 1
entries in each roll-up it touches. A later author's first yes (cases iii and iv) files a `place` entry and, per
proper ancestor, a `place-below` entry, so it pays the shared per-level terms; a later author's first no files
nothing below the position.

## Writes

### A first tag, by depth and case

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 732,157 | 402,696 | 2,599,443 | 543,123 | 1,585,733 | 269,253 |
| (i) everything new | 2 | 792,291 | 425,811 | 2,835,617 | 583,457 | 1,647,950 | 287,950 |
| (i) everything new | 4 | 919,129 | 478,647 | 3,314,569 | 670,729 | 1,778,985 | 331,945 |
| (i) everything new | 8 | 1,171,712 | 583,163 | 4,271,300 | 844,100 | 2,039,888 | 418,768 |
| (i) everything new | 16 | 1,676,280 | 791,603 | 6,184,200 | 1,190,280 | 2,561,133 | 591,853 |
| (i) everything new | 32 | 2,687,064 | 1,210,148 | 10,011,612 | 1,884,252 | 3,605,235 | 939,635 |
| (i) everything new | 64 | 4,719,238 | 2,057,853 | 17,677,066 | 3,282,826 | 5,704,068 | 1,645,828 |
| (ii) lists exist, position new | 1 | 727,983 | 400,279 | 2,528,849 | 570,449 | 1,573,549 | 267,949 |
| (ii) lists exist, position new | 2 | 764,575 | 423,400 | 2,594,241 | 635,841 | 1,635,794 | 286,674 |
| (ii) lists exist, position new | 4 | 844,329 | 476,251 | 2,731,629 | 773,229 | 1,766,889 | 330,729 |
| (ii) lists exist, position new | 8 | 1,002,744 | 580,788 | 3,005,232 | 1,046,832 | 2,027,905 | 417,665 |
| (ii) lists exist, position new | 16 | 1,318,976 | 789,283 | 3,551,876 | 1,593,476 | 2,549,372 | 590,972 |
| (ii) lists exist, position new | 32 | 1,953,088 | 1,207,921 | 4,646,776 | 2,688,376 | 3,593,925 | 939,205 |
| (ii) lists exist, position new | 64 | 3,231,918 | 2,055,814 | 6,847,206 | 4,888,806 | 5,693,662 | 1,646,302 |
| (iii) position exists, my roll-ups new | 1 | 657,302 | 320,622 | 2,194,108 | 529,468 | 1,156,210 | 242,290 |
| (iii) position exists, my roll-ups new | 2 | 722,408 | 340,954 | 2,442,454 | 581,974 | 1,205,871 | 259,311 |
| (iii) position exists, my roll-ups new | 4 | 859,187 | 388,211 | 2,945,747 | 693,587 | 1,311,790 | 299,950 |
| (iii) position exists, my roll-ups new | 8 | 1,131,653 | 481,574 | 3,951,161 | 915,641 | 1,522,464 | 380,064 |
| (iii) position exists, my roll-ups new | 16 | 1,675,987 | 667,701 | 5,961,427 | 1,359,187 | 1,943,249 | 539,729 |
| (iii) position exists, my roll-ups new | 32 | 2,766,303 | 1,041,629 | 9,983,571 | 2,247,891 | 2,786,431 | 860,671 |
| (iii) position exists, my roll-ups new | 64 | 4,957,543 | 1,800,101 | 18,038,491 | 4,035,931 | 4,483,428 | 1,513,188 |
| (iv) everything exists | 1 | 613,653 | 286,489 | 1,915,399 | 544,519 | 960,647 | 242,567 |
| (iv) everything exists | 2 | 649,888 | 309,258 | 1,980,434 | 609,554 | 1,022,535 | 260,935 |
| (iv) everything exists | 4 | 728,959 | 361,391 | 2,117,105 | 746,225 | 1,152,909 | 304,269 |
| (iv) everything exists | 8 | 885,907 | 464,499 | 2,389,275 | 1,018,395 | 1,412,488 | 389,768 |
| (iv) everything exists | 16 | 1,199,273 | 670,121 | 2,933,053 | 1,562,173 | 1,931,089 | 560,209 |
| (iv) everything exists | 32 | 1,827,653 | 1,083,026 | 4,022,221 | 2,651,341 | 2,969,911 | 902,711 |
| (iv) everything exists | 64 | 3,095,021 | 1,919,457 | 6,211,189 | 4,840,309 | 5,058,185 | 1,598,345 |

### A lone negative ("not this" about something never stated), by depth and case

| case | n | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all | amsterdam per extra, exec |
|---|---:|---:|---:|---:|---:|---:|---:|
| (i) everything new | 1 | 673,190 | 343,682 | 2,276,504 | 513,944 | 1,262,761 | 240,041 |
| (i) everything new | 2 | 733,311 | 366,788 | 2,512,677 | 554,277 | 1,324,977 | 258,737 |
| (i) everything new | 4 | 860,156 | 419,630 | 2,991,624 | 641,544 | 1,456,006 | 302,726 |
| (i) everything new | 8 | 1,112,730 | 524,134 | 3,948,358 | 814,918 | 1,716,913 | 389,553 |
| (i) everything new | 16 | 1,617,268 | 732,544 | 5,861,228 | 1,161,068 | 2,238,128 | 562,608 |
| (i) everything new | 32 | 2,628,028 | 1,151,065 | 9,688,616 | 1,855,016 | 3,282,205 | 910,365 |
| (i) everything new | 64 | 4,660,132 | 1,998,700 | 17,354,000 | 3,253,520 | 5,380,969 | 1,616,489 |
| (ii) lists exist, position new | 1 | 669,016 | 341,266 | 2,205,910 | 541,270 | 1,250,580 | 238,740 |
| (ii) lists exist, position new | 2 | 705,595 | 364,379 | 2,271,301 | 606,661 | 1,312,824 | 257,464 |
| (ii) lists exist, position new | 4 | 785,356 | 417,236 | 2,408,684 | 744,044 | 1,443,910 | 301,510 |
| (ii) lists exist, position new | 8 | 943,762 | 521,764 | 2,682,290 | 1,017,650 | 1,704,929 | 388,449 |
| (ii) lists exist, position new | 16 | 1,259,964 | 730,226 | 3,228,904 | 1,564,264 | 2,226,366 | 561,726 |
| (ii) lists exist, position new | 32 | 1,894,052 | 1,148,839 | 4,323,780 | 2,659,140 | 3,270,896 | 909,936 |
| (ii) lists exist, position new | 64 | 3,172,812 | 1,996,662 | 6,524,140 | 4,859,500 | 5,370,562 | 1,616,962 |
| (iii) position exists, my roll-ups new | 1 | 562,656 | 250,196 | 1,733,170 | 460,210 | 804,950 | 195,670 |
| (iii) position exists, my roll-ups new | 2 | 597,323 | 264,356 | 1,855,869 | 484,989 | 838,670 | 207,630 |
| (iii) position exists, my roll-ups new | 4 | 666,605 | 292,623 | 2,101,179 | 534,459 | 906,019 | 231,459 |
| (iii) position exists, my roll-ups new | 8 | 811,855 | 355,866 | 2,598,543 | 640,143 | 1,047,466 | 285,866 |
| (iii) position exists, my roll-ups new | 16 | 1,101,394 | 481,339 | 3,592,254 | 850,494 | 1,329,349 | 393,669 |
| (iii) position exists, my roll-ups new | 32 | 1,680,496 | 732,312 | 5,579,664 | 1,271,184 | 1,893,104 | 609,264 |
| (iii) position exists, my roll-ups new | 64 | 2,842,648 | 1,238,226 | 9,558,456 | 2,116,536 | 3,024,586 | 1,044,426 |
| (iv) everything exists | 1 | 553,180 | 230,704 | 1,650,174 | 475,134 | 694,965 | 194,485 |
| (iv) everything exists | 2 | 576,076 | 244,867 | 1,687,482 | 512,442 | 728,696 | 206,456 |
| (iv) everything exists | 4 | 621,816 | 273,140 | 1,762,010 | 586,970 | 796,078 | 230,318 |
| (iv) everything exists | 8 | 719,982 | 336,403 | 1,917,810 | 742,770 | 937,580 | 284,780 |
| (iv) everything exists | 16 | 915,353 | 461,896 | 2,228,393 | 1,053,353 | 1,219,573 | 392,693 |
| (iv) everything exists | 32 | 1,306,119 | 712,921 | 2,849,547 | 1,674,507 | 1,783,550 | 608,510 |
| (iv) everything exists | 64 | 2,091,599 | 1,218,927 | 4,095,827 | 2,920,787 | 2,915,483 | 1,044,123 |

### Number operations (`TagNumberMeasure.t.sol`: one registered 1-word topic, things the author has tagged)

| operation | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all |
|---|---:|---:|---:|---:|---:|
| a first tag, number 0 | 746,628 | 399,498 | 2,628,214 | 571,894 | 1,564,602 |
| a first tag, number 75 | 746,640 | 399,510 | 2,628,226 | 571,906 | 1,564,614 |
| a lone negative, −1 | 687,673 | 340,482 | 2,305,299 | 542,739 | 1,241,627 |
| a lone negative, −5 | 687,685 | 340,494 | 2,305,311 | 542,751 | 1,241,639 |
| change a positive (0 → 75) | 448,570 | 155,018 | 1,281,550 | 400,270 | 433,469 |
| change a negative (−1 → −5) | 426,776 | 129,476 | 1,171,736 | 388,376 | 319,905 |
| positive to negative (3 → −1) | 458,649 | 161,350 | 1,217,975 | 434,615 | 366,179 |
| negative to positive (−1 → 3) | 521,153 | 223,916 | 1,537,339 | 460,219 | 685,596 |
| to silent (−5 → none, RELEASE) | 425,843 | 128,511 | 1,170,803 | 387,443 | 318,940 |
| silent to negative (none → −5) | 409,703 | 112,406 | 1,073,943 | 388,503 | 222,126 |

A nonzero number costs 12 gas more than zero. A number change keeps the binding and its history; a BIND that keeps
its asserted target touches no backlink list (design §10.2).

### Tags in context (`TopicMeasure.t.sol`)

| what | prague | amsterdam, all | amsterdam, exec |
|---|---:|---:|---:|
| a first tag on a registered 2-word topic | 817,385 | 2,889,257 | 633,305 |
| the same, registering the path record in the same publication | 1,185,544 | 4,026,532 | 986,626 |
| the same, registering a new word page and its path record | 1,387,730 | 4,676,581 | 1,146,521 |
| a first tag on an address that never transacted | 749,037 | 2,497,884 | 633,591 |
| a first tag under a home | 737,296 | 2,618,884 | 558,744 |
| a label: a new `text/1` record and a PROPERTY bind | 935,435 | 3,286,233 | 735,955 |
| a label naming an existing text | 647,748 | 2,265,286 | 498,928 |
| `same` between two word pages | 652,679 | 2,255,905 | 489,543 |
| `broader` from a path to a word | 652,671 | 2,255,897 | 489,532 |

### Later authors

A later author's first statement on a position someone already stated is case (iii) (its own roll-ups new) or (iv)
(everything exists) of the tables above, and `bindTagSecondAuthor` below is its 1-word cost. A later author's first
yes files one more `place` entry and one `place-below` entry per proper ancestor; the spam rows below price it from a
fresh account.

## Registration (`TopicMeasure.t.sol`)

### Word pages, path records and text records

| record | prague alone | prague per extra (batch of 10) | amsterdam alone, all | amsterdam alone, exec | amsterdam per extra, all |
|---|---:|---:|---:|---:|---:|
| word page, 5B (ASCII) | 536,790 | 205,516 | 1,648,096 | 469,264 | 695,198 |
| word page, 12B (ASCII) | 520,663 | 208,358 | 1,551,183 | 470,241 | 707,012 |
| word page, 40B (ASCII) | 547,379 | 234,020 | 1,665,819 | 486,904 | 818,990 |
| word page, 255B (ASCII) | 748,089 | 398,533 | 2,555,655 | 593,101 | 1,494,675 |
| word page, 5B (multi-byte) | 537,845 | 206,558 | 1,649,151 | 470,319 | 696,239 |
| word page, 12B (multi-byte) | 524,823 | 212,528 | 1,555,344 | 474,401 | 711,182 |
| word page, 40B (multi-byte) | 560,917 | 247,568 | 1,679,357 | 500,451 | 832,538 |
| word page, 255B (multi-byte) | 836,629 | 486,695 | 2,644,196 | 681,756 | 1,582,837 |
| path record (`topic/1`) | 654,964 | 276,927 | 2,110,862 | 540,384 | 953,947 |
| path record already registered (a second registrant) | 547,070 | — | 1,636,789 | 457,904 | — |
| word page re-published | 491,213 | — | 1,426,480 | 443,437 | — |
| text record (`text/1`, 24 B) | 574,304 | — | 1,847,050 | 472,379 | — |

The word rule (`TopicProfile.wordRefusal`) costs ASCII 121 and multi-byte 478 gas per byte of `wordRefusal` (prague; amsterdam 121 / 478); it runs once per word, when its page is published.

### A new path of 2 to 64 words, with its transactions

Every record of the path registered in order (parents first), split into consecutive publications of at most 64
actions under the 2^24 cap (amsterdam: its execution gas), each a valid publication on its own.

| words | case | actions | prague, total | prague txs | amsterdam all, total | amsterdam exec, total | amsterdam txs (execution cap) |
|---|---|---:|---:|---:|---:|---:|---:|
| 2 | every word new | 3 | 1,075,851 | 1 | 3,521,769 | 872,983 | 1 |
| 2 | word pages exist | 1 | 655,002 | 1 | 2,110,912 | 540,384 | 1 |
| 4 | every word new | 7 | 2,027,582 | 1 | 6,783,201 | 1,586,094 | 1 |
| 4 | word pages exist | 3 | 1,183,233 | 1 | 3,885,613 | 943,000 | 1 |
| 8 | every word new | 15 | 4,074,174 | 1 | 14,088,059 | 3,010,575 | 1 |
| 8 | word pages exist | 7 | 2,410,923 | 1 | 8,354,755 | 1,786,534 | 1 |
| 16 | every word new | 31 | 8,078,831 | 1 | 27,962,829 | 5,906,265 | 1 |
| 16 | word pages exist | 15 | 4,775,486 | 1 | 16,717,359 | 3,484,766 | 1 |
| 32 | every word new | 63 | 16,319,684 | 1 | 56,252,670 | 11,846,330 | 1 |
| 32 | word pages exist | 31 | 9,585,722 | 1 | 33,744,484 | 6,889,718 | 1 |
| 64 | every word new | 127 | 33,489,665 | 3 | 113,804,370 | 24,194,550 | 2 |
| 64 | word pages exist | 63 | 19,564,020 | 2 | 67,704,266 | 13,890,572 | 1 |

## File work

| operation | prague | amsterdam, all | amsterdam, exec |
|---|---:|---:|---:|
| create file in a folder with files | 1,704,592 | 6,100,670 | 1,302,590 |
| create file in an empty home | 1,602,127 | 5,580,339 | 1,271,859 |
| create file in a home with files | 1,612,883 | 5,605,395 | 1,296,915 |
| edit | 860,531 | 2,771,259 | 714,939 |
| create file in a folder (first entry, a fresh place list) *(transaction-shaped suite)* | 1,433,327 | 5,170,299 | 1,052,172 |
| create file in a folder (later entry) *(transaction-shaped suite)* | 1,420,616 | 5,024,748 | 1,102,425 |
| create file at a home (first entry) *(transaction-shaped suite)* | 1,426,020 | 5,103,572 | 1,083,349 |
| create file at a home (later entry) *(transaction-shaped suite)* | 1,402,667 | 4,933,080 | 1,108,659 |

The first four rows are `TagListsFileMeasure.t.sol` (a create into a folder or a home that already holds files, an
empty home, an edit); a created file pays a `position-authors` entry (a new list) and, at a fresh position, a `place`
entry. The `TopicMeasure.t.sol` rows set up the place differently (a fresh folder or home of the author's own), so the
two suites' create rows are not comparable with each other. An edit is a HEAD re-bind and writes no list.

| recipe (`FilesRecipes.t.sol`, `gas/report.json`) | prague | amsterdam, all | amsterdam, exec |
|---|---:|---:|---:|
| Root seed (PUBLISH files-directory/1), first write of the principal | 669,300 | 2,434,166 | 475,766 |
| Native 1-leaf PUBLISH, steady | 573,824 | 1,853,671 | 482,791 |
| M1 create folder (PUBLISH dir, PUBLISH name, BIND FOLDER), native | 1,321,839 | 4,795,163 | 976,283 |
| M1 create file (5 leaves), native, no guard | 1,683,951 | 6,044,428 | 1,246,348 |
| Edit (PUBLISH child + BIND HEAD rebind) | 864,874 | 2,775,614 | 719,294 |
| Rename / move (PUBLISH name + RELEASE + BIND), native | 1,119,384 | 3,608,491 | 964,651 |
| Remove (RELEASE from BOUND; target word kept, no clear) | 451,410 | 1,210,736 | 427,376 |
| Restore (BIND to a released key, same target) | 485,955 | 1,259,816 | 476,456 |
| RELEASE from mask, native | 400,516 | 1,064,756 | 379,316 |
| Hide (UNBIND from BOUND: a mask, which stops the lens search) | 435,504 | 1,114,146 | 428,706 |
| Restore a released placement (BIND from RELEASED; §14 'Move-back' analog) | 500,862 | 1,355,397 | 474,117 |
| WITHDRAW, native | 444,440 | 1,284,087 | 402,807 |

## The per-level terms (`gas/model.json`, design §10.4)

| term | prague | amsterdam, all | amsterdam, execution |
|---|---:|---:|---:|
| `bindTagFresh`: a first tag on a fresh position of a 1-word topic | 414,171 | 1,646,117 | 275,237 |
| `bindTagSecondAuthor`: a later author's first tag on an existing position of a 1-word topic (files one `place` entry) | 312,771 | 1,119,017 | 237,737 |
| `bindTagNumberChange`: a number change on an asserted tag (a REBIND to the same target) | 153,736 | 432,162 | 138,402 |
| `tagLevel.mineNew`: one per-author roll-up entry on a new list | 34,627 | 122,659 | 24,739 |
| `tagLevel.mineExisting`: one per-author roll-up entry on an existing list | 22,871 | 37,268 | 37,268 |
| `tagLevel.sharedNew`: one shared roll-up entry on a new list (every filing) | 27,139 | 115,156 | 17,236 |
| `tagLevel.sharedExisting`: one shared roll-up entry on an existing list | 15,354 | 29,765 | 29,765 |

For an n-word topic: the fresh-position or later-author term, plus, per proper ancestor, mine new or existing and (at
every filing: a fresh position of either sign, or a later author's first yes) shared new or existing; a later
author's first no pays no shared term, and `bindTagSecondAuthor` (measured as a yes) is an upper bound for it. A list
holding exactly one entry or a multiple of five takes a fresh word on its next append: price that append as new
(`tagLists.priceAsNew`). On amsterdam an existing list costs more execution gas than a new one: a rewrite is 12,100
of execution gas under EIP-8038, while a new slot's 110,020 is mostly state gas.

## The largest publication per shape (`FloorPlan.t.sol`; `gas/model.json` `planning`)

The largest publication the planning rule plans of each shape, its measured execution gas E and the floor's
requirement V (both against the 16.58M–16.75M of visible execution gas a 2^24 transaction leaves); every one is
admitted, on prague also by running it with exactly that gas. "next" is one unit more: refused by the rule for gas
(on prague, run anyway, it was still admitted: the rule is conservative) or past the 64-action limit. P / spend is
the prefix floor over the callbacks' prefix spend (E − K − the final phase), F / final the final reserve over the
final phase. Below 1.0: first tags on deep topics (the floor does not know the depth; the gas model does) and the
final phase of folder re-binds and create-file recipes (the Files validator's cold reads; the final call receives
all remaining gas and V includes E, so neither is refused nor left unfinishable).

| shape | prague k | E | V | P / spend | F / final | next | amsterdam k | E (execution) | V | P / spend | F / final | next |
|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---|
| lone negatives, one-word topic | 38 | 13,161,332 | 14,330,407 | 1.13 | 1.39 | gas | 53 | 12,750,524 | 14,423,060 | 1.20 | 1.39 | gas |
| first tags, depth 8, everything new | 18 | 11,238,899 | 11,414,531 | 0.50 | 1.41 | gas | 19 | 8,432,953 | 8,616,103 | 0.52 | 1.41 | gas |
| first tags, depth 64, everything new | 3 | 10,445,638 | 10,508,508 | 0.07 | 1.27 | gas | 3 | 7,442,150 | 7,505,020 | 0.08 | 1.25 | gas |
| first tags, depth 8, everything existing | 22 | 11,373,339 | 11,579,041 | 0.55 | 1.42 | gas | 20 | 8,315,700 | 8,506,367 | 0.51 | 1.41 | gas |
| first tags, depth 64, everything existing | 4 | 8,219,424 | 8,289,812 | 0.12 | 1.29 | gas | 3 | 7,353,405 | 7,416,275 | 0.08 | 1.25 | gas |
| second author's first tags, depth 8 | 22 | 11,661,383 | 11,867,085 | 0.53 | 1.42 | gas | 20 | 8,319,882 | 8,510,549 | 0.51 | 1.41 | gas |
| masks of tags | 58 | 10,134,551 | 14,439,489 | 1.63 | 2.60 | gas | 55 | 10,072,975 | 14,354,427 | 1.59 | 2.60 | gas |
| releases of tags | 58 | 10,063,554 | 14,367,158 | 1.63 | 2.60 | gas | 55 | 10,005,768 | 14,285,955 | 1.59 | 2.60 | gas |
| restores of tags | 51 | 10,487,860 | 14,321,411 | 1.65 | 2.56 | gas | 51 | 10,766,554 | 14,417,872 | 1.51 | 2.56 | gas |
| number changes of tags | 62 | 10,166,426 | 14,330,667 | 2.00 | 2.56 | gas | 64 | 9,484,302 | 14,460,951 | 2.23 | 2.56 | limit |
| masks of masks | 58 | 8,278,655 | 14,299,801 | 2.31 | 2.60 | gas | 55 | 7,514,581 | 14,221,963 | 2.62 | 2.60 | gas |
| folder entries re-bound to another file | 62 | 13,793,877 | 14,527,729 | 1.13 | 0.56 | gas | 61 | 13,311,465 | 14,416,511 | 1.19 | 0.56 | gas |
| repeat publishes of existing name records | 64 | 12,684,712 | 13,555,737 | 1.11 | 1.16 | limit | 64 | 10,344,962 | 12,913,719 | 1.56 | 1.16 | limit |
| fresh name records | 61 | 13,337,345 | 13,630,347 | 1.05 | 1.17 | gas | 64 | 10,372,094 | 12,812,245 | 1.93 | 1.16 | limit |
| a name record and a first tag (2 actions each) | 21 | 13,423,619 | 13,771,458 | 1.02 | 1.32 | gas | 27 | 11,971,774 | 13,673,246 | 1.32 | 1.32 | gas |
| registration chunk (word pages) | 64 | 13,909,190 | 14,269,129 | 1.08 | 1.16 | limit | 64 | 10,337,078 | 12,776,137 | 1.93 | 1.16 | limit |
| create-file recipes (5 actions each) | 10 | 12,918,827 | 14,100,931 | 1.28 | 0.85 | gas | 12 | 10,875,001 | 13,019,593 | 1.59 | 0.85 | limit |

Measured with this release's code (work-model formula 3 and the list tiers, tools/RELEASE.md items 42 to 48) and the
regenerated `test/vectors/floor-plan.json` (`FloorPlan.t.sol -vv` on both profiles). Against `3ca53ba`: prague masks,
releases and masks of masks 64 → 58, restores 60 → 51, number changes 60 → 62, folder re-binds 60 → 62; amsterdam lone
negatives 50 → 53, masks, releases and masks of masks 44 → 55, restores 41 → 51, number changes 41 → 64, folder re-binds
40 → 61; every other `k` unchanged (tools/RELEASE.md item 43). The table below is the earlier step, kept for its
record. **Since the Glamsterdam rewrite price** (the floor's `floorRewriteGas` 12,100 on a Glamsterdam Realm, was
5,000; docs/GAS-SCHEDULES.md, tools/RELEASE.md item 39) the amsterdam columns moved; prague's did not (every prague `k`
and floor quote is as before; E and V moved by a few gas to a few thousand with this release's code). The planning
rule's floor quote V and largest batch on amsterdam, from `gas/model.json` `planning` and the floor-plan vectors at
`726993e` against `3ca53ba` (formula 2; V at the largest batch; the edits shape is the planner's only, `tools/gas-plan-later.mjs`):

| shape | k before | k after | V at the old k, before | V at the old k, after | V at the new k | P at the old k, before → after |
|---|---:|---:|---:|---:|---:|---:|
| lone negatives, one-word topic | 54 | 50 | 14,053,591 | 15,272,720 | 14,168,538 | 7,037,000 → 8,577,700 |
| first tags, depth 8, everything new | 19 | 19 | 13,754,312 | 13,754,796 | 13,754,796 | 2,543,800 → 3,090,500 |
| first tags, depth 64, everything new | 3 | 3 | 10,695,394 | 10,695,526 | 10,695,526 | 487,000 → 579,300 |
| first tags, depth 8, everything existing | 20 | 20 | 13,932,229 | 13,932,735 | 13,932,735 | 2,666,300 → 3,241,400 |
| first tags, depth 64, everything existing | 3 | 3 | 12,950,875 | 12,951,007 | 12,951,007 | 487,000 → 579,300 |
| second author's first tags, depth 8 | 20 | 20 | 13,844,526 | 13,845,032 | 13,845,032 | 2,666,300 → 3,241,400 |
| masks of tags | 64 | 44 | 12,704,934 | 20,215,297 | 14,012,473 | 7,903,300 → 15,180,800 |
| releases of tags | 64 | 44 | 12,627,430 | 20,137,793 | 13,959,189 | 7,903,300 → 15,180,800 |
| restores of tags | 64 | 41 | 14,077,990 | 21,588,353 | 13,961,664 | 7,903,300 → 15,180,800 |
| number changes of tags | 64 | 41 | 14,101,222 | 21,611,585 | 13,976,547 | 7,903,300 → 15,180,800 |
| masks of masks | 64 | 44 | 12,704,934 | 20,215,297 | 14,012,473 | 7,903,300 → 15,180,800 |
| folder entries re-bound to another file | 61 | 40 | 14,073,457 | 21,232,116 | 14,048,788 | 7,537,300 → 14,474,000 |
| repeat publishes of existing name records | 64 | 64 | 10,235,327 | 12,404,939 | 12,404,939 | 4,332,900 → 6,434,500 |
| fresh name records | 64 | 64 | 11,269,792 | 13,440,045 | 13,440,045 | 2,554,200 → 4,655,800 |
| a name record and a first tag (2 actions each) | 30 | 27 | 13,888,111 | 15,786,509 | 14,258,221 | 5,099,600 → 6,938,500 |
| registration chunk (word pages) | 64 | 64 | 11,355,002 | 12,469,331 | 12,469,331 | 2,554,200 → 4,655,800 |
| create-file recipes (5 actions each) | 12 | 12 | 11,786,032 | 13,310,756 | 13,310,756 | 4,205,000 → 5,681,800 |
| edits: PUBLISH child + HEAD re-bind (2 actions each; not a FloorPlan shape) | 30 | 23 | 13,860,905 | 18,396,731 | 14,194,617 | 5,992,100 → 10,387,000 |

The budget is 14,260,633 (2^24 less the 15% headroom). Prague, the same files: every `k` was unchanged by that step
(38, 18, 3, 22, 4, 22, 64, 64, 60, 60, 64, 60, 64, 61, 21, 64, 10; edits 24) and every P; V moved by +22 to +1,364 gas
with that step's re-fitted constants. 64 lone negatives do not fit one amsterdam publication: the floor's requirement for
64 is 17.40M under formula 3 (18.34M under formula 2) against the 16.60M a 2^24 transaction leaves (`IndexFloor.t.sol`),
so the rule plans 53 (50 under formula 2).

The model's estimates for deep tags run high (the composition prices every roll-up append from the per-level terms
with the price-as-new rule), so the rule under-fills those publications rather than over-fills them.

**The floor** (`IndexFloor.t.sol`, both profiles). 64 lone negatives on a one-word topic execute in 15.49M on
amsterdam; the kernel's own share K is 7.34M, the prefix floor 9.24M under formula 3 (formula 2: 10.15M, and 8.32M with
a rewrite priced at 5,000) and the final reserve 494k (1.39× the final phase's 356k); the floor's requirement V = max(K +
P·(64/63)² + 2k, E) + F·64/63 + 20k is 17.40M (formula 2: 18.34M), over the 16.60M a 2^24 transaction leaves after
intrinsic gas and calldata (it was 16.45M, within it, at the 5,000 price), so the planning rule splits them (53 a
publication). On prague their execution gas alone is over the cap. The final phase's worst cases, 64 actions each (amsterdam execution gas,
reserve 494k): first masks about 64 created subjects 994k, about 64 records 738k, first tags on 64 distinct topics
471k, lone negatives about addresses 355k: the per-bind reserve (`finalComputePerBind` 7,400) is set from the topics
row, and a per-bind term large enough for the subjects row would put 64 lone negatives over the cap (design §10.4).

## The deepest path: a single first statement in one transaction (2^24)

| statement, case | prague: deepest | tx gas at it | per level | amsterdam all gas: deepest | tx gas at it | per level | amsterdam execution only: deepest | tx execution gas at it | per level |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tag, (i) everything new | 254 | 16,627,433 | 63,183 | 60 | 16,659,829 | 239,223 | 366 | 16,765,464 | 43,383 |
| tag, (ii) lists exist, position new | 395 | 16,740,803 | 39,641 | 208 | 16,735,086 | 68,441 | 239 | 16,759,736 | 68,441 |
| tag, (iii) position exists, my roll-ups new | 238 | 16,732,260 | 68,127 | 59 | 16,716,371 | 251,267 | 286 | 16,732,335 | 55,427 |
| tag, (iv) everything exists | 401 | 16,744,687 | 39,283 | 217 | 16,758,096 | 68,084 | 240 | 16,727,785 | 68,083 |
| lone negative, (i) everything new | 254 | 16,567,628 | 63,181 | 61 | 16,572,999 | 239,221 | 366 | 16,735,173 | 43,381 |
| lone negative, (iv) everything exists | 627 | 16,774,942 | 24,428 | 386 | 16,763,973 | 38,828 | 416 | 16,759,610 | 38,827 |

### How many first tags fit one publication (2^24, at most 64 actions)

| depth | shape | prague | amsterdam, all gas | amsterdam, execution only |
|---|---|---:|---:|---:|
| 64 | best: everything exists (case iv) | 8 | 2 | 8 |
| 64 | worst on one topic: a new path, every tag on its deepest topic | 5 | 0 | 8 |
| 64 | worst: every tag on its own new path | 3 | 0 | 5 |
| 8 | best: everything exists (case iv) | 35 | 11 | 41 |
| 8 | worst on one topic: a new path, every tag on its deepest topic | 27 | 6 | 38 |
| 8 | worst: every tag on its own new path | 18 | 4 | 27 |

Found by bisection over k in 1..64, every k measured from the same prepared state; "every tag on its own new path"
was measured over 8 paths at depth 64 and 64 paths at depth 8. A 64-word first tag on an all-new path does not fit
alone under the all-gas reading on amsterdam (17.68M), so those rows' capacity is 0.

**Opening a topic's shared list at registration** *(computed, not built)*: if registering a topic also wrote that
topic's `place-below` head, a first tag would pay only the author's own new lists. "opened" = case (i) alone minus
(n − 1) × (`sharedNew` − `sharedExisting`): at n = 64 on amsterdam all gas 17.68M → about 12.30M (under 2^24), on
prague 4.72M → about 3.98M, and amsterdam execution gas 3.28M → about 4.07M (an append to an existing list is more
execution gas than a new head). Price: one list head per registered topic, about 27k on prague and 115k all gas
(17k execution) on amsterdam.

## Spam rows: what one list entry costs a spammer

| entry | prague alone (tx) | prague per entry, 64 in one publication (tx) | amsterdam alone, all (tx) | amsterdam per entry of 64, all (tx) | amsterdam per entry of 64, execution (tx) |
|---|---:|---:|---:|---:|---:|
| a `place` entry: a lone negative at a fresh position of a 1-word topic (an address-shaped role) | 676,391 | 350,376 | 2,206,073 | 1,273,785 | 244,095 |
| a `place-below` entry of an ancestor: a lone negative at a fresh position of its child topic | 724,753 | 373,208 | 2,356,855 | 1,333,974 | 262,974 |
| one more `place` entry for an EXISTING position: a fresh account's first yes there (per entry of 64: one fresh account, 64 existing positions) | 683,442 | 336,040 | 2,220,248 | 1,190,842 | 256,012 |
| the same on a 2-word topic: one `place` entry and one `place-below` entry of the ancestor | 714,375 | 341,445 | 2,272,881 | 1,152,884 | 274,664 |
| a `position-authors` entry: a fresh account's first publication, one lone negative at an existing position | 605,512 | — | 1,856,834 | — | — |
| the same by an account that has written before | 588,436 | — | 1,758,938 | — | — |

One more `place` entry for a position that already exists needs an author who never stated anything there, so a
fresh account each time, and one account files at most once per position: this is the price of a sybil bump in a
newest-first public view (QUESTIONS Q54). The place's `live` (distinct positions) does not move, and readers remove
the duplicate rows by position.

### A mask, a release and a restore

One cooled publication of one statement by an author who has written before, on a position with another author (TAG:
a 2-word topic; FOLDER: the author's home, a real name). A transition away from or back to BOUND pays one more
posting-store call (family 20's `release` or `retain`: a warm call and one slot rewrite of the position's list head).

| purpose | transition | prague (tx) | amsterdam, all (tx) | amsterdam, execution (tx) |
|---|---|---:|---:|---:|
| TAG | mask asserted | 471,988 | 1,231,266 | 447,906 |
| TAG | release asserted | 453,753 | 1,132,345 | 446,905 |
| TAG | restore from masked | 486,002 | 1,259,838 | 476,478 |
| TAG | restore from released | 486,002 | 1,259,838 | 476,478 |
| TAG | mask of masked | 423,029 | 1,087,221 | 401,781 |
| TAG | release of masked | 422,108 | 1,086,300 | 400,860 |
| FOLDER | mask asserted | 471,181 | 1,230,483 | 447,123 |
| FOLDER | release asserted | 452,946 | 1,131,562 | 446,122 |
| FOLDER | restore from masked | 515,995 | 1,370,541 | 489,261 |
| FOLDER | restore from released | 498,922 | 1,272,782 | 489,422 |
| FOLDER | mask of masked | 422,212 | 1,086,428 | 400,988 |
| FOLDER | release of masked | 421,291 | 1,085,507 | 400,067 |

## Later statements across places and in long lists (`GasModel.t.sol` sections 8 and 9; `gas/model.json` `laterLists`)

The model's single-place rows price a later statement at ONE topic or folder whose author's list is short. Two
ordinary states cost more: statements at distinct places rewrite one scope head each, and from the author's entry 48
at a place the changed entry's live bit is in a bits word of its own, found by a bisection of the author's list there
(about 3.7k gas per doubling of the list, on both schedules, within a place and across places when the entries are
spread). A restore also appends to its target's backlink list, which takes a fresh word when the list holds one entry
(the ordinary case of a file in one folder or a thing tagged once by the author), so the restore rows are measured in
that state. The list tiers price them (tools/RELEASE.md "The list tiers"): a known count of at most 48 is the short tier,
anything longer or unknown the rows measured at entry 1,024 of a 1,025-entry list; re-binds never search the list and
have no tier. The rows, per later statement (k2 − k1 of its own pair; prague / amsterdam execution gas):

| row | short, one place (the row) | short, new place | long, new place | long, same place |
|---|---:|---:|---:|---:|
| `unbindTag` | 156,523 / 165,523 | 160,929 / 177,107 | 201,300 / 224,700 | 196,451 / 212,617 |
| `releaseTag` | 155,337 / 164,337 | 159,743 / 175,921 | 200,114 / 223,514 | 195,265 / 211,431 |
| `restoreTag` | 187,314 / 193,604 | 191,708 / 205,186 | 249,180 / 252,780 | 227,232 / 240,698 |
| `unbindFolder` | 160,228 / 169,194 | 160,849 / 177,015 | 201,208 / 224,608 | 196,359 / 212,525 |
| `releaseFolder` | 157,209 / 166,175 | 159,663 / 175,829 | 200,022 / 223,422 | 195,173 / 211,339 |
| `restoreFolder` | 208,066 / 214,332 | 200,330 / 213,784 | 257,778 / 261,378 | 237,830 / 251,296 |
| `unbindProperty` | 146,405 / 155,405 | — | 181,964 / 190,918 | 181,916 / 190,882 |
| `releaseProperty` | 145,219 / 154,219 | — | 180,778 / 189,732 | 180,730 / 189,696 |
| `unbindSame` | 146,618 / 155,594 | — | 182,165 / 191,119 | 182,117 / 191,083 |
| `releaseSame` | 145,420 / 154,420 | — | 180,979 / 189,933 | 180,931 / 189,897 |
| `restoreSame` | 175,254 / 181,530 | — | 223,940 / 213,228 | 210,764 / 217,030 |
| `unbindBroader` | 146,629 / 155,629 | — | 182,188 / 191,142 | 182,128 / 191,094 |
| `releaseBroader` | 145,443 / 154,431 | — | 181,002 / 189,956 | 180,942 / 189,908 |
| `restoreBroader` | 175,277 / 181,553 | — | 223,951 / 213,239 | 210,763 / 217,029 |
| `bindTagNumberChange` | 154,415 / 139,105 | 159,179 / 151,057 | — | — |
| `bindFolderRebind` | 207,174 / 196,386 | 209,998 / 206,386 | — | — |

The composites (whole cooled publications, predicted with the tiers from the measured state; `beyondClaim` is reported
and excluded from the stated maxima; error = predicted − measured, so a negative figure is an under-prediction).
From the regenerated `gas/model.json` of this release:

| composite | state | prague | amsterdam all | amsterdam execution |
|---|---|---:|---:|---:|
| tag masks across topics | acrossPlaces | -0.92% | -0.12% | -0.56% |
| tag releases across topics | acrossPlaces | -0.92% | -0.12% | -0.56% |
| tag restores across topics | acrossPlaces | -0.82% | -0.11% | -0.53% |
| tag number changes across topics | acrossPlaces | -0.98% | -0.12% | -0.70% |
| tag masks at entry 47 across topics | acrossPlaces | -9.64% | -4.09% | -8.67% |
| tag releases at entry 47 across topics | acrossPlaces | -9.69% | -4.10% | -8.71% |
| tag restores at entry 47 across topics | acrossPlaces | -8.32% | -3.16% | -7.65% |
| tag masks at entry 48 across topics | acrossPlacesBitsWord | 8.77% | 4.22% | 8.13% |
| tag releases at entry 48 across topics | acrossPlacesBitsWord | 8.84% | 4.23% | 8.19% |
| tag restores at entry 48 across topics | acrossPlacesBitsWord | 7.00% | 2.76% | 7.17% |
| tag masks at entry 1024 across topics | longLists | 0.32% | 0.63% | 0.75% |
| tag releases at entry 1024 across topics | longLists | 0.32% | 0.63% | 0.76% |
| tag restores at entry 1024 across topics | longLists | 0.25% | 0.42% | 0.66% |
| tag masks at entry 4096 across topics | beyondClaim | -2.84% | -0.47% | -1.81% |
| tag releases at entry 4096 across topics | beyondClaim | -2.85% | -0.47% | -1.82% |
| tag restores at entry 4096 across topics | beyondClaim | -2.39% | -0.33% | -1.64% |
| tag masks of 32 entries of 1025 at one topic | longLists | 10.93% | 6.72% | 13.80% |
| tag releases of 32 entries of 1025 at one topic | longLists | 11.01% | 6.74% | 13.90% |
| tag restores of 32 entries of 1025 at one topic | longLists | 9.31% | 5.09% | 12.03% |
| tag number changes of 32 entries of 1025 at one topic | longLists | -0.98% | -0.11% | -0.73% |
| folder masks across folders | acrossPlaces | -0.91% | -0.12% | -0.56% |
| folder releases across folders | acrossPlaces | -0.90% | -0.11% | -0.55% |
| folder re-binds across folders | acrossPlaces | 2.69% | 8.86% | 0.65% |
| folder restores across folders | acrossPlaces | -2.87% | 0.46% | -3.17% |
| folder masks at entry 48 across folders | acrossPlacesBitsWord | 8.78% | 4.22% | 8.14% |
| folder releases at entry 48 across folders | acrossPlacesBitsWord | 8.85% | 4.24% | 8.20% |
| folder restores at entry 48 across folders | acrossPlacesBitsWord | 7.29% | 4.11% | 6.77% |
| folder masks at entry 1024 across folders | longLists | 0.32% | 0.63% | 0.76% |
| folder releases at entry 1024 across folders | longLists | 0.33% | 0.63% | 0.76% |
| folder restores at entry 1024 across folders | longLists | -0.01% | 0.32% | 0.39% |
| folder masks of 8 entries of 1025 in one folder | longLists | 10.68% | 6.09% | 12.43% |
| folder releases of 8 entries of 1025 in one folder | longLists | 10.74% | 6.10% | 12.49% |
| folder re-binds of 8 entries of 1025 in one folder | longLists | 1.35% | 2.49% | 1.08% |
| folder restores of 8 entries of 1025 in one folder | longLists | 8.28% | 4.45% | 10.00% |
| property masks of 8 entries of 1025 at one topic | longLists | 11.16% | 6.05% | 13.01% |
| same masks of 8 entries of 1025 at one topic | longLists | 11.15% | 6.05% | 13.00% |
| broader masks of 8 entries of 1025 at one topic | longLists | 11.14% | 6.04% | 12.99% |
| untag a file from six topics | acrossPlaces | 2.09% | 3.23% | 6.29% |
| delete six files from three folders | acrossPlaces | 1.23% | 1.68% | 2.56% |

What the short tier would under-predict if a planner passed a stale, low count for a long list (a publication at entry
1,024): tag restores across 16 topics −21.20% on prague, −17.02% amsterdam execution (−20.44% all gas); tag masks
−18.03% / −18.99%; folder releases across 16 folders −18.12% / −19.09%; and at entry 48, up to −16.75% / −13.95%. So a
count older than what the planner trusts is treated as unknown.

## Reads (`TopicReadMeasure.t.sol`, `gas/model.json` `reads`)

Every figure is one cold `view` call: every account the call can touch is cooled first (`vm.cool`), and the figure
is the call frame's gas (`vm.lastCallGas().gasTotalUsed`; no intrinsic, no calldata). Setups run with gas metering
paused. Reads are not repriced on amsterdam: every row is within 0.1% of prague (about +4k, the cold accounts), and
the per-row terms are the same. `page` is `limit`, the list entries read; in these setups every entry read is a row,
except the padded stretch. `pnpm run gas:model` writes the rows and `pnpm run gas:model:check` compares them exactly.

```sh
FOUNDRY_GAS_LIMIT=100000000000 perl -e 'alarm 5400; exec @ARGV' \
  forge test --match-path test/integration/TopicReadMeasure.t.sol -vv | grep ' tr '
FOUNDRY_GAS_LIMIT=100000000000 FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam \
  perl -e 'alarm 9000; exec @ARGV' forge test --match-path test/integration/TopicReadMeasure.t.sol -vv | grep ' tr '
```

**`mine`, exact plus below.** 50 things filed by the lens round-robin (thing i by lens author i mod L), at depth 1
(the place itself) or under the deepest topic of an 8- or 64-word path, read from its first word. Depth 8 and 64
cost the same to the gas: a read never walks a path. Nobody stated anything at the place, so the viewed-place check
reads no head (`mineBelowQuiet`).

| lens | depth | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---|---:|---:|---:|---:|---:|
| 1 | 1 | 576,269 | 580,469 | 2,362,014 | 2,366,814 |
| 1 | 8 | 563,194 | 567,394 | 2,427,134 | 2,431,934 |
| 1 | 64 | 563,194 | 567,394 | 2,427,134 | 2,431,934 |
| 8 | 1 | 1,043,236 | 1,047,436 | 3,574,302 | 3,579,102 |
| 8 | 8 | 1,099,766 | 1,103,966 | 3,670,736 | 3,675,536 |
| 8 | 64 | 1,099,766 | 1,103,966 | 3,670,736 | 3,675,536 |
| 32 | 1 | 2,501,122 | 2,505,322 | 7,527,892 | 7,532,692 |
| 32 | 8 | 2,307,423 | 2,311,623 | 7,576,021 | 7,580,821 |
| 32 | 64 | 2,307,423 | 2,311,623 | 7,576,021 | 7,580,821 |
| 64 | 1 | 5,277,237 | 5,281,437 | 12,238,349 | 12,243,149 |
| 64 | 8 | 4,797,151 | 4,801,351 | 11,876,200 | 11,881,000 |
| 64 | 64 | 4,797,151 | 4,801,351 | 11,876,200 | 11,881,000 |

**`mine`, the worst case of the viewed-place check** (`mine worst`, the bounds): before the filings the last lens
author says yes to every thing at the place itself and every lens author says "not this" about one other thing
there, so every row reads the head states of lens[0..j] at the viewed place (and, from j + 1 = 4, the author-list
head first).

| lens | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---|---:|---:|---:|---:|
| 1 | 686,699 | 690,899 | 2,929,274 | 2,934,074 |
| 8 | 1,569,170 | 1,573,370 | 5,865,692 | 5,870,492 |
| 32 | 3,825,206 | 3,829,406 | 13,799,753 | 13,804,553 |
| 64 | 8,821,390 | 8,825,590 | 23,180,254 | 23,185,054 |

**`everyone` and `raw`.** 60 things filed by one author at a one-word place's child; the exact view reads the child,
the below view the parent. The lens is 8 authors none of whom said anything, so every lens head is read where the
entry was filed; in the worst case the same things are filed at both places, so every viewed position holds a
statement and all 8 lens authors are asked there.

| view | page 10, prague | page 10, amsterdam | page 50, prague | page 50, amsterdam |
|---|---:|---:|---:|---:|
| everyone, exact, lens of 8 | 1,088,601 | 1,092,601 | 5,205,963 | 5,211,163 |
| everyone, below, lens of 8 | 1,315,134 | 1,319,134 | 6,177,276 | 6,182,476 |
| everyone, below, lens of 8, worst | 1,808,276 | 1,812,276 | 8,692,141 | 8,697,341 |
| raw, exact | 538,317 | 542,117 | 2,447,872 | 2,452,272 |
| raw, below | 619,151 | 622,951 | 2,671,538 | 2,675,938 |

**A padded stretch**: 60 lone negatives by one stranger at a place's child, so no entry is a row; a lens of L silent
authors. Gas per SKIPPED entry (the page-60 minus page-20 difference over 40 entries):

| lens | exact (prague / amsterdam) | below (prague / amsterdam) |
|---|---:|---:|
| 1 | 35,970 / 35,980 | 36,135 / 36,145 |
| 8 | 35,971 / 35,981 | 36,137 / 36,147 |
| 64 | 35,981 / 35,991 | 36,146 / 36,156 |

A skipped entry costs its cell and one author-list head whatever the lens. `test/readers/TopicLensOrder.t.sol`
asserts it: at a lens of 64 a skipped entry costs at most 1,000 gas more than at a lens of 1, and at most 45,000 in
all.

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
within 0.5% of the same page at 3 authors, and `placeCount` and `byName` in a place of 2,000 positions cost the same
to the gas as in a place of 3. A place padded with lone negatives around one real tag is read in pages of 4 entries,
each page `LIMIT` with a continuation, until the tag (`test/readers/TopicEveryone.t.sol`).

**Per row** *(fitted; `reads.schedules.<schedule>.terms`)*: `mine`, exact rows: an opening of about 192k + 28.4k per
lens author, then per row about 36k + 6.6k·(j + 1), j the row's deciding lens index. `mine`, roll-up rows, on the
worst case (`mineBelow`): an opening of about 339k + 20.7k per lens author, then per row about 39k + 15.4k·(j + 1);
where nothing is stated at the place (`mineBelowQuiet`) about 37k + 6.7k·(j + 1). `everyone`, exact: about 61k to
open, 48k per shown row without a lens and 6.9k more per lens author; below: about 106k to open, 51k per shown row
and, in the worst case, 15.1k more per lens author (8.8k when the viewed positions are empty); every skipped entry
about 36k at any lens. `byName` about 23k per row after about 140k; `about` about 32k per row after about 153k; `wordPage` and
`children` about 47k per place after about 118k–143k. A lookup page that leaves entries unread reads one entry more
for its `frontier` (about 4.2k at `byName` page 10, the entry in a word of its own; `about` and `children` alike).

**The published bounds** *(computed; `reads.schedules.<schedule>.bounds` and `recommended`)*: at a 10M cap less a 10%
margin, the most worst-case rows one call holds, by lens size (prague):

| lens | `mine` exact | `mine` below | `everyone` exact | `everyone` below |
|---|---:|---:|---:|---:|
| 1 | 208 | 159 | 163 | 133 |
| 8 | 96 | 52 | 86 | 51 |
| 16 | 59 | 29 | 56 | 30 |
| 32 | 31 | 15 | 33 | 16 |
| 64 | 15 | 7 | 18 | 8 |

Amsterdam differs only in: lens 1 mineExact {"maxRows": 207}. **Keep page × lens at or below 768 for `mine` exact, 416 for `mine`
below, 688 for `everyone` exact and 408 for `everyone` below** (`pageTimesLens`, the smallest over lenses 8 to 64),
`maxRows` at most 150, and `limit` (entries) at most 245 on both schedules (`limitEntries`; it was 246 on prague
before `TopicPageInfo.frontier`, which added 16 gas per skipped entry). A page that
mixes rows and skipped entries stays under the cap while opening + rows·row(L) + skipped·36k ≤ 9M; a page cut by a
bound is a `LIMIT`, `ROWS` or `GAS` page with a continuation, never an empty or `UNKNOWN` one.
