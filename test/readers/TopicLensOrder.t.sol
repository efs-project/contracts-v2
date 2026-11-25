// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {
    ITopicEveryoneReader,
    MineRow,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";

/// @notice The combined lens walk of design §11 in both views (spec §3.1–3.2: an earlier lens author always beats a
///         later one; "not this" at the viewed place is asked before the stance where the entry was filed), the
///         decider every row names, the two page bounds (`limit` entries, `maxRows` rows), the progress guarantee,
///         resume indices that appends never shift, and the cost of a padded stretch.
contract TopicLensOrderTest is TopicReadersBase {
    uint8 internal constant SCAN_ROWS = 4;

    bytes32 internal cars; // /lo-0
    bytes32 internal tesla; // /lo-0/tesla
    bytes32 internal ford; // /lo-0/ford

    function setUp() public override {
        super.setUp();
        cars = _regPath("lo", 1)[0];
        tesla = _child(cars, "tesla", true);
        ford = _child(cars, "ford", true);
    }

    // ---- helpers ---------------------------------------------------------------------------------------------

    function _ev(bytes32 place, bool below, bytes32[] memory lens)
        internal
        view
        returns (PlaceRow[] memory rows)
    {
        TopicPageInfo memory info;
        (info, rows) = _everyone(place, below, lens, false, 0, "", 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
    }

    function _mn(bytes32 place, bool below, bytes32[] memory lens)
        internal
        view
        returns (MineRow[] memory rows)
    {
        TopicPageInfo memory info;
        (info, rows) = _mine(lens, place, below, "", 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
    }

    function _inEv(PlaceRow[] memory rows, bytes32 thing)
        internal
        pure
        returns (bool, PlaceRow memory)
    {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].thing == thing) return (true, rows[i]);
        }
        PlaceRow memory none;
        return (false, none);
    }

    function _inMine(MineRow[] memory rows, bytes32 thing)
        internal
        pure
        returns (bool, MineRow memory)
    {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].thing == thing) return (true, rows[i]);
        }
        MineRow memory none;
        return (false, none);
    }

    function _shows(bytes32 place, bool below, bytes32[] memory lens, bytes32 thing)
        internal
        view
        returns (bool e, bool m)
    {
        (e,) = _inEv(_ev(place, below, lens), thing);
        (m,) = _inMine(_mn(place, below, lens), thing);
    }

    // ---- the four required cases -------------------------------------------------------------------------------

    /// 1. I am first in the lens and say yes at /cars/tesla; a later lens author says no at /cars: it SHOWS at /cars.
    function test_an_earlier_yes_where_filed_beats_a_later_no_at_the_viewed_place() public {
        bytes32 x = things[0];
        _tagN(alice, tesla, x, 2);
        _deny(bob, cars, x);
        bytes32[] memory lens = _lens2(alice, bob);
        (bool e, bool m) = _shows(cars, true, lens, x);
        assertTrue(e, "everyone shows it at /cars");
        assertTrue(m, "mine shows it at /cars");
        (, PlaceRow memory pr) = _inEv(_ev(cars, true, lens), x);
        assertEq(pr.decider, 0, "alice decided");
        assertEq(pr.number, 2);
        assertEq(pr.topic, tesla);
        (, MineRow memory mr) = _inMine(_mn(cars, true, lens), x);
        assertEq(mr.decider, 0);
        assertEq(mr.topic, tesla);
        // the other order: bob's "not this" at /cars now comes first
        (e, m) = _shows(cars, true, _lens2(bob, alice), x);
        assertFalse(e);
        assertFalse(m);
    }

    /// 2. The first lens author says no at /cars; a later one says yes at /cars/tesla: HIDDEN at /cars, shown at
    ///    /cars/tesla.
    function test_an_earlier_no_at_the_viewed_place_beats_a_later_yes_where_filed() public {
        bytes32 x = things[1];
        _deny(alice, cars, x);
        _tag(bob, tesla, x);
        bytes32[] memory lens = _lens2(alice, bob);
        (bool e, bool m) = _shows(cars, true, lens, x);
        assertFalse(e, "everyone hides it at /cars");
        assertFalse(m, "mine hides it at /cars");
        (e, m) = _shows(tesla, false, lens, x);
        assertTrue(e, "everyone shows it at /cars/tesla");
        assertTrue(m, "mine shows it at /cars/tesla");
        (e, m) = _shows(tesla, true, lens, x);
        assertTrue(e && m, "and below /cars/tesla: a denial does not travel down");
        (, MineRow memory mr) = _inMine(_mn(tesla, false, lens), x);
        assertEq(mr.decider, 1, "bob decided where it was filed");
    }

    /// 3. One author says yes at /cars/tesla and no at /cars: hidden at /cars, shown at /cars/tesla.
    function test_one_authors_no_at_the_viewed_place_beats_its_own_yes_below() public {
        bytes32 x = things[2];
        _tag(alice, tesla, x);
        _deny(alice, cars, x);
        bytes32[] memory lens = _lens1(alice);
        (bool e, bool m) = _shows(cars, true, lens, x);
        assertFalse(e);
        assertFalse(m);
        (e, m) = _shows(tesla, false, lens, x);
        assertTrue(e);
        assertTrue(m);
    }

    /// 4. Over a mixed fixture with several lenses and places, everything `mine` returns `everyone` returns too.
    function test_mine_is_everyone_without_the_public_tier() public {
        address[] memory a = new address[](4);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
        a[3] = makeAddr("lo/dave");
        bytes32[] memory xs = _things(12);
        bytes32[3] memory places = [cars, tesla, ford];
        // each (author, thing) gets a deterministic mix of stances: yes or no at any of the three places
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 12; ++j) {
                uint256 h = uint256(keccak256(abi.encode("lo/mix", i, j)));
                for (uint256 k; k < 3; ++k) {
                    uint256 v = (h >> (8 * k)) % 5; // 0, 1 silent; 2, 3 yes; 4 no
                    if (v == 2 || v == 3) _tagN(a[i], places[k], xs[j], uint16(v));
                    else if (v == 4) _deny(a[i], places[k], xs[j]);
                }
            }
        }
        bytes32[][] memory lenses = new bytes32[][](5);
        lenses[0] = _lensOf(_pick(a, 0, 1, 2, 3, 4));
        lenses[1] = _lensOf(_pick(a, 3, 2, 1, 0, 4));
        lenses[2] = _lensOf(_pick(a, 1, 3, 9, 9, 2));
        lenses[3] = _lensOf(_pick(a, 2, 9, 9, 9, 1));
        lenses[4] = _lensOf(_pick(a, 0, 2, 9, 9, 2));
        uint256 checked;
        uint256 same;
        for (uint256 l; l < lenses.length; ++l) {
            for (uint256 k; k < 3; ++k) {
                for (uint256 b; b < 2; ++b) {
                    MineRow[] memory m = _mn(places[k], b == 1, lenses[l]);
                    PlaceRow[] memory e = _ev(places[k], b == 1, lenses[l]);
                    for (uint256 i; i < m.length; ++i) {
                        (bool has, PlaceRow memory pr) = _inEv(e, m[i].thing);
                        assertTrue(has, "a thing mine shows, everyone shows");
                        // through the same filing, the same decider and number (everyone may show the thing
                        // through a newer filing the public tier decides)
                        if (pr.position == m[i].position) {
                            assertEq(pr.decider, m[i].decider, "the same decider");
                            assertEq(pr.number, m[i].number, "the same number");
                            ++same;
                        }
                        ++checked;
                    }
                }
            }
        }
        assertGt(checked, 20, "the fixture exercises the walk");
        assertGt(same, 10);
    }

    /// The first `n` of `a` in the order given (9 = skip).
    function _pick(address[] memory a, uint256 i0, uint256 i1, uint256 i2, uint256 i3, uint256 n)
        internal
        pure
        returns (address[] memory out)
    {
        uint256[4] memory ix = [i0, i1, i2, i3];
        out = new address[](n);
        uint256 k;
        for (uint256 i; i < 4 && k < n; ++i) {
            if (ix[i] != 9) out[k++] = a[ix[i]];
        }
    }

    // ---- who decided ------------------------------------------------------------------------------------------

    function test_every_public_row_names_its_decider() public {
        bytes32[] memory xs = _things(3);
        _tagN(alice, cars, xs[0], 5); // alice (lens index 1) decides with 5
        _tag(carol, cars, xs[1]); // a stranger's yes: the public tier
        _act(bob, EfsTopics.tag(cars, xs[2], 0, 7)); // bob (lens index 0) decides with 7
        _tag(alice, cars, xs[2]);
        PlaceRow[] memory rows = _ev(cars, false, _lens2(bob, alice));
        (bool has, PlaceRow memory r0) = _inEv(rows, xs[0]);
        assertTrue(has);
        assertEq(r0.decider, 1);
        assertEq(r0.number, 5);
        (, PlaceRow memory r1) = _inEv(rows, xs[1]);
        assertEq(r1.decider, 255, "the public tier");
        assertEq(r1.number, 0);
        (, PlaceRow memory r2) = _inEv(rows, xs[2]);
        assertEq(r2.decider, 0);
        assertEq(r2.number, 7);
        // raw reads no lens: every row 255
        (, PlaceRow[] memory raw) = _everyone(cars, false, _lens2(bob, alice), true, 0, "", 0);
        for (uint256 i; i < raw.length; ++i) {
            assertEq(raw[i].decider, 255);
        }
    }

    // ---- two bounds and progress ----------------------------------------------------------------------------

    function _ev2(
        bytes32 place,
        bool below,
        bytes32[] memory lens,
        bytes memory cont,
        uint32 limit,
        uint32 maxRows,
        uint256 reserve
    ) internal view returns (TopicPageInfo memory, PlaceRow[] memory) {
        return pager.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose_TAG, place, below, false, 0),
            lens,
            _unbound(),
            cont,
            limit,
            maxRows,
            reserve
        );
    }

    function _mn2(
        bytes32 place,
        bool below,
        bytes32[] memory lens,
        bytes memory cont,
        uint32 limit,
        uint32 maxRows,
        uint256 reserve
    ) internal view returns (TopicPageInfo memory, MineRow[] memory) {
        return miner.mine(lens, place, below, _unbound(), cont, limit, maxRows, reserve);
    }

    function test_max_rows_stops_with_a_continuation_in_both_views() public {
        bytes32[] memory xs = _things(10);
        _tagMany(alice, cars, xs);
        bytes memory cont;
        uint256 seen;
        for (uint256 pages;; ++pages) {
            (TopicPageInfo memory info, PlaceRow[] memory rows) =
                _ev2(cars, false, _lens1(alice), cont, 0, 3, 0);
            _ok(info);
            assertLe(rows.length, 3);
            for (uint256 i; i < rows.length; ++i) {
                assertEq(rows[i].thing, xs[9 - seen++], "newest first, nothing skipped or repeated");
            }
            if (info.next.length == 0) break;
            assertEq(info.scanStatus, SCAN_ROWS);
            assertEq(rows.length, 3);
            cont = info.next;
        }
        assertEq(seen, 10);
        cont = "";
        seen = 0;
        for (;;) {
            (TopicPageInfo memory info, MineRow[] memory rows) =
                _mn2(cars, true, _lens1(alice), cont, 0, 3, 0);
            _ok(info);
            assertLe(rows.length, 3);
            for (uint256 i; i < rows.length; ++i) {
                assertEq(rows[i].thing, xs[9 - seen++]);
            }
            if (info.next.length == 0) break;
            assertEq(info.scanStatus, SCAN_ROWS);
            cont = info.next;
        }
        assertEq(seen, 10);
    }

    function test_the_entry_limit_stops_first_when_entries_skip() public {
        bytes32[] memory xs = _things(6);
        for (uint256 i; i < 5; ++i) {
            _deny(carol, cars, xs[i]); // lone negatives: entries, no rows
        }
        _tag(alice, cars, xs[5]);
        // the newest entry is the row; then five skips: a row cap of 3 never fills, the entry limit stops
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _ev2(cars, false, new bytes32[](0), "", 4, 3, 0);
        _ok(info);
        assertEq(rows.length, 1);
        assertEq(info.scanned, 4);
        assertEq(info.scanStatus, SCAN_LIMIT);
    }

    function test_every_page_reads_at_least_one_entry() public {
        bytes32[] memory xs = _things(20); // more than one batch of 16
        _tagMany(alice, cars, xs);
        bytes32[] memory lens = _lens1(alice);
        uint256 huge = type(uint256).max;
        // limit 1, maxRows 1, and a reserve no call can leave: each reads exactly one entry, with a continuation
        (TopicPageInfo memory a, PlaceRow[] memory ar) = _ev2(cars, false, lens, "", 1, 0, 0);
        (TopicPageInfo memory b, PlaceRow[] memory br) = _ev2(cars, false, lens, "", 0, 1, 0);
        (TopicPageInfo memory c, PlaceRow[] memory cr) = _ev2(cars, false, lens, "", 0, 0, huge);
        assertEq(a.scanned, 1);
        assertEq(a.scanStatus, SCAN_LIMIT);
        assertEq(b.scanned, 1);
        assertEq(b.scanStatus, SCAN_ROWS);
        assertEq(c.scanned, 1);
        assertEq(c.scanStatus, SCAN_GAS);
        assertEq(ar.length + br.length + cr.length, 3);
        assertEq(c.next.length, a.next.length);
        (TopicPageInfo memory d, MineRow[] memory dr) = _mn2(cars, false, lens, "", 1, 0, 0);
        (TopicPageInfo memory e, MineRow[] memory er) = _mn2(cars, false, lens, "", 0, 1, 0);
        (TopicPageInfo memory f, MineRow[] memory fr) = _mn2(cars, false, lens, "", 0, 0, huge);
        assertEq(d.scanned, 1);
        assertEq(d.scanStatus, SCAN_LIMIT);
        assertEq(e.scanStatus, SCAN_ROWS);
        assertGe(f.scanned, 1);
        assertEq(f.scanStatus, SCAN_GAS);
        assertEq(dr.length, 1);
        assertEq(er.length, 1);
        assertGe(fr.length, 1);
        // a whole listing in pages of one reserve-starved call each still ends
        bytes memory cont;
        uint256 seen;
        for (uint256 i; i < 30; ++i) {
            (TopicPageInfo memory g, PlaceRow[] memory gr) =
                _ev2(cars, false, lens, cont, 0, 0, huge);
            seen += gr.length;
            if (g.next.length == 0) break;
            cont = g.next;
        }
        assertEq(seen, 20);
    }

    // ---- resume indices count from the start of each list -----------------------------------------------------

    function test_appends_between_pages_never_shift_the_resume_point() public {
        bytes32[] memory xs = _things(24);
        // four merged lists below /cars in each view: the place list and the roll-up (everyone); alice's and bob's
        // exact and roll-up lists (mine)
        for (uint256 i; i < 12; ++i) {
            address who = i % 2 == 0 ? alice : bob;
            _tag(who, i % 3 == 0 ? cars : tesla, xs[i]);
        }
        bytes32[] memory lens = _lens2(alice, bob);
        PlaceRow[] memory wantE = _ev(cars, true, lens);
        MineRow[] memory wantM = _mn(cars, true, lens);
        assertEq(wantE.length, 12);
        assertEq(wantM.length, 12);
        (TopicPageInfo memory e1, PlaceRow[] memory r1) = _ev2(cars, true, lens, "", 5, 0, 0);
        (TopicPageInfo memory m1, MineRow[] memory s1) = _mn2(cars, true, lens, "", 5, 0, 0);
        assertGt(e1.next.length, 0);
        assertGt(m1.next.length, 0);
        // append to every merged list: alice and bob at /cars and under /cars/tesla
        for (uint256 i = 12; i < 24; ++i) {
            address who = i % 2 == 0 ? alice : bob;
            _tag(who, i % 4 < 2 ? cars : tesla, xs[i]);
        }
        uint256 k;
        for (uint256 i; i < r1.length; ++i) {
            assertEq(r1[i].bindingOrdinal, wantE[k++].bindingOrdinal);
        }
        for (bytes memory cont = e1.next; cont.length != 0;) {
            (TopicPageInfo memory e, PlaceRow[] memory r) = _ev2(cars, true, lens, cont, 5, 0, 0);
            _ok(e);
            for (uint256 i; i < r.length; ++i) {
                assertEq(
                    r[i].bindingOrdinal, wantE[k++].bindingOrdinal, "no row skipped or repeated"
                );
            }
            cont = e.next;
        }
        assertEq(k, 12, "everyone: exactly the listing as of its origin");
        k = 0;
        for (uint256 i; i < s1.length; ++i) {
            assertEq(s1[i].bindingOrdinal, wantM[k++].bindingOrdinal);
        }
        for (bytes memory cont = m1.next; cont.length != 0;) {
            (TopicPageInfo memory m, MineRow[] memory s) = _mn2(cars, true, lens, cont, 5, 0, 0);
            _ok(m);
            for (uint256 i; i < s.length; ++i) {
                assertEq(
                    s[i].bindingOrdinal, wantM[k++].bindingOrdinal, "no row skipped or repeated"
                );
            }
            cont = m.next;
        }
        assertEq(k, 12, "mine: exactly the listing as of its origin");
        // a fresh listing sees the appended entries
        assertEq(_ev(cars, true, lens).length, 24);
        assertEq(_mn(cars, true, lens).length, 24);
    }

    // ---- a padded stretch costs about one author-list head per entry, whatever the lens --------------------

    /// The gas of reading `n` padded entries (lone negatives, nobody says yes) at /cars/ford through a lens of
    /// `len` silent authors.
    function _padGas(bytes32[] memory lens, uint32 n) internal returns (uint256 g) {
        _cool();
        uint256 before = gasleft();
        (TopicPageInfo memory info, PlaceRow[] memory rows) = _ev2(ford, false, lens, "", n, 0, 0);
        g = before - gasleft();
        _ok(info);
        assertEq(info.scanned, n);
        assertEq(rows.length, 0);
    }

    function test_a_padded_stretch_costs_the_same_whatever_the_lens() public {
        bytes32[] memory xs = _things(40);
        Action[] memory a = new Action[](40);
        for (uint256 i; i < 40; ++i) {
            a[i] = EfsTopics.deny(ford, xs[i], 0, 0);
        }
        _execAs(makeAddr("lo/stranger"), a, new bytes[](40));
        bytes32[] memory one = _lensOf(_authorsN("lo/l1", 1));
        bytes32[] memory big = _lensOf(_authorsN("lo/l64", 64));
        uint256 p1 = (_padGas(one, 40) - _padGas(one, 8)) / 32;
        uint256 p64 = (_padGas(big, 40) - _padGas(big, 8)) / 32;
        emit log_named_uint("padded entry, lens 1", p1);
        emit log_named_uint("padded entry, lens 64", p64);
        // the bound: no lens read for an entry nobody says yes to, so a lens of 64 adds at most 1,000 gas per entry
        // (calldata and memory), and an entry costs at most 45,000 (its cell and its author-list head, cold: about
        // 36k measured, against 49k at a lens of 1 and 357k at a lens of 64 when the lens was read first)
        assertLe(p64, p1 + 1_000, "the lens size does not price a padded stretch");
        assertLe(p64, 45_000, "about one head read per skipped entry");
    }
}
