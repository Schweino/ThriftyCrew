<#
  harvest-lane-tokens.ps1 - attribute real token spend to lanes, after the fact.

  WHY THIS EXISTS. hunt-run.ps1 -Lane accepts -InputTokens/-OutputTokens, and on the
  2026-08-15/16 run 738 of 738 invocations passed neither. That is not an oversight anyone
  can fix in the orchestrator: a subagent cannot read its own usage. It finishes, and only
  the harness knows what it cost. Self-reported token counts were never going to arrive.

  The figures do exist - in the workflow transcripts. Every assistant message in
  agent-<id>.jsonl carries a usage block, and the agent's first user message contains the
  laneLog command with its -LaneName and -Label. So the transcript is joinable to the lane
  by reading it. This script does that join and writes the totals back through hunt-run.ps1,
  which means -LaneSummary stops reporting a lower bound and starts reporting the run.

  Cache reads are counted SEPARATELY and never folded into input. A lane that reads 55k of
  cache and writes 1.2k of output has not spent 56k; billing and burn diverge by an order of
  magnitude there, and a summary that adds them makes cheap lanes look like the problem.
#>
[CmdletBinding()]
param(
  [string]$TranscriptDir,
  [string]$RunDir,
  [switch]$Apply,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Get-LaneFromPrompt([string]$text) {
  # The laneLog preamble is the first thing in every instrumented prompt.
  $m = [regex]::Match($text, "-LaneName\s+([A-Za-z0-9_.:-]+)\s+.*?-Label\s+'([^']*)'")
  if (-not $m.Success) { return $null }
  [pscustomobject]@{ Lane = $m.Groups[1].Value; Label = $m.Groups[2].Value }
}

function Get-UsageFromTranscript([string]$path) {
  $in = 0L; $out = 0L; $cacheRead = 0L; $cacheWrite = 0L
  foreach ($line in [System.IO.File]::ReadLines($path)) {
    if ($line -notlike '*"usage"*') { continue }
    $u = [regex]::Match($line, '"usage":\s*\{')
    if (-not $u.Success) { continue }
    foreach ($pair in @(
        @{ k = 'input_tokens'; }, @{ k = 'output_tokens'; },
        @{ k = 'cache_read_input_tokens'; }, @{ k = 'cache_creation_input_tokens'; })) {
      $mm = [regex]::Match($line, ('"{0}":\s*(\d+)' -f $pair.k))
      if (-not $mm.Success) { continue }
      $v = [int64]$mm.Groups[1].Value
      switch ($pair.k) {
        'input_tokens' { $in += $v }
        'output_tokens' { $out += $v }
        'cache_read_input_tokens' { $cacheRead += $v }
        'cache_creation_input_tokens' { $cacheWrite += $v }
      }
    }
  }
  [pscustomobject]@{ Input = $in; Output = $out; CacheRead = $cacheRead; CacheWrite = $cacheWrite }
}

if ($SelfTest) {
  $fails = 0
  function ok($cond, $msg, $got) {
    if ($cond) { Write-Host "  ok    $msg" }
    else { $script:fails++; Write-Host "  FAIL  $msg   got: $got" }
  }

  $l = Get-LaneFromPrompt "FIRST, before doing any work -Lane -RunDir x -LaneName write -Label 'chicken-piccata' -Items 'a' -By orchestrator -Event start"
  ok ($null -ne $l -and $l.Lane -eq 'write') 'the lane name is read out of the laneLog preamble' $(if ($l) { $l.Lane } else { '<null>' })
  ok ($null -ne $l -and $l.Label -eq 'chicken-piccata') 'the label is read out of the same preamble' $(if ($l) { $l.Label } else { '<null>' })

  $l2 = Get-LaneFromPrompt 'a prompt with no laneLog at all'
  ok ($null -eq $l2) 'an uninstrumented prompt yields no lane rather than a bogus one' "$l2"

  $l3 = Get-LaneFromPrompt "-LaneName qa -Label 'repair:it''s-fine' -Items '' -By orchestrator -Event start"
  ok ($null -ne $l3 -and $l3.Lane -eq 'qa') 'a doubled quote inside the label does not break the lane read' $(if ($l3) { $l3.Lane } else { '<null>' })

  # MUST-FIRE: cache reads are never folded into input. A transcript that reads 50k of cache
  # and spends 100 real input tokens must report Input=100, not 50100.
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hlt-" + [guid]::NewGuid().ToString('N') + '.jsonl')
  Set-Content $tmp '{"usage":{"input_tokens":100,"cache_read_input_tokens":50000,"cache_creation_input_tokens":7,"output_tokens":25}}' -Encoding utf8
  Add-Content $tmp '{"usage":{"input_tokens":3,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":5}}'
  $u = Get-UsageFromTranscript $tmp
  ok ($u.Input -eq 103) 'real input sums across messages and excludes cache reads' $u.Input
  ok ($u.Output -eq 30) 'output sums across messages' $u.Output
  ok ($u.CacheRead -eq 50010) 'cache reads are totalled on their own line' $u.CacheRead
  ok ($u.CacheWrite -eq 7) 'cache writes are totalled on their own line' $u.CacheWrite
  Remove-Item $tmp -Force

  # Clean twin: a transcript with no usage blocks reads as zero, not as an error.
  $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ("hlt-" + [guid]::NewGuid().ToString('N') + '.jsonl')
  Set-Content $tmp2 '{"type":"started"}' -Encoding utf8
  $u2 = Get-UsageFromTranscript $tmp2
  ok ($u2.Input -eq 0 -and $u2.Output -eq 0) 'a transcript with no usage blocks reads as zero, not as an error' "$($u2.Input)/$($u2.Output)"
  Remove-Item $tmp2 -Force

  if ($fails) { Write-Host "SELFTEST: $fails FAILED"; exit 1 }
  Write-Host 'harvest-lane-tokens SELF-TEST PASS'
  exit 0
}

if (-not $TranscriptDir) { throw '-TranscriptDir is required unless -SelfTest' }
if (-not (Test-Path $TranscriptDir)) { throw "no such transcript dir: $TranscriptDir" }

$rows = @()
foreach ($f in (Get-ChildItem $TranscriptDir -Filter 'agent-*.jsonl')) {
  $head = (Get-Content $f.FullName -TotalCount 40) -join "`n"
  $lane = Get-LaneFromPrompt $head
  $u = Get-UsageFromTranscript $f.FullName
  $rows += [pscustomobject]@{
    Agent      = $f.BaseName
    Lane       = $(if ($lane) { $lane.Lane } else { 'unattributed' })
    Label      = $(if ($lane) { $lane.Label } else { '' })
    Input      = $u.Input
    Output     = $u.Output
    CacheRead  = $u.CacheRead
    CacheWrite = $u.CacheWrite
  }
}

if (-not $rows) { Write-Host 'no agent transcripts found'; exit 0 }

$billable = ($rows | Measure-Object -Property Output -Sum).Sum
Write-Host ("harvest: {0} transcripts in {1}" -f $rows.Count, (Split-Path $TranscriptDir -Leaf))
Write-Host ('  {0,-14} {1,6} {2,12} {3,12} {4,7} {5,14}' -f 'lane', 'calls', 'input', 'output', 'share', 'cache_read')
foreach ($g in ($rows | Group-Object Lane | Sort-Object { -($_.Group | Measure-Object -Property Output -Sum).Sum })) {
  $o = ($g.Group | Measure-Object -Property Output -Sum).Sum
  $i = ($g.Group | Measure-Object -Property Input -Sum).Sum
  $c = ($g.Group | Measure-Object -Property CacheRead -Sum).Sum
  $share = if ($billable -gt 0) { '{0:P1}' -f ($o / $billable) } else { '-' }
  Write-Host ('  {0,-14} {1,6} {2,12:N0} {3,12:N0} {4,7} {5,14:N0}' -f $g.Name, $g.Count, $i, $o, $share, $c)
}
Write-Host ('  {0,-14} {1,6} {2,12:N0} {3,12:N0}' -f 'TOTAL', $rows.Count,
  ($rows | Measure-Object -Property Input -Sum).Sum, $billable)

$unattributed = @($rows | Where-Object { $_.Lane -eq 'unattributed' })
if ($unattributed.Count) {
  Write-Host ("  NOTE {0} transcript(s) carry no laneLog preamble - those dispatches are still blind." -f $unattributed.Count)
}

if ($Apply) {
  if (-not $RunDir) { throw '-Apply needs -RunDir so the figures have somewhere to land' }
  $hr = Join-Path $PSScriptRoot 'hunt-run.ps1'
  foreach ($r in ($rows | Where-Object { $_.Lane -ne 'unattributed' })) {
    & powershell -NoProfile -File $hr -Lane -RunDir $RunDir -LaneName $r.Lane -Label $r.Label `
      -By harvester -Event end -InputTokens $r.Input -OutputTokens $r.Output | Out-Null
  }
  Write-Host ("applied {0} token record(s) to {1}" -f ($rows.Count - $unattributed.Count), $RunDir)
}
