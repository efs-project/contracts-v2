// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {E_CODE_SHAPE} from "../../src/interfaces/Errors.sol";
import {CodePins} from "../../src/lib/CodePins.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";

/// External entry points, so a refusal reverts one frame below the test (`vm.expectRevert`) and the scan
/// is measured in a frame of its own.
contract CodeGate {
    function requireRealCode(address a) external view {
        CodePins.requireRealCode(a);
    }

    function requireCodehash(address a, bytes32 expected) external view {
        CodePins.requireCodehash(a, expected);
    }

    function realCodeAndHash(address a) external view returns (bytes32) {
        return CodePins.realCodeAndHash(a);
    }

    function isDesignator(address a) external view returns (bool) {
        return CodePins.isDesignator(a);
    }

    function requirePlainRuntime(address a) external view {
        CodeScan.requirePlainRuntime(a);
    }

    function scanGas(address a) external view returns (uint256 used) {
        uint256 before = gasleft();
        CodeScan.requirePlainRuntime(a);
        used = before - gasleft();
    }
}

/// Storage, arithmetic, hashing, `CALL` and `STATICCALL`: nothing the scan refuses.
contract PlainHelper {
    uint256 public total;

    function add(uint256 x) external returns (uint256) {
        total += x;
        return total;
    }

    function digest(bytes32 a, uint256 b) external pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }

    function peek(address t) external view returns (uint256) {
        return t.code.length + t.balance;
    }

    function ping(address t, bytes calldata data) external returns (bool ok) {
        (ok,) = t.call(data);
    }
}

contract DelegatingHelper {
    function forward(address t, bytes calldata data) external returns (bool ok) {
        (ok,) = t.delegatecall(data);
    }
}

contract Empty {}

contract CreatingHelper {
    function make() external returns (address) {
        return address(new Empty());
    }
}

contract Create2Helper {
    function make(bytes32 salt) external returns (address) {
        return address(new Empty{salt: salt}());
    }
}

/// Inline-size probes: the same external function with and without the library call.
contract ScanProbe {
    function check(address a) external view {
        CodeScan.requirePlainRuntime(a);
    }
}

contract PinProbe {
    function check(address a, bytes32 h) external view {
        CodePins.requireRealCode(a);
        CodePins.requireCodehash(a, h);
    }
}

contract BaselineProbe {
    event Seen(address a, bytes32 h);

    function check(address a, bytes32 h) external {
        emit Seen(a, h);
    }
}

/// @notice `CodePins` and `CodeScan` (design §2.2 S6/S16, §3.1 L6): every `E_CODE_SHAPE` reason, the
///         push-data and trailer laws, compiled helpers, real proxy shapes, and the scan's gas.
contract CodeScanTest is Test {
    /// The trailer solc 0.8.37 writes under `bytecode_hash = "none"`: a1 64 "solc" 43 00 08 25, L = 10.
    bytes internal constant TRAILER = hex"a164736f6c6343000825000a";
    bytes internal constant PROXY_HEAD = hex"363d3d373d3d3d363d73";
    bytes internal constant PROXY_TAIL = hex"5af43d82803e903d91602b57fd5bf3";
    address internal constant SLOT = address(0xC0DE);
    address internal constant CODELESS = address(0xBEEF);

    CodeGate internal gate;

    function setUp() public {
        gate = new CodeGate();
    }

    // ---- reason catalog ----------------------------------------------------------------------------

    function test_reasonCatalog() public pure {
        assertEq(CodePins.NO_CODE, 1);
        assertEq(CodePins.DESIGNATOR, 2);
        assertEq(CodePins.FORBIDDEN_OPCODE, 3);
        assertEq(CodePins.TRAILER_MALFORMED, 4);
        assertEq(CodePins.PROXY_SHAPE, 5);
        assertEq(CodePins.CODEHASH_MISMATCH, 6);
    }

    // ---- reason 1: no code ---------------------------------------------------------------------------

    function test_reason1_emptyCode() public {
        assertEq(CodeScan.scan(""), CodePins.NO_CODE);
        _expectShape(CODELESS, CodePins.NO_CODE);
        gate.requirePlainRuntime(CODELESS);
        _expectShape(CODELESS, CodePins.NO_CODE);
        gate.requireRealCode(CODELESS);
        _expectShape(CODELESS, CodePins.NO_CODE);
        gate.realCodeAndHash(CODELESS);
        assertFalse(gate.isDesignator(CODELESS));
    }

    // ---- reason 2: EIP-7702 designator -------------------------------------------------------------

    function testFuzz_reason2_designator(address target) public {
        bytes memory designator = abi.encodePacked(hex"ef0100", target);
        assertEq(designator.length, 23);
        assertEq(CodeScan.scan(designator), CodePins.DESIGNATOR);

        vm.etch(SLOT, designator);
        assertEq(SLOT.code.length, 23);
        assertTrue(gate.isDesignator(SLOT));
        _expectShape(SLOT, CodePins.DESIGNATOR);
        gate.requirePlainRuntime(SLOT);
        _expectShape(SLOT, CodePins.DESIGNATOR);
        gate.requireRealCode(SLOT);
        _expectShape(SLOT, CodePins.DESIGNATOR);
        gate.realCodeAndHash(SLOT);
    }

    /// 23 bytes of ordinary code are real code; the designator rule is the exact shape, not the size.
    function test_designatorIsTheExactShapeOnly() public {
        bytes memory ordinary23 = new bytes(23);
        for (uint256 i; i < 23; ++i) {
            ordinary23[i] = 0x5b;
        }
        vm.etch(SLOT, ordinary23);
        assertFalse(gate.isDesignator(SLOT));
        gate.requireRealCode(SLOT);
        assertEq(gate.realCodeAndHash(SLOT), keccak256(ordinary23));

        vm.etch(SLOT, hex"6000");
        assertFalse(gate.isDesignator(SLOT));
        gate.requireRealCode(SLOT);
    }

    // ---- reason 3: forbidden opcodes ---------------------------------------------------------------

    /// Every opcode byte, alone in the code region: exactly the five forbidden ones refuse.
    function test_reason3_everyOpcodeClassified() public pure {
        for (uint256 op; op < 256; ++op) {
            bool forbidden = op == 0xf0 || op == 0xf2 || op == 0xf4 || op == 0xf5 || op == 0xff;
            assertEq(
                CodeScan.scan(_rt(abi.encodePacked(uint8(op)))),
                forbidden ? CodePins.FORBIDDEN_OPCODE : 0,
                "opcode classification"
            );
        }
    }

    function test_reason3_eachForbiddenOpcodeThroughTheAddressPath() public {
        for (uint256 i; i < 5; ++i) {
            bytes memory rt = _rt(bytes.concat(hex"60006000", _forbidden(i), hex"00"));
            vm.etch(SLOT, rt);
            _expectShape(SLOT, CodePins.FORBIDDEN_OPCODE);
            gate.requirePlainRuntime(SLOT);
        }
    }

    /// Property (b): a real forbidden opcode anywhere outside push data refuses.
    function testFuzz_reason3_realForbiddenOpcodeFails(
        bytes32 seed,
        uint8 before,
        uint8 afterwards,
        uint8 which
    ) public {
        bytes memory code = bytes.concat(
            _stream(seed, bound(before, 0, 32)),
            _forbidden(which),
            _stream(~seed, bound(afterwards, 0, 32))
        );
        assertEq(CodeScan.scan(_rt(code)), CodePins.FORBIDDEN_OPCODE);
        vm.etch(SLOT, _rt(code));
        _expectShape(SLOT, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(SLOT);
    }

    /// Property (a): forbidden bytes that all sit inside push immediates pass.
    function testFuzz_forbiddenBytesInsidePushDataPass(bytes32 seed, uint8 count) public {
        bytes memory rt = _rt(_stream(seed, bound(count, 1, 48)));
        assertEq(CodeScan.scan(rt), 0);
        vm.etch(SLOT, rt);
        gate.requirePlainRuntime(SLOT);
    }

    /// Property (a), with the immediates taken verbatim from the fuzzer.
    function testFuzz_randomPushDataPasses(bytes memory data) public pure {
        bytes memory code;
        for (uint256 i; i < data.length; i += 32) {
            uint256 width = data.length - i < 32 ? data.length - i : 32;
            bytes memory chunk = new bytes(width);
            for (uint256 j; j < width; ++j) {
                chunk[j] = data[i + j];
            }
            code = bytes.concat(code, bytes1(uint8(0x5f + width)), chunk, hex"50");
        }
        assertEq(CodeScan.scan(_rt(code)), 0);
    }

    function test_pushDataOfOnlyForbiddenBytesPasses() public pure {
        bytes memory code = bytes.concat(hex"7f", _repeat(0xf4, 32), hex"64f0f2f4f5ff", hex"5050");
        assertEq(CodeScan.scan(_rt(code)), 0);
        // One byte shorter immediates and the last forbidden byte becomes an opcode.
        assertEq(CodeScan.scan(_rt(bytes.concat(hex"63f0f2f4f5ff"))), CodePins.FORBIDDEN_OPCODE);
    }

    // ---- reason 4: trailer malformed ---------------------------------------------------------------

    /// Property (c): a trailer whose last two bytes claim more than the runtime refuses.
    function testFuzz_reason4_trailerLongerThanRuntimeFails(bytes memory body, uint16 claimed)
        public
        pure
    {
        vm.assume(body.length < 0xfffd);
        bytes memory code = bytes.concat(hex"00", body); // never a designator or the EIP-1167 head
        uint256 length = bound(claimed, code.length + 1, 0xffff);
        assertEq(
            CodeScan.scan(bytes.concat(code, bytes2(uint16(length)))), CodePins.TRAILER_MALFORMED
        );
    }

    function test_reason4_trailerBoundaries() public {
        assertEq(CodeScan.scan(hex"00"), CodePins.TRAILER_MALFORMED, "no room for a length");
        assertEq(CodeScan.scan(hex"000002"), CodePins.TRAILER_MALFORMED, "L + 2 = size + 1");
        assertEq(CodeScan.scan(hex"000001"), 0, "L + 2 = size: an empty code region");
        assertEq(CodeScan.scan(hex"0000"), 0, "L = 0: a two-byte trailer");
        vm.etch(SLOT, hex"60016002ffff");
        _expectShape(SLOT, CodePins.TRAILER_MALFORMED);
        gate.requirePlainRuntime(SLOT);
    }

    // ---- reason 5: EIP-1167 minimal proxy ----------------------------------------------------------

    /// Property (f): the exact 45-byte EIP-1167 runtime, for any implementation.
    function testFuzz_reason5_minimalProxy(address implementation) public {
        bytes memory rt = bytes.concat(PROXY_HEAD, bytes20(implementation), PROXY_TAIL);
        assertEq(rt.length, 45);
        assertEq(CodeScan.scan(rt), CodePins.PROXY_SHAPE);
        vm.etch(SLOT, rt);
        _expectShape(SLOT, CodePins.PROXY_SHAPE);
        gate.requirePlainRuntime(SLOT);

        // Near misses are not the exact shape and still refuse: one appended byte, one changed byte.
        assertTrue(CodeScan.scan(bytes.concat(rt, hex"00")) != 0);
        rt[44] = 0x00;
        assertTrue(CodeScan.scan(rt) != 0);
    }

    function test_reason5_openZeppelinClone() public {
        address clone = Clones.clone(address(new PlainHelper()));
        assertEq(clone.code.length, 45);
        _expectShape(clone, CodePins.PROXY_SHAPE);
        gate.requirePlainRuntime(clone);
    }

    /// A clone with immutable arguments is no longer the exact shape: it refuses as a delegating
    /// runtime (3) or, when the arguments end in a large length, as a malformed trailer (4).
    function test_cloneWithImmutableArgsRefused() public {
        address implementation = address(new PlainHelper());
        address withLength = Clones.cloneWithImmutableArgs(implementation, hex"0001");
        _expectShape(withLength, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(withLength);
        address withJunk = Clones.cloneWithImmutableArgs(implementation, hex"ff");
        _expectShape(withJunk, CodePins.TRAILER_MALFORMED);
        gate.requirePlainRuntime(withJunk);
    }

    function test_erc1967ProxyRefused() public {
        address implementation = address(new PlainHelper());
        address proxy =
            address(new ERC1967Proxy(implementation, abi.encodeCall(PlainHelper.add, (1))));
        _expectShape(proxy, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(proxy);
    }

    // ---- property (d): a PUSH truncated by the trailer ---------------------------------------------

    function testFuzz_pushTruncatedByTrailerPasses(
        bytes32 seed,
        uint8 count,
        uint8 width,
        uint8 present
    ) public pure {
        uint256 w = bound(width, 1, 32);
        uint256 k = bound(present, 0, w - 1);
        bytes memory prefix = _stream(seed, bound(count, 0, 32));
        bytes memory push = bytes.concat(bytes1(uint8(0x5f + w)), _repeat(0xf4, k));
        assertEq(CodeScan.scan(_rt(bytes.concat(prefix, push))), 0);
        assertEq(CodeScan.scan(_rt(bytes.concat(prefix, hex"f4", push))), CodePins.FORBIDDEN_OPCODE);
    }

    // ---- the trailer region is skipped only where execution cannot reach it -----------------------

    /// A crafted runtime names its own "trailer" and jumps into it: refused, not skipped.
    function test_trailerJumpdestReachingForbiddenFails() public pure {
        // PUSH1 4 JUMP STOP | JUMPDEST DELEGATECALL STOP | L = 3
        assertEq(CodeScan.scan(hex"600456005bf4000003"), CodePins.FORBIDDEN_OPCODE);
        // A halt between the JUMPDEST and the forbidden byte makes it data again.
        assertEq(CodeScan.scan(hex"600456005b00f40004"), 0);
    }

    /// The code region falls through into its "trailer": refused.
    function test_fallThroughIntoTrailerFails() public pure {
        // PUSH1 0 | DELEGATECALL STOP | L = 2
        assertEq(CodeScan.scan(hex"6000f4000002"), CodePins.FORBIDDEN_OPCODE);
    }

    /// After STOP, JUMP, RETURN, REVERT or INVALID, forbidden trailer bytes are unreachable data.
    function test_unreachableTrailerBytesPass() public pure {
        bytes5 halting = hex"0056f3fdfe";
        for (uint256 i; i < 5; ++i) {
            bytes memory rt = bytes.concat(hex"6000", halting[i], hex"f4f0f2f5ff", hex"0005");
            assertEq(CodeScan.scan(rt), 0, "halted before the trailer");
        }
        // An undefined opcode is not trusted to halt (a later fork may define it).
        assertEq(CodeScan.scan(hex"600021f4f0f2f5ff0005"), CodePins.FORBIDDEN_OPCODE);
    }

    /// `L + 2 == size`: there is no code region, and pc 0 is live.
    function test_wholeRuntimeNamedAsTrailerIsStillScanned() public pure {
        assertEq(CodeScan.scan(hex"f4000002"), CodePins.FORBIDDEN_OPCODE);
        assertEq(CodeScan.scan(hex"00f40002"), 0);
    }

    /// A third-party IPFS-hash trailer whose hash bytes hold forbidden values passes behind INVALID,
    /// and refuses when the code before it falls through into the hash.
    function test_ipfsTrailer() public pure {
        bytes memory hash = bytes.concat(hex"f4", _repeat(0xf0, 33));
        bytes memory trailer =
            bytes.concat(hex"a264697066735822", hash, hex"64736f6c6343000825", hex"0033");
        assertEq(trailer.length, 0x33 + 2);
        assertEq(CodeScan.scan(bytes.concat(hex"6080604052600080fdfe", trailer)), 0);
        assertEq(CodeScan.scan(bytes.concat(hex"6080604052", trailer)), CodePins.FORBIDDEN_OPCODE);
    }

    // ---- property (e): compiled contracts ----------------------------------------------------------

    function test_compiledPlainHelperPasses() public {
        address helper = address(new PlainHelper());
        gate.requirePlainRuntime(helper);
        assertEq(CodeScan.scan(helper.code), 0);
    }

    /// The compiled trailer is the solc version map the scan expects: L = 10, 12 bytes in all.
    function test_compiledTrailerIsTheSolcVersionMap() public {
        bytes memory code = address(new PlainHelper()).code;
        uint256 n = code.length;
        uint256 length = (uint256(uint8(code[n - 2])) << 8) | uint8(code[n - 1]);
        assertEq(length, 10);
        bytes memory tail = new bytes(length + 2);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = code[n - tail.length + i];
        }
        assertEq(tail, TRAILER);
    }

    function test_compiledDelegatecallFails() public {
        address helper = address(new DelegatingHelper());
        _expectShape(helper, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(helper);
    }

    function test_compiledCreateFails() public {
        address helper = address(new CreatingHelper());
        _expectShape(helper, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(helper);
    }

    function test_compiledCreate2Fails() public {
        address helper = address(new Create2Helper());
        _expectShape(helper, CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(helper);
    }

    /// This test contract deploys its helpers with `new`, so its own runtime carries `CREATE`.
    function test_thisTestContractFails() public {
        assertEq(CodeScan.scan(address(this).code), CodePins.FORBIDDEN_OPCODE);
        _expectShape(address(this), CodePins.FORBIDDEN_OPCODE);
        gate.requirePlainRuntime(address(this));
    }

    // ---- the scan leaves memory as it found it ------------------------------------------------------

    function test_scanLeavesInputAndFreeMemoryPointer() public pure {
        bytes memory rt = _rt(bytes.concat(hex"7f", _repeat(0xf4, 32), hex"f4"));
        bytes32 before = keccak256(rt);
        uint256 fmp;
        assembly ("memory-safe") {
            fmp := mload(0x40)
        }
        assertEq(CodeScan.scan(rt), CodePins.FORBIDDEN_OPCODE);
        uint256 fmpAfter;
        assembly ("memory-safe") {
            fmpAfter := mload(0x40)
        }
        assertEq(fmpAfter, fmp, "scratch released");
        assertEq(keccak256(rt), before, "input untouched");
    }

    // ---- CodePins -----------------------------------------------------------------------------------

    function test_requireCodehash() public {
        address helper = address(new PlainHelper());
        gate.requireCodehash(helper, helper.codehash);
        gate.requireCodehash(helper, keccak256(helper.code));
        assertEq(gate.realCodeAndHash(helper), helper.codehash);

        _expectShape(helper, CodePins.CODEHASH_MISMATCH);
        gate.requireCodehash(helper, bytes32(uint256(helper.codehash) ^ 1));
        _expectShape(CODELESS, CodePins.CODEHASH_MISMATCH);
        gate.requireCodehash(CODELESS, helper.codehash);
    }

    /// A pin never names absent code, whether the account is missing (hash 0) or code-less.
    function test_requireCodehash_emptyPinRefused() public {
        assertEq(CODELESS.codehash, bytes32(0));
        _expectShape(CODELESS, CodePins.NO_CODE);
        gate.requireCodehash(CODELESS, bytes32(0));

        vm.deal(CODELESS, 1);
        assertEq(CODELESS.codehash, keccak256(""));
        _expectShape(CODELESS, CodePins.NO_CODE);
        gate.requireCodehash(CODELESS, keccak256(""));
    }

    /// A designator's own hash satisfies `requireCodehash`; the gate refuses it with `requireRealCode`.
    function test_requireCodehash_isNotTheDesignatorCheck() public {
        bytes memory designator = abi.encodePacked(hex"ef0100", address(0xCAFE));
        vm.etch(SLOT, designator);
        gate.requireCodehash(SLOT, keccak256(designator));
        _expectShape(SLOT, CodePins.DESIGNATOR);
        gate.realCodeAndHash(SLOT);
    }

    // ---- gas ----------------------------------------------------------------------------------------

    /// Worst case: every byte its own instruction. 20,480 B and the EIP-170 maximum, 24,576 B.
    function test_gas_oneByteOpcodes() public {
        uint256[2] memory sizes = [uint256(20_480), 24_576];
        for (uint256 i; i < 2; ++i) {
            bytes memory rt = _rt(_repeat(0x5b, sizes[i] - TRAILER.length));
            assertEq(rt.length, sizes[i]);
            uint256 before = gasleft();
            uint8 reason = CodeScan.scan(rt);
            uint256 inMemory = before - gasleft();
            assertEq(reason, 0);
            vm.etch(SLOT, rt);
            uint256 viaAddress = gate.scanGas(SLOT);
            console2.log("one-byte opcodes, runtime bytes", sizes[i]);
            console2.log("  CodeScan.scan(bytes) gas", inMemory);
            console2.log("  CodeScan.requirePlainRuntime(address) gas, cold", viaAddress);
            assertLt(viaAddress, 1_000_000);
        }
    }

    /// Compiled density: `PlainHelper`'s code region repeated to 20,480 B (32 STOP bytes between copies
    /// absorb a PUSH truncated at a copy's end, so every copy is walked in its own alignment).
    function test_gas_compiledMix20KiB() public {
        bytes memory helper = address(new PlainHelper()).code;
        bytes memory region = new bytes(helper.length - TRAILER.length);
        for (uint256 i; i < region.length; ++i) {
            region[i] = helper[i];
        }
        bytes memory unit = bytes.concat(region, new bytes(32));
        bytes memory body;
        while (body.length + unit.length <= 20_480 - TRAILER.length) {
            body = bytes.concat(body, unit);
        }
        body = bytes.concat(body, new bytes(20_480 - TRAILER.length - body.length));
        bytes memory rt = _rt(body);
        assertEq(rt.length, 20_480);
        vm.etch(SLOT, rt);
        uint256 used = gate.scanGas(SLOT);
        console2.log("compiled mix, runtime bytes", rt.length);
        console2.log("  instructions walked", _instructions(rt));
        console2.log("  CodeScan.requirePlainRuntime(address) gas, cold", used);
        assertLt(used, 1_000_000);
    }

    // ---- inline size (design §3.1 L6 estimates ≈ 0.2 KB / ≈ 0.9 KB; the gate is S0.4's budgets) -----

    /// Recorded, not asserted: the bytes depend on the codegen (via-IR in every release profile).
    function test_inlineSize() public {
        uint256 baseline = address(new BaselineProbe()).code.length;
        uint256 scan = address(new ScanProbe()).code.length;
        uint256 pins = address(new PinProbe()).code.length;
        console2.log("runtime bytes: baseline probe", baseline);
        console2.log("  with CodeScan.requirePlainRuntime", scan);
        console2.log("  with CodePins.requireRealCode + requireCodehash", pins);
        assertGt(scan, baseline);
        assertGt(pins, baseline);
    }

    // ---- helpers ------------------------------------------------------------------------------------

    function _expectShape(address target, uint8 reason) internal {
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, target, reason));
    }

    function _rt(bytes memory code) internal pure returns (bytes memory) {
        return bytes.concat(code, TRAILER);
    }

    function _forbidden(uint256 i) internal pure returns (bytes1) {
        bytes5 ops = hex"f0f2f4f5ff";
        return ops[i % 5];
    }

    /// One-byte opcodes that are neither pushes nor forbidden, including the near misses CALL,
    /// RETURN, STATICCALL, REVERT, INVALID, PUSH0 and the 0xf6..0xfc gap.
    function _harmless(uint256 i) internal pure returns (bytes1) {
        bytes16 ops = hex"0001505556575b5f80f1f3f6fafbfdfe";
        return ops[i % 16];
    }

    /// A random instruction stream: PUSH1..PUSH32 whose immediates are about one third forbidden
    /// bytes, interleaved with harmless one-byte opcodes.
    function _stream(bytes32 seed, uint256 count) internal pure returns (bytes memory code) {
        for (uint256 i; i < count; ++i) {
            bytes32 r = keccak256(abi.encode(seed, i));
            if (uint8(r[0]) & 1 == 0) {
                uint256 width = uint256(uint8(r[1])) % 32 + 1;
                bytes32 s = keccak256(abi.encode(r));
                bytes memory immediates = new bytes(width);
                for (uint256 j; j < width; ++j) {
                    immediates[j] = uint8(s[j]) % 3 == 0 ? _forbidden(uint8(r[j])) : s[j];
                }
                code = bytes.concat(code, bytes1(uint8(0x5f + width)), immediates);
            } else {
                code = bytes.concat(code, _harmless(uint8(r[1])));
            }
        }
    }

    function _repeat(uint8 value, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = bytes1(value);
        }
    }

    function _instructions(bytes memory rt) internal pure returns (uint256 count) {
        uint256 end = rt.length - TRAILER.length;
        for (uint256 pc; pc < end; ++pc) {
            uint8 op = uint8(rt[pc]);
            if (op >= 0x60 && op <= 0x7f) pc += op - 0x5f;
            ++count;
        }
    }
}
