<#
  incident-trigger.ps1 - open an INCIDENT draft when the estate records the same thing breaking three times.

  WS 10f of design\PLAN-brain-v2-2026-09-09.md.

  WHY. docs\INCIDENT-TEMPLATE.md: the estate wrote one excellent postmortem in its life and never a
  second, and a test philosophy made of must-fire fixtures keeps prompting for prevention and never for
  "would we notice this faster next time". Nothing PROMPTED an incident record at all. The events that
  should have are already recorded; this reads them.

  TRIGGERS, from what the estate already writes:
    alert confirmed x3     three alert-closed events, disposition confirmed, for one alert type inside 30
                           days (grocery\triage-close.ps1 writes them to the event bus).
    gate red x3            three gate-red events naming the same gate inside 14 days (ops\run-gates.ps1).
    known-wrong reversed   a grocery\known-wrong.json entry whose reversed_on is inside 30 days: a ruling
                           that was itself wrong, which is the worst kind of right-looking data.

  WHAT IT WRITES, and only with -Write: grocery\INCIDENT-<date>-<slug>.md with Status: DRAFT, the
  template's header, a timeline built from the rows that tripped it, and the gap between the first sign
  and this draft filled in. Every section a person owns says so. A trigger whose Trigger-Key already
  appears in any INCIDENT-*.md is never opened twice.

  A PLAUSIBILITY BAR: at most $MaxDrafts per run. A bus that trips ten triggers at once is more likely a
  broken producer than ten incidents, so the rest are REFUSED and the refusal is spoken - the same rule
  lib\ratchet.ps1 and promote_aliases.py's hold limit follow.

  THE FIVE WHYS STAY HUMAN. The trigger and the timeline are the machine's half; the root cause, the
  class and the three kinds of corrective action are not.

  SCOPE OF A CLEAN REPORT: UNSOUND. It knows three shapes. An incident that never reaches the bus or
  known-wrong.json - a wrong price a reader noticed and nobody recorded - is invisible here.

  EXIT 0 always: a draft is content, not a verdict.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Write, [int]$MaxDrafts = 2)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\event-bus.ps1')

function ConvertTo-IsoUtc([long]$Epoch) {
  return [DateTimeOffset]::FromUnixTimeSeconds($Epoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-IncidentTriggers {
  <# [@{ Key; Kind; Title; First; Rows = @(@{ T; Text }) }]. PURE over its inputs. #>
  param($Events, $Entries, [long]$NowEpoch)
  $out = New-Object System.Collections.Generic.List[object]
  $since30 = $NowEpoch - 30 * 86400
  $since14 = $NowEpoch - 14 * 86400

  $alerts = @{}
  foreach ($e in @($Events)) {
    if (-not $e -or [string]$e.kind -ne 'alert-closed' -or [string]$e.disposition -ne 'confirmed') { continue }
    if ([long]$e.t -lt $since30 -or -not [string]$e.type) { continue }
    $t = [string]$e.type
    if (-not $alerts.ContainsKey($t)) { $alerts[$t] = @{} }
    $id = [string]$e.id
    if (-not $alerts[$t].ContainsKey($id) -or [long]$e.t -lt [long]$alerts[$t][$id].t) { $alerts[$t][$id] = $e }
  }
  foreach ($t in ($alerts.Keys | Sort-Object)) {
    $rows = @($alerts[$t].Values | Sort-Object { [long]$_.t })
    if ($rows.Count -lt 3) { continue }
    $first = [long]$rows[0].t
    $tl = @($rows | ForEach-Object { @{ T = [long]$_.t; Text = ("alert-closed {0}: confirmed" -f $_.id) } })
    [void]$out.Add(@{ Key = ("alert-confirmed:{0}:{1}" -f $t, (ConvertTo-IsoUtc $first).Substring(0, 7)); Kind = 'alert confirmed x3'
                      Title = ("the '{0}' alert was confirmed right {1} times in 30 days" -f $t, $rows.Count); First = $first; Rows = $tl })
  }

  $gates = @{}
  foreach ($e in @($Events)) {
    if (-not $e -or [string]$e.kind -ne 'gate-red' -or [long]$e.t -lt $since14) { continue }
    foreach ($g in @($e.gates)) {
      $gn = [string]$g
      if (-not $gn) { continue }
      if (-not $gates.ContainsKey($gn)) { $gates[$gn] = New-Object System.Collections.Generic.List[object] }
      [void]$gates[$gn].Add($e)
    }
  }
  foreach ($gn in ($gates.Keys | Sort-Object)) {
    $rows = @($gates[$gn] | Sort-Object { [long]$_.t })
    if ($rows.Count -lt 3) { continue }
    $first = [long]$rows[0].t
    $tl = @($rows | ForEach-Object { @{ T = [long]$_.t; Text = ("gate-red at commit {0} on {1}: {2} failed" -f $_.commit, $_.branch, $_.failed) } })
    [void]$out.Add(@{ Key = ("gate-red:{0}:{1}" -f $gn, (ConvertTo-IsoUtc $first).Substring(0, 7)); Kind = 'gate red x3'
                      Title = ("{0} went red {1} times in 14 days" -f $gn, $rows.Count); First = $first; Rows = $tl })
  }

  foreach ($en in @($Entries)) {
    if (-not $en -or -not [string]$en.reversed_on) { continue }
    $rev = $null
    try { $rev = [DateTimeOffset]::new([datetime]::ParseExact([string]$en.reversed_on, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture), [TimeSpan]::Zero) } catch { continue }
    if ($rev.ToUnixTimeSeconds() -lt $since30) { continue }
    $ruled = $rev
    try { $ruled = [DateTimeOffset]::new([datetime]::ParseExact([string]$en.ruled_on, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture), [TimeSpan]::Zero) } catch { }
    $tl = @(
      @{ T = $ruled.ToUnixTimeSeconds(); Text = ("ruled {0} by {1}: {2}" -f $en.verdict, $en.ruled_by, ([string]$en.evidence).Substring(0, [math]::Min(100, ([string]$en.evidence).Length))) },
      @{ T = $rev.ToUnixTimeSeconds(); Text = ("REVERSED by {0}: {1}" -f $en.reversed_by, ([string]$en.reversal_reason).Substring(0, [math]::Min(100, ([string]$en.reversal_reason).Length))) })
    [void]$out.Add(@{ Key = ("known-wrong-reversed:{0}" -f $en.key); Kind = 'known-wrong reversed'
                      Title = ("a known-wrong ruling was reversed: {0} at {1}" -f $en.commodity, $en.store); First = $ruled.ToUnixTimeSeconds(); Rows = $tl })
  }
  $a = $out.ToArray()
  return ,$a
}

function Get-IncidentSlug([string]$Title) {
  $s = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($s.Length -gt 48) { $s = $s.Substring(0, 48).Trim('-') }
  return $s
}

function Format-IncidentDraft {
  <# The draft file's text. PURE. #>
  param($Trigger, [long]$NowEpoch, [string]$Source)
  $now = ConvertTo-IsoUtc $NowEpoch
  $gap = [math]::Round(($NowEpoch - [long]$Trigger.First) / 86400.0, 1)
  $L = New-Object System.Collections.Generic.List[string]
  [void]$L.Add(("# INCIDENT {0} - {1}" -f $now.Substring(0, 10), $Trigger.Title))
  [void]$L.Add('')
  [void]$L.Add(("Status:      DRAFT - opened by ops\incident-trigger.ps1 at {0}. A person writes everything below the timeline." -f $now))
  [void]$L.Add(("Trigger-Key: {0}" -f $Trigger.Key))
  [void]$L.Add('Severity:    TO BE WRITTEN BY A PERSON - what it cost: money, reader-facing wrongness, or time')
  [void]$L.Add(("Detected:    {0}, by ops\incident-trigger.ps1 ({1}) reading {2}" -f $now, $Trigger.Kind, $Source))
  [void]$L.Add('Resolved:    open')
  [void]$L.Add('Author:      a machine draft; the author is whoever finishes it')
  [void]$L.Add('')
  [void]$L.Add('## Timeline')
  [void]$L.Add('')
  foreach ($r in @($Trigger.Rows)) { [void]$L.Add(("- {0}  {1}" -f (ConvertTo-IsoUtc ([long]$r.T)), $r.Text)) }
  [void]$L.Add(("- {0}  this draft opened" -f $now))
  [void]$L.Add('')
  [void]$L.Add(("**The gap between the first sign and this draft: {0} day(s).** The template calls this the most valuable line in the document; the machine can fill the dates, and only a person can say why nobody acted sooner." -f $gap))
  [void]$L.Add('')
  foreach ($h in @('## Root cause', '## The class', '## Corrective actions', '### Preventive', '### Detective', '### Responsive',
                   '## What worked', '## Accepted risks', '## Independent re-review')) {
    [void]$L.Add($h)
    [void]$L.Add('')
    [void]$L.Add('TO BE WRITTEN BY A PERSON. See docs\INCIDENT-TEMPLATE.md for what this section is for.')
    [void]$L.Add('')
  }
  [void]$L.Add('The standard is grocery\INCIDENT-2026-07-23-walmart-flood.md. Close a draft that is not an incident by setting Status: NOT AN INCIDENT and one line saying why - its Trigger-Key keeps it from being opened again.')
  return ($L -join "`n") + "`n"
}

function Get-ExistingIncidentKeys {
  <# @{ Keys = @{key=$true}; DraftsOpen = N } over the INCIDENT-*.md files in a directory. #>
  param([string]$Dir)
  $keys = @{}; $open = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Filter 'INCIDENT-*.md' -ErrorAction SilentlyContinue)) {
    $txt = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($txt, '(?m)^Trigger-Key:\s*(.+?)\s*$')) { $keys[$m.Groups[1].Value] = $true }
    if ($txt -match '(?m)^Status:\s*DRAFT') { $open++ }
  }
  return @{ Keys = $keys; DraftsOpen = $open }
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $now = [long]1790000000
  $day = 86400
  function Ev([string]$kind, [long]$t, [hashtable]$extra) {
    $h = @{ kind = $kind; t = $t }
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    return [pscustomobject]$h
  }
  $a3 = @((Ev 'alert-closed' ($now - 20 * $day) @{ id = 'a1'; type = 'ff carry'; disposition = 'confirmed' }),
          (Ev 'alert-closed' ($now - 10 * $day) @{ id = 'a2'; type = 'ff carry'; disposition = 'confirmed' }),
          (Ev 'alert-closed' ($now - 2 * $day) @{ id = 'a3'; type = 'ff carry'; disposition = 'confirmed' }))
  $tr1 = Get-IncidentTriggers -Events $a3 -Entries @() -NowEpoch $now
  $t1 = @($tr1)
  Case 'MUST FIRE' 'three confirmed closes of one alert type in 30 days open a trigger' ($t1.Count -eq 1 -and $t1[0].Kind -eq 'alert confirmed x3') "$($t1.Count)"
  $g3 = @(1..3 | ForEach-Object { Ev 'gate-red' ($now - $_ * $day) @{ gates = @('ops\audit-x.ps1', 'ops\audit-y.ps1'); commit = 'abc1234'; branch = 'main'; failed = 2 } })
  $tr2 = Get-IncidentTriggers -Events $g3 -Entries @() -NowEpoch $now
  $t2 = @($tr2)
  Case 'MUST FIRE' 'three gate-red rows naming a gate in 14 days open a trigger per gate' ($t2.Count -eq 2 -and $t2[0].Title -match 'went red 3 times') "$($t2.Count)"
  $revDate = [DateTimeOffset]::FromUnixTimeSeconds($now - 5 * $day).UtcDateTime.ToString('yyyy-MM-dd')
  $kw = @([pscustomobject]@{ key = 'coconut-milk|Walmart|x'; commodity = 'coconut-milk-canned'; store = 'Walmart'; verdict = 'wrong-product'
                             evidence = 'coconut CREAM'; ruled_on = '2026-08-01'; ruled_by = 'r'; reversed_on = $revDate; reversed_by = 'r2'; reversal_reason = 'the name was truncated' })
  $tr3 = Get-IncidentTriggers -Events @() -Entries $kw -NowEpoch $now
  $t3 = @($tr3)
  Case 'MUST FIRE' 'a known-wrong reversal inside 30 days opens a trigger' ($t3.Count -eq 1 -and $t3[0].Kind -eq 'known-wrong reversed') "$($t3.Count)"

  $tr5 = Get-IncidentTriggers -Events @($a3[0], $a3[1]) -Entries @() -NowEpoch $now
  Case 'MUST NOT FIRE' 'two confirmed closes are not an incident' (@($tr5).Count -eq 0) "$(@($tr5).Count)"
  $mixed = @($a3[0], $a3[1], (Ev 'alert-closed' ($now - $day) @{ id = 'a9'; type = 'ff carry'; disposition = 'false-alarm' }))
  $tr6 = Get-IncidentTriggers -Events $mixed -Entries @() -NowEpoch $now
  Case 'MUST NOT FIRE' 'a false-alarm close does not count toward three confirmed' (@($tr6).Count -eq 0) "$(@($tr6).Count)"
  $amended = @(1..3 | ForEach-Object { Ev 'alert-closed' ($now - $_ * $day) @{ id = 'same'; type = 'ff carry'; disposition = 'confirmed' } })
  $tr7 = Get-IncidentTriggers -Events $amended -Entries @() -NowEpoch $now
  Case 'MUST NOT FIRE' 'one alert amended three times counts once' (@($tr7).Count -eq 0) "$(@($tr7).Count)"
  $oldG = @(15..17 | ForEach-Object { Ev 'gate-red' ($now - $_ * $day) @{ gates = @('ops\audit-x.ps1'); commit = 'c'; branch = 'main'; failed = 1 } })
  $tr8 = Get-IncidentTriggers -Events $oldG -Entries @() -NowEpoch $now
  Case 'MUST NOT FIRE' 'gate-red rows older than 14 days do not count' (@($tr8).Count -eq 0) "$(@($tr8).Count)"
  $kwOld = @([pscustomobject]@{ key = 'k'; commodity = 'c'; store = 's'; verdict = 'v'; evidence = 'e'; ruled_on = '2026-01-01'; ruled_by = 'r'; reversed_on = '2026-01-02'; reversed_by = 'r'; reversal_reason = 'x' })
  $tr9 = Get-IncidentTriggers -Events @() -Entries $kwOld -NowEpoch $now
  Case 'MUST NOT FIRE' 'a reversal older than 30 days does not' (@($tr9).Count -eq 0) "$(@($tr9).Count)"
  $tmpD = Join-Path $env:TEMP ("incident-trigger-selftest-{0}" -f $PID)
  $null = New-Item -ItemType Directory -Force $tmpD
  try {
    [IO.File]::WriteAllText((Join-Path $tmpD 'INCIDENT-2026-09-01-x.md'), ("# x`nStatus:      DRAFT - y`nTrigger-Key: {0}`n" -f $t1[0].Key))
    $ex = Get-ExistingIncidentKeys -Dir $tmpD
    Case 'MUST NOT FIRE' 'a trigger whose key is already on file is not opened twice' ($ex.Keys.ContainsKey($t1[0].Key))
    Case 'CLEAN TWIN' 'open drafts are counted from their Status line' ($ex.DraftsOpen -eq 1) "$($ex.DraftsOpen)"
  } finally { Remove-Item -LiteralPath $tmpD -Recurse -Force -ErrorAction SilentlyContinue }

  $draft = Format-IncidentDraft -Trigger $t1[0] -NowEpoch $now -Source 'the event bus'
  Case 'CLEAN TWIN' 'the draft carries Status: DRAFT and its Trigger-Key' (($draft -match '(?m)^Status:\s+DRAFT') -and $draft.Contains("Trigger-Key: $($t1[0].Key)"))
  Case 'CLEAN TWIN' 'the gap line is the days from the first sign to the draft' ($draft.Contains('first sign and this draft: 20 day(s)')) ''
  Case 'CLEAN TWIN' 'the slug is lowercase ascii with dashes' ((Get-IncidentSlug "The 'FF carry' alert, 3x!") -eq 'the-ff-carry-alert-3x') (Get-IncidentSlug "The 'FF carry' alert, 3x!")

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("incident-trigger selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'INCIDENT-TRIGGER-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("incident-trigger selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'INCIDENT-TRIGGER-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$nowE = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$evRaw = Read-TcEvents -SinceEpoch ($nowE - 30 * 86400)
$events = @($evRaw)
$entries = @()
$kwNote = ''
try {
  $kwDoc = [IO.File]::ReadAllText((Join-Path $repo 'grocery\known-wrong.json')) | ConvertFrom-Json
  $entries = @($kwDoc.entries)
} catch { $kwNote = ' (known-wrong.json unreadable - reversals NOT checked, which is not none reversed)' }
$incDir = Join-Path $repo 'grocery'
$trR = Get-IncidentTriggers -Events $events -Entries $entries -NowEpoch $nowE
$triggers = @($trR)
$existing = Get-ExistingIncidentKeys -Dir $incDir
$new = @($triggers | Where-Object { -not $existing.Keys.ContainsKey($_.Key) })
$take = @($new | Select-Object -First ([math]::Max(0, $MaxDrafts)))
$refused = [math]::Max(0, $new.Count - $take.Count)

Write-Output 'INCIDENT TRIGGER - the same thing, breaking three times, earns a record'
Write-Output ("  read {0} bus event(s) in 30 days and {1} known-wrong entr(ies){2}" -f $events.Count, $entries.Count, $kwNote)
foreach ($t in $triggers) {
  $state = if ($existing.Keys.ContainsKey($t.Key)) { 'already on file' } elseif (@($take | Where-Object { $_.Key -eq $t.Key }).Count) { $(if ($Write) { 'OPENED' } else { 'would open (no -Write)' }) } else { 'REFUSED by the per-run bar' }
  Write-Output ("  {0,-22} {1} - {2}" -f $state, $t.Kind, $t.Title)
}
$opened = 0
if ($Write) {
  foreach ($t in $take) {
    # Words, not a path: ops\audit-write-only-reports.ps1 reads a literal out-directory path assigned to a
    # variable as a report family, and this variable then reaches WriteAllText inside the draft's text.
    $src = if ($t.Kind -eq 'known-wrong reversed') { 'the known-wrong rulings file' } else { 'the event bus (lib\event-bus.ps1)' }
    $name = "INCIDENT-{0}-{1}.md" -f (Get-Date).ToString('yyyy-MM-dd'), (Get-IncidentSlug $t.Title)
    $path = Join-Path $incDir $name
    if (Test-Path -LiteralPath $path) { $path = Join-Path $incDir ("INCIDENT-{0}-{1}-{2}.md" -f (Get-Date).ToString('yyyy-MM-dd'), (Get-IncidentSlug $t.Title), $nowE) }
    [IO.File]::WriteAllText($path, (Format-IncidentDraft -Trigger $t -NowEpoch $nowE -Source $src), (New-Object Text.UTF8Encoding($false)))
    Write-Output ("  wrote {0}" -f $path)
    $opened++
  }
}
if ($refused -gt 0) { Write-Output ("  {0} trigger(s) REFUSED: more than {1} in one run reads as a broken producer before it reads as that many incidents." -f $refused, $MaxDrafts) }
$draftsOpen = $existing.DraftsOpen + $opened
Write-Output ("  triggers {0}, new {1}, opened {2}, refused {3}; incident drafts open {4}" -f $triggers.Count, $new.Count, $opened, $refused, $draftsOpen)
if ($Json) {
  'incident-json: ' + (([ordered]@{ known = $true; triggers = $triggers.Count; new = $new.Count; opened = $opened; refused = $refused; drafts_open = $draftsOpen }) | ConvertTo-Json -Compress)
}
Exit-Guard -Name 'INCIDENT-TRIGGER' -Code 0 -Summary ("triggers={0} new={1} opened={2} refused={3} drafts_open={4}" -f $triggers.Count, $new.Count, $opened, $refused, $draftsOpen)
