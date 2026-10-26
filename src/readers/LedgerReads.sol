// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
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

    /// The facet-layout rule (design §5.7): the facet decodes only the layout it was generated for.
    function layoutOk(address ledger) internal view returns (bool) {
        return ILedgerHot(ledger).layoutId() == Layout.LAYOUT_ID;
    }

    /// The facet-layout rule for views whose return carries no `Status`: refuse instead of guessing.
    function requireLayout(address ledger) internal view {
        bytes32 have = ILedgerHot(ledger).layoutId();
        if (have != Layout.LAYOUT_ID) revert E_LAYOUT(Layout.LAYOUT_ID, have);
    }

    function load(address ledger, uint256 slot) internal view returns (bytes32) {
        return ILedgerHot(ledger).extsload(bytes32(slot));
    }

    /// `slots` through `extsloadBatch`, in chunks of at most 256.
    function loadAll(address ledger, bytes32[] memory slots)
        internal
        view
        returns (bytes32[] memory out)
    {
        uint256 n = slots.length;
        if (n <= BATCH) return ILedgerHot(ledger).extsloadBatch(slots);
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i += BATCH) {
            uint256 m = n - i < BATCH ? n - i : BATCH;
            bytes32[] memory chunk = new bytes32[](m);
            for (uint256 j; j < m; ++j) {
                chunk[j] = slots[i + j];
            }
            bytes32[] memory got = ILedgerHot(ledger).extsloadBatch(chunk);
            for (uint256 j; j < m; ++j) {
                out[i + j] = got[j];
            }
        }
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

    /// The read bounds of the live limits profile (realm +13, +14).
    function readBounds(address ledger)
        internal
        view
        returns (uint16 maxReadIds, uint16 maxReadCount, uint32 maxBody)
    {
        bytes32[] memory w = ILedgerHot(ledger).extsloadBatch(run(REALM + 13, 2));
        (, maxBody,,,,,,,,,,, maxReadIds) = Layout.unpackRealmStorageWord13(w[0]);
        (maxReadCount,,,) = Layout.unpackRealmStorageWord14(w[1]);
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
        (
            r.activationBlock,
            r.admissionHigh,
            r.publicationHigh,
            r.activationTimestamp,
            r.flags,
            r.executionProfileId,
            r.capabilities
        ) = Layout.unpackRevisionRowWord0(w[o]);
        r.executionSet = w[o + 1];
        ComponentSet memory c = r.components;
        (c.ledgerImpl, r.acceptedChainId) = Layout.unpackRevisionRowWord2(w[o + 2]);
        c.ledgerImplCodehash = w[o + 3];
        c.registryImpl = Layout.unpackRevisionRowWord4(w[o + 4]);
        c.registryImplCodehash = w[o + 5];
        (c.index, r.indexGeneration) = Layout.unpackRevisionRowWord6(w[o + 6]);
        c.indexCodehash = w[o + 7];
        c.indexManifestHash = w[o + 8];
        c.ingress = Layout.unpackRevisionRowWord9(w[o + 9]);
        c.ingressCodehash = w[o + 10];
        c.applyDelegate = Layout.unpackRevisionRowWord11(w[o + 11]);
        c.applyCodehash = w[o + 12];
        c.controller = Layout.unpackRevisionRowWord13(w[o + 13]);
        c.controllerCodehash = w[o + 14];
        c.controllerOwner = Layout.unpackRevisionRowWord15(w[o + 15]);
        c.steward = Layout.unpackRevisionRowWord16(w[o + 16]);
        r.layoutId = w[o + 17];
        c.verifierProfilesRoot = w[o + 18];
        r.migrationHash = w[o + 19];
        r.dependencyRoot = w[o + 20];
        r.limitsProfileId = w[o + 21];
        r.limits = revisionLimits(w[o + 22], w[o + 23]);
        r.noticePrincipal = w[o + 24];
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
            h.notAfter
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
        bytes32[] memory w = ILedgerHot(ledger)
            .extsloadBatch(run(Layout.publicationsEvidenceSlot(publication), 13));
        present = w[0] != 0;
        if (!present) return (present, e);
        uint8 flags;
        (e.author, e.proofKind, e.principalKind, e.v, e.leafCount, e.firstAdmission, flags) =
            Layout.unpackEvidenceCellWord0(w[0]);
        (e.nonce, e.deadline, e.basisBlock, e.revision, e.verifierProfile) =
            Layout.unpackEvidenceCellWord1(w[1]);
        e.principalId = w[2];
        e.intentDigest = w[3];
        e.actionsHash = w[4];
        e.acceptanceProfile = w[5];
        e.indexObligations = w[6];
        e.readSetHash = w[7];
        e.witness0 = w[8];
        e.witness1 = w[9];
        e.submitter = Layout.unpackEvidenceCellWord10(w[10]);
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
        bytes32[] memory r = ILedgerHot(ledger).extsloadBatch(s);
        e.executionSet = r[0];
        if (e.proofKind == 1) {
            (address index,) = Layout.unpackRevisionRowWord6(r[1]);
            e.indexObligations = keccak256(abi.encode(index, r[2], r[3]));
        }
    }
}

/// @title LedgerReads — the exact-row ledger facet (design §5.7)
/// @notice Immutable and stateless; every function takes `address ledger` and reads it through the Etched
///         `ILedgerHot` getters and `extsload`/`extsloadBatch` with keys and unpackers from `Layout`. Rows come
///         with a `Status` (UNSET is never returned): PRESENT / ABSENT_PROVEN for rows, MASKED / RELEASED for
///         heads in those states, LIMIT_EXCEEDED past `limits.maxReadCount` / `limits.maxBody`, UNSUPPORTED on a
///         layout this facet was not generated for (the facet-layout rule) or a reserved row value it cannot
///         interpret. Views whose return carries no `Status` (`describe`, `admissions`, `principalsOf`) revert
///         `E_LAYOUT` instead; `basis` and `publicationAt` use only Etched getters and serve every layout.
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
        bytes32[] memory w = hot.extsloadBatch(s);
        _realm(d, w);
        Revision memory r = LedgerRows.revision(w, 19);
        d.revisionBlock = r.activationBlock;
        d.revisionAdmissionHigh = r.admissionHigh;
        d.ledgerImpl = address(uint160(uint256(w[44])));
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
    }

    function _realm(Description memory d, bytes32[] memory w) private pure {
        uint8 frozen;
        d.realmId = w[0];
        d.realmOrigin = w[1];
        d.realmSalt = w[2];
        (d.genesisChainId, d.acceptedChainId, d.revision, frozen) =
            Layout.unpackRealmStorageWord3(w[3]);
        d.frozen = frozen != 0;
        (d.controller, d.executionProfileId, d.capabilities,) = Layout.unpackRealmStorageWord4(w[4]);
        d.registry = Layout.unpackRealmStorageWord5(w[5]);
        (d.index, d.indexGeneration) = Layout.unpackRealmStorageWord6(w[6]);
        d.executionSet = w[7];
        d.layoutId = w[8];
        d.domainSeparator = w[9];
        d.indexObligations = w[10];
        d.steward = Layout.unpackRealmStorageWord11(w[11]);
        d.limitsProfileId = w[12];
        d.limits = LedgerRows.limits(w[13], w[14]);
        d.readerDirectory = Layout.unpackRealmStorageWord16(w[16]);
        d.noticePrincipal = w[17];
        (d.admissions, d.records, d.bindings, d.publications) = Layout.unpackCountersStorage(w[18]);
    }

    /// @inheritdoc ILedgerReads
    /// @dev ABSENT_PROVEN for 0 and for every ordinal above the current revision (rows are append-only).
    function revisionAt(address ledger, uint32 n)
        external
        view
        returns (Status, Revision memory r)
    {
        if (!LedgerRows.layoutOk(ledger)) {
            return (Status.UNSUPPORTED, r);
        }
        bytes32[] memory s = new bytes32[](26);
        uint256 row = Layout.revisionsRowsSlot(n);
        for (uint256 i; i < 25; ++i) {
            s[i] = bytes32(row + i);
        }
        s[25] = bytes32(REALM + 3);
        bytes32[] memory w = ILedgerHot(ledger).extsloadBatch(s);
        (,, uint32 current,) = Layout.unpackRealmStorageWord3(w[25]);
        if (n == 0 || n > current) return (Status.ABSENT_PROVEN, r);
        r = LedgerRows.revision(w, 0);
        r.ordinal = n;
        return (Status.PRESENT, r);
    }

    /// @inheritdoc ILedgerReads
    function basis(address ledger) external view returns (BasisCommit memory) {
        return LedgerRows.basis(ledger);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The whole body when its length is within `limits.maxBody` (LIMIT_EXCEEDED with the header
    ///      otherwise: page it with `bodySlice`); UNSUPPORTED with the header for a reserved carrier kind.
    function record(address ledger, bytes32 id)
        external
        view
        returns (Status st, RecordHeader memory h, bytes memory body, BasisCommit memory b)
    {
        b = LedgerRows.basis(ledger);
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, h, body, b);
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
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, h);
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
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, words);
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
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, out);
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
        bytes32[] memory w = ILedgerHot(ledger).extsloadBatch(s);
        (, maxBody,,,,,,,,,,,) = Layout.unpackRealmStorageWord13(w[3]);
        (maxReadCount,,,) = Layout.unpackRealmStorageWord14(w[4]);
        if (w[0] == 0) return (Status.ABSENT_PROVEN, h, maxReadCount, maxBody);
        h.typeId = w[0];
        (h.firstAdmission, h.length, h.occurrences, h.carrierKind) =
            Layout.unpackRecordCellWord1(w[1]);
        h.word0 = w[2];
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
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, 0, 0);
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
        if (!LedgerRows.layoutOk(ledger)) {
            return (Status.UNSUPPORTED, h);
        }
        bytes32[] memory w = ILedgerHot(ledger)
            .extsloadBatch(LedgerRows.run(Layout.bindingsHeadsSlot(bindingKey), 2));
        h = LedgerRows.head(w[0], w[1]);
        return (LedgerRows.headStatus(h.state), h);
    }

    /// @inheritdoc ILedgerReads
    function positionCell(address ledger, bytes32 position)
        external
        view
        returns (Status, bytes32 purpose, bytes32 subject, bytes32 role)
    {
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, 0, 0, 0);
        bytes32[] memory w = ILedgerHot(ledger)
            .extsloadBatch(LedgerRows.run(Layout.bindingsPositionsSlot(position), 3));
        if (w[0] == 0) return (Status.ABSENT_PROVEN, 0, 0, 0); // purpose is nonzero in every written cell
        return (Status.PRESENT, w[0], w[1], w[2]);
    }

    /// @inheritdoc ILedgerReads
    function bindingPosition(address ledger, uint64 bindingOrdinal)
        external
        view
        returns (Status, bytes32 position)
    {
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, 0);
        position = LedgerRows.load(ledger, Layout.bindingsBindingPositionSlot(bindingOrdinal));
        return (position == 0 ? Status.ABSENT_PROVEN : Status.PRESENT, position);
    }

    /// @inheritdoc ILedgerReads
    function admission(address ledger, uint64 ordinal)
        external
        view
        returns (Status, AdmissionRow memory r)
    {
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, r);
        bytes32[] memory w =
            ILedgerHot(ledger).extsloadBatch(LedgerRows.run(Layout.admissionsRowsSlot(ordinal), 2));
        r = LedgerRows.admission(w[0], w[1]);
        return (LedgerRows.admissionStatus(r.kind), r);
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
            rows[i] = LedgerRows.admission(w[2 * i], w[2 * i + 1]);
        }
        next = from + uint64(n);
    }

    /// @inheritdoc ILedgerReads
    function evidence(address ledger, uint64 publication)
        external
        view
        returns (Status, Evidence memory e)
    {
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, e);
        bool present;
        (present, e) = LedgerRows.evidence(ledger, publication);
        return (present ? Status.PRESENT : Status.ABSENT_PROVEN, e);
    }

    /// @inheritdoc ILedgerReads
    /// @dev The Etched getter's answer with a status; served under every layout.
    function publicationAt(address ledger, bytes32 principalId, uint64 nonce)
        external
        view
        returns (Status, uint64 publication, bytes32 intentDigest)
    {
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
}
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unused-return)
// forge-lint: disable-end(unsafe-typecast)
