// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {Coverage, Qualified, Status} from "../../src/interfaces/Results.sol";
import {AuthorRow, PlaceCount, TopicPageInfo} from "../../src/interfaces/Readers.sol";

/// @notice `TopicLookupReader`: one position's authors (`byName`), counts, a word's page and a topic's children,
///         with the targeted-spam bounds of docs/TAG-DESIGN.md §7: a read of one position or one count costs the same
///         whatever the number of authors or positions.
contract TopicLookupTest is TopicReadersBase {
    bytes32 internal home;
    address internal owner = makeAddr("lookup/owner");

    function setUp() public override {
        super.setUp();
        home = bytes32(uint256(uint160(owner)));
    }

    function _byName(bytes32 position, bytes memory cont, uint16 limit)
        internal
        view
        returns (TopicPageInfo memory, AuthorRow[] memory)
    {
        return lookup.byName(position, _unbound(), cont, limit);
    }

    // ---- byName ---------------------------------------------------------------------------------------------

    function test_by_name_lists_every_author_with_state_and_number() public {
        bytes32[] memory t = _regPath("bn", 1);
        _tagN(alice, t[0], things[0], 4);
        _deny(bob, t[0], things[0]);
        _tag(carol, t[0], things[0]);
        _release(carol, t[0], things[0]);
        (TopicPageInfo memory info, AuthorRow[] memory rows) =
            _byName(Keys.position(Purpose.TAG, t[0], things[0]), "", 0);
        _ok(info);
        assertEq(rows.length, 3);
        assertEq(rows[0].principalId, _pid(carol), "newest first-stated first");
        assertEq(uint8(rows[0].status), uint8(Status.RELEASED));
        assertEq(rows[0].number, 0);
        assertEq(uint8(rows[1].status), uint8(Status.MASKED));
        assertEq(rows[1].number, -1);
        assertEq(rows[1].target, 0);
        assertEq(uint8(rows[2].status), uint8(Status.PRESENT));
        assertEq(rows[2].number, 4);
        assertEq(rows[2].target, things[0]);
        assertEq(rows[2].targetKind, 2);
        assertEq(rows[2].revision, 1);
        assertEq(rows[2].firstAdmission, _admission(alice, Purpose.TAG, t[0], things[0]));
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        assertEq(uint8(info.listingCoverage), uint8(Coverage.COMPLETE));
    }

    function test_by_name_pages_from_the_end() public {
        bytes32[] memory t = _regPath("bp", 1);
        address[] memory a = _authorsN("bp", 7);
        for (uint256 i; i < 7; ++i) {
            _tag(a[i], t[0], things[0]);
        }
        bytes32 pos = Keys.position(Purpose.TAG, t[0], things[0]);
        bytes memory cont;
        uint256 seen;
        uint256 pages;
        while (true) {
            (TopicPageInfo memory info, AuthorRow[] memory rows) = _byName(pos, cont, 3);
            _ok(info);
            ++pages;
            for (uint256 i; i < rows.length; ++i) {
                assertEq(rows[i].principalId, _pid(a[6 - seen]));
                ++seen;
            }
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(seen, 7);
        assertEq(pages, 3);
    }

    /// "Anyone's pet.jpg at this address": 300 authors at one FOLDER position of a home cost page 1 the same as 3.
    function test_by_name_cost_does_not_depend_on_the_author_count() public {
        address[] memory a = _authorsN("pet", 300);
        bytes32 pos = EfsFiles.folderPosition(home, "pet.jpg");
        vm.pauseGasMetering();
        for (uint256 i; i < 3; ++i) {
            _attach(a[i], home, "pet.jpg");
        }
        vm.resumeGasMetering();
        uint256 few = _byNameGas(pos);
        vm.pauseGasMetering();
        for (uint256 i = 3; i < 300; ++i) {
            _attach(a[i], home, "pet.jpg");
        }
        vm.resumeGasMetering();
        uint256 many = _byNameGas(pos);
        (Qualified memory q,, uint64 statements, uint64 yes) = lookup.authorCount(pos, _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(statements, 300);
        assertLe(yes, statements);
        emit log_named_uint("byName page 1 (3 rows), 3 authors", few);
        emit log_named_uint("byName page 1 (3 rows), 300 authors", many);
        assertApproxEqRel(many, few, 0.005e18, "independent of the author count");
    }

    function _byNameGas(bytes32 pos) internal returns (uint256 used) {
        _cool();
        (TopicPageInfo memory info, AuthorRow[] memory rows) = _byName(pos, "", 3);
        used = vm.lastCallGas().gasTotalUsed;
        _ok(info);
        assertEq(rows.length, 3);
    }

    // ---- counts ---------------------------------------------------------------------------------------------

    /// A place of 2,000 positions: a count and a name lookup cost the same as with 3.
    function test_counts_and_by_name_do_not_depend_on_the_place_size() public {
        bytes32[] memory t = _regPath("big", 1);
        vm.pauseGasMetering();
        bytes32[] memory xs = _things(2_000);
        bytes32[] memory three = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            three[i] = xs[i];
        }
        _tagMany(alice, t[0], three);
        vm.resumeGasMetering();
        bytes32 pos = Keys.position(Purpose.TAG, t[0], xs[1]);
        (uint256 c3, uint256 n3) = _countGas(t[0], pos);
        vm.pauseGasMetering();
        bytes32[] memory rest = new bytes32[](1_997);
        for (uint256 i; i < 1_997; ++i) {
            rest[i] = xs[3 + i];
        }
        _tagMany(alice, t[0], rest);
        vm.resumeGasMetering();
        (uint256 c2000, uint256 n2000) = _countGas(t[0], pos);
        (Qualified memory q, Coverage c, uint64 positionsEver, uint64 filings) =
            lookup.placeCount(Purpose.TAG, t[0], false, _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(positionsEver, 2_000);
        assertGe(filings, positionsEver);
        (,, uint64 count, uint64 live) =
            lookup.entryCount(_pid(alice), Purpose.TAG, t[0], false, _unbound());
        assertEq(count, 2_000);
        assertEq(live, 2_000);
        emit log_named_uint("placeCount, 3 positions", c3);
        emit log_named_uint("placeCount, 2,000 positions", c2000);
        emit log_named_uint("byName, place of 3", n3);
        emit log_named_uint("byName, place of 2,000", n2000);
        assertApproxEqAbs(c2000, c3, 100);
        assertApproxEqAbs(n2000, n3, 100);
    }

    function _countGas(bytes32 place, bytes32 pos) internal returns (uint256 c, uint256 n) {
        _cool();
        lookup.placeCount(Purpose.TAG, place, false, _unbound());
        c = vm.lastCallGas().gasTotalUsed;
        _cool();
        _byName(pos, "", 3);
        n = vm.lastCallGas().gasTotalUsed;
    }

    function test_entry_counts_exact_and_below() public {
        bytes32[] memory t = _regPath("ec", 3);
        _tag(alice, t[2], things[0]);
        _tag(alice, t[1], things[1]);
        _deny(alice, t[2], things[2]);
        (Qualified memory q, Coverage c, uint64 count, uint64 live) =
            lookup.entryCount(_pid(alice), Purpose.TAG, t[2], false, _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 2);
        assertEq(live, 1, "the lone negative is not live");
        (q, c, count, live) = lookup.entryCount(_pid(alice), Purpose.TAG, t[0], true, _unbound());
        assertEq(count, 3, "everything below /ec-0");
        (q,, count,) = lookup.entryCount(_pid(alice), Purpose.FOLDER, t[0], true, _unbound());
        assertEq(uint8(q.status), uint8(Status.INVALID), "no FOLDER roll-up");
    }

    // ---- word pages and children ------------------------------------------------------------------------------

    function test_word_page_groups_and_children() public {
        bytes32[] memory cars = _regPath("cars", 1);
        bytes32[] memory people = _regPath("people", 1);
        // the word `tesla` used at the root, under /cars and under /people
        (bytes32 teslaPage) = EfsTopics.wordPageId(typeIds[T_TOPIC_WORD], "tesla");
        bytes32 carsTesla = _child(cars[0], "tesla", true);
        bytes32 peopleTesla = _child(people[0], "tesla", false);
        bytes32 carsFord = _child(cars[0], "ford", true);
        _tag(alice, carsTesla, things[0]);
        _tag(bob, carsTesla, things[1]);
        _tag(alice, teslaPage, things[2]);
        bytes32 modelY = _child(carsTesla, "model_y", true);
        _tag(alice, modelY, things[3]);

        (TopicPageInfo memory info, PlaceCount[] memory rows) =
            lookup.wordPage(teslaPage, _unbound(), "", 0);
        _ok(info);
        assertEq(rows.length, 3);
        assertEq(rows[0].place, teslaPage, "the root place first");
        assertEq(rows[0].positionsEver, 1);
        assertEq(rows[1].place, peopleTesla, "then newest registered first");
        assertEq(rows[2].place, carsTesla);
        assertEq(rows[2].positionsEver, 2);
        assertEq(rows[2].positionsEverBelow, 1, "model_y's tag rolls up");
        assertEq(uint8(info.listingCoverage), uint8(Coverage.COMPLETE));

        (info, rows) = lookup.children(cars[0], _unbound(), "", 0);
        _ok(info);
        assertEq(rows.length, 2);
        assertEq(rows[0].place, carsFord);
        assertEq(rows[1].place, carsTesla);
        assertEq(rows[1].positionsEverBelow, 1);

        // not a word page: INVALID; no record: ABSENT_PROVEN
        (info, rows) = lookup.wordPage(carsTesla, _unbound(), "", 0);
        assertEq(uint8(info.q.status), uint8(Status.INVALID));
        (info, rows) = lookup.children(keccak256("nothing"), _unbound(), "", 0);
        assertEq(uint8(info.q.status), uint8(Status.ABSENT_PROVEN));
    }

    function test_word_page_paging() public {
        bytes32 page = EfsTopics.wordPageId(typeIds[T_TOPIC_WORD], "w");
        bytes32[] memory parents = new bytes32[](20);
        for (uint256 i; i < 20; ++i) {
            parents[i] = _regPath(string.concat("p", vm.toString(i)), 1)[0];
            _child(parents[i], "w", i == 0);
        }
        bytes memory cont;
        uint256 seen;
        uint256 pages;
        while (true) {
            (TopicPageInfo memory info, PlaceCount[] memory rows) =
                lookup.wordPage(page, _unbound(), cont, 6);
            _ok(info);
            ++pages;
            seen += rows.length;
            if (info.next.length == 0) break;
            cont = info.next;
        }
        assertEq(seen, 21, "the root place and 20 paths");
        assertEq(pages, 4);
    }
}

/// @notice Without topic roll-ups: a below count and a word page answer UNKNOWN, never zero.
contract TopicLookupWithoutTopicListsTest is TopicReadersBase {
    function setUp() public override {
        withoutTopicLists = true;
        super.setUp();
    }

    function test_below_counts_are_unknown() public {
        bytes32[] memory t = _regPath("u", 2);
        _tag(alice, t[1], things[0]);
        (Qualified memory q, Coverage c, uint64 n,) =
            lookup.placeCount(Purpose.TAG, t[0], true, _unbound());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        assertEq(n, 0);
        (q,,,) = lookup.entryCount(_pid(alice), Purpose.TAG, t[0], true, _unbound());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        (TopicPageInfo memory info, PlaceCount[] memory rows) =
            lookup.children(t[0], _unbound(), "", 0);
        assertEq(uint8(info.q.status), uint8(Status.UNKNOWN));
        assertEq(rows.length, 0);
        (q,, n,) = lookup.placeCount(Purpose.TAG, t[1], false, _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(n, 1);
    }
}
