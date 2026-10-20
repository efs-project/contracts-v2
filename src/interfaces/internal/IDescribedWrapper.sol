// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.

import {IAcceptor} from "../IAcceptor.sol";

/// @title IDescribedWrapper — the described-Type wrapper acceptor (design §5.15, §5.10)
/// @notice Its codehash and grammar profile are read from its own pure constants at activateWrapper.
interface IDescribedWrapper is IAcceptor {
    function codecVersion() external pure returns (uint8);

    function grammarProfile() external pure returns (bytes32);
}
