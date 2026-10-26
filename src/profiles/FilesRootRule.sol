// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesRootRule — the mandatory rule of `files-root/1` (design §12.1)
/// @notice §12.1 row: "`files-root/1` | NATIVE | `abi.encode(fileSubject) ‖ document` (≥ 32 B) | none |
///         `FilesRootRule` (ported from `L/test/FilesJoinedProfile.sol:31`): `refs == 0`, `file != 0`,
///         `subjectCreatedAt(file) != 0`". The first revision of a file: word 0 names the file subject (a CREATE
///         subject that already exists), the rest is the document.
/// @dev Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 body shorter than one word, 3 file word zero,
///      4 file subject not created. Reads only `ILedgerHot(ctx.ledger).subjectCreatedAt`.
contract FilesRootRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length < 32) revert E_FILES_REFUSED(2);
        bytes32 file = bytes32(body[0:32]);
        if (file == 0) revert E_FILES_REFUSED(3);
        if (ILedgerHot(ctx.ledger).subjectCreatedAt(file) == 0) revert E_FILES_REFUSED(4);
        return IAcceptor.accept.selector;
    }
}
