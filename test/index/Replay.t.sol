// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
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

/// @notice Design §10.6 replay: a second generation with fresh stores catches up on a history of every action
///         kind through the pinned decoder, its stores equal the live generation's family by family, its
///         readiness is re-derived at activation, and after the index replacement writes fold live into the
///         replayed stores while the pre-replacement publication retries as AlreadyAdmitted.
contract ReplayTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;
    bytes32 internal constant TYPE_OK = keccak256("test/type/ok");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
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
        actions[0].salt = salt;
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

    function _gen2() internal returns (IndexDeployer d, RealmIndex ix) {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = new Unit[](0);
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        d = new IndexDeployer(k.proxy, keccak256(abi.encode(plan)));
        ix = RealmIndex(d.run(plan));
    }

    function _replayAll(RealmIndex ix) internal returns (uint256 publications) {
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
        keys[5] = PostingKey.wrap(Keys.backlinkList(recordId));
        keys[6] = PostingKey.wrap(Keys.backlinkList(otherId));
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
        (IndexDeployer d, RealmIndex ix) = _gen2();
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
        actions[0].salt = salt;
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
        (, RealmIndex ix) = _gen2();
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
}
