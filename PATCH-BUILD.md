# Reviewed experimental GEOInflow build

This workflow rebuilds public upstream commit `6ba7c79d8d263ff620911fdccd90dd90be85dfb7` with the exact public patches listed in `patches/series.json`. It is not an official upstream release.

The changes preserve missing performance values, distinguish pageview and custom-event funnel steps, support explicitly unverified Vercel requests with genuinely missing IP/bytes, and show a separate authenticated aggregate history snapshot. No credentials, real visitor records, company source project, or actual historical snapshots are present in this repository.

A disposable loopback PostgreSQL database runs the schema and funnel semantics tests. All targeted tests must pass with no skipped cases, followed by the official Dockerfile build. The synthetic runtime probe uses a shared 900 MiB memory limit with a 256 MiB PostgreSQL child limit and JIT disabled. Its result is an installation smoke test, not a production capacity guarantee.

Only a successful probe permits exporting a never-started app root filesystem. Releases retain source and patch hashes, image identities, checksums, the upstream MIT license, and small synthetic test evidence. The workflow never deploys to a server and does not export or replace PostgreSQL/Redis data or root filesystems. Production upgrades require a separate scoped rollout and migration review.
