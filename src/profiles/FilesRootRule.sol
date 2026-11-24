// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesRootRule — the mandatory rule of `files-root/1` (design §12.1, revised by docs/LARGE-FILES.md)
/// @notice `files-root/1 [fileSubject, form, …]`, refs none. The first revision of a file: word 0 names the file
///         subject (a CREATE subject that already exists, `subjectCreatedAt(file) != 0`), word 1 is the form:
///         form 0 INLINE, the rest of the body is the file's bytes (possibly empty); form 1 CONTENT, exactly one more
///         word, the id of an existing `files-content/1` or `files-external/1` record (one hot read,
///         `recordHeader(id).typeId` is one of the two descriptor Types), so a revision can never name a descriptor
///         that does not exist. Any other form refuses.
/// @dev The two descriptor Type ids are constructor STATE (written only by the constructor; pinned by the
///      descriptor's `ruleInitcodeHash`, design §9.3), for the reason given on `FilesChildRule`.
///      Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 body shorter than two words, 3 file word zero,
///      4 file subject not created, 5 form neither 0 nor 1, 6 form 1 and the body is not exactly three words,
///      7 form 1 and the named record is not an admitted `files-content/1` or `files-external/1` record.
///      Reads only `subjectCreatedAt` and `recordHeader` on `ctx.ledger`.
contract FilesRootRule is IAcceptor {
    /// The exact `files-content/1` Type id a form-1 revision may name (constructor state, never rewritten).
    bytes32 public contentTypeId;
    /// The exact `files-external/1` Type id a form-1 revision may name (constructor state, never rewritten).
    bytes32 public externalTypeId;

    constructor(bytes32 contentTypeId_, bytes32 externalTypeId_) {
        contentTypeId = contentTypeId_;
        externalTypeId = externalTypeId_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length < 64) revert E_FILES_REFUSED(2);
        bytes32 file = bytes32(body[0:32]);
        if (file == 0) revert E_FILES_REFUSED(3);
        ILedgerHot hot = ILedgerHot(ctx.ledger);
        if (hot.subjectCreatedAt(file) == 0) revert E_FILES_REFUSED(4);
        uint256 form = uint256(bytes32(body[32:64]));
        if (form == FilesProfile.FORM_CONTENT) {
            if (body.length != 96) revert E_FILES_REFUSED(6);
            (bytes32 t, uint64 first,,,) = hot.recordHeader(bytes32(body[64:96]));
            if (first == 0 || (t != contentTypeId && t != externalTypeId)) {
                revert E_FILES_REFUSED(7);
            }
        } else if (form != FilesProfile.FORM_INLINE) {
            revert E_FILES_REFUSED(5);
        }
        return IAcceptor.accept.selector;
    }
}
