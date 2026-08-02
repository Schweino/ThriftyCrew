<#
  recipe-coherence-lib.ps1 - the invariants a recipe must satisfy to be internally honest, in one place.

  WHY THIS EXISTS (2026-08-02). Brad found a card that BOUGHT rice vinegar, ground ginger and red pepper
  flakes and never mentioned them in a step. A sweep of all 500 sourced recipes found 573 defects of that
  family, and the retrospective is the useful part:

    NONE OF IT WAS AN AGENT BEING CARELESS. The recipe pipeline derives TWO artifacts from one source -
    the ingredient mapper produces the costed list, the writer produces the steps - and until today
    NOTHING EVER COMPARED THEM. Two derived artifacts from one source, never reconciled, is a defect
    generator; it will produce the same class again with better-instructed agents, because the failure is
    that nobody was looking, not that somebody was sloppy.

    AND THE GATE THAT SHOULD HAVE CAUGHT THE CREDIT GAP CHECKED THE WRONG THING. spec-guards required
    `source_url` to EXIST as a key. All 113 original recipes carried it as an empty string, passed, and
    published with no attribution for weeks. Presence is not a value.

  So these are gates, not guidance. Every one of them is cheap, deterministic, and runs before a recipe
  can publish.

  THE MATCHER IS DELIBERATELY FORGIVING, because a gate that cries wolf gets switched off. An ingredient
  counts as used when ANY distinctive word in its name appears in the steps: "93/7 Ground Beef" is used by
  "brown the beef", and "Boneless Skinless Chicken Breast" by "shred the chicken". Preparation and grade
  words are stripped first - a step never has to say "boneless" or "reduced fat" to have used the thing.
  Measured over all 513 live specs with this matcher: 66 findings across 34 recipes, all of them real.
#>

# Words that never identify an ingredient by themselves. They describe how it was cut, graded or packed,
# and requiring a step to echo them would flag every correctly written recipe in the catalogue.
$script:RC_STOP = @(
  'fresh','frozen','dried','ground','boneless','skinless','reduced','fat','free','low','sodium',
  'large','small','whole','extra','virgin','sweet','hot','mild','light','dark','shredded','diced',
  'crushed','chopped','sliced','minced','canned','can','cans','jar','bottle','bag','box','pack',
  'seasoning','powder','mix','style','flavor','and','with','the','of','in','no','added','value',
  'generic','brand','organic','natural','all','purpose','plain','pure','real','best','family'
)

function Test-RcIngredientUsed([string]$item, [string]$stepsText) {
  <# Does any distinctive word of this ingredient's name appear in the steps? Singular/plural tolerant.
     An ingredient whose name is ENTIRELY stopwords returns $true: there is nothing to look for, and
     accusing on no evidence is how a gate loses its credibility. #>
  $words = @(($item.ToLower() -replace '[^a-z0-9 ]', ' ') -split '\s+' |
             Where-Object { $_.Length -ge 4 -and $script:RC_STOP -notcontains $_ })
  if ($words.Count -eq 0) { return $true }
  foreach ($w in $words) {
    $stem = if ($w.Length -gt 5 -and $w.EndsWith('es')) { $w.Substring(0, $w.Length - 2) }
            elseif ($w.EndsWith('s')) { $w.Substring(0, $w.Length - 1) }
            else { $w }
    if ($stepsText -match ('\b' + [regex]::Escape($stem))) { return $true }
  }
  return $false
}

function Get-RcStepsText($spec) {
  return ((@($spec.make_it) -join ' ') + ' ' + (@($spec.head.steps) -join ' ')).ToLower()
}

function Get-RcUnusedIngredients($spec) {
  <# THE GENERAL TSO GATE: every ingredient the shopper is told to buy must be used by a step. #>
  $steps = Get-RcStepsText $spec
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($ing in @($spec.scaler.ing)) {
    $item = [string]$ing.item
    if (-not $item) { continue }
    if (-not (Test-RcIngredientUsed $item $steps)) { $out.Add($item) }
  }
  return @($out.ToArray())
}

function Get-RcEmptyRequired($spec) {
  <# PRESENCE IS NOT A VALUE. spec-guards already required these keys to exist; all 113 original recipes
     carried source_url, source_site and credit_html as empty strings, passed that check, and published
     with no attribution at all. #>
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($k in @('name', 'slug', 'source_url', 'source_site', 'credit_html', 'intro_html',
                   'portion_html', 'cost_closing_html', 'upsell_html')) {
    if (-not ([string]$spec.$k).Trim()) { $out.Add($k) }
  }
  if ($spec.head) {
    foreach ($k in @('description', 'keywords', 'prepTime', 'cookTime', 'totalTime')) {
      if (-not ([string]$spec.head.$k).Trim()) { $out.Add("head.$k") }
    }
  }
  # A credit that does not link anywhere is not a credit.
  $u = [string]$spec.source_url
  if ($u -and $u -notmatch '^https?://') { $out.Add('source_url (not an http(s) URL)') }
  return @($out.ToArray())
}
