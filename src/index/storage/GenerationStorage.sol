// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title GenerationStorage — an index generation's own namespace (design §4.6)
/// @notice Written only in the generation's own context, by its code or by the `IndexBuild` delegate.
abstract contract GenerationStorage {
    struct Progress {
        uint48 lastProcessed;
        uint48 lastPublication;
        uint8 gapped;
        uint8 liveStarted;
        uint8 replayStage; // 1 FRESH 2 REPLAYING 3 CAUGHT_UP
    }

    /// Ascending build of a later append-ordered family, before attachment.
    struct BuildFrontier {
        uint48 through;
        uint8 state; // 1 BUILDING 2 BUILT
    }

    /// @custom:storage-location erc7201:efs.index.v2.gen
    struct GenStorage {
        Progress progress;
        mapping(bytes32 family => BuildFrontier) buildFrontier;
    }

    bytes32 internal constant GEN_ROOT =
        0x1dec63f4cbafd6b4fe84cdc042050c704f9cdfe7f0d5bcbdfce1b30ca8f26300;

    function _gen() internal pure returns (GenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := GEN_ROOT
        }
    }
}
