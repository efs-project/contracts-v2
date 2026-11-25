// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, Native, Intent} from "./Actions.sol";

/// @title ILedger — the write lanes of a Realm ledger (design §5.2) and the write-path kernel events (§5.5)
/// @notice Calldata-only; three selectors forever (the ABI snapshot asserts no other write selector exists).
///         `guard` is the ABI encoding of a `ReadSet` or empty (the canonical-empty read set); the kernel never
///         decodes it. `intent.verifierProfile` selects 1 secp256k1-EIP-712, 2 ERC-1271, 3 P-256/WebAuthn
///         (reserved), 4+ reserved. Events accelerate receipts and indexers; state is sufficient for every
///         canonical fact except the two log-only carriers (`ReadSetChecked`, `WitnessRetained`). The
///         activation and transition events of §5.5 are declared on `ILedgerControl`.
interface ILedger {
    /// One per publication; `effectsHash = keccak256(abi.encode(Effect[]))` is emitted only, never stored.
    event Published(
        uint64 indexed publication,
        bytes32 indexed publicationId,
        bytes32 indexed principalId,
        uint8 proofKind,
        uint64 firstAdmission,
        uint8 leafCount,
        bytes32 effectsHash,
        uint32 revision
    );
    /// Topic 3: typeId for PUBLISH/REUSE/WITHDRAW, scopeKey for BIND/UNBIND/RELEASE, subjectId for CREATE.
    event Admitted(
        uint64 indexed admission,
        uint8 indexed kind,
        bytes32 indexed scopeOrType,
        bytes32 id,
        bytes32 principalId
    );
    /// One per BIND, UNBIND or RELEASE admission, right after its `Admitted`, so an indexer follows every binding
    /// (a tag: purpose TAG, subject the topic, role the thing) with no storage read. `kind` is the action kind
    /// (3 BIND, 4 UNBIND, 7 RELEASE) and `strength` its `saltOrStrength`: the number is `strength` after a BIND,
    /// `-1 - strength` after an UNBIND, none after a RELEASE (strength 0). `target` is the bound target (0 for
    /// UNBIND and RELEASE), `targetKind` 1 RECORD 2 SUBJECT 3 ADDRESS (0 for UNBIND and RELEASE), `transitionKind`
    /// that of `Effect/3` (1 FIRST_BIND 2 REBIND 3 MASK 4 RELEASE 5 RESTORE 6 FIRST_MASK). The author is the
    /// `principalId` of the `Admitted` event with the same `admission`.
    event Bound(
        uint64 indexed admission,
        bytes32 indexed purpose,
        bytes32 indexed subject,
        bytes32 role,
        bytes32 target,
        uint8 kind,
        uint16 strength,
        uint8 transitionKind,
        uint8 targetKind
    );
    /// The body of a fresh record of at most `ClosureConstants.BODY_EVENT_MAX` bytes, right after the `Admitted`
    /// of the PUBLISH that first admitted it (never for a repeat publish or a REUSE), so an indexer can follow
    /// names, words, folders and topic records from events alone. A larger body stays in state only.
    event Body(bytes32 indexed recordId, bytes32 indexed typeId, bytes body);
    /// Guarded publications: the preimage lives only here under the default retention profile.
    event ReadSetChecked(uint64 indexed publication, bytes32 indexed readSetHash, bytes readSet);
    /// ERC-1271 bytes under the log-only retention profile (w9.store == 0).
    event WitnessRetained(
        uint64 indexed publication,
        bytes32 indexed evidenceHash,
        uint16 verifierProfile,
        bytes witness
    );

    /// Native lane: the caller is the author; `ctx` carries the nonce, deadline and bound expectations.
    function execute(
        Action[] calldata actions,
        bytes[] calldata bodies,
        Native calldata ctx,
        bytes calldata guard
    ) external returns (uint64 publication, uint64 firstAdmission);

    /// Signed lane: `witness` authenticates `intent` under `intent.verifierProfile`; `actionsHash` is appended
    /// to the typed data at hashing.
    function executeSigned(
        Intent calldata intent,
        Action[] calldata actions,
        bytes[] calldata bodies,
        bytes calldata guard,
        bytes calldata witness
    ) external returns (uint64 publication, uint64 firstAdmission);

    /// S4 behind capability b5; from S1 a stub that decodes `packet`'s header and reverts E_RESERVED(5, 0).
    function importPublication(bytes calldata packet, bytes calldata witness)
        external
        returns (uint64 publication, uint64 firstAdmission);
}
