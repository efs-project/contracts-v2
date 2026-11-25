// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesDirectoryRule — the mandatory rule of `files-directory/1` (design §12.1)
/// @notice §12.1 row: "`files-directory/1` | NATIVE | `abi.encode(creatorPrincipal, salt)` | none |
///         `FilesDirectoryRule`: `ctx.principalId == creatorPrincipal`, `salt != 0`". A folder's identity is this
///         record (its id, `Keys.record(directoryType, keccak256(body))`); it is not a subject, a name or a parent
///         (placement is a FOLDER bind, judged by `FilesFinalValidator`). Word 0 names the folder's creator and only
///         that principal can admit the record, so a folder that reads as created by Alice was published by Alice;
///         word 1 is the creator's salt, so one creator has any number of folders. Publishing the same
///         `(creator, salt)` again by the creator is another occurrence of the same record: no new record or body
///         is stored (only what any repeat PUBLISH writes: the occurrence count, an admission row, index postings).
///         The kernel runs this rule on REUSE as on PUBLISH (with the REUSE publisher's principal and the stored
///         body), so no other principal can admit an occurrence of the record either.
///
///         Kind is a property of the id. A file is a created subject (`Keys.subject`, keccak over the domain tag
///         `efs/subject/1`) and a folder is a record (`Keys.record`, keccak over the domain tag `efs/record/1`):
///         both are keccak outputs of three-word preimages whose first words are different domain tags, so no id is
///         both a record and a subject short of a keccak collision. "A `files-directory/1` record of this profile's
///         Type, else a created subject, else absent" is therefore a sound routing rule, and a `files-root/1` whose
///         file word is a folder's id is refused by `FilesRootRule` (the id was never created as a subject).
/// @dev The body is exactly two words (no trailing metadata). The rule is pure over calldata and its context: it
///      reads nothing from the ledger. Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 body not exactly
///      64 bytes, 3 salt zero, 4 the creator word is not the publishing principal (`ctx.principalId`).
contract FilesDirectoryRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length != 64) revert E_FILES_REFUSED(2);
        if (bytes32(body[32:64]) == 0) revert E_FILES_REFUSED(3);
        if (bytes32(body[0:32]) != ctx.principalId) revert E_FILES_REFUSED(4);
        return IAcceptor.accept.selector;
    }
}
