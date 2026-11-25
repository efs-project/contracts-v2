// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IndexProfiles — the profile ids and manifest constants a generation-1 index and its reads contract share
///        (design §5.11, §10.1, §10.3)
/// @notice `RealmIndex` folds, `IndexReads` answers; both name the same physical and callback profiles and the same
///         manifest header, so they are defined once here.
library IndexProfiles {
    /// The physical composition: the two per-Realm stores, inline singletons, five u48 entries per word, live bits
    /// in the scope head.
    bytes32 internal constant PHYSICAL =
        keccak256("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head");
    /// The callback shape the generation folds (design §10.3).
    bytes32 internal constant CALLBACK =
        keccak256("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs");
    /// `/2`: the manifest hash also folds the reads contract's address and codehash (design §10.1).
    bytes32 internal constant MANIFEST_HEADER = keccak256("efs/index-manifest/2");
    /// `FamilyEntry.fromAdmission` of a family the generation does not maintain.
    uint64 internal constant NOT_MAINTAINED = type(uint64).max;
}
