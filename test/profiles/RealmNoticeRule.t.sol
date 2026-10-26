// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext} from "../../src/interfaces/IAcceptor.sol";
import {ClosureConstants} from "../../src/interfaces/Limits.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {RealmNoticeRule} from "../../src/profiles/RealmNoticeRule.sol";
import {RefuseAllPolicy} from "../../src/profiles/RefuseAllPolicy.sol";
import {E_FILES_SUNSET} from "../../src/profiles/FilesProfile.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `realm-notice/1` (the freeze canary's exact body, the controller and notice principals, canonical
///         encoding) and `RefuseAllPolicy` (refuses every context).
contract RealmNoticeRuleTest is FilesUnitBase {
    RealmNoticeRule internal rule;
    RefuseAllPolicy internal refuseAll;
    bytes32 internal constant ORIGIN = keccak256("test/realm-origin");
    address internal constant CONTROLLER = address(0xC0FFEE);
    bytes32 internal constant NOTICE = keccak256("test/notice-principal");
    bytes32 internal controllerPrincipal;

    function setUp() public override {
        super.setUp();
        rule = new RealmNoticeRule();
        refuseAll = new RefuseAllPolicy();
        stub.setRealm(ORIGIN, CONTROLLER, NOTICE);
        controllerPrincipal = Keys.contractPrincipal(ORIGIN, CONTROLLER);
    }

    function _as(bytes32 principal) internal view returns (AcceptContext memory c) {
        c = _ctx();
        c.principalId = principal;
    }

    function _notice(bytes32 kind, uint256 revision, bytes memory note)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(kind, revision, note);
    }

    function test_notice_accepts_the_freeze_canary_body() public {
        // RealmController._nativeCanary: abi.encode(NOTICE_FROZEN, uint256(revision), bytes("")) as its principal
        bytes memory canary = abi.encode(ClosureConstants.NOTICE_FROZEN, uint256(7), bytes(""));
        assertEq(canary.length, 128);
        _accepts(rule, _as(controllerPrincipal), canary, _none(), _noHeaders());
        _accepts(
            rule,
            _as(controllerPrincipal),
            _notice(ClosureConstants.NOTICE_MIGRATION, 8, "to 0x0123..."),
            _none(),
            _noHeaders()
        );
        _accepts(
            rule,
            _as(NOTICE),
            _notice(ClosureConstants.NOTICE_SUCCESSOR, 9, "the successor realm is at ..."),
            _none(),
            _noHeaders()
        );
        _accepts(
            rule,
            _as(NOTICE),
            _notice(ClosureConstants.NOTICE_SUCCESSOR, 9, new bytes(32)),
            _none(),
            _noHeaders()
        );
    }

    function test_notice_principals() public {
        bytes memory frozen = _notice(ClosureConstants.NOTICE_FROZEN, 1, "");
        // frozen and migration only from the controller's contract principal of THIS realm
        _refuses(rule, _as(NOTICE), frozen, _none(), _noHeaders(), 4);
        _refuses(rule, _as(Keys.principal(CONTROLLER)), frozen, _none(), _noHeaders(), 4);
        _refuses(
            rule,
            _as(Keys.contractPrincipal(keccak256("another realm"), CONTROLLER)),
            frozen,
            _none(),
            _noHeaders(),
            4
        );
        _refuses(
            rule,
            _as(NOTICE),
            _notice(ClosureConstants.NOTICE_MIGRATION, 1, ""),
            _none(),
            _noHeaders(),
            4
        );
        // successor only from the notice principal, and never when it is unset
        bytes memory successor = _notice(ClosureConstants.NOTICE_SUCCESSOR, 1, "");
        _refuses(rule, _as(controllerPrincipal), successor, _none(), _noHeaders(), 5);
        stub.setRealm(ORIGIN, CONTROLLER, 0);
        _refuses(rule, _as(0), successor, _none(), _noHeaders(), 5);
        _refuses(rule, _as(NOTICE), successor, _none(), _noHeaders(), 5);
        // the controller principal follows the ledger's controller()
        stub.setRealm(ORIGIN, address(0xD00D), NOTICE);
        _refuses(rule, _as(controllerPrincipal), frozen, _none(), _noHeaders(), 4);
        _accepts(
            rule,
            _as(Keys.contractPrincipal(ORIGIN, address(0xD00D))),
            frozen,
            _none(),
            _noHeaders()
        );
    }

    function test_notice_kinds_and_canonical_encoding() public {
        _refuses(
            rule,
            _as(controllerPrincipal),
            _notice(keccak256("efs2/notice/other/1"), 1, ""),
            _none(),
            _noHeaders(),
            3
        );
        _refuses(rule, _as(controllerPrincipal), _notice(0, 1, ""), _none(), _noHeaders(), 3);
        bytes memory body = _notice(ClosureConstants.NOTICE_FROZEN, 1, "note");
        _accepts(rule, _as(controllerPrincipal), body, _none(), _noHeaders());
        // a trailing byte, a missing padding word, a nonzero padding byte, a moved offset, a long length
        _refuses(
            rule, _as(controllerPrincipal), bytes.concat(body, hex"00"), _none(), _noHeaders(), 2
        );
        bytes memory cut = new bytes(128);
        for (uint256 i; i < 128; ++i) {
            cut[i] = body[i];
        }
        _refuses(rule, _as(controllerPrincipal), cut, _none(), _noHeaders(), 2);
        bytes memory dirty = bytes.concat(body);
        dirty[dirty.length - 1] = 0x01;
        _refuses(rule, _as(controllerPrincipal), dirty, _none(), _noHeaders(), 2);
        bytes memory moved = bytes.concat(body);
        moved[95] = 0x80;
        _refuses(rule, _as(controllerPrincipal), moved, _none(), _noHeaders(), 2);
        bytes memory long = bytes.concat(body);
        long[127] = 0x21; // 33 bytes claimed, one word present
        _refuses(rule, _as(controllerPrincipal), long, _none(), _noHeaders(), 2);
        _refuses(
            rule,
            _as(controllerPrincipal),
            abi.encode(ClosureConstants.NOTICE_FROZEN, uint256(1)),
            _none(),
            _noHeaders(),
            2
        );
        _refuses(rule, _as(controllerPrincipal), body, _one(keccak256("x")), _noHeaders(), 1);
    }

    function testFuzz_notice_note_roundtrip(bytes memory note, uint256 revision) public {
        vm.assume(note.length < 4096);
        _accepts(
            rule,
            _as(controllerPrincipal),
            _notice(ClosureConstants.NOTICE_FROZEN, revision, note),
            _none(),
            _noHeaders()
        );
    }

    function test_notice_context_is_authenticated() public {
        _contextIsAuthenticated(
            rule,
            _as(controllerPrincipal),
            _notice(ClosureConstants.NOTICE_FROZEN, 1, ""),
            _none(),
            _noHeaders()
        );
    }

    // ---- RefuseAllPolicy ------------------------------------------------------------------------------------------

    function test_refuse_all_refuses_every_context() public {
        AcceptContext memory c = _ctx();
        (bool ok, bytes memory ret) = _call(refuseAll, c, "anything", _none(), _noHeaders());
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(E_FILES_SUNSET.selector));
        (ok, ret) = address(refuseAll)
            .staticcall(abi.encodeCall(IAcceptor.accept, (c, bytes(""), _none(), _noHeaders())));
        assertFalse(ok, "a forged context too");
        assertEq(ret, abi.encodeWithSelector(E_FILES_SUNSET.selector));
    }

    function test_notice_rules_are_plain_runtimes() public {
        _codeChecks(address(rule), "RealmNoticeRule");
        _codeChecks(address(refuseAll), "RefuseAllPolicy");
    }
}
