// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {Status} from "../../src/interfaces/Results.sol";

/// @notice User bytes whose FIRST BYTE is 0xEF store and read back exactly, through every path a file's bytes take.
///         EIP-3541 refuses to deploy contract code that starts with 0xEF, so a system that keeps user data as
///         contract code cannot hold such data. This repository does not: every record body (inline revisions,
///         `files-bytes/1` chunks, `files-span/1` pieces, `files-content/1` descriptors) is stored as STORAGE WORDS
///         (`carrierKind` 0, INLINE_WORDS), never as code, and the only data-as-code write, `DescriptorStore`, always
///         prefixes its runtime with a STOP byte. The suite writes 0xEF-leading bytes down each path and compares
///         what the read facets and the web3:// gateway return with what was written, byte for byte.
contract BytesStartingWithEFTest is Web3GatewayHarness {
    uint256 internal constant FILE_HEADER = 64; // an inline revision body is `file ‖ form ‖ document`
    uint256 internal constant CHUNK_HEADER = 32; // a files-bytes/1 body is `sha256 ‖ payload`

    function setUp() public {
        _setUpGateway();
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    function _url(string memory name) internal view returns (string memory) {
        return string.concat(R, "/", name);
    }

    function _repeat(bytes1 b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b;
        }
    }

    /// An inline file `name` holding `document`; returns its first revision record.
    function _inline(string memory name, bytes memory document) internal returns (bytes32 root) {
        (Action[] memory a, bytes[] memory b,, bytes32 rr) =
            EfsFiles.createFile(t, p, rootDir, keccak256(bytes(name)), bytes(name), document, true);
        _exec(a, b);
        return rr;
    }

    /// A record's body bytes `[offset, offset + length)` through the read facet.
    function _slice(bytes32 record, uint256 offset, uint256 length)
        internal
        view
        returns (bytes memory)
    {
        (Status s, bytes memory out) =
            reads.bodySlice(address(r.ledger), record, uint32(offset), uint32(length));
        assertEq(uint8(s), uint8(Status.PRESENT), "the body is present");
        return out;
    }

    function _assertInline(string memory name, bytes memory document) internal {
        assertEq(uint8(document[0]), 0xEF, "the document starts with 0xEF");
        bytes32 root = _inline(name, document);
        // the stored body: file ‖ form ‖ the document, whole
        assertEq(
            _slice(root, FILE_HEADER, document.length), document, "the read facet returns the bytes"
        );
        Res memory res = _status(_url(name), 200);
        assertEq(res.body, document, "the gateway serves the bytes");
        _headerEq(res, "x-efs-record", vm.toString(root));
        _headerEq(res, "Content-Length", vm.toString(document.length));
    }

    /// A one-chunk file `name` (`files-content/1` carrier 0 over a `files-bytes/1` chunk) holding `payload`.
    function _assertChunk(string memory name, bytes memory payload) internal {
        assertEq(uint8(payload[0]), 0xEF, "the chunk starts with 0xEF");
        bytes memory chunk = EfsFiles.bytesBody(payload);
        _contentFile(
            name,
            chunk,
            EfsFiles.contentBody(
                Keys.record(t.bytes_, chunk), 0, payload.length, sha256(payload), ""
            )
        );
        assertEq(
            _slice(Keys.record(t.bytes_, chunk), CHUNK_HEADER, payload.length),
            payload,
            "the read facet returns the chunk"
        );
        assertEq(_status(_url(name), 200).body, payload, "the gateway serves the chunk");
    }

    // ---- 1. inline revisions ------------------------------------------------------------------------------------

    function test_an_inline_revision_starting_with_ef_reads_back() public {
        // the EIP-7702 designator prefix, three bytes in the first word
        _assertInline("short.bin", hex"ef0100aabbccdd");
        // a lone 0xEF
        _assertInline("one.bin", hex"ef");
    }

    function test_an_inline_revision_of_forty_ef_bytes_spans_two_words() public {
        // 64 header bytes + 40 document bytes: the document straddles the word boundary at byte 96
        _assertInline("forty.bin", _repeat(0xEF, 40));
    }

    // ---- 2. chunks ----------------------------------------------------------------------------------------------

    function test_a_chunk_starting_with_ef_is_stored_and_served() public {
        _assertChunk("chunk-ef01.bin", hex"ef0100deadbeef");
        _assertChunk("chunk-ef-only.bin", _repeat(0xEF, 100));
        _assertChunk("chunk-ef-word.bin", _repeat(0xEF, 32));
        // a full-size chunk made only of 0xEF
        _assertChunk("chunk-ef-full.bin", _repeat(0xEF, CHUNK));
    }

    // ---- 3. spans -----------------------------------------------------------------------------------------------

    function test_a_span_file_whose_every_chunk_starts_with_ef_reads_back_whole() public {
        uint256 size = 64;
        uint256 n = 5; // an odd tree: span(span(span(c0,c1),span(c2,c3)), c4)
        bytes memory payload = new bytes(size * n - 17); // the last chunk is short
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = bytes1(uint8(i + 1)); // a pattern that is not 0xEF-heavy elsewhere
        }
        for (uint256 c; c < n; ++c) {
            payload[c * size] = 0xEF; // EVERY chunk begins with 0xEF
        }
        payload[1] = 0x01;
        payload[2] = 0x00; // the first chunk begins with the 7702 designator prefix
        for (uint256 c; c < n; ++c) {
            assertEq(uint8(payload[c * size]), 0xEF);
        }
        _store(address(this), rootDir, "span-ef.bin", payload, size);
        (bytes memory all, uint256 responses) = _fetchAll(_url("span-ef.bin"));
        assertEq(responses, n, "one response per chunk, joined by web3-next-chunk");
        assertEq(all, payload, "the whole file reads back");
    }

    // ---- 4. descriptor blobs ------------------------------------------------------------------------------------

    /// @dev `DescriptorStore` is the one write that stores data as CODE. Its runtime is `0x00 ‖ descriptor ‖
    ///      declarationSig`: the first byte is a STOP, never 0xEF, whatever the descriptor and signature contain, so
    ///      EIP-3541 cannot refuse a blob and a blob can never run.
    function test_a_descriptor_blob_begins_with_a_stop_byte() public view {
        for (uint8 i = T_ROOT; i <= T_SPAN; ++i) {
            address blob = r.registry.typeInfo(typeIds[i]).descriptorBlob;
            assertGt(blob.code.length, 1, "a blob exists");
            bytes memory first = new bytes(1);
            assembly ("memory-safe") {
                extcodecopy(blob, add(first, 32), 0, 1)
            }
            assertEq(uint8(first[0]), 0x00, "the runtime starts with STOP");
            assertTrue(first[0] != 0xEF, "never 0xEF");
            // and the bytes after the STOP are the registry's descriptor
            assertEq(
                bytes.concat(hex"00", r.registry.descriptorBytes(typeIds[i])),
                _prefix(blob, 1 + r.registry.descriptorBytes(typeIds[i]).length),
                "the descriptor follows the STOP"
            );
        }
    }

    function _prefix(address blob, uint256 n) internal view returns (bytes memory out) {
        out = new bytes(n);
        assembly ("memory-safe") {
            extcodecopy(blob, add(out, 32), 0, n)
        }
    }
}
