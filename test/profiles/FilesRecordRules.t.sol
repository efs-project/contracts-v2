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
///         onto a rule (the placement cases belong to `FilesFinalValidator` and the recipes), plus the context check
///         and the revision `form` word of docs/LARGE-FILES.md (0 inline bytes, 1 one word naming a descriptor).
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
    bytes32 internal constant CONTENT_TYPE = keccak256("test/files/content-type");
    bytes32 internal constant EXTERNAL_TYPE = keccak256("test/files/external-type");
    bytes32 internal constant CONTENT_REC = keccak256("a files-content/1 record");
    bytes32 internal constant EXTERNAL_REC = keccak256("a files-external/1 record");
    bytes32 internal constant DIR_REC = keccak256("a files-directory/1 record");

    function setUp() public override {
        super.setUp();
        root = new FilesRootRule(CONTENT_TYPE, EXTERNAL_TYPE);
        child = new FilesChildRule(ROOT_TYPE, CONTENT_TYPE, EXTERNAL_TYPE);
        directory = new FilesDirectoryRule();
        alias_ = new DirectoryAliasRule(DIR_TYPE);
        stub.setSubject(FILE, 10);
        stub.setSubject(OTHER_FILE, 11);
        stub.setRecord(CONTENT_REC, CONTENT_TYPE, 5, 320);
        stub.setRecord(EXTERNAL_REC, EXTERNAL_TYPE, 6, 240);
        stub.setRecord(DIR_REC, DIR_TYPE, 6, 64);
    }

    /// Form 0 (INLINE): `[file, 0] ‖ document`.
    function _root(bytes32 file, bytes memory document) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(file, uint256(0)), document);
    }

    /// Form 1 (CONTENT): `[file, 1, descriptor]`.
    function _rootRef(bytes32 file, bytes32 descriptor) internal pure returns (bytes memory) {
        return abi.encode(file, uint256(1), descriptor);
    }

    function _child(bytes32 parent, bytes32 file, bytes memory document)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(abi.encode(parent, file, uint256(0)), document);
    }

    function _childRef(bytes32 parent, bytes32 file, bytes32 descriptor)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(parent, file, uint256(1), descriptor);
    }

    // ---- files-root/1 -----------------------------------------------------------------------------------------

    function test_root_accepts_an_existing_file_with_any_document() public {
        _accepts(root, _ctx(), _root(FILE, "Meeting at 10:00.\n"), _none(), _noHeaders());
        _accepts(root, _ctx(), abi.encode(FILE, uint256(0)), _none(), _noHeaders()); // the empty document
        _accepts(root, _ctx(), _root(FILE, new bytes(8128)), _none(), _noHeaders()); // an 8,192-byte body
        // the rule has no upper bound of its own (the Realm's maxBody is the bound)
        _accepts(root, _ctx(), _root(FILE, new bytes(9000)), _none(), _noHeaders());
    }

    function test_root_form_1_names_an_admitted_descriptor() public {
        _accepts(root, _ctx(), _rootRef(FILE, CONTENT_REC), _none(), _noHeaders());
        _accepts(root, _ctx(), _rootRef(FILE, EXTERNAL_REC), _none(), _noHeaders());
        // a missing record, a record of another Type, a zero id
        _refuses(
            root, _ctx(), _rootRef(FILE, keccak256("no such record")), _none(), _noHeaders(), 7
        );
        _refuses(root, _ctx(), _rootRef(FILE, DIR_REC), _none(), _noHeaders(), 7);
        _refuses(root, _ctx(), _rootRef(FILE, bytes32(0)), _none(), _noHeaders(), 7);
        // a descriptor Type's header with no admission (never stored) is not admitted
        bytes32 ghost = keccak256("ghost");
        stub.setRecord(ghost, CONTENT_TYPE, 0, 320);
        _refuses(root, _ctx(), _rootRef(FILE, ghost), _none(), _noHeaders(), 7);
        // form 1 is exactly three words
        _refuses(root, _ctx(), abi.encode(FILE, uint256(1)), _none(), _noHeaders(), 6);
        _refuses(
            root,
            _ctx(),
            bytes.concat(_rootRef(FILE, CONTENT_REC), hex"00"),
            _none(),
            _noHeaders(),
            6
        );
        _refuses(
            root,
            _ctx(),
            bytes.concat(_rootRef(FILE, CONTENT_REC), abi.encode(EXTERNAL_REC)),
            _none(),
            _noHeaders(),
            6
        );
        // form 0 never reads the ledger: a body that looks like a form-1 body with form 0 is just bytes
        _accepts(
            root,
            _ctx(),
            abi.encode(FILE, uint256(0), keccak256("no such record")),
            _none(),
            _noHeaders()
        );
    }

    function test_root_unknown_forms_refused() public {
        _refuses(root, _ctx(), abi.encode(FILE, uint256(2)), _none(), _noHeaders(), 5);
        _refuses(root, _ctx(), abi.encode(FILE, uint256(2), CONTENT_REC), _none(), _noHeaders(), 5);
        _refuses(
            root, _ctx(), abi.encode(FILE, type(uint256).max, CONTENT_REC), _none(), _noHeaders(), 5
        );
        _refuses(root, _ctx(), bytes.concat(abi.encode(FILE), hex"01"), _none(), _noHeaders(), 2);
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
        _refuses(
            child,
            _ctx(),
            abi.encode(PARENT, FILE),
            _one(PARENT),
            _header(ROOT_TYPE, 32, FILE, 0, 0),
            2
        ); // no form word
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
        FilesChildRule other = new FilesChildRule(OTHER_TYPE, CONTENT_TYPE, EXTERNAL_TYPE);
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

    function test_child_form_1_names_an_admitted_descriptor() public {
        RefHeader[] memory rootParent = _header(ROOT_TYPE, 64, FILE, 0, 0);
        _accepts(child, _ctx(), _childRef(PARENT, FILE, CONTENT_REC), _one(PARENT), rootParent);
        _accepts(child, _ctx(), _childRef(PARENT, FILE, EXTERNAL_REC), _one(PARENT), rootParent);
        // a child parent works alike (the parent law is unchanged)
        _accepts(
            child,
            _ctx(),
            _childRef(PARENT, FILE, CONTENT_REC),
            _one(PARENT),
            _header(SELF_TYPE, 128, keccak256("gp"), FILE, 0)
        );
        _refuses(
            child,
            _ctx(),
            _childRef(PARENT, FILE, keccak256("no such record")),
            _one(PARENT),
            rootParent,
            10
        );
        _refuses(child, _ctx(), _childRef(PARENT, FILE, DIR_REC), _one(PARENT), rootParent, 10);
        _refuses(child, _ctx(), _childRef(PARENT, FILE, PARENT), _one(PARENT), rootParent, 10);
        _refuses(child, _ctx(), abi.encode(PARENT, FILE, uint256(1)), _one(PARENT), rootParent, 9);
        _refuses(
            child,
            _ctx(),
            bytes.concat(_childRef(PARENT, FILE, CONTENT_REC), hex"00"),
            _one(PARENT),
            rootParent,
            9
        );
        // the parent law runs first: a form-1 body with a wrong parent is a parent refusal
        _refuses(
            child,
            _ctx(),
            _childRef(PARENT, FILE, CONTENT_REC),
            _one(PARENT),
            _header(ROOT_TYPE, 64, OTHER_FILE, 0, 0),
            5
        );
    }

    function test_child_unknown_forms_refused() public {
        RefHeader[] memory rootParent = _header(ROOT_TYPE, 64, FILE, 0, 0);
        _refuses(child, _ctx(), abi.encode(PARENT, FILE, uint256(2)), _one(PARENT), rootParent, 8);
        _refuses(
            child,
            _ctx(),
            abi.encode(PARENT, FILE, type(uint256).max, CONTENT_REC),
            _one(PARENT),
            rootParent,
            8
        );
        // form 0 with an empty document is the smallest revision
        _accepts(child, _ctx(), abi.encode(PARENT, FILE, uint256(0)), _one(PARENT), rootParent);
    }

    function test_form_rules_read_only_the_named_header() public {
        // the descriptor Type ids are constructor state: another pair rejects the same descriptor
        FilesRootRule other = new FilesRootRule(keccak256("x"), keccak256("y"));
        assertEq(address(other).codehash, address(root).codehash, "one runtime for every pair");
        assertEq(root.contentTypeId(), CONTENT_TYPE);
        assertEq(root.externalTypeId(), EXTERNAL_TYPE);
        assertEq(child.contentTypeId(), CONTENT_TYPE);
        assertEq(child.externalTypeId(), EXTERNAL_TYPE);
        _refuses(other, _ctx(), _rootRef(FILE, CONTENT_REC), _none(), _noHeaders(), 7);
    }

    function test_child_context_is_authenticated() public {
        _contextIsAuthenticated(
            child, _child(PARENT, FILE, "doc"), _one(PARENT), _header(ROOT_TYPE, 32, FILE, 0, 0)
        );
    }

    // ---- files-directory/1 ------------------------------------------------------------------------------------

    /// `files-directory/1` is `abi.encode(creatorPrincipal, salt)`: the creator is the publishing principal.
    function _dir(bytes32 creator, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encode(creator, salt);
    }

    function test_directory_accepts_the_creator_with_any_nonzero_salt() public {
        AcceptContext memory c = _ctx();
        _accepts(directory, c, _dir(c.principalId, keccak256("docs")), _none(), _noHeaders());
        _accepts(directory, c, _dir(c.principalId, bytes32(uint256(1))), _none(), _noHeaders());
        _accepts(
            directory, c, _dir(c.principalId, bytes32(type(uint256).max)), _none(), _noHeaders()
        );
        // the rule reads nothing from the ledger: a creator word that is also a created subject changes nothing
        c.principalId = FILE;
        _accepts(directory, c, _dir(FILE, keccak256("docs")), _none(), _noHeaders());
    }

    /// The spoof: a principal other than the creator word publishes `(alice, salt)`.
    function test_directory_refuses_a_creator_word_that_is_not_the_publisher() public {
        bytes32 alice = keccak256("alice");
        AcceptContext memory c = _ctx();
        _refuses(directory, c, _dir(alice, keccak256("docs")), _none(), _noHeaders(), 4);
        // nor can it name someone's FILE subject (or any id) as the creator
        _refuses(directory, c, _dir(FILE, keccak256("docs")), _none(), _noHeaders(), 4);
        _refuses(directory, c, _dir(bytes32(0), keccak256("docs")), _none(), _noHeaders(), 4);
        // Alice herself is admitted
        c.principalId = alice;
        _accepts(directory, c, _dir(alice, keccak256("docs")), _none(), _noHeaders());
    }

    function testFuzz_directory_admits_exactly_the_creators_two_words(
        bytes32 principal,
        bytes calldata body
    ) public {
        AcceptContext memory c = _ctx();
        c.principalId = principal;
        bool ok = body.length == 64 && bytes32(body[32:64]) != 0 && bytes32(body[0:32]) == principal;
        if (ok) {
            _accepts(directory, c, body, _none(), _noHeaders());
        } else {
            uint8 code = body.length != 64 ? 2 : bytes32(body[32:64]) == 0 ? 3 : 4;
            _refuses(directory, c, body, _none(), _noHeaders(), code);
        }
    }

    // L FilesDirectory test_directory_exact_body_length_required (the body is now exactly two words)
    function test_directory_zero_salt_wrong_length_and_refs_refused() public {
        bytes32 me = _ctx().principalId;
        _refuses(directory, _ctx(), _dir(me, 0), _none(), _noHeaders(), 3);
        _refuses(directory, _ctx(), abi.encode(me), _none(), _noHeaders(), 2); // the old one-word body
        _refuses(directory, _ctx(), bytes("x"), _none(), _noHeaders(), 2);
        _refuses(directory, _ctx(), "", _none(), _noHeaders(), 2);
        _refuses(
            directory,
            _ctx(),
            bytes.concat(_dir(me, keccak256("d")), hex"ff"),
            _none(),
            _noHeaders(),
            2
        );
        _refuses(directory, _ctx(), abi.encode(me, keccak256("d"), me), _none(), _noHeaders(), 2);
        _refuses(directory, _ctx(), _dir(me, keccak256("d")), _one(PARENT), _noHeaders(), 1);
    }

    function test_directory_context_is_authenticated() public {
        _contextIsAuthenticated(
            directory, _dir(_ctx().principalId, keccak256("d")), _none(), _noHeaders()
        );
    }

    /// A folder's id is a record, never a created subject: a `files-root/1` whose file word is a folder record
    /// is refused (code 4, the subject was never created), so nobody can give a folder a HEAD revision.
    function test_root_refuses_a_folder_record_as_its_file() public {
        _refuses(root, _ctx(), _root(DIR_REC, "x"), _none(), _noHeaders(), 4);
        _refuses(root, _ctx(), _rootRef(DIR_REC, CONTENT_REC), _none(), _noHeaders(), 4);
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
