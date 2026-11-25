// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Coordinate, FamilyId, Purpose, TypeId} from "../../src/interfaces/Actions.sol";
import {ILedgerViews} from "../../src/interfaces/ILedgerViews.sol";
import {BasisCommit, Status} from "../../src/interfaces/Results.sol";
import {Head} from "../../src/interfaces/Views.sol";

/// @notice The two batched list reads of `LedgerViews` (design §5.7): `bindingCells` (binding ordinal → position and
///         cell) and `authorHeads` (a `position-authors` entry → author and head), against the kernel's own heads, with
///         the blanket statuses (LIMIT_EXCEEDED past `maxReadIds`, UNKNOWN without a ledger) and the per-entry
///         ABSENT_PROVEN / INVALID, and their ABI encodings (standard: the facet returns them through the encoder).
contract FacetsListsTest is TopicReadersBase {
    bytes32 internal topic;

    function setUp() public override {
        super.setUp();
        topic = _regPath("fl", 1)[0];
        _tagN(alice, topic, things[0], 9);
        _deny(bob, topic, things[0]);
        _tag(carol, topic, things[1]);
    }

    function _authorsAt(bytes32 pos) internal view returns (uint64[] memory e) {
        (, e,) = r.g.index
            .postingSliceOf(FamilyId.wrap(F_POSITION_AUTHORS), TypeId.wrap(0), 0, pos, 0, 64);
    }

    function test_binding_cells_name_each_ordinal() public view {
        uint64[] memory o = new uint64[](3);
        o[0] = _ordinal(alice, Purpose.TAG, topic, things[0]);
        o[1] = _ordinal(carol, Purpose.TAG, topic, things[1]);
        o[2] = 1 << 40; // never allocated
        (Status[] memory st, bytes32[] memory pos, Coordinate[] memory c, BasisCommit memory b) =
            views.bindingCells(address(r.ledger), o);
        assertEq(uint8(st[0]), uint8(Status.PRESENT));
        assertEq(pos[0], Keys.position(Purpose.TAG, topic, things[0]));
        assertEq(c[0].purpose, Purpose.TAG);
        assertEq(c[0].subject, topic);
        assertEq(c[0].role, things[0]);
        assertEq(pos[1], Keys.position(Purpose.TAG, topic, things[1]));
        assertEq(uint8(st[2]), uint8(Status.ABSENT_PROVEN));
        assertEq(pos[2], 0);
        assertEq(c[2].purpose, 0);
        assertEq(keccak256(abi.encode(b)), keccak256(abi.encode(reads.basis(address(r.ledger)))));
    }

    function test_author_heads_resolve_each_first_statement() public view {
        bytes32 pos = Keys.position(Purpose.TAG, topic, things[0]);
        uint64[] memory e = _authorsAt(pos);
        assertEq(e.length, 2);
        (Status[] memory st, bytes32[] memory who, Head[] memory hs,) =
            views.authorHeads(address(r.ledger), pos, e);
        assertEq(who[0], _pid(alice));
        assertEq(uint8(st[0]), uint8(Status.PRESENT));
        assertEq(hs[0].strength, 9);
        assertEq(hs[0].target, things[0]);
        assertEq(who[1], _pid(bob));
        assertEq(uint8(st[1]), uint8(Status.MASKED));
        assertEq(hs[1].target, 0);
        (Head[] memory direct,) = views.heads(address(r.ledger), _keys(who, pos));
        assertEq(keccak256(abi.encode(hs)), keccak256(abi.encode(direct)), "the kernel's own heads");
    }

    function _keys(bytes32[] memory who, bytes32 pos) internal pure returns (bytes32[] memory k) {
        k = new bytes32[](who.length);
        for (uint256 i; i < who.length; ++i) {
            k[i] = Keys.binding(who[i], pos);
        }
    }

    function test_author_heads_refuse_an_entry_of_another_binding() public view {
        bytes32 pos = Keys.position(Purpose.TAG, topic, things[0]);
        uint64[] memory e = new uint64[](3);
        e[0] = _authorsAt(Keys.position(Purpose.TAG, topic, things[1]))[0]; // carol's, at another position
        e[1] = 1; // the first admission: a PUBLISH row
        e[2] = 1 << 40; // unwritten
        (Status[] memory st, bytes32[] memory who, Head[] memory hs,) =
            views.authorHeads(address(r.ledger), pos, e);
        assertEq(uint8(st[0]), uint8(Status.INVALID));
        assertEq(uint8(st[1]), uint8(Status.INVALID));
        assertEq(uint8(st[2]), uint8(Status.ABSENT_PROVEN));
        assertEq(who[2], 0);
        assertEq(hs[2].state, 0);
    }

    function test_blanket_statuses() public {
        uint64[] memory many = new uint64[](65);
        (Status[] memory st,,,) = views.bindingCells(address(r.ledger), many);
        for (uint256 i; i < 65; ++i) {
            assertEq(uint8(st[i]), uint8(Status.LIMIT_EXCEEDED));
        }
        (st,,,) = views.authorHeads(address(r.ledger), 0, many);
        assertEq(uint8(st[64]), uint8(Status.LIMIT_EXCEEDED));
        uint64[] memory one = new uint64[](1);
        address nobody = makeAddr("facets-lists/no-ledger");
        BasisCommit memory b;
        (st,,, b) = views.bindingCells(nobody, one);
        assertEq(uint8(st[0]), uint8(Status.UNKNOWN));
        assertEq(b.admissionHighWater, 0);
        (st,,,) = views.authorHeads(nobody, 0, one);
        assertEq(uint8(st[0]), uint8(Status.UNKNOWN));
        // an empty batch is served with its basis
        (st,,, b) = views.bindingCells(address(r.ledger), new uint64[](0));
        assertEq(st.length, 0);
        assertGt(b.admissionHighWater, 0);
    }

    /// The replies are the ABI encoder's: the raw return data equals `abi.encode` of the decoded values.
    function test_canonical_encodings() public view {
        bytes32 pos = Keys.position(Purpose.TAG, topic, things[0]);
        uint64[] memory e = _authorsAt(pos);
        (bool ok, bytes memory raw) = address(views)
            .staticcall(abi.encodeCall(ILedgerViews.authorHeads, (address(r.ledger), pos, e)));
        assertTrue(ok);
        (Status[] memory st, bytes32[] memory who, Head[] memory hs, BasisCommit memory b) =
            abi.decode(raw, (Status[], bytes32[], Head[], BasisCommit));
        assertEq(keccak256(raw), keccak256(abi.encode(st, who, hs, b)));
        uint64[] memory o = new uint64[](1);
        o[0] = _ordinal(alice, Purpose.TAG, topic, things[0]);
        (ok, raw) = address(views)
            .staticcall(abi.encodeCall(ILedgerViews.bindingCells, (address(r.ledger), o)));
        assertTrue(ok);
        (Status[] memory s2, bytes32[] memory p2, Coordinate[] memory c2, BasisCommit memory b2) =
            abi.decode(raw, (Status[], bytes32[], Coordinate[], BasisCommit));
        assertEq(keccak256(raw), keccak256(abi.encode(s2, p2, c2, b2)));
    }
}
