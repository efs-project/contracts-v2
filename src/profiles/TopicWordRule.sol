// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile} from "./FilesProfile.sol";
import {TopicProfile, E_TOPIC_REFUSED} from "./TopicProfile.sol";

/// @title TopicWordRule — the mandatory rule of `topic-word/1` (design §12.5; docs/TAG-DESIGN.md §1)
/// @notice A word's page, which is also the root-level topic `/<word>`: the body is the word's bytes and nothing
///         else, no refs. The word rules (`TopicProfile.wordRefusal`, codes 1-4, 6, 7 and 9: of ASCII only
///         `a`-`z`, `0`-`9`, `-`, `_` and `.`, never `.` last, never `-` first, no Unicode whitespace at all, nothing of
///         `TopicProfile.REFUSED`) run here, once per word, when its
///         page is published (a later PUBLISH of the same page re-runs them on the same bytes). A `topic/1` record
///         never re-reads a word: it names the page by reference, so every word of every path was judged here.
/// @dev Pure over calldata. Refusal codes (`E_TOPIC_REFUSED`): 8 refs present (checked first), else
///      `TopicProfile.wordRefusal`'s code (1-4, 6, 7 or 9; 5 is unused).
contract TopicWordRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_TOPIC_REFUSED(8);
        uint256 code = TopicProfile.wordRefusal(body);
        if (code != 0) revert E_TOPIC_REFUSED(uint8(code));
        return IAcceptor.accept.selector;
    }
}
