// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";
import {Keys} from "../lib/Keys.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title RealmNoticeRule — the mandatory rule of `realm-notice/1` (design §12.1, §8.10)
/// @notice §12.1 row: "`realm-notice/1` | NATIVE | `abi.encode(kind, revision, note)` | none | `RealmNoticeRule`:
///         `kind ∈ {frozen, successor, migration}`; `frozen`/`migration` require `ctx.principalId ==
///         Keys.contractPrincipal(realmOrigin(), controller())`, `successor` requires `ctx.principalId ==
///         noticePrincipal() != 0` (all hot reads on `ctx.ledger`); the freeze canaries and the only successor
///         evidence". The kinds are the closure constants `ClosureConstants.NOTICE_{FROZEN,SUCCESSOR,MIGRATION}`;
///         the body is the canonical ABI encoding of `(bytes32 kind, uint256 revision, bytes note)` — the exact
///         bytes `RealmController`'s freeze canary writes, `abi.encode(NOTICE_FROZEN, uint256(revision), bytes(""))`
///         — so one notice has one record id: the offset word is 0x60, the body ends at the note's 32-byte-padded
///         end and the padding is zero. `revision` and `note` are otherwise unconstrained (the row constrains neither).
/// @dev Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 not the canonical encoding, 3 unknown kind,
///      4 frozen/migration not by the controller's contract principal, 5 successor with no notice principal or
///      by another principal.
contract RealmNoticeRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (!_canonical(body)) revert E_FILES_REFUSED(2);
        bytes32 kind = bytes32(body[0:32]);
        ILedgerHot hot = ILedgerHot(ctx.ledger);
        if (kind == ClosureConstants.NOTICE_FROZEN || kind == ClosureConstants.NOTICE_MIGRATION) {
            if (ctx.principalId != Keys.contractPrincipal(hot.realmOrigin(), hot.controller())) {
                revert E_FILES_REFUSED(4);
            }
        } else if (kind == ClosureConstants.NOTICE_SUCCESSOR) {
            bytes32 notice = hot.noticePrincipal();
            if (notice == 0 || ctx.principalId != notice) revert E_FILES_REFUSED(5);
        } else {
            revert E_FILES_REFUSED(3);
        }
        return IAcceptor.accept.selector;
    }

    /// `abi.encode(bytes32, uint256, bytes)` exactly: head `[kind, revision, 0x60]`, the note length, the note
    /// padded with zero bytes to a word boundary, nothing after.
    function _canonical(bytes calldata body) private pure returns (bool) {
        if (body.length < 128 || uint256(bytes32(body[64:96])) != 0x60) return false;
        uint256 n = uint256(bytes32(body[96:128]));
        if (n > body.length) return false;
        uint256 padded = (n + 31) & ~uint256(31);
        if (body.length != 128 + padded) return false;
        if (padded != n) {
            // the last word holds the tail of the note followed by zero padding
            uint256 last = uint256(bytes32(body[body.length - 32:]));
            if (last & ((uint256(1) << ((padded - n) * 8)) - 1) != 0) return false;
        }
        return true;
    }
}
