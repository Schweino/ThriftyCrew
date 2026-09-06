<#
  triage-due.ps1 - 2-second guard for the grocery-alert-triage scheduled agent.
  Prints IDLE (nothing open) or DUE with a compact list of open queue items. The agent runs hourly while
  the Claude app is open precisely so that a queue written while the app was CLOSED gets drained on the
  first tick after Brad opens it - the guard is what makes that cheap.
  -SelfTest runs the RE-MEASURE FIRST fixtures against a temp git repo and exits, touching no live file.
#>
# [CmdletBinding()] so -SelfTest cannot fall into $args and run the LIVE report instead ([[arg-silently-ignored]]).
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$qFile = Join-Path $root 'triage-queue.json'

# ---- DID THE EMITTING CODE CHANGE AFTER THE ALERT FIRED? (2026-09-05, queue 2026-09-04-bf1642) ----------
# FOUNDING CASE: alert 2026-09-04-bf1642 fired at 14:57:31 saying the recipe pool's dedup evidence had gone
# stale. Commit bb8de6a0 landed at 15:56:16 - 59 minutes later - and DELETED the arm that emitted that body.
# The alert was stale by construction the moment the fix landed, and nothing said so: a queue item recorded
# what broke and when, never which code said so. Proving it stale cost a git log across three files plus a
# timestamp comparison, and every triage round would pay that again for every same-day fix in this estate.
# So send-alert.ps1 now stamps `emitter` (a repo-relative path) on new items, and this prints one line.
# ADVISORY, NEVER FATAL. Three ways this must stay quiet rather than break:
#   - an item written before 2026-09-05 has no emitter field at all,
#   - an emitter whose path was renamed or deleted has no commits under that name,
#   - git may be missing, or the tree may not be a repo.
# Each of those is "I cannot tell", and the correct output for "I cannot tell" is nothing. A triage guard
# that throws is a triage tick that does not happen.
function Get-EmitterCommitTime {
  <# .SYNOPSIS Committer time of the newest commit touching RelPath, or $null. Pure, never throws. #>
  param([string]$RepoDir, [string]$RelPath)
  if (-not $RelPath -or -not $RepoDir) { return $null }
  # NEVER 2>&1, AND NEVER A REDIRECT UNDER EAP=Stop. In PS 5.1 redirecting a native command's stderr wraps
  # each line in a NativeCommandError, and with $ErrorActionPreference='Stop' the first one is a terminating
  # throw - the exact shape that killed capture-run on 2026-08-22. Dropping to Continue first makes the
  # redirect safe, and the redirect is what keeps git's "fatal: not a git repository" out of a triage report
  # that has to stay readable. Restored in the finally either way.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& git -C $RepoDir log -1 --format=%cI -- $RelPath 2>$null) | Where-Object { $_ } | Select-Object -First 1
    if (-not $out) { return $null }
    return ([datetimeoffset]::Parse(([string]$out).Trim(), [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
  } catch { return $null }
  finally { $ErrorActionPreference = $prev }
}
function Get-RemeasureLines {
  <# .SYNOPSIS One 'RE-MEASURE FIRST' line per open item whose emitter changed after the item's ts. #>
  param($Items, [string]$RepoDir)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($i in @($Items)) {
    $em = ''
    if ($i -and $i.PSObject.Properties['emitter']) { $em = ([string]$i.emitter).Trim() }
    if (-not $em) { continue }
    $ct = Get-EmitterCommitTime $RepoDir $em
    if ($null -eq $ct) { continue }
    $its = $null
    try { $its = [datetime]([string]$i.ts) } catch { $its = $null }
    if ($null -eq $its) { continue }
    if ($ct -gt $its) {
      [void]$lines.Add(('  RE-MEASURE FIRST: ' + [string]$i.id + ' - ' + $em + ' changed at ' + $ct.ToString('s') +
                        ', AFTER this alert fired at ' + $its.ToString('s') + '. The behaviour it describes may already be gone.'))
    }
  }
  return $lines
}

if ($SelfTest) {
  $fail = 0; $cases = 0
  function _T([string]$label, [bool]$cond, [string]$detail) {
    $script:cases++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ } }
  $fx = Join-Path $env:TEMP ('triagedue-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  # git writes progress and hints to stderr; under EAP=Stop one of those lines can end this run. The live
  # path above never shells out under Stop for that reason, and the fixture builder below shells out a lot.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    New-Item -ItemType Directory -Force (Join-Path $fx 'grocery') | Out-Null
    Set-Content (Join-Path $fx 'grocery\emitter.ps1') '# the arm that emitted the alert' -Encoding UTF8
    & git -C $fx init --quiet | Out-Null
    & git -C $fx config user.name t | Out-Null
    & git -C $fx config user.email t@t | Out-Null
    & git -C $fx add -A | Out-Null
    & git -C $fx commit -q -m 'the same-day fix that removed the emitting arm' | Out-Null
    $ct = Get-EmitterCommitTime $fx 'grocery/emitter.ps1'
    _T 'the resolver reads a real committer time out of git for a tracked emitter' ($null -ne $ct) 'got $null'

    if ($null -ne $ct) {
      # MUST FIRE: the founding shape. The alert fired an hour BEFORE the commit that changed its emitter.
      $firedBefore = @([pscustomobject]@{ id = '2026-09-04-bf1642'; ts = $ct.AddHours(-1).ToString('s'); emitter = 'grocery/emitter.ps1' })
      $l = @(Get-RemeasureLines $firedBefore $fx)
      _T 'MUST-FIRE an emitter committed AFTER the alert fired prints RE-MEASURE FIRST, naming the item' `
        ($l.Count -eq 1 -and ($l -join ' ') -match 'RE-MEASURE FIRST' -and ($l -join ' ') -match '2026-09-04-bf1642' -and ($l -join ' ') -match 'grocery/emitter\.ps1') `
        (($l -join ' | '))
      # CLEAN TWIN: the alert fired an hour AFTER the last commit, so it describes live behaviour.
      $firedAfter = @([pscustomobject]@{ id = '2026-09-04-bf1642'; ts = $ct.AddHours(1).ToString('s'); emitter = 'grocery/emitter.ps1' })
      _T 'CLEAN TWIN an emitter last committed BEFORE the alert fired prints nothing' `
        ((@(Get-RemeasureLines $firedAfter $fx)).Count -eq 0) 'a line was printed'
    }
    # CLEAN TWIN: every item written before 2026-09-05 has no emitter field. Silence, never a failure.
    $noEmitter = @([pscustomobject]@{ id = '2026-08-01-aaaaaa'; ts = '2026-08-01T09:00:00' })
    _T 'CLEAN TWIN an item with no emitter field at all prints nothing and does not throw' `
      ((@(Get-RemeasureLines $noEmitter $fx)).Count -eq 0) 'a line was printed'
    # CLEAN TWIN: a renamed or deleted emitter has no commits under that name. Nothing to say, NOT an error.
    $renamed = @([pscustomobject]@{ id = '2026-09-01-bbbbbb'; ts = '2026-09-01T09:00:00'; emitter = 'grocery/this-file-was-renamed.ps1' })
    _T 'CLEAN TWIN a renamed or missing emitter path prints nothing and does not error' `
      ((@(Get-RemeasureLines $renamed $fx)).Count -eq 0) 'a line was printed'
    # CLEAN TWIN: not a git repository at all. "I cannot tell" is not "nothing changed", and neither is a crash.
    $noRepo = Join-Path $env:TEMP ('triagedue-norepo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $noRepo | Out-Null
    try {
      _T 'CLEAN TWIN a directory that is not a git repo prints nothing and does not throw' `
        ((@(Get-RemeasureLines $renamed $noRepo)).Count -eq 0) 'a line was printed'
    } finally { Remove-Item $noRepo -Recurse -Force -ErrorAction SilentlyContinue }
    # An unparseable ts must not throw either - a queue item is data, and data can be wrong.
    $badTs = @([pscustomobject]@{ id = '2026-09-01-cccccc'; ts = 'not a date'; emitter = 'grocery/emitter.ps1' })
    _T 'CLEAN TWIN an unparseable item ts prints nothing rather than throwing' `
      ((@(Get-RemeasureLines $badTs $fx)).Count -eq 0) 'a line was printed'
  } finally {
    $ErrorActionPreference = $prevEap
    Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases triage-due cases)"
  exit 0
}
# EMAIL MUTED? (2026-08-14) Say so up front. With the inbox silenced, this guard and the agent behind it are
# the ONLY thing that notices an alert, so the mute has to be visible exactly where the response happens -
# an indefinite mute nobody is reminded of is how a rule silently outlives its reason.
#
# ASK THE MAILER'S OWN RULE, do not re-decide it here (2026-08-31). This used to be a bare
# `if (Test-Path $muteFile)`, which is not the same question send-alert.ps1 answers: the documented
# in-place off switch is `muted:false`, which KEEPS the file so the mute period stays on the record.
# So the day the mail came back this banner went on announcing "email alerts are OFF" above a queue
# that was being emailed normally. One copy now, in mute-lib.ps1.
$muteFile = Join-Path $root 'alerts-muted.json'
. (Join-Path $root 'mute-lib.ps1')
$mute = Get-MuteState -Path $muteFile -Today (Get-Date -Format 'yyyy-MM-dd')
if ($mute.muted) {
  Write-Output ('MUTED  email alerts are OFF (' + $mute.why + ', grocery\alerts-muted.json) - alerts still queue here and still get worked; only the mail stopped.')
}
if (-not (Test-Path $qFile)) { Write-Output 'IDLE  no triage queue file - no alert has ever fired'; exit 0 }
# FAIL CLOSED. 2026-07-28: send-alert.ps1 rewrote this file in place, and a read landing inside that window
# returned an empty string. '' | ConvertFrom-Json yields $null in PS 5.1 WITHOUT throwing, so the catch below
# never fired, $q.items was $null, and the guard printed IDLE while 5 real alerts sat open - the tick was
# skipped and Brad had to notice the emails himself. Writes are atomic now; this retries anyway (a swap is
# still a moment where the handle can miss) and treats "cannot read a queue that exists" as DUE, never IDLE.
$q = $null
for ($try = 1; $try -le 4; $try++) {
  try {
    # -Encoding utf8 (worklist C5): PS 5.1 decodes a BOM-less file as ANSI, so the triage agent
    # was shown mangled product names even though this reader never writes the file back.
    $raw = Get-Content $qFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ($raw -and $raw.Trim()) { $q = $raw | ConvertFrom-Json }
  } catch { $q = $null }
  if ($q -and $q.PSObject.Properties['items']) { break }
  $q = $null
  Start-Sleep -Milliseconds 250
}
if (-not $q) { Write-Output 'DUE  triage-queue.json exists but read back empty/unparseable after 4 tries - that itself is the first item to fix'; exit 0 }
$open = @($q.items | Where-Object { $_.status -eq 'open' })
# a spool file means send-alert could not reach the queue at all - those alerts are unworked by definition
$spools = @(Get-ChildItem (Join-Path $root 'triage-spool-*.jsonl') -ErrorAction SilentlyContinue)
if ($spools.Count -gt 0) {
  Write-Output ('DUE  ' + $spools.Count + ' triage SPOOL file(s) - send-alert could not write the queue; drain and delete them:')
  foreach ($s in $spools) { Write-Output ('  ' + $s.Name) }
}
$needsBrad = @($q.items | Where-Object { $_.status -eq 'needs-brad' })
if ($open.Count -eq 0 -and $spools.Count -gt 0) { exit 0 }   # spool lines above already said DUE
if ($open.Count -eq 0) {
  $nb = ''; if ($needsBrad.Count) { $nb = ' (' + $needsBrad.Count + ' item(s) parked needs-brad - do not re-triage, they are his)' }
  Write-Output ('IDLE  triage queue clear' + $nb); exit 0
}
Write-Output ("DUE  " + $open.Count + " open alert(s) to triage:")
foreach ($i in $open) { Write-Output ('  [' + $i.id + '] x' + $i.count + '  ' + $i.subject) }
# An item whose emitter was committed after the alert fired may be describing code that no longer exists.
# Wrapped: this is provenance, and provenance must never cost a triage tick.
try { foreach ($l in (Get-RemeasureLines $open (Split-Path -Parent $root))) { Write-Output $l } } catch { }

# ---------------------------------------------------------------- BOARD GENERATION, pinned for both stages
# WHY (2026-08-06): the reviewer froze a 26,013-name routing corpus at 06:44 against comparison-2026-08-05, a
# board build landed at ~06:50, and the developer then implemented against 08-06 data. Three of six items came
# back "deviated" and EVERY deviation traced to the board moving underneath the plan, not to a bad diagnosis:
# coverage gaps re-derived 43/8 against the plan's 51/7, a 21st aisle BLOCK appeared, and a cell the plan
# called an empty gap had been filled by a wrong product. The developer paid a second time for a measurement
# the reviewer had already bought. Nothing here blocks a run - the whole point of this system is that an
# alert never waits - but both stages must be able to name the generation they measured, and starting inside
# a build is worth one line of warning.
$outDir = Join-Path $root 'out'
$cmp = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
if (-not $cmp.Count) {
  Write-Output 'BOARD UNKNOWN  no comparison-*.json on disk - measure nothing against "the board" until one exists'
} else {
  $newest = $cmp[0]
  $ageMin = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
  Write-Output ("BOARD " + $newest.BaseName + "  built " + $newest.LastWriteTime.ToString('HH:mm:ss') + " (" + $ageMin + " min ago)")
  # MID-BUILD: compare-deals writes candidates-*.json a beat BEFORE comparison-*.json, so candidates being the
  # newer of the two means a build is in flight right now and neither file is a stable thing to measure.
  $cand = @(Get-ChildItem (Join-Path $outDir 'candidates-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
  if ($cand.Count -and $cand[0].LastWriteTime -gt $newest.LastWriteTime) {
    Write-Output '  MID-BUILD: candidates is newer than comparison, so a board build is writing RIGHT NOW.'
    Write-Output '             Wait for it to finish before measuring, or the plan will be stale on arrival.'
  } elseif ($ageMin -le 10) {
    Write-Output '  JUST LANDED: this board is minutes old, which usually means a build just finished or another'
    Write-Output '               is close behind. Pin this generation in the plan and re-check it before shipping.'
  }
  Write-Output ('  Pin it: the reviewer records this name in board_week, the developer re-checks it before acting,')
  Write-Output ('  and any item whose freshness line names a different generation gets re-measured, not assumed.')
}
exit 0
