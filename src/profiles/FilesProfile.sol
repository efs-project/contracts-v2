// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AcceptContext} from "../interfaces/IAcceptor.sol";

// Profile-local refusals of the Files profile (design §12). The kernel discards acceptor revert data and reports
// `E_REJECTED(leaf, typeId)` / `E_POLICY_REJECTED(leaf, typeId, row)`; these errors exist so a direct call (a unit
// test, an SDK pre-flight `eth_call` from the ledger's address) can tell which law refused. A final-hook refusal is
// nested by the index and the ingress inside `E_INDEX_CALL(inner)`, so `E_FILES_FINAL` is visible to the caller.

/// `ctx.ledger != msg.sender`: a forged context or a lookalike coordinator (design §5.10).
error E_FILES_CONTEXT(address ledger, address caller); // none
/// A rule's law refused the record; `code` is listed in each rule's NatSpec.
error E_FILES_REFUSED(uint8 code); // none
/// `FilesFinalValidator` refused the statement (a FOLDER, HEAD, TAG, SAME or BROADER bind or first mask) at
/// publication leaf `leaf`; codes 1 to 16 on the validator.
error E_FILES_FINAL(uint8 code, uint8 leaf); // reprepare
/// `RefuseAllPolicy`: the explicit sunset policy refuses every record.
error E_FILES_SUNSET(); // none

/// @title FilesProfile — constants shared by the Files rules (design §12.1)
/// @dev Internal only; no storage, no immutables (the profile immutables gate, `tools/checks.mjs`).
library FilesProfile {
    /// The ledger's head target kinds (`Effect.targetKind`, `ILedgerHot.head`): a record id, a created subject, an
    /// address-shaped word that is neither.
    uint8 internal constant TARGET_RECORD = 1;
    uint8 internal constant TARGET_SUBJECT = 2;
    uint8 internal constant TARGET_ADDRESS = 3;
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

    /// The longest media type a content descriptor carries (`files-content/1`, `files-external/1`).
    uint256 internal constant MEDIA_MAX = 255;

    /// Every acceptor must require `ctx.ledger == msg.sender` first (design §5.10).
    function requireLedger(AcceptContext calldata ctx) internal view {
        if (ctx.ledger != msg.sender) revert E_FILES_CONTEXT(ctx.ledger, msg.sender);
    }

    /// The media-type grammar of both content descriptors (docs/LARGE-FILES.md "Media types"). Returns 0 when `m`
    /// is admitted, else the first refusal: 1 longer than 255 bytes, 2 no valid type name at the start, 3 the type
    /// is not followed by `/`, 4 no valid subtype name after the `/`, 5 the subtype is followed by a byte other
    /// than `;`, 6 a byte outside 0x20..0x7e after the first `;`.
    ///
    /// Empty is admitted: the media type is unknown (a reader falls back to the name's extension). Otherwise
    /// `type "/" subtype [";" parameters]`: `type` and `subtype` are RFC 6838 restricted-names in LOWERCASE only,
    /// 1..127 bytes, the first byte `a-z` or `0-9`, the rest `a-z`, `0-9` or one of `! # $ & - ^ _ . +`; the
    /// first byte after the subtype is `;` or the end; every byte from that `;` to the end is printable ASCII
    /// including space (0x20..0x7e), so a parameter value such as `codecs="avc1.42E01E, mp4a.40.2"` keeps its
    /// case and spaces. Parameters are not parsed further. The canonical form is `text/html; charset=utf-8`; a
    /// space before the first `;` is refused (it is not a name byte).
    ///
    /// The chain checks this for two reasons only: the `web3://` gateway emits the string in an HTTP header, so a
    /// control byte (CR, LF, NUL) must never be admitted; and a client compares `type/subtype` byte for byte, so
    /// mixed case cannot be admitted (`Text/HTML` and `text/html` would be two answers for one type). The chain
    /// never normalizes: an SDK lowercases the type and subtype and refuses an invalid string before it builds a
    /// plan, so a bad media type is never an on-chain revert.
    /// @dev Byte at a time over calldata (bitmap lookups). `m.offset` is never 0 (calldata starts with a
    ///      selector), so 0 is a safe "no name here" answer of `name`.
    function mediaTypeRefusal(bytes calldata m) internal pure returns (uint256 code) {
        assembly ("memory-safe") {
            // the end of the restricted-name starting at p, or 0 when none starts there or it is over 127 bytes;
            // bit c of the first constant is set for a-z 0-9, of the second also for ! # $ & - ^ _ . +
            function name(p, e) -> q {
                if lt(p, e) {
                    if and(shr(byte(0, calldataload(p)), 0x7fffffe0000000003ff000000000000), 1) {
                        q := add(p, 1)
                        for {} lt(q, e) { q := add(q, 1) } {
                            if iszero(
                                and(
                                    shr(
                                        byte(0, calldataload(q)),
                                        0x7fffffec000000003ff685a00000000
                                    ),
                                    1
                                )
                            ) { break }
                        }
                        if gt(sub(q, p), 127) { q := 0 }
                    }
                }
            }
            let n := m.length
            if n {
                code := 1
                if lt(n, 256) {
                    let e := add(m.offset, n)
                    code := 2
                    let t := name(m.offset, e)
                    if t {
                        code := 3
                        if and(lt(t, e), eq(byte(0, calldataload(t)), 0x2f)) {
                            code := 4
                            let s := name(add(t, 1), e)
                            if s {
                                code := 0
                                if lt(s, e) {
                                    code := 5
                                    if eq(byte(0, calldataload(s)), 0x3b) {
                                        code := 0
                                        for { let i := add(s, 1) } lt(i, e) { i := add(i, 1) } {
                                            let c := byte(0, calldataload(i))
                                            if or(lt(c, 0x20), gt(c, 0x7e)) {
                                                code := 6
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
