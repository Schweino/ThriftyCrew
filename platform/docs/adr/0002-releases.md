# ADR 0002: Immutable unified releases

Board cells, recipe costs, Top 5, rotation intent, feeds, and API payloads belong to one immutable release.
Publication changes one market pointer only after all server-owned hard guards pass. Ghost reconciliation is
recorded as the sole non-atomic external side effect.
