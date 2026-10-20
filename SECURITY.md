# Security status

The contracts are under implementation from [docs/DESIGN.md](docs/DESIGN.md); there is no
deployment to assess, and passing CI is not a security review. The design's privileged-path
register (§2.2) and the disclosed residuals that any deployment must state are:

- **Administrator power before the freeze.** Until `freeze()` runs, the controller owner can
  install any implementation by activation (disclosed in `describe().controllerOwner`).
- **Declared dependency classes.** A Type's `dependencyClass` is the creator's claim, never a
  proof; a proxied or state-reading rule stays behaviour-mutable by whoever controls it.
- **Relayer gas exposure.** Acceptor and index gas are availability floors, so a hostile Type in
  a signed plan can burn the submitter's `tx.gas`; relayers simulate and bound their gas limit.
- **Log-only retention.** Under the default retention profile, read-set preimages and ERC-1271
  witness bytes live in logs; such rows are graded `UNKNOWN` for portability.

For a security concern, contact the repository owner privately. Do not put secrets, private
keys or sensitive reproduction data in a public issue. A disclosure and response policy is
reviewed before the first public deployment.
