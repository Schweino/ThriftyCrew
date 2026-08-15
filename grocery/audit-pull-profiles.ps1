<#
  audit-pull-profiles.ps1 - keeps each store's PACING honest.

  WHY IT EXISTS
  -------------
  2026-08-15: the Sam's sweep ran as a console snippet with no delay and tripped the bot wall after
  207 of 595 (id,term) pairs. The pacing that would have prevented it existed nowhere - not in a
  file, not in a script, only in whatever number was typed that day. Pacing is now versioned data
  in stores.json -> pull_profile, and each walled store has an agent module that reads it.

  A browser agent cannot read stores.json (the console has no filesystem), so every agent carries a
  MIRROR of its own profile constants. That is a duplicated constant, which is the class where a
  shared-source fix ships nothing because the caller keeps its own stale copy. This guard is what
  makes the duplication safe: it fails when the mirror and the registry disagree.

  IT ALSO ENFORCES THE ONE RULE THAT MATTERS FOR CORRECTNESS: a pull_profile records HOW to pull,
  never WHAT a store carries. A "known empty term" learned during a wall would silently stop being
  checked forever - unchecked is never not-carried.

  -SelfTest runs the frozen fixtures: the founding bug (a mirror that drifted from the registry)
  plus clean twins that must pass.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Keys that describe HOW to pull. Anything outside this set in a pull_profile is suspect; the
# CARRIAGE_WORDS check below is the one that actually blocks.
$script:PROFILE_KEYS = @(
  'agent', 'surface', 'delay_ms', 'jitter_ms', 'wall_limit', 'backoff_ms', 'retries',
  'confidence', 'evidence', 'identity_assert', 'wall_signals'
)
# A profile must never encode what a store stocks. These are the shapes that would do it.
$script:CARRIAGE_KEYS = @(
  'known_empty', 'empty_terms', 'not_carried', 'absent_terms', 'skip_terms',
  'carried', 'no_results', 'blocklist'
)
$script:VALID_CONFIDENCE = @('measured', 'proposed', 'unmeasured', 'n/a')

function Get-JsMirror {
  <# Pull the mirrored profile constants out of an agent module. #>
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  $txt = Get-Content $Path -Raw
  $m = [regex]::Match($txt, '(?s)_PROFILE\s*=\s*\{(.*?)\}')
  if (-not $m.Success) { return $null }
  $body = $m.Groups[1].Value
  $out = @{}
  foreach ($pair in @('delayMs:delay_ms', 'jitterMs:jitter_ms', 'retries:retries', 'backoffMs:backoff_ms', 'wallLimit:wall_limit')) {
    $js, $json = $pair -split ':'
    $mm = [regex]::Match($body, ('(?m)\b' + $js + '\s*:\s*(\d+)'))
    if ($mm.Success) { $out[$json] = [int]$mm.Groups[1].Value }
  }
  return $out
}

function Test-PullProfiles {
  param($Stores, [string]$Root)
  $problems = New-Object 'System.Collections.Generic.List[string]'

  foreach ($s in $Stores) {
    $name = [string]$s.name
    $p = $s.pull_profile
    if ($null -eq $p) { $problems.Add("$name : no pull_profile block"); continue }

    # 1) A profile must not encode carriage. This is the correctness rule, not a style rule.
    foreach ($k in $p.PSObject.Properties.Name) {
      if ($script:CARRIAGE_KEYS -contains $k.ToLower()) {
        $problems.Add("$name : pull_profile carries '$k' - a profile records HOW to pull, never WHAT a store stocks. A term learned empty during a wall would never be checked again.")
      }
    }

    # 2) Confidence must be one of the declared states, so an unmeasured rate can never read as safe.
    $conf = [string]$p.confidence
    if ($script:VALID_CONFIDENCE -notcontains $conf) {
      $problems.Add("$name : confidence '$conf' is not one of: $($script:VALID_CONFIDENCE -join ', ')")
    }

    # 3) Any pacing number at all requires evidence explaining where it came from.
    $hasPacing = ($null -ne $p.delay_ms)
    if ($hasPacing -and [string]::IsNullOrWhiteSpace([string]$p.evidence)) {
      $problems.Add("$name : has a delay_ms but no evidence - an unexplained rate is a guess")
    }
    if ($hasPacing -and $conf -eq 'n/a') {
      $problems.Add("$name : has a delay_ms but confidence 'n/a'")
    }

    # 4) THE DUPLICATED-CONSTANT GUARD: the agent's mirror must equal the registry.
    if ($p.agent) {
      $agentPath = Join-Path $Root ([string]$p.agent)
      if (-not (Test-Path $agentPath)) {
        $problems.Add("$name : pull_profile names agent '$($p.agent)' which does not exist")
      }
      else {
        $mirror = Get-JsMirror -Path $agentPath
        if ($null -eq $mirror) {
          $problems.Add("$name : agent '$($p.agent)' has no _PROFILE mirror to check against the registry")
        }
        else {
          foreach ($k in $mirror.Keys) {
            $reg = $p.$k
            if ($null -eq $reg) { continue }
            if ([int]$reg -ne [int]$mirror[$k]) {
              $problems.Add("$name : '$k' DRIFTED - stores.json says $reg, $($p.agent) mirrors $($mirror[$k]). Tune the registry, then copy it into the agent.")
            }
          }
        }
      }
    }
  }
  return $problems
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$label, [bool]$cond) {
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ }
  }

  # FOUNDING BUG: an agent mirror that disagrees with the registry must FIRE.
  $drift = @([pscustomobject]@{ name = 'DriftStore'; pull_profile = [pscustomobject]@{
      agent = '__fixture_agent.js'; delay_ms = 2600; jitter_ms = 1400; retries = 3
      backoff_ms = 20000; wall_limit = 3; confidence = 'proposed'; evidence = 'fixture' } })
  $fixDir = Join-Path $env:TEMP ('tc-pp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $fixDir | Out-Null
  try {
    # mirror says 200ms where the registry says 2600 - exactly the 2026-08-15 shape
    Set-Content -Path (Join-Path $fixDir '__fixture_agent.js') -Encoding UTF8 -Value @'
const SAMS_PROFILE = { delayMs: 200, jitterMs: 1400, retries: 3, backoffMs: 20000, wallLimit: 3 };
'@
    $r = Test-PullProfiles -Stores $drift -Root $fixDir
    Check "MUST-FIRE: a drifted agent mirror is caught" (@($r | Where-Object { $_ -match 'DRIFTED' }).Count -eq 1)

    # CLEAN TWIN: the same profile with a mirror that agrees must pass silently.
    Set-Content -Path (Join-Path $fixDir '__fixture_agent.js') -Encoding UTF8 -Value @'
const SAMS_PROFILE = { delayMs: 2600, jitterMs: 1400, retries: 3, backoffMs: 20000, wallLimit: 3 };
'@
    $r2 = Test-PullProfiles -Stores $drift -Root $fixDir
    Check "CLEAN TWIN: an agreeing mirror passes" ($r2.Count -eq 0)
  }
  finally { Remove-Item $fixDir -Recurse -Force -ErrorAction SilentlyContinue }

  # MUST-FIRE: a profile that encodes carriage.
  $carriage = @([pscustomobject]@{ name = 'CarriageStore'; pull_profile = [pscustomobject]@{
      agent = $null; delay_ms = $null; confidence = 'n/a'; evidence = 'x'
      known_empty = @('saffron', 'milk gallon') } })
  $r3 = Test-PullProfiles -Stores $carriage -Root $here
  Check "MUST-FIRE: a profile encoding carriage is rejected" (@($r3 | Where-Object { $_ -match 'known_empty' }).Count -eq 1)

  # MUST-FIRE: a pacing number with no evidence behind it.
  $noEv = @([pscustomobject]@{ name = 'GuessStore'; pull_profile = [pscustomobject]@{
      agent = $null; delay_ms = 1500; confidence = 'measured'; evidence = '' } })
  $r4 = Test-PullProfiles -Stores $noEv -Root $here
  Check "MUST-FIRE: an unexplained rate is rejected" (@($r4 | Where-Object { $_ -match 'no evidence' }).Count -eq 1)

  # CLEAN TWIN: a server-fed store with no pacing at all is legitimate.
  $server = @([pscustomobject]@{ name = 'ServerStore'; pull_profile = [pscustomobject]@{
      agent = $null; delay_ms = $null; confidence = 'n/a'; evidence = 'sanctioned feed' } })
  $r5 = Test-PullProfiles -Stores $server -Root $here
  Check "CLEAN TWIN: a server-fed store needs no pacing" ($r5.Count -eq 0)

  if ($fail) { Write-Output "PULL-PROFILE SELFTEST FAILED ($fail)"; exit 1 }
  Write-Output 'all self-tests pass'
  exit 0
}

$doc = Get-Content (Join-Path $here 'stores.json') -Raw | ConvertFrom-Json
$problems = Test-PullProfiles -Stores $doc.stores -Root $here

if ($problems.Count) {
  Write-Output "PULL-PROFILE PROBLEMS: $($problems.Count)"
  foreach ($p in $problems) { Write-Output "  $p" }
  Write-Output "PULL-PROFILE-COMPLETE problems=$($problems.Count)"
  exit 2
}

$measured = @($doc.stores | Where-Object { $_.pull_profile.confidence -eq 'measured' }).Count
$proposed = @($doc.stores | Where-Object { $_.pull_profile.confidence -eq 'proposed' }).Count
$unmeas   = @($doc.stores | Where-Object { $_.pull_profile.confidence -eq 'unmeasured' }).Count
Write-Output "PULL-PROFILE OK: $($doc.stores.Count) stores; pacing measured=$measured proposed=$proposed unmeasured=$unmeas"
if ($proposed -or $unmeas) {
  Write-Output "  note: a proposed/unmeasured rate has not been proven to avoid a wall. Promote it to 'measured' only after a full run completes cleanly, and record the real number."
}
Write-Output "PULL-PROFILE-COMPLETE problems=0"
exit 0
