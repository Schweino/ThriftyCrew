# Authored grocery configuration

This directory is the only hand-edited authority for commodity definitions, category assignments, matching rules,
and known-wrong rulings during migration. Run `pnpm tc config generate` after an approved edit. The generator
atomically emits the byte-identical compatibility files under `grocery/` for the PowerShell estate; the v3 bridge
deploys the same content through the Worker configuration API.

Do not hand-edit the generated `grocery/commodities.json`, `grocery/categories.json`, or
`grocery/known-wrong.json`. CI runs `pnpm tc config check` and fails if either estate has drifted.
