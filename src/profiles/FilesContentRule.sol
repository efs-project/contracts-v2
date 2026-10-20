// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesContentRule — the mandatory rule of `files-content/1` (design §12.1)
/// @notice §12.1 row: "`files-content/1` | NATIVE | 11 words `[bytesRef, version, carrier, hashAlg, length, sha256,
///         media(2), cipher, nonce12, plaintextLength, plaintextSHA256OrZero]` | `[files-bytes/1]` (3) |
///         `FilesContentRule` as measured (`L/test/FilesCarrierProfile.sol:22`); word 5 feeds the digest family".
///         The prototype's law, verbatim in meaning: exactly 352 bytes; `bytesRef == refs[0]`; version 1; carrier
///         0 (inline) or 1 (remote); hashAlg 1 (sha256); media ≤ 2; cipher 0 or 1; length and plaintextLength
///         ≤ 1 MiB; the 12-byte nonce is left-aligned (its low 20 bytes zero). Plaintext (cipher 0): nonce zero,
///         plaintextLength == length, plaintextSHA256 == sha256. Encrypted (cipher 1): length == plaintextLength
///         + 16 and plaintextSHA256 zero (no public plaintext fingerprint). The referenced `files-bytes/1` record
///         (its Type is the descriptor's exact ref, verified by the kernel) holds 32..8,192 bytes; remote: exactly
///         the empty sentinel (`length == 32 && word0 == sha256("")`), the remote bytes are NOT validated at
///         admission; inline: `length − 32 == length word && word0 == sha256 word`.
/// @dev Pure over calldata and `refHeaders` (word0 is the bytes record's retained sha256). Refusal codes
///      (`E_FILES_REFUSED`): 1 not exactly one ref/header, 2 body not 352 bytes, 3 `bytesRef != refs[0]`,
///      4 version/carrier/hashAlg/media/cipher/length/nonce domain, 5 cipher parameters, 6 bytes record outside
///      32..8,192, 7 remote without the empty sentinel, 8 inline length or digest mismatch.
contract FilesContentRule is IAcceptor {
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
                uint256(bytes32(body[32:64])) != 1 || carrier > 1
                    || uint256(bytes32(body[96:128])) != 1 || uint256(bytes32(body[192:224])) > 2
                    || cipher > 1 || length > FilesProfile.CONTENT_LENGTH_MAX
                    || plainLength > FilesProfile.CONTENT_LENGTH_MAX || uint160(uint256(nonce)) != 0
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
        if (b.firstAdmission == 0 || b.length < 32 || b.length > FilesProfile.BYTES_BODY_MAX) {
            revert E_FILES_REFUSED(6);
        }
        if (carrier == 1) {
            if (b.length != 32 || b.word0 != FilesProfile.SHA256_EMPTY) revert E_FILES_REFUSED(7);
        } else if (b.length - 32 != length || b.word0 != digest) {
            revert E_FILES_REFUSED(8);
        }
        return IAcceptor.accept.selector;
    }
}
