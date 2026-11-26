// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {TopicMineReader} from "../../src/readers/TopicMineReader.sol";
import {TopicEveryoneReader} from "../../src/readers/TopicEveryoneReader.sol";
import {TopicLookupReader} from "../../src/readers/TopicLookupReader.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {Coverage, Qualified, Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicEveryoneReader,
    MineRow,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";

/// @notice Docs INDEX-BUILD step 3b, §8's reader test for partial coverage, under the list-coverage rule of the page
///         laws (`src/interfaces/Readers.sol`, above `TopicPageInfo`): a topic reader answers from a list only when
///         the index reports it COMPLETE, and a list reported PARTIAL is treated exactly as one reported UNKNOWN. A
///         real live index is always COMPLETE (the readers ask only `ledger.index()`, and a building generation is
///         never it), so the index is wrapped in `FaultyReads` and made to report one family at a time as UNKNOWN or
///         as PARTIAL, on every read that names the family (`coverage`, `postingHeadOf`, `postingSliceOf`), for every
///         view of the three topic readers.
///
///         What the readers promise: a needed list that is not COMPLETE refuses the view as data: status UNKNOWN, no
///         rows, coverage UNKNOWN, no counts (`rawTotal`, `positionsEver`, `scanned`, `selectedSoFar`, a count view's
///         two counts all 0), `frontier` 0, `scanStatus` 0 and no continuation; PARTIAL gives exactly the answer
///         UNKNOWN gives. The page's own `listingCoverage` PARTIAL (a page that is not origin-started and finished)
///         is unchanged. The matrix of which families each view needs is pinned and logged.
contract TopicPartialCoverageTest is TopicReadersBase {
    uint8 internal constant VIEWS = 13;
    uint8 internal constant M_SET_WORD = 4;
    uint8 internal constant M_UNDECLARED = 11;
    uint8 internal constant V_ABOUT = 5;
    uint8 internal constant V_EVERYONE_EXACT = 2;
    uint8 internal constant FAM_POSITION_AUTHORS = 3;
    uint8 internal constant V_MINE_BELOW = 1;
    uint8 internal constant V_EVERYONE_BELOW = 3;
    uint8 internal constant V_BY_NAME = 4;

    FaultyReads internal fl;
    FaultyReads internal fi;
    TopicMineReader internal fp;
    TopicEveryoneReader internal fe;
    TopicLookupReader internal fk;
    bytes32[] internal t;
    bytes32 internal pos;
    bytes32[7] internal fams;
    string[7] internal famNames;

    struct Outcome {
        bool reverted;
        uint8 status;
        uint8 coverage;
        uint256 rows;
        bool complete;
        bytes32 hash;
        uint8 scanStatus;
        uint64 frontier;
        uint256 nextLength;
        uint64 rawTotal;
        uint64 positionsEver;
        uint64 scanned;
        uint64 selected;
    }

    function setUp() public override {
        super.setUp();
        t = _regPath("partial", 2);
        _child(t[0], "partial-kid", true);
        _tag(alice, t[0], things[0]);
        _tag(alice, t[1], things[1]);
        _deny(alice, t[0], things[2]);
        _tag(bob, t[0], things[0]);
        _deny(carol, t[0], things[0]);
        _deny(bob, t[1], things[3]); // a lone negative below
        pos = Keys.position(Purpose.TAG, t[0], things[0]);
        fl = new FaultyReads(address(r.ledger));
        fi = new FaultyReads(address(r.g.index));
        fi.setBasis(address(r.ledger));
        fl.setFault(
            ILedgerHot.index.selector,
            FaultyReads.Fault(M_SET_WORD, 0, false, bytes32(0), uint160(address(fi)))
        );
        fp = new TopicMineReader(address(fl), address(views), address(reads));
        fe = new TopicEveryoneReader(address(fl), address(views), address(reads));
        fk = new TopicLookupReader(
            address(fl), address(views), address(reads), typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]
        );
        fams = [
            F_PLACE,
            F_PLACE_BELOW,
            F_SCOPE_BELOW,
            F_POSITION_AUTHORS,
            F_ROLE_PLACES,
            Keys.familyId("reference-position"),
            Keys.familyId("live-scope")
        ];
        famNames = [
            "place",
            "place-below",
            "scope-below",
            "position-authors",
            "role-places",
            "reference-position",
            "live-scope"
        ];
    }

    function _viewName(uint8 v) internal pure returns (string memory) {
        string[13] memory n = [
            "mine exact",
            "mine below",
            "everyone exact",
            "everyone below",
            "byName",
            "about",
            "placeCount exact",
            "placeCount below",
            "authorCount",
            "entryCount exact",
            "entryCount below",
            "wordPage",
            "children"
        ];
        return n[v];
    }

    /// The families (bit j = `fams[j]`) each view needs: the lists whose coverage changes its answer. Bits: 1 place,
    /// 2 place-below, 4 scope-below, 8 position-authors, 16 role-places, 32 reference-position, 64 live-scope. The
    /// viewed-place shortcut of `mine` below reads `position-authors` only to save reads (at COMPLETE), so its
    /// coverage never changes an answer there.
    function _needs(uint8 v) internal pure returns (uint256) {
        uint8[13] memory m = [64, 68, 9, 11, 8, 24, 1, 2, 8, 64, 4, 35, 35];
        return m[v];
    }

    function _isPaged(uint8 v) internal pure returns (bool) {
        return v <= 5 || v >= 11;
    }

    function _page(TopicPageInfo memory i, uint256 rows, bytes memory enc)
        internal
        pure
        returns (Outcome memory o)
    {
        o.status = uint8(i.q.status);
        o.coverage = uint8(i.listingCoverage);
        o.rows = rows;
        o.complete = i.completeFromOrigin;
        o.hash = keccak256(enc);
        o.scanStatus = i.scanStatus;
        o.frontier = i.frontier;
        o.nextLength = i.next.length;
        o.rawTotal = i.rawTotal;
        o.positionsEver = i.positionsEver;
        o.scanned = i.scanned;
        o.selected = i.selectedSoFar;
    }

    function _count(Qualified memory q, Coverage c, uint64 a, uint64 b)
        internal
        pure
        returns (Outcome memory o)
    {
        o.status = uint8(q.status);
        o.coverage = uint8(c);
        o.rows = a + b;
        o.complete = c == Coverage.COMPLETE;
        o.hash = keccak256(abi.encode(a, b));
    }

    /// View `v` through the wrapped index from `cont` with `limit` (0 = no bound), as an outcome and its `next`.
    function probe(uint8 v, bytes memory cont, uint16 limit)
        external
        view
        returns (Outcome memory, bytes memory)
    {
        bytes32[] memory lens = _lens2(alice, bob);
        if (v <= 1) {
            (TopicPageInfo memory i, MineRow[] memory x) =
                fp.mine(lens, t[0], v == 1, _unbound(), cont, limit, 0, 0);
            return (_page(i, x.length, abi.encode(x)), i.next);
        }
        if (v <= 3) {
            (TopicPageInfo memory i, PlaceRow[] memory x) = fe.everyone(
                ITopicEveryoneReader.PlaceQuery(Purpose.TAG, t[0], v == 3, false, 4),
                lens,
                _unbound(),
                cont,
                limit,
                0,
                0
            );
            return (_page(i, x.length, abi.encode(x)), i.next);
        }
        if (v == 4) {
            (TopicPageInfo memory i, AuthorRow[] memory x) = fk.byName(pos, _unbound(), cont, limit);
            return (_page(i, x.length, abi.encode(x)), i.next);
        }
        if (v == 5) {
            (TopicPageInfo memory i, PlaceRow[] memory x) =
                fk.about(things[0], 4, _unbound(), cont, limit);
            return (_page(i, x.length, abi.encode(x)), i.next);
        }
        if (v <= 7) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) =
                fk.placeCount(Purpose.TAG, t[0], v == 7, _unbound());
            return (_count(q, c, a, b), "");
        }
        if (v == 8) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) = fk.authorCount(pos, _unbound());
            return (_count(q, c, a, b), "");
        }
        if (v <= 10) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) =
                fk.entryCount(_pid(alice), Purpose.TAG, t[0], v == 10, _unbound());
            return (_count(q, c, a, b), "");
        }
        TopicPageInfo memory info;
        PlaceCount[] memory pc;
        if (v == 11) (info, pc) = fk.wordPage(t[0], _unbound(), cont, limit);
        else (info, pc) = fk.children(t[0], _unbound(), cont, limit);
        return (_page(info, pc.length, abi.encode(pc)), info.next);
    }

    function _run(uint8 v) internal view returns (Outcome memory o) {
        (o,) = _runAt(v, "", 0);
    }

    function _runAt(uint8 v, bytes memory cont, uint16 limit)
        internal
        view
        returns (Outcome memory o, bytes memory next)
    {
        try this.probe(v, cont, limit) returns (Outcome memory got, bytes memory n) {
            (o, next) = (got, n);
        } catch {
            o.reverted = true;
        }
    }

    function _arm(bytes32 family, Coverage c) internal {
        FaultyReads.Fault memory f = FaultyReads.Fault(M_SET_WORD, 0, true, family, uint8(c));
        fi.setFault(IIndexReads.coverage.selector, f);
        fi.setFault(IIndexReads.postingHeadOf.selector, f);
        fi.setFault(IIndexReads.postingSliceOf.selector, f);
    }

    /// The reply shape of a family the index does not declare (`FaultyReads.UNDECLARED`, mirroring `IndexReads`):
    /// coverage UNKNOWN with zero counts and an empty slice, not a faithful head relabelled.
    function _armUndeclared(bytes32 family) internal {
        FaultyReads.Fault memory f = FaultyReads.Fault(M_UNDECLARED, 0, true, family, 0);
        fi.setFault(IIndexReads.coverage.selector, f);
        fi.setFault(IIndexReads.postingHeadOf.selector, f);
        fi.setFault(IIndexReads.postingSliceOf.selector, f);
    }

    function _disarm() internal {
        fi.clear(IIndexReads.coverage.selector);
        fi.clear(IIndexReads.postingHeadOf.selector);
        fi.clear(IIndexReads.postingSliceOf.selector);
    }

    function _same(Outcome memory a, Outcome memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// A refusal as data: status UNKNOWN, no rows, coverage UNKNOWN, no counts, no frontier, no continuation.
    function _refused(Outcome memory o, string memory what) internal pure {
        assertFalse(o.reverted, string.concat(what, ": data, never a revert"));
        assertEq(o.status, uint8(Status.UNKNOWN), string.concat(what, ": UNKNOWN"));
        assertEq(o.coverage, uint8(Coverage.UNKNOWN), string.concat(what, ": coverage UNKNOWN"));
        assertEq(o.rows, 0, string.concat(what, ": no rows (no counts)"));
        assertFalse(o.complete, string.concat(what, ": never complete"));
        assertEq(o.scanStatus, 0, string.concat(what, ": no scan status"));
        assertEq(o.frontier, 0, string.concat(what, ": frontier 0"));
        assertEq(o.nextLength, 0, string.concat(what, ": no continuation"));
        assertEq(o.rawTotal, 0, string.concat(what, ": no rawTotal"));
        assertEq(o.positionsEver, 0, string.concat(what, ": no positionsEver"));
        assertEq(o.scanned, 0, string.concat(what, ": nothing scanned"));
        assertEq(o.selected, 0, string.concat(what, ": nothing selected"));
    }

    function _word(Outcome memory o) internal pure returns (string memory) {
        if (o.reverted) return "REVERT";
        string[4] memory s = ["UNSET", "UNKNOWN", "PARTIAL", "COMPLETE"];
        string[3] memory st = ["UNSET", "UNKNOWN", "PRESENT"];
        return string.concat(
            o.status < 3 ? st[o.status] : vm.toString(o.status),
            "/",
            s[o.coverage],
            " rows ",
            vm.toString(o.rows),
            o.complete ? " complete" : ""
        );
    }

    /// Every view against every family: a needed family at UNKNOWN or at PARTIAL refuses the view, with the same
    /// answer both times; a family the view does not need changes nothing. The needed families are pinned
    /// (`_needs`).
    function test_every_view_refuses_a_needed_list_at_unknown_or_partial() public {
        for (uint8 v; v < VIEWS; ++v) {
            Outcome memory base = _run(v);
            assertFalse(base.reverted, string.concat(_viewName(v), ": faithful read"));
            assertEq(base.status, uint8(Status.PRESENT), string.concat(_viewName(v), ": base"));
            assertEq(base.coverage, uint8(Coverage.COMPLETE), string.concat(_viewName(v), ": base"));
            uint256 needed;
            for (uint256 j; j < fams.length; ++j) {
                string memory what = string.concat(_viewName(v), " / ", famNames[j]);
                _arm(fams[j], Coverage.UNKNOWN);
                Outcome memory u = _run(v);
                _arm(fams[j], Coverage.PARTIAL);
                Outcome memory q = _run(v);
                _disarm();
                bool usesU = !_same(u, base);
                bool usesP = !_same(q, base);
                assertEq(
                    usesU, usesP, string.concat(what, ": PARTIAL matters exactly when UNKNOWN does")
                );
                if (!usesU) continue;
                needed |= 1 << j;
                emit log_named_string(
                    what, string.concat("UNKNOWN -> ", _word(u), "; PARTIAL -> ", _word(q))
                );
                _refused(u, string.concat(what, " at UNKNOWN"));
                _refused(q, string.concat(what, " at PARTIAL"));
                assertTrue(_same(u, q), string.concat(what, ": PARTIAL answers as UNKNOWN does"));
            }
            assertEq(needed, _needs(v), string.concat(_viewName(v), ": the families it needs"));
        }
    }

    /// The whole needs matrix again, in the reply shape a real undeclared family has (`IndexReads`: head
    /// `(UNKNOWN, 0, 0, 0, false)`, an empty slice, coverage `(UNKNOWN, 0, 0, phase)`): every view against every list
    /// it needs refuses as data (status UNKNOWN, no rows, no counts, `frontier` 0, no continuation), never a revert,
    /// and answers exactly as the relabelled UNKNOWN does; a list it does not need changes nothing.
    function test_every_view_refuses_a_needed_list_the_index_does_not_declare() public {
        for (uint8 v; v < VIEWS; ++v) {
            Outcome memory base = _run(v);
            assertFalse(base.reverted, string.concat(_viewName(v), ": faithful read"));
            uint256 needed;
            for (uint256 j; j < fams.length; ++j) {
                string memory what = string.concat(_viewName(v), " / ", famNames[j], " undeclared");
                _armUndeclared(fams[j]);
                Outcome memory d = _run(v);
                _arm(fams[j], Coverage.UNKNOWN);
                Outcome memory u = _run(v);
                _disarm();
                emit log_named_string(what, _word(d));
                if (_same(d, base)) continue;
                needed |= 1 << j;
                _refused(d, what);
                assertTrue(_same(d, u), string.concat(what, ": answers as UNKNOWN does"));
            }
            assertEq(needed, _needs(v), string.concat(_viewName(v), ": the families it needs"));
        }
    }

    /// By name: `position-authors` undeclared under `about` (the case that reverted while `about` checked the count
    /// before the coverage) and under `everyone`, exact and below.
    function test_position_authors_undeclared_under_about_and_everyone_refuses() public {
        uint8[3] memory vs = [V_ABOUT, V_EVERYONE_EXACT, V_EVERYONE_BELOW];
        for (uint256 i; i < vs.length; ++i) {
            _armUndeclared(fams[FAM_POSITION_AUTHORS]);
            Outcome memory d = _run(vs[i]);
            _disarm();
            _refused(d, string.concat(_viewName(vs[i]), " / position-authors undeclared"));
        }
    }

    /// The two families of `mine` below that come through different reads (live-scope through `coverage`,
    /// scope-below through `postingHeadOf`) set to different coverages: any needed list not COMPLETE refuses, and
    /// every mix answers as UNKNOWN alone does.
    function test_one_list_partial_and_another_unknown_or_complete_refuses() public {
        Outcome memory want = _unknownAlone();
        bytes32 liveScope = Keys.familyId("live-scope");
        uint8[3] memory other =
            [uint8(Coverage.UNKNOWN), uint8(Coverage.PARTIAL), uint8(Coverage.COMPLETE)];
        for (uint256 k; k < 3; ++k) {
            // scope-below PARTIAL, live-scope UNKNOWN / PARTIAL / COMPLETE
            fi.setFault(
                IIndexReads.postingHeadOf.selector,
                FaultyReads.Fault(M_SET_WORD, 0, true, F_SCOPE_BELOW, uint8(Coverage.PARTIAL))
            );
            fi.setFault(
                IIndexReads.coverage.selector,
                FaultyReads.Fault(M_SET_WORD, 0, true, liveScope, other[k])
            );
            Outcome memory o = _run(V_MINE_BELOW);
            _refused(o, "scope-below PARTIAL");
            assertTrue(_same(o, want), "a mix answers as UNKNOWN does");
            // live-scope PARTIAL, scope-below UNKNOWN / PARTIAL / COMPLETE
            fi.setFault(
                IIndexReads.postingHeadOf.selector,
                FaultyReads.Fault(M_SET_WORD, 0, true, F_SCOPE_BELOW, other[k])
            );
            fi.setFault(
                IIndexReads.coverage.selector,
                FaultyReads.Fault(M_SET_WORD, 0, true, liveScope, uint8(Coverage.PARTIAL))
            );
            o = _run(V_MINE_BELOW);
            _refused(o, "live-scope PARTIAL");
            assertTrue(_same(o, want), "a mix answers as UNKNOWN does");
            _disarm();
        }
    }

    function _unknownAlone() internal returns (Outcome memory o) {
        _arm(F_SCOPE_BELOW, Coverage.UNKNOWN);
        o = _run(V_MINE_BELOW);
        _disarm();
        _refused(o, "scope-below UNKNOWN");
    }

    /// A listing over more than one page: started with every list COMPLETE, then a needed list turns PARTIAL (or
    /// UNKNOWN) and the resumed page refuses, with no rows; back at COMPLETE the same continuation is served. The
    /// reverse: a fresh listing at PARTIAL refuses, and once COMPLETE a fresh listing is the faithful one. Every paged
    /// view, against every family it needs.
    function test_a_needed_list_turning_partial_between_pages_refuses_the_resumed_page() public {
        _tag(alice, t[1], things[0]); // `about` has two places
        _child(t[1], "partial-0", false); // `wordPage` has a list entry besides its root row
        for (uint8 v; v < VIEWS; ++v) {
            if (!_isPaged(v)) continue;
            (Outcome memory first, bytes memory next) = _runAt(v, "", 1);
            assertEq(first.status, uint8(Status.PRESENT), _viewName(v));
            assertGt(next.length, 0, string.concat(_viewName(v), ": more than one page"));
            Outcome memory base = _run(v);
            (Outcome memory resumed,) = _runAt(v, next, 1);
            assertEq(resumed.status, uint8(Status.PRESENT), _viewName(v));
            for (uint256 j; j < fams.length; ++j) {
                if ((_needs(v) >> j) & 1 == 0) continue;
                string memory what = string.concat(_viewName(v), " / ", famNames[j]);
                _arm(fams[j], Coverage.PARTIAL);
                (Outcome memory p, bytes memory pn) = _runAt(v, next, 1);
                _refused(p, string.concat(what, ": resumed at PARTIAL"));
                assertEq(pn.length, 0);
                (Outcome memory fresh,) = _runAt(v, "", 0);
                _refused(fresh, string.concat(what, ": fresh at PARTIAL"));
                _arm(fams[j], Coverage.UNKNOWN);
                (Outcome memory u,) = _runAt(v, next, 1);
                assertTrue(_same(p, u), string.concat(what, ": resumed PARTIAL answers as UNKNOWN"));
                _disarm();
                (Outcome memory again,) = _runAt(v, next, 1);
                assertTrue(
                    _same(again, resumed),
                    string.concat(what, ": COMPLETE again, the page is served")
                );
                assertTrue(
                    _same(_run(v), base), string.concat(what, ": a fresh listing is faithful")
                );
            }
        }
    }

    /// An empty list at PARTIAL is UNKNOWN, never an empty PRESENT page: a topic nobody tagged and a position nobody
    /// stated anything at, through every view that reads only that list.
    function test_an_empty_list_at_partial_is_unknown_never_an_empty_page() public {
        bytes32 empty = _regPath("partial-empty", 1)[0];
        bytes32 nobody = Keys.position(Purpose.TAG, empty, things[0]);
        bytes32[] memory lens = _lens2(alice, bob);
        // COMPLETE: an empty, finished, complete page
        (TopicPageInfo memory i, MineRow[] memory x) =
            fp.mine(lens, empty, false, _unbound(), "", 0, 0, 0);
        assertEq(
            abi.encode(uint8(i.q.status), uint8(i.listingCoverage), x.length), abi.encode(2, 3, 0)
        );
        for (uint256 c = uint8(Coverage.UNKNOWN); c <= uint8(Coverage.PARTIAL); ++c) {
            _arm(Keys.familyId("live-scope"), Coverage(c));
            (i, x) = fp.mine(lens, empty, false, _unbound(), "", 0, 0, 0);
            _refused(_page(i, x.length, ""), "mine on an empty topic");
            _arm(F_PLACE, Coverage(c));
            (TopicPageInfo memory e, PlaceRow[] memory y) = fe.everyone(
                ITopicEveryoneReader.PlaceQuery(Purpose.TAG, empty, false, false, 4),
                lens,
                _unbound(),
                "",
                0,
                0,
                0
            );
            _refused(_page(e, y.length, ""), "everyone on an empty topic");
            (Qualified memory q, Coverage cov, uint64 a, uint64 b) =
                fk.placeCount(Purpose.TAG, empty, false, _unbound());
            _refused(_count(q, cov, a, b), "placeCount of an empty topic");
            _arm(F_POSITION_AUTHORS, Coverage(c));
            (TopicPageInfo memory n, AuthorRow[] memory z) = fk.byName(nobody, _unbound(), "", 0);
            _refused(_page(n, z.length, ""), "byName of an unstated position");
            (q, cov, a, b) = fk.authorCount(nobody, _unbound());
            _refused(_count(q, cov, a, b), "authorCount of an unstated position");
            _arm(Keys.familyId("reference-position"), Coverage(c));
            (TopicPageInfo memory k, PlaceCount[] memory w) = fk.children(empty, _unbound(), "", 0);
            _refused(_page(k, w.length, ""), "children of a childless topic");
            _disarm();
        }
    }

    /// The page's own coverage is unchanged by the rule: over COMPLETE lists a listing read one entry per page says
    /// PARTIAL on every page (the first, which stops early; the resumed ones; the last, which is resumed), and only
    /// a listing that starts at the origin and finishes on that page says COMPLETE.
    function test_the_pages_own_partial_is_unchanged() public {
        uint8[3] memory vs = [V_MINE_BELOW, V_EVERYONE_BELOW, V_BY_NAME];
        for (uint256 k; k < 3; ++k) {
            uint8 v = vs[k];
            Outcome memory whole = _run(v);
            assertEq(whole.status, uint8(Status.PRESENT));
            assertEq(whole.coverage, uint8(Coverage.COMPLETE), _viewName(v));
            assertTrue(whole.complete);
            assertEq(whole.scanStatus, SCAN_EXHAUSTED);
            bytes memory cont;
            uint256 pages;
            while (true) {
                (Outcome memory o, bytes memory next) = _runAt(v, cont, 1);
                ++pages;
                assertEq(o.status, uint8(Status.PRESENT), _viewName(v));
                assertEq(o.coverage, uint8(Coverage.PARTIAL), "a page of a paged listing");
                assertFalse(o.complete);
                if (next.length == 0) {
                    assertEq(o.scanStatus, SCAN_EXHAUSTED, "the last page, resumed: PARTIAL");
                    assertEq(o.frontier, 0);
                    break;
                }
                assertGt(o.frontier, 0);
                cont = next;
            }
            assertGe(pages, 2, _viewName(v));
        }
    }
}
