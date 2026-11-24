// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesPageHarness} from "./FilesPageHarness.sol";
import {EfsWeb3Gateway} from "../../../src/periphery/EfsWeb3Gateway.sol";
import {KeyValue} from "../../../src/interfaces/IWeb3Gateway.sol";
import {EfsFiles} from "../../../src/lib/EfsFiles.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, Purpose} from "../../../src/interfaces/Actions.sol";

/// @notice The `EfsWeb3Gateway` suites' fixture: the Files Realm of `FilesPageHarness` (kernel, real registry, real
///         generation-1 index, the ten Types, the two facets and a `FilesPageReader`), a gateway with the page reader
///         and one without, and a tree written by this contract's principal `p` and an EOA `alice`:
///
///           /hello.txt              inline "hello, web3"
///           /notes.txt              edited: root "v1" then child "v2: edited"
///           /big.bin                40,000 bytes, 8,160-byte chunks (5 chunks, depth 3), files-content/1 carrier 2
///           /deep tree.bin          5,000 bytes, 64-byte chunks (79 chunks, depth 7)
///           /ext.bin                files-external/1 ar://… (307)
///           /gone.txt               removed by p (MASKED); alice binds her own gone.txt
///           /docs/sub/              nested folder, /docs/sub/leaf.txt
///           /docs/guide.html        inline
///           alice: /alice.txt, /gone.txt, /docs/alice-doc.txt, /shared.txt (removed by alice; p binds shared.txt)
///
///         URL helpers parse a `/path?query` string the way an ERC-6860 client does (split on `/`, percent-decode,
///         split the query on `&` and `=`) and follow `web3-next-chunk`.
abstract contract Web3GatewayHarness is FilesPageHarness {
    struct Res {
        uint16 status;
        bytes body;
        KeyValue[] headers;
    }

    uint256 internal constant CHUNK = 8_160;
    EfsWeb3Gateway internal gw;
    EfsWeb3Gateway internal bare; // no page reader
    address internal alice = makeAddr("alice");
    bytes32 internal pa;
    string internal P; // p as 64 hex digits
    string internal A; // alice as 64 hex digits

    bytes32 internal docs;
    bytes32 internal sub;
    bytes32 internal helloRoot;
    bytes32 internal notesChild;
    bytes32 internal bigRoot;
    bytes internal bigPayload;
    bytes internal deepPayload;
    bytes32 internal extDescriptor;
    bytes internal constant LOCATOR = "ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U";

    function _setUpGateway() internal {
        _setUpFiles(keccak256("web3/realm"));
        pa = Keys.principal(alice);
        P = _hex64(p);
        A = _hex64(pa);
        gw = new EfsWeb3Gateway(
            address(r.ledger), address(reads), address(views), address(reader), rootDir, _gt()
        );
        bare = new EfsWeb3Gateway(
            address(r.ledger), address(reads), address(views), address(0), rootDir, _gt()
        );
        Action[] memory a;
        bytes[] memory b;
        (, helloRoot) = _file(address(this), rootDir, "hello.txt", "hello, web3", true);
        (bytes32 notes, bytes32 notesRoot) = _file(address(this), rootDir, "notes.txt", "v1", true);
        (a, b, notesChild) = EfsFiles.edit(t, notes, notesRoot, "v2: edited", 1);
        _exec(a, b);
        bigPayload = _payload(40_000, "big");
        bigRoot = _store(address(this), rootDir, "big.bin", bigPayload, CHUNK);
        deepPayload = _payload(5_000, "deep");
        _store(address(this), rootDir, "deep tree.bin", deepPayload, 64);
        _external("ext.bin");
        _file(address(this), rootDir, "gone.txt", "p's gone", true);
        (a, b) = EfsFiles.remove(rootDir, "gone.txt", 1);
        _exec(a, b);
        docs = _folder(rootDir, "docs");
        sub = _folder(docs, "sub");
        _file(address(this), sub, "leaf.txt", "a leaf", true);
        _file(address(this), docs, "guide.html", "<h1>guide</h1>", true);
        // alice binds names in p's folders, and masks one p binds afterwards
        _file(alice, rootDir, "alice.txt", "alice's own", true);
        _file(alice, rootDir, "gone.txt", "alice's gone", false);
        _file(alice, docs, "alice-doc.txt", "alice's doc", true);
        _file(alice, rootDir, "shared.txt", "alice's shared", true);
        (a, b) = EfsFiles.remove(rootDir, "shared.txt", 1);
        _execAs(alice, a, b);
        _file(address(this), rootDir, "shared.txt", "p's shared", false);
    }

    function _gt() internal view returns (EfsWeb3Gateway.Types memory g) {
        g.directory = typeIds[T_DIRECTORY];
        g.name = typeIds[T_NAME];
        g.root = typeIds[T_ROOT];
        g.child = typeIds[T_CHILD];
        g.content = typeIds[T_CONTENT];
        g.external_ = typeIds[T_EXTERNAL];
        g.bytes_ = typeIds[T_BYTES];
        g.span = typeIds[T_SPAN];
    }

    // ---- writers --------------------------------------------------------------------------------------------

    /// `n` pseudo-random bytes.
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

    /// Chunks, spans, descriptor and a form-1 file named `name` in `folder`, split under the S1 limits (64
    /// actions, 16,384 body bytes per publication). Returns the tree root (chunk or span).
    function _store(
        address author,
        bytes32 folder,
        string memory name,
        bytes memory payload,
        uint256 chunk
    ) internal returns (bytes32 root) {
        (Action[] memory a, bytes[] memory b, bytes32 descriptor) =
            EfsFiles.storeContent(t, payload, chunk, 0);
        (,,, root) = _descriptorOf(b[b.length - 1]);
        (Action[] memory fa, bytes[] memory fb,,) = EfsFiles.createFileRef(
            t, _principalOf(author), folder, keccak256(bytes(name)), bytes(name), descriptor, true
        );
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        _publishAll(author, a, b);
    }

    function _descriptorOf(bytes memory body)
        internal
        pure
        returns (uint256 carrier, uint256 length, bytes32 digest, bytes32 ref)
    {
        (ref,, carrier,, length, digest) =
            abi.decode(body, (bytes32, uint256, uint256, uint256, uint256, bytes32));
    }

    function _publishAll(address author, Action[] memory a, bytes[] memory b) internal {
        uint256[] memory ends = EfsFiles.split(b, 64, 16_384);
        uint256 from;
        for (uint256 i; i < ends.length; ++i) {
            (Action[] memory xa, bytes[] memory xb) = EfsFiles.slice(a, b, from, ends[i]);
            _execAs(author, xa, xb);
            from = ends[i];
        }
    }

    function _principalOf(address author) internal view returns (bytes32) {
        return author == address(this) ? p : Keys.principal(author);
    }

    /// A form-1 file naming a `files-external/1` location (with the empty-bytes sentinel it references).
    function _external(string memory name) internal {
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        b[0] = EfsFiles.bytesBody("");
        a[0] = EfsFiles.publish(t.bytes_, b[0]);
        b[1] = EfsFiles.externalBody(
            Keys.record(t.bytes_, b[0]), 1234, sha256("remote bytes"), LOCATOR
        );
        a[1] = EfsFiles.publish(t.external_, b[1]);
        extDescriptor = Keys.record(t.external_, b[1]);
        (Action[] memory fa, bytes[] memory fb,,) = EfsFiles.createFileRef(
            t, p, rootDir, keccak256(bytes(name)), bytes(name), extDescriptor, true
        );
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        _exec(a, b);
    }

    /// A form-1 file in the root naming `descriptorBody` (a `files-content/1` body over `bytesBody`'s record).
    function _contentFile(string memory name, bytes memory bytesBody, bytes memory descriptorBody)
        internal
    {
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        b[0] = bytesBody;
        a[0] = EfsFiles.publish(t.bytes_, b[0]);
        b[1] = descriptorBody;
        a[1] = EfsFiles.publish(t.content, b[1]);
        (Action[] memory fa, bytes[] memory fb,,) = EfsFiles.createFileRef(
            t,
            p,
            rootDir,
            keccak256(bytes(name)),
            bytes(name),
            Keys.record(t.content, descriptorBody),
            true
        );
        (a, b) = EfsFiles.concat(a, b, fa, fb);
        _exec(a, b);
    }

    // ---- requests -------------------------------------------------------------------------------------------

    function _get(string memory url) internal view returns (Res memory) {
        return _getFrom(gw, url);
    }

    function _getFrom(EfsWeb3Gateway g, string memory url) internal view returns (Res memory res) {
        (string[] memory resource, KeyValue[] memory params) = _parseUrl(url);
        string memory body;
        (res.status, body, res.headers) = g.request(resource, params);
        res.body = bytes(body);
    }

    /// The gas of one `request` (the URL parsing excluded).
    function _gasOf(string memory url) internal view returns (uint256 used, Res memory res) {
        (string[] memory resource, KeyValue[] memory params) = _parseUrl(url);
        string memory body;
        uint256 before = gasleft();
        (res.status, body, res.headers) = gw.request(resource, params);
        used = before - gasleft();
        res.body = bytes(body);
    }

    /// Follows `web3-next-chunk` from `url` until a response has none; every response must be 200.
    function _fetchAll(string memory url)
        internal
        view
        returns (bytes memory all, uint256 responses)
    {
        while (true) {
            Res memory res = _get(url);
            assertEq(res.status, 200, url);
            all = bytes.concat(all, res.body);
            ++responses;
            (bool more, string memory next) = _header(res, "web3-next-chunk");
            if (!more) break;
            url = next;
        }
    }

    function _header(Res memory res, string memory key)
        internal
        pure
        returns (bool found, string memory value)
    {
        for (uint256 i; i < res.headers.length; ++i) {
            if (keccak256(bytes(res.headers[i].key)) == keccak256(bytes(key))) {
                return (true, res.headers[i].value);
            }
        }
    }

    function _headerEq(Res memory res, string memory key, string memory want) internal pure {
        (bool found, string memory value) = _header(res, key);
        assertTrue(found, key);
        assertEq(value, want, key);
    }

    /// `url` answers `want`; a refusal is a short `text/plain` body and that one header.
    function _status(string memory url, uint16 want) internal view returns (Res memory res) {
        res = _get(url);
        assertEq(res.status, want, url);
        if (want >= 400) {
            assertEq(res.headers.length, 1, "a refusal carries only its content type");
            _headerEq(res, "Content-Type", "text/plain; charset=utf-8");
            assertGt(res.body.length, 0, "a refusal names its reason");
        }
    }

    // ---- an ERC-6860 client's URL split -----------------------------------------------------------------------

    /// `/a/b%20c/?k=v&x` → resource `["a", "b c", ""]`, params `[(k, v), (x, "")]`; `/` → no segment.
    function _parseUrl(string memory url)
        internal
        pure
        returns (string[] memory resource, KeyValue[] memory params)
    {
        bytes memory u = bytes(url);
        require(u.length != 0 && u[0] == "/", "url starts with /");
        uint256 q = u.length;
        for (uint256 i; i < u.length; ++i) {
            if (u[i] == "?") {
                q = i;
                break;
            }
        }
        bytes[] memory segments = _split(_cut(u, 1, q), "/");
        resource = new string[](q == 1 ? 0 : segments.length);
        for (uint256 i; i < resource.length; ++i) {
            resource[i] = string(_decode(segments[i]));
        }
        if (q + 1 >= u.length) return (resource, params);
        bytes[] memory pairs = _split(_cut(u, q + 1, u.length), "&");
        params = new KeyValue[](pairs.length);
        for (uint256 i; i < pairs.length; ++i) {
            bytes[] memory kv = _split(pairs[i], "=");
            params[i].key = string(_decode(kv[0]));
            if (kv.length > 1) params[i].value = string(_decode(kv[1]));
        }
    }

    function _cut(bytes memory s, uint256 from, uint256 to)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = s[from + i];
        }
    }

    function _split(bytes memory s, bytes1 sep) internal pure returns (bytes[] memory parts) {
        uint256 n = 1;
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == sep) ++n;
        }
        parts = new bytes[](n);
        uint256 k;
        uint256 from;
        for (uint256 i; i <= s.length; ++i) {
            if (i == s.length || s[i] == sep) {
                parts[k++] = _cut(s, from, i);
                from = i + 1;
            }
        }
    }

    function _decode(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length);
        uint256 k;
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == "%" && i + 2 < s.length) {
                out[k++] = bytes1(uint8(_nibble(s[i + 1]) * 16 + _nibble(s[i + 2])));
                i += 2;
            } else {
                out[k++] = s[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    function _nibble(bytes1 c) internal pure returns (uint8) {
        uint8 x = uint8(c);
        if (x >= 48 && x <= 57) return x - 48;
        if (x >= 97 && x <= 102) return x - 87;
        require(x >= 65 && x <= 70, "hex digit");
        return x - 55;
    }

    /// 64 lower-case hex digits, no prefix.
    function _hex64(bytes32 v) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(v));
        return string(_cut(s, 2, s.length));
    }

    function _hexId(bytes32 v) internal pure returns (string memory) {
        return vm.toString(v);
    }
}
