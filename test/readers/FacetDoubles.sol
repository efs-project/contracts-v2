// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LedgerApply} from "../../src/core/LedgerApply.sol";
import {LedgerStorage} from "../../src/core/storage/LedgerStorage.sol";
import {Action, ActionKind} from "../../src/interfaces/Actions.sol";
import {Effect} from "../../src/interfaces/Index.sol";
import {ITypeRegistry, TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {MockCaller, MockUnsupported} from "../harness/doubles/MockRegistry.sol";

/// @notice Test-only `ITypeRegistry` double for the facet suites: the hot-path rows the kernel reads during a
///         publication (as `MockRegistry` serves them) plus the history rows the facets read back — policy rows
///         (`policy(typeId, row)`), role rows (`roleRow`, `roleRows`, the latest of which `roleExpectation`
///         serves) and `catalogCount`. Writes are owner-only; nothing bumps `mutations` implicitly.
contract FacetRegistry is ITypeRegistry {
    struct PolicyRow {
        address acceptor;
        bytes32 codehash;
        uint64 activatedAt;
        uint64 mutationAt;
    }

    struct RoleRow {
        bytes32 expectedType;
        uint64 activatedAt;
    }

    address public immutable owner = msg.sender;

    mapping(bytes32 => TypeInfo) internal _types;
    mapping(bytes32 => bytes32[]) internal _refTypes;
    mapping(bytes32 => mapping(uint16 => PolicyRow)) internal _policies;
    mapping(bytes32 => mapping(bytes32 => RoleRow[])) internal _roles;
    uint64 internal _mutations;
    uint64 internal _catalogCount;
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

    function setPolicyRow(bytes32 typeId, uint16 row, PolicyRow memory p) external onlyOwner {
        _policies[typeId][row] = p;
    }

    /// Appends role row `n = roleRows + 1`; `roleExpectation` serves the latest row.
    function addRoleRow(bytes32 purpose, bytes32 role, bytes32 expectedType, uint64 activatedAt)
        external
        onlyOwner
        returns (uint16 row)
    {
        _roles[purpose][role].push(RoleRow(expectedType, activatedAt));
        row = uint16(_roles[purpose][role].length);
    }

    function bumpMutations() external onlyOwner {
        _mutations += 1;
    }

    function setCatalogCount(uint64 n) external onlyOwner {
        _catalogCount = n;
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

    // ---- served rows --------------------------------------------------------------------------------------

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
        RoleRow[] storage rows = _roles[purpose][role];
        if (rows.length == 0) return (0, 0);
        return (rows[rows.length - 1].expectedType, uint16(rows.length));
    }

    function mutations() external view returns (uint64) {
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

    function catalogCount() external view returns (uint64) {
        return _catalogCount;
    }

    function policy(bytes32 typeId, uint16 row)
        external
        view
        returns (address acceptor, bytes32 codehash, uint64 activatedAt, uint64 mutationAt)
    {
        PolicyRow storage p = _policies[typeId][row];
        return (p.acceptor, p.codehash, p.activatedAt, p.mutationAt);
    }

    function roleRow(bytes32 purpose, bytes32 role, uint16 n)
        external
        view
        returns (bytes32 expectedType, uint64 activatedAt)
    {
        RoleRow storage r = _roles[purpose][role][n - 1];
        return (r.expectedType, r.activatedAt);
    }

    function roleRows(bytes32 purpose, bytes32 role) external view returns (uint16) {
        return uint16(_roles[purpose][role].length);
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

    function descriptorBytes(bytes32) external pure returns (bytes memory) {
        revert MockUnsupported(ITypeRegistry.descriptorBytes.selector);
    }

    function declaration(bytes32) external pure returns (address, bool, bytes32) {
        revert MockUnsupported(ITypeRegistry.declaration.selector);
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

    function FACTORY() external pure returns (address) {
        revert MockUnsupported(ITypeRegistry.FACTORY.selector);
    }

    function DESCRIPTOR_STORE() external pure returns (address) {
        revert MockUnsupported(ITypeRegistry.DESCRIPTOR_STORE.selector);
    }

    function predictInstance(bytes32) external pure returns (address) {
        revert MockUnsupported(ITypeRegistry.predictInstance.selector);
    }

    function declarationDigest(bytes32) external pure returns (bytes32) {
        revert MockUnsupported(ITypeRegistry.declarationDigest.selector);
    }

    function bindingDigest(bytes32) external pure returns (bytes32) {
        revert MockUnsupported(ITypeRegistry.bindingDigest.selector);
    }
}

contract RevertingEverything {
    error Refused();

    fallback() external payable {
        revert Refused();
    }
}

/// @notice Test-only apply delegate that completes the bind-kind admission rows the way design §4.3 specifies
///         them and the committed `LedgerApply` does not yet write: `bindingOrdinal` (so
///         `position[bindingPosition[bindingOrdinal]]` re-derives purpose/subject/role) and `expectedRevision`.
///         It DELEGATECALLs the real `LedgerApply` (so every other write is the real one), then adds the two
///         fields to the row in the kernel's own storage and returns the real reply unchanged. It lets the facet
///         suites prove the `Effect/3` reconstruction against a kernel that records what the design says it
///         records; it is never a release component.
contract RowCompleteApply is LedgerStorage {
    LedgerApply public immutable INNER;

    constructor() {
        INNER = new LedgerApply();
    }

    function applyLeaf(
        uint8,
        uint64 admission,
        Action calldata action,
        bytes calldata,
        uint8,
        bytes32,
        uint8,
        uint16,
        uint16
    ) external returns (Effect memory effect, uint256 refCountOut, bytes32[8] memory refs) {
        (bool ok, bytes memory ret) = address(INNER).delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        (effect, refCountOut, refs) = abi.decode(ret, (Effect, uint256, bytes32[8]));
        uint8 kind = action.kind;
        if (kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE) {
            AdmissionRow storage row = _admissions().rows[admission];
            row.bindingOrdinal = uint48(effect.bindingOrdinal);
            row.expectedRevision = uint48(action.expectedRevision);
        }
    }
}
