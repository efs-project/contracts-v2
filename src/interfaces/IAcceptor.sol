// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// IAcceptor/2 — the acceptance-rule ABI (design §5.10). Frozen before the first Files Type is registered; it is
// inside every native-grade `ruleId`. Success is exactly 32 bytes of returndata equal to
// `bytes32(IAcceptor.accept.selector)` (left-aligned); `EXHAUSTED` is the one reserved reply that is neither
// success nor refusal; any other 32-byte word is a refusal.

/// The header words the kernel already loaded for one checked reference. word1/word2 are loaded only up to the
/// Type's declared refHeaderWords (1..3); undeclared words are zero.
struct RefHeader {
    bytes32 typeId;
    uint64 firstAdmission;
    uint32 length;
    bytes32 word0;
    bytes32 word1;
    bytes32 word2;
}

/// The context of one `accept` call. Every acceptor must require `ctx.ledger == msg.sender`.
struct AcceptContext {
    bytes32 typeId;
    bytes32 realmId;
    bytes32 principalId;
    uint64 admission;
    uint32 revision;
    uint8 grade;
    uint8 leaf;
    address ledger;
    address index;
    address registry;
    address descriptorBlob;
    address customPredicate;
    bytes32 bindingId;
}

/// @title IAcceptor — IAcceptor/2 (design §5.10)
/// @notice The caller is the ledger proxy (the ingress in ledger context) and `ctx.ledger == address(this)`;
///         refs are pre-verified to exist with the declared Types; `refHeaders[i]` carries the words the kernel
///         already loaded so rules are pure over calldata.
interface IAcceptor {
    /// Returns `IAcceptor.accept.selector` on success, `EXHAUSTED` on nested exhaustion, anything else refuses.
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4);
}

// The one reserved 32-byte reply that is neither success nor refusal: nested exhaustion (mapped to E_ACCEPTOR_GAS).
bytes32 constant EXHAUSTED = keccak256("efs2/acceptor/2/exhausted");
