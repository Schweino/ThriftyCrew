<#
  regular-fileset-lib.ps1 - THE definition of "which out\regular files does the board actually price from".

  *** WHY THIS FILE EXISTS ***
  compare-deals.ps1 owned this rule and guards.ps1 had its own, simpler one: "newest file per store". Those
  two answers differ for exactly one store, and it is the biggest one on the board.

  Walmart has no weekly ad cycle, so a partial daily capture must UNION with recent files instead of replacing
  them (see the EVERYDAY-ONLY note below). The engine therefore prices Walmart from every file inside a 14-day
  window; guards.ps1 opened only the newest. Measured on 2026-07-29: 332 live Walmart board cells came from
  files guard 5 (multipack) and guard 10 (never publish the regular price) never opened. Those two guards exist
  to stop a 2x pack price and a price the store is not charging, and roughly a third of the Walmart cells they
  were supposed to cover were structurally out of reach - a bad row in ANY capture older than today was live on
  the board and unreachable by the gates written to catch it.

  A guard must iterate the SAME file set the engine priced from, or it is guarding a different board than the
  one that ships. Both now call this.

  NOT GUARD 9. Guard 9 measures how FRESH the newest capture is; newest-per-store is the correct question
  there, and widening it would make a store look fresher than it is by averaging in older files. Guard 9
  deliberately keeps its own newest-only lookup.

  *** NO param() BLOCK IN THIS FILE, DELIBERATELY ***
  Dot-sourcing a script runs its param() block in the CALLER's scope. capture-lib.ps1 learned this the hard way
  on 2026-07-29: a `param([switch]$SelfTest)` in a shared lib silently reset every builder's own $SelfTest to
  $false. A shared library must not declare parameters at all.
#>

# EVERYDAY-ONLY STORES: out\regular stores with no weekly ad cycle, where it is safe AND REQUIRED to union
# across recent captures rather than let the newest file win outright. A throttled/bot-walled Walmart pull
# returns a fraction of the catalogue, and under newest-file-wins that partial REPLACED the full board.
# Deliberately distinct name so dot-sourcing cannot collide with a caller's own variable.
$script:REGFILESET_EVERYDAY_ONLY = @('walmart')

function Get-EverydayOnlyStores { return @($script:REGFILESET_EVERYDAY_ONLY) }

function Select-RegularFileSet($fileObjs, [datetime]$asof, [int]$unionMaxAgeDays) {
  <#
    Given candidate out\regular file objects, return the ones the board prices from:
      - an EVERYDAY-ONLY store  -> every dated capture within $unionMaxAgeDays of $asof (the union)
      - every other store       -> the newest dated capture only
    The name filter is load-bearing: '*-regular-*.json' also matches things like
    'family-fare-regular-<date>.PARTIAL.json', and a non-canonical name can outsort real data in a
    newest-by-name lookup.
  #>
  $everyday = Get-EverydayOnlyStores
  $fileObjs |
    Where-Object { $_.BaseName -match '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}$' } |
    Group-Object { ($_.BaseName -replace '-regular-.*$','') } |
    ForEach-Object {
      $grp = $_.Group | Sort-Object Name -Descending
      if ($everyday -contains $_.Name) {
        $grp | Where-Object {
          $m = [regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$')
          $m.Success -and [math]::Abs(([datetime]$m.Groups[1].Value - $asof).TotalDays) -le $unionMaxAgeDays
        }
      } else {
        $grp | Select-Object -First 1
      }
    }
}
