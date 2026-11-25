// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {ActionKind} from "../interfaces/Actions.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {ComponentSet} from "../interfaces/ILedgerControl.sol";
import {Limits} from "../interfaces/Limits.sol";
import {BasisCommit, Retention, STATUS_VOCABULARY_ID, Status} from "../interfaces/Results.sol";
import {
    AdmissionRow,
    Description,
    Evidence,
    Head,
    RecordHeader,
    Revision
} from "../interfaces/Views.sol";
import {E_LAYOUT, E_RESERVED} from "../interfaces/Errors.sol";

// Every narrowing cast below unpacks a field `Layout` declares at that width or re-narrows a value that was
// widened from a narrower stored field; every ignored tuple component is a field the caller does not need.
// The facets read the ledger row by row, so calls in loops are their purpose, bounded by the read limits.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(unused-return)
// forge-lint: disable-start(calls-loop)

/// @title LedgerRows — the raw-row codec shared by the two ledger facets (design §4.1–§4.3, §5.7)
/// @notice Every key is derived and every packed word unpacked through `Layout` (generated from the committed
///         storage snapshot), and every row is read through `ILedgerHot(ledger).extsload`/`extsloadBatch`.
///         `LedgerViews.sol` imports this library from here so the two facets decode rows identically; the
///         import gate (tools/checks.mjs) lets only these two files reach `Layout`.
library LedgerRows {
    /// The facet ABI revision served by `facetVersion()` and `Description.facetVersion`.
    uint16 internal constant FACET_VERSION = 1;
    uint256 internal constant REALM = uint256(Layout.LEDGER_REALM_ROOT);
    uint256 internal constant COUNTERS = uint256(Layout.LEDGER_COUNTERS_ROOT);
    /// ERC-1967 implementation slot of the ledger proxy.
    uint256 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// `ILedgerHot.extsloadBatch` serves at most this many slots per call.
    uint256 internal constant BATCH = 256;
    /// `E_RESERVED(READ_IDS, length)`: a status-less batched view was handed more ids than
    /// `limits.maxReadIds` (the kernel uses field 30 for the 256-slot `extsloadBatch` bound).
    uint8 internal constant READ_IDS = 31;
    uint8 internal constant SELECTED_NONE = type(uint8).max;

    // ---- layout, raw loads and the basis ------------------------------------------------------------------

    /// The facet-layout gate (design §5.7), three-way so that absence is never a fault: UNKNOWN when `ledger`
    /// has no code at this block (no ledger there yet: a read below its genesis); UNSUPPORTED when it has code
    /// that is not this layout (`layoutId()` reverts, replies short or names another layout); PRESENT when the
    /// facet decodes it. `hot` is true when `layoutId()` answered (every ledger layout serves the Etched getters).
    function probe(address ledger) internal view returns (Status st, bool hot) {
        if (ledger.code.length == 0) return (Status.UNKNOWN, hot); // `hot` is still false
        bytes32 have;
        (hot, have) = word(ledger, ILedgerHot.layoutId.selector);
        st = hot && have == Layout.LAYOUT_ID ? Status.PRESENT : Status.UNSUPPORTED;
    }

    /// The gate alone (see `probe`).
    function gate(address ledger) internal view returns (Status st) {
        (st,) = probe(ledger);
    }

    /// The gate and the basis a view echoes with it: the basis is read whenever `layoutId()` answered (under
    /// any layout, as before), and stays zero when there is no ledger or the code is not one.
    function gateBasis(address ledger) internal view returns (Status st, BasisCommit memory b) {
        bool hot;
        (st, hot) = probe(ledger);
        if (hot) b = basis(ledger);
    }

    /// The facet-layout rule for views whose return carries no `Status`: refuse instead of guessing, with
    /// `E_LAYOUT(expected, have)`; `have` is 0 when there is no code or `layoutId()` does not answer a word.
    function requireLayout(address ledger) internal view {
        (, bytes32 have) = word(ledger, ILedgerHot.layoutId.selector);
        if (have != Layout.LAYOUT_ID) revert E_LAYOUT(Layout.LAYOUT_ID, have);
    }

    /// `basis` for the status-less `basis()` view: served under every layout, `E_LAYOUT(expected, 0)` when
    /// `layoutId()` does not answer (no code, or code that is not a ledger).
    function requireHot(address ledger) internal view returns (BasisCommit memory) {
        (bool hot,) = word(ledger, ILedgerHot.layoutId.selector);
        if (!hot) revert E_LAYOUT(Layout.LAYOUT_ID, bytes32(0));
        return basis(ledger);
    }

    function load(address ledger, uint256 slot) internal view returns (bytes32) {
        return ILedgerHot(ledger).extsload(bytes32(slot));
    }

    /// `slots` through `extsloadBatch`, in chunks of at most 256: one call with `slots` itself when it fits
    /// (also when it is empty), else one call per chunk. Every batched read of the facets goes through this
    /// one call site, so the call, its revert forwarding and the array codec are emitted once.
    function loadAll(address ledger, bytes32[] memory slots)
        internal
        view
        returns (bytes32[] memory out)
    {
        uint256 n = slots.length;
        bool chunked = n > BATCH;
        if (chunked) out = new bytes32[](n);
        uint256 i = 0;
        do {
            uint256 m = n - i < BATCH ? n - i : BATCH; // i < n, or i == n == 0
            bytes32[] memory chunk = slots;
            if (chunked) {
                chunk = new bytes32[](m);
                for (uint256 j; j < m; ++j) {
                    chunk[j] = slots[i + j];
                }
            }
            bytes32[] memory got = ILedgerHot(ledger).extsloadBatch(chunk);
            if (!chunked) {
                out = got;
                break;
            }
            for (uint256 j; j < m; ++j) {
                out[i + j] = got[j]; // checked: a short chunk reply panics here
            }
            i += BATCH;
        } while (i < n);
        // A reply shorter than the request is the out-of-bounds `Panic(0x32)` an index into it would raise;
        // after this check `at(out, i)` is in bounds for every `i < slots.length`.
        if (out.length < n) _panicOutOfBounds();
    }

    /// `count` consecutive slots from `base` in one batch.
    function loadRun(address ledger, uint256 base, uint256 count)
        internal
        view
        returns (bytes32[] memory)
    {
        return loadAll(ledger, run(base, count));
    }

    /// `count` consecutive slots from `base`.
    function run(uint256 base, uint256 count) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            s[i] = bytes32(base + i);
        }
    }

    /// The basis every view echoes, from the Etched hot getters alone, so it is served under any layout.
    /// `registryMutations` is 0 when the registry cannot answer (it is echoed, never compared; design §5.1).
    function basis(address ledger) internal view returns (BasisCommit memory b) {
        ILedgerHot hot = ILedgerHot(ledger);
        b.executionSet = hot.executionSet();
        (b.phase,,, b.revision) = hot.phase();
        b.indexGeneration = hot.indexGeneration();
        (b.admissionHighWater,,,) = hot.counts();
        (, bytes32 m) = word(hot.registry(), ITypeRegistry.mutations.selector);
        b.registryMutations = uint64(uint256(m));
    }

    /// A zero-argument one-word view call that never reverts: (false, 0) when the target reverts, has no code
    /// or replies with fewer than 32 bytes. At most one word is copied (no returndata bomb).
    function word(address target, bytes4 selector) internal view returns (bool ok, bytes32 w) {
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(gas(), target, 0, 4, 0, 32)
            if lt(returndatasize(), 32) { ok := 0 }
            w := mul(mload(0), ok)
        }
    }

    /// A view call that never reverts: `ok` only when the target answered with at least `size` bytes, of
    /// which exactly `size` are copied.
    function viewCall(address target, bytes memory data, uint256 size)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 32), mload(data), 0, 0)
            if lt(returndatasize(), size) { ok := 0 }
        }
        if (ok) {
            ret = new bytes(size);
            assembly ("memory-safe") {
                returndatacopy(add(ret, 32), 0, size)
            }
        }
    }

    function _panicOutOfBounds() private pure {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x4e487b71))
            mstore(4, 0x32)
            revert(0, 0x24)
        }
    }

    /// `w[i]` without the bounds check, for a reply of `loadAll`/`loadRun` (at least as long as the request)
    /// and an `i` below the request's length, which every call site fixes as a constant bound.
    function at(bytes32[] memory w, uint256 i) internal pure returns (bytes32 x) {
        assembly ("memory-safe") {
            x := mload(add(w, shl(5, add(i, 1))))
        }
    }

    /// The read bounds of the live limits profile (realm +13, +14).
    function readBounds(address ledger)
        internal
        view
        returns (uint16 maxReadIds, uint16 maxReadCount, uint32 maxBody)
    {
        bytes32[] memory w = loadRun(ledger, REALM + 13, 2);
        (, maxBody,,,,,,,,,,, maxReadIds) = Layout.unpackRealmStorageWord13(at(w, 0));
        (maxReadCount,,,) = Layout.unpackRealmStorageWord14(at(w, 1));
    }

    // ---- row decoders -------------------------------------------------------------------------------------

    function limits(bytes32 w0, bytes32 w1) internal pure returns (Limits memory l) {
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
        ) = Layout.unpackRealmStorageWord13(w0);
        (l.maxReadCount, l.floorFreshGas, l.floorRewriteGas, l.kernelTail) =
            Layout.unpackRealmStorageWord14(w1);
    }

    function revisionLimits(bytes32 w22, bytes32 w23) internal pure returns (Limits memory l) {
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
        ) = Layout.unpackRevisionRowWord22(w22);
        (l.maxReadCount, l.floorFreshGas, l.floorRewriteGas, l.kernelTail) =
            Layout.unpackRevisionRowWord23(w23);
    }

    /// One revision row (25 words starting at `w[o]`); the ordinal is the caller's.
    function revision(bytes32[] memory w, uint256 o) internal pure returns (Revision memory r) {
        revisionInto(r, w, o);
    }

    /// `revision` into a zeroed `r`.
    function revisionInto(Revision memory r, bytes32[] memory w, uint256 o) internal pure {
        (
            r.activationBlock,
            r.admissionHigh,
            r.publicationHigh,
            r.activationTimestamp,
            r.flags,
            r.executionProfileId,
            r.capabilities
        ) = Layout.unpackRevisionRowWord0(at(w, o));
        r.executionSet = at(w, o + 1);
        ComponentSet memory c = r.components;
        (c.ledgerImpl, r.acceptedChainId) = Layout.unpackRevisionRowWord2(at(w, o + 2));
        c.ledgerImplCodehash = at(w, o + 3);
        c.registryImpl = Layout.unpackRevisionRowWord4(at(w, o + 4));
        c.registryImplCodehash = at(w, o + 5);
        (c.index, r.indexGeneration) = Layout.unpackRevisionRowWord6(at(w, o + 6));
        c.indexCodehash = at(w, o + 7);
        c.indexManifestHash = at(w, o + 8);
        c.ingress = Layout.unpackRevisionRowWord9(at(w, o + 9));
        c.ingressCodehash = at(w, o + 10);
        c.applyDelegate = Layout.unpackRevisionRowWord11(at(w, o + 11));
        c.applyCodehash = at(w, o + 12);
        c.controller = Layout.unpackRevisionRowWord13(at(w, o + 13));
        c.controllerCodehash = at(w, o + 14);
        c.controllerOwner = Layout.unpackRevisionRowWord15(at(w, o + 15));
        c.steward = Layout.unpackRevisionRowWord16(at(w, o + 16));
        r.layoutId = at(w, o + 17);
        c.verifierProfilesRoot = at(w, o + 18);
        r.migrationHash = at(w, o + 19);
        r.dependencyRoot = at(w, o + 20);
        r.limitsProfileId = at(w, o + 21);
        r.limits = revisionLimits(at(w, o + 22), at(w, o + 23));
        r.noticePrincipal = at(w, o + 24);
    }

    /// A head row; the target is canonical (0 unless BOUND), as `ILedgerHot.head` serves it.
    function head(bytes32 meta, bytes32 target) internal pure returns (Head memory h) {
        (
            h.state,
            h.revision,
            h.admission,
            h.targetKind,
            h.prevAdmission,
            h.bindingOrdinal,
            h.notAfter,
            // SPIKE (T-4 number): the strength is not served by the Head ABI in the spike
        ) = Layout.unpackHeadRowWord0(meta);
        if (h.state == 1) h.target = target;
    }

    /// 0 UNSET → ABSENT_PROVEN, 1 BOUND → PRESENT, 2 MASKED, 3 RELEASED; 4..255 are reserved → UNSUPPORTED.
    function headStatus(uint8 state) internal pure returns (Status) {
        if (state == 0) return Status.ABSENT_PROVEN;
        if (state == 1) return Status.PRESENT;
        if (state == 2) return Status.MASKED;
        if (state == 3) return Status.RELEASED;
        return Status.UNSUPPORTED;
    }

    function admission(bytes32 meta, bytes32 a) internal pure returns (AdmissionRow memory r) {
        uint8 withdrawn;
        (
            r.kind,
            r.leaf,
            r.publication,
            r.bindingOrdinal,
            r.expectedRevision,
            r.prevAdmission,
            withdrawn,
            r.policyRow,
            r.roleRow,
            r.targetKind
        ) = Layout.unpackAdmissionRowWord0(meta);
        r.withdrawn = withdrawn != 0;
        // SPIKE (T-4 number): a bind row's policyRow field is its strength; no policy row applies to a bind kind
        if (
            r.kind == ActionKind.BIND || r.kind == ActionKind.UNBIND || r.kind == ActionKind.RELEASE
        ) {
            r.policyRow = 0;
        }
        r.a = a;
    }

    /// Kind 0 is an unwritten row; kinds 8..15 are reserved (refused by the kernel until they are defined).
    function admissionStatus(uint8 kind) internal pure returns (Status) {
        if (kind == 0) return Status.ABSENT_PROVEN;
        return kind > 7 ? Status.UNSUPPORTED : Status.PRESENT;
    }

    /// The evidence cell of `publication` plus what state derives for it (design §4.4, §7.3): the execution
    /// set of the revision it ran under, the native rows' index obligations from that revision row, the
    /// recomputed publication id and the retention grade. A native row's acceptance profile is not stored
    /// (`acceptanceProfile` stays the stored zero: it is re-folded from the admission rows and the registry
    /// history, design §4.4). `present` is false for an unwritten cell (w0 is nonzero for every lane).
    function evidence(address ledger, uint64 publication)
        internal
        view
        returns (bool present, Evidence memory e)
    {
        bytes32[] memory w = loadRun(ledger, Layout.publicationsEvidenceSlot(publication), 13);
        present = at(w, 0) != 0;
        if (!present) return (present, e);
        uint8 flags;
        (e.author, e.proofKind, e.principalKind, e.v, e.leafCount, e.firstAdmission, flags) =
            Layout.unpackEvidenceCellWord0(at(w, 0));
        (e.nonce, e.deadline, e.basisBlock, e.revision, e.verifierProfile) =
            Layout.unpackEvidenceCellWord1(at(w, 1));
        e.principalId = at(w, 2);
        e.intentDigest = at(w, 3);
        e.actionsHash = at(w, 4);
        e.acceptanceProfile = at(w, 5);
        e.indexObligations = at(w, 6);
        e.readSetHash = at(w, 7);
        e.witness0 = at(w, 8);
        e.witness1 = at(w, 9);
        e.submitter = Layout.unpackEvidenceCellWord10(at(w, 10));
        // flags: b0 imported, b1 guarded, b3 executionBound, b4 acceptanceBound, b5 witnessInState
        e.imported = flags & 1 != 0;
        e.guarded = flags & 2 != 0;
        e.executionBound = flags & 8 != 0;
        e.acceptanceBound = flags & 16 != 0;
        // LOG_ONLY when a carrier of the row's authorship lives only in logs: a read-set preimage
        // (ReadSetChecked) or an ERC-1271 witness without the in-state flag (WitnessRetained), design §7.4
        e.retention = e.guarded || (e.proofKind == 3 && flags & 32 == 0)
            ? Retention.LOG_ONLY
            : Retention.STATE;
        e.publicationId = Keys.publicationId(e.principalId, e.intentDigest);
        uint256 row = Layout.revisionsRowsSlot(e.revision);
        bytes32[] memory s = new bytes32[](4);
        s[0] = bytes32(row + 1);
        s[1] = bytes32(row + 6);
        s[2] = bytes32(row + 7);
        s[3] = bytes32(row + 8);
        bytes32[] memory r = loadAll(ledger, s);
        e.executionSet = at(r, 0);
        if (e.proofKind == 1) {
            (address index,) = Layout.unpackRevisionRowWord6(at(r, 1));
            e.indexObligations = keccak256(abi.encode(index, at(r, 2), at(r, 3)));
        }
    }
}

/// @title LedgerReads — the exact-row ledger facet (design §5.7)
/// @notice Immutable and stateless; every function takes `address ledger` and reads it through the Etched
///         `ILedgerHot` getters and `extsload`/`extsloadBatch` with keys and unpackers from `Layout`. Rows come
///         with a `Status` (UNSET is never returned): PRESENT / ABSENT_PROVEN for rows, MASKED / RELEASED for
///         heads in those states, LIMIT_EXCEEDED past `limits.maxReadCount` / `limits.maxBody`, UNKNOWN with
///         every value zero when there is no code at `ledger` (no ledger at this block), UNSUPPORTED on code that
///         is not the layout this facet was generated for (the facet-layout rule, `LedgerRows.probe`) or a
///         reserved row value it cannot interpret. Views whose return carries no `Status` (`describe`,
///         `admissions`, `principalsOf`) revert `E_LAYOUT` instead (`have` 0 without a ledger); `basis` and
///         `publicationAt` use only Etched getters and serve every layout.
contract LedgerReads is ILedgerReads {
    uint256 private constant REALM = LedgerRows.REALM;

    /// The facet ABI revision (also `Description.facetVersion`).
    function facetVersion() external pure returns (uint16) {
        return LedgerRows.FACET_VERSION;
    }

    /// @inheritdoc ILedgerReads
    /// @dev One `extsloadBatch` of the realm namespace (18 words), the counters, the current revision row (25
    ///      words) and the ERC-1967 implementation slot, after `revision()` names the row. Pins come from that
    ///      revision row (what the activation pinned) except `ledgerImpl`, which is the live implementation slot,
    ///      and `ledgerImplCodehash`, its live code hash: the one pin that can move without an activation (the
    ///      SDK compares both with `revisionAt(revision)` and `release.json`). `registryMutations`,
    ///      `catalogCount` and `indexManifestHash` are live calls that yield 0 when the registry or index
    ///      cannot answer. `chainNamespace` is "eip155" and `chainReference` is `bytes32(acceptedChainId)`.
    function describe(address ledger) external view returns (Description memory d) {
        LedgerRows.requireLayout(ledger);
        ILedgerHot hot = ILedgerHot(ledger);
        uint256 row = Layout.revisionsRowsSlot(hot.revision());
        bytes32[] memory s = new bytes32[](45);
        for (uint256 i; i < 18; ++i) {
            s[i] = bytes32(REALM + i);
        }
        s[18] = bytes32(LedgerRows.COUNTERS);
        for (uint256 i; i < 25; ++i) {
            s[19 + i] = bytes32(row + i);
        }
        s[44] = bytes32(LedgerRows.IMPLEMENTATION_SLOT);
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        _realm(d, w);
        Revision memory r = LedgerRows.revision(w, 19);
        d.revisionBlock = r.activationBlock;
        d.revisionAdmissionHigh = r.admissionHigh;
        d.ledgerImpl = address(uint160(uint256(LedgerRows.at(w, 44))));
        d.ledgerImplCodehash = d.ledgerImpl.codehash;
        d.ingress = r.components.ingress;
        d.ingressCodehash = r.components.ingressCodehash;
        d.applyDelegate = r.components.applyDelegate;
        d.applyCodehash = r.components.applyCodehash;
        d.registryImpl = r.components.registryImpl;
        d.registryImplCodehash = r.components.registryImplCodehash;
        d.indexCodehash = r.components.indexCodehash;
        d.controllerCodehash = r.components.controllerCodehash;
        d.controllerOwner = r.components.controllerOwner;
        d.verifierProfilesRoot = r.components.verifierProfilesRoot;
        d.dependencyRoot = r.dependencyRoot;
        d.hotAbiId = hot.hotAbiId();
        (d.phase,,,) = hot.phase();
        d.thisFacet = address(this);
        d.thisFacetCodehash = address(this).codehash;
        d.facetVersion = LedgerRows.FACET_VERSION;
        d.statusVocabularyId = STATUS_VOCABULARY_ID;
        d.chainNamespace = bytes8("eip155");
        d.chainReference = bytes32(uint256(d.acceptedChainId));
        (, bytes32 m) = LedgerRows.word(d.registry, ITypeRegistry.mutations.selector);
        (, bytes32 c) = LedgerRows.word(d.registry, ITypeRegistry.catalogCount.selector);
        (, d.indexManifestHash) = LedgerRows.word(d.index, IIndexReads.manifestHash.selector);
        d.registryMutations = uint64(uint256(m));
        d.catalogCount = uint64(uint256(c));
        // `d` ABI-encoded (see "returns" below): members 0..49, `limits` (member 50, 17 words), member 51
        assembly ("memory-safe") {
            let o := mload(0x40)
            mcopy(o, d, 0x640)
            mcopy(add(o, 0x640), mload(add(d, 0x640)), 0x220)
            mstore(add(o, 0x860), mload(add(d, 0x660)))
            return(o, 0x880)
        }
    }

    function _realm(Description memory d, bytes32[] memory w) private pure {
        uint8 frozen;
        d.realmId = LedgerRows.at(w, 0);
        d.realmOrigin = LedgerRows.at(w, 1);
        d.realmSalt = LedgerRows.at(w, 2);
        (d.genesisChainId, d.acceptedChainId, d.revision, frozen) =
            Layout.unpackRealmStorageWord3(LedgerRows.at(w, 3));
        d.frozen = frozen != 0;
        (d.controller, d.executionProfileId, d.capabilities,) =
            Layout.unpackRealmStorageWord4(LedgerRows.at(w, 4));
        d.registry = Layout.unpackRealmStorageWord5(LedgerRows.at(w, 5));
        (d.index, d.indexGeneration) = Layout.unpackRealmStorageWord6(LedgerRows.at(w, 6));
        d.executionSet = LedgerRows.at(w, 7);
        d.layoutId = LedgerRows.at(w, 8);
        d.domainSeparator = LedgerRows.at(w, 9);
        d.indexObligations = LedgerRows.at(w, 10);
        d.steward = Layout.unpackRealmStorageWord11(LedgerRows.at(w, 11));
        d.limitsProfileId = LedgerRows.at(w, 12);
        d.limits = LedgerRows.limits(LedgerRows.at(w, 13), LedgerRows.at(w, 14));
        d.readerDirectory = Layout.unpackRealmStorageWord16(LedgerRows.at(w, 16));
        d.noticePrincipal = LedgerRows.at(w, 17);
        (d.admissions, d.records, d.bindings, d.publications) =
            Layout.unpackCountersStorage(LedgerRows.at(w, 18));
    }

    /// @inheritdoc ILedgerReads
    /// @dev ABSENT_PROVEN for 0 and for every ordinal above the current revision (rows are append-only).
    function revisionAt(address ledger, uint32 n)
        external
        view
        returns (Status, Revision memory r)
    {
        _return(_revisionAt(ledger, n, r), r);
    }

    function _revisionAt(address ledger, uint32 n, Revision memory r)
        private
        view
        returns (Status)
    {
        Status g = LedgerRows.gate(ledger);
        if (g != Status.PRESENT) return g;
        bytes32[] memory s = new bytes32[](26);
        uint256 row = Layout.revisionsRowsSlot(n);
        for (uint256 i; i < 25; ++i) {
            s[i] = bytes32(row + i);
        }
        s[25] = bytes32(REALM + 3);
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        (,, uint32 current,) = Layout.unpackRealmStorageWord3(LedgerRows.at(w, 25));
        if (n == 0 || n > current) return Status.ABSENT_PROVEN;
        LedgerRows.revisionInto(r, w, 0);
        r.ordinal = n;
        return Status.PRESENT;
    }

    /// @inheritdoc ILedgerReads
    function basis(address ledger) external view returns (BasisCommit memory) {
        return LedgerRows.requireHot(ledger);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The whole body when its length is within `limits.maxBody` (LIMIT_EXCEEDED with the header
    ///      otherwise: page it with `bodySlice`); UNSUPPORTED with the header for a reserved carrier kind.
    function record(address ledger, bytes32 id)
        external
        view
        returns (Status st, RecordHeader memory h, bytes memory body, BasisCommit memory b)
    {
        (st, b) = LedgerRows.gateBasis(ledger);
        if (st != Status.PRESENT) return (st, h, body, b);
        uint32 maxBody;
        (st, h,, maxBody) = _header(ledger, id);
        if (st != Status.PRESENT) return (st, h, body, b);
        if (h.carrierKind != 0) return (Status.UNSUPPORTED, h, body, b);
        if (h.length > maxBody) return (Status.LIMIT_EXCEEDED, h, body, b);
        body = _slice(ledger, id, 0, h.length);
    }

    /// @inheritdoc ILedgerReads
    function recordHeader(address ledger, bytes32 id)
        external
        view
        returns (Status st, RecordHeader memory h)
    {
        st = LedgerRows.gate(ledger);
        if (st != Status.PRESENT) return (st, h);
        (st, h,,) = _header(ledger, id);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The stored words in `[fromWord, fromWord + count)` clipped to the record's word count (words
    ///      beyond the length are never written, so none is invented); the tail word is the stored, masked one.
    function bodyWords(address ledger, bytes32 id, uint32 fromWord, uint16 count)
        external
        view
        returns (Status st, bytes32[] memory words)
    {
        st = LedgerRows.gate(ledger);
        if (st != Status.PRESENT) return (st, words);
        RecordHeader memory h;
        uint16 maxReadCount;
        (st, h, maxReadCount,) = _header(ledger, id);
        if (count > maxReadCount) return (Status.LIMIT_EXCEEDED, words);
        if (st != Status.PRESENT) return (st, words);
        if (h.carrierKind != 0) return (Status.UNSUPPORTED, words);
        uint256 total = (uint256(h.length) + 31) / 32;
        uint256 n = fromWord >= total ? 0 : total - fromWord;
        if (n > count) n = count;
        words = _words(ledger, id, fromWord, n);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The bytes in `[offset, offset + length)` clipped to the record's length.
    function bodySlice(address ledger, bytes32 id, uint32 offset, uint32 length)
        external
        view
        returns (Status st, bytes memory out)
    {
        st = LedgerRows.gate(ledger);
        if (st != Status.PRESENT) return (st, out);
        RecordHeader memory h;
        uint32 maxBody;
        (st, h,, maxBody) = _header(ledger, id);
        if (length > maxBody) return (Status.LIMIT_EXCEEDED, out);
        if (st != Status.PRESENT) return (st, out);
        if (h.carrierKind != 0) return (Status.UNSUPPORTED, out);
        uint256 end = uint256(offset) + length;
        if (end > h.length) end = h.length;
        if (offset < end) out = _slice(ledger, id, offset, end - offset);
    }

    /// The record cell, body word 0 and the read bounds in one batch.
    function _header(address ledger, bytes32 id)
        private
        view
        returns (Status st, RecordHeader memory h, uint16 maxReadCount, uint32 maxBody)
    {
        uint256 cell = Layout.recordsCellsSlot(id);
        bytes32[] memory s = new bytes32[](5);
        s[0] = bytes32(cell);
        s[1] = bytes32(cell + 1);
        s[2] = bytes32(Layout.recordsBodyWordsSlot(id, 0));
        s[3] = bytes32(REALM + 13);
        s[4] = bytes32(REALM + 14);
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        (, maxBody,,,,,,,,,,,) = Layout.unpackRealmStorageWord13(LedgerRows.at(w, 3));
        (maxReadCount,,,) = Layout.unpackRealmStorageWord14(LedgerRows.at(w, 4));
        if (LedgerRows.at(w, 0) == 0) return (Status.ABSENT_PROVEN, h, maxReadCount, maxBody);
        h.typeId = LedgerRows.at(w, 0);
        (h.firstAdmission, h.length, h.occurrences, h.carrierKind) =
            Layout.unpackRecordCellWord1(LedgerRows.at(w, 1));
        h.word0 = LedgerRows.at(w, 2);
        st = Status.PRESENT;
    }

    function _words(address ledger, bytes32 id, uint256 from, uint256 n)
        private
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory s = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = bytes32(Layout.recordsBodyWordsSlot(id, from + i));
        }
        return LedgerRows.loadAll(ledger, s);
    }

    /// `length` body bytes from byte `offset` (both within the record).
    function _slice(address ledger, bytes32 id, uint256 offset, uint256 length)
        private
        view
        returns (bytes memory out)
    {
        out = new bytes(length);
        if (length == 0) return out;
        uint256 first = offset / 32;
        bytes32[] memory words = _words(ledger, id, first, (offset + length + 31) / 32 - first);
        uint256 skip = offset % 32;
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(words, 32), skip), length)
        }
    }

    /// @inheritdoc ILedgerReads
    /// @dev `creatorPrincipal` is the principal of the publication that admitted the CREATE.
    function subjectInfo(address ledger, bytes32 subjectId)
        external
        view
        returns (Status, uint64 createdAt, bytes32 creatorPrincipal)
    {
        Status g = LedgerRows.gate(ledger);
        if (g != Status.PRESENT) return (g, 0, 0);
        (createdAt,) =
            Layout.unpackSubjectCell(LedgerRows.load(ledger, Layout.subjectsCellsSlot(subjectId)));
        if (createdAt == 0) return (Status.ABSENT_PROVEN, 0, 0);
        (,, uint48 publication,,,,,,,) = Layout.unpackAdmissionRowWord0(
            LedgerRows.load(ledger, Layout.admissionsRowsSlot(createdAt))
        );
        creatorPrincipal = LedgerRows.load(ledger, Layout.publicationsEvidenceSlot(publication) + 2);
        return (Status.PRESENT, createdAt, creatorPrincipal);
    }

    /// @inheritdoc ILedgerReads
    function head(address ledger, bytes32 bindingKey)
        external
        view
        returns (Status, Head memory h)
    {
        Status st = LedgerRows.gate(ledger);
        if (st == Status.PRESENT) {
            bytes32[] memory w = LedgerRows.loadRun(ledger, Layout.bindingsHeadsSlot(bindingKey), 2);
            h = LedgerRows.head(LedgerRows.at(w, 0), LedgerRows.at(w, 1));
            st = LedgerRows.headStatus(h.state);
        }
        uint256 p;
        assembly ("memory-safe") {
            p := h
        }
        _returnFlat(st, p, 8);
    }

    /// @inheritdoc ILedgerReads
    function positionCell(address ledger, bytes32 position)
        external
        view
        returns (Status, bytes32 purpose, bytes32 subject, bytes32 role)
    {
        Status g = LedgerRows.gate(ledger);
        if (g != Status.PRESENT) return (g, 0, 0, 0);
        bytes32[] memory w = LedgerRows.loadRun(ledger, Layout.bindingsPositionsSlot(position), 3);
        // purpose is nonzero in every written cell
        if (LedgerRows.at(w, 0) == 0) return (Status.ABSENT_PROVEN, 0, 0, 0);
        return (Status.PRESENT, LedgerRows.at(w, 0), LedgerRows.at(w, 1), LedgerRows.at(w, 2));
    }

    /// @inheritdoc ILedgerReads
    function bindingPosition(address ledger, uint64 bindingOrdinal)
        external
        view
        returns (Status, bytes32 position)
    {
        Status g = LedgerRows.gate(ledger);
        if (g != Status.PRESENT) return (g, 0);
        position = LedgerRows.load(ledger, Layout.bindingsBindingPositionSlot(bindingOrdinal));
        return (position == 0 ? Status.ABSENT_PROVEN : Status.PRESENT, position);
    }

    /// @inheritdoc ILedgerReads
    function admission(address ledger, uint64 ordinal)
        external
        view
        returns (Status, AdmissionRow memory r)
    {
        Status st = LedgerRows.gate(ledger);
        if (st == Status.PRESENT) {
            bytes32[] memory w = LedgerRows.loadRun(ledger, Layout.admissionsRowsSlot(ordinal), 2);
            r = LedgerRows.admission(LedgerRows.at(w, 0), LedgerRows.at(w, 1));
            st = LedgerRows.admissionStatus(r.kind);
        }
        uint256 p;
        assembly ("memory-safe") {
            p := r
        }
        _returnFlat(st, p, 11);
    }

    /// @inheritdoc ILedgerReads
    /// @dev A page: rows `[from, next)` with `from` 0 read as 1, at most `limits.maxReadCount` rows and never past
    ///      the admission high water (`basis.admissionHighWater`); continue from `next`.
    function admissions(address ledger, uint64 from, uint16 count)
        external
        view
        returns (AdmissionRow[] memory rows, uint64 next, BasisCommit memory b)
    {
        LedgerRows.requireLayout(ledger);
        b = LedgerRows.basis(ledger);
        (, uint16 maxReadCount,) = LedgerRows.readBounds(ledger);
        if (from == 0) from = 1;
        uint256 n = count < maxReadCount ? count : maxReadCount;
        uint256 left = b.admissionHighWater >= from ? b.admissionHighWater - from + 1 : 0;
        if (n > left) n = left;
        bytes32[] memory s = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 slot = Layout.admissionsRowsSlot(from + i);
            s[2 * i] = bytes32(slot);
            s[2 * i + 1] = bytes32(slot + 1);
        }
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        rows = new AdmissionRow[](n);
        for (uint256 i; i < n; ++i) {
            rows[i] = LedgerRows.admission(LedgerRows.at(w, 2 * i), LedgerRows.at(w, 2 * i + 1));
        }
        next = from + uint64(n);
    }

    /// @inheritdoc ILedgerReads
    function evidence(address ledger, uint64 publication)
        external
        view
        returns (Status, Evidence memory e)
    {
        Status st = LedgerRows.gate(ledger);
        if (st == Status.PRESENT) {
            bool present;
            (present, e) = LedgerRows.evidence(ledger, publication);
            st = present ? Status.PRESENT : Status.ABSENT_PROVEN;
        }
        uint256 p;
        assembly ("memory-safe") {
            p := e
        }
        _returnFlat(st, p, 27);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The Etched getter's answer with a status; served under every layout (UNKNOWN without a ledger).
    function publicationAt(address ledger, bytes32 principalId, uint64 nonce)
        external
        view
        returns (Status, uint64 publication, bytes32 intentDigest)
    {
        if (ledger.code.length == 0) return (Status.UNKNOWN, 0, 0);
        (publication, intentDigest) = ILedgerHot(ledger).publicationAt(principalId, nonce);
        return (publication == 0 ? Status.ABSENT_PROVEN : Status.PRESENT, publication, intentDigest);
    }

    /// @inheritdoc ILedgerReads
    /// @dev `Keys.principalFor` under the ledger's `realmOrigin`; more than `limits.maxReadIds` accounts revert
    ///      `E_RESERVED(31, length)`.
    function principalsOf(address ledger, address[] calldata accounts)
        external
        view
        returns (bytes32[] memory out)
    {
        LedgerRows.requireLayout(ledger);
        (uint16 maxReadIds,,) = LedgerRows.readBounds(ledger);
        if (accounts.length > maxReadIds) revert E_RESERVED(LedgerRows.READ_IDS, accounts.length);
        bytes32 origin = ILedgerHot(ledger).realmOrigin();
        out = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            out[i] = Keys.principalFor(accounts[i], origin);
        }
    }

    // ---- returns ------------------------------------------------------------------------------------------
    // The large status-carrying views end the call themselves instead of through the ABI encoder: every view
    // struct here holds only one-word value members (nested structs are pointers), the compiler cleans every
    // value it writes to memory, and memory is zeroed where nothing was written, so a struct's memory image,
    // with each nested struct copied in place of its pointer, is exactly its ABI encoding (all members are
    // static). One copy routine then replaces one encoder per return type.

    /// Ends the call with `(st, r)` ABI-encoded: `r` with `components` (member 7, 16 words) and `limits`
    /// (member 16, 17 words) copied in place.
    function _return(Status st, Revision memory r) private pure {
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, st)
            mcopy(add(o, 0x20), r, 0xe0) // members 0..6
            mcopy(add(o, 0x100), mload(add(r, 0xe0)), 0x200) // components
            mcopy(add(o, 0x300), add(r, 0x100), 0x100) // members 8..15
            mcopy(add(o, 0x400), mload(add(r, 0x200)), 0x220) // limits
            mstore(add(o, 0x620), mload(add(r, 0x220))) // member 17
            return(o, 0x640)
        }
    }

    /// Ends the call with `(st, x)` ABI-encoded, `x` the struct of `words` members at memory `p`.
    function _returnFlat(Status st, uint256 p, uint256 words) private pure {
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, st)
            mcopy(add(o, 0x20), p, shl(5, words))
            return(o, shl(5, add(words, 1)))
        }
    }
}
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unused-return)
// forge-lint: disable-end(unsafe-typecast)
