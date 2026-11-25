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
        uint8 flags; // descriptor byte 133: bit 0 TYPE_FLAG_EMITS_BODY (packed in the header word, bits 192..199)
        // pins
        bytes32 shape;
        bytes32 ruleId;
        address mandatory;
        address descriptorBlob;
        uint16 blobLength;
        bytes32 grammarProfile; // grades 1–2: the wrapper's pure constant; zero for native
    }

    /// @custom:storage-location erc7201:efs.registry.types
    struct TypesStorage {
        mapping(bytes32 typeId => TypeRow) rows;
        mapping(bytes32 typeId => mapping(uint256 index => bytes32)) refTypes;
    }

    bytes32 internal constant TYPES_ROOT =
        0xf33da83cec8cfa19b823e041c9adb0176a906c07f2b895fc2182be31f9d30100;

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

    /// @custom:storage-location erc7201:efs.registry.declarations
    struct DeclarationsStorage {
        mapping(bytes32 typeId => DeclarationRow) rows;
    }

    bytes32 internal constant DECLARATIONS_ROOT =
        0xcd8e6cb67099bf4deab380a79e39e866feedda3f0365bab5f4c71bd0b7220500;

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

    /// @custom:storage-location erc7201:efs.registry.policy
    struct PolicyStorage {
        mapping(bytes32 typeId => mapping(uint256 row => PolicyRow)) rows;
    }

    bytes32 internal constant POLICY_ROOT =
        0xf79f93f502a9f1db3ca03146652b2c7e63c6e515716b59dda68bf801d5d37700;

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

    /// @custom:storage-location erc7201:efs.registry.roles
    struct RolesStorage {
        mapping(bytes32 roleKey => mapping(uint256 n => RoleRow)) rows;
        mapping(bytes32 roleKey => uint16) count;
    }

    bytes32 internal constant ROLES_ROOT =
        0x6864ecb50b786d57d32a993ea982bcb79fe8ccac6d2ff77ca134e1ab5ada1500;

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

    /// @custom:storage-location erc7201:efs.registry.bindings
    struct BindingsStorage {
        mapping(bytes32 typeId => BindingRow) rows;
    }

    bytes32 internal constant BINDINGS_ROOT =
        0x7f74cb4214d2027c0c0b9f1f324390fbcac1113b4ba0b4a3cf89779ed1dd0a00;

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

    /// @custom:storage-location erc7201:efs.registry.wrappers
    struct WrappersStorage {
        mapping(uint256 version => WrapperRow) rows;
    }

    bytes32 internal constant WRAPPERS_ROOT =
        0x5ba824ff1a0cd666e5f4d466df1e8dc1c48bab3e6b5f3f782f0484396c78cb00;

    function _wrappers() internal pure returns (WrappersStorage storage $) {
        assembly ("memory-safe") {
            $.slot := WRAPPERS_ROOT
        }
    }

    /// @custom:storage-location erc7201:efs.registry.catalog
    struct CatalogStorage {
        mapping(uint256 ordinal => bytes32) typeAt;
    }

    bytes32 internal constant CATALOG_ROOT =
        0xc291987f9a0dae7a0ba69b59a92083e69a889825804dd3b1b561b0d85218a000;

    function _catalog() internal pure returns (CatalogStorage storage $) {
        assembly ("memory-safe") {
            $.slot := CATALOG_ROOT
        }
    }

    /// @custom:storage-location erc7201:efs.registry.control
    struct ControlStorage {
        address ledger;
        uint32 activeRevision;
        uint16 wrapperCount;
        uint48 mutations; // bumped by every activation; the per-callback basis re-check reads it
        uint48 catalogCount;
    }

    bytes32 internal constant CONTROL_ROOT =
        0xd66677389f9bccfb9c56e4cd57ee93fada10258bbfc71f9559907a6a53b2ea00;

    function _control() internal pure returns (ControlStorage storage $) {
        assembly ("memory-safe") {
            $.slot := CONTROL_ROOT
        }
    }
}
