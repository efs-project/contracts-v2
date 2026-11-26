// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PostingStoreStorage, WriterRange} from "./storage/StoreStorage.sol";
import {StoreBase} from "./StoreBase.sol";
import {FamilyId, PostingKey} from "../interfaces/Actions.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {E_ORDER, E_WRITER} from "../interfaces/Errors.sol";

/// @title PostingStore — append-ordered posting lists that outlive index generations (design §4.6, §10.1)
/// @notice One per Realm and family set. Entries are strictly increasing ordinals, five per word; the first
///         entry of a key lives in the head word (`last`) until a second append materializes word 0, so a
///         singleton list costs one slot. Writes come only through the authorization of `StoreBase`. The family
///         set (at most `FAMILY_CAPACITY` ids: generation 1's sixteen APPEND families, the ten of the core, the five
///         lists of the tag design and `head-authors`, with room for one more) is held as immutables, so a family
///         check reads no storage; `familyIds()` keeps the same ids in the same order in storage for readiness checks.
contract PostingStore is IPostingStore, PostingStoreStorage, StoreBase {
    /// keccak("efs/posting-store/2" ‖ for each IPostingStore function by selector: selector ‖ keccak(output tuple))
    /// (tools/abi-id.mjs; `pnpm abi:check` recomputes it from the committed snapshot).
    bytes32 public constant STORE_ABI_ID =
        0x420c69c26d04ae5ba1cacc694d440d5257b35567851f953775e889406066128a;

    uint256 private constant MASK48 = (1 << 48) - 1;
    /// Bit 63 of an appended ordinal: append the entry without raising `live` (`IPostingStore.append`).
    uint64 public constant UNCOUNTED = uint64(1) << 63;
    uint256 public constant FAMILY_CAPACITY = 17;

    bytes32 private immutable F0;
    bytes32 private immutable F1;
    bytes32 private immutable F2;
    bytes32 private immutable F3;
    bytes32 private immutable F4;
    bytes32 private immutable F5;
    bytes32 private immutable F6;
    bytes32 private immutable F7;
    bytes32 private immutable F8;
    bytes32 private immutable F9;
    bytes32 private immutable F10;
    bytes32 private immutable F11;
    bytes32 private immutable F12;
    bytes32 private immutable F13;
    bytes32 private immutable F14;
    bytes32 private immutable F15;
    bytes32 private immutable F16;

    constructor(address ledger_, address initialWriter_, bytes32[] memory families)
        StoreBase(ledger_, initialWriter_)
    {
        _checkFamilies(families, FAMILY_CAPACITY);
        F0 = _familyAt(families, 0);
        F1 = _familyAt(families, 1);
        F2 = _familyAt(families, 2);
        F3 = _familyAt(families, 3);
        F4 = _familyAt(families, 4);
        F5 = _familyAt(families, 5);
        F6 = _familyAt(families, 6);
        F7 = _familyAt(families, 7);
        F8 = _familyAt(families, 8);
        F9 = _familyAt(families, 9);
        F10 = _familyAt(families, 10);
        F11 = _familyAt(families, 11);
        F12 = _familyAt(families, 12);
        F13 = _familyAt(families, 13);
        F14 = _familyAt(families, 14);
        F15 = _familyAt(families, 15);
        F16 = _familyAt(families, 16);
        PostingStorage storage $ = _posting();
        for (uint256 i; i < families.length; ++i) {
            $.familyIds.push(families[i]);
        }
    }

    // ---- StoreBase hooks ---------------------------------------------------------------------------------

    function _familyIds() internal view override returns (bytes32[] storage) {
        return _posting().familyIds;
    }

    function _isFamily(bytes32 f) internal view override returns (bool) {
        return f != 0
            && (f == F0
                || f == F1
                || f == F2
                || f == F3
                || f == F4
                || f == F5
                || f == F6
                || f == F7
                || f == F8
                || f == F9
                || f == F10
                || f == F11
                || f == F12
                || f == F13
                || f == F14
                || f == F15
                || f == F16);
    }

    function _writers() internal view override returns (WriterRange[] storage) {
        return _posting().writers;
    }

    function _attached() internal view override returns (bool) {
        return _posting().attached != 0;
    }

    function _setAttached() internal override {
        _posting().attached = 1;
    }

    // ---- writes ------------------------------------------------------------------------------------------

    /// @inheritdoc IPostingStore
    function append(FamilyId family, PostingKey key, uint64 ordinal, uint16 flagsOr)
        external
        returns (uint64 count)
    {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender); // append-ordered lists are never backfilled
        return _append(PostingKey.unwrap(key), ordinal, flagsOr);
    }

    /// @inheritdoc IPostingStore
    /// @dev Equivalent to `append(families[i], keys[i], ordinals[i], 0)` for each i in order, with the writer rule
    ///      asked once: entry 0's family is checked before it (the error a lone append would raise first), every
    ///      entry's family and order law are checked as `append` checks them, and an empty batch writes nothing and
    ///      attaches nothing. Arrays of different lengths revert `E_ORDER(keys.length, other length)`.
    function appendBatch(
        FamilyId[] calldata families,
        PostingKey[] calldata keys,
        uint64[] calldata ordinals
    ) external {
        uint256 n = keys.length;
        if (families.length != n) revert E_ORDER(uint64(n), uint64(families.length));
        if (ordinals.length != n) revert E_ORDER(uint64(n), uint64(ordinals.length));
        if (n == 0) return;
        _requireFamily(FamilyId.unwrap(families[0]));
        (uint8 mode,) = _authorizeWriter();
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender); // append-ordered lists are never backfilled
        _append(PostingKey.unwrap(keys[0]), ordinals[0], 0);
        for (uint256 i = 1; i < n; ++i) {
            _requireFamily(FamilyId.unwrap(families[i]));
            _append(PostingKey.unwrap(keys[i]), ordinals[i], 0);
        }
    }

    /// @inheritdoc IPostingStore
    function release(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live) {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        PostingHead storage h = _posting().heads[PostingKey.unwrap(key)];
        if (n > h.live) revert E_ORDER(h.live, n);
        h.live -= uint48(n);
        return h.live;
    }

    /// @inheritdoc IPostingStore
    function retain(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live) {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        PostingHead storage h = _posting().heads[PostingKey.unwrap(key)];
        uint64 raised = uint64(h.live) + n;
        if (raised > h.count) revert E_ORDER(h.count, raised);
        h.live = uint48(raised);
        return raised;
    }

    /// One entry: `tagged` is the ordinal with bit 63 (`UNCOUNTED`) set when `live` is not raised; the entry itself
    /// is the low 63 bits, which must fit the 48-bit entry (`E_ORDER(last, entry)` otherwise).
    function _append(bytes32 key, uint64 tagged, uint16 flagsOr) private returns (uint64) {
        PostingStorage storage $ = _posting();
        PostingHead storage h = $.heads[key];
        uint48 c = h.count;
        uint64 ordinal = tagged & ~UNCOUNTED;
        if (ordinal > MASK48 || (c != 0 && ordinal <= h.last)) revert E_ORDER(h.last, ordinal);
        if (c == 1) {
            // the second append materializes word 0 with the inline first entry and this one
            $.words[key][0] = uint256(h.last) | (uint256(ordinal) << 48);
        } else if (c > 1) {
            uint256 w = c / 5;
            uint256 shift = (c % 5) * 48;
            $.words[key][w] |= uint256(ordinal) << shift;
        }
        h.count = c + 1;
        if (tagged & UNCOUNTED == 0) h.live += 1;
        h.last = uint48(ordinal);
        if (flagsOr != 0) h.flags |= flagsOr;
        return c + 1;
    }

    // ---- reads (raw storage getters for the oracle; the generation derives keys) --------------------------

    /// @inheritdoc IPostingStore
    function postingHead(PostingKey key)
        external
        view
        returns (uint64 count, uint64 live, uint64 last, uint16 flags)
    {
        PostingHead storage h = _posting().heads[PostingKey.unwrap(key)];
        return (h.count, h.live, h.last, h.flags);
    }

    /// @inheritdoc IPostingStore
    function postingAt(PostingKey key, uint64 i) public view returns (uint64) {
        PostingStorage storage $ = _posting();
        bytes32 k = PostingKey.unwrap(key);
        PostingHead storage h = $.heads[k];
        if (i >= h.count) revert E_ORDER(h.count, i);
        if (h.count == 1) return h.last;
        return uint64(($.words[k][i / 5] >> ((i % 5) * 48)) & MASK48);
    }

    /// @inheritdoc IPostingStore
    function postingSlice(PostingKey key, uint64 from, uint16 n)
        external
        view
        returns (uint64[] memory out)
    {
        uint64 count = _posting().heads[PostingKey.unwrap(key)].count;
        uint64 end = from + n > count ? count : from + n;
        out = new uint64[](end > from ? end - from : 0);
        for (uint64 i = from; i < end; ++i) {
            out[i - from] = postingAt(key, i);
        }
    }

    /// @inheritdoc IPostingStore
    function postingWords(PostingKey key, uint64 fromWord, uint16 n)
        external
        view
        returns (uint256[] memory out)
    {
        PostingStorage storage $ = _posting();
        bytes32 k = PostingKey.unwrap(key);
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = $.words[k][fromWord + i];
        }
    }

    // ---- common getters ---------------------------------------------------------------------------------

    function writers()
        external
        view
        returns (address[] memory generations, uint64[] memory from, uint64[] memory to)
    {
        return _writersView();
    }

    function familyIds() external view returns (bytes32[] memory) {
        return _familyIds();
    }

    function initialWriter() external view returns (address) {
        return INITIAL_WRITER;
    }

    function attached() external view returns (bool) {
        return _attached();
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function storeAbiId() external pure returns (bytes32) {
        return STORE_ABI_ID;
    }
}
