// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// The hot-path registry row for one Type (design §5.9): 17 fields. `custom`/`bindingId` are nonzero only for
/// grade 2, so validateLeaf fills AcceptContext without a binding() call.
struct TypeInfo {
    uint8 grade;
    uint8 refCount;
    uint8 wrapperVersion;
    uint8 ruleMode;
    uint8 dependencyClass;
    uint8 refHeaderWords;
    uint32 validationGas;
    uint16 policyRows;
    address mandatory;
    bytes32 ruleId;
    bytes32 shape;
    address descriptorBlob;
    address policy;
    bytes32 policyCodehash;
    uint16 policyRow;
    address custom;
    bytes32 bindingId;
}

/// @title ITypeRegistry — the Type registry (design §5.9)
/// @notice Registration is permissionless, atomic and idempotent. Activations are controller-only
///         (controller = ILedgerHot(ledger).controller()), idle-gated through ledger.phase(), refused when
///         ledger.control().frozen, append-only, and bump `mutations`.
interface ITypeRegistry {
    // ---- hot path (the only registry reads during a publication) ----

    /// One packed header word + pins; the active policy row is read only when policyRows > 1.
    function typeInfo(bytes32 typeId) external view returns (TypeInfo memory);

    function refTypes(bytes32 typeId) external view returns (bytes32[] memory);

    /// (0, 0) when no row.
    function roleExpectation(bytes32 purpose, bytes32 role)
        external
        view
        returns (bytes32 expectedType, uint16 row);

    function mutations() external view returns (uint64);

    function activeRevision() external view returns (uint32);

    // ---- registration (permissionless, atomic, idempotent) ----

    function retainDeclaration(bytes calldata descriptor, bytes calldata declarationSig)
        external
        returns (bytes32 typeId, address blob);

    function registerDescribed(
        bytes calldata descriptor,
        bytes calldata declarationSig,
        address nativeOrCustom,
        bytes calldata bindingSig
    ) external returns (bytes32 typeId, uint64 catalogOrdinal);

    // ---- activations ----

    /// acceptor == 0 appends a no-policy row; otherwise requireRealCode + requirePlainRuntime.
    function activatePolicy(bytes32 typeId, address acceptor) external returns (uint16 row);

    function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType)
        external
        returns (uint16 row);

    /// Codehash and grammarProfile read from the wrapper's own pure constants; requirePlainRuntime.
    function activateWrapper(uint8 version, address implementation) external;

    /// Initializer; genesis creation transaction only (design §8.2 G18); records wrappers[1] from the
    /// wrapper's own constants.
    function initialize(address ledger, address wrapperV1) external;

    /// reinitializer(uint64(revision) + 1); onlyController; records activeRevision.
    function activate(uint32 revision) external;

    // ---- enumeration and discovery ----

    /// ERC-1967 implementation slot, one SLOAD; pinned per revision.
    function implementation() external view returns (address);

    function ledger() external view returns (address);

    function catalog(uint64 ordinal) external view returns (bytes32 typeId);

    function catalogCount() external view returns (uint64);

    /// Bounded EXTCODECOPY of the blob (descriptor part only, ≤ DESCRIPTOR_MAX = 4,096).
    function descriptorBytes(bytes32 typeId) external view returns (bytes memory);

    function declaration(bytes32 typeId)
        external
        view
        returns (address key, bool installed, bytes32 signatureHash);

    function policy(bytes32 typeId, uint16 row)
        external
        view
        returns (address acceptor, bytes32 codehash, uint64 activatedAt, uint64 mutationAt);

    function roleRow(bytes32 purpose, bytes32 role, uint16 n)
        external
        view
        returns (bytes32 expectedType, uint64 activatedAt);

    function roleRows(bytes32 purpose, bytes32 role) external view returns (uint16);

    function wrapper(uint8 version)
        external
        view
        returns (
            address implementation,
            bytes32 codehash,
            uint8 codecVersion,
            bytes32 grammarProfile
        );

    function binding(bytes32 typeId)
        external
        view
        returns (address custom, uint8 customAbi, bytes32 bindingId);

    /// keccak(typeId, mandatory, ruleId, policyRows, policyCodehash) for the SDK's per-Type pin.
    function typeCommitment(bytes32 typeId) external view returns (bytes32);

    // ---- registration facts an outside app needs (design §9.3) ----

    /// The deterministic-deployment factory every NATIVE instance is created through (salt 0).
    function FACTORY() external view returns (address);

    /// The descriptor blob store whose `predict` names the blob a registration expects.
    function DESCRIPTOR_STORE() external view returns (address);

    /// CREATE2(FACTORY, 0, initcode) for a descriptor's `ruleInitcodeHash`.
    function predictInstance(bytes32 ruleInitcodeHash) external pure returns (address);

    /// The chain-free EIP-712 digest a creator signs to declare `typeId`.
    function declarationDigest(bytes32 typeId) external pure returns (bytes32);

    /// The EIP-712 digest a creator signs to bind a custom predicate (the preimage binds chain and registry).
    function bindingDigest(bytes32 bindingId) external pure returns (bytes32);
}
