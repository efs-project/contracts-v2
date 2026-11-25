// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {RecordingIndex} from "../harness/doubles/RecordingIndex.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {FamilyId, ScopeKey} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {DigestSpec, FamilyEntry, Readiness, Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {E_PIN} from "../../src/interfaces/Errors.sol";

/// A recording index that names a reads contract whose codehash is not the one it reports.
contract WrongReadsIndex is RecordingIndex {
    constructor(address ledger_) RecordingIndex(ledger_) {}

    function readsContract() external view override returns (address, bytes32) {
        return (address(this), keccak256("not this code"));
    }
}

/// A contract that claims a progress of its own and asks the reads contract directly.
contract ProgressClaimer {
    function progress() external pure returns (uint64, uint64, bool) {
        return (7, 3, false);
    }

    function ask(IndexReads reads, FamilyId family)
        external
        view
        returns (Coverage c, uint64 from, uint64 through)
    {
        (c, from, through,) = reads.coverage(family, ScopeKey.wrap(0));
    }
}

/// @notice The read side of generation 1 (design §10.1, §5.11): the index answers every `IIndexReads` and
///         `IRealmIndex` read at its own address, the forwarded ones by `STATICCALL` to its `IndexReads`; the
///         manifest hash folds the reads contract's address and codehash; the generation copies its manifest from
///         the reads contract and refuses one built for another ledger; activation pins the reads contract's
///         codehash; and a direct call to the reads contract answers only from its caller's own claims.
contract IndexReadsSplitTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID);
    }

    function _activate(address index, bytes32 manifestHash) internal {
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(k, address(this), address(registry), index, manifestHash)
            );
    }

    function test_manifest_hash_folds_the_reads_contract() public view {
        (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physical,
            bytes32 callback
        ) = g.index.manifest();
        (address reads, bytes32 codehash) = g.index.readsContract();
        assertEq(reads, address(g.reads));
        assertEq(codehash, address(g.reads).codehash);
        assertEq(header, keccak256("efs/index-manifest/2"));
        assertEq(families.length, 18);
        assertEq(
            g.index.manifestHash(),
            keccak256(
                abi.encode(
                    header, families, units, specs, work, physical, callback, reads, codehash
                )
            )
        );
        Readiness memory r = g.index.replayReadiness();
        assertEq(r.manifestHash, g.index.manifestHash(), "readiness names the generation's hash");
        assertEq(r.hotAbiId, KernelDeploy.HOT_ABI_ID);
        assertEq(abi.encode(g.index.workModel()), abi.encode(IndexDoubleDefaults.workModel()));
    }

    function test_every_read_is_answered_at_the_index_address() public {
        _activate(address(g.index), g.index.manifestHash());
        FamilyId byType = FamilyId.wrap(Keys.familyId("by-type"));
        (Coverage c, uint64 from,,) = g.index.coverage(byType, ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(from, 1);
        assertEq(g.index.provenFrom(), 1);
        assertEq(g.index.buildDelegate(), address(0));
        assertTrue(g.index.replayReadiness().ready);
        // an unknown selector reverts in the reads contract, and the forward carries no value
        (bool ok,) = address(g.index).call(abi.encodeWithSignature("noSuchRead()"));
        assertFalse(ok, "unknown selector");
        (ok,) = address(g.index).call{value: 1}(abi.encodeCall(IIndexReads.provenFrom, ()));
        assertFalse(ok, "value refused");
    }

    function test_a_direct_call_answers_only_from_the_callers_claims() public {
        _activate(address(g.index), g.index.manifestHash());
        FamilyId byType = FamilyId.wrap(Keys.familyId("by-type"));
        // from an account without code the progress question cannot be asked: it reverts
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        g.reads.coverage(byType, ScopeKey.wrap(0));
        // a contract hears its own claim back (through 7 is not the ledger's 0: PARTIAL), nobody else's
        ProgressClaimer claimer = new ProgressClaimer();
        (Coverage c,, uint64 through) = claimer.ask(g.reads, byType);
        assertEq(uint8(c), uint8(Coverage.PARTIAL));
        assertEq(through, 7);
        (c,,,) = g.index.coverage(byType, ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "the index's answer is unchanged");
    }

    function test_the_generation_refuses_a_reads_contract_of_another_ledger() public {
        IndexReads other = new IndexReads(
            address(0x1234),
            KernelDeploy.HOT_ABI_ID,
            address(g.posting),
            address(g.bitmap),
            new Unit[](0),
            new DigestSpec[](0),
            IndexDoubleDefaults.workModel(),
            0,
            0
        );
        vm.expectRevert(abi.encodeWithSelector(E_PIN.selector, address(other), uint8(10)));
        new RealmIndex(k.proxy, address(0), address(other));
    }

    function test_activation_pins_the_reads_codehash() public {
        WrongReadsIndex bad = new WrongReadsIndex(k.proxy);
        bytes32 manifestHash = bad.manifestHash();
        vm.expectRevert(abi.encodeWithSelector(E_PIN.selector, address(bad), uint8(10)));
        _activate(address(bad), manifestHash);
    }

    function test_the_real_generation_activates_with_its_reads_contract() public {
        _activate(address(g.index), g.index.manifestHash());
        IGeneration1 ix = g.index;
        assertEq(ix.READS(), address(g.reads));
        assertEq(ix.READS_CODEHASH(), address(g.reads).codehash);
    }
}
