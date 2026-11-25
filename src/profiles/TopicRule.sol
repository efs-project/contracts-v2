// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile} from "./FilesProfile.sol";
import {E_TOPIC_REFUSED} from "./TopicProfile.sol";

/// @title TopicRule — the mandatory rule of `topic/1` (design §12.5; docs/TAG-DESIGN.md §1)
/// @notice A path of two or more words. The body is exactly 64 bytes, `[parent, wordPage]`, both declared refs with
///         ref Types `[0 = ANY, topic-word/1]`: `/cars/tesla` is the record (page of `cars`, page of `tesla`) and
///         `/cars/tesla/model_y` is the record (`/cars/tesla`, page of `model_y`). This rule adds to the kernel's
///         reference law only that the parent is a `topic/1` (`ctx.typeId`) or `topic-word/1` record and the exact
///         length.
///
///         The references this rule judges ARE the body's two words. The caller never supplies refs: an `Action`
///         has no refs field, and the kernel (`LedgerIngress._resolveRefs`) reads declared reference i from body
///         word i of the very bytes it hashes into the record id and stores, then passes that same body, those refs
///         and their headers to `accept`. So `refs[0]` is body word 0 (the parent) and `refs[1]` body word 1 (the
///         word page), and a stored `topic/1` record whose words differ from what this rule judged cannot exist;
///         the rule needs no comparison of its own (`test/integration/Topics.t.sol`,
///         `test_the_judged_refs_are_the_body_words`). A direct call with refs that do not match the body is
///         judged on its headers alone, but no admission takes that path.
///
///         Identity. A topic's id is its record id, `Keys.record(topic/1, abi.encode(parent, wordPage))` (a word page's
///         is `Keys.record(topic-word/1, word)`): a hash of the Type and the body only, so it depends on neither the
///         author, the Realm nor the chain. Anyone computes it from the words with no chain read
///         (`EfsTopics.pathId`), and two people publishing `/cars/tesla` get the same id; the second publication
///         stores nothing again.
///
///         What the kernel's reference law (design §6.2) gives with no code here: parent before child and word page
///         before use (a record whose declared reference does not exist is refused, and a record admitted earlier
///         in the same publication counts, so a short new path registers in one transaction and a deep one splits
///         in order, parents first); and permanence (the law asks whether the reference was EVER admitted: a
///         WITHDRAW by the first registrant lowers an occurrence count and keeps the record's type and first
///         admission, so a withdrawal never unregisters a topic or anything below it).
///
///         One sequence of words has exactly one record. A one-word topic is only ever a `topic-word/1` record: a
///         `topic/1` cannot be built without a parent (the kernel refuses a zero or sentinel reference, `E_REF`
///         code 3, and a missing one, code 1). An n-word topic (n >= 2) is exactly the record
///         `[id(first n-1 words), wordPage(last word)]`: by induction the parent is the one record of the first
///         n-1 words, because a parent of any other Type (a file revision, a directory, a name, a text, anything)
///         is refused here, the second reference must be a `topic-word/1` record (the declared ref Type), and a body
///         of any other length is refused here, so no second encoding exists.
///
///         Depth is deliberately not stored. If the body carried a depth, this rule would have to enforce
///         depth = parent's depth + 1 (one more read), or two records could exist for one sequence of words; a
///         reader or the SDK learns the depth by walking the parents, and plans from the words anyway.
/// @dev The `topic-word/1` Type id is constructor STATE (one storage word written only by the constructor), not an
///      immutable, exactly as `FilesChildRule` holds its sibling ids: the profile immutables gate keeps
///      `immutableReferences` empty and the instance's initcode hash pins it. Never reads the ledger.
///      Refusal codes (`E_TOPIC_REFUSED`): 10 not exactly two refs and two headers, 11 the body is not exactly
///      64 bytes, 12 the parent is neither a `topic/1` nor a `topic-word/1` record, 13 the second reference is not
///      a `topic-word/1` record (the kernel refuses it first through the declared ref Type; kept so a direct call
///      is judged the same).
contract TopicRule is IAcceptor {
    /// The exact `topic-word/1` Type id (constructor state, never rewritten).
    bytes32 public wordTypeId;

    constructor(bytes32 wordTypeId_) {
        wordTypeId = wordTypeId_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 2 || refHeaders.length != 2) revert E_TOPIC_REFUSED(10);
        if (body.length != 64) revert E_TOPIC_REFUSED(11);
        bytes32 word = wordTypeId;
        bytes32 parent = refHeaders[0].typeId;
        if (parent != ctx.typeId && parent != word) revert E_TOPIC_REFUSED(12);
        if (refHeaders[1].typeId != word) revert E_TOPIC_REFUSED(13);
        return IAcceptor.accept.selector;
    }
}
