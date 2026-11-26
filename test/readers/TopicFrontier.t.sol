// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {CountCapReads} from "../harness/doubles/CountCapReads.sol";
import {TopicMineReader} from "../../src/readers/TopicMineReader.sol";
import {TopicEveryoneReader} from "../../src/readers/TopicEveryoneReader.sol";
import {TopicLookupReader} from "../../src/readers/TopicLookupReader.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {E_TOPIC_READ} from "../../src/readers/TopicReaderBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {FamilyId, Purpose, ScopeKey, TypeId} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Coverage, Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicEveryoneReader,
    MineRow,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";

/// @notice `TopicPageInfo.frontier` on every topic view (the page laws in `src/interfaces/Readers.sol`). Each chain
///         is checked against the listing's own entries read straight from the index, merged newest first: after
///         every PRESENT page, `frontier` is the entry the next page reads first (the entry at the listing's
///         cumulative `scanned`), 0 exactly when EXHAUSTED; every row of the page has an entry > `frontier`; every row
///         of every later page has an entry <= every earlier page's `frontier`; and `frontier` falls strictly from
///         page to page, rows or not. Refusals carry 0.
abstract contract TopicFrontierBase is TopicReadersBase {
    uint8 internal constant SCAN_ROWS = 4;

    /// One page as the checks see it: the page info and its rows' entries (newest first).
    struct Pg {
        TopicPageInfo info;
        uint64[] rows;
    }

    /// A chain's running state.
    struct Listing {
        uint64[] all; // the listing's entries in read order (newest first)
        uint256 scanned;
        uint256 pages;
        uint256 emptyPages;
        uint64[] frontiers;
        uint64[][] rowsByPage;
    }

    function _listing(uint64[] memory all) internal pure returns (Listing memory c) {
        c.all = all;
        c.frontiers = new uint64[](0);
        c.rowsByPage = new uint64[][](0);
    }

    /// Checks one PRESENT page against the laws and appends it to the chain.
    function _step(Listing memory c, Pg memory pg) internal pure {
        TopicPageInfo memory info = pg.info;
        assertEq(uint8(info.q.status), uint8(Status.PRESENT), "page status");
        c.scanned += info.scanned;
        assertLe(c.scanned, c.all.length, "scanned within the listing");
        uint64 want = c.scanned < c.all.length ? c.all[c.scanned] : 0;
        assertEq(info.frontier, want, "frontier = the next entry the listing reads");
        assertEq(info.frontier == 0, info.scanStatus == SCAN_EXHAUSTED, "0 exactly when EXHAUSTED");
        assertEq(info.frontier == 0, info.next.length == 0, "0 exactly when no continuation");
        for (uint256 i; i < pg.rows.length; ++i) {
            assertGt(pg.rows[i], info.frontier, "a row of the page is newer than the frontier");
        }
        if (c.pages != 0) {
            uint64 prev = c.frontiers[c.pages - 1];
            assertLt(info.frontier, prev, "the frontier falls strictly, rows or not");
        }
        // every row of this page is <= every earlier page's frontier
        for (uint256 b; b < c.pages; ++b) {
            for (uint256 i; i < pg.rows.length; ++i) {
                assertLe(pg.rows[i], c.frontiers[b], "a later row is <= an earlier frontier");
            }
        }
        if (pg.rows.length == 0) ++c.emptyPages;
        uint64[] memory fs = new uint64[](c.pages + 1);
        uint64[][] memory rs = new uint64[][](c.pages + 1);
        for (uint256 i; i < c.pages; ++i) {
            fs[i] = c.frontiers[i];
            rs[i] = c.rowsByPage[i];
        }
        fs[c.pages] = info.frontier;
        rs[c.pages] = pg.rows;
        c.frontiers = fs;
        c.rowsByPage = rs;
        ++c.pages;
    }

    /// A refusal: no rows, frontier 0.
    function _refused(TopicPageInfo memory info, Status want) internal pure {
        assertEq(uint8(info.q.status), uint8(want), "refusal status");
        assertEq(info.frontier, 0, "a refusal's frontier is 0");
    }

    /// `a` and `b` merged, newest first (each ascending as the index stores it).
    function _mergeDesc(uint64[] memory a, uint64[] memory b)
        internal
        pure
        returns (uint64[] memory e)
    {
        e = new uint64[](a.length + b.length);
        uint256 i = a.length;
        uint256 j = b.length;
        for (uint256 k; k < e.length; ++k) {
            if (j == 0 || (i != 0 && a[i - 1] > b[j - 1])) e[k] = a[--i];
            else e[k] = b[--j];
        }
    }

    function _desc(uint64[] memory a) internal pure returns (uint64[] memory) {
        return _mergeDesc(a, new uint64[](0));
    }

    /// An author's exact scope list at `place` (family 10, in the bitmap store), ascending.
    function _scopeList(address who, bytes32 place) internal view returns (uint64[] memory) {
        ScopeKey k = ScopeKey.wrap(Keys.scope(_pid(who), Purpose.TAG, place));
        (uint64 count,,,,,) = r.g.bitmap.scopeHead(k);
        return r.g.bitmap.scopeSlice(k, 0, uint16(count));
    }

    function _refList(uint8 slot, bytes32 value) internal view returns (uint64[] memory e) {
        Coverage c;
        (c, e,) = r.g.index
            .postingSliceOf(
                FamilyId.wrap(F_REFERENCE), TypeId.wrap(typeIds[T_TOPIC]), slot, value, 0, 512
            );
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
    }

    function _bad(bytes memory cont) internal pure returns (bytes memory out) {
        out = bytes.concat(cont, bytes1(0));
    }

    /// The continuation `cont` minted under another execution set (word 2).
    function _stale(bytes memory cont) internal pure returns (bytes memory out) {
        out = new bytes(cont.length);
        for (uint256 i; i < cont.length; ++i) {
            out[i] = cont[i];
        }
        assembly ("memory-safe") {
            mstore(add(out, 96), 1)
        }
    }
}

contract TopicFrontierTest is TopicFrontierBase {
    bytes32[] internal t; // /f-0 /f-0/f-1
    bytes32 internal c2; // /f-0/second

    function setUp() public override {
        super.setUp();
        t = _regPath("f", 2);
        c2 = _child(t[0], "second", true);
    }

    // ---- mine ----------------------------------------------------------------------------------------------

    function _minePg(
        bytes32[] memory lens,
        bool below,
        bytes memory cont,
        uint32 limit,
        uint32 maxRows
    ) internal view returns (Pg memory pg) {
        MineRow[] memory rows;
        (pg.info, rows) = miner.mine(lens, t[0], below, _unbound(), cont, limit, maxRows, 0);
        pg.rows = new uint64[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            pg.rows[i] = rows[i].bindingOrdinal;
        }
    }

    function _asc(uint64[] memory d) internal pure returns (uint64[] memory a) {
        a = new uint64[](d.length);
        for (uint256 i; i < d.length; ++i) {
            a[i] = d[d.length - 1 - i];
        }
    }

    /// The entries `mine(lens = [alice, bob], t[0], below)` reads: both authors' exact lists and roll-ups, merged
    /// newest first.
    function _mineList(bool below) internal view returns (uint64[] memory) {
        uint64[] memory e = _mergeDesc(_scopeList(alice, t[0]), _scopeList(bob, t[0]));
        if (!below) return e;
        e = _mergeDesc(_asc(e), _scopeBelow(alice, t[0]));
        return _mergeDesc(_asc(e), _scopeBelow(bob, t[0]));
    }

    /// Two authors' lists interleave at the place and below it; masked own entries pad the exact lists.
    function _mineFixture() internal {
        for (uint256 i; i < 14; ++i) {
            address who = i % 2 == 0 ? alice : bob;
            bytes32 at = i % 3 == 0 ? t[1] : i % 3 == 1 ? t[0] : c2;
            if (i % 5 == 4) _deny(who, at, things[i]);
            else _tag(who, at, things[i]);
        }
    }

    function _runMine(bool below, uint32 limit, uint32 maxRows)
        internal
        view
        returns (Listing memory c)
    {
        c = _listing(_mineList(below));
        bytes memory cont;
        bytes32[] memory lens = _lens2(alice, bob);
        while (true) {
            Pg memory pg = _minePg(lens, below, cont, limit, maxRows);
            _step(c, pg);
            if (pg.info.next.length == 0) break;
            cont = pg.info.next;
        }
        assertEq(c.scanned, c.all.length, "the chain reads every entry");
    }

    function test_mine_frontier_over_interleaved_lists() public {
        _mineFixture();
        Listing memory c = _runMine(true, 3, 0);
        assertGe(c.pages, 5);
        c = _runMine(false, 2, 0);
        assertGe(c.pages, 3);
        c = _runMine(true, 0, 0);
        assertEq(c.pages, 1, "one page reads everything");
        assertEq(c.frontiers[0], 0);
    }

    /// A ROWS stop with entries left in the fetched window: the frontier is the first one not processed.
    function test_mine_frontier_after_a_rows_stop_inside_a_window() public {
        _mineFixture();
        Listing memory c = _runMine(true, 0, 1);
        assertGe(c.pages, 5);
        // page 1 stopped at one row with the rest of a 16-entry window fetched: the frontier is the next entry
        Pg memory pg = _minePg(_lens2(alice, bob), true, "", 0, 1);
        assertEq(pg.info.scanStatus, SCAN_ROWS);
        assertEq(pg.rows.length, 1);
        assertEq(pg.info.frontier, c.all[pg.info.scanned]);
    }

    /// A padded stretch (masked own entries): pages with no rows still move the frontier down.
    function test_mine_frontier_moves_over_a_padded_stretch() public {
        bytes32[] memory xs = _things(24);
        _tag(alice, t[0], xs[0]);
        for (uint256 i = 1; i < 23; ++i) {
            _deny(alice, t[0], xs[i]);
        }
        _tag(alice, t[0], xs[23]);
        Listing memory c = _listing(_desc(_scopeList(alice, t[0])));
        bytes memory cont;
        while (true) {
            MineRow[] memory rows;
            Pg memory pg;
            (pg.info, rows) = miner.mine(_lens1(alice), t[0], false, _unbound(), cont, 4, 0, 0);
            pg.rows = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                pg.rows[i] = rows[i].bindingOrdinal;
            }
            _step(c, pg);
            if (pg.info.next.length == 0) break;
            cont = pg.info.next;
        }
        assertGe(c.emptyPages, 4, "pages with no rows");
        assertEq(c.scanned, 24);
    }

    function test_mine_frontier_ignores_appends_between_pages() public {
        _mineFixture();
        Listing memory c = _listing(_mineList(true));
        bytes32[] memory lens = _lens2(alice, bob);
        Pg memory pg = _minePg(lens, true, "", 3, 0);
        _step(c, pg);
        // newer than the origin: appended to every list, never read by this listing
        _tag(alice, t[0], things[15]);
        _tag(bob, t[1], things[15]);
        _tag(alice, c2, things[14]);
        while (pg.info.next.length != 0) {
            pg = _minePg(lens, true, pg.info.next, 3, 0);
            _step(c, pg);
        }
        assertEq(c.scanned, c.all.length);
    }

    /// A lens that names one principal twice reads that author's lists twice: the frontier can equal a row's entry
    /// (the page laws' stated exception; the guarantee is then <=).
    function test_mine_frontier_with_a_repeated_lens_principal_is_not_strict() public {
        _tag(alice, t[0], things[0]);
        _tag(alice, t[0], things[1]);
        (TopicPageInfo memory info, MineRow[] memory rows) =
            miner.mine(_lens2(alice, alice), t[0], false, _unbound(), "", 1, 0, 0);
        _ok(info);
        assertEq(rows.length, 1);
        assertEq(info.frontier, rows[0].bindingOrdinal, "the second copy of the same entry is next");
    }

    function test_mine_refusals_carry_no_frontier() public {
        _mineFixture();
        (TopicPageInfo memory info,) = _mine(new bytes32[](0), t[0], false, "", 0);
        _refused(info, Status.INVALID);
        (info,) = _mine(new bytes32[](65), t[0], false, "", 0);
        _refused(info, Status.LIMIT_EXCEEDED);
        (TopicPageInfo memory first,) = _mine(_lens2(alice, bob), t[0], true, "", 2);
        assertGt(first.frontier, 0);
        (info,) = _mine(_lens2(alice, bob), t[0], true, _bad(first.next), 2);
        _refused(info, Status.INVALID);
        (info,) = _mine(_lens2(alice, bob), t[0], true, _stale(first.next), 2);
        _refused(info, Status.BASIS_STALE);
        BasisCommit memory b = reads.basis(address(r.ledger));
        b.executionSet = keccak256("other");
        (info,) = miner.mine(_lens2(alice, bob), t[0], true, b, "", 2, 0, 0);
        _refused(info, Status.BASIS_STALE);
        // an empty listing is EXHAUSTED at once: frontier 0
        (info,) = _mine(_lens1(carol), t[0], true, "", 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        assertEq(info.frontier, 0);
    }

    // ---- everyone ------------------------------------------------------------------------------------------

    function _evPg(
        bool below,
        bytes32[] memory lens,
        bytes memory cont,
        uint32 limit,
        uint32 maxRows
    ) internal view returns (Pg memory pg) {
        PlaceRow[] memory rows;
        (pg.info, rows) = pager.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.TAG, t[0], below, false, 0),
            lens,
            _unbound(),
            cont,
            limit,
            maxRows,
            0
        );
        pg.rows = new uint64[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            pg.rows[i] = rows[i].bindingOrdinal;
        }
    }

    function _evList(bool below) internal view returns (uint64[] memory) {
        return _mergeDesc(_place(Purpose.TAG, t[0]), below ? _placeBelow(t[0]) : new uint64[](0));
    }

    /// The place list and the roll-up interleave; lone negatives and a lens denial pad them.
    function _evFixture() internal {
        for (uint256 i; i < 14; ++i) {
            address who = i % 3 == 0 ? alice : i % 3 == 1 ? bob : carol;
            bytes32 at = i % 2 == 0 ? t[0] : i % 4 == 1 ? t[1] : c2;
            if (i % 4 == 3) _deny(who, at, things[i]); // a lone negative: listed, shown to nobody
            else _tag(who, at, things[i]);
        }
        _deny(alice, t[0], things[2]); // a later first statement that files nothing
        _tag(bob, t[0], things[0]); // a later first yes: the position filed again
    }

    function _runEv(bool below, bytes32[] memory lens, uint32 limit, uint32 maxRows)
        internal
        view
        returns (Listing memory c)
    {
        c = _listing(_evList(below));
        bytes memory cont;
        while (true) {
            Pg memory pg = _evPg(below, lens, cont, limit, maxRows);
            _step(c, pg);
            if (pg.info.next.length == 0) break;
            cont = pg.info.next;
        }
        assertEq(c.scanned, c.all.length);
    }

    function test_everyone_frontier_over_interleaved_lists() public {
        _evFixture();
        Listing memory c = _runEv(true, _lens1(alice), 3, 0);
        assertGe(c.pages, 5);
        c = _runEv(false, new bytes32[](0), 2, 0);
        assertGe(c.pages, 3);
        c = _runEv(true, _lens2(bob, alice), 0, 0);
        assertEq(c.pages, 1);
    }

    /// A ROWS stop inside a fetched window of 16: the frontier is the first entry not consumed.
    function test_everyone_frontier_after_a_rows_stop_inside_a_window() public {
        _evFixture();
        Listing memory c = _runEv(true, _lens1(alice), 0, 1);
        assertGe(c.pages, 5);
        Pg memory pg = _evPg(true, _lens1(alice), "", 0, 1);
        assertEq(pg.info.scanStatus, SCAN_ROWS);
        assertLt(pg.info.scanned, c.all.length);
        assertEq(pg.info.frontier, c.all[pg.info.scanned]);
    }

    /// A padded stretch (positions nobody says yes to): pages with no rows still move the frontier down.
    function test_everyone_frontier_moves_over_a_padded_stretch() public {
        bytes32[] memory xs = _things(30);
        _tag(alice, t[0], xs[0]);
        for (uint256 i = 1; i < 29; ++i) {
            _deny(carol, i % 2 == 0 ? t[0] : t[1], xs[i]);
        }
        _tag(bob, t[1], xs[29]);
        Listing memory c = _listing(_evList(true));
        bytes memory cont;
        while (true) {
            Pg memory pg = _evPg(true, new bytes32[](0), cont, 4, 0);
            _step(c, pg);
            if (pg.info.next.length == 0) break;
            cont = pg.info.next;
        }
        assertGe(c.emptyPages, 6, "pages with no rows");
        assertEq(c.scanned, 30);
    }

    function test_everyone_frontier_ignores_appends_between_pages() public {
        _evFixture();
        Listing memory c = _listing(_evList(true));
        Pg memory pg = _evPg(true, _lens1(alice), "", 3, 0);
        _step(c, pg);
        _tag(carol, t[0], things[15]);
        _tag(carol, c2, things[14]);
        while (pg.info.next.length != 0) {
            pg = _evPg(true, _lens1(alice), pg.info.next, 3, 0);
            _step(c, pg);
        }
        assertEq(c.scanned, c.all.length);
    }

    function test_everyone_refusals_carry_no_frontier() public {
        _evFixture();
        TopicPageInfo memory info;
        (info,) = pager.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.FOLDER, t[0], true, false, 0),
            new bytes32[](0),
            _unbound(),
            "",
            0,
            0,
            0
        );
        _refused(info, Status.INVALID);
        (info,) = _everyone(t[0], true, new bytes32[](65), false, 0, "", 0);
        _refused(info, Status.LIMIT_EXCEEDED);
        (TopicPageInfo memory first,) = _everyone(t[0], true, _lens1(alice), false, 0, "", 2);
        assertGt(first.frontier, 0);
        (info,) = _everyone(t[0], true, _lens1(alice), false, 0, _bad(first.next), 2);
        _refused(info, Status.INVALID);
        (info,) = _everyone(t[0], true, _lens1(alice), false, 0, _stale(first.next), 2);
        _refused(info, Status.BASIS_STALE);
        // an empty place: EXHAUSTED at once, frontier 0
        (info,) = _everyone(c2, false, _lens1(alice), false, 0, "", 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        assertEq(info.frontier, 0);
    }

    // ---- lookups: byName, about, wordPage, children -----------------------------------------------------------

    function test_by_name_frontier() public {
        address[] memory a = _authorsN("fb", 9);
        for (uint256 i; i < 9; ++i) {
            if (i % 3 == 2) _deny(a[i], t[0], things[0]);
            else _tag(a[i], t[0], things[0]);
        }
        bytes32 pos = Keys.position(Purpose.TAG, t[0], things[0]);
        Listing memory c = _listing(_desc(_authors(Purpose.TAG, t[0], things[0])));
        bytes memory cont;
        bool appended;
        while (true) {
            (TopicPageInfo memory info, AuthorRow[] memory rows) =
                lookup.byName(pos, _unbound(), cont, 2);
            Pg memory pg;
            pg.info = info;
            pg.rows = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                pg.rows[i] = rows[i].firstAdmission;
            }
            _step(c, pg);
            if (!appended) {
                _tag(bob, t[0], things[0]); // a newer author between pages: not part of this listing
                appended = true;
            }
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(c.pages, 5);
        (TopicPageInfo memory bad,) = lookup.byName(pos, _unbound(), _bad(cont), 2);
        _refused(bad, Status.INVALID);
        BasisCommit memory b = reads.basis(address(r.ledger));
        b.executionSet = keccak256("other");
        (bad,) = lookup.byName(pos, b, "", 2);
        _refused(bad, Status.BASIS_STALE);
    }

    function test_about_frontier() public {
        bytes32[] memory topics = new bytes32[](7);
        for (uint256 i; i < 7; ++i) {
            topics[i] = _child(t[0], bytes(string.concat("ab", vm.toString(i))), true);
            if (i % 2 == 1) _deny(alice, topics[i], things[5]);
            else _tag(bob, topics[i], things[5]);
        }
        Listing memory c = _listing(_desc(_rolePlaces(Purpose.TAG, things[5])));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, PlaceRow[] memory rows) =
                lookup.about(things[5], 0, _unbound(), cont, 2);
            Pg memory pg;
            pg.info = info;
            pg.rows = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                pg.rows[i] = rows[i].bindingOrdinal;
            }
            _step(c, pg);
            if (c.pages == 1) _tag(carol, t[1], things[5]); // appended between pages
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(c.pages, 4);
    }

    function test_children_frontier() public {
        for (uint256 i; i < 7; ++i) {
            _child(t[1], bytes(string.concat("ch", vm.toString(i))), true);
        }
        Listing memory c = _listing(_desc(_refList(0, t[1])));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, PlaceCount[] memory rows) =
                lookup.children(t[1], _unbound(), cont, 3);
            Pg memory pg;
            pg.info = info;
            pg.rows = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                pg.rows[i] = rows[i].admission;
            }
            _step(c, pg);
            if (c.pages == 1) _child(t[1], "late", true); // appended between pages
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(c.pages, 3);
        (TopicPageInfo memory bad,) = lookup.children(keccak256("nothing"), _unbound(), "", 0);
        _refused(bad, Status.ABSENT_PROVEN);
    }

    /// The word page: the root row of the first page is no list entry (older than every entry) and is left out of
    /// the row law; a first page of only the root row reads no entry, and its frontier is the list's newest.
    function test_word_page_frontier() public {
        bytes32 page = EfsTopics.wordPageId(typeIds[T_TOPIC_WORD], "w");
        for (uint256 i; i < 10; ++i) {
            bytes32 parent = _regPath(string.concat("wp", vm.toString(i)), 1)[0];
            _child(parent, "w", i == 0);
        }
        uint64[] memory all = _desc(_refList(1, page));
        for (uint16 limit = 1; limit <= 4; ++limit) {
            Listing memory c = _listing(all);
            bytes memory cont;
            while (true) {
                (TopicPageInfo memory info, PlaceCount[] memory rows) =
                    lookup.wordPage(page, _unbound(), cont, limit);
                bool root = cont.length == 0;
                Pg memory pg;
                pg.info = info;
                pg.rows = new uint64[](root ? rows.length - 1 : rows.length);
                for (uint256 i; i < pg.rows.length; ++i) {
                    pg.rows[i] = rows[root ? i + 1 : i].admission;
                }
                if (root) {
                    assertEq(rows[0].place, page);
                    assertLt(
                        rows[0].admission,
                        all[all.length - 1],
                        "the root row is older than every entry"
                    );
                }
                _step(c, pg);
                if (info.next.length == 0) break;
                cont = info.next;
            }
            assertEq(c.scanned, 10);
        }
        (TopicPageInfo memory bad,) = lookup.wordPage(t[1], _unbound(), "", 0);
        _refused(bad, Status.INVALID);
    }
}

/// @notice Without topic roll-ups: the UNKNOWN pages carry no frontier.
contract TopicFrontierWithoutTopicListsTest is TopicFrontierBase {
    function setUp() public override {
        withoutTopicLists = true;
        super.setUp();
    }

    function test_unknown_pages_carry_no_frontier() public {
        bytes32[] memory t = _regPath("u", 2);
        _tag(alice, t[1], things[0]);
        _tag(alice, t[0], things[1]);
        (TopicPageInfo memory info,) = _mine(_lens1(alice), t[0], true, "", 0);
        _refused(info, Status.UNKNOWN);
        (info,) = _everyone(t[0], true, _lens1(alice), false, 0, "", 0);
        _refused(info, Status.UNKNOWN);
        (info,) = lookup.children(t[0], _unbound(), "", 0);
        _refused(info, Status.UNKNOWN);
        // the exact views are served
        (info,) = _mine(_lens1(alice), t[0], false, "", 0);
        _ok(info);
        assertEq(info.frontier, 0);
    }
}

/// @notice Full pages and the entry-read counts: every lookup view's full page (64 rows) with entries left gives the
///         right `frontier`, and every reader path, read through `CountCapReads` in front of the index and the bitmap
///         store, asks for no more entries per read than the Realm's `limits.maxReadCount` (the documented maximum
///         of `IIndexReads.postingSliceOf`). The tighter caps pin what each path asks for at most: the `mine` and
///         `everyone` windows 16, a row's sample 64, a lookup page its rows plus the one look-ahead entry (65 on a
///         full page with entries left).
contract TopicSliceCapTest is TopicFrontierBase {
    uint256 internal constant N = 70;
    bytes32[] internal t; // /sc-0 /sc-0/sc-1
    bytes32 internal x; // tagged by N authors at t[0]: byName, sample
    bytes32 internal y; // tagged by alice under N children of t[1]: about, children, mine and everyone below
    bytes32 internal page; // the word page `w`, the last word of N paths

    function setUp() public override {
        super.setUp();
        t = _regPath("sc", 2);
        x = things[0];
        y = things[1];
        address[] memory a = _authorsN("sc", N);
        for (uint256 i; i < N; ++i) {
            _tag(a[i], t[0], x);
            bytes32 c = _child(t[1], bytes(string.concat("sc", vm.toString(i))), true);
            _tag(alice, c, y);
        }
        page = EfsTopics.wordPageId(typeIds[T_TOPIC_WORD], "w");
        for (uint256 i; i < N; ++i) {
            _child(_regPath(string.concat("scw", vm.toString(i)), 1)[0], "w", i == 0);
        }
    }

    /// Readers whose index and bitmap store refuse any entry read above `cap`.
    function _capped(uint256 cap)
        internal
        returns (TopicMineReader m, TopicEveryoneReader e, TopicLookupReader k)
    {
        CountCapReads bs = new CountCapReads(address(r.g.bitmap), cap, address(0));
        CountCapReads ix = new CountCapReads(address(r.g.index), cap, address(bs));
        FaultyReads fl = new FaultyReads(address(r.ledger));
        fl.setFault(
            ILedgerHot.index.selector,
            FaultyReads.Fault(fl.SET_WORD(), 0, false, bytes32(0), uint160(address(ix)))
        );
        m = new TopicMineReader(address(fl), address(views), address(reads));
        e = new TopicEveryoneReader(address(fl), address(views), address(reads));
        k = new TopicLookupReader(
            address(fl), address(views), address(reads), typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]
        );
    }

    function _pg(TopicPageInfo memory info, uint64[] memory rows)
        internal
        pure
        returns (Pg memory pg)
    {
        pg.info = info;
        pg.rows = rows;
    }

    function _byNameChain(TopicLookupReader k, uint16 limit)
        internal
        view
        returns (Listing memory c)
    {
        bytes32 pos = Keys.position(Purpose.TAG, t[0], x);
        c = _listing(_desc(_authors(Purpose.TAG, t[0], x)));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, AuthorRow[] memory rows) =
                k.byName(pos, _unbound(), cont, limit);
            uint64[] memory e = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                e[i] = rows[i].firstAdmission;
            }
            _step(c, _pg(info, e));
            if (info.next.length == 0) break;
            cont = info.next;
        }
    }

    function _aboutChain(TopicLookupReader k, uint16 limit, uint16 sample)
        internal
        view
        returns (Listing memory c)
    {
        c = _listing(_desc(_rolePlaces(Purpose.TAG, y)));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, PlaceRow[] memory rows) =
                k.about(y, sample, _unbound(), cont, limit);
            uint64[] memory e = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                e[i] = rows[i].bindingOrdinal;
            }
            _step(c, _pg(info, e));
            if (info.next.length == 0) break;
            cont = info.next;
        }
    }

    function _dirChain(TopicLookupReader k, bool word, uint16 limit)
        internal
        view
        returns (Listing memory c)
    {
        bytes32 id = word ? page : t[1];
        c = _listing(_desc(_refList(word ? 1 : 0, id)));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, PlaceCount[] memory rows) = word
                ? k.wordPage(id, _unbound(), cont, limit)
                : k.children(id, _unbound(), cont, limit);
            uint256 skip = word && cont.length == 0 ? 1 : 0; // the word page's root row is no list entry
            uint64[] memory e = new uint64[](rows.length - skip);
            for (uint256 i; i < e.length; ++i) {
                e[i] = rows[i + skip].admission;
            }
            _step(c, _pg(info, e));
            if (info.next.length == 0) break;
            cont = info.next;
        }
    }

    function _mineChain(TopicMineReader m) internal view returns (Listing memory c) {
        c = _listing(_mergeDesc(_scopeList(alice, t[0]), _scopeBelow(alice, t[0])));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, MineRow[] memory rows) =
                m.mine(_lens1(alice), t[0], true, _unbound(), cont, 0, 0, 0);
            uint64[] memory e = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                e[i] = rows[i].bindingOrdinal;
            }
            _step(c, _pg(info, e));
            if (info.next.length == 0) break;
            cont = info.next;
        }
    }

    function _everyoneChain(TopicEveryoneReader ev, uint16 sample)
        internal
        view
        returns (Listing memory c)
    {
        c = _listing(_mergeDesc(_place(Purpose.TAG, t[0]), _placeBelow(t[0])));
        bytes memory cont;
        while (true) {
            (TopicPageInfo memory info, PlaceRow[] memory rows) = ev.everyone(
                ITopicEveryoneReader.PlaceQuery(Purpose.TAG, t[0], true, true, sample),
                new bytes32[](0),
                _unbound(),
                cont,
                0,
                0,
                0
            );
            uint64[] memory e = new uint64[](rows.length);
            for (uint256 i; i < rows.length; ++i) {
                e[i] = rows[i].bindingOrdinal;
            }
            _step(c, _pg(info, e));
            if (info.next.length == 0) break;
            cont = info.next;
        }
    }

    /// A full page (64 rows) of every lookup view, with entries left: the frontier is the 65th entry.
    function test_full_lookup_pages_have_the_right_frontier() public view {
        Listing memory c = _byNameChain(lookup, 64);
        assertEq(c.pages, 2);
        assertEq(c.frontiers[0], c.all[64], "byName: the 65th entry");
        c = _aboutChain(lookup, 64, 0);
        assertEq(c.pages, 2);
        assertEq(c.frontiers[0], c.all[64], "about: the 65th entry");
        c = _dirChain(lookup, false, 64);
        assertEq(c.pages, 2);
        assertEq(c.frontiers[0], c.all[64], "children: the 65th entry");
        c = _dirChain(lookup, true, 64); // 63 entries and the root row, then 64
        assertEq(c.pages, 2);
        assertEq(c.frontiers[0], c.all[63], "wordPage: the 64th entry after the root row");
        assertGe(N, 66);
    }

    /// Through readers whose index and store refuse a read above the Realm's `maxReadCount`, every view's full
    /// listing reads as it does directly.
    function test_no_reader_path_asks_for_more_than_max_read_count() public {
        uint256 cap = reads.describe(address(r.ledger)).limits.maxReadCount;
        assertEq(cap, 256, "the release profile's maxReadCount");
        (TopicMineReader m, TopicEveryoneReader e, TopicLookupReader k) = _capped(cap);
        _mineChain(m);
        _everyoneChain(e, 64);
        _byNameChain(k, 64);
        _byNameChain(k, 0);
        _aboutChain(k, 64, 64);
        _dirChain(k, false, 64);
        _dirChain(k, true, 64);
    }

    /// What each path asks for at most: the windows 16, a sample 64, a lookup page its rows plus one.
    function test_what_each_path_asks_for_at_most() public {
        (TopicMineReader m, TopicEveryoneReader e, TopicLookupReader k) = _capped(16);
        _mineChain(m);
        _everyoneChain(e, 0);
        _byNameChain(k, 15); // 15 rows and the look-ahead entry
        (, e, k) = _capped(64);
        _everyoneChain(e, 64);
        _byNameChain(k, 63);
        _aboutChain(k, 63, 64);
        _dirChain(k, false, 63);
        _dirChain(k, true, 64); // 63 entries and the look-ahead, then 64 with entries left: below
        // a full page with entries left asks for its 64 rows and the look-ahead entry in one slice: 65
        bytes32 pos = Keys.position(Purpose.TAG, t[0], x);
        vm.expectPartialRevert(E_TOPIC_READ.selector);
        this.byName64(k, pos);
        (,, k) = _capped(65);
        _byNameChain(k, 64);
        _aboutChain(k, 64, 0);
        _dirChain(k, false, 64);
        _dirChain(k, true, 64);
    }

    function byName64(TopicLookupReader k, bytes32 pos) external view {
        k.byName(pos, _unbound(), "", 64);
    }
}
