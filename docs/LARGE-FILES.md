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
- **`files-content/1`** is ten words and a media tail, `[bytesRef, version, carrier, hashAlg, length, sha256, cipher,
  nonce12, plaintextLength, plaintextSHA256OrZero] ‖ media`: 320 bytes, then the media type as the rest of the body
  (see "Media types" below); its one reference is `ANY` and the rule checks the Type by
  carrier: `0` one `files-bytes/1` record (length and sha256 verified, as before); `1` the remote sentinel (as
  before); `2` a `files-span/1` root whose word 2 equals `length`. Lengths are bounded by `2^64 − 1`, not 1 MiB.
  For carrier 2 the whole-file sha256 cannot be recomputed on chain, so it is the author's claim exactly as it is
  for an external location; the verified commitment is the span root id, and a reader checks the sha256 after
  reading.

Canonical chunking for SDKs (`efs/chunking/1`, a convention, never enforced): fixed chunk payloads of 8,160 bytes
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

`[bytesRef (the empty sentinel), version = 2, carrier = 2, hashAlg = 1, length, sha256, locatorLength] ‖ locator ‖
media`: a seven-word head (224 bytes), then the locator, then the media type as the rest of the body. The locator is a URI of 1..2,048 bytes, every byte printable ASCII (0x21..0x7e), starting with an RFC 3986 scheme
(`ALPHA *(ALPHA / DIGIT / "+" / "-" / ".") ":"`) and at least one byte after the colon. **There is no scheme
allowlist**: `ar://`, `ipfs://`, `bzz://`, `web3://`, `https://` and schemes that do not exist yet are all
admitted. A scheme list on an immutable rule is not a security boundary (rendering safety lives in the client),
is trivially evaded and cannot anticipate new schemes; this is the v1 ruling of 2026-06-19 (ADR-0056) carried
over. `length` is bounded by `2^64 − 1`. No remote proof is taken at admission; readers verify the sha256. The media
type is the same field as `files-content/1`'s, checked by the same function.

## Media types

Every content descriptor says what its bytes are: a MIME media type string (RFC 6838 `type/subtype` with optional
parameters), carried as the rest of the descriptor's body. No word stores its length: the record's length already
fixes it, and a length word that must equal `body.length − constant` would carry no information, cost a nonzero
storage word and add a refusal every SDK must mirror.

```text
files-content/1   [bytesRef, version, carrier, hashAlg, length, sha256, cipher, nonce12,
                   plaintextLength, plaintextSHA256OrZero] ‖ media     media = body[320:]
files-external/1  [bytesRef, version, carrier, hashAlg, length, sha256, locatorLength]
                   ‖ locator ‖ media                                  media = body[224 + locatorLength:]
```

- **The tail is final.** Because the media string is the remainder of the body, nothing can ever be appended after
  it: any further field for `files-content/1` or `files-external/1` needs a new Type, not an appended trailing field.
- **Absent is unknown.** An empty tail (a 320-byte content body, a location that ends with its locator) means the
  author did not say; a reader falls back to the name's extension.
- **The grammar** (`FilesProfile.mediaTypeRefusal`, shared by both rules): at most 255 bytes of `type "/" subtype
  [";" parameters]`. `type` and `subtype` are RFC 6838 restricted-names in **lowercase only**: 1..127 bytes, the first
  `a-z` or `0-9`, the rest `a-z`, `0-9` or one of `! # $ & - ^ _ . +`. Exactly one `/` comes before the first `;` (or
  the end). Everything from the first `;` to the end is printable ASCII including space (0x20..0x7e) and is not
  parsed further, so `video/mp4; codecs="avc1.42E01E, mp4a.40.2"` keeps its case and spaces, and `text/plain;` is
  admitted. No space or tab may come before the first `;`. The canonical form is `text/html; charset=utf-8`.
- **Why the chain checks it.** The `web3://` gateway emits the string in an HTTP header, so no control byte (CR, LF,
  NUL, tab) may ever be admitted; and a client compares `type/subtype` byte for byte to decide how to render, so mixed
  case cannot be admitted. Where this is stricter than RFC 6838 / RFC 9110 (uppercase names, whitespace or a tab
  before `;`, a tab after it, `*` wildcards, non-ASCII parameter bytes) the vectors say so case by case.
- **The SDK normalizes and refuses before it builds the plan.** It lowercases the type and subtype, and refuses an
  invalid string (with the grammar's reason) when it builds the plan, so a bad media type is never an on-chain
  revert. The chain never normalizes: `Text/HTML` is refused, not lowercased.
- **Refusal codes.** `files-content/1`: 2 the body is shorter than 320 bytes, 11 the media tail is longer than 255
  bytes (a body above 575), 12 the grammar. `files-external/1`: 5 `locatorLength` outside 1..2,048 or the body shorter
  than `224 + locatorLength`, 8 the media tail is longer than 255 bytes, 9 the grammar. There is no "length does not
  match" case. The grammar's own reason (1..6) is returned by `mediaTypeRefusal` for a direct call.
- **Encrypted content** (cipher 1): the media type is public metadata about the plaintext. An author who does not want
  to disclose it leaves it empty.
- **Vectors.** `test/vectors/media.json` (`efs/vectors/media/1`, generated by `tools/media-vectors.mjs` through `pnpm
  release`, checked by `pnpm release:check`, asserted in `test/profiles/FilesMediaType.t.sol` against the grammar,
  both rules, `EfsFiles`, `Keys` and the release Type ids): encoded bodies with their Type and record ids, and about
  forty media strings with the grammar's code and each rule's code. Strings with non-printable bytes are hex only.

What it costs (measured 2026-11-25, `test/integration/MediaTypeMeasure.t.sol`, one cooled publication per row, the
whole file: chunk or location, descriptor, CREATE, revision, name, two binds):

| Media type | Small on-chain file, prague | amsterdam | External file, prague | amsterdam |
|---|---:|---:|---:|---:|
| none (empty) | 2,546,193 (−2,824) | 9,194,047 (−2,700) | 2,277,302 (+149) | 8,294,860 (+137) |
| `image/png` (9 B) | 2,569,949 (+20,932) | 9,305,711 (+108,964) | 2,278,530 (+1,377) | 8,296,088 (+1,365) |
| `text/html; charset=utf-8` (24 B) | 2,571,526 (+22,509) | 9,307,300 (+110,553) | 2,302,820 (+25,667) | 8,408,310 (+113,587) |
| the 71-byte Word type | 2,621,387 (+72,370) | 9,533,037 (+336,290) | 2,330,045 (+52,892) | 8,523,443 (+228,720) |

In brackets: the change from the same file before media types (small file 2,549,017 / 9,196,747, external file
2,277,153 / 8,294,723), all measured. It is storage: the tail takes `ceil` of its bytes in new words, and nothing else
changes. With no media type a content descriptor is one (zero) word shorter than before, hence slightly cheaper. A
48-byte locator ends half way through a word, so a type of up to 16 bytes shares that word and costs an external
descriptor almost nothing.

The rules' own validation (the `accept` frame, `test/profiles/FilesMediaType.t.sol`, measured): `files-content/1`
4,419 gas with no media type, +1,141 for `image/png`, +2,526 for `text/html; charset=utf-8`, +6,473 for the docx type
and +22,297 for the 255-byte maximum; `files-external/1` (48-byte locator) 3,155, +1,119, +2,504, +6,451 and +22,275.
The grammar runs a byte at a time (about 87 gas a byte), far inside the 300,000 acceptor budget.

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

### The gateway as built (`EfsWeb3Gateway/1`)

`web3://<gateway>:<chainId>/<principal>[/<name>…][/][?lens=<principal>,<principal>…][&offset=<n>]`

- `<principal>` is 64 hex digits, `0x` + 64 hex digits, or `0x` + 40 hex digits for a key account (an EOA or an
  EIP-7702 account). A contract account in address form is `400`: its principal depends on the Realm, so name it by
  id. Hex is case-insensitive.
- `lens` adds fall-through principals after the path principal (64 in all at most). For each name the first
  principal with a live binding wins; a mask stops the walk (`404`); unset and released fall through.
- `offset` (decimal, default 0) is the first byte served. A large file is one chunk per response; the
  `web3-next-chunk` header carries the URL of the next one, so an ERC-7617 client streams the whole file.
- At most 32 names of 1..255 bytes. A trailing slash is ignored.

| Status | When |
|---|---|
| 200 | a file's bytes or one chunk of them; a directory as JSON `{"entries":[{"name","kind"}…],"complete":bool}` |
| 307 | the file is a `files-external/1` location; `Location` carries the URI, `x-efs-media-type` its declared media type |
| 400 | malformed principal, lens or offset; an empty name; too many names or principals |
| 404 | no such name, a hidden (masked) name, a file used as a folder, no revision, remote-only content |
| 416 | `offset` at or past the end (offset 0 of an empty file is `200`) |
| 500 | a broken Files invariant (wrong Type or length, a missing tree node) or a failed listing |
| 503 | another ledger layout, or a read the facet refuses |

Headers: `Content-Type` (a `files-content/1` descriptor's declared media type when it has one, else from the last
name's extension), `X-Content-Type-Options: nosniff` (only on a 200 that serves a declared media type, so a browser
cannot upgrade an author's `text/plain` to HTML; the extension path is unchanged and sends none), `Content-Length`
(the whole file), `x-efs-record` (the revision or directory record), `x-efs-sha256` (the descriptor's digest: for a
span tree and for an external location it is the author's claim, verify after reading), `x-efs-cipher`,
`x-efs-media-type` (on the 307 of a `files-external/1` location that declares one, so a client that does not follow
the redirect still learns it), `x-efs-listing: complete|partial`. A descriptor shorter than its words, or a location
whose locator length is 0 or runs past the body, is a 500. `request` never
reverts for anything a URL can cause. A directory lists one page of 64 entries; a longer directory is `partial`.

Measured in the suites (cold storage): an inline file 0.13M gas, an 8,160-byte chunk at tree depth 3 about 1.2M, a
7-entry listing 0.88M. A local fixture deploys the gateway (`readers.web3Gateway` in `efs-deployment.json`, with a
ready `seedUrl`) and `verify` reads the three seed files back through it, following `web3-next-chunk`.

**Open, with the directory questions:** the gateway is bound to one root `files-directory/1` record at construction
(the fixture's seed root). What a principal's root is (a shared Realm root, a home per principal) is not ruled; the
answer changes the gateway's constructor argument or its first path segment, and nothing in the kernel.

## What a size costs on chain (measured 2026-11-24)

Measured in `test/integration/FilesLargeFiles.t.sol` on both schedules (`docs/GAS-SCHEDULES.md`); the totals for
whole files are computed from those rows. A chunk is 8,160 file bytes in an 8,192-byte record.

| Row | Today (prague) | After Glamsterdam (amsterdam) |
|---|---:|---:|
| One more chunk in a publication | 6.09M | 28.88M |
| Per 1,000 file bytes | 0.75M | 3.54M |
| One more span node | 0.32M | 1.05M |
| A publication's fixed part | 0.39M | 1.28M |
| The finish (descriptor, revision, name, CREATE, two binds) | 1.50M | 5.31M |
| A two-chunk publication, measured whole | 12.57M | 59.04M |

What bounds one publication: the Realm limits allow 16,384 body bytes (two chunks). Today the 16.78M per-transaction
gas cap allows the same and no more: a third chunk would need 18.7M. After Glamsterdam the cap counts execution gas
only (about 3.8M per chunk, derived), so gas no longer binds per transaction; the total (59M for two chunks) then
has to fit the chain's block limit, which may force one chunk per publication.

| File | Chunks | Publications | Gas today | Gas after Glamsterdam | Wallet prompts, native lane | Prompts with a session |
|---|---:|---:|---:|---:|---:|---:|
| 100 KB | 13 | 7 | 87M | 402M | 7 | 1 |
| 1 MB | 123 | ≈ 64 | 815M | 3.77 billion | ≈ 64 | 1 |
| 10 MB | 1,226 | ≈ 638 | 8.11 billion | 37.5 billion | ≈ 638 | 1 |

A session (`docs/SESSION-LANE.md`) changes the prompt column only: the publications, the gas and the number of
transactions stay the same, plus an estimated 0.17M per publication today (0.8M after Glamsterdam). For scale, at a
60M block gas limit (an assumption, not checked against any chain) a 1 MB file is the gas of about 14 full blocks
today and a 10 MB file about 135. At a gas price of 1 gwei, 1 MB costs about 0.8 ETH today. Span publications are
bounded by gas before the 64-action limit (a span node costs about 0.38M when its children are cold, as they are in a transaction of its own, so about 43 reach the cap and 36 fit with headroom; the 0.32M row above was measured warm), so a client must split by the
gas quote and not only by action and byte counts.

## What changes in the repository

`src/profiles/` (the four rules above, the new `FilesSpanRule`, `FilesTypes`), `src/lib/EfsFiles.sol` (encoders, the
canonical chunker), the Files suites and fixtures, the genesis plan (ten Files Types), and
`src/periphery/EfsWeb3Gateway.sol` with `src/interfaces/IWeb3Gateway.sol`. The kernel, the registry, the index, the readers' laws and the final
validator are untouched.
