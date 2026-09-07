<#
  audit-price-claims.ps1 - a price comparison on a live page is re-checked against the board, weekly.

  WHY THIS EXISTS (2026-09-07, backlog E6, Brad: "what is the best approach for a LONG TERM
  solution"). E6 shipped a DECLARATION plus a ratchet: the writer states the claims its card rests on,
  and the gate counts prose assertions it did not declare. Measured on the live corpus today, that
  produced 332 undeclared price comparisons - of which 11 carry a number, and none is contradicted by
  the board. So the count is the house voice, not a defect list, and no amount of declaring would
  change that.

  THE PART A DECLARATION CANNOT DO IS THE PART THAT MATTERS: THESE CLAIMS DECAY.

    "Ground turkey usually undercuts ground beef by a couple dollars a pound"

  is true on 2026-09-07 - Ground Turkey $2.663/lb against 93/7 Lean Ground Beef $6.17/lb. If beef
  falls to $3.00 in November, that sentence on a live paid page becomes FALSE, and nothing in this
  estate would notice. A declaration is a one-time act. The board is rebuilt every day. **Only a
  standing re-check can catch "true in August, false in November"**, and that is the whole argument
  for this file existing rather than a longer list of declarations.

  SO THE DECLARATION BECOMES THE INPUT TO A CHECK, not an echo of the prose. A spec may carry:

      "price_claims": [
        { "cheaper": "ground-turkey", "dearer": "ground-beef-9307",
          "basis": "per lb", "says": "Ground turkey usually undercuts ground beef ..." }
      ]

  and this resolves both ids against the newest board and asks whether the claim is still true. That
  is a question with an answer, which "declare what you asserted" never was.

  GREEN ON DAY ONE BY CONSTRUCTION: no spec declares one yet, so there is nothing to contradict. It
  grows as claims are declared, and the first declaration is immediately worth more than the 332
  undeclared ones, because it is the only one anybody can check.

  IT DOES NOT PARSE PROSE. Two attempts to classify these sentences mechanically were wrong on
  2026-09-07 - the second reported "only 4 are checkable" because it read a pantry-package table as
  the commodity list. The writer names the two ids; this file only ever reads ids.

  DATA-DEPENDENT, so it is NOT in run-gates: comparison-*.json is gitignored, so a worktree or a clean
  checkout has no board and this would be BLIND there. Its pure half is covered by -SelfTest, which
  run-gates does discover.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File meal-prep\pipeline\audit-price-claims.ps1 -SelfTest
#>
param(
  [switch]$SelfTest,
  [string]$BoardFile = '',
  # A FILE, NOT STDOUT. Every exit path here owes a PRICE-CLAIMS-COMPLETE marker as its LAST stdout
  # line (lib\guard-contract.ps1), and a JSON payload on stdout either swallows the marker or is
  # corrupted by it. Writing the machine-readable copy to a file keeps both honest - and the
  # guard-contract audit caught exactly this the first time it ran.
  [string]$JsonOut = ''
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep\pipeline' }
$repo = Split-Path (Split-Path $here -Parent) -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$SPEC_DIR = Join-Path $repo 'meal-prep\db\recipes'
$OUT_DIR  = Join-Path $repo 'grocery\out'

# A claim is only worth calling FALSE when the board disagrees by more than the noise in its own
# numbers. Two commodities a cent apart are not a refuted claim, they are a tie - and reporting a tie
# as a contradiction is how a check like this gets switched off.
$TIE_PCT = 5.0

function Get-TcBoardPrices {
  <# commodity id -> cheapest per-unit, from a board document. Pure, so the fixtures drive it. #>
  param($Board)
  $h = @{}
  foreach ($r in @($Board.comparison)) {
    $id = [string]$r.id
    if (-not $id) { continue }
    if ($null -ne $r.cheapest_price) { $h[$id] = [double]$r.cheapest_price }
  }
  return $h
}

function Test-TcPriceClaim {
  <# Is this claim still true on this board? Returns @{ Verdict; Why }.

     Verdicts:
       supported     the board agrees, by more than a tie
       tie           the two are within TIE_PCT - not a refutation, and saying so is what keeps this
                     check credible
       CONTRADICTED  the board says the 'cheaper' side costs MORE. A wrong number on a live paid page.
       unpriceable   one side is not on the board, so the claim cannot be checked either way - and
                     that is reported, never counted as agreement #>
  param($Claim, $Prices, [double]$TiePct = 5.0)
  $c = [string]$Claim.cheaper
  $d = [string]$Claim.dearer
  if (-not $c -or -not $d) {
    return [pscustomobject]@{ Verdict = 'unpriceable'; Why = 'the claim names no cheaper/dearer pair' }
  }
  if (-not $Prices.ContainsKey($c)) {
    return [pscustomobject]@{ Verdict = 'unpriceable'; Why = ("'{0}' is not priced on this board, so the claim cannot be checked - NOT evidence that it holds" -f $c) }
  }
  if (-not $Prices.ContainsKey($d)) {
    return [pscustomobject]@{ Verdict = 'unpriceable'; Why = ("'{0}' is not priced on this board, so the claim cannot be checked - NOT evidence that it holds" -f $d) }
  }
  $pc = [double]$Prices[$c]
  $pd = [double]$Prices[$d]
  if ($pd -le 0) { return [pscustomobject]@{ Verdict = 'unpriceable'; Why = ("'{0}' is priced at {1}, which cannot anchor a comparison" -f $d, $pd) } }
  $gap = 100.0 * ($pd - $pc) / $pd
  if ([math]::Abs($gap) -le $TiePct) {
    return [pscustomobject]@{ Verdict = 'tie'; Why = ("{0} {1:N3} vs {2} {3:N3} - within {4}%, which is a tie rather than a refutation" -f $c, $pc, $d, $pd, $TiePct) }
  }
  if ($pc -lt $pd) {
    return [pscustomobject]@{ Verdict = 'supported'; Why = ("{0} {1:N3} vs {2} {3:N3} ({4:N1}% cheaper)" -f $c, $pc, $d, $pd, $gap) }
  }
  return [pscustomobject]@{ Verdict = 'CONTRADICTED'; Why = ("the card says {0} is cheaper than {1}, and the board has {0} at {2:N3} against {1} at {3:N3} - the claim is now BACKWARDS by {4:N1}%" -f $c, $d, $pc, $pd, [math]::Abs($gap)) }
}

function Get-TcDeclaredPriceClaims {
  <# One record per declared claim across the specs handed in. `,@()` so a single claim does not
     unroll to a bare object, and CALLERS ASSIGN BEFORE WRAPPING. [[ps-json-array-collapse]] #>
  param([object[]]$Specs, [scriptblock]$ReadJson)
  $out = @()
  foreach ($s in @($Specs)) {
    $doc = & $ReadJson $s
    if ($null -eq $doc) { continue }
    if (-not $doc.PSObject.Properties['price_claims']) { continue }
    foreach ($c in @($doc.price_claims)) {
      $out += [pscustomobject]@{ Slug = [IO.Path]::GetFileNameWithoutExtension([string]$s); Claim = $c }
    }
  }
  return ,@($out)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $P = @{ 'ground-turkey' = 2.663; 'ground-beef-9307' = 6.17; 'chicken-thighs' = 0.98; 'chicken-breast' = 1.99; 'tie-a' = 1.00; 'tie-b' = 1.02; 'free' = 0.0 }
  function _C($a, $b) { [pscustomobject]@{ cheaper = $a; dearer = $b } }

  T 'MUST FIRE  THE ONE THIS FILE EXISTS FOR - a claim the board now contradicts is a wrong number on a live paid page' `
    ((Test-TcPriceClaim (_C 'ground-beef-9307' 'ground-turkey') $P).Verdict -eq 'CONTRADICTED') `
    (Test-TcPriceClaim (_C 'ground-beef-9307' 'ground-turkey') $P).Verdict
  T 'MUST FIRE  the contradiction says which way round it now is, so it can be acted on without re-deriving' `
    ((Test-TcPriceClaim (_C 'ground-beef-9307' 'ground-turkey') $P).Why -like '*BACKWARDS*') `
    (Test-TcPriceClaim (_C 'ground-beef-9307' 'ground-turkey') $P).Why
  T 'MUST FIRE  a side the board does not price is UNPRICEABLE and says it is not evidence the claim holds' `
    ((Test-TcPriceClaim (_C 'saffron' 'ground-turkey') $P).Why -like '*NOT evidence*') `
    (Test-TcPriceClaim (_C 'saffron' 'ground-turkey') $P).Why

  T 'MUST NOT FIRE  a claim the board agrees with is supported' `
    ((Test-TcPriceClaim (_C 'ground-turkey' 'ground-beef-9307') $P).Verdict -eq 'supported') `
    (Test-TcPriceClaim (_C 'ground-turkey' 'ground-beef-9307') $P).Verdict
  T 'MUST NOT FIRE  THE ONE THAT KEEPS THIS CREDIBLE - two commodities a cent apart are a TIE, not a refuted claim' `
    ((Test-TcPriceClaim (_C 'tie-a' 'tie-b') $P).Verdict -eq 'tie') (Test-TcPriceClaim (_C 'tie-a' 'tie-b') $P).Verdict
  T 'MUST NOT FIRE  a claim naming no pair is unpriceable rather than contradicted' `
    ((Test-TcPriceClaim (_C '' '') $P).Verdict -eq 'unpriceable') (Test-TcPriceClaim (_C '' '') $P).Verdict
  T 'MUST NOT FIRE  a zero-priced anchor cannot make a comparison, and does not divide by zero' `
    ((Test-TcPriceClaim (_C 'ground-turkey' 'free') $P).Verdict -eq 'unpriceable') `
    (Test-TcPriceClaim (_C 'ground-turkey' 'free') $P).Verdict

  T 'CLEAN TWIN the real thighs-vs-breast claim on today''s board is supported' `
    ((Test-TcPriceClaim (_C 'chicken-thighs' 'chicken-breast') $P).Verdict -eq 'supported') `
    (Test-TcPriceClaim (_C 'chicken-thighs' 'chicken-breast') $P).Why
  $b = [pscustomobject]@{ comparison = @([pscustomobject]@{ id = 'x'; cheapest_price = 1.5 }, [pscustomobject]@{ id = 'y'; cheapest_price = $null }) }
  $pr = Get-TcBoardPrices $b
  T 'CLEAN TWIN a board row with no cheapest price is left OUT of the lookup rather than entering it as zero' `
    ($pr.ContainsKey('x') -and -not $pr.ContainsKey('y')) (($pr.Keys | Sort-Object) -join ',')
  $read = { param($p) if ($p -eq 'a.json') { [pscustomobject]@{ price_claims = @([pscustomobject]@{ cheaper = 'p'; dearer = 'q' }) } } else { [pscustomobject]@{ name = 'no claims here' } } }
  $cl = Get-TcDeclaredPriceClaims -Specs @('a.json', 'b.json') -ReadJson $read
  T 'CLEAN TWIN a spec declaring no price_claims contributes nothing, which is every spec today' `
    (@($cl).Count -eq 1 -and $cl[0].Slug -eq 'a') ("count=" + @($cl).Count)
  T 'CLEAN TWIN a single declared claim comes back as an ARRAY, not unrolled' ($cl -is [array]) ($cl.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 3 must-fire cases led by the contradiction this file exists for, 4 must-not-fire cases including the tie that keeps it credible, and 4 clean twins'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $BoardFile) {
  $newest = @(Get-ChildItem (Join-Path $OUT_DIR 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  if ($newest.Count) { $BoardFile = $newest[0].FullName }
}
if (-not $BoardFile -or -not (Test-Path -LiteralPath $BoardFile)) {
  Write-Output 'PRICE-CLAIMS AUDIT BLIND: no comparison board on disk, so no claim was checked. That is the expected state in a worktree - the boards are gitignored - and it is NOT evidence that the claims still hold.'
  Write-GuardComplete -Name 'price-claims' -Summary 'blind=no-board'
  exit 3
}
$board = Get-Content $BoardFile -Raw -Encoding UTF8 | ConvertFrom-Json
$prices = Get-TcBoardPrices $board
if (-not $prices.Keys.Count) {
  Write-Output 'PRICE-CLAIMS AUDIT BLIND: the board parsed and priced nothing, which is a read failure rather than an empty board.'
  Write-GuardComplete -Name 'price-claims' -Summary 'blind=no-prices'
  exit 3
}

$specs = @(Get-ChildItem $SPEC_DIR -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$claims = Get-TcDeclaredPriceClaims -Specs $specs -ReadJson {
  param($p) try { Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
$claims = @($claims)

$results = @()
foreach ($c in $claims) {
  $v = Test-TcPriceClaim $c.Claim $prices $TIE_PCT
  $results += [pscustomobject]@{ Slug = $c.Slug; Verdict = $v.Verdict; Why = $v.Why; Says = [string]$c.Claim.says }
}
$bad = @($results | Where-Object { $_.Verdict -eq 'CONTRADICTED' })
$unpriceable = @($results | Where-Object { $_.Verdict -eq 'unpriceable' })

if ($JsonOut) {
  ($results | ConvertTo-Json -Depth 4) | Set-Content $JsonOut -Encoding UTF8
  Write-Output ("  machine-readable copy written to {0}" -f $JsonOut)
}

foreach ($r in ($results | Sort-Object Verdict, Slug)) {
  Write-Output ("  {0,-13} {1,-34} {2}" -f $r.Verdict, $r.Slug.Substring(0, [math]::Min(34, $r.Slug.Length)), $r.Why)
}
Write-Output ("  board {0}, {1} commodity price(s)" -f (Split-Path $BoardFile -Leaf), $prices.Keys.Count)

if ($bad.Count) {
  Write-Output ("PRICE-CLAIMS AUDIT FAILED: {0} of {1} declared price claim(s) are now CONTRADICTED by the board. A comparison that was true when it was written and is false today is a wrong number on a live paid page, and it is the failure no declaration can catch - a declaration is a one-time act and the board is rebuilt daily." -f $bad.Count, $results.Count)
  Write-GuardComplete -Name 'price-claims' -Summary ("claims={0} contradicted={1} unpriceable={2}" -f $results.Count, $bad.Count, $unpriceable.Count)
  exit 2
}
if (-not $results.Count) {
  Write-Output 'price-claims: PASSED - no spec declares a price_claims entry yet, so there is nothing to contradict. That is the honest state on the day this shipped, not a clean bill: the 332 comparisons already in the prose are undeclared and therefore unchecked. The FIRST declaration is worth more than all of them, because it is the only one anybody can verify.'
} else {
  Write-Output ("price-claims: PASSED - {0} declared claim(s) still hold on today's board, {1} could not be priced (reported, never counted as agreement)." -f ($results.Count - $unpriceable.Count), $unpriceable.Count)
}
Write-GuardComplete -Name 'price-claims' -Summary ("claims={0} contradicted=0 unpriceable={1}" -f $results.Count, $unpriceable.Count)
exit 0
