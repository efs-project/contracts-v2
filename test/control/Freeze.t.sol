// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ControlFixture} from "../harness/ControlFixture.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {
    E_CHAIN,
    E_EXPECTED_SET,
    E_FREEZE_PRECHECK,
    E_FROZEN,
    E_NOT_CONTROLLER,
    E_TRANSITION_TARGET
} from "../../src/interfaces/Errors.sol";

/// @notice Design §8.10 at the ledger level (`LedgerCore.freeze`, the test contract as controller): the
///         ledger's pre-checks in order, a successful terminal activation, and the frozen Realm (every
///         control path refused, writes and reads continuing, retained rows untouched). The controller's
///         side of the ceremony — pre-checks 2, 3 and 9, the canaries, renouncing both ProxyAdmins,
///         `owner := 0` and the `Frozen` event — needs a RealmController and is not covered here.
contract FreezeTest is ControlFixture {
    bytes32 internal constant DEPS = keccak256("efs2/test/control/dependency-root");

    /// The terminal set: the live components at revision + 1 with a nonzero dependency root.
    function _finalSet() internal view returns (ActivationSet memory set) {
        set = nextSet();
        set.dependencyRoot = DEPS;
        set = seal(set);
    }

    function _precheck(uint8 n) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_FREEZE_PRECHECK.selector, n);
    }

    // =============================================================================================
    // Pre-checks (the ledger's numbering is the design's: 1, 4, 5, 6, 7, 8)
    // =============================================================================================

    function test_precheck_1_wrong_chain_id() public {
        ActivationSet memory set = _finalSet();
        set.acceptedChainId = uint64(vm.getChainId()) + 1;
        expectFreezeRevert(seal(set), _precheck(1));
    }

    function test_precheck_4_open_transition() public {
        ctl.beginTransition(2, uint48(vm.getBlockNumber() + 100));
        expectFreezeRevert(_finalSet(), _precheck(4));
    }

    function test_precheck_5_steward_nonzero() public {
        ActivationSet memory set = _finalSet();
        set.components.steward = address(index); // real code: refused by the pre-check, not a scan
        expectFreezeRevert(seal(set), _precheck(5));
    }

    function test_precheck_6_dependency_root_zero() public {
        ActivationSet memory set = _finalSet();
        set.dependencyRoot = bytes32(0);
        expectFreezeRevert(seal(set), _precheck(6));
    }

    function test_precheck_7_narrower_capabilities() public {
        ActivationSet memory set = nextSet();
        set.capabilities = 1; // b0 NATIVE_GUARD
        activate(seal(set));
        set = _finalSet();
        set.capabilities = 0; // retires b0
        expectFreezeRevert(seal(set), _precheck(7));
        set.capabilities = 2; // a different lane is not a superset
        expectFreezeRevert(seal(set), _precheck(7));
        set.capabilities = 3; // a superset passes
        freeze(seal(set));
        (,,, bool frozen) = hot.control();
        assertTrue(frozen);
    }

    function test_precheck_8_smaller_limit() public {
        ActivationSet memory set = _finalSet();
        set.limits.maxActions = 63;
        expectFreezeRevert(seal(set), _precheck(8));
        set = _finalSet();
        set.limits.maxReadCount = 255;
        expectFreezeRevert(seal(set), _precheck(8));
        set = _finalSet();
        set.limits.maxBodyBytesPerPublication = 16_383;
        expectFreezeRevert(seal(set), _precheck(8));
        set = _finalSet();
        set.limits.maxBody = 16_384; // larger maxima pass
        freeze(seal(set));
        (,,, bool frozen) = hot.control();
        assertTrue(frozen);
    }

    /// One set failing every ledger pre-check, repaired one check at a time: the refusals come in the
    /// design's order. An expired transition does not block the freeze.
    function test_prechecks_fire_in_order() public {
        ActivationSet memory set = nextSet();
        set.capabilities = 1;
        activate(seal(set)); // revision 2, capabilities b0
        uint48 deadline = uint48(vm.getBlockNumber() + 100);
        ctl.beginTransition(3, deadline);

        set = nextSet();
        uint64 chain = set.acceptedChainId;
        set.acceptedChainId = chain + 1;
        set.components.steward = address(index);
        set.dependencyRoot = bytes32(0);
        set.capabilities = 0;
        set.limits.maxActions = 1;
        expectFreezeRevert(set, _precheck(1));
        set.acceptedChainId = chain;
        expectFreezeRevert(set, _precheck(4));
        vm.roll(uint256(deadline) + 1);
        expectFreezeRevert(set, _precheck(5));
        set.components.steward = address(0);
        expectFreezeRevert(set, _precheck(6));
        set.dependencyRoot = DEPS;
        expectFreezeRevert(set, _precheck(7));
        set.capabilities = 1;
        expectFreezeRevert(set, _precheck(8));
        set.limits.maxActions = 64;
        freeze(seal(set));
        (,, uint32 rev, bool frozen) = hot.control();
        assertEq(rev, 3);
        assertTrue(frozen);
        assertEq(transitionWord().target, 0, "the expired transition was closed by the freeze");
    }

    /// DESIGN-DIVERGENCE: §8.10 pre-check 8 requires "every maximum in finalSet.limits ≥ the current
    /// revision's". `_limitsSuperset` (src/core/LedgerControl.sol:138-146) omits `maxTransitionBlocks`
    /// and the advisory `maxFreshSlotsPerPublication`, so smaller values of both are accepted (benign:
    /// no transition can begin after the freeze, and the fresh-slot maximum is never a refusal). The
    /// floors and `kernelTail` are not maxima and are unconstrained; only the controller's canaries
    /// (§8.10 step 7) prove the terminal envelope still admits a write.
    function test_freeze_accepts_smaller_transition_and_fresh_slot_maxima() public {
        ActivationSet memory set = _finalSet();
        set.limits.maxTransitionBlocks = 1;
        set.limits.maxFreshSlotsPerPublication = 1;
        freeze(seal(set));
        (,,, bool frozen) = hot.control();
        assertTrue(frozen);
        assertEq(revisionRow(2).limits.maxTransitionBlocks, 1);
    }

    // =============================================================================================
    // The gate
    // =============================================================================================

    function test_stranger_freeze_E_NOT_CONTROLLER() public {
        ActivationSet memory set = _finalSet();
        registry.setActiveRevision(2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.freeze(set);
        (,,, bool frozen) = hot.control();
        assertFalse(frozen);
    }

    function test_freeze_with_wrong_expected_set_reverts_and_leaves_the_realm_live() public {
        publishMarker("m");
        bytes32 digest = fullDigest(2);
        ActivationSet memory set = _finalSet();
        bytes32 actual = executionSetOf(set);
        set.expectedExecutionSet = DEPS;
        expectFreezeRevert(set, abi.encodeWithSelector(E_EXPECTED_SET.selector, DEPS, actual));
        assertEq(fullDigest(2), digest);
        (,,, bool frozen) = hot.control();
        assertFalse(frozen);
    }

    // =============================================================================================
    // A successful freeze and the frozen Realm
    // =============================================================================================

    function test_successful_freeze_sets_frozen_and_flag_b0() public {
        publishMarker("m1");
        publishMarker("m2");
        bytes32 retained = retainedDigest(1);
        ActivationSet memory set = _finalSet();
        registry.setActiveRevision(2);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.Activated(
            2,
            executionSetOf(set),
            uint64(vm.getBlockNumber()),
            uint64(2),
            FLAG_FROZEN | FLAG_SAME_CODE
        );
        ctl.freeze(set);

        (uint64 genesisChain, uint64 accepted, uint32 rev, bool frozen) = hot.control();
        assertTrue(frozen);
        assertEq(rev, 2);
        assertEq(genesisChain, vm.getChainId());
        assertEq(accepted, vm.getChainId());
        (,,, uint8 frozenBit) = Layout.unpackRealmStorageWord3(realmWord(3));
        assertEq(frozenBit, 1);
        Rev memory r = revisionRow(2);
        assertEq(r.flags & FLAG_FROZEN, FLAG_FROZEN);
        assertEq(r.flags, FLAG_FROZEN | FLAG_SAME_CODE);
        assertEq(r.dependencyRoot, DEPS);
        assertEq(r.executionSet, hot.executionSet());
        assertEq(hot.executionSet(), executionSetOf(set));
        assertEq(initializedVersion(), 3);
        assertEq(revisionRow(1).flags & FLAG_FROZEN, 0);
        assertEq(retainedDigest(1), retained, "retained rows and revision row 1 unchanged");
    }

    function test_after_freeze_activate_freeze_and_beginTransition_E_FROZEN() public {
        freeze(_finalSet());
        bytes memory frozen = abi.encodeWithSelector(E_FROZEN.selector);
        ActivationSet memory set = nextSet();
        expectActivateRevert(set, frozen);
        set.dependencyRoot = DEPS;
        expectFreezeRevert(seal(set), frozen);
        uint48 d = uint48(vm.getBlockNumber() + 100);
        vm.expectRevert(frozen);
        ctl.beginTransition(3, d);
        // a stranger meets the controller gate first
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.activate(set);
    }

    /// DESIGN-DIVERGENCE: §8.10 lists `abortTransition` among the paths that revert E_FROZEN after the
    /// §8.10: after the freeze every control entry, `abortTransition` included, refuses with E_FROZEN.
    function test_after_freeze_abortTransition_E_FROZEN() public {
        freeze(_finalSet());
        vm.expectRevert(E_FROZEN.selector);
        ctl.abortTransition();
    }

    function test_after_freeze_writes_land_and_reads_work() public {
        (, bytes32 before) = publishMarker("before");
        freeze(_finalSet());
        (uint64 publication, bytes32 subject) = publishMarker("after");
        assertEq(publication, 2);
        assertEq(hot.subjectCreatedAt(before), 1);
        assertEq(hot.subjectCreatedAt(subject), 2);
        (uint64 admissions,,, uint64 publications) = hot.counts();
        assertEq(admissions, 2);
        assertEq(publications, 2);
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 2);
        (uint64 at,) = hot.publicationAt(principal, 1);
        assertEq(at, 2);
        assertEq(index.prefixCalls(), 2, "the frozen generation keeps indexing");
        assertEq(revisionRow(2).flags & FLAG_FROZEN, FLAG_FROZEN);
    }

    /// §8.9: a chain-acceptance change is refused after the freeze; a frozen Realm is read-only on a fork.
    function test_after_freeze_a_fork_is_read_only() public {
        publishMarker("m");
        freeze(_finalSet());
        uint64 genesisChain = uint64(vm.getChainId());
        uint64 fork = genesisChain + 1;
        vm.chainId(fork);
        expectWriteRevert("fork", abi.encodeWithSelector(E_CHAIN.selector, genesisChain, fork));
        ActivationSet memory set = nextSet();
        set.acceptedChainId = fork;
        expectActivateRevert(seal(set), abi.encodeWithSelector(E_FROZEN.selector));
        assertEq(hot.subjectCreatedAt(markerSubjects[0]), 1, "reads still work");
    }
}
