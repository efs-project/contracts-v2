// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";

/// @notice What a declared media type costs per file (docs/LARGE-FILES.md; DESIGN.md adoption note 27). One
///         publication per row, cooled like `GasModel.t.sol`, so each pays what a transaction of its own pays:
///         a small on-chain file (`files-bytes/1` chunk, `files-content/1` carrier 0, CREATE, root form 1, name,
///         BIND HEAD, BIND FOLDER) and an external file (`files-external/1` over `ar://…`, the sentinel published
///         in setUp, then the same five actions), each with media empty, `image/png`, `text/html; charset=utf-8`
///         and the 71-byte docx type. Logs `media <key> gas` and `frame gas` (and `frame state gas` under the
///         amsterdam profile).
contract MediaTypeMeasureTest is FilesRecipesBase {
    address[] internal cold;
    bytes32 internal sentinel;

    bytes internal constant LOCATOR = "ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U";
    bytes internal constant DOCUMENT = "Meeting at 10:00.\n";
    bytes internal constant PNG = "image/png";
    bytes internal constant HTML = "text/html; charset=utf-8";
    bytes internal constant DOCX =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 10; ++i) {
            cold.push(instances[i]);
        }
        cold.push(refuseAll);
        cold.push(address(validator));
        cold.push(address(r.k.ingress));
        cold.push(address(r.k.applyDelegate));
        cold.push(address(r.k.control));
        cold.push(address(r.k.implementation));
        cold.push(r.k.proxy);
        cold.push(address(r.g.posting));
        cold.push(address(r.g.bitmap));
        cold.push(address(r.g.index));
        cold.push(address(r.store));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        // the empty files-bytes/1 sentinel every external location references
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(T_BYTES, EfsFiles.bytesBody(""));
        sentinel = _id(T_BYTES, b[0]);
        r.ledger.execute(a, b, _ctx(a), "");
    }

    function _beforeExecute() internal override {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
    }

    function _contentBody(bytes32 ref, uint256 length, bytes32 digest, bytes memory media)
        internal
        pure
        returns (bytes memory)
    {
        return EfsFiles.contentBody(ref, EfsFiles.CARRIER_INLINE, length, digest, media);
    }

    function _externalBody(uint256 length, bytes32 digest, bytes memory media)
        internal
        view
        returns (bytes memory)
    {
        return EfsFiles.externalBody(sentinel, length, digest, LOCATOR, media);
    }

    /// The five file actions after `pre` (CREATE, root form 1 naming `descriptor`, name, BIND HEAD, BIND FOLDER).
    function _file(
        string memory key,
        Action[] memory pre,
        bytes[] memory preBodies,
        bytes32 descriptor
    ) internal {
        bytes memory name = "file.txt";
        (Action[] memory fa, bytes[] memory fb,,) = EfsFiles.createFileRef(
            _types(), p, rootDir, keccak256("measured file"), name, descriptor, true
        );
        (Action[] memory a, bytes[] memory b) = EfsFiles.concat(pre, preBodies, fa, fb);
        _exec(string.concat("media ", key), a, b);
    }

    function _types() internal view returns (EfsFiles.Types memory t) {
        t.root = typeIds[T_ROOT];
        t.child = typeIds[T_CHILD];
        t.directory = typeIds[T_DIRECTORY];
        t.name = typeIds[T_NAME];
        t.bytes_ = typeIds[T_BYTES];
        t.content = typeIds[T_CONTENT];
        t.external_ = typeIds[T_EXTERNAL];
        t.span = typeIds[T_SPAN];
    }

    function _small(string memory key, bytes memory media) internal {
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = _publish(T_BYTES, EfsFiles.bytesBody(DOCUMENT));
        (a[1], b[1]) = _publish(
            T_CONTENT, _contentBody(_id(T_BYTES, b[0]), DOCUMENT.length, sha256(DOCUMENT), media)
        );
        _file(string.concat("small ", key), a, b, _id(T_CONTENT, b[1]));
    }

    function _external(string memory key, bytes memory media) internal {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(T_EXTERNAL, _externalBody(1234, sha256("remote bytes"), media));
        _file(string.concat("external ", key), a, b, _id(T_EXTERNAL, b[0]));
    }

    function test_media_small_empty() public {
        _small("empty", "");
    }

    function test_media_small_png() public {
        _small("png", PNG);
    }

    function test_media_small_html() public {
        _small("html", HTML);
    }

    function test_media_small_docx() public {
        _small("docx", DOCX);
    }

    function test_media_external_empty() public {
        _external("empty", "");
    }

    function test_media_external_png() public {
        _external("png", PNG);
    }

    function test_media_external_html() public {
        _external("html", HTML);
    }

    function test_media_external_docx() public {
        _external("docx", DOCX);
    }
}
