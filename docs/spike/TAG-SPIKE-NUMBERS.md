# Tag spike: final numbers (integrated build)

All figures were measured at commit `a47f2e955e9d25a0ef6f83dfde818ecfdbca6ce4` on branch `spike/2026-11-25-tags`, from one integrated build: the real
`topic-word/1` and `topic/1` Types, `FilesFinalValidator` (first tag needs its topic admitted strictly before it; address
targets for TAG only) and the index with every topic list on (`trustRegistered` on, role-places for TAG and FOLDER)
unless a row names another build. Spike evidence only; never merged as is. The next commit, `49ed9fd`, is `forge fmt`
only (no bytecode change).

Every figure is **measured** unless marked *(estimate)*. Gas is the measured execution frame of `execute` with every
contract cooled first (each row pays what a transaction of its own pays), native lane, unless a table says otherwise.
On amsterdam, "all" = execution (regular) gas + EIP-8037 state gas, "exec" = regular gas only, "state share" =
state / all. Reads are cold `view` calls (gas inside the test frame). Raw logs and parsed JSON:
`/private/tmp/claude-501/-Users-james-Code-EFS/edf3f386-5f8f-47d6-922a-e6bebb37b3ce/scratchpad/final/` (`prague.log`,
`amsterdam.log`, `prague.json`, `amsterdam.json`; local evidence, not committed).

Commands (Foundry 1.8.3, solc 0.8.37 via-IR, Node 24.21.0):

```sh
M='TagNumberMeasure|TopicMeasure|OpenScopeMeasure|TagPathMeasure|TopicListsIntegrated|GlamsterdamFloor'
perl -e 'alarm 7000; exec @ARGV' forge test --match-contract "$M" -vv > prague.log
FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam FOUNDRY_GAS_LIMIT=100000000000 \
  perl -e 'alarm 7000; exec @ARGV' forge test --match-contract "$M" -vv > amsterdam.log
```

`FOUNDRY_GAS_LIMIT` is raised to 10^11 for the amsterdam run (as in round two): Foundry's amsterdam profile draws state
gas from the call's own gas (no reservoir, see Part 2), so the deep-fit and chain-building setups exceed the 2^30 default.

Builds (`OpenScopeMeasure` contracts): `off` = no topic list (families 6, 7, 19, 20, 21 unmaintained); `mine` = family 19
only; `all` = families 6, 20, 7 (no 19, no 21); `full` = every list incl. role-places for TAG and FOLDER (the integrated
default); `full-no-rp` = full minus family 21; `full-rp-tag` = full with family 21 for TAG only.

## A. A tag by an author on an n-word topic

Cases: (i) everything fresh (the author's exact and roll-up lists, the position, the all-authors lists); (ii) the
author's lists and the all-authors lists exist (6 entries), the position is new; (iii) the position exists (another
author's), this author's below-lists are fresh; (iv) everything exists, the position has two authors already. "per
extra" = (k10 - k1) / 9, ten statements in one publication.

### A1. Assert (number 0), integrated build `full`

| case | n | prague alone | amsterdam alone (all) | amsterdam alone (exec) | state share | prague per extra (k10) | amsterdam per extra (all) | state share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (i) everything fresh | 1 | 789,463 | 2,920,743 | 570,663 | 80% | 400,755 | 1,583,794 | 83% |
|  | 2 | 849,572 | 3,156,892 | 610,972 | 81% | 423,902 | 1,646,042 | 83% |
|  | 4 | 969,411 | 3,628,811 | 691,211 | 81% | 469,814 | 1,770,157 | 82% |
|  | 8 | 1,221,206 | 4,584,766 | 863,806 | 81% | 573,769 | 2,030,511 | 80% |
|  | 16 | 1,724,361 | 6,496,241 | 1,208,561 | 81% | 781,253 | 2,550,784 | 77% |
|  | 32 | 2,732,774 | 10,321,294 | 1,900,174 | 82% | 1,198,334 | 3,593,434 | 74% |
|  | 64 | 4,761,835 | 17,983,635 | 3,295,635 | 82% | 2,044,739 | 5,690,968 | 71% |
| (ii) author lists exist, position new | 1 | 725,175 | 2,526,041 | 567,641 | 78% | 398,337 | 1,571,614 | 83% |
|  | 2 | 761,770 | 2,591,470 | 633,070 | 76% | 421,499 | 1,633,896 | 83% |
|  | 4 | 834,649 | 2,721,949 | 763,549 | 72% | 467,441 | 1,758,082 | 82% |
|  | 8 | 992,524 | 2,995,024 | 1,036,624 | 65% | 571,438 | 2,018,567 | 80% |
|  | 16 | 1,307,839 | 3,540,739 | 1,582,339 | 55% | 779,016 | 2,539,104 | 77% |
|  | 32 | 1,940,572 | 4,634,272 | 2,675,872 | 42% | 1,196,275 | 3,582,291 | 74% |
|  | 64 | 3,218,273 | 6,833,573 | 4,875,173 | 29% | 2,043,038 | 5,680,898 | 71% |
| (iii) position exists, author below-lists fresh | 1 | 640,826 | 2,163,232 | 498,592 | 77% | 312,194 | 1,138,012 | 79% |
|  | 2 | 675,296 | 2,285,722 | 523,162 | 77% | 326,185 | 1,171,548 | 79% |
|  | 4 | 742,404 | 2,528,904 | 570,504 | 77% | 352,366 | 1,236,826 | 78% |
|  | 8 | 876,731 | 3,015,311 | 665,231 | 78% | 404,769 | 1,367,432 | 77% |
|  | 16 | 1,157,635 | 4,000,375 | 866,935 | 78% | 521,830 | 1,640,892 | 75% |
|  | 32 | 1,719,491 | 5,970,551 | 1,270,391 | 79% | 756,014 | 2,187,866 | 72% |
|  | 64 | 2,847,240 | 9,914,940 | 2,081,340 | 79% | 1,228,431 | 3,285,851 | 69% |
| (iv) everything exists | 1 | 597,237 | 1,884,583 | 513,703 | 73% | 275,676 | 930,281 | 75% |
|  | 2 | 619,967 | 1,921,713 | 550,833 | 71% | 289,673 | 963,834 | 75% |
|  | 4 | 663,629 | 1,994,175 | 623,295 | 69% | 315,868 | 1,029,149 | 74% |
|  | 8 | 750,962 | 2,139,142 | 768,262 | 64% | 368,298 | 1,159,819 | 73% |
|  | 16 | 937,946 | 2,441,326 | 1,070,446 | 56% | 485,400 | 1,433,413 | 71% |
|  | 32 | 1,311,962 | 3,045,742 | 1,674,862 | 45% | 719,679 | 1,980,652 | 69% |
|  | 64 | 2,064,031 | 4,258,611 | 2,887,731 | 32% | 1,192,274 | 3,079,170 | 67% |

### A2. Lone negative (number -1), integrated build `full`

| case | n | prague alone | amsterdam alone (all) | amsterdam alone (exec) | state share | prague per extra (k10) | amsterdam per extra (all) | state share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (i) everything fresh | 1 | 720,984 | 2,588,304 | 531,984 | 79% | 332,230 | 1,251,305 | 82% |
|  | 2 | 781,091 | 2,824,439 | 572,279 | 80% | 355,372 | 1,313,540 | 81% |
|  | 4 | 900,927 | 3,296,367 | 652,527 | 80% | 401,284 | 1,437,667 | 80% |
|  | 8 | 1,152,713 | 4,252,313 | 825,113 | 81% | 505,227 | 1,698,009 | 78% |
|  | 16 | 1,655,848 | 6,163,768 | 1,169,848 | 81% | 712,690 | 2,218,262 | 76% |
|  | 32 | 2,664,224 | 9,988,772 | 1,861,412 | 81% | 1,129,734 | 3,260,862 | 73% |
|  | 64 | 4,693,209 | 17,651,037 | 3,256,797 | 82% | 1,976,063 | 5,358,320 | 70% |
| (ii) author lists exist, position new | 1 | 656,696 | 2,193,602 | 528,962 | 76% | 329,813 | 1,239,131 | 82% |
|  | 2 | 693,323 | 2,259,017 | 594,377 | 74% | 352,970 | 1,301,399 | 81% |
|  | 4 | 766,165 | 2,389,505 | 724,865 | 70% | 398,909 | 1,425,590 | 80% |
|  | 8 | 924,031 | 2,662,571 | 997,931 | 63% | 502,897 | 1,686,069 | 78% |
|  | 16 | 1,239,326 | 3,208,266 | 1,543,626 | 52% | 710,455 | 2,206,587 | 75% |
|  | 32 | 1,872,022 | 4,301,750 | 2,637,110 | 39% | 1,127,676 | 3,249,721 | 73% |
|  | 64 | 3,149,647 | 6,500,975 | 4,836,335 | 26% | 1,974,364 | 5,348,252 | 70% |
| (iii) position exists, author below-lists fresh | 1 | 567,039 | 1,818,385 | 447,505 | 75% | 238,358 | 793,116 | 77% |
|  | 2 | 601,508 | 1,940,862 | 472,062 | 76% | 252,348 | 826,642 | 76% |
|  | 4 | 668,614 | 2,184,054 | 519,414 | 76% | 278,530 | 891,930 | 76% |
|  | 8 | 802,937 | 2,670,457 | 614,137 | 77% | 330,926 | 1,022,529 | 74% |
|  | 16 | 1,083,828 | 3,655,508 | 815,828 | 78% | 447,974 | 1,295,976 | 72% |
|  | 32 | 1,645,660 | 5,625,648 | 1,219,248 | 78% | 682,134 | 1,842,914 | 70% |
|  | 64 | 2,773,362 | 9,569,990 | 2,030,150 | 79% | 1,154,504 | 2,940,852 | 67% |
| (iv) everything exists | 1 | 540,499 | 1,637,505 | 462,465 | 72% | 218,890 | 683,155 | 73% |
|  | 2 | 563,228 | 1,674,622 | 499,582 | 70% | 232,886 | 716,695 | 73% |
|  | 4 | 606,888 | 1,747,094 | 572,054 | 67% | 259,079 | 782,021 | 72% |
|  | 8 | 694,217 | 1,892,057 | 717,017 | 62% | 311,505 | 912,690 | 72% |
|  | 16 | 881,188 | 2,194,228 | 1,019,188 | 54% | 428,595 | 1,186,267 | 70% |
|  | 32 | 1,255,180 | 2,798,608 | 1,623,568 | 42% | 662,849 | 1,733,470 | 68% |
|  | 64 | 2,007,202 | 4,011,430 | 2,836,390 | 29% | 1,135,397 | 2,831,941 | 66% |

### A3. Assert, lists-off baseline (`off`)

| case | n | prague alone | amsterdam alone (all) | amsterdam alone (exec) | state share | prague per extra (k10) | amsterdam per extra (all) | state share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (i) everything fresh | 1 | 703,999 | 2,571,173 | 514,853 | 80% | 333,736 | 1,321,193 | 83% |
|  | 2 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
|  | 4 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
|  | 8 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
|  | 16 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
|  | 32 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
|  | 64 | 703,971 | 2,571,145 | 514,825 | 80% | 333,708 | 1,321,165 | 83% |
| (ii) author lists exist, position new | 1 | 651,417 | 2,261,831 | 499,271 | 78% | 331,314 | 1,308,997 | 83% |
|  | 2 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
|  | 4 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
|  | 8 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
|  | 16 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
|  | 32 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
|  | 64 | 651,389 | 2,261,803 | 499,243 | 78% | 331,286 | 1,308,969 | 83% |
| (iii) position exists, author below-lists fresh | 1 | 601,385 | 2,028,659 | 461,939 | 77% | 274,753 | 1,005,454 | 80% |
|  | 2 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
|  | 4 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
|  | 8 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
|  | 16 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
|  | 32 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
|  | 64 | 601,357 | 2,028,631 | 461,911 | 77% | 274,725 | 1,005,426 | 80% |
| (iv) everything exists | 1 | 574,845 | 1,847,779 | 476,899 | 74% | 255,283 | 895,489 | 78% |
|  | 2 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |
|  | 4 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |
|  | 8 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |
|  | 16 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |
|  | 32 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |
|  | 64 | 574,817 | 1,847,751 | 476,871 | 74% | 255,255 | 895,461 | 78% |

### A4. Lone negative, lists-off baseline (`off`)

| case | n | prague alone | amsterdam alone (all) | amsterdam alone (exec) | state share | prague per extra (k10) | amsterdam per extra (all) | state share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (i) everything fresh | 1 | 635,522 | 2,238,736 | 476,176 | 79% | 265,209 | 988,711 | 81% |
|  | 2 | 635,494 | 2,238,696 | 476,136 | 79% | 265,181 | 988,671 | 81% |
|  | 4 | 635,494 | 2,238,708 | 476,148 | 79% | 265,181 | 988,683 | 81% |
|  | 8 | 635,494 | 2,238,708 | 476,148 | 79% | 265,181 | 988,683 | 81% |
|  | 16 | 635,494 | 2,238,708 | 476,148 | 79% | 265,181 | 988,683 | 81% |
|  | 32 | 635,494 | 2,238,696 | 476,136 | 79% | 265,181 | 988,671 | 81% |
|  | 64 | 635,494 | 2,238,696 | 476,136 | 79% | 265,181 | 988,671 | 81% |
| (ii) author lists exist, position new | 1 | 582,940 | 1,929,394 | 460,594 | 76% | 262,791 | 976,516 | 81% |
|  | 2 | 582,912 | 1,929,354 | 460,554 | 76% | 262,763 | 976,476 | 81% |
|  | 4 | 582,912 | 1,929,366 | 460,566 | 76% | 262,763 | 976,488 | 81% |
|  | 8 | 582,912 | 1,929,366 | 460,566 | 76% | 262,763 | 976,488 | 81% |
|  | 16 | 582,912 | 1,929,366 | 460,566 | 76% | 262,763 | 976,488 | 81% |
|  | 32 | 582,912 | 1,929,354 | 460,554 | 76% | 262,763 | 976,476 | 81% |
|  | 64 | 582,912 | 1,929,354 | 460,554 | 76% | 262,763 | 976,476 | 81% |
| (iii) position exists, author below-lists fresh | 1 | 527,599 | 1,683,813 | 410,853 | 76% | 200,918 | 660,563 | 77% |
|  | 2 | 527,571 | 1,683,773 | 410,813 | 76% | 200,890 | 660,523 | 77% |
|  | 4 | 527,571 | 1,683,785 | 410,825 | 76% | 200,890 | 660,535 | 77% |
|  | 8 | 527,571 | 1,683,785 | 410,825 | 76% | 200,890 | 660,535 | 77% |
|  | 16 | 527,571 | 1,683,785 | 410,825 | 76% | 200,890 | 660,535 | 77% |
|  | 32 | 527,571 | 1,683,773 | 410,813 | 76% | 200,890 | 660,523 | 77% |
|  | 64 | 527,571 | 1,683,773 | 410,813 | 76% | 200,890 | 660,523 | 77% |
| (iv) everything exists | 1 | 518,108 | 1,600,702 | 425,662 | 73% | 198,499 | 648,364 | 77% |
|  | 2 | 518,080 | 1,600,662 | 425,622 | 73% | 198,471 | 648,324 | 77% |
|  | 4 | 518,080 | 1,600,674 | 425,634 | 73% | 198,471 | 648,336 | 77% |
|  | 8 | 518,080 | 1,600,674 | 425,634 | 73% | 198,471 | 648,336 | 77% |
|  | 16 | 518,080 | 1,600,674 | 425,634 | 73% | 198,471 | 648,336 | 77% |
|  | 32 | 518,080 | 1,600,662 | 425,622 | 73% | 198,471 | 648,324 | 77% |
|  | 64 | 518,080 | 1,600,662 | 425,622 | 73% | 198,471 | 648,324 | 77% |

### A5. The cost of the lists (`full` minus `off`, alone, all gas)

| statement, case | n | prague | amsterdam (all) |
| --- | ---: | ---: | ---: |
| assert (i) | 1 | 85,464 | 349,570 |
| assert (i) | 4 | 265,440 | 1,057,666 |
| assert (i) | 8 | 517,235 | 2,013,621 |
| assert (i) | 64 | 4,057,864 | 15,412,490 |
| assert (ii) | 1 | 73,758 | 264,210 |
| assert (ii) | 4 | 183,260 | 460,146 |
| assert (ii) | 8 | 341,135 | 733,221 |
| assert (ii) | 64 | 2,566,884 | 4,571,770 |
| assert (iii) | 1 | 39,441 | 134,573 |
| assert (iii) | 4 | 141,047 | 500,273 |
| assert (iii) | 8 | 275,374 | 986,680 |
| assert (iii) | 64 | 2,245,883 | 7,886,309 |
| assert (iv) | 1 | 22,392 | 36,804 |
| assert (iv) | 4 | 88,812 | 146,424 |
| assert (iv) | 8 | 176,145 | 291,391 |
| assert (iv) | 64 | 1,489,214 | 2,410,860 |
| lone negative (i) | 1 | 85,462 | 349,568 |
| lone negative (i) | 4 | 265,433 | 1,057,659 |
| lone negative (i) | 8 | 517,219 | 2,013,605 |
| lone negative (i) | 64 | 4,057,715 | 15,412,341 |
| lone negative (ii) | 1 | 73,756 | 264,208 |
| lone negative (ii) | 4 | 183,253 | 460,139 |
| lone negative (ii) | 8 | 341,119 | 733,205 |
| lone negative (ii) | 64 | 2,566,735 | 4,571,621 |
| lone negative (iii) | 1 | 39,440 | 134,572 |
| lone negative (iii) | 4 | 141,043 | 500,269 |
| lone negative (iii) | 8 | 275,366 | 986,672 |
| lone negative (iii) | 64 | 2,245,791 | 7,886,217 |
| lone negative (iv) | 1 | 22,391 | 36,803 |
| lone negative (iv) | 4 | 88,808 | 146,420 |
| lone negative (iv) | 8 | 176,137 | 291,383 |
| lone negative (iv) | 64 | 1,489,122 | 2,410,768 |

### A6. Per-level cost (slope between n = 32 and n = 64, alone, all gas, minus the `off` slope)

Per extra topic level, for the per-author roll-up alone (`mine`, family 19) and the all-authors lists alone (`all`,
families 6/20/7; only family 7 grows with depth), and for `full`.

| statement, case | prague mine | prague all | prague full | amsterdam mine | amsterdam all | amsterdam full |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| assert (i) everything fresh | 35,240 | 35,198 | 63,408 | 123,260 | 123,218 | 239,448 |
| assert (ii) author lists exist, position new | 23,500 | 23,458 | 39,928 | 37,900 | 37,858 | 68,728 |
| assert (iii) position exists, author below-lists fresh | 35,240 | 0 | 35,242 | 123,260 | 0 | 123,262 |
| assert (iv) everything exists | 23,500 | 0 | 23,502 | 37,900 | 0 | 37,902 |
| lone negative (i) everything fresh | 35,239 | 35,196 | 63,406 | 123,259 | 123,216 | 239,446 |
| lone negative (ii) author lists exist, position new | 23,499 | 23,456 | 39,926 | 37,899 | 37,856 | 68,726 |
| lone negative (iii) position exists, author below-lists fresh | 35,239 | 0 | 35,241 | 123,259 | 0 | 123,261 |
| lone negative (iv) everything exists | 23,499 | 0 | 23,501 | 37,899 | 0 | 37,901 |

### A7. The quoted worst case: one first assert on a fully fresh 64-word topic, case (i)

| reading | gas |
| --- | ---: |
| prague (all gas = execution gas) | 4,761,835 |
| amsterdam, all gas (execution + state) | 17,983,635 |
| amsterdam, execution gas only | 3,295,635 |
| amsterdam, state gas | 14,688,000 (82% of all) |
| amsterdam, transaction estimate (all + 21,000 + calldata) *(estimate)* | 18,009,811 |

## B. Number operations on an existing tag (`TagNumberMeasure`, one-word topic, later members)

Gas here is the caller's `gasleft()` delta around `execute` (a few thousand above the frame figures elsewhere); on
amsterdam that delta includes state gas (Foundry draws it from the call), so "exec" = delta - state.

| operation | prague k1 | amsterdam k1 (all) | amsterdam k1 (exec) | state share | prague per extra | amsterdam per extra (all) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| change a positive (0 -> 75, REBIND) | 485,253 | 1,413,319 | 434,119 | 69% | 192,640 | 566,197 |
| change a negative (-1 -> -5, MASK again) | 423,408 | 1,168,334 | 384,974 | 67% | 127,004 | 317,433 |
| positive to negative (3 -> -1, MASK) | 441,018 | 1,193,144 | 409,784 | 66% | 144,614 | 342,239 |
| negative to positive (-1 -> 3, RESTORE) | 503,330 | 1,512,316 | 435,196 | 71% | 206,971 | 661,448 |
| to silent (-5 -> released) | 422,465 | 1,167,391 | 384,031 | 67% | 126,029 | 316,458 |
| silent to negative (released -> -5) | 406,359 | 1,070,599 | 385,159 | 64% | 109,958 | 219,678 |
| reference: first assert (number 0) | 743,810 | 2,625,396 | 569,076 | 78% | 397,543 | 1,562,652 |
| reference: first lone negative (-1) | 675,331 | 2,292,957 | 530,397 | 77% | 329,024 | 1,230,172 |

## C. Registration

### C1. One record (`TopicMeasure`, later records of the Type)

| record | prague k1 | amsterdam k1 (all) | amsterdam k1 (exec) | state share | prague per extra | amsterdam per extra (all, caller delta) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| word page 5 B | 510,158 | 1,540,678 | 463,558 | 70% | 202,095 | 699,964 |
| word page 12 B | 528,201 | 1,639,507 | 464,467 | 72% | 201,669 | 691,358 |
| word page 40 B | 537,506 | 1,655,946 | 480,906 | 71% | 228,971 | 813,956 |
| word page 255 B | 736,382 | 2,543,948 | 585,548 | 77% | 391,915 | 1,488,076 |
| path record `[parent, wordPage]` | 644,513 | 2,100,411 | 533,691 | 75% | 271,272 | 948,296 |
| path record, second registrant (record exists) | 537,355 | 1,627,073 | 452,033 | 72% |  |  |
| word page re-published (exists) | 481,254 | 1,416,520 | 437,320 | 69% |  |  |

### C2. A brand-new path of n words (`TopicMeasure`: pages first, then records; chunks of at most 64 actions that fit
2^24 by frame gas, which on amsterdam is execution gas only)

| n | words | prague total | prague txs | amsterdam total (all) | amsterdam total (exec) | state share | amsterdam txs (exec <= 2^24) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | all words new | 1,054,685 | 1 | 3,500,615 | 856,775 | 76% | 1 |
| 2 | all words exist | 644,525 | 1 | 2,100,411 | 533,691 | 75% | 1 |
| 4 | all words new | 1,973,582 | 1 | 6,714,740 | 1,524,980 | 77% | 1 |
| 4 | all words exist | 1,160,288 | 1 | 3,862,632 | 925,032 | 76% | 1 |
| 8 | all words new | 3,982,474 | 1 | 13,996,306 | 2,931,346 | 79% | 1 |
| 8 | all words exist | 2,362,684 | 1 | 8,306,430 | 1,745,790 | 79% | 1 |
| 16 | all words new | 7,889,592 | 1 | 27,773,494 | 5,741,494 | 79% | 1 |
| 16 | all words exist | 4,675,669 | 1 | 16,617,513 | 3,398,313 | 80% | 1 |
| 32 | all words new | 15,935,403 | 1 | 55,875,303 | 11,517,543 | 79% | 1 |
| 32 | all words exist | 9,381,991 | 1 | 33,540,345 | 6,710,265 | 80% | 1 |
| 64 | all words new | 32,695,250 | 3 | 113,018,507 | 23,519,627 | 79% | 2 |
| 64 | all words exist | 19,138,196 | 2 | 67,278,685 | 13,520,605 | 80% | 1 |

### C3. The same, all words new, integrated lists on (`OpenScopeMeasure full`: interleaved page/record, transaction
estimates incl. 21,000 + calldata *(estimate)*; chunked by all gas, and on amsterdam also by execution gas only)

| n | prague total | prague txs | amsterdam total (all), chunked by all gas | txs | amsterdam total (all), chunked by exec gas | txs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 1,053,027 | 1 | 3,337,469 | 1 | 3,337,469 | 1 |
| 8 | 4,018,022 | 1 | 13,870,194 | 1 | 13,870,194 | 1 |
| 16 | 8,009,428 | 1 | 28,838,555 | 2 | 27,893,150 | 1 |
| 32 | 16,116,409 | 1 | 58,556,341 | 4 | 55,887,167 | 1 |
| 64 | 32,580,679 | 2 | 118,364,397 | 8 | 113,009,573 | 2 |

## D. Composite writes

| publication | prague | amsterdam (all) | amsterdam (exec) | state share |
| --- | ---: | ---: | ---: | ---: |
| first tag on a registered 2-word topic (later member) | 810,774 | 2,882,634 | 630,474 | 78% |
| first tag + one new leaf (page + record, registrations first) in one publication | 1,362,662 | 4,651,594 | 1,126,474 | 76% |
| first tag + one new leaf (record only, page exists) | 1,182,928 | 4,104,734 | 971,294 | 76% |
| first tag on an ADDRESS target (never transacted) | 742,442 | 2,491,288 | 630,808 | 75% |
| first tag under a home (address-shaped subject) | 730,642 | 2,612,228 | 555,908 | 79% |
| file attached to a home (5 actions) (caller delta) | 1,731,223 | 6,303,341 | 1,309,421 | 79% |
| file attached to a directory (5 actions) (caller delta) | 1,737,328 | 6,309,446 | 1,315,526 | 79% |

### D2. Create-file and edit with the lists on, by build (`OpenScopeMeasure`)

| publication | prague off | prague full-no-rp | prague full-rp-tag | prague full | amsterdam off | amsterdam full-no-rp | amsterdam full-rp-tag | amsterdam full |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| create file k1 (first file of the Realm's root FOLDER lists) | 1,671,777 | 1,724,723 | 1,724,775 | 1,750,350 | 6,186,695 | 6,415,681 | 6,415,733 | 6,529,328 |
| create file k1 (second) | 1,626,560 | 1,684,803 | 1,684,855 | 1,710,430 | 5,839,486 | 6,080,869 | 6,080,933 | 6,194,528 |
| create file k10 | 12,239,098 | 12,608,426 | 12,608,946 | 12,864,696 | 45,085,310 | 46,525,200 | 46,525,720 | 47,661,534 |
| edit (publish child + HEAD rebind) | 845,957 | 845,957 | 845,957 | 845,945 | 2,756,685 | 2,756,697 | 2,756,697 | 2,756,697 |

### D3. What family 21 (role-places) adds

First statements on a fresh position of an existing one-word topic (the place list and the author's scope list exist).
"adds" = `full` - `full-no-rp`. For FOLDER the role is the name hash, so the list is "every place this name is used":
see the create-file rows (`full` - `full-rp-tag`).

| row | prague full | prague adds | amsterdam full (all) | amsterdam adds (all) | amsterdam adds (exec) |
| --- | ---: | ---: | ---: | ---: | ---: |
| first tag, thing never tagged (fresh role-places list) | 706,075 | 25,628 | 2,426,121 | 113,648 | 15,728 |
| first tag, thing already tagged elsewhere (existing list, 2nd entry) | 722,002 | 30,937 | 2,463,348 | 126,069 | 28,149 |
| lone negative, thing never tagged | 637,596 | 25,628 | 2,093,682 | 113,648 | 15,728 |
| ten first tags, things never tagged (k10) | 4,308,185 | 256,246 | 16,668,547 | 1,136,446 | 157,246 |
| create file k1 (FOLDER position) [full - full-rp-tag] | 1,750,350 | 25,575 | 6,529,328 | 113,595 | 15,675 |
| create file k1 (second) [full - full-rp-tag] | 1,710,430 | 25,575 | 6,194,528 | 113,595 | 15,675 |
| create file k10 [full - full-rp-tag] | 12,864,696 | 255,750 | 47,661,534 | 1,135,814 | 156,614 |

## E. Reads (cold `view` calls, integrated build)

Topic T at depth d with one child C; author 0 tags 60 things on T and 60 on C; authors 1..63 each tag one thing on T
and one on C after author 0; author 1 also denies one thing on T. `mine` reads exact + below (families 10 + 19).

| read | prague d=1 | prague d=8 | prague d=64 | amsterdam d=8 | rows |
| --- | ---: | ---: | ---: | ---: | ---: |
| mine, lens 1, page 10 | 283,299 | 283,494 | 285,040 | 285,894 | 10 |
| mine, lens 1, page 50 | 1,354,701 | 1,355,653 | 1,362,981 | 1,358,053 | 50 |
| mine, lens 8, page 10 | 633,220 | 633,468 | 635,387 | 635,868 | 10 |
| mine, lens 8, page 50 | 1,926,082 | 1,927,083 | 1,934,782 | 1,929,483 | 50 |
| mine, lens 32, page 10 | 2,084,392 | 2,084,805 | 2,087,985 | 2,087,205 | 10 |
| mine, lens 32, page 50 | 6,489,331 | 6,490,495 | 6,499,458 | 6,492,895 | 50 |
| mine, lens 64, page 10 | 4,104,545 | 4,105,176 | 4,110,038 | 4,107,576 | 10 |
| mine, lens 64, page 50 | 15,103,070 | 15,104,453 | 15,115,097 | 15,106,853 | 50 |
| everyone exact, lens 8, page 10 | 656,207 | 656,502 | 658,776 | 658,502 | 10 |
| everyone exact, lens 8, page 50 | 3,487,667 | 3,489,123 | 3,500,332 | 3,491,123 | 50 |
| everyone exact raw, page 10 | 322,368 | 322,663 | 324,936 | 324,663 | 10 |
| everyone exact raw, page 50 | 1,436,981 | 1,438,437 | 1,449,647 | 1,440,437 | 50 |
| everyone below (family 7), lens 8, page 10 | 657,651 | 657,946 | 660,220 | 659,946 | 10 |
| everyone below raw, page 50 | 1,440,636 | 1,442,092 | 1,453,301 | 1,444,092 | 50 |
| count places (one family-6 head) | 28,978 | 28,984 | 29,021 | 30,984 | 60 |
| count authors (one family-20 head) | 31,530 | 31,544 | 31,646 | 33,544 | 3 |

### E2. byName and lookups

| read | prague | amsterdam |
| --- | ---: | ---: |
| byName, TAG position with 3 authors, page 3 | 87,737 | 89,737 |
| byName, TAG position with 300 authors, page 3 | 90,306 | 92,306 |
| byName, TAG position with 300 authors, page 10 | 200,633 | 202,633 |
| byName, FOLDER `pet.jpg` at a home, 3 authors, page 3 | 88,440 | 90,440 |
| byName, FOLDER `pet.jpg` at a home, 300 authors, page 3 (targeted spam) | 88,446 | 90,446 |
| byName, FOLDER at a home, 300 authors, page 10 | 201,027 | 203,027 |
| one name in a place of 3 positions | 71,459 | 73,459 |
| one name in a place of 2,001 positions | 73,462 | 75,590 |
| word page rendered from family 11, k = 1 places (directory + one count per place) | 61,263 | 64,863 |
| word page rendered from family 11, k = 5 places (directory + one count per place) | 176,757 | 188,357 |
| word page rendered from family 11, k = 20 places (directory + one count per place) | 610,054 | 651,654 |

## F. Deepest path whose single first statement fits one transaction (2^24)

Measured by bisection over a one-word-repeated chain (`OpenScopeMeasure._fit`); the criterion is the transaction
estimate (frame + 21,000 + calldata) <= 2^24. "exec only" on amsterdam counts execution gas against the cap (EIP-8037:
the cap is execution gas; state gas comes from the reservoir) and is the figure for a real Glamsterdam chain; Foundry has
no reservoir, so it is measured as the execution reading of an uncapped call *(estimate of the chain behaviour)*.
">= n" means the bisection's upper probe already fit. Per-level slope between depths 17 and 33 in brackets.

| build | statement, case | prague | amsterdam all gas | amsterdam exec only |
| --- | ---: | ---: | ---: | ---: |
| full | assert (i) everything fresh | 254 [63,037/level] | >= 59 [239,077/level] | 364 [43,237/level] |
| full | assert (ii) author lists exist, position new | 393 [39,557/level] | 208 [68,357/level] | >= 239 [68,357/level] |
| full | assert (iii) position exists, author below-lists fresh | 454 [35,119/level] | >= 120 [123,141/level] | 610 [25,221/level] |
| full | assert (iv) everything exists | 651 [23,381/level] | 390 [37,781/level] | 426 [37,782/level] |
| full | lone negative (i) everything fresh | 254 [63,034/level] | 60 [239,074/level] | 365 [43,236/level] |
| full | lone negative (ii) author lists exist, position new | 395 [39,554/level] | 213 [68,354/level] | >= 239 [68,354/level] |
| full | lone negative (iii) position exists, author below-lists fresh | 457 [35,119/level] | 122 [123,138/level] | 612 [25,219/level] |
| full | lone negative (iv) everything exists | 654 [23,378/level] | 397 [37,778/level] | 428 [37,778/level] |
| mine | assert (i) everything fresh | 452 [35,118/level] | 116 [123,138/level] | 609 [25,218/level] |
| mine | assert (ii) author lists exist, position new | 649 [23,378/level] | 380 [37,778/level] | 427 [37,778/level] |
| mine | assert (iii) position exists, author below-lists fresh | 455 [35,117/level] | >= 121 [123,138/level] | 611 [25,218/level] |
| mine | assert (iv) everything exists | 652 [23,378/level] | 391 [37,778/level] | 427 [37,780/level] |
| mine | lone negative (i) everything fresh | 454 [35,117/level] | >= 119 [123,137/level] | 610 [25,218/level] |
| mine | lone negative (ii) author lists exist, position new | 652 [23,377/level] | 389 [37,777/level] | 428 [37,777/level] |
| mine | lone negative (iii) position exists, author below-lists fresh | 457 [35,117/level] | 123 [123,135/level] | 613 [25,217/level] |
| mine | lone negative (iv) everything exists | 654 [23,375/level] | 398 [37,775/level] | 429 [37,775/level] |
| all | assert (i) everything fresh | 452 [35,084/level] | 114 [123,104/level] | 610 [25,184/level] |
| all | assert (ii) author lists exist, position new | 650 [23,344/level] | 375 [37,744/level] | 427 [37,744/level] |
| all | assert (iii) position exists, author below-lists fresh | any (depth-independent) [0/level] | any (depth-independent) [0/level] | any (depth-independent) [0/level] |
| all | assert (iv) everything exists | any (depth-independent) [0/level] | any (depth-independent) [0/level] | any (depth-independent) [1/level] |
| all | lone negative (i) everything fresh | 454 [35,082/level] | 117 [123,102/level] | 612 [25,184/level] |
| all | lone negative (ii) author lists exist, position new | 653 [23,342/level] | 384 [37,742/level] | 428 [37,742/level] |
| all | lone negative (iii) position exists, author below-lists fresh | any (depth-independent) [0/level] | any (depth-independent) [0/level] | any (depth-independent) [0/level] |
| all | lone negative (iv) everything exists | any (depth-independent) [0/level] | any (depth-independent) [0/level] | any (depth-independent) [0/level] |

## G. The kernel's availability floor on the two schedules (`GlamsterdamFloor.t.sol`)

How it is computed (no change to `src/core`):

- `src/core/LedgerIngress.sol` `_foldAndQuote`: `prefixFloor = compute + ceil(fresh10/10) * limits.floorFreshGas +
  ceil(rw10/10) * limits.floorRewriteGas`, with slot counts and compute from the index's `WorkModel`
  (`IIndexReads.workModel()`): per publication, per fresh publish, per ref, per digest spec, per fresh bind
  (`freshPerBindFresh`), per bind, per hook effect; `finalReserve = finalComputeBase + finalComputePerBind * binds`.
  Nothing in it depends on the topic's depth.
- `dispatchIndex` (same file): before every index callback, `gasleft() * 63/64 >= remainingPrefixFloor`, else
  `E_INDEX_GAS(remaining, available)`; `LedgerCore._notifyIndex` first takes `finalReserve + kernelTail` off the
  forwarded gas, and `remainingPrefixFloor` falls by what each callback spent. `_final` needs `finalReserve` after
  `kernelTail`. Every check reads the GAS opcode.
- Values (measured on the harness, `test/harness/KernelDeploy.sol` `s1Limits`, identical in `tools/deploy-plan.mjs`
  and `release/release.json` — there is no separate amsterdam limits fixture): `floorFreshGas = 22,100`,
  `floorRewriteGas = 5,000`, `kernelTail = 20,000`; work model (`IndexDoubleDefaults.workModel`): fresh/bind-fresh
  3, rewrites/bind 4, fresh/publish-fresh 1, rewrites/publish 5, fresh/ref 1, compute 60,000 + 25,000/action +
  60,000/hook effect, final 60,000 + 120,000/bind.

What Foundry's amsterdam profile emulates (measured, probe `test_probe_state_gas_dimension`):

- There is **no reservoir and no 2^24 execution cap**: with `FOUNDRY_GAS_LIMIT = 10^11` the test frame's `gasleft()`
  is 99,999,984,718. State gas is taken from the call's own gas: 100 fresh slots cost 11,007,636 by the GAS opcode
  inside the writer, of which `vm.lastFrameGas().gasTotalUsed` reports 1,231,177 (regular only) and `gasStateUsed`
  9,792,000 (97,920 per slot); a call given 4,000,000 gas runs out of gas (on prague it succeeds, 2,215,636).
- So in this repo's suites `gasTotalUsed` (logged as `frame gas` / `exec`) is execution gas only, `gasStateUsed` is
  logged separately (`frame state gas` / `state`), and every `before - gasleft()` figure (logged as `gas` in
  `TopicMeasure`, `TagNumberMeasure`) already includes state gas. A capped call in Foundry therefore cannot show the
  chain behaviour of "2^24 visible + reservoir"; the execution readings below stand in for it *(estimate)*.

Large fresh publications (`indexFloor` quote; "needs" = `prefixFloor * 64/63 + finalReserve + kernelTail`, the visible
gas the first callback check needs; "exec"/"state" measured uncapped):

| publication | prefixFloor | finalReserve | needs | prague exec | amsterdam exec | amsterdam state | admitted with a 2^24 call (Foundry) | on a Glamsterdam chain (2^24 exec + reservoir) *(estimate)* |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| first tag on a fully fresh 64-word path (+ CREATE of the thing) | 283,400 | 180,000 | 487,898 | 4,858,211 | 3,362,223 | 14,981,760 | prague yes; amsterdam no (out of gas: state drawn from the call) | admitted: the floor is tiny, exec 3.4M |
| 64 fresh word pages (one 64-action registration chunk) | 4,701,500 | 60,000 | 4,856,126 | 13,616,590 | 10,058,512 | 35,740,800 | prague yes; amsterdam no (floor check mid-publication after state gas ate the visible gas) | admitted: exec 10.1M, floor 4.9M |
| 32 first tags on a 64-word path | 5,568,700 | 3,900,000 | 9,577,092 | 68,535,711 | 54,187,377 | 141,886,080 | no (cannot pay) | not payable (exec 54M) |
| 64 lone negatives on a 1-word topic | 11,050,300 | 7,740,000 | 18,985,701 | 22,227,757 | 15,371,727 | 66,291,840 | no: `E_INDEX_GAS(11,050,300, ...)` at the first callback (the floor) | **refused by the floor though payable** (exec 15.4M < 2^24) |

Findings:

- The floor never refuses a deep first tag: it is depth-independent (283,400 for a single bind) and under-quotes the
  real cost (3.4M exec on amsterdam, 4.9M on prague); a callback that runs out reverts the publication with
  `E_INDEX_GAS` (no silent miss), so the depth limit is the real cost (Table F), not the floor.
- It does refuse a large, payable bind publication on amsterdam: 64 first statements quote 18,985,701 of visible gas,
  more than 2^24 can ever show, while their execution gas is 15,371,727 and their 66M of state gas would come from the
  reservoir. On prague the same publication cannot pay anyway (22.2M), so this is an amsterdam-only refusal. The
  test asserts both halves (`needs > 2^24`; on amsterdam `exec < 2^24`).
- Which value fixes it: of the `limits` values, `floorFreshGas` must stay a REGULAR-gas price on amsterdam (the GAS
  opcode never sees the reservoir): quoting the all-in 110,020 would make it far worse (193 fresh slots alone = 21.2M).
  Lowering `floorFreshGas` to 0 (state gas fully from the reservoir) gives `needs` = 14.65M *(estimate)* and admits it,
  but under-quotes the ~12,100 regular part of a fresh slot. With honest regular prices (fresh 12,100, rewrite 5,000)
  `needs` = 17.0M *(estimate)*: still refused. The dominant terms are the work model's, not `limits`:
  `finalComputePerBind` (120,000 per bind = 7.74M reserved) and `computePerHookEffect` (60,000 per bind). Lowering
  `finalComputePerBind` to the validator's measured per-bind cost, or the floor counting only the prefix still to run,
  is the fix; `limits.floorFreshGas` alone cannot be set to a safe value that admits it.

## H. What the integrated tests prove (all green at the measured commit)

- `TopicListsIntegrated.test_every_admitted_first_tag_has_every_rollup_entry`: on the real Types with the validator
  and `trustRegistered` on, for n = 1, 2, 3, 8, 64 and three authors (asserts, lone negatives, a second author on an
  existing position, and a fresh 5-word path registered and tagged in ONE publication), every admitted first statement
  ends each proper ancestor's per-author list, and each all-authors list exactly when its position was fresh.
- `test_rebuild_equals_live_integrated`: a replayed generation over the integrated Files Realm equals the live one on
  every list of families 6, 7, 10, 11, 19, 20, 21 plus backlink and history, over registrations at several depths,
  several authors, a second author on a position, lone negatives, number changes, mask/restore/release,
  remove-and-add-back, a home subject, an address target, a batch with its registration first, a FOLDER position with
  three authors and a file at a home.
- `test_every_statement_is_reachable_from_its_thing`: for a file subject, a directory record, a topic record, a
  revision record and an address with no history, alice's lone negative and bob's/carol's statements are listed by
  `about(thing)` (family 21) and each position's `byName` (family 20) lists every author with its number; the thing's
  backlink list shows only the assert (the gap family 21 closes).
- `test_role_places_remove_and_add_back_appends_nothing`; `test_targeted_spam_byName_on_a_home_folder` (300 authors'
  `pet.jpg` at one home: page 1 of 3 costs 88,446 vs 88,440 with 3 authors).
- `TopicTagsTest.test_registered_later_in_the_same_publication_is_refused` (code 7, also for a lone negative and a
  path record placed after the tag), `FilesFinalValidatorTest.test_topic_registered_at_or_after_the_tag_is_refused`,
  `test_address_target_is_for_tags_only` and `AddressTargetsTest.test_head_to_an_address_is_refused_tag_is_admitted`
  (code 8).

Observed while reading the tables: on amsterdam a rewrite of an existing slot costs more EXECUTION gas than a fresh
slot (the fresh slot's cost is mostly state gas), so cases (ii) and (iv) have higher "exec" than case (i) at depth, and
the exec-only depth limit of case (ii) (>= 239) is below case (i) (364). Family 21's "thing already tagged elsewhere"
row costs more than the fresh one because the posting store keeps a one-entry list inline in its head and the second
entry materializes the first word.

FOLDER verdict on family 21: for a FOLDER position the role is the name hash, so the list answers "every directory
where some author used this name". The file itself is already reachable from its target (backlink) and the name's
directory entry from the directory's place list; no reader in this spike or in the Files views needs "places by name". It looks like pure cost
for FOLDER (+25,575 prague, +113,595 amsterdam per new name position, 1.5% / 1.7% of a create): restrict it to TAG
(`rolePlaces = 1`, the `full-rp-tag` columns).

## I. Sizes and gates at the measured build (prague, `forge build --sizes`)

| contract over 17,500 B | runtime (B) | initcode (B) |
| --- | ---: | ---: |
| RealmIndex | 21,955 | 34,997 |
| LedgerIngress | 19,034 | 19,206 |
| EfsWeb3Gateway | 18,006 | 19,078 |

`FOUNDRY_PROFILE=ci forge test`: 1,096 tests in 88 suites, 1,095 pass; the one failure is the size budget
(`Budgets.t.sol`: RealmIndex runtime 21,955 and initcode+args 38,697 over its budget; budgets not edited).
