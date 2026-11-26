// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {IndexDoubleDefaults, PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
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
    ScopeKey
} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Effect, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {E_BUILD, E_INDEX_NOT_READY, E_REPLAY} from "../../src/interfaces/Errors.sol";

/// The carried check, answered at a generation's address by its reads contract (through the fallback).
interface ICarried {
    function carriedCheck() external view returns (bool);
}

/// The Realm's controller in this suite: an owner-only batch of calls in one transaction, as a Safe sends them
/// (docs INDEX-BUILD §5.4 route 1). It is also the ProxyAdmin's owner. Bubbles the first failing call's revert.
contract Batch {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable owner = msg.sender;

    function exec(Call[] calldata calls) external {
        require(msg.sender == owner, "owner");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// A fold hook of the live generation that, once armed, calls `build(0, 64)` on a candidate from inside the
/// publication and records the refusal.
contract ArmedHook is IIndexHook {
    address public target;
    bytes public lastError;
    bool public built;

    function arm(address t) external {
        target = t;
    }

    function fold(Effect calldata, bytes32[] calldata, uint64) external returns (bytes4) {
        if (target != address(0)) {
            try IRealmIndex(target).build(bytes32(0), 64) {
                built = true;
            } catch (bytes memory err) {
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

/// The INITIAL_WRITER of a store that no generation names: on an empty, idle Realm it may write it in build mode.
contract Squatter {
    function squat(PostingStore store) external {
        store.append(
            FamilyId.wrap(Keys.familyId("by-type")),
            PostingKey.wrap(keccak256("efs/test/squat")),
            1,
            0
        );
    }
}

/// @notice Docs INDEX-BUILD step 1: a generation that carries stores becomes ready on a Realm with history
///         (`build(0, …)` moves its frontier once its carried check passes, §3.5) and is activated; a generation
///         that carries an abandoned store cannot, and the kernel's own checks (`E_INDEX_NOT_READY` 12 and 13,
///         §5.3) refuse it even when it lies about its progress.
contract CarriedTest is Test {
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
    ArmedHook internal hook;

    function setUp() public {
        hook = new ArmedHook();
        _realm(a, keccak256("salt-a"));
        _realm(b, keccak256("salt-b"));
    }

    // =============================================================================================
    // Setup and actions
    // =============================================================================================

    function _realm(Realm storage R, bytes32 salt) internal {
        R.registry = new MockRegistry();
        R.batch = new Batch();
        R.k = KernelDeploy.deploy(address(R.batch), address(R.registry), salt);
        R.registry.setLedger(R.k.proxy);
        R.registry.setImplementation(address(R.registry));
        Unit[] memory units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(hook),
            foldCodehash: address(hook).codehash,
            finalHook: address(0),
            finalCodehash: 0,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/armed-hook/1")
        });
        R.g = IndexDeploy.deploy(R.k.proxy, KernelDeploy.HOT_ABI_ID, units, _specs());
        // genesis: generation 1 names stores whose INITIAL_WRITER is 0 (carried by the definition), on a Realm with
        // no admissions, so neither the generation's carried check nor the kernel's has anything to prove
        assertTrue(ICarried(address(R.g.index)).carriedCheck());
        assertTrue(R.g.index.replayReadiness().ready);
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

    /// A history of every action kind: 11 admissions in 8 publications (the `Replay.t.sol` history).
    function _history(Realm storage R) internal {
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = SALT;
        actions[1] = _publish(BODY);
        actions[2] = _bind(R, ActionKind.BIND, NAME, _rid(BODY), 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = BODY;
        assertEq(_exec(R, actions, bodies), 1); // admissions 1..3
        Action memory reuse;
        reuse.kind = ActionKind.REUSE;
        reuse.typeId = TYPE_OK;
        reuse.bodyHashOrRecordId = _rid(BODY);
        assertEq(_one(R, reuse, ""), 2); // 4
        assertEq(_one(R, _bind(R, ActionKind.UNBIND, NAME, 0, 1), ""), 3); // 5: mask
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(BODY), 2), ""), 4); // 6: restore
        Action[] memory two = new Action[](2);
        two[0] = _publish(OTHER);
        two[1] = _bind(R, ActionKind.BIND, NAME, _rid(OTHER), 3);
        bytes[] memory tb = new bytes[](2);
        tb[0] = OTHER;
        assertEq(_exec(R, two, tb), 5); // 7: publish, 8: rebind
        assertEq(_one(R, _bind(R, ActionKind.BIND, SECOND, _rid(BODY), 0), ""), 6); // 9
        Action memory withdraw;
        withdraw.kind = ActionKind.WITHDRAW;
        withdraw.target = bytes32(uint256(4)); // the REUSE occurrence
        assertEq(_one(R, withdraw, ""), 7); // 10
        assertEq(_one(R, _bind(R, ActionKind.RELEASE, SECOND, 0, 1), ""), 8); // 11
        (uint64 admissions,,, uint64 publications) = _hot(R).counts();
        assertEq(admissions, 11);
        assertEq(publications, 8);
    }

    /// Traffic after the switch: a new record (admission 12), a re-bind of NAME to it (13), a mask of NAME (14).
    function _traffic(Realm storage R) internal {
        assertEq(_one(R, _publish(THIRD), THIRD), 9);
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(THIRD), 4), ""), 10);
        assertEq(_one(R, _bind(R, ActionKind.UNBIND, NAME, 0, 5), ""), 11);
    }

    // ---- generations -----------------------------------------------------------------------------------------

    /// A generation of generation 1's code over `posting` and `bitmap`, each carried when nonzero and fresh (a new
    /// store naming the generation as INITIAL_WRITER) when zero, created by `IndexDeployer` with no units.
    function _gen(Realm storage R, address posting, address bitmap)
        internal
        returns (IndexDeployer d, IGeneration1 ix)
    {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        if (posting == address(0)) plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.posting = posting;
        if (bitmap == address(0)) plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.bitmap = bitmap;
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = new Unit[](0);
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.liveManifest = ManifestCopy.ofLive(R.k.proxy);
        d = new IndexDeployer(R.k.proxy, keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    /// A generation that carries both of generation 1's stores (docs INDEX-BUILD case (a)).
    function _repin(Realm storage R) internal returns (IGeneration1 ix) {
        (, ix) = _gen(R, address(R.g.posting), address(R.g.bitmap));
    }

    // ---- activation through the batch -------------------------------------------------------------------------

    function _set(Realm storage R, address ix) internal returns (ActivationSet memory set) {
        uint32 rev = R.revision + 1;
        R.registry.setActiveRevision(rev);
        set = KernelDeploy.genesisSet(
            R.k, address(R.batch), address(R.registry), ix, IGeneration1(ix).manifestHash()
        );
        set.revision = rev;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, R.k.proxy);
    }

    function _activateCall(Realm storage R, ActivationSet memory set)
        internal
        view
        returns (Batch.Call memory)
    {
        return Batch.Call(R.k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
    }

    function _activate(Realm storage R, address ix) internal {
        ActivationSet memory set = _set(R, ix);
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = _activateCall(R, set);
        R.batch.exec(calls);
        R.revision = set.revision;
        assertEq(_hot(R).index(), ix);
    }

    function _expectActivateRevert(Realm storage R, address ix, uint8 reason) internal {
        ActivationSet memory set = _set(R, ix);
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = _activateCall(R, set);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, reason));
        R.batch.exec(calls);
        R.registry.setActiveRevision(R.revision); // the registry follows the ledger's revision again
    }

    // ---- comparison -------------------------------------------------------------------------------------------

    function _keys(Realm storage R) internal view returns (PostingKey[] memory keys) {
        bytes32 p = _principal(R);
        bytes32 bindingKey = Keys.binding(p, Keys.position(FOLDER, _subject(R), NAME));
        keys = new PostingKey[](11);
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
    }

    /// Every compared head and its entries are equal in the two Realms' generation-1 stores, and the scope head of
    /// the file's FOLDER scope is equal (keys are per Realm: the principal differs, the ordinals do not).
    function _assertSameHeads() internal view {
        PostingKey[] memory ka = _keys(a);
        PostingKey[] memory kb = _keys(b);
        for (uint256 i; i < ka.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = a.g.posting.postingHead(ka[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = b.g.posting.postingHead(kb[i]);
            assertEq(c1, c2, "count");
            assertEq(l1, l2, "live");
            assertEq(last1, last2, "last");
            assertEq(f1, f2, "flags");
            if (c1 != 0) {
                assertEq(
                    keccak256(abi.encode(a.g.posting.postingSlice(ka[i], 0, 64))),
                    keccak256(abi.encode(b.g.posting.postingSlice(kb[i], 0, 64)))
                );
            }
        }
        bytes32 sa = Keys.scope(_principal(a), FOLDER, _subject(a));
        bytes32 sb = Keys.scope(_principal(b), FOLDER, _subject(b));
        (uint64 sc1, uint64 sl1, uint64 lm1, uint48 bits1,, uint64 e1) =
            a.g.bitmap.scopeHead(ScopeKey.wrap(sa));
        (uint64 sc2, uint64 sl2, uint64 lm2, uint48 bits2,, uint64 e2) =
            b.g.bitmap.scopeHead(ScopeKey.wrap(sb));
        assertEq(sc1, sc2, "scope count");
        assertEq(sl1, sl2, "scope live");
        assertEq(lm1, lm2, "scope lastMutation");
        assertEq(bits1, bits2, "scope bits");
        assertEq(e1, e2);
    }

    function _writers(address store)
        internal
        view
        returns (address[] memory gens, uint64[] memory from, uint64[] memory to)
    {
        return IPostingStore(store).writers();
    }

    // =============================================================================================
    // 1. Re-pin only (docs INDEX-BUILD §8 test 5)
    // =============================================================================================

    function testRePinBuildsActivatesAndFoldsLiveIntoTheCarriedStores() public {
        _history(a);
        _history(b);
        _assertSameHeads();
        (address[] memory g0,,) = _writers(address(a.g.posting));
        assertEq(g0.length, 1);
        uint64 firstWrite;
        {
            (, uint64[] memory f0,) = _writers(address(a.g.posting));
            firstWrite = f0[0];
        }
        IGeneration1 gen2 = _repin(a);
        assertEq(gen2.postingStore(), address(a.g.posting), "carried, not recreated");
        assertEq(gen2.bitmapStore(), address(a.g.bitmap));
        // before the build: the carried check passes, the frontier is behind, activation refuses it as behind
        assertTrue(ICarried(address(gen2)).carriedCheck());
        Readiness memory r = gen2.replayReadiness();
        assertFalse(r.ready);
        assertEq(r.completedAdmission, 0);
        assertEq(r.completedPublication, 0);
        _expectActivateRevert(a, address(gen2), 8);
        // replay is for fresh stores only
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(1)));
        gen2.replayNextPublication(64);
        // the build folds nothing and moves the frontier to the ledger's counts
        vm.prank(address(0xBEEF)); // permissionless
        assertEq(gen2.build(bytes32(0), 64), 11);
        (uint64 processed, uint64 publication, bool gapped) = gen2.progress();
        assertEq(processed, 11);
        assertEq(publication, 8);
        assertFalse(gapped);
        r = gen2.replayReadiness();
        assertTrue(r.ready);
        assertEq(r.completedAdmission, 11);
        assertEq(r.completedPublication, 8);
        assertEq(
            gen2.build(bytes32(0), 64), 11, "a second call with nothing new keeps the frontier"
        );
        _activate(a, address(gen2));
        assertEq(_hot(a).indexGeneration(), 2);
        // the first live onAdmission finds expected = lastProcessed + 1; the next publications fold into the carried
        // stores exactly as in the Realm that never switched
        _traffic(a);
        _traffic(b);
        _assertSameHeads();
        (processed, publication,) = gen2.progress();
        assertEq(processed, 14);
        assertEq(publication, 11);
        (uint64 c,, uint64 last,) =
            a.g.posting.postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 4, "the by-type list continues: 3 before the switch, 1 after");
        assertEq(last, 12);
        // writer ranges: the first live write of generation 2 to each carried store, at admission k, closes
        // generation 1's range at k - 1 and opens generation 2's at k (posting: the PUBLISH at 12; bitmap: the
        // re-bind's stamp at 13)
        (address[] memory gens, uint64[] memory from, uint64[] memory to) =
            _writers(address(a.g.posting));
        assertEq(gens.length, 2);
        assertEq(gens[0], address(a.g.index));
        assertEq(from[0], firstWrite);
        assertEq(to[0], 11);
        assertEq(gens[1], address(gen2));
        assertEq(from[1], 12);
        assertEq(to[1], 0);
        (gens, from, to) = _writers(address(a.g.bitmap));
        assertEq(gens.length, 2);
        assertEq(gens[0], address(a.g.index));
        assertEq(to[0], 12);
        assertEq(gens[1], address(gen2));
        assertEq(from[1], 13);
        assertEq(to[1], 0);
        // once live, build is refused
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(1)));
        gen2.build(bytes32(0), 64);
        // generation 1, replaced, is behind and stays so
        assertFalse(a.g.index.replayReadiness().ready);
    }

    /// Generation 1's first live write is the first admission that writes a store; recorded here so the report
    /// can say what `from[0]` of a genesis store's first range is.
    function testGenesisStoreFirstRangeStartsAtItsFirstWrite() public {
        _history(a);
        (address[] memory gens, uint64[] memory from, uint64[] memory to) =
            _writers(address(a.g.posting));
        assertEq(gens.length, 1);
        assertEq(gens[0], address(a.g.index));
        assertEq(
            from[0],
            2,
            "admission 1 is a CREATE, which touches no family; the PUBLISH at 2 attaches"
        );
        assertEq(to[0], 0);
        (gens, from,) = _writers(address(a.g.bitmap));
        assertEq(from[0], 3, "the first bind");
    }

    // =============================================================================================
    // 2. A publication slips in; the one-transaction route
    // =============================================================================================

    function testAPublicationBetweenBuildAndActivateIsRefusedThenBuiltAgain() public {
        _history(a);
        IGeneration1 gen2 = _repin(a);
        assertEq(gen2.build(bytes32(0), 64), 11);
        assertEq(_one(a, _publish(THIRD), THIRD), 9); // admission 12
        assertFalse(gen2.replayReadiness().ready);
        _expectActivateRevert(a, address(gen2), 8);
        assertEq(gen2.build(bytes32(0), 64), 12, "the frontier moves again");
        (, uint64 publication,) = gen2.progress();
        assertEq(publication, 9);
        _activate(a, address(gen2));
        assertEq(_one(a, _bind(a, ActionKind.BIND, NAME, _rid(THIRD), 4), ""), 10);
        (uint64 processed,,) = gen2.progress();
        assertEq(processed, 13);
    }

    function testBuildAndActivateInOneTransaction() public {
        _history(a);
        IGeneration1 gen2 = _repin(a);
        assertEq(_one(a, _publish(THIRD), THIRD), 9);
        ActivationSet memory set = _set(a, address(gen2));
        Batch.Call[] memory calls = new Batch.Call[](2);
        calls[0] = Batch.Call(address(gen2), abi.encodeCall(IRealmIndex.build, (bytes32(0), 64)));
        calls[1] = _activateCall(a, set);
        a.batch.exec(calls);
        assertEq(_hot(a).index(), address(gen2));
        (uint64 processed, uint64 publication,) = gen2.progress();
        assertEq(processed, 12);
        assertEq(publication, 9);
    }

    // =============================================================================================
    // 3. An abandoned carried store (docs INDEX-BUILD §8 test 6)
    // =============================================================================================

    function testAnAbandonedCarriedStoreIsRefusedByTheGenerationAndTheKernel() public {
        _history(a);
        // a re-pin built while generation 1 is live: ready at that moment
        IGeneration1 early = _repin(a);
        assertEq(early.build(bytes32(0), 64), 11);
        assertTrue(early.replayReadiness().ready);
        // generation 2 replays into all-fresh stores and goes live; generation 1's stores are abandoned
        (IndexDeployer d2, IGeneration1 gen2) = _gen(a, address(0), address(0));
        while (gen2.replayNextPublication(64) != 0) {}
        _activate(a, address(gen2));
        assertEq(_one(a, _publish(THIRD), THIRD), 9); // admission 12 reaches only generation 2's stores
        (uint64 c,,,) = a.g.posting.postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 3, "the abandoned store missed admission 12");
        (c,,,) =
            IPostingStore(d2.postingStore()).postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 4);
        // its writers list is contiguous all the same: writer ranges are not coverage
        (address[] memory gens,, uint64[] memory to) = _writers(address(a.g.posting));
        assertEq(gens.length, 1);
        assertEq(to[0], 0);

        // the re-pin built earlier no longer claims anything, at the moment it is read
        assertFalse(ICarried(address(early)).carriedCheck());
        Readiness memory r = early.replayReadiness();
        assertFalse(r.ready);
        assertEq(r.completedAdmission, 0);
        assertEq(r.completedPublication, 0);
        (uint64 processed,,) = early.progress();
        assertEq(processed, 11, "its progress word is unchanged; readiness withholds it");
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        early.build(bytes32(0), 64);
        // its copy of the live index's manifest is generation 1's, stale since generation 2 went live: the kernel
        // refuses it 14 before it compares a family (docs INDEX-BUILD §10)
        _expectActivateRevert(a, address(early), 14);

        // generation 3 re-pins generation 1's old stores after the switch: refused the same way
        IGeneration1 gen3 = _repin(a);
        assertFalse(ICarried(address(gen3)).carriedCheck());
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        gen3.build(bytes32(0), 64);
        r = gen3.replayReadiness();
        assertFalse(r.ready);
        assertEq(r.completedAdmission, 0);
        _expectActivateRevert(a, address(gen3), 12);

        // the kernel's own check: a generation that lies (it reports itself caught up while declaring generation
        // 1's families in generation 1's old stores) is refused with 12, from the live index's manifest
        PrefixAgreement liar = new PrefixAgreement(a.k.proxy);
        liar.setManifestHash(keccak256("efs/test/carried/liar"));
        (uint64 admissions,,, uint64 publications) = _hot(a).counts();
        liar.setProgress(admissions, publications);
        Readiness memory lie = a.g.index.replayReadiness();
        lie.manifestHash = liar.manifestHash();
        lie.completedAdmission = admissions;
        lie.completedPublication = publications;
        lie.ready = true;
        lie.units = new Unit[](0);
        liar.setReadiness(lie);
        liar.setLiveManifestCopy(ManifestCopy.ofLive(a.k.proxy)); // a true copy: generation 2's manifest
        _expectActivateRevert(a, address(liar), 12);
        // the same lie over generation 2's live stores passes the carried check and activates: 12 is about stores
        Readiness memory honest = gen2.replayReadiness();
        honest.manifestHash = liar.manifestHash();
        honest.units = new Unit[](0);
        liar.setReadiness(honest);
        _activate(a, address(liar));
    }

    // =============================================================================================
    // 4. Check 13: a candidate's fresh store is already attached
    // =============================================================================================

    /// The smallest honest setup: generation 2 replays into fresh stores (INITIAL_WRITER = generation 2), goes live
    /// and writes them (attached); generation 3 re-pins them and takes over; re-activating generation 2 names stores
    /// that call it their INITIAL_WRITER and are attached, which only a live write does.
    function testAFreshStoreAlreadyAttachedIsRefused13() public {
        _history(a);
        (IndexDeployer d2, IGeneration1 gen2) = _gen(a, address(0), address(0));
        while (gen2.replayNextPublication(64) != 0) {}
        _activate(a, address(gen2));
        assertEq(_one(a, _publish(THIRD), THIRD), 9);
        assertTrue(IPostingStore(d2.postingStore()).attached());
        (, IGeneration1 gen3) = _gen(a, d2.postingStore(), d2.bitmapStore());
        assertEq(gen3.build(bytes32(0), 64), 12);
        _activate(a, address(gen3));
        assertEq(_one(a, _bind(a, ActionKind.BIND, NAME, _rid(THIRD), 4), ""), 10);
        assertEq(IPostingStore(d2.postingStore()).initialWriter(), address(gen2));
        _expectActivateRevert(a, address(gen2), 13);
    }

    // =============================================================================================
    // 5. Refusals
    // =============================================================================================

    function testBuildRefusals() public {
        _history(a);
        IGeneration1 gen2 = _repin(a);
        // a nonzero familyId
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(8)));
        gen2.build(keccak256("efs/family/by-author/1"), 64);
        // from inside a publication: generation 1's fold hook calls it while the ledger is APPLYING
        hook.arm(address(gen2));
        assertEq(_one(a, _publish(THIRD), THIRD), 9);
        assertFalse(hook.built());
        assertEq(
            keccak256(hook.lastError()),
            keccak256(abi.encodeWithSelector(E_BUILD.selector, uint8(3)))
        );
        hook.arm(address(0));
        // a generation with a fresh store walks history into it (step 2; `test/index/BuildWalk.t.sol`): one fresh and
        // one carried, and both fresh, where replay and build resume each other's frontier
        (, IGeneration1 mixed) = _gen(a, address(a.g.posting), address(0));
        assertEq(mixed.build(bytes32(0), 64), 12);
        (, IGeneration1 fresh) = _gen(a, address(0), address(0));
        assertEq(fresh.replayNextPublication(64), 3, "replay still serves the all-fresh case");
        assertEq(fresh.build(bytes32(0), 64), 12, "the build resumes the replay's frontier");
        // after the generation is live
        assertEq(gen2.build(bytes32(0), 64), 12);
        _activate(a, address(gen2));
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(1)));
        gen2.build(bytes32(0), 64);
        // the live generation 1, replaced, has folded live: refused too
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(1)));
        a.g.index.build(bytes32(0), 64);
    }

    // =============================================================================================
    // 6. A Realm with no admissions
    // =============================================================================================

    function testZeroAdmissionRealmActivatesACarriedGeneration() public {
        IGeneration1 gen2 = _repin(a);
        assertTrue(ICarried(address(gen2)).carriedCheck());
        Readiness memory r = gen2.replayReadiness();
        assertTrue(r.ready, "nothing to prove with no admissions");
        assertEq(r.completedAdmission, 0);
        assertEq(gen2.build(bytes32(0), 64), 0);
        _activate(a, address(gen2));
        _history(a);
        (address[] memory gens, uint64[] memory from, uint64[] memory to) =
            _writers(address(a.g.posting));
        assertEq(gens.length, 1, "generation 1 never wrote the store");
        assertEq(gens[0], address(gen2));
        assertEq(from[0], 2);
        assertEq(to[0], 0);
        (uint64 processed,,) = gen2.progress();
        assertEq(processed, 11);
    }

    /// The base case of "every store of the live index holds only what pinned generation code wrote": on an empty
    /// Realm a store that its own INITIAL_WRITER (a contract nobody pinned) wrote in build mode is refused, by the
    /// generation (`build` 7, not ready) and by the kernel (12). The generation's tuple reports 0, which equals the
    /// empty Realm's counts, so the kernel's check is what refuses it.
    function testAnEmptyRealmRefusesAStoreWrittenBeforeAnyAdmission() public {
        Squatter squatter = new Squatter();
        PostingStore squatted =
            new PostingStore(a.k.proxy, address(squatter), IndexDeploy.postingFamilies());
        squatter.squat(squatted);
        (address[] memory gens, uint64[] memory from,) = _writers(address(squatted));
        assertEq(gens.length, 1);
        assertEq(gens[0], address(squatter));
        assertEq(from[0], 1);
        assertFalse(squatted.attached());
        (, IGeneration1 candidate) = _gen(a, address(squatted), address(a.g.bitmap));
        assertFalse(ICarried(address(candidate)).carriedCheck());
        Readiness memory r = candidate.replayReadiness();
        assertFalse(r.ready);
        assertEq(r.completedAdmission, 0, "0 is also the empty Realm's count");
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        candidate.build(bytes32(0), 64);
        _expectActivateRevert(a, address(candidate), 12);
        // the same candidate shape over pristine stores activates (testZeroAdmissionRealmActivatesACarriedGeneration)
        IGeneration1 clean = _repin(a);
        assertTrue(ICarried(address(clean)).carriedCheck());
        _activate(a, address(clean));
    }

    /// Genesis is unchanged: generation 1's stores are new, their writers lists empty, and the activation in `setUp`
    /// passed the empty-Realm rule.
    function testGenesisStoresAreUnwritten() public view {
        (address[] memory gens,,) = _writers(address(a.g.posting));
        assertEq(gens.length, 0);
        (gens,,) = _writers(address(a.g.bitmap));
        assertEq(gens.length, 0);
        assertEq(_hot(a).index(), address(a.g.index));
        assertTrue(ICarried(address(a.g.index)).carriedCheck());
        assertTrue(a.g.index.replayReadiness().ready);
    }

    /// Without a build, the zero-admission activation needs no build call at all.
    function testZeroAdmissionRealmActivatesWithoutABuild() public {
        IGeneration1 gen2 = _repin(a);
        _activate(a, address(gen2));
        assertEq(_one(a, _publish(THIRD), THIRD), 1);
        (uint64 processed, uint64 publication,) = gen2.progress();
        assertEq(processed, 1);
        assertEq(publication, 1);
    }
}
