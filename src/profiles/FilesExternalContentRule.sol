// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesExternalContentRule — the mandatory rule of `files-external/1` (design §12.1, revised by
///        docs/LARGE-FILES.md)
/// @notice `[bytesRef (the empty sentinel), version = 2, carrier = 2, hashAlg = 1, length, sha256, locatorLength,
///         mediaLength] ‖ locator ‖ media`, refs `[files-bytes/1]` (the kernel checks the exact Type). The body is
///         exactly `256 + locatorLength + mediaLength` bytes. The locator is a URI of 1..2,048 bytes, every byte
///         printable ASCII (0x21..0x7e), beginning with an RFC 3986 scheme (`ALPHA *(ALPHA / DIGIT / "+" / "-" /
///         ".") ":"`) with at least one byte after the colon. There is NO scheme allowlist: `ar://`, `ipfs://`,
///         `bzz://`, `web3://`, `https://`, `data:` and schemes that do not exist yet are all admitted. A scheme
///         list on an immutable rule is not a security boundary (rendering safety lives in the client), is
///         trivially evaded and cannot anticipate new schemes (the v1 ruling of 2026-06-19, ADR-0056, carried
///         over). The media type is the `files-content/1` one: 0..255 bytes satisfying
///         `FilesProfile.mediaTypeRefusal` (empty: unknown; otherwise a lowercase RFC 6838 `type/subtype` with
///         optional `;` parameters), checked on chain because the `web3://` gateway emits it in an HTTP header
///         (`x-efs-media-type`; no control byte may ever be admitted) and because a client compares `type/subtype`
///         byte for byte (mixed case cannot be admitted). `length` ≤ 2^64 − 1. No remote proof is taken at
///         admission; readers verify the sha256 (word 5, which feeds the digest family through the second gen-1
///         `DigestSpec`). `refs[0]` is the empty-sentinel bytes record (`refHeaders[0]`: `length == 32 && word0 ==
///         sha256("")`).
/// @dev Pure over calldata and `refHeaders`. The locator checks run a word at a time (lane-parallel byte tests;
///      the tail word's bytes past the locator read as `!`), so a 2,048-byte locator, or a 2,046-byte scheme,
///      costs a few thousand gas whatever its shape.
///      Refusal codes (`E_FILES_REFUSED`): 1 not exactly one ref/header, 2 body shorter than the 8-word head,
///      3 `bytesRef != refs[0]`, 4 version/carrier/hashAlg/length domain, 5 locatorLength outside 1..2,048 or the
///      body not exactly `256 + locatorLength + mediaLength` bytes, 6 locator grammar (a byte outside 0x21..0x7e,
///      no scheme, or nothing after the colon), 7 the ref is not the empty sentinel, 8 `mediaLength` above 255,
///      9 the media bytes are not a media type (`FilesProfile.mediaTypeRefusal` is nonzero).
contract FilesExternalContentRule is IAcceptor {
    uint256 private constant HEAD = 256;
    uint256 private constant LOCATOR_MAX = 2_048;
    /// The one carrier of this Type: an external location given as a URI.
    uint256 private constant CARRIER_LOCATION = 2;
    /// Byte lanes (SWAR over 32-byte words; big-endian, so lane 0 is the most significant byte). Every lane test
    /// below assumes each byte is below 0x80, which the first test establishes, so no lane carries into the next.
    uint256 private constant LANES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant HI = LANES * 0x80;
    /// `!` in every lane: the bytes of the tail word past the locator read as this printable non-scheme byte.
    uint256 private constant FILL = LANES * 0x21;
    uint256 private constant COLONS = LANES * 0x3a;
    uint256 private constant PLUSES = LANES * 0x2b;
    uint256 private constant ALPHA = 0x7fffffe07fffffe0000000000000000; // a bitmap over 0..127

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
        if (
            uint256(bytes32(body[32:64])) != 2 || uint256(bytes32(body[64:96])) != CARRIER_LOCATION
                || uint256(bytes32(body[96:128])) != 1
                || uint256(bytes32(body[128:160])) > FilesProfile.LENGTH_MAX
        ) revert E_FILES_REFUSED(4);
        uint256 locatorLength = uint256(bytes32(body[192:224]));
        if (locatorLength == 0 || locatorLength > LOCATOR_MAX) revert E_FILES_REFUSED(5);
        uint256 mediaLength = uint256(bytes32(body[224:256]));
        if (mediaLength > FilesProfile.MEDIA_MAX) revert E_FILES_REFUSED(8);
        uint256 media = HEAD + locatorLength;
        if (body.length != media + mediaLength) revert E_FILES_REFUSED(5);
        if (!_locator(body[HEAD:media])) revert E_FILES_REFUSED(6);
        if (FilesProfile.mediaTypeRefusal(body[media:]) != 0) revert E_FILES_REFUSED(9);
        RefHeader calldata b = refHeaders[0];
        if (b.firstAdmission == 0 || b.length != 32 || b.word0 != FilesProfile.SHA256_EMPTY) {
            revert E_FILES_REFUSED(7);
        }
        return IAcceptor.accept.selector;
    }

    /// Every byte in 0x21..0x7e, an RFC 3986 scheme, a colon, at least one more byte. `uri` is 1..2,048 bytes.
    function _locator(bytes calldata uri) private pure returns (bool) {
        uint256 n = uri.length;
        uint256 off;
        assembly ("memory-safe") {
            off := uri.offset
        }
        // printable: a byte is in 0x21..0x7e iff its high bit is clear and it is in range
        for (uint256 i; i < n; i += 32) {
            uint256 w = _word(off, i, n);
            if (w & HI != 0 || _range(w, 0x21, 0x7e) != HI) return false;
        }
        // the scheme: ALPHA first, then scheme bytes; the first byte that is not a scheme byte must be a colon,
        // and that colon must not be the last byte
        if ((ALPHA >> uint8(uri[0])) & 1 == 0) return false;
        for (uint256 i; i < n; i += 32) {
            uint256 w = _word(off, i, n);
            uint256 colon = _equal(w, COLONS);
            uint256 other = HI & ~(_scheme(w) | colon);
            if (colon | other == 0) continue;
            // the two masks are disjoint: the larger holds the earliest lane
            if (colon < other) return false;
            // the first colon is the last byte iff it is the only colon of the word and sits in the last lane
            uint256 last = n - 1 - i;
            return last >= 32 || colon != uint256(0x80) << (8 * (31 - last));
        }
        return false;
    }

    /// The word at `i` of the locator; the lanes past its end read as `FILL`.
    function _word(uint256 off, uint256 i, uint256 n) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := calldataload(add(off, i))
        }
        uint256 rest = n - i;
        if (rest < 32) {
            uint256 keep = ~(type(uint256).max >> (rest * 8));
            w = (w & keep) | (FILL & ~keep);
        }
    }

    /// High bit of every lane whose byte is in `lo..hi` (`1 ≤ lo ≤ hi ≤ 0x7f`, every byte below 0x80).
    function _range(uint256 w, uint256 lo, uint256 hi) private pure returns (uint256) {
        unchecked {
            return (w + LANES * (0x80 - lo)) & ~(w + LANES * (0x7f - hi)) & HI;
        }
    }

    /// High bit of every lane equal to the byte repeated in `k` (every byte below 0x80).
    function _equal(uint256 w, uint256 k) private pure returns (uint256) {
        unchecked {
            uint256 x = w ^ k;
            return ~((x + LANES * 0x7f) | x) & HI;
        }
    }

    /// High bit of every lane holding `ALPHA / DIGIT / "+" / "-" / "."`.
    function _scheme(uint256 w) private pure returns (uint256) {
        return _range(w, 0x41, 0x5a) | _range(w, 0x61, 0x7a) | _range(w, 0x30, 0x39)
            | _range(w, 0x2d, 0x2e) | _equal(w, PLUSES);
    }
}
