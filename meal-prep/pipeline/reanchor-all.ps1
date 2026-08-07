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
$prev = Join-Path $here 'v2-perserving.prev.json'
$specDir = Join-Path $mp 'db\recipes'
$builtDir = Join-Path $mp 'db\built'

# ---- the invariant this whole script exists to hold ----
# every $N.NN in a spec's reader-facing money fields must equal that spec's own stat.cost_ps
function Get-ProseMoneyDisagreements {
  $out = New-Object System.Collections.Generic.List[object]
  foreach($f in (Get-ChildItem (Join-Path $specDir '*.json'))){
    $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $cps = [string]$s.stat.cost_ps
    foreach($fld in @('intro_html','portion_html','cost_closing_html','upsell_html')){
      foreach($m in [regex]::Matches([string]$s.$fld, '\$(\d+\.\d{2})')){
        if($m.Groups[1].Value -ne $cps){ $out.Add([pscustomobject]@{ slug=$f.BaseName; field=$fld; quotes=$m.Groups[1].Value; cost_ps=$cps }) }
      }
    }
    foreach($m in [regex]::Matches([string]$s.head.description, '\$(\d+\.\d{2})')){
      if($m.Groups[1].Value -ne $cps){ $out.Add([pscustomobject]@{ slug=$f.BaseName; field='head.description'; quotes=$m.Groups[1].Value; cost_ps=$cps }) }
    }
  }
  return $out
}

if($VerifyOnly){
  $d = Get-ProseMoneyDisagreements
  Write-Output ("verify only: {0} prose/stat money disagreement(s) across {1} spec(s)" -f $d.Count, (@($d | Select-Object -ExpandProperty slug -Unique)).Count)
  $d | Select-Object -First 20 | ForEach-Object { Write-Output ("  {0} {1} quotes `${2}, stat says `${3}" -f $_.slug,$_.field,$_.quotes,$_.cost_ps) }
  exit $(if($d.Count){ 1 } else { 0 })
}

if(-not (Test-Path $prev)){
  throw ("no $prev - compute-v2-perserving.ps1 writes it before overwriting the manifest. If this is the first run after that change landed, run compute-v2-perserving.ps1 once and re-run this.")
}

Write-Output '1/3 reanchor-machine-fields'
& (Join-Path $here 'reanchor-machine-fields.ps1') | Select-Object -Last 1
Write-Output '2/3 reanchor-moved-prose (vs the pre-recompute snapshot)'
& (Join-Path $here 'reanchor-moved-prose.ps1') -Baseline $prev | Select-Object -Last 1

Write-Output '3/3 verify the invariant'
$d = Get-ProseMoneyDisagreements
if($d.Count){
  Write-Output ("  STILL DISAGREEING: {0} finding(s) across {1} spec(s)" -f $d.Count, (@($d | Select-Object -ExpandProperty slug -Unique)).Count)
  $d | Select-Object -First 15 | ForEach-Object { Write-Output ("    {0} {1} quotes `${2}, stat says `${3}" -f $_.slug,$_.field,$_.quotes,$_.cost_ps) }
  Write-Output '  NOTE: reanchor-moved-prose only rewrites the PREVIOUS manifest value. A figure that was already'
  Write-Output '  wrong before the move is unreachable by it and needs repair-basis-relabel or a hand fix.'
} else {
  Write-Output '  clean: every prose dollar figure equals its own spec stat.cost_ps'
}

# ---- which live cards are now stale? ----
$stale = New-Object System.Collections.Generic.List[string]
foreach($f in (Get-ChildItem (Join-Path $specDir '*.json'))){
  $card = Join-Path $builtDir ($f.BaseName + '.body.html')
  if(-not (Test-Path $card)){ continue }
  $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $html = [IO.File]::ReadAllText($card)
  $m = [regex]::Match($html, '\$(\d+\.\d{2})\s*per serving')
  if($m.Success -and [Math]::Abs([double]$m.Groups[1].Value - [double]$s.stat.cost_ps) -gt 0.005){ $stale.Add($f.BaseName) }
}
Write-Output ''
if($stale.Count){
  Write-Output ("{0} built card(s) now show a cost their spec no longer holds. They are NOT rebuilt by this" -f $stale.Count)
  Write-Output 'script. To land them on the live site:'
  Write-Output ('  & .\engine\build-cards.ps1 -Slugs <slugs>   then   & .\engine\publish.ps1 -Slugs <slugs>')
  Write-Output ('  (publish is content-hash gated, so unchanged cards are skipped)')
  $listPath = Join-Path $here 'reanchor-stale-cards.txt'
  $stale | Out-File $listPath -Encoding utf8
  Write-Output ("  slug list written to: {0}" -f $listPath)
} else {
  Write-Output 'every built card agrees with its spec cost - nothing to rebuild'
}
exit $(if($d.Count){ 1 } else { 0 })
