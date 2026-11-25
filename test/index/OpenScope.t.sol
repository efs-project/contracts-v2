// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {OpenScopeReader} from "../../src/readers/OpenScopeReader.sol";
import {Keys} from "../../src/lib/Keys.sol";
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
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, OpenScopeConfig, Unit} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";

/// @notice SPIKE (tags-index): the all-authors families 6 (open-scope), 7 (open-scope-below), 9 (open-scope-word)
///         and 2 (word-directory) on a mock-registry kernel: list semantics, the replay rule for topic stand-ins
///         registered after a tag, replay equals live over a mixed history, and the spike page reader.
contract OpenScopeIndexTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;
    OpenScopeReader internal reader;
    /// SPIKE stand-in: a topic is a record of this Type, body word 0 = parent topic id, word 1 = word id.
    bytes32 internal constant TOPIC = keccak256("test/type/topic-stand-in");
    bytes32 internal constant THING = keccak256("test/type/thing");
    bytes32 internal constant TAG = Purpose.TAG;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    bytes32 internal me;
    mapping(address => uint64) internal nonces;
    bytes32[] internal things;

    function _config() internal pure virtual returns (OpenScopeConfig memory os) {
        os.exact = true;
        os.topicTypeId = TOPIC;
        os.depthCap = 64;
        os.paths = true;
        os.words = true;
        os.directory = true;
    }

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("open-scope/salt"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        g = IndexDeploy.deploy(
            k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), new DigestSpec[](0), _config()
        );
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k, address(this), address(registry), address(g.index), g.index.manifestHash()
                )
            );
        AcceptAll acceptAll = new AcceptAll();
        TypeInfo memory info;
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = address(acceptAll);
        info.ruleId = address(acceptAll).codehash;
        info.policyRows = 1;
        info.policyRow = 1;
        registry.setType(TOPIC, info, new bytes32[](0));
        registry.setType(THING, info, new bytes32[](0));
        me = Keys.principalFor(address(this), hot.realmOrigin());
        reader = new OpenScopeReader();
        // ten things to tag (records of THING)
        Action[] memory a = new Action[](10);
        bytes[] memory b = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            b[i] = abi.encode("thing", i);
            a[i].kind = ActionKind.PUBLISH;
            a[i].typeId = THING;
            a[i].bodyHashOrRecordId = keccak256(b[i]);
            things.push(Keys.recordFromHash(THING, keccak256(b[i])));
        }
        _exec(address(this), a, b);
    }

    // ---- builders ---------------------------------------------------------------------------------------------

    function _exec(address who, Action[] memory a, bytes[] memory b) internal returns (uint64 p) {
        Native memory ctx;
        ctx.nonce = nonces[who]++;
        if (who != address(this)) vm.prank(who, who);
        (p,) = ledger.execute(a, b, ctx, "");
    }

    function _one(address who, Action memory x) internal returns (uint64) {
        Action[] memory a = new Action[](1);
        a[0] = x;
        return _exec(who, a, new bytes[](1));
    }

    function _act(uint8 kind, bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = kind;
        a.purpose = TAG;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _tag(address who, bytes32 topic, uint256 thing) internal returns (uint64) {
        return _one(who, _act(ActionKind.BIND, topic, things[thing], things[thing], 0));
    }

    function _topicBody(bytes32 parent, bytes32 word) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(parent, word), "topic stand-in");
    }

    function _topicId(bytes32 parent, bytes32 word) internal pure returns (bytes32) {
        return Keys.recordFromHash(TOPIC, keccak256(_topicBody(parent, word)));
    }

    function _register(bytes32 parent, bytes32 word) internal returns (bytes32 id) {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        b[0] = _topicBody(parent, word);
        a[0].kind = ActionKind.PUBLISH;
        a[0].typeId = TOPIC;
        a[0].bodyHashOrRecordId = keccak256(b[0]);
        _exec(address(this), a, b);
        return _topicId(parent, word);
    }

    function _list(IPostingStore s, uint8 kind, bytes32 value)
        internal
        view
        returns (uint64 count, uint64[] memory entries)
    {
        PostingKey pk = PostingKey.wrap(Keys.posting(0, kind, 0, Keys.openScope(TAG, value)));
        (count,,,) = s.postingHead(pk);
        entries = s.postingSlice(pk, 0, 256);
    }

    function _exactKey(bytes32 purpose, bytes32 subject) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, 6, 0, Keys.openScope(purpose, subject)));
    }

    function _kindKey(uint8 kind, bytes32 value) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, kind, 0, Keys.openScope(TAG, value)));
    }

    function _dirKey(bytes32 word) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(TOPIC, 2, 0, word));
    }

    // ---- family 6 ---------------------------------------------------------------------------------------------

    function testTwoAuthorsOnOneTopicShareOneList() public {
        bytes32 x = keccak256("topic/x");
        (uint64 a1,,,) = hot.counts();
        _tag(address(this), x, 0);
        _tag(alice, x, 0);
        _tag(alice, x, 1);
        (uint64 n, uint64[] memory e) = _list(g.posting, 6, x);
        assertEq(n, 3);
        assertEq(abi.encode(e[0], e[1], e[2]), abi.encode(a1 + 1, a1 + 2, a1 + 3));
        (Coverage c, uint64 count,,,) = g.index
            .postingHeadOf(
                FamilyId.wrap(Keys.familyId("open-scope")),
                TypeId.wrap(0),
                0,
                Keys.openScope(TAG, x)
            );
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 3);
    }

    function testEveryPurposeIsListed() public {
        bytes32 folder = keccak256("some folder");
        Action memory a = _act(ActionKind.BIND, folder, keccak256("name"), things[0], 0);
        a.purpose = Purpose.FOLDER;
        _one(alice, a);
        (uint64 n,,,) = g.posting.postingHead(_exactKey(Purpose.FOLDER, folder));
        assertEq(n, 1);
    }

    function testAFirstMaskLandsInTheList() public {
        bytes32 x = keccak256("topic/x");
        uint64 p = _one(bob, _act(ActionKind.UNBIND, x, things[2], 0, 0));
        assertGt(p, 0);
        (uint64 n, uint64[] memory e) = _list(g.posting, 6, x);
        assertEq(n, 1);
        (uint64 adm,,,) = hot.counts();
        assertEq(e[0], adm);
    }

    function testLaterTransitionsAppendNothing() public {
        bytes32 x = keccak256("topic/x");
        _tag(alice, x, 0); // FIRST_BIND, rev 1
        _one(alice, _act(ActionKind.BIND, x, things[0], things[1], 1)); // REBIND, rev 2
        _one(alice, _act(ActionKind.UNBIND, x, things[0], 0, 2)); // MASK, rev 3
        _one(alice, _act(ActionKind.BIND, x, things[0], things[0], 3)); // RESTORE, rev 4
        _one(alice, _act(ActionKind.RELEASE, x, things[0], 0, 4)); // RELEASE, rev 5
        _one(alice, _act(ActionKind.UNBIND, x, things[0], 0, 5)); // MASK from RELEASED
        (uint64 n,) = _list(g.posting, 6, x);
        assertEq(n, 1, "one entry per (author, position)");
    }

    // ---- families 7, 9, 2 and the replay rule ------------------------------------------------------------------

    function testRollUpAndWordsFollowRegisteredTopics() public {
        bytes32 wCars = keccak256("word/cars");
        bytes32 wTesla = keccak256("word/tesla");
        bytes32 cars = _register(0, wCars);
        bytes32 tesla = _register(cars, wTesla);
        uint64 t = _tag(alice, tesla, 0);
        t;
        (uint64 adm,,,) = hot.counts();
        (uint64 n, uint64[] memory e) = _list(g.posting, 7, cars);
        assertEq(n, 1, "listed below /cars");
        assertEq(e[0], adm);
        (n,) = _list(g.posting, 7, tesla);
        assertEq(n, 0, "the exact path is kind 6, not 7");
        (n,) = _list(g.posting, 6, tesla);
        assertEq(n, 1);
        (n,) = _list(g.posting, 9, wCars);
        assertEq(n, 1);
        (n,) = _list(g.posting, 9, wTesla);
        assertEq(n, 1);
        (uint64 d1,,,) = g.posting.postingHead(_dirKey(wCars));
        (uint64 d2,,,) = g.posting.postingHead(_dirKey(wTesla));
        assertEq(abi.encode(d1, d2), abi.encode(2, 1), "cars lists both paths, tesla one");
    }

    function testARepeatedWordIsListedOnce() public {
        bytes32 w = keccak256("word/again");
        bytes32 a = _register(0, w);
        bytes32 b = _register(a, keccak256("word/middle"));
        bytes32 c = _register(b, w);
        _tag(alice, c, 0);
        (uint64 n,) = _list(g.posting, 9, w);
        assertEq(n, 1);
        (uint64 d,,,) = g.posting.postingHead(_dirKey(w));
        assertEq(d, 3, "a, b and c are each listed once under w (c's path repeats it)");
    }

    function testATagBeforeItsTopicIsRegisteredRollsUpNothing() public {
        bytes32 wCars = keccak256("word/cars");
        bytes32 cars = _register(0, wCars);
        bytes32 later = _topicId(cars, keccak256("word/later"));
        _tag(alice, later, 0); // the topic record does not exist yet
        _register(cars, keccak256("word/later"));
        (uint64 n,) = _list(g.posting, 7, cars);
        assertEq(n, 0, "no roll-up for a tag admitted before its topic");
        _tag(bob, later, 0); // after registration: rolls up
        (n,) = _list(g.posting, 7, cars);
        assertEq(n, 1);
        (n,) = _list(g.posting, 6, later);
        assertEq(n, 2);
    }

    function testDepth64AndTheCap() public {
        bytes32 cur;
        for (uint256 i; i < 64; ++i) {
            cur = _register(cur, keccak256(abi.encode("w", i)));
        }
        _tag(alice, cur, 0);
        (uint64 n,) = _list(g.posting, 9, keccak256(abi.encode("w", 0)));
        assertEq(n, 1, "the root word is reached at depth 64");
        n = 0;
        bytes32 c;
        for (uint256 i; i < 63; ++i) {
            c = _topicId(c, keccak256(abi.encode("w", i)));
            (uint64 m,) = _list(g.posting, 7, c);
            n += m;
        }
        assertEq(n, 63, "63 ancestor paths");
    }

    // ---- replay equals live over a mixed history --------------------------------------------------------------

    bytes32[] internal touched6;
    bytes32[] internal touched7;
    bytes32[] internal touched9;
    bytes32[] internal touchedDir;

    function _mixedHistory() internal {
        bytes32 wA = keccak256("word/a");
        bytes32 wB = keccak256("word/b");
        bytes32 wD = keccak256("word/d");
        bytes32 wU = keccak256("word/u");
        bytes32 tA = _register(0, wA);
        bytes32 tB = _register(tA, wB);
        bytes32 tC = _register(tB, wA); // the word of A again
        bytes32 tD = _register(tC, wD);
        bytes32 tU = _topicId(tA, wU);
        bytes32 loose = keccak256("unregistered, never a record");
        _tag(address(this), tD, 0);
        _tag(alice, tD, 0);
        _tag(alice, tD, 1);
        _tag(bob, tC, 2);
        _tag(alice, tU, 3); // before U exists
        _register(tA, wU);
        _tag(bob, tU, 3); // after
        _tag(bob, loose, 4);
        _one(bob, _act(ActionKind.UNBIND, tD, things[5], 0, 0)); // lone negative
        _one(alice, _act(ActionKind.UNBIND, tB, things[6], 0, 0)); // lone negative on B
        _one(alice, _act(ActionKind.BIND, tD, things[0], things[7], 1)); // rebind
        _one(alice, _act(ActionKind.UNBIND, tD, things[1], 0, 1)); // mask
        _one(alice, _act(ActionKind.BIND, tD, things[1], things[1], 2)); // restore
        _one(bob, _act(ActionKind.RELEASE, tC, things[2], 0, 1)); // release
        _one(bob, _act(ActionKind.BIND, tD, things[5], things[5], 1)); // restore over a first mask
        Action memory f = _act(ActionKind.BIND, keccak256("folder"), keccak256("n"), things[8], 0);
        f.purpose = Purpose.FOLDER;
        _one(alice, f);
        touched6 = [tA, tB, tC, tD, tU, loose];
        touched7 = [tA, tB, tC, tD, tU];
        touched9 = [wA, wB, wD, wU];
        touchedDir = [wA, wB, wD, wU];
    }

    function _assertSame(IPostingStore a, IPostingStore b, PostingKey pk) internal view {
        (uint64 c1, uint64 l1, uint64 x1, uint16 f1) = a.postingHead(pk);
        (uint64 c2, uint64 l2, uint64 x2, uint16 f2) = b.postingHead(pk);
        assertEq(abi.encode(c1, l1, x1, f1), abi.encode(c2, l2, x2, f2), "posting head");
        assertEq(
            keccak256(abi.encode(a.postingSlice(pk, 0, 256))),
            keccak256(abi.encode(b.postingSlice(pk, 0, 256))),
            "posting entries"
        );
    }

    function testReplayEqualsLiveForEveryNewFamily() public {
        _mixedHistory();
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = new Unit[](0);
        plan.specs = new DigestSpec[](0);
        plan.work = IndexDoubleDefaults.workModel();
        plan.os = _config();
        IndexDeployer d = new IndexDeployer(k.proxy, keccak256(abi.encode(plan)));
        RealmIndex ix = RealmIndex(d.run(plan));
        while (ix.replayNextPublication(64) != 0) {}
        assertTrue(ix.replayReadiness().ready);
        IPostingStore p2 = IPostingStore(d.postingStore());
        uint256 nonEmpty;
        for (uint256 i; i < touched6.length; ++i) {
            _assertSame(g.posting, p2, _exactKey(TAG, touched6[i]));
            (uint64 c,,,) = g.posting.postingHead(_exactKey(TAG, touched6[i]));
            if (c != 0) ++nonEmpty;
        }
        _assertSame(g.posting, p2, _exactKey(Purpose.FOLDER, keccak256("folder")));
        for (uint256 i; i < touched7.length; ++i) {
            _assertSame(g.posting, p2, _kindKey(7, touched7[i]));
        }
        for (uint256 i; i < touched9.length; ++i) {
            _assertSame(g.posting, p2, _kindKey(9, touched9[i]));
            _assertSame(g.posting, p2, _dirKey(touchedDir[i]));
        }
        assertEq(nonEmpty, 5, "A has no direct tag");
        // A's below list: the first statements on B, C, D and U's late tag; U's early tag never rolled up
        (uint64 n,) = _list(p2, 7, touched7[0]);
        assertEq(n, 7, "D: me, alice x2, bob's negative; C: bob; B: alice's negative; U: bob");
        (uint64 dA,,,) = p2.postingHead(_dirKey(touchedDir[0]));
        assertEq(dA, 5, "word a lists A, B, C, D and U (each has a on its path)");
    }

    // ---- the spike reader --------------------------------------------------------------------------------------

    function _q(uint8 kind, bytes32 key, uint64 from, uint16 count, bool newest, bool dead)
        internal
        pure
        returns (OpenScopeReader.Query memory q)
    {
        q.kind = kind;
        q.purpose = TAG;
        q.key = key;
        q.from = from;
        q.count = count;
        q.newestFirst = newest;
        q.minNumber = type(int16).min;
        q.includeDead = dead;
    }

    function testReaderOrderPagingAndDeadEntries() public {
        bytes32 x = keccak256("topic/x");
        address[3] memory who = [address(this), alice, bob];
        uint64[] memory adm = new uint64[](12);
        for (uint256 i; i < 12; ++i) {
            if (i % 4 == 3) {
                _one(who[i % 3], _act(ActionKind.UNBIND, x, things[i % 10], 0, 0)); // dead (masked)
            } else {
                _tag(who[i % 3], x, i % 10);
            }
            (adm[i],,,) = hot.counts();
        }
        (uint64 len, uint64 next, OpenScopeReader.Row[] memory rows) =
            reader.page(address(ledger), _q(6, x, 0, 5, false, false));
        assertEq(len, 12);
        assertEq(rows.length, 5);
        assertEq(rows[0].admission, adm[0]);
        assertEq(rows[3].admission, adm[4], "entry 3 (masked) skipped");
        assertEq(next, 6);
        assertEq(rows[1].principalId, Keys.principal(alice));
        assertEq(rows[0].principalId, me);
        assertEq(rows[0].state, 1);
        assertEq(rows[0].target, things[0]);
        assertEq(rows[0].role, things[0]);
        // newest first from the end
        (len, next, rows) = reader.page(address(ledger), _q(6, x, 0, 4, true, false));
        assertEq(rows[0].admission, adm[10]);
        assertEq(rows[1].admission, adm[9]);
        assertEq(rows[2].admission, adm[8]);
        assertEq(rows[3].admission, adm[6]);
        assertEq(next, 6);
        // continue from the cursor
        (len, next, rows) = reader.page(address(ledger), _q(6, x, next, 20, true, false));
        assertEq(rows.length, 5);
        assertEq(rows[4].admission, adm[0]);
        assertEq(next, 12);
        // dead entries included, with their number
        (len, next, rows) = reader.page(address(ledger), _q(6, x, 0, 12, false, true));
        assertEq(rows.length, 12);
        assertEq(rows[3].state, 2);
        assertEq(rows[3].number, -1);
        assertEq(rows[3].target, 0);
        // minNumber 0 drops the masked rows even with includeDead
        OpenScopeReader.Query memory q = _q(6, x, 0, 12, false, true);
        q.minNumber = 0;
        (,, rows) = reader.page(address(ledger), q);
        assertEq(rows.length, 9);
    }

    function testReaderBelowListCarriesTheSubject() public {
        bytes32 a = _register(0, keccak256("w/a"));
        bytes32 b = _register(a, keccak256("w/b"));
        bytes32 c = _register(a, keccak256("w/c"));
        _tag(alice, b, 0);
        _tag(bob, c, 1);
        (uint64 len,, OpenScopeReader.Row[] memory rows) =
            reader.page(address(ledger), _q(7, a, 0, 10, true, false));
        assertEq(len, 2);
        assertEq(rows[0].subject, c);
        assertEq(rows[1].subject, b);
        (len,, rows) = reader.page(address(ledger), _q(9, keccak256("w/a"), 0, 10, false, false));
        assertEq(len, 2);
        assertEq(rows[0].subject, b);
        (uint64 dl, bytes32[] memory topics,) =
            reader.directory(address(ledger), TOPIC, keccak256("w/a"), 0, 10, false);
        assertEq(dl, 3);
        assertEq(abi.encode(topics[0], topics[1], topics[2]), abi.encode(a, b, c));
    }
}
