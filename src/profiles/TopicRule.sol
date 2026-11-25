// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile} from "./FilesProfile.sol";
import {E_TOPIC_REFUSED} from "./TopicProfile.sol";

/// @title TopicRule — the mandatory rule of `topic/1` (SPIKE, tags/topics)
/// @notice A path of two or more words. The body is exactly 64 bytes, `[parent, wordPage]`, both declared refs with
///         ref Types `[0 = ANY, topic-word/1]`, so the kernel's reference law already guarantees both records exist
///         (parent before child, word page before use; a record admitted earlier in the same publication counts)
///         and that `wordPage` is a `topic-word/1` record. This rule adds only that the parent is a `topic/1`
///         (SELF, `ctx.typeId`) or a `topic-word/1` record, and the exact length.
///
///         Uniqueness: one sequence of words has exactly one record. A one-word path is only ever a `topic-word/1`
///         record: a `topic/1` cannot be built without a parent reference (64 bytes, two refs), and the kernel
///         refuses a zero or sentinel reference (`E_REF(leaf, i, 3)` below 2^16) and a missing one
///         (`E_REF(leaf, i, 1)`). An n-word path (n >= 2) is exactly the one `topic/1` record
///         `[id(first n-1 words), wordPage(last word)]`: the parent must be the (unique, by induction) record of the
///         first n-1 words, since a parent of any other Type (a file revision, a directory, a name, anything) is
///         refused here, and a body of any other length is refused here, so no second encoding exists.
/// @dev The `topic-word/1` Type id is constructor STATE (one storage word written only by the constructor), not an
///      immutable, exactly as `FilesChildRule` holds its sibling ids: the profile immutables gate keeps
///      `immutableReferences` empty and the NATIVE instance's initcode hash pins it. Never reads the ledger.
///      Refusal codes (`E_TOPIC_REFUSED`): 10 not exactly two refs/headers, 11 body not exactly 64 bytes,
///      12 parent neither `topic/1` nor `topic-word/1`, 13 the second ref is not a `topic-word/1` record (the kernel
///      already refuses it; kept so a direct call is judged the same).
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
