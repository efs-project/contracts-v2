// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, ActionKind, Coordinate, Native} from "../interfaces/Actions.sol";
import {ILedger} from "../interfaces/ILedger.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerCommitments} from "../interfaces/ILedgerCommitments.sol";
import {
    AlreadyAdmitted,
    E_ACCEPTANCE_PROFILE,
    E_ACCEPTOR_CODE,
    E_ACCEPTOR_GAS,
    E_CAS,
    E_EXECUTION_DRIFT,
    E_EXECUTION_SET,
    E_EXPIRED,
    E_GAS,
    E_HELPER_CODE,
    E_INDEX_GAS,
    E_INGRESS,
    E_INTENT,
    E_MISSING_RECORD,
    E_NO_INDEX,
    E_NONCE,
    E_NOT_LIVE,
    E_PUBLICATION_ACTIVE,
    E_READSET_STALE,
    E_REF,
    E_REGISTRY_DRIFT,
    E_SIGNATURE,
    E_TARGET_MISSING,
    E_TRANSITION,
    E_WALLET_GAS
} from "../interfaces/Errors.sol";
import {Keys} from "./Keys.sol";

/// @title EfsNative — the native-lane consumer library (design §5.14, §3.1 row L4)
/// @notice For a contract that writes to an EFS v2 ledger as itself. The author of a native publication is the
///         caller of `execute` (`msg.sender` at the ledger): a contract using this library writes as
///         `Keys.principalFor(address(this), realmOrigin)` — its own contract principal — never as the EOA or
///         contract that called it. Every write carries an explicit nonce (each plan has its own
///         `AlreadyAdmitted` retry identity) and a `Bind`: the execution set and the acceptance profile the plan
///         was prepared under. `currentBind` binds both (design Q22): `expectedExecutionSet` is
///         `ILedgerHot.executionSet()` and `expectedAcceptanceProfile` is the ingress view
///         `ILedgerCommitments(ledger.ingress()).acceptanceProfileOf(ledger, actions)`, the same fold the ingress
///         runs in `prepareNative` (it depends on the actions and live registry rows, not on the principal).
///         Zero `Bind` fields are unbound.
/// @dev Consumer closure: internal functions only, no storage, no OpenZeppelin, no transient storage; imports
///      only `src/interfaces/` and `Keys`. Binding the live values inside the same transaction that executes
///      only refuses on a change made earlier in that transaction; the binding earns its keep when a `Bind` is
///      computed off chain or in an earlier transaction and carried into the write (design §12.3: an activation
///      between preparation and landing → `E_EXECUTION_SET`/`E_ACCEPTANCE_PROFILE`, nonce intact).
library EfsNative {
    /// The plan's expectations; a zero field is unbound.
    struct Bind {
        bytes32 executionSet;
        bytes32 acceptanceProfile;
    }

    // Retry classes of the error catalog (design §5.6; `Errors.sol` trailing comments).
    /// Unclassified or "none": do not retry the same plan (it can never land).
    uint8 internal constant RETRY_NONE = 0;
    /// Rebuild the plan against fresh state (new nonce, heads, bind) and submit again.
    uint8 internal constant RETRY_REPREPARE = 1;
    /// Submit the identical plan again (more gas, or after a transient drift).
    uint8 internal constant RETRY_RESUBMIT = 2;
    /// Submit the identical plan later (a transition, activation or publication is in the way).
    uint8 internal constant RETRY_WAIT = 3;
    /// `AlreadyAdmitted`: the identical plan is committed; nothing to retry.
    uint8 internal constant RETRY_COMMITTED = 4;

    // ---- identity and nonce --------------------------------------------------------------------------------

    /// The principal `account` authors as on `l`'s Realm (the exact 23-byte `ef0100` rule; design §2.2 S2).
    function principalOf(ILedger l, address account) internal view returns (bytes32) {
        return Keys.principalFor(account, ILedgerHot(address(l)).realmOrigin());
    }

    /// This contract's principal on `l`'s Realm: the author of every write it makes through this library.
    function myPrincipal(ILedger l) internal view returns (bytes32) {
        return principalOf(l, address(this));
    }

    /// The next native nonce of this contract's principal.
    function nextNonce(ILedger l) internal view returns (uint64 nonce) {
        (nonce,) = ILedgerHot(address(l)).nonceOf(myPrincipal(l));
    }

    // ---- expectations --------------------------------------------------------------------------------------

    /// Both expectations as the ledger would judge `actions` now: the live execution set and the acceptance
    /// profile from the ingress commitment view. Reverts as the ingress fold does (`E_UNKNOWN_TYPE` for an
    /// unregistered PUBLISH/REUSE Type).
    function currentBind(ILedger l, Action[] memory actions) internal view returns (Bind memory b) {
        ILedgerHot h = ILedgerHot(address(l));
        b.executionSet = h.executionSet();
        b.acceptanceProfile =
            ILedgerCommitments(h.ingress()).acceptanceProfileOf(address(l), actions);
    }

    /// The native context for `nonce` under `b`, no deadline.
    function context(uint64 nonce, Bind memory b) internal pure returns (Native memory ctx) {
        ctx.nonce = nonce;
        ctx.expectedExecutionSet = b.executionSet;
        ctx.expectedAcceptanceProfile = b.acceptanceProfile;
    }

    /// `context(nextNonce(l), currentBind(l, actions))`: this contract's next write of `actions`, fully bound.
    function currentContext(ILedger l, Action[] memory actions)
        internal
        view
        returns (Native memory)
    {
        return context(nextNonce(l), currentBind(l, actions));
    }

    // ---- action builders (the per-kind zero-shape law of design §6.4) --------------------------------------

    function createAction(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function publishAction(bytes32 typeId, bytes memory body)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function reuseAction(bytes32 typeId, bytes32 recordId) internal pure returns (Action memory a) {
        a.kind = ActionKind.REUSE;
        a.typeId = typeId;
        a.bodyHashOrRecordId = recordId;
    }

    function bindAction(Coordinate memory c, bytes32 target, uint64 expectedRevision)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = c.purpose;
        a.subject = c.subject;
        a.role = c.role;
        a.target = target;
        a.expectedRevision = expectedRevision;
    }

    function unbindAction(Coordinate memory c, uint64 expectedRevision)
        internal
        pure
        returns (Action memory a)
    {
        a = bindAction(c, 0, expectedRevision);
        a.kind = ActionKind.UNBIND;
    }

    function releaseAction(Coordinate memory c, uint64 expectedRevision)
        internal
        pure
        returns (Action memory a)
    {
        a = bindAction(c, 0, expectedRevision);
        a.kind = ActionKind.RELEASE;
    }

    /// WITHDRAW names the admission ordinal in `target`.
    function withdrawAction(uint64 admission) internal pure returns (Action memory a) {
        a.kind = ActionKind.WITHDRAW;
        a.target = bytes32(uint256(admission));
    }

    // ---- writes --------------------------------------------------------------------------------------------

    /// Passthrough to the native lane with the canonical-empty guard. A refusal reverts the caller with the
    /// kernel's error (atomicity: the caller's own state rolls back with the ledger's).
    function execute(ILedger l, Action[] memory actions, bytes[] memory bodies, Native memory ctx)
        internal
        returns (uint64 publication, uint64 firstAdmission)
    {
        return l.execute(actions, bodies, ctx, "");
    }

    /// `execute` that returns the kernel's refusal instead of reverting: `selector` is the outer error selector
    /// (zero for empty revert data) and `retry` its class; for `AlreadyAdmitted` `publication` is the committed
    /// ordinal. The caller's state changes before the call are kept; decide explicitly what to undo.
    function tryExecute(
        ILedger l,
        Action[] memory actions,
        bytes[] memory bodies,
        Native memory ctx
    )
        internal
        returns (bool ok, uint64 publication, uint64 firstAdmission, bytes4 selector, uint8 retry)
    {
        try l.execute(actions, bodies, ctx, "") returns (uint64 p, uint64 f) {
            return (true, p, f, bytes4(0), RETRY_NONE);
        } catch (bytes memory reason) {
            if (reason.length >= 4) selector = bytes4(reason);
            if (selector == AlreadyAdmitted.selector && reason.length >= 36) {
                uint256 w;
                assembly ("memory-safe") {
                    w := mload(add(reason, 36))
                }
                publication = uint64(w);
            }
            retry = retryClass(selector);
        }
    }

    /// The retry class of a kernel write-path error selector (design §5.6); unknown selectors are RETRY_NONE.
    function retryClass(bytes4 s) internal pure returns (uint8) {
        if (s == AlreadyAdmitted.selector) return RETRY_COMMITTED;
        if (
            s == E_NONCE.selector || s == E_EXECUTION_SET.selector
                || s == E_ACCEPTANCE_PROFILE.selector || s == E_EXPIRED.selector
                || s == E_INTENT.selector || s == E_SIGNATURE.selector
                || s == E_READSET_STALE.selector || s == E_MISSING_RECORD.selector
                || s == E_REF.selector || s == E_NOT_LIVE.selector || s == E_CAS.selector
                || s == E_TARGET_MISSING.selector
        ) return RETRY_REPREPARE;
        if (
            s == E_REGISTRY_DRIFT.selector || s == E_WALLET_GAS.selector || s == E_GAS.selector
                || s == E_ACCEPTOR_GAS.selector || s == E_INDEX_GAS.selector
        ) return RETRY_RESUBMIT;
        if (
            s == E_PUBLICATION_ACTIVE.selector || s == E_TRANSITION.selector
                || s == E_NO_INDEX.selector || s == E_EXECUTION_DRIFT.selector
                || s == E_HELPER_CODE.selector || s == E_ACCEPTOR_CODE.selector
                || s == E_INGRESS.selector
        ) return RETRY_WAIT;
        return RETRY_NONE;
    }

    // ---- one-shot writes (design §5.14): explicit nonce and Bind ------------------------------------------

    function publish(ILedger l, uint64 nonce, Bind memory b, bytes32 typeId, bytes memory body)
        internal
        returns (uint64 publication, bytes32 recordId)
    {
        (publication,) = _one(l, nonce, b, publishAction(typeId, body), body);
        recordId = Keys.record(typeId, body);
    }

    function create(ILedger l, uint64 nonce, Bind memory b, bytes32 salt)
        internal
        returns (uint64 publication, bytes32 subjectId)
    {
        (publication,) = _one(l, nonce, b, createAction(salt), "");
        subjectId = Keys.subject(myPrincipal(l), salt);
    }

    function bind(
        ILedger l,
        uint64 nonce,
        Bind memory b,
        Coordinate memory c,
        bytes32 target,
        uint64 expectedRevision
    ) internal returns (uint64 publication) {
        (publication,) = _one(l, nonce, b, bindAction(c, target, expectedRevision), "");
    }

    function unbind(
        ILedger l,
        uint64 nonce,
        Bind memory b,
        Coordinate memory c,
        uint64 expectedRevision
    ) internal returns (uint64 publication) {
        (publication,) = _one(l, nonce, b, unbindAction(c, expectedRevision), "");
    }

    function release(
        ILedger l,
        uint64 nonce,
        Bind memory b,
        Coordinate memory c,
        uint64 expectedRevision
    ) internal returns (uint64 publication) {
        (publication,) = _one(l, nonce, b, releaseAction(c, expectedRevision), "");
    }

    function withdraw(ILedger l, uint64 nonce, Bind memory b, uint64 admission)
        internal
        returns (uint64 publication)
    {
        (publication,) = _one(l, nonce, b, withdrawAction(admission), "");
    }

    function batch(
        ILedger l,
        uint64 nonce,
        Bind memory b,
        Action[] memory actions,
        bytes[] memory bodies
    ) internal returns (uint64 publication, uint64 firstAdmission) {
        return l.execute(actions, bodies, context(nonce, b), "");
    }

    function _one(ILedger l, uint64 nonce, Bind memory b, Action memory a, bytes memory body)
        private
        returns (uint64, uint64)
    {
        Action[] memory actions = new Action[](1);
        actions[0] = a;
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        return l.execute(actions, bodies, context(nonce, b), "");
    }
}
