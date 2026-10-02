<#
  audit-selftest-load-bars.ps1 - no NEW self-test asserts an upper wall-clock bar or a CPU share.

  WHY (2026-10-02, Phase 6 of design\PLAN-weekly-root-families-2026-10-02.md, queue 2026-10-01-c12baf). Rule og-36 in
  .claude\rules\ops-and-gates.md: "A hermetic self-test never asserts an UPPER wall-clock bar: the box is shared and
  load makes it red." It was judgement only, and it recurred: push ledger pushes-2026-10-01.jsonl, attempt 1 at 14:05Z,
  was refused by ops\reap-runaway-processes.ps1 rc=1 because its MUST FIRE case measured a real spinner at 48.4% of a
  core against a 50% bar. A share measured on a shared box is the box's number, not the code's. That case now runs
  through a seam with a fixed share; this holds the shape so it does not come back somewhere else.

  WHAT FIRES, inside self-test code only (lib\selftest-lib.ps1's Get-SelfTestSpans: the if-on-a-self-test-switch body,
  the code after `if (-not $SelfTest) { ...; exit }`, Invoke-<name>SelfTest, or a whole test-*.ps1), on the AST:
    cpu-share   a CPU-share measure (CoreShare, CpuShare, CpuPct, CpuPercent, LoadPercentage) compared with a numeric
                constant other than 0, in EITHER direction: load pushes a share down and a neighbour's burst pushes a
                box-wide one up. A share compared with 0 (did the counter move at all) is a lower bar load cannot cross.
    clock-upper a wall-clock measure (Elapsed, ElapsedMilliseconds, TotalMilliseconds, TotalSeconds, or a variable
                named for elapsed or duration) held UNDER a numeric constant (`$t -lt N`, `N -gt $t`, and -le / -ge)
                when N is under the hang-guard floor: 60 s, or 60000 when the measure reads milliseconds. A lower bar
                never fires, and an upper bar of 60 s or more is a generous hang guard, which og-36 keeps.
  The 60 s floor is the first plausible value, not the survivor of a sweep (og-14): the hang guards in today's suites
  run 30 s to 120 s, and the reds this exists for were bars of a few seconds or a share.

  THE DELIBERATE EXCEPTION: a line carrying `# load-bar:allow <reason>`. A marker with no reason exempts nothing.

  A RATCHET, NOT A GATE AT ZERO (og-11): the tree held sites the day this landed. ops\selftest-load-bars-baseline.json
  names them by file, kind and text (never the line); a site the baseline does not name fails even at an unchanged
  count, a fall is SPOKEN and the mark kept, -Tighten records a believable fall through lib\ratchet.ps1.

  SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. It knows the measure names above; a share or a
  clock held in a variable named otherwise, a bar held in a variable rather than a constant, a poll whose DEADLINE is
  the bar (a while or do condition is skipped, since a loop condition is not an assertion), and a self-test the
  census cannot see, are all outside it. It is COMPLETE for what it names: the match is the comparison itself, so a
  finding is a real bar of that kind, though one the author may have made safe some other way (mark it).

  Exit (lib\guard-contract.ps1): 0 at or under the baseline; 2 a site the baseline does not name, or -Tighten refused
  an implausible fall; 3 could not evaluate (no files resolved, or no readable baseline). Last line
  AUDIT-SELFTEST-LOAD-BARS-COMPLETE files=N ... Self-test: -SelfTest.
    .\audit-selftest-load-bars.ps1            measure and ratchet; writes nothing
    .\audit-selftest-load-bars.ps1 -Tighten   also record a believable fall (or the first baseline)
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Tighten, [switch]$AcceptDrop, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestSpans: where self-test code lives, the census's own rule

$script:SLB_GUARD = 'audit-selftest-load-bars'
$script:SLB_EXCLUDE = '\\(\.claude\\worktrees|archive|node_modules|\.git)\\'
$script:SLB_SHARE_RX = '(?i)(Core_?Share|Cpu_?Share|Cpu_?Pct|Cpu_?Percent|LoadPercentage)'
$script:SLB_CLOCK_RX = '(?i)(Elapsed|TotalMilliseconds|TotalSeconds|\$\w*(duration|wallclock)\w*)'
$script:SLB_PREFILTER = '(?i)(Core_?Share|Cpu_?Share|Cpu_?Pct|Cpu_?Percent|LoadPercentage|Elapsed|TotalMilliseconds|TotalSeconds|duration|wallclock)'
$script:SLB_HANG_GUARD_S = 60

function Get-SlbConstant($Ast) {
  # The numeric value of a constant operand, or $null. A unary minus on a constant is still a constant.
  if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst] -and
      ($Ast.Value -is [int] -or $Ast.Value -is [long] -or $Ast.Value -is [double] -or $Ast.Value -is [decimal])) { return [double]$Ast.Value }
  if ($Ast -is [System.Management.Automation.Language.UnaryExpressionAst] -and
      $Ast.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) {
    $v = Get-SlbConstant $Ast.Child
    if ($null -ne $v) { return -$v }
  }
  return $null
}

function Test-SlbInLoopCondition($Node) {
  # A while/do/for CONDITION is a poll deadline, not an assertion (stated outside the scope in the header).
  $p = $Node.Parent
  while ($null -ne $p) {
    if ($p -is [System.Management.Automation.Language.LoopStatementAst] -and $null -ne $p.Condition) {
      $c = $p.Condition.Extent
      if ($Node.Extent.StartOffset -ge $c.StartOffset -and $Node.Extent.EndOffset -le $c.EndOffset) { return $true }
    }
    $p = $p.Parent
  }
  return $false
}

function Get-SlbFindings {
  <# Pure. The load bars in one file's self-test code. Returns @{ Read; Candidates; Findings = @(@{ Line; Kind; Text }) }.
     Read is $false when the file names no measure at all (the prefilter) or does not parse. Candidates counts the bars
     found ANYWHERE in the file before the self-test scope is applied.
     THE SCOPE IS ASKED LAST, AND ONLY OF A FILE WITH A CANDIDATE (2026-10-02): Get-SelfTestSpans cost 12.8 s over the
     87 files the prefilter keeps, against 0.4 s to parse them; a file with no candidate bar needs no answer. #>
  param([string]$Source, [string]$Path = '')
  $none = [pscustomobject]@{ Read = $false; Candidates = 0; Findings = @() }
  if ($Source -notmatch $script:SLB_PREFILTER) { return $none }
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { return $none }
  $lines = $Source -split "`n"
  $K = [System.Management.Automation.Language.TokenKind]
  $less = @($K::Ilt, $K::Ile, $K::Clt, $K::Cle)
  $more = @($K::Igt, $K::Ige, $K::Cgt, $K::Cge)
  $cand = New-Object System.Collections.Generic.List[object]
  $bins = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
  foreach ($b in $bins) {
    $isLess = $less -contains $b.Operator; $isMore = $more -contains $b.Operator
    if (-not ($isLess -or $isMore)) { continue }
    $lc = Get-SlbConstant $b.Left; $rc = Get-SlbConstant $b.Right
    if (($null -eq $lc) -eq ($null -eq $rc)) { continue }   # exactly one side must be a constant
    $measure = if ($null -eq $rc) { $b.Right } else { $b.Left }
    $bar = if ($null -eq $rc) { $lc } else { $rc }
    $mText = $measure.Extent.Text
    $kind = ''
    if ($mText -match $script:SLB_SHARE_RX) {
      if ($bar -ne 0) { $kind = 'cpu-share' }
    } elseif ($mText -match $script:SLB_CLOCK_RX) {
      # measure on the LEFT of -lt/-le, or on the RIGHT of -gt/-ge, is held UNDER the bar
      $upper = (($null -ne $rc) -and $isLess) -or (($null -ne $lc) -and $isMore)
      $floor = if ($mText -match '(?i)(Milliseconds|ms\b)') { $script:SLB_HANG_GUARD_S * 1000 } else { $script:SLB_HANG_GUARD_S }
      if ($upper -and $bar -lt $floor) { $kind = 'clock-upper' }
    }
    if (-not $kind) { continue }
    if (Test-SlbInLoopCondition $b) { continue }
    $ln = $b.Extent.StartLineNumber
    if ($lines[$ln - 1] -match '#[^\n]*load-bar:allow\s+\S') { continue }
    $cand.Add([pscustomobject]@{ Off = $b.Extent.StartOffset; Line = $ln; Kind = $kind; Text = (($b.Extent.Text -replace '\s+', ' ').Trim()) })
  }
  $out = New-Object System.Collections.Generic.List[object]
  if ($cand.Count) {
    $spans = Get-SelfTestSpans -Text $Source -Path $Path
    $spans = @($spans)
    foreach ($c in $cand) {
      foreach ($s in $spans) {
        if ($c.Off -ge $s.S -and $c.Off -lt $s.E) { $out.Add([pscustomobject]@{ Line = $c.Line; Kind = $c.Kind; Text = $c.Text }); break }
      }
    }
  }
  return [pscustomobject]@{ Read = $true; Candidates = $cand.Count; Findings = $out.ToArray() }
}

function Get-SlbSiteKey([string]$Rel, $Finding) { return ('{0} :: {1} :: {2}' -f $Rel, $Finding.Kind, $Finding.Text) }

function Get-SlbScanFiles {
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  $walk = @(Get-TcTreeFiles -RootFull $rootFull -Filter '*.ps1' -PruneBelow $script:SLB_EXCLUDE)
  return ,@($walk | Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:SLB_EXCLUDE -and
    -not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object FullName)
}

function Write-SlbBaseline {
  param([string]$Path, [int]$Count, [string[]]$Names, $PriorDoc)
  $doc = if ($null -ne $PriorDoc) { $PriorDoc } else { [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $Count
  $body = [ordered]@{
    note      = 'HIGH-WATER MARK for self-test assertions of an upper wall-clock bar or a CPU share (ops\audit-selftest-load-bars.ps1, rule og-36, queue 2026-10-01-c12baf). It may only go DOWN; a fall is recorded only by -Tighten, and a fall to zero or over 60% in one run needs -AcceptDrop (lib\ratchet.ps1).'
    generated = (Get-Date).ToString('s')
    sites     = $Count
    names     = @($Names | Sort-Object)
    history   = $hist
  }
  return (Write-TcLfFile -Path $Path -Text ($body | ConvertTo-Json -Depth 5) -NoBom)
}

# ----------------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function SlbT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function SlbIn([string]$body) { return ('param([switch]$SelfTest)' + "`n" + 'if ($SelfTest) {' + "`n" + $body + "`n" + '}' + "`n") }
  function SlbKinds([string]$src, [string]$path = 'ops\x.ps1') { $r = Get-SlbFindings -Source $src -Path $path; return (@($r.Findings | ForEach-Object { $_.Kind }) -join ',') }
  try {
    # Needles by concatenation, so no measure name appears whole in this file's own fixtures (og-03).
    $share = 'Core' + 'SharePct'; $tms = 'Elapsed' + 'Milliseconds'; $ts = 'Elapsed.Total' + 'Seconds'
    $founding = SlbIn ('  _T ''MUST FIRE the sampler measures the spinner at 50% or more of one core'' ($rec.Count -eq 1 -and $rec[0].' + $share + ' -ge 50) "share"')
    $k = SlbKinds $founding
    SlbT 'MUST FIRE  the c12baf reaper case: a real spinner''s share held at 50% or more' ($k -eq 'cpu-share') $k
    $k = SlbKinds (SlbIn ('  T ''fast'' ($sw.' + $tms + ' -lt 500)'))
    SlbT 'MUST FIRE  an upper wall-clock bar of 500 ms' ($k -eq 'clock-upper') $k
    $k = SlbKinds (SlbIn ('  T ''fast'' (2 -gt $sw.' + $ts + ')'))
    SlbT 'MUST FIRE  the same bar written constant-first (2 -gt elapsed seconds)' ($k -eq 'clock-upper') $k
    $k = SlbKinds (SlbIn ('  T ''box busy'' ((Get-CimInstance Win32_Processor).Load' + 'Percentage -lt 90)'))
    SlbT 'MUST FIRE  a box-wide load share held under a bar, the other direction' ($k -eq 'cpu-share') $k
    $k = SlbKinds (SlbIn ('  T ''lingered'' ($sw.' + $ts + ' -ge 3)'))
    SlbT 'MUST NOT FIRE  a LOWER wall-clock bar, which load can only help' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''no hang'' ($sw.' + $ts + ' -lt 600)'))
    SlbT 'MUST NOT FIRE  a generous hang guard of 600 s' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''at'' ($sw.' + $ts + ' -lt 60)'))
    SlbT 'MUST NOT FIRE  AT THE BAR: an upper bound of exactly 60 s is a hang guard' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''past'' ($sw.' + $ts + ' -lt 59)'))
    SlbT 'MUST FIRE  ONE STEP PAST THE BAR: 59 s (one second, the constant''s resolution) is a bar' ($k -eq 'clock-upper') $k
    $k = SlbKinds (SlbIn ('  T ''at ms'' ($sw.' + $tms + ' -lt 60000)'))
    SlbT 'MUST NOT FIRE  AT THE BAR in milliseconds: 60000 ms reads in its own unit' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''past ms'' ($sw.' + $tms + ' -lt 59999)'))
    SlbT 'MUST FIRE  ONE STEP PAST in milliseconds: 59999 ms' ($k -eq 'clock-upper') $k
    $k = SlbKinds (SlbIn ('  T ''moved'' ($rec.' + $share + ' -gt 0)'))
    SlbT 'MUST NOT FIRE  a share compared with 0 (the counter moved), a lower bar load cannot cross' ($k -eq '') $k
    $k = SlbKinds ('function Get-Verdict { if ($p.' + $share + ' -ge 50) { ''reap'' } }' + "`n" + (SlbIn '  $x = 1'))
    SlbT 'MUST NOT FIRE  the same comparison in PRODUCTION code outside the self-test' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  while ($sw.' + $tms + ' -lt 5000) { Start-Sleep -Milliseconds 20 }'))
    SlbT 'MUST NOT FIRE  a while condition (a poll deadline, stated outside the scope)' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''fast'' ($sw.' + $tms + ' -lt 500)   # load-bar:allow measured on an idle CI box only'))
    SlbT 'MUST NOT FIRE  a marked line with a reason' ($k -eq '') $k
    $k = SlbKinds (SlbIn ('  T ''fast'' ($sw.' + $tms + ' -lt 500)   # load-bar:allow'))
    SlbT 'MUST FIRE  a marker with no reason exempts nothing' ($k -eq 'clock-upper') $k
    $k = SlbKinds (SlbIn ('  # ($sw.' + $tms + ' -lt 500) was the old bar' + "`n" + '  $s = ''$x.' + $share + ' -ge 50'''))
    SlbT 'MUST NOT FIRE  a comment and a string that spell a bar' ($k -eq '') $k
    $k = SlbKinds ('$sw = 1' + "`n" + 'if (($sw.' + $tms + ') -lt 500) { ''FAIL'' }') 'grocery\test-thing.ps1'
    SlbT 'CLEAN TWIN  a whole test-*.ps1 file is self-test code, so its bar fires with no switch' ($k -eq 'clock-upper') $k
    $r = Get-SlbFindings -Source ('$x = 1') -Path 'ops\x.ps1'
    SlbT 'CLEAN TWIN  a file that names no measure is not read (the prefilter), so the run can count what it read' (-not $r.Read) ([string]$r.Read)

    # ---- THE WALK FROM A WORKTREE ROOT (lib\tree-walk.ps1) ----------------------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'ops\fx-a.ps1' = $founding; 'archive\fx-old.ps1' = $founding; 'ops\fx-self.ps1' = $founding }
    try {
      $selfFx = Join-Path $wtFx.Root 'ops\fx-self.ps1'
      $found = Get-SlbScanFiles -RootDir $wtFx.Root -Self $selfFx
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      SlbT 'MUST FIRE  a root that IS a worktree is walked (one file below it: not archive\ and not the detector)' ($hits.Root -eq 1) ('root=' + $hits.Root)
      SlbT 'MUST NOT FIRE  the sibling worktree below that root is not counted' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

    # ---- THE LIVE PATH AND THE RATCHET, as a child against a temp tree and temp baselines ---------------------------
    $tmp = Join-Path $env:TEMP ('slb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'tree\ops') -Force -ErrorAction Stop | Out-Null
    try {
      $tree = Join-Path $tmp 'tree'
      [IO.File]::WriteAllText((Join-Path $tree 'ops\site.ps1'), $founding, (New-Object Text.UTF8Encoding($false)))
      $liveKey = Get-SlbSiteKey 'ops\site.ps1' (Get-SlbFindings -Source $founding -Path 'ops\site.ps1').Findings[0]
      $psexe = Join-Path $PSHOME 'powershell.exe'
      function SlbSeed([string]$P, [int]$N, [string[]]$Names) {
        $null = Write-TcLfFile -Path $P -Text ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; sites = $N; names = @($Names); history = @() } | ConvertTo-Json -Depth 4) -NoBom
      }
      function SlbChild([string]$TreeRoot, [string[]]$Extra) {
        $o = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $TreeRoot @Extra)
        $rc = $LASTEXITCODE
        $o = @($o | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Rc = $rc; Out = $o; Last = $(if ($o.Count) { $o[$o.Count - 1] } else { '' }) }
      }
      $blAt = Join-Path $tmp 'at.json'; SlbSeed $blAt 1 @($liveKey)
      $c0 = SlbChild $tree @('-BaselineFile', $blAt)
      SlbT 'MUST NOT FIRE  AT THE MARK (1 site, baseline 1, the same site named): exit 0, completion marker last' ($c0.Rc -eq 0 -and $c0.Last -like 'AUDIT-SELFTEST-LOAD-BARS-COMPLETE files=1 *') ("rc={0} last={1}" -f $c0.Rc, $c0.Last)
      $blPast = Join-Path $tmp 'past.json'; SlbSeed $blPast 0 @()
      $c1 = SlbChild $tree @('-BaselineFile', $blPast)
      SlbT 'MUST FIRE  ONE PAST THE MARK (1 site, baseline 0): exit 2, the site named' ($c1.Rc -eq 2 -and (($c1.Out -join "`n") -like '*NEW  ops\site.ps1 :: cpu-share*')) ("rc=" + $c1.Rc)
      $blSwap = Join-Path $tmp 'swap.json'; SlbSeed $blSwap 1 @('ops\other.ps1 :: clock-upper :: ($sw.x -lt 5)')
      $c2 = SlbChild $tree @('-BaselineFile', $blSwap)
      SlbT 'MUST FIRE  a new site at an UNCHANGED count exits 2' ($c2.Rc -eq 2) ("rc=" + $c2.Rc)
      $blFall = Join-Path $tmp 'fall.json'; SlbSeed $blFall 2 @($liveKey, 'ops\gone.ps1 :: clock-upper :: ($sw.x -lt 5)')
      $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall))
      $c3 = SlbChild $tree @('-BaselineFile', $blFall)
      $same = [string]::Equals($before, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall)), [StringComparison]::Ordinal)
      SlbT 'CLEAN TWIN  a FALL without -Tighten passes, is spoken, and leaves the baseline bytes as they were' ($c3.Rc -eq 0 -and $same -and (($c3.Out -join "`n") -match 'CAN tighten')) ("rc={0} same={1}" -f $c3.Rc, $same)
      $c4 = SlbChild $tree @('-BaselineFile', $blFall, '-Tighten')
      $b4 = [IO.File]::ReadAllBytes($blFall); $cr = 0; foreach ($x in $b4) { if ($x -eq 13) { $cr++ } }
      $doc4 = [Text.Encoding]::UTF8.GetString($b4) | ConvertFrom-Json
      SlbT 'CLEAN TWIN  -Tighten records the fall in LF bytes: sites 1, the live site named' ($c4.Rc -eq 0 -and $cr -eq 0 -and $b4[-1] -eq 10 -and [int]$doc4.sites -eq 1 -and @($doc4.names)[0] -eq $liveKey) ("rc={0} cr={1} sites={2}" -f $c4.Rc, $cr, $doc4.sites)
      $c5 = SlbChild $tree @('-BaselineFile', (Join-Path $tmp 'absent.json'))
      SlbT 'MUST FIRE  no baseline and no -Tighten is could-not-evaluate, exit 3, and writes nothing' ($c5.Rc -eq 3 -and -not (Test-Path -LiteralPath (Join-Path $tmp 'absent.json'))) ("rc=" + $c5.Rc)
      $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Path $empty -ErrorAction Stop | Out-Null
      $c6 = SlbChild $empty @('-BaselineFile', $blAt)
      SlbT 'MUST FIRE  a walk that resolves zero .ps1 is BLIND, exit 3, files=0 on the marker' ($c6.Rc -eq 3 -and $c6.Last -like '*files=0*') ("rc={0} last={1}" -f $c6.Rc, $c6.Last)
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  }
  $expected = 27
  if ($script:cases -ne $expected) { Write-Output ("  FAIL  ran {0} case(s), the list holds {1}" -f $script:cases, $expected); $script:fail++ }
  if ($script:fail) { Write-Output ("audit-selftest-load-bars self-test FAIL ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 2 }
  Write-Output ("audit-selftest-load-bars self-test PASS ({0} case(s))" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------------------ live run
$scanRoot = if ($Root) { $Root } else { $repo }
$blPath = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'ops\selftest-load-bars-baseline.json' }
$files = Get-SlbScanFiles -RootDir $scanRoot -Self $PSCommandPath
if (-not $files.Count) {
  Write-Output 'SELFTEST-LOAD-BARS AUDIT BLIND: resolved zero .ps1 files, which is the walk broken, not the tree clean.'
  Exit-Guard -Name $script:SLB_GUARD -Summary 'files=0 blind=no-files' -Code 3
}
$rootFull = Get-TcRootFull $scanRoot
$keys = New-Object System.Collections.ArrayList
$read = 0; $candidates = 0
foreach ($f in $files) {
  $r = Get-SlbFindings -Source ([IO.File]::ReadAllText($f.FullName)) -Path $f.Name
  if (-not $r.Read) { continue }
  $read++
  $candidates += $r.Candidates
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in @($r.Findings)) {
    [void]$keys.Add((Get-SlbSiteKey $rel $h))
    Write-Output ("  load-bar  {0}:{1}  {2}  {3}" -f $rel, $h.Line, $h.Kind, $h.Text)
  }
}
$count = $keys.Count
$summary = "files={0} read={1} candidates={2} sites={3}" -f $files.Count, $read, $candidates, $count
Write-Output ("selftest-load-bars: resolved {0} .ps1 file(s); {1} name a clock or share measure and parsed; {2} comparison(s) of that shape anywhere in them, {3} inside self-test code." -f $files.Count, $read, $candidates, $count)

if (-not (Test-Path -LiteralPath $blPath)) {
  if ($Tighten) {
    $null = Write-SlbBaseline -Path $blPath -Count $count -Names $keys.ToArray() -PriorDoc $null
    Write-Output ("selftest-load-bars: baseline written at {0} site(s) - commit it. From here the number may only go DOWN." -f $count)
    Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} baseline-written={1}" -f $summary, $count) -Code 0
  }
  Write-Output ("SELFTEST-LOAD-BARS AUDIT CANNOT EVALUATE: no baseline at {0}. Run with -Tighten once and commit it; a missing baseline is never a pass." -f $blPath)
  Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} blind=baseline-missing" -f $summary) -Code 3
}
$bl = Read-TcRatchetBaseline -Path $blPath -Field 'sites'
if ($bl.State -ne 'read') {
  Write-Output ("SELFTEST-LOAD-BARS AUDIT CANNOT EVALUATE: the baseline at {0} is unreadable: {1}." -f $blPath, $bl.Why)
  Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} blind={1}" -f $summary, (Get-TcRatchetBlindToken $bl.State)) -Code 3
}
$base = $bl.Value
$knownNames = @()
if ($bl.Doc.PSObject.Properties['names'] -and $null -ne $bl.Doc.names) { $knownNames = @($bl.Doc.names) }
$cmp = Compare-TcRatchetSites -Current $keys.ToArray() -Baseline $knownNames
if ($count -gt $base -or @($cmp.New).Count) {
  Write-Output ("SELFTEST-LOAD-BARS AUDIT FAILED: {0} site(s) against a baseline of {1}, and {2} the baseline does not name:" -f $count, $base, @($cmp.New).Count)
  foreach ($k in @($cmp.New)) { Write-Output ('  NEW  ' + $k) }
  Write-Output '  A self-test runs on a shared box under a 24-wide gate pool, so a share or a short upper clock bar is the BOX''s'
  Write-Output '  number. Drive the share through a seam with a fixed value, prove concurrency by overlap (lib\concurrency-probe.ps1),'
  Write-Output '  or hold the subject on a condition the test controls; keep a clock only as a lower bar or a hang guard of 60 s or more.'
  Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} baseline={1} new={2}" -f $summary, $base, @($cmp.New).Count) -Code 2
}
if ($count -lt $base) {
  foreach ($k in @($cmp.Gone)) { Write-Output ('  gone  ' + $k) }
  $move = Test-RatchetMove -Name 'selftest-load-bars' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
  if ($move.Verdict -eq 'implausible') {
    Write-Output ('  ' + $move.Message)
    if ($Tighten) { Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} baseline={1} refused-to-lower" -f $summary, $base) -Code 2 }
  } elseif ($Tighten) {
    $null = Write-SlbBaseline -Path $blPath -Count $count -Names $keys.ToArray() -PriorDoc $bl.Doc
    Write-Output ('PASSED and TIGHTENED - ' + $move.Message + ' Commit the baseline, or it protects only this checkout.')
    Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} tightened-from={1}" -f $summary, $base) -Code 0
  } else {
    Write-Output ("  ratchet CAN tighten: {0} site(s), baseline {1}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit the baseline." -f $count, $base)
  }
}
Write-Output ("selftest-load-bars: PASSED - {0} known site(s) against a baseline of {1}." -f $count, $base)
Exit-Guard -Name $script:SLB_GUARD -Summary ("{0} baseline={1}" -f $summary, $base) -Code 0
