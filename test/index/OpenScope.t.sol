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
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, OpenScopeConfig, Unit} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice SPIKE (tags-index2): the topic lists on a mock-registry kernel — family 6 (place), 20 (position-authors),
///         19 (per-author roll-up), 7 (all-authors roll-up) — over word-page and path stand-in Types of the owner-
///         ruled shapes (a word page: body = the word's bytes; a path: body exactly `[parent, wordPage]`, both
///         declared references, so family 11 is written). List semantics, the restore law (no transition after a
///         first statement appends), the family-11 directories, rebuild equals live, and the spike reader views.
contract OpenScopeIndexTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;
    OpenScopeReader internal reader;
    bytes32 internal constant WORD = keccak256("test/type/word-page-stand-in");
    bytes32 internal constant PATH = keccak256("test/type/path-stand-in");
    bytes32 internal constant THING = keccak256("test/type/thing");
    bytes32 internal constant TAG = Purpose.TAG;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    bytes32 internal me;
    mapping(address => uint64) internal nonces;
    bytes32[] internal things;

    function _trust() internal pure virtual returns (bool) {
        return false;
    }

    function _config() internal pure returns (OpenScopeConfig memory os) {
        os.wordTypeId = WORD;
        os.pathTypeId = PATH;
        os.scopeBelow = true;
        os.allAuthors = new bytes32[](2);
        os.allAuthors[0] = TAG;
        os.allAuthors[1] = Purpose.FOLDER;
        os.allBelow = true;
        os.trustRegistered = _trust();
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
        registry.setType(WORD, info, new bytes32[](0));
        registry.setType(THING, info, new bytes32[](0));
        info.refCount = 2;
        bytes32[] memory refTypes = new bytes32[](2);
        refTypes[0] = 0; // ANY: a word page or a path
        refTypes[1] = WORD;
        registry.setType(PATH, info, refTypes);
        me = Keys.principalFor(address(this), hot.realmOrigin());
        reader = new OpenScopeReader();
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

    function _deny(address who, bytes32 topic, uint256 thing) internal returns (uint64) {
        return _one(who, _act(ActionKind.UNBIND, topic, things[thing], 0, 0));
    }

    function _wordBody(string memory w) internal pure returns (bytes memory) {
        return bytes(w);
    }

    function _wordId(string memory w) internal pure returns (bytes32) {
        return Keys.record(WORD, _wordBody(w));
    }

    function _pathId(bytes32 parent, bytes32 wordPage) internal pure returns (bytes32) {
        return Keys.record(PATH, abi.encode(parent, wordPage));
    }

    function _publish(bytes32 t, bytes memory body) internal returns (bytes32) {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        b[0] = body;
        a[0].kind = ActionKind.PUBLISH;
        a[0].typeId = t;
        a[0].bodyHashOrRecordId = keccak256(body);
        _exec(address(this), a, b);
        return Keys.record(t, body);
    }

    function _word(string memory w) internal returns (bytes32) {
        bytes32 id = _wordId(w);
        (, uint64 first,,,) = hot.recordHeader(id);
        if (first != 0) return id;
        return _publish(WORD, _wordBody(w));
    }

    function _path(bytes32 parent, string memory w) internal returns (bytes32) {
        return _publish(PATH, abi.encode(parent, _word(w)));
    }

    /// `/w0/w1/.../w(n-1)`: returns the topic of every prefix (index 0 the word page w0).
    function _chain(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        t = new bytes32[](n);
        t[0] = _word(string.concat(name, "0"));
        for (uint256 i = 1; i < n; ++i) {
            t[i] = _path(t[i - 1], string.concat(name, vm.toString(i)));
        }
    }

    // ---- list probes ------------------------------------------------------------------------------------------

    function _pk(uint8 kind, bytes32 value) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, kind, 0, value));
    }

    function _place(bytes32 purpose, bytes32 subject) internal pure returns (PostingKey) {
        return _pk(6, Keys.openScope(purpose, subject));
    }

    function _allBelow(bytes32 ancestor) internal pure returns (PostingKey) {
        return _pk(7, Keys.openScope(TAG, ancestor));
    }

    function _mineBelow(bytes32 principal, bytes32 ancestor) internal pure returns (PostingKey) {
        return _pk(19, Keys.scopeBelow(principal, TAG, ancestor));
    }

    function _authorsKey(bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        pure
        returns (PostingKey)
    {
        return _pk(20, Keys.position(purpose, subject, role));
    }

    function _count(PostingKey pk) internal view returns (uint64 n) {
        (n,,,) = g.posting.postingHead(pk);
    }

    function _entries(PostingKey pk) internal view returns (uint64[] memory) {
        return g.posting.postingSlice(pk, 0, 512);
    }

    function _ordinal(address who, bytes32 subject, uint256 thing)
        internal
        view
        returns (uint64 o)
    {
        bytes32 principal = who == address(this) ? me : Keys.principal(who);
        (,,,,, o,) = hot.head(Keys.binding(principal, Keys.position(TAG, subject, things[thing])));
    }

    // ---- the place and position-authors lists (families 6, 20) ------------------------------------------------

    function testPlaceListHasOneEntryPerPosition() public {
        bytes32 x = _word("x");
        _tag(address(this), x, 0);
        (uint64 a1,,,) = hot.counts();
        _tag(alice, x, 0); // the same position: no place entry
        (uint64 a2,,,) = hot.counts();
        _tag(alice, x, 1);
        assertEq(_count(_place(TAG, x)), 2, "two positions");
        uint64[] memory e = _entries(_place(TAG, x));
        assertEq(
            e[0], _ordinal(address(this), x, 0), "entry = the first statement's binding ordinal"
        );
        assertEq(e[1], _ordinal(alice, x, 1));
        PostingKey pa = _authorsKey(TAG, x, things[0]);
        assertEq(_count(pa), 2, "two authors at thing 0");
        e = _entries(pa);
        assertEq(abi.encode(e[0], e[1]), abi.encode(a1, a2), "entry = the admission ordinal");
        (Coverage c, uint64 count,,,) = g.index
            .postingHeadOf(
                FamilyId.wrap(Keys.familyId("open-scope")),
                TypeId.wrap(0),
                0,
                Keys.openScope(TAG, x)
            );
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 2);
    }

    function testFolderHasTwoLevelsAndHeadNone() public {
        bytes32 folder = keccak256("some folder");
        Action memory f = _act(ActionKind.BIND, folder, keccak256("pet.jpg"), things[0], 0);
        f.purpose = Purpose.FOLDER;
        _one(alice, f);
        _one(bob, f);
        assertEq(_count(_place(Purpose.FOLDER, folder)), 1);
        assertEq(_count(_authorsKey(Purpose.FOLDER, folder, keccak256("pet.jpg"))), 2);
        Action memory h = _act(ActionKind.BIND, things[1], 0, things[2], 0);
        h.purpose = Purpose.HEAD;
        _one(alice, h);
        assertEq(_count(_place(Purpose.HEAD, things[1])), 0, "HEAD is not listed");
        assertEq(_count(_authorsKey(Purpose.HEAD, things[1], 0)), 0);
    }

    function testALoneNegativeIsAFirstStatement() public {
        bytes32 x = _word("x");
        _deny(bob, x, 2);
        assertEq(_count(_place(TAG, x)), 1);
        assertEq(_count(_authorsKey(TAG, x, things[2])), 1);
    }

    // ---- the roll-ups (families 19, 7) ------------------------------------------------------------------------

    function testRollUpsListProperAncestorsOnly() public {
        bytes32[] memory t = _chain("r", 3); // /r0, /r0/r1, /r0/r1/r2
        _tag(alice, t[2], 0);
        bytes32 pa = Keys.principal(alice);
        uint64 o = _ordinal(alice, t[2], 0);
        for (uint256 i; i < 2; ++i) {
            assertEq(_count(_mineBelow(pa, t[i])), 1, "alice below each proper ancestor");
            assertEq(_entries(_mineBelow(pa, t[i]))[0], o);
            assertEq(_count(_allBelow(t[i])), 1, "all-authors below each proper ancestor");
            assertEq(_entries(_allBelow(t[i]))[0], o);
        }
        assertEq(_count(_mineBelow(pa, t[2])), 0, "the topic itself is the exact scope list");
        assertEq(_count(_allBelow(t[2])), 0);
        // a second author on the same position: her own roll-up, no all-authors entry (the position exists)
        _tag(bob, t[2], 0);
        assertEq(_count(_mineBelow(Keys.principal(bob), t[0])), 1);
        assertEq(_count(_allBelow(t[0])), 1);
        // a new position by bob: both
        _tag(bob, t[2], 1);
        assertEq(_count(_mineBelow(Keys.principal(bob), t[0])), 2);
        assertEq(_count(_allBelow(t[0])), 2);
    }

    function testAWordPageAndAHomeHaveNoAncestors() public {
        bytes32 w = _word("solo");
        _tag(alice, w, 0);
        bytes32 home = bytes32(uint256(uint160(address(0xBEEF))));
        _tag(alice, home, 1);
        assertEq(_count(_mineBelow(Keys.principal(alice), w)), 0);
        assertEq(_count(_allBelow(w)), 0);
        assertEq(_count(_place(TAG, home)), 1, "a home is a place");
    }

    function testATagBeforeItsPathIsRegisteredRollsUpNothing() public {
        if (_trust()) return; // the trusted build relies on a validator this mock realm does not have
        bytes32 cars = _word("cars");
        bytes32 later = _pathId(cars, _word("later"));
        _tag(alice, later, 0); // the path record does not exist yet
        _path(cars, "later");
        assertEq(_count(_allBelow(cars)), 0, "no roll-up for a tag admitted before its path");
        assertEq(_count(_mineBelow(Keys.principal(alice), cars)), 0);
        _tag(bob, later, 1);
        assertEq(_count(_allBelow(cars)), 1);
    }

    function testDepth64() public {
        bytes32[] memory t = _chain("d", 64);
        _tag(alice, t[63], 0);
        uint256 n;
        uint256 m;
        for (uint256 i; i < 63; ++i) {
            n += _count(_allBelow(t[i]));
            m += _count(_mineBelow(Keys.principal(alice), t[i]));
        }
        assertEq(abi.encode(n, m), abi.encode(63, 63), "63 proper ancestors each");
    }

    /// Word pages keep no item list: a topic's children and the topics that use a word are family 11.
    function testFamily11AnswersBothDirectories() public {
        bytes32 cars = _word("cars");
        bytes32 red = _word("red");
        bytes32 carsRed = _path(cars, "red");
        bytes32 carsBlue = _path(cars, "blue");
        bytes32 carsRedRed = _path(carsRed, "red");
        PostingKey children = PostingKey.wrap(Keys.referenceList(PATH, 0, cars));
        PostingKey usesRed = PostingKey.wrap(Keys.referenceList(PATH, 1, red));
        assertEq(_count(children), 2, "cars/red and cars/blue");
        assertEq(_count(usesRed), 2, "cars/red and cars/red/red");
        uint64[] memory e = g.posting.postingSlice(children, 0, 8);
        (, uint64 f1,,,) = hot.recordHeader(carsRed);
        (, uint64 f2,,,) = hot.recordHeader(carsBlue);
        assertEq(abi.encode(e[0], e[1]), abi.encode(f1, f2), "entries are the paths' admissions");
        e = g.posting.postingSlice(usesRed, 0, 8);
        (, uint64 f3,,,) = hot.recordHeader(carsRedRed);
        assertEq(abi.encode(e[0], e[1]), abi.encode(f1, f3));
        assertEq(_count(PostingKey.wrap(Keys.referenceList(PATH, 0, carsRed))), 1);
    }

    // ---- the restore law: no transition after a first statement appends anywhere --------------------------------

    function _snap(PostingKey[] memory keys) internal view returns (bytes memory out) {
        for (uint256 i; i < keys.length; ++i) {
            (uint64 c, uint64 l, uint64 x, uint16 f) = g.posting.postingHead(keys[i]);
            out = bytes.concat(out, abi.encode(c, l, x, f, g.posting.postingSlice(keys[i], 0, 64)));
        }
    }

    function _lawKeys(bytes32[] memory t, address who, uint256 thing)
        internal
        view
        returns (PostingKey[] memory keys)
    {
        bytes32 p = who == address(this) ? me : Keys.principal(who);
        keys = new PostingKey[](6);
        keys[0] = _mineBelow(p, t[0]);
        keys[1] = _mineBelow(p, t[1]);
        keys[2] = _place(TAG, t[2]);
        keys[3] = _authorsKey(TAG, t[2], things[thing]);
        keys[4] = _allBelow(t[0]);
        keys[5] = _allBelow(t[1]);
    }

    function _scopeSnap(bytes32[] memory t, address who) internal view returns (bytes memory) {
        bytes32 p = who == address(this) ? me : Keys.principal(who);
        ScopeKey s = ScopeKey.wrap(Keys.scope(p, TAG, t[2]));
        (uint64 c,,,,, uint64 e0) = g.bitmap.scopeHead(s);
        return abi.encode(c, e0, g.bitmap.scopeSlice(s, 0, 64));
    }

    function testRemoveAndAddBackAppendsNothing() public {
        bytes32[] memory t = _chain("law", 3);
        bytes32 x = t[2];
        // assert, release, assert again (RELEASE then RESTORE)
        _tag(alice, x, 0);
        PostingKey[] memory keys = _lawKeys(t, alice, 0);
        bytes memory before = _snap(keys);
        bytes memory sb = _scopeSnap(t, alice);
        _one(alice, _act(ActionKind.RELEASE, x, things[0], 0, 1));
        _one(alice, _act(ActionKind.BIND, x, things[0], things[0], 2));
        assertEq(_snap(keys), before, "assert, release, assert");
        // assert, mask, assert again (MASK then RESTORE)
        _one(alice, _act(ActionKind.UNBIND, x, things[0], 0, 3));
        _one(alice, _act(ActionKind.BIND, x, things[0], things[0], 4));
        assertEq(_snap(keys), before, "assert, mask, assert");
        assertEq(_scopeSnap(t, alice), sb, "the exact scope list too");
        // lone negative, release, lone negative again (FIRST_MASK, RELEASE, MASK)
        _deny(alice, x, 1);
        keys = _lawKeys(t, alice, 1);
        before = _snap(keys);
        _one(alice, _act(ActionKind.RELEASE, x, things[1], 0, 1));
        _one(alice, _act(ActionKind.UNBIND, x, things[1], 0, 2));
        assertEq(_snap(keys), before, "negative, release, negative");
        // a second author on the same positions, the same three sequences
        _tag(bob, x, 0);
        keys = _lawKeys(t, bob, 0);
        before = _snap(keys);
        _one(bob, _act(ActionKind.RELEASE, x, things[0], 0, 1));
        _one(bob, _act(ActionKind.BIND, x, things[0], things[0], 2));
        _one(bob, _act(ActionKind.UNBIND, x, things[0], 0, 3));
        _one(bob, _act(ActionKind.BIND, x, things[0], things[0], 4));
        assertEq(_snap(keys), before, "second author: release and mask round trips");
        _deny(bob, x, 1);
        keys = _lawKeys(t, bob, 1);
        before = _snap(keys);
        _one(bob, _act(ActionKind.RELEASE, x, things[1], 0, 1));
        _one(bob, _act(ActionKind.UNBIND, x, things[1], 0, 2));
        assertEq(_snap(keys), before, "second author: negative, release, negative");
        assertEq(_count(_authorsKey(TAG, x, things[0])), 2, "one entry per author");
        assertEq(_count(_place(TAG, x)), 2, "one entry per position");
    }

    // ---- rebuild equals live over a mixed history -------------------------------------------------------------

    PostingKey[] internal touched;
    ScopeKey[] internal touchedScopes;

    function _touch(PostingKey k_) internal {
        touched.push(k_);
    }

    function _mixedHistory() internal {
        // registrations at several depths, out of order across publications
        bytes32 a = _word("a");
        bytes32 b = _word("b");
        bytes32 ab = _path(a, "b");
        bytes32 abc = _path(ab, "c");
        bytes32 ba = _path(b, "a");
        bytes32 abcd = _path(abc, "d");
        bytes32 later = _pathId(ab, _word("z")); // tagged before it exists
        bytes32 home = bytes32(uint256(uint160(address(0xBEEF))));
        _tag(address(this), abcd, 0);
        _tag(alice, abcd, 0); // a second author on an existing position
        _tag(alice, abcd, 1);
        _tag(bob, abc, 2);
        _tag(alice, later, 3); // before its path exists
        _path(ab, "z");
        _tag(bob, later, 3); // after
        _tag(bob, home, 4); // a home as subject
        _tag(carol, ba, 5);
        _deny(bob, abcd, 5); // lone negative
        _deny(alice, ab, 6); // lone negative on a middle topic
        _one(alice, _act(ActionKind.BIND, abcd, things[0], things[7], 1)); // rebind
        _one(alice, _act(ActionKind.UNBIND, abcd, things[1], 0, 1)); // mask
        _one(alice, _act(ActionKind.BIND, abcd, things[1], things[1], 2)); // restore
        _one(bob, _act(ActionKind.RELEASE, abc, things[2], 0, 1)); // release
        _one(bob, _act(ActionKind.BIND, abcd, things[5], things[5], 1)); // restore over a first mask
        _one(bob, _act(ActionKind.BIND, abc, things[2], things[2], 2)); // restore after release
        Action memory f = _act(ActionKind.BIND, keccak256("folder"), keccak256("n"), things[8], 0);
        f.purpose = Purpose.FOLDER;
        _one(alice, f);
        _one(bob, f);
        _one(carol, f);
        // a batch: one publication, several first statements on one topic
        Action[] memory batch = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            batch[i] = _act(ActionKind.BIND, abc, things[6 + i], things[6 + i], 0);
        }
        _exec(carol, batch, new bytes[](3));
        bytes32[8] memory topics = [a, b, ab, abc, ba, abcd, later, home];
        address[4] memory who = [address(this), alice, bob, carol];
        for (uint256 i; i < topics.length; ++i) {
            _touch(_place(TAG, topics[i]));
            _touch(_allBelow(topics[i]));
            _touch(PostingKey.wrap(Keys.referenceList(PATH, 0, topics[i])));
            _touch(PostingKey.wrap(Keys.referenceList(PATH, 1, topics[i])));
            for (uint256 j; j < who.length; ++j) {
                bytes32 p = j == 0 ? me : Keys.principal(who[j]);
                _touch(_mineBelow(p, topics[i]));
                touchedScopes.push(ScopeKey.wrap(Keys.scope(p, TAG, topics[i])));
                for (uint256 th; th < 10; ++th) {
                    _touch(_authorsKey(TAG, topics[i], things[th]));
                    _touch(
                        PostingKey.wrap(
                            Keys.historyList(
                                Keys.binding(p, Keys.position(TAG, topics[i], things[th]))
                            )
                        )
                    );
                }
            }
        }
        _touch(_place(Purpose.FOLDER, keccak256("folder")));
        _touch(_authorsKey(Purpose.FOLDER, keccak256("folder"), keccak256("n")));
        _touch(PostingKey.wrap(Keys.byTypeList(PATH)));
        _touch(PostingKey.wrap(Keys.byTypeList(WORD)));
        _touch(PostingKey.wrap(Keys.uniqueByTypeList(PATH)));
        for (uint256 th; th < 10; ++th) {
            _touch(PostingKey.wrap(Keys.backlinkList(things[th])));
        }
        for (uint256 j; j < who.length; ++j) {
            bytes32 p = j == 0 ? me : Keys.principal(who[j]);
            _touch(PostingKey.wrap(Keys.byAuthorList(p)));
        }
    }

    function _assertSame(IPostingStore x, IPostingStore y, PostingKey pk) internal view {
        (uint64 c1, uint64 l1, uint64 x1, uint16 f1) = x.postingHead(pk);
        (uint64 c2, uint64 l2, uint64 x2, uint16 f2) = y.postingHead(pk);
        assertEq(abi.encode(c1, l1, x1, f1), abi.encode(c2, l2, x2, f2), "posting head");
        assertEq(
            keccak256(abi.encode(x.postingSlice(pk, 0, 512))),
            keccak256(abi.encode(y.postingSlice(pk, 0, 512))),
            "posting entries"
        );
    }

    function testRebuildEqualsLive() public {
        if (_trust()) return; // a trusted build replays equal only behind its validator
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
        IBitmapStore b2 = IBitmapStore(d.bitmapStore());
        uint256 nonEmpty;
        for (uint256 i; i < touched.length; ++i) {
            _assertSame(g.posting, p2, touched[i]);
            (uint64 c,,,) = g.posting.postingHead(touched[i]);
            if (c != 0) ++nonEmpty;
        }
        for (uint256 i; i < touchedScopes.length; ++i) {
            ScopeKey s = touchedScopes[i];
            (uint64 c1, uint64 l1, uint64 m1, uint48 b1,, uint64 e1) = g.bitmap.scopeHead(s);
            (uint64 c2, uint64 l2, uint64 m2, uint48 bb2,, uint64 e2) = b2.scopeHead(s);
            assertEq(abi.encode(c1, l1, m1, b1, e1), abi.encode(c2, l2, m2, bb2, e2), "scope head");
            assertEq(abi.encode(g.bitmap.scopeSlice(s, 0, 64)), abi.encode(b2.scopeSlice(s, 0, 64)));
        }
        assertGt(nonEmpty, 40, "the history touched the lists");
        // spot checks on the rebuilt store
        bytes32 a = _wordId("a");
        bytes32 ab = _pathId(a, _wordId("b"));
        // positions below /a: abcd x2 (thing 0, 1), abcd thing 5 (bob's negative), abc thing 2, abc 6..8,
        // ab thing 6 (alice's negative) = 8. NOT `later` thing 3: its position was first stated (by alice) before
        // the path existed, so it was never fresh again when bob tagged it after registration — a position whose
        // first statement predates its topic is missing from the all-authors roll-up for good.
        (uint64 n,,,) = p2.postingHead(_allBelow(a));
        assertEq(n, 8, "all-authors below /a");
        (n,,,) = p2.postingHead(_mineBelow(Keys.principal(alice), a));
        assertEq(n, 3, "alice below /a: abcd 0, abcd 1, ab 6 (her early tag on z never rolled up)");
        (n,,,) = p2.postingHead(_mineBelow(Keys.principal(alice), ab));
        assertEq(n, 2, "alice below /a/b: abcd 0 and 1 (ab itself is exact)");
        (n,,,) = p2.postingHead(_authorsKey(Purpose.FOLDER, keccak256("folder"), keccak256("n")));
        assertEq(n, 3, "three authors on the folder name");
    }

    // ---- the spike reader ---------------------------------------------------------------------------------------

    function _lens2(bytes32 x, bytes32 y) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        l[0] = x;
        l[1] = y;
    }

    function _mineQ(bytes32[] memory lens, bytes32 topic, bool below, uint16 count)
        internal
        pure
        returns (OpenScopeReader.MineQuery memory q)
    {
        q.lens = lens;
        q.topic = topic;
        q.below = below;
        q.count = count;
    }

    function testMineMergesNewestFirstAppliesTheLensAndDedupes() public {
        bytes32[] memory t = _chain("m", 2); // /m0, /m0/m1
        bytes32 pa = Keys.principal(alice);
        bytes32 pb = Keys.principal(bob);
        _tag(alice, t[0], 0); // exact
        _tag(alice, t[1], 1); // below
        _tag(bob, t[0], 2); // exact, bob
        _tag(bob, t[1], 0); // thing 0 again, below: a duplicate by thing
        _deny(alice, t[0], 3); // alice denies thing 3 ...
        _tag(bob, t[0], 3); // ... which bob asserts
        _tag(alice, t[0], 4);
        _one(alice, _act(ActionKind.UNBIND, t[0], things[4], 0, 1)); // later masked: hidden for alice
        // lens [alice, bob], exact + below
        (OpenScopeReader.MineRow[] memory rows,) =
            reader.mine(address(ledger), _mineQ(_lens2(pa, pb), t[0], true, 20));
        // newest first by first statement: bob/3, alice deny 3, alice 4 (masked), bob below 0, bob 2, alice
        // below 1, alice 0. Lens decides: thing 3 -> alice negative -> hidden; thing 4 -> alice masked -> hidden;
        // bob below 0 -> alice has no stance at (t1, thing0) -> bob shows 0 under t1; bob 2 -> shown; alice 1
        // under t1; alice 0 under t0 -> a duplicate of thing 0 -> dropped.
        assertEq(rows.length, 3);
        assertEq(rows[0].thing, things[0]);
        assertEq(rows[0].topic, t[1]);
        assertEq(rows[0].decider, 1, "bob decided");
        assertEq(rows[1].thing, things[2]);
        assertEq(rows[2].thing, things[1]);
        assertEq(rows[2].topic, t[1]);
        // lens [bob, alice]: bob's assertion of thing 3 wins (the denial hides it only behind alice)
        (rows,) = reader.mine(address(ledger), _mineQ(_lens2(pb, pa), t[0], true, 20));
        assertEq(rows.length, 4, "3, 0 (t1), 2, 1");
        assertEq(rows[0].thing, things[3]);
        assertEq(rows[0].decider, 0);
        // exact only, lens [alice]
        bytes32[] memory l1 = new bytes32[](1);
        l1[0] = pa;
        (rows,) = reader.mine(address(ledger), _mineQ(l1, t[0], false, 20));
        assertEq(rows.length, 1, "thing 0 only: 3 denied, 4 masked");
        assertEq(rows[0].thing, things[0]);
        // paging: one row at a time continues from the cursor
        OpenScopeReader.MineQuery memory q = _mineQ(_lens2(pb, pa), t[0], true, 1);
        uint64[] memory next;
        (rows, next) = reader.mine(address(ledger), q);
        assertEq(rows[0].thing, things[3]);
        q.cursor = next;
        (rows, next) = reader.mine(address(ledger), q);
        // duplicates are removed within a page only: alice's denial of thing 3 is the next candidate and bob
        // (first in the lens) decides it, so the same position shows again on the next page
        assertEq(rows[0].thing, things[3]);
        assertEq(rows[0].bindingOrdinal, _ordinal(alice, t[0], 3));
        q.cursor = next;
        (rows, next) = reader.mine(address(ledger), q);
        assertEq(rows[0].thing, things[0]);
    }

    function _everyQ(bytes32 topic, bool below, uint16 count, bytes32[] memory lens, bool raw)
        internal
        pure
        returns (OpenScopeReader.EveryoneQuery memory q)
    {
        q.purpose = TAG;
        q.topic = topic;
        q.below = below;
        q.count = count;
        q.lens = lens;
        q.raw = raw;
    }

    function testEveryoneHidesOnlyForLensAuthorsAndCountsAuthors() public {
        bytes32[] memory t = _chain("e", 2);
        bytes32 x = t[1];
        _tag(alice, x, 0);
        _tag(bob, x, 0);
        _tag(carol, x, 0); // three authors, newest carol
        _tag(alice, x, 1);
        _deny(bob, x, 1); // bob denies thing 1
        _tag(alice, x, 2);
        bytes32[] memory lensBob = new bytes32[](1);
        lensBob[0] = Keys.principal(bob);
        (uint64 len,, OpenScopeReader.PlaceRow[] memory rows) =
            reader.everyone(address(ledger), _everyQ(x, false, 10, lensBob, false));
        assertEq(len, 3);
        assertEq(rows.length, 2, "thing 1 hidden behind bob");
        assertEq(rows[0].thing, things[2]);
        assertEq(rows[1].thing, things[0]);
        assertEq(rows[1].authors, 3);
        assertEq(rows[1].newestAuthor, Keys.principal(carol));
        assertEq(rows[1].state, 1);
        assertEq(rows[1].topic, x);
        bytes32[] memory lensCarol = new bytes32[](1);
        lensCarol[0] = Keys.principal(carol);
        (,, rows) = reader.everyone(address(ledger), _everyQ(x, false, 10, lensCarol, false));
        assertEq(rows.length, 3, "carol has no stance on thing 1");
        assertEq(rows[1].newestAuthor, Keys.principal(bob));
        assertEq(rows[1].number, -1, "bob's lone negative is the newest statement");
        (,, rows) = reader.everyone(address(ledger), _everyQ(x, false, 10, lensBob, true));
        assertEq(rows.length, 3, "raw");
        // below the parent: the same three positions
        (len,, rows) = reader.everyone(address(ledger), _everyQ(t[0], true, 2, lensBob, true));
        assertEq(len, 3);
        assertEq(rows.length, 2);
        assertEq(rows[0].thing, things[2]);
        assertEq(rows[0].topic, x);
        assertEq(reader.places(address(ledger), TAG, x), 3);
        assertEq(reader.authors(address(ledger), Keys.position(TAG, x, things[0])), 3);
    }

    function testByNameNewestFirst() public {
        bytes32 x = _word("pets");
        _tag(alice, x, 0);
        _tag(bob, x, 0);
        _deny(carol, x, 0);
        (uint64 len, OpenScopeReader.AuthorRow[] memory rows) =
            reader.byName(address(ledger), Keys.position(TAG, x, things[0]), 0, 2);
        assertEq(len, 3);
        assertEq(rows.length, 2);
        assertEq(rows[0].principalId, Keys.principal(carol));
        assertEq(rows[0].number, -1);
        assertEq(rows[1].principalId, Keys.principal(bob));
        assertEq(rows[1].target, things[0]);
        (, rows) = reader.byName(address(ledger), Keys.position(TAG, x, things[0]), 2, 2);
        assertEq(rows.length, 1);
        assertEq(rows[0].principalId, Keys.principal(alice));
    }
}

/// The same suite with `trustRegistered` on (the rebuild and before-registration cases are skipped there).
contract OpenScopeIndexTrustedTest is OpenScopeIndexTest {
    function _trust() internal pure override returns (bool) {
        return true;
    }
}
