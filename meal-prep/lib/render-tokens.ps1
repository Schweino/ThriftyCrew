# render-tokens.ps1 - expand {{stat}} tokens in a spec's prose at RENDER time.
#
# WHY THIS EXISTS (2026-08-08 architecture review, Brad's call). Until now every price and calorie figure a
# reader sees was a LITERAL baked into the prose text, which meant the sentence had to be re-edited every
# time the number moved. That one decision generated most of the estate's recurring defects: the reanchor
# pair (machine fields moved, prose left quoting the old price - happened twice in one day), the 15
# slow-cooker specs understating cost by up to $1.75 for weeks, the prose disaster that rewrote 11 bounds,
# and six scripts whose whole job was moving numbers already known elsewhere.
#
# The cure: prose stores TOKENS ("at roughly ${{cost_ps}} a bowl"), and the render boundary substitutes the
# spec's own stat at build/publish time. The number can never disagree with the sentence again, because the
# sentence does not contain a number.
#
# TOKENS (all resolved from the spec's own stat block - never from a manifest, never from the wall clock):
#   {{cost_ps}}   stat.cost_ps   (string, 2dp - the everyday per-serving cost)
#   {{cal}}       stat.cal       (int)
#   {{protein}}   stat.protein   (int)
#
# BOUNDS ARE NOT TOKENS, deliberately. "under 400 calories" is a CLAIM whose truth the bounded-claim gate
# already checks against stat; tokenizing it would rewrite the promise whenever the stat moved, which is
# exactly the corruption the 2026-08-07 prose disaster produced by accident.
#
# Dot-source:  . (Join-Path $mp 'lib\render-tokens.ps1')
# Self-test:   powershell -File lib\render-tokens.ps1 -SelfTest
param([switch]$SelfTest)

$script:TOKEN_FIELDS = @('intro_html','portion_html','cost_closing_html','upsell_html')  # + head.description

function Expand-SpecTokens { param([string]$Text, $Spec)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  if ($Text.IndexOf('{{') -lt 0) { return $Text }
  $map = @{
    'cost_ps' = [string]$Spec.stat.cost_ps
    'cal'     = [string][int]$Spec.stat.cal
    'protein' = [string][int]$Spec.stat.protein
  }
  $out = [regex]::Replace($Text, '\{\{(\w+)\}\}', {
    param($m)
    $k = $m.Groups[1].Value
    if (-not $map.ContainsKey($k)) { throw ("render-tokens: unknown token '{{{{{0}}}}}' - a typo in prose would otherwise ship to a reader verbatim" -f $k) }
    if ([string]::IsNullOrEmpty($map[$k])) { throw ("render-tokens: token '{{{{{0}}}}}' resolves to an EMPTY stat - the spec is missing the number its prose promises" -f $k) }
    $map[$k]
  })
  if ($out.IndexOf('{{') -ge 0) { throw 'render-tokens: unexpanded token survived - refusing to render it to a reader' }
  return $out
}

# Expand every prose field of a parsed spec IN MEMORY, returning the spec. This is the one call the render
# boundary (build-card2, publish) makes; nothing downstream ever sees a token.
function Expand-SpecProse { param($Spec)
  foreach ($k in $script:TOKEN_FIELDS) {
    $v = [string]$Spec.$k
    if ($v) { $Spec.$k = Expand-SpecTokens -Text $v -Spec $Spec }
  }
  if ($Spec.head -and $Spec.head.PSObject.Properties['description']) {
    $d = [string]$Spec.head.description
    if ($d) { $Spec.head.description = Expand-SpecTokens -Text $d -Spec $Spec }
  }
  return $Spec
}

# Ghost owns recipe prose, never grocery-price authority. Replace this recipe's
# old static cost token with a live hydration target in HTML fields, and remove
# it from non-hydratable metadata. The $1 membership sentence is intentionally
# untouched because it is not a grocery price and does not equal stat.cost_ps.
function Move-SpecPriceToReleaseHydration { param($Spec)
  $cost = [string]$Spec.stat.cost_ps
  if ([string]::IsNullOrEmpty($cost)) { return $Spec }
  $pattern = '\$' + [regex]::Escape($cost)
  $markup = '<span data-tc-live-price>current release price loading</span>'
  foreach ($k in $script:TOKEN_FIELDS) {
    $v = [string]$Spec.$k
    if ($v) { $Spec.$k = [regex]::Replace($v, $pattern, $markup) }
  }
  if ($Spec.head -and $Spec.head.PSObject.Properties['description']) {
    $description = [string]$Spec.head.description
    $priceClause = '\s+for about ' + $pattern + '\s+(?:a|per)\s+[^.]+\.?'
    $description = [regex]::Replace($description, $priceClause, '.')
    $Spec.head.description = Remove-GhostStaticCurrencyClaims ([regex]::Replace($description, $pattern, 'live promoted-release pricing'))
  }
  return $Spec
}

function Remove-GhostStaticCurrencyClaims { param([string]$Text)
  if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch '\$\d') { return $Text }
  $membership = '__TC_MEMBERSHIP_PRICE__'
  $out = $Text.Replace('$1 a month', $membership)
  $amount = '\$\d+(?:\.\d+)?'
  $out = [regex]::Replace($out, $amount + '\s*(?:to|[-–])\s*' + $amount, 'far more')
  $out = [regex]::Replace($out, '(?i)(?:roughly|around|about|near)\s+' + $amount, 'substantially')
  $out = [regex]::Replace($out, '(?i)under\s+' + $amount, 'on a strong sale')
  $out = [regex]::Replace($out, '(?i)' + $amount + '\s+or more', 'far more')
  $out = [regex]::Replace($out, $amount, 'restaurant-priced')
  return $out.Replace($membership, '$1 a month')
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $spec = '{"stat":{"cal":460,"protein":38,"cost_ps":"5.76"}}' | ConvertFrom-Json

  T 'money token expands to the spec''s own stat' `
    ((Expand-SpecTokens 'about ${{cost_ps}} a bowl' $spec) -eq 'about $5.76 a bowl') (Expand-SpecTokens 'about ${{cost_ps}} a bowl' $spec)
  T 'cal + protein expand together' `
    ((Expand-SpecTokens 'near {{cal}} calories with {{protein}} grams of protein' $spec) -eq 'near 460 calories with 38 grams of protein') 'mismatch'
  T 'CLEAN TWIN text with no tokens is returned untouched (fast path)' `
    ((Expand-SpecTokens 'no tokens here, just $1 a month' $spec) -eq 'no tokens here, just $1 a month') 'rewritten'

  # MUST FIRE: a typo'd token must throw, never ship "{{cost_p}}" to a reader.
  $threw = $false; try { Expand-SpecTokens 'about ${{cost_p}} a bowl' $spec | Out-Null } catch { $threw = $true }
  T 'MUST FIRE  an unknown token throws instead of rendering verbatim' $threw 'shipped a typo'

  # MUST FIRE: a token resolving to an empty stat is the turkey-pozole class (five empty fields shipped
  # because nothing checked what a write resolved to).
  $bad = '{"stat":{"cal":460,"protein":38,"cost_ps":""}}' | ConvertFrom-Json
  $threw2 = $false; try { Expand-SpecTokens 'about ${{cost_ps}} a bowl' $bad | Out-Null } catch { $threw2 = $true }
  T 'MUST FIRE  a token resolving to an empty stat throws' $threw2 'rendered "about $ a bowl"'

  # Expand-SpecProse touches all five surfaces including head.description.
  $full = '{"stat":{"cal":610,"protein":57,"cost_ps":"3.58"},"intro_html":"x {{protein}}g","portion_html":"{{cal}} cal","cost_closing_html":"${{cost_ps}}","upsell_html":"${{cost_ps}} a bowl","head":{"description":"about ${{cost_ps}} each","costPerServing":3.58}}' | ConvertFrom-Json
  $e = Expand-SpecProse $full
  T 'Expand-SpecProse expands all four prose fields + head.description' `
    ($e.intro_html -eq 'x 57g' -and $e.portion_html -eq '610 cal' -and $e.upsell_html -eq '$3.58 a bowl' -and $e.head.description -eq 'about $3.58 each') `
    ($e.head.description)

  $h = Move-SpecPriceToReleaseHydration $e
  T 'Ghost prose price becomes a live release hydration target while membership pricing is untouched' `
    ($h.upsell_html -eq '<span data-tc-live-price>current release price loading</span> a bowl' -and $h.head.description -notmatch '\$3\.58') `
    ($h.upsell_html + ' / ' + $h.head.description)
  T 'non-release currency claims become qualitative while membership pricing remains' `
    ((Remove-GhostStaticCurrencyClaims 'runs $14 to $17, saves around $12, members pay $1 a month') -eq 'runs far more, saves substantially, members pay $1 a month') `
    (Remove-GhostStaticCurrencyClaims 'runs $14 to $17, saves around $12, members pay $1 a month')

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
