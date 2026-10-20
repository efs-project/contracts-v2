// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {BaseIndexDouble, IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {RealmController} from "../../src/control/RealmController.sol";
import {RealmGenesis} from "../../src/control/RealmGenesis.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
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
import {ITypeRegistry} from "../../src/interfaces/ITypeRegistry.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {DigestSpec, Effect, FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {
    E_BACKFILL,
    E_BUILD,
    E_NOT_IDLE,
    E_PUBLICATION_ACTIVE,
    E_REPLAY,
    E_WRITER
} from "../../src/interfaces/Errors.sol";

/// @notice The relay a callback re-enters through: calls `target` (as `as_` when nonzero, otherwise as the test
///         contract, which owns the controller), bubbles a refusal verbatim and turns a success into `Bypassed`.
interface IRelay {
    function relay(address target, bytes calldata data, address as_) external;
}

/// @notice A live index whose prefix callback (CALL, phase APPLYING) re-enters every gated entry the test
///         lists through the relay and records each attempt's revert data (`"BYPASSED"` when one succeeded).
///         It then acknowledges honestly, so the outer publication lands and the records survive.
contract ReenteringIndex is BaseIndexDouble {
    struct Attempt {
        address target;
        bytes data;
        address as_;
    }

    IRelay public immutable RELAY;
    Attempt[] internal _attempts;
    bytes[] internal _results;

    constructor(address ledger_, IRelay relay_) BaseIndexDouble(ledger_) {
        RELAY = relay_;
    }

    function add(address target, bytes calldata data, address as_) external onlyOwner {
        _attempts.push(Attempt(target, data, as_));
    }

    function results() external view returns (bytes[] memory) {
        return _results;
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        for (uint256 i; i < _attempts.length; ++i) {
            Attempt storage a = _attempts[i];
            try RELAY.relay(a.target, a.data, a.as_) {
                _results.push(bytes("BYPASSED"));
            } catch (bytes memory err) {
                _results.push(err);
            }
        }
        return super.onAdmission(publication, effects, refs);
    }
}

/// @notice §2.2 S1 — reentrancy from an index callback into every gated entry the existing suites do not reach
///         with a real callback: the `RealmController` activation family (`activate`, `freeze`, `migrate`,
///         `acceptOwnershipAndActivate`, transitions, `activatePolicy`, `declareRoleExpectation`,
///         `activateWrapper`), the ledger's and the registry's own gates behind it (called as the controller),
///         a candidate generation's `replayNextPublication`/`build`/`backfill`, its fresh stores written as a
///         stranger and as their INITIAL_WRITER, and the write lane. Every attempt is refused by the transient
///         lock read through `phase()` and nothing it could have changed moves. Re-entry into the ledger's
///         `activate`/`beginTransition`/`abortTransition`/`execute` with the test contract as controller is
///         `test/integration/atomicity/Ordered.t.sol::test_callbacks_cannot_reenter_writes_or_configuration`;
///         an acceptor re-entering is `test/unit/ingress/Acceptors.t.sol::test_reentrant_acceptor_is_refused_and_the_publication_lands`.
contract ReentrancyTest is Test, IRelay {
    error Bypassed();

    bytes32 internal constant NOTICE = keccak256("efs2/test/security/reentrancy/notice");

    KernelDeploy.Kernel internal k;
    TypeRegistry internal registryImpl;
    TypeRegistry internal registry;
    RealmController internal controller;
    ReenteringIndex internal attack;
    ILedger internal ledger;
    ILedgerHot internal hot;
    RealmIndex internal candidate;
    PostingStore internal candidatePosting;
    BitmapStore internal candidateBitmap;

    function relay(address target, bytes calldata data, address as_) external {
        if (as_ != address(0)) vm.prank(as_);
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) revert Bypassed();
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    function setUp() public {
        k = KernelDeploy.deployImplementations();
        registryImpl = new TypeRegistry(address(new DescriptorStore()));
        Limits memory limits = KernelDeploy.s1Limits();
        RealmGenesis genesis = new RealmGenesis(
            address(this),
            address(k.implementation),
            address(registryImpl),
            keccak256("efs2/test/security/reentrancy/salt"),
            1,
            keccak256(abi.encode(limits)),
            address(0),
            address(0),
            NOTICE,
            keccak256(type(RealmController).creationCode),
            keccak256(type(TransparentUpgradeableProxy).creationCode)
        );
        genesis.run(
            limits,
            type(RealmController).creationCode,
            type(TransparentUpgradeableProxy).creationCode
        );
        controller = RealmController(genesis.controller());
        registry = TypeRegistry(genesis.registryProxy());
        k.proxy = genesis.ledgerProxy();
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        attack = new ReenteringIndex(k.proxy, this);
        Readiness memory r;
        r.version = 1;
        r.ledger = k.proxy;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = KernelDeploy.HOT_ABI_ID;
        r.manifestHash = attack.manifestHash();
        r.provenFrom = 1;
        r.ready = true;
        r.units = new Unit[](0);
        r.families = new FamilyEntry[](0);
        attack.setReadiness(r);
        controller.activate(_set(1, address(controller)));
        _deployCandidate();
    }

    function _set(uint32 revision, address ctl) internal view returns (ActivationSet memory set) {
        set = KernelDeploy.genesisSet(
            k, ctl, address(this), address(registryImpl), address(attack), attack.manifestHash()
        );
        set.revision = revision;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }

    /// A later generation with fresh stores naming it as INITIAL_WRITER (design §10.1), plus a decoder.
    function _deployCandidate() internal {
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
        IndexDeployer d = new IndexDeployer(k.proxy, keccak256(abi.encode(plan)));
        candidate = RealmIndex(d.run(plan));
        candidatePosting = PostingStore(d.postingStore());
        candidateBitmap = BitmapStore(d.bitmapStore());
    }

    function _err(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    function _add(address target, bytes memory data, address as_, bytes memory expected)
        internal
        returns (bytes memory)
    {
        attack.add(target, data, as_);
        return expected;
    }

    function test_index_callback_cannot_reenter_controller_registry_replay_build_backfill_or_stores()
        public
    {
        ActivationSet memory next = _set(2, address(controller));
        ActivationSet memory terminal = _set(2, address(controller));
        terminal.dependencyRoot = keccak256("efs2/test/security/reentrancy/dependency-root");
        terminal.expectedExecutionSet = ExecutionSets.executionSet(terminal, k.proxy);
        RealmController successor =
            new RealmController(address(this), k.proxy, address(registry), NOTICE);
        ActivationSet memory migration = _set(2, address(successor));
        controller.transferOwnership(address(this)); // so acceptOwnershipAndActivate reaches its body
        bytes32 typeId = keccak256("efs2/test/security/reentrancy/type");
        address wrapper = address(new AcceptAll());
        bytes32 roster = Keys.familyId("roster");
        bytes32 byAuthor = Keys.familyId("by-author");
        bytes memory active = _err(E_PUBLICATION_ACTIVE.selector);
        bytes memory notIdle = _err(E_NOT_IDLE.selector);
        address c = address(controller);
        address cand = address(candidate);

        bytes[] memory expected = new bytes[](18);
        // the controller's own idle gate (§8.3 step 1) refuses its activation family ...
        expected[0] = _add(c, abi.encodeCall(RealmController.activate, (next)), address(0), notIdle);
        expected[1] = _add(
            c,
            abi.encodeCall(RealmController.freeze, (terminal, new bytes[](0))),
            address(0),
            notIdle
        );
        expected[2] = _add(
            c,
            abi.encodeCall(RealmController.migrate, (address(successor), migration)),
            address(0),
            notIdle
        );
        expected[3] = _add(
            c,
            abi.encodeCall(RealmController.acceptOwnershipAndActivate, (next)),
            address(0),
            notIdle
        );
        // ... and passes the rest to gates that read the lock: the ledger's transitions, the registry's rows
        expected[4] = _add(
            c,
            abi.encodeCall(RealmController.beginTransition, (2, uint48(block.number + 10))),
            address(0),
            active
        );
        expected[5] =
            _add(c, abi.encodeCall(RealmController.abortTransition, ()), address(0), active);
        expected[6] = _add(
            c,
            abi.encodeCall(RealmController.activatePolicy, (typeId, address(0))),
            address(0),
            active
        );
        expected[7] = _add(
            c,
            abi.encodeCall(
                RealmController.declareRoleExpectation, (keccak256("purpose"), "role", typeId)
            ),
            address(0),
            active
        );
        expected[8] = _add(
            c, abi.encodeCall(RealmController.activateWrapper, (2, wrapper)), address(0), active
        );
        // the inner gates, called as the controller itself (defence in depth behind the controller's gate)
        expected[9] = _add(k.proxy, abi.encodeCall(ILedgerControl.activate, (next)), c, active);
        expected[10] = _add(k.proxy, abi.encodeCall(ILedgerControl.freeze, (terminal)), c, active);
        expected[11] =
            _add(address(registry), abi.encodeCall(ITypeRegistry.activate, (2)), c, active);
        // a candidate generation: replay is idle-gated; build/backfill are not implemented at S1 and refuse
        // unconditionally (src/index/RealmIndex.sol:460-467)
        expected[12] = _add(
            cand,
            abi.encodeCall(IRealmIndex.replayNextPublication, (64)),
            address(0),
            abi.encodeWithSelector(E_REPLAY.selector, uint8(3))
        );
        expected[13] = _add(
            cand,
            abi.encodeCall(IRealmIndex.build, (byAuthor, 64)),
            address(0),
            abi.encodeWithSelector(E_BUILD.selector, uint8(0))
        );
        expected[14] = _add(
            cand,
            abi.encodeCall(IRealmIndex.backfill, (roster, ScopeKey.wrap(0), 0, 64)),
            address(0),
            abi.encodeWithSelector(E_BACKFILL.selector, uint8(0))
        );
        // its fresh stores, pre-written mid-publication by a stranger and by their own INITIAL_WRITER
        bytes memory append = abi.encodeCall(
            PostingStore.append,
            (FamilyId.wrap(byAuthor), PostingKey.wrap(keccak256("squat")), 1, 0)
        );
        expected[15] = _add(
            address(candidatePosting),
            append,
            address(0),
            abi.encodeWithSelector(E_WRITER.selector, address(this))
        );
        expected[16] = _add(
            address(candidatePosting), append, cand, abi.encodeWithSelector(E_WRITER.selector, cand)
        );
        expected[17] = _add(
            address(candidateBitmap),
            abi.encodeCall(
                BitmapStore.setBit, (FamilyId.wrap(roster), ScopeKey.wrap(keccak256("s")), 0, true)
            ),
            cand,
            abi.encodeWithSelector(E_WRITER.selector, cand)
        );

        uint64 mutations = registry.mutations();
        bytes32 es = hot.executionSet();
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.CREATE;
        actions[0].salt = keccak256("efs2/test/security/reentrancy/outer");
        Native memory ctx;
        (uint64 publication,) = ledger.execute(actions, new bytes[](1), ctx, "");
        assertEq(publication, 1, "the outer publication landed");

        bytes[] memory got = attack.results();
        assertEq(got.length, expected.length);
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], expected[i], vm.toString(i));
        }
        // nothing the attempts reach moved
        assertEq(abi.encode(hot.revision(), hot.executionSet()), abi.encode(uint32(1), es));
        assertEq(
            abi.encode(registry.activeRevision(), registry.mutations()), abi.encode(1, mutations)
        );
        assertEq(hot.controller(), c);
        assertEq(
            abi.encode(controller.owner(), controller.retired()), abi.encode(address(this), false)
        );
        assertEq(
            hot.extsload(bytes32(Layout.LEDGER_REALM_TRANSITIONTARGET_SLOT)),
            bytes32(0),
            "no transition opened"
        );
        (uint64 processed, uint64 replayed,) = candidate.progress();
        assertEq(abi.encode(processed, replayed), abi.encode(0, 0));
        assertFalse(candidatePosting.attached());
        assertFalse(candidateBitmap.attached());
        (address[] memory w,,) = candidatePosting.writers();
        assertEq(w.length, 0, "no build range was opened");
        // after the publication the same calls are reachable again (the lock was the only refusal)
        assertEq(candidate.replayNextPublication(64), 1, "replay runs once idle");
    }
}
