// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AcceptContext} from "../interfaces/IAcceptor.sol";

// Profile-local refusals of the Files profile (design §12). The kernel discards acceptor revert data and reports
// `E_REJECTED(leaf, typeId)` / `E_POLICY_REJECTED(leaf, typeId, row)`; these errors exist so a direct call (a unit
// test, an SDK pre-flight `eth_call` from the ledger's address) can tell which law refused. A final-hook refusal is
// nested by the index and the ingress inside `E_INDEX_CALL(inner)`, so `E_FILES_FINAL` is visible to the caller.

/// `ctx.ledger != msg.sender`: a forged context or a lookalike coordinator (design §5.10).
error E_FILES_CONTEXT(address ledger, address caller);
/// A rule's law refused the record; `code` is listed in each rule's NatSpec.
error E_FILES_REFUSED(uint8 code);
/// `FilesFinalValidator` refused the FOLDER bind at publication leaf `leaf`; codes on the validator.
error E_FILES_FINAL(uint8 code, uint8 leaf);
/// `RefuseAllPolicy`: the explicit sunset policy refuses every record.
error E_FILES_SUNSET();

/// @title FilesProfile — constants shared by the Files rules (design §12.1)
/// @dev Internal only; no storage, no immutables (the profile immutables gate, `tools/checks.mjs`).
library FilesProfile {
    /// The ledger's head target kinds (`Effect.targetKind`, `ILedgerHot.head`): a record id, a created subject.
    uint8 internal constant TARGET_RECORD = 1;
    uint8 internal constant TARGET_SUBJECT = 2;
    /// sha256 of the empty string: the `files-bytes/1` sentinel body word of a remote (external) carrier.
    bytes32 internal constant SHA256_EMPTY =
        0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
    /// The bound on every content length (`files-content/1` length and plaintextLength, `files-external/1` length,
    /// `files-span/1` length): 2^64 − 1 (docs/LARGE-FILES.md). A `files-bytes/1` record has no codec cap: the
    /// Realm's `limits.maxBody` is its only bound, so a cheaper chain raises the chunk size by activation.
    uint256 internal constant LENGTH_MAX = type(uint64).max;
    /// The `form` word of a `files-root/1` / `files-child/1` revision (docs/LARGE-FILES.md): 0 the rest of the body
    /// is the file's bytes, 1 exactly one more word naming a `files-content/1` or `files-external/1` record.
    uint256 internal constant FORM_INLINE = 0;
    uint256 internal constant FORM_CONTENT = 1;

    /// Every acceptor must require `ctx.ledger == msg.sender` first (design §5.10).
    function requireLedger(AcceptContext calldata ctx) internal view {
        if (ctx.ledger != msg.sender) revert E_FILES_CONTEXT(ctx.ledger, msg.sender);
    }
}
