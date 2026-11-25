// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title GenerationStorage — an index generation's own namespace (design §4.6)
/// @notice Written only by the generation's own code (no delegate: design §10.6).
abstract contract GenerationStorage {
    struct Progress {
        uint48 lastProcessed;
        uint48 lastPublication;
        uint8 gapped;
        uint8 liveStarted;
        uint8 replayStage; // 1 FRESH 2 REPLAYING 3 CAUGHT_UP 4 IN_FLIGHT (a replay call in progress)
    }

    /// Ascending build of a later append-ordered family, before attachment.
    struct BuildFrontier {
        uint48 through;
        uint8 state; // 1 BUILDING 2 BUILT
    }

    /// @custom:storage-location erc7201:efs.index.gen
    struct GenStorage {
        Progress progress;
        mapping(bytes32 family => BuildFrontier) buildFrontier;
    }

    bytes32 internal constant GEN_ROOT =
        0xb5c0d2a68acfe73ade1091b3f74f29317622b434abd8d361aeac70e6ad780e00;

    function _gen() internal pure returns (GenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := GEN_ROOT
        }
    }
}
