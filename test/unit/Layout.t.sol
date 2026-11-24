// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {LedgerStorage} from "../../src/core/storage/LedgerStorage.sol";
import {RegistryStorage} from "../../src/types/storage/RegistryStorage.sol";
import {
    PostingStoreStorage,
    BitmapStoreStorage,
    WriterRange
} from "../../src/index/storage/StoreStorage.sol";
import {GenerationStorage} from "../../src/index/storage/GenerationStorage.sol";
import {Limits} from "../../src/interfaces/Limits.sol";

/// Writes through the typed namespaced structs; the test reads the raw slots back through `Layout`.
contract LedgerWriter is LedgerStorage {
    function setControl(uint64 g, uint64 a, uint32 r, uint8 f) external {
        RealmStorage storage $ = _realm();
        $.genesisChainId = g;
        $.acceptedChainId = a;
        $.revision = r;
        $.frozen = f;
    }

    function setAuthority(address c, uint16 p, uint16 caps, uint16 gp) external {
        RealmStorage storage $ = _realm();
        $.controller = c;
        $.executionProfileId = p;
        $.capabilities = caps;
        $.genesisExecutionProfileId = gp;
    }

    function setLimits(Limits calldata l) external {
        _realm().limits = l;
    }

    function setTransition(uint32 t, uint48 d, uint32 lt, uint48 cu) external {
        RealmStorage storage $ = _realm();
        $.transitionTarget = t;
        $.transitionDeadline = d;
        $.transitionLastTarget = lt;
        $.transitionCooldownUntil = cu;
    }

    function setWords(
        bytes32 realmId,
        bytes32 executionSet,
        bytes32 noticePrincipal,
        address readerDirectory
    ) external {
        RealmStorage storage $ = _realm();
        $.realmId = realmId;
        $.executionSet = executionSet;
        $.noticePrincipal = noticePrincipal;
        $.readerDirectory = readerDirectory;
    }

    function setCounters(uint48 a, uint48 r, uint48 b, uint48 p) external {
        CountersStorage storage $ = _counters();
        $.admissions = a;
        $.records = r;
        $.bindings = b;
        $.publications = p;
    }

    function setRecord(
        bytes32 id,
        bytes32 typeId,
        uint48 fa,
        uint32 len,
        uint48 occ,
        uint8 ck,
        bytes32 w0,
        bytes32 w7
    ) external {
        RecordCell storage c = _records().cells[id];
        c.typeId = typeId;
        c.firstAdmission = fa;
        c.length = len;
        c.occurrences = occ;
        c.carrierKind = ck;
        _records().bodyWords[id][0] = w0;
        _records().bodyWords[id][7] = w7;
    }

    function setAdmission(uint256 ordinal, AdmissionRow calldata row) external {
        _admissions().rows[ordinal] = row;
    }

    function setEvidenceW0W1(
        uint256 pub,
        address author,
        uint8 pk,
        uint8 prk,
        uint8 v,
        uint8 lc,
        uint48 fa,
        uint8 flags,
        uint48 nonce,
        uint64 deadline,
        uint48 bb,
        uint32 rev,
        uint16 vp
    ) external {
        EvidenceCell storage e = _publications().evidence[pub];
        e.author = author;
        e.proofKind = pk;
        e.principalKind = prk;
        e.v = v;
        e.leafCount = lc;
        e.firstAdmission = fa;
        e.flags = flags;
        e.nonce = nonce;
        e.deadline = deadline;
        e.basisBlock = bb;
        e.revision = rev;
        e.verifierProfile = vp;
    }

    function setPublicationAt(bytes32 principal, uint256 nonce, uint48 pub) external {
        _publications().publicationAt[principal][nonce] = pub;
    }

    function setHead(bytes32 key, HeadRow calldata h) external {
        _bindings().heads[key] = h;
    }

    function setPrincipal(bytes32 id, uint48 n, uint48 v) external {
        _principals().rows[id] = PrincipalRow(n, v);
    }

    function setRevisionW0(
        uint256 rev,
        uint48 ab,
        uint48 ah,
        uint48 ph,
        uint40 ts,
        uint16 flags,
        uint16 ep,
        uint16 caps
    ) external {
        RevisionRow storage r = _revisions().rows[rev];
        r.activationBlock = ab;
        r.admissionHigh = ah;
        r.publicationHigh = ph;
        r.activationTimestamp = ts;
        r.flags = flags;
        r.executionProfileId = ep;
        r.capabilities = caps;
        r.limits.kernelTail = 20_000;
        r.noticePrincipal = bytes32(uint256(7));
    }
}

contract RegistryWriter is RegistryStorage {
    function setType(bytes32 id, TypeRow calldata row, bytes32 ref1) external {
        _types().rows[id] = row;
        _types().refTypes[id][1] = ref1;
    }

    function setControl(address l, uint32 ar, uint16 wc, uint48 m, uint48 cc) external {
        ControlStorage storage $ = _control();
        $.ledger = l;
        $.activeRevision = ar;
        $.wrapperCount = wc;
        $.mutations = m;
        $.catalogCount = cc;
    }
}

contract StoreWriter is PostingStoreStorage, BitmapStoreStorage {
    function setPosting(bytes32 key, uint48 c, uint48 l, uint48 last, uint16 f, uint256 w3)
        external
    {
        PostingHead storage h = _posting().heads[key];
        h.count = c;
        h.live = l;
        h.last = last;
        h.flags = f;
        _posting().words[key][3] = w3;
        _posting().writers.push(WriterRange(address(0xABCD), 5, 0));
        _posting().writers.push(WriterRange(address(0xBEEF), 9, 12));
        _posting().attached = 1;
    }

    function setScope(
        bytes32 scope,
        ScopeHead calldata h,
        bytes32 family,
        uint256 bitsWord,
        CoverageSlot calldata cov
    ) external {
        _bitmap().scopeHeads[scope] = h;
        _bitmap().bits[scope][family][2] = bitsWord;
        _bitmap().coverage[family][scope] = cov;
    }
}

contract GenWriter is GenerationStorage {
    function setProgress(
        uint48 lp,
        uint48 lpub,
        uint8 g,
        uint8 ls,
        uint8 rs,
        bytes32 fam,
        uint48 through,
        uint8 st
    ) external {
        Progress storage p = _gen().progress;
        p.lastProcessed = lp;
        p.lastPublication = lpub;
        p.gapped = g;
        p.liveStarted = ls;
        p.replayStage = rs;
        _gen().buildFrontier[fam] = BuildFrontier(through, st);
    }
}

/// @notice Typed-struct writes land exactly where `Layout` says, and `Layout`'s unpackers read them back
///         field by field at every width; this is the parity the facets, the decoder and the SDK rely on.
contract LayoutTest is Test {
    LedgerWriter internal L = new LedgerWriter();
    RegistryWriter internal R = new RegistryWriter();
    StoreWriter internal S = new StoreWriter();
    GenWriter internal G = new GenWriter();

    function raw(address a, uint256 slot) internal view returns (bytes32) {
        return vm.load(a, bytes32(slot));
    }

    function testLayoutIdIsStable() public pure {
        // Regenerate with `pnpm layout`; a changed id means a one-way door moved.
        assertEq(
            Layout.LAYOUT_ID, 0x61a441c149dcbe899e7243167ec95077ad34211feeb9232959903c20a6c6484a
        );
    }

    function testFuzzRealmWords(
        uint64 g,
        uint64 a,
        uint32 r,
        bool f,
        address c,
        uint16 p,
        uint16 caps,
        uint16 gp
    ) public {
        L.setControl(g, a, r, f ? 1 : 0);
        L.setAuthority(c, p, caps, gp);
        (uint64 g2, uint64 a2, uint32 r2, uint8 f2) =
            Layout.unpackRealmStorageWord3(raw(address(L), Layout.LEDGER_REALM_GENESISCHAINID_SLOT));
        assertEq(g2, g);
        assertEq(a2, a);
        assertEq(r2, r);
        assertEq(f2, f ? 1 : 0);
        (address c2, uint16 p2, uint16 caps2, uint16 gp2) =
            Layout.unpackRealmStorageWord4(raw(address(L), Layout.LEDGER_REALM_CONTROLLER_SLOT));
        assertEq(c2, c);
        assertEq(p2, p);
        assertEq(caps2, caps);
        assertEq(gp2, gp);
        assertEq(Layout.LEDGER_REALM_CONTROLLER_SLOT, uint256(Layout.LEDGER_REALM_ROOT) + 4);
    }

    function testFuzzRealmLimitsAndTransition(
        Limits memory l,
        uint32 t,
        uint48 d,
        uint32 lt,
        uint48 cu
    ) public {
        L.setLimits(l);
        L.setTransition(t, d, lt, cu);
        (
            uint16 maxActions,
            uint32 maxBody,
            uint8 maxRefs,
            uint16 maxReadSetPrincipals,
            uint8 maxReadSetPositions,
            uint16 maxWitness,
            uint32 maxTransitionBlocks,
            uint16 inlineWordMax,
            uint8 witnessRetention,
            uint16 maxBindsPerPublication,
            uint32 maxBodyBytesPerPublication,
            uint32 maxFreshSlotsPerPublication,
            uint16 maxReadIds
        ) = Layout.unpackRealmStorageWord13(raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 13));
        assertEq(maxActions, l.maxActions);
        assertEq(maxBody, l.maxBody);
        assertEq(maxRefs, l.maxRefs);
        assertEq(maxReadSetPrincipals, l.maxReadSetPrincipals);
        assertEq(maxReadSetPositions, l.maxReadSetPositions);
        assertEq(maxWitness, l.maxWitness);
        assertEq(maxTransitionBlocks, l.maxTransitionBlocks);
        assertEq(inlineWordMax, l.inlineWordMax);
        assertEq(witnessRetention, l.witnessRetention);
        assertEq(maxBindsPerPublication, l.maxBindsPerPublication);
        assertEq(maxBodyBytesPerPublication, l.maxBodyBytesPerPublication);
        assertEq(maxFreshSlotsPerPublication, l.maxFreshSlotsPerPublication);
        assertEq(maxReadIds, l.maxReadIds);
        (uint16 maxReadCount, uint32 floorFreshGas, uint32 floorRewriteGas, uint32 kernelTail) =
            Layout.unpackRealmStorageWord14(raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 14));
        assertEq(maxReadCount, l.maxReadCount);
        assertEq(floorFreshGas, l.floorFreshGas);
        assertEq(floorRewriteGas, l.floorRewriteGas);
        assertEq(kernelTail, l.kernelTail);
        (uint32 t2, uint48 d2, uint32 lt2, uint48 cu2) = Layout.unpackRealmStorageWord15(
            raw(address(L), Layout.LEDGER_REALM_TRANSITIONTARGET_SLOT)
        );
        assertEq(t2, t);
        assertEq(d2, d);
        assertEq(lt2, lt);
        assertEq(cu2, cu);
    }

    function testRealmSingleWordsAndRootsAreTheDesignSlots() public {
        L.setWords(bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), address(4));
        assertEq(raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 0), bytes32(uint256(1)));
        assertEq(raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 7), bytes32(uint256(2)));
        assertEq(raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 17), bytes32(uint256(3)));
        assertEq(
            Layout.unpackRealmStorageWord16(
                raw(address(L), uint256(Layout.LEDGER_REALM_ROOT) + 16)
            ),
            address(4)
        );
    }

    function testFuzzCounters(uint48 a, uint48 r, uint48 b, uint48 p) public {
        L.setCounters(a, r, b, p);
        (uint48 a2, uint48 r2, uint48 b2, uint48 p2) =
            Layout.unpackCountersStorage(raw(address(L), uint256(Layout.LEDGER_COUNTERS_ROOT)));
        assertEq(a2, a);
        assertEq(r2, r);
        assertEq(b2, b);
        assertEq(p2, p);
    }

    function testFuzzRecordCellAndBodyWords(
        bytes32 id,
        bytes32 typeId,
        uint48 fa,
        uint32 len,
        uint48 occ,
        uint8 ck,
        bytes32 w0,
        bytes32 w7
    ) public {
        L.setRecord(id, typeId, fa, len, occ, ck, w0, w7);
        uint256 s = Layout.recordsCellsSlot(id);
        assertEq(raw(address(L), s), typeId);
        (uint48 fa2, uint32 len2, uint48 occ2, uint8 ck2) =
            Layout.unpackRecordCellWord1(raw(address(L), s + 1));
        assertEq(fa2, fa);
        assertEq(len2, len);
        assertEq(occ2, occ);
        assertEq(ck2, ck);
        assertEq(raw(address(L), Layout.recordsBodyWordsSlot(id, 0)), w0);
        assertEq(raw(address(L), Layout.recordsBodyWordsSlot(id, 7)), w7);
        if (w0 != 0) {
            assertTrue(raw(address(L), Layout.recordsBodyWordsSlot(id, 1)) == 0, "untouched word");
        }
    }

    function testFuzzAdmissionRow(uint256 ordinal, LedgerStorage.AdmissionRow memory row) public {
        L.setAdmission(ordinal, row);
        uint256 s = Layout.admissionsRowsSlot(ordinal);
        (
            uint8 kind,
            uint8 leaf,
            uint48 publication,
            uint48 bindingOrdinal,
            uint48 expectedRevision,
            uint48 prevAdmission,
            uint8 withdrawn,
            uint16 policyRow,
            uint16 roleRow,
            uint8 targetKind
        ) = Layout.unpackAdmissionRowWord0(raw(address(L), s));
        assertEq(kind, row.kind);
        assertEq(leaf, row.leaf);
        assertEq(publication, row.publication);
        assertEq(bindingOrdinal, row.bindingOrdinal);
        assertEq(expectedRevision, row.expectedRevision);
        assertEq(prevAdmission, row.prevAdmission);
        assertEq(withdrawn, row.withdrawn);
        assertEq(policyRow, row.policyRow);
        assertEq(roleRow, row.roleRow);
        assertEq(targetKind, row.targetKind);
        assertEq(raw(address(L), s + 1), row.a);
    }

    function testFuzzEvidenceWords(
        uint256 pub,
        address author,
        uint8 pk,
        uint8 prk,
        uint8 v,
        uint8 lc,
        uint48 fa,
        uint8 flags,
        uint48 nonce,
        uint64 deadline,
        uint48 bb,
        uint32 rev,
        uint16 vp
    ) public {
        L.setEvidenceW0W1(pub, author, pk, prk, v, lc, fa, flags, nonce, deadline, bb, rev, vp);
        uint256 s = Layout.publicationsEvidenceSlot(pub);
        (address author2, uint8 pk2, uint8 prk2, uint8 v2, uint8 lc2, uint48 fa2, uint8 flags2) =
            Layout.unpackEvidenceCellWord0(raw(address(L), s));
        assertEq(author2, author);
        assertEq(pk2, pk);
        assertEq(prk2, prk);
        assertEq(v2, v);
        assertEq(lc2, lc);
        assertEq(fa2, fa);
        assertEq(flags2, flags);
        (uint48 nonce2, uint64 deadline2, uint48 bb2, uint32 rev2, uint16 vp2) =
            Layout.unpackEvidenceCellWord1(raw(address(L), s + 1));
        assertEq(nonce2, nonce);
        assertEq(deadline2, deadline);
        assertEq(bb2, bb);
        assertEq(rev2, rev);
        assertEq(vp2, vp);
        // sparse: w2..w12 untouched
        assertEq(raw(address(L), s + 3), bytes32(0));
    }

    function testFuzzPublicationAtAndPrincipal(
        bytes32 principal,
        uint64 nonce,
        uint48 pub,
        uint48 n,
        uint48 vmv
    ) public {
        L.setPublicationAt(principal, nonce, pub);
        assertEq(
            uint256(raw(address(L), Layout.publicationsPublicationAtSlot(principal, nonce))), pub
        );
        L.setPrincipal(principal, n, vmv);
        (uint48 n2, uint48 v2) =
            Layout.unpackPrincipalRow(raw(address(L), Layout.principalsRowsSlot(principal)));
        assertEq(n2, n);
        assertEq(v2, vmv);
    }

    function testFuzzHeadRow(bytes32 key, LedgerStorage.HeadRow memory h) public {
        L.setHead(key, h);
        uint256 s = Layout.bindingsHeadsSlot(key);
        (
            uint8 state,
            uint48 revision,
            uint48 admission,
            uint8 targetKind,
            uint48 prevAdmission,
            uint48 bindingOrdinal,
            uint40 notAfter
        ) = Layout.unpackHeadRowWord0(raw(address(L), s));
        assertEq(state, h.state);
        assertEq(revision, h.revision);
        assertEq(admission, h.admission);
        assertEq(targetKind, h.targetKind);
        assertEq(prevAdmission, h.prevAdmission);
        assertEq(bindingOrdinal, h.bindingOrdinal);
        assertEq(notAfter, h.notAfter);
        assertEq(raw(address(L), s + 1), h.target);
    }

    function testFuzzRevisionRowWord0(
        uint256 rev,
        uint48 ab,
        uint48 ah,
        uint48 ph,
        uint40 ts,
        uint16 flags,
        uint16 ep,
        uint16 caps
    ) public {
        L.setRevisionW0(rev, ab, ah, ph, ts, flags, ep, caps);
        uint256 s = Layout.revisionsRowsSlot(rev);
        (uint48 ab2, uint48 ah2, uint48 ph2, uint40 ts2, uint16 flags2, uint16 ep2, uint16 caps2) =
            Layout.unpackRevisionRowWord0(raw(address(L), s));
        assertEq(ab2, ab);
        assertEq(ah2, ah);
        assertEq(ph2, ph);
        assertEq(ts2, ts);
        assertEq(flags2, flags);
        assertEq(ep2, ep);
        assertEq(caps2, caps);
        // the row is 25 words: limits occupy +22/+23 and noticePrincipal is +24
        (,,, uint32 kernelTail) = Layout.unpackRevisionRowWord23(raw(address(L), s + 23));
        assertEq(kernelTail, 20_000);
        assertEq(raw(address(L), s + 24), bytes32(uint256(7)));
    }

    function testFuzzTypeRowAndControl(
        bytes32 id,
        RegistryStorage.TypeRow memory row,
        bytes32 ref1,
        address l,
        uint32 ar,
        uint16 wc,
        uint48 m,
        uint48 cc
    ) public {
        R.setType(id, row, ref1);
        uint256 s = Layout.typesRowsSlot(id);
        (
            uint8 grade,
            uint8 refCount,
            uint8 wrapperVersion,
            uint8 ruleMode,
            uint8 dependencyClass,
            uint8 refHeaderWords,
            uint24 validationGas,
            uint16 policyRows,
            uint40 registeredAt,
            uint48 catalogOrdinal,
            uint8 codecVersion,
            uint8 textProfile
        ) = Layout.unpackTypeRowWord0(raw(address(R), s));
        assertEq(grade, row.grade);
        assertEq(refCount, row.refCount);
        assertEq(wrapperVersion, row.wrapperVersion);
        assertEq(ruleMode, row.ruleMode);
        assertEq(dependencyClass, row.dependencyClass);
        assertEq(refHeaderWords, row.refHeaderWords);
        assertEq(validationGas, row.validationGas);
        assertEq(policyRows, row.policyRows);
        assertEq(registeredAt, row.registeredAt);
        assertEq(catalogOrdinal, row.catalogOrdinal);
        assertEq(codecVersion, row.codecVersion);
        assertEq(textProfile, row.textProfile);
        assertEq(raw(address(R), s + 1), row.shape);
        assertEq(raw(address(R), s + 2), row.ruleId);
        assertEq(Layout.unpackTypeRowWord3(raw(address(R), s + 3)), row.mandatory);
        (address blob, uint16 blobLength) = Layout.unpackTypeRowWord4(raw(address(R), s + 4));
        assertEq(blob, row.descriptorBlob);
        assertEq(blobLength, row.blobLength);
        assertEq(raw(address(R), s + 5), row.grammarProfile);
        assertEq(raw(address(R), Layout.typesRefTypesSlot(id, 1)), ref1);
        R.setControl(l, ar, wc, m, cc);
        (address l2, uint32 ar2, uint16 wc2, uint48 m2) =
            Layout.unpackControlStorageWord0(raw(address(R), uint256(Layout.REGISTRY_CONTROL_ROOT)));
        assertEq(l2, l);
        assertEq(ar2, ar);
        assertEq(wc2, wc);
        assertEq(m2, m);
        assertEq(
            Layout.unpackControlStorageWord1(
                raw(address(R), uint256(Layout.REGISTRY_CONTROL_ROOT) + 1)
            ),
            cc
        );
    }

    function testFuzzStores(
        bytes32 key,
        uint48 c,
        uint48 l,
        uint48 last,
        uint16 f,
        uint256 w3,
        bytes32 scope,
        BitmapStoreStorage.ScopeHead memory h,
        bytes32 fam,
        uint256 bitsWord,
        BitmapStoreStorage.CoverageSlot memory cov
    ) public {
        S.setPosting(key, c, l, last, f, w3);
        (uint48 c2, uint48 l2, uint48 last2, uint16 f2) =
            Layout.unpackPostingHead(raw(address(S), Layout.postingHeadsSlot(key)));
        assertEq(c2, c);
        assertEq(l2, l);
        assertEq(last2, last);
        assertEq(f2, f);
        assertEq(uint256(raw(address(S), Layout.postingWordsSlot(key, 3))), w3);
        assertEq(uint256(raw(address(S), Layout.INDEX_STORE_POSTING_WRITERS_LENGTH_SLOT)), 2);
        (address gen, uint48 from, uint48 to) =
            Layout.unpackWriterRange(raw(address(S), Layout.postingWritersElementSlot(1)));
        assertEq(gen, address(0xBEEF));
        assertEq(from, 9);
        assertEq(to, 12);
        assertEq(uint256(raw(address(S), Layout.INDEX_STORE_POSTING_ATTACHED_SLOT)), 1);

        S.setScope(scope, h, fam, bitsWord, cov);
        (
            uint48 count,
            uint48 live,
            uint48 lastMutation,
            uint48 liveBits0,
            uint16 flags,
            uint48 entry0
        ) = Layout.unpackScopeHead(raw(address(S), Layout.bitmapScopeHeadsSlot(scope)));
        assertEq(count, h.count);
        assertEq(live, h.live);
        assertEq(lastMutation, h.lastMutation);
        assertEq(liveBits0, h.liveBits0);
        assertEq(flags, h.flags);
        assertEq(entry0, h.entry0);
        assertEq(uint256(raw(address(S), Layout.bitmapBitsSlot(scope, fam, 2))), bitsWord);
        (uint48 through, uint48 liveFrom, uint48 retiredAt, uint8 state) =
            Layout.unpackCoverageSlot(raw(address(S), Layout.bitmapCoverageSlot(fam, scope)));
        assertEq(through, cov.through);
        assertEq(liveFrom, cov.liveFrom);
        assertEq(retiredAt, cov.retiredAt);
        assertEq(state, cov.state);
    }

    function testFuzzGeneration(
        uint48 lp,
        uint48 lpub,
        uint8 g,
        uint8 ls,
        uint8 rs,
        bytes32 fam,
        uint48 through,
        uint8 st
    ) public {
        G.setProgress(lp, lpub, g, ls, rs, fam, through, st);
        (uint48 lp2, uint48 lpub2, uint8 g2, uint8 ls2, uint8 rs2) =
            Layout.unpackGenStorage(raw(address(G), uint256(Layout.INDEX_GEN_ROOT)));
        assertEq(lp2, lp);
        assertEq(lpub2, lpub);
        assertEq(g2, g);
        assertEq(ls2, ls);
        assertEq(rs2, rs);
        (uint48 through2, uint8 st2) =
            Layout.unpackBuildFrontier(raw(address(G), Layout.genBuildFrontierSlot(fam)));
        assertEq(through2, through);
        assertEq(st2, st);
    }
}
