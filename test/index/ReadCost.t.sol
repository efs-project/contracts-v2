// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";

/// @notice What each read of the index costs a caller (design §5.11): one cold `view` call per row against the
///         real generation-1 index over the real kernel, after one seed publication. Every account the call can
///         touch is cooled first (the index, its stores, its reads contract when it has one, the ledger proxy
///         and implementation, the registry), so each row is the cost of a call of its own in a fresh
///         transaction. The same file measured the index before its reads moved out, which is how the hop's
///         added gas is reported.
contract ReadCostTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    address internal ix;
    bytes32 internal constant TYPE_OK = keccak256("test/type/ok");
    bytes32 internal constant FOLDER = keccak256("efs/purpose/folder/1");
    bytes32 internal constant NAME = keccak256("name");
    bytes32 internal recordId;
    bytes32 internal scopeKey;

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        DigestSpec[] memory specs = new DigestSpec[](1);
        specs[0] = DigestSpec({typeId: TYPE_OK, wordIndex: 0, algorithm: 1});
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), specs);
        ix = address(g.index);
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k, address(this), address(registry), ix, IIndexReads(ix).manifestHash()
                )
            );
        AcceptAll acceptAll = new AcceptAll();
        TypeInfo memory info;
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = address(acceptAll);
        info.ruleId = address(acceptAll).codehash;
        info.policyRows = 1;
        info.policyRow = 1;
        registry.setType(TYPE_OK, info, new bytes32[](0));
        bytes32 principal = Keys.principalFor(address(this), ILedgerHot(k.proxy).realmOrigin());
        bytes32 salt = keccak256("file-1");
        bytes32 subject = Keys.subject(principal, salt);
        bytes memory body = "0123456789abcdef0123456789abcdef-tail";
        recordId = Keys.recordFromHash(TYPE_OK, keccak256(body));
        scopeKey = Keys.scope(principal, FOLDER, subject);
        Action[] memory actions = new Action[](3);
        actions[0].kind = ActionKind.CREATE;
        actions[0].saltOrStrength = salt;
        actions[1].kind = ActionKind.PUBLISH;
        actions[1].typeId = TYPE_OK;
        actions[1].bodyHashOrRecordId = keccak256(body);
        actions[2].kind = ActionKind.BIND;
        actions[2].purpose = FOLDER;
        actions[2].subject = subject;
        actions[2].role = NAME;
        actions[2].target = recordId;
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        Native memory ctx;
        ILedger(k.proxy).execute(actions, bodies, ctx, "");
    }

    function _cool() internal {
        vm.cool(ix);
        vm.cool(address(g.posting));
        vm.cool(address(g.bitmap));
        vm.cool(k.proxy);
        vm.cool(address(k.implementation));
        vm.cool(address(k.ingress));
        vm.cool(address(registry));
        (bool ok, bytes memory ret) = ix.staticcall(abi.encodeWithSignature("readsContract()"));
        if (ok && ret.length >= 32) vm.cool(abi.decode(ret, (address)));
    }

    function _row(string memory name, bytes memory data) internal {
        _cool();
        uint256 before = gasleft();
        (bool ok,) = ix.staticcall(data);
        uint256 used = before - gasleft();
        assertTrue(ok, name);
        emit log_named_uint(string.concat("read ", name, " gas"), used);
    }

    function test_read_costs() public {
        FamilyId byType = FamilyId.wrap(Keys.familyId("by-type"));
        FamilyId live = FamilyId.wrap(Keys.familyId("live-scope"));
        _row("manifestHash", abi.encodeCall(IIndexReads.manifestHash, ()));
        _row("manifest", abi.encodeCall(IIndexReads.manifest, ()));
        _row("workModel", abi.encodeCall(IIndexReads.workModel, ()));
        _row("digestSpecCount", abi.encodeCall(IIndexReads.digestSpecCount, (TYPE_OK)));
        _row("coverage", abi.encodeCall(IIndexReads.coverage, (live, ScopeKey.wrap(scopeKey))));
        _row(
            "coverageOfType",
            abi.encodeCall(IIndexReads.coverageOfType, (byType, TypeId.wrap(TYPE_OK)))
        );
        _row(
            "coverageOfSpec",
            abi.encodeCall(
                IIndexReads.coverageOfSpec,
                (FamilyId.wrap(Keys.familyId("digest")), TypeId.wrap(TYPE_OK), 0)
            )
        );
        _row("coverageOfDigest", abi.encodeCall(IIndexReads.coverageOfDigest, (1)));
        _row("provenFrom", abi.encodeCall(IIndexReads.provenFrom, ()));
        _row("progress", abi.encodeCall(IIndexReads.progress, ()));
        _row(
            "postingHeadOf",
            abi.encodeCall(IIndexReads.postingHeadOf, (byType, TypeId.wrap(TYPE_OK), 0, bytes32(0)))
        );
        _row(
            "postingSliceOf",
            abi.encodeCall(
                IIndexReads.postingSliceOf, (byType, TypeId.wrap(TYPE_OK), 0, bytes32(0), 0, 8)
            )
        );
        _row("occurrencesOf", abi.encodeCall(IIndexReads.occurrencesOf, (recordId)));
        _row("ledger", abi.encodeCall(IIndexReads.ledger, ()));
        _row("postingStore", abi.encodeCall(IIndexReads.postingStore, ()));
        _row("bitmapStore", abi.encodeCall(IIndexReads.bitmapStore, ()));
        _row("buildDelegate", abi.encodeCall(IIndexReads.buildDelegate, ()));
        _row("replayReadiness", abi.encodeCall(IRealmIndex.replayReadiness, ()));
    }
}
