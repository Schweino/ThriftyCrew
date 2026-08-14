param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('Triage','PostPublish','SourceSentinel','Recipe','RecipeCompletion','IngredientPricing','IngredientPublication','Accuracy')]
  [string]$Cycle,
  [ValidateRange(1,50)][int]$MaxItems = 1,
  [ValidateRange(0,10)][int]$PricingWorkerSlot = 0,
  [ValidateRange(0,4)][int]$RecipeWorkerSlot = 0,
  [ValidateRange(0,2)][int]$CompletionWorkerSlot = 0,
  [string]$OnlyAgent,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
$platformRoot = [string]$config.platformRoot
$incomeRoot = [string]$config.incomeRoot
$pnpmPath = [string]$config.pnpmPath
$logSuffix = if ($Cycle -eq 'IngredientPricing' -and $PricingWorkerSlot -gt 0) { "-{0}" -f $PricingWorkerSlot }
  elseif ($Cycle -eq 'Recipe' -and $RecipeWorkerSlot -gt 0) { "-shard-{0}" -f $RecipeWorkerSlot } else { '' }
$logFile = Join-Path ([string]$config.logRoot) ("agent-{0}{1}.log" -f $Cycle.ToLowerInvariant(), $logSuffix)
$outputBase = Join-Path (Split-Path -Parent ([string]$config.logRoot)) 'agent-output'
$registry = Read-PcUtf8Json (Join-Path $platformRoot 'config\agents.json')

$cycleAgents = @{
  Triage = @('triage-reviewer','triage-developer')
  PostPublish = @('post-publish-reviewer')
  SourceSentinel = @('source-sentinel-investigator')
  Recipe = @('recipe-sourcer','recipe-deduper','recipe-fact-extractor','recipe-mapper','recipe-writer','recipe-auditor')
  RecipeCompletion = @('recipe-writer','recipe-auditor')
  IngredientPricing = @()
  IngredientPublication = @('ingredient-definition-planner')
  Accuracy = @('accuracy-headless')
}
$jobByCycle = @{
  Triage = 'triage-review'
  PostPublish = 'post-publish-review'
  SourceSentinel = 'source-sentinel-daily'
  Recipe = 'recipe-pack-weekly'
  Accuracy = 'accuracy-verdict'
}
$agentsForCycle = @($cycleAgents[$Cycle])
$script:ingredientProposalFiles = [Collections.Generic.List[string]]::new()
$script:ingredientConfigurationChanged = $false
if ($Cycle -ne 'IngredientPricing' -and $PricingWorkerSlot -ne 0) {
  throw 'PricingWorkerSlot is valid only for the IngredientPricing cycle'
}
if ($Cycle -ne 'RecipeCompletion' -and $CompletionWorkerSlot -ne 0) {
  throw 'CompletionWorkerSlot is valid only for the RecipeCompletion cycle'
}
if ($OnlyAgent) {
  if ($OnlyAgent -notin $agentsForCycle) {
    throw "Agent '$OnlyAgent' is not registered for the $Cycle cycle"
  }
  $agentsForCycle = @($OnlyAgent)
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

function Apply-PendingIngredientProposals([int]$BatchSize = 20) {
  $publicationLock = $null
  for ($attempt = 0; $attempt -lt 360 -and -not $publicationLock; $attempt++) {
    $publicationLock = Enter-PcRuntimeLock 'ingredient-config-publication' 300
    if (-not $publicationLock) { Start-Sleep -Seconds 5 }
  }
  if (-not $publicationLock) { throw 'ingredient configuration publication lock remained occupied for 30 minutes' }
  $branch = @(git -C $incomeRoot branch --show-current)
  if ($LASTEXITCODE -ne 0 -or [string]$branch[0] -ne 'main') {
    Exit-PcRuntimeLock $publicationLock
    throw 'automatic ingredient publication requires the checked-out main branch'
  }
  $scopedPaths = @(
    'platform/config/commodities.json', 'platform/config/categories.json',
    'grocery/commodity-search.json', 'grocery/commodities.json', 'grocery/categories.json',
    'platform/config/manifest.json'
  )
  $dirty = @(git -C $incomeRoot status --porcelain -- $scopedPaths)
  if ($LASTEXITCODE -ne 0) {
    Exit-PcRuntimeLock $publicationLock
    throw 'could not inspect ingredient configuration paths'
  }
  if ($dirty.Count -gt 0) {
    Exit-PcRuntimeLock $publicationLock
    throw "ingredient configuration paths already contain uncommitted work: $($dirty -join '; ')"
  }
  git -C $incomeRoot fetch origin main
  if ($LASTEXITCODE -ne 0) {
    Exit-PcRuntimeLock $publicationLock
    throw 'could not refresh origin/main before ingredient publication'
  }
  git -C $incomeRoot merge --ff-only origin/main
  if ($LASTEXITCODE -ne 0) {
    Exit-PcRuntimeLock $publicationLock
    throw 'ingredient publication checkout could not fast-forward to origin/main'
  }
  $committed = $false
  try {
    Set-PcRuntimeCredential $config 'local-operator'
    Invoke-LoggedCommand 'ingredient-config-apply-ready' { & $pnpmPath tc ingredient apply-ready $BatchSize } | Out-Null
    $changed = @(git -C $incomeRoot status --porcelain -- $scopedPaths)
    if ($LASTEXITCODE -ne 0) { throw 'could not inspect recovered ingredient configuration changes' }
    if ($changed.Count -eq 0) { return }
    Invoke-LoggedCommand 'ingredient-config-full-check' { & $pnpmPath check } | Out-Null
    git -C $incomeRoot add -- $scopedPaths
    if ($LASTEXITCODE -ne 0) { throw 'could not stage verified ingredient configuration' }
    git -C $incomeRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { throw 'available ingredient research produced no configuration change' }
    git -C $incomeRoot commit -m 'Add verified Omaha ingredient coverage'
    if ($LASTEXITCODE -ne 0) { throw 'could not commit verified ingredient configuration' }
    $committed = $true
    git -C $incomeRoot push origin HEAD:main
    if ($LASTEXITCODE -ne 0) { throw 'could not push verified ingredient configuration to main' }
    Invoke-LoggedCommand 'ingredient-config-deploy' { & $pnpmPath tc config deploy } | Out-Null
    $script:ingredientConfigurationChanged = $true
  } catch {
    if (-not $committed) {
      git -C $incomeRoot restore --staged --worktree -- $scopedPaths 2>&1 | ForEach-Object { Write-PcRuntimeLog $logFile ("ingredient-config-rollback: {0}" -f $_) }
    }
    throw
  } finally {
    Exit-PcRuntimeLock $publicationLock
    $script:ingredientProposalFiles.Clear()
  }
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
      if ($AgentId -eq 'ingredient-price-researcher') { $script:ingredientProposalFiles.Add($runnerFile) }
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

function Publish-ReadyRecipeContent {
  $dailyEngineLock = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\locks\platform-job-daily-engine.lock'
  if (Test-Path -LiteralPath $dailyEngineLock) {
    throw 'grocery publication deferred because daily-engine owns the capture and publication coordinator'
  }
  Set-PcRuntimeCredential $config 'local-operator'
  Push-Location $platformRoot
  try {
    Invoke-LoggedCommand 'recipe-browser-capture-promote-ready' { & $pnpmPath tc capture promote-ready-browser } | Out-Null
    Invoke-LoggedCommand 'recipe-content-promote-ready' { & $pnpmPath tc content promote-ready $env:TC_SCHEDULED_FOR } | Out-Null
    Invoke-LoggedCommand 'recipe-content-publish-native' { & $pnpmPath tc engine publish-native } | Out-Null
  } finally { Pop-Location }
}
if ($Cycle -ne 'Recipe' -and $RecipeWorkerSlot -ne 0) { throw 'RecipeWorkerSlot is valid only for the Recipe cycle' }
if ($RecipeWorkerSlot -gt 0 -and $OnlyAgent) { throw 'RecipeWorkerSlot cannot be combined with OnlyAgent' }

function Start-IngredientPricingDrain {
  $supervisorScript = Join-Path $platformRoot 'scripts\run-ingredient-campaign-supervisor.ps1'
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $supervisorScript))
  Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
  Write-PcRuntimeLog $logFile 'recipe-mapper queued or advanced ingredient gaps; ensured the supervised pricing and batch-publication coordinator is running'
}

function Invoke-IngredientDownstreamDrain {
  $downstreamLock = $null
  for ($attempt = 0; $attempt -lt 12 -and -not $downstreamLock; $attempt++) {
    $downstreamLock = Enter-PcRuntimeLock 'ingredient-recipe-downstream' 300
    if (-not $downstreamLock) { Start-Sleep -Seconds 5 }
  }
  if (-not $downstreamLock) { throw 'ingredient recipe completion lock remained occupied for one minute' }
  try {
    $contentAdvanced = $false
    foreach ($agentId in @('recipe-writer','recipe-auditor')) {
      for ($item = 0; $item -lt $MaxItems; $item++) {
        if (-not (Invoke-AgentItem $agentId)) { break }
        $contentAdvanced = $true
      }
    }
    if ($contentAdvanced) { Publish-ReadyRecipeContent }
  } finally {
    Exit-PcRuntimeLock $downstreamLock
  }
}

if ($SelfTest) {
  if ($Cycle -in @('Recipe','RecipeCompletion','IngredientPricing','IngredientPublication')) {
    $authPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { throw 'Codex ChatGPT authentication is not configured' }
    $auth = Read-PcUtf8Json $authPath
    if ([string]$auth.auth_mode -ne 'chatgpt' -or [string]$auth.OPENAI_API_KEY) { throw 'Recipe execution requires ChatGPT OAuth and prohibits API-key billing' }
  } elseif (-not [Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')) {
    throw 'OPENAI_API_KEY is not configured for this API-backed agent cycle'
  }
  foreach ($agentId in $agentsForCycle) { Set-PcRuntimeCredential $config $agentId }
  Set-PcRuntimeCredential $config 'local-operator'
  Write-Output "PC agent cycle self-test passed for $Cycle"
  exit 0
}

$lockName = if ($Cycle -eq 'IngredientPricing' -and $PricingWorkerSlot -gt 0) {
  "agent-cycle-ingredientpricing-{0}" -f $PricingWorkerSlot
} elseif ($Cycle -eq 'RecipeCompletion' -and $CompletionWorkerSlot -gt 0) {
  "agent-cycle-recipecompletion-{0}" -f $CompletionWorkerSlot
} elseif ($Cycle -eq 'Recipe' -and $RecipeWorkerSlot -gt 0) {
  "agent-cycle-recipe-shard-{0}" -f $RecipeWorkerSlot
} else {
  "agent-cycle-{0}" -f $Cycle.ToLowerInvariant()
}
$lock = Enter-PcRuntimeLock $lockName 300
if (-not $lock) { Write-PcRuntimeLog $logFile 'another instance holds the cycle lock; standing down'; exit 0 }
$job = if ($Cycle -eq 'Recipe' -and $RecipeWorkerSlot -gt 0) { $null } else { $jobByCycle[$Cycle] }
$env:TC_SCHEDULED_FOR = (Get-Date).ToUniversalTime().ToString('o')
if ($job) {
  $env:TC_JOB_RUN_ID = "run_{0}_pc-{1}" -f $job, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $env:TC_JOB_LEASE_FILE = Join-Path ([string]$config.logRoot) ("lease-{0}.json" -f ($env:TC_JOB_RUN_ID -replace '[^a-zA-Z0-9_-]', '-'))
}
$failed = $false
$jobStarted = $false
try {
  if ($job) {
    Set-PcRuntimeCredential $config 'local-operator'
    Push-Location $platformRoot
    try {
      $start = Invoke-LoggedCommand 'job-ledger-start' { & $pnpmPath tc job start $job } -AllowFailure
      if ($start.ExitCode -eq 75) { Write-PcRuntimeLog $logFile 'control-plane lease is held; standing down'; exit 0 }
      if ($start.ExitCode -ne 0) { throw "job-ledger-start failed with exit code $($start.ExitCode)" }
      $jobStarted = $true
    }
    finally { Pop-Location }
  }
  if ($Cycle -eq 'Recipe' -and $RecipeWorkerSlot -gt 0 -and -not $OnlyAgent) {
    for ($round = 0; $round -lt $MaxItems; $round++) {
      $roundProgress = $false
      foreach ($agentId in @('recipe-fact-extractor','recipe-mapper')) {
        if (Invoke-AgentItem $agentId) {
          $roundProgress = $true
          if ($agentId -eq 'recipe-mapper') { Start-IngredientPricingDrain }
        }
      }
      if (-not $roundProgress) { break }
    }
  } elseif ($Cycle -eq 'Recipe' -and -not $OnlyAgent) {
    for ($round = 0; $round -lt $MaxItems; $round++) {
      $roundProgress = $false
      foreach ($agentId in @('recipe-sourcer','recipe-deduper')) {
        if (Invoke-AgentItem $agentId) {
          $roundProgress = $true
        }
      }
      $shardProcesses = @()
      foreach ($slot in 1..4) {
        $shardArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $PSCommandPath),
          '-Cycle','Recipe','-RecipeWorkerSlot',[string]$slot,'-MaxItems',[string]$MaxItems)
        $shardProcesses += Start-Process -FilePath 'powershell.exe' -ArgumentList $shardArgs -WorkingDirectory $platformRoot -WindowStyle Hidden -PassThru
      }
      $shardProcesses | Wait-Process
      foreach ($process in $shardProcesses) {
        if ($process.ExitCode -ne 0) { throw "recipe shard worker $($process.Id) failed with exit code $($process.ExitCode)" }
      }
      if (-not $roundProgress) { break }
    }
    $contentAdvanced = $false
    foreach ($agentId in @('recipe-mapper','recipe-writer','recipe-auditor')) {
      for ($item = 0; $item -lt $MaxItems; $item++) {
        if (-not (Invoke-AgentItem $agentId)) { break }
        if ($agentId -in @('recipe-writer','recipe-auditor')) { $contentAdvanced = $true }
      }
    }
    if ($contentAdvanced) { Publish-ReadyRecipeContent }
  } elseif ($Cycle -eq 'IngredientPricing' -and -not $OnlyAgent) {
    $pricingAssignments = @{
      1 = @('bakers-saddle-creek','capture')
      2 = @('bakers-saddle-creek','qa')
      3 = @('family-fare-omaha-6401','capture')
      4 = @('family-fare-omaha-6401','qa')
      5 = @('hy-vee-omaha-1465','capture')
      6 = @('hy-vee-omaha-1465','qa')
    }
    if ($PricingWorkerSlot -gt 6) { throw 'IngredientPricing worker slots 1-6 map to the three independent headless producer/QA pools' }
    Set-PcRuntimeCredential $config 'local-operator'
    Push-Location $platformRoot
    try {
      if ($PricingWorkerSlot -eq 0) {
        Invoke-LoggedCommand 'ingredient-v3-pricing-coordinator' { & $pnpmPath tc ingredient pipeline tick coordinator } | Out-Null
      } else {
        $assignment = $pricingAssignments[$PricingWorkerSlot]
        Invoke-LoggedCommand ("ingredient-v3-pricing-{0}-{1}" -f $assignment[0],$assignment[1]) {
          & $pnpmPath tc ingredient pipeline tick $assignment[0] $assignment[1]
        } | Out-Null
      }
    }
    finally { Pop-Location }
  } elseif ($Cycle -eq 'RecipeCompletion' -and -not $OnlyAgent) {
    if ($CompletionWorkerSlot -eq 0) {
      Invoke-IngredientDownstreamDrain
    } else {
      $completionAgent = if ($CompletionWorkerSlot -eq 1) { 'recipe-writer' } else { 'recipe-auditor' }
      $contentAdvanced = $false
      for ($item = 0; $item -lt $MaxItems; $item++) {
        if (-not (Invoke-AgentItem $completionAgent)) { break }
        $contentAdvanced = $true
      }
      if ($CompletionWorkerSlot -eq 2 -and $contentAdvanced) { Publish-ReadyRecipeContent }
    }
  } elseif ($Cycle -eq 'IngredientPublication' -and -not $OnlyAgent) {
    for ($item = 0; $item -lt $MaxItems; $item++) {
      if (-not (Invoke-AgentItem 'ingredient-definition-planner')) { break }
    }
    Set-PcRuntimeCredential $config 'local-operator'
    $publishedGaps = 0
    Push-Location $platformRoot
    try {
      $readyResult = Invoke-LoggedCommand 'ingredient-v2-publication-ready' { & $pnpmPath --silent --filter '@thriftycrew/operator' tc ingredient publication-ready }
      $readyText = @($readyResult.Output) -join "`n"
      $readyStart = $readyText.IndexOf('{'); $readyEnd = $readyText.LastIndexOf('}')
      if ($readyStart -ge 0 -and $readyEnd -gt $readyStart) {
        $readyDocument = $readyText.Substring($readyStart, $readyEnd - $readyStart + 1) | ConvertFrom-Json
        # Publication is intentionally one ingredient per transaction. Matcher
        # surgery or release failure for one definition must never strand its
        # independently QA-verified siblings in the same sealed batch.
        $gapIds = @($readyDocument.gaps | Select-Object -First 1 | ForEach-Object { [string]$_.gap_id })
        if ($gapIds.Count -gt 0) {
          Invoke-LoggedCommand 'ingredient-v2-publish' { & $pnpmPath tc ingredient publish-v2 @gapIds } | Out-Null
          $publishedGaps = $gapIds.Count
        }
      }
    } finally { Pop-Location }
    if ($publishedGaps -gt 0) { Start-IngredientPricingDrain }
  } else {
    foreach ($agentId in $agentsForCycle) {
      for ($item = 0; $item -lt $MaxItems; $item++) {
        if (-not (Invoke-AgentItem $agentId)) { break }
      }
    }
  }
  if ($script:ingredientConfigurationChanged) {
    Invoke-LoggedCommand 'ingredient-immediate-grocery-refresh' {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $platformRoot 'scripts\run-pc-platform-job.ps1') -Job daily-engine
    } | Out-Null
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
  if ($env:TC_JOB_LEASE_FILE -and (Test-Path -LiteralPath $env:TC_JOB_LEASE_FILE)) { Remove-Item -LiteralPath $env:TC_JOB_LEASE_FILE -Force }
}
if ($failed) { exit 1 }
