// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
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

/// @notice Target kind 3 = ADDRESS. A nonzero address-shaped target (top 96 bits zero) that is neither a record nor
///         a subject is admitted with `targetKind = 3`, so an address that never transacted can be tagged; the
///         readers and the replay decoder carry it; `FilesFinalValidator` refuses it for HEAD (code 7) and FOLDER
///         (code 6), admits it for TAG and does not judge a purpose the profile does not name. A file revision is a
///         record, so it was a target already. The two topics are word pages registered in `setUp` (a tag's subject
///         must be a registered topic or a home).
contract AddressTargetsTest is FilesRecipesBase {
    bytes32 internal TOPIC;
    bytes32 internal TRUSTED;
    address internal phisher = makeAddr("address-targets/phisher");
    bytes32 internal target;
    LensReader internal lens;

    function setUp() public override {
        super.setUp();
        target = bytes32(uint256(uint160(phisher)));
        (Action[] memory a, bytes[] memory b, bytes32 phishing) =
            EfsTopics.registerWord(_topicTypes(), "phishing");
        _execAs(address(this), a, b);
        (a, b, TRUSTED) = EfsTopics.registerWord(_topicTypes(), "trusted");
        _execAs(address(this), a, b);
        TOPIC = phishing;
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

        // assert: (TAG, topic, role = address) -> address, number +3
        uint64 pub = _execAs(
            address(this),
            _one(EfsFiles.bindWithStrength(Purpose.TAG, TOPIC, target, target, 0, 3)),
            new bytes[](1)
        );
        (uint8 st,,, uint8 kind,,, bytes32 got, uint16 strength) =
            r.hot.head(_key(Purpose.TAG, TOPIC, target));
        assertEq(abi.encode(st, kind, got, strength), abi.encode(uint8(1), uint8(3), target, 3));
        _assertBacklink(target, 1, 1);

        // a lone negative on the same address under another topic (no target: role = address)
        _execAs(
            address(this),
            _one(EfsFiles.loneNegative(Purpose.TAG, TRUSTED, target, 0)),
            new bytes[](1)
        );
        (st,,, kind,,,,) = r.hot.head(_key(Purpose.TAG, TRUSTED, target));
        assertEq(abi.encode(st, kind), abi.encode(uint8(2), uint8(0)));
        // the backlink list is keyed by target, and a lone negative has none
        _assertBacklink(target, 1, 1);

        // LensReader reads the ADDRESS head as PRESENT and the lone negative as MASKED
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        BasisCommit memory none;
        (Qualified memory q, Selection memory s) =
            lens.resolve(l, Coordinate(Purpose.TAG, TOPIC, target), none);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(abi.encode(s.targetKind, s.target, s.strength), abi.encode(3, target, 3));
        (q, s) = lens.resolve(l, Coordinate(Purpose.TAG, TRUSTED, target), none);
        assertEq(uint8(q.status), uint8(Status.MASKED));
        assertEq(abi.encode(s.targetKind, s.target, s.strength), abi.encode(0, bytes32(0), 0));

        // replay equals live: the decoder rebuilds the bind effect with targetKind 3
        IndexReplayDecoder dec = new IndexReplayDecoder();
        (Effect[] memory e,) = dec.decode(address(r.ledger), pub);
        assertEq(e.length, 1);
        assertEq(
            abi.encode(e[0].kind, e[0].transitionKind, e[0].targetKind, e[0].target),
            abi.encode(ActionKind.BIND, uint8(1), uint8(3), target)
        );
        assertEq(abi.encode(e[0].subject, e[0].role), abi.encode(TOPIC, target));
    }

    function test_rebind_and_restore_on_an_address_keep_kind_3() public {
        _execAs(address(this), _one(_bind(Purpose.TAG, TOPIC, target, target, 0)), new bytes[](1));
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, TOPIC, target, 0, 1)),
            new bytes[](1)
        );
        _execAs(address(this), _one(_bind(Purpose.TAG, TOPIC, target, target, 2)), new bytes[](1));
        (uint8 st, uint64 rev,, uint8 kind,,,,) = r.hot.head(_key(Purpose.TAG, TOPIC, target));
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

    /// A HEAD bind to an address is refused by `FilesFinalValidator` code 7 (this profile's readers cannot serve
    /// it); a bind of a purpose this profile does not name is not judged and is admitted, and so is the TAG bind
    /// to the same word.
    function test_head_to_an_address_is_refused_tag_and_third_party_are_admitted() public {
        bytes32 file = Keys.subject(p, keccak256("address-targets/head"));
        Action[] memory a = new Action[](2);
        a[0] = _create(keccak256("address-targets/head"));
        a[1] = _bind(Purpose.HEAD, file, 0, target, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(7), uint8(1))
            )
        );
        this.execExternal(a, new bytes[](2));
        bytes32 thirdParty = keccak256("third-party/purpose/1");
        a[1] = _bind(thirdParty, file, 0, target, 0);
        _execAs(address(this), a, new bytes[](2));
        (uint8 st,,, uint8 kind,,,,) = r.hot.head(_key(thirdParty, file, 0));
        assertEq(abi.encode(st, kind), abi.encode(uint8(1), uint8(3)));
        a = _one(_bind(Purpose.TAG, TOPIC, target, target, 0));
        _execAs(address(this), a, new bytes[](1));
        (st,,, kind,,,,) = r.hot.head(_key(Purpose.TAG, TOPIC, target));
        assertEq(abi.encode(st, kind), abi.encode(uint8(1), uint8(3)));
    }

    /// A non-address word that is neither record nor subject is still E_TARGET_MISSING.
    function test_non_address_missing_target_still_refused() public {
        bytes32 bogus = bytes32(uint256(1) << 160);
        vm.expectRevert(abi.encodeWithSelector(E_TARGET_MISSING.selector, uint8(0), bogus));
        this.execExternal(_one(_bind(Purpose.TAG, TOPIC, bogus, bogus, 0)), new bytes[](1));
    }

    /// A specific file revision is a record, so it is already a target (kind 1).
    function test_tag_a_revision_record() public {
        bytes32 file = Keys.subject(p, keccak256("address-targets/file"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("address-targets/file"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "v1"));
        bytes32 revision = Keys.record(typeIds[T_ROOT], b[1]);
        a[2] = _bind(Purpose.TAG, TOPIC, revision, revision, 0);
        _execAs(address(this), a, b);
        (uint8 st,,, uint8 kind,,, bytes32 got,) = r.hot.head(_key(Purpose.TAG, TOPIC, revision));
        assertEq(abi.encode(st, kind, got), abi.encode(uint8(1), uint8(1), revision));
        _assertBacklink(revision, 1, 1);
    }
}
