// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsHistory} from "../integration/TopicListsHistory.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, PostingKey, Purpose} from "../../src/interfaces/Actions.sol";
import {Effect, Unit} from "../../src/interfaces/Index.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// A final hook that answers the two topic Type getters (so a generation may keep the topic lists beside it) and
/// judges nothing: the lists are live while the profile's laws (`FilesFinalValidator` codes 1 to 16) are absent.
contract PassiveTopicHook is IIndexHook {
    bytes32 public topicTypeId;
    bytes32 public topicWordTypeId;

    constructor(bytes32 topic, bytes32 word) {
        topicTypeId = topic;
        topicWordTypeId = word;
    }

    function fold(Effect calldata, bytes32[] calldata, uint64) external pure returns (bytes4) {
        return IIndexHook.fold.selector;
    }

    function validate(uint64, Effect[] calldata, bytes32[] calldata)
        external
        pure
        returns (bytes4)
    {
        return IIndexHook.validate.selector;
    }
}

/// @notice Docs INDEX-BUILD §4.3, the as-of rule (step 3a): a fold from history reads every fact as of the admission
///         it folds, and never takes a fact from a validator's law. Realm U's history is admitted with no unit at all
///         (generation 1 keeps no topic lists and has no Files validator), so a tag can name a topic that is
///         registered only later. A topic-list generation built over U (with the real validator as its unit, which a
///         build never calls) must then file exactly what a live fold files, whenever the build runs:
///
///         - two builds on identical Realms, one started before the topic's registration and one after it, and a
///           replay, give the same lists, and none of them rolls up the early tag (`test_build_does_not_depend_on_when_it_runs`);
///         - the lists built on U equal, key by key, the live lists of Realm V, which takes the same history with the
///           topic lists live beside a final hook that judges nothing (`test_built_equals_a_live_fold_without_the_law`);
///         - in one publication, a topic registered in an earlier leaf rolls the tag up and one registered in a later
///           leaf does not, live and from history (`test_same_publication_topic_first`, `test_same_publication_tag_first`);
///         - the live fold never pays the history read (`test_the_live_fold_never_reads_the_first_admission`).
contract BuildAsOfTest is TopicListsHistory {
    PassiveTopicHook internal passive;
    bool internal passiveTopics; // Realm V: the generation-1 unit is the passive hook, the topic lists are live

    address internal dave = makeAddr("as-of/dave");

    // ---- Realms U and V ---------------------------------------------------------------------------------------------

    /// Realm U: no unit, no topic lists (FilesFixture `withoutValidator`).
    function setUp() public virtual override {
        withoutValidator = true;
        super.setUp();
        authors.push(dave);
    }

    function _units() internal view virtual override returns (Unit[] memory units) {
        if (!passiveTopics) return super._units();
        units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(0),
            foldCodehash: 0,
            finalHook: address(passive),
            finalCodehash: address(passive).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: Purpose.FOLDER,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/unit/passive-topics")
        });
    }

    /// Switches `r` to Realm V: the same genesis traffic as `setUp` (the root seed, 16 CREATEs), the topic lists live
    /// beside the passive hook. The recorded keys are cleared: the history records them again, and every key it
    /// records is Realm-independent (EOA authors, address-shaped things, record ids).
    function _realmV() internal {
        passive = new PassiveTopicHook(typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]);
        withoutValidator = false;
        passiveTopics = true;
        r = _realm(keccak256("as-of/realm-v"));
        _register(r);
        p = r.principal;
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(T_DIRECTORY, _dirBody(p, keccak256("root")));
        rootDir = _id(T_DIRECTORY, b[0]);
        _execAs(address(this), a, b);
        Action[] memory c = new Action[](16);
        for (uint256 i; i < 16; ++i) {
            c[i] = _create(keccak256(abi.encode("lists/thing", i)));
        }
        _execAs(address(this), c, new bytes[](16));
        delete postingKeys;
        delete scopeKeys;
        delete topicIds;
        (bytes32 t, bytes32 w) = r.g.index.topicTypes();
        assertEq(abi.encode(t, w), abi.encode(typeIds[T_TOPIC], typeIds[T_TOPIC_WORD]));
    }

    /// A topic-list generation over two fresh stores, with the real validator as its unit (a build never calls it).
    function _topicGeneration() internal returns (IndexDeployer d, IGeneration1 ix) {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        Unit[] memory units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(0),
            foldCodehash: 0,
            finalHook: address(validator),
            finalCodehash: address(validator).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: Purpose.FOLDER,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: validator.identity()
        });
        plan.units = units;
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.topicTypeId = typeIds[T_TOPIC];
        plan.topicWordTypeId = typeIds[T_TOPIC_WORD];
        plan.liveManifest = ManifestCopy.ofLive(address(r.ledger));
        d = new IndexDeployer(address(r.ledger), keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    function _buildAll(IGeneration1 ix) internal {
        (uint64 admissions,,,) = r.hot.counts();
        while (ix.build(bytes32(0), 64) != admissions) {}
    }

    function _stores(IndexDeployer d) internal view returns (IPostingStore, IBitmapStore) {
        return (IPostingStore(d.postingStore()), IBitmapStore(d.bitmapStore()));
    }

    // ---- the history ------------------------------------------------------------------------------------------------

    function _thing(string memory seed) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode("as-of/thing", seed))))));
    }

    /// The path `late-0/late-1`, registered only in part 2: [0] its word page (a root), [1] the path record.
    function _late() internal view returns (bytes32[] memory) {
        return _prefixes(_words("late", 2));
    }

    /// `who`'s one publication of the path `<name>-0/<name>-1` (two pages, then the path record) and a first tag under
    /// the path record, the tag in leaf `tagLeaf` (3: after the registration; 2: just before the path record). The
    /// path record's first admission is the tag's admission - 1 or + 1: the two sides of "strictly below".
    function _samePublication(address who, string memory name, uint256 tagLeaf, bytes32 thing)
        internal
        returns (bytes32[] memory t)
    {
        bytes[] memory w = _words(name, 2);
        (Action[] memory reg, bytes[] memory regBodies,) = EfsTopics.registerPath(_topicTypes(), w);
        t = _prefixes(w);
        Action memory tag = EfsTopics.tag(t[1], thing, 0, 0);
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        uint256 j;
        for (uint256 i; i < 4; ++i) {
            if (i == tagLeaf) {
                a[i] = tag;
            } else {
                (a[i], b[i]) = (reg[j], regBodies[j]);
                ++j;
            }
        }
        _execAs(who, a, b);
        // the keys `_say` records for the tag, and the two new topics for `_rollUpKeys`
        bytes32 pid = _pid(who);
        bytes32 position = Keys.position(Purpose.TAG, t[1], thing);
        postingKeys.push(PostingKey.wrap(Keys.historyList(Keys.binding(pid, position))));
        postingKeys.push(
            PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(pid, Purpose.TAG, thing)))
        );
        postingKeys.push(PostingKey.wrap(Keys.placeList(Purpose.TAG, t[1])));
        postingKeys.push(PostingKey.wrap(Keys.positionAuthorsList(position)));
        postingKeys.push(PostingKey.wrap(Keys.rolePlacesList(Purpose.TAG, thing)));
        postingKeys.push(PostingKey.wrap(Keys.backlinkList(Purpose.TAG, thing)));
        scopeKeys.push(Keys.scope(pid, Purpose.TAG, t[1]));
        topicIds.push(t[0]);
        topicIds.push(t[1]);
        // the tag's leaf and the path record's leaf are adjacent admissions
        (,, uint64 tagAdmission,,,,,) = r.hot.head(Keys.binding(pid, position));
        (, uint64 first,,,) = r.hot.recordHeader(t[1]);
        assertEq(first, tagLeaf == 3 ? tagAdmission - 1 : tagAdmission + 1, "adjacent leaves");
    }

    /// Part 1: an early path; first statements (a tag, a lone negative) under `late-0/late-1` before it is
    /// registered (nothing judges them on U or V).
    function _part1() internal {
        bytes32[] memory early = _path("early", 3);
        bytes32 late = _late()[1];
        _tagAs(alice, late, _thing("a"), 0); // a first tag under a topic that does not exist yet
        _denyAs(carol, late, _thing("b")); // a lone negative under it
        _tagAs(bob, early[2], _thing("a"), 0); // an ordinary roll-up, for contrast
        _tagAs(dave, late, _thing("a"), 0); // a second author at alice's position, before the registration
    }

    /// Part 2: `late-0/late-1` is registered; statements under it after that roll up; the two same-publication cases.
    function _part2() internal {
        bytes32[] memory late = _path("late", 2);
        (, uint64 first,,,) = r.hot.recordHeader(late[1]);
        assertGt(first, _admission(alice, Purpose.TAG, late[1], _thing("a")), "registered later");
        _tagAs(bob, late[1], _thing("a"), 0); // a later author's first yes at alice's position: rolls up
        _tagAs(alice, late[1], _thing("a"), 9); // a number change: no first statement
        _tagAs(carol, late[1], _thing("c"), 0); // a fresh position after the registration: rolls up
        _denyAs(alice, late[1], _thing("a")); // a mask of alice's early tag: no first statement
        _samePublication(alice, "topic-first", 3, _thing("d"));
        _samePublication(bob, "tag-first", 2, _thing("d"));
        _rollUpKeys();
    }

    function _history() internal {
        _part1();
        _part2();
    }

    // ---- assertions -------------------------------------------------------------------------------------------------

    function _entriesOf(IPostingStore ps, PostingKey key) internal view returns (uint64[] memory) {
        (uint64 c,,,) = ps.postingHead(key);
        return c == 0 ? new uint64[](0) : ps.postingSlice(key, 0, uint16(c));
    }

    function _contains(uint64[] memory xs, uint64 v) internal pure returns (bool) {
        for (uint256 i; i < xs.length; ++i) {
            if (xs[i] == v) return true;
        }
        return false;
    }

    /// The roll-up of each statement in `ps`, by what the live fold sees at its admission: nothing for the
    /// statements made before `late-0/late-1` existed or in a leaf before the path record; an entry for those after.
    function _assertRollUps(IPostingStore ps, string memory what) internal view {
        bytes32 lateWord = _late()[0];
        uint64[] memory placeBelow =
            _entriesOf(ps, PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, lateWord)));
        // before the registration: alice's tag, carol's lone negative, dave's tag
        assertFalse(
            _contains(placeBelow, _ordinal(alice, Purpose.TAG, _late()[1], _thing("a"))),
            string.concat(what, ": alice's early tag is not rolled up")
        );
        assertFalse(
            _contains(placeBelow, _ordinal(carol, Purpose.TAG, _late()[1], _thing("b"))),
            string.concat(what, ": carol's early lone negative is not rolled up")
        );
        assertEq(
            _entriesOf(ps, PostingKey.wrap(Keys.scopeBelowList(_pid(alice), Purpose.TAG, lateWord)))
            .length,
            0,
            string.concat(what, ": alice has nothing below late-0")
        );
        assertEq(
            _entriesOf(ps, PostingKey.wrap(Keys.scopeBelowList(_pid(dave), Purpose.TAG, lateWord)))
            .length,
            0,
            string.concat(what, ": dave has nothing below late-0")
        );
        // after it: bob's later first yes and carol's fresh position
        uint64 bobOrdinal = _ordinal(bob, Purpose.TAG, _late()[1], _thing("a"));
        uint64 carolOrdinal = _ordinal(carol, Purpose.TAG, _late()[1], _thing("c"));
        _eq(
            placeBelow, _pair(bobOrdinal, carolOrdinal), string.concat(what, ": place-below late-0")
        );
        (uint64 c, uint64 l,,) =
            ps.postingHead(PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, lateWord)));
        assertEq(abi.encode(c, l), abi.encode(uint64(2), uint64(1)), "bob's filing is uncounted");
        _eq(
            _entriesOf(ps, PostingKey.wrap(Keys.scopeBelowList(_pid(bob), Purpose.TAG, lateWord))),
            _list1(bobOrdinal),
            string.concat(what, ": bob below late-0")
        );
    }

    function _pair(uint64 a, uint64 b) internal pure returns (uint64[] memory x) {
        x = new uint64[](2);
        (x[0], x[1]) = (a, b);
    }

    /// The topic-first publication rolls alice's tag up under its word page; the tag-first one rolls nothing up.
    function _assertSamePublication(IPostingStore ps, bool topicFirst, string memory what)
        internal
        view
    {
        address who = topicFirst ? alice : bob;
        bytes32[] memory t = _prefixes(_words(topicFirst ? "topic-first" : "tag-first", 2));
        uint64 ordinal = _ordinal(who, Purpose.TAG, t[1], _thing("d"));
        uint64[] memory below =
            _entriesOf(ps, PostingKey.wrap(Keys.scopeBelowList(_pid(who), Purpose.TAG, t[0])));
        uint64[] memory placeBelow =
            _entriesOf(ps, PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, t[0])));
        if (topicFirst) {
            _eq(below, _list1(ordinal), string.concat(what, ": scope-below"));
            _eq(placeBelow, _list1(ordinal), string.concat(what, ": place-below"));
        } else {
            assertEq(below.length, 0, string.concat(what, ": no scope-below"));
            assertEq(placeBelow.length, 0, string.concat(what, ": no place-below"));
        }
        // the exact place is filed either way
        _eq(
            _entriesOf(ps, PostingKey.wrap(Keys.placeList(Purpose.TAG, t[1]))),
            _list1(ordinal),
            string.concat(what, ": place")
        );
    }

    // =============================================================================================
    // 1. Unvalidated history: the build does not depend on when it runs
    // =============================================================================================

    function test_build_does_not_depend_on_when_it_runs() public {
        _part1();
        uint256 snap = vm.snapshotState();
        // A: built before the topic's registration exists, then continued to the end after it lands
        (IndexDeployer da, IGeneration1 a) = _topicGeneration();
        _buildAll(a);
        _part2();
        _buildAll(a);
        (IPostingStore ap, IBitmapStore ab) = _stores(da);
        (bytes32[] memory early, uint256 nonEmpty, uint256 entries) = _capture(ap, ab);
        _assertRollUps(ap, "built early");
        _assertSamePublication(ap, true, "built early");
        _assertSamePublication(ap, false, "built early");
        vm.revertToState(snap);
        // B: the whole history first, then one build; and a replay
        _part2();
        (IndexDeployer db, IGeneration1 b) = _topicGeneration();
        _buildAll(b);
        (IPostingStore bp, IBitmapStore bb) = _stores(db);
        (bytes32[] memory late,,) = _capture(bp, bb);
        _assertSameCapture(early, late, "built before vs after the registration");
        _assertRollUps(bp, "built late");
        (IndexDeployer dr, IGeneration1 replayed) = _topicGeneration();
        while (replayed.replayNextPublication(64) != 0) {}
        (IPostingStore rp, IBitmapStore rb) = _stores(dr);
        (bytes32[] memory rep,,) = _capture(rp, rb);
        _assertSameCapture(early, rep, "built vs replayed");
        assertGt(nonEmpty, 30, "non-empty lists compared");
        assertGt(entries, 40, "entries compared");
    }

    // =============================================================================================
    // 2-4. What a live fold would have filed (Realm V), and the two same-publication cases
    // =============================================================================================

    /// Realm U's history built by a topic-list generation, and Realm V's live lists over the same history; returns
    /// both stores' posting store and asserts every recorded list equal, key by key.
    function _builtAndLive()
        internal
        returns (IPostingStore builtPosting, IPostingStore livePosting)
    {
        _history();
        (IndexDeployer d, IGeneration1 ix) = _topicGeneration();
        _buildAll(ix);
        IBitmapStore builtBitmap;
        (builtPosting, builtBitmap) = _stores(d);
        (bytes32[] memory built, uint256 nonEmpty, uint256 entries) =
            _capture(builtPosting, builtBitmap);
        uint256 keys = postingKeys.length;
        _realmV();
        _history();
        assertEq(postingKeys.length, keys, "the same keys recorded on V");
        livePosting = IPostingStore(address(r.g.posting));
        (bytes32[] memory live,,) = _capture(livePosting, IBitmapStore(address(r.g.bitmap)));
        _assertSameCapture(built, live, "built on U vs live on V");
        assertGt(nonEmpty, 30, "non-empty lists compared");
        assertGt(entries, 40, "entries compared");
        // every topic family was compared non-empty: 6, 7, 19, 20, 21 (the rest are the history's)
        _assertNonEmpty(livePosting, Keys.placeList(Purpose.TAG, _late()[1]), "6");
        _assertNonEmpty(livePosting, Keys.placeBelowList(Purpose.TAG, _late()[0]), "7");
        _assertNonEmpty(livePosting, Keys.scopeBelowList(_pid(bob), Purpose.TAG, _late()[0]), "19");
        _assertNonEmpty(
            livePosting,
            Keys.positionAuthorsList(Keys.position(Purpose.TAG, _late()[1], _thing("a"))),
            "20"
        );
        _assertNonEmpty(livePosting, Keys.rolePlacesList(Purpose.TAG, _thing("a")), "21");
    }

    function _assertNonEmpty(IPostingStore ps, bytes32 key, string memory family) internal view {
        (uint64 c,,,) = ps.postingHead(PostingKey.wrap(key));
        assertGt(c, 0, string.concat("family ", family, " compared non-empty"));
    }

    function test_built_equals_a_live_fold_without_the_law() public {
        (IPostingStore built, IPostingStore live) = _builtAndLive();
        _assertRollUps(live, "live on V");
        _assertRollUps(built, "built on U");
    }

    function test_same_publication_topic_first() public {
        (IPostingStore built, IPostingStore live) = _builtAndLive();
        _assertSamePublication(live, true, "live on V");
        _assertSamePublication(built, true, "built on U");
    }

    function test_same_publication_tag_first() public {
        (IPostingStore built, IPostingStore live) = _builtAndLive();
        _assertSamePublication(live, false, "live on V");
        _assertSamePublication(built, false, "built on U");
    }

    // =============================================================================================
    // 6. The history flag never rides the live path
    // =============================================================================================

    /// Counts the ledger reads of `slot` recorded since `vm.record()`.
    function _readsOf(bytes32 slot) internal view returns (uint256 n) {
        (bytes32[] memory reads,) = vm.accesses(address(r.ledger));
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == slot) ++n;
        }
    }

    /// On Realm V (nothing but the index reads the tag's subject), a live first tag never reads the subject's
    /// first-admission word (record cell word 1), while a build of the same publication does, once.
    function test_the_live_fold_never_reads_the_first_admission() public {
        _realmV();
        bytes32[] memory t = _path("flag", 3);
        bytes32 word1 = bytes32(Layout.recordsCellsSlot(t[2]) + 1);
        bytes32 word0 = bytes32(Layout.recordsCellsSlot(t[2]));
        (, IGeneration1 ix) = _topicGeneration();
        _buildAll(ix); // a candidate caught up before the tag
        vm.record();
        _tagAs(alice, t[2], _thing("flag"), 0);
        assertGt(_readsOf(word0), 0, "the live walk reads the subject's Type word");
        assertEq(_readsOf(word1), 0, "the live fold never reads the first admission");
        // the live fold rolled the tag up (two proper ancestors)
        _eq(
            _entriesOf(
                IPostingStore(address(r.g.posting)),
                PostingKey.wrap(Keys.scopeBelowList(_pid(alice), Purpose.TAG, t[0]))
            ),
            _list1(_ordinal(alice, Purpose.TAG, t[2], _thing("flag"))),
            "live roll-up"
        );
        // the history path reads it, exactly once for this one first tag
        vm.record();
        _buildAll(ix);
        assertEq(_readsOf(word1), 1, "the build reads the first admission once");
    }
}
