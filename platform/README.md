# Thrifty Crew Grocery Platform v3

This workspace is the shadow-first replacement for the PowerShell/Git/Ghost-injection grocery estate. The
legacy pipeline remains authoritative until every gate in `docs/IMPLEMENTATION-CONTRACT.md` passes. Authored
grocery configuration is the exception: `config/` is the single source and generates the legacy JSON files.

## Runtime

- Production and CI: Node 22
- Package manager: pnpm 11.16.0
- Local development may use a newer Node release, but CI is the compatibility authority.

## Commands

```text
pnpm install
pnpm check
pnpm db:migrate:local
pnpm dev
pnpm tc help
pnpm tc config check
pnpm tc run daily --dry
TC_LOCAL_MUTATION_SECRET=... pnpm tc replay
```

The new Worker uses its own name (`tc-grocery-v3`) and isolated D1/R2/Analytics Engine bindings. It cannot overwrite the current
`smp-feed` Worker unless a later, explicit production cutover changes the routing configuration.

Build and publish the direct-only native release with the operator CLI. The command first selects the
currently promoted direct batch IDs, computes every board cell and recipe cost from that immutable
snapshot, excludes incomplete recipes from Top 5/free rotation, runs server-side hard guards, and only
then swaps the Omaha release pointer:

```powershell
pnpm tc engine build-native native-release.json
pnpm tc engine publish-native
```

`tc replay` reads the newest ignored local comparison artifact and the tracked upstream recipe-basis
snapshot. `replay:current` signs every mutation, writes evidence and large payloads to local R2, validates all
server-owned hard guards, and publishes only when the release is complete. The bridge keeps single-store
recipe bases private while the public comparison continues to require multi-store coverage.

PC credentials and Ghost credentials belong in Cloudflare secrets, never the repository. GitHub Actions gets a
short-lived OIDC identity (`id-token: write`) bound to the repository and workflow; it does not use a static ingest
secret. Remote resources, beta routing, entitlements, and cutover remain explicit rollout steps.
