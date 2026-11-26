// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EfsTopics} from "../lib/EfsTopics.sol";
import {FilesTypes} from "./FilesTypes.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";

/// @title TopicTypes — the codec-1 descriptors and Type ids of the Topics Types (design §12.5, §9.2)
/// @notice Three NATIVE Types in the exact style of `FilesTypes` (same header bytes, same REF32 field rows,
///         `ruleMode` 1, `validationGas` 0), under namespace `keccak256("efs/topics/1")`, declared by the same key
///         and registered at genesis after the ten Files Types (design §8.2 G10-G12, G21):
///         `topic-word/1`, body = the word's bytes, no refs, rule `TopicWordRule` (no constructor state);
///         `topic/1`, body = `[parent, wordPage]` (64 bytes), refs `[0 = ANY, topic-word/1]` with `refHeaderWords`
///         1, rule `TopicRule(wordTypeId)`; `text/1`, body = the text's bytes, no refs, rule `TextRule` (no
///         constructor state). Dependency order: the word Type first (the topic descriptor's second ref and the
///         topic rule's constructor state name its id); text is independent. All three are pure over calldata and
///         `refHeaders` (`dependencyClass` 1).
///         The descriptor's header byte 133 is the Type's `flags` byte, set in one place per Type below (`flags`
///         in each spec). All three set `ClosureConstants.TYPE_FLAG_EMITS_BODY`, so a fresh word page, path record
///         or text record (each at most 255 bytes, below `BODY_EVENT_MAX`) is logged in `Body` and an indexer
///         follows words, paths and labels from events alone.
/// @dev Internal and pure/view only, so it compiles into its callers. Ids depend on neither author, Realm nor
///      chain (`Keys.record(typeId, body)`), so `EfsTopics.pathId` computes any topic's id offline from its words.
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

    /// `instance` is `TopicRule(wordTypeId)`; the descriptor's second ref is `wordTypeId`.
    function topic(address key, address instance, bytes32 initcodeHash, bytes32 wordTypeId)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, topicSpec(wordTypeId));
    }

    function text(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, textSpec());
    }

    // =============================================================================================
    // Specs (identity-bearing: every byte below is inside the shape commitment)
    // =============================================================================================

    function wordSpec() internal pure returns (FilesTypes.Spec memory s) {
        s.name = "topic-word/1";
        s.description =
            "a word's page and the root-level topic /<word>: 1-255 bytes of well-formed UTF-8, of ASCII only a-z 0-9 - _ ., not ending in ., no C1, bidi, invisible, joiner or variation selector code point, not 0x and 40 lowercase hex";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
        s.flags = ClosureConstants.TYPE_FLAG_EMITS_BODY; // a fresh word page is logged in `Body`
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
        s.flags = ClosureConstants.TYPE_FLAG_EMITS_BODY; // a fresh path record is logged in `Body`
    }

    function textSpec() internal pure returns (FilesTypes.Spec memory s) {
        s.name = "text/1";
        s.description =
            "a short display string: 1-255 bytes of well-formed UTF-8, no control character (C0, DEL, C1), no bidi control or invisible code point; /, spaces and uppercase allowed";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
        s.flags = ClosureConstants.TYPE_FLAG_EMITS_BODY; // a fresh text record is logged in `Body`
    }

    /// `FilesTypes.encode` with this profile's namespace (bytes 34..65).
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

    // =============================================================================================
    // Ids (no chain read; `EfsTopics` is the consumer-closure copy)
    // =============================================================================================

    /// The page of `word`, which is also the root-level topic `/<word>`.
    function wordPageId(bytes32 wordTypeId, bytes memory word) internal pure returns (bytes32) {
        return EfsTopics.wordPageId(wordTypeId, word);
    }

    /// The `topic/1` record of `parent` extended by the word whose page is `wordPage`.
    function childId(bytes32 topicTypeId, bytes32 parent, bytes32 wordPage)
        internal
        pure
        returns (bytes32)
    {
        return EfsTopics.childId(topicTypeId, parent, wordPage);
    }

    /// The id of the path `words`: the word page for one word, else the `topic/1` chain (zero for no words).
    function pathId(bytes32 wordTypeId, bytes32 topicTypeId, bytes[] memory words)
        internal
        pure
        returns (bytes32)
    {
        return EfsTopics.pathId(EfsTopics.Types(wordTypeId, topicTypeId, 0), words);
    }

    /// `FilesTypes.typeIdOf` (the registry's derivation).
    function typeIdOf(bytes memory d) internal pure returns (bytes32) {
        return FilesTypes.typeIdOf(d);
    }
}
