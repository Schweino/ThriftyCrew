param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('Triage','PostPublish','SourceSentinel','Recipe','Accuracy')]
  [string]$Cycle,
  [ValidateRange(1,10)][int]$MaxItems = 1,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
$platformRoot = [string]$config.platformRoot
$incomeRoot = [string]$config.incomeRoot
$pnpmPath = [string]$config.pnpmPath
$logFile = Join-Path ([string]$config.logRoot) ("agent-{0}.log" -f $Cycle.ToLowerInvariant())
$outputBase = Join-Path (Split-Path -Parent ([string]$config.logRoot)) 'agent-output'
$registry = Read-PcUtf8Json (Join-Path $platformRoot 'config\agents.json')

$cycleAgents = @{
  Triage = @('triage-reviewer','triage-developer')
  PostPublish = @('post-publish-reviewer')
  SourceSentinel = @('source-sentinel-investigator')
  Recipe = @('recipe-sourcer','recipe-deduper','recipe-mapper','recipe-writer','recipe-auditor')
  Accuracy = @('accuracy-headless')
}
$jobByCycle = @{
  Triage = 'triage-review'
  PostPublish = 'post-publish-review'
  SourceSentinel = 'source-sentinel-daily'
  Recipe = 'recipe-pack-weekly'
  Accuracy = 'accuracy-verdict'
}

function Invoke-LoggedCommand([string]$Label, [scriptblock]$Command, [switch]$AllowFailure) {
  $prior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $output = & $Command 2>&1; $exitCode = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prior }
  foreach ($line in @($output)) { Write-PcRuntimeLog $logFile ("{0}: {1}" -f $Label, $line) }
  if ($null -eq $exitCode) { $exitCode = 0 }
  if ($exitCode -ne 0 -and -not $AllowFailure) { throw "$Label failed with exit code $exitCode" }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-GitHubApiContext {
  $lines = @('protocol=https','host=github.com','') | git credential fill
  $values = @{}
  foreach ($line in $lines) { if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1]] = $matches[2] } }
  if (-not $values.password) { throw 'Git Credential Manager did not return a GitHub token' }
  return [pscustomobject]@{
    Headers = @{ Authorization = "Bearer $($values.password)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'tc-local-agent' }
    Owner = 'Schweino'
    Repository = 'SimpleMoneyPlaybook'
  }
}

function Find-PullRequest($Github, [string]$Branch) {
  $head = [uri]::EscapeDataString(("{0}:{1}" -f $Github.Owner, $Branch))
  $uri = "https://api.github.com/repos/$($Github.Owner)/$($Github.Repository)/pulls?state=open&head=$head&per_page=1"
  return @(Invoke-RestMethod -Uri $uri -Headers $Github.Headers | Select-Object -First 1)
}

function Publish-AgentProposal([string]$AgentId, [string]$WorkItemId, [string]$RunnerOutputFile) {
  $runner = Read-PcUtf8Json $RunnerOutputFile
  $proposal = $runner.finalOutput
  if (-not $proposal) { throw 'agent runner output omitted finalOutput' }
  if ($proposal.requiresOperator) {
    Write-PcRuntimeLog $logFile ("{0}: proposal requires operator; no repository mutation attempted" -f $AgentId)
    return $null
  }
  if (@($proposal.files).Count -eq 0) { throw 'autonomous proposal did not contain file changes' }
  $github = Get-GitHubApiContext
  $existing = Find-PullRequest $github ([string]$proposal.branch)
  if ($existing.Count -gt 0) {
    Write-PcRuntimeLog $logFile ("{0}: existing PR reused: {1}" -f $AgentId, $existing[0].html_url)
    return [string]$existing[0].html_url
  }

  $remoteBranch = @(git -C $incomeRoot ls-remote --heads origin ([string]$proposal.branch))
  if ($LASTEXITCODE -ne 0) { throw 'could not inspect the proposed remote branch' }
  if ($remoteBranch.Count -eq 0) {
    git -C $incomeRoot fetch origin main
    if ($LASTEXITCODE -ne 0) { throw 'could not fetch origin/main for the isolated proposal worktree' }
    $worktreeRoot = Join-Path (Split-Path -Parent ([string]$config.logRoot)) 'agent-worktrees'
    New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null
    $safeId = ($WorkItemId -replace '[^a-zA-Z0-9_-]', '-')
    $worktree = Join-Path $worktreeRoot $safeId
    $resolvedParent = (Resolve-Path -LiteralPath $worktreeRoot).Path
    if (-not ([IO.Path]::GetFullPath($worktree).StartsWith($resolvedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'proposal worktree escaped its bounded root' }
    if (Test-Path -LiteralPath $worktree) { throw "proposal worktree already exists and is preserved for inspection: $worktree" }
    git -C $incomeRoot worktree add --detach $worktree origin/main
    if ($LASTEXITCODE -ne 0) { throw 'could not create the isolated proposal worktree' }
    $published = $false
    try {
      git -C $worktree switch -c ([string]$proposal.branch)
      if ($LASTEXITCODE -ne 0) { throw 'could not create the proposed local branch' }
      $priorProposalRoot = $env:TC_PROPOSAL_ROOT
      $env:TC_PROPOSAL_ROOT = $worktree
      try { Invoke-LoggedCommand 'stage-proposal' { & node (Join-Path $platformRoot 'scripts\stage-agent-pr.mjs') $AgentId $RunnerOutputFile } | Out-Null }
      finally { $env:TC_PROPOSAL_ROOT = $priorProposalRoot }
      Push-Location (Join-Path $worktree 'platform')
      try {
        Invoke-LoggedCommand 'proposal-install' { & $pnpmPath install --frozen-lockfile } | Out-Null
        Invoke-LoggedCommand 'proposal-check' { & $pnpmPath check } | Out-Null
      } finally { Pop-Location }
      git -C $worktree config user.name 'thriftycrew-local-agent'
      git -C $worktree config user.email 'actions@users.noreply.github.com'
      git -C $worktree add --all
      git -C $worktree diff --cached --quiet
      if ($LASTEXITCODE -eq 0) { throw 'proposal produced no staged repository change' }
      git -C $worktree commit -m ([string]$proposal.title)
      if ($LASTEXITCODE -ne 0) { throw 'could not commit the verified proposal' }
      git -C $worktree push origin ("HEAD:refs/heads/{0}" -f [string]$proposal.branch)
      if ($LASTEXITCODE -ne 0) { throw 'could not push the verified proposal branch' }
      $published = $true
    } finally {
      if ($published) {
        git -C $incomeRoot worktree remove $worktree 2>&1 | ForEach-Object { Write-PcRuntimeLog $logFile ("worktree-remove: {0}" -f $_) }
        git -C $incomeRoot worktree prune
      } else { Write-PcRuntimeLog $logFile ("proposal worktree preserved after failure: {0}" -f $worktree) }
    }
  }

  $body = @{ title = [string]$proposal.title; head = [string]$proposal.branch; base = 'main'; body = "Generated by the registered $AgentId on the authoritative local execution plane. The complete local quality gate passed. Deployment remains operator-owned." } | ConvertTo-Json
  try {
    $pr = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$($github.Owner)/$($github.Repository)/pulls" -Headers $github.Headers -ContentType 'application/json' -Body $body
  } catch {
    $existing = Find-PullRequest $github ([string]$proposal.branch)
    if ($existing.Count -eq 0) { throw }
    $pr = $existing[0]
  }
  Write-PcRuntimeLog $logFile ("{0}: PR opened: {1}" -f $AgentId, $pr.html_url)
  return [string]$pr.html_url
}

function Invoke-AgentItem([string]$AgentId) {
  $definition = $registry.agents | Where-Object { $_.id -eq $AgentId } | Select-Object -First 1
  if (-not $definition -or -not $definition.enabled -or $definition.plane -ne 'pc') { throw "$AgentId is not an enabled PC agent" }
  $subscriptionExecution = [string]$definition.provider -eq 'codex-chatgpt'
  $estimatedCostMicrousd = if ($subscriptionExecution) { 0 } else { 500000 }
  Set-PcRuntimeCredential $config $AgentId
  $stamp = "{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8))
  $outputRoot = Join-Path $outputBase ("{0}-{1}" -f $AgentId, $stamp)
  New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
  $claimFile = Join-Path $outputRoot 'claim.json'
  $evaluationFile = Join-Path $outputRoot 'evaluation-status.json'
  $authorizationFile = Join-Path $outputRoot 'authorization.json'
  $inputFile = Join-Path $outputRoot 'input.json'
  $runnerFile = Join-Path $outputRoot ("{0}.json" -f $AgentId)
  $claim = $null
  try {
    Push-Location $platformRoot
    try {
      Invoke-LoggedCommand "$AgentId-evaluation-status" { & $pnpmPath tc agent evaluation-status $AgentId $evaluationFile } | Out-Null
      $evaluation = Read-PcUtf8Json $evaluationFile
      if (-not $evaluation.current) { throw "$AgentId execution is blocked because its exact live evaluation is not current" }
      Invoke-LoggedCommand "$AgentId-claim" { & $pnpmPath tc agent claim $AgentId $claimFile } | Out-Null
      $claim = Read-PcUtf8Json $claimFile
      if (-not $claim.item) { Write-PcRuntimeLog $logFile ("{0}: no queued work" -f $AgentId); return $false }
      Invoke-LoggedCommand "$AgentId-authorize" { & $pnpmPath tc agent authorize $AgentId $claimFile $estimatedCostMicrousd $authorizationFile } | Out-Null
      $authorization = Read-PcUtf8Json $authorizationFile
      if (-not $authorization.allowed -or -not $authorization.modelId) { throw "$AgentId budget authorization was denied" }
      # Windows PowerShell 5.1's `-Encoding UTF8` writes a BOM. Node's strict
      # JSON.parse does not remove it, so agent inputs must be UTF-8 without BOM.
      [IO.File]::WriteAllText(
        $inputFile,
        ($claim.item.input | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false)
      )
      $env:TC_OUTPUT_ROOT = $outputRoot
      $env:TC_AGENT_INPUT_FILE = $inputFile
      $env:TC_AGENT_MODEL = [string]$authorization.modelId
      $env:TC_AGENT_PROMPT_HASH = [string]$definition.promptSha256
      $env:TC_AGENT_ESTIMATED_COST_MICROUSD = [string]$estimatedCostMicrousd
      $env:TC_AGENT_WORK_ITEM_ID = [string]$claim.item.id
      $savedBillingEnvironment = @{
        OPENAI_API_KEY = $env:OPENAI_API_KEY
        CODEX_API_KEY = $env:CODEX_API_KEY
        OPENAI_BASE_URL = $env:OPENAI_BASE_URL
      }
      try {
        if ($subscriptionExecution) {
          Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
          Remove-Item Env:CODEX_API_KEY -ErrorAction SilentlyContinue
          Remove-Item Env:OPENAI_BASE_URL -ErrorAction SilentlyContinue
        }
        Invoke-LoggedCommand "$AgentId-run" { & $pnpmPath --filter '@thriftycrew/agents' run run -- $AgentId } | Out-Null
      } finally {
        foreach ($name in $savedBillingEnvironment.Keys) {
          $value = $savedBillingEnvironment[$name]
          if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
          else { Set-Item "Env:$name" $value }
        }
      }
      if (-not (Test-Path -LiteralPath $runnerFile)) { throw "$AgentId did not produce its bounded runner output" }
      if ($AgentId -in @('triage-developer','source-sentinel-investigator')) { Publish-AgentProposal $AgentId ([string]$claim.item.id) $runnerFile | Out-Null }
      Invoke-LoggedCommand "$AgentId-complete" { & $pnpmPath tc agent complete $claimFile $runnerFile } | Out-Null
      return $true
    } finally { Pop-Location }
  } catch {
    Write-PcRuntimeLog $logFile ("{0}: FAILED: {1}" -f $AgentId, $_.Exception.Message)
    if ($claim -and $claim.item) {
      try {
        Set-PcRuntimeCredential $config $AgentId
        Push-Location $platformRoot
        try { Invoke-LoggedCommand "$AgentId-fail" { & $pnpmPath tc agent fail $claimFile ("local agent cycle failed: {0}" -f $_.Exception.Message) } | Out-Null }
        finally { Pop-Location }
      } catch { Write-PcRuntimeLog $logFile ("$AgentId-fail ledger update failed: {0}" -f $_.Exception.Message) }
    }
    throw
  }
}

if ($SelfTest) {
  if ($Cycle -eq 'Recipe') {
    $authPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { throw 'Codex ChatGPT authentication is not configured' }
    $auth = Read-PcUtf8Json $authPath
    if ([string]$auth.auth_mode -ne 'chatgpt' -or [string]$auth.OPENAI_API_KEY) { throw 'Recipe execution requires ChatGPT OAuth and prohibits API-key billing' }
  } elseif (-not [Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')) {
    throw 'OPENAI_API_KEY is not configured for this API-backed agent cycle'
  }
  foreach ($agentId in $cycleAgents[$Cycle]) { Set-PcRuntimeCredential $config $agentId }
  Set-PcRuntimeCredential $config 'local-operator'
  Write-Output "PC agent cycle self-test passed for $Cycle"
  exit 0
}

$lock = Enter-PcRuntimeLock ("agent-cycle-{0}" -f $Cycle.ToLowerInvariant()) 300
if (-not $lock) { Write-PcRuntimeLog $logFile 'another instance holds the cycle lock; standing down'; exit 0 }
$job = $jobByCycle[$Cycle]
$env:TC_JOB_RUN_ID = "run_{0}_pc-{1}" -f $job, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$env:TC_SCHEDULED_FOR = (Get-Date).ToUniversalTime().ToString('o')
$env:TC_JOB_LEASE_FILE = Join-Path ([string]$config.logRoot) ("lease-{0}.json" -f ($env:TC_JOB_RUN_ID -replace '[^a-zA-Z0-9_-]', '-'))
$failed = $false
$jobStarted = $false
try {
  Set-PcRuntimeCredential $config 'local-operator'
  Push-Location $platformRoot
  try {
    $start = Invoke-LoggedCommand 'job-ledger-start' { & $pnpmPath tc job start $job } -AllowFailure
    if ($start.ExitCode -eq 75) { Write-PcRuntimeLog $logFile 'control-plane lease is held; standing down'; exit 0 }
    if ($start.ExitCode -ne 0) { throw "job-ledger-start failed with exit code $($start.ExitCode)" }
    $jobStarted = $true
  }
  finally { Pop-Location }
  foreach ($agentId in $cycleAgents[$Cycle]) {
    for ($item = 0; $item -lt $MaxItems; $item++) {
      if (-not (Invoke-AgentItem $agentId)) { break }
    }
  }
} catch {
  $failed = $true
  Write-PcRuntimeLog $logFile ("CYCLE FAILED: {0}" -f $_.Exception.Message)
  Send-PcRuntimeAlert ("ThriftyCrew V3 local agent cycle failed: $Cycle") ("The bounded local $Cycle agent cycle failed.`n`n$($_.Exception.Message)`n`nLog: $logFile`n`nNo unverified proposal is merged or deployed automatically.")
} finally {
  if ($jobStarted) {
    try {
      Set-PcRuntimeCredential $config 'local-operator'
      $env:TC_GITHUB_JOB_STATUS = if ($failed) { 'failure' } else { 'success' }
      Push-Location $platformRoot
      try { Invoke-LoggedCommand 'job-ledger-finish' { & $pnpmPath tc job finish $job $env:TC_GITHUB_JOB_STATUS } | Out-Null }
      finally { Pop-Location }
    } catch {
      $failed = $true
      Write-PcRuntimeLog $logFile ("job-ledger-finish failed: {0}" -f $_.Exception.Message)
      Send-PcRuntimeAlert ("ThriftyCrew V3 agent ledger finish failed: $Cycle") ("The agent cycle could not record a terminal job state.`n`n$($_.Exception.Message)`n`nLog: $logFile")
    }
  }
  Exit-PcRuntimeLock $lock
  if (Test-Path -LiteralPath $env:TC_JOB_LEASE_FILE) { Remove-Item -LiteralPath $env:TC_JOB_LEASE_FILE -Force }
}
if ($failed) { exit 1 }
