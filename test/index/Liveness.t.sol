// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Batch} from "./Carried.t.sol";
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
import {Action, ActionKind, Native, PostingKey, ScopeKey} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {E_BUILD, E_INDEX_NOT_READY, E_PIN} from "../../src/interfaces/Errors.sol";

interface ICarriedCheck {
    function carriedCheck() external view returns (bool);
    function LIVE_COPY() external view returns (address);
    function LIVE_COPY_CODEHASH() external view returns (bytes32);
}

/// @notice A test double: generation 1's real read side, whose carried check REVERTS once `breakNow()` is called. The
///         live index's `replayReadiness` runs the carried check, so after the switch every `replayReadiness` of the
///         generation over this reads contract reverts `E_BROKEN`, while it keeps folding correctly (the fold runs in
///         `RealmIndex`, which never asks the reads contract). Its `manifest()` still answers: it is static.
contract BreakableReads is IndexReads {
    error E_BROKEN();

    bool public broken;

    constructor(address ledger_, address posting, address bitmap, DigestSpec[] memory specs)
        IndexReads(
            ledger_,
            KernelDeploy.HOT_ABI_ID,
            posting,
            bitmap,
            new Unit[](0),
            specs,
            IndexDoubleDefaults.workModel(),
            0,
            0,
            ""
        )
    {}

    function breakNow() external {
        broken = true;
    }

    function _carriedCheck(address gen) internal view override returns (bool) {
        if (broken) revert E_BROKEN();
        return super._carriedCheck(gen);
    }
}

/// @notice Docs INDEX-BUILD §10, the pre-freeze gate "activation must not depend on the live index answering": a
///         candidate carries a copy of the live index's manifest preimage (`IIndexReads.liveManifestCopy`), and both the
///         kernel (check 12, reason 14) and the generation's own carried check read the live index's families from that
///         copy once it hashes to the `indexManifestHash` the kernel recorded, never from the live index.
///
///         Before this change (main at 4003069) the same scenario was refused: `LedgerControl._liveFamilies` called
///         `IRealmIndex(live).replayReadiness()` uncaught, so the activation reverted with the live index's own error,
///         and `IndexReads._carriedCheck` caught the same revert and returned false, so `build` reverted `E_BUILD(7)`
///         and readiness claimed nothing. Run against that tree (`git archive 4003069`, the same scenario with no copy):
///         `build` → `E_BUILD(7)`, activation → `BreakableReads.E_BROKEN()`. The suite pins the input those two code
///         paths read (`test_a_live_index_that_stops_answering_is_replaced_by_a_re_pin`: the live index's
///         `replayReadiness` reverts `E_BROKEN`).
contract LivenessTest is Test {
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

    Realm internal a; // generation 1 over BreakableReads
    Realm internal b; // the twin: generation 1 throughout
    BreakableReads internal breakable;

    function setUp() public {
        _realm(a, keccak256("salt-a"), true);
        _realm(b, keccak256("salt-b"), false);
    }

    // =============================================================================================
    // Setup and actions (the `Carried.t.sol` Realm and history)
    // =============================================================================================

    function _realm(Realm storage R, bytes32 salt, bool breakableGen1) internal {
        R.registry = new MockRegistry();
        R.batch = new Batch();
        R.k = KernelDeploy.deploy(address(R.batch), address(R.registry), salt);
        R.registry.setLedger(R.k.proxy);
        R.registry.setImplementation(address(R.registry));
        if (breakableGen1) {
            R.g.posting = new PostingStore(R.k.proxy, address(0), IndexDeploy.postingFamilies());
            R.g.bitmap = new BitmapStore(R.k.proxy, address(0), IndexDeploy.bitmapFamilies());
            breakable =
                new BreakableReads(R.k.proxy, address(R.g.posting), address(R.g.bitmap), _specs());
            R.g.reads = breakable;
            R.g.index =
                IGeneration1(address(new RealmIndex(R.k.proxy, address(0), address(breakable))));
        } else {
            R.g = IndexDeploy.deploy(R.k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), _specs());
        }
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

    /// 11 admissions in 8 publications (the `Carried.t.sol` history).
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
        (uint64 admissions,,, uint64 publications) = _hot(R).counts();
        assertEq(admissions, 11);
        assertEq(publications, 8);
    }

    /// A new record (admission 12), a re-bind of NAME to it (13), a mask of NAME (14).
    function _traffic(Realm storage R) internal {
        assertEq(_one(R, _publish(THIRD), THIRD), 9);
        assertEq(_one(R, _bind(R, ActionKind.BIND, NAME, _rid(THIRD), 4), ""), 10);
        assertEq(_one(R, _bind(R, ActionKind.UNBIND, NAME, 0, 5), ""), 11);
    }

    // ---- generations -----------------------------------------------------------------------------------------

    /// Generation 1's code over `posting` and `bitmap` (carried when nonzero, fresh when zero), deployed by
    /// `IndexDeployer` with `copy` as its copy of the live index's manifest.
    function _gen(Realm storage R, address posting, address bitmap, bytes memory copy)
        internal
        returns (IGeneration1 ix)
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
        plan.liveManifest = copy;
        IndexDeployer d = new IndexDeployer(R.k.proxy, keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    function _repin(Realm storage R, bytes memory copy) internal returns (IGeneration1) {
        return _gen(R, address(R.g.posting), address(R.g.bitmap), copy);
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

    function _activateSet(Realm storage R, ActivationSet memory set) internal {
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = Batch.Call(R.k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        R.batch.exec(calls);
        R.revision = set.revision;
    }

    function _activate(Realm storage R, address ix) internal {
        _activateSet(R, _set(R, ix));
        assertEq(_hot(R).index(), ix);
    }

    function _expectActivateRevert(Realm storage R, address ix, bytes memory err) internal {
        ActivationSet memory set = _set(R, ix);
        Batch.Call[] memory calls = new Batch.Call[](1);
        calls[0] = Batch.Call(R.k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        vm.expectRevert(err);
        R.batch.exec(calls);
        R.registry.setActiveRevision(R.revision);
    }

    function _notReady(uint8 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_INDEX_NOT_READY.selector, reason);
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

    /// Every compared list and the FOLDER scope head are equal in the two Realms' stores.
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
        (uint64 sc1, uint64 sl1, uint64 lm1, uint48 bits1,, uint64 e1) =
            a.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(_principal(a), FOLDER, _subject(a))));
        (uint64 sc2, uint64 sl2, uint64 lm2, uint48 bits2,, uint64 e2) =
            b.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(_principal(b), FOLDER, _subject(b))));
        assertEq(sc1, sc2, "scope count");
        assertEq(sl1, sl2, "scope live");
        assertEq(lm1, lm2, "scope lastMutation");
        assertEq(bits1, bits2, "scope bits");
        assertEq(e1, e2);
    }

    /// A re-pin of `a`'s stores with a correct copy builds, is ready, activates, folds the next publications live,
    /// and every list equals the twin's.
    function _replaceAndCompare(bytes memory copy) internal returns (IGeneration1 gen2) {
        gen2 = _repin(a, copy);
        assertTrue(ICarriedCheck(address(gen2)).carriedCheck());
        assertEq(gen2.build(bytes32(0), 64), 11);
        Readiness memory r = gen2.replayReadiness();
        assertTrue(r.ready);
        assertEq(r.completedAdmission, 11);
        _activate(a, address(gen2));
        _traffic(a);
        _traffic(b);
        (uint64 processed,,) = gen2.progress();
        assertEq(processed, 14, "the next publications folded live into the new index");
        _assertSameHeads();
    }

    // =============================================================================================
    // 1. The live index stops answering
    // =============================================================================================

    function test_a_live_index_that_stops_answering_is_replaced_by_a_re_pin() public {
        _history(a);
        _history(b);
        _assertSameHeads();
        address live = address(a.g.index);
        breakable.breakNow();
        // the input the code before this change read: the live index's readiness now reverts (it still folds)
        vm.expectRevert(BreakableReads.E_BROKEN.selector);
        IRealmIndex(live).replayReadiness();
        // the copy is taken from the live index's reads contract, whose manifest is static
        bytes memory copy = ManifestCopy.ofReads(address(breakable));
        assertEq(keccak256(copy), IGeneration1(live).manifestHash(), "the copy is the preimage");
        _replaceAndCompare(copy);
    }

    /// The stronger form: every call to the live index's address reverts once the re-pin is deployed (its fold
    /// included, so this also shows nothing calls it again after the switch).
    function test_a_live_index_whose_every_call_reverts_is_replaced_by_a_re_pin() public {
        _history(a);
        _history(b);
        bytes memory copy = ManifestCopy.ofReads(address(breakable));
        IGeneration1 gen2 = _repin(a, copy);
        address live = address(a.g.index);
        vm.mockCallRevert(live, bytes(""), abi.encodeWithSignature("E_DEAD()"));
        vm.expectRevert(abi.encodeWithSignature("E_DEAD()"));
        IRealmIndex(live).replayReadiness();
        vm.expectRevert(abi.encodeWithSignature("E_DEAD()"));
        IGeneration1(live).manifestHash();
        assertTrue(ICarriedCheck(address(gen2)).carriedCheck());
        assertEq(gen2.build(bytes32(0), 64), 11);
        assertTrue(gen2.replayReadiness().ready);
        _activate(a, address(gen2));
        _traffic(a);
        _traffic(b);
        _assertSameHeads();
        vm.clearMockedCalls();
    }

    // =============================================================================================
    // 2. A wrong copy
    // =============================================================================================

    function _expectRefused(IGeneration1 gen, string memory label) internal {
        assertFalse(ICarriedCheck(address(gen)).carriedCheck(), label);
        Readiness memory r = gen.replayReadiness();
        assertFalse(r.ready, label);
        assertEq(r.completedAdmission, 0, label);
        assertEq(r.completedPublication, 0, label);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        gen.build(bytes32(0), 64);
        _expectActivateRevert(a, address(gen), _notReady(14));
    }

    function test_a_wrong_copy_is_refused() public {
        _history(a);
        bytes memory good = ManifestCopy.ofReads(address(breakable));
        // one byte changed inside the family table
        bytes memory flipped = bytes.concat(good);
        flipped[32 * 30] = bytes1(uint8(flipped[32 * 30]) ^ 1);
        _expectRefused(_repin(a, flipped), "a byte of the families");
        // one byte changed after the families (the trailing readsCodehash): the kernel decodes only the leading
        // values, and the hash covers the rest
        bytes memory tail = bytes.concat(good);
        tail[tail.length - 1] = bytes1(uint8(tail[tail.length - 1]) ^ 1);
        _expectRefused(_repin(a, tail), "the last byte");
        // truncated, and with extra trailing bytes (both still decode to the same families)
        bytes memory truncated = new bytes(good.length - 32);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = good[i];
        }
        _expectRefused(_repin(a, truncated), "truncated");
        _expectRefused(_repin(a, bytes.concat(good, bytes32(0))), "extra trailing bytes");
        // empty, on a Realm with admissions
        _expectRefused(_repin(a, ""), "empty");
        // the manifest of a different generation (the twin Realm's generation 1: same families, other stores)
        _expectRefused(_repin(a, ManifestCopy.ofReads(address(b.g.reads))), "another generation");
        // the good copy, for contrast
        IGeneration1 ok = _repin(a, good);
        assertTrue(ICarriedCheck(address(ok)).carriedCheck());
        assertEq(ok.build(bytes32(0), 64), 11);
        _activate(a, address(ok));
    }

    /// The copy lives in a data contract created by the reads contract's constructor: one STOP byte, then the copy,
    /// bound by address and codehash; `liveManifestCopy` reads it back exactly. An all-fresh generation never asks for
    /// it (it carries nothing), so a wrong copy does not stop a full replay.
    function test_the_copy_is_held_as_code_and_an_all_fresh_generation_never_asks() public {
        _history(a);
        bytes memory good = ManifestCopy.ofReads(address(breakable));
        IGeneration1 g2 = _repin(a, good);
        ICarriedCheck reads = ICarriedCheck(g2.READS());
        address data = reads.LIVE_COPY();
        assertEq(data.code.length, good.length + 1);
        assertEq(uint8(data.code[0]), 0, "starts with STOP");
        assertEq(reads.LIVE_COPY_CODEHASH(), keccak256(bytes.concat(hex"00", good)));
        assertEq(data.codehash, reads.LIVE_COPY_CODEHASH());
        assertEq(keccak256(g2.liveManifestCopy()), keccak256(good), "read back exactly");
        // genesis and an empty copy hold no data contract
        assertEq(ICarriedCheck(address(breakable)).LIVE_COPY(), address(0));
        assertEq(IGeneration1(address(a.g.index)).liveManifestCopy().length, 0);
        // all fresh: replayed with an empty copy, activated
        IGeneration1 fresh = _gen(a, address(0), address(0), "");
        while (fresh.replayNextPublication(64) != 0) {}
        assertTrue(fresh.replayReadiness().ready);
        _activate(a, address(fresh));
    }

    /// The code form's limit: a copy of 24,575 B is held (EIP-170's 24,576 B runtime less the STOP byte); one byte more
    /// is refused at construction with its own code, `E_PIN(reads, 12)`.
    function test_an_oversize_copy_is_refused_at_construction() public {
        IndexReads fits = _readsWith(new bytes(24_575));
        assertEq(fits.LIVE_COPY().code.length, 24_576);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(E_PIN.selector, next, uint8(12)));
        _readsWith(new bytes(24_576));
    }

    function _readsWith(bytes memory copy) internal returns (IndexReads) {
        return new IndexReads(
            a.k.proxy,
            KernelDeploy.HOT_ABI_ID,
            address(a.g.posting),
            address(a.g.bitmap),
            new Unit[](0),
            _specs(),
            IndexDoubleDefaults.workModel(),
            0,
            0,
            copy
        );
    }

    // =============================================================================================
    // 3. A stale copy
    // =============================================================================================

    function test_a_stale_copy_is_refused_and_a_fresh_one_activates() public {
        _history(a);
        bytes memory l1 = ManifestCopy.ofReads(address(breakable));
        // C is deployed against L1 = generation 1
        IGeneration1 c = _repin(a, l1);
        assertTrue(ICarriedCheck(address(c)).carriedCheck());
        assertEq(c.build(bytes32(0), 64), 11);
        assertTrue(c.replayReadiness().ready, "ready while L1 is live");
        // L1 is replaced by L2, a re-pin of the same stores with L1's copy
        IGeneration1 l2 = _repin(a, l1);
        assertEq(l2.build(bytes32(0), 64), 11);
        _activate(a, address(l2));
        // C's copy is now stale: refused by the generation and by the kernel
        _expectRefused(c, "stale");
        // redeployed with L2's manifest, it activates
        IGeneration1 c2 = _repin(a, ManifestCopy.ofLive(a.k.proxy));
        assertEq(keccak256(c2.liveManifestCopy()), l2.manifestHash());
        assertEq(c2.build(bytes32(0), 64), 11);
        _activate(a, address(c2));
    }

    // =============================================================================================
    // 4. A lying candidate
    // =============================================================================================

    /// A double that reports itself caught up and declares generation 1's families, one of them in a store the live
    /// index does not declare: with a true copy the kernel refuses it 12, with a forged copy that "declares" that
    /// store 14. The kernel's defense does not rest on the candidate's honesty.
    function test_a_lying_candidate_is_refused_12_with_a_true_copy_and_14_with_a_forged_one()
        public
    {
        _history(a);
        PostingStore stray = new PostingStore(a.k.proxy, address(0), IndexDeploy.postingFamilies());
        PrefixAgreement liar = new PrefixAgreement(a.k.proxy);
        liar.setManifestHash(keccak256("efs/test/liveness/liar"));
        (uint64 admissions,,, uint64 publications) = _hot(a).counts();
        liar.setProgress(admissions, publications);
        // the live index's own tuple, taken before it breaks, with the first posting family moved to the stray store
        Readiness memory lie = a.g.index.replayReadiness();
        lie.manifestHash = liar.manifestHash();
        lie.completedAdmission = admissions;
        lie.completedPublication = publications;
        lie.ready = true;
        uint256 moved = lie.families[0].store == address(a.g.posting) ? 0 : 1;
        lie.families[moved].store = address(stray);
        lie.families[moved].storeCodehash = address(stray).codehash;
        liar.setReadiness(lie);
        breakable.breakNow(); // the kernel never asks the live index
        bytes memory good = ManifestCopy.ofReads(address(breakable));
        liar.setLiveManifestCopy(good);
        _expectActivateRevert(a, address(liar), _notReady(12));
        // a forged copy: the live manifest with the same family moved, so the copy "declares" the stray store
        (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,,
            bytes32 physical,
            bytes32 callback
        ) = IndexReads(address(breakable)).manifest();
        families[moved].store = address(stray);
        families[moved].storeCodehash = address(stray).codehash;
        liar.setLiveManifestCopy(
            abi.encode(
                header,
                families,
                units,
                specs,
                IndexDoubleDefaults.workModel(),
                physical,
                callback,
                address(breakable),
                address(breakable).codehash
            )
        );
        _expectActivateRevert(a, address(liar), _notReady(14));
        // the same lie with the stray store put back and the true copy passes 12: the check is about stores
        lie.families[moved].store = address(a.g.posting);
        lie.families[moved].storeCodehash = address(a.g.posting).codehash;
        liar.setReadiness(lie);
        liar.setLiveManifestCopy(good);
        _activate(a, address(liar));
    }

    // =============================================================================================
    // 5. The empty Realm and genesis
    // =============================================================================================

    /// On an empty Realm nothing asks for the copy (§5.3's empty-Realm rule is unchanged): a re-pin with an empty
    /// copy and one with a garbage copy both activate; genesis activated in `setUp` with an empty copy.
    function test_the_empty_realm_never_asks_for_the_copy() public {
        assertEq(IGeneration1(address(a.g.index)).liveManifestCopy().length, 0, "genesis: empty");
        IGeneration1 garbage = _repin(a, "not a manifest");
        assertTrue(ICarriedCheck(address(garbage)).carriedCheck());
        assertTrue(garbage.replayReadiness().ready);
        IGeneration1 empty = _repin(a, "");
        assertTrue(ICarriedCheck(address(empty)).carriedCheck());
        _activate(a, address(empty));
        _history(a);
        (uint64 processed,,) = empty.progress();
        assertEq(processed, 11);
    }

    // =============================================================================================
    // 6. The unchanged-index path
    // =============================================================================================

    /// An activation that KEEPS the live index still reads its readiness phase (reason 2), uncaught: while the live
    /// index does not answer, such an activation reverts with the live index's own error. The recovery is the
    /// replacement (test 1), which no longer reads the live index.
    function test_keeping_an_index_that_stops_answering_reverts_with_its_error() public {
        _history(a);
        breakable.breakNow();
        _expectActivateRevert(
            a, address(a.g.index), abi.encodeWithSelector(BreakableReads.E_BROKEN.selector)
        );
        _replaceAndCompareAfterBreak();
    }

    function _replaceAndCompareAfterBreak() internal {
        _history(b);
        _replaceAndCompare(ManifestCopy.ofReads(address(breakable)));
    }
}
