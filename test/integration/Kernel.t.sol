// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {StateDigest} from "../harness/StateDigest.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
import {AcceptAll, RejectAll} from "../harness/doubles/Acceptors.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {Phase} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {Readiness, Unit, FamilyEntry} from "../../src/interfaces/Index.sol";
import {
    AlreadyAdmitted,
    E_NONCE,
    E_REJECTED,
    E_TRANSITION,
    E_PUBLICATION_ACTIVE
} from "../../src/interfaces/Errors.sol";

/// @notice The kernel vertical on the native lane against the registry and index doubles: genesis
///         activation, one publication of every row kind, the retry law, rollback on refusal.
contract KernelTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    PrefixAgreement internal index;
    ILedger internal ledger;
    ILedgerHot internal hot;
    AcceptAll internal acceptAll;
    RejectAll internal rejectAll;

    bytes32 internal constant TYPE_OK = keccak256("test/type/ok");
    bytes32 internal constant TYPE_REJECT = keccak256("test/type/reject");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal principal;

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        index = new PrefixAgreement(k.proxy);
        index.setReadiness(_readiness(0, 0));
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), address(index), index.manifestHash()
        );
        ILedgerControl(k.proxy).activate(set);

        acceptAll = new AcceptAll();
        rejectAll = new RejectAll();
        registry.setType(TYPE_OK, _nativeType(address(acceptAll)), new bytes32[](0));
        registry.setType(TYPE_REJECT, _nativeType(address(rejectAll)), new bytes32[](0));
        principal = Keys.principalFor(address(this), hot.realmOrigin());
    }

    function _readiness(uint64 admissions, uint64 publications)
        internal
        view
        returns (Readiness memory r)
    {
        r.version = 1;
        r.ledger = k.proxy;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = KernelDeploy.HOT_ABI_ID;
        r.manifestHash = index.manifestHash();
        r.provenFrom = 1;
        r.completedAdmission = admissions;
        r.completedPublication = publications;
        r.ready = true;
        r.units = new Unit[](0);
        r.families = new FamilyEntry[](0);
    }

    function _nativeType(address rule) internal view returns (TypeInfo memory info) {
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = rule;
        info.ruleId = rule.codehash;
        info.policyRows = 1;
        info.policyRow = 1;
    }

    function _native(uint64 nonce) internal pure returns (Native memory ctx) {
        ctx.nonce = nonce;
    }

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function _publish(bytes32 typeId, bytes memory body) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function _bind(bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = FOLDER;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _keys() internal pure returns (StateDigest.LedgerKeys memory key) {
        key.admissionsThrough = 8;
        key.publicationsThrough = 4;
        key.revisionsThrough = 2;
    }

    // ---- genesis ---------------------------------------------------------------------------------------

    function testGenesisActivationOpensWrites() public view {
        assertEq(hot.revision(), 1);
        assertEq(hot.index(), address(index));
        assertEq(hot.registry(), address(registry));
        assertEq(hot.controller(), address(this));
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE);
        (uint64 genesisChain, uint64 accepted, uint32 rev, bool frozen) = hot.control();
        assertEq(genesisChain, block.chainid);
        assertEq(accepted, block.chainid);
        assertEq(rev, 1);
        assertFalse(frozen);
        assertTrue(hot.executionSet() != 0);
        assertEq(hot.layoutId(), Layout.LAYOUT_ID);
        assertEq(hot.ingress(), address(k.ingress));
        assertEq(hot.applyDelegate(), address(k.applyDelegate));
    }

    function testWritesAreDisabledBeforeGenesisActivation() public {
        KernelDeploy.Kernel memory fresh =
            KernelDeploy.deploy(address(this), address(registry), keccak256("other"));
        Action[] memory actions = new Action[](1);
        actions[0] = _create(keccak256("s"));
        bytes[] memory bodies = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(E_TRANSITION.selector, uint32(1), type(uint48).max));
        ILedger(fresh.proxy).execute(actions, bodies, _native(0), "");
    }

    // ---- one publication of create, publish and bind --------------------------------------------------------

    function testCreatePublishBind() public {
        bytes memory body = "hello, efs";
        bytes32 salt = keccak256("file-1");
        bytes32 subject = Keys.subject(principal, salt);
        bytes32 recordId = Keys.recordFromHash(TYPE_OK, keccak256(body));
        Action[] memory actions = new Action[](3);
        actions[0] = _create(salt);
        actions[1] = _publish(TYPE_OK, body);
        actions[2] = _bind(subject, keccak256("name"), recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;

        (uint64 publication, uint64 firstAdmission) =
            ledger.execute(actions, bodies, _native(0), "");
        assertEq(publication, 1);
        assertEq(firstAdmission, 1);

        (uint64 admissions, uint64 records, uint64 bindings, uint64 publications) = hot.counts();
        assertEq(admissions, 3);
        assertEq(records, 1);
        assertEq(bindings, 1);
        assertEq(publications, 1);
        assertEq(hot.subjectCreatedAt(subject), 1);
        (bytes32 typeId, uint64 fa, uint32 len, uint64 occ, uint8 carrier) =
            hot.recordHeader(recordId);
        assertEq(typeId, TYPE_OK);
        assertEq(fa, 2);
        assertEq(len, body.length);
        assertEq(occ, 1);
        assertEq(carrier, 0);
        bytes32 key = Keys.binding(principal, Keys.position(FOLDER, subject, keccak256("name")));
        (
            uint8 state,
            uint64 revision,
            uint64 admission,
            uint8 targetKind,,
            uint64 ordinal,
            bytes32 target
        ) = hot.head(key);
        assertEq(state, 1);
        assertEq(revision, 1);
        assertEq(admission, 3);
        assertEq(targetKind, 1);
        assertEq(ordinal, 1);
        assertEq(target, recordId);
        (uint64 nonce, uint64 vmv) = hot.nonceOf(principal);
        assertEq(nonce, 1);
        assertEq(vmv, 1);
        (uint64 pub, bytes32 digest) = hot.publicationAt(principal, 0);
        assertEq(pub, 1);
        assertTrue(digest != 0);
        assertEq(index.prefixCalls(), 3);
        assertEq(index.effectsSeen(), 3);
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE);
    }

    // ---- the retry law -------------------------------------------------------------------------------------

    function testExactRetryIsAlreadyAdmittedAndWritesNothing() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _create(keccak256("s1"));
        bytes[] memory bodies = new bytes[](1);
        ledger.execute(actions, bodies, _native(0), "");
        bytes32 before = StateDigest.ledger(k.proxy, _keys());
        vm.roll(block.number + 10);
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(1)));
        ledger.execute(actions, bodies, _native(0), "");
        assertEq(StateDigest.ledger(k.proxy, _keys()), before);
        // a different plan under the consumed nonce names the publication that took it
        actions[0] = _create(keccak256("s2"));
        vm.expectRevert(abi.encodeWithSelector(E_NONCE.selector, principal, uint64(0), uint64(1)));
        ledger.execute(actions, bodies, _native(0), "");
        // a nonce that is not next is refused with publication 0
        vm.expectRevert(abi.encodeWithSelector(E_NONCE.selector, principal, uint64(5), uint64(0)));
        ledger.execute(actions, bodies, _native(5), "");
        // the next nonce lands
        ledger.execute(actions, bodies, _native(1), "");
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 2);
    }

    // ---- rollback on refusal ------------------------------------------------------------------------------

    function testRefusedValidationRollsBackEverything() public {
        Action[] memory ok = new Action[](1);
        ok[0] = _create(keccak256("first"));
        bytes[] memory none = new bytes[](1);
        ledger.execute(ok, none, _native(0), "");
        bytes32 before = StateDigest.ledger(k.proxy, _keys());
        uint64 prefixBefore = index.prefixCalls();

        bytes memory body = "will be refused";
        Action[] memory actions = new Action[](3);
        actions[0] = _create(keccak256("second"));
        actions[1] = _publish(TYPE_OK, body);
        actions[2] = _publish(TYPE_REJECT, body);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        bodies[2] = body;
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(2), TYPE_REJECT));
        ledger.execute(actions, bodies, _native(1), "");

        assertEq(StateDigest.ledger(k.proxy, _keys()), before, "no row changed");
        (uint64 admissions, uint64 records,, uint64 publications) = hot.counts();
        assertEq(admissions, 1);
        assertEq(records, 0);
        assertEq(publications, 1);
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 1, "the nonce was not consumed");
        assertEq(
            index.prefixCalls(),
            prefixBefore,
            "the index double's state reverted with the publication"
        );
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE, "the lock cleared with the frame");
        (uint64 pub,) = hot.publicationAt(principal, 1);
        assertEq(pub, 0);
    }
}
