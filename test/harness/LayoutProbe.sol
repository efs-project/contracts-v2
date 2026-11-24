// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LedgerStorage} from "../../src/core/storage/LedgerStorage.sol";
import {RegistryStorage} from "../../src/types/storage/RegistryStorage.sol";
import {PostingStoreStorage, BitmapStoreStorage} from "../../src/index/storage/StoreStorage.sol";
import {GenerationStorage} from "../../src/index/storage/GenerationStorage.sol";

/// @notice Test-only probes: each declares its implementation's namespaced structs as plain state
///         variables so `forge inspect <Probe> storageLayout` emits every struct's member offsets;
///         tools/layout.mjs combines them with the ERC-7201 roots to generate `Layout`. Never deployed.
///         One probe per implementation, mirroring which contract carries which namespaces.
contract LedgerLayoutProbe is LedgerStorage {
    RealmStorage internal probe_realm;
    CountersStorage internal probe_counters;
    RecordsStorage internal probe_records;
    SubjectsStorage internal probe_subjects;
    AdmissionsStorage internal probe_admissions;
    PublicationsStorage internal probe_publications;
    BindingsStorage internal probe_bindings;
    PrincipalsStorage internal probe_principals;
    RevisionsStorage internal probe_revisions;
}

contract RegistryLayoutProbe is RegistryStorage {
    TypesStorage internal probe_types;
    DeclarationsStorage internal probe_declarations;
    PolicyStorage internal probe_policy;
    RolesStorage internal probe_roles;
    BindingsStorage internal probe_bindings;
    WrappersStorage internal probe_wrappers;
    CatalogStorage internal probe_catalog;
    ControlStorage internal probe_control;
}

contract PostingStoreLayoutProbe is PostingStoreStorage {
    PostingStorage internal probe_posting;
}

contract BitmapStoreLayoutProbe is BitmapStoreStorage {
    BitmapStorage internal probe_bitmap;
}

contract GenerationLayoutProbe is GenerationStorage {
    GenStorage internal probe_gen;
}
