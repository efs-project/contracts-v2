// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../KernelDeploy.sol";
import {IndexDeploy} from "../IndexDeploy.sol";
import {MockRegistry} from "./MockRegistry.sol";
import {AcceptAll} from "./Acceptors.sol";
import {LedgerReads} from "../../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../../src/readers/LedgerViews.sol";
import {LensReader} from "../../../src/readers/LensReader.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, ActionKind, Coordinate, Native, Purpose} from "../../../src/interfaces/Actions.sol";
import {BasisCommit, Qualified, Status} from "../../../src/interfaces/Results.sol";
import {Cursor, Selection} from "../../../src/interfaces/Readers.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";

/// @notice The `LensReview` vertical (design §16.3): the kernel against the mock registry and the real
///         generation-1 index (so scope lists and `lastMutation` are the real `BitmapStore`'s), both read
///         facets and a `LensReader` over them, and a base history in which two principals — this contract
///         (a contract principal, `pA`) and the EOA `alice` on the native lane (a key principal, `pB`) — bind
///         the same FOLDER position `x` of subject `S`, plus positions only one of them binds:
///
///         | pub | author | leaves                                                                              |
///         |-----|--------|-------------------------------------------------------------------------------------|
///         |  1  | pA     | CREATE S, PUBLISH root (word0 = S), a2, tiny; BIND x→root, y→a2, sub→S, tiny→tiny,  |
///         |     |        | HEAD(S,0)→root                                                                      |
///         |  2  | pB     | PUBLISH b; BIND x→b, z→b, HEAD(S,0)→b                                               |
///
///         Tests drive the later transitions (mask, release, rebind, restore) through the helpers, which track
///         each binding's CAS revision.
abstract contract LensFixture is Test {
    bytes32 internal constant TYPE_OK = keccak256("efs2/test/lens/type/ok");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant X = keccak256("efs2/test/lens/role/x");
    bytes32 internal constant Y = keccak256("efs2/test/lens/role/y");
    bytes32 internal constant Z = keccak256("efs2/test/lens/role/z");
    bytes32 internal constant SUB = keccak256("efs2/test/lens/role/sub");
    bytes32 internal constant TINY = keccak256("efs2/test/lens/role/tiny");
    bytes32 internal constant SALT_S = keccak256("efs2/test/lens/subject/S");

    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;
    LedgerReads internal reads;
    LedgerViews internal views;
    LensReader internal lens;

    address internal alice;
    bytes32 internal pA;
    bytes32 internal pB;
    bytes32 internal pNobody;
    bytes32 internal S;
    bytes internal rootBody;
    bytes internal a2Body = "a2: a second body of thirty-two-plus bytes";
    bytes internal tinyBody = "tiny";
    bytes internal bBody = "b: alice's body, also more than thirty-two bytes";
    bytes32 internal rRoot;
    bytes32 internal rA2;
    bytes32 internal rTiny;
    bytes32 internal rB;

    mapping(address => uint64) internal nonces;
    mapping(bytes32 => uint64) internal revisions; // binding key -> current revision

    function setUp() public virtual {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("efs2/test/lens/salt"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID);
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k, address(this), address(registry), address(g.index), g.index.manifestHash()
                )
            );
        vm.roll(vm.getBlockNumber() + 1);
        AcceptAll acceptAll = new AcceptAll();
        TypeInfo memory info;
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = address(acceptAll);
        info.ruleId = address(acceptAll).codehash;
        info.policyRows = 1;
        info.policyRow = 1;
        registry.setType(TYPE_OK, info, new bytes32[](0));
        reads = new LedgerReads();
        views = new LedgerViews();
        lens = new LensReader(k.proxy, address(views), address(reads));

        alice = makeAddr("alice");
        pA = Keys.principalFor(address(this), hot.realmOrigin());
        pB = Keys.principal(alice);
        pNobody = Keys.principal(makeAddr("nobody"));
        S = Keys.subject(pA, SALT_S);
        rootBody = abi.encodePacked(S, "root document");
        rRoot = Keys.record(TYPE_OK, rootBody);
        rA2 = Keys.record(TYPE_OK, a2Body);
        rTiny = Keys.record(TYPE_OK, tinyBody);
        rB = Keys.record(TYPE_OK, bBody);
        _base();
    }

    function _base() internal {
        Action[] memory a = new Action[](9);
        bytes[] memory b = new bytes[](9);
        a[0].kind = ActionKind.CREATE;
        a[0].salt = SALT_S;
        (a[1], b[1]) = (_publish(rootBody), rootBody);
        (a[2], b[2]) = (_publish(a2Body), a2Body);
        (a[3], b[3]) = (_publish(tinyBody), tinyBody);
        a[4] = _bindAction(address(this), FOLDER, X, rRoot);
        a[5] = _bindAction(address(this), FOLDER, Y, rA2);
        a[6] = _bindAction(address(this), FOLDER, SUB, S);
        a[7] = _bindAction(address(this), FOLDER, TINY, rTiny);
        a[8] = _bindAction(address(this), Purpose.HEAD, 0, rRoot);
        _exec(address(this), a, b);

        a = new Action[](4);
        b = new bytes[](4);
        (a[0], b[0]) = (_publish(bBody), bBody);
        a[1] = _bindAction(alice, FOLDER, X, rB);
        a[2] = _bindAction(alice, FOLDER, Z, rB);
        a[3] = _bindAction(alice, Purpose.HEAD, 0, rB);
        _exec(alice, a, b);
    }

    // ---- transitions ------------------------------------------------------------------------------------------

    function _exec(address author, Action[] memory actions, bytes[] memory bodies) internal {
        Native memory ctx;
        ctx.nonce = nonces[author]++;
        if (author != address(this)) vm.prank(author, author);
        ledger.execute(actions, bodies, ctx, "");
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _one(address author, Action memory a) internal {
        Action[] memory actions = new Action[](1);
        actions[0] = a;
        _exec(author, actions, new bytes[](1));
    }

    function _bind(address author, bytes32 role, bytes32 target) internal {
        _one(author, _bindAction(author, FOLDER, role, target));
    }

    function _mask(address author, bytes32 role) internal {
        _one(author, _transition(author, ActionKind.UNBIND, role));
    }

    function _release(address author, bytes32 role) internal {
        _one(author, _transition(author, ActionKind.RELEASE, role));
    }

    /// One publication that touches no FOLDER scope of S (a fresh subject).
    function _unrelated(bytes32 salt) internal {
        Action memory a;
        a.kind = ActionKind.CREATE;
        a.salt = salt;
        _one(address(this), a);
    }

    function _bindAction(address author, bytes32 purpose, bytes32 role, bytes32 target)
        internal
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = purpose;
        a.subject = S;
        a.role = role;
        a.target = target;
        a.expectedRevision = revisions[_key(author, purpose, role)]++;
    }

    function _transition(address author, uint8 kind, bytes32 role)
        internal
        returns (Action memory a)
    {
        a.kind = kind;
        a.purpose = FOLDER;
        a.subject = S;
        a.role = role;
        a.expectedRevision = revisions[_key(author, FOLDER, role)]++;
    }

    function _publish(bytes memory body) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = TYPE_OK;
        a.bodyHashOrRecordId = keccak256(body);
    }

    // ---- read helpers -----------------------------------------------------------------------------------------

    function _key(address author, bytes32 purpose, bytes32 role) internal view returns (bytes32) {
        return Keys.binding(_principal(author), Keys.position(purpose, S, role));
    }

    function _principal(address author) internal view returns (bytes32) {
        return author == address(this) ? pA : Keys.principal(author);
    }

    function _lens(bytes32 first, bytes32 second) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        l[0] = first;
        l[1] = second;
    }

    function _at(bytes32 role) internal view returns (Coordinate memory) {
        return Coordinate(FOLDER, S, role);
    }

    function _head() internal view returns (Coordinate memory) {
        return Coordinate(Purpose.HEAD, S, 0);
    }

    function _unpinned() internal pure returns (BasisCommit memory b) {}

    function _fresh() internal pure returns (Cursor memory c) {}

    function _assertSelected(
        Qualified memory q,
        Selection memory s,
        Status st,
        bytes32 principal,
        uint8 index,
        bytes32 target
    ) internal pure {
        assertEq(uint8(q.status), uint8(st), "q.status");
        assertEq(uint8(s.status), uint8(st), "selection status");
        assertEq(s.principalId, principal, "principal");
        assertEq(s.selectedIndex, index, "selected index");
        assertEq(s.target, target, "target");
    }
}
