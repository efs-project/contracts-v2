// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesRootRule} from "../../src/profiles/FilesRootRule.sol";
import {FilesChildRule} from "../../src/profiles/FilesChildRule.sol";
import {FilesDirectoryRule} from "../../src/profiles/FilesDirectoryRule.sol";
import {DirectoryAliasRule} from "../../src/profiles/DirectoryAliasRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `files-root/1`, `files-child/1`, `files-directory/1` and `directory-alias/1` against a stub ledger:
///         every rule-level case of the prototype's `FilesJoined.t.sol` and `FilesDirectoryProfile.t.sol` that maps
///         onto a rule (the placement cases belong to `FilesFinalValidator` and the recipes), plus the context check.
contract FilesRecordRulesTest is FilesUnitBase {
    FilesRootRule internal root;
    FilesChildRule internal child;
    FilesDirectoryRule internal directory;
    DirectoryAliasRule internal alias_;

    bytes32 internal constant ROOT_TYPE = keccak256("test/files/root-type");
    bytes32 internal constant DIR_TYPE = keccak256("test/files/directory-type");
    bytes32 internal constant OTHER_TYPE = keccak256("test/files/binary-type");
    bytes32 internal constant FILE = keccak256("file subject");
    bytes32 internal constant OTHER_FILE = keccak256("other file subject");
    bytes32 internal constant PARENT = keccak256("parent record");

    function setUp() public override {
        super.setUp();
        root = new FilesRootRule();
        child = new FilesChildRule(ROOT_TYPE);
        directory = new FilesDirectoryRule();
        alias_ = new DirectoryAliasRule(DIR_TYPE);
        stub.setSubject(FILE, 10);
        stub.setSubject(OTHER_FILE, 11);
    }

    function _root(bytes32 file, bytes memory document) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(file), document);
    }

    function _child(bytes32 parent, bytes32 file, bytes memory document)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(abi.encode(parent, file), document);
    }

    // ---- files-root/1 -----------------------------------------------------------------------------------------

    function test_root_accepts_an_existing_file_with_any_document() public {
        _accepts(root, _ctx(), _root(FILE, "Meeting at 10:00.\n"), _none(), _noHeaders());
        _accepts(root, _ctx(), abi.encode(FILE), _none(), _noHeaders()); // the empty document
        _accepts(root, _ctx(), _root(FILE, new bytes(8160)), _none(), _noHeaders()); // the largest body
    }

    // L FilesJoined test_root_requires_existing_nonzero_file_and_shape
    function test_root_requires_existing_nonzero_file_and_shape() public {
        _refuses(root, _ctx(), bytes("short"), _none(), _noHeaders(), 2);
        _refuses(root, _ctx(), new bytes(31), _none(), _noHeaders(), 2);
        _refuses(root, _ctx(), _root(0, "zero"), _none(), _noHeaders(), 3);
        _refuses(
            root, _ctx(), _root(keccak256("missing Subject"), "missing"), _none(), _noHeaders(), 4
        );
        _refuses(root, _ctx(), _root(FILE, "x"), _one(PARENT), _noHeaders(), 1);
        _refuses(root, _ctx(), _root(FILE, "x"), _none(), _header(OTHER_TYPE, 32, 0, 0, 0), 1);
    }

    function test_root_context_is_authenticated() public {
        _contextIsAuthenticated(root, _root(FILE, "doc"), _none(), _noHeaders());
    }

    // ---- files-child/1 ----------------------------------------------------------------------------------------

    function test_child_accepts_root_and_child_parents_of_the_same_file() public {
        // a root parent: word0 is the file
        _accepts(
            child,
            _ctx(),
            _child(PARENT, FILE, "Meeting at 11:00.\n"),
            _one(PARENT),
            _header(ROOT_TYPE, 50, FILE, "doc", 0)
        );
        // a root parent that is exactly one word (an empty first revision)
        _accepts(
            child,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(ROOT_TYPE, 32, FILE, 0, 0)
        );
        // a child parent (this very Type): word1 is the file
        _accepts(
            child,
            _ctx(),
            _child(PARENT, FILE, "grandchild"),
            _one(PARENT),
            _header(SELF_TYPE, 64, keccak256("grandparent"), FILE, 0)
        );
        // cold large headers: only the header words matter (L test_cold_large_root_and_child_headers_accept)
        _accepts(
            child,
            _ctx(),
            _child(PARENT, FILE, new bytes(8128)),
            _one(PARENT),
            _header(ROOT_TYPE, 8192, FILE, 0, 0)
        );
    }

    // L FilesJoined test_missing_unrelated_and_wrong_file_parents_roll_back (the rule-level half; a missing
    // parent is the kernel's E_REF(leaf, 0, 1) and is covered by FilesRecipes)
    function test_child_refuses_unrelated_and_wrong_file_parents() public {
        // an unrelated Type whose word0 is the file: a wildcard reference is not an arbitrary acceptable parent
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, "unrelated"),
            _one(PARENT),
            _header(OTHER_TYPE, 64, FILE, FILE, 0),
            7
        );
        // another file's root and another file's child
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, "wrong Root File"),
            _one(PARENT),
            _header(ROOT_TYPE, 40, OTHER_FILE, 0, 0),
            5
        );
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, "wrong Child File"),
            _one(PARENT),
            _header(SELF_TYPE, 70, keccak256("gp"), OTHER_FILE, 0),
            6
        );
        // the root law reads word0, the child law word1: a root whose word1 is the file is not enough
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(ROOT_TYPE, 64, OTHER_FILE, FILE, 0),
            5
        );
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(SELF_TYPE, 64, FILE, OTHER_FILE, 0),
            6
        );
        // a child parent shorter than two words and a root parent shorter than one word
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(SELF_TYPE, 63, 0, FILE, 0),
            6
        );
        _refuses(
            child,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(ROOT_TYPE, 31, FILE, 0, 0),
            5
        );
        // zero file, a missing file (no parent holds it) and the one-word body
        _refuses(
            child,
            _ctx(),
            _child(PARENT, 0, "zero File"),
            _one(PARENT),
            _header(ROOT_TYPE, 32, 0, 0, 0),
            4
        );
        _refuses(
            child,
            _ctx(),
            _child(PARENT, keccak256("missing File"), "missing File"),
            _one(PARENT),
            _header(ROOT_TYPE, 32, FILE, 0, 0),
            5
        );
        _refuses(
            child, _ctx(), abi.encode(PARENT), _one(PARENT), _header(ROOT_TYPE, 32, FILE, 0, 0), 2
        );
        // body word 0 must be the checked reference itself
        _refuses(
            child,
            _ctx(),
            _child(keccak256("elsewhere"), FILE, ""),
            _one(PARENT),
            _header(ROOT_TYPE, 32, FILE, 0, 0),
            3
        );
        // exactly one ref and one header
        _refuses(
            child, _ctx(), _child(PARENT, FILE, ""), _none(), _header(ROOT_TYPE, 32, FILE, 0, 0), 1
        );
        _refuses(child, _ctx(), _child(PARENT, FILE, ""), _one(PARENT), _noHeaders(), 1);
    }

    function test_child_root_type_is_constructor_state() public {
        assertEq(child.rootTypeId(), ROOT_TYPE);
        FilesChildRule other = new FilesChildRule(OTHER_TYPE);
        assertEq(
            address(other).codehash, address(child).codehash, "one runtime for every root Type"
        );
        // the same body and header: accepted under the instance pinned to that root Type only
        _accepts(
            other,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(OTHER_TYPE, 32, FILE, 0, 0)
        );
        _refuses(
            other,
            _ctx(),
            _child(PARENT, FILE, ""),
            _one(PARENT),
            _header(ROOT_TYPE, 32, FILE, 0, 0),
            7
        );
    }

    function test_child_context_is_authenticated() public {
        _contextIsAuthenticated(
            child, _child(PARENT, FILE, "doc"), _one(PARENT), _header(ROOT_TYPE, 32, FILE, 0, 0)
        );
    }

    // ---- files-directory/1 ------------------------------------------------------------------------------------

    function test_directory_accepts_a_seed_created_at_or_before_the_admission() public {
        _accepts(directory, _ctx(), abi.encode(FILE), _none(), _noHeaders());
        bytes32 seed = keccak256("same-admission seed");
        stub.setSubject(seed, ADMISSION);
        _accepts(directory, _ctx(), abi.encode(seed), _none(), _noHeaders());
    }

    // L FilesDirectory test_missing_zero_and_wrong_length_directory_seeds_rejected,
    // test_directory_exact_body_length_required
    function test_directory_missing_zero_wrong_length_and_late_seeds_refused() public {
        _refuses(directory, _ctx(), abi.encode(bytes32(0)), _none(), _noHeaders(), 3);
        _refuses(directory, _ctx(), abi.encode(bytes32(uint256(999))), _none(), _noHeaders(), 4);
        _refuses(directory, _ctx(), bytes("x"), _none(), _noHeaders(), 2);
        _refuses(
            directory, _ctx(), bytes.concat(abi.encode(FILE), hex"ff"), _none(), _noHeaders(), 2
        );
        _refuses(directory, _ctx(), abi.encode(FILE, FILE), _none(), _noHeaders(), 2);
        bytes32 late = keccak256("created after this admission");
        stub.setSubject(late, ADMISSION + 1);
        _refuses(directory, _ctx(), abi.encode(late), _none(), _noHeaders(), 4);
        _refuses(directory, _ctx(), abi.encode(FILE), _one(PARENT), _noHeaders(), 1);
    }

    function test_directory_context_is_authenticated() public {
        _contextIsAuthenticated(directory, abi.encode(FILE), _none(), _noHeaders());
    }

    // ---- directory-alias/1 ------------------------------------------------------------------------------------

    function test_alias_targets_a_directory_record_or_a_file_subject() public {
        bytes32 dir = keccak256("a directory record");
        stub.setRecord(dir, DIR_TYPE, 5, 32);
        _accepts(alias_, _ctx(), abi.encode(dir, uint256(1)), _none(), _noHeaders());
        _accepts(alias_, _ctx(), abi.encode(FILE, uint256(2)), _none(), _noHeaders());
    }

    function test_alias_never_targets_a_name_or_a_missing_object() public {
        bytes32 nameRecord = keccak256("a files-name/2 record");
        stub.setRecord(nameRecord, keccak256("test/files/name-type"), 5, 9);
        _refuses(alias_, _ctx(), abi.encode(nameRecord, uint256(1)), _none(), _noHeaders(), 5);
        _refuses(
            alias_,
            _ctx(),
            abi.encode(keccak256("no such record"), uint256(1)),
            _none(),
            _noHeaders(),
            5
        );
        // a record is not a file subject, and a subject is not a directory record
        _refuses(alias_, _ctx(), abi.encode(nameRecord, uint256(2)), _none(), _noHeaders(), 6);
        _refuses(alias_, _ctx(), abi.encode(FILE, uint256(1)), _none(), _noHeaders(), 5);
        _refuses(alias_, _ctx(), abi.encode(bytes32(0), uint256(2)), _none(), _noHeaders(), 3);
        _refuses(alias_, _ctx(), abi.encode(FILE, uint256(0)), _none(), _noHeaders(), 4);
        _refuses(alias_, _ctx(), abi.encode(FILE, uint256(3)), _none(), _noHeaders(), 4);
        _refuses(alias_, _ctx(), abi.encode(FILE), _none(), _noHeaders(), 2);
        _refuses(
            alias_,
            _ctx(),
            bytes.concat(abi.encode(FILE, uint256(2)), hex"00"),
            _none(),
            _noHeaders(),
            2
        );
        _refuses(alias_, _ctx(), abi.encode(FILE, uint256(2)), _one(PARENT), _noHeaders(), 1);
    }

    function test_alias_context_is_authenticated() public {
        _contextIsAuthenticated(alias_, abi.encode(FILE, uint256(2)), _none(), _noHeaders());
    }

    // ---- code shape -------------------------------------------------------------------------------------------

    function test_record_rules_are_plain_runtimes() public {
        _codeChecks(address(root), "FilesRootRule");
        _codeChecks(address(child), "FilesChildRule");
        _codeChecks(address(directory), "FilesDirectoryRule");
        _codeChecks(address(alias_), "DirectoryAliasRule");
    }
}
