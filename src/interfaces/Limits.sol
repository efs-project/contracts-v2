// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// @title Limits — the Realm limits profile (design §4.2, §5.1)
// @notice Activation-set values stored in two realm words and hashed into `limitsProfileId`
//         (`keccak(abi.encode(Limits))`), which is an input of the execution set. Every field is a
//         maximum, a schedule constant or a profile selector; none enters validity or identity.
//         The three numbers that do (`ACCEPTOR_GAS_DEFAULT`, `DESCRIPTOR_MAX`, `WALLET_GAS_FLOOR`)
//         are closure constants below, never Realm fields (design §4.2).

struct Limits {
    uint16 maxActions;
    uint32 maxBody;
    uint8 maxRefs;
    uint16 maxReadSetPrincipals;
    uint8 maxReadSetPositions;
    uint16 maxWitness;
    uint32 maxTransitionBlocks;
    uint16 inlineWordMax;
    uint8 witnessRetention; // = Retention (1 LOG_ONLY, 2 STATE)
    uint16 maxBindsPerPublication;
    uint32 maxBodyBytesPerPublication;
    uint32 maxFreshSlotsPerPublication; // advisory: the SDK's estimator, never a refusal
    uint16 maxReadIds;
    uint16 maxReadCount;
    uint32 floorFreshGas;
    uint32 floorRewriteGas;
    uint32 kernelTail;
}

/// Closure constants that enter validity, identity or liveness (design §4.2, §6.2, §9.2).
library ClosureConstants {
    /// The declared minimum a rule needs when its descriptor says 0 (design §9.2); a floor, never a cap.
    uint32 internal constant ACCEPTOR_GAS_DEFAULT = 300_000;
    /// Codec-1 descriptors are at most this many bytes (design §9.2).
    uint32 internal constant DESCRIPTOR_MAX = 4_096;
    /// The ERC-1271 `isValidSignature` call is forwarded at least this much (design §6.2).
    uint32 internal constant WALLET_GAS_FLOOR = 300_000;
    /// The largest record body the kernel logs in a `Body` event on its first admission (design §5.5), a hard
    /// ceiling on the log cost of a Type whose descriptor sets `TYPE_FLAG_EMITS_BODY`: the flag decides who pays
    /// (only records of a flagged Type are logged), the ceiling bounds what they pay. 256 bytes covers every name
    /// and word (both capped at 255 bytes) and small fixed-shape records (a topic path's two references), so a
    /// flagged Type never logs a body that grows with a file's size.
    uint32 internal constant BODY_EVENT_MAX = 256;
    /// Bit 0 of the described-Type descriptor's `flags` byte (header byte 133, design §9.2): the kernel emits
    /// `Body` for a fresh record of the Type of at most `BODY_EVENT_MAX` bytes. Bits 1–7 are reserved and refused.
    uint8 internal constant TYPE_FLAG_EMITS_BODY = 1;
    /// The saturation threshold of every 48-bit counter and ordinal (design §4.1).
    uint64 internal constant SATURATION = (uint64(1) << 48) - 64;
    /// realm-notice/1 kinds (design §12.1, §8.10): the freeze canary, the successor notice, the migration notice.
    bytes32 internal constant NOTICE_FROZEN = keccak256("efs/notice/frozen/1");
    bytes32 internal constant NOTICE_SUCCESSOR = keccak256("efs/notice/successor/1");
    bytes32 internal constant NOTICE_MIGRATION = keccak256("efs/notice/migration/1");
}
