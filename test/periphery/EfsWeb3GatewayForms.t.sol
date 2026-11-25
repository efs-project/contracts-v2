// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {Keys} from "../../src/lib/Keys.sol";

/// @notice The first path segment decides the kind of a gateway path (docs/LARGE-FILES.md "`web3://`"): `0x<40 hex>`
///         a home, `~efs/o/<folder id>` any folder by its record id with its creator as the default lens, any other
///         `~` segment refused, anything else a topic path that this gateway does not serve, so a folder name is never
///         served as a topic.
contract EfsWeb3GatewayFormsTest is Web3GatewayHarness {
    function setUp() public {
        _setUpGateway();
    }

    function _byId(bytes32 folder, string memory rest) internal pure returns (string memory) {
        return string.concat("/~efs/o/", vm.toString(folder), rest);
    }

    function test_the_root_by_id_serves_its_creators_files() public view {
        Res memory res = _status(_byId(rootDir, "/hello.txt"), 200);
        assertEq(res.body, "hello, web3");
        _headerEq(res, "x-efs-record", vm.toString(helloRoot));
        // the creator is the whole default lens: alice's own file needs her in it
        _status(_byId(rootDir, "/alice.txt"), 404);
        // big.bin's chunks keep the by-id path
        Res memory first = _status(_byId(rootDir, "/big.bin"), 200);
        _headerEq(first, "web3-next-chunk", _byId(rootDir, "/big.bin?offset=8160"));
        (bytes memory all,) = _fetchAll(_byId(rootDir, "/big.bin"));
        assertEq(keccak256(all), keccak256(bigPayload));
    }

    function test_a_bare_folder_by_id_is_its_directory_answer() public view {
        Res memory res = _status(_byId(rootDir, ""), 200);
        _headerEq(res, "x-efs-record", vm.toString(rootDir));
        _headerEq(res, "x-efs-listing", "complete");
        Res memory slash = _status(_byId(rootDir, "/"), 200);
        assertEq(keccak256(slash.body), keccak256(res.body), "a trailing slash is dropped");
        // the bare gateway (no page reader) answers a directory as it always did
        Res memory b = _getFrom(bare, _byId(rootDir, ""));
        assertEq(b.status, 200);
        assertEq(string(b.body), "directory");
    }

    function test_a_nested_folder_by_id() public view {
        assertEq(_status(_byId(docs, "/guide.html"), 200).body, "<h1>guide</h1>");
        assertEq(_status(_byId(docs, "/sub/leaf.txt"), 200).body, "a leaf");
        assertEq(_status(_byId(sub, "/leaf.txt"), 200).body, "a leaf");
        _headerEq(_status(_byId(sub, ""), 200), "x-efs-record", vm.toString(sub));
    }

    function test_the_lens_parameter_replaces_the_creator() public view {
        assertEq(
            _status(_byId(rootDir, string.concat("/alice.txt?lens=", A)), 200).body, "alice's own"
        );
        // exactly the listed principals: p's own file needs p in the lens
        _status(_byId(rootDir, string.concat("/hello.txt?lens=", A)), 404);
        assertEq(
            _status(_byId(rootDir, string.concat("/hello.txt?lens=", A, ",", P)), 200).body,
            "hello, web3"
        );
        assertEq(
            _status(_byId(docs, string.concat("/alice-doc.txt?lens=", A)), 200).body, "alice's doc"
        );
        // and it is kept in web3-next-chunk
        Res memory res = _status(_byId(rootDir, string.concat("/big.bin?lens=", P)), 200);
        _headerEq(
            res, "web3-next-chunk", _byId(rootDir, string.concat("/big.bin?offset=8160&lens=", P))
        );
    }

    function test_an_id_that_is_not_a_folder_is_404_never_an_empty_listing() public view {
        // a record of another Type (a file revision), no record at all, and a file subject
        assertEq(_status(_byId(helloRoot, ""), 404).body, "not found: not a folder");
        assertEq(
            _status(_byId(keccak256("no such record"), "/x"), 404).body, "not found: not a folder"
        );
        bytes32 file = Keys.subject(p, keccak256("web3/a file"));
        assertEq(_status(_byId(file, ""), 404).body, "not found: not a folder");
        // a folder id of the wrong shape
        assertEq(_status("/~efs/o/0x1234/hello.txt", 400).body, "malformed id");
        assertEq(_status(string.concat("/~efs/o/", P, "/hello.txt"), 400).body, "malformed id");
    }

    function test_unknown_system_paths_are_400() public view {
        string[6] memory paths = [
            string.concat("/~root/hello.txt?lens=", P),
            string.concat("/~home/", vm.toString(alice), "/alice.txt"),
            string.concat("/~efs/x/", vm.toString(rootDir), "/hello.txt"),
            "/~efs/o",
            "/~efs",
            "/~"
        ];
        for (uint256 i; i < paths.length; ++i) {
            assertEq(_status(paths[i], 400).body, "unknown system path");
        }
    }

    function test_a_plain_word_path_is_a_topic_and_not_served() public view {
        // hello.txt and docs/ are names in the root folder: never served at /<name>
        assertEq(_status("/hello.txt", 501).body, "topic paths are not served");
        assertEq(_status("/docs/guide.html", 501).body, "topic paths are not served");
        assertEq(_status(string.concat("/docs?lens=", P), 501).body, "topic paths are not served");
        _status("/cars/tesla", 501);
        // a principal id is not a first segment any more: 64 hex digits are a word
        _status(string.concat("/", P, "/hello.txt"), 501);
    }

    function test_malformed_address_shaped_segments_are_400() public view {
        assertEq(_status("/0x1234/hello.txt", 400).body, "malformed id");
        assertEq(
            _status("/0x00000000000000000000000000000000000000zz/hello.txt", 400).body,
            "malformed id"
        );
        assertEq(_status(string.concat("/0x", P, "/hello.txt"), 400).body, "malformed id");
        assertEq(_status(string.concat("/0X", _hexAddr(alice), "/x"), 404).body, "not found");
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    function _hexAddr(address a) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(a));
        return string(_cut(s, 2, s.length));
    }
}
