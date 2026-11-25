// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, PostingKey, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {OpenScopeConfig} from "../../src/interfaces/Index.sol";
import {OpenScopeReader} from "../../src/readers/OpenScopeReader.sol";
import {Layout} from "../../src/core/layout/Layout.sol";

/// @notice SPIKE (tags-index2) measurements of the topic lists on the Files Realm. Every measured publication is
///         cooled (each pays what a transaction of its own pays), native lane. Logs `os <variant> <row>`:
///         `exec` = the execution frame's regular gas, `state` = its EIP-8037 state gas (zero on prague),
///         `all` = exec + state, `tx` = all + 21,000 + the calldata's standard cost (an estimate of the whole
///         transaction). Each concrete contract is one index build (`OpenScopeConfig`) over the REAL `topic-word/1`
///         and `topic/1` Types, with `trustRegistered` on (the validator admits a first tag only on a topic first
///         admitted strictly before it). Words are made to satisfy the word grammar (`_wordAction` lowercases and
///         turns spaces into `-`).
abstract contract OpenScopeMeasureBase is FilesRecipesBase {
    uint256 internal constant N = 128;
    uint256 internal constant CAP = 1 << 24;
    uint8 internal constant V_MINE = 1; // family 19
    uint8 internal constant V_ALL = 2; // families 6 + 20 (TAG, FOLDER)
    uint8 internal constant V_ALL_BELOW = 4; // family 7
    uint8 internal constant V_RP = 16; // family 21 for TAG and FOLDER
    uint8 internal constant V_RP_TAG = 32; // family 21 for TAG only
    uint8 internal constant FULL = V_MINE | V_ALL | V_ALL_BELOW | V_RP;

    address[] internal cold;
    bytes32[N] internal s; // CREATE subjects of p: the tagged things
    OpenScopeReader internal reader;
    bytes32 internal wordType;
    bytes32 internal pathType;
    mapping(address => uint64) internal nonces;

    function _variant() internal pure virtual returns (uint8);
    function _vname() internal pure virtual returns (string memory);

    function _openScope() internal virtual override returns (OpenScopeConfig memory os) {
        wordType = topicTypeIds[TT_WORD];
        pathType = topicTypeIds[TT_PATH];
        uint8 v = _variant();
        os.wordTypeId = wordType;
        os.pathTypeId = pathType;
        os.scopeBelow = v & V_MINE != 0;
        if (v & V_ALL != 0) {
            os.allAuthors = new bytes32[](2);
            os.allAuthors[0] = Purpose.TAG;
            os.allAuthors[1] = Purpose.FOLDER;
        }
        os.allBelow = v & V_ALL_BELOW != 0;
        os.trustRegistered = true;
        os.rolePlaces = v & V_RP != 0 ? 2 : (v & V_RP_TAG != 0 ? 1 : 0);
    }

    function _isFull() internal pure returns (bool) {
        return _variant() == FULL;
    }

    function setUp() public override {
        super.setUp();
        reader = new OpenScopeReader();
        for (uint256 i; i < 10; ++i) {
            cold.push(instances[i]);
        }
        cold.push(topicInstances[TT_WORD]);
        cold.push(topicInstances[TT_PATH]);
        cold.push(address(validator));
        cold.push(address(r.k.ingress));
        cold.push(address(r.k.applyDelegate));
        cold.push(address(r.k.control));
        cold.push(address(r.k.implementation));
        cold.push(r.k.proxy);
        cold.push(address(r.g.posting));
        cold.push(address(r.g.bitmap));
        cold.push(address(r.g.index));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        cold.push(address(reader));
        for (uint256 from; from < N; from += 32) {
            Action[] memory a = new Action[](32);
            for (uint256 i; i < 32; ++i) {
                a[i] = _create(keccak256(abi.encode("tagged", from + i)));
                s[from + i] = Keys.subject(p, a[i].salt);
            }
            r.ledger.execute(a, new bytes[](32), _ctx(a), "");
        }
    }

    function _on(uint8 flags) internal pure returns (bool) {
        return _variant() & flags == flags;
    }

    function _cool() internal {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
    }

    function _beforeExecute() internal override {
        _cool();
    }

    function _label(string memory row) internal pure returns (string memory) {
        return string.concat("os ", _vname(), " ", row);
    }

    function _author(uint256 i) internal pure returns (address) {
        return address(uint160(0xA0000 + i));
    }

    function _pid(address who) internal view returns (bytes32) {
        return who == address(this) ? p : Keys.principal(who);
    }

    function _nctx(address who, Action[] memory a) internal returns (Native memory c) {
        if (who == address(this)) return _ctx(a);
        c.nonce = nonces[who]++;
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
    }

    function _go(address who, Action[] memory a, bytes[] memory b) internal {
        Native memory c = _nctx(who, a);
        if (who != address(this)) vm.prank(who, who);
        r.ledger.execute(a, b, c, "");
    }

    function _go(address who, Action[] memory a) internal {
        _go(who, a, new bytes[](a.length));
    }

    struct G {
        uint256 exec; // regular gas of the frame
        uint256 state; // EIP-8037 state gas of the frame
        uint256 all; // exec + state
        uint256 txAll; // all + intrinsic + calldata (estimate)
        uint256 txRegular; // exec + intrinsic + calldata (estimate)
    }

    function _calldataCost(bytes memory cd) internal pure returns (uint256 c) {
        for (uint256 i; i < cd.length; ++i) {
            c += cd[i] == 0 ? 4 : 16;
        }
    }

    /// One cooled publication by `who`; never logs.
    function _measure(address who, Action[] memory a, bytes[] memory b)
        internal
        returns (G memory g)
    {
        Native memory c = _nctx(who, a);
        uint256 extra =
            21_000 + _calldataCost(abi.encodeCall(ILedger.execute, (a, b, c, bytes(""))));
        _cool();
        if (who != address(this)) vm.prank(who, who);
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        g.exec = f.gasTotalUsed;
        g.state = f.gasStateUsed > 0 ? uint256(int256(f.gasStateUsed)) : 0;
        g.all = g.exec + g.state;
        g.txAll = g.all + extra;
        g.txRegular = g.exec + extra;
    }

    function _log(string memory row, G memory g) internal {
        emit log_named_uint(_label(string.concat(row, " exec")), g.exec);
        if (g.state != 0) emit log_named_uint(_label(string.concat(row, " state")), g.state);
        emit log_named_uint(_label(string.concat(row, " all")), g.all);
        emit log_named_uint(_label(string.concat(row, " tx")), g.txAll);
    }

    function _run(string memory row, address who, Action[] memory a, bytes[] memory b)
        internal
        returns (G memory g)
    {
        g = _measure(who, a, b);
        _log(row, g);
    }

    function _run(string memory row, address who, Action[] memory a) internal returns (G memory) {
        return _run(row, who, a, new bytes[](a.length));
    }

    // ---- statements and topics -------------------------------------------------------------------------------

    function _stmts(bytes32 topic, uint256 from, uint256 n, bool deny)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = deny
                ? _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, s[from + i], 0, 0)
                : _bind(Purpose.TAG, topic, s[from + i], s[from + i], 0);
        }
    }

    function _tags(bytes32 topic, uint256 from, uint256 n) internal view returns (Action[] memory) {
        return _stmts(topic, from, n, false);
    }

    /// Makes `w` a `topic-word/1` word IN PLACE (callers keep the same bytes as the body): ASCII upper case to lower
    /// case, space to `-`.
    function _wordAction(bytes memory w) internal view returns (Action memory a, bytes32 id) {
        for (uint256 i; i < w.length; ++i) {
            bytes1 c = w[i];
            if (c == 0x20) w[i] = 0x2d;
            else if (c >= 0x41 && c <= 0x5a) w[i] = bytes1(uint8(c) + 32);
        }
        a.kind = ActionKind.PUBLISH;
        a.typeId = wordType;
        a.bodyHashOrRecordId = keccak256(w);
        id = Keys.record(wordType, w);
    }

    function _pathAction(bytes32 parent, bytes32 wordPage)
        internal
        view
        returns (Action memory a, bytes memory body, bytes32 id)
    {
        body = abi.encode(parent, wordPage);
        a.kind = ActionKind.PUBLISH;
        a.typeId = pathType;
        a.bodyHashOrRecordId = keccak256(body);
        id = Keys.record(pathType, body);
    }

    function _wordBytes(string memory chain, uint256 i) internal pure returns (bytes memory) {
        return bytes(string.concat(chain, "-", vm.toString(i)));
    }

    /// A chain of `n` topics (index 0 the word page `<name>-0`), every level a new word, silently: the words
    /// first (64 per publication), then the paths (64 per publication).
    function _chain(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        t = new bytes32[](n);
        bytes32[] memory w = new bytes32[](n);
        for (uint256 from; from < n; from += 64) {
            uint256 m = n - from < 64 ? n - from : 64;
            Action[] memory a = new Action[](m);
            bytes[] memory b = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                b[i] = _wordBytes(name, from + i);
                (a[i], w[from + i]) = _wordAction(b[i]);
            }
            _go(address(this), a, b);
        }
        t[0] = w[0];
        for (uint256 from = 1; from < n; from += 64) {
            uint256 m = n - from < 64 ? n - from : 64;
            Action[] memory a = new Action[](m);
            bytes[] memory b = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                (a[i], b[i], t[from + i]) = _pathAction(t[from + i - 1], w[from + i]);
            }
            _go(address(this), a, b);
        }
    }

    /// A deep chain over ONE repeated word (the walk does not care which word a level holds).
    function _deepChain(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        t = new bytes32[](n);
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        b[0] = bytes(name);
        bytes32 w;
        (a[0], w) = _wordAction(b[0]);
        _go(address(this), a, b);
        t[0] = w;
        for (uint256 from = 1; from < n; from += 64) {
            uint256 m = n - from < 64 ? n - from : 64;
            a = new Action[](m);
            b = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                (a[i], b[i], t[from + i]) = _pathAction(t[from + i - 1], w);
            }
            _go(address(this), a, b);
        }
    }

    function _n(uint256 n) internal pure returns (string memory) {
        return vm.toString(n);
    }

    // =============================================================================================
    // 1./3. one statement on an n-word topic, four cases, alone and in a batch of 10
    // =============================================================================================

    address internal constant X = address(0xA0001);
    address internal constant Y = address(0xA0002);

    /// Prepares case `c` (1..4) on `topic` and returns the measured publication: author and statements.
    /// (i) everything fresh; (ii) the author's lists and the all-authors lists exist (6 entries), the position is
    /// new; (iii) the position exists (another author's), this author's below-lists are fresh; (iv) everything
    /// exists, the position has two authors already. `k` statements on things from a fixed base.
    function _case(uint8 c, bytes32 topic, uint256 k, bool deny)
        internal
        returns (address who, Action[] memory a)
    {
        if (c == 1) return (address(this), _stmts(topic, 0, k, deny));
        if (c == 2) {
            _go(address(this), _tags(topic, 0, 6));
            return (address(this), _stmts(topic, 6, k, deny));
        }
        if (c == 3) {
            _go(address(this), _tags(topic, 0, 10));
            return (X, _stmts(topic, 0, k, deny));
        }
        _go(address(this), _tags(topic, 0, 16));
        _go(Y, _tags(topic, 6, 10));
        _go(X, _tags(topic, 0, 6));
        return (X, _stmts(topic, 6, k, deny));
    }

    function _cases(bool deny) internal {
        if (!_on(V_MINE) && !_on(V_ALL) && _variant() != 0) return;
        bytes32[] memory t = _chain(deny ? "neg" : "pos", 64);
        string memory kind = deny ? "deny" : "tag";
        uint256[7] memory depths = [uint256(1), 2, 4, 8, 16, 32, 64];
        for (uint8 c = 1; c <= 4; ++c) {
            for (uint256 d; d < 7; ++d) {
                uint256 n = depths[d];
                string memory row = string.concat(kind, " case ", _n(c), " n ", _n(n), " ");
                uint256 snap = vm.snapshotState();
                (address who, Action[] memory a) = _case(c, t[n - 1], 1, deny);
                G memory one = _run(string.concat(row, "k1"), who, a);
                vm.revertToState(snap);
                (who, a) = _case(c, t[n - 1], 10, deny);
                G memory ten = _run(string.concat(row, "k10"), who, a);
                vm.revertToState(snap);
                emit log_named_uint(
                    _label(string.concat(row, "marginal all")), (ten.all - one.all) / 9
                );
                if (ten.state != 0) {
                    emit log_named_uint(
                        _label(string.concat(row, "marginal state")), (ten.state - one.state) / 9
                    );
                }
            }
        }
    }

    function test_cases_tag() public {
        _cases(false);
    }

    function test_cases_deny() public {
        _cases(true);
    }

    // =============================================================================================
    // 2./3. the deepest topic whose single statement fits one transaction (2^24)
    // =============================================================================================

    uint256 internal constant DEEP_MAX = 4096;

    /// The deep-fit preparation. Prefill that every depth shares is stated once on the deepest topic of the chain
    /// (its ancestors are every shallower topic's ancestors, so the author and all-authors roll-up lists of every
    /// shallower topic exist with two entries); per-depth prefill only where the case needs the position itself.
    /// Deviation from `_case`, both cases 2 and 4: the measured topic's own exact lists (family 10, and the place
    /// list in case 2) are fresh, one slot each, < 0.2% of a transaction at the depths measured.
    function _prefillDeep(uint8 c, bytes32 deepest) internal {
        if (c == 2) {
            _go(address(this), _tags(deepest, 0, 2));
        } else if (c == 4) {
            _go(address(this), _tags(deepest, 0, 1));
            _go(Y, _tags(deepest, 0, 1));
            _go(X, _tags(deepest, 0, 2));
        }
    }

    function _caseAt(uint8 c, bytes32 topic, bool deny)
        internal
        returns (address who, Action[] memory a)
    {
        if (c == 1) return (address(this), _stmts(topic, 0, 1, deny));
        if (c == 2) return (address(this), _stmts(topic, 2, 1, deny));
        if (c == 3) {
            _go(address(this), _tags(topic, 0, 1));
            return (X, _stmts(topic, 0, 1, deny));
        }
        _go(address(this), _tags(topic, 2, 1));
        _go(Y, _tags(topic, 2, 1));
        return (X, _stmts(topic, 2, 1, deny));
    }

    function _cost(bytes32 topic, uint8 c, bool deny, bool regularOnly) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        (address who, Action[] memory a) = _caseAt(c, topic, deny);
        G memory g = _measure(who, a, new bytes[](1));
        vm.revertToState(snap);
        if (regularOnly && g.state == 0) return type(uint256).max; // not a state-gas schedule
        return regularOnly ? g.txRegular : g.txAll;
    }

    /// The deepest topic whose single statement (case `c`) fits 2^24: predicted from the slope between depths 17
    /// and 33 (estimate), then measured: a bisection between a depth that fits and one that does not.
    function _fit(uint8 c, bool deny, bool regularOnly) internal {
        uint8 v = _variant();
        if (v != V_MINE && v != (V_ALL | V_ALL_BELOW) && v != FULL) return; // mine, all, full only
        string memory row = string.concat(
            deny ? "deny" : "tag",
            " case ",
            _n(c),
            regularOnly ? " regular-only" : " all-gas",
            " deepest"
        );
        bytes32[] memory small = _deepChain(string.concat(row, " small"), 34);
        _prefillDeep(c, small[33]);
        uint256 c17 = _cost(small[16], c, deny, regularOnly);
        if (c17 == type(uint256).max) return; // regular-only rows exist on amsterdam only
        uint256 c33 = _cost(small[32], c, deny, regularOnly);
        uint256 slope = c33 > c17 ? (c33 - c17) / 16 : 0;
        emit log_named_uint(_label(string.concat(row, " per level (estimate)")), slope);
        if (slope < 100) {
            emit log_named_uint(_label(string.concat(row, " depth-independent, tx at 33")), c33);
            return;
        }
        uint256 n = c17 >= CAP ? 1 : 17 + (CAP - c17) / slope;
        emit log_named_uint(_label(string.concat(row, " predicted (estimate)")), n);
        if (n + 8 > DEEP_MAX) {
            emit log_named_uint(_label(string.concat(row, " beyond the spike chain")), DEEP_MAX);
            return;
        }
        bytes32[] memory t = _deepChain(string.concat(row, " deep"), n + 3);
        _prefillDeep(c, t[n + 2]);
        uint256 hi = n + 1; // depth n + 1 is t[n]
        uint256 lo = n - (n / 32 + 4);
        uint256 atLo = _cost(t[lo - 1], c, deny, regularOnly);
        while (atLo > CAP) {
            hi = lo;
            lo = lo - (n / 32 + 4);
            atLo = _cost(t[lo - 1], c, deny, regularOnly);
        }
        uint256 atHi = _cost(t[hi - 1], c, deny, regularOnly);
        if (atHi <= CAP) {
            emit log_named_uint(_label(string.concat(row, " >= (measured)")), hi);
            return;
        }
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 at = _cost(t[mid - 1], c, deny, regularOnly);
            if (at <= CAP) (lo, atLo) = (mid, at);
            else (hi, atHi) = (mid, at);
        }
        emit log_named_uint(_label(string.concat(row, " (measured)")), lo);
        emit log_named_uint(_label(string.concat(row, " tx at n")), atLo);
        emit log_named_uint(_label(string.concat(row, " tx at n+1")), atHi);
    }

    function test_fit_tag_case1_all() public {
        _fit(1, false, false);
    }

    function test_fit_tag_case1_regular() public {
        _fit(1, false, true);
    }

    function test_fit_tag_case2_all() public {
        _fit(2, false, false);
    }

    function test_fit_tag_case2_regular() public {
        _fit(2, false, true);
    }

    function test_fit_tag_case3_all() public {
        _fit(3, false, false);
    }

    function test_fit_tag_case3_regular() public {
        _fit(3, false, true);
    }

    function test_fit_tag_case4_all() public {
        _fit(4, false, false);
    }

    function test_fit_tag_case4_regular() public {
        _fit(4, false, true);
    }

    function test_fit_deny_case1_all() public {
        _fit(1, true, false);
    }

    function test_fit_deny_case1_regular() public {
        _fit(1, true, true);
    }

    function test_fit_deny_case2_all() public {
        _fit(2, true, false);
    }

    function test_fit_deny_case2_regular() public {
        _fit(2, true, true);
    }

    function test_fit_deny_case3_all() public {
        _fit(3, true, false);
    }

    function test_fit_deny_case3_regular() public {
        _fit(3, true, true);
    }

    function test_fit_deny_case4_all() public {
        _fit(4, true, false);
    }

    function test_fit_deny_case4_regular() public {
        _fit(4, true, true);
    }

    // =============================================================================================
    // Part 2: the per-list cost on a word-page topic (no walk)
    // =============================================================================================

    /// Position-authors only (the position exists, so no place entry): the second author materializes word 0, the
    /// third and fourth write into it. Compare with `off` for the per-list cost (one fresh-detection head read plus
    /// one append).
    function test_per_list() public {
        bytes32 x = _chain("per-list", 1)[0];
        Action[] memory a = _tags(x, 0, 1);
        _run("per-list author 1 (place 0->1, authors 0->1)", address(this), a);
        _run("per-list author 2 (authors 1->2)", X, a);
        _run("per-list author 3 (authors 2->3)", Y, a);
        _run("per-list author 4 (authors 3->4)", _author(3), a);
        _run("per-list author 1 thing 2 (place 1->2, authors 0->1)", address(this), _tags(x, 1, 1));
        _run("per-list author 1 thing 3 (place 2->3, authors 0->1)", address(this), _tags(x, 2, 1));
        // the per-author roll-up on a 2-word topic: one ancestor list (0->1, 1->2, 2->3) plus a one-level walk
        bytes32 y = _chain("per-list-2", 2)[1];
        _run("per-list n2 entry 1", address(this), _tags(y, 0, 1));
        _run("per-list n2 entry 2", address(this), _tags(y, 1, 1));
        _run("per-list n2 entry 3", address(this), _tags(y, 2, 1));
        _run("per-list n2 k10 entries 4-13", address(this), _tags(y, 3, 10));
    }

    // =============================================================================================
    // 4. ordinary file work (FOLDER two-level lists on in `all` builds)
    // =============================================================================================

    function _createFile(uint256 i)
        internal
        view
        returns (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRec)
    {
        bytes32 salt = keccak256(abi.encode("os-file", i));
        file = Keys.subject(p, salt);
        string memory name = string.concat("file-", _n(i), ".txt");
        a = new Action[](5);
        b = new bytes[](5);
        a[0] = _create(salt);
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file, uint256(0)), "hello"));
        rootRec = _id(T_ROOT, b[1]);
        (a[2], b[2]) = _name(bytes(name));
        a[3] = _bind(Purpose.HEAD, file, 0, rootRec, 0);
        a[4] = _bind(Purpose.FOLDER, rootDir, keccak256(bytes(name)), file, 0);
    }

    function test_files() public {
        uint8 v = _variant();
        if (v != 0 && v & (V_MINE | V_ALL | V_ALL_BELOW) != (V_MINE | V_ALL | V_ALL_BELOW)) return;
        (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRec) = _createFile(0);
        G memory one = _run("file create k1", address(this), a, b);
        (a, b,,) = _createFile(1);
        _run("file create k1 (second)", address(this), a, b);
        Action[] memory batch = new Action[](50);
        bytes[] memory bodies = new bytes[](50);
        for (uint256 f; f < 10; ++f) {
            (a, b,,) = _createFile(2 + f);
            for (uint256 j; j < 5; ++j) {
                batch[5 * f + j] = a[j];
                bodies[5 * f + j] = b[j];
            }
        }
        G memory ten = _run("file create k10", address(this), batch, bodies);
        emit log_named_uint(_label("file create marginal all"), (ten.all - one.all) / 9);
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) =
            _publish(T_CHILD, bytes.concat(abi.encode(rootRec, file, uint256(0)), "edited"));
        a[1] = _bind(Purpose.HEAD, file, 0, _id(T_CHILD, b[0]), 1);
        _run("file edit (HEAD rebind)", address(this), a, b);
    }

    // =============================================================================================
    // 4b. what family 21 (role-places) adds to a first tag on a fresh position
    // =============================================================================================

    /// A first tag on a fresh position of an existing one-word topic (the place list exists, the author's scope list
    /// exists): the thing never tagged before (its role-places list is fresh) and the thing already tagged under
    /// another topic (its list exists). Compare `full` with `full-no-rp`; `full-rp-tag` equals `full` here.
    function test_role_places_cost() public {
        if (_variant() & (V_MINE | V_ALL | V_ALL_BELOW) != (V_MINE | V_ALL | V_ALL_BELOW)) return;
        bytes32 x = _chain("rp-x", 1)[0];
        bytes32 y = _chain("rp-y", 1)[0];
        _go(address(this), _tags(x, 10, 2)); // x's place list and the author's scope list on x exist
        _go(address(this), _tags(y, 0, 1)); // thing 0 is already tagged elsewhere
        _run("role-places first tag, thing never tagged", address(this), _tags(x, 1, 1));
        _run("role-places first tag, thing tagged elsewhere", address(this), _tags(x, 0, 1));
        _run("role-places lone negative, thing never tagged", address(this), _stmts(x, 2, 1, true));
        _run("role-places k10 things never tagged", address(this), _tags(x, 20, 10));
    }

    // =============================================================================================
    // 5. registering path records (family 11 included)
    // =============================================================================================

    function test_register() public {
        if (_variant() != 0 && !_isFull()) return;
        bytes32[] memory base = _chain("reg", 2);
        // one path record alone: parent and word exist
        bytes memory wb = bytes("reg-new-word");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        bytes32 w;
        (a[0], w) = _wordAction(wb);
        b[0] = wb;
        _run("register word page k1", address(this), a, b);
        (a[0], b[0],) = _pathAction(base[1], w);
        G memory one = _run("register path k1 (parent and word exist)", address(this), a, b);
        Action[] memory again = a;
        bytes[] memory againB = b;
        a = new Action[](10);
        b = new bytes[](10);
        // ten new paths under ten different existing parents, all with the existing word w
        bytes32[] memory parents = _chain("reg-parents", 10);
        for (uint256 i; i < 10; ++i) {
            (a[i], b[i],) = _pathAction(parents[i], w);
        }
        G memory ten = _run("register path k10", address(this), a, b);
        emit log_named_uint(_label("register path marginal all"), (ten.all - one.all) / 9);
        _run("register path second registrant (REUSE-like republish)", X, again, againB);
        // brand-new paths of n words, every word new, in consecutive chunks of at most 64 actions
        uint256[5] memory ns = [uint256(2), 8, 16, 32, 64];
        for (uint256 i; i < 5; ++i) {
            _brandNew(ns[i]);
        }
    }

    /// The 2n-1 actions of a brand-new n-word path (w0, then w_i and p_i), split greedily into chunks that fit
    /// 64 actions and 2^24 (all gas, and regular-only when the schedule has state gas).
    function _brandNew(uint256 n) internal {
        uint256 m = 2 * n - 1;
        Action[] memory all = new Action[](m);
        bytes[] memory bodies = new bytes[](m);
        string memory name = string.concat("brand-", _n(n));
        bytes32 parent;
        for (uint256 i; i < n; ++i) {
            bytes memory wb = _wordBytes(name, i);
            bytes32 w;
            uint256 at = i == 0 ? 0 : 2 * i - 1;
            (all[at], w) = _wordAction(wb);
            bodies[at] = wb;
            if (i == 0) {
                parent = w;
            } else {
                (all[at + 1], bodies[at + 1], parent) = _pathAction(parent, w);
            }
        }
        for (uint8 metric; metric < 2; ++metric) {
            uint256 snap = vm.snapshotState();
            (uint256 txs, uint256 total, bool sawState) = _chunks(all, bodies, metric == 1);
            vm.revertToState(snap);
            if (metric == 1 && !sawState) break;
            string memory row = string.concat(
                "brand-new path n ", _n(n), metric == 1 ? " regular-only" : " all-gas"
            );
            emit log_named_uint(_label(string.concat(row, " transactions")), txs);
            emit log_named_uint(_label(string.concat(row, " total tx gas")), total);
        }
    }

    function _chunks(Action[] memory all, bytes[] memory bodies, bool regularOnly)
        internal
        returns (uint256 txs, uint256 total, bool sawState)
    {
        uint256 m = all.length;
        for (uint256 start; start < m;) {
            uint256 size = m - start < 64 ? m - start : 64;
            while (true) {
                uint256 inner = vm.snapshotState();
                G memory g = _measureSlice(all, bodies, start, size);
                if (g.state != 0) sawState = true;
                if ((regularOnly ? g.txRegular : g.txAll) <= CAP) {
                    total += g.txAll;
                    break;
                }
                vm.revertToState(inner);
                size /= 2;
                require(size != 0, "one action does not fit");
            }
            start += size;
            ++txs;
        }
    }

    function _measureSlice(Action[] memory all, bytes[] memory bodies, uint256 start, uint256 size)
        internal
        returns (G memory)
    {
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, start, size);
        return _measure(address(this), a, b);
    }

    function _slice(Action[] memory a, bytes[] memory b, uint256 from, uint256 n)
        internal
        pure
        returns (Action[] memory x, bytes[] memory y)
    {
        x = new Action[](n);
        y = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = a[from + i];
            y[i] = b[from + i];
        }
    }

    // =============================================================================================
    // 6. reads (cold)
    // =============================================================================================

    function _lens(uint256 n) internal view returns (bytes32[] memory l) {
        l = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = i == 0 ? p : Keys.principal(_author(i));
        }
    }

    /// Topic T at depth d with one child C. Author 0 (this contract) tags things 0..59 on T and 60..119 on C;
    /// authors 1..63 each tag thing i%60 on T and 60 + i%60 on C, after author 0 (so their statements are the
    /// newest); author 1 also denies thing 2 on T.
    function _populate(uint256 d) internal returns (bytes32 t, bytes32 c) {
        bytes32[] memory ch = _chain(string.concat("read", _n(d)), d);
        t = ch[d - 1];
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        bytes memory wb = bytes(string.concat("child", _n(d)));
        bytes32 w;
        (a[0], w) = _wordAction(wb);
        b[0] = wb;
        _go(address(this), a, b);
        (a[0], b[0], c) = _pathAction(t, w);
        _go(address(this), a, b);
        _go(address(this), _tags(t, 0, 60));
        Action[] memory below = new Action[](60);
        for (uint256 i; i < 60; ++i) {
            below[i] = _bind(Purpose.TAG, c, s[60 + i], s[60 + i], 0);
        }
        _go(address(this), below);
        for (uint256 i = 1; i < 64; ++i) {
            Action[] memory x = new Action[](i == 1 ? 3 : 2);
            x[0] = _bind(Purpose.TAG, t, s[i % 60], s[i % 60], 0);
            x[1] = _bind(Purpose.TAG, c, s[60 + i % 60], s[60 + i % 60], 0);
            if (i == 1) x[2] = _bindKind(ActionKind.UNBIND, Purpose.TAG, t, s[2], 0, 0);
            _go(_author(i), x);
        }
    }

    function _mineRead(string memory row, bytes32 t, uint256 lens, uint16 count) internal {
        OpenScopeReader.MineQuery memory q;
        q.lens = _lens(lens);
        q.topic = t;
        q.below = true;
        q.count = count;
        _cool();
        uint256 before = gasleft();
        (OpenScopeReader.MineRow[] memory rows,) = reader.mine(address(r.ledger), q);
        uint256 used = before - gasleft();
        emit log_named_uint(_label(string.concat(row, " gas")), used);
        emit log_named_uint(_label(string.concat(row, " rows")), rows.length);
    }

    function _everyRead(string memory row, bytes32 t, bool below, uint16 count, bool raw) internal {
        OpenScopeReader.EveryoneQuery memory q;
        q.purpose = Purpose.TAG;
        q.topic = t;
        q.below = below;
        q.count = count;
        q.lens = _lens(8);
        q.raw = raw;
        _cool();
        uint256 before = gasleft();
        (uint64 len,, OpenScopeReader.PlaceRow[] memory rows) =
            reader.everyone(address(r.ledger), q);
        uint256 used = before - gasleft();
        emit log_named_uint(_label(string.concat(row, " gas")), used);
        emit log_named_uint(_label(string.concat(row, " rows")), rows.length);
        emit log_named_uint(_label(string.concat(row, " list length")), len);
    }

    function _reads(uint256 d) internal {
        if (!_isFull()) return;
        (bytes32 t,) = _populate(d);
        string memory dd = string.concat("read depth ", _n(d), " ");
        uint256[4] memory lenses = [uint256(1), 8, 32, 64];
        for (uint256 i; i < 4; ++i) {
            _mineRead(string.concat(dd, "mine lens ", _n(lenses[i]), " page 10"), t, lenses[i], 10);
            _mineRead(string.concat(dd, "mine lens ", _n(lenses[i]), " page 50"), t, lenses[i], 50);
        }
        _everyRead(string.concat(dd, "everyone exact lens 8 page 10"), t, false, 10, false);
        _everyRead(string.concat(dd, "everyone exact lens 8 page 50"), t, false, 50, false);
        _everyRead(string.concat(dd, "everyone exact raw page 10"), t, false, 10, true);
        _everyRead(string.concat(dd, "everyone exact raw page 50"), t, false, 50, true);
        _everyRead(string.concat(dd, "everyone below lens 8 page 10"), t, true, 10, false);
        _everyRead(string.concat(dd, "everyone below raw page 50"), t, true, 50, true);
        _cool();
        uint256 before = gasleft();
        uint64 n = reader.places(address(r.ledger), Purpose.TAG, t);
        emit log_named_uint(_label(string.concat(dd, "count places gas")), before - gasleft());
        emit log_named_uint(_label(string.concat(dd, "count places")), n);
        _cool();
        before = gasleft();
        n = reader.authors(address(r.ledger), Keys.position(Purpose.TAG, t, s[1]));
        emit log_named_uint(_label(string.concat(dd, "count authors gas")), before - gasleft());
        emit log_named_uint(_label(string.concat(dd, "count authors")), n);
    }

    function test_reads_01() public {
        _reads(1);
    }

    function test_reads_08() public {
        _reads(8);
    }

    function test_reads_64() public {
        _reads(64);
    }

    /// One word page `/w` rendered from the family-11 directory: the topics that use the word (family 11, ordinal 1,
    /// one entry per `topic/1` record naming the page, its admission), each topic's id from its admission row (word
    /// +1), then one place count (family 6 head) per topic. k = 1, 5, 20 places, 3 things tagged in each. Cold.
    function test_word_page_render() public {
        if (!_isFull()) return;
        uint256[3] memory ks = [uint256(1), 5, 20];
        for (uint256 x; x < 3; ++x) {
            uint256 k = ks[x];
            bytes memory wb = bytes(string.concat("render-", _n(k)));
            Action[] memory a = new Action[](1);
            bytes[] memory b = new bytes[](1);
            bytes32 w;
            (a[0], w) = _wordAction(wb);
            b[0] = wb;
            _go(address(this), a, b);
            bytes32[] memory paths = new bytes32[](k);
            for (uint256 i; i < k; ++i) {
                bytes32 parent = _chain(string.concat("render-", _n(k), "-parent-", _n(i)), 1)[0];
                (a[0], b[0], paths[i]) = _pathAction(parent, w);
                _go(address(this), a, b);
                _go(address(this), _tags(paths[i], 3 * i, 3));
            }
            _cool();
            uint256 before = gasleft();
            PostingKey dir = PostingKey.wrap(Keys.referenceList(pathType, 1, w));
            (uint64 n,,,) = r.g.posting.postingHead(dir);
            uint64[] memory adm = r.g.posting.postingSlice(dir, 0, uint16(n));
            bytes32[] memory slots = new bytes32[](n);
            for (uint256 i; i < n; ++i) {
                slots[i] = bytes32(Layout.admissionsRowsSlot(adm[i]) + 1);
            }
            bytes32[] memory ids = r.hot.extsloadBatch(slots);
            uint256 total;
            for (uint256 i; i < n; ++i) {
                total += reader.places(address(r.ledger), Purpose.TAG, ids[i]);
            }
            uint256 used = before - gasleft();
            assertEq(n, k, "k topics use the word");
            for (uint256 i; i < n; ++i) {
                assertEq(ids[i], paths[i], "admission row word 1 is the record id");
            }
            assertEq(total, 3 * k);
            emit log_named_uint(_label(string.concat("render word page k ", _n(k), " gas")), used);
        }
    }

    function _byName(string memory row, bytes32 position, uint16 count) internal {
        _cool();
        uint256 before = gasleft();
        (uint64 len, OpenScopeReader.AuthorRow[] memory rows) =
            reader.byName(address(r.ledger), position, 0, count);
        emit log_named_uint(_label(string.concat(row, " gas")), before - gasleft());
        emit log_named_uint(_label(string.concat(row, " rows")), rows.length);
        emit log_named_uint(_label(string.concat(row, " authors")), len);
    }

    /// "anyone's pet.jpg at this address": one position with 3 authors and one with 300 (targeted spam).
    function test_by_name() public {
        if (!_isFull()) return;
        bytes32 x = _chain("byname", 1)[0];
        for (uint256 i; i < 3; ++i) {
            _go(_author(100 + i), _tags(x, 0, 1));
        }
        for (uint256 i; i < 300; ++i) {
            _go(_author(1000 + i), _tags(x, 1, 1));
        }
        _byName("byName 3 authors page 3", Keys.position(Purpose.TAG, x, s[0]), 3);
        _byName("byName 300 authors page 3", Keys.position(Purpose.TAG, x, s[1]), 3);
        _byName("byName 300 authors page 10", Keys.position(Purpose.TAG, x, s[1]), 10);
        // one name in a place of 3 positions and in a place of 2,000 positions (lone negatives on fresh roles)
        bytes32 small = _chain("place-small", 1)[0];
        bytes32 big = _chain("place-big", 1)[0];
        _go(address(this), _tags(small, 0, 3));
        for (uint256 from; from < 2000; from += 50) {
            Action[] memory a = new Action[](50);
            for (uint256 i; i < 50; ++i) {
                a[i] = _bindKind(
                    ActionKind.UNBIND, Purpose.TAG, big, keccak256(abi.encode(from + i)), 0, 0
                );
            }
            _go(address(this), a);
        }
        _go(address(this), _tags(big, 0, 1));
        _go(X, _tags(small, 0, 1));
        _go(X, _tags(big, 0, 1));
        _byName("lookup one name in a place of 3", Keys.position(Purpose.TAG, small, s[0]), 3);
        _byName("lookup one name in a place of 2001", Keys.position(Purpose.TAG, big, s[0]), 3);
        emit log_named_uint(
            _label("place of 2001 positions"), reader.places(address(r.ledger), Purpose.TAG, big)
        );
    }

    // =============================================================================================
    // 7. spam: the cheapest statement that adds one entry
    // =============================================================================================

    function test_spam() public {
        if (!_isFull()) return;
        bytes32[] memory t = _chain("spam", 2);
        // (a) a place entry: lone negatives on fresh roles of a word-page topic (no walk), batch of 10
        _go(address(this), _stmts(t[0], 0, 1, true)); // the lists exist
        Action[] memory a = new Action[](10);
        for (uint256 i; i < 10; ++i) {
            a[i] = _bindKind(
                ActionKind.UNBIND, Purpose.TAG, t[0], keccak256(abi.encode("a", i)), 0, 0
            );
        }
        G memory ten = _run("spam place k10", address(this), a);
        Action[] memory one = new Action[](1);
        one[0] = _bindKind(ActionKind.UNBIND, Purpose.TAG, t[0], keccak256("a-one"), 0, 0);
        G memory k1 = _run("spam place k1", address(this), one);
        emit log_named_uint(_label("spam place per entry (batch marginal)"), (ten.all - k1.all) / 9);
        // (b) an all-authors roll-up entry of the ancestor t[0]: lone negatives on fresh roles of t[1]
        for (uint256 i; i < 10; ++i) {
            a[i] = _bindKind(
                ActionKind.UNBIND, Purpose.TAG, t[1], keccak256(abi.encode("b", i)), 0, 0
            );
        }
        _go(address(this), _stmts(t[1], 0, 1, true));
        ten = _run("spam roll-up k10", address(this), a);
        one[0] = _bindKind(ActionKind.UNBIND, Purpose.TAG, t[1], keccak256("b-one"), 0, 0);
        k1 = _run("spam roll-up k1", address(this), one);
        emit log_named_uint(
            _label("spam roll-up per entry (batch marginal)"), (ten.all - k1.all) / 9
        );
        // (c) a position-authors entry: a new principal's lone negative on an existing position (one per tx)
        _run("spam position-authors new principal", _author(500), _stmts(t[0], 0, 1, true));
        _run("spam position-authors new principal 2", _author(501), _stmts(t[0], 0, 1, true));
    }

    // =============================================================================================
    // round one's row that still applies: entries on one exact topic (a word page: no walk)
    // =============================================================================================

    function test_exact_writes() public {
        bytes32 x = _chain("exact", 1)[0];
        _run("exact assert entry 1 (first ever on a topic)", address(this), _tags(x, 0, 1));
        _run("exact assert entry 2", address(this), _tags(x, 1, 1));
        _go(address(this), _tags(x, 2, 3));
        _run("exact assert entry 6", address(this), _tags(x, 5, 1));
        _go(address(this), _tags(x, 6, 4));
        _run("exact assert entry 11", address(this), _tags(x, 10, 1));
        _run("exact assert k10 entries 12-21", address(this), _tags(x, 11, 10));
        _run("exact deny k10 entries 22-31", address(this), _stmts(x, 21, 10, true));
    }
}

contract OpenScopeMeasureOff is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return 0;
    }

    function _vname() internal pure override returns (string memory) {
        return "off";
    }
}

contract OpenScopeMeasureMine is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_MINE;
    }

    function _vname() internal pure override returns (string memory) {
        return "mine";
    }
}

contract OpenScopeMeasureAll is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_ALL | V_ALL_BELOW;
    }

    function _vname() internal pure override returns (string memory) {
        return "all";
    }
}

contract OpenScopeMeasureFull is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return FULL;
    }

    function _vname() internal pure override returns (string memory) {
        return "full";
    }
}

/// Every list but role-places (family 21): `full` minus this is what family 21 adds.
contract OpenScopeMeasureFullNoRolePlaces is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_MINE | V_ALL | V_ALL_BELOW;
    }

    function _vname() internal pure override returns (string memory) {
        return "full-no-rp";
    }
}

/// Every list, role-places for TAG only (FOLDER positions append no family-21 entry).
contract OpenScopeMeasureFullRolePlacesTag is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_MINE | V_ALL | V_ALL_BELOW | V_RP_TAG;
    }

    function _vname() internal pure override returns (string memory) {
        return "full-rp-tag";
    }
}
