// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesFixture} from "../profiles/FilesFixture.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    Purpose,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";

/// @notice The Files Realm of the recipe suites (`FilesRecipes.t.sol`, `FilesLargeFiles.t.sol`): the profile on a
///         real kernel, registry proxy and generation-1 index, the Realm root seeded by this contract's principal,
///         native-lane builders (both expectations bound), index probes and a state snapshot for refusals.
abstract contract FilesRecipesBase is FilesFixture {
    Realm internal r;
    bytes32 internal p; // address(this) as a contract principal of the Realm

    bytes32 internal F_BACKLINK = Keys.familyId("backlink");
    bytes32 internal F_HISTORY = Keys.familyId("history");
    bytes32 internal F_BY_TYPE = Keys.familyId("by-type");
    bytes32 internal F_DIGEST = Keys.familyId("digest");
    bytes32 internal F_REFERENCE = Keys.familyId("reference-position");

    bytes32 internal rootDir;

    function setUp() public virtual {
        _deployProfile();
        r = _realm(keccak256("files/realm-a"));
        _register(r);
        p = r.principal;
        // Root (the seed, once per Realm): PUBLISH(files-directory/1, (p, rootSalt)); no CREATE, no FOLDER bind
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(T_DIRECTORY, _dirBody(p, keccak256("root")));
        rootDir = _id(T_DIRECTORY, b[0]);
        _exec("recipe root seed (PUBLISH directory)", a, b);
    }

    // ---- builders -----------------------------------------------------------------------------------------------

    function _id(uint8 t, bytes memory body) internal view returns (bytes32) {
        return Keys.record(typeIds[t], body);
    }

    /// `files-directory/1`: `abi.encode(creatorPrincipal, salt)`.
    function _dirBody(bytes32 creator, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encode(creator, salt);
    }

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.saltOrStrength = salt;
    }

    function _publish(uint8 t, bytes memory body)
        internal
        view
        returns (Action memory a, bytes memory)
    {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeIds[t];
        a.bodyHashOrRecordId = keccak256(body);
        return (a, body);
    }

    function _bindKind(
        uint8 kind,
        bytes32 purpose,
        bytes32 subject,
        bytes32 role,
        bytes32 target,
        uint64 expected
    ) internal pure returns (Action memory a) {
        a.kind = kind;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _bind(bytes32 purpose, bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bindKind(ActionKind.BIND, purpose, subject, role, target, expected);
    }

    /// Both expectations bound (the SDK default, design Q22): the live execution set and the acceptance profile.
    function _ctx(Action[] memory actions) internal view returns (Native memory c) {
        (c.nonce,) = r.hot.nonceOf(p);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), actions);
    }

    function _exec(string memory label, Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 publication)
    {
        Native memory c = _ctx(actions);
        _beforeMeasure(label, actions, bodies, c);
        _beforeExecute();
        uint256 before = gasleft();
        (publication,) = r.ledger.execute(actions, bodies, c, "");
        uint256 used = before - gasleft();
        Vm.Gas memory frame = vm.lastFrameGas();
        emit log_named_uint(string.concat(label, " gas"), used);
        emit log_named_uint(string.concat(label, " frame gas"), frame.gasTotalUsed);
        // EIP-8037 state gas: zero under the release schedule (prague), meaningful under `--profile amsterdam`
        if (frame.gasStateUsed != 0) {
            emit log_named_int(string.concat(label, " frame state gas"), frame.gasStateUsed);
        }
    }

    /// Native execution as `author` (an EOA author is also tx.origin), both expectations bound; no gas log.
    function _execAs(address author, Action[] memory a, bytes[] memory b)
        internal
        returns (uint64 publication)
    {
        bytes32 principal = author == address(this) ? p : Keys.principal(author);
        Native memory c;
        (c.nonce,) = r.hot.nonceOf(principal);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
        if (author != address(this)) vm.prank(author, author);
        (publication,) = r.ledger.execute(a, b, c, "");
    }

    /// Runs after the expectations are read and before the measured `execute` (`GasModel.t.sol` cools the state
    /// and may prank the caller here; a no-op for the recipe suites).
    function _beforeExecute() internal virtual {}

    /// Runs before the measured publication with its exact inputs, and must leave the state as it found it
    /// (`GasModel.t.sol` measures the kernel's own share here; a no-op for the recipe suites).
    function _beforeMeasure(
        string memory label,
        Action[] memory actions,
        bytes[] memory bodies,
        Native memory c
    ) internal virtual {}

    function _name(bytes memory n) internal view returns (Action memory a, bytes memory) {
        return _publish(T_NAME, n);
    }

    function _key(bytes32 purpose, bytes32 subject, bytes32 role) internal view returns (bytes32) {
        return Keys.binding(p, Keys.position(purpose, subject, role));
    }

    function _scope(bytes32 dir)
        internal
        view
        returns (uint64 count, uint64 live, uint48 bits, uint64 entry0)
    {
        (count, live,, bits,, entry0) =
            r.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(p, Purpose.FOLDER, dir)));
    }

    function _posting(bytes32 family, bytes32 typeId, bytes32 value)
        internal
        view
        returns (uint64 count, uint64 live)
    {
        Coverage c;
        (c, count, live,,) =
            r.g.index.postingHeadOf(FamilyId.wrap(family), TypeId.wrap(typeId), 0, value);
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "honest coverage");
    }

    function _head(bytes32 key)
        internal
        view
        returns (uint8 state, uint64 revision, bytes32 target)
    {
        (state, revision,,,,, target,) = r.hot.head(key);
    }

    function _assertScope(bytes32 dir, uint64 count, uint64 live, uint48 bits) internal view {
        (uint64 c, uint64 l, uint48 b,) = _scope(dir);
        assertEq(c, count, "scope entries");
        assertEq(l, live, "scope live");
        assertEq(b, bits, "scope live bits");
    }

    /// Family 5 is keyed by (purpose, target): the purpose rides in the key's first word.
    function _assertBacklink(bytes32 purpose, bytes32 target, uint64 count, uint64 live)
        internal
        view
    {
        (uint64 c, uint64 l) = _posting(F_BACKLINK, purpose, target);
        assertEq(c, count, "backlink entries");
        assertEq(l, live, "backlink live");
    }

    function _assertHistory(bytes32 key, uint64 count) internal view {
        (uint64 c,) = _posting(F_HISTORY, 0, key);
        assertEq(c, count, "history entries");
    }

    // ---- refusals land nothing ---------------------------------------------------------------------------------

    struct Snapshot {
        uint64 admissions;
        uint64 records;
        uint64 bindings;
        uint64 publications;
        uint64 nonce;
        uint64 processed;
        uint64 scopeCount;
        uint64 scopeLive;
        uint64 backlinks;
        uint64 headBacklinks;
    }

    function _snapshot(bytes32 dir, bytes32 target) internal view returns (Snapshot memory s) {
        (s.admissions, s.records, s.bindings, s.publications) = r.hot.counts();
        (s.nonce,) = r.hot.nonceOf(p);
        (s.processed,,) = r.g.index.progress();
        (s.scopeCount, s.scopeLive,,) = _scope(dir);
        (s.backlinks,) = _posting(F_BACKLINK, Purpose.FOLDER, target);
        (s.headBacklinks,) = _posting(F_BACKLINK, Purpose.HEAD, target);
    }

    function _assertSame(Snapshot memory x, Snapshot memory y) internal pure {
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), "nothing landed");
    }
}
