// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ControlFixture} from "../harness/ControlFixture.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {FORMULA_VERSION, WORK_MODEL_WORDS, WorkModel} from "../../src/interfaces/Index.sol";
import {ILedgerIngress} from "../../src/interfaces/internal/ILedgerIngress.sol";
import {E_INDEX_NOT_READY, E_WORK_MODEL} from "../../src/interfaces/Errors.sol";

/// @notice The work model's shape is checked, never mis-read (docs/WORK-MODEL-V3.md §6.5): the ingress reads
///         `IIndexReads.workModel()` as raw words and refuses any other length or formula (`E_WORK_MODEL`), and
///         activation refuses an index whose work model is not the ingress's formula (`E_INDEX_NOT_READY` 15) or whose
///         words do not fit their fields (16), for a kept index and a new one alike. A formula-2 index (17 words) under
///         this build is refused loudly in both places.
contract WorkModelChecksTest is ControlFixture {
    function _words(WorkModel memory w) internal pure returns (uint256[] memory v) {
        bytes memory e = abi.encode(w);
        v = new uint256[](WORK_MODEL_WORDS);
        for (uint256 i; i < WORK_MODEL_WORDS; ++i) {
            uint256 x;
            assembly ("memory-safe") {
                x := mload(add(e, add(32, shl(5, i))))
            }
            v[i] = x;
        }
    }

    function _raw(uint256[] memory v) internal pure returns (bytes memory r) {
        r = new bytes(v.length * 32);
        for (uint256 i; i < v.length; ++i) {
            uint256 x = v[i];
            assembly ("memory-safe") {
                mstore(add(r, add(32, shl(5, i))), x)
            }
        }
    }

    /// A formula-2 work model as such an index answers it: 17 words, word 0 = 2.
    function _formula2() internal pure returns (bytes memory) {
        uint256[] memory v = new uint256[](17);
        v[0] = 2;
        for (uint256 i = 1; i < 17; ++i) {
            v[i] = 10;
        }
        return _raw(v);
    }

    function _mockWork(bytes memory reply) internal {
        vm.mockCall(address(index), abi.encodeWithSelector(IIndexReads.workModel.selector), reply);
    }

    function _quote() internal view returns (uint32 p) {
        (Action[] memory a,) = createActions(keccak256("work model checks"));
        (p,,,) = ILedgerCommitments(k.ingress).indexFloor(address(ledger), a);
    }

    function test_ingress_implements_formula_3() public view {
        assertEq(ILedgerIngress(k.ingress).formulaVersion(), FORMULA_VERSION);
        assertEq(FORMULA_VERSION, 3);
        assertEq(abi.encode(IndexDoubleDefaults.workModel()).length, WORK_MODEL_WORDS * 32);
    }

    function test_ingress_refuses_a_formula_2_index_E_WORK_MODEL_2() public {
        _mockWork(_formula2());
        vm.expectRevert(abi.encodeWithSelector(E_WORK_MODEL.selector, uint8(2), uint256(17 * 32)));
        this.quote();
    }

    function test_ingress_refuses_another_version_E_WORK_MODEL_3() public {
        uint256[] memory v = _words(IndexDoubleDefaults.workModel());
        v[0] = 4;
        _mockWork(_raw(v));
        vm.expectRevert(abi.encodeWithSelector(E_WORK_MODEL.selector, uint8(3), uint256(4)));
        this.quote();
    }

    function test_ingress_refuses_a_failed_read_E_WORK_MODEL_1() public {
        vm.mockCallRevert(
            address(index), abi.encodeWithSelector(IIndexReads.workModel.selector), "no"
        );
        vm.expectRevert(abi.encodeWithSelector(E_WORK_MODEL.selector, uint8(1), uint256(2)));
        this.quote();
    }

    function test_a_publication_under_a_formula_2_index_is_refused() public {
        _mockWork(_formula2());
        expectWriteRevert(
            keccak256("refused"),
            abi.encodeWithSelector(E_WORK_MODEL.selector, uint8(2), uint256(17 * 32))
        );
    }

    function quote() external view returns (uint32) {
        return _quote();
    }

    function test_activation_keeps_an_index_of_formula_3() public {
        activate(nextSet());
    }

    function test_kept_formula_2_index_E_INDEX_NOT_READY_15() public {
        _mockWork(_formula2());
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(15))
        );
    }

    function test_kept_index_of_another_version_E_INDEX_NOT_READY_15() public {
        WorkModel memory w = IndexDoubleDefaults.workModel();
        w.formulaVersion = 2;
        index.setWorkModel(w);
        expectActivateRevert(
            nextSet(), abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(15))
        );
    }

    /// Every field's width is checked: a `uint16` word at 2^16, a `uint32` word at 2^32, refused; at the largest value
    /// that fits, accepted by the check (the purpose word, 22, may hold any value).
    function test_out_of_range_words_E_INDEX_NOT_READY_16() public {
        uint256[11] memory u32 = [uint256(8), 9, 10, 11, 12, 15, 18, 21, 25, 28, 31];
        for (uint256 i = 1; i < WORK_MODEL_WORDS; ++i) {
            if (i == 22) continue;
            bool wide;
            for (uint256 j; j < u32.length; ++j) {
                if (u32[j] == i) wide = true;
            }
            uint256[] memory v = _words(IndexDoubleDefaults.workModel());
            v[i] = wide ? 1 << 32 : 1 << 16;
            _mockWork(_raw(v));
            expectActivateRevert(
                nextSet(), abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(16))
            );
            vm.clearMockedCalls();
        }
        uint256[] memory ok = _words(IndexDoubleDefaults.workModel());
        ok[22] = type(uint256).max;
        ok[1] = type(uint16).max;
        ok[8] = type(uint32).max;
        _mockWork(_raw(ok));
        activate(nextSet());
    }

    function test_kept_index_short_reply_E_INDEX_NOT_READY_15() public {
        _mockWork("");
        ActivationSet memory set = nextSet();
        expectActivateRevert(set, abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(15)));
    }
}
