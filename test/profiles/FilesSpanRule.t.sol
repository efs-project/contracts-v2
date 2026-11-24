// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesSpanRule} from "../../src/profiles/FilesSpanRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `files-span/1` (docs/LARGE-FILES.md) against supplied reference headers: children of each kind (a
///         nonempty `files-bytes/1` chunk, a span of this very Type), the length law from the headers alone, the
///         64-bit bound, zero-payload chunks and third Types refused, the exact body and reference shape, the
///         context check and the constructor-state bytes Type.
contract FilesSpanRuleTest is FilesUnitBase {
    FilesSpanRule internal span;

    bytes32 internal constant BYTES_TYPE = keccak256("test/files/bytes-type");
    bytes32 internal constant L = keccak256("left child");
    bytes32 internal constant R = keccak256("right child");
    uint256 internal constant U64 = type(uint64).max;

    function setUp() public override {
        super.setUp();
        span = new FilesSpanRule(BYTES_TYPE);
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        r[0] = a;
        r[1] = b;
    }

    /// A chunk header: `payload` bytes after the sha256 word.
    function _chunk(uint256 payload) internal pure returns (RefHeader memory h) {
        h = RefHeader({
            typeId: BYTES_TYPE,
            firstAdmission: 7,
            length: uint32(32 + payload),
            word0: keccak256("digest"),
            word1: 0,
            word2: 0
        });
    }

    /// A span header (SELF: `ctx.typeId`) of `length` payload bytes.
    function _node(uint256 length) internal pure returns (RefHeader memory h) {
        h = RefHeader({
            typeId: SELF_TYPE,
            firstAdmission: 7,
            length: 96,
            word0: keccak256("ll"),
            word1: keccak256("lr"),
            word2: bytes32(length)
        });
    }

    function _pair(RefHeader memory a, RefHeader memory b)
        internal
        pure
        returns (RefHeader[] memory h)
    {
        h = new RefHeader[](2);
        h[0] = a;
        h[1] = b;
    }

    function _span(RefHeader memory a, RefHeader memory b, uint256 length, uint8 code) internal {
        bytes memory body = abi.encode(L, R, length);
        if (code == 0) _accepts(span, _ctx(), body, _two(L, R), _pair(a, b));
        else _refuses(span, _ctx(), body, _two(L, R), _pair(a, b), code);
    }

    // ---- accepted ----------------------------------------------------------------------------------------------

    function test_children_of_each_kind() public {
        _span(_chunk(8_160), _chunk(8_160), 16_320, 0); // two full chunks
        _span(_chunk(8_160), _chunk(1), 8_161, 0); // a short last chunk
        _span(_chunk(1), _chunk(1), 2, 0); // the smallest span
        _span(_node(16_320), _chunk(7_360), 23_680, 0); // span + chunk
        _span(_chunk(5), _node(9), 14, 0); // chunk + span (not canonical, still a valid tree)
        _span(_node(32_640), _node(7_360), 40_000, 0); // span + span
        // chunks larger than the canonical size (a Realm with a larger maxBody)
        _span(_chunk(100_000), _chunk(100_000), 200_000, 0);
    }

    function test_identical_children_are_one_record_twice() public {
        bytes memory body = abi.encode(L, L, uint256(16));
        _accepts(span, _ctx(), body, _two(L, L), _pair(_chunk(8), _chunk(8)));
    }

    function test_length_bound_is_inclusive() public {
        _span(_node(U64 - 1), _chunk(1), U64, 0);
        _span(_node(U64 - 8_160), _chunk(8_160), U64, 0);
    }

    // ---- refused -----------------------------------------------------------------------------------------------

    function test_length_must_be_the_sum() public {
        _span(_chunk(8_160), _chunk(8_160), 16_319, 6);
        _span(_chunk(8_160), _chunk(8_160), 16_321, 6);
        _span(_chunk(8_160), _chunk(8_160), 0, 6);
        _span(_node(10), _node(20), 31, 6);
        _span(_node(10), _chunk(20), 20, 6); // only one side counted
        // the header length of a span child is its body (96), never its payload
        _span(_node(10), _chunk(20), 96 - 32 + 20, 6);
    }

    function test_lengths_past_64_bits_refused() public {
        _span(_node(U64), _chunk(1), U64 + 1, 6);
        _span(_node(U64), _node(U64), 2 * U64, 6);
        // a forged span header above the bound cannot overflow the sum
        _span(_node(type(uint256).max), _chunk(1), 0, 6);
        _span(_chunk(1), _node(U64 + 1), U64 + 2, 6);
    }

    function test_a_zero_payload_chunk_is_never_a_child() public {
        _span(_chunk(0), _chunk(5), 5, 5); // the empty sentinel on the left
        _span(_chunk(5), _chunk(0), 5, 5);
        _span(_node(5), _chunk(0), 5, 5);
        RefHeader memory short = _chunk(0);
        short.length = 31; // never admitted under files-bytes/1, refused all the same
        _span(short, _chunk(5), 5, 5);
    }

    function test_a_third_type_is_never_a_child() public {
        RefHeader memory other = _chunk(5);
        other.typeId = keccak256("files-content/1 or anything else");
        _span(other, _chunk(5), 10, 4);
        _span(_chunk(5), other, 10, 4);
        other.typeId = 0;
        _span(other, _chunk(5), 10, 4);
        // a span-shaped header of another Type, whose word 2 would make the sum right
        RefHeader memory lookalike = _node(5);
        lookalike.typeId = keccak256("another span Type");
        _span(lookalike, _chunk(5), 10, 4);
        // headers with no admission
        RefHeader memory ghost = _chunk(5);
        ghost.firstAdmission = 0;
        _span(ghost, _chunk(5), 10, 4);
        ghost = _node(5);
        ghost.firstAdmission = 0;
        _span(_chunk(5), ghost, 10, 4);
    }

    function test_body_and_reference_shape() public {
        RefHeader[] memory h = _pair(_chunk(1), _chunk(1));
        bytes memory body = abi.encode(L, R, uint256(2));
        // exactly 96 bytes
        _refuses(span, _ctx(), abi.encode(L, R), _two(L, R), h, 2);
        _refuses(span, _ctx(), bytes.concat(body, hex"00"), _two(L, R), h, 2);
        _refuses(span, _ctx(), bytes.concat(body, abi.encode(uint256(0))), _two(L, R), h, 2);
        // the words are the references, in order
        _refuses(span, _ctx(), abi.encode(R, L, uint256(2)), _two(L, R), h, 3);
        _refuses(span, _ctx(), abi.encode(L, L, uint256(2)), _two(L, R), h, 3);
        _refuses(span, _ctx(), abi.encode(keccak256("x"), R, uint256(2)), _two(L, R), h, 3);
        // exactly two refs and two headers
        _refuses(span, _ctx(), body, _one(L), h, 1);
        _refuses(span, _ctx(), body, _two(L, R), _header(BYTES_TYPE, 33, 0, 0, 0), 1);
        bytes32[] memory three = new bytes32[](3);
        (three[0], three[1], three[2]) = (L, R, R);
        _refuses(span, _ctx(), body, three, h, 1);
        _refuses(span, _ctx(), body, _none(), _noHeaders(), 1);
    }

    function test_bytes_type_is_constructor_state() public {
        assertEq(span.bytesTypeId(), BYTES_TYPE);
        FilesSpanRule other = new FilesSpanRule(keccak256("another bytes Type"));
        assertEq(
            address(other).codehash, address(span).codehash, "one runtime for every bytes Type"
        );
        _refuses(
            other, _ctx(), abi.encode(L, R, uint256(2)), _two(L, R), _pair(_chunk(1), _chunk(1)), 4
        );
        // SELF is the context's Type: the same headers under another context Type are a third Type
        bytes memory body = abi.encode(L, R, uint256(15));
        RefHeader[] memory h = _pair(_node(10), _chunk(5));
        _accepts(span, _ctx(), body, _two(L, R), h);
        h[0].typeId = keccak256("not this Type");
        _refuses(span, _ctx(), body, _two(L, R), h, 4);
    }

    function test_span_context_is_authenticated() public {
        _contextIsAuthenticated(
            span, abi.encode(L, R, uint256(2)), _two(L, R), _pair(_chunk(1), _chunk(1))
        );
    }

    function test_span_rule_is_a_plain_runtime() public {
        _codeChecks(address(span), "FilesSpanRule");
        // a span costs no reads: measured from the ledger's seat
        bytes memory body = abi.encode(L, R, uint256(16_320));
        RefHeader[] memory h = _pair(_chunk(8_160), _chunk(8_160));
        vm.prank(address(stub));
        uint256 before = gasleft();
        span.accept(_ctx(), body, _two(L, R), h);
        emit log_named_uint("files-span/1 accept gas (call included)", before - gasleft());
    }
}
