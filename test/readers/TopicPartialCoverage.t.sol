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

/// @notice Docs INDEX-BUILD step 3b, §8's reader test for partial coverage. A real live index is always COMPLETE (the
///         readers ask only `ledger.index()`, and a building generation is never it), so the index is wrapped in
///         `FaultyReads` and made to report one family at a time as UNKNOWN or as PARTIAL, on every read that names
///         the family (`coverage`, `postingHeadOf`, `postingSliceOf`), for every view of the three topic readers.
///
///         What the readers promise (`src/interfaces/Readers.sol`): UNKNOWN is a refusal as data (status UNKNOWN, no
///         rows, coverage UNKNOWN); PARTIAL is data with its coverage stated: the page is PRESENT with the faithful
///         rows, `listingCoverage` PARTIAL and `completeFromOrigin` false (a count view returns PARTIAL with its
///         counts). So a page whose lists are not COMPLETE is never reported COMPLETE, and an UNKNOWN list never reads
///         as an empty answer. The matrix of which family each view needs, and what it answers, is logged.
contract TopicPartialCoverageTest is TopicReadersBase {
    uint8 internal constant VIEWS = 13;
    uint8 internal constant M_SET_WORD = 4;

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

    /// View `v` through the wrapped index, as an outcome.
    function probe(uint8 v) external view returns (Outcome memory) {
        bytes32[] memory lens = _lens2(alice, bob);
        if (v <= 1) {
            (TopicPageInfo memory i, MineRow[] memory x) =
                fp.mine(lens, t[0], v == 1, _unbound(), "", 0, 0, 0);
            return _page(i, x.length, abi.encode(x));
        }
        if (v <= 3) {
            (TopicPageInfo memory i, PlaceRow[] memory x) = fe.everyone(
                ITopicEveryoneReader.PlaceQuery(Purpose.TAG, t[0], v == 3, false, 4),
                lens,
                _unbound(),
                "",
                0,
                0,
                0
            );
            return _page(i, x.length, abi.encode(x));
        }
        if (v == 4) {
            (TopicPageInfo memory i, AuthorRow[] memory x) = fk.byName(pos, _unbound(), "", 0);
            return _page(i, x.length, abi.encode(x));
        }
        if (v == 5) {
            (TopicPageInfo memory i, PlaceRow[] memory x) =
                fk.about(things[0], 4, _unbound(), "", 0);
            return _page(i, x.length, abi.encode(x));
        }
        if (v <= 7) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) =
                fk.placeCount(Purpose.TAG, t[0], v == 7, _unbound());
            return _count(q, c, a, b);
        }
        if (v == 8) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) = fk.authorCount(pos, _unbound());
            return _count(q, c, a, b);
        }
        if (v <= 10) {
            (Qualified memory q, Coverage c, uint64 a, uint64 b) =
                fk.entryCount(_pid(alice), Purpose.TAG, t[0], v == 10, _unbound());
            return _count(q, c, a, b);
        }
        TopicPageInfo memory info;
        PlaceCount[] memory pc;
        if (v == 11) (info, pc) = fk.wordPage(t[0], _unbound(), "", 0);
        else (info, pc) = fk.children(t[0], _unbound(), "", 0);
        return _page(info, pc.length, abi.encode(pc));
    }

    function _run(uint8 v) internal view returns (Outcome memory o) {
        try this.probe(v) returns (Outcome memory got) {
            o = got;
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

    function _disarm() internal {
        fi.clear(IIndexReads.coverage.selector);
        fi.clear(IIndexReads.postingHeadOf.selector);
        fi.clear(IIndexReads.postingSliceOf.selector);
    }

    function _same(Outcome memory a, Outcome memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
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

    function test_every_view_under_unknown_and_partial_coverage_of_each_family() public {
        for (uint8 v; v < VIEWS; ++v) {
            Outcome memory base = _run(v);
            assertFalse(base.reverted, string.concat(_viewName(v), ": faithful read"));
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
                if (!usesU && !usesP) continue;
                ++needed;
                emit log_named_string(
                    what, string.concat("UNKNOWN -> ", _word(u), "; PARTIAL -> ", _word(q))
                );
                assertFalse(u.reverted, string.concat(what, ": UNKNOWN is data, never a revert"));
                assertFalse(q.reverted, string.concat(what, ": PARTIAL is data, never a revert"));
                // never COMPLETE while a needed list is not
                assertTrue(u.coverage != uint8(Coverage.COMPLETE) || !usesU, what);
                assertFalse(u.complete && usesU, string.concat(what, ": UNKNOWN, never complete"));
                assertFalse(q.complete && usesP, string.concat(what, ": PARTIAL, never complete"));
                if (usesP) {
                    assertTrue(
                        q.coverage != uint8(Coverage.COMPLETE),
                        string.concat(what, ": PARTIAL coverage is stated")
                    );
                }
                // UNKNOWN: a refusal with no rows (or a shortcut not taken, with the faithful answer)
                if (usesU && u.status != uint8(Status.PRESENT)) {
                    assertEq(
                        u.status, uint8(Status.UNKNOWN), string.concat(what, ": UNKNOWN status")
                    );
                    assertEq(u.rows, 0, string.concat(what, ": UNKNOWN has no rows"));
                    assertEq(u.coverage, uint8(Coverage.UNKNOWN), what);
                }
                // PARTIAL: PRESENT with the faithful rows, the coverage stated
                if (usesP) {
                    assertEq(
                        q.status, uint8(Status.PRESENT), string.concat(what, ": PARTIAL is PRESENT")
                    );
                    assertEq(
                        q.hash, base.hash, string.concat(what, ": PARTIAL keeps the faithful rows")
                    );
                }
            }
            assertGt(needed, 0, string.concat(_viewName(v), ": needs at least one family"));
        }
    }

    /// An empty list at PARTIAL: the page is PRESENT, with no rows and coverage PARTIAL (never an empty COMPLETE);
    /// at UNKNOWN it is UNKNOWN. A topic nobody tagged, read through `mine` and `everyone`.
    function test_an_empty_list_at_partial_is_never_an_empty_complete_page() public {
        bytes32 empty = _regPath("partial-empty", 1)[0];
        bytes32[] memory lens = _lens2(alice, bob);
        (TopicPageInfo memory i, MineRow[] memory x) =
            fp.mine(lens, empty, false, _unbound(), "", 0, 0, 0);
        assertEq(
            abi.encode(uint8(i.q.status), uint8(i.listingCoverage), x.length), abi.encode(2, 3, 0)
        );
        _arm(Keys.familyId("live-scope"), Coverage.PARTIAL);
        (i, x) = fp.mine(lens, empty, false, _unbound(), "", 0, 0, 0);
        assertEq(uint8(i.q.status), uint8(Status.PRESENT));
        assertEq(uint8(i.listingCoverage), uint8(Coverage.PARTIAL), "an empty PARTIAL page says so");
        assertFalse(i.completeFromOrigin);
        assertEq(x.length, 0);
        _arm(Keys.familyId("live-scope"), Coverage.UNKNOWN);
        (i, x) = fp.mine(lens, empty, false, _unbound(), "", 0, 0, 0);
        assertEq(uint8(i.q.status), uint8(Status.UNKNOWN));
        assertEq(uint8(i.listingCoverage), uint8(Coverage.UNKNOWN));
        _disarm();
        _arm(F_PLACE, Coverage.PARTIAL);
        (TopicPageInfo memory e, PlaceRow[] memory y) = fe.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.TAG, empty, false, false, 4),
            lens,
            _unbound(),
            "",
            0,
            0,
            0
        );
        assertEq(uint8(e.q.status), uint8(Status.PRESENT));
        assertEq(uint8(e.listingCoverage), uint8(Coverage.PARTIAL));
        assertFalse(e.completeFromOrigin);
        assertEq(y.length, 0);
    }
}
