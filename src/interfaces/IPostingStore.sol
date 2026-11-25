// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, PostingKey} from "./Actions.sol";

/// @title IPostingStore — the per-Realm APPEND_ORDERED family store (design §5.11, §4.6)
/// @notice STORE_ABI_ID = the ABI id of this interface under "efs/posting-store/2" (design §5.3's rule): a constant
///         exposed by storeAbiId(), snapshot-tested like ILedgerHot; stores outlive generations, so this ABI is
///         Etched. Writes are authorized per §4.6 (E_WRITER / E_FAMILY / E_ORDER). The reads are raw storage
///         getters for the oracle, not family reads; the index derives keys. A list's head holds `count` (entries
///         ever appended) and `live`, a counter the writer keeps with `0 ≤ live ≤ count` (checked on every write):
///         an append raises it unless the ordinal is tagged UNCOUNTED, `release` lowers it and `retain` raises it
///         without an entry. Version 2 (step 3b) added `retain` and the UNCOUNTED tag.
interface IPostingStore {
    /// Strictly increasing per key; the first append of a key writes only the head. The entry is the low 63 bits of
    /// `ordinal` and must fit 48 bits; bit 63 set (UNCOUNTED, `1 << 63`) appends it without raising `live`, so a
    /// writer can keep `live` as a count of something other than the entries (the same tag in `appendBatch`).
    function append(FamilyId family, PostingKey key, uint64 ordinal, uint16 flagsOr)
        external
        returns (uint64 count);

    /// live −= n, checked (`E_ORDER(live, n)` when n > live).
    function release(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live);

    /// live += n without appending, checked (`E_ORDER(count, live + n)` when that exceeds count); the same writer
    /// and family rules as `release`.
    function retain(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live);

    /// One CALL per publication if C1 decides to batch; each ordinal may carry the UNCOUNTED tag.
    function appendBatch(
        FamilyId[] calldata families,
        PostingKey[] calldata keys,
        uint64[] calldata ordinals
    ) external;

    function postingHead(PostingKey key)
        external
        view
        returns (uint64 count, uint64 live, uint64 last, uint16 flags);

    function postingAt(PostingKey key, uint64 i) external view returns (uint64);

    function postingSlice(PostingKey key, uint64 from, uint16 n)
        external
        view
        returns (uint64[] memory);

    function postingWords(PostingKey key, uint64 fromWord, uint16 n)
        external
        view
        returns (uint256[] memory);

    function writers()
        external
        view
        returns (address[] memory generations, uint64[] memory from, uint64[] memory to);

    function familyIds() external view returns (bytes32[] memory);

    function initialWriter() external view returns (address);

    function attached() external view returns (bool);

    function storeAbiId() external view returns (bytes32);

    function ledger() external view returns (address);
}
