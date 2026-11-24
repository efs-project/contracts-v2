// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "./KernelDeploy.sol";
import {ExecutionSets} from "./ExecutionSets.sol";
import {StateDigest} from "./StateDigest.sol";
import {MockRegistry} from "./doubles/MockRegistry.sol";
import {IndexDoubleCore, PrefixAgreement} from "./doubles/IndexDoubles.sol";
import {LedgerCore} from "../../src/core/LedgerCore.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet, ComponentSet} from "../../src/interfaces/ILedgerControl.sol";
import {FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";

/// @notice Test-only fixture for the control-plane suites (`test/control/`, design §8, §16.4 C2 cells). It
///         deploys and activates genesis exactly as `test/integration/Kernel.t.sol` does — `KernelDeploy` with
///         the test contract as controller and ProxyAdmin owner, `MockRegistry`, a `PrefixAgreement` index
///         double with an explicit readiness tuple — and adds the helpers an activation test needs: the next
///         set built from the live revision row, a second implementation over the same delegates, the
///         ProxyAdmin upgrade, a populated-row marker, raw revision-row and realm-word readers through
///         `Layout`/`extsload`, and the OZ initializer version.
/// @dev There is no `RealmController` yet: the test contract is the controller, so every check §8.3 places
///      in the controller (step 0's controller/owner equality, steps 2–4's upgrade and registry activation,
///      step 6) is either done by hand here (the upgrade, `registry.setActiveRevision`) or is out of scope.
abstract contract ControlFixture is Test {
    // ---- the revision-row flags (design §4.3 w0) ----------------------------------------------------------
    uint16 internal constant FLAG_FROZEN = 1 << 0;
    uint16 internal constant FLAG_SAME_CODE = 1 << 1;
    uint16 internal constant FLAG_CHAIN = 1 << 2;
    uint16 internal constant FLAG_CONTROLLER = 1 << 3;
    uint16 internal constant FLAG_OWNER = 1 << 4;
    uint16 internal constant FLAG_INDEX = 1 << 5;
    uint16 internal constant FLAG_LAYOUT = 1 << 6;
    uint16 internal constant FLAG_LIMITS = 1 << 7;

    // ---- slots outside the EFS namespaces ---------------------------------------------------------------
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    /// erc7201:openzeppelin.storage.Initializable; `_initialized` is the uint64 at the low bits.
    bytes32 internal constant INITIALIZABLE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    bytes32 internal constant REALM_SALT = keccak256("efs2/test/control/salt");

    /// A decoded revision row (design §4.3, 25 words).
    struct Rev {
        uint48 activationBlock;
        uint48 admissionHigh;
        uint48 publicationHigh;
        uint40 activationTimestamp;
        uint16 flags;
        uint16 executionProfileId;
        uint16 capabilities;
        bytes32 executionSet;
        address ledgerImpl;
        uint64 acceptedChainId;
        bytes32 ledgerImplCodehash;
        address registryImpl;
        bytes32 registryImplCodehash;
        address index;
        uint32 indexGeneration;
        bytes32 indexCodehash;
        bytes32 indexManifestHash;
        address ingress;
        bytes32 ingressCodehash;
        address applyDelegate;
        bytes32 applyCodehash;
        address controller;
        bytes32 controllerCodehash;
        address controllerOwner;
        address steward;
        bytes32 layoutId;
        bytes32 verifierProfilesRoot;
        bytes32 migrationHash;
        bytes32 dependencyRoot;
        bytes32 limitsProfileId;
        Limits limits;
        bytes32 noticePrincipal;
    }

    /// The transition word (realm +15).
    struct TransitionWord {
        uint32 target;
        uint48 deadline;
        uint32 lastTarget;
        uint48 cooldownUntil;
    }

    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    PrefixAgreement internal index;
    ILedger internal ledger;
    ILedgerHot internal hot;
    ILedgerControl internal ctl;
    bytes32 internal principal;
    address internal stranger;

    /// The subjects created by `publishMarker`, in order, with the native nonce each consumed.
    bytes32[] internal markerSubjects;
    uint64[] internal markerNonces;

    function setUp() public virtual {
        stranger = makeAddr("stranger");
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), REALM_SALT);
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        ctl = ILedgerControl(k.proxy);
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        index = new PrefixAgreement(k.proxy);
        index.setReadiness(readiness(index, 0, 0));
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registry), address(index), index.manifestHash()
        );
        ctl.activate(set);
        principal = Keys.principalFor(address(this), hot.realmOrigin());
    }

    // =============================================================================================
    // Readiness tuples
    // =============================================================================================

    /// An honest readiness tuple for `idx` at the given frontier (no units, no families).
    function readiness(IndexDoubleCore idx, uint64 admissions, uint64 publications)
        internal
        view
        returns (Readiness memory)
    {
        return readinessFor(k.proxy, idx, admissions, publications);
    }

    /// The same tuple for an index of another ledger (a fresh deployment).
    function readinessFor(
        address ledger_,
        IndexDoubleCore idx,
        uint64 admissions,
        uint64 publications
    ) internal view returns (Readiness memory r) {
        r.version = 1;
        r.ledger = ledger_;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = KernelDeploy.HOT_ABI_ID;
        r.manifestHash = idx.manifestHash();
        r.provenFrom = 1;
        r.completedAdmission = admissions;
        r.completedPublication = publications;
        r.ready = true;
        r.units = new Unit[](0);
        r.families = new FamilyEntry[](0);
    }

    /// An honest readiness tuple at the ledger's live counters.
    function liveReadiness(IndexDoubleCore idx) internal view returns (Readiness memory) {
        (uint64 admissions,,, uint64 publications) = hot.counts();
        return readiness(idx, admissions, publications);
    }

    /// A second `PrefixAgreement` attached to the populated Realm: its contiguity record starts after the
    /// existing history and its readiness tuple is honest at the live counters.
    function newIndexDouble(bytes32 manifestHash) internal returns (PrefixAgreement idx) {
        idx = new PrefixAgreement(k.proxy);
        idx.setManifestHash(manifestHash);
        (uint64 admissions,,, uint64 publications) = hot.counts();
        idx.setProgress(admissions, publications);
        idx.setReadiness(readiness(idx, admissions, publications));
    }

    /// `set` with `idx` as its index component (address, codehash and manifest hash), resealed.
    function withIndex(ActivationSet memory set, address idx)
        internal
        view
        returns (ActivationSet memory)
    {
        set.components.index = idx;
        set.components.indexCodehash = idx.codehash;
        set.components.indexManifestHash = IndexDoubleCore(idx).manifestHash();
        return seal(set);
    }

    // =============================================================================================
    // Activation sets
    // =============================================================================================

    /// The next activation set: the live revision row's components, layout, profile, capabilities, chain,
    /// limits, dependency root and notice principal, the ordinal bumped, no migration, and
    /// `expectedExecutionSet` recomputed offline (design §8.1).
    function nextSet() internal view returns (ActivationSet memory set) {
        uint32 rev = hot.revision();
        Rev memory r = revisionRow(rev);
        set.revision = rev + 1;
        set.components = ComponentSet({
            ledgerImpl: r.ledgerImpl,
            ledgerImplCodehash: r.ledgerImplCodehash,
            registryImpl: r.registryImpl,
            registryImplCodehash: r.registryImplCodehash,
            index: r.index,
            indexCodehash: r.indexCodehash,
            indexManifestHash: r.indexManifestHash,
            ingress: r.ingress,
            ingressCodehash: r.ingressCodehash,
            applyDelegate: r.applyDelegate,
            applyCodehash: r.applyCodehash,
            controller: r.controller,
            controllerCodehash: r.controllerCodehash,
            controllerOwner: r.controllerOwner,
            steward: r.steward,
            verifierProfilesRoot: r.verifierProfilesRoot
        });
        set.layoutId = r.layoutId;
        set.executionProfileId = r.executionProfileId;
        set.capabilities = r.capabilities;
        set.acceptedChainId = r.acceptedChainId;
        set.limits = r.limits;
        set.dependencyRoot = r.dependencyRoot;
        set.noticePrincipal = r.noticePrincipal;
        set.migrationScope = new bytes32[](0);
        set.migration = "";
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }

    /// Recomputes `expectedExecutionSet` after a test edited the set.
    function seal(ActivationSet memory set) internal view returns (ActivationSet memory) {
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        return set;
    }

    /// The execution set the ledger will compute for `set` (independent of `set.expectedExecutionSet`).
    function executionSetOf(ActivationSet memory set) internal view returns (bytes32) {
        return ExecutionSets.executionSet(set, k.proxy);
    }

    /// Advances the registry double (the controller's §8.3 step 4) and activates.
    function activate(ActivationSet memory set) internal {
        registry.setActiveRevision(set.revision);
        ctl.activate(set);
    }

    /// Advances the registry double and expects `activate(set)` to revert with exactly `err`.
    function expectActivateRevert(ActivationSet memory set, bytes memory err) internal {
        registry.setActiveRevision(set.revision);
        vm.expectRevert(err);
        ctl.activate(set);
    }

    /// Advances the registry double and freezes (the controller's §8.10 step 4, then step 5).
    function freeze(ActivationSet memory set) internal {
        registry.setActiveRevision(set.revision);
        ctl.freeze(set);
    }

    /// Advances the registry double and expects `freeze(set)` to revert with exactly `err`.
    function expectFreezeRevert(ActivationSet memory set, bytes memory err) internal {
        registry.setActiveRevision(set.revision);
        vm.expectRevert(err);
        ctl.freeze(set);
    }

    // =============================================================================================
    // Implementations and the ProxyAdmin
    // =============================================================================================

    /// A second `LedgerCore` implementation over the same three delegates. Its runtime equals the
    /// first's (same immutables), so its codehash is the same; only its address differs.
    function deploySecondImplementation() internal returns (address) {
        return address(
            new LedgerCore(
                address(k.ingress),
                address(k.applyDelegate),
                address(k.control),
                KernelDeploy.HOT_ABI_ID
            )
        );
    }

    /// The proxy's ProxyAdmin, read from the ERC-1967 admin slot (the test contract owns it).
    function proxyAdmin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(k.proxy, ADMIN_SLOT)))));
    }

    /// The implementation the proxy runs, read from the ERC-1967 implementation slot.
    function liveImplementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(k.proxy, IMPLEMENTATION_SLOT))));
    }

    /// §8.3 step 2 by hand: upgrades the proxy through its ProxyAdmin with empty call data.
    function upgradeProxy(address implementation) internal {
        proxyAdmin().upgradeAndCall(ITransparentUpgradeableProxy(k.proxy), implementation, "");
    }

    /// OZ `_getInitializedVersion()` of the proxy (design §5.4: revision `n` runs under version `n + 1`).
    function initializedVersion() internal view returns (uint64) {
        return initializedVersionOf(k.proxy);
    }

    function initializedVersionOf(address a) internal view returns (uint64) {
        return uint64(uint256(vm.load(a, INITIALIZABLE_SLOT)));
    }

    // =============================================================================================
    // Writes
    // =============================================================================================

    /// The test contract's next native nonce.
    function nextNonce() internal view returns (uint64 n) {
        (n,) = hot.nonceOf(principal);
    }

    function createActions(bytes32 salt)
        internal
        pure
        returns (Action[] memory actions, bytes[] memory bodies)
    {
        actions = new Action[](1);
        actions[0].kind = ActionKind.CREATE;
        actions[0].salt = salt;
        bodies = new bytes[](1);
    }

    function nativeCtx(uint64 nonce, bytes32 expectedExecutionSet)
        internal
        pure
        returns (Native memory ctx)
    {
        ctx.nonce = nonce;
        ctx.expectedExecutionSet = expectedExecutionSet;
    }

    /// Publishes one native CREATE (unbound) as a "populated" marker and records its subject and nonce.
    function publishMarker(bytes32 salt) internal returns (uint64 publication, bytes32 subjectId) {
        (Action[] memory actions, bytes[] memory bodies) = createActions(salt);
        uint64 nonce = nextNonce();
        (publication,) = ledger.execute(actions, bodies, nativeCtx(nonce, 0), "");
        subjectId = Keys.subject(principal, salt);
        markerSubjects.push(subjectId);
        markerNonces.push(nonce);
    }

    /// Expects the next native CREATE of `salt` (unbound, next nonce) to revert with exactly `err`.
    function expectWriteRevert(bytes32 salt, bytes memory err) internal {
        (Action[] memory actions, bytes[] memory bodies) = createActions(salt);
        Native memory ctx = nativeCtx(nextNonce(), 0);
        vm.expectRevert(err);
        ledger.execute(actions, bodies, ctx, "");
    }

    // =============================================================================================
    // Raw reads through Layout / extsload
    // =============================================================================================

    /// Realm word `+i` (design §4.2) through the Etched `extsload`.
    function realmWord(uint256 i) internal view returns (bytes32) {
        return realmWordOf(k.proxy, i);
    }

    function realmWordOf(address ledger_, uint256 i) internal view returns (bytes32) {
        return ILedgerHot(ledger_).extsload(bytes32(uint256(Layout.LEDGER_REALM_ROOT) + i));
    }

    function transitionWord() internal view returns (TransitionWord memory) {
        return transitionWordOf(k.proxy);
    }

    function transitionWordOf(address ledger_) internal view returns (TransitionWord memory t) {
        (t.target, t.deadline, t.lastTarget, t.cooldownUntil) =
            Layout.unpackRealmStorageWord15(realmWordOf(ledger_, 15));
    }

    /// Revision row `n` (design §4.3), 25 words in one `extsloadBatch`, unpacked through `Layout`.
    function revisionRow(uint256 n) internal view returns (Rev memory) {
        return revisionRowOf(k.proxy, n);
    }

    function revisionRowOf(address ledger_, uint256 n) internal view returns (Rev memory r) {
        uint256 base = Layout.revisionsRowsSlot(n);
        bytes32[] memory slots = new bytes32[](25);
        for (uint256 i; i < 25; ++i) {
            slots[i] = bytes32(base + i);
        }
        bytes32[] memory w = ILedgerHot(ledger_).extsloadBatch(slots);
        (
            r.activationBlock,
            r.admissionHigh,
            r.publicationHigh,
            r.activationTimestamp,
            r.flags,
            r.executionProfileId,
            r.capabilities
        ) = Layout.unpackRevisionRowWord0(w[0]);
        r.executionSet = w[1];
        (r.ledgerImpl, r.acceptedChainId) = Layout.unpackRevisionRowWord2(w[2]);
        r.ledgerImplCodehash = w[3];
        r.registryImpl = Layout.unpackRevisionRowWord4(w[4]);
        r.registryImplCodehash = w[5];
        (r.index, r.indexGeneration) = Layout.unpackRevisionRowWord6(w[6]);
        r.indexCodehash = w[7];
        r.indexManifestHash = w[8];
        r.ingress = Layout.unpackRevisionRowWord9(w[9]);
        r.ingressCodehash = w[10];
        r.applyDelegate = Layout.unpackRevisionRowWord11(w[11]);
        r.applyCodehash = w[12];
        r.controller = Layout.unpackRevisionRowWord13(w[13]);
        r.controllerCodehash = w[14];
        r.controllerOwner = Layout.unpackRevisionRowWord15(w[15]);
        r.steward = Layout.unpackRevisionRowWord16(w[16]);
        r.layoutId = w[17];
        r.verifierProfilesRoot = w[18];
        r.migrationHash = w[19];
        r.dependencyRoot = w[20];
        r.limitsProfileId = w[21];
        Limits memory l = r.limits;
        (
            l.maxActions,
            l.maxBody,
            l.maxRefs,
            l.maxReadSetPrincipals,
            l.maxReadSetPositions,
            l.maxWitness,
            l.maxTransitionBlocks,
            l.inlineWordMax,
            l.witnessRetention,
            l.maxBindsPerPublication,
            l.maxBodyBytesPerPublication,
            l.maxFreshSlotsPerPublication,
            l.maxReadIds
        ) = Layout.unpackRevisionRowWord22(w[22]);
        (l.maxReadCount, l.floorFreshGas, l.floorRewriteGas, l.kernelTail) =
            Layout.unpackRevisionRowWord23(w[23]);
        r.noticePrincipal = w[24];
    }

    /// Digest of every retained row outside the realm namespace: the counters word, every admission row
    /// and evidence cell through the live counters, the marker subjects, the test principal's row and its
    /// `publicationAt` entries, and revision rows `1..revisionsThrough` (design §16.4 post-conditions).
    function retainedDigest(uint32 revisionsThrough) internal view returns (bytes32) {
        (uint64 admissions,,, uint64 publications) = hot.counts();
        uint256 n = 1 + 2 * admissions + 13 * publications + 2 * markerSubjects.length + 1 + 25
            * uint256(revisionsThrough);
        uint256[] memory list = new uint256[](n);
        uint256 j;
        list[j++] = uint256(Layout.LEDGER_COUNTERS_ROOT);
        for (uint256 o = 1; o <= admissions; ++o) {
            uint256 s = Layout.admissionsRowsSlot(o);
            list[j++] = s;
            list[j++] = s + 1;
        }
        for (uint256 p = 1; p <= publications; ++p) {
            uint256 s = Layout.publicationsEvidenceSlot(p);
            for (uint256 w; w < 13; ++w) {
                list[j++] = s + w;
            }
        }
        for (uint256 i; i < markerSubjects.length; ++i) {
            list[j++] = Layout.subjectsCellsSlot(markerSubjects[i]);
            list[j++] = Layout.publicationsPublicationAtSlot(principal, markerNonces[i]);
        }
        list[j++] = Layout.principalsRowsSlot(principal);
        for (uint256 r = 1; r <= revisionsThrough; ++r) {
            uint256 s = Layout.revisionsRowsSlot(r);
            for (uint256 w; w < 25; ++w) {
                list[j++] = s + w;
            }
        }
        return StateDigest.slots(k.proxy, list);
    }

    /// The full `StateDigest.ledger` (realm included) over the markers and revision rows 1..through.
    function fullDigest(uint32 revisionsThrough) internal view returns (bytes32) {
        (uint64 admissions,,, uint64 publications) = hot.counts();
        StateDigest.LedgerKeys memory key;
        key.subjectIds = markerSubjects;
        key.admissionsThrough = admissions;
        key.publicationsThrough = publications;
        key.principalIds = new bytes32[](1);
        key.principalIds[0] = principal;
        key.revisionsThrough = revisionsThrough;
        return StateDigest.ledger(k.proxy, key);
    }
}
