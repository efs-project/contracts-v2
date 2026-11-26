// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FloorBase} from "./FloorBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice The prefix floor P against what the index's callbacks spend before the final phase (E − K − the final
///         phase, `FloorBase`), in the two states a planned shape meets: (A) the author's lists are new
///         (`FloorPlan.t.sol`'s state) and (B) they exist (the ordinary case: the author already has files in the
///         folder, has already stated on the topic, has published before). The floor is a lower bound on the gas that
///         must be visible before each callback (design §10.4): P / spend ≥ 1 means a transaction the floor admits
///         reaches the end of the prefix callbacks. Each shape at one unit and at the planning rule's k
///         (test/vectors/floor-plan.json), on whichever profile runs.
///
///         State B for files is `test/index/HeadAuthorsFloor.t.sol`'s state before its "create file" (as the
///         index-build step 4 measurement uses it): bob's and carol's files in their homes, bob's version of carol's,
///         this principal's `mine.txt` and `masked.txt` in the root (the second masked). On amsterdam with a rewrite
///         priced at 5,000 its one-recipe ratio was 0.969 (the defect this suite pins: a cold rewrite costs 12,100 of
///         execution gas there, docs/GAS-SCHEDULES.md).
///
///         Relation to `FloorReconcile.t.sol` (index-build step 4): that suite measured the 0.969 and now asserts the
///         create-file recipe's P / spend ≥ 1 in the same two states (the same recipe, the same state B), with the
///         recipe's per-leaf split, the least gas that admits it against the plan and the sweep below it; this suite
///         asserts the rule over every shape the floor claims.
///
///         Deep first tags are not here: the floor does not know a topic's depth (design §10.4) and quotes them below
///         their spend by design; the gas model prices the walk.
contract FloorStatesTest is FloorBase {
    EfsTopics.Types internal tt;
    bytes32 internal topic;
    string internal json;
    address internal bob = makeAddr("floor-states/bob");
    address internal carol = makeAddr("floor-states/carol");

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        // FloorPlan.t.sol's setUp: one registered word
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerWord(tt, bytes("floor-plan"));
        _execAs(address(this), a, b);
        topic = id;
        json = vm.readFile("test/vectors/floor-plan.json");
    }

    function _k(string memory shape) internal view returns (uint256) {
        return vm.parseJsonUint(
            json,
            string.concat(".schedules.", _amsterdam() ? "amsterdam" : "prague", ".", shape, ".k")
        );
    }

    function _ft() internal view returns (EfsFiles.Types memory t) {
        t = EfsFiles.Types({
            root: typeIds[T_ROOT],
            child: typeIds[T_CHILD],
            directory: typeIds[T_DIRECTORY],
            name: typeIds[T_NAME],
            bytes_: typeIds[T_BYTES],
            content: typeIds[T_CONTENT],
            external_: typeIds[T_EXTERNAL],
            alias_: typeIds[T_ALIAS],
            notice: typeIds[T_NOTICE],
            span: typeIds[T_SPAN]
        });
    }

    /// FloorPlan.t.sol's create-file recipes: n files into the root, a 10-byte name and an 18-byte document each.
    function _recipes(string memory seed, uint256 n)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n * 5);
        b = new bytes[](n * 5);
        for (uint256 i; i < n; ++i) {
            bytes memory name = bytes.concat(
                "f", bytes1(uint8(97 + (i / 26) % 26)), bytes1(uint8(97 + i % 26)), "-doc.md"
            );
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                _ft(), p, rootDir, keccak256(abi.encode(seed, i)), name, "Meeting at 10:00.\n", true
            );
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _newFile(address who, string memory name) internal returns (bytes32 f, bytes32 root) {
        Action[] memory a;
        bytes[] memory b;
        bytes32 pid = who == address(this) ? p : Keys.principal(who);
        (a, b, f, root) = EfsFiles.createFile(
            _ft(),
            pid,
            who == address(this) ? rootDir : bytes32(uint256(uint160(who))),
            keccak256(bytes(name)),
            bytes(name),
            bytes(name),
            true
        );
        _execAs(who, a, b);
    }

    /// State B for files (see the contract NatSpec).
    function _filesExist() internal {
        _newFile(bob, "bob.txt");
        (bytes32 g, bytes32 gRoot) = _newFile(carol, "carol.txt");
        _execAs(bob, _one(EfsFiles.bind(Purpose.HEAD, g, 0, gRoot, 0)), new bytes[](1));
        _newFile(address(this), "mine.txt");
        (bytes32 k,) = _newFile(address(this), "masked.txt");
        (, uint64 rev,,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.HEAD, k, 0)));
        _execAs(address(this), _one(EfsFiles.unbind(Purpose.HEAD, k, 0, rev)), new bytes[](1));
    }

    /// P / spend × 1000 of `a` from the current state (logged under `label`), asserted ≥ `_minRatio()`.
    function _ratio(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 ratio)
    {
        Need memory w = _need(a, b, address(0));
        uint256 fin = _finalPhase(a, b, w.exec);
        uint256 spend = w.exec - w.kernel - fin;
        ratio = uint256(w.prefixFloor) * 1000 / spend;
        emit log_named_uint(string.concat("states ", label, " actions"), a.length);
        emit log_named_uint(string.concat("states ", label, " exec"), w.exec);
        emit log_named_uint(string.concat("states ", label, " kernel"), w.kernel);
        emit log_named_uint(string.concat("states ", label, " final phase"), fin);
        emit log_named_uint(string.concat("states ", label, " prefix spend"), spend);
        emit log_named_uint(string.concat("states ", label, " prefixFloor"), w.prefixFloor);
        emit log_named_uint(string.concat("states ", label, " visible needed"), w.visible);
        emit log_named_uint(string.concat("states ", label, " P / spend x1000"), ratio);
        assertGe(
            ratio,
            _minRatio(),
            string.concat(label, ": the prefix floor covers the callbacks' spend, with the margin")
        );
    }

    // ---- create-file recipes -------------------------------------------------------------------------------------

    function test_states_create_file_lists_new() public {
        (Action[] memory a, bytes[] memory b) = _recipes("floor-plan file", 1);
        _ratio("A create file x1", a, b);
        (a, b) = _recipes("floor-plan file", _k("createFiles"));
        _ratio("A create file xk", a, b);
    }

    function test_states_create_file_lists_exist() public {
        _filesExist();
        (Action[] memory a, bytes[] memory b,,) =
            EfsFiles.createFile(_ft(), p, rootDir, keccak256("new.txt"), "new.txt", "new.txt", true);
        _ratio("B create file x1 (new.txt)", a, b);
        (a, b) = _recipes("floor-plan file", 1);
        _ratio("B create file x1", a, b);
        (a, b) = _recipes("floor-plan file", _k("createFiles"));
        _ratio("B create file xk", a, b);
    }

    /// Edits in state B: a new files-child/1 of mine.txt's root and the HEAD re-bind (EfsFiles.edit), once and for
    /// ten files at once.
    function test_states_edits_lists_exist() public {
        _filesExist();
        uint256 n = 10;
        bytes32[] memory files = new bytes32[](n);
        bytes32[] memory roots = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (files[i], roots[i]) =
                _newFile(address(this), string(bytes.concat("ed-", bytes1(uint8(97 + i)), ".md")));
        }
        Action[] memory all = new Action[](2 * n);
        bytes[] memory bodies = new bytes[](2 * n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y,) =
                EfsFiles.edit(_ft(), files[i], roots[i], "Meeting at 11:00.\n", 1);
            (all[2 * i], bodies[2 * i]) = (x[0], y[0]);
            (all[2 * i + 1], bodies[2 * i + 1]) = (x[1], y[1]);
        }
        Action[] memory a1 = new Action[](2);
        bytes[] memory b1 = new bytes[](2);
        (a1[0], b1[0], a1[1], b1[1]) = (all[0], bodies[0], all[1], bodies[1]);
        _ratio("B edit x1", a1, b1);
        _ratio("B edit x10", all, bodies);
    }

    // ---- statements on a one-word topic ----------------------------------------------------------------------------

    function _thing(string memory seed, uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
    }

    function _denies(string memory seed, uint256 n) internal view returns (Action[] memory a) {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = EfsTopics.deny(topic, _thing(seed, i), 0, 0);
        }
    }

    function _tags(string memory seed, uint256 n) internal view returns (Action[] memory a) {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = EfsTopics.tag(topic, _thing(seed, i), 0, 0);
        }
    }

    function test_states_lone_negatives_lists_new() public {
        _ratio("A lone negatives x1", _denies("lone", 1), new bytes[](1));
        uint256 k = _k("loneNegatives");
        _ratio("A lone negatives xk", _denies("lone", k), new bytes[](k));
    }

    /// The author has already stated six lone negatives and six tags on the topic.
    function test_states_lone_negatives_lists_exist() public {
        _execAs(address(this), _denies("earlier", 6), new bytes[](6));
        _execAs(address(this), _tags("earlier tag", 6), new bytes[](6));
        _ratio("B lone negatives x1", _denies("lone", 1), new bytes[](1));
        uint256 k = _k("loneNegatives");
        _ratio("B lone negatives xk", _denies("lone", k), new bytes[](k));
    }

    /// First tags on the one-word topic after six earlier ones (a tag on a topic the author already tagged under).
    function test_states_first_tags_lists_exist() public {
        _execAs(address(this), _tags("earlier tag", 6), new bytes[](6));
        _ratio("B first tags x1", _tags("tag", 1), new bytes[](1));
        _ratio("B first tags x32", _tags("tag", 32), new bytes[](32));
    }

    // ---- publishes -------------------------------------------------------------------------------------------------

    /// A ten-byte name `<pre><3 letters>.txt`, distinct per i (< 26^3).
    function _nm(string memory pre, uint256 i) internal pure returns (bytes memory) {
        return bytes.concat(
            bytes(pre),
            bytes1(uint8(97 + (i / 676) % 26)),
            bytes1(uint8(97 + (i / 26) % 26)),
            bytes1(uint8(97 + i % 26)),
            ".txt"
        );
    }

    function _names(string memory pre, uint256 n)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n);
        b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (a[i], b[i]) = _name(_nm(pre, i));
        }
    }

    /// Fresh name records, after the author published six (and the files of state B).
    function test_states_name_records_lists_exist() public {
        _filesExist();
        (Action[] memory a, bytes[] memory b) = _names("ea-", 6);
        _execAs(address(this), a, b);
        (a, b) = _names("nr-", 1);
        _ratio("B name records x1", a, b);
        uint256 k = _k("nameRecords");
        (a, b) = _names("nr-", k);
        _ratio("B name records xk", a, b);
    }

    /// FloorPlan's publishesAndTags at its k, after six earlier tags on the topic and six names.
    function test_states_publishes_and_tags_lists_exist() public {
        _execAs(address(this), _tags("earlier tag", 6), new bytes[](6));
        (Action[] memory na, bytes[] memory nb) = _names("eb-", 6);
        _execAs(address(this), na, nb);
        uint256 k = _k("publishesAndTags");
        (na, nb) = _names("pt-", k);
        Action[] memory t = _tags("publishesAndTags", k);
        Action[] memory a = new Action[](2 * k);
        bytes[] memory b = new bytes[](2 * k);
        for (uint256 i; i < k; ++i) {
            (a[2 * i], b[2 * i]) = (na[i], nb[i]);
            a[2 * i + 1] = t[i];
        }
        _ratio("B publishes and tags xk", a, b);
    }
}
