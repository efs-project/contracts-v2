# Foundation scope and tooling choices

The September 26 contracts initialization plan (revision 2) supports Foundry as the
primary toolchain. James's October 6 clarification permits repository setup while
Fable's contract/link design remains pending. This checkout implements only that setup.

Pins are Foundry 1.8.3, solc 0.8.37, test-only forge-std 1.16.2, Node 24.21.0 and pnpm 12.6.0.
Node/pnpm align with the accepted sibling foundations. Soldeer records test dependency
archive checksum/integrity. No OpenZeppelin/proxy or upgrade-validation dependency is
selected before the architecture requires one.

Prague, optimizer 200 and via-IR are provisional compilation settings for the test fixture.
They do not establish the future protocol's compiler compatibility or identity policy.
Compiler metadata keeps its default IPFS hash; `bytecode_hash = "none"` is not selected.
These settings and the foundation source-empty check should be reviewed when implementation
is authorized. No EFS interface, module split, storage schema or release format is frozen.

The fixture checks Foundry cheatcodes/assertions and fuzzed storage round-trips in a test
contract. No production Solidity is present. CI performs the same standalone setup,
format/build/smoke and contributor checks as the documented local commands, with pinned
actions, hosted runners, read-only permissions and no deployment/publication path.
There are no placeholder security, upgrade, gas, index or recovery suites labeled passing.
