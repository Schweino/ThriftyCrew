<#
  browser-feeds-lib.ps1 - the ONE definition of "which feeds the weekly browser refresh owns, and how old is
  each one". Dot-sourced by browser-refresh-due.ps1 (the pre-run idempotency gate) and by check-ad-cycles.ps1
  (the missed-refresh alert).

  *** WHY THIS FILE EXISTS ***
  Those two consumers each carried their own copy of the same six globs and the same freshness comparison, and
  the copies drifted the way that class always does: NEITHER listed Fareway. Fareway is a browser store and
  supplies 433 of the board's cells, so when its weekly sweep was skipped on 2026-07-29 the pre-run gate printed
  FRESH (which tells the agent to STOP without pulling anything) and the alert to Brad could not name the store
  either. One store went a week unrefreshed with every signal green.

  *** NO param() BLOCK IN THIS FILE, DELIBERATELY ***
  Dot-sourcing a script runs its param() block in the CALLER's scope. capture-lib.ps1 learned this the hard way
  on 2026-07-29: a `param([switch]$SelfTest)` in a shared lib silently reset every builder's own $SelfTest to
  $false. A shared library must not declare parameters at all, so it cannot collide with its callers.
#>

function Get-CaptureDateFromName([string]$baseName) {
  <#
    The capture date is the one in the FILENAME, never LastWriteTime.
    Both gates used to sort on mtime, so ANY maintenance sweep that rewrote a historical capture made it read as
    this week's pull. That is not hypothetical: heal-mojibake.ps1 -Apply rewrote every out\regular\*-regular-*.json
    on 2026-07-29 to repair corrupted brand names, and afterwards two ELEVEN-DAY-OLD captures
    (walmart-regular-2026-07-18, bakers-regular-2026-07-18) satisfied the weekly freshness check.
  #>
  $m = [regex]::Match($baseName, '(\d{4}-\d{2}-\d{2})$')
  if (-not $m.Success) { return $null }                      # rejects/meta side files carry no capture date
  try { return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null) } catch { return $null }
}

function Get-NewestCaptureDate([string]$glob) {
  $best = $null
  foreach ($f in (Get-ChildItem $glob -ErrorAction SilentlyContinue)) {
    $d = Get-CaptureDateFromName $f.BaseName
    if ($null -eq $d) { continue }
    if (($null -eq $best) -or ($d -gt $best)) { $best = $d }
  }
  return $best
}

function Get-BrowserFeedDates {
  <#
    Returns an ordered map of feed label -> newest capture date (or $null if the feed has no dated file at all).
    ADD A BROWSER STORE HERE AND BOTH the pre-run gate AND the missed-refresh alert pick it up.
  #>
  param([Parameter(Mandatory = $true)][string]$OutDir)
  return [ordered]@{
    "Baker's ad"       = (Get-NewestCaptureDate (Join-Path $OutDir 'bakers\bakers-deals-*.json'))
    "Sam's"            = (Get-NewestCaptureDate (Join-Path $OutDir 'sams\sams-deals-*.json'))
    "Baker's everyday" = (Get-NewestCaptureDate (Join-Path $OutDir 'regular\bakers-regular-*.json'))
    "Hy-Vee everyday"  = (Get-NewestCaptureDate (Join-Path $OutDir 'regular\hyvee-regular-*.json'))
    "Walmart everyday" = (Get-NewestCaptureDate (Join-Path $OutDir 'regular\walmart-regular-*.json'))
    "Aldi everyday"    = (Get-NewestCaptureDate (Join-Path $OutDir 'regular\aldi-regular-*.json'))
    "Fareway everyday" = (Get-NewestCaptureDate (Join-Path $OutDir 'regular\fareway-regular-*.json'))
  }
}
