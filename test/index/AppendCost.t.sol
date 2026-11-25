// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStub} from "../harness/doubles/LedgerStub.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {FamilyId, PostingKey} from "../../src/interfaces/Actions.sol";
import {Phase} from "../../src/interfaces/Results.sol";

/// @notice The posting store's write cost in isolation (design §4.6, §10.2): one `append` per CALL against one
///         `appendBatch` for the same entries, on the generation-1 family set, for a fresh list (the head only)
///         and an existing list (the second entry materializes word 0; later entries OR into a word). The
///         ledger is a stub whose three hot reads are plain calls, cheaper than the real proxy's, so these
///         figures are a floor for the authorization part; the integration rows (`GasModel.t.sol`) are the real
///         ones. Every row starts cold (`vm.cool` on the store and the stub), as a transaction of its own would.
contract AppendCostTest is Test {
    LedgerStub internal ledger;
    PostingStore internal posting;
    address internal constant GEN = address(0xA11CE);
    bytes32[] internal fam;

    function setUp() public {
        ledger = new LedgerStub();
        bytes32[] memory f = IndexDeploy.postingFamilies();
        for (uint256 i; i < f.length; ++i) {
            fam.push(f[i]);
        }
        posting = new PostingStore(address(ledger), address(0), f);
        ledger.set(GEN, Phase.APPLYING, 1, 1);
        // attach, and give keys 0..31 two entries each, so the next append to one writes into word 0
        vm.startPrank(GEN);
        for (uint256 k; k < 32; ++k) {
            posting.append(FamilyId.wrap(fam[k % fam.length]), _key(k), 1, 0);
            posting.append(FamilyId.wrap(fam[k % fam.length]), _key(k), 2, 0);
        }
        vm.stopPrank();
    }

    function _key(uint256 k) internal pure returns (PostingKey) {
        return PostingKey.wrap(keccak256(abi.encode("append-cost", k)));
    }

    /// Keys 0..31 exist (two entries); keys from 1,000 are fresh.
    function _keyOf(bool fresh, uint256 i) internal pure returns (PostingKey) {
        return _key(fresh ? 1000 + i : i);
    }

    function _cool() internal {
        vm.cool(address(posting));
        vm.cool(address(ledger));
    }

    function _single(string memory row, uint256 familyIndex, uint256 n, bool fresh) internal {
        _cool();
        vm.startPrank(GEN);
        uint256 before = gasleft();
        for (uint256 i; i < n; ++i) {
            posting.append(FamilyId.wrap(fam[familyIndex]), _keyOf(fresh, i), uint64(3 + i), 0);
        }
        uint256 used = before - gasleft();
        vm.stopPrank();
        emit log_named_uint(string.concat("append ", row, " total"), used);
        emit log_named_uint(string.concat("append ", row, " per entry"), used / n);
    }

    function _batch(string memory row, uint256 familyIndex, uint256 n, bool fresh) internal {
        FamilyId[] memory f = new FamilyId[](n);
        PostingKey[] memory k = new PostingKey[](n);
        uint64[] memory o = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            f[i] =
                FamilyId.wrap(fam[familyIndex == type(uint256).max ? i % fam.length : familyIndex]);
            k[i] = _keyOf(fresh, i);
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
        uint256 last = fam.length - 1;
        uint256 snap = vm.snapshotState();
        _single("single x1 existing, first family", 0, 1, false);
        vm.revertToState(snap);
        _single("single x1 existing, last family", last, 1, false);
        vm.revertToState(snap);
        _single("single x1 fresh, last family", last, 1, true);
        vm.revertToState(snap);
        _single("single x5 existing, last family", last, 5, false);
        vm.revertToState(snap);
        _single("single x5 fresh, last family", last, 5, true);
        vm.revertToState(snap);
        _batch("batch x1 existing, last family", last, 1, false);
        vm.revertToState(snap);
        _batch("batch x1 fresh, last family", last, 1, true);
        vm.revertToState(snap);
        _batch("batch x5 existing, last family", last, 5, false);
        vm.revertToState(snap);
        _batch("batch x5 fresh, last family", last, 5, true);
        vm.revertToState(snap);
        _batch("batch x10 existing, mixed families", type(uint256).max, 10, false);
        vm.revertToState(snap);
        _batch("batch x10 fresh, mixed families", type(uint256).max, 10, true);
    }
}
