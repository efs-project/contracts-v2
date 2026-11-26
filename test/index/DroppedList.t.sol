// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsHistory} from "../integration/TopicListsHistory.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {CreatorsIndex, CreatorsReads} from "../harness/HeadAuthors.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    FamilyId,
    PostingKey,
    Purpose,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {E_BUILD, E_INDEX_NOT_READY} from "../../src/interfaces/Errors.sol";

interface ICarriedCheck {
    function carriedCheck() external view returns (bool);
}

interface IProgressFlag {
    function generationProgress()
        external
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped, bool liveStarted);
}

/// @notice Docs INDEX-BUILD §5.3, the dropped-list claim (a pre-freeze gate): dropping a list from a store a generation
///         carries is safe; the replaced generation's late walk can write only the dropped list; the dropped list can
///         never be declared in that store again; the kept lists are untouched.
///
///         G (example code, `CreatorsIndex`) keeps generation 1's posting lists PLUS X (`subjects-created`, folded on
///         CREATE only) in a fresh posting store T, carries the genesis bitmap store, builds and is activated. Before
///         any admission reaches G, G' (generation 1's code) carries T and the bitmap store and is activated: it
///         declares generation 1's lists in T and not X. A CREATE-only publication then leaves T unattached, so G's
///         late build is still allowed and folds the CREATE into X, and only X; a bind attaches T and G is refused
///         (`E_BUILD(2)`, kernel 13); H (G's code again, carrying T) cannot declare X in T again (`E_BUILD(7)`, kernel
///         12); every list G' keeps equals a twin Realm that ran generation 1 throughout.
contract DroppedListTest is TopicListsHistory {
    bytes32 internal F_X = Keys.familyId("subjects-created");

    function _withX() internal pure returns (bytes32[] memory f) {
        bytes32[] memory g = IndexDeploy.postingFamilies();
        f = new bytes32[](g.length + 1);
        for (uint256 i; i < g.length; ++i) {
            f[i] = g[i];
        }
        f[g.length] = Keys.familyId("subjects-created");
    }

    function _xKey(bytes32 creator) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, 23, 0, creator));
    }

    /// A generation of G's code (`CreatorsIndex` over `CreatorsReads`) over `posting` (fresh with generation 1's lists
    /// plus X when zero) and the carried `bitmap`.
    function _creators(address posting, address bitmap)
        internal
        returns (IndexDeployer d, IGeneration1 ix)
    {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        if (posting == address(0)) plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = _withX();
        plan.posting = posting;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.bitmap = bitmap;
        plan.readsInitcode = type(CreatorsReads).creationCode;
        plan.generationInitcode = type(CreatorsIndex).creationCode;
        plan.units = _units();
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.topicTypeId = typeIds[T_TOPIC];
        plan.topicWordTypeId = typeIds[T_TOPIC_WORD];
        d = new IndexDeployer(address(r.ledger), keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    function _buildAll(IGeneration1 ix) internal {
        (uint64 admissions,,,) = r.hot.counts();
        while (ix.build(bytes32(0), 64) != admissions) {}
    }

    function _createOnly(string memory seed) internal {
        Action[] memory a = new Action[](1);
        a[0] = _create(keccak256(bytes(seed)));
        _execAs(address(this), a, new bytes[](1));
    }

    /// The first bind after the CREATE: a tag (it writes T's history, role-scope, place and position-authors lists).
    function _bindOne() internal {
        _tagAs(bob, topicIds[2], things[14], 0);
    }

    /// More traffic: a PUBLISH, a first tag on the deepest topic, a mask, a same-target re-bind, a release, a FOLDER
    /// restore and a FOLDER first bind, and another CREATE (G' writes nothing for it; T is attached by now).
    function _more() internal {
        bytes32 deep = topicIds[5];
        bytes32 home = bytes32(uint256(uint160(alice)));
        bytes32 role = keccak256("shared.txt");
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("dropped.txt");
        _execAs(address(this), x, y);
        _tagAs(carol, deep, things[11], 0);
        _denyAs(alice, deep, things[0]);
        _tagAs(bob, deep, things[0], 7);
        _releaseAs(carol, Purpose.TAG, deep, things[0]);
        _say(
            carol,
            _bind(Purpose.FOLDER, home, role, things[5], _rev(carol, Purpose.FOLDER, home, role))
        );
        _say(alice, _bind(Purpose.FOLDER, home, keccak256("dropped.txt"), things[12], 0));
        _createOnly("dropped/create-2");
    }

    function _writersHash(IPostingStore s) internal view returns (bytes32) {
        (address[] memory g, uint64[] memory f, uint64[] memory t) = s.writers();
        return keccak256(abi.encode(g, f, t, s.attached()));
    }

    function test_a_dropped_list_is_safe_and_cannot_return() public {
        _mixedHistory();
        IBitmapStore b0 = IBitmapStore(address(r.g.bitmap));
        IPostingStore p0 = IPostingStore(address(r.g.posting));
        // the twin: the same Realm, generation 1 live throughout, the same publications
        uint256 snap = vm.snapshotState();
        _createOnly("dropped/create");
        (bytes32[] memory twinAfterCreate,,) = _capture(p0, b0);
        _bindOne();
        _more();
        (bytes32[] memory twinEnd,,) = _capture(p0, b0);
        vm.revertToState(snap);

        // G: T fresh (generation 1's lists + X), the genesis bitmap store carried; built and activated
        (IndexDeployer dg, IGeneration1 g) = _creators(address(0), address(b0));
        IPostingStore t = IPostingStore(dg.postingStore());
        assertEq(t.familyIds().length, 16, "T: generation 1's fifteen posting lists and X");
        _buildAll(g);
        _assertSameStores(p0, b0, t, b0, "G's T vs the genesis posting store");
        (uint64 x0,,,) = t.postingHead(_xKey(p));
        assertEq(x0, 16, "X: the sixteen CREATEs of setUp");
        this.activateNow(address(g));
        assertEq(r.hot.index(), address(g));

        // G': generation 1's code, carrying T and the bitmap store, before any admission reaches G. It drops X.
        (, IGeneration1 g2) = _generation(address(t), address(b0));
        assertTrue(
            ICarriedCheck(address(g2)).carriedCheck(),
            "the live G declares each of G' s lists in T from 1"
        );
        (uint64 admissions,,,) = r.hot.counts();
        assertEq(g2.build(bytes32(0), 64), admissions, "a re-pin: the frontier moves to counts()");
        this.activateNow(address(g2));
        assertEq(r.hot.index(), address(g2));
        (Coverage cx,,,) = g2.coverage(FamilyId.wrap(F_X), ScopeKey.wrap(0));
        assertEq(uint8(cx), uint8(Coverage.UNKNOWN), "G' does not declare X");

        // a CREATE-only publication: G' writes nothing to T, which stays unattached
        (bytes32[] memory before,,) = _capture(t, b0);
        bytes32 writersBefore = _writersHash(t);
        _createOnly("dropped/create");
        (uint64 createAdmission,,,) = r.hot.counts();
        assertEq(_writersHash(t), writersBefore, "G' wrote nothing to T");
        assertFalse(t.attached(), "T is still unattached");
        (bytes32[] memory afterCreate,,) = _capture(t, b0);
        _assertSameCapture(before, afterCreate, "the CREATE touched no list of generation 1");
        _assertSameCapture(twinAfterCreate, afterCreate, "T vs the twin after the CREATE");

        // G's late build is still allowed (G never folded live) and folds that CREATE: X's entry is the only change
        (,,, bool liveStarted) = IProgressFlag(address(g)).generationProgress();
        assertFalse(liveStarted, "G never folded live");
        assertEq(g.build(bytes32(0), 64), createAdmission, "G's late walk folds the CREATE");
        (uint64 x1,, uint64 xLast,) = t.postingHead(_xKey(p));
        assertEq(x1, x0 + 1, "X: one more entry");
        assertEq(xLast, createAdmission, "X: the CREATE's admission");
        (bytes32[] memory afterWalk,,) = _capture(t, b0);
        _assertSameCapture(afterCreate, afterWalk, "G's late walk wrote no list of generation 1");
        _assertSameCapture(twinAfterCreate, afterWalk, "T vs the twin after G's late walk");
        assertEq(_writersHash(t), writersBefore, "a build write never attaches");

        // a bind: G' folds it live and attaches T; G is refused by its build (2) and by the kernel (13)
        _bindOne();
        assertTrue(t.attached(), "G' s live write attached T");
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(2)));
        g.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(13)));
        this.activateNow(address(g));

        // H: G's code again, declaring X in T: refused (7 / 12), because the live G' does not declare X in T
        (, IGeneration1 h) = _creators(address(t), address(b0));
        assertFalse(
            ICarriedCheck(address(h)).carriedCheck(), "the live index does not declare X in T"
        );
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        h.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(12)));
        this.activateNow(address(h));

        // more traffic: every list G' keeps equals the twin's, key by key
        _more();
        (bytes32[] memory end,,) = _capture(t, b0);
        _assertSameCapture(twinEnd, end, "G' s lists vs the twin that ran generation 1 throughout");
        // X is dead weight: G' answers UNKNOWN for it, the store still holds G's entries
        (Coverage c, uint64 count,,,) = g2.postingHeadOf(FamilyId.wrap(F_X), TypeId.wrap(0), 0, p);
        assertEq(uint8(c), uint8(Coverage.UNKNOWN), "unreadable through the live index");
        assertEq(count, 0);
        (uint64 x2,,,) = t.postingHead(_xKey(p));
        assertEq(x2, x1, "readable only from the store, and frozen: nobody folds X any more");
    }
}
