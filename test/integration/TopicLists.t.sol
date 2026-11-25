// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsBase} from "./TopicListsBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    PostingKey,
    Purpose,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {E_INDEX_GAS} from "../../src/interfaces/Errors.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {Status} from "../../src/interfaces/Results.sol";

/// @notice The five first-statement lists on the real Files Realm (design §10.2): `scope-below` (19), `place` (6),
///         `position-authors` (20), `place-below` (7) and `role-places` (21). Every admitted first tag on an n-word
///         topic has exactly n - 1 per-author roll-up entries and, on a fresh position, n - 1 shared ones; no later
///         action of an author's moves or duplicates an entry; every statement of either sign is reachable from its
///         target; counts are one read; the backlink list ignores a BIND that keeps its target; and a deep first tag
///         sent with too little gas fails with the named index-gas error and is never admitted without its lists.
contract TopicListsTest is TopicListsBase {
    // ---- n - 1 entries at every depth -------------------------------------------------------------------------

    function _assertRollups(
        bytes32[] memory t,
        address who,
        bytes32 thing,
        uint64[] memory shared,
        string memory what
    ) internal view {
        uint256 n = t.length;
        uint64 o = _ordinal(who, Purpose.TAG, t[n - 1], thing);
        assertTrue(o != 0, what);
        for (uint256 j; j + 1 < n; ++j) {
            _eq(_scopeBelow(who, t[j]), _list1(o), string.concat(what, ": scope-below"));
            _eq(_placeBelow(t[j]), shared, string.concat(what, ": place-below"));
        }
        // the topic itself is not its own proper ancestor
        assertEq(
            _scopeBelow(who, t[n - 1]).length, 0, string.concat(what, ": not the topic itself")
        );
        assertEq(_placeBelow(t[n - 1]).length, 0, string.concat(what, ": not the topic itself"));
    }

    function _depth(uint256 n, uint256 thingIndex) internal {
        bytes32[] memory t = _regPath(string.concat("depth", vm.toString(n)), n);
        bytes32 thing = things[thingIndex];
        _tag(alice, t[n - 1], thing);
        uint64 o = _ordinal(alice, Purpose.TAG, t[n - 1], thing);
        _assertRollups(t, alice, thing, _list1(o), string.concat("n ", vm.toString(n)));
        // a second author's first no on the same (now existing) position: their own roll-ups, the shared ones
        // unchanged
        _deny(bob, t[n - 1], thing);
        _assertRollups(t, bob, thing, _list1(o), string.concat("second author n ", vm.toString(n)));
        _eq(_place(Purpose.TAG, t[n - 1]), _list1(o), "a later first no files nothing");
        // a third author's first yes is filed again, at the place and at every proper ancestor
        _tag(carol, t[n - 1], thing);
        uint64 oc = _ordinal(carol, Purpose.TAG, t[n - 1], thing);
        _assertRollups(
            t, carol, thing, _list2(o, oc), string.concat("third author n ", vm.toString(n))
        );
        _eq(_place(Purpose.TAG, t[n - 1]), _list2(o, oc), "a later first yes is filed");
        (uint64 c, uint64 l) = _head(F_PLACE, Purpose.TAG, t[n - 1]);
        assertEq(abi.encode(c, l), abi.encode(uint64(2), uint64(1)), "two filings, one position");
        _eq(
            _authors(Purpose.TAG, t[n - 1], thing),
            _list3(
                _admission(alice, Purpose.TAG, t[n - 1], thing),
                _admission(bob, Purpose.TAG, t[n - 1], thing),
                _admission(carol, Purpose.TAG, t[n - 1], thing)
            ),
            "three authors"
        );
        _eq(_rolePlaces(Purpose.TAG, thing), _list1(o), "one role-places entry");
    }

    function _list3(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory x) {
        x = new uint64[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function test_every_first_tag_has_n_minus_one_entries_at_depths_1_2_3_8_64() public {
        _depth(1, 0);
        _depth(2, 1);
        _depth(3, 2);
        _depth(8, 3);
        _depth(64, 4);
    }

    /// Registration and the first tag in one publication, registrations first (validator code 9 counts an earlier
    /// action of the same publication).
    function test_registration_and_tag_in_one_publication() public {
        uint256[5] memory depths = [uint256(1), 2, 3, 8, 32];
        for (uint256 d; d < depths.length; ++d) {
            uint256 n = depths[d];
            bytes[] memory w = _words(string.concat("onepub", vm.toString(n)), n);
            (Action[] memory a, bytes[] memory b, bytes32 id) =
                EfsTopics.registerPath(_topicTypes(), w);
            bytes32 thing = things[5 + d];
            (Action[] memory x, bytes[] memory y) =
                EfsFiles.concat(a, b, _one(EfsTopics.tag(id, thing, 0, 0)), new bytes[](1));
            assertLe(x.length, 64);
            _execAs(alice, x, y);
            bytes32[] memory t = _prefixes(w);
            assertEq(t[n - 1], id);
            uint64 o = _ordinal(alice, Purpose.TAG, id, thing);
            _assertRollups(
                t, alice, thing, _list1(o), string.concat("one publication n ", vm.toString(n))
            );
        }
    }

    // ---- no later action moves or duplicates an entry ---------------------------------------------------------------

    struct Lists {
        uint64[][] mine; // scope-below of `who` per proper ancestor
        uint64[][] shared; // place-below per proper ancestor
        uint64[] place;
        uint64[] authors;
        uint64[] rolePlaces;
    }

    function _lists(bytes32[] memory t, address who, bytes32 thing)
        internal
        view
        returns (Lists memory l)
    {
        uint256 n = t.length;
        l.mine = new uint64[][](n - 1);
        l.shared = new uint64[][](n - 1);
        for (uint256 j; j + 1 < n; ++j) {
            l.mine[j] = _scopeBelow(who, t[j]);
            l.shared[j] = _placeBelow(t[j]);
        }
        l.place = _place(Purpose.TAG, t[n - 1]);
        l.authors = _authors(Purpose.TAG, t[n - 1], thing);
        l.rolePlaces = _rolePlaces(Purpose.TAG, thing);
    }

    function _same(Lists memory x, Lists memory y, string memory what) internal pure {
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), what);
    }

    function test_no_later_action_of_an_author_moves_or_duplicates_an_entry() public {
        bytes32[] memory t = _regPath("stable", 4);
        bytes32 topic = t[3];
        bytes32 thing = things[0];
        // alice: assert, release, assert again; mask, assert again; number changes; mask then restore
        _tag(alice, topic, thing);
        Lists memory first = _lists(t, alice, thing);
        assertEq(first.authors.length, 1);
        _release(alice, topic, thing);
        _same(_lists(t, alice, thing), first, "release");
        _tag(alice, topic, thing);
        _same(_lists(t, alice, thing), first, "release then bind");
        _deny(alice, topic, thing);
        _same(_lists(t, alice, thing), first, "mask");
        _tag(alice, topic, thing);
        _same(_lists(t, alice, thing), first, "mask then restore");
        _tagN(alice, topic, thing, 75);
        _tagN(alice, topic, thing, 9);
        _same(_lists(t, alice, thing), first, "number changes");
        // bob: a lone negative, release, a lone negative again; then an assert and a mask
        _deny(bob, topic, thing);
        Lists memory bobs = _lists(t, bob, thing);
        assertEq(bobs.authors.length, 2, "bob's first statement adds his one entry");
        _eq(bobs.place, first.place, "a later author's first no files nothing");
        _eq(bobs.rolePlaces, first.rolePlaces, "the position was not fresh");
        _release(bob, topic, thing);
        _same(_lists(t, bob, thing), bobs, "bob release");
        _deny(bob, topic, thing);
        _same(_lists(t, bob, thing), bobs, "bob lone negative again");
        // bob's yes after his first no files nothing either (a deliberate limit: design §10.2)
        _tag(bob, topic, thing);
        _deny(bob, topic, thing);
        _same(_lists(t, bob, thing), bobs, "bob assert, mask");
        _same(_lists(t, alice, thing), _lists(t, alice, thing), "alice unchanged");
        Lists memory aliceNow = _lists(t, alice, thing);
        for (uint256 j; j < 3; ++j) {
            _eq(aliceNow.mine[j], first.mine[j], "alice's roll-ups never moved");
        }
    }

    /// A FOLDER position: release then bind again and a re-bind elsewhere add nothing to `place` or
    /// `position-authors`; a second author's first yes adds one author entry and one place filing (a second person's
    /// `notes.txt` at the same home shows as new), and the place still counts one distinct position.
    function test_folder_positions_record_first_statements_only() public {
        bytes32 role = keccak256("notes.txt");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _name("notes.txt");
        _execAs(address(this), a, b);
        bytes32 home = bytes32(uint256(uint160(alice)));
        _act(alice, _bind(Purpose.FOLDER, home, role, things[0], 0));
        uint64 o = _ordinal(alice, Purpose.FOLDER, home, role);
        uint64[] memory authors = _authors(Purpose.FOLDER, home, role);
        _eq(_place(Purpose.FOLDER, home), _list1(o), "one place entry");
        assertEq(authors.length, 1);
        _act(
            alice,
            EfsFiles.release(Purpose.FOLDER, home, role, _rev(alice, Purpose.FOLDER, home, role))
        );
        _act(
            alice,
            _bind(Purpose.FOLDER, home, role, things[1], _rev(alice, Purpose.FOLDER, home, role))
        );
        _act(
            alice,
            _bind(Purpose.FOLDER, home, role, things[2], _rev(alice, Purpose.FOLDER, home, role))
        );
        _eq(_place(Purpose.FOLDER, home), _list1(o), "place unchanged");
        _eq(_authors(Purpose.FOLDER, home, role), authors, "authors unchanged");
        _act(bob, _bind(Purpose.FOLDER, home, role, things[3], 0));
        assertEq(_authors(Purpose.FOLDER, home, role).length, 2, "bob is the second author");
        _eq(
            _place(Purpose.FOLDER, home),
            _list2(o, _ordinal(bob, Purpose.FOLDER, home, role)),
            "bob's first yes is filed"
        );
        (uint64 c, uint64 l) = _head(F_PLACE, Purpose.FOLDER, home);
        assertEq(abi.encode(c, l), abi.encode(uint64(2), uint64(1)), "one distinct position");
        // FOLDER keeps no role-places list and no topic roll-ups
        assertEq(_rolePlaces(Purpose.FOLDER, role).length, 0);
    }

    // ---- every statement is reachable from its target ------------------------------------------------------------

    function _thirdPartyRecord() internal returns (bytes32 move) {
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
        r.registry.registerDescribed(d, sig, instance, "");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        b[0] = "e2e4";
        a[0].kind = ActionKind.PUBLISH;
        a[0].typeId = chess;
        a[0].bodyHashOrRecordId = keccak256(b[0]);
        _execAs(address(this), a, b);
        move = Keys.record(chess, b[0]);
    }

    function _targets() internal returns (bytes32[6] memory x) {
        // a file subject, a directory record, a topic record, a revision record, an address with no history and a
        // record of a throwaway third-party Type
        x[0] = things[8];
        x[1] = rootDir;
        (Action[] memory a, bytes[] memory b, bytes32 topicRecord) =
            EfsTopics.registerWord(_topicTypes(), "target-topic");
        _execAs(address(this), a, b);
        x[2] = topicRecord;
        a = new Action[](1);
        b = new bytes[](1);
        (a[0], b[0]) = _publish(T_ROOT, EfsFiles.rootBody(things[9], "v1"));
        _execAs(address(this), a, b);
        x[3] = _id(T_ROOT, b[0]);
        x[4] = bytes32(uint256(uint160(makeAddr("lists/never-transacted"))));
        x[5] = _thirdPartyRecord();
    }

    function test_every_statement_is_reachable_from_its_target_whatever_its_sign() public {
        bytes32[] memory t = _regPath("reach", 2);
        bytes32 topic = t[1];
        bytes32[6] memory x = _targets();
        for (uint256 i; i < x.length; ++i) {
            string memory what = string.concat("target kind ", vm.toString(i));
            _deny(alice, topic, x[i]); // a lone negative: no target, so no backlink
            _tag(bob, topic, x[i]);
            uint64 o = _ordinal(alice, Purpose.TAG, topic, x[i]);
            // thing -> role-places -> the position -> position-authors
            uint64[] memory places = _rolePlaces(Purpose.TAG, x[i]);
            _eq(places, _list1(o), what);
            assertEq(_positionOf(places[0]), Keys.position(Purpose.TAG, topic, x[i]), what);
            _eq(
                _authors(Purpose.TAG, topic, x[i]),
                _list2(
                    _admission(alice, Purpose.TAG, topic, x[i]),
                    _admission(bob, Purpose.TAG, topic, x[i])
                ),
                what
            );
            (uint64 c,) = _head(F_BACKLINK, Purpose.TAG, x[i]);
            assertEq(c, 1, "only the assert carries a target");
        }
    }

    /// The position a `role-places` / `place` entry names: the binding of that ordinal, read from the ledger.
    function _positionOf(uint64 bindingOrdinal) internal returns (bytes32 position) {
        Status st;
        (st, position) = new LedgerReads().bindingPosition(address(r.ledger), bindingOrdinal);
        assertEq(uint8(st), uint8(Status.PRESENT), "the ordinal names a binding");
    }

    /// A position whose only statements are lone negatives is in every all-authors list (through the fresh rule),
    /// with a yes-count of zero.
    function test_a_position_with_only_negatives_is_in_every_all_authors_list() public {
        bytes32[] memory t = _regPath("negonly", 3);
        bytes32 thing = things[10];
        _deny(alice, t[2], thing);
        _deny(bob, t[2], thing);
        uint64 o = _ordinal(alice, Purpose.TAG, t[2], thing);
        _eq(_place(Purpose.TAG, t[2]), _list1(o), "place");
        _eq(_placeBelow(t[0]), _list1(o), "place-below of the root");
        _eq(_placeBelow(t[1]), _list1(o), "place-below of the middle");
        _eq(_rolePlaces(Purpose.TAG, thing), _list1(o), "role-places");
        assertEq(_authors(Purpose.TAG, t[2], thing).length, 2, "position-authors");
        (uint64 count, uint64 yes) =
            _head(F_POSITION_AUTHORS, 0, Keys.position(Purpose.TAG, t[2], thing));
        assertEq(
            abi.encode(count, yes), abi.encode(uint64(2), uint64(0)), "two authors, nobody says yes"
        );
        (count, yes) = _head(F_PLACE, Purpose.TAG, t[2]);
        assertEq(
            abi.encode(count, yes), abi.encode(uint64(1), uint64(1)), "one filing, one position"
        );
        _eq(_scopeBelow(bob, t[0]), _list1(_ordinal(bob, Purpose.TAG, t[2], thing)), "bob's own");
        (uint64 c,) = _head(F_BACKLINK, Purpose.TAG, thing);
        assertEq(c, 0, "no backlink: nothing asserted");
    }

    // ---- counts are one read -------------------------------------------------------------------------------------

    function test_a_places_live_is_its_positions_and_a_positions_count_its_authors() public {
        bytes32[] memory t = _regPath("counts", 2);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j <= i % 3; ++j) {
                if (j % 2 == 0) _tag(who[j], t[1], things[i]);
                else _deny(who[j], t[1], things[i]);
            }
        }
        // positions 0..3: alice yes; alice yes, bob no; alice yes, bob no, carol yes; alice yes
        (uint64 places, uint64 distinct) = _head(F_PLACE, Purpose.TAG, t[1]);
        assertEq(places, 5, "five filings: four fresh positions and carol's later first yes");
        assertEq(distinct, 4, "four distinct positions");
        (uint64 below, uint64 belowDistinct) = _head(F_PLACE_BELOW, Purpose.TAG, t[0]);
        assertEq(below, 5, "five filings below the root");
        assertEq(belowDistinct, 4, "four positions below the root");
        uint64[4] memory expected = [uint64(1), 2, 3, 1];
        uint64[4] memory yes = [uint64(1), 1, 2, 1];
        for (uint256 i; i < 4; ++i) {
            (uint64 authors, uint64 saying) =
                _head(F_POSITION_AUTHORS, 0, Keys.position(Purpose.TAG, t[1], things[i]));
            assertEq(authors, expected[i], "authors at the position");
            assertEq(saying, yes[i], "authors saying yes at the position");
            (uint64 rp,) = _head(F_ROLE_PLACES, Purpose.TAG, things[i]);
            assertEq(rp, 1, "one place per thing");
        }
    }

    // ---- family 11 still answers the topic directories ------------------------------------------------------------

    function test_reference_positions_answer_a_topics_children_and_a_words_topics() public {
        EfsTopics.Types memory tt = _topicTypes();
        bytes32[] memory a = _regPath("dir", 2); // dir-0, dir-0/dir-1
        (Action[] memory x, bytes[] memory y, bytes32 c2) =
            EfsTopics.registerChild(tt, a[0], "dir-2", true); // dir-0/dir-2
        _execAs(address(this), x, y);
        (x, y,) = EfsTopics.registerChild(tt, a[1], "dir-2", false); // dir-0/dir-1/dir-2
        _execAs(address(this), x, y);
        (Coverage cov, uint64 n,,,) =
            r.g.index.postingHeadOf(FamilyId.wrap(F_REFERENCE), TypeId.wrap(tt.topic), 0, a[0]);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE));
        assertEq(n, 2, "dir-0 has two children");
        (, n,,,) = r.g.index
            .postingHeadOf(
                FamilyId.wrap(F_REFERENCE),
                TypeId.wrap(tt.topic),
                1,
                EfsTopics.wordPageId(tt.word, "dir-2")
            );
        assertEq(n, 2, "dir-2 is used by two topics");
        assertTrue(c2 != a[1]);
    }

    // ---- the backlink list ignores a BIND that keeps its target ---------------------------------------------------

    function test_number_changes_leave_the_backlink_list_alone() public {
        bytes32 topic = _regPath("numbers", 1)[0];
        bytes32 thing = things[11];
        _tag(alice, topic, thing);
        bytes32 key = Keys.binding(_pid(alice), Keys.position(Purpose.TAG, topic, thing));
        (uint64 c0, uint64 l0) = _head(F_BACKLINK, Purpose.TAG, thing);
        assertEq(abi.encode(c0, l0), abi.encode(uint64(1), uint64(1)));
        for (uint16 i = 1; i <= 6; ++i) {
            _tagN(alice, topic, thing, i * 10);
        }
        (uint64 c, uint64 l) = _head(F_BACKLINK, Purpose.TAG, thing);
        assertEq(c, 1, "no entry per number change");
        assertEq(l, 1, "live unchanged");
        (uint64 h,) = _head(F_HISTORY, 0, key);
        assertEq(h, 7, "the history still records every admission");
    }

    function test_a_rebind_to_another_target_still_moves_the_backlink() public {
        bytes32 role = keccak256("moving.txt");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _name("moving.txt");
        _execAs(address(this), a, b);
        _act(address(this), _bind(Purpose.FOLDER, rootDir, role, things[12], 0));
        _act(
            address(this),
            _bind(
                Purpose.FOLDER,
                rootDir,
                role,
                things[13],
                _rev(address(this), Purpose.FOLDER, rootDir, role)
            )
        );
        (uint64 c, uint64 l) = _head(F_BACKLINK, Purpose.FOLDER, things[12]);
        assertEq(abi.encode(c, l), abi.encode(uint64(1), uint64(0)), "the old target released");
        (c, l) = _head(F_BACKLINK, Purpose.FOLDER, things[13]);
        assertEq(abi.encode(c, l), abi.encode(uint64(1), uint64(1)), "the new target appended");
        // a FOLDER re-bind to the same target with a new number appends nothing either
        _act(
            address(this),
            EfsFiles.bindWithStrength(
                Purpose.FOLDER,
                rootDir,
                role,
                things[13],
                _rev(address(this), Purpose.FOLDER, rootDir, role),
                5
            )
        );
        (c, l) = _head(F_BACKLINK, Purpose.FOLDER, things[13]);
        assertEq(abi.encode(c, l), abi.encode(uint64(1), uint64(1)), "same target: unchanged");
        // mask then restore appends again (a restore re-asserts the target)
        _act(
            address(this),
            EfsFiles.unbind(
                Purpose.FOLDER, rootDir, role, _rev(address(this), Purpose.FOLDER, rootDir, role)
            )
        );
        _act(
            address(this),
            _bind(
                Purpose.FOLDER,
                rootDir,
                role,
                things[13],
                _rev(address(this), Purpose.FOLDER, rootDir, role)
            )
        );
        (c, l) = _head(F_BACKLINK, Purpose.FOLDER, things[13]);
        assertEq(abi.encode(c, l), abi.encode(uint64(2), uint64(1)), "restore appends");
    }

    // ---- the quote does not know the depth: too little gas fails by name ----------------------------------------

    function execute(Action[] calldata a, bytes[] calldata b, Native calldata c) external {
        r.ledger.execute(a, b, c, "");
    }

    function test_a_deep_first_tag_with_too_little_gas_fails_with_the_index_gas_error() public {
        bytes32[] memory t = _regPath("deep", 64);
        bytes32 thing = things[14];
        Action[] memory a = _one(EfsTopics.tag(t[63], thing, 0, 0));
        bytes[] memory b = new bytes[](1);
        Native memory c = _ctx(a);
        // the full cost, measured and rolled back
        uint256 snap = vm.snapshotState();
        uint256 before = gasleft();
        r.ledger.execute(a, b, c, "");
        uint256 full = before - gasleft();
        vm.revertToState(snap);
        (uint64 admissions,,,) = r.hot.counts();
        // short by an eighth: past every pre-callback check, short inside the lists
        (bool ok, bytes memory ret) = address(r.ledger).call{gas: full - full / 8}(
            abi.encodeCall(ILedger.execute, (a, b, c, ""))
        );
        assertFalse(ok, "refused");
        assertEq(bytes4(ret), E_INDEX_GAS.selector, "the named index-gas error");
        (uint64 after_,,,) = r.hot.counts();
        assertEq(after_, admissions, "nothing admitted");
        assertEq(_scopeBelow(address(this), t[0]).length, 0, "no partial list");
        assertEq(_ordinal(address(this), Purpose.TAG, t[63], thing), 0, "no binding");
        // with the gas the model quotes it is admitted with all 63 levels
        r.ledger.execute(a, b, c, "");
        for (uint256 j; j < 63; ++j) {
            assertEq(_scopeBelow(address(this), t[j]).length, 1, "every level");
            assertEq(_placeBelow(t[j]).length, 1, "every level");
        }
    }
}

/// @notice A Realm whose index is built with zero topic Type ids keeps the place, author and role lists but walks no
///         ancestors: `scope-below` and `place-below` stay empty and report UNKNOWN.
contract TopicListsWithoutTopicTypesTest is TopicListsBase {
    function setUp() public override {
        withoutTopicLists = true;
        super.setUp();
    }

    function test_no_walk_and_the_topic_roll_ups_are_unknown() public {
        bytes32[] memory t = _regPath("nowalk", 3);
        bytes32 thing = things[0];
        _tag(alice, t[2], thing);
        uint64 o = _ordinal(alice, Purpose.TAG, t[2], thing);
        _eq(_place(Purpose.TAG, t[2]), _list1(o), "place kept");
        _eq(_rolePlaces(Purpose.TAG, thing), _list1(o), "role-places kept");
        assertEq(_authors(Purpose.TAG, t[2], thing).length, 1, "position-authors kept");
        (uint64 count,,,) = r.g.posting
            .postingHead(PostingKey.wrap(Keys.scopeBelowList(_pid(alice), Purpose.TAG, t[0])));
        assertEq(count, 0, "no scope-below");
        (count,,,) =
            r.g.posting.postingHead(PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, t[0])));
        assertEq(count, 0, "no place-below");
        (Coverage c,,,,) = r.g.index
            .postingHeadOf(
                FamilyId.wrap(F_SCOPE_BELOW),
                TypeId.wrap(0),
                0,
                Keys.scopeBelow(_pid(alice), Purpose.TAG, t[0])
            );
        assertEq(uint8(c), uint8(Coverage.UNKNOWN), "scope-below not maintained");
    }
}
