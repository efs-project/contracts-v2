// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {FacetRegistry, RevertingEverything, RowCompleteApply} from "./FacetDoubles.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {LedgerApply} from "../../src/core/LedgerApply.sol";
import {LedgerCore} from "../../src/core/LedgerCore.sol";
import {LedgerControl} from "../../src/core/LedgerControl.sol";
import {LedgerIngress} from "../../src/core/LedgerIngress.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {
    BasisCommit,
    History,
    Retention,
    STATUS_VOCABULARY_ID,
    Status
} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {
    ActivationSet,
    ComponentSet,
    ILedgerControl,
    RealmInit
} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {
    AcceptanceBasis,
    AdmissionRow,
    Description,
    Evidence,
    Head,
    PublicationView,
    RecordHeader,
    Revision
} from "../../src/interfaces/Views.sol";
import {E_LAYOUT, E_READSET_SHAPE, E_RESERVED} from "../../src/interfaces/Errors.sol";

/// @notice The kernel vertical (design §16 preamble) with both read facets: genesis activation against the
///         registry double and the `PrefixAgreement` index double, two NATIVE Types (one with a checked
///         reference), a policy row and a role row, and one mixed history of eight publications by two
///         principals (a contract principal — this test — and a key principal on the native lane) covering
///         every S1 action kind and every binding transition. Every publication's `Published.effectsHash` and
///         every head after every publication are captured for the suites.
abstract contract FacetFixture is Test {
    bytes32 internal constant TYPE_OK = keccak256("efs2/test/readers/type/ok");
    bytes32 internal constant TYPE_REF = keccak256("efs2/test/readers/type/ref");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant ROLE_NAME = keccak256("efs2/test/readers/role/name");
    bytes32 internal constant SALT = keccak256("efs2/test/readers/realm-salt");
    bytes32 internal constant SALT1 = keccak256("efs2/test/readers/subject/1");
    bytes32 internal constant SALT2 = keccak256("efs2/test/readers/subject/2");
    uint32 internal constant VALIDATION_GAS = 50_000;
    uint64 internal constant POLICY1_AT = 100;
    uint64 internal constant POLICY2_AT = 200;
    uint64 internal constant REF_POLICY_AT = 300;
    uint64 internal constant ROLE_AT = 400;

    struct Pub {
        address author;
        bytes32 principalId;
        uint64 nonce;
        bytes32 effectsHash;
        bytes32 publicationId;
        uint64 firstAdmission;
        uint8 leafCount;
        bytes32 actionsHash;
        uint256 blockNumber;
        bool hasBind;
    }

    struct HeadsAtCapture {
        uint64 lastAdmission;
        Status status;
        uint8 selectedIndex;
        bytes32 target;
    }

    struct HeadCapture {
        bytes32 key;
        uint64 lastAdmission;
        Head head;
    }

    KernelDeploy.Kernel internal k;
    FacetRegistry internal registry;
    PrefixAgreement internal index;
    ILedger internal ledger;
    ILedgerHot internal hot;
    LedgerReads internal reads;
    LedgerViews internal views;
    AcceptAll internal acceptAll;
    AcceptAll internal policyRule;

    ComponentSet internal genesisComponents;
    bytes32 internal genesisExecutionSet;
    uint256 internal genesisBlock;
    uint256 internal genesisTimestamp;

    address internal alice;
    bytes32 internal p1; // this test: a contract principal
    bytes32 internal p2; // alice: a key principal
    bytes32 internal p3; // never publishes
    bytes32 internal s1;
    bytes32 internal s2;
    bytes internal body70;
    bytes internal refBody;
    bytes32 internal r1;
    bytes32 internal r2;
    bytes32 internal r3;
    bytes32 internal r4;
    bytes32 internal posName; // (FOLDER, s1, ROLE_NAME)
    bytes32 internal posZero; // (FOLDER, s1, 0)
    bytes32 internal posName2; // (FOLDER, s2, ROLE_NAME)

    Pub[] internal pubs;
    HeadsAtCapture[] internal headsAtCaptures;
    HeadCapture[] internal headCaptures;

    function _deployKernel(address registry_) internal virtual returns (KernelDeploy.Kernel memory);

    function setUp() public virtual {
        registry = new FacetRegistry();
        k = _deployKernel(address(registry));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        registry.setCatalogCount(2);
        index = new PrefixAgreement(k.proxy);
        index.setReadiness(_readiness());
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), address(index), index.manifestHash()
        );
        genesisComponents = set.components;
        genesisExecutionSet = set.expectedExecutionSet;
        genesisBlock = vm.getBlockNumber();
        genesisTimestamp = vm.getBlockTimestamp();
        ILedgerControl(k.proxy).activate(set);
        vm.roll(vm.getBlockNumber() + 1);

        reads = new LedgerReads();
        views = new LedgerViews();
        _registerTypes();

        alice = makeAddr("alice");
        p1 = Keys.principalFor(address(this), hot.realmOrigin());
        p2 = Keys.principal(alice);
        p3 = Keys.principal(makeAddr("nobody"));
        s1 = Keys.subject(p1, SALT1);
        s2 = Keys.subject(p2, SALT2);
        body70 = abi.encodePacked(
            keccak256("efs2/test/readers/w0"), keccak256("efs2/test/readers/w1"), hex"a1b2c3d4e5f6"
        );
        r1 = Keys.record(TYPE_OK, body70);
        refBody = abi.encodePacked(r1, "tail.");
        r2 = Keys.record(TYPE_REF, refBody);
        r3 = Keys.record(TYPE_OK, "second");
        r4 = Keys.record(TYPE_OK, "alice");
        posName = Keys.position(FOLDER, s1, ROLE_NAME);
        posZero = Keys.position(FOLDER, s1, 0);
        posName2 = Keys.position(FOLDER, s2, ROLE_NAME);
        _scenario();
    }

    function _readiness() internal view returns (Readiness memory r) {
        r.version = 1;
        r.ledger = k.proxy;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = KernelDeploy.HOT_ABI_ID;
        r.manifestHash = index.manifestHash();
        r.provenFrom = 1;
        r.ready = true;
        r.units = new Unit[](0);
        r.families = new FamilyEntry[](0);
    }

    function _registerTypes() internal {
        acceptAll = new AcceptAll();
        policyRule = new AcceptAll();
        TypeInfo memory ok;
        ok.grade = 3;
        ok.refHeaderWords = 1;
        ok.validationGas = VALIDATION_GAS;
        ok.mandatory = address(acceptAll);
        ok.ruleId = address(acceptAll).codehash;
        ok.policyRows = 2;
        ok.policyRow = 2;
        ok.policy = address(policyRule);
        ok.policyCodehash = address(policyRule).codehash;
        registry.setType(TYPE_OK, ok, new bytes32[](0));
        registry.setPolicyRow(TYPE_OK, 1, FacetRegistry.PolicyRow(address(0), 0, POLICY1_AT, 1));
        registry.setPolicyRow(
            TYPE_OK,
            2,
            FacetRegistry.PolicyRow(
                address(policyRule), address(policyRule).codehash, POLICY2_AT, 2
            )
        );
        TypeInfo memory ref;
        ref.grade = 3;
        ref.refCount = 1;
        ref.refHeaderWords = 1;
        ref.mandatory = address(acceptAll);
        ref.ruleId = address(acceptAll).codehash;
        ref.policyRows = 1;
        ref.policyRow = 1;
        bytes32[] memory refTypes = new bytes32[](1);
        refTypes[0] = TYPE_OK;
        registry.setType(TYPE_REF, ref, refTypes);
        registry.setPolicyRow(TYPE_REF, 1, FacetRegistry.PolicyRow(address(0), 0, REF_POLICY_AT, 3));
        registry.addRoleRow(FOLDER, ROLE_NAME, TYPE_OK, ROLE_AT);
    }

    // ---- the history -----------------------------------------------------------------------------------
    //
    //  pub  author nonce  admissions
    //   1   p1     0      1 CREATE s1 | 2 PUBLISH r1 (70 B) | 3 BIND (s1,name)→r1 FIRST_BIND
    //   2   p1     1      4 PUBLISH r2 (ref → r1) | 5 REUSE r1 | 6 PUBLISH r3
    //   3   p1     2      7 BIND (s1,name)→r3 REBIND | 8 BIND (s1,0)→s1 FIRST_BIND subject | 9 WITHDRAW 5
    //   4   p1     3      10 UNBIND (s1,name) MASK
    //   5   p1     4      11 BIND (s1,name)→r1 RESTORE | 12 RELEASE (s1,0) from BOUND
    //   6   p2     0      13 CREATE s2 | 14 PUBLISH r4 | 15 BIND (s1,name)→r4 | 16 BIND (s2,name)→r1
    //   7   p2     1      17 UNBIND (s1,name) MASK | 18 RELEASE (s1,name) from MASKED | 19 WITHDRAW 14
    //   8   p2     2      20 PUBLISH r4 again (not fresh)

    function _scenario() internal {
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(SALT1);
        a[1] = _publish(TYPE_OK, body70);
        b[1] = body70;
        a[2] = _bind(s1, ROLE_NAME, r1, 0);
        _exec(address(this), 0, a, b);

        a = new Action[](3);
        b = new bytes[](3);
        a[0] = _publish(TYPE_REF, refBody);
        b[0] = refBody;
        a[1] = _reuse(TYPE_OK, r1);
        a[2] = _publish(TYPE_OK, "second");
        b[2] = "second";
        _exec(address(this), 1, a, b);

        a = new Action[](3);
        b = new bytes[](3);
        a[0] = _bind(s1, ROLE_NAME, r3, 1);
        a[1] = _bind(s1, 0, s1, 0);
        a[2] = _withdraw(5);
        _exec(address(this), 2, a, b);

        a = new Action[](1);
        b = new bytes[](1);
        a[0] = _unbind(s1, ROLE_NAME, 2);
        _exec(address(this), 3, a, b);

        a = new Action[](2);
        b = new bytes[](2);
        a[0] = _bind(s1, ROLE_NAME, r1, 3);
        a[1] = _release(s1, 0, 1);
        _exec(address(this), 4, a, b);

        a = new Action[](4);
        b = new bytes[](4);
        a[0] = _create(SALT2);
        a[1] = _publish(TYPE_OK, "alice");
        b[1] = "alice";
        a[2] = _bind(s1, ROLE_NAME, r4, 0);
        a[3] = _bind(s2, ROLE_NAME, r1, 0);
        _exec(alice, 0, a, b);

        a = new Action[](3);
        b = new bytes[](3);
        a[0] = _unbind(s1, ROLE_NAME, 1);
        a[1] = _release(s1, ROLE_NAME, 2);
        a[2] = _withdraw(14);
        _exec(alice, 1, a, b);

        a = new Action[](1);
        b = new bytes[](1);
        a[0] = _publish(TYPE_OK, "alice");
        b[0] = "alice";
        _exec(alice, 2, a, b);
    }

    /// Native execution as `author` (an EOA author must also be tx.origin: E_NATIVE_AMBIGUOUS), capturing the
    /// `Published` event, then the heads and the ordered first-touch answer at (s1, name).
    function _exec(address author, uint64 nonce, Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 publication)
    {
        Native memory ctx;
        ctx.nonce = nonce;
        vm.recordLogs();
        if (author != address(this)) vm.prank(author, author);
        (publication,) = ledger.execute(actions, bodies, ctx, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Pub memory p;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != k.proxy || logs[i].topics[0] != ILedger.Published.selector) {
                continue;
            }
            p.publicationId = logs[i].topics[2];
            p.principalId = logs[i].topics[3];
            (, p.firstAdmission, p.leafCount, p.effectsHash,) =
                abi.decode(logs[i].data, (uint8, uint64, uint8, bytes32, uint32));
        }
        p.author = author;
        p.nonce = nonce;
        p.actionsHash = keccak256(abi.encode(actions));
        p.blockNumber = vm.getBlockNumber();
        for (uint256 i; i < actions.length; ++i) {
            uint8 kind = actions[i].kind;
            if (kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE)
            {
                p.hasBind = true;
            }
        }
        pubs.push(p);
        assertEq(pubs.length, publication, "publication ordinal");
        _checkpoint();
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _checkpoint() internal {
        (uint64 admissions,,,) = hot.counts();
        bytes32[] memory order = new bytes32[](2);
        order[0] = p2;
        order[1] = p1;
        (Status st, Head memory selected, uint8 idx,,) = views.headsAt(k.proxy, order, posName);
        headsAtCaptures.push(HeadsAtCapture(admissions, st, idx, selected.target));
        bytes32[4] memory keys = [
            Keys.binding(p1, posName),
            Keys.binding(p1, posZero),
            Keys.binding(p2, posName),
            Keys.binding(p2, posName2)
        ];
        for (uint256 i; i < 4; ++i) {
            (, Head memory h) = reads.head(k.proxy, keys[i]);
            headCaptures.push(HeadCapture(keys[i], admissions, h));
        }
    }

    // ---- action builders ---------------------------------------------------------------------------------

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function _publish(bytes32 typeId, bytes memory body) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function _reuse(bytes32 typeId, bytes32 recordId) internal pure returns (Action memory a) {
        a.kind = ActionKind.REUSE;
        a.typeId = typeId;
        a.bodyHashOrRecordId = recordId;
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

    function _unbind(bytes32 subject, bytes32 role, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.UNBIND;
        a.purpose = FOLDER;
        a.subject = subject;
        a.role = role;
        a.expectedRevision = expected;
    }

    function _release(bytes32 subject, bytes32 role, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a = _unbind(subject, role, expected);
        a.kind = ActionKind.RELEASE;
    }

    function _withdraw(uint64 admission) internal pure returns (Action memory a) {
        a.kind = ActionKind.WITHDRAW;
        a.target = bytes32(uint256(admission));
    }

    // ---- helpers -------------------------------------------------------------------------------------------

    /// Whether the kernel under test records the bind-row coordinates (`bindingOrdinal`, `expectedRevision`)
    /// that design §4.3 specifies (row 3 is the first BIND).
    function _rowsComplete() internal view returns (bool) {
        (, uint48 ordinal,,,,,,,) = _rawRowMeta(3);
        return ordinal != 0;
    }

    function _rawRowMeta(uint64 ordinal)
        internal
        view
        returns (
            uint8 kind,
            uint48 bindingOrdinal,
            uint48 expectedRevision,
            uint48 prevAdmission,
            uint8 withdrawn,
            uint16 policyRow,
            uint16 roleRow,
            uint8 targetKind,
            uint48 publication
        )
    {
        bytes32 w = vm.load(k.proxy, bytes32(Layout.admissionsRowsSlot(ordinal)));
        (
            kind,,
            publication,
            bindingOrdinal,
            expectedRevision,
            prevAdmission,
            withdrawn,
            policyRow,
            roleRow,
            targetKind
        ) = Layout.unpackAdmissionRowWord0(w);
    }

    function _st(Status a, Status b, string memory m) internal pure {
        assertEq(uint8(a), uint8(b), m);
    }

    function _assertHead(Head memory a, Head memory b, string memory m) internal pure {
        assertEq(a.state, b.state, string.concat(m, ": state"));
        assertEq(a.revision, b.revision, string.concat(m, ": revision"));
        assertEq(a.admission, b.admission, string.concat(m, ": admission"));
        assertEq(a.targetKind, b.targetKind, string.concat(m, ": targetKind"));
        assertEq(a.prevAdmission, b.prevAdmission, string.concat(m, ": prevAdmission"));
        assertEq(a.bindingOrdinal, b.bindingOrdinal, string.concat(m, ": bindingOrdinal"));
        assertEq(a.notAfter, b.notAfter, string.concat(m, ": notAfter"));
        assertEq(a.target, b.target, string.concat(m, ": target"));
    }

    function _hotHead(bytes32 key) internal view returns (Head memory h) {
        (
            h.state,
            h.revision,
            h.admission,
            h.targetKind,
            h.prevAdmission,
            h.bindingOrdinal,
            h.target
        ) = hot.head(key);
    }

    function _sub(bytes memory b, uint256 from, uint256 to)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
    }

    function _setRealmWordBits(uint256 offset, uint256 shift, uint256 width, uint256 value)
        internal
    {
        bytes32 slot = bytes32(uint256(Layout.LEDGER_REALM_ROOT) + offset);
        uint256 w = uint256(vm.load(k.proxy, slot));
        uint256 mask = ((uint256(1) << width) - 1) << shift;
        vm.store(k.proxy, slot, bytes32((w & ~mask) | (value << shift)));
    }
}

/// @notice The facet suite (design §5.7, §16.3 `readers`), run against two kernels by the contracts below.
abstract contract FacetSuite is FacetFixture {
    // =============================================================================================
    // Exact rows: every LedgerReads row equals the hot getters and the raw slots
    // =============================================================================================

    function testCountsAndBasis() public view {
        (uint64 admissions, uint64 records, uint64 bindings, uint64 publications) = hot.counts();
        assertEq(admissions, 20);
        assertEq(records, 4);
        assertEq(bindings, 4);
        assertEq(publications, 8);
        BasisCommit memory b = reads.basis(k.proxy);
        assertEq(b.executionSet, hot.executionSet());
        assertEq(b.executionSet, genesisExecutionSet);
        assertEq(b.revision, 1);
        assertEq(b.indexGeneration, hot.indexGeneration());
        assertEq(b.indexGeneration, 1);
        assertEq(b.registryMutations, registry.mutations());
        assertEq(b.admissionHighWater, admissions);
        assertEq(b.phase, 0);
        assertEq(reads.facetVersion(), 1);
        assertEq(views.facetVersion(), 1);
    }

    function testRecordHeadersEqualHotGettersAndRawSlots() public view {
        bytes32[4] memory ids = [r1, r2, r3, r4];
        uint64[4] memory first = [uint64(2), 4, 6, 14];
        uint64[4] memory occ = [uint64(1), 1, 1, 1]; // r1: 2 − withdraw(5); r4: 1 − withdraw(14) + 1
        bytes32[] memory list = new bytes32[](5);
        for (uint256 i; i < 4; ++i) {
            (Status st, RecordHeader memory h) = reads.recordHeader(k.proxy, ids[i]);
            _st(st, Status.PRESENT, "record present");
            (bytes32 typeId, uint64 fa, uint32 len, uint64 o, uint8 carrier) =
                hot.recordHeader(ids[i]);
            assertEq(h.typeId, typeId, "typeId vs hot");
            assertEq(h.firstAdmission, fa, "firstAdmission vs hot");
            assertEq(h.length, len, "length vs hot");
            assertEq(h.occurrences, o, "occurrences vs hot");
            assertEq(h.carrierKind, carrier, "carrier vs hot");
            assertEq(h.firstAdmission, first[i], "firstAdmission");
            assertEq(h.occurrences, occ[i], "occurrences");
            assertEq(h.typeId, vm.load(k.proxy, bytes32(Layout.recordsCellsSlot(ids[i]))));
            assertEq(h.word0, vm.load(k.proxy, bytes32(Layout.recordsBodyWordsSlot(ids[i], 0))));
            list[i] = ids[i];
        }
        list[4] = keccak256("absent");
        (Status st4,) = reads.recordHeader(k.proxy, list[4]);
        _st(st4, Status.ABSENT_PROVEN, "absent header");
        (Status[] memory sts, RecordHeader[] memory hs, BasisCommit memory b) =
            views.records(k.proxy, list);
        assertEq(sts.length, 5);
        for (uint256 i; i < 5; ++i) {
            (Status one, RecordHeader memory h) = reads.recordHeader(k.proxy, list[i]);
            _st(sts[i], one, "records() status equals recordHeader()");
            assertEq(keccak256(abi.encode(hs[i])), keccak256(abi.encode(h)), "records() header");
        }
        assertEq(b.admissionHighWater, 20);
    }

    function testRecordBodiesAreExactBytes() public view {
        (Status st, RecordHeader memory h, bytes memory body,) = reads.record(k.proxy, r1);
        _st(st, Status.PRESENT, "record");
        assertEq(body, body70, "70-byte body");
        assertEq(h.length, 70);
        assertEq(h.word0, keccak256("efs2/test/readers/w0"));
        (st,, body,) = reads.record(k.proxy, r2);
        assertEq(body, refBody, "ref body");
        (st,, body,) = reads.record(k.proxy, r3);
        assertEq(body, bytes("second"));
        (st, h, body,) = reads.record(k.proxy, keccak256("absent"));
        _st(st, Status.ABSENT_PROVEN, "absent record");
        assertEq(body.length, 0);
        assertEq(h.typeId, 0);

        // words: whole words, the stored tail word masked beyond the length
        bytes32[] memory words;
        (st, words) = reads.bodyWords(k.proxy, r1, 0, 3);
        _st(st, Status.PRESENT, "bodyWords");
        assertEq(words.length, 3);
        assertEq(words[0], keccak256("efs2/test/readers/w0"));
        assertEq(words[1], keccak256("efs2/test/readers/w1"));
        assertEq(words[2], bytes32(hex"a1b2c3d4e5f6"), "the tail word is masked");
        for (uint256 i; i < 3; ++i) {
            assertEq(words[i], vm.load(k.proxy, bytes32(Layout.recordsBodyWordsSlot(r1, i))));
        }
        (st, words) = reads.bodyWords(k.proxy, r1, 1, 10);
        assertEq(words.length, 2, "clipped to the record's words");
        assertEq(words[1], bytes32(hex"a1b2c3d4e5f6"));
        (st, words) = reads.bodyWords(k.proxy, r1, 3, 1);
        _st(st, Status.PRESENT, "past the last word");
        assertEq(words.length, 0);
        (st, words) = reads.bodyWords(k.proxy, r1, 0, 257);
        _st(st, Status.LIMIT_EXCEEDED, "count > maxReadCount");
        assertEq(words.length, 0);
        (st, words) = reads.bodyWords(k.proxy, r1, 0, 256);
        _st(st, Status.PRESENT, "count == maxReadCount");
        (st,) = reads.bodyWords(k.proxy, keccak256("absent"), 0, 1);
        _st(st, Status.ABSENT_PROVEN, "absent words");

        // slices
        bytes memory slice;
        (st, slice) = reads.bodySlice(k.proxy, r1, 30, 10);
        _st(st, Status.PRESENT, "slice");
        assertEq(slice, _sub(body70, 30, 40), "slice across a word boundary");
        (st, slice) = reads.bodySlice(k.proxy, r1, 60, 100);
        assertEq(slice, _sub(body70, 60, 70), "slice clipped at the length");
        (st, slice) = reads.bodySlice(k.proxy, r1, 64, 6);
        assertEq(slice, hex"a1b2c3d4e5f6", "the tail bytes");
        (st, slice) = reads.bodySlice(k.proxy, r1, 70, 5);
        _st(st, Status.PRESENT, "slice at the end");
        assertEq(slice.length, 0);
        (st, slice) = reads.bodySlice(k.proxy, r1, 0, 8_192);
        assertEq(slice, body70, "length == maxBody");
        (st, slice) = reads.bodySlice(k.proxy, r1, 0, 8_193);
        _st(st, Status.LIMIT_EXCEEDED, "length > maxBody");
        assertEq(slice.length, 0);
        (st,) = reads.bodySlice(k.proxy, keccak256("absent"), 0, 1);
        _st(st, Status.ABSENT_PROVEN, "absent slice");
    }

    function testReadBoundsFollowTheLiveLimits() public {
        _setRealmWordBits(13, 16, 32, 64); // limits.maxBody = 64
        _setRealmWordBits(14, 0, 16, 5); // limits.maxReadCount = 5
        (Status st, RecordHeader memory h, bytes memory body,) = reads.record(k.proxy, r1);
        _st(st, Status.LIMIT_EXCEEDED, "a record longer than maxBody");
        assertEq(h.length, 70, "the header is still served");
        assertEq(body.length, 0);
        bytes memory slice;
        (st, slice) = reads.bodySlice(k.proxy, r1, 0, 64);
        _st(st, Status.PRESENT, "pageable through bodySlice");
        assertEq(slice, _sub(body70, 0, 64));
        (st,) = reads.bodySlice(k.proxy, r1, 0, 65);
        _st(st, Status.LIMIT_EXCEEDED, "slice > maxBody");
        (st,) = reads.bodyWords(k.proxy, r1, 0, 6);
        _st(st, Status.LIMIT_EXCEEDED, "words > maxReadCount");
        (AdmissionRow[] memory rows, uint64 next,) = reads.admissions(k.proxy, 1, 10);
        assertEq(rows.length, 5, "admissions clipped to maxReadCount");
        assertEq(next, 6);
    }

    function testSubjectsAndPositions() public view {
        (Status st, uint64 created, bytes32 creator) = reads.subjectInfo(k.proxy, s1);
        _st(st, Status.PRESENT, "s1");
        assertEq(created, hot.subjectCreatedAt(s1));
        assertEq(created, 1);
        assertEq(creator, p1);
        (st, created, creator) = reads.subjectInfo(k.proxy, s2);
        assertEq(created, 13);
        assertEq(creator, p2);
        (st, created, creator) = reads.subjectInfo(k.proxy, keccak256("absent"));
        _st(st, Status.ABSENT_PROVEN, "absent subject");
        assertEq(created, 0);
        assertEq(creator, 0);

        bytes32[4] memory positions = [posName, posZero, posName, posName2];
        bytes32[4] memory subjects = [s1, s1, s1, s2];
        bytes32[4] memory roles = [ROLE_NAME, bytes32(0), ROLE_NAME, ROLE_NAME];
        for (uint256 i; i < 4; ++i) {
            (Status ps, bytes32 position) = reads.bindingPosition(k.proxy, uint64(i + 1));
            _st(ps, Status.PRESENT, "binding ordinal");
            assertEq(position, positions[i], "bindingPosition");
            assertEq(position, vm.load(k.proxy, bytes32(Layout.bindingsBindingPositionSlot(i + 1))));
            (Status cs, bytes32 purpose, bytes32 subject, bytes32 role) =
                reads.positionCell(k.proxy, position);
            _st(cs, Status.PRESENT, "position cell");
            assertEq(purpose, FOLDER);
            assertEq(subject, subjects[i]);
            assertEq(role, roles[i]);
            assertEq(Keys.position(purpose, subject, role), position, "the cell is the preimage");
        }
        (Status none,) = reads.bindingPosition(k.proxy, 5);
        _st(none, Status.ABSENT_PROVEN, "binding ordinal past the counter");
        (none,,,) = reads.positionCell(k.proxy, keccak256("absent"));
        _st(none, Status.ABSENT_PROVEN, "absent position");
    }

    function testHeadsEqualHotGettersWithCanonicalTargets() public view {
        bytes32[] memory keys = new bytes32[](5);
        keys[0] = Keys.binding(p1, posName); // BOUND r1 (restored)
        keys[1] = Keys.binding(p1, posZero); // RELEASED
        keys[2] = Keys.binding(p2, posName); // RELEASED from MASKED
        keys[3] = Keys.binding(p2, posName2); // BOUND r1
        keys[4] = Keys.binding(p3, posName); // UNSET
        Status[5] memory want = [
            Status.PRESENT, Status.RELEASED, Status.RELEASED, Status.PRESENT, Status.ABSENT_PROVEN
        ];
        (Head[] memory hs, BasisCommit memory b) = views.heads(k.proxy, keys);
        assertEq(b.admissionHighWater, 20);
        for (uint256 i; i < 5; ++i) {
            (Status st, Head memory h) = reads.head(k.proxy, keys[i]);
            _st(st, want[i], "head status");
            _assertHead(h, _hotHead(keys[i]), "head() vs hot.head");
            _assertHead(hs[i], h, "heads() vs head()");
            uint256 slot = Layout.bindingsHeadsSlot(keys[i]);
            (uint8 state,,,,,, uint40 notAfter) =
                Layout.unpackHeadRowWord0(vm.load(k.proxy, bytes32(slot)));
            assertEq(h.state, state, "raw state");
            assertEq(h.notAfter, notAfter, "raw notAfter");
            bytes32 rawTarget = vm.load(k.proxy, bytes32(slot + 1));
            assertEq(h.target, state == 1 ? rawTarget : bytes32(0), "canonical target");
        }
        // the target word is kept on RELEASE; the canonical target is 0
        assertEq(vm.load(k.proxy, bytes32(Layout.bindingsHeadsSlot(keys[2]) + 1)), r4);
        assertEq(hs[0].target, r1);
        assertEq(hs[0].revision, 4);
        assertEq(hs[1].targetKind, 2, "the released head keeps its target kind");
    }

    function testAdmissionRowsEqualRawSlotsAndTheHistory() public view {
        uint8[20] memory kinds = [5, 1, 3, 1, 2, 1, 3, 3, 6, 4, 3, 7, 5, 1, 3, 3, 4, 7, 6, 1];
        uint8[20] memory pubOf = [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 8];
        uint8[20] memory leafOf = [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 0, 1, 0, 1, 2, 3, 0, 1, 2, 0];
        uint8[20] memory prev = [0, 0, 0, 0, 0, 0, 3, 0, 0, 7, 10, 8, 0, 0, 0, 0, 15, 17, 0, 0];
        uint8[20] memory ord = [0, 0, 1, 0, 0, 0, 1, 2, 0, 1, 1, 2, 0, 0, 3, 4, 3, 3, 0, 0];
        uint8[20] memory expected = [0, 0, 0, 0, 0, 0, 1, 0, 0, 2, 3, 1, 0, 0, 0, 0, 1, 2, 0, 0];
        uint8[20] memory targetKind = [0, 0, 1, 0, 0, 0, 1, 2, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0];
        uint8[20] memory policy = [0, 2, 0, 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 2];
        uint8[20] memory roleRow = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0];
        bytes32[20] memory a = [
            SALT1,
            r1,
            r1,
            r2,
            r1,
            r3,
            r3,
            s1,
            bytes32(uint256(5)),
            bytes32(0),
            r1,
            bytes32(0),
            SALT2,
            r4,
            r4,
            r1,
            bytes32(0),
            bytes32(0),
            bytes32(uint256(14)),
            r4
        ];
        bool complete = _rowsComplete();
        (AdmissionRow[] memory page, uint64 next, BasisCommit memory b) =
            reads.admissions(k.proxy, 0, 300);
        assertEq(page.length, 20, "the page stops at the high water");
        assertEq(next, 21);
        assertEq(b.admissionHighWater, 20);
        for (uint256 i; i < 20; ++i) {
            uint64 o = uint64(i + 1);
            (Status st, AdmissionRow memory r) = reads.admission(k.proxy, o);
            _st(st, Status.PRESENT, "admission present");
            assertEq(keccak256(abi.encode(page[i])), keccak256(abi.encode(r)), "page row");
            assertEq(r.kind, kinds[i], "kind");
            assertEq(r.publication, pubOf[i], "publication");
            assertEq(r.leaf, leafOf[i], "leaf");
            assertEq(r.prevAdmission, prev[i], "prevAdmission");
            assertEq(r.targetKind, targetKind[i], "targetKind");
            assertEq(r.policyRow, policy[i], "policyRow");
            assertEq(r.roleRow, roleRow[i], "roleRow");
            assertEq(r.a, a[i], "a");
            assertEq(r.withdrawn, o == 5 || o == 14, "withdrawn");
            assertEq(r.bindingOrdinal, complete ? ord[i] : 0, "bindingOrdinal");
            assertEq(r.expectedRevision, complete ? expected[i] : 0, "expectedRevision");
            uint256 slot = Layout.admissionsRowsSlot(o);
            assertEq(r.a, vm.load(k.proxy, bytes32(slot + 1)), "raw a");
            (
                uint8 kind,
                uint48 bo,
                uint48 er,
                uint48 pa,
                uint8 wd,
                uint16 pr,
                uint16 rr,
                uint8 tk,
                uint48 pub
            ) = _rawRowMeta(o);
            assertEq(
                keccak256(abi.encode(kind, r.leaf, pub, bo, er, pa, wd != 0, pr, rr, tk, r.a)),
                keccak256(abi.encode(r)),
                "raw meta"
            );
        }
        (Status none,) = reads.admission(k.proxy, 21);
        _st(none, Status.ABSENT_PROVEN, "past the high water");
        (none,) = reads.admission(k.proxy, 0);
        _st(none, Status.ABSENT_PROVEN, "admission 0");
        (page, next,) = reads.admissions(k.proxy, 18, 10);
        assertEq(page.length, 3);
        assertEq(next, 21);
        (page, next,) = reads.admissions(k.proxy, 25, 10);
        assertEq(page.length, 0);
        assertEq(next, 25);
    }

    function testEvidenceAndPublicationAt() public view {
        bytes32 obligations = ExecutionSets.indexObligations(genesisComponents);
        assertEq(obligations, vm.load(k.proxy, bytes32(uint256(Layout.LEDGER_REALM_ROOT) + 10)));
        for (uint256 i; i < pubs.length; ++i) {
            Pub memory p = pubs[i];
            uint64 ordinal = uint64(i + 1);
            (Status st, uint64 publication, bytes32 digest) =
                reads.publicationAt(k.proxy, p.principalId, p.nonce);
            _st(st, Status.PRESENT, "publicationAt");
            (uint64 hp, bytes32 hd) = hot.publicationAt(p.principalId, p.nonce);
            assertEq(publication, hp, "publicationAt vs hot");
            assertEq(digest, hd, "intentDigest vs hot");
            assertEq(publication, ordinal);
            Evidence memory e;
            (st, e) = reads.evidence(k.proxy, ordinal);
            _st(st, Status.PRESENT, "evidence");
            assertEq(e.principalId, p.principalId, "principalId");
            assertEq(e.author, p.author, "author");
            assertEq(e.submitter, address(0), "native: author is the submitter");
            assertEq(e.proofKind, 1, "NATIVE");
            assertEq(e.principalKind, p.author == address(this) ? 2 : 1, "principalKind");
            assertEq(e.verifierProfile, 0);
            assertEq(e.leafCount, p.leafCount, "leafCount");
            assertEq(e.firstAdmission, p.firstAdmission, "firstAdmission");
            assertEq(e.nonce, p.nonce, "nonce");
            assertEq(e.deadline, 0);
            assertEq(e.basisBlock, p.blockNumber, "basisBlock");
            assertEq(e.revision, 1);
            assertEq(e.executionSet, genesisExecutionSet, "the revision's execution set");
            assertEq(e.intentDigest, digest, "intentDigest");
            Native memory ctx;
            ctx.nonce = p.nonce;
            assertEq(
                e.intentDigest,
                ILedgerCommitments(address(k.ingress))
                    .nativeIntentDigest(
                        hot.realmId(), p.principalId, ctx, p.actionsHash, keccak256("")
                    ),
                "the native digest is recomputable from the row"
            );
            assertEq(e.actionsHash, p.actionsHash, "actionsHash");
            assertEq(e.acceptanceProfile, 0, "native: not stored");
            assertEq(e.indexObligations, obligations, "native: the revision's obligations");
            assertEq(e.readSetHash, 0);
            assertEq(e.witness0, 0);
            assertEq(e.witness1, 0);
            assertEq(e.v, 0);
            assertFalse(e.imported || e.guarded || e.executionBound || e.acceptanceBound);
            _st(Status(uint8(e.retention)), Status(uint8(Retention.STATE)), "retention");
            assertEq(e.publicationId, p.publicationId, "publicationId equals the Published topic");
            assertEq(e.publicationId, Keys.publicationId(p.principalId, digest));
            uint256 slot = Layout.publicationsEvidenceSlot(ordinal);
            assertEq(e.principalId, vm.load(k.proxy, bytes32(slot + 2)), "raw w2");
            assertEq(e.intentDigest, vm.load(k.proxy, bytes32(slot + 3)), "raw w3");
            assertEq(e.actionsHash, vm.load(k.proxy, bytes32(slot + 4)), "raw w4");
        }
        (Status none, uint64 pub0,) = reads.publicationAt(k.proxy, p1, 99);
        _st(none, Status.ABSENT_PROVEN, "unused nonce");
        assertEq(pub0, 0);
        (none,) = reads.evidence(k.proxy, 9);
        _st(none, Status.ABSENT_PROVEN, "evidence past the counter");
        (none,) = reads.evidence(k.proxy, 0);
        _st(none, Status.ABSENT_PROVEN, "evidence 0");
    }

    function testPrincipalsOf() public {
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        vm.etch(bob, abi.encodePacked(hex"ef0100", address(acceptAll))); // an EIP-7702 designator
        address[] memory accounts = new address[](4);
        accounts[0] = address(this);
        accounts[1] = alice;
        accounts[2] = bob;
        accounts[3] = carol;
        bytes32[] memory out = reads.principalsOf(k.proxy, accounts);
        assertEq(out.length, 4);
        assertEq(out[0], p1, "a contract principal of this Realm");
        assertEq(out[0], Keys.contractPrincipal(hot.realmOrigin(), address(this)));
        assertEq(out[1], p2, "a key principal");
        assertEq(out[2], Keys.principal(bob), "a 7702 designator is a key principal");
        assertEq(out[3], Keys.principal(carol));
        address[] memory many = new address[](65);
        vm.expectRevert(abi.encodeWithSelector(E_RESERVED.selector, uint8(31), uint256(65)));
        reads.principalsOf(k.proxy, many);
    }

    // =============================================================================================
    // describe(), revisionAt()
    // =============================================================================================

    function testDescribeEqualsHotGettersTheRevisionRowAndTheCounters() public view {
        Description memory d = reads.describe(k.proxy);
        (uint64 genesisChain, uint64 accepted, uint32 rev, bool frozen) = hot.control();
        assertEq(d.realmId, hot.realmId());
        assertEq(d.realmOrigin, hot.realmOrigin());
        assertEq(d.realmOrigin, Keys.realmOrigin(uint64(block.chainid), k.proxy, SALT));
        assertEq(d.realmSalt, SALT);
        assertEq(d.genesisChainId, genesisChain);
        assertEq(d.acceptedChainId, accepted);
        assertEq(d.chainNamespace, bytes8("eip155"));
        assertEq(d.chainReference, bytes32(uint256(block.chainid)));
        assertEq(d.executionSet, hot.executionSet());
        assertEq(d.revision, rev);
        assertEq(d.revision, hot.revision());
        assertEq(d.revisionBlock, genesisBlock);
        assertEq(d.revisionAdmissionHigh, 0);
        assertEq(d.layoutId, hot.layoutId());
        assertEq(d.layoutId, Layout.LAYOUT_ID);
        assertEq(d.hotAbiId, hot.hotAbiId());
        assertEq(d.executionProfileId, 1);
        assertEq(d.capabilities, 0);
        assertEq(d.ledgerImpl, address(k.implementation), "the live implementation slot");
        assertEq(d.ledgerImpl, genesisComponents.ledgerImpl);
        assertEq(d.ledgerImplCodehash, address(k.implementation).codehash);
        assertEq(d.ingress, hot.ingress());
        assertEq(d.ingressCodehash, address(k.ingress).codehash);
        assertEq(d.applyDelegate, hot.applyDelegate());
        assertEq(d.applyCodehash, address(k.applyDelegate).codehash);
        assertEq(d.registry, hot.registry());
        assertEq(d.registryImpl, genesisComponents.registryImpl);
        assertEq(d.registryImplCodehash, genesisComponents.registryImplCodehash);
        assertEq(d.registryMutations, registry.mutations());
        assertEq(d.catalogCount, 2);
        assertEq(d.index, hot.index());
        assertEq(d.indexCodehash, address(index).codehash);
        assertEq(d.indexGeneration, hot.indexGeneration());
        assertEq(d.indexManifestHash, index.manifestHash());
        assertEq(d.indexObligations, ExecutionSets.indexObligations(genesisComponents));
        assertEq(d.controller, hot.controller());
        assertEq(d.controllerCodehash, address(this).codehash);
        assertEq(d.controllerOwner, address(this));
        assertEq(d.steward, address(0));
        assertEq(d.frozen, frozen);
        assertEq(d.phase, 0);
        assertEq(d.readerDirectory, hot.readerDirectory());
        assertEq(d.thisFacet, address(reads));
        assertEq(d.thisFacetCodehash, address(reads).codehash);
        assertEq(d.facetVersion, 1);
        (uint64 admissions, uint64 records, uint64 bindings, uint64 publications) = hot.counts();
        assertEq(d.admissions, admissions);
        assertEq(d.records, records);
        assertEq(d.bindings, bindings);
        assertEq(d.publications, publications);
        assertEq(d.domainSeparator, ExecutionSets.domainSeparator(accepted, k.proxy));
        assertEq(d.limitsProfileId, keccak256(abi.encode(KernelDeploy.s1Limits())));
        assertEq(d.statusVocabularyId, STATUS_VOCABULARY_ID);
        assertEq(d.verifierProfilesRoot, 0);
        assertEq(d.dependencyRoot, 0);
        assertEq(keccak256(abi.encode(d.limits)), keccak256(abi.encode(KernelDeploy.s1Limits())));
        assertEq(d.noticePrincipal, hot.noticePrincipal());
        // and the revision row it summarises
        (, Revision memory r) = reads.revisionAt(k.proxy, d.revision);
        assertEq(d.revisionBlock, r.activationBlock);
        assertEq(d.ingress, r.components.ingress);
        assertEq(d.controllerOwner, r.components.controllerOwner);
        assertEq(d.indexManifestHash, r.components.indexManifestHash);
    }

    function testRevisionAtGenesisEqualsTheActivatedSet() public view {
        (Status st, Revision memory r) = reads.revisionAt(k.proxy, 1);
        _st(st, Status.PRESENT, "revision 1");
        assertEq(r.ordinal, 1);
        assertEq(r.activationBlock, genesisBlock);
        assertEq(r.admissionHigh, 0);
        assertEq(r.publicationHigh, 0);
        assertEq(r.activationTimestamp, genesisTimestamp);
        assertEq(r.flags, 0);
        assertEq(r.executionSet, genesisExecutionSet);
        assertEq(
            keccak256(abi.encode(r.components)),
            keccak256(abi.encode(genesisComponents)),
            "components"
        );
        assertEq(r.components.applyDelegate, address(k.applyDelegate));
        assertEq(r.layoutId, Layout.LAYOUT_ID);
        assertEq(r.executionProfileId, 1);
        assertEq(r.capabilities, 0);
        assertEq(r.acceptedChainId, block.chainid);
        assertEq(r.indexGeneration, 1);
        assertEq(r.migrationHash, 0);
        assertEq(r.dependencyRoot, 0);
        assertEq(r.limitsProfileId, keccak256(abi.encode(KernelDeploy.s1Limits())));
        assertEq(keccak256(abi.encode(r.limits)), keccak256(abi.encode(KernelDeploy.s1Limits())));
        assertEq(r.noticePrincipal, 0);
        assertEq(
            r.executionSet, vm.load(k.proxy, bytes32(Layout.revisionsRowsSlot(1) + 1)), "raw w1"
        );
        Revision memory none;
        (st, none) = reads.revisionAt(k.proxy, 0);
        _st(st, Status.ABSENT_PROVEN, "revision 0");
        (st, none) = reads.revisionAt(k.proxy, 2);
        _st(st, Status.ABSENT_PROVEN, "a revision not yet activated");
        assertEq(none.ordinal, 0);
    }

    // =============================================================================================
    // publication(): Effect/3 reconstruction
    // =============================================================================================

    function testPublicationRecomputesEveryEffectsHash() public {
        bool complete = _rowsComplete();
        for (uint256 i; i < pubs.length; ++i) {
            Pub memory p = pubs[i];
            uint256 g = gasleft();
            (Status st, PublicationView memory v) =
                views.publication(k.proxy, p.principalId, p.nonce);
            g -= gasleft();
            console2.log("publication() gas", i + 1, p.leafCount, g);
            assertEq(v.ordinal, i + 1, "ordinal");
            assertEq(v.admissions.length, p.leafCount, "rows");
            assertEq(v.admissionBlock, p.blockNumber, "admissionBlock");
            assertEq(v.evidence.publicationId, p.publicationId, "publicationId");
            assertEq(v.observed.admissionHighWater, 20, "basis echoed");
            if (complete || !p.hasBind) {
                _st(st, Status.PRESENT, "reconstructed");
                assertEq(v.effectsHash, p.effectsHash, "effectsHash equals Published");
            } else {
                // the stock kernel leaves bindingOrdinal unwritten in bind rows (design §4.3 says it is
                // written), so the coordinate is not in state and the facet says it cannot know
                _st(st, Status.UNKNOWN, "a bind row without its coordinate");
                assertEq(v.effectsHash, 0);
            }
            for (uint256 j; j < v.admissions.length; ++j) {
                (, AdmissionRow memory r) = reads.admission(k.proxy, p.firstAdmission + uint64(j));
                assertEq(keccak256(abi.encode(v.admissions[j])), keccak256(abi.encode(r)));
            }
        }
        (Status none, PublicationView memory empty) = views.publication(k.proxy, p3, 0);
        _st(none, Status.ABSENT_PROVEN, "no publication");
        assertEq(empty.ordinal, 0);
    }

    // =============================================================================================
    // headsAt(), headSnapshots(), historyAt()
    // =============================================================================================

    function testHeadsAtFirstTouchAcrossTheHistory() public view {
        // order [p2, p1] at (s1, name) after each publication
        Status[8] memory st = [
            Status.PRESENT,
            Status.PRESENT,
            Status.PRESENT,
            Status.MASKED,
            Status.PRESENT,
            Status.PRESENT,
            Status.PRESENT,
            Status.PRESENT
        ];
        uint8[8] memory idx = [1, 1, 1, 1, 1, 0, 1, 1];
        bytes32[8] memory target = [r1, r1, r3, bytes32(0), r1, r4, r1, r1];
        assertEq(headsAtCaptures.length, 8);
        for (uint256 i; i < 8; ++i) {
            HeadsAtCapture memory c = headsAtCaptures[i];
            _st(c.status, st[i], "headsAt status");
            assertEq(c.selectedIndex, idx[i], "selectedIndex");
            assertEq(c.target, target[i], "selected target");
        }
    }

    function testHeadsAtLaw() public {
        bytes32[] memory order = new bytes32[](3);
        order[0] = p3; // UNSET
        order[1] = p2; // RELEASED
        order[2] = p1; // BOUND r1
        (Status st, Head memory sel, uint8 idx, Head[] memory all, BasisCommit memory b) =
            views.headsAt(k.proxy, order, posName);
        _st(st, Status.PRESENT, "unset and released fall through");
        assertEq(idx, 2);
        assertEq(sel.target, r1);
        assertEq(all.length, 3);
        assertEq(all[0].state, 0);
        assertEq(all[1].state, 3);
        assertEq(b.admissionHighWater, 20);
        for (uint256 i; i < 3; ++i) {
            _assertHead(all[i], _hotHead(Keys.binding(order[i], posName)), "all[] vs hot");
        }
        // released only: nothing wins
        bytes32[] memory one = new bytes32[](1);
        one[0] = p1;
        (st, sel, idx, all,) = views.headsAt(k.proxy, one, posZero);
        _st(st, Status.ABSENT_PROVEN, "a released head falls through");
        assertEq(idx, 255);
        assertEq(all[0].state, 3);
        (st,, idx, all,) = views.headsAt(k.proxy, new bytes32[](0), posName);
        _st(st, Status.ABSENT_PROVEN, "no principals");
        assertEq(idx, 255);
        assertEq(all.length, 0);

        // a mask beats a later bound head; a bound head beats a later mask
        Action[] memory a = new Action[](1);
        bytes[] memory none = new bytes[](1);
        a[0] = _unbind(s1, ROLE_NAME, 4);
        _exec(address(this), 5, a, none);
        a[0] = _bind(s1, ROLE_NAME, r1, 3);
        _exec(alice, 3, a, none); // RESTORE from RELEASED
        bytes32[] memory two = new bytes32[](2);
        two[0] = p1;
        two[1] = p2;
        (st, sel, idx,,) = views.headsAt(k.proxy, two, posName);
        _st(st, Status.MASKED, "mask beats fall-through");
        assertEq(idx, 0);
        assertEq(sel.target, 0, "a masked head's canonical target");
        assertEq(sel.state, 2);
        two[0] = p2;
        two[1] = p1;
        (st, sel, idx,,) = views.headsAt(k.proxy, two, posName);
        _st(st, Status.PRESENT, "first touch");
        assertEq(idx, 0);
        assertEq(sel.target, r1);

        bytes32[] memory many = new bytes32[](65);
        (st,, idx,,) = views.headsAt(k.proxy, many, posName);
        _st(st, Status.LIMIT_EXCEEDED, "more than maxReadIds principals");
        vm.expectRevert(abi.encodeWithSelector(E_RESERVED.selector, uint8(31), uint256(65)));
        views.heads(k.proxy, many);
    }

    function testHeadSnapshotsArePositionMajor() public view {
        bytes32[] memory principals = new bytes32[](3);
        principals[0] = p1;
        principals[1] = p2;
        principals[2] = p3;
        bytes32[] memory positions = new bytes32[](3);
        positions[0] = posName;
        positions[1] = posZero;
        positions[2] = posName2;
        bytes32[] memory out = views.headSnapshots(k.proxy, principals, positions);
        assertEq(out.length, 9);
        ILedgerCommitments c = ILedgerCommitments(address(k.ingress));
        for (uint256 j; j < 3; ++j) {
            for (uint256 i; i < 3; ++i) {
                Head memory h = _hotHead(Keys.binding(principals[i], positions[j]));
                assertEq(
                    out[j * 3 + i],
                    c.headSnapshotHash(h.state, h.revision, h.admission, h.target),
                    "the ingress's head snapshot"
                );
            }
        }
    }

    function testHeadSnapshotsRefuseShapesTheIngressRefuses() public {
        bytes32[] memory one = new bytes32[](1);
        vm.expectRevert(abi.encodeWithSelector(E_READSET_SHAPE.selector, uint8(1)));
        views.headSnapshots(k.proxy, new bytes32[](65), one);
        vm.expectRevert(abi.encodeWithSelector(E_READSET_SHAPE.selector, uint8(2)));
        views.headSnapshots(k.proxy, one, new bytes32[](5));
        assertEq(views.headSnapshots(k.proxy, new bytes32[](64), new bytes32[](4)).length, 256);
    }

    function testHistoryAtReproducesEveryCapturedHead() public view {
        assertEq(headCaptures.length, 32);
        for (uint256 i; i < headCaptures.length; ++i) {
            HeadCapture memory c = headCaptures[i];
            (History hs, Head memory h) = views.historyAt(k.proxy, c.key, c.lastAdmission, 64);
            if (c.head.state == 0) {
                assertEq(uint8(hs), uint8(History.NONE), "before the first bind");
            } else {
                assertEq(uint8(hs), uint8(History.FOUND), "found");
                _assertHead(h, c.head, "historyAt(lastAdmission) == the head then");
            }
        }
    }

    function testHistoryAtWalksTheChain() public view {
        bytes32 key = Keys.binding(p1, posName); // 3 BIND r1 → 7 REBIND r3 → 10 MASK → 11 RESTORE r1
        (History hs, Head memory h) = views.historyAt(k.proxy, key, 20, 0);
        assertEq(uint8(hs), uint8(History.FOUND), "the live head needs no hop");
        _assertHead(h, _hotHead(key), "live");
        (hs, h) = views.historyAt(k.proxy, key, 10, 8);
        assertEq(uint8(hs), uint8(History.FOUND));
        assertEq(h.state, 2, "masked as of 10");
        assertEq(h.revision, 3);
        assertEq(h.admission, 10);
        assertEq(h.prevAdmission, 7);
        assertEq(h.targetKind, 1, "kept from the last BIND");
        assertEq(h.target, 0, "canonical");
        assertEq(h.bindingOrdinal, 1);
        for (uint64 asOf = 7; asOf <= 9; ++asOf) {
            (hs, h) = views.historyAt(k.proxy, key, asOf, 8);
            assertEq(uint8(hs), uint8(History.FOUND));
            assertEq(h.state, 1);
            assertEq(h.revision, 2);
            assertEq(h.admission, 7);
            assertEq(h.prevAdmission, 3);
            assertEq(h.target, r3, "rebound to r3 as of 7..9");
        }
        for (uint64 asOf = 3; asOf <= 6; ++asOf) {
            (hs, h) = views.historyAt(k.proxy, key, asOf, 8);
            assertEq(h.revision, 1);
            assertEq(h.admission, 3);
            assertEq(h.prevAdmission, 0);
            assertEq(h.target, r1);
        }
        (hs, h) = views.historyAt(k.proxy, key, 2, 8);
        assertEq(uint8(hs), uint8(History.NONE), "before the first bind");
        assertEq(h.state, 0);
        (hs,) = views.historyAt(k.proxy, key, 0, 8);
        assertEq(uint8(hs), uint8(History.NONE));
        // hops: 11 → 10 → 7 → 3
        (hs, h) = views.historyAt(k.proxy, key, 3, 2);
        assertEq(uint8(hs), uint8(History.UNKNOWN), "beyond maxHops");
        assertEq(h.state, 0);
        (hs,) = views.historyAt(k.proxy, key, 3, 3);
        assertEq(uint8(hs), uint8(History.FOUND), "exactly maxHops");
        // the masked state needs one more hop to its last BIND for the kept target kind
        (hs,) = views.historyAt(k.proxy, key, 10, 1);
        assertEq(uint8(hs), uint8(History.UNKNOWN));
        (hs,) = views.historyAt(k.proxy, key, 10, 2);
        assertEq(uint8(hs), uint8(History.FOUND));
        // a released-from-masked head: 15 BIND r4 → 17 MASK → 18 RELEASE
        key = Keys.binding(p2, posName);
        (hs, h) = views.historyAt(k.proxy, key, 17, 8);
        assertEq(h.state, 2);
        assertEq(h.targetKind, 1);
        (hs, h) = views.historyAt(k.proxy, key, 16, 8);
        assertEq(h.state, 1);
        assertEq(h.target, r4);
        (hs,) = views.historyAt(k.proxy, key, 14, 8);
        assertEq(uint8(hs), uint8(History.NONE));
        (hs,) = views.historyAt(k.proxy, Keys.binding(p3, posName), 20, 8);
        assertEq(uint8(hs), uint8(History.NONE), "an unset binding has no history");
    }

    // =============================================================================================
    // acceptanceBasis()
    // =============================================================================================

    function testAcceptanceBasisMatchesTheRegistry() public view {
        (Status st, AcceptanceBasis memory ab) = views.acceptanceBasis(k.proxy, 2);
        _st(st, Status.PRESENT, "publish");
        assertEq(ab.typeId, TYPE_OK);
        assertEq(ab.policyRow, 2);
        assertEq(ab.mandatory, address(acceptAll));
        assertEq(ab.ruleId, address(acceptAll).codehash);
        assertEq(ab.policy, address(policyRule));
        assertEq(ab.policyCodehash, address(policyRule).codehash);
        assertEq(ab.activatedAt, POLICY2_AT);
        assertEq(ab.roleRow, 0);
        assertEq(ab.revision, 1);
        assertEq(ab.validationGas, VALIDATION_GAS);
        (st, ab) = views.acceptanceBasis(k.proxy, 4);
        _st(st, Status.PRESENT, "publish of the ref Type");
        assertEq(ab.typeId, TYPE_REF);
        assertEq(ab.policyRow, 1);
        assertEq(ab.policy, address(0), "row 1: no policy");
        assertEq(ab.activatedAt, REF_POLICY_AT);
        assertEq(ab.validationGas, 0, "declared 0: the default floor applied");
        (st, ab) = views.acceptanceBasis(k.proxy, 5);
        _st(st, Status.PRESENT, "reuse");
        assertEq(ab.typeId, TYPE_OK);
        assertEq(ab.policyRow, 2);
        (st, ab) = views.acceptanceBasis(k.proxy, 3);
        if (_rowsComplete()) {
            _st(st, Status.PRESENT, "bind under a role row");
            assertEq(ab.typeId, TYPE_OK, "the role row's expected Type");
            assertEq(ab.roleRow, 1);
            assertEq(ab.activatedAt, ROLE_AT);
        } else {
            _st(st, Status.UNKNOWN, "a role-checked bind row without its coordinate");
            assertEq(ab.roleRow, 1);
        }
        (st, ab) = views.acceptanceBasis(k.proxy, 8);
        _st(st, Status.PRESENT, "bind without a role row");
        assertEq(ab.roleRow, 0);
        assertEq(ab.typeId, 0);
        (st, ab) = views.acceptanceBasis(k.proxy, 1);
        _st(st, Status.NOT_APPLICABLE, "create");
        assertEq(ab.revision, 1);
        (st,) = views.acceptanceBasis(k.proxy, 9);
        _st(st, Status.NOT_APPLICABLE, "withdraw");
        (st,) = views.acceptanceBasis(k.proxy, 10);
        _st(st, Status.NOT_APPLICABLE, "unbind");
        (st,) = views.acceptanceBasis(k.proxy, 0);
        _st(st, Status.ABSENT_PROVEN, "admission 0");
        (st,) = views.acceptanceBasis(k.proxy, 21);
        _st(st, Status.ABSENT_PROVEN, "past the high water");
    }

    // =============================================================================================
    // The facet-layout rule, reserved values and components that cannot answer
    // =============================================================================================

    function testForeignLayoutIsUnsupported() public {
        bytes32 other = keccak256("efs2/ledger-layout/other");
        vm.store(k.proxy, bytes32(Layout.LEDGER_REALM_LAYOUTID_SLOT), other);
        assertEq(hot.layoutId(), other);
        address l = k.proxy;
        (Status st,) = reads.revisionAt(l, 1);
        _st(st, Status.UNSUPPORTED, "revisionAt");
        (st,,,) = reads.record(l, r1);
        _st(st, Status.UNSUPPORTED, "record");
        (st,) = reads.recordHeader(l, r1);
        _st(st, Status.UNSUPPORTED, "recordHeader");
        (st,) = reads.bodyWords(l, r1, 0, 1);
        _st(st, Status.UNSUPPORTED, "bodyWords");
        (st,) = reads.bodySlice(l, r1, 0, 1);
        _st(st, Status.UNSUPPORTED, "bodySlice");
        (st,,) = reads.subjectInfo(l, s1);
        _st(st, Status.UNSUPPORTED, "subjectInfo");
        (st,) = reads.head(l, Keys.binding(p1, posName));
        _st(st, Status.UNSUPPORTED, "head");
        (st,,,) = reads.positionCell(l, posName);
        _st(st, Status.UNSUPPORTED, "positionCell");
        (st,) = reads.bindingPosition(l, 1);
        _st(st, Status.UNSUPPORTED, "bindingPosition");
        (st,) = reads.admission(l, 1);
        _st(st, Status.UNSUPPORTED, "admission");
        (st,) = reads.evidence(l, 1);
        _st(st, Status.UNSUPPORTED, "evidence");
        (st,) = views.publication(l, p1, 0);
        _st(st, Status.UNSUPPORTED, "publication");
        (st,) = views.acceptanceBasis(l, 2);
        _st(st, Status.UNSUPPORTED, "acceptanceBasis");
        bytes32[] memory ids = new bytes32[](2);
        Status[] memory sts;
        (sts,,) = views.records(l, ids);
        _st(sts[0], Status.UNSUPPORTED, "records");
        _st(sts[1], Status.UNSUPPORTED, "records");
        bytes32[] memory order = new bytes32[](1);
        order[0] = p1;
        (st,,,,) = views.headsAt(l, order, posName);
        _st(st, Status.UNSUPPORTED, "headsAt");
        (History hs,) = views.historyAt(l, Keys.binding(p1, posName), 20, 8);
        assertEq(uint8(hs), uint8(History.UNKNOWN), "historyAt");
        // the Etched getters are layout-independent
        (st,,) = reads.publicationAt(l, p1, 0);
        _st(st, Status.PRESENT, "publicationAt is served under every layout");
        assertEq(reads.basis(l).executionSet, hot.executionSet(), "basis is served too");
        // views without a status refuse
        bytes memory refusal = abi.encodeWithSelector(E_LAYOUT.selector, Layout.LAYOUT_ID, other);
        vm.expectRevert(refusal);
        reads.describe(l);
        vm.expectRevert(refusal);
        reads.admissions(l, 1, 1);
        vm.expectRevert(refusal);
        reads.principalsOf(l, new address[](0));
        vm.expectRevert(refusal);
        views.heads(l, ids);
        vm.expectRevert(refusal);
        views.headSnapshots(l, order, ids);
    }

    function testReservedRowValuesAreUnsupported() public {
        // head state 4
        bytes32 key = Keys.binding(p1, posName);
        bytes32 slot = bytes32(Layout.bindingsHeadsSlot(key));
        vm.store(k.proxy, slot, bytes32((uint256(vm.load(k.proxy, slot)) & ~uint256(0xff)) | 4));
        (Status st, Head memory h) = reads.head(k.proxy, key);
        _st(st, Status.UNSUPPORTED, "head state 4");
        assertEq(h.state, 4);
        bytes32[] memory order = new bytes32[](2);
        order[0] = p3;
        order[1] = p1;
        uint8 idx;
        (st,, idx,,) = views.headsAt(k.proxy, order, posName);
        _st(st, Status.UNSUPPORTED, "headsAt cannot rank a reserved state");
        assertEq(idx, 1);
        (History hs,) = views.historyAt(k.proxy, key, 20, 8);
        assertEq(uint8(hs), uint8(History.UNKNOWN));
        // admission kind 8
        slot = bytes32(Layout.admissionsRowsSlot(20));
        vm.store(k.proxy, slot, bytes32((uint256(vm.load(k.proxy, slot)) & ~uint256(0xff)) | 8));
        (st,) = reads.admission(k.proxy, 20);
        _st(st, Status.UNSUPPORTED, "kind 8");
        (st,) = views.publication(k.proxy, p2, 2);
        _st(st, Status.UNSUPPORTED, "a publication with a reserved kind");
        // carrier kind 1
        slot = bytes32(Layout.recordsCellsSlot(r1) + 1);
        vm.store(k.proxy, slot, bytes32(uint256(vm.load(k.proxy, slot)) | (uint256(1) << 128)));
        RecordHeader memory rh;
        (st, rh) = reads.recordHeader(k.proxy, r1);
        _st(st, Status.PRESENT, "the header is exact");
        assertEq(rh.carrierKind, 1);
        bytes memory body;
        (st, rh, body,) = reads.record(k.proxy, r1);
        _st(st, Status.UNSUPPORTED, "a CODE_BLOB body cannot be read");
        assertEq(rh.length, 70);
        assertEq(body.length, 0);
        (st,) = reads.bodyWords(k.proxy, r1, 0, 1);
        _st(st, Status.UNSUPPORTED, "bodyWords");
        (st,) = reads.bodySlice(k.proxy, r1, 0, 1);
        _st(st, Status.UNSUPPORTED, "bodySlice");
    }

    function testFacetsSurviveARevertingRegistryAndIndex() public {
        bytes memory code = address(new RevertingEverything()).code;
        vm.etch(address(registry), code);
        vm.etch(address(index), code);
        Description memory d = reads.describe(k.proxy);
        assertEq(d.registryMutations, 0);
        assertEq(d.catalogCount, 0);
        assertEq(d.indexManifestHash, 0);
        assertEq(d.realmId, hot.realmId(), "the rows are still served");
        assertEq(d.registry, address(registry));
        assertEq(d.index, address(index));
        assertEq(reads.basis(k.proxy).registryMutations, 0);
        (Status st, PublicationView memory v) = views.publication(k.proxy, p1, 1);
        _st(st, Status.UNKNOWN, "refCount needs the registry");
        assertEq(v.evidence.leafCount, 3, "the evidence is still served");
        assertEq(v.admissions.length, 3);
        (st,) = views.acceptanceBasis(k.proxy, 2);
        _st(st, Status.UNKNOWN, "the registry row is unknown");
        // and code-less components
        vm.etch(address(registry), "");
        vm.etch(address(index), "");
        d = reads.describe(k.proxy);
        assertEq(d.registryMutations, 0);
        assertEq(d.catalogCount, 0);
        assertEq(d.indexManifestHash, 0);
        (st,) = views.publication(k.proxy, p1, 1);
        _st(st, Status.UNKNOWN, "code-less registry");
    }
}

/// @notice The suite against the kernel exactly as `test/integration/Kernel.t.sol` deploys it.
contract FacetsTest is FacetSuite {
    function _deployKernel(address registry_)
        internal
        override
        returns (KernelDeploy.Kernel memory)
    {
        return KernelDeploy.deploy(address(this), registry_, SALT);
    }
}

/// @notice The suite against a kernel whose apply delegate also records the bind-row `bindingOrdinal` and
///         `expectedRevision` of design §4.3 (`RowCompleteApply`): every publication's `effectsHash` is
///         reconstructed from state.
contract FacetsRowCompleteTest is FacetSuite {
    function _deployKernel(address registry_)
        internal
        override
        returns (KernelDeploy.Kernel memory kk)
    {
        kk.ingress = new LedgerIngress(address(0));
        RowCompleteApply shim = new RowCompleteApply();
        kk.applyDelegate = LedgerApply(address(shim));
        kk.control = new LedgerControl(address(kk.ingress), address(shim), bytes32(0));
        kk.implementation = new LedgerCore(
            address(kk.ingress), address(shim), address(kk.control), KernelDeploy.HOT_ABI_ID
        );
        RealmInit memory init = RealmInit({
            realmSalt: SALT,
            controller: address(this),
            registry: registry_,
            readerDirectory: address(0),
            executionProfileId: 1,
            limits: KernelDeploy.s1Limits()
        });
        kk.proxy = address(
            new TransparentUpgradeableProxy(
                address(kk.implementation),
                address(this),
                abi.encodeCall(ILedgerControl.initialize, (init))
            )
        );
    }

    function testRowsAreComplete() public view {
        assertTrue(_rowsComplete());
    }
}
