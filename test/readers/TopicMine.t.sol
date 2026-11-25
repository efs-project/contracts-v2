// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Coverage, Status} from "../../src/interfaces/Results.sol";
import {MineRow, TopicPageInfo} from "../../src/interfaces/Readers.sol";

/// @notice `TopicMineReader.mine` (docs/TAG-DESIGN.md §6; spec §3.1): the lens rule, roll-up, one row per
///         (topic filed under, thing), newest-first paging, the basis and the gas-reserve stop.
contract TopicMineTest is TopicReadersBase {
    bytes32[] internal cars; // /m-0 /m-0/m-1
    bytes32 internal tesla; // /m-0/tesla
    bytes32 internal ford; // /m-0/ford

    function setUp() public override {
        super.setUp();
        cars = _regPath("m", 2);
        tesla = _child(cars[0], "tesla", true);
        ford = _child(cars[0], "ford", true);
    }

    function _row(MineRow[] memory rows, bytes32 thing)
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

    // ---- the lens rule --------------------------------------------------------------------------------------

    function test_first_author_with_a_stance_decides() public {
        bytes32 t = cars[0];
        _tagN(alice, t, things[0], 3); // alice yes 3, bob no: alice decides
        _deny(bob, t, things[0]);
        _deny(bob, t, things[1]); // bob no, alice silent: hidden
        _tag(alice, t, things[2]);
        _release(alice, t, things[2]); // alice released, bob yes 2: bob decides
        _tagN(bob, t, things[2], 2);
        _deny(alice, t, things[3]); // alice no, bob yes: hidden (the first stance decides)
        _tagN(bob, t, things[3], 5);
        _deny(carol, t, things[4]); // a stranger's no hides nothing
        _tag(bob, t, things[4]);

        (TopicPageInfo memory info, MineRow[] memory rows) =
            _mine(_lens2(alice, bob), t, false, "", 0);
        _ok(info);
        assertEq(rows.length, 3, "things 0, 2 and 4");
        (bool has, MineRow memory x) = _row(rows, things[0]);
        assertTrue(has);
        assertEq(x.number, 3);
        assertEq(x.decider, 0);
        assertEq(x.principalId, _pid(alice));
        assertEq(x.topic, t);
        assertEq(x.position, Keys.position(Purpose.TAG, t, things[0]));
        assertEq(x.targetKind, 2, "a created subject");
        (has,) = _row(rows, things[1]);
        assertFalse(has, "bob's no hides");
        (has, x) = _row(rows, things[2]);
        assertTrue(has);
        assertEq(x.decider, 1, "a release falls through");
        assertEq(x.number, 2);
        (has,) = _row(rows, things[3]);
        assertFalse(has, "alice's no decides before bob's yes");
        (has, x) = _row(rows, things[4]);
        assertTrue(has, "carol is not in the lens");
        assertEq(x.decider, 1);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        assertEq(uint8(info.listingCoverage), uint8(Coverage.COMPLETE));
        assertTrue(info.completeFromOrigin);
        assertTrue(info.dedupWithinPageOnly);
        assertEq(info.next.length, 0);
    }

    function _lensRule(uint256 n) internal {
        address[] memory a = _authorsN(string.concat("lens", vm.toString(n)), n);
        bytes32 t = cars[1];
        address last = a[n - 1];
        _tagN(last, t, things[0], 7); // only the last author says yes
        _tag(last, t, things[1]);
        _deny(a[0], t, things[1]); // the first author's no hides it
        _deny(carol, t, things[2]); // a stranger's no
        _tag(last, t, things[2]);
        (TopicPageInfo memory info, MineRow[] memory rows) = _mine(_lensOf(a), t, false, "", 0);
        _ok(info);
        assertEq(rows.length, 2, "things 0 and 2");
        assertEq(rows[0].thing, things[2], "newest first-stated first");
        assertEq(rows[1].thing, things[0]);
        assertEq(rows[1].number, 7);
        assertEq(rows[1].decider, n - 1);
        assertEq(rows[1].principalId, _pid(last));
    }

    function test_lens_rule_with_a_lens_of_1() public {
        _lensRule(1);
    }

    function test_lens_rule_with_a_lens_of_8() public {
        _lensRule(8);
    }

    function test_lens_rule_with_a_lens_of_64() public {
        _lensRule(64);
    }

    function test_lens_bounds_are_refusals_as_data() public view {
        (TopicPageInfo memory info, MineRow[] memory rows) =
            _mine(new bytes32[](0), cars[0], false, "", 0);
        assertEq(uint8(info.q.status), uint8(Status.INVALID));
        assertEq(rows.length, 0);
        (info, rows) = _mine(new bytes32[](65), cars[0], false, "", 0);
        assertEq(uint8(info.q.status), uint8(Status.LIMIT_EXCEEDED));
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
    }

    // ---- below, and one row per (topic, thing) --------------------------------------------------------------

    function test_below_shows_a_thing_once_per_page_and_once_per_position() public {
        _tag(alice, tesla, things[0]);
        _tag(alice, ford, things[0]); // the same thing under two child topics: one row, the newest filing
        _tag(bob, tesla, things[0]); // a second lens author at the same position: no second row
        _tag(alice, cars[0], things[1]); // exact at the place itself
        (TopicPageInfo memory info, MineRow[] memory rows) =
            _mine(_lens2(alice, bob), cars[0], true, "", 0);
        _ok(info);
        assertEq(rows.length, 2);
        assertEq(rows[0].thing, things[1]);
        assertEq(rows[0].topic, cars[0]);
        assertEq(rows[1].thing, things[0]);
        assertEq(rows[1].topic, ford, "the newest filing that the lens shows");
        assertEq(info.repeatsSkipped, 1, "the tesla filing of the same thing");
        assertTrue(info.dedupWithinPageOnly);
        // exact only: the place itself
        (info, rows) = _mine(_lens2(alice, bob), cars[0], false, "", 0);
        assertEq(rows.length, 1);
        assertEq(rows[0].thing, things[1]);
        // a page of one entry each: the thing recurs across pages, which the consumer removes
        bytes memory cont;
        uint256 total;
        while (true) {
            (info, rows) = _mine(_lens2(alice, bob), cars[0], true, cont, 1);
            total += rows.length;
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(total, 3, "things[1] and things[0] twice (under ford and under tesla)");
    }

    function test_below_reaches_a_deep_descendant() public {
        bytes32[] memory deep = _regPath("deep", 8);
        _tag(alice, deep[7], things[0]);
        (TopicPageInfo memory info, MineRow[] memory rows) =
            _mine(_lens1(alice), deep[0], true, "", 0);
        _ok(info);
        assertEq(rows.length, 1);
        assertEq(rows[0].topic, deep[7]);
    }

    // ---- paging ---------------------------------------------------------------------------------------------

    function test_newest_first_paging_across_pages() public {
        // 12 things, alternating authors, newest first-stated first across both lists and below
        for (uint256 i; i < 12; ++i) {
            _tag(i % 2 == 0 ? alice : bob, i % 3 == 0 ? tesla : cars[0], things[i]);
        }
        bytes32[] memory lens = _lens2(alice, bob);
        bytes memory cont;
        uint256 seen;
        uint256 pages;
        uint64 lastOrdinal = type(uint64).max;
        while (true) {
            (TopicPageInfo memory info, MineRow[] memory rows) = _mine(lens, cars[0], true, cont, 5);
            _ok(info);
            ++pages;
            assertEq(info.startsAtOrigin, pages == 1);
            for (uint256 i; i < rows.length; ++i) {
                // first statements in time order: things[11] first
                assertEq(rows[i].thing, things[11 - seen], "newest first");
                assertLt(rows[i].bindingOrdinal, lastOrdinal);
                lastOrdinal = rows[i].bindingOrdinal;
                ++seen;
            }
            assertEq(info.selectedSoFar, seen);
            if (info.next.length == 0) {
                assertEq(info.scanStatus, SCAN_EXHAUSTED);
                assertEq(
                    uint8(info.listingCoverage), uint8(Coverage.PARTIAL), "a continuation page"
                );
                break;
            }
            assertEq(info.scanStatus, SCAN_LIMIT);
            assertEq(uint8(info.listingCoverage), uint8(Coverage.PARTIAL));
            cont = info.next;
        }
        assertEq(seen, 12);
        assertGe(pages, 3);
    }

    function test_a_continuation_is_bound_to_its_query_and_basis() public {
        for (uint256 i; i < 4; ++i) {
            _tag(alice, cars[0], things[i]);
        }
        (TopicPageInfo memory info,) = _mine(_lens1(alice), cars[0], false, "", 2);
        bytes memory cont = info.next;
        // another query: INVALID
        (TopicPageInfo memory other,) = _mine(_lens1(bob), cars[0], false, cont, 2);
        assertEq(uint8(other.q.status), uint8(Status.INVALID));
        // malformed: INVALID
        (other,) = _mine(_lens1(alice), cars[0], false, bytes.concat(cont, bytes1(0)), 2);
        assertEq(uint8(other.q.status), uint8(Status.INVALID));
        // a stale basis: the continuation names another execution set
        bytes memory stale = bytes.concat(
            _slice(cont, 0, 64), bytes32(uint256(1)), _slice(cont, 96, cont.length - 96)
        );
        (other,) = _mine(_lens1(alice), cars[0], false, stale, 2);
        assertEq(uint8(other.q.status), uint8(Status.BASIS_STALE));
        // an expected basis that differs from the live one
        BasisCommit memory b = reads.basis(address(r.ledger));
        b.executionSet = keccak256("other");
        (other,) = miner.mine(_lens1(alice), cars[0], false, b, "", 0, 0, 0);
        assertEq(uint8(other.q.status), uint8(Status.BASIS_STALE));
        // the live basis, bound: served
        b = reads.basis(address(r.ledger));
        (other,) = miner.mine(_lens1(alice), cars[0], false, b, cont, 2, 0, 0);
        _ok(other);
        // a later admission does not disturb a continuation: lists are append-only
        _tag(alice, cars[0], things[9]);
        (TopicPageInfo memory later, MineRow[] memory rows) =
            _mine(_lens1(alice), cars[0], false, cont, 0);
        _ok(later);
        assertEq(rows.length, 2, "only the entries older than page 1");
        assertEq(rows[0].thing, things[1]);
    }

    function _slice(bytes memory b, uint256 from, uint256 n)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[from + i];
        }
    }

    function test_gas_reserve_stops_early_with_a_continuation() public {
        bytes32[] memory xs = _things(40);
        _tagMany(alice, cars[0], xs);
        (TopicPageInfo memory info, MineRow[] memory rows) = miner.mine{gas: 2_000_000}(
            _lens1(alice), cars[0], false, _unbound(), "", 0, 0, 1_500_000
        );
        _ok(info);
        assertEq(info.scanStatus, SCAN_GAS);
        assertGt(info.next.length, 0);
        assertLt(rows.length, 40);
        assertEq(uint8(info.listingCoverage), uint8(Coverage.PARTIAL));
        uint256 got = rows.length;
        while (info.next.length != 0) {
            (info, rows) = _mine(_lens1(alice), cars[0], false, info.next, 0);
            got += rows.length;
        }
        assertEq(got, 40, "the continuation finishes the listing");
    }
}

/// @notice A Realm whose index keeps no topic roll-ups: a below view answers UNKNOWN, never empty; exact is served.
contract TopicMineWithoutTopicListsTest is TopicReadersBase {
    function setUp() public override {
        withoutTopicLists = true;
        super.setUp();
    }

    function test_below_is_unknown_never_empty() public {
        bytes32[] memory t = _regPath("n", 2);
        _tag(alice, t[1], things[0]);
        (TopicPageInfo memory info, MineRow[] memory rows) = _mine(_lens1(alice), t[0], true, "", 0);
        assertEq(uint8(info.q.status), uint8(Status.UNKNOWN));
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
        assertEq(rows.length, 0);
        assertFalse(info.completeFromOrigin);
        (info, rows) = _mine(_lens1(alice), t[1], false, "", 0);
        _ok(info);
        assertEq(rows.length, 1);
    }
}
