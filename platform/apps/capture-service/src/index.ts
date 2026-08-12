/**
 * Persistent typed capture daemon entrypoint.
 *
 * The service owns durable work leases, per-store isolation, adaptive rate
 * control, challenge callbacks, crash-resume journals, and Parquet-bound
 * capture commits. PowerShell is retained only as the Windows process
 * supervisor; it no longer owns capture state or orchestration decisions.
 */
import "../../operator/src/capture-controller";
