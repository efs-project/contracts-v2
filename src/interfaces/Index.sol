// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Index — the structs of the required-index ABI (design §5.11, §10), shared by `IRealmIndex`, `IIndexHook`,
// `IIndexReads` and the kernel-internal delegates.

/// Effect/3: 24 static words (768 B); callbackProfile =
/// keccak("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs").
/// transitionKind: 0 none (publish/reuse/create/withdraw) 1 FIRST_BIND 2 REBIND 3 MASK 4 RELEASE 5 RESTORE (BIND
/// from MASKED/RELEASED). freshRecord: first admission of recordId. refCount: how many entries of `refs` belong
/// to this effect, in order. WITHDRAW: recordId/typeId of the withdrawn record, withdrawnAdmission = target
/// admission, withdrawnPrincipal = its retained principal.
struct Effect {
    uint8 kind;
    uint8 leaf;
    uint64 admission;
    uint64 publication;
    bytes32 principalId;
    bytes32 typeId;
    bytes32 recordId;
    bytes32 subjectId;
    uint64 bindingOrdinal;
    bytes32 position;
    bytes32 purpose;
    bytes32 subject;
    bytes32 role;
    uint64 revision;
    uint64 prevAdmission;
    uint8 transitionKind;
    uint8 targetKind;
    uint8 oldTargetKind;
    uint8 refCount;
    bool freshRecord;
    bytes32 target;
    bytes32 oldTarget;
    uint64 withdrawnAdmission;
    bytes32 withdrawnPrincipal;
}

/// Slot counts and compute; converted with limits.floor* at quote time.
struct WorkModel {
    uint8 formulaVersion;
    uint16 freshPerPublication;
    uint16 rwPerPublication;
    uint16 freshPerPublishFresh;
    uint16 rwPerPublish;
    uint16 freshPerBindFresh;
    uint16 rwPerBind;
    uint16 freshPerRef;
    uint16 freshPerDigestSpec;
    uint32 computeBase;
    uint32 computePerAction;
    uint32 computePerHookEffect;
    uint32 finalComputeBase;
    uint32 finalComputePerBind;
}

/// Constructor-fixed; the core folds family 15 from body word `wordIndex` (one cold SLOAD, priced).
struct DigestSpec {
    bytes32 typeId;
    uint8 wordIndex;
    uint8 algorithm;
}

/// One pinned index unit: its fold and final hooks with codehashes, its families, and the
/// hot-ABI id it was built against.
struct Unit {
    address foldHook;
    bytes32 foldCodehash;
    address finalHook;
    bytes32 finalCodehash;
    bytes32[] familyIds;
    bytes32 purposeFilter;
    bytes32 hotAbiId;
    bytes32 identity;
}

/// One index family. kind: the §10.2 kind number (0 reserved); universe: 1 TYPE 2 PRINCIPAL 3 SCOPE 4 TARGET
/// 5 GLOBAL; shape: 1 APPEND_ORDERED 2 BITMAP. liveSemantics, read by shape — APPEND: 1 RETAINED 2 OCCURRENCE
/// 3 HEADS; BITMAP: 1 MONOTONE 2 CURRENT_STATE; 0 reserved. fromAdmission NOT_MAINTAINED = 2^64-1.
struct FamilyEntry {
    bytes32 familyId;
    uint8 kind;
    uint8 universe;
    uint8 shape;
    bool mandatory;
    uint8 liveSemantics;
    bytes32 recipe;
    uint64 fromAdmission;
    address store;
    bytes32 storeCodehash;
}

/// A generation's readiness tuple. phase echoes ILedgerHot(ledger).phase(); ready is the §10.5 predicate, which
/// checkActivation re-derives from the tuple and the stores and never trusts.
struct Readiness {
    uint8 version;
    address ledger;
    bytes32 layoutId;
    bytes32 hotAbiId;
    bytes32 physicalProfile;
    bytes32 callbackProfile;
    bytes32 manifestHash;
    uint64 provenFrom;
    uint64 completedAdmission;
    uint64 completedPublication;
    uint8 phase;
    bool ready;
    Unit[] units;
    FamilyEntry[] families;
    address build;
    bytes32 buildCodehash;
}
