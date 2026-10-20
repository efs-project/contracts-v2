// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {Action, ActionKind} from "../../../src/interfaces/Actions.sol";
import {
    E_CAS,
    E_KIND,
    E_NOT_LIVE,
    E_RESERVED,
    E_SHAPE,
    E_TARGET_MISSING,
    E_UNKNOWN_TYPE
} from "../../../src/interfaces/Errors.sol";

/// @notice The per-kind zero-shape law (design §6.4, `LedgerCore._checkShape`): code 1 a required field is
///         zero, code 2 a forbidden field is set, code 3 a body accompanies a body-less kind; reserved kinds
///         8/9 → `E_RESERVED(2, kind)`; unknown kinds → `E_KIND(leaf, kind)`. The failing leaf sits after 0..3
///         valid CREATE leaves so the leaf index in the error is the failing leaf's, and every refusal leaves
///         the raw-slot digest unchanged (I8).
contract ShapeTest is KernelFixture {
    // Action fields by index: 1 typeId, 2 bodyHashOrRecordId, 3 purpose, 4 subject, 5 role, 6 target,
    // 7 expectedRevision, 8 salt.
    uint8 internal constant F_TYPE = 1;
    uint8 internal constant F_BODYHASH = 2;
    uint8 internal constant F_PURPOSE = 3;
    uint8 internal constant F_SUBJECT = 4;
    uint8 internal constant F_ROLE = 5;
    uint8 internal constant F_TARGET = 6;
    uint8 internal constant F_REVISION = 7;
    uint8 internal constant F_SALT = 8;

    bytes32 internal constant SUBJ = keccak256("shape/subject");
    bytes32 internal constant TARGET = keccak256("shape/target");
    bytes internal constant BODY = "shape-law";

    uint256 internal _case;

    function _base(uint8 kind) internal pure returns (Action memory a) {
        if (kind == ActionKind.PUBLISH) a = _publish(TYPE_OK, BODY);
        else if (kind == ActionKind.REUSE) a = _reuse(TYPE_OK, keccak256("shape/record"));
        else if (kind == ActionKind.BIND) a = _bind(FOLDER, SUBJ, ROLE, TARGET, 0);
        else if (kind == ActionKind.UNBIND) a = _unbind(FOLDER, SUBJ, ROLE, 0);
        else if (kind == ActionKind.RELEASE) a = _release(FOLDER, SUBJ, ROLE, 0);
        else if (kind == ActionKind.CREATE) a = _create(keccak256("shape/salt"));
        else if (kind == ActionKind.WITHDRAW) a = _withdraw(1);
        else a.kind = kind;
    }

    function _set(Action memory a, uint8 field, bytes32 v) internal pure {
        if (field == F_TYPE) a.typeId = v;
        else if (field == F_BODYHASH) a.bodyHashOrRecordId = v;
        else if (field == F_PURPOSE) a.purpose = v;
        else if (field == F_SUBJECT) a.subject = v;
        else if (field == F_ROLE) a.role = v;
        else if (field == F_TARGET) a.target = v;
        else if (field == F_REVISION) a.expectedRevision = uint64(uint256(v));
        else a.salt = v;
    }

    /// Submits `a` as leaf `_case % 4` (after that many CREATE leaves) with `body` at that leaf.
    function _refuse(Action memory a, bytes memory body, bytes memory err) internal {
        uint256 leaf = _case++ % 4;
        Action[] memory l = _afterCreates(leaf, keccak256("shape/prefix"), a);
        bytes[] memory b = _bodies(leaf + 1, leaf, body);
        _expectNoChange(l, b, err);
    }

    function _leaf() internal view returns (uint8) {
        return uint8(_case % 4);
    }

    function _shape(uint8 code) internal view returns (bytes memory) {
        return abi.encodeWithSelector(E_SHAPE.selector, _leaf(), code);
    }

    function _bodyOf(uint8 kind) internal pure returns (bytes memory) {
        return kind == ActionKind.PUBLISH ? BODY : bytes("");
    }

    // ---- code 2: a forbidden field is set -----------------------------------------------------------------

    function _forbidden(uint8 kind) internal pure returns (uint8[] memory f) {
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            f = new uint8[](6);
            (f[0], f[1], f[2], f[3], f[4], f[5]) =
            (F_PURPOSE, F_SUBJECT, F_ROLE, F_TARGET, F_REVISION, F_SALT);
        } else if (kind == ActionKind.BIND) {
            f = new uint8[](3);
            (f[0], f[1], f[2]) = (F_TYPE, F_BODYHASH, F_SALT);
        } else if (kind == ActionKind.UNBIND || kind == ActionKind.RELEASE) {
            f = new uint8[](4);
            (f[0], f[1], f[2], f[3]) = (F_TYPE, F_BODYHASH, F_TARGET, F_SALT);
        } else if (kind == ActionKind.CREATE) {
            f = new uint8[](7);
            (f[0], f[1], f[2], f[3], f[4], f[5], f[6]) =
            (F_TYPE, F_BODYHASH, F_PURPOSE, F_SUBJECT, F_ROLE, F_TARGET, F_REVISION);
        } else {
            f = new uint8[](7);
            (f[0], f[1], f[2], f[3], f[4], f[5], f[6]) =
            (F_TYPE, F_BODYHASH, F_PURPOSE, F_SUBJECT, F_ROLE, F_REVISION, F_SALT);
        }
    }

    function test_forbidden_field_is_E_SHAPE_2_for_every_kind() public {
        for (uint8 kind = 1; kind <= 7; ++kind) {
            uint8[] memory f = _forbidden(kind);
            for (uint256 i; i < f.length; ++i) {
                Action memory a = _base(kind);
                _set(a, f[i], keccak256(abi.encode("forbidden", kind, f[i])));
                _refuse(a, _bodyOf(kind), _shape(2));
            }
        }
    }

    // ---- code 1: a required field is zero ------------------------------------------------------------------

    function test_missing_required_field_is_E_SHAPE_1_for_every_kind() public {
        uint8[2][9] memory table = [
            [ActionKind.PUBLISH, F_BODYHASH],
            [ActionKind.REUSE, F_BODYHASH],
            [ActionKind.BIND, F_PURPOSE],
            [ActionKind.BIND, F_SUBJECT],
            [ActionKind.BIND, F_TARGET],
            [ActionKind.UNBIND, F_PURPOSE],
            [ActionKind.UNBIND, F_SUBJECT],
            [ActionKind.CREATE, F_SALT],
            [ActionKind.WITHDRAW, F_TARGET]
        ];
        for (uint256 i; i < table.length; ++i) {
            Action memory a = _base(table[i][0]);
            _set(a, table[i][1], 0);
            _refuse(a, _bodyOf(table[i][0]), _shape(1));
        }
        for (uint8 f = F_PURPOSE; f <= F_SUBJECT; ++f) {
            Action memory a = _base(ActionKind.RELEASE);
            _set(a, f, 0);
            _refuse(a, "", _shape(1));
        }
    }

    // DESIGN-DIVERGENCE: §6.4 runs the shape law per leaf before the kernel's `typeInfo` load, and §6.2 says
    // an unbound native call meets an unknown Type only at that per-leaf load. The code's preparation quote
    // (`LedgerIngress._foldOne`, src/core/LedgerIngress.sol:387-388) loads `typeInfo` for every PUBLISH/REUSE
    // leaf on every lane, bound or not, so a zero typeId is `E_UNKNOWN_TYPE(leaf, 0)`, never `E_SHAPE(leaf, 1)`.
    function test_zero_typeId_is_E_UNKNOWN_TYPE_from_preparation_not_E_SHAPE_1() public {
        for (uint8 kind = ActionKind.PUBLISH; kind <= ActionKind.REUSE; ++kind) {
            Action memory a = _base(kind);
            a.typeId = 0;
            _refuse(a, _bodyOf(kind), abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, _leaf(), 0));
        }
    }

    // DESIGN-DIVERGENCE: same root as above (src/core/LedgerIngress.sol:387-388): the precedence across leaves
    // inverts — a later leaf's unknown Type (refused in preparation) beats an earlier leaf's shape error.
    function test_preparation_unknown_type_precedes_an_earlier_leafs_shape_error() public {
        Action memory badShape = _create(0);
        Action memory unknown = _publish(keccak256("never registered"), BODY);
        _expectNoChange(
            _acts(badShape, unknown),
            _bodies(2, 1, BODY),
            abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(1), keccak256("never registered"))
        );
    }

    // ---- code 3: a body accompanies a body-less kind -------------------------------------------------------

    function test_body_present_is_E_SHAPE_3_for_every_bodyless_kind() public {
        for (uint8 kind = ActionKind.REUSE; kind <= ActionKind.RELEASE; ++kind) {
            _refuse(_base(kind), hex"00", _shape(3));
        }
    }

    // ---- optional fields pass the law and fail at the next stage --------------------------------------------

    function test_optional_fields_pass_the_shape_law() public {
        Action memory roleless = _base(ActionKind.BIND);
        roleless.role = 0;
        _refuse(roleless, "", abi.encodeWithSelector(E_TARGET_MISSING.selector, _leaf(), TARGET));
        Action memory cas = _base(ActionKind.BIND);
        cas.expectedRevision = 5;
        bytes32 key = _key(principal, FOLDER, SUBJ, ROLE);
        _refuse(cas, "", abi.encodeWithSelector(E_CAS.selector, key, uint64(5), uint64(0)));
        Action memory mask = _base(ActionKind.UNBIND);
        mask.role = 0;
        bytes32 roleless0 = _key(principal, FOLDER, SUBJ, 0);
        _refuse(mask, "", abi.encodeWithSelector(E_NOT_LIVE.selector, _leaf(), roleless0, 0));
    }

    // ---- reserved and unknown kinds ------------------------------------------------------------------------

    function test_reserved_kinds_8_and_9_are_E_RESERVED_2() public {
        for (uint8 kind = ActionKind.STAGE_RESERVED; kind <= ActionKind.COMMIT_RESERVED; ++kind) {
            _refuse(_base(kind), "", abi.encodeWithSelector(E_RESERVED.selector, uint8(2), kind));
        }
    }

    function test_unknown_kinds_are_E_KIND() public {
        uint8[6] memory kinds = [0, 10, 11, 15, 128, 255];
        for (uint256 i; i < kinds.length; ++i) {
            _refuse(_base(kinds[i]), "", abi.encodeWithSelector(E_KIND.selector, _leaf(), kinds[i]));
        }
    }

    // ---- fuzz: one forbidden field set to any nonzero value ------------------------------------------------

    function testFuzz_forbidden_field_any_value(uint8 kindSeed, uint8 fieldSeed, bytes32 v) public {
        uint8 kind = uint8(bound(kindSeed, 1, 7));
        uint8[] memory f = _forbidden(kind);
        uint8 field = f[bound(fieldSeed, 0, f.length - 1)];
        if (field == F_REVISION) vm.assume(uint64(uint256(v)) != 0);
        vm.assume(v != 0);
        Action memory a = _base(kind);
        _set(a, field, v);
        _refuse(a, _bodyOf(kind), _shape(2));
    }

    // ---- the law holds at the last leaf of a full batch ------------------------------------------------------

    function test_leaf_63_reports_leaf_63() public {
        Action[] memory l = _afterCreates(63, keccak256("shape/full"), _create(0));
        _expectNoChange(l, _bodies(64), abi.encodeWithSelector(E_SHAPE.selector, uint8(63), 1));
    }
}
