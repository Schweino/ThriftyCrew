function Get-TcRejectLinesCapped {
  <# Up to 3 lines of at most 300 characters each, in order: what a row keeps of a refusal. #>
  param($Lines)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($l in @($Lines)) {
    if ($out.Count -ge 3) { break }
    $s = [string]$l
    if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
    $out.Add($s)
  }
  return , ($out.ToArray())
}

function Get-TcRejectRc {
  <# THE EXIT CODE OF THE CHECK THAT REFUSED (the row's reject_rc, review of W0.1R, 2026-09-23): 1 is a red, 3 is
     could-not-evaluate, which is NEVER a red and never a pass. The fixed PRE-PUSH-REFUSED line carries cause and gate but
     no code, so rule 1 of the classifier kept a contention 3 of run-gates or test-auditors exactly as it kept a red, and
     a reader scored both as the change's own red. Read, first match wins:
       1. an rc=<n> on a PRE-PUSH-REFUSED line (a later hook may print one)     n
       2. a ^pre-push: BLOCKED - line saying COULD NOT EVALUATE, or "without its completion marker" (decided nothing)  3
       3. a ^pre-push: BLOCKED - line carrying "(exit <n>)" or "exited <n>"      n
     $null when no line says, which is what a structure refusal, a remote rejection and an unknown text all are. Pure. #>
  param($Lines)
  $all = @(@($Lines) | ForEach-Object { [string]$_ })
  foreach ($l in $all) {
    $m = [regex]::Match($l, '^PRE-PUSH-REFUSED cause=\S+.*?\brc=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  foreach ($l in $all) {
    if ($l -cnotmatch '^pre-push: BLOCKED - ') { continue }
    if ($l -cmatch 'COULD NOT EVALUATE' -or $l -cmatch 'without its completion marker') { return 3 }
    $m = [regex]::Match($l, '\(exit (\d+)\)')
    if (-not $m.Success) { $m = [regex]::Match($l, '\bexited (\d+)\b') }
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  return $null
}

function Get-TcHookTestAuditorsScope {
  <# How much of test-auditors the IN-LOCK hook ran (the row's hook_ta_scope, review of W0.1R, 2026-09-23): 'full' for
     prepush-test-auditors' "running <suite> in full" line, 'selective <n> of <m>' for its "running <suite> on <n> of <m>
     unit(s)" line, $null when it did not run. hook_ta keeps its four words (the probe reads them); B11 counts FULL runs
     inside the lock, and 'ran' alone could not say which. Pure. #>
  param([string]$Text)
  foreach ($l in @(([string]$Text) -split "`r?`n")) {
    if ($l -cmatch '^\s*prepush-test-auditors: running .+? in full\b') { return 'full' }
    $m = [regex]::Match($l, '^\s*prepush-test-auditors: running .+? on (\d+) of (\d+) unit\(s\)')
    if ($m.Success) { return ('selective ' + $m.Groups[1].Value + ' of ' + $m.Groups[2].Value) }
  }
  return $null
}

function Get-TcPushRejectClass {
  <# WHY A PUSH WAS REJECTED, from git's output (the row's reject_class and reject_lines). The FIRST RULE THAT MATCHES
     ANY LINE wins, in this order, never the first line that matches any rule: a text carrying both the fixed line and an
     older wording is classified by the fixed line wherever it sits.
       1. ^PRE-PUSH-REFUSED cause=<c> [gate=<g>]      the fixed line the hook prints from W1.1: <c>, or <c>:<g>
       2. ^pre-push: BLOCKED - (the chain rehearsal|this push changes the daily chain), or
          ^chain-rehearsal: (REFUSED|COULD NOT)       rehearsal
       3. ^pre-push: BLOCKED - the test-auditors check  test-auditors
       4. ^pre-push: BLOCKED - run-gates              run-gates, or run-gates:<gate> naming the first ^\s+FAIL\s+(\S+) line;
                                                      the BLOCKED line, the FAIL lines and the run-gates: FAILED or COULD
                                                      NOT lines the hook echoes are kept, in that order
       5. ^pre-push: REFUSING                         structure
       6. ! [remote rejected], or cannot lock ref     remote
       7. none                                        unknown, keeping the first 3 non-empty lines
     THE WORDING BEFORE 2026-09-23 matched only rule 5's lines (^(pre-push: REFUS|chain-rehearsal: REFUSED) or RATCHET
     BROKEN): every gate refusal in the hook says BLOCKED, and RATCHET BROKEN never reaches git's stderr, because the hook
     echoes only FAIL and run-gates: lines from run-gates' log. Lines are matched case-sensitively, as the hook prints
     them. Rc is Get-TcRejectRc's reading of the same text (the row's reject_rc). Pure: it runs nothing and never throws on
     any text. #>
  param([string]$Text)
  $lines = @(([string]$Text) -split "`r?`n" | Where-Object { ([string]$_).Trim() })
  $rc = Get-TcRejectRc -Lines $lines
  $pp = @($lines | Where-Object { $_ -cmatch '^PRE-PUSH-REFUSED cause=\S+' })
  if ($pp.Count) {
    $m = [regex]::Match([string]$pp[0], '^PRE-PUSH-REFUSED cause=(\S+)(?:.*?\sgate=(\S+))?')
    $cls = $m.Groups[1].Value
    if ($m.Groups[2].Success -and $m.Groups[2].Value) { $cls = $cls + ':' + $m.Groups[2].Value }
    return [pscustomobject]@{ Rc = $rc; Class = $cls; Lines = (Get-TcRejectLinesCapped $pp) }
  }
  $rh = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - (the chain rehearsal|this push changes the daily chain)' -or $_ -cmatch '^chain-rehearsal: (REFUSED|COULD NOT)' })
  if ($rh.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'rehearsal'; Lines = (Get-TcRejectLinesCapped $rh) } }
  $ta = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - the test-auditors check' })
  if ($ta.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'test-auditors'; Lines = (Get-TcRejectLinesCapped $ta) } }
  $rg = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - run-gates' })
  if ($rg.Count) {
    $fails = @($lines | Where-Object { $_ -cmatch '^\s+FAIL\s+\S+' })
    $said = @($lines | Where-Object { $_ -cmatch '^run-gates: (FAILED|COULD NOT)' })
    $cls = 'run-gates'
    if ($fails.Count) { $cls = 'run-gates:' + [regex]::Match([string]$fails[0], '^\s+FAIL\s+(\S+)').Groups[1].Value }
    return [pscustomobject]@{ Rc = $rc; Class = $cls; Lines = (Get-TcRejectLinesCapped (@($rg[0]) + $fails + $said)) }
  }
  $st = @($lines | Where-Object { $_ -cmatch '^pre-push: REFUSING' })
  if ($st.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'structure'; Lines = (Get-TcRejectLinesCapped $st) } }
  $rm = @($lines | Where-Object { $_ -cmatch '! \[remote rejected\]' -or $_ -cmatch 'cannot lock ref' })
  if ($rm.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'remote'; Lines = (Get-TcRejectLinesCapped $rm) } }
  return [pscustomobject]@{ Rc = $rc; Class = 'unknown'; Lines = (Get-TcRejectLinesCapped $lines) }
}

function Get-TcRunGatesFailed {
  <# The gates run-gates named as failed ("  failed: <gate>" lines), so a refused-gate-red ledger row says WHICH gate
     refused it (2026-10-02, Phase 6 of design/PLAN-weekly-root-families-2026-10-02.md: 162 such rows named none, so a
     load-caused refusal could not be told from a real red when its bar was counted). At most 20, in order. Empty when
     no such line was printed, which is "not recorded", never "none failed". #>
  param($Lines)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in @($Lines)) {
    $m = [regex]::Match([string]$l, '^\s+failed: (\S.*?)\s*$')
    if ($m.Success -and $out.Count -lt 20) { $out.Add($m.Groups[1].Value) }
  }
  return , $out.ToArray()
}

function Get-TcRunGatesReading {
  <# What run-gates said about reuse, from its own lines (rg_reused, rg_selftests, rg_unkeyable): its "<x> of <y>
     self-test(s) already passed over these exact inputs ...; <z> could not be keyed" line (ops\run-gates.ps1, printed
     on every run that dispatches), and WholeRun when it replayed a whole recorded verdict and dispatched nothing (its
     "PASSED - all <n> gate(s) passed at ... not one was run again" line, or a completion marker carrying reused=1), which
     is what makes the leg's time 0. Every number is null when its line is absent. #>
  param($Lines)
  $res = [pscustomobject]@{ Reused = $null; SelfTests = $null; Unkeyable = $null; WholeRun = $false }
  foreach ($l in @($Lines)) {
    $s = [string]$l
    $m = [regex]::Match($s, '^run-gates: (\d+) of (\d+) self-test\(s\) already passed over these exact inputs.*; (\d+) could not be keyed')
    if ($m.Success -and $null -eq $res.Reused) { $res.Reused = [int]$m.Groups[1].Value; $res.SelfTests = [int]$m.Groups[2].Value; $res.Unkeyable = [int]$m.Groups[3].Value }
    if ($s -cmatch '^run-gates: PASSED - all \d+ gate\(s\) passed at .*not one was run again' -or $s -cmatch '^RUN-GATES-COMPLETE\b.*\breused=1\b') { $res.WholeRun = $true }
  }
  return $res
}

function Test-TcTaReused {
  <# Did the test-auditors check replay a recorded pass instead of running (its "REUSED key=" line)? Then its leg is 0. #>
  param($Lines)
  return [bool](@(@($Lines) | Where-Object { [string]$_ -cmatch '^\s*prepush-test-auditors: REUSED key=' }).Count)
}

function Get-TcTaKeyMoved {
  <# The TA-KEY-MOVED line the test-auditors check prints before a run that could not reuse its pass (W0.4:
     `TA-KEY-MOVED kind=<content|mtime|lib|board> input=<repo path>`, or `TA-KEY-MOVED kind=no-record`), copied as the
     row's ta_moved: the first such line, trimmed, at most 300 characters. $null when there is none, which is what a
     reused pass and a checkout older than W0.4 both print. #>
  param($Lines)
  foreach ($l in @($Lines)) {
    $s = ([string]$l).Trim()
    if ($s -cmatch '^TA-KEY-MOVED kind=\S+') { if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }; return $s }
  }
  return $null
}

function Get-TcHookTestAuditors {
  <# What the IN-LOCK hook's test-auditors leg did (hook_ta), from the lines ops\prepush-test-auditors.ps1 prints and the
     hook echoes to git's stderr: `running ...` (in full or selectively) is ran; `REUSED key=` is reused; `NOT NEEDED` is
     not-needed; anything else, including a hook that refused before test-auditors ran, is unknown. #>
  param([string]$Text)
  $lines = @(([string]$Text) -split "`r?`n")
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: running ' }).Count) { return 'ran' }
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: REUSED key=' }).Count) { return 'reused' }
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: NOT NEEDED' }).Count) { return 'not-needed' }
  return 'unknown'
}

function Get-TcRehearsalOutcome {
  <# The outcome= word of the LAST `CHAIN-REHEARSAL-CHECK-COMPLETE code=<n> outcome=<o>` line the -ForPush child printed
     (ops\rehearse-chain.ps1), or '' when there is none. #>
  param($Lines)
  $o = ''
  foreach ($l in @($Lines)) {
    $m = [regex]::Match([string]$l, '^CHAIN-REHEARSAL-CHECK-COMPLETE code=\d+ outcome=(\S+)')
    if ($m.Success) { $o = $m.Groups[1].Value }
  }
  return $o
}

function Get-TcChainTouching {
  <# Did this push change the daily chain (chain_touching)? Mapped from ops\rehearse-chain.ps1's outcome vocabulary, read
     from Get-RhPushDecision: not-needed is false; rehearsed-pass, rehearsed-fail, no-verdict, stale and bypassed are
     each reached only after a chain-manifest script was found changed, so they are true; could-not-rehearse is reached
     both BEFORE the manifest is read (the diff or the manifest failed) and after (a blind verdict), so it is $null, not
     known. A word outside that vocabulary THROWS (a switch on data refuses loudly): its caller records null and says so. #>
  param([string]$Outcome)
  $t = $null
  switch -CaseSensitive ($Outcome) {
    'not-needed'         { $t = $false }
    'rehearsed-pass'     { $t = $true }
    'rehearsed-fail'     { $t = $true }
    'no-verdict'         { $t = $true }
    'stale'              { $t = $true }
    'bypassed'           { $t = $true }
    'could-not-rehearse' { $t = $null }
    default              { throw ('unknown rehearsal outcome: ' + $Outcome) }
  }
  return $t
}

function Get-TcOptionalProp {
  <# A property a runner MAY report (a self-test stub or an older seam reports fewer), or $null. #>
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

function Add-TcRunnerReadings {
  <# Copies what the runner's legs SAID into the row: leg_sec.rg and .ta, rg_reused, rg_selftests, rg_unkeyable, ta_rc and
     ta_moved. A runner that reports none of it leaves every one null, which is "not recorded", never a zero. #>
  param([System.Collections.IDictionary]$Row, $Result)
  $rgLines = Get-TcOptionalProp $Result 'RgLines'
  $rgSec = Get-TcOptionalProp $Result 'RgSec'
  if ($null -ne $rgLines) {
    $rgr = Get-TcRunGatesReading -Lines $rgLines
    $Row['rg_reused'] = $rgr.Reused; $Row['rg_selftests'] = $rgr.SelfTests; $Row['rg_unkeyable'] = $rgr.Unkeyable
    if ($rgr.WholeRun) { $Row['leg_sec']['rg'] = 0 } elseif ($null -ne $rgSec) { $Row['leg_sec']['rg'] = [int]$rgSec }
  } elseif ($null -ne $rgSec) { $Row['leg_sec']['rg'] = [int]$rgSec }
  $taExit = Get-TcOptionalProp $Result 'TaExit'
  if ($null -ne $taExit) { $Row['ta_rc'] = [int]$taExit }
  $taLines = Get-TcOptionalProp $Result 'TaLines'
  $taSec = Get-TcOptionalProp $Result 'TaSec'
  if ($null -ne $taLines) {
    $Row['ta_moved'] = Get-TcTaKeyMoved -Lines $taLines
    if (Test-TcTaReused -Lines $taLines) { $Row['leg_sec']['ta'] = 0 } elseif ($null -ne $taSec) { $Row['leg_sec']['ta'] = [int]$taSec }
  } elseif ($null -ne $taSec) { $Row['leg_sec']['ta'] = [int]$taSec }
}

function Add-TcRehearsalReadings {
  <# Copies what the rehearsal leg said into the row: leg_sec.rh, chain_touching and rh_outcome. The leg is null when
     nothing was asked (Ran $false), 0 when the child read a recorded verdict (a rehearsed-pass or rehearsed-fail outcome
     with no "rehearsing HEAD now" line), and its measured seconds otherwise. #>
  param([System.Collections.IDictionary]$Row, $Result, [int]$Sec)
  $ran = Get-TcOptionalProp $Result 'Ran'
  if ($ran -eq $false) { return }
  $lines = Get-TcOptionalProp $Result 'Lines'
  $oc = Get-TcRehearsalOutcome -Lines $lines
  if ($oc) {
    $Row['rh_outcome'] = $oc
    try { $Row['chain_touching'] = Get-TcChainTouching -Outcome $oc }
    catch { $Row['chain_touching'] = $null; Say ('push-main: ' + $_.Exception.Message + ' - recorded as chain_touching null; the word is kept in rh_outcome.') }
  }
  $rehearsedNow = [bool](@(@($lines) | Where-Object { [string]$_ -cmatch 'rehearsing HEAD now' }).Count)
  if (($oc -ceq 'rehearsed-pass' -or $oc -ceq 'rehearsed-fail') -and -not $rehearsedNow) { $Row['leg_sec']['rh'] = 0 } else { $Row['leg_sec']['rh'] = $Sec }
}

# ======================================================================================================================
# WHAT THE ROW RECORDS ABOUT THE LOOP (2026-09-23, W0.1R: W0.1 rebuilt on the fetch-and-rebase-first loop). The loop
# landed after W0.1 was written, so the row now also says which phase a rebase or a refusal happened in, how many rounds
# and lock takes the push needed, and what the in-lock verdict check said. Same rule as above: pure, or a few git reads
# that answer null on any failure.
# ======================================================================================================================

function Get-TcSubjectsSha {
  <# The row's subjects_sha: SHA-256, lower-case hex, of the commit subjects of <Base>..HEAD, sorted ORDINAL and joined
     with LF (no trailing LF), as UTF-8 bytes. It names the change by what its commits SAY, which survives a rebase that
     rewrites every sha and moves a patch-id whenever a conflict is resolved, so W0.3b can group one change's attempts on
     it. Read at START with the branch base. Null when the base is unreadable, git fails, or the range holds no commit
     (a branch with nothing to push has no subjects to be named by). The subjects are the lines Invoke-TcGit decodes
     from git's stdout, so one box hashes one subject one way. #>
  param([string]$Dir, [string]$Base)
  $subj = Get-TcRangeSubjects -Dir $Dir -Base $Base
  if ($null -eq $subj) { return $null }
  return (Get-TcSubjectsShaOf -Subjects $subj)
}

function Get-TcRangeSubjects {
  <# The commit subjects of <Base>..HEAD as git decodes them, one per commit, or $null when the base is unreadable, git
     fails, or the range holds no commit. #>
  param([string]$Dir, [string]$Base)
  if ($Base -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return $null }
  $r = Invoke-TcGit -Dir $Dir -Arguments @('log', '--format=%s', ($Base + '..HEAD'))
  if ($r.Code -ne 0) { return $null }
  $subj = [string[]]@(@($r.Out) | ForEach-Object { [string]$_ })
  if ($subj.Count -eq 0) { return $null }
  return , $subj
}

function Get-TcSha256Hex {
  <# SHA-256 of a string's UTF-8 bytes (no preamble), lower-case hex. #>
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text)) } finally { $sha.Dispose() }
  return (([BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant())
}

function Get-TcSubjectsShaOf {
  <# subjects_sha over a subject list: sorted ORDINAL, joined with LF, hashed. Null for an empty or absent list. Pure. #>
  param([string[]]$Subjects)
  if ($null -eq $Subjects -or $Subjects.Count -eq 0) { return $null }
  $s = [string[]]$Subjects.Clone()
  [Array]::Sort($s, [StringComparer]::Ordinal)
  return (Get-TcSha256Hex -Text ($s -join "`n"))
}

# HOW MANY PER-SUBJECT HASHES A ROW KEEPS. The first plausible number (the W0.1R review's "around 50"), not the survivor
# of a sweep: a push-main range is a handful of commits, and a range longer than this is rare enough that keeping its
# first 50 sorted hashes still overlaps an earlier attempt's. subject_count says when the list was cut.
$script:TcSubjectShasCap = 50

function Get-TcSubjectShaList {
  <# The row's subject_shas (review of W0.1R, 2026-09-23): one short hash per DISTINCT subject of the range, the first 16
     hex of Get-TcSha256Hex, sorted ORDINAL and cut at $script:TcSubjectShasCap. subjects_sha is ONE hash over the whole
     set, so it moves whenever a lane amends one subject or adds a fix commit, and W0.3b split one change into several
     on exactly the housekeeping lane its key was founded on (three attempts, three subjects_sha values, measured from
     the 2026-09-23 production ledger by the review). Per-subject hashes let a reader link attempts by OVERLAP instead.
     Null for an empty or absent list. Pure. #>
  param([string[]]$Subjects)
  if ($null -eq $Subjects -or $Subjects.Count -eq 0) { return $null }
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($x in $Subjects) { [void]$set.Add((Get-TcSha256Hex -Text ([string]$x)).Substring(0, 16)) }
  $list = [string[]]@($set)
  [Array]::Sort($list, [StringComparer]::Ordinal)
  if ($list.Count -gt $script:TcSubjectShasCap) { $list = [string[]]$list[0..($script:TcSubjectShasCap - 1)] }
  return , $list
}
