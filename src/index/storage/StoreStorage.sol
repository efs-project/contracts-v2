// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Store storage — the per-Realm index stores' ERC-7201 namespaces (design §4.6)
/// @notice Stores outlive index generations. Each store's write authorization (design §4.6) is the
///         only rule it enforces; `writers` is the append-only history of who wrote which range.

/// Shared by both store kinds.
struct WriterRange {
    address generation;
    uint48 fromAdmission;
    uint48 toAdmission; // 0 while open
}

abstract contract PostingStoreStorage {
    /// Append-ordered posting lists: five u48 ordinals per word; the first append writes only the head.
    struct PostingHead {
        uint48 count;
        uint48 live;
        uint48 last;
        uint16 flags; // reserved zero
    }

    /// @custom:storage-location erc7201:efs.index.v2.store.posting
    struct PostingStorage {
        mapping(bytes32 postingKey => PostingHead) heads;
        mapping(bytes32 postingKey => mapping(uint256 wordIndex => uint256)) words;
        WriterRange[] writers;
        uint8 attached; // set by the first live write; INITIAL_WRITER's right lapses when set
    }

    bytes32 internal constant POSTING_ROOT =
        0xafadaed06cad87ccf20afccb1a44eec86b687f3eab1409e879b2ae8416b40a00;

    function _posting() internal pure returns (PostingStorage storage $) {
        assembly ("memory-safe") {
            $.slot := POSTING_ROOT
        }
    }
}

abstract contract BitmapStoreStorage {
    /// The kind-10 scope list head: entry 0 inline, the first 48 live bits inline, the mutation stamp.
    struct ScopeHead {
        uint48 count;
        uint48 live;
        uint48 lastMutation;
        uint48 liveBits0;
        uint16 flags; // reserved zero
        uint48 entry0;
    }

    /// Per-(family, scope) coverage; exists only for scopes that predate the family's declaration.
    struct CoverageSlot {
        uint48 through;
        uint48 liveFrom;
        uint48 retiredAt;
        uint8 state; // 1 OPEN 2 COMPLETE 3 RETIRED
    }

    /// @custom:storage-location erc7201:efs.index.v2.store.bitmap
    struct BitmapStorage {
        mapping(bytes32 scope => ScopeHead) scopeHeads;
        mapping(bytes32 scope => mapping(uint256 wordIndex => uint256)) scopeEntries; // five u48 per word, entries >= 1
        mapping(
            bytes32 scope => mapping(bytes32 family => mapping(uint256 wordIndex => uint256))
        ) bits; // entries >= 48
        mapping(bytes32 family => mapping(bytes32 scope => CoverageSlot)) coverage;
        WriterRange[] writers;
        uint8 attached;
    }

    bytes32 internal constant BITMAP_ROOT =
        0x4640202bf0ab6387cbfef29b92cbbb784eceffe554551be074390efd2b65b600;

    function _bitmap() internal pure returns (BitmapStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BITMAP_ROOT
        }
    }
}
