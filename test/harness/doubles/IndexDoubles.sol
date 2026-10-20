// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRealmIndex} from "../../../src/interfaces/IRealmIndex.sol";
import {IIndexReads} from "../../../src/interfaces/IIndexReads.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    ScopeKey,
    TypeId
} from "../../../src/interfaces/Actions.sol";
import {
    DigestSpec,
    Effect,
    FamilyEntry,
    Readiness,
    Unit,
    WorkModel
} from "../../../src/interfaces/Index.sol";
import {Coverage, Phase} from "../../../src/interfaces/Results.sol";
import {
    E_LEDGER,
    E_ORDER,
    E_PUBLICATION_ACTIVE,
    E_STAGED
} from "../../../src/interfaces/Errors.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {MockCaller, MockRegistry, MockUnsupported} from "./MockRegistry.sol";

// Index-generation doubles (design §5.11, §6.4–§6.5, §10.3; §2.2 S1/S4). The kernel dispatches one
// `onAdmission(publication, Effect[1], refsSlice)` per leaf by CALL from ledger context and one
// `afterPublication(publication, Effect[n], refs)` by STATICCALL in phase FINAL, and accepts only the exact
// 32-byte selector acknowledgement. The ten behaviours of §16 are below; each is the prototype's double
// (`lab-b/test/CoreOrderedAcceptance.t.sol`, `MatchedRollback.t.sol`) ported to Effect/3 and IAcceptor/2-era
// ABIs. Constructors never read the ledger; they take its address.

// keccak("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs") (design §5.11).
bytes32 constant CALLBACK_PROFILE_3 =
    keccak256("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs");

/// The initial work-model coefficients of design §10.4, slot counts ×10 as the design stores them.
library IndexDoubleDefaults {
    function workModel() internal pure returns (WorkModel memory w) {
        w.formulaVersion = 1;
        w.freshPerPublication = 2; // 0.2 (progress)
        w.rwPerPublication = 10; // 1
        w.freshPerPublishFresh = 10; // 1
        w.rwPerPublish = 50; // 5
        w.freshPerBindFresh = 30; // 3
        w.rwPerBind = 40; // 4
        w.freshPerRef = 10; // 1
        w.freshPerDigestSpec = 10; // 1
        w.computeBase = 60_000;
        w.computePerAction = 25_000;
        w.computePerHookEffect = 60_000;
        w.finalComputeBase = 60_000;
        w.finalComputePerBind = 120_000;
    }
}

/// @notice The shared state of every index double: a compact record of the prefix calls, the `IIndexReads`
///         surface with settable answers, and a settable readiness tuple. No postings are maintained; every
///         posting read answers `UNKNOWN`, never an empty `COMPLETE`.
/// @dev The prefix record is two slots (counters packed, plus a hash chain over every call's arguments) so
///      a double stays cheap under both gas schedules. Setters are owner-only (the deployer), so a callback
///      cannot reconfigure its own index mid-publication.
abstract contract IndexDoubleCore is IIndexReads {
    /// One configured coverage reply.
    struct CoverageAnswer {
        Coverage status;
        uint64 fromAdmission;
        uint64 throughAdmission;
        uint8 phase;
    }

    address public immutable owner = msg.sender;

    address public ledger;
    bytes32 public manifestHash = keccak256("efs2/test/index-double/1");
    bytes32 public physicalProfile;
    uint64 public provenFrom = 1;
    address public postingStore;
    address public bitmapStore;
    address public buildDelegate;
    WorkModel internal _work;
    bytes internal _readiness; // abi.encode(Readiness); empty = derived from this double's own state
    CoverageAnswer internal _defaultCoverage;
    mapping(bytes32 => CoverageAnswer) internal _coverage; // keyed by keccak256 of the full query calldata
    mapping(bytes32 => bool) internal _coverageSet;

    // The prefix record (one slot), then the hash chain.
    uint64 public prefixCalls;
    uint64 public lastPublication;
    uint64 public lastProcessed; // the admission of the last effect received
    uint32 public effectsSeen;
    uint32 public refsSeen;
    /// keccak256(abi.encode(previous, publication, effects, refs)) over every prefix call, in order.
    bytes32 public prefixDigest;

    modifier onlyOwner() {
        if (msg.sender != owner) revert MockCaller(msg.sender);
        _;
    }

    constructor(address ledger_) {
        ledger = ledger_;
        _work = IndexDoubleDefaults.workModel();
        _defaultCoverage.status = Coverage.UNKNOWN;
    }

    // ---- test setters -----------------------------------------------------------------------------------

    function setLedger(address ledger_) external onlyOwner {
        ledger = ledger_;
    }

    function setManifestHash(bytes32 h) external onlyOwner {
        manifestHash = h;
    }

    function setPhysicalProfile(bytes32 p) external onlyOwner {
        physicalProfile = p;
    }

    function setProvenFrom(uint64 from) external onlyOwner {
        provenFrom = from;
    }

    function setWorkModel(WorkModel memory w) external onlyOwner {
        _work = w;
    }

    function setStores(address posting, address bitmap, address build_) external onlyOwner {
        postingStore = posting;
        bitmapStore = bitmap;
        buildDelegate = build_;
    }

    /// Starts the contiguity record after existing history (an index attached to a populated Realm).
    function setProgress(uint64 processed, uint64 publication) external onlyOwner {
        lastProcessed = processed;
        lastPublication = publication;
    }

    function setReadiness(Readiness memory r) external onlyOwner {
        _readiness = abi.encode(r);
    }

    /// The reply of every coverage query without its own answer (initially UNKNOWN, 0, 0, 0).
    function setDefaultCoverage(CoverageAnswer memory a) external onlyOwner {
        _defaultCoverage = a;
    }

    /// The reply to one exact query, e.g. `abi.encodeCall(IIndexReads.coverage, (family, scope))`; works
    /// for `coverage`, `coverageOfType`, `coverageOfSpec` and `coverageOfDigest`.
    function setCoverage(bytes calldata query, CoverageAnswer memory a) external onlyOwner {
        bytes32 k = keccak256(query);
        _coverage[k] = a;
        _coverageSet[k] = true;
    }

    // ---- IIndexReads ----------------------------------------------------------------------------------------

    function manifest()
        external
        view
        returns (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physical,
            bytes32 callbackProfile
        )
    {
        Readiness memory r = _replayReadiness();
        return (header, r.families, r.units, specs, _work, r.physicalProfile, r.callbackProfile);
    }

    function workModel() external view returns (WorkModel memory) {
        return _work;
    }

    function coverage(FamilyId, ScopeKey) external view returns (Coverage, uint64, uint64, uint8) {
        return _answer();
    }

    function coverageOfType(FamilyId, TypeId)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        return _answer();
    }

    function coverageOfSpec(FamilyId, TypeId, uint8)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        return _answer();
    }

    function coverageOfDigest(uint8) external view returns (Coverage, uint64, uint64, uint8) {
        return _answer();
    }

    function progress()
        external
        view
        returns (uint64 lastProcessed_, uint64 lastPublication_, bool gapped)
    {
        return (lastProcessed, lastPublication, false);
    }

    function postingHeadOf(FamilyId, TypeId, uint8, bytes32)
        external
        pure
        returns (Coverage, uint64 count, uint64 live, uint64 last, bool synthesized)
    {
        return (Coverage.UNKNOWN, count, live, last, synthesized);
    }

    function postingSliceOf(FamilyId, TypeId, uint8, bytes32, uint64, uint16)
        external
        pure
        returns (Coverage, uint64[] memory entries, bool synthesized)
    {
        return (Coverage.UNKNOWN, entries, synthesized);
    }

    function occurrencesOf(bytes32)
        external
        pure
        returns (Coverage, uint64 count, uint64 live, uint64[] memory entries)
    {
        return (Coverage.UNKNOWN, count, live, entries);
    }

    // ---- shared internals -----------------------------------------------------------------------------------

    function _requireLedger() internal view {
        if (msg.sender != ledger) revert E_LEDGER();
    }

    function _recordPrefix(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        internal
    {
        _requireLedger();
        prefixCalls += 1;
        lastPublication = publication;
        if (effects.length != 0) lastProcessed = effects[effects.length - 1].admission;
        effectsSeen += uint32(effects.length);
        refsSeen += uint32(refs.length);
        prefixDigest = keccak256(abi.encode(prefixDigest, publication, effects, refs));
    }

    function _replayReadiness() internal view returns (Readiness memory r) {
        if (_readiness.length != 0) return abi.decode(_readiness, (Readiness));
        r.version = 1;
        r.ledger = ledger;
        r.physicalProfile = physicalProfile;
        r.callbackProfile = CALLBACK_PROFILE_3;
        r.manifestHash = manifestHash;
        r.provenFrom = provenFrom;
        r.completedAdmission = lastProcessed;
        r.completedPublication = lastPublication;
        r.build = buildDelegate;
        r.buildCodehash = buildDelegate == address(0) ? bytes32(0) : buildDelegate.codehash;
    }

    function _answer() internal view returns (Coverage, uint64, uint64, uint8) {
        bytes32 k = keccak256(msg.data);
        CoverageAnswer storage a = _coverageSet[k] ? _coverage[k] : _defaultCoverage;
        return (a.status, a.fromAdmission, a.throughAdmission, a.phase);
    }
}

/// @notice The honest base: records each prefix call and acknowledges both phases with the exact selector.
///         The build entry points are not modelled (`MockUnsupported`).
abstract contract BaseIndexDouble is IndexDoubleCore, IRealmIndex {
    constructor(address ledger_) IndexDoubleCore(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        virtual
        returns (bytes4)
    {
        _recordPrefix(publication, effects, refs);
        return IRealmIndex.onAdmission.selector;
    }

    function afterPublication(uint64, Effect[] calldata, bytes32[] calldata)
        public
        view
        virtual
        returns (bytes4)
    {
        _requireLedger();
        return IRealmIndex.afterPublication.selector;
    }

    function replayReadiness() external view returns (Readiness memory) {
        return _replayReadiness();
    }

    function replayNextPublication(uint16) external pure returns (uint64) {
        revert MockUnsupported(IRealmIndex.replayNextPublication.selector);
    }

    function build(bytes32, uint16) external pure returns (uint64) {
        revert MockUnsupported(IRealmIndex.build.selector);
    }

    function backfill(bytes32, ScopeKey, uint64, uint16) external pure returns (uint64) {
        revert MockUnsupported(IRealmIndex.backfill.selector);
    }
}

/// @notice 1 — the honest index of `CoreOrderedAcceptance::PrefixAgreementIndex`: before acknowledging, each
///         prefix call must agree with the ledger's staged state through the Etched hot reads — phase
///         APPLYING, `publication == stagedPublication` (`E_STAGED`), effects contiguous with the last one
///         seen (`E_ORDER`), the staged frontier `counts().admissions` equal to the last effect's admission,
///         and each effect's row visible (record header Type and occurrences, head state/revision/admission/
///         ordinal/target, subject creation admission). A divergence reverts `E_PREFIX_DIVERGED(code, admission)`.
contract PrefixAgreement is BaseIndexDouble {
    error E_PREFIX_DIVERGED(uint8 code, uint64 admission);

    constructor(address ledger_) BaseIndexDouble(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        ILedgerHot hot = ILedgerHot(ledger);
        (uint8 phase, uint64 staged,,) = hot.phase();
        if (phase != Phase.APPLYING) revert E_PREFIX_DIVERGED(1, 0);
        if (publication != staged) revert E_STAGED(staged, publication);
        uint64 expected = lastProcessed + 1;
        for (uint256 i; i < effects.length; ++i) {
            Effect calldata e = effects[i];
            if (e.admission != expected) revert E_ORDER(expected, e.admission);
            if (e.publication != publication) revert E_STAGED(publication, e.publication);
            _agree(hot, e);
            ++expected;
        }
        (uint64 admissions,,,) = hot.counts();
        if (admissions != expected - 1) revert E_PREFIX_DIVERGED(2, admissions);
        return super.onAdmission(publication, effects, refs);
    }

    function _agree(ILedgerHot hot, Effect calldata e) internal view {
        uint8 kind = e.kind;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            (bytes32 typeId, uint64 first,, uint64 occurrences,) = hot.recordHeader(e.recordId);
            if (typeId != e.typeId || first == 0 || occurrences == 0) {
                revert E_PREFIX_DIVERGED(3, e.admission);
            }
            if (e.freshRecord && first != e.admission) revert E_PREFIX_DIVERGED(3, e.admission);
        } else if (
            kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE
        ) {
            (uint8 state, uint64 revision, uint64 admission,,, uint64 ordinal, bytes32 target) =
                hot.head(Keys.binding(e.principalId, e.position));
            uint8 want = kind == ActionKind.BIND ? 1 : kind == ActionKind.UNBIND ? 2 : 3;
            if (
                state != want || revision != e.revision || admission != e.admission
                    || ordinal != e.bindingOrdinal || target != (want == 1 ? e.target : bytes32(0))
            ) revert E_PREFIX_DIVERGED(4, e.admission);
        } else if (kind == ActionKind.CREATE) {
            if (hot.subjectCreatedAt(e.subjectId) != e.admission) {
                revert E_PREFIX_DIVERGED(5, e.admission);
            }
        } else if (kind == ActionKind.WITHDRAW) {
            (bytes32 typeId,,,,) = hot.recordHeader(e.recordId);
            if (typeId != e.typeId) revert E_PREFIX_DIVERGED(6, e.admission);
        }
    }
}

/// @notice 2 — `PhaseRefusingIndex`: every prefix call must observe phase APPLYING and the final call phase
///         FINAL, read from `ILedgerHot(msg.sender).phase()` (else `E_PHASE(expected, observed)`), so a passing
///         publication proves the kernel set the phase before each callback (§6.4–§6.5). It can also refuse
///         the prefix call whose effect has admission `REFUSE_PREFIX_AT` (`E_PREFIX`) or every final call
///         (`E_FINAL`): the prototype's prefix and final rollback controls.
contract PhaseRefusing is BaseIndexDouble {
    error E_PREFIX(uint64 admission);
    error E_FINAL();
    error E_PHASE(uint8 expected, uint8 observed);

    uint64 public immutable REFUSE_PREFIX_AT; // 0 = never
    bool public immutable REFUSE_FINAL;

    constructor(address ledger_, uint64 refusePrefixAt, bool refuseFinal) BaseIndexDouble(ledger_) {
        REFUSE_PREFIX_AT = refusePrefixAt;
        REFUSE_FINAL = refuseFinal;
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        (uint8 phase,,,) = ILedgerHot(msg.sender).phase();
        if (phase != Phase.APPLYING) revert E_PHASE(Phase.APPLYING, phase);
        uint256 n = effects.length;
        if (REFUSE_PREFIX_AT != 0 && n != 0 && effects[n - 1].admission == REFUSE_PREFIX_AT) {
            revert E_PREFIX(REFUSE_PREFIX_AT);
        }
        return super.onAdmission(publication, effects, refs);
    }

    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) public view override returns (bytes4 ack) {
        ack = super.afterPublication(publication, effects, refs);
        (uint8 phase,,,) = ILedgerHot(msg.sender).phase();
        if (phase != Phase.FINAL) revert E_PHASE(Phase.FINAL, phase);
        if (REFUSE_FINAL) revert E_FINAL();
    }
}

/// @notice 3 — `LegacyFallbackIndex`: a pre-final-phase module. It acknowledges prefix calls and serves the
///         reads and readiness, but has no `afterPublication`; its permissive fallback answers every unknown
///         selector with 32 zero bytes, which the exact-ack law must refuse (`E_INDEX_ACK`/`E_INDEX_FINAL`).
/// @dev Not a `BaseIndexDouble`: inheriting `IRealmIndex` would give it the very selector it lacks.
contract LegacyFallback is IndexDoubleCore {
    constructor(address ledger_) IndexDoubleCore(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (bytes4)
    {
        _recordPrefix(publication, effects, refs);
        return IRealmIndex.onAdmission.selector;
    }

    function replayReadiness() external view returns (Readiness memory) {
        return _replayReadiness();
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

/// @notice 4 — `MalformedFinalIndex`: `afterPublication` returns `REPLY_LENGTH` bytes (33 in the brief) whose
///         first word is the clean selector word; anything but exactly 32 bytes must be refused, so a kernel that
///         checks the word but not `returndatasize()` is caught. Lengths below 32 return a truncated selector.
contract MalformedFinal is BaseIndexDouble {
    uint256 public immutable REPLY_LENGTH;

    constructor(address ledger_, uint256 replyLength) BaseIndexDouble(ledger_) {
        REPLY_LENGTH = replyLength;
    }

    function afterPublication(uint64, Effect[] calldata, bytes32[] calldata)
        public
        view
        override
        returns (bytes4)
    {
        _requireLedger();
        bytes4 s = IRealmIndex.afterPublication.selector;
        uint256 n = REPLY_LENGTH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, s)
            calldatacopy(add(p, 0x20), calldatasize(), n) // zero padding
            return(p, n)
        }
    }
}

/// @notice 5 — `WritingFinalIndex`: `afterPublication` attempts a storage write, which must fail because the
///         final call is a `STATICCALL` (§6.5). `NESTED == false`: the `SSTORE` runs in the callback's own
///         frame (an exceptional halt: empty returndata, all forwarded gas). `NESTED == true`: the write runs
///         in a bounded self-call and the failure is reported as `E_FINAL_WRITE()` revert data. Either way
///         the publication must fail (`E_INDEX_CALL`/`E_INDEX_FINAL`/`E_INDEX_GAS` by the kernel's
///         classification) and the prefix writes roll back. Under a plain `CALL` it writes and acknowledges.
/// @dev Not a `BaseIndexDouble`: the interface's `afterPublication` is `view`, which forbids the write this
///      double exists to attempt. The selector is the same.
contract WritingFinal is IndexDoubleCore {
    error E_FINAL_WRITE();

    bool public immutable NESTED;
    uint256 public finalWrites;

    constructor(address ledger_, bool nested) IndexDoubleCore(ledger_) {
        NESTED = nested;
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (bytes4)
    {
        _recordPrefix(publication, effects, refs);
        return IRealmIndex.onAdmission.selector;
    }

    function afterPublication(uint64, Effect[] calldata, bytes32[] calldata)
        external
        returns (bytes4)
    {
        _requireLedger();
        if (NESTED) {
            (bool ok,) = address(this).call{gas: 50_000}(abi.encodeCall(this.writeOnce, ()));
            if (!ok) revert E_FINAL_WRITE();
        } else {
            ++finalWrites;
        }
        return IRealmIndex.afterPublication.selector;
    }

    function writeOnce() external {
        if (msg.sender != address(this)) revert MockCaller(msg.sender);
        ++finalWrites;
    }

    function replayReadiness() external view returns (Readiness memory) {
        return _replayReadiness();
    }
}

/// @notice 6 — `OversizedCallbackIndex`: `onAdmission` sets `touched` and then reverts (`AS_REVERT`) or
///         returns (`!AS_REVERT`, the prototype's shape) with `SIZE` bytes (> 4,096 in the brief: 4,097).
///         The kernel bounds returndata at 4,096 bytes before copying (§2.2 S4, `E_INDEX_RETURNDATA`), and
///         `touched` must read 0 afterwards. The first word is `E_OVERSIZED()`'s selector when reverting and
///         the `onAdmission` selector when returning.
contract OversizedCallback is BaseIndexDouble {
    error E_OVERSIZED();

    uint256 public immutable SIZE;
    bool public immutable AS_REVERT;
    uint256 public touched;

    constructor(address ledger_, uint256 size, bool asRevert) BaseIndexDouble(ledger_) {
        SIZE = size;
        AS_REVERT = asRevert;
    }

    function onAdmission(uint64, Effect[] calldata, bytes32[] calldata)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        touched = 1;
        uint256 n = SIZE;
        bool asRevert = AS_REVERT;
        bytes4 s = asRevert ? E_OVERSIZED.selector : IRealmIndex.onAdmission.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, s)
            calldatacopy(add(p, 0x20), calldatasize(), n) // zero padding
            if asRevert { revert(p, n) }
            return(p, n)
        }
    }
}

/// @notice 7 — `BudgetBurningIndex`: burns `PREFIX_BURN` gas in each prefix call (after recording) and
///         `FINAL_BURN` in the final call. `ALL` burns everything forwarded and returns nothing (empty
///         returndata → `E_INDEX_GAS`, resubmit); a fixed amount builds the joint-allowance and
///         final-starvation fixtures (§16.3: "prefix spends everything it is given; final still runs from
///         finalReserve").
contract BudgetBurning is BaseIndexDouble {
    uint256 public constant ALL = type(uint256).max;

    uint256 public immutable PREFIX_BURN;
    uint256 public immutable FINAL_BURN;

    constructor(address ledger_, uint256 prefixBurn, uint256 finalBurn) BaseIndexDouble(ledger_) {
        PREFIX_BURN = prefixBurn;
        FINAL_BURN = finalBurn;
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4 ack)
    {
        ack = super.onAdmission(publication, effects, refs);
        _burn(PREFIX_BURN);
    }

    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) public view override returns (bytes4 ack) {
        ack = super.afterPublication(publication, effects, refs);
        _burn(FINAL_BURN);
    }

    function _burn(uint256 amount) private view {
        if (amount == 0) return;
        uint256 start = gasleft();
        while (start - gasleft() < amount) {}
    }
}

/// @notice 8 — `AttackIndex`: from each prefix call it re-enters `ILedger(ledger).execute` (and every attempt
///         the test added: activations, policy/role/wrapper activations, replay/build/backfill, …) by `CALL`,
///         and from the final call the same list by `STATICCALL`. Every attempt must revert with its expected
///         error (`E_PUBLICATION_ACTIVE` for the built-in one): the transient lock read through `phase()`
///         (§2.2 S1). Prefix attempts are recorded (`prefixAttempts`, `prefixRefusals`); an attempt that
///         succeeds or reverts otherwise reverts `AttackBypassed(i, returndata)` (prefix: unless `strict` is
///         off, in which case it is only left out of `prefixRefusals`; final: always).
contract AttackIndex is BaseIndexDouble {
    error AttackBypassed(uint256 attempt, bytes returndata);

    struct Attempt {
        address target;
        bytes data;
        bytes4 expected;
    }

    Attempt[] internal _attempts;
    bool public strict = true;
    uint64 public prefixAttempts;
    uint64 public prefixRefusals;

    constructor(address ledger_) BaseIndexDouble(ledger_) {}

    function addAttempt(address target, bytes calldata data, bytes4 expected) external onlyOwner {
        _attempts.push(Attempt(target, data, expected));
    }

    function setStrict(bool on) external onlyOwner {
        strict = on;
    }

    function attempts() external view returns (uint256) {
        return _attempts.length + 1;
    }

    /// `execute` with one CREATE leaf, an unbound native context and the canonical-empty guard.
    function reentryCalldata() public pure returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.CREATE;
        actions[0].salt = keccak256("efs2/test/index/reentry");
        Native memory ctx;
        return abi.encodeCall(ILedger.execute, (actions, new bytes[](1), ctx, ""));
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        uint256 n = _attempts.length + 1;
        for (uint256 i; i < n; ++i) {
            (address target, bytes memory data, bytes4 expected) = _attempt(i);
            (bool ok, bytes memory err) = target.call(data);
            ++prefixAttempts;
            if (!ok && _is(err, expected)) ++prefixRefusals;
            else if (strict) revert AttackBypassed(i, err);
        }
        return super.onAdmission(publication, effects, refs);
    }

    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) public view override returns (bytes4 ack) {
        ack = super.afterPublication(publication, effects, refs);
        uint256 n = _attempts.length + 1;
        for (uint256 i; i < n; ++i) {
            (address target, bytes memory data, bytes4 expected) = _attempt(i);
            (bool ok, bytes memory err) = target.staticcall(data);
            if (ok || !_is(err, expected)) revert AttackBypassed(i, err);
        }
    }

    function _attempt(uint256 i) internal view returns (address, bytes memory, bytes4) {
        if (i == 0) return (ledger, reentryCalldata(), E_PUBLICATION_ACTIVE.selector);
        Attempt storage a = _attempts[i - 1];
        return (a.target, a.data, a.expected);
    }

    function _is(bytes memory err, bytes4 expected) private pure returns (bool) {
        return err.length >= 4 && bytes4(err) == expected;
    }
}

/// @notice 9 — `LateRefusingIndexModule` (`MatchedRollback.t.sol`): acknowledges every prefix call (the honest
///         record runs) and refuses the final one with `E_LATE_INDEX(key)` — always when
///         `POISON_BINDING_KEY == 0`, otherwise only when the publication contains a BIND of that binding key
///         (`Keys.binding(principalId, position)`). The full prefix must roll back.
contract LateRefusing is BaseIndexDouble {
    error E_LATE_INDEX(bytes32 bindingKey);

    bytes32 public immutable POISON_BINDING_KEY;

    constructor(address ledger_, bytes32 poisonBindingKey) BaseIndexDouble(ledger_) {
        POISON_BINDING_KEY = poisonBindingKey;
    }

    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) public view override returns (bytes4 ack) {
        ack = super.afterPublication(publication, effects, refs);
        bytes32 poison = POISON_BINDING_KEY;
        if (poison == 0) revert E_LATE_INDEX(0);
        for (uint256 i; i < effects.length; ++i) {
            Effect calldata e = effects[i];
            if (e.kind == ActionKind.BIND && Keys.binding(e.principalId, e.position) == poison) {
                revert E_LATE_INDEX(poison);
            }
        }
    }
}

/// @notice 10 — `MutatingRule`: after recording, each prefix call asks the settable registry double to
///         `bumpMutations()`, so the kernel's per-leaf basis re-check (`registry.mutations() == snapshot`,
///         §6.4) trips with `E_REGISTRY_DRIFT` — but only when the registry allows this index
///         (`MockRegistry.setMutator`). A refused bump is counted (`bumpRefusals`) and the call still
///         acknowledges, so the same double is the negative control.
contract MutatingRule is BaseIndexDouble {
    address public registry;
    uint64 public bumps;
    uint64 public bumpRefusals;

    constructor(address ledger_, address registry_) BaseIndexDouble(ledger_) {
        registry = registry_;
    }

    function setRegistry(address registry_) external onlyOwner {
        registry = registry_;
    }

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4 ack)
    {
        ack = super.onAdmission(publication, effects, refs);
        address r = registry;
        if (r.code.length == 0) {
            ++bumpRefusals;
            return ack;
        }
        try MockRegistry(r).bumpMutations() {
            ++bumps;
        } catch {
            ++bumpRefusals;
        }
    }
}
