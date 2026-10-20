// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStub} from "../harness/doubles/LedgerStub.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FamilyId, PostingKey, ScopeKey} from "../../src/interfaces/Actions.sol";
import {Phase} from "../../src/interfaces/Results.sol";
import {E_BACKFILL, E_COVERAGE, E_FAMILY, E_ORDER, E_WRITER} from "../../src/interfaces/Errors.sol";

/// @notice The per-Realm stores under the writer rule of design §4.6/§10 (adoption item 7): who may write
///         when, the strictly increasing order law, the inline-singleton and five-per-word posting layout,
///         scope lists with their live bits in the head word, and the coverage slots' backfill modes.
contract StoresTest is Test {
    LedgerStub internal ledger;
    PostingStore internal posting;
    BitmapStore internal bitmap;
    address internal constant GEN = address(0xA11CE);
    address internal constant BUILDER = address(0xB0B);

    bytes32 internal BY_TYPE = Keys.familyId("by-type");
    bytes32 internal HISTORY = Keys.familyId("history");
    bytes32 internal SCOPE = Keys.familyId("scope");
    bytes32 internal ROSTER = Keys.familyId("roster");
    bytes32 internal LIVE = Keys.familyId("live-scope");
    PostingKey internal KEY = PostingKey.wrap(keccak256("list"));
    ScopeKey internal S = ScopeKey.wrap(keccak256("scope"));

    function setUp() public {
        ledger = new LedgerStub();
        bytes32[] memory pf = new bytes32[](2);
        pf[0] = BY_TYPE;
        pf[1] = HISTORY;
        posting = new PostingStore(address(ledger), address(0), pf);
        bytes32[] memory bf = new bytes32[](3);
        bf[0] = SCOPE;
        bf[1] = ROSTER;
        bf[2] = LIVE;
        bitmap = new BitmapStore(address(ledger), address(0), bf);
        _live(1);
    }

    function _live(uint64 admission) internal {
        ledger.set(GEN, Phase.APPLYING, admission, 1);
    }

    function _idle(uint64 admission) internal {
        ledger.set(GEN, Phase.IDLE, admission, 1);
    }

    function _append(uint64 ordinal) internal {
        vm.prank(GEN);
        posting.append(FamilyId.wrap(BY_TYPE), KEY, ordinal, 0);
    }

    // ---- the writer rule ------------------------------------------------------------------------------------

    function testStrangerCannotWrite() public {
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        bitmap.stamp(S);
        assertFalse(posting.attached());
        assertFalse(bitmap.attached());
    }

    function testUndeclaredFamilyIsRefusedBeforeAuthorization() public {
        bytes32 other = Keys.familyId("by-author");
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, other));
        posting.append(FamilyId.wrap(other), KEY, 1, 0);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, other));
        bitmap.setBit(FamilyId.wrap(other), S, 0, true);
    }

    function testIndexInIdleIsBackfillOnly() public {
        _idle(3);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 1, 0);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        bitmap.setBit(FamilyId.wrap(LIVE), S, 0, true);
        assertFalse(posting.attached(), "an idle call never attaches");
    }

    function testFirstLiveWriteAttachesLazilyAndOpensOneRange() public {
        _live(5);
        _append(5);
        assertTrue(posting.attached());
        (address[] memory g, uint64[] memory from, uint64[] memory to) = posting.writers();
        assertEq(g.length, 1);
        assertEq(g[0], GEN);
        assertEq(from[0], 5);
        assertEq(to[0], 0);
        _live(6);
        _append(6);
        (g,,) = posting.writers();
        assertEq(g.length, 1, "the same generation keeps its open range");
    }

    function testInitialWriterBuildsBeforeAttachmentOnly() public {
        bytes32[] memory pf = new bytes32[](1);
        pf[0] = BY_TYPE;
        PostingStore fresh = new PostingStore(address(ledger), BUILDER, pf);
        _idle(9);
        vm.prank(BUILDER);
        fresh.append(FamilyId.wrap(BY_TYPE), KEY, 1, 0);
        vm.prank(BUILDER);
        fresh.append(FamilyId.wrap(BY_TYPE), KEY, 4, 0);
        assertFalse(fresh.attached(), "building is not attachment");
        (address[] memory g, uint64[] memory from, uint64[] memory to) = fresh.writers();
        assertEq(g.length, 1);
        assertEq(g[0], BUILDER);
        assertEq(from[0], 1);
        assertEq(to[0], 0);
        // the builder may not write while a publication is open, even before attachment
        _live(9);
        vm.prank(BUILDER);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, BUILDER));
        fresh.append(FamilyId.wrap(BY_TYPE), KEY, 5, 0);
        // the generation's first live write closes the build range and opens its own
        _live(10);
        vm.prank(GEN);
        fresh.append(FamilyId.wrap(BY_TYPE), KEY, 10, 0);
        (g, from, to) = fresh.writers();
        assertEq(g.length, 2);
        assertEq(to[0], 9);
        assertEq(g[1], GEN);
        assertEq(from[1], 10);
        assertEq(to[1], 0);
        assertTrue(fresh.attached());
        // and the builder is refused from then on, idle or not
        _idle(10);
        vm.prank(BUILDER);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, BUILDER));
        fresh.append(FamilyId.wrap(BY_TYPE), KEY, 11, 0);
        // a store whose INITIAL_WRITER is zero has no build lane at all
        _idle(10);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(0)));
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 1, 0);
    }

    // ---- posting lists ------------------------------------------------------------------------------------

    function testAppendOrderLaw() public {
        _append(3);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(3), uint64(3)));
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 3, 0);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(3), uint64(2)));
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 2, 0);
        _append(4);
        (uint64 count,, uint64 last,) = posting.postingHead(KEY);
        assertEq(count, 2);
        assertEq(last, 4);
    }

    function testInlineSingletonThenFivePerWord() public {
        _append(3);
        (uint64 count, uint64 live, uint64 last, uint16 flags) = posting.postingHead(KEY);
        assertEq(count, 1);
        assertEq(live, 1);
        assertEq(last, 3);
        assertEq(flags, 0);
        assertEq(posting.postingWords(KEY, 0, 1)[0], 0, "a singleton touches no word");
        assertEq(posting.postingAt(KEY, 0), 3);

        _append(9);
        assertEq(posting.postingWords(KEY, 0, 1)[0], uint256(3) | (uint256(9) << 48));
        assertEq(posting.postingAt(KEY, 0), 3);
        assertEq(posting.postingAt(KEY, 1), 9);

        uint64[7] memory more = [uint64(10), 11, 12, 13, 14, 15, 16];
        for (uint256 i; i < more.length; ++i) {
            _append(more[i]);
        }
        (count,,,) = posting.postingHead(KEY);
        assertEq(count, 9);
        uint256[] memory words = posting.postingWords(KEY, 0, 2);
        assertEq(
            words[0],
            uint256(3) | (uint256(9) << 48) | (uint256(10) << 96) | (uint256(11) << 144)
                | (uint256(12) << 192)
        );
        assertEq(
            words[1], uint256(13) | (uint256(14) << 48) | (uint256(15) << 96) | (uint256(16) << 144)
        );
        uint64[] memory slice = posting.postingSlice(KEY, 0, 100);
        assertEq(slice.length, 9);
        assertEq(slice[0], 3);
        assertEq(slice[1], 9);
        assertEq(slice[8], 16);
        slice = posting.postingSlice(KEY, 7, 2);
        assertEq(slice.length, 2);
        assertEq(slice[0], 15);
        assertEq(slice[1], 16);
        assertEq(posting.postingSlice(KEY, 9, 3).length, 0);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(9), uint64(9)));
        posting.postingAt(KEY, 9);
    }

    function testFlagsAccumulateAndReleaseIsBoundedByLive() public {
        vm.prank(GEN);
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 1, 0x0001);
        vm.prank(GEN);
        posting.append(FamilyId.wrap(BY_TYPE), KEY, 2, 0x0100);
        (, uint64 live,, uint16 flags) = posting.postingHead(KEY);
        assertEq(flags, 0x0101);
        assertEq(live, 2);
        vm.prank(GEN);
        assertEq(posting.release(FamilyId.wrap(BY_TYPE), KEY, 1), 1);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(1), uint64(2)));
        posting.release(FamilyId.wrap(BY_TYPE), KEY, 2);
        (uint64 count, uint64 live2,,) = posting.postingHead(KEY);
        assertEq(count, 2, "release never removes entries");
        assertEq(live2, 1);
    }

    function testAppendBatchWritesEveryEntryUnderTheWriterRule() public {
        FamilyId[] memory fam = new FamilyId[](2);
        fam[0] = FamilyId.wrap(BY_TYPE);
        fam[1] = FamilyId.wrap(HISTORY);
        PostingKey[] memory keys = new PostingKey[](2);
        keys[0] = KEY;
        keys[1] = PostingKey.wrap(keccak256("other"));
        uint64[] memory ords = new uint64[](2);
        ords[0] = 7;
        ords[1] = 7;
        vm.prank(GEN);
        posting.appendBatch(fam, keys, ords);
        (uint64 c0,,,) = posting.postingHead(keys[0]);
        (uint64 c1,,,) = posting.postingHead(keys[1]);
        assertEq(c0 + c1, 2);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        posting.appendBatch(fam, keys, ords);
    }

    // ---- scope lists and live bits ----------------------------------------------------------------------------

    function testScopeEntriesLiveBitsAndStamps() public {
        _live(11);
        vm.prank(GEN);
        assertEq(bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1), 0);
        _live(12);
        vm.prank(GEN);
        assertEq(bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 4), 1);
        _live(13);
        vm.prank(GEN);
        assertEq(bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 9), 2);
        (uint64 count, uint64 live, uint64 lastMutation, uint48 liveBits0,, uint64 entry0) =
            bitmap.scopeHead(S);
        assertEq(count, 3);
        assertEq(live, 3);
        assertEq(lastMutation, 13);
        assertEq(liveBits0, 7);
        assertEq(entry0, 1);
        assertEq(bitmap.scopeEntry(S, 1), 4);
        assertEq(bitmap.scopeEntry(S, 2), 9);
        uint64[] memory slice = bitmap.scopeSlice(S, 0, 10);
        assertEq(slice.length, 3);
        assertEq(slice[2], 9);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(LIVE), 0, 1)[0], 7);
        assertEq(bitmap.liveCount(S), 3);

        // the order law holds on binding ordinals
        _live(14);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(9), uint64(9)));
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 9);

        // a mask clears the bit, adjusts the live count, stamps; liveAt walks live entries only
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(LIVE), S, 1, false);
        (, live, lastMutation, liveBits0,,) = bitmap.scopeHead(S);
        assertEq(live, 2);
        assertEq(lastMutation, 14);
        assertEq(liveBits0, 5);
        assertEq(bitmap.liveAt(S, 0), 1);
        assertEq(bitmap.liveAt(S, 1), 9);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(2), uint64(2)));
        bitmap.liveAt(S, 2);
        // an idempotent clear changes nothing but the stamp
        _live(15);
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(LIVE), S, 1, false);
        (, live, lastMutation,,,) = bitmap.scopeHead(S);
        assertEq(live, 2);
        assertEq(lastMutation, 15);
        // restore
        _live(16);
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(LIVE), S, 1, true);
        (, live, lastMutation, liveBits0,,) = bitmap.scopeHead(S);
        assertEq(live, 3);
        assertEq(liveBits0, 7);
        assertEq(lastMutation, 16);
        // a bare stamp (REBIND) moves lastMutation only
        _live(17);
        vm.prank(GEN);
        bitmap.stamp(S);
        assertEq(bitmap.lastMutation(S), 17);
        (, live,,,,) = bitmap.scopeHead(S);
        assertEq(live, 3);
        // out-of-range entries are refused
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(3), uint64(3)));
        bitmap.setBit(FamilyId.wrap(LIVE), S, 3, true);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(3), uint64(3)));
        bitmap.scopeEntry(S, 3);
    }

    function testLiveBitsBeyondFortyEightSpillIntoWords() public {
        for (uint64 i = 1; i <= 50; ++i) {
            _live(i);
            vm.prank(GEN);
            bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, i);
        }
        (uint64 count, uint64 live,, uint48 liveBits0,,) = bitmap.scopeHead(S);
        assertEq(count, 50);
        assertEq(live, 50);
        assertEq(liveBits0, type(uint48).max);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(LIVE), 0, 1)[0], (uint256(1) << 50) - 1);
        assertEq(bitmap.scopeEntry(S, 49), 50);
        assertEq(bitmap.scopeEntry(S, 48), 49);
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(LIVE), S, 49, false);
        assertEq(
            bitmap.liveWords(S, FamilyId.wrap(LIVE), 0, 1)[0],
            ((uint256(1) << 50) - 1) ^ (uint256(1) << 49)
        );
        (, live,, liveBits0,,) = bitmap.scopeHead(S);
        assertEq(live, 49);
        assertEq(liveBits0, type(uint48).max, "the head bits are untouched by a spilled entry");
        assertEq(bitmap.liveAt(S, 48), 49);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(49), uint64(49)));
        bitmap.liveAt(S, 49);
    }

    function testOtherBitmapFamiliesKeepTheirOwnWords() public {
        _live(1);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1);
        _live(2);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 2);
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(ROSTER), S, 1, true);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(ROSTER), 0, 1)[0], 2);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(LIVE), 0, 1)[0], 3, "the live bits are separate");
        assertEq(bitmap.liveCount(S), 2, "a roster bit is not a live bit");
        vm.prank(GEN);
        bitmap.setBit(FamilyId.wrap(ROSTER), S, 1, false);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(ROSTER), 0, 1)[0], 0);
    }

    // ---- coverage slots and the backfill modes ---------------------------------------------------------------

    function testCoverageIsOpenedLiveAndBackfilledIdle() public {
        _live(20);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 2);
        vm.prank(GEN);
        bitmap.openCoverage(FamilyId.wrap(ROSTER), S, 20);
        (uint64 through, uint64 liveFrom, uint64 retiredAt, uint8 state) =
            bitmap.scopeCoverage(FamilyId.wrap(ROSTER), S);
        assertEq(through, 0);
        assertEq(liveFrom, 20);
        assertEq(retiredAt, 0);
        assertEq(state, 1);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_COVERAGE.selector, uint8(1)));
        bitmap.openCoverage(FamilyId.wrap(ROSTER), S, 21);
        // backfill is refused while a publication is open
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 1, 10);
        // idle: a MONOTONE backfill ORs words and advances `through` within [through, liveFrom]
        _idle(20);
        vm.prank(GEN);
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 1, 10);
        (through,,, state) = bitmap.scopeCoverage(FamilyId.wrap(ROSTER), S);
        assertEq(through, 10);
        assertEq(state, 1);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(ROSTER), 0, 1)[0], 1);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_BACKFILL.selector, uint8(2)));
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 2, 9);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_BACKFILL.selector, uint8(2)));
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 2, 21);
        vm.prank(GEN);
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 2, 20);
        (through,,, state) = bitmap.scopeCoverage(FamilyId.wrap(ROSTER), S);
        assertEq(through, 20);
        assertEq(state, 2, "reaching liveFrom completes the slot");
        assertEq(bitmap.liveWords(S, FamilyId.wrap(ROSTER), 0, 1)[0], 3);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_BACKFILL.selector, uint8(1)));
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 4, 20);
        // a stranger never backfills
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        bitmap.backfillOr(FamilyId.wrap(ROSTER), S, 0, 4, 20);
    }

    function testCurrentStateBackfillSetsAndClearsLiveBits() public {
        _live(5);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 1);
        vm.prank(GEN);
        bitmap.appendScopeEntry(FamilyId.wrap(SCOPE), S, 2);
        vm.prank(GEN);
        bitmap.openCoverage(FamilyId.wrap(LIVE), S, 5);
        _idle(5);
        vm.prank(GEN);
        bitmap.backfillSet(FamilyId.wrap(LIVE), S, 0, false, 3);
        assertEq(bitmap.liveCount(S), 1);
        assertEq(bitmap.liveWords(S, FamilyId.wrap(LIVE), 0, 1)[0], 2);
        vm.prank(GEN);
        bitmap.backfillSet(FamilyId.wrap(LIVE), S, 0, true, 5);
        assertEq(bitmap.liveCount(S), 2);
        (uint64 through,,, uint8 state) = bitmap.scopeCoverage(FamilyId.wrap(LIVE), S);
        assertEq(through, 5);
        assertEq(state, 2);
        // retirement freezes the slot from the idle lane only
        _live(6);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        bitmap.retireCoverage(FamilyId.wrap(LIVE), S);
        _idle(6);
        vm.prank(GEN);
        bitmap.retireCoverage(FamilyId.wrap(LIVE), S);
        (,, uint64 retiredAt, uint8 st) = bitmap.scopeCoverage(FamilyId.wrap(LIVE), S);
        assertEq(retiredAt, 6);
        assertEq(st, 3);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_COVERAGE.selector, uint8(2)));
        bitmap.retireCoverage(FamilyId.wrap(ROSTER), S);
    }

    function testIdentityGetters() public view {
        assertEq(posting.ledger(), address(ledger));
        assertEq(bitmap.ledger(), address(ledger));
        assertEq(posting.initialWriter(), address(0));
        assertEq(posting.storeAbiId(), keccak256("efs2/posting-store/1"));
        assertEq(bitmap.storeAbiId(), keccak256("efs2/bitmap-store/1"));
        assertEq(posting.familyIds().length, 2);
        assertEq(bitmap.familyIds().length, 3);
        assertEq(bitmap.familyIds()[2], LIVE);
    }
}
