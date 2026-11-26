// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsBase} from "./TopicListsBase.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, FamilyId, PostingKey, Purpose, ScopeKey} from "../../src/interfaces/Actions.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";

/// @notice The mixed history of the first-statement list suites on the real Files Realm (`TopicListsReplay.t.sol`,
///         `test/index/BuildWalk.t.sol`), recording every list it can touch, with the generation and comparison
///         helpers those suites share: a later generation from `IndexDeployer` over fresh or carried stores, every
///         recorded list of two store pairs compared head by head and entry by entry, and activation by this
///         contract (the Realm's controller).
abstract contract TopicListsHistory is TopicListsBase {
    PostingKey[] internal postingKeys; // every list of families 5, 6, 7, 8, 11, 16, 19, 20, 21 the history touches
    bytes32[] internal scopeKeys; // every family-10 scope list it touches
    bytes32[] internal topicIds; // every registered topic (the ancestors any walk can reach)
    address[] internal authors;
    /// The ledger's revision, followed by `_activate`.
    uint32 internal revision = 1;

    function setUp() public virtual override {
        super.setUp();
        authors.push(address(this));
        authors.push(alice);
        authors.push(bob);
        authors.push(carol);
    }

    // ---- the history, recording every list it can touch ---------------------------------------------------------

    function _say(address who, Action memory x) internal {
        _act(who, x);
        bytes32 pid = _pid(who);
        bytes32 position = Keys.position(x.purpose, x.subject, x.role);
        postingKeys.push(PostingKey.wrap(Keys.historyList(Keys.binding(pid, position))));
        postingKeys.push(
            PostingKey.wrap(Keys.posting(0, 16, 0, Keys.roleScope(pid, x.purpose, x.role)))
        );
        postingKeys.push(PostingKey.wrap(Keys.placeList(x.purpose, x.subject)));
        postingKeys.push(PostingKey.wrap(Keys.positionAuthorsList(position)));
        postingKeys.push(PostingKey.wrap(Keys.rolePlacesList(x.purpose, x.role)));
        if (x.target != 0) {
            postingKeys.push(PostingKey.wrap(Keys.backlinkList(x.purpose, x.target)));
        }
        scopeKeys.push(Keys.scope(pid, x.purpose, x.subject));
    }

    function _path(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        t = _regPath(name, n);
        EfsTopics.Types memory tt = _topicTypes();
        bytes[] memory w = _words(name, n);
        for (uint256 i; i < n; ++i) {
            topicIds.push(t[i]);
            bytes32 page = EfsTopics.wordPageId(tt.word, w[i]);
            postingKeys.push(PostingKey.wrap(Keys.referenceList(tt.topic, 1, page)));
            if (i != 0) {
                postingKeys.push(PostingKey.wrap(Keys.referenceList(tt.topic, 0, t[i - 1])));
            }
        }
    }

    function _tagAs(address who, bytes32 topic, bytes32 thing, uint16 n) internal {
        _say(who, EfsTopics.tag(topic, thing, _rev(who, Purpose.TAG, topic, thing), n));
    }

    function _denyAs(address who, bytes32 topic, bytes32 thing) internal {
        _say(who, EfsTopics.deny(topic, thing, _rev(who, Purpose.TAG, topic, thing), 3));
    }

    function _releaseAs(address who, bytes32 purpose, bytes32 subject, bytes32 role) internal {
        _say(who, EfsFiles.release(purpose, subject, role, _rev(who, purpose, subject, role)));
    }

    function _mixedHistory() internal {
        bytes32[] memory a = _path("mix", 6); // mix-0 .. mix-0/../mix-5
        bytes32[] memory b = _path("branch", 3);
        bytes32 one = _path("solo", 1)[0];
        bytes32 thing = things[0];
        // tags by several authors, a second author on an existing position, a lone negative
        _tagAs(alice, a[5], thing, 0);
        _tagAs(bob, a[5], thing, 10);
        _denyAs(carol, a[5], thing);
        _tagAs(alice, a[2], things[1], 0);
        _denyAs(bob, b[2], things[2]); // a lone negative on a fresh position
        _tagAs(carol, one, things[3], 0);
        // number changes, masks, restores, releases, remove-and-add-back
        _tagAs(alice, a[5], thing, 75);
        _tagAs(alice, a[5], thing, 4);
        _denyAs(alice, a[5], thing);
        _tagAs(alice, a[5], thing, 0);
        _releaseAs(bob, Purpose.TAG, a[5], thing);
        _tagAs(bob, a[5], thing, 1);
        _releaseAs(alice, Purpose.TAG, a[2], things[1]);
        _tagAs(alice, a[2], things[1], 0);
        _denyAs(bob, b[2], things[2]);
        _releaseAs(bob, Purpose.TAG, b[2], things[2]);
        _denyAs(bob, b[2], things[2]);
        // a home subject and an address target
        bytes32 home = bytes32(uint256(uint160(alice)));
        bytes32 addr = bytes32(uint256(uint160(makeAddr("replay/address-target"))));
        _tagAs(alice, home, things[4], 0);
        _tagAs(bob, a[3], addr, 0);
        _tagAs(carol, home, addr, 0);
        // a FOLDER position with several authors (a home folder), with a move and a re-bind
        bytes32 role = keccak256("shared.txt");
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("shared.txt");
        _execAs(address(this), x, y);
        _say(alice, _bind(Purpose.FOLDER, home, role, things[5], 0));
        _say(bob, _bind(Purpose.FOLDER, home, role, things[6], 0));
        _say(carol, _bind(Purpose.FOLDER, home, role, things[5], 0));
        _say(
            alice,
            _bind(Purpose.FOLDER, home, role, things[7], _rev(alice, Purpose.FOLDER, home, role))
        );
        _releaseAs(bob, Purpose.FOLDER, home, role);
        _say(address(this), _bind(Purpose.FOLDER, rootDir, role, things[8], 0));
        // the yes-count of a FOLDER position: a restore from released, a mask of an asserted head, a lone hide of
        // another author's entry and its release
        _say(
            bob, _bind(Purpose.FOLDER, home, role, things[6], _rev(bob, Purpose.FOLDER, home, role))
        );
        _say(
            carol,
            EfsFiles.unbind(Purpose.FOLDER, home, role, _rev(carol, Purpose.FOLDER, home, role))
        );
        _say(alice, EfsFiles.unbind(Purpose.FOLDER, rootDir, role, 0));
        _releaseAs(alice, Purpose.FOLDER, rootDir, role);
        // same, broader and property statements (no new lists; their exact lists still compare)
        _say(alice, EfsTopics.same(a[0], b[0], 0));
        _say(bob, EfsTopics.broader(b[1], a[1], 0));
        _say(carol, EfsTopics.property(a[2], EfsTopics.labelKey("en"), things[9], 0));
        // a statement on a deeper level after its ancestors' lists exist
        _tagAs(carol, a[4], thing, 0);
        _tagAs(address(this), a[5], things[10], 0);
        _rollUpKeys();
    }

    /// Records the roll-up lists (families 7 and 19) of every registered topic and author.
    function _rollUpKeys() internal {
        for (uint256 i; i < topicIds.length; ++i) {
            postingKeys.push(PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, topicIds[i])));
            for (uint256 j; j < authors.length; ++j) {
                postingKeys.push(
                    PostingKey.wrap(Keys.scopeBelowList(_pid(authors[j]), Purpose.TAG, topicIds[i]))
                );
            }
        }
    }

    /// The counters the history must have moved (docs INDEX-BUILD §4.2), read from `live`: three authors at the shared
    /// TAG position, a place and its roll-up with more filings than positions, and two yes-counts below their author
    /// counts (TAG and FOLDER).
    function _assertCountersMoved(IPostingStore live) internal view {
        bytes32 thing = things[0];
        bytes32 deep = _prefixes(_words("mix", 6))[5];
        (uint64 authorsAt,,,) = live.postingHead(
            PostingKey.wrap(Keys.positionAuthorsList(Keys.position(Purpose.TAG, deep, thing)))
        );
        assertEq(authorsAt, 3, "three authors at the shared position");
        // both counters were exercised: a place with more filings than positions, a position whose yes-count is
        // below its author count
        (uint64 c, uint64 l,,) =
            live.postingHead(PostingKey.wrap(Keys.placeList(Purpose.TAG, deep)));
        assertGt(c, l, "a later first yes was filed at the place");
        (c, l,,) = live.postingHead(PostingKey.wrap(Keys.placeBelowList(Purpose.TAG, topicIds[0])));
        assertGt(c, l, "and below it");
        (c, l,,) = live.postingHead(
            PostingKey.wrap(Keys.positionAuthorsList(Keys.position(Purpose.TAG, deep, thing)))
        );
        assertEq(
            abi.encode(c, l), abi.encode(uint64(3), uint64(2)), "alice and bob say yes, carol no"
        );
        bytes32 home = bytes32(uint256(uint160(alice)));
        (c, l,,) = live.postingHead(
            PostingKey.wrap(
                Keys.positionAuthorsList(
                    Keys.position(Purpose.FOLDER, home, keccak256("shared.txt"))
                )
            )
        );
        assertEq(
            abi.encode(c, l), abi.encode(uint64(3), uint64(2)), "alice and bob say yes at the home"
        );
    }

    // ---- later generations ------------------------------------------------------------------------------------------

    /// A generation of generation 1's code over `posting` and `bitmap`, each carried when nonzero and fresh (a new
    /// store naming the generation as INITIAL_WRITER) when zero, with the Realm's units, specs and topic Types.
    function _generation(address posting, address bitmap)
        internal
        returns (IndexDeployer d, IGeneration1 ix)
    {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        if (posting == address(0)) plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.posting = posting;
        if (bitmap == address(0)) plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.bitmap = bitmap;
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = _units();
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.topicTypeId = typeIds[T_TOPIC];
        plan.topicWordTypeId = typeIds[T_TOPIC_WORD];
        d = new IndexDeployer(address(r.ledger), keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
        assertEq(ix.manifestHash() == r.g.index.manifestHash(), false, "a new generation");
    }

    // ---- comparison -------------------------------------------------------------------------------------------------

    /// One hash per recorded list: posting lists (head and every entry) in `ps`, then scope lists (head, every entry
    /// and every live-scope word) in `bs`. Two store pairs hold the same recorded state exactly when the arrays are
    /// equal; `nonEmpty` and `entries` count the non-empty posting lists and their entries.
    function _capture(IPostingStore ps, IBitmapStore bs)
        internal
        view
        returns (bytes32[] memory h, uint256 nonEmpty, uint256 entries)
    {
        h = new bytes32[](postingKeys.length + scopeKeys.length);
        for (uint256 i; i < postingKeys.length; ++i) {
            (uint64 c, uint64 l, uint64 last, uint16 f) = ps.postingHead(postingKeys[i]);
            bytes memory e;
            if (c != 0) {
                ++nonEmpty;
                entries += c;
                e = abi.encode(ps.postingSlice(postingKeys[i], 0, uint16(c)));
            }
            h[i] = keccak256(abi.encode(c, l, last, f, e));
        }
        FamilyId liveScope = FamilyId.wrap(Keys.familyId("live-scope"));
        for (uint256 i; i < scopeKeys.length; ++i) {
            ScopeKey sk = ScopeKey.wrap(scopeKeys[i]);
            (uint64 c, uint64 l, uint64 m, uint48 bits, uint16 f, uint64 e0) = bs.scopeHead(sk);
            h[postingKeys.length + i] = keccak256(
                abi.encode(
                    c,
                    l,
                    m,
                    bits,
                    f,
                    e0,
                    bs.scopeSlice(sk, 0, uint16(c)),
                    bs.liveWords(sk, liveScope, 0, uint16(c / 256 + 1))
                )
            );
        }
    }

    /// Every recorded list is the same in the two store pairs; returns the non-empty posting lists and their entries.
    function _assertSameStores(
        IPostingStore pa,
        IBitmapStore ba,
        IPostingStore pb,
        IBitmapStore bb,
        string memory what
    ) internal view returns (uint256 nonEmpty, uint256 entries) {
        bytes32[] memory x;
        (x, nonEmpty, entries) = _capture(pa, ba);
        (bytes32[] memory y,,) = _capture(pb, bb);
        _assertSameCapture(x, y, what);
    }

    function _assertSameCapture(bytes32[] memory x, bytes32[] memory y, string memory what)
        internal
        view
    {
        assertEq(x.length, y.length, string.concat(what, ": lists"));
        for (uint256 i; i < x.length; ++i) {
            if (x[i] != y[i]) {
                revert(
                    string.concat(
                        what,
                        i < postingKeys.length ? ": posting list " : ": scope list ",
                        vm.toString(i < postingKeys.length ? i : i - postingKeys.length)
                    )
                );
            }
        }
    }

    // ---- activation (this contract is the Realm's controller) --------------------------------------------------------

    function _set(address ix) internal view returns (ActivationSet memory set) {
        set = KernelDeploy.genesisSet(
            r.k, address(this), address(r.registryImpl), ix, IGeneration1(ix).manifestHash()
        );
        set.revision = revision + 1;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, r.k.proxy);
    }

    /// The registry's activation and the ledger's in one call, so a refused activation also rolls the registry back
    /// (a registry ahead of the ledger refuses every write, `E_REGISTRY_DRIFT`). Called as `this.activateNow`.
    function activateNow(address ix) external {
        require(msg.sender == address(this), "self");
        ActivationSet memory set = _set(ix);
        r.registry.activate(set.revision);
        ILedgerControl(r.k.proxy).activate(set);
        revision = set.revision;
    }
}
