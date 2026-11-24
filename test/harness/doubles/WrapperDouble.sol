// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDescribedWrapper} from "../../../src/interfaces/internal/IDescribedWrapper.sol";
import {IAcceptor, AcceptContext, RefHeader} from "../../../src/interfaces/IAcceptor.sol";

/// @notice A described-wrapper stand-in: the two pure constants `activateWrapper` reads, and an accept that
///         always agrees. Plain runtime (no delegatecall), so it passes the activation scan.
contract WrapperDouble is IDescribedWrapper {
    function codecVersion() external pure returns (uint8) {
        return 1;
    }

    function grammarProfile() external pure returns (bytes32) {
        return keccak256("test/grammar/1");
    }

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        return IAcceptor.accept.selector;
    }
}

/// @notice A second wrapper build (another grammar profile, hence another codehash).
contract WrapperDoubleB is IDescribedWrapper {
    function codecVersion() external pure returns (uint8) {
        return 1;
    }

    function grammarProfile() external pure returns (bytes32) {
        return keccak256("test/grammar/2");
    }

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        return IAcceptor.accept.selector;
    }
}

/// @notice A delegating runtime (one DELEGATECALL in its fallback): what every EFS code gate must refuse.
contract Delegator {
    address private immutable TARGET;

    constructor(address target) {
        TARGET = target;
    }

    fallback() external {
        (bool ok, bytes memory ret) = TARGET.delegatecall(msg.data);
        assembly ("memory-safe") {
            if iszero(ok) { revert(add(ret, 32), mload(ret)) }
            return(add(ret, 32), mload(ret))
        }
    }
}
