// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TopicListsBase} from "./TopicListsBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";

/// @notice Measurements of the first-statement lists (docs/TAG-NUMBERS.md tables A, C, D and the batch capacity) on
///         the real Files Realm: the real `topic-word/1` and `topic/1` Types, `FilesFinalValidator` and the
///         generation-1 index with its topic lists. Every measured publication is cooled first (each pays the cold
///         costs of a transaction of its own), native lane, by an author that has written before. Logs `tl <row>`:
///         `exec` = the execute frame's regular gas, `state` = its EIP-8037 state gas (zero on prague), `all` =
///         exec + state, `tx` = all + 21,000 + the calldata's standard cost (the transaction's gas), `txexec` = exec
///         + 21,000 + calldata (the quantity the EIP-7825 cap counts on Glamsterdam's execution-only reading).
///         Run under the default profile (prague, the release bytes) and under `FOUNDRY_PROFILE=amsterdam` with its
///         own out/ and cache/ (never the default `out/`).
contract TagListsMeasureTest is TopicListsBase {
    uint256 internal constant N = 160;
    uint256 internal constant CAP = 1 << 24;
    address internal constant X = address(0xA0001);
    address internal constant Y = address(0xA0002);

    address[] internal cold;
    bytes32[N] internal s; // CREATE subjects of p: the tagged things

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 13; ++i) {
            cold.push(instances[i]);
        }
        cold.push(refuseAll);
        cold.push(address(validator));
        cold.push(address(r.k.ingress));
        cold.push(address(r.k.applyDelegate));
        cold.push(address(r.k.control));
        cold.push(address(r.k.implementation));
        cold.push(r.k.proxy);
        cold.push(address(r.g.posting));
        cold.push(address(r.g.bitmap));
        cold.push(address(r.g.index));
        cold.push(address(r.g.reads));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        cold.push(address(r.store));
        for (uint256 from; from < N; from += 32) {
            Action[] memory a = new Action[](32);
            for (uint256 i; i < 32; ++i) {
                a[i] = _create(keccak256(abi.encode("measure/thing", from + i)));
                s[from + i] = Keys.subject(p, a[i].saltOrStrength);
            }
            _go(address(this), a);
        }
        // X and Y have written before (a lone negative each on a warm-up topic), so no row pays a first write
        bytes32 warm = _chain("warm", 1)[0];
        _go(X, _one(EfsTopics.deny(warm, _addr("warm"), 0, 0)));
        _go(Y, _one(EfsTopics.deny(warm, _addr("warm"), 0, 0)));
    }

    /// An address-shaped role (top 96 bits zero): something a first "not this" may name without any history, and
    /// the validator's cheapest admitted role (validator code 15).
    function _addr(bytes memory label) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(label)))));
    }

    // ---- publications --------------------------------------------------------------------------------------------

    function _nctx(address who, Action[] memory a) internal view returns (Native memory c) {
        (c.nonce,) = r.hot.nonceOf(_pid(who));
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

    /// `a` in publications of at most 64 actions (unmeasured).
    function _goChunked(address who, Action[] memory a) internal {
        for (uint256 from; from < a.length; from += 64) {
            uint256 m = a.length - from < 64 ? a.length - from : 64;
            Action[] memory x = new Action[](m);
            for (uint256 i; i < m; ++i) {
                x[i] = a[from + i];
            }
            _go(who, x);
        }
    }

    struct G {
        uint256 exec;
        uint256 state;
        uint256 all;
        uint256 txAll;
        uint256 txExec;
    }

    function _calldataCost(bytes memory cd) internal pure returns (uint256 c) {
        for (uint256 i; i < cd.length; ++i) {
            c += cd[i] == 0 ? 4 : 16;
        }
    }

    /// One cooled publication by `who`; never logs.
    function _measure(address who, Action[] memory a) internal returns (G memory g) {
        bytes[] memory b = new bytes[](a.length);
        Native memory c = _nctx(who, a);
        uint256 extra =
            21_000 + _calldataCost(abi.encodeCall(ILedger.execute, (a, b, c, bytes(""))));
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
        if (who != address(this)) vm.prank(who, who);
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        g.exec = f.gasTotalUsed;
        g.state = f.gasStateUsed > 0 ? uint256(int256(f.gasStateUsed)) : 0;
        g.all = g.exec + g.state;
        g.txAll = g.all + extra;
        g.txExec = g.exec + extra;
    }

    function _log(string memory row, G memory g) internal {
        emit log_named_uint(string.concat("tl ", row, " exec"), g.exec);
        if (g.state != 0) emit log_named_uint(string.concat("tl ", row, " state"), g.state);
        emit log_named_uint(string.concat("tl ", row, " all"), g.all);
        emit log_named_uint(string.concat("tl ", row, " tx"), g.txAll);
        if (g.state != 0) emit log_named_uint(string.concat("tl ", row, " txexec"), g.txExec);
    }

    // ---- topics and statements ---------------------------------------------------------------------------------------

    /// A chain of `n` topics, every level a new word (t[0] the word page `<name>-0`), registered unmeasured.
    function _chain(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        t = _regPath(name, n);
    }

    /// A chain of `n` topics over one repeated word (the walk does not care which word a level holds): the page, then
    /// the path records, 64 per publication.
    function _deepChain(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        EfsTopics.Types memory tt = _topicTypes();
        t = new bytes32[](n);
        bytes memory w = bytes(name);
        (Action[] memory a, bytes[] memory b, bytes32 page) = EfsTopics.registerWord(tt, w);
        _go(address(this), a, b);
        t[0] = page;
        for (uint256 from = 1; from < n; from += 64) {
            uint256 m = n - from < 64 ? n - from : 64;
            a = new Action[](m);
            b = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                b[i] = EfsTopics.pathBody(t[from + i - 1], page);
                a[i].kind = ActionKind.PUBLISH;
                a[i].typeId = tt.topic;
                a[i].bodyHashOrRecordId = keccak256(b[i]);
                t[from + i] = Keys.record(tt.topic, b[i]);
            }
            _go(address(this), a, b);
        }
    }

    function _stmts(bytes32 topic, uint256 from, uint256 n, bool deny)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = deny
                ? EfsTopics.deny(topic, s[from + i], 0, 0)
                : EfsTopics.tag(topic, s[from + i], 0, 0);
        }
    }

    function _tags(bytes32 topic, uint256 from, uint256 n) internal view returns (Action[] memory) {
        return _stmts(topic, from, n, false);
    }

    function _n(uint256 n) internal pure returns (string memory) {
        return vm.toString(n);
    }

    // =============================================================================================
    // A. one first statement on an n-word topic, four cases, alone and per extra one in a batch of 10
    // =============================================================================================

    /// Prepares case `c` on `topic` and returns the measured publication's author and statements (`k` of them):
    /// (i) everything new; (ii) the author's lists and the shared lists exist (6 entries), the position is new;
    /// (iii) the position exists (p stated it first), the author's (X's) roll-up lists are new; (iv) everything
    /// exists: the position has two authors already and X's lists hold 6 entries.
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

    function _tableA(bool deny) internal {
        bytes32[] memory t = _chain(deny ? "neg" : "pos", 64);
        string memory kind = deny ? "deny" : "tag";
        uint256[7] memory depths = [uint256(1), 2, 4, 8, 16, 32, 64];
        for (uint8 c = 1; c <= 4; ++c) {
            for (uint256 d; d < 7; ++d) {
                uint256 n = depths[d];
                string memory row = string.concat("A ", kind, " case ", _n(c), " n ", _n(n), " ");
                uint256 snap = vm.snapshotState();
                (address who, Action[] memory a) = _case(c, t[n - 1], 1, deny);
                G memory one = _measure(who, a);
                _log(string.concat(row, "k1"), one);
                vm.revertToState(snap);
                (who, a) = _case(c, t[n - 1], 10, deny);
                G memory ten = _measure(who, a);
                _log(string.concat(row, "k10"), ten);
                vm.revertToState(snap);
                emit log_named_uint(
                    string.concat("tl ", row, "per extra all"), (ten.all - one.all) / 9
                );
                if (ten.state != 0) {
                    emit log_named_uint(
                        string.concat("tl ", row, "per extra exec"), (ten.exec - one.exec) / 9
                    );
                }
            }
        }
    }

    function test_A_tag() public {
        _tableA(false);
    }

    function test_A_deny() public {
        _tableA(true);
    }

    // =============================================================================================
    // C. the deepest topic whose single first statement fits one transaction (2^24)
    // =============================================================================================

    uint256 internal constant DEEP_MAX = 2048;

    /// Prefill every depth shares, stated once on the deepest topic of the chain (its ancestors are every shallower
    /// topic's ancestors, so the roll-up lists of every shallower topic exist).
    function _prefillDeep(uint8 c, bytes32 deepest) internal {
        if (c == 2) {
            _go(address(this), _tags(deepest, 0, 2));
        } else if (c == 4) {
            // the later statements at the existing position are nos, so the prefill files at every level of the
            // deep chain once per position (a later first yes would file again)
            _go(address(this), _tags(deepest, 0, 1));
            _go(Y, _stmts(deepest, 0, 1, true));
            Action[] memory x = new Action[](2);
            x[0] = EfsTopics.deny(deepest, s[0], 0, 0);
            x[1] = EfsTopics.tag(deepest, s[1], 0, 0);
            _go(X, x);
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
        // Y's earlier statement is a no: it makes the position's second author without filing at every level of
        // the deep chain (a later first yes would), which keeps the suite under the default test gas limit
        _go(address(this), _tags(topic, 2, 1));
        _go(Y, _stmts(topic, 2, 1, true));
        return (X, _stmts(topic, 2, 1, deny));
    }

    /// The measured quantity: the transaction's gas (`execOnly`: its execution gas, amsterdam only).
    function _cost(bytes32 topic, uint8 c, bool deny, bool execOnly) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        (address who, Action[] memory a) = _caseAt(c, topic, deny);
        G memory g = _measure(who, a);
        vm.revertToState(snap);
        if (execOnly && g.state == 0) return type(uint256).max; // not a state-gas schedule
        return execOnly ? g.txExec : g.txAll;
    }

    /// The deepest topic whose single statement (case `c`) fits 2^24: predicted from the slope between depths 17 and
    /// 33, then measured by bisection between a depth that fits and one that does not.
    function _fit(uint8 c, bool deny, bool execOnly) internal {
        string memory row = string.concat(
            "C ", deny ? "deny" : "tag", " case ", _n(c), execOnly ? " exec-only" : " all-gas"
        );
        bytes32[] memory small =
            _deepChain(string.concat("c", _n(c), deny ? "d" : "t", execOnly ? "xs" : "as"), 34);
        _prefillDeep(c, small[33]);
        uint256 c17 = _cost(small[16], c, deny, execOnly);
        if (c17 == type(uint256).max) return; // execution-only rows exist on amsterdam only
        uint256 c33 = _cost(small[32], c, deny, execOnly);
        uint256 slope = (c33 - c17) / 16;
        emit log_named_uint(string.concat("tl ", row, " per level"), slope);
        uint256 n = c17 >= CAP ? 1 : 17 + (CAP - c17) / slope;
        require(n + 8 <= DEEP_MAX, "beyond the measured chain");
        uint256 len = n + 12; // room for the bisection to step past the prediction
        bytes32[] memory t =
            _deepChain(string.concat("c", _n(c), deny ? "d" : "t", execOnly ? "x" : "a"), len);
        _prefillDeep(c, t[len - 1]);
        uint256 hi = n + 1;
        uint256 lo = n - (n / 32 + 4);
        uint256 atLo = _cost(t[lo - 1], c, deny, execOnly);
        while (atLo > CAP) {
            hi = lo;
            lo = lo - (n / 32 + 4);
            atLo = _cost(t[lo - 1], c, deny, execOnly);
        }
        uint256 atHi = _cost(t[hi - 1], c, deny, execOnly);
        while (atHi <= CAP) {
            (lo, atLo) = (hi, atHi);
            hi += 4;
            require(hi < len, "beyond the measured chain");
            atHi = _cost(t[hi - 1], c, deny, execOnly);
        }
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 at = _cost(t[mid - 1], c, deny, execOnly);
            if (at <= CAP) (lo, atLo) = (mid, at);
            else (hi, atHi) = (mid, at);
        }
        emit log_named_uint(string.concat("tl ", row, " deepest"), lo);
        emit log_named_uint(string.concat("tl ", row, " at deepest"), atLo);
        emit log_named_uint(string.concat("tl ", row, " at deepest+1"), atHi);
    }

    function test_C_tag_case1() public {
        _fit(1, false, false);
        _fit(1, false, true);
    }

    function test_C_tag_case2() public {
        _fit(2, false, false);
        _fit(2, false, true);
    }

    function test_C_tag_case3() public {
        _fit(3, false, false);
        _fit(3, false, true);
    }

    function test_C_tag_case4() public {
        _fit(4, false, false);
        _fit(4, false, true);
    }

    function test_C_deny_case1() public {
        _fit(1, true, false);
        _fit(1, true, true);
    }

    function test_C_deny_case4() public {
        _fit(4, true, false);
        _fit(4, true, true);
    }

    // =============================================================================================
    // Batch capacity: how many first tags at depth n fit one publication (2^24, at most 64 actions)
    // =============================================================================================

    uint8 internal constant BEST = 1; // everything exists (case iv on one topic)
    uint8 internal constant ONE_NEW_PATH = 2; // one new path, every tag on its deepest topic (case i)
    uint8 internal constant OWN_NEW_PATHS = 3; // every tag on its own new path (everything new for each)

    bytes32[] internal _paths; // OWN_NEW_PATHS: the deepest topic of each new path

    function _batch(uint8 shape, bytes32 topic, uint256 k)
        internal
        view
        returns (address who, Action[] memory a)
    {
        if (shape == BEST) return (X, _tags(topic, 80, k));
        if (shape == ONE_NEW_PATH) return (address(this), _tags(topic, 0, k));
        a = new Action[](k);
        for (uint256 i; i < k; ++i) {
            a[i] = EfsTopics.tag(_paths[i], s[i], 0, 0);
        }
        return (address(this), a);
    }

    function _batchCost(uint8 shape, bytes32 topic, uint256 k, bool execOnly)
        internal
        returns (uint256)
    {
        uint256 snap = vm.snapshotState();
        (address who, Action[] memory a) = _batch(shape, topic, k);
        G memory g = _measure(who, a);
        vm.revertToState(snap);
        return execOnly ? g.txExec : g.txAll;
    }

    /// The largest k in 1..64 whose publication fits 2^24 (0 when even one does not), by bisection.
    function _capacity(string memory row, uint8 shape, bytes32 topic, bool execOnly) internal {
        uint256 lo;
        uint256 limit = shape == OWN_NEW_PATHS ? _paths.length : 64;
        uint256 hi = limit + 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_batchCost(shape, topic, mid, execOnly) <= CAP) lo = mid;
            else hi = mid;
        }
        emit log_named_uint(string.concat("tl ", row, " fit"), lo);
        if (lo != 0) {
            emit log_named_uint(
                string.concat("tl ", row, " at fit"), _batchCost(shape, topic, lo, execOnly)
            );
        }
        if (lo < limit) {
            emit log_named_uint(
                string.concat("tl ", row, " at fit+1"), _batchCost(shape, topic, lo + 1, execOnly)
            );
        } else {
            emit log_named_uint(string.concat("tl ", row, " limited by"), 64);
        }
    }

    function _capacities(string memory row, uint8 shape, bytes32 topic) internal {
        _capacity(string.concat(row, " all-gas"), shape, topic, false);
        if (_batchCost(shape, topic, 1, true) != _batchCost(shape, topic, 1, false)) {
            _capacity(string.concat(row, " exec-only"), shape, topic, true);
        }
    }

    function _bestPrefill(bytes32 topic) internal {
        // the position of every measured thing has two authors and X's lists exist (case iv for every k <= 64)
        _goChunked(address(this), _tags(topic, 80, 64));
        _goChunked(Y, _tags(topic, 80, 64));
        _goChunked(X, _tags(topic, 0, 6));
    }

    function test_batch_depth_64() public {
        bytes32[] memory t = _deepChain("bat64", 64);
        _bestPrefill(t[63]);
        _capacities("batch n 64 best", BEST, t[63]);
        bytes32[] memory fresh = _deepChain("bat64new", 64);
        _capacities("batch n 64 one new path", ONE_NEW_PATH, fresh[63]);
        for (uint256 i; i < 8; ++i) {
            _paths.push(_deepChain(string.concat("own64-", _n(i)), 64)[63]);
        }
        _capacities("batch n 64 own new paths", OWN_NEW_PATHS, 0);
    }

    function test_batch_depth_8() public {
        bytes32[] memory t = _deepChain("bat8", 8);
        _bestPrefill(t[7]);
        _capacities("batch n 8 best", BEST, t[7]);
        bytes32[] memory fresh = _deepChain("bat8new", 8);
        _capacities("batch n 8 one new path", ONE_NEW_PATH, fresh[7]);
        for (uint256 i; i < 64; ++i) {
            _paths.push(_deepChain(string.concat("own8-", _n(i)), 8)[7]);
        }
        _capacities("batch n 8 own new paths", OWN_NEW_PATHS, 0);
    }

    // =============================================================================================
    // D. what one list entry costs a spammer
    // =============================================================================================

    /// The cheapest statement that adds an entry: a lone negative (no target; an address-shaped role, which needs no
    /// history) on a fresh position, by an account that has written before, alone and per entry in a full
    /// publication of 64.
    function _spam(string memory row, address who, bytes32 topic) internal {
        Action[] memory a = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            a[i] = EfsTopics.deny(topic, _addr(abi.encode(row, i)), 0, 0);
        }
        uint256 snap = vm.snapshotState();
        _log(string.concat(row, " alone"), _measure(who, _one(a[0])));
        vm.revertToState(snap);
        G memory g = _measure(who, a);
        vm.revertToState(snap);
        emit log_named_uint(string.concat("tl ", row, " per entry of 64 tx"), g.txAll / 64);
        if (g.state != 0) {
            emit log_named_uint(string.concat("tl ", row, " per entry of 64 txexec"), g.txExec / 64);
        }
    }

    function test_D_spam() public {
        bytes32[] memory t = _chain("spam", 2);
        // a place that already has entries
        _go(address(this), _tags(t[0], 0, 4));
        _go(address(this), _tags(t[1], 0, 4));
        // place entry: a statement at a fresh position of a 1-word topic
        _spam("D place entry", X, t[0]);
        // place-below entry of the ancestor t[0]: a statement at a fresh position of its child t[1] (it also adds a
        // place entry at t[1] and a role-places and a position-authors list)
        _spam("D place-below entry", X, t[1]);
        // position-authors entry: each needs an author that never stated anything there, so a fresh account each
        // time: its first publication, one lone negative at an existing position
        address fresh = makeAddr("measure/spammer");
        _log(
            "D position-authors entry fresh account",
            _measure(fresh, _one(EfsTopics.deny(t[0], s[0], 0, 0)))
        );
        // the same by an account that has written before, for comparison
        _log(
            "D position-authors entry warm account",
            _measure(Y, _one(EfsTopics.deny(t[0], s[1], 0, 0)))
        );
    }

    /// One more `place` (and `place-below`) entry for an EXISTING position: a later author's first yes. Each author
    /// files at most once per position, so it takes a fresh account each time; one fresh account can file once at
    /// each of many existing positions. Alone (one first yes) and per entry of 64 (64 first yeses at 64 existing
    /// positions), the account's first publication.
    function _spamExisting(string memory row, bytes32 topic) internal {
        _goChunked(address(this), _tags(topic, 0, 64)); // 64 existing positions at the place
        uint256 snap = vm.snapshotState();
        address one = makeAddr(string.concat("measure/filer-one ", row));
        _log(string.concat(row, " alone"), _measure(one, _tags(topic, 0, 1)));
        vm.revertToState(snap);
        address many = makeAddr(string.concat("measure/filer-many ", row));
        G memory g = _measure(many, _tags(topic, 0, 64));
        vm.revertToState(snap);
        emit log_named_uint(string.concat("tl ", row, " per entry of 64 tx"), g.txAll / 64);
        if (g.state != 0) {
            emit log_named_uint(string.concat("tl ", row, " per entry of 64 txexec"), g.txExec / 64);
        }
    }

    function test_D_spam_existing_positions() public {
        bytes32[] memory t = _chain("spamx", 2);
        // a place entry: a first yes at an existing position of a 1-word topic (no ancestor)
        _spamExisting("D place entry existing position fresh account", t[0]);
        // a place entry and the ancestor's place-below entry: the same on the 2-word topic
        _spamExisting("D place-below entry existing position fresh account", t[1]);
    }

    // =============================================================================================
    // E. later transitions: a mask, a release and a restore (the yes-count of `position-authors`)
    // =============================================================================================

    /// X's asserted head at (purpose, subject, role) is masked, restored, released and restored again, each step a
    /// cooled publication of its own.
    function _transitions(
        string memory row,
        bytes32 purpose,
        bytes32 subject,
        bytes32 role,
        bytes32 target
    ) internal {
        _go(X, _one(_bind(purpose, subject, role, target, 0)));
        _log(
            string.concat(row, " mask asserted"),
            _measure(X, _one(EfsFiles.unbind(purpose, subject, role, 1)))
        );
        _log(
            string.concat(row, " restore from masked"),
            _measure(X, _one(_bind(purpose, subject, role, target, 2)))
        );
        _log(
            string.concat(row, " release asserted"),
            _measure(X, _one(EfsFiles.release(purpose, subject, role, 3)))
        );
        _log(
            string.concat(row, " restore from released"),
            _measure(X, _one(_bind(purpose, subject, role, target, 4)))
        );
        _log(
            string.concat(row, " mask of masked"),
            _measure(X, _one(EfsFiles.unbind(purpose, subject, role, 5)))
        );
    }

    function test_E_transitions() public {
        bytes32 topic = _chain("trans", 2)[1];
        _go(address(this), _tags(topic, 0, 1)); // the position exists (two authors after X)
        _transitions("E tag", Purpose.TAG, topic, s[0], s[0]);
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _name("trans.txt");
        _go(address(this), a, b);
        bytes32 home = bytes32(uint256(uint160(X)));
        _transitions("E folder", Purpose.FOLDER, home, keccak256("trans.txt"), s[1]);
    }
}
