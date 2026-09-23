<#
  commit-size-lib.ps1 - the daily bot commit's size gate, judged per RUN. A run that stages files but does not commit
  records its OWN additions in a carry record; the next run's gate counts those files at the caps they already met, and
  judges everything else, its own writes included, at exactly today's 300 files / 25 MB.

  Dot-source:  . (Join-Path $repoRoot 'grocery\commit-size-lib.ps1')
  Self-test:   powershell -NoProfile -File grocery\commit-size-lib.ps1 -SelfTest

  WHY (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W2.1, Brad's ruling D3 (a) the same day).
  grocery\capture-run.ps1 caps a commit's NEW files at 300 files / 25 MB, summed over the whole of
  `git diff --cached --diff-filter=A`. That sum includes files an EARLIER refused run wrote and never committed, so one
  refused day pushes the next day over the cap and the refusal then carries itself forward. On 2026-09-23 the 07:00 run
  was refused at 40 files / 28.8 MB and the 08:00 run at 51 files / 43.3 MB, while one normal date's two bot commits add
  about 31 files / 24.8 MiB (plan sections 1.1, 1.2 and 2.3; the per-date figure is SCRATCH). Brad ruled for carry
  records, not a larger cap.

  THE THREE BUCKETS (Test-CarriedCommitSize, pure: no git, no disk, no clock of its own):
    own        an addition whose LastWriteTime is at or after this run's start. This run wrote it.
    carried    an older addition that a `within-caps` record under 72 h old names with the SAME byte length. The newest
               such record wins. Each carried record's files are judged again at one run's caps, as a defence: they met
               those caps when they were recorded, so a record that does not is refused rather than trusted.
    unvouched  everything else: an older file nobody recorded, a file whose length moved since its record, a file an
               `over-caps` record names, a record too old or dated after now, a session's dump into grocery\out.
  own + unvouched is judged EXACTLY as capture-run judges today: more than 300 files, or
  [math]::Round(<sum of bytes> / 1MB, 1) more than 25. So:
    * a flood refused yesterday (`over-caps`) is never laundered, because its files are unvouched today;
    * this run's own writes still meet exactly today's caps, whatever it carries;
    * with no records at all every addition is own or unvouched, which is today's gate.
  WHY NOT A LARGER CAP PER CAPTURE DATE, the rejected design (plan section 4.2): 600 files / 50 MB per path date admits a
  single-day flood of 350 files or 40 MiB, where today's gate refuses both. That is a loosening. The self-test's
  no-laundering case is built so that design turns it red (plan section 8, mutant M4).
  A VERDICT THIS FILE DOES NOT KNOW vouches NOTHING and is named in `notes`. That is the refusing direction for a size
  gate: its files are judged at today's caps, never admitted on a word this code cannot read. The switch that reads a
  record's verdict is case-sensitive for the same reason.

  THE LEDGER (Read-TcCommitCarry, Add-TcCommitCarry): <git common dir>\tc-commit-carry.json, beside
  lib\pipeline-commit.ps1's write journal, where it can never ride a commit.
      { "schema": 1, "runs": [ { "run_id", "kind", "checkout", "started", "recorded", "verdict", "files", "bytes",
                                 "paths": { "<repo path>": <bytes> } } ] }
    * every read-modify-write holds lib\ledger-lock.ps1's lock with the READ inside it, and replaces the file through
      lib\atomic-write.ps1 (Write-TcAtomicFile -NoBom). Read-TcCommitCarry takes the same lock, so it never lands in the
      instant between a replace's delete and its move.
    * `checkout` is the toplevel of the checkout that wrote the run, full and lower-cased. The ledger sits in the COMMON
      dir, which every linked worktree shares, so Read-TcCommitCarry returns only the runs of the checkout it is asked
      about: a hand run in a worktree must not vouch for a byte-equal file in the main checkout. The plan's schema has no
      such field; it is the one addition to it.
    * Add-TcCommitCarry REPLACES a run with the same run_id, so a retry after a lost reply writes the same ledger: it is
      IDEMPOTENT for a given run_id, file list and -Now. It prunes runs recorded more than 72 h ago and runs all of whose
      paths HEAD now tracks, and never the run it is adding.
    * a ledger that cannot be parsed is MOVED ASIDE to <path>.unreadable-<utc stamp> and a fresh one is written. An
      unreadable record vouches nothing anyway; moving it keeps the evidence and lets the mechanism recover. A Read of an
      unreadable ledger returns ok=$false and no runs, which is today's gate.
    * $env:TC_COMMIT_CARRY_PATH overrides the path, for fixtures only.
    * ITS CLASS under Brad's I117 ruling (lib\atomic-write.ps1): a lost last write is NOTICED, never silent. The next run
      judges those files unvouched, which is exactly today's gate, and a size refusal pages. So it does not flush.

  WHAT A NUMBER HERE DOES WHEN THE PRODUCER STOPS. If no run records (capture-run stops calling Add-TcCommitCarry, or the
  ledger is deleted), records age out after 72 h and every older addition is unvouched: today's gate exactly, never an
  admit. `deep` cannot fire with no records, so it is not an absence check; capture-watchdog's CAPTURE BACKLOG floor
  (plan W1.1) reads the filesystem and is.

  THE TUNING CONSTANTS. 300 files and 25 MB are capture-run's existing caps, unchanged and not tuned here. 72 h (how long
  a record vouches) and 24 h (the age past which a carried record is `deep` and pages) are the plan's first plausible
  numbers, not the survivors of a sweep; nothing else was tried. Ages are compared in TICKS, never through TotalSeconds,
  which multiplies by an inexact 1e-7, so a record exactly 72 h old is exactly on the bar.

  Get-CaptureDateOf is the path-date rule the rejected design bucketed on, copied unchanged from the prototype
  (sync-proto.ps1 blob 3ddd9f98c415). Nothing here judges by it; it lives here because capture-watchdog's backlog floor
  (plan W1.1) groups untracked files by it, and one copy of the rule is enough.

  SCOPE OF A CLEAN REPORT: the self-test drives the pure judge over frozen fixtures (the 09-23 07:00 and 08:00 shapes, the
  bars at 300 files, 25.0 MiB, 72 h and 24 h with one step past each, laundering, a moved length, the browser-profiles
  shape, and the size half of every test-commit-size-gate case fed through with no records), the ledger through a temp
  path, one temp git repo for the common-dir path and the tracked prune, a lock held from ANOTHER process, and four writer
  processes released together on lib\ledger-fixture.ps1's barrier. A pass proves those behaviours of this file on this
  machine. It proves nothing about capture-run's call site, which grocery\test-commit-size-gate.ps1 owns (plan W2.2).

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\json-io.ps1).
#>
# gate-inputs: grocery\commit-size-lib.ps1, lib\ledger-lock.ps1, lib\event-bus.ps1, lib\ledger-fixture.ps1, lib\atomic-write.ps1, lib\git-blob-lib.ps1, lib\git-repo-env.ps1
$__cslSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ledger-lock.ps1')    # Enter-TcLedgerLock, and ledger-fixture's writer barrier
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\atomic-write.ps1')   # Write-TcAtomicFile
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-blob-lib.ps1')   # Invoke-GitCaptured: every git call, never a native redirect

$script:CslLedgerName = 'tc-commit-carry.json'

# ---- THE PATH-DATE RULE (pure) ------------------------------------------------------------------------------------------
function Get-CaptureDateOf([string]$Path) {
  <# The capture date a path names: the LAST yyyy-MM-dd in it, else a yyyyMMdd directly before -HHmmss, else ''. A date
     inside a longer run of digits is not a date. #>
  $m = [regex]::Matches($Path, '(?<!\d)(20\d\d)-(\d\d)-(\d\d)(?!\d)')
  if ($m.Count) { $g = $m[$m.Count - 1].Groups; return ($g[1].Value + '-' + $g[2].Value + '-' + $g[3].Value) }
  $m = [regex]::Matches($Path, '(?<!\d)(20\d\d)(\d\d)(\d\d)(?=-\d{6})')
  if ($m.Count) { $g = $m[$m.Count - 1].Groups; return ($g[1].Value + '-' + $g[2].Value + '-' + $g[3].Value) }
  return ''
}

# ---- SMALL PURE HELPERS -------------------------------------------------------------------------------------------------
function ConvertTo-CslUtc($Value) {
  <# A UTC DateTime from a DateTime, a DateTimeOffset or an ISO 8601 string; $null when it is none of them. A DateTime whose
     Kind is Unspecified is read as local time, which is what Get-Date and LastWriteTime mean by one. #>
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
  if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
  $s = [string]$Value
  if (-not $s.Trim()) { return $null }
  $dto = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto.UtcDateTime }
  return $null
}

function ConvertTo-CslBytes($Value) {
  <# A byte length as [long], or $null when the value is not a whole number at or above zero. #>
  if ($null -eq $Value) { return $null }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32]) {
    $l = [long]$Value
    if ($l -lt 0) { return $null }
    return $l
  }
  if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
    try { $d = [decimal]$Value } catch { return $null }
    if ($d -lt 0 -or [decimal]::Truncate($d) -ne $d -or $d -gt [decimal][long]::MaxValue) { return $null }
    return [long]$d
  }
  return $null
}

function ConvertTo-CslRepoPath([string]$Path) {
  <# A repo path as git writes it: forward slashes. Git never writes a backslash into a path on Windows. #>
  if (-not $Path) { return '' }
  return $Path.Replace('\', '/')
}

function Get-CslField($Obj, [string]$Name) {
  <# One named field of a hashtable or an object, or $null. The comma keeps an array value from unrolling. #>
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [Collections.IDictionary]) {
    foreach ($k in $Obj.Keys) { if ([string]::Equals([string]$k, $Name, [StringComparison]::OrdinalIgnoreCase)) { return , $Obj[$k] } }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p) { return , $p.Value }
  return $null
}

function Test-CslOverCaps([long]$Files, [long]$Bytes, [int]$FileCap, [double]$MbCap) {
  <# capture-run's size test since 2026-08-23, exactly: more files than the cap, or the MB rounded to one place (the
     default Math.Round, which rounds a midpoint to even) above the MB cap. #>
  return (($Files -gt $FileCap) -or ([math]::Round($Bytes / 1MB, 1) -gt $MbCap))
}

function Measure-CslEntries([object[]]$Entries) {
  <# files, bytes and mb (rounded to one place, for display) over entries carrying .bytes. A $null length adds a file and
     no bytes, the way capture-run counts an addition it cannot measure. #>
  $n = 0
  [long]$b = 0
  foreach ($e in $Entries) {
    if ($null -eq $e) { continue }
    $n++
    if ($null -ne $e.bytes) { $b += [long]$e.bytes }
  }
  return [pscustomobject]@{ files = $n; bytes = $b; mb = [math]::Round($b / 1MB, 1) }
}

function Format-CslMb($Mb) { return ([double]$Mb).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }

function ConvertTo-CslCarryRun($Run) {
  <# One carry record in a fixed shape - run_id, kind, checkout, started and recorded as UTC DateTimes (or $null when
     unreadable), verdict, paths as an ORDINAL string->[long] dictionary, files, bytes, bad_paths - from a parsed ledger
     row, a hashtable or an already-normalised record. $null when the row names no run. #>
  if ($null -eq $Run) { return $null }
  $id = [string](Get-CslField $Run 'run_id')
  if (-not $id) { return $null }
  $dict = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
  $bad = 0
  $raw = Get-CslField $Run 'paths'
  $pairs = [Collections.Generic.List[object]]::new()
  if ($raw -is [Collections.IDictionary]) { foreach ($k in $raw.Keys) { $pairs.Add(@([string]$k, $raw[$k])) } }
  elseif ($null -ne $raw) { foreach ($prop in $raw.PSObject.Properties) { $pairs.Add(@([string]$prop.Name, $prop.Value)) } }
  [long]$sum = 0
  foreach ($pr in $pairs) {
    $p = ConvertTo-CslRepoPath $pr[0]
    $b = ConvertTo-CslBytes $pr[1]
    if (-not $p -or $null -eq $b -or $dict.ContainsKey($p)) { $bad++; continue }
    $dict[$p] = $b
    $sum += $b
  }
  return [pscustomobject]@{
    run_id = $id; kind = [string](Get-CslField $Run 'kind'); checkout = [string](Get-CslField $Run 'checkout')
    started = (ConvertTo-CslUtc (Get-CslField $Run 'started')); recorded = (ConvertTo-CslUtc (Get-CslField $Run 'recorded'))
    verdict = [string](Get-CslField $Run 'verdict'); paths = $dict; files = $dict.Count; bytes = $sum; bad_paths = $bad
  }
}

# ---- THE JUDGE (pure) ---------------------------------------------------------------------------------------------------
function Test-CarriedCommitSize {
  <# Splits a commit's additions into own, carried and unvouched (see the header) and judges them. Returns
       ok, verdict ('within-caps' | 'over-caps': what own + unvouched met, the verdict Add-TcCommitCarry records),
       own / unvouched / judged = @{ files; bytes; mb }, carried = @(@{ run_id; kind; verdict; recorded; age_h; files;
       bytes; mb; record_files; record_bytes; deep }), deep, deep_days, own_files and unvouched_files (@{ path; bytes }),
       why (every reason it refuses; empty exactly when ok) and notes (what vouched nothing, and why).
     -Added holds @{ path; bytes; mtime } per addition. -Records holds runs as Read-TcCommitCarry returns them. #>
  param(
    [object[]]$Added = @(),
    [Parameter(Mandatory = $true)]$RunStart,
    [object[]]$Records = @(),
    [Parameter(Mandatory = $true)]$Now,
    [int]$FileCap = 300,
    [double]$MbCap = 25,
    [int]$WindowHours = 72,
    [int]$DeepHours = 24
  )
  $nowU = ConvertTo-CslUtc $Now
  $startU = ConvertTo-CslUtc $RunStart
  if ($null -eq $nowU -or $null -eq $startU) { throw ('Test-CarriedCommitSize: -Now and -RunStart must be dates (got "{0}" and "{1}")' -f $Now, $RunStart) }
  $windowTicks = [long]$WindowHours * [TimeSpan]::TicksPerHour
  $deepTicks = [long]$DeepHours * [TimeSpan]::TicksPerHour
  $why = [Collections.Generic.List[string]]::new()
  $notes = [Collections.Generic.List[string]]::new()

  # WHICH RECORDS MAY VOUCH. Age is measured from `recorded`, in ticks, so the bar is exact.
  $eligible = [Collections.Generic.List[object]]::new()
  foreach ($raw in @($Records)) {
    if ($null -eq $raw) { continue }
    $r = ConvertTo-CslCarryRun $raw
    if ($null -eq $r) { $notes.Add('a carry record that names no run vouches nothing'); continue }
    # A SWITCH ON DATA, and its default refuses to vouch: see A VERDICT THIS FILE DOES NOT KNOW in the header.
    switch -CaseSensitive ($r.verdict) {
      'within-caps' { $mayVouch = $true }
      'over-caps' { $mayVouch = $false; $notes.Add(('run {0} was recorded over-caps: its {1} file(s) vouch nothing' -f $r.run_id, $r.files)) }
      default { $mayVouch = $false; $notes.Add(('run {0} carries an unknown verdict "{1}": its {2} file(s) vouch nothing' -f $r.run_id, $r.verdict, $r.files)) }
    }
    if (-not $mayVouch) { continue }
    if ($null -eq $r.recorded) { $notes.Add(('run {0} has no readable recorded time: its {1} file(s) vouch nothing' -f $r.run_id, $r.files)); continue }
    $age = ($nowU - $r.recorded).Ticks
    if ($age -lt 0) { $notes.Add(('run {0} is recorded after now: its {1} file(s) vouch nothing' -f $r.run_id, $r.files)); continue }
    if ($age -gt $windowTicks) {
      $notes.Add(('run {0} was recorded {1} h ago, past the {2} h window: its {3} file(s) vouch nothing' -f $r.run_id, (Format-CslMb ($age / [TimeSpan]::TicksPerHour)), $WindowHours, $r.files))
      continue
    }
    $eligible.Add([pscustomobject]@{ rec = $r; age = $age })
  }

  # THE BUCKETS.
  $ownL = [Collections.Generic.List[object]]::new()
  $unvL = [Collections.Generic.List[object]]::new()
  $byRun = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  $moved = 0
  foreach ($a in @($Added)) {
    if ($null -eq $a) { continue }
    $p = ConvertTo-CslRepoPath ([string](Get-CslField $a 'path'))
    $b = ConvertTo-CslBytes (Get-CslField $a 'bytes')
    $m = ConvertTo-CslUtc (Get-CslField $a 'mtime')
    $entry = [pscustomobject]@{ path = $p; bytes = $b }
    if ($null -ne $m -and $m -ge $startU) { $ownL.Add($entry); continue }
    $best = $null; $named = $false
    if ($p -and $null -ne $b -and $null -ne $m) {
      foreach ($e in $eligible) {
        $v = [long]0
        if (-not $e.rec.paths.TryGetValue($p, [ref]$v)) { continue }
        $named = $true
        if ($v -ne $b) { continue }
        if ($null -eq $best -or $e.age -lt $best.age -or ($e.age -eq $best.age -and [string]::CompareOrdinal($e.rec.run_id, $best.rec.run_id) -lt 0)) { $best = $e }
      }
    }
    if ($null -ne $best) {
      if (-not $byRun.ContainsKey($best.rec.run_id)) { $byRun[$best.rec.run_id] = [pscustomobject]@{ hit = $best; entries = [Collections.Generic.List[object]]::new() } }
      $byRun[$best.rec.run_id].entries.Add($entry)
      continue
    }
    if ($named) {
      $moved++
      if ($moved -le 20) { $notes.Add(('{0}: its length is not the one any in-window record gave it (now {1} bytes), so it is unvouched' -f $p, $b)) }
    }
    $unvL.Add($entry)
  }
  if ($moved -gt 20) { $notes.Add(('...and {0} more file(s) whose length moved since their record' -f ($moved - 20))) }

  # THE JUDGEMENT: own + unvouched at exactly today's caps.
  $ownM = Measure-CslEntries $ownL.ToArray()
  $unvM = Measure-CslEntries $unvL.ToArray()
  $jFiles = $ownM.files + $unvM.files
  [long]$jBytes = $ownM.bytes + $unvM.bytes
  $jOver = Test-CslOverCaps -Files $jFiles -Bytes $jBytes -FileCap $FileCap -MbCap $MbCap
  if ($jOver) {
    $why.Add(('own + unvouched: {0} file(s) / {1} MB is over one run''s caps of {2} files / {3} MB ({4} own, {5} unvouched)' -f $jFiles, (Format-CslMb ([math]::Round($jBytes / 1MB, 1))), $FileCap, $MbCap, $ownM.files, $unvM.files))
  }

  # EACH CARRIED RECORD, judged again at one run's caps: they met them when recorded, so a record that does not is refused.
  $carried = [Collections.Generic.List[object]]::new()
  $deep = $false; [long]$oldest = 0
  foreach ($g in @($byRun.Values | Sort-Object -Property @{ Expression = { $_.hit.age } }, @{ Expression = { $_.hit.rec.run_id } })) {
    $rec = $g.hit.rec; $age = [long]$g.hit.age
    $cm = Measure-CslEntries $g.entries.ToArray()
    if (Test-CslOverCaps -Files $rec.files -Bytes $rec.bytes -FileCap $FileCap -MbCap $MbCap) {
      $why.Add(('carried run {0}: its record names {1} file(s) / {2} MB, over one run''s caps, so it cannot have met them and vouches for none' -f $rec.run_id, $rec.files, (Format-CslMb ([math]::Round($rec.bytes / 1MB, 1)))))
    }
    $isDeep = ($age -gt $deepTicks)
    if ($isDeep) { $deep = $true }
    if ($age -gt $oldest) { $oldest = $age }
    $carried.Add([pscustomobject]@{
      run_id = $rec.run_id; kind = $rec.kind; verdict = $rec.verdict; recorded = $rec.recorded.ToString('o')
      age_h = [math]::Round($age / [TimeSpan]::TicksPerHour, 1); files = $cm.files; bytes = $cm.bytes; mb = $cm.mb
      record_files = $rec.files; record_bytes = $rec.bytes; deep = $isDeep
    })
  }
  $deepDays = 0
  if ($deep) { $deepDays = [int][math]::Ceiling($oldest / [double][TimeSpan]::TicksPerDay) }

  return [pscustomobject]@{
    ok = ($why.Count -eq 0)
    verdict = $(if ($jOver) { 'over-caps' } else { 'within-caps' })
    own = $ownM
    carried = $carried.ToArray()
    unvouched = $unvM
    judged = [pscustomobject]@{ files = $jFiles; bytes = $jBytes; mb = [math]::Round($jBytes / 1MB, 1) }
    deep = $deep
    deep_days = $deepDays
    own_files = $ownL.ToArray()
    unvouched_files = $unvL.ToArray()
    why = $why.ToArray()
    notes = $notes.ToArray()
    caps = [pscustomobject]@{ files = $FileCap; mb = $MbCap; window_h = $WindowHours; deep_h = $DeepHours }
  }
}

function Format-CarriedCommitSize {
  <# The lines a caller prints for one Test-CarriedCommitSize result: one per bucket (own, each carried run, unvouched),
     the verdict over own + unvouched, the backlog depth when deep, then every refusal reason and every note. #>
  param([Parameter(Mandatory = $true)]$Result)
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add(('commit-size: own        {0} file(s) / {1} MB, written at or after this run started' -f $Result.own.files, (Format-CslMb $Result.own.mb)))
  foreach ($c in @($Result.carried)) {
    if ($null -eq $c) { continue }
    $lines.Add(('commit-size: carried    {0} file(s) / {1} MB from run {2} ({3}, recorded {4} h ago, {5}){6}' -f $c.files, (Format-CslMb $c.mb), $c.run_id, $c.kind, (Format-CslMb $c.age_h), $c.verdict, $(if ($c.deep) { ' DEEP' } else { '' })))
  }
  $lines.Add(('commit-size: unvouched  {0} file(s) / {1} MB' -f $Result.unvouched.files, (Format-CslMb $Result.unvouched.mb)))
  $lines.Add(('commit-size: own + unvouched {0} file(s) / {1} MB against {2} files / {3} MB: {4}' -f $Result.judged.files, (Format-CslMb $Result.judged.mb), $Result.caps.files, $Result.caps.mb, $(if ($Result.verdict -eq 'within-caps') { 'within caps' } else { 'OVER caps' })))
  if ($Result.deep) { $lines.Add(('commit-size: capture backlog {0} day(s) deep - a carried record is older than {1} h' -f $Result.deep_days, $Result.caps.deep_h)) }
  foreach ($w in @($Result.why)) { if ($w) { $lines.Add('commit-size: REFUSED - ' + $w) } }
  foreach ($n in @($Result.notes)) { if ($n) { $lines.Add('commit-size: note - ' + $n) } }
  return , $lines.ToArray()
}

# ---- THE LEDGER ---------------------------------------------------------------------------------------------------------
function Get-TcCommitCarryPath {
  <# The carry ledger's full path: $env:TC_COMMIT_CARRY_PATH when set (fixtures only), else
     <git common dir>\tc-commit-carry.json. $null when git cannot name the common dir. #>
  param([string]$Repo)
  $o = [string]$env:TC_COMMIT_CARRY_PATH
  if ($o.Trim()) { return [IO.Path]::GetFullPath($o) }
  if (-not $Repo) { return $null }
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--git-common-dir')
  if ($g.rc -ne 0) { return $null }
  $d = ([string]$g.stdout).Trim()
  if (-not $d) { return $null }
  if (-not [IO.Path]::IsPathRooted($d)) { $d = Join-Path $Repo $d }
  return (Join-Path ([IO.Path]::GetFullPath($d)) $script:CslLedgerName)
}

function Get-TcCommitCarryCheckout {
  <# The checkout a carry record belongs to: its toplevel, full, lower-cased, backslashed (lib\pipeline-commit.ps1's key). #>
  param([string]$Repo)
  if (-not $Repo) { return '' }
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--show-toplevel')
  $t = if ($g.rc -eq 0 -and ([string]$g.stdout).Trim()) { ([string]$g.stdout).Trim() } else { $Repo }
  return ([IO.Path]::GetFullPath($t.Replace('/', '\'))).TrimEnd('\').ToLowerInvariant()
}

function Read-CslLedgerDoc([string]$Path) {
  <# The ledger's runs, normalised. state is 'absent', 'ok' or 'unreadable'. The CALLER holds the lock. #>
  if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ state = 'absent'; runs = @(); dropped = 0; bad_paths = 0; why = '' } }
  $doc = $null
  try { $doc = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
  catch { return [pscustomobject]@{ state = 'unreadable'; runs = @(); dropped = 0; bad_paths = 0; why = ('it does not parse as JSON: ' + $_.Exception.Message) } }
  $sp = $null; $rp = $null
  if ($null -ne $doc -and $doc -isnot [array]) { $sp = $doc.PSObject.Properties['schema']; $rp = $doc.PSObject.Properties['runs'] }
  if ($null -eq $sp -or -not ($sp.Value -is [int] -and $sp.Value -eq 1) -or $null -eq $rp -or $rp.Value -isnot [array]) {
    return [pscustomobject]@{ state = 'unreadable'; runs = @(); dropped = 0; bad_paths = 0; why = 'it is not a schema 1 ledger with a runs array' }
  }
  $runs = [Collections.Generic.List[object]]::new()
  $dropped = 0; $badPaths = 0
  foreach ($x in $rp.Value) {
    $r = ConvertTo-CslCarryRun $x
    if ($null -eq $r) { $dropped++; continue }
    $badPaths += $r.bad_paths
    $runs.Add($r)
  }
  return [pscustomobject]@{ state = 'ok'; runs = $runs.ToArray(); dropped = $dropped; bad_paths = $badPaths; why = '' }
}

function ConvertTo-CslLedgerJson([object[]]$Runs) {
  <# The ledger text for normalised runs. Paths are written in ordinal order, so one set of runs is one text. #>
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($r in $Runs) {
    if ($null -eq $r) { continue }
    $keys = [string[]]@($r.paths.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $pd = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
    foreach ($k in $keys) { $pd[$k] = $r.paths[$k] }
    $rows.Add([ordered]@{
      run_id = $r.run_id; kind = $r.kind; checkout = $r.checkout
      started = $(if ($r.started) { $r.started.ToString('o') } else { '' }); recorded = $(if ($r.recorded) { $r.recorded.ToString('o') } else { '' })
      verdict = $r.verdict; files = [int]$pd.Count; bytes = [long]$r.bytes; paths = $pd
    })
  }
  return ([ordered]@{ schema = 1; runs = $rows.ToArray() } | ConvertTo-Json -Depth 6)
}

function Get-CslTrackedPaths {
  <# Which of $Paths HEAD tracks, asked of git in chunks of 50 so a long list never meets the command-line limit. Literal
     pathspecs, so a path holding a glob character names only itself. ok=$false when git could not answer. #>
  param([string]$Repo, [string[]]$Paths)
  $found = [Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $Paths.Count; $i += 50) {
    $chunk = @($Paths[$i..([Math]::Min($i + 49, $Paths.Count - 1))])
    $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('--literal-pathspecs', '-c', 'core.quotePath=false', 'ls-tree', '-r', '-z', '--name-only', 'HEAD', '--') + $chunk)
    if ($g.rc -ne 0) { return [pscustomobject]@{ ok = $false; tracked = @(); why = ('git ls-tree exited ' + $g.rc + ': ' + ([string]$g.stderr).Trim()) } }
    foreach ($t in ([string]$g.stdout).Split([char]0)) { if ($t) { $found.Add($t) } }
  }
  return [pscustomobject]@{ ok = $true; tracked = $found.ToArray(); why = '' }
}

function Read-TcCommitCarry {
  <# The carry records of ONE checkout (-Checkout, or the one -Repo is in; neither means every checkout's). Returns
     @{ ok; path; runs; other_checkouts; dropped; why }. Never throws: a ledger it cannot read gives ok=$false and no runs,
     so every older addition is unvouched, which is today's gate. #>
  param([string]$Repo, [string]$Checkout = '', [int]$TimeoutMs = $script:TcLedgerLockTimeoutMs)
  $out = [pscustomobject]@{ ok = $false; path = $null; runs = @(); other_checkouts = 0; dropped = 0; why = '' }
  $path = $null
  try { $path = Get-TcCommitCarryPath -Repo $Repo } catch { $path = $null }
  if (-not $path) { $out.why = 'git could not name the common dir, so there is no carry ledger to read: every older addition is unvouched'; return $out }
  $out.path = $path
  $doc = $null; $lock = $null
  try {
    $lock = Enter-TcLedgerLock -Path $path -TimeoutMs $TimeoutMs
    $doc = Read-CslLedgerDoc -Path $path
  } catch {
    $out.why = ('could not read the carry ledger (' + $_.Exception.Message + '): every older addition is unvouched')
    return $out
  } finally { Exit-TcLedgerLock $lock }
  if ($doc.state -eq 'unreadable') { $out.why = ('the carry ledger ' + $path + ' is unreadable (' + $doc.why + '): every older addition is unvouched'); return $out }
  $filter = $Checkout
  if (-not $filter -and $Repo) { $filter = Get-TcCommitCarryCheckout -Repo $Repo }
  $mine = [Collections.Generic.List[object]]::new(); $other = 0
  foreach ($r in $doc.runs) {
    if ($filter -and -not [string]::Equals([string]$r.checkout, $filter, [StringComparison]::Ordinal)) { $other++; continue }
    $mine.Add($r)
  }
  $out.ok = $true
  $out.runs = $mine.ToArray()
  $out.other_checkouts = $other
  $out.dropped = $doc.dropped
  $out.why = $(if ($doc.state -eq 'absent') { 'no carry ledger yet' } else { ('{0} run(s) for this checkout, {1} for others, {2} unreadable row(s) left out' -f $mine.Count, $other, $doc.dropped) })
  return $out
}

function Add-TcCommitCarry {
  <# Records one run's OWN additions and its verdict. Replaces a run with the same run_id (idempotent), prunes runs
     recorded more than -WindowHours ago and runs all of whose paths HEAD now tracks, never the run being added. Returns
     @{ ok; path; run_id; files; bytes; kept; pruned_age; pruned_tracked; replaced; skipped; note }.
     THROWS when the ledger lock is not free within -TimeoutMs, or the replace fails, having written nothing: the caller
     logs it and pages once, and never fails its run on it (plan W2.2 step 4).
     -Files holds @{ path; bytes } per addition. -TrackedBy { param($paths) } returns @{ ok; tracked; why } in place of
     asking git, for fixtures. #>
  param(
    [string]$Repo,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Run,
    [Parameter(Mandatory = $true)][ValidateSet('ad', 'daily', IgnoreCase = $false)][string]$Kind,
    [Parameter(Mandatory = $true)]$Started,
    [Parameter(Mandatory = $true)][ValidateSet('within-caps', 'over-caps', IgnoreCase = $false)][string]$Verdict,
    [object[]]$Files = @(),
    $Now = $null,
    [string]$Checkout = '',
    [scriptblock]$TrackedBy = $null,
    [int]$WindowHours = 72,
    [int]$TimeoutMs = $script:TcLedgerLockTimeoutMs
  )
  $nowU = if ($null -eq $Now) { [datetime]::UtcNow } else { ConvertTo-CslUtc $Now }
  $startU = ConvertTo-CslUtc $Started
  if ($null -eq $nowU -or $null -eq $startU) { throw ('Add-TcCommitCarry: -Started and -Now must be dates (got "{0}" and "{1}"). NOTHING was written.' -f $Started, $Now) }
  $path = Get-TcCommitCarryPath -Repo $Repo
  if (-not $path) { throw ('Add-TcCommitCarry: git could not name the common dir of "' + $Repo + '", so there is no carry ledger. NOTHING was written.') }
  $who = $Checkout
  if (-not $who) { $who = Get-TcCommitCarryCheckout -Repo $Repo }

  $newPaths = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
  $skipped = 0
  [long]$newBytes = 0
  foreach ($f in @($Files)) {
    if ($null -eq $f) { continue }
    $p = ConvertTo-CslRepoPath ([string](Get-CslField $f 'path'))
    $b = ConvertTo-CslBytes (Get-CslField $f 'bytes')
    if (-not $p -or $null -eq $b -or $newPaths.ContainsKey($p)) { $skipped++; continue }
    $newPaths[$p] = $b
    $newBytes += $b
  }
  $windowTicks = [long]$WindowHours * [TimeSpan]::TicksPerHour
  $notes = [Collections.Generic.List[string]]::new()
  $lock = Enter-TcLedgerLock -Path $path -TimeoutMs $TimeoutMs   # throws, having written nothing
  try {
    # THE READ IS INSIDE THE LOCK: a lock around the save alone writes back what was read before it was taken.
    $cur = Read-CslLedgerDoc -Path $path
    $runs = @($cur.runs)
    if ($cur.state -eq 'unreadable') {
      $aside = $path + '.unreadable-' + $nowU.ToString('yyyyMMdd''T''HHmmssfff''Z''', [Globalization.CultureInfo]::InvariantCulture)
      Move-Item -LiteralPath $path -Destination $aside -ErrorAction Stop   # no -Force: a name that exists refuses, never overwrites
      $notes.Add(('the ledger was unreadable (' + $cur.why + '); moved aside to ' + $aside + ' and a fresh one written'))
      $runs = @()
    }
    if ($cur.dropped) { $notes.Add(([string]$cur.dropped + ' unreadable run row(s) dropped')) }
    if ($cur.bad_paths) { $notes.Add(([string]$cur.bad_paths + ' unreadable path row(s) dropped')) }

    $replaced = 0; $prunedAge = 0; $prunedTracked = 0
    $aged = [Collections.Generic.List[object]]::new()
    foreach ($r in $runs) {
      if ($null -eq $r) { continue }
      if ([string]::Equals([string]$r.run_id, $Run, [StringComparison]::Ordinal)) { $replaced++; continue }
      # A run whose time cannot be read cannot be aged, and it vouches nothing, so it goes with the old ones.
      if ($null -eq $r.recorded -or ($nowU - $r.recorded).Ticks -gt $windowTicks) { $prunedAge++; continue }
      $aged.Add($r)
    }
    $kept = [Collections.Generic.List[object]]::new()
    $ask = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $aged) { foreach ($k in $r.paths.Keys) { [void]$ask.Add($k) } }
    $trk = [pscustomobject]@{ ok = $true; tracked = @(); why = '' }
    if ($ask.Count) {
      $askArr = [string[]]@($ask)
      $trk = if ($TrackedBy) { & $TrackedBy $askArr } else { Get-CslTrackedPaths -Repo $Repo -Paths $askArr }
    }
    if ($null -eq $trk -or -not $trk.ok) {
      $notes.Add(('could not ask git which paths HEAD tracks (' + $(if ($trk) { $trk.why } else { 'no answer' }) + '): no run was pruned as committed'))
      foreach ($r in $aged) { $kept.Add($r) }
    } else {
      $tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach ($t in @($trk.tracked)) { if ($t) { [void]$tracked.Add((ConvertTo-CslRepoPath ([string]$t))) } }
      foreach ($r in $aged) {
        $all = $true
        foreach ($k in $r.paths.Keys) { if (-not $tracked.Contains($k)) { $all = $false; break } }
        if ($all) { $prunedTracked++ } else { $kept.Add($r) }
      }
    }
    $kept.Add([pscustomobject]@{
      run_id = $Run; kind = $Kind; checkout = $who; started = $startU; recorded = $nowU; verdict = $Verdict
      paths = $newPaths; files = $newPaths.Count; bytes = $newBytes; bad_paths = 0
    })
    [void](Write-TcAtomicFile -Path $path -Text (ConvertTo-CslLedgerJson -Runs $kept.ToArray()) -NoBom)
  } finally { Exit-TcLedgerLock $lock }
  if ($skipped) { $notes.Add(([string]$skipped + ' file row(s) with no path or no whole byte length were not recorded')) }
  return [pscustomobject]@{
    ok = $true; path = $path; run_id = $Run; files = $newPaths.Count; bytes = $newBytes; kept = $kept.Count
    pruned_age = $prunedAge; pruned_tracked = $prunedTracked; replaced = $replaced; skipped = $skipped; note = ($notes -join '; ')
  }
}

# ---- SELF-TEST ----------------------------------------------------------------------------------------------------------
# Every case below is a literal line, so the suite asserts how many ran. Every path is under one per-run temp directory,
# removed in the finally. The judge's cases touch no disk; the ledger's go through TC_COMMIT_CARRY_PATH; one group builds
# a temp git repo after Clear-TcGitRepoEnv. No case asserts how long anything took: the lock and barrier cases wait on a
# holder in ANOTHER process, and every wait is a hang guard only. All byte counts are whole bytes and every MiB figure a
# power-of-two fraction, so a case at a bar is on the bar in binary as well as on paper.
if ($__cslSelfTest) {
  $ErrorActionPreference = 'Stop'
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-repo-env.ps1')
  Clear-TcGitRepoEnv   # this process owns its environment; the lib never does this when it is dot-sourced
  $script:cslExpected = 43
  $script:cslN = 0; $script:cslBad = 0
  function Test-CslCase([string]$Label, [string]$Name, [bool]$Ok, [string]$Got = '') {
    $script:cslN++
    if ($Ok) { Write-Output ('  ok    ' + $Label + '  ' + $Name) }
    else { $script:cslBad++; Write-Output ('  FAIL  ' + $Label + '  ' + $Name + '   got: ' + $Got) }
  }
  $MiB = [long]1048576
  function New-CslAdds([string]$Stem, [int]$Count, [long]$Bytes, $Mtime) {
    $l = [Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $Count; $i++) { $l.Add([pscustomobject]@{ path = ('{0}-{1:D4}.json' -f $Stem, $i); bytes = $Bytes; mtime = $Mtime }) }
    return , $l.ToArray()
  }
  function New-CslRecord([string]$Id, [string]$Verdict, $Recorded, [object[]]$Files) {
    $pth = @{}
    foreach ($f in $Files) { $pth[[string]$f.path] = [long]$f.bytes }
    return [pscustomobject]@{ run_id = $Id; kind = 'daily'; checkout = 'fixture'; started = $Recorded; recorded = $Recorded; verdict = $Verdict; paths = $pth }
  }
  # TODAY'S GATE, restated for the fixtures as capture-run holds it at this file's landing: every addition counts, and the
  # MB is the sum of each file's Length / 1MB rounded to one place. The shipped block itself is test-commit-size-gate's.
  function Test-CslTodayRefuses([object[]]$Adds) {
    $mb = 0.0
    foreach ($x in $Adds) { $mb += ([long]$x.bytes / 1MB) }
    return (($Adds.Count -gt 300) -or ([math]::Round($mb, 1) -gt 25))
  }
  function Get-CslSha([string]$Path) { if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } return 'absent' }
  $stub = { param($p) [pscustomobject]@{ ok = $true; tracked = @(); why = '' } }

  $cslExe = (Get-Command powershell).Source
  $cslDir = Join-Path ([IO.Path]::GetTempPath()) ('tc-csl-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $null = New-Item -ItemType Directory -Path $cslDir -ErrorAction Stop
  $prevCarry = $env:TC_COMMIT_CARRY_PATH
  $prevBus = $env:TC_EVENT_BUS
  $env:TC_EVENT_BUS = Join-Path $cslDir 'bus.jsonl'   # a lock refusal writes an event: keep it off the live bus
  $kids = [Collections.Generic.List[object]]::new()
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    # ---- the path-date rule ----
    $d1 = Get-CaptureDateOf 'grocery/out/2026-09-21/hy-vee-regular-2026-09-22.json'
    $d2 = Get-CaptureDateOf 'grocery/out/regular/aldi-regular-2026-09-20.json'
    Test-CslCase 'MUST FIRE' 'the LAST yyyy-MM-dd in a path is its capture date' ($d1 -eq '2026-09-22' -and $d2 -eq '2026-09-20') ("d1=$d1 d2=$d2")
    $d3 = Get-CaptureDateOf 'grocery/out/logs/walmart-20260922-081530.json'
    Test-CslCase 'MUST FIRE' 'a yyyyMMdd directly before -HHmmss is a capture date' ($d3 -eq '2026-09-22') ("d3=$d3")
    $d4 = @((Get-CaptureDateOf 'grocery/out/aisle-test.json'), (Get-CaptureDateOf 'grocery/out/x-20260922.json'), (Get-CaptureDateOf 'grocery/out/id-12026-09-22.json'), (Get-CaptureDateOf 'grocery/out/2026-09-221.json')) -join '|'
    Test-CslCase 'MUST NOT FIRE' 'no date, a compact date with no -HHmmss, and a date inside a longer number all read as undated' ($d4 -eq '|||') ("got=$d4")

    # ---- the judge: the incident ----
    $start7 = [datetime]::new(2026, 9, 23, 12, 0, 0, [DateTimeKind]::Utc)     # 07:00 CDT, the 07:00 run's start
    $now7 = $start7.AddMinutes(30)
    $rec22 = [datetime]::new(2026, 9, 22, 13, 45, 0, [DateTimeKind]::Utc)     # 08:45 CDT on 09-22, when that run was refused
    $old = $rec22.AddMinutes(-45)
    $own7T = $start7.AddMinutes(10)
    $c22a = New-CslAdds 'grocery/out/regular/c-2026-09-22-a' 17 $MiB $old
    $c22b = New-CslAdds 'grocery/out/regular/c-2026-09-22-b' 2 ($MiB / 4) $old
    $c22 = $c22a + $c22b                                                     # 19 files, 17.5 MiB = 18,350,080 bytes
    $o7a = New-CslAdds 'grocery/out/regular/o-2026-09-23-a' 9 $MiB $own7T
    $o7b = New-CslAdds 'grocery/out/regular/o-2026-09-23-b' 12 196608 $own7T
    $own7 = $o7a + $o7b                                                      # 21 files, 11.25 MiB = 11,796,480 bytes
    $r22 = New-CslRecord 'capture-run-daily-2026-09-22' 'within-caps' $rec22 $c22
    $rInc = Test-CarriedCommitSize -Added ($c22 + $own7) -RunStart $start7 -Records @($r22) -Now $now7
    Test-CslCase 'MUST NOT FIRE' 'the 09-23 07:00 shape: 09-22''s refused run recorded 19 files / 17.5 MiB within-caps and this run''s own 21 files / 11.25 MiB are admitted together, where today''s gate refused the 40 files / 28.8 MB sum (the log''s totals; the split between them is chosen, not measured)' `
      ($rInc.ok -and $rInc.own.files -eq 21 -and $rInc.own.bytes -eq 11796480 -and $rInc.carried.Count -eq 1 -and $rInc.carried[0].files -eq 19 -and $rInc.carried[0].bytes -eq 18350080 -and $rInc.unvouched.files -eq 0 -and (Test-CslTodayRefuses ($c22 + $own7))) `
      ("ok=$($rInc.ok) own=$($rInc.own.files)/$($rInc.own.bytes) carried=$($rInc.carried.Count) unvouched=$($rInc.unvouched.files) why=$($rInc.why -join ';')")

    $start8 = [datetime]::new(2026, 9, 23, 13, 0, 0, [DateTimeKind]::Utc)     # 08:00 CDT
    $now8 = $start8.AddMinutes(40)
    $rec7 = $now7.AddMinutes(1)
    $o8a = New-CslAdds 'grocery/out/regular/p-2026-09-23-a' 10 1310720 $start8.AddMinutes(10)
    $o8b = New-CslAdds 'grocery/out/regular/p-2026-09-23-b' 1 2162688 $start8.AddMinutes(10)
    $own8 = $o8a + $o8b                                                      # 11 files, 14.5625 MiB = 15,269,888 bytes
    $r7 = New-CslRecord 'capture-run-ad-2026-09-23' 'within-caps' $rec7 $own7
    $r8 = Test-CarriedCommitSize -Added ($c22 + $own7 + $own8) -RunStart $start8 -Records @($r22, $r7) -Now $now8
    Test-CslCase 'MUST NOT FIRE' 'the 09-23 08:00 shape: two refused runs carried (19 files / 17.5 MiB and 21 / 11.25) plus its own 11 files / 14.5625 MiB are admitted, where today''s gate refused the 51 files / 43.3 MB sum' `
      ($r8.ok -and $r8.carried.Count -eq 2 -and $r8.own.files -eq 11 -and $r8.own.bytes -eq 15269888 -and $r8.unvouched.files -eq 0 -and -not $r8.deep -and (Test-CslTodayRefuses ($c22 + $own7 + $own8))) `
      ("ok=$($r8.ok) carried=$($r8.carried.Count) own=$($r8.own.files)/$($r8.own.bytes) deep=$($r8.deep) why=$($r8.why -join ';')")

    # ---- the judge: the caps, at the bar and one step past ----
    # 150 own + 150 unvouched; 100 of the 300 carry a quarter MiB each, the rest are empty: 300 files, 26,214,400 bytes.
    function New-CslBar([long]$Delta, [int]$Extra) {
      $a1 = New-CslAdds 'grocery/out/bar/own-q' 49 ($MiB / 4) $own7T
      $a2 = New-CslAdds 'grocery/out/bar/own-big' 1 (($MiB / 4) + $Delta) $own7T
      $a3 = New-CslAdds 'grocery/out/bar/own-empty' (100 + $Extra) 0 $own7T
      $a4 = New-CslAdds 'grocery/out/bar/old-q' 50 ($MiB / 4) $old
      $a5 = New-CslAdds 'grocery/out/bar/old-empty' 100 0 $old
      return , ($a1 + $a2 + $a3 + $a4 + $a5)
    }
    $bar = New-CslBar 0 0
    $rBar = Test-CarriedCommitSize -Added $bar -RunStart $start7 -Records @() -Now $now7
    Test-CslCase 'AT THE BAR' 'own + unvouched exactly 300 files and exactly 26,214,400 bytes (25.0 MiB) is admitted' ($rBar.ok -and $rBar.judged.files -eq 300 -and $rBar.judged.bytes -eq 26214400 -and $rBar.own.files -eq 150 -and $rBar.unvouched.files -eq 150) ("ok=$($rBar.ok) judged=$($rBar.judged.files)/$($rBar.judged.bytes)")
    $bar301 = New-CslBar 0 1
    $rB301 = Test-CarriedCommitSize -Added $bar301 -RunStart $start7 -Records @() -Now $now7
    Test-CslCase 'ONE PAST' '301 files (one more, empty) refuses on the 300-file cap' ((-not $rB301.ok) -and $rB301.judged.files -eq 301 -and $rB301.verdict -eq 'over-caps') ("ok=$($rB301.ok) judged=$($rB301.judged.files)")
    $barMb = New-CslBar ($MiB / 4) 0
    $rBMb = Test-CarriedCommitSize -Added $barMb -RunStart $start7 -Records @() -Now $now7
    Test-CslCase 'ONE PAST' '300 files and 26,476,544 bytes (25.25 MiB, rounds to 25.2) refuses on the 25 MB cap' ((-not $rBMb.ok) -and $rBMb.judged.bytes -eq 26476544) ("ok=$($rBMb.ok) bytes=$($rBMb.judged.bytes)")
    $barR1 = New-CslBar 32768 0
    $barR2 = New-CslBar 65536 0
    $rR1 = Test-CarriedCommitSize -Added $barR1 -RunStart $start7 -Records @() -Now $now7
    $rR2 = Test-CarriedCommitSize -Added $barR2 -RunStart $start7 -Records @() -Now $now7
    $todayR1 = Test-CslTodayRefuses $barR1
    Test-CslCase 'CLEAN TWIN' 'the existing rounding is kept: 300 files and 25.03125 MiB round to 25.0 MB and are admitted, exactly as capture-run rounds today' ($rR1.ok -and $rR1.judged.bytes -eq 26247168 -and $todayR1 -eq $false) ("r1=$($rR1.ok)/$($rR1.judged.bytes) today_refuses=$todayR1")
    Test-CslCase 'ONE PAST' 'and 25.0625 MiB rounds to 25.1 MB and refuses, as it does today' ((-not $rR2.ok) -and $rR2.judged.bytes -eq 26279936 -and (Test-CslTodayRefuses $barR2)) ("r2=$($rR2.ok)/$($rR2.judged.bytes)")

    # ---- the judge: nothing is laundered ----
    $flood = New-CslAdds 'grocery/out/regular/flood-2026-09-22' 350 1024 $old
    $rFlood = New-CslRecord 'capture-run-daily-2026-09-22-flood' 'over-caps' $rec22 $flood
    $rNL = Test-CarriedCommitSize -Added ($flood + $own7) -RunStart $start7 -Records @($rFlood) -Now $now7
    Test-CslCase 'MUST FIRE' 'no laundering: an over-caps record vouches nothing, so the 350 files it names (all dated 2026-09-22, at their recorded lengths) are unvouched and refuse' `
      ((-not $rNL.ok) -and $rNL.unvouched.files -eq 350 -and $rNL.carried.Count -eq 0 -and (($rNL.notes -join ' ') -match 'over-caps')) ("ok=$($rNL.ok) unvouched=$($rNL.unvouched.files) carried=$($rNL.carried.Count)")

    $bigOld = New-CslAdds 'grocery/out/regular/big-2026-09-22' 1 (20 * $MiB) $old
    $smallOld = New-CslAdds 'grocery/out/regular/small-2026-09-22' 1 $MiB $old
    $rMovedRec = New-CslRecord 'capture-run-daily-2026-09-22-moved' 'within-caps' $rec22 ($bigOld + $smallOld)
    $bigNow = New-CslAdds 'grocery/out/regular/big-2026-09-22' 1 ((20 * $MiB) + 1) $old
    $rMv = Test-CarriedCommitSize -Added ($bigNow + $smallOld + $own7) -RunStart $start7 -Records @($rMovedRec) -Now $now7
    Test-CslCase 'MUST FIRE' 'a carried path whose byte length moved since its record (20 MiB, now one byte more) counts as unvouched, its unchanged sibling stays carried, and the sum refuses' `
      ((-not $rMv.ok) -and $rMv.unvouched.files -eq 1 -and $rMv.unvouched_files[0].path -eq $bigNow[0].path -and $rMv.carried.Count -eq 1 -and $rMv.carried[0].files -eq 1) ("ok=$($rMv.ok) unvouched=$($rMv.unvouched.files) carried=$($rMv.carried.Count)")

    # ---- the judge: the window and the depth, in ticks ----
    $nowW = $rec22.AddSeconds(259200); $startW = $nowW.AddMinutes(-30)
    $ownW = New-CslAdds 'grocery/out/regular/w-2026-09-25' 21 ($MiB * 9 / 16) $startW.AddMinutes(5)   # 21 files, 11.8125 MiB
    $rW0 = Test-CarriedCommitSize -Added ($c22 + $ownW) -RunStart $startW -Records @($r22) -Now $nowW
    Test-CslCase 'AT THE BAR' 'a record exactly 72 h (259,200 s) old still vouches' ($rW0.carried.Count -eq 1 -and $rW0.carried[0].files -eq 19 -and $rW0.ok) ("carried=$($rW0.carried.Count) ok=$($rW0.ok)")
    $nowW1 = $rec22.AddSeconds(259201); $startW1 = $nowW1.AddMinutes(-30)
    $ownW1 = New-CslAdds 'grocery/out/regular/w-2026-09-25' 21 ($MiB * 9 / 16) $startW1.AddMinutes(5)
    $rW1 = Test-CarriedCommitSize -Added ($c22 + $ownW1) -RunStart $startW1 -Records @($r22) -Now $nowW1
    Test-CslCase 'ONE PAST' 'a record 259,201 s old vouches nothing: its 19 files are unvouched and the sum refuses' ((-not $rW1.ok) -and $rW1.carried.Count -eq 0 -and $rW1.unvouched.files -eq 19) ("carried=$($rW1.carried.Count) unvouched=$($rW1.unvouched.files) ok=$($rW1.ok)")
    $nowD = $rec22.AddSeconds(86400); $startD = $nowD.AddMinutes(-30)
    $rD0 = Test-CarriedCommitSize -Added $c22 -RunStart $startD -Records @($r22) -Now $nowD
    Test-CslCase 'AT THE BAR' 'deep is false for a carried record exactly 24 h (86,400 s) old' ($rD0.ok -and $rD0.carried.Count -eq 1 -and $rD0.deep -eq $false -and $rD0.deep_days -eq 0) ("deep=$($rD0.deep) days=$($rD0.deep_days) carried=$($rD0.carried.Count)")
    $nowD1 = $rec22.AddSeconds(86401); $startD1 = $nowD1.AddMinutes(-30)
    $rD1 = Test-CarriedCommitSize -Added $c22 -RunStart $startD1 -Records @($r22) -Now $nowD1
    Test-CslCase 'ONE PAST' 'deep is true at 86,401 s, the backlog reads 2 days deep, and the commit is still admitted' ($rD1.ok -and $rD1.deep -eq $true -and $rD1.deep_days -eq 2 -and $rD1.carried[0].deep -eq $true) ("deep=$($rD1.deep) days=$($rD1.deep_days) ok=$($rD1.ok)")

    $prof = New-CslAdds 'grocery/out/browser-profiles/fareway/c' 4388 1024 $own7T
    $rProf = Test-CarriedCommitSize -Added $prof -RunStart $start7 -Records @() -Now $now7
    Test-CslCase 'MUST FIRE' 'the 2026-08-22 browser-profiles shape, 4,388 own files, refuses' ((-not $rProf.ok) -and $rProf.own.files -eq 4388) ("ok=$($rProf.ok) own=$($rProf.own.files)")

    # ---- the judge: the size half of every test-commit-size-gate case, with no records ----
    # Each case's files as that fixture writes them: Set-Content in PS 5.1 writes one byte a character plus CRLF. Each is fed
    # twice, all written this run and all older, and with no records both must give today's verdict. Its new-directory
    # refusal and -ForceBigCommit stay in capture-run and are not this file's to judge.
    function Test-CslExisting([int]$Count, [long]$Bytes, [bool]$TodayRefused) {
      $aOwn = New-CslAdds 'grocery/out/f' $Count $Bytes $own7T
      $aOld = New-CslAdds 'grocery/out/f' $Count $Bytes $old
      $x1 = Test-CarriedCommitSize -Added $aOwn -RunStart $start7 -Records @() -Now $now7
      $x2 = Test-CarriedCommitSize -Added $aOld -RunStart $start7 -Records @() -Now $now7
      return (($x1.ok -eq (-not $TodayRefused)) -and ($x2.ok -eq (-not $TodayRefused)) -and ((Test-CslTodayRefuses $aOwn) -eq $TodayRefused))
    }
    Test-CslCase 'CLEAN TWIN' 'with no records, 400 files of 1 KB gives today''s verdict: refused' (Test-CslExisting 400 1026 $true)
    Test-CslCase 'CLEAN TWIN' 'with no records, 12 files of 4 KB gives today''s verdict: admitted' (Test-CslExisting 12 4098 $false)
    Test-CslCase 'CLEAN TWIN' 'with no records, 40 files of 1 MB gives today''s verdict: refused on size' (Test-CslExisting 40 1048578 $true)
    Test-CslCase 'CLEAN TWIN' 'with no records, the 8 cookie files of the new-directory case give today''s size verdict: admitted' (Test-CslExisting 8 8 $false)
    Test-CslCase 'CLEAN TWIN' 'with no records, the one new file in a tracked directory gives today''s verdict: admitted' (Test-CslExisting 1 4 $false)
    Test-CslCase 'CLEAN TWIN' 'with no records, the 10 declared cadence stamps give today''s size verdict: admitted' (Test-CslExisting 10 35 $false)

    # ---- the judge: the edges of each bucket ----
    $atStart = [pscustomobject]@{ path = 'grocery/out/regular/edge-2026-09-23-a.json'; bytes = [long]100; mtime = $start7 }
    $tickBefore = [pscustomobject]@{ path = 'grocery/out/regular/edge-2026-09-23-b.json'; bytes = [long]100; mtime = $start7.AddTicks(-1) }
    $rEdgeRec = New-CslRecord 'edge' 'within-caps' $start7.AddMinutes(-5) @($atStart, $tickBefore)
    $rEdge = Test-CarriedCommitSize -Added @($atStart, $tickBefore) -RunStart $start7 -Records @($rEdgeRec) -Now $now7
    Test-CslCase 'AT THE BAR' 'an addition written exactly at the run''s start is own, one written a tick before is carried' ($rEdge.own.files -eq 1 -and $rEdge.own_files[0].path -eq $atStart.path -and $rEdge.carried.Count -eq 1 -and $rEdge.carried[0].files -eq 1) ("own=$($rEdge.own.files) carried=$($rEdge.carried.Count)")

    $one = New-CslAdds 'grocery/out/regular/n-2026-09-22' 1 100 $old
    $rOlder = New-CslRecord 'r-older' 'within-caps' $rec22 $one
    $rNewer = New-CslRecord 'r-newer' 'within-caps' $rec22.AddHours(1) $one
    $rNw = Test-CarriedCommitSize -Added $one -RunStart $start7 -Records @($rOlder, $rNewer) -Now $now7
    Test-CslCase 'CLEAN TWIN' 'of two within-caps records naming a path at its length, the newest carries it' ($rNw.carried.Count -eq 1 -and $rNw.carried[0].run_id -eq 'r-newer') ("carried=$(@($rNw.carried | ForEach-Object { $_.run_id }) -join ',')")

    $rUpper = New-CslRecord 'r-upper' 'WITHIN-CAPS' $rec22 $c22
    $rUp = Test-CarriedCommitSize -Added ($c22 + $own7) -RunStart $start7 -Records @($rUpper) -Now $now7
    Test-CslCase 'MUST FIRE' 'a verdict this file does not know (WITHIN-CAPS, upper case) vouches nothing, is named in the notes, and the sum refuses' ((-not $rUp.ok) -and $rUp.carried.Count -eq 0 -and $rUp.unvouched.files -eq 19 -and (($rUp.notes -join ' ') -match 'unknown verdict')) ("ok=$($rUp.ok) carried=$($rUp.carried.Count) notes=$($rUp.notes -join ';')")

    $wide = New-CslAdds 'grocery/out/regular/wide-2026-09-22' 301 0 $old
    $rWide = New-CslRecord 'r-wide' 'within-caps' $rec22 $wide
    $rWd = Test-CarriedCommitSize -Added $wide -RunStart $start7 -Records @($rWide) -Now $now7
    Test-CslCase 'MUST FIRE' 'the defence: a within-caps record whose own files are over one run''s caps (301) refuses, and the reason names the run' ((-not $rWd.ok) -and $rWd.carried.Count -eq 1 -and (($rWd.why -join ' ') -match 'r-wide')) ("ok=$($rWd.ok) why=$($rWd.why -join ';')")

    $rFut = New-CslRecord 'r-future' 'within-caps' $now7.AddSeconds(1) $c22
    $rFt = Test-CarriedCommitSize -Added $c22 -RunStart $start7 -Records @($rFut) -Now $now7
    Test-CslCase 'MUST FIRE' 'a record dated after now vouches nothing: its files are unvouched and the notes say why' ($rFt.carried.Count -eq 0 -and $rFt.unvouched.files -eq 19 -and (($rFt.notes -join ' ') -match 'after now')) ("carried=$($rFt.carried.Count) unvouched=$($rFt.unvouched.files)")

    $lines = Format-CarriedCommitSize -Result $rInc
    $lOwn = @($lines | Where-Object { $_ -like 'commit-size: own  *' }).Count
    $lCar = @($lines | Where-Object { $_ -like 'commit-size: carried *capture-run-daily-2026-09-22*' }).Count
    $lUnv = @($lines | Where-Object { $_ -like 'commit-size: unvouched *' }).Count
    $lVer = @($lines | Where-Object { $_ -like 'commit-size: own + unvouched 21 file(s)*within caps' }).Count
    Test-CslCase 'CLEAN TWIN' 'the printed lines carry one line per bucket (own, each carried run, unvouched) and the verdict over own + unvouched' ($lOwn -eq 1 -and $lCar -eq 1 -and $lUnv -eq 1 -and $lVer -eq 1) ("own=$lOwn carried=$lCar unvouched=$lUnv verdict=$lVer lines=" + ($lines -join ' | '))

    # ---- the ledger, through a temp path ----
    function New-CslLedger([string]$Name) {
      $ld = Join-Path $cslDir $Name
      $null = New-Item -ItemType Directory -Path $ld -ErrorAction Stop
      $env:TC_COMMIT_CARRY_PATH = Join-Path $ld 'tc-commit-carry.json'
      return $env:TC_COMMIT_CARRY_PATH
    }
    $L1 = New-CslLedger 'l1'
    $rd0 = Read-TcCommitCarry -Checkout 'fixture'
    Test-CslCase 'MUST NOT FIRE' 'with no ledger yet a read is ok and carries no runs' ($rd0.ok -and $rd0.runs.Count -eq 0 -and $rd0.path -eq $L1) ("ok=$($rd0.ok) runs=$($rd0.runs.Count) path=$($rd0.path) why=$($rd0.why)")

    $a1 = Add-TcCommitCarry -Run 'r1' -Kind 'daily' -Started $rec22.AddMinutes(-40) -Verdict 'within-caps' -Files $c22 -Now $rec22 -Checkout 'fixture' -TrackedBy $stub
    $rd1 = Read-TcCommitCarry -Checkout 'fixture'
    $first = [IO.File]::ReadAllBytes($L1)[0]
    $rt = if ($rd1.runs.Count -eq 1) { $rd1.runs[0] } else { $null }
    $rtV = $null; $rtB = $false
    if ($rt) { $rtB = $rt.paths.TryGetValue($c22[18].path, [ref]$rtV) }
    $rE2E = Test-CarriedCommitSize -Added ($c22 + $own7) -RunStart $start7 -Records $rd1.runs -Now $now7
    Test-CslCase 'CLEAN TWIN' 'Add then Read round-trips the run (id, kind, verdict, 19 paths at their lengths), writes no BOM, and the read runs carry the files through the judge' `
      ($a1.ok -and $rt -and $rt.run_id -eq 'r1' -and $rt.kind -eq 'daily' -and $rt.verdict -eq 'within-caps' -and $rt.paths.Count -eq 19 -and $rt.bytes -eq 18350080 -and $rtB -and $rtV -eq ($MiB / 4) -and $first -eq 0x7B -and $rE2E.ok -and $rE2E.carried.Count -eq 1 -and $rE2E.carried[0].files -eq 19) `
      ("runs=$($rd1.runs.Count) first=$first e2e=$($rE2E.ok)/$($rE2E.carried.Count) why=$($rd1.why)")

    $three = @($c22[0], $c22[1], $c22[2])
    $a1b = Add-TcCommitCarry -Run 'r1' -Kind 'daily' -Started $rec22.AddMinutes(-40) -Verdict 'within-caps' -Files $three -Now $rec22 -Checkout 'fixture' -TrackedBy $stub
    $rd1b = Read-TcCommitCarry -Checkout 'fixture'
    Test-CslCase 'CLEAN TWIN' 'Add is idempotent per run_id: a second Add of r1 replaces it, leaving one run with the second call''s 3 paths' ($a1b.replaced -eq 1 -and $rd1b.runs.Count -eq 1 -and $rd1b.runs[0].paths.Count -eq 3) ("replaced=$($a1b.replaced) runs=$($rd1b.runs.Count)")

    $L2 = New-CslLedger 'l2'
    $nP = [datetime]::new(2026, 9, 26, 12, 0, 0, [DateTimeKind]::Utc)
    [void](Add-TcCommitCarry -Run 'a72' -Kind 'ad' -Started $nP.AddHours(-73) -Verdict 'within-caps' -Files $one -Now $nP.AddSeconds(-259200) -Checkout 'fixture' -TrackedBy $stub)
    [void](Add-TcCommitCarry -Run 'a72p' -Kind 'ad' -Started $nP.AddHours(-73) -Verdict 'within-caps' -Files $one -Now $nP.AddSeconds(-259201) -Checkout 'fixture' -TrackedBy $stub)
    $aZ = Add-TcCommitCarry -Run 'z' -Kind 'daily' -Started $nP.AddHours(-1) -Verdict 'within-caps' -Files $one -Now $nP -Checkout 'fixture' -TrackedBy $stub
    $idsP = (@((Read-TcCommitCarry -Checkout 'fixture').runs | ForEach-Object { $_.run_id }) | Sort-Object) -join ','
    Test-CslCase 'AT THE BAR' 'Add keeps a run recorded exactly 72 h before now and prunes one recorded 72 h and 1 s before' ($aZ.pruned_age -eq 1 -and $idsP -eq 'a72,z') ("pruned_age=$($aZ.pruned_age) runs=$idsP")

    $L3 = New-CslLedger 'l3'
    $px = @([pscustomobject]@{ path = 'grocery/out/t/x.json'; bytes = 1 })
    $pyz = @([pscustomobject]@{ path = 'grocery/out/t/y.json'; bytes = 1 }, [pscustomobject]@{ path = 'grocery/out/t/z.json'; bytes = 1 })
    [void](Add-TcCommitCarry -Run 't1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $px -Now $rec22 -Checkout 'fixture' -TrackedBy $stub)
    [void](Add-TcCommitCarry -Run 't2' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $pyz -Now $rec22 -Checkout 'fixture' -TrackedBy $stub)
    $trackXY = { param($p) [pscustomobject]@{ ok = $true; tracked = @('grocery/out/t/x.json', 'grocery/out/t/y.json'); why = '' } }
    $aT = Add-TcCommitCarry -Run 't3' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22.AddHours(1) -Checkout 'fixture' -TrackedBy $trackXY
    $idsT = (@((Read-TcCommitCarry -Checkout 'fixture').runs | ForEach-Object { $_.run_id }) | Sort-Object) -join ','
    Test-CslCase 'MUST FIRE' 'Add prunes a run all of whose paths HEAD now tracks, and keeps a run with one path still untracked' ($aT.pruned_tracked -eq 1 -and $idsT -eq 't2,t3') ("pruned_tracked=$($aT.pruned_tracked) runs=$idsT")

    $L4 = New-CslLedger 'l4'
    $torn = '{ "schema": 1, "runs": [ { "run_'
    [IO.File]::WriteAllText($L4, $torn, $utf8)
    $rdU = Read-TcCommitCarry -Checkout 'fixture'
    $aU = Add-TcCommitCarry -Run 'u1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub
    $aside = @(Get-ChildItem -LiteralPath (Split-Path $L4 -Parent) -Filter 'tc-commit-carry.json.unreadable-*')
    $asideText = if ($aside.Count -eq 1) { [IO.File]::ReadAllText($aside[0].FullName) } else { '' }
    $rdU2 = Read-TcCommitCarry -Checkout 'fixture'
    Test-CslCase 'MUST FIRE' 'an unreadable ledger reads ok=false with no runs (today''s gate), and Add moves it aside with its bytes intact and writes a fresh one' `
      ((-not $rdU.ok) -and $rdU.runs.Count -eq 0 -and $aU.note -match 'moved aside' -and $aside.Count -eq 1 -and $asideText -eq $torn -and $rdU2.ok -and $rdU2.runs.Count -eq 1 -and $rdU2.runs[0].run_id -eq 'u1') `
      ("read_ok=$($rdU.ok) aside=$($aside.Count) note=$($aU.note) after=$($rdU2.runs.Count)")

    $h4 = Get-CslSha $L4
    $e1 = ''; $e2 = ''
    try { [void](Add-TcCommitCarry -Run 'v1' -Kind 'daily' -Started $rec22 -Verdict 'WITHIN-CAPS' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub) } catch { $e1 = $_.Exception.Message }
    try { [void](Add-TcCommitCarry -Run 'v2' -Kind 'weekly' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub) } catch { $e2 = $_.Exception.Message }
    Test-CslCase 'MUST FIRE' 'Add refuses a verdict or a kind outside its set, case-sensitively (WITHIN-CAPS, weekly), and the ledger is byte-identical after' ($e1 -ne '' -and $e2 -ne '' -and (Get-CslSha $L4) -eq $h4) ("e1='$e1' e2='$e2'")

    $L5 = New-CslLedger 'l5'
    [void](Add-TcCommitCarry -Run 'oc1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'c:\some\other\checkout' -TrackedBy $stub)
    [void](Add-TcCommitCarry -Run 'mine1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub)
    $rdC = Read-TcCommitCarry -Checkout 'fixture'
    Test-CslCase 'MUST NOT FIRE' 'a run another checkout wrote is not returned for this one, and is counted' ($rdC.runs.Count -eq 1 -and $rdC.runs[0].run_id -eq 'mine1' -and $rdC.other_checkouts -eq 1) ("runs=$($rdC.runs.Count) other=$($rdC.other_checkouts)")

    # ---- the lock, held from ANOTHER process ----
    $L6 = New-CslLedger 'l6'
    [void](Add-TcCommitCarry -Run 'k0' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub)
    $h6 = Get-CslSha $L6
    $holder = Join-Path $cslDir 'holder.ps1'
    $holderText = @'
param([string]$LockLib, [string]$Ledger, [string]$Ready, [string]$Release)
$ErrorActionPreference = 'Stop'
. $LockLib
$lk = Enter-TcLedgerLock -Path $Ledger -TimeoutMs 60000
[IO.File]::WriteAllText($Ready, [string]$PID)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Release) -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 20 }
Exit-TcLedgerLock $lk
exit 0
'@
    [IO.File]::WriteAllText($holder, $holderText, $utf8)
    $ready = Join-Path $cslDir 'held.ready'; $release = Join-Path $cslDir 'held.release'
    $hOut = Join-Path $cslDir 'holder.out'
    $lockLib = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ledger-lock.ps1'
    $hp = Start-Process -FilePath $cslExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $holder + '"'), ('"' + $lockLib + '"'), ('"' + $L6 + '"'), ('"' + $ready + '"'), ('"' + $release + '"')) -PassThru -NoNewWindow -RedirectStandardOutput $hOut -RedirectStandardError ($hOut + '.err')
    $null = $hp.Handle   # cache it now, or ExitCode reads empty once the process is gone
    $kids.Add($hp)
    $sw = [Diagnostics.Stopwatch]::StartNew()   # a hang guard, never a bar
    while (-not (Test-Path -LiteralPath $ready) -and -not $hp.HasExited -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 20 }
    $heldUp = Test-Path -LiteralPath $ready
    $eHeld = ''
    try { [void](Add-TcCommitCarry -Run 'k1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub -TimeoutMs 250) } catch { $eHeld = $_.Exception.Message }
    $rdH = Read-TcCommitCarry -Checkout 'fixture' -TimeoutMs 250
    Test-CslCase 'MUST FIRE' 'while ANOTHER process holds the ledger''s lock, Add throws naming the ledger and saying nothing was written, the file is byte-identical, and a Read degrades to ok=false' `
      ($heldUp -and $eHeld.Contains($L6) -and $eHeld -match 'NOTHING was written' -and (Get-CslSha $L6) -eq $h6 -and (-not $rdH.ok)) ("holder_ready=$heldUp error='$eHeld' read_ok=$($rdH.ok)")
    [IO.File]::WriteAllText($release, 'x')
    [void]$hp.WaitForExit(120000)
    $aK = Add-TcCommitCarry -Run 'k1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $one -Now $rec22 -Checkout 'fixture' -TrackedBy $stub -TimeoutMs 30000
    $idsK = (@((Read-TcCommitCarry -Checkout 'fixture').runs | ForEach-Object { $_.run_id }) | Sort-Object) -join ','
    Test-CslCase 'CLEAN TWIN' 'once that holder lets go, the same Add lands beside the run already there' ($aK.ok -and $idsK -eq 'k0,k1' -and $hp.ExitCode -eq 0) ("runs=$idsK holder_exit=$($hp.ExitCode)")

    # ---- four writer processes at once, released together inside Enter-TcLedgerLock ----
    $L7 = New-CslLedger 'l7'
    $writer = Join-Path $cslDir 'writer.ps1'
    $writerText = @'
param([string]$Lib, [string]$Tag, [int]$K)
$ErrorActionPreference = 'Stop'
. $Lib
$added = 0
for ($i = 1; $i -le $K; $i++) {
  try {
    $f = @([pscustomobject]@{ path = ('grocery/out/' + $Tag + '-' + $i + '.json'); bytes = 10 })
    $r = Add-TcCommitCarry -Run ($Tag + '-' + $i) -Kind 'daily' -Started ([datetime]::UtcNow) -Verdict 'within-caps' -Files $f -Checkout 'fixture' -TrackedBy { param($p) [pscustomobject]@{ ok = $true; tracked = @(); why = '' } }
    if ($r.ok) { $added++ }
  } catch { Write-Output ('WHY ' + $_.Exception.Message) }
}
Write-Output ('ADDED=' + $added)
exit 0
'@
    [IO.File]::WriteAllText($writer, $writerText, $utf8)
    $wr = Invoke-TcLedgerWriters -Script $writer -ArgSets @(@($PSCommandPath, 'w1', '5'), @($PSCommandPath, 'w2', '5'), @($PSCommandPath, 'w3', '5'), @($PSCommandPath, 'w4', '5'))
    $wRows = @($wr.writers)
    $wGood = @($wRows | Where-Object { $_.ran -and $_.exit -eq 0 -and $_.out -match 'ADDED=5' -and $_.ready_seen -eq 4 }).Count
    $idsW = @((Read-TcCommitCarry -Checkout 'fixture').runs | ForEach-Object { $_.run_id })
    $wantW = @(foreach ($w in 1..4) { foreach ($k in 1..5) { 'w' + $w + '-' + $k } })
    $landedW = @($wantW | Where-Object { $idsW -contains $_ }).Count
    Test-CslCase 'CLEAN TWIN' 'four writer processes released together (each saw 4 at the barrier), five Adds each: every one of the 20 runs lands, because the read is inside the lock' `
      ($wGood -eq 4 -and $idsW.Count -eq 20 -and $landedW -eq 20) ("good_writers=$wGood runs=$($idsW.Count) landed=$landedW trouble=" + (Format-TcWriterTrouble $wRows))

    # ---- a temp git repo: the default path, the tracked prune and the checkout key ----
    Remove-Item Env:\TC_COMMIT_CARRY_PATH -ErrorAction SilentlyContinue
    $g = Join-Path $cslDir 'g'
    $null = New-Item -ItemType Directory -Path (Join-Path $g 'grocery\out') -Force -ErrorAction Stop
    $gi = Invoke-GitCaptured -Repo $g -GitArgs @('init', '-q')
    [void](Invoke-GitCaptured -Repo $g -GitArgs @('config', 'user.email', 't@t'))
    [void](Invoke-GitCaptured -Repo $g -GitArgs @('config', 'user.name', 't'))
    [IO.File]::WriteAllText((Join-Path $g 'grocery\out\a.json'), '{}', $utf8)
    [void](Invoke-GitCaptured -Repo $g -GitArgs @('add', '--', 'grocery/out/a.json'))
    $gc = Invoke-GitCaptured -Repo $g -GitArgs @('commit', '-q', '-m', 'seed')
    $fa = @([pscustomobject]@{ path = 'grocery/out/a.json'; bytes = 2 })
    $fb = @([pscustomobject]@{ path = 'grocery/out/b.json'; bytes = 2 })
    $fc = @([pscustomobject]@{ path = 'grocery/out/c.json'; bytes = 2 })
    $g1 = Add-TcCommitCarry -Repo $g -Run 'g1' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $fa -Now $rec22
    $wantLedger = Join-Path $g '.git\tc-commit-carry.json'
    Test-CslCase 'CLEAN TWIN' 'with no override the ledger is <git common dir>\tc-commit-carry.json of the repo it is asked about' ($gi.rc -eq 0 -and $gc.rc -eq 0 -and (Test-Path -LiteralPath $wantLedger) -and [string]::Equals($g1.path, [IO.Path]::GetFullPath($wantLedger), [StringComparison]::OrdinalIgnoreCase)) ("init=$($gi.rc) commit=$($gc.rc) path=$($g1.path)")
    $g2 = Add-TcCommitCarry -Repo $g -Run 'g2' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $fb -Now $rec22.AddMinutes(1)
    $g3 = Add-TcCommitCarry -Repo $g -Run 'g3' -Kind 'daily' -Started $rec22 -Verdict 'within-caps' -Files $fc -Now $rec22.AddMinutes(2)
    Test-CslCase 'MUST FIRE' 'asking git itself, Add prunes the run whose only path HEAD tracks and keeps the one whose path is untracked' ($g2.pruned_tracked -eq 1 -and $g3.pruned_tracked -eq 0 -and $g3.kept -eq 2) ("g2_pruned=$($g2.pruned_tracked) g3_pruned=$($g3.pruned_tracked) g3_kept=$($g3.kept) note=$($g3.note)")
    $rdG = Read-TcCommitCarry -Repo $g
    $idsG = (@($rdG.runs | ForEach-Object { $_.run_id }) | Sort-Object) -join ','
    Test-CslCase 'CLEAN TWIN' 'a Read given only -Repo derives the same checkout key the Adds wrote, and returns their runs' ($rdG.ok -and $idsG -eq 'g2,g3') ("ok=$($rdG.ok) runs=$idsG other=$($rdG.other_checkouts) why=$($rdG.why)")
  } catch {
    $script:cslBad++
    Write-Output ('  FAIL  the suite threw after ' + $script:cslN + ' case(s): ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    foreach ($k in $kids) { try { if (-not $k.HasExited) { $k.Kill() } } catch { } }
    $env:TC_COMMIT_CARRY_PATH = $prevCarry
    $env:TC_EVENT_BUS = $prevBus
    Remove-Item -LiteralPath $cslDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:cslN -ne $script:cslExpected) {
    $script:cslBad++
    Write-Output ('  FAIL  the suite ran {0} case(s) and lists {1}' -f $script:cslN, $script:cslExpected)
  }
  if ($script:cslBad) {
    Write-Output ('commit-size-lib SELF-TEST FAIL ({0} failure(s) over {1} case(s))' -f $script:cslBad, $script:cslN)
    Write-Output ('COMMIT-SIZE-LIB-SELFTEST-COMPLETE cases={0} failed={1}' -f $script:cslN, $script:cslBad)
    exit 1
  }
  Write-Output ('commit-size-lib SELF-TEST PASS ({0} of {0} cases)' -f $script:cslN)
  Write-Output ('COMMIT-SIZE-LIB-SELFTEST-COMPLETE cases={0} failed=0' -f $script:cslN)
  exit 0
}
