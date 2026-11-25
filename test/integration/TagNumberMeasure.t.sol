// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Vm} from "forge-std/Vm.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice SPIKE (T-4 number, T-5 homes): measurements for a signed number on every binding and for files attached
///         to an address ("home"). The number rides the bind kinds' `salt` word as a strength 0..255 (number =
///         strength when BOUND, -1 - strength when MASKED); it costs no slot. Same harness as
///         `TagPathMeasure.t.sol`: the shape is one TAG binding per (concept, target), every publication is cooled
///         so it pays what a transaction of its own pays, the concept already has one member (so `k1` and `k10`
///         are both later members), `k10` is ten actions in one publication and `per extra` is (k10 - k1) / 9.
///         Logs: `num <row> gas` (and `frame state gas` under the amsterdam profile).
contract TagNumberMeasureTest is FilesRecipesBase {
    uint256 internal constant N = 60;
    // SPIKE (tags/topics): the concept is a registered topic (a `topic-word/1` page, registered in `setUp`)
    bytes32 internal X;

    address[] internal cold;
    bytes32[N] internal s;
    EfsFiles.Types internal t;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 10; ++i) {
            cold.push(instances[i]);
        }
        cold.push(address(validator));
        cold.push(address(r.k.ingress));
        cold.push(address(r.k.applyDelegate));
        cold.push(address(r.k.control));
        cold.push(address(r.k.implementation));
        cold.push(r.k.proxy);
        cold.push(address(r.g.posting));
        cold.push(address(r.g.bitmap));
        cold.push(address(r.g.index));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        for (uint256 from; from < N; from += 20) {
            Action[] memory a = new Action[](20);
            for (uint256 i; i < 20; ++i) {
                a[i] = _create(keccak256(abi.encode("numbered", from + i)));
                s[from + i] = Keys.subject(p, a[i].salt);
            }
            r.ledger.execute(a, new bytes[](20), _ctx(a), "");
        }
        (Action memory wp, bytes memory wb) = _wordPage("measure-number-x");
        Action[] memory reg = new Action[](1);
        bytes[] memory regb = new bytes[](1);
        (reg[0], regb[0]) = (wp, wb);
        r.ledger.execute(reg, regb, _ctx(reg), "");
        X = _wordId("measure-number-x");
        // the concept's first member, so every measured row is a later member
        _silent(_acts(ActionKind.BIND, N - 1, 1, 0, 0));
        t.root = typeIds[T_ROOT];
        t.child = typeIds[T_CHILD];
        t.directory = typeIds[T_DIRECTORY];
        t.name = typeIds[T_NAME];
        t.bytes_ = typeIds[T_BYTES];
        t.content = typeIds[T_CONTENT];
        t.external_ = typeIds[T_EXTERNAL];
        t.alias_ = typeIds[T_ALIAS];
        t.notice = typeIds[T_NOTICE];
        t.span = typeIds[T_SPAN];
    }

    function _beforeExecute() internal override {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
    }

    function _silent(Action[] memory a) internal {
        r.ledger.execute(a, new bytes[](a.length), _ctx(a), "");
    }

    /// `n` TAG actions of `kind` on s[from..from+n) with `strength` and `rev` as expectedRevision.
    function _acts(uint8 kind, uint256 from, uint256 n, uint256 strength, uint64 rev)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 target = kind == ActionKind.BIND ? s[from + i] : bytes32(0);
            a[i] = _bindKind(kind, Purpose.TAG, X, s[from + i], target, rev);
            a[i].salt = bytes32(strength);
        }
    }

    function _gas(string memory label, Action[] memory a) internal returns (uint256) {
        return _measure(string.concat("num ", label), a, new bytes[](a.length));
    }

    /// `_exec` that returns the measured `execute` gas (expectations read before, state cooled just before).
    function _measure(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 used)
    {
        Native memory c = _ctx(a);
        _beforeExecute();
        uint256 before = gasleft();
        r.ledger.execute(a, b, c, "");
        used = before - gasleft();
        Vm.Gas memory frame = vm.lastFrameGas();
        emit log_named_uint(string.concat(label, " gas"), used);
        if (frame.gasStateUsed != 0) {
            emit log_named_int(string.concat(label, " frame state gas"), frame.gasStateUsed);
        }
    }

    /// k1 on s[0], k10 on s[1..11), both from the state `prep` left on s[0..11), and the marginal per extra action.
    function _row(string memory label, uint8 kind, uint256 strength, uint64 rev) internal {
        uint256 g1 = _gas(string.concat(label, " k1"), _acts(kind, 0, 1, strength, rev));
        uint256 g10 = _gas(string.concat(label, " k10"), _acts(kind, 1, 10, strength, rev));
        emit log_named_uint(string.concat("num ", label, " per extra"), (g10 - g1) / 9);
    }

    function _prep(uint8 kind, uint256 strength, uint64 rev) internal {
        _silent(_acts(kind, 0, 11, strength, rev));
    }

    function _numHead(uint256 i) internal view returns (uint8 state, uint8 strength) {
        uint256 m =
            uint256(r.hot.extsload(bytes32(Layout.bindingsHeadsSlot(_key(Purpose.TAG, X, s[i])))));
        return (uint8(m), uint8(m >> 248));
    }

    // ---- 1: assert with strength 0 and 75 -----------------------------------------------------------------

    function test_1_assert_strength_0() public {
        _row("assert s0", ActionKind.BIND, 0, 0);
    }

    function test_1_assert_strength_75() public {
        _row("assert s75", ActionKind.BIND, 75, 0);
        (uint8 st, uint8 sv) = _numHead(0);
        assertEq(abi.encode(st, sv), abi.encode(1, 75));
    }

    // ---- 2: a lone negative (UNBIND from UNSET) -----------------------------------------------------------

    function test_2_lone_negative_strength_0() public {
        _row("lone negative s0 (-1)", ActionKind.UNBIND, 0, 0);
    }

    function test_2_lone_negative_strength_4() public {
        _row("lone negative s4 (-5)", ActionKind.UNBIND, 4, 0);
        (uint8 st, uint8 sv) = _numHead(0);
        assertEq(abi.encode(st, sv), abi.encode(2, 4));
    }

    // ---- 3: change the number on an asserted tag (0 -> 75, REBIND to the same target) ---------------------

    function test_3_rebind_0_to_75() public {
        _prep(ActionKind.BIND, 0, 0);
        _row("rebind 0->75", ActionKind.BIND, 75, 1);
        (uint8 st, uint8 sv) = _numHead(0);
        assertEq(abi.encode(st, sv), abi.encode(1, 75));
    }

    // ---- 4: change a negative (-1 -> -5, MASKED -> MASKED) --------------------------------------------------

    function test_4_negative_minus1_to_minus5() public {
        _prep(ActionKind.UNBIND, 0, 0);
        _row("mask again -1->-5", ActionKind.UNBIND, 4, 1);
        (uint8 st, uint8 sv) = _numHead(0);
        assertEq(abi.encode(st, sv), abi.encode(2, 4));
    }

    // ---- 5: sign changes ------------------------------------------------------------------------------------

    function test_5_positive_to_negative() public {
        _prep(ActionKind.BIND, 3, 0);
        _row("positive->negative (3->-1, mask)", ActionKind.UNBIND, 0, 1);
    }

    function test_5_negative_to_positive() public {
        _prep(ActionKind.UNBIND, 0, 0);
        _row("negative->positive (-1->3, restore)", ActionKind.BIND, 3, 1);
    }

    function test_5_negative_to_silent() public {
        _prep(ActionKind.UNBIND, 4, 0);
        _row("negative->silent (-5, release)", ActionKind.RELEASE, 0, 1);
        (uint8 st, uint8 sv) = _numHead(0);
        assertEq(abi.encode(st, sv), abi.encode(3, 0));
    }

    function test_5_silent_to_negative() public {
        _prep(ActionKind.BIND, 0, 0);
        _silent(_acts(ActionKind.RELEASE, 0, 11, 0, 1));
        _row("silent->negative (released->-5)", ActionKind.UNBIND, 4, 2);
    }

    // ---- 6: one file attached to a home vs into an ordinary directory --------------------------------------

    function _files(bytes32 parent, string memory tag, uint256 n)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        uint256 per;
        for (uint256 i; i < n; ++i) {
            (Action[] memory ai, bytes[] memory bi,,) = EfsFiles.createFile(
                t,
                p,
                parent,
                keccak256(abi.encode(tag, i)),
                abi.encodePacked(tag, bytes1(uint8(0x30 + i))),
                "hello, home",
                true
            );
            if (i == 0) {
                per = ai.length;
                a = new Action[](per * n);
                b = new bytes[](per * n);
            }
            for (uint256 j; j < per; ++j) {
                a[i * per + j] = ai[j];
                b[i * per + j] = bi[j];
            }
        }
    }

    function _fileRow(string memory label, bytes32 parent, string memory tag) internal {
        (Action[] memory a, bytes[] memory b) = _files(parent, string.concat(tag, "1-"), 1);
        uint256 g1 = _measure(string.concat("num ", label, " file k1"), a, b);
        (a, b) = _files(parent, string.concat(tag, "x-"), 10);
        uint256 g10 = _measure(string.concat("num ", label, " file k10"), a, b);
        emit log_named_uint(string.concat("num ", label, " file per extra"), (g10 - g1) / 9);
        emit log_named_uint(string.concat("num ", label, " file actions per file"), a.length / 10);
    }

    function test_6_file_into_a_directory() public {
        // the directory already has one entry, as the home does below
        (Action[] memory a, bytes[] memory b) = _files(rootDir, "seed-", 1);
        r.ledger.execute(a, b, _ctx(a), "");
        _fileRow("directory", rootDir, "d");
    }

    function test_6_file_into_a_home() public {
        bytes32 home = bytes32(uint256(uint160(makeAddr("measure/home"))));
        (Action[] memory a, bytes[] memory b) = _files(home, "seed-", 1);
        r.ledger.execute(a, b, _ctx(a), "");
        _fileRow("home", home, "h");
    }
}
