// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IAcceptor, AcceptContext, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {E_FILES_CONTEXT, E_FILES_REFUSED} from "../../src/profiles/FilesProfile.sol";
import {FilesLedgerStub} from "../harness/doubles/FilesDoubles.sol";

/// @notice Shared harness for the Files rule unit suites: a stub ledger the rules read, a context whose
///         `ledger` is that stub, and calls made AS the stub (`vm.prank`), which is how the kernel's ingress calls
///         an acceptor (the ledger proxy is `msg.sender` and `ctx.ledger == address(this)`).
abstract contract FilesUnitBase is Test {
    FilesLedgerStub internal stub;
    bytes32 internal constant SELF_TYPE = keccak256("test/files/self-type");
    uint64 internal constant ADMISSION = 100;

    function setUp() public virtual {
        stub = new FilesLedgerStub();
    }

    function _ctx() internal view returns (AcceptContext memory c) {
        c.typeId = SELF_TYPE;
        c.realmId = keccak256("test/realm");
        c.principalId = keccak256("test/principal");
        c.admission = ADMISSION;
        c.revision = 1;
        c.grade = 3;
        c.ledger = address(stub);
    }

    function _none() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _noHeaders() internal pure returns (RefHeader[] memory) {
        return new RefHeader[](0);
    }

    function _one(bytes32 ref) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = ref;
    }

    function _header(bytes32 typeId, uint32 length, bytes32 w0, bytes32 w1, bytes32 w2)
        internal
        pure
        returns (RefHeader[] memory h)
    {
        h = new RefHeader[](1);
        h[0] = RefHeader({
            typeId: typeId, firstAdmission: 7, length: length, word0: w0, word1: w1, word2: w2
        });
    }

    function _call(
        IAcceptor rule,
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(c.ledger);
        (ok, ret) =
            address(rule).staticcall(abi.encodeCall(IAcceptor.accept, (c, body, refs, headers)));
    }

    function _accepts(
        IAcceptor rule,
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers
    ) internal {
        (bool ok, bytes memory ret) = _call(rule, c, body, refs, headers);
        assertTrue(ok, "accepted");
        assertEq(ret, abi.encode(IAcceptor.accept.selector), "exactly the selector word");
    }

    function _refuses(
        IAcceptor rule,
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers,
        uint8 code
    ) internal {
        (bool ok, bytes memory ret) = _call(rule, c, body, refs, headers);
        assertFalse(ok, "refused");
        assertEq(ret, abi.encodeWithSelector(E_FILES_REFUSED.selector, code), "refusal code");
    }

    /// A call that would be accepted from `ctx.ledger` is refused from any other caller before any law runs
    /// (design §5.10: "supplied context alone is not authentication").
    function _contextIsAuthenticated(
        IAcceptor rule,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers
    ) internal {
        _contextIsAuthenticated(rule, _ctx(), body, refs, headers);
    }

    function _contextIsAuthenticated(
        IAcceptor rule,
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers
    ) internal {
        _accepts(rule, c, body, refs, headers);
        (bool ok, bytes memory ret) =
            address(rule).staticcall(abi.encodeCall(IAcceptor.accept, (c, body, refs, headers)));
        assertFalse(ok, "a direct call with a forged context");
        assertEq(
            ret, abi.encodeWithSelector(E_FILES_CONTEXT.selector, address(stub), address(this))
        );
        vm.prank(address(0xBEEF));
        (ok, ret) =
            address(rule).staticcall(abi.encodeCall(IAcceptor.accept, (c, body, refs, headers)));
        assertFalse(ok, "another caller");
        assertEq(
            ret, abi.encodeWithSelector(E_FILES_CONTEXT.selector, address(stub), address(0xBEEF))
        );
    }

    /// Plain runtime (CodeScan 0), no reachable SSTORE (constructor state is never rewritten), size logged.
    function _codeChecks(address rule, string memory label) internal {
        bytes memory code = rule.code;
        assertEq(CodeScan.scan(code), 0, "plain runtime");
        assertFalse(_reachable(code, 0x55), "no SSTORE in the runtime");
        assertFalse(_reachable(code, 0x5d), "no TSTORE in the runtime");
        emit log_named_uint(string.concat(label, " runtime bytes"), code.length);
    }

    /// The reachability rule of `CodeScan` and `tools/checks.mjs`: push data skipped; a halting opcode ends
    /// reachability until the next JUMPDEST; the CBOR trailer named by the last two bytes is excluded.
    function _reachable(bytes memory code, uint8 op) internal pure returns (bool) {
        uint256 n = code.length;
        uint256 trailer = (uint256(uint8(code[n - 2])) << 8 | uint8(code[n - 1])) + 2;
        uint256 end = n - trailer;
        bool live = true;
        for (uint256 pc; pc < end; ++pc) {
            uint8 c = uint8(code[pc]);
            if (c >= 0x60 && c <= 0x7f) {
                pc += c - 0x5f;
                continue;
            }
            if (c == 0x5b) {
                live = true;
                continue;
            }
            if (!live) continue;
            if (c == op) return true;
            if (c == 0x00 || c == 0x56 || c == 0xf3 || c == 0xfd || c == 0xfe) live = false;
        }
        return false;
    }
}
