# graph.db schema changes

**This file is APPENDED BY A TOOL, not by hand** (2026-09-09, backlog I41, ruled by Brad).
`python graph/audit_schema_change.py --accept --note "..."` writes an entry here and moves the
baseline in the same call. That is deliberate: it is the only way to clear the detector, so a
schema change cannot be made without leaving a record. A written procedure nobody is forced to
follow is an intention, and an intention has no exit code.

**`graph/sqlite/graph.db` has NO undo layer.** ~127 MB of live state, written nightly under WAL
and committed whole by the ~07:00 bot. Copy the file before running anything experimental
against it; `--accept` refuses unless you either name the backup or state why there is none.

**What this is NOT: a migration capability.** There is no expand-contract, no backfill and no
rollback here, and nothing in this estate currently knows how to do them. This file records
what changed and why. It does not help you undo it.

## 2026-09-09 - fingerprint `014da3370767862b`

**Why.** Founding baseline. No schema change was made - this records the shape as it stands so any future change is detected. Backlog I41.

**No backup taken.** Stated reason: Nothing was altered, so there is nothing to roll back to. Future accepts that follow a real change must name a backup.

Previous fingerprint: `(none - first record)`

- **Added:** `index:ix_alias_alias`, `index:ix_alias_kind`, `index:ix_ap_verdict`, `index:ix_cell_adto`, `index:ix_cell_asof`, `index:ix_cell_store`, `index:ix_dlog_run`, `index:ix_dlog_type`, `index:ix_edges_pred`, `index:ix_edges_src`, `index:ix_edges_tgt`, `index:ix_eval_at`, `index:ix_lp_status`, `index:ix_nodes_name`, `index:ix_nodes_type`, `index:ix_nodes_type_name`, `index:ix_po_cell`, `index:ix_po_commodity`, `index:ix_po_cycle`, `index:ix_po_store`, `index:ix_prov_method`, `index:ix_prov_run`, `index:ix_prov_source`, `index:ix_qv_status`, `table:aliases`, `table:approved_patches`, `table:cell_state`, `table:decision_log`, `table:edges`, `table:eval_runs`, `table:learning_proposals`, `table:nodes`, `table:price_observations`, `table:provenance`, `table:question_verdicts`, `view:v_cell_crown`, `view:v_current_cell`, `view:v_current_rows`, `view:v_price_why`
