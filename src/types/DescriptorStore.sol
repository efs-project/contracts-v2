// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDescriptorStore} from "../interfaces/internal/IDescriptorStore.sol";
import {E_BLOB, E_CODEC} from "../interfaces/Errors.sol";

/// @title DescriptorStore — the immutable CREATE2 factory of STOP-prefixed descriptor blobs (design §9, §5.15)
/// @notice A blob's runtime is `0x00 ‖ descriptor ‖ declarationSig`: never executable (it halts at pc 0), read
///         by `EXTCODECOPY`, and pinned by `extcodehash == keccak256(runtime)`. Creation is permissionless and
///         idempotent: the address is a function of the bytes alone (salt 0, the data inside the initcode), so a
///         second `put` of the same bytes returns the same address without creating. Refuses runtimes over
///         24,576 bytes (EIP-170; the registry separately caps descriptors at 4,096).
contract DescriptorStore is IDescriptorStore {
    /// SSTORE2's creation prologue: returns everything after its own 11 bytes as the runtime.
    bytes11 private constant PROLOGUE = hex"600B5981380380925939F3";
    uint256 private constant RUNTIME_MAX = 24_576;

    function blobHash(bytes calldata descriptor, bytes calldata declarationSig)
        external
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(hex"00", descriptor, declarationSig));
    }

    /// @inheritdoc IDescriptorStore
    function predict(bytes calldata descriptor, bytes calldata declarationSig)
        public
        view
        returns (address)
    {
        bytes32 initcodeHash = keccak256(_initcode(descriptor, declarationSig));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initcodeHash)
                    )
                )
            )
        );
    }

    /// @inheritdoc IDescriptorStore
    function put(bytes calldata descriptor, bytes calldata declarationSig)
        external
        returns (address blob)
    {
        if (1 + descriptor.length + declarationSig.length > RUNTIME_MAX) {
            revert E_CODEC(0, 1);
        }
        blob = predict(descriptor, declarationSig);
        if (blob.code.length != 0) return blob;
        bytes memory initcode = _initcode(descriptor, declarationSig);
        address created;
        assembly ("memory-safe") {
            created := create2(0, add(initcode, 32), mload(initcode), 0)
        }
        if (created != blob) revert E_BLOB(created);
    }

    function _initcode(bytes calldata descriptor, bytes calldata declarationSig)
        private
        pure
        returns (bytes memory)
    {
        return bytes.concat(PROLOGUE, hex"00", descriptor, declarationSig);
    }
}
