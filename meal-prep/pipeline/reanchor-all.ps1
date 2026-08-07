# reanchor-all.ps1 - the ONE door for re-anchoring specs after a price recompute.
#
# WHY THIS EXISTS (2026-08-07). Re-anchoring is two writes that must both happen:
#   reanchor-machine-fields.ps1  stamps stat.cost_ps + head.costPerServing from the manifest
#   reanchor-moved-prose.ps1     moves the prose dollar figures to match
# Running the FIRST without the SECOND leaves every affected spec quoting two different prices for the same
# serving - the machine field says one number, the sentence next to it says another, and both ship. Nothing
# in the estate paired them, so it happened TWICE in one session (2026-08-07: 512 specs, then 1531 findings
# on the contradiction gate). Both times the specs were internally consistent beforehand, so it was caused,
# not exposed.
#
# A third step used to be required and is now automatic: moved-prose diffs against the PRE-recompute
# manifest, which compute-v2-perserving.ps1 now snapshots to v2-perserving.prev.json before overwriting.
#
# THE CARDS ARE NOT RE-ANCHORED HERE. A spec whose cost moved has a built card and a live page still showing
# the old number, and this script reports exactly which slugs those are so the caller can rebuild+publish
# them. It does not do it silently: republishing live pages is the caller's decision, not a side effect of
# a price recompute.
#
# Run:  .\reanchor-all.ps1              (re-anchor, then verify, then list slugs needing a card rebuild)
#       .\reanchor-all.ps1 -VerifyOnly  (no writes; just report what disagrees)
param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$isVerifyOnly = [bool]$VerifyOnly            # capture BEFORE dot-sourcing: a lib's param() binds into THIS scope
. (Join-Path $mp 'lib\render-tokens.ps1')    # Expand-SpecProse, used by the token half of the invariant
$prev = Join-Path $here 'v2-perserving.prev.json'
$specDir = Join-Path $mp 'db\recipes'
$builtDir = Join-Path $mp 'db\built'

# ---- the invariant this whole script exists to hold - REWRITTEN 2026-08-08 for prose templating ----
# Prose no longer stores money figures at all: it stores {{cost_ps}}/{{cal}}/{{protein}} tokens, and
# lib\render-tokens.ps1 substitutes the spec's own stat at render. So the old invariant ("every $N.NN in
# prose equals stat.cost_ps") is superseded by two stronger ones:
#   1. NO money literal may exist in the five reader-prose surfaces AT ALL. A literal can only arrive from
#      a batch promote whose writers typed real numbers and skipped migrate-prose-tokens - and a literal is
#      a number that will silently rot the day the stat moves, which is the whole class templating ended.
#   2. Every token must EXPAND: unknown token names or empty stats throw at render, so they must throw
#      here first, where the daily chain reports them, not at 6:31am inside build-cards.
function Get-ProseMoneyDisagreements {
  $out = New-Object System.Collections.Generic.List[object]
  foreach($f in (Get-ChildItem (Join-Path $specDir '*.json'))){
    $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($fld in @('intro_html','portion_html','cost_closing_html','upsell_html')){
      foreach($m in [regex]::Matches([string]$s.$fld, '\$(\d+\.\d{2})')){
        $out.Add([pscustomobject]@{ slug=$f.BaseName; field=$fld; quotes=$m.Groups[1].Value; why='money LITERAL in templated prose - run migrate-prose-tokens.ps1 -Slugs ' + $f.BaseName + ' -Apply' })
      }
    }
    foreach($m in [regex]::Matches([string]$s.head.description, '\$(\d+\.\d{2})')){
      $out.Add([pscustomobject]@{ slug=$f.BaseName; field='head.description'; quotes=$m.Groups[1].Value; why='money LITERAL in templated prose' })
    }
    # every token must expand against this spec's own stat (typo'd names and empty stats throw)
    try { Expand-SpecProse ($s) | Out-Null }
    catch { $out.Add([pscustomobject]@{ slug=$f.BaseName; field='(tokens)'; quotes=''; why=$_.Exception.Message }) }
  }
  return $out
}

if($isVerifyOnly){
  $d = Get-ProseMoneyDisagreements
  Write-Output ("verify only: {0} prose money/token finding(s) across {1} spec(s)" -f $d.Count, (@($d | Select-Object -ExpandProperty slug -Unique)).Count)
  $d | Select-Object -First 20 | ForEach-Object { Write-Output ("  {0} {1} {2} - {3}" -f $_.slug,$_.field,$(if($_.quotes){'$'+$_.quotes}else{''}),$_.why) }
  exit $(if($d.Count){ 1 } else { 0 })
}

$listPath = Join-Path $here 'reanchor-stale-cards.txt'
# TRUNCATE BEFORE ANY WORK, not after it. Writing the list only at the END means a crash between
# machine-fields and moved-prose leaves YESTERDAY's list sitting on disk - and the daily chain's Test-Path
# then finds a perfectly readable file and republishes those slugs from specs that are now half-anchored,
# quoting two prices. Emptying it first makes a crash publish NOTHING, which is the safe direction. This is
# the same stale-proof-file class the end-of-run write already fixed for the clean-day case; the crash case
# was still open.
'' | Out-File $listPath -Encoding utf8

if(-not (Test-Path $prev)){
  throw ("no $prev - compute-v2-perserving.ps1 writes it before overwriting the manifest. If this is the first run after that change landed, run compute-v2-perserving.ps1 once and re-run this.")
}

Write-Output '1/2 reanchor-machine-fields'
& (Join-Path $here 'reanchor-machine-fields.ps1') | Select-Object -Last 1
# STEP 2 (reanchor-moved-prose) IS GONE - RETIRED BY TEMPLATING (2026-08-08). Prose stores {{tokens}} that
# resolve from stat at render, so there is no prose figure to move: the machine-field re-anchor above IS the
# whole re-anchor now. The script (and the pre-recompute snapshot dance it needed) lives on in
# archive\retired-by-templating\ with the full story. The $prev gate above stays: compute-v2's snapshot is
# still the proof a recompute actually ran before we stamp machine fields from its output.

Write-Output '2/2 verify the invariant (no money literals; every token expands)'
$d = Get-ProseMoneyDisagreements
if($d.Count){
  Write-Output ("  FINDINGS: {0} across {1} spec(s)" -f $d.Count, (@($d | Select-Object -ExpandProperty slug -Unique)).Count)
  $d | Select-Object -First 15 | ForEach-Object { Write-Output ("    {0} {1} {2} - {3}" -f $_.slug,$_.field,$(if($_.quotes){'$'+$_.quotes}else{''}),$_.why) }
} else {
  Write-Output '  clean: no money literal in prose, every token expands against its own stat'
}

# ---- which live cards are now stale? ----
# A spec that FAILED the invariant above is excluded, and named separately. It quotes two different prices
# for one serving, so rebuilding its card would take that contradiction from the spec file to the live page.
# Excluding per-slug rather than refusing the whole run is deliberate: a handful of specs carry figures that
# predate the manifest and are unreachable by moved-prose (today: 15 slow-cooker slugs). Blocking everything
# on them would mean the other 500-odd cards silently keep drifting - trading a visible contradiction for
# the invisible staleness this whole loop exists to end.
$blocked = @($d | Select-Object -ExpandProperty slug -Unique)
$stale = New-Object System.Collections.Generic.List[string]
$held  = New-Object System.Collections.Generic.List[string]
foreach($f in (Get-ChildItem (Join-Path $specDir '*.json'))){
  $card = Join-Path $builtDir ($f.BaseName + '.body.html')
  if(-not (Test-Path $card)){ continue }
  $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $html = [IO.File]::ReadAllText($card)
  $m = [regex]::Match($html, '\$(\d+\.\d{2})\s*per serving')
  if($m.Success -and [Math]::Abs([double]$m.Groups[1].Value - [double]$s.stat.cost_ps) -gt 0.005){
    if($blocked -contains $f.BaseName){ $held.Add($f.BaseName) } else { $stale.Add($f.BaseName) }
  }
}
Write-Output ''
# The list is written on EVERY run, empty included. Writing it only when non-empty leaves yesterday's list
# on disk, and the daily chain reads this file to decide what to republish - so a clean day would have
# rebuilt and published whatever the last dirty day happened to contain. That is the stale-proof-file class
# (a proof that outlives the work it certifies), and it was caught the first time this was dry-run.
$stale | Out-File $listPath -Encoding utf8
if($held.Count){
  Write-Output ("{0} stale card(s) HELD BACK - their spec fails the money invariant, so republishing would" -f $held.Count)
  Write-Output '  move a two-price contradiction onto the live page. Fix the spec, then they republish normally:'
  $held | Select-Object -First 15 | ForEach-Object { Write-Output ("    HELD $_") }
}
if($stale.Count){
  Write-Output ("{0} built card(s) now show a cost their spec no longer holds. They are NOT rebuilt by this" -f $stale.Count)
  Write-Output 'script. To land them on the live site:'
  Write-Output ('  & .\engine\build-cards.ps1 -Slugs <slugs>   then   & .\engine\publish.ps1 -Slugs <slugs>')
  Write-Output ('  (publish is content-hash gated, so unchanged cards are skipped)')
  Write-Output ("  slug list written to: {0}" -f $listPath)
} else {
  Write-Output 'every built card agrees with its spec cost - nothing to rebuild'
  Write-Output ("  (empty list written to {0} so a stale one cannot be re-read)" -f $listPath)
}
# A COMPLETION MARKER, because the exit code cannot carry this. Under EAP=Stop a throw also exits 1, which is
# the same code "some specs still disagree" uses - so rc alone cannot tell the daily chain "I finished and the
# list below is mine" from "I died half way". The caller requires this line before it publishes anything.
Write-Output ("REANCHOR-COMPLETE stale={0} held={1} disagreements={2}" -f $stale.Count, $held.Count, $d.Count)
exit $(if($d.Count){ 1 } else { 0 })
