// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, ActionKind, Coordinate, Purpose} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Qualified, Status} from "../../src/interfaces/Results.sol";
import {Selection} from "../../src/interfaces/Readers.sol";
import {RecordHeader} from "../../src/interfaces/Views.sol";
import {E_INDEX_CALL} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {LensReader} from "../../src/readers/LensReader.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";

/// @notice Statements about things on a real Realm (design §12.5; docs/TAG-DESIGN.md §2, §8): a first tag (TAG,
///         FIRST_BIND or FIRST_MASK) stands on a topic registered strictly before it or on a home, else
///         `FilesFinalValidator` refuses it (code 9, nested in `E_INDEX_CALL`); anything that exists may be tagged,
///         including a record of a Type this repository has never seen; SAME and BROADER join two registered topics
///         (codes 10-13); PROPERTY is not judged. Every statement reads back through `LensReader` under a lens.
contract TopicTagsTest is FilesRecipesBase {
    EfsTopics.Types internal tt;
    bytes32 internal thing;
    LensReader internal lens;

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        Action[] memory a = new Action[](1);
        a[0] = _create(keccak256("thing"));
        thing = Keys.subject(p, a[0].saltOrStrength);
        _execAs(address(this), a, new bytes[](1));
        lens = new LensReader(
            address(r.ledger), address(new LedgerViews()), address(new LedgerReads())
        );
    }

    function execExternal(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _execAs(address(this), a, b);
    }

    function _refused(Action[] memory a, bytes[] memory b, uint8 code, uint8 leaf) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector, abi.encodeWithSelector(E_FILES_FINAL.selector, code, leaf)
            )
        );
        this.execExternal(a, b);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _words(string memory x, string memory y) internal pure returns (bytes[] memory w) {
        w = new bytes[](2);
        w[0] = bytes(x);
        w[1] = bytes(y);
    }

    function _registerWord(string memory word) internal returns (bytes32 page) {
        (Action[] memory a, bytes[] memory b, bytes32 id) = EfsTopics.registerWord(tt, bytes(word));
        _execAs(address(this), a, b);
        return id;
    }

    function _registerPath(bytes[] memory words) internal returns (bytes32 id) {
        Action[] memory a;
        bytes[] memory b;
        (a, b, id) = EfsTopics.registerPath(tt, words);
        _execAs(address(this), a, b);
    }

    /// `a ‖ [x]`, with an empty body for `x`.
    function _then(Action[] memory a, bytes[] memory b, Action memory x)
        internal
        pure
        returns (Action[] memory a2, bytes[] memory b2)
    {
        a2 = new Action[](a.length + 1);
        b2 = new bytes[](a.length + 1);
        for (uint256 i; i < a.length; ++i) {
            (a2[i], b2[i]) = (a[i], b[i]);
        }
        a2[a.length] = x;
    }

    function _read(bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        view
        returns (Qualified memory q, Selection memory s)
    {
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        BasisCommit memory none;
        return lens.resolve(l, Coordinate(purpose, subject, role), none);
    }

    // ---- what a tag may stand on ------------------------------------------------------------------------------

    function test_unregistered_topic_refused_first_assert() public {
        _refused(
            _one(EfsTopics.tag(EfsTopics.wordPageId(tt.word, "nowhere"), thing, 0, 0)),
            new bytes[](1),
            9,
            0
        );
        // an arbitrary concept word (the pre-topic shape) is refused the same way
        _refused(_one(EfsTopics.tag(keccak256("concept"), thing, 0, 0)), new bytes[](1), 9, 0);
        // a record of another Type is not a topic: a directory, a file subject
        _refused(_one(EfsTopics.tag(rootDir, thing, 0, 0)), new bytes[](1), 9, 0);
        _refused(_one(EfsTopics.tag(thing, thing, 0, 0)), new bytes[](1), 9, 0);
    }

    function test_unregistered_topic_refused_first_lone_negative() public {
        _refused(
            _one(EfsTopics.deny(EfsTopics.wordPageId(tt.word, "nowhere"), thing, 0, 0)),
            new bytes[](1),
            9,
            0
        );
        _refused(_one(EfsTopics.deny(keccak256("concept"), thing, 0, 7)), new bytes[](1), 9, 0);
    }

    function test_refusal_names_the_leaf() public {
        (Action[] memory a, bytes[] memory b, bytes32 cars) = EfsTopics.registerWord(tt, "cars");
        (a, b) = _then(a, b, EfsTopics.tag(cars, thing, 0, 0));
        (a, b) = _then(a, b, EfsTopics.deny(EfsTopics.wordPageId(tt.word, "boats"), thing, 0, 0));
        _refused(a, b, 9, 2);
    }

    /// The registration and the tag in one publication: pages, `/cars/tesla`, then the first tag on it, and a lone
    /// negative on `/cars`.
    function test_registered_earlier_in_the_same_publication_is_admitted() public {
        (Action[] memory a, bytes[] memory b, bytes32 topic) =
            EfsTopics.registerPath(tt, _words("cars", "tesla"));
        bytes32 cars = EfsTopics.wordPageId(tt.word, "cars");
        (a, b) = _then(a, b, EfsTopics.tag(topic, thing, 0, 75));
        (a, b) = _then(a, b, EfsTopics.deny(cars, thing, 0, 0));
        _execAs(address(this), a, b);
        (Qualified memory q, Selection memory s) = _read(Purpose.TAG, topic, thing);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(abi.encode(s.target, s.strength), abi.encode(thing, uint16(75)));
        (q,) = _read(Purpose.TAG, cars, thing);
        assertEq(uint8(q.status), uint8(Status.MASKED));
    }

    /// The topic must be first admitted strictly before the tag's own admission: a tag ahead of its registration
    /// in one publication is refused (code 9, the tag's leaf); registrations come first.
    function test_registered_later_in_the_same_publication_is_refused() public {
        (Action[] memory reg, bytes[] memory rb, bytes32 later) =
            EfsTopics.registerWord(tt, "later");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = EfsTopics.tag(later, thing, 0, 0);
        (a[1], b[1]) = (reg[0], rb[0]);
        _refused(a, b, 9, 0);
        a[0] = EfsTopics.deny(later, thing, 0, 0); // a lone negative ahead of its registration, the same
        _refused(a, b, 9, 0);
        // a two-word path: the pages first, then the tag, then the path record: refused though its parent came first
        bytes32 topic;
        (reg, rb, topic) = EfsTopics.registerPath(tt, _words("early", "late"));
        a = new Action[](4);
        b = new bytes[](4);
        (a[0], b[0]) = (reg[0], rb[0]);
        (a[1], b[1]) = (reg[1], rb[1]);
        a[2] = EfsTopics.tag(topic, thing, 0, 0);
        (a[3], b[3]) = (reg[2], rb[2]);
        _refused(a, b, 9, 2);
    }

    function test_a_home_subject_is_admitted() public {
        bytes32 home = bytes32(uint256(uint160(makeAddr("topic-tags/home"))));
        Action[] memory a = new Action[](2);
        a[0] = EfsTopics.tag(home, thing, 0, 0);
        a[1] = EfsTopics.deny(home, keccak256("other"), 0, 0);
        _execAs(address(this), a, new bytes[](2));
        (Qualified memory q,) = _read(Purpose.TAG, home, thing);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
    }

    /// Later transitions on an existing binding are never refused: the validator judges only the first statement
    /// (mask, re-assert, release and restore below are not looked at again).
    function test_later_transitions_are_not_judged() public {
        bytes32 topic = _registerWord("cars");
        _execAs(address(this), _one(EfsTopics.tag(topic, thing, 0, 0)), new bytes[](1));
        _execAs(address(this), _one(EfsTopics.deny(topic, thing, 1, 3)), new bytes[](1));
        _execAs(address(this), _one(EfsTopics.tag(topic, thing, 2, 9)), new bytes[](1));
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.RELEASE, Purpose.TAG, topic, thing, 0, 3)),
            new bytes[](1)
        );
        _execAs(address(this), _one(EfsTopics.tag(topic, thing, 4, 1)), new bytes[](1));
        (uint8 st, uint64 rev,) = _head(_key(Purpose.TAG, topic, thing));
        assertEq(abi.encode(st, rev), abi.encode(uint8(1), uint64(5)));
    }

    // ---- what can be tagged ------------------------------------------------------------------------------------

    /// A record of a Type this repository has never seen (a chess app's move) is tagged like anything else.
    function test_a_record_of_a_third_party_type_is_a_target() public {
        bytes memory initcode = type(AcceptAll).creationCode;
        address instance = Factory.deploy(initcode);
        FilesTypes.Spec memory spec;
        spec.name = "chess-move/1";
        spec.description = "a third-party Type: a move in a game, any bytes";
        spec.dependencyClass = 1;
        spec.refHeaderWords = 1;
        bytes memory d =
            FilesTypes.encode(declarationKey, instance.codehash, keccak256(initcode), spec);
        bytes32 chess = FilesTypes.typeIdOf(d);
        bytes memory sig = _declare(r.registry, chess);
        r.store.put(d, sig);
        vm.prank(address(0xCAFE));
        (bytes32 got,) = r.registry.registerDescribed(d, sig, instance, "");
        assertEq(got, chess);
        bytes32 topic = _registerWord("openings");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        b[0] = "e2e4";
        a[0].kind = ActionKind.PUBLISH;
        a[0].typeId = chess;
        a[0].bodyHashOrRecordId = keccak256(b[0]);
        bytes32 move = Keys.record(chess, b[0]);
        a[1] = EfsTopics.tag(topic, move, 0, 0);
        _execAs(address(this), a, b);
        (Qualified memory q, Selection memory s) = _read(Purpose.TAG, topic, move);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(abi.encode(s.target, s.targetKind), abi.encode(move, uint8(1)));
    }

    /// A specific file revision, an address that never transacted, a folder and another topic are targets.
    function test_revisions_addresses_folders_and_topics_are_targets() public {
        bytes32 topic = _registerWord("collected");
        bytes32 file = Keys.subject(p, keccak256("topic-tags/file"));
        Action[] memory a = new Action[](6);
        bytes[] memory b = new bytes[](6);
        a[0] = _create(keccak256("topic-tags/file"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "v1"));
        bytes32 revision = Keys.record(typeIds[T_ROOT], b[1]);
        bytes32 addr = bytes32(uint256(uint160(makeAddr("topic-tags/never"))));
        bytes32 other = EfsTopics.wordPageId(tt.word, "collected");
        a[2] = EfsTopics.tag(topic, revision, 0, 0);
        a[3] = EfsTopics.tag(topic, addr, 0, 0);
        a[4] = EfsTopics.tag(topic, rootDir, 0, 0);
        a[5] = EfsTopics.tag(topic, other, 0, 0); // a topic tagged into itself: a curating statement
        _execAs(address(this), a, b);
        uint8[4] memory kinds = [uint8(1), 3, 1, 1];
        bytes32[4] memory targets = [revision, addr, rootDir, other];
        for (uint256 i; i < 4; ++i) {
            (Qualified memory q, Selection memory s) = _read(Purpose.TAG, topic, targets[i]);
            assertEq(uint8(q.status), uint8(Status.PRESENT));
            assertEq(abi.encode(s.target, s.targetKind), abi.encode(targets[i], kinds[i]));
        }
    }

    // ---- SAME, BROADER, PROPERTY ---------------------------------------------------------------------------------

    function test_same_and_broader_between_topics() public {
        bytes32 tesla = _registerWord("tesla");
        bytes32 auto_ = _registerWord("automobile");
        bytes32 car = _registerWord("car");
        bytes32 carsTesla = _registerPath(_words("cars", "tesla"));
        bytes32 brandsTesla = _registerPath(_words("brands", "tesla"));
        bytes32 cars = EfsTopics.wordPageId(tt.word, "cars");
        Action[] memory a = new Action[](6);
        a[0] = EfsTopics.same(car, auto_, 0); // word - word: the word-level synonym
        a[1] = EfsTopics.same(carsTesla, brandsTesla, 0); // path - path: those two places only
        a[2] = EfsTopics.same(tesla, carsTesla, 0); // word - path: the root place and that one path
        a[3] = EfsTopics.broader(carsTesla, cars, 0); // path - word
        a[4] = EfsTopics.broader(car, auto_, 0); // word - word
        a[5] = EfsTopics.broader(brandsTesla, carsTesla, 0); // path - path
        _execAs(address(this), a, new bytes[](6));
        for (uint256 i; i < 6; ++i) {
            (Qualified memory q, Selection memory s) = _read(a[i].purpose, a[i].subject, a[i].role);
            assertEq(uint8(q.status), uint8(Status.PRESENT));
            assertEq(s.target, a[i].role, "the target is the other topic");
        }
        // a lone negative at SAME between two topics: "not the same"
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.UNBIND, Purpose.SAME, tesla, car, 0, 0)),
            new bytes[](1)
        );
        (Qualified memory q2,) = _read(Purpose.SAME, tesla, car);
        assertEq(uint8(q2.status), uint8(Status.MASKED));
        // a later mask and release of an existing relation are never judged
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.UNBIND, Purpose.SAME, car, auto_, 0, 1)),
            new bytes[](1)
        );
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.RELEASE, Purpose.SAME, car, auto_, 0, 2)),
            new bytes[](1)
        );
    }

    function test_relations_refused() public {
        bytes32 tesla = _registerWord("tesla");
        bytes32 nowhere = EfsTopics.wordPageId(tt.word, "nowhere");
        bytes32[2] memory purposes = [Purpose.SAME, Purpose.BROADER];
        for (uint256 i; i < 2; ++i) {
            bytes32 pu = purposes[i];
            // the subject not a topic: unregistered, a file, a home (homes are not topics)
            _refused(_one(_bind(pu, nowhere, tesla, tesla, 0)), new bytes[](1), 10, 0);
            _refused(_one(_bind(pu, thing, tesla, tesla, 0)), new bytes[](1), 10, 0);
            _refused(
                _one(_bind(pu, bytes32(uint256(0xBEEF)), tesla, tesla, 0)), new bytes[](1), 10, 0
            );
            // the role not a topic (a directory record is a record, so the target exists)
            _refused(_one(_bind(pu, tesla, rootDir, rootDir, 0)), new bytes[](1), 11, 0);
            // the same topic twice
            _refused(_one(_bind(pu, tesla, tesla, tesla, 0)), new bytes[](1), 12, 0);
            // the target is not the role
            bytes32 other = _registerWord(i == 0 ? "other-same" : "other-broader");
            _refused(_one(_bind(pu, tesla, other, tesla, 0)), new bytes[](1), 13, 0);
            _refused(_one(_bind(pu, tesla, other, thing, 0)), new bytes[](1), 13, 0);
            // a lone negative needs two topics too
            _refused(
                _one(_bindKind(ActionKind.UNBIND, pu, nowhere, tesla, 0, 0)), new bytes[](1), 10, 0
            );
            _refused(
                _one(_bindKind(ActionKind.UNBIND, pu, tesla, nowhere, 0, 0)), new bytes[](1), 11, 0
            );
            // a lone negative whose role is registered later in the same publication (a bind could not name it:
            // its target, the role, must exist when the bind is admitted)
            (Action[] memory reg, bytes[] memory rb, bytes32 late) =
                EfsTopics.registerWord(tt, bytes(i == 0 ? "late-same" : "late-broader"));
            Action[] memory a = new Action[](2);
            bytes[] memory b = new bytes[](2);
            a[0] = _bindKind(ActionKind.UNBIND, pu, tesla, late, 0, 0);
            (a[1], b[1]) = (reg[0], rb[0]);
            _refused(a, b, 11, 0);
            // with the order fixed it is admitted
            (a[0], b[0]) = (reg[0], rb[0]);
            (a[1], b[1]) = (_bindKind(ActionKind.UNBIND, pu, tesla, late, 0, 0), "");
            _execAs(address(this), a, b);
        }
    }

    /// SAME's subject registered later in the same publication than the statement: the target (the role) exists,
    /// the subject does not yet, so the kernel admits the bind and the validator refuses it (code 10).
    function test_relation_subject_registered_later_is_refused() public {
        bytes32 tesla = _registerWord("tesla");
        (Action[] memory reg, bytes[] memory rb, bytes32 late) = EfsTopics.registerWord(tt, "late");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = EfsTopics.same(late, tesla, 0);
        (a[1], b[1]) = (reg[0], rb[0]);
        _refused(a, b, 10, 0);
        a[0] = EfsTopics.broader(late, tesla, 0);
        _refused(a, b, 10, 0);
    }

    function test_property_and_label_read_back() public {
        bytes32 tesla = _registerPath(_words("cars", "tesla"));
        (Action[] memory a, bytes[] memory b, bytes32 text) =
            EfsTopics.label(tt, tesla, "en", "Tesla, Inc. (AC/DC fan club)", 0);
        bytes32 home = bytes32(uint256(uint160(makeAddr("topic-tags/moved-to"))));
        (a, b) = _then(a, b, EfsTopics.property(tesla, EfsTopics.propertyKey("moved-to"), home, 0));
        // PROPERTY is not judged: any subject (a file, a home), any value that exists or an address
        (a, b) =
            _then(a, b, EfsTopics.property(thing, EfsTopics.propertyKey("definition"), text, 0));
        (a, b) = _then(a, b, EfsTopics.property(home, EfsTopics.labelKey("en"), text, 0));
        _execAs(address(this), a, b);
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        BasisCommit memory none;
        (Qualified memory q, Selection memory s, RecordHeader memory h, bytes memory body) = lens.resolveRecord(
            l, Coordinate(Purpose.PROPERTY, tesla, EfsTopics.labelKey("en")), 255, none
        );
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(s.target, text);
        assertEq(h.typeId, tt.text);
        assertEq(body, "Tesla, Inc. (AC/DC fan club)");
        (q, s) = _read(Purpose.PROPERTY, tesla, EfsTopics.propertyKey("moved-to"));
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(abi.encode(s.target, s.targetKind), abi.encode(home, uint8(3)), "an address value");
        (q, s) = _read(Purpose.PROPERTY, thing, EfsTopics.propertyKey("definition"));
        assertEq(s.target, text);
        (q, s) = _read(Purpose.PROPERTY, home, EfsTopics.labelKey("en"));
        assertEq(s.target, text);
    }
}
