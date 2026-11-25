// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";
import {FilesTypes} from "./FilesTypes.sol";

/// @title TopicTypes — the codec-1 descriptors, Type ids and id helpers of the Topics profile (SPIKE, tags/topics)
/// @notice Two NATIVE Types in the exact style of `FilesTypes` (same header bytes, same REF32 field rows), under
///         namespace `keccak256("efs/topics/1")`:
///         `topic-word/1`, body = the word's bytes, no refs, rule `TopicWordRule` (no constructor state);
///         `topic/1`, body = `[parent, wordPage]` (64 bytes), refs `[0 = ANY, topic-word/1]` with
///         `refHeaderWords` 1, rule `TopicRule(wordTypeId)`. Dependency order: the word Type first (the topic
///         descriptor's second ref and the topic rule's constructor state name its id).
/// @dev Ids depend on neither author, Realm nor chain (`Keys.record(typeId, body)`), so `wordPageId` and `pathId`
///      compute any topic's id offline from its words.
library TopicTypes {
    bytes32 internal constant NAMESPACE = keccak256("efs/topics/1");
    bytes32 internal constant FIELD_PARENT = keccak256("efs/topics/field/parent/1");
    bytes32 internal constant FIELD_WORD = keccak256("efs/topics/field/word/1");
    bytes32 internal constant SEMANTIC_PARENT = keccak256("efs/topics/semantic/parent-topic/1");
    bytes32 internal constant SEMANTIC_WORD = keccak256("efs/topics/semantic/word-page/1");

    function topicWord(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, wordSpec());
    }

    function topic(address key, address instance, bytes32 initcodeHash, bytes32 wordTypeId)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, topicSpec(wordTypeId));
    }

    function wordSpec() internal pure returns (FilesTypes.Spec memory s) {
        s.name = "topic-word/1";
        s.description =
            "a word's page and the root-level topic /<word>: 1-255 bytes of well-formed UTF-8, no /, no ASCII control, space or A-Z, not . or .., not starting with ~, not 0x and 40 lowercase hex";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
    }

    function topicSpec(bytes32 wordTypeId) internal pure returns (FilesTypes.Spec memory s) {
        s.name = "topic/1";
        s.description =
            "abi.encode(parent, wordPage); a path of two or more words; parent is a topic/1 or topic-word/1 record, wordPage a topic-word/1 record";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
        s.fields = bytes.concat(
            FilesTypes.refField(FIELD_PARENT, SEMANTIC_PARENT, FilesTypes.REF_ANY),
            FilesTypes.refField(FIELD_WORD, SEMANTIC_WORD, wordTypeId)
        );
        s.fieldCount = 2;
    }

    /// `FilesTypes.encode` with this profile's namespace (byte 34..65).
    function encode(
        address key,
        bytes32 ruleCodehash,
        bytes32 initcodeHash,
        FilesTypes.Spec memory s
    ) internal pure returns (bytes memory d) {
        d = FilesTypes.encode(key, ruleCodehash, initcodeHash, s);
        bytes32 ns = NAMESPACE;
        assembly ("memory-safe") {
            mstore(add(add(d, 32), 34), ns)
        }
    }

    // ---- ids (no chain read) -------------------------------------------------------------------------------

    /// The page of `word`, which is also the root-level topic `/<word>`.
    function wordPageId(bytes32 wordTypeId, bytes memory word) internal pure returns (bytes32) {
        return Keys.record(wordTypeId, word);
    }

    /// The `topic/1` record of `parent` extended by the word whose page is `wordPage`.
    function childId(bytes32 topicTypeId, bytes32 parent, bytes32 wordPage)
        internal
        pure
        returns (bytes32)
    {
        return Keys.record(topicTypeId, abi.encode(parent, wordPage));
    }

    /// The id of the path `words[0]/…/words[n-1]`: the word page for n = 1, else the `topic/1` record
    /// `[pathId(first n-1 words), wordPageId(last word)]`. Zero for the empty path (no topic).
    function pathId(bytes32 wordTypeId, bytes32 topicTypeId, bytes[] memory words)
        internal
        pure
        returns (bytes32 id)
    {
        uint256 n = words.length;
        if (n == 0) return 0;
        id = wordPageId(wordTypeId, words[0]);
        for (uint256 i = 1; i < n; ++i) {
            id = childId(topicTypeId, id, wordPageId(wordTypeId, words[i]));
        }
    }

    /// `FilesTypes.typeIdOf` (the registry's derivation).
    function typeIdOf(bytes memory d) internal pure returns (bytes32) {
        return FilesTypes.typeIdOf(d);
    }
}
