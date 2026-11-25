// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile} from "./FilesProfile.sol";
import {TopicWord, E_TOPIC_REFUSED} from "./TopicProfile.sol";

/// @title TopicWordRule — the mandatory rule of `topic-word/1` (SPIKE, tags/topics)
/// @notice A word's page, which is also the root-level topic `/<word>`. The body is the word's bytes, nothing else;
///         no refs. The grammar is `TopicWord.refusal` (codes 1–6). The word rules run here once per word, when its
///         page is first admitted (a later REUSE of the page re-runs them on the same bytes); a `topic/1` record
///         never re-reads a word, it names the page by reference.
/// @dev Pure over calldata. Refusal codes (`E_TOPIC_REFUSED`): 1–6 `TopicWord.refusal`, 7 refs present.
contract TopicWordRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_TOPIC_REFUSED(7);
        uint256 code = TopicWord.refusal(body);
        if (code != 0) revert E_TOPIC_REFUSED(uint8(code));
        return IAcceptor.accept.selector;
    }
}
