# audit-size-parser-parity.ps1 - the two size readers in this estate must give the same answer.
#
# WHY THIS EXISTS (2026-09-22, queue 2026-09-22-a09096). "What quantity does this size string state" is ONE
# rule and this estate holds TWO implementations of it:
#
#   grocery\pricing-math-lib.ps1  Get-SizeAmount    the ENGINE's. It prices the board.
#   grocery\pu-lib.ps1            Get-LinkPerUnit   the LINK and AUDIT side. guards.ps1, prune-bad-links.ps1,
#                                                   audit-everyday-mismatch.ps1, audit-board-consistency.ps1,
#                                                   build-deals-page.ps1, generate-board-overrides.ps1 and
#                                                   verify-price-flags.ps1 all decide through it.
#
# Nothing proved they agreed. They did not. The engine has read "24 ct 16.9 oz" as count-times-size since it
# was written; pu-lib's pack-first branch listed pk|pack|x only, so it returned $null for every 'ct' or
# 'count' multipack. Measured over comparison-2026-09-22 the day this landed: 26 board cells carried a size
# of that shape and pu-lib could price none of them, plus 5 more disagreements of other shapes, 31 of 2,564
# comparable size strings in all.
#
# THE COST WAS NOT A WRONG PRICE, IT WAS A WRONG VERDICT, which is why no price guard saw it. Sam's Club's
# "Member's Mark Classic Hummus Singles 2.5 oz., 16 ct." is $5.58 for 16 x 2.5 oz = 40 oz = $0.1395/oz, and
# the board published exactly that. verify-price-flags asked pu-lib what the store's own size field gave,
# got $null, fell back to a name reading, and condemned the cell as wrong-price. audit-flag-verification
# then quarantined a CORRECT price off the board. A silent $null in a shared reader is the estate's
# same-fact-published-twice class wearing its worst coat: two copies of one rule, and the weaker copy
# deciding whether the stronger copy is allowed to publish.
#
# WHAT THIS DOES. Runs both readers over a frozen corpus of real size strings and reports every
# disagreement. A disagreement is a $null on one side and a number on the other, or two numbers more than
# the tolerance apart. Neither reader is treated as right: the POINT is that one rule may not have two
# answers, and which answer is correct is a question for whoever reads the finding.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, and deliberately so. The corpus is frozen, so a clean report means
# these two readers agree ON THESE STRINGS, never that they agree on every string a store can print. It is
# COMPLETE in the other direction: a finding is a real disagreement between two live functions over a real
# input, computed rather than pattern-matched, so there is nothing to triage about whether it is genuine.
# -Board widens the corpus to every size string on the newest comparison board and is the arm worth running
# in the daily chain; with no board it says BLIND and exits 3, because a could-not-look is never a pass.
#
# -Board IS NOT WIRED INTO THE CHAIN YET, ON PURPOSE. Over comparison-2026-09-22, after the 'ct' fix that
# shipped with this file, it reads 5 disagreements over 2,584 comparable of 2,675 size strings: a bare 'oz'
# twice, '30 sq ft', '200 g', and eggs|Sam's Club '15 dozen' where pu-lib says 29.5600 and the engine says
# 1.9707. Every one is a real divergence and none is fixed here. Wiring it today would add a gate that is
# RED ON DAY ONE, which this estate refuses because it teaches people to ignore red
# (.claude/rules/ops-and-gates.md). The hermetic -SelfTest arm IS green and run-gates runs it on every push,
# so the 'ct' class cannot come back while the remaining five wait for their own item.
#
#   grocery\audit-size-parser-parity.ps1            the frozen corpus
#   grocery\audit-size-parser-parity.ps1 -Board     the frozen corpus PLUS every size string on the newest board
#   grocery\audit-size-parser-parity.ps1 -SelfTest  must-fire and must-not-fire over the comparison itself
# Exit 0 = the readers agree. 2 = at least one disagreement. 3 = BLIND (a library or a board is missing).
#
# IT LIVES IN grocery\ AND NOT IN ops\ because both readers do. The first cut of this file sat in ops\ and
# dot-sourced two grocery libraries, which ops\audit-cross-module-reach.ps1 correctly refused on the push
# that carried it (base=118 now=119, one new reach, mine). A check about grocery's pricing rules belongs
# beside them.
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Board)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')   # Read-JsonFile: a BOM-less Get-Content read is cp1252 under PS 5.1

# The tolerance is float noise, not a judgement about prices: both sides divide the same price by a
# quantity each derives, so anything above this is a different QUANTITY and not a different rounding.
# FIRST PLAUSIBLE NUMBER, nothing else tried, and it is not a tuning constant - no finding here is
# decided by how big it is, because every real divergence found so far was a null against a number or a
# whole pack count apart.
$script:SizeParityTol = 0.0001

function Test-TcSizeParity {
  <# Returns 'agree', 'disagree' or 'not-comparable'. Nulls are the whole point: a reader that cannot read
     a string is not wrong, but two readers where only ONE can read it is a divergence, and that is the
     shape that cost the hummus cell. Both blind is not a finding here; it is a gap in both, which is a
     different question and a different check. #>
  param($A, $B)
  $aNull = ($null -eq $A); $bNull = ($null -eq $B)
  if ($aNull -and $bNull) { return 'not-comparable' }
  if ($aNull -or $bNull) { return 'disagree' }
  if ([math]::Abs([double]$A - [double]$B) -le $script:SizeParityTol) { return 'agree' }
  return 'disagree'
}

function Get-TcEnginePerUnit {
  <# The ENGINE's answer in per-unit terms, so the two are compared on one scale. #>
  param([string]$Size, [string]$Unit, [double]$Price)
  $qty = Get-SizeAmount -sizeText $Size -unit $Unit
  if ($null -eq $qty) { return $null }
  if ([double]$qty -le 0) { return $null }
  return ($Price / [double]$qty)
}

function Get-TcSizeParityCorpus {
  <# FROZEN, and every row is a real size string read off a real capture. Never regenerate this from the
     live board: the divergence it encodes would vanish the day a store restyles its sizes and the check
     would pass by finding nothing. Each row is size | unit | price. #>
  $rows = New-Object System.Collections.ArrayList
  # the founding case, Sam's Club hummus, 2026-09-22
  [void]$rows.Add('16 ct 2.5 oz|oz|5.58')
  # the other 'ct'/'count' multipacks live on comparison-2026-09-22, one per distinct shape
  [void]$rows.Add('12 ct 10.75 oz|oz|12.98')
  [void]$rows.Add('8 ct 15 oz|oz|12.98')
  [void]$rows.Add('24 ct 10 oz|floz|13.78')
  [void]$rows.Add('180 ct 0.3 fl oz|floz|12.78')
  [void]$rows.Add('48 ct 1 oz|oz|9.47')
  [void]$rows.Add('6 ct 1 lb|oz|8.52')
  [void]$rows.Add('2 ct 48 fl oz|floz|6.48')
  [void]$rows.Add('16 count 2.5 oz|oz|5.58')
  # the spellings that already worked, so a change that fixes 'ct' by breaking 'pk' is caught
  [void]$rows.Add('16 pk 2.5 oz|oz|5.58')
  [void]$rows.Add('6 pk 4 oz|oz|3.99')
  [void]$rows.Add('12 x 12 fl oz|floz|7.48')
  [void]$rows.Add('2 pk 1 gal|gallon|6.98')
  # single-unit shapes, where a pack rule that fires too eagerly would show up
  [void]$rows.Add('15 oz|oz|1.29')
  [void]$rows.Add('1.82 lb|oz|6.44')
  [void]$rows.Add('48 fl oz|floz|3.24')
  [void]$rows.Add('1/2 gal|gallon|2.19')
  # count commodities, where 'N pk M oz' means N ITEMS and not N*M ounces
  [void]$rows.Add('4 pk 4 oz|each|2.38')
  [void]$rows.Add('12 pk 2 oz|dozen|3.48')
  [void]$rows.Add('6 ct 5.3 oz|each|5.94')
  return ,$rows.ToArray()
}

function Invoke-TcSizeParityRun {
  param([string[]]$Rows)
  $findings = New-Object System.Collections.ArrayList
  $comparable = 0; $examined = 0
  foreach ($row in $Rows) {
    $parts = $row -split '\|'
    if ($parts.Count -lt 3) { continue }
    $size = $parts[0]; $unit = $parts[1]; $price = [double]$parts[2]
    $examined++
    $link = Get-LinkPerUnit -size $size -unit $unit -price $price
    $eng = Get-TcEnginePerUnit -Size $size -Unit $unit -Price $price
    $verdict = Test-TcSizeParity -A $link -B $eng
    switch ($verdict) {
      'agree' { $comparable++ }
      'not-comparable' { }
      'disagree' {
        $comparable++
        $lT = if ($null -eq $link) { 'cannot read it' } else { '{0:0.0000}' -f $link }
        $eT = if ($null -eq $eng) { 'cannot read it' } else { '{0:0.0000}' -f $eng }
        [void]$findings.Add(("'{0}' at {1}, `${2}: pu-lib Get-LinkPerUnit says {3}, pricing-math-lib Get-SizeAmount says {4}" -f $size, $unit, $price, $lT, $eT))
      }
      default { throw "unknown size-parity verdict: $verdict" }
    }
  }
  return [pscustomobject]@{ findings = $findings.ToArray(); comparable = $comparable; examined = $examined }
}

function Get-TcBoardSizeRows {
  <# Every size string on the newest comparison board, as corpus rows. Returns $null when there is no
     board, which is a worktree and a clean checkout - BLIND, never clean. #>
  param([string]$Root)
  $dir = Join-Path $Root 'out'
  if (-not (Test-Path $dir)) { return $null }
  $cmp = @(Get-ChildItem -LiteralPath $dir -Filter 'comparison-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if (-not $cmp.Count) { return $null }
  # Read-JsonFile, never Get-Content -Raw: under PS 5.1 a BOM-less read is cp1252 and mangles every name
  # (lib/json-io.ps1, and grocery/audit-json-readers.ps1 ratchets it - it caught this line on the push).
  $doc = Read-JsonFile -Path $cmp[0].FullName
  $rows = New-Object System.Collections.ArrayList
  foreach ($r in @($doc.comparison)) {
    $unit = [string]$r.unit
    if (-not $unit) { continue }
    if (-not $r.PSObject.Properties['stores']) { continue }
    foreach ($cell in @($r.stores)) {
      if ($null -eq $cell) { continue }
      if (-not $cell.PSObject.Properties['size']) { continue }
      $sz = [string]$cell.size
      if (-not $sz) { continue }
      if ($sz -match '\|') { continue }
      $pr = 0.0
      foreach ($pk in @('price', 'ad', 'ad_price', 'current_price')) {
        if ($cell.PSObject.Properties[$pk]) {
          $t = ([string]$cell.$pk) -replace '[^0-9.]', ''
          if ($t -and [double]::TryParse($t, [ref]$pr) -and $pr -gt 0) { break }
        }
      }
      if ($pr -le 0) { $pr = 1.0 }
      [void]$rows.Add(("{0}|{1}|{2}" -f $sz, $unit, $pr))
    }
  }
  return ,$rows.ToArray()
}

# ---- libraries. A reader that will not load is BLIND, never clean ---------------------------------------
try {
  . (Join-Path $root 'pu-lib.ps1')
  . (Join-Path $root 'pricing-math-lib.ps1')
} catch {
  Write-Output ('BLIND: a size reader would not load, so nothing was compared: ' + $_.Exception.Message)
  Write-GuardComplete -Name 'size-parser-parity' -Summary 'could not load both readers'
  exit 3
}
if (-not (Get-Command Get-LinkPerUnit -ErrorAction SilentlyContinue) -or -not (Get-Command Get-SizeAmount -ErrorAction SilentlyContinue)) {
  Write-Output 'BLIND: Get-LinkPerUnit or Get-SizeAmount is not defined after loading both libraries'
  Write-GuardComplete -Name 'size-parser-parity' -Summary 'a reader is missing'
  exit 3
}

if ($SelfTest) {
  $fail = 0; $cases = 0
  # MUST FIRE, the founding shape: one reader blind, the other reading. This is exactly what 2026-09-22
  # looked like before the fix, and a check that scored it 'agree' would have found nothing that day.
  $cases++
  if ((Test-TcSizeParity -A $null -B 0.1395) -eq 'disagree') { Write-Output '  PASS  MUST FIRE: one reader returning $null while the other prices it is a disagreement (the 2026-09-22 hummus shape)' } else { Write-Output '  FAIL  a null against a number scored as agreement - the founding divergence would not be found'; $fail++ }
  # MUST FIRE, a numeric divergence: eggs|Sam's Club '15 dozen' read 29.5600 by pu-lib and 1.9707 by the engine.
  $cases++
  if ((Test-TcSizeParity -A 29.56 -B 1.9707) -eq 'disagree') { Write-Output '  PASS  MUST FIRE: two readers a pack count apart is a disagreement (the eggs 15-dozen shape)' } else { Write-Output '  FAIL  a 15x divergence scored as agreement'; $fail++ }
  $cases++
  if ((Test-TcSizeParity -A 0.1395 -B 0.1395) -eq 'agree') { Write-Output '  PASS  MUST NOT FIRE: two readers giving the same per-unit is not a finding' } else { Write-Output '  FAIL  an agreement was reported as a divergence - this check would cry wolf'; $fail++ }
  $cases++
  if ((Test-TcSizeParity -A $null -B $null) -eq 'not-comparable') { Write-Output '  PASS  MUST NOT FIRE: BOTH readers blind is a gap in both, not a divergence between them' } else { Write-Output '  FAIL  two nulls were scored as a divergence'; $fail++ }
  $cases++
  if ((Test-TcSizeParity -A 0.1395 -B 0.13955) -eq 'agree') { Write-Output '  PASS  MUST NOT FIRE: a difference inside the float tolerance is not a divergence' } else { Write-Output '  FAIL  float noise was reported as a divergence'; $fail++ }
  # CLEAN TWIN: the real libraries, over the real founding string, still both price it and still agree.
  # This is the positive assertion the exemptions above cannot make: it runs the code under test.
  $cases++
  $lv = Get-LinkPerUnit -size '16 ct 2.5 oz' -unit 'oz' -price 5.58
  $ev = Get-TcEnginePerUnit -Size '16 ct 2.5 oz' -Unit 'oz' -Price 5.58
  if ($null -ne $lv -and $null -ne $ev -and [math]::Abs($lv - 0.1395) -le 0.0001 -and [math]::Abs($ev - 0.1395) -le 0.0001) { Write-Output '  PASS  CLEAN TWIN: both live readers price the founding string 16 ct 2.5 oz at $5.58 as 0.1395/oz' } else { Write-Output ("  FAIL  the live readers no longer agree on the founding string: pu-lib=$lv engine=$ev"); $fail++ }
  # THE FROZEN CORPUS, through the real code on both sides.
  $cases++
  $corpus = Get-TcSizeParityCorpus
  $res = Invoke-TcSizeParityRun -Rows $corpus
  if ($res.findings.Count -eq 0) { Write-Output ("  PASS  CLEAN TWIN: the two readers agree on all $($res.comparable) comparable row(s) of the frozen $($res.examined)-row corpus") } else { Write-Output ("  FAIL  $($res.findings.Count) of $($res.comparable) comparable frozen row(s) disagree:"); $res.findings | ForEach-Object { Write-Output ('          ' + $_) }; $fail++ }
  Write-Output ("size-parser-parity self-test: $cases case(s), $fail failure(s)")
  if ($fail) { Write-Output 'SIZE-PARSER-PARITY SELF-TEST FAIL'; exit 2 }
  Write-Output 'SIZE-PARSER-PARITY SELF-TEST PASS - a null against a number, a pack count apart, and the frozen corpus all decide correctly'
  exit 0
}

# ASSIGN, THEN WRAP. Get-TcSizeParityCorpus returns `,$array`, so `@(Get-TcSizeParityCorpus)` is ONE element
# that IS the array (.claude/rules/ops-and-gates.md: "Never wrap a function call inline as @(Get-Thing ...)").
# Coerced into [string[]]$Rows below, that one element joined the whole corpus into a single space-separated
# string and the first price parsed as "5.58 12 ct 10.75 oz". Caught by running the -Board arm; the frozen
# arm assigned first and was fine, which is exactly how this trap stays hidden.
$corpusRows = Get-TcSizeParityCorpus
$rows = @($corpusRows)
$scope = 'the frozen corpus'
if ($Board) {
  $boardRows = Get-TcBoardSizeRows -Root $root
  if ($null -eq $boardRows) {
    Write-Output 'BLIND: -Board was asked for and there is no grocery\out\comparison-*.json in this checkout, so no board size string was compared. The boards are gitignored, so a worktree and a clean checkout are blind here.'
    Write-GuardComplete -Name 'size-parser-parity' -Summary 'no board to read'
    exit 3
  }
  $rows = @($rows + $boardRows)
  $scope = "the frozen corpus plus $($boardRows.Count) size string(s) on the newest board"
}
$res = Invoke-TcSizeParityRun -Rows $rows
Write-Output ("size-parser-parity: $($res.findings.Count) disagreement(s) over $($res.comparable) comparable of $($res.examined) size string(s) examined, from $scope")
$res.findings | ForEach-Object { Write-Output ('  ' + $_) }
if ($res.findings.Count) {
  Write-Output '  ONE RULE MAY NOT HAVE TWO ANSWERS. Which reader is right is the question to answer next; what is'
  Write-Output '  certain is that the board is priced by Get-SizeAmount and audited by Get-LinkPerUnit, so a string'
  Write-Output '  only one of them can read is a cell the audits cannot judge, and a cell they judge differently is'
  Write-Output '  a guard finding nobody can act on. Fix the reader that is wrong; never widen the tolerance.'
  Write-GuardComplete -Name 'size-parser-parity' -Summary ("$($res.findings.Count) disagreement(s) over $($res.comparable) comparable size string(s)")
  exit 2
}
Write-GuardComplete -Name 'size-parser-parity' -Summary ("scanned=$($res.examined) comparable=$($res.comparable) findings=0")
exit 0
