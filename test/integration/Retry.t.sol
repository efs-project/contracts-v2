// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../harness/KernelFixture.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {RecordingIndex} from "../harness/doubles/RecordingIndex.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Action, Native} from "../../src/interfaces/Actions.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {
    AlreadyAdmitted,
    E_ACCEPTANCE_PROFILE,
    E_EXECUTION_SET,
    E_EXPIRED,
    E_NONCE
} from "../../src/interfaces/Errors.sol";

/// @notice PM behaviour 4 at S1 (design §16.2 item 4, I4, §6.1 step 3, §6.6): an exact native retry reverts
///         `AlreadyAdmitted(ordinal)` with no state change at any later block, whatever happened in between,
///         because the retry compare precedes every check whose outcome can change with time or Realm state;
///         bound expectations refuse new plans, never admitted ones; and the recovery classifier of
///         docs/RECOVERY.md over `publicationAt` and the block timestamp.
contract RetryTest is KernelFixture {
    enum Recovery {
        UNSET,
        COMMITTED,
        NOT_COMMITTED_PROVEN,
        UNKNOWN
    }

    struct Plan {
        Action[] actions;
        bytes[] bodies;
        Native ctx;
        bytes32 digest; // computed offline from plan-intrinsic inputs and two Realm constants
    }

    bytes32 internal constant TYPE_P = keccak256("retry/type/plan");

    function setUp() public override {
        super.setUp();
        _registerType(TYPE_P, address(acceptAll));
        vm.warp(1_000_000);
    }

    function _plan(bytes memory body, Native memory ctx) internal view returns (Plan memory p) {
        p.actions = _acts(_publish(TYPE_P, body));
        p.bodies = _bodies(1, 0, body);
        p.ctx = ctx;
        p.digest = keccak256(
            abi.encode(
                Keys.DOM_NATIVE_INTENT,
                hot.realmId(),
                principal,
                ctx.nonce,
                ctx.deadline,
                ctx.expectedExecutionSet,
                ctx.expectedAcceptanceProfile,
                keccak256(""),
                keccak256(abi.encode(p.actions))
            )
        );
    }

    function _bound(bytes memory body, uint64 nonce) internal view returns (Plan memory) {
        Action[] memory a = _acts(_publish(TYPE_P, body));
        return _plan(
            body, _native(nonce, 0, hot.executionSet(), commitments.acceptanceProfileOf(k.proxy, a))
        );
    }

    function _submit(Plan memory p) internal returns (uint64 publication) {
        _track(principal, p.actions);
        (publication,) = ledger.execute(p.actions, p.bodies, p.ctx, "");
    }

    function _refused(Plan memory p, bytes memory err) internal {
        _expectNoChange(p.actions, p.bodies, p.ctx, err);
    }

    function _retried(Plan memory p, uint64 publication) internal {
        _refused(p, abi.encodeWithSelector(AlreadyAdmitted.selector, publication));
    }

    /// docs/RECOVERY.md, read at one block: COMMITTED iff the nonce's ordinal is set and its stored digest is
    /// the plan's; NOT_COMMITTED_PROVEN iff another plan took the nonce, or nothing did and the deadline passed.
    function _classify(Plan memory p) internal view returns (Recovery) {
        (uint64 ordinal, bytes32 stored) = hot.publicationAt(principal, p.ctx.nonce);
        if (ordinal != 0) {
            return stored == p.digest ? Recovery.COMMITTED : Recovery.NOT_COMMITTED_PROVEN;
        }
        if (p.ctx.deadline != 0 && block.timestamp > p.ctx.deadline) {
            return Recovery.NOT_COMMITTED_PROVEN;
        }
        return Recovery.UNKNOWN;
    }

    function _setPolicy(bytes32 t, address policy, uint16 row) internal {
        TypeInfo memory info = _nativeType(address(acceptAll));
        (info.policy, info.policyCodehash, info.policyRow, info.policyRows) =
        (policy, policy.codehash, row, row);
        registry.setType(t, info, new bytes32[](0));
        registry.bumpMutations(); // what the real registry's activatePolicy does
    }

    // ---- (a) blocks pass, (b) another principal publishes ---------------------------------------------------

    function test_exact_retry_AlreadyAdmitted_after_blocks_pass() public {
        Plan memory p = _plan("retry/a", _native(0));
        uint64 pub = _submit(p);
        vm.roll(block.number + 50_000);
        vm.warp(block.timestamp + 365 days);
        _retried(p, pub);
        assertEq(uint8(_classify(p)), uint8(Recovery.COMMITTED));
    }

    function test_exact_retry_AlreadyAdmitted_after_another_principal_published() public {
        Plan memory p = _plan("retry/b", _native(0));
        uint64 pub = _submit(p);
        _execAs(makeAddr("alice"), _acts(_publish(TYPE_P, "retry/b")), _bodies(1, 0, "retry/b"));
        _retried(p, pub);
    }

    // ---- (c) a policy activation on the plan's Type ---------------------------------------------------------

    function test_exact_retry_AlreadyAdmitted_after_policy_activation_on_plan_type() public {
        Plan memory landed = _plan("retry/c/1", _native(0));
        Plan memory pending = _plan("retry/c/2", _native(1)); // unbound, prepared before the change
        uint64 pub = _submit(landed);
        _setPolicy(TYPE_P, address(new AcceptAll()), 2);
        _retried(landed, pub);
        _submit(pending); // an unbound plan is not voided by the activation
        assertEq(uint8(_classify(pending)), uint8(Recovery.COMMITTED));
    }

    function test_bound_plan_across_policy_activation() public {
        Plan memory landed = _bound("retry/c/3", 0);
        Plan memory pending = _bound("retry/c/4", 1); // bound, prepared before the change
        uint64 pub = _submit(landed);
        _retried(landed, pub);
        _setPolicy(TYPE_P, address(new AcceptAll()), 2);
        _retried(landed, pub); // the compare precedes the profile check
        bytes32 live = commitments.acceptanceProfileOf(k.proxy, pending.actions);
        assertTrue(live != pending.ctx.expectedAcceptanceProfile);
        _refused(
            pending,
            abi.encodeWithSelector(
                E_ACCEPTANCE_PROFILE.selector, pending.ctx.expectedAcceptanceProfile, live
            )
        );
        assertEq(_nonce(principal), 1, "the refused plan's nonce is intact");
        _submit(_bound("retry/c/4", 1)); // re-prepared under the new profile, it lands
    }

    // ---- (d) deadlines ----------------------------------------------------------------------------------------

    function test_exact_retry_AlreadyAdmitted_after_deadline() public {
        uint64 deadline = uint64(block.timestamp + 100);
        Plan memory p = _plan("retry/d", _native(0, deadline, 0, 0));
        uint64 pub = _submit(p);
        vm.warp(deadline + 1);
        _retried(p, pub); // the compare precedes the deadline
        Plan memory late = _plan("retry/d/late", _native(1, deadline, 0, 0));
        _refused(
            late, abi.encodeWithSelector(E_EXPIRED.selector, deadline, uint64(block.timestamp))
        );
        // a different plan under the consumed nonce is E_NONCE even though its deadline also passed
        Plan memory other = _plan("retry/d/other", _native(0, deadline, 0, 0));
        _refused(other, abi.encodeWithSelector(E_NONCE.selector, principal, uint64(0), pub));
        vm.warp(deadline); // at the deadline itself the plan is still live
        _submit(late);
    }

    // ---- (e) execution-set expectations, activation and index replacement ---------------------------------

    function test_expected_execution_set_wrong_is_E_EXECUTION_SET() public {
        bytes32 live = hot.executionSet();
        Plan memory p = _plan("retry/e", _native(0, 0, keccak256("not the set"), 0));
        _refused(
            p, abi.encodeWithSelector(E_EXECUTION_SET.selector, keccak256("not the set"), live)
        );
    }

    function test_exact_retry_AlreadyAdmitted_after_activation() public {
        Plan memory landed = _bound("retry/f/1", 0);
        Plan memory bound = _bound("retry/f/2", 1);
        Plan memory unbound = _plan("retry/f/3", _native(1));
        uint64 pub = _submit(landed);
        bytes32 old = hot.executionSet();
        _activateNext(index, KernelDeploy.s1Limits()); // same-code reactivation: revision + 1
        _retried(landed, pub);
        _refused(bound, abi.encodeWithSelector(E_EXECUTION_SET.selector, old, hot.executionSet()));
        assertEq(_nonce(principal), 1, "nonce intact");
        _submit(unbound);
    }

    function test_exact_retry_AlreadyAdmitted_after_index_replacement() public {
        Plan memory p = _plan("retry/g", _native(0));
        uint64 pub = _submit(p);
        _useIndex(address(new RecordingIndex(k.proxy)));
        _retried(p, pub);
    }

    // ---- the recovery classifier --------------------------------------------------------------------------------

    function test_offline_digest_equals_stored_w3() public {
        Plan memory p = _plan("retry/v", _native(0, uint64(block.timestamp + 5), 0, 0));
        assertEq(
            p.digest,
            commitments.nativeIntentDigest(
                hot.realmId(), principal, p.ctx, keccak256(abi.encode(p.actions)), keccak256("")
            )
        );
        _submit(p);
        uint256 w3 = Layout.publicationsEvidenceSlot(1) + 3;
        assertEq(_raw(w3), p.digest);
    }

    function test_classifier_COMMITTED_and_second_device_NOT_COMMITTED_PROVEN() public {
        Plan memory p = _plan("retry/h/1", _native(0, uint64(block.timestamp + 100), 0, 0));
        Plan memory q = _plan("retry/h/2", _native(0, uint64(block.timestamp + 100), 0, 0));
        assertEq(uint8(_classify(p)), uint8(Recovery.UNKNOWN), "in flight");
        uint64 pub = _submit(p);
        assertEq(uint8(_classify(p)), uint8(Recovery.COMMITTED));
        assertEq(uint8(_classify(q)), uint8(Recovery.NOT_COMMITTED_PROVEN), "the second device");
        _refused(q, abi.encodeWithSelector(E_NONCE.selector, principal, uint64(0), pub));
        vm.warp(block.timestamp + 1_000);
        assertEq(uint8(_classify(p)), uint8(Recovery.COMMITTED), "stable after the deadline");
    }

    function test_classifier_deadline_proves_absence_and_no_deadline_stays_UNKNOWN() public {
        Plan memory lost = _plan("retry/i/1", _native(0, uint64(block.timestamp + 10), 0, 0));
        Plan memory open = _plan("retry/i/2", _native(0));
        vm.warp(block.timestamp + 11);
        assertEq(uint8(_classify(lost)), uint8(Recovery.NOT_COMMITTED_PROVEN));
        _refused(
            lost,
            abi.encodeWithSelector(E_EXPIRED.selector, lost.ctx.deadline, uint64(block.timestamp))
        );
        vm.warp(block.timestamp + 3650 days);
        assertEq(
            uint8(_classify(open)), uint8(Recovery.UNKNOWN), "an undated plan is never proven lost"
        );
        _submit(open); // and can still land exactly once
        assertEq(uint8(_classify(open)), uint8(Recovery.COMMITTED));
    }

    function test_deadline_uint64_max_round_trips() public {
        Plan memory p = _plan("retry/j", _native(0, type(uint64).max, 0, 0));
        _submit(p);
        (, uint64 deadline,,,) =
            Layout.unpackEvidenceCellWord1(_raw(Layout.publicationsEvidenceSlot(1) + 1));
        assertEq(deadline, type(uint64).max, "full width, never truncated");
        Plan memory never = _plan("retry/j/2", _native(1, type(uint64).max, 0, 0));
        vm.warp(type(uint64).max);
        assertEq(uint8(_classify(p)), uint8(Recovery.COMMITTED));
        assertEq(uint8(_classify(never)), uint8(Recovery.UNKNOWN));
    }
}
