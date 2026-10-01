# rescue-owed-lib.ps1 - which of a walled store's at-risk board cells its worklist must lead with today.
#
# WHY (2026-10-01). build-rescue-worklist.ps1 writes out\rescue-terms-<urlkey>.txt every daily chain: the cells a
# walled store (Walmart, Sam's Club, Aldi, Fareway) has DROPPED, cannot TRACE to a capture still on disk, is about to
# EXPIRE, or serves from past the union window - "the terms to search FIRST". Nothing read it. Get-CaptureWorklist built
# each store's list from the ruling, the price-flag verifications, the ad, the rotation and the expiries, and on
# 2026-10-01 all five DROPPED cells (horseradish at Walmart and Aldi, teriyaki sauce, brussels sprouts, sirloin steak)
# were absent from every worklist. Four were swept only because the browser run compared the two lists by hand, and
# Fareway's sirloin steak was missed. So the worklist now reads the file itself and leads with it.
#
# Dot-sourced by capture-policy-lib.ps1 (its sibling-lib line) and by test-rescue-owed-lib.ps1, which holds the fixtures.
# Lives here, not in capture-policy-lib, which sits at its file-size mark. Pure functions: no write, no cursor move.
#
# SCOPE OF A CLEAN REPORT: not a detector. An empty Terms list with Blind = $false means the file was read, fresh, and
# named nothing this store's catalogue carries; with Blind = $true the file was missing for a walled store, unreadable
# or stale, and Why says which. Either way nothing is prepended, so the worst a blind read costs is the day before.

# The freshest file the 06:15 browser run can see is the one the PREVIOUS day's chain wrote (~08:40), so an as-of of
# today or yesterday is current; anything older means the chain did not rebuild it, and its cells may already be
# recovered. First plausible value, 1 variant tried.
$script:RescueMaxAgeDays = 1

function Get-TcRescueOwed {
  <#
    .SYNOPSIS The entries of out\rescue-terms-<urlkey>.txt for -Store, if that file is current for -Today.
    .OUTPUTS @{ Entries (term, id, section); File; Blind; Why }
  #>
  param([Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$Today,
        [string]$StoresFile = '')
  $none = [pscustomobject]@{ Entries = @(); File = ''; Blind = $false; Why = '' }
  if (-not $StoresFile) { $StoresFile = Join-Path $PSScriptRoot 'stores.json' }
  $reg = $null
  try { $reg = ConvertFrom-Json ([IO.File]::ReadAllText($StoresFile)) } catch { $reg = $null }
  if ($null -eq $reg) { $none.Blind = $true; $none.Why = ('stores.json could not be read (' + $StoresFile + '), so which stores own a rescue list is unknown'); return $none }
  $row = @(@($reg.stores) | Where-Object { [string]$_.name -eq $Store })
  if ($row.Count -eq 0) { $none.Blind = $true; $none.Why = ("store '" + $Store + "' is not in stores.json"); return $none }
  if (-not $row[0].walled) { $none.Why = ($Store + ' is not a walled store, so build-rescue-worklist writes it no rescue list'); return $none }
  $urlkey = [string]$row[0].urlkey
  $file = Join-Path $OutDir ('rescue-terms-' + $urlkey + '.txt')
  $none.File = $file
  if (-not (Test-Path -LiteralPath $file)) { $none.Blind = $true; $none.Why = ('no ' + (Split-Path $file -Leaf) + ' on disk, so the cells this store is losing are unknown here'); return $none }
  $lines = @()
  try { $lines = [IO.File]::ReadAllLines($file) } catch { $none.Blind = $true; $none.Why = ((Split-Path $file -Leaf) + ' could not be read: ' + $_.Exception.Message); return $none }
  $asOf = ''
  foreach ($l in $lines) {
    $m = [regex]::Match($l, '^#\s*generated\b.*\bas-of\s+(\d{4}-\d{2}-\d{2})')
    if ($m.Success) { $asOf = $m.Groups[1].Value; break }
  }
  if (-not $asOf) { $none.Blind = $true; $none.Why = ((Split-Path $file -Leaf) + ' carries no "as-of" date, so whether it is current is unknown'); return $none }
  $age = ([datetime]::ParseExact($Today, 'yyyy-MM-dd', $null) - [datetime]::ParseExact($asOf, 'yyyy-MM-dd', $null)).Days
  if ($age -lt 0 -or $age -gt $script:RescueMaxAgeDays) {
    $none.Blind = $true
    $none.Why = ('{0} is as-of {1}, {2} day(s) from {3}; only today''s or yesterday''s list is current' -f (Split-Path $file -Leaf), $asOf, $age, $Today)
    return $none
  }
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($l in $lines) {
    if (-not $l -or $l.StartsWith('#')) { continue }
    $p = $l -split "`t"
    if ($p.Count -lt 3) { continue }
    $t = $p[0].Trim(); $id = $p[1].Trim()
    if ($t -and $id) { $entries.Add([pscustomobject]@{ term = $t; id = $id; section = $p[2].Trim() }) }
  }
  return [pscustomobject]@{ Entries = $entries.ToArray(); File = $file; Blind = $false
                            Why = ('{0} (as-of {1}): {2} at-risk cell(s)' -f (Split-Path $file -Leaf), $asOf, $entries.Count) }
}

# The terms Get-CaptureWorklist leads with for those cells, right after the price-flag verifications and inside the same
# room, so the rotation keeps its drip and a cut-short run spends its requests on cells the board is losing. Every
# catalogue term of each commodity (the carry keys on the commodity, as the verifications do). A commodity that does
# not fit the room is DEFERRED and counted, never half-asked; it leads again tomorrow while the file still names it.
function Select-TcRescueTerms {
  param([Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$Today,
        $All, $SkipIds, [int]$Room, [string]$StoresFile = '')
  $ro = Get-TcRescueOwed -Store $Store -OutDir $OutDir -Today $Today -StoresFile $StoresFile
  $out = New-Object System.Collections.Generic.List[object]
  $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $deferred = 0; $unknown = 0
  foreach ($e in @($ro.Entries)) {
    $id = [string]$e.id
    if ($taken.Contains($id) -or (@($SkipIds) -contains $id)) { continue }
    $hits = @($All | Where-Object { [string]$_.id -eq $id })
    if ($hits.Count -eq 0) { $unknown++; continue }          # a commodity the search catalogue no longer carries
    if (($out.Count + $hits.Count) -gt [math]::Max(0, $Room)) { $deferred++; continue }
    [void]$taken.Add($id)
    foreach ($h in $hits) { $out.Add($h) }
  }
  $why = $ro.Why
  if ($deferred -or $unknown) { $why += ('; {0} deferred for room, {1} not in the catalogue' -f $deferred, $unknown) }
  return [pscustomobject]@{ Terms = $out.ToArray(); Ids = @($taken); Owed = @(@($ro.Entries) | ForEach-Object { [string]$_.id } | Select-Object -Unique)
                            Deferred = $deferred; Unknown = $unknown; Blind = [bool]$ro.Blind; Why = $why }
}
