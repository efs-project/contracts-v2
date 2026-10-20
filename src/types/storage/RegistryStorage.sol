// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title RegistryStorage — the Type registry's ERC-7201 namespaces (design §4.5)
/// @notice The registry stores no controller and no frozen flag: both are read from the ledger.
abstract contract RegistryStorage {
    /// One row per Type. `ruleId` is the codehash named in the descriptor header; `mandatory` is the
    /// pinned instance (the wrapper for grades 1–2, the deterministic rule instance for grade 3).
    struct TypeRow {
        // header word
        uint8 grade; // 1 STRUCTURAL 2 CUSTOM 3 NATIVE
        uint8 refCount;
        uint8 wrapperVersion;
        uint8 ruleMode; // 1 STATICCALL; 2 CALL reserved
        uint8 dependencyClass; // 1 pure 2 realm-reads 3 external-reads; 4, 5 reserved
        uint8 refHeaderWords; // 1..3
        uint24 validationGas; // 0 = ACCEPTOR_GAS_DEFAULT; a declared minimum
        uint16 policyRows;
        uint40 registeredAt;
        uint48 catalogOrdinal;
        uint8 codecVersion;
        uint8 textProfile;
        // pins
        bytes32 shape;
        bytes32 ruleId;
        address mandatory;
        address descriptorBlob;
        uint16 blobLength;
        bytes32 grammarProfile; // grades 1–2: the wrapper's pure constant; zero for native
    }

    /// @custom:storage-location erc7201:efs.registry.v2.types
    struct TypesStorage {
        mapping(bytes32 typeId => TypeRow) rows;
        mapping(bytes32 typeId => mapping(uint256 index => bytes32)) refTypes;
    }

    bytes32 internal constant TYPES_ROOT =
        0xb88a601303f5b59143b779b8925ece487b1fa8710d521523140b6c2d91568c00;

    function _types() internal pure returns (TypesStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TYPES_ROOT
        }
    }

    struct DeclarationRow {
        address key;
        uint8 installed;
        bytes32 signatureHash;
    }

    /// @custom:storage-location erc7201:efs.registry.v2.declarations
    struct DeclarationsStorage {
        mapping(bytes32 typeId => DeclarationRow) rows;
    }

    bytes32 internal constant DECLARATIONS_ROOT =
        0x8f2637a7c7ef5342894e46d7ac564c4785ed47b68917ca992a8f09c97592e400;

    function _declarations() internal pure returns (DeclarationsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := DECLARATIONS_ROOT
        }
    }

    /// Append-only per Type; row 1 is implicit (no policy). `acceptor == 0` is a no-policy row.
    struct PolicyRow {
        address acceptor;
        uint40 activatedAt;
        uint48 mutationAt;
        bytes32 codehash;
    }

    /// @custom:storage-location erc7201:efs.registry.v2.policy
    struct PolicyStorage {
        mapping(bytes32 typeId => mapping(uint256 row => PolicyRow)) rows;
    }

    bytes32 internal constant POLICY_ROOT =
        0x7607b3cefdb65ccdfb170dbf9826aca7c3eb2dc0e0e0e5b7bce6a5dffc3f8400;

    function _policy() internal pure returns (PolicyStorage storage $) {
        assembly ("memory-safe") {
            $.slot := POLICY_ROOT
        }
    }

    /// Append-only per role key (keccak(DOM_ROLE_KEY, purpose, role)).
    struct RoleRow {
        bytes32 expectedType;
        uint40 activatedAt;
        uint48 mutationAt;
    }

    /// @custom:storage-location erc7201:efs.registry.v2.roles
    struct RolesStorage {
        mapping(bytes32 roleKey => mapping(uint256 n => RoleRow)) rows;
        mapping(bytes32 roleKey => uint16) count;
    }

    bytes32 internal constant ROLES_ROOT =
        0xff16ead419b5fba0549e2629eb15e3f34a6f0ce7330d7cbb2139b6c4e90ceb00;

    function _roles() internal pure returns (RolesStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ROLES_ROOT
        }
    }

    /// Grade 2 only. `customAbi`: 1 = the IAcceptor/2 nested-call shape.
    struct BindingRow {
        address custom;
        uint8 customAbi;
        bytes32 bindingId;
    }

    /// @custom:storage-location erc7201:efs.registry.v2.bindings
    struct BindingsStorage {
        mapping(bytes32 typeId => BindingRow) rows;
    }

    bytes32 internal constant BINDINGS_ROOT =
        0x8a64542b45955b344eb3568068f1a96cd4fb0b1d8aae3976b48ef53dd8a65a00;

    function _bindings() internal pure returns (BindingsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BINDINGS_ROOT
        }
    }

    struct WrapperRow {
        address implementation;
        uint8 codecVersion;
        uint40 activatedAt;
        bytes32 codehash;
        bytes32 grammarProfile;
    }

    /// @custom:storage-location erc7201:efs.registry.v2.wrappers
    struct WrappersStorage {
        mapping(uint256 version => WrapperRow) rows;
    }

    bytes32 internal constant WRAPPERS_ROOT =
        0x1f2457b895e07513acc7a811602edc7bb7a689b9636346c7d88f35b713b9cc00;

    function _wrappers() internal pure returns (WrappersStorage storage $) {
        assembly ("memory-safe") {
            $.slot := WRAPPERS_ROOT
        }
    }

    /// @custom:storage-location erc7201:efs.registry.v2.catalog
    struct CatalogStorage {
        mapping(uint256 ordinal => bytes32) typeAt;
    }

    bytes32 internal constant CATALOG_ROOT =
        0xc84eebc1c1b2541cf63d04f7c3100d60f4e279f74ae58772ae0888ed60264000;

    function _catalog() internal pure returns (CatalogStorage storage $) {
        assembly ("memory-safe") {
            $.slot := CATALOG_ROOT
        }
    }

    /// @custom:storage-location erc7201:efs.registry.v2.control
    struct ControlStorage {
        address ledger;
        uint32 activeRevision;
        uint16 wrapperCount;
        uint48 mutations; // bumped by every activation; the per-callback basis re-check reads it
        uint48 catalogCount;
    }

    bytes32 internal constant CONTROL_ROOT =
        0x746f5ca92ad4053adbc9ee32a7eb3c5322aee798e9dd1d4ffd591785f460be00;

    function _control() internal pure returns (ControlStorage storage $) {
        assembly ("memory-safe") {
            $.slot := CONTROL_ROOT
        }
    }
}
