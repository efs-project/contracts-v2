// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ControlFixture} from "../harness/ControlFixture.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
import {PassthroughController} from "../harness/doubles/Signers.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Action, ActionKind} from "../../src/interfaces/Actions.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {
    AlreadyAdmitted,
    E_BATCH_SHAPE,
    E_CHAIN,
    E_CODE_SHAPE,
    E_EXECUTION_DRIFT,
    E_EXECUTION_SET,
    E_EXPECTED_SET,
    E_HOT_ABI,
    E_IMPLEMENTATION,
    E_INDEX_NOT_READY,
    E_LAYOUT,
    E_MIGRATION_SCOPE,
    E_NOT_CONTROLLER,
    E_PIN,
    E_REGISTRY,
    E_REGISTRY_DRIFT,
    E_REVISION
} from "../../src/interfaces/Errors.sol";

/// @notice Design §8.3 at the ledger level, with the test contract as controller: each step's refusal with
///         its exact error, one success per step, and the activation family's effects on the revision row,
///         the realm words and pending plans (the §16.4 C2-gate cells reachable without a RealmController).
contract ActivationTest is ControlFixture {
    bytes32 internal constant OTHER = keccak256("efs2/test/control/other");

    // =============================================================================================
    // 5a — the ordinal
    // =============================================================================================

    function test_skipped_ordinal_E_REVISION() public {
        ActivationSet memory set = nextSet();
        set.revision = 3;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_REVISION.selector, uint32(2), uint32(3))
        );
    }

    /// DESIGN-DIVERGENCE: §8.3 5a names E_REVISION for any ordinal other than revision + 1, but a repeated
    /// or lower ordinal never reaches the body: the `reinitializer(uint64(set.revision) + 1)` gate on
    /// `LedgerCore.activate` (src/core/LedgerCore.sol:117) refuses it first with OZ's InvalidInitialization.
    function test_repeated_or_lower_ordinal_refused_by_the_reinitializer() public {
        ActivationSet memory set = nextSet();
        set.revision = 1;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
        set.revision = 0;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
        // after a real activation the repeated ordinal is refused the same way
        activate(nextSet());
        set = nextSet();
        set.revision = 2;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
    }

    // =============================================================================================
    // 5b — migration (none at S1)
    // =============================================================================================

    function test_nonempty_migration_bytes_E_MIGRATION_SCOPE() public {
        ActivationSet memory set = nextSet();
        set.migration = hex"01";
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_MIGRATION_SCOPE.selector, bytes32(0))
        );
    }

    function test_nonempty_migration_scope_E_MIGRATION_SCOPE() public {
        ActivationSet memory set = nextSet();
        set.migrationScope = new bytes32[](1);
        set.migrationScope[0] = Layout.LEDGER_REALM_ROOT;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_MIGRATION_SCOPE.selector, bytes32(0))
        );
    }

    // =============================================================================================
    // 5c — the implementation
    // =============================================================================================

    function test_set_naming_an_implementation_that_is_not_live_E_IMPLEMENTATION() public {
        address impl2 = deploySecondImplementation();
        ActivationSet memory set = nextSet();
        set.components.ledgerImpl = impl2;
        set.components.ledgerImplCodehash = impl2.codehash;
        expectActivateRevert(
            seal(set),
            abi.encodeWithSelector(E_IMPLEMENTATION.selector, impl2, address(k.implementation))
        );
    }

    function test_live_implementation_with_wrong_codehash_E_IMPLEMENTATION() public {
        ActivationSet memory set = nextSet();
        set.components.ledgerImplCodehash = OTHER;
        expectActivateRevert(
            seal(set),
            abi.encodeWithSelector(
                E_IMPLEMENTATION.selector, address(k.implementation), address(k.implementation)
            )
        );
    }

    /// The C2 "ledger implementation" cell: upgrade through the ProxyAdmin (§8.3 step 2 by hand), the
    /// entry tripwire refuses writes until the revision row exists, then the matching set activates.
    function test_upgrade_then_activate_records_the_new_implementation() public {
        publishMarker("before");
        bytes32 retained = retainedDigest(1);
        bytes32 oldSet = hot.executionSet();
        address impl1 = address(k.implementation);
        address impl2 = deploySecondImplementation();
        upgradeProxy(impl2);
        assertEq(liveImplementation(), impl2);
        // between the upgrade and the activation no write lands under the new code (§8.3, §8.11)
        expectWriteRevert(
            "between", abi.encodeWithSelector(E_EXECUTION_DRIFT.selector, impl2, impl1)
        );

        ActivationSet memory set = nextSet();
        set.components.ledgerImpl = impl2;
        set.components.ledgerImplCodehash = impl2.codehash;
        set = seal(set);
        activate(set);

        Rev memory r = revisionRow(2);
        assertEq(r.ledgerImpl, impl2);
        assertEq(r.ledgerImplCodehash, impl2.codehash);
        assertEq(r.flags & (FLAG_SAME_CODE | FLAG_CHAIN), 0, "neither same-code nor chain");
        assertEq(r.flags, 0);
        assertEq(r.executionSet, hot.executionSet());
        assertEq(hot.executionSet(), executionSetOf(set));
        assertTrue(hot.executionSet() != oldSet);
        assertEq(revisionRow(1).ledgerImpl, impl1, "the old row is write-once");
        assertEq(retainedDigest(1), retained, "populated rows unchanged by the activation");
        (uint64 publication,) = publishMarker("after");
        assertEq(publication, 2);
    }

    /// The C2 "rollback" cell: an activation back to the previous implementation, with a new ordinal.
    function test_rollback_is_an_activation_to_the_previous_implementation() public {
        address impl1 = address(k.implementation);
        address impl2 = deploySecondImplementation();
        upgradeProxy(impl2);
        ActivationSet memory set = nextSet();
        set.components.ledgerImpl = impl2;
        set.components.ledgerImplCodehash = impl2.codehash;
        activate(seal(set));
        bytes32 es2 = hot.executionSet();

        upgradeProxy(impl1);
        expectWriteRevert(
            "between", abi.encodeWithSelector(E_EXECUTION_DRIFT.selector, impl1, impl2)
        );
        set = nextSet();
        set.components.ledgerImpl = impl1;
        set.components.ledgerImplCodehash = impl1.codehash;
        set = seal(set);
        activate(set);

        assertEq(hot.revision(), 3);
        assertEq(revisionRow(3).ledgerImpl, impl1);
        assertEq(revisionRow(3).flags, 0);
        assertTrue(hot.executionSet() != es2);
        assertTrue(hot.executionSet() != revisionRow(1).executionSet, "the ordinal is in the hash");
        publishMarker("after-rollback");
    }

    // =============================================================================================
    // 5d — the layout
    // =============================================================================================

    function test_wrong_layout_id_E_LAYOUT() public {
        ActivationSet memory set = nextSet();
        set.layoutId = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_LAYOUT.selector, Layout.LAYOUT_ID, OTHER)
        );
    }

    // =============================================================================================
    // 5e — the registry
    // =============================================================================================

    function test_registry_activeRevision_not_advanced_E_REGISTRY_1() public {
        ActivationSet memory set = nextSet();
        vm.expectRevert(abi.encodeWithSelector(E_REGISTRY.selector, uint8(1)));
        ctl.activate(set); // the registry double still reports revision 1
    }

    function test_registry_ledger_wrong_E_REGISTRY_2() public {
        registry.setLedger(stranger);
        expectActivateRevert(nextSet(), abi.encodeWithSelector(E_REGISTRY.selector, uint8(2)));
    }

    function test_registry_implementation_mismatched_E_REGISTRY_3() public {
        registry.setImplementation(address(index));
        expectActivateRevert(nextSet(), abi.encodeWithSelector(E_REGISTRY.selector, uint8(3)));
    }

    function test_registry_codehash_mismatched_E_REGISTRY_4() public {
        ActivationSet memory set = nextSet();
        set.components.registryImplCodehash = OTHER;
        expectActivateRevert(seal(set), abi.encodeWithSelector(E_REGISTRY.selector, uint8(4)));
    }

    /// The C2 "registry implementation" cell at the ledger level: the registry reports a new
    /// implementation and the matching set records it.
    function test_registry_only_activation_records_the_new_registry_implementation() public {
        MockRegistry impl2 = new MockRegistry();
        registry.setImplementation(address(impl2));
        // the drift is not a write tripwire (§8.11: only activeRevision is compared on entry)
        publishMarker("registry-drifted");
        ActivationSet memory set = nextSet();
        set.components.registryImpl = address(impl2);
        set.components.registryImplCodehash = address(impl2).codehash;
        set = seal(set);
        activate(set);
        Rev memory r = revisionRow(2);
        assertEq(r.registryImpl, address(impl2));
        assertEq(r.registryImplCodehash, address(impl2).codehash);
        assertEq(r.flags & FLAG_SAME_CODE, 0);
        assertEq(hot.executionSet(), executionSetOf(set));
        publishMarker("after");
    }

    function test_registry_activeRevision_behind_halts_writes_E_REGISTRY_DRIFT() public {
        registry.setActiveRevision(2); // the registry moved without the ledger
        expectWriteRevert(
            "drift", abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, uint64(1), uint64(2))
        );
    }

    // =============================================================================================
    // 5f — the helpers the implementation carries
    // =============================================================================================

    function test_set_naming_another_ingress_E_PIN_1() public {
        ActivationSet memory set = nextSet();
        set.components.ingress = stranger;
        expectActivateRevert(seal(set), abi.encodeWithSelector(E_PIN.selector, stranger, uint8(1)));
    }

    function test_set_with_wrong_ingress_codehash_E_PIN_1() public {
        ActivationSet memory set = nextSet();
        set.components.ingressCodehash = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_PIN.selector, address(k.ingress), uint8(1))
        );
    }

    function test_set_naming_another_apply_E_PIN_2() public {
        ActivationSet memory set = nextSet();
        set.components.applyDelegate = stranger;
        expectActivateRevert(seal(set), abi.encodeWithSelector(E_PIN.selector, stranger, uint8(2)));
    }

    function test_set_with_wrong_apply_codehash_E_PIN_2() public {
        ActivationSet memory set = nextSet();
        set.components.applyCodehash = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_PIN.selector, address(k.applyDelegate), uint8(2))
        );
    }

    /// DESIGN-DIVERGENCE: src/interfaces/Errors.sol:71 catalogs E_PIN reason 4 as "steward"; the control
    /// delegate uses 4 for the controller codehash (src/core/LedgerControl.sol:187-189) and pins the steward
    /// with CodePins/CodeScan only (E_CODE_SHAPE, :251-254).
    function test_wrong_controller_codehash_E_PIN_4() public {
        ActivationSet memory set = nextSet();
        set.components.controllerCodehash = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_PIN.selector, address(this), uint8(4))
        );
    }

    // =============================================================================================
    // 5g–5h — the index: pins and readiness
    // =============================================================================================

    function test_zero_index_refused_E_CODE_SHAPE() public {
        ActivationSet memory set = nextSet();
        set.components.index = address(0);
        set.components.indexCodehash = bytes32(0);
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0), uint8(1))
        );
    }

    function test_unchanged_index_wrong_codehash_E_PIN_3() public {
        ActivationSet memory set = nextSet();
        set.components.indexCodehash = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_PIN.selector, address(index), uint8(3))
        );
    }

    function test_unchanged_index_wrong_manifest_E_INDEX_NOT_READY_1() public {
        ActivationSet memory set = nextSet();
        set.components.indexManifestHash = OTHER;
        expectActivateRevert(
            seal(set), abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(1))
        );
    }

    function test_unchanged_index_not_idle_E_INDEX_NOT_READY_2() public {
        Readiness memory r = liveReadiness(index);
        r.phase = 2;
        index.setReadiness(r);
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(2))
        );
    }

    function test_new_index_wrong_ledger_E_INDEX_NOT_READY_3() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.ledger = stranger;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(3))
        );
    }

    function test_new_index_wrong_layout_E_INDEX_NOT_READY_4() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.layoutId = OTHER;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(4))
        );
    }

    function test_new_index_unsupported_hot_abi_E_INDEX_NOT_READY_5() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.hotAbiId = OTHER;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(5))
        );
    }

    function test_new_index_manifest_mismatch_E_INDEX_NOT_READY_6() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.manifestHash = keccak256("efs2/test/control/stale-manifest");
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(6))
        );
    }

    function test_new_index_completedAdmission_behind_E_INDEX_NOT_READY_8() public {
        publishMarker("m1");
        publishMarker("m2");
        PrefixAgreement idx = newIndexDouble(OTHER);
        idx.setReadiness(readiness(idx, 1, 2)); // stale admission frontier
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8))
        );
    }

    function test_new_index_completedPublication_behind_E_INDEX_NOT_READY_8() public {
        publishMarker("m1");
        publishMarker("m2");
        PrefixAgreement idx = newIndexDouble(OTHER);
        idx.setReadiness(readiness(idx, 2, 1)); // stale publication frontier
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8))
        );
    }

    function test_new_index_append_family_not_from_1_E_INDEX_NOT_READY_9() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.families = new FamilyEntry[](1);
        r.families[0].familyId = keccak256("efs2/family/by-type/1");
        r.families[0].shape = 1; // APPEND_ORDERED
        r.families[0].fromAdmission = 2;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(9))
        );
    }

    // E_INDEX_NOT_READY(10) (a family whose store's FAMILY_IDS lacks the id) and (11) (a writers gap) need
    // a PostingStore-shaped double; none exists in test/harness/doubles/, so both are not covered here.

    function test_new_index_store_codehash_mismatch_E_PIN_6() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.families = new FamilyEntry[](1);
        r.families[0].familyId = keccak256("efs2/family/scope/1");
        r.families[0].shape = 2; // BITMAP: no from == 1 rule
        r.families[0].fromAdmission = 1;
        r.families[0].store = address(registry); // real code, not the pinned codehash
        r.families[0].storeCodehash = OTHER;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_PIN.selector, address(registry), uint8(6))
        );
    }

    function test_new_index_build_codehash_mismatch_E_PIN_7() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.build = address(registry);
        r.buildCodehash = OTHER;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_PIN.selector, address(registry), uint8(7))
        );
    }

    function test_new_index_unit_hot_abi_unsupported_E_HOT_ABI() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.units = new Unit[](1);
        r.units[0].foldHook = address(idx);
        r.units[0].foldCodehash = address(idx).codehash;
        r.units[0].familyIds = new bytes32[](0);
        r.units[0].hotAbiId = OTHER;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_HOT_ABI.selector, address(idx))
        );
    }

    function test_new_index_unit_codehash_mismatch_E_PIN_5() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.units = new Unit[](1);
        r.units[0].foldHook = address(idx);
        r.units[0].foldCodehash = OTHER;
        r.units[0].familyIds = new bytes32[](0);
        r.units[0].hotAbiId = KernelDeploy.HOT_ABI_ID;
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_PIN.selector, address(idx), uint8(5))
        );
    }

    /// The tuple's own `ready` flag is never trusted (§8.3 5h): a false flag over a true predicate passes.
    function test_new_index_ready_flag_is_not_trusted() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.ready = false;
        idx.setReadiness(r);
        activate(withIndex(nextSet(), address(idx)));
        assertEq(hot.index(), address(idx));
    }

    /// §8.3 5h / §10.5: the readiness tuple echoes the ledger's phase; a new generation that reports a
    /// non-idle phase is not ready (reason 7), whatever the ledger's own lock says.
    function test_new_index_tuple_phase_must_be_idle_E_INDEX_NOT_READY_7() public {
        PrefixAgreement idx = newIndexDouble(OTHER);
        Readiness memory r = liveReadiness(idx);
        r.phase = 2; // APPLYING, as a mid-replay generation would echo
        idx.setReadiness(r);
        expectActivateRevert(
            withIndex(nextSet(), address(idx)),
            abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(7))
        );
    }

    // =============================================================================================
    // 5h — the ProxyAdmin
    // =============================================================================================

    function test_caller_not_ProxyAdmin_owner_E_PIN_9() public {
        ProxyAdmin admin = proxyAdmin();
        admin.transferOwnership(stranger);
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_PIN.selector, address(admin), uint8(9))
        );
    }

    /// DESIGN-DIVERGENCE: src/interfaces/Errors.sol:71 catalogs E_PIN reason 8 "admin slot"; a zero admin
    /// slot is refused as reason 9 with target 0 (src/core/LedgerControl.sol:312) and 8 is never emitted.
    function test_zeroed_admin_slot_E_PIN_9() public {
        vm.store(k.proxy, ADMIN_SLOT, bytes32(0));
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_PIN.selector, address(0), uint8(9))
        );
    }

    /// DESIGN-DIVERGENCE: §8.3 5h requires "ERC-1967 admin slot == the expected ProxyAdmin", and §8.11 lists
    /// "admin slot vs actual ProxyAdmin" as detected at activation. The ActivationSet carries no expected
    /// admin, so the control delegate trusts the slot and checks only `owner()` of whatever it names
    /// (src/core/LedgerControl.sol:307-313). With the slot pointing at a decoy owned by the controller, an
    /// activation succeeds while the proxy's real (immutable) admin is owned by a stranger who can still
    /// upgrade. Only the implementation can write that slot, so this needs a hostile implementation; the
    /// residual is `verify-deployment`'s (§8.11).
    function test_admin_slot_is_trusted_not_compared_with_the_proxy_admin() public {
        ProxyAdmin real = proxyAdmin();
        ProxyAdmin decoy = new ProxyAdmin(address(this));
        real.transferOwnership(stranger);
        vm.store(k.proxy, ADMIN_SLOT, bytes32(uint256(uint160(address(decoy)))));
        activate(nextSet());
        assertEq(hot.revision(), 2);
        // the real admin still governs the proxy
        address impl2 = deploySecondImplementation();
        vm.prank(stranger);
        real.upgradeAndCall(ITransparentUpgradeableProxy(k.proxy), impl2, "");
        assertEq(liveImplementation(), impl2);
    }

    // =============================================================================================
    // Step 6 (here inside the ledger) — the expected execution set
    // =============================================================================================

    function test_wrong_expected_set_reverts_the_whole_call_and_changes_no_state() public {
        publishMarker("m");
        bytes32 digest = fullDigest(2);
        uint64 version = initializedVersion();
        ActivationSet memory set = nextSet();
        bytes32 actual = executionSetOf(set);
        set.expectedExecutionSet = OTHER;
        expectActivateRevert(set, abi.encodeWithSelector(E_EXPECTED_SET.selector, OTHER, actual));
        assertEq(fullDigest(2), digest, "realm, counters, rows and revision rows 1..2 unchanged");
        assertEq(initializedVersion(), version);
        assertEq(hot.revision(), 1);
        registry.setActiveRevision(1); // undo the double's own advance
        publishMarker("still-writable");
    }

    // =============================================================================================
    // The gate
    // =============================================================================================

    function test_stranger_E_NOT_CONTROLLER() public {
        ActivationSet memory set = nextSet();
        registry.setActiveRevision(2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.activate(set);
    }

    // =============================================================================================
    // Same-code reactivation and pending plans (the C2 pending-artifact cells)
    // =============================================================================================

    function test_same_code_reactivation_advances_ordinal_sets_b1_and_changes_executionSet()
        public
    {
        publishMarker("m");
        bytes32 oldSet = hot.executionSet();
        bytes32 origin = hot.realmOrigin();
        bytes32 id = hot.realmId();
        bytes32 retained = retainedDigest(1);
        ActivationSet memory set = nextSet();
        registry.setActiveRevision(2);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.Activated(
            2, executionSetOf(set), uint64(vm.getBlockNumber()), uint64(1), FLAG_SAME_CODE
        );
        ctl.activate(set);

        assertEq(hot.revision(), 2);
        Rev memory r = revisionRow(2);
        assertEq(r.flags, FLAG_SAME_CODE);
        assertEq(r.admissionHigh, 1);
        assertEq(r.publicationHigh, 1);
        assertEq(r.activationBlock, vm.getBlockNumber());
        assertTrue(hot.executionSet() != oldSet, "the ordinal is inside the hash");
        assertEq(hot.executionSet(), executionSetOf(set));
        assertEq(r.executionSet, hot.executionSet());
        assertEq(hot.realmOrigin(), origin);
        assertEq(hot.realmId(), id);
        assertEq(retainedDigest(1), retained);
    }

    function test_bound_native_call_under_the_old_set_refused_unbound_lands() public {
        bytes32 oldSet = hot.executionSet();
        activate(nextSet());
        bytes32 newSet = hot.executionSet();
        uint64 nonce = nextNonce();
        (Action[] memory actions, bytes[] memory bodies) = createActions("bound");
        vm.expectRevert(abi.encodeWithSelector(E_EXECUTION_SET.selector, oldSet, newSet));
        ledger.execute(actions, bodies, nativeCtx(nonce, oldSet), "");
        assertEq(nextNonce(), nonce, "nonce intact");
        // the unbound call proceeds under the same nonce
        ledger.execute(actions, bodies, nativeCtx(nonce, 0), "");
        assertEq(nextNonce(), nonce + 1);
        // a call bound to the live set also lands
        (actions, bodies) = createActions("bound-live");
        ledger.execute(actions, bodies, nativeCtx(nonce + 1, newSet), "");
    }

    function test_already_admitted_plan_retried_after_activation_is_AlreadyAdmitted() public {
        bytes32 oldSet = hot.executionSet();
        (Action[] memory actions, bytes[] memory bodies) = createActions("unbound");
        ledger.execute(actions, bodies, nativeCtx(0, 0), "");
        (Action[] memory boundActions, bytes[] memory boundBodies) = createActions("bound");
        ledger.execute(boundActions, boundBodies, nativeCtx(1, oldSet), "");
        activate(nextSet());
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(1)));
        ledger.execute(actions, bodies, nativeCtx(0, 0), "");
        // the retry compare runs before the execution-set check
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(2)));
        ledger.execute(boundActions, boundBodies, nativeCtx(1, oldSet), "");
    }

    // =============================================================================================
    // Limits, index replacement, chain acceptance, owner and controller fields
    // =============================================================================================

    /// The C2 "limits" cell.
    function test_limits_change_sets_b7_and_changes_limitsProfileId() public {
        bytes32 oldProfile = realmWord(12);
        bytes32 oldSet = hot.executionSet();
        ActivationSet memory set = nextSet();
        set.limits.maxActions = 32;
        set.limits.kernelTail = 25_000;
        set = seal(set);
        activate(set);

        Rev memory r = revisionRow(2);
        assertEq(r.flags & FLAG_LIMITS, FLAG_LIMITS);
        // limits are not components: the same components still mark the row same-code
        assertEq(r.flags, FLAG_SAME_CODE | FLAG_LIMITS);
        bytes32 profile = keccak256(abi.encode(set.limits));
        assertEq(realmWord(12), profile);
        assertTrue(profile != oldProfile);
        assertEq(r.limitsProfileId, profile);
        assertEq(r.limits.maxActions, 32);
        assertEq(r.limits.kernelTail, 25_000);
        (uint16 maxActions,,,,,,,,,,,,) = Layout.unpackRealmStorageWord13(realmWord(13));
        assertEq(maxActions, 32);
        (,,, uint32 kernelTail) = Layout.unpackRealmStorageWord14(realmWord(14));
        assertEq(kernelTail, 25_000);
        assertTrue(hot.executionSet() != oldSet);

        // the new maximum binds the next write
        Action[] memory actions = new Action[](33);
        for (uint256 i; i < 33; ++i) {
            actions[i].kind = ActionKind.CREATE;
            actions[i].salt = bytes32(i + 1);
        }
        bytes[] memory bodies = new bytes[](33);
        uint64 nonce = nextNonce();
        vm.expectRevert(abi.encodeWithSelector(E_BATCH_SHAPE.selector, uint16(33), uint16(33)));
        ledger.execute(actions, bodies, nativeCtx(nonce, 0), "");
    }

    function test_index_replacement_sets_b5_and_indexGeneration_is_the_revision() public {
        publishMarker("m");
        uint64 oldCalls = index.prefixCalls();
        PrefixAgreement idx = newIndexDouble(OTHER);
        ActivationSet memory set = withIndex(nextSet(), address(idx));
        activate(set);

        Rev memory r = revisionRow(2);
        assertEq(r.flags, FLAG_INDEX);
        assertEq(r.index, address(idx));
        assertEq(r.indexGeneration, 2);
        assertEq(hot.index(), address(idx));
        assertEq(hot.indexGeneration(), 2);
        assertEq(realmWord(10), ExecutionSets.indexObligations(set.components));
        publishMarker("through-the-new-index");
        assertEq(idx.prefixCalls(), 1);
        assertEq(index.prefixCalls(), oldCalls, "the old generation is detached");

        // a later activation that keeps the index carries the generation
        activate(nextSet());
        assertEq(revisionRow(3).indexGeneration, 2);
        assertEq(hot.indexGeneration(), 2);
        assertEq(revisionRow(3).flags, FLAG_SAME_CODE);
    }

    function test_chain_acceptance_change_sets_b2_recomputes_domain_and_reopens_writes() public {
        publishMarker("m");
        uint64 genesisChain = uint64(vm.getChainId());
        uint64 fork = genesisChain + 1_000;
        bytes32 origin = hot.realmOrigin();
        bytes32 oldDomain = realmWord(9);
        assertEq(oldDomain, ExecutionSets.domainSeparator(genesisChain, k.proxy));

        vm.chainId(fork);
        expectWriteRevert(
            "on-the-fork", abi.encodeWithSelector(E_CHAIN.selector, genesisChain, fork)
        );
        ActivationSet memory set = nextSet();
        set.acceptedChainId = fork;
        set = seal(set);
        activate(set);

        Rev memory r = revisionRow(2);
        assertEq(r.flags, FLAG_SAME_CODE | FLAG_CHAIN);
        assertEq(r.acceptedChainId, fork);
        assertEq(realmWord(9), ExecutionSets.domainSeparator(fork, k.proxy));
        assertTrue(realmWord(9) != oldDomain);
        (uint64 g, uint64 accepted, uint32 rev, bool frozen) = hot.control();
        assertEq(g, genesisChain, "genesisChainId is forever");
        assertEq(accepted, fork);
        assertEq(rev, 2);
        assertFalse(frozen);
        assertEq(hot.realmOrigin(), origin, "realmOrigin keeps the genesis chain id");
        publishMarker("on-the-fork");
    }

    /// The ledger records `controllerOwner` as a claim and flags its change (b4); the owner itself is the
    /// RealmController's (§8.4), not testable here.
    function test_owner_field_change_sets_b4() public {
        ActivationSet memory set = nextSet();
        set.components.controllerOwner = stranger;
        activate(seal(set));
        Rev memory r = revisionRow(2);
        assertEq(r.flags, FLAG_OWNER);
        assertEq(r.controllerOwner, stranger);
    }

    /// At the ledger level a set may name a controller other than the caller: that is how §8.5 migration
    /// lands (flag b3). The refusal of a set whose `controller` is not the executing controller (§8.3 step 0,
    /// §16.4) lives in RealmController and is not testable without it. The successor can activate only once
    /// the ProxyAdmin is its own (§8.3 5h).
    function test_ledger_level_controller_handover_sets_b3() public {
        PassthroughController successor = new PassthroughController();
        ActivationSet memory set = nextSet();
        set.components.controller = address(successor);
        set.components.controllerCodehash = address(successor).codehash;
        activate(seal(set));
        Rev memory r = revisionRow(2);
        assertEq(r.flags, FLAG_CONTROLLER);
        assertEq(r.controller, address(successor));
        assertEq(hot.controller(), address(successor));

        // the old controller is out
        set = nextSet();
        registry.setActiveRevision(3);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, address(this)));
        ctl.activate(set);
        // the successor is refused until it owns the ProxyAdmin
        ProxyAdmin admin = proxyAdmin();
        vm.expectRevert(abi.encodeWithSelector(E_PIN.selector, address(admin), uint8(9)));
        successor.call(k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        admin.transferOwnership(address(successor));
        successor.call(k.proxy, abi.encodeCall(ILedgerControl.activate, (set)));
        assertEq(hot.revision(), 3);
        assertEq(revisionRow(3).flags, FLAG_SAME_CODE);
    }

    // =============================================================================================
    // The reinitializer offset (design §5.4)
    // =============================================================================================

    function test_initialized_version_is_revision_plus_one_after_each_activation() public {
        assertEq(initializedVersion(), 2);
        assertEq(initializedVersion(), uint64(hot.revision()) + 1);

        activate(nextSet()); // same code
        assertEq(initializedVersion(), 3);

        ActivationSet memory set = nextSet();
        set.limits.maxRefs = 4;
        activate(seal(set)); // limits
        assertEq(initializedVersion(), 4);

        activate(withIndex(nextSet(), address(newIndexDouble(OTHER)))); // index
        assertEq(initializedVersion(), 5);
        assertEq(initializedVersion(), uint64(hot.revision()) + 1);

        // the bare implementation's initializers are disabled
        assertEq(initializedVersionOf(address(k.implementation)), type(uint64).max);
    }
}
