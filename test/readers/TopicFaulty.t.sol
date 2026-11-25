// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {TopicPageReader} from "../../src/readers/TopicPageReader.sol";
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
import {AuthorRow, MineRow, PlaceCount, TopicPageInfo} from "../../src/interfaces/Readers.sol";
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
    TopicPageReader internal fp;
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
        fp = new TopicPageReader(address(fl), address(fv), address(fr));
        fk = new TopicLookupReader(
            address(fl), address(fv), address(fr), typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]
        );
    }

    function _set(FaultyReads f, bytes4 selector, uint8 mode, uint16 word, uint256 value) internal {
        f.setFault(selector, FaultyReads.Fault(mode, word, false, bytes32(0), value));
    }

    function _mineF(bool below) internal view returns (TopicPageInfo memory, MineRow[] memory) {
        return fp.mine(_lens2(alice, bob), t[0], below, _unbound(), "", 0, 0);
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
            pager.mine(_lens2(alice, bob), t[0], true, _unbound(), "", 0, 0);
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

    function test_a_binding_cell_of_another_place() public {
        // (st[], positions[], cells[], basis): one ordinal; cells[0].subject is word 15
        _set(fv, ILedgerViews.bindingCells.selector, M_SET_WORD, 15, uint256(keccak256("x")));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 3));
        _mineF(false);
    }

    function test_an_absent_binding_cell_is_inconsistent_and_unknown_a_status_fault() public {
        _set(fv, ILedgerViews.bindingCells.selector, M_SET_WORD, 10, uint8(Status.ABSENT_PROVEN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 3));
        _mineF(false);
        _set(fv, ILedgerViews.bindingCells.selector, M_SET_WORD, 10, uint8(Status.UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNKNOWN)));
        _mineF(false);
    }

    function test_heads_at_unknown_is_never_a_silence() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 0, uint8(Status.UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_STATUS.selector, uint8(Status.UNKNOWN)));
        _mineF(false);
    }

    function test_heads_at_status_contradicts_its_state() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 0, uint8(Status.MASKED));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mineF(false);
    }

    function test_heads_at_selects_nobody() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 10, 255);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mineF(false);
    }

    function test_heads_at_echoes_another_basis() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 12, uint256(keccak256("e")));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 5));
        _mineF(false);
    }

    function test_a_head_admitted_in_the_future() public {
        _set(fv, ILedgerViews.headsAt.selector, M_FUTURE_ADMISSION, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 4));
        _mineF(false);
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

    // ---- refusals as data ------------------------------------------------------------------------------------

    function test_a_foreign_layout_is_unsupported_as_data() public {
        _set(fl, ILedgerHot.layoutId.selector, M_SET_WORD, 0, uint256(keccak256("other")));
        (TopicPageInfo memory info, MineRow[] memory rows) = _mineF(true);
        assertEq(uint8(info.q.status), uint8(Status.UNSUPPORTED));
        assertEq(rows.length, 0);
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
        (TopicPageInfo memory w, PlaceCount[] memory p) = fk.wordPage(page, _unbound(), "", 0);
        assertEq(uint8(w.q.status), uint8(Status.UNSUPPORTED));
        assertEq(p.length, 0);
    }

    function test_an_unlisted_index_profile_is_unsupported_as_data() public {
        _set(fi, bytes4(keccak256("CALLBACK_PROFILE()")), M_SET_WORD, 0, 1);
        (TopicPageInfo memory info,) = _byNameF();
        assertEq(uint8(info.q.status), uint8(Status.UNSUPPORTED));
    }

    // ---- the new primitives ----------------------------------------------------------------------------------

    function test_revert_exhaust_and_empty_are_read_or_reply_faults() public {
        fr.setMode(ILedgerReads.basis.selector, M_REVERT);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        _byNameF();
        fr.clear(ILedgerReads.basis.selector);
        fv.setMode(ILedgerViews.headsAt.selector, M_EXHAUST);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        _mineF(false);
        fv.clear(ILedgerViews.headsAt.selector);
        fv.setMode(ILedgerViews.bindingCells.selector, M_EMPTY);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mineF(false);
        fv.clear(ILedgerViews.bindingCells.selector);
        fi.setMode(IIndexReads.bitmapStore.selector, M_EMPTY);
        vm.expectPartialRevert(E_TOPIC_REPLY.selector);
        _mineF(false);
    }

    function test_extra_trailing_bytes_are_tolerated() public {
        (, MineRow[] memory want) = _mineF(true);
        _set(fv, ILedgerViews.headsAt.selector, M_EXTRA, 0, 64);
        _set(fi, IIndexReads.postingSliceOf.selector, M_EXTRA, 0, 96);
        _set(fs, IBitmapStore.liveWords.selector, M_EXTRA, 0, 32);
        (, MineRow[] memory got) = _mineF(true);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)));
    }

    function test_a_stale_heads_at_is_inconsistent() public {
        bytes32 p0 = Keys.position(Purpose.TAG, t[0], things[3]);
        bytes32[] memory one = _lens1(alice);
        fv.capture(abi.encodeCall(ILedgerViews.headsAt, (address(fl), one, p0)));
        _tag(carol, t[0], things[5]); // a later admission
        fv.setMode(ILedgerViews.headsAt.selector, M_STALE);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_INCONSISTENT.selector, 5));
        fp.mine(one, t[0], false, _unbound(), "", 1, 0);
    }
}
