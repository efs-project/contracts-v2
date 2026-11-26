// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsHistory} from "../integration/TopicListsHistory.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {
    HeadAuthorsGenesis,
    HeadAuthorsIndex,
    HeadAuthorsReads,
    IHeadAuthorsGeneration,
    ListIndexDeployer
} from "../harness/HeadAuthors.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    PostingKey,
    Purpose,
    ScopeKey
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice The shared setting of the step-3b suites (docs INDEX-BUILD §2.2, §8): the Files Realm of `TopicListsHistory`
///         with a HEAD history that moves every counter of the example list `file-versions` (provisional kind 24, a
///         test harness, not product: `test/harness/HeadAuthors.sol`; generation 1's own `head-authors`, family 22,
///         kept a second time under another id), the example generation over three stores (the two genesis stores
///         carried or fresh, a third `PostingStore` for `file-versions`) from `ListIndexDeployer`, a Realm L that runs
///         the example generation from genesis, and a capture of every recorded key of every family in the three
///         stores.
abstract contract HeadAuthorsBase is TopicListsHistory {
    /// The example list (`F_HEAD_AUTHORS` names it in the suites, as before the list release).
    bytes32 internal F_HEAD_AUTHORS = Keys.familyId("file-versions");
    uint256 internal constant BUILD_BUDGET = 64;

    /// When set before `_realm`, the Realm's genesis index is the example generation over three new stores whose
    /// `INITIAL_WRITER` is 0 (as genesis stores are): Realm L of §8 test 1.
    bool internal headAtGenesis;
    address internal genesisThird;

    PostingKey[] internal headKeys; // every example list the history touches
    bytes32[] internal headFiles; // the file of each, in the same order
    EfsFiles.Types internal ft;
    bytes32 internal f1; // the shared file of the HEAD history (created by this contract's principal)
    bytes32 internal f1Root;
    bytes32 internal f1Child;
    bytes32 internal f1Bob; // bob's own version of f1
    bytes32 internal f2; // alice's file
    bytes32 internal f2Root;

    function setUp() public virtual override {
        super.setUp();
        _types();
    }

    function _types() internal {
        ft.root = typeIds[T_ROOT];
        ft.child = typeIds[T_CHILD];
        ft.directory = typeIds[T_DIRECTORY];
        ft.name = typeIds[T_NAME];
    }

    // ---- the example generation ---------------------------------------------------------------------------------

    function _headFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](1);
        f[0] = Keys.familyId("file-versions");
    }

    /// The example generation's work model (`HeadAuthorsGenesis.workModel`).
    function _headWork() internal pure virtual returns (WorkModel memory) {
        return HeadAuthorsGenesis.workModel();
    }

    function _gen1(address ledger) internal virtual override returns (IndexDeploy.Gen1 memory g) {
        if (!headAtGenesis) return super._gen1(ledger);
        ListIndexDeployer.ReadsArgs memory x;
        x.ledger = ledger;
        x.hotAbiId = KernelDeploy.HOT_ABI_ID;
        x.units = _units();
        x.specs = _specs();
        x.work = _headWork();
        x.topicTypeId = typeIds[T_TOPIC];
        x.topicWordTypeId = typeIds[T_TOPIC_WORD];
        HeadAuthorsGenesis.Deployed memory d = HeadAuthorsGenesis.deploy(
            x, IndexDeploy.postingFamilies(), IndexDeploy.bitmapFamilies()
        );
        genesisThird = d.third;
        g.posting = PostingStore(d.posting);
        g.bitmap = BitmapStore(d.bitmap);
        g.reads = HeadAuthorsReads(d.reads);
        g.index = IGeneration1(d.index);
    }

    /// The example generation over `posting`, `bitmap` and `third`, each carried when nonzero and fresh (a new store
    /// naming the generation as INITIAL_WRITER) when zero, with the Realm's units, specs and topic Types.
    function _headGen(address posting, address bitmap, address third)
        internal
        returns (ListIndexDeployer d, IHeadAuthorsGeneration ix)
    {
        Unit[] memory units = _units();
        return _headGenWith(posting, bitmap, third, units, units.length);
    }

    function _headGenWith(
        address posting,
        address bitmap,
        address third,
        Unit[] memory units,
        uint256 newUnitsFrom
    ) internal returns (ListIndexDeployer d, IHeadAuthorsGeneration ix) {
        ListIndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.stores = new ListIndexDeployer.Store[](3);
        plan.stores[0].families = IndexDeploy.postingFamilies();
        plan.stores[0].carried = posting;
        if (posting == address(0)) plan.stores[0].initcode = type(PostingStore).creationCode;
        plan.stores[1].families = IndexDeploy.bitmapFamilies();
        plan.stores[1].carried = bitmap;
        if (bitmap == address(0)) plan.stores[1].initcode = type(BitmapStore).creationCode;
        plan.stores[2].families = _headFamilies();
        plan.stores[2].carried = third;
        if (third == address(0)) plan.stores[2].initcode = type(PostingStore).creationCode;
        plan.readsInitcode = type(HeadAuthorsReads).creationCode;
        plan.generationInitcode = type(HeadAuthorsIndex).creationCode;
        plan.units = units;
        plan.specs = _specs();
        plan.work = _headWork();
        plan.topicTypeId = typeIds[T_TOPIC];
        plan.topicWordTypeId = typeIds[T_TOPIC_WORD];
        plan.newUnitsFrom = newUnitsFrom;
        plan.liveManifest = ManifestCopy.ofLive(address(r.ledger));
        d = new ListIndexDeployer(address(r.ledger), keccak256(abi.encode(plan)));
        ix = IHeadAuthorsGeneration(d.run(plan));
        assertEq(ix.THIRD(), d.store(2));
    }

    function _three(ListIndexDeployer d)
        internal
        view
        returns (IPostingStore, IBitmapStore, IPostingStore)
    {
        return (IPostingStore(d.store(0)), IBitmapStore(d.store(1)), IPostingStore(d.store(2)));
    }

    function _counts() internal view returns (uint64 admissions, uint64 publications) {
        (admissions,,, publications) = r.hot.counts();
    }

    function _buildAll(IGeneration1 ix) internal returns (uint256 calls) {
        (uint64 admissions,) = _counts();
        while (true) {
            uint64 through = ix.build(bytes32(0), uint16(BUILD_BUDGET));
            ++calls;
            if (through == admissions) return calls;
        }
    }

    function _assertCoverage(
        IGeneration1 ix,
        bytes32 family,
        Coverage want,
        uint64 through,
        string memory what
    ) internal view {
        (Coverage c, uint64 from, uint64 t,) = ix.coverage(FamilyId.wrap(family), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(want), string.concat(what, ": coverage"));
        assertEq(from, want == Coverage.UNKNOWN ? 0 : 1, string.concat(what, ": from"));
        assertEq(t, through, string.concat(what, ": through"));
    }

    // ---- Realm L ------------------------------------------------------------------------------------------------

    /// Switches `r` to a new Realm L whose genesis index is the example generation (three stores, INITIAL_WRITER 0),
    /// with the same genesis traffic as `setUp` (the root seed, 16 CREATEs). The recorded keys and this contract's
    /// CREATE subjects are recomputed for L: the history records its keys again, so a capture of L lines up with a
    /// capture of the setUp Realm list by list.
    function _realmL() internal {
        headAtGenesis = true;
        r = _realm(keccak256("head-authors/realm-l"));
        headAtGenesis = false;
        _register(r);
        p = r.principal;
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(T_DIRECTORY, _dirBody(p, keccak256("root")));
        rootDir = _id(T_DIRECTORY, b[0]);
        _execAs(address(this), a, b);
        delete things;
        Action[] memory c = new Action[](16);
        for (uint256 i; i < 16; ++i) {
            c[i] = _create(keccak256(abi.encode("lists/thing", i)));
            things.push(Keys.subject(p, c[i].saltOrStrength));
        }
        _execAs(address(this), c, new bytes[](16));
        delete postingKeys;
        delete scopeKeys;
        delete topicIds;
        delete headKeys;
        delete headFiles;
        assertEq(IHeadAuthorsGeneration(address(r.g.index)).THIRD(), genesisThird);
    }

    // ---- the HEAD history ---------------------------------------------------------------------------------------

    /// The example list's key for `file` (kind 24, in the third store).
    function _headKey(bytes32 file) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, 24, 0, Keys.position(Purpose.HEAD, file, 0)));
    }

    /// Generation 1's `head-authors` key for `file` (kind 22, in the genesis posting store).
    function _genesisKey(bytes32 file) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.headAuthorsList(Keys.position(Purpose.HEAD, file, 0)));
    }

    /// The keys a bind-kind statement can touch (as `_say` records them) and, at HEAD, both lists of its file's
    /// authors (generation 1's in the posting store, the example's in the third store).
    function _recordKeys(address who, Action memory x) internal {
        bytes32 pid = _pid(who);
        bytes32 position = Keys.position(x.purpose, x.subject, x.role);
        postingKeys.push(PostingKey.wrap(Keys.historyList(Keys.binding(pid, position))));
        postingKeys.push(
            PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(pid, x.purpose, x.role)))
        );
        postingKeys.push(PostingKey.wrap(Keys.placeList(x.purpose, x.subject)));
        postingKeys.push(PostingKey.wrap(Keys.positionAuthorsList(position)));
        postingKeys.push(PostingKey.wrap(Keys.rolePlacesList(x.purpose, x.role)));
        if (x.target != 0) {
            postingKeys.push(PostingKey.wrap(Keys.backlinkList(x.purpose, x.target)));
        }
        scopeKeys.push(Keys.scope(pid, x.purpose, x.subject));
        if (x.purpose == Purpose.HEAD) {
            headKeys.push(_headKey(x.subject));
            headFiles.push(x.subject);
            postingKeys.push(_genesisKey(x.subject));
        }
    }

    /// Executes one publication as `who` and records the keys of each of its actions (by-record for each record).
    function _run(address who, Action[] memory a, bytes[] memory b) internal {
        _execAs(who, a, b);
        for (uint256 i; i < a.length; ++i) {
            uint8 k = a[i].kind;
            if (k == ActionKind.BIND || k == ActionKind.UNBIND || k == ActionKind.RELEASE) {
                _recordKeys(who, a[i]);
            } else if (k == ActionKind.PUBLISH) {
                bytes32 rid = Keys.recordFromHash(a[i].typeId, a[i].bodyHashOrRecordId);
                postingKeys.push(PostingKey.wrap(Keys.posting(0, 12, 0, rid)));
            }
        }
    }

    function _head1(address who, Action memory x) internal {
        _run(who, _one(x), new bytes[](1));
    }

    function _hrev(address who, bytes32 file) internal view returns (uint64) {
        return _rev(who, Purpose.HEAD, file, 0);
    }

    /// A file created by `who` (a FIRST_BIND at HEAD) in `folder`.
    function _newFile(address who, bytes32 folder, string memory name)
        internal
        returns (bytes32 file, bytes32 root)
    {
        Action[] memory a;
        bytes[] memory b;
        (a, b, file, root) = EfsFiles.createFile(
            ft, _pid(who), folder, keccak256(bytes(name)), bytes(name), bytes(name), true
        );
        _run(who, a, b);
    }

    /// An edit by `who` of `file` (a REBIND at HEAD when `who` is BOUND there).
    function _editFile(address who, bytes32 file, bytes32 parent, string memory text)
        internal
        returns (bytes32 child)
    {
        Action[] memory a;
        bytes[] memory b;
        (a, b, child) = EfsFiles.edit(ft, file, parent, bytes(text), _hrev(who, file));
        _run(who, a, b);
    }

    /// The HEAD history (§8 test 1): a first bind, a re-bind, a second author's first bind on the same file, a first
    /// mask at HEAD by a third author, a mask of a bound head, a release of a bound head, a restore, a mask of an
    /// already masked head, a release of a masked head and a restore over a first mask; then a second file.
    function _headHistory() internal {
        (f1, f1Root) = _newFile(address(this), rootDir, "head-1.txt"); // FIRST_BIND (this)
        f1Child = _editFile(address(this), f1, f1Root, "head-1 v2"); // REBIND
        // bob's own version: PUBLISH child + his FIRST_BIND at the same position
        f1Bob = _editFile(bob, f1, f1Child, "bob's head-1");
        _head1(carol, EfsFiles.loneNegative(Purpose.HEAD, f1, 0, 0)); // FIRST_MASK (third author)
        _head1(bob, EfsFiles.unbind(Purpose.HEAD, f1, 0, _hrev(bob, f1))); // MASK of a BOUND head
        _head1(address(this), EfsFiles.release(Purpose.HEAD, f1, 0, _hrev(address(this), f1))); // RELEASE of BOUND
        _head1(address(this), EfsFiles.bind(Purpose.HEAD, f1, 0, f1Child, _hrev(address(this), f1))); // RESTORE
        _head1(carol, EfsFiles.unbind(Purpose.HEAD, f1, 0, _hrev(carol, f1))); // MASK of a MASKED head
        _head1(bob, EfsFiles.release(Purpose.HEAD, f1, 0, _hrev(bob, f1))); // RELEASE of a MASKED head
        _head1(carol, EfsFiles.bind(Purpose.HEAD, f1, 0, f1Root, _hrev(carol, f1))); // RESTORE over a first mask
        bytes32 home = bytes32(uint256(uint160(alice)));
        (f2, f2Root) = _newFile(alice, home, "head-2.txt");
        _head1(bob, EfsFiles.bind(Purpose.HEAD, f2, 0, f2Root, 0)); // a second author on f2
    }

    /// More HEAD traffic after a switch: every transition again, on both files.
    function _headTraffic() internal {
        _head1(bob, EfsFiles.bind(Purpose.HEAD, f1, 0, f1Bob, _hrev(bob, f1))); // RESTORE from RELEASED
        _head1(carol, EfsFiles.release(Purpose.HEAD, f1, 0, _hrev(carol, f1))); // RELEASE of BOUND
        _head1(alice, EfsFiles.loneNegative(Purpose.HEAD, f1, 0, 0)); // a fourth author's FIRST_MASK
        _editFile(alice, f2, f2Root, "head-2 v2"); // REBIND
        _head1(bob, EfsFiles.unbind(Purpose.HEAD, f2, 0, _hrev(bob, f2))); // MASK of BOUND
        _newFile(carol, bytes32(uint256(uint160(carol))), "head-3.txt"); // a new list
    }

    /// The by-author, by-type and unique-by-type lists (families 4, 1, 13) of every author and Type.
    function _genesisKeys() internal {
        for (uint256 i; i < authors.length; ++i) {
            postingKeys.push(PostingKey.wrap(Keys.posting(0, 4, 0, _pid(authors[i]))));
        }
        for (uint256 i; i < TYPE_COUNT; ++i) {
            postingKeys.push(PostingKey.wrap(Keys.posting(typeIds[i], 1, 0, 0)));
            postingKeys.push(PostingKey.wrap(Keys.posting(typeIds[i], 13, 0, 0)));
        }
    }

    /// The traffic of `BuildWalk.t.sol` after a switch (both genesis stores, every bind transition), then HEAD.
    function _traffic() internal {
        bytes32 deep = topicIds[5];
        bytes32 home = bytes32(uint256(uint160(alice)));
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("after.txt");
        _execAs(address(this), x, y);
        _tagAs(carol, deep, things[11], 0);
        _denyAs(alice, deep, things[0]);
        _tagAs(bob, deep, things[0], 7);
        _releaseAs(carol, Purpose.TAG, deep, things[0]);
        _say(
            carol,
            _bind(Purpose.FOLDER, home, ROLE, things[5], _rev(carol, Purpose.FOLDER, home, ROLE))
        );
        _say(alice, _bind(Purpose.FOLDER, home, keccak256("after.txt"), things[12], 0));
        _headTraffic();
    }

    bytes32 internal constant ROLE = keccak256("shared.txt");

    // ---- comparison ---------------------------------------------------------------------------------------------

    /// `_capture` of the two genesis-shaped stores, then one hash per recorded head-authors list in `third`.
    function _capture3(IPostingStore ps, IBitmapStore bs, IPostingStore third)
        internal
        view
        returns (bytes32[] memory h)
    {
        (bytes32[] memory g,,) = _capture(ps, bs);
        h = new bytes32[](g.length + headKeys.length);
        for (uint256 i; i < g.length; ++i) {
            h[i] = g[i];
        }
        for (uint256 i; i < headKeys.length; ++i) {
            h[g.length + i] = _list(third, headKeys[i]);
        }
    }

    function _list(IPostingStore s, PostingKey key) internal view returns (bytes32) {
        (uint64 c, uint64 l, uint64 last, uint16 f) = s.postingHead(key);
        bytes memory e;
        if (c != 0) e = abi.encode(s.postingSlice(key, 0, uint16(c)));
        return keccak256(abi.encode(c, l, last, f, e));
    }

    function _assertSame3(bytes32[] memory x, bytes32[] memory y, string memory what)
        internal
        pure
    {
        assertEq(x.length, y.length, string.concat(what, ": lists"));
        for (uint256 i; i < x.length; ++i) {
            if (x[i] != y[i]) revert(string.concat(what, ": list ", vm.toString(i)));
        }
    }

    function _headOf(IPostingStore third, bytes32 file)
        internal
        view
        returns (uint64 count, uint64 live, uint64 last)
    {
        (count, live, last,) = third.postingHead(_headKey(file));
    }

    function _entriesOf(IPostingStore s, PostingKey key) internal view returns (uint64[] memory) {
        (uint64 c,,,) = s.postingHead(key);
        return c == 0 ? new uint64[](0) : s.postingSlice(key, 0, uint16(c));
    }

    /// Every counter of the example list moved (docs INDEX-BUILD §2.2): f1 has three authors (two counted appends, one
    /// uncounted), two of them BOUND after two releases and two restores; f2 has two. And every example list in
    /// `third` equals generation 1's `head-authors` list of the same file in the live posting store, entry by entry
    /// with every counter: the list built from history (or kept by the example) is the list generation 1 keeps.
    function _assertHeadCountersMoved(IPostingStore third) internal view {
        _assertSameAsGenesisList(third);
        (uint64 c, uint64 l, uint64 last) = _headOf(third, f1);
        assertEq(abi.encode(c, l), abi.encode(uint64(3), uint64(2)), "f1: three authors, two BOUND");
        uint64[] memory e = _entriesOf(third, _headKey(f1));
        assertEq(e[0], _admission0(address(this)), "f1: the creator's first statement");
        assertEq(last, e[2], "f1: last is the third author's");
        (c, l,) = _headOf(third, f2);
        assertEq(abi.encode(c, l), abi.encode(uint64(2), uint64(2)), "f2: two authors, both BOUND");
    }

    /// Each recorded example list in `third` against generation 1's `head-authors` list of its file.
    function _assertSameAsGenesisList(IPostingStore third) internal view {
        IPostingStore genesis = IPostingStore(address(r.g.posting));
        for (uint256 i; i < headFiles.length; ++i) {
            assertEq(
                _list(third, headKeys[i]),
                _list(genesis, _genesisKey(headFiles[i])),
                "the example list equals generation 1's head-authors"
            );
        }
    }

    /// The admission of `who`'s first HEAD statement on f1: its history list's entry 0.
    function _admission0(address who) internal view returns (uint64) {
        return IPostingStore(address(r.g.posting))
            .postingAt(
                PostingKey.wrap(
                    Keys.historyList(Keys.binding(_pid(who), Keys.position(Purpose.HEAD, f1, 0)))
                ),
                0
            );
    }
}
