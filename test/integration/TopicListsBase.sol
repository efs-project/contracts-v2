// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, FamilyId, Purpose, TypeId} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";

/// @notice Helpers for the first-statement list suites (design §10.2 kinds 6, 7, 19, 20, 21) on the real Files Realm
///         with the real Topics Types and `FilesFinalValidator`: path registration split at 64 actions, statements
///         by any author, and list reads through the index's own posting reads (`postingHeadOf`/`postingSliceOf`,
///         coverage asserted COMPLETE). Readers of these lists are step 4; nothing here is one.
abstract contract TopicListsBase is FilesRecipesBase {
    bytes32 internal F_PLACE = Keys.familyId("place");
    bytes32 internal F_PLACE_BELOW = Keys.familyId("place-below");
    bytes32 internal F_SCOPE_BELOW = Keys.familyId("scope-below");
    bytes32 internal F_POSITION_AUTHORS = Keys.familyId("position-authors");
    bytes32 internal F_ROLE_PLACES = Keys.familyId("role-places");

    address internal alice = makeAddr("lists/alice");
    address internal bob = makeAddr("lists/bob");
    address internal carol = makeAddr("lists/carol");
    bytes32[] internal things; // CREATE subjects of p

    function setUp() public virtual override {
        super.setUp();
        Action[] memory a = new Action[](16);
        for (uint256 i; i < 16; ++i) {
            a[i] = _create(keccak256(abi.encode("lists/thing", i)));
            things.push(Keys.subject(p, a[i].saltOrStrength));
        }
        _execAs(address(this), a, new bytes[](16));
    }

    // ---- statements -------------------------------------------------------------------------------------------

    function _pid(address who) internal view returns (bytes32) {
        return who == address(this) ? p : Keys.principal(who);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _act(address who, Action memory x) internal {
        _execAs(who, _one(x), new bytes[](1));
    }

    function _rev(address who, bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        view
        returns (uint64 revision)
    {
        (, revision,,,,,,) =
            r.hot.head(Keys.binding(_pid(who), Keys.position(purpose, subject, role)));
    }

    function _ordinal(address who, bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        view
        returns (uint64 o)
    {
        (,,,,, o,,) = r.hot.head(Keys.binding(_pid(who), Keys.position(purpose, subject, role)));
    }

    function _admission(address who, bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        view
        returns (uint64 a)
    {
        (,, a,,,,,) = r.hot.head(Keys.binding(_pid(who), Keys.position(purpose, subject, role)));
    }

    /// A tag (`strength` 0) at the head's current revision: a first tag, a re-assert or a number change.
    function _tag(address who, bytes32 topic, bytes32 thing) internal {
        _act(who, EfsTopics.tag(topic, thing, _rev(who, Purpose.TAG, topic, thing), 0));
    }

    function _tagN(address who, bytes32 topic, bytes32 thing, uint16 n) internal {
        _act(who, EfsTopics.tag(topic, thing, _rev(who, Purpose.TAG, topic, thing), n));
    }

    /// "Not this" at the head's current revision (a lone negative when the author never said anything there).
    function _deny(address who, bytes32 topic, bytes32 thing) internal {
        _act(who, EfsTopics.deny(topic, thing, _rev(who, Purpose.TAG, topic, thing), 0));
    }

    function _release(address who, bytes32 topic, bytes32 thing) internal {
        _act(who, EfsFiles.release(Purpose.TAG, topic, thing, _rev(who, Purpose.TAG, topic, thing)));
    }

    // ---- topics -------------------------------------------------------------------------------------------------

    function _words(string memory name, uint256 n) internal pure returns (bytes[] memory w) {
        w = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = bytes(string.concat(name, "-", vm.toString(i)));
        }
    }

    /// Every prefix id of the path `words`: t[i] is the topic of the first i + 1 words.
    function _prefixes(bytes[] memory words) internal view returns (bytes32[] memory t) {
        EfsTopics.Types memory tt = _topicTypes();
        t = new bytes32[](words.length);
        t[0] = EfsTopics.wordPageId(tt.word, words[0]);
        for (uint256 i = 1; i < words.length; ++i) {
            t[i] = EfsTopics.childId(tt.topic, t[i - 1], EfsTopics.wordPageId(tt.word, words[i]));
        }
    }

    /// Registers the path `<name>-0/.../<name>-(n-1)` (pages first, then records; 64 actions per publication).
    function _regPath(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        bytes[] memory w = _words(name, n);
        (Action[] memory a, bytes[] memory b,) = EfsTopics.registerPath(_topicTypes(), w);
        for (uint256 from; from < a.length; from += 64) {
            uint256 m = a.length - from < 64 ? a.length - from : 64;
            (Action[] memory x, bytes[] memory y) = EfsFiles.slice(a, b, from, from + m);
            _execAs(address(this), x, y);
        }
        t = _prefixes(w);
    }

    // ---- list reads (the index's posting reads) ----------------------------------------------------------------------

    function _head(bytes32 family, bytes32 typeId, bytes32 value)
        internal
        view
        returns (uint64 count, uint64 live)
    {
        Coverage c;
        (c, count, live,,) =
            r.g.index.postingHeadOf(FamilyId.wrap(family), TypeId.wrap(typeId), 0, value);
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "list coverage");
    }

    function _entries(bytes32 family, bytes32 typeId, bytes32 value)
        internal
        view
        returns (uint64[] memory e)
    {
        Coverage c;
        (c, e,) =
            r.g.index.postingSliceOf(FamilyId.wrap(family), TypeId.wrap(typeId), 0, value, 0, 512);
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "list coverage");
    }

    function _scopeBelow(address who, bytes32 ancestor) internal view returns (uint64[] memory) {
        return _entries(F_SCOPE_BELOW, 0, Keys.scopeBelow(_pid(who), Purpose.TAG, ancestor));
    }

    function _placeBelow(bytes32 ancestor) internal view returns (uint64[] memory) {
        return _entries(F_PLACE_BELOW, Purpose.TAG, ancestor);
    }

    function _place(bytes32 purpose, bytes32 subject) internal view returns (uint64[] memory) {
        return _entries(F_PLACE, purpose, subject);
    }

    function _authors(bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        view
        returns (uint64[] memory)
    {
        return _entries(F_POSITION_AUTHORS, 0, Keys.position(purpose, subject, role));
    }

    function _rolePlaces(bytes32 purpose, bytes32 role) internal view returns (uint64[] memory) {
        return _entries(F_ROLE_PLACES, purpose, role);
    }

    function _eq(uint64[] memory x, uint64[] memory y, string memory what) internal pure {
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), what);
    }

    function _list1(uint64 a) internal pure returns (uint64[] memory x) {
        x = new uint64[](1);
        x[0] = a;
    }

    function _list2(uint64 a, uint64 b) internal pure returns (uint64[] memory x) {
        x = new uint64[](2);
        x[0] = a;
        x[1] = b;
    }
}
