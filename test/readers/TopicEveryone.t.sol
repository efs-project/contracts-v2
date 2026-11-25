// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {Coverage, Status} from "../../src/interfaces/Results.sol";
import {ITopicPageReader, PlaceRow, TopicPageInfo} from "../../src/interfaces/Readers.sol";

/// @notice `TopicPageReader.everyone`, `raw` and `about` (docs/TAG-DESIGN.md §6; spec §3.2): a row is shown when
///         someone says yes now (the position's author head `live`), hidden only by a lens author's negative at the
///         filed position or at the viewed place, never by a stranger; `raw` and `about` return rows nobody says yes
///         to; repeats of a position (a later author's first yes) are removed within a page.
contract TopicEveryoneTest is TopicReadersBase {
    bytes32[] internal cars; // /e-0
    bytes32 internal tesla; // /e-0/tesla
    bytes32 internal ford; // /e-0/ford

    function setUp() public override {
        super.setUp();
        cars = _regPath("e", 1);
        tesla = _child(cars[0], "tesla", true);
        ford = _child(cars[0], "ford", true);
    }

    function _has(PlaceRow[] memory rows, bytes32 topic, bytes32 thing)
        internal
        pure
        returns (bool, PlaceRow memory)
    {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].topic == topic && rows[i].thing == thing) return (true, rows[i]);
        }
        PlaceRow memory none;
        return (false, none);
    }

    function _about(bytes32 thing) internal view returns (TopicPageInfo memory, PlaceRow[] memory) {
        return lookup.about(thing, 0, _unbound(), "", 0);
    }

    // ---- denials ----------------------------------------------------------------------------------------------

    function test_a_lens_negative_at_the_filed_position_hides() public {
        _tag(carol, cars[0], things[0]);
        _deny(alice, cars[0], things[0]);
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], false, _lens1(alice), false, 0, "", 0);
        _ok(info);
        (bool has,) = _has(rows, cars[0], things[0]);
        assertFalse(has, "alice's no hides it from alice's view");
        (info, rows) = _everyone(cars[0], false, _lens1(bob), false, 0, "", 0);
        (has,) = _has(rows, cars[0], things[0]);
        assertTrue(has, "alice is not in bob's lens");
        (info, rows) = _everyone(cars[0], false, _lens1(alice), true, 0, "", 0);
        (has,) = _has(rows, cars[0], things[0]);
        assertTrue(has, "raw skips the lens");
    }

    function test_a_lens_negative_at_the_viewed_place_hides_below() public {
        _tag(carol, tesla, things[1]); // filed under /e-0/tesla
        _deny(alice, cars[0], things[1]); // alice: not in /e-0
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], true, _lens1(alice), false, 0, "", 0);
        _ok(info);
        (bool has,) = _has(rows, tesla, things[1]);
        assertFalse(has, "a denial at the viewed place hides the thing under it");
        // the denial does not travel down: viewing /e-0/tesla itself shows it
        (info, rows) = _everyone(tesla, false, _lens1(alice), false, 0, "", 0);
        (has,) = _has(rows, tesla, things[1]);
        assertTrue(has);
    }

    function test_a_child_denial_says_nothing_about_the_place() public {
        _tag(carol, tesla, things[2]);
        _tag(carol, ford, things[2]);
        _deny(alice, tesla, things[2]); // not /e-0/tesla
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], true, _lens1(alice), false, 0, "", 0);
        _ok(info);
        (bool has,) = _has(rows, tesla, things[2]);
        assertFalse(has, "hidden where denied");
        (has,) = _has(rows, ford, things[2]);
        assertTrue(has, "still filed under /e-0 by another statement");
    }

    function test_a_strangers_statements_never_hide() public {
        _tag(alice, cars[0], things[3]);
        _deny(carol, cars[0], things[3]);
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], false, _lens1(alice), false, 0, "", 0);
        _ok(info);
        (bool has, PlaceRow memory x) = _has(rows, cars[0], things[3]);
        assertTrue(has);
        assertEq(x.statements, 2);
        assertEq(x.yes, 1);
        (info, rows) = _everyone(cars[0], false, _lens1(bob), false, 0, "", 0);
        (has,) = _has(rows, cars[0], things[3]);
        assertTrue(has, "carol is a stranger to bob too");
    }

    // ---- public rows never depend on a scan -------------------------------------------------------------------

    function test_lone_negatives_before_the_first_yes_do_not_keep_the_row_out() public {
        address[] memory k = _authorsN("pre-neg", 5);
        for (uint256 i; i < 5; ++i) {
            _deny(k[i], cars[0], things[4]);
        }
        _tag(bob, cars[0], things[5]); // a later, unrelated first statement
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], false, new bytes32[](0), false, 3, "", 0);
        _ok(info);
        (bool has,) = _has(rows, cars[0], things[4]);
        assertFalse(has, "nobody says yes yet");
        (info, rows) = _everyone(cars[0], false, new bytes32[](0), true, 3, "", 0);
        (has,) = _has(rows, cars[0], things[4]);
        assertTrue(has, "raw returns it");
        (info, rows) = _about(things[4]);
        (has,) = _has(rows, cars[0], things[4]);
        assertTrue(has, "about returns it");

        _tag(alice, cars[0], things[4]); // the first yes
        (info, rows) = _everyone(cars[0], false, new bytes32[](0), false, 3, "", 0);
        _ok(info);
        assertEq(rows[0].thing, things[4], "shown at the position of its first yes, newest first");
        assertEq(rows[1].thing, things[5]);
        assertEq(rows[0].statements, 6);
        assertEq(rows[0].yes, 1);
        assertEq(rows[0].sampled, 3);
        assertEq(rows[0].sampleYes, 1, "alice is the newest author");
        assertEq(rows[0].sampleNo, 2);
        assertTrue(rows[0].incomplete, "the sample did not cover every author");
        assertTrue(info.dedupWithinPageOnly);
        // a lens author's no still hides it
        _deny(bob, cars[0], things[4]);
        (info, rows) = _everyone(cars[0], false, _lens1(bob), false, 0, "", 0);
        (has,) = _has(rows, cars[0], things[4]);
        assertFalse(has);
    }

    function test_a_later_first_yes_shows_an_old_position_as_new_once_per_page() public {
        _tag(alice, cars[0], things[6]);
        _tag(alice, cars[0], things[7]);
        _tag(bob, cars[0], things[6]); // a later author's first yes at an old position
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(cars[0], false, new bytes32[](0), false, 0, "", 0);
        _ok(info);
        assertEq(rows.length, 2, "once per page");
        assertEq(rows[0].thing, things[6], "the newest occurrence");
        assertEq(rows[1].thing, things[7]);
        assertEq(info.repeatsSkipped, 1);
        assertEq(rows[0].yes, 2);
        // across pages the repeat can recur: a page of one row holds the newest occurrence only
        (info, rows) = _everyone(cars[0], false, new bytes32[](0), false, 0, "", 1);
        assertEq(rows[0].thing, things[6]);
        bytes memory cont = info.next;
        uint256 total = 1;
        bool again;
        while (cont.length != 0) {
            (info, rows) = _everyone(cars[0], false, new bytes32[](0), false, 0, cont, 1);
            for (uint256 i; i < rows.length; ++i) {
                if (rows[i].thing == things[6]) again = true;
                ++total;
            }
            cont = info.next;
        }
        assertTrue(again, "a consumer removes repeats across pages");
        assertEq(total, 3);
    }

    // ---- paging, about, homes, no topic lists -----------------------------------------------------------------

    function test_everyone_pages_newest_first_with_a_gas_stop() public {
        for (uint256 i; i < 9; ++i) {
            _tag(i % 2 == 0 ? alice : carol, i % 3 == 0 ? tesla : cars[0], things[i]);
        }
        bytes memory cont;
        uint256 seen;
        uint256 pages;
        while (true) {
            (TopicPageInfo memory info, PlaceRow[] memory rows) =
                _everyone(cars[0], true, _lens1(alice), false, 1, cont, 3);
            _ok(info);
            ++pages;
            for (uint256 i; i < rows.length; ++i) {
                assertEq(rows[i].thing, things[8 - seen]);
                ++seen;
            }
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(seen, 9);
        assertGe(pages, 3);
        (TopicPageInfo memory g, PlaceRow[] memory gr) = pager.everyone{gas: 1_500_000}(
            ITopicPageReader.PlaceQuery(Purpose.TAG, cars[0], true, false, 0),
            new bytes32[](0),
            _unbound(),
            "",
            0,
            1_200_000
        );
        _ok(g);
        assertEq(g.scanStatus, SCAN_GAS);
        assertLt(gr.length, 9);
        assertGt(g.next.length, 0);
    }

    function test_about_lists_every_place_of_a_thing() public {
        _tag(alice, tesla, things[9]);
        _deny(carol, ford, things[9]);
        _tag(bob, cars[0], things[9]);
        _deny(alice, cars[0], things[9]);
        (TopicPageInfo memory info, PlaceRow[] memory rows) = _about(things[9]);
        _ok(info);
        assertFalse(info.dedupWithinPageOnly, "one entry per position");
        assertEq(rows.length, 3);
        assertEq(rows[0].topic, cars[0]);
        assertEq(rows[0].statements, 2);
        assertEq(rows[0].yes, 1);
        assertEq(rows[1].topic, ford);
        assertEq(rows[1].yes, 0, "a lone negative is reachable from its thing");
        assertEq(rows[2].topic, tesla);
        (info, rows) = lookup.about(things[9], 2, _unbound(), "", 1);
        assertEq(rows.length, 1);
        assertEq(rows[0].sampled, 2);
        assertEq(rows[0].sampleYes, 1);
        assertEq(rows[0].sampleNo, 1);
        assertFalse(rows[0].incomplete);
        (info, rows) = lookup.about(things[9], 2, _unbound(), info.next, 0);
        assertEq(rows.length, 2, "the continuation");
        assertEq(rows[0].topic, ford);
    }

    function test_everyone_at_a_home_folder() public {
        bytes32 home = bytes32(uint256(uint160(makeAddr("everyone/home"))));
        _attach(alice, home, "pet.jpg");
        _attach(bob, home, "pet.jpg");
        _attach(carol, home, "notes.txt");
        (TopicPageInfo memory info, PlaceRow[] memory rows) = pager.everyone(
            ITopicPageReader.PlaceQuery(Purpose.FOLDER, home, false, false, 0),
            new bytes32[](0),
            _unbound(),
            "",
            0,
            0
        );
        _ok(info);
        assertEq(rows.length, 2);
        assertEq(rows[0].position, EfsFiles.folderPosition(home, "notes.txt"));
        assertEq(rows[1].position, EfsFiles.folderPosition(home, "pet.jpg"));
        assertEq(rows[1].statements, 2);
        // FOLDER has no roll-up
        (info,) = pager.everyone(
            ITopicPageReader.PlaceQuery(Purpose.FOLDER, home, true, false, 0),
            new bytes32[](0),
            _unbound(),
            "",
            0,
            0
        );
        assertEq(uint8(info.q.status), uint8(Status.INVALID));
        Keys.position(Purpose.TAG, home, 0);
    }
}

/// @notice Without topic roll-ups: `everyone` below answers UNKNOWN, never empty.
contract TopicEveryoneWithoutTopicListsTest is TopicReadersBase {
    function setUp() public override {
        withoutTopicLists = true;
        super.setUp();
    }

    function test_below_is_unknown() public {
        bytes32[] memory t = _regPath("eu", 2);
        _tag(alice, t[1], things[0]);
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(t[0], true, new bytes32[](0), false, 0, "", 0);
        assertEq(uint8(info.q.status), uint8(Status.UNKNOWN));
        assertEq(uint8(info.listingCoverage), uint8(Coverage.UNKNOWN));
        assertEq(rows.length, 0);
        (info, rows) = _everyone(t[1], false, new bytes32[](0), false, 0, "", 0);
        _ok(info);
        assertEq(rows.length, 1);
    }
}
