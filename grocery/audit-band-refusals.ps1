<#
  audit-band-refusals.ps1 - EVERY ROW A PRICE BAND REFUSES MUST BE EXPLAINED AS A BASIS ERROR.
  HOLD SCOPE: board - advisory: it pages and never holds the board (a refusal already kept the row off it)

  Brad, 2026-09-22, on moving every commodity to derived bands: "We need to fix it now, properly, and to make sure we
  are future proof so this doesn't happen again. I dont care how long it takes."

  WHY. A price band has ONE job: refuse a price that is off by a basis error (a pack price read per piece, ounces read
  as pounds, a dropped decimal). On 2026-09-22 the typed band floors turned out to be doing a SECOND, invisible job:
  keeping wrong products off the board (Clancy's Himalayan Pink Salt POPCORN as salt, a jalapeno HUMMUS as jalapenos,
  a butter SEASONING as butter, a smoked-SALMON bowl as cooked quinoa). A band that hides a wrong product is a second,
  invisible copy of the identity rules (gap F1 of design/RCA-holistic-2026-09-22.md), and it fails open the day the
  band moves - which is exactly what switching to derived bands did. The wrong products were fixed at identity
  (commodity excludes); this check keeps the class closed.

  THE RULE. For every row the engine's flagged-<date>.json records as refused by a band (band_ref present), ratio
  r = per-unit / band reference. The refusal is EXPLAINED when the row itself carries the evidence of a basis error:
    - a pack or count N stated in its name or size (N pk, N ct, N count, pack of N, N-pack) with r*N or r/N within
      $BasisTol of 1 (a pack price read per piece, or a piece price read per pack);
    - r or 1/r within 10% of a unit conversion THE COMMODITY'S UNIT can produce: 16 (oz/lb), 128 and 32 (fl oz against a
      gallon or quart), 12 (each/dozen), 100 (cents/dollars), 1000 (g/kg). By unit, because the founding popcorn row sits at
      11.6x salt's reference, and a dozen means nothing on an ounce commodity;
    - r or 1/r of at least 50 (an order-of-magnitude-and-more parse error no real product explains).
  Anything else is UNEXPLAINED: the identity rules matched the row to the commodity, and its price is merely unusual,
  so it is either a wrong product the band is hiding (fix at identity: an exclude, per Brad's shape ruling) or a real
  bargain or premium the band is censoring (fix the band's derivation, never its number). Either way it PAGES, naming
  the row, with the resolver lane:grocery/apply-coverage-batch.ps1 (the gated exclude road: every MOVED and DROPPED line reviewed, then audit-match-soundness -Accept).
  $BasisTol = 0.25 and 50 are FIRST PLAUSIBLE NUMBERS, nothing else tried.

  A RATCHET, not a gate red on day one: the unexplained rows on the first measured board are the backlog
  (band-refusals-backlog.json, keyed by row, may only shrink; see the note above Get-TcRefusalKey). Exit 0 = no
  unexplained row outside the backlog, 2 = at least one NEW one (each printed by name), 3 = BLIND (no flagged file, none
  carrying band_ref, or no backlog recorded). What it does when the producer STOPS: no flagged file, or one built with
  no derived bands, is exit 3 and pages as could-not-evaluate, never as clean.
  SCOPE OF A CLEAN REPORT: UNSOUND - a wrong product whose price happens to reproduce a unit conversion is read as a
  basis error. A finding is a candidate for a person or the matching lane, not a verdict.

  Usage: .\audit-band-refusals.ps1 [-OutDir <dir>] [-Date yyyy-MM-dd] | -SelfTest
#>
param([string]$OutDir = '', [string]$Date = '', [string]$BacklogFile = '', [switch]$Accept, [switch]$Tighten, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# THE MARK IS A BACKLOG OF NAMED ROWS, not a bare count (measured 2026-09-22: 1,465 band-refused rows on the first all-derived
# board, 221 explained as basis errors and 1,244 not, almost all wrong products refused on the DEAR side - apple rice cakes and
# smoked gouda as apples, fully cooked bacon as bacon). A count ratchet at 1,244 would page on ordinary capture churn and
# mail all of them. So the 1,244 are recorded by key (id|store|name) in grocery\band-refusals-backlog.json: they are the
# matching lane's worklist, and a run PAGES only on an unexplained row that is NOT in the backlog, naming it. The backlog may
# only SHRINK: -Tighten drops keys that no longer occur, -Accept records the current set (the founding run, or a reviewed
# reset), and a plain run never writes it (.claude/rules/ops-and-gates.md, a ratchet's mark).
if (-not $BacklogFile) { $BacklogFile = Join-Path $root 'band-refusals-backlog.json' }
function Get-TcRefusalKey($Row) { return (([string]$Row.id) + '|' + ([string]$Row.store) + '|' + ([string]$Row.name)) }
function Get-TcNewRefusals($Unexplained, [hashtable]$Backlog) {
  $new = New-Object System.Collections.ArrayList
  foreach ($u in @($Unexplained)) { if ($null -ne $u -and -not $Backlog.ContainsKey((Get-TcRefusalKey $u))) { [void]$new.Add($u) } }
  return ,($new.ToArray())
}
$BasisTol = 0.25
# Unit conversions a basis error can produce, BY THE COMMODITY'S UNIT: a 12x ratio on an ounce commodity is not a dozen.
$script:TcConversionsByUnit = @{ oz = @(16.0, 100.0, 1000.0); lb = @(16.0, 100.0, 1000.0); floz = @(128.0, 32.0, 16.0, 100.0, 1000.0); gallon = @(128.0, 32.0, 100.0); each = @(12.0, 100.0); dozen = @(12.0, 100.0) }
$script:TcConversionTol = 0.1   # a conversion is exact, so it is judged tighter than a pack count; first plausible number

function Get-TcRowCounts([string]$Text) {
  $out = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches(([string]$Text).ToLower(), '(?:(\d+)\s*-?\s*(?:pk|pack|packs|ct|count|ea|each|pc|pcs|pieces?|bags?|cans?|bottles?)\b|pack\s+of\s+(\d+)|\((\d+)\s*pack\))')) {
    foreach ($gi in 1..3) { if ($m.Groups[$gi].Success) { $v = [double]$m.Groups[$gi].Value; if ($v -gt 1 -and -not ($out -contains $v)) { [void]$out.Add($v) } } }
  }
  return ,($out.ToArray())
}

function Test-TcNear([double]$A, [double]$B, [double]$Tol) { if ($B -le 0) { return $false }; return ([math]::Abs(($A / $B) - 1.0) -le $Tol) }

function Get-TcRefusalExplanation($Row, [double]$Tol = 0.25) {
  # '' when UNEXPLAINED, else the basis error that explains it.
  $ref = [double]$Row.band_ref; $pu = [double]$Row.unit_price
  if ($ref -le 0 -or $pu -le 0) { return 'no reference' }
  $r = $pu / $ref; $inv = $ref / $pu
  if ($r -ge 50 -or $inv -ge 50) { return ('order of magnitude (x' + ('{0:0.#}' -f [math]::Max($r, $inv)) + ')') }
  foreach ($n in (Get-TcRowCounts ([string]$Row.name + ' ' + [string]$Row.size_text))) {
    if ((Test-TcNear $r $n $Tol) -or (Test-TcNear $inv $n $Tol)) { return ('pack count ' + $n) }
  }
  $u = if ($Row.PSObject.Properties['unit']) { [string]$Row.unit } else { '' }
  $convs = if ($script:TcConversionsByUnit.ContainsKey($u)) { $script:TcConversionsByUnit[$u] } else { @(100.0, 1000.0) }
  foreach ($k in $convs) { if ((Test-TcNear $r $k $script:TcConversionTol) -or (Test-TcNear $inv $k $script:TcConversionTol)) { return ('unit conversion x' + $k) } }
  return ''
}

function Invoke-TcBandRefusalAudit($Rows) {
  $un = New-Object System.Collections.ArrayList; $ex = 0; $n = 0
  foreach ($r in @($Rows)) {
    if ($null -eq $r -or -not $r.PSObject.Properties['band_ref'] -or $null -eq $r.band_ref) { continue }
    $n++
    $why = Get-TcRefusalExplanation $r $BasisTol
    if ($why) { $ex++ } else { [void]$un.Add($r) }
  }
  return [pscustomobject]@{ examined = $n; explained = $ex; unexplained = $un.ToArray() }
}

if ($SelfTest) {
  $bad = 0; $cases = 0
  function Bc([string]$l, [bool]$ok) { $script:cases++; if ($ok) { Write-Output ('ok    ' + $l) } else { Write-Output ('FAIL  ' + $l); $script:bad++ } }
  # frozen from comparison-2026-09-22's first all-derived dry run
  $popcorn = [pscustomobject]@{ id = 'salt'; store = 'Aldi'; unit = 'oz'; name = 'Clancy S Coconut Oil Himalayan Pink Salt Popcorn 4.6 OZ'; unit_price = 0.4326; band_ref = 0.0373; size_text = '4.6 OZ' }
  Bc 'MUST FIRE  the pink-salt popcorn refused only by the band (0.4326 against salt''s 0.0373, no pack or unit story) is UNEXPLAINED' ((Get-TcRefusalExplanation $popcorn) -eq '')
  $chk = [pscustomobject]@{ id = 'canned-chicken'; store = 'Walmart'; name = '(8 pack) Great Value Chunk Chicken Breast with Rib Meat in Water, 12.5 oz Can'; unit_price = 0.0275; band_ref = 0.2273; size_text = '12.5 oz' }
  Bc 'MUST NOT FIRE  an 8-pack price read per can (0.0275 against 0.2273, x8.3) is a basis error the band exists to refuse' ((Get-TcRefusalExplanation $chk) -like 'pack count 8')
  $oz = [pscustomobject]@{ id = 'ground-beef'; store = "Baker's"; unit = 'lb'; name = 'Kroger 80/20 Ground Beef'; unit_price = 0.3125; band_ref = 5.0; size_text = 'lb' }
  Bc 'MUST NOT FIRE  a per-ounce price read as per-pound (x16) is a unit-conversion basis error' ((Get-TcRefusalExplanation $oz) -like 'unit conversion x16')
  $dec = [pscustomobject]@{ id = 'grits'; store = 'Walmart'; name = 'Quaker Old Fashioned Grits 24 oz'; unit_price = 0.0023; band_ref = 0.135; size_text = '24 oz' }
  Bc 'MUST NOT FIRE  the 2026-07-27 grits decimal-drop (x58) is an order-of-magnitude basis error' ((Get-TcRefusalExplanation $dec) -like 'order of magnitude*')
  $bulk = [pscustomobject]@{ id = 'bay-leaves'; store = "Sam's Club"; name = "Member's Mark Whole Bay Leaves, 2 oz."; unit_price = 4.27; band_ref = 25.1667; size_text = '2 oz' }
  Bc 'MUST FIRE  a real bulk price that a band DID refuse (bay leaves 4.27 against a retail reference of 25.17, no pack or unit story) is UNEXPLAINED and pages: that is the loop that moves the warehouse allowance' ((Get-TcRefusalExplanation $bulk) -eq '')
  # CLEAN TWIN over the band itself: the same real Sam's row, with the retail store numbers frozen from the derived-arm
  # board of 2026-09-22, is ADMITTED by the warehouse floor, so on the live board it never reaches this audit at all.
  . (Join-Path $root 'derived-band-lib.ps1')
  $bayRows = @(@('R1', 7.9733), @('R2', 25.1667), @('R3', 31.9333), @("Sam's Club", 4.27)) | ForEach-Object { [pscustomobject]@{ id = 'bay-leaves'; store = $_[0]; per_unit = $_[1] } }
  $bayBand = (Get-TcDerivedBands -Rows $bayRows -Groups @{ "Sam's Club" = 'warehouse' })['bay-leaves']
  Bc 'CLEAN TWIN  the real Sam''s bulk bay leaves (4.27/oz) are ADMITTED by their derived band''s warehouse floor' (Test-TcInBand $bayBand 4.27 'warehouse')
  Bc 'BAR  a pack count exactly AT the tolerance (r = 8 x 1.25 = 10 against an 8-pack) is explained' ((Get-TcRefusalExplanation ([pscustomobject]@{ name = 'x 8 pack'; unit_price = 10.0; band_ref = 1.0; size_text = '' })) -like 'pack count 8')
  Bc 'BAR  one step past it (r = 10.25 against an 8-pack) is not' ((Get-TcRefusalExplanation ([pscustomobject]@{ name = 'x 8 pack'; unit_price = 10.25; band_ref = 1.0; size_text = '' })) -eq '')
  $a = Invoke-TcBandRefusalAudit @($popcorn, $chk, $bulk, [pscustomobject]@{ id = 'x'; unit_price = 1; band = '1-2' })
  Bc 'MECHANISM  a flagged row with no band_ref (a typed band, or another refusal) is not examined' ($a.examined -eq 3 -and @($a.unexplained).Count -eq 2)
  $bl = @{ (Get-TcRefusalKey $bulk) = $true }
  $nw = Get-TcNewRefusals @($popcorn, $bulk) $bl
  Bc 'MUST FIRE  an unexplained row NOT in the backlog (the popcorn) is NEW and pages by name' (@($nw).Count -eq 1 -and $nw[0].name -eq $popcorn.name)
  Bc 'MUST NOT FIRE  an unexplained row already in the backlog (the bay leaves) is the worklist, not a new page' (-not (@($nw) | Where-Object { $_.name -eq $bulk.name }))
  Write-Output ('band-refusals self-test ' + $(if ($bad -eq 0 -and $cases -eq 11) { 'pass' } else { 'FAIL' }) + ': ' + ($cases - $bad) + ' of ' + $cases + ' case(s) (11 expected)')
  exit $(if ($bad -eq 0 -and $cases -eq 11) { 0 } else { 1 })
}

. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
$ff = if ($Date) { Get-Item (Join-Path $OutDir ('flagged-' + $Date + '.json')) -ErrorAction SilentlyContinue } else { Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^flagged-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1 }
if (-not $ff) { Write-Output 'band-refusals: BLIND - no flagged-<date>.json to read'; Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-flagged'; exit 3 }
$doc = Read-JsonFile $ff.FullName
$res = Invoke-TcBandRefusalAudit @($doc.flagged)
if ($res.examined -eq 0) { Write-Output ('band-refusals: BLIND - ' + $ff.Name + ' carries no band-refused row with a band_ref (built before the derived bands?)'); Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-band-ref'; exit 3 }
$un = @($res.unexplained)
. (Join-Path $repo 'lib\lf-write.ps1')
$backlog = @{}
$haveBacklog = Test-Path -LiteralPath $BacklogFile
if ($haveBacklog) { foreach ($k in @((Read-JsonFile $BacklogFile).keys)) { if ($k) { $backlog[[string]$k] = $true } } }
if (-not $haveBacklog -and -not $Accept) { Write-Output ('band-refusals: BLIND - no backlog at ' + $BacklogFile + '; record the founding one with -Accept'); Write-GuardComplete -Name 'band-refusals' -Summary 'blind=no-backlog'; exit 3 }
$curKeys = @{}; foreach ($u in $un) { $curKeys[(Get-TcRefusalKey $u)] = $true }
if ($Accept -or $Tighten) {
  # -Tighten may only SHRINK the backlog (keys that still occur survive); -Accept records exactly the current set.
  $keep = if ($Accept) { @($curKeys.Keys) } else { @($backlog.Keys | Where-Object { $curKeys.ContainsKey($_) }) }
  $bdoc = [ordered]@{ note = 'Band-refused rows no basis error explains, by key id|store|name: the matching lane''s worklist (lane:grocery/apply-coverage-batch.ps1). Written only by audit-band-refusals.ps1 -Accept or -Tighten; a plain run never writes it. May only shrink.'; recorded = (Get-Date).ToString('yyyy-MM-dd'); from = $ff.Name; count = $keep.Count; keys = @($keep | Sort-Object) }
  $null = Write-TcLfFile -Path $BacklogFile -Text ($bdoc | ConvertTo-Json -Depth 4) -NoBom
  Write-Output ('band-refusals: backlog ' + $(if ($Accept) { 'ACCEPTED' } else { 'TIGHTENED' }) + ' at ' + $keep.Count + ' key(s) (was ' + $backlog.Count + ')')
  $backlog = @{}; foreach ($k in $keep) { $backlog[[string]$k] = $true }
}
$new = Get-TcNewRefusals $un $backlog
$gone = @($backlog.Keys | Where-Object { -not $curKeys.ContainsKey($_) }).Count
Write-Output ('band-refusals: ' + $res.examined + ' band-refused row(s) in ' + $ff.Name + ': ' + $res.explained + ' explained as a basis error, ' + $un.Count + ' unexplained, of which ' + $new.Count + ' NEW (not in the backlog of ' + $backlog.Count + '); ' + $gone + ' backlog key(s) no longer occur' + $(if ($gone -gt 0) { ' (ratchet CAN tighten: -Tighten)' } else { '' }))
foreach ($u in ($new | Sort-Object id)) { Write-Output ('  UNEXPLAINED  ' + $u.id + ' | ' + $u.store + ' | ' + ('{0:0.####}' -f [double]$u.unit_price) + ' against reference ' + $u.band_ref + ' | ' + $u.name + '   resolver: lane:grocery/apply-coverage-batch.ps1 (a wrong product -> an exclude) or the band derivation (a real price)') }
Write-GuardComplete -Name 'band-refusals' -Summary ('scanned=' + $res.examined + ' explained=' + $res.explained + ' unexplained=' + $un.Count + ' findings=' + $new.Count + ' backlog=' + $backlog.Count)
exit $(if ($new.Count -gt 0) { 2 } else { 0 })
