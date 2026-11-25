// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {E_REF, E_REJECTED} from "../../src/interfaces/Errors.sol";
import {TopicTypes} from "../../src/profiles/TopicTypes.sol";

/// @notice SPIKE (tags/topics): the two Topics Types on a real Realm. Ids are computed offline, are the same for
///         every author, and one sequence of words has exactly one record; parents and word pages must exist
///         first (the kernel's reference law, including records admitted earlier in the same publication); a
///         withdrawn registration does not unregister the topic.
contract TopicsTest is FilesRecipesBase {
    address internal alice = makeAddr("topics/alice");
    address internal bob = makeAddr("topics/bob");

    function _words(string memory a) internal pure returns (bytes[] memory w) {
        w = new bytes[](1);
        w[0] = bytes(a);
    }

    function _words(string memory a, string memory b) internal pure returns (bytes[] memory w) {
        w = new bytes[](2);
        w[0] = bytes(a);
        w[1] = bytes(b);
    }

    function _words(string memory a, string memory b, string memory c)
        internal
        pure
        returns (bytes[] memory w)
    {
        w = new bytes[](3);
        w[0] = bytes(a);
        w[1] = bytes(b);
        w[2] = bytes(c);
    }

    function _registerPath(address who, bytes[] memory words) internal returns (bytes32 id) {
        (Action[] memory a, bytes[] memory b, bytes32 got) = _pathActions(words, true);
        _execAs(who, a, b);
        return got;
    }

    function _exists(bytes32 id, bytes32 typeId) internal view returns (bool) {
        (bytes32 t, uint64 first,,,) = r.hot.recordHeader(id);
        return t == typeId && first != 0;
    }

    function execExternal(address who, Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _execAs(who, a, b);
    }

    // ---- ids ------------------------------------------------------------------------------------------------

    function test_ids_are_offline_and_the_path_is_the_identity() public {
        bytes32 tesla = _registerPath(alice, _words("cars", "tesla"));
        bytes32 people = _registerPath(alice, _words("people", "tesla"));
        assertTrue(tesla != people, "/cars/tesla and /people/tesla are different topics");
        assertEq(tesla, _pathId(_words("cars", "tesla")));
        assertEq(
            tesla, Keys.record(topicTypeIds[TT_PATH], abi.encode(_wordId("cars"), _wordId("tesla")))
        );
        assertTrue(_exists(tesla, topicTypeIds[TT_PATH]));
        // the word is shared: /tesla is one page under both paths
        assertTrue(_exists(_wordId("tesla"), topicTypeIds[TT_WORD]));
        assertEq(_pathId(_words("tesla")), _wordId("tesla"));
    }

    function test_two_authors_same_ids_second_stores_nothing_new() public {
        bytes[] memory w = _words("cars", "tesla", "model-3");
        bytes32 id = _registerPath(alice, w);
        (, uint64 records,,) = r.hot.counts();
        (bytes32 t, uint64 first,, uint64 occ,) = r.hot.recordHeader(id);
        assertEq(occ, 1);
        bytes32 again = _registerPath(bob, w);
        assertEq(again, id, "same ids for every author");
        (, uint64 records2,,) = r.hot.counts();
        assertEq(records2, records, "the second publication stores no new record");
        (bytes32 t2, uint64 first2,, uint64 occ2,) = r.hot.recordHeader(id);
        assertEq(t2, t);
        assertEq(first2, first, "first admission unchanged");
        assertEq(occ2, 2, "only the occurrence count moved");
    }

    // ---- uniqueness -----------------------------------------------------------------------------------------

    function _refuse(Action[] memory a, bytes[] memory b, bytes memory err) internal {
        vm.expectRevert(err);
        this.execExternal(alice, a, b);
    }

    function _one(Action memory x, bytes memory y)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = x;
        b[0] = y;
    }

    /// One sequence of words has exactly one record: no `topic/1` may stand on a parent of another Type, no body of
    /// another length is admitted, and a one-word `topic/1` cannot be built (no zero or sentinel parent).
    function test_no_second_encoding_of_the_same_words() public {
        bytes32 tesla = _wordId("tesla");
        _registerPath(alice, _words("tesla"));
        bytes32 tt = topicTypeIds[TT_PATH];
        // a name record, a directory record and a file revision as the parent: refused by the rule (12)
        (Action memory n, bytes memory nb) = _name("cars");
        (Action[] memory a, bytes[] memory b) = _one(n, nb);
        _execAs(alice, a, b);
        bytes32[] memory parents = new bytes32[](2);
        parents[0] = Keys.record(typeIds[T_NAME], "cars");
        parents[1] = rootDir;
        for (uint256 i; i < parents.length; ++i) {
            (Action memory x, bytes memory y) = _topicRecord(parents[i], tesla);
            (a, b) = _one(x, y);
            _refuse(a, b, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), tt));
        }
        // a body of any other length: 96 bytes refused by the rule, 32 or 63 by the reference law
        bytes32 cars = _registerPath(alice, _words("cars"));
        bytes[3] memory odd = [
            abi.encode(cars, tesla, bytes32(0)),
            abi.encode(cars),
            abi.encodePacked(cars, bytes31(0))
        ];
        bytes[3] memory why = [
            abi.encodeWithSelector(E_REJECTED.selector, uint8(0), tt),
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1)),
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1))
        ];
        for (uint256 i; i < 3; ++i) {
            Action memory x;
            x.kind = ActionKind.PUBLISH;
            x.typeId = tt;
            x.bodyHashOrRecordId = keccak256(odd[i]);
            (a, b) = _one(x, odd[i]);
            _refuse(a, b, why[i]);
        }
        // a one-word topic/1: a zero or sentinel parent is refused by the kernel (E_REF code 3)
        (Action memory z, bytes memory zb) = _topicRecord(bytes32(0), tesla);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(3)));
        (z, zb) = _topicRecord(bytes32(uint256(1)), tesla);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(3)));
        // the second word must be a word page (a topic record is the wrong Type: E_REF code 2)
        bytes32 ct = _registerPath(alice, _words("cars", "tesla"));
        (z, zb) = _topicRecord(cars, ct);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(2)));
        // and the one encoding that remains is the one pathId names
        assertEq(ct, _pathId(_words("cars", "tesla")));
    }

    function test_a_file_revision_is_not_a_parent() public {
        _registerPath(alice, _words("tesla"));
        (Action[] memory fa, bytes[] memory fb,,) = _fileActions();
        _exec("seed file", fa, fb);
        bytes32 revision = Keys.record(typeIds[T_ROOT], fb[1]);
        (Action memory x, bytes memory y) = _topicRecord(revision, _wordId("tesla"));
        (Action[] memory a, bytes[] memory b) = _one(x, y);
        _refuse(a, b, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), topicTypeIds[TT_PATH]));
    }

    function _fileActions()
        internal
        view
        returns (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rev)
    {
        file = Keys.subject(p, keccak256("topics/file"));
        a = new Action[](2);
        b = new bytes[](2);
        a[0] = _create(keccak256("topics/file"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "hello"));
        rev = Keys.record(typeIds[T_ROOT], b[1]);
    }

    // ---- order ----------------------------------------------------------------------------------------------

    /// Word pages, then /a/b, then /a/b/c in ONE publication: each child's parent was admitted earlier in the same
    /// publication, which satisfies the reference law.
    function test_parents_earlier_in_the_same_publication() public {
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            _pathActions(_words("a", "b", "c"), true);
        assertEq(a.length, 5);
        _execAs(alice, a, b);
        assertTrue(_exists(id, topicTypeIds[TT_PATH]));
    }

    function test_wrong_order_is_refused() public {
        (Action[] memory a, bytes[] memory b,) = _pathActions(_words("a", "b", "c"), true);
        // /a/b/c before /a/b: the parent is missing at leaf 3
        (a[3], a[4]) = (a[4], a[3]);
        (b[3], b[4]) = (b[4], b[3]);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(3), uint8(0), uint8(1)));
        // /a/b before the page of b: the word page is missing at leaf 1
        (a, b,) = _pathActions(_words("a", "b", "c"), true);
        Action[] memory a2 = new Action[](5);
        bytes[] memory b2 = new bytes[](5);
        uint256[5] memory order = [uint256(0), 3, 1, 2, 4];
        for (uint256 i; i < 5; ++i) {
            a2[i] = a[order[i]];
            b2[i] = b[order[i]];
        }
        _refuse(a2, b2, abi.encodeWithSelector(E_REF.selector, uint8(1), uint8(1), uint8(1)));
    }

    // ---- depth ----------------------------------------------------------------------------------------------

    function test_a_64_word_path() public {
        bytes[] memory w = new bytes[](64);
        for (uint256 i; i < 64; ++i) {
            w[i] = abi.encodePacked("w", vm.toString(i));
        }
        // in chunks of 16 registrations, parents first
        (Action[] memory a, bytes[] memory b, bytes32 id) = _pathActions(w, true);
        for (uint256 from; from < a.length; from += 16) {
            uint256 k = a.length - from < 16 ? a.length - from : 16;
            Action[] memory ca = new Action[](k);
            bytes[] memory cb = new bytes[](k);
            for (uint256 i; i < k; ++i) {
                ca[i] = a[from + i];
                cb[i] = b[from + i];
            }
            _execAs(alice, ca, cb);
        }
        assertTrue(_exists(id, topicTypeIds[TT_PATH]));
        assertEq(id, TopicTypes.pathId(topicTypeIds[TT_WORD], topicTypeIds[TT_PATH], w));
    }

    // ---- permanence -----------------------------------------------------------------------------------------

    /// After the first registrant withdraws their admissions of a topic and of its word page, anyone can still
    /// publish a child of it and tag it: a withdrawal decrements occurrences, never erases the record.
    function test_withdrawn_registration_still_works() public {
        (uint64 before,,,) = r.hot.counts();
        bytes32 id = _registerPath(alice, _words("cars", "tesla")); // admissions before+1..+3: cars, tesla, /cars/tesla
        Action[] memory w = new Action[](2);
        w[0].kind = ActionKind.WITHDRAW;
        w[0].target = bytes32(uint256(before + 3));
        w[1].kind = ActionKind.WITHDRAW;
        w[1].target = bytes32(uint256(before + 1));
        _execAs(alice, w, new bytes[](2));
        (,,, uint64 occ,) = r.hot.recordHeader(id);
        assertEq(occ, 0, "no live registration");
        // bob: a child of the withdrawn topic and a tag on it
        (Action memory pg, bytes memory pb) = _wordPage("model-3");
        (Action memory c, bytes memory cb) = _topicRecord(id, _wordId("model-3"));
        bytes32 thing = Keys.subject(Keys.principal(bob), keccak256("thing"));
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        (a[0], b[0]) = (pg, pb);
        (a[1], b[1]) = (c, cb);
        a[2] = _create(keccak256("thing"));
        a[3] = _bind(Purpose.TAG, id, thing, thing, 0);
        _execAs(bob, a, b);
        assertTrue(
            _exists(
                TopicTypes.childId(topicTypeIds[TT_PATH], id, _wordId("model-3")),
                topicTypeIds[TT_PATH]
            )
        );
        (uint8 st,,,,,,) =
            r.hot.head(Keys.binding(Keys.principal(bob), Keys.position(Purpose.TAG, id, thing)));
        assertEq(st, 1, "the tag stands");
    }
}
