// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Web3GatewayHarness} from "../harness/doubles/Web3GatewayHarness.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action} from "../../src/interfaces/Actions.sol";

/// @notice The gateway's home form (`/0x<40 hex>/…`, docs/LARGE-FILES.md "`web3://`"): names resolve from an
///         address's place; the default lens is the address's own principal; another author's entry is served only
///         when the lens names that author; a missing name is 404, a malformed address 400; the home directory is
///         named by `x-efs-home`, never `x-efs-record`.
contract EfsWeb3GatewayHomeTest is Web3GatewayHarness {
    address internal owner = makeAddr("gw-home/owner");
    address internal stranger = makeAddr("gw-home/stranger");
    string internal H; // the owner's home path
    bytes32 internal home;

    function setUp() public {
        _setUpGateway();
        home = bytes32(uint256(uint160(owner)));
        H = string.concat("/", vm.toString(owner));
        bytes32 docsAtHome = _folder2(owner, home, "docs");
        _file(owner, docsAtHome, "a.txt", "owner's a", true);
        _file(owner, home, "readme.txt", "owner's readme", true);
        _file(stranger, home, "spam.txt", "stranger's spam", true);
    }

    /// A folder made by `who` under `parent`.
    function _folder2(address who, bytes32 parent, string memory name)
        internal
        returns (bytes32 dir)
    {
        (Action[] memory a, bytes[] memory b, bytes32 d) = EfsFiles.createFolder(
            t, Keys.principal(who), parent, keccak256(bytes(name)), bytes(name), true
        );
        _execAs(who, a, b);
        return d;
    }

    function test_the_owners_file_is_served_at_the_home_path() public view {
        Res memory res = _status(string.concat(H, "/docs/a.txt"), 200);
        assertEq(res.body, "owner's a");
        assertEq(_status(string.concat(H, "/readme.txt"), 200).body, "owner's readme");
        // the address in any case
        string memory upper = string.concat("/0x", _upper(_cutStr(vm.toString(owner), 2)));
        assertEq(_status(string.concat(upper, "/readme.txt"), 200).body, "owner's readme");
    }

    function test_another_authors_entry_needs_the_lens() public view {
        _status(string.concat(H, "/spam.txt"), 404);
        string memory s = _hex64(Keys.principal(stranger));
        assertEq(_status(string.concat(H, "/spam.txt?lens=", s), 200).body, "stranger's spam");
        // the lens parameter replaces the default: the owner's own entries need the owner in it
        _status(string.concat(H, "/readme.txt?lens=", s), 404);
        string memory o = _hex64(Keys.principal(owner));
        assertEq(
            _status(string.concat(H, "/readme.txt?lens=", s, ",", o), 200).body, "owner's readme"
        );
    }

    function test_missing_names_are_404_and_malformed_addresses_400() public view {
        _status(string.concat(H, "/nope.txt"), 404);
        _status(string.concat(H, "/docs/nope.txt"), 404);
        assertEq(_status("/0x1234/readme.txt", 400).body, "malformed id");
        assertEq(
            _status("/0xg000000000000000000000000000000000000000/readme.txt", 400).body,
            "malformed id"
        );
        assertEq(
            _status(string.concat("/", vm.toString(home), "/readme.txt"), 400).body, "malformed id"
        ); // 64
        // `~home` is gone: an unknown system path
        assertEq(
            _status(string.concat("/~home", H, "/readme.txt"), 400).body, "unknown system path"
        );
        // 40 or 64 hex digits without `0x` are words: a topic path, not served
        _status("/ab00000000000000000000000000000000000000/readme.txt", 501);
        _status(string.concat("/", _hex64(home), "/readme.txt"), 501);
    }

    function test_the_home_directory_is_named_as_an_address() public view {
        Res memory res = _status(string.concat(H, "/"), 200);
        (bool found,) = _header(res, "x-efs-record");
        assertFalse(found, "a home is not a record");
        _headerEq(res, "x-efs-home", _lower(vm.toString(owner)));
        // a folder under a home is a record
        res = _status(string.concat(H, "/docs"), 200);
        (found,) = _header(res, "x-efs-record");
        assertTrue(found);
    }

    // ---- small string helpers -------------------------------------------------------------------------------

    function _cutStr(string memory s, uint256 from) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        return string(_cut(b, from, b.length));
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "f") b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= "A" && b[i] <= "F") b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}
