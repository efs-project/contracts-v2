// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {EfsWeb3Gateway} from "../../src/periphery/EfsWeb3Gateway.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice `EfsWeb3Gateway` end to end on the real Files Realm (kernel, registry, generation-1 index, facets, page
///         reader): inline and edited files, a 40 KB chunked file fetched by following `web3-next-chunk` and checked
///         against its sha256, mid-chunk offsets and 416, a 79-chunk depth-7 tree with an escaped name, external
///         locations (307), remote-only (404) and encrypted (as stored) descriptors, the Lens law over two
///         principals (fall-through, mask beats fall-through), listings (JSON, escaping, coverage header, no-pager
///         variant), the reader-side HEAD law (500), gas and the plain-runtime and size gates.
contract EfsWeb3GatewayTest is Web3GatewayHarness {
    function setUp() public {
        _setUpGateway();
    }

    function _u(string memory principal, string memory rest) internal pure returns (string memory) {
        return string.concat("/", principal, rest);
    }

    // ---- surface ------------------------------------------------------------------------------------------------

    function test_resolve_mode_and_reader_getters() public view {
        assertEq(gw.resolveMode(), bytes32("5219"));
        assertEq(gw.ledger(), address(r.ledger));
        assertEq(gw.layoutId(), r.hot.layoutId());
        assertEq(gw.facetVersion(), 1);
        assertEq(gw.READS(), address(reads));
        assertEq(gw.VIEWS(), address(views));
        assertEq(gw.PAGER(), address(reader));
        assertEq(bare.PAGER(), address(0));
        assertEq(gw.ROOT_DIRECTORY(), rootDir);
        assertEq(gw.SPAN_TYPE(), typeIds[T_SPAN]);
    }

    function test_runtime_is_plain_and_within_budget() public {
        bytes memory code = address(gw).code;
        assertEq(CodeScan.scan(code), 0, "no DELEGATECALL, CALLCODE, SELFDESTRUCT, CREATE, CREATE2");
        emit log_named_uint("EfsWeb3Gateway runtime bytes", code.length);
        assertLe(code.length, 19_660, "the 19,660 B runtime budget");
    }

    // ---- inline and edited files --------------------------------------------------------------------------------

    function test_inline_file_with_headers_and_offsets() public view {
        Res memory res = _status(_u(P, "/hello.txt"), 200);
        assertEq(res.body, "hello, web3");
        assertEq(res.headers.length, 3, "Content-Type, x-efs-record, Content-Length");
        _headerEq(res, "Content-Type", "text/plain; charset=utf-8");
        _headerEq(res, "Content-Length", "11");
        _headerEq(res, "x-efs-record", vm.toString(helloRoot));
        (bool has,) = _header(res, "x-efs-sha256");
        assertFalse(has, "inline bytes have no descriptor");
        res = _status(_u(P, "/hello.txt?offset=7"), 200);
        assertEq(res.body, "web3");
        res = _status(_u(P, "/hello.txt?offset=10"), 200);
        assertEq(res.body, "3");
        _status(_u(P, "/hello.txt?offset=11"), 416);
        _status(_u(P, "/hello.txt?offset=18446744073709551615"), 416);
    }

    function test_edited_file_serves_its_latest_revision() public view {
        Res memory res = _status(_u(P, "/notes.txt"), 200);
        assertEq(res.body, "v2: edited");
        _headerEq(res, "x-efs-record", vm.toString(notesChild));
        _headerEq(res, "Content-Length", "10");
    }

    function test_nested_folders_resolve_by_point_reads() public view {
        assertEq(_status(_u(P, "/docs/sub/leaf.txt"), 200).body, "a leaf");
        Res memory res = _status(_u(P, "/docs/guide.html"), 200);
        assertEq(res.body, "<h1>guide</h1>");
        _headerEq(res, "Content-Type", "text/html; charset=utf-8");
    }

    function test_empty_inline_file_is_served_and_any_offset_is_416() public {
        _file(address(this), rootDir, "empty.txt", "", true);
        Res memory res = _status(_u(P, "/empty.txt"), 200);
        assertEq(res.body.length, 0);
        _headerEq(res, "Content-Length", "0");
        _status(_u(P, "/empty.txt?offset=0"), 200);
        _status(_u(P, "/empty.txt?offset=1"), 416);
    }

    // ---- chunked files ------------------------------------------------------------------------------------------

    function test_chunked_file_is_fetched_by_following_next_chunk() public view {
        Res memory first = _status(_u(P, "/big.bin"), 200);
        assertEq(first.body.length, CHUNK, "one chunk per response");
        _headerEq(first, "Content-Length", "40000");
        _headerEq(first, "Content-Type", "application/octet-stream");
        _headerEq(first, "x-efs-sha256", vm.toString(sha256(bigPayload)));
        _headerEq(first, "web3-next-chunk", _u(P, "/big.bin?offset=8160"));
        (bool has,) = _header(first, "x-efs-cipher");
        assertFalse(has, "plaintext");
        (bytes memory all, uint256 responses) = _fetchAll(_u(P, "/big.bin"));
        assertEq(responses, 5, "five chunks");
        assertEq(keccak256(all), keccak256(bigPayload), "the concatenated bodies are the file");
        assertEq(sha256(all), sha256(bigPayload), "and verify against the descriptor's sha256");
        Res memory last = _get(_u(P, "/big.bin?offset=32640"));
        assertEq(last.body.length, 40_000 - 4 * CHUNK);
        (has,) = _header(last, "web3-next-chunk");
        assertFalse(has, "the last chunk has no next");
    }

    function test_offset_inside_a_chunk_returns_that_chunks_tail() public view {
        uint256 from = 2 * CHUNK + 1000;
        Res memory res = _status(_u(P, string.concat("/big.bin?offset=", vm.toString(from))), 200);
        assertEq(res.body, _slice(bigPayload, from, 3 * CHUNK), "to the end of chunk 2");
        _headerEq(res, "web3-next-chunk", _u(P, "/big.bin?offset=24480"));
        res = _status(_u(P, "/big.bin?offset=39999"), 200);
        assertEq(res.body.length, 1);
        assertEq(res.body[0], bigPayload[39_999]);
        _status(_u(P, "/big.bin?offset=40000"), 416);
        _status(_u(P, "/big.bin?offset=40001"), 416);
        // following from a mid-chunk offset reassembles the tail of the file
        (bytes memory tail,) = _fetchAll(_u(P, "/big.bin?offset=12345"));
        assertEq(keccak256(tail), keccak256(_slice(bigPayload, 12_345, 40_000)));
    }

    function test_deep_tree_of_tiny_chunks_with_an_escaped_name() public view {
        Res memory first = _status(_u(P, "/deep%20tree.bin"), 200);
        assertEq(first.body, _slice(deepPayload, 0, 64));
        _headerEq(first, "web3-next-chunk", _u(P, "/deep%20tree.bin?offset=64"));
        _headerEq(first, "Content-Length", "5000");
        (bytes memory all, uint256 responses) = _fetchAll(_u(P, "/deep%20tree.bin"));
        assertEq(responses, 79, "78 full chunks and an 8-byte tail");
        assertEq(keccak256(all), keccak256(deepPayload));
        Res memory res = _status(_u(P, "/deep%20tree.bin?offset=4999"), 200);
        assertEq(res.body.length, 1, "the last byte of the 8-byte tail");
        assertEq(res.body[0], deepPayload[4999]);
    }

    function test_a_single_chunk_file_is_carrier_0_without_next_chunk() public {
        bytes memory payload = _payload(3_000, "one chunk");
        _store(address(this), rootDir, "one.json", payload, CHUNK);
        Res memory res = _status(_u(P, "/one.json"), 200);
        assertEq(res.body, payload);
        _headerEq(res, "Content-Type", "application/json");
        (bool has,) = _header(res, "web3-next-chunk");
        assertFalse(has);
        assertEq(_status(_u(P, "/one.json?offset=2990"), 200).body, _slice(payload, 2990, 3000));
    }

    // ---- other descriptors ----------------------------------------------------------------------------------

    function test_external_location_is_a_307_with_location() public view {
        Res memory res = _status(_u(P, "/ext.bin"), 307);
        assertEq(res.body.length, 0, "an empty body");
        _headerEq(res, "Location", string(LOCATOR));
        _headerEq(res, "x-efs-sha256", vm.toString(sha256("remote bytes")));
        (bool has,) = _header(res, "Content-Length");
        assertFalse(has, "a redirect carries no body length");
        (has,) = _header(res, "x-efs-record");
        assertTrue(has);
    }

    function test_external_location_carries_its_declared_media_type() public {
        Res memory res = _status(_u(P, "/ext.bin"), 307);
        _headerEq(res, "x-efs-media-type", string(EXT_MEDIA));
        (bool has,) = _header(res, "X-Content-Type-Options");
        assertFalse(has, "nosniff is for a served body, not a redirect");
        // a location with no media type: no header, the redirect is otherwise the same
        _external("plain.bin", "");
        res = _status(_u(P, "/plain.bin"), 307);
        _headerEq(res, "Location", string(LOCATOR));
        (has,) = _header(res, "x-efs-media-type");
        assertFalse(has, "no declared media type");
        // parameters are carried byte for byte
        _external("clip.mp4", 'video/mp4; codecs="avc1.42E01E, mp4a.40.2"');
        _headerEq(
            _status(_u(P, "/clip.mp4"), 307),
            "x-efs-media-type",
            'video/mp4; codecs="avc1.42E01E, mp4a.40.2"'
        );
    }

    /// A one-chunk file (carrier 0) named `name` holding `payload`, with media type `media`.
    function _declared(string memory name, bytes memory payload, bytes memory media) internal {
        bytes memory chunk = EfsFiles.bytesBody(payload);
        _contentFile(
            name,
            chunk,
            EfsFiles.contentBody(
                Keys.record(t.bytes_, chunk), 0, payload.length, sha256(payload), media
            )
        );
    }

    function test_a_declared_media_type_is_served_with_nosniff() public {
        _declared("page.bin", "<p>hi</p>", "text/html; charset=utf-8");
        Res memory res = _status(_u(P, "/page.bin"), 200);
        assertEq(res.body, "<p>hi</p>");
        _headerEq(res, "Content-Type", "text/html; charset=utf-8");
        _headerEq(res, "X-Content-Type-Options", "nosniff");
        _headerEq(res, "Content-Length", "9");
        assertEq(res.headers[0].key, "Content-Type", "Content-Type stays the first header");
        // the declaration beats the extension: an author's text/plain under an .html name stays text
        _declared("note.html", "<script>x</script>", "text/plain; charset=utf-8");
        res = _status(_u(P, "/note.html"), 200);
        _headerEq(res, "Content-Type", "text/plain; charset=utf-8");
        _headerEq(res, "X-Content-Type-Options", "nosniff");
        // a declared type on a span tree is sent with every chunk
        (Action[] memory a, bytes[] memory b, bytes32 descriptor) = EfsFiles.storeContent(
            t, _payload(20_000, "typed"), CHUNK, "application/x.efs-test+octet"
        );
        (Action[] memory fa, bytes[] memory fb,,) = EfsFiles.createFileRef(
            t, p, rootDir, keccak256("typed.bin"), "typed.bin", descriptor, true
        );
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        _publishAll(address(this), a, b);
        res = _status(_u(P, "/typed.bin?offset=8160"), 200);
        _headerEq(res, "Content-Type", "application/x.efs-test+octet");
        _headerEq(res, "X-Content-Type-Options", "nosniff");
    }

    function test_an_empty_media_type_falls_back_to_the_extension_without_nosniff() public {
        _declared("plain.txt", "just text", "");
        Res memory res = _status(_u(P, "/plain.txt"), 200);
        _headerEq(res, "Content-Type", "text/plain; charset=utf-8");
        (bool has,) = _header(res, "X-Content-Type-Options");
        assertFalse(has, "the extension path is unchanged");
        res = _status(_u(P, "/big.bin"), 200);
        _headerEq(res, "Content-Type", "application/octet-stream");
        (has,) = _header(res, "X-Content-Type-Options");
        assertFalse(has);
        // inline (form 0) bytes have no descriptor and so no media type
        res = _status(_u(P, "/hello.txt"), 200);
        (has,) = _header(res, "X-Content-Type-Options");
        assertFalse(has);
    }

    function test_a_descriptor_whose_length_disagrees_with_its_layout_is_500() public {
        // The rules make such a record impossible on a real Realm, so a gateway is built with the two
        // descriptor Types swapped: a files-content/1 record is read as a location, and the reverse.
        EfsWeb3Gateway.Types memory g = _gt();
        (g.content, g.external_) = (g.external_, g.content);
        EfsWeb3Gateway swapped = new EfsWeb3Gateway(
            address(r.ledger), address(reads), address(views), address(reader), rootDir, g
        );
        _declared("typed.txt", "typed", "text/plain");
        // a content body of 362 bytes: word 6 (the media length, 10) and word 7 (the cipher, 0) as the locator
        // and media lengths: 256 + 10 + 0 != 362
        Res memory res = _getFrom(swapped, _u(P, "/typed.txt"));
        assertEq(res.status, 500);
        assertEq(res.body, "malformed location");
        // an external body of 256 + 48 + 24 bytes read as content: shorter than the eleven words
        res = _getFrom(swapped, _u(P, "/ext.bin"));
        assertEq(res.status, 500);
        assertEq(res.body, "revision names no descriptor");
        // a location of 256 + 48 + 54 bytes read as content: word 6 (48, the locator length) is not 358 - 352
        _external("long.bin", "application/vnd.efs.test-of-a-long-declared-media-type");
        res = _getFrom(swapped, _u(P, "/long.bin"));
        assertEq(res.status, 500);
        assertEq(res.body, "revision names no descriptor");
    }

    function test_remote_only_content_is_404() public {
        bytes memory sentinel = EfsFiles.bytesBody("");
        _contentFile(
            "remote.bin",
            sentinel,
            EfsFiles.contentBody(Keys.record(t.bytes_, sentinel), 1, 10, sha256("0123456789"), "")
        );
        Res memory res = _status(_u(P, "/remote.bin"), 404);
        assertEq(res.body, "not found: remote-only content");
    }

    function test_encrypted_content_is_served_as_stored() public {
        bytes memory ciphertext = _payload(48, "ciphertext");
        bytes memory chunk = EfsFiles.bytesBody(ciphertext);
        EfsFiles.Content memory c = EfsFiles.Content({
            bytesRef: Keys.record(t.bytes_, chunk),
            version: 1,
            carrier: 0,
            hashAlg: 1,
            length: 48,
            sha256Digest: sha256(ciphertext),
            media: "",
            cipher: 1,
            nonce12: bytes32(bytes12(0x0102030405060708090a0b0c)),
            plaintextLength: 32,
            plaintextSha256OrZero: 0
        });
        _contentFile("secret.bin", chunk, EfsFiles.contentBody(c));
        Res memory res = _status(_u(P, "/secret.bin"), 200);
        assertEq(res.body, ciphertext, "the ciphertext, as stored");
        _headerEq(res, "x-efs-cipher", "1");
        _headerEq(res, "x-efs-sha256", vm.toString(sha256(ciphertext)));
        _headerEq(res, "Content-Length", "48");
    }

    // ---- the Lens law -----------------------------------------------------------------------------------------

    function test_lens_falls_through_to_the_second_principal() public view {
        _status(_u(P, "/alice.txt"), 404);
        assertEq(_status(_u(P, "/alice.txt?lens=", A), 200).body, "alice's own");
        assertEq(
            _status(_u(P, string.concat("/docs/alice-doc.txt?lens=", A)), 200).body, "alice's doc"
        );
        // the path principal is first: p's own entries win over alice's
        assertEq(_status(_u(A, string.concat("/hello.txt?lens=", P)), 200).body, "hello, web3");
        _status(_u(A, "/hello.txt"), 404);
        // the lens is preserved in web3-next-chunk
        Res memory res = _status(_u(P, string.concat("/big.bin?lens=", A)), 200);
        _headerEq(res, "web3-next-chunk", _u(P, string.concat("/big.bin?offset=8160&lens=", A)));
        (bytes memory all,) = _fetchAll(_u(P, string.concat("/big.bin?lens=", A, ",", P)));
        assertEq(keccak256(all), keccak256(bigPayload));
    }

    function test_a_mask_by_an_earlier_principal_wins() public view {
        Res memory res = _status(_u(P, "/gone.txt"), 404);
        assertEq(res.body, "not found: removed");
        _status(_u(P, string.concat("/gone.txt?lens=", A)), 404);
        assertEq(_status(_u(A, "/gone.txt"), 200).body, "alice's gone");
        assertEq(_status(_u(A, string.concat("/gone.txt?lens=", P)), 200).body, "alice's gone");
        // alice removed shared.txt, p bound it afterwards: alice first hides p's entry
        _status(_u(A, string.concat("/shared.txt?lens=", P)), 404);
        assertEq(_status(_u(P, string.concat("/shared.txt?lens=", A)), 200).body, "p's shared");
    }

    function test_a_release_falls_through_again() public {
        (Action[] memory a, bytes[] memory b) = EfsFiles.releaseEntry(rootDir, "shared.txt", 2);
        _execAs(alice, a, b);
        assertEq(_status(_u(A, string.concat("/shared.txt?lens=", P)), 200).body, "p's shared");
    }

    function test_unknown_names_and_files_used_as_folders_are_404() public view {
        assertEq(_status(_u(P, "/nope.txt"), 404).body, "not found");
        _status(_u(P, "/docs/nope"), 404);
        _status(_u(P, "/docs/sub/leaf.txt/more"), 404);
        Res memory res = _status(_u(P, "/hello.txt/x"), 404);
        assertEq(res.body, "not found: a file is not a folder");
        _status(_u(P, "/Hello.txt"), 404); // byte-exact, case-sensitive
    }

    // ---- directories --------------------------------------------------------------------------------------------

    function test_directory_listing_json_and_coverage_header() public {
        Res memory res = _status(_u(P, "/docs"), 200);
        assertEq(
            res.body,
            '{"entries":[{"name":"sub","kind":"directory"},{"name":"guide.html","kind":"file"}],"complete":true}'
        );
        _headerEq(res, "Content-Type", "application/json");
        _headerEq(res, "x-efs-listing", "complete");
        _headerEq(res, "x-efs-record", vm.toString(docs));
        res = _status(_u(P, string.concat("/docs/?lens=", A)), 200);
        assertEq(
            res.body,
            '{"entries":[{"name":"sub","kind":"directory"},{"name":"guide.html","kind":"file"},{"name":"alice-doc.txt","kind":"file"}],"complete":true}'
        );
        // the root: p's live entries (gone.txt is masked, so not listed)
        res = _status(_u(P, "/"), 200);
        assertEq(
            res.body,
            '{"entries":[{"name":"hello.txt","kind":"file"},{"name":"notes.txt","kind":"file"},{"name":"big.bin","kind":"file"},{"name":"deep tree.bin","kind":"file"},{"name":"ext.bin","kind":"file"},{"name":"docs","kind":"directory"},{"name":"shared.txt","kind":"file"}],"complete":true}'
        );
        assertEq(_status(_u(P, ""), 200).body, res.body, "/<principal> is the root too");
        // names are JSON-escaped
        _file(address(this), sub, 'say "hi".txt', "hi", true);
        res = _status(_u(P, "/docs/sub"), 200);
        assertEq(
            res.body,
            '{"entries":[{"name":"leaf.txt","kind":"file"},{"name":"say \\"hi\\".txt","kind":"file"}],"complete":true}'
        );
        assertEq(_status(_u(P, "/docs/sub/say%20%22hi%22.txt"), 200).body, "hi");
    }

    function test_directory_without_a_page_reader() public view {
        Res memory res = _getFrom(bare, _u(P, "/docs"));
        assertEq(res.status, 200);
        assertEq(res.body, "directory");
        _headerEq(res, "Content-Type", "text/plain; charset=utf-8");
        _headerEq(res, "x-efs-record", vm.toString(docs));
        assertEq(_getFrom(bare, _u(P, "/hello.txt")).body, "hello, web3", "files need no pager");
    }

    function test_a_listing_past_the_row_limit_is_partial() public {
        bytes32 many = _folder(rootDir, "many");
        for (uint256 i; i < 65; ++i) {
            _file(address(this), many, string.concat("f", vm.toString(i)), "", true);
        }
        Res memory res = _status(_u(P, "/many"), 200);
        _headerEq(res, "x-efs-listing", "partial");
        assertEq(_count(res.body, '"kind":"file"'), 64, "one page of LISTING_LIMIT rows");
    }

    // ---- the reader-side HEAD law -------------------------------------------------------------------------------

    /// CREATE, PUBLISH name, BIND(HEAD → `headTarget`, or the file subject itself when 0) unless `!withHead`,
    /// BIND(FOLDER, root, name → file): the gen-1 validator judges FOLDER binds only, so any HEAD target lands.
    function _placeWithHead(string memory name, bytes32 headTarget, bool withHead) internal {
        bytes32 salt = keccak256(bytes(name));
        bytes32 file = EfsFiles.subjectId(p, salt);
        uint256 n = withHead ? 4 : 3;
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        a[0] = EfsFiles.create(salt);
        b[1] = bytes(name);
        a[1] = EfsFiles.publish(t.name, b[1]);
        if (withHead) {
            a[2] = EfsFiles.bind(Purpose.HEAD, file, 0, headTarget == 0 ? file : headTarget, 0);
        }
        a[n - 1] = EfsFiles.bind(Purpose.FOLDER, rootDir, keccak256(bytes(name)), file, 0);
        _exec(a, b);
    }

    function test_head_law_violations_are_500() public {
        _placeWithHead("bad.txt", Keys.recordFromHash(t.name, keccak256("bad.txt")), true);
        _placeWithHead("wrong.txt", helloRoot, true);
        _placeWithHead("self.txt", 0, true);
        _placeWithHead("none.txt", 0, false);
        assertEq(_status(_u(P, "/bad.txt"), 500).body, "HEAD law: target is not a revision");
        assertEq(_status(_u(P, "/wrong.txt"), 500).body, "HEAD law: revision of another file");
        assertEq(_status(_u(P, "/self.txt"), 500).body, "HEAD law: target is not a record");
        assertEq(_status(_u(P, "/none.txt"), 404).body, "not found: no revision");
    }

    // ---- gas ----------------------------------------------------------------------------------------------------

    function test_gas_inline_and_chunk_reads_at_depth_3_and_7() public {
        (uint256 inlineGas, Res memory res) = _gasOf(_u(P, "/hello.txt"));
        assertEq(res.status, 200);
        (uint256 depth3, Res memory r3) = _gasOf(_u(P, "/big.bin"));
        assertEq(r3.body.length, CHUNK, "chunk 0 sits at depth 3");
        (uint256 depth1,) = _gasOf(_u(P, "/big.bin?offset=32640"));
        (uint256 depth7, Res memory r7) = _gasOf(_u(P, "/deep%20tree.bin"));
        assertEq(r7.body.length, 64, "chunk 0 sits at depth 7");
        (uint256 listing,) = _gasOf(_u(P, "/"));
        emit log_named_uint("web3 gas: inline file (11 B, one name)", inlineGas);
        emit log_named_uint("web3 gas: 8,160 B chunk at depth 3 (40 KB file)", depth3);
        emit log_named_uint("web3 gas: 7,840 B chunk at depth 1 (40 KB file)", depth1);
        emit log_named_uint("web3 gas: 64 B chunk at depth 7 (5,000 B file)", depth7);
        emit log_named_uint("web3 gas: root listing (7 rows)", listing);
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    function _u(string memory principal, string memory rest, string memory more)
        internal
        pure
        returns (string memory)
    {
        return string.concat("/", principal, rest, more);
    }

    function _slice(bytes memory s, uint256 from, uint256 to) internal pure returns (bytes memory) {
        return _cut(s, from, to);
    }

    function _count(bytes memory s, bytes memory needle) internal pure returns (uint256 n) {
        for (uint256 i; i + needle.length <= s.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length && hit; ++j) {
                hit = s[i + j] == needle[j];
            }
            if (hit) ++n;
        }
    }
}
