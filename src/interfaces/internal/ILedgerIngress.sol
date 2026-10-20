// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15): outside the consumer closure; declared so the ABI union is complete.
// Calling convention: the kernel forwards its own lane calldata to `prepareNative`/`prepareSigned` (same
// parameter layout as `ILedger.execute`/`executeSigned`, only the selector differs), so no lane argument is
// re-encoded; per-leaf calls carry scalars and the one body; the index callbacks receive the apply delegate's
// opaque 33-word leaf blob (24 Effect/3 words, the ref count, up to eight refs) and never an ABI struct.
import {Action, Intent, Native} from "../Actions.sol";

/// The fixed-size preparation output both lanes produce: 21 words, 672 B (design §6.2).
struct Prepared {
    bytes32 principalId;
    uint8 principalKind;
    uint8 proofKind;
    uint16 verifierProfile;
    uint8 v;
    address author;
    bytes32 witness0;
    bytes32 witness1;
    uint64 nonce;
    uint64 deadline;
    bytes32 actionsHash;
    bytes32 acceptanceProfile;
    bytes32 indexObligations;
    bytes32 readSetHash;
    bytes32 intentDigest;
    uint32 prefixFloor;
    uint32 finalReserve;
    uint32 freshSlots;
    uint32 rewrites;
    uint8 leafCount;
    uint8 flags;
}

/// What the ingress tells the kernel about one leaf after the shape law, the registry reads and the
/// acceptors: the kernel passes these scalars to the apply delegate and never decodes a TypeInfo.
struct LeafVerdict {
    uint8 refCount;
    uint16 policyRow;
    uint16 roleRow;
}

/// @title ILedgerIngress — the preparation, validation and dispatch delegate (design §5.15, §6.2–§6.5)
/// @notice Every selector reverts E_DELEGATE_ONLY unless running by DELEGATECALL in the ledger's context.
interface ILedgerIngress {
    /// Same layout as ILedger.execute; the kernel forwards msg.data[4:] under this selector.
    function prepareNative(
        Action[] calldata actions,
        bytes[] calldata bodies,
        Native calldata ctx,
        bytes calldata guard
    ) external returns (Prepared memory);
    /// Same layout as ILedger.executeSigned.
    function prepareSigned(
        Intent calldata intent,
        Action[] calldata actions,
        bytes[] calldata bodies,
        bytes calldata guard,
        bytes calldata witness
    ) external returns (Prepared memory);
    /// Every kind: the shape law, then for PUBLISH/REUSE the registry row, the body law, the references
    /// and the acceptors; for BIND the role expectation and the target's Type.
    function validateLeaf(
        uint8 leaf,
        Action calldata action,
        bytes calldata body,
        uint64 admission,
        bytes32 principalId
    ) external view returns (LeafVerdict memory);
    /// The prefix callback for one leaf under the availability floor; `leafBlob` is the apply delegate's
    /// 33-word return (Effect/3 words 0..23, refCount at 24, refs at 25..32).
    function dispatchIndex(uint64 publication, bytes calldata leafBlob, uint32 remainingPrefixFloor)
        external
        returns (uint32 spent);
    /// The final STATICCALL with the exact-acknowledgement law; `effects` is the concatenation of every
    /// leaf's 24 Effect words, `refs` every leaf's refs in order.
    function dispatchFinal(uint64 publication, bytes calldata effects, bytes32[] calldata refs)
        external
        view;
    /// The SIGNATURE_STORE immutable; 0 until the S2b build.
    function signatureStore() external view returns (address);
}
