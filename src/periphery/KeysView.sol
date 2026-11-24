// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";
import {FamilyId, PostingKey, TypeId} from "../interfaces/Actions.sol";
import {IKeysView} from "../interfaces/IKeysView.sol";
import {E_RESERVED} from "../interfaces/Errors.sol";

/// @title KeysView — the pure identity derivations as an on-chain view (design §5.8)
/// @notice Stateless and immutable; outside the execution set. Every function is `Keys` verbatim.
contract KeysView is IKeysView {
    function recordId(bytes32 typeId, bytes32 bodyHash) external pure returns (bytes32) {
        return Keys.recordFromHash(typeId, bodyHash);
    }

    function subjectId(bytes32 principalId, bytes32 salt) external pure returns (bytes32) {
        return Keys.subject(principalId, salt);
    }

    function positionKey(bytes32 purpose, bytes32 subject, bytes32 role)
        external
        pure
        returns (bytes32)
    {
        return Keys.position(purpose, subject, role);
    }

    function bindingKey(bytes32 principalId, bytes32 position) external pure returns (bytes32) {
        return Keys.binding(principalId, position);
    }

    function scopeKey(bytes32 principalId, bytes32 purpose, bytes32 subject)
        external
        pure
        returns (bytes32)
    {
        return Keys.scope(principalId, purpose, subject);
    }

    function roleScopeKey(bytes32 principalId, bytes32 purpose, bytes32 role)
        external
        pure
        returns (bytes32)
    {
        return Keys.roleScope(principalId, purpose, role);
    }

    function postingKey(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        pure
        returns (PostingKey)
    {
        return PostingKey.wrap(Keys.posting(TypeId.unwrap(typeId), _kindOf(family), ordinal, value));
    }

    function typeIdOf(bytes32 shape, bytes32[] calldata refTypes, bytes32 ruleId)
        external
        pure
        returns (bytes32)
    {
        return Keys.typeId(shape, refTypes, ruleId);
    }

    /// The §10.2 kind number of a family id: the first eight bytes of each id (test/vectors/ids.json), packed
    /// in declaration order, and the matching kinds; reverts for an unknown family.
    bytes private constant FAMILY_PREFIXES =
        hex"e4f7cc7ff76622e1d674025fa1091f86f564f360d1f5b65ade538e29eab736631fd035d41e55e58529d3bea0a01e3e2603b682942778e8b977b478e9ae9182faef3758cffd687b169f7b888d291c8c4ce84f1b109238a09c04369382b4c38d708433e20c283016a6";
    bytes private constant FAMILY_KINDS = hex"010405080a0b0c0d0e0f101112";

    function _kindOf(FamilyId family) private pure returns (uint8) {
        bytes8 head = bytes8(FamilyId.unwrap(family));
        bytes memory prefixes = FAMILY_PREFIXES;
        for (uint256 i; i < 13; ++i) {
            bytes8 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(prefixes, 32), mul(i, 8)))
            }
            if (candidate == head) return uint8(FAMILY_KINDS[i]);
        }
        revert E_RESERVED(20, uint256(FamilyId.unwrap(family)));
    }
}
