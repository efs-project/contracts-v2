// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesDirectoryRule — the mandatory rule of `files-directory/1` (design §12.1)
/// @notice §12.1 row: "`files-directory/1` | NATIVE | `abi.encode(seedSubject)` | none | `FilesDirectoryRule`
///         (ported from `L/test/FilesDirectoryProfile.sol:32`): `subjectCreatedAt(seed) ≤ ctx.admission` and
///         nonzero". A directory's identity is this record (its id), derived from a CREATE seed subject; it is
///         not the seed, a name or a parent (placement is a FOLDER bind, judged by `FilesFinalValidator`).
/// @dev The body is exactly one word (the prototype's `test_directory_exact_body_length_required`: no trailing
///      metadata). Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 body not exactly 32 bytes, 3 seed zero,
///      4 seed not created at or before this admission. Reads only `ILedgerHot(ctx.ledger).subjectCreatedAt`.
contract FilesDirectoryRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (body.length != 32) revert E_FILES_REFUSED(2);
        bytes32 seed = bytes32(body);
        if (seed == 0) revert E_FILES_REFUSED(3);
        uint64 created = ILedgerHot(ctx.ledger).subjectCreatedAt(seed);
        if (created == 0 || created > ctx.admission) revert E_FILES_REFUSED(4);
        return IAcceptor.accept.selector;
    }
}
