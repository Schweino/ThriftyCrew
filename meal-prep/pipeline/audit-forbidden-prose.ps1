<#
  audit-forbidden-prose.ps1 - no recipe title and no reader-facing prose carries a globally forbidden
  health word. A gate at ZERO, over the committed recipe catalogue.

  WHY THIS EXISTS (Brad's ruling, 2026-09-12, backlog I138). Two live paid recipes carried the word
  "Healthy" in the title we publish, and one of them - Healthy Hamburger Helper - is 5.5% vegetable by
  weight in a 5,074 g batch whose only vegetable is onion. Both titles were inherited from the source
  blog. Brad's ruling: "A title we publish on a paid page is our claim, whatever blog it came from. No
  recipe title or reader-facing prose may carry a health word (healthy, clean, guilt-free, light,
  nutritious and the like) unless we own a written bar behind it. ... Source attribution lines naming
  the originating blog stay as they are. Add 'healthy' to the global forbidden prose list so the Recipe
  Hunter cannot import the word again."

  THE LIST IT ENFORCES IS DATA: meal-prep\pipeline\forbidden-prose-global.json, read through
  meal-prep\pipeline\forbidden-prose-lib.ps1, which is the same matcher build-v2-spec.ps1 refuses an
  import with and spec-guards.ps1 fails a validation with. One list, three callers, no second copy.

  SCOPE OF A CLEAN REPORT: UNSOUND, and in a way worth stating plainly. It finds the SPELLINGS on the
  list, in the committed specs, on word boundaries. A clean report means no spec carries a LISTED term
  in a swept field. It does not mean the catalogue makes no health claim: "packed with fiber",
  "fuels your day" and every sentence that asserts a benefit in words nobody thought to list are
  invisible to it, and so is a claim assembled at render time from tokens. A reported hit is real.

  WHY IT IS A GATE AT ZERO AND NOT A RATCHET. The estate's rule is that a gate red on day one teaches
  people to ignore red, so the change that added this cleaned the catalogue first: measured 2026-09-12,
  12 of 584 recipes carried "healthy" in a swept field (2 titles, 2 meta descriptions, 10 meta keyword
  lists, 2 sentences of prose), and all 12 were repaired in the same commit. A further 16 carry it in an
  attribution field and are correct, which is why those fields are not swept. So zero is a real floor
  here, not an aspiration, and a ratchet would only let the next one in.

  EXIT CODES: 0 clean, 1 at least one spec carries a listed term, 2 self-test regression,
  3 BLIND (no specs resolved, or the global list missing, empty or without its anchor term).

  IT LIVES IN meal-prep\pipeline AND NOT IN ops, on purpose. Its population is meal-prep\db\recipes,
  which is meal-prep's INTERNALS directory, and a detector in ops\ reading it is exactly the coupling
  ops\audit-cross-module-reach.ps1 ratchets - that ratchet went 118 -> 120 on the first draft of this
  file, which is how the placement was settled. run-gates lists it by path, the way it already lists
  meal-prep\engine\golden-test.ps1, so nothing is lost by putting it where its data is.

    meal-prep\pipeline\audit-forbidden-prose.ps1             scan the committed catalogue
    meal-prep\pipeline\audit-forbidden-prose.ps1 -SelfTest   the two founding titles, the carve-out, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [string]$RecipeDir = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }   # ...\meal-prep\pipeline
$mp   = Split-Path $here -Parent
$repo = Split-Path $mp -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'forbidden-prose-lib.ps1')

# The term every honest list carries. A list that parsed but lost this one is a list that would pass the
# very catalogue this file was written for, so the live run reads it as BLIND rather than clean.
$script:FP_ANCHOR_TERM = 'healthy'
# A spec the discovery must resolve, or it found some other directory (or none) and its silence means
# nothing. Chosen because it is one of the two recipes Brad's ruling renamed, so it cannot be deleted
# quietly: if it ever goes, whoever removed it reads this line.
$script:FP_ANCHOR_SPEC = 'healthy-hamburger-helper.json'

function Get-FpSpecFiles {
  param([string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Sort-Object Name)
}

# ------------------------------------------------------------------------------------------------ self-test
if ($SelfTest) {
  $script:fail = 0
  $script:cases = 0
  function Assert-FpCase {
    param([string]$Name, [bool]$Ok, [string]$Got = '')
    $script:cases++
    if ($Ok) { Write-Output ('  ok    ' + $Name) }
    else { $script:fail++; Write-Output ('  X     ' + $Name + '   got: ' + $Got) }
  }
  $TERMS = Get-TcGlobalForbiddenProse

  # ---- MUST FIRE. The two founding titles, frozen as they stood at c98564ff0.
  $t1 = [pscustomobject]@{ name = 'Healthy Hamburger Helper'; slug = 'healthy-hamburger-helper' }
  $h1 = @(Get-TcForbiddenProseHit -Spec $t1 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      the founding title "Healthy Hamburger Helper" is caught in name' `
    ($h1.Count -eq 1 -and $h1[0].Field -eq 'name' -and $h1[0].Term -eq 'healthy') ('hits=' + $h1.Count)

  $t2 = [pscustomobject]@{ name = 'Healthy Chicken, Rice and Broccoli Skillet' }
  $h2 = @(Get-TcForbiddenProseHit -Spec $t2 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      the second founding title is caught too' ($h2.Count -eq 1) ('hits=' + $h2.Count)

  # The meta description and the meta keyword list are published bytes, so they are our claim as much as
  # the title is. 10 of the 12 repaired on 2026-09-12 were keyword lists.
  $t3 = [pscustomobject]@{ head = [pscustomobject]@{ description = 'One-pot healthy chicken, rice and broccoli skillet built for meal prep.' } }
  $h3 = @(Get-TcForbiddenProseHit -Spec $t3 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      head.description is swept' ($h3.Count -eq 1 -and $h3[0].Field -eq 'head.description') ('hits=' + $h3.Count + ' field=' + $(if ($h3.Count) { $h3[0].Field } else { '-' }))

  $t4 = [pscustomobject]@{ head = [pscustomobject]@{ keywords = 'turkey pumpkin chili, budget meal prep, healthy chili recipe, cheap dinner ideas' } }
  $h4 = @(Get-TcForbiddenProseHit -Spec $t4 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      head.keywords is swept' ($h4.Count -eq 1 -and $h4[0].Field -eq 'head.keywords') ('hits=' + $h4.Count)

  $t5 = [pscustomobject]@{ upsell_html = 'this saag makes healthy eating feel effortless all week long' }
  $h5 = @(Get-TcForbiddenProseHit -Spec $t5 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      a health word in a PROSE field is caught and names its field' `
    ($h5.Count -eq 1 -and $h5[0].Field -eq 'upsell_html' -and $h5[0].Term -eq 'healthy') ('hits=' + $h5.Count)

  # A term written with a hyphen matches the spaced spelling, or the ban is one space from useless.
  $t6 = [pscustomobject]@{ intro_html = 'a guilt free dinner you can eat all week' }
  $h6 = @(Get-TcForbiddenProseHit -Spec $t6 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      the hyphenated term "guilt-free" also catches the SPACED spelling' `
    ($h6.Count -eq 1 -and $h6[0].Term -eq 'guilt-free') ('hits=' + $h6.Count)

  $t7 = [pscustomobject]@{ intro_html = 'clean eating without the price tag' }
  $h7 = @(Get-TcForbiddenProseHit -Spec $t7 -Terms $TERMS)
  Assert-FpCase 'MUST FIRE      the health-claim FORM "clean eating" is listed even though bare "clean" is not' `
    ($h7.Count -eq 1 -and $h7[0].Term -eq 'clean eating') ('hits=' + $h7.Count)

  # ---- MUST NOT FIRE. Brad's carve-out, and the legal prose the bare words appear in.
  $c1 = [pscustomobject]@{ credit_html = 'Recipe adapted from <a href="https://thecleaneatingcouple.com/healthy-baked-ziti/">The Clean Eating Couple</a>, rebuilt for 14 servings.' }
  $n1 = @(Get-TcForbiddenProseHit -Spec $c1 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  the attribution line naming the originating blog is SILENT (Brad''s ruling)' ($n1.Count -eq 0) ('hits=' + $n1.Count)

  $c2 = [pscustomobject]@{ source_site = 'Healthy Foodie Girl'; source_url = 'https://healthyfoodiegirl.com/ground-turkey-enchilada-skillet/' }
  $n2 = @(Get-TcForbiddenProseHit -Spec $c2 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  source_site and source_url are the same attribution in machine form' ($n2.Count -eq 0) ('hits=' + $n2.Count)

  $c3 = [pscustomobject]@{ slug = 'healthy-hamburger-helper' }
  $n3 = @(Get-TcForbiddenProseHit -Spec $c3 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  the slug is the live URL of a paid page and is not swept' ($n3.Count -eq 0) ('hits=' + $n3.Count)

  # The dash-sweep lesson, one field over: a ban list that NAMES the banned word is not prose. Reading it
  # as prose refused three recipes in hunt-2026-08-27-ten for carrying the character they banned.
  $c4 = [pscustomobject]@{ forbidden_prose_terms = @('guilt-free', 'superfood', 'healthy'); intro_html = 'clean prose' }
  $n4 = @(Get-TcForbiddenProseHit -Spec $c4 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  a spec whose own ban list NAMES the term is silent' ($n4.Count -eq 0) ('hits=' + $n4.Count)

  $c5 = [pscustomobject]@{ make_it = @('Scrape the bottom of the pot clean and bring it to a bare simmer.', 'Rinse the rice clean before it goes in.') }
  $n5 = @(Get-TcForbiddenProseHit -Spec $c5 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  bare "clean" as a verb is legal prose - 58 of 584 recipes use it that way' ($n5.Count -eq 0) ('hits=' + $n5.Count)

  $c6 = [pscustomobject]@{ ingredients_display = @('<strong>Light Sour Cream (generic):</strong> 1.25 cups (300 g)', '<strong>Light Brown Sugar:</strong> 2 tbsp (25 g)') }
  $n6 = @(Get-TcForbiddenProseHit -Spec $c6 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  "light" is a PRODUCT NAME here, which is why the bare word is not listed' ($n6.Count -eq 0) ('hits=' + $n6.Count)

  $c7 = [pscustomobject]@{ intro_html = 'adapted from healthyfoodiegirl and rebuilt for fourteen' }
  $n7 = @(Get-TcForbiddenProseHit -Spec $c7 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  matching is on WORD BOUNDARIES, so it does not fire inside healthyfoodiegirl' ($n7.Count -eq 0) ('hits=' + $n7.Count)

  $c8 = [pscustomobject]@{ name = 'Homemade Hamburger Helper'; head = [pscustomobject]@{ description = 'Homemade Hamburger Helper made from scratch in one pot.' } }
  $n8 = @(Get-TcForbiddenProseHit -Spec $c8 -Terms $TERMS)
  Assert-FpCase 'MUST NOT FIRE  the RENAMED title Brad ruled for is silent' ($n8.Count -eq 0) ('hits=' + $n8.Count)

  # ---- CLEAN TWIN. The adjacent behaviours this change was most likely to have broken.
  # The walk is a DENYLIST, so a reader-facing field somebody adds tomorrow is swept without being listed.
  # An allowlist would leave it silently unswept, which is the direction that fails quietly.
  $w1 = [pscustomobject]@{ a_field_nobody_has_written_yet = 'a healthy weeknight dinner' }
  $g1 = @(Get-TcForbiddenProseHit -Spec $w1 -Terms $TERMS)
  Assert-FpCase 'CLEAN TWIN     a field the skip list has never heard of is still swept' ($g1.Count -eq 1) ('hits=' + $g1.Count)

  $w2 = [pscustomobject]@{ shop_smart = @('fine', 'a healthy swap') }
  $g2 = @(Get-TcForbiddenProseHit -Spec $w2 -Terms $TERMS)
  Assert-FpCase 'CLEAN TWIN     a term inside an ARRAY of prose is still found, with its index in the field path' `
    ($g2.Count -eq 1 -and $g2[0].Field -eq 'shop_smart[1]') ('hits=' + $g2.Count + ' field=' + $(if ($g2.Count) { $g2[0].Field } else { '-' }))

  Assert-FpCase 'CLEAN TWIN     the committed global list still carries the anchor term Brad named' `
    ((@($TERMS | ForEach-Object { $_.Term }) -contains $script:FP_ANCHOR_TERM)) ('terms=' + @($TERMS).Count)
  Assert-FpCase 'CLEAN TWIN     every listed term carries the reason it is listed' `
    (@($TERMS | Where-Object { -not $_.Reason }).Count -eq 0) ('unreasoned=' + @($TERMS | Where-Object { -not $_.Reason }).Count)

  # A list that cannot be read must REFUSE, not report clean. A sweep with no terms finds nothing and
  # looks exactly like a catalogue with nothing to find.
  $threw = $false
  try { $null = Get-TcGlobalForbiddenProse -ListFile (Join-Path $here 'a-list-that-does-not-exist.json') } catch { $threw = $true }
  Assert-FpCase 'MUST FIRE      a MISSING global list throws rather than sweeping against nothing' $threw 'it swept with no terms'

  # THE SEAL. A predicate whose only caller is its own test runs never - the shape that let 51 broken
  # specs walk past every green gate. These assert the two PRODUCTION doors call it.
  $bvs = [IO.File]::ReadAllText((Join-Path $here 'build-v2-spec.ps1'))
  $needle = 'Get-TcForbiddenProse' + 'Hit'
  Assert-FpCase 'CLEAN TWIN     build-v2-spec (the Recipe Hunter''s import door) calls the sweep on its write path' `
    ($bvs -match ('(?m)^\s*\$fpHits\s*=\s*@\(' + [regex]::Escape($needle))) 'the import door does not call it'
  Assert-FpCase '   ...and THROWS on a finding rather than warning' `
    ($bvs -match '(?s)if\(\$fpHits\.Count\)\{[\s\S]{0,500}?throw') 'a listed term would only warn'
  $sg = [IO.File]::ReadAllText((Join-Path $here 'spec-guards.ps1'))
  Assert-FpCase 'CLEAN TWIN     spec-guards fails validation on the same sweep' ($sg -match [regex]::Escape($needle)) 'validation does not call it'

  # The walk, pointed at a real directory of real specs, which is the half a fixture object cannot prove.
  $live = Get-FpSpecFiles -Dir (Join-Path $mp 'db\recipes')
  Assert-FpCase 'CLEAN TWIN     the discovery resolves this checkout''s catalogue and finds the anchor spec' `
    (@($live).Count -gt 100 -and (@($live | ForEach-Object { $_.Name }) -contains $script:FP_ANCHOR_SPEC)) ('resolved=' + @($live).Count)

  if ($script:cases -eq 0) { $script:fail++ }
  ''
  if ($script:fail) {
    Write-Output ('forbidden-prose selftest: {0} FAILED of {1}' -f $script:fail, $script:cases)
    Exit-Guard -Name 'FORBIDDEN-PROSE-SELFTEST' -Code 2 -Summary ('failed={0} of {1}' -f $script:fail, $script:cases)
  }
  Write-Output ('forbidden-prose selftest: {0} of {0} cases pass (both founding titles fire, the attribution carve-out and the two unlistable words stay silent, the denylist walk reaches an unknown field, both production doors call the sweep)' -f $script:cases)
  Exit-Guard -Name 'FORBIDDEN-PROSE-SELFTEST' -Code 0 -Summary ('cases={0}' -f $script:cases)
}

# ------------------------------------------------------------------------------------------------- live run
if (-not $RecipeDir) { $RecipeDir = Join-Path $mp 'db\recipes' }   # its OWN module's data, not a cross-module reach
$terms = $null
try { $terms = Get-TcGlobalForbiddenProse }
catch {
  Write-Output ('audit-forbidden-prose: BLIND - ' + $_.Exception.Message)
  Exit-Guard -Name 'AUDIT-FORBIDDEN-PROSE' -Code 3 -Summary 'blind=no-global-list'
}
if (-not (@($terms | ForEach-Object { $_.Term }) -contains $script:FP_ANCHOR_TERM)) {
  Write-Output ('audit-forbidden-prose: BLIND - the global list parsed to ' + @($terms).Count + ' term(s) but not the anchor "' + $script:FP_ANCHOR_TERM + '" Brad''s ruling named, so it was edited wrong and would pass the catalogue it exists for')
  Exit-Guard -Name 'AUDIT-FORBIDDEN-PROSE' -Code 3 -Summary ('blind=list-missing-anchor terms={0}' -f @($terms).Count)
}
$specs = Get-FpSpecFiles -Dir $RecipeDir
if (-not @($specs).Count) {
  Write-Output ('audit-forbidden-prose: BLIND - resolved 0 spec(s) under ' + $RecipeDir + ', which means the discovery is broken, not that the catalogue is clean')
  Exit-Guard -Name 'AUDIT-FORBIDDEN-PROSE' -Code 3 -Summary 'blind=no-specs'
}

$findings = New-Object System.Collections.ArrayList
$read = 0
$unreadable = @()
foreach ($f in $specs) {
  $spec = $null
  try { $spec = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json }
  catch { $unreadable += $f.Name; continue }
  $read++
  foreach ($h in @(Get-TcForbiddenProseHit -Spec $spec -Terms $terms)) {
    [void]$findings.Add([pscustomobject]@{ Slug = ($f.BaseName); Hit = $h })
  }
}

Write-Output ('audit-forbidden-prose: {0} spec(s) resolved, {1} read ({2} unreadable), against {3} globally forbidden term(s); {4} finding(s)' -f @($specs).Count, $read, $unreadable.Count, @($terms).Count, $findings.Count)
foreach ($u in $unreadable) { Write-Output ('  unreadable (not judged)  ' + $u) }
foreach ($x in $findings) { Write-Output ('  CLAIM    ' + (Format-TcForbiddenProseHit -Hit $x.Hit -Slug $x.Slug)) }

$summary = 'scanned={0} terms={1} findings={2} unreadable={3}' -f $read, @($terms).Count, $findings.Count, $unreadable.Count
if ($findings.Count -or $unreadable.Count) {
  if ($findings.Count) {
    Write-Output '  A title or a sentence on a paid page is OUR claim, whatever blog it came from, and none of these words'
    Write-Output '  has a written bar behind it (Brad, 2026-09-12, backlog I138). Reword it, or bring a bar and put the term'
    Write-Output '  in meal-prep\pipeline\forbidden-prose-global.json''s not_listed with the measurement that justifies it.'
    Write-Output '  A SOURCE ATTRIBUTION line is never a finding here - credit_html, source_url and source_site are not swept.'
  }
  Exit-Guard -Name 'AUDIT-FORBIDDEN-PROSE' -Code 1 -Summary $summary
}
Exit-Guard -Name 'AUDIT-FORBIDDEN-PROSE' -Code 0 -Summary $summary
