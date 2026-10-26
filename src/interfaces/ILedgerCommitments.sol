// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, FamilyId, Intent, Native, PostingKey, ReadSet, TypeId} from "./Actions.sol";

/// @title ILedgerCommitments — the commitment encoders (design §5.8)
/// @notice On the ingress address; pure/view encoders the SDK proves equivalent in CI from `vectors/`, never on
///         the hot path.
interface ILedgerCommitments {
    function actionsHash(Action[] calldata actions) external pure returns (bytes32);

    /// The signed lanes' retry key, chain-free:
    /// keccak(abi.encode(DOM_SIGNED_INTENT, hashStruct(intent), actionsHash)).
    function intentDigest(Intent calldata intent, bytes32 actionsHash)
        external
        pure
        returns (bytes32);

    /// The EIP-712 digest the key or wallet signs:
    /// keccak(0x1901 ‖ domainSeparator ‖ hashStruct(IntentWithActions{intent, actionsHash})); never stored.
    function signingDigest(bytes32 domainSeparator, Intent calldata intent, bytes32 actionsHash)
        external
        pure
        returns (bytes32);

    /// keccak(abi.encode(DOM_NATIVE_INTENT, realmId, principalId, ctx.nonce, ctx.deadline,
    /// ctx.expectedExecutionSet, ctx.expectedAcceptanceProfile, guardHash, actionsHash));
    /// guardHash = keccak(raw guard bytes).
    function nativeIntentDigest(
        bytes32 realmId,
        bytes32 principalId,
        Native calldata ctx,
        bytes32 actionsHash,
        bytes32 guardHash
    ) external pure returns (bytes32);

    function publicationIdOf(bytes32 principalId, bytes32 intentDigest)
        external
        pure
        returns (bytes32);

    /// keccak(abi.encode(rs)); equal to guardHash for every accepted guarded publication, because the ingress
    /// requires the raw guard bytes to be the canonical encoding.
    function readSetHash(ReadSet calldata rs) external pure returns (bytes32);

    function headSnapshotHash(
        uint8 state,
        uint64 revision,
        uint64 admission,
        bytes32 canonicalTarget
    ) external pure returns (bytes32);

    function acceptanceProfileOf(address ledger, Action[] calldata actions)
        external
        view
        returns (bytes32);

    function indexObligationsOf(address ledger) external view returns (bytes32);

    /// Estimation: the floor the dispatcher will demand.
    function indexFloor(address ledger, Action[] calldata actions)
        external
        view
        returns (uint32 prefixFloor, uint32 finalReserve, uint32 freshSlots, uint32 rewrites);

    function recordId(bytes32 typeId, bytes32 bodyHash) external pure returns (bytes32);

    function subjectId(bytes32 principalId, bytes32 salt) external pure returns (bytes32);

    function positionKey(bytes32 purpose, bytes32 subject, bytes32 role)
        external
        pure
        returns (bytes32);

    function bindingKey(bytes32 principalId, bytes32 position) external pure returns (bytes32);

    function scopeKey(bytes32 principalId, bytes32 purpose, bytes32 subject)
        external
        pure
        returns (bytes32);

    function roleScopeKey(bytes32 principalId, bytes32 purpose, bytes32 role)
        external
        pure
        returns (bytes32);

    /// = Keys.posting(typeId, kindOf(family), ordinal, value), kindOf = the §10.2 kind number (FamilyEntry.kind).
    function postingKey(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        pure
        returns (PostingKey);

    function typeIdOf(bytes32 shape, bytes32[] calldata refTypes, bytes32 ruleId)
        external
        pure
        returns (bytes32);
}
