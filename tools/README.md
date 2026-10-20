# Contributor tools

Run these from the repository root under the pinned Node runtime (`.node-version`, 24.21.0).

## checks.mjs

The contributor policy gate, run with `pnpm check`. It asserts the pinned Node and Foundry versions and
the compiler identity policy (solc 0.8.37, EVM `prague`, via-IR, 200 optimizer runs,
`bytecode_hash = "none"` with the CBOR trailer kept). It also checks the MIT SPDX header on every original
`.sol` and `.mjs` source, the dependency pins in `soldeer.lock` and their retained licenses, and the import
direction between `src/` layers. The script calls `forge --version` and `forge config --json` but never
compiles. A failure is an `AssertionError` that names the file or setting; success prints two `checks:`
lines with the versions and counts it verified.

## vectors.mjs

Writes the golden identity vectors for `src/lib/Keys.sol` to `test/vectors/ids.json`. Run it with
`pnpm vectors` after `pnpm install --frozen-lockfile`. It is the one tool with a dependency: viem's
`keccak256` and ABI encoder. The vectors come from an implementation independent of Solidity: `forge test`
reads the file, and the SDK's `Keys` twin must reproduce it bit for bit. Commit the regenerated file with any
change to a derivation. The output line names the file, the number of outputs and the vector `typeId`.

## attrib.mjs

Attributes a compiled contract's runtime bytes to source functions, selector wrappers and overhead, using
Foundry artifacts only. It needs ASTs, which the default profile does not emit, so build with
`forge build --ast` or `FOUNDRY_PROFILE=ci forge build`. Then run
`node tools/attrib.mjs out/<File>.sol/<Contract>.json [--out out] [--json report.json] [--diff old.json] [--top N]`.

The script decodes the source map, splits the code into basic blocks and names each block after the
function, modifier or public getter that owns most of its source-mapped bytes. Blocks with no named
instruction (contract-level or compiler-generated code) get an owner by reachability:

- **functions**: a definition's named blocks plus the helper blocks only it reaches.
- **selectors**: wrapper blocks that only one dispatcher entry reaches.
- **shared**: blocks with several owners.
- **unreached**: blocks with no owner.
- **dispatcher prefix**: blocks reached only from pc 0.
- **trailer**: bytes after the last mapped instruction. This is embedded data plus the CBOR metadata,
  whose length is read from the last two bytes.

The `reconciliation` line must show that the categories sum to the runtime length; on a mismatch the
script exits 1. `--json` writes `{contract, runtimeBytes, functions, selectors, shared, unreached,
dispatcherPrefix, trailer, detail}`. `--diff` compares the current build against such a file and lists
added, removed and changed functions and selectors, largest delta first, so a PR can quote its size
change. `--top 0` prints every row.

Read the numbers as source attribution, not call-graph cost. Via-IR inlines small functions, and an
inlined copy keeps its callee's source location. So `Keys.posting` counts every inlined copy across its
callers, and the callers' rows exclude it. Most via-IR instructions map to the whole contract or to no
source at all, and only blocks with at least one named instruction can carry a name. The
`source-map coverage` line shows how much of the code the source map resolved directly.

## layout.mjs

Generates the storage layout artifacts from the compiler, never by hand. Run `pnpm layout` after changing
any storage contract; `pnpm layout:check` (also run in CI) regenerates in memory and fails when a committed
file is stale. It runs `forge inspect` on the test-only probes in `test/harness/LayoutProbe.sol`, combines
each struct's member offsets with the ERC-7201 namespace roots, and writes `src/core/layout/Layout.sol`
(roots, member slot constants, mapping and array slot derivations, one unpacker per packed word,
`LAYOUT_ID` over the canonical ledger manifest), `vectors/layout.json` (the same manifest for the SDK's slot
codecs and the oracle) and the raw snapshots under `test/snapshots/layout/`. The generated Solidity is
passed through `forge fmt` so the check mode compares formatted output. A changed `LAYOUT_ID` means a
one-way door moved; `test/unit/Layout.t.sol` pins the id and proves typed writes and raw reads agree.
