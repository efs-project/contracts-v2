// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {E_INDEX_CALL} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";

/// @notice The HEAD law at admission (design §12.5): `FilesFinalValidator` refuses every BIND at HEAD whose target is
///         not a `files-root/1` record naming the bind's subject in word 0 or a `files-child/1` record naming it in
///         word 1 (code 8; an ADDRESS target keeps code 7), and every first "not this" at HEAD whose subject is not a
///         subject created strictly before it (code 16). Masks and releases of an existing HEAD are never judged. The readers' own
///         checks of a bad HEAD already on chain are in `FilesPageInvalidHeadsTest` and
///         `EfsWeb3GatewayInvalidHeadsTest`, on Realms without the validator.
contract HeadLawTest is FilesRecipesBase {
    address internal bob = makeAddr("head-law/bob");
    EfsFiles.Types internal t;
    bytes32 internal docs;
    bytes32 internal fileA;
    bytes32 internal aRoot;
    bytes32 internal aChild;
    bytes32 internal fileB;
    bytes32 internal bRoot;
    bytes32 internal bChild;

    function setUp() public override {
        super.setUp();
        t.root = typeIds[T_ROOT];
        t.child = typeIds[T_CHILD];
        t.directory = typeIds[T_DIRECTORY];
        t.name = typeIds[T_NAME];
        Action[] memory a;
        bytes[] memory b;
        (a, b, docs) = EfsFiles.createFolder(t, p, rootDir, keccak256("docs"), "docs", true);
        _execAs(address(this), a, b);
        (a, b, fileA, aRoot) =
            EfsFiles.createFile(t, p, docs, keccak256("a"), "a.txt", "alpha", true);
        _execAs(address(this), a, b);
        (a, b, aChild) = EfsFiles.edit(t, fileA, aRoot, "alpha 2", 1);
        _execAs(address(this), a, b);
        (a, b, fileB, bRoot) =
            EfsFiles.createFile(t, p, docs, keccak256("b"), "b.txt", "beta", true);
        _execAs(address(this), a, b);
        (a, b, bChild) = EfsFiles.edit(t, fileB, bRoot, "beta 2", 1);
        _execAs(address(this), a, b);
    }

    function execExternal(address who, Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _execAs(who, a, b);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _refused(address who, Action[] memory a, bytes[] memory b, uint8 code, uint8 leaf)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector, abi.encodeWithSelector(E_FILES_FINAL.selector, code, leaf)
            )
        );
        this.execExternal(who, a, b);
    }

    function _head(bytes32 file, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return EfsFiles.bind(Purpose.HEAD, file, 0, target, expected);
    }

    function test_a_head_at_a_folder_id_is_refused() public {
        // no revision can name a folder record: a root needs a created subject, a child inherits its file
        _refused(bob, _one(_head(docs, aRoot, 0)), new bytes[](1), 8, 0);
        _refused(bob, _one(_head(rootDir, aChild, 0)), new bytes[](1), 8, 0);
    }

    function test_a_head_to_another_files_revision_is_refused() public {
        _refused(bob, _one(_head(fileA, bRoot, 0)), new bytes[](1), 8, 0);
        _refused(bob, _one(_head(fileA, bChild, 0)), new bytes[](1), 8, 0);
        // and a re-bind of the creator's own HEAD (revision 2) to B's revision
        _refused(address(this), _one(_head(fileA, bRoot, 2)), new bytes[](1), 8, 0);
    }

    function test_a_head_to_a_non_revision_record_or_a_subject_is_refused() public {
        bytes32 nameRec = Keys.recordFromHash(t.name, keccak256("a.txt"));
        // a content descriptor: chunk + files-content/1 carrier 0
        bytes memory chunkBody = EfsFiles.bytesBody("descriptor payload");
        bytes32 chunk = Keys.record(typeIds[T_BYTES], chunkBody);
        EfsFiles.Content memory c;
        c.bytesRef = chunk;
        c.version = 1;
        c.hashAlg = 1;
        c.length = 18;
        c.sha256Digest = sha256("descriptor payload");
        c.plaintextLength = 18;
        c.plaintextSha256OrZero = c.sha256Digest;
        bytes memory contentBody = EfsFiles.contentBody(c);
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = _publish(T_BYTES, chunkBody);
        (a[1], b[1]) = _publish(T_CONTENT, contentBody);
        _execAs(address(this), a, b);
        bytes32 content = Keys.record(typeIds[T_CONTENT], contentBody);
        bytes32[5] memory targets = [nameRec, content, docs, fileA, fileB];
        for (uint256 i; i < targets.length; ++i) {
            _refused(bob, _one(_head(fileA, targets[i], 0)), new bytes[](1), 8, 0);
        }
    }

    /// A record of another Type whose word 0 is the subject (a `directory-alias/1` to the file) is not a revision.
    function test_a_lookalike_record_naming_the_file_is_refused() public {
        bytes memory body = EfsFiles.aliasBody(fileA, EfsFiles.ALIAS_FILE);
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = _publish(T_ALIAS, body);
        a[1] = _head(fileA, Keys.record(typeIds[T_ALIAS], body), 0);
        _refused(bob, a, b, 8, 1);
    }

    function test_own_revisions_are_admitted_by_the_creator_and_by_another_author() public {
        // bob's lens of fileA: a root and a child of fileA itself
        _execAs(bob, _one(_head(fileA, aRoot, 0)), new bytes[](1));
        _execAs(bob, _one(_head(fileA, aChild, 1)), new bytes[](1));
        // bob's own child of fileA, published and bound in one publication
        bytes memory body = EfsFiles.childBody(aChild, fileA, "bob's edit");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = _publish(T_CHILD, body);
        a[1] = _head(fileA, Keys.record(t.child, body), 2);
        _execAs(bob, a, b);
        // the creator: back to the root (a re-bind)
        _execAs(address(this), _one(_head(fileA, aRoot, 2)), new bytes[](1));
    }

    /// A restore is judged; a mask and a release are not.
    function test_restore_is_judged_mask_and_release_are_not() public {
        _execAs(address(this), _one(EfsFiles.unbind(Purpose.HEAD, fileA, 0, 2)), new bytes[](1));
        _refused(address(this), _one(_head(fileA, bRoot, 3)), new bytes[](1), 8, 0);
        _execAs(address(this), _one(_head(fileA, aChild, 3)), new bytes[](1)); // restore to its own child
        _execAs(address(this), _one(EfsFiles.release(Purpose.HEAD, fileA, 0, 4)), new bytes[](1));
        _refused(address(this), _one(_head(fileA, bChild, 5)), new bytes[](1), 8, 0);
    }

    // ---- code 16: a first "not this" at HEAD names a file (a subject created strictly before it) ---------------

    function _lone(bytes32 subject) internal pure returns (Action memory) {
        return EfsFiles.loneNegative(Purpose.HEAD, subject, 0, 0);
    }

    function test_a_lone_head_mask_on_an_id_that_names_nothing_is_refused() public {
        _refused(bob, _one(_lone(keccak256("head-law/nothing"))), new bytes[](1), 16, 0);
    }

    /// A folder is a directory record, not a created subject: no revision can name it (code 8), so no "not this" either.
    function test_a_lone_head_mask_on_a_folder_record_is_refused() public {
        _refused(bob, _one(_lone(docs)), new bytes[](1), 16, 0);
    }

    function test_a_lone_head_mask_on_an_address_is_refused() public {
        _refused(bob, _one(_lone(bytes32(uint256(uint160(bob))))), new bytes[](1), 16, 0);
        _refused(bob, _one(_lone(bytes32(uint256(1)))), new bytes[](1), 16, 0);
    }

    /// A file created earlier: another author's first "not this" about it is admitted.
    function test_a_lone_head_mask_on_a_file_created_earlier_is_admitted() public {
        _execAs(bob, _one(_lone(fileB)), new bytes[](1));
        // and the same author can later bind a version of it (a restore from MASKED is judged by code 8)
        _execAs(bob, _one(_head(fileB, bChild, 1)), new bytes[](1));
    }

    /// A file created earlier in the same publication counts; one created later in it does not (strictly before).
    function test_a_lone_head_mask_on_a_file_created_in_the_same_publication() public {
        bytes32 salt = keccak256("head-law/same-publication");
        bytes32 file = Keys.subject(Keys.principal(bob), salt);
        Action[] memory a = new Action[](2);
        a[0] = _create(salt);
        a[1] = _lone(file);
        _execAs(bob, a, new bytes[](2));
        bytes32 salt2 = keccak256("head-law/created-after");
        bytes32 later = Keys.subject(Keys.principal(bob), salt2);
        a[0] = _lone(later);
        a[1] = _create(salt2);
        _refused(bob, a, new bytes[](2), 16, 0);
    }

    /// The cost of a lone HEAD "not this" about a file another author created (one publication, logged as
    /// `head lone mask on a file gas` / `frame gas`): code 16 adds one `subjectCreatedAt` read to the final phase.
    function test_measure_a_lone_head_mask_on_a_file() public {
        bytes32 salt = keccak256("head-law/measured");
        _execAs(bob, _one(_create(salt)), new bytes[](1));
        _exec(
            "head lone mask on a file",
            _one(_lone(Keys.subject(Keys.principal(bob), salt))),
            new bytes[](1)
        );
    }

    /// The standing invariant: an author with a HEAD on a file can always mask and release it (MASK and RELEASE are
    /// never judged), and that holds for a file's creator and for another author alike.
    function test_an_existing_head_can_always_be_masked_and_released() public {
        _execAs(bob, _one(_head(fileA, aRoot, 0)), new bytes[](1));
        _execAs(bob, _one(EfsFiles.unbind(Purpose.HEAD, fileA, 0, 1)), new bytes[](1));
        _execAs(bob, _one(EfsFiles.release(Purpose.HEAD, fileA, 0, 2)), new bytes[](1));
        _execAs(address(this), _one(EfsFiles.unbind(Purpose.HEAD, fileB, 0, 2)), new bytes[](1));
        _execAs(address(this), _one(EfsFiles.release(Purpose.HEAD, fileB, 0, 3)), new bytes[](1));
    }
}
