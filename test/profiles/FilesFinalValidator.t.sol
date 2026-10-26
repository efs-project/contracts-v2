// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {Effect} from "../../src/interfaces/Index.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FilesFinalValidator} from "../../src/profiles/FilesFinalValidator.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {FilesIndexStub, FilesLedgerStub} from "../harness/doubles/FilesDoubles.sol";

/// @notice `FilesFinalValidator.validate` against a stub ledger, called as a stub index (its `ledger()` is the
///         stub): every law of design §12.2 and the prototype's `FilesFinalValidator`/`FilesDirectoryProfile`
///         placement cases at the hook level (the same cases through the real kernel are in `FilesRecipes`).
contract FilesFinalValidatorTest is Test {
    FilesLedgerStub internal ledger;
    FilesIndexStub internal index;
    FilesFinalValidator internal v;

    bytes32 internal constant NAME_TYPE = keccak256("test/files/name-type");
    bytes32 internal constant DIR_TYPE = keccak256("test/files/directory-type");
    bytes32 internal constant OTHER_TYPE = keccak256("test/files/binary-type");
    bytes32 internal constant PARENT = keccak256("parent directory record");
    bytes32 internal constant CHILD_DIR = keccak256("child directory record");
    bytes32 internal constant FILE = keccak256("file subject");
    bytes32 internal constant ROLE = keccak256("readme.txt");
    uint64 internal constant TERMINAL = 50;

    function setUp() public {
        ledger = new FilesLedgerStub();
        index = new FilesIndexStub(address(ledger));
        v = new FilesFinalValidator(NAME_TYPE, DIR_TYPE);
        ledger.setRecord(Keys.recordFromHash(NAME_TYPE, ROLE), NAME_TYPE, 3, 10);
        ledger.setRecord(PARENT, DIR_TYPE, 1, 32);
        ledger.setRecord(CHILD_DIR, DIR_TYPE, 2, 32);
        ledger.setSubject(FILE, 4);
    }

    function _bind(uint8 leaf, bytes32 subject, bytes32 role, bytes32 target, uint8 targetKind)
        internal
        pure
        returns (Effect memory e)
    {
        e.kind = ActionKind.BIND;
        e.leaf = leaf;
        e.admission = TERMINAL - 5 + leaf;
        e.purpose = Purpose.FOLDER;
        e.subject = subject;
        e.role = role;
        e.target = target;
        e.targetKind = targetKind;
        e.transitionKind = 1;
    }

    function _list(Effect memory a) internal pure returns (Effect[] memory l) {
        l = new Effect[](2);
        l[0] = a;
        l[1].kind = ActionKind.CREATE; // the terminal admission
        l[1].leaf = 9;
        l[1].admission = TERMINAL;
    }

    function _validate(Effect[] memory effects) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(index));
        (ok, ret) = address(v)
            .staticcall(abi.encodeCall(IIndexHook.validate, (uint64(1), effects, new bytes32[](0))));
    }

    function _ok(Effect[] memory effects) internal {
        (bool ok, bytes memory ret) = _validate(effects);
        assertTrue(ok, "validated");
        assertEq(ret, abi.encode(IIndexHook.validate.selector), "echoes the selector");
    }

    function _bad(Effect[] memory effects, uint8 code, uint8 leaf) internal {
        (bool ok, bytes memory ret) = _validate(effects);
        assertFalse(ok, "refused");
        assertEq(ret, abi.encodeWithSelector(E_FILES_FINAL.selector, code, leaf));
    }

    // ---- accepted placements ------------------------------------------------------------------------------------

    function test_a_file_and_a_directory_placement() public {
        _ok(_list(_bind(0, PARENT, ROLE, FILE, 2)));
        _ok(_list(_bind(0, PARENT, ROLE, CHILD_DIR, 1)));
        // a nested placement under a directory that is itself placed (the parent is any directory record)
        _ok(_list(_bind(0, CHILD_DIR, ROLE, FILE, 2)));
    }

    function test_nothing_to_judge() public {
        _ok(new Effect[](0));
        // HEAD binds, PUBLISH/CREATE effects and FOLDER removals are never judged
        Effect memory head = _bind(0, FILE, 0, keccak256("anything"), 1);
        head.purpose = Purpose.HEAD;
        _ok(_list(head));
        Effect memory mask = _bind(0, keccak256("no parent"), keccak256("no name"), 0, 0);
        mask.kind = ActionKind.UNBIND;
        _ok(_list(mask));
        mask.kind = ActionKind.RELEASE;
        _ok(_list(mask));
        Effect memory pub;
        pub.kind = ActionKind.PUBLISH;
        pub.admission = TERMINAL;
        pub.purpose = Purpose.FOLDER; // a forged purpose on a publish effect is still not a bind
        Effect[] memory one = new Effect[](1);
        one[0] = pub;
        _ok(one);
    }

    function test_a_name_published_after_the_bind_in_the_same_publication() public {
        bytes32 late = keccak256("later");
        ledger.setRecord(Keys.recordFromHash(NAME_TYPE, late), NAME_TYPE, TERMINAL, 5);
        _ok(_list(_bind(0, PARENT, late, FILE, 2)));
    }

    // ---- refused placements ----------------------------------------------------------------------------------------

    function test_the_name_must_exist_by_the_terminal_admission() public {
        _bad(_list(_bind(0, PARENT, keccak256("never published"), FILE, 2)), 1, 0);
        bytes32 future = keccak256("future");
        ledger.setRecord(Keys.recordFromHash(NAME_TYPE, future), NAME_TYPE, TERMINAL + 1, 6);
        _bad(_list(_bind(0, PARENT, future, FILE, 2)), 1, 0);
        // a record at the derived id under another Type (only a stub can show this) is not a name
        bytes32 forged = keccak256("forged");
        ledger.setRecord(Keys.recordFromHash(NAME_TYPE, forged), OTHER_TYPE, 1, 6);
        _bad(_list(_bind(0, PARENT, forged, FILE, 2)), 1, 0);
        // the name record of ANOTHER name Type does not count
        bytes32 otherName = keccak256("other.txt");
        ledger.setRecord(Keys.recordFromHash(OTHER_TYPE, otherName), OTHER_TYPE, 1, 9);
        _bad(_list(_bind(0, PARENT, otherName, FILE, 2)), 1, 0);
    }

    // L FilesDirectory test_nonexistent_parent / test_file_subject_parent / test_unrelated_record_parent
    function test_the_parent_must_be_a_directory_record() public {
        _bad(_list(_bind(0, bytes32(uint256(999)), ROLE, FILE, 2)), 2, 0);
        _bad(_list(_bind(0, FILE, ROLE, CHILD_DIR, 1)), 2, 0); // a file subject is not a directory
        bytes32 unrelated = keccak256("forged-directory");
        ledger.setRecord(unrelated, OTHER_TYPE, 1, 32);
        _bad(_list(_bind(0, unrelated, ROLE, FILE, 2)), 2, 0);
        bytes32 late = keccak256("a directory admitted later");
        ledger.setRecord(late, DIR_TYPE, TERMINAL + 1, 32);
        _bad(_list(_bind(0, late, ROLE, FILE, 2)), 2, 0);
    }

    // L FilesDirectory test_self_link_raw_ingress_rejected, test_unrelated_record_target_raw_ingress_rejected,
    // test_lookalike_type_with_wrong_rule_is_not_a_directory
    function test_the_target_is_a_file_subject_or_another_directory() public {
        _bad(_list(_bind(0, PARENT, ROLE, PARENT, 1)), 3, 0);
        bytes32 notAFile = keccak256("not-a-file");
        ledger.setRecord(notAFile, OTHER_TYPE, 1, 10);
        _bad(_list(_bind(0, PARENT, ROLE, notAFile, 1)), 5, 0);
        _bad(_list(_bind(0, PARENT, ROLE, Keys.recordFromHash(NAME_TYPE, ROLE), 1)), 5, 0); // a name
        _bad(_list(_bind(0, PARENT, ROLE, keccak256("no such subject"), 2)), 4, 0);
        bytes32 lateFile = keccak256("created later");
        ledger.setSubject(lateFile, TERMINAL + 1);
        _bad(_list(_bind(0, PARENT, ROLE, lateFile, 2)), 4, 0);
        bytes32 lateDir = keccak256("directory later");
        ledger.setRecord(lateDir, DIR_TYPE, TERMINAL + 1, 32);
        _bad(_list(_bind(0, PARENT, ROLE, lateDir, 1)), 5, 0);
        _bad(_list(_bind(0, PARENT, ROLE, FILE, 0)), 6, 0);
        _bad(_list(_bind(0, PARENT, ROLE, FILE, 3)), 6, 0);
    }

    function test_the_refusal_names_the_offending_leaf() public {
        Effect[] memory l = new Effect[](4);
        l[0] = _bind(0, PARENT, ROLE, FILE, 2);
        l[1] = _bind(1, CHILD_DIR, ROLE, FILE, 2);
        l[2] = _bind(2, PARENT, keccak256("missing"), FILE, 2);
        l[3] = _bind(3, PARENT, ROLE, FILE, 2);
        l[3].admission = TERMINAL;
        _bad(l, 1, 2);
        l[2] = _bind(2, PARENT, ROLE, CHILD_DIR, 1);
        _ok(l);
    }

    // ---- shape -----------------------------------------------------------------------------------------------------

    function test_configuration_identity_and_fold() public view {
        assertEq(v.nameTypeId(), NAME_TYPE);
        assertEq(v.directoryTypeId(), DIR_TYPE);
        assertEq(
            v.identity(),
            keccak256(abi.encode(keccak256("efs2/unit/files-final/1"), NAME_TYPE, DIR_TYPE))
        );
        Effect memory e;
        assertEq(v.fold(e, new bytes32[](0), 1), IIndexHook.fold.selector);
    }

    function test_only_an_index_caller_gets_an_answer() public {
        // a caller without ledger() cannot be answered; one with ledger() gets that ledger's verdict
        (bool ok,) = address(v)
            .staticcall(
                abi.encodeCall(
                    IIndexHook.validate,
                    (uint64(1), _list(_bind(0, PARENT, ROLE, FILE, 2)), new bytes32[](0))
                )
            );
        assertFalse(ok, "no index, no verdict");
        FilesIndexStub elsewhere = new FilesIndexStub(address(new FilesLedgerStub()));
        vm.prank(address(elsewhere));
        (ok,) = address(v)
            .staticcall(
                abi.encodeCall(
                    IIndexHook.validate,
                    (uint64(1), _list(_bind(0, PARENT, ROLE, FILE, 2)), new bytes32[](0))
                )
            );
        assertFalse(ok, "judged against the caller's own (empty) ledger");
    }

    function test_validator_is_a_plain_runtime_without_sstore() public {
        bytes memory code = address(v).code;
        assertEq(CodeScan.scan(code), 0);
        // constructor state only: no reachable SSTORE (the walk of CodeScan and tools/checks.mjs)
        uint256 n = code.length;
        uint256 end = n - ((uint256(uint8(code[n - 2])) << 8 | uint8(code[n - 1])) + 2);
        bool live = true;
        for (uint256 pc; pc < end; ++pc) {
            uint8 c = uint8(code[pc]);
            if (c >= 0x60 && c <= 0x7f) {
                pc += c - 0x5f;
            } else if (c == 0x5b) {
                live = true;
            } else if (live) {
                assertTrue(c != 0x55 && c != 0x5d, "no SSTORE/TSTORE");
                if (c == 0x00 || c == 0x56 || c == 0xf3 || c == 0xfd || c == 0xfe) live = false;
            }
        }
        emit log_named_uint("FilesFinalValidator runtime bytes", n);
    }

    function test_validate_gas() public {
        Effect[] memory l = new Effect[](8);
        for (uint8 i; i < 8; ++i) {
            l[i] = _bind(i, i % 2 == 0 ? PARENT : CHILD_DIR, ROLE, FILE, 2);
        }
        l[7].admission = TERMINAL;
        (bool ok,) = _validate(l);
        uint256 eight = vm.lastFrameGas().gasTotalUsed;
        assertTrue(ok);
        (ok,) = _validate(_list(_bind(0, PARENT, ROLE, FILE, 2)));
        uint256 one = vm.lastFrameGas().gasTotalUsed;
        assertTrue(ok);
        emit log_named_uint("validate frame gas, 8 FOLDER binds (stub ledger, cold)", eight);
        emit log_named_uint("validate frame gas, 1 FOLDER bind (stub ledger, warm)", one);
    }
}
