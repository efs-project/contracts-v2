// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title DirectoryAliasRule — the mandatory rule of `directory-alias/1` (design §12.1)
/// @notice §12.1 row: "`directory-alias/1` | NATIVE | `abi.encode(targetObjectId, kind)` | none | id-targeted alias".
///         The naming reconciliation (§7) fixes the law the row leaves implicit: an alias targets an OBJECT id, never
///         a path or a name, so following one is a single hop by Type. `kind` uses the ledger's own target-kind
///         numbering (`ILedgerHot.head`, `Effect.targetKind`): 1 = a directory (a `files-directory/1` record of this
///         profile), 2 = a file (a created subject). The body is exactly two words.
/// @dev The directory Type id is constructor STATE (written only by the constructor; pinned by the descriptor's
///      `ruleInitcodeHash`, design §9.3), for the reason given on `FilesChildRule`. Refusal codes
///      (`E_FILES_REFUSED`): 1 refs present, 2 body not exactly 64 bytes, 3 target zero, 4 kind not 1 or 2,
///      5 kind 1 and the target is not a directory record, 6 kind 2 and the target subject was never created.
///      Reads only `recordHeader`/`subjectCreatedAt` on `ctx.ledger`.
contract DirectoryAliasRule is IAcceptor {
    /// The exact `files-directory/1` Type id a kind-1 alias may target (constructor state, never rewritten).
    bytes32 public directoryTypeId;

    constructor(bytes32 directoryTypeId_) {
        directoryTypeId = directoryTypeId_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length != 64) revert E_FILES_REFUSED(2);
        bytes32 target = bytes32(body[0:32]);
        uint256 kind = uint256(bytes32(body[32:64]));
        if (target == 0) revert E_FILES_REFUSED(3);
        if (kind == FilesProfile.TARGET_RECORD) {
            (bytes32 t, uint64 first,,,) = ILedgerHot(ctx.ledger).recordHeader(target);
            if (first == 0 || t != directoryTypeId) revert E_FILES_REFUSED(5);
        } else if (kind == FilesProfile.TARGET_SUBJECT) {
            if (ILedgerHot(ctx.ledger).subjectCreatedAt(target) == 0) revert E_FILES_REFUSED(6);
        } else {
            revert E_FILES_REFUSED(4);
        }
        return IAcceptor.accept.selector;
    }
}
