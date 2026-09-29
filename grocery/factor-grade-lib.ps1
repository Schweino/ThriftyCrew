# factor-grade-lib.ps1 - WHICH board cells guard 4 (factor mismatch: board vs its own product link) grades.
#
# Guard 4 exempts a weekly-ad SALE cell on purpose: a printed ad may price a different pack than the everyday
# link shows, so board and link are allowed to disagree. A Sam's Club ROLLBACK is not an ad. build-sams-deals
# types it `sale` only so its 30-day window can retire it (rollback-ttl-lib Set-RollbackFields stamps
# ad_basis 'ttl'; the builder stamps source_ad 'everyday club price (<club>)'), and its link is the same product
# at the same size, merely marked down. Exempting it hid 46 of 321 Sam's cells (14%) from guard 4 from the
# 2026-09-23 board on (queue 2026-09-28-a5268a). Brad's ruling 2026-09-29: grade the rollback, keep the real
# weekly-ad sale exempt.
#
# SCOPE: Sam's Club rollbacks only, as ruled. Walmart rollbacks (ad_basis 'store', source_ad 'everyday shelf
# price') and Fareway site sales (ad_basis 'ttl', source_ad shop.fareway.com) are the same shape of question and
# are NOT graded here; the triage plan for this change records them as leaves_open with their counts.
#
# No load side effects. Self-test: grocery\test-factor-grade.ps1.

function Test-TcSamsRollbackCell {
  # A board cell is a Sam's rollback when ALL of: store Sam's Club, typed sale, ad_basis 'ttl' (the rollback
  # window, never a printed ad's dates), and source_ad naming the everyday club price the builder read.
  # Each field is read by presence: an absent field is a non-match, never a guess.
  param($Cell)
  if ($null -eq $Cell) { return $false }
  if (-not [string]::Equals([string]$Cell.store, "Sam's Club", [StringComparison]::Ordinal)) { return $false }
  if (-not [string]::Equals([string]$Cell.type, 'sale', [StringComparison]::Ordinal)) { return $false }
  $ab = $Cell.PSObject.Properties['ad_basis']
  if (-not $ab -or -not [string]::Equals([string]$ab.Value, 'ttl', [StringComparison]::Ordinal)) { return $false }
  $sa = $Cell.PSObject.Properties['source_ad']
  if (-not $sa) { return $false }
  return ([string]$sa.Value).StartsWith('everyday club price', [StringComparison]::Ordinal)
}

function Test-TcFactorGuardGrades {
  # True when guard 4 compares this cell against its link: every EVERYDAY cell, and a Sam's rollback.
  param($Cell)
  if ($null -eq $Cell) { return $false }
  $t = [string]$Cell.type
  if ([string]::Equals($t, 'everyday', [StringComparison]::Ordinal)) { return $true }
  return (Test-TcSamsRollbackCell $Cell)
}
