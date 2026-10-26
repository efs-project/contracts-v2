// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStorage} from "../../src/core/storage/LedgerStorage.sol";
import {RegistryStorage} from "../../src/types/storage/RegistryStorage.sol";
import {PostingStoreStorage, BitmapStoreStorage} from "../../src/index/storage/StoreStorage.sol";
import {GenerationStorage} from "../../src/index/storage/GenerationStorage.sol";

contract LedgerRootsExposer is LedgerStorage {
    function roots() external pure returns (bytes32[12] memory r) {
        r = [
            REALM_ROOT,
            COUNTERS_ROOT,
            RECORDS_ROOT,
            SUBJECTS_ROOT,
            ADMISSIONS_ROOT,
            PUBLICATIONS_ROOT,
            BINDINGS_ROOT,
            PRINCIPALS_ROOT,
            REVISIONS_ROOT,
            SOURCE_ROOT,
            STAGING_ROOT,
            LOCK_SLOT
        ];
    }

    function lock(uint8 p, uint48 a, uint48 b, uint48 c) external pure returns (uint256) {
        return _packLock(p, a, b, c);
    }

    function unlock(uint256 w) external pure returns (uint8, uint48, uint48, uint48) {
        return _unpackLock(w);
    }
}

contract RegistryRootsExposer is RegistryStorage {
    function roots() external pure returns (bytes32[8] memory r) {
        r = [
            TYPES_ROOT,
            DECLARATIONS_ROOT,
            POLICY_ROOT,
            ROLES_ROOT,
            BINDINGS_ROOT,
            WRAPPERS_ROOT,
            CATALOG_ROOT,
            CONTROL_ROOT
        ];
    }
}

contract IndexRootsExposer is PostingStoreStorage, BitmapStoreStorage, GenerationStorage {
    function roots() external pure returns (bytes32[3] memory r) {
        r = [POSTING_ROOT, BITMAP_ROOT, GEN_ROOT];
    }
}

/// @notice Every namespace root equals the ERC-7201 formula over its id, so a renamed id or a
///         mistyped constant fails here before any slot is written.
contract StorageRootsTest is Test {
    LedgerRootsExposer internal x = new LedgerRootsExposer();
    RegistryRootsExposer internal y = new RegistryRootsExposer();
    IndexRootsExposer internal z = new IndexRootsExposer();

    function root(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function testLedgerRoots() public view {
        bytes32[12] memory r = x.roots();
        string[12] memory ids = [
            "efs.ledger.v2.realm",
            "efs.ledger.v2.counters",
            "efs.ledger.v2.records",
            "efs.ledger.v2.subjects",
            "efs.ledger.v2.admissions",
            "efs.ledger.v2.publications",
            "efs.ledger.v2.bindings",
            "efs.ledger.v2.principals",
            "efs.ledger.v2.revisions",
            "efs.ledger.v2.source",
            "efs.ledger.v2.staging",
            "efs.ledger.v2.lock"
        ];
        for (uint256 i; i < 12; ++i) {
            assertEq(r[i], root(ids[i]), ids[i]);
        }
    }

    function testRegistryRoots() public view {
        bytes32[8] memory r = y.roots();
        string[8] memory ids = [
            "efs.registry.v2.types",
            "efs.registry.v2.declarations",
            "efs.registry.v2.policy",
            "efs.registry.v2.roles",
            "efs.registry.v2.bindings",
            "efs.registry.v2.wrappers",
            "efs.registry.v2.catalog",
            "efs.registry.v2.control"
        ];
        for (uint256 i; i < 8; ++i) {
            assertEq(r[i], root(ids[i]), ids[i]);
        }
    }

    function testIndexRoots() public view {
        bytes32[3] memory r = z.roots();
        assertEq(r[0], root("efs.index.v2.store.posting"));
        assertEq(r[1], root("efs.index.v2.store.bitmap"));
        assertEq(r[2], root("efs.index.v2.gen"));
    }

    function testAllRootsDistinctAndLowByteZero() public view {
        bytes32[12] memory a = x.roots();
        bytes32[8] memory b = y.roots();
        bytes32[3] memory c = z.roots();
        bytes32[] memory all = new bytes32[](23);
        for (uint256 i; i < 12; ++i) {
            all[i] = a[i];
        }
        for (uint256 i; i < 8; ++i) {
            all[12 + i] = b[i];
        }
        for (uint256 i; i < 3; ++i) {
            all[20 + i] = c[i];
        }
        for (uint256 i; i < all.length; ++i) {
            assertEq(uint256(all[i]) & 0xff, 0, "low byte");
            for (uint256 j = i + 1; j < all.length; ++j) {
                assertTrue(all[i] != all[j], "duplicate root");
            }
        }
    }

    function testFuzzLockWordRoundTrip(uint8 p, uint48 a, uint48 b, uint48 c) public view {
        (uint8 p2, uint48 a2, uint48 b2, uint48 c2) = x.unlock(x.lock(p, a, b, c));
        assertEq(p2, p);
        assertEq(a2, a);
        assertEq(b2, b);
        assertEq(c2, c);
        assertEq(x.lock(p, a, b, c) >> 152, 0, "reserved bits zero");
    }
}
