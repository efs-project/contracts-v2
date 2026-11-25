// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStub} from "../harness/doubles/LedgerStub.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FamilyId, PostingKey} from "../../src/interfaces/Actions.sol";
import {Phase} from "../../src/interfaces/Results.sol";

/// @notice SPIKE (tags-index2): the posting store's per-append cost in isolation (a stub ledger: its three hot
///         reads are plain calls, cheaper than the real proxy's delegatecalls), the same file run against round
///         one's store for the before figures. Every row is one cold call (`vm.cool` on the store and the stub,
///         as a new transaction would see them): `single` = `append` calls, `batch` = one `appendBatch`.
contract AppendCostTest is Test {
    LedgerStub internal ledger;
    PostingStore internal posting;
    address internal constant GEN = address(0xA11CE);
    bytes32[] internal fam;

    function setUp() public {
        ledger = new LedgerStub();
        // the round-two family order: the spike families sit at indices 10..13
        string[14] memory names = [
            "by-type",
            "by-author",
            "backlink",
            "history",
            "reference-position",
            "by-record",
            "unique-by-type",
            "scalar",
            "digest",
            "role-scope",
            "open-scope",
            "open-scope-below",
            "scope-below",
            "position-authors"
        ];
        for (uint256 i; i < 14; ++i) {
            fam.push(Keys.familyId(names[i]));
        }
        posting = new PostingStore(address(ledger), address(0), fam);
        ledger.set(GEN, Phase.APPLYING, 1, 1);
        // the store is attached and every key below exists with 2 entries (the next append writes word 0)
        vm.startPrank(GEN);
        for (uint256 k; k < 32; ++k) {
            posting.append(FamilyId.wrap(fam[k % 14]), _key(k), 1, 0);
            posting.append(FamilyId.wrap(fam[k % 14]), _key(k), 2, 0);
        }
        vm.stopPrank();
    }

    function _key(uint256 k) internal pure returns (PostingKey) {
        return PostingKey.wrap(keccak256(abi.encode("key", k)));
    }

    function _cool() internal {
        vm.cool(address(posting));
        vm.cool(address(ledger));
    }

    function _single(string memory row, uint256 familyIndex, uint256 n, bool sameKey) internal {
        _cool();
        vm.startPrank(GEN);
        uint256 before = gasleft();
        for (uint256 i; i < n; ++i) {
            posting.append(
                FamilyId.wrap(fam[familyIndex]), _key(sameKey ? 0 : 1 + i), uint64(3 + i), 0
            );
        }
        uint256 used = before - gasleft();
        vm.stopPrank();
        emit log_named_uint(string.concat("append ", row, " total"), used);
        emit log_named_uint(string.concat("append ", row, " per entry"), used / n);
    }

    function _batch(string memory row, uint256 familyIndex, uint256 n, bool sameKey) internal {
        FamilyId[] memory f = new FamilyId[](n);
        PostingKey[] memory k = new PostingKey[](n);
        uint64[] memory o = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            f[i] = FamilyId.wrap(fam[familyIndex]);
            k[i] = _key(sameKey ? 0 : 1 + i);
            o[i] = uint64(3 + i);
        }
        _cool();
        vm.prank(GEN);
        uint256 before = gasleft();
        posting.appendBatch(f, k, o);
        uint256 used = before - gasleft();
        emit log_named_uint(string.concat("append ", row, " total"), used);
        emit log_named_uint(string.concat("append ", row, " per entry"), used / n);
    }

    function test_append_costs() public {
        uint256 snap = vm.snapshotState();
        _single("single x1 family 0 (by-type)", 0, 1, true);
        vm.revertToState(snap);
        _single("single x1 family 13 (position-authors)", 13, 1, true);
        vm.revertToState(snap);
        _single("single x10 same key family 13", 13, 10, true);
        vm.revertToState(snap);
        _single("single x10 ten keys family 13", 13, 10, false);
        vm.revertToState(snap);
        _batch("batch x1 family 13", 13, 1, true);
        vm.revertToState(snap);
        _batch("batch x10 same key family 13", 13, 10, true);
        vm.revertToState(snap);
        _batch("batch x10 ten keys family 13", 13, 10, false);
        vm.revertToState(snap);
    }
}
