import fs from "node:fs";
import path from "node:path";

const [agentId, outputFile] = process.argv.slice(2);
if (!agentId || !outputFile) throw new Error("usage: stage-agent-pr <agent-id> <runner-output-json>");
if (!["triage-developer", "source-sentinel-investigator"].includes(agentId)) throw new Error(`${agentId} may not stage pull requests`);
const defaultRoot = path.resolve(import.meta.dirname, "../..");
const root = process.env.TC_PROPOSAL_ROOT ? path.resolve(process.env.TC_PROPOSAL_ROOT) : defaultRoot;
if (process.env.TC_PROPOSAL_ROOT && root === path.parse(root).root) throw new Error("proposal root cannot be a filesystem root");
const runner = JSON.parse(fs.readFileSync(path.resolve(outputFile), "utf8"));
const proposal = runner.finalOutput;
if (!proposal || typeof proposal !== "object" || !Array.isArray(proposal.files)) throw new Error("runner output omitted a pull-request proposal");
if (!/^agent\/[a-z0-9][a-z0-9-]{2,100}$/.test(proposal.branch ?? "")) throw new Error("proposal branch is invalid");
if (proposal.requiresOperator === true) {
  if (proposal.files.length !== 0) throw new Error("operator-only proposals must not contain repository changes");
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `branch=${proposal.branch}\n`);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=${String(proposal.title).replaceAll("\n", " ")}\n`);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, "requires_operator=true\n");
    fs.appendFileSync(process.env.GITHUB_OUTPUT, "has_changes=false\n");
  }
  console.log(JSON.stringify({ ok: true, agentId, branch: proposal.branch, files: [], requiresOperator: true }));
  process.exit(0);
}
if (proposal.requiresOperator !== false) throw new Error("proposal requiresOperator flag is missing");
if (proposal.files.length === 0) throw new Error("autonomous pull-request proposals require at least one file change");
for (const file of proposal.files) {
  const normalized = String(file.path).replaceAll("\\", "/");
  if (normalized.startsWith("/") || normalized.includes("../") || normalized.startsWith(".github/workflows/") || /(^|\/)(\.env|\.dev\.vars|secrets?)(\/|$)/i.test(normalized)) throw new Error(`forbidden PR path: ${normalized}`);
  if (agentId === "source-sentinel-investigator" && !(
    normalized === "platform/config/source-contracts.json"
    || normalized.startsWith("platform/apps/daily/src/source-contracts")
    || normalized.startsWith("platform/agents/evals/source-sentinel-investigator")
    || normalized.startsWith("grocery/tests/fixtures/")
  )) throw new Error(`source sentinel path is outside its allowlist: ${normalized}`);
  const target = path.resolve(root, normalized);
  if (!target.startsWith(`${root}${path.sep}`)) throw new Error(`path escapes repository: ${normalized}`);
  const exists = fs.existsSync(target);
  if (file.operation === "create" && exists) throw new Error(`create target already exists: ${normalized}`);
  if (file.operation === "update" && !exists) throw new Error(`update target does not exist: ${normalized}`);
  const content = String(file.content);
  if (!content.trim()) throw new Error(`refusing an empty repository file: ${normalized}`);
  if (file.operation === "update") {
    const existingContent = fs.readFileSync(target, "utf8");
    if (existingContent === content) throw new Error(`refusing a no-op repository update: ${normalized}`);
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content, "utf8");
}
if (process.env.GITHUB_OUTPUT) {
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `branch=${proposal.branch}\n`);
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=${String(proposal.title).replaceAll("\n", " ")}\n`);
  fs.appendFileSync(process.env.GITHUB_OUTPUT, "requires_operator=false\n");
  fs.appendFileSync(process.env.GITHUB_OUTPUT, "has_changes=true\n");
}
console.log(JSON.stringify({ ok: true, agentId, branch: proposal.branch, files: proposal.files.map((file) => file.path), requiresOperator: false }));
