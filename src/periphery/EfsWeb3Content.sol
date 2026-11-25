// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {Status} from "../interfaces/Results.sol";
import {KeyValue} from "../interfaces/IWeb3Gateway.sol";
import {IWeb3Content} from "../interfaces/IWeb3Content.sol";

/// The inner frame's answer for anything other than a served response: `EfsWeb3Gateway.request` returns it as
/// `(status, reason)` with a `text/plain` body. Never escapes `request`.
error E_WEB3_STATUS(uint16 status, string reason); // none
/// Constructor only: 1 a zero ledger, facet or content server, 2 a page reader bound to another ledger, 3 a content
/// server bound to another ledger.
error E_WEB3_CONFIG(uint8 code); // none

// Narrowing casts are record offsets and lengths bounded by the record's own 32-bit length, or ASCII bytes; the
// server reads the ledger row by row, so calls in loops are its purpose, bounded by the span tree's depth (each
// level strictly shrinks the length it covers). Ignored tuple components are fields it does not need; `_fail` is the
// one refusal path, loops included.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(unused-return)
// forge-lint: disable-start(require-revert-in-loop)

/// @title EfsWeb3Content/1 — the content half of `EfsWeb3Gateway` (docs/LARGE-FILES.md "`web3://`")
/// @notice Immutable and stateless, outside the execution set. Bound at construction to one ledger, its
///         `LedgerReads` facet (bodies) and the Files Type ids it interprets. Facts come from the Etched hot getters
///         (`recordHeader`, `subjectCreatedAt`, `layoutId`), bodies from `LedgerReads.bodySlice` / `bodyWords`; it
///         never reads raw slots, never consults the index and never resolves a name or a lens.
///
///         `serveRevision(revision, file, name, offset)`: `revision` must be a `files-root/1` / `files-child/1`
///         record. With `file` nonzero (a HEAD the gateway selected) its file word must be `file`, the reader-side
///         HEAD law: a breach is a 500 with its own body. With `file` zero (a revision link) any revision record is
///         served, whosever HEAD it is or was; an existing record of another Type or a created subject is 501
///         "object not served", an id that names nothing 404. Form 0: the inline bytes. Form 1 naming
///         `files-content/1`: carrier 0 or 2, the chunk holding byte `offset` (found by descending the span tree
///         by its lengths, O(depth) record reads), served from `offset` to the chunk's end, with `next` the offset
///         after it unless it reaches the end; carrier 1 (remote sentinel) is 404. Form 1 naming `files-external/1`:
///         307 with `Location: <locator>` (and `x-efs-media-type` when the location declares one).
///
///         Headers: `Content-Type` first (a `files-content/1` descriptor's declared media type when it has one, else
///         by `name`'s extension, `application/octet-stream` without one), `X-Content-Type-Options: nosniff` (only
///         with a declared media type), `Content-Length` (the whole file's length), `x-efs-record` (the revision
///         record), `x-efs-sha256` (a descriptor's digest), `x-efs-cipher` (a nonzero cipher word),
///         `x-efs-media-type` (on a location's 307). A descriptor shorter than its words, or a location whose
///         locator length is 0 or runs past the body, is a 500; a ledger of another layout or a read the facet
///         refuses is a 503.
/// @dev Sound as a separate contract: it holds no state and has no owner, it is reached at an immutable address
///      whose codehash the gateway records, and it contains no SELFDESTRUCT, CREATE or DELEGATECALL, so its code can
///      never change; every input is one a URL can name, so a direct call serves nothing the gateway would not.
contract EfsWeb3Content is IWeb3Content {
    /// The Files Type ids the server interprets (`FilesTypes.typeIdOf` of the release descriptors).
    struct Types {
        bytes32 root;
        bytes32 child;
        bytes32 content;
        bytes32 external_;
        bytes32 bytes_;
        bytes32 span;
    }

    uint16 public constant FACET_VERSION = 1;

    uint256 private constant CARRIER_REMOTE = 1;
    uint256 private constant CARRIER_SPAN = 2;
    uint256 private constant MAX_HEADERS = 7;
    bytes16 private constant HEX = "0123456789abcdef";
    string private constant TEXT = "text/plain; charset=utf-8";

    address private immutable LEDGER;
    address public immutable READS;
    bytes32 private immutable LAYOUT;
    bytes32 public immutable ROOT_TYPE;
    bytes32 public immutable CHILD_TYPE;
    bytes32 public immutable CONTENT_TYPE;
    bytes32 public immutable EXTERNAL_TYPE;
    bytes32 public immutable BYTES_TYPE;
    bytes32 public immutable SPAN_TYPE;

    /// One response's headers.
    struct Out {
        KeyValue[] h;
        uint256 n;
    }

    constructor(address ledger_, address reads_, Types memory t) {
        if (ledger_ == address(0) || reads_ == address(0)) revert E_WEB3_CONFIG(1);
        LEDGER = ledger_;
        READS = reads_;
        LAYOUT = ILedgerHot(ledger_).layoutId();
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

    /// @inheritdoc IWeb3Content
    function ledger() external view returns (address) {
        return LEDGER;
    }

    /// The layout read from the ledger at construction; a ledger reporting another layout is served 503.
    function layoutId() external view returns (bytes32) {
        return LAYOUT;
    }

    /// @inheritdoc IWeb3Content
    function serveRevision(bytes32 revision, bytes32 file, bytes calldata name, uint256 offset)
        external
        view
        returns (uint16, bytes memory, KeyValue[] memory, uint256)
    {
        if (ILedgerHot(LEDGER).layoutId() != LAYOUT) _fail(503, "foreign ledger layout");
        (bytes32 typeId,, uint32 length,,) = ILedgerHot(LEDGER).recordHeader(revision);
        if (typeId != ROOT_TYPE && typeId != CHILD_TYPE) {
            if (file != 0) _fail(500, "HEAD law: target not a revision");
            // a revision link to something that exists but is not a revision (every record has a nonzero Type; a
            // created subject such as a file) is never absent: only an id that names nothing is 404
            if (typeId == 0 && ILedgerHot(LEDGER).subjectCreatedAt(revision) == 0) {
                _fail(404, "not found");
            }
            _fail(501, "object not served");
        }
        uint256 base = typeId == ROOT_TYPE ? 0 : 32; // the file word: root word 0, child word 1
        if (length < base + 64) {
            _fail(500, file != 0 ? "HEAD law: short revision" : "short revision");
        }
        bytes memory body = _slice(revision, 0, length);
        if (file != 0 && _word(body, base) != file) _fail(500, "HEAD law: revision of other file");
        Out memory o = Out(new KeyValue[](MAX_HEADERS), 0);
        _add(o, "Content-Type", _contentType(name));
        _add(o, "x-efs-record", _hex(revision));
        uint256 form = uint256(_word(body, base + 32));
        if (form == 0) {
            uint256 size = length - base - 64;
            _range(offset, size);
            _add(o, "Content-Length", _dec(size));
            return (200, _tail(body, base + 64 + offset), _headers(o), 0);
        }
        if (form != 1 || length != base + 96) _fail(500, "unknown revision form");
        return _descriptor(o, _word(body, base + 64), offset);
    }

    // =============================================================================================
    // Descriptors
    // =============================================================================================

    function _descriptor(Out memory o, bytes32 d, uint256 offset)
        private
        view
        returns (uint16, bytes memory, KeyValue[] memory, uint256)
    {
        (bytes32 typeId,, uint32 length,,) = ILedgerHot(LEDGER).recordHeader(d);
        if (typeId == EXTERNAL_TYPE) {
            // [sentinel, 2, 2, 1, length, sha256, locatorLength] ‖ locator ‖ media (the rest of the body)
            if (length <= 224) _fail(500, "malformed location");
            bytes memory b = _slice(d, 0, length);
            uint256 locator = uint256(_word(b, 192));
            if (locator == 0 || locator > length - 224) _fail(500, "malformed location");
            _add(o, "x-efs-sha256", _hex(_word(b, 160)));
            _add(o, "Location", string(_cut(b, 224, locator)));
            if (224 + locator < length) {
                _add(o, "x-efs-media-type", string(_tail(b, 224 + locator)));
            }
            return (307, "", _headers(o), 0);
        }
        if (typeId != CONTENT_TYPE || length < 320) _fail(500, "revision names no descriptor");
        // [bytesRef, version, carrier, hashAlg, length, sha256, cipher, …] ‖ media (the rest of the body)
        bytes32[] memory w = _words(d, 0, 7);
        uint256 carrier = uint256(w[2]);
        uint256 size = uint256(w[4]);
        if (carrier == CARRIER_REMOTE) _fail(404, "not found: remote-only content");
        if (carrier > CARRIER_SPAN) _fail(500, "unknown carrier");
        _range(offset, size);
        if (length > 320) {
            // the declared media type replaces the extension's guess (Content-Type is always header 0)
            o.h[0].value = string(_slice(d, 320, length - 320));
            _add(o, "X-Content-Type-Options", "nosniff");
        }
        _add(o, "Content-Length", _dec(size));
        _add(o, "x-efs-sha256", _hex(w[5]));
        if (w[6] != 0) _add(o, "x-efs-cipher", _dec(uint256(w[6])));
        bytes memory chunk = _chunk(w[0], carrier == CARRIER_SPAN, size, offset);
        uint256 next = offset + chunk.length;
        return (200, chunk, _headers(o), next < size ? next : 0);
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
    // The response
    // =============================================================================================

    function _fail(uint16 status, string memory reason) private pure {
        revert E_WEB3_STATUS(status, reason);
    }

    /// 416 unless `offset` is inside `[0, size)`; offset 0 of an empty file is served (an empty body).
    function _range(uint256 offset, uint256 size) private pure {
        if (offset != 0 && offset >= size) _fail(416, "offset out of range");
    }

    function _add(Out memory o, string memory key, string memory value) private pure {
        o.h[o.n++] = KeyValue(key, value);
    }

    function _headers(Out memory o) private pure returns (KeyValue[] memory h) {
        h = o.h;
        uint256 n = o.n;
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
        if (dot == 0) return "application/octet-stream"; // no name, no dot, or only a leading one
        uint256 n = name.length - dot - 1;
        if (n == 0 || n > 4) return "application/octet-stream";
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
// forge-lint: disable-end(unused-return)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
