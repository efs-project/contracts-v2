// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesChildRule — the mandatory rule of `files-child/1` (design §12.1, revised by docs/LARGE-FILES.md)
/// @notice §12.1 row: "`files-child/1` | NATIVE | `abi.encode(parentRecord, fileSubject) ‖ document` (≥ 64 B) |
///         `[0 = ANY]` (2) | `FilesChildRule` (ported from `L/test/FilesJoinedProfile.sol:39`): `parent == refs[0]`;
///         from `refHeaders[0]`: root → `length ≥ 32 && word0 == file`; child → `length ≥ 64 && word1 == file`;
///         never loads the parent body". A later revision names its parent revision (a `files-root/1` record or a
///         record of this very Type) and the same file subject; the parent's words come from the header the kernel
///         already loaded (`refHeaderWords = 2`). docs/LARGE-FILES.md adds the `form` word after the fixed words,
///         `[parentRecord, fileSubject, form, …]`, with the law of `FilesRootRule`: form 0 INLINE, the rest of the body
///         is the file's bytes (possibly empty); form 1 CONTENT, exactly one more word naming an admitted
///         `files-content/1` or `files-external/1` record (one hot read). The parent law is unchanged (the file word
///         keeps its position).
/// @dev "root" is the exact `files-root/1` Type id of the same profile, fixed at construction. It is constructor
///      STATE (one storage word written only by the constructor; the runtime has no `SSTORE`), not an immutable:
///      the profile immutables gate keeps `immutableReferences` empty, and design §9.3 pins a NATIVE instance's
///      constructor state by the descriptor's `ruleInitcodeHash` (instance = CREATE2(factory, 0, initcode ‖ args)),
///      so the Type id commits to the root Type id and stays identical on every Realm and chain. "child" is
///      `ctx.typeId` (SELF). A parent of any other Type refuses (the prototype's "wildcard reference is not an
///      arbitrary acceptable parent" canary). The two descriptor Type ids are constructor state for the same reason.
///      Refusal codes (`E_FILES_REFUSED`): 1 not exactly one ref/header, 2 body shorter than three words,
///      3 `parent != refs[0]`, 4 file word zero, 5 root parent shorter than one word or another file,
///      6 child parent shorter than two words or another file, 7 parent of neither Type, 8 form neither 0 nor 1,
///      9 form 1 and the body is not exactly four words, 10 form 1 and the named record is not an admitted
///      `files-content/1` or `files-external/1` record. Reads only `recordHeader` on `ctx.ledger`, and only for
///      form 1.
contract FilesChildRule is IAcceptor {
    /// The exact `files-root/1` Type id whose records may be a parent (constructor state, never rewritten).
    bytes32 public rootTypeId;
    /// The exact `files-content/1` Type id a form-1 revision may name (constructor state, never rewritten).
    bytes32 public contentTypeId;
    /// The exact `files-external/1` Type id a form-1 revision may name (constructor state, never rewritten).
    bytes32 public externalTypeId;

    constructor(bytes32 rootTypeId_, bytes32 contentTypeId_, bytes32 externalTypeId_) {
        rootTypeId = rootTypeId_;
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
        if (refs.length != 1 || refHeaders.length != 1) revert E_FILES_REFUSED(1);
        if (body.length < 96) revert E_FILES_REFUSED(2);
        if (bytes32(body[0:32]) != refs[0]) revert E_FILES_REFUSED(3);
        bytes32 file = bytes32(body[32:64]);
        if (file == 0) revert E_FILES_REFUSED(4);
        RefHeader calldata parent = refHeaders[0];
        if (parent.typeId == ctx.typeId) {
            if (parent.length < 64 || parent.word1 != file) revert E_FILES_REFUSED(6);
        } else if (parent.typeId == rootTypeId) {
            if (parent.length < 32 || parent.word0 != file) revert E_FILES_REFUSED(5);
        } else {
            revert E_FILES_REFUSED(7);
        }
        uint256 form = uint256(bytes32(body[64:96]));
        if (form == FilesProfile.FORM_CONTENT) {
            if (body.length != 128) revert E_FILES_REFUSED(9);
            (bytes32 t, uint64 first,,,) =
                ILedgerHot(ctx.ledger).recordHeader(bytes32(body[96:128]));
            if (first == 0 || (t != contentTypeId && t != externalTypeId)) {
                revert E_FILES_REFUSED(10);
            }
        } else if (form != FilesProfile.FORM_INLINE) {
            revert E_FILES_REFUSED(8);
        }
        return IAcceptor.accept.selector;
    }
}
