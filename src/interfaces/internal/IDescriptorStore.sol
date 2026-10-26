// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.

/// @title IDescriptorStore — the descriptor blob factory (design §5.15, §9)
interface IDescriptorStore {
    function predict(bytes calldata descriptor, bytes calldata declarationSig)
        external
        view
        returns (address);

    /// CREATE2 of 0x00 ‖ descriptor ‖ sig; idempotent; refuses > 24,576 B.
    function put(bytes calldata descriptor, bytes calldata declarationSig)
        external
        returns (address blob);
}
