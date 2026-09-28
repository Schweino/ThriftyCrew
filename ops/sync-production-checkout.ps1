<#
  sync-production-checkout.ps1 - the ONE way a scheduled task pulls the production checkout.

  WHY (triage 2026-09-28-90a544). Nothing told a scheduled task that the daily chain was in flight, so five
  scheduled `git pull --rebase --autostash` calls (the grocery-alert-triage, grocery-fareway-daily-check,
  grocery-recipe-everyday-refresh and grocery-bakers-daily-flash-check prompts, and grocery/bakers-daily-scan.ps1)
  ran on a clock that assumed the chain had finished. The chain ran past 09:45 on 7 of 26 days on disk
  (2026-09-01..09-28). A pull that lands an upstream change to a verdict input (commodities.json, known-wrong.json,
  board-price-overrides.json, product-urls.json) after guards moves the chain's verdict fingerprint and withholds a
  board guards passed.

  WHAT IT DOES. Reads grocery/out/logs/capture-run-status.json ONCE, lock-free (og-53: one sample of one record
  survives every read anomaly). A capture-run is IN FLIGHT when any kind (daily, ad) has date = today, a stage that
  is not terminal, and a pid that is alive and not younger than the record. In flight: print SYNC-SKIPPED and exit 0,
  so the task carries on with the checkout as the chain left it (which is what the chain publishes from). Otherwise
  run `git -C <repo> pull --rebase --autostash origin main` through Invoke-Native (og-04) and exit git's rc. An
  absent or unreadable status file pulls as before and says so: it degrades to the day before, never to a refusal.

  IT NEVER TAKES Global\tc-capture-run. capture-run waits only 60 s for that mutex (capture-run.ps1 ~:605) and skips
  its whole day without it, so a sync holding it across a slow pull would cost a day; and a WaitOne on an abandoned
  mutex consumes the abandoned state capture-run relies on to detect an orphaned child. It is self-contained rather
  than a function in lib/checkout-sync.ps1 because that lib is in the chain's derived set and this script is not run
  by the chain. Cost: 0 seconds per push beyond its own self-test.

  SCOPE OF A CLEAN REPORT: UNSOUND. A pulled outcome says the status record showed no live run; it says nothing about
  a session or hand command writing the production checkout mid-run (owned by
  design/PLAN-bot-dedicated-checkout-2026-09-25.md Stage 2 W2.1, not yet built), and NOTHING STOPS A FUTURE
  SCHEDULED TASK FROM ADDING ITS OWN BARE PULL: a sixth copy is unguarded. New scheduled pulls call this script.

  Last line: SYNC-PRODUCTION-CHECKOUT-COMPLETE outcome=<skipped|pulled|failed>
#>
param(
  [string]$Repo = '',
  [string]$StatusFile = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Repo) { $Repo = Split-Path -Parent $here }
if (-not $StatusFile) { $StatusFile = Join-Path $Repo 'grocery\out\logs\capture-run-status.json' }
. (Join-Path (Split-Path -Parent $here) 'grocery\native-lib.ps1')

function Test-TcCaptureStageInFlight([string]$Stage) {
  switch ($Stage) {
    'complete'         { return $false }
    'skipped-locked'   { return $false }
    'blocked-checkout' { return $false }
    'handoff-failed'   { return $false }
    'syncing'          { return $true }
    'synced-handoff'   { return $true }
    'started'          { return $true }
    'capturing'        { return $true }
    'downstream'       { return $true }
    'publishing'       { return $true }
    # og-16: an unknown stage is a stage capture-run added after this list; fail closed, treat it as running.
    default            { return $true }
  }
}

function Test-TcPidAliveForRecord($ProcId, [string]$Started) {
  $p = $null
  try { $p = Get-Process -Id ([int]$ProcId) -ErrorAction Stop } catch { return $false }
  # A reused pid belongs to a process that started AFTER the record's run did.
  try {
    $st = [datetime]::Parse($Started)
    if ($p.StartTime -gt $st.AddMinutes(5)) { return $false }
  } catch { }
  return $true
}

function Test-TcCaptureRunInFlight([string]$Path, [datetime]$Now) {
  # Returns @{ state = 'in-flight'|'idle'|'stale'|'unreadable'; kind; stage; pid; started; note }
  if (-not (Test-Path -LiteralPath $Path)) { return @{ state = 'unreadable'; note = 'status file absent' } }
  $doc = $null
  try { $doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return @{ state = 'unreadable'; note = ('status file unparseable: ' + $_.Exception.Message) } }
  if ($null -eq $doc) { return @{ state = 'unreadable'; note = 'status file empty' } }
  $today = $Now.ToString('yyyy-MM-dd')
  $stale = $null
  foreach ($prop in $doc.PSObject.Properties) {
    $r = $prop.Value
    if ($null -eq $r -or -not $r.PSObject.Properties['stage']) { continue }
    if ([string]$r.date -ne $today) { continue }
    if (-not (Test-TcCaptureStageInFlight ([string]$r.stage))) { continue }
    $info = @{ kind = $prop.Name; stage = [string]$r.stage; pid = $r.pid; started = [string]$r.started }
    if (Test-TcPidAliveForRecord $r.pid ([string]$r.started)) { $info.state = 'in-flight'; return $info }
    $info.state = 'stale'; $stale = $info
  }
  if ($stale) { return $stale }
  return @{ state = 'idle' }
}

function Invoke-TcSyncProductionCheckout([string]$RepoPath, [string]$Status, [scriptblock]$GitRunner, [datetime]$Now) {
  # Returns @{ outcome; rc; lines = [string[]] }
  $lines = New-Object System.Collections.Generic.List[string]
  $s = Test-TcCaptureRunInFlight $Status $Now
  if ($s.state -eq 'in-flight') {
    $lines.Add(('SYNC-SKIPPED capture-run {0} in stage {1} (pid {2}, started {3}) - the production checkout is not pulled while the chain runs' -f $s.kind, $s.stage, $s.pid, $s.started))
    return @{ outcome = 'skipped'; rc = 0; lines = $lines.ToArray() }
  }
  switch ($s.state) {
    'stale'      { $lines.Add(('sync: capture-run {0} record says stage {1} but pid {2} is not running - the record is stale, pulling' -f $s.kind, $s.stage, $s.pid)) }
    'unreadable' { $lines.Add(('sync: status unreadable, pulling ({0})' -f $s.note)) }
    'idle'       { $lines.Add('sync: no capture-run in flight, pulling') }
    default      { throw "unknown in-flight state: $($s.state)" }
  }
  $g = & $GitRunner $RepoPath
  $rc = [int]$g.ExitCode
  $last = @($g.Lines | Where-Object { [string]$_ }) | Select-Object -Last 1
  if ($last) { $lines.Add('git: ' + [string]$last) }
  $outcome = 'pulled'; if ($rc -ne 0) { $outcome = 'failed' }
  return @{ outcome = $outcome; rc = $rc; lines = $lines.ToArray() }
}

$defaultGit = { param($r) Invoke-Native git -C $r pull --rebase --autostash origin main }

if ($SelfTest) {
  $fail = 0; $cases = 0
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ('tcspc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
  try {
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $startedNow = $now.ToString('s')
    # A pid that certainly exited: a child started and waited for.
    $dead = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c exit 0' -WindowStyle Hidden -PassThru
    $dead.WaitForExit()
    $deadPid = $dead.Id
    $script:gitCalls = New-Object System.Collections.Generic.List[string]
    $okGit = { param($r) $script:gitCalls.Add([string]$r); [pscustomobject]@{ ExitCode = 0; Lines = @('From x', 'Already up to date.') } }
    $badGit = { param($r) $script:gitCalls.Add([string]$r); [pscustomobject]@{ ExitCode = 128; Lines = @('fatal: could not read from remote') } }
    function Write-Status([string]$name, $obj) {
      $p = Join-Path $scratch ($name + '.json')
      [IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
      return $p
    }
    function Assert-Case([string]$label, $status, [scriptblock]$runner, [string]$wantOutcome, [int]$wantCalls, [string]$wantText, [int]$wantRc) {
      $script:cases++
      try {
        $script:gitCalls.Clear()
        $res = Invoke-TcSyncProductionCheckout 'C:\fixture-repo' $status $runner $now
        $text = ($res.lines -join "`n")
        $ok = ($res.outcome -eq $wantOutcome) -and ($script:gitCalls.Count -eq $wantCalls) -and ($res.rc -eq $wantRc) -and ($text.Contains($wantText))
        if ($ok) { Write-Output ('  ok    ' + $label) }
        else { $script:fail++; Write-Output ('  FAIL  ' + $label + ' outcome=' + $res.outcome + ' calls=' + $script:gitCalls.Count + ' rc=' + $res.rc + ' text=' + $text) }
      } catch { $script:fail++; Write-Output ('  FAIL  ' + $label + ' threw: ' + $_.Exception.Message) }
    }
    $sGuards = Write-Status 'guards' @{ daily = @{ date = $today; pid = $PID; started = $startedNow; stage = 'guards' } }
    Assert-Case 'MUST FIRE: the 09-27 shape, daily in an unlisted mid-run stage with a live pid -> SKIPPED, git never runs' $sGuards $okGit 'skipped' 0 'SYNC-SKIPPED capture-run daily in stage guards' 0
    $sPub = Write-Status 'pub' @{ daily = @{ date = $today; pid = $PID; started = $startedNow; stage = 'publishing' } }
    Assert-Case 'MUST FIRE: daily publishing with a live pid -> SKIPPED' $sPub $okGit 'skipped' 0 'in stage publishing' 0
    $sAd = Write-Status 'ad' @{ daily = @{ date = $today; pid = $PID; started = $startedNow; stage = 'complete' }; ad = @{ date = $today; pid = $PID; started = $startedNow; stage = 'capturing' } }
    Assert-Case 'MUST FIRE: daily complete but ad capturing -> SKIPPED on the ad kind' $sAd $okGit 'skipped' 0 'capture-run ad in stage capturing' 0
    $sZzz = Write-Status 'zzz' @{ daily = @{ date = $today; pid = $PID; started = $startedNow; stage = 'zzz' } }
    Assert-Case 'MUST FIRE: unknown stage zzz with a live pid -> SKIPPED (fail-closed default)' $sZzz $okGit 'skipped' 0 'in stage zzz' 0
    $sStale = Write-Status 'stale' @{ daily = @{ date = $today; pid = $deadPid; started = $startedNow; stage = 'guards' } }
    Assert-Case 'MUST NOT FIRE: a killed chain''s stale record (pid exited) -> pulled once, says stale' $sStale $okGit 'pulled' 1 'the record is stale' 0
    $sYday = Write-Status 'yday' @{ daily = @{ date = $now.AddDays(-1).ToString('yyyy-MM-dd'); pid = $PID; started = $startedNow; stage = 'publishing' } }
    Assert-Case 'MUST NOT FIRE: yesterday''s record in a mid-run stage -> pulled' $sYday $okGit 'pulled' 1 'no capture-run in flight' 0
    $sDone = Write-Status 'done' @{ daily = @{ date = $today; pid = $PID; started = $startedNow; stage = 'complete' } }
    Assert-Case 'CLEAN TWIN: daily complete with a live pid -> git runs exactly once, outcome pulled' $sDone $okGit 'pulled' 1 'git: Already up to date.' 0
    Assert-Case 'CLEAN TWIN: absent status file -> pulled, says status unreadable' (Join-Path $scratch 'absent.json') $okGit 'pulled' 1 'status unreadable' 0
    $bad = Join-Path $scratch 'bad.json'; [IO.File]::WriteAllText($bad, '{ not json', (New-Object Text.UTF8Encoding($false)))
    Assert-Case 'CLEAN TWIN: unparseable status file -> pulled, says status unreadable' $bad $okGit 'pulled' 1 'status unreadable' 0
    Assert-Case 'CLEAN TWIN: git fails -> outcome failed, its rc carried' $sDone $badGit 'failed' 1 'fatal: could not read from remote' 128
    # The default runner passes the repo and the exact pull; checked by the argument the seam receives.
    $script:cases++
    $script:gitCalls.Clear()
    $null = Invoke-TcSyncProductionCheckout 'C:\fixture-repo' $sDone $okGit $now
    if ($script:gitCalls.Count -eq 1 -and $script:gitCalls[0] -eq 'C:\fixture-repo') { Write-Output '  ok    CLEAN TWIN: the runner receives the repo path' }
    else { $script:fail++; Write-Output ('  FAIL  CLEAN TWIN: the runner receives the repo path, got ' + ($script:gitCalls -join ',')) }
    $script:cases++
    if (([string]$defaultGit).Contains('pull --rebase --autostash origin main')) { Write-Output '  ok    CLEAN TWIN: the default runner is the same pull the prompts ran' }
    else { $script:fail++; Write-Output '  FAIL  CLEAN TWIN: the default runner is the same pull the prompts ran' }
  } catch { $fail++; Write-Output ('  FAIL  self-test harness threw: ' + $_.Exception.Message) }
  finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  if ($cases -ne 12) { $fail++; Write-Output ('  FAIL  expected 12 cases, ran ' + $cases) }
  if ($fail -eq 0) { Write-Output ('sync-production-checkout self-test pass (' + $cases + ' cases)'); exit 0 }
  Write-Output ('sync-production-checkout self-test FAIL (' + $fail + ' of ' + $cases + ' failed)'); exit 1
}

$res = Invoke-TcSyncProductionCheckout $Repo $StatusFile $defaultGit (Get-Date)
foreach ($l in $res.lines) { Write-Output $l }
Write-Output ('SYNC-PRODUCTION-CHECKOUT-COMPLETE outcome=' + $res.outcome)
exit $res.rc
