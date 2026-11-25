// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    Purpose,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage, Status} from "../../src/interfaces/Results.sol";
import {RecordHeader} from "../../src/interfaces/Views.sol";
import {E_REF, E_REJECTED} from "../../src/interfaces/Errors.sol";

/// @notice Large files end to end (docs/LARGE-FILES.md) through the real kernel, registry and index: content found
///         by sha256 (inline and external); a ~40 KB payload cut by the canonical chunker (`efs/chunking/1`,
///         `EfsFiles.chunk`) into 8,160-byte chunks across several publications under the S1 limits, described by
///         `files-content/1` carrier 2 over the span root, named by a `files-root/1` form-1 revision with HEAD and
///         FOLDER binds, then READ BACK by walking the span tree through `LedgerReads.record` and checked against
///         the descriptor's sha256 and length; a deep tree of 64-byte chunks and odd tree shapes; an identical file
///         stored twice creating no record cell; the new laws refused through the kernel. Gas per 8 KB chunk
///         publication and per span node is logged.
contract FilesLargeFilesTest is FilesRecipesBase {
    LedgerReads internal reads;
    uint256 internal constant CHUNK = 8_160;

    function setUp() public override {
        super.setUp();
        reads = new LedgerReads();
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    function _types() internal view returns (EfsFiles.Types memory t) {
        t = EfsFiles.Types({
            root: typeIds[T_ROOT],
            child: typeIds[T_CHILD],
            directory: typeIds[T_DIRECTORY],
            name: typeIds[T_NAME],
            bytes_: typeIds[T_BYTES],
            content: typeIds[T_CONTENT],
            external_: typeIds[T_EXTERNAL],
            alias_: typeIds[T_ALIAS],
            notice: typeIds[T_NOTICE],
            span: typeIds[T_SPAN]
        });
    }

    /// `n` pseudo-random bytes (clean padding).
    function _payload(uint256 n, bytes32 seed) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) {
            bytes32 w = keccak256(abi.encode(seed, i));
            if (n - i < 32) w &= bytes32(~(type(uint256).max >> ((n - i) * 8)));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), i), w)
            }
        }
    }

    /// Execute `a`/`b` as this contract's principal (both expectations bound); returns the gas used.
    function _run(Action[] memory a, bytes[] memory b) internal returns (uint256 used) {
        Native memory c = _ctx(a);
        uint256 before = gasleft();
        r.ledger.execute(a, b, c, "");
        used = before - gasleft();
    }

    /// Split under the Realm's S1 limits (64 actions, 16,384 body bytes) and execute every publication.
    function _publishAll(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 publications)
    {
        uint256[] memory ends = EfsFiles.split(b, 64, 16_384);
        uint256 from;
        for (uint256 i; i < ends.length; ++i) {
            (Action[] memory xa, bytes[] memory xb) = EfsFiles.slice(a, b, from, ends[i]);
            uint256 bytes_;
            for (uint256 j; j < xb.length; ++j) {
                bytes_ += xb[j].length;
            }
            uint256 used = _run(xa, xb);
            emit log_named_uint(
                string.concat(
                    label,
                    " publication ",
                    vm.toString(i),
                    " (",
                    vm.toString(xa.length),
                    " actions, ",
                    vm.toString(bytes_),
                    " body bytes) gas"
                ),
                used
            );
            from = ends[i];
        }
        return ends.length;
    }

    function _records() internal view returns (uint64 records) {
        (, records,,) = r.hot.counts();
    }

    function _copyFrom(bytes memory body, uint256 at) internal pure returns (bytes memory out) {
        out = new bytes(body.length - at);
        for (uint256 i; i < out.length; ++i) {
            out[i] = body[at + i];
        }
    }

    struct Walk {
        uint256 chunks;
        uint256 spans;
        uint256 depth;
    }

    /// Reassemble the bytes under `id` (a chunk or a span) by point reads, verifying each node on the way.
    function _read(bytes32 id) internal view returns (bytes memory out, Walk memory w) {
        (Status st, RecordHeader memory h, bytes memory body,) = reads.record(address(r.ledger), id);
        assertEq(uint8(st), uint8(Status.PRESENT), "every node is present");
        if (h.typeId == typeIds[T_BYTES]) {
            out = _copyFrom(body, 32);
            assertEq(sha256(out), h.word0, "a chunk verifies against its own sha256");
            w.chunks = 1;
            return (out, w);
        }
        assertEq(h.typeId, typeIds[T_SPAN], "a tree node is a chunk or a span");
        (bytes32 left, bytes32 right, uint256 length) =
            abi.decode(body, (bytes32, bytes32, uint256));
        (bytes memory lo, Walk memory wl) = _read(left);
        (bytes memory hi, Walk memory wr) = _read(right);
        assertTrue(lo.length != 0 && hi.length != 0, "no empty chunk inside a tree");
        out = bytes.concat(lo, hi);
        assertEq(out.length, length, "a span's length is its bytes");
        w.chunks = wl.chunks + wr.chunks;
        w.spans = 1 + wl.spans + wr.spans;
        w.depth = 1 + (wl.depth > wr.depth ? wl.depth : wr.depth);
    }

    /// A file's bytes from its HEAD: the revision (form 1) → the descriptor → the tree, checked against the
    /// descriptor's length and sha256 (the author's claim for carrier 2, verified here by the reader).
    function _readFile(bytes32 file) internal view returns (bytes memory out, Walk memory w) {
        (uint8 state,, bytes32 revision) = _head(_key(Purpose.HEAD, file, 0));
        assertEq(state, 1, "HEAD bound");
        (, RecordHeader memory rh, bytes memory rb,) = reads.record(address(r.ledger), revision);
        assertEq(rh.typeId, typeIds[T_ROOT]);
        (bytes32 f, uint256 form, bytes32 descriptor) = abi.decode(rb, (bytes32, uint256, bytes32));
        assertEq(f, file);
        assertEq(form, 1, "form 1 CONTENT");
        (, RecordHeader memory dh, bytes memory db,) = reads.record(address(r.ledger), descriptor);
        assertEq(dh.typeId, typeIds[T_CONTENT]);
        EfsFiles.Content memory c = _decode(db);
        (out, w) = _read(c.bytesRef);
        assertEq(out.length, c.length, "the descriptor's length");
        assertEq(sha256(out), c.sha256Digest, "the descriptor's sha256");
        assertEq(c.carrier, w.spans == 0 ? 0 : 2, "carrier 2 over a span root, 0 over one chunk");
    }

    function _decode(bytes memory d) internal pure returns (EfsFiles.Content memory c) {
        (c.bytesRef, c.version, c.carrier, c.hashAlg, c.length, c.sha256Digest) =
            abi.decode(d, (bytes32, uint256, uint256, uint256, uint256, bytes32));
    }

    /// Store `payload` (chunks, spans, descriptor) and create `name` in the root folder naming it (form 1), in as
    /// few publications as the limits allow. Returns the file subject.
    function _storeFile(
        string memory label,
        bytes memory payload,
        uint256 chunk,
        string memory name
    ) internal returns (bytes32 file, uint256 publications) {
        EfsFiles.Types memory t = _types();
        (Action[] memory a, bytes[] memory b, bytes32 descriptor) =
            EfsFiles.storeContent(t, payload, chunk, "");
        (Action[] memory fa, bytes[] memory fb, bytes32 f,) = EfsFiles.createFileRef(
            t, p, rootDir, keccak256(bytes(name)), bytes(name), descriptor, true
        );
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        publications = _publishAll(label, a, b);
        file = f;
    }

    // ---- content by sha256 -------------------------------------------------------------------------------------

    function test_inline_and_external_content_found_by_sha256() public {
        bytes memory payload = "hello, efs files";
        bytes32 digest = sha256(payload);
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        (a[0], b[0]) = _publish(T_BYTES, EfsFiles.bytesBody(payload));
        bytes32 bytesRec = _id(T_BYTES, b[0]);
        (a[1], b[1]) =
            _publish(T_CONTENT, EfsFiles.contentBody(bytesRec, 0, payload.length, digest, ""));
        bytes32 inlineRec = _id(T_CONTENT, b[1]);
        (a[2], b[2]) = _publish(T_BYTES, EfsFiles.bytesBody(""));
        bytes32 sentinel = _id(T_BYTES, b[2]);
        bytes memory locator = "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        (a[3], b[3]) = _publish(
            T_EXTERNAL, EfsFiles.externalBody(sentinel, payload.length, digest, locator, "")
        );
        bytes32 externalRec = _id(T_EXTERNAL, b[3]);
        _exec("recipe inline bytes + content + sentinel + external", a, b);

        (Coverage cov,,,) = r.g.index.coverageOfDigest(SHA256);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE));
        (cov,,,) =
            r.g.index.coverageOfSpec(FamilyId.wrap(F_DIGEST), TypeId.wrap(typeIds[T_EXTERNAL]), 1);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE), "the second gen-1 digest spec");
        bytes32 value = keccak256(abi.encode(bytes32(uint256(SHA256)), digest));
        (uint64 count,) = _posting(F_DIGEST, 0, value);
        assertEq(count, 2, "found by sha256, inline and external");
        uint64[] memory entries;
        (, entries,) =
            r.g.index.postingSliceOf(FamilyId.wrap(F_DIGEST), TypeId.wrap(0), 0, value, 0, 8);
        (, uint64 inlineAt,,,) = r.hot.recordHeader(inlineRec);
        (, uint64 externalAt,,,) = r.hot.recordHeader(externalRec);
        assertEq(entries.length, 2);
        assertEq(entries[0], inlineAt);
        assertEq(entries[1], externalAt);
        (, count,, entries) = r.g.index.occurrencesOf(inlineRec);
        assertEq(count, 1);
        assertEq(entries[0], inlineAt);
        (count,) = _posting(F_REFERENCE, typeIds[T_CONTENT], bytesRec);
        assertEq(count, 1, "content -> bytes reference");
        // the external locator is retained byte for byte
        (bytes32 t,, uint32 length,,) = r.hot.recordHeader(externalRec);
        assertEq(t, typeIds[T_EXTERNAL]);
        assertEq(length, 224 + locator.length);
    }

    // ---- a large file end to end -------------------------------------------------------------------------------

    function test_large_file_chunked_published_bound_and_read_back() public {
        bytes memory payload = _payload(40_000, "large file");
        (Action[] memory ca,, bytes32 root, bool isSpan) =
            EfsFiles.chunk(typeIds[T_BYTES], typeIds[T_SPAN], payload, CHUNK);
        assertTrue(isSpan);
        assertEq(ca.length, 9, "5 chunks and 4 span nodes");
        uint64 before = _records();
        (bytes32 file, uint256 publications) = _storeFile("large 40 KB", payload, CHUNK, "big.bin");
        assertEq(publications, 3, "two 8 KB chunks per publication, the rest with the last chunk");
        // 5 chunks + 4 spans + descriptor + revision + name
        assertEq(_records() - before, 12, "one cell per distinct record");
        // the HEAD and FOLDER binds landed
        (uint8 state,, bytes32 target) = _head(_key(Purpose.FOLDER, rootDir, keccak256("big.bin")));
        assertEq(state, 1);
        assertEq(target, file);
        _assertScope(rootDir, 1, 1, 1);
        // read it back: HEAD → revision → descriptor → span tree, reassembled and verified
        (bytes memory got, Walk memory w) = _readFile(file);
        assertEq(keccak256(got), keccak256(payload), "the bytes round-trip");
        assertEq(w.chunks, 5);
        assertEq(w.spans, 4);
        assertEq(w.depth, 3, "span(span(span(c0,c1), span(c2,c3)), c4)");
        // the descriptor is found by its sha256 through the digest family
        (uint64 count,) =
            _posting(F_DIGEST, 0, keccak256(abi.encode(bytes32(uint256(SHA256)), sha256(payload))));
        assertEq(count, 1);
        (count,) = _posting(F_REFERENCE, typeIds[T_CONTENT], root);
        assertEq(count, 1, "content -> span root reference");
    }

    function test_deep_tree_of_tiny_chunks_round_trips() public {
        bytes memory payload = _payload(5_000, "deep");
        (bytes32 file, uint256 publications) = _storeFile("deep 64 B", payload, 64, "deep.bin");
        (bytes memory got, Walk memory w) = _readFile(file);
        assertEq(keccak256(got), keccak256(payload));
        assertEq(w.chunks, 79, "78 full chunks and an 8-byte tail");
        assertEq(w.spans, 78);
        assertEq(w.depth, 7, "ceil(log2 79)");
        assertEq(publications, 3, "163 actions in 64-action publications");
    }

    function test_odd_shapes_round_trip() public {
        uint16[12] memory sizes = [0, 1, 64, 65, 128, 129, 192, 193, 320, 448, 449, 575];
        for (uint256 i; i < sizes.length; ++i) {
            bytes memory payload = _payload(sizes[i], bytes32(i));
            string memory name = string.concat("odd-", vm.toString(i));
            (bytes32 file,) = _storeFile(name, payload, 64, name);
            (bytes memory got, Walk memory w) = _readFile(file);
            assertEq(keccak256(got), keccak256(payload), name);
            uint256 n = sizes[i] == 0 ? 1 : (uint256(sizes[i]) + 63) / 64;
            assertEq(w.chunks, n);
            assertEq(w.spans, n - 1);
        }
    }

    function test_repeated_chunks_are_one_record() public {
        // five identical chunks: the tree span(span(span(c,c), span(c,c)), c) holds four distinct records
        bytes memory payload = new bytes(320);
        uint64 before = _records();
        (bytes32 file,) = _storeFile("repeated", payload, 64, "zeros.bin");
        // c, span(c,c), span(s,s), span(ss,c), the descriptor, the revision, the name
        assertEq(_records() - before, 7);
        (bytes memory got, Walk memory w) = _readFile(file);
        assertEq(keccak256(got), keccak256(payload));
        assertEq(w.chunks, 5);
        bytes32 zeros = Keys.record(typeIds[T_BYTES], EfsFiles.bytesBody(new bytes(64)));
        (,,, uint64 occurrences,) = r.hot.recordHeader(zeros);
        assertEq(occurrences, 5, "one cell, five occurrences");
    }

    function test_identical_file_twice_creates_no_record_cell() public {
        EfsFiles.Types memory t = _types();
        bytes memory payload = _payload(20_000, "twice");
        (Action[] memory a, bytes[] memory b, bytes32 descriptor) =
            EfsFiles.storeContent(t, payload, CHUNK, "");
        uint64 r0 = _records();
        _publishAll("store once", a, b);
        assertEq(_records() - r0, 6, "3 chunks, 2 spans, the descriptor");
        // the same publications again: every PUBLISH is an already-admitted record (a new occurrence, no cell)
        (uint64 admissions0,,,) = r.hot.counts();
        _publishAll("store again (PUBLISH of existing records)", a, b);
        assertEq(_records() - r0, 6, "no new record cell");
        (uint64 admissions1,,,) = r.hot.counts();
        assertEq(admissions1 - admissions0, 6, "six new occurrences");
        // REUSE by id: no bodies at all, one publication
        Action[] memory reuse = new Action[](a.length);
        bytes[] memory none = new bytes[](a.length);
        for (uint256 i; i < a.length; ++i) {
            reuse[i].kind = ActionKind.REUSE;
            reuse[i].typeId = a[i].typeId;
            reuse[i].bodyHashOrRecordId = Keys.recordFromHash(a[i].typeId, a[i].bodyHashOrRecordId);
        }
        emit log_named_uint(
            "store a third time by REUSE (6 actions, 0 body bytes) gas", _run(reuse, none)
        );
        assertEq(_records() - r0, 6, "REUSE creates no record cell");
        (,,, uint64 occurrences,) = r.hot.recordHeader(descriptor);
        assertEq(occurrences, 3);
        // two files naming the one descriptor: each adds only its own revision and name
        (Action[] memory fa, bytes[] memory fb, bytes32 f1,) =
            EfsFiles.createFileRef(t, p, rootDir, "one", "one.bin", descriptor, true);
        _run(fa, fb);
        (fa, fb,,) = EfsFiles.createFileRef(t, p, rootDir, "two", "two.bin", descriptor, true);
        _run(fa, fb);
        assertEq(_records() - r0, 10);
        (bytes memory got,) = _readFile(f1);
        assertEq(keccak256(got), keccak256(payload));
    }

    function test_gas_per_8kb_chunk_and_per_span_node() public {
        bytes memory payload = _payload(4 * CHUNK, "gas");
        (Action[] memory a, bytes[] memory b,,) =
            EfsFiles.chunk(typeIds[T_BYTES], typeIds[T_SPAN], payload, CHUNK);
        assertEq(a.length, 7, "c0 c1 c2 c3, s01 s23 root");
        uint256 one;
        uint256 two;
        {
            (Action[] memory xa, bytes[] memory xb) = EfsFiles.slice(a, b, 0, 1);
            one = _run(xa, xb);
            (xa, xb) = EfsFiles.slice(a, b, 1, 3);
            two = _run(xa, xb);
        }
        emit log_named_uint("8 KB chunk: one-chunk publication gas", one);
        emit log_named_uint("8 KB chunks: two-chunk publication gas", two);
        emit log_named_uint("8 KB chunk: marginal gas per chunk", two - one);
        emit log_named_uint("8 KB chunk: gas per chunk in a two-chunk publication", two / 2);
        (Action[] memory ya, bytes[] memory yb) = EfsFiles.slice(a, b, 3, 4);
        _run(ya, yb);
        (ya, yb) = EfsFiles.slice(a, b, 4, 5);
        uint256 span1 = _run(ya, yb);
        (ya, yb) = EfsFiles.slice(a, b, 5, 7);
        uint256 span2 = _run(ya, yb);
        emit log_named_uint("span node: one-span publication gas", span1);
        emit log_named_uint("span nodes: two-span publication gas", span2);
        emit log_named_uint("span node: marginal gas per span", span2 - span1);
    }

    // ---- the new laws through the kernel -----------------------------------------------------------------------

    function _refused(Action[] memory a, bytes[] memory b, bytes memory err) internal {
        Native memory c = _ctx(a);
        uint64 before = _records();
        vm.expectRevert(err);
        r.ledger.execute(a, b, c, "");
        assertEq(_records(), before, "nothing landed");
    }

    function test_large_file_laws_through_the_kernel() public {
        bytes memory payload = _payload(100, "laws");
        (Action[] memory a, bytes[] memory b, bytes32 root,) =
            EfsFiles.chunk(typeIds[T_BYTES], typeIds[T_SPAN], payload, 64);
        _run(a, b); // c0, c1, span
        bytes32 c0 = Keys.record(typeIds[T_BYTES], b[0]);
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        // carrier 2 with a wrong root length
        (x[0], y[0]) = _publish(T_CONTENT, EfsFiles.contentBody(root, 2, 101, sha256(payload), ""));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_CONTENT]));
        // carrier 2 over a chunk, carrier 0 over a span
        (x[0], y[0]) = _publish(T_CONTENT, EfsFiles.contentBody(c0, 2, 64, sha256(payload), ""));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_CONTENT]));
        (x[0], y[0]) = _publish(T_CONTENT, EfsFiles.contentBody(root, 0, 100, sha256(payload), ""));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_CONTENT]));
        // a span over the empty sentinel, a span of a wrong length, a span over a third Type, a missing child
        (x[0], y[0]) = _publish(T_BYTES, EfsFiles.bytesBody(""));
        _run(x, y);
        bytes32 sentinel = Keys.record(typeIds[T_BYTES], y[0]);
        (x[0], y[0]) = _publish(T_SPAN, EfsFiles.spanBody(sentinel, c0, 64));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_SPAN]));
        (x[0], y[0]) = _publish(T_SPAN, EfsFiles.spanBody(c0, c0, 127));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_SPAN]));
        (x[0], y[0]) = _publish(T_SPAN, EfsFiles.spanBody(rootDir, c0, 96));
        _refused(x, y, abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_SPAN]));
        (x[0], y[0]) = _publish(T_SPAN, EfsFiles.spanBody(c0, keccak256("missing"), 128));
        _refused(x, y, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(1), uint8(1)));
        // a form-1 revision naming a missing record, or a record of another Type (the span root, a chunk)
        bytes32 file = Keys.subject(p, keccak256("form1"));
        Action[] memory f = new Action[](2);
        bytes[] memory fb = new bytes[](2);
        f[0] = _create(keccak256("form1"));
        bytes32[3] memory wrong = [keccak256("no such descriptor"), root, c0];
        for (uint256 i; i < 3; ++i) {
            (f[1], fb[1]) = _publish(T_ROOT, EfsFiles.rootRefBody(file, wrong[i]));
            _refused(f, fb, abi.encodeWithSelector(E_REJECTED.selector, uint8(1), typeIds[T_ROOT]));
        }
        // an unknown form
        (f[1], fb[1]) = _publish(T_ROOT, abi.encode(file, uint256(2), root));
        _refused(f, fb, abi.encodeWithSelector(E_REJECTED.selector, uint8(1), typeIds[T_ROOT]));
        // and the right descriptor lands, in the same publication as its revision
        Action[] memory ok = new Action[](3);
        bytes[] memory okb = new bytes[](3);
        (ok[0], okb[0]) =
            _publish(T_CONTENT, EfsFiles.contentBody(root, 2, 100, sha256(payload), ""));
        ok[1] = _create(keccak256("form1"));
        (ok[2], okb[2]) = _publish(T_ROOT, EfsFiles.rootRefBody(file, _id(T_CONTENT, okb[0])));
        _run(ok, okb);
        (bytes32 t,,,,) = r.hot.recordHeader(_id(T_ROOT, okb[2]));
        assertEq(t, typeIds[T_ROOT]);
        // a child (edit) revision of form 1 naming the same descriptor, then back to inline
        (Action[] memory ea, bytes[] memory eb, bytes32 child) =
            EfsFiles.editRef(_types(), file, _id(T_ROOT, okb[2]), _id(T_CONTENT, okb[0]), 0);
        _run(ea, eb);
        (ea, eb,) = EfsFiles.edit(_types(), file, child, "inline again", 1);
        _run(ea, eb);
    }
}
