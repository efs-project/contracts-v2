// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {E_PUBLICATION_ACTIVE} from "../../src/interfaces/Errors.sol";
import {ControlFixture} from "../harness/ControlFixture.sol";
import {BaseIndexDouble} from "../harness/doubles/IndexDoubles.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {Effect} from "../../src/interfaces/Index.sol";
import {
    E_DEADLINE_BOUND,
    E_NOT_CONTROLLER,
    E_REVISION,
    E_TRANSITION,
    E_TRANSITION_COOLDOWN,
    E_TRANSITION_TARGET
} from "../../src/interfaces/Errors.sol";

/// @notice An honest index double that, from its first prefix callback, calls `abortTransition()` on the
///         ledger mid-publication and records whether the call succeeded (design §8.7 idle gate).
contract AbortingIndex is BaseIndexDouble {
    bool public attempted;
    bool public aborted;
    bytes public reason;

    constructor(address ledger_) BaseIndexDouble(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        if (!attempted) {
            attempted = true;
            (aborted, reason) = ledger.call(abi.encodeCall(ILedgerControl.abortTransition, ()));
        }
        return super.onAdmission(publication, effects, refs);
    }
}

/// @notice Design §8.8 at the ledger level: `beginTransition` / `abortTransition`, the write refusal while a
///         transition is open, expiry with no call, the spent-target rule, the cooldown, and how activation
///         closes a transition (`TransitionEnded` how = 1 activated, 2 aborted, 3 expired).
contract TransitionTest is ControlFixture {
    uint32 internal constant MAX_BLOCKS = 7_200; // KernelDeploy.s1Limits().maxTransitionBlocks

    function setUp() public override {
        super.setUp();
        vm.roll(1_000);
    }

    function _begin(uint32 target, uint48 deadline) internal {
        ctl.beginTransition(target, deadline);
    }

    // =============================================================================================
    // beginTransition refusals
    // =============================================================================================

    function test_beginTransition_requires_the_next_ordinal_E_REVISION() public {
        uint48 d = uint48(vm.getBlockNumber() + 10);
        vm.expectRevert(abi.encodeWithSelector(E_REVISION.selector, uint32(2), uint32(3)));
        ctl.beginTransition(3, d);
        vm.expectRevert(abi.encodeWithSelector(E_REVISION.selector, uint32(2), uint32(1)));
        ctl.beginTransition(1, d);
    }

    function test_deadline_in_the_past_E_DEADLINE_BOUND() public {
        uint48 d = uint48(vm.getBlockNumber() - 1);
        vm.expectRevert(abi.encodeWithSelector(E_DEADLINE_BOUND.selector, d, MAX_BLOCKS));
        ctl.beginTransition(2, d);
    }

    function test_deadline_beyond_maxTransitionBlocks_E_DEADLINE_BOUND() public {
        uint48 d = uint48(vm.getBlockNumber() + MAX_BLOCKS + 1);
        vm.expectRevert(abi.encodeWithSelector(E_DEADLINE_BOUND.selector, d, MAX_BLOCKS));
        ctl.beginTransition(2, d);
        // the bound itself is inclusive
        _begin(2, uint48(vm.getBlockNumber() + MAX_BLOCKS));
        assertEq(transitionWord().deadline, vm.getBlockNumber() + MAX_BLOCKS);
    }

    function test_stranger_beginTransition_E_NOT_CONTROLLER() public {
        uint48 d = uint48(vm.getBlockNumber() + 10);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.beginTransition(2, d);
    }

    // =============================================================================================
    // Open transition, expiry, the spent target
    // =============================================================================================

    function test_begin_emits_TransitionBegun_and_writes_wait_until_the_deadline() public {
        publishMarker("before");
        uint48 d = uint48(vm.getBlockNumber() + 100);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionBegun(2, d);
        _begin(2, d);
        TransitionWord memory t = transitionWord();
        assertEq(t.target, 2);
        assertEq(t.deadline, d);
        assertEq(t.lastTarget, 2);
        assertEq(t.cooldownUntil, 0);

        bytes memory refused = abi.encodeWithSelector(E_TRANSITION.selector, uint32(2), d);
        expectWriteRevert("during", refused);
        vm.roll(d); // the deadline block itself is still inside the transition
        expectWriteRevert("at-deadline", refused);

        // after the deadline writes resume with no call
        vm.roll(uint256(d) + 1);
        (uint64 publication,) = publishMarker("after");
        assertEq(publication, 2);
        assertEq(transitionWord().target, 2, "expiry is lazy: the word is untouched");
        assertEq(hot.revision(), 1);
    }

    function test_the_same_target_can_never_be_begun_again() public {
        uint48 d = uint48(vm.getBlockNumber() + 100);
        _begin(2, d);
        bytes memory spent = abi.encodeWithSelector(E_TRANSITION_TARGET.selector, uint32(2));
        // while open
        vm.expectRevert(spent);
        ctl.beginTransition(2, d);
        // after expiry
        vm.roll(uint256(d) + 1);
        uint48 d2 = uint48(vm.getBlockNumber() + 100);
        vm.expectRevert(spent);
        ctl.beginTransition(2, d2);
        // after an abort, past any cooldown
        ctl.abortTransition();
        vm.roll(vm.getBlockNumber() + MAX_BLOCKS + 1);
        uint48 d3 = uint48(vm.getBlockNumber() + 100);
        vm.expectRevert(spent);
        ctl.beginTransition(2, d3);
    }

    function test_later_target_after_activation_waits_for_the_cooldown() public {
        _begin(2, uint48(vm.getBlockNumber() + 100));
        ctl.abortTransition();
        uint48 until = uint48(vm.getBlockNumber() + MAX_BLOCKS);
        assertEq(transitionWord().cooldownUntil, until);
        vm.expectRevert(abi.encodeWithSelector(E_TRANSITION_TARGET.selector, uint32(2)));
        ctl.beginTransition(2, uint48(vm.getBlockNumber() + 100));

        activate(nextSet()); // revision 2: the next pause needs a later target, hence this activation
        uint48 d = uint48(vm.getBlockNumber() + 100);
        vm.expectRevert(abi.encodeWithSelector(E_TRANSITION_COOLDOWN.selector, until));
        ctl.beginTransition(3, d);
        vm.roll(uint256(until) - 1);
        d = uint48(vm.getBlockNumber() + 100);
        vm.expectRevert(abi.encodeWithSelector(E_TRANSITION_COOLDOWN.selector, until));
        ctl.beginTransition(3, d);

        vm.roll(until);
        d = uint48(vm.getBlockNumber() + 100);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionBegun(3, d);
        ctl.beginTransition(3, d);
        assertEq(transitionWord().target, 3);
        assertEq(transitionWord().lastTarget, 3);
    }

    // =============================================================================================
    // abortTransition
    // =============================================================================================

    function test_controller_abort_before_the_deadline_ends_it_with_how_2() public {
        uint48 d = uint48(vm.getBlockNumber() + 100);
        _begin(2, d);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionEnded(2, 2);
        ctl.abortTransition();
        TransitionWord memory t = transitionWord();
        assertEq(t.target, 0);
        assertEq(t.deadline, 0);
        assertEq(t.lastTarget, 2);
        assertEq(t.cooldownUntil, vm.getBlockNumber() + MAX_BLOCKS);
        publishMarker("reopened");
    }

    function test_stranger_abort_refused_before_the_deadline_allowed_after_it() public {
        uint48 d = uint48(vm.getBlockNumber() + 100);
        _begin(2, d);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.abortTransition();
        vm.roll(d); // still inside
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, stranger));
        ctl.abortTransition();

        vm.roll(uint256(d) + 1);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionEnded(2, 2);
        vm.prank(stranger);
        ctl.abortTransition();
        assertEq(transitionWord().target, 0);
        assertEq(transitionWord().cooldownUntil, vm.getBlockNumber() + MAX_BLOCKS);
    }

    function test_abort_with_none_open_E_TRANSITION_TARGET_0() public {
        bytes memory none = abi.encodeWithSelector(E_TRANSITION_TARGET.selector, uint32(0));
        vm.expectRevert(none);
        ctl.abortTransition();
        vm.prank(stranger);
        vm.expectRevert(none);
        ctl.abortTransition();
        // and again once one was aborted
        _begin(2, uint48(vm.getBlockNumber() + 100));
        ctl.abortTransition();
        vm.expectRevert(none);
        ctl.abortTransition();
    }

    /// DESIGN-DIVERGENCE: §8.7 gates `LedgerCore.abortTransition` with "onlyController; phase == IDLE" and
    /// §2.2 S1 requires IDLE for every transition call. `LedgerCore.abortTransition`
    /// (src/core/LedgerCore.sol:139-141) carries no `idle` (and no `notFrozen`) modifier and the delegate
    /// body (src/core/LedgerControl.sol:446-457) has no phase check, so an index callback can abort an
    /// expired transition from inside a publication. After the deadline anyone may abort anyway, so the
    /// only extra power is doing it mid-publication (the transition word and the cooldown move under a
    /// staged publication).
    /// §8.7 / §2.2 S1: an index callback cannot abort an expired transition from inside a publication;
    /// the idle gate refuses it and the transition stays open for an idle caller.
    function test_abortTransition_is_idle_gated() public {
        AbortingIndex idx = new AbortingIndex(k.proxy);
        idx.setManifestHash(keccak256("efs2/test/control/aborting-index"));
        idx.setReadiness(liveReadiness(idx));
        activate(withIndex(nextSet(), address(idx))); // revision 2
        uint48 d = uint48(vm.getBlockNumber() + 10);
        _begin(3, d);
        vm.roll(uint256(d) + 1);

        publishMarker("mid-publication-abort");

        assertTrue(idx.attempted());
        assertFalse(idx.aborted(), "abortTransition must be refused inside the publication");
        assertEq(bytes4(idx.reason()), E_PUBLICATION_ACTIVE.selector);
        TransitionWord memory t = transitionWord();
        assertEq(t.target, 3, "the expired transition is still open");
        // idle again: anyone may abort the expired transition
        ctl.abortTransition();
        t = transitionWord();
        assertEq(t.target, 0);
        assertEq(t.cooldownUntil, vm.getBlockNumber() + MAX_BLOCKS);
    }

    // =============================================================================================
    // Activation closes a transition
    // =============================================================================================

    function test_activate_during_an_open_transition_ends_it_with_how_1() public {
        uint48 d = uint48(vm.getBlockNumber() + 100);
        _begin(2, d);
        ActivationSet memory set = nextSet();
        registry.setActiveRevision(2);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionEnded(2, 1);
        ctl.activate(set);
        TransitionWord memory t = transitionWord();
        assertEq(t.target, 0);
        assertEq(t.deadline, 0);
        assertEq(t.lastTarget, 2, "lastTarget is untouched by activate");
        assertEq(t.cooldownUntil, 0);
        publishMarker("reopened-by-activation");
    }

    /// KERNEL-BUG: `_closeTransition` (src/core/LedgerControl.sol:397-408) tests `target == activated`
    /// before the expiry branch. Every transition targets `revision + 1` (beginTransition, :421) and every
    /// activation is `revision + 1` (:153), so an activation that follows an unobserved expiry always takes
    /// the first branch: it emits TransitionEnded(target, 1) instead of 3 and never sets
    /// `cooldownUntil := deadline + maxTransitionBlocks` (§8.3 j, §8.8, §16.4 "the next beginTransition/activate
    /// emits TransitionEnded(3)"). The expiry branch is dead code, and so is beginTransition's (:423-429,
    /// reachable only before genesis, where it reverts E_TRANSITION). Consequence: after an expired pause
    /// plus an activation the controller can open the next pause immediately, with no cooldown.
    function test_activation_after_an_unobserved_expiry_ends_it_with_how_3() public {
        uint48 d = uint48(vm.getBlockNumber() + 100);
        _begin(2, d);
        vm.roll(uint256(d) + 1);
        publishMarker("after-expiry");
        ActivationSet memory set = nextSet();
        registry.setActiveRevision(2);
        vm.expectEmit(k.proxy);
        emit ILedgerControl.TransitionEnded(2, 3);
        ctl.activate(set);
        assertEq(transitionWord().cooldownUntil, uint256(d) + MAX_BLOCKS);
    }
}
