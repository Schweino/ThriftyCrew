import { normalizeName } from "@thriftycrew/domain";

type WorkItem = { id: string; agent_id: string; lease_owner: string | null; lease_generation: number;
  lease_expires_at: string | null; input_json: string };
type AdapterChunk = { version: number; phase: string; store: string; canary: Record<string, unknown>;
  terms?: Array<Record<string, unknown>>; rows?: Array<Record<string, unknown>> };

export type BackfillSubmission = { workItemId: string; owner: string; leaseGeneration: number;
  generationId: string; sessionId: string; document: AdapterChunk };

export function buildBackfillSubmissions(input: { role: "producer" | "verifier"; claim: unknown; chunk: unknown;
  generationPrefix: string; sessionPrefix: string; now?: Date }): BackfillSubmission[] {
  if (!input.generationPrefix.trim() || !input.sessionPrefix.trim()) throw new Error("backfill submission prefixes are required");
  const claim = input.claim as { workItems?: WorkItem[] };
  const chunk = input.chunk as AdapterChunk;
  if (!Array.isArray(claim?.workItems) || claim.workItems.length === 0) throw new Error("backfill claim has no work items");
  if (chunk?.version !== 2 || chunk.phase !== "discovery" || !Array.isArray(chunk.terms) || !Array.isArray(chunk.rows)) {
    throw new Error("backfill submission requires one discovery adapter chunk");
  }
  const now = (input.now ?? new Date()).getTime();
  const termByQuery = new Map<string, Record<string, unknown>>();
  for (const term of chunk.terms) {
    const query = normalizeName(String(term.query ?? ""));
    if (!query || termByQuery.has(query)) throw new Error("adapter chunk has missing or duplicate normalized queries");
    termByQuery.set(query, term);
  }
  const queriesByWork = new Map<string, string[]>();
  const workByQuery = new Map<string, string>();
  for (const work of claim.workItems) {
    if (!work.agent_id.startsWith(`omaha-price-${input.role}-`)) throw new Error(`claim mixes non-${input.role} work`);
    const payload = JSON.parse(work.input_json) as { queryTerms?: string[] };
    const queries = [...new Set((payload.queryTerms ?? []).map(normalizeName))].sort();
    if (queries.length === 0) throw new Error(`work item ${work.id} has no locked queries`);
    queriesByWork.set(work.id, queries);
    for (const query of queries) {
      const owner = workByQuery.get(query);
      if (owner && owner !== work.id) throw new Error(`claim has ambiguous duplicate locked query ${query}`);
      workByQuery.set(query, work.id);
    }
  }
  const outsideClaim = [...termByQuery.keys()].filter((query) => !workByQuery.has(query));
  if (outsideClaim.length) throw new Error(`adapter chunk contains ${outsideClaim.length} query terms outside the claim`);
  const selectedWork = claim.workItems.filter((work) => queriesByWork.get(work.id)!.every((query) => termByQuery.has(query)));
  if (selectedWork.length === 0) throw new Error("adapter chunk does not complete any exact claimed work item");
  const claimedQueries = new Set<string>();
  const submissions = selectedWork.map((work) => {
    if (!work.lease_owner || !Number.isInteger(Number(work.lease_generation)) || Number(work.lease_generation) < 1
      || !work.lease_expires_at || Date.parse(work.lease_expires_at) <= now) throw new Error(`claim lease is missing or expired for ${work.id}`);
    const queries = queriesByWork.get(work.id)!;
    const terms = queries.map((query) => {
      const term = termByQuery.get(query);
      if (!term) throw new Error(`adapter chunk omitted locked query ${query}`);
      claimedQueries.add(query);
      return term;
    });
    const querySet = new Set(queries);
    const rows = chunk.rows!.filter((row) => querySet.has(normalizeName(String(row.q ?? row.term ?? ""))));
    return { workItemId: work.id, owner: work.lease_owner, leaseGeneration: Number(work.lease_generation),
      generationId: `${input.generationPrefix}:${work.id}`, sessionId: `${input.sessionPrefix}:${work.id}`,
      document: { version: 2, phase: "discovery", store: chunk.store, canary: chunk.canary, terms, rows } };
  });
  const unclaimedTerms = [...termByQuery.keys()].filter((query) => !claimedQueries.has(query));
  if (unclaimedTerms.length) throw new Error(`adapter chunk contains ${unclaimedTerms.length} query terms outside the claim`);
  const claimedRows = new Set([...claimedQueries]);
  if (chunk.rows.some((row) => !claimedRows.has(normalizeName(String(row.q ?? row.term ?? ""))))) {
    throw new Error("adapter chunk contains rows outside the claim");
  }
  return submissions.sort((a, b) => a.workItemId.localeCompare(b.workItemId));
}
