# scorecard.ps1
# ---------------------------------------------------------------------------------------------------
# THE MATCHING LANE'S WEEKLY SCORECARD - plan section 9 of design\PLAN-local-matching-2026-08-22.md.
#
# "Every phase ships with its before/after on the scorecard or it did not ship." This is that
# scorecard. It answers, for a window:
#
#     questions asked                          how much work the lane was handed
#     settled by the deterministic layers      layers 1-4, the free ones
#     settled by layer 5 (the local model)     the GPU ones
#     sent to Claude                           the ones that cost money
#     confirmed / rejected / deferred          what Claude ruled
#     tokens per Claude ruling                 the number the whole plan exists to drive down
#
# READ-ONLY. The graph half runs through scorecard_query.py, which opens SQLite with mode=ro so a bug
# here cannot write and so it can run while the 07:00 pipeline holds the file. It changes nothing about
# what may price a cell.
#
# WHY THE TOKEN FIGURE COMES FROM TRANSCRIPTS. Same reason meal-prep\pipeline\lane-tokens.ps1 reads
# them for the recipe hunter: token usage is not exposed to the calling script, it is only written to
# the session transcript - and reading transcripts has the property a stamped log lacks, that it still
# works for a session that DIED. Get-UsageFromLine is lane-tokens' predicate with one change: it keeps
# cache READS separate from fresh input instead of summing them, for the reason recorded on the
# function.
#
# HOW A TRANSCRIPT IS ATTRIBUTED TO THIS LANE, AND WHY THE ANSWER IS A RANGE. The recipe hunter stamps
# `-LaneName <lane>` into every dispatch prompt, so its lanes are separable. The matching lane has no
# such marker: the reviewer is run from an ordinary session that also writes code and captures stores,
# and the transcript does not say which turn was which. Attribution is therefore by the tool the
# reviewer actually RUNS (`review_escalations.py --ingest|--emit-packet|--queue`, never a mere mention
# of the path - this file mentions it and must not attribute itself), line by line, inside the SAME
# window the rulings are counted in, and the answer is reported as two bounds rather than one number.
# See the bounds note further down. The report always prints how many transcripts it charged, so an
# inflated denominator is visible rather than hidden.
#
#   .\scorecard.ps1                      last 7 days
#   .\scorecard.ps1 -Days 30
#   .\scorecard.ps1 -Since 2026-08-16 -Until 2026-08-23 -Json
#   .\scorecard.ps1 -SelfTest
# Exit 0 ok, 2 self-test failure, 3 could-not-evaluate (no graph db / no python).
# ---------------------------------------------------------------------------------------------------
param(
  [int]$Days = 7,
  [string]$Since = '',
  [string]$Until = '',
  [string]$TranscriptDir = '',
  [string]$Db = '',
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$graph = Split-Path -Parent $here
$repo  = Split-Path -Parent $graph
. (Join-Path $repo 'lib\guard-contract.ps1')

# The Windows Store python.exe on PATH is a stub that exits 49 without running anything, so the
# interpreter is always an absolute resolved path - never a bare `python`.
function Get-Python {
  foreach ($c in @("C:\Codex\Python312\python.exe",
                   "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                   "C:\Program Files\Python312\python.exe")) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

# ---------------------------------------------------------------------------------------------------
# PREDICATES, pure so the self-test exercises the same code the report runs.
# ---------------------------------------------------------------------------------------------------
function Get-UsageFromLine {
  param([string]$Line)
  # @{fresh=<int>; cache=<int>; out=<int>; in=<int>} for one transcript JSONL line, or $null when the
  # line carries no usage record. `in` is fresh+cache, so this stays a drop-in for lane-tokens' shape.
  # Cache reads are SEPARATED rather than dropped: they are real tokens and belong in the total, but
  # they are also 90% of a long session's input and an order of magnitude cheaper, so a report that
  # folds them into fresh input says a review lane spent a billion tokens when it spent a few million.
  if (-not $Line -or $Line.Trim() -eq '') { return $null }
  $mi  = [regex]::Match($Line, '"input_tokens"\s*:\s*(\d+)')
  $mo  = [regex]::Match($Line, '"output_tokens"\s*:\s*(\d+)')
  $mcr = [regex]::Match($Line, '"cache_read_input_tokens"\s*:\s*(\d+)')
  $mcc = [regex]::Match($Line, '"cache_creation_input_tokens"\s*:\s*(\d+)')
  if (-not $mi.Success -and -not $mo.Success) { return $null }
  $fresh = 0
  if ($mi.Success)  { $fresh += [int]$mi.Groups[1].Value }
  if ($mcc.Success) { $fresh += [int]$mcc.Groups[1].Value }   # cache CREATION is full-price input
  $cache = 0
  if ($mcr.Success) { $cache = [int]$mcr.Groups[1].Value }
  $outTok = 0
  if ($mo.Success) { $outTok = [int]$mo.Groups[1].Value }
  return @{ fresh = $fresh; cache = $cache; out = $outTok; in = ($fresh + $cache) }
}

function Get-LineTimestamp {
  param([string]$Line)
  # The transcript's own ISO timestamp for this line, as a sortable yyyy-MM-ddTHH:mm:ss string, or ''.
  # Used to keep the token half inside the SAME window as the ruling half - a whole-file attribution
  # would charge a week's rulings with a month of a long-running session's tokens.
  if (-not $Line) { return '' }
  $m = [regex]::Match($Line, '"timestamp"\s*:\s*"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})')
  if (-not $m.Success) { return '' }
  return ($m.Groups[1].Value + 'T' + $m.Groups[2].Value)
}

function Test-InWindow {
  param([string]$Stamp, [string]$Since, [string]$Until)
  # Half-open [Since, Until). An undated line is NOT in the window: it cannot be shown to belong, and
  # guessing inflates the numerator of a cost figure.
  if (-not $Stamp) { return $false }
  return ($Stamp -ge $Since -and $Stamp -lt $Until)
}

function Test-ReviewLaneTranscript {
  param([string]$Text)
  # A transcript belongs to the matching-review lane when it RAN the reviewer, not when it mentions it.
  if (-not $Text) { return $false }
  return [bool][regex]::IsMatch($Text, 'review_escalations\.py[^\r\n]*--(ingest|emit-packet|queue)')
}

function Format-Rate {
  param([double]$Numerator, [double]$Denominator)
  if ($Denominator -le 0) { return 'n/a' }
  return ('{0:N0}' -f ($Numerator / $Denominator))
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  $u1 = Get-UsageFromLine '{"usage":{"input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}'
  T 'cache reads count as input (cheaper, not free)' ($u1.in -eq 1000 -and $u1.out -eq 50) ("in=$($u1.in) out=$($u1.out)")
  T 'MUST FIRE  cache reads are SEPARABLE from fresh input, not merged into it' ($u1.fresh -eq 100 -and $u1.cache -eq 900) ("fresh=$($u1.fresh) cache=$($u1.cache)")
  $u2 = Get-UsageFromLine '{"type":"text","text":"hello"}'
  T 'MUST FIRE  a line with no usage record is null, not zero' ($null -eq $u2) 'not null'
  $u3 = Get-UsageFromLine '{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":0}}'
  T 'cache CREATION also counts as input' ($u3.in -eq 15) ([string]$u3.in)
  T 'cache creation is FULL-PRICE input, so it lands in fresh' ($u3.fresh -eq 15 -and $u3.cache -eq 0) ("fresh=$($u3.fresh) cache=$($u3.cache)")

  $ts = Get-LineTimestamp '{"timestamp":"2026-08-20T19:09:55.123Z","usage":{}}'
  T 'a line timestamp is read as a sortable stamp' ($ts -eq '2026-08-20T19:09:55') $ts
  T 'MUST FIRE  a line with no timestamp is not in any window' (-not (Test-InWindow (Get-LineTimestamp '{"x":1}') '2026-01-01' '2027-01-01')) 'in window'
  T 'a line inside the window counts' (Test-InWindow '2026-08-20T19:09:55' '2026-08-16' '2026-08-23') 'not counted'
  T 'MUST FIRE  the window is half-open: Until is EXCLUSIVE' (-not (Test-InWindow '2026-08-23T00:00:00' '2026-08-16' '2026-08-23')) 'counted'
  T 'MUST FIRE  a line before the window is excluded' (-not (Test-InWindow '2026-08-15T23:59:59' '2026-08-16' '2026-08-23')) 'counted'

  T 'a transcript that RAN the reviewer is attributed to this lane' (Test-ReviewLaneTranscript 'python graph/pipeline/review_escalations.py --ingest x.json') 'not attributed'
  T 'MUST FIRE  merely NAMING the reviewer does not attribute a transcript' (-not (Test-ReviewLaneTranscript 'see graph/pipeline/review_escalations.py for the lane')) 'attributed'
  T 'the packet emitter also counts as the lane' (Test-ReviewLaneTranscript 'review_escalations.py --emit-packet --limit 20') 'not attributed'

  T 'MUST FIRE  tokens per ruling with zero rulings is n/a, never a divide' ((Format-Rate 1000 0) -eq 'n/a') (Format-Rate 1000 0)
  T 'tokens per ruling divides' ((Format-Rate 1000 4) -eq '250') (Format-Rate 1000 4)

  $py = Get-Python
  T 'a real python interpreter is resolved (never the Store shim)' ($null -ne $py) 'none found'
  if ($py) {
    $q = Join-Path $here 'scorecard_query.py'
    T 'the query half is present' (Test-Path $q) $q
    $out = & $py $q --selftest
    T 'the read-only query self-test passes' ($LASTEXITCODE -eq 0) (($out | Select-Object -Last 1) -join '')
  }

  if ($bad -gt 0) { Write-Output ("scorecard SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'scorecard SELF-TEST PASS'
  Write-GuardComplete -Name 'scorecard' -Summary 'selftest pass'
  exit 0
}

# ---- window ----------------------------------------------------------------------------------------
if (-not $Since) { $Since = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd') }
if (-not $Until) { $Until = (Get-Date).AddDays(1).ToString('yyyy-MM-dd') }

$py = Get-Python
if (-not $py) { Write-Output 'scorecard: no python interpreter found'; exit 3 }
if (-not $Db) { $Db = Join-Path $graph 'sqlite\graph.db' }
if (-not (Test-Path $Db)) { Write-Output ("scorecard: no graph db at {0}" -f $Db); exit 3 }

$raw = & $py (Join-Path $here 'scorecard_query.py') --since $Since --until $Until --db $Db
if ($LASTEXITCODE -ne 0) { Write-Output ("scorecard: query failed: {0}" -f ($raw -join ' ')); exit 3 }
$g = ($raw -join "`n") | ConvertFrom-Json

# ---- Claude tokens, from transcripts, inside the SAME window -----------------------------------------
if (-not $TranscriptDir) {
  $TranscriptDir = Join-Path $env:USERPROFILE '.claude\projects'
}
#
# TWO BOUNDS, BOTH REPORTED, NEITHER PRETENDING TO BE THE OTHER. A Claude session is not a lane: the
# sessions that ran the reviewer also wrote code, captured stores and argued about schema in the same
# transcript, and nothing in the transcript separates those turns from the review turns. So:
#
#   session bound   every in-window token of every transcript that ran the reviewer. An UPPER bound -
#                   it charges this lane for everything else those sessions did.
#   stretch bound   only the tokens between the FIRST and LAST reviewer invocation in a transcript.
#                   Much tighter, still not exact: it misses packet-reading before the first
#                   invocation and includes any unrelated work between two of them.
#
# The true cost is between them. Printing one number would have been a guess wearing a decimal point.
# Cache READS are reported separately from fresh input because they dominate the total (a long session
# re-reads its context on every turn) and they are an order of magnitude cheaper - summing them 1:1
# with fresh input makes a coding session look like a review lane that spent a billion tokens.
$scanned = 0; $used = @()
$sessFresh = 0; $sessCache = 0; $sessOut = 0
$strFresh = 0; $strCache = 0; $strOut = 0
if (Test-Path $TranscriptDir) {
  # Only this repo's project directories. Scanning every project charges the board's lane with other
  # repositories' sessions, which is how a cost report ends up reporting someone else's cost.
  $dirs = @(Get-ChildItem $TranscriptDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*ThriftyCrew*' })
  foreach ($d in $dirs) {
    foreach ($f in @(Get-ChildItem $d.FullName -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue)) {
      $scanned++
      $lines = @([IO.File]::ReadAllLines($f.FullName))
      $first = -1; $last = -1
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if (Test-ReviewLaneTranscript $lines[$i]) { if ($first -lt 0) { $first = $i }; $last = $i }
      }
      if ($first -lt 0) { continue }
      $fFresh = 0; $fCache = 0; $fOut = 0; $sFresh = 0; $sCache = 0; $sOut = 0
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not (Test-InWindow (Get-LineTimestamp $lines[$i]) $Since $Until)) { continue }
        $u = Get-UsageFromLine $lines[$i]
        if (-not $u) { continue }
        $fFresh += $u.fresh; $fCache += $u.cache; $fOut += $u.out
        if ($i -ge $first -and $i -le $last) { $sFresh += $u.fresh; $sCache += $u.cache; $sOut += $u.out }
      }
      if (($fFresh + $fCache + $fOut) -le 0) { continue }
      $sessFresh += $fFresh; $sessCache += $fCache; $sessOut += $fOut
      $strFresh  += $sFresh; $strCache  += $sCache; $strOut  += $sOut
      $used += [pscustomobject]@{ transcript = $f.Name; session_total = ($fFresh + $fCache + $fOut)
                                  stretch_total = ($sFresh + $sCache + $sOut) }
    }
  }
}
$tokSession = $sessFresh + $sessCache + $sessOut
$tokStretch = $strFresh + $strCache + $strOut
$rulings    = [int]$g.claude_rulings_total

$card = [ordered]@{
  window                = @{ since = $Since; until = $Until }
  questions_asked       = $g.questions_asked
  settled_deterministic = $g.settled_by.deterministic
  settled_layer5        = $g.settled_by.layer5
  settled_other         = $g.settled_by.other
  model_calls           = $g.model_calls
  layer5_outcomes       = $g.layer5_outcomes
  sent_to_claude        = $rulings
  claude_rulings        = $g.claude_rulings
  claude_tokens_session = @{ fresh_input = $sessFresh; cache_read = $sessCache; output = $sessOut; total = $tokSession }
  claude_tokens_stretch = @{ fresh_input = $strFresh; cache_read = $strCache; output = $strOut; total = $tokStretch }
  tokens_per_ruling     = @{
    session_bound = $(if ($rulings -gt 0) { [int]($tokSession / $rulings) } else { $null })
    stretch_bound = $(if ($rulings -gt 0) { [int]($tokStretch / $rulings) } else { $null })
    stretch_excluding_cache_reads = $(if ($rulings -gt 0) { [int](($strFresh + $strOut) / $rulings) } else { $null })
  }
  queue_now             = $g.queue_now
  prior_authority_tiers = $g.prior_authority_tiers
  learning_proposals    = $g.learning_proposals
  transcripts_scanned   = $scanned
  transcripts_attributed = $used
}

if ($runJson) {
  ($card | ConvertTo-Json -Depth 6)
  Write-GuardComplete -Name 'scorecard' -Summary ("window={0}..{1} rulings={2}" -f $Since, $Until, $rulings)
  exit 0
}

$det = [int]$g.settled_by.deterministic; $l5 = [int]$g.settled_by.layer5
$tot = $det + $l5 + [int]$g.settled_by.other
Write-Output ("MATCHING LANE SCORECARD   {0} .. {1}   (exclusive end)" -f $Since, $Until)
Write-Output ''
Write-Output ("  questions asked                 {0,10:N0}   over {1} resolve run(s)" -f $g.questions_asked, @($g.resolve_runs).Count)
Write-Output ("  rows settled, deterministic     {0,10:N0}   {1}" -f $det, $(if ($tot -gt 0) { '{0:N1}% of settled rows' -f (100.0 * $det / $tot) } else { '-' }))
Write-Output ("  rows settled, layer 5 (local)   {0,10:N0}   {1}" -f $l5, $(if ($tot -gt 0) { '{0:N1}%' -f (100.0 * $l5 / $tot) } else { '-' }))
Write-Output ("  local model calls               {0,10:N0}" -f $g.model_calls)
if ($g.layer5_outcomes) {
  foreach ($p in $g.layer5_outcomes.PSObject.Properties) {
    Write-Output ("      {0,-24} {1,10:N0}" -f $p.Name, $p.Value)
  }
}
Write-Output ''
Write-Output ("  sent to Claude (rulings)        {0,10:N0}" -f $rulings)
foreach ($k in @('confirmed','rejected','deferred')) {
  $v = 0; if ($g.claude_rulings.PSObject.Properties.Name -contains $k) { $v = [int]$g.claude_rulings.$k }
  Write-Output ("      {0,-24} {1,10:N0}" -f $k, $v)
}
Write-Output ''
Write-Output ("  Claude transcripts attributed   {0,10:N0}   of {1:N0} scanned in this repo's projects" -f @($used).Count, $scanned)
Write-Output ("  tokens, SESSION bound (upper)   {0,10:N0}   fresh {1:N0} + cache-read {2:N0} + out {3:N0}" -f $tokSession, $sessFresh, $sessCache, $sessOut)
Write-Output ("  tokens, STRETCH bound (tighter) {0,10:N0}   fresh {1:N0} + cache-read {2:N0} + out {3:N0}" -f $tokStretch, $strFresh, $strCache, $strOut)
Write-Output ("  TOKENS PER CLAUDE RULING        {0,10}   session bound (charges the whole session)" -f (Format-Rate $tokSession $rulings))
Write-Output ("                                  {0,10}   stretch bound (first..last reviewer call)" -f (Format-Rate $tokStretch $rulings))
Write-Output ("                                  {0,10}   stretch, cache reads excluded" -f (Format-Rate ($strFresh + $strOut) $rulings))
Write-Output ''
Write-Output '  standing (not window-bounded):'
if ($g.queue_now) {
  foreach ($p in $g.queue_now.PSObject.Properties) { Write-Output ("      queue {0,-18} {1,10:N0}" -f $p.Name, $p.Value) }
}
if ($g.prior_authority_tiers) {
  foreach ($p in $g.prior_authority_tiers.PSObject.Properties) { Write-Output ("      priors {0,-17} {1,10:N0}" -f $p.Name, $p.Value) }
}
if ($g.learning_proposals) {
  foreach ($p in $g.learning_proposals.PSObject.Properties) { Write-Output ("      learning {0,-15} {1,10:N0}" -f $p.Name, $p.Value) }
}

# ---- THE LOCAL LANE (phase 2). Reads the two run artefacts, not the graph -----------------------
# Deliberately printed BELOW the token figures, because that is the order the plan reasons in: the
# question is always "what did a Claude ruling cost", and this section is the machinery whose job is
# to make that number smaller by asking for fewer of them. It reports what the machinery DID, and it
# is scrupulous about the difference between a zero and a BLIND.
Write-Output ''
Write-Output '  the local lane (nightly chain + helper scores):'
$ll = $g.local_lane
if (-not $ll) {
  Write-Output '      BLIND    this scorecard predates the local lane; re-run scorecard_query.py'
} else {
  if ($ll.nightly.state -ne 'ran') {
    Write-Output ("      nightly  BLIND    {0}" -f $ll.nightly.why)
  } else {
    $bl = @($ll.nightly.blind_stages)
    Write-Output ("      nightly  ran {0}  in {1}s, contested {2}" -f $ll.nightly.at, $ll.nightly.elapsed_sec, $(if ($null -eq $ll.nightly.contested) { 'n/a' } else { $ll.nightly.contested }))
    # THE ONE LINE THAT IS ABOUT RIGHT NOW. Everything else here is history; a card still held is a
    # BLIND 07:00 sweep tomorrow, and it wants to be read as an alarm, not as a statistic.
    if ($ll.nightly.card_free -eq $true) { Write-Output ("               card handed back, {0} MiB free" -f $ll.nightly.free_vram_mib) }
    else { Write-Output '               *** THE CARD WAS NOT HANDED BACK - llama-server may still hold it, and the next semantic sweep will go BLIND ***' }
    if ($bl.Count) { Write-Output ("               stages not clean: {0}" -f ($bl -join ', ')) }
  }
  if ($ll.helper.state -ne 'ran') {
    Write-Output ("      helper   BLIND    {0}" -f $ll.helper.why)
  } else {
    Write-Output ("      helper   scored {0} of {1} contested pair(s), {2} with no sidecar definition" -f $ll.helper.scored, $ll.helper.offered, $ll.helper.no_definition)
    Write-Output ("               warmed {0} vector(s) in {1}s; routes {2}" -f $ll.helper.vectors_warmed, $ll.helper.elapsed_sec, $ll.helper.routes)
  }
}

if ($rulings -eq 0) {
  Write-Output ''
  Write-Output '  NOTE no Claude rulings in this window, so tokens-per-ruling is n/a rather than 0.'
}
Write-GuardComplete -Name 'scorecard' -Summary ("window={0}..{1} questions={2} rulings={3} tokens={4}(session)/{5}(stretch)" -f $Since, $Until, $g.questions_asked, $rulings, $tokSession, $tokStretch)
exit 0
