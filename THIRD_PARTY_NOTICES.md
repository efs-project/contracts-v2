# Third-party notices

The repository's MIT license applies to original software and does not replace dependency
licenses or license any user content stored through EFS.

| Dependency | Version | License | Where the license text is kept | Used by |
| --- | --- | --- | --- | --- |
| `forge-std` ([foundry-rs/forge-std](https://github.com/foundry-rs/forge-std/releases/tag/v1.17.0)) | **1.17.0** | MIT OR Apache-2.0 | `dependencies/forge-std-1.17.0/LICENSE-MIT`, `LICENSE-APACHE` (installed through Soldeer with the recorded archive checksum and extracted integrity) | tests and scripts only; never imported by production sources |
| `@openzeppelin-contracts` ([OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.6.1)) | **5.6.1** | MIT | `licenses/openzeppelin-contracts-5.6.1-LICENSE.txt` (the Soldeer archive ships the `contracts/` tree without the license file, so the text is vendored here verbatim) | proxies, `ProxyAdmin`, `Initializable`, ERC-1967 utilities, transient-slot helpers in `src/core`, `src/types`, `src/control` |
| `@openzeppelin-contracts-upgradeable` ([OpenZeppelin/openzeppelin-contracts-upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/releases/tag/v5.6.1)) | **5.6.1** | MIT | `licenses/openzeppelin-contracts-upgradeable-5.6.1-LICENSE.txt` | upgradeable base contracts in `src/core`, `src/types` |

OpenZeppelin 5.6.1 is the npm `latest` (audited) release; 5.7.0 is on the `dev` tag ("Final but not
audited") and was deliberately not pinned. The proxy, `ProxyAdmin`, `Initializable` and transient-slot
sources are identical between the two.

Foundry, solc, Node and pnpm are contributor tools with their own upstream licenses. Vendored third-party
Solidity (if any is ever added, for example the Optimism trie libraries for periphery proofs) lives under
`src/periphery/vendor/` with its own `LICENSE` and `NOTICE` files and is listed in this table.
