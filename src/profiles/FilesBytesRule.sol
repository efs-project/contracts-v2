// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesBytesRule — the mandatory rule of `files-bytes/1` (design §12.1)
/// @notice §12.1 row: "`files-bytes/1` | NATIVE | `sha256(payload) ‖ payload` | none | `FilesBytesRule` (ported from
///         `L/test/FilesCarrierProfile.sol:15`): hashes calldata once". Word 0 is the retained commitment, so a
///         descriptor joining these bytes needs only the header's `length` and `word0` (no cold rehash). The empty
///         payload (`length == 32 && word0 == sha256("")`) is the remote-carrier sentinel.
/// @dev Pure over calldata (the sha256 precompile). Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 body
///      shorter than one word or longer than 8,192 bytes, 3 word 0 is not sha256 of the payload.
contract FilesBytesRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length < 32 || body.length > FilesProfile.BYTES_BODY_MAX) {
            revert E_FILES_REFUSED(2);
        }
        if (bytes32(body[0:32]) != sha256(body[32:])) revert E_FILES_REFUSED(3);
        return IAcceptor.accept.selector;
    }
}
