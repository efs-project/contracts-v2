// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @notice Test-only: inspects a recorded state diff (`vm.startStateDiffRecording` /
///         `vm.stopAndReturnStateDiff`) and asserts that a delegate wrote nothing it must not
///         (design I3: the ingress is zero-write except the named SignatureStore target; the apply
///         delegate writes only the kernel's own namespaces, which show up as writes to the kernel's
///         address). Reverting frames are ignored, because a reverted write never lands.
library ZeroWrite {
    error UnexpectedWrite(address account, bytes32 slot, bytes32 previousValue, bytes32 newValue);
    error UnexpectedCreate(address account);

    /// Reverts when any storage write landed on an account other than `allowed` (zero = none allowed),
    /// or when any account was created.
    function assertOnly(Vm.AccountAccess[] memory accesses, address allowed) internal pure {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.reverted) continue;
            if (a.kind == VmSafe.AccountAccessKind.Create) revert UnexpectedCreate(a.account);
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = a.storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                if (s.account != allowed) {
                    revert UnexpectedWrite(s.account, s.slot, s.previousValue, s.newValue);
                }
            }
        }
    }

    /// Reverts when a storage write landed on `forbidden`.
    function assertNoneOn(Vm.AccountAccess[] memory accesses, address forbidden) internal pure {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.reverted) continue;
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = a.storageAccesses[j];
                if (s.isWrite && !s.reverted && s.account == forbidden) {
                    revert UnexpectedWrite(s.account, s.slot, s.previousValue, s.newValue);
                }
            }
        }
    }

    /// Counts the storage writes that landed on `account`.
    function writesOn(Vm.AccountAccess[] memory accesses, address account)
        internal
        pure
        returns (uint256 n)
    {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].reverted) continue;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (s.isWrite && !s.reverted && s.account == account) ++n;
            }
        }
    }
}
