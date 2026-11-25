// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {EfsFiles} from "../../../src/lib/EfsFiles.sol";
import {EfsNative} from "../../../src/lib/EfsNative.sol";
import {Action, ActionKind, BindingNumber, Coordinate} from "../../../src/interfaces/Actions.sol";
import {E_SHAPE} from "../../../src/interfaces/Errors.sol";

/// @notice Asserts test/vectors/numbers.json (`efs/vectors/numbers/1`, written in JS by tools/number-vectors.mjs)
///         against the contracts: every shape case against the kernel (admitted, or `E_SHAPE(0, 2)` with nothing
///         written), every (state, strength) against `BindingNumber.numberOf`, and every builder's action and
///         actionsHash against `EfsFiles` and `EfsNative`. The SDK reproduces the same file.
contract NumberVectorsTest is KernelFixture {
    string internal json;

    function setUp() public override {
        super.setUp();
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/numbers.json"));
    }

    function _at(string memory list, uint256 i, string memory field)
        internal
        pure
        returns (string memory)
    {
        return string.concat(".", list, "[", vm.toString(i), "].", field);
    }

    function test_header() public view {
        assertEq(vm.parseJsonString(json, ".schema"), "efs/vectors/numbers/1");
        assertEq(vm.parseJsonUint(json, ".maxStrength"), BindingNumber.MAX_STRENGTH);
    }

    function test_numbers() public view {
        uint256 n = _len(".numbers");
        assertEq(n, 20);
        for (uint256 i; i < n; ++i) {
            uint8 state = uint8(vm.parseJsonUint(json, _at("numbers", i, "state")));
            uint16 strength = uint16(vm.parseJsonUint(json, _at("numbers", i, "strength")));
            (bool has, int32 number) = BindingNumber.numberOf(state, strength);
            assertEq(has, vm.parseJsonBool(json, _at("numbers", i, "has")), "has");
            assertEq(int256(number), vm.parseJsonInt(json, _at("numbers", i, "number")), "number");
        }
    }

    /// Each shape case is executed by a fresh principal at a fresh position: BIND and UNBIND from UNSET, RELEASE
    /// from BOUND (a strength-0 bind first), so the shape law is the only thing that can refuse it.
    function test_shape_law_against_the_kernel() public {
        uint256 n = _len(".shape");
        assertEq(n, 27);
        bytes32 target = _rid(TYPE_OK, "vectors/numbers/target");
        _exec(
            _acts(_publish(TYPE_OK, "vectors/numbers/target")),
            _bodies(1, 0, "vectors/numbers/target")
        );
        for (uint256 i; i < n; ++i) {
            uint8 kind = uint8(vm.parseJsonUint(json, _at("shape", i, "kind")));
            bytes32 word = vm.parseJsonBytes32(json, _at("shape", i, "saltOrStrength"));
            uint256 code = vm.parseJsonUint(json, _at("shape", i, "code"));
            bytes32 subject = keccak256(abi.encode("vectors/numbers/shape", i));
            uint64 rev;
            if (kind == ActionKind.RELEASE) {
                _exec(_acts(_bind(FOLDER, subject, ROLE, target, 0)), _bodies(1));
                rev = 1;
            }
            Action memory a = kind == ActionKind.BIND
                ? _bind(FOLDER, subject, ROLE, target, rev)
                : kind == ActionKind.UNBIND
                    ? _unbind(FOLDER, subject, ROLE, rev)
                    : _release(FOLDER, subject, ROLE, rev);
            a.saltOrStrength = word;
            if (code == 0) {
                _exec(_acts(a), _bodies(1));
                (uint8 state,,,,,,, uint16 strength) =
                    hot.head(_key(principal, FOLDER, subject, ROLE));
                assertEq(state, kind == ActionKind.BIND ? 1 : kind == ActionKind.UNBIND ? 2 : 3);
                assertEq(uint256(strength), uint256(word), "the strength is stored as sent");
            } else {
                _expectNoChange(
                    _acts(a),
                    _bodies(1),
                    abi.encodeWithSelector(E_SHAPE.selector, uint8(0), uint8(code))
                );
            }
        }
    }

    function test_builders() public view {
        uint256 n = _len(".builders");
        assertEq(n, 5);
        bytes32 tag = vm.parseJsonBytes32(json, ".ids.TAG");
        bytes32 topic = vm.parseJsonBytes32(json, ".ids.topic");
        bytes32 thing = vm.parseJsonBytes32(json, ".ids.thing");
        bytes32 addr = vm.parseJsonBytes32(json, ".ids.address");
        Action[5] memory built = [
            EfsFiles.bindWithStrength(tag, topic, thing, thing, 0, 75),
            EfsFiles.bindWithStrength(tag, topic, thing, thing, 1, 3),
            EfsFiles.loneNegative(tag, topic, thing, 0),
            EfsFiles.loneNegative(tag, topic, addr, 65_535),
            EfsFiles.unbindWithStrength(tag, topic, thing, 1, 4)
        ];
        Coordinate memory c = Coordinate(tag, topic, thing);
        Action[5] memory native = [
            EfsNative.bindActionWithStrength(c, thing, 0, 75),
            EfsNative.bindActionWithStrength(c, thing, 1, 3),
            EfsNative.loneNegativeAction(c, 0),
            EfsNative.loneNegativeAction(Coordinate(tag, topic, addr), 65_535),
            EfsNative.unbindActionWithStrength(c, 1, 4)
        ];
        for (uint256 i; i < n; ++i) {
            Action[] memory one = new Action[](1);
            one[0] = built[i];
            assertEq(
                keccak256(abi.encode(one)),
                vm.parseJsonBytes32(json, _at("builders", i, "actionsHash")),
                "EfsFiles actionsHash"
            );
            assertEq(abi.encode(native[i]), abi.encode(built[i]), "EfsNative == EfsFiles");
            assertEq(
                uint256(built[i].saltOrStrength),
                vm.parseJsonUint(
                    json, string.concat(_at("builders", i, "action"), ".saltOrStrength")
                )
            );
            (bool has, int32 number) = BindingNumber.numberOf(
                built[i].kind == ActionKind.BIND ? 1 : 2, uint16(uint256(built[i].saltOrStrength))
            );
            assertTrue(has);
            assertEq(int256(number), vm.parseJsonInt(json, _at("builders", i, "number")), "number");
        }
    }

    function _len(string memory path) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n), "]"))) ++n;
    }
}
