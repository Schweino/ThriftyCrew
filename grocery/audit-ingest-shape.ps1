<#
.SYNOPSIS
  Meets a store rendering first seen THIS MORNING at ingest, before the chain prices anything: a never-seen unit
  spelling is PROVED from the store's own price arithmetic and kept in unit-aliases.json, or reported with its rows.

.DESCRIPTION
  Queue 2026-09-22-20fecf (plan-2026-09-22-10), which also closes batch 2's unbuilt "per-reason reject spike check"
  residual (2026-09-22-f23a00): the two are one condition. capture-run.ps1 runs this after the store builders and
  BEFORE check-ad-cycles.

  PER STORE, over the rejects files the three per-row builders write (build-sams-deals, build-walmart-deals,
  build-aldi-regular; see $script:IngestShapeBuilders in ingest-shape-lib.ps1):
    - a reason key (Get-RejectReasonKey: numbers to #, a quoted spelling kept) absent from EVERY rejects file of the
      prior $WindowDays days is NEW. Fewer than $MinPriorFiles prior files: that store is BLIND and admits nothing.
    - a new 'unknown unit "<spelling>"' is a UNIT finding. Its candidate family comes from the builders' unit
      vocabulary after dropping a parenthetical qualifier, dots and a plural s. It is PROVED only when EVERY row
      carrying it satisfies the store's own printed-cent rounding: some size the NAME states in that family
      (walmart-row-lib's Get-NameQtyCandidates) reproduces the unit price the store printed, within the half-ulp
      the price was printed to (Get-SamsUnitPriceReading's halfUlp, the rule build-sams-deals already carries).
      Proved: the alias is written to unit-aliases.json with its proving rows, and 'REBUILD-STORE <key>' tells
      capture-run to rebuild that store before downstream. ANY row unproved: nothing is admitted (the Aldi rule,
      "resolved by arithmetic proof or not at all") and the finding is listed with every row, for capture-run to
      send as 'Grocery: ingest shape - new unit spelling unproved'.
    - any other new reason is printed as NEW-REASON and never sent: 9 of the 16 first-seen reasons measured over
      87 rejects files were builder refusal WORDING after a code change, which ops/rehearse-chain.ps1 owns.

  THE CONSTANTS. $WindowDays = 14 and $MinPriorFiles = 3 are the plan's first plausible values, not the survivors of
  a sweep. The proof tolerance is not a constant of this file: it is the half-ulp of each printed price.

  SCOPE OF A CLEAN REPORT: unsound. It sees only the three builders that write per-row rejects, and only a
  rendering that is REFUSED; a rendering misread into a known unit is not a new spelling (leaves_open (b)).
  A PROVED finding is complete for what it claims: every row reproduced its own name in the store's own price.

  EXIT: 0 no unproved unit finding (BLIND stores and NEW-REASON lines may be present, named on the marker);
  2 at least one unit spelling unproved (capture-run sends it); 3 could not evaluate (an input could not be read).
  The last line is always INGEST-SHAPE-COMPLETE.

.EXAMPLE
  powershell -NoProfile -File grocery\audit-ingest-shape.ps1 -Date 2026-09-21
  powershell -NoProfile -File grocery\audit-ingest-shape.ps1 -SelfTest
#>
# The self-test lists and reads the frozen Sam's and Walmart rejects fixtures and writes its alias files in temp:
# gate-inputs: grocery\ingest-shape-lib.ps1, grocery\pricing-math-lib.ps1, grocery\walmart-row-lib.ps1, lib\lf-write.ps1, grocery\regression-inputs\guard-fixtures\ingest-shape\walmart-rejects-*.json, grocery\regression-inputs\guard-fixtures\ingest-shape\sams\sams-rejects-*.json
[CmdletBinding()]
param(
  [string]$Date = '',
  [string]$OutRoot = '',
  [string]$AliasFile = '',
  # a comma list under -File binds as one string; split below into a NEW variable
  [string]$Stores = 'sams,walmart,aldi',
  [int]$WindowDays = 14,
  [int]$MinPriorFiles = 3,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
. (Join-Path $root 'ingest-shape-lib.ps1')
. (Join-Path $root 'pricing-math-lib.ps1')    # Get-SamsUnitPriceReading: value + the half-ulp it was printed to
. (Join-Path $root 'walmart-row-lib.ps1')     # Get-NameQtyCandidates: every size the NAME can mean, in a family
. (Join-Path (Split-Path $root -Parent) 'lib\lf-write.ps1')

# The builders' unit vocabulary (build-sams-deals and walmart-row-lib Resolve-Unit), keyed by the normalised
# spelling. A spelling that normalises to none of these has NO family in the builder's table and cannot be proved:
# 'sq ft', 'g', 'ml' stay refused and are reported once (the day they are new).
$script:IsFamily = @{
  'fl oz' = @{ tok = 'fl oz'; unit = 'floz' };   'floz' = @{ tok = 'fl oz'; unit = 'floz' }
  'foz' = @{ tok = 'fl oz'; unit = 'floz' };     'fluid ounce' = @{ tok = 'fl oz'; unit = 'floz' }
  'oz' = @{ tok = 'oz'; unit = 'oz' };           'ounce' = @{ tok = 'oz'; unit = 'oz' }
  'lb' = @{ tok = 'lb'; unit = 'lb' };           'pound' = @{ tok = 'lb'; unit = 'lb' }
  'gal' = @{ tok = 'gal'; unit = 'gallon' };     'gallon' = @{ tok = 'gal'; unit = 'gallon' }; 'gl' = @{ tok = 'gal'; unit = 'gallon' }
  'ea' = @{ tok = 'ct'; unit = 'each' };         'each' = @{ tok = 'ct'; unit = 'each' }
  'ct' = @{ tok = 'ct'; unit = 'each' };         'count' = @{ tok = 'ct'; unit = 'each' }
  'dozen' = @{ tok = 'dozen'; unit = 'dozen' };  'doz' = @{ tok = 'dozen'; unit = 'dozen' }; 'dz' = @{ tok = 'dozen'; unit = 'dozen' }
}

function Get-UnitSpellingCandidate([string]$Spelling) {
  $n = ('' + $Spelling).ToLowerInvariant()
  $n = ($n -replace '\([^)]*\)', ' ' -replace '\.', '' -replace '\s+', ' ').Trim()
  if ($script:IsFamily.ContainsKey($n)) { return $script:IsFamily[$n] }
  if ($n.Length -gt 2 -and $n.EndsWith('s')) {
    $s = $n.Substring(0, $n.Length - 1)
    if ($script:IsFamily.ContainsKey($s)) { return $script:IsFamily[$s] }
  }
  return $null
}

function Test-RowProvesUnit($Row, [string]$Tok) {
  # Does some size the NAME states, in $Tok's family, reproduce the unit price the store printed, within the
  # half-ulp that price was printed to? Returns @{ ok; derived; name_qty; why }.
  $m = [regex]::Match(('' + $Row.lp), '([\d,]+(?:\.\d+)?)')
  if (-not $m.Success) { return @{ ok = $false; why = 'no line price' } }
  $lp = [double]($m.Groups[1].Value -replace ',', '')
  $up = Get-SamsUnitPriceReading ('' + $Row.up)
  if ($null -eq $up -or $up.value -le 0 -or $lp -le 0) { return @{ ok = $false; why = 'unit price unreadable' } }
  $derived = $lp / $up.value   # derived-size:allow the quotient is quoted in a finding's message and never written as a row's size
  $cands = Get-NameQtyCandidates ('' + $Row.name) $Tok
  foreach ($q in @($cands)) {
    if ($null -eq $q -or [double]$q -le 0) { continue }
    if ([math]::Abs(($lp / [double]$q) - $up.value) -le ($up.halfUlp + 0.000001)) {
      return @{ ok = $true; derived = $derived; name_qty = [double]$q }
    }
  }
  $cs = (@($cands) | ForEach-Object { '{0:0.###}' -f [double]$_ }) -join ','
  if (-not $cs) { $cs = 'none' }
  return @{ ok = $false; derived = $derived; why = ("the name states no size in the '{0}' family that reproduces {1} (lp/up {2:0.###}; name sizes {3})" -f $Tok, $Row.up, $derived, $cs) }
}

function Get-StoreRejectFiles([string]$Base, [string]$Key) {
  # date -> full path of that store's rejects file under $Base.
  $b = $script:IngestShapeBuilders[$Key]
  $dir = if ($b.Dir) { Join-Path $Base $b.Dir } else { $Base }
  $out = @{}
  if (-not (Test-Path -LiteralPath $dir)) { return $out }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter ($b.Prefix + '*.json'))) {
    $m = [regex]::Match($f.Name, ('^' + [regex]::Escape($b.Prefix) + '(\d{4}-\d{2}-\d{2})\.json$'))
    if ($m.Success) { $out[$m.Groups[1].Value] = $f.FullName }
  }
  return $out
}

function Read-RejectRows([string]$Path) {
  $txt = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  if (-not $txt.Trim()) { return ,@() }
  $j = $txt | ConvertFrom-Json
  $rows = New-Object System.Collections.ArrayList
  foreach ($r in @($j)) { if ($null -ne $r) { [void]$rows.Add((ConvertTo-IngestRejectRow $r)) } }
  return ,($rows.ToArray())
}

function Save-UnitAlias([string]$Path, [string]$Key, [string]$Spelling, $Cand, [string]$On, $Proofs) {
  $doc = [ordered]@{ readme = ''; stores = [ordered]@{} }
  if (Test-Path -LiteralPath $Path) {
    $old = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($old.PSObject.Properties['readme']) { $doc.readme = [string]$old.readme }
    if ($old.PSObject.Properties['stores']) {
      foreach ($sp in $old.stores.PSObject.Properties) {
        $m = [ordered]@{}
        foreach ($ap in $sp.Value.PSObject.Properties) { $m[$ap.Name] = $ap.Value }
        $doc.stores[$sp.Name] = $m
      }
    }
  }
  if (-not $doc.stores.Contains($Key)) { $doc.stores[$Key] = [ordered]@{} }
  $doc.stores[$Key][$Spelling] = [ordered]@{ tok = $Cand.tok; unit = $Cand.unit; proved_on = $On
                                            rows_proved = @($Proofs).Count; proving_rows = @($Proofs) }
  [void](Write-TcLfFile -Path $Path -Text ($doc | ConvertTo-Json -Depth 8) -NoBom)
  $script:UnitAliasCache = @{}
}

function Invoke-IngestShapeAudit {
  param([string]$Date, [string]$OutRoot, [string]$AliasFile, [string[]]$StoreKeys, [int]$WindowDays, [int]$MinPriorFiles)
  $res = [ordered]@{ lines = (New-Object System.Collections.ArrayList); stores = 0; scanned = 0; new = 0; proved = 0
                     unproved = 0; blind = 0; wording = 0; rebuild = (New-Object System.Collections.ArrayList); error = $null }
  $L = $res.lines
  $day = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  foreach ($key in $StoreKeys) {
    if (-not $script:IngestShapeBuilders.Contains($key)) { $res.error = "unknown store key '$key'"; return $res }
    $res.stores++
    $label = $script:IngestShapeBuilders[$key].Label
    $files = Get-StoreRejectFiles $OutRoot $key
    if (-not $files.ContainsKey($Date)) { [void]$L.Add(("  {0}: no rejects file for {1} (no build today, or nothing refused) - nothing to compare" -f $label, $Date)); continue }
    $prior = @($files.Keys | Where-Object {
      $d = [datetime]::ParseExact($_, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
      $d -lt $day -and $d -ge $day.AddDays(-1 * $WindowDays) } | Sort-Object)
    if ($prior.Count -lt $MinPriorFiles) {
      $res.blind++
      [void]$L.Add(("  BLIND {0}: {1} prior rejects file(s) in {2} days, fewer than {3} - nothing compared, nothing admitted" -f $label, $prior.Count, $WindowDays, $MinPriorFiles))
      continue
    }
    $seen = @{}
    foreach ($pd in $prior) { $pRows = Read-RejectRows $files[$pd]; foreach ($r in $pRows) { $seen[(Get-RejectReasonKey $r.reason)] = $true } }
    $today = Read-RejectRows $files[$Date]   # assigned, never wrapped inline: a comma-returned array wraps as ONE element
    $res.scanned++
    $groups = [ordered]@{}
    foreach ($r in $today) {
      $k = Get-RejectReasonKey $r.reason
      if (-not $groups.Contains($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
      [void]$groups[$k].Add($r)
    }
    $newKeys = @($groups.Keys | Where-Object { -not $seen.ContainsKey($_) })
    [void]$L.Add(("  {0}: {1} rejected row(s) today under {2} reason key(s); {3} prior file(s) ({4}..{5}); {6} key(s) new" -f $label, $today.Count, $groups.Count, $prior.Count, $prior[0], $prior[-1], $newKeys.Count))
    foreach ($k in $newKeys) {
      $res.new++
      $rows = $groups[$k].ToArray()
      $spell = Get-RejectUnitSpelling $rows[0].reason
      if ($null -eq $spell) {
        $res.wording++
        [void]$L.Add(("    NEW-REASON {0} x{1}: {2}  (printed, never sent: new refusal wording is the rehearsal's class)" -f $label, $rows.Count, $k))
        continue
      }
      $cand = Get-UnitSpellingCandidate $spell
      if ($null -eq $cand) {
        $res.unproved++
        [void]$L.Add(("    UNPROVED {0} unit ""{1}"" x{2}: no family in the builders' unit table, so no arithmetic can prove it; the rows stay refused" -f $label, $spell, $rows.Count))
        foreach ($r in $rows) { [void]$L.Add(("      row: {0} | {1} | {2}" -f $r.name, $r.lp, $r.up)) }
        continue
      }
      $proofs = New-Object System.Collections.ArrayList
      $fails = New-Object System.Collections.ArrayList
      foreach ($r in $rows) {
        $t = Test-RowProvesUnit $r $cand.tok
        if ($t.ok) { [void]$proofs.Add([ordered]@{ name = $r.name; lp = $r.lp; up = $r.up; derived = [math]::Round($t.derived, 3); name_qty = [math]::Round($t.name_qty, 3) }) }
        else { [void]$fails.Add(("      unproved row: {0} | {1} | {2} | {3}" -f $r.name, $r.lp, $r.up, $t.why)) }
      }
      if ($fails.Count -eq 0) {
        $res.proved++
        Save-UnitAlias $AliasFile $key $spell $cand $Date $proofs.ToArray()
        if (-not $res.rebuild.Contains($key)) { [void]$res.rebuild.Add($key) }
        [void]$L.Add(("    PROVED {0} unit ""{1}"" -> {2} ({3} of {3} rows reproduce their own name at the store's printed rounding); alias written to {4}" -f $label, $spell, $cand.tok, $rows.Count, (Split-Path $AliasFile -Leaf)))
      } else {
        $res.unproved++
        [void]$L.Add(("    UNPROVED {0} unit ""{1}"" -> {2}: {3} of {4} rows proved, {5} did not, so nothing is admitted (resolved by arithmetic proof or not at all)" -f $label, $spell, $cand.tok, $proofs.Count, $rows.Count, $fails.Count))
        foreach ($f in $fails) { [void]$L.Add($f) }
      }
    }
  }
  return $res
}

function Invoke-IngestShapeRun([string]$D, [string]$Base, [string]$Aliases, [string]$StoreList, [int]$Win, [int]$MinP) {
  # -> @{ rc; lines } with the verdict line and the marker last. The one road for the CLI and the self-test.
  $out = New-Object System.Collections.ArrayList
  $keys = @(($StoreList -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  try {
    $res = Invoke-IngestShapeAudit -Date $D -OutRoot $Base -AliasFile $Aliases -StoreKeys $keys -WindowDays $Win -MinPriorFiles $MinP
  } catch { $res = $null; $err = $_.Exception.Message }
  if ($null -eq $res -or $res.error) {
    if ($res) { $err = $res.error }
    [void]$out.Add("INGEST-SHAPE: COULD NOT EVALUATE - $err")
    [void]$out.Add('INGEST-SHAPE-COMPLETE stores=0 scanned=0 new=0 proved=0 unproved=0 blind=could-not-evaluate')
    return @{ rc = 3; lines = $out.ToArray(); rebuild = @() }
  }
  foreach ($l in $res.lines) { [void]$out.Add($l) }
  foreach ($k in $res.rebuild) { [void]$out.Add("REBUILD-STORE $k") }
  $rc = 0
  if ($res.unproved -gt 0) { $rc = 2; [void]$out.Add(("INGEST-SHAPE: FINDING - {0} new unit spelling(s) unproved at ingest; the rows stay refused and are listed above" -f $res.unproved)) }
  elseif ($res.proved -gt 0) { [void]$out.Add(("INGEST-SHAPE: PROVED - {0} new unit spelling(s) proved by the store's own arithmetic and kept" -f $res.proved)) }
  else { [void]$out.Add(("INGEST-SHAPE: PASSED - no unproved new unit spelling ({0} new reason key(s) printed, {1} store(s) blind)" -f $res.new, $res.blind)) }
  [void]$out.Add(("INGEST-SHAPE-COMPLETE stores={0} scanned={1} new={2} proved={3} unproved={4} blind={5}" -f $res.stores, $res.scanned, $res.new, $res.proved, $res.unproved, $res.blind))
  return @{ rc = $rc; lines = $out.ToArray(); rebuild = $res.rebuild.ToArray() }
}

if ($SelfTest) {
  # FROZEN FIXTURES: grocery\regression-inputs\guard-fixtures\ingest-shape\, cut ONCE from the real rejects files
  # on 2026-09-22 (every 'unknown unit' row kept whole, one row per other reason key; the key set per file, which is
  # all this audit compares, is unchanged). Never regenerate them from live files: the founding case would vanish.
  $fx = Join-Path $root 'regression-inputs\guard-fixtures\ingest-shape'
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ingshape-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $script:fail = 0; $script:cases = 0
  function _Ok([string]$Label, [bool]$Cond, [string]$Got) {
    $script:cases++
    if ($Cond) { Write-Output ("ok    " + $Label) } else { Write-Output ("FAIL  " + $Label + "  got: " + $Got); $script:fail++ }
  }
  function _Alias([string]$Name) { $p = Join-Path $tmp ($Name + '-aliases.json'); [IO.File]::WriteAllText($p, '{"readme":"fixture","stores":{"sams":{},"walmart":{}}}', (New-Object Text.UTF8Encoding($false))); return $p }
  try {
    # unit: the key keeps a quoted spelling and folds numbers outside it
    $k1 = Get-RejectReasonKey 'unknown unit "fluid ounce (us)"'
    _Ok 'key keeps the quoted spelling verbatim' ($k1 -eq 'unknown unit "fluid ounce (us)"') $k1
    $k2 = Get-RejectReasonKey 'NAME CONFLICT: name states 3 ct but none reproduces Sam''s 0.16/ct (lp/up derives 12.5)'
    _Ok 'key folds every number outside quotes to #' ($k2 -eq 'name conflict: name states # ct but none reproduces sam''s #/ct (lp/up derives #)') $k2
    $c1 = Get-UnitSpellingCandidate 'fluid ounce (us)'
    _Ok 'candidate: "fluid ounce (us)" drops its qualifier and is the fl oz family' ($null -ne $c1 -and $c1.tok -eq 'fl oz') ("$($c1.tok)")
    $c2 = Get-UnitSpellingCandidate 'sq ft'
    _Ok 'candidate: "sq ft" has no family in the builders'' table' ($null -eq $c2) ("$c2")
    $c3 = Get-UnitSpellingCandidate 'Pounds'
    _Ok 'candidate: a plural s is dropped ("Pounds" -> lb)' ($null -ne $c3 -and $c3.tok -eq 'lb') ("$($c3.tok)")

    # THE BAR: the store's printed rounding. "$0.50/fluid ounce (us)" prints to the cent, halfUlp 0.005 (+1e-6).
    # 10 fl oz at $5.05: lp/q = 0.505, 0.005 from the printed 0.50 = AT the bar (inside the 1e-6 epsilon).
    $atBar = Test-RowProvesUnit ([pscustomobject]@{ name = 'Fixture Juice 10 fl oz'; lp = '$5.05'; up = '$0.50/fluid ounce (us)' }) 'fl oz'
    _Ok 'BAR: lp/q exactly half a cent from the printed unit price (0.505 vs 0.50) proves' ($atBar.ok) ("$($atBar.why)")
    # a step past: $5.06 -> 0.506, 0.006 from 0.50, one tenth of a cent past the bar
    $past = Test-RowProvesUnit ([pscustomobject]@{ name = 'Fixture Juice 10 fl oz'; lp = '$5.06'; up = '$0.50/fluid ounce (us)' }) 'fl oz'
    _Ok 'BAR: a step past (0.506 vs 0.50, 0.001 beyond the half cent) does not prove' (-not $past.ok) ("ok=$($past.ok)")

    # MUST FIRE: the founding day. Sam's 2026-09-21 against its prior 14 days of frozen rejects files.
    # MEASURED 2026-09-22 (premise check): 50 of the 52 "fluid ounce (us)" rows reproduce their name; two do not
    # (Bimbo bread "20 oz., 2 pk." at 8.6 c/fluid ounce derives 40.93, and a 750 ml Chardonnay derives 25.34 against
    # 25.36). So under the plan's own rule the founding spelling is UNPROVED and queued with its rows, not admitted.
    $a1 = _Alias 'founding'
    $before = [IO.File]::ReadAllText($a1)
    $r1 = Invoke-IngestShapeRun '2026-09-21' $fx $a1 'sams' 14 3
    $t1 = ($r1.lines -join "`n")
    _Ok 'MUST FIRE Sam''s 2026-09-21: "fluid ounce (us)" is NEW and UNPROVED, 50 of 52 rows proved' ($t1 -match 'UNPROVED Sam''s Club unit "fluid ounce \(us\)" -> fl oz: 50 of 52 rows proved') $t1
    _Ok 'MUST FIRE the unproved finding names its rows (the bread and the Chardonnay)' (($t1 -match 'unproved row: Bimbo Soft White Bread') -and ($t1 -match 'unproved row: Sonoma-Cutrer')) $t1
    _Ok 'MUST FIRE "sq ft" is new the same day and has no family: unproved, rows listed' ($t1 -match 'UNPROVED Sam''s Club unit "sq ft" x53') $t1
    # The same real day also carried 'gl' (2 rows, both reproduce: PROVED and kept), 'gallon (us)' (1 row, Member's
    # Mark water 6 x 1 gal at $5.38 printed 98.0 c/gallon, lp/up 5.49: UNPROVED) and 'pad' (no family). So the
    # unproved spellings are NOT admitted while the proved one is, on one day, in one store.
    $s1 = [IO.File]::ReadAllText($a1) | ConvertFrom-Json
    $admitted = @($s1.stores.sams.PSObject.Properties | ForEach-Object { $_.Name })
    _Ok 'MUST FIRE exit 2; only the proved "gl" is admitted, never "fluid ounce (us)", "gallon (us)", "sq ft" or "pad"' (($r1.rc -eq 2) -and ($admitted.Count -eq 1) -and ($admitted[0] -eq 'gl') -and ($before -ne [IO.File]::ReadAllText($a1))) ("rc=$($r1.rc) admitted=" + ($admitted -join ','))
    _Ok 'MUST FIRE marker counts it: 6 new keys, 1 proved, 4 unproved' ($r1.lines[-1] -ceq 'INGEST-SHAPE-COMPLETE stores=1 scanned=1 new=6 proved=1 unproved=4 blind=0') $r1.lines[-1]

    # MUST FIRE, the proving road: the same frozen day with only the rows that reproduce (the 50) left under the
    # spelling. Every row proves, so the alias is written with its rows and the store is rebuilt.
    $fx2 = Join-Path $tmp 'proved'
    New-Item -ItemType Directory -Path (Join-Path $fx2 'sams') -Force | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $fx 'sams') -Filter 'sams-rejects-*.json')) {
      if ($f.Name -ne 'sams-rejects-2026-09-21.json') { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $fx2 'sams') }
    }
    $d21 = [IO.File]::ReadAllText((Join-Path $fx 'sams\sams-rejects-2026-09-21.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $keep = @($d21 | Where-Object { ([string]$_.reason -eq 'unknown unit "fluid ounce (us)"') -and ([string]$_.name -notmatch '^(Bimbo Soft White Bread|Sonoma-Cutrer)') })
    [IO.File]::WriteAllText((Join-Path $fx2 'sams\sams-rejects-2026-09-21.json'), ((ConvertTo-Json -InputObject $keep -Depth 4)), (New-Object Text.UTF8Encoding($false)))
    $a2 = _Alias 'proved'
    $r2 = Invoke-IngestShapeRun '2026-09-21' $fx2 $a2 'sams' 14 3
    $t2 = ($r2.lines -join "`n")
    $al = Resolve-UnitAlias -Store 'sams' -Spelling 'fluid ounce (us)' -AliasFile $a2
    _Ok 'MUST FIRE the 50 reproducing rows PROVE fl oz: alias written, REBUILD-STORE sams, exit 0' (($r2.rc -eq 0) -and ($t2 -match 'PROVED Sam''s Club unit "fluid ounce \(us\)" -> fl oz \(50 of 50 rows') -and (@($r2.rebuild) -contains 'sams')) $t2
    $saved = [IO.File]::ReadAllText($a2) | ConvertFrom-Json
    _Ok 'MUST FIRE the alias keeps its proving rows and the date' (($saved.stores.sams.'fluid ounce (us)'.rows_proved -eq 50) -and ($saved.stores.sams.'fluid ounce (us)'.proved_on -eq '2026-09-21')) ("rows=$($saved.stores.sams.'fluid ounce (us)'.rows_proved)")
    # CLEAN TWIN: the builders' fallback reads the proved alias back in their own vocabulary
    _Ok 'CLEAN TWIN Resolve-UnitAlias hands the builder {tok fl oz, unit floz} for the proved spelling' ($null -ne $al -and $al.tok -eq 'fl oz' -and $al.unit -eq 'floz') ("$($al.tok)/$($al.unit)")
    $alW = Resolve-UnitAlias -Store 'walmart' -Spelling 'fluid ounce (us)' -AliasFile $a2
    _Ok 'MUST NOT FIRE a spelling proved at Sam''s is not admitted at Walmart' ($null -eq $alW) ("$alW")

    # MUST NOT FIRE: Sam's 2026-09-20 against its prior files raises no unit finding.
    $a3 = _Alias 'clean'
    $r3 = Invoke-IngestShapeRun '2026-09-20' $fx $a3 'sams' 14 3
    _Ok 'MUST NOT FIRE Sam''s 2026-09-20: no unit finding, exit 0' (($r3.rc -eq 0) -and (($r3.lines -join "`n") -cnotmatch 'UNPROVED|PROVED Sam')) (($r3.lines -join ' / '))

    # MUST NOT FIRE: fewer than 3 prior files is BLIND for that store and admits nothing.
    $a4 = _Alias 'blind'; $b4 = [IO.File]::ReadAllText($a4)
    $r4 = Invoke-IngestShapeRun '2026-09-08' $fx $a4 'sams' 14 3
    _Ok 'MUST NOT FIRE Sam''s 2026-09-08 with 2 prior files (one under the bar of 3) reports BLIND, exit 0, admits nothing' (($r4.rc -eq 0) -and (($r4.lines -join "`n") -match 'BLIND Sam''s Club: 2 prior') -and ($r4.lines[-1] -match 'scanned=0 .*blind=1$') -and ([IO.File]::ReadAllText($a4) -eq $b4)) (($r4.lines -join ' / '))
    # AT THE BAR: Sam's 2026-09-09 has exactly 3 prior files (09-06, 09-07, 09-08) and is compared, not blind
    $r4b = Invoke-IngestShapeRun '2026-09-09' $fx (_Alias 'atbar') 'sams' 14 3
    _Ok 'AT THE BAR Sam''s 2026-09-09 with exactly 3 prior files is scanned, not blind' ($r4b.lines[-1] -match 'scanned=1 .*blind=0$') (($r4b.lines -join ' / '))

    # MUST NOT FIRE: Walmart 2026-09-06's new refusal wording is printed, never a unit finding, never exit 2.
    $a5 = _Alias 'wording'
    $r5 = Invoke-IngestShapeRun '2026-09-06' $fx $a5 'walmart' 14 3
    $t5 = ($r5.lines -join "`n")
    _Ok 'MUST NOT FIRE Walmart 2026-09-06: "refused: name quantity disagrees" is NEW-REASON, printed, exit 0' (($r5.rc -eq 0) -and ($t5 -match 'NEW-REASON Walmart x\d+: refused: name quantity disagrees') -and ($t5 -cnotmatch 'UNPROVED')) $t5

    # could-not-evaluate: an unknown store key is exit 3 with the marker still last
    $r6 = Invoke-IngestShapeRun '2026-09-21' $fx (_Alias 'bad') 'nosuchstore' 14 3
    _Ok 'COULD NOT EVALUATE an unknown store key is exit 3 and still ends on the marker' (($r6.rc -eq 3) -and ($r6.lines[-1] -match '^INGEST-SHAPE-COMPLETE .*blind=could-not-evaluate$')) (($r6.lines -join ' / '))
  } catch {
    Write-Output ("FAIL  self-test threw: " + $_.Exception.Message); $script:fail++
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 21
  if ($script:cases -ne $expected) { Write-Output ("FAIL  ran {0} case(s), the suite lists {1}" -f $script:cases, $expected); $script:fail++ }
  if ($script:fail -eq 0) { Write-Output ("audit-ingest-shape self-test: PASS ({0} cases)" -f $script:cases); exit 0 }
  Write-Output ("audit-ingest-shape self-test: FAIL ({0} of {1} failed)" -f $script:fail, $script:cases); exit 1
}

if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $OutRoot) { $OutRoot = Join-Path $root 'out' }
if (-not $AliasFile) { $AliasFile = Join-Path $root 'unit-aliases.json' }
$run = Invoke-IngestShapeRun $Date $OutRoot $AliasFile $Stores $WindowDays $MinPriorFiles
foreach ($l in $run.lines) { Write-Output $l }
exit $run.rc
