// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStub} from "../harness/doubles/LedgerStub.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FamilyId, PostingKey} from "../../src/interfaces/Actions.sol";
import {Phase} from "../../src/interfaces/Results.sol";
import {E_FAMILY, E_ORDER, E_WRITER} from "../../src/interfaces/Errors.sol";

/// @notice `appendBatch` is the per-append path with the writer rule asked once (design §4.6): the same stored
///         result, the same first error, every entry's family and order law checked, an empty batch inert; and
///         the family set is the constructor's, exactly, from immutables.
contract AppendBatchTest is Test {
    LedgerStub internal ledger;
    address internal constant GEN = address(0xA11CE);
    bytes32 internal A = Keys.familyId("by-type");
    bytes32 internal B = Keys.familyId("history");
    bytes32 internal OTHER = Keys.familyId("backlink");

    function setUp() public {
        ledger = new LedgerStub();
        ledger.set(GEN, Phase.APPLYING, 1, 1);
    }

    function _store() internal returns (PostingStore) {
        bytes32[] memory f = new bytes32[](2);
        f[0] = A;
        f[1] = B;
        return new PostingStore(address(ledger), address(0), f);
    }

    function _k(uint256 i) internal pure returns (PostingKey) {
        return PostingKey.wrap(keccak256(abi.encode("k", i)));
    }

    function _batch(bytes32[] memory fam, uint256[] memory key, uint64[] memory ord)
        internal
        pure
        returns (FamilyId[] memory f, PostingKey[] memory k, uint64[] memory o)
    {
        f = new FamilyId[](fam.length);
        k = new PostingKey[](key.length);
        o = ord;
        for (uint256 i; i < fam.length; ++i) {
            f[i] = FamilyId.wrap(fam[i]);
        }
        for (uint256 i; i < key.length; ++i) {
            k[i] = _k(key[i]);
        }
    }

    function _heads(PostingStore s, uint256 keys) internal view returns (bytes memory out) {
        for (uint256 i; i < keys; ++i) {
            (uint64 c, uint64 l, uint64 last,) = s.postingHead(_k(i));
            out = bytes.concat(out, abi.encode(c, l, last, s.postingSlice(_k(i), 0, 16)));
        }
    }

    function testFuzz_batch_equals_appends(uint8 seed) public {
        PostingStore one = _store();
        PostingStore many = _store();
        uint256 n = 1 + (seed % 12);
        bytes32[] memory fam = new bytes32[](n);
        uint256[] memory key = new uint256[](n);
        uint64[] memory ord = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            fam[i] = (seed >> (i % 8)) & 1 == 0 ? A : B;
            key[i] = uint256(keccak256(abi.encode(seed, i))) % 3;
            ord[i] = uint64(10 + i);
        }
        vm.startPrank(GEN);
        for (uint256 i; i < n; ++i) {
            one.append(FamilyId.wrap(fam[i]), _k(key[i]), ord[i], 0);
        }
        (FamilyId[] memory f, PostingKey[] memory k, uint64[] memory o) = _batch(fam, key, ord);
        many.appendBatch(f, k, o);
        vm.stopPrank();
        assertEq(_heads(one, 3), _heads(many, 3));
        assertEq(one.attached(), many.attached());
        (address[] memory g1,,) = one.writers();
        (address[] memory g2,,) = many.writers();
        assertEq(g1, g2);
    }

    function test_every_entry_is_checked() public {
        PostingStore s = _store();
        bytes32[] memory fam = new bytes32[](3);
        (fam[0], fam[1], fam[2]) = (A, B, OTHER);
        uint256[] memory key = new uint256[](3);
        (key[0], key[1], key[2]) = (0, 1, 2);
        uint64[] memory ord = new uint64[](3);
        (ord[0], ord[1], ord[2]) = (5, 6, 7);
        (FamilyId[] memory f, PostingKey[] memory k, uint64[] memory o) = _batch(fam, key, ord);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, OTHER));
        s.appendBatch(f, k, o);
        // the order law inside one batch: the same key twice, not increasing
        fam[2] = A;
        key[2] = 0;
        ord[2] = 5;
        (f, k, o) = _batch(fam, key, ord);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(5), uint64(5)));
        s.appendBatch(f, k, o);
    }

    function test_first_error_is_the_lone_appends() public {
        PostingStore s = _store();
        bytes32[] memory fam = new bytes32[](1);
        fam[0] = OTHER;
        uint256[] memory key = new uint256[](1);
        uint64[] memory ord = new uint64[](1);
        ord[0] = 1;
        (FamilyId[] memory f, PostingKey[] memory k, uint64[] memory o) = _batch(fam, key, ord);
        // a stranger with a foreign family: the family error comes first, as for append
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, OTHER));
        s.appendBatch(f, k, o);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, OTHER));
        s.append(FamilyId.wrap(OTHER), _k(0), 1, 0);
        // a stranger with a member family: the writer error
        (f, k, o) = _batch(_one(A), key, ord);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(0xBAD)));
        s.appendBatch(f, k, o);
        // the live generation while the ledger is idle: append-ordered lists are never backfilled
        ledger.set(GEN, Phase.IDLE, 1, 1);
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, GEN));
        s.appendBatch(f, k, o);
    }

    function _one(bytes32 x) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = x;
    }

    function test_empty_batch_writes_and_attaches_nothing() public {
        PostingStore s = _store();
        vm.prank(GEN);
        s.appendBatch(new FamilyId[](0), new PostingKey[](0), new uint64[](0));
        assertFalse(s.attached());
        (address[] memory g,,) = s.writers();
        assertEq(g.length, 0);
    }

    function test_arrays_of_different_lengths_revert() public {
        PostingStore s = _store();
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(1), uint64(2)));
        s.appendBatch(new FamilyId[](2), new PostingKey[](1), new uint64[](1));
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_ORDER.selector, uint64(1), uint64(0)));
        s.appendBatch(new FamilyId[](1), new PostingKey[](1), new uint64[](0));
    }

    function test_family_set_is_exact_and_bounded() public {
        PostingStore s = _store();
        vm.prank(GEN);
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, bytes32(0)));
        s.append(FamilyId.wrap(0), _k(0), 1, 0); // the zero padding of unused slots never matches
        bytes32[] memory f = new bytes32[](17);
        for (uint256 i; i < 17; ++i) {
            f[i] = keccak256(abi.encode(i));
        }
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, bytes32(uint256(17))));
        new PostingStore(address(ledger), address(0), f);
        bytes32[] memory full = new bytes32[](16);
        for (uint256 i; i < 16; ++i) {
            full[i] = f[i];
        }
        PostingStore sixteen = new PostingStore(address(ledger), address(0), full);
        vm.startPrank(GEN);
        for (uint256 i; i < 16; ++i) {
            sixteen.append(FamilyId.wrap(full[i]), _k(i), 1, 0); // every slot is a member
        }
        vm.stopPrank();
        full[3] = 0;
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, bytes32(0)));
        new PostingStore(address(ledger), address(0), full);
        bytes32[] memory five = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = f[i];
        }
        vm.expectRevert(abi.encodeWithSelector(E_FAMILY.selector, bytes32(uint256(5))));
        new BitmapStore(address(ledger), address(0), five);
    }
}
