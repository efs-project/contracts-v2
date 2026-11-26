// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {HeadAuthorsBase} from "./HeadAuthorsBase.sol";
import {IGeneration1} from "../harness/IndexDeploy.sol";
import {IHeadAuthorsGeneration, ListIndexDeployer} from "../harness/HeadAuthors.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";

/// @notice Docs INDEX-BUILD step 4 (§6, §3.3, §8 test 11): the measured gas of a build.
///
///         Two building generations over the same Realm (the Files Realm of `TopicListsHistory`, generation 1 live):
///         EX, the example generation of step 3b (`head-authors` in a fresh third store, both genesis stores
///         carried: "add one list later"), and FR, generation 1's code over two fresh stores (a full replay: the heal
///         path). Both are caught up before each measurement.
///
///         Every figure is one `build(0, maxFacts)` call measured as a transaction of its own would run it: the
///         publications to build are admitted live, the state is snapshotted, every account a build touches (the
///         kernel's five, the registry and its implementation, the descriptor store, generation 1's index, reads and
///         stores, the Files validator, the rule instances, and both building generations with their reads, decoders
///         and stores) is cooled with `vm.cool` (account and storage cold), and the call is made with ample gas;
///         `vm.lastFrameGas()` gives its gas (`gasTotalUsed`) and, on amsterdam, its EIP-8037 state gas
///         (`gasStateUsed`). Each measurement is reverted, so every kind is measured from the same state.
///
///         Per publication: the cold call over one publication (C1) and over `M` publications of the same kind, each
///         on its own file (CM); the marginal publication is (CM − C1)/(M − 1), the call's fixed share C1 − marginal.
///         Per leaf, for the kinds whose leaves are all alike: one publication of 1 and of `M` leaves, the marginal
///         leaf (CM − C1)/(M − 1). The new list's storage: the same EX call with the third store's `append`,
///         `retain` and `release` answered by `vm.mockCall` (the CALL is still made; its storage is not), subtracted.
contract BuildGasTest is HeadAuthorsBase {
    uint256 internal constant TX_CAP = 1 << 24;
    /// What a 2^24 transaction leaves a `build(bytes32, uint16)` call (21,000 base, ≤ 1,088 of calldata).
    uint256 internal constant BUILD_CALL_GAS = TX_CAP - 21_000 - 1_000;
    uint256 internal constant M = 9;
    uint256 internal constant POOL = 9;

    uint8 internal constant K_CREATE = 0;
    uint8 internal constant K_EDIT = 1;
    uint8 internal constant K_SECOND = 2;
    uint8 internal constant K_MASK = 3;
    uint8 internal constant K_RELEASE = 4;
    uint8 internal constant K_RESTORE = 5;
    uint8 internal constant K_TAG = 6;
    uint8 internal constant K_MOVE = 7;
    uint8 internal constant K_PUBLISH = 8;
    uint8 internal constant KINDS = 9;

    bytes32 internal word; // a registered one-word topic
    bytes32[] internal pool; // files of this principal in the root, `pool-<i>.txt`
    bytes32[] internal poolRoot;

    ListIndexDeployer internal exD;
    IHeadAuthorsGeneration internal ex;
    IndexDeployer internal frD;
    IGeneration1 internal fr;

    struct Cost {
        uint256 gas; // lastFrameGas().gasTotalUsed of the build call
        int256 state; // lastFrameGas().gasStateUsed (amsterdam; 0 on prague)
        uint256 delta; // gasleft() before − after, around the call
    }

    function setUp() public virtual override {
        super.setUp();
        word = _regPath("buildgas", 1)[0];
        for (uint256 i; i < POOL; ++i) {
            (bytes32 f, bytes32 root) =
                _newFile(address(this), rootDir, string.concat("pool-", vm.toString(i), ".txt"));
            pool.push(f);
            poolRoot.push(root);
        }
        (exD, ex) = _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        (frD, fr) = _generation(address(0), address(0));
        _buildAll(ex);
        _buildAll(fr);
    }

    function _amsterdam() internal view returns (bool) {
        return
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam");
    }

    // ---- cold calls --------------------------------------------------------------------------------------------------

    function _coolAll() internal {
        address[12] memory a = [
            r.k.proxy,
            address(r.k.implementation),
            address(r.k.ingress),
            address(r.k.applyDelegate),
            address(r.k.control),
            address(r.registry),
            address(r.registryImpl),
            address(r.store),
            address(r.g.index),
            address(r.g.posting),
            address(r.g.bitmap),
            address(r.g.reads)
        ];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
        vm.cool(address(validator));
        for (uint256 i; i < instances.length; ++i) {
            if (instances[i] != address(0)) vm.cool(instances[i]);
        }
        address[2] memory g = [address(ex), address(fr)];
        for (uint256 i; i < 2; ++i) {
            vm.cool(g[i]);
            vm.cool(IGeneration1(g[i]).READS());
            vm.cool(IGeneration1(g[i]).decoder());
        }
        for (uint256 i; i < 3; ++i) {
            vm.cool(exD.store(i));
        }
        vm.cool(frD.postingStore());
        vm.cool(frD.bitmapStore());
    }

    /// One cold `build(0, 65535)` call of `ix` over everything pending (the state is left as it was found).
    function _cold(IGeneration1 ix, bool mockList) internal returns (Cost memory c) {
        uint256 snap = vm.snapshotState();
        if (mockList) {
            address third = exD.store(2);
            vm.mockCall(
                third, abi.encodeWithSelector(IPostingStore.append.selector), abi.encode(uint64(1))
            );
            vm.mockCall(
                third, abi.encodeWithSelector(IPostingStore.retain.selector), abi.encode(uint64(1))
            );
            vm.mockCall(
                third, abi.encodeWithSelector(IPostingStore.release.selector), abi.encode(uint64(1))
            );
        }
        _coolAll();
        uint256 g0 = gasleft();
        ix.build(bytes32(0), type(uint16).max);
        c.delta = g0 - gasleft();
        Vm.Gas memory f = vm.lastFrameGas();
        c.gas = f.gasTotalUsed;
        c.state = f.gasStateUsed;
        (uint64 admissions,) = _counts();
        (uint64 processed,,) = ix.progress();
        assertEq(processed, admissions, "the call built everything pending");
        if (mockList) vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
    }

    // ---- the kinds of publication --------------------------------------------------------------------------------

    function _kindName(uint8 k) internal pure returns (string memory) {
        string[9] memory n = [
            "create file (5 leaves)",
            "edit (2 leaves)",
            "second author's version (2 leaves)",
            "HEAD mask (1 leaf)",
            "HEAD release (1 leaf)",
            "HEAD restore (1 leaf)",
            "first tag, one-word topic (1 leaf)",
            "folder move with a new name (3 leaves)",
            "plain publish, a name record (1 leaf)"
        ];
        return n[k];
    }

    function _leavesOf(uint8 k) internal pure returns (uint256) {
        uint8[9] memory n = [5, 2, 2, 1, 1, 1, 1, 3, 1];
        return n[k];
    }

    function _bytes(string memory s, uint256 i) internal pure returns (bytes memory) {
        return bytes(string.concat(s, vm.toString(i), ".txt"));
    }

    /// Whatever kind `k` needs before its measured publications (admitted and built, so nothing of it is pending).
    function _prep(uint8 k, uint256 m) internal {
        if (k != K_RESTORE) return;
        for (uint256 i; i < m; ++i) {
            _head1(
                address(this),
                EfsFiles.unbind(Purpose.HEAD, pool[i], 0, _hrev(address(this), pool[i]))
            );
        }
        _buildAll(ex);
        _buildAll(fr);
    }

    /// Admits publication i of kind k (live, generation 1).
    function _admit(uint8 k, uint256 i) internal {
        if (k == K_CREATE) {
            _newFile(address(this), rootDir, string(_bytes("new-", i)));
        } else if (k == K_EDIT) {
            _editFile(address(this), pool[i], poolRoot[i], string(_bytes("edit-", i)));
        } else if (k == K_SECOND) {
            _editFile(bob, pool[i], poolRoot[i], string(_bytes("bob-", i)));
        } else if (k == K_MASK) {
            _head1(
                address(this),
                EfsFiles.unbind(Purpose.HEAD, pool[i], 0, _hrev(address(this), pool[i]))
            );
        } else if (k == K_RELEASE) {
            _head1(
                address(this),
                EfsFiles.release(Purpose.HEAD, pool[i], 0, _hrev(address(this), pool[i]))
            );
        } else if (k == K_RESTORE) {
            _head1(
                address(this),
                EfsFiles.bind(Purpose.HEAD, pool[i], 0, poolRoot[i], _hrev(address(this), pool[i]))
            );
        } else if (k == K_TAG) {
            _execAs(
                address(this), _one(EfsTopics.tag(word, _thing("tag", i), 0, 0)), new bytes[](1)
            );
        } else if (k == K_MOVE) {
            (Action[] memory a, bytes[] memory b) = EfsFiles.move(
                ft,
                pool[i],
                rootDir,
                _bytes("pool-", i),
                _rev(address(this), Purpose.FOLDER, rootDir, keccak256(_bytes("pool-", i))),
                rootDir,
                _bytes("moved-", i),
                0,
                true
            );
            _execAs(address(this), a, b);
        } else {
            (Action memory x, bytes memory y) = _name(_bytes("pub-", i));
            Action[] memory a = new Action[](1);
            bytes[] memory b = new bytes[](1);
            (a[0], b[0]) = (x, y);
            _execAs(address(this), a, b);
        }
    }

    function _thing(string memory seed, uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
    }

    struct KindCost {
        Cost ex1;
        Cost exM;
        Cost exList1; // EX with the list's writes mocked, one publication
        Cost exListM;
        Cost fr1;
        Cost frM;
    }

    function _measureKind(uint8 k) internal returns (KindCost memory c) {
        for (uint256 pass; pass < 2; ++pass) {
            uint256 m = pass == 0 ? 1 : M;
            uint256 snap = vm.snapshotState();
            _prep(k, m);
            for (uint256 i; i < m; ++i) {
                _admit(k, i);
            }
            if (pass == 0) {
                c.ex1 = _cold(ex, false);
                c.exList1 = _cold(ex, true);
                c.fr1 = _cold(fr, false);
            } else {
                c.exM = _cold(ex, false);
                c.exListM = _cold(ex, true);
                c.frM = _cold(fr, false);
            }
            vm.revertToStateAndDelete(snap);
        }
    }

    function _marginal(Cost memory one, Cost memory many) internal pure returns (uint256) {
        return (many.gas - one.gas) / (M - 1);
    }

    function _marginalState(Cost memory one, Cost memory many) internal pure returns (int256) {
        return (many.state - one.state) / int256(M - 1);
    }

    function _logCost(string memory label, Cost memory c) internal {
        emit log_named_uint(string.concat(label, ": gas"), c.gas);
        emit log_named_int(string.concat(label, ": state gas"), c.state);
        emit log_named_uint(string.concat(label, ": gasleft delta"), c.delta);
    }

    /// The upper bands this suite asserts: gas (`gasTotalUsed`) of the marginal publication of each kind, about 25%
    /// over the larger of the two schedules' measured figures (docs INDEX-BUILD §6.1), so a change that makes a build
    /// much dearer fails here; one that makes it cheaper passes and should update §6.
    function _band(uint8 k, bool full) internal pure returns (uint256) {
        uint32[9] memory ex_ =
            [uint32(223_000), 115_000, 155_000, 101_000, 101_000, 101_000, 70_000, 143_000, 63_000];
        uint32[9] memory fr_ = [
            uint32(577_000), 305_000, 316_000, 180_000, 180_000, 189_000, 284_000, 468_000, 107_000
        ];
        return full ? fr_[k] : ex_[k];
    }

    // =============================================================================================
    // A and B: per publication, every kind, EX (a list added later) and FR (a full replay)
    // =============================================================================================

    function test_per_publication() public {
        for (uint8 k; k < KINDS; ++k) {
            KindCost memory c = _measureKind(k);
            string memory n = _kindName(k);
            _logCost(string.concat("EX 1 pub ", n), c.ex1);
            _logCost(string.concat("EX M pubs ", n), c.exM);
            _logCost(string.concat("EX list mocked 1 pub ", n), c.exList1);
            _logCost(string.concat("EX list mocked M pubs ", n), c.exListM);
            _logCost(string.concat("FR 1 pub ", n), c.fr1);
            _logCost(string.concat("FR M pubs ", n), c.frM);
            uint256 exPub = _marginal(c.ex1, c.exM);
            uint256 exWalk = _marginal(c.exList1, c.exListM);
            uint256 frPub = _marginal(c.fr1, c.frM);
            emit log_named_uint(string.concat("EX marginal publication ", n), exPub);
            emit log_named_uint(string.concat("EX marginal walk, list mocked ", n), exWalk);
            emit log_named_int(
                string.concat("EX marginal list storage ", n), int256(exPub) - int256(exWalk)
            );
            emit log_named_int(
                string.concat("EX marginal state gas ", n), _marginalState(c.ex1, c.exM)
            );
            emit log_named_uint(string.concat("EX fixed share of a call ", n), c.ex1.gas - exPub);
            emit log_named_uint(string.concat("FR marginal publication ", n), frPub);
            emit log_named_int(
                string.concat("FR marginal state gas ", n), _marginalState(c.fr1, c.frM)
            );
            emit log_named_uint(string.concat("FR fixed share of a call ", n), c.fr1.gas - frPub);
            assertLe(exPub, _band(k, false), string.concat("EX band ", n));
            assertLe(frPub, _band(k, true), string.concat("FR band ", n));
        }
    }

    // =============================================================================================
    // A3: per leaf, inside one publication, for leaves alike (k vs k + M − 1 leaves)
    // =============================================================================================

    function _batch(uint8 which, uint256 n, string memory seed) internal {
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            if (which == 0) {
                a[i] = EfsTopics.tag(word, _thing(seed, i), 0, 0);
            } else if (which == 1) {
                (a[i], b[i]) = _name(_bytes(seed, i));
            } else if (which == 2) {
                a[i] = _create(keccak256(abi.encode(seed, i)));
            } else {
                a[i] = EfsFiles.unbind(Purpose.HEAD, pool[i], 0, _hrev(address(this), pool[i]));
            }
        }
        _execAs(address(this), a, b);
    }

    function test_per_leaf() public {
        string[4] memory names = [
            "first tag, one-word topic",
            "plain publish, a name record",
            "CREATE",
            "HEAD mask (touches the list)"
        ];
        // about 25% over the measured marginal leaf (the same on both schedules for the first three)
        uint32[4] memory leafBand = [uint32(37_400), 30_200, 13_800, 68_600];
        for (uint8 w; w < 4; ++w) {
            Cost[2] memory e;
            Cost[2] memory el;
            Cost[2] memory f;
            for (uint256 pass; pass < 2; ++pass) {
                uint256 snap = vm.snapshotState();
                _batch(w, pass == 0 ? 1 : M, string.concat("leaf-", vm.toString(w)));
                e[pass] = _cold(ex, false);
                el[pass] = _cold(ex, true);
                f[pass] = _cold(fr, false);
                vm.revertToStateAndDelete(snap);
            }
            string memory n = names[w];
            _logCost(string.concat("EX 1 leaf ", n), e[0]);
            _logCost(string.concat("EX M leaves ", n), e[1]);
            _logCost(string.concat("FR 1 leaf ", n), f[0]);
            _logCost(string.concat("FR M leaves ", n), f[1]);
            emit log_named_uint(string.concat("EX marginal leaf ", n), _marginal(e[0], e[1]));
            emit log_named_uint(
                string.concat("EX marginal leaf, list mocked ", n), _marginal(el[0], el[1])
            );
            emit log_named_int(
                string.concat("EX marginal leaf state gas ", n), _marginalState(e[0], e[1])
            );
            emit log_named_uint(string.concat("FR marginal leaf ", n), _marginal(f[0], f[1]));
            emit log_named_int(
                string.concat("FR marginal leaf state gas ", n), _marginalState(f[0], f[1])
            );
            assertLe(_marginal(e[0], e[1]), leafBand[w], string.concat("EX leaf band ", n));
        }
        // the fixed share: a cold call with nothing pending (the gates, the carried check, the progress word)
        Cost memory idleEx = _cold(ex, false);
        Cost memory idleFr = _cold(fr, false);
        _logCost("EX idle call, nothing pending", idleEx);
        _logCost("FR idle call, nothing pending", idleFr);
    }

    // =============================================================================================
    // A2 cross-check: one cold call over a segment of the §6.2 mix
    // =============================================================================================

    /// 20 files: 20 create-file recipes, 60 edits (3 a file), 2 second authors' versions (10%), and one HEAD mask,
    /// release and restore (6% would be 1.2: three transitions here, 15%; the line is priced from the per-kind
    /// figures, this segment checks that those add up).
    function test_mixed_segment() public {
        uint256 files = 20;
        bytes32[] memory f = new bytes32[](files);
        bytes32[] memory root = new bytes32[](files);
        bytes32[] memory last = new bytes32[](files);
        for (uint256 i; i < files; ++i) {
            (f[i], root[i]) = _newFile(address(this), rootDir, string(_bytes("mix-", i)));
            last[i] = root[i];
        }
        for (uint256 e; e < 3; ++e) {
            for (uint256 i; i < files; ++i) {
                last[i] = _editFile(
                    address(this),
                    f[i],
                    last[i],
                    string.concat("mix v", vm.toString(e), vm.toString(i))
                );
            }
        }
        _editFile(bob, f[0], root[0], "bob mix 0");
        _editFile(bob, f[1], root[1], "bob mix 1");
        _head1(address(this), EfsFiles.unbind(Purpose.HEAD, f[2], 0, _hrev(address(this), f[2])));
        _head1(address(this), EfsFiles.release(Purpose.HEAD, f[3], 0, _hrev(address(this), f[3])));
        _head1(
            address(this), EfsFiles.bind(Purpose.HEAD, f[2], 0, last[2], _hrev(address(this), f[2]))
        );
        Cost memory e1 = _cold(ex, false);
        Cost memory f1 = _cold(fr, false);
        _logCost("segment EX (20 files: 85 publications, 227 leaves)", e1);
        _logCost("segment FR (20 files: 85 publications, 227 leaves)", f1);
        emit log_named_uint("segment EX per file", e1.gas / files);
        emit log_named_uint("segment FR per file", f1.gas / files);
        assertLe(e1.gas, BUILD_CALL_GAS, "EX: the segment builds in one 2^24 call");
    }

    // =============================================================================================
    // C: the heaviest admitted publications, one cold call each, EX and FR (docs INDEX-BUILD §3.3)
    // =============================================================================================

    function _k(string memory shape) internal view returns (uint256) {
        return vm.parseJsonUint(
            vm.readFile("test/vectors/floor-plan.json"),
            string.concat(".schedules.", _amsterdam() ? "amsterdam" : "prague", ".", shape, ".k")
        );
    }

    function _tags(bytes32 topic, string memory seed, uint256 n, bool deny)
        internal
        pure
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = deny
                ? EfsTopics.deny(topic, _thing(seed, i), 0, 0)
                : EfsTopics.tag(topic, _thing(seed, i), 0, 0);
        }
    }

    /// FloorPlan.t.sol's create-file recipes.
    function _recipes(uint256 n) internal view returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](n * 5);
        b = new bytes[](n * 5);
        for (uint256 i; i < n; ++i) {
            bytes memory name = bytes.concat(
                "f", bytes1(uint8(97 + (i / 26) % 26)), bytes1(uint8(97 + i % 26)), "-doc.md"
            );
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                ft,
                p,
                rootDir,
                keccak256(abi.encode("floor-plan file", i)),
                name,
                "Meeting at 10:00.\n",
                true
            );
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
    }

    /// Admits `a` (ample gas), then builds it alone in one cold call of EX and of FR; asserts each fits the gas a
    /// 2^24 transaction leaves the call (on prague also by running it with exactly that gas).
    function _heavy(string memory label, Action[] memory a, bytes[] memory b, bool mustFit)
        internal
    {
        uint256 snap = vm.snapshotState();
        _execAs(address(this), a, b);
        IGeneration1[2] memory g = [IGeneration1(address(ex)), fr];
        string[2] memory who = ["EX", "FR"];
        for (uint256 i; i < 2; ++i) {
            Cost memory c = _cold(g[i], false);
            string memory l = string.concat(who[i], " ", label);
            emit log_named_uint(string.concat(l, ": leaves"), a.length);
            _logCost(l, c);
            emit log_named_int(
                string.concat(l, ": headroom under the call's 2^24 share"),
                int256(BUILD_CALL_GAS) - int256(c.gas)
            );
            bool fit = c.gas <= BUILD_CALL_GAS;
            if (mustFit) assertTrue(fit, string.concat(l, ": fits one 2^24 call"));
            if (!_amsterdam()) {
                uint256 s2 = vm.snapshotState();
                _coolAll();
                try g[i].build{gas: BUILD_CALL_GAS}(bytes32(0), type(uint16).max) {
                    assertTrue(fit, "a capped call that fits was measured as fitting");
                } catch {
                    assertFalse(fit, "a capped call that fails was measured as not fitting");
                }
                vm.revertToStateAndDelete(s2);
            }
        }
        vm.revertToStateAndDelete(snap);
    }

    function test_heaviest_admitted_publications() public {
        bytes32 deep8 = _regPath("eight", 8)[7];
        bytes32 deep64 = _regPath("sixtyfour", 64)[63];
        _buildAll(ex);
        _buildAll(fr);
        bytes[] memory none = new bytes[](64);
        uint256 k = _k("loneNegatives");
        _heavy("lone negatives (k)", _tags(word, "ln-k", k, true), _cut(none, k), true);
        k = _k("firstTagsDepth8New");
        _heavy("depth-8 first tags (k)", _tags(deep8, "d8-k", k, false), _cut(none, k), true);
        k = _k("firstTagsDepth64New");
        _heavy("depth-64 first tags (k)", _tags(deep64, "d64-k", k, false), _cut(none, k), true);
        k = _k("createFiles");
        (Action[] memory a, bytes[] memory b) = _recipes(k);
        _heavy("create-file recipes (k)", a, b, true);
        _heavy("64 lone negatives", _tags(word, "ln-64", 64, true), none, true);
    }

    function _cut(bytes[] memory b, uint256 n) internal pure returns (bytes[] memory x) {
        x = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = b[i];
        }
    }
}
