// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {TopicMineReader} from "../../src/readers/TopicMineReader.sol";
import {TopicEveryoneReader} from "../../src/readers/TopicEveryoneReader.sol";
import {TopicLookupReader} from "../../src/readers/TopicLookupReader.sol";
import {
    E_TOPIC_INCONSISTENT,
    E_TOPIC_READ,
    E_TOPIC_REPLY,
    E_TOPIC_STATUS
} from "../../src/readers/TopicReaderBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {Coverage, Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicEveryoneReader,
    MineRow,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../../src/interfaces/ILedgerViews.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice Both topic readers through the `FaultyReads` port (design §11): one wrapper in front of the ledger, each
///         facet, the index and its bitmap store, and readers built over the wrappers. Every fault ends in a named
///         revert (`E_TOPIC_READ`, `E_TOPIC_REPLY`, `E_TOPIC_STATUS`, `E_TOPIC_INCONSISTENT(code)`), an unnamed
///         decoder revert, or a refusal as data (UNKNOWN / UNSUPPORTED with no rows and coverage UNKNOWN); none makes an
///         UNKNOWN read as an empty page or as a yes. EXTRA (trailing bytes) is tolerated: the page is the faithful
///         one.
contract TopicFaultyTest is TopicReadersBase {
    uint8 internal constant M_REVERT = 1;
    uint8 internal constant M_SHORT = 2;
    uint8 internal constant M_EXTRA = 3;
    uint8 internal constant M_SET_WORD = 4;
    uint8 internal constant M_ADD_WORD = 5;
    uint8 internal constant M_ZERO = 6;
    uint8 internal constant M_STALE = 7;
    uint8 internal constant M_FUTURE_ADMISSION = 8;
    uint8 internal constant M_EXHAUST = 9;
    uint8 internal constant M_EMPTY = 10;

    FaultyReads internal fl;
    FaultyReads internal fv;
    FaultyReads internal fr;
    FaultyReads internal fi;
    FaultyReads internal fs;
    TopicMineReader internal fp;
    TopicEveryoneReader internal fe;
    TopicLookupReader internal fk;
    bytes32[] internal t;
    bytes32 internal pos;
    bytes32 internal page;

    function setUp() public override {
        super.setUp();
        t = _regPath("fault", 2);
        page = t[0];
        _tag(alice, t[0], things[0]);
        _tag(alice, t[1], things[1]);
        _deny(alice, t[0], things[2]); // a dead entry of the exact list
        _tag(alice, t[0], things[3]);
        _tag(bob, t[0], things[0]);
        _deny(carol, t[0], things[0]);
        pos = Keys.position(Purpose.TAG, t[0], things[0]);
        fl = new FaultyReads(address(r.ledger));
        fv = new FaultyReads(address(views));
        fr = new FaultyReads(address(reads));
        fi = new FaultyReads(address(r.g.index));
        fs = new FaultyReads(address(r.g.bitmap));
        fv.setBasis(address(r.ledger));
        fr.setBasis(address(r.ledger));
        fi.setBasis(address(r.ledger));
        fs.setBasis(address(r.ledger));
        _set(fl, ILedgerHot.index.selector, M_SET_WORD, 0, uint160(address(fi)));
        _set(fi, IIndexReads.bitmapStore.selector, M_SET_WORD, 0, uint160(address(fs)));
        fp = new TopicMineReader(address(fl), address(fv), address(fr));
        fe = new TopicEveryoneReader(address(fl), address(fv), address(fr));
        fk = new TopicLookupReader(
            address(fl), address(fv), address(fr), typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]
        );
    }

    function _set(FaultyReads f, bytes4 selector, uint8 mode, uint16 word, uint256 value) internal {
        f.setFault(selector, FaultyReads.Fault(mode, word, false, bytes32(0), value));
    }

    function _mineF(bool below) internal view returns (TopicPageInfo memory, MineRow[] memory) {
        return fp.mine(_lens2(alice, bob), t[0], below, _unbound(), "", 0, 0, 0);
    }

    /// A page of one row: one batch of one candidate (bob's newest exact entry: the heads of alice and bob).
    function _mine1() internal view returns (TopicPageInfo memory, MineRow[] memory) {
        return fp.mine(_lens2(alice, bob), t[0], false, _unbound(), "", 1, 0, 0);
    }

    function _byNameF() internal view returns (TopicPageInfo memory, AuthorRow[] memory) {
        return fk.byName(pos, _unbound(), "", 0);
    }

    function _unknownAsData(TopicPageInfo memory info, uint256 rows) internal pure {
        assertEq(uint8(info.q.status), uint8(Status.UNKNOWN), "UNKNOWN, never empty");
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
        assertEq(rows, 0);
        assertFalse(info.completeFromOrigin);
    }

    function test_the_wrappers_are_faithful_without_a_fault() public view {
        (TopicPageInfo memory a, MineRow[] memory x) = _mineF(true);
        (TopicPageInfo memory b, MineRow[] memory y) =
            miner.mine(_lens2(alice, bob), t[0], true, _unbound(), "", 0, 0, 0);
        assertEq(x.length, 3);
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)));
        assertEq(uint8(a.listingCoverage), uint8(Coverage.COMPLETE));
        assertEq(uint8(b.listingCoverage), uint8(Coverage.COMPLETE));
        (, AuthorRow[] memory n) = _byNameF();
        assertEq(n.length, 3);
    }

    // ---- coverage: UNKNOWN is data, UNSET is a fault ---------------------------------------------------------

    function test_an_unknown_roll_up_is_an_unknown_page() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_SET_WORD, 0, uint8(Coverage.UNKNOWN));
        (TopicPageInfo memory info, MineRow[] memory rows) = _mineF(true);
        _unknownAsData(info, rows.length);
        (TopicPageInfo memory n, AuthorRow[] memory a) = _byNameF();
        _unknownAsData(n, a.length);
    }

    function test_an_unknown_scope_coverage_is_an_unknown_page() public {
        _set(fi, IIndexReads.coverage.selector, M_SET_WORD, 0, uint8(Coverage.UNKNOWN));
        (TopicPageInfo memory info, MineRow[] memory rows) = _mineF(false);
        _unknownAsData(info, rows.length);
    }

    function test_an_unset_coverage_is_a_reply_fault() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_SET_WORD, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(E_TOPIC_REPLY.selector, IIndexReads.postingHeadOf.selector, 0)
        );
        _byNameF();
        _set(fi, IIndexReads.coverage.selector, M_ZERO, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 6));
        _mineF(false);
    }

    function test_a_coverage_past_its_enum_reverts() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_ADD_WORD, 0, 1);
        vm.expectRevert();
        _byNameF();
    }

    function test_a_coverage_frontier_in_the_future() public {
        _set(fi, IIndexReads.coverage.selector, M_FUTURE_ADMISSION, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 6));
        _mineF(false);
    }

    // ---- list heads and entries ------------------------------------------------------------------------------

    function test_a_list_head_in_the_future() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_FUTURE_ADMISSION, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 1));
        _byNameF();
    }

    function test_a_live_count_past_its_entries() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_SET_WORD, 2, 99);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 1));
        _byNameF();
    }

    function test_a_count_past_its_slice() public {
        _set(fi, IIndexReads.postingHeadOf.selector, M_ADD_WORD, 1, 2);
        vm.expectPartialRevert(E_TOPIC_INCONSISTENT.selector);
        _byNameF();
    }

    function test_slice_entries_out_of_order() public {
        // byName reads 3 entries: word 4 is the first, word 6 the last
        _set(fi, IIndexReads.postingSliceOf.selector, M_SET_WORD, 6, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 2));
        _byNameF();
    }

    function test_a_short_slice_reverts() public {
        _set(fi, IIndexReads.postingSliceOf.selector, M_SHORT, 0, 100);
        vm.expectRevert();
        _byNameF();
    }

    function test_scope_head_out_of_range() public {
        _set(fs, IBitmapStore.scopeHead.selector, M_SET_WORD, 1, 9);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 7));
        _mineF(false);
        _set(fs, IBitmapStore.scopeHead.selector, M_FUTURE_ADMISSION, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 7));
        _mineF(false);
    }

    function test_a_scope_entry_in_the_future() public {
        _set(fs, IBitmapStore.scopeSlice.selector, M_FUTURE_ADMISSION, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 2));
        _mineF(false);
    }

    function test_a_live_bit_on_a_dead_entry() public {
        _set(fs, IBitmapStore.liveWords.selector, M_SET_WORD, 2, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mineF(false);
    }

    // ---- facet rows ------------------------------------------------------------------------------------------

    // `lensRule` reply of `_mine1` (one entry): offsets [0..6], BasisCommit [7..12], st [13 len, 14], positions
    // [15, 16], cells [17, 18 purpose, 19 subject, 20 role], decider [21, 22], decided [23, 24], strength [25, 26],
    // own [27 len, 28 state, 29 revision, 30 admission, 31 targetKind, 32 prevAdmission, 33 bindingOrdinal,
    // 34 notAfter, 35 target, 36 strength]. The entry is bob's; alice (lens index 0) decides with a yes.

    function test_a_binding_cell_of_another_place() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 19, uint256(keccak256("x")));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 3));
        _mine1();
    }

    function test_an_absent_entry_is_inconsistent_and_unknown_a_status_fault() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 14, uint8(Status.ABSENT_PROVEN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 3));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 14, uint8(Status.UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNKNOWN)));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 14, uint8(Status.UNSUPPORTED));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNSUPPORTED)));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 14, 0);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mine1();
    }

    function test_an_own_head_reported_unset_is_never_a_silence() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 28, 0);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
    }

    function test_a_reserved_or_contradictory_own_head_is_inconsistent() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 28, 7);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 28, 2); // MASKED with a target
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
    }

    function test_a_decision_that_contradicts_the_own_head() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 22, 255); // nobody decides, but bob is BOUND
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 24, 0); // a decider without a state
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 22, 2); // a decider past the author
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
    }

    function test_a_deciders_strength_that_contradicts_its_head() public {
        // bob alone in the lens, bob's own entry: the decider is the author, so its strength must be the head's
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 26, 7);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        fp.mine(_lens1(bob), t[0], false, _unbound(), "", 1, 0, 0);
    }

    function test_an_own_head_of_another_binding_is_inconsistent() public {
        _set(fv, ILedgerViews.lensRule.selector, M_ADD_WORD, 33, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
    }

    function test_a_lens_rule_echoing_another_basis() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SET_WORD, 7, uint256(keccak256("e")));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 5));
        _mine1();
    }

    function test_an_own_head_admitted_in_the_future() public {
        _set(fv, ILedgerViews.lensRule.selector, M_FUTURE_ADMISSION, 30, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mine1();
    }

    function test_a_short_lens_rule_reply_reverts() public {
        _set(fv, ILedgerViews.lensRule.selector, M_SHORT, 0, 500);
        vm.expectRevert();
        _mine1();
    }

    function test_author_heads_unknown_and_absent() public {
        // (st[], principals[], heads[], basis): st[0] is word 10
        _set(fv, ILedgerViews.authorHeads.selector, M_SET_WORD, 10, uint8(Status.UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNKNOWN)));
        _byNameF();
        _set(fv, ILedgerViews.authorHeads.selector, M_SET_WORD, 10, uint8(Status.ABSENT_PROVEN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _byNameF();
        _set(fv, ILedgerViews.authorHeads.selector, M_SET_WORD, 12, uint8(Status.PRESENT));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4)); // carol's head is MASKED
        _byNameF();
    }

    function test_word_page_registration_of_another_kind() public {
        // (status, AdmissionRow): word 1 is the kind
        _set(fr, ILedgerReads.admission.selector, M_SET_WORD, 1, 3);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 8));
        fk.children(t[0], _unbound(), "", 0);
    }

    // ---- everyone: the author head decides "someone says yes"; UNKNOWN is never a no -------------------------

    function _everyoneF() internal view returns (TopicPageInfo memory, PlaceRow[] memory) {
        return fe.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.TAG, t[0], false, false, 0),
            _lens1(alice),
            _unbound(),
            "",
            0,
            0,
            0
        );
    }

    function test_an_unknown_author_head_is_an_unknown_page() public {
        (, PlaceRow[] memory want) = _everyoneF();
        assertGt(want.length, 0);
        fi.setFault(
            IIndexReads.postingHeadOf.selector,
            FaultyReads.Fault(M_SET_WORD, 0, true, F_POSITION_AUTHORS, uint8(Coverage.UNKNOWN))
        );
        (TopicPageInfo memory info, PlaceRow[] memory rows) = _everyoneF();
        _unknownAsData(info, rows.length);
    }

    function test_a_yes_count_past_the_statements_is_inconsistent() public {
        fi.setFault(
            IIndexReads.postingHeadOf.selector,
            FaultyReads.Fault(M_SET_WORD, 2, true, F_POSITION_AUTHORS, 99)
        );
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 1));
        _everyoneF();
    }

    // ---- the viewed-place check: the author-list shortcut and the head-state read --------------------------------

    function _hasThing(MineRow[] memory rows, bytes32 thing) internal pure returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].thing == thing) return true;
        }
        return false;
    }

    /// The viewed position of alice's roll-up row (things[1] under t[1], viewed at t[0]) gets a stranger's statement,
    /// so the check reads alice's head state there (`headStates`); each fault of that read is a named revert.
    function test_head_state_faults_are_named_reverts() public {
        _tag(carol, t[0], things[1]); // a stranger at the viewed position: its author list is not empty
        (, MineRow[] memory want) = _mineF(true);
        assertTrue(_hasThing(want, things[1]), "the stranger hides nothing");
        // reply words: 0 offset, 1..6 basis, 7 length, 8 the first state
        fv.setMode(ILedgerViews.headStates.selector, M_REVERT);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_TOPIC_READ.selector, address(fv), ILedgerViews.headStates.selector
            )
        );
        _mineF(true);
        fv.setMode(ILedgerViews.headStates.selector, M_EXHAUST);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        _mineF(true);
        fv.setMode(ILedgerViews.headStates.selector, M_EMPTY);
        vm.expectRevert(
            abi.encodeWithSelector(E_TOPIC_REPLY.selector, ILedgerViews.headStates.selector, 0)
        );
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_SHORT, 0, 200);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_SET_WORD, 8, 7); // a reserved state
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNSUPPORTED)));
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_SET_WORD, 8, 256); // past uint8: the decoder refuses
        vm.expectRevert();
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_SET_WORD, 7, 0); // no states for the keys asked
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_ADD_WORD, 7, 1); // a length past the reply
        vm.expectRevert();
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_SET_WORD, 1, uint256(keccak256("e")));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 5)); // another basis
        _mineF(true);
        _set(fv, ILedgerViews.headStates.selector, M_EXTRA, 0, 64);
        (, MineRow[] memory got) = _mineF(true);
        assertEq(
            keccak256(abi.encode(got)), keccak256(abi.encode(want)), "trailing bytes tolerated"
        );
    }

    /// A lens of four whose every author has a "not this" at t[0] about another thing (none is all live, so all four
    /// are asked about alice's roll-up row things[1] at the viewed place, enough for the author-list read).
    function _lens4() internal returns (bytes32[] memory l) {
        address dave = makeAddr("fault/dave");
        address erin = makeAddr("fault/erin");
        _deny(dave, t[0], things[2]);
        _deny(erin, t[0], things[2]);
        l = new bytes32[](4);
        l[0] = _pid(carol); // "not this" at t[0] about things[0]
        l[1] = _pid(dave);
        l[2] = _pid(erin);
        l[3] = _pid(alice); // "not this" at t[0] about things[2]; files things[1] under t[1]
    }

    /// The viewed position's author list decides only "nobody stated anything here", and only at COMPLETE coverage:
    /// UNKNOWN or PARTIAL asks the heads as before (observed here by arming the head-state read to revert), so a list
    /// the index cannot vouch for is never read as "nobody"; UNSET coverage and a count in the future are faults.
    function test_an_author_list_the_index_cannot_vouch_for_never_reads_as_nobody() public {
        bytes32[] memory lens = _lens4();
        (, MineRow[] memory want) = fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        assertTrue(_hasThing(want, things[1]), "nobody stated anything at the viewed position");
        // COMPLETE and empty: no head is read at the viewed place
        fv.setMode(ILedgerViews.headStates.selector, M_REVERT);
        (, MineRow[] memory got) = fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)), "no state read");
        for (uint256 c = uint8(Coverage.UNKNOWN); c <= uint8(Coverage.PARTIAL); ++c) {
            fi.setFault(
                IIndexReads.postingHeadOf.selector,
                FaultyReads.Fault(M_SET_WORD, 0, true, F_POSITION_AUTHORS, c)
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    E_TOPIC_READ.selector, address(fv), ILedgerViews.headStates.selector
                )
            );
            fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        }
        fv.clear(ILedgerViews.headStates.selector);
        (TopicPageInfo memory info, MineRow[] memory asked) =
            fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(keccak256(abi.encode(asked)), keccak256(abi.encode(want)), "asked: the same rows");
        fi.setFault(
            IIndexReads.postingHeadOf.selector,
            FaultyReads.Fault(M_SET_WORD, 0, true, F_POSITION_AUTHORS, 0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(E_TOPIC_REPLY.selector, IIndexReads.postingHeadOf.selector, 0)
        );
        fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        fi.setFault(
            IIndexReads.postingHeadOf.selector,
            FaultyReads.Fault(M_FUTURE_ADMISSION, 1, true, F_POSITION_AUTHORS, 1)
        );
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 1));
        fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        // a lens author's "not this" at the viewed place hides, whatever the list's coverage says
        fi.clear(IIndexReads.postingHeadOf.selector);
        _deny(makeAddr("fault/erin"), t[0], things[1]);
        (, got) = fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        assertFalse(_hasThing(got, things[1]), "erin (index 2) hides it at the viewed place");
        fi.setFault(
            IIndexReads.postingHeadOf.selector,
            FaultyReads.Fault(M_SET_WORD, 0, true, F_POSITION_AUTHORS, uint8(Coverage.UNKNOWN))
        );
        (, got) = fp.mine(lens, t[0], true, _unbound(), "", 0, 0, 0);
        assertFalse(_hasThing(got, things[1]), "UNKNOWN never reads as nobody");
    }

    /// The all-live scope shortcut is read only at COMPLETE live-scope coverage, and a live-scope coverage that is
    /// not COMPLETE refuses the page (the list-coverage rule: PARTIAL is UNKNOWN), so the shortcut can never stand in
    /// for a list the index has not finished.
    function test_a_partial_scope_coverage_refuses_the_page() public {
        // bob's exact list at t[0] is all live (bob is skipped at COMPLETE); a stranger keeps the author list full
        _tag(carol, t[0], things[1]);
        (TopicPageInfo memory info, MineRow[] memory got) = _mineF(true);
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertGt(got.length, 0);
        _set(fi, IIndexReads.coverage.selector, M_SET_WORD, 0, uint8(Coverage.PARTIAL));
        (info, got) = _mineF(true);
        _unknownAsData(info, got.length);
        assertEq(info.rawTotal, 0, "a refusal carries no counts");
        assertEq(info.frontier, 0);
        assertEq(info.next.length, 0);
    }

    // ---- refusals as data ------------------------------------------------------------------------------------

    function test_a_foreign_layout_is_unsupported_as_data() public {
        _set(fl, ILedgerHot.layoutId.selector, M_SET_WORD, 0, uint256(keccak256("other")));
        (TopicPageInfo memory info, MineRow[] memory rows) = _mineF(true);
        assertEq(uint8(info.q.status), uint8(Status.UNSUPPORTED));
        assertEq(rows.length, 0);
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
        assertEq(info.frontier, 0, "a refusal's frontier is 0");
        (TopicPageInfo memory w, PlaceCount[] memory p) = fk.wordPage(page, _unbound(), "", 0);
        assertEq(uint8(w.q.status), uint8(Status.UNSUPPORTED));
        assertEq(p.length, 0);
        assertEq(w.frontier, 0, "a refusal's frontier is 0");
    }

    function test_an_unlisted_index_profile_is_unsupported_as_data() public {
        _set(fi, bytes4(keccak256("CALLBACK_PROFILE()")), M_SET_WORD, 0, 1);
        (TopicPageInfo memory info,) = _byNameF();
        assertEq(uint8(info.q.status), uint8(Status.UNSUPPORTED));
        assertEq(info.frontier, 0, "a refusal's frontier is 0");
    }

    // ---- the new primitives ----------------------------------------------------------------------------------

    function test_revert_exhaust_and_empty_are_read_or_reply_faults() public {
        fr.setMode(ILedgerReads.basis.selector, M_REVERT);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        _byNameF();
        fr.clear(ILedgerReads.basis.selector);
        fv.setMode(ILedgerViews.lensRule.selector, M_EXHAUST);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        _mineF(false);
        fv.setMode(ILedgerViews.lensRule.selector, M_EMPTY);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mineF(false);
        fv.clear(ILedgerViews.lensRule.selector);
        fi.setMode(IIndexReads.bitmapStore.selector, M_EMPTY);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mineF(false);
    }

    function test_extra_trailing_bytes_are_tolerated() public {
        (, MineRow[] memory want) = _mineF(true);
        _set(fv, ILedgerViews.lensRule.selector, M_EXTRA, 0, 64);
        _set(fi, IIndexReads.postingSliceOf.selector, M_EXTRA, 0, 96);
        _set(fs, IBitmapStore.liveWords.selector, M_EXTRA, 0, 32);
        (, MineRow[] memory got) = _mineF(true);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)));
    }

    function test_a_stale_lens_rule_reply_is_inconsistent() public {
        uint64[] memory o = new uint64[](1);
        o[0] = _ordinal(bob, Purpose.TAG, t[0], things[0]);
        uint8[] memory who = new uint8[](1);
        who[0] = 1;
        fv.capture(abi.encodeCall(ILedgerViews.lensRule, (address(fl), _lens2(alice, bob), o, who)));
        _tag(carol, t[1], things[5]); // a later admission
        fv.setMode(ILedgerViews.lensRule.selector, M_STALE);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 5));
        _mine1();
    }
}
