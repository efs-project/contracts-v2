// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Batch, ArmedHook, Squatter} from "./Carried.t.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    PostingKey,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Effect, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {E_BUILD, E_INDEX_NOT_READY, E_REPLAY, E_WRITER} from "../../src/interfaces/Errors.sol";

interface ICarriedCheck {
    function carriedCheck() external view returns (bool);
}

/// A fold hook that counts its calls and, once armed, calls `build(0, 64)` on a target from inside the fold.
contract CountingHook is IIndexHook {
    uint256 public calls;
    address public target;
    bytes public lastError;

    function arm(address t) external {
        target = t;
    }

    function fold(Effect calldata, bytes32[] calldata, uint64) external returns (bytes4) {
        ++calls;
        if (target != address(0)) {
            try RealmIndex(target).build(bytes32(0), 64) {}
            catch (bytes memory err) {
                lastError = err;
            }
        }
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

/// @notice Docs INDEX-BUILD step 2 on a minimal Realm (the `Carried.t.sol` history: every action kind, a WITHDRAW of a
///         REUSE among them): the refusals of the walk (§3.2, §8 test 7), fold hooks during a build (§3.6), coverage
///         and readiness when the carried check fails (§3.5), a store attached by a live write before the build
///         (`E_BUILD(2)`, kernel reason 13), and the stores refusing every build write that is not their
///         INITIAL_WRITER's into a fresh store. Two Realms take the same history: `b` never switches and is the twin.
contract BuildWalkRefusalsTest is Test {
    struct Realm {
        KernelDeploy.Kernel k;
        MockRegistry registry;
        IndexDeploy.Gen1 g;
        Batch batch;
        uint64 nonce;
        uint32 revision;
    }

    bytes32 internal constant TYPE_OK = keccak256("test/type/ok");
    bytes32 internal constant FOLDER = keccak256("efs/purpose/folder/1");
    bytes32 internal constant NAME = keccak256("name");
    bytes32 internal constant SECOND = keccak256("second");
    bytes internal constant BODY = "0123456789abcdef0123456789abcdef-tail";
    bytes internal constant OTHER = "another body of thirty-two-plus bytes!";
    bytes internal constant THIRD = "third body, long enough to pass the words";
    bytes32 internal constant SALT = keccak256("file-1");

    Realm internal a;
    Realm internal b;
    ArmedHook internal liveHook;

    function setUp() public {
        liveHook = new ArmedHook();
        _realm(a, keccak256("salt-a"));
        _realm(b, keccak256("salt-b"));
    }

    // ---- setup and actions (as `Carried.t.sol`) -----------------------------------------------------------------

    function _hookUnit(address hook) internal view returns (Unit[] memory units) {
        units = new Unit[](1);
        units[0] = Unit({
            foldHook: hook,
            foldCodehash: hook.codehash,
            finalHook: address(0),
            finalCodehash: 0,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/build-walk-hook/1")
        });
    }

    function _realm(Realm storage R, bytes32 salt) internal {
        R.registry = new MockRegistry();
        R.batch = new Batch();
        R.k = KernelDeploy.deploy(address(R.batch), address(R.registry), salt);
        R.registry.setLedger(R.k.proxy);
        R.registry.setImplementation(address(R.registry));
        R.g = IndexDeploy.deploy(
            R.k.proxy, KernelDeploy.HOT_ABI_ID, _hookUnit(address(liveHook)), _specs()
        );
        _activate(R, address(R.g.index));
        AcceptAll acceptAll = new AcceptAll();
        TypeInfo memory info;
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = address(acceptAll);
        info.ruleId = address(acceptAll).codehash;
        info.policyRows = 1;
        info.policyRow = 1;
        R.registry.setType(TYPE_OK, info, new bytes32[](0));
    }

    function _specs() internal pure returns (DigestSpec[] memory specs) {
        specs = new DigestSpec[](1);
        specs[0] = DigestSpec({typeId: TYPE_OK, wordIndex: 0, algorithm: 1});
    }

    function _hot(Realm storage R) internal view returns (ILedgerHot) {
        return ILedgerHot(R.k.proxy);
    }

    function _principal(Realm storage R) internal view returns (bytes32) {
        return Keys.principalFor(address(this), _hot(R).realmOrigin());
    }

    function _subject(Realm storage R) internal view returns (bytes32) {
        return Keys.subject(_principal(R), SALT);
    }

    function _exec(Realm storage R, Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 p)
    {
        Native memory ctx;
        ctx.nonce = R.nonce++;
        (p,) = ILedger(R.k.proxy).execute(actions, bodies, ctx, "");
    }

    function _one(Realm storage R, Action memory x, bytes memory body) internal returns (uint64) {
        Action[] memory actions = new Action[](1);
        actions[0] = x;
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        return _exec(R, actions, bodies);
    }

    function _bind(Realm storage R, uint8 kind, bytes32 role, bytes32 target, uint64 expected)
        internal
        view
        returns (Action memory x)
    {
        x.kind = kind;
        x.purpose = FOLDER;
        x.subject = _subject(R);
        x.role = role;
        x.target = target;
        x.expectedRevision = expected;
    }

    function _publish(bytes memory body) internal pure returns (Action memory x) {
        x.kind = ActionKind.PUBLISH;
        x.typeId = TYPE_OK;
        x.bodyHashOrRecordId = keccak256(body);
    }

    function _rid(bytes memory body) internal pure returns (bytes32) {
        return Keys.recordFromHash(TYPE_OK, keccak256(body));
    }

    /// 11 admissions in 8 publications: CREATE, PUBLISH, first BIND; REUSE; mask; restore; PUBLISH + re-bind; a second
    /// first BIND; WITHDRAW of the REUSE; RELEASE.
    function _history(Realm storage R) internal {
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = SALT;
        actions[1] = _publish(BODY);
        actions[2] = _bind(R, ActionKind.BIND, NAME, _rid(BODY), 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = BODY;
        assertEq(_exec(R, actions, bodies), 1);
        Action memory reuse;
        reuse.kind = ActionKind.REUSE;
        reuse.typeId = TYPE_OK;
        reuse.bodyHashOrRecordId = _rid(BODY);
        assertEq(_one(R, reuse, ""), 2);
        assertEq(_one(R, _bind(R, ActionKind.UNBIND, NAME, 0, 1), ""), 3);
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(BODY), 2), ""), 4);
        Action[] memory two = new Action[](2);
        two[0] = _publish(OTHER);
        two[1] = _bind(R, ActionKind.BIND, NAME, _rid(OTHER), 3);
        bytes[] memory tb = new bytes[](2);
        tb[0] = OTHER;
        assertEq(_exec(R, two, tb), 5);
        assertEq(_one(R, _bind(R, ActionKind.BIND, SECOND, _rid(BODY), 0), ""), 6);
        Action memory withdraw;
        withdraw.kind = ActionKind.WITHDRAW;
        withdraw.target = bytes32(uint256(4));
        assertEq(_one(R, withdraw, ""), 7);
        assertEq(_one(R, _bind(R, ActionKind.RELEASE, SECOND, 0, 1), ""), 8);
    }

    /// A new record (12), a re-bind of NAME to it (13), a mask of NAME (14), a restore (15), a WITHDRAW of 12 (16).
    function _traffic(Realm storage R) internal {
        assertEq(_one(R, _publish(THIRD), THIRD), 9);
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(THIRD), 4), ""), 10);
        assertEq(_one(R, _bind(R, ActionKind.UNBIND, NAME, 0, 5), ""), 11);
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(THIRD), 6), ""), 12);
        Action memory withdraw;
        withdraw.kind = ActionKind.WITHDRAW;
        withdraw.target = bytes32(uint256(12));
        assertEq(_one(R, withdraw, ""), 13);
    }

    /// A generation of generation 1's code over `posting` and `bitmap` (carried when nonzero, fresh when zero).
    function _gen(
        Realm storage R,
        address posting,
        address bitmap,
        Unit[] memory units,
        bool decoder
    ) internal returns (IndexDeployer d, IGeneration1 ix) {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        if (decoder) plan.decoder = address(new IndexReplayDecoder());
        if (posting == address(0)) plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.posting = posting;
        if (bitmap == address(0)) plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.bitmap = bitmap;
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = units;
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.liveManifest = ManifestCopy.ofLive(R.k.proxy);
        d = new IndexDeployer(R.k.proxy, keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    function _gen(Realm storage R, address posting, address bitmap)
        internal
        returns (IndexDeployer d, IGeneration1 ix)
    {
        return _gen(R, posting, bitmap, new Unit[](0), true);
    }

    function _set(Realm storage R, address ix) internal returns (ActivationSet memory set) {
        uint32 rev = R.revision + 1;
        R.registry.setActiveRevision(rev);
        set = KernelDeploy.genesisSet(
            R.k, address(R.batch), address(R.registry), ix, IGeneration1(ix).manifestHash()
        );
        set.revision = rev;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, R.k.proxy);
    }

    function _activate(Realm storage R, address ix) internal {
        ActivationSet memory set = _set(R, ix);
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = Batch.Call(R.k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        R.batch.exec(calls);
        R.revision = set.revision;
        assertEq(_hot(R).index(), ix);
    }

    function _expectActivateRevert(Realm storage R, address ix, uint8 reason) internal {
        ActivationSet memory set = _set(R, ix);
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = Batch.Call(R.k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, reason));
        R.batch.exec(calls);
        R.registry.setActiveRevision(R.revision);
    }

    function _coverage(IGeneration1 ix, string memory family)
        internal
        view
        returns (Coverage c, uint64 from, uint64 through)
    {
        (c, from, through,) = ix.coverage(FamilyId.wrap(Keys.familyId(family)), ScopeKey.wrap(0));
    }

    // ---- comparison ----------------------------------------------------------------------------------------------

    function _keys(Realm storage R) internal view returns (PostingKey[] memory keys) {
        bytes32 p = _principal(R);
        bytes32 bindingKey = Keys.binding(p, Keys.position(FOLDER, _subject(R), NAME));
        keys = new PostingKey[](13);
        keys[0] = PostingKey.wrap(Keys.byTypeList(TYPE_OK));
        keys[1] = PostingKey.wrap(Keys.byAuthorList(p));
        keys[2] = PostingKey.wrap(Keys.uniqueByTypeList(TYPE_OK));
        keys[3] = PostingKey.wrap(Keys.byRecordList(_rid(BODY)));
        keys[4] = PostingKey.wrap(Keys.historyList(bindingKey));
        keys[5] = PostingKey.wrap(Keys.backlinkList(FOLDER, _rid(BODY)));
        keys[6] = PostingKey.wrap(Keys.backlinkList(FOLDER, _rid(OTHER)));
        keys[7] = PostingKey.wrap(Keys.backlinkList(FOLDER, _rid(THIRD)));
        keys[8] = PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(p, FOLDER, NAME)));
        keys[9] = PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(p, FOLDER, SECOND)));
        bytes memory body = BODY;
        bytes32 w0;
        assembly ("memory-safe") {
            w0 := mload(add(body, 32))
        }
        keys[10] = PostingKey.wrap(Keys.digestList(bytes32(uint256(1)), w0));
        keys[11] = PostingKey.wrap(Keys.byRecordList(_rid(THIRD)));
        keys[12] = PostingKey.wrap(
            Keys.historyList(Keys.binding(p, Keys.position(FOLDER, _subject(R), SECOND)))
        );
    }

    /// Every compared posting list and the file's FOLDER scope list are equal in the two store pairs (keys per Realm:
    /// the principal differs between Realms, the ordinals do not).
    function _assertSame(
        Realm storage RA,
        IPostingStore pa,
        IBitmapStore ba,
        Realm storage RB,
        IPostingStore pb,
        IBitmapStore bb
    ) internal view {
        PostingKey[] memory ka = _keys(RA);
        PostingKey[] memory kb = _keys(RB);
        for (uint256 i; i < ka.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = pa.postingHead(ka[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = pb.postingHead(kb[i]);
            assertEq(abi.encode(c1, l1, last1, f1), abi.encode(c2, l2, last2, f2), "head");
            assertEq(
                keccak256(abi.encode(pa.postingSlice(ka[i], 0, 64))),
                keccak256(abi.encode(pb.postingSlice(kb[i], 0, 64))),
                "entries"
            );
        }
        ScopeKey sa = ScopeKey.wrap(Keys.scope(_principal(RA), FOLDER, _subject(RA)));
        ScopeKey sb = ScopeKey.wrap(Keys.scope(_principal(RB), FOLDER, _subject(RB)));
        (uint64 sc1, uint64 sl1, uint64 lm1, uint48 bits1, uint16 sf1, uint64 e1) = ba.scopeHead(sa);
        (uint64 sc2, uint64 sl2, uint64 lm2, uint48 bits2, uint16 sf2, uint64 e2) = bb.scopeHead(sb);
        assertEq(
            abi.encode(sc1, sl1, lm1, bits1, sf1, e1),
            abi.encode(sc2, sl2, lm2, bits2, sf2, e2),
            "scope"
        );
        assertEq(
            keccak256(abi.encode(ba.scopeSlice(sa, 0, 64))),
            keccak256(abi.encode(bb.scopeSlice(sb, 0, 64))),
            "scope entries"
        );
    }

    // =============================================================================================
    // Heal one store on the history with a WITHDRAW, against a twin Realm that never switches
    // =============================================================================================

    function testHealEachStoreAgainstATwinRealm() public {
        _history(b);
        _traffic(b);
        for (uint256 cfg = 1; cfg <= 2; ++cfg) {
            uint256 snap = vm.snapshotState();
            _history(a);
            bool healBitmap = cfg == 1;
            (IndexDeployer d, IGeneration1 ix) = _gen(
                a,
                healBitmap ? address(a.g.posting) : address(0),
                healBitmap ? address(0) : address(a.g.bitmap)
            );
            IPostingStore hp = IPostingStore(d.postingStore());
            IBitmapStore hb = IBitmapStore(d.bitmapStore());
            assertEq(ix.build(bytes32(0), 64), 11);
            _assertSame(
                a, IPostingStore(address(a.g.posting)), IBitmapStore(address(a.g.bitmap)), a, hp, hb
            );
            _activate(a, address(ix));
            _traffic(a);
            _assertSame(
                a, hp, hb, b, IPostingStore(address(b.g.posting)), IBitmapStore(address(b.g.bitmap))
            );
            (uint64 processed,,) = ix.progress();
            assertEq(processed, 16);
            vm.revertToState(snap);
        }
    }

    // =============================================================================================
    // Refusals (docs INDEX-BUILD §8 test 7)
    // =============================================================================================

    function testBuildRefusals() public {
        _history(a);
        (, IGeneration1 mixed) = _gen(a, address(a.g.posting), address(0));
        // a nonzero familyId
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(8)));
        mixed.build(keccak256("efs/family/by-author/1"), 64);
        // from inside a publication: generation 1's fold hook calls it while the ledger is APPLYING
        liveHook.arm(address(mixed));
        assertEq(_one(a, _publish(THIRD), THIRD), 9);
        assertFalse(liveHook.built());
        assertEq(
            keccak256(liveHook.lastError()),
            keccak256(abi.encodeWithSelector(E_BUILD.selector, uint8(3)))
        );
        liveHook.arm(address(0));
        // a budget below the next publication's leaf count (publication 1 has 3 leaves): nothing changes
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
        mixed.build(bytes32(0), 2);
        (uint64 processed, uint64 publication,) = mixed.progress();
        assertEq(abi.encode(processed, publication), abi.encode(uint64(0), uint64(0)));
        // a fresh store and no decoder
        (, IGeneration1 blind) = _gen(a, address(a.g.posting), address(0), new Unit[](0), false);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(5)));
        blind.build(bytes32(0), 64);
        // replay stays all-fresh only
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(1)));
        mixed.replayNextPublication(64);
        // after activation
        assertEq(mixed.build(bytes32(0), 64), 12);
        _activate(a, address(mixed));
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(1)));
        mixed.build(bytes32(0), 64);
    }

    // =============================================================================================
    // Fold hooks during a build (docs INDEX-BUILD §3.6)
    // =============================================================================================

    function testFoldHooksRunInAnAllFreshBuildOnlyAndCannotReenterIt() public {
        _history(a);
        // both fresh: the build calls the generation's fold hooks as replay does, once per effect
        CountingHook hook = new CountingHook();
        (, IGeneration1 fresh) = _gen(a, address(0), address(0), _hookUnit(address(hook)), true);
        hook.arm(address(fresh));
        assertEq(fresh.build(bytes32(0), 64), 11);
        assertEq(hook.calls(), 11, "one fold-hook call per effect");
        assertEq(
            keccak256(hook.lastError()),
            keccak256(abi.encodeWithSelector(E_BUILD.selector, uint8(3))),
            "a fold hook re-entering the build in flight is refused"
        );
        // the same through replay, for comparison
        CountingHook replayHook = new CountingHook();
        (, IGeneration1 replayed) =
            _gen(a, address(0), address(0), _hookUnit(address(replayHook)), true);
        while (replayed.replayNextPublication(64) != 0) {}
        assertEq(replayHook.calls(), 11);
        // one store carried: a build that heals one store calls no fold hook of a unit its reads contract does not
        // name as built, so a unit the live index never ran would miss the history; Option A refuses it (docs
        // INDEX-BUILD §3.6: the carried check fails, `build` 7, readiness claims nothing). Before Option A this
        // build passed with the hook called for nothing.
        CountingHook mixedHook = new CountingHook();
        (, IGeneration1 mixed) =
            _gen(a, address(0), address(a.g.bitmap), _hookUnit(address(mixedHook)), true);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        mixed.build(bytes32(0), 64);
        assertEq(mixedHook.calls(), 0, "no fold hook in a build that heals one store");
        assertFalse(mixed.replayReadiness().ready);
    }

    // =============================================================================================
    // A build write never lands in a store that is not the builder's fresh store
    // =============================================================================================

    function testStoresRefuseEveryBuildWriteButTheirInitialWriters() public {
        _history(a);
        (IndexDeployer d, IGeneration1 mixed) = _gen(a, address(a.g.posting), address(0));
        FamilyId byType = FamilyId.wrap(Keys.familyId("by-type"));
        FamilyId scope = FamilyId.wrap(Keys.familyId("scope"));
        // the candidate itself cannot write the store it carries (INITIAL_WRITER 0, attached by generation 1)
        vm.prank(address(mixed));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(mixed)));
        a.g.posting.append(byType, PostingKey.wrap(keccak256("x")), 99, 0);
        vm.prank(address(mixed));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(mixed)));
        a.g.bitmap.appendScopeEntry(scope, ScopeKey.wrap(keccak256("x")), 99, 11);
        // another generation (a stranger) cannot write the candidate's fresh store
        (, IGeneration1 stranger) = _gen(a, address(0), address(0));
        IBitmapStore candidateBitmap = IBitmapStore(d.bitmapStore());
        vm.prank(address(stranger));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(stranger)));
        candidateBitmap.appendScopeEntry(scope, ScopeKey.wrap(keccak256("x")), 99, 11);
        // nor can the stranger's own build reach it: it names its own stores only
        assertEq(stranger.build(bytes32(0), 64), 11);
        (address[] memory gens,,) = IPostingStore(d.bitmapStore()).writers();
        assertEq(gens.length, 0, "the candidate's fresh store is unwritten");
        // the candidate's build writes its fresh store only
        (address[] memory g0, uint64[] memory f0, uint64[] memory t0) = a.g.posting.writers();
        assertEq(mixed.build(bytes32(0), 64), 11);
        (address[] memory g1, uint64[] memory f1, uint64[] memory t1) = a.g.posting.writers();
        assertEq(keccak256(abi.encode(g1, f1, t1)), keccak256(abi.encode(g0, f0, t0)));
        (gens,,) = IPostingStore(d.bitmapStore()).writers();
        assertEq(gens.length, 1);
        assertEq(gens[0], address(mixed));
    }

    // =============================================================================================
    // A fresh store attached by a live write (E_BUILD(2), kernel reason 13)
    // =============================================================================================

    /// The route that remains under the kernel's checks: C replays into its fresh stores and is activated; before any
    /// admission reaches C, D re-pins C's stores (they are the live index's: check 12 passes) and is activated; the
    /// next publication folds into them live through D and attaches them. C has never folded live, is not the live
    /// index, and names stores that call it their INITIAL_WRITER and are attached: neither fresh nor carried.
    /// Before that publication C may still call `build` (its stores are unattached and its own), and it folds nothing:
    /// nothing has been admitted past its frontier, and any admission that would give it something to fold attaches
    /// the store first (docs INDEX-BUILD §5.3, the lazily attached store).
    function testAFreshStoreAttachedByALiveWriteRefusesTheBuild() public {
        _history(a);
        (IndexDeployer dc, IGeneration1 c) = _gen(a, address(0), address(0));
        assertEq(c.build(bytes32(0), 64), 11);
        _activate(a, address(c));
        (, IGeneration1 d) = _gen(a, dc.postingStore(), dc.bitmapStore());
        assertEq(d.build(bytes32(0), 64), 11);
        _activate(a, address(d));
        IPostingStore stolen = IPostingStore(dc.postingStore());
        assertFalse(stolen.attached(), "no admission since: the stores are unattached");
        (address[] memory g0, uint64[] memory f0, uint64[] memory t0) = stolen.writers();
        assertEq(
            c.build(bytes32(0), 64), 11, "the replaced generation may build, and folds nothing"
        );
        (address[] memory g1, uint64[] memory f1, uint64[] memory t1) = stolen.writers();
        assertEq(keccak256(abi.encode(g1, f1, t1)), keccak256(abi.encode(g0, f0, t0)));
        assertEq(_one(a, _publish(THIRD), THIRD), 9); // D's first live write attaches C's posting store
        assertTrue(stolen.attached());
        assertEq(stolen.initialWriter(), address(c));
        // the generation: build 2, replay 1, the carried check fails, readiness claims nothing
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(2)));
        c.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(1)));
        c.replayNextPublication(64);
        assertFalse(ICarriedCheck(address(c)).carriedCheck());
        Readiness memory rd = c.replayReadiness();
        assertFalse(rd.ready);
        assertEq(rd.completedAdmission, 0);
        (Coverage cov, uint64 from, uint64 through) = _coverage(c, "by-type");
        assertEq(abi.encode(cov, from, through), abi.encode(Coverage.PARTIAL, uint64(1), uint64(0)));
        // the kernel
        _expectActivateRevert(a, address(c), 13);
    }

    // =============================================================================================
    // The empty-Realm rule: a store's INITIAL_WRITER is nobody or the candidate (kernel reason 12, build 7)
    // =============================================================================================

    /// The gap the rule closes: on a Realm with no admissions a candidate carried an unwritten store whose
    /// INITIAL_WRITER is a third contract; once activated, that contract could still write the store in build mode
    /// (it is unattached until the first live write), after every check had run. Now the candidate is refused, so the
    /// squatter's late write lands in a store no index names; it cannot write the genesis stores the live index uses.
    function testAnEmptyRealmRefusesAStoreAThirdContractCouldWrite() public {
        Squatter squatter = new Squatter();
        PostingStore squatted =
            new PostingStore(a.k.proxy, address(squatter), IndexDeploy.postingFamilies());
        (address[] memory gens,,) = squatted.writers();
        assertEq(gens.length, 0, "unwritten: the step-1 rule alone would pass it");
        (, IGeneration1 candidate) = _gen(a, address(squatted), address(a.g.bitmap));
        assertFalse(ICarriedCheck(address(candidate)).carriedCheck());
        assertFalse(candidate.replayReadiness().ready);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        candidate.build(bytes32(0), 64);
        _expectActivateRevert(a, address(candidate), 12);
        // the attack has nothing to ride on: the squatter writes its own store, which no index names, and is refused
        // by the stores the live index does use
        squatter.squat(squatted);
        assertEq(_hot(a).index(), address(a.g.index));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(squatter)));
        squatter.squat(a.g.posting);
        _history(a);
        (uint64 c,,,) = squatted.postingHead(PostingKey.wrap(keccak256("efs/test/squat")));
        assertEq(c, 1, "the junk sits where nothing reads it");
    }

    /// The rule keeps both honest shapes on an empty Realm: a re-pin of the genesis stores (INITIAL_WRITER 0) and a
    /// generation with its own fresh stores (INITIAL_WRITER = the candidate).
    function testAnEmptyRealmStillActivatesARePinAndAFreshGeneration() public {
        (, IGeneration1 repin) = _gen(a, address(a.g.posting), address(a.g.bitmap));
        assertTrue(ICarriedCheck(address(repin)).carriedCheck());
        assertEq(repin.build(bytes32(0), 64), 0);
        _activate(a, address(repin));
        (, IGeneration1 fresh) = _gen(b, address(0), address(0));
        assertTrue(ICarriedCheck(address(fresh)).carriedCheck());
        assertTrue(fresh.replayReadiness().ready);
        _activate(b, address(fresh));
        _history(a);
        _history(b);
        _assertSame(
            a,
            IPostingStore(address(a.g.posting)),
            IBitmapStore(address(a.g.bitmap)),
            b,
            IPostingStore(fresh.postingStore()),
            IBitmapStore(fresh.bitmapStore())
        );
    }

    // =============================================================================================
    // Only the generation itself can call replayFold (the trailing carried-mask word is its own)
    // =============================================================================================

    function testOnlyTheGenerationCallsReplayFold() public {
        _history(a);
        (, IGeneration1 mixed) = _gen(a, address(a.g.posting), address(0));
        IndexReplayDecoder dec = IndexReplayDecoder(mixed.decoder());
        (Effect[] memory effects, bytes32[] memory refs) = dec.decode(a.k.proxy, 1);
        // a stranger, with or without a mask word of its choosing, is refused before anything is read or written
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        mixed.replayFold(1, effects, refs);
        (bool ok, bytes memory err) = address(mixed)
            .call(
                bytes.concat(abi.encodeCall(RealmIndex.replayFold, (1, effects, refs)), bytes32(0))
            );
        assertFalse(ok);
        assertEq(
            keccak256(err), keccak256(abi.encodeWithSelector(E_WRITER.selector, address(this)))
        );
        // the live index cannot either, nor a fold hook (any other address)
        vm.prank(address(a.g.index));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(a.g.index)));
        mixed.replayFold(1, effects, refs);
        (uint64 processed,,) = mixed.progress();
        assertEq(processed, 0, "nothing folded");
        assertEq(mixed.build(bytes32(0), 64), 11, "its own build still folds");
    }

    // =============================================================================================
    // Coverage and readiness when a carried check fails (docs INDEX-BUILD §3.5, step 2)
    // =============================================================================================

    function testCoverageOfCarriedFamiliesFollowsTheCarriedCheck() public {
        _history(a);
        // a re-pin and a build that heals the posting store, both built while generation 1 is live
        (, IGeneration1 repin) = _gen(a, address(a.g.posting), address(a.g.bitmap));
        (, IGeneration1 mixed) = _gen(a, address(0), address(a.g.bitmap));
        assertEq(repin.build(bytes32(0), 64), 11);
        assertEq(mixed.build(bytes32(0), 64), 11);
        Coverage cov;
        uint64 from;
        uint64 through;
        (cov, from, through) = _coverage(repin, "by-type");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(11))
        );
        (cov, from, through) = _coverage(mixed, "scope");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(11))
        );
        // generation 2 replays into all-fresh stores and goes live: generation 1's stores are abandoned, with no
        // admission since (so they still hold everything through 11)
        (, IGeneration1 gen2) = _gen(a, address(0), address(0));
        while (gen2.replayNextPublication(64) != 0) {}
        _activate(a, address(gen2));
        // a carried family claims nothing once the check fails (step 1 reported COMPLETE here)
        (cov, from, through) = _coverage(repin, "by-type");
        assertEq(abi.encode(cov, from, through), abi.encode(Coverage.PARTIAL, uint64(1), uint64(0)));
        (cov, from, through) = _coverage(mixed, "scope");
        assertEq(abi.encode(cov, from, through), abi.encode(Coverage.PARTIAL, uint64(1), uint64(0)));
        // a built family in the generation's own fresh store keeps its frontier: it folded it itself
        (cov, from, through) = _coverage(mixed, "by-type");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(11))
        );
        (Coverage pc,,,,) =
            mixed.postingHeadOf(FamilyId.wrap(Keys.familyId("by-type")), _typeOk(), 0, bytes32(0));
        assertEq(uint8(pc), uint8(Coverage.COMPLETE));
        // readiness claims nothing for either, and both builds refuse 7
        assertEq(mixed.replayReadiness().completedAdmission, 0);
        assertFalse(mixed.replayReadiness().ready);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        mixed.build(bytes32(0), 64);
        // the live index, activated but not yet folded live (liveStarted 0: it takes the check, which passes for the
        // live index), answers COMPLETE
        (cov, from, through) = _coverage(gen2, "scope");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(11))
        );
        // generation 1 folded live and was replaced: it answers as before step 2, from its stale frontier, with no
        // check (COMPLETE while nothing has been admitted since, PARTIAL after)
        IGeneration1 gen1 = IGeneration1(address(a.g.index));
        (cov, from, through) = _coverage(gen1, "by-type");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(11))
        );
        assertEq(_one(a, _publish(THIRD), THIRD), 9);
        (cov, from, through) = _coverage(gen1, "by-type");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.PARTIAL, uint64(1), uint64(11))
        );
        (cov, from, through) = _coverage(gen2, "scope");
        assertEq(
            abi.encode(cov, from, through), abi.encode(Coverage.COMPLETE, uint64(1), uint64(12))
        );
        // a not-maintained family stays UNKNOWN
        (cov, from, through) = _coverage(mixed, "roster");
        assertEq(abi.encode(cov, from, through), abi.encode(Coverage.UNKNOWN, uint64(0), uint64(0)));
    }

    function _typeOk() internal pure returns (TypeId) {
        return TypeId.wrap(TYPE_OK);
    }
}
