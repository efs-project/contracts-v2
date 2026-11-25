// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";
import {Purpose} from "../interfaces/Actions.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {IFilesPageReader, IReader} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {IWeb3Gateway, KeyValue} from "../interfaces/IWeb3Gateway.sol";
import {IWeb3Content} from "../interfaces/IWeb3Content.sol";
import {E_WEB3_CONFIG, E_WEB3_STATUS} from "./EfsWeb3Content.sol";

// Narrowing casts are ASCII bytes and the facet's 32-bit word index; the gateway reads the ledger row by row, so
// calls in loops are its purpose, bounded by the path depth and the lens length. Ignored tuple components are fields
// the gateway does not need; a zero page reader is the documented "no listings" configuration; `_fail` is the one
// refusal path, loops included.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(unused-return)
// forge-lint: disable-start(missing-zero-check)
// forge-lint: disable-start(require-revert-in-loop)

/// @title EfsWeb3Gateway/1 — EFS content over `web3://` (docs/LARGE-FILES.md "`web3://`")
/// @notice ERC-5219 resource-request mode (`resolveMode() == "5219"`) with ERC-7617 chunked bodies. Immutable and
///         stateless, outside the execution set, so it can be added, fixed and replaced after a freeze. This is the
///         one address a `web3://<gateway>/…` URL names: it parses the URL, resolves names and the lens, applies the
///         HEAD selection and serves listings; the revision it selects is served by `CONTENT`, an `EfsWeb3Content`
///         bound to the same ledger, reached by STATICCALL at an immutable address whose codehash is recorded
///         (`CONTENT_CODEHASH`, checked on every call). Bound at construction to one ledger, its `LedgerReads`
///         facet (a folder's creator word, a subject's creator), its `LedgerViews` facet (held for parity with the
///         other readers; this version needs no composite read), an optional `FilesPageReader` (zero: no listings),
///         the content server, the Realm's root `files-directory/1` record and the `files-directory/1` Type id.
///         Facts come from the Etched hot getters (`head`, `recordHeader`, `layoutId`) and the facet; it never
///         reads raw slots and never consults the index for a file read.
///
///         URL grammar (docs/LARGE-FILES.md "`web3://`"; the shared link grammar): the FIRST path segment decides
///         the kind of path.
///         - `/0x<40 hex>[/<name>…][/][?lens=…][&offset=<n>]`: that address's HOME (its place,
///           `bytes32(uint256(uint160(address)))`, design §12.5). The lens defaults to the address's own author
///           identity, `Keys.principalFor(address, realmOrigin)`: the key principal of a key account, the Realm's
///           contract principal of a contract (a Safe's home shows the Safe's own entries). The home itself is named
///           `x-efs-home: 0x<40 hex>` (lowercase) in place of `x-efs-record`: a home is an address, never a record.
///           Any other segment starting `0x` or `0X` (and a byte more) is 400 "malformed id".
///         - `/~efs/o/<object id>[/<name>…][/][?lens=…][&offset=<n>]` (an object link; `0x` + 64 hex, any case):
///           a `files-directory/1` record id is that FOLDER, the Realm root included, with the names below it; the
///           lens defaults to the folder's creator, the record's body word 0 (`abi.encode(creator, salt)`). A
///           created subject is a FILE: its current HEAD under the lens, served exactly as a named file is; the lens
///           defaults to the subject's creator (the principal of the publication that created it,
///           `LedgerReads.subjectInfo`); a name after it is 404 "not found: file used as a folder". An id that is a
///           record of any other Type (a file revision, a name, a descriptor) is 501 "object not served": it
///           exists, this gateway does not serve that kind of object link, and it is never 404. Only an id that is
///           neither a record nor a created subject is 404 "not found"; never an empty listing. An id of another
///           shape is 400 "malformed id".
///         - `/~efs/v/<revision record id>[?offset=<n>]` (a revision link): exactly that `files-root/1` or
///           `files-child/1` record's bytes, with no lens (`lens` is ignored), whether or not it is anyone's HEAD;
///           `Content-Type` from its descriptor, else `application/octet-stream` (there is no name). An existing
///           record of another Type or a created subject is 501 "object not served", an id that names nothing 404,
///           a malformed id 400 "malformed id", and a missing id or a segment after it 400 "malformed revision
///           link". Every other `~` first segment, and every other `~efs/…` form, is 400 "unknown system path"
///           (`~` first segments are the system's).
///         - Anything else is a topic path (`/<word>/…`): 501 "topic paths are not served" (this gateway serves
///           none yet). No folder is ever served there, so a topic link can never mean a folder.
///         `lens` replaces the default lens with exactly the listed principals (at most 64): each 64 hex digits (a
///         principal id), `0x` + 64 hex digits (the same), or `0x` + 40 hex digits (an account; accepted only when
///         `Keys.principalFor` makes it a key principal — no code, or exactly an EIP-7702 designator — and then the
///         left-padded address; a contract account is 400, use its id). Hex is case-insensitive, no checksum.
///         `offset` (decimal, < 2^64, default 0) is the first byte served. Other parameters are ignored; a repeated
///         parameter's last value wins. A trailing empty segment (a trailing slash) is dropped; any other empty
///         segment is 400. At most 32 names, each 1..255 bytes. `ROOT_DIRECTORY` is the Realm root's record id, the
///         folder id of the root's own path `/~efs/o/<ROOT_DIRECTORY>/…`; it is configuration, never a default.
///
///         Resolution: each name is one FOLDER position `(FOLDER, directoryRecord, keccak256(name))`, read for each
///         principal in order through `ILedgerHot.head(Keys.binding(principal, position))`: the first BOUND head
///         wins, a MASKED head stops (mask beats fall-through), UNSET and RELEASED fall through. A directory target
///         continues the walk; a file subject must be the last name. A file's HEAD `(HEAD, file, 0)` is resolved the
///         same way; a HEAD that is not a record target is 500 "HEAD law: target is not a record", and the record is
///         handed to `CONTENT.serveRevision(record, file, lastName, offset)`, which checks the rest of the reader-side
///         HEAD law ("HEAD law: target not a revision", "HEAD law: short revision", "HEAD law: revision of other
///         file") and serves it: inline bytes, one chunk of a `files-content/1` descriptor, or a `files-external/1`
///         location as a 307 (see `EfsWeb3Content`). When a chunk does not reach the end of the file the gateway adds
///         `web3-next-chunk: /<path>?offset=<next>[&lens=…]`. A directory: with a page reader, 200
///         `application/json` `{"entries":[{"name":…,"kind":"file"|"directory"}…],"complete":bool}` from one page of
///         at most `LISTING_LIMIT` rows and `x-efs-listing: complete|partial`; a listing the pager answers with a
///         status other than PRESENT is 500 "listing refused" (UNSUPPORTED 503), one that reverts 500 "listing
///         failed"; without a page reader, 200 `directory`.
///
///         Statuses (never a revert for anything a URL can cause): 200 served; 307 external location; 400 malformed
///         URL or unknown system path; 404 not found, removed (masked), file used as a folder, no revision, an id that
///         names nothing, or remote-only content; 501 a link form not served yet (a topic path, the id of an
///         existing object that is neither a folder nor a file, a revision link to an object that is not a
///         revision); 416 `offset` at or past the end (except 0 on an empty file); 500 a broken invariant (a Type,
///         length or record the Files laws guarantee is wrong or missing, a failed listing); 503 a ledger layout or
///         head state this gateway was not built for, or a read the facet refuses (UNSUPPORTED, LIMIT_EXCEEDED).
/// @dev `request` calls `serve` on itself by STATICCALL; every refusal inside, the content server's included, is
///      `E_WEB3_STATUS(status, reason)` and any other failure of the inner frame (a dependency revert, out of gas) is
///      a 500, so `request` itself only fails when the outer frame cannot encode its answer.
contract EfsWeb3Gateway is IWeb3Gateway {
    uint16 public constant FACET_VERSION = 1;
    uint256 public constant MAX_NAMES = 32;
    uint256 public constant MAX_NAME_BYTES = 255;
    uint256 public constant MAX_PRINCIPALS = 64;
    uint32 public constant LISTING_LIMIT = 64;
    /// The page reader stops before a row when its frame has less than this left (its `gasReserve`).
    uint256 public constant LISTING_GAS_RESERVE = 300_000;

    uint8 private constant BOUND = 1;
    uint8 private constant MASKED = 2;
    uint8 private constant RELEASED = 3;
    uint8 private constant TARGET_RECORD = 1;
    uint8 private constant TARGET_SUBJECT = 2;
    uint8 private constant ROW_ENTRY = 1;
    uint256 private constant MAX_HEADERS = 3;
    bytes16 private constant HEX = "0123456789abcdef";
    bytes16 private constant UPPER_HEX = "0123456789ABCDEF";
    string private constant TEXT = "text/plain; charset=utf-8";

    address private immutable LEDGER;
    address public immutable READS;
    address public immutable VIEWS;
    address public immutable PAGER;
    /// The `EfsWeb3Content` that serves the revisions this gateway selects, and its runtime codehash.
    address public immutable CONTENT;
    bytes32 public immutable CONTENT_CODEHASH;
    bytes32 private immutable LAYOUT;
    bytes32 public immutable ROOT_DIRECTORY;
    bytes32 public immutable DIRECTORY_TYPE;

    /// One request's working state.
    struct Req {
        bytes32[] lens;
        uint256 offset;
        bytes lensParam;
        uint256 last;
        KeyValue[] h;
        uint256 n;
        uint256 start;
        bytes32 home;
        bytes32 folder;
        bool revision;
    }

    /// @param pager_ a `FilesPageReader` bound to `ledger_`, or zero for no listings
    /// @param content_ an `EfsWeb3Content` bound to `ledger_`
    /// @param rootDirectory_ the Realm root's `files-directory/1` record id (served as `/~efs/o/<id>/`)
    /// @param directoryType_ the `files-directory/1` Type id
    constructor(
        address ledger_,
        address reads_,
        address views_,
        address pager_,
        address content_,
        bytes32 rootDirectory_,
        bytes32 directoryType_
    ) {
        if (
            ledger_ == address(0) || reads_ == address(0) || views_ == address(0)
                || content_ == address(0)
        ) {
            revert E_WEB3_CONFIG(1);
        }
        if (pager_ != address(0) && IReader(pager_).ledger() != ledger_) revert E_WEB3_CONFIG(2);
        if (IWeb3Content(content_).ledger() != ledger_) revert E_WEB3_CONFIG(3);
        LEDGER = ledger_;
        READS = reads_;
        VIEWS = views_;
        PAGER = pager_;
        CONTENT = content_;
        CONTENT_CODEHASH = content_.codehash;
        LAYOUT = ILedgerHot(ledger_).layoutId();
        ROOT_DIRECTORY = rootDirectory_;
        DIRECTORY_TYPE = directoryType_;
    }

    function facetVersion() external pure returns (uint16) {
        return FACET_VERSION;
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    /// The layout read from the ledger at construction; a ledger reporting another layout is served 503.
    function layoutId() external view returns (bytes32) {
        return LAYOUT;
    }

    /// @inheritdoc IWeb3Gateway
    function resolveMode() external pure returns (bytes32) {
        return "5219";
    }

    /// @inheritdoc IWeb3Gateway
    function request(string[] calldata resource, KeyValue[] calldata params)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers)
    {
        try this.serve(resource, params) returns (uint16 s, bytes memory b, KeyValue[] memory h) {
            return (s, string(b), h);
        } catch (bytes memory err) {
            statusCode = 500;
            body = "internal fault";
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(err, 32))
            }
            if (err.length >= 100 && selector == E_WEB3_STATUS.selector) {
                assembly ("memory-safe") {
                    let n := mload(err)
                    err := add(err, 4)
                    mstore(err, sub(n, 4))
                }
                (statusCode, body) = abi.decode(err, (uint16, string));
            }
            headers = new KeyValue[](1);
            headers[0] = KeyValue("Content-Type", TEXT);
        }
    }

    /// The inner frame of `request` (callable directly; its refusals are `E_WEB3_STATUS` reverts).
    function serve(string[] calldata resource, KeyValue[] calldata params)
        external
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        Req memory q = _parse(resource, params);
        if (ILedgerHot(LEDGER).layoutId() != LAYOUT) _fail(503, "foreign ledger layout");
        // a revision link: exactly that revision, no lens, no name (the content server judges the id)
        if (q.revision) return _serveRevision(q, resource, q.folder, 0, "");
        bytes32 dir = q.home;
        if (q.home == 0) {
            // an object by id: a `files-directory/1` record is a folder, never a silent empty folder, and its
            // creator (body word 0, `abi.encode(creator, salt)`) is the lens unless `lens` names one
            dir = q.folder;
            (bytes32 t,,,,) = ILedgerHot(LEDGER).recordHeader(dir);
            if (t != DIRECTORY_TYPE) {
                // a record of another Type (every record has a nonzero Type) exists: never absent
                if (t != 0) _fail(501, "object not served");
                // a created subject is a file, served under its creator's lens unless `lens` names one; only an
                // id that is neither a record nor a created subject is 404
                (Status st,, bytes32 creator) = ILedgerReads(READS).subjectInfo(LEDGER, dir);
                if (st == Status.ABSENT_PROVEN) _fail(404, "not found");
                _ok(st);
                if (q.start != q.last) _fail(404, "not found: file used as a folder");
                if (q.lensParam.length == 0) q.lens[0] = creator;
                return _file(q, resource, dir, "");
            }
            if (q.lensParam.length == 0) q.lens[0] = _words(dir, 0, 1)[0];
        }
        for (uint256 i = q.start; i < q.last; ++i) {
            (uint8 state, uint8 kind, bytes32 target) =
                _select(q.lens, Keys.position(Purpose.FOLDER, dir, keccak256(bytes(resource[i]))));
            if (state == MASKED) _fail(404, "not found: removed");
            if (state != BOUND) _fail(404, "not found");
            if (kind == TARGET_SUBJECT) {
                if (i + 1 != q.last) _fail(404, "not found: file used as a folder");
                return _file(q, resource, target, bytes(resource[i]));
            }
            if (kind != TARGET_RECORD || !_isDirectory(target)) {
                _fail(500, "folder target is not a directory");
            }
            dir = target;
        }
        return _directory(q, dir);
    }

    // =============================================================================================
    // Files
    // =============================================================================================

    function _isDirectory(bytes32 id) private view returns (bool) {
        (bytes32 typeId,,,,) = ILedgerHot(LEDGER).recordHeader(id);
        return typeId == DIRECTORY_TYPE;
    }

    /// The lens selection at `position`: (BOUND, kind, target), (MASKED, 0, 0) or (0, 0, 0) when every principal
    /// is UNSET or RELEASED. A reserved head state is 503 (it never falls through).
    function _select(bytes32[] memory lens, bytes32 position)
        private
        view
        returns (uint8, uint8, bytes32)
    {
        for (uint256 i; i < lens.length; ++i) {
            (uint8 state,,, uint8 kind,,, bytes32 target,) =
                ILedgerHot(LEDGER).head(Keys.binding(lens[i], position));
            if (state == BOUND) return (BOUND, kind, target);
            if (state == MASKED) return (MASKED, 0, 0);
            if (state != RELEASED && state != 0) _fail(503, "unsupported head state");
        }
        return (0, 0, 0);
    }

    /// File subject `file`'s HEAD `(HEAD, file, 0)` under the lens, served by the content server, which checks the
    /// rest of the reader-side HEAD law against `file`; `name` gives the extension fallback (empty: none).
    function _file(Req memory q, string[] calldata resource, bytes32 file, bytes memory name)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        (uint8 state, uint8 kind, bytes32 rev) =
            _select(q.lens, Keys.position(Purpose.HEAD, file, 0));
        if (state != BOUND) _fail(404, "not found: no revision");
        if (kind != TARGET_RECORD) _fail(500, "HEAD law: target is not a record");
        return _serveRevision(q, resource, rev, file, name);
    }

    /// `CONTENT.serveRevision` (its refusals revert through), then `web3-next-chunk` when the chunk is not the last.
    function _serveRevision(
        Req memory q,
        string[] calldata resource,
        bytes32 rev,
        bytes32 file,
        bytes memory name
    ) private view returns (uint16, bytes memory, KeyValue[] memory) {
        if (CONTENT.codehash != CONTENT_CODEHASH) {
            _fail(500, "content server changed");
        }
        (uint16 status, bytes memory body, KeyValue[] memory h, uint256 next) =
            IWeb3Content(CONTENT).serveRevision(rev, file, name, q.offset);
        if (next == 0) return (status, body, h);
        KeyValue[] memory all = new KeyValue[](h.length + 1);
        for (uint256 i; i < h.length; ++i) {
            all[i] = h[i];
        }
        all[h.length] = KeyValue("web3-next-chunk", _nextUrl(q, resource, next));
        return (status, body, all);
    }

    function _directory(Req memory q, bytes32 dir)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        // a home is an address, not a record: it is named as such
        if (dir == q.home) {
            _add(q, "x-efs-home", string(bytes.concat("0x", _cut(bytes(_hex(dir)), 26, 40))));
        } else {
            _add(q, "x-efs-record", _hex(dir));
        }
        if (PAGER == address(0)) {
            _add(q, "Content-Type", TEXT);
            return (200, "directory", _headers(q));
        }
        BasisCommit memory unbound;
        // F_NAME | F_KIND, directories and files (no whiteouts)
        IFilesPageReader.Query memory query = IFilesPageReader.Query(1 | 4, 0, 1 | 2);
        try IFilesPageReader(PAGER)
            .listDirectory(
                dir, q.lens, query, unbound, "", LISTING_LIMIT, LISTING_GAS_RESERVE
            ) returns (
            IFilesPageReader.DirectoryPage memory page
        ) {
            if (page.q.status == Status.UNSUPPORTED) _fail(503, "listing unsupported");
            if (page.q.status != Status.PRESENT) _fail(500, "listing refused");
            // complete only when the pager proves it and offers no continuation: a listing is never silently short
            bool complete = page.listingCoverage == Coverage.COMPLETE && page.next.length == 0;
            _add(q, "Content-Type", "application/json");
            _add(q, "x-efs-listing", complete ? "complete" : "partial");
            return (200, _json(page.rows, complete), _headers(q));
        } catch {
            _fail(500, "listing failed");
        }
    }

    // =============================================================================================
    // Facet reads
    // =============================================================================================

    function _words(bytes32 id, uint256 from, uint256 count)
        private
        view
        returns (bytes32[] memory w)
    {
        Status st;
        (st, w) = ILedgerReads(READS).bodyWords(LEDGER, id, uint32(from), uint16(count));
        _ok(st);
        if (w.length != count) _fail(500, "short body");
    }

    function _ok(Status st) private pure {
        if (st == Status.PRESENT) return;
        if (st == Status.UNSUPPORTED || st == Status.LIMIT_EXCEEDED) {
            _fail(503, "read refused by the facet");
        }
        _fail(500, "missing record");
    }

    // =============================================================================================
    // The URL
    // =============================================================================================

    function _parse(string[] calldata resource, KeyValue[] calldata params)
        private
        view
        returns (Req memory q)
    {
        uint256 last = resource.length;
        if (last > 1 && bytes(resource[last - 1]).length == 0) --last; // a trailing slash
        if (last == 0 || bytes(resource[0]).length == 0) _fail(400, "empty segment");
        // the first segment decides the kind: `~` the system, `0x` an address's home, anything else a topic
        bytes calldata s0 = bytes(resource[0]);
        bytes32 first;
        if (s0[0] == "~") {
            // `/~efs/o/<object id>/…` (an object link) and `/~efs/v/<revision id>` (a revision link, nothing after
            // the id); every other system path is unknown
            bytes32 sys =
                last < 2 ? bytes32(0) : keccak256(bytes.concat(s0, "/", bytes(resource[1])));
            if (sys == keccak256("~efs/v")) {
                if (last != 3) _fail(400, "malformed revision link");
                q.revision = true;
            } else if (last < 3 || sys != keccak256("~efs/o")) {
                _fail(400, "unknown system path");
            }
            q.folder = bytes32(_id(bytes(resource[2]), 66));
            q.start = 3;
        } else if (_prefixed(s0)) {
            q.home = bytes32(_id(s0, 42));
            first = Keys.principalFor(
                address(uint160(uint256(q.home))), ILedgerHot(LEDGER).realmOrigin()
            );
            q.start = 1;
        } else {
            _fail(501, "topic paths are not served");
        }
        if (last - q.start > MAX_NAMES) _fail(400, "too many segments");
        for (uint256 i = q.start; i < last; ++i) {
            uint256 n = bytes(resource[i]).length;
            if (n == 0) _fail(400, "empty segment");
            if (n > MAX_NAME_BYTES) _fail(400, "name over 255 bytes");
        }
        q.last = last;
        q.h = new KeyValue[](MAX_HEADERS);
        bytes calldata lens = msg.data[0:0];
        for (uint256 i; i < params.length; ++i) {
            bytes32 key = keccak256(bytes(params[i].key));
            if (key == keccak256("lens")) lens = bytes(params[i].value);
            else if (key == keccak256("offset")) q.offset = _uint(bytes(params[i].value));
        }
        // a revision link has no lens; elsewhere the lens is the `lens` parameter alone when one is given, else the
        // place's default principal (the address's own; a folder's or a file's creator, read in `serve`)
        if (q.revision) lens = msg.data[0:0];
        uint256 k = lens.length != 0 ? 0 : 1;
        uint256 count = k;
        for (uint256 i; i < lens.length; ++i) {
            if (lens[i] == ",") ++count;
        }
        if (lens.length != 0) ++count;
        if (count > MAX_PRINCIPALS) _fail(400, "too many principals");
        q.lens = new bytes32[](count);
        if (k == 1) q.lens[0] = first;
        q.lensParam = lens;
        uint256 from = 0;
        for (uint256 i = 0; i <= lens.length && lens.length != 0; ++i) {
            if (i == lens.length || lens[i] == ",") {
                q.lens[k++] = _principal(lens[from:i]);
                from = i + 1;
            }
        }
    }

    /// A principal id from 64 hex digits (optionally `0x`-prefixed), or the key principal of a `0x` + 40 hex
    /// account (a contract account is refused: its principal is Realm-qualified, name it by id).
    function _principal(bytes calldata s) private view returns (bytes32) {
        uint256 n = s.length;
        if (n == 64) return bytes32(_hexValue(s));
        if (n != 66 && n != 42) _fail(400, "malformed principal");
        uint256 v = _id(s, n);
        if (n == 66) return bytes32(v);
        address account = address(uint160(v));
        if (Keys.principalFor(account, 0) != Keys.principal(account)) {
            _fail(400, "contract account: use its id");
        }
        return Keys.principal(account);
    }

    /// `0x` + hex of exactly `n` bytes in all (an address 42, a record id 66), else 400 "malformed id".
    function _id(bytes calldata s, uint256 n) private pure returns (uint256) {
        if (s.length != n || !_prefixed(s)) _fail(400, "malformed id");
        return _hexValue(s[2:]);
    }

    /// `0x` or `0X` and at least one more byte.
    function _prefixed(bytes calldata s) private pure returns (bool) {
        return s.length > 2 && s[0] == "0" && (s[1] == "x" || s[1] == "X");
    }

    function _hexValue(bytes calldata s) private pure returns (uint256 v) {
        for (uint256 i; i < s.length; ++i) {
            uint8 c = uint8(s[i]);
            if (c >= 48 && c <= 57) c -= 48;
            else if (c >= 97 && c <= 102) c -= 87;
            else if (c >= 65 && c <= 70) c -= 55;
            else _fail(400, "malformed id");
            v = v << 4 | c;
        }
    }

    function _uint(bytes calldata s) private pure returns (uint256 v) {
        if (s.length == 0 || s.length > 20) _fail(400, "malformed offset");
        for (uint256 i; i < s.length; ++i) {
            uint8 c = uint8(s[i]);
            if (c < 48 || c > 57) _fail(400, "malformed offset");
            v = v * 10 + (c - 48);
        }
        if (v > type(uint64).max) _fail(400, "malformed offset");
    }

    /// The request's own path `?offset=<next>[&lens=<lens>]`, every segment byte outside RFC 3986 unreserved escaped.
    function _nextUrl(Req memory q, string[] calldata resource, uint256 next)
        private
        pure
        returns (string memory)
    {
        bytes memory u = bytes.concat("/", bytes(resource[0]));
        for (uint256 i = 1; i < q.last; ++i) {
            u = bytes.concat(u, "/", _escapeUrl(bytes(resource[i])));
        }
        u = bytes.concat(u, "?offset=", bytes(_dec(next)));
        if (q.lensParam.length != 0) u = bytes.concat(u, "&lens=", q.lensParam);
        return string(u);
    }

    function _escapeUrl(bytes calldata s) private pure returns (bytes memory out) {
        uint256 n = s.length;
        for (uint256 i; i < s.length; ++i) {
            if (!_unreserved(s[i])) n += 2;
        }
        out = new bytes(n);
        uint256 k = 0;
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (_unreserved(c)) {
                out[k++] = c;
            } else {
                out[k++] = "%";
                out[k++] = UPPER_HEX[uint8(c) >> 4];
                out[k++] = UPPER_HEX[uint8(c) & 15];
            }
        }
    }

    function _unreserved(bytes1 c) private pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
            || c == "-" || c == "." || c == "_" || c == "~";
    }

    // =============================================================================================
    // The response
    // =============================================================================================

    function _fail(uint16 status, string memory reason) private pure {
        revert E_WEB3_STATUS(status, reason);
    }

    function _add(Req memory q, string memory key, string memory value) private pure {
        q.h[q.n++] = KeyValue(key, value);
    }

    function _headers(Req memory q) private pure returns (KeyValue[] memory h) {
        h = q.h;
        uint256 n = q.n;
        assembly ("memory-safe") {
            mstore(h, n)
        }
    }

    /// `{"entries":[{"name":"…","kind":"file"|"directory"},…],"complete":true|false}` over the ENTRY rows.
    function _json(IFilesPageReader.Row[] memory rows, bool complete)
        private
        pure
        returns (bytes memory out)
    {
        out = '{"entries":[';
        bool first = true;
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].rowKind != ROW_ENTRY) continue;
            out = bytes.concat(
                out,
                first ? bytes('{"name":"') : bytes(',{"name":"'),
                _escapeJson(rows[i].name),
                rows[i].targetKind == TARGET_RECORD
                    ? bytes('","kind":"directory"}')
                    : bytes('","kind":"file"}')
            );
            first = false;
        }
        out = bytes.concat(
            out, complete ? bytes('],"complete":true}') : bytes('],"complete":false}')
        );
    }

    /// JSON string contents: `"` and `\` escaped, control bytes as `\u00XX`, every other byte as is (UTF-8).
    function _escapeJson(bytes memory s) private pure returns (bytes memory out) {
        uint256 n = s.length;
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c == '"' || c == "\\") n += 1;
            else if (uint8(c) < 0x20) n += 5;
        }
        out = new bytes(n);
        uint256 k;
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c == '"' || c == "\\") {
                out[k++] = "\\";
            } else if (uint8(c) < 0x20) {
                out[k++] = "\\";
                out[k++] = "u";
                out[k++] = "0";
                out[k++] = "0";
                out[k++] = HEX[uint8(c) >> 4];
                c = HEX[uint8(c) & 15];
            }
            out[k++] = c;
        }
    }

    // ---- small codecs ---------------------------------------------------------------------------------------

    /// `b[from:from + n]` (the caller keeps it inside `b`).
    function _cut(bytes memory b, uint256 from, uint256 n) private pure returns (bytes memory out) {
        out = new bytes(n);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(b, 32), from), n)
        }
    }

    function _dec(uint256 v) private pure returns (string memory) {
        uint256 n = 1;
        for (uint256 x = v; x >= 10; x /= 10) {
            ++n;
        }
        bytes memory b = new bytes(n);
        for (; n != 0; v /= 10) {
            b[--n] = bytes1(uint8(48 + v % 10));
        }
        return string(b);
    }

    function _hex(bytes32 v) private pure returns (string memory) {
        bytes memory b = new bytes(66);
        b[0] = "0";
        b[1] = "x";
        for (uint256 i; i < 32; ++i) {
            b[2 + 2 * i] = HEX[uint8(v[i]) >> 4];
            b[3 + 2 * i] = HEX[uint8(v[i]) & 15];
        }
        return string(b);
    }
}

// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(missing-zero-check)
// forge-lint: disable-end(unused-return)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
