// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ControlFixture} from "../harness/ControlFixture.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
import {LedgerCore} from "../../src/core/LedgerCore.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet, RealmInit} from "../../src/interfaces/ILedgerControl.sol";
import {
    E_DELEGATE_ONLY,
    E_EXECUTION_DRIFT,
    E_HELPER_CODE,
    E_IMPLEMENTATION,
    E_NOT_CONTROLLER,
    E_NO_INDEX,
    E_TRANSITION
} from "../../src/interfaces/Errors.sol";

/// @notice Design §8.2 (G13, G18.3, G20) and the per-write drift tripwires of §8.11 at the ledger level:
///         initializer misuse, the disabled bare implementation, writes refused until the genesis
///         activation, the genesis identity and limits words, the helper pins, etched helpers and
///         implementation-slot drift.
contract GenesisTest is ControlFixture {
    struct Fresh {
        KernelDeploy.Kernel k;
        MockRegistry registry;
        PrefixAgreement index;
    }

    /// A deployment initialized but not yet activated, with its own registry and index doubles.
    function _fresh(bytes32 salt) internal returns (Fresh memory f) {
        f.registry = new MockRegistry();
        f.k = KernelDeploy.deploy(address(this), address(f.registry), salt);
        f.registry.setLedger(f.k.proxy);
        f.registry.setImplementation(address(f.registry));
        f.registry.setActiveRevision(1);
        f.index = new PrefixAgreement(f.k.proxy);
        f.index.setReadiness(readinessFor(f.k.proxy, f.index, 0, 0));
    }

    function _genesisSet(Fresh memory f) internal view returns (ActivationSet memory) {
        return KernelDeploy.genesisSet(
            f.k, address(this), address(f.registry), address(f.index), f.index.manifestHash()
        );
    }

    function _init(bytes32 salt) internal pure returns (RealmInit memory) {
        return RealmInit({
            realmSalt: salt,
            controller: address(0xC0FFEE),
            registry: address(0xBEEF),
            readerDirectory: address(0),
            executionProfileId: 1,
            limits: KernelDeploy.s1Limits()
        });
    }

    function _write(address proxy, bytes32 salt) internal returns (uint64 publication) {
        (Action[] memory actions, bytes[] memory bodies) = createActions(salt);
        (publication,) = ILedger(proxy).execute(actions, bodies, nativeCtx(0, 0), "");
    }

    function _expectFreshWriteRevert(address proxy, bytes32 salt, bytes memory err) internal {
        (Action[] memory actions, bytes[] memory bodies) = createActions(salt);
        vm.expectRevert(err);
        ILedger(proxy).execute(actions, bodies, nativeCtx(0, 0), "");
    }

    // =============================================================================================
    // Initializer misuse (§16.2 #5 `test_initializer_misuse_refused`)
    // =============================================================================================

    function test_initialize_twice_InvalidInitialization() public {
        bytes memory err = abi.encodeWithSelector(Initializable.InvalidInitialization.selector);
        // on the activated proxy
        vm.expectRevert(err);
        ctl.initialize(_init(REALM_SALT));
        // and on a fresh proxy before its genesis activation
        Fresh memory f = _fresh("fresh");
        vm.expectRevert(err);
        ILedgerControl(f.k.proxy).initialize(_init("fresh"));
        assertEq(initializedVersionOf(f.k.proxy), 1);
    }

    function test_initialize_on_the_bare_implementation_reverts() public {
        LedgerCore impl = k.implementation;
        assertEq(initializedVersionOf(address(impl)), type(uint64).max, "initializers disabled");
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        impl.initialize(_init(REALM_SALT));
        // its controller word is zero: anyone but address(0) meets the controller gate ...
        ActivationSet memory set = nextSet();
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, address(this)));
        impl.activate(set);
        // ... and address(0) meets the disabled reinitializer
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        impl.activate(set);
    }

    function test_control_delegate_refuses_direct_calls_E_DELEGATE_ONLY() public {
        bytes memory err = abi.encodeWithSelector(E_DELEGATE_ONLY.selector);
        vm.expectRevert(err);
        k.control.initialize(_init(REALM_SALT));
        ActivationSet memory set = nextSet();
        vm.expectRevert(err);
        k.control.activate(set);
        vm.expectRevert(err);
        k.control.abortTransition();
    }

    // =============================================================================================
    // Writes disabled until genesis (G18.3, G20)
    // =============================================================================================

    function test_fresh_deployment_refuses_writes_until_genesis() public {
        Fresh memory f = _fresh("fresh");
        assertEq(ILedgerHot(f.k.proxy).revision(), 0);
        assertEq(initializedVersionOf(f.k.proxy), 1);
        TransitionWord memory t = transitionWordOf(f.k.proxy);
        assertEq(t.target, 1);
        assertEq(t.deadline, type(uint48).max);
        assertEq(t.lastTarget, 0);
        assertEq(t.cooldownUntil, 0);
        bytes memory refused =
            abi.encodeWithSelector(E_TRANSITION.selector, uint32(1), type(uint48).max);
        _expectFreshWriteRevert(f.k.proxy, "pre-genesis", refused);
        vm.roll(vm.getBlockNumber() + 1_000_000); // the genesis transition never expires
        _expectFreshWriteRevert(f.k.proxy, "pre-genesis", refused);

        ILedgerControl(f.k.proxy).activate(_genesisSet(f));
        assertEq(_write(f.k.proxy, "post-genesis"), 1);
    }

    function test_genesis_activation_clears_the_genesis_transition() public {
        Fresh memory f = _fresh("fresh");
        ActivationSet memory set = _genesisSet(f);
        vm.expectEmit(f.k.proxy);
        emit ILedgerControl.TransitionEnded(1, 1);
        vm.expectEmit(f.k.proxy);
        emit ILedgerControl.Activated(
            1, ExecutionSets.executionSet(set, f.k.proxy), uint64(vm.getBlockNumber()), 0, 0
        );
        ILedgerControl(f.k.proxy).activate(set);

        TransitionWord memory t = transitionWordOf(f.k.proxy);
        assertEq(t.target, 0);
        assertEq(t.deadline, 0);
        assertEq(t.lastTarget, 0, "lastTarget stays 0 (G20)");
        assertEq(t.cooldownUntil, 0);
        Rev memory r = revisionRowOf(f.k.proxy, 1);
        assertEq(r.flags, 0, "the genesis row carries no change flags");
        assertEq(r.indexGeneration, 1);
        assertEq(ILedgerHot(f.k.proxy).indexGeneration(), 1);
        assertEq(initializedVersionOf(f.k.proxy), 2, "revision 1 runs under version 2");
        assertEq(ILedgerHot(f.k.proxy).executionSet(), set.expectedExecutionSet);
    }

    function test_pre_genesis_beginTransition_E_TRANSITION() public {
        Fresh memory f = _fresh("fresh");
        uint48 d = uint48(vm.getBlockNumber() + 10);
        vm.expectRevert(abi.encodeWithSelector(E_TRANSITION.selector, uint32(1), type(uint48).max));
        ILedgerControl(f.k.proxy).beginTransition(1, d);
    }

    /// DESIGN-DIVERGENCE: §8.2 G18.3 disables writes "until the genesis activation" through the genesis
    /// transition (target 1, deadline 2^48 − 1). `abortTransition` lets the controller end it before genesis
    /// (src/core/LedgerControl.sol:446-457 has no revision-0 case); writes stay refused only because no
    /// index is installed yet (E_NO_INDEX, src/core/LedgerCore.sol:230). A stranger cannot (the deadline
    /// never passes).
    function test_pre_genesis_abort_of_the_genesis_transition_leaves_writes_E_NO_INDEX() public {
        Fresh memory f = _fresh("fresh");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ILedgerControl(f.k.proxy).abortTransition();

        vm.expectEmit(f.k.proxy);
        emit ILedgerControl.TransitionEnded(1, 2);
        ILedgerControl(f.k.proxy).abortTransition();
        _expectFreshWriteRevert(f.k.proxy, "aborted", abi.encodeWithSelector(E_NO_INDEX.selector));

        ILedgerControl(f.k.proxy).activate(_genesisSet(f));
        assertEq(_write(f.k.proxy, "post-genesis"), 1);
    }

    // =============================================================================================
    // Identity, limits and pins
    // =============================================================================================

    function test_realm_identity_words() public view {
        bytes32 origin = Keys.realmOrigin(uint64(vm.getChainId()), k.proxy, REALM_SALT);
        assertEq(hot.realmOrigin(), origin);
        assertEq(hot.realmId(), Keys.realmId(origin, 1));
        assertEq(realmWord(0), hot.realmId());
        assertEq(realmWord(1), origin);
        assertEq(realmWord(2), REALM_SALT);
        (uint64 genesisChain, uint64 accepted, uint32 rev, uint8 frozen) =
            Layout.unpackRealmStorageWord3(realmWord(3));
        assertEq(genesisChain, vm.getChainId());
        assertEq(accepted, vm.getChainId());
        assertEq(rev, 1);
        assertEq(frozen, 0);
        (address controller, uint16 profile, uint16 caps, uint16 genesisProfile) =
            Layout.unpackRealmStorageWord4(realmWord(4));
        assertEq(controller, address(this));
        assertEq(profile, 1);
        assertEq(caps, 0);
        assertEq(genesisProfile, 1);
        assertEq(hot.registry(), address(registry));
        assertEq(hot.readerDirectory(), address(0));
        assertEq(hot.layoutId(), Layout.LAYOUT_ID);
        assertEq(realmWord(9), ExecutionSets.domainSeparator(uint64(vm.getChainId()), k.proxy));
    }

    function test_limitsProfileId_is_the_hash_of_the_limits() public {
        bytes32 profile = keccak256(abi.encode(KernelDeploy.s1Limits()));
        assertEq(realmWord(12), profile);
        Rev memory r = revisionRow(1);
        assertEq(r.limitsProfileId, profile);
        assertEq(keccak256(abi.encode(r.limits)), profile, "w22-w23 re-derive w21");
        // initialize already wrote it, before any activation
        Fresh memory f = _fresh("fresh");
        assertEq(realmWordOf(f.k.proxy, 12), profile);
    }

    function test_helper_pins_from_hot_getters_immutables_and_the_revision_row() public view {
        LedgerCore impl = k.implementation;
        address ingress = address(k.ingress);
        address applyDelegate = address(k.applyDelegate);
        address control = address(k.control);
        // hot getters (served from the implementation's immutables)
        assertEq(hot.ingress(), ingress);
        assertEq(hot.applyDelegate(), applyDelegate);
        assertEq(hot.hotAbiId(), KernelDeploy.HOT_ABI_ID);
        bytes32[] memory supported = hot.supportedHotAbiIds();
        assertEq(supported.length, 1);
        assertEq(supported[0], KernelDeploy.HOT_ABI_ID);
        // the implementation's public immutables
        assertEq(impl.INGRESS(), ingress);
        assertEq(impl.INGRESS_CODEHASH(), ingress.codehash);
        assertEq(impl.APPLY(), applyDelegate);
        assertEq(impl.APPLY_CODEHASH(), applyDelegate.codehash);
        assertEq(impl.CONTROL(), control);
        assertEq(impl.CONTROL_CODEHASH(), control.codehash);
        assertEq(impl.HOT_ABI_ID(), KernelDeploy.HOT_ABI_ID);
        assertEq(impl.LAYOUT_ID(), Layout.LAYOUT_ID);
        // the same immutables through the proxy
        assertEq(LedgerCore(k.proxy).CONTROL(), control);
        assertEq(LedgerCore(k.proxy).CONTROL_CODEHASH(), control.codehash);
        // the control delegate carries the same helper pins (the implementation's constructor checks it)
        assertEq(k.control.INGRESS(), ingress);
        assertEq(k.control.APPLY(), applyDelegate);
        assertEq(k.control.INGRESS_CODEHASH(), ingress.codehash);
        assertEq(k.control.APPLY_CODEHASH(), applyDelegate.codehash);
        assertEq(k.control.LAYOUT_ID(), Layout.LAYOUT_ID);
        assertEq(k.control.PREDECESSOR_LAYOUT_ID(), bytes32(0));
        // the genesis revision row records the activated implementation's values
        Rev memory r = revisionRow(1);
        assertEq(r.ledgerImpl, address(impl));
        assertEq(r.ledgerImplCodehash, address(impl).codehash);
        assertEq(r.ingress, ingress);
        assertEq(r.ingressCodehash, ingress.codehash);
        assertEq(r.applyDelegate, applyDelegate);
        assertEq(r.applyCodehash, applyDelegate.codehash);
        assertEq(r.controller, address(this));
        assertEq(r.controllerCodehash, address(this).codehash);
        assertEq(r.index, address(index));
        assertEq(r.layoutId, Layout.LAYOUT_ID);
    }

    // =============================================================================================
    // Per-write drift tripwires (§6.1, §8.11)
    // =============================================================================================

    function test_etched_ingress_E_HELPER_CODE_then_restored() public {
        address ingress = address(k.ingress);
        bytes memory code = ingress.code;
        vm.etch(ingress, bytes.concat(code, hex"00")); // same behaviour, different codehash
        expectWriteRevert("etched", abi.encodeWithSelector(E_HELPER_CODE.selector, ingress));
        vm.etch(ingress, code);
        publishMarker("restored");
    }

    function test_etched_apply_E_HELPER_CODE_then_restored() public {
        address applyDelegate = address(k.applyDelegate);
        bytes memory code = applyDelegate.code;
        vm.etch(applyDelegate, bytes.concat(code, hex"00"));
        expectWriteRevert("etched", abi.encodeWithSelector(E_HELPER_CODE.selector, applyDelegate));
        vm.etch(applyDelegate, code);
        publishMarker("restored");
    }

    function test_etched_control_delegate_E_HELPER_CODE_then_restored() public {
        address control = address(k.control);
        bytes memory code = control.code;
        vm.etch(control, bytes.concat(code, hex"00"));
        ActivationSet memory set = nextSet();
        bytes memory err = abi.encodeWithSelector(E_HELPER_CODE.selector, control);
        expectActivateRevert(set, err);
        vm.expectRevert(err);
        ctl.abortTransition();
        uint48 d = uint48(vm.getBlockNumber() + 10);
        vm.expectRevert(err);
        ctl.beginTransition(2, d);
        vm.etch(control, code);
        activate(set);
        assertEq(hot.revision(), 2);
    }

    /// The c0 "drift behind unchanged code" test rebuilt as a per-write tripwire (§8.6, §8.11): the ERC-1967
    /// implementation slot moved without an activation refuses every write, the drift is visible as slot
    /// vs `revisionRow(revision).ledgerImpl`, and the next activation naming the recorded implementation
    /// is refused at step 5c.
    function test_implementation_slot_drift_refuses_writes_E_EXECUTION_DRIFT() public {
        address impl1 = address(k.implementation);
        address impl2 = deploySecondImplementation();
        vm.store(k.proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(impl2))));
        expectWriteRevert(
            "drifted", abi.encodeWithSelector(E_EXECUTION_DRIFT.selector, impl2, impl1)
        );
        assertEq(liveImplementation(), impl2);
        assertEq(revisionRow(1).ledgerImpl, impl1);
        assertTrue(liveImplementation() != revisionRow(hot.revision()).ledgerImpl, "visible");
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_IMPLEMENTATION.selector, impl1, impl2)
        );
        registry.setActiveRevision(1);
        vm.store(k.proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(impl1))));
        publishMarker("restored");
    }
}
