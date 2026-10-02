<#
  ff-name-score-lib.ps1 - how much of a BOARD ITEM'S name a candidate product name carries. Dot-source it.

  Lifted out of fix-links-ff.ps1 (2026-10-02) so resolve-familyfare-urls.ps1 judges "is this the board item?"
  with the same arithmetic, rather than a second copy that drifts. The score is the share of the board name's
  words (longer than 2 characters, punctuation dropped) that appear in the candidate name: 1.0 means every
  board word is there, 0 means none is.

  It is a recall score over the BOARD's words only, so a candidate that shares just the brand scores
  (brand words / board words), which is why both callers hold a 0.75 floor rather than "any overlap"
  ([[same-brand-different-product]]).
#>

function Get-FfNameScore([string]$board, [string]$cand) {
  $n = { param($x) (($x.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s{2,}', ' ').Trim() }
  $b = @((& $n $board) -split ' ' | Where-Object { $_.Length -gt 2 })
  $c = (& $n $cand)
  if (-not $b.Count) { return 0 }
  $h = 0; foreach ($w in $b) { if ($c -match [regex]::Escape($w)) { $h++ } }
  return [math]::Round($h / $b.Count, 3)
}
