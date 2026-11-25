// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";
import {Purpose} from "../interfaces/Actions.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {IFilesPageReader, IReader} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {IWeb3Gateway, KeyValue} from "../interfaces/IWeb3Gateway.sol";

/// The inner frame's answer for anything other than a served response: `request` returns it as
/// `(status, reason)` with a `text/plain` body. Never escapes `request`.
error E_WEB3_STATUS(uint16 status, string reason); // none
/// Constructor only: 1 a zero ledger or facet, 2 a page reader bound to another ledger.
error E_WEB3_CONFIG(uint8 code); // none

// Narrowing casts are record offsets and lengths bounded by the record's own 32-bit length, or ASCII bytes; the
// gateway reads the ledger row by row, so calls in loops are its purpose, bounded by the path depth, the lens
// length and the span tree's depth (each level strictly shrinks the length it covers). Ignored tuple components are
// fields the gateway does not need; a zero page reader is the documented "no listings" configuration; `_fail` is the
// one refusal path, loops included.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(unused-return)
// forge-lint: disable-start(missing-zero-check)
// forge-lint: disable-start(require-revert-in-loop)

/// @title EfsWeb3Gateway/1 — EFS content over `web3://` (docs/LARGE-FILES.md "`web3://`")
/// @notice ERC-5219 resource-request mode (`resolveMode() == "5219"`) with ERC-7617 chunked bodies. Immutable and
///         stateless, outside the execution set, so it can be added, fixed and replaced after a freeze. Bound at
///         construction to one ledger, its `LedgerReads` facet (bodies), its `LedgerViews` facet (held for parity
///         with the other readers; this version needs no composite read), an optional `FilesPageReader` (zero: no
///         listings), the Realm's root `files-directory/1` record and the Files Type ids it interprets. Facts come
///         from the Etched hot getters (`head`, `recordHeader`, `layoutId`), bodies from `LedgerReads.bodySlice` /
///         `bodyWords`; it never reads raw slots and never consults the index for a file read.
///
///         URL grammar: `/<principal>[/<name>…][/][?lens=<principal>,<principal>…][&offset=<n>]`.
///         `<principal>`: 64 hex digits (a principal id), `0x` + 64 hex digits (the same), or `0x` + 40 hex digits
///         (an account; accepted only when `Keys.principalFor` makes it a key principal — no code, or exactly an
///         EIP-7702 designator — and then the left-padded address; a contract account is 400, use its id). Hex is
///         case-insensitive, no checksum. `lens` appends fall-through principals after the path principal (at most
///         64 in all). `offset` (decimal, < 2^64, default 0) is the first byte served. Other parameters are ignored;
///         a repeated parameter's last value wins. A trailing empty segment (a trailing slash) is dropped; any other
///         empty segment is 400. At most 32 names, each 1..255 bytes.
///
///         Resolution: each name is one FOLDER position `(FOLDER, directoryRecord, keccak256(name))`, read for each
///         principal in order through `ILedgerHot.head(Keys.binding(principal, position))`: the first BOUND head
///         wins, a MASKED head stops (mask beats fall-through), UNSET and RELEASED fall through. A directory target
///         continues the walk; a file subject must be the last name. A file's HEAD `(HEAD, file, 0)` is resolved the
///         same way and must name a `files-root/1` / `files-child/1` record whose file word is that file (the
///         reader-side HEAD law). Form 0: the inline bytes. Form 1 naming `files-content/1`: carrier 0 or 2, the
///         chunk holding byte `offset` (found by descending the span tree by its lengths, O(depth) record reads),
///         served from `offset` to the chunk's end, with `web3-next-chunk: /<path>?offset=<next>[&lens=…]` unless it
///         reaches the end; carrier 1 (remote sentinel) is 404. Form 1 naming `files-external/1`: 307 with
///         `Location: <locator>` (and `x-efs-media-type` when the location declares one). A directory: with a page reader, 200 `application/json`
///         `{"entries":[{"name":…,"kind":"file"|"directory"}…],"complete":bool}` from one page of at most
///         `LISTING_LIMIT` rows and `x-efs-listing: complete|partial`; without one, 200 `directory`.
///
///         Headers: `Content-Type` (a `files-content/1` descriptor's declared media type when it has one, else by
///         the final name's extension; listings JSON; refusals text), `X-Content-Type-Options: nosniff` (only with
///         a declared media type, so a browser cannot upgrade an author's `text/plain` to HTML; the extension path
///         sends none), `Content-Length` (the whole file's length), `x-efs-record` (the revision record, or the
///         directory record), `x-efs-sha256` (a descriptor's digest: the author's claim for carrier 2 and external
///         locations, verify after reading), `x-efs-cipher` (a nonzero cipher word: the stored ciphertext is
///         served), `x-efs-media-type` (a `files-external/1` location's declared media type, on the 307, so a
///         client that does not follow the redirect still learns it). A media type is the rest of a descriptor's
///         body; a descriptor shorter than its words, or a location whose locator length is 0 or runs past the
///         body, is a 500.
///
///         Statuses (never a revert for anything a URL can cause): 200 served; 307 external location; 400 malformed
///         URL; 404 not found, removed (masked), file used as a folder, or remote-only content; 416 `offset` at or
///         past the end (except 0 on an empty file); 500 a broken invariant (a Type, length or record the Files
///         laws guarantee is wrong or missing, a failed listing); 503 a ledger layout or head state this gateway was
///         not built for, or a read the facet refuses (UNSUPPORTED, LIMIT_EXCEEDED).
/// @dev `request` calls `serve` on itself by STATICCALL; every refusal inside is `E_WEB3_STATUS(status, reason)` and
///      any other failure of the inner frame (a dependency revert, out of gas) is a 500, so `request` itself only
///      fails when the outer frame cannot encode its answer.
contract EfsWeb3Gateway is IWeb3Gateway {
    /// The Files Type ids the gateway interprets (`FilesTypes.typeIdOf` of the release descriptors).
    struct Types {
        bytes32 directory;
        bytes32 name;
        bytes32 root;
        bytes32 child;
        bytes32 content;
        bytes32 external_;
        bytes32 bytes_;
        bytes32 span;
    }

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
    uint256 private constant CARRIER_REMOTE = 1;
    uint256 private constant CARRIER_SPAN = 2;
    uint256 private constant MAX_HEADERS = 8;
    bytes16 private constant HEX = "0123456789abcdef";
    bytes16 private constant UPPER_HEX = "0123456789ABCDEF";
    string private constant TEXT = "text/plain; charset=utf-8";

    address private immutable LEDGER;
    address public immutable READS;
    address public immutable VIEWS;
    address public immutable PAGER;
    bytes32 private immutable LAYOUT;
    bytes32 public immutable ROOT_DIRECTORY;
    bytes32 public immutable DIRECTORY_TYPE;
    bytes32 public immutable NAME_TYPE;
    bytes32 public immutable ROOT_TYPE;
    bytes32 public immutable CHILD_TYPE;
    bytes32 public immutable CONTENT_TYPE;
    bytes32 public immutable EXTERNAL_TYPE;
    bytes32 public immutable BYTES_TYPE;
    bytes32 public immutable SPAN_TYPE;

    /// One request's working state.
    struct Req {
        bytes32[] lens;
        uint256 offset;
        bytes lensParam;
        uint256 last;
        KeyValue[] h;
        uint256 n;
    }

    /// @param pager_ a `FilesPageReader` bound to `ledger_`, or zero for no listings
    /// @param rootDirectory_ the Realm root's `files-directory/1` record id (the `/<principal>/` directory)
    constructor(
        address ledger_,
        address reads_,
        address views_,
        address pager_,
        bytes32 rootDirectory_,
        Types memory t
    ) {
        if (ledger_ == address(0) || reads_ == address(0) || views_ == address(0)) {
            revert E_WEB3_CONFIG(1);
        }
        if (pager_ != address(0) && IReader(pager_).ledger() != ledger_) revert E_WEB3_CONFIG(2);
        LEDGER = ledger_;
        READS = reads_;
        VIEWS = views_;
        PAGER = pager_;
        LAYOUT = ILedgerHot(ledger_).layoutId();
        ROOT_DIRECTORY = rootDirectory_;
        DIRECTORY_TYPE = t.directory;
        NAME_TYPE = t.name;
        ROOT_TYPE = t.root;
        CHILD_TYPE = t.child;
        CONTENT_TYPE = t.content;
        EXTERNAL_TYPE = t.external_;
        BYTES_TYPE = t.bytes_;
        SPAN_TYPE = t.span;
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
        bytes32 dir = ROOT_DIRECTORY;
        for (uint256 i = 1; i < q.last; ++i) {
            (uint8 state, uint8 kind, bytes32 target) =
                _select(q.lens, Keys.position(Purpose.FOLDER, dir, keccak256(bytes(resource[i]))));
            if (state == MASKED) _fail(404, "not found: removed");
            if (state != BOUND) _fail(404, "not found");
            if (kind == TARGET_SUBJECT) {
                if (i + 1 != q.last) _fail(404, "not found: a file is not a folder");
                return _file(q, resource, target);
            }
            if (kind != TARGET_RECORD) _fail(500, "folder target of an unknown kind");
            (bytes32 typeId,,,,) = ILedgerHot(LEDGER).recordHeader(target);
            if (typeId != DIRECTORY_TYPE) _fail(500, "folder target is not a directory");
            dir = target;
        }
        return _directory(q, dir);
    }

    // =============================================================================================
    // Files
    // =============================================================================================

    /// The lens selection at `position`: (BOUND, kind, target), (MASKED, 0, 0) or (0, 0, 0) when every principal
    /// is UNSET or RELEASED. A reserved head state is 503 (it never falls through).
    function _select(bytes32[] memory lens, bytes32 position)
        private
        view
        returns (uint8, uint8, bytes32)
    {
        for (uint256 i; i < lens.length; ++i) {
            (uint8 state,,, uint8 kind,,, bytes32 target) =
                ILedgerHot(LEDGER).head(Keys.binding(lens[i], position));
            if (state == BOUND) return (BOUND, kind, target);
            if (state == MASKED) return (MASKED, 0, 0);
            if (state != RELEASED && state != 0) _fail(503, "unsupported head state");
        }
        return (0, 0, 0);
    }

    function _file(Req memory q, string[] calldata resource, bytes32 file)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        (uint8 state, uint8 kind, bytes32 rev) =
            _select(q.lens, Keys.position(Purpose.HEAD, file, 0));
        if (state != BOUND) _fail(404, "not found: no revision");
        if (kind != TARGET_RECORD) _fail(500, "HEAD law: target is not a record");
        (bytes32 typeId,, uint32 length,,) = ILedgerHot(LEDGER).recordHeader(rev);
        if (typeId != ROOT_TYPE && typeId != CHILD_TYPE) {
            _fail(500, "HEAD law: target is not a revision");
        }
        uint256 base = typeId == ROOT_TYPE ? 0 : 32; // the file word: root word 0, child word 1
        if (length < base + 64) _fail(500, "HEAD law: short revision");
        bytes memory body = _slice(rev, 0, length);
        if (_word(body, base) != file) _fail(500, "HEAD law: revision of another file");
        _add(q, "Content-Type", _contentType(bytes(resource[q.last - 1])));
        _add(q, "x-efs-record", _hex(rev));
        uint256 form = uint256(_word(body, base + 32));
        if (form == 0) {
            uint256 size = length - base - 64;
            _range(q.offset, size);
            _add(q, "Content-Length", _dec(size));
            return (200, _tail(body, base + 64 + q.offset), _headers(q));
        }
        if (form != 1 || length != base + 96) _fail(500, "unknown revision form");
        return _descriptor(q, resource, _word(body, base + 64));
    }

    function _descriptor(Req memory q, string[] calldata resource, bytes32 d)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        (bytes32 typeId,, uint32 length,,) = ILedgerHot(LEDGER).recordHeader(d);
        if (typeId == EXTERNAL_TYPE) {
            // [sentinel, 2, 2, 1, length, sha256, locatorLength] ‖ locator ‖ media (the rest of the body)
            if (length <= 224) _fail(500, "malformed location");
            bytes memory b = _slice(d, 0, length);
            uint256 locator = uint256(_word(b, 192));
            if (locator == 0 || locator > length - 224) _fail(500, "malformed location");
            _add(q, "x-efs-sha256", _hex(_word(b, 160)));
            _add(q, "Location", string(_cut(b, 224, locator)));
            if (224 + locator < length) {
                _add(q, "x-efs-media-type", string(_tail(b, 224 + locator)));
            }
            return (307, "", _headers(q));
        }
        if (typeId != CONTENT_TYPE || length < 320) _fail(500, "revision names no descriptor");
        // [bytesRef, version, carrier, hashAlg, length, sha256, cipher, …] ‖ media (the rest of the body)
        bytes32[] memory w = _words(d, 0, 7);
        uint256 carrier = uint256(w[2]);
        uint256 size = uint256(w[4]);
        if (carrier == CARRIER_REMOTE) _fail(404, "not found: remote-only content");
        if (carrier > CARRIER_SPAN) _fail(500, "unknown carrier");
        _range(q.offset, size);
        if (length > 320) {
            // the declared media type replaces the extension's guess (Content-Type is always header 0)
            q.h[0].value = string(_slice(d, 320, length - 320));
            _add(q, "X-Content-Type-Options", "nosniff");
        }
        _add(q, "Content-Length", _dec(size));
        _add(q, "x-efs-sha256", _hex(w[5]));
        if (w[6] != 0) _add(q, "x-efs-cipher", _dec(uint256(w[6])));
        bytes memory chunk = _chunk(w[0], carrier == CARRIER_SPAN, size, q.offset);
        uint256 next = q.offset + chunk.length;
        if (next < size) _add(q, "web3-next-chunk", _nextUrl(q, resource, next));
        return (200, chunk, _headers(q));
    }

    /// The bytes from `offset` to the end of the chunk that holds it, under the tree `node` of `size` bytes: a
    /// `files-bytes/1` chunk (carrier 0) or a `files-span/1` root (carrier 2), descended by the left child's
    /// length. Every node's Type and length is checked against what its parent says it covers.
    function _chunk(bytes32 node, bool span, uint256 size, uint256 offset)
        private
        view
        returns (bytes memory chunk)
    {
        for (bool top = true;; top = false) {
            (bytes32 t,, uint32 len,,) = ILedgerHot(LEDGER).recordHeader(node);
            if (t == BYTES_TYPE && !(top && span)) {
                if (len < 32 || len - 32 != size) _fail(500, "tree: chunk length");
                return _slice(node, 32 + offset, size - offset);
            }
            if (t != SPAN_TYPE || len != 96 || (top && !span)) _fail(500, "tree: missing node");
            bytes32[] memory w = _words(node, 0, 3); // [left, right, length]
            if (uint256(w[2]) != size) _fail(500, "tree: span length");
            uint256 left = _length(w[0]);
            if (left == 0 || left >= size) _fail(500, "tree: child length");
            if (offset < left) {
                node = w[0];
                size = left;
            } else {
                node = w[1];
                offset -= left;
                size -= left;
            }
        }
    }

    /// The payload length a tree child covers; 0 when it is neither a chunk nor a span.
    function _length(bytes32 child) private view returns (uint256) {
        (bytes32 t,, uint32 len,,) = ILedgerHot(LEDGER).recordHeader(child);
        if (t == BYTES_TYPE) return len < 32 ? 0 : len - 32;
        if (t == SPAN_TYPE && len == 96) return uint256(_words(child, 2, 1)[0]);
        return 0;
    }

    function _directory(Req memory q, bytes32 dir)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory)
    {
        _add(q, "x-efs-record", _hex(dir));
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

    function _slice(bytes32 id, uint256 offset, uint256 length)
        private
        view
        returns (bytes memory out)
    {
        if (length == 0) return out;
        Status st;
        (st, out) = ILedgerReads(READS).bodySlice(LEDGER, id, uint32(offset), uint32(length));
        _ok(st);
        if (out.length != length) _fail(500, "short body");
    }

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
        if (last == 0) _fail(400, "missing principal");
        if (last - 1 > MAX_NAMES) _fail(400, "too many segments");
        for (uint256 i = 1; i < last; ++i) {
            uint256 n = bytes(resource[i]).length;
            if (n == 0) _fail(400, "empty segment");
            if (n > MAX_NAME_BYTES) _fail(400, "name over 255 bytes");
        }
        q.last = last;
        q.h = new KeyValue[](MAX_HEADERS);
        bytes32 first = _principal(bytes(resource[0]));
        bytes calldata lens = msg.data[0:0];
        for (uint256 i; i < params.length; ++i) {
            bytes32 key = keccak256(bytes(params[i].key));
            if (key == keccak256("lens")) lens = bytes(params[i].value);
            else if (key == keccak256("offset")) q.offset = _uint(bytes(params[i].value));
        }
        uint256 count = 1;
        for (uint256 i; i < lens.length; ++i) {
            if (lens[i] == ",") ++count;
        }
        if (lens.length != 0) ++count;
        if (count > MAX_PRINCIPALS) _fail(400, "too many principals");
        q.lens = new bytes32[](count);
        q.lens[0] = first;
        q.lensParam = lens;
        uint256 from = 0;
        uint256 k = 1;
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
        if ((n != 66 && n != 42) || s[0] != "0" || (s[1] != "x" && s[1] != "X")) {
            _fail(400, "malformed principal");
        }
        uint256 v = _hexValue(s[2:]);
        if (n == 66) return bytes32(v);
        address account = address(uint160(v));
        if (Keys.principalFor(account, 0) != Keys.principal(account)) {
            _fail(400, "contract account: use its principal id");
        }
        return Keys.principal(account);
    }

    function _hexValue(bytes calldata s) private pure returns (uint256 v) {
        for (uint256 i; i < s.length; ++i) {
            uint8 c = uint8(s[i]);
            if (c >= 48 && c <= 57) c -= 48;
            else if (c >= 97 && c <= 102) c -= 87;
            else if (c >= 65 && c <= 70) c -= 55;
            else _fail(400, "malformed principal");
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

    /// `/<principal>/<name>…?offset=<next>[&lens=<lens>]`, every name byte outside RFC 3986 unreserved escaped.
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

    /// 416 unless `offset` is inside `[0, size)`; offset 0 of an empty file is served (an empty body).
    function _range(uint256 offset, uint256 size) private pure {
        if (offset != 0 && offset >= size) _fail(416, "offset out of range");
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

    /// By the final name's extension (after its last `.`, not a leading one), ASCII case-insensitive.
    function _contentType(bytes calldata name) private pure returns (string memory) {
        uint256 dot;
        for (uint256 i = name.length; i > 1;) {
            if (name[--i] == ".") {
                dot = i;
                break;
            }
        }
        uint256 n = name.length - dot - 1;
        if (dot == 0 || n == 0 || n > 4) return "application/octet-stream";
        bytes32 e;
        for (uint256 i; i < n; ++i) {
            bytes1 c = name[dot + 1 + i];
            if (c >= "A" && c <= "Z") c |= 0x20;
            e |= bytes32(c) >> (8 * i);
        }
        if (e == "txt") return TEXT;
        if (e == "html" || e == "htm") return "text/html; charset=utf-8";
        if (e == "css") return "text/css; charset=utf-8";
        if (e == "js") return "text/javascript; charset=utf-8";
        if (e == "json") return "application/json";
        if (e == "svg") return "image/svg+xml";
        if (e == "png") return "image/png";
        if (e == "jpg" || e == "jpeg") return "image/jpeg";
        if (e == "gif") return "image/gif";
        if (e == "webp") return "image/webp";
        if (e == "pdf") return "application/pdf";
        if (e == "wasm") return "application/wasm";
        return "application/octet-stream";
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

    function _word(bytes memory b, uint256 base) private pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 32), base))
        }
    }

    /// `b[from:]` (empty when `from` is at or past the end).
    function _tail(bytes memory b, uint256 from) private pure returns (bytes memory) {
        return from >= b.length ? bytes("") : _cut(b, from, b.length - from);
    }

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
