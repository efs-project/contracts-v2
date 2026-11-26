// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Index — the structs of the required-index ABI (design §5.11, §10), shared by `IRealmIndex`, `IIndexHook`,
// `IIndexReads` and the kernel-internal delegates.

/// Effect/3: 24 static words (768 B); callbackProfile =
/// keccak("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs") (callback 4 is the Effect/3 shape with
/// transition kind 6 and target kind 3 added). transitionKind: 0 none (publish/reuse/create/withdraw) 1 FIRST_BIND
/// 2 REBIND 3 MASK (UNBIND from BOUND, MASKED or RELEASED) 4 RELEASE 5 RESTORE (BIND from MASKED/RELEASED)
/// 6 FIRST_MASK (UNBIND from UNSET: the binding is allocated with no target). targetKind/oldTargetKind: 0 none
/// 1 RECORD 2 SUBJECT 3 ADDRESS. freshRecord: first admission of recordId. refCount: how many entries of `refs` belong
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

/// Slot counts (×10) and compute; converted with limits.floor* at quote time (design §10.4). Formula 3
/// (docs/WORK-MODEL-V3.md), over a publication of n actions, `binds` of them BIND/UNBIND/RELEASE and `publishes`
/// PUBLISH/REUSE:
///   fresh10 = freshPerPublication + Σ_publishes (freshPerRef·refs + (new record ? freshPerPublishFresh +
///             freshPerDigestSpec·specs : freshPerPublishExisting)) + Σ_rows fresh
///   rw10    = rwPerPublication + publishes·rwPerPublish + Σ_rows rw
///   prefixFloor  = computeBase + n·computePerAction + Σ_rows compute + ceil(fresh10/10)·floorFreshGas
///                  + ceil(rw10/10)·floorRewriteGas
///   finalReserve = finalComputeBase + binds·finalComputePerBind + publishes·finalComputePerPublish
/// Each bind-kind action adds one row (fresh, rw, compute) by its class: a first statement (a BIND or UNBIND on the
/// author's UNSET head: words 13-15), a re-bind (a BIND on a BOUND head, transition REBIND: words 16-18) or another
/// later statement (a mask, a release, a restore: words 19-21); and, when its purpose word equals `surchargePurpose`,
/// the surcharge's row of the same class (words 23-25, 26-28, 29-31). Every WITHDRAW after the first of a publication
/// adds the later-statement row. With no principal (`ILedgerCommitments.indexFloor`) every bind takes the largest of
/// the three rows in each field, surcharge included. A record is new when no earlier admission wrote its header (a
/// REUSE always names an existing one). Slot counts are true counts: each is the largest number of index slots a
/// statement of its class writes, measured per statement on both schedules (`test/integration/FloorSplit.t.sol`); the
/// later row's three fresh slots are a yes after a lone no's (the binding's second statement), its five rewrites a
/// restore's at a place of its own. Compute carries no slot. The ingress reads the ABI reply of `IIndexReads.workModel()` as raw words in this order, so the
/// field order is part of the formula.
struct WorkModel {
    uint8 formulaVersion;
    uint16 freshPerPublication;
    uint16 rwPerPublication;
    uint16 freshPerPublishFresh;
    /// Charged instead of `freshPerPublishFresh` for a PUBLISH of an existing record or a REUSE: filing a record
    /// again writes more fresh index slots than its first admission (measured ≈ 2.4 per action against 0.6).
    uint16 freshPerPublishExisting;
    uint16 rwPerPublish;
    uint16 freshPerRef;
    uint16 freshPerDigestSpec;
    uint32 computeBase;
    uint32 computePerAction;
    uint32 finalComputeBase;
    uint32 finalComputePerBind;
    /// The final phase's compute per PUBLISH or REUSE: the final units see every effect, not only the bind-kind ones.
    uint32 finalComputePerPublish;
    /// The first-statement row (words 13-15).
    uint16 freshPerBindFirst;
    uint16 rwPerBindFirst;
    uint32 computePerBindFirst;
    /// The re-bind row (words 16-18): a BIND on a BOUND head (a new target, or the same target with a new number). It
    /// never searches the author's scope list and moves no live bit, so it does not grow with the list.
    uint16 freshPerRebind;
    uint16 rwPerRebind;
    uint32 computePerRebind;
    /// The row of every other later statement (words 19-21): a mask, a release or a restore, and every WITHDRAW after a
    /// publication's first. Its compute is fitted to the list length the floor claims (docs/WORK-MODEL-V3.md §3.5), at
    /// which a yes after a lone no and a restore across places are the dearest it covers.
    uint16 freshPerBindLater;
    uint16 rwPerBindLater;
    uint32 computePerBindLater;
    /// One purpose surcharge (word 22; 0 = none): a generation that keeps a list for one purpose reserves for it here,
    /// so statements of every other purpose pay nothing for it. Its rows, by the same classes: words 23-25, 26-28,
    /// 29-31.
    bytes32 surchargePurpose;
    uint16 surchargeFreshFirst;
    uint16 surchargeRwFirst;
    uint32 surchargeComputeFirst;
    uint16 surchargeFreshRebind;
    uint16 surchargeRwRebind;
    uint32 surchargeComputeRebind;
    uint16 surchargeFreshLater;
    uint16 surchargeRwLater;
    uint32 surchargeComputeLater;
}

// `WorkModel`'s ABI size in words: a static struct, one word per field, returned inline by `IIndexReads.manifest()`
// between the three array offsets and the two profiles, so a reader that checks the profiles from the raw reply finds
// them at words 4 + WORK_MODEL_WORDS and 5 + WORK_MODEL_WORDS. It must change with the struct;
// `test/index/IndexReadsSplit.t.sol` fails when the two drift.
uint256 constant WORK_MODEL_WORDS = 32;

// The work-model formula this build implements (word 0 of `WorkModel`). The ingress refuses a work model of any other
// version (`E_WORK_MODEL` 3) and activation refuses an index whose work model it is not (`E_INDEX_NOT_READY` 15).
uint8 constant FORMULA_VERSION = 3;

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
/// 5 GLOBAL; shape: 1 APPEND_ORDERED 2 BITMAP. liveSemantics, read by shape — APPEND: 1 RETAINED (never releases;
/// `live` = `count`) 2 OCCURRENCE (releases on WITHDRAW) 3 HEADS (tracks the entries' current heads) 4 DISTINCT
/// (`live` is raised only by a counted append and never lowered; `count` is every entry, so `live` ≤ `count`);
/// BITMAP: 1 MONOTONE 2 CURRENT_STATE; 0 reserved. fromAdmission NOT_MAINTAINED = 2^64-1.
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
