// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {EfsWeb3Gateway} from "../../src/periphery/EfsWeb3Gateway.sol";
import {EfsWeb3Content, E_WEB3_CONFIG, E_WEB3_STATUS} from "../../src/periphery/EfsWeb3Content.sol";
import {IWeb3Content} from "../../src/interfaces/IWeb3Content.sol";
import {KeyValue} from "../../src/interfaces/IWeb3Gateway.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {IReader} from "../../src/interfaces/Readers.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";

/// @notice `EfsWeb3Gateway`'s URL grammar and its infrastructure statuses (paths through the root folder by id): the
///         three principal forms of `lens` (64 hex, `0x` + 64 hex, a key account's `0x` + 40 hex) and the refused
///         ones, `lens` and `offset` syntax, the segment
///         and name bounds (400), trailing slashes, content types by extension, and the faults a URL cannot cause:
///         a foreign layout, a facet refusal, a reserved head state (503), a broken tree, a reverting dependency
///         (500); the constructor's configuration checks.
contract EfsWeb3GatewayUrlTest is Web3GatewayHarness {
    function setUp() public {
        _setUpGateway();
    }

    /// The root folder by id (its default lens: its creator p).
    function _p(string memory rest) internal view returns (string memory) {
        return string.concat(R, rest);
    }

    function _req(string[] memory resource, KeyValue[] memory params)
        internal
        view
        returns (uint16 status, string memory body)
    {
        (status, body,) = gw.request(resource, params);
    }

    // ---- principal forms (in `lens`) ------------------------------------------------------------------------

    function test_an_address_principal_equals_its_id_form() public view {
        Res memory byId = _status(_p(string.concat("/alice.txt?lens=", A)), 200);
        assertEq(byId.body, "alice's own");
        string memory checksummed = vm.toString(alice); // EIP-55 mixed case
        Res memory byAddress = _status(_p(string.concat("/alice.txt?lens=", checksummed)), 200);
        assertEq(
            keccak256(abi.encode(byAddress.body)), keccak256(abi.encode(byId.body)), "same body"
        );
        string memory lower = vm.toLowercase(checksummed);
        assertEq(_status(_p(string.concat("/alice.txt?lens=", lower)), 200).body, "alice's own");
        assertEq(
            _status(_p(string.concat("/alice.txt?lens=", vm.toUppercase(A))), 200).body,
            "alice's own",
            "hex is case-insensitive"
        );
        assertEq(
            _status(_p(string.concat("/alice.txt?lens=", vm.toString(pa))), 200).body, "alice's own"
        );
    }

    function test_a_contract_account_is_refused_in_address_form() public view {
        // address(this) is a contract principal of the Realm (Keys.principalFor): name it by its id
        Res memory res =
            _status(_p(string.concat("/hello.txt?lens=", vm.toString(address(this)))), 400);
        assertEq(res.body, "contract account: use its id");
        assertEq(_status(_p("/hello.txt"), 200).body, "hello, web3");
        assertEq(_status(_p(string.concat("/hello.txt?lens=", P)), 200).body, "hello, web3");
    }

    function test_an_eip7702_delegated_key_is_still_a_key_principal() public {
        string memory url = _p(string.concat("/alice.txt?lens=", vm.toString(alice)));
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertEq(_status(url, 200).body, "alice's own");
        vm.etch(alice, hex"00");
        _status(url, 400);
    }

    function test_malformed_principals_are_400() public view {
        string[8] memory bad = [
            "xyz",
            "0x",
            "0x1234",
            string(_cut(bytes(A), 0, 63)), // 63 digits
            string.concat(A, "0"), // 65 digits
            string.concat("0y", _hex64(bytes32(0))),
            string.concat(string(_cut(bytes(A), 0, 63)), "g"), // a non-hex digit
            string.concat("0x", string(_cut(bytes(A), 0, 39)))
        ];
        for (uint256 i; i < bad.length; ++i) {
            Res memory res = _status(_p(string.concat("/hello.txt?lens=", bad[i])), 400);
            assertTrue(
                keccak256(res.body) == keccak256("malformed principal")
                    || keccak256(res.body) == keccak256("malformed id"),
                string(res.body)
            );
        }
        _status(_p("/hello.txt?lens=zz"), 400);
        _status(_p(string.concat("/hello.txt?lens=", A, ",")), 400); // an empty item
        _status(_p(string.concat("/hello.txt?lens=", A, ",,", A)), 400);
    }

    function test_at_most_64_principals() public view {
        string memory lens = A;
        for (uint256 i; i < 63; ++i) {
            lens = string.concat(lens, ",", A);
        }
        _status(_p(string.concat("/alice.txt?lens=", lens)), 200); // 64
        Res memory res = _status(_p(string.concat("/alice.txt?lens=", lens, ",", A)), 400);
        assertEq(res.body, "too many principals");
    }

    // ---- parameters -------------------------------------------------------------------------------------------

    function test_offset_syntax() public view {
        string[6] memory bad =
            ["", "abc", "-1", "1e3", "184467440737095516160", "18446744073709551616"];
        for (uint256 i; i < bad.length; ++i) {
            Res memory res = _status(_p(string.concat("/hello.txt?offset=", bad[i])), 400);
            assertEq(res.body, "malformed offset");
        }
        assertEq(_status(_p("/hello.txt?offset=007"), 200).body, "web3", "leading zeros");
    }

    function test_unknown_parameters_are_ignored_and_the_last_value_wins() public view {
        assertEq(_status(_p("/hello.txt?x=1&format=json&"), 200).body, "hello, web3");
        assertEq(_status(_p("/hello.txt?offset=1&offset=7"), 200).body, "web3");
        assertEq(
            _status(_p(string.concat("/alice.txt?lens=", P, "&lens=", A)), 200).body, "alice's own"
        );
    }

    // ---- segments -----------------------------------------------------------------------------------------------

    function test_segment_and_name_bounds() public view {
        string memory deep = "";
        for (uint256 i; i < 32; ++i) {
            deep = string.concat(deep, "/d");
        }
        assertEq(_status(_p(deep), 404).body, "not found", "32 names are well formed");
        Res memory res = _status(_p(string.concat(deep, "/d")), 400);
        assertEq(res.body, "too many segments");
        bytes memory name = new bytes(255);
        for (uint256 i; i < 255; ++i) {
            name[i] = "n";
        }
        _status(_p(string.concat("/", string(name))), 404);
        res = _status(_p(string.concat("/", string(name), "n")), 400);
        assertEq(res.body, "name over 255 bytes");
        assertEq(_status(_p("//hello.txt"), 400).body, "empty segment");
        assertEq(_status(_p("/docs//guide.html"), 400).body, "empty segment");
    }

    function test_empty_paths_and_trailing_slashes() public view {
        assertEq(_status("/", 400).body, "empty segment"); // resource = []
        string[] memory one = new string[](1); // resource = [""]
        (uint16 status,) = _req(one, new KeyValue[](0));
        assertEq(status, 400);
        assertEq(_status(_p("/hello.txt/"), 200).body, "hello, web3", "a trailing slash is dropped");
        _headerEq(_status(_p("/docs/"), 200), "x-efs-listing", "complete");
        _headerEq(_status(_p(""), 200), "x-efs-record", vm.toString(rootDir));
    }

    function test_serve_is_the_inner_frame_and_reverts_its_refusals() public {
        (string[] memory resource, KeyValue[] memory params) = _parseUrl(_p("/nope.txt"));
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_STATUS.selector, uint16(404), "not found"));
        gw.serve(resource, params);
    }

    // ---- content types ----------------------------------------------------------------------------------------

    function test_content_type_by_extension() public {
        bytes32 types = _folder(rootDir, "types");
        string[2][21] memory cases = [
            ["a.txt", "text/plain; charset=utf-8"],
            ["a.TXT", "text/plain; charset=utf-8"],
            ["index.html", "text/html; charset=utf-8"],
            ["old.htm", "text/html; charset=utf-8"],
            ["s.css", "text/css; charset=utf-8"],
            ["app.js", "text/javascript; charset=utf-8"],
            ["d.json", "application/json"],
            ["logo.svg", "image/svg+xml"],
            ["i.png", "image/png"],
            ["p.JPG", "image/jpeg"],
            ["p.jpeg", "image/jpeg"],
            ["g.gif", "image/gif"],
            ["w.webp", "image/webp"],
            ["doc.pdf", "application/pdf"],
            ["m.wasm", "application/wasm"],
            ["noext", "application/octet-stream"],
            [".txt", "application/octet-stream"], // a leading dot is not an extension
            ["dot.x", "application/octet-stream"], // an unknown extension (`dot.` is no longer a name)
            ["a.tar.gz", "application/octet-stream"],
            ["readme.md", "application/octet-stream"],
            ["page.html5", "application/octet-stream"]
        ];
        for (uint256 i; i < cases.length; ++i) {
            _file(address(this), types, cases[i][0], "x", true);
        }
        for (uint256 i; i < cases.length; ++i) {
            Res memory res = _status(_p(string.concat("/types/", cases[i][0])), 200);
            _headerEq(res, "Content-Type", cases[i][1]);
        }
    }

    // ---- infrastructure statuses --------------------------------------------------------------------------------

    function test_a_foreign_layout_is_503() public {
        vm.mockCall(
            address(r.ledger),
            abi.encodeWithSelector(ILedgerHot.layoutId.selector),
            abi.encode(keccak256("another layout"))
        );
        assertEq(_status(_p("/hello.txt"), 503).body, "foreign ledger layout");
        _status(_p("/docs"), 503);
        _status(_p("/hello.txt?x=1&offset=abc"), 400); // a malformed URL is the client's, whatever the ledger
    }

    function test_a_facet_refusal_is_503() public {
        vm.mockCall(
            address(reads),
            abi.encodeWithSelector(ILedgerReads.bodySlice.selector),
            abi.encode(Status.UNSUPPORTED, bytes(""))
        );
        assertEq(_status(_p("/hello.txt"), 503).body, "read refused by the facet");
        vm.mockCall(
            address(reads),
            abi.encodeWithSelector(ILedgerReads.bodySlice.selector),
            abi.encode(Status.LIMIT_EXCEEDED, bytes(""))
        );
        _status(_p("/hello.txt"), 503);
        vm.mockCall(
            address(reads),
            abi.encodeWithSelector(ILedgerReads.bodySlice.selector),
            abi.encode(Status.ABSENT_PROVEN, bytes(""))
        );
        assertEq(_status(_p("/hello.txt"), 500).body, "missing record");
    }

    function test_a_reserved_head_state_is_503() public {
        bytes32 key =
            Keys.binding(p, Keys.position(Purpose.FOLDER, rootDir, keccak256("hello.txt")));
        vm.mockCall(
            address(r.ledger),
            abi.encodeCall(ILedgerHot.head, (key)),
            abi.encode(
                uint8(4),
                uint64(1),
                uint64(1),
                uint8(0),
                uint64(0),
                uint64(1),
                bytes32(0),
                uint16(0)
            )
        );
        assertEq(_status(_p("/hello.txt"), 503).body, "unsupported head state");
    }

    function test_a_broken_tree_is_500() public {
        // the span root claims to be 95 bytes long
        vm.mockCall(
            address(r.ledger),
            abi.encodeCall(ILedgerHot.recordHeader, (bigRoot)),
            abi.encode(typeIds[T_SPAN], uint64(1), uint32(95), uint64(1), uint8(0))
        );
        assertEq(_status(_p("/big.bin"), 500).body, "tree: missing node");
        vm.clearMockedCalls();
        // a child under the verified root is missing
        (, bytes32[] memory w) = reads.bodyWords(address(r.ledger), bigRoot, 0, 3);
        vm.mockCall(
            address(r.ledger),
            abi.encodeCall(ILedgerHot.recordHeader, (w[0])),
            abi.encode(bytes32(0), uint64(0), uint32(0), uint64(0), uint8(0))
        );
        assertEq(_status(_p("/big.bin"), 500).body, "tree: child length");
        assertEq(_status(_p("/big.bin?offset=39000"), 500).body, "tree: child length");
    }

    function test_a_reverting_dependency_is_500_never_a_revert() public {
        vm.mockCallRevert(
            address(reads), abi.encodeWithSelector(ILedgerReads.bodySlice.selector), "boom"
        );
        assertEq(_status(_p("/hello.txt"), 500).body, "internal fault");
        vm.mockCallRevert(
            address(reader), abi.encodeWithSelector(reader.listDirectory.selector), "boom"
        );
        assertEq(_status(_p("/docs"), 500).body, "listing failed");
    }

    function test_constructor_configuration() public {
        address c = address(content);
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(1)));
        new EfsWeb3Gateway(
            address(0), address(reads), address(views), address(0), c, rootDir, typeIds[T_DIRECTORY]
        );
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(1)));
        new EfsWeb3Gateway(
            address(r.ledger),
            address(0),
            address(views),
            address(0),
            c,
            rootDir,
            typeIds[T_DIRECTORY]
        );
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(1)));
        _gateway(address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(1)));
        new EfsWeb3Content(address(0), address(reads), _ct());
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(1)));
        new EfsWeb3Content(address(r.ledger), address(0), _ct());
        // a content server bound to another ledger
        vm.mockCall(c, abi.encodeWithSelector(IWeb3Content.ledger.selector), abi.encode(address(1)));
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(3)));
        _gateway(address(0), c);
        vm.clearMockedCalls();
        vm.mockCall(
            address(reader), abi.encodeWithSelector(IReader.ledger.selector), abi.encode(address(1))
        );
        vm.expectRevert(abi.encodeWithSelector(E_WEB3_CONFIG.selector, uint8(2)));
        _gateway(address(reader), c);
    }
}
