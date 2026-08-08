<#
  audit-cloud-readiness.ps1 - can the daily chain actually run on a runner that has no key files?

  WHY THIS EXISTS (2026-08-08). The cloud backup (.github\workflows\daily.yml) has NEVER completed a full
  run. Every scheduled run from 2026-07-24 to 2026-08-05 stood down in under half a minute because of a
  PS 5.1 array-wrapper bug in its gate, and a stand-down reports SUCCESS - so the workflow looked healthy
  for 13 straight days while the safety net underneath it was untested. Then on 08-05/06 the LOCAL run
  stood down too (the weekly browser lock held grocery\out for two days) and there was nothing underneath
  at all. The gate is fixed; what is still unproven is whether the run would SUCCEED if it ever fired.

  The first thing that would have killed it is credentials. Key files (.ghostkey, .krogerkey) are
  gitignored, so on a runner they do not exist - every consumer must fall back to an environment variable.
  Most did. meal-prep\engine\publish.ps1, the recipe card publisher, did not: it read the key file directly
  on the line ABOVE the dot-source that provides the env-aware helper, so it would have thrown before
  publishing anything. That is exactly the class this audit exists to find, and it is invisible locally
  because the key file is always there.

  WHAT IT CHECKS. Every script the daily chain invokes that consumes a credential must either read an env
  var first, or use the estate's lib helper (which does). A script that can ONLY read a file is a cloud
  failure waiting for its first real run.

  This is static analysis on purpose - it does not need a runner, and it stays true whether or not the
  secrets are set. Whether the secrets EXIST is a separate question only Brad can answer from the repo
  settings page; this prints the exact list.

  Usage: .\audit-cloud-readiness.ps1 [-ShowAll] | -SelfTest
#>
param([switch]$ShowAll, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
$repo = Split-Path $root -Parent
$mp   = Join-Path $repo 'meal-prep'

# a consumer is cloud-safe if it reads the env var, or delegates to a helper that does
$script:SAFE_PATTERNS = @('\$env:GHOST_ADMIN_KEY', '\$env:KROGER_CLIENT_ID', 'Get-GhostKey', 'Get-KrogerKey')
$script:KEY_READ      = 'Get-Content[^\r\n]*\.(ghostkey|krogerkey)'

function Test-CloudSafe { param([string]$Text)
  <# Reads a key FILE but never an env var (nor a helper that does) => cannot run on a runner. #>
  if (-not ([regex]::IsMatch($Text, $script:KEY_READ))) { return $true }   # consumes no key file at all
  foreach ($p in $script:SAFE_PATTERNS) { if ([regex]::IsMatch($Text, $p)) { return $true } }
  return $false
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  # FROZEN FIXTURE: publish.ps1 exactly as it stood - a bare key-file read, no env fallback anywhere.
  $bad = '$adminKey = (Get-Content (Join-Path $here "..\.ghostkey") -Raw).Trim()'
  T 'MUST FIRE  a bare key-file read with no env fallback (publish.ps1 as it was)' (-not (Test-CloudSafe $bad)) 'passed a cloud-fatal script'
  # CLEAN TWIN: the estate's own env-first pattern, used by every other publisher in the chain
  $good = '$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path $kf) { (Get-Content $kf -Raw).Trim() }'
  T 'CLEAN TWIN the env-first pattern is cloud-safe' (Test-CloudSafe $good) 'flagged a safe script'
  # CLEAN TWIN: delegating to the lib helper counts, even with no literal env reference of its own
  $lib = '. (Join-Path $PSScriptRoot "..\..\lib\ghost-lib.ps1")' + "`n" + '$adminKey = Get-GhostKey' + "`n" + '(Get-Content x.ghostkey)'
  T 'CLEAN TWIN delegating to Get-GhostKey counts as safe'  (Test-CloudSafe $lib) 'flagged a helper user'
  # CLEAN TWIN: a script that touches no credential at all is not this audit's business
  T 'CLEAN TWIN a script with no credential read is not flagged' (Test-CloudSafe 'Write-Output "hello"') 'false positive'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- who does the daily chain actually invoke? -----------------------------------------------------------
$chain = @((Join-Path $root 'check-ad-cycles.ps1'), (Join-Path $root 'run-daily-local.ps1'))
$chainText = ''
foreach ($c in $chain) { if (Test-Path $c) { $chainText += [IO.File]::ReadAllText($c) } }

$candidates = @()
foreach ($d in @($root, $mp, (Join-Path $mp 'engine'), (Join-Path $mp 'pipeline'))) {
  $candidates += @(Get-ChildItem (Join-Path $d '*.ps1') -ErrorAction SilentlyContinue)
}

$unsafe = @(); $safe = 0; $needed = @{}
foreach ($f in $candidates) {
  $txt = [IO.File]::ReadAllText($f.FullName)
  if (-not ([regex]::IsMatch($txt, $script:KEY_READ))) { continue }        # no credential, not our business
  $inChain = $chainText -match [regex]::Escape($f.Name)
  if ([regex]::IsMatch($txt, '\$env:GHOST_ADMIN_KEY') -or [regex]::IsMatch($txt, 'Get-GhostKey')) { $needed['GHOST_ADMIN_KEY'] = $true }
  if ([regex]::IsMatch($txt, '\$env:KROGER_CLIENT_ID')) { $needed['KROGER_CLIENT_ID'] = $true; $needed['KROGER_CLIENT_SECRET'] = $true }
  if (Test-CloudSafe $txt) { $safe++ }
  else { $unsafe += [pscustomobject]@{ name = $f.Name; inChain = $inChain } }
}

$blocking = @($unsafe | Where-Object { $_.inChain })
Write-Output ("cloud-readiness: {0} credential consumer(s) cloud-safe, {1} not ({2} of those are IN the daily chain)" -f $safe, $unsafe.Count, $blocking.Count)
Write-Output ''
Write-Output 'SECRETS the runner needs (set at Settings > Secrets and variables > Actions):'
foreach ($k in ($needed.Keys | Sort-Object)) { Write-Output ("    " + $k) }
Write-Output ''
if ($blocking.Count) {
  Write-Output 'BLOCKING - these run in the daily chain and can ONLY read a key file, so a runner kills them:'
  $blocking | ForEach-Object { Write-Output ("  ! " + $_.name) }
} else {
  Write-Output 'no blocking consumer: every credential reader in the daily chain falls back to an env var'
}
if ($unsafe.Count -gt $blocking.Count) {
  $off = @($unsafe | Where-Object { -not $_.inChain })
  Write-Output ''
  Write-Output ("off-chain tools that are still local-only (diagnostics/one-offs, not run by the pipeline): {0}" -f (($off | ForEach-Object { $_.name }) -join ', '))
}
Write-GuardComplete -Name 'cloud-readiness' -Summary ("safe={0} blocking={1}" -f $safe, $blocking.Count)
exit $(if ($blocking.Count) { 1 } else { 0 })
