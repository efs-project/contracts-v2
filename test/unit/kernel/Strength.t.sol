// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {Status} from "../../../src/interfaces/Results.sol";
import {AdmissionRow} from "../../../src/interfaces/Views.sol";
import {LedgerReads} from "../../../src/readers/LedgerReads.sol";
import {E_CAS, E_SHAPE} from "../../../src/interfaces/Errors.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice SPIKE (T-4 number, 16 bits): every binding carries a signed number. BIND/UNBIND put an unsigned strength
///         0..65535 in the action's `salt` word (RELEASE keeps salt 0); the head stores it at `HeadRow.meta` u16 at bit 240
///         (taken from the reserved `notAfter`, now u32 at bit 208) and the admission row in the bind rows' `policyRow` field
///         (u16 at bit 216; the kernel passes policyRow 0 for every bind kind). number = strength when BOUND (0..65535),
///         -1 - strength when MASKED (-1..-65536). Strength is read from raw storage: no reader ABI serves it in the
///         spike; `LedgerReads.admission` reports policyRow 0 and the true `withdrawn` for bind rows.
contract StrengthTest is KernelFixture {
    bytes32 internal constant SA = keccak256("strength/subject/a");
    bytes32 internal constant SB = keccak256("strength/subject/b");

    function _s(Action memory a, uint256 strength) internal pure returns (Action memory) {
        a.salt = bytes32(strength);
        return a;
    }

    function _headMeta(bytes32 key) internal view returns (uint256) {
        return uint256(_raw(Layout.bindingsHeadsSlot(key)));
    }

    function _headStrength(bytes32 key) internal view returns (uint16) {
        return uint16(_headMeta(key) >> 240);
    }

    /// The signed number of a head: strength when BOUND, -1 - strength when MASKED; `has` false otherwise.
    function _number(bytes32 key) internal view returns (bool has, int256 n) {
        uint256 m = _headMeta(key);
        uint8 state = uint8(m);
        int256 strength = int256(uint256(uint16(m >> 240)));
        if (state == 1) return (true, strength);
        if (state == 2) return (true, -1 - strength);
        return (false, 0);
    }

    function _rowStrength(uint64 admission) internal view returns (uint16) {
        return uint16(uint256(_raw(Layout.admissionsRowsSlot(admission))) >> 216);
    }

    function _rowWithdrawnByte(uint64 admission) internal view returns (uint8) {
        return uint8(uint256(_raw(Layout.admissionsRowsSlot(admission))) >> 208);
    }

    function _land(bytes memory body) internal returns (bytes32 rid) {
        rid = _rid(TYPE_OK, body);
        _exec(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
    }

    function _rev(bytes32 key) internal view returns (uint64 rev) {
        (, rev,,,,,) = hot.head(key);
    }

    function _assertNumber(bytes32 key, int256 want) internal view {
        (bool has, int256 n) = _number(key);
        assertTrue(has, "head has a number");
        assertEq(n, want, "number");
    }

    // ---- the number lifecycle --------------------------------------------------------------------------------

    function test_number_lifecycle_through_every_transition() public {
        bytes32 r = _land("strength/target");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        // 0 is the default bind (admission 2)
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        _assertNumber(key, 0);
        assertEq(_rowStrength(2), 0);
        // 0 → 75 on the same target: one REBIND (admission 3)
        vm.recordLogs();
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 1), 75)), _bodies(1));
        (Effect[] memory e,) = _effects(vm.getRecordedLogs());
        assertEq(e[0].transitionKind, 2, "REBIND");
        assertEq(e[0].oldTarget, r);
        _assertNumber(key, 75);
        assertEq(_rowStrength(3), 75);
        // positive → negative: UNBIND strength 0 is -1 (admission 4)
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 2)), _bodies(1));
        _assertNumber(key, -1);
        // -1 → -5: MASKED → MASKED, strength 4 (admission 5)
        vm.recordLogs();
        _exec(_acts(_s(_unbind(FOLDER, SA, ROLE, 3), 4)), _bodies(1));
        (e,) = _effects(vm.getRecordedLogs());
        assertEq(e[0].transitionKind, 3, "MASK again");
        assertEq(e[0].oldTarget, 0, "no live target before a mask of a mask");
        _assertNumber(key, -5);
        assertEq(_rowStrength(5), 4);
        assertEq(_raw(Layout.bindingsHeadsSlot(key) + 1), r, "the target word is kept");
        // negative → positive: RESTORE with strength 99 (admission 6)
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 4), 99)), _bodies(1));
        _assertNumber(key, 99);
        // positive → silent: RELEASE writes strength 0 (admission 7)
        _exec(_acts(_release(FOLDER, SA, ROLE, 5)), _bodies(1));
        (bool has,) = _number(key);
        assertFalse(has, "a released head has no number");
        assertEq(_headStrength(key), 0, "RELEASE writes strength 0");
        // silent → negative: UNBIND from RELEASED with strength 2 is -3
        _exec(_acts(_s(_unbind(FOLDER, SA, ROLE, 6), 2)), _bodies(1));
        _assertNumber(key, -3);
        // negative → silent
        _exec(_acts(_release(FOLDER, SA, ROLE, 7)), _bodies(1));
        assertEq(_headStrength(key), 0);
        assertEq(uint8(_headMeta(key)), 3);
    }

    /// A lone negative with no earlier positive: UNBIND from UNSET with strength 4 is -5.
    function test_lone_negative_with_a_strength() public {
        bytes32 key = _key(principal, FOLDER, SB, ROLE);
        _exec(_acts(_s(_unbind(FOLDER, SB, ROLE, 0), 4)), _bodies(1));
        _assertNumber(key, -5);
        assertEq(_rowStrength(1), 4);
        // the owner's examples: -1, 0, 3, 75, 99, and the extremes 65535 / -65536
        _exec(_acts(_s(_unbind(FOLDER, SB, ROLE, 1), 65_535)), _bodies(1));
        _assertNumber(key, -65_536);
        assertEq(_rowStrength(2), 65_535);
        assertEq(_rowWithdrawnByte(2), 0, "the withdrawn byte is not reused");
    }

    /// Changing the number on an asserted tag (3 → 75) is ONE BIND from BOUND under the ordinary CAS; a stale
    /// expectedRevision is refused and lands nothing.
    function test_rebind_changes_the_number_under_cas() public {
        bytes32 r = _land("strength/cas");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 3)), _bodies(1));
        _assertNumber(key, 3);
        _expectNoChange(
            _acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 75)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(0), uint64(1))
        );
        (uint64 before,,,) = hot.counts();
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 1), 75)), _bodies(1));
        (uint64 afterCount,,,) = hot.counts();
        assertEq(afterCount, before + 1, "one action");
        _assertNumber(key, 75);
        assertEq(_rev(key), 2);
        // the same on a masked head: a stale CAS on MASKED → MASKED is refused
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 2)), _bodies(1));
        _expectNoChange(
            _acts(_s(_unbind(FOLDER, SA, ROLE, 2), 4)),
            _bodies(1),
            abi.encodeWithSelector(E_CAS.selector, key, uint64(2), uint64(3))
        );
    }

    /// The admission facet reads neither a bind row's strength as `withdrawn` nor as a policy row.
    function test_bind_row_strength_is_not_read_as_withdrawn_or_policy() public {
        bytes32 r = _land("strength/facet");
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 40_000)), _bodies(1));
        LedgerReads reads = new LedgerReads();
        (Status st, AdmissionRow memory row) = reads.admission(k.proxy, 2);
        assertEq(uint8(st), uint8(Status.PRESENT));
        assertEq(row.kind, 3);
        assertFalse(row.withdrawn, "strength is not withdrawn");
        assertEq(row.policyRow, 0, "strength is not a policy row");
        assertEq(_rowStrength(2), 40_000);
        assertEq(_rowWithdrawnByte(2), 0);
        assertEq(_headStrength(_key(principal, FOLDER, SA, ROLE)), 40_000);
    }

    /// The narrowed `notAfter` stays zero next to a maximal strength.
    function test_max_strength_leaves_notAfter_zero() public {
        bytes32 r = _land("strength/notafter");
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 0), 65_535)), _bodies(1));
        (,,,,,, uint32 notAfter, uint16 strength) =
            Layout.unpackHeadRowWord0(bytes32(_headMeta(_key(principal, FOLDER, SA, ROLE))));
        assertEq(notAfter, 0);
        assertEq(strength, 65_535);
    }

    // ---- the shape law: refused, never truncated -------------------------------------------------------------

    function _shape2(Action memory a) internal {
        _expectNoChange(
            _acts(a), _bodies(1), abi.encodeWithSelector(E_SHAPE.selector, uint8(0), uint8(2))
        );
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
        // RELEASE keeps salt == 0: any nonzero salt is refused
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        uint256[5] memory rel =
            [uint256(1), uint256(255), uint256(65_535), uint256(65_536), uint256(high)];
        for (uint256 i; i < rel.length; ++i) {
            _shape2(_s(_release(FOLDER, SA, ROLE, 1), rel[i]));
        }
        // 256 (the old maximum + 1) and 65535 (the maximum) are admitted on both kinds
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 1), 256)), _bodies(1));
        _assertNumber(_key(principal, FOLDER, SA, ROLE), 256);
        _exec(_acts(_s(_bind(FOLDER, SA, ROLE, r, 2), 65_535)), _bodies(1));
        _assertNumber(_key(principal, FOLDER, SA, ROLE), 65_535);
        _exec(_acts(_s(_unbind(FOLDER, SA, ROLE, 3), 65_535)), _bodies(1));
        _assertNumber(_key(principal, FOLDER, SA, ROLE), -65_536);
    }

    /// The head's strength shares the meta word: binding a strength writes no slot a strength-0 bind does not.
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
