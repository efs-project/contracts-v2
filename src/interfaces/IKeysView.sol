// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, PostingKey, TypeId} from "./Actions.sol";

/// @title IKeysView — the pure identity derivations as an on-chain view (design §5.8)
/// @notice The eight derivations of `Keys` that depend on no state. They lived on the ingress's commitment
///         surface; they are served by the standalone `KeysView` contract instead, because nothing on the
///         write path calls them and the pinned ingress must stay under its size budget. The SDK proves its
///         own twin against `test/vectors/ids.json`; this view exists for conformance checks and for
///         Solidity callers that prefer a call to linking the library.
interface IKeysView {
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
