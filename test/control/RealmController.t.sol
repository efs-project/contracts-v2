// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {Descriptors} from "../harness/Descriptors.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {AcceptAll, RejectAll} from "../harness/doubles/Acceptors.sol";
import {RealmController} from "../../src/control/RealmController.sol";
import {RealmGenesis} from "../../src/control/RealmGenesis.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {DescribedCodec} from "../../src/types/DescribedCodec.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Capability, Intent, Native} from "../../src/interfaces/Actions.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {ClosureConstants, Limits} from "../../src/interfaces/Limits.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {IRealmController} from "../../src/interfaces/IRealmController.sol";
import {
    E_CANARY,
    E_CONTROLLER,
    E_VERIFIER_PROFILE,
    E_FREEZE_PRECHECK,
    E_FROZEN,
    E_GENESIS,
    E_NOT_OWNER,
    E_PENDING,
    E_RETIRED,
    E_SUCCESSOR
} from "../../src/interfaces/Errors.sol";

/// @notice The control plane end to end: RealmGenesis creates the controller and both proxies by its nonces,
///         the controller runs the genesis activation, an owner change, a migration, transitions and the
///         freeze ceremony with its native canary, and every gate of design §5.12/§8.3–§8.5/§8.10.
contract RealmControllerTest is Test {
    using Descriptors for Descriptors.Params;

    KernelDeploy.Kernel internal k;
    IndexDeploy.Gen1 internal g;
    DescriptorStore internal store;
    TypeRegistry internal registryImpl;
    TypeRegistry internal registry;
    RealmGenesis internal genesis;
    RealmController internal controller;
    ILedger internal ledger;
    ILedgerHot internal hot;
    Limits internal limits;
    uint256 internal constant PK = 0xA11CE;
    address internal key;
    address internal instance;
    bytes32 internal initcodeHash;
    bytes32 internal noticeType;
    bytes internal noticeDescriptor;
    address internal constant STRANGER = address(0xBEEF);

    function setUp() public {
        k = KernelDeploy.deployImplementations();
        store = new DescriptorStore();
        registryImpl = new TypeRegistry(address(store));
        limits = KernelDeploy.s1Limits();
        key = vm.addr(PK);
        // the notice Type's id is known before genesis: it is deterministic in its descriptor
        bytes memory initcode = type(AcceptAll).creationCode;
        initcodeHash = keccak256(initcode);
        instance = Factory.deploy(initcode);
        noticeDescriptor = Descriptors.defaults(3, key, instance.codehash, initcodeHash).encode();
        (, bytes32[] memory refs) = this.parse(noticeDescriptor);
        noticeType = Keys.typeId(
            keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, noticeDescriptor)),
            refs,
            instance.codehash
        );
        genesis = new RealmGenesis(
            address(this),
            address(k.implementation),
            address(registryImpl),
            keccak256("realm-salt"),
            1,
            keccak256(abi.encode(limits)),
            address(0),
            address(0),
            noticeType,
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
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID);
        controller.activate(_set(1, address(controller), address(this)));
        // the notice Type is registered after genesis, permissionlessly
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, registry.declarationDigest(noticeType));
        bytes memory sig = abi.encodePacked(r, s, v);
        store.put(noticeDescriptor, sig);
        (bytes32 got,) = registry.registerDescribed(noticeDescriptor, sig, instance, "");
        assertEq(got, noticeType);
    }

    function parse(bytes calldata d)
        external
        pure
        returns (DescribedCodec.Header memory, bytes32[] memory)
    {
        return DescribedCodec.parse(d);
    }

    /// An activation set for `revision` naming `ctl` as the controller with `owner_` as its owner.
    function _set(uint32 revision, address ctl, address owner_)
        internal
        view
        returns (ActivationSet memory set)
    {
        set = KernelDeploy.genesisSet(
            k, ctl, owner_, address(registryImpl), address(g.index), g.index.manifestHash()
        );
        set.revision = revision;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }

    function _final(uint32 revision, address ctl, address owner_)
        internal
        view
        returns (ActivationSet memory set)
    {
        set = _set(revision, ctl, owner_);
        set.dependencyRoot = keccak256("dependency root");
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }

    function _publish(bytes memory body, uint64 nonce) internal returns (uint64 publication) {
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = noticeType;
        actions[0].bodyHashOrRecordId = keccak256(body);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        Native memory ctx;
        ctx.nonce = nonce;
        (publication,) = ledger.execute(actions, bodies, ctx, "");
    }

    // ---- genesis ------------------------------------------------------------------------------------------

    function testGenesisCreatesEverythingWhereItSaid() public {
        (address pc, address pr, address pl) = genesis.predict();
        assertEq(address(controller), pc);
        assertEq(address(registry), pr);
        assertEq(k.proxy, pl);
        assertEq(controller.owner(), address(this));
        assertEq(controller.ledger(), k.proxy);
        assertEq(controller.registryProxy(), address(registry));
        (address la, address ra) = controller.admins();
        assertEq(ProxyAdmin(la).owner(), address(controller));
        assertEq(ProxyAdmin(ra).owner(), address(controller));
        assertEq(hot.controller(), address(controller));
        assertEq(hot.registry(), address(registry));
        assertEq(registry.ledger(), k.proxy);
        assertEq(hot.revision(), 1);
        assertEq(registry.activeRevision(), 1);
        assertEq(controller.NOTICE_TYPE(), noticeType);
        assertFalse(controller.frozen());
        assertFalse(controller.retired());
        // single use
        vm.expectRevert(abi.encodeWithSelector(E_GENESIS.selector, uint8(0)));
        genesis.run(
            limits,
            type(RealmController).creationCode,
            type(TransparentUpgradeableProxy).creationCode
        );
        // a stranger's replay with other bytes is refused before anything is created
        RealmGenesis other = new RealmGenesis(
            address(this),
            address(k.implementation),
            address(registryImpl),
            keccak256("other"),
            1,
            keccak256(abi.encode(limits)),
            address(0),
            address(0),
            noticeType,
            keccak256(type(RealmController).creationCode),
            keccak256(type(TransparentUpgradeableProxy).creationCode)
        );
        Limits memory wrong = limits;
        wrong.maxActions += 1;
        vm.expectRevert(abi.encodeWithSelector(E_GENESIS.selector, uint8(1)));
        other.run(
            wrong,
            type(RealmController).creationCode,
            type(TransparentUpgradeableProxy).creationCode
        );
        vm.expectRevert(abi.encodeWithSelector(E_GENESIS.selector, uint8(10)));
        other.run(limits, hex"00", type(TransparentUpgradeableProxy).creationCode);
        vm.prank(STRANGER);
        other.run(
            limits,
            type(RealmController).creationCode,
            type(TransparentUpgradeableProxy).creationCode
        );
        (address pc2,,) = other.predict();
        assertEq(other.controller(), pc2);
        assertEq(
            RealmController(pc2).owner(),
            address(this),
            "the owner comes from the plan, never from msg.sender"
        );
    }

    // ---- activation gates --------------------------------------------------------------------------------

    function testActivationGates() public {
        ActivationSet memory set = _set(2, address(controller), address(this));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_OWNER.selector, STRANGER));
        controller.activate(set);
        ActivationSet memory bad = _set(2, STRANGER, address(this));
        vm.expectRevert(abi.encodeWithSelector(E_CONTROLLER.selector, uint8(1)));
        controller.activate(bad);
        bad = _set(2, address(controller), address(this));
        bad.components.controllerCodehash = keccak256("x");
        vm.expectRevert(abi.encodeWithSelector(E_CONTROLLER.selector, uint8(2)));
        controller.activate(bad);
        bad = _set(2, address(controller), STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_CONTROLLER.selector, uint8(3)));
        controller.activate(bad);
        controller.activate(set);
        assertEq(hot.revision(), 2);
        assertEq(registry.activeRevision(), 2);
        assertEq(hot.executionSet(), set.expectedExecutionSet);
    }

    function testOwnerChangeIsAnActivation() public {
        address newOwner = address(0xA55E7);
        controller.transferOwnership(newOwner);
        assertEq(controller.pendingOwner(), newOwner);
        assertEq(controller.owner(), address(this), "nothing changes until accepted");
        ActivationSet memory early = _set(2, address(controller), newOwner);
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_OWNER.selector, newOwner));
        controller.activate(early);
        // the old owner may still activate meanwhile
        controller.activate(_set(2, address(controller), address(this)));
        ActivationSet memory set = _set(3, address(controller), newOwner);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_PENDING.selector, newOwner));
        controller.acceptOwnershipAndActivate(set);
        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true);
        emit IRealmController.OwnershipActivated(address(this), newOwner, 3);
        controller.acceptOwnershipAndActivate(set);
        assertEq(controller.owner(), newOwner);
        assertEq(controller.pendingOwner(), address(0));
        assertEq(hot.revision(), 3);
        ActivationSet memory later = _set(4, address(controller), newOwner);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_OWNER.selector, address(this)));
        controller.activate(later);
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(E_PENDING.selector, address(0)));
        controller.acceptOwnershipAndActivate(set);
    }

    // ---- migrate → activate → activatePolicy → freeze through the successor ------------------------------------

    function testMigrateThenActivateThenPolicyThenFreezeThroughTheSuccessor() public {
        _publish("before", 0);
        RealmController successor =
            new RealmController(address(this), k.proxy, address(registry), noticeType);
        ActivationSet memory set = _set(2, address(successor), address(this));
        ActivationSet memory wrongOwner = _set(2, address(successor), STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(3)));
        controller.migrate(address(successor), wrongOwner);
        ActivationSet memory wrongController = _set(2, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(2)));
        controller.migrate(address(successor), wrongController);
        vm.expectEmit(true, false, false, true);
        emit IRealmController.ControllerMigrated(address(successor), 2);
        controller.migrate(address(successor), set);
        assertTrue(controller.retired());
        assertFalse(controller.frozen());
        assertEq(hot.controller(), address(successor));
        (address la, address ra) = controller.admins();
        assertEq(ProxyAdmin(la).owner(), address(successor));
        assertEq(ProxyAdmin(ra).owner(), address(successor));
        ActivationSet memory retiredSet = _set(3, address(controller), address(this));
        vm.expectRevert(E_RETIRED.selector);
        controller.activate(retiredSet);
        vm.expectRevert(E_RETIRED.selector);
        controller.activatePolicy(noticeType, address(0));
        // the successor activates, administers the registry and freezes
        successor.activate(_set(3, address(successor), address(this)));
        assertEq(hot.revision(), 3);
        successor.activatePolicy(noticeType, address(0));
        assertEq(registry.typeInfo(noticeType).policyRow, 2);
        ActivationSet memory finalSet = _final(4, address(successor), address(this));
        bytes32 principal = Keys.contractPrincipal(hot.realmOrigin(), address(successor));
        (uint64 admissionsBefore,,,) = hot.counts();
        vm.expectEmit(true, false, false, false);
        emit IRealmController.Frozen(4, bytes32(0), 0, new uint64[](0));
        successor.freeze(finalSet, new bytes[](0));
        assertTrue(successor.frozen());
        assertEq(successor.owner(), address(0));
        assertEq(successor.pendingOwner(), address(0));
        assertEq(ProxyAdmin(la).owner(), address(0));
        assertEq(ProxyAdmin(ra).owner(), address(0));
        (,,, bool frozen) = hot.control();
        assertTrue(frozen);
        assertEq(hot.revision(), 4);
        // the canary landed as the successor's contract principal
        (uint64 admissions,,, uint64 publications) = hot.counts();
        assertEq(admissions, admissionsBefore + 1);
        bytes memory body = abi.encode(ClosureConstants.NOTICE_FROZEN, uint256(4), bytes(""));
        (bytes32 t, uint64 fa,,,) =
            hot.recordHeader(Keys.recordFromHash(noticeType, keccak256(body)));
        assertEq(t, noticeType);
        assertEq(fa, admissions);
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 1);
        // frozen: every control path refuses, writes keep landing
        ActivationSet memory afterFreeze = _set(5, address(successor), address(this));
        vm.expectRevert(E_FROZEN.selector);
        successor.activate(afterFreeze);
        vm.expectRevert(E_FROZEN.selector);
        successor.activatePolicy(noticeType, address(0));
        vm.expectRevert(E_FROZEN.selector);
        successor.beginTransition(5, uint48(vm.getBlockNumber() + 10));
        assertEq(_publish("after", 1), publications + 1);
    }

    function testFreezePrechecksAndCanary() public {
        ActivationSet memory finalSet = _final(2, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_FREEZE_PRECHECK.selector, uint8(9)));
        controller.freeze(finalSet, new bytes[](1));
        // the ledger's own pre-check: a terminal set needs a dependency root
        ActivationSet memory noRoot = _set(2, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_FREEZE_PRECHECK.selector, uint8(6)));
        controller.freeze(noRoot, new bytes[](0));
        // a replaced index that is not caught up is refused by the controller before anything moves
        _publish("one", 0);
        IndexDeploy.Gen1 memory g2 = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID);
        ActivationSet memory withNew = _final(2, address(controller), address(this));
        withNew.components.index = address(g2.index);
        withNew.components.indexCodehash = address(g2.index).codehash;
        withNew.components.indexManifestHash = g2.index.manifestHash();
        withNew.expectedExecutionSet = ExecutionSets.executionSet(withNew, k.proxy);
        vm.expectRevert(abi.encodeWithSelector(E_FREEZE_PRECHECK.selector, uint8(2)));
        controller.freeze(withNew, new bytes[](0));
        // a canary that cannot land reverts the whole ceremony: a refusing policy on the notice Type
        controller.activatePolicy(noticeType, address(new RejectAll()));
        finalSet = _final(2, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_CANARY.selector, uint8(0)));
        controller.freeze(finalSet, new bytes[](0));
        assertFalse(controller.frozen());
        assertEq(hot.revision(), 1, "nothing was frozen");
        (,,, bool frozen) = hot.control();
        assertFalse(frozen);
        assertEq(controller.owner(), address(this));
        // sunset the policy and the ceremony lands
        controller.activatePolicy(noticeType, address(0));
        controller.freeze(_final(2, address(controller), address(this)), new bytes[](0));
        assertTrue(controller.frozen());
    }

    // ---- transitions --------------------------------------------------------------------------------------

    function testTransitionsThroughTheController() public {
        vm.roll(1_000);
        uint48 deadline = uint48(vm.getBlockNumber() + 10); // block.number is CSE'd within a frame under via-IR
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_OWNER.selector, STRANGER));
        controller.beginTransition(2, deadline);
        controller.beginTransition(2, deadline);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_OWNER.selector, STRANGER));
        controller.abortTransition();
        vm.roll(uint256(deadline) + 1);
        vm.prank(STRANGER);
        controller.abortTransition(); // anyone after the deadline
        // the owner may abort early
        vm.roll(vm.getBlockNumber() + limits.maxTransitionBlocks + 1);
        controller.activate(_set(2, address(controller), address(this)));
        controller.beginTransition(3, uint48(vm.getBlockNumber() + 10));
        controller.abortTransition();
    }

    // ---- review findings -------------------------------------------------------------------------------------

    function testMigrateRefusesSuccessorsThatCouldNeverAct() public {
        ActivationSet memory self = _set(2, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(5)));
        controller.migrate(address(controller), self);
        RealmController foreignLedger =
            new RealmController(address(this), address(0xBAD), address(registry), noticeType);
        ActivationSet memory f1 = _set(2, address(foreignLedger), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(7)));
        controller.migrate(address(foreignLedger), f1);
        RealmController foreignRegistry =
            new RealmController(address(this), k.proxy, address(0xBAD), noticeType);
        ActivationSet memory f2 = _set(2, address(foreignRegistry), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(8)));
        controller.migrate(address(foreignRegistry), f2);
        // a retired controller is never a successor: migrate A → B, then B → A is refused
        RealmController successor =
            new RealmController(address(this), k.proxy, address(registry), noticeType);
        controller.migrate(address(successor), _set(2, address(successor), address(this)));
        assertTrue(controller.retired());
        ActivationSet memory back = _set(3, address(controller), address(this));
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(6)));
        successor.migrate(address(controller), back);
        assertEq(hot.controller(), address(successor), "the live controller is unchanged");
        assertFalse(successor.retired());
    }

    function testEveryControlPathAnswersFrozenAfterTheFreeze() public {
        controller.freeze(_final(2, address(controller), address(this)), new bytes[](0));
        ActivationSet memory set = _final(3, address(controller), address(this));
        vm.expectRevert(E_FROZEN.selector);
        controller.freeze(set, new bytes[](0));
        vm.expectRevert(E_FROZEN.selector);
        controller.declareRoleExpectation(keccak256("p"), keccak256("r"), noticeType);
        vm.expectRevert(E_FROZEN.selector);
        controller.activate(set);
        vm.prank(STRANGER);
        vm.expectRevert(E_FROZEN.selector);
        controller.activatePolicy(noticeType, address(0));
    }

    // ---- lane canaries must be the lane they claim ------------------------------------------------------------

    function _signedNotice(
        bytes32 executionSet,
        bytes32 indexObligations,
        uint64 nonce,
        bytes memory body
    ) internal view returns (bytes memory calldata_) {
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = noticeType;
        actions[0].bodyHashOrRecordId = keccak256(body);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        Intent memory it;
        it.realmId = hot.realmId();
        it.realmOrigin = hot.realmOrigin();
        it.executionSet = executionSet;
        it.principalId = Keys.principal(key);
        it.author = key;
        it.nonce = nonce;
        it.deadline = uint64(block.timestamp + 1 days);
        it.acceptanceProfile = _profileUnder(executionSet, actions[0]);
        it.indexObligations = indexObligations;
        it.readSetHash = keccak256("");
        it.verifierProfile = 1;
        bytes32 domain = hot.extsload(bytes32(Layout.LEDGER_REALM_DOMAINSEPARATOR_SLOT));
        bytes32 digest = ILedgerCommitments(hot.ingress())
            .signingDigest(domain, it, keccak256(abi.encode(actions)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, digest);
        calldata_ = abi.encodeCall(
            ILedger.executeSigned, (it, actions, bodies, "", abi.encodePacked(r, s, v))
        );
    }

    function _profileUnder(bytes32 executionSet, Action memory a)
        internal
        view
        returns (bytes32 h)
    {
        h = keccak256(abi.encode(Keys.DOM_PROFILE, executionSet));
        TypeInfo memory info = registry.typeInfo(a.typeId);
        uint32 gas_ =
            info.validationGas == 0 ? ClosureConstants.ACCEPTOR_GAS_DEFAULT : info.validationGas;
        h = keccak256(
            abi.encode(
                h, a.typeId, info.mandatory, info.ruleId, info.policyRow, info.policyCodehash, gas_
            )
        );
    }

    function _proofKind(uint64 publication) internal view returns (uint8 proofKind) {
        (, proofKind,,,,,) = Layout.unpackEvidenceCellWord0(
            hot.extsload(bytes32(Layout.publicationsEvidenceSlot(publication)))
        );
    }

    function _obligations(ActivationSet memory set) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                set.components.index, set.components.indexCodehash, set.components.indexManifestHash
            )
        );
    }

    function testASecpCanaryCannotStandInForTheErc1271Lane() public {
        ActivationSet memory set = _set(2, address(controller), address(this));
        set.capabilities = Capability.SIGNED_SECP256K1 | Capability.ERC1271;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        controller.activate(set);
        ActivationSet memory finalSet = _final(3, address(controller), address(this));
        finalSet.capabilities = Capability.SIGNED_SECP256K1 | Capability.ERC1271;
        finalSet.expectedExecutionSet = ExecutionSets.executionSet(finalSet, k.proxy);
        bytes[] memory canaries = new bytes[](2);
        canaries[0] =
            _signedNotice(finalSet.expectedExecutionSet, _obligations(finalSet), 0, "lane-1");
        canaries[1] =
            _signedNotice(finalSet.expectedExecutionSet, _obligations(finalSet), 1, "lane-2");
        vm.expectRevert(abi.encodeWithSelector(E_CANARY.selector, uint8(2)));
        controller.freeze(finalSet, canaries);
        assertFalse(controller.frozen(), "the ceremony reverted whole");
        assertEq(hot.revision(), 2);
    }

    function testTheSecpLaneCanaryProvesTheSecpLane() public {
        ActivationSet memory set = _set(2, address(controller), address(this));
        set.capabilities = Capability.SIGNED_SECP256K1;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        controller.activate(set);
        ActivationSet memory finalSet = _final(3, address(controller), address(this));
        finalSet.capabilities = Capability.SIGNED_SECP256K1;
        finalSet.expectedExecutionSet = ExecutionSets.executionSet(finalSet, k.proxy);
        bytes[] memory canaries = new bytes[](1);
        canaries[0] =
            _signedNotice(finalSet.expectedExecutionSet, _obligations(finalSet), 0, "lane-1");
        (,,, uint64 before) = hot.counts();
        controller.freeze(finalSet, canaries);
        assertTrue(controller.frozen());
        (,,, uint64 after_) = hot.counts();
        assertEq(after_, before + 2, "the native canary and the lane canary landed");
        assertEq(_proofKind(before + 1), 1, "native");
        assertEq(_proofKind(before + 2), 2, "secp256k1");
        // a canary that publishes something other than a realm notice is refused: not testable here without
        // a second registered Type on the signed lane; covered by the proof-kind check above
    }
}
