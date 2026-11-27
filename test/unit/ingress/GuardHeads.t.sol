// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GuardBase} from "./GuardBase.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";

/// @notice The invariant head-snapshot profile 2 rests on (`LedgerIngress._checkGuard`): a head's stored target
///         word is 0 exactly when its `targetKind` is 0, and it is the target of the last BIND (0 if none). A
///         BIND writes both, a first mask writes kind 0 and word 0, UNBIND and RELEASE write neither; a BIND with
///         target 0 is refused `E_SHAPE(leaf, 1)` (pinned in test/unit/kernel/Shape.t.sol). Every sequence of
///         length ≤ 4 over {BIND A, BIND B, UNBIND, RELEASE} from an UNSET head that the kernel admits is walked
///         (a refused step is skipped); after every admitted step the raw head row, `LedgerViews.headSnapshots`
///         and a guard built from them are checked.
contract GuardHeadsTest is GuardBase {
    uint8 internal constant BIND_A = 0;
    uint8 internal constant BIND_B = 1;
    uint8 internal constant UNBIND = 2;
    uint8 internal constant RELEASE = 3;
    uint256 internal constant DEPTH = 4;

    function _step(uint8 op, uint48 revision) internal view returns (Action memory) {
        if (op == BIND_A) return _bind(FOLDER, SUBJECT, ROLE, recA, revision);
        if (op == BIND_B) return _bind(FOLDER, SUBJECT, ROLE, recB, revision);
        if (op == UNBIND) return _unbind(FOLDER, SUBJECT, ROLE, revision);
        return _release(FOLDER, SUBJECT, ROLE, revision);
    }

    /// Whether the kernel admitted `op` on the head as it stands (a refused call changes nothing).
    function _try(uint8 op) internal returns (bool ok) {
        Raw memory h = _rawHead(principal, pos);
        Action[] memory a = _acts(_step(op, h.revision));
        (ok,) = k.proxy
            .call(abi.encodeCall(ILedger.execute, (a, _bodies(1), _native(_nonce(principal)), "")));
        if (op == RELEASE) {
            assertEq(
                ok, h.state == 1 || h.state == 2, "RELEASE is admitted from BOUND or MASKED only"
            );
        }
    }

    function _check(bytes32 lastBind, uint256 depth) internal {
        Raw memory h = _rawHead(principal, pos);
        assertEq(h.word == 0, h.targetKind == 0, "target word 0 iff targetKind 0");
        assertEq(h.word, lastBind, "the target word is the last BIND's target");
        (bytes32[] memory snapshots, bytes32[] memory targets) =
            views.headSnapshots(k.proxy, _one(principal), _one(pos));
        assertEq(snapshots.length, 1);
        assertEq(targets[0], h.word, "headSnapshots.targets is the raw word");
        bytes32 expected = _snap(h.state, h.revision, h.admission, h.word);
        assertEq(snapshots[0], expected, "headSnapshots.snapshots is profile 2 over the raw word");
        // a guard built from them passes (a CREATE whose salt is unique on this path)
        Action[] memory c = _acts(_create(keccak256(abi.encode("guard/heads", depth))));
        (uint64 n) = _nonce(principal);
        (bool ok,) = k.proxy
            .call(
                abi.encodeCall(
                    ILedger.execute, (c, _bodies(1), _native(n), _guard1(principal, pos, expected))
                )
            );
        assertTrue(ok, "a guard built from the raw head passes");
    }

    /// Returns the number of admitted steps under the current head.
    function _walk(uint256 depth, bytes32 lastBind) internal returns (uint256 admitted) {
        if (depth == DEPTH) return 0;
        for (uint8 op; op < 4; ++op) {
            uint256 snap = vm.snapshotState();
            if (_try(op)) {
                bytes32 lb = op == BIND_A ? recA : op == BIND_B ? recB : lastBind;
                _check(lb, depth);
                admitted += 1 + _walk(depth + 1, lb);
            }
            vm.revertToState(snap);
        }
    }

    function test_the_stored_target_word_over_every_admitted_sequence() public {
        Raw memory h = _rawHead(principal, pos);
        assertEq(abi.encode(h.state, h.targetKind, h.word), abi.encode(0, 0, bytes32(0)));
        uint256 admitted = _walk(0, 0);
        emit log_named_uint("admitted steps", admitted);
        // the count observed at 9784a25: a change in which transitions the kernel admits changes it
        assertEq(admitted, 231, "admitted steps over every sequence of length <= 4");
    }
}
