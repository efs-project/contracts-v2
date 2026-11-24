// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.
import {Action} from "../Actions.sol";
import {Effect} from "../Index.sol";

/// @title ILedgerApply — the per-leaf apply delegate (design §5.15, §6.4)
/// @notice Same delegate-only guard as ILedgerIngress; executes under the kernel's lock in the kernel's
///         storage; makes no external call. The return is static (33 words) so the kernel can keep it as an
///         opaque blob: Effect/3 at words 0..23, the ref count at word 24, the refs at words 25..32.
interface ILedgerApply {
    function applyLeaf(
        uint8 leaf,
        uint64 admission,
        Action calldata action,
        bytes calldata body,
        uint8 refCount,
        bytes32 principalId,
        uint8 principalKind,
        uint16 policyRow,
        uint16 roleRow
    ) external returns (Effect memory effect, uint256 refCountOut, bytes32[8] memory refs);
}
