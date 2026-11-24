// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KernelFixture} from "../../harness/KernelFixture.sol";
import {KernelDeploy} from "../../harness/KernelDeploy.sol";
import {BaseIndexDouble} from "../../harness/doubles/IndexDoubles.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {Phase} from "../../../src/interfaces/Results.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {E_RESERVED} from "../../../src/interfaces/Errors.sol";

/// Logs what `phase()` and `counts()` show from inside each prefix callback; the final call checks them itself.
contract ProbeIndex is BaseIndexDouble {
    event Probe(
        uint64 effectAdmission,
        uint8 phase,
        uint64 staged,
        uint64 frontier,
        uint32 revision,
        uint64 admissions,
        uint64 records,
        uint64 bindings,
        uint64 publications
    );

    error E_FINAL_PROBE(
        uint8 phase, uint64 staged, uint64 frontier, uint64 admissions, uint64 pubs
    );

    constructor(address ledger_) BaseIndexDouble(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        ILedgerHot h = ILedgerHot(msg.sender);
        (uint8 phase, uint64 staged, uint64 frontier, uint32 revision) = h.phase();
        (uint64 a, uint64 r, uint64 b, uint64 p) = h.counts();
        emit Probe(effects[0].admission, phase, staged, frontier, revision, a, r, b, p);
        return super.onAdmission(publication, effects, refs);
    }

    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) public view override returns (bytes4 ack) {
        ack = super.afterPublication(publication, effects, refs);
        (uint8 phase, uint64 staged, uint64 frontier,) = ILedgerHot(msg.sender).phase();
        (uint64 a,,, uint64 p) = ILedgerHot(msg.sender).counts();
        uint64 last = effects[effects.length - 1].admission;
        if (
            phase != Phase.FINAL || staged != publication || frontier != last || a != last
                || p != publication - 1
        ) revert E_FINAL_PROBE(phase, staged, frontier, a, p);
    }
}

/// @notice Every `ILedgerHot` getter (design §5.3) against the raw slots it reads, decoded through `Layout`,
///         after a publication of mixed kinds by two principals; `extsloadBatch` bounds; and the staged
///         frontier as seen from inside the callbacks.
contract HotReadsTest is KernelFixture {
    bytes32 internal sid;
    bytes32 internal rid1;
    bytes32 internal rid2;
    bytes32 internal rid3;
    bytes32 internal boundKey;
    bytes32 internal maskedKey;
    address internal alice;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        sid = _sid(principal, "hot/s");
        bytes memory b2 = new bytes(40);
        b2[39] = bytes1(0x7f);
        (rid1, rid2) = (_rid(TYPE_OK, "hot/1"), _rid(TYPE_OK2, b2));
        Action[] memory a = new Action[](6);
        (a[0], a[1], a[2]) = (_create("hot/s"), _publish(TYPE_OK, "hot/1"), _publish(TYPE_OK2, b2));
        (a[3], a[4], a[5]) =
        (
            _bind(FOLDER, sid, ROLE, rid1, 0),
            _bind(FOLDER, sid, 0, sid, 0),
            _unbind(FOLDER, sid, 0, 1)
        );
        bytes[] memory b = new bytes[](6);
        b[1] = "hot/1";
        b[2] = b2;
        _exec(a, b);
        rid3 = _rid(TYPE_OK, "hot/3");
        _execAs(alice, _acts(_publish(TYPE_OK, "hot/3")), _bodies(1, 0, "hot/3"));
        (boundKey, maskedKey) =
        (_key(principal, FOLDER, sid, ROLE), _key(principal, FOLDER, sid, 0));
    }

    function _realmWord(uint256 i) internal view returns (bytes32) {
        return _raw(uint256(Layout.LEDGER_REALM_ROOT) + i);
    }

    function _lockSlot() internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256("efs.ledger.v2.lock")) - 1))
            & ~bytes32(uint256(0xff));
    }

    function test_realm_getters_match_raw_storage() public view {
        (uint48 a, uint48 r, uint48 b, uint48 p) =
            Layout.unpackCountersStorage(_raw(uint256(Layout.LEDGER_COUNTERS_ROOT)));
        (uint64 ca, uint64 cr, uint64 cb, uint64 cp) = hot.counts();
        assertEq(abi.encode(ca, cr, cb, cp), abi.encode(a, r, b, p));
        assertEq(abi.encode(a, r, b, p), abi.encode(7, 3, 2, 2));
        (uint64 gen, uint64 acc, uint32 rev, uint8 frozen) =
            Layout.unpackRealmStorageWord3(_realmWord(3));
        (uint64 hg, uint64 ha, uint32 hr, bool hf) = hot.control();
        assertEq(abi.encode(hg, ha, hr, hf), abi.encode(gen, acc, rev, frozen != 0));
        assertEq(hot.revision(), rev);
        (uint8 phase, uint64 staged, uint64 frontier, uint32 prev) = hot.phase();
        assertEq(abi.encode(phase, staged, frontier, prev), abi.encode(Phase.IDLE, 0, 0, rev));
        assertEq(_lockSlot(), 0x6c6eb23cf3b383a5fb365ecd153e56a97a2ae1f01e555420253212131c40d200);
        assertEq(hot.exttload(_lockSlot()), 0, "the lock word is clear between publications");
        assertEq(hot.executionSet(), _realmWord(7));
        assertEq(hot.realmId(), _realmWord(0));
        assertEq(hot.realmOrigin(), _realmWord(1));
        assertEq(hot.layoutId(), _realmWord(8));
        assertEq(hot.layoutId(), Layout.LAYOUT_ID);
        (address controller,,,) = Layout.unpackRealmStorageWord4(_realmWord(4));
        assertEq(hot.controller(), controller);
        assertEq(hot.registry(), Layout.unpackRealmStorageWord5(_realmWord(5)));
        (address idx, uint32 generation) = Layout.unpackRealmStorageWord6(_realmWord(6));
        assertEq(abi.encode(hot.index(), hot.indexGeneration()), abi.encode(idx, generation));
        assertEq(hot.noticePrincipal(), _realmWord(17));
        assertEq(hot.readerDirectory(), Layout.unpackRealmStorageWord16(_realmWord(16)));
        assertEq(hot.ingress(), address(k.ingress), "the implementation immutable");
        assertEq(hot.applyDelegate(), address(k.applyDelegate), "the implementation immutable");
        assertEq(hot.hotAbiId(), KernelDeploy.HOT_ABI_ID);
        bytes32[] memory ids = hot.supportedHotAbiIds();
        assertEq(abi.encode(ids.length, ids[0]), abi.encode(1, KernelDeploy.HOT_ABI_ID));
    }

    function test_row_getters_match_raw_storage() public view {
        bytes32[2] memory principals = [principal, Keys.principal(alice)];
        for (uint256 i; i < 2; ++i) {
            (uint48 n, uint48 v) =
                Layout.unpackPrincipalRow(_raw(Layout.principalsRowsSlot(principals[i])));
            (uint64 hn, uint64 hv) = hot.nonceOf(principals[i]);
            assertEq(abi.encode(hn, hv), abi.encode(n, v));
        }
        (uint48 created,) = Layout.unpackSubjectCell(_raw(Layout.subjectsCellsSlot(sid)));
        assertEq(hot.subjectCreatedAt(sid), created);
        assertEq(created, 1);
        bytes32[3] memory keys = [boundKey, maskedKey, keccak256("hot/unset")];
        for (uint256 i; i < 3; ++i) {
            uint256 s = Layout.bindingsHeadsSlot(keys[i]);
            (uint8 st, uint48 rv, uint48 ad, uint8 tk, uint48 pa, uint48 bo,) =
                Layout.unpackHeadRowWord0(_raw(s));
            bytes32 canonical = st == 1 ? _raw(s + 1) : bytes32(0);
            (uint8 hs, uint64 hrv, uint64 had, uint8 htk, uint64 hpa, uint64 hbo, bytes32 ht) =
                hot.head(keys[i]);
            assertEq(
                abi.encode(hs, hrv, had, htk, hpa, hbo, ht),
                abi.encode(st, rv, ad, tk, pa, bo, canonical)
            );
        }
        assertEq(
            _raw(Layout.bindingsHeadsSlot(maskedKey) + 1), sid, "masked head keeps its raw target"
        );
        bytes32[4] memory records = [rid1, rid2, rid3, keccak256("hot/missing")];
        for (uint256 i; i < 4; ++i) {
            uint256 s = Layout.recordsCellsSlot(records[i]);
            (uint48 fa, uint32 len, uint48 occ, uint8 carrier) =
                Layout.unpackRecordCellWord1(_raw(s + 1));
            (bytes32 t, uint64 hfa, uint32 hlen, uint64 hocc, uint8 hc) =
                hot.recordHeader(records[i]);
            assertEq(abi.encode(t, hfa, hlen, hocc, hc), abi.encode(_raw(s), fa, len, occ, carrier));
        }
        (, uint64 fa2, uint32 len2,,) = hot.recordHeader(rid2);
        assertEq(abi.encode(fa2, len2), abi.encode(3, 40));
        for (uint256 slot; slot < 4; ++slot) {
            bytes32 s = bytes32(Layout.recordsCellsSlot(rid2) + slot);
            assertEq(hot.extsload(s), vm.load(k.proxy, s));
        }
    }

    function test_publicationAt_and_the_native_evidence_words() public view {
        (uint64 pub, bytes32 digest_) = hot.publicationAt(principal, 0);
        uint48 raw = uint48(uint256(_raw(Layout.publicationsPublicationAtSlot(principal, 0))));
        uint256 e = Layout.publicationsEvidenceSlot(pub);
        assertEq(abi.encode(pub, digest_), abi.encode(raw, _raw(e + 3)));
        (uint64 none, bytes32 noneDigest) = hot.publicationAt(principal, 1);
        assertEq(abi.encode(none, noneDigest), abi.encode(0, 0), "(0, 0) when none");
        (uint64 alicePub,) = hot.publicationAt(Keys.principal(alice), 0);
        assertEq(alicePub, 2);
        (
            address author,
            uint8 proofKind,
            uint8 principalKind,
            uint8 v,
            uint8 leaves,
            uint48 first,
            uint8 flags
        ) = Layout.unpackEvidenceCellWord0(_raw(e));
        assertEq(
            abi.encode(author, proofKind, principalKind, v, leaves, first, flags),
            abi.encode(address(this), 1, 2, 0, 6, 1, 0)
        );
        (uint48 nonce, uint64 deadline, uint48 basis, uint32 rev, uint16 profile) =
            Layout.unpackEvidenceCellWord1(_raw(e + 1));
        assertEq(
            abi.encode(nonce, deadline, basis, rev, profile), abi.encode(0, 0, block.number, 1, 0)
        );
        assertEq(_raw(e + 2), principal);
        for (uint256 w = 5; w < 13; ++w) {
            assertEq(_raw(e + w), 0, "native rows write w0..w4 only");
        }
    }

    function test_extsloadBatch_256_and_257() public {
        bytes32[] memory slots = new bytes32[](256);
        for (uint256 i; i < 256; ++i) {
            slots[i] = bytes32(uint256(Layout.LEDGER_REALM_ROOT) + (i % 18) + (i / 18) * 2 ** 32);
        }
        slots[255] = Layout.LEDGER_COUNTERS_ROOT;
        bytes32[] memory out = hot.extsloadBatch(slots);
        assertEq(out.length, 256);
        for (uint256 i; i < 256; ++i) {
            assertEq(out[i], vm.load(k.proxy, slots[i]));
        }
        assertEq(hot.extsloadBatch(new bytes32[](0)).length, 0);
        vm.expectRevert(abi.encodeWithSelector(E_RESERVED.selector, uint8(30), uint256(257)));
        hot.extsloadBatch(new bytes32[](257));
    }

    function test_viewMutationVersion_moves_only_with_bind_kinds() public {
        bytes32 p = Keys.principal(alice);
        (uint64 n, uint64 v) = hot.nonceOf(p);
        assertEq(abi.encode(n, v), abi.encode(1, 0));
        _execAs(alice, _acts(_create("hot/a")), _bodies(1));
        (n, v) = hot.nonceOf(p);
        assertEq(abi.encode(n, v), abi.encode(2, 0));
        _execAs(alice, _acts(_bind(FOLDER, "x", ROLE, rid3, 0), _create("hot/b")), _bodies(2));
        (n, v) = hot.nonceOf(p);
        assertEq(abi.encode(n, v), abi.encode(3, 1));
        _execAs(alice, _acts(_unbind(FOLDER, "x", ROLE, 1)), _bodies(1));
        (n, v) = hot.nonceOf(p);
        assertEq(abi.encode(n, v), abi.encode(4, 2));
    }

    // DESIGN-DIVERGENCE: §6.4 says the staged frontier is visible through counts()/phase(); counts() shows it,
    // but phase().admissionFrontier stays at the pre-publication frontier through APPLYING (the lock word is
    // packed once in _begin, src/core/LedgerCore.sol:367-371, and again only in _final) and equals the staged
    // frontier only in FINAL.
    function test_counts_and_phase_inside_callbacks_show_the_staged_frontier() public {
        _useIndex(address(new ProbeIndex(k.proxy)));
        (uint64 base, uint64 records, uint64 bindings, uint64 pubs) = _counts();
        bytes32 r = _rid(TYPE_OK, "hot/probe");
        vm.recordLogs();
        _exec(
            _acts(
                _create("hot/probe"), _publish(TYPE_OK, "hot/probe"), _bind(FOLDER, "p", ROLE, r, 0)
            ),
            _bodies(3, 1, "hot/probe")
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != index || logs[i].topics[0] != ProbeIndex.Probe.selector) {
                continue;
            }
            (
                uint64 adm,
                uint8 ph,
                uint64 st,
                uint64 fr,
                uint32 rev,
                uint64 a,
                uint64 rc,
                uint64 bc,
                uint64 pc
            ) = abi.decode(
                logs[i].data,
                (uint64, uint8, uint64, uint64, uint32, uint64, uint64, uint64, uint64)
            );
            assertEq(
                abi.encode(adm, ph, st, rev),
                abi.encode(base + 1 + seen, Phase.APPLYING, pubs + 1, hot.revision())
            );
            assertEq(a, adm, "counts().admissions is the staged frontier");
            assertEq(
                abi.encode(rc, bc, pc),
                abi.encode(records + (seen >= 1 ? 1 : 0), bindings + (seen >= 2 ? 1 : 0), pubs)
            );
            assertEq(
                fr, base, "phase().admissionFrontier is the pre-publication frontier while APPLYING"
            );
            ++seen;
        }
        assertEq(seen, 3);
    }
}
