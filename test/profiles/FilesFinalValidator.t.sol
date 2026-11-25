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
    bytes32 internal constant ROOT_TYPE = keccak256("test/files/root-type");
    bytes32 internal constant CHILD_TYPE = keccak256("test/files/child-type");
    bytes32 internal constant TOPIC_TYPE = keccak256("test/topics/topic-type");
    bytes32 internal constant WORD_TYPE = keccak256("test/topics/word-type");
    bytes32 internal constant ROOT_REV = keccak256("FILE's root revision");
    bytes32 internal constant CHILD_REV = keccak256("FILE's child revision");
    bytes32 internal constant OTHER_FILE = keccak256("another file subject");
    bytes32 internal constant OTHER_ROOT = keccak256("OTHER_FILE's root revision");
    bytes32 internal constant WORD_A = keccak256("page of a");
    bytes32 internal constant WORD_B = keccak256("page of b");
    bytes32 internal constant PATH_AB = keccak256("/a/b");
    bytes32 internal constant PATH_LATE = keccak256("/a/late");
    bytes32 internal constant PARENT = keccak256("parent directory record");
    bytes32 internal constant CHILD_DIR = keccak256("child directory record");
    bytes32 internal constant FILE = keccak256("file subject");
    bytes32 internal constant ROLE = keccak256("readme.txt");
    uint64 internal constant TERMINAL = 50;

    function setUp() public {
        ledger = new FilesLedgerStub();
        index = new FilesIndexStub(address(ledger));
        v = new FilesFinalValidator(
            NAME_TYPE, DIR_TYPE, ROOT_TYPE, CHILD_TYPE, TOPIC_TYPE, WORD_TYPE
        );
        ledger.setRecord(Keys.recordFromHash(NAME_TYPE, ROLE), NAME_TYPE, 3, 10);
        ledger.setRecord(PARENT, DIR_TYPE, 1, 32);
        ledger.setRecord(CHILD_DIR, DIR_TYPE, 2, 32);
        ledger.setSubject(FILE, 4);
        ledger.setSubject(OTHER_FILE, 4);
        // revisions: a root names its file in word 0, a child in word 1 (word 0 is its parent revision)
        ledger.setRecord(ROOT_REV, ROOT_TYPE, 5, 69);
        ledger.setBodyWord(ROOT_REV, 0, FILE);
        ledger.setRecord(CHILD_REV, CHILD_TYPE, 6, 101);
        ledger.setBodyWord(CHILD_REV, 0, ROOT_REV);
        ledger.setBodyWord(CHILD_REV, 1, FILE);
        ledger.setRecord(OTHER_ROOT, ROOT_TYPE, 5, 69);
        ledger.setBodyWord(OTHER_ROOT, 0, OTHER_FILE);
        // topics: two word pages and a path admitted early, a path admitted at TERMINAL - 3
        ledger.setRecord(WORD_A, WORD_TYPE, 7, 1);
        ledger.setRecord(WORD_B, WORD_TYPE, 7, 1);
        ledger.setRecord(PATH_AB, TOPIC_TYPE, 8, 64);
        ledger.setRecord(PATH_LATE, TOPIC_TYPE, TERMINAL - 3, 64);
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
        // PUBLISH/CREATE effects, FOLDER and HEAD removals and unnamed purposes are never judged
        Effect memory head = _bind(0, FILE, 0, 0, 0);
        head.purpose = Purpose.HEAD;
        head.kind = ActionKind.UNBIND;
        head.transitionKind = 3;
        _ok(_list(head));
        head.kind = ActionKind.RELEASE;
        head.transitionKind = 4;
        _ok(_list(head));
        Effect memory other = _bind(0, keccak256("anything"), 0, keccak256("anything"), 1);
        other.purpose = keccak256("efs/purpose/some-app/1");
        _ok(_list(other));
        other.targetKind = 3; // an address target is judged for HEAD and FOLDER only
        other.target = bytes32(uint256(0xBA5ED));
        _ok(_list(other));
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
        _bad(_list(_bind(0, bytes32(uint256(1) << 160), ROLE, FILE, 2)), 2, 0); // the lowest non-address word
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

    /// An ADDRESS target (kind 3): HEAD is refused with 7 and FOLDER with 6 (this profile's readers cannot serve
    /// either pointing at an address), TAG is admitted (its subject is a registered topic; the target is never
    /// judged), and a purpose the profile does not name is not judged.
    function test_address_targets_by_purpose() public {
        bytes32 addr = bytes32(uint256(uint160(address(0xADD))));
        Effect memory e = _bind(0, FILE, 0, addr, 3);
        e.purpose = Purpose.HEAD;
        _bad(_list(e), 7, 0);
        _bad(_list(_bind(0, PARENT, ROLE, addr, 3)), 6, 0);
        Effect memory t = _bind(0, WORD_A, addr, addr, 3);
        t.purpose = Purpose.TAG;
        _ok(_list(t));
        e.purpose = keccak256("third-party/purpose/1");
        _ok(_list(e));
        // the property purpose a later profile adds is another app's purpose here
        e.purpose = keccak256("efs/purpose/property/1");
        _ok(_list(e));
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

    // ---- HEAD: the target is a revision of the bind's own file -------------------------------------------------

    function _headBind(bytes32 file, bytes32 target, uint8 targetKind, uint8 transition)
        internal
        pure
        returns (Effect memory e)
    {
        e = _bind(0, file, 0, target, targetKind);
        e.purpose = Purpose.HEAD;
        e.transitionKind = transition;
    }

    function test_head_admits_a_revision_of_its_own_file() public {
        for (uint8 tk = 1; tk <= 5; tk += 1) {
            if (tk == 3 || tk == 4) continue; // MASK and RELEASE are not BIND-kind effects
            _ok(_list(_headBind(FILE, ROOT_REV, 1, tk)));
            _ok(_list(_headBind(FILE, CHILD_REV, 1, tk)));
        }
    }

    function test_head_refuses_anything_else() public {
        // another file's root; FILE's revisions under OTHER_FILE's HEAD
        _bad(_list(_headBind(FILE, OTHER_ROOT, 1, 1)), 8, 0);
        _bad(_list(_headBind(OTHER_FILE, ROOT_REV, 1, 1)), 8, 0);
        _bad(_list(_headBind(OTHER_FILE, CHILD_REV, 1, 1)), 8, 0);
        // a child whose word 0 (its parent revision) happens to be the subject is not the file word
        _bad(_list(_headBind(ROOT_REV, CHILD_REV, 1, 1)), 8, 0);
        // records of other Types: a name, a directory, an arbitrary record whose word 0 is the file
        _bad(_list(_headBind(FILE, Keys.recordFromHash(NAME_TYPE, ROLE), 1, 1)), 8, 0);
        _bad(_list(_headBind(FILE, PARENT, 1, 1)), 8, 0);
        bytes32 lookalike = keccak256("a record of another Type naming FILE");
        ledger.setRecord(lookalike, OTHER_TYPE, 5, 64);
        ledger.setBodyWord(lookalike, 0, FILE);
        _bad(_list(_headBind(FILE, lookalike, 1, 1)), 8, 0);
        // a subject target (the file itself, another file); a HEAD at a folder's record id
        _bad(_list(_headBind(FILE, FILE, 2, 1)), 8, 0);
        _bad(_list(_headBind(FILE, OTHER_FILE, 2, 1)), 8, 0);
        _bad(_list(_headBind(PARENT, ROOT_REV, 1, 1)), 8, 0);
        // judged on a re-bind and a restore too; an address keeps its own code
        _bad(_list(_headBind(FILE, OTHER_ROOT, 1, 2)), 8, 0);
        _bad(_list(_headBind(FILE, OTHER_ROOT, 1, 5)), 8, 0);
        _bad(_list(_headBind(FILE, bytes32(uint256(0xBA5ED)), 3, 1)), 7, 0);
        // a record target that is not a record at all (only a stub can claim kind 1 for it)
        _bad(_list(_headBind(FILE, keccak256("no such record"), 1, 1)), 8, 0);
        // a zero file word never matches, even for a zero subject: a root whose word 0 was never set
        bytes32 blank = keccak256("a root with no file word");
        ledger.setRecord(blank, ROOT_TYPE, 5, 69);
        _bad(_list(_headBind(bytes32(0), blank, 1, 1)), 8, 0);
        // a revision admitted after the terminal admission (only a stub can show this)
        bytes32 late = keccak256("a later root of FILE");
        ledger.setRecord(late, ROOT_TYPE, TERMINAL + 1, 69);
        ledger.setBodyWord(late, 0, FILE);
        _bad(_list(_headBind(FILE, late, 1, 1)), 8, 0);
    }

    // ---- homes ---------------------------------------------------------------------------------------------------

    function test_a_home_is_a_folder_parent() public {
        _ok(_list(_bind(0, bytes32(uint256(uint160(address(0xBEEF)))), ROLE, FILE, 2)));
        _ok(_list(_bind(0, bytes32(uint256(1)), ROLE, FILE, 2))); // a precompile: an ordinary home
        _ok(_list(_bind(0, bytes32(uint256(type(uint160).max)), ROLE, CHILD_DIR, 1)));
        // the other laws still hold under a home
        _bad(_list(_bind(0, bytes32(uint256(7)), keccak256("unnamed"), FILE, 2)), 1, 0);
        _bad(_list(_bind(0, bytes32(uint256(7)), ROLE, bytes32(uint256(7)), 3)), 3, 0);
        _bad(_list(_bind(0, bytes32(uint256(7)), ROLE, bytes32(uint256(8)), 3)), 6, 0);
    }

    // ---- TAG: a first statement stands on a registered topic or a home ------------------------------------------

    function _stmt(bytes32 purpose, bytes32 subject, bytes32 role, uint8 kind, uint8 transition)
        internal
        pure
        returns (Effect memory e)
    {
        e = _bind(0, subject, role, kind == ActionKind.BIND ? role : bytes32(0), 1);
        e.purpose = purpose;
        e.kind = kind;
        e.transitionKind = transition;
        if (kind != ActionKind.BIND) e.targetKind = 0;
    }

    function test_tag_first_statements() public {
        bytes32 thing = FILE;
        // a word page, a path, a home: admitted for a first assert and a first lone negative
        bytes32[3] memory ok = [WORD_A, PATH_AB, bytes32(uint256(uint160(address(0xBEEF))))];
        for (uint256 i; i < 3; ++i) {
            _ok(_list(_stmt(Purpose.TAG, ok[i], thing, ActionKind.BIND, 1)));
            _ok(_list(_stmt(Purpose.TAG, ok[i], thing, ActionKind.UNBIND, 6)));
        }
        // anything else: an unregistered word, a directory, a file subject, a name
        bytes32[4] memory bad =
            [keccak256("never registered"), PARENT, FILE, Keys.recordFromHash(NAME_TYPE, ROLE)];
        for (uint256 i; i < 4; ++i) {
            _bad(_list(_stmt(Purpose.TAG, bad[i], thing, ActionKind.BIND, 1)), 9, 0);
            _bad(_list(_stmt(Purpose.TAG, bad[i], thing, ActionKind.UNBIND, 6)), 9, 0);
        }
    }

    function test_tag_topic_must_be_registered_strictly_before() public {
        // _bind puts leaf 0 at TERMINAL - 5; PATH_LATE is admitted at TERMINAL - 3
        _bad(_list(_stmt(Purpose.TAG, PATH_LATE, FILE, ActionKind.BIND, 1)), 9, 0);
        Effect memory e = _stmt(Purpose.TAG, PATH_LATE, FILE, ActionKind.BIND, 1);
        e.admission = TERMINAL - 3; // the topic's own admission is not before it
        _bad(_list(e), 9, 0);
        e.admission = TERMINAL - 2; // one later: admitted
        _ok(_list(e));
    }

    /// Later transitions on an existing binding are never judged: an unregistered subject passes as a re-bind,
    /// a mask, a release and a restore (an author can always mask or release; a re-assert on an existing position
    /// creates nothing new).
    function test_tag_later_transitions_are_never_judged() public {
        bytes32 nowhere = keccak256("never registered");
        _ok(_list(_stmt(Purpose.TAG, nowhere, FILE, ActionKind.BIND, 2)));
        _ok(_list(_stmt(Purpose.TAG, nowhere, FILE, ActionKind.UNBIND, 3)));
        _ok(_list(_stmt(Purpose.TAG, nowhere, FILE, ActionKind.RELEASE, 4)));
        _ok(_list(_stmt(Purpose.TAG, nowhere, FILE, ActionKind.BIND, 5)));
    }

    // ---- SAME and BROADER --------------------------------------------------------------------------------------

    function test_relations_admitted_between_topics() public {
        bytes32[2] memory purposes = [Purpose.SAME, Purpose.BROADER];
        for (uint256 i; i < 2; ++i) {
            _ok(_list(_stmt(purposes[i], WORD_A, WORD_B, ActionKind.BIND, 1))); // word - word
            _ok(_list(_stmt(purposes[i], PATH_AB, WORD_A, ActionKind.BIND, 1))); // path - word
            _ok(_list(_stmt(purposes[i], WORD_B, PATH_AB, ActionKind.BIND, 1))); // word - path
            _ok(_list(_stmt(purposes[i], WORD_A, WORD_B, ActionKind.UNBIND, 6))); // a lone negative
        }
    }

    function test_relations_refused() public {
        bytes32[2] memory purposes = [Purpose.SAME, Purpose.BROADER];
        bytes32 nowhere = keccak256("never registered");
        for (uint256 i; i < 2; ++i) {
            bytes32 pu = purposes[i];
            _bad(_list(_stmt(pu, nowhere, WORD_B, ActionKind.BIND, 1)), 10, 0);
            _bad(_list(_stmt(pu, FILE, WORD_B, ActionKind.BIND, 1)), 10, 0);
            _bad(_list(_stmt(pu, bytes32(uint256(0xBEEF)), WORD_B, ActionKind.BIND, 1)), 10, 0); // no homes
            _bad(_list(_stmt(pu, WORD_A, nowhere, ActionKind.BIND, 1)), 11, 0);
            _bad(_list(_stmt(pu, WORD_A, PARENT, ActionKind.BIND, 1)), 11, 0);
            _bad(_list(_stmt(pu, WORD_A, WORD_A, ActionKind.BIND, 1)), 12, 0);
            _bad(_list(_stmt(pu, PATH_LATE, WORD_A, ActionKind.BIND, 1)), 10, 0); // registered later
            _bad(_list(_stmt(pu, WORD_A, PATH_LATE, ActionKind.BIND, 1)), 11, 0);
            // a lone negative needs two topics too
            _bad(_list(_stmt(pu, nowhere, WORD_B, ActionKind.UNBIND, 6)), 10, 0);
            _bad(_list(_stmt(pu, WORD_A, nowhere, ActionKind.UNBIND, 6)), 11, 0);
            _bad(_list(_stmt(pu, WORD_B, WORD_B, ActionKind.UNBIND, 6)), 12, 0);
            // every BIND names the role as its target: first, re-bind, restore
            for (uint8 tk = 1; tk <= 5; ++tk) {
                if (tk == 3 || tk == 4) continue;
                Effect memory e = _stmt(pu, WORD_A, WORD_B, ActionKind.BIND, tk);
                e.target = PATH_AB;
                _bad(_list(e), 13, 0);
            }
            // a mask and a release of an existing binding are never judged, whatever the ends
            _ok(_list(_stmt(pu, nowhere, nowhere, ActionKind.UNBIND, 3)));
            _ok(_list(_stmt(pu, nowhere, nowhere, ActionKind.RELEASE, 4)));
            // a re-bind is not a first statement: only the target law applies
            _ok(_list(_stmt(pu, nowhere, WORD_B, ActionKind.BIND, 2)));
        }
    }

    function test_property_is_not_judged() public {
        Effect memory e = _bind(0, FILE, keccak256("label:en"), bytes32(uint256(0xBA5ED)), 3);
        e.purpose = Purpose.PROPERTY;
        _ok(_list(e)); // an address value
        e.subject = keccak256("anything at all");
        e.target = keccak256("any record");
        e.targetKind = 1;
        _ok(_list(e));
    }

    // ---- shape -----------------------------------------------------------------------------------------------------

    function test_configuration_identity_and_fold() public view {
        assertEq(v.nameTypeId(), NAME_TYPE);
        assertEq(v.directoryTypeId(), DIR_TYPE);
        assertEq(v.rootTypeId(), ROOT_TYPE);
        assertEq(v.childTypeId(), CHILD_TYPE);
        assertEq(v.topicTypeId(), TOPIC_TYPE);
        assertEq(v.topicWordTypeId(), WORD_TYPE);
        assertEq(
            v.identity(),
            keccak256(
                abi.encode(
                    keccak256("efs/unit/files-final/1"),
                    NAME_TYPE,
                    DIR_TYPE,
                    ROOT_TYPE,
                    CHILD_TYPE,
                    TOPIC_TYPE,
                    WORD_TYPE
                )
            )
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
