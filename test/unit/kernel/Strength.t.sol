// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KernelFixture} from "../../harness/KernelFixture.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, BindingNumber} from "../../../src/interfaces/Actions.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {Status} from "../../../src/interfaces/Results.sol";
import {AdmissionRow, Head} from "../../../src/interfaces/Views.sol";
import {LedgerReads} from "../../../src/readers/LedgerReads.sol";
import {E_CAS, E_NOT_LIVE, E_SHAPE} from "../../../src/interfaces/Errors.sol";

/// @notice The number on every binding (design §6.4). BIND and UNBIND carry an unsigned strength 0..65,535 in
///         `Action.saltOrStrength` (RELEASE carries 0); the head stores it in `HeadRow.strength` and the admission
///         row in `policyRowOrStrength`; the signed number is derived: `strength` when BOUND, `-1 - strength` when
///         MASKED, none otherwise. An UNBIND is admitted from every state: a first statement may be negative
///         (FIRST_MASK) and a negative number changes by another UNBIND.
contract StrengthTest is KernelFixture {
    bytes32 internal constant SA = keccak256("strength/subject/a");
    bytes32 internal constant SB = keccak256("strength/subject/b");

    LedgerReads internal reads;

    function setUp() public override {
        super.setUp();
        reads = new LedgerReads();
    }

    function _s(Action memory a, uint256 strength) internal pure returns (Action memory) {
        a.saltOrStrength = bytes32(strength);
        return a;
    }

    function _hotHead(bytes32 key) internal view returns (Head memory h) {
        (
            h.state,
            h.revision,
            h.admission,
            h.targetKind,
            h.prevAdmission,
            h.bindingOrdinal,
            h.target,
            h.strength
        ) = hot.head(key);
    }

    function _number(bytes32 key) internal view returns (bool has, int32 n) {
        Head memory h = _hotHead(key);
        return BindingNumber.numberOf(h.state, h.strength);
    }

    function _assertNumber(bytes32 key, int32 want) internal view {
        (bool has, int32 n) = _number(key);
        assertTrue(has, "the head has a number");
        assertEq(n, want, "number");
        // the facet serves the same head, strength included
        (, Head memory viaFacet) = reads.head(k.proxy, key);
        assertEq(abi.encode(viaFacet.strength), abi.encode(_hotHead(key).strength), "facet");
    }

    function _rowStrength(uint64 admission) internal view returns (uint16) {
        (, AdmissionRow memory row) = reads.admission(k.proxy, admission);
        return row.strength;
    }

    function _land(bytes memory body) internal returns (bytes32 rid) {
        rid = _rid(TYPE_OK, body);
        _exec(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
    }

    function _transition(Action memory a) internal returns (uint8) {
        vm.recordLogs();
        _exec(_acts(a), _bodies(1));
        (Effect[] memory e,) = _effects(vm.getRecordedLogs());
        return e[0].transitionKind;
    }

    // ---- the derived number ----------------------------------------------------------------------------------

    function test_numberOf_by_state() public pure {
        (bool has, int32 n) = BindingNumber.numberOf(1, 0);
        assertEq(abi.encode(has, n), abi.encode(true, int32(0)));
        (has, n) = BindingNumber.numberOf(1, 65_535);
        assertEq(abi.encode(has, n), abi.encode(true, int32(65_535)));
        (has, n) = BindingNumber.numberOf(2, 0);
        assertEq(abi.encode(has, n), abi.encode(true, int32(-1)));
        (has, n) = BindingNumber.numberOf(2, 65_535);
        assertEq(abi.encode(has, n), abi.encode(true, int32(-65_536)));
        for (uint8 st = 0; st < 8; ++st) {
            if (st == 1 || st == 2) continue;
            (has, n) = BindingNumber.numberOf(st, 77);
            assertEq(abi.encode(has, n), abi.encode(false, int32(0)), "no number");
        }
    }

    // ---- the number lifecycle --------------------------------------------------------------------------------

    function test_number_lifecycle_through_every_transition() public {
        bytes32 r = _land("strength/target");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        assertEq(_transition(_bind(FOLDER, SA, ROLE, r, 0)), 1, "FIRST_BIND"); // admission 2
        _assertNumber(key, 0);
        assertEq(_rowStrength(2), 0);
        assertEq(_transition(_s(_bind(FOLDER, SA, ROLE, r, 1), 75)), 2, "REBIND: 0 -> 75"); // 3
        _assertNumber(key, 75);
        assertEq(_rowStrength(3), 75);
        assertEq(_transition(_unbind(FOLDER, SA, ROLE, 2)), 3, "MASK: 75 -> -1"); // 4
        _assertNumber(key, -1);
        assertEq(_transition(_s(_unbind(FOLDER, SA, ROLE, 3), 4)), 3, "MASK of a mask: -1 -> -5"); // 5
        _assertNumber(key, -5);
        assertEq(_rowStrength(5), 4);
        assertEq(_raw(Layout.bindingsHeadsSlot(key) + 1), r, "the target word is kept");
        assertEq(_transition(_s(_bind(FOLDER, SA, ROLE, r, 4), 99)), 5, "RESTORE: -5 -> 99"); // 6
        _assertNumber(key, 99);
        assertEq(_transition(_release(FOLDER, SA, ROLE, 5)), 4, "RELEASE"); // 7
        (bool has,) = _number(key);
        assertFalse(has, "a released head has no number");
        assertEq(_hotHead(key).strength, 0, "RELEASE writes strength 0");
        assertEq(_transition(_s(_unbind(FOLDER, SA, ROLE, 6), 2)), 3, "MASK from RELEASED: -3"); // 8
        _assertNumber(key, -3);
        assertEq(_transition(_release(FOLDER, SA, ROLE, 7)), 4, "RELEASE from MASKED"); // 9
        assertEq(_hotHead(key).strength, 0);
        assertEq(_hotHead(key).state, 3);
    }

    /// A lone negative: UNBIND on an UNSET head allocates the binding and position with no target (FIRST_MASK).
    function test_lone_negative_allocates_with_no_target() public {
        bytes32 key = _key(principal, FOLDER, SB, ROLE);
        (,, uint64 bindingsBefore,) = hot.counts();
        assertEq(_transition(_s(_unbind(FOLDER, SB, ROLE, 0), 4)), 6, "FIRST_MASK");
        Head memory h = _hotHead(key);
        assertEq(
            abi.encode(h.state, h.revision, h.admission, h.targetKind, h.prevAdmission, h.target),
            abi.encode(uint8(2), uint64(1), uint64(1), uint8(0), uint64(0), bytes32(0))
        );
        (,, uint64 bindingsAfter,) = hot.counts();
        assertEq(bindingsAfter, bindingsBefore + 1, "a binding ordinal is minted");
        assertEq(h.bindingOrdinal, bindingsAfter);
        (Status st, bytes32 position) = reads.bindingPosition(k.proxy, h.bindingOrdinal);
        assertEq(uint8(st), uint8(Status.PRESENT));
        assertEq(position, Keys.position(FOLDER, SB, ROLE));
        (, bytes32 pp, bytes32 ps, bytes32 pr) = reads.positionCell(k.proxy, position);
        assertEq(
            abi.encode(pp, ps, pr), abi.encode(FOLDER, SB, ROLE), "the position cell is written"
        );
        _assertNumber(key, -5);
        assertEq(_rowStrength(1), 4);
        // the extremes, and a mask of the first mask
        assertEq(_transition(_s(_unbind(FOLDER, SB, ROLE, 1), 65_535)), 3);
        _assertNumber(key, -65_536);
        (, AdmissionRow memory row) = reads.admission(k.proxy, 2);
        assertEq(
            abi.encode(row.strength, row.withdrawn, row.policyRow), abi.encode(65_535, false, 0)
        );
        // a RELEASE and a BIND after a lone negative (the head was never bound)
        assertEq(_transition(_release(FOLDER, SB, ROLE, 2)), 4);
        assertEq(_hotHead(key).targetKind, 0, "never bound");
        bytes32 r = _land("strength/after-lone");
        assertEq(
            _transition(_s(_bind(FOLDER, SB, ROLE, r, 3), 7)), 5, "RESTORE over a lone negative"
        );
        _assertNumber(key, 7);
    }

    /// An UNBIND is admitted from every state; a RELEASE still only from BOUND or MASKED.
    function test_unbind_from_every_state_release_not_from_silence() public {
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _expectNoChange(
            _acts(_release(FOLDER, SA, ROLE, 0)),
            _bodies(1),
            abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(0), key, uint8(0))
        );
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 0)), _bodies(1)); // UNSET
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1)); // MASKED
        _exec(_acts(_release(FOLDER, SA, ROLE, 2)), _bodies(1));
        _expectNoChange(
            _acts(_release(FOLDER, SA, ROLE, 3)),
            _bodies(1),
            abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(0), key, uint8(3))
        );
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 3)), _bodies(1)); // RELEASED
        bytes32 r = _land("strength/states");
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 4)), _bodies(1));
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 5)), _bodies(1)); // BOUND
        assertEq(_hotHead(key).revision, 6);
    }

    /// Changing the number on an asserted binding (3 -> 75) is ONE BIND under the ordinary CAS.
    function test_rebind_changes_the_number_under_cas() public {
        bytes32 r = _land("strength/cas");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 3)), _bodies(1));
        _assertNumber(key, 3);
        (uint64 before,,,) = hot.counts();
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 1), 75)), _bodies(1));
        (uint64 afterCount,,,) = hot.counts();
        assertEq(afterCount, before + 1, "one action");
        _assertNumber(key, 75);
        assertEq(_hotHead(key).revision, 2);
    }

    /// A stale `expectedRevision` is refused, with nothing written, on every transition this step adds or
    /// widens: a first mask, a number change on a positive, a mask of a mask, a mask from RELEASED.
    function test_stale_revision_refused_on_every_new_transition() public {
        bytes32 r = _land("strength/stale");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        // FIRST_MASK: the head is UNSET (revision 0)
        _expectNoChange(
            _acts(_s(_unbind(FOLDER, SA, ROLE, 1), 9)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(1), uint64(0))
        );
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 3)), _bodies(1)); // revision 1
        // a number change on a positive
        _expectNoChange(
            _acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 75)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(0), uint64(1))
        );
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1)); // revision 2, MASKED
        // a mask of a mask
        _expectNoChange(
            _acts(_s(_unbind(FOLDER, SA, ROLE, 1), 4)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(1), uint64(2))
        );
        _exec(_acts(_release(FOLDER, SA, ROLE, 2)), _bodies(1)); // revision 3, RELEASED
        // a mask from RELEASED
        _expectNoChange(
            _acts(_unbind(FOLDER, SA, ROLE, 2)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(2), uint64(3))
        );
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 3)), _bodies(1));
        _assertNumber(key, -1);
    }

    /// The expected-revision check covers all three bind kinds alike (`LedgerApply._applyBind` for BIND,
    /// `_applyMaskOrRelease` for UNBIND and RELEASE: `head.revision != action.expectedRevision` → `E_CAS`), for a
    /// revision too low and too high, from BOUND and from MASKED, with nothing written. So a planner that prices a
    /// statement from a stale head (gas/model.json `laterRows`: the history-word correction reads the revision) has the
    /// statement refused, never admitted at a price it did not plan.
    function test_stale_expected_revision_refused_for_bind_unbind_and_release() public {
        bytes32 r = _land("strength/cas-kinds");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1)); // revision 1, BOUND
        for (uint64 wrong; wrong < 3; wrong += 2) {
            // revision 0 (stale) and 2 (ahead) against the head's 1
            bytes memory cas = abi.encodeWithSelector(E_CAS.selector, key, wrong, uint64(1));
            _expectNoChange(_acts(_bind(FOLDER, SA, ROLE, r, wrong)), _bodies(1), cas);
            _expectNoChange(_acts(_unbind(FOLDER, SA, ROLE, wrong)), _bodies(1), cas);
            _expectNoChange(_acts(_release(FOLDER, SA, ROLE, wrong)), _bodies(1), cas);
        }
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1)); // revision 2, MASKED
        bytes memory stale = abi.encodeWithSelector(E_CAS.selector, key, uint64(1), uint64(2));
        _expectNoChange(_acts(_bind(FOLDER, SA, ROLE, r, 1)), _bodies(1), stale);
        _expectNoChange(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1), stale);
        _expectNoChange(_acts(_release(FOLDER, SA, ROLE, 1)), _bodies(1), stale);
        assertEq(_hotHead(key).revision, 2, "nothing written");
    }

    /// The admission facet serves a bind row's strength as `strength`, never as `withdrawn` or a policy row,
    /// and a record row's policy row as `policyRow` with strength 0.
    function test_admission_view_splits_the_shared_field_by_kind() public {
        bytes32 r = _land("strength/facet"); // admission 1, policy row 1
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 40_000)), _bodies(1)); // admission 2
        (Status st, AdmissionRow memory row) = reads.admission(k.proxy, 2);
        assertEq(uint8(st), uint8(Status.PRESENT));
        assertEq(row.kind, 3);
        assertFalse(row.withdrawn, "a strength is not withdrawn");
        assertEq(row.policyRow, 0, "a strength is not a policy row");
        assertEq(row.strength, 40_000);
        (,,,,,,, uint16 raw,,) = Layout.unpackAdmissionRowWord0(_raw(Layout.admissionsRowsSlot(2)));
        assertEq(raw, 40_000, "stored in policyRowOrStrength");
        (, row) = reads.admission(k.proxy, 1);
        assertEq(abi.encode(row.kind, row.policyRow, row.strength), abi.encode(1, 1, 0));
        assertEq(_hotHead(_key(principal, FOLDER, SA, ROLE)).strength, 40_000);
    }

    /// The facets' hand-encoded `head` (10 words) and `admission` (13 words) stay canonical with a nonzero strength
    /// and on a head that was never bound.
    function test_hand_encoded_returns_carry_the_strength_canonically() public {
        bytes32 r = _land("strength/canonical");
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 65_535)), _bodies(1)); // admission 2
        _exec(_acts(_s(_unbind(FOLDER, SB, ROLE, 0), 300)), _bodies(1)); // admission 3: a first mask
        bytes32[2] memory keys =
            [_key(principal, FOLDER, SA, ROLE), _key(principal, FOLDER, SB, ROLE)];
        for (uint256 i; i < 2; ++i) {
            (bool ok, bytes memory ret) =
                address(reads).staticcall(abi.encodeCall(LedgerReads.head, (k.proxy, keys[i])));
            assertTrue(ok);
            (Status st, Head memory h) = abi.decode(ret, (Status, Head));
            assertEq(ret, abi.encode(st, h), "head canonical");
            assertEq(ret.length, 10 * 32);
            assertEq(h.strength, i == 0 ? 65_535 : 300);
        }
        for (uint64 o = 1; o <= 3; ++o) {
            (bool ok, bytes memory ret) =
                address(reads).staticcall(abi.encodeCall(LedgerReads.admission, (k.proxy, o)));
            assertTrue(ok);
            (Status st, AdmissionRow memory row) = abi.decode(ret, (Status, AdmissionRow));
            assertEq(ret, abi.encode(st, row), "admission canonical");
            assertEq(ret.length, 13 * 32);
        }
    }

    /// The narrowed `notAfter` stays zero next to a maximal strength.
    function test_max_strength_leaves_notAfter_zero() public {
        bytes32 r = _land("strength/notafter");
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 65_535)), _bodies(1));
        (,,,,,, uint32 notAfter, uint16 strength) = Layout.unpackHeadRowWord0(
            _raw(Layout.bindingsHeadsSlot(_key(principal, FOLDER, SA, ROLE)))
        );
        assertEq(notAfter, 0);
        assertEq(strength, 65_535);
    }

    // ---- the shape law: refused, never truncated -------------------------------------------------------------

    function _shape2(Action memory a) internal {
        _expectNoChange(
            _acts(a), _bodies(1), abi.encodeWithSelector(E_SHAPE.selector, uint8(0), uint8(2))
        );
    }

    /// The boundary: 65,535 is admitted on BIND and UNBIND, 65,536 refused on both; RELEASE refuses any nonzero.
    function test_strength_boundary_65535_65536() public {
        bytes32 r = _land("strength/boundary");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _shape2(_s(_bind(FOLDER, SA, ROLE, r, 0), 65_536));
        _shape2(_s(_unbind(FOLDER, SA, ROLE, 0), 65_536));
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 65_535)), _bodies(1));
        _assertNumber(key, 65_535);
        _shape2(_s(_bind(FOLDER, SA, ROLE, r, 1), 65_536));
        _shape2(_s(_unbind(FOLDER, SA, ROLE, 1), 65_536));
        _exec(_acts(_s(_unbind(FOLDER, SA, ROLE, 1), 65_535)), _bodies(1));
        _assertNumber(key, -65_536);
        _shape2(_s(_release(FOLDER, SA, ROLE, 2), 1));
        _shape2(_s(_release(FOLDER, SA, ROLE, 2), 65_535));
        _exec(_acts(_release(FOLDER, SA, ROLE, 2)), _bodies(1));
    }

    function test_strength_over_65535_is_E_SHAPE_2() public {
        bytes32 r = _land("strength/shape");
        bytes32 high = bytes32(uint256(1) << 255); // only a high bit: its low bits are 0, must not truncate to 0
        bytes32 highPlus = bytes32((uint256(1) << 200) | 7); // low bits 7, high bits set
        uint256[5] memory bad = [
            uint256(65_536), uint256(65_536 + 7), uint256(1 << 24), uint256(high), uint256(highPlus)
        ];
        for (uint256 i; i < bad.length; ++i) {
            _shape2(_s(_bind(FOLDER, SA, ROLE, r, 0), bad[i]));
            _shape2(_s(_unbind(FOLDER, SA, ROLE, 0), bad[i]));
        }
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        uint256[5] memory rel =
            [uint256(1), uint256(255), uint256(65_535), uint256(65_536), uint256(high)];
        for (uint256 i; i < rel.length; ++i) {
            _shape2(_s(_release(FOLDER, SA, ROLE, 1), rel[i]));
        }
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 1), 256)), _bodies(1));
        _assertNumber(_key(principal, FOLDER, SA, ROLE), 256);
    }

    /// The head's strength shares the meta word: a strength writes no slot a strength-0 bind does not.
    function test_strength_writes_no_new_slot() public {
        bytes32 r = _land("strength/slots");
        uint256 zero = _writtenSlots(_acts(_bind(FOLDER, SA, ROLE, r, 0)));
        uint256 some = _writtenSlots(_acts(_s(_bind(FOLDER, SB, ROLE, r, 0), 75)));
        assertEq(some, zero, "same slot count");
    }

    function _writtenSlots(Action[] memory a) internal returns (uint256 n) {
        _track(principal, a);
        vm.startStateDiffRecording();
        ledger.execute(a, _bodies(a.length), _native(_nonce(principal)), "");
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory x = acc[i].storageAccesses[j];
                if (x.isWrite && !x.reverted && x.previousValue == 0 && x.newValue != 0) ++n;
            }
        }
    }
}
