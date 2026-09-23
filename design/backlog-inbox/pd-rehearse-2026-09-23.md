## rehearse-chain's self-test runs on every push because its key refusal is an accident, and a declaration today would open a stale pass

`OPEN` `2-WAY` `RUNG1 BUILD`

**Source.** Found building W0.5 of `design/PLAN-push-derived-conflicts-2026-09-23.md` (lane pd-rehearse, 2026-09-23). The
brief asked for the `# gate-inputs:` line of every changed self-test to be updated and verified with
`lib\gate-input-key.ps1 -VerifyDeclared`. `ops/rehearse-chain.ps1` has no such line, and adding one was deliberately
not done, for the reason below. `-VerifyDeclared ops\rehearse-chain.ps1` exits 1 with `declares nothing`.

**What is true today.** `Get-TcGateInputKey` refuses `ops/rehearse-chain.ps1 -SelfTest` with "builds a repo path from a
variable". The two spellings that trip it are `Join-Path $Repo $_` (the commit stage, which runs inside a scratch clone)
and `Join-Path $Root $Rel` (the self-test's fixture writer, which runs inside a temp repo). Neither reads this repo. So
the refusal is an accident, and the suite runs on every push that reaches run-gates: 18 s for one run before W0.5, and
28 to 31 s over the 8 mutation-probe runs after it (control 28 s).

**Why a declaration cannot simply be added.** The suite's two hook-membership cases (`Get-RhManifestSet $script:RhRoot
'HEAD'`) read `ops/chain-manifest.json` and the tree AT HEAD from git's object store. A per-gate key hashes WORKING-TREE
bytes. Suppose run-gates runs with an uncommitted manifest edit. It reads HEAD's old manifest, passes, and records that
pass under the key of the NEW bytes. After the commit the key is unchanged, so the pass replays over a manifest the suite
never read. That is the stale-pass class (`15b02198b`) the key exists to refuse. The same risk arrives silently if
someone renames either temp-repo variable, because the refusal would then go away by inference.

**The repair, in order.** (1) Make the two cases read the working-tree manifest. For example, build a temp repo holding
the working `ops/chain-manifest.json` and ask `Get-RhManifestSet` of that. (2) Then declare
`# gate-inputs: lib\*.ps1, ops\verify-bulk-edit.ps1, ops\hooks\pre-commit, ops\chain-manifest.json`. The whole `lib\` is
copied into fixture repos by directory enumeration, so a narrower list would miss one. (3) Run
`powershell -File lib\gate-input-key.ps1 -VerifyDeclared ops\rehearse-chain.ps1` and read exit 0. Everything else the
suite reads is a frozen blob by id: `08e1381de`, `ba13faba0^:ops/hooks/pre-commit`, and W0.5's `5126d59ab`. `ops/rehearse-chain.ps1` is in
the chain manifest, so this is a chain-touching push with its own rehearsal (about 14 minutes and one of 6 slots).
