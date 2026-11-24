// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AcceptContext, IAcceptor, RefHeader} from "../src/interfaces/IAcceptor.sol";
import {Action, Coordinate, Native} from "../src/interfaces/Actions.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../src/interfaces/ILedgerHot.sol";
import {ITypeRegistry} from "../src/interfaces/ITypeRegistry.sol";
import {IDescriptorStore} from "../src/interfaces/internal/IDescriptorStore.sol";
import {TypeRegistry} from "../src/types/TypeRegistry.sol";
import {EfsNative} from "../src/lib/EfsNative.sol";
import {Keys} from "../src/lib/Keys.sol";

/// @title NativeAppRule — the example's NATIVE acceptance rule (IAcceptor/2)
/// @notice Accepts a non-empty body whose first byte is not `0xff`; anything else is refused, which the kernel
///         reports as `E_REJECTED(leaf, typeId)`. No storage and no immutables, so its runtime — and therefore
///         its codehash, its `ruleId` and the Type id — is identical on every chain, and its instance is
///         `CREATE2(TypeRegistry.FACTORY, 0, creationCode)` everywhere.
contract NativeAppRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        if (ctx.ledger != msg.sender || body.length == 0 || body[0] == 0xff) {
            return bytes4(0);
        }
        return IAcceptor.accept.selector;
    }
}

/// @title NativeApp — a tiny external Solidity consumer of an EFS v2 ledger (design §12.3)
/// @notice At initialization it deploys its own NATIVE rule at the deterministic instance (the EIP-7997 factory,
///         salt 0), retains the declaration it was given (descriptor bytes + the declaration key's signature) in
///         the registry's descriptor store and registers the Type — idempotently, so any number of apps (or
///         proxies of this one) share one Type. `write` then creates a subject (salt = its own counter),
///         publishes a record under its Type and binds it under FOLDER in one publication, with both plan
///         expectations bound through `EfsNative.currentContext`.
///
///         Authorship: the ledger's author is whoever calls `execute` — this contract (its contract principal
///         `Keys.contractPrincipal(realmOrigin, address(this))`, or the proxy's address when it runs behind a
///         proxy), never the EOA or contract that called the app. `requestedBy` is app-level bookkeeping the
///         ledger neither sees nor verifies.
///
///         Atomicity, both directions: a ledger refusal bubbles and reverts the app's own bookkeeping; an app
///         refusal after the ledger accepted (the quota check below, placed after the call on purpose) reverts
///         the publication.
/// @dev Storage, not immutables, so the same code runs directly (constructor arguments) or behind an ERC-1967
///      proxy (`initialize` in the proxy's construction data). An implementation deployed with a zero ledger is
///      left uninitialized; initializing it would only register the same Type and give it its own principal.
contract NativeApp {
    using EfsNative for ILedger;

    bytes32 public constant FOLDER = keccak256("efs2/purpose/folder/1");

    struct Entry {
        bytes32 subject;
        bytes32 role;
        bytes32 recordId;
        uint64 publication;
        address requestedBy;
    }

    error AlreadyInitialized();
    error RuleDeployFailed(address expected);
    error QuotaExceeded(uint64 written, uint64 quota);

    event Wrote(
        uint64 indexed n, bytes32 subject, bytes32 recordId, uint64 publication, address requestedBy
    );

    ILedger public ledger;
    bytes32 public typeId;
    address public rule;
    uint64 public quota;
    uint64 public written;
    mapping(uint64 n => Entry) public entries;

    constructor(
        ILedger ledger_,
        bytes memory descriptor,
        bytes memory declarationSig,
        uint64 quota_
    ) {
        if (address(ledger_) != address(0)) {
            _initialize(ledger_, descriptor, declarationSig, quota_);
        }
    }

    function initialize(
        ILedger ledger_,
        bytes calldata descriptor,
        bytes calldata declarationSig,
        uint64 quota_
    ) external {
        _initialize(ledger_, descriptor, declarationSig, quota_);
    }

    function _initialize(
        ILedger ledger_,
        bytes memory descriptor,
        bytes memory declarationSig,
        uint64 quota_
    ) private {
        if (address(ledger) != address(0)) revert AlreadyInitialized();
        ledger = ledger_;
        quota = quota_;
        TypeRegistry registry = TypeRegistry(ILedgerHot(address(ledger_)).registry());
        bytes memory initcode = type(NativeAppRule).creationCode;
        address instance = registry.predictInstance(keccak256(initcode));
        if (instance.code.length == 0) {
            (bool ok, bytes memory ret) =
                registry.FACTORY().call(abi.encodePacked(bytes32(0), initcode));
            if (!ok || ret.length != 20 || address(bytes20(ret)) != instance) {
                revert RuleDeployFailed(instance);
            }
        }
        IDescriptorStore(registry.DESCRIPTOR_STORE()).put(descriptor, declarationSig);
        (typeId,) = ITypeRegistry(address(registry))
            .registerDescribed(descriptor, declarationSig, instance, "");
        rule = instance;
    }

    /// CREATE + PUBLISH + BIND(FOLDER, subject, role) as this app; `msg.sender` is recorded as `requestedBy`.
    function write(bytes calldata body, bytes32 role)
        external
        returns (uint64 n, bytes32 subject, bytes32 recordId, uint64 publication)
    {
        return _write(body, role, msg.sender);
    }

    /// `write` on behalf of `writer`: the ledger still records this app as the author; `writer` is kept only
    /// in the app's own mapping.
    function forward(address writer, bytes calldata body, bytes32 role)
        external
        returns (uint64 n, bytes32 subject, bytes32 recordId, uint64 publication)
    {
        return _write(body, role, writer);
    }

    /// Two apps composing in one transaction: this app writes `mine`, then `other` writes `theirs` as itself.
    /// Either refusal reverts both.
    function compose(NativeApp other, bytes calldata mine, bytes calldata theirs, bytes32 role)
        external
        returns (uint64 myN, uint64 theirN)
    {
        (myN,,,) = _write(mine, role, msg.sender);
        (theirN,,,) = other.write(theirs, role);
    }

    function _write(bytes calldata body, bytes32 role, address requestedBy)
        private
        returns (uint64 n, bytes32 subject, bytes32 recordId, uint64 publication)
    {
        ILedger l = ledger;
        n = ++written;
        bytes32 salt = bytes32(uint256(n));
        subject = Keys.subject(l.myPrincipal(), salt);
        recordId = Keys.record(typeId, body);
        Action[] memory actions = new Action[](3);
        actions[0] = EfsNative.createAction(salt);
        actions[1] = EfsNative.publishAction(typeId, body);
        actions[2] = EfsNative.bindAction(Coordinate(FOLDER, subject, role), recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        Native memory ctx = l.currentContext(actions);
        (publication,) = EfsNative.execute(l, actions, bodies, ctx);
        entries[n] = Entry(subject, role, recordId, publication, requestedBy);
        emit Wrote(n, subject, recordId, publication, requestedBy);
        if (n > quota) revert QuotaExceeded(n, quota); // after the ledger call on purpose (atomicity)
    }

    /// Proves entry `n` landed: its record exists under this app's Type and its FOLDER head, under this app's
    /// principal, is BOUND to that record. `revision` is the head's revision.
    function readBack(uint64 n)
        external
        view
        returns (bool recordPresent, bool headBound, uint64 revision)
    {
        Entry storage e = entries[n];
        ILedgerHot h = ILedgerHot(address(ledger));
        (bytes32 t, uint64 firstAdmission,,,) = h.recordHeader(e.recordId);
        recordPresent = e.recordId != 0 && t == typeId && firstAdmission != 0;
        bytes32 key = Keys.binding(ledger.myPrincipal(), Keys.position(FOLDER, e.subject, e.role));
        uint8 state;
        bytes32 target;
        (state, revision,,,,, target) = h.head(key);
        headBound = state == 1 && target == e.recordId;
    }
}
