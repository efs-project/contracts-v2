// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, ActionKind, Purpose} from "../interfaces/Actions.sol";

/// @title EfsTopics — topics, tags and statements about topics as `Action[]`/`bytes[]` builders (design §5.14,
///        §12.5; docs/TAG-DESIGN.md §1, §2, §8)
/// @notice Pure builders and ids for the Topics Types and the purposes that use them:
///         - a topic is a path of words: the word page `topic-word/1` (body = the word) is the root-level topic
///           `/<word>`, and a path of n >= 2 words is the `topic/1` record `[path of the first n-1 words, page of
///           the last word]`. Ids come from the words alone (`wordPageId`, `childId`, `pathId`).
///         - registration order: every word page and every path record a topic needs must be admitted before
///           anything references it (the kernel's reference law: parents first, pages before use) and STRICTLY
///           BEFORE the first statement made on it (`FilesFinalValidator` code 9: the index walks a topic's
///           ancestors at the statement's own admission). An earlier action of the same publication counts, so
///           `registerPath` followed by `tag` is one publication. Registering an existing page or path again is a
///           new occurrence of the same record (gas, never a refusal); a client may drop it.
///         - a tag is `BIND(TAG, topic, role = thing → thing)` with a number (`tag`, strength n >= 0), "not this" is
///           `UNBIND(TAG, topic, thing)` (`deny`, number -1 - strength; a lone negative when the author never said
///           anything there). The topic may also be a home (an address-shaped word).
///         - `PROPERTY` at (any subject, key) → a value record, a file or an address, one value per author per key:
///           `propertyKey("label:en")`, `propertyKey("definition")`, `propertyKey("moved-to")`; `label` publishes a
///           `text/1` record and names it.
///         - `SAME` at (topic, other topic) → the other topic; `BROADER` at (topic, parent topic) → the parent.
///         Type ids are the caller's (`Types`): `profiles/TopicTypes.sol` derives them from the release descriptors.
/// @dev Consumer closure: internal functions only, no storage, imports only `src/interfaces/`. The record id repeats
///      `Keys.record` with the same domain tag and argument order (a one-way door, checked against `Keys` in
///      `test/profiles/TopicVectors.t.sol`). `tools/topic-vectors.mjs` is the JS twin of every id and builder.
library EfsTopics {
    /// The Topics Type ids (`TopicTypes.typeIdOf` of the release descriptors).
    struct Types {
        bytes32 word;
        bytes32 topic;
        bytes32 text;
    }

    bytes32 internal constant DOM_RECORD = keccak256("efs/record/1");
    /// The domain of a `PROPERTY` key: `propertyKey(k) = keccak256(abi.encode(DOM_PROPERTY_KEY, keccak256(k)))`.
    bytes32 internal constant DOM_PROPERTY_KEY = keccak256("efs/property-key/1");

    // =============================================================================================
    // Ids (no chain read)
    // =============================================================================================

    /// `Keys.record`: the record id of `body` under `typeId`.
    function recordId(bytes32 typeId, bytes memory body) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, typeId, keccak256(body)));
    }

    /// The page of `word`, which is also the root-level topic `/<word>`.
    function wordPageId(bytes32 wordType, bytes memory word) internal pure returns (bytes32) {
        return recordId(wordType, word);
    }

    /// The `topic/1` body: `abi.encode(parent, wordPage)`, 64 bytes.
    function pathBody(bytes32 parent, bytes32 wordPage) internal pure returns (bytes memory) {
        return abi.encode(parent, wordPage);
    }

    /// The `topic/1` record of `parent` extended by the word whose page is `wordPage`.
    function childId(bytes32 topicType, bytes32 parent, bytes32 wordPage)
        internal
        pure
        returns (bytes32)
    {
        return recordId(topicType, pathBody(parent, wordPage));
    }

    /// The id of the path `words[0]/.../words[n-1]`: the word page for n = 1, else the `topic/1` record
    /// `[pathId(first n-1 words), wordPageId(last word)]`. Zero for the empty path (no topic).
    function pathId(Types memory t, bytes[] memory words) internal pure returns (bytes32 id) {
        uint256 n = words.length;
        if (n == 0) return 0;
        id = wordPageId(t.word, words[0]);
        for (uint256 i = 1; i < n; ++i) {
            id = childId(t.topic, id, wordPageId(t.word, words[i]));
        }
    }

    /// The role of a `PROPERTY` statement for the ASCII key `key` (`label:en`, `definition`, `moved-to`).
    function propertyKey(bytes memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_PROPERTY_KEY, keccak256(key)));
    }

    /// `propertyKey("label:" ‖ language)`: the label key of a BCP 47 language tag (`en`, `pt-br`).
    function labelKey(bytes memory language) internal pure returns (bytes32) {
        return propertyKey(bytes.concat("label:", language));
    }

    // =============================================================================================
    // Registration
    // =============================================================================================

    /// `PUBLISH(topic-word/1, word)`: the page of `word` (the root-level topic `/<word>`).
    function registerWord(Types memory t, bytes memory word)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 page)
    {
        (a, b) = _alloc(1);
        b[0] = word;
        a[0] = _publish(t.word, word);
        page = wordPageId(t.word, word);
    }

    /// Every record the path `words` needs, parents first: the n word pages in order, then the n - 1 `topic/1`
    /// records from the two-word prefix on (2n - 1 actions; n >= 1). Returns the path's id.
    function registerPath(Types memory t, bytes[] memory words)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 id)
    {
        uint256 n = words.length;
        require(n != 0, "EfsTopics: empty path");
        (a, b) = _alloc(2 * n - 1);
        for (uint256 i; i < n; ++i) {
            b[i] = words[i];
            a[i] = _publish(t.word, words[i]);
        }
        id = wordPageId(t.word, words[0]);
        for (uint256 i = 1; i < n; ++i) {
            b[n - 1 + i] = pathBody(id, wordPageId(t.word, words[i]));
            a[n - 1 + i] = _publish(t.topic, b[n - 1 + i]);
            id = recordId(t.topic, b[n - 1 + i]);
        }
    }

    /// One new leaf under an existing topic `parent`: the page of `word` when `withPage`, then the `topic/1`
    /// record `[parent, page]`. Returns the new topic's id.
    function registerChild(Types memory t, bytes32 parent, bytes memory word, bool withPage)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 id)
    {
        (a, b) = _alloc(withPage ? 2 : 1);
        uint256 k;
        if (withPage) {
            b[0] = word;
            a[0] = _publish(t.word, word);
            k = 1;
        }
        b[k] = pathBody(parent, wordPageId(t.word, word));
        a[k] = _publish(t.topic, b[k]);
        id = recordId(t.topic, b[k]);
    }

    // =============================================================================================
    // Statements
    // =============================================================================================

    /// A tag: `BIND(TAG, topic, role = thing → thing)` stating the number `strength` (0..65,535). `thing` is any
    /// record or created subject of any Type, or an address-shaped word (target kind ADDRESS). `expected` is the
    /// head's revision (0 for a first statement; changing the number on the same thing is this action again).
    function tag(bytes32 topic, bytes32 thing, uint64 expected, uint16 strength)
        internal
        pure
        returns (Action memory a)
    {
        a = _bind(Purpose.TAG, topic, thing, thing, expected);
        a.saltOrStrength = bytes32(uint256(strength));
    }

    /// "Not this": `UNBIND(TAG, topic, role = thing)` stating the number `-1 - strength`. With `expected` 0 it is a
    /// lone negative (a first statement, transition FIRST_MASK), which needs no earlier tag.
    function deny(bytes32 topic, bytes32 thing, uint64 expected, uint16 strength)
        internal
        pure
        returns (Action memory a)
    {
        a = _bind(Purpose.TAG, topic, thing, 0, expected);
        a.kind = ActionKind.UNBIND;
        a.saltOrStrength = bytes32(uint256(strength));
    }

    /// `BIND(PROPERTY, subject, key → value)`: one value per author per key. `subject` is any id (a topic, a home,
    /// a file, a folder); `value` a record (a `text/1`, any value record), a file subject or an address.
    function property(bytes32 subject, bytes32 key, bytes32 value, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bind(Purpose.PROPERTY, subject, key, value, expected);
    }

    /// A label: `PUBLISH(text/1, text)`, then `BIND(PROPERTY, subject, labelKey(language) → the text record)`.
    function label(
        Types memory t,
        bytes32 subject,
        bytes memory language,
        bytes memory text,
        uint64 expected
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 textRecord) {
        (a, b) = _alloc(2);
        b[0] = text;
        a[0] = _publish(t.text, text);
        textRecord = recordId(t.text, text);
        a[1] = property(subject, labelKey(language), textRecord, expected);
    }

    /// "Same as": `BIND(SAME, topic, role = other → other)`. Between two word pages it is the word-level synonym;
    /// between two path records it joins those two places only; between a word page and a path record it joins
    /// that root place and that one path (design §12.5).
    function same(bytes32 topic, bytes32 other, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bind(Purpose.SAME, topic, other, other, expected);
    }

    /// "Broader": `BIND(BROADER, topic, role = parent → parent)`, the optional booru-style parent of a topic.
    function broader(bytes32 topic, bytes32 parent, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bind(Purpose.BROADER, topic, parent, parent, expected);
    }

    // =============================================================================================
    // Internals
    // =============================================================================================

    function _publish(bytes32 typeId, bytes memory body) private pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function _bind(bytes32 purpose, bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        private
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _alloc(uint256 n) private pure returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](n);
        b = new bytes[](n);
    }
}
