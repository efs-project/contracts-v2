// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FloorBase} from "../integration/FloorBase.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {HeadAuthorsGenesis, HeadAuthorsReads, ListIndexDeployer} from "../harness/HeadAuthors.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, Native, PostingKey, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";

/// @notice The HEAD surcharge against what the callbacks really spend, by `FloorBase`'s method: for each HEAD shape, from
///         one cooled state, E (execution gas), K (the callbacks mocked) and the final phase; the callbacks' prefix
///         spend is E − K − the final phase, and the kernel's prefix quote P must be at or above it (the floor is
///         honest, as design §10.4 asks of every shape it claims). Three settings run the same shapes: generation 1
///         itself, which keeps `head-authors` (everyone's versions of a file) and reserves for it with its HEAD
///         surcharge (asserted; its spend against the same code without the list is what the surcharge values are
///         measured from); the example generation (`file-versions` in a third store, docs INDEX-BUILD §2.2, §6.3; a
///         test harness, not product) with its own model (asserted); and the example with generation 1's model
///         (logged: what the second list costs that generation 1's model does not quote).
abstract contract HeadAuthorsFloorBase is FloorBase {
    uint8 internal constant OWN_MODEL = 0;
    uint8 internal constant GEN1_MODEL = 1;
    uint8 internal constant GEN1 = 2;

    EfsFiles.Types internal ft;
    address internal third;
    address internal bob = makeAddr("head-floor/bob");
    address internal carol = makeAddr("head-floor/carol");

    function _setting() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        super.setUp();
        ft.root = typeIds[T_ROOT];
        ft.child = typeIds[T_CHILD];
        ft.directory = typeIds[T_DIRECTORY];
        ft.name = typeIds[T_NAME];
    }

    function _gen1(address ledger) internal virtual override returns (IndexDeploy.Gen1 memory g) {
        if (_setting() == GEN1) return super._gen1(ledger);
        ListIndexDeployer.ReadsArgs memory x;
        x.ledger = ledger;
        x.hotAbiId = KernelDeploy.HOT_ABI_ID;
        x.units = _units();
        x.specs = _specs();
        x.work = _setting() == OWN_MODEL
            ? HeadAuthorsGenesis.workModel()
            : IndexDoubleDefaults.workModel();
        x.topicTypeId = typeIds[T_TOPIC];
        x.topicWordTypeId = typeIds[T_TOPIC_WORD];
        HeadAuthorsGenesis.Deployed memory d = HeadAuthorsGenesis.deploy(
            x, IndexDeploy.postingFamilies(), IndexDeploy.bitmapFamilies()
        );
        third = d.third;
        g.posting = PostingStore(d.posting);
        g.bitmap = BitmapStore(d.bitmap);
        g.reads = HeadAuthorsReads(d.reads);
        g.index = IGeneration1(d.index);
    }

    function _coolRealm() internal virtual override {
        super._coolRealm();
        if (third != address(0)) vm.cool(third);
    }

    function _home(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    function _newFile(address who, string memory name)
        internal
        returns (bytes32 file, bytes32 root)
    {
        Action[] memory a;
        bytes[] memory b;
        bytes32 pid = who == address(this) ? p : Keys.principal(who);
        (a, b, file, root) = EfsFiles.createFile(
            ft,
            pid,
            who == address(this) ? rootDir : _home(who),
            keccak256(bytes(name)),
            bytes(name),
            bytes(name),
            true
        );
        _execAs(who, a, b);
    }

    function _rev(bytes32 file) internal view returns (uint64 revision) {
        (, revision,,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.HEAD, file, 0)));
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function execGas(Action[] calldata a, bytes[] calldata b, Native calldata c, uint256 gas_)
        external
    {
        require(msg.sender == address(this));
        r.ledger.execute{gas: gas_}(a, b, c, "");
    }

    /// One shape from the current state: logs the quote against the prefix spend and, with the example generation's
    /// own model, asserts P ≥ the spend and (prague) that the publication is admitted with exactly V of gas. Leaves
    /// the state as it found it.
    function _shape(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 spend, uint256 quote)
    {
        Need memory w = _need(a, b, address(0));
        uint256 fin = _finalPhase(a, b, w.exec);
        spend = w.exec - w.kernel - fin;
        quote = w.prefixFloor;
        _log(label, w);
        emit log_named_uint(string.concat("floor ", label, " final phase"), fin);
        emit log_named_uint(string.concat("floor ", label, " prefix spend"), spend);
        emit log_named_uint(
            string.concat("floor ", label, " quote / spend (x1000)"), quote * 1000 / spend
        );
        if (_setting() != GEN1_MODEL) {
            assertGe(quote, spend, string.concat(label, ": the prefix quote covers the spend"));
            assertLe(w.visible, w.room, string.concat(label, ": V fits a 2^24 transaction"));
            if (!_amsterdam()) {
                uint256 snap = vm.snapshotState();
                _coolRealm();
                this.execGas(a, b, _ctx(a), w.visible);
                vm.revertToStateAndDelete(snap);
            }
        }
    }

    function test_head_shapes() public {
        // the state: bob's file f (bob's list: one author), carol's file g with bob's version too (two authors), and
        // this contract's own files h (bound) and k (masked)
        (bytes32 f, bytes32 fRoot) = _newFile(bob, "bob.txt");
        (bytes32 g, bytes32 gRoot) = _newFile(carol, "carol.txt");
        _execAs(bob, _one(EfsFiles.bind(Purpose.HEAD, g, 0, gRoot, 0)), new bytes[](1));
        (bytes32 h, bytes32 hRoot) = _newFile(address(this), "mine.txt");
        (bytes32 k, bytes32 kRoot) = _newFile(address(this), "masked.txt");
        _execAs(address(this), _one(EfsFiles.unbind(Purpose.HEAD, k, 0, _rev(k))), new bytes[](1));
        Action[] memory a;
        bytes[] memory b;
        // a new file: a FIRST_BIND on a new list (one fresh slot)
        (a, b,,) =
            EfsFiles.createFile(ft, p, rootDir, keccak256("new.txt"), "new.txt", "new.txt", true);
        _shape("create file", a, b);
        // this contract's own version of bob's file: the list's second author (word 0 materialized)
        (a, b,) = EfsFiles.edit(ft, f, fRoot, "my version", 0);
        _shape("second author's version", a, b);
        // a lone negative on carol's file: the list's third author (a word rewrite)
        _shape(
            "third author's first mask",
            _one(EfsFiles.loneNegative(Purpose.HEAD, g, 0, 0)),
            new bytes[](1)
        );
        // later statements on its own heads: the counter
        _shape(
            "mask of a bound head",
            _one(EfsFiles.unbind(Purpose.HEAD, h, 0, _rev(h))),
            new bytes[](1)
        );
        _shape(
            "release of a bound head",
            _one(EfsFiles.release(Purpose.HEAD, h, 0, _rev(h))),
            new bytes[](1)
        );
        _shape(
            "restore of a masked head",
            _one(EfsFiles.bind(Purpose.HEAD, k, 0, kRoot, _rev(k))),
            new bytes[](1)
        );
        (a, b,) = EfsFiles.edit(ft, h, hRoot, "mine v2", _rev(h));
        _shape("re-bind (an edit)", a, b);
        // 32 first masks on 32 files of bob: 32 lists, each gaining a second author
        Action[] memory c = new Action[](32);
        for (uint256 i; i < 32; ++i) {
            (bytes32 fi,) = _newFile(bob, string.concat("bob-", vm.toString(i), ".txt"));
            c[i] = EfsFiles.loneNegative(Purpose.HEAD, fi, 0, 0);
        }
        _shape("32 second-author first masks", c, new bytes[](32));
    }

    /// The list's reservation is the HEAD surcharge of formula 3, so it no longer reaches other purposes: with the example
    /// generation's own model, a TAG and a FOLDER publication are quoted exactly as generation 1's model quotes them
    /// (the work model mocked to generation 1's), and a HEAD statement exactly one surcharge more (formula 2 charged
    /// the list's +10 fresh, +10 rewrites and +27,000 to every bind-kind action of every purpose).
    function test_other_purposes_are_not_reserved_for_the_list() public {
        if (_setting() != OWN_MODEL) return;
        Action[] memory tags = new Action[](8);
        Action[] memory folders = new Action[](8);
        for (uint256 i; i < 8; ++i) {
            bytes32 thing = bytes32(uint256(uint160(uint256(keccak256(abi.encode("hf", i))))));
            tags[i] = EfsTopics.deny(keccak256("some topic"), thing, 0, 0);
            folders[i] =
                EfsFiles.bind(Purpose.FOLDER, rootDir, keccak256(abi.encode("n", i)), thing, 0);
        }
        Action[] memory heads =
            _one(EfsFiles.bind(Purpose.HEAD, keccak256("a file"), 0, keccak256("a root"), 0));
        ILedgerCommitments c = ILedgerCommitments(r.hot.ingress());
        (uint32 tagOwn,,,) = c.indexFloor(address(r.ledger), tags);
        (uint32 folderOwn,,,) = c.indexFloor(address(r.ledger), folders);
        (uint32 headOwn,,,) = c.indexFloor(address(r.ledger), heads);
        vm.mockCall(
            address(r.g.index),
            abi.encodeWithSelector(IIndexReads.workModel.selector),
            abi.encode(IndexDoubleDefaults.workModel())
        );
        (uint32 tagGen1,,,) = c.indexFloor(address(r.ledger), tags);
        (uint32 folderGen1,,,) = c.indexFloor(address(r.ledger), folders);
        (uint32 headGen1,,,) = c.indexFloor(address(r.ledger), heads);
        vm.clearMockedCalls();
        assertEq(tagOwn, tagGen1, "TAG statements: no reservation for the HEAD list");
        assertEq(folderOwn, folderGen1, "FOLDER statements: no reservation for the HEAD list");
        uint256 surcharge = uint256(KernelDeploy.s1Limits().floorFreshGas)
            + KernelDeploy.s1Limits().floorRewriteGas + 27_000;
        assertEq(
            headOwn, headGen1 + surcharge, "a first HEAD statement: exactly one surcharge more"
        );
    }
}

contract HeadAuthorsFloorTest is HeadAuthorsFloorBase {
    function _setting() internal pure override returns (uint8) {
        return OWN_MODEL;
    }
}

contract HeadAuthorsFloorGen1ModelTest is HeadAuthorsFloorBase {
    function _setting() internal pure override returns (uint8) {
        return GEN1_MODEL;
    }
}

contract HeadAuthorsFloorGen1Test is HeadAuthorsFloorBase {
    function _setting() internal pure override returns (uint8) {
        return GEN1;
    }
}
