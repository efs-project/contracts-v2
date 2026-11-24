// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// @title Results — the read-side vocabulary of the EFS v2 consumer closure (design §5.1)
// @notice Value 0 of every enum is reserved and never returned: a zero-decoded struct is a transport
//         fault, never a result. `STATUS_VOCABULARY_ID` versions the enums; additions are append-only.

// Read statuses. `ABSENT_PROVEN` is the only absence; `UNKNOWN` never renders as empty.
enum Status {
    UNSET,
    UNKNOWN,
    PRESENT,
    ABSENT_PROVEN,
    MASKED,
    RELEASED,
    CONFLICT,
    NOT_ON_PAGE,
    NOT_APPLICABLE,
    INVALID,
    UNSUPPORTED,
    BASIS_STALE,
    LIMIT_EXCEEDED
}

/// Index coverage (design §10.5, invariant I9).
enum Coverage {
    UNSET,
    UNKNOWN,
    PARTIAL,
    COMPLETE
}

/// As-of history lookups (design §5.7 `historyAt`).
enum History {
    UNSET,
    UNKNOWN,
    NONE,
    FOUND
}

/// Witness retention of an evidence row (design §7.4). Numbered as `limits.witnessRetention` reads it:
/// 1 LOG_ONLY (the default profile: hash in state, bytes in logs), 2 STATE (bytes retained in the
/// pinned `SignatureStore`). The design's §5.1 listed the two names in the other order; §4.2's
/// numbering is the one used here and recorded as an adoption note.
enum Retention {
    UNSET,
    LOG_ONLY,
    STATE
}

/// The basis a reader observed and echoes back (design §5.1). Comparison law: plans compare
/// `executionSet` and the acceptance profile, never `registryMutations`; readers and cursors compare
/// `(executionSet, indexGeneration)` exactly and treat `admissionHighWater` as the origin.
struct BasisCommit {
    bytes32 executionSet;
    uint32 revision;
    uint32 indexGeneration;
    uint64 registryMutations;
    uint64 admissionHighWater;
    uint8 phase;
}

/// A status with the basis it was observed under.
struct Qualified {
    Status status;
    BasisCommit observed;
}

/// Publication phase as `ILedgerHot.phase()` reports it (design §5.3).
library Phase {
    uint8 internal constant IDLE = 0;
    uint8 internal constant PREPARING = 1;
    uint8 internal constant APPLYING = 2;
    uint8 internal constant FINAL = 3;
}

// Versions the enums above; changed only when a value is appended.
bytes32 constant STATUS_VOCABULARY_ID = keccak256("efs2/status-vocabulary/1");
