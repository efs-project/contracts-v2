// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Limits} from "./Limits.sol";
import {BasisCommit, Retention} from "./Results.sol";
import {ComponentSet} from "./ILedgerControl.sol";

// Views — the structs the ledger facets return (design §5.7), shared by `ILedgerReads`, `ILedgerViews` and the
// readers. Statuses travel beside these structs, never zero sentinels inside them. `Coordinate` (also listed in
// §5.7) is declared once in `Actions.sol`.

/// Everything `describe()` reads: the realm namespace (limits included), the current revision row, the ERC-1967
/// implementation slot and the counters. `thisFacet`/`thisFacetCodehash` describe the facet being called; the
/// SDK trusts nothing it says about code until it compares the proxy's implementation slot and code hash with
/// `release.json`.
struct Description {
    bytes32 realmId;
    bytes32 realmOrigin;
    bytes32 realmSalt;
    uint64 genesisChainId;
    uint64 acceptedChainId;
    bytes8 chainNamespace;
    bytes32 chainReference;
    bytes32 executionSet;
    uint32 revision;
    uint64 revisionBlock;
    uint64 revisionAdmissionHigh;
    bytes32 layoutId;
    bytes32 hotAbiId;
    uint16 executionProfileId;
    uint16 capabilities;
    address ledgerImpl;
    bytes32 ledgerImplCodehash;
    address ingress;
    bytes32 ingressCodehash;
    address applyDelegate;
    bytes32 applyCodehash;
    address registry;
    address registryImpl;
    bytes32 registryImplCodehash;
    uint64 registryMutations;
    uint64 catalogCount;
    address index;
    bytes32 indexCodehash;
    uint32 indexGeneration;
    bytes32 indexManifestHash;
    bytes32 indexObligations;
    address controller;
    bytes32 controllerCodehash;
    address controllerOwner;
    address steward;
    bool frozen;
    uint8 phase;
    address readerDirectory;
    address thisFacet;
    bytes32 thisFacetCodehash;
    uint16 facetVersion;
    uint64 admissions;
    uint64 records;
    uint64 bindings;
    uint64 publications;
    bytes32 domainSeparator;
    bytes32 limitsProfileId;
    bytes32 statusVocabularyId;
    bytes32 verifierProfilesRoot;
    bytes32 dependencyRoot;
    Limits limits;
    bytes32 noticePrincipal;
}

/// One retained revision row (`revisionAt(n)`).
struct Revision {
    uint32 ordinal;
    uint64 activationBlock;
    uint64 admissionHigh;
    uint64 publicationHigh;
    uint64 activationTimestamp;
    uint16 flags;
    bytes32 executionSet;
    ComponentSet components;
    bytes32 layoutId;
    uint16 executionProfileId;
    uint16 capabilities;
    uint64 acceptedChainId;
    uint32 indexGeneration;
    bytes32 migrationHash;
    bytes32 dependencyRoot;
    bytes32 limitsProfileId;
    Limits limits;
    bytes32 noticePrincipal;
}

/// A record's header row plus its first body word.
struct RecordHeader {
    bytes32 typeId;
    uint64 firstAdmission;
    uint32 length;
    uint64 occurrences;
    uint8 carrierKind;
    bytes32 word0;
}

/// A binding head. `target` is canonical: 0 unless BOUND.
struct Head {
    uint8 state;
    uint64 revision;
    uint64 admission;
    uint8 targetKind;
    uint64 prevAdmission;
    uint64 bindingOrdinal;
    uint40 notAfter;
    bytes32 target;
}

/// One admission row.
struct AdmissionRow {
    uint8 kind;
    uint8 leaf;
    uint64 publication;
    uint64 bindingOrdinal;
    uint64 expectedRevision;
    uint64 prevAdmission;
    bool withdrawn;
    uint16 policyRow;
    uint16 roleRow;
    uint8 targetKind;
    bytes32 a;
}

/// One publication's evidence row. `retention` is LOG_ONLY for rows whose read-set preimage or ERC-1271
/// witness lives only in logs; readers grade their portability UNKNOWN (design §7.4). `publicationId` is
/// recomputed for the caller.
struct Evidence {
    bytes32 principalId;
    address author;
    address submitter;
    uint8 proofKind;
    uint8 principalKind;
    uint16 verifierProfile;
    uint8 leafCount;
    uint64 firstAdmission;
    uint64 nonce;
    uint64 deadline;
    uint64 basisBlock;
    uint32 revision;
    bytes32 executionSet;
    bytes32 intentDigest;
    bytes32 actionsHash;
    bytes32 acceptanceProfile;
    bytes32 indexObligations;
    bytes32 readSetHash;
    bytes32 witness0;
    bytes32 witness1;
    uint8 v;
    bool imported;
    bool guarded;
    bool executionBound;
    bool acceptanceBound;
    Retention retention;
    bytes32 publicationId;
}

/// A publication composite; `effectsHash` is recomputed from state so a receipt matches a plan.
struct PublicationView {
    uint64 ordinal;
    Evidence evidence;
    AdmissionRow[] admissions;
    bytes32 effectsHash;
    uint64 admissionBlock;
    BasisCommit observed;
}

/// The acceptance basis an admission was validated under.
struct AcceptanceBasis {
    bytes32 typeId;
    uint16 policyRow;
    address mandatory;
    bytes32 ruleId;
    address policy;
    bytes32 policyCodehash;
    uint64 activatedAt;
    uint16 roleRow;
    uint32 revision;
    uint32 validationGas;
}
