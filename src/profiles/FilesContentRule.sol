// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesContentRule — the mandatory rule of `files-content/1` (design §12.1, revised by docs/LARGE-FILES.md)
/// @notice §12.1 row: "`files-content/1` | NATIVE | 11 words `[bytesRef, version, carrier, hashAlg, length, sha256,
///         media(2), cipher, nonce12, plaintextLength, plaintextSHA256OrZero]` | ... | `FilesContentRule` as measured
///         (`L/test/FilesCarrierProfile.sol:22`); word 5 feeds the digest family". The one reference is `ANY`
///         (`refHeaderWords = 3`) and this rule checks its Type by carrier. The law: exactly 352 bytes;
///         `bytesRef == refs[0]`; version 1; carrier 0 (one `files-bytes/1` record), 1 (remote) or 2 (a
///         `files-span/1` tree); hashAlg 1 (sha256); media ≤ 2; cipher 0 or 1; length and plaintextLength
///         ≤ 2^64 − 1; the 12-byte nonce is left-aligned (its low 20 bytes zero). Plaintext (cipher 0): nonce zero,
///         plaintextLength == length, plaintextSHA256 == sha256. Encrypted (cipher 1): length == plaintextLength
///         + 16 and plaintextSHA256 zero (no public plaintext fingerprint). By carrier: 0 the reference is an
///         admitted `files-bytes/1` record with `length − 32 == length word && word0 == sha256 word` (the bytes'
///         sha256 was verified at their admission, so the descriptor's digest is verified); 1 it is exactly the
///         empty sentinel (`files-bytes/1`, `length == 32 && word0 == sha256("")`), the remote bytes are NOT
///         validated at admission; 2 it is an admitted `files-span/1` root whose word 2 (the tree's payload length)
///         equals the length word. For carrier 2 the whole-file sha256 cannot be recomputed on chain: it is the
///         AUTHOR'S CLAIM, exactly as it is for an external location; the verified commitment is the span root id
///         (complete and correct by construction), and a reader checks the sha256 after reading the tree.
/// @dev Pure over calldata, `refHeaders` and constructor state (word0 is the bytes record's retained sha256, word2 a
///      span's length). The `files-bytes/1` and `files-span/1` Type ids are constructor STATE (written only by the
///      constructor; pinned by the descriptor's `ruleInitcodeHash`, design §9.3), for the reason given on
///      `FilesChildRule`. Refusal codes (`E_FILES_REFUSED`): 1 not exactly one ref/header, 2 body not 352 bytes,
///      3 `bytesRef != refs[0]`, 4 version/carrier/hashAlg/media/cipher/length/nonce domain, 5 cipher parameters,
///      6 carrier 0 or 1 and the reference is not an admitted `files-bytes/1` record, 7 remote without the empty
///      sentinel, 8 inline length or digest mismatch, 9 carrier 2 and the reference is not an admitted
///      `files-span/1` record, 10 carrier 2 and the span's length is not the length word.
contract FilesContentRule is IAcceptor {
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
        if (body.length != 352) revert E_FILES_REFUSED(2);
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
                    || uint256(bytes32(body[96:128])) != 1 || uint256(bytes32(body[192:224])) > 2
                    || cipher > 1 || length > FilesProfile.LENGTH_MAX
                    || plainLength > FilesProfile.LENGTH_MAX || uint160(uint256(nonce)) != 0
            ) revert E_FILES_REFUSED(4);
            if (cipher == 0) {
                if (nonce != 0 || plainLength != length || plainHash != digest) {
                    revert E_FILES_REFUSED(5);
                }
            } else if (length != plainLength + 16 || plainHash != 0) {
                revert E_FILES_REFUSED(5);
            }
        }
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
