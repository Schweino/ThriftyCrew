# lane-tokens.ps1
# ---------------------------------------------------------------------------------------------------
# Per-lane token accounting for a hunt run - the number v2.1 section 5.2 asked for and never got.
#
# WHY THIS READS TRANSCRIPTS RATHER THAN BEING STAMPED AT DISPATCH. The plan assumed the orchestrator
# could stamp each Agent result's usage into the lane log as it arrived. It cannot: the Workflow tool's
# agent() returns the agent's text or its schema object and nothing else - token usage is not exposed
# to the calling script. The usage IS written to each subagent's transcript, continuously, so reading
# those is the only way to get real figures, and it has the property the original usage.jsonl lacked:
# it works on a run that DIED, because the transcripts are already on disk.
#
# HOW A TRANSCRIPT IS ATTRIBUTED TO A LANE. Every orchestrator prompt opens with the lane-log command
# (`hunt-run.ps1 -Lane -RunDir ... -LaneName <lane>`), so the lane name is inside the prompt text the
# transcript records. That is a more reliable join than timestamps, which interleave badly at 16-way
# concurrency. An unattributable transcript is reported as `unknown` - never silently dropped, because
# a lane that vanishes from a cost report is exactly how you conclude the wrong thing about cost.
#
#   .\lane-tokens.ps1 -TranscriptDir <dir>            per-lane totals
#   .\lane-tokens.ps1 -TranscriptDir <dir> -Json
#   .\lane-tokens.ps1 -SelfTest
# Exit 0 ok, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$TranscriptDir = '',
  [int]$PerRecipe = 0,        # published/accepted recipe count, to report cost-per-recipe
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')

$script:LANES = @('hunt','select','extract','map','price','write','qa','audit','publish','review')

# ---------------------------------------------------------------------------------------------------
# PREDICATES, pure so the fixtures test the same code the sweep runs.
# ---------------------------------------------------------------------------------------------------
function Get-LaneFromText {
  param([string]$Text)
  if (-not $Text) { return 'unknown' }
  $m = [regex]::Match($Text, '-LaneName\s+([A-Za-z]+)')
  if ($m.Success) {
    $ln = $m.Groups[1].Value.ToLower()
    if ($script:LANES -contains $ln) { return $ln }
  }
  return 'unknown'
}

function Get-UsageFromLine {
  param([string]$Line)
  # Returns @{in=<int>; out=<int>} for one JSONL line, or $null when the line carries no usage record.
  # cache_read_input_tokens is counted as input: it is cheaper per token but it is not free, and
  # excluding it understates exactly the repeated-context waste this report exists to expose.
  if (-not $Line -or $Line.Trim() -eq '') { return $null }
  $mi  = [regex]::Match($Line, '"input_tokens"\s*:\s*(\d+)')
  $mo  = [regex]::Match($Line, '"output_tokens"\s*:\s*(\d+)')
  $mcr = [regex]::Match($Line, '"cache_read_input_tokens"\s*:\s*(\d+)')
  $mcc = [regex]::Match($Line, '"cache_creation_input_tokens"\s*:\s*(\d+)')
  if (-not $mi.Success -and -not $mo.Success) { return $null }
  $inTok = 0
  if ($mi.Success)  { $inTok += [int]$mi.Groups[1].Value }
  if ($mcr.Success) { $inTok += [int]$mcr.Groups[1].Value }
  if ($mcc.Success) { $inTok += [int]$mcc.Groups[1].Value }
  $outTok = 0
  if ($mo.Success) { $outTok = [int]$mo.Groups[1].Value }
  return @{ in = $inTok; out = $outTok }
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  T 'lane is read out of the -LaneName in the prompt' ((Get-LaneFromText 'blah -Lane -RunDir x -LaneName price -Label y') -eq 'price') (Get-LaneFromText 'blah -LaneName price')
  T 'MUST FIRE  an unknown lane name is NOT accepted as a lane' ((Get-LaneFromText '-LaneName pricer') -eq 'unknown') (Get-LaneFromText '-LaneName pricer')
  T 'MUST FIRE  a transcript with no lane marker is `unknown`, never dropped' ((Get-LaneFromText 'no marker here') -eq 'unknown') (Get-LaneFromText 'no marker here')
  T 'lane match is case-insensitive on the value' ((Get-LaneFromText '-LaneName MAP') -eq 'map') (Get-LaneFromText '-LaneName MAP')

  $u1 = Get-UsageFromLine '{"usage":{"input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}'
  T 'cache reads count as input (they are cheaper, not free)' ($u1.in -eq 1000 -and $u1.out -eq 50) ("in=$($u1.in) out=$($u1.out)")
  $u2 = Get-UsageFromLine '{"type":"text","text":"hello"}'
  T 'MUST FIRE  a line with no usage record returns null, not zero' ($null -eq $u2) 'not null'
  $u3 = Get-UsageFromLine '{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":0}}'
  T 'cache CREATION also counts as input' ($u3.in -eq 15) ([string]$u3.in)
  $u4 = Get-UsageFromLine ''
  T 'an empty line is null' ($null -eq $u4) 'not null'

  if ($bad -gt 0) { Write-Output ("lane-tokens SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'lane-tokens SELF-TEST PASS'
  Write-GuardComplete -Name 'lane-tokens' -Summary 'selftest pass'
  exit 0
}

# ---- report ----------------------------------------------------------------------------------------
if (-not $TranscriptDir -or -not (Test-Path $TranscriptDir)) {
  Write-Output 'lane-tokens: -TranscriptDir <workflow transcript dir> is required'
  exit 1
}
$files = @(Get-ChildItem $TranscriptDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue)
if (-not $files.Count) { Write-Output ("lane-tokens: no agent transcripts under {0}" -f $TranscriptDir); exit 1 }

$agg = @{}
foreach ($f in $files) {
  $lane = 'unknown'; $inSum = 0; $outSum = 0; $sawUsage = $false
  $head = ''
  $n = 0
  foreach ($line in [IO.File]::ReadLines($f.FullName)) {
    $n++
    if ($n -le 40 -and $head.Length -lt 20000) { $head += $line }   # the dispatch prompt lives near the top
    $u = Get-UsageFromLine $line
    if ($u) { $inSum += $u.in; $outSum += $u.out; $sawUsage = $true }
  }
  $lane = Get-LaneFromText $head
  if (-not $agg.ContainsKey($lane)) { $agg[$lane] = [pscustomobject]@{ lane=$lane; agents=0; in=0; out=0; nousage=0 } }
  $a = $agg[$lane]; $a.agents++; $a.in += $inSum; $a.out += $outSum
  if (-not $sawUsage) { $a.nousage++ }
}

$tot = 0; foreach ($a in $agg.Values) { $tot += ($a.in + $a.out) }

if ($runJson) {
  ([pscustomobject]@{ transcripts=$files.Count; total_tokens=$tot; per_recipe=$(if($PerRecipe -gt 0){[int]($tot/$PerRecipe)}else{$null}); lanes=@($agg.Values | Sort-Object { -($_.in + $_.out) }) } | ConvertTo-Json -Depth 5)
  exit 0
}

Write-Output ("lane-tokens: {0} transcript(s) under {1}" -f $files.Count, (Split-Path $TranscriptDir -Leaf))
Write-Output ("  {0,-9} {1,7} {2,14} {3,14} {4,14} {5,7}" -f 'lane','agents','input','output','total','share')
foreach ($a in ($agg.Values | Sort-Object { -($_.in + $_.out) })) {
  $lt = $a.in + $a.out
  $share = if ($tot -gt 0) { '{0:N1}%' -f (100.0 * $lt / $tot) } else { '-' }
  $note = if ($a.nousage -gt 0) { (' [{0} with no usage record]' -f $a.nousage) } else { '' }
  Write-Output ("  {0,-9} {1,7} {2,14:N0} {3,14:N0} {4,14:N0} {5,7}{6}" -f $a.lane,$a.agents,$a.in,$a.out,$lt,$share,$note)
}
Write-Output ("  {0,-9} {1,7} {2,14} {3,14} {4,14:N0}" -f 'TOTAL',$files.Count,'','',$tot)
if ($PerRecipe -gt 0) {
  Write-Output ("  per recipe ({0} recipes): {1:N0} tokens   [v2.1 target 200,000-250,000]" -f $PerRecipe, ($tot / $PerRecipe))
}
if ($agg.ContainsKey('unknown')) {
  Write-Output ("  NOTE {0} transcript(s) could not be attributed to a lane - their tokens are real and counted under `unknown`." -f $agg['unknown'].agents)
}
Write-GuardComplete -Name 'lane-tokens' -Summary ("lanes={0} tokens={1}" -f $agg.Count, $tot)
exit 0
