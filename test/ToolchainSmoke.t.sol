// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

/// @notice Test-only fixture proving compiler, EVM execution and Foundry cheatcodes work.
/// @dev This is not EFS behavior, a protocol contract, or an approved storage layout.
contract ToolchainSmokeTest is Test {
    function testCheatcodesAndAssertions() public {
        vm.warp(1234);
        assertEq(block.timestamp, 1234);
    }

    function testFuzzCheatcodeRoundTrip(uint256 value) public {
        vm.store(address(this), bytes32(0), bytes32(value));
        assertEq(uint256(vm.load(address(this), bytes32(0))), value);
    }
}
