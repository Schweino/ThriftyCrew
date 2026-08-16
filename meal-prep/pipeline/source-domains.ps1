# source-domains.ps1
# ---------------------------------------------------------------------------------------------------
# What the pipeline has learned about recipe publishers, so it stops re-learning it every run.
#
# WHAT THIS REPLACES. A blocked-domain list existed as PROSE, duplicated verbatim in two agent files
# (.claude\agents\recipe-sourcer.md and recipe-source-qa.md), with nothing keeping them in sync and
# nothing able to update them. On 2026-08-16 `thespruceeats` was on that list in BOTH files and a
# sourcer sourced from it anyway - the recipe 404'd and died `rejected-unreadable`, after paying for
# the search and the fetch. `themediterraneandish` 404'd the same run and was on neither list, so the
# next run would have tried it again. Prose in a prompt is guidance; this file is data the pipeline
# writes to itself.
#
#   .\source-domains.ps1 -Record -Domain x.com -Outcome ok|fail|404|blocked [-HasJsonLd] [-Note '...']
#   .\source-domains.ps1 -Query -Domain x.com          exit 3 if the domain is blocked
#   .\source-domains.ps1 -Brief                        the block for a sourcer prompt
#   .\source-domains.ps1 -SelfTest
#
# STATUS RULE, inherited from the store-carriage discipline: one failure is a fact about one URL, not
# about a publisher. A single 404 makes a domain `unreliable`, never `blocked`. Only a repeated
# pattern earns `blocked`, and the counts stay in the row so the judgment is auditable, not folkloric.
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Brief, [switch]$List, [switch]$SelfTest,
  [string]$Domain = '', [string]$Outcome = '', [string]$Note = '', [switch]$HasJsonLd,
  [string]$Store = '', [switch]$Json
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runBrief=[bool]$Brief; $runList=[bool]$List
$runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runHasJsonLd=[bool]$HasJsonLd

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $Store) { $Store = Join-Path $mp 'db\source-domains.json' }

$script:BLOCK_AFTER = 3   # consecutive-ish failures with no success before a domain is called blocked

function Get-Host2 {
  param([string]$D)
  if (-not $D) { return '' }
  $d = $D.Trim().ToLower()
  $d = $d -replace '^https?://', ''
  $d = ($d -split '/')[0]
  $d = $d -replace '^www\.', ''
  return $d
}

function Get-Status {
  param([int]$Ok, [int]$Fail, [bool]$ForcedBlock)
  if ($ForcedBlock) { return 'blocked' }
  if ($Ok -gt 0 -and $Fail -eq 0) { return 'reliable' }
  if ($Fail -ge $script:BLOCK_AFTER -and $Ok -eq 0) { return 'blocked' }
  if ($Fail -gt 0) { return 'unreliable' }
  return 'unknown'
}

function Read-Store { param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  try { $d = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { return @() }
  if ($d -and ($d.PSObject.Properties.Name -contains 'domains')) { return @($d.domains) }
  return @()
}

if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  T 'host normalises scheme, www and path away' ((Get-Host2 'https://www.thespruceeats.com/recipe/x') -eq 'thespruceeats.com') (Get-Host2 'https://www.thespruceeats.com/recipe/x')
  T 'MUST FIRE  ONE failure is `unreliable`, never `blocked`' ((Get-Status 0 1 $false) -eq 'unreliable') (Get-Status 0 1 $false)
  T 'MUST FIRE  a repeated pattern with no success earns `blocked`' ((Get-Status 0 3 $false) -eq 'blocked') (Get-Status 0 3 $false)
  T 'MUST FIRE  a domain that has EVER worked is not blocked by later failures' ((Get-Status 5 4 $false) -eq 'unreliable') (Get-Status 5 4 $false)
  T 'CLEAN TWIN all-success is reliable' ((Get-Status 9 0 $false) -eq 'reliable') (Get-Status 9 0 $false)
  T 'an explicit block (a real bot wall) overrides the counts' ((Get-Status 9 0 $true) -eq 'blocked') (Get-Status 9 0 $true)
  T 'an unseen domain is `unknown`, not `reliable`' ((Get-Status 0 0 $false) -eq 'unknown') (Get-Status 0 0 $false)

  $tmp = Join-Path $env:TEMP ('sd-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ([pscustomobject]@{ domains=@([pscustomobject]@{domain='x.com';ok=1;fail=0;status='reliable'}) } | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding utf8
    T 'the store round-trips' ((@(Read-Store $tmp)).Count -eq 1) ([string](@(Read-Store $tmp)).Count)
    T 'a missing store reads as empty' ((@(Read-Store (Join-Path $env:TEMP 'nope.json'))).Count -eq 0) 'not empty'
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }

  if ($bad -gt 0) { Write-Output ("source-domains SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'source-domains SELF-TEST PASS'
  Write-GuardComplete -Name 'source-domains' -Summary 'selftest pass'; exit 0
}

$rows = @(Read-Store $Store)

if ($runRecord) {
  $h = Get-Host2 $Domain
  if (-not $h) { Write-Output 'source-domains: -Record needs -Domain'; exit 1 }
  $o = $Outcome.ToLower()
  if (@('ok','fail','404','blocked') -notcontains $o) { Write-Output ("source-domains: -Outcome must be ok|fail|404|blocked (got '{0}')" -f $Outcome); exit 1 }
  $r = @($rows | Where-Object { [string]$_.domain -eq $h })[0]
  if (-not $r) {
    $r = [pscustomobject]@{ domain=$h; ok=0; fail=0; last_404=$null; has_jsonld=$false; forced_block=$false; status='unknown'; note=''; updated='' }
    $rows = @($rows + $r)
  }
  switch ($o) {
    'ok'      { $r.ok = [int]$r.ok + 1 }
    'fail'    { $r.fail = [int]$r.fail + 1 }
    '404'     { $r.fail = [int]$r.fail + 1; $r.last_404 = (Get-Date -Format 'yyyy-MM-dd') }
    'blocked' { $r.fail = [int]$r.fail + 1; $r.forced_block = $true }
  }
  if ($runHasJsonLd) { $r.has_jsonld = $true }
  if ($Note) { $r.note = $Note }
  $r.status = Get-Status ([int]$r.ok) ([int]$r.fail) ([bool]$r.forced_block)
  $r.updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  $doc = [pscustomobject]@{
    _doc='What the pipeline has learned about recipe publishers. Written automatically on every fetch outcome; read by sourcers before searching and before fetching. Replaces the prose blocked-domain lists that used to live, duplicated, in two agent prompts.'
    _rule='One failure is `unreliable`, not `blocked` - a 404 is a fact about one URL. Only a repeated pattern with no successes earns `blocked`. Counts stay visible so the judgment is auditable.'
    updated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count=@($rows).Count; domains=@($rows)
  }
  $tmpf = $Store + '.tmp'
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -Path $tmpf -Encoding utf8
  Move-Item -Path $tmpf -Destination $Store -Force
  Write-Output ("source-domains: {0}  ok={1} fail={2}  -> {3}" -f $h, $r.ok, $r.fail, $r.status)
  exit 0
}

if ($runQuery) {
  $h = Get-Host2 $Domain
  $r = @($rows | Where-Object { [string]$_.domain -eq $h })[0]
  if (-not $r) { Write-Output ("source-domains: {0} unknown - no history, treat as untested (not as safe, not as bad)" -f $h); exit 0 }
  if ($runJson) { ($r | ConvertTo-Json -Depth 5); if ([string]$r.status -eq 'blocked') { exit 3 }; exit 0 }
  Write-Output ("source-domains: {0}  {1}  (ok={2} fail={3}{4}{5})" -f $r.domain, ([string]$r.status).ToUpper(), $r.ok, $r.fail,
    $(if($r.last_404){', last 404 ' + $r.last_404}else{''}), $(if($r.has_jsonld){', JSON-LD'}else{''}))
  if ($r.note) { Write-Output ("  note: " + $r.note) }
  if ([string]$r.status -eq 'blocked') { exit 3 }
  exit 0
}

if ($runBrief) {
  $blocked = @($rows | Where-Object { [string]$_.status -eq 'blocked' } | ForEach-Object { $_.domain } | Sort-Object)
  $unrel   = @($rows | Where-Object { [string]$_.status -eq 'unreliable' } | ForEach-Object { $_.domain } | Sort-Object)
  $rel     = @($rows | Where-Object { [string]$_.status -eq 'reliable' } | ForEach-Object { $_.domain } | Sort-Object)
  $jsonld  = @($rows | Where-Object { $_.has_jsonld } | ForEach-Object { $_.domain } | Sort-Object)
  if ($runJson) { ([pscustomobject]@{ blocked=$blocked; unreliable=$unrel; reliable=$rel; jsonld=$jsonld } | ConvertTo-Json -Depth 4); exit 0 }
  Write-Output ("BLOCKED (do not fetch, do not retry): {0}" -f $(if($blocked.Count){$blocked -join ', '}else{'(none yet)'}))
  Write-Output ("UNRELIABLE (has failed before - prefer alternatives): {0}" -f $(if($unrel.Count){$unrel -join ', '}else{'(none yet)'}))
  Write-Output ("RELIABLE (known good): {0}" -f $(if($rel.Count){$rel -join ', '}else{'(none yet)'}))
  if ($jsonld.Count) { Write-Output ("JSON-LD available (cheap structured fetch): {0}" -f ($jsonld -join ', ')) }
  exit 0
}

if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; domains=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("source-domains: {0} domain(s)" -f @($rows).Count)
foreach ($r in @($rows | Sort-Object status, domain)) {
  Write-Output ("  {0,-12} {1,-30} ok={2,-4} fail={3,-4}{4}" -f ([string]$r.status).ToUpper(), $r.domain, $r.ok, $r.fail, $(if($r.has_jsonld){' json-ld'}else{''}))
}
exit 0
