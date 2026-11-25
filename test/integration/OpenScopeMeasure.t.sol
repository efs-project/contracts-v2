// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, PostingKey, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {OpenScopeConfig} from "../../src/interfaces/Index.sol";
import {IAcceptor, AcceptContext, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";
import {OpenScopeReader} from "../../src/readers/OpenScopeReader.sol";

/// SPIKE stand-in (tags-index): the topic Type's rule. Body: word 0 = parent topic id (0 = top level), word 1 = word
/// id, then anything; no references. Not a proposal for a topic Type: the parent pointer is a measurement device.
contract TopicStandInRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        require(ctx.ledger == msg.sender && refs.length == 0 && body.length >= 64, "topic");
        return IAcceptor.accept.selector;
    }
}

/// @notice SPIKE (tags-index) measurements of the all-authors families on the Files Realm, in the style of
///         `TagPathMeasure.t.sol`: every publication cooled (each pays what a transaction of its own pays), native
///         lane, logs `os <variant> <row> gas` (and `frame state gas` under the amsterdam profile). Each concrete
///         contract below is one index build (`OpenScopeConfig`); a row is measured only in the variants where it
///         means something. Topics are records of the test-only `TopicStandInRule` Type (SPIKE stand-in).
abstract contract OpenScopeMeasureBase is FilesRecipesBase {
    uint256 internal constant N = 64;
    uint8 internal constant V_EXACT = 1;
    uint8 internal constant V_SKIP_HEAD = 2;
    uint8 internal constant V_PATHS = 4;
    uint8 internal constant V_WORDS = 8;
    uint8 internal constant V_DIR = 16;

    address[] internal cold;
    bytes32[N] internal s; // CREATE subjects of p: the tagged things
    OpenScopeReader internal reader;
    address internal topicRule;
    bytes internal topicDescriptor;
    bytes32 internal topicType;
    mapping(address => uint64) internal nonces;

    function _variant() internal pure virtual returns (uint8);
    function _vname() internal pure virtual returns (string memory);

    function _openScope() internal virtual override returns (OpenScopeConfig memory os) {
        _topicType();
        uint8 v = _variant();
        os.exact = v & V_EXACT != 0;
        os.skipPurpose = v & V_SKIP_HEAD != 0 ? Purpose.HEAD : bytes32(0);
        os.topicTypeId = topicType;
        os.depthCap = 64;
        os.paths = v & V_PATHS != 0;
        os.words = v & V_WORDS != 0;
        os.directory = v & V_DIR != 0;
    }

    function _topicType() internal {
        if (topicRule != address(0)) return;
        bytes memory initcode = type(TopicStandInRule).creationCode;
        topicRule = Factory.deploy(initcode);
        FilesTypes.Spec memory spec = FilesTypes.bytesSpec();
        spec.name = "test/topic-stand-in/1";
        spec.description = "SPIKE stand-in: word 0 parent topic, word 1 word id";
        topicDescriptor =
            FilesTypes.encode(declarationKey, topicRule.codehash, keccak256(initcode), spec);
        topicType = FilesTypes.typeIdOf(topicDescriptor);
    }

    function setUp() public override {
        super.setUp();
        bytes memory sig = _declare(r.registry, topicType);
        r.store.put(topicDescriptor, sig);
        vm.prank(address(0xCAFE));
        (bytes32 got,) = r.registry.registerDescribed(topicDescriptor, sig, topicRule, "");
        require(got == topicType, "topic type");
        reader = new OpenScopeReader();
        for (uint256 i; i < 10; ++i) {
            cold.push(instances[i]);
        }
        cold.push(topicRule);
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

    function _run(string memory row, Action[] memory a) internal {
        _exec(_label(row), a, new bytes[](a.length));
    }

    function _runB(string memory row, Action[] memory a, bytes[] memory b) internal {
        _exec(_label(row), a, b);
    }

    function _silent(Action[] memory a) internal {
        r.ledger.execute(a, new bytes[](a.length), _ctx(a), "");
    }

    function _silentB(Action[] memory a, bytes[] memory b) internal {
        r.ledger.execute(a, b, _ctx(a), "");
    }

    /// Another author: an EOA key principal on the native lane.
    function _asAuthor(address who, Action[] memory a) internal {
        Native memory c;
        c.nonce = nonces[who]++;
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
        vm.prank(who, who);
        r.ledger.execute(a, new bytes[](a.length), c, "");
    }

    function _author(uint256 i) internal pure returns (address) {
        return address(uint160(0xA0000 + i));
    }

    // ---- statements and topics -------------------------------------------------------------------------------

    function _tags(bytes32 topic, uint256 from, uint256 n)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _bind(Purpose.TAG, topic, s[from + i], s[from + i], 0);
        }
    }

    function _denies(bytes32 topic, uint256 from, uint256 n)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, s[from + i], 0, 0);
        }
    }

    function _topicBody(bytes32 parent, bytes32 word, bytes32 salt)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(parent, word, salt);
    }

    function _topicAction(bytes32 parent, bytes32 word, bytes32 salt)
        internal
        view
        returns (Action memory a, bytes memory body, bytes32 id)
    {
        body = _topicBody(parent, word, salt);
        a.kind = ActionKind.PUBLISH;
        a.typeId = topicType;
        a.bodyHashOrRecordId = keccak256(body);
        id = Keys.record(topicType, body);
    }

    function _word(string memory chain, uint256 level) internal pure returns (bytes32) {
        return keccak256(abi.encode("word", chain, level));
    }

    /// Registers a chain of `n` topics (level 0 top), silently, 16 per publication; returns the ids.
    function _chain(string memory name, uint256 n, bytes32 parent)
        internal
        returns (bytes32[] memory ids)
    {
        ids = new bytes32[](n);
        for (uint256 from; from < n; from += 16) {
            uint256 m = n - from < 16 ? n - from : 16;
            Action[] memory a = new Action[](m);
            bytes[] memory b = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                (a[i], b[i], ids[from + i]) =
                    _topicAction(parent, _word(name, from + i), keccak256(bytes(name)));
                parent = ids[from + i];
            }
            _silentB(a, b);
        }
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _n(uint256 n) internal pure returns (string memory) {
        return vm.toString(n);
    }

    // ---- 1. family 6 on plain topics (every variant; Off is the baseline) -------------------------------------

    function test_exact_writes() public {
        bytes32 x = keccak256("measure/os/x");
        _run("assert entry 1 (first ever on a topic)", _tags(x, 0, 1));
        _run("assert entry 2", _tags(x, 1, 1));
        _silent(_tags(x, 2, 3));
        _run("assert entry 6", _tags(x, 5, 1));
        _silent(_tags(x, 6, 4));
        _run("assert entry 11", _tags(x, 10, 1));
        _run("assert entry 12", _tags(x, 11, 1));
        _run("assert k10 entries 13-22", _tags(x, 12, 10));
        _run("deny-unset k1 entry 23", _denies(x, 22, 1));
        _run("deny-unset k10 entries 24-33", _denies(x, 23, 10));
        bytes32 y = keccak256("measure/os/y");
        _run("deny-unset entry 1 (first ever on a topic)", _denies(y, 0, 1));
    }

    // ---- 2./5a. roll-up and words at depth --------------------------------------------------------------------

    function _depth(uint256 n) internal {
        if (!_on(V_PATHS) && !_on(V_WORDS)) return;
        string memory d = string.concat("depth ", _n(n), " ");
        bytes32[] memory c = _chain(string.concat("a", _n(n)), n, 0);
        bytes32 leaf = c[n - 1];
        _run(string.concat(d, "fresh lists k1"), _tags(leaf, 0, 1));
        _silent(_tags(leaf, 1, 5));
        _run(string.concat(d, "existing lists k1"), _tags(leaf, 6, 1));
        _run(string.concat(d, "existing lists k10"), _tags(leaf, 7, 10));
        _run(string.concat(d, "existing lists deny-unset k10"), _denies(leaf, 17, 10));
        bytes32[] memory c2 = _chain(string.concat("b", _n(n)), n, 0);
        _run(string.concat(d, "fresh lists k10"), _tags(c2[n - 1], 0, 10));
        bytes32[] memory c3 = _chain(string.concat("c", _n(n)), n, 0);
        _run(string.concat(d, "fresh lists deny-unset k1"), _denies(c3[n - 1], 0, 1));
    }

    function test_depth_01() public {
        _depth(1);
    }

    function test_depth_02() public {
        _depth(2);
    }

    function test_depth_04() public {
        _depth(4);
    }

    function test_depth_05() public {
        _depth(5);
    }

    function test_depth_08() public {
        _depth(8);
    }

    function test_depth_09() public {
        _depth(9);
    }

    function test_depth_16() public {
        _depth(16);
    }

    function test_depth_32() public {
        _depth(32);
    }

    function test_depth_64() public {
        _depth(64);
    }

    /// Paths: each tag of a batch on a different sibling under one parent at depth n (shared ancestor lists).
    function _siblings(uint256 n) internal {
        if (!_on(V_PATHS)) return;
        string memory d = string.concat("depth ", _n(n), " siblings ");
        bytes32[] memory c = _chain(string.concat("sib", _n(n)), n - 1, 0);
        bytes32 parent = c[n - 2];
        bytes32[] memory leaves = new bytes32[](12);
        Action[] memory a = new Action[](12);
        bytes[] memory b = new bytes[](12);
        for (uint256 i; i < 12; ++i) {
            (a[i], b[i], leaves[i]) =
                _topicAction(parent, _word(string.concat("sibleaf", _n(n)), i), bytes32(i));
        }
        _silentB(a, b);
        _silent(_tags(leaves[0], 0, 1)); // the ancestor lists exist
        _run(string.concat(d, "k1"), _one(_tags(leaves[1], 1, 1)[0]));
        Action[] memory t = new Action[](10);
        for (uint256 i; i < 10; ++i) {
            t[i] = _tags(leaves[2 + i], 2 + i, 1)[0];
        }
        _run(string.concat(d, "k10"), t);
    }

    function test_siblings_04() public {
        _siblings(4);
    }

    function test_siblings_08() public {
        _siblings(8);
    }

    function test_siblings_64() public {
        _siblings(64);
    }

    // ---- 3. reads ---------------------------------------------------------------------------------------------

    function _q(uint8 kind, bytes32 key, uint64 from, uint16 count, bool newest, bool dead)
        internal
        pure
        returns (OpenScopeReader.Query memory q)
    {
        q.kind = kind;
        q.purpose = Purpose.TAG;
        q.key = key;
        q.from = from;
        q.count = count;
        q.newestFirst = newest;
        q.minNumber = type(int16).min;
        q.includeDead = dead;
    }

    function _page(string memory row, OpenScopeReader.Query memory q) internal {
        _cool();
        uint256 before = gasleft();
        (uint64 len,, OpenScopeReader.Row[] memory rows) = reader.page(address(r.ledger), q);
        uint256 used = before - gasleft();
        emit log_named_uint(_label(string.concat(row, " gas")), used);
        emit log_named_uint(_label(string.concat(row, " rows")), rows.length);
        emit log_named_uint(_label(string.concat(row, " list length")), len);
        if (rows.length != 0) {
            emit log_named_uint(_label(string.concat(row, " gas per row")), used / rows.length);
        }
    }

    /// `authors` authors x 10 statements on `topic`; statement j of author i is a lone negative when j == i % 10.
    function _populate(bytes32 topic, uint256 authors) internal {
        for (uint256 i; i < authors; ++i) {
            Action[] memory a = new Action[](10);
            for (uint256 j; j < 10; ++j) {
                a[j] = j == i % 10
                    ? _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, s[j], 0, 0)
                    : _bind(Purpose.TAG, topic, s[j], s[j], 0);
            }
            _asAuthor(_author(i), a);
        }
    }

    function _readSet(string memory what, uint8 kind, bytes32 key) internal {
        _page(string.concat(what, " oldest page 10"), _q(kind, key, 0, 10, false, false));
        _page(string.concat(what, " oldest page 50"), _q(kind, key, 0, 50, false, false));
        _page(string.concat(what, " newest page 10"), _q(kind, key, 0, 10, true, false));
        _page(string.concat(what, " newest page 50"), _q(kind, key, 0, 50, true, false));
        _page(string.concat(what, " newest page 50 incl dead"), _q(kind, key, 0, 50, true, true));
    }

    function test_reads_exact() public {
        if (_variant() != V_EXACT) return;
        bytes32 x = keccak256("measure/os/read");
        _populate(x, 20); // 200 entries, 20 dead
        _cool();
        uint256 before = gasleft();
        (uint64 len,,,) = r.g.posting
            .postingHead(PostingKey.wrap(Keys.posting(0, 6, 0, Keys.openScope(Purpose.TAG, x))));
        emit log_named_uint(_label("read length (store postingHead, cold) gas"), before - gasleft());
        assertEq(len, 200);
        _readSet("exact 200", 6, x);
        _page("exact 200 middle page 50", _q(6, x, 75, 50, false, false));
    }

    function test_reads_below_and_word() public {
        if (!_on(V_PATHS | V_WORDS)) return;
        bytes32[] memory c = _chain("read4", 4, 0);
        _populate(c[3], 20);
        _readSet("below depth4 200", 7, c[0]);
        _readSet("word depth4 200", 9, _word("read4", 0));
        bytes32[] memory d = _chain("read64", 64, 0);
        _populate(d[63], 5);
        _readSet("below depth64 50", 7, d[0]);
        _readSet("word depth64 50", 9, _word("read64", 0));
    }

    // ---- 5b. the word directory --------------------------------------------------------------------------------

    function _register(uint256 n) internal {
        string memory d = string.concat("register leaf of ", _n(n), " words");
        bytes32 parent;
        if (n > 1) {
            bytes32[] memory c = _chain(string.concat("reg", _n(n)), n - 1, 0);
            parent = c[n - 2];
        }
        (Action memory a, bytes memory b,) =
            _topicAction(parent, _word(string.concat("reg", _n(n)), n - 1), "leaf");
        Action[] memory aa = new Action[](1);
        bytes[] memory bb = new bytes[](1);
        aa[0] = a;
        bb[0] = b;
        _runB(d, aa, bb);
    }

    function test_register() public {
        if (_variant() != 0 && _variant() != (V_EXACT | V_DIR)) return;
        _register(1);
        _register(4);
        _register(8);
        _register(16);
        _register(32);
        _register(64);
    }

    /// A whole brand-new 64-word path in one publication, then in prefix chunks.
    function test_register_path_64() public {
        if (_variant() != 0 && _variant() != (V_EXACT | V_DIR)) return;
        for (uint256 chunk = 64; chunk >= 8; chunk /= 2) {
            uint256 snap = vm.snapshotState();
            bytes32 parent;
            string memory name = string.concat("path64x", _n(chunk));
            for (uint256 from; from < 64; from += chunk) {
                Action[] memory a = new Action[](chunk);
                bytes[] memory b = new bytes[](chunk);
                for (uint256 i; i < chunk; ++i) {
                    bytes32 id;
                    (a[i], b[i], id) = _topicAction(parent, _word(name, from + i), "p");
                    parent = id;
                }
                Native memory c = _ctx(a);
                _cool();
                uint256 before = gasleft();
                try r.ledger.execute(a, b, c, "") {
                    emit log_named_uint(
                        _label(
                            string.concat(
                                "register 64-word path in chunks of ", _n(chunk), " chunk gas"
                            )
                        ),
                        before - gasleft()
                    );
                } catch (bytes memory err) {
                    emit log_named_bytes(
                        _label(
                            string.concat(
                                "register 64-word path in chunks of ", _n(chunk), " REFUSED"
                            )
                        ),
                        err
                    );
                    break;
                }
            }
            vm.revertToState(snap);
        }
    }

    /// Directory reads: k one-word paths share the word W, each path's list holds 10 tags.
    function test_directory_reads() public {
        if (_variant() != (V_EXACT | V_DIR)) return;
        bytes32 w = keccak256("measure/os/dir-word");
        bytes32[] memory topics = new bytes32[](26);
        Action[] memory a = new Action[](26);
        bytes[] memory b = new bytes[](26);
        for (uint256 i; i < 26; ++i) {
            bytes32 word = i < 1 ? w : i < 6 ? keccak256("w5") : keccak256("w20");
            (a[i], b[i], topics[i]) = _topicAction(0, word, bytes32(i));
        }
        _silentB(a, b);
        for (uint256 i; i < 26; ++i) {
            _silent(_tags(topics[i], 0, 10));
        }
        _dirRead("k1", w, topics, 0, 1);
        _dirRead("k5", keccak256("w5"), topics, 1, 5);
        _dirRead("k20", keccak256("w20"), topics, 6, 20);
    }

    function _dirRead(
        string memory k,
        bytes32 word,
        bytes32[] memory topics,
        uint256 from,
        uint256 n
    ) internal {
        _cool();
        uint256 before = gasleft();
        (uint64 len, bytes32[] memory got,) =
            reader.directory(address(r.ledger), topicType, word, 0, 64, true);
        uint256 used = before - gasleft();
        assertEq(len, n);
        assertEq(got.length, n);
        emit log_named_uint(_label(string.concat("directory ", k, " read gas")), used);
        before = gasleft();
        for (uint256 i; i < n; ++i) {
            (,, OpenScopeReader.Row[] memory rows) =
                reader.page(address(r.ledger), _q(6, topics[from + i], 0, 10, true, false));
            assertEq(rows.length, 10);
        }
        emit log_named_uint(
            _label(string.concat("directory ", k, " newest 10 of each list gas")),
            before - gasleft()
        );
    }

    // ---- 6. file operations and topic records ------------------------------------------------------------------

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
        if (_variant() > (V_EXACT | V_SKIP_HEAD)) return;
        (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRec) = _createFile(0);
        _runB("file create k1", a, b);
        (a, b,,) = _createFile(1);
        _runB("file create k1 (second)", a, b);
        Action[] memory batch = new Action[](50);
        bytes[] memory bodies = new bytes[](50);
        for (uint256 f; f < 10; ++f) {
            (a, b,,) = _createFile(2 + f);
            for (uint256 j; j < 5; ++j) {
                batch[5 * f + j] = a[j];
                bodies[5 * f + j] = b[j];
            }
        }
        _runB("file create k10", batch, bodies);
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) =
            _publish(T_CHILD, bytes.concat(abi.encode(rootRec, file, uint256(0)), "edited"));
        a[1] = _bind(Purpose.HEAD, file, 0, _id(T_CHILD, b[0]), 1);
        _runB("file edit (HEAD rebind)", a, b);
    }

    function test_topic_records() public {
        if (_variant() != 0) return;
        (Action memory x, bytes memory xb,) = _topicAction(0, keccak256("rec/w"), "one");
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        a[0] = x;
        b[0] = xb;
        _runB("topic record k1", a, b);
        a = new Action[](10);
        b = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            (a[i], b[i],) = _topicAction(0, keccak256(abi.encode("rec/w", i)), "ten");
        }
        _runB("topic record k10", a, b);
        // a second registrant publishes the first record again
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = x;
        b[0] = xb;
        Native memory c;
        c.nonce = nonces[_author(0)]++;
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
        _cool();
        vm.prank(_author(0), _author(0));
        uint256 before = gasleft();
        r.ledger.execute(a, b, c, "");
        emit log_named_uint(
            _label("topic record already exists (second registrant) gas"), before - gasleft()
        );
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

contract OpenScopeMeasureExact is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT;
    }

    function _vname() internal pure override returns (string memory) {
        return "exact";
    }
}

contract OpenScopeMeasureSkipHead is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT | V_SKIP_HEAD;
    }

    function _vname() internal pure override returns (string memory) {
        return "exact-skip-head";
    }
}

contract OpenScopeMeasurePaths is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT | V_PATHS;
    }

    function _vname() internal pure override returns (string memory) {
        return "paths";
    }
}

contract OpenScopeMeasureWords is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT | V_WORDS;
    }

    function _vname() internal pure override returns (string memory) {
        return "words";
    }
}

contract OpenScopeMeasureBoth is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT | V_PATHS | V_WORDS;
    }

    function _vname() internal pure override returns (string memory) {
        return "both";
    }
}

contract OpenScopeMeasureDir is OpenScopeMeasureBase {
    function _variant() internal pure override returns (uint8) {
        return V_EXACT | V_DIR;
    }

    function _vname() internal pure override returns (string memory) {
        return "dir";
    }
}
