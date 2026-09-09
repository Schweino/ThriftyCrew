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
# THE PRICE TABLE (2026-09-09, backlog I31).
#
# USD per MILLION tokens. Anthropic first-party API list prices, read on 2026-09-09 from the
# `claude-api` skill's model table (cached there 2026-06-24). These are NOT estimates and NOT
# remembered - if they are stale, the fix is to re-read that table, not to adjust them by feel.
#
# THEY DO NOT APPLY TO A PARTNER PLATFORM. Bedrock and Vertex are separately priced, so a run
# dispatched through one of those is mispriced by this table and nothing here can detect it.
#
# FOUR RATES PER MODEL, NOT TWO, and that is the whole reason this is worth building. `Get-UsageFromLine`
# folds fresh input, cache reads and cache writes into one `in` number, which is correct for TOKENS and
# wrong for MONEY by nearly an order of magnitude in both directions: a cache read costs a tenth of
# fresh input, a cache write costs a quarter more. This estate's transcripts are overwhelmingly cache
# reads - a single sampled session ran 40,153 cache-read tokens against 2 fresh input tokens - so
# pricing `in` at the input rate would overstate the bill by roughly 10x and would make the repeated
# context this report exists to expose look like the dominant cost when it is not.
$script:PRICES = @{
  'claude-fable-5-1'  = @{ inp=10.0; out=50.0; cwrite=12.50; cread=0.25 }   # cread is a PUBLISHED override, not 0.1x
  'claude-fable-5'    = @{ inp=10.0; out=50.0; cwrite=12.50; cread=1.00 }
  'claude-opus-5'     = @{ inp= 5.0; out=25.0; cwrite= 6.25; cread=0.50 }
  'claude-opus-4-8'   = @{ inp= 5.0; out=25.0; cwrite= 6.25; cread=0.50 }
  'claude-opus-4-7'   = @{ inp= 5.0; out=25.0; cwrite= 6.25; cread=0.50 }
  'claude-opus-4-6'   = @{ inp= 5.0; out=25.0; cwrite= 6.25; cread=0.50 }
  'claude-sonnet-5'   = @{ inp= 2.0; out=10.0; cwrite= 2.50; cread=0.20 }
  'claude-sonnet-4-6' = @{ inp= 3.0; out=15.0; cwrite= 3.75; cread=0.30 }
  'claude-haiku-4-5'  = @{ inp= 1.0; out= 5.0; cwrite= 1.25; cread=0.10 }
}
# Except where a model publishes its own rate (Fable 5.1 above), cache write is 1.25x input and cache
# read is 0.10x input - the standard published ratios. A model added here owes all four numbers.

function Get-ModelFromLine {
  param([string]$Line)
  if (-not $Line) { return '' }
  $m = [regex]::Match($Line, '"model"\s*:\s*"([^"]+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-CostUsd {
  param([string]$Model, [int]$Fresh = 0, [int]$CacheRead = 0, [int]$CacheWrite = 0, [int]$Out = 0)
  # Returns @{ usd=<double>; priced=<bool> }.
  # AN UNKNOWN MODEL RETURNS priced=$false AND ZERO, AND THE CALLER MUST SAY SO. A zero here is
  # indistinguishable from a free lane, which is the agreeing-zero shape this estate keeps being bitten
  # by: the report would read as a complete bill while silently omitting a whole model's spend. Every
  # money figure this script prints is therefore a FLOOR whenever anything went unpriced.
  if (-not $Model -or -not $script:PRICES.ContainsKey($Model)) { return @{ usd = 0.0; priced = $false } }
  $p = $script:PRICES[$Model]
  $usd = ($Fresh * $p.inp + $CacheRead * $p.cread + $CacheWrite * $p.cwrite + $Out * $p.out) / 1000000.0
  return @{ usd = $usd; priced = $true }
}

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
  # Returns @{in=; out=; fresh=; cread=; cwrite=; model=} for one JSONL line, or $null when the line
  # carries no usage record.
  # cache_read_input_tokens is counted as input: it is cheaper per token but it is not free, and
  # excluding it understates exactly the repeated-context waste this report exists to expose.
  # `in` remains their SUM so the token report is unchanged; the three are also returned separately
  # because they are priced at three different rates (see $script:PRICES).
  if (-not $Line -or $Line.Trim() -eq '') { return $null }
  $mi  = [regex]::Match($Line, '"input_tokens"\s*:\s*(\d+)')
  $mo  = [regex]::Match($Line, '"output_tokens"\s*:\s*(\d+)')
  $mcr = [regex]::Match($Line, '"cache_read_input_tokens"\s*:\s*(\d+)')
  $mcc = [regex]::Match($Line, '"cache_creation_input_tokens"\s*:\s*(\d+)')
  if (-not $mi.Success -and -not $mo.Success) { return $null }
  $fresh = 0; $cread = 0; $cwrite = 0
  if ($mi.Success)  { $fresh  = [int]$mi.Groups[1].Value }
  if ($mcr.Success) { $cread  = [int]$mcr.Groups[1].Value }
  if ($mcc.Success) { $cwrite = [int]$mcc.Groups[1].Value }
  $outTok = 0
  if ($mo.Success) { $outTok = [int]$mo.Groups[1].Value }
  return @{ in = ($fresh + $cread + $cwrite); out = $outTok
            fresh = $fresh; cread = $cread; cwrite = $cwrite
            model = (Get-ModelFromLine $Line) }
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

  # ---- the price table (backlog I31) ---------------------------------------------------------------
  $c1 = Get-CostUsd -Model 'claude-opus-5' -Fresh 1000000 -Out 0
  T 'one million fresh input tokens on opus-5 is $5.00' ([math]::Round($c1.usd,6) -eq 5.0) ([string]$c1.usd)
  $c2 = Get-CostUsd -Model 'claude-opus-5' -Out 1000000
  T 'one million output tokens on opus-5 is $25.00' ([math]::Round($c2.usd,6) -eq 25.0) ([string]$c2.usd)

  # MUST FIRE. This is the founding bug: pricing the collapsed `in` at the input rate. A million cache
  # reads cost $0.50 on opus-5, not $5.00, and this estate's transcripts are almost entirely cache reads.
  $c3 = Get-CostUsd -Model 'claude-opus-5' -CacheRead 1000000
  T 'MUST FIRE  a cache READ is a tenth of fresh input, not the same' ([math]::Round($c3.usd,6) -eq 0.5) ([string]$c3.usd)
  $c4 = Get-CostUsd -Model 'claude-opus-5' -CacheWrite 1000000
  T 'MUST FIRE  a cache WRITE is 1.25x fresh input, not the same' ([math]::Round($c4.usd,6) -eq 6.25) ([string]$c4.usd)

  # MUST FIRE. An unpriced model must be VISIBLE, not billed at zero and folded into the total.
  $c5 = Get-CostUsd -Model 'some-model-nobody-added' -Fresh 999999999 -Out 999999999
  T 'MUST FIRE  an unknown model reports priced=false, never a silent zero' ((-not $c5.priced) -and $c5.usd -eq 0.0) ("priced=$($c5.priced) usd=$($c5.usd)")
  $c6 = Get-CostUsd -Model '' -Fresh 1000000
  T 'MUST FIRE  a missing model name is unpriced too' (-not $c6.priced) 'priced'

  # MUST NOT FIRE. A model that IS in the table prices, and the four buckets add up rather than
  # replacing one another.
  $c7 = Get-CostUsd -Model 'claude-haiku-4-5' -Fresh 1000000 -CacheRead 1000000 -CacheWrite 1000000 -Out 1000000
  T 'the four buckets sum (haiku 1 + 0.10 + 1.25 + 5 = 7.35)' ([math]::Round($c7.usd,6) -eq 7.35) ([string]$c7.usd)
  T 'every priced model carries all four rates' (@($script:PRICES.Keys | Where-Object { -not ($script:PRICES[$_].ContainsKey('inp') -and $script:PRICES[$_].ContainsKey('out') -and $script:PRICES[$_].ContainsKey('cread') -and $script:PRICES[$_].ContainsKey('cwrite')) }).Count -eq 0) 'a model is missing a rate'

  # CLEAN TWIN. The token side still works: splitting the buckets must not have changed `in`.
  $u5 = Get-UsageFromLine '{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":30,"cache_read_input_tokens":900,"output_tokens":7}}'
  T 'CLEAN TWIN  `in` is still the sum of all three input buckets' ($u5.in -eq 932) ([string]$u5.in)
  T 'the three buckets are also returned separately' ($u5.fresh -eq 2 -and $u5.cwrite -eq 30 -and $u5.cread -eq 900) ("$($u5.fresh)/$($u5.cwrite)/$($u5.cread)")
  T 'the model is read off the same line as the usage' ($u5.model -eq 'claude-opus-5') $u5.model
  $u6 = Get-UsageFromLine '{"usage":{"input_tokens":5,"output_tokens":1}}'
  T 'MUST FIRE  a usage line with no model yields an empty model, not a default' ($u6.model -eq '') $u6.model

  if ($bad -gt 0) { Write-Output ("lane-tokens SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'lane-tokens SELF-TEST PASS'
  Exit-Guard -Name 'lane-tokens' -Summary 'selftest pass' -Code 0
}

# ---- report ----------------------------------------------------------------------------------------
if (-not $TranscriptDir -or -not (Test-Path $TranscriptDir)) {
  Write-Output 'lane-tokens: -TranscriptDir <workflow transcript dir> is required'
  exit 1
}
$files = @(Get-ChildItem $TranscriptDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue)
if (-not $files.Count) { Write-Output ("lane-tokens: no agent transcripts under {0}" -f $TranscriptDir); exit 1 }

$agg = @{}
$models = @{}          # model name -> tokens seen, so an unpriced model can be NAMED rather than lost
$unpricedTokens = 0
foreach ($f in $files) {
  $lane = 'unknown'; $inSum = 0; $outSum = 0; $sawUsage = $false; $usd = 0.0; $unpriced = 0
  $head = ''
  $n = 0
  foreach ($line in [IO.File]::ReadLines($f.FullName)) {
    $n++
    if ($n -le 40 -and $head.Length -lt 20000) { $head += $line }   # the dispatch prompt lives near the top
    $u = Get-UsageFromLine $line
    if ($u) {
      $inSum += $u.in; $outSum += $u.out; $sawUsage = $true
      # Priced PER LINE against that line's own model. The roster is mixed on purpose - some agents are
      # Fable-pinned and some Opus-pinned, a 2x difference in input rate - so one assumed model for a
      # whole run would be wrong for most of it.
      $c = Get-CostUsd -Model $u.model -Fresh $u.fresh -CacheRead $u.cread -CacheWrite $u.cwrite -Out $u.out
      $usd += $c.usd
      $mk = if ($u.model) { $u.model } else { '(no model on the line)' }
      if (-not $models.ContainsKey($mk)) { $models[$mk] = [pscustomobject]@{ model=$mk; tokens=0; priced=$c.priced } }
      $models[$mk].tokens += ($u.in + $u.out)
      if (-not $c.priced) { $unpriced++; $unpricedTokens += ($u.in + $u.out) }
    }
  }
  $lane = Get-LaneFromText $head
  if (-not $agg.ContainsKey($lane)) { $agg[$lane] = [pscustomobject]@{ lane=$lane; agents=0; in=0; out=0; nousage=0; usd=0.0; unpriced=0 } }
  $a = $agg[$lane]; $a.agents++; $a.in += $inSum; $a.out += $outSum; $a.usd += $usd; $a.unpriced += $unpriced
  if (-not $sawUsage) { $a.nousage++ }
}

$tot = 0; foreach ($a in $agg.Values) { $tot += ($a.in + $a.out) }
$totUsd = 0.0; foreach ($a in $agg.Values) { $totUsd += $a.usd }

if ($runJson) {
  ([pscustomobject]@{ transcripts=$files.Count; total_tokens=$tot; total_usd=[math]::Round($totUsd,4)
                      usd_is_a_floor=($unpricedTokens -gt 0); unpriced_tokens=$unpricedTokens
                      models=@($models.Values | Sort-Object { -$_.tokens })
                      per_recipe=$(if($PerRecipe -gt 0){[int]($tot/$PerRecipe)}else{$null})
                      usd_per_recipe=$(if($PerRecipe -gt 0){[math]::Round($totUsd/$PerRecipe,4)}else{$null})
                      lanes=@($agg.Values | Sort-Object { -($_.in + $_.out) }) } | ConvertTo-Json -Depth 5)
  exit 0
}

Write-Output ("lane-tokens: {0} transcript(s) under {1}" -f $files.Count, (Split-Path $TranscriptDir -Leaf))
Write-Output ("  {0,-9} {1,7} {2,14} {3,14} {4,14} {5,7} {6,10}" -f 'lane','agents','input','output','total','share','USD')
foreach ($a in ($agg.Values | Sort-Object { -($_.in + $_.out) })) {
  $lt = $a.in + $a.out
  $share = if ($tot -gt 0) { '{0:N1}%' -f (100.0 * $lt / $tot) } else { '-' }
  $note = if ($a.nousage -gt 0) { (' [{0} with no usage record]' -f $a.nousage) } else { '' }
  if ($a.unpriced -gt 0) { $note += (' [{0} unpriced call(s) - this lane''s USD is a FLOOR]' -f $a.unpriced) }
  Write-Output ("  {0,-9} {1,7} {2,14:N0} {3,14:N0} {4,14:N0} {5,7} {6,10:C2}{7}" -f $a.lane,$a.agents,$a.in,$a.out,$lt,$share,$a.usd,$note)
}
Write-Output ("  {0,-9} {1,7} {2,14} {3,14} {4,14:N0} {5,7} {6,10:C2}" -f 'TOTAL',$files.Count,'','',$tot,'',$totUsd)
if ($PerRecipe -gt 0) {
  Write-Output ("  per recipe ({0} recipes): {1:N0} tokens   [v2.1 target 200,000-250,000]" -f $PerRecipe, ($tot / $PerRecipe))
  Write-Output ("  per recipe ({0} recipes): {1:C2}" -f $PerRecipe, ($totUsd / $PerRecipe))
}

# THE MODEL MIX, always printed. A dollar figure with no model behind it cannot be checked, and the mix
# is what a reader needs to know whether a lane is expensive because it did a lot or because it ran on
# an expensive model.
Write-Output '  models seen:'
foreach ($m in ($models.Values | Sort-Object { -$_.tokens })) {
  $flag = if ($m.priced) { '' } else { '   <- NOT IN THE PRICE TABLE, CONTRIBUTES $0.00 TO THE TOTAL' }
  Write-Output ("    {0,-24} {1,14:N0} tokens{2}" -f $m.model, $m.tokens, $flag)
}
if ($unpricedTokens -gt 0) {
  Write-Output ("  THE TOTAL ABOVE IS A FLOOR, NOT A BILL: {0:N0} token(s) ran on a model this script has no price for." -f $unpricedTokens)
  Write-Output  '  Add it to $script:PRICES with all four rates. Do not read the total as complete until you have.'
} else {
  Write-Output ("  Every model seen was priced. Rates: Anthropic first-party list, read 2026-09-09; a partner platform (Bedrock/Vertex) would be mispriced and this script cannot tell.")
}
if ($agg.ContainsKey('unknown')) {
  Write-Output ("  NOTE {0} transcript(s) could not be attributed to a lane - their tokens are real and counted under `unknown`." -f $agg['unknown'].agents)
}
Exit-Guard -Name 'lane-tokens' -Summary ("lanes={0} tokens={1}" -f $agg.Count, $tot) -Code 0
