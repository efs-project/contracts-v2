// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {Layout} from "../../src/core/layout/Layout.sol";

/// @notice Test-only: a digest over raw slots of the rows a test knows about, read through `Layout`,
///         so "refused call changed nothing" and "activation changed nothing outside its scope" are
///         one equality (design §6.6, §16.5 #12). Head rows are projected canonically: the target
///         counts as zero unless the state is BOUND, because the target word is kept on MASK/RELEASE.
library StateDigest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct LedgerKeys {
        bytes32[] recordIds;
        bytes32[] subjectIds;
        uint64 admissionsThrough; // rows 1..n
        uint64 publicationsThrough; // evidence 1..n
        bytes32[] principalIds;
        uint64[] nonces; // publicationAt[principalIds[i]][nonces[i]]
        bytes32[] bindingKeys;
        bytes32[] positionKeys;
        uint64 bindingOrdinalsThrough;
        uint32 revisionsThrough; // rows 1..n
    }

    function raw(address a, uint256 slot) internal view returns (bytes32) {
        return vm.load(a, bytes32(slot));
    }

    /// Digest of an explicit slot list: keccak over (slot, value) pairs in order.
    function slots(address a, uint256[] memory list) internal view returns (bytes32 h) {
        for (uint256 i; i < list.length; ++i) {
            h = keccak256(abi.encode(h, list[i], raw(a, list[i])));
        }
    }

    function realm(address a) internal view returns (bytes32 h) {
        for (uint256 i; i < 18; ++i) {
            h = keccak256(abi.encode(h, i, raw(a, uint256(Layout.LEDGER_REALM_ROOT) + i)));
        }
        h = keccak256(abi.encode(h, raw(a, uint256(Layout.LEDGER_COUNTERS_ROOT))));
    }

    function ledger(address a, LedgerKeys memory k) internal view returns (bytes32 h) {
        h = realm(a);
        for (uint256 i; i < k.recordIds.length; ++i) {
            uint256 s = Layout.recordsCellsSlot(k.recordIds[i]);
            bytes32 w1 = raw(a, s + 1);
            (, uint32 len,,) = Layout.unpackRecordCellWord1(w1);
            h = keccak256(abi.encode(h, raw(a, s), w1));
            for (uint256 w; w < (len + 31) / 32; ++w) {
                h = keccak256(abi.encode(h, raw(a, Layout.recordsBodyWordsSlot(k.recordIds[i], w))));
            }
        }
        for (uint256 i; i < k.subjectIds.length; ++i) {
            h = keccak256(abi.encode(h, raw(a, Layout.subjectsCellsSlot(k.subjectIds[i]))));
        }
        for (uint256 o = 1; o <= k.admissionsThrough; ++o) {
            uint256 s = Layout.admissionsRowsSlot(o);
            h = keccak256(abi.encode(h, raw(a, s), raw(a, s + 1)));
        }
        for (uint256 p = 1; p <= k.publicationsThrough; ++p) {
            uint256 s = Layout.publicationsEvidenceSlot(p);
            for (uint256 w; w < 13; ++w) {
                h = keccak256(abi.encode(h, raw(a, s + w)));
            }
        }
        for (uint256 i; i < k.principalIds.length; ++i) {
            h = keccak256(abi.encode(h, raw(a, Layout.principalsRowsSlot(k.principalIds[i]))));
            if (i < k.nonces.length) {
                h = keccak256(
                    abi.encode(
                        h,
                        raw(a, Layout.publicationsPublicationAtSlot(k.principalIds[i], k.nonces[i]))
                    )
                );
            }
        }
        for (uint256 i; i < k.bindingKeys.length; ++i) {
            uint256 s = Layout.bindingsHeadsSlot(k.bindingKeys[i]);
            bytes32 meta = raw(a, s);
            (uint8 state,,,,,,) = Layout.unpackHeadRowWord0(meta);
            bytes32 target = state == 1 ? raw(a, s + 1) : bytes32(0); // canonical projection
            h = keccak256(abi.encode(h, meta, target));
        }
        for (uint256 i; i < k.positionKeys.length; ++i) {
            uint256 s = Layout.bindingsPositionsSlot(k.positionKeys[i]);
            h = keccak256(abi.encode(h, raw(a, s), raw(a, s + 1), raw(a, s + 2)));
        }
        for (uint256 o = 1; o <= k.bindingOrdinalsThrough; ++o) {
            h = keccak256(abi.encode(h, raw(a, Layout.bindingsBindingPositionSlot(o))));
        }
        for (uint256 r = 1; r <= k.revisionsThrough; ++r) {
            uint256 s = Layout.revisionsRowsSlot(r);
            for (uint256 w; w < 25; ++w) {
                h = keccak256(abi.encode(h, raw(a, s + w)));
            }
        }
    }
}
