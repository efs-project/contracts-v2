// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile} from "./FilesProfile.sol";
import {TopicProfile, E_TOPIC_REFUSED} from "./TopicProfile.sol";

/// @title TextRule — the mandatory rule of `text/1` (design §12.5; docs/TAG-DESIGN.md §8)
/// @notice A short display string, the value a `PROPERTY` statement names for a label (`label:en` → a `text/1`
///         record). The body is the text's bytes, no refs: 1 to 255 bytes of well-formed UTF-8 with no control
///         character and no bidirectional, invisible or noncharacter code point (`TopicProfile.textRefusal`). `/`,
///         spaces (U+0020 and the no-break and typographic spaces; never U+2028 or U+2029: a label is one line) and
///         uppercase are admitted (`files-name/3` refuses `/`, so a name cannot hold "AC/DC").
/// @dev Pure over calldata. Refusal codes (`E_TOPIC_REFUSED`): 24 refs present (checked first), else
///      `TopicProfile.textRefusal`'s code 20-23.
contract TextRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_TOPIC_REFUSED(24);
        uint256 code = TopicProfile.textRefusal(body);
        if (code != 0) revert E_TOPIC_REFUSED(uint8(code));
        return IAcceptor.accept.selector;
    }
}
