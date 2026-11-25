// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice The measurements behind `gas/model.json` (`tools/gas-model.mjs`): a per-action gas model for the SDK's
///         write planner. Every measured publication runs on the native lane through `FilesRecipesBase._exec`
///         (label `model <key>`, logging `gas`, `frame gas` and, under amsterdam, `frame state gas`) by a principal
///         that has written before (the setUp publications), except the first-write pair. Before each measured
///         `execute` every account the setUp touched is cooled (`vm.cool`), so each publication pays the cold
///         access costs of a transaction of its own; refunds (EIP-3529) are not applied, as in any frame
///         measurement. A marginal cost is `k2 − k1` of two publications of the same shape with distinct bodies;
///         `2·k1 − k2` is the fixed cost the shape implies. The `validate` publications are composites the script
///         predicts and never fits.
contract GasModelTest is FilesRecipesBase {
    uint256 internal constant N_SUBJECTS = 40;
    uint256 internal constant N_CHUNKS = 40;
    uint256 internal constant N_NAMES = 15;

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

    /// A valid `files-name/2` name of exactly `len` bytes (3 ≤ len ≤ 255), distinct per `i` (< 26^3).
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

    function test_model_withdraw() public {
        Action[3] memory x;
        for (uint256 i; i < 3; ++i) {
            (, uint64 first,,,) = r.hot.recordHeader(c[26 + i]);
            x[i].kind = ActionKind.WITHDRAW;
            x[i].target = bytes32(uint256(first));
        }
        _actionPair("withdraw", x);
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
