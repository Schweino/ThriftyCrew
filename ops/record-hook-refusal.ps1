<#
  record-hook-refusal.ps1 - write ONE push-ledger row for a push the pre-push hook refused.

  Run:        started by ops\hooks\pre-push on every refusal, never by hand. Its arguments are the refusal:
              powershell -File ops\record-hook-refusal.ps1 -Cause <cause> [-Gate <gate>] [-Rc <n>] [-Blind <token>]
                [-Log <path>] [-Checkout <dir>] [-Remote <name>] [-LocalRef <ref> -LocalSha <sha> -RemoteRef <ref>
                -RemoteSha <sha>] [-RefLines <n>] [-HookPid <n>] [-HookBlob <sha>]
  Self-test:  powershell -File ops\record-hook-refusal.ps1 -SelfTest

  WHY THIS EXISTS (2026-09-23, W0.6 of design\PLAN-push-derived-conflicts-2026-09-23.md, section 15.5). The push ledger
  (lib\push-ledger.ps1) had exactly two writers: ops\hold-push-lock.ps1, which the hook starts only AFTER every check
  has passed, and ops\push-main.ps1. So a plain `git push` the hook refused left no row at all, and the plan measured
  what that hides: only 32 of 72 origin/main updates in its window came through a push-main row, and a session that
  retried a refused plain push three times looked, in the ledger, like one push or none. W0.3b counts an ATTEMPT as a
  push-main row OR one of these rows, so without them every attempts-per-change figure undercounts exactly the pushes
  that failed. This is RECORD THE CASE AT THE MOMENT IT FAILS (measurement.md) for the hook's own refusals.

  THE ROW. lib\push-ledger.ps1's ten fields, with event `hook-refused`, outcome `refused`, waitMs -1 (nothing queued for
  the lock: a refusal never reaches it) and base and grant empty, which Measure-TcPushRows counts as UNKNOWN rather than
  as a ref that stood still. `checkout` is the PUSHING checkout the hook resolved, in Windows form. `pid` is this
  writer's, as every row's pid is its writer's; the hook itself is named by `hook_pid`. Then, in this order:
      cause            run-gates, test-auditors, rehearsal or structure: the cause on the hook's PRE-PUSH-REFUSED line
      gate             run-gates' first failing gate, the same token as that line's gate=; null when there was none
      rc               the exit code of the check that refused; null for a structural refusal, where no check ran
      blind            run-gates' blind= token on a 3; null otherwise
      log              the hook's kept log for that check (Windows form); null when it keeps none
      remote           the remote NAME the push went to (never its URL, which can carry a credential)
      local_ref, local_sha, remote_ref, remote_sha   the first ref line that carried work, as git handed it to the hook
      ref_lines        how many ref lines git handed the hook
      hook_pid         the hook shell's Windows pid (/proc/<pid>/winpid), which names its kept logs' owner
      hook_blob        `git hash-object --no-filters` of the running hook: which copy of the SHARED hook refused
      under_push_main  true when this push runs inside a live ops\push-main.ps1 that holds the push lock, false otherwise
      push_main_pid    that push-main's pid when under_push_main, null otherwise
  An absent value is null, never '' and never 0, because a reader cannot tell an empty string from "not recorded".

  UNDER_PUSH_MAIN IS ASKED OF THE LOCK THIS HOOK WOULD TAKE, never of the bare variable. push-main exports
  TC_PUSH_LOCK_HOLDER=<pid>|<guid>|<prefix> while it holds the push lock, and every descendant inherits it, including a
  gate suite's sandbox push run under push-main's own in-lock hook. So the answer is the one hold-push-lock would give:
  a token whose pid is live AND whose prefix names the lock this hook takes (the real Global one, or a private Local\
  one a fixture set in TC_PUSH_LOCK_PREFIX, the only override Get-TcHoldLockNames honours). A token naming another lock
  is not an inheritance, which is the rule lib\push-lock.ps1's Test-TcPushLockTokenLive learnt on 2026-09-11.
  W0.3b tells a plain push's refusal (an attempt of its own) from push-main's in-lock refusal (push-main's row already
  counts it) by this field.

  TWO ROADS TO ONE ROW. Once lib\push-ledger.ps1's Write-TcPushRow takes -Fields (W0.1), this calls it with the fields
  above and the library's own collision rule applies. Until then it builds the same row from New-TcPushRowText and
  splices the fields after the ten own ones, refusing a field that names one of them ignoring case, which is the rule
  W0.1 states. The road is chosen by asking the loaded library whether Write-TcPushRow declares -Fields; the splice road
  is dead code from the day W0.1 lands and can be deleted then.

  IT NEVER DECIDES A PUSH. The hook has already refused when this runs, and it keeps its exit code whatever happens
  here. Exit 0 = the row was written; exit 1 = it was not, and the ONE line printed says why; the hook prints that line
  and exits 1 as it was going to. Nothing reads these rows to decide anything.

  SCOPE OF A CLEAN REPORT: a row proves the hook refused one push on this box. The rows are not a census of refusals: a
  checkout whose hook predates W0.6 writes none, a checkout with no copy of this script (and a main checkout with none)
  writes none and says so, --no-verify runs no hook, and another machine writes to its own ledger.
#>
# gate-inputs: lib\push-ledger.ps1, lib\append-line.ps1, lib\push-lock.ps1, lib\gate-slots.ps1
[CmdletBinding()]
param(
  [string]$Cause = '',
  [string]$Gate = '',
  [string]$Rc = '',
  [string]$Blind = '',
  [string]$Log = '',
  [string]$Checkout = '',
  [string]$Remote = '',
  [string]$LocalRef = '',
  [string]$LocalSha = '',
  [string]$RemoteRef = '',
  [string]$RemoteSha = '',
  [string]$RefLines = '',
  [string]$HookPid = '',
  [string]$HookBlob = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
# A LIBRARY THAT CANNOT LOAD IS A ROW NOT WRITTEN, said in the one line the hook prints. It is never a throw into the
# hook: the hook has already refused, and this can only add a record of it.
try {
  . (Join-Path $repo 'lib\push-ledger.ps1')
  . (Join-Path $repo 'lib\push-lock.ps1')
} catch {
  Write-Output ('record-hook-refusal: NOT recorded - a library did not load (' + $_.Exception.Message + ')')
  exit 1
}

function ConvertTo-TcRefusalText {
  <# A text value, or $null when there is none. '' and whitespace are absent, never a value. #>
  param([string]$Value)
  $t = ([string]$Value).Trim()
  if (-not $t) { return $null }
  return $t
}

function ConvertTo-TcRefusalInt {
  <# An integer, or $null when the text is absent or is not one. A value the hook could not read stays null rather
     than becoming 0, which would read as a real exit code or a real count. #>
  param([string]$Value)
  $t = ([string]$Value).Trim()
  if ($t -notmatch '^-?\d{1,9}$') { return $null }
  return [int]$t
}

function ConvertTo-TcRefusalSha {
  <# A lower-case hex object id of 7 to 64 characters (sha1 or sha256), or $null. Anything else is not recorded as a
     sha, because a reader joins these to git history. #>
  param([string]$Value)
  $t = ([string]$Value).Trim().ToLowerInvariant()
  if ($t -notmatch '^[0-9a-f]{7,64}$') { return $null }
  return $t
}

function ConvertTo-TcRefusalPath {
  <# A drive-rooted path in Windows form (git hands the hook C:/Codex/..., hold-push-lock writes C:\Codex\...), so a
     reader that excludes sandbox checkouts by a %TEMP%\... prefix matches both writers' rows. Anything that is not
     drive-rooted (an MSYS /tmp/... path, a relative one) is kept exactly as given: guessing its drive would invent one. #>
  param([string]$Value)
  $t = ([string]$Value).Trim()
  if (-not $t) { return $null }
  if ($t -match '^[A-Za-z]:[\\/]') {
    try { return ([IO.Path]::GetFullPath($t)).TrimEnd('\') } catch { return $t }
  }
  return $t
}

function Get-TcRefusalHolder {
  <# Is this push running inside a live ops\push-main.ps1 that holds the push lock this hook would take? See the
     header. -PrefixEnv is TC_PUSH_LOCK_PREFIX, honoured only when it is a private Local\ one (Get-TcHoldLockNames in
     ops\hold-push-lock.ps1 states that rule; this reads it the same way). #>
  param([string]$Token, [string]$PrefixEnv)
  $prefix = $script:TcPushLockPrefix
  if ($PrefixEnv -and $PrefixEnv.StartsWith('Local\')) { $prefix = $PrefixEnv }
  $under = $false
  try { $under = [bool](Test-TcPushLockTokenLive -Token $Token -Prefix $prefix) } catch { $under = $false }
  $holderPid = $null
  if ($under -and ([string]$Token -match '^(\d+)\|')) { $holderPid = [int]$Matches[1] }
  return [pscustomobject]@{ UnderPushMain = $under; PushMainPid = $holderPid }
}

function New-TcHookRefusalFields {
  <# The row's own fields, in their order (see the header), from the hook's raw arguments. Throws on a cause that is
     not one lower-case word: that is the one field every reader groups on, so a malformed one is refused rather than
     written. Any other unreadable value becomes null. #>
  param(
    [string]$Cause, [string]$Gate, [string]$Rc, [string]$Blind, [string]$Log, [string]$Remote,
    [string]$LocalRef, [string]$LocalSha, [string]$RemoteRef, [string]$RemoteSha, [string]$RefLines,
    [string]$HookPid, [string]$HookBlob, [string]$Token, [string]$PrefixEnv
  )
  # A FORMAT, NOT A LIST. The hook is installed in the SHARED .git and is always current, while this script runs from
  # whichever checkout pushed, which may be older than the hook: a list here would refuse a cause a newer hook adds
  # (W8.3 adds chain-lease) and lose that row. Only a value no reader could group on is refused.
  $c = ([string]$Cause).Trim()
  if ($c -notmatch '^[a-z][a-z0-9-]{0,39}$') {
    throw ("the cause '" + $c + "' is not one lower-case word, so no reader could group on it")
  }
  $holder = Get-TcRefusalHolder -Token $Token -PrefixEnv $PrefixEnv
  return [ordered]@{
    cause           = $c
    gate            = (ConvertTo-TcRefusalText $Gate)
    rc              = (ConvertTo-TcRefusalInt $Rc)
    blind           = (ConvertTo-TcRefusalText $Blind)
    log             = (ConvertTo-TcRefusalPath $Log)
    remote          = (ConvertTo-TcRefusalText $Remote)
    local_ref       = (ConvertTo-TcRefusalText $LocalRef)
    local_sha       = (ConvertTo-TcRefusalSha $LocalSha)
    remote_ref      = (ConvertTo-TcRefusalText $RemoteRef)
    remote_sha      = (ConvertTo-TcRefusalSha $RemoteSha)
    ref_lines       = (ConvertTo-TcRefusalInt $RefLines)
    hook_pid        = (ConvertTo-TcRefusalInt $HookPid)
    hook_blob       = (ConvertTo-TcRefusalSha $HookBlob)
    under_push_main = [bool]$holder.UnderPushMain
    push_main_pid   = $holder.PushMainPid
  }
}

function Join-TcRefusalRowText {
  <# The splice road: the ten own fields exactly as New-TcPushRowText wrote them, then $Fields in their own order. A
     field naming one of the row's own fields THROWS, compared ignoring case, because ConvertFrom-Json under PS 5.1
     refuses two keys that differ only in case and an extra field may never overwrite what the row says (W0.1's rule).
     The own names are read from the row itself, never listed here, so a field the library adds is protected too. #>
  param([string]$BaseText, [System.Collections.IDictionary]$Fields)
  $b = ([string]$BaseText).Trim()
  if (-not ($b.StartsWith('{') -and $b.EndsWith('}'))) { throw 'the base row is not one JSON object' }
  $own = @(($b | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name })
  if ($null -eq $Fields -or $Fields.Count -eq 0) { return $b }
  foreach ($k in @($Fields.Keys)) {
    foreach ($o in $own) {
      if ([string]::Equals([string]$k, [string]$o, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("the field '" + $k + "' collides with a field the row already has; an extra field may never overwrite what the row says")
      }
    }
  }
  $extra = (ConvertTo-Json ([pscustomobject]$Fields) -Compress -Depth 5).Trim()
  if (-not ($extra.StartsWith('{') -and $extra.EndsWith('}')) -or $extra -eq '{}') { return $b }
  if ($b -eq '{}') { return $extra }
  return ($b.Substring(0, $b.Length - 1) + ',' + $extra.Substring(1))
}

function Write-TcHookRefusalRow {
  <# Append the row. Returns Written / Reason / Path / Road and NEVER throws, the contract Write-TcPushRow keeps: a
     failure is reported in Reason so the hook can print it and a case can read it.
     -Road auto asks the loaded library; `fields` and `splice` force a road, for the self-test. #>
  param(
    [string]$Cause, [string]$Gate = '', [string]$Rc = '', [string]$Blind = '', [string]$Log = '', [string]$Checkout = '',
    [string]$Remote = '', [string]$LocalRef = '', [string]$LocalSha = '', [string]$RemoteRef = '', [string]$RemoteSha = '',
    [string]$RefLines = '', [string]$HookPid = '', [string]$HookBlob = '',
    [string]$Token = ([string]$env:TC_PUSH_LOCK_HOLDER), [string]$PrefixEnv = ([string]$env:TC_PUSH_LOCK_PREFIX),
    [string]$Root = '', [string]$Road = 'auto'
  )
  $path = ''; $roadTaken = ''
  try {
    $fields = New-TcHookRefusalFields -Cause $Cause -Gate $Gate -Rc $Rc -Blind $Blind -Log $Log -Remote $Remote `
      -LocalRef $LocalRef -LocalSha $LocalSha -RemoteRef $RemoteRef -RemoteSha $RemoteSha -RefLines $RefLines `
      -HookPid $HookPid -HookBlob $HookBlob -Token $Token -PrefixEnv $PrefixEnv
    $co = ConvertTo-TcRefusalPath $Checkout
    $coText = $(if ($null -eq $co) { '' } else { [string]$co })
    $hasFields = (Get-Command Write-TcPushRow -ErrorAction Stop).Parameters.ContainsKey('Fields')
    switch ($Road) {
      'auto'   { $roadTaken = $(if ($hasFields) { 'fields' } else { 'splice' }) }
      'fields' { $roadTaken = 'fields' }
      'splice' { $roadTaken = 'splice' }
      default  { throw ("unknown road: " + $Road) }
    }
    if ($roadTaken -eq 'fields') {
      if (-not $hasFields) { throw 'lib\push-ledger.ps1 has no -Fields on Write-TcPushRow, so the fields road does not exist yet' }
      $w = Write-TcPushRow -Event 'hook-refused' -Outcome 'refused' -Checkout $coText -Root $Root -Fields $fields
      return [pscustomobject]@{ Written = [bool]$w.Written; Reason = [string]$w.Reason; Path = [string]$w.Path; Road = $roadTaken }
    }
    $path = Get-TcPushLedgerPath -Root $Root
    # THE TEXT IS BUILT BEFORE THE DIRECTORY IS TOUCHED, so a refused field writes nothing at all (W0.1's order).
    $text = Join-TcRefusalRowText -BaseText (New-TcPushRowText -Event 'hook-refused' -Outcome 'refused' -Checkout $coText) -Fields $fields
    $dir = Split-Path -Parent $path
    # A FILE WHERE THE DIRECTORY SHOULD BE fails here at once, rather than after Add-TcLine's whole open-retry budget
    # (about 7 s) spent on a path that waiting cannot fix. Asked explicitly: measured here, New-Item -ItemType Directory
    # -Force over an existing FILE returns without throwing.
    if (Test-Path -LiteralPath $dir -PathType Leaf) { throw ('the ledger directory ' + $dir + ' is a file') }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Force -ErrorAction Stop $dir }
    $null = Add-TcLine -Path $path -Text $text
    return [pscustomobject]@{ Written = $true; Reason = ''; Path = $path; Road = $roadTaken }
  } catch {
    return [pscustomobject]@{ Written = $false; Reason = [string]$_.Exception.Message; Path = $path; Road = $roadTaken }
  }
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # ONE DIRECTORY PER RUN, short, removed in the finally: run-gates runs every self-test and pre-push runs run-gates, so
  # concurrent pushes run this file over each other in one %TEMP% (ops-and-gates.md's fixed-temp-name rule).
  $tmp = Join-Path $env:TEMP ('tc-rhr-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $PSExe = (Get-Command powershell).Source
  $shaL = '1111111111111111111111111111111111111111'
  $shaR = '2222222222222222222222222222222222222222'
  $shaH = '3333333333333333333333333333333333333333'
  # THE WHOLE SUITE WRITES TO SCRATCH, and every row carries this RUN's id (lib\push-ledger.ps1, backlog I171), so the
  # last case can prove nothing reached the production ledger by filtering on the run, never on a recyclable pid.
  $prodPath = Get-TcPushLedgerPath -Root $script:TcPushLedgerRoot
  $ledgerRootWas = $env:TC_PUSH_LEDGER_ROOT
  $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite'
  $runWas = $env:TC_PUSH_LEDGER_RUN
  $suiteRun = New-TcPushLedgerRunId
  $env:TC_PUSH_LEDGER_RUN = $suiteRun
  # A PRIVATE LOCK PREFIX FOR THE HOLDER CASES. Nothing here opens a mutex: the token check is a string compare and a
  # process lookup. The prefix is private anyway, so no case even names the production lock.
  $pfx = 'Local\tc-rhr-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $wantNames = 'ts,pid,run,event,waitMs,state,base,grant,outcome,checkout,cause,gate,rc,blind,log,remote,local_ref,local_sha,remote_ref,remote_sha,ref_lines,hook_pid,hook_blob,under_push_main,push_main_pid'
  try {
    # ---- the row, on fixed inputs, on the splice road (the road until W0.1 lands) ----
    $r1 = Join-Path $tmp 'r1'
    $w1 = Write-TcHookRefusalRow -Cause 'run-gates' -Gate 'ops\audit-conclusion-currency.ps1' -Rc '1' -Log 'C:/tmp/tc-prepush-9.log' `
      -Checkout 'C:/Codex/wt/a/' -Remote 'origin' -LocalRef 'refs/heads/feat' -LocalSha $shaL -RemoteRef 'refs/heads/main' `
      -RemoteSha $shaR -RefLines '1' -HookPid '4242' -HookBlob $shaH -Token '' -PrefixEnv $pfx -Root $r1 -Road 'splice'
    $rows1Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $r1)
    $rows1 = @($rows1Raw)
    $row1 = $(if ($rows1.Count) { $rows1[0] } else { $null })
    $names1 = $(if ($row1) { @($row1.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' } else { '' })
    T ($kMF + '  a run-gates refusal writes ONE hook-refused row: the ten own fields, then cause, gate, rc and every other field in order, the checkout in Windows form') `
      ($w1.Written -and $rows1.Count -eq 1 -and [string]::Equals($names1, $wantNames, [StringComparison]::Ordinal) -and $row1.event -eq 'hook-refused' `
        -and $row1.outcome -eq 'refused' -and $row1.cause -eq 'run-gates' -and $row1.gate -eq 'ops\audit-conclusion-currency.ps1' -and $row1.rc -eq 1 `
        -and $row1.checkout -eq 'C:\Codex\wt\a' -and $row1.log -eq 'C:\tmp\tc-prepush-9.log' -and $row1.local_sha -eq $shaL -and $row1.remote_ref -eq 'refs/heads/main' `
        -and $row1.ref_lines -eq 1 -and $row1.hook_pid -eq 4242 -and $row1.hook_blob -eq $shaH -and $row1.under_push_main -eq $false -and [double]$row1.waitMs -eq -1) `
      ("written={0} reason={1} rows={2} names={3}" -f $w1.Written, $w1.Reason, $rows1.Count, $names1)

    # ---- an absent value is null, never '' ----
    $r2 = Join-Path $tmp 'r2'
    $w2 = Write-TcHookRefusalRow -Cause 'structure' -Token '' -PrefixEnv $pfx -Root $r2 -Road 'splice'
    $raw2 = $(if (Test-Path -LiteralPath (Get-TcPushLedgerPath -Root $r2)) { [IO.File]::ReadAllText((Get-TcPushLedgerPath -Root $r2)) } else { '' })
    T ($kMNF + '  a structural refusal with nothing else known records every absent value as null, never an empty string or a 0') `
      ($w2.Written -and $raw2.Contains('"gate":null') -and $raw2.Contains('"rc":null') -and $raw2.Contains('"log":null') -and $raw2.Contains('"local_sha":null') `
        -and $raw2.Contains('"ref_lines":null') -and $raw2.Contains('"hook_blob":null') -and $raw2.Contains('"push_main_pid":null') -and -not $raw2.Contains('"gate":""')) `
      ("written={0} reason={1} text={2}" -f $w2.Written, $w2.Reason, $raw2.Trim())

    # ---- a value that is not what it claims is not recorded as one ----
    $r3 = Join-Path $tmp 'r3'
    $w3 = Write-TcHookRefusalRow -Cause 'rehearsal' -Rc 'one' -LocalSha 'not-a-sha' -HookPid '12ab' -RefLines '' -Token '' -PrefixEnv $pfx -Root $r3 -Road 'splice'
    $rows3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $r3)
    $rows3 = @($rows3Raw)
    T ($kMNF + '  a non-numeric exit code, a malformed sha and a non-numeric pid are recorded as null, never as the text the hook passed') `
      ($w3.Written -and $rows3.Count -eq 1 -and $null -eq $rows3[0].rc -and $null -eq $rows3[0].local_sha -and $null -eq $rows3[0].hook_pid -and $rows3[0].cause -eq 'rehearsal') `
      ("written={0} rows={1} rc={2} sha={3} pid={4}" -f $w3.Written, $rows3.Count, $(if ($rows3.Count) { $rows3[0].rc }), $(if ($rows3.Count) { $rows3[0].local_sha }), $(if ($rows3.Count) { $rows3[0].hook_pid }))

    # ---- the one field every reader groups on is refused rather than written malformed ----
    $r4 = Join-Path $tmp 'r4'
    $w4 = Write-TcHookRefusalRow -Cause 'run gates' -Token '' -PrefixEnv $pfx -Root $r4 -Road 'splice'
    T ($kMF + '  a cause that is not one lower-case word writes nothing at all, not even the ledger directory, and says why') `
      ((-not $w4.Written) -and $w4.Reason -match 'lower-case word' -and -not (Test-Path -LiteralPath $r4)) `
      ("written={0} reason={1} dirMade={2}" -f $w4.Written, $w4.Reason, (Test-Path -LiteralPath $r4))

    # ---- the splice road keeps W0.1's collision rule: an extra field may never overwrite the row ----
    $baseText = New-TcPushRowText -Event 'hook-refused' -Outcome 'refused' -Checkout 'C:\x'
    $colErr = ''
    try { $null = Join-TcRefusalRowText -BaseText $baseText -Fields ([ordered]@{ cause = 'x'; Outcome = 'landed' }) } catch { $colErr = [string]$_.Exception.Message }
    T ($kMF + '  on the splice road a field naming one of the row''s own (Outcome, differing only in case) throws naming it') `
      ($colErr -match "'Outcome'") ("err={0}" -f $colErr)

    # ---- under_push_main: asked of the lock this hook would take ----
    $hLive = Get-TcRefusalHolder -Token ("{0}|abcdef123456|{1}" -f $PID, $pfx) -PrefixEnv $pfx
    T ($kMF + '  a live push-main token naming the lock this hook would take is under_push_main, with that push-main''s pid') `
      ($hLive.UnderPushMain -eq $true -and $hLive.PushMainPid -eq $PID) ("under={0} pid={1}" -f $hLive.UnderPushMain, $hLive.PushMainPid)
    $hOther = Get-TcRefusalHolder -Token ("{0}|abcdef123456|{1}" -f $PID, 'Local\tc-some-other-lock-') -PrefixEnv $pfx
    T ($kMNF + '  a live token naming ANOTHER lock is not under_push_main: a sandbox push under a real push-main is still a plain push') `
      ($hOther.UnderPushMain -eq $false -and $null -eq $hOther.PushMainPid) ("under={0} pid={1}" -f $hOther.UnderPushMain, $hOther.PushMainPid)
    $gone = Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-Command', 'exit') -PassThru -WindowStyle Hidden
    $null = $gone.WaitForExit(30000)
    $hDead = Get-TcRefusalHolder -Token ("{0}|abcdef123456|{1}" -f $gone.Id, $pfx) -PrefixEnv $pfx
    $hNone = Get-TcRefusalHolder -Token '' -PrefixEnv $pfx
    T ($kMNF + '  a token whose push-main is gone, and no token at all, are both not under_push_main') `
      ($hDead.UnderPushMain -eq $false -and $hNone.UnderPushMain -eq $false) ("dead={0} none={1}" -f $hDead.UnderPushMain, $hNone.UnderPushMain)

    # ---- the ledger must not be able to change what the hook does ----
    $blocked = Join-Path $tmp 'blocked'
    [IO.File]::WriteAllText($blocked, 'not a directory')
    $wBad = Write-TcHookRefusalRow -Cause 'test-auditors' -Rc '2' -Token '' -PrefixEnv $pfx -Root $blocked
    T ($kMF + '  a ledger that cannot be written reports it in words and does NOT throw') `
      ((-not $wBad.Written) -and $wBad.Reason) ("written={0} reason={1}" -f $wBad.Written, $wBad.Reason)

    # ---- the road the loaded library supports writes a row every reader parses ----
    $hasFieldsNow = (Get-Command Write-TcPushRow).Parameters.ContainsKey('Fields')
    $rA = Join-Path $tmp 'auto'
    $wA = Write-TcHookRefusalRow -Cause 'rehearsal' -Rc '1' -LocalSha $shaL -RemoteRef 'refs/heads/main' -Token '' -PrefixEnv $pfx -Root $rA
    $rowsARaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $rA)
    $mA = Measure-TcPushRows @($rowsARaw)
    $rowsA = @($rowsARaw)
    T ($kCT + '  the auto road takes -Fields when the library has it and splices when not, and its row parses: not malformed, counted UNKNOWN, never as a wait') `
      ($wA.Written -and $wA.Road -eq $(if ($hasFieldsNow) { 'fields' } else { 'splice' }) -and $rowsA.Count -eq 1 -and $rowsA[0].cause -eq 'rehearsal' `
        -and $rowsA[0].local_sha -eq $shaL -and $mA.Malformed -eq 0 -and $mA.Unknown -eq 1 -and $mA.Waited -eq 0) `
      ("written={0} road={1} libHasFields={2} rows={3} malformed={4} unknown={5} waited={6}" -f $wA.Written, $wA.Road, $hasFieldsNow, $rowsA.Count, $mA.Malformed, $mA.Unknown, $mA.Waited)

    # ---- the command line, run the way ops\hooks\pre-push runs it: a child process, arguments as the hook passes them ----
    # STDOUT ONLY, never a stderr redirect: under this file's EAP=Stop a redirected native stderr line is a terminating
    # throw (ops-and-gates.md). The one line the hook prints is on stdout.
    $me = $PSCommandPath
    $cliOut = @(& $PSExe -NoProfile -ExecutionPolicy Bypass -File $me -Cause 'rehearsal' -Rc '1' -Log 'C:/tmp/tc-prepush-rh-7.log' `
      -Checkout 'C:/Codex/wt/b' -Remote 'origin' -LocalRef 'HEAD' -LocalSha $shaL -RemoteRef 'refs/heads/cli-case' -RemoteSha $shaR `
      -RefLines '1' -HookPid '77' | ForEach-Object { [string]$_ })
    $cliRc = $LASTEXITCODE
    $suiteRowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath)
    $cliRows = @(@($suiteRowsRaw) | Where-Object { -not $_.PSObject.Properties['malformed'] -and $_.remote_ref -eq 'refs/heads/cli-case' })
    T ($kCT + '  run as the hook runs it, the script exits 0, prints ONE line, and writes exactly one row carrying what it was given') `
      ($cliRc -eq 0 -and $cliOut.Count -eq 1 -and $cliOut[0] -match '^record-hook-refusal: recorded cause=rehearsal' -and $cliRows.Count -eq 1 `
        -and $cliRows[0].checkout -eq 'C:\Codex\wt\b' -and $cliRows[0].rc -eq 1 -and $cliRows[0].run -eq $suiteRun) `
      ("rc={0} lines={1} out=[{2}] rows={3}" -f $cliRc, $cliOut.Count, ($cliOut -join ' | '), $cliRows.Count)
    $env:TC_PUSH_LEDGER_ROOT = $blocked
    try {
      $cliBad = @(& $PSExe -NoProfile -ExecutionPolicy Bypass -File $me -Cause 'run-gates' -Rc '3' -Blind 'no-gate-worker-slot' | ForEach-Object { [string]$_ })
      $cliBadRc = $LASTEXITCODE
    } finally { $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite' }
    T ($kMF + '  with a ledger it cannot write, the script exits 1 and its ONE line says NOT recorded and why, which is the line the hook prints') `
      ($cliBadRc -eq 1 -and $cliBad.Count -eq 1 -and $cliBad[0] -match '^record-hook-refusal: NOT recorded - .+') `
      ("rc={0} lines={1} out=[{2}]" -f $cliBadRc, $cliBad.Count, ($cliBad -join ' | '))

    # ---- nothing this suite wrote reached the production ledger ----
    $prodRaw = Read-TcPushRows -Path $prodPath
    $prodMineRaw = Select-TcPushRowsOfRun -Rows $prodRaw -Run $suiteRun
    $prodMine = @($prodMineRaw)
    T ($kMF + '  no row this suite wrote, in this process or in the child it ran, reached the production push ledger') `
      ($prodMine.Count -eq 0) ("run={0} rowsFromThisRunInProduction={1}" -f $suiteRun, $prodMine.Count)
  } finally {
    if ($null -eq $runWas) { Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_RUN -ErrorAction SilentlyContinue } else { $env:TC_PUSH_LEDGER_RUN = $runWas }
    if ($null -eq $ledgerRootWas) { Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_ROOT -ErrorAction SilentlyContinue } else { $env:TC_PUSH_LEDGER_ROOT = $ledgerRootWas }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A LITERAL-CASE SUITE KNOWS ITS OWN NUMBER, so a case lost to a throw, a comment or a glued line is a failure here
  # rather than a smaller green tally (ops-and-gates.md).
  $expectedCases = 13
  if ($cases -ne $expectedCases) { Write-Output ("FAIL  ran {0} case(s), expected {1} - a case was skipped" -f $cases, $expectedCases); $f++ }
  if ($f) { Write-Output ("record-hook-refusal self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("record-hook-refusal self-test PASS: {0} cases - led by a refusal writing one hook-refused row with its cause, gate and ref line, and by a ledger it cannot write saying so in the one line the hook prints" -f $cases)
  exit 0
}

# ---- the command line: one row for the refusal the hook passed ----
$result = Write-TcHookRefusalRow -Cause $Cause -Gate $Gate -Rc $Rc -Blind $Blind -Log $Log -Checkout $Checkout -Remote $Remote `
  -LocalRef $LocalRef -LocalSha $LocalSha -RemoteRef $RemoteRef -RemoteSha $RemoteSha -RefLines $RefLines -HookPid $HookPid `
  -HookBlob $HookBlob -Root ([string]$env:TC_PUSH_LEDGER_ROOT)
if ($result.Written) {
  Write-Output ('record-hook-refusal: recorded cause=' + ([string]$Cause).Trim() + ' in ' + $result.Path)
  exit 0
}
Write-Output ('record-hook-refusal: NOT recorded - ' + $result.Reason)
exit 1
