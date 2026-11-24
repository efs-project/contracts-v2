// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {LedgerStub} from "../harness/doubles/LedgerStub.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";
import {E_DEPLOYER} from "../../src/interfaces/Errors.sol";

/// @notice A later generation created together with its fresh stores by one contract's nonces (design §10.1):
///         the stores name the nonce-predicted generation as INITIAL_WRITER, the generation names the stores,
///         every prediction is asserted, the plan is pinned by hash, and a second run reverts.
contract IndexDeployerTest is Test {
    LedgerStub internal ledger;
    bytes32 internal constant HOT = keccak256("efs2/ledger-hot/1:test");

    function setUp() public {
        ledger = new LedgerStub();
    }

    function _plan(bool freshPosting, bool freshBitmap, address posting, address bitmap)
        internal
        pure
        returns (IndexDeployer.Plan memory p)
    {
        p.hotAbiId = HOT;
        p.decoder = address(0);
        if (freshPosting) p.postingInitcode = type(PostingStore).creationCode;
        p.postingFamilies = IndexDeploy.postingFamilies();
        p.posting = posting;
        if (freshBitmap) p.bitmapInitcode = type(BitmapStore).creationCode;
        p.bitmapFamilies = IndexDeploy.bitmapFamilies();
        p.bitmap = bitmap;
        p.generationInitcode = type(RealmIndex).creationCode;
        p.units = new Unit[](0);
        p.specs = new DigestSpec[](0);
        p.work = IndexDoubleDefaults.workModel();
    }

    function testFreshStoresNameThePredictedGeneration() public {
        IndexDeployer.Plan memory plan = _plan(true, true, address(0), address(0));
        IndexDeployer d = new IndexDeployer(address(ledger), keccak256(abi.encode(plan)));
        address predicted = d.predictGeneration(plan);
        vm.prank(address(0xCAFE)); // anyone runs the plan
        address gen = d.run(plan);
        assertEq(gen, predicted);
        assertEq(d.generation(), gen);
        PostingStore ps = PostingStore(d.postingStore());
        BitmapStore bs = BitmapStore(d.bitmapStore());
        assertEq(ps.initialWriter(), gen, "the fresh store names the generation before it exists");
        assertEq(bs.initialWriter(), gen);
        assertEq(ps.ledger(), address(ledger));
        assertFalse(ps.attached());
        assertEq(ps.familyIds().length, 10);
        assertEq(bs.familyIds().length, 3);
        RealmIndex ix = RealmIndex(gen);
        assertEq(ix.postingStore(), address(ps));
        assertEq(ix.bitmapStore(), address(bs));
        assertEq(ix.ledger(), address(ledger));
        assertEq(ix.HOT_ABI_ID(), HOT);
        assertEq(ix.replayReadiness().families.length, 13);
        vm.expectRevert(abi.encodeWithSelector(E_DEPLOYER.selector, uint8(0)));
        d.run(plan);
    }

    function testRePinnedStoresAreReusedAndThePlanIsPinned() public {
        IndexDeploy.Gen1 memory g1 = IndexDeploy.deploy(address(ledger), HOT);
        IndexDeployer.Plan memory plan = _plan(false, true, address(g1.posting), address(0));
        IndexDeployer d = new IndexDeployer(address(ledger), keccak256(abi.encode(plan)));
        IndexDeployer.Plan memory other = _plan(true, true, address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(E_DEPLOYER.selector, uint8(1)));
        d.run(other);
        address gen = d.run(plan);
        assertEq(gen, d.predictGeneration(plan));
        assertEq(RealmIndex(gen).postingStore(), address(g1.posting), "re-pinned, not recreated");
        assertEq(d.postingStore(), address(g1.posting));
        assertTrue(d.bitmapStore() != address(g1.bitmap));
        assertEq(BitmapStore(d.bitmapStore()).initialWriter(), gen);
    }
}
