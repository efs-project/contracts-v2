// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action} from "../../src/interfaces/Actions.sol";

/// @notice `ILedgerHot.bodyWord` (design §5.3): word `index` of a record's stored body, one SLOAD. Whole 32-byte
///         words, the last one zero-padded; zero beyond the length and for a record that does not exist. Profile
///         rules and validators read only the hot interface, so this is how a Files validator reads the file word
///         of a revision record.
contract BodyWordTest is FilesRecipesBase {
    bytes32 internal file;
    bytes32 internal revision;
    bytes internal body;

    function setUp() public override {
        super.setUp();
        file = Keys.subject(p, keccak256("body-word/file"));
        // 64-byte header (file, form 0) + 37 document bytes = 101 bytes: words 0..3, the last holding 5 bytes
        body = bytes.concat(abi.encode(file, uint256(0)), "a document of thirty-seven bytes long");
        assertEq(body.length, 101);
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("body-word/file"));
        (a[1], b[1]) = _publish(T_ROOT, body);
        revision = _id(T_ROOT, body);
        _execAs(address(this), a, b);
    }

    function _word(bytes memory d, uint256 i) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(d, 32), mul(i, 32)))
        }
    }

    function test_word_zero_and_a_middle_word() public view {
        assertEq(r.hot.bodyWord(revision, 0), file, "word 0 is the file subject");
        assertEq(r.hot.bodyWord(revision, 1), bytes32(0), "form 0");
        assertEq(r.hot.bodyWord(revision, 2), _word(body, 2), "a middle word");
    }

    function test_the_last_word_is_zero_padded() public view {
        bytes32 last = r.hot.bodyWord(revision, 3);
        bytes memory tail = new bytes(32);
        for (uint256 i; i < 5; ++i) {
            tail[i] = body[96 + i];
        }
        assertEq(last, bytes32(tail));
        assertTrue(last != 0);
        assertEq(uint256(last) & ((uint256(1) << 216) - 1), 0, "bytes past the length are zero");
    }

    function test_beyond_the_length_and_an_unknown_record() public view {
        assertEq(r.hot.bodyWord(revision, 4), bytes32(0));
        assertEq(r.hot.bodyWord(revision, type(uint256).max), bytes32(0));
        assertEq(r.hot.bodyWord(keccak256("no such record"), 0), bytes32(0));
    }

    /// The call's gas (`vm.lastCallGas`, the ledger proxy's frame), next to `subjectCreatedAt`, a one-SLOAD hot
    /// read of the same shape: cold (the accounts and the slot untouched, as an acceptor's first read pays) and warm.
    function test_body_word_gas() public {
        vm.cool(address(r.ledger));
        vm.cool(address(r.k.implementation));
        r.hot.bodyWord(revision, 0);
        uint256 cold = vm.lastCallGas().gasTotalUsed;
        r.hot.bodyWord(revision, 0);
        uint256 warm = vm.lastCallGas().gasTotalUsed;
        vm.cool(address(r.ledger));
        vm.cool(address(r.k.implementation));
        r.hot.subjectCreatedAt(file);
        uint256 refCold = vm.lastCallGas().gasTotalUsed;
        r.hot.subjectCreatedAt(file);
        uint256 refWarm = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("bodyWord gas, cold", cold);
        emit log_named_uint("bodyWord gas, warm", warm);
        emit log_named_uint("subjectCreatedAt gas, cold", refCold);
        emit log_named_uint("subjectCreatedAt gas, warm", refWarm);
        assertLt(cold, refCold + 200, "one SLOAD, like subjectCreatedAt");
        assertLt(warm, refWarm + 200);
    }
}
