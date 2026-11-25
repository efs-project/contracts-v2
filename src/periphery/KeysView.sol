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
        hex"6e9951606fbc96e1560952b497304e115de43022a254f3877bd99cbefd8ad976785d20da3fabd294e01d4c32df6ffe58f0fdfb2a411a0a6c88058113d0725ef394f3e0f72302096c34e61531e3e8c02e3f6c616797d01274930992982a761794fa1f2b56a78c1724";
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
