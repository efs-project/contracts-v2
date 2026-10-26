// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {FilesFixture} from "../profiles/FilesFixture.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {StateDigest} from "../harness/StateDigest.sol";
import {LedgerCore} from "../../src/core/LedgerCore.sol";
import {LedgerIngress} from "../../src/core/LedgerIngress.sol";
import {LedgerApply} from "../../src/core/LedgerApply.sol";
import {LedgerControl} from "../../src/core/LedgerControl.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    Purpose,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {ActivationSet, ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {Head, RecordHeader} from "../../src/interfaces/Views.sol";
import {AlreadyAdmitted, E_EXECUTION_DRIFT, E_EXECUTION_SET} from "../../src/interfaces/Errors.sol";

/// @notice The PM's fifth difficult behaviour at the Files level (design §12.3 "populated upgrade", §16.4 C2
///         subset): a Realm seeded with a folder and a file activates a new LedgerCore with a new ingress and
///         apply pin; every row outside the activation's scope is byte-identical, directory and file reads are
///         identical through the facets and the index before and after, a plan bound to the old execution set
///         is refused whole with its nonce intact, the pre-upgrade publication retries as AlreadyAdmitted, and
///         a new write lands under the new pins.
contract PopulatedUpgradeTest is FilesFixture {
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    Realm internal r;
    bytes32 internal p;
    LedgerReads internal reads;
    LedgerViews internal views;
    bytes32 internal rootSubject;
    bytes32 internal rootDir;
    bytes32 internal docsSubject;
    bytes32 internal docsDir;
    bytes32 internal docsName;
    bytes32 internal file;
    bytes32 internal rootRec;
    bytes32 internal readmeName;
    // the create-folder publication, kept for the exact retry
    uint64 internal folderNonce;
    bytes32 internal folderSet;
    bytes32 internal folderProfile;

    function setUp() public {
        _deployProfile();
        r = _realm(keccak256("files/upgrade"));
        _register(r);
        p = r.principal;
        reads = new LedgerReads();
        views = new LedgerViews();
        rootSubject = Keys.subject(p, keccak256("root"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("root"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(rootSubject));
        rootDir = Keys.record(typeIds[T_DIRECTORY], b[1]);
        _exec(a, b);
        // create folder
        docsSubject = Keys.subject(p, keccak256("docs"));
        a = new Action[](4);
        b = new bytes[](4);
        a[0] = _create(keccak256("docs"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(docsSubject));
        docsDir = Keys.record(typeIds[T_DIRECTORY], b[1]);
        (a[2], b[2]) = _publish(T_NAME, "docs");
        docsName = Keys.record(typeIds[T_NAME], b[2]);
        a[3] = _bind(Purpose.FOLDER, rootDir, keccak256("docs"), docsDir, 0);
        (folderNonce, folderSet, folderProfile) = _execKeep(a, b);
        // create file
        file = Keys.subject(p, keccak256("readme"));
        a = new Action[](5);
        b = new bytes[](5);
        a[0] = _create(keccak256("readme"));
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file), "Meeting at 10:00.\n"));
        rootRec = Keys.record(typeIds[T_ROOT], b[1]);
        (a[2], b[2]) = _publish(T_NAME, "readme.txt");
        readmeName = Keys.record(typeIds[T_NAME], b[2]);
        a[3] = _bind(Purpose.HEAD, file, 0, rootRec, 0);
        a[4] = _bind(Purpose.FOLDER, docsDir, keccak256("readme.txt"), file, 0);
        _exec(a, b);
    }

    // ---- builders ------------------------------------------------------------------------------------------

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function _publish(uint8 t, bytes memory body)
        internal
        view
        returns (Action memory a, bytes memory)
    {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeIds[t];
        a.bodyHashOrRecordId = keccak256(body);
        return (a, body);
    }

    function _bind(bytes32 purpose, bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _ctx(Action[] memory actions) internal view returns (Native memory c) {
        (c.nonce,) = r.hot.nonceOf(p);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), actions);
    }

    function _exec(Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 publication)
    {
        (publication,) = r.ledger.execute(actions, bodies, _ctx(actions), "");
    }

    function _execKeep(Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 nonce, bytes32 set, bytes32 profile)
    {
        Native memory c = _ctx(actions);
        r.ledger.execute(actions, bodies, c, "");
        return (c.nonce, c.expectedExecutionSet, c.expectedAcceptanceProfile);
    }

    function _folderActions() internal view returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](4);
        b = new bytes[](4);
        a[0] = _create(keccak256("docs"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(docsSubject));
        (a[2], b[2]) = _publish(T_NAME, "docs");
        a[3] = _bind(Purpose.FOLDER, rootDir, keccak256("docs"), docsDir, 0);
    }

    function _key(bytes32 purpose, bytes32 subject, bytes32 role) internal view returns (bytes32) {
        return Keys.binding(p, Keys.position(purpose, subject, role));
    }

    function _keys() internal view returns (StateDigest.LedgerKeys memory k) {
        k.recordIds = new bytes32[](5);
        k.recordIds[0] = rootDir;
        k.recordIds[1] = docsDir;
        k.recordIds[2] = docsName;
        k.recordIds[3] = rootRec;
        k.recordIds[4] = readmeName;
        k.subjectIds = new bytes32[](3);
        k.subjectIds[0] = rootSubject;
        k.subjectIds[1] = docsSubject;
        k.subjectIds[2] = file;
        (uint64 admissions,, uint64 bindings, uint64 publications) = r.hot.counts();
        k.admissionsThrough = admissions;
        k.publicationsThrough = publications;
        k.principalIds = new bytes32[](1);
        k.principalIds[0] = p;
        k.nonces = new uint64[](1);
        k.nonces[0] = folderNonce;
        k.bindingKeys = new bytes32[](3);
        k.bindingKeys[0] = _key(Purpose.FOLDER, rootDir, keccak256("docs"));
        k.bindingKeys[1] = _key(Purpose.HEAD, file, 0);
        k.bindingKeys[2] = _key(Purpose.FOLDER, docsDir, keccak256("readme.txt"));
        k.positionKeys = new bytes32[](3);
        k.positionKeys[0] = Keys.position(Purpose.FOLDER, rootDir, keccak256("docs"));
        k.positionKeys[1] = Keys.position(Purpose.HEAD, file, 0);
        k.positionKeys[2] = Keys.position(Purpose.FOLDER, docsDir, keccak256("readme.txt"));
        k.bindingOrdinalsThrough = bindings;
        k.revisionsThrough = 1;
    }

    /// Everything a client reads for the directory and the file, through both facets and the index.
    function _readsHash() internal view returns (bytes32 h) {
        address l = address(r.ledger);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = rootDir;
        ids[1] = docsDir;
        ids[2] = rootRec;
        for (uint256 i; i < 3; ++i) {
            (Status st, RecordHeader memory hd, bytes memory body,) = reads.record(l, ids[i]);
            h = keccak256(abi.encode(h, st, hd, body));
        }
        StateDigest.LedgerKeys memory k = _keys();
        (Head[] memory heads,) = views.heads(l, k.bindingKeys);
        h = keccak256(abi.encode(h, heads));
        for (uint256 t; t < 4; ++t) {
            (, uint64 count, uint64 live, uint64 last,) = r.g.index
                .postingHeadOf(
                    FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(typeIds[t]), 0, 0
                );
            h = keccak256(abi.encode(h, count, live, last));
        }
        (uint64 sc, uint64 sl,, uint48 bits,, uint64 e0) =
            r.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(p, Purpose.FOLDER, rootDir)));
        h = keccak256(abi.encode(h, sc, sl, bits, e0));
        (sc, sl,, bits,, e0) =
            r.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(p, Purpose.FOLDER, docsDir)));
        h = keccak256(abi.encode(h, sc, sl, bits, e0));
    }

    function testPopulatedUpgradeKeepsEveryRowAndEveryRead() public {
        bytes32 rowsBefore = StateDigest.rowsOnly(r.k.proxy, _keys());
        bytes32 readsBefore = _readsHash();
        bytes32 oldSet = r.hot.executionSet();
        (uint64 admissionsBefore,,, uint64 publicationsBefore) = r.hot.counts();
        (uint64 nonceBefore,) = r.hot.nonceOf(p);

        // a new implementation with a new ingress pin (another immutable, another codehash) and apply pin
        LedgerIngress ingress2 = new LedgerIngress(address(0x5151));
        LedgerApply apply2 = new LedgerApply();
        LedgerControl control2 = new LedgerControl(address(ingress2), address(apply2), bytes32(0));
        LedgerCore core2 = new LedgerCore(
            address(ingress2), address(apply2), address(control2), KernelDeploy.HOT_ABI_ID
        );
        assertTrue(
            address(ingress2).codehash != address(r.k.ingress).codehash, "a new ingress build"
        );

        // §8.3 step 2: the upgrade alone opens no write (entry tripwire)
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(r.k.proxy, ADMIN_SLOT)))));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(r.k.proxy), address(core2), "");
        (Action[] memory fa, bytes[] memory fb) = _folderActions();
        Native memory stale;
        stale.nonce = nonceBefore;
        stale.expectedExecutionSet = oldSet;
        vm.expectRevert(
            abi.encodeWithSelector(
                E_EXECUTION_DRIFT.selector, address(core2), address(r.k.implementation)
            )
        );
        r.ledger.execute(fa, fb, stale, "");

        // steps 4–5: the registry, then the ledger
        KernelDeploy.Kernel memory k2 = r.k;
        k2.ingress = ingress2;
        k2.applyDelegate = apply2;
        k2.control = control2;
        k2.implementation = core2;
        ActivationSet memory set = KernelDeploy.genesisSet(
            k2, address(this), address(r.registryImpl), address(r.g.index), r.g.index.manifestHash()
        );
        set.revision = 2;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, r.k.proxy);
        r.registry.activate(2);
        ILedgerControl(r.k.proxy).activate(set);
        assertEq(r.hot.revision(), 2);
        assertEq(r.hot.ingress(), address(ingress2));
        assertEq(r.hot.applyDelegate(), address(apply2));
        assertTrue(r.hot.executionSet() != oldSet);

        // every row outside the activation's scope is byte-identical; every read is identical
        assertEq(StateDigest.rowsOnly(r.k.proxy, _keys()), rowsBefore, "rows outside the scope");
        assertEq(_readsHash(), readsBefore, "directory and file reads");
        (uint64 admissions,,, uint64 publications) = r.hot.counts();
        assertEq(admissions, admissionsBefore);
        assertEq(publications, publicationsBefore);

        // a plan bound to the old execution set is refused whole with the nonce intact
        Action[] memory edit = new Action[](2);
        bytes[] memory eb = new bytes[](2);
        (edit[0], eb[0]) =
            _publish(T_CHILD, bytes.concat(abi.encode(rootRec, file), "Meeting at 11:00.\n"));
        edit[1] = _bind(Purpose.HEAD, file, 0, Keys.record(typeIds[T_CHILD], eb[0]), 1);
        Native memory bound = _ctx(edit);
        bound.expectedExecutionSet = oldSet;
        bytes32 liveSet = r.hot.executionSet();
        vm.expectRevert(abi.encodeWithSelector(E_EXECUTION_SET.selector, oldSet, liveSet));
        r.ledger.execute(edit, eb, bound, "");
        (uint64 nonceAfter,) = r.hot.nonceOf(p);
        assertEq(nonceAfter, nonceBefore, "nonce intact");

        // the pre-upgrade publication, retried exactly, is AlreadyAdmitted (the retry compare precedes every check)
        Native memory retry;
        retry.nonce = folderNonce;
        retry.expectedExecutionSet = folderSet;
        retry.expectedAcceptanceProfile = folderProfile;
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(2)));
        r.ledger.execute(fa, fb, retry, "");

        // a new write lands under the new pins and the index folds it
        uint64 pub = _exec(edit, eb);
        assertEq(pub, publicationsBefore + 1);
        (Head[] memory heads,) = views.heads(r.k.proxy, _keys().bindingKeys);
        assertEq(heads[1].revision, 2, "the HEAD moved under the new kernel");
        (, uint64 count,,,) = r.g.index
            .postingHeadOf(
                FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(typeIds[T_CHILD]), 0, 0
            );
        assertEq(count, 1);
        // the directory listing is untouched by the edit
        (uint64 sc, uint64 sl,,,,) =
            r.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(p, Purpose.FOLDER, docsDir)));
        assertEq(sc, 1);
        assertEq(sl, 1);
    }
}
