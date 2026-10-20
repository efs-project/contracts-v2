// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.

import {Action} from "../Actions.sol";
import {Effect} from "../Index.sol";
import {TypeInfo} from "../ITypeRegistry.sol";

/// @title ILedgerApply — the per-leaf apply delegate (design §5.15, §6.4)
/// @notice Same delegate-only guard as ILedgerIngress; executes under the kernel's lock in the kernel's
///         storage; makes no external call.
interface ILedgerApply {
    function applyLeaf(
        uint8 leaf,
        uint64 admission,
        Action calldata action,
        bytes calldata body,
        TypeInfo calldata info,
        bytes32 principalId,
        uint8 principalKind,
        uint16 policyRow,
        uint16 roleRow
    ) external returns (Effect memory effect, bytes32[] memory refs);
}
