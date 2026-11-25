// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesContentRule — the mandatory rule of `files-content/1` (design §12.1, revised by docs/LARGE-FILES.md)
/// @notice `[bytesRef, version, carrier, hashAlg, length, sha256, mediaLength, cipher, nonce12, plaintextLength,
///         plaintextSHA256OrZero] ‖ media`: eleven words, then `mediaLength` media bytes; word 5 feeds the digest
///         family. The one reference is `ANY` (`refHeaderWords = 3`) and this rule checks its Type by carrier. The
///         law: exactly `352 + mediaLength` bytes with `mediaLength ≤ 255`; `bytesRef == refs[0]`; version 1;
///         carrier 0 (one `files-bytes/1` record), 1 (remote) or 2 (a `files-span/1` tree); hashAlg 1 (sha256);
///         cipher 0 or 1; length and plaintextLength ≤ 2^64 − 1; the 12-byte nonce is left-aligned (its low 20
///         bytes zero); the media bytes satisfy `FilesProfile.mediaTypeRefusal` (empty: unknown; otherwise a
///         lowercase RFC 6838 `type/subtype` with optional `;` parameters). Plaintext (cipher 0): nonce zero,
///         plaintextLength == length, plaintextSHA256 == sha256. Encrypted (cipher 1): length == plaintextLength
///         + 16 and plaintextSHA256 zero (no public plaintext fingerprint); the media type is public metadata about
///         the plaintext, so an author who does not want to disclose it leaves it empty. By carrier: 0 the
///         reference is an admitted `files-bytes/1` record with `length − 32 == length word && word0 == sha256
///         word` (the bytes' sha256 was verified at their admission, so the descriptor's digest is verified); 1 it
///         is exactly the empty sentinel (`files-bytes/1`, `length == 32 && word0 == sha256("")`), the remote bytes
///         are NOT validated at admission; 2 it is an admitted `files-span/1` root whose word 2 (the tree's payload
///         length) equals the length word. For carrier 2 the whole-file sha256 cannot be recomputed on chain: it
///         is the AUTHOR'S CLAIM, exactly as it is for an external location; the verified commitment is the span
///         root id (complete and correct by construction), and a reader checks the sha256 after reading the tree.
///
///         The media type belongs to the bytes, so it lives here and not in a name or a property. The chain checks
///         its grammar because the `web3://` gateway emits it in an HTTP header (no control byte may ever be
///         admitted) and because a client compares `type/subtype` byte for byte (mixed case cannot be admitted);
///         an SDK lowercases and validates it before it builds a plan.
/// @dev Pure over calldata, `refHeaders` and constructor state (word0 is the bytes record's retained sha256, word2 a
///      span's length). The `files-bytes/1` and `files-span/1` Type ids are constructor STATE (written only by the
///      constructor; pinned by the descriptor's `ruleInitcodeHash`, design §9.3), for the reason given on
///      `FilesChildRule`. Refusal codes (`E_FILES_REFUSED`): 1 not exactly one ref/header, 2 body shorter than the
///      eleven words or not exactly `352 + mediaLength` bytes, 3 `bytesRef != refs[0]`, 4
///      version/carrier/hashAlg/cipher/length/nonce domain, 5 cipher parameters, 6 carrier 0 or 1 and the
///      reference is not an admitted `files-bytes/1` record, 7 remote without the empty sentinel, 8 inline length
///      or digest mismatch, 9 carrier 2 and the reference is not an admitted `files-span/1` record, 10 carrier 2
///      and the span's length is not the length word, 11 `mediaLength` above 255, 12 the media bytes are not a
///      media type (`FilesProfile.mediaTypeRefusal` is nonzero).
contract FilesContentRule is IAcceptor {
    /// The eleven words before the media bytes.
    uint256 private constant HEAD = 352;
    uint256 private constant CARRIER_REMOTE = 1;
    uint256 private constant CARRIER_SPAN = 2;

    /// The exact `files-bytes/1` Type id of carriers 0 and 1 (constructor state, never rewritten).
    bytes32 public bytesTypeId;
    /// The exact `files-span/1` Type id of carrier 2 (constructor state, never rewritten).
    bytes32 public spanTypeId;

    constructor(bytes32 bytesTypeId_, bytes32 spanTypeId_) {
        bytesTypeId = bytesTypeId_;
        spanTypeId = spanTypeId_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 1 || refHeaders.length != 1) revert E_FILES_REFUSED(1);
        if (body.length < HEAD) revert E_FILES_REFUSED(2);
        uint256 mediaLength = uint256(bytes32(body[192:224]));
        if (mediaLength > FilesProfile.MEDIA_MAX) revert E_FILES_REFUSED(11);
        if (body.length != HEAD + mediaLength) revert E_FILES_REFUSED(2);
        if (bytes32(body[0:32]) != refs[0]) revert E_FILES_REFUSED(3);
        uint256 carrier = uint256(bytes32(body[64:96]));
        uint256 length = uint256(bytes32(body[128:160]));
        bytes32 digest = bytes32(body[160:192]);
        {
            uint256 cipher = uint256(bytes32(body[224:256]));
            bytes32 nonce = bytes32(body[256:288]);
            uint256 plainLength = uint256(bytes32(body[288:320]));
            bytes32 plainHash = bytes32(body[320:352]);
            if (
                uint256(bytes32(body[32:64])) != 1 || carrier > CARRIER_SPAN
                    || uint256(bytes32(body[96:128])) != 1 || cipher > 1
                    || length > FilesProfile.LENGTH_MAX || plainLength > FilesProfile.LENGTH_MAX
                    || uint160(uint256(nonce)) != 0
            ) revert E_FILES_REFUSED(4);
            if (cipher == 0) {
                if (nonce != 0 || plainLength != length || plainHash != digest) {
                    revert E_FILES_REFUSED(5);
                }
            } else if (length != plainLength + 16 || plainHash != 0) {
                revert E_FILES_REFUSED(5);
            }
        }
        if (FilesProfile.mediaTypeRefusal(body[HEAD:]) != 0) revert E_FILES_REFUSED(12);
        RefHeader calldata b = refHeaders[0];
        if (carrier == CARRIER_SPAN) {
            if (b.firstAdmission == 0 || b.typeId != spanTypeId) revert E_FILES_REFUSED(9);
            if (uint256(b.word2) != length) revert E_FILES_REFUSED(10);
            return IAcceptor.accept.selector;
        }
        if (b.firstAdmission == 0 || b.typeId != bytesTypeId || b.length < 32) {
            revert E_FILES_REFUSED(6);
        }
        if (carrier == CARRIER_REMOTE) {
            if (b.length != 32 || b.word0 != FilesProfile.SHA256_EMPTY) revert E_FILES_REFUSED(7);
        } else if (b.length - 32 != length || b.word0 != digest) {
            revert E_FILES_REFUSED(8);
        }
        return IAcceptor.accept.selector;
    }
}
