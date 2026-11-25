// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {EfsWeb3Content, E_WEB3_STATUS} from "../../src/periphery/EfsWeb3Content.sol";
import {KeyValue} from "../../src/interfaces/IWeb3Gateway.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice The two link forms the gateway serves besides paths (docs/LARGE-FILES.md "`web3://`"; the SDK's link
///         grammar `~efs/o/<id>` and `~efs/v/<record>`): a FILE by its object link `/~efs/o/<file subject id>`,
///         its current HEAD under the lens (default: the subject's creator, `?lens=` exactly the listed principals),
///         and a REVISION link `/~efs/v/<revision record id>`, exactly that revision with no lens whether or not it
///         is anyone's HEAD; large files through both (the span/chunk path and `web3-next-chunk`), the answers for
///         other objects (501), nothing (404) and malformed links (400); and direct calls to `EfsWeb3Content`.
contract EfsWeb3GatewayLinksTest is Web3GatewayHarness {
    bytes32 internal hello; // hello.txt's file subject (created by p)
    bytes32 internal notes;
    bytes32 internal notesRoot; // no longer anyone's HEAD
    bytes32 internal big;
    bytes32 internal bigRevision;

    function setUp() public {
        _setUpGateway();
        hello = r.hot.bodyWord(helloRoot, 0);
        notes = r.hot.bodyWord(notesChild, 1);
        notesRoot = r.hot.bodyWord(notesChild, 0);
        big = _entry(p, rootDir, "big.bin");
        bigRevision = _headOf(p, big);
    }

    function _o(bytes32 id, string memory rest) internal pure returns (string memory) {
        return string.concat("/~efs/o/", vm.toString(id), rest);
    }

    function _v(bytes32 id, string memory rest) internal pure returns (string memory) {
        return string.concat("/~efs/v/", vm.toString(id), rest);
    }

    /// The target `principal` binds at `name` in `folder`.
    function _entry(bytes32 principal, bytes32 folder, string memory name)
        internal
        view
        returns (bytes32 target)
    {
        (,,,,,, target,) = r.hot
            .head(
                Keys.binding(
                    principal, Keys.position(Purpose.FOLDER, folder, keccak256(bytes(name)))
                )
            );
    }

    /// `principal`'s HEAD revision of `file`.
    function _headOf(bytes32 principal, bytes32 file) internal view returns (bytes32 rev) {
        (,,,,,, rev,) = r.hot.head(Keys.binding(principal, Keys.position(Purpose.HEAD, file, 0)));
    }

    function _headRevision(bytes32 principal, bytes32 file) internal view returns (uint64 n) {
        (, n,,,,,,) = r.hot.head(Keys.binding(principal, Keys.position(Purpose.HEAD, file, 0)));
    }

    /// alice writes her own revision of p's hello.txt (a child of p's root) and binds her own HEAD to it.
    function _aliceEditsHello() internal returns (bytes32 child) {
        (Action[] memory a, bytes[] memory b, bytes32 c) =
            EfsFiles.edit(t, hello, helloRoot, "alice's hello", 0);
        _execAs(alice, a, b);
        return c;
    }

    // ---- a file by its object link ----------------------------------------------------------------------------

    function test_a_file_by_id_is_its_creators_head() public view {
        Res memory res = _status(_o(hello, ""), 200);
        assertEq(res.body, "hello, web3");
        _headerEq(res, "x-efs-record", vm.toString(helloRoot));
        _headerEq(res, "Content-Length", "11");
        // there is no name to take an extension from
        _headerEq(res, "Content-Type", "application/octet-stream");
        assertEq(_status(_o(hello, "/"), 200).body, "hello, web3", "a trailing slash is dropped");
        // an edited file serves its current revision
        res = _status(_o(notes, ""), 200);
        assertEq(res.body, "v2: edited");
        _headerEq(res, "x-efs-record", vm.toString(notesChild));
        // offsets work as on a path
        assertEq(_status(_o(hello, "?offset=7"), 200).body, "web3");
        _status(_o(hello, "?offset=11"), 416);
    }

    function test_the_default_lens_is_the_subjects_creator_not_the_folders() public view {
        // alice.txt sits in p's root but alice created it: its object link needs no lens
        bytes32 aliceFile = _entry(pa, rootDir, "alice.txt");
        assertEq(_status(_o(aliceFile, ""), 200).body, "alice's own");
        // and p's lens alone does not see it (p never bound a HEAD for it)
        assertEq(
            _status(_o(aliceFile, string.concat("?lens=", P)), 404).body, "not found: no revision"
        );
    }

    function test_the_lens_parameter_replaces_the_creator() public {
        bytes32 child = _aliceEditsHello();
        // the creator by default
        assertEq(_status(_o(hello, ""), 200).body, "hello, web3");
        // exactly the listed principals
        Res memory res = _status(_o(hello, string.concat("?lens=", A)), 200);
        assertEq(res.body, "alice's hello");
        _headerEq(res, "x-efs-record", vm.toString(child));
        assertEq(_status(_o(hello, string.concat("?lens=", A, ",", P)), 200).body, "alice's hello");
        assertEq(_status(_o(hello, string.concat("?lens=", P, ",", A)), 200).body, "hello, web3");
        assertEq(
            _status(_o(hello, string.concat("?lens=", vm.toString(alice))), 200).body,
            "alice's hello",
            "an account in address form"
        );
        // a lens naming nobody who has a HEAD
        bytes32 nobody = Keys.principal(makeAddr("nobody"));
        assertEq(
            _status(_o(hello, string.concat("?lens=", vm.toString(nobody))), 404).body,
            "not found: no revision"
        );
    }

    function test_a_file_whose_creator_released_their_head() public {
        _aliceEditsHello();
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        a[0] = EfsFiles.release(Purpose.HEAD, hello, 0, _headRevision(p, hello));
        _exec(a, b);
        // no revision under the creator's lens: the same answer as a named file with no HEAD
        assertEq(_status(_o(hello, ""), 404).body, "not found: no revision");
        assertEq(_status(R, 200).status, 200);
        assertEq(_status(string.concat(R, "/hello.txt"), 404).body, "not found: no revision");
        // a released HEAD falls through to the next principal
        assertEq(_status(_o(hello, string.concat("?lens=", P, ",", A)), 200).body, "alice's hello");
        // and the released revision itself is still served by its revision link
        assertEq(_status(_v(helloRoot, ""), 200).body, "hello, web3");
    }

    function test_a_masked_head_is_removed() public {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        a[0] = EfsFiles.unbind(Purpose.HEAD, hello, 0, _headRevision(p, hello));
        _exec(a, b);
        _aliceEditsHello();
        // a MASKED head stops the lens: alice's revision behind p is not served (the same answer as a masked HEAD
        // of a named file)
        assertEq(
            _status(_o(hello, string.concat("?lens=", P, ",", A)), 404).body,
            "not found: no revision"
        );
        assertEq(_status(_o(hello, ""), 404).body, "not found: no revision");
        assertEq(_status(string.concat(R, "/hello.txt"), 404).body, "not found: no revision");
        // alice first sees her own
        assertEq(_status(_o(hello, string.concat("?lens=", A, ",", P)), 200).body, "alice's hello");
    }

    function test_a_name_after_a_file_id_is_a_file_used_as_a_folder() public view {
        assertEq(_status(_o(hello, "/x"), 404).body, "not found: file used as a folder");
        assertEq(
            _status(_o(hello, string.concat("/x/y?lens=", A)), 404).body,
            "not found: file used as a folder"
        );
    }

    function test_a_large_file_by_id_follows_next_chunk() public view {
        Res memory first = _status(_o(big, ""), 200);
        assertEq(first.body.length, CHUNK);
        _headerEq(first, "Content-Length", "40000");
        _headerEq(first, "x-efs-record", vm.toString(bigRevision));
        _headerEq(first, "web3-next-chunk", _o(big, "?offset=8160"));
        (bytes memory all, uint256 responses) = _fetchAll(_o(big, ""));
        assertEq(responses, 5);
        assertEq(keccak256(all), keccak256(bigPayload));
        // the lens is kept in web3-next-chunk
        first = _status(_o(big, string.concat("?lens=", P)), 200);
        _headerEq(first, "web3-next-chunk", _o(big, string.concat("?offset=8160&lens=", P)));
        (all,) = _fetchAll(_o(big, string.concat("?offset=12345&lens=", P)));
        assertEq(keccak256(all), keccak256(_cut(bigPayload, 12_345, 40_000)));
        // the deep tree too
        bytes32 deep = _entry(p, rootDir, "deep tree.bin");
        (all, responses) = _fetchAll(_o(deep, ""));
        assertEq(responses, 79);
        assertEq(keccak256(all), keccak256(deepPayload));
    }

    function test_an_external_file_by_id_is_a_307() public view {
        bytes32 ext = _entry(p, rootDir, "ext.bin");
        Res memory res = _status(_o(ext, ""), 307);
        _headerEq(res, "Location", string(LOCATOR));
        _headerEq(res, "x-efs-media-type", string(EXT_MEDIA));
    }

    // ---- a revision link ----------------------------------------------------------------------------------------

    function test_a_revision_link_to_a_root_and_to_a_child() public view {
        Res memory res = _status(_v(helloRoot, ""), 200);
        assertEq(res.body, "hello, web3");
        assertEq(res.headers.length, 3, "Content-Type, x-efs-record, Content-Length");
        _headerEq(res, "x-efs-record", vm.toString(helloRoot));
        _headerEq(res, "Content-Type", "application/octet-stream");
        _headerEq(res, "Content-Length", "11");
        res = _status(_v(notesChild, ""), 200);
        assertEq(res.body, "v2: edited");
        _headerEq(res, "x-efs-record", vm.toString(notesChild));
        assertEq(_status(_v(helloRoot, "?offset=7"), 200).body, "web3");
        _status(_v(helloRoot, "?offset=11"), 416);
        // any hex case
        assertEq(
            _status(string.concat("/~efs/v/0x", vm.toUppercase(_hex64(helloRoot))), 200).body,
            "hello, web3"
        );
    }

    function test_a_revision_that_is_no_longer_anyones_head_still_serves() public view {
        // notes.txt's root was replaced by its child: no HEAD names it
        assertEq(_headOf(p, notes), notesChild);
        Res memory res = _status(_v(notesRoot, ""), 200);
        assertEq(res.body, "v1");
        _headerEq(res, "x-efs-record", vm.toString(notesRoot));
    }

    function test_a_revision_link_has_no_lens() public {
        bytes32 child = _aliceEditsHello();
        // a revision of another author's HEAD, with no lens naming her
        assertEq(_status(_v(child, ""), 200).body, "alice's hello");
        // `lens` is ignored, even a malformed one
        assertEq(_status(_v(helloRoot, string.concat("?lens=", A)), 200).body, "hello, web3");
        assertEq(_status(_v(helloRoot, "?lens=zz"), 200).body, "hello, web3");
    }

    function test_a_large_revision_link_follows_next_chunk_without_a_lens() public view {
        Res memory first = _status(_v(bigRevision, string.concat("?lens=", P)), 200);
        assertEq(first.body.length, CHUNK);
        _headerEq(first, "x-efs-sha256", vm.toString(sha256(bigPayload)));
        _headerEq(first, "web3-next-chunk", _v(bigRevision, "?offset=8160"));
        (bytes memory all, uint256 responses) = _fetchAll(_v(bigRevision, ""));
        assertEq(responses, 5);
        assertEq(keccak256(all), keccak256(bigPayload));
        Res memory last = _status(_v(bigRevision, "?offset=32640"), 200);
        assertEq(last.body.length, 40_000 - 4 * CHUNK);
        (bool has,) = _header(last, "web3-next-chunk");
        assertFalse(has);
        _status(_v(bigRevision, "?offset=40000"), 416);
    }

    function test_a_revision_link_takes_its_media_type_from_its_descriptor() public {
        bytes memory payload = "<p>typed</p>";
        bytes memory chunk = EfsFiles.bytesBody(payload);
        _contentFile(
            "typed.bin",
            chunk,
            EfsFiles.contentBody(
                Keys.record(t.bytes_, chunk), 0, payload.length, sha256(payload), "text/html"
            )
        );
        bytes32 rev = _headOf(p, _entry(p, rootDir, "typed.bin"));
        Res memory res = _status(_v(rev, ""), 200);
        assertEq(res.body, payload);
        _headerEq(res, "Content-Type", "text/html");
        _headerEq(res, "X-Content-Type-Options", "nosniff");
    }

    function test_a_revision_link_to_an_object_that_is_not_a_revision_is_501() public view {
        bytes32 name = Keys.recordFromHash(t.name, keccak256("hello.txt"));
        bytes32[6] memory ids = [rootDir, docs, name, bigRoot, extDescriptor, hello];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(_status(_v(ids[i], ""), 501).body, "object not served");
        }
    }

    function test_a_revision_link_to_nothing_is_404_and_malformed_links_are_400() public view {
        assertEq(_status(_v(keccak256("no such record"), ""), 404).body, "not found");
        assertEq(_status(_v(Keys.subject(p, keccak256("never")), ""), 404).body, "not found");
        assertEq(_status("/~efs/v/0x1234", 400).body, "malformed id");
        assertEq(_status("/~efs/v/anything", 400).body, "malformed id");
        assertEq(_status(string.concat("/~efs/v/", P), 400).body, "malformed id");
        assertEq(_status("/~efs/v", 400).body, "malformed revision link");
        assertEq(_status("/~efs/v/", 400).body, "malformed revision link");
        assertEq(_status(_v(helloRoot, "/x"), 400).body, "malformed revision link");
        assertEq(
            _status(_v(keccak256("no such record"), "/x?offset=3"), 400).body,
            "malformed revision link"
        );
    }

    // ---- the content server, called directly ------------------------------------------------------------------

    function test_direct_calls_serve_what_a_revision_link_serves() public view {
        (uint16 s, bytes memory body, KeyValue[] memory h, uint256 next) =
            content.serveRevision(helloRoot, 0, "", 0);
        assertEq(s, 200);
        assertEq(body, "hello, web3");
        assertEq(h.length, 3);
        assertEq(h[0].value, "application/octet-stream");
        assertEq(next, 0);
        // with the file it belongs to (the HEAD law holds) and a name for the extension
        (s, body, h,) = content.serveRevision(helloRoot, hello, "a.txt", 7);
        assertEq(body, "web3");
        assertEq(h[0].value, "text/plain; charset=utf-8");
        // a chunk names the next offset; the gateway turns it into web3-next-chunk
        (s, body,, next) = content.serveRevision(bigRevision, big, "", 0);
        assertEq(body.length, CHUNK);
        assertEq(next, CHUNK);
        (,,, next) = content.serveRevision(bigRevision, 0, "", 32_640);
        assertEq(next, 0, "the last chunk");
    }

    function test_direct_call_refusals_are_status_reverts() public {
        _expectStatus(500, "HEAD law: revision of other file");
        content.serveRevision(helloRoot, notes, "", 0);
        _expectStatus(500, "HEAD law: target not a revision");
        content.serveRevision(rootDir, hello, "", 0);
        _expectStatus(501, "object not served");
        content.serveRevision(rootDir, 0, "", 0);
        _expectStatus(404, "not found");
        content.serveRevision(keccak256("no such record"), 0, "", 0);
        _expectStatus(416, "offset out of range");
        content.serveRevision(helloRoot, 0, "", 11);
        vm.mockCall(
            address(r.ledger),
            abi.encodeWithSelector(ILedgerHot.layoutId.selector),
            abi.encode(keccak256("another layout"))
        );
        _expectStatus(503, "foreign ledger layout");
        content.serveRevision(helloRoot, 0, "", 0);
    }

    function test_a_changed_content_server_is_500() public {
        vm.etch(
            address(content),
            address(new EfsWeb3Content(address(r.ledger), address(reads), _ct())).code
        );
        assertEq(address(content).codehash, gw.CONTENT_CODEHASH(), "the same code: still served");
        assertEq(_status(_v(helloRoot, ""), 200).body, "hello, web3");
        vm.etch(address(content), hex"00");
        assertEq(_status(_v(helloRoot, ""), 500).body, "content server changed");
        assertEq(_status(_o(hello, ""), 500).body, "content server changed");
        // folders and listings never reach the content server
        _status(R, 200);
    }

    function _expectStatus(uint16 status, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_STATUS.selector, status, reason));
    }
}
