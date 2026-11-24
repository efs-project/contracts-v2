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
///         singleton list costs one slot. Writes come only through the authorization of `StoreBase`.
contract PostingStore is IPostingStore, PostingStoreStorage, StoreBase {
    bytes32 public constant STORE_ABI_ID = keccak256("efs2/posting-store/1");

    uint256 private constant MASK48 = (1 << 48) - 1;

    constructor(address ledger_, address initialWriter_, bytes32[] memory families)
        StoreBase(ledger_, initialWriter_)
    {
        PostingStorage storage $ = _posting();
        for (uint256 i; i < families.length; ++i) {
            $.familyIds.push(families[i]);
        }
    }

    // ---- StoreBase hooks ---------------------------------------------------------------------------------

    function _familyIds() internal view override returns (bytes32[] storage) {
        return _posting().familyIds;
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
    function appendBatch(
        FamilyId[] calldata families,
        PostingKey[] calldata keys,
        uint64[] calldata ordinals
    ) external {
        for (uint256 i; i < keys.length; ++i) {
            (uint8 mode,) = _authorize(FamilyId.unwrap(families[i]));
            if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
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

    function _append(bytes32 key, uint64 ordinal, uint16 flagsOr) private returns (uint64) {
        PostingStorage storage $ = _posting();
        PostingHead storage h = $.heads[key];
        uint48 c = h.count;
        if (c != 0 && ordinal <= h.last) revert E_ORDER(h.last, ordinal);
        if (c == 1) {
            // the second append materializes word 0 with the inline first entry and this one
            $.words[key][0] = uint256(h.last) | (uint256(ordinal) << 48);
        } else if (c > 1) {
            uint256 w = c / 5;
            uint256 shift = (c % 5) * 48;
            $.words[key][w] |= uint256(ordinal) << shift;
        }
        h.count = c + 1;
        h.live += 1;
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
