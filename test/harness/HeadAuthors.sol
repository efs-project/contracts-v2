// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {IndexProfiles} from "../../src/index/IndexProfiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {ActionKind, FamilyId, PostingKey, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {
    DigestSpec,
    Effect,
    FamilyEntry,
    Readiness,
    Unit,
    WorkModel
} from "../../src/interfaces/Index.sol";
import {IGeneration1} from "./IndexDeploy.sol";
import {IndexDoubleDefaults} from "./doubles/IndexDoubles.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";

/// Everything a test calls on the example generation: generation 1's surface and its third store.
interface IHeadAuthorsGeneration is IGeneration1 {
    function carriedCheck() external view returns (bool);
    function THIRD() external view returns (address);
    function NEW_UNITS_FROM() external view returns (uint256);
}

/// @notice EXAMPLE, NOT PRODUCT (docs INDEX-BUILD §2.2, step 3b): the read side of a generation that adds one APPEND
///         list, `head-authors` (provisional kind 22: everyone's versions of a file), in a THIRD store, beside generation
///         1's families in the two stores it carries. It extends the real `IndexReads` through its extension points
///         only: the extra family is declared after the constructor's own table (`_declare`), every posting read goes
///         to the family's own store (`_postingOf`), and the carried check covers every store (`_carriedCheck`);
///         coverage then applies the check per family, as `IndexReads._coverage` already does.
contract HeadAuthorsReads is IndexReads {
    uint8 internal constant KIND_HEAD_AUTHORS = 22;
    uint8 private constant UNIVERSE_SCOPE = 3;
    uint8 private constant SHAPE_APPEND_ = 1;
    uint8 private constant HEADS = 3;

    /// The store of `head-authors`.
    address public immutable THIRD;
    /// Units at this index and above are new in this generation: their fold hooks are built from history (docs
    /// INDEX-BUILD §3.6, §8 test 12); every unit below it is carried (folded live by an earlier generation).
    uint256 public immutable NEW_UNITS_FROM;

    constructor(
        address ledger_,
        bytes32 hotAbiId,
        address posting,
        address bitmap,
        Unit[] memory units,
        DigestSpec[] memory specs,
        WorkModel memory work,
        bytes32 topicTypeId,
        bytes32 topicWordTypeId,
        address[] memory extra,
        uint256 newUnitsFrom
    )
        IndexReads(
            ledger_, hotAbiId, posting, bitmap, units, specs, work, topicTypeId, topicWordTypeId
        )
    {
        THIRD = extra[0];
        NEW_UNITS_FROM = newUnitsFrom;
        _declare(
            "head-authors", KIND_HEAD_AUTHORS, UNIVERSE_SCOPE, SHAPE_APPEND_, HEADS, extra[0], 1
        );
    }

    function _postingOf(uint256 pos) internal view override returns (address) {
        return _families[pos - 1].store;
    }

    /// `IndexReads._carriedCheck` over three stores: the same rule, store by store.
    function _carriedCheck(address gen) internal view override returns (bool) {
        address[3] memory s = [POSTING, BITMAP, THIRD];
        (uint64 admissions,,,) = ILedgerHot(LEDGER).counts();
        if (admissions == 0) {
            return _unwritten(s[0], gen) && _unwritten(s[1], gen) && _unwritten(s[2], gen);
        }
        address live = ILedgerHot(LEDGER).index();
        if (live == gen) return true;
        bool[3] memory carried;
        bool any;
        for (uint256 i; i < 3; ++i) {
            (bool c, bool spoiled) = _storeOf(s[i], gen);
            if (spoiled) return false;
            carried[i] = c;
            any = any || c;
        }
        if (!any) return true;
        if (live.code.length == 0) return false;
        FamilyEntry[] memory theirs;
        try IRealmIndex(live).replayReadiness() returns (Readiness memory lr) {
            theirs = lr.families;
        } catch {
            return false;
        }
        for (uint256 i; i < _families.length; ++i) {
            FamilyEntry storage f = _families[i];
            if (f.fromAdmission == IndexProfiles.NOT_MAINTAINED) continue;
            uint256 at = f.store == s[0] ? 0 : f.store == s[1] ? 1 : 2;
            if (!carried[at]) continue;
            if (!_declaresFromOne(theirs, f.familyId, f.store)) return false;
        }
        return true;
    }
}

/// @notice EXAMPLE, NOT PRODUCT (docs INDEX-BUILD §2.2, step 3b): generation 1's code plus the `head-authors` list in a
///         third store, through `RealmIndex`'s extension points only (`_foldMore`, `_carried`, `_allCarried`,
///         `_spoiled`, `_hookRuns`). The list: key `(0, 22, 0, position)` with `position = Keys.position(HEAD, file, 0)`;
///         entry = the admission of each author's first HEAD statement on the file; `count` = authors who ever made a
///         HEAD statement there; `live` = authors whose HEAD there is BOUND now. Fold (§2.2): FIRST_BIND appends counted,
///         FIRST_MASK appends UNCOUNTED, RESTORE retains 1, MASK or RELEASE of a BOUND head (`oldTarget != 0`) releases
///         1, everything else does nothing. It reads nothing but the effect, so the as-of rule of §4.3 holds for it
///         with no comparison, live and from history alike.
contract HeadAuthorsIndex is RealmIndex {
    uint256 internal constant CARRIED_THIRD = 4;
    uint8 private constant FIRST_BIND = 1;
    uint8 private constant REBIND = 2;
    uint8 private constant RESTORE = 5;
    uint8 private constant FIRST_MASK = 6;
    uint64 private constant UNCOUNTED_ = uint64(1) << 63;

    address public immutable THIRD;
    uint256 public immutable NEW_UNITS_FROM;
    bytes32 private immutable F_HEAD_AUTHORS;

    constructor(address ledger_, address decoder, address reads)
        RealmIndex(ledger_, decoder, reads)
    {
        THIRD = HeadAuthorsReads(reads).THIRD();
        NEW_UNITS_FROM = HeadAuthorsReads(reads).NEW_UNITS_FROM();
        F_HEAD_AUTHORS = Keys.familyId("head-authors");
    }

    function _foldMore(Effect calldata e, bytes32[] calldata, uint256 carried) internal override {
        if (carried & CARRIED_THIRD != 0 || e.purpose != Purpose.HEAD) return;
        uint8 kind = e.kind;
        if (kind != ActionKind.BIND && kind != ActionKind.UNBIND && kind != ActionKind.RELEASE) {
            return;
        }
        uint8 tk = e.transitionKind;
        FamilyId f = FamilyId.wrap(F_HEAD_AUTHORS);
        PostingKey key = PostingKey.wrap(Keys.posting(0, 22, 0, e.position));
        IPostingStore s = IPostingStore(THIRD);
        if (tk == FIRST_BIND) {
            s.append(f, key, e.admission, 0);
        } else if (tk == FIRST_MASK) {
            s.append(f, key, e.admission | UNCOUNTED_, 0);
        } else if (tk == RESTORE) {
            s.retain(f, key, 1);
        } else if (tk != REBIND && e.oldTarget != 0) {
            // MASK (from any state) or RELEASE of a head that was BOUND
            s.release(f, key, 1);
        }
    }

    function _carried() internal view override returns (uint256 mask) {
        mask = super._carried();
        if (!_isFresh(THIRD)) mask |= CARRIED_THIRD;
    }

    function _allCarried() internal pure override returns (uint256) {
        return super._allCarried() | CARRIED_THIRD;
    }

    function _spoiled() internal view override returns (bool) {
        return super._spoiled() || _isSpoiled(THIRD);
    }

    /// A new unit's fold hook is built from history with the walk (it gets the same effects as live, in order); a
    /// carried unit's is called only live (mask 0), as generation 1 does.
    function _hookRuns(uint256 unit, uint256 carried) internal view override returns (bool) {
        return carried == 0 || unit >= NEW_UNITS_FROM;
    }
}

/// @notice EXAMPLE, NOT PRODUCT (docs INDEX-BUILD §5.3, step 3b, the dropped-list test): generation 1's code plus one
///         list X in the POSTING store itself, `subjects-created` (provisional kind 23): key `(0, 23, 0, creator)`,
///         entry = the admission of each CREATE. Folded on CREATE only, so a publication of CREATEs writes X and
///         nothing else. Built with the production `IndexDeployer` (its reads take `IndexReads`' arguments).
contract CreatorsReads is IndexReads {
    constructor(
        address ledger_,
        bytes32 hotAbiId,
        address posting,
        address bitmap,
        Unit[] memory units,
        DigestSpec[] memory specs,
        WorkModel memory work,
        bytes32 topicTypeId,
        bytes32 topicWordTypeId
    )
        IndexReads(
            ledger_, hotAbiId, posting, bitmap, units, specs, work, topicTypeId, topicWordTypeId
        )
    {
        _declare("subjects-created", 23, 2, 1, 1, posting, 1);
    }
}

/// @notice See `CreatorsReads`.
contract CreatorsIndex is RealmIndex {
    bytes32 private immutable F_CREATED;

    constructor(address ledger_, address decoder, address reads)
        RealmIndex(ledger_, decoder, reads)
    {
        F_CREATED = Keys.familyId("subjects-created");
    }

    function _foldMore(Effect calldata e, bytes32[] calldata, uint256 carried) internal override {
        if (carried & CARRIED_POSTING != 0 || e.kind != ActionKind.CREATE) return;
        IPostingStore(POSTING)
            .append(
                FamilyId.wrap(F_CREATED),
                PostingKey.wrap(Keys.posting(0, 23, 0, e.principalId)),
                e.admission,
                0
            );
    }
}

/// @notice A unit's fold hook that records every effect it is given, as a hash chain and a count (docs INDEX-BUILD
///         §3.6, §8 test 12). It obeys rule (i) of §3.6: it is exact on its own, because it uses only the effect and
///         the publication it is given and reads no ledger fact at all, so it records the same chain live and from
///         history.
contract RecordingFoldHook is IIndexHook {
    bytes32 public chain;
    uint256 public calls;

    function fold(Effect calldata e, bytes32[] calldata refs, uint64 publication)
        external
        returns (bytes4)
    {
        chain = keccak256(
            abi.encode(chain, publication, e.admission, e.kind, e.purpose, e.position, refs)
        );
        ++calls;
        return IIndexHook.fold.selector;
    }

    function validate(uint64, Effect[] calldata, bytes32[] calldata)
        external
        pure
        returns (bytes4)
    {
        return IIndexHook.validate.selector;
    }
}

/// @notice EXAMPLE, NOT PRODUCT: a deployer for a generation whose plan is a LIST of stores, each carried (an address)
///         or fresh (initcode and families, created with `INITIAL_WRITER` = the nonce-predicted generation). Slot 0 is
///         the posting store, slot 1 the bitmap store, every further slot an extra store of the reads contract
///         (`HeadAuthorsReads`: `extra[0]` holds `head-authors`). The production `IndexDeployer` has one slot of each
///         kind and stays as it is (docs INDEX-BUILD §3.1).
contract ListIndexDeployer {
    struct Store {
        bytes initcode; // empty: carried
        bytes32[] families;
        address carried;
    }

    struct Plan {
        bytes32 hotAbiId;
        address decoder;
        Store[] stores;
        bytes readsInitcode;
        bytes generationInitcode;
        Unit[] units;
        DigestSpec[] specs;
        WorkModel work;
        bytes32 topicTypeId;
        bytes32 topicWordTypeId;
        uint256 newUnitsFrom;
    }

    /// The reads constructor's arguments as one tuple (see `IndexDeploy.ReadsArgs`).
    struct ReadsArgs {
        address ledger;
        bytes32 hotAbiId;
        address posting;
        address bitmap;
        Unit[] units;
        DigestSpec[] specs;
        WorkModel work;
        bytes32 topicTypeId;
        bytes32 topicWordTypeId;
        address[] extra;
        uint256 newUnitsFrom;
    }

    error E_LIST_DEPLOYER(uint8 code);

    address public immutable LEDGER;
    bytes32 public immutable PLAN_HASH;
    address public generation;
    address public reads;
    address[] internal _stores;

    constructor(address ledger, bytes32 planHash_) {
        LEDGER = ledger;
        PLAN_HASH = planHash_;
    }

    function stores() external view returns (address[] memory) {
        return _stores;
    }

    function store(uint256 i) external view returns (address) {
        return _stores[i];
    }

    function run(Plan calldata plan) external returns (address gen) {
        if (generation != address(0)) revert E_LIST_DEPLOYER(0);
        if (keccak256(abi.encode(plan)) != PLAN_HASH) revert E_LIST_DEPLOYER(1);
        if (plan.stores.length < 3) revert E_LIST_DEPLOYER(5);
        uint256 fresh;
        for (uint256 i; i < plan.stores.length; ++i) {
            if (plan.stores[i].initcode.length != 0) ++fresh;
        }
        address predicted = _creation(uint8(fresh + 2));
        uint8 nonce = 1;
        for (uint256 i; i < plan.stores.length; ++i) {
            Store calldata s = plan.stores[i];
            address a = s.carried;
            if (s.initcode.length != 0) {
                a = _create(bytes.concat(s.initcode, abi.encode(LEDGER, predicted, s.families)));
                if (a != _creation(nonce++)) revert E_LIST_DEPLOYER(2);
            }
            _stores.push(a);
        }
        ReadsArgs memory x;
        x.ledger = LEDGER;
        x.hotAbiId = plan.hotAbiId;
        x.posting = _stores[0];
        x.bitmap = _stores[1];
        x.units = plan.units;
        x.specs = plan.specs;
        x.work = plan.work;
        x.topicTypeId = plan.topicTypeId;
        x.topicWordTypeId = plan.topicWordTypeId;
        x.extra = new address[](_stores.length - 2);
        for (uint256 i = 2; i < _stores.length; ++i) {
            x.extra[i - 2] = _stores[i];
        }
        x.newUnitsFrom = plan.newUnitsFrom;
        address r = _create(_withArgs(plan.readsInitcode, abi.encode(x)));
        if (r != _creation(nonce)) revert E_LIST_DEPLOYER(2);
        gen = _create(bytes.concat(plan.generationInitcode, abi.encode(LEDGER, plan.decoder, r)));
        if (gen != predicted) revert E_LIST_DEPLOYER(3);
        if (IRealmIndex(gen).replayReadiness().ledger != LEDGER) revert E_LIST_DEPLOYER(4);
        generation = gen;
        reads = r;
    }

    /// `encoded` is `abi.encode(struct)`: its leading offset word dropped, it is the constructor's argument encoding.
    function _withArgs(bytes memory init, bytes memory encoded)
        internal
        pure
        returns (bytes memory code)
    {
        code = new bytes(init.length + encoded.length - 32);
        assembly ("memory-safe") {
            mcopy(add(code, 32), add(init, 32), mload(init))
            mcopy(add(add(code, 32), mload(init)), add(encoded, 64), sub(mload(encoded), 32))
        }
    }

    function _create(bytes memory initcode) private returns (address created) {
        assembly ("memory-safe") {
            created := create(0, add(initcode, 32), mload(initcode))
        }
        if (created == address(0)) revert E_LIST_DEPLOYER(2);
    }

    function _creation(uint8 nonce) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), nonce)))));
    }
}

/// @notice EXAMPLE, NOT PRODUCT: the example generation at a Realm's genesis, over three new stores whose
///         `INITIAL_WRITER` is 0 (as genesis stores are), for Realm L of docs INDEX-BUILD §8 test 1 and the floor suite.
library HeadAuthorsGenesis {
    struct Deployed {
        address posting;
        address bitmap;
        address third;
        address reads;
        address index;
    }

    /// The example generation's work model (docs INDEX-BUILD §6.3): generation 1's, plus what `head-authors` costs
    /// live. The model has no per-purpose term, so the list's price is charged on every bind-kind action (an upper
    /// bound for the other purposes); `test/index/HeadAuthorsFloor.t.sol` measures it.
    function workModel() internal pure returns (WorkModel memory w) {
        w = IndexDoubleDefaults.workModel();
        w.freshPerBindFresh += 10; // a first HEAD statement: one fresh slot (the list's head, or its word 0)
        w.rwPerBind += 10; // the list's head rewritten (a later author's first statement)
        w.rwPerBindLater += 10; // a restore, a mask or a release of a BOUND head: the counter
        // the CALL to the third store (cold on a publication's first HEAD statement) and its writer rule. With the
        // slot terms above, a first statement is quoted 54.1k more on prague and 44.1k on amsterdam, a later one 37k;
        // measured (`test/index/HeadAuthorsFloor.t.sol`), the list costs a first statement 41.6k to 46.5k on prague
        // and 32.1k to 44.1k on amsterdam, a later one 22.9k to 23.1k and 30.5k to 30.6k
        w.computePerHookEffect += 27_000;
    }

    function headFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](1);
        f[0] = Keys.familyId("head-authors");
    }

    function readsCode(ListIndexDeployer.ReadsArgs memory x)
        internal
        pure
        returns (bytes memory code)
    {
        bytes memory encoded = abi.encode(x);
        bytes memory init = type(HeadAuthorsReads).creationCode;
        code = new bytes(init.length + encoded.length - 32);
        assembly ("memory-safe") {
            mcopy(add(code, 32), add(init, 32), mload(init))
            mcopy(add(add(code, 32), mload(init)), add(encoded, 64), sub(mload(encoded), 32))
        }
    }

    function create(bytes memory code) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 32), mload(code))
            if iszero(a) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// `x.ledger`, `x.hotAbiId`, `x.units`, `x.specs`, `x.work` and the topic ids as the Realm wants them; the stores,
    /// `extra` and `newUnitsFrom` are set here (no unit is new at genesis).
    function deploy(
        ListIndexDeployer.ReadsArgs memory x,
        bytes32[] memory postingFamilies,
        bytes32[] memory bitmapFamilies
    ) internal returns (Deployed memory d) {
        d.posting = address(new PostingStore(x.ledger, address(0), postingFamilies));
        d.bitmap = address(new BitmapStore(x.ledger, address(0), bitmapFamilies));
        d.third = address(new PostingStore(x.ledger, address(0), headFamilies()));
        x.posting = d.posting;
        x.bitmap = d.bitmap;
        x.extra = new address[](1);
        x.extra[0] = d.third;
        x.newUnitsFrom = x.units.length;
        d.reads = create(readsCode(x));
        d.index = address(new HeadAuthorsIndex(x.ledger, address(0), d.reads));
    }
}
