// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, ActionKind, FamilyId, Purpose, TypeId} from "../../src/interfaces/Actions.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {E_REF, E_REJECTED} from "../../src/interfaces/Errors.sol";
import {TopicTypes} from "../../src/profiles/TopicTypes.sol";

/// @notice The two topic Types on a real Realm (design §12.5; docs/TAG-DESIGN.md §1). Ids are computed offline, are
///         the same for every author, and one sequence of words has exactly one record; parents and word pages must
///         exist first (the kernel's reference law, including records admitted earlier in the same publication); a
///         withdrawn registration does not unregister the topic; a 64-word path registers.
contract TopicsTest is FilesRecipesBase {
    address internal alice = makeAddr("topics/alice");
    address internal bob = makeAddr("topics/bob");
    EfsTopics.Types internal tt;

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
    }

    function _w(string memory a) internal pure returns (bytes[] memory w) {
        w = new bytes[](1);
        w[0] = bytes(a);
    }

    function _w(string memory a, string memory b) internal pure returns (bytes[] memory w) {
        w = new bytes[](2);
        w[0] = bytes(a);
        w[1] = bytes(b);
    }

    function _w(string memory a, string memory b, string memory c)
        internal
        pure
        returns (bytes[] memory w)
    {
        w = new bytes[](3);
        w[0] = bytes(a);
        w[1] = bytes(b);
        w[2] = bytes(c);
    }

    function _register(address who, bytes[] memory words) internal returns (bytes32 id) {
        (Action[] memory a, bytes[] memory b, bytes32 got) = EfsTopics.registerPath(tt, words);
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

    function _pathRecord(bytes32 parent, bytes32 page)
        internal
        view
        returns (Action memory a, bytes memory body)
    {
        body = EfsTopics.pathBody(parent, page);
        (a,) = _publish(T_TOPIC, body);
    }

    // ---- ids ------------------------------------------------------------------------------------------------

    function test_ids_are_offline_and_the_path_is_the_identity() public {
        bytes32 tesla = _register(alice, _w("cars", "tesla"));
        bytes32 people = _register(alice, _w("people", "tesla"));
        assertTrue(tesla != people, "/cars/tesla and /people/tesla are different topics");
        assertEq(tesla, EfsTopics.pathId(tt, _w("cars", "tesla")));
        assertEq(tesla, TopicTypes.pathId(tt.word, tt.topic, _w("cars", "tesla")));
        assertEq(
            tesla,
            Keys.record(
                tt.topic, abi.encode(Keys.record(tt.word, "cars"), Keys.record(tt.word, "tesla"))
            )
        );
        assertTrue(_exists(tesla, tt.topic));
        // the word is shared: /tesla is one page under both paths, and it is the one-word topic
        assertTrue(_exists(EfsTopics.wordPageId(tt.word, "tesla"), tt.word));
        assertEq(EfsTopics.pathId(tt, _w("tesla")), EfsTopics.wordPageId(tt.word, "tesla"));
        assertEq(EfsTopics.pathId(tt, new bytes[](0)), bytes32(0), "the empty path is no topic");
    }

    function test_two_authors_same_ids_second_stores_nothing_new() public {
        bytes[] memory w = _w("cars", "tesla", "model-3");
        bytes32 id = _register(alice, w);
        (, uint64 records,,) = r.hot.counts();
        (bytes32 t, uint64 first,, uint64 occ,) = r.hot.recordHeader(id);
        assertEq(occ, 1);
        bytes32 again = _register(bob, w);
        assertEq(again, id, "same ids for every author");
        (, uint64 records2,,) = r.hot.counts();
        assertEq(records2, records, "the second publication stores no new record");
        (bytes32 t2, uint64 first2,, uint64 occ2,) = r.hot.recordHeader(id);
        assertEq(t2, t);
        assertEq(first2, first, "first admission unchanged");
        assertEq(occ2, 2, "only the occurrence count moved");
    }

    // ---- uniqueness -----------------------------------------------------------------------------------------

    /// One sequence of words has exactly one record: no `topic/1` stands on a parent of another Type (a name, a
    /// directory, a text, a file revision), no body of another length is admitted, and a one-word `topic/1`
    /// cannot be built (no zero or sentinel parent).
    function test_no_second_encoding_of_the_same_words() public {
        bytes32 tesla = _register(alice, _w("tesla"));
        bytes32 rejected = bytes32(0);
        bytes memory refusedByRule = abi.encodeWithSelector(E_REJECTED.selector, uint8(0), tt.topic);
        // other Types as the parent: refused by the rule (code 12, reported as E_REJECTED)
        (Action memory n, bytes memory nb) = _name("cars");
        (Action memory x, bytes memory xb) = _publish(T_TEXT, "Cars");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (n, nb);
        (a[1], b[1]) = (x, xb);
        _execAs(alice, a, b);
        bytes32[3] memory parents =
            [Keys.record(typeIds[T_NAME], "cars"), rootDir, Keys.record(typeIds[T_TEXT], "Cars")];
        for (uint256 i; i < parents.length; ++i) {
            (Action memory pr, bytes memory pb) = _pathRecord(parents[i], tesla);
            (a, b) = _one(pr, pb);
            _refuse(a, b, refusedByRule);
        }
        // a body of any other length: 96 bytes refused by the rule, 32 or 63 by the reference law
        bytes32 cars = _register(alice, _w("cars"));
        bytes[3] memory odd = [
            abi.encode(cars, tesla, rejected), abi.encode(cars), abi.encodePacked(cars, bytes31(0))
        ];
        bytes[3] memory why = [
            refusedByRule,
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1)),
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1))
        ];
        for (uint256 i; i < 3; ++i) {
            (Action memory pr,) = _publish(T_TOPIC, odd[i]);
            (a, b) = _one(pr, odd[i]);
            _refuse(a, b, why[i]);
        }
        // a one-word topic/1: a zero or sentinel parent is refused by the kernel (E_REF code 3)
        (Action memory z, bytes memory zb) = _pathRecord(bytes32(0), tesla);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(3)));
        (z, zb) = _pathRecord(bytes32(uint256(1)), tesla);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(3)));
        // the second word must be a word page (a topic record is the wrong Type: E_REF code 2)
        bytes32 ct = _register(alice, _w("cars", "tesla"));
        (z, zb) = _pathRecord(cars, ct);
        (a, b) = _one(z, zb);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(2)));
        // and the one encoding that remains is the one pathId names
        assertEq(ct, EfsTopics.pathId(tt, _w("cars", "tesla")));
    }

    // ---- the refs the rule judges are the body words ----------------------------------------------------------

    function _refCount(uint8 ordinal, bytes32 value) internal view returns (uint64 count) {
        Coverage c;
        (c, count,,,) = r.g.index
            .postingHeadOf(FamilyId.wrap(F_REFERENCE), TypeId.wrap(tt.topic), ordinal, value);
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "honest coverage");
    }

    function _tail(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    /// An `Action` carries no refs: the kernel (`LedgerIngress._resolveRefs`) reads reference i from body word i of
    /// the bytes it hashes and stores, and hands that same body and those refs to `TopicRule.accept`. Recorded here
    /// on the real kernel: the one `accept` call for `topic/1` carries refs equal to the body's two words, and the
    /// stored record's words and its reference-position index entries are exactly those two records. The swapped
    /// body is a different record with swapped entries, so no `topic/1` record exists whose words differ from what
    /// the rule judged.
    function test_the_judged_refs_are_the_body_words() public {
        bytes32 cars = _register(alice, _w("cars"));
        bytes32 tesla = _register(alice, _w("tesla"));
        (Action memory x, bytes memory body) = _pathRecord(cars, tesla);
        (Action[] memory a, bytes[] memory b) = _one(x, body);
        vm.startStateDiffRecording();
        _execAs(alice, a, b);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 calls;
        for (uint256 i; i < acc.length; ++i) {
            bytes memory data = acc[i].data;
            if (data.length < 4 || bytes4(data) != IAcceptor.accept.selector) continue;
            (
                AcceptContext memory ctx,
                bytes memory seen,
                bytes32[] memory refs,
                RefHeader[] memory h
            ) = abi.decode(_tail(data), (AcceptContext, bytes, bytes32[], RefHeader[]));
            if (ctx.typeId != tt.topic) continue;
            ++calls;
            assertEq(seen, body, "the rule sees the published body");
            assertEq(refs.length, 2);
            assertEq(refs[0], cars, "ref 0 is body word 0");
            assertEq(refs[1], tesla, "ref 1 is body word 1");
            assertEq(h[0].typeId, tt.word);
            assertEq(h[1].typeId, tt.word);
        }
        assertEq(calls, 1, "one accept call for the topic/1 record");
        bytes32 id = Keys.record(tt.topic, body);
        assertEq(id, EfsTopics.pathId(tt, _w("cars", "tesla")));
        (bytes32 word, bytes32 parent) = _pathOf(id);
        assertEq(parent, cars, "stored word 0");
        assertEq(word, tesla, "stored word 1");
        assertEq(_refCount(0, cars), 1, "slot 0 entry: the parent");
        assertEq(_refCount(1, tesla), 1, "slot 1 entry: the word page");
        assertEq(_refCount(0, tesla), 0);
        assertEq(_refCount(1, cars), 0);
        // the swapped body [tesla, cars] is /tesla/cars: another record, with the entries swapped
        (x, body) = _pathRecord(tesla, cars);
        (a, b) = _one(x, body);
        _execAs(alice, a, b);
        (word, parent) = _pathOf(Keys.record(tt.topic, body));
        assertEq(abi.encode(parent, word), abi.encode(tesla, cars));
        assertEq(_refCount(0, tesla), 1);
        assertEq(_refCount(1, cars), 1);
        assertEq(_refCount(0, cars), 1, "unchanged");
        assertEq(_refCount(1, tesla), 1, "unchanged");
        // a body word that is not a record is refused by the reference law before any rule runs
        (x, body) = _pathRecord(cars, keccak256("not a record"));
        (a, b) = _one(x, body);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1)));
    }

    function test_a_file_revision_is_not_a_parent() public {
        bytes32 tesla = _register(alice, _w("tesla"));
        bytes32 file = Keys.subject(p, keccak256("topics/file"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("topics/file"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "hello"));
        _exec("topics: seed a file", a, b);
        bytes32 revision = Keys.record(typeIds[T_ROOT], b[1]);
        (Action memory x, bytes memory y) = _pathRecord(revision, tesla);
        (a, b) = _one(x, y);
        _refuse(a, b, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), tt.topic));
    }

    // ---- order ----------------------------------------------------------------------------------------------

    /// Word pages, then /a/b, then /a/b/c in ONE publication: each child's parent was admitted earlier in the same
    /// publication, which satisfies the reference law.
    function test_parents_earlier_in_the_same_publication() public {
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerPath(tt, _w("a", "b", "c"));
        assertEq(a.length, 5);
        _execAs(alice, a, b);
        assertTrue(_exists(id, tt.topic));
        assertTrue(_exists(EfsTopics.pathId(tt, _w("a", "b")), tt.topic));
    }

    function test_wrong_order_is_refused() public {
        (Action[] memory a, bytes[] memory b,) = EfsTopics.registerPath(tt, _w("a", "b", "c"));
        // /a/b/c before /a/b: the parent is missing at leaf 3
        (a[3], a[4]) = (a[4], a[3]);
        (b[3], b[4]) = (b[4], b[3]);
        _refuse(a, b, abi.encodeWithSelector(E_REF.selector, uint8(3), uint8(0), uint8(1)));
        // /a/b before the page of b: the word page is missing at leaf 1
        (a, b,) = EfsTopics.registerPath(tt, _w("a", "b", "c"));
        Action[] memory a2 = new Action[](5);
        bytes[] memory b2 = new bytes[](5);
        uint256[5] memory order = [uint256(0), 3, 1, 2, 4];
        for (uint256 i; i < 5; ++i) {
            a2[i] = a[order[i]];
            b2[i] = b[order[i]];
        }
        _refuse(a2, b2, abi.encodeWithSelector(E_REF.selector, uint8(1), uint8(1), uint8(1)));
    }

    function test_register_a_child_on_an_existing_topic() public {
        bytes32 cars = _register(alice, _w("cars"));
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerChild(tt, cars, "tesla", true);
        assertEq(a.length, 2);
        _execAs(bob, a, b);
        assertEq(id, EfsTopics.pathId(tt, _w("cars", "tesla")));
        (a, b, id) = EfsTopics.registerChild(tt, id, "tesla", false); // the page exists: /cars/tesla/tesla
        assertEq(a.length, 1);
        _execAs(bob, a, b);
        assertEq(id, EfsTopics.pathId(tt, _w("cars", "tesla", "tesla")));
        assertTrue(_exists(id, tt.topic));
    }

    // ---- depth ----------------------------------------------------------------------------------------------

    function test_a_64_word_path() public {
        bytes[] memory w = new bytes[](64);
        for (uint256 i; i < 64; ++i) {
            w[i] = abi.encodePacked("w", vm.toString(i));
        }
        // 127 registrations in publications of at most 32 actions, parents first
        (Action[] memory a, bytes[] memory b, bytes32 id) = EfsTopics.registerPath(tt, w);
        assertEq(a.length, 127);
        for (uint256 from; from < a.length; from += 32) {
            uint256 k = a.length - from < 32 ? a.length - from : 32;
            Action[] memory ca = new Action[](k);
            bytes[] memory cb = new bytes[](k);
            for (uint256 i; i < k; ++i) {
                ca[i] = a[from + i];
                cb[i] = b[from + i];
            }
            _execAs(alice, ca, cb);
        }
        assertTrue(_exists(id, tt.topic));
        assertEq(id, TopicTypes.pathId(tt.word, tt.topic, w));
        // walking the parents from the leaf reaches the first word's page in 63 steps
        bytes32 at = id;
        for (uint256 i = 63; i > 0; --i) {
            (, bytes32 parent) = _pathOf(at);
            at = parent;
        }
        assertEq(at, EfsTopics.wordPageId(tt.word, "w0"));
    }

    function _pathOf(bytes32 id) internal view returns (bytes32 word, bytes32 parent) {
        parent = r.hot.bodyWord(id, 0);
        word = r.hot.bodyWord(id, 1);
    }

    // ---- permanence -----------------------------------------------------------------------------------------

    /// After the first registrant withdraws their admissions of a topic and of its word page, anyone can still
    /// publish a child of it and tag it: a withdrawal decrements occurrences, never erases the record.
    function test_withdrawn_registration_still_works() public {
        (uint64 before,,,) = r.hot.counts();
        bytes32 id = _register(alice, _w("cars", "tesla")); // admissions before+1..+3: cars, tesla, /cars/tesla
        Action[] memory w = new Action[](2);
        w[0].kind = ActionKind.WITHDRAW;
        w[0].target = bytes32(uint256(before + 3));
        w[1].kind = ActionKind.WITHDRAW;
        w[1].target = bytes32(uint256(before + 1));
        _execAs(alice, w, new bytes[](2));
        (,,, uint64 occ,) = r.hot.recordHeader(id);
        assertEq(occ, 0, "no live registration");
        // bob: a child of the withdrawn topic and a tag on it
        (Action[] memory ra, bytes[] memory rb, bytes32 child) =
            EfsTopics.registerChild(tt, id, "model-3", true);
        bytes32 thing = Keys.subject(Keys.principal(bob), keccak256("thing"));
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        (a[0], b[0]) = (ra[0], rb[0]);
        (a[1], b[1]) = (ra[1], rb[1]);
        a[2] = _create(keccak256("thing"));
        a[3] = EfsTopics.tag(id, thing, 0, 0);
        _execAs(bob, a, b);
        assertTrue(_exists(child, tt.topic));
        (uint8 st,,,,,,,) =
            r.hot.head(Keys.binding(Keys.principal(bob), Keys.position(Purpose.TAG, id, thing)));
        assertEq(st, 1, "the tag stands on a withdrawn registration");
    }
}
