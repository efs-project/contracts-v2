// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Action, ActionKind, Purpose} from "../interfaces/Actions.sol";

/// @title EfsFiles — the Files recipes of design §12.2 as `Action[]`/`bytes[]` builders (design §5.14)
/// @notice Pure builders for the measured recipes — root seed, create folder, create file, edit, rename/move,
///         remove, hide, restore — plus the body encoders of the ten Files Types (§12.1 and docs/LARGE-FILES.md),
///         the canonical chunker of a large file (`efs/chunking/1`, `chunk`), a publication splitter (`split`,
///         `slice`) and the ids a client needs (subject, record, name record, position, FOLDER scope). Every builder
///         returns the `actions` and the aligned `bodies` the ledger's `execute` takes; hand them to
///         `EfsNative.batch` (or `ILedger.execute`).
///         Type ids are the caller's (`Types`): `profiles/FilesTypes.sol` derives them from the release's
///         descriptors, and they are identical on every Realm for one declaration key.
///
///         Recipe shapes (design §12.2): a FOLDER bind is `BIND(FOLDER, parentDirectoryRecord, keccak(name) →
///         target)` — the subject is the parent's `files-directory/1` record id, the role the name's body hash, the
///         target a file subject or a directory record; a HEAD bind is `BIND(HEAD, fileSubject, 0 → record)`.
///         A file is a created subject (`subjectId`, domain `efs/subject/1`) and a folder is a `files-directory/1`
///         record (`directoryRecord`, domain `efs/record/1`) whose body names its creator and a salt; the two
///         domains differ, so no id is both and the kind of a target is a property of its id.
///         Removing an entry RELEASEs it (my claim stops and a lower-ranked author's entry at the same place shows
///         through); hiding UNBINDs it (a MASK, which stops a lens search, so it hides every lower-ranked author's
///         entry at that place too, for readers who rank me first).
///         `FilesFinalValidator` requires a `files-name/3` record for the role at or before the publication's
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
        bytes32 span;
    }

    /// The `files-content/1` body (docs/LARGE-FILES.md): ten words, then the `media` bytes (their length is the
    /// body's beyond 320; a MIME media type: empty for unknown, else a lowercase RFC 6838 `type/subtype` with
    /// optional `;` parameters, at most 255 bytes; `FilesProfile.mediaTypeRefusal` is the law). The media bytes are
    /// the rest of the body, so nothing can follow them. These encoders do not validate it: an SDK lowercases the
    /// type and subtype and refuses an invalid string before it builds the plan.
    struct Content {
        bytes32 bytesRef;
        uint256 version;
        uint256 carrier;
        uint256 hashAlg;
        uint256 length;
        bytes32 sha256Digest;
        uint256 cipher;
        bytes32 nonce12;
        uint256 plaintextLength;
        bytes32 plaintextSha256OrZero;
        bytes media;
    }

    bytes32 internal constant DOM_RECORD = keccak256("efs/record/1");
    bytes32 internal constant DOM_SUBJECT = keccak256("efs/subject/1");
    bytes32 internal constant DOM_POSITION = keccak256("efs/position/1");
    bytes32 internal constant DOM_SCOPE = keccak256("efs/vk/binding-scope/1");
    /// `directory-alias/1` kinds (design §12.1).
    uint256 internal constant ALIAS_DIRECTORY = 1;
    uint256 internal constant ALIAS_FILE = 2;
    /// The revision `form` word (docs/LARGE-FILES.md): 0 the file's bytes follow, 1 one word names a descriptor.
    uint256 internal constant FORM_INLINE = 0;
    uint256 internal constant FORM_CONTENT = 1;
    /// `files-content/1` carriers: one `files-bytes/1` record, the remote sentinel, a `files-span/1` root.
    uint256 internal constant CARRIER_INLINE = 0;
    uint256 internal constant CARRIER_REMOTE = 1;
    uint256 internal constant CARRIER_SPAN = 2;
    /// The one `files-external/1` carrier: a URI locator.
    uint256 internal constant CARRIER_LOCATION = 2;
    uint256 internal constant HASH_SHA256 = 1;
    /// `efs/chunking/1`: the canonical chunk payload (a `files-bytes/1` body of 8,192 bytes, the S1 `maxBody`).
    uint256 internal constant CHUNK_PAYLOAD = 8_160;

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

    /// The `files-name/3` record id whose body hash is `role_` (`Keys.recordFromHash(nameType, role)`).
    function nameRecord(bytes32 nameType, bytes32 role_) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOM_RECORD, nameType, role_));
    }

    /// The `files-directory/1` record id of the folder `creator` made with `salt` (`directoryBody`).
    function directoryRecord(bytes32 directoryType, bytes32 creator, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return recordId(directoryType, directoryBody(creator, salt));
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

    /// `files-root/1` form 0 (INLINE): `abi.encode(fileSubject, 0) ‖ document`.
    function rootBody(bytes32 file, bytes memory document) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(file, FORM_INLINE), document);
    }

    /// `files-root/1` form 1 (CONTENT): `abi.encode(fileSubject, 1, descriptor)`; `descriptor` is an admitted
    /// `files-content/1` or `files-external/1` record (it may be published earlier in the same publication).
    function rootRefBody(bytes32 file, bytes32 descriptor) internal pure returns (bytes memory) {
        return abi.encode(file, FORM_CONTENT, descriptor);
    }

    /// `files-child/1` form 0 (INLINE): `abi.encode(parentRecord, fileSubject, 0) ‖ document`.
    function childBody(bytes32 parent, bytes32 file, bytes memory document)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(abi.encode(parent, file, FORM_INLINE), document);
    }

    /// `files-child/1` form 1 (CONTENT): `abi.encode(parentRecord, fileSubject, 1, descriptor)`.
    function childRefBody(bytes32 parent, bytes32 file, bytes32 descriptor)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(parent, file, FORM_CONTENT, descriptor);
    }

    /// `files-directory/1`: `abi.encode(creatorPrincipal, salt)` (64 bytes). `FilesDirectoryRule` admits it only
    /// when the publishing principal is `creator` and `salt` is nonzero.
    function directoryBody(bytes32 creator, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encode(creator, salt);
    }

    /// `files-name/3`: the raw UTF-8 name (its rule judges well-formedness; this encoder is the identity).
    function nameBody(bytes memory name) internal pure returns (bytes memory) {
        return name;
    }

    /// `files-bytes/1`: `sha256(payload) ‖ payload`.
    function bytesBody(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(sha256(payload), payload);
    }

    /// `files-span/1`: `abi.encode(left, right, length)`; `length` is the two children's payload lengths summed.
    function spanBody(bytes32 left, bytes32 right, uint256 length)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(left, right, length);
    }

    /// `files-content/1`: the ten words in order, then the media bytes (320 + media.length bytes).
    function contentBody(Content memory c) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(c.bytesRef, c.version, c.carrier, c.hashAlg, c.length, c.sha256Digest),
            abi.encode(c.cipher, c.nonce12, c.plaintextLength, c.plaintextSha256OrZero),
            c.media
        );
    }

    /// A plaintext `files-content/1` (version 1, sha256, cipher 0): `ref` is the `files-bytes/1` record (carrier 0),
    /// the empty sentinel (carrier 1) or the `files-span/1` root (carrier 2) of `length` bytes hashing to `digest`.
    /// For carrier 2 the sha256 is the author's claim (a reader verifies it after reading the tree).
    function contentBody(
        bytes32 ref,
        uint256 carrier,
        uint256 length,
        bytes32 digest,
        bytes memory media
    ) internal pure returns (bytes memory) {
        return contentBody(
            Content({
                bytesRef: ref,
                version: 1,
                carrier: carrier,
                hashAlg: HASH_SHA256,
                length: length,
                sha256Digest: digest,
                media: media,
                cipher: 0,
                nonce12: 0,
                plaintextLength: length,
                plaintextSha256OrZero: digest
            })
        );
    }

    /// `files-external/1`: `[emptyBytesRef, 2, 2, 1, length, sha256, locatorLength] ‖ locator ‖ media`;
    /// `locator` is any URI (1..2,048 printable ASCII bytes with an RFC 3986 scheme: `ar://…`, `ipfs://…`,
    /// `web3://…`, `https://…`); `media` is the media type as in `Content` (empty for unknown).
    function externalBody(
        bytes32 emptyBytesRef,
        uint256 length,
        bytes32 sha256Digest,
        bytes memory locator,
        bytes memory media
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(
                emptyBytesRef,
                uint256(2),
                CARRIER_LOCATION,
                HASH_SHA256,
                length,
                sha256Digest,
                locator.length
            ),
            locator,
            media
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
        a.saltOrStrength = salt;
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

    /// A BIND that states the number `strength` (0..65,535; `bind` states 0). Changing a positive number on the
    /// same target is this action again under the head's current revision (a REBIND).
    function bindWithStrength(
        bytes32 purpose,
        bytes32 subject,
        bytes32 role_,
        bytes32 target,
        uint64 expected,
        uint16 strength
    ) internal pure returns (Action memory a) {
        a = bind(purpose, subject, role_, target, expected);
        a.saltOrStrength = bytes32(uint256(strength));
    }

    /// An UNBIND that states the number `-1 - strength` (-1..-65,536; `unbind` states -1). It is admitted from
    /// every state, so it also changes a negative number (expected = the masked head's revision).
    function unbindWithStrength(
        bytes32 purpose,
        bytes32 subject,
        bytes32 role_,
        uint64 expected,
        uint16 strength
    ) internal pure returns (Action memory a) {
        a = unbind(purpose, subject, role_, expected);
        a.saltOrStrength = bytes32(uint256(strength));
    }

    /// A lone negative: a first statement that is negative ("not this", number `-1 - strength`) about a position
    /// the author never stated anything at, so `expectedRevision` is 0 (transition FIRST_MASK).
    function loneNegative(bytes32 purpose, bytes32 subject, bytes32 role_, uint16 strength)
        internal
        pure
        returns (Action memory)
    {
        return unbindWithStrength(purpose, subject, role_, 0, strength);
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

    /// Root (the seed, once per Realm): `PUBLISH(files-directory/1, (principal, rootSalt))` by `principal`; no
    /// CREATE and no FOLDER bind. Returns the root directory record id.
    function rootSeed(Types memory t, bytes32 principal, bytes32 rootSalt)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 rootDirectory)
    {
        (a, b) = _alloc(1);
        b[0] = directoryBody(principal, rootSalt);
        a[0] = publish(t.directory, b[0]);
        rootDirectory = recordId(t.directory, b[0]);
    }

    /// Create folder: `PUBLISH(files-directory/1, (principal, salt))`, `PUBLISH(files-name/3, name)` when
    /// `withName`, `BIND(FOLDER, parent, keccak(name) → directoryRecord, exp 0)`; no CREATE. `principal` must be the
    /// publishing principal (`FilesDirectoryRule` refuses any other).
    function createFolder(
        Types memory t,
        bytes32 principal,
        bytes32 parent,
        bytes32 salt,
        bytes memory name,
        bool withName
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 directory) {
        (a, b) = _alloc(withName ? 3 : 2);
        b[0] = directoryBody(principal, salt);
        a[0] = publish(t.directory, b[0]);
        directory = recordId(t.directory, b[0]);
        uint256 k = 1;
        if (withName) k = _name(t, a, b, k, name);
        a[k] = bind(Purpose.FOLDER, parent, keccak256(name), directory, 0);
    }

    /// Create file: `CREATE(salt)`, `PUBLISH(files-root/1, file ‖ 0 ‖ document)`, `PUBLISH(files-name/3, name)`
    /// when `withName`, `BIND(HEAD, file, 0 → root, exp 0)`, `BIND(FOLDER, folder, keccak(name) → file, exp 0)`.
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
        return _createFile(
            t,
            principal,
            folder,
            salt,
            name,
            bytes.concat(abi.encode(FORM_INLINE), document),
            withName
        );
    }

    /// Create a file whose first revision names a descriptor (form 1): as `createFile` with the root body
    /// `file ‖ 1 ‖ descriptor`. `descriptor` must be admitted before this publication's root leaf (an earlier
    /// publication, or earlier leaves of the same one: `concat(storeContent(..), createFileRef(..))`).
    function createFileRef(
        Types memory t,
        bytes32 principal,
        bytes32 folder,
        bytes32 salt,
        bytes memory name,
        bytes32 descriptor,
        bool withName
    )
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRecord)
    {
        return _createFile(
            t, principal, folder, salt, name, abi.encode(FORM_CONTENT, descriptor), withName
        );
    }

    function _createFile(
        Types memory t,
        bytes32 principal,
        bytes32 folder,
        bytes32 salt,
        bytes memory name,
        bytes memory tail,
        bool withName
    ) private pure returns (Action[] memory a, bytes[] memory b, bytes32 file, bytes32 rootRecord) {
        (a, b) = _alloc(withName ? 5 : 4);
        file = subjectId(principal, salt);
        a[0] = create(salt);
        b[1] = bytes.concat(abi.encode(file), tail);
        a[1] = publish(t.root, b[1]);
        rootRecord = recordId(t.root, b[1]);
        uint256 k = 2;
        if (withName) k = _name(t, a, b, k, name);
        a[k] = bind(Purpose.HEAD, file, 0, rootRecord, 0);
        a[k + 1] = bind(Purpose.FOLDER, folder, keccak256(name), file, 0);
    }

    /// Edit: `PUBLISH(files-child/1, parent ‖ file ‖ 0 ‖ document)`, `BIND(HEAD, file, 0 → child, exp current)`.
    function edit(
        Types memory t,
        bytes32 file,
        bytes32 parentRecord,
        bytes memory document,
        uint64 expectedHead
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 childRecord) {
        return _edit(t, file, childBody(parentRecord, file, document), expectedHead);
    }

    /// Edit to a descriptor (form 1): `PUBLISH(files-child/1, parent ‖ file ‖ 1 ‖ descriptor)`, `BIND(HEAD, …)`.
    function editRef(
        Types memory t,
        bytes32 file,
        bytes32 parentRecord,
        bytes32 descriptor,
        uint64 expectedHead
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 childRecord) {
        return _edit(t, file, childRefBody(parentRecord, file, descriptor), expectedHead);
    }

    function _edit(Types memory t, bytes32 file, bytes memory body, uint64 expectedHead)
        private
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 childRecord)
    {
        (a, b) = _alloc(2);
        b[0] = body;
        a[0] = publish(t.child, b[0]);
        childRecord = recordId(t.child, b[0]);
        a[1] = bind(Purpose.HEAD, file, 0, childRecord, expectedHead);
    }

    /// Rename / move (atomic by the rollback law): `PUBLISH(files-name/3, newName)` when `withName`,
    /// `RELEASE(FOLDER, from, keccak(oldName), exp)`, `BIND(FOLDER, to, keccak(newName) → target, exp)`, in one
    /// publication. The source is RELEASED, not masked, so a lower-ranked author's entry of the old name shows
    /// through. `target` is the file subject or directory record being moved; `expectedNew` is the new position's
    /// revision (0 when fresh, the masked or released head's revision for a restore over it).
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
        a[k] = release(Purpose.FOLDER, from, keccak256(oldName), expectedOld);
        a[k + 1] = bind(Purpose.FOLDER, to, keccak256(newName), target, expectedNew);
    }

    /// Remove (stop claiming): `RELEASE(FOLDER, folder, keccak(name), exp)`. My head is RELEASED and falls through:
    /// a reader that ranks me first sees the next principal's entry of that name, if any. `exp` is my head's
    /// current revision; a MASKED (hidden) head can be released too.
    function remove(bytes32 folder, bytes memory name, uint64 expected)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        (a, b) = _alloc(1);
        a[0] = release(Purpose.FOLDER, folder, keccak256(name), expected);
    }

    /// Hide: `UNBIND(FOLDER, folder, keccak(name), exp)`. My head is MASKED, and a mask stops a lens search: for a
    /// reader that ranks me first the name is absent, whatever any lower-ranked principal binds there. Use it only to
    /// hide the place; to delete my own entry use `remove`.
    function hide(bytes32 folder, bytes memory name, uint64 expected)
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

    // =============================================================================================
    // Large files: the canonical chunker (`efs/chunking/1`) and publication splitting
    // =============================================================================================

    /// The chunker's working state (memory, shared by the recursion).
    struct Tree {
        bytes32 spanType;
        uint256 size;
        uint256 total;
        bytes32[] chunks;
        Action[] a;
        bytes[] b;
        uint256 cursor;
    }

    /// `efs/chunking/1` (docs/LARGE-FILES.md; a convention, never enforced): `payload` cut into `chunkPayload`-byte
    /// chunks except the last (`CHUNK_PAYLOAD` = 8,160 is the canonical size; an empty payload is one empty chunk,
    /// the sentinel record), one `files-bytes/1` PUBLISH per chunk, and over `n` chunks the tree `tree(1) = the
    /// chunk`, `tree(n) = span(tree(first k), tree(rest))` with `k` the largest power of two below `n`.
    ///
    /// Publication order (children always before their parents): every chunk in payload order (leaves
    /// `0..n-1`), then the `n − 1` span nodes in post-order (left subtree, right subtree, node), so the last
    /// action is the root span. Cutting the list anywhere keeps that order, so `split` may cut it into
    /// publications. A chunk that occurs twice is published twice (the second PUBLISH is a new occurrence of the
    /// same record, never a new cell); a client may drop any action whose record already exists, ids unchanged.
    /// Returns the `2n − 1` actions and aligned bodies, the root record (the one chunk when `n == 1`, else the
    /// root span) and whether it is a span (`files-content/1` carrier 2) or a chunk (carrier 0).
    function chunk(bytes32 bytesType, bytes32 spanType, bytes memory payload, uint256 chunkPayload)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b, bytes32 root, bool isSpan)
    {
        require(chunkPayload != 0, "EfsFiles: chunk size");
        uint256 total = payload.length;
        uint256 n = total == 0 ? 1 : (total + chunkPayload - 1) / chunkPayload;
        Tree memory tr;
        tr.spanType = spanType;
        tr.size = chunkPayload;
        tr.total = total;
        tr.chunks = new bytes32[](n);
        (tr.a, tr.b) = _alloc(2 * n - 1);
        for (uint256 i; i < n; ++i) {
            uint256 start = i * chunkPayload;
            uint256 len = _min(chunkPayload, total - start);
            bytes memory piece = new bytes(len);
            // word copies inside the piece's allocation; the last word keeps only the piece's own bytes
            for (uint256 j; j < len; j += 32) {
                bytes32 w;
                assembly ("memory-safe") {
                    w := mload(add(add(payload, 32), add(start, j)))
                }
                if (len - j < 32) w &= bytes32(~(type(uint256).max >> ((len - j) * 8)));
                assembly ("memory-safe") {
                    mstore(add(add(piece, 32), j), w)
                }
            }
            tr.b[i] = bytesBody(piece);
            tr.a[i] = publish(bytesType, tr.b[i]);
            tr.chunks[i] = recordId(bytesType, tr.b[i]);
        }
        if (n == 1) return (tr.a, tr.b, tr.chunks[0], false);
        tr.cursor = n;
        root = _tree(tr, 0, n);
        return (tr.a, tr.b, root, true);
    }

    /// The record of `tree(chunks[lo..hi))`; appends its span nodes in post-order.
    function _tree(Tree memory tr, uint256 lo, uint256 hi) private pure returns (bytes32) {
        uint256 n = hi - lo;
        if (n == 1) return tr.chunks[lo];
        uint256 k = 1;
        while (k * 2 < n) k *= 2;
        bytes32 left = _tree(tr, lo, lo + k);
        bytes32 right = _tree(tr, lo + k, hi);
        uint256 length = _min(hi * tr.size, tr.total) - lo * tr.size;
        bytes memory body = spanBody(left, right, length);
        tr.a[tr.cursor] = publish(tr.spanType, body);
        tr.b[tr.cursor] = body;
        ++tr.cursor;
        return recordId(tr.spanType, body);
    }

    /// Store `payload` on chain: `chunk` with `t.bytes_`/`t.span`, then `PUBLISH(files-content/1)` describing it
    /// (plaintext; carrier 2 over the span root, or carrier 0 over the one chunk; `media` its media type, empty for
    /// unknown). Returns the actions, bodies and
    /// the descriptor record id a form-1 revision names (`createFileRef`, `editRef`).
    function storeContent(
        Types memory t,
        bytes memory payload,
        uint256 chunkPayload,
        bytes memory media
    ) internal pure returns (Action[] memory a, bytes[] memory b, bytes32 descriptor) {
        (Action[] memory ca, bytes[] memory cb, bytes32 root, bool isSpan) =
            chunk(t.bytes_, t.span, payload, chunkPayload);
        (a, b) = _alloc(ca.length + 1);
        for (uint256 i; i < ca.length; ++i) {
            a[i] = ca[i];
            b[i] = cb[i];
        }
        bytes memory body = contentBody(
            root, isSpan ? CARRIER_SPAN : CARRIER_INLINE, payload.length, sha256(payload), media
        );
        a[ca.length] = publish(t.content, body);
        b[ca.length] = body;
        descriptor = recordId(t.content, body);
    }

    /// Greedy publication boundaries over an ordered action list: each publication takes the next actions while
    /// it holds at most `maxActions` actions and `maxBodyBytes` body bytes (the Realm's `limits.maxActions` and
    /// `limits.maxBodyBytesPerPublication`). Returns the exclusive end index of every publication, in order
    /// (`slice(a, b, ends[i-1], ends[i])`). A body larger than `maxBodyBytes` is put alone in its publication (which
    /// the kernel then refuses); the other per-publication limits (binds, fresh slots) are the caller's.
    function split(bytes[] memory b, uint256 maxActions, uint256 maxBodyBytes)
        internal
        pure
        returns (uint256[] memory ends)
    {
        require(maxActions != 0, "EfsFiles: maxActions");
        ends = new uint256[](b.length);
        uint256 count;
        uint256 actions;
        uint256 bytes_;
        for (uint256 i; i < b.length; ++i) {
            uint256 len = b[i].length;
            if (actions != 0 && (actions == maxActions || bytes_ + len > maxBodyBytes)) {
                ends[count++] = i;
                actions = 0;
                bytes_ = 0;
            }
            ++actions;
            bytes_ += len;
        }
        if (actions != 0) ends[count++] = b.length;
        assembly ("memory-safe") {
            mstore(ends, count)
        }
    }

    /// `a[from..to)` and `b[from..to)`.
    function slice(Action[] memory a, bytes[] memory b, uint256 from, uint256 to)
        internal
        pure
        returns (Action[] memory xa, bytes[] memory xb)
    {
        (xa, xb) = _alloc(to - from);
        for (uint256 i = from; i < to; ++i) {
            xa[i - from] = a[i];
            xb[i - from] = b[i];
        }
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
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
