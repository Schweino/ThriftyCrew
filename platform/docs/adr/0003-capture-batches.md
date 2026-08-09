# ADR 0003: Honest capture batches

Every source uses open, sealed, validated, promoted, rejected, superseded states with explicit coverage mode,
term/page outcomes, capture and ingestion times, idempotency, and evidence. Engine inputs are a sorted list of
promoted batch IDs selected before computation.
