<#
  coverage-explain-lib.ps1 - WHY is a product invisible to a commodity's rule? One classifier, two readers.

  LIFTED out of explain-coverage-gap.ps1 on 2026-09-18 (queue 2026-09-18-37ac63, triage-plans\plan-2026-09-18.json)
  so that the EMITTER of the semantic-sweep alert (audit-semantic-identity.ps1) asks the same question the
  diagnosis tool asks. Until then the alert could not tell "no include matches" from "an exclude refused it",
  so every product a rule deliberately refuses was re-paged as "no rule can see it" on every sweep: on
  2026-09-18, 3 of the 7 findings were deliberate refusals (a ready-to-feed formula killed by ready-to-feed,
  two pre-formed patties killed by patties), and two of them had been ruled on already.

  The verdicts, decided in the engine's own first-match-wins order:
    NO-INCLUDE   no include pattern matches                  -> the rule genuinely cannot see it
    EXCLUDED     an include matched, an exclude killed it     -> the rule SAW it and refused it, usually correctly
    CLAIMED      a DIFFERENT commodity matched first          -> the collision trap (widening changes nothing)
    MATCHES      the include matches and nothing excludes it  -> the sweep's premise is wrong for this row

  Same semantics as the explain-coverage-gap.ps1 original, byte for byte in the decision; the patterns are built
  without RegexOptions.Compiled because a reader classifies a handful of findings, and compiling every include
  and exclude of ~590 commodities costs far more than it saves (Compiled changes speed, never a match).
#>

function New-CoverageExplainer {
  param([Parameter(Mandatory = $true)][object[]]$Commodities)
  $rx = [System.Collections.Generic.List[object]]::new()
  $exc = @{}
  foreach ($c in $Commodities) {
    if (-not $c) { continue }
    foreach ($p in @($c.include)) { if ($p) { $rx.Add([pscustomobject]@{ id = [string]$c.id; pat = [string]$p; r = [regex]::new([string]$p, 'IgnoreCase') }) } }
    $l = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($c.exclude)) { if ($p) { $l.Add([pscustomobject]@{ pat = [string]$p; r = [regex]::new([string]$p, 'IgnoreCase') }) } }
    $exc[[string]$c.id] = $l
  }
  return [pscustomobject]@{ rx = $rx; exc = $exc }
}

function Get-CoverageVerdict {
  param([Parameter(Mandatory = $true)]$Explainer, [string]$Name, [string]$WantId)
  # what the engine would actually do, in order
  $claimedBy = ''
  foreach ($e in $Explainer.rx) {
    if (-not $e.r.IsMatch($Name)) { continue }
    $killed = $false
    foreach ($x in $Explainer.exc[$e.id]) { if ($x.r.IsMatch($Name)) { $killed = $true; break } }
    if (-not $killed) { $claimedBy = $e.id; break }
  }
  # what the INTENDED commodity thinks of it
  $incHit = ''
  foreach ($e in $Explainer.rx) { if ($e.id -eq $WantId -and $e.r.IsMatch($Name)) { $incHit = $e.pat; break } }
  $excHit = ''
  if ($Explainer.exc.ContainsKey($WantId)) { foreach ($x in $Explainer.exc[$WantId]) { if ($x.r.IsMatch($Name)) { $excHit = $x.pat; break } } }

  if ($claimedBy -and $claimedBy -ne $WantId) { return [pscustomobject]@{ verdict = 'CLAIMED'; detail = "claimed first by '$claimedBy'" } }
  if ($incHit -and $excHit) { return [pscustomobject]@{ verdict = 'EXCLUDED'; detail = "include '$incHit' matched, exclude '$excHit' killed it" } }
  if ($incHit) { return [pscustomobject]@{ verdict = 'MATCHES'; detail = "include '$incHit' already matches - the sweep's premise is wrong for this row" } }
  # REFUSED-BY-EXCLUDE (2026-09-19, queue 2026-09-19-4f01f6). No admit pattern matches, but the intended commodity's own
  # exclude matches the name, so the rule would refuse it on sight even if an admit were widened to reach it: 'Jj's
  # Bakery Pie, Pumpkin Spice' on pie-pumpkins hits the 'spice' exclude. That is a refusal the rule already made,
  # not a product no rule can see. Classification only: nothing here is read by the matcher, so no cell moves.
  if ($excHit) { return [pscustomobject]@{ verdict = 'REFUSED-BY-EXCLUDE'; detail = "no admit pattern matches, and exclude '$excHit' would refuse it anyway" } }
  return [pscustomobject]@{ verdict = 'NO-INCLUDE'; detail = 'no include pattern matches' }
}

# Split coverage findings into what an alert should carry and what a rule deliberately refused. ONLY EXCLUDED
# leaves the alerted set: CLAIMED, MATCHES and NO-INCLUDE each still need a person. A suppressed row keeps its
# verdict and detail, and the caller keeps it in the findings file, so explain-coverage-gap still lists it.
# Returns arrays (.ToArray()), never a List, so a caller may wrap the result in @() under PS 5.1.
function Split-CoverageFindings {
  param([object[]]$Rows, [Parameter(Mandatory = $true)]$Explainer)
  $alert = [System.Collections.Generic.List[object]]::new()
  $excluded = [System.Collections.Generic.List[object]]::new()
  foreach ($r in @($Rows)) {
    if (-not $r) { continue }
    $v = Get-CoverageVerdict -Explainer $Explainer -Name ([string]$r.product) -WantId ([string]$r.id)
    if ($v.verdict -eq 'EXCLUDED' -or $v.verdict -eq 'REFUSED-BY-EXCLUDE') {
      $copy = [ordered]@{}
      foreach ($p in $r.PSObject.Properties) { $copy[$p.Name] = $p.Value }
      $copy['verdict'] = $v.verdict; $copy['detail'] = $v.detail
      $excluded.Add([pscustomobject]$copy)
    } else { $alert.Add($r) }
  }
  return [pscustomobject]@{ alert = $alert.ToArray(); excluded = $excluded.ToArray() }
}
