// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ITypeRegistry, TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";

/// A double was asked for behaviour it does not model (the selector names what was asked).
error MockUnsupported(bytes4 selector);
/// A double's setter, or `MockRegistry.bumpMutations`, was called by an account the double does not allow.
error MockCaller(address caller);

/// @notice Test-only `ITypeRegistry` double for kernel tests (design §16 preamble; implementation plan S1.1
///         "against a stub registry"). It serves the hot-path reads the kernel and the ingress make during a
///         publication (`typeInfo`, `refTypes`, `roleExpectation`, `mutations`, `activeRevision`, §5.9) plus
///         `ledger()` and `implementation()` from rows the test writes. Every other `ITypeRegistry` selector
///         reverts `MockUnsupported(selector)`.
/// @dev Writes are owner-only (the deployer), so a callback cannot rewrite a Type row behind the kernel's back:
///      the real registry's activations are idle-gated and bump `mutations`, and a mock that let a callback
///      change a row silently would test the mock, not the kernel. Nothing here bumps `mutations` implicitly;
///      the test calls `bumpMutations` where the real registry would have. An unknown Type reads as the zero
///      row (grade 0, mandatory 0) and the kernel decides what that means (`E_UNKNOWN_TYPE`). The owner may
///      open `bumpMutations` to other accounts (`setMutator`) so an index double can drift the basis from
///      inside a publication (`MutatingRule` in IndexDoubles.sol).
contract MockRegistry is ITypeRegistry {
    struct RoleExpectation {
        bytes32 expectedType;
        uint16 row;
    }

    address public immutable owner = msg.sender;

    mapping(bytes32 => TypeInfo) internal _types;
    mapping(bytes32 => bytes32[]) internal _refTypes;
    mapping(bytes32 => mapping(bytes32 => RoleExpectation)) internal _roles;
    mapping(address => bool) public mutator;
    uint64 internal _mutations;
    uint32 internal _activeRevision;
    address internal _ledger;
    address internal _implementation;

    modifier onlyOwner() {
        if (msg.sender != owner) revert MockCaller(msg.sender);
        _;
    }

    // ---- test setters -----------------------------------------------------------------------------------

    function setType(bytes32 typeId, TypeInfo memory info, bytes32[] memory refTypes_)
        external
        onlyOwner
    {
        _types[typeId] = info;
        _refTypes[typeId] = refTypes_;
    }

    function setRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType, uint16 row)
        external
        onlyOwner
    {
        _roles[purpose][role] = RoleExpectation(expectedType, row);
    }

    /// The owner, or an account the owner allowed with `setMutator`.
    function bumpMutations() external {
        if (msg.sender != owner && !mutator[msg.sender]) revert MockCaller(msg.sender);
        _mutations += 1;
    }

    function setMutator(address account, bool allowed) external onlyOwner {
        mutator[account] = allowed;
    }

    function setActiveRevision(uint32 revision) external onlyOwner {
        _activeRevision = revision;
    }

    function setLedger(address ledger_) external onlyOwner {
        _ledger = ledger_;
    }

    function setImplementation(address implementation_) external onlyOwner {
        _implementation = implementation_;
    }

    // ---- hot path -----------------------------------------------------------------------------------------

    function typeInfo(bytes32 typeId) external view returns (TypeInfo memory) {
        return _types[typeId];
    }

    function refTypes(bytes32 typeId) external view returns (bytes32[] memory) {
        return _refTypes[typeId];
    }

    function roleExpectation(bytes32 purpose, bytes32 role)
        external
        view
        returns (bytes32 expectedType, uint16 row)
    {
        RoleExpectation storage r = _roles[purpose][role];
        return (r.expectedType, r.row);
    }

    function mutations() public view virtual returns (uint64) {
        return _mutations;
    }

    function activeRevision() external view returns (uint32) {
        return _activeRevision;
    }

    function implementation() external view returns (address) {
        return _implementation;
    }

    function ledger() external view returns (address) {
        return _ledger;
    }

    // ---- not modelled -------------------------------------------------------------------------------------

    function retainDeclaration(bytes calldata, bytes calldata)
        external
        pure
        returns (bytes32, address)
    {
        revert MockUnsupported(ITypeRegistry.retainDeclaration.selector);
    }

    function registerDescribed(bytes calldata, bytes calldata, address, bytes calldata)
        external
        pure
        returns (bytes32, uint64)
    {
        revert MockUnsupported(ITypeRegistry.registerDescribed.selector);
    }

    function activatePolicy(bytes32, address) external pure returns (uint16) {
        revert MockUnsupported(ITypeRegistry.activatePolicy.selector);
    }

    function declareRoleExpectation(bytes32, bytes32, bytes32) external pure returns (uint16) {
        revert MockUnsupported(ITypeRegistry.declareRoleExpectation.selector);
    }

    function activateWrapper(uint8, address) external pure {
        revert MockUnsupported(ITypeRegistry.activateWrapper.selector);
    }

    function initialize(address, address) external pure {
        revert MockUnsupported(ITypeRegistry.initialize.selector);
    }

    function activate(uint32) external pure {
        revert MockUnsupported(ITypeRegistry.activate.selector);
    }

    function catalog(uint64) external pure returns (bytes32) {
        revert MockUnsupported(ITypeRegistry.catalog.selector);
    }

    function catalogCount() external pure returns (uint64) {
        revert MockUnsupported(ITypeRegistry.catalogCount.selector);
    }

    function descriptorBytes(bytes32) external pure returns (bytes memory) {
        revert MockUnsupported(ITypeRegistry.descriptorBytes.selector);
    }

    function declaration(bytes32) external pure returns (address, bool, bytes32) {
        revert MockUnsupported(ITypeRegistry.declaration.selector);
    }

    function policy(bytes32, uint16) external pure returns (address, bytes32, uint64, uint64) {
        revert MockUnsupported(ITypeRegistry.policy.selector);
    }

    function roleRow(bytes32, bytes32, uint16) external pure returns (bytes32, uint64) {
        revert MockUnsupported(ITypeRegistry.roleRow.selector);
    }

    function roleRows(bytes32, bytes32) external pure returns (uint16) {
        revert MockUnsupported(ITypeRegistry.roleRows.selector);
    }

    function wrapper(uint8) external pure returns (address, bytes32, uint8, bytes32) {
        revert MockUnsupported(ITypeRegistry.wrapper.selector);
    }

    function binding(bytes32) external pure returns (address, uint8, bytes32) {
        revert MockUnsupported(ITypeRegistry.binding.selector);
    }

    function typeCommitment(bytes32) external pure returns (bytes32) {
        revert MockUnsupported(ITypeRegistry.typeCommitment.selector);
    }
}

/// @notice A `MockRegistry` whose observed mutation counter moves during a publication, for the per-leaf basis
///         re-check test (design §6.4: after every leaf's callback, `registry.mutations() == snapshot` else
///         `E_REGISTRY_DRIFT`).
/// @dev Interface limitation: the brief asked for a `typeInfo()` that bumps `mutations` on every call, but
///      `ITypeRegistry.typeInfo` is `view` and the kernel reaches it by `STATICCALL`, so no registry can write
///      (or `TSTORE`) there. The nearest behaviour that needs no write: while armed, `mutations()` reports
///      the stored counter plus `ILedgerHot(ledger).counts().admissions`. The kernel snapshots the counter at
///      entry (§6.1 step 9) and `_checkpoint` makes each leaf's admission visible through `counts()` before
///      the re-check, so the first re-check of every publication sees a moved counter — the drift a
///      per-leaf Type-row read would have caused. Outside a publication the counter also moves with every
///      committed admission; disarm it (`arm(false)`) for set-up publications.
contract MutatingRegistry is MockRegistry {
    bool public armed = true;

    function arm(bool on) external onlyOwner {
        armed = on;
    }

    function mutations() public view override returns (uint64) {
        uint64 stored = super.mutations();
        if (!armed || _ledger == address(0)) return stored;
        (uint64 admissions,,,) = ILedgerHot(_ledger).counts();
        return stored + admissions;
    }
}
