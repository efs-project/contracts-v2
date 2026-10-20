// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.

import {Action} from "../Actions.sol";
import {ActivationSet} from "../ILedgerControl.sol";
import {Effect} from "../Index.sol";
import {TypeInfo} from "../ITypeRegistry.sol";

/// The fixed-size preparation output both lanes produce: 21 words, 672 B (design §6.2).
struct Prepared {
    bytes32 principalId;
    uint8 principalKind;
    uint8 proofKind;
    uint16 verifierProfile;
    uint8 v;
    address author;
    bytes32 witness0;
    bytes32 witness1;
    uint64 nonce;
    uint64 deadline;
    bytes32 actionsHash;
    bytes32 acceptanceProfile;
    bytes32 indexObligations;
    bytes32 readSetHash;
    bytes32 intentDigest;
    uint32 prefixFloor;
    uint32 finalReserve;
    uint32 freshSlots;
    uint32 rewrites;
    uint8 leafCount;
    uint8 flags;
}

/// @title ILedgerIngress — the preparation and validation delegate (design §5.15, §6.2)
/// @notice Every selector reverts E_DELEGATE_ONLY unless running by DELEGATECALL in the ledger's context
///         (address(this) != SELF).
interface ILedgerIngress {
    /// lane 1 native (laneInput = abi.encode(Native)), 2 signed (abi.encode(Intent)); not `view` only because of
    /// the SignatureStore CALL under STATE retention (design §7.4).
    function prepare(
        uint8 lane,
        bytes calldata laneInput,
        Action[] calldata actions,
        bytes[] calldata bodies,
        bytes calldata guard,
        bytes calldata witness
    ) external returns (Prepared memory);

    function validateLeaf(
        uint8 leaf,
        TypeInfo calldata info,
        bytes32 recordId,
        bytes calldata body,
        uint64 admission,
        bytes32 principalId
    ) external view returns (bytes32[] memory refs);

    function dispatchIndex(
        uint64 publication,
        Effect calldata effect,
        bytes32[] calldata refs,
        uint32 remainingPrefixFloor
    ) external returns (uint32 spent);

    function checkActivation(ActivationSet calldata set) external view;

    /// The SIGNATURE_STORE immutable; 0 until the S2b build.
    function signatureStore() external view returns (address);
}
