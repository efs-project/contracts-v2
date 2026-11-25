// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FacetFixture} from "./Facets.t.sol";
import {RevertingEverything} from "./FacetDoubles.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {BasisCommit, History, Status} from "../../src/interfaces/Results.sol";
import {
    AcceptanceBasis,
    AdmissionRow,
    Evidence,
    Head,
    PublicationView,
    RecordHeader,
    Revision
} from "../../src/interfaces/Views.sol";
import {E_LAYOUT} from "../../src/interfaces/Errors.sol";

/// @notice Test-only non-ledger: every call succeeds with no return data (a short `layoutId()` reply).
contract SilentEverything {
    fallback() external payable {}
}

/// @notice The three-way facet gate (design §5.7, adoption note 26): no code at the ledger address is UNKNOWN
///         with every value zero (absence is never a fault), code that is not a ledger is UNSUPPORTED, and the
///         status-less views refuse with `E_LAYOUT(LAYOUT_ID, 0)`. The client scenario: a facet deployed before
///         the ledger proxy is asked about the proxy's address first while it has no code, then after genesis.
contract NoLedgerTest is FacetFixture {
    LedgerReads internal early;
    address internal predicted;
    Status internal earlyStatus;
    uint64 internal earlyPublication;
    bytes32 internal earlyDigest;

    function _deployKernel(address registry_)
        internal
        override
        returns (KernelDeploy.Kernel memory)
    {
        return KernelDeploy.deploy(address(this), registry_, SALT);
    }

    /// The facet goes first (as in genesis); the proxy will be this contract's 5th creation after the
    /// registry double (`FacetRegistry`, then ingress, apply, control, core, proxy).
    function setUp() public override {
        early = new LedgerReads();
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        assertEq(predicted.code.length, 0, "no ledger yet");
        (earlyStatus, earlyPublication, earlyDigest) =
            early.publicationAt(predicted, keccak256("efs/test/no-ledger/any-principal"), 0);
        super.setUp();
    }

    // ---- the client scenario ---------------------------------------------------------------------------

    function testPublicationAtBeforeAndAfterTheLedgerExists() public view {
        assertEq(k.proxy, predicted, "the proxy landed at the address read before it existed");
        _st(earlyStatus, Status.UNKNOWN, "before genesis");
        assertEq(earlyPublication, 0);
        assertEq(earlyDigest, 0);
        (Status st, uint64 publication, bytes32 digest) = early.publicationAt(k.proxy, p1, 0);
        _st(st, Status.PRESENT, "after genesis");
        assertEq(publication, 1);
        (uint64 hotPublication, bytes32 hotDigest) = hot.publicationAt(p1, 0);
        assertEq(publication, hotPublication);
        assertEq(digest, hotDigest);
        (st,,) = early.publicationAt(k.proxy, p3, 0);
        _st(st, Status.ABSENT_PROVEN, "a principal that never published");
    }

    // ---- no code → UNKNOWN, a non-ledger → UNSUPPORTED -----------------------------------------------------

    function testNoCodeIsUnknownWithZeroValues() public {
        _allStatusViews(makeAddr("no-ledger-here"), Status.UNKNOWN);
        _allStatusViews(address(0), Status.UNKNOWN);
    }

    function testNonLedgerCodeIsUnsupported() public {
        _allStatusViews(address(new RevertingEverything()), Status.UNSUPPORTED);
        _allStatusViews(address(new SilentEverything()), Status.UNSUPPORTED);
    }

    function testPublicationAtWithoutALedgerIsUnknown() public {
        (Status st, uint64 publication, bytes32 digest) =
            reads.publicationAt(makeAddr("no-ledger-here"), p1, 0);
        _st(st, Status.UNKNOWN, "publicationAt");
        assertEq(publication, 0);
        assertEq(digest, 0);
    }

    function testARealLedgerStillAnswers() public view {
        (Status st, RecordHeader memory h) = reads.recordHeader(k.proxy, r1);
        _st(st, Status.PRESENT, "recordHeader");
        assertEq(h.typeId, TYPE_OK);
        (st,) = reads.revisionAt(k.proxy, 1);
        _st(st, Status.PRESENT, "revisionAt");
        (st,) = views.publication(k.proxy, p1, 0);
        _st(st, Status.PRESENT, "publication");
        (History hs,) = views.historyAt(k.proxy, Keys.binding(p1, posName), 3, 8);
        assertEq(uint8(hs), uint8(History.FOUND), "historyAt");
        assertEq(reads.basis(k.proxy).executionSet, hot.executionSet(), "basis");
    }

    // ---- the status-less views refuse with E_LAYOUT(expected, 0) ----------------------------------------

    function testStatuslessViewsRefuseWithoutALedger() public {
        _refuses(makeAddr("no-ledger-here"));
        _refuses(address(0));
    }

    function testStatuslessViewsRefuseANonLedger() public {
        _refuses(address(new RevertingEverything()));
        _refuses(address(new SilentEverything()));
    }

    // ---- helpers -------------------------------------------------------------------------------------------

    /// Every `Status`-returning view of both facets (and `historyAt`) against `l`: status `want`, every other
    /// value zero or empty.
    function _allStatusViews(address l, Status want) internal view {
        bytes32 key = Keys.binding(p1, posName);

        (Status st, Revision memory rev) = reads.revisionAt(l, 1);
        _st(st, want, "revisionAt");
        _zeroRevision(rev);

        RecordHeader memory h;
        bytes memory body;
        BasisCommit memory b;
        (st, h, body, b) = reads.record(l, r1);
        _st(st, want, "record");
        _zeroHeader(h, "record");
        assertEq(body.length, 0, "record body");
        _zeroBasis(b, "record");

        (st, h) = reads.recordHeader(l, r1);
        _st(st, want, "recordHeader");
        _zeroHeader(h, "recordHeader");

        bytes32[] memory words;
        (st, words) = reads.bodyWords(l, r1, 0, 1);
        _st(st, want, "bodyWords");
        assertEq(words.length, 0, "bodyWords");

        (st, body) = reads.bodySlice(l, r1, 0, 1);
        _st(st, want, "bodySlice");
        assertEq(body.length, 0, "bodySlice");

        uint64 createdAt;
        bytes32 creator;
        (st, createdAt, creator) = reads.subjectInfo(l, s1);
        _st(st, want, "subjectInfo");
        assertEq(createdAt, 0);
        assertEq(creator, 0);

        Head memory hd;
        (st, hd) = reads.head(l, key);
        _st(st, want, "head");
        _zeroHead(hd, "head");

        bytes32 purpose;
        bytes32 subject;
        bytes32 role;
        (st, purpose, subject, role) = reads.positionCell(l, posName);
        _st(st, want, "positionCell");
        assertEq(purpose, 0);
        assertEq(subject, 0);
        assertEq(role, 0);

        bytes32 position;
        (st, position) = reads.bindingPosition(l, 1);
        _st(st, want, "bindingPosition");
        assertEq(position, 0);

        AdmissionRow memory ar;
        (st, ar) = reads.admission(l, 1);
        _st(st, want, "admission");
        AdmissionRow memory zar;
        _zero(abi.encode(ar), abi.encode(zar), "admission");

        Evidence memory e;
        (st, e) = reads.evidence(l, 1);
        _st(st, want, "evidence");
        Evidence memory ze;
        _zero(abi.encode(e), abi.encode(ze), "evidence");

        if (want == Status.UNKNOWN) {
            (Status pst, uint64 publication, bytes32 digest) = reads.publicationAt(l, p1, 0);
            _st(pst, Status.UNKNOWN, "publicationAt");
            assertEq(publication, 0);
            assertEq(digest, 0);
        }

        PublicationView memory pv;
        (st, pv) = views.publication(l, p1, 0);
        _st(st, want, "publication");
        PublicationView memory zpv;
        _zero(abi.encode(pv), abi.encode(zpv), "publication");

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = r1;
        ids[1] = r2;
        Status[] memory sts;
        RecordHeader[] memory hs;
        (sts, hs, b) = views.records(l, ids);
        assertEq(sts.length, 2, "records");
        _st(sts[0], want, "records[0]");
        _st(sts[1], want, "records[1]");
        _zeroHeader(hs[0], "records[0]");
        _zeroHeader(hs[1], "records[1]");
        _zeroBasis(b, "records");

        bytes32[] memory order = new bytes32[](2);
        order[0] = p2;
        order[1] = p1;
        Head memory selected;
        uint8 idx;
        Head[] memory all;
        (st, selected, idx, all, b) = views.headsAt(l, order, posName);
        _st(st, want, "headsAt");
        _zeroHead(selected, "headsAt");
        assertEq(idx, type(uint8).max, "headsAt selectedIndex is none");
        assertEq(all.length, 0, "headsAt all");
        _zeroBasis(b, "headsAt");

        AcceptanceBasis memory ab;
        (st, ab) = views.acceptanceBasis(l, 2);
        _st(st, want, "acceptanceBasis");
        AcceptanceBasis memory zab;
        _zero(abi.encode(ab), abi.encode(zab), "acceptanceBasis");

        History hist;
        (hist, hd) = views.historyAt(l, key, 20, 8);
        assertEq(uint8(hist), uint8(History.UNKNOWN), "historyAt");
        _zeroHead(hd, "historyAt");
    }

    function _refuses(address l) internal {
        bytes memory refusal =
            abi.encodeWithSelector(E_LAYOUT.selector, Layout.LAYOUT_ID, bytes32(0));
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = Keys.binding(p1, posName);
        bytes32[] memory principals = new bytes32[](1);
        principals[0] = p1;
        bytes32[] memory positions = new bytes32[](1);
        positions[0] = posName;
        vm.expectRevert(refusal);
        reads.describe(l);
        vm.expectRevert(refusal);
        reads.basis(l);
        vm.expectRevert(refusal);
        reads.admissions(l, 1, 1);
        vm.expectRevert(refusal);
        reads.principalsOf(l, accounts);
        vm.expectRevert(refusal);
        views.heads(l, keys);
        vm.expectRevert(refusal);
        views.headStates(l, keys);
        vm.expectRevert(refusal);
        views.headSnapshots(l, principals, positions);
    }

    function _zero(bytes memory have, bytes memory want, string memory m) internal pure {
        assertEq(keccak256(have), keccak256(want), m);
    }

    function _zeroRevision(Revision memory r) internal pure {
        Revision memory z;
        _zero(abi.encode(r), abi.encode(z), "revisionAt");
    }

    function _zeroHeader(RecordHeader memory h, string memory m) internal pure {
        RecordHeader memory z;
        _zero(abi.encode(h), abi.encode(z), m);
    }

    function _zeroHead(Head memory h, string memory m) internal pure {
        Head memory z;
        _zero(abi.encode(h), abi.encode(z), m);
    }

    function _zeroBasis(BasisCommit memory b, string memory m) internal pure {
        BasisCommit memory z;
        _zero(abi.encode(b), abi.encode(z), m);
    }
}
