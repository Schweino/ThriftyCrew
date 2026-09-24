<#
  ratchet.ps1 - a high-water baseline may only go DOWN, and a drop to nothing is a broken detector.

  WHY THIS EXISTS (2026-09-07, backlog I15). Four audits here carry a high-water mark that "may only
  go DOWN", and every one of them lowered it UNCONDITIONALLY:

      if ($count -lt $base) { write the new, lower baseline }

  That is correct for a real migration and catastrophic for a broken detector. A regex that stops
  matching, a path that moved, a tree that is empty inside a worktree - any of these makes a detector
  find NOTHING, and the ratchet then records 0 as the new permanent ceiling, prints "PASSED and
  TIGHTENED", and can never rise again. The gate goes green forever on a detector that died, and the
  findings it used to catch become invisible rather than loud. audit-mustfire-census sits at 653; the
  same failure there would record "tightened" while every must-fire assertion in the estate had
  vanished.

  THE ASYMMETRY IS THE WHOLE POINT. A count that ROSE is a new finding and the detector is working. A
  count that FELL is either good news or the detector is broken, and those two look identical from
  outside - which is the same shape as guard-contract.ps1's "no findings" versus "died halfway", and
  the same shape backlog I15 describes when it says an audit that stops firing looks like one that
  passes. So a fall has to clear a plausibility bar before it is believed.

  TWO REFUSALS, and neither is a hard failure - the caller keeps its old baseline and says so:
    * COUNT ZERO while the baseline was not. Extraordinary claims. Migrating every last finding in one
      run happens; a detector breaking happens far more often, and only one of the two is reversible
      after the baseline is overwritten.
    * A DROP LARGER THAN -MaxDropPct in a single run. Same argument, weaker evidence.
  -AcceptDrop records it anyway, and exists so a genuine bulk migration is one flag rather than a
  hand-edited baseline file.

  A COUNT IS NOT A NAME (2026-09-23, W6.9 step 3). A count ratchet admits a NEW defect into the slack a fixed one
  left: a fix and a new site in one change hold the count, and Test-RatchetMove reads 'held'. Compare-TcRatchetSites
  is the named comparison, multisets keyed on the path below the root plus the site's normalised text. It was lifted
  from the two copies that existed (grocery\test-native-stderr-eap.ps1, ops\audit-typed-param-shadow.ps1), and both
  call it now, so there is one copy rather than three.

  THE SAME ASYMMETRY ONE LEVEL DOWN: A DETECTOR THAT READ NOTHING (2026-09-23, W6.9 of
  design\PLAN-brain-consults-on-code-and-analysis-2026-09-22.md). A ratchet's count is findings; a static detector's
  COMPLETE marker also says how much it READ, as scanned=, files=, examined= or resolved=. When that is 0 and the exit
  is 0, the detector did not look, and "found nothing" is the same bytes as "looked at nothing".
  ops\audit-readjson-inline-wrap.ps1 did exactly that from every worktree for two days, and run-gates scored each run
  ok. Get-TcStaticZeroScan reads the marker; run-gates scores such a gate 3 (blind=static-scanned-zero), never ok.

  IT ALSO KEEPS HISTORY, which is I15's actual ask. A single number cannot show a detection RATE, and
  a change in alert volume is one tripwire for several unrelated causes at once - real behaviour
  change, drift, a data-quality problem, a threshold edit, or the detector degrading. The history says
  something moved; it does not say which, and that is still worth having.

  A MARK NOBODY CAN READ IS NOT A MARK (2026-09-24, design\backlog-inbox\pd-currency-2026-09-23.md). Eleven ratchets
  read their baseline inside a try whose catch set it to $null, then wrote the CURRENT count as the mark whenever it was
  $null, so a baseline left holding conflict markers by a botched rebase, or deleted, silently accepted whatever count
  the push carried, a rise included, and exited 0. W1.2 fixed ops\audit-conclusion-currency.ps1 alone (Read-CcBaseline).
  Read-TcRatchetBaseline is that rule once, for the rest: ABSENT, UNREADABLE and READ are three answers, the caller
  exits 3 on the first two (Get-TcRatchetBlindToken names which) and writes nothing, and only its -Accept writes a mark.

  Dot-source:  . (Join-Path $repoRoot 'lib\ratchet.ps1')
  Self-test:   powershell -File lib\ratchet.ps1 -SelfTest

  THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the trap guard-contract.ps1 documents. In PS 5.1
  dot-sourcing runs a param() block in the CALLER's scope, so a param([switch]$SelfTest) here would
  reset every caller's own -SelfTest to $false on the line after it bound.
#>
# USE WHEN: a detector keeps a high-water mark that may only fall, compares today's named sites with its baseline's, or must tell a static scan that read nothing from a clean one
# REPLACES: if\s*\(\s*\$\w+\s+-lt\s+\$\w+\s*\)\s*\{(?![^}]*Test-RatchetMove)[^}]*\b(?:Set-Content|Out-File|WriteAllText|Write-TcLfFile)\b ;; (?:Where-Object|\?)\s*\{\s*\$\w*(?:[Bb]ase|[Kk]nown)\w*\s+-notcontains\s+\$_\b
# REPLACES-FIRE: if ($count -lt $base) { $doc.sites = $count; $doc | ConvertTo-Json | Set-Content $blPath }
# REPLACES-FIRE: if ($n -lt $baseline) { [IO.File]::WriteAllText($bl, ($n | ConvertTo-Json)) }
# REPLACES-FIRE: $new = @($keys | Where-Object { $baseKeys -notcontains $_ })
# REPLACES-FIRE: $fresh = @($names | ? { $knownNames -notcontains $_ })
# REPLACES-SILENT: if ($count -lt $base) { $move = Test-RatchetMove -Name 'x' -Count $count -Baseline $base; if ($move.Verdict -eq 'tightened') { $null = Write-TcLfFile -Path $bl -Text $t } }
# REPLACES-SILENT: if ($count -lt $base) { foreach ($k in @($cmp.Gone)) { Write-Output ('  gone  ' + $k) } }
# REPLACES-SILENT: $cmp = Compare-TcRatchetSites -Current $keys -Baseline $baseKeys
# REPLACES-SILENT: if ($base -notcontains $cl) { $base += $cl }
# REPLACES-SILENT: $extra = @($names | Where-Object { $allow -notcontains $_ })
# ENFORCED BY: ops/audit-one-way-actuators.ps1 (none)
$__ratchetSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Read-TcRatchetBaseline {
  <# A ratchet's baseline as @{ State = read | absent | unreadable; Value; Doc; Why }. READ only when the file parses as
     a JSON object whose -Field is a non-negative integer. No file is ABSENT. Anything else is UNREADABLE with its
     reason: conflict markers, a JSON array or scalar, a missing field, a quoted "4", a fraction. The caller refuses both
     non-read states unless it was asked to record a mark. Never throws. #>
  param([string]$Path, [string]$Field)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ State = 'absent'; Value = $null; Doc = $null; Why = 'no such file' } }
  $doc = $null
  try { $doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return @{ State = 'unreadable'; Value = $null; Doc = $null; Why = 'it does not parse as JSON' } }
  if ($null -eq $doc -or $doc -is [array] -or $doc -is [string] -or $doc -is [ValueType]) { return @{ State = 'unreadable'; Value = $null; Doc = $null; Why = 'it is not a JSON object' } }
  $prop = $doc.PSObject.Properties[$Field]
  if (-not $prop) { return @{ State = 'unreadable'; Value = $null; Doc = $doc; Why = ('it has no ' + $Field + ' field') } }
  $v = $prop.Value
  if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 0 -or $v -gt [int]::MaxValue) {
    return @{ State = 'unreadable'; Value = $null; Doc = $doc; Why = ('its ' + $Field + ' field is not a non-negative integer: ' + [string]$v) }
  }
  return @{ State = 'read'; Value = [int]$v; Doc = $doc; Why = '' }
}

function Get-TcRatchetBlindToken([string]$State) {
  <# The blind= token for a baseline that was not READ, the same words audit-conclusion-currency prints. #>
  switch -CaseSensitive ($State) {
    'absent'     { return 'baseline-missing' }
    'unreadable' { return 'baseline-unreadable' }
    default      { throw ('Get-TcRatchetBlindToken: a baseline in state ''' + $State + ''' was read and is not blind') }
  }
}

function Test-RatchetMove {
  <# What this run's count means against the stored baseline.

     Returns @{ Verdict; Message; NewBaseline }. Verdict is one of:
       rose        - a NEW finding; the caller hard-fails
       held        - unchanged; pass
       tightened   - a believable fall; the caller lowers the baseline
       implausible - a fall too large or too complete to believe; the caller KEEPS the old baseline
                     and reports, because overwriting it is the irreversible half #>
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$Count,
    [Parameter(Mandatory=$true)][int]$Baseline,
    [double]$MaxDropPct = 60.0,
    [switch]$AcceptDrop
  )
  if ($Count -gt $Baseline) {
    return [pscustomobject]@{ Verdict = 'rose'; NewBaseline = $Baseline
      Message = ("{0}: {1} finding(s), ABOVE the baseline of {2}. This is a NEW one." -f $Name, $Count, $Baseline) }
  }
  if ($Count -eq $Baseline) {
    return [pscustomobject]@{ Verdict = 'held'; NewBaseline = $Baseline
      Message = ("{0}: {1} known finding(s), unchanged from the baseline." -f $Name, $Count) }
  }

  # From here the count FELL, which is the direction that cannot be trusted on its own.
  if (-not $AcceptDrop) {
    if ($Baseline -gt 0 -and $Count -eq 0) {
      return [pscustomobject]@{ Verdict = 'implausible'; NewBaseline = $Baseline
        Message = ("{0}: found NOTHING where the baseline is {1}. A detector that suddenly finds nothing is broken until proven otherwise, so the baseline is KEPT rather than rewritten to 0 - lowering it would lock the blindness in permanently and print a pass forever. Check the detector actually ran and still matches, then re-run with -AcceptDrop if the migration is real." -f $Name, $Baseline) }
    }
    if ($Baseline -gt 0) {
      $dropPct = 100.0 * ($Baseline - $Count) / $Baseline
      if ($dropPct -gt $MaxDropPct) {
        return [pscustomobject]@{ Verdict = 'implausible'; NewBaseline = $Baseline
          Message = ("{0}: {1} finding(s) against a baseline of {2}, a {3}% fall in one run, over the {4}% that reads as a real migration rather than a detector that stopped seeing things. Baseline KEPT. Re-run with -AcceptDrop if the fall is genuine." -f $Name, $Count, $Baseline, [math]::Round($dropPct, 1), $MaxDropPct) }
      }
    }
  }
  return [pscustomobject]@{ Verdict = 'tightened'; NewBaseline = $Count
    Message = ("{0}: {1} finding(s), down from {2}. Baseline lowered; it can never rise again." -f $Name, $Count, $Baseline) }
}

function Compare-TcRatchetSites {
  <# NAMES AGAINST THE BASELINE, NEVER ONLY A COUNT (2026-09-23, W6.9 step 3). A fix and a new site in one change hold
     the count, and Test-RatchetMove reads that as 'held'; this calls the new one new. Lifted from the two copies that
     existed, grocery\test-native-stderr-eap.ps1's Compare-TcSiteBaseline and ops\audit-typed-param-shadow.ps1's
     Compare-TpsSites, which both call this now, so there is one.

     THE KEY IS THE CALLER'S, and its contract is: the path BELOW the root (Get-TcPathBelowRoot, so a run from a worktree
     and a run from the main checkout build identical keys) plus the site's whitespace-normalised text, and NEVER its
     line number, so an edit above a known site does not move it. A rename inside a known bad line is then one gone plus
     one new, a red on a refactor: read the line, then re-record through the caller's own road (-Accept in
     test-native-stderr-eap). audit-typed-param-shadow has no same-count road yet; stated, not built here.

     MULTISETS, compared ORDINALLY: a second copy of a known site is new, and a case change is not waved through as the
     same site (a bare @{} is case-insensitive). Returns Verdict 'rose' | 'fell' | 'held', New (one entry per occurrence
     above the baseline, in Current's order) and Gone (one per occurrence below it, in Baseline's order). #>
  param([string[]]$Current, [string[]]$Baseline)
  $left = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
  foreach ($k in @($Baseline)) { if ($null -eq $k) { continue }; if ($left.ContainsKey($k)) { $left[$k] = $left[$k] + 1 } else { $left[$k] = 1 } }
  $new = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($Current)) {
    if ($null -eq $k) { continue }
    if ($left.ContainsKey($k) -and $left[$k] -gt 0) { $left[$k] = $left[$k] - 1 } else { $new.Add($k) }
  }
  $gone = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($Baseline)) {
    if ($null -eq $k) { continue }
    if ($left[$k] -gt 0) { $gone.Add($k); $left[$k] = $left[$k] - 1 }
  }
  $verdict = if ($new.Count) { 'rose' } elseif ($gone.Count) { 'fell' } else { 'held' }
  return [pscustomobject]@{ Verdict = $verdict; New = $new.ToArray(); Gone = $gone.ToArray() }
}

function Add-RatchetHistory {
  <# Append this run's count to the baseline document's history, newest last, capped.

     THE COUNT IS RECORDED ON EVERY RUN, not only when the baseline moves - the point is the RATE. A
     history that only grows when the number changes cannot show that a detector has been quietly
     returning the same figure for six weeks because it stopped looking.

     Guarded and swallowing its own failure, for the same reason run-log-lib states: a run with no
     history is degraded, and a run KILLED BY its history is lost. #>
  param(
    [Parameter(Mandatory=$true)]$Doc,
    [Parameter(Mandatory=$true)][int]$Count,
    [int]$Keep = 120
  )
  try {
    $hist = @()
    if ($Doc.PSObject.Properties['history'] -and $Doc.history) { $hist = @($Doc.history) }
    $hist += [pscustomobject]@{ date = (Get-Date).ToString('s'); count = $Count }
    if ($hist.Count -gt $Keep) { $hist = @($hist[($hist.Count - $Keep)..($hist.Count - 1)]) }
    # THE COMMA IS LOAD-BEARING. PS 5.1 unrolls a one-element array on return, and the caller then
    # reads .Count off the single object - where it resolves to that object's own `count` PROPERTY
    # rather than a length. This file's own self-test reported 17 where it expected 1.
    return ,$hist
  } catch {
    return ,@()
  }
}

function Get-RatchetTrend {
  <# A one-line read of the history: is this detector still finding what it used to?

     Deliberately reports "not enough history" rather than inventing a trend from two points. #>
  param([Parameter(Mandatory=$true)]$History, [int]$Window = 10)
  $h = @($History)
  if ($h.Count -lt 3) { return 'trend: not enough history yet' }
  $recent = @($h[[math]::Max(0, $h.Count - $Window)..($h.Count - 1)])
  $counts = @($recent | ForEach-Object { [int]$_.count })
  $lo = ($counts | Measure-Object -Minimum).Minimum
  $hi = ($counts | Measure-Object -Maximum).Maximum
  if ($lo -eq $hi) { return ("trend: flat at {0} across the last {1} run(s)" -f $lo, $counts.Count) }
  return ("trend: {0} to {1} across the last {2} run(s)" -f $lo, $hi, $counts.Count)
}

# The fields a static detector's COMPLETE marker uses for how much it READ. Only these: read=, findings=, sites= and
# the rest count what was FOUND, and a zero there is the good news, not a blind walk. A field glued to a prefix
# (stale-files=, py_files=) is a different quantity and is not read as one of these.
$script:TcStaticPopulationRx = '(?<![\w-])(scanned|files|examined|resolved)=(\d+)(?![\w.])'

function Get-TcStaticZeroScan {
  <# Did a static detector that exited 0 read NOTHING? Read off its LAST COMPLETE marker, which the caller passes.

     Returns @{ Blind; Counted; Field }:
       Blind   - $true when the exit code is 0, the marker carries a population field (scanned|files|examined|resolved)
                 whose value is 0, and the gate does not declare zero_ok. The caller scores that gate 3, never ok.
       Counted - the marker carries at least one population field, so the rule could look at all.
       Field   - the population field that read 0, or ''.

     A NON-ZERO EXIT IS LEFT TO THE EXIT CODE: a red gate outranks blind, and a gate that says 3 itself already said
     it. A marker with no population field is scored by its exit code exactly as before - the rule cannot see how much
     such a gate read, and says so by Counted = $false rather than guessing. ZeroOk is a gate's own declaration that
     an empty population is a legitimate answer for it, with its reason beside the declaration. #>
  # $ExitCode is UNTYPED on purpose: [int] would turn a missing exit code into 0 and read an absent result as a pass.
  param($ExitCode, [string]$Marker = '', [bool]$ZeroOk = $false)
  $counted = $false; $field = ''
  foreach ($m in [regex]::Matches([string]$Marker, $script:TcStaticPopulationRx)) {
    $counted = $true
    if (-not $field -and [long]$m.Groups[2].Value -eq 0) { $field = [string]$m.Groups[1].Value }
  }
  $blind = ($null -ne $ExitCode) -and ([int]$ExitCode -eq 0) -and (-not $ZeroOk) -and [bool]$field
  return [pscustomobject]@{ Blind = $blind; Counted = $counted; Field = $field }
}

if ($__ratchetSelfTest) {
  $fail = 0
  $cases = 0
  function T($n, $c, $g = '') { $script:cases++; if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  $r = Test-RatchetMove -Name 'probe' -Count 18 -Baseline 17
  T 'a count above the baseline is a NEW finding' ($r.Verdict -eq 'rose' -and $r.NewBaseline -eq 17) $r.Verdict

  $r = Test-RatchetMove -Name 'probe' -Count 17 -Baseline 17
  T 'an unchanged count holds' ($r.Verdict -eq 'held') $r.Verdict

  $r = Test-RatchetMove -Name 'probe' -Count 15 -Baseline 17
  T 'CLEAN TWIN a believable fall tightens and lowers the baseline' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 15) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # THE FOUNDING BUG. Before 2026-09-07 this recorded 0 and printed "PASSED and TIGHTENED".
  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 17
  T 'MUST FIRE  a fall to ZERO is refused and the baseline is KEPT' ($r.Verdict -eq 'implausible' -and $r.NewBaseline -eq 17) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)
  T 'the refusal says what to check rather than only that it refused' ($r.Message -like '*broken until proven otherwise*') $r.Message

  $r = Test-RatchetMove -Name 'probe' -Count 100 -Baseline 653
  T 'MUST FIRE  an 85% fall in one run is refused' ($r.Verdict -eq 'implausible' -and $r.NewBaseline -eq 653) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # CLEAN TWIN for that: a fall just inside the bar is still a tightening, or the guard is a wall.
  $r = Test-RatchetMove -Name 'probe' -Count 45 -Baseline 100
  T 'CLEAN TWIN a 55% fall is inside the bar and still tightens' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 45) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # THE BAR ITSELF (backlog I196). The refusal is for a fall LARGER than -MaxDropPct (-gt), so a fall of
  # exactly 60% still tightens and 61% is refused. 55 and 85 above cannot tell -gt from -ge; these can.
  $r = Test-RatchetMove -Name 'probe' -Count 40 -Baseline 100
  T 'MUST NOT FIRE a fall of exactly 60%, AT the MaxDropPct bar, still tightens' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 40) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)
  $r = Test-RatchetMove -Name 'probe' -Count 39 -Baseline 100
  T 'MUST FIRE  a fall of 61%, one point past the 60% MaxDropPct bar, is refused and the baseline KEPT' ($r.Verdict -eq 'implausible' -and $r.NewBaseline -eq 100) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 17 -AcceptDrop
  T '-AcceptDrop records a genuine bulk migration' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 0) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # A ratchet legitimately AT zero must keep passing, or the guard punishes the success it wanted.
  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 0
  T 'CLEAN TWIN a ratchet already at zero holds rather than being refused' ($r.Verdict -eq 'held') $r.Verdict
  $r = Test-RatchetMove -Name 'probe' -Count 1 -Baseline 0
  T 'MUST FIRE  a finding appearing on a clean ratchet is a rise' ($r.Verdict -eq 'rose') $r.Verdict

  $doc = [pscustomobject]@{ sites = 17 }
  # ASSIGNED, NOT WRAPPED. Add-RatchetHistory returns ,$hist so the array survives the unroll; putting
  # @() around that makes a one-element array whose single element IS the array, which is the same
  # collapse from the other side. Both mistakes were made here before this comment existed.
  $h = Add-RatchetHistory -Doc $doc -Count 17
  T 'history starts from a document that has none' ($h.Count -eq 1 -and [int]$h[0].count -eq 17) $h.Count
  T 'MUST FIRE  a one-entry history reports length 1, not the entry it contains' ([int]$h.Count -eq 1) $h.Count
  $doc2 = [pscustomobject]@{ sites = 16; history = $h }
  $h2 = Add-RatchetHistory -Doc $doc2 -Count 16
  T 'history appends rather than replacing' ($h2.Count -eq 2 -and [int]$h2[-1].count -eq 16) $h2.Count

  $many = @()
  for ($i = 0; $i -lt 130; $i++) { $many += [pscustomobject]@{ date = 'x'; count = $i } }
  $capped = Add-RatchetHistory -Doc ([pscustomobject]@{ history = $many }) -Count 999 -Keep 120
  T 'history is capped and keeps the NEWEST entries' ($capped.Count -eq 120 -and [int]$capped[-1].count -eq 999) ("{0}/{1}" -f $capped.Count, $capped[-1].count)

  T 'a trend refuses to be read from two points' ((Get-RatchetTrend -History @(1, 2)) -like '*not enough*')
  $flat = @(); for ($i = 0; $i -lt 5; $i++) { $flat += [pscustomobject]@{ count = 7 } }
  T 'MUST FIRE  a flat detector reads as flat, which is the I15 signal' ((Get-RatchetTrend -History $flat) -like '*flat at 7*') (Get-RatchetTrend -History $flat)

  # ---- a static detector that READ nothing (W6.9, 2026-09-23) ----------------------------------------------------
  # THE FOUNDING MARKER, verbatim from the readjson gate's runs in eleven worktrees: exit 0, scanned=0.
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'READJSON-INLINE-WRAP-COMPLETE scanned=0 findings=0'
  T 'MUST FIRE  exit 0 with scanned=0 is blind, and names the field that read zero' ($z.Blind -and $z.Field -ceq 'scanned') ("blind={0} field={1}" -f $z.Blind, $z.Field)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'X-COMPLETE files=0 read=0 sites=0'
  T 'MUST FIRE  files=0 is a population field too' ($z.Blind -and $z.Field -ceq 'files') ("blind={0} field={1}" -f $z.Blind, $z.Field)
  # THE BAR IS ZERO (backlog I196): exactly at it fires, one file past it does not.
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'X-COMPLETE examined=1 findings=0'
  T 'MUST NOT FIRE  examined=1, one step past the zero bar, is a detector that looked' (-not $z.Blind) ("blind={0}" -f $z.Blind)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'READJSON-INLINE-WRAP-COMPLETE scanned=681 findings=0'
  T 'MUST NOT FIRE  scanned=681 is a detector that looked' (-not $z.Blind) ("blind={0}" -f $z.Blind)
  T 'CLEAN TWIN  ...and it is read as a counted population, so the rule really looked at that marker' ($z.Counted) ("counted={0} field={1}" -f $z.Counted, $z.Field)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'AUDIT-TYPED-PARAM-SHADOW-COMPLETE files=725 read=0 assignments=0 sites=0 baseline=0'
  T 'MUST NOT FIRE  a zero in a FOUND field (read=0, sites=0) beside files=725 is good news, not a blind walk' (-not $z.Blind) ("blind={0} field={1}" -f $z.Blind, $z.Field)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'X-COMPLETE stale-files=0 py_files=0 findings=0'
  T 'MUST NOT FIRE  a prefixed field (stale-files=, py_files=) is a different quantity' (-not $z.Blind -and -not $z.Counted) ("blind={0} counted={1}" -f $z.Blind, $z.Counted)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'GUARD-CONTRACT-COMPLETE covered=63 backlog=0 dead=0'
  T 'MUST NOT FIRE  a marker with no population field is scored by its exit code exactly as before' (-not $z.Blind -and -not $z.Counted) ("blind={0} counted={1}" -f $z.Blind, $z.Counted)
  $z = Get-TcStaticZeroScan -ExitCode 1 -Marker 'X-COMPLETE scanned=0 findings=2'
  T 'MUST NOT FIRE  a red gate stays red: a non-zero exit is left to the exit code, which outranks blind' (-not $z.Blind) ("blind={0}" -f $z.Blind)
  $z = Get-TcStaticZeroScan -ExitCode $null -Marker 'X-COMPLETE scanned=0'
  T 'MUST NOT FIRE  a missing exit code is never read as exit 0' (-not $z.Blind) ("blind={0}" -f $z.Blind)
  $z = Get-TcStaticZeroScan -ExitCode 0 -Marker 'LIFT-COMPLETENESS-COMPLETE scanned=0 findings=0' -ZeroOk $true
  T 'MUST NOT FIRE  a gate that declares zero_ok is not blind on zero' (-not $z.Blind -and $z.Field -ceq 'scanned') ("blind={0} field={1}" -f $z.Blind, $z.Field)

  # ---- one named-site comparison (W6.9 step 3, 2026-09-23) --------------------------------------------------------
  $s = Compare-TcRatchetSites -Current @('a|x', 'c|z') -Baseline @('a|x', 'b|y')
  T 'MUST FIRE  a fix plus a NEW site in one change is a rise, although the count held at 2' ($s.Verdict -ceq 'rose' -and @($s.New).Count -eq 1 -and $s.New[0] -ceq 'c|z' -and @($s.Gone).Count -eq 1 -and $s.Gone[0] -ceq 'b|y') ("{0} new={1} gone={2}" -f $s.Verdict, (@($s.New) -join ','), (@($s.Gone) -join ','))
  $s = Compare-TcRatchetSites -Current @('a|x', 'a|x') -Baseline @('a|x')
  T 'MUST FIRE  a second copy of a known site is new - these are multisets, not sets' ($s.Verdict -ceq 'rose' -and @($s.New).Count -eq 1) ("{0} new={1}" -f $s.Verdict, @($s.New).Count)
  $s = Compare-TcRatchetSites -Current @('A|x') -Baseline @('a|x')
  T 'MUST FIRE  names compare ORDINALLY, so a case change is not waved through as the same site' ($s.Verdict -ceq 'rose') $s.Verdict
  $s = Compare-TcRatchetSites -Current @('a|x') -Baseline @('a|x', 'b|y')
  T 'MUST NOT FIRE  a pure fall reports no new site' (@($s.New).Count -eq 0) ("new=" + (@($s.New) -join ','))
  T 'CLEAN TWIN  ...and the fall NAMES the site that went, so a tightening says what it lowers' ($s.Verdict -ceq 'fell' -and @($s.Gone).Count -eq 1 -and $s.Gone[0] -ceq 'b|y') ("{0} gone={1}" -f $s.Verdict, (@($s.Gone) -join ','))
  $s = Compare-TcRatchetSites -Current @('b|y', 'a|x') -Baseline @('a|x', 'b|y')
  T 'MUST NOT FIRE  an unchanged set of sites holds, in any order' ($s.Verdict -ceq 'held') $s.Verdict
  $s = Compare-TcRatchetSites -Current @() -Baseline @()
  T 'MUST NOT FIRE  an empty tree against an empty baseline holds, not a PS 5.1 @($null) count of 1' ($s.Verdict -ceq 'held' -and @($s.New).Count -eq 0 -and @($s.Gone).Count -eq 0) ("{0} new={1} gone={2}" -f $s.Verdict, @($s.New).Count, @($s.Gone).Count)
  $s = Compare-TcRatchetSites -Current @('z|1', 'a|2') -Baseline @()
  T 'CLEAN TWIN  New keeps the order the caller listed its sites in, so a report reads in the caller''s order' ((@($s.New) -join ',') -ceq 'z|1,a|2') (@($s.New) -join ',')
  # THE KEY CONTRACT, on the real rule: a site keyed below the root reads the same from a worktree as from the main
  # checkout, so a worktree run never calls every known site new.
  . (Join-Path $PSScriptRoot 'tree-walk.ps1')
  $kMain = (Get-TcPathBelowRoot 'C:\x\main\ops\a.ps1' 'C:\x\main') + '|$v = & git log -1 2>$null'
  $kWt = (Get-TcPathBelowRoot 'C:\x\main\.claude\worktrees\wt1\ops\a.ps1' 'C:\x\main\.claude\worktrees\wt1') + '|$v = & git log -1 2>$null'
  $s = Compare-TcRatchetSites -Current @($kWt) -Baseline @($kMain)
  T 'CLEAN TWIN  a key built below a worktree root equals the key built below the main root, so the comparison holds' ($s.Verdict -ceq 'held' -and $kWt -ceq $kMain) ("{0} wt={1} main={2}" -f $s.Verdict, $kWt, $kMain)

  # ---- a mark nobody can read is not a mark (2026-09-24, pd-currency-2026-09-23.md) --------------------------------
  $rbDir = Join-Path $env:TEMP ('tc-rbl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $rbDir -ErrorAction Stop | Out-Null
  try {
    $u8r = New-Object Text.UTF8Encoding($false)
    $rbConf = Join-Path $rbDir 'conflict.json'
    [IO.File]::WriteAllText($rbConf, ('<' * 7) + " HEAD`n{ ""unbound"": 3 }`n" + ('=' * 7) + "`n{ ""unbound"": 4 }`n" + ('>' * 7) + " theirs`n", $u8r)
    $rb1 = Read-TcRatchetBaseline -Path $rbConf -Field 'unbound'
    $rb2 = Read-TcRatchetBaseline -Path (Join-Path $rbDir 'absent.json') -Field 'unbound'
    T 'MUST FIRE  a baseline holding rebase conflict markers is UNREADABLE and a missing one ABSENT, never a $null the caller rewrites' ($rb1.State -ceq 'unreadable' -and $null -eq $rb1.Value -and $rb2.State -ceq 'absent' -and (Get-TcRatchetBlindToken $rb1.State) -ceq 'baseline-unreadable' -and (Get-TcRatchetBlindToken $rb2.State) -ceq 'baseline-missing') ("{0}/{1}" -f $rb1.State, $rb2.State)
    $rbOdd = @()
    foreach ($body in @('[3]', '{"unbound":"3"}', '{"unbound":3.5}', '{"unbound":-1}', '{"other":3}')) {
      $fp = Join-Path $rbDir ('odd-' + $rbOdd.Count + '.json'); [IO.File]::WriteAllText($fp, $body, $u8r)
      $rbOdd += (Read-TcRatchetBaseline -Path $fp -Field 'unbound').State
    }
    T 'MUST FIRE  an array, a quoted number, a fraction, a negative and a missing field are each UNREADABLE' ((@($rbOdd | Where-Object { $_ -ceq 'unreadable' })).Count -eq 5) ($rbOdd -join ',')
    $rbOk = Join-Path $rbDir 'ok.json'
    [IO.File]::WriteAllBytes($rbOk, ([byte[]](0xEF, 0xBB, 0xBF) + $u8r.GetBytes('{"unbound":0,"names":[]}' + "`n")))
    $rb3 = Read-TcRatchetBaseline -Path $rbOk -Field 'unbound'
    T 'CLEAN TWIN  a committed baseline with a BOM and a mark of 0 is READ as 0, with its document' ($rb3.State -ceq 'read' -and $rb3.Value -eq 0 -and $null -ne $rb3.Doc) ("{0} {1}" -f $rb3.State, $rb3.Value)
    $threw = $false; try { $null = Get-TcRatchetBlindToken 'read' } catch { $threw = $true }
    T 'MUST FIRE  asking for the blind token of a READ baseline throws rather than naming a blindness that is not there' $threw
  } finally { Remove-Item -LiteralPath $rbDir -Recurse -Force -ErrorAction SilentlyContinue }

  $expected = 42
  if ($cases -ne $expected) { Write-Output ("FAIL  ran {0} case(s), the list holds {1}" -f $cases, $expected); $fail++ }
  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output ("SELF-TEST PASS ({0} cases): the rise, the hold, a believable fall, and the two refusals - a fall to nothing and a fall too large - plus history and its cap, one named-site comparison, a static detector that read nothing, and a baseline that cannot be read" -f $cases)
  exit 0
}
