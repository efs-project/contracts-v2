// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsBase} from "../integration/TopicListsBase.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {TopicPageReader} from "../../src/readers/TopicPageReader.sol";
import {TopicLookupReader} from "../../src/readers/TopicLookupReader.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicPageReader,
    MineRow,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";

/// @notice The topic reader suites' fixture: the Files and Topics Realm of `TopicListsBase` (real kernel, registry,
///         generation-1 index with the topic lists and `FilesFinalValidator`), the two read facets and both topic
///         readers over them, plus writers for many authors, child topics, files at homes and cooled reads.
abstract contract TopicReadersBase is TopicListsBase {
    uint8 internal constant SCAN_EXHAUSTED = 1;
    uint8 internal constant SCAN_LIMIT = 2;
    uint8 internal constant SCAN_GAS = 3;

    LedgerReads internal reads;
    LedgerViews internal views;
    TopicPageReader internal pager;
    TopicLookupReader internal lookup;
    EfsFiles.Types internal ft;

    function setUp() public virtual override {
        super.setUp();
        reads = new LedgerReads();
        views = new LedgerViews();
        pager = new TopicPageReader(address(r.ledger), address(views), address(reads));
        lookup = new TopicLookupReader(
            address(r.ledger),
            address(views),
            address(reads),
            typeIds[T_TOPIC],
            typeIds[T_TOPIC_WORD]
        );
        ft.root = typeIds[T_ROOT];
        ft.child = typeIds[T_CHILD];
        ft.directory = typeIds[T_DIRECTORY];
        ft.name = typeIds[T_NAME];
        ft.bytes_ = typeIds[T_BYTES];
        ft.content = typeIds[T_CONTENT];
        ft.external_ = typeIds[T_EXTERNAL];
        ft.alias_ = typeIds[T_ALIAS];
        ft.notice = typeIds[T_NOTICE];
        ft.span = typeIds[T_SPAN];
    }

    // ---- authors, topics, things ----------------------------------------------------------------------------

    function _authorsN(string memory label, uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = makeAddr(string.concat(label, "-", vm.toString(i)));
        }
    }

    function _lensOf(address[] memory a) internal view returns (bytes32[] memory l) {
        l = new bytes32[](a.length);
        for (uint256 i; i < a.length; ++i) {
            l[i] = _pid(a[i]);
        }
    }

    function _lens1(address a) internal view returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = _pid(a);
    }

    function _lens2(address a, address b) internal view returns (bytes32[] memory l) {
        l = new bytes32[](2);
        l[0] = _pid(a);
        l[1] = _pid(b);
    }

    /// A child topic `word` under `parent`, registering the word's page when it is new.
    function _child(bytes32 parent, bytes memory word, bool withPage)
        internal
        returns (bytes32 id)
    {
        (Action[] memory a, bytes[] memory b, bytes32 t) =
            EfsTopics.registerChild(_topicTypes(), parent, word, withPage);
        _execAs(address(this), a, b);
        return t;
    }

    /// `n` more created subjects of this contract (real things to tag).
    function _things(uint256 n) internal returns (bytes32[] memory out) {
        out = new bytes32[](n);
        uint256 base = things.length;
        for (uint256 from; from < n; from += 64) {
            uint256 m = n - from < 64 ? n - from : 64;
            Action[] memory a = new Action[](m);
            for (uint256 i; i < m; ++i) {
                a[i] = _create(keccak256(abi.encode("readers/thing", base + from + i)));
                out[from + i] = Keys.subject(p, a[i].saltOrStrength);
                things.push(out[from + i]);
            }
            _execAs(address(this), a, new bytes[](m));
        }
    }

    /// `who` tags each of `xs` at `topic` (number 0) in one publication.
    function _tagMany(address who, bytes32 topic, bytes32[] memory xs) internal {
        for (uint256 from; from < xs.length; from += 64) {
            uint256 m = xs.length - from < 64 ? xs.length - from : 64;
            Action[] memory a = new Action[](m);
            for (uint256 i; i < m; ++i) {
                a[i] = EfsTopics.tag(topic, xs[from + i], 0, 0);
            }
            _execAs(who, a, new bytes[](m));
        }
    }

    /// `who` attaches a file named `name` to `home` (a FOLDER entry at the address's place).
    function _attach(address who, bytes32 home, bytes memory name) internal returns (bytes32 file) {
        (Action[] memory a, bytes[] memory b, bytes32 f,) = EfsFiles.createFile(
            ft, _pid(who), home, keccak256(abi.encode(home, name, who)), name, "doc", true
        );
        _execAs(who, a, b);
        return f;
    }

    // ---- reads ---------------------------------------------------------------------------------------------

    function _unbound() internal pure returns (BasisCommit memory b) {}

    function _mine(
        bytes32[] memory lens,
        bytes32 place,
        bool below,
        bytes memory cont,
        uint32 limit
    ) internal view returns (TopicPageInfo memory, MineRow[] memory) {
        return pager.mine(lens, place, below, _unbound(), cont, limit, 0);
    }

    function _everyone(
        bytes32 place,
        bool below,
        bytes32[] memory lens,
        bool raw,
        uint16 sample,
        bytes memory cont,
        uint32 limit
    ) internal view returns (TopicPageInfo memory, PlaceRow[] memory) {
        return pager.everyone(
            ITopicPageReader.PlaceQuery(Purpose_TAG, place, below, raw, sample),
            lens,
            _unbound(),
            cont,
            limit,
            0
        );
    }

    bytes32 internal constant Purpose_TAG = keccak256("efs/purpose/tag/1");
    bytes32 internal constant Purpose_FOLDER = keccak256("efs/purpose/folder/1");

    /// Cools every account a read touches, so the next call is a call of its own in a fresh transaction.
    function _cool() internal {
        vm.cool(address(r.ledger));
        vm.cool(address(r.k.implementation));
        vm.cool(address(r.g.index));
        vm.cool(address(r.g.posting));
        vm.cool(address(r.g.bitmap));
        vm.cool(address(r.g.reads));
        vm.cool(address(r.k.ingress));
        vm.cool(address(r.registry));
        vm.cool(address(reads));
        vm.cool(address(views));
        vm.cool(address(pager));
        vm.cool(address(lookup));
    }

    function _ok(TopicPageInfo memory info) internal pure {
        assertEq(uint8(info.q.status), uint8(Status.PRESENT), "page status");
    }
}
