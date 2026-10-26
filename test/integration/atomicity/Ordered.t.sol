// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {KernelDeploy} from "../../harness/KernelDeploy.sol";
import {MockRegistry, MutatingRegistry} from "../../harness/doubles/MockRegistry.sol";
import {
    AttackIndex,
    BaseIndexDouble,
    BudgetBurning,
    IndexDoubleCore,
    LateRefusing,
    LegacyFallback,
    MalformedFinal,
    MutatingRule,
    OversizedCallback,
    PhaseRefusing,
    PrefixAgreement,
    WritingFinal
} from "../../harness/doubles/IndexDoubles.sol";
import {ACCEPTOR_REFUSAL} from "../../harness/doubles/Acceptors.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {Phase} from "../../../src/interfaces/Results.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../../src/interfaces/ILedgerControl.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {Effect, WorkModel} from "../../../src/interfaces/Index.sol";
import {
    E_INDEX_ACK,
    E_INDEX_CALL,
    E_INDEX_GAS,
    E_INDEX_RETURNDATA,
    E_NONCE,
    E_NOT_CONTROLLER,
    E_PUBLICATION_ACTIVE,
    E_REGISTRY_DRIFT,
    E_REJECTED
} from "../../../src/interfaces/Errors.sol";

/// An index whose prefix call reverts with the constructor's bytes (a forged kernel error).
contract ForgedRevertIndex is BaseIndexDouble {
    bytes internal _data;

    constructor(address ledger_, bytes memory data) BaseIndexDouble(ledger_) {
        _data = data;
    }

    function onAdmission(uint64, Effect[] calldata, bytes32[] calldata)
        public
        view
        override
        returns (bytes4)
    {
        _requireLedger();
        bytes memory d = _data;
        assembly ("memory-safe") {
            revert(add(d, 0x20), mload(d))
        }
    }
}

/// CoreAcceptanceAudit: a rule that accepts only when the ledger's staged frontier and the index both show
/// exactly the ordered prefix before its own leaf.
contract PrefixObservingRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        (uint8 phase,,,) = ILedgerHot(ctx.ledger).phase();
        (uint64 admissions,,,) = ILedgerHot(ctx.ledger).counts();
        bool prefix = admissions == ctx.admission - 1
            && IndexDoubleCore(ctx.index).lastProcessed() == ctx.admission - 1;
        return phase == Phase.APPLYING && prefix ? IAcceptor.accept.selector : ACCEPTOR_REFUSAL;
    }
}

/// CoreAcceptanceAudit's singleton: accepts only while the required index has seen no effect at all.
contract SingletonRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        return IndexDoubleCore(ctx.index).effectsSeen() == 0
            ? IAcceptor.accept.selector
            : ACCEPTOR_REFUSAL;
    }
}

/// @notice Ordered single-pass atomicity against the ten index doubles (design §6.4–§6.6, I2, §2.2 S1/S4/S13;
///         ports of CoreOrderedAcceptance, MatchedRollback and CoreAcceptanceAudit). Every refusal leaves the
///         raw-slot digest and the index double's prefix record unchanged.
contract OrderedTest is KernelFixture {
    error Bypassed();

    MutatingRegistry internal mutating;

    function _newRegistry() internal override returns (MockRegistry) {
        mutating = new MutatingRegistry();
        mutating.arm(false);
        return mutating;
    }

    /// The controller relay for re-entry attempts: an index callback calls this, this calls the ledger as the
    /// controller, and the ledger's refusal is bubbled verbatim (success reverts `Bypassed`).
    function reenter(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = k.proxy.call(data);
        if (ok) revert Bypassed();
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    function _mixed() internal pure returns (Action[] memory a, bytes[] memory b) {
        a = _acts(_create("ordered/c"), _publish(TYPE_OK, "ordered/p"));
        b = _bodies(2, 1, "ordered/p");
    }

    function _call(bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_INDEX_CALL.selector, inner);
    }

    function _refuseMixed(bytes memory err) internal {
        (Action[] memory a, bytes[] memory b) = _mixed();
        _expectNoChange(a, b, err);
    }

    // ---- 1 PrefixAgreement --------------------------------------------------------------------------------

    function test_prefix_agreement_every_kind_agrees_with_the_staged_state() public {
        PrefixAgreement agree = new PrefixAgreement(k.proxy);
        _useIndex(address(agree));
        bytes memory d = hex"0102";
        bytes32 r = _rid(TYPE_OK, d);
        Action[] memory a = new Action[](10);
        (a[0], a[1], a[2], a[3]) =
        (_publish(TYPE_OK, d), _publish(TYPE_OK, d), _reuse(TYPE_OK, r), _withdraw(2));
        (a[4], a[5], a[6], a[7]) =
        (
            _bind(FOLDER, r, 0, r, 0),
            _bind(FOLDER, r, 0, r, 1),
            _unbind(FOLDER, r, 0, 2),
            _withdraw(1)
        );
        (a[8], a[9]) = (_release(FOLDER, r, 0, 3), _create("ordered/agree"));
        bytes[] memory b = new bytes[](10);
        (b[0], b[1]) = (d, d);
        _exec(a, b);
        assertEq(abi.encode(agree.prefixCalls(), agree.lastProcessed()), abi.encode(10, 10));
        (,,, uint64 occ,) = hot.recordHeader(r);
        assertEq(occ, 1, "three occurrences, two withdrawn");
    }

    // ---- 2 PhaseRefusing (and a reader inside the final phase sees phase != IDLE) ----------------------------

    function test_phase_refusing_prefix_and_final_roll_back() public {
        PhaseRefusing honest = new PhaseRefusing(k.proxy, 0, false);
        _useIndex(address(honest));
        (Action[] memory a, bytes[] memory b) = _mixed();
        _exec(a, b); // prefix observed APPLYING, final observed FINAL (else E_PHASE)
        assertEq(honest.prefixCalls(), 2);
        _useIndex(address(new PhaseRefusing(k.proxy, 4, false)));
        a = _acts(_create("ordered/c2"), _publish(TYPE_OK, "ordered/p2"));
        b = _bodies(2, 1, "ordered/p2");
        _expectNoChange(a, b, _call(abi.encodeWithSelector(PhaseRefusing.E_PREFIX.selector, 4)));
        _useIndex(address(new PhaseRefusing(k.proxy, 0, true)));
        _expectNoChange(a, b, _call(abi.encodeWithSelector(PhaseRefusing.E_FINAL.selector)));
    }

    // ---- 3 LegacyFallback, 4 MalformedFinal -----------------------------------------------------------------

    // DESIGN-DIVERGENCE: §5.6 names E_INDEX_FINAL() for a final acknowledgement mismatch; the code raises
    // E_INDEX_ACK(3) (src/core/LedgerIngress.sol:708), an error the design catalog does not list.
    function test_legacy_fallback_final_ack_is_E_INDEX_ACK_3() public {
        _useIndex(address(new LegacyFallback(k.proxy)));
        _refuseMixed(abi.encodeWithSelector(E_INDEX_ACK.selector, uint8(3)));
    }

    function test_malformed_final_reply_lengths_are_E_INDEX_RETURNDATA() public {
        uint256[4] memory lengths = [uint256(33), 31, 64, 0];
        for (uint256 i; i < lengths.length; ++i) {
            _useIndex(address(new MalformedFinal(k.proxy, lengths[i])));
            _refuseMixed(abi.encodeWithSelector(E_INDEX_RETURNDATA.selector, lengths[i]));
        }
    }

    // ---- 5 WritingFinal ----------------------------------------------------------------------------------------

    // DESIGN-DIVERGENCE: I11 says gas-class refusals name what was quoted and what was available; a final
    // callback that fails with empty returndata (here: an SSTORE under STATICCALL) is E_INDEX_GAS(0, 0)
    // because dispatchFinal passes (0, 0) to _ack (src/core/LedgerIngress.sol:686). Retry class: resubmit,
    // although a static-write failure is permanent.
    function test_writing_final_direct_and_nested() public {
        WritingFinal direct = new WritingFinal(k.proxy, false);
        _useIndex(address(direct));
        _refuseMixed(abi.encodeWithSelector(E_INDEX_GAS.selector, uint32(0), uint32(0)));
        WritingFinal nested = new WritingFinal(k.proxy, true);
        _useIndex(address(nested));
        _refuseMixed(_call(abi.encodeWithSelector(WritingFinal.E_FINAL_WRITE.selector)));
        assertEq(direct.finalWrites() + nested.finalWrites(), 0);
    }

    // ---- 6 OversizedCallback -----------------------------------------------------------------------------------

    function test_callback_returndata_is_bounded_before_copy() public {
        for (uint256 i; i < 2; ++i) {
            OversizedCallback big = new OversizedCallback(k.proxy, 4_097, i == 0);
            _useIndex(address(big));
            _refuseMixed(abi.encodeWithSelector(E_INDEX_RETURNDATA.selector, uint256(4_097)));
            assertEq(big.touched(), 0);
        }
        _useIndex(address(new OversizedCallback(k.proxy, 4_096, true)));
        bytes memory inner = new bytes(4_096);
        bytes4 s = OversizedCallback.E_OVERSIZED.selector;
        for (uint256 j; j < 4; ++j) {
            inner[j] = s[j];
        }
        _refuseMixed(_call(inner)); // 4,096 bytes are nested verbatim (4,164 B with the wrapper)
    }

    // ---- 7 BudgetBurning and the availability floor ---------------------------------------------------------

    function test_callback_that_burns_everything_is_E_INDEX_GAS_after_the_call() public {
        _useIndex(address(new BudgetBurning(k.proxy, type(uint256).max, 0)));
        (Action[] memory a, bytes[] memory b) = _mixed();
        (uint32 floor,,,) = commitments.indexFloor(k.proxy, a);
        bytes memory err = _refusedWithGas(a, b, 3_000_000);
        (uint32 quoted, uint32 available) =
            abi.decode(_args(err, E_INDEX_GAS.selector), (uint32, uint32));
        assertEq(quoted, floor, "the full prefix floor remains at leaf 0");
        assertGt(available, floor, "the floor was met; the callback spent what it was given");
    }

    function test_prefix_floor_above_available_is_E_INDEX_GAS_before_the_call() public {
        WorkModel memory w = IndexDoubleCore(index).workModel();
        w.computeBase = 4_000_000;
        IndexDoubleCore(index).setWorkModel(w);
        // one leaf, so the binding check is leaf 0's (later leaves check the floor less what was spent)
        Action[] memory a = _acts(_create("ordered/floor"));
        bytes[] memory b = _bodies(1);
        (uint32 floor,,,) = commitments.indexFloor(k.proxy, a);
        bytes memory data = abi.encodeCall(ILedger.execute, (a, b, _native(0), ""));
        uint256 lo = 1_000_000; // refused
        uint256 hi = 12_000_000; // lands
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = k.proxy.call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        bytes memory err = _refusedWithGas(a, b, lo);
        (uint32 quoted, uint32 available) =
            abi.decode(_args(err, E_INDEX_GAS.selector), (uint32, uint32));
        assertEq(quoted, floor);
        assertLt(available, quoted);
        assertLt(quoted - available, 2_000, "just under the floor");
        assertEq(IndexDoubleCore(index).prefixCalls(), 0, "refused before the call");
        emit log_named_uint("prefix floor quoted", floor);
        emit log_named_uint("smallest landing tx gas", hi);
    }

    // ---- 8 AttackIndex (S1) ----------------------------------------------------------------------------------

    function _nextSetCalldata() internal view returns (bytes memory) {
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), index, IndexDoubleCore(index).manifestHash()
        );
        set.revision = hot.revision() + 1;
        return abi.encodeCall(ILedgerControl.activate, (set));
    }

    function test_callbacks_cannot_reenter_writes_or_configuration() public {
        AttackIndex attack = new AttackIndex(k.proxy);
        _useIndex(address(attack));
        bytes memory activate = _nextSetCalldata();
        bytes memory begin = abi.encodeCall(
            ILedgerControl.beginTransition, (hot.revision() + 1, uint48(block.number + 10))
        );
        bytes memory abort = abi.encodeCall(ILedgerControl.abortTransition, ());
        // as the index itself: activate/begin are refused by the controller gate first; abort (open to anyone
        // after a deadline) by the lock
        attack.addAttempt(k.proxy, activate, E_NOT_CONTROLLER.selector);
        attack.addAttempt(k.proxy, begin, E_NOT_CONTROLLER.selector);
        attack.addAttempt(k.proxy, abort, E_PUBLICATION_ACTIVE.selector);
        // as the controller: refused by the lock, in both phases
        attack.addAttempt(
            address(this), abi.encodeCall(this.reenter, (activate)), E_PUBLICATION_ACTIVE.selector
        );
        attack.addAttempt(
            address(this), abi.encodeCall(this.reenter, (begin)), E_PUBLICATION_ACTIVE.selector
        );
        bytes32 es = hot.executionSet();
        uint32 rev = hot.revision();
        (Action[] memory a, bytes[] memory b) = _mixed();
        _exec(a, b);
        assertEq(abi.encode(attack.prefixAttempts(), attack.prefixRefusals()), abi.encode(12, 12));
        assertEq(abi.encode(hot.executionSet(), hot.revision()), abi.encode(es, rev));
        assertEq(_raw(Layout.LEDGER_REALM_TRANSITIONTARGET_SLOT), 0);
    }

    /// S1 / §8.7: after a deadline anyone may abort a transition, so only the lock keeps an index callback from
    /// ending it (writing the transition word, starting the cooldown) inside a publication. Regression for the
    /// missing `idle` gate on `abortTransition` fixed in 09c5b13 (src/core/LedgerCore.sol:139).
    function test_expired_transition_cannot_be_aborted_from_a_callback() public {
        AttackIndex attack = new AttackIndex(k.proxy);
        _useIndex(address(attack));
        attack.addAttempt(
            k.proxy,
            abi.encodeCall(ILedgerControl.abortTransition, ()),
            E_PUBLICATION_ACTIVE.selector
        );
        ILedgerControl(k.proxy).beginTransition(hot.revision() + 1, uint48(block.number + 5));
        vm.roll(block.number + 6); // expired: writes resume with no call
        uint256 word = uint256(_raw(Layout.LEDGER_REALM_TRANSITIONTARGET_SLOT));
        (Action[] memory a, bytes[] memory b) = _mixed();
        (bool ok, bytes memory err) =
            k.proxy.call(abi.encodeCall(ILedger.execute, (a, b, _native(0), "")));
        assertTrue(
            ok, string(abi.encodePacked("abortTransition ran inside the publication: ", err))
        );
        assertEq(uint256(_raw(Layout.LEDGER_REALM_TRANSITIONTARGET_SLOT)), word);
    }

    // ---- 9 LateRefusing (MatchedRollback) ---------------------------------------------------------------------

    function test_late_final_refusal_rolls_back_the_full_prefix() public {
        bytes32 sid = _sid(principal, "ordered/late");
        bytes32 rid = _rid(TYPE_OK, "ordered/late");
        bytes32 key = _key(principal, FOLDER, sid, ROLE);
        _useIndex(address(new LateRefusing(k.proxy, key)));
        Action[] memory a = new Action[](6);
        (a[0], a[1], a[2]) =
        (_create("ordered/late"), _publish(TYPE_OK, "ordered/late"), _reuse(TYPE_OK, rid));
        (a[3], a[4], a[5]) =
        (_bind(FOLDER, sid, ROLE, rid, 0), _unbind(FOLDER, sid, ROLE, 1), _withdraw(2));
        bytes[] memory b = _bodies(6, 1, "ordered/late");
        _expectNoChange(
            a, b, _call(abi.encodeWithSelector(LateRefusing.E_LATE_INDEX.selector, key))
        );
        // a publication without the poisoned key lands under the same index
        _exec(
            _acts(_create("ordered/late"), _publish(TYPE_OK, "ordered/late")),
            _bodies(2, 1, "ordered/late")
        );
        _useIndex(address(new LateRefusing(k.proxy, 0)));
        _expectNoChange(
            _acts(_create("ordered/late/2")),
            _bodies(1),
            _call(abi.encodeWithSelector(LateRefusing.E_LATE_INDEX.selector, bytes32(0)))
        );
    }

    // ---- 10 MutatingRule / MutatingRegistry -------------------------------------------------------------------

    function test_registry_drift_inside_a_publication_rolls_back() public {
        MutatingRule rule = new MutatingRule(k.proxy, address(registry));
        _useIndex(address(rule));
        (Action[] memory a, bytes[] memory b) = _mixed();
        uint64 m = registry.mutations();
        registry.setMutator(address(rule), true);
        _expectNoChange(a, b, abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, m, m + 1));
        registry.setMutator(address(rule), false); // negative control: the bump is refused, the write lands
        _exec(a, b);
        assertEq(abi.encode(rule.bumps(), rule.bumpRefusals()), abi.encode(0, 2));
        mutating.arm(true); // the observed counter moves with the first checkpoint
        (uint64 admissions,,,) = _counts();
        a = _acts(_create("ordered/drift"));
        b = _bodies(1);
        _expectNoChange(
            a,
            b,
            abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, m + admissions, m + admissions + 1)
        );
        registry.setMutator(address(rule), true); // both at once: the first re-check sees both moves
        _expectNoChange(
            a,
            b,
            abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, m + admissions, m + admissions + 2)
        );
        registry.setMutator(address(rule), false);
        mutating.arm(false);
        _exec(a, b);
    }

    // ---- forged errors, late leaf refusal, rules observing the prefix ---------------------------------------

    function test_forged_inner_E_NONCE_decodes_as_E_INDEX_CALL() public {
        bytes memory forged =
            abi.encodeWithSelector(E_NONCE.selector, principal, uint64(0), uint64(1));
        _useIndex(address(new ForgedRevertIndex(k.proxy, forged)));
        _refuseMixed(_call(forged));
    }

    function test_refused_leaf_after_successes_leaves_no_trace() public {
        bytes32 sid = _sid(principal, "ordered/trace");
        bytes32 rid = _rid(TYPE_OK, "ordered/trace");
        Action[] memory a = new Action[](5);
        (a[0], a[1], a[2]) =
        (
            _create("ordered/trace"),
            _publish(TYPE_OK, "ordered/trace"),
            _bind(FOLDER, sid, ROLE, rid, 0)
        );
        (a[3], a[4]) = (_reuse(TYPE_OK, rid), _publish(TYPE_REJECT, "ordered/trace"));
        bytes[] memory b = _bodies(5, 1, "ordered/trace");
        b[4] = "ordered/trace";
        _expectNoChange(a, b, abi.encodeWithSelector(E_REJECTED.selector, uint8(4), TYPE_REJECT));
        (bytes32 t,,,,) = hot.recordHeader(rid);
        (uint8 state,,,,,,) = hot.head(_key(principal, FOLDER, sid, ROLE));
        (uint64 pub,) = hot.publicationAt(principal, 0);
        assertEq(abi.encode(t, state, pub, hot.subjectCreatedAt(sid)), abi.encode(0, 0, 0, 0));
        assertEq(IndexDoubleCore(index).prefixCalls(), 0, "no posting call survived");
    }

    function test_rules_observe_the_ordered_prefix() public {
        bytes32 seeing = keccak256("ordered/prefix-rule");
        _registerType(seeing, address(new PrefixObservingRule()));
        _exec(_acts(_create("o/1"), _create("o/2"), _publish(seeing, "o/p")), _bodies(3, 2, "o/p"));
        bytes32 single = keccak256("ordered/singleton");
        _registerType(single, address(new SingletonRule()));
        _useIndex(address(new PrefixAgreement(k.proxy))); // fresh index: no effect seen yet
        bytes[] memory b = new bytes[](2);
        (b[0], b[1]) = (bytes("s/1"), bytes("s/2"));
        _expectNoChange(
            _acts(_publish(single, "s/1"), _publish(single, "s/2")),
            b,
            abi.encodeWithSelector(E_REJECTED.selector, uint8(1), single)
        );
        _exec(_acts(_publish(single, "s/1")), _bodies(1, 0, "s/1"));
        _expectNoChange(
            _acts(_publish(single, "s/2")),
            _bodies(1, 0, "s/2"),
            abi.encodeWithSelector(E_REJECTED.selector, uint8(0), single)
        );
    }
}
