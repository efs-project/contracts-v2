// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

/// @notice The EIP-7997 deterministic-deployment factory (Arachnid's proxy at 0x4e59…956C) for tests: its
///         runtime is etched once, then `deploy` creates `initcode` at salt 0 exactly as a NATIVE rule
///         instance is deployed on chain (design §9.3, §8.2 G10).
library Factory {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function ensure() internal {
        if (FACTORY.code.length == 0) vm.etch(FACTORY, RUNTIME);
    }

    function predict(bytes memory initcode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), FACTORY, bytes32(0), keccak256(initcode))
                    )
                )
            )
        );
    }

    /// Deploys at salt 0; returns the instance (idempotent: an existing instance is returned, not recreated).
    function deploy(bytes memory initcode) internal returns (address instance) {
        ensure();
        instance = predict(initcode);
        if (instance.code.length != 0) return instance;
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(bytes32(0), initcode));
        require(ok && ret.length == 20, "factory call failed");
        require(address(bytes20(ret)) == instance, "factory address mismatch");
    }
}
