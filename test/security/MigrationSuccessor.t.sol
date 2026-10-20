// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {Delegator} from "../harness/doubles/WrapperDouble.sol";
import {
    DelegatingPassthroughController,
    PassthroughController
} from "../harness/doubles/Signers.sol";
import {RealmController} from "../../src/control/RealmController.sol";
import {RealmGenesis} from "../../src/control/RealmGenesis.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {E_CODE_SHAPE, E_SUCCESSOR} from "../../src/interfaces/Errors.sol";

/// @notice §2.2 S15 — migration to a hostile successor. `RealmController.migrate` runs `CodePins.requireRealCode`
///         and `CodeScan.requirePlainRuntime` on the successor, then requires the set to pin its codehash
///         (`E_SUCCESSOR(1)`), name it (`2`) and disclose its owner (`3`) before the activation runs
///         (src/control/RealmController.sol:111-131). A code-less, designator, `DELEGATECALL`-passthrough,
///         proxied or cloned successor is refused and the Realm keeps its controller and both ProxyAdmins.
contract MigrationSuccessorTest is Test {
    KernelDeploy.Kernel internal k;
    IndexDeploy.Gen1 internal g;
    TypeRegistry internal registryImpl;
    TypeRegistry internal registry;
    RealmController internal controller;
    ILedgerHot internal hot;
    bytes32 internal constant NOTICE = keccak256("efs2/test/security/migration/notice");

    function setUp() public {
        k = KernelDeploy.deployImplementations();
        registryImpl = new TypeRegistry(address(new DescriptorStore()));
        Limits memory limits = KernelDeploy.s1Limits();
        RealmGenesis genesis = new RealmGenesis(
            address(this),
            address(k.implementation),
            address(registryImpl),
            keccak256("efs2/test/security/migration/salt"),
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
        hot = ILedgerHot(k.proxy);
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID);
        controller.activate(_set(1, address(controller)));
    }

    function _set(uint32 revision, address ctl) internal view returns (ActivationSet memory set) {
        set = KernelDeploy.genesisSet(
            k, ctl, address(this), address(registryImpl), address(g.index), g.index.manifestHash()
        );
        set.revision = revision;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }

    function _assertUnchanged() internal view {
        assertEq(hot.controller(), address(controller));
        assertEq(hot.revision(), 1);
        assertEq(registry.activeRevision(), 1);
        assertFalse(controller.retired());
        (address la, address ra) = controller.admins();
        assertEq(ProxyAdmin(la).owner(), address(controller));
        assertEq(ProxyAdmin(ra).owner(), address(controller));
    }

    function _refuse(address successor, bytes memory err) internal {
        ActivationSet memory set = _set(2, successor);
        vm.expectRevert(err);
        controller.migrate(successor, set);
        _assertUnchanged();
    }

    function test_codeless_designator_passthrough_proxy_and_clone_successors_refused() public {
        RealmController honest =
            new RealmController(address(this), k.proxy, address(registry), NOTICE);
        address codeless = makeAddr("migration/code-less");
        _refuse(codeless, abi.encodeWithSelector(E_CODE_SHAPE.selector, codeless, uint8(1)));
        address designator = makeAddr("migration/designator");
        vm.etch(designator, abi.encodePacked(hex"ef0100", address(honest)));
        _refuse(designator, abi.encodeWithSelector(E_CODE_SHAPE.selector, designator, uint8(2)));
        address delegating = address(new DelegatingPassthroughController());
        _refuse(delegating, abi.encodeWithSelector(E_CODE_SHAPE.selector, delegating, uint8(3)));
        address proxied = address(new Delegator(address(honest)));
        _refuse(proxied, abi.encodeWithSelector(E_CODE_SHAPE.selector, proxied, uint8(3)));
        address clone = Clones.clone(address(honest));
        _refuse(clone, abi.encodeWithSelector(E_CODE_SHAPE.selector, clone, uint8(5)));
        // an honest successor whose codehash the set does not pin
        ActivationSet memory set = _set(2, address(honest));
        set.components.controllerCodehash = keccak256("efs2/test/security/migration/other");
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(1)));
        controller.migrate(address(honest), set);
        _assertUnchanged();
        // the control: the honest successor, pinned and disclosed, is accepted
        set = _set(2, address(honest));
        controller.migrate(address(honest), set);
        assertEq(hot.controller(), address(honest));
        assertTrue(controller.retired());
    }

    /// DESIGN-DIVERGENCE: §16.6 lists "migration to a code-less, proxied or passthrough successor refused", but
    /// the S15 mechanism (opcode scan + codehash pin + owner disclosure) cannot refuse a `CALL`-only
    /// passthrough: it is a plain runtime (`test/unit/Doubles.t.sol::test_passthrough_controllers_and_what_CodeScan_sees`).
    /// This test pins the residual: such a successor is accepted only when the set pins its exact codehash and
    /// discloses its owner, so the choice is visible in the revision row. A design ruling is needed on whether
    /// that is the intended reading of "passthrough".
    function test_call_only_passthrough_is_accepted_only_pinned_and_disclosed() public {
        PassthroughController passthrough = new PassthroughController();
        ActivationSet memory set = _set(2, address(passthrough));
        set.components.controllerOwner = address(0xBEEF);
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        vm.expectRevert(abi.encodeWithSelector(E_SUCCESSOR.selector, uint8(3)));
        controller.migrate(address(passthrough), set);
        _assertUnchanged();
        set = _set(2, address(passthrough));
        controller.migrate(address(passthrough), set);
        assertEq(hot.controller(), address(passthrough));
    }
}
