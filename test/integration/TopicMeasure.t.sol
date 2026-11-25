// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {AcceptContext, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {TopicWordRule} from "../../src/profiles/TopicWordRule.sol";
import {TopicProbe} from "../profiles/TopicRules.t.sol";

/// @notice What topics, tags and statements about topics cost (design §12.5; docs/TAG-DESIGN.md §1, §2, §8), with
///         the validator's checks (a first tag's topic, SAME/BROADER ends, the HEAD law) in every row. Same harness as `TagNumberMeasure.t.sol`: every measured
///         publication is cooled (`vm.cool` over every contract the write path touches), native lane, both
///         expectations bound. Logs `topic <row> gas` (gasleft delta around `execute`), `frame gas` (the frame's
///         regular gas: under amsterdam it excludes EIP-8037 state gas, which is what EIP-7825's 2^24 cap counts)
///         and, under amsterdam, `frame state gas`. Path rows also log `tx estimate` (frame gas + 21,000 intrinsic +
///         calldata at 4/16 per zero/nonzero byte, the EIP-7623 floor ignored) and the transactions needed when the
///         registrations are split into consecutive chunks, each a valid publication on its own (parents first),
///         each at most `maxActions` (64) actions and at most the 2^24 cap.
contract TopicMeasureTest is FilesRecipesBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216; // EIP-7825 (tools/release.mjs TX_GAS_CAP)
    uint256 internal constant MAX_ACTIONS = 64; // KernelDeploy limits.maxActions

    address[] internal cold;
    TopicProbe internal probe;
    TopicWordRule internal wordRule;
    EfsTopics.Types internal tt;

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        for (uint256 i; i < TYPE_COUNT; ++i) {
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
        cold.push(address(r.store));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        Action[] memory a = new Action[](12);
        for (uint256 i; i < 12; ++i) {
            a[i] = _create(keccak256(abi.encode("measured thing", i)));
        }
        r.ledger.execute(a, new bytes[](12), _ctx(a), "");
        // the first record of each Topics Type opens that Type's by-type lists: pay it here, so every measured row
        // is a later record of its Type
        bytes[] memory sw = new bytes[](2);
        (sw[0], sw[1]) = (bytes("seed-a"), bytes("seed-b"));
        (Action[] memory seed, bytes[] memory seedB,) = EfsTopics.registerPath(tt, sw);
        Action[] memory text = new Action[](1);
        bytes[] memory textB = new bytes[](1);
        (text[0], textB[0]) = _publish(T_TEXT, "seed text");
        r.ledger.execute(seed, seedB, _ctx(seed), "");
        r.ledger.execute(text, textB, _ctx(text), "");
        probe = new TopicProbe();
        wordRule = new TopicWordRule();
    }

    function _wordPage(bytes memory word) internal view returns (Action memory a, bytes memory) {
        (a,) = _publish(T_TOPIC_WORD, word);
        return (a, word);
    }

    function _topicRecord(bytes32 parent, bytes32 page)
        internal
        view
        returns (Action memory a, bytes memory body)
    {
        body = EfsTopics.pathBody(parent, page);
        (a,) = _publish(T_TOPIC, body);
    }

    function _wordId(bytes memory word) internal view returns (bytes32) {
        return EfsTopics.wordPageId(tt.word, word);
    }

    /// The registrations of a path, parents first: every page when `withPages` (`EfsTopics.registerPath`), else
    /// only the n - 1 path records.
    function _pathActions(bytes[] memory words, bool withPages)
        internal
        view
        returns (Action[] memory a, bytes[] memory b, bytes32 id)
    {
        (a, b, id) = EfsTopics.registerPath(tt, words);
        if (withPages) return (a, b, id);
        uint256 n = words.length;
        (a, b) = _slice(a, b, n, n - 1);
    }

    function _thing(uint256 i) internal view returns (bytes32) {
        return Keys.subject(p, keccak256(abi.encode("measured thing", i)));
    }

    function _beforeExecute() internal override {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
    }

    function _silent(Action[] memory a, bytes[] memory b) internal {
        r.ledger.execute(a, b, _ctx(a), "");
    }

    struct Gas {
        uint256 used;
        uint256 frame;
        int256 state;
        uint256 txEstimate;
    }

    function _calldataGas(Action[] memory a, bytes[] memory b, Native memory c)
        internal
        pure
        returns (uint256 g)
    {
        bytes memory data = abi.encodeCall(ILedger.execute, (a, b, c, ""));
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// One cooled `execute`; logs and returns its gas.
    function _measure(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (Gas memory g)
    {
        Native memory c = _ctx(a);
        _beforeExecute();
        uint256 before = gasleft();
        r.ledger.execute(a, b, c, "");
        g.used = before - gasleft();
        Vm.Gas memory frame = vm.lastFrameGas();
        g.frame = frame.gasTotalUsed;
        g.state = frame.gasStateUsed;
        g.txEstimate = g.frame + 21_000 + _calldataGas(a, b, c);
        string memory l = string.concat("topic ", label);
        emit log_named_uint(string.concat(l, " gas"), g.used);
        emit log_named_uint(string.concat(l, " frame gas"), g.frame);
        if (g.state != 0) emit log_named_int(string.concat(l, " frame state gas"), g.state);
    }

    function _one(Action memory x, bytes memory y)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = x;
        b[0] = y;
    }

    // =============================================================================================
    // 1: one word page
    // =============================================================================================

    function _repeat(bytes memory unit, uint256 n) internal pure returns (bytes memory out) {
        for (uint256 i; i < n; ++i) {
            out = bytes.concat(out, unit);
        }
    }

    /// A word of `len` bytes, ASCII (`a-z`) or multi-byte (3-byte CJK scalars, then ASCII to the length);
    /// `variant` changes the first scalar so ten words of one shape are distinct.
    function _word(uint256 len, bool multi, uint256 variant)
        internal
        pure
        returns (bytes memory w)
    {
        if (!multi) {
            w = _repeat("q", len);
            w[0] = bytes1(uint8(0x61 + variant));
            return w;
        }
        uint256 scalars = len / 3;
        w = bytes.concat(_repeat(hex"e69db1", scalars), _repeat("q", len - scalars * 3));
        w[2] = bytes1(uint8(0x80 + variant));
    }

    function _wordRow(uint256 len, bool multi) internal {
        string memory tag = string.concat(multi ? "multi " : "ascii ", vm.toString(len), "B");
        bytes memory w = _word(len, multi, 0);
        assertEq(w.length, len);
        assertEq(probe.wordRefusal(w), 0, "admitted");
        (Action memory x, bytes memory y) = _wordPage(w);
        (Action[] memory a, bytes[] memory b) = _one(x, y);
        Gas memory g1 = _measure(string.concat("word ", tag, " k1"), a, b);
        a = new Action[](10);
        b = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            (a[i], b[i]) = _wordPage(_word(len, multi, i + 1));
        }
        Gas memory g10 = _measure(string.concat("word ", tag, " k10"), a, b);
        emit log_named_uint(
            string.concat("topic word ", tag, " per extra"), (g10.used - g1.used) / 9
        );
    }

    function test_1_word_page_ascii() public {
        _wordRow(5, false);
        _wordRow(12, false);
        _wordRow(40, false);
        _wordRow(255, false);
    }

    function test_1_word_page_multibyte() public {
        _wordRow(5, true);
        _wordRow(12, true);
        _wordRow(40, true);
        _wordRow(255, true);
    }

    /// The rule alone, by direct call: the grammar and the rule's `accept` per length; gas per byte from the 5- and
    /// 255-byte rows.
    function test_1_rule_gas_per_byte() public {
        bool[2] memory kinds = [false, true];
        uint256[4] memory lens = [uint256(5), 12, 40, 255];
        for (uint256 k; k < 2; ++k) {
            string memory cls = kinds[k] ? "multi" : "ascii";
            uint256[4] memory g;
            for (uint256 i; i < 4; ++i) {
                bytes memory w = _word(lens[i], kinds[k], 0);
                uint256 before = gasleft();
                probe.wordRefusal(w);
                g[i] = before - gasleft();
                string memory l = string.concat("topic rule ", cls, " ", vm.toString(lens[i]), "B");
                emit log_named_uint(string.concat(l, " wordRefusal() gas"), g[i]);
                emit log_named_uint(string.concat(l, " accept() gas"), _acceptGas(w));
            }
            emit log_named_uint(
                string.concat("topic rule ", cls, " per byte (x100)"), (g[3] - g[0]) * 100 / 250
            );
        }
    }

    function _acceptGas(bytes memory w) internal view returns (uint256 used) {
        AcceptContext memory c;
        c.typeId = tt.word;
        c.ledger = address(this);
        uint256 before = gasleft();
        wordRule.accept(c, w, new bytes32[](0), new RefHeader[](0));
        used = before - gasleft();
    }

    // =============================================================================================
    // 2: one topic/1 record
    // =============================================================================================

    function test_2_topic_record() public {
        // parent /base and leaf pages l0..l10, all already published
        Action[] memory a = new Action[](12);
        bytes[] memory b = new bytes[](12);
        (a[0], b[0]) = _wordPage("base");
        for (uint256 i; i < 11; ++i) {
            (a[i + 1], b[i + 1]) = _wordPage(abi.encodePacked("leaf", vm.toString(i)));
        }
        _silent(a, b);
        bytes32 base = _wordId("base");
        (Action memory x, bytes memory y) = _topicRecord(base, _wordId("leaf0"));
        (Action[] memory one, bytes[] memory oneB) = _one(x, y);
        Gas memory g1 = _measure("record k1", one, oneB);
        a = new Action[](10);
        b = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            (a[i], b[i]) = _topicRecord(base, _wordId(abi.encodePacked("leaf", vm.toString(i + 1))));
        }
        Gas memory g10 = _measure("record k10", a, b);
        emit log_named_uint("topic record per extra", (g10.used - g1.used) / 9);
        // a second registrant publishes the record that already exists (an occurrence bump)
        address bob = makeAddr("measure/bob");
        Native memory c;
        (c.nonce,) = r.hot.nonceOf(Keys.principal(bob));
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile = _ctx(one).expectedAcceptanceProfile;
        _beforeExecute();
        vm.prank(bob, bob);
        uint256 before = gasleft();
        r.ledger.execute(one, oneB, c, "");
        uint256 used = before - gasleft();
        Vm.Gas memory frame = vm.lastFrameGas();
        emit log_named_uint("topic record existing (second registrant) gas", used);
        emit log_named_uint(
            "topic record existing (second registrant) frame gas", frame.gasTotalUsed
        );
        if (frame.gasStateUsed != 0) {
            emit log_named_int(
                "topic record existing (second registrant) frame state gas", frame.gasStateUsed
            );
        }
        // the same author re-publishing an existing word page (for the word rule's re-run)
        (x, y) = _wordPage("base");
        (one, oneB) = _one(x, y);
        _measure("word existing (re-publish) k1", one, oneB);
    }

    // =============================================================================================
    // 3: a brand-new path of n words
    // =============================================================================================

    function _pathWords(uint256 n, string memory tag) internal pure returns (bytes[] memory w) {
        w = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = abi.encodePacked(tag, vm.toString(i)); // e.g. "pa12": 3..6 bytes
        }
    }

    function _slice(Action[] memory a, bytes[] memory b, uint256 from, uint256 k)
        internal
        pure
        returns (Action[] memory ca, bytes[] memory cb)
    {
        ca = new Action[](k);
        cb = new bytes[](k);
        for (uint256 i; i < k; ++i) {
            ca[i] = a[from + i];
            cb[i] = b[from + i];
        }
    }

    /// Whether `[from, from + k)` fits one transaction: at most 64 actions and a tx estimate within the cap.
    /// Probed on a snapshot that is reverted.
    function _fits(Action[] memory a, bytes[] memory b, uint256 from, uint256 k)
        internal
        returns (bool ok)
    {
        if (k > MAX_ACTIONS) return false;
        (Action[] memory ca, bytes[] memory cb) = _slice(a, b, from, k);
        uint256 snap = vm.snapshotState();
        Native memory c = _ctx(ca);
        _beforeExecute();
        try this.execRaw{gas: 500_000_000}(ca, cb, c) {
            Vm.Gas memory frame = vm.lastFrameGas();
            ok = frame.gasTotalUsed + 21_000 + _calldataGas(ca, cb, c) <= TX_GAS_CAP;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }

    function execRaw(Action[] calldata a, bytes[] calldata b, Native calldata c) external {
        require(msg.sender == address(this));
        r.ledger.execute(a, b, c, "");
    }

    function _pathRow(uint256 n, bool newPages) internal {
        string memory tag = string.concat(newPages ? "pa" : "pb", vm.toString(n), "x");
        bytes[] memory w = _pathWords(n, tag);
        if (!newPages) {
            Action[] memory pa = new Action[](n);
            bytes[] memory pb = new bytes[](n);
            for (uint256 i; i < n; ++i) {
                (pa[i], pb[i]) = _wordPage(w[i]);
            }
            for (uint256 from; from < n; from += 32) {
                uint256 k = n - from < 32 ? n - from : 32;
                (Action[] memory ca, bytes[] memory cb) = _slice(pa, pb, from, k);
                _silent(ca, cb);
            }
        }
        (Action[] memory a, bytes[] memory b, bytes32 id) = _pathActions(w, newPages);
        string memory l =
            string.concat("path n=", vm.toString(n), newPages ? " all new" : " pages exist");
        emit log_named_uint(string.concat("topic ", l, " actions"), a.length);
        uint256 txs = a.length == 0 ? 0 : _chunksMeasured(a, b, l);
        emit log_named_uint(string.concat("topic ", l, " txs"), txs);
        emit log_named_uint(string.concat("topic ", l, " fits one tx"), txs <= 1 ? 1 : 0);
        (bytes32 t, uint64 first,,,) = r.hot.recordHeader(id);
        assertTrue(first != 0 && (t == tt.topic || t == tt.word));
    }

    /// Greedy consecutive chunks, each the longest prefix that fits (probed on reverted snapshots), landed one by one
    /// with each chunk's measured gas logged; returns the number of transactions.
    function _chunksMeasured(Action[] memory a, bytes[] memory b, string memory l)
        internal
        returns (uint256 txs)
    {
        uint256 from;
        uint256 sumUsed;
        uint256 sumFrame;
        int256 sumState;
        while (from < a.length) {
            uint256 lo = 1;
            uint256 hi = a.length - from < MAX_ACTIONS ? a.length - from : MAX_ACTIONS;
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                if (_fits(a, b, from, mid)) lo = mid;
                else hi = mid - 1;
            }
            (Action[] memory ca, bytes[] memory cb) = _slice(a, b, from, lo);
            Gas memory g = _measure(
                string.concat(
                    l, " chunk ", vm.toString(txs + 1), " (", vm.toString(lo), " actions)"
                ),
                ca,
                cb
            );
            sumUsed += g.used;
            sumFrame += g.frame;
            sumState += g.state;
            from += lo;
            ++txs;
        }
        emit log_named_uint(string.concat("topic ", l, " total gas"), sumUsed);
        emit log_named_uint(string.concat("topic ", l, " total frame gas"), sumFrame);
        if (sumState != 0) {
            emit log_named_int(string.concat("topic ", l, " total frame state gas"), sumState);
        }
    }

    function test_3_path_all_new() public {
        uint256[4] memory ns = [uint256(2), 4, 8, 16];
        for (uint256 i; i < ns.length; ++i) {
            _pathRow(ns[i], true);
        }
    }

    function test_3_path_all_new_32() public {
        _pathRow(32, true);
    }

    function test_3_path_all_new_64() public {
        _pathRow(64, true);
    }

    function test_3_path_pages_exist() public {
        uint256[4] memory ns = [uint256(2), 4, 8, 16];
        for (uint256 i; i < ns.length; ++i) {
            _pathRow(ns[i], false);
        }
    }

    function test_3_path_pages_exist_32() public {
        _pathRow(32, false);
    }

    function test_3_path_pages_exist_64() public {
        _pathRow(64, false);
    }

    // =============================================================================================
    // 4: first tags
    // =============================================================================================

    function test_4_first_tags() public {
        // a registered topic /cars/tesla and a registered parent for a new leaf
        bytes[] memory w = new bytes[](2);
        w[0] = "cars";
        w[1] = "tesla";
        (Action[] memory reg, bytes[] memory regB, bytes32 topic) = _pathActions(w, true);
        _silent(reg, regB);
        // the topic's first member already exists, so the rows below are later members of the scope
        _silent(_tagOnly(topic, 11, 0), new bytes[](1));

        _measure("tag first on a registered topic", _tagOnly(topic, 1, 0), new bytes[](1));

        // a new leaf /cars/tesla/model-3 (page + topic record) and the first tag on it, one publication
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        (a[0], b[0]) = _wordPage("model-3");
        (a[1], b[1]) = _topicRecord(topic, _wordId("model-3"));
        bytes32 leaf = EfsTopics.childId(tt.topic, topic, _wordId("model-3"));
        a[2] = _bind(Purpose.TAG, leaf, _thing(2), _thing(2), 0);
        _measure("tag first + new leaf (page + record) in one publication", a, b);
        // the same with the leaf's word page already published (record + tag)
        Action[] memory pa = new Action[](1);
        bytes[] memory pb = new bytes[](1);
        (pa[0], pb[0]) = _wordPage("model-y");
        _silent(pa, pb);
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) = _topicRecord(topic, _wordId("model-y"));
        leaf = EfsTopics.childId(tt.topic, topic, _wordId("model-y"));
        a[1] = _bind(Purpose.TAG, leaf, _thing(3), _thing(3), 0);
        _measure("tag first + new leaf (record only) in one publication", a, b);

        // an ADDRESS target (never transacted), on the registered topic
        bytes32 addr = bytes32(uint256(uint160(makeAddr("measure/phisher"))));
        Action[] memory t = new Action[](1);
        t[0] = _bind(Purpose.TAG, topic, addr, addr, 0);
        _measure("tag first on an address target", t, new bytes[](1));

        // a home subject (no record read), target a created subject
        bytes32 home = bytes32(uint256(uint160(makeAddr("measure/home"))));
        _silent(_one2(_bind(Purpose.TAG, home, _thing(10), _thing(10), 0)), new bytes[](1));
        t[0] = _bind(Purpose.TAG, home, _thing(4), _thing(4), 0);
        _measure("tag first with a home subject", t, new bytes[](1));
    }

    function _tagOnly(bytes32 topic, uint256 i, uint64 rev)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](1);
        a[0] = _bind(Purpose.TAG, topic, _thing(i), _thing(i), rev);
    }

    function _one2(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    // =============================================================================================
    // 6: text, labels, relations
    // =============================================================================================

    function test_6_text_label_and_relations() public {
        (Action memory x, bytes memory y) = _publish(T_TEXT, "A label of 24 bytes long");
        (Action[] memory a, bytes[] memory b) = _one(x, y);
        _measure("text record 24B k1", a, b);
        bytes[] memory w = new bytes[](2);
        (w[0], w[1]) = (bytes("cars"), bytes("tesla"));
        (Action[] memory reg, bytes[] memory regB, bytes32 topic) = _pathActions(w, true);
        _silent(reg, regB);
        // a label: PUBLISH text/1 + BIND PROPERTY (topic, label:en) -> the text, one publication
        (a, b,) = EfsTopics.label(tt, topic, "en", "Tesla, Inc.", 0);
        _measure("label (new text + PROPERTY bind)", a, b);
        // a second language naming an existing text: the PROPERTY bind alone
        bytes32 text = EfsTopics.recordId(tt.text, "Tesla, Inc.");
        a = new Action[](1);
        a[0] = EfsTopics.property(topic, EfsTopics.labelKey("de"), text, 0);
        _measure("label (existing text, PROPERTY bind only)", a, new bytes[](1));
        // relations: SAME word-word, BROADER path-word (two topic reads each)
        bytes32 cars = _wordId("cars");
        bytes32 tesla = _wordId("tesla");
        a[0] = EfsTopics.same(tesla, cars, 0);
        _measure("same (word - word)", a, new bytes[](1));
        a[0] = EfsTopics.broader(topic, cars, 0);
        _measure("broader (path - word)", a, new bytes[](1));
    }

    // =============================================================================================
    // 7: a file attached to a home against one in a folder
    // =============================================================================================

    function test_7_file_at_a_home_and_in_a_folder() public {
        EfsFiles.Types memory t;
        t.root = typeIds[T_ROOT];
        t.directory = typeIds[T_DIRECTORY];
        t.name = typeIds[T_NAME];
        (Action[] memory a, bytes[] memory b, bytes32 folder) =
            EfsFiles.createFolder(t, p, rootDir, keccak256("measure/folder"), "folder", true);
        _silent(a, b);
        // the name record exists for both rows, and both are the first entry of a fresh scope
        bytes32 home = bytes32(uint256(uint160(makeAddr("measure/home-owner"))));
        (a, b,,) = EfsFiles.createFile(t, p, folder, keccak256("f1"), "folder", "same bytes", false);
        _measure("file create in a folder (first entry)", a, b);
        (a, b,,) = EfsFiles.createFile(t, p, home, keccak256("f2"), "folder", "same bytes", false);
        _measure("file create at a home (first entry)", a, b);
        // a later entry of each scope under another existing name
        (Action memory nm, bytes memory nb) = _name("second");
        (a, b) = _one(nm, nb);
        _silent(a, b);
        (a, b,,) = EfsFiles.createFile(t, p, folder, keccak256("f3"), "second", "same bytes", false);
        _measure("file create in a folder (later entry)", a, b);
        (a, b,,) = EfsFiles.createFile(t, p, home, keccak256("f4"), "second", "same bytes", false);
        _measure("file create at a home (later entry)", a, b);
    }

    // =============================================================================================
    // 5: the event's own price (the kernel rows are TagNumberMeasure's, compared across commits)
    // =============================================================================================

    /// The raw log the event is: LOG4 (signature + 3 indexed topics) with 192 data bytes, in this frame. The kernel's
    /// extra work around it (reading the fields, ABI-encoding) is the A/B difference of the TagNumberMeasure rows
    /// before and after the event commit.
    function test_5_bound_event_price() public {
        uint256 a = gasleft();
        assembly ("memory-safe") {
            log4(0, 192, 1, 2, 3, 4)
        }
        uint256 b = gasleft();
        emit log_named_uint("topic Bound-shaped LOG4 with 192 data bytes gas", a - b);
    }
}
