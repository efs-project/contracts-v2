// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, PostingKey} from "./Actions.sol";

/// @title IPostingStore — the per-Realm APPEND_ORDERED family store (design §5.11, §4.6)
/// @notice STORE_ABI_ID = keccak("efs2/posting-store/1" ‖ sorted selectors ‖ return layouts): an immutable
///         exposed by storeAbiId(), snapshot-tested like ILedgerHot; stores outlive generations, so this ABI is
///         Etched. Writes are authorized per §4.6 (E_WRITER / E_FAMILY / E_ORDER). The reads are raw storage
///         getters for the oracle, not family reads; the index derives keys.
interface IPostingStore {
    /// Strictly increasing per key; the first append of a key writes only the head.
    function append(FamilyId family, PostingKey key, uint64 ordinal, uint16 flagsOr)
        external
        returns (uint64 count);

    /// live −= n, checked.
    function release(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live);

    /// One CALL per publication if C1 decides to batch.
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
