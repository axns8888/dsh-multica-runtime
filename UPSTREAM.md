# Upstream and provenance

This is a private maintenance build; package name `@multica-ai/dsh-runtime`,
`private: true`, `UNLICENSED`, original copyright and full Git history remain.
No license grant is added. Redistribution requires the original rights holder's permission.

- Official upstream: `https://github.com/multica-ai/dsh-multica-runtime`
- User remote: `https://github.com/axns8888/dsh-multica-runtime`
- Baseline: `571d7c036d15f58ee88c89fd80afb0a6c7f0023c`
- Baseline version: `0.2.0-private.1`
- Verified on 2026-11-26 using authenticated Git ls-remote of BOTH repositories;
  both main branches named the baseline above. This is a fresh observation, not
  a claim based on a previous public snapshot. Checkout is not shallow.
- Maintenance version: `0.2.0-axns.1`; prerelease label distinguishes the build,
  not a promise of semver ordering relative to upstream's private label.
- Local branch: `agent/mika/54a3c223e412` (not the target of upstream changes).

User patches: version/repository metadata; pinned release toolchain; package
allowlist; checksums/build provenance; transactional install/rollback and strict
JSONL checks; explicit CI/Release workflows; Chinese operating instructions.
No controller, runner, dsh-as-mcp adapter, package identity or protocol change.
Dependency family remains locked to upstream's DSH 0.2.1-rc.2 for compile tests;
actual DSH 0.2.2-rc.5 is tested separately and must not be inferred from compilation.

For an upstream update, fetch upstream, inspect changes against this baseline,
retain history and license, update release-toolchain.json/upstream only after
review, resolve patches, run full tests and isolated install/rollback, increment
maintenance prerelease and collect new build information. Never merge a new
upstream or widen the engines range merely to bypass compatibility failure.

Return to official distribution when the required fixes are included and the
same native profile/protocol checks pass. Use the recorded profile backup first;
then install an explicitly selected official bundle through the same checksum
and backup discipline. No assumed npm availability or public release is claimed.
