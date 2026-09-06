<#
  audit-pack-basis.ps1 - catches the MULTIPACK TOTAL read as an EACH-SIZE (2026-07-28).

  The engine's count-first idiom ("24 ct 16.9 fl oz") means 24 bottles OF 16.9 oz, so it multiplies to a
  405.6 oz total. That is right for water, vinegar and grits. It is WRONG when the store already printed the
  pack TOTAL after the count: Sam's "Pledge Furniture Polish, 3 ct., 29 oz." is three 9.7 oz cans totalling
  29 oz, and multiplying gave 87 oz -> $0.14/oz, which made Sam's the cheapest furniture polish in Omaha at
  a third of the real price. Text alone cannot tell the two apart, so this audit uses ARITHMETIC:

    when the multiplied reading makes a cell a large outlier under every other store, AND no other store
    sells anything near the each-size that reading implies, the multiply is what created the outlier.

  BOTH conditions are needed. The outlier test alone would flag genuine bulk: a 24 ct x 16.9 fl oz water
  case really is 65% under the single-bottle stores, and its pack-total reading really would look absurd.
  What separates it from Pledge is CORROBORATION of the each-size: peers sell 16.9 fl oz bottles, so
  reading 16.9 as the each-size is confirmed by the market; nobody sells a 29 oz can of furniture polish,
  while three stores sell the 9.7 oz can that 29/3 implies. That is exactly how a human resolves it, and it
  is the check that keeps this guard quiet on real bulk.

  Advisory by design (exit 0 with findings, 2 only on -Strict): it names cells for a human decision instead
  of silently dropping a price.

  EXCEPT for the one subset that is DECIDABLE, which blocks (2026-08-02). Advisory was not enough: this
  audit named the Pledge row at 09:03 and the board published the wrong crown anyway, because nothing in
  the publish path reads a report. When stated-size / count reproduces the single-unit size a peer store
  actually sells (29/3 = 9.67 against four stores' 9.7 oz cans), the printed number was the pack TOTAL and
  the multiplied basis is wrong by a factor of the count - provable arithmetic, not a judgement call. Those
  findings now exit 2 and guards.ps1 delegates to this audit, so the board cannot ship over one. The
  genuinely ambiguous rest stays advisory exactly as before.

  Usage: audit-pack-basis.ps1 [-CompareFile <path>] [-Strict]
  Exit:  0 ok / advisory findings only, 2 at least one CONFIRMED pack-total (or -Strict with any finding)
#>
# -ReportDir: where pack-basis-audit.json is written. Defaults to out\, which is the live daily behaviour and
# is unchanged. It exists so a FIXTURE run can park its report beside its fixture instead of overwriting the
# live one: test-auditors passes fixture boards via -CompareFile but the report path was hardcoded, so every
# harness run left out\pack-basis-audit.json describing 'packbasis-legit-bulk-board.json' with 0 findings -
# a fixture's clean result sitting exactly where a human (or the next audit) looks for the real board's.
# -AllowFile parameterises the RULINGS list so a FIXTURE is never at the mercy of a live ruling
# (2026-09-05). Adding suppression immediately broke the hummus clean-twin case: that drill proves the
# arithmetic FINGERPRINT does not condemn a correct per-item pack, and it identifies the row by finding it
# in the output - so a real ruling on the real hummus row silenced the test that proves the fingerprint is
# not over-broad. A fixture whose outcome depends on production data is not a fixture. Default is the live
# list; the drill passes its own path.
param([string]$CompareFile = "", [switch]$Strict, [string]$ReportDir = "", [string]$AllowFile = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
$doc = Read-JsonFile $CompareFile

# how far under the next-cheapest store counts as "an outlier this audit should explain"
$OUTLIER = 0.35
# how close a peer's package size has to be to count as corroborating an each-size reading
$SIZE_TOL = 0.15
# how close stated-size/count has to land to a peer's single-unit size to PROVE the stated size was the
# pack total. Tighter than $SIZE_TOL on purpose: corroboration only has to be plausible, but this one
# hard-fails a publish, so it has to be an arithmetic identity rather than a resemblance.
$FP_TOL = 0.05
# A RULED ROW MUST BE ABLE TO GO QUIET (2026-09-05). This audit reported every ambiguous pack on every run
# with no way to mark one reviewed, so a ruling could never close anything and the same lines scrolled past
# forever. That is the estate's own complaint about an alarm with no repair lane, aimed at itself: an
# advisory nobody can act on is an advisory nobody reads, and the genuine CONFIRMED-PACK-TOTAL finding
# would eventually be lost in the standing noise.
# The ruling lives in multipack-allowlist.json - the SAME file guard 5 reads - because a pack this audit
# has cleared and a pack the publish gate has cleared must never be two different lists.
# A CONFIRMED-PACK-TOTAL finding is NOT suppressible. That is the arithmetic fingerprint, it is a hard
# fail by design, and letting a ruling silence it would turn the allowlist into a way to publish a known
# bad number.
$ruled = @{}
try {
  $alf = if ($AllowFile) { $AllowFile } else { Join-Path $root 'multipack-allowlist.json' }
  if (Test-Path $alf) {
    foreach ($e in @((Read-JsonFile $alf).allow)) {
      $k = (('' + $e.store).Trim() + '|' + ('' + $e.item).Trim()).ToLower()
      if ($k -ne '|') { $ruled[$k] = ('' + $e.why) }
    }
  }
} catch { $ruled = @{} }   # an unreadable allowlist must not silence anything
$findings = @()
$ruledQuiet = 0
$confirmedCount = 0

function ToUnit([double]$num, [string]$token, [string]$unit) {
  $t = $token.ToLower().Trim().TrimEnd('.')
  switch ($unit) {
    'lb'     { if ($t -match '^(lb|lbs|pound|pounds)$') { return $num }; if ($t -match '^(oz|ounce|ounces)$') { return $num/16.0 }; return $null }
    'oz'     { if ($t -match '^(oz|ounce|ounces|fl\s*oz|floz)$') { return $num }; if ($t -match '^(lb|lbs|pound|pounds)$') { return $num*16.0 }; return $null }
    'floz'   { if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num }; if ($t -match '^(gal|gallon|gallons)$') { return $num*128.0 }
               if ($t -match '^(qt|quart|quarts)$') { return $num*32.0 }; if ($t -match '^(pt|pint|pints)$') { return $num*16.0 }; if ($t -match '^(ml)$') { return $num/29.5735 }; return $null }
    'gallon' { if ($t -match '^(gal|gallon|gallons)$') { return $num }; if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num/128.0 }; return $null }
  }
  return $null
}
# the package size a store row states, in the commodity's unit ($null when it does not state one)
function RowSize([string]$sizeText, [string]$unit) {
  if (-not $sizeText) { return $null }
  $s = $sizeText.ToLower()
  # for a count-first multipack the EACH size is the second number, which is what we want to compare
  $mm = [regex]::Match($s, '^\s*\d+(?:\.\d+)?\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
  if ($mm.Success) { return (ToUnit ([double]$mm.Groups[1].Value) $mm.Groups[2].Value $unit) }
  $m = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|ml)\b')
  if ($m.Success) { return (ToUnit ([double]$m.Groups[1].Value) $m.Groups[2].Value $unit) }
  return $null
}

foreach ($r in $doc.comparison) {
  $rows = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
  if ($rows.Count -lt 2) { continue }
  $ranked = @($rows | Sort-Object { [double]$_.per_unit })
  foreach ($s in $ranked) {
    $size = [string]$s.size
    # the count-first idiom the engine multiplies on
    $m = [regex]::Match($size.ToLower(), '^\s*(\d+(?:\.\d+)?)\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
    if (-not $m.Success) { continue }
    $cnt = [double]$m.Groups[1].Value
    if ($cnt -le 1) { continue }
    $published = [double]$s.per_unit
    # the alternative reading: the printed size was the pack TOTAL, so the price divides by it, not by count*it
    $asTotal = $published * $cnt
    # cheapest OTHER store on this commodity
    $others = @($ranked | Where-Object { $_.store -ne $s.store } | ForEach-Object { [double]$_.per_unit })
    if ($others.Count -eq 0) { continue }
    $peer = ($others | Sort-Object)[0]
    if ($peer -le 0) { continue }
    $underNow  = (($peer - $published) / $peer)
    $underThen = (($peer - $asTotal) / $peer)
    if (-not ($underNow -ge $OUTLIER -and $underThen -lt $OUTLIER)) { continue }
    # CORROBORATION. The published reading says each unit in this pack is $each big. If any other store
    # sells a package about that size, the market confirms the reading and this is real bulk, not a bug.
    $each = ToUnit ([double]$m.Groups[2].Value) $m.Groups[3].Value ([string]$r.unit)
    $peerSizes = @($ranked | Where-Object { $_.store -ne $s.store } | ForEach-Object { RowSize ([string]$_.size) ([string]$r.unit) } | Where-Object { $_ -ne $null -and $_ -gt 0 })
    if ($each -ne $null -and $each -gt 0) {
      $confirmed = @($peerSizes | Where-Object { [math]::Abs($_ - $each) / $each -le $SIZE_TOL })
      if ($confirmed.Count -gt 0) { continue }   # another store sells that each-size: the multiply is right
    }
    # THE ARITHMETIC FINGERPRINT OF A PACK TOTAL (2026-08-02, promoted to BLOCKING).
    #
    # Everything above is a suspicion: it says the multiply created an outlier and nothing corroborates the
    # each-size it assumes. That is enough to name a cell for a human, which is why this audit shipped
    # advisory. It is NOT enough to refuse a publish, because the count-first idiom is genuinely ambiguous -
    # Sam's writes "6 ct., 3.5 oz." meaning 3.5 oz PER TABLET and "3 ct., 29 oz." meaning 29 oz TOTAL with
    # the same grammar.
    #
    # There is exactly one locally decidable case, and it is arithmetic rather than text. If the printed
    # number is the pack TOTAL, then total/count is the SINGLE-UNIT size, and a single-unit size is the
    # thing other stores sell. Sam's Pledge: 29/3 = 9.67, and Family Fare, Hy-Vee, Baker's and Walmart all
    # sell the 9.7 oz can - 0.34 percent apart. The multiplied 87 oz can then only be wrong, so the wrong
    # crown ($0.1439/oz against a true $0.4317) is provable without asking anyone.
    #
    # This does NOT fire on a true per-item pack. There the printed number IS the per-item size, so the peer
    # match lands on $each and the corroboration branch above already returned. total/count is a size nobody
    # sells: the Member's Mark hummus 16 ct / 2.5 oz singles give 2.5/16 = 0.156 oz against peers at 8, 10
    # and 17 oz, so the fingerprint stays silent and that finding stays advisory. Both cases are frozen in
    # test-auditors.ps1 as the must-fire and the clean twin.
    $fpConfirmed = $false; $fpEach = $null; $fpPeer = $null
    if ($each -ne $null -and $each -gt 0 -and $cnt -gt 0) {
      $derived = $each / $cnt
      if ($derived -gt 0) {
        foreach ($ps in $peerSizes) {
          if ([math]::Abs($ps - $derived) / $derived -le $FP_TOL) { $fpConfirmed = $true; $fpEach = $derived; $fpPeer = $ps; break }
        }
      }
    }
    # published reading is a big outlier, the pack-total reading is not, and nothing on the market sells
    # the each-size the multiply assumes -> the multiply is what created the outlier
    # A ruled pack goes quiet - UNLESS the fingerprint condemned it, which no ruling may silence.
    $rk = (([string]$s.store).Trim() + '|' + ([string]$s.item).Trim()).ToLower()
    $isRuled = ($ruled.ContainsKey($rk) -and -not $fpConfirmed)
    if ($isRuled) { $ruledQuiet++ }
    if (-not $isRuled) {
      $findings += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; store = [string]$s.store
        unit = [string]$r.unit; published = [math]::Round($published,4)
        as_pack_total = [math]::Round($asTotal,4); peer_cheapest = [math]::Round($peer,4)
        count = $cnt; size = $size; ad = [string]$s.ad; item = [string]$s.item
        fingerprint = $(if ($fpConfirmed) { 'CONFIRMED-PACK-TOTAL' } else { 'undecidable' })
        each_derived = $(if ($fpConfirmed) { [math]::Round($fpEach,4) } else { $null })
        peer_single_unit = $(if ($fpConfirmed) { [math]::Round($fpPeer,4) } else { $null })
      }
      if ($fpConfirmed) { $confirmedCount++ }
    }
  }
}

$rep = Join-Path $(if ($ReportDir) { $ReportDir } else { $OutDir }) 'pack-basis-audit.json'
([pscustomobject]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); compare_file = (Split-Path $CompareFile -Leaf); finding_count = $findings.Count; confirmed_count = $confirmedCount; findings = $findings } |
  ConvertTo-Json -Depth 5) | Set-Content $rep -Encoding UTF8

$ruledNote = $(if ($ruledQuiet) { " ($ruledQuiet ruled in multipack-allowlist.json, not re-reported)" } else { '' })
if ($findings.Count -eq 0) { Write-Output ('pack-basis: ok - no multipack cell owes its cheapest-in-Omaha rank to the count multiply' + $ruledNote); Write-GuardComplete -Name 'pack-basis' -Summary $ruledNote.Trim(); exit 0 }
Write-Output ("pack-basis: " + $findings.Count + " cell(s) are cheapest ONLY because a pack count was multiplied into the size - verify the size is per-item, not the pack total:")
foreach ($f in $findings) {
  Write-Output ("  {0,-24} {1,-12} published {2}/{3} vs {4} as a pack total (peer {5}) | size '{6}' | {7}" -f `
    $f.id, $f.store, $f.published, $f.unit, $f.as_pack_total, $f.peer_cheapest, $f.size, $f.item)
  if ($f.fingerprint -eq 'CONFIRMED-PACK-TOTAL') {
    Write-Output ("      CONFIRMED PACK TOTAL: {0} / {1} = {2} {3}, which is the single-unit size a peer store actually sells ({4} {3}). The multiplied basis is provably wrong." -f `
      $f.size, $f.count, $f.each_derived, $f.unit, $f.peer_single_unit)
  }
}
Write-Output ("  report: " + $rep)
if ($confirmedCount -gt 0) {
  Write-Output ("PACK-BASIS BLOCKED: " + $confirmedCount + " cell(s) carry the arithmetic fingerprint of a pack TOTAL read as an each-size. That is not a judgement call, it is stated-size/count reproducing a size other stores sell, so the published per-unit is wrong by a factor of the count. Correct the size at capture, or rule the row wrong with add-known-wrong.ps1, then rebuild. Do NOT publish over this.")
  Write-GuardComplete -Name 'pack-basis'
  exit 2
}
# above the -Strict branch, not below it: all three of these are completed runs and only differ in verdict
Write-GuardComplete -Name 'pack-basis' -Summary ''
if ($Strict) { exit 2 }
exit 0
