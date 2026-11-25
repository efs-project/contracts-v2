// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Coordinate, Purpose} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Qualified, Status} from "../../src/interfaces/Results.sol";
import {Selection} from "../../src/interfaces/Readers.sol";
import {Effect} from "../../src/interfaces/Index.sol";
import {E_INDEX_CALL, E_TARGET_MISSING} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {LensReader} from "../../src/readers/LensReader.sol";

/// @notice SPIKE (tags/topics, Part C): target kind 3 = ADDRESS. A nonzero address-shaped target that is neither a
///         record nor a subject is admitted with `targetKind = 3` ("this address is a phishing site"), and the
///         readers that judged kinds 1/2 only accept it. A file revision is already a record, so it is a target too.
contract AddressTargetsTest is FilesRecipesBase {
    address internal phisher = makeAddr("address-targets/phisher");
    bytes32 internal target;
    bytes32 internal topic;
    LensReader internal lens;

    function setUp() public override {
        super.setUp();
        target = bytes32(uint256(uint160(phisher)));
        (Action memory w, bytes memory wb) = _wordPage("phishing");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = (w, wb);
        _execAs(address(this), a, b);
        topic = _wordId("phishing");
        lens = new LensReader(
            address(r.ledger), address(new LedgerViews()), address(new LedgerReads())
        );
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function execExternal(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _execAs(address(this), a, b);
    }

    function test_assert_and_lone_negative_on_a_fresh_address() public {
        assertEq(phisher.code.length, 0);
        assertEq(phisher.balance, 0);
        (uint64 nonce,) = r.hot.nonceOf(Keys.principal(phisher));
        assertEq(nonce, 0, "no history");
        (bytes32 t, uint64 first,,,) = r.hot.recordHeader(target);
        assertEq(abi.encode(t, first), abi.encode(bytes32(0), uint64(0)), "not a record");
        assertEq(r.hot.subjectCreatedAt(target), 0, "not a subject");

        // assert: (TAG, /phishing, role = address) -> address, number +3
        Action memory a = _bind(Purpose.TAG, topic, target, target, 0);
        a.salt = bytes32(uint256(3));
        uint64 pub = _execAs(address(this), _one(a), new bytes[](1));
        (uint8 st,,, uint8 kind,,, bytes32 got) = r.hot.head(_key(Purpose.TAG, topic, target));
        assertEq(abi.encode(st, kind, got), abi.encode(uint8(1), uint8(3), target));
        _assertBacklink(target, 1, 1);

        // a lone negative on the same address under another topic (no target: role = address)
        (Action memory w, bytes memory wb) = _wordPage("trusted");
        Action[] memory n = new Action[](2);
        bytes[] memory nb = new bytes[](2);
        (n[0], nb[0]) = (w, wb);
        n[1] = _bindKind(ActionKind.UNBIND, Purpose.TAG, _wordId("trusted"), target, 0, 0);
        _execAs(address(this), n, nb);
        (st,,, kind,,,) = r.hot.head(_key(Purpose.TAG, _wordId("trusted"), target));
        assertEq(abi.encode(st, kind), abi.encode(uint8(2), uint8(0)));
        // the backlink list is keyed by target, and a lone negative has none: it is found by role-scope instead
        _assertBacklink(target, 1, 1);

        // LensReader reads the ADDRESS head as PRESENT (its head sanity accepts kind 3)
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        BasisCommit memory none;
        (Qualified memory q, Selection memory s) =
            lens.resolve(l, Coordinate(Purpose.TAG, topic, target), none);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(s.targetKind, 3);
        assertEq(s.target, target);
        (q,) = lens.resolve(l, Coordinate(Purpose.TAG, _wordId("trusted"), target), none);
        assertEq(uint8(q.status), uint8(Status.MASKED));

        // replay equals live: the decoder rebuilds the bind effect with targetKind 3
        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory e,) = dec.decode(address(r.ledger), pub);
        assertEq(e.length, 1);
        assertEq(
            abi.encode(e[0].kind, e[0].transitionKind, e[0].targetKind, e[0].target),
            abi.encode(ActionKind.BIND, uint8(1), uint8(3), target)
        );
        assertEq(e[0].subject, topic);
        assertEq(e[0].role, target);
    }

    function test_rebind_and_restore_on_an_address_keep_kind_3() public {
        _execAs(address(this), _one(_bind(Purpose.TAG, topic, target, target, 0)), new bytes[](1));
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, topic, target, 0, 1)),
            new bytes[](1)
        );
        _execAs(address(this), _one(_bind(Purpose.TAG, topic, target, target, 2)), new bytes[](1));
        (uint8 st, uint64 rev,, uint8 kind,,,) = r.hot.head(_key(Purpose.TAG, topic, target));
        assertEq(abi.encode(st, rev, kind), abi.encode(uint8(1), uint64(3), uint8(3)));
        _assertBacklink(target, 2, 1);
    }

    /// A FOLDER bind to an address target is still refused: `FilesFinalValidator` code 6 (an unknown target kind).
    function test_folder_to_an_address_is_refused() public {
        (Action memory nm, bytes memory nb) = _name("evil");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (nm, nb);
        a[1] = _bind(Purpose.FOLDER, rootDir, keccak256("evil"), target, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(6), uint8(1))
            )
        );
        this.execExternal(a, b);
    }

    /// ADDRESS targets are for tags only: a HEAD bind to an address is refused by `FilesFinalValidator` code 8 (FOLDER
    /// keeps code 6 above); the TAG bind to the same address word is admitted.
    function test_head_to_an_address_is_refused_tag_is_admitted() public {
        bytes32 file = Keys.subject(p, keccak256("address-targets/head"));
        Action[] memory a = new Action[](2);
        a[0] = _create(keccak256("address-targets/head"));
        a[1] = _bind(Purpose.HEAD, file, 0, target, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(8), uint8(1))
            )
        );
        this.execExternal(a, new bytes[](2));
        a[1] = _bind(Purpose.TAG, topic, target, target, 0);
        _execAs(address(this), a, new bytes[](2));
        (uint8 st,,, uint8 kind,,,) = r.hot.head(_key(Purpose.TAG, topic, target));
        assertEq(abi.encode(st, kind), abi.encode(uint8(1), uint8(3)));
    }

    /// The zero word is refused by the shape law; a non-address word that is neither record nor subject is still
    /// E_TARGET_MISSING.
    function test_non_address_missing_target_still_refused() public {
        bytes32 bogus = bytes32(uint256(1) << 160);
        vm.expectRevert(abi.encodeWithSelector(E_TARGET_MISSING.selector, uint8(0), bogus));
        this.execExternal(_one(_bind(Purpose.TAG, topic, bogus, bogus, 0)), new bytes[](1));
    }

    /// A specific file revision is a record, so it is already a target (kind 1).
    function test_tag_a_revision_record() public {
        bytes32 file = Keys.subject(p, keccak256("address-targets/file"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("address-targets/file"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "v1"));
        bytes32 revision = Keys.record(typeIds[T_ROOT], b[1]);
        a[2] = _bind(Purpose.TAG, topic, revision, revision, 0);
        _execAs(address(this), a, b);
        (uint8 st,,, uint8 kind,,, bytes32 got) = r.hot.head(_key(Purpose.TAG, topic, revision));
        assertEq(abi.encode(st, kind, got), abi.encode(uint8(1), uint8(1), revision));
        _assertBacklink(revision, 1, 1);
    }
}
