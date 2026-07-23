<#
  carry-forward-regular.ps1 - "absence from one throttled response is not evidence of absence from the
  store" (the Family Fare lesson of 2026-07-14), extended to the stores that never got it: Baker's,
  Aldi, Fareway (2026-07-23, improvement item 4).

  THE PROBLEM: these stores' everyday files are written wholesale by the browser agents, and
  compare-deals takes the NEWEST file per store. A partial pull (Akamai wall, agent interrupted,
  thin search results) therefore silently REPLACES a fuller capture, and the missing items fall off
  the board - the coverage guard then HOLDS the publish (safe, but a lost refresh day). These stores
  cannot use the Walmart/Sam's UNION: their sale rows are dated, so a freshness-ranked union would
  filter a still-valid sale out (pinned by compare-deals self-test case 13). The fix that IS safe is
  carry-forward at file level: after a new capture is written, items present in the PREVIOUS capture
  but absent from this one are copied in, stamped with their true capture date (as_of), and dropped
  once they age past -MaxCarryDays. The file stays a single newest-wins file; no ranker semantics change.

  Idempotent: carried rows land in the newest file, so a re-run finds nothing new to carry.
  Chained age: a carried row keeps its ORIGINAL as_of across successive carries and expires from that
  date, never from the date it was last copied.

  Called by: the weekly browser SKILL (Baker's step C, Aldi step F2), the Fareway builds
  (build-fareway-regular.ps1 tail). Run manually anytime; it only ever touches the newest file.
#>
param(
  [Parameter(Mandatory=$true)][ValidateSet('bakers','aldi','fareway')][string]$Store,
  [int]$MaxCarryDays = 14,
  [string]$RegularDir = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }

function Invoke-CarryForward([string]$prefix, [string]$dir, [int]$maxDays) {
  $files = @(Get-ChildItem (Join-Path $dir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($prefix) + '-regular-\d{4}-\d{2}-\d{2}$') } |
    Sort-Object Name -Descending)
  if ($files.Count -lt 2) { return "carry-forward [$prefix]: fewer than 2 dated captures - nothing to carry from" }
  $newF = $files[0]; $prevF = $files[1]
  $newDate  = [datetime]([regex]::Match($newF.BaseName,  '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $prevDate = [datetime]([regex]::Match($prevF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $new  = Get-Content $newF.FullName  -Raw | ConvertFrom-Json
  $prev = Get-Content $prevF.FullName -Raw | ConvertFrom-Json
  $have = @{}
  foreach ($d in @($new.deals)) { $have[([string]$d.item).ToLower().Trim()] = $true }
  $carried = 0; $expired = 0
  $outDeals = New-Object System.Collections.Generic.List[object]
  foreach ($d in @($new.deals)) { $outDeals.Add($d) }
  foreach ($d in @($prev.deals)) {
    $k = ([string]$d.item).ToLower().Trim()
    if (-not $k -or $have.ContainsKey($k)) { continue }
    # true capture date: a row already carried once keeps its original as_of
    $asOf = $prevDate
    if ($d.PSObject.Properties['as_of'] -and $d.as_of) { try { $asOf = [datetime]$d.as_of } catch {} }
    if (($newDate - $asOf).TotalDays -gt $maxDays) { $expired++; continue }
    $row = $d | Select-Object *   # shallow copy so we never mutate the prev doc
    if (-not $row.PSObject.Properties['as_of']) { $row | Add-Member -NotePropertyName as_of -NotePropertyValue $asOf.ToString('yyyy-MM-dd') }
    else { $row.as_of = $asOf.ToString('yyyy-MM-dd') }
    $outDeals.Add($row); $carried++
  }
  if ($carried -eq 0 -and $expired -eq 0) { return "carry-forward [$prefix]: newest capture already covers everything in $($prevF.Name) - nothing carried" }
  $new.deals = $outDeals
  # note the operation in the envelope without disturbing other fields (price_mode etc. must survive)
  $note = ("carry-forward: +{0} item(s) from {1} (absent from this pull; as_of-stamped, {2}-day cap), {3} expired" -f $carried, $prevF.Name, $maxDays, $expired)
  if ($new.PSObject.Properties['carry_note']) { $new.carry_note = $note } else { $new | Add-Member -NotePropertyName carry_note -NotePropertyValue $note }
  $new | ConvertTo-Json -Depth 6 | Set-Content $newF.FullName -Encoding UTF8
  return "carry-forward [$prefix]: $note -> $($newF.Name)"
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('cf-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $T -Force | Out-Null
  try {
    $today = [datetime]::Today
    $d0 = $today.ToString('yyyy-MM-dd')                    # newest (partial: 1 item)
    $d1 = $today.AddDays(-5).ToString('yyyy-MM-dd')        # previous (3 items, 1 pre-carried and expired)
    $prevDeals = @(
      @{ store='Aldi'; item='Milk';   ad_price='$3.39'; size='1 gal' },
      @{ store='Aldi'; item='Eggs';   ad_price='$1.65'; size='dozen' },
      @{ store='Aldi'; item='Butter'; ad_price='$3.19'; size='16 oz'; as_of=$today.AddDays(-20).ToString('yyyy-MM-dd') }  # already 20d old -> expires
    )
    @{ store='Aldi'; price_type='everyday'; price_mode='in-store'; mode_verified=$d1; deals=$prevDeals } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "aldi-regular-$d1.json") -Encoding UTF8
    @{ store='Aldi'; price_type='everyday'; price_mode='in-store'; mode_verified=$d0; deals=@(@{ store='Aldi'; item='Milk'; ad_price='$3.45'; size='1 gal' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "aldi-regular-$d0.json") -Encoding UTF8
    $r = Invoke-CarryForward 'aldi' $T 14
    Write-Output $r
    $out = Get-Content (Join-Path $T "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
    $items = @($out.deals | ForEach-Object { $_.item })
    if ($items.Count -eq 2 -and ($items -contains 'Milk') -and ($items -contains 'Eggs')) { Write-Output 'ok    partial pull keeps its own row + carries the missing one' } else { Write-Output "FAIL  items = $($items -join ',') want Milk,Eggs"; $fail++ }
    if (-not ($items -contains 'Butter')) { Write-Output 'ok    20-day-old pre-carried row expired (14-day cap from ORIGINAL as_of)' } else { Write-Output 'FAIL  expired row was carried'; $fail++ }
    $eggs = $out.deals | Where-Object { $_.item -eq 'Eggs' }
    if ($eggs.as_of -eq $d1) { Write-Output "ok    carried row stamped as_of=$d1 (its true capture date)" } else { Write-Output "FAIL  eggs as_of=$($eggs.as_of)"; $fail++ }
    if ($out.price_mode -eq 'in-store' -and $out.mode_verified) { Write-Output 'ok    envelope (price_mode/mode_verified) survives untouched' } else { Write-Output 'FAIL  envelope damaged'; $fail++ }
    $milk = $out.deals | Where-Object { $_.item -eq 'Milk' }
    if ($milk.ad_price -eq '$3.45') { Write-Output 'ok    fresh row NOT overwritten by the stale one' } else { Write-Output "FAIL  milk = $($milk.ad_price)"; $fail++ }
    # idempotency: run again -> nothing new
    $r2 = Invoke-CarryForward 'aldi' $T 14
    $out2 = Get-Content (Join-Path $T "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
    if (@($out2.deals).Count -eq 2) { Write-Output 'ok    idempotent (second run carries nothing new)' } else { Write-Output "FAIL  second run -> $(@($out2.deals).Count) rows"; $fail++ }
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Write-Output (Invoke-CarryForward $Store $regDir $MaxCarryDays)
