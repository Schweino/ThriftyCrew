# audit-buy-label-plurals.ps1
# ---------------------------------------------------------------------------------------------------
# Every package label must survive being pluralised, because the cost line pluralises it in front of a
# paying reader: "Buy {n} {label}s".
#
# WHY (2026-08-29). Get-CostPlural appends s/es to the END OF THE WHOLE LABEL. That is correct only
# when the label ends in a singular noun, and seven live paid pages proved it is not always so:
#   Buy 2 8ozes              (Swiss Cheese "8oz")          x4 recipes
#   Buy 2 Great Value 12 ozes (label-price fallback)        x2 recipes
#   Buy 4 8 bunses           (Keto Bun "8 buns")            x1 recipe
# Three more were latent, and the worst of them would have printed a price-capture note to readers:
# Jerk Seasoning's label was "10 oz jar (Walkerswood, Walmart $4.52 captured 2026-07-25)", which
# pluralises to that same string with an "s" hung off the closing bracket.
#
# It was found by an auditor reading a line, which is the same way the "6oz can, draineds" defect was
# found twice. Nothing mechanical was looking, which is what this file changes.
#
# THREE FAILURE SHAPES, and they are the only three that appear in 345 live labels:
#   1. the label ends in a parenthetical  - the "s" lands outside the bracket
#   2. the final token is already plural  - "8 buns" -> "8 bunses"
#   3. the final token is a UNIT that takes -es under the rule - "8oz" -> "8ozes"
#
# WHAT IS DELIBERATELY NOT FLAGGED, because the first version of this check did and it was useless:
# "lb" -> "lbs" is correct English and is how 30 of these labels read. A rule that says "the final
# token must be a noun" fails all thirty. Only a unit whose plural takes -ES is wrong, because no unit
# abbreviation does: "oz" -> "ozes" is garbage while "lb" -> "lbs" is right, and the difference is
# entirely which letter it ends in. Flagging shape 3 on the -es rule alone is what separates them.
#
# BOTH LABEL SOURCES ARE READ. db\ingredients.json is the obvious one; the second is the label-price
# fallback inside cost-recipes.ps1, which synthesises a label as brand + ' ' + package_size. That
# construction can never end in a noun ("Great Value 12 oz"), so it is checked only where it can
# actually reach a card - an item with no buy_pkg_g of its own, which is the condition under which
# cost-recipes falls back to it.
#
#   .\audit-buy-label-plurals.ps1
#   .\audit-buy-label-plurals.ps1 -Json
#   .\audit-buy-label-plurals.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param([string]$VocabFile, [string]$LabelPricesFile, [string]$CostedFile, [switch]$Json, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$runJson = [bool]$Json; $runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'cost-render-lib.ps1')
if (-not $VocabFile)       { $VocabFile       = Join-Path $mp 'db\ingredients.json' }
if (-not $LabelPricesFile) { $LabelPricesFile = Join-Path $mp 'db\label-prices.json' }
if (-not $CostedFile)     { $CostedFile     = Join-Path $mp 'db\costed.json' }

# Unit abbreviations that may legitimately end a label. NONE of them takes -es; that is the whole point.
$script:UNIT_TOKENS = @('oz','floz','lb','lbs','g','kg','ml','l','ct','pk','qt','pt')

function Get-PluralProblem {
  <# The reason this label pluralises to something a reader should not see, or '' if it is fine. #>
  param([string]$Label)
  $l = [string]$Label
  if (-not $l) { return '' }
  # Get-CostPlural returns an "each"-suffixed label untouched, so it cannot garble one.
  if ($l -match '(?i)each$') { return '' }
  $plural = Get-CostPlural $l 2
  if ($plural -eq $l) { return '' }
  if ($l -match '\)$') { return 'ends in a parenthetical, so the plural s lands outside the bracket' }
  $last = ($l -split '\s+')[-1]
  if ($last -match '(?i)s$' -and $last -notmatch '(?i)(ss|us)$') { return ("final token '" + $last + "' is already plural, so it doubles") }
  $stem = ($last -replace '[0-9.\-]', '').ToLower()
  # ONLY the -es case. "lb" -> "lbs" is right and must stay unflagged; "oz" -> "ozes" is not.
  if (($script:UNIT_TOKENS -contains $stem) -and ($plural -eq ($l + 'es'))) {
    return ("final token is the unit '" + $stem + "', and no unit abbreviation takes -es")
  }
  return ''
}

function Get-LabelFindings {
  param($VocabRows, $LabelRows)
  $out = @()
  # Items the label-price fallback can NEVER render for. cost-recipes reaches that fallback only for a
  # NON-BULK item with no buy_pkg_g of its own: a bulk item renders pantry_pkg_label instead, and an
  # item with a buy package renders that. Getting this wrong reported 31 spice rows whose descriptions
  # no card can print - measured against the 7 specs that actually carry a garbled string today.
  $fallbackUnreachable = @{}
  foreach ($r in @($VocabRows)) {
    $item = [string]$r.item
    if ($r.PSObject.Properties.Name -contains 'buy_pkg_g' -and $r.buy_pkg_g) { $fallbackUnreachable[$item] = $true }
    if ($r.PSObject.Properties.Name -contains 'bulk' -and $r.bulk) { $fallbackUnreachable[$item] = $true }
    foreach ($f in @('buy_pkg_label', 'pantry_pkg_label')) {
      if ($r.PSObject.Properties.Name -notcontains $f) { continue }
      $l = [string]$r.$f
      $why = Get-PluralProblem $l
      if ($why) { $out += [pscustomobject]@{ source = 'ingredients.json'; item = $item; field = $f; label = $l; plural = (Get-CostPlural $l 2); why = $why } }
    }
  }
  # The label-price fallback only renders where the item has NO buy package of its own - that is the
  # branch cost-recipes takes. Checking every label-price row instead would report 46 descriptions that
  # no card can ever show, which is how a gate teaches people to ignore it.
  foreach ($r in @($LabelRows)) {
    $item = [string]$r.item
    if ($fallbackUnreachable.ContainsKey($item)) { continue }
    $desc = (([string]$r.brand) + ' ' + ([string]$r.package_size)).Trim()
    $why = Get-PluralProblem $desc
    if ($why) { $out += [pscustomobject]@{ source = 'label-prices.json'; item = $item; field = 'brand+package_size'; label = $desc; plural = (Get-CostPlural $desc 2); why = $why } }
  }
  return @($out)
}

function Get-RenderedFindings {
  <#
    The labels a card ACTUALLY PRINTS, read from costed.json's frozen cost blocks.

    WHY THIS EXISTS, and it is the gap this auditor was blind to by construction. Everything above
    reads labels as AUTHORED - db\ingredients.json and db\label-prices.json - and a spec's cost block
    is a SNAPSHOT taken when the spec was last built. On 2026-08-29 both authored sources were already
    correct and this check reported "351 vocabulary row(s) checked, 0 finding(s)" while a live PAID
    page printed:

        Keto Bun, 26.4 buns: ~$15.90. Buy 4 8 bunses: $19.27.

    The relabel had reached ingredients.json and stopped one hop short of the reader, because nothing
    in the chain read a rendered line. That repair "stopped one hop short" is the same shape as the
    class it was repairing, and the finding sat in an unmerged worktree commit for three days.

    ONLY AT A COUNT OF TWO OR MORE. A label is pluralised only when the card says "Buy N <label>s", so
    a buy count of 1 renders the label verbatim and cannot garble it. Checking every row regardless
    would report labels no reader will ever see pluralised - the same over-reporting the two passes
    above are carefully scoped to avoid, and the reason this one takes the count from the data rather
    than assuming it.
  #>
  param($CostedRows)
  $out = @()
  foreach ($r in @($CostedRows)) {
    $slug = [string]$r.slug
    foreach ($l in @($r.lines)) {
      foreach ($pair in @(@('pkg', 'buy_n'), @('starter_pkg', 'starter_n'))) {
        $lf = $pair[0]; $nf = $pair[1]
        if ($l.PSObject.Properties.Name -notcontains $lf) { continue }
        $lab = [string]$l.$lf
        if (-not $lab) { continue }
        $n = 0
        if ($l.PSObject.Properties.Name -contains $nf -and $null -ne $l.$nf) { $n = [int]$l.$nf }
        if ($n -lt 2) { continue }
        $why = Get-PluralProblem $lab
        if ($why) {
          $out += [pscustomobject]@{ source = 'costed.json (RENDERED)'; item = ($slug + ' :: ' + [string]$l.item)
                                     field = $lf; label = $lab; plural = (Get-CostPlural $lab $n); why = $why }
        }
      }
    }
  }
  return @($out)
}

# ---------------------------------------------------------------------------------------------------
if ($runSelfTest) {
  $f = 0
  function T([string]$name, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $name) } else { $script:f++; Write-Output ("  FAIL  " + $name + "   got: " + $got) }
  }
  # THE THIRTY THAT MUST STAY QUIET. This is the case the first version of this gate failed.
  T 'CLEAN TWIN "lb" -> "lbs" is correct English and must NOT be flagged - 30 live labels read this way' `
    ((Get-PluralProblem 'lb') -eq '') (Get-PluralProblem 'lb')
  T 'CLEAN TWIN a label ending in a real singular noun is clean' `
    ((Get-PluralProblem '8oz jar') -eq '' -and (Get-PluralProblem '1lb bag') -eq '' -and (Get-PluralProblem '6oz drained-weight can') -eq '') 'a good label was flagged'
  T 'CLEAN TWIN a digit-bearing final token that pluralises correctly is clean - "19oz 5-pack" -> "5-packs"' `
    ((Get-PluralProblem '19oz 5-pack') -eq '') (Get-PluralProblem '19oz 5-pack')
  T 'CLEAN TWIN an "each" label is exempt, because Get-CostPlural returns it untouched' `
    ((Get-PluralProblem 'each') -eq '') (Get-PluralProblem 'each')

  T 'MUST FIRE  shape 1: a parenthetical label hangs the s outside the bracket' `
    ((Get-PluralProblem '8oz jar (board capture)') -match 'parenthetical') (Get-PluralProblem '8oz jar (board capture)')
  T 'MUST FIRE  shape 2: an already-plural final token doubles - the live "8 bunses"' `
    ((Get-PluralProblem '8 buns') -match 'already plural') (Get-PluralProblem '8 buns')
  T 'MUST FIRE  shape 3: a unit that takes -es - the live "8ozes"' `
    ((Get-PluralProblem '8oz') -match "unit 'oz'") (Get-PluralProblem '8oz')
  T 'MUST FIRE  shape 3 via the label-price construction - the live "Great Value 12 ozes"' `
    ((Get-PluralProblem 'Great Value 12 oz') -match "unit 'oz'") (Get-PluralProblem 'Great Value 12 oz')

  # The fallback is only reachable when the item has no buy package of its own. Both directions pinned,
  # because suppressing it unconditionally would hide a real defect and checking it unconditionally
  # would report 46 descriptions no card can render.
  $vocab = @([pscustomobject]@{ item = 'Thing'; buy_pkg_g = 340; buy_pkg_label = '12oz box' })
  $labels = @([pscustomobject]@{ item = 'Thing'; brand = 'Great Value'; package_size = '12 oz' })
  $vocabBulk = @([pscustomobject]@{ item = 'Thing'; bulk = $true })
  T 'CLEAN TWIN a BULK item is not judged either - it renders pantry_pkg_label, never the fallback' `
    (@(Get-LabelFindings $vocabBulk $labels).Count -eq 0) 'flagged a bulk item that renders its pantry label'
  T 'CLEAN TWIN a label-price row is NOT judged when the item has its own buy package - no card renders it' `
    (@(Get-LabelFindings $vocab $labels).Count -eq 0) 'flagged an unreachable label'
  $vocab2 = @([pscustomobject]@{ item = 'Thing' })
  T 'MUST FIRE   ...and IS judged when the item has none, because then the fallback is what prints' `
    (@(Get-LabelFindings $vocab2 $labels).Count -eq 1) 'missed a reachable label'

  # THE LIVE TREE.
  # ASSIGN THEN WRAP. `@(... | ConvertFrom-Json)` collapses the whole array into ONE element, so $r
  # becomes the entire file and $r.brand returns EVERY brand at once. Third time this trap has fired in
  # one day - audit-vocab-integrity documents it, the blocker-heading baseline hit it, and so did this.
  $vParsed = Get-Content $VocabFile -Raw -Encoding utf8 | ConvertFrom-Json
  $v = @($vParsed)
  $lpParsed = Get-Content $LabelPricesFile -Raw -Encoding utf8 | ConvertFrom-Json
  $lp = @($lpParsed)
  $cParsed = if (Test-Path $CostedFile) { Get-Content $CostedFile -Raw -Encoding utf8 | ConvertFrom-Json } else { @() }
  $live = @(Get-LabelFindings $v $lp)
  T 'CLEAN TWIN every package label in the estate survives being pluralised' `
    ($live.Count -eq 0) (($live | ForEach-Object { $_.item + ' "' + $_.label + '"' }) -join ' | ')

  # ---- the RENDERED pass (2026-09-01) ------------------------------------------------------------
  # THE FOUNDING LINE, verbatim from the live paid page it shipped on: a frozen cost block still
  # holding "8 buns" at a buy count of 4, while ingredients.json had ALREADY been relabelled and this
  # auditor reported 0 findings. Nothing in the chain read a rendered line.
  $rBad = @(Get-RenderedFindings @([pscustomobject]@{ slug = 'turkey-meatball-sub-bake'
              lines = @([pscustomobject]@{ item = 'Keto Bun'; pkg = '8 buns'; buy_n = 4 }) }))
  T 'MUST FIRE  a frozen cost block still printing "8 buns" at a buy count of 4 is caught' `
    ($rBad.Count -eq 1 -and $rBad[0].why -match 'already plural') (($rBad | ForEach-Object { $_.why }) -join '|')
  # A COUNT OF ONE RENDERS THE LABEL VERBATIM, so it cannot garble and must not be reported. Without
  # this the pass would flag every "8 buns" in the catalogue, including the ones no reader sees
  # pluralised - the over-reporting that makes a gate ignorable.
  $rOne = @(Get-RenderedFindings @([pscustomobject]@{ slug = 'single-buy'
              lines = @([pscustomobject]@{ item = 'Keto Bun'; pkg = '8 buns'; buy_n = 1 }) }))
  T 'CLEAN TWIN the same label at a buy count of ONE is not pluralised, so it is not a finding' `
    ($rOne.Count -eq 0) (($rOne | ForEach-Object { $_.label }) -join '|')
  # starter_pkg renders the same way and was the other half of the orphaned finding.
  $rStart = @(Get-RenderedFindings @([pscustomobject]@{ slug = 's'
              lines = @([pscustomobject]@{ item = 'X'; starter_pkg = '8oz'; starter_n = 2 }) }))
  T 'MUST FIRE  starter_pkg is rendered too, and "8oz" at two would print "8ozes"' `
    ($rStart.Count -eq 1 -and $rStart[0].field -eq 'starter_pkg') (($rStart | ForEach-Object { $_.field }) -join '|')
  $rLive = @(Get-RenderedFindings @(if ($cParsed.PSObject.Properties.Name -contains 'recipes') { $cParsed.recipes } else { $cParsed }))
  T 'CLEAN TWIN every RENDERED label in the live catalogue survives its own buy count' `
    ($rLive.Count -eq 0) (($rLive | ForEach-Object { $_.item + ' "' + $_.label + '"' }) -join ' | ')

  if ($f -eq 0) { Write-Output 'buy-label-plurals SELF-TEST PASS'; exit 0 }
  Write-Output ("buy-label-plurals SELF-TEST FAIL: {0} case(s)" -f $f); exit 2
}

# ---------------------------------------------------------------------------------------------------
# ASSIGN THEN WRAP - see the note in the self-test.
$vocabParsed = Get-Content $VocabFile -Raw -Encoding utf8 | ConvertFrom-Json
$vocabRows = @($vocabParsed)
$labelParsed = Get-Content $LabelPricesFile -Raw -Encoding utf8 | ConvertFrom-Json
$labelRows = @($labelParsed)
$findings = @(Get-LabelFindings $vocabRows $labelRows)
# THE RENDERED PASS. costed.json is a BUILD ARTIFACT and is gitignored in a bare checkout, so its
# absence is announced rather than silently skipped - a check that examined nothing must never read as
# ok, and this pass covering zero specs is exactly the state the 2026-08-29 bun line slipped through.
$renderedCount = 0
if (Test-Path $CostedFile) {
  $costedParsed = Get-Content $CostedFile -Raw -Encoding utf8 | ConvertFrom-Json
  $costedRows = @(if ($costedParsed.PSObject.Properties.Name -contains 'recipes') { $costedParsed.recipes } else { $costedParsed })
  $renderedCount = $costedRows.Count
  $findings += @(Get-RenderedFindings $costedRows)
}

if ($runJson) {
  [pscustomobject]@{ labels = $vocabRows.Count; findings = $findings } | ConvertTo-Json -Depth 5
} else {
  Write-Output ("buy label plurals: {0} vocabulary row(s) + {1} costed spec(s) checked, {2} finding(s)" -f $vocabRows.Count, $renderedCount, $findings.Count)
  if ($renderedCount -eq 0) { Write-Output '  NOTE: no costed.json here, so the RENDERED labels were not checked - only the authored ones.' }
  foreach ($x in $findings) {
    Write-Output ("  [{0}] {1} :: {2}" -f $x.source, $x.item, $x.field)
    Write-Output ("      `"{0}`"  renders as  `"Buy 2 {1}`"" -f $x.label, $x.plural)
    Write-Output ("      {0}" -f $x.why)
  }
  if ($findings.Count) {
    Write-Output ''
    Write-Output '  The cost line prints "Buy {n} {label}s" to a paying reader. Put the pluralizable noun LAST'
    Write-Output '  (a jar, a bag, a box, a can, a pack), keep provenance out of reader-facing text, and never'
    Write-Output '  end a label on a unit abbreviation or an already-plural word.'
  }
}
Write-GuardComplete -Name 'buy-label-plurals' -Summary ("labels={0} findings={1}" -f $vocabRows.Count, $findings.Count)
exit $(if ($findings.Count) { 1 } else { 0 })
