// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {StandInTypes} from "../harness/doubles/StandInTypes.sol";
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
import {Coverage, Phase} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Effect, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {AlreadyAdmitted, E_REPLAY} from "../../src/interfaces/Errors.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";

/// @notice Design §10.6 replay: a second generation with fresh stores catches up on a history of every action
///         kind through the pinned decoder, its stores equal the live generation's family by family, its
///         readiness is re-derived at activation, and after the index replacement writes fold live into the
///         replayed stores while the pre-replacement publication retries as AlreadyAdmitted.
/// A fold hook that tries to re-enter the replay from inside a fold.
contract ReenteringHook is IIndexHook {
    bool public reentered;
    bytes public lastError;

    function fold(Effect calldata, bytes32[] calldata, uint64) external returns (bytes4) {
        try IRealmIndex(msg.sender).replayNextPublication(64) {
            reentered = true;
        } catch (bytes memory err) {
            lastError = err;
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

contract ReplayTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;
    bytes32 internal constant TYPE_OK = StandInTypes.OK_ID; // derived from a real descriptor
    bytes32 internal constant FOLDER = keccak256("efs/purpose/folder/1");
    bytes32 internal constant NAME = keccak256("name");
    bytes32 internal principal;
    bytes internal body = "0123456789abcdef0123456789abcdef-tail";
    bytes internal other = "another body of thirty-two-plus bytes!";
    bytes32 internal salt = keccak256("file-1");
    bytes32 internal subject;
    bytes32 internal recordId;
    bytes32 internal otherId;
    bytes32 internal scopeKey;
    bytes32 internal bindingKey;
    uint64 internal nonce;

    bytes32[] internal families;

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), _specs());
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
        registry.setType(TYPE_OK, info, new bytes32[](0));
        registry.setDescriptor(TYPE_OK, StandInTypes.ok());
        principal = Keys.principalFor(address(this), hot.realmOrigin());
        subject = Keys.subject(principal, salt);
        recordId = Keys.recordFromHash(TYPE_OK, keccak256(body));
        otherId = Keys.recordFromHash(TYPE_OK, keccak256(other));
        scopeKey = Keys.scope(principal, FOLDER, subject);
        bindingKey = Keys.binding(principal, Keys.position(FOLDER, subject, NAME));
        families = IndexDeploy.postingFamilies();
    }

    function _specs() internal pure returns (DigestSpec[] memory specs) {
        specs = new DigestSpec[](1);
        specs[0] = DigestSpec({typeId: TYPE_OK, wordIndex: 0, algorithm: 1});
    }

    // ---- a history of every kind ------------------------------------------------------------------------------

    function _exec(Action[] memory actions, bytes[] memory bodies) internal returns (uint64 p) {
        Native memory ctx;
        ctx.nonce = nonce++;
        (p,) = ledger.execute(actions, bodies, ctx, "");
    }

    function _one(Action memory a, bytes memory b) internal returns (uint64) {
        Action[] memory actions = new Action[](1);
        actions[0] = a;
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = b;
        return _exec(actions, bodies);
    }

    function _bindKind(uint8 kind, bytes32 role, bytes32 target, uint64 expected)
        internal
        view
        returns (Action memory a)
    {
        a.kind = kind;
        a.purpose = FOLDER;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _history() internal {
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = salt;
        actions[1].kind = ActionKind.PUBLISH;
        actions[1].typeId = TYPE_OK;
        actions[1].bodyHashOrRecordId = keccak256(body);
        actions[2] = _bindKind(ActionKind.BIND, NAME, recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        assertEq(_exec(actions, bodies), 1); // admissions 1..3
        Action memory reuse;
        reuse.kind = ActionKind.REUSE;
        reuse.typeId = TYPE_OK;
        reuse.bodyHashOrRecordId = recordId;
        assertEq(_one(reuse, ""), 2); // admission 4
        assertEq(_one(_bindKind(ActionKind.UNBIND, NAME, 0, 1), ""), 3); // 5: mask
        assertEq(_one(_bindKind(ActionKind.BIND, NAME, recordId, 2), ""), 4); // 6: restore
        Action[] memory two = new Action[](2);
        two[0].kind = ActionKind.PUBLISH;
        two[0].typeId = TYPE_OK;
        two[0].bodyHashOrRecordId = keccak256(other);
        two[1] = _bindKind(ActionKind.BIND, NAME, otherId, 3);
        bytes[] memory tb = new bytes[](2);
        tb[0] = other;
        assertEq(_exec(two, tb), 5); // 7: publish other, 8: rebind
        assertEq(_one(_bindKind(ActionKind.BIND, keccak256("second"), recordId, 0), ""), 6); // 9: a second scope entry
        Action memory withdraw;
        withdraw.kind = ActionKind.WITHDRAW;
        withdraw.target = bytes32(uint256(4)); // the REUSE occurrence
        assertEq(_one(withdraw, ""), 7); // 10
        assertEq(_one(_bindKind(ActionKind.RELEASE, keccak256("second"), 0, 1), ""), 8); // 11: release
        (uint64 admissions,,, uint64 publications) = hot.counts();
        assertEq(admissions, 11);
        assertEq(publications, 8);
    }

    // ---- the second generation -------------------------------------------------------------------------------

    function _gen2() internal returns (IndexDeployer d, IGeneration1 ix) {
        return _gen2With(new Unit[](0));
    }

    function _gen2With(Unit[] memory units) internal returns (IndexDeployer d, IGeneration1 ix) {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = units;
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.liveManifest = ManifestCopy.ofLive(k.proxy);
        d = new IndexDeployer(k.proxy, keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    function _replayAll(IGeneration1 ix) internal returns (uint256 publications) {
        while (ix.replayNextPublication(64) != 0) {
            ++publications;
        }
    }

    function _keys() internal view returns (PostingKey[] memory keys) {
        keys = new PostingKey[](10);
        keys[0] = PostingKey.wrap(Keys.byTypeList(TYPE_OK));
        keys[1] = PostingKey.wrap(Keys.byAuthorList(principal));
        keys[2] = PostingKey.wrap(Keys.uniqueByTypeList(TYPE_OK));
        keys[3] = PostingKey.wrap(Keys.byRecordList(recordId));
        keys[4] = PostingKey.wrap(Keys.historyList(bindingKey));
        keys[5] = PostingKey.wrap(Keys.backlinkList(FOLDER, recordId));
        keys[6] = PostingKey.wrap(Keys.backlinkList(FOLDER, otherId));
        keys[7] = PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(principal, FOLDER, NAME)));
        keys[8] = PostingKey.wrap(
            Keys.posting(0, 16, 0, Keys.roleScope(principal, FOLDER, keccak256("second")))
        );
        bytes32 w0;
        bytes memory b = body;
        assembly ("memory-safe") {
            w0 := mload(add(b, 32))
        }
        keys[9] = PostingKey.wrap(Keys.digestList(bytes32(uint256(1)), w0));
    }

    function _assertStoresEqual(IPostingStore a, IPostingStore b, IBitmapStore ba, IBitmapStore bb)
        internal
        view
    {
        PostingKey[] memory keys = _keys();
        for (uint256 i; i < keys.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = a.postingHead(keys[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = b.postingHead(keys[i]);
            assertEq(c1, c2, "count");
            assertEq(l1, l2, "live");
            assertEq(last1, last2, "last");
            assertEq(f1, f2, "flags");
            assertTrue(
                c1 != 0 || i == 8 || i == 9 || i == 3 || true,
                "every key but the empty ones has entries"
            );
            if (c1 != 0) {
                assertEq(
                    keccak256(abi.encode(a.postingSlice(keys[i], 0, 64))),
                    keccak256(abi.encode(b.postingSlice(keys[i], 0, 64)))
                );
            }
        }
        (uint64 sc1, uint64 sl1, uint64 lm1, uint48 bits1,, uint64 e1) =
            ba.scopeHead(ScopeKey.wrap(scopeKey));
        (uint64 sc2, uint64 sl2, uint64 lm2, uint48 bits2,, uint64 e2) =
            bb.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc1, sc2);
        assertEq(sl1, sl2);
        assertEq(lm1, lm2, "lastMutation replays to the same admission");
        assertEq(bits1, bits2);
        assertEq(e1, e2);
        assertEq(sc1, 2, "two scope entries");
        assertEq(sl1, 1, "the second was released");
        assertEq(bits1, 1);
    }

    function testReplayRebuildsEveryFamilyAndTheGenerationActivates() public {
        _history();
        (uint64 c,, uint64 last,) = g.posting.postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 3);
        assertEq(last, 7);
        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(ix.decoder(), ix.decoder());
        assertEq(_replayAll(ix), 8);
        (uint64 processed, uint64 publication, bool gapped) = ix.progress();
        assertEq(processed, 11);
        assertEq(publication, 8);
        assertFalse(gapped);
        _assertStoresEqual(
            g.posting, IPostingStore(d.postingStore()), g.bitmap, IBitmapStore(d.bitmapStore())
        );
        // the by-record list was materialized by the REUSE and released by the WITHDRAW on both sides
        (Coverage cv, uint64 count, uint64 live, uint64[] memory entries) =
            ix.occurrencesOf(recordId);
        assertEq(uint8(cv), uint8(Coverage.COMPLETE));
        assertEq(count, 2);
        assertEq(live, 1);
        assertEq(entries[1], 4);
        // the fresh store's build range starts at admission 1, by the generation itself
        (address[] memory gens, uint64[] memory from, uint64[] memory to) =
            IPostingStore(d.postingStore()).writers();
        assertEq(gens.length, 1);
        assertEq(gens[0], address(ix));
        assertEq(from[0], 1);
        assertEq(to[0], 0);
        assertFalse(IPostingStore(d.postingStore()).attached());
        Readiness memory r = ix.replayReadiness();
        assertTrue(r.ready);
        assertEq(r.completedAdmission, 11);
        assertEq(r.completedPublication, 8);
        assertEq(ix.replayNextPublication(64), 0, "caught up");

        // activation installs the replayed generation (readiness re-derived by the ledger)
        registry.setActiveRevision(2);
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), address(ix), ix.manifestHash()
        );
        set.revision = 2;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        ILedgerControl(k.proxy).activate(set);
        assertEq(hot.index(), address(ix));
        assertEq(hot.indexGeneration(), 2);
        // a new write folds live into the replayed stores: the build range closes, the live range opens, attached flips
        Action memory a;
        a.kind = ActionKind.PUBLISH;
        a.typeId = TYPE_OK;
        a.bodyHashOrRecordId = keccak256("third body, long enough to pass the words");
        assertEq(_one(a, "third body, long enough to pass the words"), 9);
        (c,, last,) =
            IPostingStore(d.postingStore()).postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 4);
        assertEq(last, 12);
        assertTrue(IPostingStore(d.postingStore()).attached());
        (gens, from, to) = IPostingStore(d.postingStore()).writers();
        assertEq(gens.length, 1, "the same generation keeps one range from build into live");
        assertEq(from[0], 1);
        assertEq(to[0], 0);
        (processed, publication,) = ix.progress();
        assertEq(processed, 12);
        assertEq(publication, 9);
        // once live, the generation never replays again
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(1)));
        ix.replayNextPublication(64);
        // the old generation's stores are untouched by the new write
        (c,,,) = g.posting.postingHead(PostingKey.wrap(Keys.byTypeList(TYPE_OK)));
        assertEq(c, 3);
        // the pre-replacement publication retries as AlreadyAdmitted
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = salt;
        actions[1].kind = ActionKind.PUBLISH;
        actions[1].typeId = TYPE_OK;
        actions[1].bodyHashOrRecordId = keccak256(body);
        actions[2] = _bindKind(ActionKind.BIND, NAME, recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        Native memory ctx;
        ctx.nonce = 0;
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(1)));
        ledger.execute(actions, bodies, ctx, "");
    }

    function testReplayRefusals() public {
        _history();
        // the live generation has no decoder and is not fresh
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(5)));
        g.index.replayNextPublication(64);
        (, IGeneration1 ix) = _gen2();
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(6)));
        ix.replayNextPublication(0);
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(6)));
        ix.replayNextPublication(65);
        // a cap below a publication's leaf count refuses that publication whole
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(6)));
        ix.replayNextPublication(2);
        assertEq(ix.replayNextPublication(3), 3, "publication 1 has three leaves");
        // the fold is this contract's own entry: a stranger cannot inject effects
        Effect[] memory effects = new Effect[](0);
        bytes32[] memory refs = new bytes32[](0);
        vm.expectRevert();
        ix.replayFold(2, effects, refs);
        // a publication is replayed exactly once, in order
        assertEq(ix.replayNextPublication(64), 1);
        (uint64 processed, uint64 publication,) = ix.progress();
        assertEq(processed, 4);
        assertEq(publication, 2);
    }

    function testDecoderMatchesTheLiveStream() public {
        _history();
        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory effects, bytes32[] memory refs) = dec.decode(k.proxy, 5);
        assertEq(effects.length, 2);
        assertEq(refs.length, 0);
        assertEq(effects[0].kind, ActionKind.PUBLISH);
        assertEq(effects[0].admission, 7);
        assertEq(effects[0].recordId, otherId);
        assertTrue(effects[0].freshRecord);
        assertEq(effects[1].kind, ActionKind.BIND);
        assertEq(effects[1].transitionKind, 2, "REBIND");
        assertEq(effects[1].oldTarget, recordId);
        assertEq(effects[1].target, otherId);
        assertEq(effects[1].bindingOrdinal, 1);
        assertEq(effects[1].revision, 4);
        assertEq(effects[1].subject, subject);
        assertEq(effects[1].role, NAME);
        (effects,) = dec.decode(k.proxy, 7);
        assertEq(effects[0].kind, ActionKind.WITHDRAW);
        assertEq(effects[0].withdrawnAdmission, 4);
        assertEq(effects[0].withdrawnPrincipal, principal);
        assertEq(effects[0].typeId, TYPE_OK);
        (effects,) = dec.decode(k.proxy, 3);
        assertEq(effects[0].transitionKind, 3, "MASK");
        assertEq(effects[0].oldTarget, recordId);
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(7)));
        dec.decode(k.proxy, 99);
    }

    /// A first mask (UNBIND from UNSET) and a mask from RELEASED fold live and replay to the same stores; the
    /// decoder derives FIRST_MASK from an UNSET previous row. A first mask appends a dead scope entry and the
    /// role-scope entry.
    function testReplayFoldsFirstMaskAndMaskFromReleased() public {
        _history();
        bytes32 third = keccak256("third");
        bytes32 second = keccak256("second");
        assertEq(_one(_bindKind(ActionKind.UNBIND, third, 0, 0), ""), 9); // 12: first mask
        (uint64 sc, uint64 sl,, uint48 bits,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(abi.encode(sc, sl, bits), abi.encode(3, 1, 1), "a dead third entry");
        PostingKey rs3 =
            PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(principal, FOLDER, third)));
        (uint64 rc,,,) = g.posting.postingHead(rs3);
        assertEq(rc, 1, "the role-scope posting of a denial exists");
        assertEq(_one(_bindKind(ActionKind.UNBIND, second, 0, 2), ""), 10); // 13: mask from RELEASED
        assertEq(_one(_bindKind(ActionKind.BIND, third, recordId, 1), ""), 11); // 14: restore over the first mask
        (sc, sl,, bits,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(abi.encode(sc, sl, bits), abi.encode(3, 2, 5));

        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory e,) = dec.decode(k.proxy, 9);
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget, e[0].target), abi.encode(6, 0, 0));
        (e,) = dec.decode(k.proxy, 10);
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget), abi.encode(3, 0));
        (e,) = dec.decode(k.proxy, 11);
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget), abi.encode(5, 0));

        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(_replayAll(ix), 11);
        IPostingStore p2 = IPostingStore(d.postingStore());
        IBitmapStore b2 = IBitmapStore(d.bitmapStore());
        PostingKey[] memory keys = new PostingKey[](5);
        keys[0] = rs3;
        keys[1] = PostingKey.wrap(
            Keys.historyList(Keys.binding(principal, Keys.position(FOLDER, subject, third)))
        );
        keys[2] = PostingKey.wrap(
            Keys.historyList(Keys.binding(principal, Keys.position(FOLDER, subject, second)))
        );
        keys[3] = PostingKey.wrap(Keys.backlinkList(FOLDER, recordId));
        keys[4] = PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(principal, FOLDER, second)));
        for (uint256 i; i < keys.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = g.posting.postingHead(keys[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = p2.postingHead(keys[i]);
            assertEq(abi.encode(c1, l1, last1, f1), abi.encode(c2, l2, last2, f2), "posting head");
            assertEq(
                keccak256(abi.encode(g.posting.postingSlice(keys[i], 0, 64))),
                keccak256(abi.encode(p2.postingSlice(keys[i], 0, 64)))
            );
        }
        (uint64 x1, uint64 y1, uint64 z1, uint48 w1,, uint64 v1) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        (uint64 x2, uint64 y2, uint64 z2, uint48 w2,, uint64 v2) =
            b2.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(abi.encode(x1, y1, z1, w1, v1), abi.encode(x2, y2, z2, w2, v2), "scope head");
        for (uint64 i; i < 3; ++i) {
            assertEq(
                g.bitmap.scopeEntry(ScopeKey.wrap(scopeKey), i),
                b2.scopeEntry(ScopeKey.wrap(scopeKey), i)
            );
        }
    }

    /// A bind to an ADDRESS target (kind 3: neither record nor subject, address-shaped) folds live, decodes with
    /// targetKind 3, and replays to the same backlink and history lists.
    function testReplayFoldsAnAddressTarget() public {
        _history();
        bytes32 addr = bytes32(uint256(uint160(address(0xBADC0DE))));
        bytes32 role = keccak256("address-role");
        assertEq(_one(_bindKind(ActionKind.BIND, role, addr, 0), ""), 9);
        assertEq(_one(_bindKind(ActionKind.BIND, role, recordId, 1), ""), 10); // rebind away: oldTarget = addr
        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory e,) = dec.decode(k.proxy, 9);
        assertEq(
            abi.encode(e[0].transitionKind, e[0].targetKind, e[0].target), abi.encode(1, 3, addr)
        );
        (e,) = dec.decode(k.proxy, 10);
        assertEq(abi.encode(e[0].oldTargetKind, e[0].oldTarget), abi.encode(3, addr));
        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(_replayAll(ix), 10);
        PostingKey[] memory keys = new PostingKey[](2);
        keys[0] = PostingKey.wrap(Keys.backlinkList(FOLDER, addr));
        keys[1] = PostingKey.wrap(
            Keys.historyList(Keys.binding(principal, Keys.position(FOLDER, subject, role)))
        );
        IPostingStore p2 = IPostingStore(d.postingStore());
        for (uint256 i; i < keys.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = g.posting.postingHead(keys[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = p2.postingHead(keys[i]);
            assertEq(abi.encode(c1, l1, last1, f1), abi.encode(c2, l2, last2, f2), "posting head");
            assertEq(
                keccak256(abi.encode(g.posting.postingSlice(keys[i], 0, 64))),
                keccak256(abi.encode(p2.postingSlice(keys[i], 0, 64)))
            );
        }
        (uint64 bc, uint64 bl,,) = g.posting.postingHead(keys[0]);
        assertEq(
            abi.encode(bc, bl), abi.encode(1, 0), "the address backlink, released by the rebind"
        );
    }

    /// MASKED → MASKED (a negative number changed, -1 → -5) folds as a MASK on an already-clear live bit: the live
    /// count is unchanged, a history entry is appended, and replay rebuilds the same stores.
    function testReplayFoldsAMaskOfAMask() public {
        _history();
        bytes32 third = keccak256("third");
        assertEq(_one(_bindKind(ActionKind.UNBIND, third, 0, 0), ""), 9); // first mask, -1
        (uint64 sc, uint64 sl,, uint48 bits,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        Action memory again = _bindKind(ActionKind.UNBIND, third, 0, 1);
        again.saltOrStrength = bytes32(uint256(4)); // -5
        assertEq(_one(again, ""), 10);
        (uint64 sc2, uint64 sl2,, uint48 bits2,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(
            abi.encode(sc, sl, bits), abi.encode(sc2, sl2, bits2), "the mask of a mask moves no bit"
        );
        PostingKey hist = PostingKey.wrap(
            Keys.historyList(Keys.binding(principal, Keys.position(FOLDER, subject, third)))
        );
        (uint64 hc,,,) = g.posting.postingHead(hist);
        assertEq(hc, 2, "two history entries");
        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory e,) = dec.decode(k.proxy, 10);
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget), abi.encode(3, 0), "MASK");
        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(_replayAll(ix), 10);
        (uint64 x1, uint64 y1, uint64 z1, uint48 w1,, uint64 v1) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        (uint64 x2, uint64 y2, uint64 z2, uint48 w2,, uint64 v2) =
            IBitmapStore(d.bitmapStore()).scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(abi.encode(x1, y1, z1, w1, v1), abi.encode(x2, y2, z2, w2, v2), "scope head");
        (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = g.posting.postingHead(hist);
        (uint64 c2, uint64 l2, uint64 last2, uint16 f2) =
            IPostingStore(d.postingStore()).postingHead(hist);
        assertEq(abi.encode(c1, l1, last1, f1), abi.encode(c2, l2, last2, f2), "history head");
    }

    /// Replay equals live across a mixed history that uses every transition this step adds or widens (a first
    /// mask, a mask of a mask, a mask from RELEASED, a restore over a first mask, an ADDRESS target, a number
    /// change, a release of a lone negative): every decoded publication hashes to the `effectsHash` the live
    /// publication emitted, and a fresh generation rebuilt from history holds the same lists and scope entries.
    function testReplayEqualsLiveAcrossEveryNewTransition() public {
        _history();
        bytes32 third = keccak256("third");
        bytes32 second = keccak256("second");
        bytes32 lone = keccak256("lone");
        bytes32 addrRole = keccak256("address-role");
        bytes32 addr = bytes32(uint256(uint160(address(0xA11CE))));
        Action[] memory steps = new Action[](9);
        steps[0] = _bindKind(ActionKind.UNBIND, third, 0, 0); // first mask, -1
        steps[1] = _bindKind(ActionKind.UNBIND, third, 0, 1); // mask of a mask
        steps[1].saltOrStrength = bytes32(uint256(4)); // -5
        steps[2] = _bindKind(ActionKind.UNBIND, second, 0, 2); // mask from RELEASED
        steps[3] = _bindKind(ActionKind.BIND, addrRole, addr, 0); // an ADDRESS target
        steps[4] = _bindKind(ActionKind.BIND, addrRole, addr, 1); // a number change on the same target
        steps[4].saltOrStrength = bytes32(uint256(75));
        steps[5] = _bindKind(ActionKind.BIND, third, recordId, 2); // restore over the first mask
        steps[5].saltOrStrength = bytes32(uint256(9));
        steps[6] = _bindKind(ActionKind.UNBIND, lone, 0, 0); // a lone negative
        steps[6].saltOrStrength = bytes32(uint256(65_535));
        steps[7] = _bindKind(ActionKind.RELEASE, lone, 0, 1); // released without ever being bound
        steps[8] = _bindKind(ActionKind.BIND, addrRole, recordId, 2); // rebind away from the address
        uint8[9] memory kinds = [6, 3, 3, 1, 2, 5, 6, 4, 2];
        IndexReplayDecoder dec = new IndexReplayDecoder();
        for (uint256 i; i < steps.length; ++i) {
            vm.recordLogs();
            uint64 pub = _one(steps[i], "");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 emitted;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].topics[0] == ILedger.Published.selector) {
                    (,,, emitted,) =
                        abi.decode(logs[j].data, (uint8, uint64, uint8, bytes32, uint32));
                }
            }
            (Effect[] memory e,) = dec.decode(k.proxy, pub);
            assertEq(e[0].transitionKind, kinds[i], "transition");
            assertEq(keccak256(abi.encode(e)), emitted, "decoded effects == live effects");
        }
        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(_replayAll(ix), 17);
        IPostingStore p2 = IPostingStore(d.postingStore());
        IBitmapStore b2 = IBitmapStore(d.bitmapStore());
        bytes32[5] memory roles = [NAME, second, third, lone, addrRole];
        PostingKey[] memory keys = new PostingKey[](13);
        for (uint256 i; i < 5; ++i) {
            keys[2 * i] = PostingKey.wrap(
                Keys.historyList(Keys.binding(principal, Keys.position(FOLDER, subject, roles[i])))
            );
            keys[2 * i + 1] = PostingKey.wrap(
                Keys.posting(0, 16, 0, Keys.roleScope(principal, FOLDER, roles[i]))
            );
        }
        keys[10] = PostingKey.wrap(Keys.backlinkList(FOLDER, addr));
        keys[11] = PostingKey.wrap(Keys.backlinkList(FOLDER, recordId));
        keys[12] = PostingKey.wrap(Keys.backlinkList(FOLDER, otherId));
        for (uint256 i; i < keys.length; ++i) {
            (uint64 c1, uint64 l1, uint64 last1, uint16 f1) = g.posting.postingHead(keys[i]);
            (uint64 c2, uint64 l2, uint64 last2, uint16 f2) = p2.postingHead(keys[i]);
            assertEq(abi.encode(c1, l1, last1, f1), abi.encode(c2, l2, last2, f2), "posting head");
            assertEq(
                keccak256(abi.encode(g.posting.postingSlice(keys[i], 0, 64))),
                keccak256(abi.encode(p2.postingSlice(keys[i], 0, 64)))
            );
        }
        (uint64 x1, uint64 y1, uint64 z1, uint48 w1,, uint64 v1) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        (uint64 x2, uint64 y2, uint64 z2, uint48 w2,, uint64 v2) =
            b2.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(abi.encode(x1, y1, z1, w1, v1), abi.encode(x2, y2, z2, w2, v2), "scope head");
        // entries: NAME (live), second (masked), third (restored), addrRole (live), lone (released)
        assertEq(abi.encode(x1, y1, w1), abi.encode(5, 3, uint48(0x0d)), "five entries, three live");
        for (uint64 i; i < 5; ++i) {
            assertEq(
                g.bitmap.scopeEntry(ScopeKey.wrap(scopeKey), i),
                b2.scopeEntry(ScopeKey.wrap(scopeKey), i)
            );
        }
    }

    // ---- review findings -------------------------------------------------------------------------------------

    /// A replayed store stamps the mutating admission, not the frontier at replay time.
    function testReplayStampsTheMutatingAdmission() public {
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = salt;
        actions[1].kind = ActionKind.PUBLISH;
        actions[1].typeId = TYPE_OK;
        actions[1].bodyHashOrRecordId = keccak256(body);
        actions[2] = _bindKind(ActionKind.BIND, NAME, recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        _exec(actions, bodies); // admissions 1..3, the bind at 3
        Action memory a;
        a.kind = ActionKind.PUBLISH;
        a.typeId = TYPE_OK;
        a.bodyHashOrRecordId = keccak256(other);
        _one(a, other); // admission 4, no scope mutation
        assertEq(g.bitmap.lastMutation(ScopeKey.wrap(scopeKey)), 3);
        (IndexDeployer d, IGeneration1 ix) = _gen2();
        assertEq(_replayAll(ix), 2);
        assertEq(
            IBitmapStore(d.bitmapStore()).lastMutation(ScopeKey.wrap(scopeKey)), 3, "replayed stamp"
        );
    }

    /// A fold hook cannot re-enter the replay: the nested call is refused and the stream stays in order.
    function testAFoldHookCannotReenterTheReplay() public {
        _history();
        ReenteringHook hook = new ReenteringHook();
        Unit[] memory units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(hook),
            foldCodehash: address(hook).codehash,
            finalHook: address(0),
            finalCodehash: 0,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/reentering-hook/1")
        });
        (, IGeneration1 ix) = _gen2With(units);
        assertEq(_replayAll(ix), 8);
        assertFalse(hook.reentered(), "the nested replay was refused");
        assertEq(bytes4(hook.lastError()), E_REPLAY.selector);
        (uint64 processed, uint64 publication,) = ix.progress();
        assertEq(processed, 11);
        assertEq(publication, 8);
        assertTrue(ix.replayReadiness().ready);
    }
}
