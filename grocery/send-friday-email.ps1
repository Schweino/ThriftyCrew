<#
  send-friday-email.ps1 - Puts the built Friday email into Ghost.

  DEFAULTS TO A DRAFT. An email cannot be recalled, so this script will not send one unless you pass
  -Send explicitly. Without it you get an email-only draft in Ghost that you can preview, send a test
  of, and publish by hand. That is the right default for a weekly send whose whole job is to build
  trust with a list that took a month to collect.

  The post is EMAIL-ONLY (email_only=true). It deliberately does NOT become a page on the site: 52
  near-identical "grocery prices, week of X" posts a year is exactly the thin-content pattern that got
  475 URLs left uncrawled by Google in the first place (see lib\trend-keep.ps1).

  ONCE PER WEEK. A stamp file records the week_of already sent, so a double-run - a retried scheduled
  task, a manual run after the automation - cannot mail the list twice. -Force overrides.

  AND AN UNKNOWN OUTCOME IS NEVER REPLAYED (2026-09-19, backlog I198). The stamp above is written only
  AFTER Ghost answers, so on its own it cannot cover the window where Ghost accepted the send and the
  answer never arrived: a 60 s timeout, a 5xx after the effect, or this process dying before the stamp.
  So a -Send run writes TWO records, each atomically and flushed to disk:
      friday-email.invoking   the week, written BEFORE the POST   ("invoking week W")
      friday-email.stamp      the week, written AFTER it returns  ("sent week W", the stamp as it always was)
  A run that finds invoking = W while the stamp is not W does not know whether the list got week W, so
  it REFUSES, pages Brad through alert-lib's Send-Alert, and exits 1. Check Ghost's email log for week W:
  if it went out, write W into the stamp; if it did not, re-run with -Force. A POST that fails in a way
  that proves nothing reached Ghost (the name did not resolve, the connection was refused) clears the
  marker, so an outage before the send never needs a human. lib\ghost-lib.ps1 carries the other half: it
  no longer replays a POST whose reply was lost.
  BOTH FILES ARE GITIGNORED, AND ON PURPOSE (2026-09-18, backlog I231). Until then neither was tracked or
  ignored, and grocery/out is on the ~07:00 bot's staging list (lib\bot-paths.ps1), so the bot would have
  committed them the morning after the first -Send. They record what THIS machine mailed: a tracked copy can
  be rewound to an older week by a checkout, a restore or the bot's own rebase, which would re-arm a double
  send, and an untracked-but-unignored one is deleted by `git clean -fd`. A worktree has neither record, so
  run -Send from the main checkout only.

  Usage:
    powershell -File send-friday-email.ps1              # build + create draft (safe)
    powershell -File send-friday-email.ps1 -Send        # build + actually mail the list
    powershell -File send-friday-email.ps1 -SelfTest    # the once-per-week guard against stubs; mails nobody
#>
param([switch]$Send, [switch]$Force, [switch]$SkipBuild, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here '..\lib\ghost-lib.ps1')
. (Join-Path $here '..\lib\atomic-write.ps1')   # Write-TcAtomicFile: the two week records must never be half-written

function Read-FridayWeekFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return ([IO.File]::ReadAllText($Path)).Trim()
}

function Write-FridayWeekFile([string]$Path, [string]$Week) {
  # The bytes the stamp always had (WriteAllText, UTF-8, no BOM, no newline), now through a replace that
  # a reader cannot tear, and flushed: a record that is not re-derived if its last write is lost.
  [void](Write-TcAtomicFile -Path $Path -Text $Week -NoBom -NoNewline -Flush)
}

function Send-FridayPost([string]$Uri, [hashtable]$Headers, [byte[]]$Bytes) {
  # THE one POST. Invoke-GhostApi attempts it once unless the failure proves Ghost never received it.
  return (Invoke-GhostApi -Method POST -Uri $Uri -Headers $Headers -Body $Bytes -TimeoutSec 60)
}

function Invoke-FridayEmailPost {
  <# The once-per-week decision and the two week records around the POST. -Post makes the call and
     -Alert pages; both are passed in so the self-test can count them. Returns outcome
     sent | draft | already-sent | refused, and the saved post for sent and draft. #>
  param([string]$Week, [bool]$IsSend, [bool]$IsForce, [string]$StampFile, [string]$MarkerFile,
        [scriptblock]$Post, [scriptblock]$Alert)
  $sentWeek = Read-FridayWeekFile $StampFile
  $invokingWeek = Read-FridayWeekFile $MarkerFile
  if ($IsSend -and ($sentWeek -eq $Week) -and -not $IsForce) {
    return [pscustomobject]@{ outcome = 'already-sent'; saved = $null }
  }
  if ($IsSend -and ($invokingWeek -eq $Week) -and ($sentWeek -ne $Week) -and -not $IsForce) {
    $why = ("A -Send for week {0} began (friday-email.invoking says {0}) and never recorded that it finished (friday-email.stamp says '{1}'). Ghost may or may not have mailed the list. This run sent NOTHING. Check Ghost's email log for week {0}: if it went out, write {0} into {2}; if it did not, re-run send-friday-email.ps1 -Send -Force." -f $Week, $sentWeek, $StampFile)
    & $Alert $why
    return [pscustomobject]@{ outcome = 'refused'; saved = $null; why = $why }
  }
  if ($IsSend) { Write-FridayWeekFile $MarkerFile $Week }   # invoking week W: BEFORE anything can reach Ghost
  try {
    $saved = & $Post
  } catch {
    # Proven never sent: nothing to be unsure about, so the marker goes and the next run may send.
    if ($IsSend -and (Test-TcGhostNeverSent $_.Exception) -and ((Read-FridayWeekFile $MarkerFile) -eq $Week)) {
      Remove-Item -LiteralPath $MarkerFile -Force
    }
    throw
  }
  if ($IsSend) {
    Write-FridayWeekFile $StampFile $Week                   # sent week W
    return [pscustomobject]@{ outcome = 'sent'; saved = $saved }
  }
  return [pscustomobject]@{ outcome = 'draft'; saved = $saved }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fails = 0; $script:cases = 0
  function Check([string]$Label, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:fails++ }
  }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('sfe-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
  $stamp = Join-Path $dir 'friday-email.stamp'
  $marker = Join-Path $dir 'friday-email.invoking'
  $script:posts = 0; $script:alerts = 0
  $countPost = { $script:posts++; return [pscustomobject]@{ id = 'stub' } }
  $countAlert = { param($m) $script:alerts++ }
  function Reset-Case { $script:posts = 0; $script:alerts = 0; foreach ($p in @($stamp, $marker)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } }
  $W = '2026-09-18'; $prev = '2026-09-11'
  # The transport seam from lib\ghost-lib.ps1, so the end-to-end cases run the real Send-FridayPost and the
  # real Invoke-GhostApi retry loop against a stub. Nothing here can reach Ghost.
  $script:transportCalls = 0; $script:transportPlan = @()
  function Invoke-TcGhostTransport { param([hashtable]$CallArgs, [switch]$Web)
    $i = $script:transportCalls; $script:transportCalls++
    $step = if ($i -lt $script:transportPlan.Count) { $script:transportPlan[$i] } else { $script:transportPlan[-1] }
    if ($step -is [Exception]) { throw $step }
    return $step }
  function Wait-TcGhostRetry { param([int]$Seconds) }
  $realPost = { Send-FridayPost -Uri 'https://invalid.invalid/ghost/api/admin/posts/?newsletter=x' -Headers @{} -Bytes ([byte[]](1, 2)) }
  try {
    $env:TC_STAGE_WRITES = $null; $env:TC_WRITE_JOURNAL = $null

    Reset-Case; Write-FridayWeekFile $marker $W
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'MUST FIRE  invoking W without sent W REFUSES: zero POSTs, one alert, outcome refused' (($script:posts -eq 0) -and ($script:alerts -eq 1) -and ($r.outcome -eq 'refused')) ("posts=" + $script:posts + " alerts=" + $script:alerts + " outcome=" + $r.outcome)
    Check 'MUST FIRE  the refusal leaves both records as it found them' (((Read-FridayWeekFile $marker) -eq $W) -and -not (Test-Path -LiteralPath $stamp)) ("marker=" + (Read-FridayWeekFile $marker) + " stamp=" + (Read-FridayWeekFile $stamp))

    Reset-Case
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'CLEAN TWIN a clean week sends EXACTLY ONCE and leaves sent W (and invoking W)' (($script:posts -eq 1) -and ($r.outcome -eq 'sent') -and ((Read-FridayWeekFile $stamp) -eq $W) -and ((Read-FridayWeekFile $marker) -eq $W) -and ($script:alerts -eq 0)) ("posts=" + $script:posts + " outcome=" + $r.outcome + " stamp=" + (Read-FridayWeekFile $stamp))
    Check 'CLEAN TWIN the stamp keeps its old bytes: the week, no BOM, no newline' ([IO.File]::ReadAllBytes($stamp).Length -eq 10) ("bytes=" + [IO.File]::ReadAllBytes($stamp).Length)

    Reset-Case; Write-FridayWeekFile $marker $prev; Write-FridayWeekFile $stamp $prev
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'CLEAN TWIN last week finished cleanly, so this week sends once with no alert' (($script:posts -eq 1) -and ($script:alerts -eq 0) -and ($r.outcome -eq 'sent')) ("posts=" + $script:posts + " alerts=" + $script:alerts)

    Reset-Case; Write-FridayWeekFile $marker $W; Write-FridayWeekFile $stamp $W
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'CLEAN TWIN the old stamp guard still holds: sent W is already-sent, no POST, no alert' (($script:posts -eq 0) -and ($script:alerts -eq 0) -and ($r.outcome -eq 'already-sent')) ("posts=" + $script:posts + " outcome=" + $r.outcome)

    Reset-Case; Write-FridayWeekFile $marker $W
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $true -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'CLEAN TWIN -Force after a human checked Ghost sends once' (($script:posts -eq 1) -and ($r.outcome -eq 'sent')) ("posts=" + $script:posts + " outcome=" + $r.outcome)

    Reset-Case
    $r = Invoke-FridayEmailPost -Week $W -IsSend $false -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $countPost -Alert $countAlert
    Check 'CLEAN TWIN a draft run posts once and writes neither record' (($script:posts -eq 1) -and ($r.outcome -eq 'draft') -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $stamp)) ("posts=" + $script:posts + " outcome=" + $r.outcome)

    # END TO END through the real Invoke-GhostApi: Ghost takes the send and the reply times out.
    Reset-Case; $script:transportCalls = 0
    $script:transportPlan = @((New-Object System.Net.WebException('The operation has timed out', [System.Net.WebExceptionStatus]::Timeout)))
    $threw = $false
    try { $null = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $realPost -Alert $countAlert } catch { $threw = $true }
    Check 'MUST FIRE  a POST that times out is attempted EXACTLY ONCE, and the run throws' (($script:transportCalls -eq 1) -and $threw) ("transport calls=" + $script:transportCalls + " threw=" + $threw)
    Check 'MUST FIRE  the timeout leaves invoking W and no stamp, the crash window on disk' (((Read-FridayWeekFile $marker) -eq $W) -and -not (Test-Path -LiteralPath $stamp)) ("marker=" + (Read-FridayWeekFile $marker) + " stamp=" + (Read-FridayWeekFile $stamp))
    $script:transportCalls = 0; $script:transportPlan = @([pscustomobject]@{ posts = @([pscustomobject]@{ id = 'dup' }) })
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $realPost -Alert $countAlert
    Check 'MUST FIRE  so the NEXT run refuses: zero transport calls, one alert' (($script:transportCalls -eq 0) -and ($r.outcome -eq 'refused') -and ($script:alerts -eq 1)) ("transport calls=" + $script:transportCalls + " outcome=" + $r.outcome + " alerts=" + $script:alerts)

    # CLEAN TWIN: an outage that provably stopped the request before Ghost clears the marker by itself.
    Reset-Case; $script:transportCalls = 0
    $script:transportPlan = @((New-Object System.Net.WebException('Unable to connect to the remote server', [System.Net.WebExceptionStatus]::ConnectFailure)))
    $threw = $false
    try { $null = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $realPost -Alert $countAlert } catch { $threw = $true }
    Check 'CLEAN TWIN a refused connection is retried (1 + 3 attempts), then clears invoking W' (($script:transportCalls -eq 4) -and $threw -and -not (Test-Path -LiteralPath $marker)) ("transport calls=" + $script:transportCalls + " marker present=" + (Test-Path -LiteralPath $marker))
    $script:transportCalls = 0; $script:transportPlan = @([pscustomobject]@{ posts = @([pscustomobject]@{ id = 'ok' }) })
    $r = Invoke-FridayEmailPost -Week $W -IsSend $true -IsForce $false -StampFile $stamp -MarkerFile $marker -Post $realPost -Alert $countAlert
    Check 'CLEAN TWIN and the next run sends once and records sent W' (($script:transportCalls -eq 1) -and ($r.outcome -eq 'sent') -and ((Read-FridayWeekFile $stamp) -eq $W)) ("transport calls=" + $script:transportCalls + " outcome=" + $r.outcome)

    # THE TWO RECORDS ARE MACHINE-LOCAL AND GITIGNORED (2026-09-18, backlog I231). grocery/out is on the bot's
    # INPUTS list (lib\bot-paths.ps1), so capture-run's `git add -A -- grocery/out` would commit them the first
    # morning after a -Send, and a tracked copy is one checkout, restore or `rebase -X theirs` away from being
    # rewound to an older week, which re-arms a double mail. Asked of git by FILE path, never the directory form.
    $repoRoot = Split-Path $here -Parent
    $ignored = @()
    foreach ($rel in @('grocery/out/friday-email.stamp', 'grocery/out/friday-email.invoking')) {
      & git -C $repoRoot check-ignore -q --no-index $rel
      if ($LASTEXITCODE -eq 0) { $ignored += $rel }
    }
    Check 'MUST FIRE  both week records are gitignored, so the bot''s grocery/out sweep cannot commit them' ($ignored.Count -eq 2) ("ignored: " + ($ignored -join ', '))
    & git -C $repoRoot ls-files --error-unmatch 'grocery/out/friday-email.html' | Out-Null
    $htmlTracked = ($LASTEXITCODE -eq 0)
    Check 'CLEAN TWIN the built email beside them is still tracked, so the ignore rule is no wider than the two records' $htmlTracked ("ls-files rc=" + $LASTEXITCODE)
  } catch {
    $script:fails++; Write-Output ('FAIL  the suite threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 15
  if ($script:cases -ne $expected) { $script:fails++; Write-Output ("FAIL  ran {0} of {1} cases" -f $script:cases, $expected) }
  if ($script:fails) { Write-Output ("send-friday-email self-test: FAIL ({0} of {1} cases failed)" -f $script:fails, $script:cases); exit 1 }
  Write-Output ("send-friday-email self-test: PASS ({0} of {0} cases)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
$apiUrl     = 'https://map-to-success.ghost.io'
$newsletter = 'default-newsletter'          # "Thrifty Crew" - the one free signups auto-join
$OutDir     = Join-Path $here 'out'
$htmlFile   = Join-Path $OutDir 'friday-email.html'
$metaFile   = Join-Path $OutDir 'friday-email.json'
$stampFile  = Join-Path $OutDir 'friday-email.stamp'
$markerFile = Join-Path $OutDir 'friday-email.invoking'

if (-not $SkipBuild) {
  & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'build-friday-email.ps1') | ForEach-Object { Write-Host ('  ' + $_) }
  if ($LASTEXITCODE -ne 0) { throw "build-friday-email.ps1 failed (rc=$LASTEXITCODE) - nothing sent." }
}
if (-not (Test-Path $htmlFile)) { throw "missing $htmlFile" }

$meta = Read-JsonFile $metaFile
$html = [IO.File]::ReadAllText($htmlFile, [Text.Encoding]::UTF8)
if ($html.Length -lt 400) { throw "built email is only $($html.Length) chars - refusing to mail a stub." }

# A week with no staples priced is a pipeline failure, not a quiet week. Do not mail it.
if ([int]$meta.staples -eq 0) { throw "the staples table came out empty - that is a board problem, not a slow news week. Nothing sent." }

$week = [string]$meta.week

$key = Get-GhostKey -Root (Split-Path $here -Parent)
$jwt = Get-GhostJWT -Key $key
$h   = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' }

$title  = [string]$meta.subject
$lex    = Get-GhostLexical -Html $html
$status = if ($Send) { 'published' } else { 'draft' }

$post = [ordered]@{
  title      = $title
  lexical    = $lex
  status     = $status
  email_only = $true
  # MUST be set explicitly. The site's default post visibility is "paid", and a Friday email created
  # without this went out flagged paid - i.e. the free weekly email promised on the board would have
  # reached the 2 paying members and gated everyone else. The whole point of this send is the free list.
  visibility = 'public'
  tags       = @(@{ name = '#friday-email' })   # internal tag: keeps these out of every public list
}
$body = ConvertTo-Json @{ posts = @($post) } -Depth 14
$bytes = [Text.Encoding]::UTF8.GetBytes($body)

# ?newsletter= is what turns a publish into a send. It is only meaningful when status=published, so a
# draft run carries it harmlessly and mails nobody.
$uri = "$apiUrl/ghost/api/admin/posts/?newsletter=$newsletter&email_segment=all"
$livePost = { Send-FridayPost -Uri $uri -Headers $h -Bytes $bytes }
. (Join-Path $here 'alert-lib.ps1')   # Send-Alert: the estate's one pager (queue first, mail second)
$liveAlert = {
  param($why)
  Send-Alert -Subject 'Friday email refused: a send for this week may already have gone out' -Body $why -What 'FRIDAY-EMAIL' | Out-Null
}
$res = Invoke-FridayEmailPost -Week $week -IsSend ([bool]$Send) -IsForce ([bool]$Force) -StampFile $stampFile -MarkerFile $markerFile -Post $livePost -Alert $liveAlert

if ($res.outcome -eq 'already-sent') {
  Write-Host ("already sent for week {0} - nothing to do (use -Force to override)" -f $week) -ForegroundColor Yellow
  exit 0
}
if ($res.outcome -eq 'refused') {
  Write-Host ("REFUSED week={0}: {1}" -f $week, $res.why) -ForegroundColor Red
  exit 1
}
$saved = $res.saved.posts[0]
if ($Send) {
  Write-Host ("SENT  week={0}  subject: {1}" -f $week, $title) -ForegroundColor Green
  Write-Host ("  email_only={0}  status={1}  id={2}" -f $saved.email_only, $saved.status, $saved.id)
} else {
  Write-Host ("DRAFT created (nothing mailed). Review it in Ghost, then hit Publish, or re-run with -Send." -f $null) -ForegroundColor Cyan
  Write-Host ("  subject : {0}" -f $title)
  Write-Host ("  week={0}  staples={1}  drops={2}  records={3}" -f $week, $meta.staples, $meta.drops, $meta.records)
  Write-Host ("  edit    : {0}/ghost/#/editor/post/{1}" -f $apiUrl, $saved.id)
}
