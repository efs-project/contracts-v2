// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsBase} from "./TopicListsBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice The two counters the first-statement lists keep beside their entries (design §10.2):
///         - `position-authors` (20): `count` = the authors who ever made a statement at the position, `live` = the
///           authors whose head there is BOUND now (the yes-count). Every transition is a named step below, and after
///           every step `live` equals a walk of the authors' heads at the position, never underflows and never exceeds
///           `count`.
///         - `place` (6) and `place-below` (7): `count` = filings (the first statement at a fresh position and every
///           later author's first yes), `live` = the distinct positions ever stated there (an "about" count).
contract TopicListsCountsTest is TopicListsBase {
    address internal dave = makeAddr("lists/dave");
    uint8 internal constant BOUND = 1;

    /// The yes-count at a position, computed independently: the authors whose head there is BOUND.
    function _bound(bytes32 purpose, bytes32 subject, bytes32 role, address[] memory who)
        internal
        view
        returns (uint64 n, uint64 stated)
    {
        bytes32 position = Keys.position(purpose, subject, role);
        for (uint256 i; i < who.length; ++i) {
            (uint8 state,,,,,,,) = r.hot.head(Keys.binding(_pid(who[i]), position));
            if (state == BOUND) ++n;
            if (state != 0) ++stated;
        }
    }

    function _who() internal view returns (address[] memory w) {
        w = new address[](5);
        (w[0], w[1], w[2], w[3], w[4]) = (address(this), alice, bob, carol, dave);
    }

    /// After every step: `live` is the walk of the heads, `count` the authors who ever stated, and the step moved
    /// `live` by exactly `delta`.
    function _step(
        bytes32 purpose,
        bytes32 subject,
        bytes32 role,
        uint64 before,
        int8 delta,
        string memory what
    ) internal view returns (uint64 live) {
        (uint64 walk, uint64 stated) = _bound(purpose, subject, role, _who());
        uint64 count;
        (count, live) = _head(F_POSITION_AUTHORS, 0, Keys.position(purpose, subject, role));
        assertEq(live, walk, string.concat(what, ": live = the BOUND heads"));
        assertEq(count, stated, string.concat(what, ": count = the authors who ever stated"));
        assertLe(live, count, string.concat(what, ": live <= count"));
        assertEq(int256(uint256(live)) - int256(uint256(before)), delta, what);
    }

    function test_tag_yes_count_follows_every_transition() public {
        bytes32 topic = _regPath("yes", 2)[1];
        bytes32 thing = things[0];
        bytes32 P = Purpose.TAG;
        uint64 y;
        _tag(alice, topic, thing);
        y = _step(P, topic, thing, 0, 1, "first yes");
        _deny(bob, topic, thing);
        y = _step(P, topic, thing, y, 0, "a first negative appends, the yes-count unchanged");
        _deny(bob, topic, thing);
        y = _step(P, topic, thing, y, 0, "a mask of a mask");
        _release(bob, topic, thing);
        y = _step(P, topic, thing, y, 0, "a release of a mask");
        _tag(bob, topic, thing);
        y = _step(P, topic, thing, y, 1, "a restore from released");
        _tagN(alice, topic, thing, 75);
        y = _step(P, topic, thing, y, 0, "a number change within yes");
        _tagN(alice, topic, thing, 3);
        y = _step(P, topic, thing, y, 0, "another number change");
        _deny(alice, topic, thing);
        y = _step(P, topic, thing, y, -1, "a mask of an asserted head");
        _tag(alice, topic, thing);
        y = _step(P, topic, thing, y, 1, "a restore from masked");
        _release(alice, topic, thing);
        y = _step(P, topic, thing, y, -1, "a release of an asserted head");
        _tag(alice, topic, thing);
        y = _step(P, topic, thing, y, 1, "yes -> released -> yes");
        _deny(carol, topic, thing);
        y = _step(P, topic, thing, y, 0, "a third author's lone negative");
        _release(carol, topic, thing);
        y = _step(P, topic, thing, y, 0, "a lone negative later released");
        _deny(carol, topic, thing);
        y = _step(P, topic, thing, y, 0, "no -> released -> no");
        _tag(carol, topic, thing);
        y = _step(P, topic, thing, y, 1, "no -> yes");
        _tag(dave, topic, thing);
        y = _step(P, topic, thing, y, 1, "a fourth author's first yes");
        assertEq(y, 4, "four authors say yes");
        address[4] memory all = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            _deny(all[i], topic, thing);
            y = _step(P, topic, thing, y, -1, "everyone masks");
        }
        assertEq(y, 0, "nobody says yes");
        _release(bob, topic, thing);
        y = _step(P, topic, thing, y, 0, "a release of a mask at zero: no underflow");
        _deny(bob, topic, thing);
        y = _step(P, topic, thing, y, 0, "a mask of a released head at zero");
    }

    function test_folder_yes_count_follows_every_transition() public {
        bytes32 role = keccak256("count.txt");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _name("count.txt");
        _execAs(address(this), a, b);
        bytes32 home = bytes32(uint256(uint160(alice)));
        bytes32 P = Purpose.FOLDER;
        uint64 y;
        _act(alice, _bind(P, home, role, things[0], 0));
        y = _step(P, home, role, 0, 1, "first yes");
        _act(alice, _bind(P, home, role, things[1], _rev(alice, P, home, role)));
        y = _step(P, home, role, y, 0, "a re-bind to another target is still a yes");
        _act(
            alice,
            EfsFiles.bindWithStrength(P, home, role, things[1], _rev(alice, P, home, role), 7)
        );
        y = _step(P, home, role, y, 0, "a number change on the same target");
        _act(bob, _bind(P, home, role, things[2], 0));
        y = _step(P, home, role, y, 1, "a second author's first yes");
        _act(bob, EfsFiles.unbind(P, home, role, _rev(bob, P, home, role)));
        y = _step(P, home, role, y, -1, "a mask of an asserted head");
        _act(bob, EfsFiles.unbind(P, home, role, _rev(bob, P, home, role)));
        y = _step(P, home, role, y, 0, "a mask of a mask");
        _act(bob, _bind(P, home, role, things[3], _rev(bob, P, home, role)));
        y = _step(P, home, role, y, 1, "a restore from masked, to another target");
        _act(alice, EfsFiles.release(P, home, role, _rev(alice, P, home, role)));
        y = _step(P, home, role, y, -1, "a release of an asserted head");
        _act(alice, _bind(P, home, role, things[1], _rev(alice, P, home, role)));
        y = _step(P, home, role, y, 1, "a restore from released");
        _act(carol, EfsFiles.unbind(P, home, role, 0));
        y = _step(P, home, role, y, 0, "a lone hide of the others' entry");
        _act(carol, EfsFiles.release(P, home, role, _rev(carol, P, home, role)));
        y = _step(P, home, role, y, 0, "the lone hide released");
        _act(carol, _bind(P, home, role, things[4], _rev(carol, P, home, role)));
        y = _step(P, home, role, y, 1, "no -> released -> yes");
        assertEq(y, 3);
    }

    /// `place` and `place-below`: one filing per fresh position (either sign) and per later author's first yes; a later
    /// author's first no and an author's yes after a first no file nothing; `live` counts the distinct positions.
    function test_place_files_every_first_yes_and_live_counts_distinct_positions() public {
        bytes32[] memory t = _regPath("filed", 3);
        bytes32 topic = t[2];
        bytes32 x = things[0];
        bytes32 y = things[1];
        _deny(alice, topic, x); // fresh position, a no: filed and counted
        uint64 ox = _ordinal(alice, Purpose.TAG, topic, x);
        _tag(bob, topic, x); // a later author's first yes: filed, not counted
        uint64 bx = _ordinal(bob, Purpose.TAG, topic, x);
        _deny(carol, topic, x); // a later author's first no: nothing
        _tag(carol, topic, x); // carol's yes after her first no: nothing (deliberate)
        _tag(alice, topic, x); // alice's yes after her first no: nothing
        _tag(dave, topic, y); // a second position, fresh, a yes
        uint64 dy = _ordinal(dave, Purpose.TAG, topic, y);
        _tag(alice, topic, y); // a later first yes at y
        uint64 ay = _ordinal(alice, Purpose.TAG, topic, y);
        uint64[] memory filings = new uint64[](4);
        (filings[0], filings[1], filings[2], filings[3]) = (ox, bx, dy, ay);
        _eq(_place(Purpose.TAG, topic), filings, "place: in order of filing");
        (uint64 c, uint64 l) = _head(F_PLACE, Purpose.TAG, topic);
        assertEq(abi.encode(c, l), abi.encode(uint64(4), uint64(2)), "four filings, two positions");
        for (uint256 j; j < 2; ++j) {
            _eq(_placeBelow(t[j]), filings, "place-below: the same filings");
            (c, l) = _head(F_PLACE_BELOW, Purpose.TAG, t[j]);
            assertEq(abi.encode(c, l), abi.encode(uint64(4), uint64(2)), "place-below counts");
        }
        // role-places stays one entry per fresh position
        _eq(_rolePlaces(Purpose.TAG, x), _list1(ox), "role-places x");
        _eq(_rolePlaces(Purpose.TAG, y), _list1(dy), "role-places y");
        // no author adds more than one entry per position, whatever they do later
        _release(bob, topic, x);
        _tag(bob, topic, x);
        _deny(dave, topic, y);
        _tag(dave, topic, y);
        _eq(_place(Purpose.TAG, topic), filings, "no later action files again");
    }
}
