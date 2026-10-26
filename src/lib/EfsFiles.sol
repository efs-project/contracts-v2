// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, ActionKind, Purpose} from "../interfaces/Actions.sol";

/// @title EfsFiles — the Files recipes of design §12.2 as `Action[]`/`bytes[]` builders (design §5.14)
/// @notice Pure builders for the measured recipes — root seed, create folder, create file, edit, rename/move,
///         remove, restore, release — plus the body encoders of the nine Files Types of §12.1 and the ids a client
///         needs (subject, record, name record, position, FOLDER scope). Every builder returns the `actions` and the
///         aligned `bodies` the ledger's `execute` takes; hand them to `EfsNative.batch` (or `ILedger.execute`).
///         Type ids are the caller's (`Types`): `profiles/FilesTypes.sol` derives them from the release's
///         descriptors, and they are identical on every Realm for one declaration key.
///
///         Recipe shapes (design §12.2): a FOLDER bind is `BIND(FOLDER, parentDirectoryRecord, keccak(name) →
///         target)` — the subject is the parent's `files-directory/1` record id, the role the name's body hash, the
///         target a file subject or a directory record; a HEAD bind is `BIND(HEAD, fileSubject, 0 → record)`.
///         `FilesFinalValidator` requires a `files-name/2` record for the role at or before the publication's
///         terminal admission, so the `withName` flags publish it in the same publication; pass false when the name
///         record already exists (a second PUBLISH of an existing record is a new occurrence, which costs gas but
///         is not refused). CAS values are the caller's: `expected` is the head's current revision (0 for a first
///         bind).
/// @dev Consumer closure: internal functions only, no storage, imports only `src/interfaces/`. The id derivations
///      repeat `Keys` (record, subject, position, scope) with the same domain tags and argument order — they are
///      one-way doors, and `test/readers/FilesPageReader.t.sol` checks each against `Keys`.
library EfsFiles {
    /// The Files Type ids a recipe needs (`FilesTypes.typeIdOf` of the release descriptors).
    struct Types {
        bytes32 root;
        bytes32 child;
        bytes32 directory;
        bytes32 name;
        bytes32 bytes_;
        bytes32 content;
        bytes32 external_;
        bytes32 alias_;
        bytes32 notice;
    }

    /// The 11-word (352-byte) `files-content/1` body (design §12.1; `media` is the one media-domain word, ≤ 2).
    struct Content {
        bytes32 bytesRef;
        uint256 version;
        uint256 carrier;
        uint256 hashAlg;
        uint256 length;
        bytes32 sha256Digest;
        uint256 media;
        uint256 cipher;
        bytes32 nonce12;
        uint256 plaintextLength;
        bytes32 plaintextSha256OrZero;
    }

    bytes32 internal constant DOM_RECORD = keccak256("efs2/record/1");
    bytes32 internal constant DOM_SUBJECT = keccak256("efs2/subject/1");
    bytes32 internal constant DOM_POSITION = keccak256("efs2/position/1");
    bytes32 internal constant DOM_SCOPE = keccak256("efs2/vk/binding-scope/1");
    /// `directory-alias/1` kinds and `files-external/1` carriers (design §12.1).
    uint256 internal constant ALIAS_DIRECTORY = 1;
    uint256 internal constant ALIAS_FILE = 2;
    uint256 internal constant CARRIER_AR = 2;
    uint256 internal constant CARRIER_IPFS = 3;
    uint256 internal constant HASH_SHA256 = 1;

    // =============================================================================================
    // Ids
    // =============================================================================================

    /// `Keys.record`: the record id of `body` under `typeId`.
    function recordId(bytes32 typeId, bytes memory body) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, typeId, keccak256(body)));
    }

    /// `Keys.subject`: the subject a CREATE(salt) by `principal` mints.
    function subjectId(bytes32 principal, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_SUBJECT, principal, salt));
    }

    /// The FOLDER role of a name: its body hash.
    function role(bytes memory name) internal pure returns (bytes32) {
        return keccak256(name);
    }

    /// The `files-name/2` record id whose body hash is `role_` (`Keys.recordFromHash(nameType, role)`).
    function nameRecord(bytes32 nameType, bytes32 role_) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, nameType, role_));
    }

    /// The `files-directory/1` record of a directory seeded by `seedSubject`.
    function directoryRecord(bytes32 directoryType, bytes32 seedSubject)
        internal
        pure
        returns (bytes32)
    {
        return recordId(directoryType, directoryBody(seedSubject));
    }

    /// `Keys.position`.
    function position(bytes32 purpose, bytes32 subject, bytes32 role_)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOM_POSITION, purpose, subject, role_));
    }

    /// The FOLDER position of `name` in the directory record `folder`.
    function folderPosition(bytes32 folder, bytes memory name) internal pure returns (bytes32) {
        return position(Purpose.FOLDER, folder, keccak256(name));
    }

    /// The HEAD position of a file subject.
    function headPosition(bytes32 file) internal pure returns (bytes32) {
        return position(Purpose.HEAD, file, 0);
    }

    /// `Keys.scope(principal, FOLDER, folder)`: the scope list `FilesPageReader` walks for that principal.
    function folderScope(bytes32 principal, bytes32 folder) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_SCOPE, principal, Purpose.FOLDER, folder));
    }

    // =============================================================================================
    // Body encoders (design §12.1)
    // =============================================================================================

    /// `files-root/1`: `abi.encode(fileSubject) ‖ document`.
    function rootBody(bytes32 file, bytes memory document) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(file), document);
    }

    /// `files-child/1`: `abi.encode(parentRecord, fileSubject) ‖ document`.
    function childBody(bytes32 parent, bytes32 file, bytes memory document)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(abi.encode(parent, file), document);
    }

    /// `files-directory/1`: `abi.encode(seedSubject)`.
    function directoryBody(bytes32 seedSubject) internal pure returns (bytes memory) {
        return abi.encode(seedSubject);
    }

    /// `files-name/2`: the raw UTF-8 name (its rule judges well-formedness; this encoder is the identity).
    function nameBody(bytes memory name) internal pure returns (bytes memory) {
        return name;
    }

    /// `files-bytes/1`: `sha256(payload) ‖ payload`.
    function bytesBody(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(sha256(payload), payload);
    }

    /// `files-content/1`: the 11 words in order.
    function contentBody(Content memory c) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(c.bytesRef, c.version, c.carrier, c.hashAlg, c.length, c.sha256Digest),
            abi.encode(c.media, c.cipher, c.nonce12, c.plaintextLength, c.plaintextSha256OrZero)
        );
    }

    /// `files-external/1`: `[bytesRef, 2, carrier, 1, length, sha256, locatorLength] ‖ locator`.
    function externalBody(
        bytes32 emptyBytesRef,
        uint256 carrier,
        uint256 length,
        bytes32 sha256Digest,
        bytes memory locator
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(
                emptyBytesRef,
                uint256(2),
                carrier,
                HASH_SHA256,
                length,
                sha256Digest,
                locator.length
            ),
            locator
        );
    }

    /// `directory-alias/1`: `abi.encode(targetObjectId, kind)`.
    function aliasBody(bytes32 target, uint256 kind) internal pure returns (bytes memory) {
        return abi.encode(target, kind);
    }

    /// `realm-notice/1`: `abi.encode(kind, revision, note)`.
    function noticeBody(bytes32 kind, uint256 revision, bytes memory note)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(kind, revision, note);
    }

    // =============================================================================================
    // Action builders
    // =============================================================================================

    function create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function publish(bytes32 typeId, bytes memory body) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function bind(bytes32 purpose, bytes32 subject, bytes32 role_, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory a)
    {
        a = _coordinate(ActionKind.BIND, purpose, subject, role_, expected);
        a.target = target;
    }

    function unbind(bytes32 purpose, bytes32 subject, bytes32 role_, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _coordinate(ActionKind.UNBIND, purpose, subject, role_, expected);
    }

    function release(bytes32 purpose, bytes32 subject, bytes32 role_, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _coordinate(ActionKind.RELEASE, purpose, subject, role_, expected);
    }

    function _coordinate(
        uint8 kind,
        bytes32 purpose,
        bytes32 subject,
        bytes32 role_,
        uint64 expected
    ) private pure returns (Action memory a) {
        a.kind = kind;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role_;
        a.expectedRevision = expected;
    }

    // =============================================================================================
    // Recipes (design §12.2)
    // =============================================================================================

    /// Root (the seed, once per Realm): `CREATE(rootSalt)`, `PUBLISH(files-directory/1, rootSubject)`; no FOLDER
    /// bind. Returns the root directory record id.
    function rootSeed(Types memory t, bytes32 principal, bytes32 rootSalt)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 rootDirectory)
    {
        (a, b) = _alloc(2);
        a[0] = create(rootSalt);
        b[1] = directoryBody(subjectId(principal, rootSalt));
        a[1] = publish(t.directory, b[1]);
        rootDirectory = recordId(t.directory, b[1]);
    }

    /// Create folder: `CREATE(salt)`, `PUBLISH(files-directory/1)`, `PUBLISH(files-name/2, name)` when
    /// `withName`, `BIND(FOLDER, parent, keccak(name) → directoryRecord, exp 0)`.
    function createFolder(
        Types memory t,
        bytes32 principal,
        bytes32 parent,
        bytes32 salt,
        bytes memory name,
        bool withName
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 directory) {
        (a, b) = _alloc(withName ? 4 : 3);
        a[0] = create(salt);
        b[1] = directoryBody(subjectId(principal, salt));
        a[1] = publish(t.directory, b[1]);
        directory = recordId(t.directory, b[1]);
        uint256 k = 2;
        if (withName) k = _name(t, a, b, k, name);
        a[k] = bind(Purpose.FOLDER, parent, keccak256(name), directory, 0);
    }

    /// Create file: `CREATE(salt)`, `PUBLISH(files-root/1, file ‖ document)`, `PUBLISH(files-name/2, name)` when
    /// `withName`, `BIND(HEAD, file, 0 → root, exp 0)`, `BIND(FOLDER, folder, keccak(name) → file, exp 0)`.
    function createFile(
        Types memory t,
        bytes32 principal,
        bytes32 folder,
        bytes32 salt,
        bytes memory name,
        bytes memory document,
        bool withName
    )
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRecord)
    {
        (a, b) = _alloc(withName ? 5 : 4);
        file = subjectId(principal, salt);
        a[0] = create(salt);
        b[1] = rootBody(file, document);
        a[1] = publish(t.root, b[1]);
        rootRecord = recordId(t.root, b[1]);
        uint256 k = 2;
        if (withName) k = _name(t, a, b, k, name);
        a[k] = bind(Purpose.HEAD, file, 0, rootRecord, 0);
        a[k + 1] = bind(Purpose.FOLDER, folder, keccak256(name), file, 0);
    }

    /// Edit: `PUBLISH(files-child/1, parent ‖ file ‖ document)`, `BIND(HEAD, file, 0 → child, exp current)`.
    function edit(
        Types memory t,
        bytes32 file,
        bytes32 parentRecord,
        bytes memory document,
        uint64 expectedHead
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 childRecord) {
        (a, b) = _alloc(2);
        b[0] = childBody(parentRecord, file, document);
        a[0] = publish(t.child, b[0]);
        childRecord = recordId(t.child, b[0]);
        a[1] = bind(Purpose.HEAD, file, 0, childRecord, expectedHead);
    }

    /// Rename / move (atomic by the rollback law): `PUBLISH(files-name/2, newName)` when `withName`,
    /// `UNBIND(FOLDER, from, keccak(oldName), exp)`, `BIND(FOLDER, to, keccak(newName) → target, exp)`. `target` is
    /// the file subject or directory record being moved; `expectedNew` is the new position's revision (0 when
    /// fresh, the masked or released head's revision for a restore over it).
    function move(
        Types memory t,
        bytes32 target,
        bytes32 from,
        bytes memory oldName,
        uint64 expectedOld,
        bytes32 to,
        bytes memory newName,
        uint64 expectedNew,
        bool withName
    ) internal pure returns (Action[] memory a, bytes[] memory b) {
        (a, b) = _alloc(withName ? 3 : 2);
        uint256 k = 0;
        if (withName) k = _name(t, a, b, k, newName);
        a[k] = unbind(Purpose.FOLDER, from, keccak256(oldName), expectedOld);
        a[k + 1] = bind(Purpose.FOLDER, to, keccak256(newName), target, expectedNew);
    }

    /// Remove: `UNBIND(FOLDER, folder, keccak(name), exp)` (the head is MASKED: it beats fall-through).
    function remove(bytes32 folder, bytes memory name, uint64 expected)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        (a, b) = _alloc(1);
        a[0] = unbind(Purpose.FOLDER, folder, keccak256(name), expected);
    }

    /// Restore: `BIND(FOLDER, folder, keccak(name) → target, exp)` (a same-target restore is a rewrite).
    function restore(bytes32 folder, bytes memory name, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        (a, b) = _alloc(1);
        a[0] = bind(Purpose.FOLDER, folder, keccak256(name), target, expected);
    }

    /// Stop claiming: `RELEASE(FOLDER, folder, keccak(name), exp)` (the head falls through to lower principals).
    function releaseEntry(bytes32 folder, bytes memory name, uint64 expected)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        (a, b) = _alloc(1);
        a[0] = release(Purpose.FOLDER, folder, keccak256(name), expected);
    }

    /// `x ‖ y` for both arrays: several recipes in one publication (a staged save; at most `limits.maxActions`).
    function concat(Action[] memory xa, bytes[] memory xb, Action[] memory ya, bytes[] memory yb)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        (a, b) = _alloc(xa.length + ya.length);
        for (uint256 i; i < xa.length; ++i) {
            a[i] = xa[i];
            b[i] = xb[i];
        }
        for (uint256 i; i < ya.length; ++i) {
            a[xa.length + i] = ya[i];
            b[xa.length + i] = yb[i];
        }
    }

    function _alloc(uint256 n) private pure returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](n);
        b = new bytes[](n);
    }

    function _name(
        Types memory t,
        Action[] memory a,
        bytes[] memory b,
        uint256 k,
        bytes memory name
    ) private pure returns (uint256) {
        b[k] = nameBody(name);
        a[k] = publish(t.name, b[k]);
        return k + 1;
    }
}
