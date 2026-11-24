// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.

/// @title ISignatureStore — STATE-retention witness bytes (design §5.15, §7.4)
/// @notice Namespaced by msg.sender (the calling proxy); write-once.
interface ISignatureStore {
    function put(uint64 publication, bytes calldata witness) external;

    function get(address ledger, uint64 publication) external view returns (bytes memory);
}
