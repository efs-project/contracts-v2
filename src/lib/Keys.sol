// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Keys — the EFS v2 identity derivations
/// @notice Every permanent id the kernel mints is derived here and nowhere else. The domain tags, the
///         argument order and the ABI encoding are the prototype's (lab-b `src/Keys.sol`, itself copied
///         from the c0-core model) and are one-way doors: changing any of them changes every id ever
///         minted. Nothing here depends on a proxy address, an implementation codehash, a chain id or
///         compiler metadata, except the genesis `realmOrigin` that qualifies contract principals.
/// @dev Consumer-closure library: pure/view, no storage, no external calls beyond `extcodecopy`,
///      no OpenZeppelin, nothing from EIP-1153. Golden vectors for every function live in
///      `test/vectors/ids.json` and are produced by an independent implementation (`tools/vectors.mjs`).
library Keys {
    // Record id: keccak256(abi.encode(DOM_RECORD, typeId, keccak256(body)))
    bytes32 internal constant DOM_RECORD = keccak256("efs2/record/1");
    // Position: keccak256(abi.encode(DOM_POSITION, purpose, subject, role))
    bytes32 internal constant DOM_POSITION = keccak256("efs2/position/1");
    // Binding key: keccak256(abi.encode(DOM_BINDING, principal, position))
    bytes32 internal constant DOM_BINDING = keccak256("efs2/binding/1");
    // Scope key: keccak256(abi.encode(DOM_SCOPE, principal, purpose, subject))
    bytes32 internal constant DOM_SCOPE = keccak256("efs2/vk/binding-scope/1");
    // Posting key: keccak256(abi.encode(DOM_POSTING, typeId, uint256(kind), uint256(ordinal), valueKey))
    bytes32 internal constant DOM_POSTING = keccak256("efs2/pk/1");
    // Subject id: keccak256(abi.encode(DOM_SUBJECT, creatorPrincipal, creatorSalt)) — depends only on the
    // creating principal and its salt, never on chain state, so the same create yields the same subject
    // id on every deployment.
    bytes32 internal constant DOM_SUBJECT = keccak256("efs2/subject/1");
    // Contract principal: keccak256(abi.encode(DOM_PRINCIPAL, uint256(2), realmOrigin, address)). A contract
    // address is not unique across Realms; a key is, so key principals stay the left-padded address.
    bytes32 internal constant DOM_PRINCIPAL = keccak256("efs2/principal/1");
    // Exact Type id: keccak256(abi.encode(DOM_TYPE, shape, keccak256(abi.encode(refTypes)), ruleId)).
    // The id commits to the Type's descriptor shape, its checked-reference Types in order and its
    // declared rule identity, so the same descriptor yields the same id on every Realm and a changed
    // descriptor is a different Type, never a re-registration.
    bytes32 internal constant DOM_TYPE = keccak256("efs2/type/1");

    // Posting-list kinds. 2, 3, 6, 7, 9 are reserved (never minted).
    uint8 internal constant KIND_BY_TYPE = 1;
    uint8 internal constant KIND_BY_AUTHOR = 4;
    uint8 internal constant KIND_BACKLINK = 5;
    uint8 internal constant KIND_HISTORY = 8;
    uint8 internal constant KIND_SCOPE = 10;
    uint8 internal constant KIND_REFERENCE_POSITION = 11;
    uint8 internal constant KIND_BY_RECORD = 12;
    uint8 internal constant KIND_UNIQUE_BY_TYPE = 13;
    uint8 internal constant KIND_SCALAR = 14;
    uint8 internal constant KIND_DIGEST = 15;

    /// Key principal id: the left-padded address. The same key names the same principal on every Realm.
    function principal(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// Contract principal id, qualified by the Realm that observed it (kind 2).
    function contractPrincipal(bytes32 realmOrigin, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOM_PRINCIPAL, uint256(2), realmOrigin, account));
    }

    /// The principal an account authors as. EIP-7702 delegation changes execution, not the signing
    /// key's namespace: exactly the 23-byte `ef0100 ‖ address` designator is a key principal, without
    /// following its target. Any other code is a contract principal of this Realm.
    function principalFor(address account, bytes32 realmOrigin) internal view returns (bytes32) {
        uint256 size = account.code.length;
        if (size == 0) return principal(account);
        if (size == 23) {
            bytes3 prefix;
            assembly ("memory-safe") {
                extcodecopy(account, 0, 0, 3)
                prefix := mload(0)
            }
            if (prefix == hex"ef0100") return principal(account);
        }
        return contractPrincipal(realmOrigin, account);
    }

    /// Exact Type id from its descriptor commitment, checked-reference Types and rule identity.
    function typeId(bytes32 shape, bytes32[] memory refTypes, bytes32 ruleId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOM_TYPE, shape, keccak256(abi.encode(refTypes)), ruleId));
    }

    function record(bytes32 typeId_, bytes memory body) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, typeId_, keccak256(body)));
    }

    /// Same id as `record`, from an already-computed body hash (a signed Action carries the hash).
    function recordFromHash(bytes32 typeId_, bytes32 bodyHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, typeId_, bodyHash));
    }

    function subject(bytes32 creator, bytes32 creatorSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_SUBJECT, creator, creatorSalt));
    }

    function position(bytes32 purpose, bytes32 subjectKey, bytes32 role)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOM_POSITION, purpose, subjectKey, role));
    }

    function binding(bytes32 principalId, bytes32 positionKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_BINDING, principalId, positionKey));
    }

    function scope(bytes32 principalId, bytes32 purpose, bytes32 subjectKey)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOM_SCOPE, principalId, purpose, subjectKey));
    }

    function posting(bytes32 typeId_, uint8 kind, uint8 ordinal, bytes32 valueKey)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(abi.encode(DOM_POSTING, typeId_, uint256(kind), uint256(ordinal), valueKey));
    }

    function byTypeList(bytes32 typeId_) internal pure returns (bytes32) {
        return posting(typeId_, KIND_BY_TYPE, 0, bytes32(0));
    }

    function byAuthorList(bytes32 principalId) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_BY_AUTHOR, 0, principalId);
    }

    function backlinkList(bytes32 target) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_BACKLINK, 0, target);
    }

    function historyList(bytes32 bindingKey) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_HISTORY, 0, bindingKey);
    }

    function scopeList(bytes32 scopeKey) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_SCOPE, 0, scopeKey);
    }

    function referenceList(bytes32 sourceType, uint8 ordinal, bytes32 target)
        internal
        pure
        returns (bytes32)
    {
        return posting(sourceType, KIND_REFERENCE_POSITION, ordinal, target);
    }

    function byRecordList(bytes32 recordId) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_BY_RECORD, 0, recordId);
    }

    function uniqueByTypeList(bytes32 typeId_) internal pure returns (bytes32) {
        return posting(typeId_, KIND_UNIQUE_BY_TYPE, 0, bytes32(0));
    }

    function scalarList(bytes32 typeId_, uint8 spec, uint8 kind, bytes32 value)
        internal
        pure
        returns (bytes32)
    {
        return posting(typeId_, KIND_SCALAR, spec, keccak256(abi.encode(kind, value)));
    }

    function digestList(bytes32 algorithm, bytes32 value) internal pure returns (bytes32) {
        return posting(bytes32(0), KIND_DIGEST, 0, keccak256(abi.encode(algorithm, value)));
    }
}
