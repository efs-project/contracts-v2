// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";

/// @notice The measurements behind `gas/model.json` (`tools/gas-model.mjs`): a per-action gas model for the SDK's
///         write planner. Every measured publication runs on the native lane through `FilesRecipesBase._exec`
///         (label `model <key>`, logging `gas`, `frame gas` and, under amsterdam, `frame state gas`) by a principal
///         that has written before (the setUp publications), except the first-write pair. Before each measured
///         `execute` every account the setUp touched is cooled (`vm.cool`), so each publication pays the cold
///         access costs of a transaction of its own; refunds (EIP-3529) are not applied, as in any frame
///         measurement. A marginal cost is `k2 − k1` of two publications of the same shape with distinct bodies;
///         `2·k1 − k2` is the fixed cost the shape implies. The `validate` publications are composites the script
///         predicts and never fits.
///
///         Every measured publication is also run once, from the same state and cooled the same way, with the index's
///         two callbacks answered by `vm.mockCall` (the acknowledgement word, no work): `<label> kernel frame gas` is
///         then the kernel's own execution gas with the callbacks removed (it still pays each callback's dispatch,
///         encoding and CALL, so it errs high by about 2k per action). It feeds `floor.<schedule>.kernel` in
///         `gas/model.json`, the kernel share the planning rule adds to the floor (design §10.4). The state is
///         reverted after that run, so the measured publication starts from the same state.
contract GasModelTest is FilesRecipesBase {
    uint256 internal constant N_SUBJECTS = 40;
    uint256 internal constant N_CHUNKS = 40;
    uint256 internal constant N_NAMES = 15;
    bytes32 internal TOPIC; // the word page "gas-model", registered by `_tagged` (a first tag needs a topic)

    address[] internal cold; // every account setUp touched (cooled before each measured execute)
    address internal sender; // the caller of the next measured execute (address(this) when zero)

    bytes32[N_SUBJECTS] internal s; // CREATE subjects of p
    bytes32[N_CHUNKS] internal c; // files-bytes/1 records, 64-byte bodies (32-byte payloads)
    bytes32[N_CHUNKS] internal cDigest; // their sha256 (word 0)
    bytes32 internal sentinel; // the empty files-bytes/1 record
    bytes32[3] internal sp; // files-span/1 records over c[30..36)
    bytes32[6] internal desc; // files-content/1 carrier 0 over c[34..40)
    bytes32 internal d1; // a folder of p (salt "d" 0)
    bytes32 internal d2; // a second folder of p (salt "d" 4)
    bytes32[3] internal dt; // folders of p (salts "d" 1..4), FOLDER targets
    bytes32[17] internal roots; // files-root/1 form 0 of s[5..17) at roots[5..17)
    bytes32[11] internal kids; // files-child/1 of roots[8..11) at kids[8..11) (HEAD rebind targets)

    // ---- setup ----------------------------------------------------------------------------------------------------

    function setUp() public override {
        filesTypesOnly = true; // the Topics Types are registered inside the rows that use them
        super.setUp();
        // the deployed Realm by name, then every account the setUp publications touch (recording the deployments
        // too would return their code and exhaust memory under the amsterdam cap)
        for (uint256 i; i < 10; ++i) {
            _remember(instances[i]);
        }
        _remember(refuseAll);
        _remember(address(validator));
        _remember(address(r.k.ingress));
        _remember(address(r.k.applyDelegate));
        _remember(address(r.k.control));
        _remember(address(r.k.implementation));
        _remember(r.k.proxy);
        _remember(address(r.g.posting));
        _remember(address(r.g.bitmap));
        _remember(address(r.g.index));
        _remember(address(r.store));
        _remember(address(r.registryImpl));
        _remember(address(r.registry));
        vm.startStateDiffRecording();
        _prepare();
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            _remember(acc[i].account);
            _remember(acc[i].accessor);
        }
    }

    function _remember(address a) internal {
        if (uint160(a) < 0x100 || a == address(vm) || a == address(this)) return;
        for (uint256 i; i < cold.length; ++i) {
            if (cold[i] == a) return;
        }
        cold.push(a);
    }

    function _beforeExecute() internal override {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
        if (sender != address(0)) vm.prank(sender, sender); // an EOA caller is its own origin
    }

    /// The kernel's own share of the publication about to be measured (see the contract NatSpec).
    function _beforeMeasure(
        string memory label,
        Action[] memory a,
        bytes[] memory b,
        Native memory c
    ) internal override {
        uint256 snap = vm.snapshotState();
        address index = address(r.g.index);
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.onAdmission.selector),
            abi.encode(IRealmIndex.onAdmission.selector)
        );
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.afterPublication.selector),
            abi.encode(IRealmIndex.afterPublication.selector)
        );
        _beforeExecute();
        r.ledger.execute(a, b, c, "");
        emit log_named_uint(
            string.concat(label, " kernel frame gas"), vm.lastFrameGas().gasTotalUsed
        );
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
    }

    /// Unmeasured publication of `p`.
    function _do(Action[] memory a, bytes[] memory b) internal {
        r.ledger.execute(a, b, _ctx(a), "");
    }

    function _salt(string memory tag, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("gas-model", tag, i));
    }

    function _payload(uint256 n, bytes32 seed) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) {
            bytes32 w = keccak256(abi.encode(seed, i));
            if (n - i < 32) w &= bytes32(~(type(uint256).max >> ((n - i) * 8)));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), i), w)
            }
        }
    }

    /// A valid `files-name/3` name of exactly `len` bytes (3 ≤ len ≤ 255), distinct per `i` (< 26^3).
    function _nm(uint256 i, uint256 len) internal pure returns (bytes memory n) {
        n = new bytes(len);
        for (uint256 j; j < len; ++j) {
            n[j] = "n";
        }
        n[len - 3] = bytes1(uint8(97 + (i / 676) % 26));
        n[len - 2] = bytes1(uint8(97 + (i / 26) % 26));
        n[len - 1] = bytes1(uint8(97 + i % 26));
    }

    function _bindName(uint256 i) internal pure returns (bytes memory) {
        return _nm(i, 12);
    }

    function _prepare() internal {
        // P1: CREATE s[0..40)
        Action[] memory a = new Action[](N_SUBJECTS);
        bytes[] memory b = new bytes[](N_SUBJECTS);
        for (uint256 i; i < N_SUBJECTS; ++i) {
            a[i] = _create(_salt("s", i));
            s[i] = Keys.subject(p, _salt("s", i));
        }
        _do(a, b);
        // P2: 40 chunks + the empty sentinel
        a = new Action[](N_CHUNKS + 1);
        b = new bytes[](N_CHUNKS + 1);
        for (uint256 i; i < N_CHUNKS; ++i) {
            bytes memory payload = _payload(32, _salt("c", i));
            cDigest[i] = sha256(payload);
            (a[i], b[i]) = _publish(T_BYTES, EfsFiles.bytesBody(payload));
            c[i] = _id(T_BYTES, b[i]);
        }
        (a[N_CHUNKS], b[N_CHUNKS]) = _publish(T_BYTES, EfsFiles.bytesBody(""));
        sentinel = _id(T_BYTES, b[N_CHUNKS]);
        _do(a, b);
        // P3: 3 spans, 6 carrier-0 descriptors, 5 directories
        a = new Action[](14);
        b = new bytes[](14);
        for (uint256 i; i < 3; ++i) {
            (a[i], b[i]) = _publish(T_SPAN, EfsFiles.spanBody(c[30 + 2 * i], c[31 + 2 * i], 64));
            sp[i] = _id(T_SPAN, b[i]);
        }
        for (uint256 i; i < 6; ++i) {
            (a[3 + i], b[3 + i]) =
                _publish(T_CONTENT, EfsFiles.contentBody(c[34 + i], 0, 32, cDigest[34 + i], ""));
            desc[i] = _id(T_CONTENT, b[3 + i]);
        }
        (a[9], b[9]) = _publish(T_DIRECTORY, EfsFiles.directoryBody(p, _salt("d", 0)));
        d1 = _id(T_DIRECTORY, b[9]);
        for (uint256 i; i < 3; ++i) {
            (a[10 + i], b[10 + i]) =
                _publish(T_DIRECTORY, EfsFiles.directoryBody(p, _salt("d", 1 + i)));
            dt[i] = _id(T_DIRECTORY, b[10 + i]);
        }
        (a[13], b[13]) = _publish(T_DIRECTORY, EfsFiles.directoryBody(p, _salt("d", 4)));
        d2 = _id(T_DIRECTORY, b[13]);
        _do(a, b);
        // P4: 15 bind names, roots of s[5..17)
        a = new Action[](N_NAMES + 12);
        b = new bytes[](N_NAMES + 12);
        for (uint256 i; i < N_NAMES; ++i) {
            (a[i], b[i]) = _name(_bindName(i));
        }
        for (uint256 i = 5; i < 17; ++i) {
            (a[N_NAMES + i - 5], b[N_NAMES + i - 5]) =
                _publish(T_ROOT, EfsFiles.rootBody(s[i], "setup v1"));
            roots[i] = _id(T_ROOT, b[N_NAMES + i - 5]);
        }
        _do(a, b);
        // P5: HEAD of s[8..11) + their children; FOLDER binds in d1 for rebind (names 6..9), unbind (9..12) and
        //     release (12..15), targets s[29..32)
        a = new Action[](15);
        b = new bytes[](15);
        for (uint256 i; i < 3; ++i) {
            a[i] = _bind(Purpose.HEAD, s[8 + i], 0, roots[8 + i], 0);
            (a[3 + i], b[3 + i]) =
                _publish(T_CHILD, EfsFiles.childBody(roots[8 + i], s[8 + i], "setup v2"));
            kids[8 + i] = _id(T_CHILD, b[3 + i]);
        }
        for (uint256 i; i < 9; ++i) {
            a[6 + i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(6 + i)), s[29 + i % 3], 0);
        }
        _do(a, b);
    }

    // ---- k = 1 and k = 2 of one shape ------------------------------------------------------------------------------

    function _pair(
        string memory key,
        Action[] memory a1,
        bytes[] memory b1,
        Action[] memory a2,
        bytes[] memory b2
    ) internal {
        _exec(string.concat("model ", key, " k1"), a1, b1);
        _exec(string.concat("model ", key, " k2"), a2, b2);
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

    function _two(Action memory x, bytes memory xb, Action memory y, bytes memory yb)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](2);
        b = new bytes[](2);
        a[0] = x;
        b[0] = xb;
        a[1] = y;
        b[1] = yb;
    }

    /// Three distinct bodies of one Type: k1 publishes the first, k2 the other two.
    function _publishPair(string memory key, uint8 t, bytes[3] memory bodies) internal {
        (Action memory x0, bytes memory y0) = _publish(t, bodies[0]);
        (Action memory x1, bytes memory y1) = _publish(t, bodies[1]);
        (Action memory x2, bytes memory y2) = _publish(t, bodies[2]);
        (Action[] memory a1, bytes[] memory b1) = _one(x0, y0);
        (Action[] memory a2, bytes[] memory b2) = _two(x1, y1, x2, y2);
        _pair(key, a1, b1, a2, b2);
    }

    /// Three actions without bodies: k1 executes the first, k2 the other two.
    function _actionPair(string memory key, Action[3] memory x) internal {
        (Action[] memory a1, bytes[] memory b1) = _one(x[0], "");
        (Action[] memory a2, bytes[] memory b2) = _two(x[1], "", x[2], "");
        _pair(key, a1, b1, a2, b2);
    }

    // ---- 1. new PUBLISH by Type --------------------------------------------------------------------------------------

    function _bytesPair(uint256 n) internal {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] =
                EfsFiles.bytesBody(_payload(n - 32, _salt(string.concat("b", vm.toString(n)), i)));
            assertEq(bodies[i].length, n);
        }
        _publishPair(string.concat("pub bytes ", vm.toString(n)), T_BYTES, bodies);
    }

    function test_model_publish_bytes_64() public {
        _bytesPair(64);
    }

    /// 100 and 1,000 bytes are not word multiples: with them the per-word and per-byte slopes are separable
    /// (on 64/1,024/4,096/8,192 alone `ceil(n/32) = n/32` and the two terms are collinear).
    function test_model_publish_bytes_100() public {
        _bytesPair(100);
    }

    function test_model_publish_bytes_1000() public {
        _bytesPair(1000);
    }

    function test_model_publish_bytes_1024() public {
        _bytesPair(1024);
    }

    function test_model_publish_bytes_4096() public {
        _bytesPair(4096);
    }

    function test_model_publish_bytes_8192() public {
        _bytesPair(8192);
    }

    function test_model_publish_span() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.spanBody(c[2 * i], c[2 * i + 1], 64);
        }
        _publishPair("pub span", T_SPAN, bodies);
    }

    function test_model_publish_content_carrier0() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.contentBody(c[6 + i], 0, 32, cDigest[6 + i], "");
            assertEq(bodies[i].length, 320);
        }
        _publishPair("pub content c0", T_CONTENT, bodies);
    }

    function test_model_publish_content_carrier2() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.contentBody(sp[i], 2, 64, _salt("claim", i), "");
        }
        _publishPair("pub content c2", T_CONTENT, bodies);
    }

    function _externalPair(uint256 len) internal {
        bytes memory locator = new bytes(len);
        bytes memory head = "ar://";
        for (uint256 j; j < len; ++j) {
            locator[j] = j < head.length ? head[j] : bytes1("A");
        }
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.externalBody(sentinel, 1000 + i, _salt("ext", i), locator, "");
            assertEq(bodies[i].length, 224 + len);
        }
        _publishPair(string.concat("pub external ", vm.toString(len)), T_EXTERNAL, bodies);
    }

    function test_model_publish_external_40() public {
        _externalPair(40);
    }

    function test_model_publish_external_400() public {
        _externalPair(400);
    }

    function test_model_publish_directory() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.directoryBody(p, _salt("pub-d", i));
            assertEq(bodies[i].length, 64);
        }
        _publishPair("pub directory", T_DIRECTORY, bodies);
    }

    function _namePair(uint256 len) internal {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = _nm(1000 + i, len);
        }
        _publishPair(string.concat("pub name ", vm.toString(len)), T_NAME, bodies);
    }

    function test_model_publish_name_12() public {
        _namePair(12);
    }

    function test_model_publish_name_200() public {
        _namePair(200);
    }

    function test_model_publish_root_form0() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.rootBody(s[17 + i], _payload(100, _salt("root0", i)));
            assertEq(bodies[i].length, 164);
        }
        _publishPair("pub root f0", T_ROOT, bodies);
    }

    function test_model_publish_root_form1() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.rootRefBody(s[20 + i], desc[i]);
        }
        _publishPair("pub root f1", T_ROOT, bodies);
    }

    function test_model_publish_child_form0() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] =
                EfsFiles.childBody(roots[11 + i], s[11 + i], _payload(100, _salt("child0", i)));
            assertEq(bodies[i].length, 196);
        }
        _publishPair("pub child f0", T_CHILD, bodies);
    }

    function test_model_publish_child_form1() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.childRefBody(roots[14 + i], s[14 + i], desc[3 + i]);
        }
        _publishPair("pub child f1", T_CHILD, bodies);
    }

    // ---- 2./3. existing PUBLISH, REUSE, CREATE ----------------------------------------------------------------------

    function test_model_publish_existing() public {
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsFiles.bytesBody(_payload(32, _salt("c", 20 + i)));
            assertEq(_id(T_BYTES, bodies[i]), c[20 + i]);
        }
        _publishPair("pub existing", T_BYTES, bodies);
    }

    function test_model_reuse() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i].kind = ActionKind.REUSE;
            x[i].typeId = typeIds[T_BYTES];
            x[i].bodyHashOrRecordId = c[23 + i];
        }
        _actionPair("reuse", x);
    }

    function test_model_create() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _create(_salt("fresh", i));
        }
        _actionPair("create", x);
    }

    // ---- 4./5. binds ------------------------------------------------------------------------------------------------

    function test_model_bind_head_fresh() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.HEAD, s[5 + i], 0, roots[5 + i], 0);
        }
        _actionPair("bind head fresh", x);
    }

    function test_model_bind_head_rebind() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.HEAD, s[8 + i], 0, kids[8 + i], 1);
        }
        _actionPair("bind head rebind", x);
    }

    function test_model_bind_folder_fresh_file() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(i)), s[26 + i], 0);
        }
        _actionPair("bind folder fresh file", x);
    }

    function test_model_bind_folder_fresh_dir() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(3 + i)), dt[i], 0);
        }
        _actionPair("bind folder fresh dir", x);
    }

    function test_model_bind_folder_rebind() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(6 + i)), s[32 + i], 1);
        }
        _actionPair("bind folder rebind", x);
    }

    function test_model_unbind_folder() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] =
                _bindKind(ActionKind.UNBIND, Purpose.FOLDER, d1, keccak256(_bindName(9 + i)), 0, 1);
        }
        _actionPair("unbind folder", x);
    }

    function test_model_release_folder() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bindKind(
                ActionKind.RELEASE, Purpose.FOLDER, d1, keccak256(_bindName(12 + i)), 0, 1
            );
        }
        _actionPair("release folder", x);
    }

    /// A restore of a folder entry: BIND from MASKED to the kept target (transition RESTORE). The entries (d1, names
    /// 0..3 → s[0..3)) are bound and masked unmeasured first, so each target is named by one entry, the ordinary case
    /// of a file in one folder: the restore's backlink append then takes a fresh word, as a tag restore's does.
    function test_model_restore_folder() public {
        Action[] memory m = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            m[i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(i)), s[i], 0);
        }
        _do(m, new bytes[](3));
        for (uint256 i; i < 3; ++i) {
            m[i] = _bindKind(ActionKind.UNBIND, Purpose.FOLDER, d1, keccak256(_bindName(i)), 0, 1);
        }
        _do(m, new bytes[](3));
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.FOLDER, d1, keccak256(_bindName(i)), s[i], 2);
        }
        _actionPair("restore folder", x);
    }

    bool internal _topicsRegistered;

    /// Registers the Topics Types (once), and their rule instances join the cooled set inside the rows that publish topics (`setUp` has no headroom
    /// for more state under the amsterdam cap, and the k1 row would otherwise warm them for k2).
    function _rememberTopics() internal {
        if (!_topicsRegistered) {
            _registerTopics(r);
            _topicsRegistered = true;
        }
        _remember(instances[T_TOPIC_WORD]);
        _remember(instances[T_TOPIC]);
        _remember(instances[T_TEXT]);
    }

    /// Registers TOPIC (the word page "gas-model"), then TAG binds of s[35..38) under it: the number-change targets
    /// and the lone negatives' scope. Run inside the row's own test, not `setUp`, whose amsterdam execution gas is
    /// at the EIP-7825 per-transaction cap.
    function _tagged() internal {
        _rememberTopics();
        (Action[] memory ra, bytes[] memory rb, bytes32 page) =
            EfsTopics.registerWord(_topicTypes(), "gas-model");
        TOPIC = page;
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        (a[0], b[0]) = (ra[0], rb[0]);
        for (uint256 i; i < 3; ++i) {
            a[1 + i] = _bind(Purpose.TAG, TOPIC, s[35 + i], s[35 + i], 0);
        }
        _do(a, b);
    }

    /// A first tag on a registered topic (FIRST_BIND; the validator reads the topic's header).
    function test_model_bind_tag_fresh() public {
        _tagged();
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.TAG, TOPIC, s[30 + i], s[30 + i], 0);
        }
        _actionPair("bind tag fresh", x);
    }

    /// A first tag by a second author on positions that exist (another author tagged them first): one `place` filing
    /// (appended UNCOUNTED to an existing list), no `role-places` entry, one `position-authors` entry on an existing
    /// list. The author has written before.
    function test_model_bind_tag_second_author() public {
        _tagged();
        address second = makeAddr("gas-model second author");
        _as(second);
        _send(second, _one1(_bind(Purpose.TAG, TOPIC, s[39], s[39], 0))); // unmeasured: writes once
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.TAG, TOPIC, s[35 + i], s[35 + i], 0);
        }
        _actionPair("bind tag second author", x);
        _as(address(0));
    }

    // ---- the per-level terms of a first tag (design §10.4) ----------------------------------------------------------

    /// The span of the level rows: k1 tags a 2-word topic (1 proper ancestor), k2 a 6-word topic (5), both from the
    /// same state (each measured, then rolled back), so `(k2 − k1) / LEVEL_SPAN` is one level of the walk.
    uint256 internal constant LEVEL_SPAN = 4;

    /// Publications of `who` (any principal): `p` follows it, so `_ctx` reads its nonce, and `sender` pranks it.
    function _as(address who) internal {
        if (who == address(0)) {
            p = Keys.principalFor(address(this), r.hot.realmOrigin());
            sender = address(0);
        } else {
            p = Keys.principalFor(who, r.hot.realmOrigin());
            sender = who;
        }
    }

    function _one1(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    /// An unmeasured publication of tags by `who` on `topic` of `things`.
    function _tagAll(address who, bytes32 topic, bytes32[] memory things) internal {
        _as(who);
        Action[] memory a = new Action[](things.length);
        for (uint256 i; i < things.length; ++i) {
            a[i] = _bind(Purpose.TAG, topic, things[i], things[i], 0);
        }
        _send(who, a);
        _as(address(0));
    }

    /// One unmeasured publication of `who` (p and the nonce already follow it): the context is read before the prank.
    function _send(address who, Action[] memory a) internal {
        Native memory c = _ctx(a);
        if (who != address(0) && who != address(this)) vm.prank(who, who);
        r.ledger.execute(a, new bytes[](a.length), c, "");
    }

    function _things2(uint256 i) internal view returns (bytes32[] memory t) {
        t = new bytes32[](2);
        t[0] = s[i];
        t[1] = s[i + 1];
    }

    /// The 6-word path `<name>-0/…/<name>-5` (11 publishes, one unmeasured publication), every prefix's id.
    function _levelPath(string memory name) internal returns (bytes32[] memory t) {
        _rememberTopics();
        EfsTopics.Types memory tt = _topicTypes();
        bytes[] memory w = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            w[i] = bytes(string.concat(name, "-", vm.toString(i)));
        }
        (Action[] memory a, bytes[] memory b,) = EfsTopics.registerPath(tt, w);
        _do(a, b);
        t = new bytes32[](6);
        t[0] = EfsTopics.wordPageId(tt.word, w[0]);
        for (uint256 i = 1; i < 6; ++i) {
            t[i] = EfsTopics.childId(tt.topic, t[i - 1], EfsTopics.wordPageId(tt.word, w[i]));
        }
    }

    /// k1 = `who` states t[1] about `thing`, k2 = `who` states t[5] about it, each from the current state: a first
    /// tag, or (`deny`) a first lone negative.
    function _levelPair(
        string memory key,
        address who,
        bytes32[] memory t,
        bytes32 thing,
        bool deny
    ) internal {
        _as(who);
        uint256 snap = vm.snapshotState();
        _exec(string.concat("model ", key, " k1"), _one1(_first(t[1], thing, deny)), new bytes[](1));
        vm.revertToState(snap);
        _exec(string.concat("model ", key, " k2"), _one1(_first(t[5], thing, deny)), new bytes[](1));
        vm.revertToState(snap);
        _as(address(0));
    }

    function _first(bytes32 topic, bytes32 thing, bool deny) internal pure returns (Action memory) {
        return deny
            ? EfsFiles.loneNegative(Purpose.TAG, topic, thing, 0)
            : _bind(Purpose.TAG, topic, thing, thing, 0);
    }

    address internal constant LEVEL_A = address(0xA11CE);
    address internal constant LEVEL_B = address(0xB0B);

    /// Both authors have written before (one unmeasured publication each, on another topic).
    function _levelAuthors(bytes32[] memory t) internal {
        bytes32[] memory one = new bytes32[](1);
        one[0] = s[0];
        _tagAll(LEVEL_A, t[0], one);
        _tagAll(LEVEL_B, t[0], one);
    }

    /// Fresh position, every list new: per level, a new per-author entry and a new shared entry.
    function test_model_tag_level_all_new() public {
        bytes32[] memory t = _levelPath("lvl-a");
        _levelAuthors(t);
        _levelPair("tag level all new", LEVEL_A, t, s[20], false);
    }

    /// Fresh position, every list existing (two or four entries, so the append rewrites an existing word).
    function test_model_tag_level_all_existing() public {
        bytes32[] memory t = _levelPath("lvl-b");
        _levelAuthors(t);
        _tagAll(LEVEL_A, t[1], _things2(21));
        _tagAll(LEVEL_A, t[5], _things2(21));
        _levelPair("tag level all existing", LEVEL_A, t, s[20], false);
    }

    /// Existing position (another author's), this author's roll-ups new: per level, a new per-author entry only. The
    /// measured statement is a first no, which files nothing in `place-below` (a later author's first yes also files
    /// there, which the composition rule prices with the shared terms).
    function test_model_tag_level_mine_new() public {
        bytes32[] memory t = _levelPath("lvl-c");
        _levelAuthors(t);
        bytes32[] memory one = new bytes32[](1);
        one[0] = s[20];
        _tagAll(LEVEL_A, t[1], one);
        _tagAll(LEVEL_A, t[5], one);
        _levelPair("tag level mine new", LEVEL_B, t, s[20], true);
    }

    /// Existing position, this author's roll-ups existing: per level, an existing per-author entry only (a first no,
    /// as above).
    function test_model_tag_level_mine_existing() public {
        bytes32[] memory t = _levelPath("lvl-d");
        _levelAuthors(t);
        bytes32[] memory one = new bytes32[](1);
        one[0] = s[20];
        _tagAll(LEVEL_A, t[1], one);
        _tagAll(LEVEL_A, t[5], one);
        _tagAll(LEVEL_B, t[1], _things2(21));
        _tagAll(LEVEL_B, t[5], _things2(21));
        _levelPair("tag level mine existing", LEVEL_B, t, s[20], true);
    }

    /// Composite (never fitted): a first tag on a fresh 6-word path, every list new.
    function test_model_validate_deep_tag() public {
        bytes32[] memory t = _levelPath("lvl-v");
        _levelAuthors(t);
        _as(LEVEL_A);
        _exec(
            "model validate tag 6 words all new",
            _one1(_bind(Purpose.TAG, t[5], s[20], s[20], 0)),
            new bytes[](1)
        );
        _as(address(0));
    }

    // ---- the Topics Types ----------------------------------------------------------------------------------------

    /// A valid `topic-word/1` word of exactly `len` bytes, distinct per `i` (`_nm`'s lowercase letters).
    function _topicWordPair(uint256 len) internal {
        _rememberTopics();
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = _nm(2000 + i, len);
        }
        _publishPair(string.concat("pub topic word ", vm.toString(len)), T_TOPIC_WORD, bodies);
    }

    function test_model_publish_topic_word_12() public {
        _topicWordPair(12);
    }

    function test_model_publish_topic_word_40() public {
        _topicWordPair(40);
    }

    /// Three `topic/1` records under one word page, each naming its own new word page (published unmeasured).
    function test_model_publish_topic() public {
        _rememberTopics();
        EfsTopics.Types memory t = _topicTypes();
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        bytes[3] memory bodies;
        for (uint256 i; i < 4; ++i) {
            b[i] = _nm(3000 + i, 12);
            (Action[] memory ra,,) = EfsTopics.registerWord(t, b[i]);
            a[i] = ra[0];
        }
        bytes32 parent = EfsTopics.wordPageId(t.word, b[0]);
        _do(a, b);
        for (uint256 i; i < 3; ++i) {
            bodies[i] = EfsTopics.pathBody(parent, EfsTopics.wordPageId(t.word, b[1 + i]));
        }
        _publishPair("pub topic", T_TOPIC, bodies);
    }

    function test_model_publish_text() public {
        _rememberTopics();
        bytes[3] memory bodies;
        for (uint256 i; i < 3; ++i) {
            bodies[i] = abi.encodePacked("Label ", _nm(4000 + i, 18));
            assertEq(bodies[i].length, 24);
        }
        _publishPair("pub text 24", T_TEXT, bodies);
    }

    /// A number change on an asserted tag: BIND to the same target with a new strength (0 -> 75), a REBIND.
    function test_model_bind_tag_number_change() public {
        _tagged();
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.bindWithStrength(Purpose.TAG, TOPIC, s[35 + i], s[35 + i], 1, 75);
        }
        _actionPair("bind tag number change", x);
    }

    /// A lone negative: UNBIND at a fresh position of an existing scope (FIRST_MASK), strength 4 (-5), about a file
    /// subject (the validator's most expensive admitted role: no record at the id, then the subject's creation).
    function test_model_unbind_tag_lone() public {
        _tagged();
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.loneNegative(Purpose.TAG, TOPIC, s[30 + i], 4);
        }
        _actionPair("unbind tag lone", x);
    }

    /// A mask of an asserted tag: UNBIND from BOUND at a TAG position (transition MASK).
    function test_model_unbind_tag() public {
        _tagged();
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.unbind(Purpose.TAG, TOPIC, s[35 + i], 1);
        }
        _actionPair("unbind tag", x);
    }

    /// A release of an asserted tag: RELEASE from BOUND at a TAG position.
    function test_model_release_tag() public {
        _tagged();
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.release(Purpose.TAG, TOPIC, s[35 + i], 1);
        }
        _actionPair("release tag", x);
    }

    /// A restore at a TAG position: BIND from MASKED to the kept target (transition RESTORE); the masks are written
    /// unmeasured first.
    function test_model_restore_tag() public {
        _tagged();
        Action[] memory m = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            m[i] = EfsFiles.unbind(Purpose.TAG, TOPIC, s[35 + i], 1);
        }
        _do(m, new bytes[](3));
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(Purpose.TAG, TOPIC, s[35 + i], s[35 + i], 2);
        }
        _actionPair("restore tag", x);
    }

    // ---- statements about topics: PROPERTY, SAME, BROADER (design §12.5) ------------------------------------------
    // Each row registers what it states about inside its own test (one unmeasured publication: `setUp` has no
    // headroom under the amsterdam cap), so the measured pair starts from that state. Positions are distinct per
    // action, so k1 and k2 each write fresh heads.

    /// Six word pages `<name>-0..5`, published unmeasured; returns their ids.
    function _pages(string memory name) internal returns (bytes32[6] memory w) {
        _rememberTopics();
        EfsTopics.Types memory t = _topicTypes();
        Action[] memory a = new Action[](6);
        bytes[] memory b = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            b[i] = bytes(string.concat(name, "-", vm.toString(i)));
            (Action[] memory ra,, bytes32 page) = EfsTopics.registerWord(t, b[i]);
            a[i] = ra[0];
            w[i] = page;
        }
        _do(a, b);
    }

    /// Three topics (word pages `<name>-0..2`) and six `text/1` labels (24 bytes, as `pub text 24`), published
    /// unmeasured: the label subjects, and `first[i]` / `second[i]` the existing texts a label names.
    function _labelled(string memory name)
        internal
        returns (bytes32[3] memory topic, bytes32[3] memory first, bytes32[3] memory second)
    {
        _rememberTopics();
        EfsTopics.Types memory t = _topicTypes();
        Action[] memory a = new Action[](9);
        bytes[] memory b = new bytes[](9);
        for (uint256 i; i < 3; ++i) {
            b[i] = bytes(string.concat(name, "-", vm.toString(i)));
            (Action[] memory ra,, bytes32 page) = EfsTopics.registerWord(t, b[i]);
            a[i] = ra[0];
            topic[i] = page;
            b[3 + i] = abi.encodePacked("Label ", _nm(5000 + i, 18));
            (a[3 + i],) = _publish(T_TEXT, b[3 + i]);
            first[i] = EfsTopics.recordId(t.text, b[3 + i]);
            b[6 + i] = abi.encodePacked("Label ", _nm(5100 + i, 18));
            (a[6 + i],) = _publish(T_TEXT, b[6 + i]);
            second[i] = EfsTopics.recordId(t.text, b[6 + i]);
        }
        _do(a, b);
    }

    /// `label:en` → `first[i]` on `topic[i]`, unmeasured (the later statements' starting state).
    function _labelAll(bytes32[3] memory topic, bytes32[3] memory first) internal {
        Action[] memory a = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            a[i] = EfsTopics.property(topic[i], EfsTopics.labelKey("en"), first[i], 0);
        }
        _do(a, new bytes[](3));
    }

    /// A label as a first statement: `BIND(PROPERTY, topic, labelKey("en") → an existing text/1)` (FIRST_BIND; the
    /// validator does not judge PROPERTY).
    function test_model_bind_property_fresh() public {
        (bytes32[3] memory topic, bytes32[3] memory first,) = _labelled("prop-fresh");
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsTopics.property(topic[i], EfsTopics.labelKey("en"), first[i], 0);
        }
        _actionPair("bind property fresh", x);
    }

    /// A label changed to another existing text: a re-bind (CAS to a different target).
    function test_model_bind_property_rebind() public {
        (bytes32[3] memory topic, bytes32[3] memory first, bytes32[3] memory second) =
            _labelled("prop-rebind");
        _labelAll(topic, first);
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsTopics.property(topic[i], EfsTopics.labelKey("en"), second[i], 1);
        }
        _actionPair("bind property rebind", x);
    }

    /// A mask of a label: UNBIND from BOUND at a PROPERTY position.
    function test_model_unbind_property() public {
        (bytes32[3] memory topic, bytes32[3] memory first,) = _labelled("prop-mask");
        _labelAll(topic, first);
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.unbind(Purpose.PROPERTY, topic[i], EfsTopics.labelKey("en"), 1);
        }
        _actionPair("unbind property", x);
    }

    /// A release of a label: RELEASE from BOUND at a PROPERTY position.
    function test_model_release_property() public {
        (bytes32[3] memory topic, bytes32[3] memory first,) = _labelled("prop-release");
        _labelAll(topic, first);
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = EfsFiles.release(Purpose.PROPERTY, topic[i], EfsTopics.labelKey("en"), 1);
        }
        _actionPair("release property", x);
    }

    /// Composite (never fitted): a label with its text: `EfsTopics.label`, PUBLISH a new 24-byte text/1 then
    /// BIND PROPERTY to it (a first statement).
    function test_model_validate_label_new_text() public {
        (bytes32[3] memory topic,,) = _labelled("prop-new");
        (Action[] memory a, bytes[] memory b,) = EfsTopics.label(
            _topicTypes(), topic[0], "en", abi.encodePacked("Label ", _nm(5200, 18)), 0
        );
        assertEq(b[0].length, 24);
        _exec("model validate label new text", a, b);
    }

    /// `purpose` from w[i] to w[3 + i], unmeasured (the later statements' starting state).
    function _relateAll(bytes32 purpose, bytes32[6] memory w) internal {
        Action[] memory a = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            a[i] = _bind(purpose, w[i], w[3 + i], w[3 + i], 0);
        }
        _do(a, new bytes[](3));
    }

    /// A first statement at `purpose` (SAME or BROADER) from w[i] to w[3 + i] (FIRST_BIND; the validator reads both
    /// topics' headers).
    function _relationFresh(string memory key, bytes32 purpose, bytes32[6] memory w) internal {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = _bind(purpose, w[i], w[3 + i], w[3 + i], 0);
        }
        _actionPair(key, x);
    }

    /// The later statements at `purpose` on w[i] → w[3 + i]: `which` 0 a mask (UNBIND from BOUND), 1 a release
    /// (RELEASE from BOUND), 2 a restore (BIND from MASKED to the kept target; the masks written unmeasured first).
    function _relationLater(string memory key, bytes32 purpose, bytes32[6] memory w, uint256 which)
        internal
    {
        _relateAll(purpose, w);
        if (which == 2) {
            Action[] memory m = new Action[](3);
            for (uint256 i; i < 3; ++i) {
                m[i] = EfsFiles.unbind(purpose, w[i], w[3 + i], 1);
            }
            _do(m, new bytes[](3));
        }
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            x[i] = which == 0
                ? EfsFiles.unbind(purpose, w[i], w[3 + i], 1)
                : which == 1
                    ? EfsFiles.release(purpose, w[i], w[3 + i], 1)
                    : _bind(purpose, w[i], w[3 + i], w[3 + i], 2);
        }
        _actionPair(key, x);
    }

    /// `same` between word pages (the word-level synonym).
    function test_model_bind_same_fresh_word() public {
        _relationFresh("bind same fresh word", Purpose.SAME, _pages("same-w"));
    }

    /// `same` between 2-word path records (`same-p/<a>` = `same-p/<b>`): joins those two places only.
    function test_model_bind_same_fresh_path() public {
        _rememberTopics();
        EfsTopics.Types memory t = _topicTypes();
        Action[] memory a = new Action[](13);
        bytes[] memory b = new bytes[](13);
        bytes32 parent;
        (a[0], b[0], parent) = _registerOne(t, "same-p");
        bytes32[6] memory w;
        for (uint256 i; i < 6; ++i) {
            (Action[] memory ca, bytes[] memory cb, bytes32 id) = EfsTopics.registerChild(
                t, parent, bytes(string.concat("same-p-", vm.toString(i))), true
            );
            (a[1 + 2 * i], b[1 + 2 * i]) = (ca[0], cb[0]);
            (a[2 + 2 * i], b[2 + 2 * i]) = (ca[1], cb[1]);
            w[i] = id;
        }
        _do(a, b);
        _relationFresh("bind same fresh path", Purpose.SAME, w);
    }

    function _registerOne(EfsTopics.Types memory t, bytes memory word)
        internal
        pure
        returns (Action memory, bytes memory, bytes32 page)
    {
        (Action[] memory ra, bytes[] memory rb, bytes32 id) = EfsTopics.registerWord(t, word);
        return (ra[0], rb[0], id);
    }

    function test_model_unbind_same() public {
        _relationLater("unbind same", Purpose.SAME, _pages("same-m"), 0);
    }

    function test_model_release_same() public {
        _relationLater("release same", Purpose.SAME, _pages("same-r"), 1);
    }

    function test_model_restore_same() public {
        _relationLater("restore same", Purpose.SAME, _pages("same-s"), 2);
    }

    /// `broader` between word pages (a booru-style parent).
    function test_model_bind_broader_fresh() public {
        _relationFresh("bind broader fresh", Purpose.BROADER, _pages("brd-w"));
    }

    function test_model_unbind_broader() public {
        _relationLater("unbind broader", Purpose.BROADER, _pages("brd-m"), 0);
    }

    function test_model_release_broader() public {
        _relationLater("release broader", Purpose.BROADER, _pages("brd-r"), 1);
    }

    function test_model_restore_broader() public {
        _relationLater("restore broader", Purpose.BROADER, _pages("brd-s"), 2);
    }

    /// The per-Type inputs of the floor quote (design §10.4) for every Type the model prices: how many leading body
    /// words are references (`freshPerRef` each, on every publish) and how many digest specs name the Type
    /// (`freshPerDigestSpec` each, on a fresh record). `tools/gas-model.mjs` copies them into `floor.types`.
    function test_model_floor_types() public {
        _rememberTopics();
        string[13] memory names = [
            "files-root/1",
            "files-child/1",
            "files-directory/1",
            "files-name/3",
            "files-bytes/1",
            "files-content/1",
            "files-external/1",
            "directory-alias/1",
            "realm-notice/1",
            "files-span/1",
            "topic-word/1",
            "topic/1",
            "text/1"
        ];
        for (uint8 t; t < 13; ++t) {
            emit log_named_uint(
                string.concat("model type ", names[t], " refs"),
                r.registry.typeInfo(typeIds[t]).refCount
            );
            emit log_named_uint(
                string.concat("model type ", names[t], " specs"),
                r.g.index.digestSpecCount(typeIds[t])
            );
        }
    }

    function test_model_withdraw() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            (, uint64 first,,,) = r.hot.recordHeader(c[26 + i]);
            x[i].kind = ActionKind.WITHDRAW;
            x[i].target = bytes32(uint256(first));
        }
        _actionPair("withdraw", x);
    }

    /// Composite (never fitted): a first tag on an existing 6-word path, every list existing (the author tagged two
    /// other things at the deepest topic, so each proper ancestor's roll-ups hold two entries).
    function test_model_validate_deep_tag_lists_exist() public {
        bytes32[] memory t = _levelPath("lvl-w");
        _levelAuthors(t);
        _tagAll(LEVEL_A, t[5], _things2(21));
        _as(LEVEL_A);
        _exec(
            "model validate tag 6 words all existing",
            _one1(_bind(Purpose.TAG, t[5], s[20], s[20], 0)),
            new bytes[](1)
        );
        _as(address(0));
    }

    // ---- 6. first write ---------------------------------------------------------------------------------------------

    /// CREATE(salt) + PUBLISH(files-directory/1, (who, salt)) by `who`, measured under `label`.
    function _seedAs(string memory label, address who, bytes32 salt) internal {
        bytes32 saved = p;
        p = Keys.principalFor(who, r.hot.realmOrigin());
        (Action memory x1, bytes memory y1) = _publish(T_DIRECTORY, EfsFiles.directoryBody(p, salt));
        (Action[] memory a, bytes[] memory b) = _two(_create(salt), "", x1, y1);
        sender = who;
        _exec(label, a, b);
        sender = address(0);
        p = saved;
    }

    function test_model_first_write() public {
        address fresh = makeAddr("gas-model fresh principal");
        address warm = makeAddr("gas-model warm principal");
        // the warm principal writes once (unmeasured label), then both publish the same shape
        _seedAs("gas-model warm principal first publication", warm, _salt("first", 0));
        _seedAs("model first write fresh", fresh, _salt("first", 1));
        _seedAs("model first write warm", warm, _salt("first", 1));
    }

    // ---- 7. validation composites (never fitted) --------------------------------------------------------------------

    function test_model_validate_recipes() public {
        // create file: CREATE, PUBLISH root form 0 (18-byte document), PUBLISH name (10 B), BIND HEAD, BIND FOLDER
        (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRec) = EfsFiles.createFile(
            _types(), p, d2, _salt("v", 0), "readme.txt", "Meeting at 10:00.\n", true
        );
        _exec("model validate create file", a, b);
        // edit: PUBLISH child form 0 (18-byte document) + HEAD rebind
        (a, b,) = EfsFiles.edit(_types(), file, rootRec, "Meeting at 11:00.\n", 1);
        _exec("model validate edit", a, b);
        // rename + move (EfsFiles.move): PUBLISH name (9 B), RELEASE (d2, readme.txt), BIND (rootDir, notes.txt)
        a = new Action[](3);
        b = new bytes[](3);
        (a[0], b[0]) = _name("notes.txt");
        a[1] = _bindKind(ActionKind.RELEASE, Purpose.FOLDER, d2, keccak256("readme.txt"), 0, 1);
        a[2] = _bind(Purpose.FOLDER, rootDir, keccak256("notes.txt"), file, 0);
        _exec("model validate rename move", a, b);
    }

    /// The ordinary state (the author's lists exist): a file created in a folder that already holds one of the
    /// author's files (d2 after an unmeasured `first.txt`); a second edit of that file; and a rename + move into a
    /// folder that already holds the author's entries (d1, nine entries from setUp).
    function test_model_validate_recipes_lists_exist() public {
        (Action[] memory a, bytes[] memory b,,) = EfsFiles.createFile(
            _types(), p, d2, _salt("v", 1), "first.txt", "Meeting at 09:00.\n", true
        );
        _do(a, b);
        bytes32 file;
        bytes32 rootRec;
        (a, b, file, rootRec) = EfsFiles.createFile(
            _types(), p, d2, _salt("v", 0), "readme.txt", "Meeting at 10:00.\n", true
        );
        _exec("model validate create file lists exist", a, b);
        bytes32 child;
        (a, b, child) = EfsFiles.edit(_types(), file, rootRec, "Meeting at 11:00.\n", 1);
        _do(a, b);
        (a, b,) = EfsFiles.edit(_types(), file, child, "Meeting at 12:00.\n", 2);
        _exec("model validate edit lists exist", a, b);
        a = new Action[](3);
        b = new bytes[](3);
        (a[0], b[0]) = _name("notes.txt");
        a[1] = _bindKind(ActionKind.RELEASE, Purpose.FOLDER, d2, keccak256("readme.txt"), 0, 1);
        a[2] = _bind(Purpose.FOLDER, d1, keccak256("notes.txt"), file, 0);
        _exec("model validate rename move lists exist", a, b);
    }

    function test_model_validate_two_chunks() public {
        (Action memory x0, bytes memory y0) =
            _publish(T_BYTES, EfsFiles.bytesBody(_payload(8160, _salt("two", 0))));
        (Action memory x1, bytes memory y1) =
            _publish(T_BYTES, EfsFiles.bytesBody(_payload(8160, _salt("two", 1))));
        (Action[] memory a, bytes[] memory b) = _two(x0, y0, x1, y1);
        _exec("model validate two chunks", a, b);
    }

    function test_model_validate_40kb_last_publication() public {
        EfsFiles.Types memory t = _types();
        bytes memory payload = _payload(40_000, "large file");
        (Action[] memory a, bytes[] memory b, bytes32 descriptor) =
            EfsFiles.storeContent(t, payload, 8160, "");
        (Action[] memory fa, bytes[] memory fb,,) =
            EfsFiles.createFileRef(t, p, rootDir, keccak256("big.bin"), "big.bin", descriptor, true);
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        uint256[] memory ends = EfsFiles.split(b, 64, 16_384);
        assertEq(ends.length, 3);
        uint256 from;
        for (uint256 i; i < 2; ++i) {
            (Action[] memory xa, bytes[] memory xb) = EfsFiles.slice(a, b, from, ends[i]);
            _do(xa, xb);
            from = ends[i];
        }
        (Action[] memory la, bytes[] memory lb) = EfsFiles.slice(a, b, from, ends[2]);
        // c4 (7,360-byte payload), 4 spans, the descriptor, CREATE, root form 1, name, HEAD, FOLDER
        assertEq(la.length, 11);
        assertEq(lb[0].length, 7392);
        _exec("model validate 40kb last publication", la, lb);
    }

    // ---- 8. later statements across places and in long lists (validation composites, never fitted) -------------
    // The later-statement rows (masks, releases, restores, number changes; folder masks, releases, re-binds) are
    // measured at ONE topic or folder whose lists are short. Two ordinary states cost more per statement: the bitmap
    // store rewrites a scope head on every later statement (`setBit` and `stamp` write `lastMutation`), so statements
    // at distinct places rewrite one head each, where statements at one place rewrite one between them; and from an
    // author's entry 48 at a place the live bit is in a bits word of its own (a restore of an entry alone in its word
    // writes a fresh slot), found by `RealmIndex._entryIndex`, a bisection of the author's list there with one store
    // call per probe. The composites below are whole publications in those states. Each builds its state unmeasured
    // with gas metering paused (fillers are first tags of address-shaped things, or folder entries naming s[39], in
    // publications of at most 64 actions); the measured statements are about file subjects, as the rows' are.
    //
    // Sizes: 32 statements for the homogeneous shapes across places (a bulk edit: half the action limit, where the
    // per-statement error has nearly reached its asymptote), 16 at 1,024 entries and 8 at 4,096 (the state those
    // lists need: 16,400 and 32,776 filler tags), and six statements for the two mixed publications (what a person
    // sends: untag one file from six topics, delete six files from three folders).

    uint256 internal constant ACROSS = 32;

    /// `a` and `b` in unmeasured publications of at most `per` actions.
    function _doIn(Action[] memory a, bytes[] memory b, uint256 per) internal {
        for (uint256 from; from < a.length; from += per) {
            uint256 m = a.length - from < per ? a.length - from : per;
            Action[] memory x = new Action[](m);
            bytes[] memory y = new bytes[](m);
            for (uint256 j; j < m; ++j) {
                (x[j], y[j]) = (a[from + j], b[from + j]);
            }
            _do(x, y);
        }
    }

    /// `n` one-word topics `<seed><i>`, registered unmeasured.
    function _topicsN(string memory seed, uint256 n) internal returns (bytes32[] memory t) {
        _rememberTopics();
        EfsTopics.Types memory tt = _topicTypes();
        t = new bytes32[](n);
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y, bytes32 id) =
                EfsTopics.registerWord(tt, bytes(string.concat(seed, vm.toString(i))));
            (a[i], b[i], t[i]) = (x[0], y[0], id);
        }
        _doIn(a, b, 32);
    }

    /// An address-shaped thing (target kind ADDRESS), distinct per (seed, i, j).
    function _filler(string memory seed, uint256 i, uint256 j) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(uint160(uint256(keccak256(abi.encode("gas-model filler", seed, i, j)))))
            );
    }

    /// The author's tags at `k` new topics: at topic i, `fill` first tags of fillers, then a first tag of s[i]
    /// (entry `fill` of the author's list there). Unmeasured, gas metering paused. Returns (topics, things).
    function _tagsAcross(string memory seed, uint256 k, uint256 fill)
        internal
        returns (bytes32[] memory t, bytes32[] memory th)
    {
        vm.pauseGasMetering();
        t = _topicsN(seed, k);
        th = new bytes32[](k);
        if (fill != 0) {
            Action[] memory f = new Action[](k * fill);
            for (uint256 i; i < k; ++i) {
                for (uint256 j; j < fill; ++j) {
                    bytes32 x = _filler(seed, i, j);
                    f[i * fill + j] = _bind(Purpose.TAG, t[i], x, x, 0);
                }
            }
            _doIn(f, new bytes[](k * fill), 64);
        }
        Action[] memory a = new Action[](k);
        for (uint256 i; i < k; ++i) {
            th[i] = s[i];
            a[i] = _bind(Purpose.TAG, t[i], s[i], s[i], 0);
        }
        _do(a, new bytes[](k));
        vm.resumeGasMetering();
    }

    /// One later statement per (topics[i], things[i]) on the author's asserted (revision 1) or, for a restore,
    /// masked (revision 2) head: `which` 0 a mask, 1 a release, 2 a restore, 3 a number change (0 -> 75).
    function _tagLater(bytes32[] memory tp, bytes32[] memory th, uint256 which)
        internal
        pure
        returns (Action[] memory a)
    {
        a = new Action[](tp.length);
        for (uint256 i; i < tp.length; ++i) {
            a[i] = which == 0
                ? EfsFiles.unbind(Purpose.TAG, tp[i], th[i], 1)
                : which == 1
                    ? EfsFiles.release(Purpose.TAG, tp[i], th[i], 1)
                    : which == 2
                        ? _bind(Purpose.TAG, tp[i], th[i], th[i], 2)
                        : EfsFiles.bindWithStrength(Purpose.TAG, tp[i], th[i], th[i], 1, 75);
        }
    }

    /// Measures, each from the current state: masks, releases, restores (after unmeasured masks) and, when
    /// `numbers`, number changes of the author's tags (tp[i], th[i]), as "model validate tag <kind> <what>".
    function _measureTagLater(
        string memory what,
        bytes32[] memory tp,
        bytes32[] memory th,
        bool numbers
    ) internal {
        uint256 n = tp.length;
        uint256 snap = vm.snapshotState();
        _exec(
            string.concat("model validate tag masks ", what), _tagLater(tp, th, 0), new bytes[](n)
        );
        vm.revertToState(snap);
        _exec(
            string.concat("model validate tag releases ", what),
            _tagLater(tp, th, 1),
            new bytes[](n)
        );
        vm.revertToState(snap);
        vm.pauseGasMetering();
        _do(_tagLater(tp, th, 0), new bytes[](n));
        vm.resumeGasMetering();
        _exec(
            string.concat("model validate tag restores ", what),
            _tagLater(tp, th, 2),
            new bytes[](n)
        );
        vm.revertToState(snap);
        if (numbers) {
            _exec(
                string.concat("model validate tag number changes ", what),
                _tagLater(tp, th, 3),
                new bytes[](n)
            );
            vm.revertToState(snap);
        }
    }

    /// 32 topics, the author's list at each holding one entry (the measured tag): the cross-place case alone.
    function test_model_validate_later_tags_across() public {
        (bytes32[] memory t, bytes32[] memory th) = _tagsAcross("lx-", ACROSS, 0);
        _measureTagLater("across topics", t, th, true);
    }

    /// 32 topics, the author's list at each holding 49 entries, the measured tag entry 48: alone in its bits word,
    /// so a mask clears that word to zero and a restore after it writes a fresh slot.
    function test_model_validate_later_tags_entry48() public {
        (bytes32[] memory t, bytes32[] memory th) = _tagsAcross("l48-", ACROSS, 48);
        _measureTagLater("at entry 48 across topics", t, th, false);
    }

    /// 16 topics, the author's list at each holding 1,025 entries, the measured tag entry 1,024 (the floor's claim:
    /// eleven bisection probes, alone in its bits word).
    function test_model_validate_later_tags_entry1024() public {
        (bytes32[] memory t, bytes32[] memory th) = _tagsAcross("lk-", 16, 1024);
        _measureTagLater("at entry 1024 across topics", t, th, false);
    }

    /// BEYOND THE CLAIM (the floor's documented exception): 8 topics, the author's list at each holding 4,097
    /// entries, the measured tag entry 4,096 (thirteen probes, alone in its bits word).
    function test_model_validate_later_tags_entry4096() public {
        (bytes32[] memory t, bytes32[] memory th) = _tagsAcross("l4k-", 8, 4096);
        _measureTagLater("at entry 4096 across topics", t, th, false);
    }

    /// One topic whose author's list holds 1,025 entries; the measured tags are entries 32, 64, ..., 1,024 (spread,
    /// so the bisections share few probes): a long list at one place.
    function test_model_validate_later_tags_one_topic_1024() public {
        vm.pauseGasMetering();
        bytes32 t = _topicsN("l1k-", 1)[0];
        Action[] memory f = new Action[](1025);
        bytes32[] memory tp = new bytes32[](ACROSS);
        bytes32[] memory th = new bytes32[](ACROSS);
        for (uint256 e; e < 1025; ++e) {
            bytes32 x = _filler("l1k", 0, e);
            if (e != 0 && e % 32 == 0) {
                x = s[e / 32 - 1];
                (tp[e / 32 - 1], th[e / 32 - 1]) = (t, x);
            }
            f[e] = _bind(Purpose.TAG, t, x, x, 0);
        }
        _doIn(f, new bytes[](1025), 64);
        vm.resumeGasMetering();
        _measureTagLater("of 32 entries of 1025 at one topic", tp, th, false);
    }

    /// Folder entries of the author: name record `_nm(base + i, 12)` bound in `d` to `target`.
    function _entry(bytes32 d, uint256 nameIndex, bytes32 target)
        internal
        pure
        returns (Action memory)
    {
        return _bind(Purpose.FOLDER, d, keccak256(_nm(nameIndex, 12)), target, 0);
    }

    /// PUBLISHes of the name records `_nm(from .. from + n, 12)` and of `k` folders of p (salts `<seed>` i).
    function _namesAndFolders(string memory seed, uint256 from, uint256 n, uint256 k)
        internal
        returns (bytes32[] memory d)
    {
        Action[] memory a = new Action[](n + k);
        bytes[] memory b = new bytes[](n + k);
        for (uint256 i; i < n; ++i) {
            (a[i], b[i]) = _name(_nm(from + i, 12));
        }
        d = new bytes32[](k);
        for (uint256 i; i < k; ++i) {
            (a[n + i], b[n + i]) = _publish(T_DIRECTORY, EfsFiles.directoryBody(p, _salt(seed, i)));
            d[i] = _id(T_DIRECTORY, b[n + i]);
        }
        _doIn(a, b, 64);
    }

    /// `which` 0 a mask, 1 a release, 2 a re-bind (to s[32 + i % 8]), 3 a restore (after a mask, to its kept target
    /// s[i]) of the author's entries (d[i], name `names[i]` → s[i]).
    function _folderLater(bytes32[] memory d, uint256[] memory names, uint256 which)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](d.length);
        for (uint256 i; i < d.length; ++i) {
            bytes32 role = keccak256(_nm(names[i], 12));
            a[i] = which == 0
                ? _bindKind(ActionKind.UNBIND, Purpose.FOLDER, d[i], role, 0, 1)
                : which == 1
                    ? _bindKind(ActionKind.RELEASE, Purpose.FOLDER, d[i], role, 0, 1)
                    : which == 2
                        ? _bind(Purpose.FOLDER, d[i], role, s[32 + i % 8], 1)
                        : _bind(Purpose.FOLDER, d[i], role, s[i], 2);
        }
    }

    /// Measures masks, releases and re-binds of the author's entries, each from the current state, as
    /// "model validate folder <kind> <what>".
    function _measureFolderLater(string memory what, bytes32[] memory d, uint256[] memory names)
        internal
    {
        uint256 n = d.length;
        uint256 snap = vm.snapshotState();
        _exec(
            string.concat("model validate folder masks ", what),
            _folderLater(d, names, 0),
            new bytes[](n)
        );
        vm.revertToState(snap);
        _exec(
            string.concat("model validate folder releases ", what),
            _folderLater(d, names, 1),
            new bytes[](n)
        );
        vm.revertToState(snap);
        _exec(
            string.concat("model validate folder re-binds ", what),
            _folderLater(d, names, 2),
            new bytes[](n)
        );
        vm.revertToState(snap);
        _folderRestores(what, d, names);
    }

    /// Unmeasured masks of the author's entries, then their restores measured as "model validate folder restores <what>".
    function _folderRestores(string memory what, bytes32[] memory d, uint256[] memory names)
        internal
    {
        uint256 n = d.length;
        uint256 snap = vm.snapshotState();
        vm.pauseGasMetering();
        _do(_folderLater(d, names, 0), new bytes[](n));
        vm.resumeGasMetering();
        _exec(
            string.concat("model validate folder restores ", what),
            _folderLater(d, names, 3),
            new bytes[](n)
        );
        vm.revertToState(snap);
    }

    /// 32 folders of the author, each holding one of the author's entries (name i → s[i]).
    function test_model_validate_later_folders_across() public {
        vm.pauseGasMetering();
        bytes32[] memory d = _namesAndFolders("lfx", 7000, ACROSS, ACROSS);
        Action[] memory a = new Action[](ACROSS);
        uint256[] memory names = new uint256[](ACROSS);
        for (uint256 i; i < ACROSS; ++i) {
            names[i] = 7000 + i;
            a[i] = _entry(d[i], names[i], s[i]);
        }
        _do(a, new bytes[](ACROSS));
        vm.resumeGasMetering();
        _measureFolderLater("across folders", d, names);
    }

    /// One folder holding 1,025 of the author's entries; the measured entries are 128, 256, ..., 1,024 (eight
    /// files, spread): deleting, hiding or re-pointing files in a big folder.
    function test_model_validate_later_folder_1024() public {
        vm.pauseGasMetering();
        bytes32 dir = _namesAndFolders("lf1k", 8000, 1025, 1)[0];
        Action[] memory f = new Action[](1025);
        bytes32[] memory d = new bytes32[](8);
        uint256[] memory names = new uint256[](8);
        for (uint256 e; e < 1025; ++e) {
            bytes32 target = s[39];
            if (e != 0 && e % 128 == 0) {
                target = s[e / 128 - 1];
                (d[e / 128 - 1], names[e / 128 - 1]) = (dir, 8000 + e);
            }
            f[e] = _entry(dir, 8000 + e, target);
        }
        _doIn(f, new bytes[](1025), 64);
        vm.resumeGasMetering();
        _measureFolderLater("of 8 entries of 1025 in one folder", d, names);
    }

    /// Mixed, ordinary: untag one file (s[0]) from six topics, the author's list at each holding three entries
    /// (two other things, then the file): six RELEASEs.
    function test_model_validate_untag_file_six_topics() public {
        vm.pauseGasMetering();
        bytes32[] memory t = _topicsN("lu-", 6);
        Action[] memory f = new Action[](18);
        bytes32[] memory th = new bytes32[](6);
        for (uint256 i; i < 6; ++i) {
            bytes32 x0 = _filler("lu", i, 0);
            bytes32 x1 = _filler("lu", i, 1);
            f[3 * i] = _bind(Purpose.TAG, t[i], x0, x0, 0);
            f[3 * i + 1] = _bind(Purpose.TAG, t[i], x1, x1, 0);
            f[3 * i + 2] = _bind(Purpose.TAG, t[i], s[0], s[0], 0);
            th[i] = s[0];
        }
        _do(f, new bytes[](18));
        vm.resumeGasMetering();
        _exec("model validate untag a file from six topics", _tagLater(t, th, 1), new bytes[](6));
    }

    /// Mixed, ordinary: delete (RELEASE) six files from three folders, two from each, each folder holding four of
    /// the author's entries (the deleted ones are entries 1 and 3).
    function test_model_validate_delete_files_three_folders() public {
        vm.pauseGasMetering();
        bytes32[] memory dirs = _namesAndFolders("ld", 9000, 12, 3);
        Action[] memory f = new Action[](12);
        bytes32[] memory d = new bytes32[](6);
        uint256[] memory names = new uint256[](6);
        for (uint256 i; i < 3; ++i) {
            for (uint256 e; e < 4; ++e) {
                uint256 nm = 9000 + 4 * i + e;
                bytes32 target = s[39];
                if (e % 2 == 1) {
                    uint256 m = 2 * i + e / 2;
                    target = s[m];
                    (d[m], names[m]) = (dirs[i], nm);
                }
                f[4 * i + e] = _entry(dirs[i], nm, target);
            }
        }
        _do(f, new bytes[](12));
        vm.resumeGasMetering();
        _exec(
            "model validate delete six files from three folders",
            _folderLater(d, names, 1),
            new bytes[](6)
        );
    }

    // ---- 9. the list tiers: rows for later statements by place and list length (design §10.4) -------------------
    // Each row is its own k1/k2 pair (never an anchor: `fixed` stays on its forty anchor pairs). A place is the
    // author's scope (purpose, subject); its list holds one entry per position the author ever stated there.
    //   `<row> new place`: k1 one statement at place 0, k2 one at each of places 1 and 2, each list holding one entry
    //     (TAG and FOLDER only: their single-place rows are measured at ONE topic or folder; the PROPERTY, SAME and
    //     BROADER rows are already measured at distinct subjects, so they are new-place rows as they stand).
    //   `<row> long new place`: the same at three places whose lists hold 1,025 entries, each statement at entry
    //     1,024 (eleven bisection probes, alone in its bits word): the floor's claim, first statement at a place.
    //   `<row> long same place`: one place whose list holds 1,025 entries; k1 the entry at 512, k2 the entries at 256
    //     and 768 (spread, so the searches share few probes): further statements at a place already touched.

    uint8 internal constant FAM_TAG = 0;
    uint8 internal constant FAM_FOLDER = 1;
    uint8 internal constant FAM_PROPERTY = 2;
    uint8 internal constant FAM_SAME = 3;
    uint8 internal constant FAM_BROADER = 4;
    uint256 internal constant NAME0 = 10_000; // folder entry names _nm(NAME0 + e, 12)

    bytes32[] internal others; // word pages: the roles (and targets) of SAME and BROADER entries
    bool internal rebindTargets; // FOLDER measured entries name s[29 + m] (the re-bind row's pattern), else s[m]

    function _famPurpose(uint8 f) internal pure returns (bytes32) {
        return f == FAM_TAG
            ? Purpose.TAG
            : f == FAM_FOLDER
                ? Purpose.FOLDER
                : f == FAM_PROPERTY
                    ? Purpose.PROPERTY
                    : f == FAM_SAME ? Purpose.SAME : Purpose.BROADER;
    }

    /// `n` places of family `f` (word pages, or folders of p), and what entries up to `len` need: the folder names,
    /// or `len` other word pages. Unmeasured (call with gas metering paused).
    function _famPlaces(uint8 f, string memory seed, uint256 n, uint256 len)
        internal
        returns (bytes32[] memory places)
    {
        if (f == FAM_FOLDER) return _namesAndFolders(seed, NAME0, len, n);
        places = _topicsN(string.concat(seed, "-"), n);
        if ((f == FAM_SAME || f == FAM_BROADER) && others.length < len) {
            bytes32[] memory o = _topicsN(string.concat(seed, "-o"), len);
            for (uint256 i; i < len; ++i) {
                others.push(o[i]);
            }
        }
    }

    /// Entry e's position at a place of family `f`, and its target; `m` < 40 marks a measured entry (TAG entries then
    /// name the file subject s[m]; FOLDER entries name s[m], each named by that entry only, as a file in one folder,
    /// or with `rebindTargets` s[29 + m], the existing re-bind row's old targets).
    function _famEntry(uint8 f, uint256 e, uint256 m)
        internal
        view
        returns (bytes32 role, bytes32 target)
    {
        if (f == FAM_TAG) {
            role = m < 40 ? s[m] : _filler("fam", 0, e);
            target = role;
        } else if (f == FAM_FOLDER) {
            role = keccak256(_nm(NAME0 + e, 12));
            target = m < 40 ? (rebindTargets ? s[29 + m] : s[m]) : s[39];
        } else if (f == FAM_PROPERTY) {
            role = keccak256(abi.encode("gas-model property", e));
            target = _filler("prop", 0, e);
        } else {
            role = others[e];
            target = role;
        }
    }

    /// The author's list at each place: `len` first statements (entries 0 .. len − 1), `measured[e]` the subject
    /// index of a measured entry (or ≥ 40). Publications of at most 64 actions.
    function _famLists(uint8 f, bytes32[] memory places, uint256 len, uint256[] memory measuredAt)
        internal
    {
        Action[] memory a = new Action[](places.length * len);
        bytes32 purpose = _famPurpose(f);
        for (uint256 i; i < places.length; ++i) {
            for (uint256 e; e < len; ++e) {
                uint256 m = 40;
                for (uint256 q; q < measuredAt.length; ++q) {
                    if (measuredAt[q] == i * len + e) m = q;
                }
                (bytes32 role, bytes32 target) = _famEntry(f, e, m);
                a[i * len + e] = _bind(purpose, places[i], role, target, 0);
            }
        }
        _doIn(a, new bytes[](a.length), 64);
    }

    /// The later statement `which` (0 mask, 1 release, 2 restore, 3 re-bind) at `place` on entry e (measured index m).
    function _famLater(uint8 f, bytes32 place, uint256 e, uint256 m, uint256 which)
        internal
        view
        returns (Action memory)
    {
        bytes32 purpose = _famPurpose(f);
        (bytes32 role, bytes32 target) = _famEntry(f, e, m);
        if (which == 0) return EfsFiles.unbind(purpose, place, role, 1);
        if (which == 1) return EfsFiles.release(purpose, place, role, 1);
        if (which == 2) return _bind(purpose, place, role, target, 2);
        // re-binds: a tag number change (same target, 0 -> 75); a folder entry to s[32 + m] (the existing row's
        // pattern: old targets s[29..32), new s[32..35))
        if (f == FAM_TAG) return EfsFiles.bindWithStrength(purpose, place, role, role, 1, 75);
        return _bind(purpose, place, role, s[32 + m], 1);
    }

    function _famName(uint8 f, uint256 which) internal pure returns (string memory) {
        string[5] memory fam = ["tag", "folder", "property", "same", "broader"];
        if (which == 3) {
            return f == FAM_TAG ? "bind tag number change" : "bind folder rebind";
        }
        string[3] memory w = ["unbind", "release", "restore"];
        return string.concat(w[which], " ", fam[f]);
    }

    /// The rows `<kind> <suffix>` for each `which` in `kinds` (bit mask), each from the same state: k1 the statement
    /// at (places[p1[0]], entry e1[0]), k2 those at p1/e1[1..3).
    function _famPairs(
        uint8 f,
        string memory suffix,
        bytes32[] memory pl,
        uint256[3] memory e,
        uint256 kinds
    ) internal {
        uint256 snap = vm.snapshotState();
        for (uint256 w; w < 4; ++w) {
            if ((kinds >> w) & 1 == 0) continue;
            if (w == 2) {
                vm.pauseGasMetering();
                Action[] memory masks = new Action[](3);
                for (uint256 q; q < 3; ++q) {
                    masks[q] = _famLater(f, pl[q], e[q], q, 0);
                }
                _do(masks, new bytes[](3));
                vm.resumeGasMetering();
            }
            string memory key = string.concat("model ", _famName(f, w), " ", suffix);
            _exec(string.concat(key, " k1"), _one1(_famLater(f, pl[0], e[0], 0, w)), new bytes[](1));
            Action[] memory a2 = new Action[](2);
            a2[0] = _famLater(f, pl[1], e[1], 1, w);
            a2[1] = _famLater(f, pl[2], e[2], 2, w);
            _exec(string.concat(key, " k2"), a2, new bytes[](2));
            vm.revertToState(snap);
        }
    }

    /// Three places, each list holding `len` entries, the measured statements at entry len − 1 of each.
    function _famNewPlace(
        uint8 f,
        string memory seed,
        uint256 len,
        string memory suffix,
        uint256 kinds
    ) internal {
        vm.pauseGasMetering();
        bytes32[] memory places = _famPlaces(f, seed, 3, len);
        uint256[] memory at = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            at[i] = i * len + len - 1;
        }
        _famLists(f, places, len, at);
        vm.resumeGasMetering();
        _famPairs(f, suffix, places, [len - 1, len - 1, len - 1], kinds);
    }

    /// One place, its list holding 1,025 entries, the measured statements at entries 512 (k1), 256 and 768 (k2).
    function _famSamePlace(uint8 f, string memory seed, uint256 kinds) internal {
        vm.pauseGasMetering();
        bytes32[] memory one = _famPlaces(f, seed, 1, 1025);
        uint256[] memory at = new uint256[](3);
        (at[0], at[1], at[2]) = (512, 256, 768);
        _famLists(f, one, 1025, at);
        vm.resumeGasMetering();
        bytes32[] memory pl = new bytes32[](3);
        (pl[0], pl[1], pl[2]) = (one[0], one[0], one[0]);
        _famPairs(f, "long same place", pl, [uint256(512), 256, 768], kinds);
    }

    // kinds: bit 0 mask, 1 release, 2 restore, 3 re-bind
    function test_model_tier_tag_new_place() public {
        _famNewPlace(FAM_TAG, "tnp", 1, "new place", 15);
    }

    function test_model_tier_tag_long_new_place() public {
        _famNewPlace(FAM_TAG, "tln", 1025, "long new place", 7);
    }

    function test_model_tier_tag_long_same_place() public {
        _famSamePlace(FAM_TAG, "tls", 7);
    }

    function test_model_tier_folder_new_place() public {
        _famNewPlace(FAM_FOLDER, "fnp", 1, "new place", 7);
    }

    /// The folder re-bind's new-place row, with the existing re-bind row's target pattern (old s[29..32), new
    /// s[32..35)).
    function test_model_tier_folder_rebind_new_place() public {
        rebindTargets = true;
        _famNewPlace(FAM_FOLDER, "frp", 1, "new place", 8);
    }

    function test_model_tier_folder_long_new_place() public {
        _famNewPlace(FAM_FOLDER, "fln", 1025, "long new place", 7);
    }

    function test_model_tier_folder_long_same_place() public {
        _famSamePlace(FAM_FOLDER, "fls", 7);
    }

    function test_model_tier_property_long_new_place() public {
        _famNewPlace(FAM_PROPERTY, "pln", 1025, "long new place", 3);
    }

    function test_model_tier_property_long_same_place() public {
        _famSamePlace(FAM_PROPERTY, "pls", 3);
    }

    function test_model_tier_same_long_new_place() public {
        _famNewPlace(FAM_SAME, "sln", 1025, "long new place", 7);
    }

    function test_model_tier_same_long_same_place() public {
        _famSamePlace(FAM_SAME, "sls", 7);
    }

    function test_model_tier_broader_long_new_place() public {
        _famNewPlace(FAM_BROADER, "bln", 1025, "long new place", 7);
    }

    function test_model_tier_broader_long_same_place() public {
        _famSamePlace(FAM_BROADER, "bls", 7);
    }

    // ---- 9b. composites for the tiers' edges and the other purposes (never fitted) ------------------------------

    /// The top of the short tier: 32 topics, the author's list at each holding 48 entries, the measured tag entry 47
    /// (its live bit still in the head word, six bisection probes).
    function test_model_validate_later_tags_entry47() public {
        (bytes32[] memory t, bytes32[] memory th) = _tagsAcross("l47-", ACROSS, 47);
        _measureTagLater("at entry 47 across topics", t, th, false);
    }

    /// `k` folders of the author, each list holding `fill` + 1 entries (fillers name s[39]; the measured entry, the
    /// last, names s[i]): masks and releases at entry `fill` across folders.
    function _foldersLong(string memory seed, uint256 k, uint256 fill, string memory what)
        internal
    {
        vm.pauseGasMetering();
        bytes32[] memory d = _namesAndFolders(seed, NAME0, fill + 1, k);
        Action[] memory a = new Action[](k * (fill + 1));
        uint256[] memory names = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            for (uint256 e; e <= fill; ++e) {
                a[i * (fill + 1) + e] = _entry(d[i], NAME0 + e, e == fill ? s[i] : s[39]);
            }
            names[i] = NAME0 + fill;
        }
        _doIn(a, new bytes[](a.length), 64);
        vm.resumeGasMetering();
        uint256 snap = vm.snapshotState();
        _exec(
            string.concat("model validate folder masks ", what),
            _folderLater(d, names, 0),
            new bytes[](k)
        );
        vm.revertToState(snap);
        _exec(
            string.concat("model validate folder releases ", what),
            _folderLater(d, names, 1),
            new bytes[](k)
        );
        vm.revertToState(snap);
        _folderRestores(what, d, names);
    }

    function test_model_validate_later_folders_entry48() public {
        _foldersLong("lf48", ACROSS, 48, "at entry 48 across folders");
    }

    function test_model_validate_later_folders_entry1024() public {
        _foldersLong("lfk", 16, 1024, "at entry 1024 across folders");
    }

    /// Number changes (re-binds: they never search the list) of 32 spread entries of a 1,025-entry list at one topic.
    function test_model_validate_later_tag_number_changes_one_topic_1024() public {
        vm.pauseGasMetering();
        bytes32 t = _topicsN("lnk-", 1)[0];
        Action[] memory f = new Action[](1025);
        bytes32[] memory tp = new bytes32[](ACROSS);
        bytes32[] memory th = new bytes32[](ACROSS);
        for (uint256 e; e < 1025; ++e) {
            bytes32 x = _filler("lnk", 0, e);
            if (e != 0 && e % 32 == 0) {
                x = s[e / 32 - 1];
                (tp[e / 32 - 1], th[e / 32 - 1]) = (t, x);
            }
            f[e] = _bind(Purpose.TAG, t, x, x, 0);
        }
        _doIn(f, new bytes[](1025), 64);
        vm.resumeGasMetering();
        _exec(
            "model validate tag number changes of 32 entries of 1025 at one topic",
            _tagLater(tp, th, 3),
            new bytes[](ACROSS)
        );
    }

    /// One place of family `f` whose list holds 1,025 entries; 8 spread entries (128, 256, ..., 1,024) masked.
    function _famComposite(uint8 f, string memory seed, string memory key) internal {
        vm.pauseGasMetering();
        bytes32[] memory one = _famPlaces(f, seed, 1, 1025);
        uint256[] memory at = new uint256[](8);
        for (uint256 q; q < 8; ++q) {
            at[q] = 128 * (q + 1);
        }
        _famLists(f, one, 1025, at);
        vm.resumeGasMetering();
        Action[] memory a = new Action[](8);
        for (uint256 q; q < 8; ++q) {
            a[q] = _famLater(f, one[0], at[q], q, 0);
        }
        _exec(key, a, new bytes[](8));
    }

    function test_model_validate_later_property_1024() public {
        _famComposite(
            FAM_PROPERTY, "lpk", "model validate property masks of 8 entries of 1025 at one topic"
        );
    }

    function test_model_validate_later_same_1024() public {
        _famComposite(
            FAM_SAME, "lsk", "model validate same masks of 8 entries of 1025 at one topic"
        );
    }

    function test_model_validate_later_broader_1024() public {
        _famComposite(
            FAM_BROADER, "lbk", "model validate broader masks of 8 entries of 1025 at one topic"
        );
    }

    function _types() internal view returns (EfsFiles.Types memory t) {
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
}
