// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {RegistryStorage} from "./storage/RegistryStorage.sol";
import {DescribedCodec} from "./DescribedCodec.sol";
import {Keys} from "../lib/Keys.sol";
import {CodePins} from "../lib/CodePins.sol";
import {CodeScan} from "../lib/CodeScan.sol";
import {Phase} from "../interfaces/Results.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ITypeRegistry, TypeInfo} from "../interfaces/ITypeRegistry.sol";
import {IDescriptorStore} from "../interfaces/internal/IDescriptorStore.sol";
import {IDescribedWrapper} from "../interfaces/internal/IDescribedWrapper.sol";
import {
    E_BINDING,
    E_BLOB,
    E_DECLARATION,
    E_FROZEN,
    E_INSTANCE,
    E_NOT_CONTROLLER,
    E_PUBLICATION_ACTIVE,
    E_ROLE_ROWS,
    E_TYPE_EXISTS,
    E_UNKNOWN_TYPE,
    E_WRAPPER
} from "../interfaces/Errors.sol";

/// @title TypeRegistry — the proxied Type registry (design §9, §5.9, §4.5)
/// @notice Registration is permissionless, atomic and idempotent; activations are controller-only (the
///         controller is `ILedgerHot(ledger).controller()`), idle-gated through `ledger.phase()`, refused when
///         `ledger.control().frozen`, append-only, and bump `mutations`. The registry stores no controller and
///         no frozen flag of its own, so a controller migration or a freeze needs no registry write.
/// @dev Implementation immutables are pinned per revision through `implementation()`'s codehash in the
///      ledger's revision row. `DESCRIPTOR_STORE` and the deterministic-deployment `FACTORY` are closure facts
///      of the build; `SELF` guards nothing here (every entry is meant for the proxy) and is kept for parity.
contract TypeRegistry is ITypeRegistry, Initializable, RegistryStorage {
    address public immutable DESCRIPTOR_STORE;
    /// The EIP-7997 deterministic-deployment factory: every NATIVE rule instance is CREATE2(FACTORY, 0, initcode).
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// The chain-free EIP-712 domain of Type declarations: `(name = "EFS Type Declaration", version = "1")`.
    bytes32 public constant DECLARATION_DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version)"),
            keccak256("EFS Type Declaration"),
            keccak256("1")
        )
    );
    bytes32 public constant DECLARATION_TYPEHASH = keccak256("TypeDeclaration(bytes32 typeId)");
    bytes32 public constant BINDING_TYPEHASH = keccak256("TypeBinding(bytes32 bindingId)");
    bytes32 public constant BINDING_DOMAIN = keccak256("efs2/described-binding/1");
    uint8 private constant CUSTOM_ABI_NESTED = 1;
    uint256 private constant SECP256K1_HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    constructor(address descriptorStore) {
        DESCRIPTOR_STORE = descriptorStore;
        _disableInitializers();
    }

    // =============================================================================================
    // Gates (design §9.4): the controller, the idle ledger, the unfrozen Realm
    // =============================================================================================

    modifier onlyController() {
        if (msg.sender != ILedgerHot(_control().ledger).controller()) {
            revert E_NOT_CONTROLLER(msg.sender);
        }
        _;
    }

    modifier idleUnfrozen() {
        ILedgerHot hot = ILedgerHot(_control().ledger);
        (uint8 phase,,,) = hot.phase();
        if (phase != Phase.IDLE) revert E_PUBLICATION_ACTIVE();
        (,,, bool frozen) = hot.control();
        if (frozen) revert E_FROZEN();
        _;
    }

    // =============================================================================================
    // Lifecycle
    // =============================================================================================

    /// @inheritdoc ITypeRegistry
    function initialize(address ledger_, address wrapperV1) external initializer {
        _control().ledger = ledger_;
        if (wrapperV1 != address(0)) _recordWrapper(1, wrapperV1);
    }

    /// @inheritdoc ITypeRegistry
    function activate(uint32 revision)
        external
        reinitializer(uint64(revision) + 1)
        onlyController
        idleUnfrozen
    {
        ControlStorage storage c = _control();
        c.activeRevision = revision;
        c.mutations += 1;
    }

    // =============================================================================================
    // Hot path (design §5.9): the only registry reads during a publication
    // =============================================================================================

    /// @inheritdoc ITypeRegistry
    function typeInfo(bytes32 typeId) external view returns (TypeInfo memory info) {
        TypeRow storage row = _types().rows[typeId];
        if (row.grade == 0) return info;
        info.grade = row.grade;
        info.refCount = row.refCount;
        info.wrapperVersion = row.wrapperVersion;
        info.ruleMode = row.ruleMode;
        info.dependencyClass = row.dependencyClass;
        info.refHeaderWords = row.refHeaderWords;
        info.validationGas = row.validationGas;
        info.policyRows = row.policyRows;
        info.mandatory = row.mandatory;
        info.ruleId = row.ruleId;
        info.shape = row.shape;
        info.descriptorBlob = row.descriptorBlob;
        info.policyRow = row.policyRows;
        if (row.policyRows > 1) {
            PolicyRow storage p = _policy().rows[typeId][row.policyRows];
            info.policy = p.acceptor;
            info.policyCodehash = p.codehash;
        }
        if (row.grade == DescribedCodec.GRADE_CUSTOM) {
            BindingRow storage b = _bindings().rows[typeId];
            info.custom = b.custom;
            info.bindingId = b.bindingId;
        }
    }

    /// @inheritdoc ITypeRegistry
    function refTypes(bytes32 typeId) external view returns (bytes32[] memory out) {
        TypesStorage storage $ = _types();
        uint256 n = $.rows[typeId].refCount;
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = $.refTypes[typeId][i];
        }
    }

    /// @inheritdoc ITypeRegistry
    function roleExpectation(bytes32 purpose, bytes32 role)
        external
        view
        returns (bytes32 expectedType, uint16 row)
    {
        RolesStorage storage $ = _roles();
        bytes32 key = Keys.roleKey(purpose, role);
        row = $.count[key];
        if (row != 0) expectedType = $.rows[key][row].expectedType;
    }

    /// @inheritdoc ITypeRegistry
    function mutations() external view returns (uint64) {
        return _control().mutations;
    }

    /// @inheritdoc ITypeRegistry
    function activeRevision() external view returns (uint32) {
        return _control().activeRevision;
    }

    // =============================================================================================
    // Registration (design §9.3): permissionless, atomic, idempotent
    // =============================================================================================

    /// @inheritdoc ITypeRegistry
    function retainDeclaration(bytes calldata descriptor, bytes calldata declarationSig)
        external
        returns (bytes32 typeId, address blob)
    {
        (typeId, blob,,) = _retain(descriptor, declarationSig);
    }

    function _retain(bytes calldata descriptor, bytes calldata declarationSig)
        private
        returns (
            bytes32 typeId,
            address blob,
            DescribedCodec.Header memory h,
            bytes32[] memory refs
        )
    {
        (h, refs) = DescribedCodec.parse(descriptor);
        typeId = Keys.typeId(Keys.shape(descriptor), refs, h.ruleCodehash);
        _verifyDeclaration(typeId, h.declarationKey, declarationSig);
        blob = IDescriptorStore(DESCRIPTOR_STORE).predict(descriptor, declarationSig);
        if (blob.codehash != keccak256(bytes.concat(hex"00", descriptor, declarationSig))) {
            revert E_BLOB(blob);
        }
        DeclarationRow storage d = _declarations().rows[typeId];
        d.key = h.declarationKey;
        d.signatureHash = keccak256(declarationSig);
    }

    /// @inheritdoc ITypeRegistry
    function registerDescribed(
        bytes calldata descriptor,
        bytes calldata declarationSig,
        address nativeOrCustom,
        bytes calldata bindingSig
    ) external returns (bytes32 typeId, uint64 catalogOrdinal) {
        (bytes32 id, address blob, DescribedCodec.Header memory h, bytes32[] memory refs) =
            _retain(descriptor, declarationSig);
        typeId = id;
        TypeRow storage row = _types().rows[typeId];
        if (row.grade != 0) {
            _requireSameBinding(typeId, row, h, nativeOrCustom);
            return (typeId, row.catalogOrdinal);
        }
        address mandatory;
        bytes32 grammarProfile;
        if (h.grade == DescribedCodec.GRADE_NATIVE) {
            if (nativeOrCustom != predictInstance(h.auxHash)) {
                revert E_INSTANCE(predictInstance(h.auxHash), nativeOrCustom);
            }
            CodePins.requireRealCode(nativeOrCustom);
            if (nativeOrCustom.codehash != h.ruleCodehash) revert E_BINDING(4);
            if (bindingSig.length != 0) revert E_BINDING(1);
            mandatory = nativeOrCustom;
        } else {
            WrapperRow storage w = _wrappers().rows[h.wrapperVersion];
            if (w.implementation == address(0)) revert E_WRAPPER(1);
            if (w.codehash != h.ruleCodehash) revert E_WRAPPER(2);
            mandatory = w.implementation;
            grammarProfile = w.grammarProfile;
            if (h.grade == DescribedCodec.GRADE_STRUCTURAL) {
                if (nativeOrCustom != address(0) || bindingSig.length != 0) revert E_BINDING(1);
            } else {
                CodePins.requireRealCode(nativeOrCustom);
                if (nativeOrCustom.codehash != h.auxHash) revert E_BINDING(3);
                bytes32 bindingId =
                    _bindingId(w.codehash, typeId, nativeOrCustom, h.auxHash, h.declarationKey);
                _verifyBinding(bindingId, h.declarationKey, bindingSig);
                BindingRow storage b = _bindings().rows[typeId];
                b.custom = nativeOrCustom;
                b.customAbi = CUSTOM_ABI_NESTED;
                b.bindingId = bindingId;
            }
        }
        ControlStorage storage c = _control();
        uint48 ordinal = c.catalogCount + 1;
        c.catalogCount = ordinal;
        _catalog().typeAt[ordinal] = typeId;
        row.grade = h.grade;
        row.refCount = uint8(refs.length);
        row.wrapperVersion = h.wrapperVersion;
        row.ruleMode = h.ruleMode;
        row.dependencyClass = h.dependencyClass;
        row.refHeaderWords = h.refHeaderWords;
        row.validationGas = h.validationGas;
        row.policyRows = 1;
        row.registeredAt = uint40(block.number);
        row.catalogOrdinal = ordinal;
        row.codecVersion = 1;
        row.textProfile = h.textProfile;
        row.shape = Keys.shape(descriptor);
        row.ruleId = h.ruleCodehash;
        row.mandatory = mandatory;
        row.descriptorBlob = blob;
        row.blobLength = uint16(descriptor.length);
        row.grammarProfile = grammarProfile;
        for (uint256 i; i < refs.length; ++i) {
            _types().refTypes[typeId][i] = refs[i];
        }
        _declarations().rows[typeId].installed = 1;
        emit TypeRegistered(typeId, h.grade, ordinal, mandatory, blob);
        return (typeId, ordinal);
    }

    /// An existing row is idempotent only under the identical binding; anything else is a divergence.
    function _requireSameBinding(
        bytes32 typeId,
        TypeRow storage row,
        DescribedCodec.Header memory h,
        address nativeOrCustom
    ) private view {
        if (row.grade != h.grade) revert E_TYPE_EXISTS(typeId);
        if (h.grade == DescribedCodec.GRADE_NATIVE) {
            if (row.mandatory != nativeOrCustom) revert E_TYPE_EXISTS(typeId);
        } else if (h.grade == DescribedCodec.GRADE_STRUCTURAL) {
            if (nativeOrCustom != address(0)) revert E_BINDING(1);
        } else if (_bindings().rows[typeId].custom != nativeOrCustom) {
            revert E_BINDING(6);
        }
    }

    /// The deterministic NATIVE instance of a descriptor: CREATE2(FACTORY, salt 0, initcode with that hash).
    function predictInstance(bytes32 ruleInitcodeHash) public pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), FACTORY, bytes32(0), ruleInitcodeHash))
                )
            )
        );
    }

    function _bindingId(
        bytes32 wrapperCodehash,
        bytes32 typeId,
        address custom,
        bytes32 customHash,
        address key
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                BINDING_DOMAIN,
                wrapperCodehash,
                block.chainid,
                address(this),
                typeId,
                custom,
                customHash,
                uint256(CUSTOM_ABI_NESTED),
                key
            )
        );
    }

    /// The EIP-712 digest a creator signs to declare a Type (chain-free: the same bytes verify on every chain).
    function declarationDigest(bytes32 typeId) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                DECLARATION_DOMAIN_SEPARATOR,
                keccak256(abi.encode(DECLARATION_TYPEHASH, typeId))
            )
        );
    }

    /// The EIP-712 digest a creator signs to bind a custom predicate on this chain and registry.
    function bindingDigest(bytes32 bindingId) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                DECLARATION_DOMAIN_SEPARATOR,
                keccak256(abi.encode(BINDING_TYPEHASH, bindingId))
            )
        );
    }

    function _verifyDeclaration(bytes32 typeId, address key, bytes calldata sig) private pure {
        uint8 code = _recoverMismatch(declarationDigest(typeId), key, sig);
        if (code != 0) revert E_DECLARATION(code);
    }

    function _verifyBinding(bytes32 bindingId, address key, bytes calldata sig) private pure {
        uint8 code = _recoverMismatch(bindingDigest(bindingId), key, sig);
        if (code != 0) revert E_BINDING(code == 1 ? 7 : code == 2 ? 8 : code == 3 ? 9 : 5);
    }

    /// 0 when `sig` is a canonical 65-byte secp256k1 signature of `digest` by `key`; else 1 length,
    /// 2 malleable or bad v, 3 unrecoverable, 4 another signer.
    function _recoverMismatch(bytes32 digest, address key, bytes calldata sig)
        private
        pure
        returns (uint8)
    {
        if (sig.length != 65) return 1;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > SECP256K1_HALF_ORDER || (v != 27 && v != 28)) return 2;
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) return 3;
        return signer == key ? 0 : 4;
    }

    // =============================================================================================
    // Activations (design §9.4): controller, idle, unfrozen, append-only, mutations bumped
    // =============================================================================================

    /// @inheritdoc ITypeRegistry
    function activatePolicy(bytes32 typeId, address acceptor)
        external
        onlyController
        idleUnfrozen
        returns (uint16 row)
    {
        TypeRow storage t = _types().rows[typeId];
        if (t.grade == 0) revert E_UNKNOWN_TYPE(0, typeId);
        bytes32 codehash;
        if (acceptor != address(0)) {
            CodePins.requireRealCode(acceptor);
            CodeScan.requirePlainRuntime(acceptor);
            codehash = acceptor.codehash;
        }
        row = t.policyRows + 1;
        t.policyRows = row;
        ControlStorage storage c = _control();
        uint48 m = c.mutations + 1;
        c.mutations = m;
        _policy().rows[typeId][row] = PolicyRow({
            acceptor: acceptor, activatedAt: uint40(block.number), mutationAt: m, codehash: codehash
        });
        emit PolicyActivated(typeId, row, acceptor, codehash);
    }

    /// @inheritdoc ITypeRegistry
    function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType)
        external
        onlyController
        idleUnfrozen
        returns (uint16 row)
    {
        RolesStorage storage $ = _roles();
        bytes32 key = Keys.roleKey(purpose, role);
        uint16 n = $.count[key];
        if (n == type(uint16).max) revert E_ROLE_ROWS();
        row = n + 1;
        $.count[key] = row;
        ControlStorage storage c = _control();
        uint48 m = c.mutations + 1;
        c.mutations = m;
        $.rows[key][row] =
            RoleRow({expectedType: expectedType, activatedAt: uint40(block.number), mutationAt: m});
        emit RoleExpectationDeclared(purpose, role, row, expectedType);
    }

    /// @inheritdoc ITypeRegistry
    function activateWrapper(uint8 version, address implementation)
        external
        onlyController
        idleUnfrozen
    {
        _recordWrapper(version, implementation);
        _control().mutations += 1;
    }

    function _recordWrapper(uint8 version, address implementation) private {
        if (version == 0) revert E_WRAPPER(3);
        WrappersStorage storage $ = _wrappers();
        if ($.rows[version].implementation != address(0)) revert E_WRAPPER(4);
        CodePins.requireRealCode(implementation);
        CodeScan.requirePlainRuntime(implementation);
        uint8 codec =
            uint8(uint256(_constant(implementation, IDescribedWrapper.codecVersion.selector)));
        bytes32 grammar = _constant(implementation, IDescribedWrapper.grammarProfile.selector);
        $.rows[version] = WrapperRow({
            implementation: implementation,
            codecVersion: codec,
            activatedAt: uint40(block.number),
            codehash: implementation.codehash,
            grammarProfile: grammar
        });
        _control().wrapperCount += 1;
        emit WrapperActivated(version, implementation, implementation.codehash, codec, grammar);
    }

    /// One of the wrapper's pure constants, or `E_WRAPPER(5)` when the build does not answer as a wrapper.
    function _constant(address implementation, bytes4 selector)
        private
        view
        returns (bytes32 word)
    {
        (bool ok, bytes memory ret) = implementation.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length != 32) revert E_WRAPPER(5);
        word = abi.decode(ret, (bytes32));
    }

    // =============================================================================================
    // Enumeration and discovery
    // =============================================================================================

    /// @inheritdoc ITypeRegistry
    function implementation() external view returns (address impl) {
        assembly ("memory-safe") {
            impl := sload(IMPLEMENTATION_SLOT)
        }
    }

    /// @inheritdoc ITypeRegistry
    function ledger() external view returns (address) {
        return _control().ledger;
    }

    /// @inheritdoc ITypeRegistry
    function catalog(uint64 ordinal) external view returns (bytes32) {
        return _catalog().typeAt[ordinal];
    }

    /// @inheritdoc ITypeRegistry
    function catalogCount() external view returns (uint64) {
        return _control().catalogCount;
    }

    /// @inheritdoc ITypeRegistry
    function descriptorBytes(bytes32 typeId) external view returns (bytes memory out) {
        TypeRow storage row = _types().rows[typeId];
        address blob = row.descriptorBlob;
        uint256 len = row.blobLength;
        out = new bytes(len);
        assembly ("memory-safe") {
            extcodecopy(blob, add(out, 32), 1, len)
        }
    }

    /// @inheritdoc ITypeRegistry
    function declaration(bytes32 typeId)
        external
        view
        returns (address key, bool installed, bytes32 signatureHash)
    {
        DeclarationRow storage d = _declarations().rows[typeId];
        return (d.key, d.installed != 0, d.signatureHash);
    }

    /// @inheritdoc ITypeRegistry
    function policy(bytes32 typeId, uint16 row)
        external
        view
        returns (address acceptor, bytes32 codehash, uint64 activatedAt, uint64 mutationAt)
    {
        PolicyRow storage p = _policy().rows[typeId][row];
        return (p.acceptor, p.codehash, p.activatedAt, p.mutationAt);
    }

    /// @inheritdoc ITypeRegistry
    function roleRow(bytes32 purpose, bytes32 role, uint16 n)
        external
        view
        returns (bytes32 expectedType, uint64 activatedAt)
    {
        RoleRow storage r = _roles().rows[Keys.roleKey(purpose, role)][n];
        return (r.expectedType, r.activatedAt);
    }

    /// @inheritdoc ITypeRegistry
    function roleRows(bytes32 purpose, bytes32 role) external view returns (uint16) {
        return _roles().count[Keys.roleKey(purpose, role)];
    }

    /// @inheritdoc ITypeRegistry
    function wrapper(uint8 version)
        external
        view
        returns (
            address implementation_,
            bytes32 codehash,
            uint8 codecVersion,
            bytes32 grammarProfile
        )
    {
        WrapperRow storage w = _wrappers().rows[version];
        return (w.implementation, w.codehash, w.codecVersion, w.grammarProfile);
    }

    /// @inheritdoc ITypeRegistry
    function binding(bytes32 typeId)
        external
        view
        returns (address custom, uint8 customAbi, bytes32 bindingId)
    {
        BindingRow storage b = _bindings().rows[typeId];
        return (b.custom, b.customAbi, b.bindingId);
    }

    /// @inheritdoc ITypeRegistry
    function typeCommitment(bytes32 typeId) external view returns (bytes32) {
        TypeRow storage row = _types().rows[typeId];
        bytes32 policyCodehash;
        if (row.policyRows > 1) policyCodehash = _policy().rows[typeId][row.policyRows].codehash;
        return
            keccak256(abi.encode(typeId, row.mandatory, row.ruleId, row.policyRows, policyCodehash));
    }

    // ---- events (acceleration only; every fact above is readable from state) --------------------------------

    event TypeRegistered(
        bytes32 indexed typeId, uint8 grade, uint64 catalogOrdinal, address mandatory, address blob
    );
    event PolicyActivated(bytes32 indexed typeId, uint16 row, address acceptor, bytes32 codehash);
    event RoleExpectationDeclared(
        bytes32 indexed purpose, bytes32 indexed role, uint16 row, bytes32 expectedType
    );
    event WrapperActivated(
        uint8 indexed version,
        address implementation,
        bytes32 codehash,
        uint8 codecVersion,
        bytes32 grammarProfile
    );
}
