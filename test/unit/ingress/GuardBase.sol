// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action, Capability, Intent, ReadSet} from "../../../src/interfaces/Actions.sol";
import {Evidence} from "../../../src/interfaces/Views.sol";
import {Status} from "../../../src/interfaces/Results.sol";
import {LedgerReads} from "../../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../../src/readers/LedgerViews.sol";
import {E_READSET_STALE} from "../../../src/interfaces/Errors.sol";

/// @notice The read-set guard suites' fixture (capability b0 `NATIVE_GUARD`, design §5.1): the kernel fixture
///         activated with b0 and b1 (`SIGNED_SECP256K1`), two TYPE_OK records A and B to bind, raw head reads
///         through `extsload`, read-set builders, a guarded native call, a guarded refusal that changes no state
///         (`KernelFixture._assertUnchanged`) and a signed-lane intent signed by `PK`.
/// @dev Expected snapshot hashes are always built from values the test knows (raw head words it just read,
///      or the values the last transition wrote), never copied from `LedgerViews.headSnapshots`, except where
///      a test checks that view against the raw words.
abstract contract GuardBase is KernelFixture {
    bytes32 internal constant SUBJECT = keccak256("guard/subject/0");
    bytes32 internal constant SUBJECT2 = keccak256("guard/subject/1");
    uint256 internal constant PK = 0x6A4D;

    bytes32 internal recA;
    bytes32 internal recB;
    bytes32 internal pos; // (FOLDER, SUBJECT, ROLE)
    bytes32 internal pos2; // (FOLDER, SUBJECT2, ROLE)
    address internal alice;
    bytes32 internal pAlice;
    address internal signer;
    bytes32 internal pSigner;
    LedgerReads internal reads;
    LedgerViews internal views;
    uint256 internal saltCounter;

    /// A head as stored: word 0 unpacked, and word +1 raw.
    struct Raw {
        uint8 state;
        uint48 revision;
        uint48 admission;
        uint8 targetKind;
        bytes32 word;
    }

    function _capabilities() internal pure virtual override returns (uint16) {
        return Capability.NATIVE_GUARD | Capability.SIGNED_SECP256K1;
    }

    function setUp() public virtual override {
        super.setUp();
        bytes[] memory b = new bytes[](2);
        (b[0], b[1]) = (bytes("guard/a"), bytes("guard/b"));
        _exec(_acts(_publish(TYPE_OK, b[0]), _publish(TYPE_OK, b[1])), b);
        recA = _rid(TYPE_OK, b[0]);
        recB = _rid(TYPE_OK, b[1]);
        pos = Keys.position(FOLDER, SUBJECT, ROLE);
        pos2 = Keys.position(FOLDER, SUBJECT2, ROLE);
        alice = makeAddr("guard/alice");
        pAlice = Keys.principal(alice);
        signer = vm.addr(PK);
        pSigner = Keys.principal(signer);
        reads = new LedgerReads();
        views = new LedgerViews();
    }

    // ---- raw heads ------------------------------------------------------------------------------------------

    function _rawHead(bytes32 p, bytes32 position) internal view returns (Raw memory h) {
        uint256 s = Layout.bindingsHeadsSlot(Keys.binding(p, position));
        (h.state, h.revision, h.admission, h.targetKind,,,,) =
            Layout.unpackHeadRowWord0(hot.extsload(bytes32(s)));
        h.word = hot.extsload(bytes32(s + 1));
    }

    function _snap(uint8 state, uint64 revision, uint64 admission, bytes32 target)
        internal
        view
        returns (bytes32)
    {
        return commitments.headSnapshotHash(state, revision, admission, target);
    }

    /// The hash of `h` with its target replaced by `target`.
    function _snapWith(Raw memory h, bytes32 target) internal view returns (bytes32) {
        return _snap(h.state, h.revision, h.admission, target);
    }

    // ---- read sets ------------------------------------------------------------------------------------------

    function _one(bytes32 v) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = v;
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        (l[0], l[1]) = (a, b);
    }

    function _rs(bytes32[] memory principals, bytes32[] memory positions, bytes32[] memory heads)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ReadSet(principals, positions, heads));
    }

    /// A one-entry guard over (p, position) expecting `expected`.
    function _guard1(bytes32 p, bytes32 position, bytes32 expected)
        internal
        pure
        returns (bytes memory)
    {
        return _rs(_one(p), _one(position), _one(expected));
    }

    function _stale(bytes32 position, bytes32 p) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_READSET_STALE.selector, position, p);
    }

    // ---- execution ------------------------------------------------------------------------------------------

    /// A CREATE leaf with a fresh salt: an action that touches no head.
    function _touchNothing() internal returns (Action[] memory) {
        return _acts(_create(keccak256(abi.encode("guard/salt", ++saltCounter))));
    }

    function _execG(Action[] memory a, bytes[] memory b, bytes memory guard)
        internal
        returns (uint64 publication)
    {
        _track(principal, a);
        (publication,) = ledger.execute(a, b, _native(_nonce(principal)), guard);
    }

    /// The guarded call reverts exactly `err` and leaves `digest()` and the lock unchanged.
    function _refuseG(Action[] memory a, bytes[] memory b, bytes memory guard, bytes memory err)
        internal
    {
        _track(principal, a);
        bytes32 before = digest();
        uint64 n = _nonce(principal);
        vm.expectRevert(err);
        ledger.execute(a, b, _native(n), guard);
        _assertUnchanged(before);
    }

    function _evidence(uint64 publication) internal view returns (Evidence memory e) {
        Status st;
        (st, e) = reads.evidence(k.proxy, publication);
        assertEq(uint8(st), uint8(Status.PRESENT), "evidence present");
    }

    function _nextPublication() internal view returns (uint64) {
        (,,, uint64 p) = hot.counts();
        return p + 1;
    }

    // ---- the signed lane ------------------------------------------------------------------------------------

    /// An intent for `actions` by `signer` at its next nonce, binding `readSetHash`, and its 65-byte witness.
    function _signed(Action[] memory actions, bytes32 readSetHash)
        internal
        view
        returns (Intent memory it, bytes memory witness)
    {
        it.realmId = hot.realmId();
        it.realmOrigin = hot.realmOrigin();
        it.executionSet = hot.executionSet();
        it.principalId = pSigner;
        it.author = signer;
        it.nonce = _nonce(pSigner);
        it.deadline = uint64(block.timestamp + 1 days);
        it.acceptanceProfile = commitments.acceptanceProfileOf(k.proxy, actions);
        it.indexObligations = commitments.indexObligationsOf(k.proxy);
        it.readSetHash = readSetHash;
        it.verifierProfile = 1;
        witness = _sign(it, actions);
    }

    function _sign(Intent memory it, Action[] memory actions) internal view returns (bytes memory) {
        bytes32 domain = hot.extsload(bytes32(Layout.LEDGER_REALM_DOMAINSEPARATOR_SLOT));
        bytes32 d = commitments.signingDigest(domain, it, keccak256(abi.encode(actions)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, d);
        return abi.encodePacked(r, s, v);
    }
}
