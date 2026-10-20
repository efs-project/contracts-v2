// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../../src/lib/Keys.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {ComponentSet, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";

/// @notice Test-only: the execution-set commitment of design §8.1 recomputed offline, exactly as the
///         control delegate computes it, so a test (and later the controller and the deployer) can set
///         `expectedExecutionSet` before activating.
library ExecutionSets {
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function domainSeparator(uint64 acceptedChainId, address ledger)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("EFS"), keccak256("2"), uint256(acceptedChainId), ledger
            )
        );
    }

    function limitsProfileId(Limits memory limits) internal pure returns (bytes32) {
        return keccak256(abi.encode(limits));
    }

    function executionSet(ActivationSet memory set, address ledger)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                Keys.DOM_EXECUTION_SET,
                set.layoutId,
                domainSeparator(set.acceptedChainId, ledger),
                set.components,
                uint256(set.revision),
                set.executionProfileId,
                set.capabilities,
                set.acceptedChainId,
                limitsProfileId(set.limits)
            )
        );
    }

    function indexObligations(ComponentSet memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c.index, c.indexCodehash, c.indexManifestHash));
    }
}
