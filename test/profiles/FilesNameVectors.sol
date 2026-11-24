// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The 50 name vectors of the naming experiment (`planning/Reviews/2026-09-26-efs-v2-naming-reconciliation/
///         experiment/test/Vectors.sol`, generated there by `vectors.mjs`, an independent JavaScript oracle), reduced to
///         the `files-name/2` verdict (the oracle's `v2` column; `NameV2F` agrees with it on every vector) and the
///         keccak role. Copied, not regenerated: the oracle and its Node ICU tables stay in the review.
library FilesNameVectors {
    struct V {
        bytes data;
        bool valid;
        bytes32 role;
    }

    function all() internal pure returns (V[] memory v) {
        v = new V[](50);
        // plain ASCII
        v[0] = V(
            hex"726561646d652e747874",
            true,
            0x31f491635b16d6fb45a7d770fcbcc8cbb6eae32ac98ab622631f4bc4a8c7e9ce
        );
        // case pair (with report.txt)
        v[1] = V(
            hex"5265706f72742e545854",
            true,
            0x36810084e09fd082065e1587a57a381b51c77bbb6ee74db5981e5b46b0fa4642
        );
        // case pair
        v[2] = V(
            hex"7265706f72742e747874",
            true,
            0x143801f1f10abf0e6876c8219bfd3c94b8a26e3b604b5ae3c46d383d7a864f70
        );
        // 255 ASCII bytes
        v[3] = V(
            hex"616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161",
            true,
            0xd44e86b57c34f27dd6e59f94c47033054a745cb3266556066ea4bf687c70a568
        );
        // 256 bytes: too long
        v[4] = V(
            hex"61616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161",
            false,
            0x1daa7034adab66d9ec9e03e2c89201b83a7497e85dc5b971aa9dae2ccbb7a208
        );
        // ASCII punctuation, spaces
        v[5] = V(
            hex"512641202331202866696e616c292e6a7067",
            true,
            0x46216254ccddb7100c31c5918e6844b9b65e537462c0a0608fe01c82440fa6b0
        );
        // percent and question mark
        v[6] = V(
            hex"3130302520646f6e653f2e747874",
            true,
            0x162e07b838f16465672f22fdf44d2adbba8a84c25927b6ceb2b46be17e6ba365
        );
        // plus, equals, ampersand
        v[7] = V(
            hex"612b623d6326642e747874",
            true,
            0x7e820e891659fb02da85f2655bafccd4aa27e0ca0604b7bab1b217c13c269923
        );
        // tilde inside
        v[8] = V(
            hex"74696c64657e686f6d652e747874",
            true,
            0x0222726d7eb9669f74a14d17172ba69dd1da19ab3bc2a8b0b4cbc440cb94f012
        );
        // reserved prefix
        v[9] = V(
            hex"7e6566732d636f6e74726f6c",
            false,
            0xe2625997285cecb3773c8ca8b5a10b623cdd4be5cd7ffa9527005b5d36aa2ebd
        );
        // leading tilde (allowed)
        v[10] = V(
            hex"7e6261636b75702e747874",
            true,
            0xd2dbf4e8838899725c495ee291e74219acb9b6c1b36137197fd948523290f81a
        );
        // leading dot
        v[11] = V(
            hex"2e68696464656e",
            true,
            0xa8ae42f1d0f5d3fc036bafb30ed3fcc9bd6e9ade46f5121c1945b13ed277b466
        );
        // three dots
        v[12] = V(
            hex"2e2e2e", true, 0xabb51256c1324a1350598653f46aa3ad693ac3cf5d05f36eba3f495a1f51590f
        );
        // dot
        v[13] =
            V(hex"2e", false, 0x6f010af653ebe3cb07d297a4ef13366103d392ceffa68dd48232e6e9ff2187bf);
        // dotdot
        v[14] =
            V(hex"2e2e", false, 0xcf7df81cda991f48de70c04bf7a6219e57bafa518c590bee9c5d9a7087825d19);
        // empty
        v[15] = V(hex"", false, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470);
        // slash
        v[16] = V(
            hex"782f79", false, 0x601eee51f573007eae874e0315d979c34125237a651922dd1f5eece46ee324b6
        );
        // backslash
        v[17] = V(
            hex"615c62", false, 0x3932c2aa8ffda7bcf1e943ba4f47242ff8feda3fa940ec177084d01b9d47ef05
        );
        // NUL
        v[18] = V(
            hex"6e756c0062797465",
            false,
            0xba78d639ab81cddfe8dd96de36ec5e31cc6c749a028b8fbfbdf70a8023cfa66b
        );
        // tab
        v[19] = V(
            hex"7461620968657265",
            false,
            0xfc5a8b1b00fc4c36467f1e4da7897650708b7bb46d338420a6cf2cff6cab87d6
        );
        // trailing space
        v[20] = V(
            hex"747261696c696e6720",
            false,
            0x63aa094540cb7fb213d31fd063b80b2945df1c8716b617984d8a198273cf676f
        );
        // leading space
        v[21] = V(
            hex"206c656164696e67",
            false,
            0x42bacad515c5cbc51f2762c79239c51d535a54f271dcc9059566c8414a3e0eb2
        );
        // inner space
        v[22] = V(
            hex"696e6e65722073706163652e747874",
            true,
            0xb033a6a9b086be23c7ef1a5eeaa02c824e06f99d97afb9f31995be716441df86
        );
        // precomposed ? (NFC)
        v[23] = V(
            hex"636166c3a92e747874",
            true,
            0x51ca49ae9a12210906e1ab86ac1c8731e11cd86edf0df9dbbc4cfd13531de9d9
        );
        // decomposed ? (not NFC, QC=Maybe)
        v[24] = V(
            hex"63616665cc812e747874",
            true,
            0x4674ddf120a1c4a844be00bf1c468c373a7faff9f25e6d8fe62fe13608d403be
        );
        // A-ring U+00C5 (NFC)
        v[25] = V(
            hex"c3856e67737472c3b66d2e747874",
            true,
            0xdf9e53e185f9b1ca668acb1a1c68974cfd7c7981eac69845d03dcb00965c043e
        );
        // ANGSTROM SIGN U+212B (NFC_QC=No)
        v[26] = V(
            hex"e284ab6e67737472c3b66d2e747874",
            true,
            0x9c9f70797952d48df450bc9078f7d9380ba751de7dce260eea8880b665804dab
        );
        // CJK
        v[27] = V(
            hex"e69db1e4baac2e747874",
            true,
            0xc1d140dd028ebef7162124945fa2e9e82b6cf62c72cc60a250101139370c159d
        );
        // 255-byte CJK
        v[28] = V(
            hex"e7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958c",
            true,
            0xaaf4458370ea746935fafcd99d226290c39b8f0cc52bca8b46ebff3d25cf98dc
        );
        // 258-byte CJK: too long
        v[29] = V(
            hex"e7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958ce7958c",
            false,
            0x35bfb95ce42fc6054bb931766fcc713176d76728acb5020d1458231a6c9a299d
        );
        // precomposed Hangul (NFC)
        v[30] = V(
            hex"ed959ceab5adec96b42e747874",
            true,
            0xcbb10af2d2e2bb3d138eee9d6747786012bf10496ec4718b95154c2253c1db64
        );
        // decomposed Hangul jamo (not NFC)
        v[31] = V(
            hex"e18492e185a1e186ab2e747874",
            true,
            0x27b9c3737dda2250db9146f9a68fb11a647474d65f9c8e440d233ee1ba6d36a1
        );
        // Arabic
        v[32] = V(
            hex"d985d984d9812e747874",
            true,
            0xaf63a5b59dc2834bb6be59b295c8560db985ae2d6c92387a162229a9f980b4aa
        );
        // Devanagari with virama
        v[33] = V(
            hex"e0a4a8e0a4aee0a4b8e0a58de0a4a4e0a5872e747874",
            true,
            0x92bd293f79a0333ebc6c70d89652d4f94318a25167f02bf1375b0b0820f3e35e
        );
        // Hebrew
        v[34] = V(
            hex"d7a9d79cd795d79d2e747874",
            true,
            0x0f6af3d6901a3cac4e98bdb20e57f4e3d8e8ba854902b4fc3c3393b99a6c771e
        );
        // emoji
        v[35] = V(
            hex"f09f93812e706e67",
            true,
            0x5a1bc69c18b84a38befe5bbe3f361f8956cdfe7d76eb9e56562310a7d8c8bc38
        );
        // ZWJ family sequence
        v[36] = V(
            hex"f09f91a8e2808df09f91a9e2808df09f91a7e2808df09f91a62e706e67",
            true,
            0x888be76c7569bf962040a61a2c915835639638766a3910d38bccc85032bc1652
        );
        // tag-sequence flag
        v[37] = V(
            hex"f09f8fb4f3a081a7f3a081a2f3a081b3f3a081a3f3a081b4f3a081bf2e706e67",
            true,
            0x107282559ad424aae000bf839876067e26ace530083cc11e55c6c977b13572da
        );
        // zero-width space (rejected)
        v[38] = V(
            hex"74657374e2808b6e616d652e747874",
            false,
            0xb9e12d78de7c5b3d3b154dd564db32f2c6f16d7d18e436b8534237b234049d3c
        );
        // RLO bidi override (rejected)
        v[39] = V(
            hex"e280ae6576696c2e747874",
            false,
            0xfe9dd2f29ddb7bc555f192dc05e1f3b729b0e8b08ee5b40e7897399212a70c9f
        );
        // soft hyphen (rejected)
        v[40] = V(
            hex"61c2ad622e747874",
            false,
            0xb72b95161e39f7749537d97c4be0842a8257c03142dbf97579ceeaa80124f962
        );
        // BOM (rejected)
        v[41] = V(
            hex"efbbbf626f6d2e747874",
            false,
            0x1803586688b095f33061fcb704b87446825356441332e8253059712c417774b7
        );
        // fi ligature (NFC yes, NFKC no)
        v[42] = V(
            hex"efac816c652e747874",
            true,
            0xe035b53992e2d791cbdf7d36ddcd6138ddc752978bc42f2397960e57fbca3f87
        );
        // Windows device name (allowed by EFS)
        v[43] = V(
            hex"434f4e", true, 0xb94082438de1196383187762753d2b2aae94d4a400b7a04ca545bfd1ce82e3dc
        );
        // Windows device name with extension
        v[44] = V(
            hex"636f6e2e747874",
            true,
            0xc29802868d3be34f3f4d5aae69462bbe4c794b881de3ede038deefd0c51a6ac7
        );
        // trailing dot (allowed by EFS)
        v[45] = V(
            hex"656e64732e",
            true,
            0x8bdc1857f8dc623682b824a19a2a500321252865f61fda7f907b8bfca812d1b6
        );
        // literal percent sequence as a name
        v[46] = V(
            hex"2545372538432541422e6a7067",
            true,
            0xf7576b2f1a856935b278b32c92e1110d8c84eff765079a1b895d91a869a3af3b
        );
        // literal %2F as a name
        v[47] = V(
            hex"2532462e747874",
            true,
            0xb2f59fea85e8953f6e8bdfec4ce58ef1f4f054fad96b6a80b88ea214fda17fce
        );
        // ZWNJ+ZWJ (allowed, DI)
        v[48] = V(
            hex"66696c65e2808ce2808d2e747874",
            true,
            0xb65e01c6fe15c2c2be2bb6962d6432c2a785b8c702dcc9bb44f10daa16e4f96f
        );
        // stacked combining marks
        v[49] = V(
            hex"65cc81cc812e747874",
            true,
            0x75ab93a377d79c0e6beeb6a1728774aab86da9583815d49fcc15877dea2cfccd
        );
    }
}
