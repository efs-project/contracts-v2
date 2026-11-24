// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesSpanRule — the mandatory rule of `files-span/1` (docs/LARGE-FILES.md)
/// @notice `files-span/1 [left, right, length]`, refs `[ANY, ANY]`, `refHeaderWords = 3`: a binary node of a large
///         file's span tree. Each child is a `files-bytes/1` record with a nonempty payload (its payload length is
///         `header.length − 32`) or another `files-span/1` record (its length is its word 2); the rule requires
///         `length == len(left) + len(right)` and `length < 2^64`, all from the reference headers the kernel already
///         loaded: no body loads, no reads. Two is the widest fan-out the acceptor ABI can verify this way (three
///         header words: two child ids and the length). A span's record id commits to every chunk under it and every
///         chunk's sha256 was verified at its admission, so a span tree is complete and correct by construction; its
///         order is left then right (a reader walks it depth-first, left first).
/// @dev The `files-bytes/1` Type id is constructor STATE (written only by the constructor; pinned by the
///      descriptor's `ruleInitcodeHash`, design §9.3), for the reason given on `FilesChildRule`; a span child is
///      `ctx.typeId` (SELF). Pure over calldata, `refHeaders` and constructor state.
///      Refusal codes (`E_FILES_REFUSED`): 1 not exactly two refs/headers, 2 body not exactly 96 bytes,
///      3 `left != refs[0]` or `right != refs[1]`, 4 a child that is neither an admitted `files-bytes/1` nor an
///      admitted `files-span/1` record, 5 a `files-bytes/1` child with an empty payload, 6 `length` is not the sum of
///      the children's lengths or is at least 2^64.
contract FilesSpanRule is IAcceptor {
    /// The exact `files-bytes/1` Type id whose records may be a leaf (constructor state, never rewritten).
    bytes32 public bytesTypeId;

    constructor(bytes32 bytesTypeId_) {
        bytesTypeId = bytesTypeId_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 2 || refHeaders.length != 2) revert E_FILES_REFUSED(1);
        if (body.length != 96) revert E_FILES_REFUSED(2);
        if (bytes32(body[0:32]) != refs[0] || bytes32(body[32:64]) != refs[1]) {
            revert E_FILES_REFUSED(3);
        }
        bytes32 leaf = bytesTypeId;
        uint256 sum =
            _length(refHeaders[0], leaf, ctx.typeId) + _length(refHeaders[1], leaf, ctx.typeId);
        uint256 length = uint256(bytes32(body[64:96]));
        if (length != sum || length > FilesProfile.LENGTH_MAX) revert E_FILES_REFUSED(6);
        return IAcceptor.accept.selector;
    }

    /// The payload length a child contributes: `length − 32` for a chunk (nonzero), word 2 for a span. A span
    /// child's word 2 is below 2^64 (it was admitted under this law); it is checked again so the sum of two can
    /// never overflow whatever header is supplied.
    function _length(RefHeader calldata h, bytes32 leaf, bytes32 self)
        private
        pure
        returns (uint256)
    {
        if (h.firstAdmission == 0) revert E_FILES_REFUSED(4);
        if (h.typeId == leaf) {
            if (h.length <= 32) revert E_FILES_REFUSED(5);
            return h.length - 32;
        }
        if (h.typeId != self) revert E_FILES_REFUSED(4);
        uint256 length = uint256(h.word2);
        if (length > FilesProfile.LENGTH_MAX) revert E_FILES_REFUSED(6);
        return length;
    }
}
