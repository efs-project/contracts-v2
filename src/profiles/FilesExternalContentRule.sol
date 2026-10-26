// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesExternalContentRule — the mandatory rule of `files-external/1` (design §12.1)
/// @notice §12.1 row: "`files-external/1` | NATIVE | 7 words `[bytesRef, version (= 2), carrier (2 ar | 3 ipfs),
///         hashAlg (1 sha256), length (≤ 2^24), sha256, locatorLength]` ‖ ASCII locator (`ar://` + 43 base64url
///         chars; `ipfs://` CIDv0 `Qm…` or CIDv1 base32) | `[files-bytes/1]` (1) | `FilesExternalContentRule`:
///         `refs[0]` is the empty-sentinel bytes record (`refHeaders[0]`: `length == 32 && word0 == sha256("")`),
///         locator grammar as the prototype's (`L/test/FilesExternalContentProfile.sol:11-40`), no remote proof at
///         admission; word 5 feeds the digest family through the second gen-1 `DigestSpec`".
///         The body is exactly `224 + locatorLength` bytes; the locator is 1..512 bytes (the prototype's 704-byte body
///         cap less its 192-byte head). Locator grammar (the prototype's, byte for byte): `ar://` + 43 of
///         `[A-Za-z0-9_-]` (48 bytes); `ipfs://` + CIDv0 (`Qm` + 44 base58btc chars) or CIDv1 (`b` + 20..120 of
///         `[a-z2-7]`), then optional `/segment`s of `[A-Za-z0-9._~-]`, none empty, `.` or `..`.
/// @dev Pure over calldata and `refHeaders`. Refusal codes (`E_FILES_REFUSED`): 1 not exactly one ref/header,
///      2 body shorter than the 7-word head, 3 `bytesRef != refs[0]`, 4 version/carrier/hashAlg/length domain,
///      5 locatorLength not the body tail or outside 1..512, 6 locator grammar, 7 the ref is not the empty sentinel.
contract FilesExternalContentRule is IAcceptor {
    uint256 private constant HEAD = 224;
    uint256 private constant LOCATOR_MAX = 512;
    uint256 private constant LENGTH_MAX = 1 << 24;

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 1 || refHeaders.length != 1) revert E_FILES_REFUSED(1);
        if (body.length < HEAD) revert E_FILES_REFUSED(2);
        if (bytes32(body[0:32]) != refs[0]) revert E_FILES_REFUSED(3);
        uint256 carrier = uint256(bytes32(body[64:96]));
        if (
            uint256(bytes32(body[32:64])) != 2 || (carrier != 2 && carrier != 3)
                || uint256(bytes32(body[96:128])) != 1
                || uint256(bytes32(body[128:160])) > LENGTH_MAX
        ) revert E_FILES_REFUSED(4);
        uint256 locatorLength = uint256(bytes32(body[192:224]));
        if (
            locatorLength == 0 || locatorLength > LOCATOR_MAX || body.length != HEAD + locatorLength
        ) {
            revert E_FILES_REFUSED(5);
        }
        bytes calldata uri = body[HEAD:];
        if (carrier == 2 ? !_arweave(uri) : !_ipfs(uri)) revert E_FILES_REFUSED(6);
        RefHeader calldata b = refHeaders[0];
        if (b.firstAdmission == 0 || b.length != 32 || b.word0 != FilesProfile.SHA256_EMPTY) {
            revert E_FILES_REFUSED(7);
        }
        return IAcceptor.accept.selector;
    }

    function _arweave(bytes calldata uri) private pure returns (bool) {
        if (uri.length != 48 || bytes5(uri[:5]) != bytes5("ar://")) return false;
        for (uint256 i = 5; i < 48; ++i) {
            uint8 c = uint8(uri[i]);
            if (!_alpha(c) && !_digit(c) && c != 0x2d && c != 0x5f) return false;
        }
        return true;
    }

    function _ipfs(bytes calldata uri) private pure returns (bool) {
        if (uri.length < 28 || bytes7(uri[:7]) != bytes7("ipfs://")) return false;
        uint256 end = 7;
        while (end < uri.length && uri[end] != 0x2f) ++end;
        if (uri[7] == 0x51) {
            // CIDv0: "Qm" + base58btc (no 0, I, O, l)
            if (end != 53 || uri[8] != 0x6d) return false;
            for (uint256 i = 9; i < end; ++i) {
                uint8 c = uint8(uri[i]);
                if (!(_alpha(c) || (c >= 0x31 && c <= 0x39)) || c == 0x49 || c == 0x4f || c == 0x6c)
                {
                    return false;
                }
            }
        } else {
            // CIDv1: multibase "b" + lowercase RFC 4648 base32
            if (uri[7] != 0x62 || end < 28 || end > 128) return false;
            for (uint256 i = 8; i < end; ++i) {
                uint8 c = uint8(uri[i]);
                if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x32 && c <= 0x37))) return false;
            }
        }
        while (end < uri.length) {
            uint256 start = ++end;
            while (end < uri.length && uri[end] != 0x2f) {
                uint8 c = uint8(uri[end]);
                if (!_alpha(c) && !_digit(c) && c != 0x2e && c != 0x5f && c != 0x7e && c != 0x2d) {
                    return false;
                }
                ++end;
            }
            if (
                end == start || (end == start + 1 && uri[start] == 0x2e)
                    || (end == start + 2 && uri[start] == 0x2e && uri[start + 1] == 0x2e)
            ) return false;
        }
        return true;
    }

    function _alpha(uint8 c) private pure returns (bool) {
        return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    }

    function _digit(uint8 c) private pure returns (bool) {
        return c >= 0x30 && c <= 0x39;
    }
}
