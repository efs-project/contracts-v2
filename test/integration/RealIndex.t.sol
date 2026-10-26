// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    PostingKey,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage, Phase} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {DigestSpec, Effect, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {E_LEDGER, E_WRITER} from "../../src/interfaces/Errors.sol";

/// A final hook that never acknowledges: the index must refuse the publication and the kernel must roll back.
contract RefusingFinalHook is IIndexHook {
    function fold(Effect calldata, bytes32[] calldata, uint64) external pure returns (bytes4) {
        return IIndexHook.fold.selector;
    }

    function validate(uint64, Effect[] calldata, bytes32[] calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(0xdeadbeef);
    }
}

/// @notice The kernel vertical against the real generation-1 index and its stores: every family of design
///         §10.2 folded from Effect/3 alone, the virtual by-record family, scope lists with live bits and
///         stamps, backlink release on mask and rebind, honest coverage answers, and atomic rollback when
///         a final hook refuses.
contract RealIndexTest is Test {
    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    IndexDeploy.Gen1 internal g;
    ILedger internal ledger;
    ILedgerHot internal hot;

    bytes32 internal constant TYPE_OK = keccak256("test/type/ok");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant NAME = keccak256("name");
    uint8 internal constant SHA256_ALG = 1;
    bytes32 internal principal;

    bytes32 internal F_BY_TYPE = Keys.familyId("by-type");
    bytes32 internal F_BY_AUTHOR = Keys.familyId("by-author");
    bytes32 internal F_BACKLINK = Keys.familyId("backlink");
    bytes32 internal F_HISTORY = Keys.familyId("history");
    bytes32 internal F_BY_RECORD = Keys.familyId("by-record");
    bytes32 internal F_UNIQUE = Keys.familyId("unique-by-type");
    bytes32 internal F_DIGEST = Keys.familyId("digest");
    bytes32 internal F_ROLE_SCOPE = Keys.familyId("role-scope");
    bytes32 internal F_ROSTER = Keys.familyId("roster");
    bytes32 internal F_LIVE = Keys.familyId("live-scope");

    bytes internal body = "0123456789abcdef0123456789abcdef-tail";
    bytes32 internal salt = keccak256("file-1");
    bytes32 internal subject;
    bytes32 internal recordId;
    bytes32 internal scopeKey;
    bytes32 internal bindingKey;

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        DigestSpec[] memory specs = new DigestSpec[](1);
        specs[0] = DigestSpec({typeId: TYPE_OK, wordIndex: 0, algorithm: SHA256_ALG});
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), specs);
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k, address(this), address(registry), address(g.index), g.index.manifestHash()
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
        principal = Keys.principalFor(address(this), hot.realmOrigin());
        subject = Keys.subject(principal, salt);
        recordId = Keys.recordFromHash(TYPE_OK, keccak256(body));
        scopeKey = Keys.scope(principal, FOLDER, subject);
        bindingKey = Keys.binding(principal, Keys.position(FOLDER, subject, NAME));
    }

    // ---- helpers ------------------------------------------------------------------------------------------

    function _native(uint64 nonce) internal pure returns (Native memory ctx) {
        ctx.nonce = nonce;
    }

    function _create(bytes32 s) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = s;
    }

    function _publish(bytes32 typeId, bytes memory b) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(b);
    }

    function _reuse(bytes32 typeId, bytes32 record) internal pure returns (Action memory a) {
        a.kind = ActionKind.REUSE;
        a.typeId = typeId;
        a.bodyHashOrRecordId = record;
    }

    function _bindKind(uint8 kind, bytes32 subj, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = kind;
        a.purpose = FOLDER;
        a.subject = subj;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _seed() internal returns (uint64 publication) {
        Action[] memory actions = new Action[](3);
        actions[0] = _create(salt);
        actions[1] = _publish(TYPE_OK, body);
        actions[2] = _bindKind(ActionKind.BIND, subject, NAME, recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        (publication,) = ledger.execute(actions, bodies, _native(0), "");
    }

    function _one(Action memory a, bytes memory b, uint64 nonce)
        internal
        returns (uint64 publication)
    {
        Action[] memory actions = new Action[](1);
        actions[0] = a;
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = b;
        (publication,) = ledger.execute(actions, bodies, _native(nonce), "");
    }

    function _head(bytes32 family, bytes32 typeId, uint8 ordinal, bytes32 value)
        internal
        view
        returns (Coverage c, uint64 count, uint64 live, uint64 last, bool synthesized)
    {
        return g.index.postingHeadOf(FamilyId.wrap(family), TypeId.wrap(typeId), ordinal, value);
    }

    function _word0() internal view returns (bytes32 w) {
        bytes memory b = body;
        assembly ("memory-safe") {
            w := mload(add(b, 32))
        }
    }

    // ---- genesis ------------------------------------------------------------------------------------------

    function testGenesisActivatesTheRealIndex() public view {
        assertEq(hot.index(), address(g.index));
        Readiness memory r = g.index.replayReadiness();
        assertTrue(r.ready);
        assertEq(r.ledger, k.proxy);
        assertEq(r.layoutId, Layout.LAYOUT_ID);
        assertEq(r.hotAbiId, KernelDeploy.HOT_ABI_ID);
        assertEq(r.manifestHash, g.index.manifestHash());
        assertEq(r.families.length, 13);
        assertEq(r.units.length, 0);
        assertEq(r.completedAdmission, 0);
        assertEq(r.completedPublication, 0);
        (Coverage c, uint64 from, uint64 through, uint8 phase) =
            g.index.coverage(FamilyId.wrap(F_BY_TYPE), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(from, 1);
        assertEq(through, 0);
        assertEq(phase, Phase.IDLE);
        assertFalse(g.posting.attached(), "nothing has been written yet");
        assertEq(g.index.workModel().formulaVersion, 1);
        assertEq(g.index.postingStore(), address(g.posting));
        assertEq(g.index.bitmapStore(), address(g.bitmap));
        assertEq(g.index.buildDelegate(), address(0));
    }

    // ---- one publication folds every family -----------------------------------------------------------------

    function testCreatePublishBindFoldsEveryFamily() public {
        assertEq(_seed(), 1);
        (uint64 processed, uint64 publication, bool gapped) = g.index.progress();
        assertEq(processed, 3);
        assertEq(publication, 1);
        assertFalse(gapped);
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE);

        // by-type and by-author: the publish admission (2)
        (Coverage c, uint64 count, uint64 live, uint64 last, bool synth) =
            _head(F_BY_TYPE, TYPE_OK, 0, 0);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1);
        assertEq(live, 1);
        assertEq(last, 2);
        assertFalse(synth);
        (, count,, last,) = _head(F_BY_AUTHOR, 0, 0, principal);
        assertEq(count, 1);
        assertEq(last, 2);
        (, count,, last,) = _head(F_UNIQUE, TYPE_OK, 0, 0);
        assertEq(count, 1);
        assertEq(last, 2);

        // by-record is virtual: synthesized from the record header
        (c, count, live, last, synth) = _head(F_BY_RECORD, 0, 0, recordId);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1);
        assertEq(live, 1);
        assertEq(last, 2);
        assertTrue(synth);
        uint64[] memory entries;
        (c, count, live, entries) = g.index.occurrencesOf(recordId);
        assertEq(entries.length, 1);
        assertEq(entries[0], 2);
        (c, entries, synth) =
            g.index.postingSliceOf(FamilyId.wrap(F_BY_RECORD), TypeId.wrap(0), 0, recordId, 0, 10);
        assertEq(entries.length, 1);
        assertEq(entries[0], 2);
        assertTrue(synth);
        (, count, live, entries) = g.index.occurrencesOf(keccak256("no such record"));
        assertEq(count, 0);
        assertEq(entries.length, 0);

        // digest: word 0 of the body under the gen-1 spec
        bytes32 digestValue = keccak256(abi.encode(bytes32(uint256(SHA256_ALG)), _word0()));
        (c, count,, last,) = _head(F_DIGEST, 0, 0, digestValue);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1);
        assertEq(last, 2);

        // the bind admission (3): history, backlink, scope list, live bit, role-scope
        (, count,, last,) = _head(F_HISTORY, 0, 0, bindingKey);
        assertEq(count, 1);
        assertEq(last, 3);
        (, count, live, last,) = _head(F_BACKLINK, 0, 0, recordId);
        assertEq(count, 1);
        assertEq(live, 1);
        assertEq(last, 3);
        (uint64 sc, uint64 sl, uint64 stamp, uint48 bits,, uint64 entry0) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc, 1);
        assertEq(sl, 1);
        assertEq(stamp, 3);
        assertEq(bits, 1);
        assertEq(entry0, 1, "binding ordinal 1");
        (, count,, last,) = _head(F_ROLE_SCOPE, 0, 0, Keys.roleScope(principal, FOLDER, NAME));
        assertEq(count, 1);
        assertEq(last, 1, "role-scope holds binding ordinals");

        // the stores attached at the first write; CREATE touched no family
        assertTrue(g.posting.attached());
        assertTrue(g.bitmap.attached());
        (address[] memory gens, uint64[] memory from, uint64[] memory to) = g.posting.writers();
        assertEq(gens.length, 1);
        assertEq(gens[0], address(g.index));
        assertEq(from[0], 2);
        assertEq(to[0], 0);
        (gens, from,) = g.bitmap.writers();
        assertEq(from[0], 3);
        Readiness memory r = g.index.replayReadiness();
        assertTrue(r.ready);
        assertEq(r.completedAdmission, 3);
        assertEq(r.completedPublication, 1);
    }

    function testReuseMaterializesTheByRecordList() public {
        _seed();
        assertEq(_one(_reuse(TYPE_OK, recordId), "", 1), 2);
        (Coverage c, uint64 count, uint64 live, uint64[] memory entries) =
            g.index.occurrencesOf(recordId);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 2);
        assertEq(live, 2);
        assertEq(entries.length, 2);
        assertEq(entries[0], 2);
        assertEq(entries[1], 4);
        (,,,, bool synth) = _head(F_BY_RECORD, 0, 0, recordId);
        assertFalse(synth, "materialized at the second occurrence");
        (, count,,,) = _head(F_BY_TYPE, TYPE_OK, 0, 0);
        assertEq(count, 2, "by-type counts occurrences");
        (, count,,,) = _head(F_UNIQUE, TYPE_OK, 0, 0);
        assertEq(count, 1, "unique-by-type counts records");
        (, count,,,) =
            _head(F_DIGEST, 0, 0, keccak256(abi.encode(bytes32(uint256(SHA256_ALG)), _word0())));
        assertEq(count, 1, "digest is fed once per record");
        (uint64 processed, uint64 publication,) = g.index.progress();
        assertEq(processed, 4);
        assertEq(publication, 2);
    }

    function testUnbindThenRestoreMovesLiveBitsBacklinksAndStamps() public {
        _seed();
        _one(_bindKind(ActionKind.UNBIND, subject, NAME, 0, 1), "", 1);
        (uint64 sc, uint64 sl, uint64 stamp, uint48 bits,,) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc, 1, "a mask appends no entry");
        assertEq(sl, 0);
        assertEq(stamp, 4);
        assertEq(bits, 0);
        (, uint64 count, uint64 live, uint64 last,) = _head(F_BACKLINK, 0, 0, recordId);
        assertEq(count, 1);
        assertEq(live, 0, "the masked target is released");
        assertEq(last, 3);
        (, count,, last,) = _head(F_HISTORY, 0, 0, bindingKey);
        assertEq(count, 2);
        assertEq(last, 4);

        _one(_bindKind(ActionKind.BIND, subject, NAME, recordId, 2), "", 2);
        (sc, sl, stamp, bits,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc, 1, "a restore appends no entry either");
        assertEq(sl, 1);
        assertEq(stamp, 5);
        assertEq(bits, 1);
        (, count, live, last,) = _head(F_BACKLINK, 0, 0, recordId);
        assertEq(count, 2);
        assertEq(live, 1);
        assertEq(last, 5);
        (, count,, last,) = _head(F_HISTORY, 0, 0, bindingKey);
        assertEq(count, 3);
        assertEq(last, 5);
        (, count,, last,) = _head(F_ROLE_SCOPE, 0, 0, Keys.roleScope(principal, FOLDER, NAME));
        assertEq(count, 1, "role-scope is written once per coordinate");
    }

    function testRebindReleasesTheOldTargetAndStamps() public {
        _seed();
        bytes memory other = "another body of thirty-two-plus bytes!";
        bytes32 otherId = Keys.recordFromHash(TYPE_OK, keccak256(other));
        Action[] memory actions = new Action[](2);
        actions[0] = _publish(TYPE_OK, other);
        actions[1] = _bindKind(ActionKind.BIND, subject, NAME, otherId, 1);
        bytes[] memory bodies = new bytes[](2);
        bodies[0] = other;
        ledger.execute(actions, bodies, _native(1), "");
        (, uint64 count, uint64 live,,) = _head(F_BACKLINK, 0, 0, recordId);
        assertEq(count, 1);
        assertEq(live, 0, "the old target lost its head");
        (, count, live,,) = _head(F_BACKLINK, 0, 0, otherId);
        assertEq(count, 1);
        assertEq(live, 1);
        (uint64 sc, uint64 sl, uint64 stamp, uint48 bits,,) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc, 1);
        assertEq(sl, 1);
        assertEq(stamp, 5, "REBIND stamps lastMutation");
        assertEq(bits, 1);
        (, count,,,) = _head(F_HISTORY, 0, 0, bindingKey);
        assertEq(count, 2);
        (, count,,,) = _head(F_BY_TYPE, TYPE_OK, 0, 0);
        assertEq(count, 2);
    }

    function testSecondScopeEntryAndSeparateScopes() public {
        _seed();
        bytes32 role2 = keccak256("second-name");
        _one(_bindKind(ActionKind.BIND, subject, role2, recordId, 0), "", 1);
        (uint64 sc, uint64 sl, uint64 stamp, uint48 bits,, uint64 entry0) =
            g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sc, 2);
        assertEq(sl, 2);
        assertEq(stamp, 4);
        assertEq(bits, 3);
        assertEq(entry0, 1);
        assertEq(g.bitmap.scopeEntry(ScopeKey.wrap(scopeKey), 1), 2);
        (, uint64 count, uint64 live,,) = _head(F_BACKLINK, 0, 0, recordId);
        assertEq(count, 2);
        assertEq(live, 2);
        // masking the second entry clears bit 1 only (bisection over binding ordinals)
        _one(_bindKind(ActionKind.UNBIND, subject, role2, 0, 1), "", 2);
        (, sl,, bits,,) = g.bitmap.scopeHead(ScopeKey.wrap(scopeKey));
        assertEq(sl, 1);
        assertEq(bits, 1);
        assertEq(g.bitmap.liveAt(ScopeKey.wrap(scopeKey), 0), 1);
    }

    // ---- honest coverage ---------------------------------------------------------------------------------------

    function testCoverageAnswers() public {
        _seed();
        (Coverage c,,,) =
            g.index.coverage(FamilyId.wrap(keccak256("no-such-family")), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        (c,,,) = g.index.coverage(FamilyId.wrap(F_ROSTER), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN), "roster is NOT_MAINTAINED in generation 1");
        uint64 from;
        uint64 through;
        (c, from, through,) = g.index.coverage(FamilyId.wrap(F_LIVE), ScopeKey.wrap(scopeKey));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(from, 1);
        assertEq(through, 3);
        (c,,,) = g.index.coverageOfType(FamilyId.wrap(F_BY_TYPE), TypeId.wrap(TYPE_OK));
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        (c,,,) = g.index
        .coverageOfType(FamilyId.wrap(F_BY_TYPE), TypeId.wrap(keccak256("unregistered")));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        (c,,,) = g.index.coverageOfDigest(SHA256_ALG);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        (c,,,) = g.index.coverageOfDigest(2);
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        (c,,,) = g.index.coverageOfSpec(FamilyId.wrap(F_DIGEST), TypeId.wrap(TYPE_OK), 0);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        (c,,,) = g.index.coverageOfSpec(FamilyId.wrap(F_DIGEST), TypeId.wrap(TYPE_OK), 1);
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        (c,,,,) = _head(keccak256("no-such-family"), 0, 0, 0);
        assertEq(uint8(c), uint8(Coverage.UNKNOWN));
        assertEq(g.index.provenFrom(), 1);
    }

    // ---- guards -----------------------------------------------------------------------------------------------

    function testOnlyTheLedgerDrivesTheIndexAndOnlyTheIndexWritesTheStores() public {
        Effect[] memory effects = new Effect[](0);
        bytes32[] memory refs = new bytes32[](0);
        vm.expectRevert(E_LEDGER.selector);
        g.index.onAdmission(1, effects, refs);
        vm.expectRevert(E_LEDGER.selector);
        g.index.afterPublication(1, effects, refs);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        g.posting.append(FamilyId.wrap(F_BY_TYPE), PostingKey.wrap(Keys.byTypeList(TYPE_OK)), 1, 0);
        vm.expectRevert(abi.encodeWithSelector(E_WRITER.selector, address(this)));
        g.bitmap.stamp(ScopeKey.wrap(scopeKey), 1);
    }

    // ---- rollback through the final hook -------------------------------------------------------------------------

    function testRefusedFinalHookRollsBackEveryStoreWrite() public {
        // a second Realm whose genesis index carries a refusing final hook
        MockRegistry reg2 = new MockRegistry();
        KernelDeploy.Kernel memory k2 =
            KernelDeploy.deploy(address(this), address(reg2), keccak256("two"));
        reg2.setLedger(k2.proxy);
        reg2.setImplementation(address(reg2));
        reg2.setActiveRevision(1);
        RefusingFinalHook hook = new RefusingFinalHook();
        Unit[] memory units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(0),
            foldCodehash: 0,
            finalHook: address(hook),
            finalCodehash: address(hook).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/refusing-final/1")
        });
        IndexDeploy.Gen1 memory g2 =
            IndexDeploy.deploy(k2.proxy, KernelDeploy.HOT_ABI_ID, units, new DigestSpec[](0));
        ILedgerControl(k2.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k2, address(this), address(reg2), address(g2.index), g2.index.manifestHash()
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
        reg2.setType(TYPE_OK, info, new bytes32[](0));

        Action[] memory actions = new Action[](3);
        actions[0] = _create(salt);
        actions[1] = _publish(TYPE_OK, body);
        bytes32 p2 = Keys.principalFor(address(this), ILedgerHot(k2.proxy).realmOrigin());
        actions[2] = _bindKind(ActionKind.BIND, Keys.subject(p2, salt), NAME, recordId, 0);
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = body;
        vm.expectRevert();
        ILedger(k2.proxy).execute(actions, bodies, _native(0), "");

        (uint64 admissions,,, uint64 publications) = ILedgerHot(k2.proxy).counts();
        assertEq(admissions, 0);
        assertEq(publications, 0);
        (uint64 processed, uint64 publication,) = g2.index.progress();
        assertEq(processed, 0);
        assertEq(publication, 0);
        (, uint64 count,,,) =
            g2.index.postingHeadOf(FamilyId.wrap(F_BY_TYPE), TypeId.wrap(TYPE_OK), 0, 0);
        assertEq(count, 0);
        assertFalse(g2.posting.attached(), "the attachment itself rolled back");
        assertFalse(g2.bitmap.attached());
        (uint8 phase,,,) = ILedgerHot(k2.proxy).phase();
        assertEq(phase, Phase.IDLE);
        assertTrue(g2.index.replayReadiness().ready);
    }

    // ---- review findings -------------------------------------------------------------------------------------

    function testWithdrawOfTheVirtualFirstOccurrenceKeepsLiveHonest() public {
        _seed(); // the record is admission 2
        Action memory w;
        w.kind = ActionKind.WITHDRAW;
        w.target = bytes32(uint256(2));
        _one(w, "", 1); // admission 4
        (Coverage c, uint64 count, uint64 live, uint64[] memory entries) =
            g.index.occurrencesOf(recordId);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1, "the withdrawn first occurrence is materialized as a dead entry");
        assertEq(live, 0);
        assertEq(entries[0], 2);
        (,,, uint64 occ,) = hot.recordHeader(recordId);
        assertEq(occ, 0);
        _one(_reuse(TYPE_OK, recordId), "", 2); // admission 5
        (, count, live, entries) = g.index.occurrencesOf(recordId);
        assertEq(count, 2);
        assertEq(live, 1, "live equals the ledger's occurrences");
        assertEq(entries[1], 5);
        (,,, occ,) = hot.recordHeader(recordId);
        assertEq(occ, 1);
        w.target = bytes32(uint256(5));
        _one(w, "", 3);
        (, count, live,) = g.index.occurrencesOf(recordId);
        assertEq(count, 2);
        assertEq(live, 0);
        (,,, occ,) = hot.recordHeader(recordId);
        assertEq(occ, 0);
    }

    function testTwoSpecsResolvingToOneKeyFoldOnce() public {
        DigestSpec[] memory specs = new DigestSpec[](2);
        specs[0] = DigestSpec({typeId: TYPE_OK, wordIndex: 0, algorithm: SHA256_ALG});
        specs[1] = DigestSpec({typeId: TYPE_OK, wordIndex: 1, algorithm: SHA256_ALG});
        IndexDeploy.Gen1 memory g2 =
            IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), specs);
        registry.setActiveRevision(2);
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), address(g2.index), g2.index.manifestHash()
        );
        set.revision = 2;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        ILedgerControl(k.proxy).activate(set);
        bytes memory twin = bytes.concat(bytes32(uint256(0xABCD)), bytes32(uint256(0xABCD)));
        Action memory a = _publish(TYPE_OK, twin);
        assertEq(_one(a, twin, 0), 1, "identical words under two specs still publish");
        bytes32 value =
            keccak256(abi.encode(bytes32(uint256(SHA256_ALG)), bytes32(uint256(0xABCD))));
        (Coverage c, uint64 count, uint64 live,,) =
            g2.index.postingHeadOf(FamilyId.wrap(F_DIGEST), TypeId.wrap(0), 0, value);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1, "folded once");
        assertEq(live, 1);
    }
}
