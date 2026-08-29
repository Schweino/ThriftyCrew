<#
  audit-buy-label-plural.ps1 - the buy line's pluralized package label must end in a word that can
  actually take an "s".

  WHY THIS EXISTS (2026-08-29). cost-render-lib.ps1's Get-CostPlural appends "s" - or "es" after
  ch/sh/ss/s/x/z - to the END of the whole package label whenever the buy count is 2 or more, with a
  single exemption for a label ending in "each". That is correct for "8oz pack" -> "8oz packs" and
  for "lb" -> "lbs", and it is garbage for a label that does not end in a pluralizable noun. Seven
  LIVE specs were rendering:
      Swiss Cheese          "8oz"                -> "Buy 2 8ozes"   (4 specs)
      Keto Bun              "8 buns"             -> "Buy 4 8 bunses" (1 spec)
      Pasta Shells - jumbo  "Great Value 12 oz"  -> "Buy 2 Great Value 12 ozes" (2 specs)
  and five pantry labels ending in a parenthetical ("8oz jar (board capture)") were one starter_n >= 2
  away from printing "(board capture)s" on a card, capture provenance and all.

  WHAT MAKES IT A CLASS RATHER THAN THREE TYPOS: nothing in the chain reads a rendered buy line. The
  engine checks that the buy amounts sum to cost_batch_true, spec-guards re-parses the numbers, and
  audit-cost-line-coverage checks that every priced line is NAMED - and every one of those passes on
  "Buy 2 8ozes", because the arithmetic is right and the ingredient is named. Both this and the two
  earlier "draineds" incidents were caught by a human auditor reading cost lines, which is not a
  control.

  THE THIRD SOURCE OF LABELS, which is why fixing ingredients.json alone would not close this: when a
  row states no buy package, cost-recipes.ps1 (line ~121) falls through to db\label-prices.json and
  builds the label as brand + package_size. That desc ends in a bare unit by construction - "Great
  Value 12 oz" - so 52 of the 59 label-priced items are one buy_n >= 2 away from this bug and no
  ingredients.json edit can reach them. This guard reads costed.json, so it sees them the day they fire.

  THE PREDICATE. A label is judged only when Get-CostPlural would actually change it (n >= 2 and not
  ending in "each"); then the last token of the label must not be:
    SIZE    a bare measurement, either self-contained ("8oz", "12ct") or a unit whose preceding token
            is the number ("... 12 oz"). "Buy 2 8ozes" / "Buy 2 Great Value 12 ozes".
    PLURAL  already plural ("8 buns", "12ct eggs"). "Buy 4 8 bunses" / "Buy 2 12ct eggses".
    PAREN   a closing parenthesis ("each (heart)", "8oz jar (board capture)"). "(heart)s".
  Everything else passes, and that "everything else" is the whole rest of the catalogue: bare
  container nouns ("lb", "pint", "gallon", "loaf"), sized containers ("8oz pack", "20ct pack",
  "19oz 5-pack", "14.5oz can"), and "each". Measured before it was written - over all 587 costed
  recipes and all 351 ingredients.json rows the predicate returns exactly the twelve rows the
  2026-08-27 wave-1 auditor found by hand, and nothing else.

  The container nouns are deliberately NOT taken from cost-render-lib's $PKG_SIZE_UNITS, which
  includes pk/pack/ct/count because it answers a different question (is a leading "1" part of a
  size?). "5-pack" ends in a container, pluralizes cleanly, and must stay quiet.

  Run:  .\audit-buy-label-plural.ps1                (whole catalogue; exit 0 clean, 1 findings)
        .\audit-buy-label-plural.ps1 -Slugs a,b     (wave battery; comma-joined form accepted)
        .\audit-buy-label-plural.ps1 -SelfTest      (frozen fixtures: the three firing cases + twins)
#>
[CmdletBinding()]
param(
  [string[]]$Slugs,
  [switch]$SelfTest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
. (Join-Path (Split-Path $mp -Parent) 'lib\guard-contract.ps1')
# THE REAL RENDERER, never a copy of it. Get-PkgLabel and Get-CostPlural are what the cards are printed
# with; a reimplementation here would drift from them and certify a rendering nothing produces.
. (Join-Path $here 'cost-render-lib.ps1')

# Measurements only - no container nouns. See the header for why this is not $PKG_SIZE_UNITS.
$script:MEASURE_TOKENS = @('lb','lbs','oz','ozs','floz','fl','g','kg','mg','ml','l','liter','liters',
                           'litre','litres','gal','gallon','gallons','qt','quart','quarts','pt','pint',
                           'pints','ct','count','in','inch','inches','cm')

function Test-LabelPluralizable {
  <# $Label is the label as Get-PkgLabel leaves it (leading redundant "1 " already stripped).
     Returns $null when the label pluralizes cleanly, or the rule name that refuses it. #>
  param([string]$Label)
  if ($null -eq $Label) { return $null }
  $l = $Label.TrimEnd()
  if ($l -eq '') { return $null }
  if ($l.EndsWith(')')) { return 'PAREN' }
  $toks = @($l -split '\s+' | Where-Object { $_ })
  if (-not $toks.Count) { return $null }
  $last = $toks[-1]
  $letters = ($last -replace '[^A-Za-z]', '').ToLower()
  # "8oz", "12ct", "0.75oz" - the token IS a size, with no noun after it.
  if ($last -match '^[\d.]+[- ]?[A-Za-z.]*$' -and $script:MEASURE_TOKENS -contains $letters) { return 'SIZE' }
  # "... 12 oz" - the unit is a separate token but the one before it is the number, so it is still a size.
  if ($script:MEASURE_TOKENS -contains $letters -and $toks.Count -ge 2 -and $toks[-2] -match '^[\d.]+$') { return 'SIZE' }
  # "buns", "eggs" - Get-CostPlural would make it "bunses"/"eggses". "ss" endings ("glass") are fine.
  if ($letters.EndsWith('s') -and -not $letters.EndsWith('ss') -and $script:MEASURE_TOKENS -notcontains $letters) { return 'PLURAL' }
  return $null
}

function Test-RenderedBuyLabel {
  <# The judged pair: a label and the count it will be rendered at. Returns $null when this render is
     not one Get-CostPlural changes (n <= 1, or an "each" label), otherwise the rule name or $null. #>
  param([string]$Label, [int]$N)
  if (-not $Label) { return $null }
  $base = Get-PkgLabel $Label
  if ((Get-CostPlural $base $N) -eq $base) { return $null }   # nothing appended - nothing to judge
  return (Test-LabelPluralizable $base)
}

if ($SelfTest) {
  $fails = 0
  function ok($c, $m, $g) { if ($c) { Write-Host "  ok    $m" } else { $script:fails++; Write-Host "  FAIL  $m   got: $g" } }

  # ---- MUST FIRE: the three renders that were live on the site on 2026-08-29.
  ok ((Test-RenderedBuyLabel '8oz' 2) -eq 'SIZE')   'MUST FIRE  Swiss Cheese "8oz" at 2 - the "Buy 2 8ozes" that shipped' (Test-RenderedBuyLabel '8oz' 2)
  ok ((Test-RenderedBuyLabel 'Great Value 12 oz' 2) -eq 'SIZE') 'MUST FIRE  a label-prices brand+size desc - "Buy 2 Great Value 12 ozes"' (Test-RenderedBuyLabel 'Great Value 12 oz' 2)
  ok ((Test-RenderedBuyLabel '8 buns' 4) -eq 'PLURAL') 'MUST FIRE  Keto Bun "8 buns" at 4 - the "Buy 4 8 bunses" that shipped' (Test-RenderedBuyLabel '8 buns' 4)

  # ---- MUST FIRE: the latent rows, none of which had reached n >= 2 yet.
  ok ((Test-RenderedBuyLabel 'each (heart)' 2) -eq 'PAREN' ) 'MUST FIRE  "each (heart)" slips the each$ exemption and pluralizes the parenthesis' (Test-RenderedBuyLabel 'each (heart)' 2)
  ok ((Test-RenderedBuyLabel '8oz jar (board capture)' 2) -eq 'PAREN') 'MUST FIRE  a pantry label that would print capture provenance to a reader' (Test-RenderedBuyLabel '8oz jar (board capture)' 2)
  ok ((Test-RenderedBuyLabel '12ct eggs' 2) -eq 'PLURAL') 'MUST FIRE  "12ct eggs" -> "12ct eggses"' (Test-RenderedBuyLabel '12ct eggs' 2)

  # ---- CLEAN TWINS: the shapes that make up the rest of the catalogue and must stay silent, or this
  # guard reports 300 recipes on its first run and joins the estate's dead-guard pile.
  ok ($null -eq (Test-RenderedBuyLabel 'lb' 3))          'CLEAN TWIN a bare container unit - "Buy 3 lbs" is correct English' (Test-RenderedBuyLabel 'lb' 3)
  ok ($null -eq (Test-RenderedBuyLabel 'pint' 2))        'CLEAN TWIN "Buy 2 pints"' (Test-RenderedBuyLabel 'pint' 2)
  ok ($null -eq (Test-RenderedBuyLabel 'gallon' 2))      'CLEAN TWIN "Buy 2 gallons"' (Test-RenderedBuyLabel 'gallon' 2)
  ok ($null -eq (Test-RenderedBuyLabel '8oz pack' 3))    'CLEAN TWIN a sized container - "Buy 3 8oz packs"' (Test-RenderedBuyLabel '8oz pack' 3)
  ok ($null -eq (Test-RenderedBuyLabel '20ct pack' 2))   'CLEAN TWIN a counted container - "Buy 2 20ct packs"' (Test-RenderedBuyLabel '20ct pack' 2)
  ok ($null -eq (Test-RenderedBuyLabel '19oz 5-pack' 6)) 'CLEAN TWIN a hyphenated count - "Buy 6 19oz 5-packs", NOT a bare size' (Test-RenderedBuyLabel '19oz 5-pack' 6)
  ok ($null -eq (Test-RenderedBuyLabel '14.5oz can' 2))  'CLEAN TWIN "Buy 2 14.5oz cans"' (Test-RenderedBuyLabel '14.5oz can' 2)
  ok ($null -eq (Test-RenderedBuyLabel '6oz drained-weight can' 2)) 'CLEAN TWIN the 08-27 black-olives ruling shape' (Test-RenderedBuyLabel '6oz drained-weight can' 2)
  ok ($null -eq (Test-RenderedBuyLabel '8ct bun pack' 4)) 'CLEAN TWIN the Keto Bun repair' (Test-RenderedBuyLabel '8ct bun pack' 4)
  ok ($null -eq (Test-RenderedBuyLabel '12oz box' 2))     'CLEAN TWIN the Pasta Shells repair' (Test-RenderedBuyLabel '12oz box' 2)
  ok ($null -eq (Test-RenderedBuyLabel '8oz package' 2))  'CLEAN TWIN the Swiss Cheese repair' (Test-RenderedBuyLabel '8oz package' 2)
  ok ($null -eq (Test-RenderedBuyLabel 'dozen-egg carton' 2)) 'CLEAN TWIN the Egg Yolk repair' (Test-RenderedBuyLabel 'dozen-egg carton' 2)
  ok ($null -eq (Test-RenderedBuyLabel 'romaine heart' 3)) 'CLEAN TWIN the Romaine Lettuce repair' (Test-RenderedBuyLabel 'romaine heart' 3)

  # ---- NOT JUDGED: renders Get-CostPlural does not touch. A bad label at n = 1 prints nothing wrong,
  # and flagging it would make the guard's verdict depend on this week's board rather than on the label.
  ok ($null -eq (Test-RenderedBuyLabel '8oz' 1))  'NOT JUDGED a bad label at n = 1 renders "Buy 1 8oz", which is correct' (Test-RenderedBuyLabel '8oz' 1)
  ok ($null -eq (Test-RenderedBuyLabel 'each' 3)) 'NOT JUDGED "each" is exempted by Get-CostPlural itself' (Test-RenderedBuyLabel 'each' 3)
  # And the leading-"1 " strip must be applied BEFORE judging, or "1 head" is judged as "1 head".
  ok ($null -eq (Test-RenderedBuyLabel '1 head' 3)) 'NOT JUDGED "1 head" is stripped to "head" first - "Buy 3 heads"' (Test-RenderedBuyLabel '1 head' 3)
  ok ((Test-RenderedBuyLabel '1 8oz' 3) -eq 'SIZE') 'MUST FIRE  and the strip does not hide a bad label behind it' (Test-RenderedBuyLabel '1 8oz' 3)

  # ---- THE ARGUMENT SHAPE. wave-preaudit.ps1 reaches its children through `powershell -File`, which
  # cannot bind a multi-element [string[]] from argv, so -Slugs arrives comma-joined. audit-cost-line-
  # coverage shipped without this split and REFUSED on every wave for weeks. Same road, same parse.
  $split = @(@('a,b,c') | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  ok ($split.Count -eq 3) 'MUST FIRE  a comma-joined -Slugs parses to THREE slugs, the shape -File can carry' ($split -join '|')
  $splitEmpty = @(@('') | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  ok ($splitEmpty.Count -eq 0) 'CLEAN TWIN an empty -Slugs still means the whole catalogue' ([string]$splitEmpty.Count)

  if ($fails) { Write-Host "SELFTEST: $fails FAILED"; exit 1 }
  Write-Host 'audit-buy-label-plural SELF-TEST PASS'
  exit 0
}

# ---------------- live sweep ----------------
$costedPath = Join-Path $mp 'db\costed.json'
if (-not (Test-Path $costedPath)) { throw "no costed.json at $costedPath" }
# ASSIGN, THEN WRAP: @(Get-Content | ConvertFrom-Json) collapses the array to Count 1, which reads as an
# empty catalogue and passes everything.
$costedParsed = ConvertFrom-Json (Get-Content $costedPath -Raw)
$costed = @($costedParsed)
if ($costed.Count -lt 50) { throw "costed.json read as only $($costed.Count) row(s) - refusing to certify a catalogue that cannot be that small" }

$askedSlugs = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rows = if ($askedSlugs.Count) { @($costed | Where-Object { $askedSlugs -contains [string]$_.slug }) } else { $costed }

# A GUARD THAT SWEEPS NOTHING MUST NOT REPORT CLEAN.
if ($askedSlugs.Count -and -not $rows.Count) {
  Write-Host ("audit-buy-label-plural: REFUSING - {0} slug(s) named but NONE matched a row in db\costed.json." -f $askedSlugs.Count)
  Write-Host  '  A sweep of zero recipes is not a clean sweep.'
  exit 1
}

$firing = @()
foreach ($r in $rows) {
  foreach ($l in @($r.lines)) {
    foreach ($pair in @(@{ n = 'buy_n'; lab = 'pkg'; what = 'buy' }, @{ n = 'starter_n'; lab = 'starter_pkg'; what = 'pantry' })) {
      $n = $l.($pair.n); $lab = [string]$l.($pair.lab)
      if (-not $lab -or $null -eq $n) { continue }
      $ni = [int][Math]::Floor([double]$n)
      $why = Test-RenderedBuyLabel $lab $ni
      if ($why) {
        $firing += [pscustomobject]@{ slug = [string]$r.slug; item = [string]$l.item; kind = $pair.what
                                      label = $lab; n = $ni; rule = $why
                                      rendered = ('Buy ' + $ni + ' ' + (Get-CostPlural (Get-PkgLabel $lab) $ni)) }
      }
    }
  }
}

# The catalogue's OWN labels, judged at n = 2 whether or not any recipe has reached that count yet. This
# is the half that would have caught the five pantry parentheticals before a card printed one.
#
# IT RUNS EVEN UNDER -Slugs, deliberately. A wave's own mapper is the thing most likely to introduce a
# fresh bad label, and a brand-new row has no recipe at n >= 2 yet - so scoping this half to the wave's
# slugs would blind the gate to exactly the case it is wired into the battery for. The file is clean as
# of 2026-08-29, so a finding here is something that arrived after that and is worth stopping for.
$latent = @()
$ingPath = Join-Path $mp 'db\ingredients.json'
if (Test-Path $ingPath) {
  # ASSIGN, THEN WRAP - here too. @(ConvertFrom-Json (...)) inline wraps the returned array INSIDE a
  # one-element array, so this loop ran exactly once over the whole array object and reported latent=0
  # on a file that had nine bad labels in it. Caught by the neuter run, not by reading the code.
  $ingParsed = ConvertFrom-Json (Get-Content $ingPath -Raw)
  foreach ($row in @($ingParsed)) {
    foreach ($f in @('buy_pkg_label', 'pantry_pkg_label')) {
      if ($row.PSObject.Properties.Name -notcontains $f) { continue }
      $lab = [string]$row.$f
      if (-not $lab) { continue }
      $why = Test-RenderedBuyLabel $lab 2
      if ($why) { $latent += [pscustomobject]@{ item = [string]$row.item; field = $f; label = $lab; rule = $why
                                                rendered = ('Buy 2 ' + (Get-CostPlural (Get-PkgLabel $lab) 2)) } }
    }
  }
}

$scopeNote = ' + every label in ingredients.json'
if (-not $Quiet) { Write-Host ("audit-buy-label-plural: swept {0} costed recipe(s){1}" -f $rows.Count, $scopeNote) }
foreach ($h in ($firing | Sort-Object slug, item)) {
  Write-Host ("  FAIL [{0}] {1}  {2} renders `"{3}`"  (label '{4}', {5} line)" -f $h.rule, $h.slug, $h.item, $h.rendered, $h.label, $h.kind)
}
foreach ($h in ($latent | Sort-Object item, field)) {
  Write-Host ("  FAIL [{0}] {1}  {2} would render `"{3}`" the day a batch needs two (label '{4}')" -f $h.rule, $h.item, $h.field, $h.rendered, $h.label)
}
if (-not $firing.Count -and -not $latent.Count) {
  Write-Host '  ok - every buy label that gets pluralized ends in a word that can take an s'
}
Write-GuardComplete -Name 'audit-buy-label-plural' -Summary ("firing={0} latent={1} n={2}" -f $firing.Count, $latent.Count, $rows.Count)
if ($firing.Count -or $latent.Count) { exit 1 }
exit 0
