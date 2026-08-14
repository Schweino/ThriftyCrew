-- @policy expand-contract
-- Bind every staged public version to the exact resolution-ready pricing job.
ALTER TABLE public_ingredient_versions ADD COLUMN pricing_job_id TEXT REFERENCES ingredient_pricing_jobs(id);
ALTER TABLE pipeline_agent_work_items_v4 ADD COLUMN input_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE pipeline_agent_work_items_v4 ADD COLUMN result_json TEXT;
CREATE UNIQUE INDEX public_ingredient_versions_pricing_job
  ON public_ingredient_versions(pricing_job_id) WHERE pricing_job_id IS NOT NULL;
PRAGMA optimize;
