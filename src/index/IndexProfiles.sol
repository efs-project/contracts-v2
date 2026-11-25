// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Unit} from "../interfaces/Index.sol";
import {E_PIN} from "../interfaces/Errors.sol";

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
    /// `E_PIN(address(0), TOPIC_UNIT)`: the topic Type ids and the unit list disagree (`requireTopicUnit`).
    uint8 internal constant TOPIC_UNIT = 11;

    /// The structural guard of the topic lists (design §10.2 kinds 19 and 7; docs/TAG-DESIGN.md §11.7). The index
    /// walks a tagged topic's ancestors without checking that the topic was registered before the tag: the profile's
    /// final hook guarantees it (`FilesFinalValidator` code 9, strictly before). So the lists may be kept only by a
    /// generation whose fixed unit list contains a final hook built for the same two topic Types: some unit's
    /// `finalHook` answers `topicTypeId() == topic` and `topicWordTypeId() == word`. Both ids zero means the
    /// generation keeps no topic lists (a Realm without the Topics profile) and needs no such unit. Any other
    /// combination reverts `E_PIN(address(0), 11)`: one id zero, or nonzero ids without a final hook answering both.
    /// Run by the constructors of `IndexReads` and `RealmIndex`, so neither can be deployed misconfigured; there is
    /// no setting to trust or skip it.
    function requireTopicUnit(Unit[] memory units, bytes32 topic, bytes32 word) internal view {
        if (topic == 0 && word == 0) return;
        if (topic != 0 && word != 0) {
            for (uint256 i; i < units.length; ++i) {
                address hook = units[i].finalHook;
                if (hook == address(0)) continue;
                if (
                    _answer(hook, bytes4(keccak256("topicTypeId()"))) == topic
                        && _answer(hook, bytes4(keccak256("topicWordTypeId()"))) == word
                ) return;
            }
        }
        revert E_PIN(address(0), TOPIC_UNIT);
    }

    /// A hook's one-word answer to a no-argument getter, zero when it has no such getter (or no code).
    function _answer(address hook, bytes4 selector) private view returns (bytes32 v) {
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length == 32) v = abi.decode(ret, (bytes32));
    }
}
