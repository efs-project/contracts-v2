# Large files, external locations and `web3://`

Status: adopted 2026-11-24 on James's instruction ("support large on-chain files, even gigabyte files in the
future; Arweave, IPFS, Swarm and others for now; `web3://` designed into the core"). It revises design §12.1.
Nothing persistent is deployed, so the Types below are changed in place and keep their `/1` names.

## The model in one paragraph

A file revision either carries its bytes inline or names one **content descriptor** record. A content descriptor
says "these bytes have this length and this sha256" and where they are: one on-chain record, an on-chain **span
tree** of chunk records, or an external location given as a URI. Every piece is a content-addressed record, so
identical chunks, subtrees and files are stored once. Descriptors with the same sha256 are found together through
the digest index family, so anyone can add another location for the same bytes and a reader may use whichever
answers; the bytes always verify against the sha256, so the location needs no trust.

## Revision bodies (`files-root/1`, `files-child/1`)

```text
files-root/1   [fileSubject, form, …]            refs: none
files-child/1  [parentRecord, fileSubject, form, …]   refs: [ANY] (the parent revision)
form 0 INLINE   the rest of the body is the file's bytes (possibly empty)
form 1 CONTENT  exactly one more word: the id of an existing files-content/1 or files-external/1 record
```

The rule verifies form 1 with one hot read (`recordHeader(id).typeId` is one of the two descriptor Types), so a
revision can never name a descriptor that does not exist. Any other form refuses. The descriptor Type ids are
constructor state of the rules, like the existing sibling ids.

## On-chain bytes

- **`files-bytes/1`** `sha256(payload) ‖ payload`: one chunk. The rule no longer caps the body at 8,192 bytes; the
  Realm's `limits.maxBody` is the only bound, so a chain with cheaper state raises the chunk size by activation
  without a new Type. The empty payload stays the sentinel.
- **`files-span/1`** `[left, right, length]`, refs `[ANY, ANY]`, `refHeaderWords = 3`: a binary node. Each child is a
  `files-bytes/1` record (its payload length is `header.length − 32`, which must be nonzero) or another
  `files-span/1` record (its length is its word 2). The rule requires `length == len(left) + len(right)`, from the
  reference headers the kernel already loaded: no body loads, no extra reads. Two is the widest fan-out the
  acceptor ABI can verify this way (three header words: two child ids and the length). A span's record id commits
  to every chunk under it, and every chunk's sha256 was verified at admission, so a span tree is complete and
  correct by construction.
- **`files-content/1`** keeps its eleven words `[bytesRef, version, carrier, hashAlg, length, sha256, media(2), cipher,
  nonce12, plaintextLength, plaintextSHA256OrZero]`; its one reference is now `ANY` and the rule checks the Type by
  carrier: `0` one `files-bytes/1` record (length and sha256 verified, as before); `1` the remote sentinel (as
  before); `2` a `files-span/1` root whose word 2 equals `length`. Lengths are bounded by `2^64 − 1`, not 1 MiB.
  For carrier 2 the whole-file sha256 cannot be recomputed on chain, so it is the author's claim exactly as it is
  for an external location; the verified commitment is the span root id, and a reader checks the sha256 after
  reading.

Canonical chunking for SDKs (`efs2/chunking/1`, a convention, never enforced): fixed chunk payloads of 8,160 bytes
(a body of 8,192) except the last; the tree over `n` chunks is the chunk itself for `n = 1`, else
`span(tree(first k), tree(rest))` with `k` the largest power of two below `n`. Children are published before
their parents; a publication may carry several levels.

What a gigabyte means: 1 GiB is 131,587 chunks and 131,586 span nodes, depth 18. Measured under the S1 limits, an
8 KB chunk costs about 6.1M gas and a span node about 0.32M, so a gigabyte is on the order of 8 × 10^11 gas today:
the format carries it, the economics of a given chain decide whether anyone pays for it. Nothing in an id or a rule
limits it: record lengths are 32-bit, content lengths 64-bit, ordinals 48-bit. What limits it today is cost and
the per-publication byte limit (two 8 KB chunks per publication under the S1 limits). The levers that do not
change any id are the Realm limits (`maxBody`, `maxBodyBytesPerPublication`) and a cheaper body carrier (code
blobs, capability b6, design Q4): a record id is `keccak(type, body)` whatever stores the body.

## External locations (`files-external/1`)

`[bytesRef (the empty sentinel), version = 2, carrier = 2, hashAlg = 1, length, sha256, locatorLength] ‖ locator`.
The locator is a URI of 1..2,048 bytes, every byte printable ASCII (0x21..0x7e), starting with an RFC 3986 scheme
(`ALPHA *(ALPHA / DIGIT / "+" / "-" / ".") ":"`) and at least one byte after the colon. **There is no scheme
allowlist**: `ar://`, `ipfs://`, `bzz://`, `web3://`, `https://` and schemes that do not exist yet are all
admitted. A scheme list on an immutable rule is not a security boundary (rendering safety lives in the client),
is trivially evaded and cannot anticipate new schemes; this is the v1 ruling of 2026-06-19 (ADR-0056) carried
into v2. `length` is bounded by `2^64 − 1`. No remote proof is taken at admission; readers verify the sha256.

## `web3://`

Two directions, both in the core design:

1. **EFS content that lives at a `web3://` address** is an external location like any other: a `files-external/1`
   record whose locator is the `web3://` URL. This is the zero-infrastructure location every client type,
   including a contract, can read natively.
2. **EFS content served over `web3://`** is a reader, `EfsWeb3Gateway`: an immutable periphery contract outside
   the execution set that implements the ERC-5219 resource request mode (`resolveMode() = "5219"`,
   `request(string[] resource, KeyValue[] params) → (statusCode, body, headers)`) with ERC-7617 chunked bodies.
   `web3://<gateway>:<chainId>/<principal>/<name>/<name>/…` walks FOLDER bindings from the Realm root by name for
   that principal (`?lens=<principal>,<principal>` adds fall-through authors under the Lens law), reads the file's
   HEAD revision, and answers: inline bytes as the body; a `files-content/1` descriptor's bytes, one chunk per
   response with a `web3-next-chunk` header walking the span tree in order; a `files-external/1` descriptor as a
   `307` with `Location: <locator>`; a directory as a listing. It needs no index (names resolve by point reads) and
   no kernel support: every fact it serves is a hot read or a facet read. Being a reader, it can be added, fixed
   and replaced after a freeze.

## What changes in the repository

`src/profiles/` (the four rules above, the new `FilesSpanRule`, `FilesTypes`), `src/lib/EfsFiles.sol` (encoders, the
canonical chunker), the Files suites and fixtures, the genesis plan (ten Files Types), and later
`src/periphery/EfsWeb3Gateway.sol`. The kernel, the registry, the index, the readers' laws and the final
validator are untouched.
